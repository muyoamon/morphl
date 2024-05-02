#include "Token.h"
#include <string>
namespace interpreter {

  Token::Token () {
    m_type = TokenType::UNKNOWN;
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
