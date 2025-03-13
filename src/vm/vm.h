#ifndef MORPHL_VM_VM_H
#define MORPHL_VM_VM_H

#include "instruction.h"
#include <cstdint>
#include <cstring>
#include <vector>
#include <ffi.h>

namespace vm {
class VM {
  std::vector<uint64_t> registers_; // 32x 64-bits registers
  std::vector<uint8_t> memory_;     // stack memory
  
  uintptr_t& PC_REG = registers_[RPROG];
  uint64_t& SP_REG = registers_[RSTACK];
  uint64_t& FP_REG = registers_[RFRAME];
  uint64_t& RET_REG = registers_[RRET];

  ffi_type* get_ffi_type(uint8_t type_id);
  void* callFunction(const uint8_t* signature, const void** args);
  
  template<typename T>
  T& getPCValue(T& dest, size_t offset = 0) {
    memcpy(&dest, (const void *)(PC_REG + offset), sizeof(T));
    return dest;
  }


  public:
  VM() : registers_(32, 0), memory_(0x100000, 0) {};
  uint64_t execute(std::vector<uint8_t>& bytecode );

};
}

#endif  // MORPHL_VM_VM_H
