#include <assert.h>
#include <cstdio>
#include <cstring>
#include <vector>
#include <fstream>
#include <string>
#include <cstdlib>
#include <ctime>
#include <sstream>

extern "C" {
#include "typing/typing.h"
#include "typing/type_context.h"
#include "typing/inference.h"
#include "util/util.h"
#include "util/error.h"
#include "util/file.h"
#include "parser/operators.h"
#include "parser/scoped_parser.h"
#include "lexer/lexer.h"
}

// ============================================================================
// Helper: Create arena and intern table for tests
// ============================================================================
static Arena create_test_arena() {
  Arena a;
  arena_init(&a, 65536);
  return a;
}

static InternTable* create_test_interns() {
  return interns_new();
}

static std::string write_temp_file(const char* contents) {
  const char* tmpdir = std::getenv("TMP");
  if (!tmpdir) tmpdir = std::getenv("TEMP");
#ifdef _WIN32
  const char* fallback = "C:/Windows/Temp";
#else
  const char* fallback = "/tmp";
#endif
  if (!tmpdir) tmpdir = fallback;

  std::srand((unsigned)std::time(nullptr) ^ (unsigned)(uintptr_t)&tmpdir);

  for (int attempt = 0; attempt < 16; ++attempt) {
    std::ostringstream name;
    name << tmpdir;
    name << "/";
    name << "morphl_test_" << std::rand() << ".tmp";
    std::string path = name.str();

    std::ofstream out(path, std::ios::trunc);
    if (!out.is_open()) continue;
    out << contents;
    out.close();
    return path;
  }

  assert(false && "failed to open temp file");
  return std::string();
}

static AstNode* parse_source(InternTable* interns,
                             Arena* arena,
                             const char* source,
                             ScopedParserContext* out_ctx) {
  std::string path = write_temp_file(source);
  assert(scoped_parser_init(out_ctx, interns, arena, path.c_str()));
  char* source_buffer = NULL;
  size_t source_len = 0;
  assert(morphl_file_read_all(path.c_str(), &source_buffer, &source_len));
  struct token* tokens = NULL;
  size_t token_count = 0;
  assert(lexer_tokenize(path.c_str(),
                        str_from(source_buffer, source_len),
                        interns,
                        &tokens,
                        &token_count));
  AstNode* root = NULL;
  assert(scoped_parse_ast(out_ctx, tokens, token_count, &root));
  free(tokens);
  free(source_buffer);
  std::remove(path.c_str());
  return root;
}

// Helper: create identifier AST node with interned symbol
static AstNode* make_ident(InternTable* interns, const char* name) {
  size_t len = strlen(name);
  AstNode* n = ast_new(AST_IDENT);
  assert(n != NULL);
  n->value = str_from(name, len);
  n->op = interns_intern(interns, n->value);
  return n;
}

// Helper: create literal AST node
static AstNode* make_literal(const char* text) {
  size_t len = strlen(text);
  return ast_make_leaf(AST_LITERAL, str_from(text, len), "<test>", 1, 1);
}

static AstNode* make_literal_with_kind(InternTable* interns, const char* text, const char* kind_name) {
  size_t len = strlen(text);
  AstNode* node = ast_make_leaf(AST_LITERAL, str_from(text, len), "<test>", 1, 1);
  if (!node) return NULL;
  node->op = interns_intern(interns, str_from(kind_name, strlen(kind_name)));
  return node;
}

// Helper: create builtin AST node with children
static AstNode* make_builtin(InternTable* interns,
                            const char* name,
                            std::initializer_list<AstNode*> children) {
  size_t len = strlen(name);
  AstNode* n = ast_new(AST_BUILTIN);
  assert(n != NULL);
  n->op = interns_intern(interns, str_from(name, len));
  for (AstNode* child : children) {
    ast_append_child(n, child);
  }
  return n;
}

// ============================================================================
// Test: Type Constructors
// ============================================================================
static void test_type_constructors() {
  Arena arena = create_test_arena();
  
  // Test void type
  MorphlType* t_void = morphl_type_void(&arena);
  assert(t_void != NULL);
  assert(t_void->kind == MORPHL_TYPE_VOID);
  assert(t_void->size == 0);
  
  // Test int type
  MorphlType* t_int = morphl_type_int(&arena);
  assert(t_int != NULL);
  assert(t_int->kind == MORPHL_TYPE_INT);
  assert(t_int->size == 8);
  
  // Test float type
  MorphlType* t_float = morphl_type_float(&arena);
  assert(t_float != NULL);
  assert(t_float->kind == MORPHL_TYPE_FLOAT);
  assert(t_float->size == 8);
  
  // Test bool type
  MorphlType* t_bool = morphl_type_bool(&arena);
  assert(t_bool != NULL);
  assert(t_bool->kind == MORPHL_TYPE_BOOL);
  assert(t_bool->size == 1);
  
  arena_free(&arena);
  printf("✓ test_type_constructors passed\n");
}

// ============================================================================
// Test: Type Equality
// ============================================================================
static void test_type_equality() {
  Arena arena = create_test_arena();
  
  MorphlType* t_int1 = morphl_type_int(&arena);
  MorphlType* t_int2 = morphl_type_int(&arena);
  MorphlType* t_float = morphl_type_float(&arena);
  
  // Same types should be equal
  assert(morphl_type_equals(t_int1, t_int2) == true);
  
  // Different types should not be equal
  assert(morphl_type_equals(t_int1, t_float) == false);
  
  // NULL comparisons
  assert(morphl_type_equals(NULL, NULL) == true);
  assert(morphl_type_equals(t_int1, NULL) == false);
  
  arena_free(&arena);
  printf("✓ test_type_equality passed\n");
}

// ============================================================================
// Test: TypeContext Scope Management
// ============================================================================
static void test_type_context_scopes() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);
  
  // Should start with global scope
  // (scope_count is 1)
  
  // Push a new scope
  bool ok = type_context_push_scope(ctx);
  assert(ok == true);
  
  // Pop the scope
  ok = type_context_pop_scope(ctx);
  assert(ok == true);
  
  // Cannot pop global scope
  ok = type_context_pop_scope(ctx);
  assert(ok == false);
  
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("✓ test_type_context_scopes passed\n");
}

// ============================================================================
// Test: TypeContext Variable Definition and Lookup
// ============================================================================
static void test_type_context_vars() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);
  
  // Create variable types
  MorphlType* t_int = morphl_type_int(&arena);
  MorphlType* t_bool = morphl_type_bool(&arena);
  
  // Intern variable names
  Sym x_sym = interns_intern(interns, str_from("x", 1));
  Sym y_sym = interns_intern(interns, str_from("y", 1));
  
  // Define variables
  bool ok = type_context_define_var(ctx, x_sym, t_int);
  assert(ok == true);
  
  ok = type_context_define_var(ctx, y_sym, t_bool);
  assert(ok == true);
  
  // Look up variables
  MorphlType* found_x = type_context_lookup_var(ctx, x_sym);
  assert(found_x != NULL);
  assert(found_x->kind == MORPHL_TYPE_INT);
  
  MorphlType* found_y = type_context_lookup_var(ctx, y_sym);
  assert(found_y != NULL);
  assert(found_y->kind == MORPHL_TYPE_BOOL);
  
  // Look up non-existent variable
  Sym z_sym = interns_intern(interns, str_from("z", 1));
  MorphlType* found_z = type_context_lookup_var(ctx, z_sym);
  assert(found_z == NULL);
  
  // Check duplicates
  bool is_dup = type_context_check_duplicate_var(ctx, x_sym);
  assert(is_dup == true);
  
  is_dup = type_context_check_duplicate_var(ctx, z_sym);
  assert(is_dup == false);
  
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("✓ test_type_context_vars passed\n");
}

