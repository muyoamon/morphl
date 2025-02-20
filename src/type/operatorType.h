#ifndef MORPHL_TYPE_OPERATORTYPE_H
#define MORPHL_TYPE_OPERATORTYPE_H

#include "../lexer/lexer.h"
#include "type.h"
#include <functional>
#include <unordered_map>

namespace morphl {
namespace type {
using ReturnTypeFn = std::function<const TypePtr(TypePtr, TypePtr)>;
struct OperatorType {
  const TypePtr operand1_{};
  const TypePtr operand2_{};
  const ReturnTypeFn returnType_;
};

using OperatorTypeMap = std::unordered_map<TokenType, OperatorType>;
const extern OperatorTypeMap operatorTypeMap;

} // namespace type
} // namespace morphl

#endif // MORPHL_TYPE_OPERATORTYPE_H
