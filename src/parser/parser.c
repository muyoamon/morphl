#include "parser/parser.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include "lexer/lexer.h"
#include "util/file.h"

#define PARSER_MAX_DEPTH 128

typedef struct ParsedRuleContext {
  const GrammarRule* rule;
  const Grammar* grammar;
} ParsedRuleContext;

static bool ensure_rule_capacity(Grammar* grammar) {
  if (grammar->rule_count < grammar->rule_cap) return true;
  size_t new_cap = grammar->rule_cap ? grammar->rule_cap * 2 : 8;
  GrammarRule* resized = realloc(grammar->rules, new_cap * sizeof(GrammarRule));
  if (!resized) return false;
  grammar->rules = resized;
  grammar->rule_cap = new_cap;
  return true;
}

static bool ensure_production_capacity(GrammarRule* rule) {
  if (rule->production_count < rule->production_cap) return true;
  size_t new_cap = rule->production_cap ? rule->production_cap * 2 : 4;
  Production* resized = realloc(rule->productions, new_cap * sizeof(Production));
  if (!resized) return false;
  rule->productions = resized;
  rule->production_cap = new_cap;
  return true;
}

static bool ensure_atom_capacity(Production* prod) {
  if (prod->atom_count < prod->atom_capacity) return true;
  size_t new_cap = prod->atom_capacity ? prod->atom_capacity * 2 : 4;
  GrammarAtom* resized = realloc(prod->atoms, new_cap * sizeof(GrammarAtom));
  if (!resized) return false;
  prod->atoms = resized;
  prod->atom_capacity = new_cap;
  return true;
}

