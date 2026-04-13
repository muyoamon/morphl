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
add_executable(typing_tests
  typing_tests.cpp
)

target_include_directories(typing_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(typing_tests PRIVATE
  morphl_typing
  morphl_parser
  morphl_lexer
  morphl_util
)

add_test(NAME typing_tests COMMAND typing_tests)

add_executable(frame_tests
  frame_tests.cpp
)

target_include_directories(frame_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(frame_tests PRIVATE
  morphl_backend
  morphl_util
)

add_test(NAME frame_tests COMMAND frame_tests)

add_executable(vm_tests
  vm_tests.cpp
)

target_include_directories(vm_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(vm_tests PRIVATE
  morphl_runtime
  morphl_util
)

add_test(NAME vm_tests COMMAND vm_tests)

add_executable(vm_integration_tests
  vm_integration_tests.cpp
)

target_include_directories(vm_integration_tests PRIVATE
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(vm_integration_tests PRIVATE
  morphl_backend
  morphl_typing
  morphl_parser
  morphl_lexer
  morphl_runtime
  morphl_ast
  morphl_util
)

add_test(NAME vm_integration_tests COMMAND vm_integration_tests)