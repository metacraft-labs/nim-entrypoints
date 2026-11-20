## The program test_cs_m14_tests_entry_exact_run builds to check
## ``--run-exact``: ``testCase`` names that are also patterns (``a*b`` matches
## ``aXb``, ``a?c`` matches ``abc``), each printing a marker no other test
## prints, so the test can tell exactly which ran.
import entrypoints
import entrypoints/tests

testCase "a*b":
  echo "EXACTMARKER star"

testCase "aXb":
  echo "EXACTMARKER x"

testCase "a?c":
  echo "EXACTMARKER question"

testCase "abc":
  echo "EXACTMARKER abc"

main:
  echo "MAINMARKER"
