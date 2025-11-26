#include "lexer/lexer.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util/file.h"

const char* const LEXER_KIND_IDENT = "IDENT";
const char* const LEXER_KIND_NUMBER = "NUMBER";
const char* const LEXER_KIND_UNKNOWN = "UNKNOWN";
const char* const LEXER_KIND_EOF = "EOF";

static bool push_rule(Syntax* syntax, SyntaxRule rule) {
  if (syntax->rule_count == syntax->rule_capacity) {
    size_t new_cap = syntax->rule_capacity ? syntax->rule_capacity * 2 : 8;
    SyntaxRule* resized = realloc(syntax->rules, new_cap * sizeof(SyntaxRule));
    if (!resized) return false;
    syntax->rules = resized;
    syntax->rule_capacity = new_cap;
  }
  syntax->rules[syntax->rule_count++] = rule;
  return true;
}

static void trim_whitespace(const char** line, size_t* len) {
  while (*len > 0 && isspace((unsigned char)(*line)[0])) {
    (*line)++; (*len)--;
  }
  while (*len > 0 && isspace((unsigned char)(*line)[*len - 1])) {
    (*len)--;
  }
}

static bool parse_literal(const char** cursor, size_t* remaining, Str* out, bool* allocated) {
  const char* start = *cursor;
  size_t len = 0;
  if (*remaining == 0) return false;
  if (allocated) *allocated = false;
  if (**cursor == '"') {
    (*cursor)++; (*remaining)--;
    char* buf = malloc(*remaining + 1);
    if (!buf) return false;
    size_t out_len = 0;
    bool closed = false;
    while (*remaining > 0) {
      char c = **cursor;
      (*cursor)++; (*remaining)--;
      if (c == '"') { closed = true; break; }
      if (c == '\\' && *remaining > 0) {
        char esc = **cursor; (*cursor)++; (*remaining)--;
        switch (esc) {
          case 'n': c = '\n'; break;
          case 't': c = '\t'; break;
          case '\\': c = '\\'; break;
          case '"': c = '"'; break;
          default: c = esc; break;
        }
      }
      buf[out_len++] = c;
    }
    if (!closed) { free(buf); return false; }
    buf[out_len] = '\0';
    *out = str_from(buf, out_len);
    if (allocated) *allocated = true;
    return true;
  }
  while (len < *remaining && !isspace((unsigned char)start[len])) {
    len++;
  }
  if (len == 0) return false;
  *out = str_from(start, len);
  *cursor += len;
  *remaining -= len;
  return true;
}

static bool parse_rule_line(const char* line, size_t len, InternTable* interns, Arena* arena, SyntaxRule* out_rule) {
  trim_whitespace(&line, &len);
  if (len == 0 || line[0] == '#') return false;

  // Parse token name
  size_t name_len = 0;
  while (name_len < len && !isspace((unsigned char)line[name_len])) {
    name_len++;
  }
  if (name_len == 0) return false;
  Str name = str_from(line, name_len);
  line += name_len;
  len -= name_len;
  trim_whitespace(&line, &len);
  Str literal;
  bool literal_allocated = false;
  if (!parse_literal(&line, &len, &literal, &literal_allocated)) return false;

  // Copy literal into arena to keep lifetime alongside syntax
  const char* literal_buf = literal.ptr;
  char* stored = arena_push(arena, literal.ptr, literal.len + 1);
  if (!stored) return false;
  stored[literal.len] = '\0';
  literal = str_from(stored, literal.len);
  if (literal_allocated) {
    free((void*)literal_buf);
  }

  TokenKind kind = interns_intern(interns, name);
  if (!kind) return false;
  *out_rule = (SyntaxRule){ .kind = kind, .literal = literal };
  return true;
}

bool syntax_load_file(Syntax* syntax, const char* path, InternTable* interns, Arena* arena) {
  if (!syntax || !interns || !arena) return false;
  memset(syntax, 0, sizeof(*syntax));
  syntax->kinds = interns;

  char* contents = NULL;
  size_t len = 0;
  if (!file_read_all(path, &contents, &len)) {
    return false;
  }

  const char* cursor = contents;
  while (len > 0) {
    const char* line = cursor;
    size_t line_len = 0;
    while (line_len < len && cursor[line_len] != '\n') {
      line_len++;
    }
    cursor += line_len + (line_len < len);
    len -= line_len + (line_len < len);

    SyntaxRule rule;
    if (parse_rule_line(line, line_len, interns, arena, &rule)) {
      if (!push_rule(syntax, rule)) { free(contents); return false; }
    }
  }

  free(contents);
  return true;
}

void syntax_free(Syntax* syntax) {
  if (!syntax) return;
  free(syntax->rules);
  syntax->rules = NULL;
  syntax->rule_count = 0;
  syntax->rule_capacity = 0;
  syntax->kinds = NULL;
}

static bool match_rule(const SyntaxRule* rule, Str remaining) {
  return remaining.len >= rule->literal.len &&
         memcmp(remaining.ptr, rule->literal.ptr, rule->literal.len) == 0;
}

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

bool lexer_tokenize(const Syntax* syntax,
                    const char* filename,
                    Str source,
                    InternTable* interns,
                    struct token** out_tokens,
                    size_t* out_count) {
  if (!syntax || !interns || !out_tokens || !out_count) return false;
  *out_tokens = NULL;
  *out_count = 0;
  size_t cap = 0;

  TokenKind ident_kind = interns_intern(interns, str_from(LEXER_KIND_IDENT, strlen(LEXER_KIND_IDENT)));
  TokenKind number_kind = interns_intern(interns, str_from(LEXER_KIND_NUMBER, strlen(LEXER_KIND_NUMBER)));
  TokenKind unknown_kind = interns_intern(interns, str_from(LEXER_KIND_UNKNOWN, strlen(LEXER_KIND_UNKNOWN)));
  TokenKind eof_kind = interns_intern(interns, str_from(LEXER_KIND_EOF, strlen(LEXER_KIND_EOF)));
  if (!ident_kind || !number_kind || !unknown_kind || !eof_kind) return false;

  size_t offset = 0;
  size_t row = 1, col = 1;
  while (offset < source.len) {
    char c = source.ptr[offset];
    if (c == '\n') { row++; col = 1; offset++; continue; }
    if (c == ' ' || c == '\t' || c == '\r') { col++; offset++; continue; }

    SyntaxRule const* match = NULL;
    size_t match_len = 0;
    for (size_t i = 0; i < syntax->rule_count; ++i) {
      const SyntaxRule* rule = &syntax->rules[i];
      if (match_rule(rule, str_from(source.ptr + offset, source.len - offset)) &&
          rule->literal.len > match_len) {
        match = rule;
        match_len = rule->literal.len;
      }
    }

    if (match) {
      if (!ensure_token_capacity(out_tokens, &cap, *out_count + 1)) return false;
      (*out_tokens)[(*out_count)++] = (struct token){
        .kind = match->kind,
        .lexeme = str_from(source.ptr + offset, match_len),
        .filename = filename,
        .row = row,
        .col = col,
      };
      offset += match_len;
      col += match_len;
      continue;
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

    // Unknown character
    if (!ensure_token_capacity(out_tokens, &cap, *out_count + 1)) return false;
    (*out_tokens)[(*out_count)++] = (struct token){
      .kind = unknown_kind,
      .lexeme = str_from(source.ptr + offset, 1),
      .filename = filename,
      .row = row,
      .col = col,
    };
    offset++; col++;
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
