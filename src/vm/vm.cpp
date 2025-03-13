#include "vm.h"
#include "instruction.h"
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ffi.h>
#include <iostream>
#include <vector>

namespace vm {
  uint64_t VM::execute(std::vector<uint8_t>& bytecode) {
    const uint8_t* base = &bytecode.front(); 
    PC_REG = reinterpret_cast<uintptr_t>(base);
    while (PC_REG < reinterpret_cast<uintptr_t>(&bytecode.back())) {
      OpCode opcode = getPCValue(opcode);
      switch (opcode) {
        case HALT: {
          return RET_REG;
        }
        case NOOP: {
          PC_REG++;
          break;
        }
        case JM: {
          int64_t offset = getPCValue(offset, 1);
          PC_REG = 9 + offset + (intptr_t)PC_REG;
          break;
        }
        case JP: {
          int64_t offset = getPCValue(offset, 2);
          uint8_t idx = getPCValue(idx, 1);
          if ((int64_t)registers_[idx] > 0){
            PC_REG = 10 + offset + (intptr_t)PC_REG;
          } else {
            PC_REG += 10;
          }
          break;
        }
        case CALL: {
          memcpy(&memory_[SP_REG], &FP_REG, sizeof(uint64_t));
          FP_REG = SP_REG;
          SP_REG += sizeof(uint64_t);
          PC_REG += 2;
          memcpy(&memory_[SP_REG], &PC_REG, sizeof(uintptr_t));
          SP_REG += sizeof(uint64_t);
          PC_REG = registers_[*reinterpret_cast<uint8_t*>(PC_REG - 1)];
          break;
        }
        case RET: {
          memcpy(&PC_REG, &memory_[FP_REG + sizeof(uint64_t)], sizeof(uint64_t));
          auto currentFP = FP_REG;
          memcpy(&FP_REG, &memory_[FP_REG], sizeof(uint64_t));
          SP_REG = currentFP;

          break;
        }
        case CALLC: {
          PC_REG++;
          constexpr auto staticSignatureSize = sizeof(uintptr_t) + 2;
          std::vector<uint8_t> signature((uint8_t*)PC_REG, (uint8_t*)(PC_REG + staticSignatureSize));
          uint8_t numArgs = signature.back();
          auto argTypeStart = PC_REG + staticSignatureSize;
          for (size_t i = 0; i < numArgs; i++) {
            signature.push_back(*reinterpret_cast<uint8_t*>((argTypeStart + i)));
          }
          std::vector<void*> args(numArgs);
          uint8_t* argPtr = memory_.data() + FP_REG;
          for (size_t i = 0; i < numArgs; i++) {
            args[i] = argPtr;
            argPtr += get_ffi_type(signature[staticSignatureSize + i])->size;
          }
          void* res = callFunction(signature.data(), const_cast<const void**>(args.data()));

          if (RET_REG) {
            memcpy((void*)RET_REG,res,get_ffi_type(signature[staticSignatureSize - 2])->size);
          } else {
            memcpy(&RET_REG, res, sizeof(uint64_t));
          }
          free(res);
          PC_REG += staticSignatureSize + numArgs;
          break;
        }
        case LOADI: {
          uint8_t dest_reg = getPCValue(dest_reg, 1);
          uint64_t& dest = registers_[dest_reg];
          getPCValue(dest, 2);
          PC_REG += 10;
          break;
        }
        case LOAD: {
          uint8_t destIdx = getPCValue(destIdx, 1);
          uint8_t srcIdx = getPCValue(srcIdx, 2);
          memcpy(&registers_[destIdx], &memory_[registers_[srcIdx]], sizeof(uint64_t));
          PC_REG += 3;
          break;
        }
        case PUSHI: {
          uint64_t imm = 0;
          getPCValue(imm, 1);
          memcpy(&memory_[SP_REG], &imm, sizeof(uint64_t));
          SP_REG += 8;
          PC_REG += 9;
          break;
        }
        case PUSH: {
          uint8_t srcIdx = getPCValue(srcIdx, 1);
          memcpy(&memory_[SP_REG], &registers_[srcIdx], sizeof(uint64_t));
          SP_REG += 8;
          PC_REG += 2;
          break;
        }
        case POP: {
          uint8_t destIdx = getPCValue(destIdx, 1);
          if (SP_REG < 8) {
            SP_REG = 0;
            PC_REG += 2;
            registers_[destIdx] = 0;
            break;
          }
          memcpy(&registers_[destIdx], &memory_[SP_REG - 8], sizeof(uint64_t));
          SP_REG -= 8;
          PC_REG += 2;
          break;
        }
        case MOV: {
          uint8_t destIdx = getPCValue(destIdx, 1);
          uint8_t srcIdx = getPCValue(srcIdx, 2);
          registers_[destIdx] = registers_[srcIdx];
          PC_REG += 3;
          break;
        }
        case ADD: {
          uint8_t destIdx = getPCValue(destIdx, 1);
          uint8_t src1Idx = getPCValue(src1Idx, 2);
          uint8_t src2Idx = getPCValue(src2Idx, 3);
          registers_[destIdx] = registers_[src1Idx] + registers_[src2Idx];
          PC_REG += 4;
          break;
        }
        case SUB: {
          uint8_t destIdx = getPCValue(destIdx, 1);
          uint8_t src1Idx = getPCValue(src1Idx, 2);
          uint8_t src2Idx = getPCValue(src2Idx, 3);
          registers_[destIdx] = registers_[src1Idx] - registers_[src2Idx];
          PC_REG += 4;
          break;

        }
        case STORE: {
          uint8_t destIdx = getPCValue(destIdx, 1);
          uint8_t srcIdx = getPCValue(srcIdx, 2);
          memory_[registers_[destIdx]] = registers_[srcIdx];
          PC_REG += 3; 
          break;
        }

        default: {
          throw "undefined opcode";
          break;
        } 
      }
    }
    return RET_REG;
  }
  ffi_type* VM::get_ffi_type(uint8_t type_id) {
    switch (type_id) {
      case C_INT: return &ffi_type_sint;
      case C_FLOAT: return &ffi_type_float;
      case C_DOUBLE: return &ffi_type_double;
      case C_CHARPTR: return &ffi_type_pointer;
      case C_VOIDPTR: return &ffi_type_pointer;
      case C_VOID: return &ffi_type_void;
      default: return nullptr;
    }
  }

  void* VM::callFunction(const uint8_t* signature, const void** args) {
    uint64_t funcPtr;
    memcpy(&funcPtr, &signature[0], sizeof(funcPtr));
    uint8_t returnTypeId = signature[sizeof(uint64_t)];
    uint8_t numArgs = signature[sizeof(uint64_t) + 1];
    std::vector<ffi_type*> argTypes(numArgs);
    for (size_t i = 0; i < numArgs ; i++) {
      argTypes[i] = get_ffi_type(signature[sizeof(uint64_t) + 2 + i]);
    }
    // uint8_t callingConvention = signature[6 + numArgs];

    ffi_cif cif;
    ffi_type* returnType = get_ffi_type(returnTypeId);
    if (ffi_prep_cif(&cif, FFI_DEFAULT_ABI, numArgs, returnType, argTypes.data()) != FFI_OK) {
      std::cerr << "Error preparing cif\n";
      return nullptr;
    }

    void* result = malloc(returnType->size);
    if (!result) {
      std::cerr << "Failed to allocate memory for return value\n";
      return nullptr;
    }

    ffi_call(&cif, (void(*)())funcPtr, result, const_cast<void**>(args));

    return result;
  }
}
