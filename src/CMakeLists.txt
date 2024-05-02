add_executable(${PROJECT_NAME} main.cpp)

file(GLOB sources
  "${CMAKE_SOURCE_DIR}/src/*[!.txt]/"
  )
foreach(i IN ITEMS ${sources})
  IF(IS_DIRECTORY ${i})
    add_subdirectory(${i})
    target_include_directories(${PROJECT_NAME} PRIVATE ${i}) 
    message(STATUS ${i})
  endif()
endforeach()
