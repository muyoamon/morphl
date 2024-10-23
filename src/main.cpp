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
      std::cout << static_cast<std::string>(parser.getScopeManager());
    }
  }

  /*auto p1 = std::make_shared<morphl::type::PrimitiveType>("int");*/
  /*morphl::type::BlockTypeMembers blockTypeMember = {*/
  /*  {"x",p1},*/
  /*  {"y",p1},*/
  /*  {"z",p1}*/
  /*};*/
  /*morphl::type::GroupTypeMembers groupTypeMember = {p1,p1};*/
  /*auto p2 = std::make_shared<morphl::type::BlockType>(blockTypeMember);*/
  /*auto p3 = std::make_shared<morphl::type::GroupType>(groupTypeMember);*/
  /*auto p4 = std::make_shared<morphl::type::ListType>(p1,8);*/
  /*auto p5 = std::make_shared<morphl::type::FunctionType>(p3, p1);*/
  /*auto p6 = std::make_shared<morphl::type::PseudoFunctionType>(blockTypeMember, p1);*/
  /*std::cout << p1 << std::endl;*/
  /*std::cout << p2 << std::endl;*/
  /*std::cout << p3 << std::endl;*/
  /*std::cout << p4 << std::endl;*/
  /*std::cout << p5 << std::endl;*/
  /*std::cout << p6 << std::endl;*/
  return 0;
}
