#include "parser/scoped_parser.h"
#include "parser/builtin_parser.h"
#include "lexer/lexer.h"
#include "parser/operators.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Token kind constants from lexer
extern const char* const LEXER_KIND_IDENT;
extern const char* const LEXER_KIND_NUMBER;
extern const char* const LEXER_KIND_SYMBOL;
extern const char* const LEXER_KIND_EOF;

bool scoped_parser_init(ScopedParserContext* ctx, InternTable* interns, Arena* arena) {
  if (!ctx || !interns || !arena) return false;
  
  ctx->grammar_stack = NULL;
  ctx->grammar_stack_size = 0;
  ctx->grammar_stack_cap = 0;
  ctx->interns = interns;
  ctx->arena = arena;
  ctx->use_builtins = true; // Start with builtin-only
  
  return true;
}

void scoped_parser_free(ScopedParserContext* ctx) {
  if (!ctx) return;
  
  // Free all grammars on the stack
  for (size_t i = 0; i < ctx->grammar_stack_size; ++i) {
    if (ctx->grammar_stack[i]) {
      grammar_free(ctx->grammar_stack[i]);
      free(ctx->grammar_stack[i]);
    }
  }
  
  free(ctx->grammar_stack);
  ctx->grammar_stack = NULL;
  ctx->grammar_stack_size = 0;
  ctx->grammar_stack_cap = 0;
}

bool scoped_parser_push_grammar(ScopedParserContext* ctx, Grammar* grammar) {
  if (!ctx) return false;
  
  // Grow stack if needed
  if (ctx->grammar_stack_size >= ctx->grammar_stack_cap) {
    size_t new_cap = ctx->grammar_stack_cap ? ctx->grammar_stack_cap * 2 : 4;
    Grammar** resized = realloc(ctx->grammar_stack, new_cap * sizeof(Grammar*));
    if (!resized) return false;
    ctx->grammar_stack = resized;
    ctx->grammar_stack_cap = new_cap;
  }
  
  ctx->grammar_stack[ctx->grammar_stack_size++] = grammar;
  ctx->use_builtins = (grammar == NULL);
  
  return true;
}

bool scoped_parser_pop_grammar(ScopedParserContext* ctx) {
  if (!ctx || ctx->grammar_stack_size == 0) return false;
  
  // Free the top grammar
  Grammar* top = ctx->grammar_stack[--ctx->grammar_stack_size];
  if (top) {
    grammar_free(top);
    free(top);
  }
  
  // Update use_builtins based on new top
  if (ctx->grammar_stack_size > 0) {
    ctx->use_builtins = (ctx->grammar_stack[ctx->grammar_stack_size - 1] == NULL);
  } else {
    ctx->use_builtins = true;
  }
  
  return true;
}

bool scoped_parser_replace_grammar(ScopedParserContext* ctx, const char* grammar_path) {
  if (!ctx || !grammar_path) return false;
  
  // Load new grammar
  Grammar* new_grammar = malloc(sizeof(Grammar));
  if (!new_grammar) return false;
  
  if (!grammar_load_file(new_grammar, grammar_path, ctx->interns, ctx->arena)) {
    free(new_grammar);
    fprintf(stderr, "warning: failed to load grammar from '%s', keeping current grammar\n", grammar_path);
    return false;
  }
  
  // Replace current scope's grammar
  if (ctx->grammar_stack_size > 0) {
    Grammar* old = ctx->grammar_stack[ctx->grammar_stack_size - 1];
    if (old) {
      grammar_free(old);
      free(old);
    }
    ctx->grammar_stack[ctx->grammar_stack_size - 1] = new_grammar;
    ctx->use_builtins = false;
  } else {
    // No scope yet, push as first grammar
    if (!scoped_parser_push_grammar(ctx, new_grammar)) {
      grammar_free(new_grammar);
      free(new_grammar);
      return false;
    }
  }
  
  return true;
}

