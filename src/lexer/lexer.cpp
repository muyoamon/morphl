#include "lexer.h"
#include <cctype>
#include <iostream>
#include <map>
#include <sstream>
#include <string>

namespace morphl {

  std::map<std::string, TokenType> Lexer::tokenMap = {
    {"ALIAS", ALIAS},
    {"MORPH", MORPH},
    {"IF", IF},
    {"WHILE", WHILE},
    {"RETURN", RETURN},
    {"ASSIGN", ASSIGN},
    {"CALL", CALL},
    {"DECL", DECL},
    {"FUNC", FUNC},
    {"SIZE", SIZE},
    {"TYPE", TYPE},
    {"ADD", ADD},
    {"SUB", SUB},
    {"MUL", MUL},
    {"DIV", DIV},
    {"MOD", MOD},
    {"NEG", NEG},
    {"FADD", FADD},
    {"FSUB", FSUB},
    {"FMUL", FMUL},
    {"FDIV", FDIV},
    {"FNEG", FNEG},
    {"CONCAT", CONCAT},
    {"SUBSTR", SUBSTR},
    {"STRMUL", STRMUL},
    {"BAND", BAND},
    {"BOR", BOR},
    {"SHIFTL", SHIFTL},
    {"SHIFTR", SHIFTR},
    {"LSHIFTR", LSHIFTR},
    {"BNOT", BNOT},
    {"AND", AND},
    {"OR", OR},
    {"NOT", NOT},
    {"EXTEND", EXTEND},
    {"SHADOW", SHADOW},
    {"PROJECT", PROJECT},
    {"MAP", MAP},
    {"EQ", EQ},
    {"NE", NE},
    {"LT", LT},
    {"GT", GT},
    {"LE", LE},
    {"GE", GE},

    // delimiter
    {"LPAREN", LPAREN},
    {"RPAREN", RPAREN},
    {"LBRACE", LBRACE},
    {"RBRACE", RBRACE},
    {"STEND", STEND},
    {"STPRINT", STPRINT},
    {"COMMA", COMMA},
    {"COLON", COLON},
    
    {"IDENTIFIER", IDENTIFIER},
    {"SYMBOL", SYMBOL},
    {"OPERAND", OPERAND},
    {"MEMBER", MEMBER},
    {"IMPORT", IMPORT},
    {"ARR", ARR},
    {"INDEX", INDEX},

  };
  Lexer::Lexer(const std::string& input)
    : input_(input), currentPosition_(0), rowNum_(1), currentRowStartPos_(0) {
      tokenize();
    }

  std::vector<Token> Lexer::tokens() const {
    return this->tokens_;
  }
  TokenType Lexer::checkKeyword(const std::string& token) {
    return tokenMap[token];
  }



  Token Lexer::nextToken() {
    if (currentPosition_ < tokens_.size()) {
        Token token = tokens_[currentPosition_];
        currentPosition_++;
        return token;
    }
    return Token(EOF_, ""); 
  }

