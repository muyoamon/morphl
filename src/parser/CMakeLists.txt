add_library(morphl_parser SHARED 
  parser.cpp 
  parser.h 
  scope.h 
  scope.cpp 
  macro.h 
  macro.cpp
  macroManager.h
  macroManager.cpp
  error.h
)
target_link_libraries(${PROJECT_NAME} INTERFACE morphl_parser)

