## The program test_cs_m13_entry_selection builds in many ways: a clispec
## command line with the run-time entry selector declared as an internal
## parameter, a `main:`, the self-description entries, test entries and a fuzz
## target. Each entry prints a marker string that exists in no other entry, so
## the test can tell which code a binary holds.
import std/os
import clispec
import entrypoints
import entrypoints/[clispec, tests, fuzz, describe]

cliProgramWithEntryPoint(Fx, "fx"):
  help "A fixture program"
  boolFlag verbose is bool, help = "Talk more"
  subcmd "run", help = "Run something":
    pos what is string, required = false, help = "What to run"
  call(help = "Run with the defaults"):
    pos target is string, required = false, help = "What to run"

describeProgram(Fx)

testCase "passes":
  echo "TESTMARKER passes"

testCase "also-passes":
  echo "TESTMARKER also-passes"

testCase "fails-when-asked":
  if getEnv("FX_FAIL") == "1":
    raise newException(ValueError, "TESTMARKER failing on request")

tests:
  echo "TESTMARKER block ran"

fuzzTarget "len", doc = "fuzz the input length":
  echo "FUZZMARKER input of ", payload.len, " bytes"
  doAssert payload.len < 4, "FUZZMARKER input too long"

entryPoint "compile-only", doc = "an entry that needs its own binary",
           select = {compileTime}:
  echo "COMPILEONLYMARKER"

main:
  try:
    let conf = Fx.load(entryArgs())
    echo "MAINMARKER verbose=", conf.verbose, " selector=[", conf.entrypoint,
      "]"
  except CliHelpRequest as e:
    Fx.printHelp(e)
  except CliUsageError as e:
    Fx.printError(e)
    quit(e.exitCode)
