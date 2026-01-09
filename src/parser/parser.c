#include "parser/parser.h"

#include <ctype.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lexer/lexer.h"
#include "util/file.h"
#include "util/error.h"
#include "ast/ast.h"
#include "parser/operators.h"

#define PARSER_MAX_DEPTH 128

typedef struct ParsedRuleContext {
  const GrammarRule* rule;
  const Grammar* grammar;
} ParsedRuleContext;

static bool parse_rule_internal_ast(const ParsedRuleContext* ctx,
                                    const struct token* tokens,
                                    size_t token_count,
                                    size_t min_bp,
                                    size_t* cursor,
                                    size_t depth,
                                    AstNode** out_node);

typedef struct Capture {
  Sym name;
  AstNode** nodes;
  size_t count;
  size_t capacity;
} Capture;

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

static Capture* ensure_capture(Capture** captures, size_t* capture_count, Sym name);

static Capture* find_capture(Capture* captures, size_t capture_count, Sym name) {
  for (size_t i = 0; i < capture_count; ++i) {
    if (captures[i].name == name) return &captures[i];
  }
  return NULL;
}

static Capture* ensure_capture(Capture** captures, size_t* capture_count, Sym name) {
  Capture* existing = find_capture(*captures, *capture_count, name);
  if (existing) return existing;
  size_t new_count = *capture_count + 1;
  Capture* resized = realloc(*captures, new_count * sizeof(Capture));
  if (!resized) return NULL;
  *captures = resized;
  Capture* slot = &(*captures)[*capture_count];
  memset(slot, 0, sizeof(*slot));
  slot->name = name;
  *capture_count = new_count;
  return slot;
}