// ============================================================================
// Test: TypeContext Function Registry
// ============================================================================
static void test_type_context_functions() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);
  
  // Create a function type: (int) -> int
  MorphlType* t_int = morphl_type_int(&arena);
  MorphlType* func_type = morphl_type_func(&arena, t_int, t_int);
  assert(func_type != NULL);
  assert(func_type->kind == MORPHL_TYPE_FUNC);
  assert(func_type->data.func.param_count == 1);
  
  // Register function
  Sym add_sym = interns_intern(interns, str_from("add", 3));
  bool ok = type_context_define_func(ctx, add_sym, func_type);
  assert(ok == true);
  
  // Look up function
  MorphlType* found_func = type_context_lookup_func(ctx, add_sym);
  assert(found_func != NULL);
  assert(found_func->kind == MORPHL_TYPE_FUNC);
  assert(found_func->data.func.param_count == 1);
  
  // Look up non-existent function
  Sym sub_sym = interns_intern(interns, str_from("sub", 3));
  MorphlType* found_sub = type_context_lookup_func(ctx, sub_sym);
  assert(found_sub == NULL);
  
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("✓ test_type_context_functions passed\n");
}

// ============================================================================
// Test: Type Cloning
// ============================================================================
static void test_type_clone() {
  Arena arena = create_test_arena();
  
  // Clone primitive type
  MorphlType* t_int = morphl_type_int(&arena);
  MorphlType* t_int_clone = morphl_type_clone(&arena, t_int);
  assert(t_int_clone != NULL);
  assert(t_int_clone->kind == MORPHL_TYPE_INT);
  assert(morphl_type_equals(t_int, t_int_clone) == true);
  
  // Clone function type
  MorphlType* func_type = morphl_type_func(&arena, t_int, t_int);
  MorphlType* func_clone = morphl_type_clone(&arena, func_type);
  assert(func_clone != NULL);
  assert(func_clone->kind == MORPHL_TYPE_FUNC);
  assert(func_clone->data.func.param_count == 1);
  
  arena_free(&arena);
  printf("✓ test_type_clone passed\n");
}

// ============================================================================
// Test: Type Inference for Arithmetic Operators
// ============================================================================
static void test_infer_arithmetic_ops() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  
  // Initialize operator registry
  operator_registry_init(interns);
  
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);
  
  MorphlType* t_int = morphl_type_int(&arena);
  MorphlType* t_float = morphl_type_float(&arena);
  
  // Test $add (int, int) -> int
  Sym add_sym = interns_intern(interns, str_from("$add", 4));
  MorphlType* arg_types[] = {t_int, t_int};
  MorphlType* result = morphl_infer_type_for_op(ctx, NULL, add_sym, arg_types, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_INT);
  
  // Test $fadd (float, float) -> float
  Sym fadd_sym = interns_intern(interns, str_from("$fadd", 5));
  MorphlType* arg_types_f[] = {t_float, t_float};
  result = morphl_infer_type_for_op(ctx, NULL, fadd_sym, arg_types_f, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_FLOAT);
  
  // Test type error: $add (int, float) should fail (output will be printed)
  MorphlType* mixed_args[] = {t_int, t_float};
  result = morphl_infer_type_for_op(ctx, NULL, add_sym, mixed_args, 2);
  assert(result == NULL);
  
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("✓ test_infer_arithmetic_ops passed\n");
}

// ============================================================================
// Test: Type Inference for Comparison Operators
// ============================================================================
static void test_infer_comparison_ops() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  
  // Initialize operator registry
  operator_registry_init(interns);
  
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);
  
  MorphlType* t_int = morphl_type_int(&arena);
  MorphlType* t_int2 = morphl_type_int(&arena);
  
  // Test $eq (int, int) -> bool
  Sym eq_sym = interns_intern(interns, str_from("$eq", 3));
  MorphlType* arg_types[] = {t_int, t_int2};
  MorphlType* result = morphl_infer_type_for_op(ctx, NULL, eq_sym, arg_types, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_BOOL);
  
  // Test $lt (int, int) -> bool
  Sym lt_sym = interns_intern(interns, str_from("$lt", 3));
  result = morphl_infer_type_for_op(ctx, NULL, lt_sym, arg_types, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_BOOL);
  
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("✓ test_infer_comparison_ops passed\n");
}

// ============================================================================
// Test: Type Inference for Logic Operators
// ============================================================================
static void test_infer_logic_ops() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  
  // Initialize operator registry
  operator_registry_init(interns);
  
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);
  
  MorphlType* t_bool = morphl_type_bool(&arena);
  MorphlType* t_bool2 = morphl_type_bool(&arena);
  MorphlType* t_int = morphl_type_int(&arena);
  
  // Test $and (bool, bool) -> bool
  Sym and_sym = interns_intern(interns, str_from("$and", 4));
  MorphlType* arg_types[] = {t_bool, t_bool2};
  MorphlType* result = morphl_infer_type_for_op(ctx, NULL, and_sym, arg_types, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_BOOL);
  
  // Test $not (bool) -> bool
  Sym not_sym = interns_intern(interns, str_from("$not", 4));
  MorphlType* arg_types_not[] = {t_bool};
  result = morphl_infer_type_for_op(ctx, NULL, not_sym, arg_types_not, 1);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_BOOL);
  
  // Test $and (int, int) -> bool: ints are truthy, accepted for logical ops
  MorphlType* int_args[] = {t_int, t_int};
  result = morphl_infer_type_for_op(ctx, NULL, and_sym, int_args, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_BOOL);
  
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("✓ test_infer_logic_ops passed\n");
}

// ============================================================================
// Test: Type Inference for Bitwise Operators
// ============================================================================
static void test_infer_bitwise_ops() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  
  // Initialize operator registry
  operator_registry_init(interns);
  
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);
  
  MorphlType* t_int = morphl_type_int(&arena);
  MorphlType* t_int2 = morphl_type_int(&arena);
  
  // Test $band (int, int) -> int
  Sym band_sym = interns_intern(interns, str_from("$band", 5));
  MorphlType* arg_types[] = {t_int, t_int2};
  MorphlType* result = morphl_infer_type_for_op(ctx, NULL, band_sym, arg_types, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_INT);
  
  // Test $bnot (int) -> int
  Sym bnot_sym = interns_intern(interns, str_from("$bnot", 5));
  MorphlType* arg_types_bnot[] = {t_int};
  result = morphl_infer_type_for_op(ctx, NULL, bnot_sym, arg_types_bnot, 1);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_INT);
  
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("✓ test_infer_bitwise_ops passed\n");
}

