#include <string.h>

#include "common.h"

enum {
	MAX_PATCH_SIZE = 4096,
	PATCH_PAGES = 2,
	STACK_BUFFER_SIZE = 1024,
	MAX_READ_SIZE = 16 * 1024 * 1024,
	IN_PLACE_STRING_TAG = 8,
	MAX_UTF8_PER_WCHAR = 3
};

typedef struct {
	INT_PTR data;
	size_t length;
} StringView;

typedef struct {
	INT_PTR address;
	const char *expected;
	const char *bytes;
	size_t size;
	char current[MAX_PATCH_SIZE];
} PatchSite;

int catch_fault(const EXCEPTION_RECORD *record, Fault *fault)
{
	fault->code = record->ExceptionCode;
	fault->address = record->NumberParameters >= 2 ? record->ExceptionInformation[1] : 0;
	fault->instruction = record->ExceptionAddress;
	switch (fault->code) {
	case EXCEPTION_ACCESS_VIOLATION:
	case STATUS_GUARD_PAGE_VIOLATION:
	case EXCEPTION_IN_PAGE_ERROR:
		return EXCEPTION_EXECUTE_HANDLER;
	}
	return EXCEPTION_CONTINUE_SEARCH;
}

void restore_guard(ULONG_PTR address)
{
	MEMORY_BASIC_INFORMATION page;
	DWORD old_protection;

	if (VirtualQuery((LPCVOID)address, &page, sizeof page) && page.State == MEM_COMMIT)
		VirtualProtect((LPVOID)address, 1, page.Protect | PAGE_GUARD, &old_protection);
}

static BOOL guarded_copy(void *destination, const void *source, size_t size, BOOL zero)
{
	Fault fault = { 0, 0, NULL };

	__try {
		if (zero)
			memset(destination, 0, size);
		else
			memmove(destination, source, size);
	} __except (catch_fault(GetExceptionInformation()->ExceptionRecord, &fault)) {
		if (fault.code == STATUS_GUARD_PAGE_VIOLATION)
			restore_guard(fault.address);
		return FALSE;
	}
	return TRUE;
}

BOOL copy_memory(void *destination, INT_PTR address, size_t size)
{
	return guarded_copy(destination, (const void *)address, size, FALSE);
}

static BOOL store(INT_PTR address, const void *source, size_t size)
{
	if (guarded_copy((void *)address, source, size, FALSE))
		return TRUE;
	return in_game_image(address, size) && WriteProcessMemory(GetCurrentProcess(), (LPVOID)address, source, size, NULL);
}

BOOL write_memory(INT_PTR address, const void *source, size_t size)
{
	return may_write(address, size) && store(address, source, size);
}

BOOL zero_memory(INT_PTR address, size_t size)
{
	return may_write(address, size) && guarded_copy((void *)address, NULL, size, TRUE);
}

void push_read_error(lua_State *L, int result)
{
	switch (result) {
	case READ_TOO_LARGE:     lua_pushfstring(L, "cannot read more than %d bytes at once", MAX_READ_SIZE); break;
	case READ_NOT_CA_STRING: lua_pushliteral(L, "not a CA string"); break;
	default:                 lua_pushliteral(L, "failed to read memory"); break;
	}
}

static void check_read(lua_State *L, int result)
{
	if (result == READ_OK)
		return;
	push_read_error(L, result);
	lua_error(L);
}

static void read_or_fail(lua_State *L, INT_PTR address, void *destination, size_t size)
{
	check_read(L, copy_memory(destination, address, size) ? READ_OK : READ_FAILED);
}

static BOOL flag_argument(lua_State *L, int index)
{
	return lua_type(L, index) == LUA_TBOOLEAN && lua_toboolean(L, index);
}

static size_t read_size(lua_State *L, lua_Number size)
{
	if (size > MAX_READ_SIZE)
		check_read(L, READ_TOO_LARGE);
	return (size_t)size;
}

static int push_memory(lua_State *L, INT_PTR address, size_t size)
{
	char stack_buffer[STACK_BUFFER_SIZE];
	char *buffer = size <= sizeof stack_buffer ? stack_buffer : lua_newuserdata(L, size);

	if (!copy_memory(buffer, address, size))
		return READ_FAILED;
	lua_pushlstring(L, buffer, size);
	if (buffer != stack_buffer)
		lua_remove(L, -2);
	return READ_OK;
}

int push_integer(lua_State *L, INT_PTR address, int type, BOOL exact)
{
	TypedValue value = { (BYTE)type };

	if (!copy_memory(&value.pointer, address, value_size(type)))
		return READ_FAILED;
	if (exact || type == VALUE_INT64 || type == VALUE_UINT64)
		push_value(L, type, value_to_integer(&value));
	else
		lua_pushnumber(L, (lua_Number)value_to_integer(&value));
	return READ_OK;
}

