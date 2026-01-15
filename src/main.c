#include <stdio.h>
#include <stdlib.h>

#include "lexer/lexer.h"
#include "parser/parser.h"
#include "parser/builtin_parser.h"
#include "parser/scoped_parser.h"
#include "parser/operators.h"
#include "util/file.h"
#include "util/util.h"
#include <backend/backend.h>

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s [grammar-file] <source-file>\n", argv[0]);
    fprintf(stderr, "  If grammar-file is omitted, uses builtin operators only.\n");
    fprintf(stderr, "  Use $syntax \"file\" directive within source to load custom grammars.\n");
    return 1;
  }

  const char* grammar_path = NULL;
  const char* source_path = NULL;
  
  // Determine if we have one or two arguments
  if (argc == 2) {
    // Single argument: source file, no initial grammar
    source_path = argv[1];
  } else {
    // Two arguments: initial grammar file and source file
    grammar_path = argv[1];
    source_path = argv[2];
  }

  InternTable* interns = interns_new();
  if (!interns) {
    fprintf(stderr, "failed to initialize intern table\n");
    return 1;
  }

  // Initialize operator registry (interns required)
  if (!operator_registry_init(interns)) {
    fprintf(stderr, "failed to initialize operator registry\n");
    interns_free(interns);
    return 1;
  }

  Arena arena;
  arena_init(&arena, 65536);

  // Initialize scoped parser context
  ScopedParserContext parser_ctx;
  if (!scoped_parser_init(&parser_ctx, interns, &arena, source_path)) {
    fprintf(stderr, "failed to initialize parser context\n");
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

  // Load initial grammar if provided
  if (grammar_path) {
    if (!scoped_parser_replace_grammar(&parser_ctx, grammar_path)) {
      fprintf(stderr, "failed to load initial grammar from %s\n", grammar_path);
      scoped_parser_free(&parser_ctx);
      arena_free(&arena);
      interns_free(interns);
      return 1;
    }
  }

  char* source_buffer = NULL;
  size_t source_len = 0;
  if (!morphl_file_read_all(source_path, &source_buffer, &source_len)) {
    fprintf(stderr, "failed to read source from %s\n", source_path);
    scoped_parser_free(&parser_ctx);
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

  struct token* tokens = NULL;
  size_t token_count = 0;
  if (!lexer_tokenize(source_path, str_from(source_buffer, source_len), interns, &tokens, &token_count)) {
    fprintf(stderr, "tokenization failed\n");
    free(source_buffer);
    scoped_parser_free(&parser_ctx);
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

  // Parse using scoped parser (supports $syntax directives)
  printf("parsing with scoped grammar support...\n");
  AstNode* root = NULL;
  bool accepted = scoped_parse_ast(&parser_ctx, tokens, token_count, &root);
  
  if (accepted) {
    printf("parse succeeded\n");
    printf("AST:\n");
    ast_print(root, interns);
     // try backend code generation (C)
    {
      MorphlBackendContext backend_ctx;
      backend_ctx.tree = root;
      backend_ctx.out_file = "out.c";

      if (morphl_compile(&backend_ctx)) {
        printf("C code generation succeeded, output written to out.c\n");
      } else {
        printf("C code generation failed\n");
        accepted = false;
      }
    }
    ast_free(root);
  } else {
    printf("parse failed\n");
  }

 



  free(tokens);
  free(source_buffer);
  scoped_parser_free(&parser_ctx);
  arena_free(&arena);
  interns_free(interns);
  return accepted ? 0 : 1;
}



