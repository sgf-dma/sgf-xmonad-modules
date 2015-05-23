{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Sgf.XMonad.Docks
    ( DockConfig
    , addDock
    , handleDocks
    , DockClass (..)
    , ppCurrentL
    , ppVisibleL
    , ppHiddenL
    , ppHiddenNoWindowsL
    , ppUrgentL
    , ppSepL
    , ppWsSepL
    , ppTitleL
    , ppLayoutL
    , ppOrderL
    , ppSortL
    , ppExtrasL
    , ppOutputL
    )
  where

import Data.Maybe
import Data.List
import Data.Monoid
import Control.Monad.State
import Control.Applicative
import System.Posix.Types (ProcessID)

import XMonad
import XMonad.Hooks.ManageDocks hiding (docksEventHook)
import XMonad.Hooks.ManageHelpers (pid)
import XMonad.Hooks.DynamicLog
import XMonad.Layout.LayoutModifier (ModifiedLayout)
import XMonad.Util.EZConfig (additionalKeys)
import XMonad.Util.WindowProperties (getProp32s)
import Foreign.C.Types (CLong)

import Sgf.Control.Lens
import Sgf.XMonad.Restartable


-- Store some records of XConfig modified for particular dock.
-- FIXME: DockConfig should inherit something from ProgConfig . But then
-- DockClass must require RestartClass .
data DockConfig l   = DockConfig
                        { dockProg      :: ProgConfig l
                        , dockLogHook   :: X ()
                        , dockKeys      :: XConfig l
                                           -> [((ButtonMask, KeySym), X ())]
                        }

-- Wrapper around any DockClass type implementing correct dock program
-- initialization at startup: reinitPP should be done before any runP calls,
-- because i may check or fill some PP values in dock's RestartClass instance.
-- And because PP can't be saved in Extensible State, i should reinit it at
-- every xmonad restart. Note, that i can't use Existential type here, because
-- i can't define ProcessClass then.
newtype DockProg a  = DockProg a
  deriving (Eq, Read, Show, Typeable)
instance ProcessClass a => ProcessClass (DockProg a) where
    pidL f (DockProg x)     = DockProg <$> pidL f x
instance (RestartClass a, DockClass a) => RestartClass (DockProg a) where
    runP (DockProg x)       = DockProg <$> runP x
    killP (DockProg x)      = DockProg <$> killP x
    manageP (DockProg x)    = manageP x
    doLaunchP (DockProg x)  = liftA2 (<*) reinitPP doLaunchP x
    launchAtStartup (DockProg x) = launchAtStartup x
    launchKey (DockProg x)  = launchKey x
instance DockClass a => DockClass (DockProg a) where
    dockToggleKey (DockProg x)  = dockToggleKey x
    ppL f (DockProg x)          = DockProg <$> ppL f x

-- Create DockConfig for DockClass instance.
addDock :: (RestartClass a, DockClass a, LayoutClass l Window) =>
               a -> DockConfig l
addDock d           = DockConfig
      -- Launch dock process properly.
      { dockProg    = addProg (DockProg d)
      -- Log to dock according to its PP .
      , dockLogHook = dockLog d
      -- Key for toggling Struts of this Dock.
      , dockKeys    = toggleDock d
      }

-- Merge DockConfig-s into existing XConfig properly. Also takes a key for
-- toggling visibility (Struts) of all docks.
handleDocks :: LayoutClass l Window => (ButtonMask, KeySym)
               -> [DockConfig (ModifiedLayout AvoidStruts l)]
               -> XConfig l -> XConfig (ModifiedLayout AvoidStruts l)
handleDocks t ds cf = addDockKeys . handleProgs (map dockProg ds) $ cf
      -- First, de-manage dock applications.
      { manageHook = manageDocks <+> manageHook cf
      -- Then refresh screens after new dock appears.
      , handleEventHook = docksEventHook <+> handleEventHook cf
      -- Reduce Rectangle available for other windows according to Struts.
      , layoutHook = avoidStruts (layoutHook cf)
      -- Log to all docks according to their PP .
      , logHook = mapM_ dockLogHook ds >> logHook cf
      }
  where
    -- Join keys for toggling Struts of all docks and of each dock, if
    -- defined.
    --addDockKeys :: XConfig l1 -> XConfig l1
    addDockKeys     = additionalKeys <*> (concat <$> sequence
                        (toggleAllDocks t : map dockKeys ds))


class ProcessClass a => DockClass a where
    dockToggleKey   :: a -> Maybe (ButtonMask, KeySym)
    dockToggleKey   = const Nothing
    ppL             :: LensA a (Maybe PP)
    ppL             = nothingL

toggleAllDocks :: (ButtonMask, KeySym) -> XConfig l
               -> [((ButtonMask, KeySym), X ())]
toggleAllDocks (mk, k) XConfig {modMask = m} =
                        [((m .|. mk, k), sendMessage ToggleStruts)]

toggleDock :: DockClass a => a -> XConfig l -> [((ButtonMask, KeySym), X ())]
toggleDock x (XConfig {modMask = m}) = maybeToList $ do
    (mk, k) <- dockToggleKey x
    return ((m .|. mk, k), toggleProcessStruts x)

-- Toggle struts for any ProcessClass instance.
toggleProcessStruts :: ProcessClass a => a -> X ()
toggleProcessStruts = withProcess $ \x -> do
    maybe (return ()) togglePidStruts (viewA pidL x)
    return x
  where
    -- Toggle all struts, which specified PID have.
    togglePidStruts :: ProcessID -> X ()
    togglePidStruts cPid = withDisplay $ \dpy -> do
        rootw <- asks theRoot
        (_, _, wins) <- io $ queryTree dpy rootw
        ws <- filterM (\w -> maybe False (== cPid) <$> runQuery pid w) wins
        ss <- mapM getStrut ws
        let ds = nub . map (\(s, _, _, _) -> s) . concat $ ss
        mapM_ (sendMessage . ToggleStrut) ds

-- Copy from XMonad.Hooks.ManageDocks .
type Strut = (Direction2D, CLong, CLong, CLong)

-- | Gets the STRUT config, if present, in xmonad gap order
getStrut :: Window -> X [Strut]
getStrut w = do
    msp <- getProp32s "_NET_WM_STRUT_PARTIAL" w
    case msp of
        Just sp -> return $ parseStrutPartial sp
        Nothing -> fmap (maybe [] parseStrut) $ getProp32s "_NET_WM_STRUT" w
 where
    parseStrut xs@[_, _, _, _] = parseStrutPartial . take 12 $ xs ++ cycle [minBound, maxBound]
    parseStrut _ = []

    parseStrutPartial [l, r, t, b, ly1, ly2, ry1, ry2, tx1, tx2, bx1, bx2]
     = filter (\(_, n, _, _) -> n /= 0)
        [(L, l, ly1, ly2), (R, r, ry1, ry2), (U, t, tx1, tx2), (D, b, bx1, bx2)]
    parseStrutPartial _ = []
-- End copy from XMonad.Hooks.ManageDocks .

-- docksEventHook version from xmobar tutorial (5.3.1 "Example for using the
-- DBus IPC interface with XMonad"), which refreshes screen on unmap events as
-- well.
docksEventHook :: Event -> X All
docksEventHook e = do
    when (et == mapNotify || et == unmapNotify) $
        whenX ((not `fmap` isClient w) <&&> runQuery checkDock w) refresh
    return (All True)
    where w  = ev_window e
          et = ev_event_type e

dockLog :: DockClass a => a ->  X ()
dockLog             = withProcess $ \x -> do
    maybe (return ()) dynamicLogWithPP (viewA ppL x)
    return x

-- Because i can't save PP values in persistent Extensible State (there is
-- neither Show nor Read instance for PP), i need to reinitialize them each
-- time at the start (in startupHook).
reinitPP :: DockClass a => a -> X ()
reinitPP y          = withProcess (return . setA ppL (viewA ppL y)) y


-- Lenses to PP.
ppCurrentL :: LensA PP (WorkspaceId -> String)
ppCurrentL f z@(PP {ppCurrent = x})
                    = fmap (\x' -> z{ppCurrent = x'}) (f x)
