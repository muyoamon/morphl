#include "lexer.h"
#include "parser.h"
#include "config.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <ostream>
#include <sstream>
#include <string>

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

  return 0;
}
