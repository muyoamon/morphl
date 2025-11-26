# --- Define executable ---
add_executable(morphlc main.c)

target_include_directories(morphlc PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)

add_subdirectory(util)
add_subdirectory(lexer)
add_subdirectory(parser)




