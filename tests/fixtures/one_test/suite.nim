## The program test_cs_m14_tests_entry_one_test_build builds to check
## ``-d:entrypointsTest=<name>``: three ``testCase``s, one whose name holds a
## space and a ``*``, and a ``tests:`` block of ``std/unittest`` tests. Each
## test prints a marker no other test prints, so the test can tell which
## tests ran and which bodies are in a binary. The test writes variants of
## this file (an edited ``beta``, a ``gamma`` that does not compile) by
## replacing whole lines.
import std/unittest
import entrypoints
import entrypoints/tests

testCase "alpha":
  echo "ONETESTMARKER alpha"

testCase "beta":
  echo "ONETESTMARKER beta"

testCase "gamma":
  echo "ONETESTMARKER gamma"

testCase "spaced * name":
  echo "ONETESTMARKER spaced"

tests:
  disableParamFiltering()
  suite "block":
    test "framework":
      echo "ONETESTMARKER framework"

main:
  echo "ONETESTMARKER main"
