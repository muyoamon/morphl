#include <assert.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <ctime>
#include <sstream>
#include <fstream>
#include <string>
#include <vector>

extern "C" {
#include "lexer/lexer.h"
#include "parser/operators.h"
#include "parser/scoped_parser.h"
#include "runtime/runtime.h"
#include "util/file.h"
#include "util/util.h"
#include "backend/backend.h"
#include "ast/ast.h"
}

// ── Helpers ───────────────────────────────────────────────────────────────────

static int counter_g = 0;

static std::string temp_path(const char* ext) {
    const char* tmpdir = std::getenv("TMPDIR");
    if (!tmpdir) tmpdir = "/tmp";
    std::ostringstream ss;
    ss << tmpdir << "/morphl_it_" << ++counter_g << ext;
    return ss.str();
}

static std::string write_temp_source(const char* source) {
    std::string path = temp_path(".mpl");
    std::ofstream f(path, std::ios::trunc);
    assert(f.is_open());
    f << source;
    f.close();
    return path;
}

/*
 * Compile morphl source (builtin prefix syntax) and run it.
 * Returns the VM exit code (0 = success), or -1 if parse/compile fails.
 */
static int compile_and_run(const char* source) {
    std::string src_path = write_temp_source(source);
    std::string out_path = temp_path(".mbc");

    InternTable* interns = interns_new();
    if (!interns) return -1;

    if (!operator_registry_init(interns)) {
        interns_free(interns);
        return -1;
    }

    Arena arena;
    arena_init(&arena, 65536);

    ScopedParserContext parser_ctx;
    if (!scoped_parser_init(&parser_ctx, interns, &arena, src_path.c_str())) {
        arena_free(&arena);
        interns_free(interns);
        return -1;
    }

    char* source_buffer = NULL;
    size_t source_len = 0;
    if (!morphl_file_read_all(src_path.c_str(), &source_buffer, &source_len)) {
        scoped_parser_free(&parser_ctx);
        arena_free(&arena);
        interns_free(interns);
        return -1;
    }

    struct token* tokens = NULL;
    size_t token_count = 0;
    if (!lexer_tokenize(src_path.c_str(),
                        str_from(source_buffer, source_len),
                        interns, &tokens, &token_count)) {
        free(source_buffer);
        scoped_parser_free(&parser_ctx);
        arena_free(&arena);
        interns_free(interns);
        return -1;
    }

    AstNode* root = NULL;
    bool accepted = scoped_parse_ast(&parser_ctx, tokens, token_count, &root);
    if (!accepted) {
        free(tokens); free(source_buffer);
        scoped_parser_free(&parser_ctx);
        arena_free(&arena); interns_free(interns);
        return -1;
    }

    MorphlBackendContext backend_ctx;
    backend_ctx.tree         = root;
    backend_ctx.out_file     = out_path.c_str();
    backend_ctx.type_context = parser_ctx.type_context;

    int result = -1;
    if (morphl_register_backend(MORPHL_BACKEND_TYPE_VM) && morphl_compile(&backend_ctx)) {
        FILE* dev_null = fopen("/dev/null", "w");
        result = (int)morphl_vm_run_file(out_path.c_str(), dev_null ? dev_null : stderr);
        if (dev_null) fclose(dev_null);
    }

    ast_free(root);
    free(tokens);
    free(source_buffer);
    scoped_parser_free(&parser_ctx);
    arena_free(&arena);
    interns_free(interns);

    std::remove(src_path.c_str());
    std::remove(out_path.c_str());

    return result;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/* Spec §3 ($decl): basic integer declaration */
static void test_e2e_integer_decl() {
    int rc = compile_and_run("$decl x 42;");
    assert(rc == 0);
    printf("PASS test_e2e_integer_decl\n");
}

/* Spec §3 + §11.3: integer arithmetic */
static void test_e2e_integer_arithmetic() {
    int rc = compile_and_run(
        "$decl x 10;\n"
        "$decl y 20;\n"
        "$decl z $add x y;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_integer_arithmetic\n");
}

/* Spec §11.3: float arithmetic */
static void test_e2e_float_arithmetic() {
    int rc = compile_and_run(
        "$decl x 1.5;\n"
        "$decl y 2.5;\n"
        "$decl z $fadd x y;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_float_arithmetic\n");
}

/* Spec §11.4: integer comparison */
static void test_e2e_comparison() {
    int rc = compile_and_run(
        "$decl x 5;\n"
        "$decl y 3;\n"
        "$decl gt $gt x y;\n"
        "$decl lt $lt x y;\n"
        "$decl eq $eq x x;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_comparison\n");
}

/* Spec §4 ($mut) + §11.1 (store): mutable re-assignment */
static void test_e2e_mut_assign() {
    int rc = compile_and_run(
        "$decl x $mut 10;\n"
        "$set x 20;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_mut_assign\n");
}

/* Spec §11.5: type conversion */
static void test_e2e_type_conversion() {
    int rc = compile_and_run(
        "$decl n 5;\n"
        "$decl f $i2f n;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_type_conversion\n");
}

/* Spec §11.10: if/else with true branch */
static void test_e2e_if_true_branch() {
    int rc = compile_and_run(
        "$decl x 2;\n"
        "$decl cond $lte x 3;\n"
        "$if cond 1 0;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_if_true_branch\n");
}

/* Spec §11.10: if/else with false branch */
static void test_e2e_if_false_branch() {
    int rc = compile_and_run(
        "$decl x 5;\n"
        "$decl cond $lte x 3;\n"
        "$if cond 1 0;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_if_false_branch\n");
}

/* Spec §3: multiple declarations with mixed types */
static void test_e2e_multiple_decls() {
    int rc = compile_and_run(
        "$decl a 10;\n"
        "$decl b 20;\n"
        "$decl c $add a b;\n"
        "$decl d $mul a b;\n"
        "$decl e $sub d c;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_multiple_decls\n");
}

/* Spec §4.3 ($ref local alias): using r reads through to x */
static void test_e2e_ref_alias_read() {
    int rc = compile_and_run(
        "$decl x $mut 42;\n"
        "$decl r $ref x;\n"
        "$decl y $add r 1;\n"   /* reads x via alias r, y = 43 */
    );
    assert(rc == 0);
    printf("PASS test_e2e_ref_alias_read\n");
}

/* Spec §4.3 ($ref local alias): assigning through r writes to x */
static void test_e2e_ref_alias_write() {
    int rc = compile_and_run(
        "$decl x $mut 10;\n"
        "$decl r $ref x;\n"
        "$set r 99;\n"          /* writes through alias to x */
        "$decl z $add x 1;\n"  /* x should now be 99, z = 100 */
    );
    assert(rc == 0);
    printf("PASS test_e2e_ref_alias_write\n");
}

/* Spec §6 ($func) + CALLF: call a function stored as a value */
static void test_e2e_callf() {
    int rc = compile_and_run(
        "$decl add $func ($decl a 0, $decl b 0) {\n"
        "    $ret $add a b;\n"
        "};\n"
        "$decl result $call add (3 4);\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_callf\n");
}

/* Spec §5.5 ($null): push and compare null reference */
static void test_e2e_null() {
    int rc = compile_and_run(
        "$decl n $null;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_null\n");
}

/* Spec §7 ($this): $this resolves to the current function's frame address */
static void test_e2e_this() {
    int rc = compile_and_run(
        "$decl f $func () {\n"
        "    $ret $this;\n"
        "};\n"
        "$call f ();\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_this\n");
}

/* Spec §7 ($parent): $parent resolves to the caller's frame address (hidden arg) */
static void test_e2e_parent() {
    int rc = compile_and_run(
        "$decl x 10;\n"
        "$decl f $func () {\n"
        "    $ret $parent;\n"
        "};\n"
        "$call f ();\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_parent\n");
}

/* Spec §9.1 ($traits): basic trait declaration */
static void test_e2e_traits_decl() {
    int rc = compile_and_run(
        "$decl TraitA $traits {\n"
        "    $prop propA 30;\n"
        "};\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_traits_decl\n");
}

/* Spec §9.2 ($impl): impl declaration extending a base type with trait properties */
static void test_e2e_impl_decl() {
    int rc = compile_and_run(
        "$decl typeD {\n"
        "    $decl x 0;\n"
        "};\n"
        "$decl TraitA $traits {\n"
        "    $prop propA 30;\n"
        "};\n"
        "$decl typeE $impl TraitA typeD {\n"
        "    $prop propA 99;\n"
        "};\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_impl_decl\n");
}

/* Spec §9.2 ($impl): impl with function property default */
static void test_e2e_impl_with_func_prop() {
    int rc = compile_and_run(
        "$decl typeD {\n"
        "    $decl x 5;\n"
        "};\n"
        "$decl TraitA $traits {\n"
        "    $prop propA 0;\n"
        "    $prop methodB $func () 0;\n"
        "};\n"
        "$decl typeE $impl TraitA typeD {\n"
        "    $prop propA 99;\n"
        "    $prop methodB $func () {\n"
        "        $ret $parent;\n"
        "    };\n"
        "};\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_impl_with_func_prop\n");
}

/* Spec §$exit: explicit exit with code 0 */
static void test_e2e_exit_zero() {
    int rc = compile_and_run("$exit 0;\n");
    assert(rc == 0);
    printf("PASS test_e2e_exit_zero\n");
}

/* Spec §$exit: explicit exit with non-zero code */
static void test_e2e_exit_nonzero() {
    int rc = compile_and_run("$exit 42;\n");
    assert(rc == 42);
    printf("PASS test_e2e_exit_nonzero\n");
}

/* Spec §main: top-level main auto-called, return value used as exit code */
static void test_e2e_main_autocall() {
    int rc = compile_and_run(
        "$decl main $func () {\n"
        "    $ret 7;\n"
        "};\n"
    );
    assert(rc == 7);
    printf("PASS test_e2e_main_autocall\n");
}

/* Spec §main: main returning 0 produces exit code 0 */
static void test_e2e_main_returns_zero() {
    int rc = compile_and_run(
        "$decl main $func () {\n"
        "    $ret 0;\n"
        "};\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_main_returns_zero\n");
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(void) {
    test_e2e_integer_decl();
    test_e2e_integer_arithmetic();
    test_e2e_float_arithmetic();
    test_e2e_comparison();
    test_e2e_mut_assign();
    test_e2e_type_conversion();
    test_e2e_if_true_branch();
    test_e2e_if_false_branch();
    test_e2e_multiple_decls();
    test_e2e_ref_alias_read();
    test_e2e_ref_alias_write();
    test_e2e_callf();
    test_e2e_null();
    test_e2e_this();
    test_e2e_parent();
    test_e2e_traits_decl();
    test_e2e_impl_decl();
    test_e2e_impl_with_func_prop();
    test_e2e_exit_zero();
    test_e2e_exit_nonzero();
    test_e2e_main_autocall();
    test_e2e_main_returns_zero();
    printf("All integration tests passed.\n");
    return 0;
}
