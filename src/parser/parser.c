#include "parser/parser.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include "lexer/lexer.h"
#include "util/file.h"

#define PARSER_MAX_DEPTH 128

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

static bool parse_atom(const char** line,
                       size_t* len,
                       InternTable* interns,
                       Arena* arena,
                       GrammarAtom* out_atom) {
  trim_whitespace(line, len);
  if (*len == 0) return false;
  bool literal_allocated = false;
  Str raw;
  if (!parse_literal(line, len, &raw, &literal_allocated)) return false;
  GrammarAtom atom = {0};
  if (raw.len > 0 && raw.ptr[0] == '$') {
    Str name = str_from(raw.ptr + 1, raw.len - 1);
    atom.kind = GRAMMAR_ATOM_RULE;
    atom.symbol = interns_intern(interns, name);
    if (literal_allocated) free((void*)raw.ptr);
    if (!atom.symbol) return false;
  } else if (raw.len > 0 && raw.ptr[0] == '%') {
    Str kind = str_from(raw.ptr + 1, raw.len - 1);
    atom.kind = GRAMMAR_ATOM_TOKEN_KIND;
    atom.symbol = interns_intern(interns, kind);
    if (literal_allocated) free((void*)raw.ptr);
    if (!atom.symbol) return false;
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
  *out_atom = atom;
  return true;
}

static bool parse_production(const char* line,
                             size_t len,
                             InternTable* interns,
                             Arena* arena,
                             Production* prod) {
  memset(prod, 0, sizeof(*prod));
  while (true) {
    const char* before = line;
    size_t before_len = len;
    GrammarAtom atom;
    if (!parse_atom(&line, &len, interns, arena, &atom)) {
      // No more atoms.
      break;
    }
    if (!ensure_atom_capacity(prod)) {
      free(prod->atoms);
      return false;
    }
    prod->atoms[prod->atom_count++] = atom;
    if (line == before && len == before_len) break;
  }
  return true;
}

static bool parse_rule_line(const char* line,
                            size_t len,
                            Grammar* grammar,
                            InternTable* interns,
                            Arena* arena) {
  trim_whitespace(&line, &len);
  if (len == 0 || line[0] == '#') return true;

  size_t name_len = 0;
  while (name_len < len && !isspace((unsigned char)line[name_len])) {
    name_len++;
  }
  if (name_len == 0) return false;
  Str name = str_from(line, name_len);
  line += name_len;
  len -= name_len;
  trim_whitespace(&line, &len);

  if (len < 2 || !(line[0] == ':' || line[0] == '+') || line[1] != '=') {
    return false;
  }
  char op = line[0];
  line += 2;
  len -= 2;

  GrammarRule* rule = find_or_add_rule(grammar, interns_intern(interns, name));
  if (!rule) return false;
  if (op == ':') {
    reset_rule(rule);
    rule->name = interns_intern(interns, name);
  }

  if (!ensure_production_capacity(rule)) return false;
  Production* prod = &rule->productions[rule->production_count++];
  if (!parse_production(line, len, interns, arena, prod)) return false;
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

  const char* cursor = contents;
  while (len > 0) {
    const char* line = cursor;
    size_t line_len = 0;
    while (line_len < len && cursor[line_len] != '\n') {
      line_len++;
    }
    cursor += line_len + (line_len < len);
    len -= line_len + (line_len < len);

    if (!parse_rule_line(line, line_len, grammar, interns, arena)) {
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

static bool match_atom(const Grammar* grammar,
                       const GrammarAtom* atom,
                       const struct token* tokens,
                       size_t token_count,
                       size_t* cursor,
                       size_t depth);

static bool match_production(const Grammar* grammar,
                             const Production* prod,
                             const struct token* tokens,
                             size_t token_count,
                             size_t* cursor,
                             size_t depth) {
  size_t local_cursor = *cursor;
  for (size_t i = 0; i < prod->atom_count; ++i) {
    if (!match_atom(grammar, &prod->atoms[i], tokens, token_count, &local_cursor, depth)) {
      return false;
    }
  }
  *cursor = local_cursor;
  return true;
}

static bool match_rule(const Grammar* grammar,
                       const GrammarRule* rule,
                       const struct token* tokens,
                       size_t token_count,
                       size_t* cursor,
                       size_t depth) {
  if (depth > PARSER_MAX_DEPTH) return false;
  for (size_t i = 0; i < rule->production_count; ++i) {
    size_t local_cursor = *cursor;
    if (match_production(grammar, &rule->productions[i], tokens, token_count, &local_cursor, depth + 1)) {
      *cursor = local_cursor;
      return true;
    }
  }
  return false;
}

static bool match_atom(const Grammar* grammar,
                       const GrammarAtom* atom,
                       const struct token* tokens,
                       size_t token_count,
                       size_t* cursor,
                       size_t depth) {
  if (atom->kind == GRAMMAR_ATOM_LITERAL) {
    if (*cursor >= token_count) return false;
    Str lexeme = tokens[*cursor].lexeme;
    if (!str_eq(lexeme, atom->literal)) return false;
    (*cursor)++;
    return true;
  }
  if (atom->kind == GRAMMAR_ATOM_TOKEN_KIND) {
    if (*cursor >= token_count) return false;
    if (tokens[*cursor].kind != atom->symbol) return false;
    (*cursor)++;
    return true;
  }
  GrammarRule* rule = find_rule(grammar, atom->symbol);
  if (!rule) return false;
  return match_rule(grammar, rule, tokens, token_count, cursor, depth + 1);
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
  size_t cursor = 0;
  if (!match_rule(grammar, rule, tokens, parse_count, &cursor, 0)) return false;
  return cursor == parse_count;
}
