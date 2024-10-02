#ifndef MORPHL_LEXER_H
#define MORPHL_LEXER_H

#include <map>
#include <ostream>
#include <string>
#include <vector>

namespace morphl {

enum TokenType {
  ERROR_,
  // Keywords
  KEYWORD_START,
  ALIAS = KEYWORD_START,
  MORPH,
  IF,
  WHILE,
  RETURN,
  OPERATOR_START,
  UN_OPERATOR_START = OPERATOR_START,
  // resolved at compile-time operator
  SIZE,
  TYPE,
  // compile-time operator end
  NEG, // flip the sign, undefined for unsign
  FNEG,
  BNOT, // flip all bits
  NOT,
  SHADOW,
  UN_OPERATOR_END,

  //Operators
  BI_OPERATOR_START,
  ASSIGN,
  CALL,
  
  
  // integer operator
  INT_OPERATOR,
  ADD = INT_OPERATOR,
  SUB,
  MUL,
  DIV,
  MOD,
  INT_OPERATOR_END = MOD,
  
  // float operator
  FLOAT_OPERATOR,
  FADD = FLOAT_OPERATOR,
  FSUB,
  FMUL,
  FDIV,
  FLOAT_OPERATOR_END = FDIV,
  
  // string operator
  STR_OPERATOR,
  CONCAT = STR_OPERATOR,
  SUBSTR, // expect <str> <int> where int is the number of char to be SUBSTR
  STRMUL, // expect <str> <int> where int is the time string to be multiple 
          // e.g. STRMUL "abc" 2 -> "abcabc"
  STR_OPERATOR_END = STRMUL,
  
  // binary operator
  BIN_OPERATOR,
  BAND = BIN_OPERATOR,
  BOR,
  SHIFTL,
  SHIFTR,
  LSHIFTR, // logical right shift
  BIN_OPERATOR_END = LSHIFTR,

  // logical operator
  LOG_OPERATOR,
  AND = LOG_OPERATOR,
  OR,
  LOG_OPERATOR_END = OR,

  // block operator, if applicable, should be resolved at compile-time
  BLOCK_OPERATOR,
  EXTEND = BLOCK_OPERATOR,
  PROJECT,
  MAP,

  // comparison operator
  EQ,
  NE,
  LT,
  GT,
  LE,
  GE,
  CMP_OPERATOR_END = GE,
  BI_OPERATOR_END = CMP_OPERATOR_END,
  OPERATOR_END = CMP_OPERATOR_END,
  KEYWORD_END = OPERATOR_END,
  // delimiters
  LPAREN,
  RPAREN,
  LBRACE,
  RBRACE,
  STEND,
  STPRINT,
  COMMA,
  COLON,
  // identifiers
  IDENTIFIER,
  SYMBOL,
  OPERAND,
  // literals
  LITERAL_START,
  INT_LITERAL = LITERAL_START,
  FLOAT_LITERAL,
  STRING_LITERAL,
  LITERAL_END = STRING_LITERAL,
  // others
  EOF_

};

struct Token {
  TokenType type;
  std::string value;
  
  Token(TokenType type, const std::string& value) : type(type), value(value) {}
};

bool operator==(const Token lhs, const Token rhs);
std::ostream& operator<<(std::ostream& ostr, const Token t);

class Lexer {
  public:
    Lexer(const std::string& input);
    Token nextToken();
    std::vector<Token> tokens() const;
  private:
    static std::map<std::string, TokenType> tokenMap;
    void tokenize();
    TokenType checkKeyword(const std::string& token);
    std::vector<Token> tokens_;
    std::string input_;
    size_t currentPosition_;
};

bool isBinaryOperator(Token& token);
bool isUnaryOperator(Token& token);


}

#endif // !MORPHL_LEXER_H
