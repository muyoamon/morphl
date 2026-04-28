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
static int64_t vm_link_init_counter_g = 0;

static int64_t native_vm_link_tick(uint8_t* stack, size_t frame_base, size_t param_size) {
    (void)stack;
    (void)frame_base;
    (void)param_size;
    vm_link_init_counter_g += 1;
    return vm_link_init_counter_g;
}

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

static bool read_u16_le(const uint8_t* buf, size_t len, size_t* pos, uint16_t* out) {
    if (*pos + 2 > len) return false;
    *out = (uint16_t)((uint16_t)buf[*pos] | ((uint16_t)buf[*pos + 1] << 8));
    *pos += 2;
    return true;
}

static bool read_u32_le(const uint8_t* buf, size_t len, size_t* pos, uint32_t* out) {
    if (*pos + 4 > len) return false;
    *out = (uint32_t)buf[*pos]
         | ((uint32_t)buf[*pos + 1] << 8)
         | ((uint32_t)buf[*pos + 2] << 16)
         | ((uint32_t)buf[*pos + 3] << 24);
    *pos += 4;
    return true;
}

static uint32_t read_u32_le_at(const uint8_t* buf, size_t off) {
    return (uint32_t)buf[off]
         | ((uint32_t)buf[off + 1] << 8)
         | ((uint32_t)buf[off + 2] << 16)
         | ((uint32_t)buf[off + 3] << 24);
}

static uint64_t read_u64_le_at(const uint8_t* buf, size_t off) {
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v |= ((uint64_t)buf[off + i]) << (8 * i);
    return v;
}

static bool read_bytes(const uint8_t* buf, size_t len, size_t* pos, void* out, size_t n) {
    if (*pos + n > len) return false;
    std::memcpy(out, buf + *pos, n);
    *pos += n;
    return true;
}

static std::string read_len_string(const uint8_t* buf, size_t len, size_t* pos) {
    uint32_t slen = 0;
    if (!read_u32_le(buf, len, pos, &slen)) return std::string();
    std::vector<char> bytes(slen + 1, '\0');
    if (!read_bytes(buf, len, pos, bytes.data(), slen + 1)) return std::string();
    return std::string(bytes.data(), slen);
}

typedef struct {
    std::string name;
    uint16_t kind;
    uint16_t flags;
    uint32_t symbol_value;
} TestVmObjectExport;

typedef struct {
    uint16_t kind;
    uint32_t code_offset;
    std::string module_path;
    std::string symbol_name;
} TestVmObjectRelocation;

typedef struct {
    std::string binding_name;
    std::string path;
    uint32_t global_slot;
    std::vector<std::string> required_funcs;
} TestVmObjectImport;

typedef struct {
    uint16_t artifact_kind;
    uint32_t global_frame_size;
    uint32_t func_count;
    std::vector<VmFunctionMeta> functions;
    std::vector<uint8_t> code;
    std::string module_path;
    uint32_t module_init_func_idx;
    std::vector<TestVmObjectExport> exports;
    std::vector<TestVmObjectImport> imports;
    uint32_t relocation_count;
    std::vector<TestVmObjectRelocation> relocations;
} TestVmObjectFile;

static bool parse_vm_binary_file(const std::string& path, TestVmObjectFile* out) {
    if (!out) return false;
    std::ifstream f(path, std::ios::binary);
    if (!f.is_open()) return false;
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());
    if (buf.size() < 4) return false;
    size_t pos = 0;
    uint8_t magic[4];
    if (!read_bytes(buf.data(), buf.size(), &pos, magic, 4)) return false;
    if (std::memcmp(magic, MORPHL_VM_MAGIC, 4) != 0) return false;
    uint16_t vmaj = 0, vmin = 0;
    if (!read_u16_le(buf.data(), buf.size(), &pos, &vmaj) ||
        !read_u16_le(buf.data(), buf.size(), &pos, &vmin) ||
        !read_u16_le(buf.data(), buf.size(), &pos, &out->artifact_kind) ||
        !read_u32_le(buf.data(), buf.size(), &pos, &out->global_frame_size) ||
        !read_u32_le(buf.data(), buf.size(), &pos, &out->func_count)) {
        return false;
    }
    out->functions.resize(out->func_count);
    for (uint32_t i = 0; i < out->func_count; ++i) {
        if (!read_u32_le(buf.data(), buf.size(), &pos, &out->functions[i].entry_point) ||
            !read_u32_le(buf.data(), buf.size(), &pos, &out->functions[i].frame_size) ||
            !read_u32_le(buf.data(), buf.size(), &pos, &out->functions[i].param_size) ||
            !read_u32_le(buf.data(), buf.size(), &pos, &out->functions[i].flags)) {
            return false;
        }
    }
    uint32_t code_len = 0;
    if (!read_u32_le(buf.data(), buf.size(), &pos, &code_len)) return false;
    out->code.resize(code_len);
    if (code_len > 0 && !read_bytes(buf.data(), buf.size(), &pos, out->code.data(), code_len)) return false;

    uint32_t str_count = 0;
    if (!read_u32_le(buf.data(), buf.size(), &pos, &str_count)) return false;
    for (uint32_t i = 0; i < str_count; ++i) {
        (void)read_len_string(buf.data(), buf.size(), &pos);
    }
    uint32_t native_count = 0;
    if (!read_u32_le(buf.data(), buf.size(), &pos, &native_count)) return false;
    for (uint32_t i = 0; i < native_count; ++i) {
        (void)read_len_string(buf.data(), buf.size(), &pos);
    }

    if (out->artifact_kind != MORPHL_VM_ARTIFACT_OBJECT) {
        out->module_path.clear();
        out->module_init_func_idx = 0;
        out->exports.clear();
        out->imports.clear();
        out->relocation_count = 0;
        out->relocations.clear();
        return true;
    }

    out->module_path = read_len_string(buf.data(), buf.size(), &pos);
    if (!read_u32_le(buf.data(), buf.size(), &pos, &out->module_init_func_idx)) return false;

    uint32_t export_count = 0;
    if (!read_u32_le(buf.data(), buf.size(), &pos, &export_count)) return false;
    out->exports.resize(export_count);
    for (uint32_t i = 0; i < export_count; ++i) {
        uint32_t name_len = 0;
        if (!read_u16_le(buf.data(), buf.size(), &pos, &out->exports[i].kind) ||
            !read_u16_le(buf.data(), buf.size(), &pos, &out->exports[i].flags) ||
            !read_u32_le(buf.data(), buf.size(), &pos, &out->exports[i].symbol_value) ||
            !read_u32_le(buf.data(), buf.size(), &pos, &name_len)) {
            return false;
        }
        std::vector<char> bytes(name_len + 1, '\0');
        if (!read_bytes(buf.data(), buf.size(), &pos, bytes.data(), name_len + 1)) return false;
        out->exports[i].name.assign(bytes.data(), name_len);
    }

    uint32_t import_count = 0;
    if (!read_u32_le(buf.data(), buf.size(), &pos, &import_count)) return false;
    out->imports.resize(import_count);
    for (uint32_t i = 0; i < import_count; ++i) {
        out->imports[i].binding_name = read_len_string(buf.data(), buf.size(), &pos);
        out->imports[i].path = read_len_string(buf.data(), buf.size(), &pos);
        if (!read_u32_le(buf.data(), buf.size(), &pos, &out->imports[i].global_slot)) {
            return false;
        }
        uint32_t required_func_count = 0;
        if (!read_u32_le(buf.data(), buf.size(), &pos, &required_func_count)) return false;
        out->imports[i].required_funcs.resize(required_func_count);
        for (uint32_t fi = 0; fi < required_func_count; ++fi) {
            out->imports[i].required_funcs[fi] = read_len_string(buf.data(), buf.size(), &pos);
        }
    }

    if (!read_u32_le(buf.data(), buf.size(), &pos, &out->relocation_count)) return false;
    out->relocations.resize(out->relocation_count);
    for (uint32_t i = 0; i < out->relocation_count; ++i) {
        if (!read_u16_le(buf.data(), buf.size(), &pos, &out->relocations[i].kind) ||
            !read_u32_le(buf.data(), buf.size(), &pos, &out->relocations[i].code_offset)) {
            return false;
        }
        if (out->relocations[i].kind == MORPHL_VM_RELOC_EXTERN_FUNC_U32 ||
            out->relocations[i].kind == MORPHL_VM_RELOC_EXTERN_FUNC_I64 ||
            out->relocations[i].kind == MORPHL_VM_RELOC_EXTERN_DATA_I32 ||
            out->relocations[i].kind == MORPHL_VM_RELOC_MODULE_SLOT_I32) {
            out->relocations[i].module_path = read_len_string(buf.data(), buf.size(), &pos);
            out->relocations[i].symbol_name = read_len_string(buf.data(), buf.size(), &pos);
        }
    }
    return true;
}

static bool parse_vm_object_file(const std::string& path, TestVmObjectFile* out) {
    if (!parse_vm_binary_file(path, out)) return false;
    return out->artifact_kind == MORPHL_VM_ARTIFACT_OBJECT;
}

static bool compile_file_to_artifact(const std::string& src_path, const std::string& out_path) {
    InternTable* interns = interns_new();
    if (!interns) return false;

    if (!operator_registry_init(interns)) {
        interns_free(interns);
        return false;
    }

    Arena arena;
    arena_init(&arena, 65536);

    ScopedParserContext parser_ctx;
    if (!scoped_parser_init(&parser_ctx, interns, &arena, src_path.c_str())) {
        arena_free(&arena);
        interns_free(interns);
        return false;
    }

    char* source_buffer = NULL;
    size_t source_len = 0;
    if (!morphl_file_read_all(src_path.c_str(), &source_buffer, &source_len)) {
        scoped_parser_free(&parser_ctx);
        arena_free(&arena);
        interns_free(interns);
        return false;
    }

    struct token* tokens = NULL;
    size_t token_count = 0;
    if (!lexer_tokenize(src_path.c_str(), str_from(source_buffer, source_len),
                        interns, &tokens, &token_count)) {
        free(source_buffer);
        scoped_parser_free(&parser_ctx);
        arena_free(&arena);
        interns_free(interns);
        return false;
    }

    AstNode* root = NULL;
    bool accepted = scoped_parse_ast(&parser_ctx, tokens, token_count, &root);
    bool ok = false;
    if (accepted) {
        MorphlBackendContext backend_ctx = {};
        backend_ctx.tree = root;
        backend_ctx.out_file = out_path.c_str();
        backend_ctx.type_context = parser_ctx.type_context;
        ok = morphl_register_backend(MORPHL_BACKEND_TYPE_VM) &&
             morphl_compile(&backend_ctx);
        ast_free(root);
    }

    free(tokens);
    free(source_buffer);
    scoped_parser_free(&parser_ctx);
    arena_free(&arena);
    interns_free(interns);
    return ok;
}