  void Lexer::tokenize() {
    // skip comment
    if (input_[currentPosition_] == '/') {
      currentPosition_++;
      if (currentPosition_ < input_.size() && input_[currentPosition_] == '/') {
        currentPosition_++;
        // ignore until new line
        while (currentPosition_ < input_.size() && input_[currentPosition_] != '\n') {
          currentPosition_++;
        }
        return tokenize();
      } else {
        currentPosition_--;
      }
    }
    // Skip whitespace
    while (currentPosition_ < input_.size() && isspace(input_[currentPosition_])) {
        if (input_[currentPosition_] == '\n') {
          rowNum_++;
          currentRowStartPos_ = currentPosition_;
        }
        currentPosition_++;
    }

    if (currentPosition_ >= input_.size()) {
        tokens_.push_back(Token(EOF_, ""));
        return;
    }

    char currentChar = input_[currentPosition_];

    // Handle identifiers
    if (isalpha(currentChar) || currentChar == '_') {
        std::stringstream identifierStream;
        while (currentPosition_ < input_.size() && (isalnum(input_[currentPosition_]) || input_[currentPosition_] == '_')) {
            identifierStream << input_[currentPosition_];
            currentPosition_++;
        }
        std::string identifier = identifierStream.str();
        TokenType type = checkKeyword(identifier);
        if (type == ERROR_) {
            tokens_.push_back(Token(IDENTIFIER, identifier, rowNum_, currentPosition_ - currentRowStartPos_));
        } else {
            tokens_.push_back(Token(type, identifier, rowNum_, currentPosition_ - currentRowStartPos_));
        }
        return tokenize(); // Recursively call tokenize after processing a token
    }

    // Handle literals
    if (isdigit(currentChar)) {
        std::stringstream literalStream;
        while (currentPosition_ < input_.size() && isdigit(input_[currentPosition_])) {
            literalStream << input_[currentPosition_];
            currentPosition_++;
        }
        if (currentPosition_ < input_.size() && input_[currentPosition_] == '.') {
          literalStream << input_[currentPosition_];
          currentPosition_++;
          while (currentPosition_ < input_.size() && isdigit(input_[currentPosition_])) {
            literalStream << input_[currentPosition_];
            currentPosition_++;
          }
          tokens_.push_back(Token(FLOAT_LITERAL,literalStream.str(), rowNum_, currentPosition_ - currentRowStartPos_));
        } else {
          tokens_.push_back(Token(INT_LITERAL, literalStream.str(), rowNum_, currentPosition_ - currentRowStartPos_));
        }
        std::string literal = literalStream.str();
        return tokenize(); // Recursively call tokenize after processing a token
    }

    // Handle string literal
    if (currentChar == '"') {
      std::stringstream stringStream;
      currentPosition_++;
      while (currentPosition_ < input_.size() && input_[currentPosition_] != '"') {
        stringStream << input_[currentPosition_];
        currentPosition_++;
      }
      if (currentPosition_ < input_.size()) {
        currentPosition_++; // Skip closing quote
        tokens_.push_back(Token(STRING_LITERAL, stringStream.str(), rowNum_, currentPosition_ - currentRowStartPos_));
      } else {
        std::cerr << "Error: Unterminated string literal" << std::endl;
      }
      return tokenize();
    }
    
    // handle operand
    if(currentChar == OPERAND_SYMBOL) {
      //will treat any string until whitespace as operand name
      std::stringstream ss;
      currentPosition_++;
      if (!isspace(input_[currentPosition_])) {
        while (currentPosition_ < input_.size() 
            && !isspace(input_[currentPosition_]) && isalnum(input_[currentPosition_])) {
          ss << input_[currentPosition_];
          currentPosition_++;
        }
        tokens_.push_back(Token(OPERAND, ss.str(), rowNum_, currentPosition_ - currentRowStartPos_));
        return tokenize();
      }
    }
    
    //handle symbol
    tokens_.push_back(Token(SYMBOL, std::string(1,currentChar), rowNum_, currentPosition_ - currentRowStartPos_));
    currentPosition_++;
    return tokenize();
  }


bool operator==(const Token lhs, const Token rhs) {
  return lhs.type == rhs.type && lhs.value == rhs.value;
}

bool operator!=(const Token lhs, const Token rhs) {
  return !(lhs == rhs);
}

std::ostream& operator<<(std::ostream& ostr, const Token t) {
  ostr << "{type: " << t.type << ", value: \"" << t.value << "\"}";
  return ostr;
}

bool isBinaryOperator(Token& token) {
  return (token.type > TokenType::BI_OPERATOR_START && 
      token.type < TokenType::BI_OPERATOR_END);
}

bool isUnaryOperator(Token &token) {
  return (token.type > TokenType::UN_OPERATOR_START &&
      token.type < TokenType::UN_OPERATOR_END);
}

std::string Lexer::getTokenTypeName(const TokenType t) {
  for (auto& i: tokenMap) {
    if (i.second == t) {
      return i.first;
    }
  }
  return "Unknown Token Type";
}

}
