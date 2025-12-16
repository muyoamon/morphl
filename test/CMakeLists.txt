add_executable(parser_tests
  parser_tests.cpp
)

target_include_directories(parser_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(parser_tests PRIVATE
  morphl_parser
  morphl_lexer
  morphl_util
)

add_test(NAME parser_tests COMMAND parser_tests)
