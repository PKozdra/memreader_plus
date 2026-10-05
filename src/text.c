#include <string.h>

#include "common.h"

typedef struct {
	const char *constructor_pattern;
	const char *destructor_pattern;
	INT_PTR constructor;
	INT_PTR destructor;
} StringFunctions;

static StringFunctions narrow = {
	"40 53 48 83 EC ?? 48 8B D9 48 C7 41 08 ?? ?? ?? ?? 48 C7 C0 ?? ?? ?? ?? 0F 1F 84 00 ?? ?? ?? ?? 48 FF C0",
	"40 53 48 83 EC ?? 48 8B 59 08 48 8D 05 ?? ?? ?? ?? 48 3B D8 74 38 48 8B C3 48 B9 ?? ?? ?? ?? ?? ?? ?? ?? 48 23 C1",
	0,
	0
};

static StringFunctions wide = {
	"40 53 48 83 EC ?? 48 8B D9 4C 8B C2 33 C9 48 89 4B 08 41 0F B7 00 49 83 C0 02 66 85 C0 75 F3 4C 2B C2",
	"40 53 48 83 EC ?? 48 8B 59 08 48 8D 05 ?? ?? ?? ?? 48 3B D8 74 47 48 B9 ?? ?? ?? ?? ?? ?? ?? ?? 48 8B C3 48 23 C1 "
	"48 B9 ?? ?? ?? ?? ?? ?? ?? ?? 48 3B C1 74 28 48 85 DB 74 23",
	0,
	0
};

static void find_functions(lua_State *L, StringFunctions *functions)
{
	if (functions->constructor && functions->destructor)
		return;
	functions->constructor = find_unique(functions->constructor_pattern);
	functions->destructor = find_unique(functions->destructor_pattern);
	if (!functions->constructor || !functions->destructor)
		luaL_error(L, "the game's string functions were not found in this game build");
}

static void call_or_raise(lua_State *L, INT_PTR function, UINT64 first, UINT64 second, int count)
{
	UINT64 arguments[2] = { first, second };

	call_game(L, function, arguments, count);
}

static const void *wide_text(lua_State *L, const char *text, size_t length)
{
	int units = length ? MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)length, NULL, 0) : 0;
	WCHAR *buffer;

	if (length && units == 0)
		luaL_argerror(L, 3, "must be UTF-8 text");
	buffer = lua_newuserdata(L, ((size_t)units + 1) * sizeof(WCHAR));
	if (units)
		MultiByteToWideChar(CP_UTF8, 0, text, (int)length, buffer, units);
	buffer[units] = 0;
	return buffer;
}

static int set_string(lua_State *L, StringFunctions *functions, BOOL is_wide)
{
	INT_PTR address = address_argument(L, 1);
	size_t length;
	const char *text = luaL_checklstring(L, 3, &length);
	__declspec(align(16)) CaString fresh, old;
	const void *argument;

	check_write(L, 1, NULL, address, sizeof(CaString));
	if (strlen(text) != length)
		return luaL_argerror(L, 3, "must not contain a zero byte");
	if (string_view_result(address, is_wide ? sizeof(WCHAR) : sizeof(char)) != READ_OK)
		return luaL_error(L, "not a CA string");
	find_functions(L, functions);
	argument = is_wide ? wide_text(L, text, length) : text;
	memset(&fresh, 0, sizeof fresh);
	call_or_raise(L, functions->constructor, (UINT64)&fresh, (UINT64)argument, 2);
	if (!copy_memory(&old, address, sizeof old) || !write_memory(address, &fresh, sizeof fresh)) {
		call_or_raise(L, functions->destructor, (UINT64)&fresh, 0, 1);
		return luaL_error(L, "failed to write memory");
	}
	call_or_raise(L, functions->destructor, (UINT64)&old, 0, 1);
	return 0;
}

void make_game_string(lua_State *L, CaString *slot, const char *text)
{
	find_functions(L, &narrow);
	memset(slot, 0, sizeof *slot);
	call_or_raise(L, narrow.constructor, (UINT64)slot, (UINT64)text, 2);
}

void free_game_string(lua_State *L, INT_PTR slot)
{
	find_functions(L, &narrow);
	call_or_raise(L, narrow.destructor, (UINT64)slot, 0, 1);
}

static int l_string_set(lua_State *L)
{
	return set_string(L, &narrow, FALSE);
}

static int l_unistring_set(lua_State *L)
{
	return set_string(L, &wide, TRUE);
}

const luaL_Reg text_functions[] = {
	{ "string_set", l_string_set },
	{ "unistring_set", l_unistring_set },
	{ NULL, NULL }
};
