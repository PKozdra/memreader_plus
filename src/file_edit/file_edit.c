#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "file_edit.h"

static const char *const edit_keys[] = { "owner", "id", "path", "priority", "once", "ops", NULL };
static const char *const op_keys[] = { "after", "before", "find", "with", "count", "insert", "attribute", "value", "child", NULL };

static Patch *reading;

static BOOL is_listed(const char *key, const char *const *allowed)
{
	for (; *allowed; allowed++) {
		if (strcmp(key, *allowed) == 0)
			return TRUE;
	}
	return FALSE;
}

static void check_keys(lua_State *L, int table, const char *const *allowed, const char *what)
{
	lua_pushnil(L);
	while (lua_next(L, table)) {
		lua_pop(L, 1);
		if (lua_type(L, -1) != LUA_TSTRING)
			luaL_error(L, "file_edit: %s has a %s key, only names are allowed", what, luaL_typename(L, -1));
		if (!is_listed(lua_tostring(L, -1), allowed))
			luaL_error(L, "file_edit: unknown key '%s' in %s", lua_tostring(L, -1), what);
	}
}

static int list_size(lua_State *L, int list, const char *what)
{
	int count = 0, largest = 0;

	lua_pushnil(L);
	while (lua_next(L, list)) {
		lua_Number key = lua_type(L, -2) == LUA_TNUMBER ? lua_tonumber(L, -2) : 0;

		lua_pop(L, 1);
		if (key < 1 || key > INT_MAX || key != floor(key))
			luaL_error(L, "file_edit: %s must be a list", what);
		count++;
		if (key > largest)
			largest = (int)key;
	}
	if (largest != count)
		luaL_error(L, "file_edit: %s must be a list without gaps", what);
	return count;
}

static char *checked_text(lua_State *L, int index, const char *name, BOOL may_be_empty)
{
	size_t length = 0;
	const char *text = lua_type(L, index) == LUA_TSTRING ? lua_tolstring(L, index, &length) : NULL;
	char *copy;

	if (!text || (length == 0 && !may_be_empty) || strlen(text) != length)
		luaL_error(L, "file_edit: %s must be a string%s without a zero byte", name, may_be_empty ? "" : " of 1 byte or more");
	copy = _strdup(text);
	if (!copy)
		luaL_error(L, "out of memory");
	return copy;
}

static char *text_field(lua_State *L, int table, const char *name, BOOL may_be_empty)
{
	char *text = NULL;

	lua_getfield(L, table, name);
	if (!lua_isnil(L, -1))
		text = checked_text(L, -1, name, may_be_empty);
	lua_pop(L, 1);
	return text;
}

static void read_anchor_list(lua_State *L, Op *op)
{
	int count = list_size(L, lua_gettop(L), "after"), i;

	if (count > MAX_ANCHORS)
		luaL_error(L, "file_edit: after takes at most %d texts", MAX_ANCHORS);
	for (i = 1; i <= count; i++) {
		lua_rawgeti(L, -1, i);
		op->after[op->after_count++] = checked_text(L, -1, "each text in after", FALSE);
		lua_pop(L, 1);
	}
}

static void read_anchors(lua_State *L, int table, Op *op)
{
	lua_getfield(L, table, "after");
	if (lua_type(L, -1) == LUA_TSTRING)
		op->after[op->after_count++] = checked_text(L, -1, "after", FALSE);
	else if (lua_istable(L, -1))
		read_anchor_list(L, op);
	else if (!lua_isnil(L, -1))
		luaL_error(L, "file_edit: after must be a string or a list of strings");
	lua_pop(L, 1);
}

static lua_Number number_field(lua_State *L, int table, const char *name, lua_Number fallback)
{
	lua_Number value = fallback;

	lua_getfield(L, table, name);
	if (lua_type(L, -1) == LUA_TNUMBER)
		value = lua_tonumber(L, -1);
	else if (!lua_isnil(L, -1))
		luaL_error(L, "file_edit: %s must be a number", name);
	lua_pop(L, 1);
	return value;
}

static BOOL has_control_character(const char *text)
{
	for (; *text; text++) {
		if ((unsigned char)*text < 0x20 && *text != '\t' && *text != '\n' && *text != '\r')
			return TRUE;
	}
	return FALSE;
}

