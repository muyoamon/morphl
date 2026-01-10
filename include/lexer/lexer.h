#ifndef MORPHL_LEXER_LEXER_H_
#define MORPHL_LEXER_LEXER_H_

#include <stddef.h>
#include <stdbool.h>
#include "tokens/tokens.h"

// Token kind constants
extern const char* const LEXER_KIND_IDENT;
extern const char* const LEXER_KIND_NUMBER;
extern const char* const LEXER_KIND_FLOAT;
extern const char* const LEXER_KIND_STRING;
extern const char* const LEXER_KIND_SYMBOL;
extern const char* const LEXER_KIND_EOF;

/**
 * @brief Tokenize a source buffer using a static rule set.
 *
 * The lexer recognizes identifiers (`[A-Za-z_][A-Za-z0-9_]*`), decimal
 * numbers (`[0-9]+`), float numbers (`[0-9]+\\.[0-9]+`), string literals (`"..."`), and punctuation sequences
 * (any run of non-whitespace characters that are not alphanumeric or an
 * underscore). Whitespace is ignored while tracking row/column positions.
 * An explicit EOF token is appended to every stream. All token kinds are
 * interned using the provided table, allowing the parser to reference kinds
 * symbolically.
 *
 * @param filename The name of the file being tokenized (used for diagnostics).
 * @param source   The source buffer to scan.
 * @param interns  The intern table used to store token kind strings.
 * @param out_tokens Pointer that receives a heap-allocated array of tokens.
 * @param out_count  Pointer that receives the number of tokens produced.
 * @return true on success, false on allocation or interning failure.
 */
bool lexer_tokenize(const char* filename,
                    Str source,
                    InternTable* interns,
                    struct token** out_tokens,
                    size_t* out_count);

/** @name Built-in token kinds */
///@{
extern const char* const LEXER_KIND_IDENT;   /**< Identifier token kind name. */
extern const char* const LEXER_KIND_NUMBER;  /**< Number token kind name. */
extern const char* const LEXER_KIND_FLOAT;   /**< Float token kind name. */
extern const char* const LEXER_KIND_STRING;  /**< String token kind name. */
extern const char* const LEXER_KIND_SYMBOL;  /**< Punctuation token kind name. */
extern const char* const LEXER_KIND_EOF;     /**< End-of-file token kind name. */
///@}


#endif // MORPHL_LEXER_LEXER_H_
