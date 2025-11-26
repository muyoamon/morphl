cmake_minimum_required(VERSION 3.28)
project(morphl C)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_BUILD_TYPE Debug)

set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)

find_package(Catch2 CONFIG QUIET)

add_compile_options(
  -Wall -Wextra -Werror
  -g
)

add_subdirectory(src/)

if (Catch2_FOUND AND CMAKE_BUILD_TYPE STREQUAL "Debug")
  include(Catch)
  include(CTest)
  add_subdirectory(test/)
endif()

