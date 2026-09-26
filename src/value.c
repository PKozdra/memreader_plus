#include <stdio.h>
#include <string.h>

#include "common.h"

enum Operation { ADD, SUBTRACT, MULTIPLY, DIVIDE };
enum Comparison { GREATER, LESS, EQUAL };
enum { INTEGER_STRING_WIDTH = sizeof(INT32) };

static const char *const type_names[VALUE_TYPE_COUNT] = {
	"pointer", "uint8", "int8", "uint16", "int16", "uint32", "int32"
};
static const size_t type_sizes[VALUE_TYPE_COUNT] = {
	sizeof(INT_PTR), sizeof(UINT8), sizeof(INT8), sizeof(UINT16), sizeof(INT16), sizeof(UINT32), sizeof(INT32)
};
static const char *const operation_names[] = { "addition", "subtraction", "multiplication", "divide" };
static const char *const comparison_symbols[] = { ">", "<", "==" };

_Static_assert(offsetof(TypedValue, pointer) == 8 && sizeof(TypedValue) == 16, "TypedValue must match memreader's layout");

size_t value_size(int type)
{
	return type_sizes[type];
}

TypedValue *push_value(lua_State *L, int type, INT64 number)
{
	TypedValue *value = lua_newuserdata(L, sizeof(TypedValue));
	value->type = (BYTE)type;
	value->pointer = 0;
	switch (type) {
	case VALUE_POINTER: value->pointer = (INT_PTR)number; break;
	case VALUE_UINT8:   value->uint8 = (UINT8)number; break;
	case VALUE_INT8:    value->int8 = (INT8)number; break;
	case VALUE_UINT16:  value->uint16 = (UINT16)number; break;
	case VALUE_INT16:   value->int16 = (INT16)number; break;
	case VALUE_UINT32:  value->uint32 = (UINT32)number; break;
	case VALUE_INT32:   value->int32 = (INT32)number; break;
	}
	return value;
}

TypedValue *to_value(lua_State *L, int index)
{
	TypedValue *value;
	if (lua_type(L, index) != LUA_TUSERDATA || lua_objlen(L, index) != sizeof(TypedValue))
		return NULL;
	if (lua_getmetatable(L, index)) {
		lua_pop(L, 1);
		return NULL;
	}
	value = lua_touserdata(L, index);
	return value->type < VALUE_TYPE_COUNT ? value : NULL;
}

INT64 value_to_integer(const TypedValue *value)
{
	switch (value->type) {
	case VALUE_POINTER: return value->pointer;
	case VALUE_UINT8:   return value->uint8;
	case VALUE_INT8:    return value->int8;
	case VALUE_UINT16:  return value->uint16;
	case VALUE_INT16:   return value->int16;
	case VALUE_UINT32:  return value->uint32;
	case VALUE_INT32:   return value->int32;
	}
	return 0;
}

static INT64 bytes_to_integer(const char *bytes, size_t length, size_t width)
{
	UINT64 result = 0;
	memcpy(&result, bytes, length < width ? length : width);
	return (INT64)result;
}

BOOL to_integer(lua_State *L, int index, size_t string_width, INT64 *result)
{
	size_t length;
	const char *bytes;
	TypedValue *value;

	if (lua_type(L, index) == LUA_TNUMBER) {
		*result = (INT64)lua_tonumber(L, index);
		return TRUE;
	}
	if (lua_type(L, index) == LUA_TSTRING) {
		bytes = lua_tolstring(L, index, &length);
		*result = bytes_to_integer(bytes, length, string_width);
		return TRUE;
	}
	value = to_value(L, index);
	if (value && value->type != VALUE_POINTER) {
		*result = value_to_integer(value);
		return TRUE;
	}
	return FALSE;
}

INT64 to_offset(lua_State *L, int index)
{
	INT64 offset;
	return to_integer(L, index, INTEGER_STRING_WIDTH, &offset) ? offset : 0;
}

INT_PTR check_pointer(lua_State *L, int index)
{
	size_t length;
	const char *bytes;
	TypedValue *value = to_value(L, index);

	if (value && value->type == VALUE_POINTER)
		return value->pointer;
	if (lua_type(L, index) == LUA_TSTRING) {
		bytes = lua_tolstring(L, index, &length);
		return (INT_PTR)bytes_to_integer(bytes, length, sizeof(INT_PTR));
	}
	return luaL_error(L, "expected pointer argument in the form of raw string or pointer type");
}

