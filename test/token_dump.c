#include <stdio.h>
#include <stdlib.h>

#include "lexer/lexer.h"
#include "util/file.h"
#include "util/util.h"

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <source-file>\n", argv[0]);
    return 1;
  }

  const char* source_path = argv[1];

  InternTable* interns = interns_new();
  if (!interns) {
    fprintf(stderr, "failed to initialize intern table\n");
    return 1;
  }

  char* source_buffer = NULL;
  size_t source_len = 0;
  if (!morphl_file_read_all(source_path, &source_buffer, &source_len)) {
    fprintf(stderr, "failed to read source from %s\n", source_path);
    interns_free(interns);
    return 1;
  }

  struct token* tokens = NULL;
  size_t token_count = 0;
  if (!lexer_tokenize(source_path, str_from(source_buffer, source_len), interns, &tokens, &token_count)) {
    fprintf(stderr, "tokenization failed\n");
    free(source_buffer);
    interns_free(interns);
    return 1;
  }

  printf("Tokens (%zu):\n", token_count);
  for (size_t i = 0; i < token_count; ++i) {
    Str kind_str = interns_lookup(interns, tokens[i].kind);
    printf("  [%zu] %.*s: '%.*s'\n", i, (int)kind_str.len, kind_str.ptr, (int)tokens[i].lexeme.len, tokens[i].lexeme.ptr);
  }

  free(tokens);
  free(source_buffer);
  interns_free(interns);
  return 0;
}
