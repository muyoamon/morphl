add_library(morphl_config SHARED config.h config.cpp)
set_target_properties(morphl_config PROPERTIES LINKER_LANGUAGE CXX)
target_link_libraries(${PROJECT_NAME} INTERFACE morphl_config)

