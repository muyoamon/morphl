file(GLOB interpreter_sources)
add_library(interpreter SHARED Lexer.cpp Lexer.h Token.cpp Token.h)
target_link_libraries(${PROJECT_NAME} PUBLIC interpreter)

