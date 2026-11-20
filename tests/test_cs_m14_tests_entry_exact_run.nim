## test_cs_m14_tests_entry_exact_run: `--entrypoint=tests --run-exact=<name>`
## selects exactly the test `--list` printed as `<name>`, never as a pattern,
## and test names fit on one line. This is the form a build tool uses when it
## lists a binary's tests and then runs each by the name it read.
##
## Two fixtures (`tests/fixtures/exact/`) are compiled with the real Nim and
## run, each built for every entry and for the tests alone
## (`-d:entrypoint=tests`):
##
## * `cases.nim`: `testCase`s named `a*b`, `aXb`, `a?c` and `abc`, where
##   `a*b` and `a?c` are also patterns that match the others.
## * `blocks.nim`: a module written for nim-testutils, built with this
##   repository's `compat` ahead of nim-testutils on the path, whose
##   `tests:` block holds the unittest2 tests `s::a*b`, `s::aXb` and a
##   top-level `a*b`. unittest2's own filters are patterns, so the entry
##   guards the block's tests itself. The block also holds two tests the
##   listing cannot name (`test "dyn" & "amic"`, `unittest2.test
##   "qualified"`) and calls a helper procedure named `test` in an
##   expression.
##
## Checked:
##
## * A name that contains `*` or `?` selects that test alone, in both
##   fixtures and both builds; every listed name selects exactly itself.
##   The tests the listing cannot name run without `--run-exact` and never
##   under it, and the helper call is neither listed nor guarded.
## * An unknown exact name exits 64 and names the problem and the tests, and
##   runs nothing: a name that is not listed, and a pattern that `--run`
##   would accept. `--run-exact` together with `--run` exits 64 too.
## * The list document (`entrypoints/1`) names `--run-exact` in the tests
##   entry's `args`, and its `entries` are the names `--list` prints.
## * One-line names: a `testCase` whose name holds a line break stops the
##   compile, in a build that carries the tests and in one that drops them;
##   a framework test with such a name makes `--list` exit 70 and print
##   nothing on standard output, and is not selectable by `--run-exact`.
## * Negative controls: `--run=` with the same names selects every match
##   (`a*b` runs `a*b` and `aXb`), so the fixtures can tell a pattern from an
##   exact name; and without the line-break test the blocks fixture lists
##   with exit 0.
##
## Nothing is mocked: the compiler, unittest2 and nim-testutils are the real
## ones (`tests/harness.nim` finds them, and the test fails when one is
## missing).

import std/[json, os, sets, strutils, unittest]

import harness

const
  fixtures = testsDir / "fixtures" / "exact"
  compat = repoDir / "compat"
  caseNames = ["a*b", "aXb", "a?c", "abc"]
  caseMarkers = ["EXACTMARKER star", "EXACTMARKER x", "EXACTMARKER question",
    "EXACTMARKER abc"]
  blockNames = ["s::a*b", "s::aXb", "a*b"]
  blockMarkers = ["BLOCKMARKER star", "BLOCKMARKER x", "BLOCKMARKER top star"]
  unlistedMarkers = ["BLOCKMARKER unlisted", "BLOCKMARKER qualified"]

var built: HashSet[string]

proc build(name, source: string; testutils: bool;
           flags: varargs[string]): string =
  ## Compiles a fixture once per name; returns the binary. With `testutils`
  ## nim-testutils and its packages are on the path, `compat` searched first.
  if name notin built:
    var paths = @[repoDir / "src"]
    if testutils:
      paths = @[testutilsPath()] & packagePaths() & @[compat]
    let r = compileProgram(fixtures / source, name, flags, paths)
    checkpoint(r.output & r.errors)
    require r.code == 0
    built.incl(name)
  binaryOf(name)

proc run(exe: string; args: varargs[string]): RunResult =
  result = runProgram(exe, @args)
  checkpoint(exe.extractFilename & " " & @args.join(" ") & "\n" &
    result.output & result.errors)
  require not result.timedOut

proc ranMarkers(r: RunResult; markers: openArray[string]): seq[string] =
  ## The markers the run printed, in the fixture's order.
  for m in markers:
    if m in r.output:
      result.add(m)

proc casesBinaries(): seq[(string, seq[string])] =
  ## The cases fixture built for every entry and for the tests alone, with the
  ## arguments that select the tests entry in each.
  @[(build("ex_cases", "cases.nim", false), @["--entrypoint=tests"]),
    (build("ex_cases_tests", "cases.nim", false, "-d:entrypoint=tests"),
      newSeq[string]())]

proc blocksBinaries(): seq[(string, seq[string])] =
  @[(build("ex_blocks", "blocks.nim", true), @["--entrypoint=tests"]),
    (build("ex_blocks_tests", "blocks.nim", true, "-d:entrypoint=tests"),
      newSeq[string]())]

