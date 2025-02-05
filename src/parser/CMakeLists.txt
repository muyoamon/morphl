add_library(morphl_parser SHARED 
  syntax.h 
  parser.cpp 
  parser.h 
  scope.h 
  scope.cpp 
  macro.h 
  macro.cpp
  macroManager.h
  macroManager.cpp
  error.h
  importManager.h 
  importManager.cpp
)
target_link_libraries(${PROJECT_NAME} INTERFACE morphl_parser)

