add_executable(mbc_reader mbc_reader.c)
target_include_directories(mbc_reader PRIVATE ${CMAKE_SOURCE_DIR}/include)
target_link_libraries(mbc_reader PRIVATE morphl_runtime)

add_executable(mpll mpll.c)
target_include_directories(mpll PRIVATE ${CMAKE_SOURCE_DIR}/include)
target_link_libraries(mpll PRIVATE morphl_runtime)
