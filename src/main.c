#include <stdio.h>
#include <stdlib.h>

#include "lexer/lexer.h"
#include "util/file.h"
#include "util/util.h"

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <syntax-file> <source-file>\n", argv[0]);
    return 1;
  }

  const char* syntax_path = argv[1];
  const char* source_path = argv[2];

  InternTable* interns = interns_new();
  if (!interns) {
    fprintf(stderr, "failed to initialize intern table\n");
    return 1;
  }

  Arena arena;
  arena_init(&arena, 4096);

  Syntax syntax;
  if (!syntax_load_file(&syntax, syntax_path, interns, &arena)) {
    fprintf(stderr, "failed to load syntax from %s\n", syntax_path);
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

  char* source_buffer = NULL;
  size_t source_len = 0;
  if (!file_read_all(source_path, &source_buffer, &source_len)) {
    fprintf(stderr, "failed to read source from %s\n", source_path);
    syntax_free(&syntax);
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

  struct token* tokens = NULL;
  size_t token_count = 0;
  if (!lexer_tokenize(&syntax, source_path, str_from(source_buffer, source_len), interns, &tokens, &token_count)) {
    fprintf(stderr, "tokenization failed\n");
    free(source_buffer);
    syntax_free(&syntax);
    arena_free(&arena);
    interns_free(interns);
    return 1;
  }

  for (size_t i = 0; i < token_count; ++i) {
    Str kind = interns_lookup(interns, tokens[i].kind);
    printf("%s (%zu:%zu): %.*s\n",
           kind.ptr ? kind.ptr : "<invalid>",
           tokens[i].row,
           tokens[i].col,
           (int)tokens[i].lexeme.len,
           tokens[i].lexeme.ptr ? tokens[i].lexeme.ptr : "");
  }

  free(tokens);
  free(source_buffer);
  syntax_free(&syntax);
  arena_free(&arena);
  interns_free(interns);
  return 0;
}
