#include "lexer.h"
#include "parser.h"
#include <filesystem>
#include <iostream>
#include <ostream>
#include <string>

int main(int argc, char *argv[]) {
  if (argc == 1) {
    while (true) {
      std::string str;
      std::getline(std::cin, str);
      morphl::Lexer lexer(str);
      morphl::Parser parser(lexer.tokens());
      for (auto &i : lexer.tokens()) {
        std::cout << i << std::endl;
      }
      parser.parse();
      parser.printNode();
      std::cout << static_cast<std::string>(parser.getScopeManager());
    }
  } else if (argc == 2) {
    morphl::Parser parser(std::filesystem::current_path() /= argv[1]);
    parser.parse();
    parser.printNode();
    std::cout << static_cast<std::string>(parser.getScopeManager());
  } else {
    std::cerr << "Invalid usage!\n";
  }

  return 0;
}
