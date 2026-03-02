#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    fprintf(stderr, "usage: %s [--backend c|vm] [grammar-file] <source-file>\n", argv[0]);
    fprintf(stderr, "  If grammar-file is omitted, uses builtin operators only.\n");
    fprintf(stderr, "  Use $syntax \"file\" directive within source to load custom grammars.\n");
    return 1;
  }

  enum MorphlBackendType backend_type = MORPHL_BACKEND_TYPE_C;
  int arg_index = 1;
  if (argc > arg_index && strcmp(argv[arg_index], "--backend") == 0) {
    if (argc <= arg_index + 1) {
      fprintf(stderr, "missing backend value after --backend\n");
      return 1;
    }

    const char* backend_name = argv[arg_index + 1];
    if (strcmp(backend_name, "c") == 0) {
      backend_type = MORPHL_BACKEND_TYPE_C;
    } else if (strcmp(backend_name, "vm") == 0) {
      backend_type = MORPHL_BACKEND_TYPE_VM;
    } else {
      fprintf(stderr, "unknown backend '%s' (expected 'c' or 'vm')\n", backend_name);
      return 1;
    }
    arg_index += 2;
  }

  int remaining = argc - arg_index;
  if (remaining < 1 || remaining > 2) {
    fprintf(stderr, "usage: %s [--backend c|vm] [grammar-file] <source-file>\n", argv[0]);
    return 1;
  }

  const char* grammar_path = NULL;
  const char* source_path = NULL;
  if (remaining == 1) {
    source_path = argv[arg_index];
  } else {
    grammar_path = argv[arg_index];
    source_path = argv[arg_index + 1];
  }

  InternTable* interns = interns_new();
  if (!interns) {
    fprintf(stderr, "failed to initialize intern table\n");
    return 1;
  }

  if (!operator_registry_init(interns)) {
    fprintf(stderr, "failed to initialize operator registry\n");
    interns_free(interns);
    return 1;
  }

  Arena arena;
  arena_init(&arena, 65536);

  ScopedParserContext parser_ctx;
  if (!scoped_parser_init(&parser_ctx, interns, &arena, source_path)) {
    fprintf(stderr, "failed to initialize parser context\n");
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

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

  printf("parsing with scoped grammar support...\n");
  AstNode* root = NULL;
  bool accepted = scoped_parse_ast(&parser_ctx, tokens, token_count, &root);

  if (accepted) {
    printf("parse succeeded\n");
    printf("AST:\n");
    ast_print(root, interns);
    printf("Type info:\n");
    type_context_print_debug(parser_ctx.type_context);

    MorphlBackendContext backend_ctx;
    backend_ctx.tree = root;
    backend_ctx.out_file = (backend_type == MORPHL_BACKEND_TYPE_VM) ? "out.mbc" : "out.c";
    backend_ctx.type_context = parser_ctx.type_context;

    if (!morphl_register_backend(backend_type)) {
      printf("backend registration failed\n");
      accepted = false;
    } else if (morphl_compile(&backend_ctx)) {
      printf("backend code generation succeeded, output written to %s\n", backend_ctx.out_file);
    } else {
      printf("backend code generation failed\n");
      accepted = false;
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
