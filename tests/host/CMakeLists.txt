cmake_minimum_required(VERSION 3.10)

project(lua_host LANGUAGES C CXX ASM_MASM)

set(LUA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../vendor/lua-5.1")
file(GLOB LUA_SRC "${LUA_DIR}/*.c")

add_executable(lua_host lua_host.c exception.cpp registers.asm handler.asm ${LUA_SRC})
target_include_directories(lua_host PRIVATE "${LUA_DIR}")
target_compile_definitions(lua_host PRIVATE LUA_BUILD_AS_DLL LUA_CORE _CRT_SECURE_NO_WARNINGS)
if(MSVC)
	target_compile_options(lua_host PRIVATE $<$<COMPILE_LANGUAGE:C,CXX>:/W1> $<$<COMPILE_LANGUAGE:CXX>:/EHsc>)
endif()
set_target_properties(lua_host PROPERTIES OUTPUT_NAME Warhammer3)