suite "test_cs_m14_tests_entry_exact_run":

  test "--list prints the names --run-exact takes, and the list agrees":
    for (exe, sel) in casesBinaries():
      let r = run(exe, sel & @["--list"])
      check r.code == 0
      check r.output == caseNames.join("\n") & "\n"
    let blocks = blocksBinaries()
    let blocksList = run(blocks[0][0], "--entrypoint=tests", "--list")
    check blocksList.code == 0
    check blocksList.output == blockNames.join("\n") & "\n"
    # A binary built for the tests alone runs its `tests:` blocks when it
    # starts, before the entry reads `--list` (they stay at module scope), so
    # the names follow the framework's output (which does not end its last
    # line): they end standard output.
    let early = run(blocks[1][0], "--list")
    check early.code == 0
    check early.output.endsWith(blockNames.join("\n") & "\n")
    let list = parseJson(run(binaryOf("ex_cases"), "--entrypoint=list").output)
    var testsEntry: JsonNode
    for e in list["entries"]:
      if e["name"].getStr == "tests":
        testsEntry = e
    require testsEntry != nil
    check "--run-exact=<name>" in testsEntry["args"].getStr
    check "--run=<name>" in testsEntry["args"].getStr
    var listed: seq[string]
    for n in testsEntry["entries"]:
      listed.add(n.getStr)
    check listed == @caseNames

  test "a testCase name with * or ? selects only itself":
    for (exe, sel) in casesBinaries():
      for i, name in caseNames:
        let r = run(exe, sel & @["--run-exact=" & name])
        check r.code == 0
        check r.ranMarkers(caseMarkers) == @[caseMarkers[i]]
        check "1 of 1 tests passed" in r.output
      # repeated, it selects each name given and nothing else
      let two = run(exe, sel & @["--run-exact=a*b", "--run-exact=a?c"])
      check two.code == 0
      check two.ranMarkers(caseMarkers) == @[caseMarkers[0], caseMarkers[2]]

  test "a framework test name with * selects only itself":
    for (exe, sel) in blocksBinaries():
      # without --run-exact the guards let every test run, the unlisted too
      let all = run(exe, sel)
      check all.code == 0
      check all.ranMarkers(blockMarkers) == @blockMarkers
      check all.ranMarkers(unlistedMarkers) == @unlistedMarkers
      check "5 tests run" in all.output
      for i, name in blockNames:
        let r = run(exe, sel & @["--run-exact=" & name])
        check r.code == 0
        check r.ranMarkers(blockMarkers) == @[blockMarkers[i]]
        check r.ranMarkers(unlistedMarkers).len == 0
        check "1 tests run" in r.output

  test "an unknown exact name exits 64, names the problem and runs nothing":
    for (exe, sel) in casesBinaries():
      # `a*` is a pattern --run accepts (it matches three tests); `ab` is no
      # test at all
      for name in ["a*", "ab", "A*B", ""]:
        let r = run(exe, sel & @["--run-exact=" & name])
        check r.code == 64
        check ("no test is named exactly " & name.escape) in r.errors
        check "the tests are: a*b, aXb, a?c, abc" in r.errors
        check r.ranMarkers(caseMarkers).len == 0
    for (exe, sel) in blocksBinaries():
      for name in ["s::a*", "aXb", "s::a?b", "dynamic", "qualified",
                   "helper"]:
        let r = run(exe, sel & @["--run-exact=" & name])
        check r.code == 64
        check ("no test is named exactly " & name.escape) in r.errors
        check r.ranMarkers(blockMarkers).len == 0
        check r.ranMarkers(unlistedMarkers).len == 0

  test "--run-exact with --run exits 64":
    for (exe, sel) in casesBinaries() & blocksBinaries():
      let r = run(exe, sel & @["--run-exact=a*b", "--run=aXb"])
      check r.code == 64
      check "--run-exact cannot be combined with --run" in r.errors
      check r.ranMarkers(caseMarkers).len == 0
      check r.ranMarkers(blockMarkers).len == 0
      check r.ranMarkers(unlistedMarkers).len == 0

  test "negative control: --run with the same name selects every match":
    for (exe, sel) in casesBinaries():
      let star = run(exe, sel & @["--run=a*b"])
      check star.code == 0
      check star.ranMarkers(caseMarkers) == @[caseMarkers[0], caseMarkers[1]]
      let question = run(exe, sel & @["--run=a?c"])
      check question.code == 0
      check question.ranMarkers(caseMarkers) == @[caseMarkers[2],
        caseMarkers[3]]
    for (exe, sel) in blocksBinaries():
      # unittest2's filter: `s::a*b` matches `s::aXb` too, and `a*b` (no
      # suite) matches the test name in every suite
      let suiteStar = run(exe, sel & @["--run=s::a*b"])
      check suiteStar.code == 0
      check suiteStar.ranMarkers(blockMarkers) == @[blockMarkers[0],
        blockMarkers[1]]
      let star = run(exe, sel & @["--run=a*b"])
      check star.code == 0
      check star.ranMarkers(blockMarkers) == @blockMarkers

  test "a testCase name with a line break stops the compile":
    for (name, flags) in [("ex_multiline", newSeq[string]()),
                          ("ex_multiline_tests", @["-d:entrypoint=tests"]),
                          ("ex_multiline_main", @["-d:entrypoint=main"])]:
      let r = compileProgram(fixtures / "multiline_case.nim", name, flags,
        [repoDir / "src"])
      checkpoint(r.output & r.errors)
      check r.code != 0
      check "a test name must fit on one line" in r.output & r.errors
      check not fileExists(binaryOf(name))

  test "a framework test name with a line break makes --list exit 70":
    let exe = build("ex_blocks_multiline", "blocks.nim", true,
      "-d:fixtureMultiline")
    let listed = run(exe, "--entrypoint=tests", "--list")
    check listed.code == 70
    check listed.output == ""
    check ("the test name " & "first line\nsecond line".escape &
      " cannot be listed") in listed.errors
    # it cannot be selected by --run-exact either: it is not listed
    let exact = run(exe, "--entrypoint=tests",
      "--run-exact=first line\nsecond line")
    check exact.code == 64
    check "BLOCKMARKER multiline" notin exact.output
    # the other tests still run by their exact names
    let star = run(exe, "--entrypoint=tests", "--run-exact=s::a*b")
    check star.code == 0
    check star.ranMarkers(blockMarkers) == @[blockMarkers[0]]
