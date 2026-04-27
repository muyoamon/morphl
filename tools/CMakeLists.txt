add_executable(mplinsp mbc_reader.c)
target_include_directories(mplinsp PRIVATE ${CMAKE_SOURCE_DIR}/include)
target_link_libraries(mplinsp PRIVATE morphl_runtime morphl_util)

add_executable(mpll mpll.c)
target_include_directories(mpll PRIVATE ${CMAKE_SOURCE_DIR}/include)
target_link_libraries(mpll PRIVATE morphl_runtime morphl_util)

add_executable(mplvm mplvm.c)
target_include_directories(mplvm PRIVATE ${CMAKE_SOURCE_DIR}/include)
target_link_libraries(mplvm PRIVATE morphl_runtime morphl_util)
