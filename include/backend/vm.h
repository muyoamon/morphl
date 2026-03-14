#ifndef MORPHL_BACKEND_VM_H_
#define MORPHL_BACKEND_VM_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MORPHL_VM_MAGIC "MVMB"
#define MORPHL_VM_VERSION_MAJOR 1
#define MORPHL_VM_VERSION_MINOR 0

enum VmOpcode {
  /*
  * Opcode
  */

  // halt
  VM_OP_HALT = 0x00,
  // push null onto stack
  VM_OP_PUSH_NULL = 0x01,
  // push literal string onto stack, operand=string table index
  VM_OP_PUSH_LITERAL = 0x02,
  // push identifier onto stack, operand=string table index
  VM_OP_PUSH_IDENT = 0x03,
  // make group from top N stack items, operand=N
  VM_OP_MAKE_GROUP = 0x04,
  // set slot on object, operand=string table index for slot name, value on stack
  VM_OP_SET_SLOT = 0x05,
  // perform operator, operand=string table index for operator name, operands on stack
  VM_OP_OPERATOR = 0x06,

  // Call & stuffs
  // return from call, always return 1st item on stack as result
  VM_OP_RET = 0x10,
  // call function, operand=function address, arguments on stack
  VM_OP_CALL = 0x11,

  // Scope management
  // push new scope
  VM_OP_PUSH_SCOPE = 0x20,
  // pop scope
  VM_OP_POP_SCOPE = 0x21,
  // unwind scope on error (e.g. during return or unwinding), operand=scope depth to unwind to
  VM_OP_UNWIND_SCOPE = 0x22,



  // fallback descriptor for node kinds not lowered yet, operand=ast node kind, string table index for op name, operand=child count, children on stack
  VM_OP_NODE_META = 0xE0,
};

typedef struct VmString {
    char* ptr;
    uint32_t len;
} VmString;

typedef struct VmStringTable {
    VmString* items;
    size_t count;
    size_t capacity;
} VmStringTable;

typedef struct VmBytes {
    uint8_t* data;
    size_t len;
    size_t capacity;
} VmBytes;

typedef struct VmMetadata {
    uint32_t key_index;
    uint32_t value_index;
} VmMetadata;

typedef struct VmMetadataTable {
    VmMetadata* items;
    size_t count;
    size_t capacity;
} VmMetadataTable;

typedef uint32_t VmFunctionIdx;

typedef struct {
  const char *dbg_name;   // for debugging purposes only, not used in execution
  size_t entry_point;     // index into code where function body starts
  uint32_t local_count;   // number of local variables (slots) used by this function, used for stack management
  uint32_t flags;
} VmFunctionMeta;








#endif // MORPHL_BACKEND_VM_H_