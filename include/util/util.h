#ifndef MORPHL_UTIL_UTIL_H_
#define MORPHL_UTIL_UTIL_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
  const char* ptr;
  size_t len;
} Str;
static inline Str str_from(const char* p, size_t n) {return (Str){p,n};}
static inline bool str_eq(Str a, Str b) {
  return a.len==b.len && (a.len==0 || memcmp(a.ptr, b.ptr, a.len)==0);
}

// Very small arena
typedef struct Arena {
  char* base;
  size_t cap, off;
} Arena;

void arena_init(Arena* a, size_t cap);
void arena_free(Arena* a);
char* arena_push(Arena* a, const void* data, size_t n);

// Intern table
typedef uint32_t Sym;

typedef struct InternTable InternTable;
InternTable* interns_new(void);
void interns_free(InternTable*);
Sym interns_intern(InternTable*, Str s);
Str interns_lookup(InternTable*, Sym sym);


#endif // MORPHL_UTIL_UTIL_H_
