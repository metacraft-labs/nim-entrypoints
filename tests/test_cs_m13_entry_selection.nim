## test_cs_m13_entry_selection: a program with a `main:` block and test,
## self-description and fuzz entries (`tests/fixtures/selection/fixture.nim`)
## is compiled with the real Nim and run, many ways.
##
## * With no define it runs `main`; its list names every entry.
## * Every entry runs when named at run time (`--entrypoint=<name>`, and the
##   two-word `--entrypoint <name>`), and when the binary is built for it
##   (`-d:entrypoint=<name>`), each time doing its own work: the tests list,
##   run all, run one by name and fail the process when a test fails; the
##   self-description entries print a completion answer, a script, the help
##   JSON and the configuration keys; the fuzz entry reads its input from
##   standard input or a file and aborts on a failing input.
## * The run-time selector is in no help screen, no completion answer and no
##   script (it is an internal parameter of the clispec description), is
##   listed as internal by the machine-readable help, and still works when
##   given anywhere but first: it fills the configuration field.
## * A binary built for one entry holds no code of the others: marker strings
##   that only the other entries print are absent from the binary, and
##   `-d:entrypointRuntime=off` removes the selector and the list.
## * Negative controls: an unknown entry (at run time and at compile time)
##   fails with an error naming the entries that exist, an entry that needs
##   its own binary refuses to run at run time and says what to build, a
##   failing test makes the tests entry fail, and the selector is not taken
##   when it is not the first argument.
##
## Nothing is mocked: the compiler and the fixture binaries run for real.

import std/[json, os, sets, strutils, unittest]

import harness

const
  fixture = testsDir / "fixtures" / "selection" / "fixture.nim"
  entryNames = ["tests", "complete", "completion", "help-json",
    "config-schema", "fuzz-len", "compile-only"]
    ## The fixture's entries, in the order the fixture registers them (the
    ## tests library first, then the describe entries, then the fixture's own).
  runtimeEntries = ["tests", "complete", "completion", "help-json",
    "config-schema", "fuzz-len"]
  allEntries = ["main", "tests", "complete", "completion", "help-json",
    "config-schema", "fuzz-len", "compile-only"]

var built: HashSet[string]

proc build(name: string; flags: varargs[string]): string =
  ## Compiles the fixture once per name; returns the binary.
  if name notin built:
    let r = compileProgram(fixture, name, flags,
      [repoDir / "src", clispecPath()])
    checkpoint(r.output & r.errors)
    require r.code == 0
    built.incl(name)
  binaryOf(name)

proc defaultBinary(): string = build("fx_default")

proc compileTimeBinary(entry: string): string =
  build("fx_ct_" & entry, "-d:entrypoint=" & entry)

proc runWith(exe: string; args: seq[string]; input = "";
             env: openArray[(string, string)] = []): RunResult =
  result = runProgram(exe, args, input, env)
  checkpoint(exe.extractFilename & " " & args.join(" ") & "\n" &
    result.output & result.errors)
  require not result.timedOut

proc run(exe: string; args: varargs[string]): RunResult =
  runWith(exe, @args)

proc listOf(exe: string): JsonNode =
  let r = run(exe, "--entrypoint=list")
  require r.code == 0
  parseJson(r.output)

proc entryNamesIn(list: JsonNode): seq[string] =
  for e in list["entries"]:
    result.add(e["name"].getStr)

