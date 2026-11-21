## test_cs_m14_tests_entry_one_test_build: `-d:entrypointsTest=<name>` builds
## a binary for one `testCase`, and the binaries of the tests an edit did not
## touch come out byte-identical. A build tool that keys each test's run on
## the bytes of that test's binary then reruns only the edited test.
##
## The fixture (`tests/fixtures/one_test/suite.nim`) has the `testCase`s
## `alpha`, `beta`, `gamma` and `spaced * name`, a `tests:` block of
## `std/unittest` tests, and a `main:`; every test prints a marker of its own.
## It is compiled with the real Nim and run.
##
## Checked:
##
## * `--list-test-cases` prints the `testCase` names alone (not the `tests:`
##   block's), and runs nothing.
## * A binary built for one test lists that name alone, runs that test alone
##   (with `--entrypoint=tests` and with `--run-exact=<name>`), refuses
##   another name with 64, names only that test in its entry list, and holds
##   no marker of another test or of the `tests:` block; `main` is still in
##   it. The same with `-d:entrypoint=tests`, which also drops `main`.
## * An edit of `beta`'s body that keeps its line count leaves the binaries
##   built for `alpha` and `gamma` byte-identical (each rebuilt from the same
##   path into the same place). Controls: `beta`'s own binary and the binary
##   of every test do change, so the edit reached the code.
## * The other tests' bodies are not type-checked: a `gamma` that does not
##   compile does not stop a build for `alpha`. Control: the build of every
##   test fails on it.
## * The compile stops, naming the problem, for a name no `testCase` has, for
##   the name of a `tests:` block test, for a build that carries no tests
##   entry (`-d:entrypoint=main`, `-d:entrypointRuntime=off`), and for a bare
##   `-d:entrypointsTest`, an empty `-d:entrypointsTest=` and a name with a
##   line break.
##
## Nothing is mocked: the compiler is the one running this test
## (`tests/harness.nim`).

import std/[json, os, strutils, unittest]

import harness

const
  fixture = testsDir / "fixtures" / "one_test" / "suite.nim"
  caseNames = @["alpha", "beta", "gamma", "spaced * name"]
  caseMarkers = @["ONETESTMARKER alpha", "ONETESTMARKER beta",
    "ONETESTMARKER gamma", "ONETESTMARKER spaced"]
  frameworkMarker = "ONETESTMARKER framework"
  mainMarker = "ONETESTMARKER main"
  betaLine = "  echo \"ONETESTMARKER beta\""
  betaEdited = "  stdout.writeLine \"ONETESTMARKER beta\""
  gammaLine = "  echo \"ONETESTMARKER gamma\""
  gammaBroken = "  let notAnInt: int = \"ONETESTMARKER gamma\""

proc build(name, source: string; flags: varargs[string]): RunResult =
  result = compileProgram(source, name, @flags, [repoDir / "src"])
  checkpoint("nim c " & @flags.join(" ") & " " & source & " -> " &
    $result.code & "\n" & result.output & result.errors)

proc mustBuild(name, source: string; flags: varargs[string]): string =
  let r = build(name, source, flags)
  require r.code == 0
  binaryOf(name)

proc run(exe: string; args: varargs[string]): RunResult =
  result = runProgram(exe, @args)
  checkpoint(exe.extractFilename & " " & @args.join(" ") & "\n" &
    result.output & result.errors)
  require not result.timedOut

proc ranMarkers(r: RunResult): seq[string] =
  for m in caseMarkers & @[frameworkMarker, mainMarker]:
    if m in r.output:
      result.add(m)

proc heldMarkers(name: string): seq[string] =
  ## The markers whose text is in the binary.
  for m in caseMarkers & @[frameworkMarker, mainMarker]:
    if binaryHolds(name, m):
      result.add(m)

proc variant(name: string; replacements: openArray[(string, string)]):
    string =
  ## The fixture with whole lines replaced, at `scratchRoot/<name>/suite.nim`
  ## (one path per variant name, so a rebuild reads the same path).
  var text = readFile(fixture)
  for (old, new) in replacements:
    doAssert old in text, old
    text = text.replace(old, new)
  doAssert text.countLines == readFile(fixture).countLines
  let dir = scratchRoot / name
  createDir(dir)
  result = dir / "suite.nim"
  writeFile(result, text)

proc testsEntryNotes(exe: string): seq[string] =
  let list = parseJson(run(exe, "--entrypoint=list").output)
  for e in list["entries"]:
    if e["name"].getStr == "tests":
      for n in e["entries"]:
        result.add(n.getStr)

