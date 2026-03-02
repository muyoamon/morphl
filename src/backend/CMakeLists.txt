add_library(morphl_backend
  backend.c
  c.c
  vm.c
)

target_include_directories(morphl_backend PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)

