add_library(morphl_util
  util.c
  file.c
)

target_include_directories(morphl_util PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(morphlc PRIVATE morphl_util)
