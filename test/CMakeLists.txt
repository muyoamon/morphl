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

add_executable(error_tests
  error_tests.cpp
)

target_include_directories(error_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(error_tests PRIVATE
  morphl_util
)

add_test(NAME error_tests COMMAND error_tests)
