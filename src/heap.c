#include "common.h"

enum { MAX_GAME_BLOCK = 64 * 1024 * 1024, MAX_TWINS = 4, FREE_CALL_AT = 13, FREE_HEADER = 16 };

static const char malloc_pattern[] =
	"48 89 5C 24 08 57 48 83 EC ?? 65 48 8B 04 25 58 00 00 00 48 8B F9 B9 ?? ?? ?? ?? 48 8B 10 8B 04 11 39 05 ?? ?? ?? ?? "
	"7F ?? 48 8B CF E8 ?? ?? ?? ?? 48 8B D8 48 85 C0";
static const char free_pattern[] =
	"48 85 C9 74 ?? 53 48 83 EC ?? 48 8B D9 E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 85 C0 75 ?? 48 83 C4 ?? 5B C3 33 D2 "
	"48 8B CB FF D0 EB ??";
static const char deferred_key = 0;

static INT_PTR game_malloc;
static INT_PTR game_free;

static INT_PTR find_free(void)
{
	const BYTE *found[MAX_TWINS];
	int count = find_code_all(free_pattern, found, MAX_TWINS);
	INT_PTR target;
	int i;

	if (count < 1 || count > MAX_TWINS)
		return 0;
	target = call_destination((INT_PTR)found[0] + FREE_CALL_AT);
	if (!target)
		return 0;
	for (i = 1; i < count; i++) {
		if (call_destination((INT_PTR)found[i] + FREE_CALL_AT) != target)
			return 0;
	}
	return (INT_PTR)found[0];
}

static void find_heap(lua_State *L)
{
	if (game_malloc && game_free)
		return;
	game_malloc = find_unique(malloc_pattern);
	game_free = find_free();
	if (!game_malloc || !game_free)
		luaL_error(L, "the game's allocator was not found in this game build");
}

INT_PTR game_heap_alloc(lua_State *L, size_t size)
{
	UINT64 argument = size;
	INT_PTR block;

	find_heap(L);
	block = (INT_PTR)call_game(L, game_malloc, &argument, 1);
	if (!block)
		luaL_error(L, "the game's allocator returned NULL");
	zero_memory(block, size);
	return block;
}

static int free_deferred(lua_State *L)
{
	Fault fault = { 0, 0, NULL };
	UINT64 argument, unused;
	int i;

	lua_pushlightuserdata(L, (void *)&deferred_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	for (i = 1; i <= (int)lua_objlen(L, -1); i++) {
		lua_rawgeti(L, -1, i);
		argument = (UINT64)lua_touserdata(L, -1);
		call_native(game_free, &argument, 1, &unused, &fault);
		lua_pop(L, 1);
	}
	return 0;
}

static void push_deferred(lua_State *L)
{
	lua_pushlightuserdata(L, (void *)&deferred_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (!lua_isnil(L, -1))
		return;
	lua_pop(L, 1);
	lua_newtable(L);
	lua_newuserdata(L, 1);
	lua_createtable(L, 0, 1);
	lua_pushcfunction(L, free_deferred);
	lua_setfield(L, -2, "__gc");
	lua_setmetatable(L, -2);
	lua_setfield(L, -2, "closer");
	lua_pushlightuserdata(L, (void *)&deferred_key);
	lua_pushvalue(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
}

void game_heap_free(lua_State *L, INT_PTR block, BOOL defer)
{
	UINT64 argument = (UINT64)block;

	find_heap(L);
	if (!defer) {
		call_game(L, game_free, &argument, 1);
		return;
	}
	push_deferred(L);
	lua_pushlightuserdata(L, (void *)block);
	lua_rawseti(L, -2, (int)lua_objlen(L, -2) + 1);
	lua_pop(L, 1);
}

static int l_game_alloc(lua_State *L)
{
	lua_Number size = luaL_checknumber(L, 1);

	if (!(size >= 1 && size <= MAX_GAME_BLOCK))
		return luaL_argerror(L, 1, lua_pushfstring(L, "size must be from 1 to %d bytes", MAX_GAME_BLOCK));
	push_value(L, VALUE_POINTER, game_heap_alloc(L, (size_t)size));
	return 1;
}

static int l_game_free(lua_State *L)
{
	INT_PTR block = pointer_argument(L, 1);

	if (!block)
		return luaL_argerror(L, 1, "pointer is NULL");
	check_write(L, 1, NULL, block - FREE_HEADER, FREE_HEADER);
	game_heap_free(L, block, lua_toboolean(L, 2));
	return 0;
}

const luaL_Reg heap_functions[] = {
	{ "game_alloc", l_game_alloc },
	{ "game_free", l_game_free },
	{ NULL, NULL }
};
