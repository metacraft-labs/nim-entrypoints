## A ``testCase`` whose name holds a line break: the compile must stop, in
## every build, because ``--list`` prints one name per line
## (test_cs_m14_tests_entry_exact_run).
import entrypoints
import entrypoints/tests

testCase "first line\nsecond line":
  discard

main:
  echo "MAINMARKER"
