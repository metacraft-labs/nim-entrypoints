## Justfile - nim-entrypoints.
##
## Recipes:
##   * `build` compiles every test module without running it.
##   * `test` runs the test suite (`tests/test_*.nim`), the same files
##     `nimble test` runs and `repro.nim` builds and runs
##     (`tests/test_suite_lists_agree.nim` keeps the three lists equal).
##   * `lint` is `nim check` over the umbrella module, the modules under
##     `src/entrypoints/`, the compatibility modules and every test module,
##     then the cross-OS check: `nim check --os:windows` and `--os:macosx`
##     over the same library modules. Code behind `when defined(windows)` or
##     `when defined(macosx)` is not compiled on the host, so without it a
##     module that does not compile for another platform passes every local
##     check and fails first in a consumer's build. `nim check` resolves
##     names and types for the target without a C compiler or the target's
##     headers (an `importc` binding is not looked up until the C compiler
##     sees it, so this does not cover those). The standard library's types
##     differ between Nim versions on Windows, so the check also runs with
##     every `nim` named in `ENTRYPOINTS_EXTRA_NIM` (space-separated paths).
##     The dev shell sets it to the metacraft-labs Nim fork (2.3.1); outside
##     the shell the recipe refuses to run without it rather than check with
##     2.2 alone. The modules that import clispec need it on the path:
##     `ENTRYPOINTS_CLISPEC_PATH` (the dev shell sets it).
##   * `format` runs `nimpretty` when it is available.
##
## The library needs nothing but the compiler and the standard library. The
## tests also need clispec (`ENTRYPOINTS_CLISPEC_PATH`) and, for the
## nim-testutils compatibility test, nim-testutils with unittest2, stew and
## results (`ENTRYPOINTS_TESTUTILS_PATH`, `ENTRYPOINTS_NIM_PATHS`); the dev
## shell provides all of them, and the tests fail when one is missing.
##
## Hermetic flags (`--skipParentCfg --skipUserCfg`) are baked into `nim-flags`
## so every invocation gets the same isolation. That switches off
## `config.nims`, so the recipes state `--path:src` themselves and name their
## own `--nimcache:` under `.nimcache/`, in the layout `config.nims` uses for
## everything else: `.nimcache/<module dir>/<module>_<d|r|check>`.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test
alias fmt := format

src-paths := "--path:src"
nim-flags := "--skipParentCfg --skipUserCfg --hints:off"
nimcache := ".nimcache"
tests := "test_cs_m13_entry_selection test_cs_m13_testutils_compatible test_suite_lists_agree"

# Compile every test module without running it.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    : > test-logs/build.log
    for t in {{tests}}; do
      nim c {{nim-flags}} --nimcache:{{nimcache}}/tests/${t}_d {{src-paths}} \
        -o:test-logs/${t} tests/${t}.nim 2>&1 | tee -a test-logs/build.log
    done

# Run the test suite.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    : > test-logs/test.log
    for t in {{tests}}; do
      nim c -r {{nim-flags}} --nimcache:{{nimcache}}/tests/${t}_d {{src-paths}} \
        -o:test-logs/${t} tests/${t}.nim 2>&1 | tee -a test-logs/test.log
    done

# `nim check` over the library and every test module, then the cross-OS check.
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    : > test-logs/lint.log
    if [[ -z "${ENTRYPOINTS_CLISPEC_PATH:-}" ]]; then
      echo "lint: ENTRYPOINTS_CLISPEC_PATH is not set; the modules that" \
        "import clispec cannot be checked without it. Run inside the dev" \
        "shell (nix develop), which sets it, or point it at nim-cli-spec's" \
        "src directory" >&2
      exit 1
    fi
    clispec="--path:${ENTRYPOINTS_CLISPEC_PATH}"
    library="src/entrypoints.nim src/entrypoints/tests.nim src/entrypoints/fuzz.nim src/entrypoints/clispec.nim src/entrypoints/describe.nim compat/testutils/moduletests.nim compat/testutils/fuzzing.nim"
    n=0
    for m in $library; do
      n=$((n + 1))
      echo "lint: nim check ${m}" | tee -a test-logs/lint.log
      nim check {{nim-flags}} --nimcache:{{nimcache}}/src/lint${n}_check {{src-paths}} \
        ${clispec} "${m}" 2>&1 | tee -a test-logs/lint.log
    done
    for t in {{tests}}; do
      nim check {{nim-flags}} --nimcache:{{nimcache}}/tests/${t}_check {{src-paths}} \
        tests/${t}.nim 2>&1 | tee -a test-logs/lint.log
    done
    # The fixtures are compiled by the tests, but check them here too: they
    # are what the tests run.
    nim check {{nim-flags}} --nimcache:{{nimcache}}/tests/fixture_selection_check {{src-paths}} \
      ${clispec} tests/fixtures/selection/fixture.nim 2>&1 | tee -a test-logs/lint.log
    # The cross-OS check (see the header). `nim check` exits non-zero on an
    # error, and `pipefail` carries that through `tee`.
    if [[ -z "${ENTRYPOINTS_EXTRA_NIM:-}" ]]; then
      echo "lint: ENTRYPOINTS_EXTRA_NIM is not set, so the cross-OS check" \
        "would run with $(nim --version | head -1) only and miss what a" \
        "newer standard library rejects; run inside the dev shell" \
        "(nix develop), which sets it, or set it to a newer nim" >&2
      exit 1
    fi
    # One nimcache per compiler: two Nim versions do not share one.
    n=0
    for compiler in nim ${ENTRYPOINTS_EXTRA_NIM:-}; do
      n=$((n + 1))
      for os in windows macosx; do
        for m in $library; do
          echo "lint: ${compiler} check --os:${os} ${m}" | tee -a test-logs/lint.log
          "${compiler}" check {{nim-flags}} --os:${os} \
            --nimcache:{{nimcache}}/src/cross${n}_${os}_check {{src-paths}} \
            ${clispec} "${m}" 2>&1 | tee -a test-logs/lint.log
        done
      done
    done

# Format the Nim sources in place with nimpretty, when it is installed.
format:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v nimpretty >/dev/null 2>&1; then
      find src compat tests -name '*.nim' -print0 | xargs -0 -n1 nimpretty
    else
      echo "nimpretty not found; skipping" >&2
    fi

# Set the package version (version.txt and entrypoints.nimble's `version`).
bump-version version:
    printf '%s\n' "{{version}}" > version.txt
    sed -i.bak -e 's/^version       = ".*"$/version       = "{{version}}"/' entrypoints.nimble
    rm -f entrypoints.nimble.bak

# Remove test logs, binaries and the nimcache.
clean:
    rm -rf test-logs .nimcache