static int read_integer(lua_State *L, int type)
{
	INT_PTR address = address_argument(L, 1);
	check_read(L, push_integer(L, address, type, flag_argument(L, 3)));
	return 1;
}

static int l_read_uint8(lua_State *L)  { return read_integer(L, VALUE_UINT8); }
static int l_read_int8(lua_State *L)   { return read_integer(L, VALUE_INT8); }
static int l_read_uint16(lua_State *L) { return read_integer(L, VALUE_UINT16); }
static int l_read_int16(lua_State *L)  { return read_integer(L, VALUE_INT16); }
static int l_read_uint32(lua_State *L) { return read_integer(L, VALUE_UINT32); }
static int l_read_int32(lua_State *L)  { return read_integer(L, VALUE_INT32); }
static int l_read_int64(lua_State *L)  { return read_integer(L, VALUE_INT64); }
static int l_read_uint64(lua_State *L) { return read_integer(L, VALUE_UINT64); }

static int l_read_float(lua_State *L)
{
	float number;
	read_or_fail(L, address_argument(L, 1), &number, sizeof number);
	lua_pushnumber(L, number);
	return 1;
}

static int l_read_double(lua_State *L)
{
	double number;
	read_or_fail(L, address_argument(L, 1), &number, sizeof number);
	lua_pushnumber(L, (lua_Number)number);
	return 1;
}

static int l_read_pointer(lua_State *L)
{
	INT_PTR pointer;
	read_or_fail(L, address_argument(L, 1), &pointer, sizeof pointer);
	push_value(L, VALUE_POINTER, pointer);
	return 1;
}

static int l_read_boolean(lua_State *L)
{
	BYTE byte;
	read_or_fail(L, address_argument(L, 1), &byte, sizeof byte);
	lua_pushboolean(L, byte != 0);
	return 1;
}

static int l_read(lua_State *L)
{
	INT_PTR address = address_argument(L, 1);
	lua_Number size = lua_tonumber(L, 3);

	if (!(size >= 1)) {
		lua_pushliteral(L, "");
		return 1;
	}
	check_read(L, push_memory(L, address, read_size(L, size)));
	return 1;
}

static int string_view(INT_PTR address, size_t char_size, StringView *view)
{
	CaString string;

	if (!copy_memory(&string, address, sizeof string))
		return READ_FAILED;
	if (string.in_place.tag_and_length >> 4 == IN_PLACE_STRING_TAG) {
		view->data = address;
		view->length = string.in_place.tag_and_length & 0x0F;
		return view->length * char_size > sizeof string.in_place.text ? READ_NOT_CA_STRING : READ_OK;
	}
	view->data = string.heap.data;
	view->length = string.heap.length > 0 ? (size_t)string.heap.length : 0;
	return view->length * char_size > MAX_READ_SIZE ? READ_TOO_LARGE : READ_OK;
}

BOOL read_ca_text(INT_PTR address, BOOL wide, char *out, size_t size)
{
	WCHAR units[MAX_PATH];
	StringView view;
	size_t length;
	int written;

	out[0] = '\0';
	if (string_view(address, wide ? sizeof(WCHAR) : sizeof(char), &view) != READ_OK)
		return FALSE;
	if (!wide) {
		length = view.length < size - 1 ? view.length : size - 1;
		if (length && !copy_memory(out, view.data, length))
			return FALSE;
		out[length] = '\0';
		return TRUE;
	}
	length = view.length < MAX_PATH ? view.length : MAX_PATH;
	if (length && !copy_memory(units, view.data, length * sizeof(WCHAR)))
		return FALSE;
	written = WideCharToMultiByte(CP_UTF8, 0, units, (int)length, out, (int)size - 1, NULL, NULL);
	out[written > 0 ? written : 0] = '\0';
	return TRUE;
}

int string_view_result(INT_PTR address, size_t char_size)
{
	StringView view;

	return string_view(address, char_size, &view);
}

int push_string(lua_State *L, INT_PTR address, size_t char_size)
{
	StringView view;
	int result = string_view(address, char_size, &view);

	if (result != READ_OK)
		return result;
	if (view.length == 0) {
		lua_pushliteral(L, "");
		return READ_OK;
	}
	return push_memory(L, view.data, view.length * char_size);
}

int push_unistring(lua_State *L, INT_PTR address)
{
	StringView view;
	int result = string_view(address, sizeof(WCHAR), &view);
	WCHAR *text;
	char *utf8;
	int utf8_size;

	if (result != READ_OK)
		return result;
	if (view.length == 0) {
		lua_pushliteral(L, "");
		return READ_OK;
	}
	text = lua_newuserdata(L, view.length * (sizeof(WCHAR) + MAX_UTF8_PER_WCHAR));
	utf8 = (char *)(text + view.length);
	if (!copy_memory(text, view.data, view.length * sizeof(WCHAR)))
		return READ_FAILED;
	utf8_size = WideCharToMultiByte(CP_UTF8, 0, text, (int)view.length, utf8, (int)(view.length * MAX_UTF8_PER_WCHAR), NULL, NULL);
	lua_pushlstring(L, utf8, (size_t)utf8_size);
	lua_remove(L, -2);
	return READ_OK;
}

