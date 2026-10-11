#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"

int l_test_catch_site_call(lua_State *L)
{
	DWORD64 function;
	CallInfo *ci = L->ci;
	StkId top = L->top;
	unsigned short calls = L->nCcalls;
	struct lua_longjmp *jump = L->errorJmp;
	INT32 result = -1;
	int caught = 0;

	memcpy(&function, luaL_checkstring(L, 1), sizeof function);
	__try {
		result = ((INT32 (*)(INT32, INT32))function)(3, 4);
	} __except (EXCEPTION_EXECUTE_HANDLER) {
		caught = 1;
		L->ci = ci;
		L->base = ci->base;
		L->top = top;
		L->nCcalls = calls;
		L->errorJmp = jump;
	}
	lua_pushboolean(L, caught);
	lua_pushinteger(L, result);
	return 2;
}
