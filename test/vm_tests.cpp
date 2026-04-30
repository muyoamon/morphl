#include <assert.h>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <cstdlib>
#include <ctime>
#include <sstream>
#include <vector>
#include <fstream>
#include <string>

extern "C" {
#include "backend/vm.h"
#include "runtime/runtime.h"
}

// ── BytecodeBuilder ──────────────────────────────────────────────────────────

class BytecodeBuilder {
    std::vector<uint8_t> code_;
    uint32_t frame_size_ = 0;
    // For multi-function bytecode
    struct FuncEntry {
        uint32_t entry_point;
        uint32_t frame_size;
        uint32_t param_size;
        uint32_t return_size;
        uint32_t flags;
    };
    std::vector<FuncEntry> extra_funcs_;  // additional functions beyond func 0
    std::vector<std::string> native_symbols_;

public:
    void set_frame_size(uint32_t n) { frame_size_ = n; }

    // Add an extra function (entry_point = offset from start of code section)
    void add_extra_func(uint32_t entry_point, uint32_t frame_sz, uint32_t param_sz = 0) {
        extra_funcs_.push_back({entry_point, frame_sz, param_sz, 0, 0});
    }

    void add_extra_func_with_flags(uint32_t entry_point, uint32_t frame_sz,
                                   uint32_t param_sz, uint32_t flags) {
        extra_funcs_.push_back({entry_point, frame_sz, param_sz, 0, flags});
    }

    void add_native_symbol(const char* symbol) {
        native_symbols_.emplace_back(symbol);
    }

    // Byte emitters
    void u8(uint8_t b)   { code_.push_back(b); }
    void u16le(uint16_t v) { code_.push_back(v & 0xFF); code_.push_back((v >> 8) & 0xFF); }
    void i32le(int32_t v) {
        uint32_t u = (uint32_t)v;
        code_.push_back(u & 0xFF); code_.push_back((u>>8)&0xFF);
        code_.push_back((u>>16)&0xFF); code_.push_back((u>>24)&0xFF);
    }
    void u32le(uint32_t v) {
        code_.push_back(v & 0xFF); code_.push_back((v>>8)&0xFF);
        code_.push_back((v>>16)&0xFF); code_.push_back((v>>24)&0xFF);
    }
    void i64le(int64_t v) {
        uint64_t u = (uint64_t)v;
        for (int i = 0; i < 8; i++) { code_.push_back(u & 0xFF); u >>= 8; }
    }
    void f64le(double v) {
        uint64_t u; memcpy(&u, &v, 8);
        for (int i = 0; i < 8; i++) { code_.push_back(u & 0xFF); u >>= 8; }
    }

    // Opcode helpers
    void op_halt()              { u8(VM_OP_HALT); }
    void op_iconst(int64_t v)   { u8(VM_OP_ICONST); i64le(v); }
    void op_fconst(double v)    { u8(VM_OP_FCONST); f64le(v); }
    void op_iload(int32_t off)  { u8(VM_OP_ILOAD);  i32le(off); }
    void op_fload(int32_t off)  { u8(VM_OP_FLOAD);  i32le(off); }
    void op_istore(int32_t off) { u8(VM_OP_ISTORE); i32le(off); }
    void op_fstore(int32_t off) { u8(VM_OP_FSTORE); i32le(off); }
    void op_enter(uint32_t sz)  { u8(VM_OP_ENTER);  u32le(sz); }
    void op_leave(uint32_t sz)  { u8(VM_OP_LEAVE);  u32le(sz); }
    void op_jmp(int32_t rel)    { u8(VM_OP_JMP);    i32le(rel); }
    void op_jif(int32_t rel)    { u8(VM_OP_JIF);    i32le(rel); }
    void op_reserve(uint32_t sz){ u8(VM_OP_RESERVE);u32le(sz); }
    void op_call(uint32_t idx)  { u8(VM_OP_CALL);   u32le(idx); }
    void op_ret()               { u8(VM_OP_RET); }
    void op_arith(uint8_t op)   { u8(op); }  // no-operand arithmetic/compare/convert

    size_t size() const { return code_.size(); }

