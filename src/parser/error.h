#ifndef MORPHL_PARSER_ERROR_H
#define MORPHL_PARSER_ERROR_H

#include "../error/error.h"
#include "../lexer/lexer.h"
#include <string>
namespace morphl {

class UnexpectedTokenError : public error::Error {
public:
  UnexpectedTokenError(const std::string &filename, Token actual,
                       Token expected)
      : Error(filename, actual.row_, actual.col_, error::Severity::Critical,
              error::formatString("Unexpected Token, expected: '%', got: '%'\n",
                                  expected.value, actual.value)) {}
  UnexpectedTokenError(const std::string &filename, Token get)
    : Error(filename, get.row_, get.col_, error::Severity::Critical,
        error::formatString("Unexpected Token: %\n", get)) {}
};

class TokenGeneralError : public error::Error {
public:
};

} // namespace morphl

#endif // MORPHL_PARSER_ERROR_H
