#include <stdio.h>

typedef struct {
  long long a;
  long long b;
} x_block_t;

typedef struct {
  long long  _0;
  long long  _1;
  long long  _2;
} y_group_t;

typedef struct {
  long long  _0;
  long long  _1;
} anon2_group_t;

typedef long long (*f1_func_t)(anon2_group_t);

int main(void) {
  {
    long long foo;
    x_block_t x;
    y_group_t y;
    f1_func_t f1;
    (foo = (foo + 2));
  };
  return 0;
}