Grammar* scoped_parser_current_grammar(ScopedParserContext* ctx) {
  if (!ctx || ctx->grammar_stack_size == 0) return NULL;
  return ctx->grammar_stack[ctx->grammar_stack_size - 1];
}

// Forward declaration
static bool scoped_parse_expr(ScopedParserContext* ctx,
                              const struct token* tokens,
                              size_t token_count,
                              size_t* cursor,
                              size_t depth,
                              AstNode** out_node);

// Preprocessor hook executor: returns true if node should be kept, false if dropped
static bool apply_preprocessor_if_any(ScopedParserContext* ctx, AstNode* node) {
  if (!node || node->kind != AST_BUILTIN || !node->op) return true;
  const OperatorInfo* info = operator_info_lookup(node->op);
  if (!info || !info->is_preprocessor || !info->func) return true;
  info->func(info, ctx, NULL, node->children, node->child_count);
  return info->pp_policy != OP_PP_DROP_NODE;
}

/**
 * @brief Parse a sequence of statements within a scope.
 *
 * Handles $syntax directives by reloading grammar and reparsing subsequent statements.
 */
static bool scoped_parse_block_contents(ScopedParserContext* ctx,
                                        const struct token* tokens,
                                        size_t token_count,
                                        size_t* cursor,
                                        size_t depth,
                                        AstNode*** out_children,
                                        size_t* out_count) {
  // Intern token kinds
  TokenKind symbol_kind = interns_intern(ctx->interns, str_from(LEXER_KIND_SYMBOL, strlen(LEXER_KIND_SYMBOL)));
  TokenKind eof_kind = interns_intern(ctx->interns, str_from(LEXER_KIND_EOF, strlen(LEXER_KIND_EOF)));
  
  AstNode** children = NULL;
  size_t child_count = 0;
  size_t child_capacity = 0;
  
  while (*cursor < token_count && tokens[*cursor].kind != eof_kind) {
    // Check for block end
    if (tokens[*cursor].kind == symbol_kind && 
        tokens[*cursor].lexeme.len == 1 && 
        tokens[*cursor].lexeme.ptr[0] == '}') {
      break;
    }

    // If a custom grammar is active, parse the remaining tokens in this scope with it.
    if (!ctx->use_builtins) {
      Grammar* grammar = scoped_parser_current_grammar(ctx);
      if (!grammar) {
        for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
        free(children);
        return false;
      }

      size_t remaining = token_count - *cursor;
      AstNode* grammar_root = NULL;
      if (!grammar_parse_ast(grammar, 0, tokens + *cursor, remaining, &grammar_root)) {
        const struct token* t = (remaining > 0) ? &tokens[*cursor] : NULL;
        fprintf(stderr, "scoped parse: grammar parse failed at offset %zu (remaining %zu) tok='%.*s'\n",
                *cursor, remaining,
                t ? (int)t->lexeme.len : 0,
                t && t->lexeme.ptr ? t->lexeme.ptr : "");
        size_t preview = remaining < 12 ? remaining : 12;
        fprintf(stderr, "preview tokens:");
        for (size_t pi = 0; pi < preview; ++pi) {
          const struct token* pt = &tokens[*cursor + pi];
          fprintf(stderr, " [%.*s]", (int)pt->lexeme.len, pt->lexeme.ptr);
        }
        fprintf(stderr, "\n");
        for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
        free(children);
        return false;
      }

      bool is_spread = false;
      if (grammar_root && grammar_root->kind == AST_BUILTIN && grammar_root->op) {
        Str op_name = interns_lookup(ctx->interns, grammar_root->op);
        if (op_name.len == 7 && strncmp(op_name.ptr, "$spread", 7) == 0) {
          is_spread = true;
        }
      }

      if (is_spread) {
        size_t spread_count = grammar_root->child_count;
        if (spread_count > 0) {
          size_t needed = child_count + spread_count;
          if (needed > child_capacity) {
            size_t new_cap = child_capacity ? child_capacity : 4;
            while (new_cap < needed) new_cap *= 2;
            AstNode** resized = realloc(children, new_cap * sizeof(AstNode*));
            if (!resized) {
              ast_free(grammar_root);
              for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
              free(children);
              return false;
            }
            children = resized;
            child_capacity = new_cap;
          }
          for (size_t i = 0; i < spread_count; ++i) {
            children[child_count++] = grammar_root->children[i];
          }
        }
        free(grammar_root->children);
        grammar_root->children = NULL;
        grammar_root->child_count = 0;
        grammar_root->child_capacity = 0;
        ast_free(grammar_root);
      } else {
        if (child_count >= child_capacity) {
          size_t new_cap = child_capacity ? child_capacity * 2 : 4;
          AstNode** resized = realloc(children, new_cap * sizeof(AstNode*));
          if (!resized) {
            ast_free(grammar_root);
            for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
            free(children);
            return false;
          }
          children = resized;
          child_capacity = new_cap;
        }
        children[child_count++] = grammar_root;
      }

      // Grammar parser consumes all remaining tokens in this scope.
      *cursor = token_count;
      break;
    }
    
    // Parse statement
    AstNode* stmt = NULL;
    if (!scoped_parse_expr(ctx, tokens, token_count, cursor, depth + 1, &stmt)) {
      for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
      free(children);
      return false;
    }
    
    // Apply preprocessor action if needed
    bool keep = apply_preprocessor_if_any(ctx, stmt);
    if (keep) {
      // Add statement to children
      if (child_count >= child_capacity) {
        size_t new_cap = child_capacity ? child_capacity * 2 : 4;
        AstNode** resized = realloc(children, new_cap * sizeof(AstNode*));
        if (!resized) {
          ast_free(stmt);
          for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
          free(children);
          return false;
        }
        children = resized;
        child_capacity = new_cap;
      }
      children[child_count++] = stmt;
    } else {
      ast_free(stmt);
    }
    
    // Skip optional semicolons
    if (*cursor < token_count && 
        tokens[*cursor].kind == symbol_kind &&
        tokens[*cursor].lexeme.len == 1 &&
        tokens[*cursor].lexeme.ptr[0] == ';') {
      (*cursor)++;
    }
  }
  
  *out_children = children;
  *out_count = child_count;
  return true;
}