    std::string write_temp() const {
        const char* tmpdir = std::getenv("TMPDIR");
        if (!tmpdir) tmpdir = "/tmp";
        static int counter = 0;
        std::ostringstream ss;
        ss << tmpdir << "/morphl_vm_test_" << ++counter << ".mbc";
        std::string path = ss.str();

        std::ofstream f(path, std::ios::binary | std::ios::trunc);
        assert(f.is_open());

        // Helper lambdas for file writing
        auto write_u8  = [&](uint8_t  v){ f.write((char*)&v, 1); };
        auto write_u16 = [&](uint16_t v){ uint8_t b[2]={uint8_t(v),uint8_t(v>>8)}; f.write((char*)b,2); };
        auto write_u32 = [&](uint32_t v){ uint8_t b[4]={uint8_t(v),uint8_t(v>>8),uint8_t(v>>16),uint8_t(v>>24)}; f.write((char*)b,4); };
        (void)write_u8;

        // Header
        f.write("MVMB", 4);
        write_u16(MORPHL_VM_VERSION_MAJOR);
        write_u16(MORPHL_VM_VERSION_MINOR);
        write_u16(MORPHL_VM_ARTIFACT_EXECUTABLE);
        write_u32(0); // global_frame_size

        // Function table
        uint32_t func_count = 1 + (uint32_t)extra_funcs_.size();
        write_u32(func_count);
        // func 0 (main)
        write_u32(0);           // entry_point
        write_u32(frame_size_); // frame_size
        write_u32(0);           // param_size
        write_u32(0);           // return_size
        write_u32(0);           // flags
        // extra funcs
        for (auto& ef : extra_funcs_) {
            write_u32(ef.entry_point);
            write_u32(ef.frame_size);
            write_u32(ef.param_size);
            write_u32(ef.return_size);
            write_u32(ef.flags);
        }

        // Code section
        write_u32((uint32_t)code_.size());
        f.write((char*)code_.data(), (std::streamsize)code_.size());

        // String table
        write_u32(0);

        // Native symbol table
        write_u32((uint32_t)native_symbols_.size());
        for (const std::string& symbol : native_symbols_) {
            write_u32((uint32_t)symbol.size());
            f.write(symbol.c_str(), (std::streamsize)symbol.size() + 1);
            write_u32(0);
            f.write("", 1);
        }

        f.close();
        return path;
    }
};

// ── Test helpers ─────────────────────────────────────────────────────────────

static void run_and_check_i64(BytecodeBuilder& bc, int64_t expected) {
    std::string path = bc.write_temp();
    MorphlVmProgram* prog = NULL;
    assert(morphl_vm_program_load(path.c_str(), &prog));
    MorphlVm* vm = morphl_vm_new(prog);
    assert(vm);
    morphl_exit_code_t rc = morphl_vm_execute(vm, stderr);
    assert(rc == 0);
    int64_t got = -9999;
    assert(morphl_vm_read_stack_i64(vm, 0, &got));
    if (got != expected) {
        fprintf(stderr, "FAIL: expected %lld got %lld\n", (long long)expected, (long long)got);
        assert(false);
    }
    morphl_vm_free(vm);
    morphl_vm_program_free(prog);
    std::remove(path.c_str());
}

static void run_and_check_f64(BytecodeBuilder& bc, double expected) {
    std::string path = bc.write_temp();
    MorphlVmProgram* prog = NULL;
    assert(morphl_vm_program_load(path.c_str(), &prog));
    MorphlVm* vm = morphl_vm_new(prog);
    assert(vm);
    morphl_exit_code_t rc = morphl_vm_execute(vm, stderr);
    assert(rc == 0);
    double got = 0.0;
    assert(morphl_vm_read_stack_f64(vm, 0, &got));
    if (fabs(got - expected) > 1e-9) {
        fprintf(stderr, "FAIL: expected %f got %f\n", expected, got);
        assert(false);
    }
    morphl_vm_free(vm);
    morphl_vm_program_free(prog);
    std::remove(path.c_str());
}