// ============================================================================
// Test: References, meta conversions, and forward stubs
// ============================================================================
static void test_ref_meta_forward_ops() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  AstNode* mut_node = make_builtin(interns, "$mut", {make_literal("1")});
  MorphlType* mut_type = morphl_infer_type_of_ast(ctx, mut_node);
  assert(mut_type != NULL && mut_type->kind == MORPHL_TYPE_REF);
  assert(mut_type->data.ref.is_mutable == true);
  assert(mut_type->data.ref.is_inline == false);
  assert(mut_type->data.ref.target != NULL && mut_type->data.ref.target->kind == MORPHL_TYPE_INT);

  AstNode* const_node = make_builtin(interns, "$const", {make_literal("2")});
  MorphlType* const_type = morphl_infer_type_of_ast(ctx, const_node);
  assert(const_type != NULL && const_type->kind == MORPHL_TYPE_REF);
  assert(const_type->data.ref.is_mutable == false);
  assert(const_type->data.ref.is_inline == false);

  AstNode* inline_node = make_builtin(interns, "$inline", {make_literal("3")});
  MorphlType* inline_type = morphl_infer_type_of_ast(ctx, inline_node);
  assert(inline_type != NULL && inline_type->kind == MORPHL_TYPE_REF);
  assert(inline_type->data.ref.is_inline == true);

  AstNode* idtstr_node = make_builtin(interns, "$idtstr", {make_ident(interns, "name")});
  MorphlType* idtstr_type = morphl_infer_type_of_ast(ctx, idtstr_node);
  assert(idtstr_type != NULL && idtstr_type->kind == MORPHL_TYPE_STRING);

  AstNode* strtid_node = make_builtin(interns, "$strtid", {make_literal("\"name\"")});
  MorphlType* strtid_type = morphl_infer_type_of_ast(ctx, strtid_node);
  assert(strtid_type != NULL && strtid_type->kind == MORPHL_TYPE_IDENT);

  AstNode* stub_func = make_builtin(interns, "$func", {make_literal("0"), make_literal("1")});
  AstNode* forward_node = make_builtin(interns, "$forward", {stub_func});
  AstNode* forward_decl = ast_new(AST_DECL);
  assert(forward_decl != NULL);
  ast_append_child(forward_decl, make_ident(interns, "fwd"));
  ast_append_child(forward_decl, forward_node);
  MorphlType* forward_type = morphl_infer_type_of_ast(ctx, forward_decl);
  assert(forward_type != NULL && forward_type->kind == MORPHL_TYPE_FUNC);
  Sym fwd_sym = interns_intern(interns, str_from("fwd", 3));
  ForwardEntry* entry = type_context_lookup_forward(ctx, fwd_sym);
  assert(entry != NULL && entry->resolved == false);

  AstNode* body_func = make_builtin(interns, "$func", {make_literal("0"), make_literal("1")});
  AstNode* body_decl = ast_new(AST_DECL);
  assert(body_decl != NULL);
  ast_append_child(body_decl, make_ident(interns, "fwd"));
  ast_append_child(body_decl, body_func);
  MorphlType* body_type = morphl_infer_type_of_ast(ctx, body_decl);
  assert(body_type != NULL && body_type->kind == MORPHL_TYPE_FUNC);
  assert(entry->resolved == true);

  MorphlType* block_type = morphl_type_block(&arena, NULL, NULL, 0);
  assert(type_context_push_this(ctx, block_type));
  AstNode* this_node = make_builtin(interns, "$this", {});
  MorphlType* this_type = morphl_infer_type_of_ast(ctx, this_node);
  assert(this_type != NULL && this_type->kind == MORPHL_TYPE_BLOCK);
  type_context_pop_this(ctx);

  AstNode* block_node = ast_new(AST_BLOCK);
  assert(block_node != NULL);
  ast_append_child(block_node, make_literal("0"));
  MorphlType* top_block_type = morphl_infer_type_of_ast(ctx, block_node);
  assert(top_block_type != NULL && top_block_type->kind == MORPHL_TYPE_BLOCK);

  AstNode* file_node = make_builtin(interns, "$file", {});
  MorphlType* file_type = morphl_infer_type_of_ast(ctx, file_node);
  assert(file_type != NULL && file_type->kind == MORPHL_TYPE_BLOCK);

  AstNode* global_node = make_builtin(interns, "$global", {});
  MorphlType* global_type = morphl_infer_type_of_ast(ctx, global_node);
  assert(global_type != NULL && global_type->kind == MORPHL_TYPE_BLOCK);

  ast_free(mut_node);
  ast_free(const_node);
  ast_free(inline_node);
  ast_free(idtstr_node);
  ast_free(strtid_node);
  ast_free(forward_decl);
  ast_free(body_decl);
  ast_free(this_node);
  ast_free(block_node);
  ast_free(file_node);
  ast_free(global_node);

  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("✓ test_ref_meta_forward_ops passed\n");
}

// ============================================================================
// Test: Literal inference uses token kinds when available
// ============================================================================
static void test_literal_inference_kinds() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  AstNode* float_lit = make_literal_with_kind(interns, "3.14", LEXER_KIND_FLOAT);
  AstNode* int_lit = make_literal_with_kind(interns, "42", LEXER_KIND_NUMBER);
  AstNode* string_lit = make_literal_with_kind(interns, "\"ok\"", LEXER_KIND_STRING);

  MorphlType* float_type = morphl_infer_type_of_ast(ctx, float_lit);
  MorphlType* int_type = morphl_infer_type_of_ast(ctx, int_lit);
  MorphlType* string_type = morphl_infer_type_of_ast(ctx, string_lit);

  assert(float_type != NULL && float_type->kind == MORPHL_TYPE_FLOAT);
  assert(int_type != NULL && int_type->kind == MORPHL_TYPE_INT);
  assert(string_type != NULL && string_type->kind == MORPHL_TYPE_STRING);

  ast_free(float_lit);
  ast_free(int_lit);
  ast_free(string_lit);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("✓ test_literal_inference_kinds passed\n");
}

// ============================================================================
// Test: Preprocessor actions for $set
// ============================================================================
static void test_pp_set() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  MorphlType* t_int = morphl_type_int(&arena);
  Sym x_sym = interns_intern(interns, str_from("x", 1));
  type_context_define_var(ctx, x_sym, t_int);

  AstNode* target = make_ident(interns, "x");
  AstNode* value = make_literal("5");
  AstNode* args_ok[] = {target, value};
  const OperatorInfo* info = operator_info_lookup(interns_intern(interns, str_from("$set", 4)));
  assert(info != NULL && info->func != NULL);
  MorphlType* result = info->func(info, NULL, ctx, args_ok, 2);
  assert(result != NULL && result->kind == MORPHL_TYPE_INT);

  // Mismatched assignment should fail (float into int)
  AstNode* bad_value = make_literal("3.14");
  AstNode* args_bad[] = {target, bad_value};
  MorphlType* bad_result = info->func(info, NULL, ctx, args_bad, 2);
  assert(bad_result == NULL);

  ast_free(target);
  ast_free(value);
  ast_free(bad_value);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_pp_set passed\n");
}

// ============================================================================
// Test: Preprocessor action for $ret
// ============================================================================
static void test_pp_ret() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  MorphlType* t_int = morphl_type_int(&arena);
  type_context_set_return_type(ctx, t_int);

  AstNode* ret_expr = make_literal("7");
  AstNode* args_ok[] = {ret_expr};
  const OperatorInfo* info = operator_info_lookup(interns_intern(interns, str_from("$ret", 4)));
  assert(info != NULL && info->func != NULL);
  MorphlType* result = info->func(info, NULL, ctx, args_ok, 1);
  assert(result != NULL && result->kind == MORPHL_TYPE_INT);

  // Mismatched return (float vs expected int) should fail
  AstNode* ret_bad_expr = make_literal("1.5");
  AstNode* args_bad[] = {ret_bad_expr};
  MorphlType* bad = info->func(info, NULL, ctx, args_bad, 1);
  assert(bad == NULL);

  ast_free(ret_expr);
  ast_free(ret_bad_expr);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_pp_ret passed\n");
}

// ============================================================================
// Test: Preprocessor action for $member
// ============================================================================
static void test_pp_member() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  // Build a block type: { x: int, y: int }
  MorphlType* t_int = morphl_type_int(&arena);
  Sym field_names_arr[2];
  field_names_arr[0] = interns_intern(interns, str_from("x", 1));
  field_names_arr[1] = interns_intern(interns, str_from("y", 1));
  MorphlType* field_types_arr[2];
  field_types_arr[0] = t_int;
  field_types_arr[1] = t_int;
  MorphlType* block_type = morphl_type_block(&arena, field_names_arr, field_types_arr, 2);

  Sym p_sym = interns_intern(interns, str_from("p", 1));
  type_context_define_var(ctx, p_sym, block_type);

  AstNode* target = make_ident(interns, "p");
  AstNode* field = make_ident(interns, "x");
  AstNode* args_ok[] = {target, field};
  const OperatorInfo* info = operator_info_lookup(interns_intern(interns, str_from("$member", 7)));
  assert(info != NULL && info->func != NULL);
  MorphlType* result = info->func(info, NULL, ctx, args_ok, 2);
  assert(result != NULL && result->kind == MORPHL_TYPE_INT);

  // Unknown field should fail
  AstNode* bad_field = make_ident(interns, "z");
  AstNode* args_bad[] = {target, bad_field};
  MorphlType* bad = info->func(info, NULL, ctx, args_bad, 2);
  assert(bad == NULL);

  ast_free(target);
  ast_free(field);
  ast_free(bad_field);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_pp_member passed\n");
}

