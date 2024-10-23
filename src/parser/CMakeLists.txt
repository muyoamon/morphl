add_library(morphl_parser SHARED parser.cpp parser.h type.h type.cpp scope.h scope.cpp)
target_link_libraries(${PROJECT_NAME} INTERFACE morphl_parser)

