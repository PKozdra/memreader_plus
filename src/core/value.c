#include <stdio.h>
#include <string.h>

#include "common.h"

enum Operation { ADD, SUBTRACT, MULTIPLY, DIVIDE };
enum Comparison { GREATER, LESS, EQUAL };
enum { MAX_TABLE_SIZE_HINT = 1 << 20, INTEGER_STRING_WIDTH = sizeof(INT32) };

const char *const value_type_names[VALUE_TYPE_COUNT] = {
	"pointer", "uint8", "int8", "uint16", "int16", "uint32", "int32", "int64", "uint64"
};
static const size_t type_sizes[VALUE_TYPE_COUNT] = {
	sizeof(INT_PTR), sizeof(UINT8), sizeof(INT8), sizeof(UINT16), sizeof(INT16), sizeof(UINT32), sizeof(INT32),
	sizeof(INT64), sizeof(UINT64)
};
static const char *const operation_names[] = { "addition", "subtraction", "multiplication", "divide" };
static const char *const comparison_symbols[] = { ">", "<", "==" };
static char interned_keys[VALUE_TYPE_COUNT];

_Static_assert(offsetof(TypedValue, pointer) == 8 && sizeof(TypedValue) == 16, "TypedValue must match memreader's layout");

size_t value_size(int type)
{
	return type_sizes[type];
}

static void push_interned_values(lua_State *L, int type)
{
	lua_pushlightuserdata(L, &interned_keys[type]);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (!lua_isnil(L, -1))
		return;
	lua_pop(L, 1);
	lua_newtable(L);
	lua_createtable(L, 0, 1);
	lua_pushliteral(L, "v");
	lua_setfield(L, -2, "__mode");
	lua_setmetatable(L, -2);
	lua_pushlightuserdata(L, &interned_keys[type]);
	lua_pushvalue(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
}

static void set_value(TypedValue *value, int type, INT64 number)
{
	memset(value, 0, sizeof *value);
	value->type = (BYTE)type;
	switch (type) {
	case VALUE_POINTER: value->pointer = (INT_PTR)number; break;
	case VALUE_UINT8:   value->uint8 = (UINT8)number; break;
	case VALUE_INT8:    value->int8 = (INT8)number; break;
	case VALUE_UINT16:  value->uint16 = (UINT16)number; break;
	case VALUE_INT16:   value->int16 = (INT16)number; break;
	case VALUE_UINT32:  value->uint32 = (UINT32)number; break;
	case VALUE_INT32:   value->int32 = (INT32)number; break;
	case VALUE_INT64:   value->int64 = number; break;
	case VALUE_UINT64:  value->uint64 = (UINT64)number; break;
	}
}

TypedValue *push_value(lua_State *L, int type, INT64 number)
{
	TypedValue value, *interned;

	set_value(&value, type, number);
	push_interned_values(L, type);
	lua_pushlightuserdata(L, (void *)value.pointer);
	lua_pushvalue(L, -1);
	lua_rawget(L, -3);
	interned = lua_touserdata(L, -1);
	if (interned && memcmp(interned, &value, sizeof value) == 0) {
		lua_replace(L, -3);
		lua_pop(L, 1);
		return interned;
	}
	lua_pop(L, 1);
	interned = lua_newuserdata(L, sizeof value);
	memcpy(interned, &value, sizeof value);
	lua_pushvalue(L, -1);
	lua_insert(L, -4);
	lua_rawset(L, -3);
	lua_pop(L, 1);
	return interned;
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
	case VALUE_INT64:   return value->int64;
	case VALUE_UINT64:  return (INT64)value->uint64;
	}
	return 0;
}

