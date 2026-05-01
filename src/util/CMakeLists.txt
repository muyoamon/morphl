add_library(morphl_util
  util.c
  file.c
  error.c
  fs.c
)

set_target_properties(morphl_util PROPERTIES
  POSITION_INDEPENDENT_CODE ON
)

target_include_directories(morphl_util PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)
