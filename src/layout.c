#include <string.h>

#include "common.h"

enum { OFFSET = 1, TYPE, INNER, STRIDE };
enum { MAX_DEPTH = 16, MAX_ELEMENTS = 1 << 17, MAX_OFFSET = 1 << 24, LUA_SLOTS_PER_LEVEL = 8 };

enum FieldType {
	FIELD_FLOAT = VALUE_TYPE_COUNT,
	FIELD_DOUBLE,
	FIELD_BOOLEAN,
	FIELD_STRING,
	FIELD_UNISTRING,
	FIELD_ADDRESS,
	FIELD_STRUCT,
	FIELD_VECTOR,
	FIELD_LIST,
	FIELD_TYPE_COUNT
};

static const char *const more_field_type_names[FIELD_TYPE_COUNT - VALUE_TYPE_COUNT] = {
	"float", "double", "boolean", "string", "unistring", "address", "struct", "vector", "list"
};

typedef struct {
	const char *name;
	int index;
} Step;

typedef struct {
	Step steps[MAX_DEPTH + 1];
	int step_count;
	int depth;
	int elements_left;
	int types;
} Walk;

static void push_field(lua_State *L, Walk *walk, int field, INT_PTR base);

static void fail(lua_State *L, const Walk *walk, const char *message)
{
	luaL_Buffer path;
	int i;

	luaL_buffinit(L, &path);
	for (i = 0; i < walk->step_count; i++) {
		if (walk->steps[i].name) {
			if (i > 0)
				luaL_addchar(&path, '.');
			luaL_addstring(&path, walk->steps[i].name);
		} else {
			lua_pushfstring(L, "[%d]", walk->steps[i].index);
			luaL_addvalue(&path);
		}
	}
	luaL_pushresult(&path);
	if (lua_objlen(L, -1) == 0)
		luaL_error(L, "%s", message);
	luaL_error(L, "%s: %s", lua_tostring(L, -1), message);
}

static void check_field_read(lua_State *L, const Walk *walk, int result)
{
	if (result == READ_OK)
		return;
	push_read_error(L, result);
	fail(L, walk, lua_tostring(L, -1));
}

static void read_field_memory(lua_State *L, const Walk *walk, INT_PTR address, void *destination, size_t size)
{
	check_field_read(L, walk, copy_memory(destination, address, size) ? READ_OK : READ_FAILED);
}

static void enter(lua_State *L, Walk *walk)
{
	if (++walk->depth > MAX_DEPTH)
		fail(L, walk, lua_pushfstring(L, "layouts nested deeper than %d", MAX_DEPTH));
	if (!lua_checkstack(L, LUA_SLOTS_PER_LEVEL))
		fail(L, walk, "Lua stack overflow");
}

static void push_step(Walk *walk, const char *name, int index)
{
	walk->steps[walk->step_count].name = name;
	walk->steps[walk->step_count].index = index;
	walk->step_count++;
}

static void pop_step(Walk *walk)
{
	walk->step_count--;
}

static void spend(lua_State *L, Walk *walk, int elements)
{
	if (elements > walk->elements_left)
		fail(L, walk, lua_pushfstring(L, "more than %d elements in one read", MAX_ELEMENTS));
	walk->elements_left -= elements;
}

static INT64 whole_number(lua_State *L, const Walk *walk, int table, int slot, INT64 minimum, const char *what)
{
	lua_Number number;

	lua_rawgeti(L, table, slot);
	number = lua_tonumber(L, -1);
	if (lua_type(L, -1) != LUA_TNUMBER || !(number >= minimum && number < MAX_OFFSET) || number != (INT64)number)
		fail(L, walk, lua_pushfstring(L, "%s must be a whole number from %d to %d", what, (int)minimum, MAX_OFFSET - 1));
	lua_pop(L, 1);
	return (INT64)number;
}

static int field_type(lua_State *L, const Walk *walk, int field)
{
	int type;

	lua_rawgeti(L, field, TYPE);
	lua_pushvalue(L, -1);
	lua_rawget(L, walk->types);
	if (lua_type(L, -1) != LUA_TNUMBER)
		fail(L, walk, lua_pushfstring(L, "unknown field type '%s'",
			lua_type(L, -2) == LUA_TSTRING ? lua_tostring(L, -2) : luaL_typename(L, -2)));
	type = (int)lua_tonumber(L, -1);
	lua_pop(L, 2);
	return type;
}

static const char *field_type_name(int type)
{
	return type < VALUE_TYPE_COUNT ? value_type_names[type] : more_field_type_names[type - VALUE_TYPE_COUNT];
}

static BOOL is_integer(int type)
{
	return type != VALUE_POINTER && type < VALUE_TYPE_COUNT;
}

