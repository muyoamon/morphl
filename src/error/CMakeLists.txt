add_library(morphl_error SHARED error.h error.cpp)
set_target_properties(morphl_error PROPERTIES LINKER_LANGUAGE CXX)
target_link_libraries(${PROJECT_NAME} INTERFACE morphl_error)

