{-# LANGUAGE RecordWildCards, MultiParamTypeClasses, FlexibleInstances, TypeSynonymInstances, UndecidableInstances, ImplicitParams #-}

-- Interface to the abstraction library

module AbstractorIFace(mkModel) where

import qualified Data.Map as Map
import Data.List

import Cudd
import CuddConvert
import Interface
import TermiteGame
import CuddExplicitDeref
import Predicate
import qualified ISpec          as I
import qualified IType          as I
import qualified DbgTypes       as D

mkModel :: I.Spec -> STDdManager s u -> RefineStatic s u -> RefineDynamic s u -> SectionInfo s u -> SymbolInfo s u AbsVar AbsVar -> D.Model DdManager DdNode b
mkModel spec m rs rd si symi = let ?spec = spec in mkModel' m rs rd si symi

mkModel' :: (?spec::I.Spec) => STDdManager s u -> RefineStatic s u -> RefineDynamic s u -> SectionInfo s u -> SymbolInfo s u AbsVar AbsVar -> D.Model DdManager DdNode b
mkModel' m RefineStatic{..} RefineDynamic{..} SectionInfo{..} SymbolInfo{..} = D.Model {..} 
    where
    -- Extract type information from AbsVar
    avarType :: AbsVar -> D.Type
    avarType (AVarPred _) = D.Bool
    avarType (AVarTerm t) = case I.typ t of
                                 I.Bool   -> D.Bool
                                 I.Enum n -> D.Enum $ (I.enumEnums $ I.getEnumeration n)
                                 I.SInt w -> D.SInt w
                                 I.UInt w -> D.UInt w
    mCtx           = toDdManager m
    (state, untracked) = partition func $ Map.toList _stateVars
        where func (_, (_, is, _, _)) = not $ null $ intersect is _trackedInds
    mStateVars     = map toTupleState state
        where toTupleState        (p, (_, is, _, is')) = (show p, avarType p, (is, is'))
    mUntrackedVars = map toModelVarUntracked untracked
        where toModelVarUntracked (p, (_, is, _, _)) = D.ModelVar (show p) (avarType p) is
    mLabelVars     = concatMap toModelVarLabel $ Map.toList _labelVars
        where toModelVarLabel     (p, (_, is, _, ie)) = [D.ModelVar (show p) (avarType p) is, D.ModelVar (show p ++ ".en") D.Bool [ie]]
    mStateRels = concat $ [[("cont", toDdNode mCtx cont)], [("init", toDdNode mCtx init)], goals, fairs]
        where
        goals = zipWith (func "goal") [0..] goal
        fairs = zipWith (func "fair") [0..] fair
        func :: String -> Int -> DDNode s u -> (String, DdNode)
        func prefix idx node = (prefix ++ show idx, toDdNode mCtx node)
    mTransRels = [("trans", toDdNode mCtx trans), ("c-c", toDdNode mCtx consistentMinusCULCont), ("c+c", toDdNode mCtx consistentPlusCULCont), ("c-u", toDdNode mCtx consistentMinusCULUCont), ("c+u", toDdNode mCtx consistentPlusCULUCont)]
    mViews     = []
