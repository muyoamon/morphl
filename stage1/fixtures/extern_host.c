/* The C side of `stage1/fixtures/extern.mpl`, exercising §4.16's ABI mapping.
   Each signature is written the way the mapping says morphl will see it: a block
   is a struct in `$decl` order, `&T` is a thin pointer, `Int` is `int64_t`, and
   `Str` is pointer + length. The struct and string types are declared here
   independently — C matches layouts across translation units, not names. */
#include <stdint.h>

typedef struct { const char *p; int64_t n; } mpl_str;
typedef struct { int64_t x; int64_t y; } pt;

int64_t host_add(int64_t a, int64_t b) { return a + b; }
int64_t host_none(void)                { return 11; }
int64_t host_deref(int64_t *p)         { return *p * 3; }
int64_t host_strlen(mpl_str s)         { return s.n; }
pt      host_swap(pt v)                { pt r; r.x = v.y; r.y = v.x; return r; }

/* §4.16 rule 2, both directions. The parameter is a plain C function pointer,
   which is what a capture-free morphl `$func` maps to; the result is one too. */
int64_t host_apply(int64_t (*f)(int64_t), int64_t x) { return f(x) + 100; }
static int64_t host_triple(int64_t n)                { return n * 3; }
int64_t (*host_pick(int64_t n))(int64_t)             { (void)n; return host_triple; }
