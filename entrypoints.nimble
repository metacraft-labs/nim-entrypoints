# The version is written here as a literal, not read from version.txt:
# Nimble evaluates this file from its own working directory, and again in
# the installed copy of the package, which holds only `src/`, `compat/` and
# this file. `just bump-version` writes both; test_suite_lists_agree checks
# they agree.
version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Alternative entry points into a Nim program's main module: main:, entryPoint, selection at compile time or run time, and entries for tests, self-description and fuzzing."
license       = "Apache-2.0"
srcDir        = "src"
skipDirs      = @["tests"]
installDirs   = @["compat"]

# The library needs nothing beyond the standard library. clispec is an
# optional dependency: only `entrypoints/clispec` and `entrypoints/describe`
# import it, and only programs that import those need it. The nim-testutils
# compatibility test builds against nim-testutils, unittest2, stew and
# results, which the tests find themselves (see tests/harness.nim).
requires "nim >= 2.0.0"

task test, "Run the test suite":
  for t in ["test_cs_m13_entry_selection", "test_cs_m13_testutils_compatible",
            "test_cs_m14_tests_entry_exact_run", "test_suite_lists_agree"]:
    exec "nim c -r --hints:off tests/" & t & ".nim"
