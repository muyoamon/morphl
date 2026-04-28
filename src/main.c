#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "util/error.h"
#include "lexer/lexer.h"
#include "parser/parser.h"
#include "parser/builtin_parser.h"
#include "parser/scoped_parser.h"
#include "parser/operators.h"
#include "runtime/runtime.h"
#include "util/file.h"
#include "util/fs.h"
#include "util/util.h"
#include <backend/backend.h>

static void print_usage(const char* program_name) {
  fprintf(stderr, "usage: %s [--backend c|vm] [-c] [-o <filename>] [grammar-file] <source-file>\n", program_name);
  fprintf(stderr, "  If grammar-file is omitted, uses builtin operators only.\n");
  fprintf(stderr, "  VM backend compiles to .mplo with -c, otherwise compiles, links, and runs .mplx output.\n");
  fprintf(stderr, "  Use $syntax \"file\" directive within source to load custom grammars.\n");
}

typedef struct {
  char** items;
  size_t count;
  size_t cap;
} StringList;

typedef struct {
  InternTable* interns;
  Arena arena;
  ScopedParserContext parser_ctx;
  char* source_buffer;
  struct token* tokens;
  AstNode* root;
  bool arena_inited;
  bool parser_inited;
} FrontendUnit;

static void string_list_free(StringList* list) {
  if (!list) return;
  for (size_t i = 0; i < list->count; ++i) free(list->items[i]);
  free(list->items);
  list->items = NULL;
  list->count = 0;
  list->cap = 0;
}

static bool string_list_contains(const StringList* list, const char* value) {
  if (!list || !value) return false;
  for (size_t i = 0; i < list->count; ++i) {
    if (strcmp(list->items[i], value) == 0) return true;
  }
  return false;
}

static bool string_list_push_owned(StringList* list, char* value) {
  if (!list || !value) return false;
  if (list->count >= list->cap) {
    size_t new_cap = list->cap ? list->cap * 2 : 8;
    char** grown = (char**)realloc(list->items, new_cap * sizeof(char*));
    if (!grown) return false;
    list->items = grown;
    list->cap = new_cap;
  }
  list->items[list->count++] = value;
  return true;
}

static bool string_list_push_copy(StringList* list, const char* value) {
  if (!value) return false;
  size_t len = strlen(value);
  char* copy = (char*)malloc(len + 1);
  if (!copy) return false;
  memcpy(copy, value, len + 1);
  if (!string_list_push_owned(list, copy)) {
    free(copy);
    return false;
  }
  return true;
}

static char* make_temp_vm_object_path(void) {
  static size_t counter = 0;
  char path[256];
  for (;;) {
    snprintf(path, sizeof(path), "/tmp/morphl_vm_cli_%ld_%zu.mplo",
             (long)getpid(), counter++);
    if (!fs_path_exists(path)) {
      size_t len = strlen(path);
      char* out = (char*)malloc(len + 1);
      if (!out) return NULL;
      memcpy(out, path, len + 1);
      return out;
    }
  }
}

static void frontend_unit_free(FrontendUnit* unit) {
  if (!unit) return;
  if (unit->root) ast_free(unit->root);
  free(unit->tokens);
  free(unit->source_buffer);
  if (unit->parser_inited) scoped_parser_free(&unit->parser_ctx);
  if (unit->arena_inited) arena_free(&unit->arena);
  if (unit->interns) interns_free(unit->interns);
  memset(unit, 0, sizeof(*unit));
}