static int l_read_string(lua_State *L)
{
	INT_PTR address = address_argument(L, 1);
	BOOL is_pointer = flag_argument(L, 3);
	size_t char_size = flag_argument(L, 4) ? sizeof(WCHAR) : sizeof(char);

	if (is_pointer)
		read_or_fail(L, address, &address, sizeof address);
	check_read(L, push_string(L, address, char_size));
	return 1;
}

static int l_read_unistring(lua_State *L)
{
	check_read(L, push_unistring(L, address_argument(L, 1)));
	return 1;
}

static int l_read_array(lua_State *L)
{
	CaVector vector;

	read_or_fail(L, address_argument(L, 1), &vector, sizeof vector);
	if (vector.size <= 0)
		vector.data = 0;

	if (flag_argument(L, 3))
		push_value(L, VALUE_INT32, vector.size);
	else
		lua_pushnumber(L, (lua_Number)vector.size);
	push_value(L, VALUE_POINTER, vector.data);
	return 2;
}

static int l_read_rowidx(lua_State *L)
{
	INT_PTR address = address_argument(L, 1);
	INT_PTR base = check_pointer(L, 3);
	INT64 row_size = (INT64)lua_tonumber(L, 4);
	INT_PTR entry;

	if (row_size <= 0)
		return luaL_error(L, "row size must be positive");
	read_or_fail(L, address, &entry, sizeof entry);
	lua_pushnumber(L, (lua_Number)((entry - base) / row_size + 1));
	return 1;
}

static int l_write(lua_State *L)
{
	INT_PTR address = address_argument(L, 1);
	TypedValue *value = to_value(L, 3);
	BYTE byte;
	float number;
	const void *source;
	size_t size;

	if (lua_type(L, 3) == LUA_TBOOLEAN) {
		byte = (BYTE)lua_toboolean(L, 3);
		source = &byte;
		size = sizeof byte;
	} else if (lua_type(L, 3) == LUA_TNUMBER) {
		number = (float)lua_tonumber(L, 3);
		source = &number;
		size = sizeof number;
	} else if (lua_type(L, 3) == LUA_TSTRING) {
		source = lua_tolstring(L, 3, &size);
	} else if (value) {
		source = &value->pointer;
		size = value_size(value->type);
	} else {
		return luaL_error(L, "passed invalid argument type");
	}
	check_write(L, 1, "write", address, size);
	if (!store(address, source, size))
		return luaL_error(L, "failed to write memory");
	return 0;
}

const IMAGE_NT_HEADERS *game_headers(void)
{
	const BYTE *base = (const BYTE *)GetModuleHandleA(NULL);

	return (const IMAGE_NT_HEADERS *)(base + ((const IMAGE_DOS_HEADER *)base)->e_lfanew);
}

BOOL in_game_image(INT_PTR address, size_t size)
{
	INT_PTR start = (INT_PTR)GetModuleHandleA(NULL);
	INT_PTR end = start + (INT_PTR)game_headers()->OptionalHeader.SizeOfImage;

	return address >= start && address + (INT_PTR)size <= end;
}

static DWORD writable(DWORD protection)
{
	if (protection & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))
		return PAGE_EXECUTE_READWRITE;
	return PAGE_READWRITE;
}

BOOL patch_memory(INT_PTR address, const char *bytes, size_t size)
{
	SYSTEM_INFO system;
	MEMORY_BASIC_INFORMATION page;
	DWORD old[PATCH_PAGES], unused;
	INT_PTR first, at;
	int pages = 0, i;
	BOOL written;

	GetSystemInfo(&system);
	first = address & ~(INT_PTR)(system.dwPageSize - 1);
	for (at = first; at < address + (INT_PTR)size; at += system.dwPageSize) {
		if (!VirtualQuery((LPCVOID)at, &page, sizeof page) || page.State != MEM_COMMIT ||
			(page.Protect & (PAGE_GUARD | PAGE_NOACCESS)) || pages == PATCH_PAGES ||
			!VirtualProtect((LPVOID)at, 1, writable(page.Protect), &old[pages]))
			break;
		pages++;
	}
	written = at >= address + (INT_PTR)size && guarded_copy((void *)address, bytes, size, FALSE);
	for (i = 0; i < pages; i++)
		VirtualProtect((LPVOID)(first + (INT_PTR)i * system.dwPageSize), 1, old[i], &unused);
	FlushInstructionCache(GetCurrentProcess(), (LPCVOID)address, size);
	return written;
}

