#ifndef INTERPRETER_LEXER_H
#define INTERPRETER_LEXER_H
#include "Token.h"
#include <bitset>
#include <cstddef>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
namespace interpreter {

enum class BasicTokenType {
  UNKNOWN,
  WSPACE,
  NUMBER,
  ALPHA,
  STRING,
  LPAR,
  RPAR,
  OTHER
};

struct Syntax {
  std::string syntax;
  std::bitset<16> type;
};


struct BasicToken {
  BasicTokenType type;
  std::string value;
};

class Lexer {
public:
  Lexer(std::istream& file = std::cin);
  Lexer(Lexer&) = delete;
  Lexer& operator=(Lexer&) = delete;
  bool tokenize();
  bool tokenize(std::string& line);
  std::vector<BasicToken> getTokens() const;
  Token getToken(size_t i) const;
  bool ignoreWSpace(bool);
  bool useCore(bool);

private:
  const std::istream& m_inputStream;
  std::vector<Token> m_tokens;
  std::vector<BasicToken> m_baseTokens;
  bool m_ignoreWSpace = true;
  bool m_useCore = true;
  
  /// convert baseToken to Token;
  bool toToken();
};

bool isLPar(char, std::string = "");
bool isRPar(char, std::string = "");


std::ostream& operator<<(std::ostream& ostr, Lexer& l);
} // namespace interpreter

#endif // !INTERPRETER_LEXER_H
