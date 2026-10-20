#include <string.h>

#include "asm.h"

enum { DEFAULT_ADDRESS = 0x10000, MAX_DISASSEMBLE = 1024, DISASSEMBLE_LINE = 160 };

static const BYTE byte_order_mark[] = { 0xEF, 0xBB, 0xBF };
static char cave_why[ASM_ERROR_SIZE + 160];

static int l_slot_fits(lua_State *L)
{
	int size = (int)luaL_optinteger(L, 2, 0);

	lua_pushboolean(L, lua_type(L, 1) == LUA_TNUMBER && plain_slot_fits(lua_tonumber(L, 1), size));
	return 1;
}

static Program *new_program(lua_State *L, const char *text, size_t length, INT_PTR address, INT_PTR site, BOOL wildcards)
{
	Program *p = lua_newuserdata(L, sizeof *p);

	memset(p, 0, offsetof(Program, lines));
	if (length >= sizeof byte_order_mark && memcmp(text, byte_order_mark, sizeof byte_order_mark) == 0) {
		text += sizeof byte_order_mark;
		length -= sizeof byte_order_mark;
	}
	p->text = text;
	p->length = length;
	p->address = address;
	p->site = site;
	p->wildcards = wildcards;
	return p;
}

static BOOL is_whole(lua_Number number)
{
	return number > -9.2e18 && number < 9.2e18 && number == (lua_Number)(INT64)number;
}

static BOOL read_value(lua_State *L, Program *p, Name *name)
{
	TypedValue *value = to_value(L, -1);
	size_t length = 0;

	if (lua_isnil(L, -1))
		return TRUE;
	if (lua_type(L, -1) == LUA_TNUMBER && is_whole(lua_tonumber(L, -1))) {
		name->kind = GIVEN_NUMBER;
		name->number = (INT64)lua_tonumber(L, -1);
		return TRUE;
	}
	if (lua_type(L, -1) == LUA_TSTRING) {
		const char *raw = lua_tolstring(L, -1, &length);

		if (length != 1 && length != 2 && length != 4 && length != 8)
			return asm_fail(p, name->line, name->column, "{%s} as a string must be 1, 2, 4 or 8 bytes", name->name);
		name->kind = GIVEN_RAW;
		name->raw_size = (BYTE)length;
		memcpy(name->raw, raw, length);
		return TRUE;
	}
	if (!value)
		return asm_fail(p, name->line, name->column, "{%s} must be a whole number, a pointer value or a string of bytes", name->name);
	name->kind = GIVEN_BITS;
	name->number = value_to_integer(value);
	return TRUE;
}

static BOOL read_values(lua_State *L, Program *p, int values)
{
	int i;
	BOOL ok = TRUE;

	for (i = 0; ok && i < p->name_count && values; i++) {
		lua_pushstring(L, p->names[i].name);
		lua_rawget(L, values);
		ok = read_value(L, p, &p->names[i]);
		lua_pop(L, 1);
	}
	return ok;
}

static BOOL run_program(lua_State *L, Program *p, int values)
{
	if (p->length > ASM_MAX_TEXT)
		return asm_fail(p, 1, 1, "the text is longer than %d bytes", ASM_MAX_TEXT);
	return parse_program(p) && read_values(L, p, values) && build_program(p);
}

static char *make_listing(const Program *p)
{
	Text text;

	text.size = listing_size(p);
	text.used = 0;
	text.data = HeapAlloc(GetProcessHeap(), 0, text.size);
	if (!text.data)
		return NULL;
	text.data[0] = '\0';
	write_listing(p, &text);
	return text.data;
}

static void push_listing(lua_State *L, const Program *p)
{
	Text text;

	text.size = listing_size(p);
	text.used = 0;
	text.data = lua_newuserdata(L, text.size);
	text.data[0] = '\0';
	write_listing(p, &text);
	lua_pushstring(L, text.data);
	lua_remove(L, -2);
}

static void push_slots(lua_State *L, const Program *p)
{
	int i;

	lua_createtable(L, p->slot_count, 0);
	for (i = 0; i < p->slot_count; i++) {
		const Slot *slot = &p->slots[i];

		lua_createtable(L, 0, 5);
		lua_pushstring(L, p->names[slot->name].name);
		lua_setfield(L, -2, "name");
		lua_pushinteger(L, slot->offset);
		lua_setfield(L, -2, "offset");
		lua_pushinteger(L, slot->size);
		lua_setfield(L, -2, "size");
		lua_pushinteger(L, p->lines[slot->line].line);
		lua_setfield(L, -2, "line");
		lua_pushboolean(L, slot->given);
		lua_setfield(L, -2, "given");
		lua_rawseti(L, -2, i + 1);
	}
}

