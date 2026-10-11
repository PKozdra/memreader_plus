#include <string.h>

#include "common.h"

typedef struct {
	INT_PTR address;
	BYTE *start;
	size_t size;
} Cave;

static void seal_cave(void *context, void *original)
{
	const Cave *cave = context;
	DWORD old;

	write_jump_back(cave->start + cave->size, original);
	VirtualProtect(cave->start, cave->size + JUMP_BACK_SIZE, PAGE_EXECUTE_READ, &old);
	FlushInstructionCache(GetCurrentProcess(), cave->start, cave->size + JUMP_BACK_SIZE);
}

static int place_cave(lua_State *L)
{
	Cave *cave = lua_touserdata(L, 1);

	install_code_hook(L, cave->address, cave->start, cave->size + JUMP_BACK_SIZE, seal_cave, cave);
	return 0;
}

static int l_code_cave(lua_State *L)
{
	Cave cave = { pointer_argument(L, 1), NULL, 0 };
	const char *bytes = luaL_checklstring(L, 2, &cave.size);

	if (!cave.address)
		return luaL_argerror(L, 1, "address is NULL");
	if (cave.size == 0)
		return luaL_argerror(L, 2, "no cave bytes");
	cave.start = VirtualAlloc(NULL, cave.size + JUMP_BACK_SIZE, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
	if (!cave.start)
		return luaL_error(L, "no free memory for a cave at %p", (void *)cave.address);
	memcpy(cave.start, bytes, cave.size);
	if (lua_cpcall(L, place_cave, &cave)) {
		VirtualFree(cave.start, 0, MEM_RELEASE);
		return lua_error(L);
	}
	push_value(L, VALUE_POINTER, (INT_PTR)cave.start);
	return 1;
}

const luaL_Reg cave_functions[] = {
	{ "code_cave", l_code_cave },
	{ NULL, NULL }
};
