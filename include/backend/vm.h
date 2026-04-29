#ifndef MORPHL_BACKEND_VM_H_
#define MORPHL_BACKEND_VM_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MORPHL_VM_MAGIC        "MVMB"
#define MORPHL_VM_VERSION_MAJOR 0         // Major Version 0 never guarantee backward compatibility
#define MORPHL_VM_VERSION_MINOR 2

typedef enum {
  MORPHL_VM_ARTIFACT_EXECUTABLE = 0,
  MORPHL_VM_ARTIFACT_OBJECT = 1,
} MorphlVmArtifactKind;

typedef enum {
  MORPHL_VM_EXPORT_VALUE = 0,
  MORPHL_VM_EXPORT_FUNCTION = 1,
} MorphlVmExportKind;

typedef enum {
  MORPHL_VM_RELOC_FUNC_INDEX_U32 = 0,
  MORPHL_VM_RELOC_FUNC_INDEX_I64 = 1,
  MORPHL_VM_RELOC_EXTERN_FUNC_U32 = 2,
  MORPHL_VM_RELOC_EXTERN_FUNC_I64 = 3,
  MORPHL_VM_RELOC_GLOBAL_DATA_I32 = 4,
  MORPHL_VM_RELOC_GLOBAL_DATA_I64 = 5,
  MORPHL_VM_RELOC_MODULE_FRAME_BASE_I64 = 6,
  MORPHL_VM_RELOC_EXTERN_DATA_I32 = 7,
  MORPHL_VM_RELOC_MODULE_SLOT_I32 = 8,
} MorphlVmRelocKind;

typedef struct {
  uint16_t kind;
  uint32_t code_offset;
  char* module_path;
  char* symbol_name;
} MorphlVmRelocation;

