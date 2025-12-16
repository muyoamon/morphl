cmake_minimum_required(VERSION 3.28)
project(morphl C CXX)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_BUILD_TYPE Debug)

set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)

include(CTest)

add_compile_options(
  -Wall -Wextra -Werror
  -g
)

add_subdirectory(src/)

if (BUILD_TESTING)
  add_subdirectory(test/)
endif()

