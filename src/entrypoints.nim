## entrypoints: alternative entry points into a program's main module.
##
## A program writes its ordinary entry in a ``main:`` block. A library
## registers further entries with ``entryPoint``: running the program's tests,
## describing its command line, fuzzing a function, and so on. An entry is
## chosen at compile time, which builds a binary for that entry only, or at
## run time, by naming it in the first argument. A binary can list the entries
## it carries, so a tool that builds or runs it discovers them without
## running ``main``.
##
## .. code-block:: nim
##   import entrypoints
##   import entrypoints/tests          # registers the "tests" entry
##
##   testCase "addition":
##     doAssert 1 + 1 == 2
##
##   main:
##     echo "the program"
##
## ``prog`` runs ``main``; ``prog --entrypoint=tests`` runs the tests;
## ``nim c -d:entrypoint=tests prog.nim`` builds a binary that runs the tests
## and holds nothing of ``main``; ``prog --entrypoint=list`` prints the
## entries as JSON.
##
## Registry
## ========
##
## Every ``entryPoint`` the compilation sees is recorded, in import order, in
## a compile-time table that is not part of the binary. ``main:`` closes the
## table and emits the dispatcher, so an ``entryPoint`` written after
## ``main:`` in the main module is a compile-time error (an entry that an
## imported library registers always comes first).
##
## Declaring an entry
## ==================
##
## .. code-block:: nim
##   entryPoint "tests", doc = "run the program's tests",
##              select = {compileTime, runTime}:
##     runAllTests(entryArgs())
##
## * The name is a literal matching ``[a-z][a-z0-9-]*``. ``main`` belongs to
##   the ``main:`` block and ``list`` to the machine-readable list.
## * ``select`` says how the entry can be chosen: ``compileTime``
##   (``-d:entrypoint=<name>``), ``runTime`` (the first argument), or both
##   (the default). An entry that needs a binary of its own, such as a
##   libFuzzer target, is ``{compileTime}`` only.
## * ``doc`` is the line the list shows; ``args`` describes the entry's
##   arguments for the list.
## * The body is the whole of the entry's work. ``entryArgs()`` is its
##   arguments. It is the body of a ``proc (): int``: set ``result`` (or
##   ``return`` or ``quit``) to give the process's exit code.
## * A library packages an entry as a template or macro that expands to
##   ``entryPoint``. ``addEntryNote`` lets many modules contribute to one
##   entry's list (every test of every module, for the tests entry).
##
## Selection
## =========
##
## Compile time, in the style of nim-chronicles: with no define every
## registered entry is compiled in, and the ones that allow it can be chosen at
## run time. ``-d:entrypoint=<name>`` builds for that entry only: the other
## entries' ``entryPoint`` forms expand to nothing (their bodies are not even
## type-checked, so a library's other entries need not compile for this
## binary's target) and ``main:``'s body is skipped. ``-d:entrypoint=main``
## builds ``main`` only. An unknown name stops the compile and lists the
## registered ones.
##
## ``-d:entrypointRuntime=off`` removes the run-time selector and the list
## from a binary that carries every entry: ``main`` is all it runs, and the
## code that reads the arguments for them is not compiled.
##
## Run time: the selector is the *first* argument, ``--entrypoint=<name>`` or
## ``--entrypoint <name>``. It is taken before ``main`` runs and the rest of
## the arguments belong to the entry (``entryArgs()``). Because it is only
## recognised first, it cannot collide with a program's own parameters.
## An unknown name prints an error naming the entries and exits with 64; an
## entry that cannot be selected at run time says it needs
## ``-d:entrypoint=<name>``. A program with a clispec description declares the
## same parameter in it, as an internal one (``entrypoints/clispec``).
##
## The list
## ========
##
## ``--entrypoint=list`` prints one JSON document and exits:
##
## .. code-block::
##   {"schema":"entrypoints/1","program":"tool","default":"main",
##    "entries":[{"name":"main","doc":"...","select":["compiletime","runtime"]},
##               {"name":"tests","doc":"...","select":["compiletime","runtime"],
##                "args":"...","entries":["<contributed notes>"]}]}
##
## ``-d:entrypointsManifest=<path>`` makes the compiler write the same
## document to ``path`` (a relative path is relative to the compiler's working
## directory), so a tool that cannot run the binary (a cross-compiled one) still
## discovers the entries. A binary built for one entry lists that entry only.
##
## ``-d:testutils_test_build`` is read as ``-d:entrypoint=tests``, the
## define nim-testutils' runner passes.

