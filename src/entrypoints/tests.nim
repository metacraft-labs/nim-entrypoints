## entrypoints/tests: the ``tests`` entry. List the program's tests, run all
## of them, or run some by name.
##
## .. code-block:: nim
##   import entrypoints
##   import entrypoints/tests
##
##   testCase "addition":
##     doAssert 1 + 1 == 2
##
##   tests:                       # a block of a test framework's own tests
##     suite "strings":           # (unittest2, for example)
##       test "length":
##         check "abc".len == 3
##
##   main:
##     echo "the program"
##
## * ``prog --entrypoint=tests`` runs every test; the exit code is 0 only when
##   every selected test passed.
## * ``prog --entrypoint=tests --list`` prints the test names, one per line,
##   without running any (also in the entry's list, see ``entrypoints``).
## * ``prog --entrypoint=tests --run=<name>`` runs the tests with that name
##   (``--run`` can be repeated; the ``suite::name`` spelling and ``*``
##   patterns select a framework's tests).
## * ``nim c -d:entrypoint=tests prog.nim`` builds a binary for the tests
##   alone: ``main`` is not in it, and the process runs the tests when it
##   starts.
##
## A test written ``testCase "name": body`` passes when its body returns and
## fails when it raises. A ``tests:`` block is opaque: its body is Nim code
## that runs at start-up, as a test framework such as unittest2 expects, and
## the framework reports and sets the exit code. The arguments the framework
## itself takes (``--output-level``, ``--xml``, ...) pass through. A block's
## tests are listed from its ``suite "..."`` and ``test "..."`` calls with
## literal names.
##
## A framework that reads the process's arguments itself sees the selector as
## a first argument and takes it for a test filter that nothing matches, so
## every test is skipped and the run passes. Give it ``entryArgs()`` or turn
## its argument reading off (``disableParamFiltering()`` for ``std/unittest``).
## ``compat/testutils/moduletests`` does this for unittest2.
##
## How a ``tests:`` block is placed depends on the build. With
## ``-d:entrypoint=tests`` its body stays where it is written, at module scope,
## so declarations in it are visible to the rest of the module. In a build that
## carries ``main`` as well, the body is guarded by a run-time check that
## ``--entrypoint=tests`` was given, and is a block of its own. In every
## other build (``-d:entrypoint=<another entry>``, or
## ``-d:entrypointRuntime=off``) it leaves no code, and it is not even
## type-checked.

import std/[macros, strutils]
import ../entrypoints

type TestCase = object
  name: string
  run: proc () {.closure.}

var
  testCases: seq[TestCase]
  announced: seq[string]
  opaqueBlocks: int

const testsMode* =
  # How test blocks are placed in this build: 0 not at all, 1 in place
  # (``-d:entrypoint=tests``), 2 guarded by the run-time selection.
  if compileSelected == "tests": 1
  elif compileSelected == "" and runtimeEnabled: 2
  else: 0

proc testsSelected*(): bool =
  ## Whether this process was asked to run the tests: always in a
  ## ``-d:entrypoint=tests`` build, else when ``--entrypoint=tests`` was given.
  selectedEntry() == "tests"

type TestsArgs* = object
  ## The tests entry's arguments.
  list*: bool
  run*: seq[string]
  rest*: seq[string]
    ## The arguments the test framework is to see: ``--run=<name>`` as a
    ## bare name, then everything that is not ``--list``.

proc testsArgs*(): TestsArgs =
  var skipped = false
  for a in entryArgs():
    if a == "--list":
      result.list = true
    elif a.startsWith("--run="):
      result.run.add(a["--run=".len .. ^1])
    elif a == "--" and not skipped:
      skipped = true
    else:
      result.rest.add(a)

proc frameworkArgs*(): seq[string] =
  ## The arguments to hand a test framework: its own options and filters, and
  ## the ``--run`` names as filters.
  let a = testsArgs()
  result = a.run & a.rest

proc listingOnly*(): bool =
  ## Whether the process only lists the tests (``--list``).
  testsArgs().list

proc announceBlock*() =
  ## Called when a ``tests:`` block starts up: its tests are not known to
  ## the entry (a framework runs them), so ``--run`` cannot reject a name.
  inc opaqueBlocks

proc announceTest*(name: string) =
  ## Records the name of a test a ``tests:`` block contains, for ``--list``.
  announced.add(name)

proc registerTestCase*(name: string; run: proc () {.closure.}) =
  announced.add(name)
  testCases.add(TestCase(name: name, run: run))

proc globMatch(pattern, s: string): bool =
  ## ``*`` and ``?`` patterns, the whole of ``s``.
  var p = 0
  var i = 0
  var starP = -1
  var starI = 0
  while i < s.len:
    if p < pattern.len and (pattern[p] == '?' or pattern[p] == s[i]):
      inc p; inc i
    elif p < pattern.len and pattern[p] == '*':
      starP = p; starI = i; inc p
    elif starP >= 0:
      p = starP + 1; inc starI; i = starI
    else:
      return false
  while p < pattern.len and pattern[p] == '*':
    inc p
  p == pattern.len

proc nameMatches(pattern, name: string): bool =
  pattern == name or globMatch(pattern, name)