/**
 * @brief Parse a single expression, potentially with custom grammar.
 */
static bool scoped_parse_expr(ScopedParserContext* ctx,
                              const struct token* tokens,
                              size_t token_count,
                              size_t* cursor,
                              size_t depth,
                              AstNode** out_node) {
  if (depth > 128) return false; // Max depth check
  
  Grammar* current = scoped_parser_current_grammar(ctx);
  
  if (ctx->use_builtins || !current) {
    // Use builtin parser for this expression
    return builtin_parse_expr(tokens, token_count, cursor, ctx->interns, out_node);
  } else {
    // Use custom grammar parser
    // For now, fall back to builtin (full grammar integration is complex)
    // TODO: Integrate custom grammar parsing with cursor management
    return builtin_parse_expr(tokens, token_count, cursor, ctx->interns, out_node);
  }
}

bool scoped_parse_ast(ScopedParserContext* ctx,
                     const struct token* tokens,
                     size_t token_count,
                     AstNode** out_root) {
  if (!ctx || !tokens || !out_root) return false;
  
  // Start with builtin-only grammar (file-level default)
  if (!scoped_parser_push_grammar(ctx, NULL)) {
    return false;
  }
  
  size_t cursor = 0;
  AstNode** children = NULL;
  size_t child_count = 0;
  
  if (!scoped_parse_block_contents(ctx, tokens, token_count, &cursor, 0, &children, &child_count)) {
    scoped_parser_pop_grammar(ctx);
    return false;
  }
  
  // Pop file-level grammar
  scoped_parser_pop_grammar(ctx);
  
  // Create root node
  if (child_count == 1) {
    *out_root = children[0];
    free(children);
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
  }
  
  return true;
}
