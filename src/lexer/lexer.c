#include "lexer/lexer.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util/file.h"

const char* const LEXER_KIND_IDENT = "IDENT";
const char* const LEXER_KIND_NUMBER = "NUMBER";
const char* const LEXER_KIND_STRING = "STRING";
const char* const LEXER_KIND_SYMBOL = "SYMBOL";
const char* const LEXER_KIND_EOF = "EOF";

static bool ensure_token_capacity(struct token** tokens, size_t* cap, size_t needed) {
  if (*cap >= needed) return true;
  size_t new_cap = *cap ? (*cap * 2) : 16;
  while (new_cap < needed) new_cap *= 2;
  struct token* resized = realloc(*tokens, new_cap * sizeof(struct token));
  if (!resized) return false;
  *tokens = resized;
  *cap = new_cap;
  return true;
}

static bool intern_kinds(InternTable* interns,
                         TokenKind* ident,
                         TokenKind* number,
                         TokenKind* string,
                         TokenKind* symbol,
                         TokenKind* eof) {
  *ident = interns_intern(interns, str_from(LEXER_KIND_IDENT, strlen(LEXER_KIND_IDENT)));
  *number = interns_intern(interns, str_from(LEXER_KIND_NUMBER, strlen(LEXER_KIND_NUMBER)));
  *string = interns_intern(interns, str_from(LEXER_KIND_STRING, strlen(LEXER_KIND_STRING)));
  *symbol = interns_intern(interns, str_from(LEXER_KIND_SYMBOL, strlen(LEXER_KIND_SYMBOL)));
  *eof = interns_intern(interns, str_from(LEXER_KIND_EOF, strlen(LEXER_KIND_EOF)));
  return *ident && *number && *string && *symbol && *eof;
}

bool lexer_tokenize(const char* filename,
                    Str source,
                    InternTable* interns,
                    struct token** out_tokens,
                    size_t* out_count) {
  if (!interns || !out_tokens || !out_count) return false;
  *out_tokens = NULL;
  *out_count = 0;
  size_t cap = 0;

  TokenKind ident_kind, number_kind, string_kind, symbol_kind, eof_kind;
  if (!intern_kinds(interns, &ident_kind, &number_kind, &string_kind, &symbol_kind, &eof_kind)) {
    return false;
  }

  size_t offset = 0;
  size_t row = 1, col = 1;
  while (offset < source.len) {
    char c = source.ptr[offset];
    if (c == '\n') { row++; col = 1; offset++; continue; }
    if (c == ' ' || c == '\t' || c == '\r') { col++; offset++; continue; }

    // Handle $identifier as a single token (builtin operators)
    if (c == '$' && offset + 1 < source.len) {
      char next = source.ptr[offset + 1];
      if (isalpha((unsigned char)next) || next == '_') {
        size_t start = offset;
        offset++; col++; // Skip $
        while (offset < source.len) {
          char cc = source.ptr[offset];
          if (!(isalnum((unsigned char)cc) || cc == '_')) break;
          offset++; col++;
        }
        size_t len = offset - start;
        if (!ensure_token_capacity(out_tokens, &cap, *out_count + 1)) return false;
        (*out_tokens)[(*out_count)++] = (struct token){
          .kind = ident_kind,
          .lexeme = str_from(source.ptr + start, len),
          .filename = filename,
          .row = row,
          .col = col - len,
        };
        continue;
      }
    }

    if (isalpha((unsigned char)c) || c == '_') {
      size_t start = offset;
      while (offset < source.len) {
        char cc = source.ptr[offset];
        if (!(isalnum((unsigned char)cc) || cc == '_')) break;
        offset++; col++;
      }
      size_t len = offset - start;
      if (!ensure_token_capacity(out_tokens, &cap, *out_count + 1)) return false;
      (*out_tokens)[(*out_count)++] = (struct token){
        .kind = ident_kind,
        .lexeme = str_from(source.ptr + start, len),
        .filename = filename,
        .row = row,
        .col = col - len,
      };
      continue;
    }

    if (isdigit((unsigned char)c)) {
      size_t start = offset;
      while (offset < source.len && isdigit((unsigned char)source.ptr[offset])) {
        offset++; col++;
      }
      size_t len = offset - start;
      if (!ensure_token_capacity(out_tokens, &cap, *out_count + 1)) return false;
      (*out_tokens)[(*out_count)++] = (struct token){
        .kind = number_kind,
        .lexeme = str_from(source.ptr + start, len),
        .filename = filename,
        .row = row,
        .col = col - len,
      };
      continue;
    }

    // String literals: "..."
    if (c == '"') {
      size_t start = offset;
      offset++; col++; // Skip opening quote
      while (offset < source.len && source.ptr[offset] != '"') {
        if (source.ptr[offset] == '\n') {
          row++; col = 1;
        } else {
          col++;
        }
        offset++;
      }
      if (offset >= source.len) {
        // Unterminated string
        return false;
      }
      offset++; col++; // Skip closing quote
      size_t len = offset - start;
      if (!ensure_token_capacity(out_tokens, &cap, *out_count + 1)) return false;
      (*out_tokens)[(*out_count)++] = (struct token){
        .kind = string_kind,
        .lexeme = str_from(source.ptr + start, len),
        .filename = filename,
        .row = row,
        .col = col - len,
      };
      continue;
    }

    // Symbol characters: tokenize one at a time
    size_t start = offset;
    offset++; col++;
    size_t len = 1;

    if (!ensure_token_capacity(out_tokens, &cap, *out_count + 1)) return false;
    (*out_tokens)[(*out_count)++] = (struct token){
      .kind = symbol_kind,
      .lexeme = str_from(source.ptr + start, len),
      .filename = filename,
      .row = row,
      .col = col - len,
    };
  }

  if (!ensure_token_capacity(out_tokens, &cap, *out_count + 1)) return false;
  (*out_tokens)[(*out_count)++] = (struct token){
    .kind = eof_kind,
    .lexeme = str_from(NULL, 0),
    .filename = filename,
    .row = row,
    .col = col,
  };

  return true;
}