suite "test_cs_m13_entry_selection":

  test "with no define the program runs main":
    let r = run(defaultBinary())
    check r.code == 0
    check r.output == "MAINMARKER verbose=false selector=[]\n"
    # none of the other entries ran, and a `tests:` block did not run
    for marker in ["TESTMARKER", "FUZZMARKER", "COMPILEONLYMARKER"]:
      check marker notin r.output
    # main's arguments are the program's own, parsed by its clispec description
    let r2 = run(defaultBinary(), "--verbose", "run", "x")
    check r2.output == "MAINMARKER verbose=true selector=[]\n"

  test "the list names every entry, main first, with how each is selected":
    let list = listOf(defaultBinary())
    check list["schema"].getStr == "entrypoints/1"
    check list["program"].getStr == "fixture"
    check list["default"].getStr == "main"
    check entryNamesIn(list) == @allEntries
    for e in list["entries"]:
      let select = e["select"]
      let name = e["name"].getStr
      check e["doc"].getStr.len > 0
      if name == "compile-only":
        check select == %*["compiletime"]
      else:
        check select == %*["compiletime", "runtime"]
    # the tests entry lists its tests; the others carry no contributions
    var testsEntry: JsonNode
    for e in list["entries"]:
      if e["name"].getStr == "tests":
        testsEntry = e
      else:
        check not e.hasKey("entries")
    check testsEntry["entries"] ==
      %*["passes", "also-passes", "fails-when-asked"]
    check testsEntry["args"].getStr.len > 0
    # listing runs nothing
    let r = run(defaultBinary(), "--entrypoint=list")
    check "MAINMARKER" notin r.output and r.errors == ""

  test "the manifest the compiler writes is the list the binary prints":
    let manifest = scratchRoot / "fx_manifest.json"
    createDir(scratchRoot)
    if fileExists(manifest):
      removeFile(manifest)
    let exe = build("fx_manifest", "-d:entrypointsManifest=" & manifest)
    check fileExists(manifest)
    let written = parseJson(readFile(manifest))
    check written == listOf(exe)
    check written == listOf(defaultBinary())
    check entryNamesIn(written) == @allEntries
    # a binary built for one entry writes that entry's manifest
    let one = scratchRoot / "fx_manifest_tests.json"
    if fileExists(one):
      removeFile(one)
    discard build("fx_manifest_fuzz", "-d:entrypoint=fuzz-len",
      "-d:entrypointsManifest=" & one)
    let oneDoc = parseJson(readFile(one))
    check entryNamesIn(oneDoc) == @["fuzz-len"]
    check oneDoc["default"].getStr == "fuzz-len"
    check oneDoc["entries"][0]["doc"].getStr == "fuzz the input length"

  test "at run time each entry does its own work":
    let exe = defaultBinary()
    # tests: run all
    var r = run(exe, "--entrypoint=tests")
    check r.code == 0
    check "TESTMARKER block ran" in r.output
    check "[OK] passes" in r.output and "[OK] also-passes" in r.output
    check "3 of 3 tests passed" in r.output
    check "MAINMARKER" notin r.output
    # the two-word spelling of the selector
    r = run(exe, "--entrypoint", "tests", "--run=passes")
    check r.code == 0 and "[OK] passes" in r.output
    # tests: list (nothing runs)
    r = run(exe, "--entrypoint=tests", "--list")
    check r.code == 0
    check r.output == "passes\nalso-passes\nfails-when-asked\n"
    # tests: run one by name
    r = run(exe, "--entrypoint=tests", "--run=also-passes")
    check r.code == 0
    check "TESTMARKER also-passes" in r.output
    check "TESTMARKER passes" notin r.output
    check "1 of 1 tests passed" in r.output
    # self-description
    r = run(exe, "--entrypoint=complete", "zsh", "")
    check r.code == 0 and r.output == "run\tRun something\n"
    r = run(exe, "--entrypoint=complete", "zsh", "run", "--ver")
    check r.output == "--verbose\tTalk more\n"
    r = run(exe, "--entrypoint=completion", "zsh")
    check r.code == 0
    check "_clispec_complete_fx" in r.output
    check "--entrypoint=complete" in r.output
    r = run(exe, "--entrypoint=help-json", "run")
    check r.code == 0
    check parseJson(r.output)["command"]["path"] == %*["run"]
    r = run(exe, "--entrypoint=config-schema")
    check r.code == 0
    check parseJson(r.output)["schema"].getStr == "entrypoints-config/1"
    # the fuzz entry: input on standard input, then in a file
    r = runWith(exe, @["--entrypoint=fuzz-len"], input = "abc\n")
    check r.code == 0 and "FUZZMARKER input of 3 bytes" in r.output
    let input = scratchRoot / "fuzz-input.bin"
    createDir(scratchRoot)
    writeFile(input, "xy")
    r = run(exe, "--entrypoint=fuzz-len", input)
    check r.code == 0 and "FUZZMARKER input of 2 bytes" in r.output
    # main by name
    r = run(exe, "--entrypoint=main", "--verbose")
    check r.output == "MAINMARKER verbose=true selector=[]\n"

  test "a failing input aborts the fuzz entry and a failing test fails tests":
    let exe = defaultBinary()
    var r = runWith(exe, @["--entrypoint=fuzz-len"], input = "abcdefgh")
    check r.code != 0
    check "Fuzzed code raised exception" in r.output
    check "FUZZMARKER input too long" in r.output
    r = runWith(exe, @["--entrypoint=tests"], env = [("FX_FAIL", "1")])
    check r.code == 1
    check "[FAILED] fails-when-asked: TESTMARKER failing on request" in
      r.output
    check "2 of 3 tests passed" in r.output
    r = runWith(exe, @["--entrypoint=tests", "--run=fails-when-asked"],
      env = [("FX_FAIL", "1")])
    check r.code == 1
    # the same test passes when nothing makes it fail
    r = run(exe, "--entrypoint=tests", "--run=fails-when-asked")
    check r.code == 0

  test "each entry runs when the binary is built for it":
    # (one build per entry; the input and the expected output are the entry's)
    var r = run(compileTimeBinary("main"), "--verbose")
    check r.code == 0 and r.output == "MAINMARKER verbose=true selector=[]\n"
    r = run(compileTimeBinary("tests"))
    check r.code == 0
    check "TESTMARKER block ran" in r.output and
      "3 of 3 tests passed" in r.output
    r = run(compileTimeBinary("tests"), "--run=passes")
    check "1 of 1 tests passed" in r.output
    r = run(compileTimeBinary("complete"), "zsh", "run", "--ver")
    check r.output == "--verbose\tTalk more\n"
    r = run(compileTimeBinary("completion"), "bash")
    check r.code == 0 and "_clispec_complete_fx" in r.output
    r = run(compileTimeBinary("help-json"))
    check r.code == 0
    check parseJson(r.output)["schema"].getStr == "clispec-help/1"
    r = run(compileTimeBinary("config-schema"))
    check r.code == 0
    check parseJson(r.output)["program"].getStr == "fx"
    r = runWith(compileTimeBinary("fuzz-len"), @[], input = "ab")
    check r.code == 0 and "FUZZMARKER input of 2 bytes" in r.output
    r = run(compileTimeBinary("compile-only"))
    check r.code == 0 and r.output == "COMPILEONLYMARKER\n"

  test "a binary built for one entry lists that entry and holds no other":
    for entry in allEntries:
      let exe = compileTimeBinary(entry)
      var list: JsonNode
      if entry == "tests":
        # the `tests:` block of a binary built for the tests runs when the
        # process starts, before the list is answered (see entrypoints/tests):
        # the list is the last line of the output
        let r = run(exe, "--entrypoint=list")
        require r.code == 0
        list = parseJson(r.output.strip.splitLines[^1])
      else:
        list = listOf(exe)
      check list["default"].getStr == entry
      check entryNamesIn(list) == @[entry]
    # the markers each entry's code alone holds
    const markers = [
      ("main", "MAINMARKER"), ("tests", "TESTMARKER"),
      ("fuzz-len", "FUZZMARKER"), ("compile-only", "COMPILEONLYMARKER"),
      ("config-schema", "entrypoints-config/1"),
      ("completion", "_clispec_complete_"),
      ("complete", "answer a shell's completion request"),
      ("help-json", "print the machine-readable help")]
    for entry in allEntries:
      let name = "fx_ct_" & entry
      discard compileTimeBinary(entry)
      for (owner, marker) in markers:
        check binaryHolds(name, marker) == (owner == entry)
    # the binary that carries every entry holds every marker of the entries
    # it can run (the compile-only entry is not in it)
    discard defaultBinary()
    for (owner, marker) in markers:
      checkpoint(owner & ": " & marker)
      check binaryHolds("fx_default", marker) == (owner != "compile-only")
    # and the others are smaller than the whole
    let whole = getFileSize(binaryOf("fx_default"))
    for entry in allEntries:
      check getFileSize(binaryOf("fx_ct_" & entry)) < whole
    echo "binary sizes: whole ", whole, ", main ",
      getFileSize(binaryOf("fx_ct_main")), ", tests ",
      getFileSize(binaryOf("fx_ct_tests"))

  test "-d:entrypointRuntime=off removes the selector and the list":
    let exe = build("fx_runtime_off", "-d:entrypointRuntime=off")
    # main is all it runs: the selector is an ordinary argument, which the
    # clispec description accepts as its internal parameter
    var r = run(exe, "--entrypoint=tests")
    check r.code == 0
    check r.output == "MAINMARKER verbose=false selector=[tests]\n"
    r = run(exe, "--entrypoint=list")
    check "entrypoints/1" notin r.output
    check r.output == "MAINMARKER verbose=false selector=[list]\n"
    check not binaryHolds("fx_runtime_off", "entrypoints/1")
    check not binaryHolds("fx_runtime_off", "unknown entry")
    check binaryHolds("fx_default", "entrypoints/1")
    check binaryHolds("fx_default", "unknown entry")
    check getFileSize(binaryOf("fx_runtime_off")) <
      getFileSize(binaryOf("fx_default"))
    # without the selector, the other entries are not in the binary either
    check not binaryHolds("fx_runtime_off", "FUZZMARKER")
    check not binaryHolds("fx_runtime_off", "TESTMARKER")

  test "the run-time selector is in no help screen":
    let exe = defaultBinary()
    for args in [@["--help"], @["-h"], @["run", "--help"]]:
      let r = runWith(exe, args)
      check "entrypoint" notin r.output
      check "entrypoint" notin r.errors
    # a help screen that is shown at all (the check above is not vacuous)
    check "--verbose" in run(exe, "--help").output
    # completion never offers it, at the root or under a subcommand
    for words in [@["--"], @["run", "--"], @["--e"], @["run", "--e"]]:
      let r = runWith(exe, @["--entrypoint=complete", "zsh"] & words)
      check "entrypoint" notin r.output
      if words == @["--"]:
        check "--verbose" in r.output
    # the generated scripts (which would repeat any flag) do not name it as a
    # parameter: they call the complete entry through it, nothing else
    for shell in ["bash", "zsh", "fish", "powershell"]:
      let script = run(exe, "--entrypoint=completion", shell).output
      check script.len > 0
      check script.count("entrypoint") == script.count("--entrypoint=complete")
    # the machine-readable help lists it, marked internal, and nothing else
    # about it is hidden
    for path in [@[], @["run"]]:
      let doc = parseJson(runWith(exe, @["--entrypoint=help-json"] & path).output)
      var found = false
      for p in doc["command"]["parameters"]:
        if p["name"].getStr == "entrypoint":
          found = true
          check p["visibility"].getStr == "internal"
      check found
      check "entrypoint" notin $doc["command"]["help"]
    # and it works: given anywhere but first, it fills the configuration
    var r = run(exe, "--verbose", "--entrypoint=tests")
    check r.output == "MAINMARKER verbose=true selector=[tests]\n"
    r = run(exe, "run", "--entrypoint", "x")
    check r.output == "MAINMARKER verbose=false selector=[x]\n"
    check "TESTMARKER" notin r.output

  test "negative: selecting an unknown entry fails and names the known ones":
    let exe = defaultBinary()
    for args in [@["--entrypoint=nonesuch"], @["--entrypoint", "nonesuch"]]:
      let r = runWith(exe, args)
      check r.code == 64
      check r.output == ""
      check "unknown entry 'nonesuch'" in r.errors
      for name in @["main"] & @runtimeEntries:
        check name in r.errors
      # `main` ran no code
      check "MAINMARKER" notin r.output
    # an entry that exists but needs its own binary says how to build it
    var r = run(exe, "--entrypoint=compile-only")
    check r.code == 64
    check "cannot be selected at run time" in r.errors
    check "-d:entrypoint=compile-only" in r.errors
    check "COMPILEONLYMARKER" notin r.output
    # no name
    r = run(exe, "--entrypoint")
    check r.code == 64 and "needs an entry name" in r.errors
    # the same, from a binary built for another entry
    r = run(compileTimeBinary("tests"), "--entrypoint=main")
    check r.code == 64
    check "built for the 'tests' entry only" in r.errors
    check "MAINMARKER" notin r.output
    # at compile time
    let bad = compileProgram(fixture, "fx_unknown_entry",
      ["-d:entrypoint=nonesuch"], [repoDir / "src", clispecPath()])
    check bad.code != 0
    let message = bad.output & bad.errors
    check "no such entry" in message
    for name in allEntries:
      if name != "main":
        check name in message
    check not fileExists(binaryOf("fx_unknown_entry"))
    # the same fixture builds when the name is a real one (the control)
    check fileExists(compileTimeBinary("tests"))

  test "negative: an entry that is not selectable at compile time is refused":
    # a runtime-only entry cannot be the target of -d:entrypoint
    let src = scratchRoot / "runtime_only.nim"
    createDir(scratchRoot)
    writeFile(src, """
import entrypoints
entryPoint "late", select = {runTime}:
  echo "LATE"
main:
  echo "MAIN"
""")
    let bad = compileProgram(src, "fx_runtime_only_bad",
      ["-d:entrypoint=late"], [repoDir / "src"])
    check bad.code != 0
    check "cannot be selected at compile time" in bad.output & bad.errors
    check "'late'" in bad.output & bad.errors
    let good = compileProgram(src, "fx_runtime_only_good", [],
      [repoDir / "src"])
    check good.code == 0
    check run(binaryOf("fx_runtime_only_good"), "--entrypoint=late").output ==
      "LATE\n"

  test "negative: an entry registered after main: is a compile error":
    let src = scratchRoot / "late_entry.nim"
    createDir(scratchRoot)
    writeFile(src, """
import entrypoints
main:
  echo "MAIN"
entryPoint "late":
  echo "LATE"
""")
    let bad = compileProgram(src, "fx_late_entry", [], [repoDir / "src"])
    check bad.code != 0
    check "registered after `main:`" in bad.output & bad.errors
    check "move the entryPoint above" in bad.output & bad.errors

  test "the bodies of unselected entries are not even type-checked":
    # a body that cannot compile belongs to an entry another binary selects
    let src = scratchRoot / "unchecked_body.nim"
    createDir(scratchRoot)
    writeFile(src, """
import entrypoints
entryPoint "broken", select = {compileTime}:
  let x: int = "not an int"
  echo undeclaredName
entryPoint "fine":
  echo "FINE"
main:
  echo "MAIN"
""")
    let ok = compileProgram(src, "fx_unchecked_fine", ["-d:entrypoint=fine"],
      [repoDir / "src"])
    checkpoint(ok.output & ok.errors)
    check ok.code == 0
    check run(binaryOf("fx_unchecked_fine")).output == "FINE\n"
    let okMain = compileProgram(src, "fx_unchecked_main",
      ["-d:entrypoint=main"], [repoDir / "src"])
    check okMain.code == 0
    # the control: the broken entry's own binary does not compile
    let bad = compileProgram(src, "fx_unchecked_broken",
      ["-d:entrypoint=broken"], [repoDir / "src"])
    check bad.code != 0
    check "type mismatch" in bad.output & bad.errors