static int push_result(lua_State *L, const Program *p)
{
	lua_pushlstring(L, (const char *)p->image, (size_t)p->total);
	push_listing(L, p);
	push_slots(L, p);
	lua_pushinteger(L, p->code_size);
	return 4;
}

static int l_assemble(lua_State *L)
{
	size_t length;
	const char *text = luaL_checklstring(L, 1, &length);
	INT_PTR address = lua_isnoneornil(L, 2) ? DEFAULT_ADDRESS : pointer_argument(L, 2);
	BOOL wildcards = lua_toboolean(L, 4);
	int values = lua_isnoneornil(L, 3) ? 0 : 3;
	Program *p;

	if (values)
		luaL_checktype(L, values, LUA_TTABLE);
	p = new_program(L, text, length, address, 0, wildcards);
	if (run_program(L, p, values))
		return push_result(L, p);
	lua_pushnil(L);
	lua_pushfstring(L, "asm:%s", p->error);
	return 2;
}

static int l_disassemble(lua_State *L)
{
	INT_PTR address = pointer_argument(L, 1);
	int count = lua_isnoneornil(L, 2) ? 1 : (int)whole_argument(L, 2, 1, MAX_DISASSEMBLE, "count");
	char line[DISASSEMBLE_LINE];
	luaL_Buffer buffer;
	int i, length;

	if (!address)
		return luaL_argerror(L, 1, "address is NULL");
	luaL_buffinit(L, &buffer);
	for (i = 0; i < count; i++) {
		Text text = { line, sizeof line, 0 };

		line[0] = '\0';
		length = disassemble_one(address, &text);
		if (i > 0)
			luaL_addchar(&buffer, '\n');
		luaL_addstring(&buffer, line);
		if (length == 0)
			break;
		address += length;
	}
	luaL_pushresult(&buffer);
	return 1;
}

static const char *string_field(lua_State *L, int spec, const char *key, size_t *length)
{
	const char *text;

	lua_getfield(L, spec, key);
	text = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, length) : NULL;
	return text;
}

static const char *bytes_problem(const Program *p, const char *bytes, size_t size)
{
	size_t shorter = size < (size_t)p->code_size ? size : (size_t)p->code_size, i;

	for (i = 0; i < shorter && (BYTE)bytes[i] == p->image[i]; i++)
		;
	if (i == shorter && size == (size_t)p->code_size)
		return NULL;
	_snprintf_s(cave_why, sizeof cave_why, _TRUNCATE, "asm and bytes differ at +0x%x", (unsigned)i);
	return cave_why;
}

static const char *finish_cave(Program *p, const char *bytes, size_t size, BYTE *out, size_t room, AssembledCave *result)
{
	const char *why = bytes ? bytes_problem(p, bytes, size) : NULL;

	if (why)
		return why;
	result->code = (size_t)p->code_size;
	result->total = (size_t)(p->code_size + JUMP_BACK_SIZE + p->data_size);
	if (result->total > room)
		return "the cave is larger than its memory";
	memcpy(out, p->image, result->total);
	result->listing = make_listing(p);
	result->lines = make_line_map(p);
	return NULL;
}

static const char *source_error(const Program *p, const char *source)
{
	_snprintf_s(cave_why, sizeof cave_why, _TRUNCATE, "%s:%s", source ? source : "asm", p->error);
	return cave_why;
}

const char *assemble_cave(lua_State *L, int spec, INT_PTR site, INT_PTR address, BYTE *out, size_t room, AssembledCave *result)
{
	int top = lua_gettop(L), values;
	size_t length = 0, size = 0, ignored = 0;
	const char *text = string_field(L, spec, "asm", &length);
	const char *source = string_field(L, spec, "source", &ignored);
	const char *bytes = string_field(L, spec, "bytes", &size);
	const char *why;
	Program *p;

	lua_getfield(L, spec, "values");
	values = lua_istable(L, -1) ? lua_gettop(L) : 0;
	memset(result, 0, sizeof *result);
	if (!text)
		why = "the cave table needs asm text";
	else if (!lua_isnil(L, -1) && !values)
		why = "values must be a table";
	else {
		p = new_program(L, text, length, address, site, FALSE);
		why = run_program(L, p, values) ? finish_cave(p, bytes, size, out, room, result) : source_error(p, source);
	}
	lua_settop(L, top);
	return why;
}

const luaL_Reg asm_functions[] = {
	{ "assemble", l_assemble },
	{ "disassemble", l_disassemble },
	{ "slot_fits", l_slot_fits },
	{ NULL, NULL }
};
