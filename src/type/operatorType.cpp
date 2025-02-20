#include "operatorType.h"
#include "type.h"
#include <memory>
namespace morphl {
namespace type {


template<const TypePtr& ret>
static const ReturnTypeFn returnType = [](TypePtr a, TypePtr b) { return ret; };


static const ReturnTypeFn returnFirstOperandType = [](TypePtr a, TypePtr b) { return a;};


const OperatorTypeMap operatorTypeMap{
    {NEG, {PrimitiveType::INTEGER, nullptr, returnType<PrimitiveType::INTEGER>}},
    {FNEG, {PrimitiveType::FLOAT, nullptr, returnType<PrimitiveType::FLOAT>}},
    {BNOT, {nullptr, nullptr, returnFirstOperandType}},
    {NOT, {nullptr, nullptr, returnType<PrimitiveType::INTEGER>}},
    {EQ, {nullptr, nullptr, returnType<PrimitiveType::INTEGER>}},
    {NE, {nullptr, nullptr, returnType<PrimitiveType::INTEGER>}},
    {LT, {nullptr, nullptr, returnType<PrimitiveType::INTEGER>}},
    {LE, {nullptr, nullptr, returnType<PrimitiveType::INTEGER>}},
    {GT, {nullptr, nullptr, returnType<PrimitiveType::INTEGER>}},
    {GE, {nullptr, nullptr, returnType<PrimitiveType::INTEGER>}},
    {ADD, {PrimitiveType::INTEGER, PrimitiveType::INTEGER, returnType<PrimitiveType::INTEGER>}},
    {SUB, {PrimitiveType::INTEGER, PrimitiveType::INTEGER, returnType<PrimitiveType::INTEGER>}},
    {MUL, {PrimitiveType::INTEGER, PrimitiveType::INTEGER, returnType<PrimitiveType::INTEGER>}},
    {DIV, {PrimitiveType::INTEGER, PrimitiveType::INTEGER, returnType<PrimitiveType::INTEGER>}},
    {MOD, {PrimitiveType::INTEGER, PrimitiveType::INTEGER, returnType<PrimitiveType::INTEGER>}},
    {FADD, {PrimitiveType::FLOAT, PrimitiveType::FLOAT, returnType<PrimitiveType::FLOAT>}},
    {FSUB, {PrimitiveType::FLOAT, PrimitiveType::FLOAT, returnType<PrimitiveType::FLOAT>}},
    {FMUL, {PrimitiveType::FLOAT, PrimitiveType::FLOAT, returnType<PrimitiveType::FLOAT>}},
    {FDIV, {PrimitiveType::FLOAT, PrimitiveType::FLOAT, returnType<PrimitiveType::FLOAT>}},
    {CONCAT, {PrimitiveType::STRING, PrimitiveType::STRING, returnType<PrimitiveType::STRING>}},
    {BAND, {nullptr, nullptr, returnFirstOperandType}},
    {BOR, {nullptr, nullptr, returnFirstOperandType}},
    {LSHIFTR, {nullptr, nullptr, returnFirstOperandType}},
    {SHIFTR, {nullptr, nullptr, returnFirstOperandType}},
    {SHIFTL, {nullptr, nullptr, returnFirstOperandType}},
    {DECL, {nullptr, nullptr, returnFirstOperandType}},
    {EXTEND, {nullptr, nullptr, returnFirstOperandType}},
    {ASSIGN, {nullptr, nullptr, returnFirstOperandType}},
    {RETURN, {nullptr, nullptr, returnFirstOperandType}},
    {morphl::CONST, {nullptr, nullptr, returnFirstOperandType}},
    {morphl::REF, {nullptr, nullptr, returnFirstOperandType}},
    {MUT, {nullptr, nullptr, returnFirstOperandType}},
};
}
} // namespace morphl