suite "test_cs_m14_tests_entry_one_test_build":

  test "a binary built for one testCase holds and runs that test alone":
    # Control: the binary of every test holds and lists them all.
    let full = mustBuild("one_full", fixture)
    check heldMarkers("one_full") == caseMarkers & @[frameworkMarker,
      mainMarker]
    let fullList = run(full, "--entrypoint=tests", "--list")
    check fullList.code == 0
    check fullList.output == (caseNames & @["block::framework"]).join("\n") &
      "\n"
    # `--list-test-cases`: the testCases alone, the names a one-test build
    # can be made for; and nothing ran, the tests: block included.
    let casesList = run(full, "--entrypoint=tests", "--list-test-cases")
    check casesList.code == 0
    check casesList.output == caseNames.join("\n") & "\n"

    for i, name in caseNames:
      let label = "one_only_" & $i
      let exe = mustBuild(label, fixture, "-d:entrypointsTest=" & name)
      check heldMarkers(label) == @[caseMarkers[i], mainMarker]
      let listed = run(exe, "--entrypoint=tests", "--list")
      check listed.code == 0
      check listed.output == name & "\n"
      check testsEntryNotes(exe) == @[name]
      let all = run(exe, "--entrypoint=tests")
      check all.code == 0
      check all.ranMarkers == @[caseMarkers[i]]
      check "1 of 1 tests passed" in all.output
      let exact = run(exe, "--entrypoint=tests", "--run-exact=" & name)
      check exact.code == 0
      check exact.ranMarkers == @[caseMarkers[i]]
      let other = caseNames[(i + 1) mod caseNames.len]
      let refused = run(exe, "--entrypoint=tests", "--run-exact=" & other)
      check refused.code == 64
      check refused.ranMarkers.len == 0
      # `main` is still the program's entry.
      let plain = run(exe)
      check plain.code == 0
      check plain.ranMarkers == @[mainMarker]

    # With -d:entrypoint=tests the binary is the one test and nothing else.
    let alone = mustBuild("one_alone_beta", fixture, "-d:entrypoint=tests",
      "-d:entrypointsTest=beta")
    check heldMarkers("one_alone_beta") == @[caseMarkers[1]]
    let r = run(alone)
    check r.code == 0
    check r.ranMarkers == @[caseMarkers[1]]
    check run(alone, "--list").output == "beta\n"
    check run(alone, "--list-test-cases").output == "beta\n"

  test "an edit of one test's body leaves the other tests' binaries alone":
    # Each binary is built from one source path into one place, then rebuilt
    # there after the edit, as a build tool rebuilds an output.
    let source = variant("one_edit_src", [])
    let builds = [("one_edit_alpha", "alpha"), ("one_edit_beta", "beta"),
      ("one_edit_gamma", "gamma"), ("one_edit_full", "")]
    var before: seq[string]
    for (label, name) in builds:
      let flags = if name.len > 0: @["-d:entrypointsTest=" & name]
                  else: newSeq[string]()
      before.add(readFile(mustBuild(label, source, flags)))
    # The edit: beta's body calls another procedure, on the same line.
    discard variant("one_edit_src", [(betaLine, betaEdited)])
    var after: seq[string]
    for (label, name) in builds:
      let flags = if name.len > 0: @["-d:entrypointsTest=" & name]
                  else: newSeq[string]()
      after.add(readFile(mustBuild(label, source, flags)))
    # Compared as booleans, so a failure does not print the binaries.
    let alphaSame = after[0] == before[0]
    let betaSame = after[1] == before[1]
    let gammaSame = after[2] == before[2]
    let fullSame = after[3] == before[3]
    check alphaSame                      # byte-identical
    check gammaSame                      # byte-identical
    # Controls: the edit is in beta's binary and in the binary of every test.
    check not betaSame
    check not fullSame
    let edited = run(binaryOf("one_edit_beta"), "--entrypoint=tests")
    check edited.code == 0
    check edited.ranMarkers == @[caseMarkers[1]]

  test "the other tests' bodies are not type-checked":
    let source = variant("one_broken_src", [(gammaLine, gammaBroken)])
    let exe = mustBuild("one_broken_alpha", source, "-d:entrypointsTest=alpha")
    check run(exe, "--entrypoint=tests").ranMarkers == @[caseMarkers[0]]
    # Control: the build of every test type-checks gamma and fails on it.
    let full = build("one_broken_full", source)
    check full.code != 0
    check "type mismatch" in full.output & full.errors

  test "a name no testCase has, and a build without the tests entry, stop the compile":
    for name in ["delta", "block::framework", "alph"]:
      let r = build("one_refused", fixture, "-d:entrypointsTest=" & name)
      check r.code != 0
      check ("-d:entrypointsTest=" & name & ": no testCase is named") in
        r.output & r.errors
    for flag in ["-d:entrypoint=main", "-d:entrypointRuntime=off"]:
      let r = build("one_refused", fixture, flag, "-d:entrypointsTest=alpha")
      check r.code != 0
      check "carries no tests entry" in r.output & r.errors
    # A bare define, and one with an empty value, which would otherwise
    # read as no define at all and build every test.
    for flag in ["-d:entrypointsTest", "-d:entrypointsTest="]:
      let bare = build("one_refused", fixture, flag)
      check bare.code != 0
      check "-d:entrypointsTest needs a test name" in bare.output & bare.errors
    # A line break, passed in one argument (the harness runs the compiler
    # without a shell).
    for name in ["alpha\nbeta", "alpha\r"]:
      let broken = build("one_refused", fixture, "-d:entrypointsTest=" & name)
      check broken.code != 0
      check "a test name holds no line break" in broken.output & broken.errors
