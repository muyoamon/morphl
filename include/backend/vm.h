#ifndef MORPHL_BACKEND_VM_H_
#define MORPHL_BACKEND_VM_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MORPHL_VM_MAGIC        "MVMB"
#define MORPHL_VM_VERSION_MAJOR 2
#define MORPHL_VM_VERSION_MINOR 0

/*
 * Opcode encoding
 * ---------------
 * Each instruction is 1 byte opcode + zero or more fixed-width operands:
 *   frame offset : 4 bytes, i32 little-endian (signed)
 *   function idx : 4 bytes, u32 little-endian
 *   jump target  : 4 bytes, i32 little-endian (relative to byte after operand)
 *   scope size   : 4 bytes, u32 little-endian
 *   i64 immediate: 8 bytes, i64 little-endian
 *   f64 immediate: 8 bytes, IEEE-754 bits as u64 little-endian
 */
enum VmOpcode {
  /* ── Halt ── */
  VM_OP_HALT   = 0x00,   // no operand

  /* ── Constants ── */
  VM_OP_ICONST = 0x01,   // [i64 imm]  push 64-bit integer literal
  VM_OP_FCONST = 0x02,   // [f64 imm]  push 64-bit float literal
  VM_OP_RNULL  = 0x03,   //            push null reference (i32 = 0)

  /* ── Integer arithmetic  (pop 2 i64, push 1 i64) ── */
  VM_OP_IADD = 0x08,
  VM_OP_ISUB = 0x09,
  VM_OP_IMUL = 0x0A,
  VM_OP_IDIV = 0x0B,
  VM_OP_IMOD = 0x0C,

  /* ── Float arithmetic  (pop 2 f64, push 1 f64) ── */
  VM_OP_FADD = 0x0D,
  VM_OP_FSUB = 0x0E,
  VM_OP_FMUL = 0x0F,
  VM_OP_FDIV = 0x10,

  /* ── Integer comparison  (pop 2 i64, push i64 0 or 1) ── */
  VM_OP_IEQ  = 0x11,
  VM_OP_INEQ = 0x12,
  VM_OP_ILT  = 0x13,
  VM_OP_IGT  = 0x14,
  VM_OP_ILTE = 0x15,
  VM_OP_IGTE = 0x16,

  /* ── Float comparison  (pop 2 f64, push i64 0 or 1) ── */
  VM_OP_FEQ  = 0x17,
  VM_OP_FNEQ = 0x18,
  VM_OP_FLT  = 0x19,
  VM_OP_FGT  = 0x1A,
  VM_OP_FLTE = 0x1B,
  VM_OP_FGTE = 0x1C,

  /* ── Type conversion ── */
  VM_OP_I2F = 0x1D,   // pop i64, push f64
  VM_OP_F2I = 0x1E,   // pop f64, push i64 (truncate)

  /* ── Scope management  [u32 size] ── */
  VM_OP_ENTER = 0x20,  // reserve <size> bytes in current frame (zeroed)
  VM_OP_LEAVE = 0x21,  // release <size> bytes from current frame

  /* ── Load / Store  [i32 signed frame offset] ── */
  VM_OP_ILOAD  = 0x30,  // push i64 from frame[offset]
  VM_OP_FLOAD  = 0x31,  // push f64 from frame[offset]
  VM_OP_RLOAD  = 0x32,  // [i32 off]  push i64 containing i32 ref stored at frame[offset]
  VM_OP_ISTORE = 0x38,  // pop i64  → frame[offset]
  VM_OP_FSTORE = 0x39,  // pop f64  → frame[offset]
  VM_OP_RSTORE = 0x3A,  // [i32 off]  pop i64, store low 32 bits as ref at frame[offset]

  /* ── Control flow  [i32 relative offset from end of instruction] ── */
  VM_OP_JMP   = 0x40,   // unconditional jump
  VM_OP_JIF   = 0x41,   // jump if top of stack is truthy (i64 != 0); pops the value
  VM_OP_JNULL = 0x42,   // [i32 rel]  pop i64, jump if it is 0 (null ref)

  /* ── Function calls ── */
  VM_OP_RESERVE = 0x50,  // [u32 size]  zero-extend frame by <size> bytes (return slot)
  VM_OP_CALL    = 0x51,  // [u32 idx]   call function table entry <idx> (static)
  VM_OP_RET     = 0x52,  // no operand  return to caller
  VM_OP_CALLF   = 0x53,  // [i32 off]   indirect call: load func index from frame[off], dispatch

  /* ── Reference / indirection ── */
  VM_OP_ADDREF  = 0x60,  // [i32 off]  push absolute stack address of frame[off] as i64
  VM_OP_DEREF   = 0x61,  // pop i64 (absolute stack addr), push i64 at that address

  /* ── $parent field access ── */
  VM_OP_PLOAD   = 0x62,  // [i32 off]  load i64 from absolute address stored in parent slot + off
  VM_OP_PSTORE  = 0x63,  // [i32 off]  store i64 to absolute address stored in parent slot + off
};

/*
 * Function table entry.
 * The binary file's function table is an array of these, ordered by index.
 * Function 0 is always the top-level program body (implicit "main").
 */
typedef struct {
  uint32_t entry_point;  // byte offset into the code section where the body starts
  uint32_t frame_size;   // total bytes needed for this function's frame (params + locals)
  uint32_t param_size;   // bytes occupied by parameters at frame[0]
  uint32_t flags;        // reserved, must be 0
} VmFunctionMeta;

/*
 * Growable byte buffer — used internally by the emitter.
 */
typedef struct VmBytes {
  uint8_t* data;
  size_t   len;
  size_t   capacity;
} VmBytes;

#endif // MORPHL_BACKEND_VM_H_