// ============================================================================
// Test: $import produces block fields for module declarations
// ============================================================================
static void test_import_block_fields() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));

  const char* module_src = "$decl foo 1; $decl bar 2;";
  std::string module_path = write_temp_file(module_src);

  ScopedParserContext parser_ctx;
  assert(scoped_parser_init(&parser_ctx, interns, &arena, NULL));

  std::string quoted_path = "\"" + module_path + "\"";
  AstNode* import_arg = make_literal(quoted_path.c_str());
  assert(import_arg != NULL);
  AstNode* args[] = {import_arg};
  Sym import_sym = interns_intern(interns, str_from("$import", 7));
  const OperatorInfo* import_info = operator_info_lookup(import_sym);
  assert(import_info != NULL && import_info->func != NULL);
  import_info->func(import_info, &parser_ctx, NULL, args, 1);
  assert(args[0] != NULL);
  assert(args[0]->kind == AST_LITERAL);
  assert(args[0]->import_module != NULL);
  assert(args[0]->import_module->kind == AST_FILE);
  assert(args[0]->import_path.ptr != NULL);

  AstNode* import_node = make_builtin(interns, "$import", {args[0]});
  assert(import_node != NULL);

  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);
  MorphlType* module_type = morphl_infer_type_of_ast(ctx, import_node);
  assert(module_type != NULL);
  assert(module_type->kind == MORPHL_TYPE_BLOCK);
  bool found_foo = false;
  bool found_bar = false;
  Sym foo_sym = interns_intern(interns, str_from("foo", 3));
  Sym bar_sym = interns_intern(interns, str_from("bar", 3));
  for (size_t i = 0; i < module_type->data.block.field_count; ++i) {
    if (module_type->data.block.field_names[i] == foo_sym) {
      found_foo = true;
    }
    if (module_type->data.block.field_names[i] == bar_sym) {
      found_bar = true;
    }
  }
  assert(found_foo);
  assert(found_bar);

  AstNode* member_node = make_builtin(interns, "$member", {import_node, make_ident(interns, "foo")});
  assert(member_node != NULL);
  MorphlType* result_type = morphl_infer_type_of_ast(ctx, member_node);
  assert(result_type != NULL && result_type->kind == MORPHL_TYPE_INT);

  ast_free(member_node);
  type_context_free(ctx);
  scoped_parser_free(&parser_ctx);
  interns_free(interns);
  arena_free(&arena);
  std::remove(module_path.c_str());
  printf("\u2713 test_import_block_fields passed\n");
}

static void test_import_cache_reuses_analyzed_module() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));

  const char* module_src = "$decl foo 1; $decl bar 2;";
  std::string module_path = write_temp_file(module_src);
  std::string source =
      std::string("$decl dep_a $import \"") + module_path + "\";\n" +
      std::string("$decl dep_b $import \"") + module_path + "\";\n";

  ScopedParserContext parser_ctx;
  AstNode* root = parse_source(interns, &arena, source.c_str(), &parser_ctx);
  assert(root != NULL);
  assert(root->kind == AST_FILE);
  assert(root->child_count == 2);

  AstNode* first_arg = root->children[0]->children[1]->children[0];
  AstNode* second_arg = root->children[1]->children[1]->children[0];
  assert(first_arg != NULL && second_arg != NULL);
  assert(first_arg->import_module != NULL);
  assert(second_arg->import_module != NULL);
  assert(first_arg->import_path.ptr != NULL);
  assert(second_arg->import_path.ptr != NULL);
  assert(std::strcmp(first_arg->import_path.ptr, module_path.c_str()) == 0);
  assert(std::strcmp(second_arg->import_path.ptr, module_path.c_str()) == 0);
  assert(first_arg->import_module == second_arg->import_module);
  assert(parser_ctx.import_cache_count == 1);

  ast_free(root);
  scoped_parser_free(&parser_ctx);
  interns_free(interns);
  arena_free(&arena);
  std::remove(module_path.c_str());
  printf("\u2713 test_import_cache_reuses_analyzed_module passed\n");
}

static void test_global_modules_member_inference_for_duplicate_imports() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));

  std::string module_path = write_temp_file("$decl foo 42;\n");
  std::string source =
      std::string("$decl dep_a $import \"") + module_path + "\";\n" +
      std::string("$decl dep_b $import \"") + module_path + "\";\n"
      "$decl via_import $member dep_a foo;\n"
      "$decl via_global $member $member $member $global $modules dep_b foo;\n";

  ScopedParserContext parser_ctx;
  AstNode* root = parse_source(interns, &arena, source.c_str(), &parser_ctx);
  assert(root != NULL);
  assert(root->kind == AST_FILE);
  assert(root->child_count == 4);
  assert(parser_ctx.import_cache_count == 1);

  MorphlType* file_type = morphl_infer_type_of_ast(parser_ctx.type_context, root);
  assert(file_type != NULL);

  AstNode* via_import_decl = root->children[2];
  AstNode* via_global_decl = root->children[3];
  assert(via_import_decl->kind == AST_DECL);
  assert(via_global_decl->kind == AST_DECL);
  assert(via_import_decl->type != NULL);
  assert(via_global_decl->type != NULL);
  assert(via_import_decl->type->kind == MORPHL_TYPE_INT);
  assert(via_global_decl->type->kind == MORPHL_TYPE_INT);

  AstNode* first_import_arg = root->children[0]->children[1]->children[0];
  AstNode* second_import_arg = root->children[1]->children[1]->children[0];
  assert(first_import_arg->import_module != NULL);
  assert(first_import_arg->import_module == second_import_arg->import_module);

  ast_free(root);
  scoped_parser_free(&parser_ctx);
  interns_free(interns);
  arena_free(&arena);
  std::remove(module_path.c_str());
  printf("\u2713 test_global_modules_member_inference_for_duplicate_imports passed\n");
}

static void test_alias_substitution_parse() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));

  ScopedParserContext parser_ctx;
  AstNode* root = parse_source(
    interns, &arena,
    "$alias zero 0;\n"
    "$decl x $add zero 2;\n",
    &parser_ctx);
  assert(root != NULL);
  AstNode* decl = root;
  if (root->kind == AST_FILE) {
    assert(root->child_count == 1);
    decl = root->children[0];
  }
  assert(decl != NULL);
  assert(decl->kind == AST_DECL);
  assert(decl->type != NULL);
  assert(decl->type->kind == MORPHL_TYPE_INT);
  assert(decl->child_count == 2);

  ast_free(root);
  scoped_parser_free(&parser_ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_alias_substitution_parse passed\n");
}