static const char *op_problem(const Op *op, BOOL has_count)
{
	int kinds = (op->find != NULL) + (op->attribute != NULL) + (op->child != NULL) + (op->insert && !op->child);

	if (kinds != 1)
		return "each op needs one of find, insert, attribute or child";
	if (op->find && !op->with)
		return "an op with find needs with ('' removes the text)";
	if (!op->find && (op->with || op->before || has_count))
		return "with, before and count go only with find";
	if (op->attribute && !op->value)
		return "an op with attribute needs value";
	if (op->value && !op->attribute)
		return "value goes only with attribute";
	if (op->value && has_control_character(op->value))
		return "value holds a control character other than tab or a line break";
	if (op->child && !op->insert)
		return "an op with child needs insert";
	if ((op->attribute || op->child) && op->after_count == 0)
		return "an op with attribute or child needs after";
	if ((op->attribute && !is_xml_name(op->attribute)) || (op->child && !is_xml_name(op->child)))
		return "attribute and child must be XML names";
	return NULL;
}

static void read_op(lua_State *L, int table, Op *op)
{
	lua_Number count = number_field(L, table, "count", 1);
	const char *problem;

	check_keys(L, table, op_keys, "an op");
	if (count < 1 || count > MAX_COUNT || count != floor(count))
		luaL_error(L, "file_edit: count must be a whole number from 1 to %d", MAX_COUNT);
	op->count = (int)count;
	read_anchors(L, table, op);
	op->before = text_field(L, table, "before", FALSE);
	op->find = text_field(L, table, "find", FALSE);
	op->with = text_field(L, table, "with", TRUE);
	op->insert = text_field(L, table, "insert", FALSE);
	op->attribute = text_field(L, table, "attribute", FALSE);
	op->value = text_field(L, table, "value", TRUE);
	op->child = text_field(L, table, "child", FALSE);
	lua_getfield(L, table, "count");
	problem = op_problem(op, !lua_isnil(L, -1));
	lua_pop(L, 1);
	if (problem)
		luaL_error(L, "file_edit: %s", problem);
}

static void read_name(lua_State *L, int spec, const char *name, char *out)
{
	lua_getfield(L, spec, name);
	if (lua_type(L, -1) != LUA_TSTRING)
		luaL_error(L, "file_edit: %s must be a string", name);
	if (strlen(lua_tostring(L, -1)) >= NAME_SIZE)
		luaL_error(L, "file_edit: %s must be at most %d bytes", name, NAME_SIZE - 1);
	strcpy_s(out, NAME_SIZE, lua_tostring(L, -1));
	lua_pop(L, 1);
}

static void read_op_list(lua_State *L, int list, Patch *patch)
{
	int count, i;

	if (!lua_istable(L, list))
		luaL_error(L, "file_edit: ops must be a list of ops");
	count = list_size(L, list, "ops");
	if (count == 0)
		luaL_error(L, "file_edit: ops must list at least one op");
	if (count > MAX_OPS)
		luaL_error(L, "file_edit: at most %d ops per edit", MAX_OPS);
	if (!grow_array((void **)&patch->ops, &patch->op_capacity, count, sizeof *patch->ops))
		luaL_error(L, "out of memory");
	for (i = 1; i <= count; i++) {
		lua_rawgeti(L, list, i);
		if (!lua_istable(L, -1))
			luaL_error(L, "file_edit: each op must be a table");
		read_op(L, lua_gettop(L), &patch->ops[patch->op_count++]);
		lua_pop(L, 1);
	}
}

static void read_ops(lua_State *L, int spec, Patch *patch)
{
	lua_getfield(L, spec, "ops");
	read_op_list(L, lua_gettop(L), patch);
	lua_pop(L, 1);
}

static Patch *new_patch(lua_State *L)
{
	Patch *patch = calloc(1, sizeof *patch);

	reading = patch;
	if (!patch)
		luaL_error(L, "out of memory");
	return patch;
}

static Patch *read_patch(lua_State *L, int spec)
{
	Patch *patch = new_patch(L);

	read_name(L, spec, "owner", patch->owner);
	read_name(L, spec, "id", patch->id);
	patch->priority = number_field(L, spec, "priority", 0);
	if (!isfinite(patch->priority))
		luaL_error(L, "file_edit: priority must be a finite number");
	lua_getfield(L, spec, "once");
	if (!lua_isnil(L, -1) && !lua_isboolean(L, -1))
		luaL_error(L, "file_edit: once must be true or false");
	patch->once = lua_toboolean(L, -1);
	lua_pop(L, 1);
	read_ops(L, spec, patch);
	return patch;
}

