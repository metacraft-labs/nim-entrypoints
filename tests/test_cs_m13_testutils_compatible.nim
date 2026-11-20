## test_cs_m13_testutils_compatible: sources written for nim-testutils build
## and run through nim-entrypoints, unchanged, and behave as they did.
##
## The fixtures (`tests/fixtures/testutils/`) import nim-testutils' real
## `testutils/moduletests` and `testutils/fuzzing`. Every build is made twice
## with the real compiler: once with nim-testutils alone on the Nim path (what
## authors get today) and once with this repository's `compat` directory added
## so that it is searched first. The two are compared:
##
## * a module with `tests:` blocks and `programMain:` built for testing
##   (`-d:testutils_test_build`, what nim-testutils' runner passes) runs the
##   same tests with the same output, and the same exit code, with a failing
##   test too (the negative control: the comparison is not between two empty
##   runs); built without it, both run `programMain` and no tests;
## * `-d:testutils_test_build` and `-d:entrypoint=tests` are the same build;
## * only through nim-entrypoints can the same binary, built for everything,
##   run its tests at run time (`--entrypoint=tests`), list them and run one
##   by name, and list its entries; the other build ignores the selector;
## * the path order decides which implementation is used (compat searched
##   after nim-testutils changes nothing);
## * a fuzz source reads its input and aborts on a failing one as before, in
##   the AFL shape (standard input or a file), and exports the same libFuzzer
##   symbols, which a C driver standing in for libFuzzer's `main` calls.
##
## The dependencies are nim-testutils and its packages (unittest2, stew,
## results): `ENTRYPOINTS_TESTUTILS_PATH` and `ENTRYPOINTS_NIM_PATHS` (the
## package directories, separated like `PATH`), else a checkout of
## nim-testutils beside this repository and the nimble package store. When one
## is not there the test fails, it does not skip.

import std/[os, sets, strutils, unittest]

import harness

const
  fixtures = testsDir / "fixtures" / "testutils"
  compat = repoDir / "compat"

var built: HashSet[string]

proc build(name, source: string; shim: bool; flags: varargs[string]): string =
  ## Compiles `source`; with `shim` the compat directory is searched first.
  if name notin built:
    var paths = @[testutilsPath()] & packagePaths()
    if shim:
      paths.add(compat)      # `--path` entries are searched last-given first
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

proc normalized(r: RunResult; name: string): string =
  ## The output without what differs between builds: durations and the
  ## binary's own path (unittest2 prints it for a failure).
  normalizeTimings(r.output).replace(binaryOf(name), "<exe>")

proc same(a: RunResult; aName: string; b: RunResult; bName: string): bool =
  a.code == b.code and normalized(a, aName) == normalized(b, bName)