// ============================================================================
// Test: storage metadata and contextual extern forms
// ============================================================================
static void test_storage_shape_and_extern_metadata() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  AstNode* extern_decl = ast_new(AST_DECL);
  assert(extern_decl != NULL);
  ast_append_child(extern_decl, make_ident(interns, "printer"));
  AstNode* func_sig = make_builtin(interns, "$func", {make_literal("0"), make_literal("0")});
  ast_append_child(extern_decl, make_builtin(interns, "$extern", {func_sig}));
  MorphlType* extern_type = morphl_infer_type_of_ast(ctx, extern_decl);
  assert(extern_type != NULL && extern_type->kind == MORPHL_TYPE_FUNC);
  assert(extern_decl->contributes_to_shape == true);
  assert(extern_decl->contributes_to_layout == true);
  assert(extern_decl->storage_residence == MORPHL_STORAGE_EXTERN);
  assert(std::string(extern_decl->extern_symbol.ptr, extern_decl->extern_symbol.len) == "printer");

  AstNode* forward_decl = ast_new(AST_DECL);
  assert(forward_decl != NULL);
  ast_append_child(forward_decl, make_ident(interns, "late"));
  AstNode* forward_stub = make_builtin(interns, "$forward", {
    make_builtin(interns, "$extern", {make_builtin(interns, "$func", {make_literal("0"), make_literal("0")})})
  });
  ast_append_child(forward_decl, forward_stub);
  MorphlType* forward_type = morphl_infer_type_of_ast(ctx, forward_decl);
  assert(forward_type != NULL && forward_type->kind == MORPHL_TYPE_FUNC);

  AstNode* resolve_decl = ast_new(AST_DECL);
  assert(resolve_decl != NULL);
  ast_append_child(resolve_decl, make_ident(interns, "late"));
  AstNode* late_name = make_literal_with_kind(interns, "\"puts\"", LEXER_KIND_STRING);
  ast_append_child(resolve_decl, make_builtin(interns, "$extern", {late_name}));
  MorphlType* resolve_type = morphl_infer_type_of_ast(ctx, resolve_decl);
  assert(resolve_type != NULL && resolve_type->kind == MORPHL_TYPE_FUNC);
  assert(resolve_decl->extern_symbol.ptr != NULL);
  assert(std::string(resolve_decl->extern_symbol.ptr, resolve_decl->extern_symbol.len) == "puts");

  AstNode* bad_decl = ast_new(AST_DECL);
  assert(bad_decl != NULL);
  ast_append_child(bad_decl, make_ident(interns, "bad"));
  ast_append_child(bad_decl, make_builtin(interns, "$extern", {
    make_literal_with_kind(interns, "\"puts\"", LEXER_KIND_STRING)
  }));
  assert(morphl_infer_type_of_ast(ctx, bad_decl) == NULL);

  AstNode* block = ast_new(AST_BLOCK);
  assert(block != NULL);
  AstNode* static_decl = ast_new(AST_DECL);
  ast_append_child(static_decl, make_ident(interns, "cached"));
  ast_append_child(static_decl, make_builtin(interns, "$static", {make_literal("1")}));
  AstNode* value_decl = ast_new(AST_DECL);
  ast_append_child(value_decl, make_ident(interns, "value"));
  ast_append_child(value_decl, make_literal("2"));
  ast_append_child(block, static_decl);
  ast_append_child(block, value_decl);
  MorphlType* block_type = morphl_infer_type_of_ast(ctx, block);
  assert(block_type != NULL && block_type->kind == MORPHL_TYPE_BLOCK);
  assert(block_type->data.block.field_count == 1);
  assert(block_type->data.block.field_names[0] == interns_intern(interns, str_from("value", 5)));

  const char* module_src = "$decl foo 1; $decl bar 2;";
  std::string module_path = write_temp_file(module_src);
  ScopedParserContext parser_ctx;
  assert(scoped_parser_init(&parser_ctx, interns, &arena, NULL));
  std::string quoted_path = "\"" + module_path + "\"";
  AstNode* import_arg = make_literal_with_kind(interns, quoted_path.c_str(), LEXER_KIND_STRING);
  AstNode* import_args[] = {import_arg};
  Sym import_sym = interns_intern(interns, str_from("$import", 7));
  const OperatorInfo* import_info = operator_info_lookup(import_sym);
  assert(import_info != NULL && import_info->func != NULL);
  import_info->func(import_info, &parser_ctx, NULL, import_args, 1);
  AstNode* import_decl = ast_new(AST_DECL);
  assert(import_decl != NULL);
  ast_append_child(import_decl, make_ident(interns, "io"));
  ast_append_child(import_decl, make_builtin(interns, "$import", {import_args[0]}));
  AstNode* import_block = ast_new(AST_BLOCK);
  assert(import_block != NULL);
  ast_append_child(import_block, import_decl);
  MorphlType* import_block_type = morphl_infer_type_of_ast(ctx, import_block);
  assert(import_block_type != NULL && import_block_type->kind == MORPHL_TYPE_BLOCK);
  assert(import_block_type->data.block.field_count == 1);
  assert(import_block_type->data.block.field_names[0] == interns_intern(interns, str_from("io", 2)));
  assert(import_decl->contributes_to_shape == true);
  assert(import_decl->contributes_to_layout == true);
  scoped_parser_free(&parser_ctx);
  std::remove(module_path.c_str());

  ast_free(extern_decl);
  ast_free(forward_decl);
  ast_free(resolve_decl);
  ast_free(bad_decl);
  ast_free(block);
  ast_free(import_block);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_storage_shape_and_extern_metadata passed\n");
}

static void test_inline_decl_storage_metadata() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  AstNode* inline_decl = ast_new(AST_DECL);
  assert(inline_decl != NULL);
  ast_append_child(inline_decl, make_ident(interns, "x"));
  ast_append_child(inline_decl,
                   make_builtin(interns, "$inline", {make_literal("10")}));
  MorphlType* inline_type = morphl_infer_type_of_ast(ctx, inline_decl);
  assert(inline_type != NULL && inline_type->kind == MORPHL_TYPE_REF);
  assert(inline_type->data.ref.is_inline == true);
  assert(inline_decl->contributes_to_shape == true);
  assert(inline_decl->contributes_to_layout == true);
  assert(inline_decl->storage_residence == MORPHL_STORAGE_INSTANCE);

  ast_free(inline_decl);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_inline_decl_storage_metadata passed\n");
}

static void test_file_and_global_statics_intrinsics() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));

  const char* module_src =
    "$decl cached $static $mut 7;\n"
    "$decl value 1;\n";
  std::string module_path = write_temp_file(module_src);

  std::string source =
    std::string("$decl local $static $mut 1;\n") +
    "$decl mod $import \"" + module_path + "\";\n" +
    "$decl x $member $member $file $$statics local;\n";

  ScopedParserContext parser_ctx;
  AstNode* root = parse_source(interns, &arena, source.c_str(), &parser_ctx);
  assert(root != NULL);
  MorphlType* root_type = morphl_infer_type_of_ast(parser_ctx.type_context, root);
  assert(root_type != NULL && root_type->kind == MORPHL_TYPE_BLOCK);

  Sym statics_sym = interns_intern(interns, str_from("$$statics", 9));
  Sym source_sym = interns_intern(interns, str_from("$source", 7));
  Sym modules_sym = interns_intern(interns, str_from("$modules", 8));
  Sym mod_sym = interns_intern(interns, str_from("mod", 3));
  Sym local_sym = interns_intern(interns, str_from("local", 5));

  MorphlType* file_statics = NULL;
  for (size_t i = 0; i < root_type->data.block.field_count; ++i) {
    if (root_type->data.block.field_names[i] == statics_sym) {
      file_statics = root_type->data.block.field_types[i];
      break;
    }
  }
  assert(file_statics != NULL && file_statics->kind == MORPHL_TYPE_BLOCK);
  assert(file_statics->data.block.field_count == 1);
  assert(file_statics->data.block.field_names[0] == local_sym);

  MorphlType* global_type = type_context_get_global(parser_ctx.type_context);
  assert(global_type != NULL && global_type->kind == MORPHL_TYPE_BLOCK);
  MorphlType* source_type = NULL;
  MorphlType* modules_type = NULL;
  for (size_t i = 0; i < global_type->data.block.field_count; ++i) {
    if (global_type->data.block.field_names[i] == source_sym) source_type = global_type->data.block.field_types[i];
    if (global_type->data.block.field_names[i] == modules_sym) modules_type = global_type->data.block.field_types[i];
  }
  assert(source_type != NULL && source_type->kind == MORPHL_TYPE_BLOCK);
  assert(modules_type != NULL && modules_type->kind == MORPHL_TYPE_BLOCK);

  MorphlType* source_statics = NULL;
  for (size_t i = 0; i < source_type->data.block.field_count; ++i) {
    if (source_type->data.block.field_names[i] == statics_sym) {
      source_statics = source_type->data.block.field_types[i];
      break;
    }
  }
  assert(source_statics == file_statics);

  MorphlType* mod_type = NULL;
  for (size_t i = 0; i < modules_type->data.block.field_count; ++i) {
    if (modules_type->data.block.field_names[i] == mod_sym) {
      mod_type = modules_type->data.block.field_types[i];
      break;
    }
  }
  assert(mod_type != NULL && mod_type->kind == MORPHL_TYPE_BLOCK);
  MorphlType* mod_statics = NULL;
  for (size_t i = 0; i < mod_type->data.block.field_count; ++i) {
    if (mod_type->data.block.field_names[i] == statics_sym) {
      mod_statics = mod_type->data.block.field_types[i];
      break;
    }
  }
  assert(mod_statics != NULL && mod_statics->kind == MORPHL_TYPE_BLOCK);
  assert(mod_statics->data.block.field_count == 1);
  assert(mod_statics->data.block.field_names[0] ==
         interns_intern(interns, str_from("cached", 6)));

  ast_free(root);
  scoped_parser_free(&parser_ctx);
  interns_free(interns);
  arena_free(&arena);
  std::remove(module_path.c_str());
  printf("\u2713 test_file_and_global_statics_intrinsics passed\n");
}

