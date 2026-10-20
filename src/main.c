#include "core/common.h"
#include "game/game.h"
#include "file_edit/file_edit.h"
#include "asm/asm.h"

#define MEMREADER_API_VERSION 1.2f

static int l_capacity(lua_State *L)
{
	push_core_capacity(L);
	push_capacity(L, "rows", rows_capacity());
	push_capacity(L, "file_edits", file_edit_capacity());
	return 1;
}

__declspec(dllexport) int luaopen_memreader_plus(lua_State *L)
{
	prepare_hooks();
	reserve_near_caves();
	watch_crashes(L);
	register_row_kind(&rows_kind);
	register_cave_assembler(assemble_cave);
	lua_newtable(L);
	luaL_register(L, NULL, value_functions);
	luaL_register(L, NULL, memory_functions);
	luaL_register(L, NULL, process_functions);
	luaL_register(L, NULL, scan_functions);
	luaL_register(L, NULL, layout_functions);
	luaL_register(L, NULL, call_functions);
	luaL_register(L, NULL, hook_functions);
	luaL_register(L, NULL, crash_functions);
	luaL_register(L, NULL, heap_functions);
	luaL_register(L, NULL, vector_functions);
	luaL_register(L, NULL, text_functions);
	luaL_register(L, NULL, farhook_functions);
	luaL_register(L, NULL, cave_functions);
	luaL_register(L, NULL, pack_functions);
	luaL_register(L, NULL, file_edit_functions);
	luaL_register(L, NULL, map_functions);
	luaL_register(L, NULL, list_functions);
	luaL_register(L, NULL, frame_functions);
	luaL_register(L, NULL, patcher_functions);
	luaL_register(L, NULL, set_functions);
	luaL_register(L, NULL, asm_functions);
	lua_pushcfunction(L, l_capacity);
	lua_setfield(L, -2, "capacity");

	push_value(L, VALUE_POINTER, (INT_PTR)GetModuleHandleA(NULL));
	lua_setfield(L, -2, "base");
	lua_pushnumber(L, MEMREADER_API_VERSION);
	lua_setfield(L, -2, "version");
	lua_pushstring(L, MEMREADER_PLUS_VERSION);
	lua_setfield(L, -2, "plus_version");
	return 1;
}
