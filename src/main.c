#include <stdio.h>
#include <stdlib.h>

#include "lexer/lexer.h"
#include "parser/parser.h"
#include "util/file.h"
#include "util/util.h"

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <grammar-file> <source-file>\n", argv[0]);
    return 1;
  }

  const char* grammar_path = argv[1];
  const char* source_path = argv[2];

  InternTable* interns = interns_new();
  if (!interns) {
    fprintf(stderr, "failed to initialize intern table\n");
    return 1;
  }

  Arena arena;
  arena_init(&arena, 4096);

  Grammar grammar;
  if (!grammar_load_file(&grammar, grammar_path, interns, &arena)) {
    fprintf(stderr, "failed to load grammar from %s\n", grammar_path);
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

  char* source_buffer = NULL;
  size_t source_len = 0;
  if (!file_read_all(source_path, &source_buffer, &source_len)) {
    fprintf(stderr, "failed to read source from %s\n", source_path);
    grammar_free(&grammar);
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

  struct token* tokens = NULL;
  size_t token_count = 0;
  if (!lexer_tokenize(source_path, str_from(source_buffer, source_len), interns, &tokens, &token_count)) {
    fprintf(stderr, "tokenization failed\n");
    free(source_buffer);
    grammar_free(&grammar);
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

  bool accepted = grammar_parse(&grammar, 0, tokens, token_count);
  printf("parse %s\n", accepted ? "succeeded" : "failed");

  free(tokens);
  free(source_buffer);
  grammar_free(&grammar);
  arena_free(&arena);
  interns_free(interns);
  return 0;
}
