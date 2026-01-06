#include <stdio.h>
#include <stdlib.h>

#include "lexer/lexer.h"
#include "parser/parser.h"
#include "parser/builtin_parser.h"
#include "util/file.h"
#include "util/util.h"

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s [grammar-file] <source-file>\n", argv[0]);
    fprintf(stderr, "  If grammar-file is omitted, uses builtin operators only.\n");
    return 1;
  }

  const char* grammar_path = NULL;
  const char* source_path = NULL;
  
  // Determine if we have one or two arguments
  if (argc == 2) {
    // Single argument: source file, no grammar
    source_path = argv[1];
  } else {
    // Two arguments: grammar file and source file
    grammar_path = argv[1];
    source_path = argv[2];
  }

  InternTable* interns = interns_new();
  if (!interns) {
    fprintf(stderr, "failed to initialize intern table\n");
    return 1;
  }

  Arena arena;
  arena_init(&arena, 4096);

  // Load grammar if provided
  Grammar grammar;
  bool has_grammar = false;
  if (grammar_path) {
    if (!grammar_load_file(&grammar, grammar_path, interns, &arena)) {
      fprintf(stderr, "failed to load grammar from %s\n", grammar_path);
      arena_free(&arena);
      interns_free(interns);
      return 1;
    }
    has_grammar = true;
  }

  char* source_buffer = NULL;
  size_t source_len = 0;
  if (!file_read_all(source_path, &source_buffer, &source_len)) {
    fprintf(stderr, "failed to read source from %s\n", source_path);
    if (has_grammar) grammar_free(&grammar);
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

  struct token* tokens = NULL;
  size_t token_count = 0;
  if (!lexer_tokenize(source_path, str_from(source_buffer, source_len), interns, &tokens, &token_count)) {
    fprintf(stderr, "tokenization failed\n");
    free(source_buffer);
    if (has_grammar) grammar_free(&grammar);
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

  // Parse using grammar or builtin fallback
  bool accepted = false;
  AstNode* root = NULL;
  
  if (has_grammar) {
    // Use custom grammar
    accepted = grammar_parse(&grammar, 0, tokens, token_count);
    printf("parse %s\n", accepted ? "succeeded" : "failed");
    if (accepted) {
      if (grammar_parse_ast(&grammar, 0, tokens, token_count, &root)) {
        printf("AST:\n");
        ast_print(root, interns);
      } else {
        printf("failed to build AST\n");
      }
    }
  } else {
    // Use builtin parser
    printf("parsing with builtin operators...\n");
    if (builtin_parse_ast(tokens, token_count, interns, &root)) {
      printf("parse succeeded\n");
      printf("AST:\n");
      ast_print(root, interns);
      accepted = true;
    } else {
      printf("parse failed\n");
    }
  }

  if (root) ast_free(root);
  free(tokens);
  free(source_buffer);
  if (has_grammar) grammar_free(&grammar);
  arena_free(&arena);
  interns_free(interns);
  return accepted ? 0 : 1;
}
