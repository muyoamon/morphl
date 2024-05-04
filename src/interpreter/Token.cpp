#include "Token.h"
#include <cstdint>
#include <string>
#include <array>
namespace interpreter {

  std::array<std::string, UINT16_MAX> tokenTypes = {"ANY", "WSPACE", "DIGIT", "NUMBER", "ALPHA",
                                              "LPAR",   "RPAR", "IDENTIFIER",   "OTHER"};
  std::array<std::string, UINT16_MAX> tokenGroups = {"NONE", "WSPACE", "DIGIT", "NUMBER", "ALPHA",
                                               "LPAR",   "RPAR", "IDENTIFIER",   "OTHER"};
  Token::Token () {
    m_type = {"",0,0};
    m_value = "";
  }
  Token::Token(TokenType type, std::string value) {
    m_type = type;
    m_value = value;
  }

  TokenType Token::getType() const {
    return m_type;
  }

  std::string Token::getValue() const {
    return m_value;
  }

}