// ============================================================================
// Test: Preprocessor action for $call with group parameter
// ============================================================================
static void test_pp_call_group_param() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  // Build function type: (group[int, int]) -> int
  MorphlType* t_int = morphl_type_int(&arena);
  MorphlType* group_elems[2] = {t_int, t_int};
  MorphlType* group_type = morphl_type_group(&arena, group_elems, 2);
  MorphlType* func_type = morphl_type_func(&arena, group_type, t_int);

  Sym f_sym = interns_intern(interns, str_from("f", 1));
  type_context_define_func(ctx, f_sym, func_type);

  // Build call: $call f ($group 1 2)
  AstNode* func_ident = make_ident(interns, "f");
  AstNode* arg_group = ast_new(AST_GROUP);
  assert(arg_group != NULL);
  ast_append_child(arg_group, make_literal("1"));
  ast_append_child(arg_group, make_literal("2"));

  AstNode* args_ok[] = {func_ident, arg_group};
  const OperatorInfo* call_info = operator_info_lookup(interns_intern(interns, str_from("$call", 5)));
  assert(call_info != NULL && call_info->func != NULL);
  MorphlType* ok = call_info->func(call_info, NULL, ctx, args_ok, 2);
  assert(ok != NULL && ok->kind == MORPHL_TYPE_INT);

  // Mismatched group size should fail
  AstNode* arg_group_bad = ast_new(AST_GROUP);
  assert(arg_group_bad != NULL);
  ast_append_child(arg_group_bad, make_literal("1"));

  AstNode* args_bad[] = {func_ident, arg_group_bad};
  MorphlType* bad = call_info->func(call_info, NULL, ctx, args_bad, 2);
  assert(bad == NULL);

  ast_free(func_ident);
  ast_free(arg_group);
  ast_free(arg_group_bad);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("test_pp_call_group_param passed\n");
}

// ============================================================================
// Test: Preprocessor action for $while
// ============================================================================
static void test_pp_while() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  // Condition: $lt 1 2 -> bool
  AstNode* one = make_literal("1");
  AstNode* two = make_literal("2");
  AstNode* cond = make_builtin(interns, "$lt", {one, two});
  AstNode* body = make_literal("0");
  AstNode* args_ok[] = {cond, body};
  const OperatorInfo* while_info = operator_info_lookup(interns_intern(interns, str_from("$while", 6)));
  assert(while_info != NULL && while_info->func != NULL);
  MorphlType* ok = while_info->func(while_info, NULL, ctx, args_ok, 2);
  assert(ok != NULL && ok->kind == MORPHL_TYPE_VOID);

  // Integer conditions are also valid (truthy semantics)
  const OperatorInfo* while_info_bad = operator_info_lookup(interns_intern(interns, str_from("$while", 6)));
  AstNode* cond_bad = make_literal("10");
  AstNode* args_bad[] = {cond_bad, body};
  MorphlType* bad = while_info_bad->func(while_info_bad, NULL, ctx, args_bad, 2);
  assert(bad != NULL && bad->kind == MORPHL_TYPE_VOID);

  ast_free(cond);
  ast_free(cond_bad);
  ast_free(body);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_pp_while passed\n");
}

// ============================================================================
// Test: $prop produces correct types for property declarations
// ============================================================================
static void test_pp_prop() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  // Build property declaration: $prop x int
  interns_intern(interns, str_from("x", 1));
  AstNode* prop_decl = ast_new(AST_PROP);
  assert(prop_decl != NULL);
  ast_append_child(prop_decl, make_ident(interns, "x"));
  ast_append_child(prop_decl, make_literal("1"));

  MorphlType* prop_type = morphl_infer_type_of_ast(ctx, prop_decl);
  Str prop_type_str = morphl_type_to_string(prop_type, interns);
  printf("Inferred property type: %.*s\n", (int)prop_type_str.len, prop_type_str.ptr);
  assert(prop_type != NULL);
  assert(prop_type->kind == MORPHL_TYPE_INT);


  

  ast_free(prop_decl);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_pp_prop passed\n");
}

// ============================================================================
// Test: Overload Resolution
// ============================================================================
static void test_overload_resolution() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  AstNode* overload = ast_new(AST_OVERLOAD);
  assert(overload != NULL);

  AstNode* bad = make_builtin(interns, "$add", {make_literal("1"), make_literal("2.0")});
  AstNode* good = make_builtin(interns, "$fadd", {make_literal("1.0"), make_literal("2.0")});
  assert(ast_append_child(overload, bad));
  assert(ast_append_child(overload, good));

  MorphlType* inferred = morphl_infer_type_of_ast(ctx, overload);
  assert(inferred != NULL);
  assert(inferred->kind == MORPHL_TYPE_FLOAT);
  assert(overload->kind == AST_BUILTIN);
  assert(overload->op == interns_intern(interns, str_from("$fadd", 5)));

  ast_free(overload);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_overload_resolution passed\n");
}

static void test_source_overload_type_and_arithmetic_resolution() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));

  ScopedParserContext parser_ctx;
  AstNode* root = parse_source(
      interns, &arena,
      "$decl x $overload 0 0.0;\n"
      "$decl y $add x 1;\n"
      "$decl z $fadd x 1.0;\n",
      &parser_ctx);
  assert(root != NULL);

  MorphlType* file_type = morphl_infer_type_of_ast(parser_ctx.type_context, root);
  assert(file_type != NULL);

  AstNode* x_decl = root->children[0];
  AstNode* y_decl = root->children[1];
  AstNode* z_decl = root->children[2];
  assert(x_decl->type != NULL);
  assert(x_decl->type->kind == MORPHL_TYPE_OVERLOAD);
  assert(x_decl->type->data.overload.candidate_count == 2);
  assert(x_decl->type->data.overload.candidate_types[0]->kind == MORPHL_TYPE_INT);
  assert(x_decl->type->data.overload.candidate_types[1]->kind == MORPHL_TYPE_FLOAT);

  AstNode* y_rhs = y_decl->children[1];
  AstNode* z_rhs = z_decl->children[1];
  assert(y_rhs->children[0]->overload_has_selection);
  assert(!y_rhs->children[0]->overload_select_self);
  assert(y_rhs->children[0]->overload_selected_index == 0);
  assert(z_rhs->children[0]->overload_has_selection);
  assert(!z_rhs->children[0]->overload_select_self);
  assert(z_rhs->children[0]->overload_selected_index == 1);

  ast_free(root);
  scoped_parser_free(&parser_ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_source_overload_type_and_arithmetic_resolution passed\n");
}