static void run_and_check_exit(BytecodeBuilder& bc, int expected_exit) {
    std::string path = bc.write_temp();
    MorphlVmProgram* prog = NULL;
    assert(morphl_vm_program_load(path.c_str(), &prog));
    MorphlVm* vm = morphl_vm_new(prog);
    assert(vm);
    morphl_exit_code_t rc = morphl_vm_execute(vm, stderr);
    assert(rc == (morphl_exit_code_t)expected_exit);
    morphl_vm_free(vm);
    morphl_vm_program_free(prog);
    std::remove(path.c_str());
}

static void run_and_expect_load_failure(BytecodeBuilder& bc) {
    std::string path = bc.write_temp();
    MorphlVmProgram* prog = NULL;
    assert(!morphl_vm_program_load(path.c_str(), &prog));
    std::remove(path.c_str());
}

static std::string make_temp_path(const char* prefix) {
    const char* tmpdir = std::getenv("TMPDIR");
    if (!tmpdir) tmpdir = "/tmp";
    static int counter = 0;
    std::ostringstream ss;
    ss << tmpdir << "/" << prefix << "_" << ++counter << ".mbc";
    return ss.str();
}

static void write_valid_empty_header(std::ofstream& f) {
    auto write_u16 = [&](uint16_t v) {
        uint8_t b[2] = {uint8_t(v), uint8_t(v >> 8)};
        f.write((char*)b, 2);
    };
    auto write_u32 = [&](uint32_t v) {
        uint8_t b[4] = {
            uint8_t(v),
            uint8_t(v >> 8),
            uint8_t(v >> 16),
            uint8_t(v >> 24),
        };
        f.write((char*)b, 4);
    };

    f.write("MVMB", 4);
    write_u16(MORPHL_VM_VERSION_MAJOR);
    write_u16(MORPHL_VM_VERSION_MINOR);
    write_u16(MORPHL_VM_ARTIFACT_EXECUTABLE);
    write_u32(0); // global_frame_size
    write_u32(1); // func_count
    write_u32(0); // entry_point
    write_u32(0); // frame_size
    write_u32(0); // param_size
    write_u32(0); // return_size
    write_u32(0); // flags
    write_u32(1); // code_len
    uint8_t halt = VM_OP_HALT;
    f.write((char*)&halt, 1);
}

static void write_u32_le(std::ofstream& f, uint32_t v) {
    uint8_t b[4] = {
        uint8_t(v),
        uint8_t(v >> 8),
        uint8_t(v >> 16),
        uint8_t(v >> 24),
    };
    f.write((char*)b, 4);
}

static void run_and_expect_execute_failure(BytecodeBuilder& bc) {
    std::string path = bc.write_temp();
    MorphlVmProgram* prog = NULL;
    assert(morphl_vm_program_load(path.c_str(), &prog));
    MorphlVm* vm = morphl_vm_new(prog);
    assert(vm);
    assert(morphl_vm_execute(vm, stderr) != 0);
    morphl_vm_free(vm);
    morphl_vm_program_free(prog);
    std::remove(path.c_str());
}

// ── §11.1-11.2: Constants / load-store ───────────────────────────────────────

static void test_vm_iconst() {
    BytecodeBuilder bc;
    bc.op_enter(8);
    bc.op_iconst(42);
    bc.op_istore(0);
    bc.op_halt();
    run_and_check_i64(bc, 42);
    printf("PASS test_vm_iconst\n");
}

static void test_vm_iload_istore() {
    // slot 0 = 99, slot 8 = load(slot 0)
    BytecodeBuilder bc;
    bc.op_enter(16);         // two 8-byte slots
    bc.op_iconst(99);
    bc.op_istore(0);         // slot 0 = 99
    bc.op_iconst(0);
    bc.op_istore(8);         // slot 8 = 0
    bc.op_iload(0);
    bc.op_istore(8);         // slot 8 = slot 0 = 99
    bc.op_halt();
    // read slot 8 (byte offset 8)
    std::string path = bc.write_temp();
    MorphlVmProgram* prog = NULL;
    assert(morphl_vm_program_load(path.c_str(), &prog));
    MorphlVm* vm = morphl_vm_new(prog);
    assert(vm);
    assert(morphl_vm_execute(vm, stderr) == 0);
    int64_t got;
    assert(morphl_vm_read_stack_i64(vm, 8, &got));
    assert(got == 99);
    morphl_vm_free(vm); morphl_vm_program_free(prog);
    std::remove(path.c_str());
    printf("PASS test_vm_iload_istore\n");
}