static bool capture_append(Capture* cap, AstNode* node) {
  if (!cap || !node) return false;
  if (cap->count == cap->capacity) {
    size_t new_cap = cap->capacity ? cap->capacity * 2 : 4;
    AstNode** resized = realloc(cap->nodes, new_cap * sizeof(AstNode*));
    if (!resized) return false;
    cap->nodes = resized;
    cap->capacity = new_cap;
  }
  cap->nodes[cap->count++] = node;
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
    if (allocated) *allocated = true;  // Signal that this was a quoted literal
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
  
  Sym pending_capture = 0;

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
      // If a capture was seen immediately before, attach to this repeat atom.
      repeat_atom.capture = pending_capture;
      pending_capture = 0;
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
    // If identifier-like, not starting with % or $, AND not quoted, treat as capture label
    if (ident_like && raw.ptr[0] != '%' && raw.ptr[0] != '$' && !literal_allocated) {
      Sym cap = interns_intern(interns, raw);
      if (literal_allocated) free((void*)raw.ptr);
      if (!cap) return false;

      // Prefer attaching to the most recent atom; otherwise defer to the next one.
      bool attached = false;
      if (prod->atom_count > 0) {
        GrammarAtom* prev = &prod->atoms[prod->atom_count - 1];
        if (prev->capture == 0) {
          prev->capture = cap;
          attached = true;
        }
      }
      if (!attached) pending_capture = cap;
      continue; // Capture label applied; move to next token.
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
    atom.capture = pending_capture;
    pending_capture = 0;
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
      
      // Warn if rule name starts with $ (builtin namespace)
      if (name_len > 0 && name_start[0] == '$') {
        MorphlError err = MORPHL_WARN(MORPHL_E_PARSE,
            "custom rule '%.*s' redefines builtin operator namespace",
            (int)name_len, name_start);
        morphl_error_emit(NULL, &err);
      }
      
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
    memset(prod, 0, sizeof(*prod));
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

// ---------- AST construction path (experimental) ----------

static AstNode* ast_group_from_list(AstNode** nodes, size_t count) {
  AstNode* g = ast_new(AST_GROUP);
  if (!g) return NULL;
  for (size_t i = 0; i < count; ++i) {
    if (!ast_append_child(g, nodes[i])) return g; // best effort
  }
  if (count > 0) {
    g->filename = nodes[0]->filename;
    g->row = nodes[0]->row;
    g->col = nodes[0]->col;
  }
  return g;
}

static void flatten_and_append(AstNode* parent, AstNode* node) {
  if (!parent || !node) return;
  if (node->kind == AST_GROUP) {
    // Always recursively flatten group nodes (expand their children)
    for (size_t i = 0; i < node->child_count; ++i) {
      flatten_and_append(parent, node->children[i]);
    }
  } else {
    // Non-group node: add directly
    ast_append_child(parent, node);
  }
}

static AstNode* ast_clone_tree(const AstNode* node) {
  if (!node) return NULL;
  AstNode* copy = ast_new(node->kind);
  if (!copy) return NULL;
  copy->op = node->op;
  copy->value = node->value;
  copy->filename = node->filename;
  copy->row = node->row;
  copy->col = node->col;

  for (size_t i = 0; i < node->child_count; ++i) {
    AstNode* child = ast_clone_tree(node->children[i]);
    if (!child || !ast_append_child(copy, child)) {
      ast_free(child);
      ast_free(copy);
      return NULL;
    }
  }
  return copy;
}

static void release_captures(Capture* caps, size_t count, bool free_nodes) {
  if (!caps) return;
  for (size_t i = 0; i < count; ++i) {
    if (free_nodes) {
      for (size_t j = 0; j < caps[i].count; ++j) {
        ast_free(caps[i].nodes[j]);
      }
    }
    free(caps[i].nodes);
  }
  free(caps);
}

static Capture* clone_captures(const Capture* caps, size_t count) {
  if (!caps || count == 0) return NULL;
  Capture* cloned = (Capture*)calloc(count, sizeof(Capture));
  if (!cloned) return NULL;

  for (size_t i = 0; i < count; ++i) {
    cloned[i].name = caps[i].name;
    cloned[i].count = caps[i].count;
    if (caps[i].count == 0) continue;

    cloned[i].nodes = (AstNode**)malloc(caps[i].count * sizeof(AstNode*));
    if (!cloned[i].nodes) {
      release_captures(cloned, count, true);
      return NULL;
    }

    for (size_t j = 0; j < caps[i].count; ++j) {
      cloned[i].nodes[j] = ast_clone_tree(caps[i].nodes[j]);
      if (!cloned[i].nodes[j]) {
        release_captures(cloned, count, true);
        return NULL;
      }
    }
  }

  return cloned;
}

static AstNode* build_template_ast(const Production* prod,
                                   size_t template_index,
                                   Capture* captures,
                                   size_t capture_count,
                                   InternTable* interns) {
  if (template_index >= prod->template_count) return NULL;
  Str tmpl = prod->templates[template_index];
  const char* cur = tmpl.ptr;
  size_t rem = tmpl.len;
  // Parse tokens by whitespace
  #define NEXT_TOKEN(tok, tok_len)                             \
    const char* tok = cur;                                     \
    size_t tok_len = 0;                                        \
    while (tok_len < rem && !isspace((unsigned char)tok[tok_len])) tok_len++; \
    cur += tok_len; rem -= tok_len;                            \
    while (rem > 0 && isspace((unsigned char)*cur)) { cur++; rem--; }

  NEXT_TOKEN(op_tok, op_len);
  if (op_len == 0) return NULL;
  Sym op_sym = interns_intern(interns, str_from(op_tok, op_len));
  if (!op_sym) return NULL;
  
  // Determine AST kind from operator registry
  AstKind op_kind = AST_BUILTIN;
  const OperatorInfo* info = operator_info_lookup(op_sym);
  if (info && info->ast_kind != AST_UNKNOWN) {
    op_kind = info->ast_kind;
  }
  
  AstNode* root = ast_new(op_kind);
  if (!root) return NULL;
  root->op = op_sym;

  while (rem > 0) {
    NEXT_TOKEN(arg_tok, arg_len);
    if (arg_len == 0) break;

    // Check for $spread operator (exactly "$spread" followed by a capture name)
    if (arg_len == 7 && strncmp(arg_tok, "$spread", 7) == 0) {
      // Next token is the capture name to spread
      NEXT_TOKEN(name_tok, name_len);
      if (name_len == 0) { ast_free(root); return NULL; }
      Sym cap_sym = interns_intern(interns, str_from(name_tok, name_len));
      if (!cap_sym) { ast_free(root); return NULL; }
      Capture* cap = find_capture(captures, capture_count, cap_sym);
      if (!cap || cap->count == 0) { ast_free(root); return NULL; }

      // Spread: recursively flatten all nodes
      for (size_t i = 0; i < cap->count; ++i) {
        flatten_and_append(root, cap->nodes[i]);
      }
      continue;
    }

    // Regular capture reference
    Sym cap_sym = interns_intern(interns, str_from(arg_tok, arg_len));
    if (!cap_sym) { ast_free(root); return NULL; }
    Capture* cap = find_capture(captures, capture_count, cap_sym);
    if (!cap || cap->count == 0) { ast_free(root); return NULL; }
    AstNode* child = NULL;
    if (cap->count == 1) {
      child = cap->nodes[0];
    } else {
      child = ast_group_from_list(cap->nodes, cap->count);
    }
    if (!child || !ast_append_child(root, child)) { ast_free(root); return NULL; }
  }

  if (root->child_count > 0) {
    root->filename = root->children[0]->filename;
    root->row = root->children[0]->row;
    root->col = root->children[0]->col;
  }
  return root;

#undef NEXT_TOKEN
}

static void free_captures(Capture* caps, size_t count) {
  if (!caps) return;
  for (size_t i = 0; i < count; ++i) {
    free(caps[i].nodes); // nodes owned by AST; do not free nodes themselves
  }
  free(caps);
}

static bool template_is_leaf(const Production* prod, size_t template_index) {
  if (template_index >= prod->template_count) return false;
  Str tmpl = prod->templates[template_index];
  const char* cur = tmpl.ptr;
  size_t rem = tmpl.len;
  while (rem > 0 && isspace((unsigned char)*cur)) { cur++; rem--; }
  size_t tok_len = 0;
  while (tok_len < rem && !isspace((unsigned char)cur[tok_len])) tok_len++;
  cur += tok_len; rem -= tok_len;
  while (rem > 0 && isspace((unsigned char)*cur)) { cur++; rem--; }
  return tok_len > 0 && rem == 0;
}

static AstNode* build_prod_result(const Production* prod,
                                  Capture* caps,
                                  size_t cap_count,
                                  InternTable* interns,
                                  AstNode* first_node) {
  if (prod->template_count == 1) {
    if (template_is_leaf(prod, 0) && first_node) return first_node;
    return build_template_ast(prod, 0, caps, cap_count, interns);
  }
  if (prod->template_count > 1) {
    AstNode* overload = ast_new(AST_OVERLOAD);
    if (!overload) return NULL;
    for (size_t t = 0; t < prod->template_count; ++t) {
      Capture* cloned_caps = cap_count ? clone_captures(caps, cap_count) : NULL;
      if (cap_count && !cloned_caps) { ast_free(overload); return NULL; }
      AstNode* cand = build_template_ast(prod, t,
                                         cloned_caps ? cloned_caps : caps,
                                         cap_count, interns);
      release_captures(cloned_caps, cap_count, cand == NULL);
      if (!cand || !ast_append_child(overload, cand)) {
        if (cand) ast_free(cand);
        ast_free(overload);
        return NULL;
      }
    }
    return overload;
  }
  return NULL;
}

static bool match_atom_ast(const ParsedRuleContext* ctx,
                           const GrammarAtom* atom,
                           const struct token* tokens,
                           size_t token_count,
                           size_t* cursor,
                           size_t depth,
                           Capture** captures,
                           size_t* capture_count,
                           AstNode** out_node) {
  if (out_node) *out_node = NULL;
  switch (atom->kind) {
    case GRAMMAR_ATOM_LITERAL:
      if (*cursor >= token_count) return false;
      if (!str_eq(tokens[*cursor].lexeme, atom->literal)) return false;
      if (out_node && atom->capture) {
        AstNode* leaf = ast_make_leaf(AST_LITERAL, tokens[*cursor].lexeme,
                                      tokens[*cursor].filename, tokens[*cursor].row, tokens[*cursor].col);
        *out_node = leaf;
        Capture* c = ensure_capture(captures, capture_count, atom->capture);
        if (!c || !capture_append(c, leaf)) return false;
      }
      (*cursor)++;
      return true;
    case GRAMMAR_ATOM_TOKEN_KIND:
      if (*cursor >= token_count) return false;
      if (tokens[*cursor].kind != atom->symbol) return false;
      if (out_node) {
        AstKind kind = AST_LITERAL;
        // Heuristic: IDENT token kind -> AST_IDENT
        Sym ident_sym = interns_intern(ctx->grammar->names,
                                       str_from(LEXER_KIND_IDENT, strlen(LEXER_KIND_IDENT)));
        if (ident_sym && tokens[*cursor].kind == ident_sym) {
          kind = AST_IDENT;
        }
        AstNode* leaf = ast_make_leaf(kind, tokens[*cursor].lexeme,
                                      tokens[*cursor].filename, tokens[*cursor].row, tokens[*cursor].col);
        *out_node = leaf;
        if (atom->capture) {
          Capture* c = ensure_capture(captures, capture_count, atom->capture);
          if (!c || !capture_append(c, leaf)) return false;
        }
      }
      (*cursor)++;
      return true;
    case GRAMMAR_ATOM_RULE: {
      GrammarRule* target = find_rule(ctx->grammar, atom->symbol);
      if (!target) return false;
      ParsedRuleContext nested = {.rule = target, .grammar = ctx->grammar};
      AstNode* sub = NULL;
      if (!parse_rule_internal_ast(&nested, tokens, token_count, atom->min_bp, cursor, depth + 1, &sub)) {
        return false;
      }
      if (out_node) {
        *out_node = sub;
        if (atom->capture) {
          Capture* c = ensure_capture(captures, capture_count, atom->capture);
          if (!c || !capture_append(c, sub)) return false;
        }
      } else {
        ast_free(sub);
      }
      return true;
    }
    case GRAMMAR_ATOM_REPEAT: {
      size_t count = 0;
      size_t local = *cursor;
      AstNode** rep_nodes = NULL;
      size_t rep_count = 0, rep_cap = 0;
      while (count < atom->max_occurs) {
        size_t iter_cursor = local;
        bool ok = true;
        AstNode** sub_nodes = NULL;
        size_t sub_count = 0, sub_cap = 0;
        for (size_t i = 0; i < atom->subatom_count; ++i) {
          AstNode* subnode = NULL;
          if (!match_atom_ast(ctx, &atom->subatoms[i], tokens, token_count, &iter_cursor, depth + 1,
                              captures, capture_count, &subnode)) {
            ok = false;
            break;
          }
          if (subnode) {
            if (sub_count == sub_cap) {
              size_t new_cap = sub_cap ? sub_cap * 2 : 4;
              AstNode** tmp = realloc(sub_nodes, new_cap * sizeof(AstNode*));
              if (!tmp) { ok = false; break; }
              sub_nodes = tmp; sub_cap = new_cap;
            }
            sub_nodes[sub_count++] = subnode;
          }
        }
        if (!ok) { free(sub_nodes); break; }
        local = iter_cursor;
        count++;
        AstNode* group = ast_group_from_list(sub_nodes, sub_count);
        free(sub_nodes);
        if (group) {
          if (rep_count == rep_cap) {
            size_t new_cap = rep_cap ? rep_cap * 2 : 4;
            AstNode** tmp = realloc(rep_nodes, new_cap * sizeof(AstNode*));
            if (!tmp) { ast_free(group); break; }
            rep_nodes = tmp; rep_cap = new_cap;
          }
          rep_nodes[rep_count++] = group;
        }
        if (count == atom->max_occurs) break;
      }
      if (count < atom->min_occurs) { free(rep_nodes); return false; }
      *cursor = local;
      AstNode* produced = ast_group_from_list(rep_nodes, rep_count);
      free(rep_nodes);
      if (out_node) *out_node = produced;
      if (atom->capture && produced) {
        Capture* c = ensure_capture(captures, capture_count, atom->capture);
        if (!c || !capture_append(c, produced)) return false;
      }
      return true;
    }
  }
  return false;
}

static bool match_pattern_ast(const ParsedRuleContext* ctx,
                              const Production* prod,
                              const struct token* tokens,
                              size_t token_count,
                              size_t min_bp,
                              bool consume_leading_expr,
                              size_t* cursor,
                              size_t depth,
                              Capture** captures,
                              size_t* capture_count,
                              AstNode** first_node,
                              bool collect_all_nodes) {
  size_t local = *cursor;
  if (depth > PARSER_MAX_DEPTH) return false;
  for (size_t i = 0; i < prod->atom_count; ++i) {
    if (i == 0 && prod->starts_with_expr && consume_leading_expr) {
      if (prod->atoms[i].min_bp < min_bp) return false;
      continue;
    }
    AstNode* produced = NULL;
    AstNode** out_slot = (collect_all_nodes || prod->atoms[i].capture) ? &produced : NULL;
    if (!match_atom_ast(ctx, &prod->atoms[i], tokens, token_count, &local, depth, captures, capture_count, out_slot)) {
      return false;
    }
    if (first_node && produced && *first_node == NULL) {
      *first_node = produced;
    }
  }
  if (consume_leading_expr && prod->atom_count <= 1) {
    return false;
  }
  if (local == *cursor) return false;
  *cursor = local;
  return true;
}


static bool parse_rule_internal_ast(const ParsedRuleContext* ctx,
                                    const struct token* tokens,
                                    size_t token_count,
                                    size_t min_bp,
                                    size_t* cursor,
                                    size_t depth,
                                    AstNode** out_node) {
  if (depth > PARSER_MAX_DEPTH) return false;
  AstNode* lhs = NULL;

  // Prefix: productions that do not consume a leading expression
  for (size_t i = 0; i < ctx->rule->production_count; ++i) {
    const Production* prod = &ctx->rule->productions[i];
    if (prod->starts_with_expr) continue;
    size_t local = *cursor;
    Capture* caps = NULL; size_t cap_count = 0;
    AstNode* first = NULL;
    bool want_first = template_is_leaf(prod, 0);
    if (!match_pattern_ast(ctx, prod, tokens, token_count, min_bp, false, &local, depth + 1, &caps, &cap_count,
                           want_first ? &first : NULL, want_first)) {
      free_captures(caps, cap_count);
      continue;
    }
    AstNode* result = build_prod_result(prod, caps, cap_count, ctx->grammar->names, first);
    free_captures(caps, cap_count);
    if (result) {
      lhs = result;
      *cursor = local;
      break;
    }
  }

  if (!lhs) return false;

  // Infix/postfix: productions that extend a leading expression
  while (true) {
    bool extended = false;
    for (size_t i = 0; i < ctx->rule->production_count; ++i) {
      const Production* prod = &ctx->rule->productions[i];
      if (!prod->starts_with_expr) continue;
      if (prod->atom_count == 0) continue;
      size_t local = *cursor;
      Capture* caps = NULL; size_t cap_count = 0;

      // Seed captures with the already-parsed lhs if the first atom requests it
      const GrammarAtom* first = &prod->atoms[0];
      if (first->capture) {
        Capture* c = ensure_capture(&caps, &cap_count, first->capture);
        if (!c || !capture_append(c, lhs)) { free_captures(caps, cap_count); continue; }
      }

      if (!match_pattern_ast(ctx, prod, tokens, token_count, min_bp, true, &local, depth + 1, &caps, &cap_count, NULL, false)) {
        free_captures(caps, cap_count);
        continue;
      }

      AstNode* result = build_prod_result(prod, caps, cap_count, ctx->grammar->names, NULL);
      free_captures(caps, cap_count);
      if (!result) continue;

      lhs = result;
      *cursor = local;
      extended = true;
      break;
    }
    if (!extended) break;
  }

  if (out_node) {
    *out_node = lhs;
  } else {
    ast_free(lhs);
  }
  return true;
}


bool grammar_parse_ast(const Grammar* grammar,
                       Sym start_rule,
                       const struct token* tokens,
                       size_t token_count,
                       AstNode** out_root) {
  if (!grammar || grammar->rule_count == 0 || !out_root) return false;
  *out_root = NULL;
  size_t parse_count = token_count;
  Sym eof_sym = interns_intern(grammar->names,
                               str_from(LEXER_KIND_EOF, strlen(LEXER_KIND_EOF)));
  if (parse_count > 0 && tokens[parse_count - 1].kind == eof_sym) {
    parse_count--;
  }
  Sym start = start_rule ? start_rule : grammar->start_rule;
  GrammarRule* rule = find_rule(grammar, start);
  if (!rule) {
    MorphlError err = MORPHL_ERR(MORPHL_E_PARSE, "start rule not found in grammar");
    morphl_error_emit(NULL, &err);
    return false;
  }
  ParsedRuleContext ctx = {.rule = rule, .grammar = grammar};
  size_t cursor = 0;
  AstNode* root = NULL;
  if (!parse_rule_internal_ast(&ctx, tokens, parse_count, 0, &cursor, 0, &root)) {
    return false;
  }
  if (cursor != parse_count) {
    MorphlError err = MORPHL_ERR(MORPHL_E_PARSE,
        "parse stopped at token %llu of %llu: '%.*s'",
        (unsigned long long)cursor, (unsigned long long)parse_count,
        (int)tokens[cursor].lexeme.len,
        tokens[cursor].lexeme.ptr ? tokens[cursor].lexeme.ptr : "");
    morphl_error_emit(NULL, &err);
    ast_free(root);
    return false;
  }
  *out_root = root;
  return true;
}
