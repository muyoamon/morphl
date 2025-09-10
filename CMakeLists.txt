cmake_minimum_required(VERSION 3.28)
project(morphl C)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_BUILD_TYPE Debug)

find_package(Catch2 CONFIG REQUIRED)




add_subdirectory(src/)
if (CMAKE_BUILD_TYPE STREQUAL "Debug")
  include(Catch)
  include(CTest)
  add_subdirectory(test/)
endif()
