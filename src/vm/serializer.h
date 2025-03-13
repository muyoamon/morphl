#ifndef MORPHL_VM_SERIALIZER_H
#define MORPHL_VM_SERIALIZER_H

#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include "../ast/ast.h"
#include "instruction.h"
namespace vm {
  
  class Serializer {
    std::vector<uint8_t> instructions_;
    public:
    Serializer() : instructions_() {};
    Serializer(std::vector<uint8_t>);
    bool writef(const std::string& filename);
  };
}

#endif  // MORPHL_VM_SERIALIZER_H