static void reset_rule(GrammarRule* rule) {
  for (size_t i = 0; i < rule->production_count; ++i) {
    free(rule->productions[i].atoms);
  }
  free(rule->productions);
  memset(rule, 0, sizeof(*rule));
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

static GrammarRule* find_or_add_rule(Grammar* grammar, Sym name) {
  for (size_t i = 0; i < grammar->rule_count; ++i) {
    if (grammar->rules[i].name == name) {
      return &grammar->rules[i];
    }
  }
  if (!ensure_rule_capacity(grammar)) return NULL;
  GrammarRule* slot = &grammar->rules[grammar->rule_count++];
  memset(slot, 0, sizeof(*slot));
  slot->name = name;
  if (grammar->start_rule == 0) {
    grammar->start_rule = name;
  }
  return slot;
}

static bool parse_pattern(const char* line,
                          size_t len,
                          InternTable* interns,
                          Arena* arena,
                          Production* prod,
                          Str template_text) {
  memset(prod, 0, sizeof(*prod));
  prod->template_text = template_text;
  while (true) {
    trim_whitespace(&line, &len);
    if (len == 0) break;

    bool literal_allocated = false;
    Str raw;
    if (!parse_literal(&line, &len, &raw, &literal_allocated)) {
      return false;
    }

    GrammarAtom atom = {0};
    bool ident_like = (raw.len > 0 && (isalpha((unsigned char)raw.ptr[0]) || raw.ptr[0] == '_'));
    for (size_t i = 1; ident_like && i < raw.len; ++i) {
      if (!isalnum((unsigned char)raw.ptr[i]) && raw.ptr[i] != '_') {
        ident_like = false;
      }
    }
    if (ident_like && raw.ptr[0] != '%' && raw.ptr[0] != '$') {
      if (literal_allocated) free((void*)raw.ptr);
      continue; // Capture name; not a matchable atom.
    }
    if (raw.len > 6 && raw.ptr[0] == '$' && raw.ptr[1] == 'e' &&
        raw.ptr[2] == 'x' && raw.ptr[3] == 'p' && raw.ptr[4] == 'r' &&
        raw.ptr[5] == '[' && raw.ptr[raw.len - 1] == ']') {
      const char* number_start = raw.ptr + 6;
      size_t digits_len = raw.len - 7;
      char* buffer = malloc(digits_len + 1);
      if (!buffer) {
        if (literal_allocated) free((void*)raw.ptr);
        return false;
      }
      memcpy(buffer, number_start, digits_len);
      buffer[digits_len] = '\0';
      char* endptr = NULL;
      unsigned long bp = strtoul(buffer, &endptr, 10);
      if (!endptr || *endptr != '\0') {
        if (literal_allocated) free((void*)raw.ptr);
        free(buffer);
        return false;
      }
      free(buffer);
      atom.kind = GRAMMAR_ATOM_EXPR;
      atom.min_bp = (size_t)bp;
      if (literal_allocated) free((void*)raw.ptr);
    } else if (raw.len > 0 && raw.ptr[0] == '%') {
      Str kind = str_from(raw.ptr + 1, raw.len - 1);
      atom.kind = GRAMMAR_ATOM_TOKEN_KIND;
      atom.symbol = interns_intern(interns, kind);
      if (literal_allocated) free((void*)raw.ptr);
      if (!atom.symbol) {
        return false;
      }
    } else {
      const char* literal_buf = raw.ptr;
      char* stored = arena_push(arena, raw.ptr, raw.len + 1);
      if (!stored) {
        if (literal_allocated) free((void*)raw.ptr);
        return false;
      }
      stored[raw.len] = '\0';
      atom.kind = GRAMMAR_ATOM_LITERAL;
      atom.literal = str_from(stored, raw.len);
      if (literal_allocated) {
        free((void*)literal_buf);
      }
    }

    if (!ensure_atom_capacity(prod)) {
      free(prod->atoms);
      return false;
    }
    prod->atoms[prod->atom_count++] = atom;
  }
  prod->starts_with_expr = (prod->atom_count > 0 && prod->atoms[0].kind == GRAMMAR_ATOM_EXPR);
  return true;
}

bool grammar_load_file(Grammar* grammar,
                       const char* path,
                       InternTable* interns,
                       Arena* arena) {
  if (!grammar || !interns || !arena) return false;
  memset(grammar, 0, sizeof(*grammar));
  grammar->names = interns;

  char* contents = NULL;
  size_t len = 0;
  if (!file_read_all(path, &contents, &len)) {
    return false;
  }

  GrammarRule* current_rule = NULL;
  const char* cursor = contents;
  while (len > 0) {
    const char* line = cursor;
    size_t line_len = 0;
    while (line_len < len && cursor[line_len] != '\n') {
      line_len++;
    }
    cursor += line_len + (line_len < len);
    len -= line_len + (line_len < len);

    trim_whitespace(&line, &line_len);
    if (line_len == 0 || line[0] == '#') continue;

    if (line_len >= 3 && strncmp(line, "end", 3) == 0) {
      current_rule = NULL;
      continue;
    }

    if (line_len >= 5 && strncmp(line, "rule", 4) == 0) {
      const char* name_start = line + 4;
      size_t name_len = line_len - 4;
      trim_whitespace(&name_start, &name_len);
      if (name_len == 0 || name_start[name_len - 1] != ':') {
        free(contents);
        grammar_free(grammar);
        return false;
      }
      name_len -= 1; // Remove trailing ':'
      while (name_len > 0 && isspace((unsigned char)name_start[name_len - 1])) {
        name_len--;
      }
      Str name = str_from(name_start, name_len);
      Sym interned = interns_intern(interns, name);
      if (!interned) {
        free(contents);
        grammar_free(grammar);
        return false;
      }
      current_rule = find_or_add_rule(grammar, interned);
      if (!current_rule) {
        free(contents);
        grammar_free(grammar);
        return false;
      }
      reset_rule(current_rule);
      current_rule->name = interned;
      continue;
    }

    if (!current_rule) {
      free(contents);
      grammar_free(grammar);
      return false;
    }

    const char* arrow = strstr(line, "=>");
    if (!arrow) {
      free(contents);
      grammar_free(grammar);
      return false;
    }
    size_t pattern_len = (size_t)(arrow - line);
    size_t template_len = line_len - pattern_len - 2;
    const char* template_start = arrow + 2;
    trim_whitespace(&template_start, &template_len);
    const char* pattern_start = line;
    trim_whitespace(&pattern_start, &pattern_len);
    char* stored_template = arena_push(arena, template_start, template_len + 1);
    if (!stored_template) {
      free(contents);
      grammar_free(grammar);
      return false;
    }
    stored_template[template_len] = '\0';
    if (!ensure_production_capacity(current_rule)) {
      free(contents);
      grammar_free(grammar);
      return false;
    }
    Production* prod = &current_rule->productions[current_rule->production_count++];
    if (!parse_pattern(pattern_start, pattern_len, interns, arena, prod,
                       str_from(stored_template, template_len))) {
      free(contents);
      grammar_free(grammar);
      return false;
    }
  }

  free(contents);
  return grammar->rule_count > 0;
}

void grammar_free(Grammar* grammar) {
  if (!grammar) return;
  for (size_t i = 0; i < grammar->rule_count; ++i) {
    reset_rule(&grammar->rules[i]);
  }
  free(grammar->rules);
  grammar->rules = NULL;
  grammar->rule_count = grammar->rule_cap = 0;
  grammar->start_rule = 0;
  grammar->names = NULL;
}

static GrammarRule* find_rule(const Grammar* grammar, Sym name) {
  for (size_t i = 0; i < grammar->rule_count; ++i) {
    if (grammar->rules[i].name == name) return &grammar->rules[i];
  }
  return NULL;
}

static bool parse_expr_internal(const ParsedRuleContext* ctx,
                                const struct token* tokens,
                                size_t token_count,
                                size_t min_bp,
                                size_t* cursor,
                                size_t depth);

static bool match_atom(const ParsedRuleContext* ctx,
                       const GrammarAtom* atom,
                       const struct token* tokens,
                       size_t token_count,
                       size_t* cursor,
                       size_t depth) {
  switch (atom->kind) {
    case GRAMMAR_ATOM_LITERAL:
      if (*cursor >= token_count) return false;
      if (!str_eq(tokens[*cursor].lexeme, atom->literal)) return false;
      (*cursor)++;
      return true;
    case GRAMMAR_ATOM_TOKEN_KIND:
      if (*cursor >= token_count) return false;
      if (tokens[*cursor].kind != atom->symbol) return false;
      (*cursor)++;
      return true;
    case GRAMMAR_ATOM_EXPR:
      return parse_expr_internal(ctx, tokens, token_count, atom->min_bp, cursor, depth + 1);
  }
  return false;
}

static bool match_pattern(const ParsedRuleContext* ctx,
                          const Production* prod,
                          const struct token* tokens,
                          size_t token_count,
                          size_t min_bp,
                          bool consume_leading_expr,
                          size_t* cursor,
                          size_t depth) {
  size_t local = *cursor;
  if (depth > PARSER_MAX_DEPTH) return false;
  for (size_t i = 0; i < prod->atom_count; ++i) {
    if (i == 0 && prod->starts_with_expr && consume_leading_expr) {
      if (prod->atoms[i].min_bp < min_bp) return false;
      continue;
    }
    if (!match_atom(ctx, &prod->atoms[i], tokens, token_count, &local, depth)) {
      return false;
    }
  }
  if (consume_leading_expr && prod->atom_count <= 1) {
    return false;
  }
  if (local == *cursor) return false;
  *cursor = local;
  return true;
}

static bool parse_expr_internal(const ParsedRuleContext* ctx,
                                const struct token* tokens,
                                size_t token_count,
                                size_t min_bp,
                                size_t* cursor,
                                size_t depth) {
  if (depth > PARSER_MAX_DEPTH) return false;
  bool prefix_matched = false;
  for (size_t i = 0; i < ctx->rule->production_count; ++i) {
    const Production* prod = &ctx->rule->productions[i];
    if (prod->starts_with_expr) continue;
    size_t local = *cursor;
    if (match_pattern(ctx, prod, tokens, token_count, min_bp, false, &local, depth + 1)) {
      *cursor = local;
      prefix_matched = true;
      break;
    }
  }
  if (!prefix_matched) return false;

  while (true) {
    bool extended = false;
    for (size_t i = 0; i < ctx->rule->production_count; ++i) {
      const Production* prod = &ctx->rule->productions[i];
      if (!prod->starts_with_expr) continue;
      size_t local = *cursor;
      if (match_pattern(ctx, prod, tokens, token_count, min_bp, true, &local, depth + 1)) {
        *cursor = local;
        extended = true;
        break;
      }
    }
    if (!extended) break;
  }
  return true;
}

bool grammar_parse(const Grammar* grammar,
                   Sym start_rule,
                   const struct token* tokens,
                   size_t token_count) {
  if (!grammar || grammar->rule_count == 0) return false;
  size_t parse_count = token_count;
  Sym eof_sym = interns_intern(grammar->names,
                               str_from(LEXER_KIND_EOF, strlen(LEXER_KIND_EOF)));
  if (parse_count > 0 && tokens[parse_count - 1].kind == eof_sym) {
    parse_count--;
  }
  Sym start = start_rule ? start_rule : grammar->start_rule;
  GrammarRule* rule = find_rule(grammar, start);
  if (!rule) return false;
  ParsedRuleContext ctx = {.rule = rule, .grammar = grammar};
  size_t cursor = 0;
  if (!parse_expr_internal(&ctx, tokens, parse_count, 0, &cursor, 0)) return false;
  return cursor == parse_count;
}
