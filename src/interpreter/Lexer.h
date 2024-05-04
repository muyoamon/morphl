#ifndef INTERPRETER_LEXER_H
#define INTERPRETER_LEXER_H
#include "Token.h"
#include <array>
#include <bitset>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <functional>
#include <iostream>
#include <set>
#include <string>
#include <sys/types.h>
#include <vector>
namespace interpreter {


  extern std::string CORE_PATH;
enum class BasicTokenType {
  UNKNOWN,
  WSPACE,
  DIGIT,
  NUMBER,
  ALPHA,
  LPAR,
  RPAR,
  IDENTIFIER,
  OTHER,
};

struct Syntax {
  std::vector<std::pair<std::bitset<16>,std::string>> syntax;
  std::bitset<16> type;
  std::bitset<16> group;
  bool lowPrio;
};

struct SyntaxHash {
    std::size_t operator() (const Syntax& s) const {
      return std::hash<std::bitset<16>>()(s.type);
    }
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
  Syntax readSyntax(u_int16_t size, u_int16_t group, std::string);
  std::vector<Syntax> getSyntaxes() const;

private:
  const std::istream& m_inputStream;
  std::vector<Token> m_tokens;
  std::vector<BasicToken> m_baseTokens;
  bool m_ignoreWSpace;
  bool m_useCore;
  std::vector<Syntax> m_syntaxes;
  /// convert baseToken to Token;
  bool toToken();
  bool loadSyntax(std::string str);
  int tokenTypeAppend(std::string str);
  int tokenGroupAppend(std::string str);
};

bool isLPar(char, std::string = "");
bool isRPar(char, std::string = "");


bool operator<(Syntax lhs, Syntax rhs);

std::ostream& operator<<(std::ostream& ostr, Lexer& l);
std::ostream& operator<<(std::ostream& ostr, Syntax s);

bool matchSyntax(std::vector<Token> v, Syntax s, bool ignoreWhsp=true);

} // namespace interpreter

#endif // !INTERPRETER_LEXER_H
