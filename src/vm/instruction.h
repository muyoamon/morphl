#ifndef MORPHL_VM_INSTRUCTION_H
#define MORPHL_VM_INSTRUCTION_H

#include <cstdint>
#include <vector>
namespace vm {

  constexpr uint32_t MAGIC_NUMBER = 0x4D504C42; // MPLB
  constexpr uint32_t VERSION = 1;
  
  // specialized registers 
  constexpr uint8_t RRET = 28;
  constexpr uint8_t RPROG = 29;
  constexpr uint8_t RSTACK = 30;
  constexpr uint8_t RFRAME = 31;


  enum OpCode : uint8_t {
    /// special opcode
    NOOP,   // noop
    BREAK,  // breakpoint

    /// control flow
    HALT,   // halt
    CALL,   // call
    CALLC,  // call c function 
    RET,    // return 
    // jump (+-) 
    JM,     // jump
    JZ,     // jump if zero
    JN,     // jump if negative
    JP,     // jump if positive

    /// memory stack
    PUSH,   // push stack
    PUSHI,  // push immediate to stack
    POP,    // pop stack

    /// registers
    LOAD,   // load 
    LOADI,  // load immediate
    MOV,    // move
    STORE,  // store

    /// arithmetic
    NEG,
    ADD,
    SUB,
    MUL,
    DIV,
    MOD,

    // libraries
    IMPORT,

  };

  struct Instruction {
    OpCode opCode;
    uint8_t op1;
    uint8_t op2;
    uint8_t op3;
  };

  enum FFITypeIdentifier : uint8_t {
    C_VOID,
    C_INT,
    C_FLOAT,
    C_DOUBLE,
    C_CHARPTR,
    C_VOIDPTR,
    C_STRUCT,
  };

}


#endif // !MORPHL_VM_INSTRUCTION_H
