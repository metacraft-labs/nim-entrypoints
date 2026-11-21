# nim-entrypoints

A small Nim library that lets one program have several entry points. The
program writes its ordinary entry in a `main:` block; libraries register
further entries: running the program's tests, describing its command line
(shell completion, help as JSON, its configuration keys), fuzz targets, and
whatever else a project wants to run from the same binary or the same source.
An entry is chosen at compile time, which builds a binary for that entry
alone, or at run time, by naming it in the first argument. A binary lists the
entries it carries, so a tool that builds or runs it can discover them without
running `main`.

The library follows [nim-chronicles](https://github.com/status-im/nim-chronicles)'
approach to configuration: compile-time knobs decide which run-time features
exist, and what a program does not use leaves no code in it. An entry whose
library the program does not import is not there; a binary built for one entry
holds none of the others' code; a binary can drop the run-time selector too.

```nim
import entrypoints
import entrypoints/tests

testCase "addition":
  doAssert 1 + 1 == 2

main:
  echo "the program"
```

```sh
nim c prog.nim
./prog                          # runs main
./prog --entrypoint=tests       # runs the tests
./prog --entrypoint=list        # the entries, as JSON

nim c -d:entrypoint=tests prog.nim   # a binary for the tests; main is not in it
```

The library needs only the standard library. Two optional modules,
`entrypoints/clispec` and `entrypoints/describe`, work with
[nim-cli-spec](https://github.com/metacraft-labs/nim-cli-spec) (clispec) and
are imported only by programs that use it.

## The pieces

| Module                 | Provides                                                                                                             |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `entrypoints`          | `main:`, `entryPoint "<name>":`, `entryArgs()`, `selectedEntry()`, the list, compile-time and run-time selection     |
| `entrypoints/tests`    | the `tests` entry: `testCase`, `tests:` blocks, list / run all / run one by name                                     |
| `entrypoints/fuzz`     | `fuzzTarget "<name>":` entries: AFL-style input from a file or standard input, and libFuzzer's exports               |
| `entrypoints/describe` | `describeProgram(Tool)`: the `complete`, `completion`, `help-json` and `config-schema` entries for a clispec program |
| `entrypoints/clispec`  | `cliProgramWithEntryPoint`, `entryPointParameter()`: the run-time selector as a clispec internal parameter           |
| `compat/testutils/`    | drop-in `testutils/moduletests` and `testutils/fuzzing` for sources written for nim-testutils                        |

## Declaring entries

`main:` is the program's ordinary entry. Its body is the body of a procedure,
so its variables are local to it. It closes the registry of entries and emits
the dispatcher, so it comes last in the main module.

`entryPoint "<name>":` registers another entry:

```nim
import entrypoints

entryPoint "version", doc = "print the version and exit",
           select = {compileTime, runTime}:     # the default: both
  echo "1.2.3"

entryPoint "selftest", doc = "check the installation", args = "[--quick]":
  let args = entryArgs()                         # the entry's own arguments
  if "--quick" in args: echo "quick check"
  result = 0                                     # the process's exit code

main:
  echo "the program"
```

- The name matches `[a-z][a-z0-9-]*`. `main` belongs to the `main:` block and
  `list` to the list.
- `select` says how the entry can be chosen: `compileTime`
  (`-d:entrypoint=<name>`), `runTime` (the first argument), or both. An entry
  that needs a binary of its own, as a libFuzzer harness does, is
  `{compileTime}` only.
- The body is the body of a `proc (): int`: `result`, `return` or `quit` give
  the process's exit code, 0 by default.
- `doc` is the line the list shows; `args` describes the entry's arguments
  for the list.
- A library packages an entry as a template or macro that expands to
  `entryPoint`. `addEntryNote(entry, note)` lets many modules contribute lines
  to one entry's list (every test of every module, for the tests entry).

Entries are registered in the order the compiler sees them, in a compile-time
table that is not part of the binary. An `entryPoint` written after `main:` is
a compile-time error that says to move it above.

## Choosing an entry

**Compile time.** With no define, every registered entry is compiled in and
those that allow it can be chosen at run time. `-d:entrypoint=<name>` builds
for that entry only: every other entry's `entryPoint` expands to nothing (its
body is not even type-checked, so a library's other entries need not compile
for this binary's target), `main:`'s body is skipped, and the dispatcher is
the one call. `-d:entrypoint=main` builds `main` only. An unknown name stops
the compile and lists the registered ones; an entry that does not allow
`compileTime` is refused by name.

`-d:entrypointRuntime=off` removes the run-time selector and the list from a
binary that carries every entry: it runs `main`, and the code that reads the
arguments for the selector is not compiled.

**Run time.** The selector is the _first_ argument: `--entrypoint=<name>` or
`--entrypoint <name>`. It is taken before `main` runs, and the rest of the
arguments belong to the entry (`entryArgs()`). Since only the first argument is
looked at, the selector cannot collide with a program's own parameters.

An unknown name prints an error naming the entries and exits with code 64
(`EX_USAGE`); an entry the binary has but that cannot be chosen at run time
says it needs `-d:entrypoint=<name>`. A binary built for one entry accepts
that entry's name, answers `--entrypoint=list`, and refuses any other.

`selectedEntry()` returns the entry the process runs.

## The list

`--entrypoint=list` prints one JSON document and exits without running
anything else:

```json
{
  "schema": "entrypoints/1",
  "program": "prog",
  "default": "main",
  "entries": [
    {
      "name": "main",
      "doc": "run the program",
      "select": ["compiletime", "runtime"]
    },
    {
      "name": "tests",
      "doc": "run the program's tests",
      "select": ["compiletime", "runtime"],
      "args": "[--list] [--list-test-cases] [--run=<name>]... [--run-exact=<name>]... [<test framework options>]",
      "entries": ["addition"]
    }
  ]
}
```

`default` is the entry that runs with no selector: `main`, or the one a binary
was built for. `entries` of an entry holds what its library contributed.

A tool that cannot run the binary (a cross-compiled one) passes
`-d:entrypointsManifest=<path>` at compile time and the compiler writes the
same document to `path`, so discovery never needs to execute the program.

## Tests

`import entrypoints/tests` registers the `tests` entry.

```nim
import entrypoints
import entrypoints/tests

testCase "addition":                 # passes when the body returns,
  doAssert 1 + 1 == 2                # fails when it raises

tests:                               # a block of a test framework's tests,
  suite "strings":                   # run when the program starts
    test "length":
      check "abc".len == 3           # (with unittest2 imported)

main:
  echo "the program"
```

- `prog --entrypoint=tests` runs everything; the exit code is 0 only when
  every selected test passed.
- `prog --entrypoint=tests --list` prints the test names, one per line, and
  runs nothing. They are also in the entry's list. A `tests:` block's
  `suite "..."` and `test "..."` calls with literal names are found without
  running it; names under a `when` are listed at run time only.
- `prog --entrypoint=tests --list-test-cases` prints only the `testCase`
  names, in the same order and with the same checks: the tests that
  `-d:entrypointsTest=<name>` (below) can build alone. A build tool that
  builds one binary per test compares it with `--list` to refuse a `tests:`
  block's test before it compiles anything.
- `prog --entrypoint=tests --run=<name>` runs the tests with that name (repeat
  `--run`; `*` and `?` match, and a test framework's `suite::name` spelling
  works). Arguments the framework takes itself pass through to it.
- `prog --entrypoint=tests --run-exact=<name>` runs the test whose name is
  exactly `<name>` as `--list` printed it, never read as a pattern: a test
  named `a*b` runs alone, not with `aXb`. This is the form for a build tool
  that lists a binary's tests and runs each by the name it read. A name that
  `--list` does not print exits with code 64 and says so, and so does
  `--run-exact` together with `--run`; `--run-exact` can be repeated. In a
  `tests:` block, the entry runs each `test "..."` call with a literal name
  only when its listed name was given, and a `test` call that `--list` does
  not name (its name is not a literal, or it is written `unittest2.test`)
  not at all, rather than hand the name to the framework, whose filters are
  patterns.
- Test names fit on one line. A `testCase` name with a line break stops the
  compile; a framework test with such a name makes `--list` exit with code
  70, naming it, before it prints anything.
- `nim c -d:entrypoint=tests prog.nim` builds a binary for the tests alone,
  with no `main` in it. Its `tests:` blocks stay where they are written (at
  module scope), so declarations in them are visible to the rest of the
  module, and run when the process starts.
- `nim c -d:entrypointsTest=<name> prog.nim` builds a binary for the one
  `testCase` named `<name>`, as `--list` prints it. Every other `testCase`
  expands to nothing (its body is not type-checked and its name is not in
  the binary), and `tests:` blocks leave no code, since a framework runs a
  block's tests together. The binary lists and runs that one test, and
  `main` is still in it unless `-d:entrypoint=tests` is given too. A test's
  binary therefore stays byte-identical when only another test's body
  changes, as long as its own lines do not move (their numbers are in the
  binary, for stack traces), so a build tool that keys each test's run on
  its binary reruns only the edited test. A name that no `testCase` has (a
  `tests:` block's test included), and a build without the tests entry,
  stop the compile.
- In a build that carries `main` as well, a `tests:` block is guarded by the
  run-time selection and is a block of its own (so an `import` inside it must
  move out); in a build for another entry it leaves no code and is not
  type-checked.
- A framework that reads the process's arguments itself sees the selector as
  a first argument, and would take it for a test filter that nothing matches,
  so every test is skipped and the run passes. Give such a framework
  `entryArgs()` instead, or turn its argument reading off: with `std/unittest`
  call `disableParamFiltering()` first in the block. unittest2 needs nothing
  when it is used through `compat/testutils/moduletests` (below), which hands
  it the entry's arguments.

## Fuzz targets

```nim
import entrypoints
import entrypoints/fuzz

fuzzTarget "parser":
  init:                        # optional; once for libFuzzer, each run for AFL
    warmUp()
  discard parse(payload)       # `payload` holds the input bytes

main:
  runTheProgram()
```

The target is the entry `fuzz-parser`. At run time it reads its input from the
file named by its first argument, or from standard input, and runs the body
once on it; an exception the body does not handle is reported and aborts the
process, so a fuzzer sees a crash. Build with
`-d:llvmFuzzer --noMain -d:entrypoint=fuzz-parser` for a libFuzzer harness:
the binary exports `LLVMFuzzerInitialize` and `LLVMFuzzerTestOneInput`, and has
no dispatcher, since libFuzzer supplies the `main`. (`-d:honggfuzz` selects
honggfuzz's use of the same exports.)

## Describing a program with clispec

`entrypoints/clispec` declares the run-time selector in a clispec command-line
description as an internal parameter: help never shows it, completion never
offers it, the machine-readable help lists it marked internal, and a command
line that gives it anywhere but first fills the configuration field
`entrypoint`.

```nim
import clispec
import entrypoints
import entrypoints/[clispec, describe]

cliProgramWithEntryPoint(Tool, "tool"):
  boolFlag verbose is bool, help = "Talk more"
  flag jobs is int, default = 4, key = "build.jobs", help = "Parallel jobs"

describeProgram(Tool)

main:
  let conf = Tool.load(entryArgs())
  echo "verbose: ", conf.verbose
```

`describeProgram` registers entries a package build or an installer can call
on the binary it just built, with the same flags:

| Entry                         | Prints                                                                                |
| ----------------------------- | ------------------------------------------------------------------------------------- |
| `complete <shell> <words...>` | the answer to a completion request                                                    |
| `completion <shell>`          | the shell's completion script, which asks `tool --entrypoint=complete` for candidates |
| `help-json [<subcommand>...]` | the `clispec-help/1` document                                                         |
| `config-schema`               | the configuration keys files can supply, as JSON (`entrypoints-config/1`)             |

So `tool --entrypoint=completion zsh` prints a script that matches this very
binary, and the program's own command line needs no `completion` or
`__complete` words of its own.

Clispec is an optional dependency: put its `src` on the Nim path to use these
two modules. `cliProgramWithEntryPoint` takes `cliProgram`'s arguments; a library
that builds a clispec model itself adds the same declaration with
`entryPointParameter()`, a statement for the `cli:` body.

## Sources written for nim-testutils

nim-testutils' `tests:` and `programMain:` (module `testutils/moduletests`) and
its fuzz harness (`testutils/fuzzing`) work through this library, with no change
to the sources that use them. Put this repository's `compat` directory ahead of
nim-testutils on the Nim path. Nim searches `--path` directories last-given
first, so on the command line `compat` comes after nim-testutils:

```sh
nim c --path:<nim-testutils> --path:<nim-entrypoints>/compat prog.nim
```

(In a `config.nims`: `switch("path", ...)` for `compat` after the line that
includes `nimble.paths`.) Nothing in nim-testutils is forked; without the
directory on the path, nothing differs.

- `tests:` is the tests entry's block with unittest2 imported for it, as in
  nim-testutils. `-d:testutils_test_build`, which nim-testutils' runner
  passes, is read as `-d:entrypoint=tests`: the tests run when the program
  starts and `main` is not in the binary.
- `programMain:` defines `proc main` and registers it as the program's `main:`.
- Built to carry everything, the same binary also runs its tests with
  `--entrypoint=tests`, lists them with `--list`, runs one with
  `--run=<suite>::<test>`, and lists its entries. In such a build a `tests:`
  body is compiled in and guarded, where nim-testutils compiles it away.
  Import `entrypoints` (or the compat module) before `unittest2`, so that the
  selector argument is not read by unittest2 as a test filter.
- `testutils/fuzzing`: `init:` and `test:` with `payload`, as before: input
  from standard input or a file (AFL), or libFuzzer's exports under
  `-d:llvmFuzzer --noMain`. The WinAFL export `AFLmain` is not provided.

## Development

```sh
nix develop          # nim, just and the pre-commit tools
just test            # the test suite (also: nimble test)
just lint            # nim check over everything, then for Windows and macOS
just build           # compile the tests without running them
```

The tests compile and run real fixture programs with the compiler that runs
them. They need clispec and, for the nim-testutils test, nim-testutils with
unittest2, stew and results: the dev shell provides them
(`ENTRYPOINTS_CLISPEC_PATH`, `ENTRYPOINTS_TESTUTILS_PATH`,
`ENTRYPOINTS_NIM_PATHS`), and a missing one fails the test. Outside the shell,
set those variables, or have checkouts of nim-cli-spec and nim-testutils
beside this one and the packages in the nimble store.

## License

Apache-2.0. See [LICENSE](LICENSE).
