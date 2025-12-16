#ifndef MORPHL_TOKENS_TOKENS_H_
#define MORPHL_TOKENS_TOKENS_H_

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "util/util.h"

/** A token kind is identified by an interned symbol. */
typedef Sym TokenKind;

/**
 * @brief Represents a lexical token with source location metadata.
 */
struct token {
  TokenKind kind;      /**< Interned token kind. */
  Str lexeme;          /**< Token text. */
  const char* filename;/**< Originating filename. */
  size_t row;          /**< 1-based line number. */
  size_t col;          /**< 1-based column number. */
};


#endif // MORPHL_TOKENS_TOKENS_H_