static void test_vm_fconst() {
    BytecodeBuilder bc;
    bc.op_enter(8);
    bc.op_fconst(3.14);
    bc.op_fstore(0);
    bc.op_halt();
    run_and_check_f64(bc, 3.14);
    printf("PASS test_vm_fconst\n");
}

// ── §11.3: Integer arithmetic ─────────────────────────────────────────────────

static void test_vm_iadd() {
    BytecodeBuilder bc;
    bc.op_enter(8);
    bc.op_iconst(10); bc.op_iconst(20);
    bc.op_arith(VM_OP_IADD);
    bc.op_istore(0); bc.op_halt();
    run_and_check_i64(bc, 30);
    printf("PASS test_vm_iadd\n");
}

static void test_vm_isub() {
    BytecodeBuilder bc;
    bc.op_enter(8);
    bc.op_iconst(30); bc.op_iconst(12);
    bc.op_arith(VM_OP_ISUB);
    bc.op_istore(0); bc.op_halt();
    run_and_check_i64(bc, 18);
    printf("PASS test_vm_isub\n");
}

static void test_vm_imul() {
    BytecodeBuilder bc;
    bc.op_enter(8);
    bc.op_iconst(6); bc.op_iconst(7);
    bc.op_arith(VM_OP_IMUL);
    bc.op_istore(0); bc.op_halt();
    run_and_check_i64(bc, 42);
    printf("PASS test_vm_imul\n");
}

static void test_vm_idiv() {
    BytecodeBuilder bc;
    bc.op_enter(8);
    bc.op_iconst(100); bc.op_iconst(4);
    bc.op_arith(VM_OP_IDIV);
    bc.op_istore(0); bc.op_halt();
    run_and_check_i64(bc, 25);
    printf("PASS test_vm_idiv\n");
}

static void test_vm_imod() {
    BytecodeBuilder bc;
    bc.op_enter(8);
    bc.op_iconst(10); bc.op_iconst(3);
    bc.op_arith(VM_OP_IMOD);
    bc.op_istore(0); bc.op_halt();
    run_and_check_i64(bc, 1);
    printf("PASS test_vm_imod\n");
}

// ── §11.3: Float arithmetic ───────────────────────────────────────────────────

static void test_vm_fadd() {
    BytecodeBuilder bc; bc.op_enter(8);
    bc.op_fconst(1.5); bc.op_fconst(1.5);
    bc.op_arith(VM_OP_FADD); bc.op_fstore(0); bc.op_halt();
    run_and_check_f64(bc, 3.0);
    printf("PASS test_vm_fadd\n");
}

static void test_vm_fsub() {
    BytecodeBuilder bc; bc.op_enter(8);
    bc.op_fconst(5.0); bc.op_fconst(2.5);
    bc.op_arith(VM_OP_FSUB); bc.op_fstore(0); bc.op_halt();
    run_and_check_f64(bc, 2.5);
    printf("PASS test_vm_fsub\n");
}

static void test_vm_fmul() {
    BytecodeBuilder bc; bc.op_enter(8);
    bc.op_fconst(2.0); bc.op_fconst(3.0);
    bc.op_arith(VM_OP_FMUL); bc.op_fstore(0); bc.op_halt();
    run_and_check_f64(bc, 6.0);
    printf("PASS test_vm_fmul\n");
}

static void test_vm_fdiv() {
    BytecodeBuilder bc; bc.op_enter(8);
    bc.op_fconst(9.0); bc.op_fconst(3.0);
    bc.op_arith(VM_OP_FDIV); bc.op_fstore(0); bc.op_halt();
    run_and_check_f64(bc, 3.0);
    printf("PASS test_vm_fdiv\n");
}

// ── §11.4: Integer comparisons ────────────────────────────────────────────────

