add_library(morphl_ast SHARED ast.h ast.cpp)
set_target_properties(morphl_ast PROPERTIES LINKER_LANGUAGE CXX)
target_link_libraries(${PROJECT_NAME} INTERFACE morphl_ast)

