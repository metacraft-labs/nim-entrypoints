## test_suite_lists_agree: the three places that name the test suite name the
## same files.
##
## The suite is run three ways: ``just test`` (the ``tests`` variable of the
## ``Justfile``), ``nimble test`` (the ``test`` task of ``entrypoints.nimble``)
## and the build graph of ``repro.nim`` (its ``entrypointsTests`` list, one
## build and one run per entry). Each list is written by hand, so a new test
## module added to one of them and not the others silently drops out of a
## runner. This test reads the files as text and requires every list to name
## exactly the ``tests/test_*.nim`` modules on disk.
##
## It also checks the fact ``repro.nim`` records per test that the other
## runners do not need: ``runsCompiler`` must be set exactly for the modules
## that run the Nim compiler while they execute (they call
## ``compileProgram`` of ``tests/harness.nim`` or ``getCurrentCompilerExe``).
##
## And it checks that ``entrypoints.nimble`` states the version ``version.txt``
## holds (Nimble cannot read ``version.txt``: it evaluates the nimble file
## from its own working directory, and in an installed copy of the package
## that has no ``version.txt``).
##
## The files are read as text rather than evaluated because evaluating them
## needs three different tools; the text forms read here are the ones each
## file is written in, and a reformatting that defeats a reader fails this
## test rather than passing it (every reader requires a non-empty result).
## Nothing is mocked.

import std/[algorithm, os, sets, strutils, unittest]

const
  testsDir = currentSourcePath().parentDir()
  repoDir = testsDir.parentDir()

proc sortedList(items: openArray[string]): seq[string] =
  result = @items
  result.sort()

proc duplicates(items: openArray[string]): seq[string] =
  var seen = initHashSet[string]()
  for item in items:
    if item in seen:
      result.add(item)
    seen.incl(item)

proc between(text, startMarker, endMarker: string): string =
  ## The text after the first ``startMarker`` up to the next ``endMarker``;
  ## empty when either is missing.
  let start = text.find(startMarker)
  if start < 0:
    return ""
  let bodyStart = start + startMarker.len
  let stop = text.find(endMarker, bodyStart)
  if stop < 0:
    return ""
  text[bodyStart ..< stop]

proc quotedStrings(text: string): seq[string] =
  ## Every ``"..."`` literal in ``text``, in order (no escapes are needed by
  ## the lists read here).
  var i = 0
  while i < text.len:
    if text[i] == '"':
      let stop = text.find('"', i + 1)
      if stop < 0:
        break
      result.add(text[i + 1 ..< stop])
      i = stop + 1
    else:
      inc i

proc testsOnDisk(): seq[string] =
  for path in walkFiles(testsDir / "test_*.nim"):
    result.add(path.extractFilename.changeFileExt(""))
  result.sort()

proc justfileTests(): seq[string] =
  ## The ``tests := "..."`` variable of the Justfile.
  for line in readFile(repoDir / "Justfile").splitLines():
    if line.startsWith("tests :="):
      let literals = quotedStrings(line)
      if literals.len == 1:
        return literals[0].splitWhitespace()

proc nimbleTests(): seq[string] =
  ## The array the nimble task ``test`` loops over.
  let body = between(readFile(repoDir / "entrypoints.nimble"),
    "task test,", "exec")
  for literal in quotedStrings(body):
    if literal.startsWith("test_"):
      result.add(literal)

type ReproTest = object
  stem: string
  runsCompiler: bool

proc reproTests(): seq[ReproTest] =
  ## The ``entrypointsTests`` list of repro.nim: one ``EntrypointsTest(...)``
  ## per module, with its ``runsCompiler`` flag.
  let body = between(readFile(repoDir / "repro.nim"),
    "const entrypointsTests = [", "\n]")
  for entry in body.split("EntrypointsTest(")[1 .. ^1]:
    let literals = quotedStrings(entry)
    if literals.len == 0 or not literals[0].startsWith("tests/"):
      continue
    result.add(ReproTest(
      stem: literals[0].extractFilename.changeFileExt(""),
      runsCompiler: "runsCompiler: true" in entry))

proc codeLines(text: string): seq[string] =
  ## The lines of ``text`` that are not comments, stripped.
  for line in text.splitLines():
    let code = line.strip()
    if code.len > 0 and not code.startsWith("#") and
        not code.startsWith("##"):
      result.add(code)

proc runsCompiler(text: string): bool =
  # Spelled in pieces so this file's own text does not match.
  for code in codeLines(text):
    if ("compileProgram" & "(") in code or
        ("getCurrentCompilerExe" & "()") in code:
      return true

suite "test_suite_lists_agree":

  let onDisk = testsOnDisk()

  test "there are test modules to compare":
    check onDisk.len > 0
    check "test_suite_lists_agree" in onDisk

  test "the Justfile runs every test module and nothing else":
    let listed = justfileTests()
    check listed.len > 0
    check duplicates(listed).len == 0
    check sortedList(listed) == onDisk

  test "the nimble test task runs every test module and nothing else":
    let listed = nimbleTests()
    check listed.len > 0
    check duplicates(listed).len == 0
    check sortedList(listed) == onDisk

  test "repro.nim builds and runs every test module and nothing else":
    var listed: seq[string] = @[]
    for t in reproTests():
      listed.add(t.stem)
    check listed.len > 0
    check duplicates(listed).len == 0
    check sortedList(listed) == onDisk

  test "entrypoints.nimble's version is version.txt's":
    let wanted = readFile(repoDir / "version.txt").strip()
    check wanted.len > 0
    var found: seq[string] = @[]
    for line in readFile(repoDir / "entrypoints.nimble").splitLines():
      if line.startsWith("version ") and "=" in line:
        found.add(line.split("=", 1)[1].strip().strip(chars = {'"'}))
    check found == @[wanted]

  test "repro.nim declares the compiler for exactly the tests that run it":
    for t in reproTests():
      let runs = runsCompiler(readFile(testsDir / (t.stem & ".nim")))
      checkpoint(t.stem & ": runs the compiler = " & $runs &
        ", runsCompiler = " & $t.runsCompiler)
      check runs == t.runsCompiler
