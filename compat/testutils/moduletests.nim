## nim-testutils' ``testutils/moduletests`` (``tests:`` and ``programMain:``),
## over nim-entrypoints.
##
## Put this repository's ``compat`` directory ahead of nim-testutils on the
## Nim path and a project's sources need no change. Nim searches the ``--path``
## directories last-given first, so on the command line ``compat`` comes
## after nim-testutils (in a ``config.nims``, a ``switch("path", ...)`` after
## the ``include "nimble.paths"`` line):
##
## .. code-block:: sh
##   nim c --path:<nim-testutils> --path:<nim-entrypoints>/compat prog.nim
##
## * ``tests: body`` is the ``tests`` entry's block (``entrypoints/tests``)
##   with unittest2 imported for it, as nim-testutils does. A build with
##   ``-d:testutils_test_build`` (what nim-testutils' runner passes) is read as
##   ``-d:entrypoint=tests``: the body runs when the program starts and the
##   program's ``main`` is not in the binary.
## * ``programMain: body`` defines ``proc main`` and registers it as the
##   program's ``main:`` entry; it is called when the module is the main module
##   and the binary is built for ``main`` or for every entry.
##
## What differs from nim-testutils: in a build that carries ``main``, a
## ``tests:`` body is not type-checked and compiled away; it is compiled in and
## runs when the program is started with ``--entrypoint=tests``. unittest2's
## own option and filter arguments, and ``--run=<name>``, are handed on to it.
## ``--run-exact=<name>`` is not: unittest2's filters are patterns, so the
## entry guards the block's ``test`` calls itself (``entrypoints/tests``).
## Import this module (or ``entrypoints``) before ``unittest2``, so that the
## selector argument is not read by unittest2 as a test filter. When the order
## is the other way round, a run with no filter would skip every test and
## pass; the first ``tests:`` block notices (it runs a probe test) and the
## process stops with an error that says how to fix the order.

{.used.}
{.define: unittest2DisableParamFiltering.}

import std/[macros, strutils]
from ../../src/entrypoints import entryMain, compileSelected, usageExitCode
import ../../src/entrypoints/tests as entrypointsTests

var unittestPrepared = false

proc takeFirstPrepare*(): bool =
  ## True once: the first ``tests:`` block hands the arguments to unittest2.
  result = not unittestPrepared
  unittestPrepared = true

proc probeWanted*(): bool =
  ## Whether a probe of unittest2's argument filtering is called for: the
  ## tests were chosen at run time and no filter was given, so that a
  ## filter left over from the selector would silently skip every test.
  when compileSelected == "":
    result = testsSelected() and not listingOnly()
    if result:
      for a in frameworkArgs():
        if not a.startsWith("-"):
          return false
  else:
    result = false

proc probeFailed*() {.noreturn.} =
  stderr.writeLine("tests: unittest2 skipped a test that nothing filters " &
    "out: it was imported before this module and took the selector " &
    "argument for a test filter. Import testutils/moduletests (or " &
    "entrypoints) before unittest2, or build with " &
    "-d:unittest2DisableParamFiltering")
  quit(usageExitCode)

macro tests*(body: untyped): untyped =
  ## A block of unittest2 tests; see the module documentation.
  let importer = quote do:
    when not declared(unittest2):
      import unittest2
  let ran = genSym(nskVar, "ran")
  let first = bindSym"takeFirstPrepare"
  let wanted = bindSym"probeWanted"
  let failed = bindSym"probeFailed"
  let args = bindSym"frameworkArgs"
  # The probe runs, silently, a test that no sensible filter excludes. It
  # only runs where unittest2 runs its tests as it meets them (the default).
  let probe =
    when defined(unittest2Compat) or defined(unittest2NoCollect) or
        defined(unittest2ListTests) or defined(unittest2PreviewIsolate):
      newEmptyNode()
    else:
      quote do:
        if `wanted`():
          var `ran` = false
          unittest2.suite "entrypoints probe":
            unittest2.test "probe":
              `ran` = true
          if not `ran`:
            `failed`()
  let prepare = quote do:
    if `first`():
      unittest2.resetOutputFormatters()
      `probe`
      unittest2.parseParameters(`args`())
  # The set-up is the block's prelude: its probe is a test, and it must run
  # under ``--run-exact`` too, where the block's own tests are guarded.
  let code = testBlockCode(body, body, prepare)
  result = newStmtList(importer, code)

template programMain*(body: untyped) =
  ## The program's entry as ``proc main``; see the module documentation.
  proc main {.raises: [CatchableError].} =
    body

  when isMainModule:
    entryMain(main)