ppVisibleL :: LensA PP (WorkspaceId -> String)
ppVisibleL f z@(PP {ppVisible = x})
                    = fmap (\x' -> z{ppVisible = x'}) (f x)
ppHiddenL :: LensA PP (WorkspaceId -> String)
ppHiddenL f z@(PP {ppHidden = x})
                    = fmap (\x' -> z{ppHidden = x'}) (f x)
ppHiddenNoWindowsL :: LensA PP (WorkspaceId -> String)
ppHiddenNoWindowsL f z@(PP {ppHiddenNoWindows = x})
                    = fmap (\x' -> z{ppHiddenNoWindows = x'}) (f x)
ppUrgentL :: LensA PP (WorkspaceId -> String)
ppUrgentL f z@(PP {ppUrgent = x})
                    = fmap (\x' -> z{ppUrgent = x'}) (f x)
ppSepL :: LensA PP String
ppSepL f z@(PP {ppSep = x})
                    = fmap (\x' -> z{ppSep = x'}) (f x)
ppWsSepL :: LensA PP String
ppWsSepL f z@(PP {ppWsSep = x})
                    = fmap (\x' -> z{ppWsSep = x'}) (f x)
ppTitleL :: LensA PP (String -> String)
ppTitleL f z@(PP {ppTitle = x})
                    = fmap (\x' -> z{ppTitle = x'}) (f x)
ppLayoutL :: LensA PP (String -> String)
ppLayoutL f z@(PP {ppLayout = x})
                    = fmap (\x' -> z{ppLayout = x'}) (f x)
ppOrderL :: LensA PP ([String] -> [String])
ppOrderL f z@(PP {ppOrder = x})
                    = fmap (\x' -> z{ppOrder = x'}) (f x)
ppSortL :: LensA PP (X ([WindowSpace] -> [WindowSpace]))
ppSortL f z@(PP {ppSort = x})
                    = fmap (\x' -> z{ppSort = x'}) (f x)
ppExtrasL :: LensA PP [X (Maybe String)]
ppExtrasL f z@(PP {ppExtras = x})
                    = fmap (\x' -> z{ppExtras = x'}) (f x)
ppOutputL :: LensA PP (String -> IO ())
ppOutputL f z@(PP {ppOutput = x})
                    = fmap (\x' -> z{ppOutput = x'}) (f x)

