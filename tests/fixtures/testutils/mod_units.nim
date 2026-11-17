## A module written for nim-testutils, unchanged: `tests:` blocks (unittest2
## suites and tests) and `programMain:`. It imports `testutils/moduletests`
## and relies on nim-testutils' semantics; which implementation answers the
## import is decided by the Nim path alone.
import testutils/moduletests

proc double(x: int): int = x * 2

tests:
  suite "doubling":
    test "two":
      check double(2) == 4
    test "zero":
      check double(0) == 0
    when defined(fixtureFail):
      test "wrong":
        check double(2) == 5
  test "top level":
    check double(1) == 2

tests:
  suite "second block":
    test "declared apart":
      check double(10) == 20

programMain:
  echo "PROGRAM MAIN ", double(21)