suite "test_cs_m13_testutils_compatible":

  test "the test build runs the same tests with the same output":
    let base = run(build("tu_base_test", "mod_units.nim", false,
      "-d:testutils_test_build"))
    let shim = run(build("tu_shim_test", "mod_units.nim", true,
      "-d:testutils_test_build"))
    check base.code == 0
    # the run is not empty: both suites and the top-level test ran
    check "doubling" in base.output and "second block" in base.output
    check "4 tests run" in base.output and "4 OK" in base.output
    check "PROGRAM MAIN" notin base.output    # programMain is skipped
    check same(base, "tu_base_test", shim, "tu_shim_test")
    check "PROGRAM MAIN" notin shim.output

  test "negative: a failing test fails both builds the same way":
    let base = run(build("tu_base_fail", "mod_units.nim", false,
      "-d:testutils_test_build", "-d:fixtureFail"))
    let shim = run(build("tu_shim_fail", "mod_units.nim", true,
      "-d:testutils_test_build", "-d:fixtureFail"))
    check base.code != 0
    check "1 FAILED" in base.output
    check same(base, "tu_base_fail", shim, "tu_shim_fail")
    # the passing build differs from the failing one (not two empty runs)
    check not same(base, "tu_base_fail", run(binaryOf("tu_base_test")),
      "tu_base_test")

  test "without the test define both run programMain and no tests":
    let base = run(build("tu_base_default", "mod_units.nim", false))
    let shim = run(build("tu_shim_default", "mod_units.nim", true))
    check base.code == 0
    check base.output.startsWith("PROGRAM MAIN 42\n")
    check "0 tests run" in base.output
    check same(base, "tu_base_default", shim, "tu_shim_default")

  test "-d:testutils_test_build is -d:entrypoint=tests":
    let viaDefine = run(binaryOf("tu_shim_test"))
    let viaEntry = run(build("tu_shim_entry_tests", "mod_units.nim", true,
      "-d:entrypoint=tests"))
    check same(viaDefine, "tu_shim_test", viaEntry, "tu_shim_entry_tests")
    check "4 tests run" in viaEntry.output
    # unittest2's own filters reach the tests, and so does `--run`
    let one = run(binaryOf("tu_shim_entry_tests"), "doubling::two")
    check "1 tests run" in one.output
    let named = run(binaryOf("tu_shim_entry_tests"), "--run=second block::*")
    check "1 tests run" in named.output
    # a binary built for the tests holds no programMain code
    check not binaryHolds("tu_shim_entry_tests", "PROGRAM MAIN")
    check binaryHolds("tu_shim_default", "PROGRAM MAIN")

  test "through nim-entrypoints the same binary runs its tests at run time":
    let exe = binaryOf("tu_shim_default")
    discard build("tu_shim_default", "mod_units.nim", true)
    let all = run(exe, "--entrypoint=tests")
    check all.code == 0
    check normalizeTimings(all.output) ==
      normalizeTimings(run(binaryOf("tu_base_test")).output)
    let one = run(exe, "--entrypoint=tests", "--run=doubling::zero")
    check one.code == 0 and "1 tests run" in one.output
    let listed = run(exe, "--entrypoint=tests", "--list")
    check listed.code == 0
    check listed.output ==
      "doubling::two\ndoubling::zero\ntop level\nsecond block::declared apart\n"
    let list = run(exe, "--entrypoint=list")
    check list.code == 0
    check "\"name\":\"tests\"" in list.output
    check "second block::declared apart" in list.output
    # the unchanged build has none of this: it is just the program
    let plain = run(binaryOf("tu_base_default"), "--entrypoint=tests")
    check plain.output.startsWith("PROGRAM MAIN 42\n")
    check "0 tests run" in plain.output
    check not binaryHolds("tu_base_default", "entrypoints/1")
    check binaryHolds("tu_shim_default", "entrypoints/1")

  test "the path order decides: compat searched after nim-testutils is unused":
    # compat given first is searched last, so the real moduletests wins
    var paths = @[compat, testutilsPath()] & packagePaths()
    let r = compileProgram(fixtures / "mod_units.nim", "tu_order_control", [],
      paths)
    checkpoint(r.output & r.errors)
    require r.code == 0
    let out1 = run(binaryOf("tu_order_control"), "--entrypoint=tests")
    check out1.output.startsWith("PROGRAM MAIN 42\n")
    check "0 tests run" in out1.output

  test "negative: unittest2 imported first cannot silently skip the tests":
    # unittest2 then reads the selector as a test filter; the probe notices
    let exe = build("tu_shim_order", "mod_order.nim", true)
    let bad = run(exe, "--entrypoint=tests")
    check bad.code == 64
    check "took the selector argument for a test filter" in bad.errors
    check "1 tests run" notin bad.output
    # with a filter of its own the run works (the filter is a union)
    let one = run(exe, "--entrypoint=tests", "--run=s::t")
    check one.code == 0 and "1 tests run" in one.output
    # the build for the tests is unaffected by the order
    let direct = run(build("tu_shim_order_ep", "mod_order.nim", true,
      "-d:entrypoint=tests"))
    check direct.code == 0 and "1 tests run" in direct.output
    # and the define that turns filtering off fixes the order problem
    let fixed = run(build("tu_shim_order_fixed", "mod_order.nim", true,
      "-d:unittest2DisableParamFiltering"), "--entrypoint=tests")
    check fixed.code == 0 and "1 tests run" in fixed.output

  test "fuzz sources behave as before (AFL shape) and fail on a bad input":
    let okBase = build("tu_base_fuzz_ok", "fuzz_ok.nim", false, "-d:release")
    let okShim = build("tu_shim_fuzz_ok", "fuzz_ok.nim", true, "-d:release")
    let bugBase = build("tu_base_fuzz_bug", "fuzz_bug.nim", false, "-d:release")
    let bugShim = build("tu_shim_fuzz_bug", "fuzz_bug.nim", true, "-d:release")
    let big = 'x'.repeat(150)
    let file = scratchRoot / "fuzz-input.txt"
    createDir(scratchRoot)
    writeFile(file, "short input")
    for (base, shim) in [(okBase, okShim), (bugBase, bugShim)]:
      for input in ["", "abc", "short input", big]:
        let rb = runProgram(base, [], input)
        let rs = runProgram(shim, [], input)
        checkpoint(base & " / " & shim & " on " & $input.len & " bytes: " &
          $rb.code & " vs " & $rs.code)
        check not rb.timedOut and not rs.timedOut
        check rb.code == rs.code
        check normalizeTimings(rb.output).splitLines.len ==
          normalizeTimings(rs.output).splitLines.len
      # the file argument is read instead of standard input
      check runProgram(base, [file]).code == runProgram(shim, [file]).code
    # the passing source passes on everything, the buggy one fails on a long
    # input: the comparison is between real outcomes
    check runProgram(okShim, [], big).code == 0
    check runProgram(bugShim, [], "short").code == 0
    let failing = runProgram(bugShim, [], big)
    check failing.code != 0
    check "Fuzzed code raised exception" in failing.output
    check "payload.len < 100" in failing.output
    check runProgram(bugBase, [], big).code != 0

  test "fuzz sources export the same libFuzzer symbols and behave alike":
    let cc = findExe("cc")
    require cc.len > 0
    for (src, name) in [("fuzz_ok.nim", "ok"), ("fuzz_bug.nim", "bug")]:
      var drivers: array[2, string]
      for i, shim in [false, true]:
        let tag = (if shim: "tu_shim_lf_" else: "tu_base_lf_") & name
        var paths = @[testutilsPath()] & packagePaths()
        if shim: paths.add(compat)
        let r = compileProgram(fixtures / src, tag,
          ["-d:release", "-d:llvmFuzzer", "--noMain", "--app:staticlib"],
          paths)
        checkpoint(r.output & r.errors)
        require r.code == 0
        let lib = scratchRoot / tag / "lib" & tag & ".a"
        # nim names the output as given; the static library is `-o:` as is
        let archive = if fileExists(lib): lib else: binaryOf(tag)
        let drv = scratchRoot / tag / (tag & "_driver")
        let link = runProgram(cc, [fixtures / "driver.c", archive, "-lm",
          "-o", drv])
        checkpoint(link.output & link.errors)
        require link.code == 0
        drivers[i] = drv
      for input in ["", "abcd", 'x'.repeat(150)]:
        let rb = runProgram(drivers[0], [input])
        let rs = runProgram(drivers[1], [input])
        checkpoint(name & " on " & $input.len & " bytes: " & $rb.code &
          " vs " & $rs.code & "\n" & rb.output & rs.output)
        check not rb.timedOut and not rs.timedOut
        check rb.code == rs.code
        check "returned" in rs.output or "Fuzzed code" in rs.output
      # the harness really ran the target: the buggy one fails on 150 bytes
      let failing = runProgram(drivers[1], ['x'.repeat(150)])
      check (failing.code != 0) == (name == "bug")