static int64_t eval_icmp(uint8_t op, int64_t a, int64_t b) {
    BytecodeBuilder bc; bc.op_enter(8);
    bc.op_iconst(a); bc.op_iconst(b);
    bc.op_arith(op); bc.op_istore(0); bc.op_halt();
    std::string path = bc.write_temp();
    MorphlVmProgram* prog = NULL;
    assert(morphl_vm_program_load(path.c_str(), &prog));
    MorphlVm* vm = morphl_vm_new(prog);
    assert(morphl_vm_execute(vm, stderr) == 0);
    int64_t got; assert(morphl_vm_read_stack_i64(vm, 0, &got));
    morphl_vm_free(vm); morphl_vm_program_free(prog);
    std::remove(path.c_str());
    return got;
}

static void test_vm_ieq()  {
    assert(eval_icmp(VM_OP_IEQ,  5, 5) == 1);
    assert(eval_icmp(VM_OP_IEQ,  5, 6) == 0);
    printf("PASS test_vm_ieq\n");
}
static void test_vm_ineq() {
    assert(eval_icmp(VM_OP_INEQ, 5, 6) == 1);
    assert(eval_icmp(VM_OP_INEQ, 5, 5) == 0);
    printf("PASS test_vm_ineq\n");
}
static void test_vm_ilt() {
    assert(eval_icmp(VM_OP_ILT,  3, 5) == 1);
    assert(eval_icmp(VM_OP_ILT,  5, 3) == 0);
    printf("PASS test_vm_ilt\n");
}
static void test_vm_igt() {
    assert(eval_icmp(VM_OP_IGT,  5, 3) == 1);
    assert(eval_icmp(VM_OP_IGT,  3, 5) == 0);
    printf("PASS test_vm_igt\n");
}
static void test_vm_ilte() {
    assert(eval_icmp(VM_OP_ILTE, 5, 5) == 1);
    assert(eval_icmp(VM_OP_ILTE, 6, 5) == 0);
    printf("PASS test_vm_ilte\n");
}
static void test_vm_igte() {
    assert(eval_icmp(VM_OP_IGTE, 5, 5) == 1);
    assert(eval_icmp(VM_OP_IGTE, 4, 5) == 0);
    printf("PASS test_vm_igte\n");
}

// ── §11.5: Type conversion ────────────────────────────────────────────────────

static void test_vm_i2f() {
    BytecodeBuilder bc; bc.op_enter(8);
    bc.op_iconst(3); bc.op_arith(VM_OP_I2F);
    bc.op_fstore(0); bc.op_halt();
    run_and_check_f64(bc, 3.0);
    printf("PASS test_vm_i2f\n");
}

static void test_vm_f2i() {
    BytecodeBuilder bc; bc.op_enter(8);
    bc.op_fconst(3.7); bc.op_arith(VM_OP_F2I);
    bc.op_istore(0); bc.op_halt();
    run_and_check_i64(bc, 3);
    printf("PASS test_vm_f2i\n");
}

// ── §11.6: Scope management ───────────────────────────────────────────────────

static void test_vm_enter_leave() {
    // ENTER/LEAVE balance; result slot at offset 0 of outer scope
    BytecodeBuilder bc; bc.op_enter(8); // outer: slot 0
    bc.op_iconst(7); bc.op_istore(0);
    bc.op_enter(8);          // inner scope
    bc.op_iconst(99);
    bc.op_istore(8);         // inner slot (absolute offset 8)
    bc.op_leave(8);          // pop inner scope: stack.top = 8
    bc.op_halt();            // outer slot 0 still holds 7
    // read slot 0 = 7
    std::string path = bc.write_temp();
    MorphlVmProgram* prog = NULL;
    assert(morphl_vm_program_load(path.c_str(), &prog));
    MorphlVm* vm = morphl_vm_new(prog);
    assert(morphl_vm_execute(vm, stderr) == 0);
    int64_t got; assert(morphl_vm_read_stack_i64(vm, 0, &got));
    assert(got == 7);
    morphl_vm_free(vm); morphl_vm_program_free(prog);
    std::remove(path.c_str());
    printf("PASS test_vm_enter_leave\n");
}