static bool frontend_parse_file(const char* grammar_path,
                                const char* source_path,
                                FrontendUnit* out_unit) {
  if (!source_path || !out_unit) return false;
  memset(out_unit, 0, sizeof(*out_unit));

  out_unit->interns = interns_new();
  if (!out_unit->interns) {
    MorphlError e = MORPHL_ERR(MORPHL_E_INTERNAL,
                               "failed to initialize intern table");
    morphl_error_emit(NULL, &e);
    return false;
  }

  if (!operator_registry_init(out_unit->interns)) {
    MorphlError e = MORPHL_ERR(MORPHL_E_INTERNAL,
                               "failed to initialize operator registry");
    morphl_error_emit(NULL, &e);
    frontend_unit_free(out_unit);
    return false;
  }

  arena_init(&out_unit->arena, 65536);
  out_unit->arena_inited = true;

  if (!scoped_parser_init(&out_unit->parser_ctx, out_unit->interns,
                          &out_unit->arena, source_path)) {
    MorphlError e = MORPHL_ERR(MORPHL_E_INTERNAL,
                               "failed to initialize parser context");
    morphl_error_emit(NULL, &e);
    frontend_unit_free(out_unit);
    return false;
  }
  out_unit->parser_inited = true;

  if (grammar_path) {
    if (!scoped_parser_replace_grammar(&out_unit->parser_ctx, grammar_path)) {
      MorphlError e = MORPHL_ERR(
          MORPHL_E_IO, "failed to load initial grammar from %s", grammar_path);
      morphl_error_emit(NULL, &e);
      frontend_unit_free(out_unit);
      return false;
    }
  }

  size_t source_len = 0;
  if (!morphl_file_read_all(source_path, &out_unit->source_buffer, &source_len)) {
    MorphlError e =
        MORPHL_ERR(MORPHL_E_IO, "failed to read source from %s", source_path);
    morphl_error_emit(NULL, &e);
    frontend_unit_free(out_unit);
    return false;
  }

  size_t token_count = 0;
  if (!lexer_tokenize(source_path, str_from(out_unit->source_buffer, source_len),
                      out_unit->interns, &out_unit->tokens, &token_count)) {
    MorphlError e = MORPHL_ERR(MORPHL_E_LEX, "tokenization failed");
    morphl_error_emit(NULL, &e);
    frontend_unit_free(out_unit);
    return false;
  }

  if (!scoped_parse_ast(&out_unit->parser_ctx, out_unit->tokens, token_count,
                        &out_unit->root)) {
    frontend_unit_free(out_unit);
    return false;
  }

  return true;
}

static bool collect_import_paths(const ScopedParserContext* parser_ctx,
                                 StringList* out_paths) {
  if (!parser_ctx || !out_paths) return false;
  for (size_t i = 0; i < parser_ctx->import_cache_count; ++i) {
    const char* path = parser_ctx->import_cache_entries[i].canonical_path.ptr;
    if (!path || string_list_contains(out_paths, path)) continue;
    if (!string_list_push_copy(out_paths, path)) return false;
  }
  return true;
}

static bool compile_vm_object_from_unit(FrontendUnit* unit,
                                        const char* out_path) {
  MorphlBackendContext backend_ctx = {0};
  if (!unit || !out_path) return false;
  backend_ctx.tree = unit->root;
  backend_ctx.out_file = out_path;
  backend_ctx.type_context = unit->parser_ctx.type_context;
  backend_ctx.vm_emit_object = true;
  return morphl_register_backend(MORPHL_BACKEND_TYPE_VM) &&
         morphl_compile(&backend_ctx);
}

static bool compile_vm_dependency_graph_recursive(const char* source_path,
                                                  StringList* visited_sources,
                                                  StringList* object_paths) {
  FrontendUnit unit = {0};
  StringList import_paths = {0};
  char* object_path = NULL;
  bool ok = false;

  if (!source_path || !visited_sources || !object_paths) return false;
  if (string_list_contains(visited_sources, source_path)) return true;
  if (!string_list_push_copy(visited_sources, source_path)) return false;

  if (!frontend_parse_file(NULL, source_path, &unit)) goto done;
  object_path = make_temp_vm_object_path();
  if (!object_path) goto done;
  if (!compile_vm_object_from_unit(&unit, object_path)) goto done;
  if (!string_list_push_owned(object_paths, object_path)) goto done;
  object_path = NULL;
  if (!collect_import_paths(&unit.parser_ctx, &import_paths)) goto done;
  frontend_unit_free(&unit);
  for (size_t i = 0; i < import_paths.count; ++i) {
    if (!compile_vm_dependency_graph_recursive(import_paths.items[i],
                                               visited_sources,
                                               object_paths)) {
      goto done;
    }
  }
  ok = true;

done:
  free(object_path);
  string_list_free(&import_paths);
  frontend_unit_free(&unit);
  return ok;
}

static void cleanup_temp_object_paths(StringList* object_paths) {
  if (!object_paths) return;
  for (size_t i = 0; i < object_paths->count; ++i) {
    if (object_paths->items[i]) remove(object_paths->items[i]);
  }
}

