add_library(morphl_type SHARED 
  type.h 
  type.cpp
  operatorType.h
  operatorType.cpp
)
target_link_libraries(${PROJECT_NAME} INTERFACE morphl_type)

