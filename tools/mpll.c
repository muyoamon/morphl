#include <stdio.h>
#include <stdlib.h>

#include "runtime/runtime.h"

static void print_usage(const char* program) {
  fprintf(stderr, "usage: %s <out.mple> <input.mplo> [more-inputs.mplo ...]\n",
          program);
}

int main(int argc, char** argv) {
  if (argc < 3) {
    print_usage(argv[0]);
    return 1;
  }

  const char* out_path = argv[1];
  const char* const* inputs = (const char* const*)&argv[2];
  size_t input_count = (size_t)(argc - 2);

  if (!morphl_vm_link_files(out_path, inputs, input_count, stderr)) {
    return 1;
  }

  return 0;
}