import std/[compilesettings, macros, os, strutils]

type
  SelectKind* = enum
    ## How an entry may be chosen.
    compileTime = "compiletime"
    runTime = "runtime"

const
  entrypointDefine {.strdefine: "entrypoint".} = ""
  entrypointRuntimeDefine {.strdefine: "entrypointRuntime".} = "on"
  entrypointsManifestDefine {.strdefine: "entrypointsManifest".} = ""
  compileSelected* =
    when entrypointDefine == "true":
      {.error: "-d:entrypoint needs a name: -d:entrypoint=<name>".}
    elif entrypointDefine.len > 0: entrypointDefine
    elif defined(testutils_test_build): "tests"
    else: ""
    ## The entry this binary is built for, or empty when it carries every
    ## entry.
  runtimeEnabled* =
    when entrypointRuntimeDefine == "on": true
    elif entrypointRuntimeDefine == "off": false
    else: {.error: "-d:entrypointRuntime is on or off".}
    ## Whether the run-time selector (and the list) is compiled in.

# ---------------------------------------------------------------------------
# The compile-time registry.
# ---------------------------------------------------------------------------

type
  EntryDef = object
    name: string
    doc: string
    args: string
    select: set[SelectKind]
    sym: NimNode
    notes: seq[string]

var
  entryRegistry {.compileTime.}: seq[EntryDef]
  registryClosed {.compileTime.}: bool

func validEntryName(name: string): bool =
  if name.len == 0 or name[0] notin {'a'..'z'}:
    return false
  for c in name:
    if c notin {'a'..'z', '0'..'9', '-'}:
      return false
  true

proc registryIndex(name: string): int {.compileTime.} =
  result = -1
  for i, e in entryRegistry:
    if e.name == name:
      return i

template registeredNames(): string =
  ## The names of every entry, `main` first. (A template, not a procedure:
  ## the compiler folds a call of a compile-time procedure whose arguments
  ## are constants, which would read the registry before it is filled.)
  var names = "main"
  for i in 0 ..< entryRegistry.len:
    names.add(", " & entryRegistry[i].name)
  names

proc registerEntry*(name, doc, args: string; select: set[SelectKind]): int
    {.compileTime.} =
  ## Records an entry in the registry and returns its index. ``entryPoint``
  ## calls this; call it directly to register an entry whose code the library
  ## emits itself (see ``setEntryProc``).
  if registryClosed:
    error("entrypoints: entry '" & name & "' is registered after `main:`; " &
      "move the entryPoint above the `main:` block (an entry registered " &
      "by an imported library always comes first)")
  if not validEntryName(name):
    error("entrypoints: an entry name matches [a-z][a-z0-9-]*, got '" &
      name & "'")
  if name == "main":
    error("entrypoints: the name 'main' is reserved for the `main:` block")
  if name == "list":
    error("entrypoints: the name 'list' is reserved for the entry list " &
      "(--entrypoint=list)")
  if registryIndex(name) >= 0:
    error("entrypoints: entry '" & name & "' is registered twice")
  if select == {}:
    error("entrypoints: entry '" & name & "' must allow at least one way " &
      "of selecting it")
  entryRegistry.add(EntryDef(name: name, doc: doc, args: args,
    select: select))
  entryRegistry.high

proc addEntryNote*(name, note: string) {.compileTime.} =
  ## Adds a line to the ``entries`` the list shows for entry ``name`` (the
  ## tests entry lists each test's name this way). The entry must have been
  ## registered.
  let i = registryIndex(name)
  if i < 0:
    error("entrypoints: addEntryNote: no entry '" & name & "'")
  if registryClosed:
    error("entrypoints: addEntryNote('" & name & "') after `main:`; the " &
      "list is written when `main:` closes the registry")
  entryRegistry[i].notes.add(note)

proc setEntryProc*(index: int; sym: NimNode) {.compileTime.} =
  ## Gives entry ``index`` the procedure (taking nothing, returning ``int``,
  ## the exit code) that the dispatcher calls when it is chosen.
  entryRegistry[index].sym = sym

proc entryIsSelected*(name: string): bool {.compileTime.} =
  ## Whether code for entry ``name`` belongs in this binary at all.
  compileSelected == "" or compileSelected == name

