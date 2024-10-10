#include "lexer.h"
#include "parser.h"
#include <iostream>
#include <ostream>
int main (int argc, char *argv[]) {
  if (argc > 1) {
    for (auto i=1;i<argc;i++) {
      morphl::Lexer lexer(argv[i]);
      morphl::Parser parser(argv[i]);
      for (auto& i:lexer.tokens()) {
        std::cout << i << std::endl;
      }
      parser.parse();
      parser.printNode();
    }
  }


  return 0;
}
