module HeapGuard.RegionInferenceResult where

import qualified Data.Map as Map

import Language.C.Data.Ident (SUERef)
import qualified Data.Assoc

import qualified HeapGuard.PrettyPrint as PP
import HeapGuard.PrettyPrint ((<+>))

import HeapGuard.Region (RegionScheme)

-- | @struct T@ reference - the name @T@ in the struct/union/enum tag namespace, but only when it's a struct.
-- we're not interested in unions or enums.
newtype StructTagRef = StructTagRef SUERef
  deriving (Show, Eq, Ord)

instance PP.Pretty StructTagRef where
  prettyPrec p (StructTagRef sueref) = PP.parenPrec p 10 $ PP.text "StructTagRef" <+> PP.prettyPrec 11 sueref

type RegionInferenceResult = Data.Assoc.Assoc StructTagRef RegionScheme

-- | Make a region inference result.  Assumes the map contains only 'SUERef's that represent structs.
makeRegionInferenceResult :: Map.Map SUERef a -> Data.Assoc.Assoc StructTagRef a
makeRegionInferenceResult = Data.Assoc.Assoc . (Map.mapKeysMonotonic StructTagRef)