static void test_vm_nested_enter_leave() {
    // Two nested scopes with no values stored — just verify no crash and clean exit
    BytecodeBuilder bc;
    bc.op_enter(8);
    bc.op_iconst(1); bc.op_istore(0);
    bc.op_enter(8);
    bc.op_enter(8);
    bc.op_leave(8);
    bc.op_leave(8);
    bc.op_leave(8);
    bc.op_halt();
    run_and_check_exit(bc, 0);
    printf("PASS test_vm_nested_enter_leave\n");
}

// ── §11.10: Control flow ──────────────────────────────────────────────────────

static void test_vm_jmp() {
    // Layout: ENTER 8; ICONST 1; ISTORE 0; JMP +9; ICONST 2; ISTORE 0; HALT
    // JMP should skip the second ICONST+ISTORE, leaving slot 0 = 1
    BytecodeBuilder bc; bc.op_enter(8);
    bc.op_iconst(1); bc.op_istore(0);
    // JMP over: ICONST(9 bytes) + ISTORE(5 bytes) = 14 bytes
    bc.op_jmp(14);       // skip next 14 bytes
    bc.op_iconst(2);     // 9 bytes
    bc.op_istore(0);     // 5 bytes
    bc.op_halt();
    run_and_check_i64(bc, 1);
    printf("PASS test_vm_jmp\n");
}

static void test_vm_jif_taken() {
    // condition=1 (true): JIF jumps to store 100, HALT; else stores 200
    BytecodeBuilder bc; bc.op_enter(8);
    bc.op_iconst(1);  // condition = true
    // JIF +14 bytes: skip ICONST(9) + ISTORE(5) = 14 bytes
    bc.op_jif(14);
    bc.op_iconst(200); bc.op_istore(0); // false branch (skipped)
    bc.op_iconst(100); bc.op_istore(0); // true branch
    bc.op_halt();
    run_and_check_i64(bc, 100);
    printf("PASS test_vm_jif_taken\n");
}

static void test_vm_jif_not_taken() {
    // condition=0 (false): JIF does not jump → stores 200
    BytecodeBuilder bc; bc.op_enter(8);
    bc.op_iconst(0);  // condition = false
    // JIF +14: would skip ICONST(9)+ISTORE(5) = 14 bytes
    bc.op_jif(14);
    bc.op_iconst(200); bc.op_istore(0); // false branch (taken)
    bc.op_iconst(100); bc.op_istore(0); // true branch (skipped — need JMP after)
    bc.op_halt();
    // Without JMP, true branch also runs! Need to add JMP.
    // Let's redesign:
    // Actually the above is wrong. We need a JMP after false branch.
    // Rebuild:
    BytecodeBuilder bc2; bc2.op_enter(8);
    bc2.op_iconst(0);  // condition = false
    // JIF +14: if true skip false branch (ICONST+ISTORE = 14 bytes)
    bc2.op_jif(14);
    // false branch:
    bc2.op_iconst(200); bc2.op_istore(0);   // 9+5=14 bytes
    bc2.op_jmp(14);                          // skip true branch (14 bytes)
    // true branch:
    bc2.op_iconst(100); bc2.op_istore(0);   // 14 bytes
    bc2.op_halt();
    run_and_check_i64(bc2, 200);
    printf("PASS test_vm_jif_not_taken\n");
}

// ── §11.7: Function calls ─────────────────────────────────────────────────────

