#include "common.h"

enum {
	STACK_BUFFER_SIZE = 1024,
	MAX_READ_SIZE = 16 * 1024 * 1024,
	IN_PLACE_STRING_TAG = 8
};

typedef union {
	struct {
		INT32 length;
		UINT32 capacity;
		INT_PTR data;
	} heap;
	struct {
		char text[15];
		BYTE tag_and_length;
	} in_place;
} CaString;

typedef struct {
	UINT32 capacity;
	INT32 size;
	INT_PTR data;
} CaVector;

_Static_assert(sizeof(CaString) == 16 && sizeof(CaVector) == 16, "CA::String and CA_STD::VECTOR are 16 bytes");

typedef struct {
	INT_PTR data;
	size_t length;
} StringView;

static BOOL read_memory(INT_PTR address, void *destination, size_t size)
{
	return ReadProcessMemory(GetCurrentProcess(), (LPCVOID)address, destination, size, NULL);
}

static BOOL write_memory(INT_PTR address, const void *source, size_t size)
{
	return WriteProcessMemory(GetCurrentProcess(), (LPVOID)address, source, size, NULL);
}

static void read_or_fail(lua_State *L, INT_PTR address, void *destination, size_t size)
{
	if (!read_memory(address, destination, size))
		luaL_error(L, "failed to read memory");
}

static INT_PTR address_argument(lua_State *L)
{
	return check_pointer(L, 1) + (INT_PTR)to_offset(L, 2);
}

static BOOL flag_argument(lua_State *L, int index)
{
	return lua_type(L, index) == LUA_TBOOLEAN && lua_toboolean(L, index);
}

static size_t read_size(lua_State *L, lua_Number size)
{
	if (size > MAX_READ_SIZE)
		luaL_error(L, "cannot read more than %d bytes at once", MAX_READ_SIZE);
	return (size_t)size;
}

static int push_memory(lua_State *L, INT_PTR address, size_t size)
{
	char stack_buffer[STACK_BUFFER_SIZE];
	char *buffer = size <= sizeof stack_buffer ? stack_buffer : lua_newuserdata(L, size);

	read_or_fail(L, address, buffer, size);
	lua_pushlstring(L, buffer, size);
	return 1;
}

static int read_integer(lua_State *L, int type)
{
	TypedValue value = { (BYTE)type };

	read_or_fail(L, address_argument(L), &value.pointer, value_size(type));
	if (flag_argument(L, 3))
		push_value(L, type, value_to_integer(&value));
	else
		lua_pushnumber(L, (lua_Number)value_to_integer(&value));
	return 1;
}

static int l_read_uint8(lua_State *L)  { return read_integer(L, VALUE_UINT8); }
static int l_read_int8(lua_State *L)   { return read_integer(L, VALUE_INT8); }
static int l_read_uint16(lua_State *L) { return read_integer(L, VALUE_UINT16); }
static int l_read_int16(lua_State *L)  { return read_integer(L, VALUE_INT16); }
static int l_read_uint32(lua_State *L) { return read_integer(L, VALUE_UINT32); }
static int l_read_int32(lua_State *L)  { return read_integer(L, VALUE_INT32); }

static int l_read_float(lua_State *L)
{
	float number;
	read_or_fail(L, address_argument(L), &number, sizeof number);
	lua_pushnumber(L, number);
	return 1;
}

static int l_read_pointer(lua_State *L)
{
	INT_PTR pointer;
	read_or_fail(L, address_argument(L), &pointer, sizeof pointer);
	push_value(L, VALUE_POINTER, pointer);
	return 1;
}

static int l_read_boolean(lua_State *L)
{
	BYTE byte;
	read_or_fail(L, address_argument(L), &byte, sizeof byte);
	lua_pushboolean(L, byte != 0);
	return 1;
}

static int l_read(lua_State *L)
{
	INT_PTR address = address_argument(L);
	lua_Number size = lua_tonumber(L, 3);

	if (!(size >= 1)) {
		lua_pushliteral(L, "");
		return 1;
	}
	return push_memory(L, address, read_size(L, size));
}

static StringView read_string_view(lua_State *L, INT_PTR address, size_t char_size)
{
	CaString string;
	StringView view;

	read_or_fail(L, address, &string, sizeof string);
	if (string.in_place.tag_and_length >> 4 == IN_PLACE_STRING_TAG) {
		view.data = address;
		view.length = string.in_place.tag_and_length & 0x0F;
		if (view.length * char_size > sizeof string.in_place.text)
			luaL_error(L, "not a CA string");
		return view;
	}
	view.data = string.heap.data;
	view.length = string.heap.length > 0 ? (size_t)string.heap.length : 0;
	return view;
}

static int l_read_string(lua_State *L)
{
	INT_PTR address = address_argument(L);
	BOOL is_pointer = flag_argument(L, 3);
	size_t char_size = flag_argument(L, 4) ? sizeof(WCHAR) : sizeof(char);
	StringView view;

	if (is_pointer)
		read_or_fail(L, address, &address, sizeof address);
	view = read_string_view(L, address, char_size);
	if (view.length == 0) {
		lua_pushliteral(L, "");
		return 1;
	}
	return push_memory(L, view.data, read_size(L, (lua_Number)view.length * char_size));
}

static int l_read_unistring(lua_State *L)
{
	StringView view = read_string_view(L, address_argument(L), sizeof(WCHAR));
	size_t size = read_size(L, (lua_Number)view.length * sizeof(WCHAR));
	WCHAR *text;
	char *utf8;
	int utf8_size;

	if (view.length == 0) {
		lua_pushliteral(L, "");
		return 1;
	}
	text = lua_newuserdata(L, size);
	read_or_fail(L, view.data, text, size);
	utf8_size = WideCharToMultiByte(CP_UTF8, 0, text, (int)view.length, NULL, 0, NULL, NULL);
	utf8 = lua_newuserdata(L, (size_t)utf8_size);
	WideCharToMultiByte(CP_UTF8, 0, text, (int)view.length, utf8, utf8_size, NULL, NULL);
	lua_pushlstring(L, utf8, (size_t)utf8_size);
	return 1;
}

static int l_read_array(lua_State *L)
{
	CaVector vector;

	read_or_fail(L, address_argument(L), &vector, sizeof vector);
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
	INT_PTR address = address_argument(L);
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
	INT_PTR address = address_argument(L);
	TypedValue *value = to_value(L, 3);
	BOOL written;

	if (lua_type(L, 3) == LUA_TBOOLEAN) {
		BYTE byte = (BYTE)lua_toboolean(L, 3);
		written = write_memory(address, &byte, sizeof byte);
	} else if (lua_type(L, 3) == LUA_TNUMBER) {
		float number = (float)lua_tonumber(L, 3);
		written = write_memory(address, &number, sizeof number);
	} else if (lua_type(L, 3) == LUA_TSTRING) {
		size_t length;
		const char *bytes = lua_tolstring(L, 3, &length);
		written = write_memory(address, bytes, length);
	} else if (value) {
		written = write_memory(address, &value->pointer, value_size(value->type));
	} else {
		return luaL_error(L, "passed invalid argument type");
	}

	if (!written)
		return luaL_error(L, "failed to write memory");
	return 0;
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
	{ "read_boolean", l_read_boolean },
	{ "read_string", l_read_string },
	{ "read_unistring", l_read_unistring },
	{ "read_array", l_read_array },
	{ "read_rowidx", l_read_rowidx },
	{ "read", l_read },
	{ "write", l_write },
	{ NULL, NULL }
};
