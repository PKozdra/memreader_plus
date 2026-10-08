cmake_minimum_required(VERSION 3.15)

project(memreader_plus VERSION 0.9.0 LANGUAGES C ASM_MASM)

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
	src/main.c
	src/core/common.h
	src/core/value.c
	src/core/memory.c
	src/core/process.c
	src/core/scan.c
	src/core/layout.c
	src/core/call.c
	src/core/hook.c
	src/core/farhook.c
	src/core/frame.c
	src/core/guard.c
	src/core/native.c
	src/core/crash_report.c
	src/core/clues.c
	src/core/thunk.asm
	src/game/game.h
	src/game/crash.c
	src/game/session.c
	src/game/heap.c
	src/game/vector.c
	src/game/text.c
	src/game/pack.c
	src/game/map.c
	src/game/list.c
	src/file_edit/file_edit.h
	src/file_edit/file_edit.c
	src/file_edit/registry.c
	src/file_edit/ops.c
	src/file_edit/xml.c
	src/file_edit/game.c)
add_dependencies(memreader_plus game_import_lib)

configure_file(src/config.h.in config.h @ONLY)

target_include_directories(memreader_plus PRIVATE
	"${PROJECT_BINARY_DIR}"
	"${PROJECT_SOURCE_DIR}/src/core"
	"${PROJECT_SOURCE_DIR}/vendor/lua-5.1"
	"${PROJECT_SOURCE_DIR}/vendor/minhook/src")
target_compile_definitions(memreader_plus PRIVATE LUA_BUILD_AS_DLL)

option(MEMREADER_SYSTEM_EXIT_HOOKS "Hook ntdll!RtlExitUserProcess and kernelbase!TerminateProcess for exit reports" ON)
if(MEMREADER_SYSTEM_EXIT_HOOKS)
	target_compile_definitions(memreader_plus PRIVATE MEMREADER_SYSTEM_EXIT_HOOKS=1)
endif()

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
