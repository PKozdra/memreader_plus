cmake_minimum_required(VERSION 3.15)

project(memreader_plus VERSION 0.3.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

set(GAME_IMPORT_LIB "${PROJECT_BINARY_DIR}/warhammer3.lib")
add_custom_command(
	OUTPUT "${GAME_IMPORT_LIB}"
	COMMAND "${CMAKE_AR}" /nologo /machine:x64 "/def:${PROJECT_SOURCE_DIR}/src/warhammer3.def" "/out:${GAME_IMPORT_LIB}"
	DEPENDS "${PROJECT_SOURCE_DIR}/src/warhammer3.def")
add_custom_target(game_import_lib DEPENDS "${GAME_IMPORT_LIB}")

add_library(memreader_plus SHARED
	src/common.h
	src/main.c
	src/value.c
	src/memory.c
	src/process.c
	src/scan.c)
add_dependencies(memreader_plus game_import_lib)

configure_file(src/config.h.in config.h @ONLY)

target_include_directories(memreader_plus PRIVATE
	"${PROJECT_BINARY_DIR}"
	"${PROJECT_SOURCE_DIR}/vendor/lua-5.1")
target_compile_definitions(memreader_plus PRIVATE LUA_BUILD_AS_DLL)

if(MSVC)
	set(CMAKE_C_FLAGS_RELEASE "/O1 /DNDEBUG")
	target_compile_options(memreader_plus PRIVATE /W4 /GS /GL /Gy /Zi /sdl /fp:precise /Oi /FC /Brepro)
	target_link_options(memreader_plus PRIVATE /MANIFEST:NO /LTCG /NOENTRY /NODEFAULTLIB /Brepro)
	target_link_libraries(memreader_plus "${GAME_IMPORT_LIB}" ucrt.lib libcmt.lib libvcruntime.lib)
endif()
