#include "Lexer.h"
#include "Token.h"
#include <algorithm>
#include <bitset>
#include <cctype>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <sys/types.h>
#include <limits>
#include <vector>
namespace interpreter {

  std::string CORE_PATH = "/home/tomi/tomi/projects/morphl/core/core.mpg";

Lexer::Lexer(std::istream& file) : m_inputStream(file) {
  m_tokens = std::vector<Token>();
  m_ignoreWSpace = true;
  m_useCore = true;
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
  while (it != str.end()) {
    std::string value = "";
    // number
    if (isdigit(*it)) {
      std::string::iterator jt;
      for (jt = it; jt != str.end(); jt++) {
        if (isdigit(*jt)) {
          value += *jt;
        } else {
          break;
        }
      }
      if (value.length() == 1) {
        m_baseTokens.push_back({BasicTokenType::DIGIT, value});
      } else {
        m_baseTokens.push_back({BasicTokenType::NUMBER, value});
      }
      it = jt;
    } else if (isalpha(*it)) {
      std::string::iterator jt;
      for (jt = it; jt != str.end(); jt++) {
        if (isalnum(*jt)) {
          value += *jt;
        } else {
          break;
        }
      }
      if (value.length() == 1) {
        m_baseTokens.push_back({BasicTokenType::ALPHA, std::string(1, *it)});
      } else {
        m_baseTokens.push_back({BasicTokenType::IDENTIFIER, value});
      }
      it = jt;
    } else if (isLPar(*it)) {
      m_baseTokens.push_back({BasicTokenType::LPAR, std::string(1, *it)});
      it++;
    } else if (isRPar(*it)) {
      m_baseTokens.push_back({BasicTokenType::RPAR, std::string(1, *it)});
      it++;
    } else if (isspace(*it)) {
      m_baseTokens.push_back({BasicTokenType::WSPACE, std::string(1, *it)});
      it++;
    } else {
      m_baseTokens.push_back({BasicTokenType::OTHER, std::string(1, *it)});
      it++;
    }
  }

  if (m_useCore) {
    std::string syntax;
    std::ifstream coreSyntax(CORE_PATH);
    while(std::getline(coreSyntax, syntax, ';')) {
      loadSyntax(syntax);
    }
  }

  return 1;
}

bool Lexer::loadSyntax(std::string str) {
  std::stringstream ss(str);
  int type,group;
  Syntax syntax;
  std::string tokenGroup;
  std::string tokenType;
  std::string syntaxString;
  ss >> tokenGroup >> tokenType;
  type = tokenTypeAppend(tokenType);
  group = tokenGroupAppend(tokenGroup);
  if (type == -1 || group == -1) {
    return 0;
  }
  ss.ignore(std::numeric_limits<std::streamsize>::max(),'"');
  while (std::getline(ss, syntaxString, ',')) { 
    m_syntaxes.push_back(readSyntax(type, group, syntaxString));
    ss.ignore(std::numeric_limits<std::streamsize>::max(),'"');
  }
  return 1;
}

int Lexer::tokenTypeAppend(std::string str) {
  for (int i = 0; i < UINT16_MAX; i++) {
    if (tokenTypes[i] == str) {
      break;
    } else if (tokenTypes[i] == "") {
      tokenTypes[i] = str;
      return i;
    }
  }
  return -1;
}
int Lexer::tokenGroupAppend(std::string str) {
  for (int i = 0; i < UINT16_MAX; i++) {
    if (tokenGroups[i] == str) {
      return i;
    } else if (tokenGroups[i] == "") {
      tokenGroups[i] = str;
      return i;
    }
  }
  return -1;
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

std::vector<BasicToken> Lexer::getTokens() const { return m_baseTokens; }

Token Lexer::getToken(size_t i) const { return m_tokens[i]; }

std::vector<Syntax> Lexer::getSyntaxes() const {return m_syntaxes;}

bool isLPar(char c, std::string others) {
  std::string list = "<[{(";
  list.append(others);
  bool valid = false;
  for (int i = 0; i < list.length(); i++) {
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
  for (int i = 0; i < list.length(); i++) {
    if (list[i] == c) {
      valid = true;
    }
  }
  return valid;
}

std::ostream& operator<<(std::ostream& ostr, Lexer& l) {
  std::vector<BasicToken> tokens = l.getTokens();
  for (std::vector<BasicToken>::iterator it = tokens.begin();
       it != tokens.end(); it++) {
    ostr << (int)it->type;
    ostr << " | ";
    ostr << it->value << std::endl;
  }
  ostr << "Syntaxes:\n";
  for (auto i:l.getSyntaxes()) {
    ostr << i;
  }
  return ostr;
}

std::ostream& operator<<(std::ostream& ostr, Syntax s) {
  ostr << tokenGroups[s.group.to_ulong()] << " | ";
  ostr << tokenTypes[s.type.to_ulong()] << ": ";
  for (auto i:s.syntax) {
    ostr << "{" << tokenGroups[i.first.to_ulong()] << "|";
    ostr << i.second << "},";
  }
  ostr << "\b \b\n";
  return ostr;
}


bool operator<(Syntax lhs, Syntax rhs) {
  return lhs.type.to_ulong() < rhs.type.to_ulong();
}

Syntax Lexer::readSyntax(uint16_t type, uint16_t group, std::string str) {
  Syntax result = {{},type,group};
  std::cout << "reading Syntax \"" << str << "...\n";
  for (int i = 0; i < str.length(); i++) {
    std::string value = "";
    if (str[i] == '"') {
      break;
    } else if (str[i] == '\\') {
      result.syntax.push_back(
          std::pair<std::bitset<16>, std::string>(0, std::string(1, str[++i])));
    } else if (isdigit(str[i])) {
      int j;
      for (j = i; j < str.length(); j++) {
        if (isdigit(str[j])) {
          value += str[j];
        } else {
          break;
        }
      }
      result.syntax.push_back({0, value});
      i = j;
    } else if (isalpha(str[i])) {
      int j;
      for (j = i; j < str.length(); j++) {
        if (isalnum(str[j])) {
          value += str[j];
        } else {
          break;
        }
      }
      result.syntax.push_back({0, value});
      i = j;
    } else if (str[i] == '$') {
      int j = i + 2;
      while (str[j] != '}') {
        value += str[j];
        j++;
      }
      result.syntax.push_back(
          {std::distance(
               tokenGroups.begin(),
               std::find(tokenGroups.begin(), tokenGroups.end(), value)),
           std::string()});
      i = j;
    } else {
      result.syntax.push_back({0,std::string(1, str[i])});
    }
  }
  return result;
}

} // namespace interpreter
