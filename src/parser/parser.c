#include "parser/parser.h"

#include <ctype.h>
#include <limits.h>
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
    for (size_t j = 0; j < rule->productions[i].atom_count; ++j) {
      if (rule->productions[i].atoms[j].kind == GRAMMAR_ATOM_REPEAT) {
        free(rule->productions[i].atoms[j].subatoms);
      }
    }
    free(rule->productions[i].atoms);
    free(rule->productions[i].templates);
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

// Forward declaration: parse a subpattern (no templates) into atom array.
static bool parse_subpattern_atoms(const char* line,
                                   size_t len,
                                   InternTable* interns,
                                   Arena* arena,
                                   Sym rule_name,
                                   GrammarAtom** out_atoms,
                                   size_t* out_count);

// Split template string on '|' to extract overload alternatives.
// Caller owns the returned array and must free it.
static Str* split_templates(Arena* arena, const char* template_text, size_t template_len, size_t* out_count) {
  if (!template_text || template_len == 0) {
    *out_count = 0;
    return NULL;
  }

  // Count pipes
  size_t pipe_count = 0;
  for (size_t i = 0; i < template_len; ++i) {
    if (template_text[i] == '|') pipe_count++;
  }
  
  size_t count = pipe_count + 1;
  Str* result = (Str*)malloc(count * sizeof(Str));
  if (!result) return NULL;

  const char* cursor = template_text;
  size_t remaining = template_len;
  
  for (size_t i = 0; i < count; ++i) {
    // Find the next pipe or end
    size_t segment_len = 0;
    while (segment_len < remaining && cursor[segment_len] != '|') {
      segment_len++;
    }

    // Trim whitespace
    const char* segment_start = cursor;
    size_t trimmed_len = segment_len;
    while (trimmed_len > 0 && isspace((unsigned char)segment_start[0])) {
      segment_start++; trimmed_len--;
    }
    while (trimmed_len > 0 && isspace((unsigned char)segment_start[trimmed_len - 1])) {
      trimmed_len--;
    }

    // Store in arena
    char* stored = arena_push(arena, segment_start, trimmed_len + 1);
    if (!stored) {
      free(result);
      return NULL;
    }
    stored[trimmed_len] = '\0';
    result[i] = str_from(stored, trimmed_len);

    // Move past the pipe
    cursor += segment_len + (segment_len < remaining ? 1 : 0);
    remaining -= segment_len + (segment_len < remaining ? 1 : 0);
  }

  *out_count = count;
  return result;
}