static void test_source_overload_call_and_set_resolution() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));

  ScopedParserContext parser_ctx;
  AstNode* root = parse_source(
      interns, &arena,
      "$decl f $overload $func ($decl n 0) n \"hello\";\n"
      "$decl y $overload 10 \"str\";\n"
      "$decl r $call f y;\n"
      "$decl x $mut $overload 0 0.0;\n"
      "$set x $overload 99 99.0;\n",
      &parser_ctx);
  assert(root != NULL);

  MorphlType* file_type = morphl_infer_type_of_ast(parser_ctx.type_context, root);
  assert(file_type != NULL);

  AstNode* call_decl = root->children[2];
  AstNode* call_rhs = call_decl->children[1];
  assert(call_rhs->children[0]->overload_has_selection);
  assert(!call_rhs->children[0]->overload_select_self);
  assert(call_rhs->children[0]->overload_selected_index == 0);
  assert(call_rhs->children[1]->overload_has_selection);
  assert(!call_rhs->children[1]->overload_select_self);
  assert(call_rhs->children[1]->overload_selected_index == 0);

  AstNode* set_expr = root->children[4];
  assert(set_expr->overload_has_selection == false);
  assert(set_expr->children[0]->overload_has_selection);
  assert(set_expr->children[0]->overload_select_self);
  assert(set_expr->children[1]->overload_has_selection);
  assert(set_expr->children[1]->overload_select_self);

  ast_free(root);
  scoped_parser_free(&parser_ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_source_overload_call_and_set_resolution passed\n");
}

// ============================================================================
// Test: $prop nodes go into prop_names/prop_types, not field_names/field_types
// ============================================================================
static void test_prop_not_in_structural_fields() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  // Block: { $decl x 1; $prop p 0; }
  AstNode* x_decl = ast_new(AST_DECL);
  assert(x_decl != NULL);
  ast_append_child(x_decl, make_ident(interns, "x"));
  ast_append_child(x_decl, make_literal("1"));

  AstNode* p_prop = ast_new(AST_PROP);
  assert(p_prop != NULL);
  ast_append_child(p_prop, make_ident(interns, "p"));
  ast_append_child(p_prop, make_literal("0"));

  AstNode* block = ast_new(AST_BLOCK);
  assert(block != NULL);
  ast_append_child(block, x_decl);
  ast_append_child(block, p_prop);

  MorphlType* t = morphl_infer_type_of_ast(ctx, block);
  assert(t != NULL);
  assert(t->kind == MORPHL_TYPE_BLOCK);

  // x is a structural field
  assert(t->data.block.field_count == 1);
  Sym x_sym = interns_intern(interns, str_from("x", 1));
  assert(t->data.block.field_names[0] == x_sym);

  // p is a property, not a structural field
  assert(t->data.block.prop_count == 1);
  // $prop handler prefixes name with '$' in the AST, check by iterating
  bool found_p = false;
  for (size_t i = 0; i < t->data.block.prop_count; ++i) {
    Str pname = interns_lookup(interns, t->data.block.prop_names[i]);
    if (pname.len >= 1 && pname.ptr[pname.len - 1] == 'p') {
      found_p = true;
    }
  }
  assert(found_p);

  ast_free(block);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_prop_not_in_structural_fields passed\n");
}

// ============================================================================
// Test: $impl with incompatible property type returns NULL (type error)
// ============================================================================
static void test_impl_type_mismatch_error() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  // $decl TraitA $traits { $prop propA 0; }  — propA has type int
  AstNode* traitPropA = ast_new(AST_PROP);
  ast_append_child(traitPropA, make_ident(interns, "propA"));
  ast_append_child(traitPropA, make_literal("0"));
  AstNode* traits_block = ast_new(AST_BLOCK);
  ast_append_child(traits_block, traitPropA);
  AstNode* traits_node = make_builtin(interns, "$traits", {traits_block});
  AstNode* traitA_decl = ast_new(AST_DECL);
  ast_append_child(traitA_decl, make_ident(interns, "TraitA"));
  ast_append_child(traitA_decl, traits_node);
  MorphlType* traitA_type = morphl_infer_type_of_ast(ctx, traitA_decl);
  assert(traitA_type != NULL);

  // $decl typeD { $decl x 0; }
  AstNode* x_decl = ast_new(AST_DECL);
  ast_append_child(x_decl, make_ident(interns, "x"));
  ast_append_child(x_decl, make_literal("0"));
  AstNode* typeD_block = ast_new(AST_BLOCK);
  ast_append_child(typeD_block, x_decl);
  AstNode* typeD_decl = ast_new(AST_DECL);
  ast_append_child(typeD_decl, make_ident(interns, "typeD"));
  ast_append_child(typeD_decl, typeD_block);
  MorphlType* typeD_type = morphl_infer_type_of_ast(ctx, typeD_decl);
  assert(typeD_type != NULL);

  // $impl TraitA typeD { $prop propA 1.0; }  — override propA with float (mismatch!)
  AstNode* override_propA = ast_new(AST_PROP);
  ast_append_child(override_propA, make_ident(interns, "propA"));
  ast_append_child(override_propA, make_literal("1.0"));
  AstNode* override_block = ast_new(AST_BLOCK);
  ast_append_child(override_block, override_propA);
  AstNode* impl_node = make_builtin(interns, "$impl", {
    make_ident(interns, "TraitA"),
    make_ident(interns, "typeD"),
    override_block
  });

  // Silence error output during this expected-failure inference
  MorphlErrorSink null_sink = {NULL, NULL};
  MorphlErrorSink prev = morphl_error_get_global_sink();
  morphl_error_set_global_sink(null_sink);

  MorphlType* result = morphl_infer_type_of_ast(ctx, impl_node);

  morphl_error_set_global_sink(prev);

  // float override for an int trait property must be rejected
  assert(result == NULL);

  ast_free(traitA_decl);
  ast_free(typeD_decl);
  ast_free(impl_node);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_impl_type_mismatch_error passed\n");
}

// ============================================================================
// Main Test Runner
// ============================================================================
static void test_array_type() {
  Arena arena = create_test_arena();

  MorphlType* elem = morphl_type_int(&arena);
  MorphlType* arr3 = morphl_type_array(&arena, elem, 3);
  assert(arr3 != NULL);
  assert(arr3->kind == MORPHL_TYPE_ARRAY);
  assert(arr3->data.array.count == 3);
  assert(arr3->data.array.elem_type == elem);
  /* size = 3 * 8 = 24 */
  assert(arr3->size == 24);

  /* equality: same count+elem */
  MorphlType* arr3b = morphl_type_array(&arena, morphl_type_int(&arena), 3);
  assert(morphl_type_equals(arr3, arr3b));

  /* inequality: different count */
  MorphlType* arr4 = morphl_type_array(&arena, elem, 4);
  assert(!morphl_type_equals(arr3, arr4));

  /* inequality: different elem */
  MorphlType* arr3f = morphl_type_array(&arena, morphl_type_float(&arena), 3);
  assert(!morphl_type_equals(arr3, arr3f));

  /* no prefix subtyping */
  assert(!morphl_type_is_subtype(arr3, arr4));

  arena_free(&arena);
  printf("  PASS test_array_type\n");
}

