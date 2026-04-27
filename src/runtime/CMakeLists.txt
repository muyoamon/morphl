add_library(morphl_runtime
  vm_runtime.c
  vm_linker.c
  vm_native.c
  vm_stdlib_io.c
)

target_include_directories(morphl_runtime PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(morphl_runtime PRIVATE ${CMAKE_DL_LIBS})