static void read_path(lua_State *L, int spec, char *path)
{
	size_t length;
	const char *text, *problem;

	lua_getfield(L, spec, "path");
	if (lua_type(L, -1) != LUA_TSTRING)
		luaL_error(L, "file_edit: path must be a string");
	text = lua_tolstring(L, -1, &length);
	problem = pack_path_problem(text, length);
	if (problem)
		luaL_error(L, "file_edit: path %s", problem);
	if (length >= PATH_SIZE)
		luaL_error(L, "file_edit: path must be at most %d bytes", PATH_SIZE - 1);
	normal_path(text, FALSE, path);
}

static int answer(lua_State *L, BOOL ok, const char *note)
{
	if (ok)
		lua_pushboolean(L, 1);
	else
		lua_pushnil(L);
	if (!note)
		return 1;
	lua_pushstring(L, note);
	return 2;
}

static int twin_answer(lua_State *L, const EditedFile *twin)
{
	lua_pushboolean(L, 1);
	lua_pushfstring(L, "same bytes as %s: a reader that gives no path gets the edits of the file registered first", twin->path);
	return 2;
}

static void remove_patch(EditedFile *file, int at)
{
	char path[PATH_SIZE];

	drop_patch(file, at);
	strcpy_s(path, PATH_SIZE, file->path);
	if (file->patch_count)
		publish(file);
	else
		forget_file(file);
	evict_layout(path);
}

static BOOL remove_edit(const char *owner, const char *id, const EditedFile *keep)
{
	BOOL removed = FALSE;
	LONG i;
	int at;

	for (i = 0; i < file_count; i++) {
		EditedFile *file = files[i];

		if (file == keep || !file->base || (at = find_patch(file, owner, id)) < 0)
			continue;
		remove_patch(file, at);
		removed = TRUE;
	}
	return removed;
}

static int register_edit(lua_State *L)
{
	char path[PATH_SIZE];
	const EditedFile *twin = NULL;
	EditedFile *file;
	Patch *patch;
	const char *evicted;
	BOOL added = FALSE;

	if (!lua_istable(L, 1))
		luaL_error(L, "file_edit: takes a table");
	check_keys(L, 1, edit_keys, "the edit");
	read_path(L, 1, path);
	if (!can_edit(path))
		return answer(L, FALSE, "off: fast_xml");
	patch = read_patch(L, 1);
	file = find_file(path);
	if (!file)
		added = (file = add_file(L, 2, path)) != NULL;
	reading = NULL;
	if (!file) {
		free_patch(patch);
		return answer(L, FALSE, "no such file, or a UTF-16 file");
	}
	remove_edit(patch->owner, patch->id, file);
	if (added)
		twin = find_twin(file);
	if (!put_patch(file, patch)) {
		if (!file->patch_count)
			forget_file(file);
		return answer(L, FALSE, "at most 4096 edits per file, or out of memory");
	}
	publish(file);
	evicted = evict_layout(path);
	if (!patch->applied)
		return answer(L, FALSE, patch->problem);
	return twin && !evicted ? twin_answer(L, twin) : answer(L, TRUE, evicted);
}

static int apply_ops(lua_State *L)
{
	size_t size, new_size;
	const char *text = luaL_checklstring(L, 1, &size);
	Patch *patch = new_patch(L);
	char *edited;
	int results = 1;

	read_op_list(L, 2, patch);
	edited = apply_patch(text, size, patch, &new_size);
	if (edited)
		lua_pushlstring(L, edited, new_size);
	else
		results = answer(L, FALSE, patch->problem);
	free(edited);
	reading = NULL;
	free_patch(patch);
	return results;
}

static int run_protected(lua_State *L, lua_CFunction function, int arguments)
{
	lua_settop(L, arguments);
	lua_pushcfunction(L, function);
	lua_insert(L, 1);
	if (lua_pcall(L, arguments, LUA_MULTRET, 0) == 0)
		return lua_gettop(L);
	if (reading)
		free_patch(reading);
	reading = NULL;
	return answer(L, FALSE, lua_tostring(L, -1));
}

static int l_file_edit(lua_State *L)
{
	const char *off = turned_off ? "off: switched off by the player" : start_file_edits();

	if (off)
		return answer(L, FALSE, off);
	sweep();
	return run_protected(L, register_edit, 1);
}

static int l_file_edit_apply(lua_State *L)
{
	return run_protected(L, apply_ops, 2);
}

static int l_file_edit_remove(lua_State *L)
{
	const char *owner = luaL_checkstring(L, 1);
	const char *id = luaL_checkstring(L, 2);

	sweep();
	lua_pushboolean(L, remove_edit(owner, id, NULL));
	return 1;
}

