/* A stand-in for libFuzzer's main: starts the runtime through
   LLVMFuzzerInitialize and feeds one input to LLVMFuzzerTestOneInput. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int LLVMFuzzerInitialize(void);
int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size);

int main(int argc, char **argv) {
  const char *text = argc > 1 ? argv[1] : "";
  if (LLVMFuzzerInitialize() != 0) return 3;
  int rc = LLVMFuzzerTestOneInput((const unsigned char *)text, strlen(text));
  printf("driver: input of %zu bytes returned %d\n", strlen(text), rc);
  return rc;
}