static void test_union_type() {
  Arena arena = create_test_arena();

  MorphlType* ti = morphl_type_int(&arena);
  MorphlType* tf = morphl_type_float(&arena);
  MorphlType* variants[2] = {ti, tf};
  MorphlType* u = morphl_type_union(&arena, variants, 2);
  assert(u != NULL);
  assert(u->kind == MORPHL_TYPE_UNION);
  assert(u->data.union_t.variant_count == 2);
  /* size = 8 (tag) + max(8, 8) = 16 */
  assert(u->size == 16);

  /* subtyping: int <: union(int, float) */
  assert(morphl_type_is_subtype(ti, u));
  assert(morphl_type_is_subtype(tf, u));

  /* $never is subtype of everything */
  MorphlType* never = morphl_type_never(&arena);
  assert(morphl_type_is_subtype(never, u));
  assert(morphl_type_is_subtype(never, ti));

  /* flattening: $union int ($union float bool) → $union int float bool */
  MorphlType* tb = morphl_type_bool(&arena);
  MorphlType* inner[2] = {tf, tb};
  MorphlType* inner_u = morphl_type_union(&arena, inner, 2);
  MorphlType* outer[2] = {ti, inner_u};
  MorphlType* flat = morphl_type_union(&arena, outer, 2);
  assert(flat->data.union_t.variant_count == 3);

  /* collapse: $union int $never → int */
  MorphlType* with_never[2] = {ti, never};
  MorphlType* collapsed = morphl_type_union(&arena, with_never, 2);
  assert(collapsed->kind == MORPHL_TYPE_INT);

  arena_free(&arena);
  printf("  PASS test_union_type\n");
}

// ============================================================================
// Test: control-flow type inference ($if, $while, $break, $continue)
// ============================================================================
static void test_control_flow_inference() {
  Arena arena = create_test_arena();
  InternTable* interns = create_test_interns();
  assert(operator_registry_init(interns));
  TypeContext* ctx = type_context_new(&arena, interns);
  assert(ctx != NULL);

  // $if with no else → void
  {
    Sym if_sym = interns_intern(interns, str_from("$if", 3));
    MorphlType* bool_t = morphl_type_bool(&arena);
    MorphlType* int_t  = morphl_type_int(&arena);
    MorphlType* args[2] = { bool_t, int_t };
    MorphlType* result = morphl_infer_type_for_op(ctx, NULL, if_sym, args, 2);
    assert(result && result->kind == MORPHL_TYPE_VOID);
  }

  // $if with matching branches → that type
  {
    Sym if_sym = interns_intern(interns, str_from("$if", 3));
    MorphlType* bool_t = morphl_type_bool(&arena);
    MorphlType* int_t  = morphl_type_int(&arena);
    MorphlType* args[3] = { bool_t, int_t, morphl_type_int(&arena) };
    MorphlType* result = morphl_infer_type_for_op(ctx, NULL, if_sym, args, 3);
    assert(result && result->kind == MORPHL_TYPE_INT);
  }

  // $if with $never then-branch → else type
  {
    Sym if_sym = interns_intern(interns, str_from("$if", 3));
    MorphlType* bool_t  = morphl_type_bool(&arena);
    MorphlType* never_t = morphl_type_never(&arena);
    MorphlType* float_t = morphl_type_float(&arena);
    MorphlType* args[3] = { bool_t, never_t, float_t };
    MorphlType* result = morphl_infer_type_for_op(ctx, NULL, if_sym, args, 3);
    assert(result && result->kind == MORPHL_TYPE_FLOAT);
  }

  // $if with $never else-branch → then type
  {
    Sym if_sym = interns_intern(interns, str_from("$if", 3));
    MorphlType* bool_t  = morphl_type_bool(&arena);
    MorphlType* int_t   = morphl_type_int(&arena);
    MorphlType* never_t = morphl_type_never(&arena);
    MorphlType* args[3] = { bool_t, int_t, never_t };
    MorphlType* result = morphl_infer_type_for_op(ctx, NULL, if_sym, args, 3);
    assert(result && result->kind == MORPHL_TYPE_INT);
  }

  // $if with divergent branches → union
  {
    Sym if_sym = interns_intern(interns, str_from("$if", 3));
    MorphlType* bool_t  = morphl_type_bool(&arena);
    MorphlType* int_t   = morphl_type_int(&arena);
    MorphlType* float_t = morphl_type_float(&arena);
    MorphlType* args[3] = { bool_t, int_t, float_t };
    MorphlType* result = morphl_infer_type_for_op(ctx, NULL, if_sym, args, 3);
    assert(result && result->kind == MORPHL_TYPE_UNION);
    assert(result->data.union_t.variant_count == 2);
  }

  // $while → void
  {
    Sym while_sym = interns_intern(interns, str_from("$while", 6));
    MorphlType* bool_t = morphl_type_bool(&arena);
    MorphlType* void_t = morphl_type_void(&arena);
    MorphlType* args[2] = { bool_t, void_t };
    MorphlType* result = morphl_infer_type_for_op(ctx, NULL, while_sym, args, 2);
    assert(result && result->kind == MORPHL_TYPE_VOID);
  }

  // $if with int condition is valid
  {
    Sym if_sym = interns_intern(interns, str_from("$if", 3));
    MorphlType* int_t = morphl_type_int(&arena);
    MorphlType* args[3] = { int_t, morphl_type_int(&arena), morphl_type_int(&arena) };
    MorphlType* result = morphl_infer_type_for_op(ctx, NULL, if_sym, args, 3);
    assert(result && result->kind == MORPHL_TYPE_INT);
  }

  // $ret → $never
  {
    Sym ret_sym = interns_intern(interns, str_from("$ret", 4));
    type_context_set_return_type(ctx, morphl_type_unknown(&arena));
    MorphlType* args[1] = { morphl_type_int(&arena) };
    MorphlType* result = morphl_infer_type_for_op(ctx, NULL, ret_sym, args, 1);
    assert(result && result->kind == MORPHL_TYPE_NEVER);
    type_context_set_return_type(ctx, NULL);
  }

  // $exit → $never
  {
    Sym exit_sym = interns_intern(interns, str_from("$exit", 5));
    MorphlType* args[1] = { morphl_type_int(&arena) };
    MorphlType* result = morphl_infer_type_for_op(ctx, NULL, exit_sym, args, 1);
    assert(result && result->kind == MORPHL_TYPE_NEVER);
  }

  // $break → $never
  {
    Sym break_sym = interns_intern(interns, str_from("$break", 6));
    MorphlType* args[0] = {};
    MorphlType* result = morphl_infer_type_for_op(ctx, NULL, break_sym, args, 0);
    assert(result && result->kind == MORPHL_TYPE_NEVER);
  }

  // $continue → $never
  {
    Sym cont_sym = interns_intern(interns, str_from("$continue", 9));
    MorphlType* args[0] = {};
    MorphlType* result = morphl_infer_type_for_op(ctx, NULL, cont_sym, args, 0);
    assert(result && result->kind == MORPHL_TYPE_NEVER);
  }

  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("  PASS test_control_flow_inference\n");
}

int main() {
  printf("Running typing system tests...\n\n");

  test_type_constructors();
  test_type_equality();
  test_type_context_scopes();
  test_type_context_vars();
  test_type_context_functions();
  test_type_clone();
  test_infer_arithmetic_ops();
  test_infer_comparison_ops();
  test_infer_logic_ops();
  test_infer_bitwise_ops();
  test_ref_meta_forward_ops();
  test_literal_inference_kinds();
  test_pp_set();
  test_pp_ret();
  test_pp_member();
  test_import_block_fields();
  test_import_cache_reuses_analyzed_module();
  test_global_modules_member_inference_for_duplicate_imports();
  test_alias_substitution_parse();
  test_storage_shape_and_extern_metadata();
  test_inline_decl_storage_metadata();
  test_file_and_global_statics_intrinsics();
  test_pp_call_group_param();
  test_pp_while();
  test_overload_resolution();
  test_source_overload_type_and_arithmetic_resolution();
  test_source_overload_call_and_set_resolution();
  test_pp_prop();
  test_prop_not_in_structural_fields();
  test_impl_type_mismatch_error();
  test_array_type();
  test_union_type();
  test_control_flow_inference();
  // Note: Recursion is tested via examples/test_recursion.mpl
  // Unit testing recursion requires full parser integration

  printf("\n\u2713 All typing tests passed!\n");
  return 0;
}