enum PatchState { PATCH_EXPECTED, PATCH_DONE, PATCH_OTHER };

static void site_error(lua_State *L, int number, int argument, const char *message)
{
	if (number)
		luaL_error(L, "site %d: %s", number, message);
	luaL_argerror(L, argument, message);
}

static int check_patch(lua_State *L, int index, int number, PatchSite *site)
{
	size_t new_size;

	site->address = pointer_argument(L, index);
	site->expected = luaL_checklstring(L, index + 1, &site->size);
	site->bytes = luaL_checklstring(L, index + 2, &new_size);
	if (site->size != new_size)
		site_error(L, number, index + 2, "must be as long as the expected bytes");
	if (site->size == 0 || site->size > MAX_PATCH_SIZE)
		site_error(L, number, index + 1, lua_pushfstring(L, "must be 1 to %d bytes", MAX_PATCH_SIZE));
	if (!in_game_image(site->address, site->size))
		site_error(L, number, index, "address is outside the game's exe");
	if (!may_write(site->address, site->size)) {
		note_refusal(L, number ? "relocate_field" : "patch", site->address);
		site_error(L, number, index, "refused: the exe's headers and import or export tables are never patched");
	}
	read_or_fail(L, site->address, site->current, site->size);
	if (memcmp(site->current, site->bytes, site->size) == 0)
		return PATCH_DONE;
	if (in_hooked_prologue(site->address, site->size)) {
		note_refusal(L, number ? "relocate_field" : "patch", site->address);
		return PATCH_OTHER;
	}
	return memcmp(site->current, site->expected, site->size) == 0 ? PATCH_EXPECTED : PATCH_OTHER;
}

static int l_patch(lua_State *L)
{
	PatchSite site;
	int state = check_patch(L, 1, 0, &site);

	if (state == PATCH_OTHER)
		lua_pushnil(L);
	if (state == PATCH_EXPECTED)
		remember_original(site.address, site.size);
	if (state == PATCH_EXPECTED && !patch_memory(site.address, site.bytes, site.size))
		return luaL_error(L, "failed to patch memory");
	if (state == PATCH_EXPECTED)
		note_change(L, "patch", site.address, site.size);
	lua_pushlstring(L, site.current, site.size);
	return state == PATCH_OTHER ? 2 : 1;
}

static int check_site(lua_State *L, int index, PatchSite *site)
{
	int state;

	lua_rawgeti(L, 1, index);
	if (!lua_istable(L, -1))
		luaL_error(L, "site %d is not a table {address, expected, bytes}", index);
	lua_rawgeti(L, -1, 1);
	lua_rawgeti(L, -2, 2);
	lua_rawgeti(L, -3, 3);
	state = check_patch(L, lua_gettop(L) - 2, index, site);
	lua_pop(L, 4);
	return state;
}

static int l_relocate_field(lua_State *L)
{
	PatchSite site;
	int count, i;

	luaL_checktype(L, 1, LUA_TTABLE);
	count = (int)lua_objlen(L, 1);
	if (count == 0)
		return luaL_argerror(L, 1, "no sites");
	for (i = 1; i <= count; i++) {
		if (check_site(L, i, &site) == PATCH_OTHER) {
			lua_pushnil(L);
			lua_pushinteger(L, i);
			return 2;
		}
	}
	for (i = 1; i <= count; i++) {
		if (check_site(L, i, &site) != PATCH_EXPECTED)
			continue;
		remember_original(site.address, site.size);
		if (!patch_memory(site.address, site.bytes, site.size))
			return luaL_error(L, "site %d: failed to patch memory after verifying every site", i);
		note_change(L, "relocate_field", site.address, site.size);
	}
	lua_pushboolean(L, 1);
	return 1;
}

const luaL_Reg memory_functions[] = {
	{ "read_float", l_read_float },
	{ "read_pointer", l_read_pointer },
	{ "read_uint8", l_read_uint8 },
	{ "read_int8", l_read_int8 },
	{ "read_uint16", l_read_uint16 },
	{ "read_int16", l_read_int16 },
	{ "read_uint32", l_read_uint32 },
	{ "read_int32", l_read_int32 },
	{ "read_int64", l_read_int64 },
	{ "read_uint64", l_read_uint64 },
	{ "read_double", l_read_double },
	{ "read_boolean", l_read_boolean },
	{ "read_string", l_read_string },
	{ "read_unistring", l_read_unistring },
	{ "read_array", l_read_array },
	{ "read_rowidx", l_read_rowidx },
	{ "read", l_read },
	{ "write", l_write },
	{ "patch", l_patch },
	{ "relocate_field", l_relocate_field },
	{ NULL, NULL }
};
