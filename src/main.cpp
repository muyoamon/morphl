#include "interpreter/Lexer.h"
#include <iostream>
using namespace interpreter;
int main (int argc, char *argv[]) {
  Lexer l;
  l.tokenize();
  std::cout << l;
  return 0;
}