int main(int argc, char** argv) {
  if (argc < 2) {
    print_usage(argv[0]);
    return 1;
  }

  enum MorphlBackendType backend_type = MORPHL_BACKEND_TYPE_VM;
  bool compile_only = false;
  const char* output_path = NULL;
  int arg_index = 1;

  while (argc > arg_index && argv[arg_index][0] == '-') {
    if (strcmp(argv[arg_index], "--backend") == 0) {
      if (argc <= arg_index + 1) {
        MorphlError e = MORPHL_ERR(MORPHL_E_CLI, "missing backend value after --backend");
        morphl_error_emit(NULL, &e);
        return 1;
      }

      const char* backend_name = argv[arg_index + 1];
      if (strcmp(backend_name, "c") == 0) {
        backend_type = MORPHL_BACKEND_TYPE_C;
      } else if (strcmp(backend_name, "vm") == 0) {
        backend_type = MORPHL_BACKEND_TYPE_VM;
      } else {
        MorphlError e = MORPHL_ERR(MORPHL_E_CLI, "unknown backend '%s' (expected 'c' or 'vm')", backend_name);
        morphl_error_emit(NULL, &e);
        return 1;
      }
      arg_index += 2;
      continue;
    }

    if (strcmp(argv[arg_index], "-c") == 0) {
      compile_only = true;
      arg_index += 1;
      continue;
    }

    if (strcmp(argv[arg_index], "-o") == 0) {
      if (argc <= arg_index + 1) {
        MorphlError e = MORPHL_ERR(MORPHL_E_CLI, "missing output filename after -o");
        morphl_error_emit(NULL, &e);
        return 1;
      }

      output_path = argv[arg_index + 1];
      arg_index += 2;
      continue;
    }

    MorphlError e = MORPHL_ERR(MORPHL_E_CLI, "unknown option '%s'", argv[arg_index]);
    morphl_error_emit(NULL, &e);
    return 1;
  }

  int remaining = argc - arg_index;
  if (remaining < 1 || remaining > 2) {
    print_usage(argv[0]);
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

  FrontendUnit unit = {0};
  bool accepted = frontend_parse_file(grammar_path, source_path, &unit);

  if (accepted) {
    printf("parse succeeded\n");
    printf("AST:\n");
    ast_print(unit.root, unit.interns);
    printf("Type info:\n");
    type_context_print_debug(unit.parser_ctx.type_context);

    const char* final_output_path =
        output_path ? output_path
                    : ((backend_type == MORPHL_BACKEND_TYPE_VM)
                           ? (compile_only ? "out.mplo" : "out.mplx")
                           : "out.c");

    if (!morphl_register_backend(backend_type)) {
      printf("backend registration failed\n");
      accepted = false;
    } else if (backend_type == MORPHL_BACKEND_TYPE_VM) {
      if (compile_only) {
        MorphlBackendContext backend_ctx = {0};
        backend_ctx.tree = unit.root;
        backend_ctx.out_file = final_output_path;
        backend_ctx.type_context = unit.parser_ctx.type_context;
        backend_ctx.vm_emit_object = true;
        if (morphl_compile(&backend_ctx)) {
          printf("backend code generation succeeded, output written to %s\n",
                 final_output_path);
        } else {
          printf("backend code generation failed\n");
          accepted = false;
        }
      } else {
        StringList temp_object_paths = {0};
        StringList visited_sources = {0};
        StringList root_imports = {0};
        char* root_object_path = make_temp_vm_object_path();
        if (!root_object_path) {
          accepted = false;
        } else if (!compile_vm_object_from_unit(&unit, root_object_path) ||
                   !string_list_push_owned(&temp_object_paths,
                                           root_object_path) ||
                   !collect_import_paths(&unit.parser_ctx, &root_imports)) {
          free(root_object_path);
          accepted = false;
        } else {
          root_object_path = NULL;
          for (size_t i = 0; accepted && i < root_imports.count; ++i) {
            accepted = compile_vm_dependency_graph_recursive(
                root_imports.items[i], &visited_sources, &temp_object_paths);
          }
          if (accepted) {
            const char* const* link_inputs =
                (const char* const*)temp_object_paths.items;
            accepted = morphl_vm_link_files(final_output_path, link_inputs,
                                            temp_object_paths.count, stderr);
          }
        }
        string_list_free(&root_imports);
        string_list_free(&visited_sources);
        cleanup_temp_object_paths(&temp_object_paths);
        string_list_free(&temp_object_paths);
        if (accepted) {
          printf("backend code generation succeeded, output written to %s\n",
                 final_output_path);
        } else {
          printf("backend code generation failed\n");
        }
      }
      if (accepted && !compile_only) {
        printf("executing VM bytecode from %s...\n", final_output_path);
        extern char** environ;
        int exit_code =
            (int)morphl_vm_run_file(final_output_path, argc, argv, environ,
                                    stderr);
        frontend_unit_free(&unit);
        return exit_code;
      }
    } else {
      MorphlBackendContext backend_ctx = {0};
      backend_ctx.tree = unit.root;
      backend_ctx.out_file = final_output_path;
      backend_ctx.type_context = unit.parser_ctx.type_context;
      if (morphl_compile(&backend_ctx)) {
        printf("backend code generation succeeded, output written to %s\n",
               backend_ctx.out_file);
      } else {
        printf("backend code generation failed\n");
        accepted = false;
      }
    }
  } else {
    printf("parse failed\n");
  }

  frontend_unit_free(&unit);
  return accepted ? 0 : 1;
}
