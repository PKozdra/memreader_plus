#include <string.h>

#include "common.h"

#define HASH_MULTIPLIER 0x9E3779B97F4A7C15ull

enum { FIRST_SLOTS = 64, FIRST_SHIFT = 58, SLOTS_INDEX = 1 };

_Static_assert(FIRST_SLOTS == 1 << (64 - FIRST_SHIFT), "the hash fills the first table");

static char metatable_key;

static unsigned first_slot(const PointerSet *set, UINT64 key)
{
	return (unsigned)((key * HASH_MULTIPLIER) >> set->shift);
}

BOOL set_has(const PointerSet *set, UINT64 key)
{
	unsigned slot;

	if (set->all)
		return key != 0;
	for (slot = first_slot(set, key); set->slots[slot]; slot = (slot + 1) & set->mask) {
		if (set->slots[slot] == key)
			return TRUE;
	}
	return FALSE;
}

static void insert(PointerSet *set, UINT64 key)
{
	unsigned slot;

	if (key == 0 || set_has(set, key))
		return;
	for (slot = first_slot(set, key); set->slots[slot]; slot = (slot + 1) & set->mask)
		;
	set->slots[slot] = key;
	set->count++;
}

static int refuse(lua_State *L, const char *why)
{
	lua_pushnil(L);
	lua_pushstring(L, why);
	return 2;
}

static UINT64 key_at(lua_State *L, int index, BOOL *valid)
{
	const TypedValue *value = to_value(L, index);

	*valid = value && (value->type == VALUE_POINTER || value->type == VALUE_INT64 || value->type == VALUE_UINT64);
	return *valid ? (UINT64)value_to_integer(value) : 0;
}

static int first_bad_value(lua_State *L, int count)
{
	BOOL valid;
	int i;

	for (i = 1; i <= count; i++) {
		lua_rawgeti(L, 2, i);
		key_at(L, -1, &valid);
		lua_pop(L, 1);
		if (!valid)
			return i;
	}
	return 0;
}

static void fill_slots(lua_State *L, PointerSet *fresh, int count)
{
	BOOL valid;
	int i;

	for (i = 1; i <= count; i++) {
		lua_rawgeti(L, 2, i);
		insert(fresh, key_at(L, -1, &valid));
		lua_pop(L, 1);
	}
}

static void replace_content(lua_State *L, int index, PointerSet *set, int count)
{
	PointerSet fresh = { FALSE, 0, FIRST_SLOTS - 1, FIRST_SHIFT, NULL };

	while (fresh.mask + 1 < 2u * (unsigned)count) {
		fresh.mask = fresh.mask * 2 + 1;
		fresh.shift--;
	}
	fresh.slots = lua_newuserdata(L, (fresh.mask + 1) * sizeof *fresh.slots);
	memset(fresh.slots, 0, (fresh.mask + 1) * sizeof *fresh.slots);
	fill_slots(L, &fresh, count);
	*set = fresh;
	lua_getfenv(L, index);
	lua_pushvalue(L, -2);
	lua_rawseti(L, -2, SLOTS_INDEX);
	lua_pop(L, 2);
}

static int l_fill(lua_State *L)
{
	PointerSet *set = to_set(L, 1);
	int count, bad;

	if (!set)
		luaL_typerror(L, 1, "pointer set");
	if (lua_isboolean(L, 2) && lua_toboolean(L, 2)) {
		replace_content(L, 1, set, 0);
		set->all = TRUE;
		lua_pushboolean(L, 1);
		return 1;
	}
	luaL_checktype(L, 2, LUA_TTABLE);
	count = (int)lua_objlen(L, 2);
	if (count > SET_MEMBERS)
		return refuse(L, lua_pushfstring(L, "at most %d values", SET_MEMBERS));
	bad = first_bad_value(L, count);
	if (bad)
		return refuse(L, lua_pushfstring(L, "value %d is not a pointer, int64 or uint64", bad));
	replace_content(L, 1, set, count);
	lua_pushboolean(L, 1);
	return 1;
}

static int l_count(lua_State *L)
{
	const PointerSet *set = to_set(L, 1);

	if (!set)
		luaL_typerror(L, 1, "pointer set");
	if (set->all)
		lua_pushliteral(L, "all");
	else
		lua_pushnumber(L, (lua_Number)set->count);
	return 1;
}

static void push_metatable(lua_State *L)
{
	lua_pushlightuserdata(L, &metatable_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (!lua_isnil(L, -1))
		return;
	lua_pop(L, 1);
	lua_createtable(L, 0, 1);
	lua_createtable(L, 0, 2);
	lua_pushcfunction(L, l_fill);
	lua_setfield(L, -2, "fill");
	lua_pushcfunction(L, l_count);
	lua_setfield(L, -2, "count");
	lua_setfield(L, -2, "__index");
	lua_pushlightuserdata(L, &metatable_key);
	lua_pushvalue(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
}

PointerSet *to_set(lua_State *L, int index)
{
	PointerSet *set = lua_touserdata(L, index);
	BOOL ours;

	if (!set || lua_objlen(L, index) != sizeof *set || !lua_getmetatable(L, index))
		return NULL;
	push_metatable(L);
	ours = lua_rawequal(L, -1, -2);
	lua_pop(L, 2);
	return ours ? set : NULL;
}

static int l_pointer_set(lua_State *L)
{
	PointerSet *set = lua_newuserdata(L, sizeof *set);
	int index = lua_gettop(L);

	memset(set, 0, sizeof *set);
	push_metatable(L);
	lua_setmetatable(L, index);
	lua_createtable(L, 1, 0);
	lua_setfenv(L, index);
	replace_content(L, index, set, 0);
	return 1;
}

const luaL_Reg set_functions[] = {
	{ "pointer_set", l_pointer_set },
	{ NULL, NULL }
};
