#include "parser/builtin_parser.h"
#include "parser/operators.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lexer/lexer.h"

// Maximum nesting depth for safety
#define BUILTIN_MAX_DEPTH 256

// Token kind constants (must match lexer)
extern const char* const LEXER_KIND_IDENT;
extern const char* const LEXER_KIND_NUMBER;
extern const char* const LEXER_KIND_FLOAT;
extern const char* const LEXER_KIND_STRING;
extern const char* const LEXER_KIND_SYMBOL;
extern const char* const LEXER_KIND_EOF;

// Forward declaration for recursive parsing
static bool parse_builtin_expr(const struct token* tokens,
                               size_t token_count,
                               size_t* cursor,
                               InternTable* interns,
                               TokenKind ident_kind,
                               TokenKind number_kind,
                               TokenKind float_kind,
                               TokenKind string_kind,
                               TokenKind symbol_kind,
                               TokenKind eof_kind,
                               size_t depth,
                               AstNode** out_node);

/**
 * @brief Check if a token is a builtin operator (starts with $).
 */
static bool is_builtin_op(const struct token* tok, TokenKind ident_kind) {
  return tok->kind == ident_kind && tok->lexeme.len > 1 && tok->lexeme.ptr[0] == '$';
}

/**
 * @brief Parse a single expression (atom or builtin operation).
 *
 * Handles:
 * - Literals: numbers, strings, identifiers
 * - Builtin operations: $op arg1 arg2 ...
 */
static bool parse_builtin_expr(const struct token* tokens,
                               size_t token_count,
                               size_t* cursor,
                               InternTable* interns,
                               TokenKind ident_kind,
                               TokenKind number_kind,
                               TokenKind float_kind,
                               TokenKind string_kind,
                               TokenKind symbol_kind,
                               TokenKind eof_kind,
                               size_t depth,
                               AstNode** out_node) {
  if (depth > BUILTIN_MAX_DEPTH) {
    return false; // Stack overflow protection
  }

  if (*cursor >= token_count) {
    return false; // Unexpected end of input
  }

  const struct token* tok = &tokens[*cursor];
  
  // Check for EOF
  if (tok->kind == eof_kind) {
    return false;
  }

  // Handle builtin operations: $op arg1 arg2 ...
  if (is_builtin_op(tok, ident_kind)) {
    Sym op_sym = interns_intern(interns, tok->lexeme);
    if (!op_sym) return false;
    (*cursor)++; // Consume operator

    // Parse arguments until we hit a delimiter or end
    AstNode** children = NULL;
    size_t child_count = 0;
    size_t child_capacity = 0;

    // Determine arity based on operator
    // Most builtins are variadic; some are unary/binary
    // For simplicity, parse all available arguments
    while (*cursor < token_count) {
      const struct token* next = &tokens[*cursor];
      
      // Stop at EOF
      if (next->kind == eof_kind) {
        break;
      }
      
      // Stop at closing delimiters or separators
      if (next->kind == symbol_kind && next->lexeme.len == 1) {
        char c = next->lexeme.ptr[0];
        if (c == ')' || c == '}' || c == ']' || c == ';' || c == ',') {
          break;
        }
      }

      // Grow children array
      if (child_count >= child_capacity) {
        size_t new_cap = child_capacity ? child_capacity * 2 : 4;
        AstNode** resized = realloc(children, new_cap * sizeof(AstNode*));
        if (!resized) {
          for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
          free(children);
          return false;
        }
        children = resized;
        child_capacity = new_cap;
      }

      // Parse argument
      AstNode* child = NULL;
      if (!parse_builtin_expr(tokens, token_count, cursor, interns, ident_kind, number_kind, float_kind, string_kind, symbol_kind, eof_kind, depth + 1, &child)) {
        for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
        free(children);
        return false;
      }
      children[child_count++] = child;
    }

    // Choose AST kind based on operator registry (defaults to builtin)
    AstKind op_kind = AST_BUILTIN;
    const OperatorInfo* info = operator_info_lookup(op_sym);
    if (info && info->ast_kind != AST_UNKNOWN) {
      op_kind = info->ast_kind;
    }

    AstNode* node = ast_new(op_kind);
    if (!node) {
      for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
      free(children);
      return false;
    }
    node->op = op_sym;
    node->children = children;
    node->child_count = child_count;
    *out_node = node;
    return true;
  }

  // Handle literals and identifiers
  AstKind kind;
  if (tok->kind == number_kind || tok->kind == float_kind || tok->kind == string_kind) {
    kind = AST_LITERAL;
  } else if (tok->kind == ident_kind) {
    kind = AST_IDENT;
  } else {
    // Unexpected token
    return false;
  }

  (*cursor)++; // Consume token

  AstNode* node = ast_new(kind);
  if (!node) return false;
  
  if (kind == AST_LITERAL || kind == AST_IDENT) {
    node->value = tok->lexeme;
    if (kind == AST_LITERAL) {
      node->op = tok->kind;
    }
  }

  *out_node = node;
  return true;
}

