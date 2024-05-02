#include "Lexer.h"
#include "Token.h"
#include <bitset>
#include <cctype>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
namespace interpreter {


  Lexer::Lexer(std::istream& file): m_inputStream(file) {
    m_tokens = std::vector<Token>();
    m_ignoreWSpace = true;
  }

  bool Lexer::tokenize() {
    std::string text;
    if (this->m_inputStream.rdbuf() == std::cin.rdbuf()) {
      std::getline(std::cin, text);
      this->tokenize(text);
    } else {

    }
    return 1;
  }

  bool Lexer::tokenize(std::string& str) {
    std::string::iterator it = str.begin();
    while (it!=str.end()) {
      std::string value = "";
      // number
      if (isdigit(*it )) {
        std::string::iterator jt;
        for (jt=it;jt!=str.end();jt++) {
          if (isdigit(*jt)) {
            value += *jt;
          } else {
            break;
          }
        }
        m_baseTokens.push_back({BasicTokenType::NUMBER,value});
        it = jt;
      } else if (isalpha(*it)){
        m_baseTokens.push_back({BasicTokenType::ALPHA,std::string(1,*it)});
        it++;
      } else if (isLPar(*it)) {
        m_baseTokens.push_back({BasicTokenType::LPAR,std::string(1,*it)});
        it++;
      } else if (isRPar(*it)) {
        m_baseTokens.push_back({BasicTokenType::RPAR,std::string(1,*it)});
        it++;
      } else if (isspace(*it)) {
        m_baseTokens.push_back({BasicTokenType::WSPACE,std::string(1,*it)});
        it++;
      } else  {
        m_baseTokens.push_back({BasicTokenType::OTHER,std::string(1,*it)});
        it++;
      }
    }
    return 1;
  }
  bool Lexer::toToken() {
    std::vector<std::string> grammars;
    std::bitset<256> tokenType;
    for (int i= (int) BasicTokenType::UNKNOWN;i< (int) BasicTokenType::OTHER;i++) {
      
    }
    if (m_useCore) {
      
    }
  }
  bool Lexer::ignoreWSpace(bool value) {
    bool prev = m_ignoreWSpace;
    m_ignoreWSpace = value;
    return prev;
  }
  bool Lexer::useCore(bool value) {
    bool prev = m_useCore;
    m_useCore = value;
    return prev;
  }


  std::vector<BasicToken> Lexer::getTokens() const {
    return m_baseTokens;
  }

  Token Lexer::getToken(size_t i) const {
    return m_tokens[i];
  }

  bool isLPar(char c, std::string others) {
    std::string list = "<[{(";
    list.append(others);
    bool valid = false;
    for (int i=0;i<list.length();i++) {
      if (list[i] == c) {
        valid = true;
      }
    }
    return valid;
  }
  bool isRPar(char c, std::string others) {
    std::string list = ")>}]";
    list.append(others);
    bool valid = false;
    for (int i=0;i<list.length();i++) {
      if (list[i] == c) {
        valid = true;
      }
    }
    return valid;
  }


std::ostream& operator<<(std::ostream& ostr, Lexer& l) {
  std::vector<BasicToken> tokens = l.getTokens();
  for (std::vector<BasicToken>::iterator it=tokens.begin();it!=tokens.end();it++) {
    ostr << (int) it->type;
    ostr << " | ";
    ostr << it->value << std::endl;
  }
  return ostr;
}
}
