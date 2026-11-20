# nim-entrypoints - Agent Instructions

A Nim library for alternative entry points into a program's main module. The
program writes its entry in a `main:` block, libraries register more with
`entryPoint "<name>":`, and an entry is selected at compile time
(`-d:entrypoint=<name>`) or at run time (`--entrypoint=<name>` as the first
argument). `README.md` describes the whole library; read it first. The
library depends on nothing but the standard library. clispec
(`metacraft-labs/nim-cli-spec`) is an optional dependency of two modules.

## Commands

- Dev shell: `nix develop` (nim, just, the pre-commit tools, and the
  environment the tests read: `ENTRYPOINTS_CLISPEC_PATH`,
  `ENTRYPOINTS_TESTUTILS_PATH`, `ENTRYPOINTS_NIM_PATHS`,
  `ENTRYPOINTS_EXTRA_NIM`).
- Test: `just test` (also `nimble test`). The tests compile and run real
  fixture programs, so they take about a minute the first time.
- Lint: `just lint` (`nim check` over the library, the compat modules, the
  fixture and every test, then `nim check --os:windows` and `--os:macosx` over
  the library, again with each `nim` in `ENTRYPOINTS_EXTRA_NIM`, the
  metacraft-labs Nim fork, whose newer standard library differs on Windows;
  lint refuses to run without it).
- Build without running: `just build`.

## Layout

- `src/entrypoints.nim`: the main module. The compile-time registry
  (`registerEntry`, `addEntryNote`, `setEntryProc`), `entryPoint`, `main:`
  (closes the registry, emits the dispatcher, writes the list and the
  `-d:entrypointsManifest` file), the run-time selector (`parseSelector`,
  `entryArgs`, `selectedEntry`, `entryPrelude`) and the list JSON
  (schema `entrypoints/1`).
- `src/entrypoints/tests.nim`: the `tests` entry: `testCase`, `tests:` blocks
  (placed in place, guarded, or dropped depending on the build) and the run
  of `--list` / `--run=<name>` / `--run-exact=<name>` (the exact form a
  build tool uses; a `tests:` block's `test` calls are guarded for it).
- `src/entrypoints/fuzz.nim`: `fuzzTarget`, the AFL-shape reader and the
  libFuzzer exports; the helpers `compat/testutils/fuzzing.nim` shares.
- `src/entrypoints/describe.nim` and `src/entrypoints/clispec.nim`: the
  clispec-based modules (`describeProgram`, `cliProgramWithEntryPoint`).
  `entrypoints/clispec` must import clispec's modules one by one
  (`import clispec/[model, dsl, program]`), because a module named `clispec`
  that does `import clispec` imports itself.
- `compat/testutils/`: `moduletests.nim` and `fuzzing.nim`, standing in for
  nim-testutils' modules of the same names when `compat` is searched first
  (Nim searches `--path` directories last-given first).
- `tests/harness.nim`: where the dependencies are, compiling a fixture with the
  compiler that runs the test, running a program with a deadline.
- `tests/test_cs_m13_entry_selection.nim` (fixture
  `tests/fixtures/selection/fixture.nim`): selection at compile time and run
  time, the list and manifest, no code of unselected entries (marker strings
  absent from binaries), the selector in no help screen, negative controls.
- `tests/test_cs_m13_testutils_compatible.nim` (fixtures in
  `tests/fixtures/testutils/`): real nim-testutils sources built with and
  without `compat` on the path and compared.
- `tests/test_cs_m14_tests_entry_exact_run.nim` (fixtures in
  `tests/fixtures/exact/`): `--run-exact` selects exactly one listed name,
  for `testCase`s and for unittest2 tests in a `tests:` block, refuses an
  unknown name with 64, and test names fit on one line.
- `tests/test_suite_lists_agree.nim` keeps the three lists of test modules
  equal: the Justfile's `tests`, the nimble `test` task and `repro.nim`'s
  `entrypointsTests`. A new test module goes into all three lists.

## Rules

- **This repository is public.** Code, comments, docs and commit messages
  explain the library on its own terms. Do not cite or link private
  specifications or private repositories, and do not name machines.
- **A feature that is not used leaves no code.** An entry that is not selected
  expands to nothing (its body is not even type-checked); a knob that is off
  is not compiled. Keep it so: gate code with `when` on `compileSelected`,
  `runtimeEnabled` and the entry's `select`, and test it with a marker string
  that must be absent from the binary (see the shrink test).
- **A compile-time procedure called with constants is folded by the
  compiler.** The registry is read by `{.compileTime.}` procedures; one called
  with only constant arguments is evaluated at semantic-check time, before the
  registry is filled. Read the registry in templates or pass non-constants.
- **Compatibility is tested against the real thing.** The compat modules are
  checked against nim-testutils' own sources and unittest2, by comparing
  builds with and without them; do not replace that with a copy of their
  behaviour.
- **The list is a contract.** Within `entrypoints/1` keys are only added,
  never renamed or removed; anything else is a new schema name. The same for
  `entrypoints-config/1`.
- **The exit code of an unusable entry selection is 64** (`usageExitCode`).
- **Tests kill only what they started.** A test that runs a process stops it
  by the pid it got when it started it, never by name or pattern (`pkill`,
  `killall`), and every run has a deadline (`runProgram`).
- **Dependencies are found, never faked.** A missing dependency fails the test
  that needs it with a message that says where to set it.
- Every Nim compile keeps its nimcache inside the checkout (`config.nims`).
  The Justfile passes `--skipParentCfg`, so each recipe names its own
  `--nimcache:` under `.nimcache/`. The tests build fixtures under
  `.nimcache/test-builds/`.
- Commit messages follow Conventional Commits (`type(scope): summary`, under
  72 characters) with a body that says why.
