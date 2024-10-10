add_library(morphl_parser SHARED parser.cpp parser.h)
target_link_libraries(${PROJECT_NAME} INTERFACE morphl_parser)

