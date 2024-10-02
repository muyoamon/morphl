add_library(morphl_lexer SHARED lexer.cpp lexer.h)
target_link_libraries(${PROJECT_NAME} INTERFACE morphl_lexer)

