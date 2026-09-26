cmake_minimum_required(VERSION 3.10)

project(memreader_plus VERSION 0.2.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

set(GAME_IMPORT_LIB "${PROJECT_BINARY_DIR}/warhammer3.lib")
add_custom_command(
	OUTPUT "${GAME_IMPORT_LIB}"
	COMMAND "${CMAKE_AR}" /nologo /machine:x64 "/def:${PROJECT_SOURCE_DIR}/warhammer3.def" "/out:${GAME_IMPORT_LIB}"
	DEPENDS "${PROJECT_SOURCE_DIR}/warhammer3.def")
add_custom_target(game_import_lib DEPENDS "${GAME_IMPORT_LIB}")

add_library(memreader_plus SHARED
	src/common.h
	src/main.c
	src/value.c
	src/memory.c
	src/process.c)
add_dependencies(memreader_plus game_import_lib)

configure_file(src/config.h.in config.h @ONLY)

target_include_directories(memreader_plus PRIVATE
	"${PROJECT_BINARY_DIR}"
	"${PROJECT_SOURCE_DIR}/lua-5.1")
target_compile_definitions(memreader_plus PRIVATE LUA_BUILD_AS_DLL)

if(MSVC)
	set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /W4 /GS /GL /Gy /Zi /O1 /Os /sdl /fp:precise /Oi /MD /FC /Brepro")
	set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} /MANIFEST:NO /LTCG /NOENTRY /NXCOMPAT /DYNAMICBASE:NO /LARGEADDRESSAWARE /MANIFESTUAC:NO /NODEFAULTLIB /Brepro")
	target_link_libraries(memreader_plus "${GAME_IMPORT_LIB}" ucrt.lib libcmt.lib libvcruntime.lib)
endif()