proc entryEmitted*(select: set[SelectKind]): bool {.compileTime.} =
  ## Whether an entry that allows ``select`` is compiled into this binary
  ## when the entry is not excluded by the compile-time selection:
  ## without ``-d:entrypoint``, entries that can be chosen at run time are
  ## compiled in (unless ``-d:entrypointRuntime=off``).
  compileSelected != "" or (runTime in select and runtimeEnabled)

# ---------------------------------------------------------------------------
# Compile-time argument reading.
# ---------------------------------------------------------------------------

proc constString(n: NimNode; what: string): string {.compileTime.} =
  ## A string literal, or ``&`` of literals.
  case n.kind
  of nnkStrLit..nnkTripleStrLit:
    n.strVal
  of nnkInfix:
    if n[0].eqIdent("&"):
      constString(n[1], what) & constString(n[2], what)
    else:
      error("entrypoints: " & what & " is a string literal", n)
  of nnkPar:
    constString(n[0], what)
  else:
    error("entrypoints: " & what & " is a string literal", n)

proc selectSet(n: NimNode): set[SelectKind] {.compileTime.} =
  proc one(x: NimNode): SelectKind =
    if x.kind == nnkIdent or x.kind == nnkSym:
      if x.eqIdent("compileTime"): return compileTime
      if x.eqIdent("runTime"): return runTime
    error("entrypoints: select is a set of compileTime and runTime", x)
  if n.kind == nnkCurly:
    for x in n:
      result.incl(one(x))
  else:
    result.incl(one(n))

type EntryOptions* = object
  ## What an ``entryPoint``-style macro call carries besides its body.
  doc*, args*: string
  select*: set[SelectKind]
  body*: NimNode

proc entryOptions*(rest: NimNode; macroName: string): EntryOptions
    {.compileTime.} =
  ## Reads ``doc = ".."``, ``args = ".."``, ``select = {..}`` and the trailing
  ## body from the ``varargs[untyped]`` of an ``entryPoint``-style macro.
  result.select = {compileTime, runTime}
  for i in 0 ..< rest.len:
    let r = rest[i]
    if r.kind in {nnkExprEqExpr, nnkAsgn}:
      if r[0].eqIdent("doc"): result.doc = constString(r[1], "doc")
      elif r[0].eqIdent("args"): result.args = constString(r[1], "args")
      elif r[0].eqIdent("select"): result.select = selectSet(r[1])
      else:
        error("entrypoints: " & macroName & " takes doc, args and select, " &
          "not '" & r[0].repr & "'", r)
    elif i == rest.len - 1 and r.kind == nnkStmtList:
      result.body = r
    else:
      error("entrypoints: " & macroName & " is written " & macroName &
        " \"<name>\"[, doc = \"..\"][, args = \"..\"][, select = {..}]: " &
        "<body>", r)
  if result.body.isNil:
    error("entrypoints: " & macroName & " needs a body (a `:` block)")

macro entryPoint*(name: static string; rest: varargs[untyped]): untyped =
  ## Registers the entry ``name`` and, when this binary carries it, defines
  ## its body as the procedure the dispatcher calls. See the module
  ## documentation.
  let o = entryOptions(rest, "entryPoint")
  let index = registerEntry(name, o.doc, o.args, o.select)
  let selected =
    if compileSelected != "": compileSelected == name
    else: entryEmitted(o.select)
  if compileSelected == name and compileTime notin o.select:
    error("entrypoints: entry '" & name & "' cannot be selected at compile " &
      "time (its select does not include compileTime)")
  if not selected:
    return newEmptyNode()
  let p = genSym(nskProc, "entry_" & name.replace('-', '_'))
  setEntryProc(index, p)
  result = newProc(name = p, params = [ident"int"], body = o.body,
    procType = nnkProcDef)

# ---------------------------------------------------------------------------
# Run time: what the dispatcher uses.
# ---------------------------------------------------------------------------

type EntrySelector* = tuple[name: string, taken: int]

proc parseSelector*(argv: openArray[string]): EntrySelector =
  ## The entry the first arguments select: ``--entrypoint=<name>`` (one
  ## argument taken) or ``--entrypoint <name>`` (two). ``taken`` is 0 when
  ## ``argv`` selects nothing.
  if argv.len > 0:
    if argv[0].startsWith("--entrypoint="):
      return (argv[0]["--entrypoint=".len .. ^1], 1)
    if argv[0] == "--entrypoint":
      if argv.len > 1:
        return (argv[1], 2)
      return ("", 1)

proc entryArgs*(): seq[string] =
  ## The arguments of the running entry: the process's arguments without
  ## the run-time selector, when one was given.
  let argv = commandLineParams()
  when runtimeEnabled:
    let s = parseSelector(argv)
    if s.taken > 0:
      return argv[s.taken .. ^1]
  argv

