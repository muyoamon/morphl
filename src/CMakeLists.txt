add_executable(morphlc main.cpp)
add_library(${PROJECT_NAME} INTERFACE)


file(GLOB sources
  LIST_DIRECTORIES true
  "${CMAKE_SOURCE_DIR}/src/*"
  )
foreach(i IN ITEMS ${sources})
  IF(IS_DIRECTORY ${i})
    add_subdirectory(${i})
    target_include_directories(${PROJECT_NAME} INTERFACE ${i}) 
    message(STATUS ${i})
  endif()
endforeach()

target_link_libraries(morphlc PRIVATE ${PROJECT_NAME})
