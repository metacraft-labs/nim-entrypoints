## A module that imports unittest2 before nim-testutils' module, the order
## that lets unittest2 read the process's arguments before nim-entrypoints
## can keep the entry selector out of them.
import unittest2          # before the compat module: too late for its define
import testutils/moduletests
tests:
  suite "s":
    test "t":
      check 1 == 1
programMain:
  echo "MAIN"
