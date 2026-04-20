#include <stdio.h>

typedef struct {
  long long a;
} x_block_t;

int main(void) {
  {
    x_block_t x;
    /* Unknown builtin operator */;
  };
  return 0;
}
