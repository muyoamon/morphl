#include "instruction.h"
#include "lexer.h"
#include "parser.h"
#include "config.h"
#include "vm.h"
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <ostream>
#include <sstream>
#include <string>
#include <vector>
#include <dlfcn.h>

using morphl::config::readConfig;
using morphl::config::gConfig;

int main(int argc, const char *argv[]) {
  readConfig(morphl::config::gConfig, argc, argv);
  
  if (gConfig.help) {
    //TODO: write help message
    exit(0);
  } 
  
  if (gConfig.inFile != "") {
    morphl::parser::Parser parser(gConfig.inFile);
    parser.parse();

    parser.printNode();
  }

  // TEST
  std::cout << "\n\n\n VM TEST \n";
  auto lib_handle = dlopen("libc.so.6", RTLD_LAZY);
  if (!lib_handle) {
    return -1;
  }
  void* puts_fn = dlsym(lib_handle, "puts");
  if (!puts_fn) {
    dlclose(lib_handle);
    return -1;
  }

  const char* msg = "Hello World!\n";
  std::vector<uint8_t> intrs{
    vm::LOADI, vm::RRET, 0, 0, 0, 0, 0, 0, 0, 0,    // loadi ret 0
    vm::PUSHI, 0, 0, 0, 0, 0, 0, 0, 0, 
    vm::CALLC,                          // callc
    0,0,0,0,0,0,0,0,                    // function ptr placeholder
    vm::C_INT,                          // return int
    1,                                  // 1 argument
    vm::C_CHARPTR,                      // take char* as arg
    vm::LOADI, vm::RRET, 0, 0, 0, 0, 0, 0, 0, 0,
    vm::MOV, vm::RSTACK, vm::RFRAME,
    vm::LOADI, 1, 13, 0, 0, 0, 0, 0, 0, 0,
    vm::ADD, 1, vm::RPROG, 1,
    vm::JM, 84, 0, 0, 0, 0, 0, 0, 0,
    // function fibonacci
    // setup(41)
    vm::LOADI, 2, 8, 0, 0, 0, 0, 0, 0, 0, // 10
    vm::SUB, 2, vm::RFRAME, 2,            // 4
    vm::LOAD, 2, 2,                       // 3  
    vm::LOADI, 3, 1, 0, 0, 0, 0, 0, 0, 0, // 10
    vm::SUB, 4, 2, 3,                     // 4
    vm::JP, 4, 4,0,0,0, 0,0,0,0,           // 10
    // basecase (4) 
    vm::MOV, vm::RRET, 2,                 // 3
    vm::RET,                              // 1
    // main loop (39)
    vm::SUB, 4, 2, 3,                     // 4
    vm::LOADI, 6, 8, 0, 0, 0, 0, 0, 0, 0, // 10
    vm::PUSH, 4,                          // 2
    vm::CALL, 1,                          // 2
    vm::POP, 4,                           // 2
    vm::PUSH, vm::RRET,                   // 2
    vm::SUB, 4, 4, 3,                     // 4
    vm::PUSH, 4,                          // 2
    vm::CALL, 1,                          // 2
    vm::POP, 5,                           // 2
    vm::POP, 5,                           // 2 
    vm::ADD, vm::RRET, 5, vm::RRET,       // 4
    vm::RET,                              // 1


    vm::PUSHI, 10, 0, 0, 0, 0, 0, 0, 0,
    vm::CALL, 1,
    vm::SUB, vm::RSTACK, vm::RSTACK, 6,   // 4
    vm::HALT                            // halt
  };
  *(uint64_t*)(intrs.data() + 11) = reinterpret_cast<uint64_t>(msg);
  *(uint64_t*)(intrs.data() + 20) = reinterpret_cast<uint64_t>(puts_fn);
  vm::VM runtime;
  auto res = runtime.execute(intrs);
  std::cout << "vm returned " << std::to_string(res) << "\n";

  dlclose(lib_handle);
  return 0;
}