proc selectedEntry*(): string =
  ## The entry this process runs: the compile-time one, else the one the
  ## first argument names, else ``main``.
  when compileSelected != "":
    compileSelected
  else:
    when runtimeEnabled:
      let s = parseSelector(commandLineParams())
      if s.taken > 0 and s.name.len > 0:
        return s.name
    "main"

proc entryProgramName(): string =
  try:
    getAppFilename().extractFilename
  except OSError:
    "program"

proc exitImmediately*(code: int) {.noreturn.} =
  ## Ends the process now, without running exit procedures (a test framework's
  ## summary, for one), after flushing standard output. For an entry that has
  ## printed a document a tool parses.
  flushFile(stdout)
  flushFile(stderr)
  when defined(windows):
    proc cExit(code: cint) {.importc: "_exit", header: "<stdlib.h>", noreturn.}
  else:
    proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
  cExit(cint(code))

const usageExitCode* = 64
  ## EX_USAGE: the exit code of an unknown or unusable entry.

proc entryUsageError*(name, runtimeNames, compileOnlyNames,
                      thisBinary: string) {.noreturn.} =
  ## The message for a ``--entrypoint=<name>`` the binary cannot run.
  let prog = entryProgramName()
  var msg = prog & ": "
  if name.len == 0:
    msg.add("--entrypoint needs an entry name")
  elif thisBinary.len > 0:
    msg.add("this binary is built for the '" & thisBinary & "' entry only " &
      "(it was compiled with -d:entrypoint=" & thisBinary & "), not '" &
      name & "'")
  elif name in compileOnlyNames.split(", "):
    msg.add("entry '" & name & "' cannot be selected at run time; build " &
      "the program with -d:entrypoint=" & name)
  else:
    msg.add("unknown entry '" & name & "'")
  if thisBinary.len == 0:
    msg.add("; the entries are: " & runtimeNames)
    if compileOnlyNames.len > 0:
      msg.add(" (and, with -d:entrypoint=<name>: " & compileOnlyNames & ")")
  stderr.writeLine(msg)
  quit(usageExitCode)

proc entryPrelude*(listJson, runtimeNames, compileOnlyNames: string) =
  ## The run-time selector of a binary that carries every entry: handles
  ## ``--entrypoint=list`` and an unknown or unusable name. Returns when the
  ## selected entry is one the dispatcher can run (``entryDispatchName``).
  let s = parseSelector(commandLineParams())
  if s.taken > 0:
    if s.name == "list":
      stdout.write(listJson & "\n")
      exitImmediately(0)
    if s.name.len == 0:
      entryUsageError("", runtimeNames, compileOnlyNames, "")

proc entryPreludeOne*(thisBinary, listJson: string) =
  ## The selector of a binary built for the single entry ``thisBinary``:
  ## ``--entrypoint=list`` lists that entry, ``--entrypoint=<thisBinary>`` is
  ## accepted, any other name is an error.
  let s = parseSelector(commandLineParams())
  if s.taken > 0:
    if s.name == "list":
      stdout.write(listJson & "\n")
      exitImmediately(0)
    if s.name != thisBinary:
      entryUsageError(s.name, "", "", thisBinary)

proc entryFinish*(code: int) =
  ## Ends the process with an entry's exit code when it is not 0.
  if code != 0:
    quit(code)

# ---------------------------------------------------------------------------
# main: the dispatcher.
# ---------------------------------------------------------------------------

proc jsonStr(s: string): string {.compileTime.} =
  result = "\""
  for c in s:
    case c
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    elif c < ' ': result.add("\\u00" & toHex(ord(c), 2).toLowerAscii)
    else: result.add(c)
  result.add("\"")

proc selectJson(select: set[SelectKind]): string {.compileTime.} =
  var items: seq[string]
  for k in SelectKind:
    if k in select:
      items.add(jsonStr($k))
  "[" & items.join(",") & "]"

proc entryJson(e: EntryDef): string {.compileTime.} =
  result = "{\"name\":" & jsonStr(e.name) & ",\"doc\":" & jsonStr(e.doc) &
    ",\"select\":" & selectJson(e.select)
  if e.args.len > 0:
    result.add(",\"args\":" & jsonStr(e.args))
  if e.notes.len > 0:
    var items: seq[string]
    for n in e.notes:
      items.add(jsonStr(n))
    result.add(",\"entries\":[" & items.join(",") & "]")
  result.add("}")

