add_library(morphl_ast
  ast.c
)

target_include_directories(morphl_ast PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)

