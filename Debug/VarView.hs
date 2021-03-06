{-# LANGUAGE ImplicitParams, RecordWildCards #-}

module Debug.VarView(RVarView,
               varViewNew) where

import qualified Graphics.UI.Gtk as G
import Data.IORef

import qualified Debug.DbgTypes        as D
import qualified Debug.IDE             as D
import Debug.SetExplorer
import Implicit
import Util

varViewMinWidth = 150
varViewMinHeight = 150

data VarView c a b d = VarView {
    vvModel     :: D.RModel c a b d,
    vvApplyBut  :: G.Button,
    vvSelection :: Maybe (Either (D.State a d) (D.Transition a b d)),
    vvExplorer  :: RSetExplorer c a
}

vvSelectionFrom :: VarView c a b d -> Maybe (D.State a d)
vvSelectionFrom vv = case vvSelection vv of
                          Nothing         -> Nothing
                          Just (Left s)   -> Just s
                          Just (Right tr) -> Just (D.tranFrom tr)

vvSelectionTo :: VarView c a b d -> Maybe (D.State a d)
vvSelectionTo vv = case vvSelection vv of
                          Just (Right tr) -> Just (D.tranTo tr)
                          _               -> Nothing

type RVarView c a b d = IORef (VarView c a b d)

--------------------------------------------------------------
-- View callbacks
--------------------------------------------------------------

varViewNew :: (D.Rel c v a s) => D.RModel c a b d -> IO (D.View a b d)
varViewNew rmodel = do
    model <- readIORef rmodel
    let ?m = D.mCtx model
    -- Set explorer for choosing transition variables
    let sections = [ ("State Variables",      True,  D.mCurStateVars   model)
                   , ("Untracked Variables",  False, D.mUntrackedVars  model)
                   , ("Label Variables",      False, D.mLabelVars      model)
                   , ("Next-state Variables", True,  D.mNextStateVars  model)
                   ]
    runbutton <- G.buttonNewFromStock G.stockApply
    G.widgetShow runbutton
    ref <- newIORef $ VarView { vvModel     = rmodel
                              , vvApplyBut  = runbutton
                              , vvSelection = Nothing 
                              , vvExplorer  = error "VarView: vvExplorer undefined"
                              }                  
    explorer         <- setExplorerNew ?m sections (SetExplorerEvents {evtValueChanged = valueChanged ref})
    w                <- setExplorerGetWidget explorer
    modifyIORef ref $ \vv -> vv{vvExplorer = explorer}

    -- Top-level vbox
    vbox <- G.vBoxNew False 0
    G.widgetShow vbox
    G.widgetSetSizeRequest vbox varViewMinWidth varViewMinHeight

    G.boxPackStart vbox w G.PackGrow 0
    
    -- Control buttons
    bbox <- G.hButtonBoxNew
    G.widgetShow bbox
    G.boxPackStart vbox bbox G.PackNatural 0

    resetbutton <- G.buttonNewFromStock G.stockClear
    _ <- G.on resetbutton G.buttonActivated (setExplorerReset explorer)
    G.widgetShow resetbutton
    G.boxPackStart bbox resetbutton G.PackNatural 10

    _ <- G.on runbutton G.buttonActivated (executeTransition ref)
    G.boxPackStart bbox runbutton G.PackNatural 0

    let cb = D.ViewEvents { D.evtStateSelected      = varViewStateSelected      ref 
                          , D.evtTransitionSelected = varViewTransitionSelected ref
                          , D.evtTRelUpdated        = update                    ref
                          }
    D.modelAddOracle rmodel (D.Oracle "VarView_oracle" (fmap (\tr -> if' (D.tranAbstractLabel tr .== b) Nothing (Just tr)) $ getTransition ref))
    return $ D.View { D.viewName      = "Variables"
                    , D.viewDefAlign  = D.AlignLeft
                    , D.viewShow      = return ()
                    , D.viewHide      = return ()
                    , D.viewGetWidget = return $ G.toWidget vbox
                    , D.viewQuit      = return True
                    , D.viewCB        = cb
                    }

varViewStateSelected :: (D.Rel c v a s) => RVarView c a b d -> Maybe (D.State a d) -> IO ()
varViewStateSelected ref mstate = do
    modifyIORef ref $ \vv -> vv {vvSelection = fmap Left mstate}
    update ref
--    putStrLn $ "trel support: " ++ (show $ supportIndices trel)

varViewTransitionSelected :: (D.Rel c v a s) => RVarView c a b d -> D.Transition a b d -> IO ()
varViewTransitionSelected ref tran = do
    modifyIORef ref $ \vv -> vv {vvSelection = Just $ Right tran}
    update ref

update :: (D.Rel c v a s) => RVarView c a b d -> IO ()
update ref = do
    VarView{..}  <- readIORef ref
    model@D.Model{..} <- readIORef vvModel
    let ?m = mCtx
    trel <- D.modelActiveTransRel vvModel
    let rel = case vvSelection of
                   Nothing         -> trel
                   Just (Left st)  -> (D.sAbstract st) .& (maybe t snd $ D.sConcrete st) .& trel 
                   Just (Right tr) -> D.tranRel model tr
    setExplorerSetRelation vvExplorer rel

valueChanged :: (D.Rel c v a s) => RVarView c a b d -> IO ()
valueChanged ref = do
    VarView{..} <- readIORef ref
    model <- readIORef vvModel
    let ?m = D.mCtx model
    [from, _, label, _] <- setExplorerGetVarAssignment vvExplorer
    if ((conj $ map snd label ++ map snd from) .== b)
       then G.widgetSetSensitive vvApplyBut False
       else G.widgetSetSensitive vvApplyBut True

---------------------------------------------------------------------
-- Private functions
---------------------------------------------------------------------

getTransition :: (D.Rel c v a s, ?m::c) => RVarView c a b d -> IO (D.Transition a b d)
getTransition ref = do
    vv@VarView{..} <- readIORef ref
    [from, untracked, label, to] <- setExplorerGetVarAssignment vvExplorer 
    model <- readIORef vvModel
    let fabs              = conj $ map snd $ from
        tranFrom          = D.State { sAbstract = fabs
                                    , sConcrete = case vvSelectionFrom vv of
                                                       Nothing -> Nothing
                                                       Just st -> if D.sAbstract st .== fabs then D.sConcrete st else Nothing}
        tranUntracked     = conj $ map snd $ untracked 
        tranAbstractLabel = conj $ map snd $ label
        tranConcreteLabel = Nothing
        tabs              = swap (D.mNextV model) (D.mStateV model) (conj $ map snd $ to)
        tranTo            = D.State { sAbstract = tabs
                                    , sConcrete = case vvSelectionTo vv of
                                                       Nothing -> Nothing
                                                       Just st -> if D.sAbstract st  .== tabs then D.sConcrete st else Nothing}
        tranSrc           = Nothing
    return D.Transition{..}

executeTransition :: (D.Rel c v a s, ?m::c) => RVarView c a b d -> IO ()
executeTransition ref = do
    model <- getIORef vvModel ref
    tr <- getTransition ref
    D.modelAddTransition model tr
