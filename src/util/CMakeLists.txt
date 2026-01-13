add_library(morphl_util
  util.c
  file.c
  error.c
  fs.c
)

target_include_directories(morphl_util PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)

