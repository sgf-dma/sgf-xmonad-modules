{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Sgf.XMonad.Restartable
    ( modifyXS
    , ProcessClass (..)
    , withProcess
    , getProcesses
    , RestartClass (..)
    , startP
    , startP'
    , stopP
    , stopP'
    , restartP
    , restartP'
    , toggleP
    , toggleP'
    , traceP
    , ProgConfig
    , addProg
    , handleProgs
    , Program
    , progBin
    , progArgs
    , defaultProgram
    )
  where

import Data.Maybe (maybeToList)
import Control.Applicative
import Control.Monad
import Control.Exception (try, IOException)
import Control.Concurrent (threadDelay)
import System.Posix.Process (getProcessPriority)
import System.Posix.Signals (signalProcess, sigTERM)
import System.Posix.Types (ProcessID)

import XMonad
import XMonad.Util.EZConfig (additionalKeys)
import XMonad.Hooks.ManageHelpers
import qualified XMonad.Util.ExtensibleState as XS

import Sgf.Data.List
import Sgf.Control.Lens
import Sgf.XMonad.Util.Run


-- To avoid orphan (ExtensionClass [a]) instance, i need newtype.
newtype ListP a     = ListP {_processList :: [a]}
  deriving (Show, Read, Typeable)
emptyListP :: ListP a
emptyListP          = ListP []
processList :: LensA (ListP a) [a]
processList f (ListP xs)    = fmap ListP (f xs)

instance (Show a, Read a, Typeable a) => ExtensionClass (ListP a) where
    initialValue    = emptyListP
    extensionType   = PersistentExtension

modifyXS :: ExtensionClass a => (a -> X a) -> X ()
modifyXS f          = XS.get >>= f >>= XS.put

-- Strictly, all ProcessClass requirments are not required to define its
-- instance. But ProcessClass has these requirments, because i need
-- withProcess to work on its instances.
class (Eq a, Show a, Read a, Typeable a) => ProcessClass a where
    pidL            :: LensA a (Maybe ProcessID)

-- Run function on processes stored in Extensible State equal to given one. If
-- there is no such processes, add given process there and run function on it.
withProcess :: ProcessClass a => (a -> X a) -> a -> X ()
withProcess f y     = modifyXS $ modifyAA processList $
                        mapWhenM (== y) f . insertUniq y

-- Get all processes stored in Extensible State with the type of given
-- process.
getProcesses :: ProcessClass a => a -> X [a]
getProcesses y      = XS.gets (viewA processList `asTypeOf` const [y])

class ProcessClass a => RestartClass a where
    -- Run a program.
    runP  :: a -> X a
    -- Terminate a program.  restartP' relies on Pid 'Nothing' after killP,
    -- because it then calls startP' and it won't do anything, if PID will
    -- still exist. So, in killP i should either set Pid to Nothing, or wait
    -- until it really terminates (defaultKillP does first).
    killP :: a -> X a
    killP           = modifyAA pidL $ \mp -> do
                        whenJust mp (liftIO . signalProcess sigTERM)
                        return Nothing
    -- ManageHook for this program.
    manageP :: a -> ManageHook 
    manageP         = const idHook
    -- How to start a program from startupHook or by key. Usually, if i use
    -- restartP here, program will be terminated and started again at xmonad
    -- restarts, but if i use startP here, program will only be restarted, if
    -- it wasn't running at xmonad restart.
    doLaunchP :: a -> X ()
    doLaunchP       = restartP
    -- Whether to start program from startupHook ?
    launchAtStartup  :: a -> Bool
    launchAtStartup = const True
    -- Key for restarting program.
    launchKey  :: a -> Maybe (ButtonMask, KeySym)
    launchKey       = const Nothing

-- Based on doesPidProgRun by Thomas Bach
-- (https://github.com/fuzzy-id/my-xmonad) .
refreshPid :: (MonadIO m, ProcessClass a) => a -> m a
refreshPid x        = case (viewA pidL x) of
    Nothing -> return x
    Just p  -> liftIO $ do
      either (const (setA pidL Nothing x)) (const x)
      `fmap` (try $ getProcessPriority p :: IO (Either IOException Int))

-- Here are versions of start/stop working on argument, not extensible state.
-- Run, if program is not running or already dead, otherwise do nothing.
startP' :: RestartClass a => a -> X a
startP' x           = do
  x' <- refreshPid x
  case (viewA pidL x') of
    Nothing   -> runP x'
    Just _    -> return x'

-- Stop program.
stopP' :: RestartClass a => a -> X a
stopP'              = killP <=< refreshPid

-- Stop program and run again. Note, that it will run again only, if killP
-- kills it properly: either sets pid to Nothing or waits until it dies,
-- because startP' checks whether program is running.
restartP' :: RestartClass a => a -> X a
restartP'           = startP' <=< stopP'

-- Start program, if it does not run, and stop, if it is running.
toggleP' :: RestartClass a => a -> X a
toggleP' x          = do
  x' <- refreshPid x
  case (viewA pidL x') of
    Nothing   -> runP x'
    Just _    -> killP x'

-- Here are versions of start/stop working on extensible state.  Usually,
-- these should be used.
startP :: RestartClass a => a -> X ()
startP              = withProcess startP'

stopP :: RestartClass a => a -> X ()
stopP               = withProcess stopP'

restartP :: RestartClass a => a -> X ()
restartP            = withProcess restartP'

toggleP :: RestartClass a => a -> X ()
toggleP             = withProcess toggleP'

-- Print all tracked in Extensible State programs with given type.
traceP :: RestartClass a => a -> X ()
traceP y            = getProcesses y >>= mapM_ (trace . show)


-- Store some records of XConfig modified for particular program.
data ProgConfig l   = ProgConfig
                        { progManageHook  :: MaybeManageHook
                        , progStartupHook :: X ()
                        , progKeys        :: XConfig l
                                             -> [((ButtonMask, KeySym), X ())]
                        }

-- Create ProgConfig for RestartClass instance.
addProg :: (RestartClass a, LayoutClass l Window) => a -> ProgConfig l
addProg x           = ProgConfig
                        -- Create MaybeManageHook from program's ManageHook.
                        { progManageHook  = manageProg x
                        -- Execute doLaunchP at startup.
                        , progStartupHook = when (launchAtStartup x)
                                                 (doLaunchP x)
                        -- And add key for executing doLaunchP .
                        , progKeys        = launchProg x
                        }

-- Add key executing doLaunchP action of program.
launchProg :: RestartClass a => a -> XConfig l -> [((ButtonMask, KeySym), X ())]
launchProg x (XConfig {modMask = m}) = maybeToList $ do
    (mk, k) <- launchKey x
    return ((m .|. mk, k), doLaunchP x)

-- Create MaybeManageHook, which executes program's ManageHook only, if
-- current Window pid (from _NET_WM_PID) matches pid of any program with the
-- same type stored in Extensible State.
manageProg :: RestartClass a => a -> MaybeManageHook
manageProg y        = do
    -- Sometimes `pid` returns Nothing even though process has started and
    -- Extensible State contains correct pid. Probably, i should wait for a
    -- bit.
    liftIO $ threadDelay 500000
    mp <- pid
    xs <- liftX $ getProcesses y
    if mp `elem` map (viewA pidL) xs
      then Just <$> (manageP y)
      else return Nothing

-- Merge ProgConfig-s into existing XConfig properly.
handleProgs :: LayoutClass l Window => [ProgConfig l] -> XConfig l -> XConfig l
handleProgs ps cf   = addProgKeys $ cf
      -- Run only one matched program's ManageHook for any Window.
      { manageHook = composeOne (map progManageHook ps) <+> manageHook cf
      -- Restart all programs at xmonad startup.
      , startupHook = mapM_ progStartupHook ps >> startupHook cf
      }
  where
    -- Join keys for launching programs.
    --addProgKeys :: XConfig l1 -> XConfig l1
    addProgKeys     = additionalKeys <*> (concat <$> mapM progKeys ps)

-- Default program providing set of fields needed for regular program and
-- default runP implementation.
data Program        = Program
                        { _progPid  :: Maybe ProcessID
                        , _progBin  :: FilePath
                        , _progArgs :: [String]
                        }
  deriving (Show, Read, Typeable)
progPid :: LensA Program (Maybe ProcessID)
progPid f z@(Program {_progPid = x})
                    = fmap (\x' -> z{_progPid = x'}) (f x)
progBin :: LensA Program FilePath
progBin f z@(Program {_progBin = x})
                    = fmap (\x' -> z{_progBin = x'}) (f x)
progArgs :: LensA Program [String]
progArgs f z@(Program {_progArgs = x})
                    = fmap (\x' -> z{_progArgs = x'}) (f x)
defaultProgram :: Program
defaultProgram      = Program
                        { _progPid = Nothing
                        , _progBin = ""
                        , _progArgs = []
                        }

-- I assume only one instance of each program by default. I.e. different
-- programs should have different types.
instance Eq Program where
    _ == _          = True
instance ProcessClass Program where
    pidL            = progPid
instance RestartClass Program where
    runP x          = do
                        p <- spawnPID' (viewA progBin x) (viewA progArgs x)
                        return (setA pidL (Just p) x)
