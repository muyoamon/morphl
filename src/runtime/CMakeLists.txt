add_library(morphl_runtime
  vm_runtime.c
  vm_linker.c
  vm_native.c
)

target_include_directories(morphl_runtime PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(morphl_runtime PRIVATE ${CMAKE_DL_LIBS})

target_compile_definitions(morphl_runtime PRIVATE
  MORPHL_STD_NATIVE_DIR="${CMAKE_BINARY_DIR}/std"
)

add_library(morphl_std_io SHARED
  std_io_module.c
)

set_target_properties(morphl_std_io PROPERTIES
  PREFIX ""
  OUTPUT_NAME "io"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/std"
)

target_include_directories(morphl_std_io PRIVATE
  ${CMAKE_SOURCE_DIR}/include
)
