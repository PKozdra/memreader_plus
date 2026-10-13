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

int try_cave(lua_State *L, INT_PTR address, const char *bytes, size_t size, BYTE **start)
{
	Cave cave = { address, NULL, size };

	cave.start = VirtualAlloc(NULL, size + JUMP_BACK_SIZE, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
	if (!cave.start) {
		lua_pushfstring(L, "no free memory for a cave at %p", (void *)address);
		return CAVE_NO_MEMORY;
	}
	memcpy(cave.start, bytes, size);
	if (lua_cpcall(L, place_cave, &cave)) {
		VirtualFree(cave.start, 0, MEM_RELEASE);
		return CAVE_REFUSED;
	}
	*start = cave.start;
	return CAVE_OK;
}

static int l_code_cave(lua_State *L)
{
	INT_PTR address = pointer_argument(L, 1);
	size_t size;
	const char *bytes = luaL_checklstring(L, 2, &size);
	BYTE *start = NULL;
	int result;

	if (!address)
		return luaL_argerror(L, 1, "address is NULL");
	if (size == 0)
		return luaL_argerror(L, 2, "no cave bytes");
	result = try_cave(L, address, bytes, size, &start);
	if (result == CAVE_NO_MEMORY)
		return luaL_error(L, "%s", lua_tostring(L, -1));
	if (result == CAVE_REFUSED)
		return lua_error(L);
	note_anonymous_cave(L, address);
	push_value(L, VALUE_POINTER, (INT_PTR)start);
	return 1;
}

const luaL_Reg cave_functions[] = {
	{ "code_cave", l_code_cave },
	{ NULL, NULL }
};
