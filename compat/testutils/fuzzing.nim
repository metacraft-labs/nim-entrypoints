## nim-testutils' ``testutils/fuzzing`` (``init:`` and ``test:``, with
## ``payload``), over nim-entrypoints' fuzz helpers (``entrypoints/fuzz``).
##
## With this repository's ``compat`` directory before nim-testutils on the
## Nim path, a fuzz source such as
##
## .. code-block:: nim
##   import testutils/fuzzing
##   test:
##     doAssert payload.len < 100
##
## builds and runs as before: standard input or the file named by the first
## argument (AFL), or ``-d:llvmFuzzer --noMain`` for libFuzzer's exports.
## Unlike the ``fuzzTarget`` of ``entrypoints/fuzz``, the module's code is the
## whole program (nim-testutils' shape), not an entry selected among others.
## On Windows the WinAFL export ``AFLmain`` is not provided.

import std/os
import ../../src/entrypoints/fuzz
export fuzz.aflInit, fuzz.aflLoop

proc NimMain() {.importc: "NimMain".}

# The default init, gets redefined when init template is used.
template initImpl(): untyped =
  when defined(llvmFuzzer):
    proc fuzzerInit(): cint {.exportc: "LLVMFuzzerInitialize", dynlib.} =
      NimMain()

      return 0
  else:
    discard

template init*(body: untyped) {.dirty.} =
  ## Init block to do any initialisation for the fuzzing test.
  ##
  ## For AFL this is currently only cosmetic and will be run each time, before
  ## the test block.
  ##
  ## For LLVM fuzzers this will only be run once. So only put data which is
  ## stateless or make sure everything gets properply reset for each new run
  ## in the test block.
  when defined(llvmFuzzer):
    template initImpl() {.dirty.} =
      bind NimMain

      proc fuzzerInit(): cint {.exportc: "LLVMFuzzerInitialize", dynlib.} =
        NimMain()

        body

        return 0
  else:
    template initImpl(): untyped {.dirty.} =
      bind fuzzGuard
      fuzzGuard: body

template test*(body: untyped): untyped =
  ## Test block to do the actual test that will be fuzzed in a loop.
  ##
  ## Within this test block there is access to the payload OpenArray which
  ## contains the payload provided by the fuzzer.
  mixin initImpl
  initImpl()
  when defined(llvmFuzzer):
    proc fuzzerCall(data: ptr byte, len: csize_t):
        cint {.exportc: "LLVMFuzzerTestOneInput", dynlib.} =
      template payload(): auto =
        makeOpenArray(data, int(len))

      fuzzGuard: body
  else:
    var payload {.inject.} = readFuzzInput(commandLineParams())

    fuzzGuard: body
