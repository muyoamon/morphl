#ifndef INTERPRETER_TOKEN_H
#define INTERPRETER_TOKEN_H
#include <bitset>
#include <string>
namespace interpreter {
struct TokenType {
  std::string name;
  std::bitset<16> type;
};
  class Token {
public:
  Token();
  Token(TokenType type, std::string value);
  TokenType getType() const;
  std::string getValue() const;
private:
  TokenType m_type;
  std::string m_value;
};

} // namespace interpreter

#endif // !INTERPRETER_TOKEN_H
