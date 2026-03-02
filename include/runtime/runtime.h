#ifndef MORPHL_RUNTIME_RUNTIME_H_
#define MORPHL_RUNTIME_RUNTIME_H_

#include <stddef.h>
#include <stdint.h>

#include "util/util.h"

// TODO: finish runtime definitions

// Primitive runtime types
typedef enum {
    MORPHL_VALUE_TYPE_INT,
    MORPHL_VALUE_TYPE_FLOAT,
    MORPHL_VALUE_TYPE_BOOL,
    MORPHL_VALUE_TYPE_STRING,
    MORPHL_VALUE_TYPE_VOID,
    MORPHL_VALUE_TYPE_FUNC,
    MORPHL_VALUE_TYPE_BLOCK,
    MORPHL_VALUE_TYPE_GROUP,
    MORPHL_VALUE_TYPE_UNKNOWN
} MorphlValueType;



// VM structure
typedef struct {
    uint8_t* bytecode;
    size_t bytecode_size;
    size_t ip; // instruction pointer
    uint8_t* stack; // stack memory
    size_t stack_size;
    size_t sp; // stack pointer
    size_t fp; // frame pointer
    /// @brief General purpose registers. always a reference type (i.e. pointer to value)
    /// lreg should always be active (i.e. being the target for op like push/pop store/load etc).
    /// rreg is secondary register that can be used for operations needing two registers. can be set via swapping with lreg. 
    uintptr_t lreg, rreg;
    size_t constant_offset; // constant pool offset
} MorphlVM;


// VM operations
typedef enum {
    // halt the VM
    MORPHL_VM_OP_HALT = 0,
    // no operation
    MORPHL_VM_OP_NOP,
    /// @brief load effective address from sp into lreg
    MORPHL_VM_OP_LEA,
    /// @brief load effective address from stack offset into lreg, operand=size_t offset
    MORPHL_VM_OP_LEA_OFFSET,
    /// @brief load effective address from frame pointer offset into lreg, operand=size_t offset
    MORPHL_VM_OP_LEA_FP_OFFSET,
    /// @brief load effective address from constant pool into lreg, operand=size_t offset
    MORPHL_VM_OP_LEA_CONST,
    /// @brief load immediate 64-bit into scratch to which will be referenced by lreg
    MORPHL_VM_OP_LDI64,
    /// @brief load immediate 32-bit into scratch to which will be referenced by lreg
    MORPHL_VM_OP_LDI32,
    /// @brief load immediate 16-bit into scratch to which will be referenced by lreg
    MORPHL_VM_OP_LDI16,
    /// @brief load immediate 8-bit into scratch to which will be referenced by lreg
    MORPHL_VM_OP_LDI8,
    /// @brief push immediate 64-bit value onto stack
    MORPHL_VM_OP_PUSHI64,
    /// @brief push immediate 32-bit value onto stack
    MORPHL_VM_OP_PUSHI32,
    /// @brief push immediate 16-bit value onto stack
    MORPHL_VM_OP_PUSHI16,
    /// @brief push immediate 8-bit value onto stack
    MORPHL_VM_OP_PUSHI8,
    /// @brief push constant pool address onto stack, operand=size_t offset
    MORPHL_VM_OP_PUSH_CONST,
    /// @brief pop value from stack into lreg
    MORPHL_VM_OP_POP,
    /// @brief pop until stack offset, discarding values, operand=size_t offset
    MORPHL_VM_OP_POPU,
    // arithmetic operations
    MORPHL_VM_OP_ADD,
    MORPHL_VM_OP_SUB,
    MORPHL_VM_OP_MUL,
    MORPHL_VM_OP_DIV,
    MORPHL_VM_OP_MOD,
    // floating point operations
    MORPHL_VM_OP_FADD,
    MORPHL_VM_OP_FSUB,
    MORPHL_VM_OP_FMUL,
    MORPHL_VM_OP_FDIV,
    // control flow
    MORPHL_VM_OP_JMP,
    MORPHL_VM_OP_JMP_IF_FALSE,
    /// @brief call function operand=size of args lreg=func addr rreg=args
    MORPHL_VM_OP_CALL,
    // return from function
    MORPHL_VM_OP_RET,
    /// @brief load value from memory address into lreg
    MORPHL_VM_OP_LOAD,
    /// @brief load constant address into lreg, operand=const pool offset 
    MORPHL_VM_OP_LOAD_CONST,
    /// @brief store value from rreg into memory address in lreg
    MORPHL_VM_OP_STORE,
    // comparison operations
    MORPHL_VM_OP_EQ,
    MORPHL_VM_OP_NEQ,
    MORPHL_VM_OP_LT,
    MORPHL_VM_OP_GT,
    MORPHL_VM_OP_LTE,
    MORPHL_VM_OP_GTE,
    // logical operations
    MORPHL_VM_OP_AND,
    MORPHL_VM_OP_OR,
    MORPHL_VM_OP_NOT,
    // bitwise operations
    MORPHL_VM_OP_BAND,
    MORPHL_VM_OP_BOR,
    MORPHL_VM_OP_BXOR,
    MORPHL_VM_OP_BNOT,
    MORPHL_VM_OP_LSHIFT,
    MORPHL_VM_OP_RSHIFT,
    // register operations
    /// @brief swap lreg and rreg
    MORPHL_VM_OP_SWAP,
    /// @brief copy value from rreg to lreg
    MORPHL_VM_OP_COPY
} MorphlVMOp;


// Bytecode structure
typedef struct {
    // Magic number for identification
    uint32_t magic;
    // Version number
    uint32_t version;
    // Bytecode instructions
    uint8_t* bytecode;
    size_t bytecode_size; // Size of bytecode in bytes (excluding header, including constant pool)
    // Constant pool
    size_t constant_pool_offset; // Offset from start of bytecode to the constant pool
    // Entry point
    size_t entry_point;
    // Metadata (Optional)
} MorphlBytecode;

// VM API
MorphlVM* morphl_vm_new(size_t stack_size);
void morphl_vm_free(MorphlVM* vm);

int morphl_vm_execute(MorphlVM* vm);



#endif // MORPHL_RUNTIME_RUNTIME_H_