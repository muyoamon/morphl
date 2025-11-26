add_library(morphl_lexer
  lexer.c
)
target_link_libraries(morphlc PRIVATE morphl_lexer)
