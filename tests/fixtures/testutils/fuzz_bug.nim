## nim-testutils' own fuzz example with a bug (inputs of 100 bytes or more),
## as it is there, but for its import.
import testutils/fuzzing

test:
  doAssert payload.len < 100