static int l_set_file_edits(lua_State *L)
{
	BOOL enabled = lua_toboolean(L, 1);
	EditedFile *file = NULL;
	char path[PATH_SIZE];
	LONG i;

	sweep();
	if (lua_isnoneornil(L, 2)) {
		turned_off = !enabled;
	} else {
		normal_path(luaL_checkstring(L, 2), FALSE, path);
		file = find_file(path);
		if (!file)
			return answer(L, FALSE, "no edits on this file");
		file->disabled = !enabled;
	}
	for (i = 0; i < file_count; i++) {
		if (files[i]->base && (!file || file == files[i]))
			evict_layout(files[i]->path);
	}
	return answer(L, TRUE, NULL);
}

static void set_number(lua_State *L, const char *name, double value)
{
	lua_pushnumber(L, (lua_Number)value);
	lua_setfield(L, -2, name);
}

static int l_file_edit_status(lua_State *L)
{
	LONG pugi, fast_xml;
	LONG i, count = 0;

	sweep();
	for (i = 0; i < file_count; i++)
		count += files[i]->base != NULL;
	count_hand_offs(&pugi, &fast_xml);
	lua_createtable(L, 0, 9);
	lua_pushstring(L, file_edit_state());
	lua_setfield(L, -2, "state");
	lua_pushboolean(L, !turned_off);
	lua_setfield(L, -2, "enabled");
	set_number(L, "files", count);
	set_number(L, "results", result_count);
	set_number(L, "pugi_calls", pugi);
	set_number(L, "fast_xml_calls", fast_xml);
	push_sites(L);
	lua_setfield(L, -2, "sites");
	push_parts_off(L);
	lua_setfield(L, -2, "off");
	return 1;
}

static void push_patches(lua_State *L, const EditedFile *file)
{
	int i;

	lua_createtable(L, file->patch_count, 0);
	for (i = 0; i < file->patch_count; i++) {
		const Patch *patch = file->patches[i];

		lua_pushfstring(L, "%s/%s %s%s", patch->owner, patch->id, patch->applied ? "applied" : "skipped: ", patch->applied ? "" : patch->problem);
		lua_rawseti(L, -2, i + 1);
	}
	lua_setfield(L, -2, "patches");
}

static void push_file(lua_State *L, EditedFile *file)
{
	Result *result = hold_result(file);

	lua_createtable(L, 0, 10);
	set_number(L, "edited_size", result ? (double)result->size : 0);
	release_result(result);
	lua_pushstring(L, file->path);
	lua_setfield(L, -2, "path");
	lua_pushboolean(L, file->disabled);
	lua_setfield(L, -2, "disabled");
	set_number(L, "size", (double)file->base_size);
	set_number(L, "hits", file->hits);
	set_number(L, "rejected", file->rejected);
	set_number(L, "vetoes", file->vetoes);
	set_number(L, "misses", file->misses);
	push_patches(L, file);
}

static int l_file_edit_list(lua_State *L)
{
	char path[PATH_SIZE] = "";
	LONG i;
	int count = 0;

	sweep();
	if (lua_type(L, 1) == LUA_TSTRING)
		normal_path(lua_tostring(L, 1), FALSE, path);
	lua_newtable(L);
	for (i = 0; i < file_count; i++) {
		if (!files[i]->base || (path[0] && strcmp(path, files[i]->path) != 0))
			continue;
		push_file(L, files[i]);
		lua_rawseti(L, -2, ++count);
	}
	return 1;
}

static int l_file_edit_preview(lua_State *L)
{
	char path[PATH_SIZE];
	EditedFile *file;
	Result *result;

	sweep();
	normal_path(luaL_checkstring(L, 1), FALSE, path);
	file = find_file(path);
	if (!file)
		return 0;
	result = hold_result(file);
	if (result)
		lua_pushlstring(L, (const char *)result->bytes, result->size);
	else
		lua_pushnil(L);
	release_result(result);
	lua_pushlstring(L, (const char *)file->base, file->base_size);
	return 2;
}

const luaL_Reg file_edit_functions[] = {
	{ "file_edit", l_file_edit },
	{ "file_edit_remove", l_file_edit_remove },
	{ "file_edit_status", l_file_edit_status },
	{ "file_edit_list", l_file_edit_list },
	{ "file_edit_preview", l_file_edit_preview },
	{ "file_edit_apply", l_file_edit_apply },
	{ "set_file_edits", l_set_file_edits },
	{ NULL, NULL }
};
