#ifndef MORPHL_PARSER_SYNTAX_H
#define MORPHL_PARSER_SYNTAX_H

#include <string>
#include <vector>
#include "../lexer/lexer.h"
namespace morphl {
namespace parser {

using SyntaxElement = Token;
using Syntax = std::vector<SyntaxElement>;



}
}

#endif // !MORPHL_PARSER_SYNTAX_H

