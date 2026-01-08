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
  
  printf("\n✓ All typing tests passed!\n");
  return 0;
}
