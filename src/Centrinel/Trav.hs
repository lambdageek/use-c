-- | Centrinel C language traversal monad
--
-- The @HGTrav@ monad stack has:
-- 1. a collection of analysis hooks that are triggered by traversals of C ASTs,
-- 2. and a unification state of region unification constraints and a map from C types to region unification variables.
--
--
{-# language GeneralizedNewtypeDeriving, LambdaCase, ViewPatterns #-}
module Centrinel.Trav (
  HGTrav
  , runHGTrav
  , evalHGTrav
  , HGAnalysis
  , withHGAnalysis
  , RegionIdentMap
  , frozenRegionUnificationState
  ) where

import Control.Monad.Trans.Class 
import Control.Monad.Trans.Reader (ReaderT)
import Control.Monad.Except (ExceptT (..))
import qualified Control.Monad.Trans.Reader as Reader
import Control.Monad.Trans.State.Lazy (StateT)
import qualified Control.Monad.Trans.State.Lazy as State

import Data.Bifunctor (Bifunctor(..))
import qualified Data.Map.Lazy as Map

import Language.C.Data.Ident (SUERef)
import Language.C.Data.Error (CError, fromError)

import Language.C.Analysis.SemRep (DeclEvent)
import qualified Language.C.Analysis.TravMonad as AM
import Language.C.Analysis.TravMonad.Instances ()

import qualified Centrinel.Region.Ident as HGId
import Centrinel.Region.Region (RegionScheme)
import qualified Centrinel.Region.Unification as U
import qualified Centrinel.Region.Unification.Term as U
import Centrinel.Types (CentrinelAnalysisError (..))
import Centrinel.Warning (hgWarn)

type HGAnalysis s = DeclEvent -> HGTrav s ()

type RegionIdentMap = Map.Map HGId.RegionIdent U.RegionUnifyTerm

newtype HGTrav s a = HGTrav { unHGTrav :: ReaderT (HGAnalysis s) (StateT RegionIdentMap (U.UnifyRegT (AM.Trav s))) a}
  deriving (Functor, Applicative, Monad)

instance AM.MonadName (HGTrav s) where
  genName = HGTrav AM.genName

instance AM.MonadSymtab (HGTrav s) where
  getDefTable = HGTrav AM.getDefTable
  withDefTable = HGTrav . AM.withDefTable

instance AM.MonadCError (HGTrav s) where
  throwTravError = HGTrav . AM.throwTravError
  catchTravError (HGTrav c) handler = HGTrav (AM.catchTravError c (unHGTrav . handler))
  recordError = HGTrav . AM.recordError
  getErrors = HGTrav $ AM.getErrors

instance U.RegionUnification U.RegionVar (HGTrav s) where
  newRegion = HGTrav $ lift $ lift U.newRegion
  sameRegion v = HGTrav . lift . lift . U.sameRegion v
  constantRegion v  = HGTrav . lift . lift . U.constantRegion v
  regionAddLocation v = HGTrav . lift . lift . U.regionAddLocation v

instance U.ApplyUnificationState (HGTrav s) where
  applyUnificationState = HGTrav . lift . lift . U.applyUnificationState

(-:=) :: U.RegionVar -> Maybe U.RegionUnifyTerm -> HGTrav s U.RegionUnifyTerm
v -:= Nothing = return (U.regionUnifyVar v)
v -:= Just r = do
  m <- HGTrav $ lift $ lift $ U.unify (U.regionUnifyVar v) r
  case m of
    Right r' -> return r'
    Left _err -> do
      AM.recordError (hgWarn "failed to unify regions" Nothing) -- TODO: region info
      return (U.regionUnifyVar v)

getRegionIdent :: HGId.RegionIdent -> HGTrav s (Maybe (U.RegionUnifyTerm))
getRegionIdent i = HGTrav $ lift $ State.gets (Map.lookup i)

putRegionIdent :: HGId.RegionIdent -> U.RegionUnifyTerm -> HGTrav s ()
putRegionIdent i m = HGTrav $ lift $ State.modify' (Map.insert i m)

-- | Gets a mapping of the region identifiers that have been noted by
-- unification to their 'RegionScheme' as implied by the constraints available
-- at the time of the call.
frozenRegionUnificationState :: HGTrav s (Map.Map SUERef RegionScheme)
frozenRegionUnificationState = do
  sueRegions <- HGTrav $ lift $ State.gets munge
  traverse (fmap U.extractRegionScheme . U.applyUnificationState) sueRegions
  where
    munge :: Map.Map HGId.RegionIdent U.RegionUnifyTerm -> Map.Map SUERef U.RegionUnifyTerm
    munge = Map.mapKeysMonotonic onlySUERef . Map.filterWithKey (\k -> const (isStructTag k))
    onlySUERef :: HGId.RegionIdent -> SUERef
    onlySUERef (HGId.StructTagId sue) = sue
    onlySUERef (HGId.TypedefId {}) = error "unexpected TypedefId in onlySUERef"
    isStructTag :: HGId.RegionIdent -> Bool
    isStructTag (HGId.StructTagId {}) = True
    isStructTag (HGId.TypedefId {}) = False

instance HGId.RegionAssignment HGId.RegionIdent U.RegionVar (HGTrav s) where
  assignRegion i = do
    v <- U.newRegion
    r <- getRegionIdent i
    r' <- v -:= r
    putRegionIdent i r'
    return v

instance AM.MonadTrav (HGTrav s) where
  handleDecl ev = do
    handler <- HGTrav Reader.ask
    handler ev

withHGAnalysis :: HGAnalysis s -> HGTrav s a -> HGTrav s a
withHGAnalysis az =
  HGTrav . Reader.local (addAnalysis az) . unHGTrav
  where
    -- new analysis runs last
    addAnalysis m = (>> m)

runHGTrav :: Monad m
          => HGTrav () a
          -> ExceptT [CentrinelAnalysisError] m ((a, RegionIdentMap), [CentrinelAnalysisError])
runHGTrav = helper State.runStateT

evalHGTrav :: Monad m
           => HGTrav () a
          -> ExceptT [CentrinelAnalysisError] m (a, [CentrinelAnalysisError])
evalHGTrav = helper State.evalStateT

helper :: Monad m
       => (StateT RegionIdentMap (U.UnifyRegT (AM.Trav t)) a
           -> Map.Map k b
           -> U.UnifyRegT (AM.Trav ()) r)
       -> HGTrav t a
       -> ExceptT [CentrinelAnalysisError] m (r, [CentrinelAnalysisError])
helper destructState (HGTrav comp) =
  ExceptT $ return . fixupErrors $ AM.runTrav_ $ U.runUnifyRegT (destructState (Reader.runReaderT comp az) Map.empty)
  where
    az = const (return ())
    -- change errors and warnings from one form to another
    fixupFatalNonFatal :: (e1 -> e2) -> (w1 -> w2)
                       -> Either e1 (a, w1) -> Either e2 (a, w2)
    fixupFatalNonFatal fErr fWarn = bimap fErr (fmap fWarn)
    -- refine 'CError' errors and warnings to 'CentrinelAnalysisError'
    fixupErrors :: Either [CError] (a, [CError])
                -> Either [CentrinelAnalysisError] (a, [CentrinelAnalysisError])
    fixupErrors = fixupFatalNonFatal (map centrinelAnalysisError) (map centrinelAnalysisError)


-- | Refine an existentially-packed 'CError' into one of the well-known Centrinel
-- analysis errors, or a purely C syntax or semantics error from the "language-c" package.
centrinelAnalysisError :: CError -> CentrinelAnalysisError
centrinelAnalysisError =
  \case
    e | Just regError <- fromError e -> CARegionMismatchError regError
      | Just nakedPtrError <- fromError e -> CANakedPointerError nakedPtrError
      | otherwise -> CACError e
