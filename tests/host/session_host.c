#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"

enum { MOD_ENTRY_SIZE = 0x20, PATH_ENTRY_SIZE = 0x10, NAME_SIZE = 64, PATH_SEARCH_AT = 5 };

typedef struct {
	INT32 length;
	UINT32 capacity;
	char *data;
} HeapString;

typedef struct {
	UINT32 capacity;
	UINT32 count;
	BYTE *data;
} ModArray;

typedef struct {
	BYTE unused[0x18];
	BYTE *data;
	UINT32 count;
} PathCollection;

void fake_mod_list(void);
void fake_search_paths(void);
extern ModArray fake_mod_array;
extern PathCollection *fake_path_slot;

static void set_code_byte(BYTE *at, BYTE value)
{
	DWORD old;

	VirtualProtect(at, 1, PAGE_EXECUTE_READWRITE, &old);
	*at = value;
	VirtualProtect(at, 1, old, &old);
}

static BYTE *make_names(int count, size_t stride, const char *format)
{
	BYTE *list = calloc((size_t)count, stride);
	int i;

	for (i = 0; i < count; i++) {
		HeapString *name = (HeapString *)(list + (size_t)i * stride);

		name->data = malloc(NAME_SIZE);
		name->capacity = NAME_SIZE;
		name->length = _snprintf_s(name->data, NAME_SIZE, _TRUNCATE, format, i + 1);
	}
	return list;
}

static int l_test_fake_session(lua_State *L)
{
	int mods = (int)luaL_checkinteger(L, 1);
	int paths = (int)luaL_checkinteger(L, 2);
	static PathCollection collection;

	fake_mod_array.capacity = (UINT32)mods;
	fake_mod_array.count = (UINT32)mods;
	fake_mod_array.data = make_names(mods, MOD_ENTRY_SIZE, "extra_%d.pack");
	collection.count = (UINT32)paths;
	collection.data = make_names(paths, PATH_ENTRY_SIZE, "C:\\nowhere\\path_%d");
	fake_path_slot = &collection;
	set_code_byte((BYTE *)fake_mod_list, 0x48);
	set_code_byte((BYTE *)fake_search_paths + PATH_SEARCH_AT, 0x48);
	return 0;
}

void register_session_tests(lua_State *L)
{
	lua_register(L, "test_fake_session", l_test_fake_session);
}
