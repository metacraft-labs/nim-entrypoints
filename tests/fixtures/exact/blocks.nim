## A module written for nim-testutils (``tests:`` blocks of unittest2 suites,
## ``programMain:``), with test names that are also patterns, for
## test_cs_m14_tests_entry_exact_run. unittest2's own filters are patterns
## (``s::a*b`` matches ``s::aXb``); ``--run-exact`` must not be. Each test
## prints a marker no other test prints. Two tests the listing cannot name
## (a name that is not a literal, a qualified ``unittest2.test``) run only
## without ``--run-exact``, and a helper procedure called ``test`` is not a
## test at all.
import testutils/moduletests

proc test(s: string): bool =
  ## A helper that shares the framework's name; ``test("...")`` without a
  ## body is an expression, not a test.
  s.len > 0

tests:
  suite "s":
    test "a*b":
      echo "BLOCKMARKER star"
    test "aXb":
      echo "BLOCKMARKER x"
  test "a*b":
    echo "BLOCKMARKER top star"
  doAssert test("helper")
  test "dyn" & "amic":
    echo "BLOCKMARKER unlisted"
  unittest2.test "qualified":
    echo "BLOCKMARKER qualified"
  when defined(fixtureMultiline):
    # A name with a line break: `--list` cannot print it on one line.
    test "first line\nsecond line":
      echo "BLOCKMARKER multiline"

programMain:
  echo "PROGRAM MAIN"
