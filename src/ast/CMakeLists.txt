add_library(morphl_ast
  ast.c
)

target_include_directories(morphl_ast PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(morphl_ast PUBLIC morphl_util)

target_link_libraries(morphlc PRIVATE morphl_ast)