static int make_value(lua_State *L, int type)
{
	size_t length;
	const char *bytes;
	TypedValue *value = to_value(L, 1);

	if (lua_type(L, 1) == LUA_TNUMBER && type != VALUE_POINTER) {
		push_value(L, type, (INT64)lua_tonumber(L, 1));
		return 1;
	}
	if (lua_type(L, 1) == LUA_TSTRING) {
		bytes = lua_tolstring(L, 1, &length);
		push_value(L, type, bytes_to_integer(bytes, length, value_size(type)));
		return 1;
	}
	if (value && value->type == VALUE_POINTER && type == VALUE_POINTER) {
		lua_pushvalue(L, 1);
		return 1;
	}
	return luaL_error(L, "attempt to convert %s into %s", luaL_typename(L, 1), type_names[type]);
}

static int l_pointer(lua_State *L) { return make_value(L, VALUE_POINTER); }
static int l_uint8(lua_State *L)   { return make_value(L, VALUE_UINT8); }
static int l_int8(lua_State *L)    { return make_value(L, VALUE_INT8); }
static int l_uint16(lua_State *L)  { return make_value(L, VALUE_UINT16); }
static int l_int16(lua_State *L)   { return make_value(L, VALUE_INT16); }
static int l_uint32(lua_State *L)  { return make_value(L, VALUE_UINT32); }
static int l_int32(lua_State *L)   { return make_value(L, VALUE_INT32); }

static int arithmetic_error(lua_State *L, int operation)
{
	return luaL_error(L, "attempt to perform %s operation on %s and %s",
		operation_names[operation], luaL_typename(L, 1), luaL_typename(L, 2));
}

static lua_Number calculate_number(int operation, lua_Number a, lua_Number b)
{
	switch (operation) {
	case ADD:      return a + b;
	case SUBTRACT: return a - b;
	case MULTIPLY: return a * b;
	default:       return a / b;
	}
}

static INT64 calculate_integer(lua_State *L, int operation, INT64 a, INT64 b)
{
	switch (operation) {
	case ADD:      return a + b;
	case SUBTRACT: return a - b;
	case MULTIPLY: return a * b;
	default:
		if (b == 0)
			luaL_error(L, "attempt to divide by zero");
		return a / b;
	}
}

static int arithmetic(lua_State *L, int operation)
{
	TypedValue *left = to_value(L, 1);
	TypedValue *right_value = to_value(L, 2);
	INT64 right;

	if (lua_type(L, 1) == LUA_TNUMBER) {
		if (lua_type(L, 2) == LUA_TNUMBER)
			lua_pushnumber(L, calculate_number(operation, lua_tonumber(L, 1), lua_tonumber(L, 2)));
		else if (right_value && right_value->type != VALUE_POINTER)
			lua_pushnumber(L, calculate_number(operation, lua_tonumber(L, 1), (lua_Number)value_to_integer(right_value)));
		else
			return arithmetic_error(L, operation);
		return 1;
	}
	if (!left || (left->type == VALUE_POINTER && operation == MULTIPLY))
		return arithmetic_error(L, operation);
	if (left->type == VALUE_POINTER && operation == SUBTRACT && right_value && right_value->type == VALUE_POINTER) {
		push_value(L, VALUE_POINTER, left->pointer - right_value->pointer);
		return 1;
	}
	if (!to_integer(L, 2, INTEGER_STRING_WIDTH, &right))
		return arithmetic_error(L, operation);
	push_value(L, left->type, calculate_integer(L, operation, value_to_integer(left), right));
	return 1;
}

static int l_add(lua_State *L)  { return arithmetic(L, ADD); }
static int l_sub(lua_State *L)  { return arithmetic(L, SUBTRACT); }
static int l_mult(lua_State *L) { return arithmetic(L, MULTIPLY); }
static int l_div(lua_State *L)  { return arithmetic(L, DIVIDE); }

static int comparison_error(lua_State *L, int comparison)
{
	return luaL_error(L, "attempt to perform %s operation on %s and %s",
		comparison_symbols[comparison], luaL_typename(L, 1), luaL_typename(L, 2));
}