static void check_inner(lua_State *L, const Walk *walk, int type, int inner)
{
	const char *name = field_type_name(type);
	BOOL is_empty = lua_isnil(L, inner);
	BOOL is_table = lua_istable(L, inner);
	BOOL is_exact = lua_type(L, inner) == LUA_TBOOLEAN && lua_toboolean(L, inner);

	if (is_integer(type)) {
		if (!is_empty && !is_exact)
			fail(L, walk, lua_pushfstring(L, "'%s' takes only true as its third value", name));
		return;
	}
	switch (type) {
	case VALUE_POINTER:
		if (!is_empty && !is_table)
			fail(L, walk, "'pointer' takes a field as its third value");
		return;
	case FIELD_STRUCT:
	case FIELD_VECTOR:
	case FIELD_LIST:
		if (!is_table)
			fail(L, walk, lua_pushfstring(L, "'%s' needs a %s as its third value", name,
				type == FIELD_STRUCT ? "layout" : "field"));
		return;
	default:
		if (!is_empty)
			fail(L, walk, lua_pushfstring(L, "'%s' takes no third value", name));
	}
}

static int count_fields(lua_State *L, int layout)
{
	int count = 0;
	for (lua_pushnil(L); lua_next(L, layout); lua_pop(L, 1))
		count++;
	return count;
}

static void push_struct(lua_State *L, Walk *walk, int layout, INT_PTR base)
{
	enter(L, walk);
	lua_createtable(L, 0, count_fields(L, layout));
	for (lua_pushnil(L); lua_next(L, layout); lua_pop(L, 1)) {
		if (lua_type(L, -2) == LUA_TSTRING)
			push_step(walk, lua_tostring(L, -2), 0);
		else if (lua_type(L, -2) == LUA_TNUMBER)
			push_step(walk, NULL, (int)lua_tonumber(L, -2));
		else
			fail(L, walk, "layout keys must be names or numbers");
		push_field(L, walk, lua_gettop(L), base);
		pop_step(walk);
		lua_pushvalue(L, -3);
		lua_insert(L, -2);
		lua_rawset(L, -5);
	}
	walk->depth--;
}

static void push_vector(lua_State *L, Walk *walk, int element, INT64 stride, INT_PTR address)
{
	CaVector vector;
	int count, i;

	read_field_memory(L, walk, address, &vector, sizeof vector);
	count = vector.size > 0 ? vector.size : 0;
	spend(L, walk, count);
	enter(L, walk);
	lua_createtable(L, count, 0);
	for (i = 1; i <= count; i++) {
		push_step(walk, NULL, i);
		push_field(L, walk, element, vector.data + (INT_PTR)((i - 1) * stride));
		pop_step(walk);
		lua_rawseti(L, -2, i);
	}
	walk->depth--;
}

static void push_list(lua_State *L, Walk *walk, int element, INT_PTR address)
{
	CaList list;
	CaListNode header;
	INT_PTR end = address + offsetof(CaList, last);
	INT_PTR previous = 0;
	INT_PTR node;
	int i;

	read_field_memory(L, walk, address, &list, sizeof list);
	enter(L, walk);
	lua_newtable(L);
	for (i = 1, node = list.first; node != end; i++, previous = node, node = header.next) {
		push_step(walk, NULL, i);
		if (i > list.size)
			fail(L, walk, "list longer than its size");
		spend(L, walk, 1);
		read_field_memory(L, walk, node, &header, sizeof header);
		if (header.previous != previous)
			fail(L, walk, "broken list link");
		push_field(L, walk, element, node);
		pop_step(walk);
		lua_rawseti(L, -2, i);
	}
	if (i - 1 != list.size)
		fail(L, walk, "list shorter than its size");
	walk->depth--;
}

static void push_pointer(lua_State *L, Walk *walk, int inner, INT_PTR address)
{
	INT_PTR pointer;

	read_field_memory(L, walk, address, &pointer, sizeof pointer);
	if (!pointer) {
		lua_pushboolean(L, 0);
		return;
	}
	if (lua_isnil(L, inner)) {
		push_value(L, VALUE_POINTER, pointer);
		return;
	}
	enter(L, walk);
	push_field(L, walk, inner, pointer);
	walk->depth--;
}

static void push_scalar(lua_State *L, const Walk *walk, int type, INT_PTR address, BOOL exact)
{
	float single;
	double number;
	BYTE byte;

	switch (type) {
	case FIELD_FLOAT:
		read_field_memory(L, walk, address, &single, sizeof single);
		lua_pushnumber(L, single);
		return;
	case FIELD_DOUBLE:
		read_field_memory(L, walk, address, &number, sizeof number);
		lua_pushnumber(L, (lua_Number)number);
		return;
	case FIELD_BOOLEAN:
		read_field_memory(L, walk, address, &byte, sizeof byte);
		lua_pushboolean(L, byte != 0);
		return;
	case FIELD_STRING:
		check_field_read(L, walk, push_string(L, address, sizeof(char)));
		return;
	case FIELD_UNISTRING:
		check_field_read(L, walk, push_unistring(L, address));
		return;
	case FIELD_ADDRESS:
		push_value(L, VALUE_POINTER, address);
		return;
	default:
		check_field_read(L, walk, push_integer(L, address, type, exact));
	}
}

