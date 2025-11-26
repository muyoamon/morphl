#include "util/util.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

void arena_init(Arena* a, size_t cap) {
  a->base = (char*)malloc(cap);
  a->cap = cap;
  a->off = 0;
}

void arena_free(Arena* a) {
  free(a->base);
  a->base = NULL;
  a->cap = a->off = 0;
}

char* arena_push(Arena* a, const void* data, size_t n) {
  if (a->off + n > a->cap) {
    return NULL;
  }
  char* dest = a->base + a->off;
  if (data && n) {
    memcpy(dest, data, n);
  }
  a->off += n;
  return dest;
}

static uint64_t hash_str(Str s) {
  // FNV-1a 64-bit
  uint64_t h = 1469598103934665603ull;
  for (size_t i = 0; i < s.len; ++i) {
    h ^= (uint64_t)(unsigned char)s.ptr[i];
    h *= 1099511628211ull;
  }
  return h;
}

struct InternTable {
  Str* slots;
  size_t cap;
  size_t len;
  Arena arena;
};

static bool intern_table_grow(InternTable* t) {
  size_t new_cap = t->cap ? t->cap * 2 : 64;
  Str* new_slots = calloc(new_cap, sizeof(Str));
  if (!new_slots) return false;

  // Rehash existing entries
  for (size_t i = 0; i < t->cap; ++i) {
    if (t->slots[i].ptr == NULL) continue;
    Str existing = t->slots[i];
    uint64_t h = hash_str(existing);
    size_t idx = h & (new_cap - 1);
    while (new_slots[idx].ptr != NULL) {
      idx = (idx + 1) & (new_cap - 1);
    }
    new_slots[idx] = existing;
  }

  free(t->slots);
  t->slots = new_slots;
  t->cap = new_cap;
  return true;
}

InternTable* interns_new(void) {
  InternTable* t = calloc(1, sizeof(InternTable));
  if (!t) return NULL;
  t->cap = 0;
  t->len = 0;
  t->slots = NULL;
  arena_init(&t->arena, 4096);
  if (!intern_table_grow(t)) {
    interns_free(t);
    return NULL;
  }
  return t;
}

void interns_free(InternTable* t) {
  if (!t) return;
  free(t->slots);
  arena_free(&t->arena);
  free(t);
}

Sym interns_intern(InternTable* t, Str s) {
  if (!t || !s.ptr) return 0;
  if (t->len * 2 >= t->cap) {
    if (!intern_table_grow(t)) return 0;
  }
  uint64_t h = hash_str(s);
  size_t idx = h & (t->cap - 1);
  while (true) {
    Str* slot = &t->slots[idx];
    if (slot->ptr == NULL) {
      // Insert
      char* buf = arena_push(&t->arena, s.ptr, s.len + 1);
      if (!buf) return 0;
      buf[s.len] = '\0';
      *slot = str_from(buf, s.len);
      ++t->len;
      return (Sym)(idx + 1);
    }
    if (str_eq(*slot, s)) {
      return (Sym)(idx + 1);
    }
    idx = (idx + 1) & (t->cap - 1);
  }
}

Str interns_lookup(InternTable* t, Sym sym) {
  if (!t || sym == 0) return str_from(NULL, 0);
  size_t idx = sym - 1;
  if (idx >= t->cap) return str_from(NULL, 0);
  return t->slots[idx];
}
