#include <assert.h>
#include <cstdio>
#include <cstring>
#include <vector>

extern "C" {
#include "typing/typing.h"
#include "typing/type_context.h"
#include "typing/inference.h"
#include "util/util.h"
#include "parser/operators.h"
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
  MorphlType* result = morphl_infer_type_for_op(ctx, add_sym, arg_types, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_INT);
  
  // Test $fadd (float, float) -> float
  Sym fadd_sym = interns_intern(interns, str_from("$fadd", 5));
  MorphlType* arg_types_f[] = {t_float, t_float};
  result = morphl_infer_type_for_op(ctx, fadd_sym, arg_types_f, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_FLOAT);
  
  // Test type error: $add (int, float) should fail (output will be printed)
  MorphlType* mixed_args[] = {t_int, t_float};
  result = morphl_infer_type_for_op(ctx, add_sym, mixed_args, 2);
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
  MorphlType* result = morphl_infer_type_for_op(ctx, eq_sym, arg_types, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_BOOL);
  
  // Test $lt (int, int) -> bool
  Sym lt_sym = interns_intern(interns, str_from("$lt", 3));
  result = morphl_infer_type_for_op(ctx, lt_sym, arg_types, 2);
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
  MorphlType* result = morphl_infer_type_for_op(ctx, and_sym, arg_types, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_BOOL);
  
  // Test $not (bool) -> bool
  Sym not_sym = interns_intern(interns, str_from("$not", 4));
  MorphlType* arg_types_not[] = {t_bool};
  result = morphl_infer_type_for_op(ctx, not_sym, arg_types_not, 1);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_BOOL);
  
  // Test type error: $and (int, int) should fail
  MorphlType* int_args[] = {t_int, t_int};
  result = morphl_infer_type_for_op(ctx, and_sym, int_args, 2);
  assert(result == NULL);
  
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
  MorphlType* result = morphl_infer_type_for_op(ctx, band_sym, arg_types, 2);
  assert(result != NULL);
  assert(result->kind == MORPHL_TYPE_INT);
  
  // Test $bnot (int) -> int
  Sym bnot_sym = interns_intern(interns, str_from("$bnot", 5));
  MorphlType* arg_types_bnot[] = {t_int};
  result = morphl_infer_type_for_op(ctx, bnot_sym, arg_types_bnot, 1);
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

  // Non-bool condition should fail (fresh lookup because operator_info_lookup uses a static buffer)
  const OperatorInfo* while_info_bad = operator_info_lookup(interns_intern(interns, str_from("$while", 6)));
  AstNode* cond_bad = make_literal("10");
  AstNode* args_bad[] = {cond_bad, body};
  MorphlType* bad = while_info_bad->func(while_info_bad, NULL, ctx, args_bad, 2);
  assert(bad == NULL);

  ast_free(cond);
  ast_free(cond_bad);
  ast_free(body);
  type_context_free(ctx);
  interns_free(interns);
  arena_free(&arena);
  printf("\u2713 test_pp_while passed\n");
}

// ============================================================================
// Main Test Runner
// ============================================================================
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
  test_pp_set();
  test_pp_ret();
  test_pp_member();
  test_pp_call_group_param();
  test_pp_while();
  // Note: Recursion is tested via examples/test_recursion.mpl
  // Unit testing recursion requires full parser integration

  printf("\n\u2713 All typing tests passed!\n");
  return 0;
}