static int compare(lua_State *L, int comparison)
{
	TypedValue *left = to_value(L, 1);
	TypedValue *right_value = to_value(L, 2);
	INT64 a, b;

	if (!left)
		return comparison_error(L, comparison);
	a = value_to_integer(left);
	if (right_value)
		b = value_to_integer(right_value);
	else if (!to_integer(L, 2, left->type == VALUE_POINTER ? sizeof(INT_PTR) : INTEGER_STRING_WIDTH, &b))
		return comparison_error(L, comparison);

	switch (comparison) {
	case GREATER: lua_pushboolean(L, a > b); break;
	case LESS:    lua_pushboolean(L, a < b); break;
	default:      lua_pushboolean(L, a == b); break;
	}
	return 1;
}

static int l_gt(lua_State *L) { return compare(L, GREATER); }
static int l_lt(lua_State *L) { return compare(L, LESS); }
static int l_eq(lua_State *L) { return compare(L, EQUAL); }

static int l_type(lua_State *L)
{
	TypedValue *value = to_value(L, 1);

	switch (lua_type(L, 1)) {
	case LUA_TNONE:
	case LUA_TNIL:     lua_pushliteral(L, "nil"); return 1;
	case LUA_TBOOLEAN: lua_pushliteral(L, "boolean"); return 1;
	case LUA_TNUMBER:  lua_pushliteral(L, "float"); return 1;
	case LUA_TSTRING:  lua_pushliteral(L, "bytes"); return 1;
	}
	if (!value)
		return luaL_error(L, "invalid type %s", luaL_typename(L, 1));
	lua_pushstring(L, type_names[value->type]);
	return 1;
}

static void push_hex(lua_State *L, int index)
{
	static const char digits[] = "0123456789ABCDEF";
	size_t length, i;
	const unsigned char *bytes = (const unsigned char *)lua_tolstring(L, index, &length);
	luaL_Buffer buffer;

	luaL_buffinit(L, &buffer);
	for (i = 0; i < length; i++) {
		luaL_addchar(&buffer, digits[bytes[i] >> 4]);
		luaL_addchar(&buffer, digits[bytes[i] & 0x0F]);
	}
	luaL_pushresult(&buffer);
}

static int l_tostring(lua_State *L)
{
	char text[sizeof "-9223372036854775808"];
	TypedValue *value = to_value(L, 1);

	switch (lua_type(L, 1)) {
	case LUA_TNONE:
	case LUA_TNIL:     lua_pushliteral(L, "nil"); return 1;
	case LUA_TBOOLEAN: lua_pushstring(L, lua_toboolean(L, 1) ? "true" : "false"); return 1;
	case LUA_TNUMBER:  lua_pushstring(L, lua_tostring(L, 1)); return 1;
	case LUA_TSTRING:  push_hex(L, 1); return 1;
	}
	if (!value)
		return luaL_error(L, "attempt to print %s as special type", luaL_typename(L, 1));
	if (value->type == VALUE_POINTER) {
		lua_pushfstring(L, "%p", (void *)value->pointer);
		return 1;
	}
	sprintf_s(text, sizeof text, "%lld", value_to_integer(value));
	lua_pushstring(L, text);
	return 1;
}

static int l_tonumber(lua_State *L)
{
	lua_pushnumber(L, (lua_Number)to_offset(L, 1));
	return 1;
}

static int l_createtable(lua_State *L)
{
	INT64 array_size = to_offset(L, 1);
	INT64 hash_size = to_offset(L, 2);
	lua_createtable(L, array_size > 0 ? (int)array_size : 0, hash_size > 0 ? (int)hash_size : 0);
	return 1;
}

const luaL_Reg value_functions[] = {
	{ "pointer", l_pointer },
	{ "uint8", l_uint8 },
	{ "int8", l_int8 },
	{ "uint16", l_uint16 },
	{ "int16", l_int16 },
	{ "uint32", l_uint32 },
	{ "int32", l_int32 },
	{ "add", l_add },
	{ "sub", l_sub },
	{ "mult", l_mult },
	{ "div", l_div },
	{ "gt", l_gt },
	{ "lt", l_lt },
	{ "eq", l_eq },
	{ "type", l_type },
	{ "tostring", l_tostring },
	{ "tonumber", l_tonumber },
	{ "createtable", l_createtable },
	{ NULL, NULL }
};
