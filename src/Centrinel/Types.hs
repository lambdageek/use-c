-- | Types relevant to the toplevel interface to Centrinel
module Centrinel.Types where

import qualified System.Exit 

import Language.C.Parser (ParseError)
import Language.C.Data.Error (CError)

-- | The main error class for a single Centrinel run
data CentrinelError =
  CentCPPError !System.Exit.ExitCode -- ^ Error while invoking the C preprocessor
  | CentParseError !ParseError -- ^ Error while parsing the input C file
  -- | Error reports from Centrinel when analysis of a translation unit was aborted.
  | CentAbortedAnalysisError ![CentrinelAnalysisError]

type CentrinelAnalysisError = CError