static bool compile_source_to_artifact(const char* source, const std::string& out_path) {
    std::string src_path = write_temp_source(source);
    bool ok = compile_file_to_artifact(src_path, out_path);
    std::remove(src_path.c_str());
    return ok;
}

static int compile_link_and_run(const char* source) {
    std::string obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    if (!compile_source_to_artifact(source, obj_path)) {
        std::remove(obj_path.c_str());
        std::remove(exe_path.c_str());
        return -1;
    }
    const char* inputs[] = {obj_path.c_str()};
    if (!morphl_vm_link_files(exe_path.c_str(), inputs, 1, stderr)) {
        std::remove(obj_path.c_str());
        std::remove(exe_path.c_str());
        return -1;
    }
    FILE* dev_null = fopen("/dev/null", "w");
    int rc = (int)morphl_vm_run_file(exe_path.c_str(), 1, nullptr, nullptr,
                                     dev_null ? dev_null : stderr);
    if (dev_null) fclose(dev_null);
    std::remove(obj_path.c_str());
    std::remove(exe_path.c_str());
    return rc;
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

    MorphlBackendContext backend_ctx = {};
    backend_ctx.tree         = root;
    backend_ctx.out_file     = out_path.c_str();
    backend_ctx.type_context = parser_ctx.type_context;

    int result = -1;
    if (morphl_register_backend(MORPHL_BACKEND_TYPE_VM) && morphl_compile(&backend_ctx)) {
        FILE* dev_null = fopen("/dev/null", "w");
        /* pass argc=1 (simulate "program" as only arg), no argv/envp for unit tests */
        result = (int)morphl_vm_run_file(out_path.c_str(), 1, nullptr, nullptr,
                                         dev_null ? dev_null : stderr);
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

static void test_e2e_alias_scalar_substitution() {
    int rc = compile_and_run(
        "$alias one 1;\n"
        "$decl result $add one 2;\n"
        "$exit result;\n"
    );
    assert(rc == 3);
    printf("PASS test_e2e_alias_scalar_substitution\n");
}

static void test_e2e_alias_func_duplicate_by_use() {
    int rc = compile_and_run(
        "$alias inc $func ($decl x 0) {\n"
        "  $ret $add x 1;\n"
        "};\n"
        "$decl a $call inc 1;\n"
        "$decl b $call inc 2;\n"
        "$exit $add a b;\n"
    );
    assert(rc == 5);
    printf("PASS test_e2e_alias_func_duplicate_by_use\n");
}

static void test_e2e_static_mutable_counter() {
    int rc = compile_and_run(
        "$decl counter $static $mut 0;\n"
        "$set counter 41;\n"
        "$exit $add counter 1;\n"
    );
    assert(rc == 42);
    printf("PASS test_e2e_static_mutable_counter\n");
}

static void test_e2e_function_local_static_persists() {
    int rc = compile_and_run(
        "$decl step $func ($decl unused 0) {\n"
        "  $decl counter $static $mut 0;\n"
        "  $set counter $add counter 1;\n"
        "  $ret counter;\n"
        "};\n"
        "$decl a $call step 0;\n"
        "$decl b $call step 0;\n"
        "$exit b;\n"
    );
    assert(rc == 2);
    printf("PASS test_e2e_function_local_static_persists\n");
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

static void test_e2e_exit_requires_arg() {
    int rc = compile_and_run("$exit;\n");
    assert(rc == -1);
    printf("PASS test_e2e_exit_requires_arg\n");
}

static void test_e2e_main_is_not_autocalled() {
    int rc = compile_and_run(
        "$decl main $func () {\n"
        "    $ret 7;\n"
        "};\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_main_is_not_autocalled\n");
}

static void test_e2e_main_is_ordinary_binding() {
    int rc = compile_and_run(
        "$decl main $func ($decl argc 0) {\n"
        "    $ret argc;\n"
        "};\n"
        "$exit $call main 9;\n"
    );
    assert(rc == 9);
    printf("PASS test_e2e_main_is_ordinary_binding\n");
}

// ── $while / $and / $or / $not / $break / $continue ─────────────────────────

static void test_e2e_while_basic() {
    int rc = compile_and_run(
        "$decl i $mut 0;\n"
        "$while $lt i 5 { $set i $add i 1; };\n"
        "$exit i;\n"
    );
    assert(rc == 5);
    printf("PASS test_e2e_while_basic\n");
}

static void test_e2e_while_no_iter() {
    int rc = compile_and_run(
        "$decl x $mut 99;\n"
        "$while $lt 5 3 { $set x 0; };\n"
        "$exit x;\n"
    );
    assert(rc == 99);
    printf("PASS test_e2e_while_no_iter\n");
}

static void test_e2e_if_int_condition() {
    int rc = compile_and_run(
        "$decl value $if 1 9 3;\n"
        "$exit value;\n"
    );
    assert(rc == 9);
    printf("PASS test_e2e_if_int_condition\n");
}

static void test_e2e_while_int_condition() {
    int rc = compile_and_run(
        "$decl i $mut 3;\n"
        "$while i { $set i $sub i 1; };\n"
        "$exit i;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_while_int_condition\n");
}

static void test_e2e_not() {
    assert(compile_and_run("$exit $not 1;") == 0);
    assert(compile_and_run("$exit $not 0;") == 1);
    printf("PASS test_e2e_not\n");
}

static void test_e2e_and() {
    assert(compile_and_run("$exit $and 1 1;") == 1);
    assert(compile_and_run("$exit $and 1 0;") == 0);
    assert(compile_and_run("$exit $and 0 1;") == 0);
    printf("PASS test_e2e_and\n");
}

static void test_e2e_or() {
    assert(compile_and_run("$exit $or 0 0;") == 0);
    assert(compile_and_run("$exit $or 0 1;") == 1);
    assert(compile_and_run("$exit $or 1 0;") == 1);
    printf("PASS test_e2e_or\n");
}

static void test_e2e_break() {
    int rc = compile_and_run(
        "$decl i $mut 0;\n"
        "$while 1 { $set i $add i 1; $if $eq i 3 { $break; }; };\n"
        "$exit i;\n"
    );
    assert(rc == 3);
    printf("PASS test_e2e_break\n");
}

static void test_e2e_continue() {
    /* sum even numbers from 1..6: 2+4+6 = 12 */
    int rc = compile_and_run(
        "$decl i $mut 0;\n"
        "$decl s $mut 0;\n"
        "$while $lt i 6 {\n"
        "    $set i $add i 1;\n"
        "    $if $eq $mod i 2 1 { $continue; };\n"
        "    $set s $add s i;\n"
        "};\n"
        "$exit s;\n"
    );
    assert(rc == 12);
    printf("PASS test_e2e_continue\n");
}

/* Step 4 — $break/$continue scope unwinding:
 * Verify that $break inside a nested {} block properly emits LEAVE before JMP,
 * so the stack is cleaned up and execution continues after the loop. */
static void test_e2e_break_in_nested_block() {
    /* i increments to 1, then { $break; } fires — should exit with i==1 */
    int rc = compile_and_run(
        "$decl i $mut 0;\n"
        "$while $lt i 10 {\n"
        "    $set i $add i 1;\n"
        "    { $break; };\n"
        "};\n"
        "$exit i;\n"
    );
    assert(rc == 1);
    printf("PASS test_e2e_break_in_nested_block\n");
}

/* Step 4 — $continue scope unwinding:
 * $continue inside a nested {} block emits LEAVE before JMP to loop top. */
static void test_e2e_continue_in_nested_block() {
    /* i counts up to 5; { $continue; } skips $set s, so s stays 0 */
    int rc = compile_and_run(
        "$decl i $mut 0;\n"
        "$decl s $mut 0;\n"
        "$while $lt i 5 {\n"
        "    $set i $add i 1;\n"
        "    { $continue; };\n"
        "    $set s $add s i;\n"
        "};\n"
        "$exit s;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_continue_in_nested_block\n");
}

/* Step 7 — string: declare and compare (no $exit on bool — use $if wrapper) */
static void test_e2e_string_assign() {
    /* String literal compiles; $exit 0 just checks no crash */
    int rc = compile_and_run(
        "$decl s \"hello\";\n"
        "$exit 0;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_string_assign\n");
}

static void test_e2e_string_eq() {
    /* $eq on equal strings → 1; on different strings → 0 */
    int rc1 = compile_and_run(
        "$decl s \"hello\";\n"
        "$decl result $if $eq s \"hello\" 1 0;\n"
        "$exit result;\n"
    );
    assert(rc1 == 1);

    int rc2 = compile_and_run(
        "$decl s \"hello\";\n"
        "$decl result $if $eq s \"world\" 1 0;\n"
        "$exit result;\n"
    );
    assert(rc2 == 0);
    printf("PASS test_e2e_string_eq\n");
}

static void test_e2e_string_neq() {
    /* $neq on different strings → 1; on equal strings → 0 */
    int rc1 = compile_and_run(
        "$decl s \"hello\";\n"
        "$decl result $if $neq s \"world\" 1 0;\n"
        "$exit result;\n"
    );
    assert(rc1 == 1);

    int rc2 = compile_and_run(
        "$decl s \"hello\";\n"
        "$decl result $if $neq s \"hello\" 1 0;\n"
        "$exit result;\n"
    );
    assert(rc2 == 0);
    printf("PASS test_e2e_string_neq\n");
}

static void test_e2e_string_mutation() {
    /* $set a string variable then compare */
    int rc = compile_and_run(
        "$decl s $mut \"hello\";\n"
        "$set s \"world\";\n"
        "$decl result $if $eq s \"world\" 1 0;\n"
        "$exit result;\n"
    );
    assert(rc == 1);
    printf("PASS test_e2e_string_mutation\n");
}

/* Step 5 — $import VM backend:
 * Verify that the VM emitter handles $import without crashing ("unhandled builtin").
 * The imported module's AST is emitted inline. */
static void test_e2e_import_basic() {
    std::string mod_path = write_temp_source(
        "$decl modval 42;\n"
        "$decl other 1;\n"
    );

    /* Main file imports the module; $exit 0 verifies no crash */
    std::string main_src =
        std::string("$decl mod $import \"") + mod_path + "\";\n"
        "$exit 0;\n";

    int rc = compile_and_run(main_src.c_str());
    std::remove(mod_path.c_str());
    assert(rc == 0);
    printf("PASS test_e2e_import_basic\n");
}

static void test_e2e_import_single_decl_module() {
    std::string mod_path = write_temp_source(
        "$decl modval 42;\n"
    );

    std::string main_src =
        std::string("$decl mod $import \"") + mod_path + "\";\n"
        "$decl value $member mod modval;\n"
        "$exit value;\n";

    int rc = compile_and_run(main_src.c_str());
    std::remove(mod_path.c_str());
    assert(rc == 42);
    printf("PASS test_e2e_import_single_decl_module\n");
}

static void test_e2e_import_nested_member_chain() {
    std::string mod_path = write_temp_source(
        "$decl x {\n"
        "  $decl a 42;\n"
        "};\n"
    );

    std::string main_src =
        std::string("$decl mod $import \"") + mod_path + "\";\n"
        "$exit $member $member mod x a;\n";

    int rc = compile_and_run(main_src.c_str());
    std::remove(mod_path.c_str());
    assert(rc == 42);
    printf("PASS test_e2e_import_nested_member_chain\n");
}

static void test_e2e_vm_object_metadata() {
    std::string dep_path = write_temp_source(
        "$decl dep_value 7;\n"
    );
    std::string obj_path = temp_path(".mplo");
    std::string src =
        std::string("$decl dep $import \"") + dep_path + "\";\n" +
        "$decl foo 42;\n" +
        "$decl bar $func () 0;\n";

    assert(compile_source_to_artifact(src.c_str(), obj_path));

    TestVmObjectFile obj = {};
    assert(parse_vm_object_file(obj_path, &obj));
    assert(obj.artifact_kind == MORPHL_VM_ARTIFACT_OBJECT);
    assert(obj.module_init_func_idx == 0);
    assert(!obj.code.empty());
    assert(obj.code.back() == VM_OP_RET);
    assert(obj.imports.size() == 1);
    assert(obj.imports[0].path == dep_path);
    assert(obj.imports[0].required_funcs.empty());

    bool saw_dep = false;
    bool saw_foo = false;
    bool saw_bar = false;
    uint32_t bar_symbol_value = UINT32_MAX;
    for (const auto& ex : obj.exports) {
        if (ex.name == "dep") saw_dep = true;
        if (ex.name == "foo" && ex.kind == MORPHL_VM_EXPORT_VALUE) saw_foo = true;
        if (ex.name == "bar" && ex.kind == MORPHL_VM_EXPORT_FUNCTION) {
            saw_bar = true;
            bar_symbol_value = ex.symbol_value;
        }
    }
    assert(saw_dep);
    assert(saw_foo);
    assert(saw_bar);
    assert(bar_symbol_value != UINT32_MAX);
    assert(obj.relocation_count >= 1);
    bool saw_func_i64_reloc = false;
    for (const auto& reloc : obj.relocations) {
        if (reloc.kind == MORPHL_VM_RELOC_FUNC_INDEX_I64) {
            saw_func_i64_reloc = true;
        }
    }
    assert(saw_func_i64_reloc);

    std::remove(dep_path.c_str());
    std::remove(obj_path.c_str());
    printf("PASS test_e2e_vm_object_metadata\n");
}

static void test_e2e_vm_link_single_object() {
    int rc = compile_link_and_run(
        "$decl x 40;\n"
        "$exit $add x 2;\n"
    );
    assert(rc == 42);
    printf("PASS test_e2e_vm_link_single_object\n");
}

static void test_e2e_vm_link_accepts_function_relocs() {
    std::string obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    assert(compile_source_to_artifact(
        "$decl foo $func () 40;\n"
        "$decl x $call foo ();\n"
        "$exit $add x 2;\n",
        obj_path));
    TestVmObjectFile obj = {};
    assert(parse_vm_object_file(obj_path, &obj));
    bool saw_i64_reloc = false;
    for (const auto& reloc : obj.relocations) {
        if (reloc.kind == MORPHL_VM_RELOC_FUNC_INDEX_I64) saw_i64_reloc = true;
    }
    assert(obj.relocation_count >= 1);
    assert(saw_i64_reloc);
    const char* inputs[] = {obj_path.c_str()};
    assert(morphl_vm_link_files(exe_path.c_str(), inputs, 1, stderr));
    std::remove(obj_path.c_str());
    std::remove(exe_path.c_str());
    printf("PASS test_e2e_vm_link_accepts_function_relocs\n");
}

static void test_e2e_vm_link_dedups_duplicate_object_inputs() {
    std::string obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    assert(compile_source_to_artifact(
        "$decl x 20;\n"
        "$exit $mul x 2;\n",
        obj_path));
    const char* inputs[] = {obj_path.c_str(), obj_path.c_str()};
    assert(morphl_vm_link_files(exe_path.c_str(), inputs, 2, stderr));
    FILE* dev_null = fopen("/dev/null", "w");
    int rc = (int)morphl_vm_run_file(exe_path.c_str(), 1, nullptr, nullptr,
                                     dev_null ? dev_null : stderr);
    if (dev_null) fclose(dev_null);
    assert(rc == 40);
    std::remove(obj_path.c_str());
    std::remove(exe_path.c_str());
    printf("PASS test_e2e_vm_link_dedups_duplicate_object_inputs\n");
}

static void test_e2e_vm_link_rejects_executable_input() {
    std::string exe_input_path = temp_path(".mbc");
    std::string exe_output_path = temp_path(".mplx");
    assert(compile_source_to_artifact(
        "$exit 1;\n",
        exe_input_path));
    FILE* dev_null = fopen("/dev/null", "w");
    const char* inputs[] = {exe_input_path.c_str()};
    assert(!morphl_vm_link_files(exe_output_path.c_str(), inputs, 1,
                                 dev_null ? dev_null : stderr));
    if (dev_null) fclose(dev_null);
    std::remove(exe_input_path.c_str());
    std::remove(exe_output_path.c_str());
    printf("PASS test_e2e_vm_link_rejects_executable_input\n");
}

static void test_e2e_vm_link_accepts_dependency_object() {
    std::string dep_src_path = write_temp_source(
        "$decl dep_func $func () {\n"
        "  $ret 11;\n"
        "};\n"
    );
    std::string dep_obj_path = temp_path(".mplo");
    std::string root_obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    std::string root_src =
        std::string("$decl dep $import \"") + dep_src_path + "\";\n" +
        "$decl f $member dep dep_func;\n" +
        "$exit $add $call f () 2;\n";
    assert(compile_source_to_artifact(
        root_src.c_str(),
        root_obj_path));
    {
        std::ofstream f(dep_src_path, std::ios::trunc);
        assert(f.is_open());
        f << "$decl dep_func $func () {\n"
             "  $ret 40;\n"
             "};\n";
    }
    assert(compile_file_to_artifact(dep_src_path, dep_obj_path));
    FILE* dev_null = fopen("/dev/null", "w");
    const char* inputs[] = {root_obj_path.c_str(), dep_obj_path.c_str()};
    assert(morphl_vm_link_files(exe_path.c_str(), inputs, 2,
                                dev_null ? dev_null : stderr));
    TestVmObjectFile root_obj = {};
    TestVmObjectFile dep_obj = {};
    TestVmObjectFile linked_exe = {};
    assert(parse_vm_object_file(root_obj_path, &root_obj));
    assert(parse_vm_object_file(dep_obj_path, &dep_obj));
    assert(root_obj.imports.size() == 1);
    assert(root_obj.imports[0].path == dep_src_path);
    bool saw_dep_func_requirement = false;
    for (const auto& name : root_obj.imports[0].required_funcs) {
        if (name == "dep_func") saw_dep_func_requirement = true;
    }
    assert(saw_dep_func_requirement);
    bool saw_external_func_i64 = false;
    for (const auto& reloc : root_obj.relocations) {
        if (reloc.kind == MORPHL_VM_RELOC_EXTERN_FUNC_I64 &&
            reloc.module_path == dep_src_path &&
            reloc.symbol_name == "dep_func") {
            saw_external_func_i64 = true;
        }
    }
    assert(saw_external_func_i64);
    assert(parse_vm_binary_file(exe_path, &linked_exe));
    assert(linked_exe.artifact_kind == MORPHL_VM_ARTIFACT_EXECUTABLE);
    assert(linked_exe.func_count == root_obj.func_count + dep_obj.func_count + 1);
    assert(linked_exe.code.size() > root_obj.code.size());
    int rc = (int)morphl_vm_run_file(exe_path.c_str(), 1, nullptr, nullptr,
                                     dev_null ? dev_null : stderr);
    if (dev_null) fclose(dev_null);
    assert(rc == 42);
    std::remove(dep_src_path.c_str());
    std::remove(dep_obj_path.c_str());
    std::remove(root_obj_path.c_str());
    std::remove(exe_path.c_str());
    printf("PASS test_e2e_vm_link_accepts_dependency_object\n");
}

static void test_e2e_vm_link_relocates_global_layout() {
    std::string dep_src_path = write_temp_source(
        "$decl dep_static $static 5;\n"
        "$decl dep_func $func () {\n"
        "  $ret 40;\n"
        "};\n"
    );
    std::string root_obj_path = temp_path(".mplo");
    std::string dep_obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    std::string root_src =
        std::string("$decl root_static $static 7;\n") +
        "$decl dep $import \"" + dep_src_path + "\";\n" +
        "$exit $add $call $member dep dep_func () root_static;\n";
    assert(compile_source_to_artifact(root_src.c_str(), root_obj_path));
    assert(compile_file_to_artifact(dep_src_path, dep_obj_path));

    TestVmObjectFile root_obj = {};
    TestVmObjectFile dep_obj = {};
    TestVmObjectFile linked_exe = {};
    assert(parse_vm_object_file(root_obj_path, &root_obj));
    assert(parse_vm_object_file(dep_obj_path, &dep_obj));
    assert(root_obj.global_frame_size > 32);
    assert(dep_obj.global_frame_size > 32);

    const TestVmObjectRelocation* root_global_reloc = nullptr;
    for (const auto& reloc : root_obj.relocations) {
        if (!root_global_reloc &&
            (reloc.kind == MORPHL_VM_RELOC_GLOBAL_DATA_I32 ||
             reloc.kind == MORPHL_VM_RELOC_GLOBAL_DATA_I64)) {
            root_global_reloc = &reloc;
        }
    }
    assert(root_global_reloc != nullptr);

    FILE* dev_null = fopen("/dev/null", "w");
    const char* inputs[] = {root_obj_path.c_str(), dep_obj_path.c_str()};
    assert(morphl_vm_link_files(exe_path.c_str(), inputs, 2,
                                dev_null ? dev_null : stderr));
    assert(parse_vm_binary_file(exe_path, &linked_exe));

    uint32_t dep_extra = dep_obj.global_frame_size - 32;
    uint32_t expected_global_frame =
        32 + (root_obj.global_frame_size - 32) + dep_extra + 16;
    assert(linked_exe.global_frame_size == expected_global_frame);

    size_t root_code_base = dep_obj.code.size();
    if (root_global_reloc->kind == MORPHL_VM_RELOC_GLOBAL_DATA_I32) {
        uint32_t orig = read_u32_le_at(root_obj.code.data(),
                                       root_global_reloc->code_offset);
        uint32_t patched = read_u32_le_at(linked_exe.code.data(),
                                          root_code_base +
                                              root_global_reloc->code_offset);
        assert(patched == orig + dep_extra);
    } else {
        uint64_t orig = read_u64_le_at(root_obj.code.data(),
                                       root_global_reloc->code_offset);
        uint64_t patched = read_u64_le_at(linked_exe.code.data(),
                                          root_code_base +
                                              root_global_reloc->code_offset);
        assert(patched == orig + dep_extra);
    }

    int rc = (int)morphl_vm_run_file(exe_path.c_str(), 1, nullptr, nullptr,
                                     dev_null ? dev_null : stderr);
    if (dev_null) fclose(dev_null);
    assert(rc == 47);
    std::remove(dep_src_path.c_str());
    std::remove(dep_obj_path.c_str());
    std::remove(root_obj_path.c_str());
    std::remove(exe_path.c_str());
    printf("PASS test_e2e_vm_link_relocates_global_layout\n");
}

static void test_e2e_vm_link_initializes_modules_once() {
    vm_link_init_counter_g = 0;
    assert(morphl_register_native("vm_link_tick", native_vm_link_tick));
    std::string dep_src_path = write_temp_source(
        "$decl tick $extern \"vm_link_tick\" $func () 0;\n"
        "$decl touched $call tick ();\n"
    );
    std::string root_obj_path = temp_path(".mplo");
    std::string dep_obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    std::string root_src =
        std::string("$decl dep_a $import \"") + dep_src_path + "\";\n" +
        "$decl dep_b $import \"" + dep_src_path + "\";\n" +
        "$exit 0;\n";

    assert(compile_source_to_artifact(root_src.c_str(), root_obj_path));
    assert(compile_file_to_artifact(dep_src_path, dep_obj_path));

    TestVmObjectFile root_obj = {};
    TestVmObjectFile dep_obj = {};
    TestVmObjectFile linked_exe = {};
    assert(parse_vm_object_file(root_obj_path, &root_obj));
    assert(parse_vm_object_file(dep_obj_path, &dep_obj));
    assert(root_obj.imports.size() == 2);
    assert(root_obj.imports[0].binding_name == "dep_a");
    assert(root_obj.imports[0].path == dep_src_path);
    assert(root_obj.imports[1].binding_name == "dep_b");
    assert(root_obj.imports[1].path == dep_src_path);

    FILE* dev_null = fopen("/dev/null", "w");
    const char* inputs[] = {
        root_obj_path.c_str(), dep_obj_path.c_str()
    };
    assert(morphl_vm_link_files(exe_path.c_str(), inputs, 2,
                                dev_null ? dev_null : stderr));
    assert(parse_vm_binary_file(exe_path, &linked_exe));
    int rc = (int)morphl_vm_run_file(exe_path.c_str(), 1, nullptr, nullptr,
                                     dev_null ? dev_null : stderr);
    if (dev_null) fclose(dev_null);
    assert(rc == 0);
    assert(vm_link_init_counter_g == 1);
    std::remove(dep_src_path.c_str());
    std::remove(dep_obj_path.c_str());
    std::remove(root_obj_path.c_str());
    std::remove(exe_path.c_str());
    printf("PASS test_e2e_vm_link_initializes_modules_once\n");
}

static void test_e2e_vm_link_shares_imported_module_statics() {
    std::string dep_src_path = write_temp_source(
        "$decl cached $static $mut 7;\n"
    );
    std::string root_obj_path = temp_path(".mplo");
    std::string dep_obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    std::string root_src =
        std::string("$decl dep_a $import \"") + dep_src_path + "\";\n" +
        "$decl dep_b $import \"" + dep_src_path + "\";\n" +
        "$decl before $member $member dep_a $$statics cached;\n" +
        "$set $member $member dep_b $$statics cached $add before 5;\n" +
        "$decl after_alias $member $member dep_a $$statics cached;\n" +
        "$decl after_global $member $member $member $member $global $modules dep_b $$statics cached;\n" +
        "$exit $add after_alias after_global;\n";

    assert(compile_source_to_artifact(root_src.c_str(), root_obj_path));
    assert(compile_file_to_artifact(dep_src_path, dep_obj_path));

    TestVmObjectFile root_obj = {};
    assert(parse_vm_object_file(root_obj_path, &root_obj));
    assert(root_obj.imports.size() == 2);
    assert(root_obj.imports[0].binding_name == "dep_a");
    assert(root_obj.imports[1].binding_name == "dep_b");
    assert(root_obj.imports[0].path == dep_src_path);
    assert(root_obj.imports[1].path == dep_src_path);
    assert(root_obj.imports[0].global_slot != root_obj.imports[1].global_slot);

    bool saw_external_data_reloc = false;
    for (const auto& reloc : root_obj.relocations) {
        if (reloc.kind == MORPHL_VM_RELOC_EXTERN_DATA_I32 &&
            reloc.module_path == dep_src_path &&
            reloc.symbol_name == "cached") {
            saw_external_data_reloc = true;
        }
    }
    assert(saw_external_data_reloc);

    FILE* dev_null = fopen("/dev/null", "w");
    const char* inputs[] = {root_obj_path.c_str(), dep_obj_path.c_str()};
    assert(morphl_vm_link_files(exe_path.c_str(), inputs, 2,
                                dev_null ? dev_null : stderr));
    int rc = (int)morphl_vm_run_file(exe_path.c_str(), 1, nullptr, nullptr,
                                     dev_null ? dev_null : stderr);
    if (dev_null) fclose(dev_null);
    assert(rc == 24);
    std::remove(dep_src_path.c_str());
    std::remove(root_obj_path.c_str());
    std::remove(dep_obj_path.c_str());
    std::remove(exe_path.c_str());
    printf("PASS test_e2e_vm_link_shares_imported_module_statics\n");
}

static void test_e2e_vm_link_deduplicates_module_slot_offsets() {
    std::string dep_src_path = write_temp_source(
        "$decl value 9;\n"
    );
    std::string root_obj_path = temp_path(".mplo");
    std::string dep_obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    std::string root_src =
        std::string("$decl dep_a $import \"") + dep_src_path + "\";\n" +
        "$decl dep_b $import \"" + dep_src_path + "\";\n" +
        "$decl via_a $member dep_a value;\n" +
        "$decl via_b $member dep_b value;\n" +
        "$exit 0;\n";

    assert(compile_source_to_artifact(root_src.c_str(), root_obj_path));
    assert(compile_file_to_artifact(dep_src_path, dep_obj_path));

    TestVmObjectFile root_obj = {};
    TestVmObjectFile dep_obj = {};
    TestVmObjectFile linked_exe = {};
    assert(parse_vm_object_file(root_obj_path, &root_obj));
    assert(parse_vm_object_file(dep_obj_path, &dep_obj));

    std::vector<uint32_t> module_slot_relocs;
    for (const auto& reloc : root_obj.relocations) {
      if (reloc.kind == MORPHL_VM_RELOC_MODULE_SLOT_I32 &&
          reloc.module_path == dep_src_path) {
        module_slot_relocs.push_back(reloc.code_offset);
      }
    }
    assert(module_slot_relocs.size() >= 2);

    FILE* dev_null = fopen("/dev/null", "w");
    const char* inputs[] = {root_obj_path.c_str(), dep_obj_path.c_str()};
    assert(morphl_vm_link_files(exe_path.c_str(), inputs, 2,
                                dev_null ? dev_null : stderr));
    assert(parse_vm_binary_file(exe_path, &linked_exe));

    uint32_t root_code_base = (uint32_t)dep_obj.code.size();
    uint32_t canonical_slot = UINT32_MAX;
    for (uint32_t code_off : module_slot_relocs) {
      uint32_t patched =
          read_u32_le_at(linked_exe.code.data(), root_code_base + code_off);
      if (canonical_slot == UINT32_MAX) canonical_slot = patched;
      assert(patched == canonical_slot);
    }

    int rc = (int)morphl_vm_run_file(exe_path.c_str(), 1, nullptr, nullptr,
                                     dev_null ? dev_null : stderr);
    if (dev_null) fclose(dev_null);
    assert(rc == 0);
    std::remove(dep_src_path.c_str());
    std::remove(root_obj_path.c_str());
    std::remove(dep_obj_path.c_str());
    std::remove(exe_path.c_str());
    printf("PASS test_e2e_vm_link_deduplicates_module_slot_offsets\n");
}

static void test_e2e_vm_link_rejects_missing_dependency_function_export() {
    std::string dep_src_path = write_temp_source(
        "$decl dep_func $func () {\n"
        "  $ret 11;\n"
        "};\n"
    );
    std::string root_obj_path = temp_path(".mplo");
    std::string dep_obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    std::string root_src =
        std::string("$decl dep $import \"") + dep_src_path + "\";\n" +
        "$exit $call $member dep dep_func ();\n";
    assert(compile_source_to_artifact(root_src.c_str(), root_obj_path));

    {
        std::ofstream f(dep_src_path, std::ios::trunc);
        assert(f.is_open());
        f << "$decl dep_value 11;\n";
    }
    assert(compile_file_to_artifact(dep_src_path, dep_obj_path));

    FILE* dev_null = fopen("/dev/null", "w");
    const char* inputs[] = {root_obj_path.c_str(), dep_obj_path.c_str()};
    assert(!morphl_vm_link_files(exe_path.c_str(), inputs, 2,
                                 dev_null ? dev_null : stderr));
    if (dev_null) fclose(dev_null);
    std::remove(dep_src_path.c_str());
    std::remove(root_obj_path.c_str());
    std::remove(dep_obj_path.c_str());
    std::remove(exe_path.c_str());
    printf("PASS test_e2e_vm_link_rejects_missing_dependency_function_export\n");
}

static void test_e2e_vm_link_accepts_direct_imported_function_call() {
    std::string dep_src_path = write_temp_source(
        "$decl dep_func $func () {\n"
        "  $ret 9;\n"
        "};\n"
    );
    std::string root_obj_path = temp_path(".mplo");
    std::string dep_obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    std::string root_src =
        std::string("$decl dep $import \"") + dep_src_path + "\";\n" +
        "$exit $add $call $member dep dep_func () 2;\n";
    assert(compile_source_to_artifact(root_src.c_str(), root_obj_path));
    {
        std::ofstream f(dep_src_path, std::ios::trunc);
        assert(f.is_open());
        f << "$decl dep_func $func () {\n"
             "  $ret 40;\n"
             "};\n";
    }
    assert(compile_file_to_artifact(dep_src_path, dep_obj_path));

    TestVmObjectFile root_obj = {};
    assert(parse_vm_object_file(root_obj_path, &root_obj));
    bool saw_external_func_u32 = false;
    for (const auto& reloc : root_obj.relocations) {
        if (reloc.kind == MORPHL_VM_RELOC_EXTERN_FUNC_U32 &&
            reloc.module_path == dep_src_path &&
            reloc.symbol_name == "dep_func") {
            saw_external_func_u32 = true;
        }
    }
    assert(saw_external_func_u32);

    FILE* dev_null = fopen("/dev/null", "w");
    const char* inputs[] = {root_obj_path.c_str(), dep_obj_path.c_str()};
    assert(morphl_vm_link_files(exe_path.c_str(), inputs, 2,
                                dev_null ? dev_null : stderr));
    int rc = (int)morphl_vm_run_file(exe_path.c_str(), 1, nullptr, nullptr,
                                     dev_null ? dev_null : stderr);
    if (dev_null) fclose(dev_null);
    assert(rc == 42);
    std::remove(dep_src_path.c_str());
    std::remove(root_obj_path.c_str());
    std::remove(dep_obj_path.c_str());
    std::remove(exe_path.c_str());
    printf("PASS test_e2e_vm_link_accepts_direct_imported_function_call\n");
}

static void test_e2e_vm_link_rejects_missing_dependency_object() {
    std::string dep_src_path = write_temp_source(
        "$decl dep_value 11;\n"
    );
    std::string root_obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    std::string root_src =
        std::string("$decl dep $import \"") + dep_src_path + "\";\n" +
        "$exit $member dep dep_value;\n";
    assert(compile_source_to_artifact(
        root_src.c_str(),
        root_obj_path));
    FILE* dev_null = fopen("/dev/null", "w");
    const char* inputs[] = {root_obj_path.c_str()};
    assert(!morphl_vm_link_files(exe_path.c_str(), inputs, 1,
                                 dev_null ? dev_null : stderr));
    if (dev_null) fclose(dev_null);
    std::remove(dep_src_path.c_str());
    std::remove(root_obj_path.c_str());
    std::remove(exe_path.c_str());
    printf("PASS test_e2e_vm_link_rejects_missing_dependency_object\n");
}

static void test_e2e_vm_link_rejects_unrelated_object() {
    std::string dep_src_path = write_temp_source(
        "$decl dep_value 7;\n"
    );
    std::string dep_obj_path = temp_path(".mplo");
    std::string root_obj_path = temp_path(".mplo");
    std::string unrelated_obj_path = temp_path(".mplo");
    std::string exe_path = temp_path(".mplx");
    assert(compile_file_to_artifact(dep_src_path, dep_obj_path));
    std::string root_src =
        std::string("$decl dep $import \"") + dep_src_path + "\";\n" +
        "$exit $member dep dep_value;\n";
    assert(compile_source_to_artifact(
        root_src.c_str(),
        root_obj_path));
    assert(compile_source_to_artifact(
        "$decl unrelated 9;\n"
        "$exit unrelated;\n",
        unrelated_obj_path));
    FILE* dev_null = fopen("/dev/null", "w");
    const char* inputs[] = {
        root_obj_path.c_str(), dep_obj_path.c_str(), unrelated_obj_path.c_str()
    };
    assert(!morphl_vm_link_files(exe_path.c_str(), inputs, 3,
                                 dev_null ? dev_null : stderr));
    if (dev_null) fclose(dev_null);
    std::remove(dep_src_path.c_str());
    std::remove(dep_obj_path.c_str());
    std::remove(root_obj_path.c_str());
    std::remove(unrelated_obj_path.c_str());
    std::remove(exe_path.c_str());
    printf("PASS test_e2e_vm_link_rejects_unrelated_object\n");
}

/* compile_and_run variant that forwards a custom argc to $global.$argc */
static int compile_and_run_argc(const char* source, int vm_argc) {
    std::string src_path = write_temp_source(source);
    std::string out_path = temp_path(".mbc");

    InternTable* interns = interns_new();
    if (!interns) return -1;
    if (!operator_registry_init(interns)) { interns_free(interns); return -1; }

    Arena arena;
    arena_init(&arena, 65536);

    ScopedParserContext parser_ctx;
    if (!scoped_parser_init(&parser_ctx, interns, &arena, src_path.c_str())) {
        arena_free(&arena); interns_free(interns); return -1;
    }

    char* source_buffer = NULL;
    size_t source_len = 0;
    if (!morphl_file_read_all(src_path.c_str(), &source_buffer, &source_len)) {
        scoped_parser_free(&parser_ctx); arena_free(&arena); interns_free(interns); return -1;
    }

    struct token* tokens = NULL;
    size_t token_count = 0;
    if (!lexer_tokenize(src_path.c_str(), str_from(source_buffer, source_len),
                        interns, &tokens, &token_count)) {
        free(source_buffer); scoped_parser_free(&parser_ctx);
        arena_free(&arena); interns_free(interns); return -1;
    }

    AstNode* root = NULL;
    bool accepted = scoped_parse_ast(&parser_ctx, tokens, token_count, &root);
    if (!accepted) {
        free(tokens); free(source_buffer); scoped_parser_free(&parser_ctx);
        arena_free(&arena); interns_free(interns); return -1;
    }

    MorphlBackendContext backend_ctx = {};
    backend_ctx.tree         = root;
    backend_ctx.out_file     = out_path.c_str();
    backend_ctx.type_context = parser_ctx.type_context;

    int result = -1;
    if (morphl_register_backend(MORPHL_BACKEND_TYPE_VM) && morphl_compile(&backend_ctx)) {
        FILE* dev_null = fopen("/dev/null", "w");
        result = (int)morphl_vm_run_file(out_path.c_str(), vm_argc, nullptr, nullptr,
                                          dev_null ? dev_null : stderr);
        if (dev_null) fclose(dev_null);
    }

    ast_free(root);
    free(tokens); free(source_buffer);
    scoped_parser_free(&parser_ctx);
    arena_free(&arena); interns_free(interns);
    std::remove(src_path.c_str()); std::remove(out_path.c_str());
    return result;
}

static void test_e2e_overload_arithmetic_resolution() {
    int rc = compile_and_run(
        "$decl x $overload 41 1.0;\n"
        "$exit $add x 1;\n");
    assert(rc == 42);
    printf("PASS test_e2e_overload_arithmetic_resolution\n");
}

static void test_e2e_overload_whole_object_assignment() {
    int rc = compile_and_run(
        "$decl x $mut $overload 0 0.0;\n"
        "$set x $overload 41 41.0;\n"
        "$exit $add x 1;\n");
    assert(rc == 42);
    printf("PASS test_e2e_overload_whole_object_assignment\n");
}

/* $global.$argc — program receives argc via the global frame */
static void test_e2e_global_argc() {
    /* Pass vm_argc=3; program exits with that value.
     * Two statements so scoped_parse_ast wraps the root in AST_FILE. */
    int rc = compile_and_run_argc(
        "$decl a $member $global $argc;\n"
        "$exit a;\n",
        3
    );
    assert(rc == 3);
    printf("PASS test_e2e_global_argc\n");
}

/* $global.$entry — should be non-zero (valid stack address) */
static void test_e2e_global_entry() {
    int rc = compile_and_run(
        "$decl e $member $global $entry;\n"
        "$decl result $if $gt e 0 1 0;\n"
        "$exit result;\n"
    );
    assert(rc == 1);
    printf("PASS test_e2e_global_entry\n");
}

/* $global.$modules — after $import, slot must be non-zero */
static void test_e2e_global_modules_slot() {
    std::string mod_path = write_temp_source(
        "$decl x 42;\n"
        "$decl y 1;\n"
    );
    std::string main_src =
        std::string("$decl mod $import \"") + mod_path + "\";\n"
        "$decl value $member $member $member $global $modules mod x;\n"
        "$exit value;\n";

    int rc = compile_and_run(main_src.c_str());
    std::remove(mod_path.c_str());
    assert(rc == 42);
    printf("PASS test_e2e_global_modules_slot\n");
}

static void test_e2e_file_statics_access() {
    int rc = compile_and_run(
        "$decl counter $static $mut 41;\n"
        "$set $member $member $file $$statics counter 42;\n"
        "$exit $member $member $file $$statics counter;\n"
    );
    assert(rc == 42);
    printf("PASS test_e2e_file_statics_access\n");
}

static void test_e2e_global_source_statics_access() {
    int rc = compile_and_run(
        "$decl counter $static $mut 5;\n"
        "$set $member $member $member $global $source $$statics counter 9;\n"
        "$exit $member $member $member $global $source $$statics counter;\n"
    );
    assert(rc == 9);
    printf("PASS test_e2e_global_source_statics_access\n");
}

static void test_e2e_module_statics_access() {
    std::string mod_path = write_temp_source(
        "$decl cached $static $mut 7;\n"
        "$decl value 1;\n"
    );

    std::string main_src =
        std::string("$decl mod $import \"") + mod_path + "\";\n"
        "$decl before $member $member mod $$statics cached;\n"
        "$set $member $member mod $$statics cached $add before 1;\n"
        "$decl after $member $member mod $$statics cached;\n"
        "$exit $sub after before;\n";

    int rc = compile_and_run(main_src.c_str());
    std::remove(mod_path.c_str());
    assert(rc == 1);
    printf("PASS test_e2e_module_statics_access\n");
}

static void test_e2e_file_static_function() {
    int rc = compile_and_run(
        "$decl f $static $func () {\n"
        "    $ret 9;\n"
        "};\n"
        "$decl fn $member $member $file $$statics f;\n"
        "$exit $call fn ();\n"
    );
    assert(rc == 9);
    printf("PASS test_e2e_file_static_function\n");
}

static void test_e2e_member_immediate_block_operand() {
    int rc = compile_and_run(
        "$exit $member {\n"
        "    $decl value 9;\n"
        "} value;\n"
    );
    assert(rc == 9);
    printf("PASS test_e2e_member_immediate_block_operand\n");
}

static void test_e2e_set_from_member_immediate_block_operand() {
    int rc = compile_and_run(
        "$decl y $mut 0;\n"
        "$set y $member {\n"
        "    $decl value 9;\n"
        "} value;\n"
        "$exit y;\n"
    );
    assert(rc == 9);
    printf("PASS test_e2e_set_from_member_immediate_block_operand\n");
}

static void test_e2e_member_immediate_block_operand_mutation() {
    int rc = compile_and_run(
        "$exit $member {\n"
        "    $decl value $mut 0;\n"
        "    $set value 12;\n"
        "} value;\n"
    );
    assert(rc == 12);
    printf("PASS test_e2e_member_immediate_block_operand_mutation\n");
}

static void test_e2e_block_value_captures_final_state() {
    int rc = compile_and_run(
        "$decl p {\n"
        "    $decl x $mut 1;\n"
        "    $set x 5;\n"
        "};\n"
        "$exit $member p x;\n"
    );
    assert(rc == 5);
    printf("PASS test_e2e_block_value_captures_final_state\n");
}

static void test_e2e_ref_member_immediate_block_operand() {
    int rc = compile_and_run(
        "$decl r $ref $member {\n"
        "    $decl value $mut 3;\n"
        "    $set value 21;\n"
        "} value;\n"
        "$exit r;\n"
    );
    assert(rc == 21);
    printf("PASS test_e2e_ref_member_immediate_block_operand\n");
}

static void test_e2e_set_member_immediate_block_lhs() {
    int rc = compile_and_run(
        "$set $member {\n"
        "    $decl value $mut 3;\n"
        "} value 8;\n"
        "$exit 0;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_set_member_immediate_block_lhs\n");
}

static void test_e2e_set_member_new_value_context_lhs() {
    int rc = compile_and_run(
        "$decl Point { $decl x $mut 0; };\n"
        "$set $member $new Point (3) x 8;\n"
        "$exit 0;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_set_member_new_value_context_lhs\n");
}

static void test_e2e_heap_alloc_free() {
    int rc = compile_and_run(
        "$decl x $heap $mut 41;\n"
        "$free x;\n"
        "$exit 0;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_heap_alloc_free\n");
}

static void test_e2e_ref_identity_ops() {
    int rc = compile_and_run(
        "$decl a $heap $mut 1;\n"
        "$decl b $heap $mut 1;\n"
        "$decl same $if $req a a 1 0;\n"
        "$decl diff $if $rneq a b 1 0;\n"
        "$free a;\n"
        "$free b;\n"
        "$exit $add same diff;\n"
    );
    assert(rc == 2);
    printf("PASS test_e2e_ref_identity_ops\n");
}

static void test_e2e_heap_block_defer_cleanup() {
    int rc = compile_and_run(
        "$decl x $heap {\n"
        "    $decl a $heap $mut 4;\n"
        "    $defer $free a;\n"
        "};\n"
        "$free x;\n"
        "$exit 0;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_heap_block_defer_cleanup\n");
}

// ── $ref regression tests ────────────────────────────────────────────────────

static void test_e2e_rnull_decl_and_req_check() {
    // $null pushes a null ref handle; $req against same address returns 1
    int rc = compile_and_run(
        "$decl p $null;\n"
        "$decl is_null $if $req p $null 1 0;\n"
        "$exit is_null;\n"
    );
    assert(rc == 1);
    printf("PASS test_e2e_rnull_decl_and_req_check\n");
}

static void test_e2e_ref_write_through() {
    // write-through: $set r val writes to x via ref alias; x is changed
    int rc = compile_and_run(
        "$decl x $mut 10;\n"
        "$decl r $ref x;\n"
        "$set r 99;\n"
        "$exit x;\n"
    );
    assert(rc == 99);
    printf("PASS test_e2e_ref_write_through\n");
}

static void test_e2e_static_ref_read() {
    // $ref on a $static variable produces a valid ref
    int rc = compile_and_run(
        "$decl x $static $mut 77;\n"
        "$decl r $ref x;\n"
        "$exit r;\n"
    );
    assert(rc == 77);
    printf("PASS test_e2e_static_ref_read\n");
}

// ── $defer / $free regression tests ──────────────────────────────────────────

static void test_e2e_func_body_defer_runs_at_ret() {
    // $defer at function-body level fires AFTER $ret stores the return value.
    // Function-local static: defer increments AFTER the pre-defer value is returned.
    // r1 = 0 (cnt was 0), defer runs → cnt=1; r2 = 1 (cnt is now 1); exit = 0+1 = 1
    int rc = compile_and_run(
        "$decl f $func () {\n"
        "    $decl cnt $static $mut 0;\n"
        "    $defer $set cnt $add cnt 1;\n"
        "    $ret cnt;\n"
        "};\n"
        "$decl r1 $call f ();\n"
        "$decl r2 $call f ();\n"
        "$exit $add r1 r2;\n"
    );
    assert(rc == 1);
    printf("PASS test_e2e_func_body_defer_runs_at_ret\n");
}

static void test_e2e_func_body_defer_lifo_order() {
    // Multiple function-body $defer statements run in LIFO order.
    // defer2 (second registered) runs first, defer1 runs second.
    // order starts at 0: defer2 first → 0*10+2=2; defer1 next → 2*10+1=21.
    // r1 = 0 (pre-defer), r2 = 21 (next call sees order=21); exit = 0+21 = 21
    int rc = compile_and_run(
        "$decl f $func () {\n"
        "    $decl order $static $mut 0;\n"
        "    $defer $set order $add $mul order 10 1;\n"
        "    $defer $set order $add $mul order 10 2;\n"
        "    $ret order;\n"
        "};\n"
        "$decl r1 $call f ();\n"
        "$decl r2 $call f ();\n"
        "$exit $add r1 r2;\n"
    );
    assert(rc == 21);
    printf("PASS test_e2e_func_body_defer_lifo_order\n");
}

static void test_e2e_func_body_defer_implicit_ret() {
    // $defer fires at implicit end-of-function (no explicit $ret).
    // A heap alloc is created and freed by the deferred $free — no crash = correct.
    int rc = compile_and_run(
        "$decl do_work $func () {\n"
        "    $decl x $heap $mut 0;\n"
        "    $defer $free x;\n"
        "};\n"
        "$decl _ $call do_work ();\n"
        "$exit 0;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_func_body_defer_implicit_ret\n");
}

static void test_e2e_free_alias_cleanup() {
    // $free via an $alias must still trigger the original binding's cleanup
    int rc = compile_and_run(
        "$decl x $heap {\n"
        "    $decl a $heap $mut 1;\n"
        "    $defer $free a;\n"
        "};\n"
        "$alias y x;\n"
        "$free y;\n"
        "$exit 0;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_free_alias_cleanup\n");
}

static void test_e2e_new_decl_cleanup_at_scope_exit() {
    // $new creates a fresh block instance; if the template has $defer the
    // new declaration inherits cleanup and it fires when the binding goes out of scope
    int rc = compile_and_run(
        "$decl counter $static $mut 0;\n"
        "$decl Template {\n"
        "    $decl x $mut 0;\n"
        "    $defer $set counter $add counter 1;\n"
        "};\n"
        "{\n"
        "    $decl n $new Template ();\n"
        "};\n"
        "$exit counter;\n"
    );
    assert(rc == 1);
    printf("PASS test_e2e_new_decl_cleanup_at_scope_exit\n");
}

static void test_e2e_heap_free_via_alias_thunk() {
    // $decl y x copies the heap handle value (not a $alias).
    // $free y must still invoke the cleanup thunk via the runtime cleanup_fidx.
    int rc = compile_and_run(
        "$decl counter $static $mut 0;\n"
        "$decl x $heap {\n"
        "    $defer $set counter $add counter 1;\n"
        "};\n"
        "$decl y x;\n"
        "$free y;\n"
        "$exit counter;\n"
    );
    assert(rc == 1);
    printf("PASS test_e2e_heap_free_via_alias_thunk\n");
}

static void test_e2e_metadata_syntax_reserved() {
    int rc = compile_and_run(
        "$decl x $member 7 $$syntax;\n"
    );
    assert(rc == -1);
    printf("PASS test_e2e_metadata_syntax_reserved\n");
}

// ── $extern / FFI tests ───────────────────────────────────────────────────────

/* Write a temp io-like module and return its path. */
static std::string write_io_module(const char* extra = "") {
    std::string src =
        "$decl print     $extern $func ($decl s \"\") 0;\n"
        "$decl println   $extern $func ($decl s \"\") 0;\n"
        "$decl print_int $extern $func ($decl n 0) 0;\n"
        "$decl eprint    $extern $func ($decl s \"\") 0;\n"
        "$decl eprintln  $extern $func ($decl s \"\") 0;\n";
    if (extra && extra[0]) src += extra;
    return write_temp_source(src.c_str());
}

/* Call println; verify no crash and exit 0. */
static void test_e2e_extern_print() {
    std::string io_path = write_io_module();
    std::string main_src =
        std::string("$decl io $import \"") + io_path + "\";\n"
        "$decl _ $call $member io println (\"hello from morphl\");\n"
        "$exit 0;\n";
    int rc = compile_and_run(main_src.c_str());
    std::remove(io_path.c_str());
    assert(rc == 0);
    printf("PASS test_e2e_extern_print\n");
}

/* Call print_int; verify no crash and exit 0. */
static void test_e2e_extern_print_int() {
    std::string io_path = write_io_module();
    std::string main_src =
        std::string("$decl io $import \"") + io_path + "\";\n"
        "$decl _ $call $member io print_int (42);\n"
        "$exit 0;\n";
    int rc = compile_and_run(main_src.c_str());
    std::remove(io_path.c_str());
    assert(rc == 0);
    printf("PASS test_e2e_extern_print_int\n");
}

/* Use the return value of a native function in $exit. println returns 0. */
static void test_e2e_extern_return_value() {
    std::string io_path = write_io_module();
    std::string main_src =
        std::string("$decl io $import \"") + io_path + "\";\n"
        "$decl r $call $member io println (\"return value test\");\n"
        "$exit r;\n";
    int rc = compile_and_run(main_src.c_str());
    std::remove(io_path.c_str());
    assert(rc == 0);  // println returns 0
    printf("PASS test_e2e_extern_return_value\n");
}

/* Unregistered native symbol must cause load failure (rc != 0). */
static void test_e2e_extern_unknown_sym() {
    /* Write a module with a symbol that is not in the static registry. */
    std::string mod_path = write_temp_source(
        "$decl no_such_native $extern $func ($decl s \"\") 0;\n"
        "$decl sentinel 1;\n"
    );
    std::string main_src =
        std::string("$decl mod $import \"") + mod_path + "\";\n"
        "$exit 0;\n";
    int rc = compile_and_run(main_src.c_str());
    std::remove(mod_path.c_str());
    /* Compile succeeds, but load must fail because no_such_native is unresolved. */
    assert(rc != 0);
    printf("PASS test_e2e_extern_unknown_sym\n");
}

/* Explicit extern symbol name in declaration. */
static void test_e2e_extern_explicit_symbol() {
    std::string main_src =
        "$decl writer $extern \"println\" $func ($decl s \"\") 0;\n"
        "$decl _ $call writer (\"explicit symbol\");\n"
        "$exit 0;\n";
    int rc = compile_and_run(main_src.c_str());
    assert(rc == 0);
    printf("PASS test_e2e_extern_explicit_symbol\n");
}

/* Rebind a mutable extern by name-only extern in $set. */
static void test_e2e_extern_rebind() {
    std::string main_src =
        "$decl writer $mut $extern \"print\" $func ($decl s \"\") 0;\n"
        "$set writer $extern \"println\";\n"
        "$decl _ $call writer (\"rebound symbol\");\n"
        "$exit 0;\n";
    int rc = compile_and_run(main_src.c_str());
    assert(rc == 0);
    printf("PASS test_e2e_extern_rebind\n");
}

/* Resolve an extern after a forward declaration using name-only syntax. */
static void test_e2e_extern_forward_resolve() {
    std::string main_src =
        "$decl writer $forward $extern $func ($decl s \"\") 0;\n"
        "$decl writer $extern \"println\";\n"
        "$decl _ $call writer (\"forward extern\");\n"
        "$exit 0;\n";
    int rc = compile_and_run(main_src.c_str());
    assert(rc == 0);
    printf("PASS test_e2e_extern_forward_resolve\n");
}

// ── Array tests ──────────────────────────────────────────────────────────────

/* $array declaration zero-initialises all elements */
static void test_e2e_array_zero_init() {
    int rc = compile_and_run(
        "$decl buf $array 0 4;\n"
        "$decl v $index buf 0;\n"
        "$exit v;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_array_zero_init\n");
}

/* $index reads the correct element after mutation */
static void test_e2e_array_index_read() {
    /* Use $array 0 3 (structural form), then $index after init, or just read zero */
    int rc = compile_and_run(
        "$decl buf $array 0 3;\n"
        "$decl a $index buf 1;\n"
        "$decl b $index buf 2;\n"
        "$exit $add a b;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_array_index_read\n");
}

/* $array with structural element type from integer literal */
static void test_e2e_array_type_name() {
    int rc = compile_and_run(
        "$decl buf $array 0 2;\n"
        "$decl v $index buf 0;\n"
        "$exit v;\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_array_type_name\n");
}

// ── Union tests ───────────────────────────────────────────────────────────────

/* $decl s $union 0 0.0 — frame is zero-initialized; $$tag starts at 0 */
static void test_e2e_union_zero_tag() {
    const char* src =
        "$decl s $union 0 0.0;\n"
        "$exit $member s $$tag;\n";
    int rc = compile_and_run(src);
    assert(rc == 0);
    printf("PASS test_e2e_union_zero_tag\n");
}

/* Named union type via $decl; same zero-tag behavior */
static void test_e2e_union_named_type() {
    const char* src =
        "$decl Shape $union 0 0.0;\n"
        "$decl s Shape;\n"
        "$exit $member s $$tag;\n";
    int rc = compile_and_run(src);
    assert(rc == 0);
    printf("PASS test_e2e_union_named_type\n");
}

/* Data-first layout: $as directly on union reads from byte 0 (payload region).
 * A zero-initialized union reinterpreted as int should produce 0. */
static void test_e2e_union_data_first_layout() {
    const char* src =
        "$decl s $union 0 0.0;\n"
        "$decl v $as s 0;\n"   /* data-first: payload at offset 0 */
        "$exit v;\n";
    int rc = compile_and_run(src);
    assert(rc == 0);
    printf("PASS test_e2e_union_data_first_layout\n");
}

/* $as as a pure type annotation — wrapping an integer expression */
static void test_e2e_as_identity() {
    const char* src =
        "$decl x 42;\n"
        "$decl y $as x 0;\n"
        "$exit y;\n";
    int rc = compile_and_run(src);
    assert(rc == 42);
    printf("PASS test_e2e_as_identity\n");
}

/* Phase 2: block field initialization via inline block literal
 * $decl p { $decl x 42; $decl y 7; } stores fields directly into p's frame slot. */
static void test_e2e_block_field_init() {
    const char* src =
        "$decl p { $decl x 42; $decl y 7; };\n"
        "$exit $member p x;\n";
    int rc = compile_and_run(src);
    assert(rc == 42);
    printf("PASS test_e2e_block_field_init\n");
}

/* Phase 2: second field of block is also correctly initialized */
static void test_e2e_block_field_init_second() {
    const char* src =
        "$decl p { $decl x 10; $decl y 30; };\n"
        "$exit $member p y;\n";
    int rc = compile_and_run(src);
  assert(rc == 30);
  printf("PASS test_e2e_block_field_init_second\n");
}

static void test_e2e_block_function_field_updates_parent() {
    int rc = compile_and_run(
        "$decl x {\n"
        "  $decl a $mut 10;\n"
        "  $decl f $func ($decl n 0) $set $member $parent a n;\n"
        "};\n"
        "$call $member x f 42;\n"
        "$exit $member x a;\n"
    );
    assert(rc == 42);
    printf("PASS test_e2e_block_function_field_updates_parent\n");
}

/* Phase 3: $ref on a $member lvalue — read through the alias */
static void test_e2e_ref_member() {
    const char* src =
        "$decl p { $decl x 99; $decl y 0; };\n"
        "$decl rx $ref $member p x;\n"
        "$exit rx;\n";
    int rc = compile_and_run(src);
    assert(rc == 99);
    printf("PASS test_e2e_ref_member\n");
}

/* Phase 3: $ref on an array element ($index literal) */
static void test_e2e_ref_index() {
    const char* src =
        "$decl arr $array 0 3;\n"
        "$set $index arr 1 77;\n"
        "$decl r $ref $index arr 1;\n"
        "$exit r;\n";
    int rc = compile_and_run(src);
    assert(rc == 77);
    printf("PASS test_e2e_ref_index\n");
}

/* Phase 4: $set with $member LHS — block named field */
static void test_e2e_set_member_field() {
    const char* src =
        "$decl p { $decl x $mut 0; $decl y $mut 0; };\n"
        "$set $member p x 42;\n"
        "$exit $member p x;\n";
    int rc = compile_and_run(src);
    assert(rc == 42);
    printf("PASS test_e2e_set_member_field\n");
}

/* Phase 4: $set with $member $$tag on a union */
static void test_e2e_set_union_tag() {
    const char* src =
        "$decl Circle { $decl r $mut 0; };\n"
        "$decl Rect   { $decl w $mut 0; $decl h $mut 0; };\n"
        "$decl Shape $union Circle Rect;\n"
        "$decl s Shape;\n"
        "$set $member s $$tag 1;\n"
        "$exit $member s $$tag;\n";
    int rc = compile_and_run(src);
    assert(rc == 1);
    printf("PASS test_e2e_set_union_tag\n");
}

/* Phase 4: $set with $index LHS (literal index) */
static void test_e2e_set_index() {
    const char* src =
        "$decl arr $array 0 4;\n"
        "$set $index arr 2 77;\n"
        "$exit $index arr 2;\n";
    int rc = compile_and_run(src);
    assert(rc == 77);
    printf("PASS test_e2e_set_index\n");
}

/* Phase 5: runtime (variable) $index */
static void test_e2e_runtime_index() {
    const char* src =
        "$decl arr $array 0 4;\n"
        "$set $index arr 0 10;\n"
        "$set $index arr 1 20;\n"
        "$set $index arr 2 30;\n"
        "$decl i 2;\n"
        "$exit $index arr i;\n";
    int rc = compile_and_run(src);
    assert(rc == 30);
    printf("PASS test_e2e_runtime_index\n");
}

/* Phase 6: $new scalar (2-arg form) — $new 0 55 copies 55 into a new int slot */
static void test_e2e_new_scalar() {
    const char* src =
        "$decl x $new 0 55;\n"
        "$exit x;\n";
    int rc = compile_and_run(src);
    assert(rc == 55);
    printf("PASS test_e2e_new_scalar\n");
}

static void test_e2e_new_array_group_initializer() {
    int rc = compile_and_run(
        "$decl arr $new ($array 0 3) (4, 5, 6);\n"
        "$exit $index arr 2;\n"
    );
    assert(rc == 6);
    printf("PASS test_e2e_new_array_group_initializer\n");
}

/* Phase 6: $new block with positional group initializer — field override */
static void test_e2e_new_union_tag() {
    const char* src =
        "$decl Circle { $decl r 0; };\n"
        "$decl c $new Circle (7);\n"
        "$exit $member c r;\n";
    int rc = compile_and_run(src);
    assert(rc == 7);
    printf("PASS test_e2e_new_union_tag\n");
}

static void test_e2e_new_inline_block_type_expr() {
    int rc = compile_and_run(
        "$decl p $new $inline {\n"
        "    $decl x 7;\n"
        "};\n"
        "$exit $member p x;\n"
    );
    assert(rc == 7);
    printf("PASS test_e2e_new_inline_block_type_expr\n");
}

static void test_e2e_new_import_member_type_expr_default() {
    std::string mod_path = write_temp_source(
        "$decl Point { $decl x 0; };\n"
    );

    std::string main_src =
        std::string("$decl mod $import \"") + mod_path + "\";\n"
        "$decl p $new $member mod Point;\n"
        "$exit $member p x;\n";

    int rc = compile_and_run(main_src.c_str());
    std::remove(mod_path.c_str());
    assert(rc == 0);
    printf("PASS test_e2e_new_import_member_type_expr_default\n");
}

static void test_e2e_new_import_member_type_expr_init() {
    std::string mod_path = write_temp_source(
        "$decl Point { $decl x 0; };\n"
    );

    std::string main_src =
        std::string("$decl mod $import \"") + mod_path + "\";\n"
        "$decl p $new $member mod Point (11);\n"
        "$exit $member p x;\n";

    int rc = compile_and_run(main_src.c_str());
    std::remove(mod_path.c_str());
    assert(rc == 11);
    printf("PASS test_e2e_new_import_member_type_expr_init\n");
}

static void test_e2e_new_value_context_member() {
    int rc = compile_and_run(
        "$decl Point { $decl x 0; };\n"
        "$exit $member $new Point (13) x;\n"
    );
    assert(rc == 13);
    printf("PASS test_e2e_new_value_context_member\n");
}

static void test_e2e_new_value_context_import_member() {
    std::string mod_path = write_temp_source(
        "$decl Point { $decl x 0; };\n"
    );

    std::string main_src =
        std::string("$decl mod $import \"") + mod_path + "\";\n"
        "$exit $member $new $member mod Point (17) x;\n";

    int rc = compile_and_run(main_src.c_str());
    std::remove(mod_path.c_str());
    assert(rc == 17);
    printf("PASS test_e2e_new_value_context_import_member\n");
}

static void test_e2e_ref_member_new_value_context() {
    int rc = compile_and_run(
        "$decl Point { $decl x $mut 0; };\n"
        "$decl r $ref $member $new Point (23) x;\n"
        "$exit r;\n"
    );
    assert(rc == 23);
    printf("PASS test_e2e_ref_member_new_value_context\n");
}

static void test_e2e_nested_new_import_member_ref_field() {
    std::string mod_path = write_temp_source(
        "$decl Node { $decl val $mut 0; $decl next $mut $ref $this; };\n"
    );

    std::string main_src =
        std::string("$decl mod $import \"") + mod_path + "\";\n"
        "$decl node $new $member mod Node (5, $new $member mod Node (9, $null));\n"
        "$exit $member node val;\n";

    int rc = compile_and_run(main_src.c_str());
    std::remove(mod_path.c_str());
    assert(rc == 5);
    printf("PASS test_e2e_nested_new_import_member_ref_field\n");
}

// ── Compiler-injected intrinsic properties ────────────────────────────────────

static void test_e2e_intrinsic_size_int() {
    /* $$size of an int variable: i64 is 8 bytes */
    int rc = compile_and_run(
        "$decl x 42;\n"
        "$exit $member x $$size;\n"
    );
    assert(rc == 8);
    printf("PASS test_e2e_intrinsic_size_int\n");
}

static void test_e2e_intrinsic_size_block() {
    /* $$size of a two-field block: 2 × 8 = 16 bytes */
    int rc = compile_and_run(
        "$decl Point { $decl px 0; $decl py 0; };\n"
        "$decl p $new Point ();\n"
        "$exit $member p $$size;\n"
    );
    assert(rc == 16);
    printf("PASS test_e2e_intrinsic_size_block\n");
}

static void test_e2e_intrinsic_name_ident() {
    /* $$name of an identifier returns the identifier's name */
    int rc = compile_and_run(
        "$decl myvar 99;\n"
        "$decl result $if $eq $member myvar $$name \"myvar\" 1 0;\n"
        "$exit result;\n"
    );
    assert(rc == 1);
    printf("PASS test_e2e_intrinsic_name_ident\n");
}

static void test_e2e_intrinsic_type_int() {
    /* $$type of an int variable returns "int" */
    int rc = compile_and_run(
        "$decl x 7;\n"
        "$decl result $if $eq $member x $$type \"int\" 1 0;\n"
        "$exit result;\n"
    );
    assert(rc == 1);
    printf("PASS test_e2e_intrinsic_type_int\n");
}

// ── Recursive $new with $ref $this fields ─────────────────────────────────────

static void test_e2e_recursive_new_head_val() {
    /* $new Node (head_val, ...) — head field is correctly initialised */
    int rc = compile_and_run(
        "$decl Node { $decl val $mut 0; $decl next $mut $ref $this; };\n"
        "$decl node $new Node (7, $null);\n"
        "$exit $member node val;\n"
    );
    assert(rc == 7);
    printf("PASS test_e2e_recursive_new_head_val\n");
}

static void test_e2e_recursive_new_two_nodes() {
    /* Two-node list: flatten pre-pass creates a sibling; head.val initialised. */
    int rc = compile_and_run(
        "$decl Node { $decl val $mut 0; $decl next $mut $ref $this; };\n"
        "$decl node $new Node (3, $new Node (9, $null));\n"
        "$exit $member node val;\n"
    );
    assert(rc == 3);
    printf("PASS test_e2e_recursive_new_two_nodes\n");
}

static void test_e2e_recursive_new_three_nodes() {
    /* Three-node list: two siblings inserted; head.val initialised. */
    int rc = compile_and_run(
        "$decl Node { $decl val $mut 0; $decl next $mut $ref $this; };\n"
        "$decl node $new Node (5, $new Node (6, $new Node (7, $null)));\n"
        "$exit $member node val;\n"
    );
    assert(rc == 5);
    printf("PASS test_e2e_recursive_new_three_nodes\n");
}

static void test_e2e_inline_member_block_field() {
    int rc = compile_and_run(
        "$exit $member $inline {\n"
        "    $decl value 9;\n"
        "} value;\n"
    );
    assert(rc == 9);
    printf("PASS test_e2e_inline_member_block_field\n");
}

static void test_e2e_inline_member_block_dependency() {
    int rc = compile_and_run(
        "$exit $member $inline {\n"
        "    $decl base 4;\n"
        "    $decl doubled $add base base;\n"
        "} doubled;\n"
    );
    assert(rc == 8);
    printf("PASS test_e2e_inline_member_block_dependency\n");
}

static void test_e2e_inline_member_import_alias() {
    std::string mod_path = write_temp_source(
        "$decl answer 42;\n"
    );

    std::string main_src =
        std::string("$alias mod $inline $import \"") + mod_path + "\";\n"
        "$exit $member mod answer;\n";

    int rc = compile_and_run(main_src.c_str());
    std::remove(mod_path.c_str());
    assert(rc == 42);
    printf("PASS test_e2e_inline_member_import_alias\n");
}

static void test_e2e_inline_member_runtime_dependency_rejected() {
    int rc = compile_and_run(
        "$exit $member $inline {\n"
        "    $decl value $mut 1;\n"
        "    $set value 2;\n"
        "} value;\n"
    );
    assert(rc == -1);
    printf("PASS test_e2e_inline_member_runtime_dependency_rejected\n");
}

static void test_e2e_inline_func_expression_body() {
    int rc = compile_and_run(
        "$alias add_one $inline $func ($decl n 0) $add n 1;\n"
        "$exit $call add_one 5;\n"
    );
    assert(rc == 6);
    printf("PASS test_e2e_inline_func_expression_body\n");
}

static void test_e2e_inline_func_multiple_uses() {
    int rc = compile_and_run(
        "$alias twice $inline $func ($decl n 0) $add n n;\n"
        "$decl a $call twice 4;\n"
        "$decl b $call twice 7;\n"
        "$exit $add a b;\n"
    );
    assert(rc == 22);
    printf("PASS test_e2e_inline_func_multiple_uses\n");
}

static void test_e2e_inline_func_block_body_ret() {
    int rc = compile_and_run(
        "$alias choose $inline $func ($decl x 0) {\n"
        "    $if $gt x 4 {\n"
        "        $ret $add x 10;\n"
        "    } {\n"
        "        $ret 0;\n"
        "    };\n"
        "};\n"
        "$exit $call choose 7;\n"
    );
    assert(rc == 17);
    printf("PASS test_e2e_inline_func_block_body_ret\n");
}

static void test_e2e_inline_func_block_body_no_ret() {
    int rc = compile_and_run(
        "$alias zeroed $inline $func () {\n"
        "    $decl x 9;\n"
        "};\n"
        "$exit $call zeroed ();\n"
    );
    assert(rc == 0);
    printf("PASS test_e2e_inline_func_block_body_no_ret\n");
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
    test_e2e_alias_scalar_substitution();
    test_e2e_alias_func_duplicate_by_use();
    test_e2e_static_mutable_counter();
    test_e2e_function_local_static_persists();
    test_e2e_callf();
    test_e2e_null();
    test_e2e_this();
    test_e2e_parent();
    test_e2e_traits_decl();
    test_e2e_impl_decl();
    test_e2e_impl_with_func_prop();
    test_e2e_exit_zero();
    test_e2e_exit_nonzero();
    test_e2e_exit_requires_arg();
    test_e2e_main_is_not_autocalled();
    test_e2e_main_is_ordinary_binding();
    test_e2e_while_basic();
    test_e2e_while_no_iter();
    test_e2e_if_int_condition();
    test_e2e_while_int_condition();
    test_e2e_not();
    test_e2e_and();
    test_e2e_or();
    test_e2e_break();
    test_e2e_continue();
    test_e2e_break_in_nested_block();
    test_e2e_continue_in_nested_block();
    test_e2e_string_assign();
    test_e2e_string_eq();
    test_e2e_string_neq();
    test_e2e_string_mutation();
    test_e2e_import_basic();
    test_e2e_import_single_decl_module();
    test_e2e_import_nested_member_chain();
    test_e2e_vm_object_metadata();
    test_e2e_vm_link_single_object();
    test_e2e_vm_link_accepts_function_relocs();
    test_e2e_vm_link_dedups_duplicate_object_inputs();
    test_e2e_vm_link_rejects_executable_input();
    test_e2e_vm_link_accepts_dependency_object();
    test_e2e_vm_link_relocates_global_layout();
    test_e2e_vm_link_initializes_modules_once();
    test_e2e_vm_link_shares_imported_module_statics();
    test_e2e_vm_link_deduplicates_module_slot_offsets();
    test_e2e_vm_link_accepts_direct_imported_function_call();
    test_e2e_vm_link_rejects_missing_dependency_function_export();
    test_e2e_vm_link_rejects_missing_dependency_object();
    test_e2e_vm_link_rejects_unrelated_object();
    test_e2e_global_argc();
    test_e2e_global_entry();
    test_e2e_global_modules_slot();
    test_e2e_file_statics_access();
    test_e2e_global_source_statics_access();
    test_e2e_module_statics_access();
    test_e2e_file_static_function();
    test_e2e_member_immediate_block_operand();
    test_e2e_set_from_member_immediate_block_operand();
    test_e2e_member_immediate_block_operand_mutation();
    test_e2e_block_value_captures_final_state();
    test_e2e_ref_member_immediate_block_operand();
    test_e2e_set_member_immediate_block_lhs();
    test_e2e_set_member_new_value_context_lhs();
    test_e2e_heap_alloc_free();
    test_e2e_ref_identity_ops();
    test_e2e_heap_block_defer_cleanup();
    test_e2e_rnull_decl_and_req_check();
    test_e2e_ref_write_through();
    test_e2e_static_ref_read();
    test_e2e_func_body_defer_runs_at_ret();
    test_e2e_func_body_defer_lifo_order();
    test_e2e_func_body_defer_implicit_ret();
    test_e2e_free_alias_cleanup();
    test_e2e_new_decl_cleanup_at_scope_exit();
    test_e2e_heap_free_via_alias_thunk();
    test_e2e_extern_print();
    test_e2e_extern_print_int();
    test_e2e_extern_return_value();
    test_e2e_extern_unknown_sym();
    test_e2e_extern_explicit_symbol();
    test_e2e_extern_rebind();
    test_e2e_extern_forward_resolve();
    test_e2e_array_zero_init();
    test_e2e_array_index_read();
    test_e2e_array_type_name();
    test_e2e_union_zero_tag();
    test_e2e_union_named_type();
    test_e2e_union_data_first_layout();
    test_e2e_as_identity();
    test_e2e_block_field_init();
    test_e2e_block_field_init_second();
    test_e2e_block_function_field_updates_parent();
    test_e2e_ref_member();
    test_e2e_ref_index();
    test_e2e_set_member_field();
    test_e2e_set_union_tag();
    test_e2e_set_index();
    test_e2e_runtime_index();
    test_e2e_new_scalar();
    test_e2e_new_array_group_initializer();
    test_e2e_new_union_tag();
    test_e2e_new_inline_block_type_expr();
    test_e2e_new_import_member_type_expr_default();
    test_e2e_new_import_member_type_expr_init();
    test_e2e_new_value_context_member();
    test_e2e_new_value_context_import_member();
    test_e2e_ref_member_new_value_context();
    test_e2e_nested_new_import_member_ref_field();
    test_e2e_intrinsic_size_int();
    test_e2e_intrinsic_size_block();
    test_e2e_intrinsic_name_ident();
    test_e2e_intrinsic_type_int();
    test_e2e_metadata_syntax_reserved();
    test_e2e_recursive_new_head_val();
    test_e2e_recursive_new_two_nodes();
    test_e2e_recursive_new_three_nodes();
    test_e2e_inline_member_block_field();
    test_e2e_inline_member_block_dependency();
    test_e2e_inline_member_import_alias();
    test_e2e_inline_member_runtime_dependency_rejected();
    test_e2e_inline_func_expression_body();
    test_e2e_inline_func_multiple_uses();
    test_e2e_inline_func_block_body_ret();
    test_e2e_inline_func_block_body_no_ret();
    test_e2e_overload_arithmetic_resolution();
    test_e2e_overload_whole_object_assignment();
    printf("All integration tests passed.\n");
    return 0;
}
