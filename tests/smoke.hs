module Main where

import Test.Tasty
import Test.Tasty.HUnit

import qualified Centrinel as C
import qualified Centrinel.Report as C
import Centrinel.System.RunLikeCC (runLikeCC, ParsedCC(..))
import Language.C.System.GCC (newGCC)
import qualified Centrinel.Util.Datafiles as CData



main :: IO ()
main = defaultMain smokeTests


smokeTests :: TestTree
smokeTests = testGroup "Smoke Tests"
  [ testGroup "Examples run"
    [ assertRunsTestCase "c-examples/incl.c"
    , assertRunsTestCase "c-examples/c99.c"
    ]
  ]

assertRunsTestCase :: FilePath -> TestTree
assertRunsTestCase fp = testCase (fp ++ " runs") cmd
  where
    cmd = do
      case runLikeCC gcc [fp] of
        ParsedCC args [] -> do
          ec <- C.report C.defaultOutputMethod fp $ C.runCentrinel datafiles gcc args
          assertEqual "exit code" (Just ()) (const () <$> ec) -- throw away analysis results
        NoInputFilesCC -> assertFailure $ "expected input files in smoketest " ++ fp
        ErrorParsingCC err -> assertFailure $ "unexpected parse error \"" ++ err ++ "\" in smoketest " ++ fp
        ParsedCC _args ignoredArgs -> assertFailure $ "unepxected ignored args " ++ show ignoredArgs ++ " in smoketest " ++ fp
    gcc = newGCC "cc"
    datafiles = CData.Datafiles "include/centrinel.h"

