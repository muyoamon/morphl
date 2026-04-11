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
    printf("All integration tests passed.\n");
    return 0;
}
