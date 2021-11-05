import Test.Cabal.Prelude
import Control.Monad.Reader (local)

main = do
  cabalTest' "single-repl-options" $ do
    cabal' "clean" []
    res <- cabalWithStdin "v2-repl" ["--repl-options=-fwrite-interface"] ":set"
    assertOutputContains "Ok, two modules loaded." res
    assertOutputContains "  -fwrite-interface" res
  cabalTest' "multiple-repl-options" $ do
    cabal' "clean" []
    res <- cabalWithStdin "v2-repl" ["--repl-options=-fwrite-interface", "--repl-options=-fdefer-typed-holes"] ":set"
    assertOutputContains "Ok, two modules loaded." res
    assertOutputContains "  -fwrite-interface" res
    assertOutputContains "  -fdefer-typed-holes" res
  cabalTest' "single-repl-options-multiple-flags" $ do
    cabal' "clean" []
    res <- cabalWithStdin "v2-repl" ["--repl-options=-fdefer-typed-holes -fwrite-interface"] ":set"
    assertOutputContains "Ok, two modules loaded." res
    assertOutputContains "  -fwrite-interface" res
    assertOutputContains "  -fdefer-typed-holes" res
  cabalTest' "single-repl-options-multiple-flags-negative" $ do
    cabal' "clean" []
    res <- local negativeTest $ cabalWithStdin "v2-repl" ["--repl-options=-fwrite-interface -fdiagnostics-show-baret"] ":set"
    assertOutputDoesNotContain "Ok, two modules loaded." res
    assertOutputContains "ghc: unrecognised flag: -fdiagnostics-show-baret" res
    assertOutputContains "did you mean one of:" res
  cabalTest' "multiple-repl-options-multiple-flags" $ do
    cabal' "clean" []
    res <- cabalWithStdin "v2-repl" [
      "--repl-options=-fignore-optim-changes -fwrite-interface",
        "--repl-options=-fdefer-type-errors -fdefer-typed-holes"
      ] ":set"
    assertOutputContains "Ok, two modules loaded." res
    assertOutputContains "  -fwrite-interface" res
    assertOutputContains "  -fignore-optim-changes" res
    assertOutputContains "  -fdefer-typed-holes" res
    assertOutputContains "  -fdefer-type-errors" res
      where
        negativeTest env = env { testShouldFail = True }
