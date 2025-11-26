#ifndef MORPHL_TOKENS_TOKENS_H_
#define MORPHL_TOKENS_TOKENS_H_

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "util/util.h"

enum TokenKind {
  TK_NONE = 0,

  // delimiter
  TK_LBRACE, TK_RBRACE,         // []
  TK_LPAREN, TK_RPAREN,         // ()
  TK_LBRACK, TK_RBRACK,         // {}
  TK_COMMA, TK_SEMI, TK_DOT,
  TK_COLON, 
};

struct token {
  enum TokenKind kind;
  const char* str;
  const char* filename;
  size_t row;
  size_t col;
};


#endif // MORPHL_TOKENS_TOKENS_H_
