cmake_minimum_required(VERSION 3.15)

project(memreader_plus VERSION 0.6.0 LANGUAGES C ASM_MASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

set(GAME_IMPORT_LIB "${PROJECT_BINARY_DIR}/warhammer3.lib")
add_custom_command(
	OUTPUT "${GAME_IMPORT_LIB}"
	COMMAND "${CMAKE_AR}" /nologo /machine:x64 "/def:${PROJECT_SOURCE_DIR}/src/warhammer3.def" "/out:${GAME_IMPORT_LIB}"
	DEPENDS "${PROJECT_SOURCE_DIR}/src/warhammer3.def")
add_custom_target(game_import_lib DEPENDS "${GAME_IMPORT_LIB}")

add_library(minhook STATIC
	vendor/minhook/src/buffer.c
	vendor/minhook/src/hook.c
	vendor/minhook/src/trampoline.c
	vendor/minhook/src/hde/hde64.c)
target_include_directories(minhook PUBLIC "${PROJECT_SOURCE_DIR}/vendor/minhook/include")

add_library(memreader_plus SHARED
	src/common.h
	src/main.c
	src/value.c
	src/memory.c
	src/process.c
	src/scan.c
	src/layout.c
	src/call.c
	src/hook.c
	src/crash.c
	src/crash_report.c
	src/session.c
	src/heap.c
	src/vector.c
	src/text.c
	src/farhook.c
	src/pack.c
	src/map.c
	src/list.c
	src/frame.c
	src/guard.c
	src/native.c
	src/thunk.asm)
add_dependencies(memreader_plus game_import_lib)

configure_file(src/config.h.in config.h @ONLY)

target_include_directories(memreader_plus PRIVATE
	"${PROJECT_BINARY_DIR}"
	"${PROJECT_SOURCE_DIR}/vendor/lua-5.1"
	"${PROJECT_SOURCE_DIR}/vendor/minhook/src")
target_compile_definitions(memreader_plus PRIVATE LUA_BUILD_AS_DLL)

if(MSVC)
	set(CMAKE_C_FLAGS_RELEASE "/O1 /DNDEBUG")
	set(C_OPTIONS /W4 /GS /GL /Gy /Zi /sdl /fp:precise /Oi /FC /Brepro)
	target_compile_options(memreader_plus PRIVATE
		"$<$<COMPILE_LANGUAGE:C>:${C_OPTIONS}>"
		"$<$<COMPILE_LANGUAGE:ASM_MASM>:/W3;/WX>")
	target_link_options(memreader_plus PRIVATE /MANIFEST:NO /LTCG /NOENTRY /NODEFAULTLIB /Brepro)
	target_compile_options(minhook PRIVATE /W3 /GS /GL /Gy /Brepro)
	target_link_libraries(memreader_plus minhook "${GAME_IMPORT_LIB}" version.lib ucrt.lib libcmt.lib libvcruntime.lib)
endif()
