add_library(morphl_parser
  parser.c
)

target_link_libraries(morphl_parser PUBLIC morphl_util morphl_ast)
target_link_libraries(morphlc PRIVATE morphl_parser)
