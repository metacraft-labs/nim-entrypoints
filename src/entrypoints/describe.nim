## entrypoints/describe: a clispec program describes itself through entries.
##
## ``describeProgram(Tool)`` registers, for a program whose command line is
## described with clispec (``cliProgram(Tool, ...)``), the entries a package
## build or an installer calls on the binary it just built:
##
## ================ ==================================================== ===========================
## entry            prints                                               arguments
## ================ ==================================================== ===========================
## ``complete``     the answer to a completion request (clispec's        ``<shell> <words...>``
##                  ``__complete`` protocol)
## ``completion``   the shell's completion script, registered to call    ``<shell>``
##                  this entry
## ``help-json``    the ``clispec-help/1`` document of a command         ``[<subcommand words>...]``
## ``config-schema`` the program's configuration keys as JSON            none
## ================ ==================================================== ===========================
##
## .. code-block:: nim
##   import clispec, entrypoints, entrypoints/[clispec, describe]
##
##   cliProgramWithEntryPoint(Tool, "tool"):
##     flag jobs is int, default = 4, key = "build.jobs"
##
##   describeProgram(Tool)
##
##   main:
##     discard Tool.load(entryArgs())
##
## ``tool --entrypoint=completion zsh`` prints a zsh script that asks
## ``tool --entrypoint=complete zsh <words>`` for candidates, so the script
## matches the binary it was generated from and the program's own command line
## needs no ``completion`` word or ``__complete`` handling of its own. The
## entries are internal: they appear in no help screen, only in the list
## (``--entrypoint=list``).
##
## The ``config-schema`` document, schema name ``entrypoints-config/1``:
## ``{"schema":"entrypoints-config/1","program":"tool","configSchema":"<the
## description's configSchema id or empty>","keys":[{"key":"build.jobs",
## "parameter":"jobs","type":"integer","required":false,"default":"4",
## "help":"..."}]}``. It lists the parameters that a configuration file can
## supply (those whose ``sources`` include ``file``), with the key a file
## uses.
##
## The ``entrypoint`` parameter that ``cliProgramWithEntryPoint`` declares is
## left out of every one of these.

import std/json
import clispec/[model, grammar, errors, parser, completion]
import ../entrypoints

proc describeJson*(g: CliGrammar): string =
  ## The ``config-schema`` document of a program's grammar.
  var keys = newJArray()
  for p in g.params:
    if csFile notin p.sources or p.configKey.len == 0:
      continue
    if p.name == "entrypoint" and p.visibility == cvInternal:
      continue
    var k = newJObject()
    k["key"] = %p.configKey
    k["parameter"] = %p.name
    k["type"] = %($p.configType)
    k["list"] = %p.isList
    k["required"] = %p.required
    if p.hasDefault:
      k["default"] = %p.defaultText
    if p.help.len > 0:
      k["help"] = %p.help
    keys.add(k)
  $(%*{"schema": "entrypoints-config/1", "program": g.program,
    "configSchema": g.configSchema, "keys": keys})

const selectorEntry* = "--entrypoint=complete"
  ## The completion word of the scripts: the first argument that selects the
  ## ``complete`` entry.

proc describeUsage*(message: string): int =
  stderr.writeLine(message)
  usageExitCode

template describeProgram*(T: typedesc) =
  ## Registers the self-description entries for the clispec program ``T``.
  entryPoint "complete",
             doc = "answer a shell's completion request",
             args = "<shell> <words...>":
    stdout.write(T.completionReply(entryArgs()))
  entryPoint "completion",
             doc = "print a shell's completion script",
             args = "<bash|zsh|fish|powershell>":
    let words = entryArgs()
    var shell: CliShell
    if words.len != 1 or not cliParseShell(words[0], shell):
      result = describeUsage("completion: expected one of: bash, zsh, " &
        "fish, powershell")
    else:
      stdout.write(T.completionScript(shell,
        options = CliOptions(completionEntry: selectorEntry)))
  entryPoint "help-json",
             doc = "print the machine-readable help (clispec-help/1)",
             args = "[<subcommand words>...]":
    try:
      stdout.writeLine(T.helpJson(entryArgs()))
    except CliUsageError as e:
      result = describeUsage("help-json: " & e.msg)
  entryPoint "config-schema",
             doc = "print the configuration keys the program reads from files":
    stdout.writeLine(describeJson(T.cliGrammar))