static void test_vm_call_ret() {
    // func 0 (main): RESERVE 8; CALL 1; HALT (return value at stack[0])
    // func 1 (callee): writes 99 into return slot (offset -8 from frame_base)
    //   frame_base = stack.top when CALL executes (after RESERVE and any args)
    //   So return slot is at stack[frame_base - 8].
    //   callee does: ISTORE -8 writes to frame_ptr(vm, -8) = stack[frame_base - 8]

    // Build code:
    // func 0 starts at 0
    // func 1 starts after func 0's code

    // func 0 code:
    //   RESERVE 8        (return slot)
    //   ICONST <parent>  (hidden parent placeholder for the ABI)
    //   CALL 1
    //   HALT

    BytecodeBuilder bc;
    // func 0:
    bc.op_reserve(8);
    bc.op_iconst(0);
    bc.op_call(1);
    bc.op_halt();

    size_t func1_entry = bc.size();

    // func 1:
    bc.op_iconst(99);   // push 99
    bc.op_istore(-16);  // return slot sits before the hidden parent slot
    bc.op_ret();

    bc.add_extra_func((uint32_t)func1_entry, 0, 0);

    std::string path = bc.write_temp();
    MorphlVmProgram* prog = NULL;
    assert(morphl_vm_program_load(path.c_str(), &prog));
    MorphlVm* vm = morphl_vm_new(prog);
    assert(vm);
    morphl_exit_code_t rc = morphl_vm_execute(vm, stderr);
    assert(rc == 0);
    // Return value sits at stack[0] (the RESERVE'd slot, which is at offset 0
    // because RESERVE is the first thing done by func 0 before CALL)
    int64_t got;
    assert(morphl_vm_read_stack_i64(vm, 0, &got));
    assert(got == 99);
    morphl_vm_free(vm); morphl_vm_program_free(prog);
    std::remove(path.c_str());
    printf("PASS test_vm_call_ret\n");
}

static void test_vm_call_ret_reclaims_args() {
    BytecodeBuilder bc;

    bc.op_reserve(8);
    bc.op_iconst(111);    // hidden parent placeholder
    bc.op_iconst(222);    // one 8-byte argument
    bc.op_call(1);
    bc.op_reserve(8);
    bc.op_iconst(55);
    bc.op_istore(8);
    bc.op_halt();

    size_t func1_entry = bc.size();
    bc.op_iconst(99);
    bc.op_istore(-24);    // return slot sits before hidden parent + 1 arg
    bc.op_ret();
    bc.add_extra_func((uint32_t)func1_entry, 0, 8);

    std::string path = bc.write_temp();
    MorphlVmProgram* prog = NULL;
    assert(morphl_vm_program_load(path.c_str(), &prog));
    MorphlVm* vm = morphl_vm_new(prog);
    assert(vm);
    assert(morphl_vm_execute(vm, stderr) == 0);

    int64_t ret = 0;
    int64_t marker = 0;
    int64_t leaked = 0;
    assert(morphl_vm_read_stack_i64(vm, 0, &ret));
    assert(morphl_vm_read_stack_i64(vm, 8, &marker));
    assert(ret == 99);
    assert(marker == 55);
    assert(!morphl_vm_read_stack_i64(vm, 16, &leaked));

    morphl_vm_free(vm);
    morphl_vm_program_free(prog);
    std::remove(path.c_str());
    printf("PASS test_vm_call_ret_reclaims_args\n");
}

static void test_vm_load_rejects_bad_entry_point() {
    BytecodeBuilder bc;
    bc.op_halt();
    bc.add_extra_func(99, 0, 0);
    run_and_expect_load_failure(bc);
    printf("PASS test_vm_load_rejects_bad_entry_point\n");
}

static void test_vm_load_rejects_bad_native_symbol_index() {
    BytecodeBuilder bc;
    bc.op_halt();
    bc.add_native_symbol("native_ok");
    bc.add_extra_func_with_flags(1, 0, 0, MORPHL_FUNC_FLAG_NATIVE);
    run_and_expect_load_failure(bc);
    printf("PASS test_vm_load_rejects_bad_native_symbol_index\n");
}

static void test_vm_load_rejects_nonterminated_string() {
    std::string path = make_temp_path("morphl_vm_bad_string");
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    assert(f.is_open());
    write_valid_empty_header(f);
    write_u32_le(f, 1); // str_count
    write_u32_le(f, 3); // string length without terminator
    f.write("abcX", 4);
    write_u32_le(f, 0); // native_sym_count
    f.close();

    MorphlVmProgram* prog = NULL;
    assert(!morphl_vm_program_load(path.c_str(), &prog));
    std::remove(path.c_str());
    printf("PASS test_vm_load_rejects_nonterminated_string\n");
}