static bool parse_pattern(const char* line,
                          size_t len,
                          InternTable* interns,
                          Arena* arena,
                          Sym rule_name,
                          Production* prod,
                          const Str* templates,
                          size_t template_count) {
  memset(prod, 0, sizeof(*prod));
  
  // Store templates
  if (template_count > 0) {
    prod->templates = (Str*)malloc(template_count * sizeof(Str));
    if (!prod->templates) return false;
    memcpy(prod->templates, templates, template_count * sizeof(Str));
    prod->template_count = template_count;
    prod->template_capacity = template_count;
  }
  
  while (true) {
    trim_whitespace(&line, &len);
    if (len == 0) break;

    // Inline grouping with repetition: $( ... )+ | * | ?
    if (len >= 2 && line[0] == '$' && line[1] == '(') {
      const char* sub = line + 2;
      size_t remaining = len - 2;
      size_t depth = 1;
      size_t idx = 0;
      while (idx < remaining && depth > 0) {
        char c = sub[idx];
        if (c == '(') depth++;
        else if (c == ')') depth--;
        idx++;
      }
      if (depth != 0) {
        return false; // unmatched parenthesis
      }
      size_t inner_len = idx - 1; // exclude the closing ')'
      const char* after_paren = sub + inner_len + 1;
      size_t after_len = remaining - inner_len - 1;

      GrammarAtom repeat_atom;
      memset(&repeat_atom, 0, sizeof(repeat_atom));
      repeat_atom.kind = GRAMMAR_ATOM_REPEAT;
      repeat_atom.min_occurs = 1;
      repeat_atom.max_occurs = 1;

      if (!parse_subpattern_atoms(sub, inner_len, interns, arena, rule_name,
                                   &repeat_atom.subatoms, &repeat_atom.subatom_count)) {
        return false;
      }
      repeat_atom.subatom_capacity = repeat_atom.subatom_count;

      trim_whitespace(&after_paren, &after_len);
      if (after_len > 0) {
        char q = after_paren[0];
        if (q == '+') {
          repeat_atom.min_occurs = 1;
          repeat_atom.max_occurs = SIZE_MAX;
          after_paren++; after_len--;
        } else if (q == '*') {
          repeat_atom.min_occurs = 0;
          repeat_atom.max_occurs = SIZE_MAX;
          after_paren++; after_len--;
        } else if (q == '?') {
          repeat_atom.min_occurs = 0;
          repeat_atom.max_occurs = 1;
          after_paren++; after_len--;
        }
      }

      if (!ensure_atom_capacity(prod)) {
        free(repeat_atom.subatoms);
        return false;
      }
      prod->atoms[prod->atom_count++] = repeat_atom;

      // Advance line/len past the group (and optional quantifier) for next atom
      line = after_paren;
      len = after_len;
      continue;
    }

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
    if (raw.len > 1 && raw.ptr[0] == '$') {
      size_t name_len = 0;
      while (1 + name_len < raw.len && raw.ptr[1 + name_len] != '[') {
        name_len++;
      }
      if (name_len == 0) {
        if (literal_allocated) free((void*)raw.ptr);
        return false;
      }

      size_t bp = 0;
      if (1 + name_len < raw.len) {
        if (raw.ptr[1 + name_len] != '[' || raw.ptr[raw.len - 1] != ']') {
          if (literal_allocated) free((void*)raw.ptr);
          return false;
        }
        size_t digits_len = raw.len - name_len - 3; // exclude '$', name, '[' and ']'
        char* buffer = malloc(digits_len + 1);
        if (!buffer) {
          if (literal_allocated) free((void*)raw.ptr);
          return false;
        }
        memcpy(buffer, raw.ptr + name_len + 2, digits_len);
        buffer[digits_len] = '\0';
        char* endptr = NULL;
        unsigned long parsed = strtoul(buffer, &endptr, 10);
        bool parsed_ok = (endptr && *endptr == '\0');
        free(buffer);
        if (!parsed_ok) {
          if (literal_allocated) free((void*)raw.ptr);
          return false;
        }
        bp = (size_t)parsed;
      }

      Str name = str_from(raw.ptr + 1, name_len);
      atom.kind = GRAMMAR_ATOM_RULE;
      atom.symbol = interns_intern(interns, name);
      atom.min_bp = bp;
      if (!atom.symbol) {
        if (literal_allocated) free((void*)raw.ptr);
        return false;
      }
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
  prod->starts_with_expr =
      (prod->atom_count > 0 && prod->atoms[0].kind == GRAMMAR_ATOM_RULE &&
       prod->atoms[0].symbol == rule_name);
  return true;
}

// Parse a subpattern (no templates) into an atom array. Ownership of atoms is returned to caller.
static bool parse_subpattern_atoms(const char* line,
                                   size_t len,
                                   InternTable* interns,
                                   Arena* arena,
                                   Sym rule_name,
                                   GrammarAtom** out_atoms,
                                   size_t* out_count) {
  if (!out_atoms || !out_count) return false;
  Production temp;
  memset(&temp, 0, sizeof(temp));
  if (!parse_pattern(line, len, interns, arena, rule_name, &temp, NULL, 0)) {
    return false;
  }
  *out_atoms = temp.atoms;
  *out_count = temp.atom_count;
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
    
    // Split templates on '|' to extract overload alternatives
    size_t template_count = 0;
    Str* templates = split_templates(arena, template_start, template_len, &template_count);
    if (template_count == 0) {
      free(contents);
      grammar_free(grammar);
      free(templates);
      return false;
    }
    
    if (!ensure_production_capacity(current_rule)) {
      free(contents);
      grammar_free(grammar);
      free(templates);
      return false;
    }
    Production* prod = &current_rule->productions[current_rule->production_count++];
    if (!parse_pattern(pattern_start, pattern_len, interns, arena, current_rule->name, prod,
                       templates, template_count)) {
      free(contents);
      grammar_free(grammar);
      free(templates);
      return false;
    }
    free(templates);
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

static bool parse_rule_internal(const ParsedRuleContext* ctx,
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
    case GRAMMAR_ATOM_RULE: {
      GrammarRule* target = find_rule(ctx->grammar, atom->symbol);
      if (!target) return false;
      ParsedRuleContext nested = {.rule = target, .grammar = ctx->grammar};
      return parse_rule_internal(&nested, tokens, token_count, atom->min_bp, cursor, depth + 1);
    }
    case GRAMMAR_ATOM_REPEAT: {
      size_t count = 0;
      size_t local = *cursor;
      while (count < atom->max_occurs) {
        size_t iter_cursor = local;
        bool ok = true;
        for (size_t i = 0; i < atom->subatom_count; ++i) {
          if (!match_atom(ctx, &atom->subatoms[i], tokens, token_count, &iter_cursor, depth + 1)) {
            ok = false;
            break;
          }
        }
        if (!ok) break;
        local = iter_cursor;
        count++;
        if (count == atom->max_occurs) break;
      }
      if (count < atom->min_occurs) return false;
      *cursor = local;
      return true;
    }
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

static bool parse_rule_internal(const ParsedRuleContext* ctx,
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
  if (!parse_rule_internal(&ctx, tokens, parse_count, 0, &cursor, 0)) return false;
  return cursor == parse_count;
}