static void push_field(lua_State *L, Walk *walk, int field, INT_PTR base)
{
	INT_PTR address;
	int type, inner;

	if (!lua_istable(L, field))
		fail(L, walk, "a field must be a table {offset, type, ...}");
	address = base + (INT_PTR)whole_number(L, walk, field, OFFSET, 0, "offset");
	type = field_type(L, walk, field);
	lua_rawgeti(L, field, INNER);
	inner = lua_gettop(L);
	check_inner(L, walk, type, inner);

	switch (type) {
	case VALUE_POINTER:
		push_pointer(L, walk, inner, address);
		break;
	case FIELD_STRUCT:
		push_struct(L, walk, inner, address);
		break;
	case FIELD_VECTOR:
		push_vector(L, walk, inner, whole_number(L, walk, field, STRIDE, 1, "stride"), address);
		break;
	case FIELD_LIST:
		push_list(L, walk, inner, address);
		break;
	default:
		push_scalar(L, walk, type, address, lua_toboolean(L, inner));
	}
	lua_remove(L, inner);
}

static int push_field_types(lua_State *L)
{
	int type;

	lua_pushlightuserdata(L, (void *)more_field_type_names);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_createtable(L, 0, FIELD_TYPE_COUNT);
		for (type = 0; type < FIELD_TYPE_COUNT; type++) {
			lua_pushnumber(L, (lua_Number)type);
			lua_setfield(L, -2, field_type_name(type));
		}
		lua_pushlightuserdata(L, (void *)more_field_type_names);
		lua_pushvalue(L, -2);
		lua_rawset(L, LUA_REGISTRYINDEX);
	}
	return lua_gettop(L);
}

static INT_PTR start_walk(lua_State *L, Walk *walk, int field)
{
	INT_PTR address = check_pointer(L, 1) + (INT_PTR)to_offset(L, 2);

	luaL_checktype(L, field, LUA_TTABLE);
	memset(walk, 0, sizeof *walk);
	walk->elements_left = MAX_ELEMENTS;
	walk->types = push_field_types(L);
	return address;
}

static int l_read_struct(lua_State *L)
{
	Walk walk;
	INT_PTR address = start_walk(L, &walk, 3);

	push_struct(L, &walk, 3, address);
	return 1;
}

static int l_read_vector(lua_State *L)
{
	Walk walk;
	lua_Number stride = luaL_checknumber(L, 4);
	INT_PTR address;

	if (!(stride >= 1 && stride < MAX_OFFSET) || stride != (INT64)stride)
		luaL_argerror(L, 4, lua_pushfstring(L, "stride must be a whole number from 1 to %d", MAX_OFFSET - 1));
	address = start_walk(L, &walk, 3);
	push_vector(L, &walk, 3, (INT64)stride, address);
	return 1;
}

static int l_read_list(lua_State *L)
{
	Walk walk;
	INT_PTR address = start_walk(L, &walk, 3);

	push_list(L, &walk, 3, address);
	return 1;
}

static INT64 chain_offset(lua_State *L, int index)
{
	lua_Number number = lua_tonumber(L, index);

	if (lua_type(L, index) == LUA_TNUMBER && (number >= MAX_OFFSET || number <= -MAX_OFFSET))
		luaL_argerror(L, index, lua_pushfstring(L, "offsets from %d on lose precision as numbers, pass a typed value", MAX_OFFSET));
	return to_offset(L, index);
}

static int l_read_chain(lua_State *L)
{
	int count = lua_gettop(L);
	INT_PTR pointer;
	int i;

	if (lua_isnoneornil(L, 1)) {
		lua_pushnil(L);
		return 1;
	}
	pointer = check_pointer(L, 1);
	for (i = 2; i <= count && pointer; i++)
		if (!copy_memory(&pointer, pointer + (INT_PTR)chain_offset(L, i), sizeof pointer))
			return luaL_error(L, "failed to read memory at offset #%d", i - 1);
	if (!pointer)
		lua_pushnil(L);
	else
		push_value(L, VALUE_POINTER, pointer);
	return 1;
}

const luaL_Reg layout_functions[] = {
	{ "read_struct", l_read_struct },
	{ "read_vector", l_read_vector },
	{ "read_list", l_read_list },
	{ "read_chain", l_read_chain },
	{ NULL, NULL }
};
