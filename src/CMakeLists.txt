# --- Define executable ---
add_executable(morphlc main.c)

target_include_directories(morphlc PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(morphlc
  morphl_parser
  morphl_lexer
  morphl_typing
  morphl_ast
  morphl_util
)

add_subdirectory(util)
add_subdirectory(lexer)
add_subdirectory(parser)
add_subdirectory(ast)
add_subdirectory(typing)