static void test_vm_load_rejects_object_artifact() {
    std::string path = make_temp_path("morphl_vm_object_artifact");
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    assert(f.is_open());
    auto write_u16 = [&](uint16_t v) {
        uint8_t b[2] = {uint8_t(v), uint8_t(v >> 8)};
        f.write((char*)b, 2);
    };
    auto write_u32 = [&](uint32_t v) {
        uint8_t b[4] = {
            uint8_t(v),
            uint8_t(v >> 8),
            uint8_t(v >> 16),
            uint8_t(v >> 24),
        };
        f.write((char*)b, 4);
    };

    f.write("MVMB", 4);
    write_u16(MORPHL_VM_VERSION_MAJOR);
    write_u16(MORPHL_VM_VERSION_MINOR);
    write_u16(MORPHL_VM_ARTIFACT_OBJECT);
    write_u32(0); // global_frame_size
    write_u32(0); // func_count
    write_u32(0); // code_len
    write_u32(0); // str_count
    write_u32(0); // native_sym_count
    f.close();

    MorphlVmProgram* prog = NULL;
    assert(!morphl_vm_program_load(path.c_str(), &prog));
    std::remove(path.c_str());
    printf("PASS test_vm_load_rejects_object_artifact\n");
}

static void test_vm_load_rejects_nonterminated_native_symbol() {
    std::string path = make_temp_path("morphl_vm_bad_native_symbol");
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    assert(f.is_open());
    write_valid_empty_header(f);
    write_u32_le(f, 0); // str_count
    write_u32_le(f, 1); // native_sym_count
    write_u32_le(f, 6); // symbol length without terminator
    f.write("nativeX", 7);
    f.close();

    MorphlVmProgram* prog = NULL;
    assert(!morphl_vm_program_load(path.c_str(), &prog));
    std::remove(path.c_str());
    printf("PASS test_vm_load_rejects_nonterminated_native_symbol\n");
}

static void test_vm_iload_oob_fails() {
    BytecodeBuilder bc;
    bc.op_reserve(8);
    bc.op_iconst(0);
    bc.op_call(1);
    bc.op_halt();

    size_t func1_entry = bc.size();
    bc.op_iload(0);
    bc.op_ret();
    bc.add_extra_func((uint32_t)func1_entry, 0, 0);

    run_and_expect_execute_failure(bc);
    printf("PASS test_vm_iload_oob_fails\n");
}

static void test_vm_callf_oob_fails() {
    BytecodeBuilder bc;
    bc.op_reserve(8);
    bc.op_iconst(0);
    bc.op_call(1);
    bc.op_halt();

    size_t func1_entry = bc.size();
    bc.u8(VM_OP_CALLF);
    bc.i32le(0);
    bc.op_ret();
    bc.add_extra_func((uint32_t)func1_entry, 0, 0);

    run_and_expect_execute_failure(bc);
    printf("PASS test_vm_callf_oob_fails\n");
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(void) {
    // Constants / load-store
    test_vm_iconst();
    test_vm_iload_istore();
    test_vm_fconst();

    // Integer arithmetic
    test_vm_iadd();
    test_vm_isub();
    test_vm_imul();
    test_vm_idiv();
    test_vm_imod();

    // Float arithmetic
    test_vm_fadd();
    test_vm_fsub();
    test_vm_fmul();
    test_vm_fdiv();

    // Comparisons
    test_vm_ieq();
    test_vm_ineq();
    test_vm_ilt();
    test_vm_igt();
    test_vm_ilte();
    test_vm_igte();

    // Type conversion
    test_vm_i2f();
    test_vm_f2i();

    // Scope management
    test_vm_enter_leave();
    test_vm_nested_enter_leave();

    // Control flow
    test_vm_jmp();
    test_vm_jif_taken();
    test_vm_jif_not_taken();

    // Function calls
    test_vm_call_ret();
    test_vm_call_ret_reclaims_args();
    test_vm_load_rejects_bad_entry_point();
    test_vm_load_rejects_bad_native_symbol_index();
    test_vm_load_rejects_nonterminated_string();
    test_vm_load_rejects_object_artifact();
    test_vm_load_rejects_nonterminated_native_symbol();
    test_vm_iload_oob_fails();
    test_vm_callf_oob_fails();

    printf("All VM opcode tests passed.\n");
    return 0;
}