proc programNameOf(): string {.compileTime.} =
  querySetting(SingleValueSetting.projectName)

macro main*(rest: varargs[untyped]): untyped =
  ## The program's ordinary entry. ``main:`` closes the registry and emits
  ## the dispatcher, so it comes after every ``entryPoint`` of the main
  ## module. ``main(doc = "..."):`` sets the line the list shows. The body is
  ## the body of a procedure: its variables are local to it.
  var o = entryOptions(rest, "main")
  if o.doc.len == 0:
    o.doc = "run the program"
  if registryClosed:
    error("entrypoints: `main:` is written once, and no entry's library may " &
      "come after it")
  registryClosed = true
  let sel = compileSelected
  if sel != "" and sel != "main":
    let i = registryIndex(sel)
    if i < 0:
      error("entrypoints: -d:entrypoint=" & sel & ": no such entry; the " &
        "registered entries are: " & registeredNames())
    if compileTime notin entryRegistry[i].select:
      error("entrypoints: entry '" & sel & "' cannot be selected at compile " &
        "time (its select does not include compileTime)")
  let mainDef = EntryDef(name: "main", doc: o.doc,
    select: {compileTime, runTime})

  # The list, in registration order, `main` first.
  var listed: seq[string]
  var runtimeNames: seq[string] = @["main"]
  var compileOnlyNames: seq[string]
  var defaultName = "main"
  if sel == "" or sel == "main":
    listed.add(entryJson(mainDef))
  if sel == "":
    for e in entryRegistry:
      listed.add(entryJson(e))
      if runTime in e.select: runtimeNames.add(e.name)
      else: compileOnlyNames.add(e.name)
  elif sel != "main":
    defaultName = sel
    listed.add(entryJson(entryRegistry[registryIndex(sel)]))
  let program = programNameOf()
  let listJson = "{\"schema\":\"entrypoints/1\",\"program\":" &
    jsonStr(program) & ",\"default\":" & jsonStr(defaultName) &
    ",\"entries\":[" & listed.join(",") & "]}"
  when entrypointsManifestDefine.len > 0:
    writeFile(entrypointsManifestDefine, listJson & "\n")

  result = newStmtList()
  let mainProc = genSym(nskProc, "entrypointsMain")
  if sel == "" or sel == "main":
    result.add newProc(name = mainProc, body = o.body)
  let mainCall = newCall(mainProc)

  var dispatch = newStmtList()
  if sel == "":
    var branches = nnkCaseStmt.newTree(
      newCall(bindSym"selectedEntry"))
    branches.add nnkOfBranch.newTree(newLit("main"), mainCall)
    for e in entryRegistry:
      if runTime in e.select and not e.sym.isNil:
        branches.add nnkOfBranch.newTree(newLit(e.name),
          newCall(bindSym"entryFinish", newCall(e.sym)))
    branches.add nnkElse.newTree(newCall(bindSym"entryUsageError",
      newCall(bindSym"selectedEntry"), newLit(runtimeNames.join(", ")),
      newLit(compileOnlyNames.join(", ")), newLit("")))
    when runtimeEnabled:
      dispatch.add newCall(bindSym"entryPrelude", newLit(listJson),
        newLit(runtimeNames.join(", ")), newLit(compileOnlyNames.join(", ")))
      dispatch.add branches
    else:
      dispatch.add mainCall
  elif sel == "main":
    when runtimeEnabled:
      dispatch.add newCall(bindSym"entryPreludeOne", newLit(sel),
        newLit(listJson))
    dispatch.add mainCall
  else:
    let e = entryRegistry[registryIndex(sel)]
    if not e.sym.isNil:
      when runtimeEnabled:
        dispatch.add newCall(bindSym"entryPreludeOne", newLit(sel),
          newLit(listJson))
      dispatch.add newCall(bindSym"entryFinish", newCall(e.sym))
  if dispatch.len > 0:
    result.add nnkWhenStmt.newTree(nnkElifBranch.newTree(
      ident"isMainModule", dispatch))

macro entryMain*(callee: untyped): untyped =
  ## ``main:`` whose body is the call ``callee()``, for a program that
  ## already has its entry as a procedure (nim-testutils' ``programMain``).
  ## The procedure stays defined in every build; it is only called when the
  ## binary is built for ``main`` or carries every entry.
  result = newCall(bindSym"main", newStmtList(newCall(callee)))