INT64 narrow_integer(int type, INT64 number)
{
	TypedValue value;

	set_value(&value, type, number);
	return value_to_integer(&value);
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

INT64 whole_argument(lua_State *L, int index, INT64 low, INT64 high, const char *name)
{
	lua_Number number = luaL_checknumber(L, index);

	if (!(number >= (lua_Number)low && number <= (lua_Number)high) || number != (lua_Number)(INT64)number)
		luaL_argerror(L, index, lua_pushfstring(L, "%s must be a whole number from %d to %d", name, (int)low, (int)high));
	return (INT64)number;
}

INT_PTR address_argument(lua_State *L, int index)
{
	return check_pointer(L, index) + (INT_PTR)to_offset(L, index + 1);
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
	return luaL_error(L, "attempt to convert %s into %s", luaL_typename(L, 1), value_type_names[type]);
}

static int l_pointer(lua_State *L) { return make_value(L, VALUE_POINTER); }
static int l_uint8(lua_State *L)   { return make_value(L, VALUE_UINT8); }
static int l_int8(lua_State *L)    { return make_value(L, VALUE_INT8); }
static int l_uint16(lua_State *L)  { return make_value(L, VALUE_UINT16); }
static int l_int16(lua_State *L)   { return make_value(L, VALUE_INT16); }
static int l_uint32(lua_State *L)  { return make_value(L, VALUE_UINT32); }
static int l_int32(lua_State *L)   { return make_value(L, VALUE_INT32); }
static int l_int64(lua_State *L)   { return make_value(L, VALUE_INT64); }
static int l_uint64(lua_State *L)  { return make_value(L, VALUE_UINT64); }

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

static INT64 calculate_integer(lua_State *L, int operation, INT64 a, INT64 b, BOOL is_unsigned)
{
	switch (operation) {
	case ADD:      return (INT64)((UINT64)a + (UINT64)b);
	case SUBTRACT: return (INT64)((UINT64)a - (UINT64)b);
	case MULTIPLY: return (INT64)((UINT64)a * (UINT64)b);
	default:
		if (b == 0)
			luaL_error(L, "attempt to divide by zero");
		if (is_unsigned)
			return (INT64)((UINT64)a / (UINT64)b);
		if (b == -1)
			return (INT64)(0 - (UINT64)a);
		return a / b;
	}
}

static lua_Number value_to_number(const TypedValue *value)
{
	return value->type == VALUE_UINT64 ? (lua_Number)value->uint64 : (lua_Number)value_to_integer(value);
}

static size_t string_width(int type)
{
	return type == VALUE_INT64 || type == VALUE_UINT64 ? value_size(type) : INTEGER_STRING_WIDTH;
}

static int arithmetic(lua_State *L, int operation)
{
	TypedValue *left = to_value(L, 1);
	TypedValue *right_value = to_value(L, 2);
	BOOL is_unsigned;
	INT64 right;

	if (lua_type(L, 1) == LUA_TNUMBER) {
		if (lua_type(L, 2) == LUA_TNUMBER)
			lua_pushnumber(L, calculate_number(operation, lua_tonumber(L, 1), lua_tonumber(L, 2)));
		else if (right_value && right_value->type != VALUE_POINTER)
			lua_pushnumber(L, calculate_number(operation, lua_tonumber(L, 1), value_to_number(right_value)));
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
	if (!to_integer(L, 2, string_width(left->type), &right))
		return arithmetic_error(L, operation);
	is_unsigned = left->type == VALUE_UINT64 || (right_value && right_value->type == VALUE_UINT64);
	push_value(L, left->type, calculate_integer(L, operation, value_to_integer(left), right, is_unsigned));
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

static BOOL compare_integers(int comparison, INT64 a, INT64 b, BOOL is_unsigned)
{
	if (comparison == EQUAL)
		return a == b;
	if (is_unsigned)
		return comparison == GREATER ? (UINT64)a > (UINT64)b : (UINT64)a < (UINT64)b;
	return comparison == GREATER ? a > b : a < b;
}

static int compare(lua_State *L, int comparison)
{
	TypedValue *left = to_value(L, 1);
	TypedValue *right_value = to_value(L, 2);
	BOOL is_unsigned;
	INT64 a, b;

	if (!left)
		return comparison_error(L, comparison);
	a = value_to_integer(left);
	if (right_value)
		b = value_to_integer(right_value);
	else if (!to_integer(L, 2, left->type == VALUE_POINTER ? sizeof(INT_PTR) : string_width(left->type), &b))
		return comparison_error(L, comparison);

	is_unsigned = left->type == VALUE_UINT64 || (right_value && right_value->type == VALUE_UINT64);
	lua_pushboolean(L, compare_integers(comparison, a, b, is_unsigned));
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
	lua_pushstring(L, value_type_names[value->type]);
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
	sprintf_s(text, sizeof text, value->type == VALUE_UINT64 ? "%llu" : "%lld", value_to_integer(value));
	lua_pushstring(L, text);
	return 1;
}

static int l_tonumber(lua_State *L)
{
	TypedValue *value = to_value(L, 1);

	if (value && value->type == VALUE_UINT64)
		lua_pushnumber(L, (lua_Number)value->uint64);
	else
		lua_pushnumber(L, (lua_Number)to_offset(L, 1));
	return 1;
}

static int table_size_hint(lua_State *L, int index)
{
	INT64 size = to_offset(L, index);
	if (size <= 0)
		return 0;
	return size < MAX_TABLE_SIZE_HINT ? (int)size : MAX_TABLE_SIZE_HINT;
}

static int l_is_null(lua_State *L)
{
	TypedValue *value = to_value(L, 1);
	INT64 number = 0;

	if (lua_type(L, 1) == LUA_TBOOLEAN && !lua_toboolean(L, 1))
		number = 0;
	else if (value)
		number = value_to_integer(value);
	else if (!lua_isnoneornil(L, 1) && !to_integer(L, 1, sizeof(INT_PTR), &number))
		return luaL_typerror(L, 1, "pointer, number, bytes, false or nil");
	lua_pushboolean(L, number == 0);
	return 1;
}

static int l_createtable(lua_State *L)
{
	lua_createtable(L, table_size_hint(L, 1), table_size_hint(L, 2));
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
	{ "int64", l_int64 },
	{ "uint64", l_uint64 },
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
	{ "is_null", l_is_null },
	{ "createtable", l_createtable },
	{ NULL, NULL }
};
