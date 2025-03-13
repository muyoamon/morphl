
add_library(morphl_vm SHARED 
  vm.cpp
  vm.h
  instruction.h 
  serializer.h 
  serializer.cpp
)
find_library(FFI_LIB NAMES ffi PATHS /usr/lib /usr/local/lib REQUIRED)
find_path(FFI_INCLUDE_DIR NAMES ffi.h PATH_SUFFIXES ffi)
target_link_libraries(morphl_vm PRIVATE "${FFI_LIB}")
target_include_directories(morphl_vm PRIVATE "${FFI_INCLUDE_DIR}")
target_link_libraries(${PROJECT_NAME} INTERFACE morphl_vm)

