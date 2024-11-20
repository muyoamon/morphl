#ifndef MORPHL_LEXER_H
#define MORPHL_LEXER_H

#include <map>
#include <ostream>
#include <string>
#include <vector>

#define OPERAND_SYMBOL '$'



namespace morphl {

enum TokenType {
  ERROR_,
  // Keywords
  KEYWORD_START,
  ALIAS,
  MORPH,
  IF,
  WHILE,
  OPERATOR_START,
  UN_OPERATOR_START = OPERATOR_START,
  // resolved at compile-time operator
  SIZE,
  TYPE,
  // compile-time operator end
  RETURN,
  
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
  DECL,
  FUNC,
  
  // integer operator
  INT_OPERATOR,
  ADD,
  SUB,
  MUL,
  DIV,
  MOD,
  INT_OPERATOR_END,
  
  // float operator
  FLOAT_OPERATOR,
  FADD,
  FSUB,
  FMUL,
  FDIV,
  FLOAT_OPERATOR_END,
  
  // string operator
  STR_OPERATOR,
  CONCAT,
  SUBSTR, // expect <str> <int> where int is the number of char to be SUBSTR
  STRMUL, // expect <str> <int> where int is the time string to be multiple 
          // e.g. STRMUL "abc" 2 -> "abcabc"
  STR_OPERATOR_END,
  
  // binary operator
  BIN_OPERATOR,
  BAND,
  BOR,
  SHIFTL,
  SHIFTR,
  LSHIFTR, // logical right shift
  BIN_OPERATOR_END,

  // logical operator
  LOGIC_OPERATOR,
  AND,
  OR,
  LOGIC_OPERATOR_END,

  // block operator, if applicable, should be resolved at compile-time
  BLOCK_OPERATOR,
  EXTEND,
  PROJECT,
  MAP,
  BLOCK_OPERATOR_END,

  // comparison operator
  CMP_OPERATOR,
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
  INT_LITERAL,
  FLOAT_LITERAL,
  STRING_LITERAL,
  LITERAL_END,
  // others
  EOF_

};

struct Token {
  TokenType type;
  std::string value;
  size_t row_{};
  size_t col_{};
  
  Token(TokenType type, const std::string& value) : type(type), value(value) {}
  Token(TokenType type, const std::string& val, size_t row, size_t col)
    : type(type), value(val), row_(row), col_(col) {}
};

bool operator==(const Token lhs, const Token rhs);
bool operator!=(const Token lhs, const Token rhs);
std::ostream& operator<<(std::ostream& ostr, const Token t);

class Lexer {
  private:
    static std::map<std::string, TokenType> tokenMap;
    std::vector<Token> tokens_;
    std::string input_;
    size_t currentPosition_;
    size_t rowNum_;
    size_t currentRowStartPos_;
    
    void tokenize();
    TokenType checkKeyword(const std::string& token);
  public:
    static std::string getTokenTypeName(const TokenType);
    Lexer(const std::string& input);
    Token nextToken();
    std::vector<Token> tokens() const;
};

bool isBinaryOperator(Token& token);
bool isUnaryOperator(Token& token);

template<typename T>
std::string tokensString(T tokens) {
  std::string res;
  for (auto& i:tokens) {
    res += i.value;
  }
  return res;
}


}

#endif // !MORPHL_LEXER_H
