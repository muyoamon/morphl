#include <catch2/catch_test_macros.hpp>
#include "../../src/parser/parser.h"

TEST_CASE("Parser: Pure Literal", "[parser]") {
    std::string input = "\"Hello World!\"?";
    morphl::Parser parser(input);

    parser.parse();
    // ... (Add more assertions for member nodes)
}

TEST_CASE("Parser: Pure Expression Statement", "[parser]") {
    std::string input = "ADD 5 2?"; 
    morphl::Parser parser(input);

    parser.parse();

    // ... (Add more assertions for the expression node)
}

