#include "parser/scoped_parser.h"
#include "parser/builtin_parser.h"
#include "lexer/lexer.h"
#include "parser/operators.h"
#include "typing/type_context.h"
#include "typing/inference.h"
#include "util/error.h"
#include "util/fs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Token kind constants from lexer
extern const char* const LEXER_KIND_IDENT;
extern const char* const LEXER_KIND_NUMBER;
extern const char* const LEXER_KIND_SYMBOL;
extern const char* const LEXER_KIND_EOF;

#define MORPHL_SPAN_AT_CURSOR(cursor) \
  morphl_span_from_loc(tokens[cursor].filename, tokens[cursor].row, tokens[cursor].col)

bool scoped_parser_init(ScopedParserContext* ctx, InternTable* interns, Arena* arena, const char* filename) {
  if (!ctx || !interns || !arena) return false;
  
  ctx->grammar_stack = NULL;
  ctx->grammar_stack_size = 0;
  ctx->grammar_stack_cap = 0;
  ctx->interns = interns;
  ctx->arena = arena;
  ctx->use_builtins = true; // Start with builtin-only
  ctx->filename = filename;
  
  // Initialize TypeContext for type checking
  ctx->type_context = type_context_new(arena, interns);
  if (!ctx->type_context) return false;
  
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
  
  // Free TypeContext (it's allocated from arena, so just reset)
  type_context_free(ctx->type_context);
  ctx->type_context = NULL;
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

bool scoped_parser_replace_grammar(ScopedParserContext* ctx, 
                                    const char* grammar_path) {
  if (!ctx || !grammar_path) return false;
  
  // Load new grammar
  Grammar* new_grammar = malloc(sizeof(Grammar));
  if (!new_grammar) return false;

  // if a relative path is given, it should be relative to the source file
  // unless ctx->filename is NULL, which means grammar_path is relative to cwd
  // thus no change is needed
  memset(new_grammar, 0, sizeof(Grammar));
  Str resolved_path;
  if (fs_is_relative_path(grammar_path) && ctx->filename) {
    resolved_path = fs_get_absolute_path_from_source(grammar_path, ctx->filename);
  } else {
    resolved_path = str_from(grammar_path, strlen(grammar_path));
  }

  
  if (!grammar_load_file(new_grammar, resolved_path.ptr, ctx->interns, ctx->arena)) {
    free(new_grammar);
    MorphlError err = MORPHL_WARN(MORPHL_E_PARSE,
        "failed to load grammar from '%s', keeping current grammar", resolved_path.ptr);
    morphl_error_emit(NULL, &err);
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
  MorphlError err = MORPHL_NOTE(MORPHL_E_PARSE, 
                                "loaded grammar from '%s", resolved_path.ptr);
  morphl_error_emit(NULL, &err);
  
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
  // Pass ctx as global_state and type_context as block_state
  info->func(info, ctx, ctx->type_context, node->children, node->child_count);
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
        for (size_t i = 0; i < child_count; ++i) ast_free(children[i]);
        free(children);
        return false;
      }

      bool is_spread = false;
      if (grammar_root && grammar_root->kind == AST_BUILTIN && grammar_root->op) {
        Str op_name = interns_lookup(ctx->interns, grammar_root->op);
        if ((op_name.len == 7 && strncmp(op_name.ptr, "$spread", 7) == 0) ||
            (op_name.len == 8 && strncmp(op_name.ptr, "$$spread", 8) == 0)) {
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
  if (depth > 128) {
    MorphlError err = MORPHL_ERR_FROM(MORPHL_E_PARSE, 
      "parsing depth exceeded (recursion limit: 128)", 
      MORPHL_SPAN_AT_CURSOR(*cursor));
    morphl_error_emit(NULL, &err);
    return false;
  }
  
  // Always use builtin parser for now
  // Grammar-based parsing is a future feature (Maybe)
  return builtin_parse_expr(tokens, token_count, cursor, ctx->interns, out_node);
}

/**
 * @brief Run a typing pass on the AST root.
 *
 * morphl_infer_type_of_ast already traverses child nodes as needed, so we only
 * need to invoke it once at the root to populate the type context.
 *
 * @param ctx TypeContext for storing inferred types
 * @param node AST node to process
 */
static void typing_pass_ast(TypeContext* ctx, AstNode* node) {
  if (!ctx || !node) return;
  
  // Infer type for this node (this may trigger preprocessor actions)
  morphl_infer_type_of_ast(ctx, node);

}

bool scoped_parse_ast(ScopedParserContext* ctx,
                     const struct token* tokens,
                     size_t token_count,
                     AstNode** out_root) {
  if (!ctx || !tokens || !out_root) return false;
  
  // Start with builtin-only grammar (file-level default)
  // Grammars can be loaded via $syntax directives in the source
  if (!scoped_parser_push_grammar(ctx, NULL)) {
    return false;
  }
  
  size_t cursor = 0;
  AstNode** children = NULL;
  size_t child_count = 0;
  
  if (!scoped_parse_block_contents(ctx, tokens, token_count, &cursor, 0, &children, &child_count)) {
    scoped_parser_pop_grammar(ctx);
    MorphlError err = MORPHL_ERR_FROM(MORPHL_E_PARSE, 
                        "failed to parse program content", 
                        MORPHL_SPAN_AT_CURSOR(cursor));
    morphl_error_emit(NULL, &err);
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
      MorphlError err = MORPHL_ERR(MORPHL_E_PARSE, "failed to allocate root AST node");
      morphl_error_emit(NULL, &err);
      return false;
    }
    root->children = children;
    root->child_count = child_count;
    *out_root = root;
  }
  
  // Perform typing pass on the entire AST
  typing_pass_ast(ctx->type_context, *out_root);
  (void)type_context_check_unresolved_forwards(ctx->type_context);
  
  return true;
}
