#ifndef MORPHL_TOKENS_TOKENS_H_
#define MORPHL_TOKENS_TOKENS_H_

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "util/util.h"

// A token kind is identified by an interned symbol, allowing the lexer to
// accept syntax rules that are loaded at runtime.
typedef Sym TokenKind;

struct token {
  TokenKind kind;
  Str lexeme;
  const char* filename;
  size_t row;
  size_t col;
};


#endif // MORPHL_TOKENS_TOKENS_H_
