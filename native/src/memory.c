#include "memreader_plus.h"

enum {
	STRING_LENGTH_OFFSET = 0,
	STRING_DATA_OFFSET = 8,
	ARRAY_SIZE_OFFSET = 4,
	ARRAY_DATA_OFFSET = 8,
	STACK_BUFFER_SIZE = 1024
};

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

	if (size < 1) {
		lua_pushliteral(L, "");
		return 1;
	}
	return push_memory(L, address, (size_t)size);
}

static int l_read_string(lua_State *L)
{
	INT_PTR address = address_argument(L);
	BOOL is_pointer = flag_argument(L, 3);
	BOOL is_wide = flag_argument(L, 4);
	INT32 length;
	INT_PTR data;

	if (is_pointer)
		read_or_fail(L, address, &address, sizeof address);
	read_or_fail(L, address + STRING_LENGTH_OFFSET, &length, sizeof length);
	if (length <= 0) {
		lua_pushliteral(L, "");
		return 1;
	}
	read_or_fail(L, address + STRING_DATA_OFFSET, &data, sizeof data);
	return push_memory(L, data, (size_t)length * (is_wide ? 2 : 1));
}

static int l_read_array(lua_State *L)
{
	INT_PTR address = address_argument(L);
	INT32 size;
	INT_PTR data = 0;

	read_or_fail(L, address + ARRAY_SIZE_OFFSET, &size, sizeof size);
	if (size > 0)
		read_or_fail(L, address + ARRAY_DATA_OFFSET, &data, sizeof data);

	if (flag_argument(L, 3))
		push_value(L, VALUE_INT32, size);
	else
		lua_pushnumber(L, (lua_Number)size);
	push_value(L, VALUE_POINTER, data);
	return 2;
}

static int l_read_rowidx(lua_State *L)
{
	INT_PTR address = address_argument(L);
	INT_PTR base = check_pointer(L, 3);
	lua_Number row_size = lua_tonumber(L, 4);
	INT_PTR entry;

	read_or_fail(L, address, &entry, sizeof entry);
	lua_pushnumber(L, (lua_Number)(INT64)((entry - base) / row_size) + 1);
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
	{ "read_array", l_read_array },
	{ "read_rowidx", l_read_rowidx },
	{ "read", l_read },
	{ "write", l_write },
	{ NULL, NULL }
};
