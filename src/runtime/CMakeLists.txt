add_library(morphl_runtime
  vm_runtime.c
)

target_include_directories(morphl_runtime PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)
