## Reprobuild project file for nim-entrypoints (the ``entrypoints`` package).
##
## A Nim leaf library: it needs nothing beyond the standard library.
## (clispec is an optional dependency of two submodules; the tests put it on
## the Nim path themselves, see ``tests/harness.nim``.)
##
## * ``uses:`` declares the tool floor (``nim``, the C back-end ``nim c``
##   shells out to and the Justfile's command closure), mirroring
##   ``entrypoints.nimble``'s ``requires "nim >= 2.0.0"``.
## * ``library entrypoints`` exports ``src/`` (the main module
##   ``src/entrypoints.nim`` and its submodules under ``src/entrypoints/``),
##   so a consumer that declares ``uses: "nim-entrypoints"`` gets it on its
##   ``nim c --path:``.
## * Every test module the Justfile and ``entrypoints.nimble`` run is listed
##   in ``entrypointsTests`` and gets a BUILD edge
##   (``buildNimUnittest.build``) compiling ``build/test-bin/<stem>`` and an
##   EXECUTE edge (``edge.testBinary.run``) running it. The BUILD halves
##   collect into ``test-builds`` and the EXECUTE halves into ``test``, so
##   ``repro build test`` is the same suite as ``just test``.
##   ``tests/test_suite_lists_agree.nim`` fails when this list, the
##   Justfile's and the nimble task's stop naming the same files.
##
## ``defaultToolProvisioning "path"``: this repository's dev shell
## (``flake.nix``) puts ``nim``, the C compiler, ``just``, ``bash`` and
## coreutils on ``PATH``, so the PATH resolver is the right local default.

import repro_project_dsl
# ``useFlakeDevShell()`` in ``devEnv:``.
import repro_dsl_stdlib/foreign_env

# ``buildNimUnittest.build(...)`` for the BUILD edges and the
# ``edge.testBinary.run(...)`` dispatch for the EXECUTE edges.
import ct_test_nim_unittest

type
  EntrypointsTest = object
    ## One test module. ``runsCompiler``: it runs the Nim compiler (and
    ## through ``nim c``, the C compiler) while it executes, so its EXECUTE
    ## edge declares those tools too.
    source: string
    runsCompiler: bool

const entrypointsTests = [
  EntrypointsTest(source: "tests/test_cs_m13_entry_selection.nim",
    runsCompiler: true),
  EntrypointsTest(source: "tests/test_cs_m13_testutils_compatible.nim",
    runsCompiler: true),
  EntrypointsTest(source: "tests/test_cs_m14_tests_entry_exact_run.nim",
    runsCompiler: true),
  EntrypointsTest(source: "tests/test_suite_lists_agree.nim"),
]

package entrypoints:
  defaultToolProvisioning "path"

  uses:
    "nim >=2.0"
    when defined(macosx):
      "clang >=14"
    else:
      "gcc >=12"
    # The Justfile's command closure: ``just``, the ``bash`` its ``set
    # shell`` and shebang recipes name, and the coreutils they invoke.
    "just >=1"
    "bash >=4"
    "mkdir"
    "tee"

  library entrypoints

  devEnv:
    # This repository's own flake dev shell. Windows has no Nix; its
    # toolchain comes from the ``uses:`` floor above.
    when not defined(windows):
      useFlakeDevShell()
    task "bump-version", command = "just bump-version",
      description = "Bump version number (version.txt, entrypoints.nimble)"

  build:
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    proc stemOf(source: string): string =
      var start = 0
      for i in 0 ..< source.len:
        if source[i] == '/' or source[i] == '\\':
          start = i + 1
      result = source[start .. ^1]
      if result.len > 4 and result[^4 .. ^1] == ".nim":
        result = result[0 ..< ^4]

    let cTool = when defined(macosx): "clang" else: "gcc"

    for spec in entrypointsTests:
      let stem = stemOf(spec.source)
      let edge = buildNimUnittest.build(
        source = spec.source,
        binary = "build/test-bin/" & stem,
        paths = @["src"],
        extraInputs = @["src", "compat", "tests", "config.nims",
          "entrypoints.nimble"],
        actionId = "entrypoints.test_build." & stem)
      appendRegisteredActionToolIdentityRefs(edge.action.id, @[cTool])
      testBuildActions.add(edge.action)
      # The BUILD edge already owns the binary basename as its implicit
      # target name; the explicit ``actionId`` names the execute edge.
      let run = edge.testBinary.run(
        actionId = "entrypoints.test_execute." & stem,
        registerImplicitName = false)
      if spec.runsCompiler:
        appendRegisteredActionToolIdentityRefs(run.id, @["nim", cTool])
      testExecuteActions.add(run)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
