add_library(morphl_lexer
  lexer.c
)
target_link_libraries(morphl_lexer PUBLIC morphl_util)
target_link_libraries(morphlc PRIVATE morphl_lexer)