bool builtin_parse_expr(const struct token* tokens,
                        size_t token_count,
                        size_t* cursor,
                        InternTable* interns,
                        AstNode** out_node) {
  if (!tokens || !cursor || !interns || !out_node) return false;

  // Intern token kinds
  TokenKind ident_kind = interns_intern(interns, str_from(LEXER_KIND_IDENT, strlen(LEXER_KIND_IDENT)));
  TokenKind number_kind = interns_intern(interns, str_from(LEXER_KIND_NUMBER, strlen(LEXER_KIND_NUMBER)));
  TokenKind float_kind = interns_intern(interns, str_from(LEXER_KIND_FLOAT, strlen(LEXER_KIND_FLOAT)));
  TokenKind string_kind = interns_intern(interns, str_from(LEXER_KIND_STRING, strlen(LEXER_KIND_STRING)));
  TokenKind symbol_kind = interns_intern(interns, str_from(LEXER_KIND_SYMBOL, strlen(LEXER_KIND_SYMBOL)));
  TokenKind eof_kind = interns_intern(interns, str_from(LEXER_KIND_EOF, strlen(LEXER_KIND_EOF)));
  if (!ident_kind || !number_kind || !float_kind || !string_kind || !symbol_kind || !eof_kind) return false;

  return parse_builtin_expr(tokens, token_count, cursor, interns, ident_kind, number_kind, float_kind, string_kind, symbol_kind, eof_kind, 0, out_node);
}

bool builtin_parse_ast(const struct token* tokens,
                       size_t token_count,
                       InternTable* interns,
                       AstNode** out_root) {
  if (!tokens || !interns || !out_root) return false;

  // Intern token kinds
  TokenKind ident_kind = interns_intern(interns, str_from(LEXER_KIND_IDENT, strlen(LEXER_KIND_IDENT)));
  TokenKind number_kind = interns_intern(interns, str_from(LEXER_KIND_NUMBER, strlen(LEXER_KIND_NUMBER)));
  TokenKind float_kind = interns_intern(interns, str_from(LEXER_KIND_FLOAT, strlen(LEXER_KIND_FLOAT)));
  TokenKind string_kind = interns_intern(interns, str_from(LEXER_KIND_STRING, strlen(LEXER_KIND_STRING)));
  TokenKind symbol_kind = interns_intern(interns, str_from(LEXER_KIND_SYMBOL, strlen(LEXER_KIND_SYMBOL)));
  TokenKind eof_kind = interns_intern(interns, str_from(LEXER_KIND_EOF, strlen(LEXER_KIND_EOF)));
  if (!ident_kind || !number_kind || !float_kind || !string_kind || !symbol_kind || !eof_kind) return false;

  size_t cursor = 0;
  
  // Parse a single top-level expression or implicit block
  // If multiple top-level expressions exist, wrap them in an implicit block
  AstNode** children = NULL;
  size_t child_count = 0;
  size_t child_capacity = 0;

  while (cursor < token_count && tokens[cursor].kind != eof_kind) {
    // Grow children array
    if (child_count >= child_capacity) {
      size_t new_cap = child_capacity ? child_capacity * 2 : 4;
      AstNode** resized = realloc(children, new_cap * sizeof(AstNode*));
      if (!resized) {
        for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
        free(children);
        return false;
      }
      children = resized;
      child_capacity = new_cap;
    }

    // Parse top-level statement
    AstNode* child = NULL;
    if (!parse_builtin_expr(tokens, token_count, &cursor, interns, ident_kind, number_kind, float_kind, string_kind, symbol_kind, eof_kind, 0, &child)) {
      for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
      free(children);
      return false;
    }
    children[child_count++] = child;

    // Skip optional semicolons between statements
    if (cursor < token_count) {
      const struct token* sep = &tokens[cursor];
      if (sep->kind == symbol_kind && sep->lexeme.len == 1 && sep->lexeme.ptr[0] == ';') {
        cursor++;
      }
    }
  }

  // If single child, return it directly; otherwise wrap in implicit block
  if (child_count == 1) {
    *out_root = children[0];
    free(children);
    return true;
  } else {
    AstNode* root = ast_new(AST_BLOCK);
    if (!root) {
      for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
      free(children);
      return false;
    }
    root->children = children;
    root->child_count = child_count;
    *out_root = root;
    return true;
  }
}
