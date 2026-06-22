// mayhem/harnesses/standalone_main.c — single-file run-once driver for the rabbitmq-c
// OSS-Fuzz harnesses (fuzz_url / fuzz_table / fuzz_server). It provides a main() that reads
// each path argument as one input and hands it to the harness's LLVMFuzzerTestOneInput, so
// every libFuzzer target also builds as a plain reproducer (no libFuzzer runtime linked).
//
// The rabbitmq-c harnesses declare LLVMFuzzerTestOneInput as (const char *, size_t), so the
// forward declaration here matches that exact signature.
#include <stdio.h>
#include <stdlib.h>

extern int LLVMFuzzerTestOneInput(const char *data, size_t size);

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    FILE *f = fopen(argv[i], "rb");
    if (!f) {
      perror(argv[i]);
      continue;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    if (n < 0) {
      fclose(f);
      continue;
    }
    fseek(f, 0, SEEK_SET);
    char *buf = (char *)malloc((size_t)n ? (size_t)n : 1);
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    LLVMFuzzerTestOneInput(buf, got);
    free(buf);
  }
  return 0;
}
