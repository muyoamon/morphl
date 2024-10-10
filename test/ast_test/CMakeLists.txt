add_executable(ast_test ast_test.cpp)
target_link_libraries(ast_test PRIVATE morphl Catch2::Catch2WithMain)

