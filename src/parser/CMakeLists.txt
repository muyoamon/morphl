add_library(morphl_parser
  parser.c
  builtin_parser.c
  scoped_parser.c
  operators.c
)

target_link_libraries(morphl_parser PUBLIC morphl_util morphl_ast morphl_typing)
