## Helpers the tests share: where the repository and its optional
## dependencies are, compiling a fixture with the Nim that runs the test, and
## running a program with a deadline. Nothing here mocks anything.

import std/[algorithm, os, osproc, streams, strtabs, strutils]

const
  testsDir* = currentSourcePath().parentDir()
  repoDir* = testsDir.parentDir()
  scratchRoot* = repoDir / ".nimcache" / "test-builds"
    ## Where fixture builds go: inside the checkout, which `.gitignore` covers.

type RunResult* = object
  output*: string
    ## Standard output.
  errors*: string
    ## Standard error.
  code*: int
  timedOut*: bool

proc firstExistingDir(candidates: openArray[string]): string =
  for c in candidates:
    if c.len > 0 and dirExists(c):
      return c

proc clispecPath*(): string =
  ## The directory to put on the Nim path to import clispec, an optional
  ## dependency: `ENTRYPOINTS_CLISPEC_PATH`, else a checkout beside this one.
  result = firstExistingDir([getEnv("ENTRYPOINTS_CLISPEC_PATH"),
    repoDir.parentDir() / "wt-cli-spec" / "src",
    repoDir.parentDir() / "nim-cli-spec" / "src"])
  doAssert result.len > 0, "clispec is not on hand: set " &
    "ENTRYPOINTS_CLISPEC_PATH to the `src` directory of nim-cli-spec"

proc nimbleDep*(name: string): string =
  ## A package's directory in the nimble package store, the newest by name.
  let pkgs = getHomeDir() / ".nimble" / "pkgs2"
  var found: seq[string]
  if dirExists(pkgs):
    for kind, path in walkDir(pkgs):
      if kind == pcDir and path.extractFilename.startsWith(name & "-"):
        found.add(path)
  if found.len > 0:
    found.sort()
    return found[^1]

proc depPath*(name, envVar: string; siblings: openArray[string]): string =
  ## Where a package is: the environment variable, else a checkout beside
  ## this one, else the nimble package store. Empty when nowhere.
  result = getEnv(envVar)
  if result.len > 0:
    return
  for s in siblings:
    if dirExists(repoDir.parentDir() / s):
      return repoDir.parentDir() / s
  result = nimbleDep(name)

proc testutilsPath*(): string =
  ## nim-testutils' checkout: `ENTRYPOINTS_TESTUTILS_PATH`, else a checkout
  ## beside this one, else the nimble package store.
  result = depPath("testutils", "ENTRYPOINTS_TESTUTILS_PATH",
    ["nim-testutils", "wt-testutils"])
  doAssert result.len > 0 and fileExists(result / "testutils" / "moduletests.nim"),
    "nim-testutils is not on hand: set ENTRYPOINTS_TESTUTILS_PATH to its checkout"

proc packagePaths*(): seq[string] =
  ## The packages nim-testutils needs (unittest2, stew, results):
  ## `ENTRYPOINTS_NIM_PATHS` (separated like `PATH`), else the nimble
  ## package store.
  let given = getEnv("ENTRYPOINTS_NIM_PATHS")
  if given.len > 0:
    for p in given.split(PathSep):
      if p.len > 0: result.add(p)
  for pkg in ["unittest2", "stew", "results"]:
    var present = false
    for p in result:
      if (p / (pkg & ".nim")).fileExists or dirExists(p / pkg):
        present = true
    if not present:
      let dir = nimbleDep(pkg)
      doAssert dir.len > 0, "the package '" & pkg & "' (needed by " &
        "nim-testutils) is not on hand: set ENTRYPOINTS_NIM_PATHS"
      result.add(dir)

proc runProgram*(exe: string; args: openArray[string] = [];
                 input = ""; env: openArray[(string, string)] = [];
                 timeoutMs = 60_000): RunResult =
  ## Runs `exe` with `args`, feeds `input` to its standard input, and kills it
  ## (by the pid this started) after `timeoutMs`.
  var environment = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    environment[k] = v
  for (k, v) in env:
    environment[k] = v
  let p = startProcess(exe, args = @args, env = environment, options = {})
  if input.len > 0:
    p.inputStream.write(input)
  p.inputStream.close()
  let code = p.waitForExit(timeoutMs)
  if p.running:
    result.timedOut = true
    p.kill()
    discard p.waitForExit(5000)
  result.output = p.outputStream.readAll()
  result.errors = p.errorStream.readAll()
  result.code = if result.timedOut: -1 else: code
  p.close()

proc compileProgram*(source, name: string; flags: openArray[string] = [];
                     paths: openArray[string] = []): RunResult =
  ## Compiles `source` with the Nim that runs this test, hermetically,
  ## into `scratchRoot / name`. Returns the compiler's output; the binary is
  ## `scratchRoot / name / name`.
  let dir = scratchRoot / name
  createDir(dir)
  var args = @["c", "--hints:off", "--warnings:off", "--skipParentCfg",
    "--skipUserCfg", "--nimcache:" & (dir / "nimcache"),
    "-o:" & (dir / name)]
  for p in paths:
    args.add("--path:" & p)
  for f in flags:
    args.add(f)
  args.add(source)
  result = runProgram(getCurrentCompilerExe(), args, timeoutMs = 600_000)

proc binaryOf*(name: string): string =
  scratchRoot / name / name

proc binaryHolds*(name, text: string): bool =
  ## Whether the compiled binary contains `text` (as `strings` would find it).
  readFile(binaryOf(name)).contains(text)

proc normalizeTimings*(s: string): string =
  ## unittest2 prints each suite's duration, `(0.00s)`; make runs comparable.
  var i = 0
  while i < s.len:
    if s[i] == '(' and i + 1 < s.len and s[i + 1] in {'0'..'9'}:
      let close = s.find("s)", i)
      if close > 0 and s[i + 1 ..< close].allCharsInSet({'0'..'9', '.'}):
        result.add("(Ns)")
        i = close + 2
        continue
    result.add(s[i])
    inc i
