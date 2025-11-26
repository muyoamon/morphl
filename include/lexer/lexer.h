#ifndef MORPHL_LEXER_LEXER_H_
#define MORPHL_LEXER_LEXER_H_

#include <stddef.h>
#include <stdbool.h>
#include "tokens/tokens.h"

typedef struct SyntaxRule {
  TokenKind kind;
  Str literal;
} SyntaxRule;

typedef struct Syntax {
  SyntaxRule* rules;
  size_t rule_count;
  size_t rule_capacity;
  InternTable* kinds;
} Syntax;

// Load syntax rules from a file. Each non-empty, non-comment line should be in
// the form:
//   TOKEN_NAME literal
// The literal may be unquoted (single word) or wrapped in double quotes when it
// contains whitespace. Backslash escapes (\n, \t, \\ and \") are honored in
// quoted literals. TOKEN_NAME is interned and used as the token kind.
bool syntax_load_file(Syntax* syntax, const char* path, InternTable* interns, Arena* arena);
void syntax_free(Syntax* syntax);

// Tokenize a source string using the supplied syntax. Identifiers (/[A-Za-z_][A-Za-z0-9_]*/) are
// emitted as the IDENT kind, numbers (/[0-9]+/) as NUMBER, and any unknown
// character as UNKNOWN. An EOF token is appended to the end of the stream.
bool lexer_tokenize(const Syntax* syntax,
                    const char* filename,
                    Str source,
                    InternTable* interns,
                    struct token** out_tokens,
                    size_t* out_count);

// Common token kind strings that are always interned by the lexer.
extern const char* const LEXER_KIND_IDENT;
extern const char* const LEXER_KIND_NUMBER;
extern const char* const LEXER_KIND_UNKNOWN;
extern const char* const LEXER_KIND_EOF;


#endif // MORPHL_LEXER_LEXER_H_
