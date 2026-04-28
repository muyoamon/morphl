#include <stdio.h>

#include "runtime/runtime.h"

static void print_usage(const char* program) {
  fprintf(stderr, "usage: %s <file.mplx> [program-args...]\n", program);
}

int main(int argc, char** argv) {
  if (argc < 2) {
    print_usage(argv[0]);
    return 1;
  }

  extern char** environ;
  return (int)morphl_vm_run_file(argv[1], argc - 1, &argv[1], environ, stderr);
}
