## entrypoints/clispec: the run-time entry selector in a clispec description.
##
## A program that parses its command line with clispec and selects entries at
## run time declares the selector as an internal parameter of its root command
## (``visibility = internal``): help never shows it, completion never offers
## it, the machine-readable help lists it marked internal, and a command line
## that gives it anywhere but first (where ``entrypoints`` takes it before
## ``main`` runs) fills the configuration field ``entrypoint``.
##
## ``cliProgram`` reads its description as untyped syntax and does not expand
## macros inside it, so the parameter is added by this module's
## ``cliProgramWithEntryPoint``, which takes the arguments of ``cliProgram``:
##
## .. code-block:: nim
##   import clispec, entrypoints, entrypoints/clispec
##
##   cliProgramWithEntryPoint(Tool, "tool"):
##     boolFlag verbose is bool
##
##   main:
##     let conf = Tool.load(entryArgs())   # `conf.entrypoint` is "" here
##
## A library whose own macro builds a clispec model adds the same declaration
## with ``entryPointParameter()``, a statement to put in the ``cli:`` body.
##
## Clispec is an optional dependency of ``entrypoints``: only programs that
## import this module (or ``entrypoints/describe``) need it on their path.

import std/macros
# Not `import clispec`: inside a module that is itself named `clispec`,
# that would name this module. The library's own modules are unambiguous.
import clispec/[model, dsl, program]

proc entryPointParameter*(): NimNode {.compileTime.} =
  ## The ``cli:`` statement that declares the run-time selector: a string flag
  ## ``entrypoint``, internal, read from the command line only.
  parseStmt("flag entrypoint is string, visibility = internal, " &
    "sources = {cli}, help = \"Run another entry point of the program\"")[0]

macro cliProgramWithEntryPoint*(args: varargs[untyped]): untyped =
  ## ``cliProgram`` with the run-time entry selector (``entryPointParameter``)
  ## declared in the root command.
  let a = cliProgramArgs(args, "cliProgramWithEntryPoint")
  a.body.insert(0, entryPointParameter())
  let model = parseCliModel[NoCliExtension, NoCliExtension](a.body,
    NoCliExtension())
  cliProgramCode(model, a.typeName, a.program, a.exported, a.colorConfig)
