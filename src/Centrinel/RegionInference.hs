-- | Analyze a parsed C file and create region unification constraints
--
{-# LANGUAGE FunctionalDependencies #-}
module Centrinel.RegionInference (inferDeclEvent, hasRegionAttr, applyBindingTagDef, justStructTagDefs) where

import qualified Data.Map
import Data.Monoid (First(..))

-- data
import qualified Language.C.Data.Ident as Id
import qualified Language.C.Data.Node as C

-- syntax
import qualified Language.C.Syntax.AST as Syn
import qualified Language.C.Syntax.Constants as Syn

-- semantics
import qualified Language.C.Analysis.SemRep as A

import Language.C.Analysis.Debug () -- P.Pretty instances 

import Centrinel.Region
import Centrinel.RegionUnification
import Centrinel.RegionUnification.Term (regionUnifyVar, RegionVar)
import Centrinel.RegionIdent

inferDeclEvent :: (RegionAssignment RegionIdent v m, RegionUnification v m) => A.DeclEvent -> m ()
inferDeclEvent e =
  case e of
    A.TagEvent (A.CompDef structTy@(A.CompType suref A.StructTag _ attrs ni)) -> do
      -- Effect order matters here: first add the location from the attribute,
      -- then try to unify with region from the first member.  That way we have
      -- both if unification fails.
      r <- assignRegion (StructTagId suref)
      case hasRegionAttr attrs of
        Just rc -> do
          constantRegion r rc
          regionAddLocation r ni
        Nothing -> return ()
      m <- deriveRegionFromMember structTy
      case m of
        Just r' -> sameRegion r' r
        Nothing -> return ()
    A.TypeDefEvent (A.TypeDef typedefIdent ty _ _) -> do
      m <- deriveRegionFromType ty
      r <- assignRegion (TypedefId typedefIdent)
      case m of
        Just r' -> sameRegion r' r
        Nothing -> return ()
    _ -> return ()

hasRegionAttr :: A.Attributes -> Maybe Region
hasRegionAttr = getFirst . foldMap (First . from)
  where
    from (A.Attr ident [Syn.CConst (Syn.CIntConst r _)] _ni) | Id.identToString ident == "__region" = Just (Region $ fromInteger $ Syn.getCInteger r)
    from _ = Nothing

withLocation :: (RegionUnification v m, C.CNode n) => n -> Maybe v -> m (Maybe v)
withLocation ni m = do
  case m of
    Just r -> regionAddLocation r ni
    Nothing -> return ()
  return m

deriveRegionFromMember :: (RegionAssignment RegionIdent v m, RegionUnification v m) => A.CompType -> m (Maybe v)
deriveRegionFromMember (A.CompType _suref A.StructTag (A.MemberDecl (A.VarDecl _varName _dattrs memberType) Nothing niMember :_) _ _ni) =
  deriveRegionFromType memberType >>= withLocation niMember
deriveRegionFromMember _ = return Nothing

deriveRegionFromType :: (RegionAssignment RegionIdent v m, RegionUnification v m) => A.Type -> m (Maybe v)
deriveRegionFromType (A.DirectType t _qs _attrs) = deriveRegionFromTypeName t
deriveRegionFromType (A.TypeDefType td _qs _attrs) = deriveRegionFromTypeDefRef td
deriveRegionFromType _ = return Nothing

deriveRegionFromTypeName :: (RegionAssignment RegionIdent v m) => A.TypeName -> m (Maybe v)
deriveRegionFromTypeName (A.TyComp (A.CompTypeRef sueref A.StructTag _ni)) = Just <$> deriveRegionFromSUERef sueref
deriveRegionFromTypeName _ = return Nothing

deriveRegionFromTypeDefRef :: (RegionAssignment RegionIdent v m, RegionUnification v m) => A.TypeDefRef -> m (Maybe v)
deriveRegionFromTypeDefRef (A.TypeDefRef _ t _ni) = deriveRegionFromType t

deriveRegionFromSUERef :: (RegionAssignment RegionIdent v m) => Id.SUERef -> m v
deriveRegionFromSUERef suref = assignRegion (StructTagId suref)

-- Apply the current unification bindings to a given struct definition and return the inferred region.
applyBindingTagDef :: (ApplyUnificationState m, RegionAssignment RegionIdent RegionVar m) => A.TagDef -> m RegionScheme
applyBindingTagDef (A.CompDef (A.CompType sueref A.StructTag _members _attrs _ni)) = do
  v <- assignRegion (StructTagId sueref)
  m <- applyUnificationState (regionUnifyVar v)
  return $ extractRegionScheme m
applyBindingTagDef _ = return PolyRS

justStructTagDefs :: Data.Map.Map k A.TagDef -> Data.Map.Map k A.TagDef
justStructTagDefs = Data.Map.filter isStruct
  where
    isStruct (A.CompDef (A.CompType _sueref A.StructTag _membs _attrs _ni)) = True
    isStruct _ = False