proc runTests*(): int =
  ## The tests entry: ``--list``, or run the registered test cases (every
  ## one, or those ``--run`` names). The tests of ``tests:`` blocks ran when
  ## the process started and the framework sets their exit code.
  let a = testsArgs()
  if a.list:
    for n in announced:
      stdout.writeLine(n)
    exitImmediately(0)
  var failed = 0
  var ran = 0
  for t in testCases:
    var wanted = a.run.len == 0
    for r in a.run:
      if nameMatches(r, t.name):
        wanted = true
    if not wanted:
      continue
    inc ran
    try:
      t.run()
      stdout.writeLine("[OK] " & t.name)
    except CatchableError, Defect:
      inc failed
      stdout.writeLine("[FAILED] " & t.name & ": " &
        getCurrentExceptionMsg())
  if a.run.len > 0 and ran == 0 and opaqueBlocks == 0:
    stderr.writeLine("tests: no test is named " & a.run.join(", ") &
      "; the tests are: " & announced.join(", "))
    return usageExitCode
  if testCases.len > 0:
    stdout.writeLine($(ran - failed) & " of " & $ran & " tests passed")
  if failed > 0: 1 else: 0

when testsMode != 0:
  entryPoint "tests", doc = "run the program's tests",
             args = "[--list] [--run=<name>]... [<test framework options>]":
    result = runTests()

# ---------------------------------------------------------------------------
# Declaring tests.
# ---------------------------------------------------------------------------

macro testCase*(name: static string; body: untyped): untyped =
  ## A test: passes when ``body`` returns, fails when it raises.
  result = newEmptyNode()
  when testsMode != 0:
    addEntryNote("tests", name)
    result = newCall(bindSym"registerTestCase", newLit(name),
      newTree(nnkLambda, newEmptyNode(), newEmptyNode(), newEmptyNode(),
        newTree(nnkFormalParams, newEmptyNode()),
        newTree(nnkPragma, ident"closure"), newEmptyNode(), body))

proc collectNames(n: NimNode; suite: string; names: var seq[string])
    {.compileTime.} =
  ## The ``suite "x"`` / ``test "y"`` names a block's body writes literally
  ## and unconditionally (not under ``when``, ``if`` or ``case``).
  if n.kind in {nnkCall, nnkCommand} and n.len >= 2 and n[0].kind == nnkIdent and
      n[1].kind in {nnkStrLit..nnkTripleStrLit}:
    if n[0].eqIdent("suite"):
      for i in 2 ..< n.len:
        collectNames(n[i], n[1].strVal, names)
      return
    if n[0].eqIdent("test"):
      names.add(if suite.len > 0: suite & "::" & n[1].strVal else: n[1].strVal)
      return
  if n.kind in {nnkWhenStmt, nnkIfStmt, nnkCaseStmt}:
    return
  for c in n:
    collectNames(c, suite, names)

proc announceCode(n: NimNode; suite: string): NimNode {.compileTime.} =
  ## Code that announces the tests of a block's body when the program starts:
  ## the same walk as ``collectNames``, but a ``when`` statement is kept with
  ## its conditions, so the compiler decides which of its tests exist in this
  ## build.
  result = newStmtList()
  if n.kind in {nnkCall, nnkCommand} and n.len >= 2 and n[0].kind == nnkIdent and
      n[1].kind in {nnkStrLit..nnkTripleStrLit}:
    if n[0].eqIdent("suite"):
      for i in 2 ..< n.len:
        result.add(announceCode(n[i], n[1].strVal))
      return
    if n[0].eqIdent("test"):
      result.add(newCall(bindSym"announceTest", newLit(
        if suite.len > 0: suite & "::" & n[1].strVal else: n[1].strVal)))
      return
  if n.kind == nnkWhenStmt:
    var w = newTree(nnkWhenStmt)
    for branch in n:
      var b = branch.copyNimNode()
      for i in 0 ..< branch.len - 1:
        b.add(branch[i])
      b.add(announceCode(branch[^1], suite))
      w.add(b)
    result.add(w)
    return
  for c in n:
    result.add(announceCode(c, suite))

proc testBlockCode*(body: NimNode; where: NimNode): NimNode {.compileTime.} =
  ## The code a ``tests:`` block expands to in this build (see the module
  ## documentation). ``where`` is the node whose position labels the block.
  result = newEmptyNode()
  when testsMode != 0:
    var names: seq[string]
    collectNames(body, "", names)
    for n in names:
      addEntryNote("tests", n)
    var announce = newStmtList(newCall(bindSym"announceBlock"))
    announce.add(announceCode(body, ""))
    when testsMode == 1:
      result = newStmtList(announce, body)
    else:
      result = newStmtList(announce, newTree(nnkIfStmt,
        newTree(nnkElifBranch,
          newTree(nnkInfix, ident"and", newCall(bindSym"testsSelected"),
            newTree(nnkPrefix, ident"not", newCall(bindSym"listingOnly"))),
          newTree(nnkBlockStmt, newEmptyNode(), body))))

macro tests*(body: untyped): untyped =
  ## A block of a framework's tests; see the module documentation.
  testBlockCode(body, body)
