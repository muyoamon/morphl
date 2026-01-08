add_library(morphl_typing
  typing.c
  type_context.c
  inference.c
)

target_include_directories(morphl_typing PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(morphl_typing
  morphl_util
)
