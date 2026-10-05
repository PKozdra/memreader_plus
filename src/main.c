#include "common.h"

#define MEMREADER_API_VERSION 1.2f

__declspec(dllexport) int luaopen_memreader_plus(lua_State *L)
{
	prepare_hooks();
	watch_crashes(L);
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
	luaL_register(L, NULL, pack_functions);
	luaL_register(L, NULL, map_functions);
	luaL_register(L, NULL, list_functions);
	luaL_register(L, NULL, frame_functions);

	push_value(L, VALUE_POINTER, (INT_PTR)GetModuleHandleA(NULL));
	lua_setfield(L, -2, "base");
	lua_pushnumber(L, MEMREADER_API_VERSION);
	lua_setfield(L, -2, "version");
	lua_pushstring(L, MEMREADER_PLUS_VERSION);
	lua_setfield(L, -2, "plus_version");
	return 1;
}
