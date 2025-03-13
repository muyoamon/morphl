#include "serializer.h"
#include "instruction.h"
#include "../error/error.h"
#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

#define writeBytecode(file, obj) file.write(reinterpret_cast<const char*>(&obj), sizeof(obj))

namespace vm {
  Serializer::Serializer(std::vector<uint8_t> instructions) : instructions_{instructions} {}

  bool Serializer::writef(const std::string& filename) {
    std::ofstream file(filename, std::ios::binary);
    if (!file) {
      morphl::error::errorManager.addError({"Cannot open file " + filename + " for writing.\n", morphl::error::Severity::Critical});
      return false;
    }

    // write header
    uint32_t instructionCount = instructions_.size();

    writeBytecode(file, MAGIC_NUMBER);
    writeBytecode(file, VERSION);
    writeBytecode(file, instructionCount);
    

    for (const auto& instruction : instructions_) {
      writeBytecode(file, instruction);
    }

    file.close();
    morphl::error::errorManager.addError({"Bytecode saved successfully to " + filename + "\n", morphl::error::Severity::Info});
    return true;
  }
}
