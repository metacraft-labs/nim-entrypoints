## entrypoints/fuzz: fuzz targets as entries.
##
## .. code-block:: nim
##   import entrypoints
##   import entrypoints/fuzz
##
##   fuzzTarget "parser":
##     init:                    # optional; runs before the test
##       warmUp()
##     discard parse(payload)   # `payload` holds the fuzzer's input bytes
##
##   main:
##     runTheProgram()
##
## The target is the entry ``fuzz-parser``.
##
## * At run time (``prog --entrypoint=fuzz-parser [<file>]``) the entry reads
##   its input from the file named by its first argument, or from standard
##   input, and runs the body once on it: the shape AFL-style fuzzers, and a
##   person reproducing a crash, use. ``payload`` is a ``seq[byte]`` (a
##   trailing newline is removed). An exception the body does not handle is
##   reported and aborts the process, so a fuzzer sees a crash.
## * ``nim c -d:llvmFuzzer --noMain -d:entrypoint=fuzz-parser prog.nim``
##   builds the libFuzzer harness instead: it exports
##   ``LLVMFuzzerTestOneInput`` (``payload`` is then an ``openArray[byte]``
##   over the fuzzer's buffer) and ``LLVMFuzzerInitialize``, which starts the
##   Nim runtime and runs ``init``. libFuzzer's own ``main`` calls them, so the
##   binary has no entry dispatcher. ``-d:llvmFuzzer`` without
##   ``-d:entrypoint=`` for a fuzz entry is an error: a harness replaces the
##   program's ``main``.
## * ``-d:honggfuzz`` with ``-d:llvmFuzzer`` selects honggfuzz's use of the same
##   exports.
##
## Fuzz entries are listed with every other entry, so a tool finds the targets
## of a binary without running it.

import std/[macros, strutils]
when not (defined(llvmFuzzer) and not defined(honggfuzz)):
  import system/ansi_c
import ../entrypoints

proc fuzzFailed*(exc: ref Exception) =
  ## Reports an exception the fuzzed code let escape and aborts the process.
  try:
    echo "Fuzzed code raised exception:" &
      " name=" & $exc.name & " msg=" & exc.msg & "\n" & $getStackTrace(exc)
  except Exception:
    echo "Fuzzed code raised exception"
  finally:
    when defined(llvmFuzzer) and not defined(honggfuzz):
      quit QuitFailure
    else:
      c_abort()

template fuzzGuard*(body: untyped) =
  ## Runs ``body``; an exception it does not handle fails the fuzz run.
  try:
    body
  except Exception as exc:
    fuzzFailed(exc)

proc readFuzzInput*(args: openArray[string]): seq[byte] =
  ## The bytes to fuzz with: the file named by ``args[0]``, else standard
  ## input, with a trailing newline removed.
  var input: string
  if args.len > 0:
    try:
      input = readFile(args[0])
    except IOError:
      echo "Error opening input stream"
      quit QuitFailure
  else:
    try:
      input = stdin.readAll()
    except IOError:
      echo "Error opening input stream"
      quit QuitFailure
  input.removeSuffix
  cast[seq[byte]](input)

template makeOpenArray*(data: ptr byte; len: int): untyped =
  ## The bytes libFuzzer hands over, as a view.
  toOpenArray(cast[ptr UncheckedArray[byte]](data), 0, len - 1)

when defined(clangfast) and not defined(llvmFuzzer):
  proc aflInit*() {.importc: "__AFL_INIT", noDecl.}
    ## Deferred instrumentation: place where the fork server can start.
  proc aflLoopImpl(count: cuint): cint {.importc: "__AFL_LOOP", noDecl.}
  template aflLoop*(body: untyped): untyped =
    ## Persistent mode: runs ``body`` repeatedly for AFL.
    while aflLoopImpl(1000) != 0:
      `body`
else:
  proc aflInit*() = discard
  template aflLoop*(body: untyped): untyped = `body`

proc NimMain() {.importc: "NimMain".}

proc splitFuzzBody*(body: NimNode): tuple[init, test: NimNode]
    {.compileTime.} =
  ## The ``init:`` block (if any) and the test statements of a fuzz body.
  ## A ``test:`` block is unwrapped.
  result.init = newStmtList()
  result.test = newStmtList()
  for st in body:
    if st.kind in {nnkCall, nnkCommand} and st.len == 2 and
        st[0].kind == nnkIdent and st[1].kind == nnkStmtList:
      if st[0].eqIdent("init"):
        result.init.add(st[1])
        continue
      if st[0].eqIdent("test"):
        result.test.add(st[1])
        continue
    result.test.add(st)

proc llvmHarness*(init, test: NimNode): NimNode {.compileTime.} =
  ## The libFuzzer exports for a target.
  let payloadId = ident"payload"
  let data = ident"data"
  let len = ident"len"
  let initProc = ident"LLVMFuzzerInitialize"
  let callProc = ident"LLVMFuzzerTestOneInput"
  let guard = bindSym"fuzzGuard"
  let nimMain = bindSym"NimMain"
  let mk = bindSym"makeOpenArray"
  result = quote do:
    proc `initProc`(): cint {.exportc: "LLVMFuzzerInitialize", dynlib.} =
      `nimMain`()
      `guard`:
        `init`
      return 0
    proc `callProc`(`data`: ptr byte; `len`: csize_t): cint
        {.exportc: "LLVMFuzzerTestOneInput", dynlib.} =
      template `payloadId`(): auto {.used.} = `mk`(`data`, int(`len`))
      `guard`:
        `test`
      return 0

macro fuzzTarget*(name: static string; rest: varargs[untyped]): untyped =
  ## Declares the fuzz target ``name`` (the entry ``fuzz-<name>``); see the
  ## module documentation.
  let o = entryOptions(rest, "fuzzTarget")
  let entryName = "fuzz-" & name
  let (init, test) = splitFuzzBody(o.body)
  when defined(llvmFuzzer):
    let index = registerEntry(entryName,
      if o.doc.len > 0: o.doc else: "fuzz target " & name & " (libFuzzer)",
      o.args, {compileTime})
    discard index
    if compileSelected == entryName:
      result = llvmHarness(init, test)
    elif compileSelected == "":
      error("entrypoints: -d:llvmFuzzer builds a libFuzzer harness, which " &
        "replaces the program's main: pick the target with " &
        "-d:entrypoint=" & entryName)
    else:
      result = newEmptyNode()
  else:
    let doc = if o.doc.len > 0: o.doc else: "fuzz target " & name
    let args = if o.args.len > 0: o.args else: "[<input file>]"
    let index = registerEntry(entryName, doc, args, o.select)
    if compileSelected == entryName and compileTime notin o.select:
      error("entrypoints: entry '" & entryName & "' cannot be selected at " &
        "compile time (its select does not include compileTime)")
    let selected =
      if compileSelected != "": compileSelected == entryName
      else: entryEmitted(o.select)
    if not selected:
      return newEmptyNode()
    let p = genSym(nskProc, "fuzz_" & name.replace('-', '_'))
    setEntryProc(index, p)
    let payloadId = ident"payload"
    let guard = bindSym"fuzzGuard"
    let reader = bindSym"readFuzzInput"
    let argsProc = bindSym"entryArgs"
    result = quote do:
      proc `p`(): int =
        var `payloadId` {.inject.} = `reader`(`argsProc`())
        `guard`:
          `init`
          `test`
