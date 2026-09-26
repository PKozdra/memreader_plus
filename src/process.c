#include "common.h"

#include <tlhelp32.h>

#include "lstate.h"

static HANDLE create_module_snapshot(void)
{
	HANDLE snapshot;
	do {
		snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetCurrentProcessId());
	} while (snapshot == INVALID_HANDLE_VALUE && GetLastError() == ERROR_BAD_LENGTH);
	return snapshot;
}

static void push_module(lua_State *L, const MODULEENTRY32 *module)
{
	lua_createtable(L, 0, 4);
	lua_pushstring(L, module->szModule);
	lua_setfield(L, -2, "name");
	lua_pushstring(L, module->szExePath);
	lua_setfield(L, -2, "path");
	push_value(L, VALUE_POINTER, (INT_PTR)module->modBaseAddr);
	lua_setfield(L, -2, "base");
	lua_pushnumber(L, (lua_Number)module->modBaseSize);
	lua_setfield(L, -2, "size");
}

enum { MODULE_LIST = 1, MODULE_POSITION = 2, MODULE_UPVALUE_COUNT = 2 };

static int next_module(lua_State *L)
{
	int position = (int)lua_tointeger(L, lua_upvalueindex(MODULE_POSITION)) + 1;
	lua_pushinteger(L, position);
	lua_replace(L, lua_upvalueindex(MODULE_POSITION));
	lua_rawgeti(L, lua_upvalueindex(MODULE_LIST), position);
	return 1;
}

static int l_modules(lua_State *L)
{
	MODULEENTRY32 module = { sizeof module };
	HANDLE snapshot = create_module_snapshot();
	BOOL found;
	int count = 0;

	if (snapshot == INVALID_HANDLE_VALUE)
		return luaL_error(L, "failed to create snapshot");

	lua_newtable(L);
	for (found = Module32First(snapshot, &module); found; found = Module32Next(snapshot, &module)) {
		push_module(L, &module);
		lua_rawseti(L, -2, ++count);
	}
	CloseHandle(snapshot);

	lua_pushinteger(L, 0);
	lua_pushcclosure(L, next_module, MODULE_UPVALUE_COUNT);
	return 1;
}

static int l_ud_topointer(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TUSERDATA);
	luaL_argcheck(L, lua_objlen(L, 1) >= sizeof(INT_PTR), 1, "userdata too small to hold a pointer");
	push_value(L, VALUE_POINTER, *(INT_PTR *)lua_touserdata(L, 1));
	return 1;
}

static int l_ud_debug(lua_State *L)
{
	const TValue *argument = L->base;
	luaL_checkany(L, 1);
	lua_pushnumber(L, (lua_Number)argument->tt);
	push_value(L, VALUE_POINTER, (INT_PTR)argument->value.p);
	return 2;
}

const luaL_Reg process_functions[] = {
	{ "modules", l_modules },
	{ "ud_topointer", l_ud_topointer },
	{ "ud_debug", l_ud_debug },
	{ NULL, NULL }
};
