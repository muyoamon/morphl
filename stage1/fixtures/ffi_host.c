/* The C side of `stage1/fixtures/ffi.mpl`: §8's FFI addresses arrive as `int64_t`,
   because §3.1 has one integer type, and are cast back to what they point at. */
#include <stdint.h>

typedef struct { const char *p; int64_t n; } mpl_str;
typedef struct { int64_t x; int64_t y; } pt;

/* `str_ptr`: the bytes, with the length beside them since a `Str` is not
   NUL-terminated. */
int64_t host_sum_bytes(int64_t p, int64_t n) {
  const unsigned char *b = (const unsigned char *)(intptr_t)p;
  int64_t s = 0, i;
  for (i = 0; i < n; i++) s += b[i];
  return s;
}

/* `array_ptr`: an array of `Str` is contiguous `mpl_str`s. */
int64_t host_total_len(int64_t p, int64_t n) {
  const mpl_str *a = (const mpl_str *)(intptr_t)p;
  int64_t s = 0, i;
  for (i = 0; i < n; i++) s += a[i].n;
  return s;
}

/* `box_ptr`: C writes through the address of morphl storage. */
int64_t host_bump(int64_t addr) {
  int64_t *c = (int64_t *)(intptr_t)addr;
  *c += 10;
  return *c;
}

/* `unbox`: memory C owns, which morphl reads and writes as a reference. */
static pt shared = { 3, 4 };
int64_t host_point(void)     { return (int64_t)(intptr_t)&shared; }
int64_t host_point_sum(void) { return shared.x * 100 + shared.y; }
