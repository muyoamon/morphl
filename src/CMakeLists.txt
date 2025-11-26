# --- Define executable ---
add_executable(morphlc main.c)

target_include_directories(morphlc PUBLIC
  ${CMAKE_SOURCE_DIR}/include
)


file(GLOB sources
  LIST_DIRECTORIES true
  "${CMAKE_SOURCE_DIR}/src/*"
  )
foreach(i IN ITEMS ${sources})
  IF(IS_DIRECTORY ${i})
    add_subdirectory(${i})
    message(STATUS ${i})
  endif()
endforeach()