#define MORPHL_VM_EXPORT_FLAG_STATIC 0x01u
#define MORPHL_VM_EXPORT_FLAG_IMPORT 0x02u
#define MORPHL_VM_EXPORT_FLAG_EXTERN 0x04u

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
  VM_OP_RNULL  = 0x03,   //            push null reference handle (0)

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
  VM_OP_RLOAD  = 0x32,  // [i32 off]  push i64 reference handle stored at frame[offset]
  VM_OP_ILOAD1S = 0x33,
  VM_OP_ILOAD1U = 0x34,
  VM_OP_ILOAD2S = 0x35,
  VM_OP_ILOAD2U = 0x36,
  VM_OP_ILOAD4S = 0x37,
  VM_OP_ILOAD4U = 0x3E,
  VM_OP_ISTORE = 0x38,  // pop i64  → frame[offset]
  VM_OP_FSTORE = 0x39,  // pop f64  → frame[offset]
  VM_OP_RSTORE = 0x3A,  // [i32 off]  pop i64 reference handle, store at frame[offset]
  VM_OP_ISTORE1 = 0x3B,
  VM_OP_ISTORE2 = 0x3C,
  VM_OP_ISTORE4 = 0x3D,

  /* ── Control flow  [i32 relative offset from end of instruction] ── */
  VM_OP_JMP   = 0x40,   // unconditional jump
  VM_OP_JIF   = 0x41,   // jump if top of stack is truthy (i64 != 0); pops the value
  VM_OP_JNULL = 0x42,   // [i32 rel]  pop i64, jump if it is 0 (null ref)

  /* ── Function calls ── */
  VM_OP_RESERVE = 0x50,  // [u32 size]  zero-extend frame by <size> bytes (return slot)
  VM_OP_CALL    = 0x51,  // [u32 idx]   call function table entry <idx> (static)
  VM_OP_RET     = 0x52,  // no operand  return to caller
  VM_OP_CALLF   = 0x53,  // [i32 off]   indirect call: load func index from frame[off], dispatch
  VM_OP_EXIT    = 0x54,  //             pop i64 from stack, exit program with that value as exit code
  VM_OP_CALLX   = 0x55,  //             pop i64 function index from stack, dispatch (dynamic trait dispatch)
  VM_OP_HEAP        = 0x56,  // [u32 size] allocate zeroed heap storage, push ref handle
  VM_OP_FREE        = 0x57,  //             pop ref handle, release heap allocation
  VM_OP_SET_CLEANUP = 0x58,  // [u32 fidx] pop heap handle, store cleanup fidx in allocation
  VM_OP_INORM1S     = 0x59,
  VM_OP_INORM1U     = 0x5A,
  VM_OP_INORM2S     = 0x5B,
  VM_OP_INORM2U     = 0x5C,
  VM_OP_INORM4S     = 0x5D,
  VM_OP_INORM4U     = 0x5E,

  /* ── Reference / indirection ── */
  VM_OP_ADDREF  = 0x60,  // [i32 off]  push stack/static ref handle for frame[off]
  VM_OP_DEREF   = 0x61,  // pop ref handle, push i64 at that location

  /* ── $parent field access ── */
  VM_OP_PLOAD   = 0x62,  // [i32 off]  load i64 from absolute address stored in parent slot + off
  VM_OP_PSTORE  = 0x63,  // [i32 off]  store i64 to absolute address stored in parent slot + off

  /* ── Global frame access ── */
  VM_OP_GLOBAL  = 0x64,  // push i64(0) — stack/global base handle
  VM_OP_ALOAD   = 0x65,  // [i32 off]  pop base handle, push i64 from base + off
  VM_OP_ASTORE  = 0x66,  // [i32 off]  pop i64 val, pop base handle, store val to base + off
  VM_OP_ALOAD1S = 0x67,
  VM_OP_ALOAD1U = 0x68,
  VM_OP_ALOAD2S = 0x69,
  VM_OP_ALOAD2U = 0x6A,
  VM_OP_ALOAD4S = 0x6B,
  VM_OP_ALOAD4U = 0x6C,
  VM_OP_ASTORE1 = 0x6D,
  VM_OP_ASTORE2 = 0x6E,
  VM_OP_ASTORE4 = 0x6F,

  /* ── String operations ── */
  VM_OP_SCONST  = 0x70,  // [u32 idx]  push pointer (as i64) to string table entry <idx>
  VM_OP_SEQ     = 0x71,  // pop 2 string pointers (i64), push i64 1 if strcmp==0, else 0
  VM_OP_SNEQ    = 0x72,  // pop 2 string pointers (i64), push i64 0 if strcmp==0, else 1

  /* ── Integer bitwise  (pop 2 i64, push 1 i64) ── */
  VM_OP_IBAND   = 0x80,
  VM_OP_IBOR    = 0x81,
  VM_OP_IBXOR   = 0x82,
  VM_OP_IBNOT   = 0x83,  // unary: pop 1 i64, push ~a
  VM_OP_ILSHIFT = 0x84,
  VM_OP_IRSHIFT = 0x85,
  VM_OP_IUDIV   = 0x86,
  VM_OP_IUMOD   = 0x87,
  VM_OP_IULT    = 0x88,
  VM_OP_IUGT    = 0x89,
  VM_OP_IULTE   = 0x8A,
  VM_OP_IUGTE   = 0x8B,
  VM_OP_IURSHIFT = 0x8C,

  /* ── Reference equality  (pop 2 i64 addresses, push i64 0 or 1) ── */
  VM_OP_REQ     = 0x8D,
  VM_OP_RNEQ    = 0x8E,
};

/* Function flags — stored in VmFunctionMeta.flags */
#define MORPHL_FUNC_FLAG_NATIVE  0x01u  /* entry_point is a native symbol table index */

/*
 * Function table entry.
 * The binary file's function table is an array of these, ordered by index.
 * Function 0 is the executable entry function.
 */
typedef struct {
  uint32_t entry_point;  // byte offset into the code section (or native sym index if NATIVE flag set)
  uint32_t frame_size;   // total bytes needed for this function's frame (params + locals)
  uint32_t param_size;   // bytes occupied by parameters at frame[0]
  uint32_t flags;        // see MORPHL_FUNC_FLAG_* above
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
