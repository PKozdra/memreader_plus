#include <string.h>

#include <intrin.h>
#include "batch.h"
#include "hook.h"

enum { MAX_RELOCATE_SITES = 1024, MAX_PRIORITY = 1000, MAX_FIELD_NUMBER = 16777215, FIELD_BYTE = 1, FIELD_WORD = 4, WHEN_INDEX = 7 };

enum { METATABLE_KEY, HANDLES_KEY, KEY_COUNT };

_Static_assert(OWNER_SIZE == 64 && ITEM_NAME_SIZE == 48, "the argument messages say 1 to 63 and 1 to 47");

typedef struct {
	int owner;
} Patcher;

typedef struct {
	INT_PTR at;
	size_t size;
	const char *expected;
	const char *bytes;
} CodeChange;

static char keys[KEY_COUNT];

const char different_change[] = "the name is already used for a different change";
static const char hooked_bytes[] = "refused: the first bytes of a hooked function run from the hook's copy, so a change there would never run";
const char hooked_call[] = "not from inside a hooked call";
static const char changed_bytes[] = "the bytes were changed by something else";
static const char full_message[] = "full";
static const char stays_message[] = "stays for the session";
static char target_why[96];

static int refuse(lua_State *L, const char *why)
{
	lua_pushnil(L);
	lua_pushstring(L, why);
	return 2;
}

static int refuse_held(lua_State *L, const char *holder)
{
	lua_pushnil(L);
	lua_pushfstring(L, "held by %s", holder);
	return 2;
}

static int refuse_site(lua_State *L, int number, const char *why)
{
	lua_pushnil(L);
	lua_pushfstring(L, "site %d: %s", number, why);
	return 2;
}

static int refuse_bytes(lua_State *L, const BYTE *current, size_t size)
{
	lua_pushnil(L);
	lua_pushliteral(L, "unexpected bytes");
	lua_pushlstring(L, (const char *)current, size);
	return 3;
}

static int succeed(lua_State *L)
{
	lua_pushboolean(L, 1);
	return 1;
}

static int plan_write(lua_State *L, Batch *batch, int kind, int item, const char *name, INT_PTR at, size_t size, const BYTE *old, const BYTE *wanted, BOOL write)
{
	const char *why;

	batch_begin(batch, kind, item, name);
	why = batch_write(batch, at, size, old, wanted, write);
	return why ? refuse(L, why) : succeed(L);
}

static BOOL valid_name(const char *text, size_t length, size_t limit)
{
	size_t i;

	if (length == 0 || length > limit)
		return FALSE;
	for (i = 0; i < length; i++) {
		char c = text[i];

		if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && c != '_')
			return FALSE;
	}
	return TRUE;
}

static BOOL is_whole(lua_Number number, INT64 low, INT64 high)
{
	return number >= (lua_Number)low && number <= (lua_Number)high && number == (lua_Number)(INT64)number;
}

static const char *target_expect(lua_State *L, int index, INT_PTR at)
{
	const char *expect;
	int matches;

	lua_getfield(L, index, "expect");
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		return NULL;
	}
	expect = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "";
	lua_pop(L, 1);
	matches = *expect ? original_matches(at, expect) : -1;
	if (matches < 0)
		return "expect must be hex bytes and ?? separated by spaces";
	return matches ? NULL : "unexpected bytes";
}

static const char *target_at(lua_State *L, int index, INT_PTR *at)
{
	INT_PTR first = 0;
	lua_Number offset = 0;
	int count;

	if (!lua_istable(L, index)) {
		*at = pointer_argument(L, index);
		return NULL;
	}
	lua_getfield(L, index, "pattern");
	if (lua_type(L, -1) != LUA_TSTRING) {
		lua_pop(L, 1);
		return "a target table needs a pattern string";
	}
	count = find_pattern_count(lua_tostring(L, -1), &first);
	lua_pop(L, 1);
	if (count < 0)
		return "bad pattern: hex bytes and ?? separated by spaces, starting with a byte";
	if (count != 1) {
		_snprintf_s(target_why, sizeof target_why, _TRUNCATE, "pattern found %d times", count);
		return target_why;
	}
	lua_getfield(L, index, "at");
	if (!lua_isnil(L, -1))
		offset = lua_type(L, -1) == LUA_TNUMBER ? lua_tonumber(L, -1) : (lua_Number)0.5;
	lua_pop(L, 1);
	if (!is_whole(offset, -MAX_FIELD_NUMBER, MAX_FIELD_NUMBER))
		return "at must be a whole number";
	*at = first + (INT_PTR)offset;
	return target_expect(L, index, *at);
}

static Patcher *check_self(lua_State *L)
{
	Patcher *self = lua_touserdata(L, 1);

	if (self && lua_getmetatable(L, 1)) {
		lua_pushlightuserdata(L, &keys[METATABLE_KEY]);
		lua_rawget(L, LUA_REGISTRYINDEX);
		if (lua_rawequal(L, -1, -2)) {
			lua_pop(L, 2);
			return self;
		}
		lua_pop(L, 2);
	}
	luaL_typerror(L, 1, "patcher");
	return NULL;
}

static int open_method(lua_State *L, Patcher **self, const char **name)
{
	size_t length;

	*self = check_self(L);
	flush_link_log(L);
	*name = luaL_checklstring(L, 2, &length);
	if (valid_name(*name, length, ITEM_NAME_SIZE - 1))
		return 0;
	return refuse(L, "name must be 1 to 47 letters, digits or underscores");
}

static int open_change(lua_State *L, Patcher **self, const char **name)
{
	int refused = open_method(L, self, name);

	if (!refused && batch_running())
		return refuse(L, batch_busy);
	return refused;
}

static const char *check_change(const CodeChange *change, size_t bytes_size)
{
	if (change->size != bytes_size)
		return "must be as long as the expected bytes";
	if (change->size == 0 || change->size > MAX_PATCH_SIZE)
		return "must be 1 to 4096 bytes";
	if (!in_game_image(change->at, change->size))
		return "address is outside the game's exe";
	return NULL;
}

static const char *read_change(lua_State *L, int first, CodeChange *change)
{
	size_t bytes_size;
	const char *why = target_at(L, first, &change->at);

	if (why)
		return why;
	change->expected = luaL_checklstring(L, first + 1, &change->size);
	change->bytes = luaL_checklstring(L, first + 2, &bytes_size);
	return check_change(change, bytes_size);
}

static BOOL write_code(INT_PTR at, const char *bytes, size_t size)
{
	remember_original(at, size);
	return patch_memory(at, bytes, size);
}

static BOOL refuse_hooked_code(lua_State *L, const char *what, INT_PTR at, size_t size)
{
	if (!in_hooked_prologue(at, size))
		return FALSE;
	note_refusal(L, what, at);
	return TRUE;
}

static BOOL same_change(const Item *item, const Claim *claim, const CodeChange *change, int kind)
{
	return item->kind == kind && claim->from == change->at && (size_t)claim->size == change->size &&
		memcmp(held_bytes(claim), change->expected, change->size) == 0 && memcmp(wrote_bytes(claim), change->bytes, change->size) == 0;
}

static int new_patch(lua_State *L, int owner, const char *name, const CodeChange *change, const BYTE *current, Batch *batch)
{
	char holder[TAG_SIZE], tag[TAG_SIZE];
	int item;

	if (memcmp(current, change->expected, change->size) != 0)
		return refuse_bytes(L, current, change->size);
	if (refuse_hooked_code(L, "patch", change->at, change->size))
		return refuse(L, hooked_bytes);
	if (claim_holder(change->at, change->size, -1, holder, sizeof holder))
		return refuse_held(L, holder);
	if (!registry_room(1, 2 * change->size))
		return refuse(L, full_message);
	if (batch)
		return plan_write(L, batch, ITEM_PATCH, -1, name, change->at, change->size, current, (const BYTE *)change->bytes, TRUE);
	if (!write_code(change->at, change->bytes, change->size))
		return refuse(L, "failed to patch memory");
	item = add_item(owner, name, ITEM_PATCH, change->at);
	add_claim(item, change->at, change->size, current, (const BYTE *)change->bytes);
	make_tag(tag, sizeof tag, owner, name);
	note_owned_change(L, "patch", change->at, change->size, tag);
	return succeed(L);
}

static int repeat_patch(lua_State *L, int item, const CodeChange *change, const BYTE *current, Batch *batch)
{
	int first = first_claim(item);
	const Claim *claim;
	char tag[TAG_SIZE];

	if (first < 0)
		return refuse(L, different_change);
	claim = claim_at(first);
	if (!same_change(item_at(item), claim, change, ITEM_PATCH))
		return refuse(L, different_change);
	if (in_hooked_prologue(change->at, change->size) || memcmp(current, wrote_bytes(claim), change->size) == 0)
		return succeed(L);
	if (memcmp(current, held_bytes(claim), change->size) != 0)
		return refuse_bytes(L, current, change->size);
	if (batch)
		return plan_write(L, batch, ITEM_PATCH, item, item_at(item)->name, change->at, change->size, current, (const BYTE *)change->bytes, TRUE);
	if (!write_code(change->at, change->bytes, change->size))
		return refuse(L, "failed to patch memory");
	make_tag(tag, sizeof tag, item_at(item)->owner, item_at(item)->name);
	note_owned_change(L, "patch", change->at, change->size, tag);
	return succeed(L);
}

static int patch_step(lua_State *L, int owner, const char *name, int first, Batch *batch)
{
	BYTE current[MAX_PATCH_SIZE];
	CodeChange change;
	const char *why = read_change(L, first, &change);
	int item;

	if (why)
		return refuse(L, why);
	if (!copy_memory(current, change.at, change.size))
		return refuse(L, "the bytes cannot be read");
	item = find_item(owner, name);
	if (item >= 0)
		return repeat_patch(L, item, &change, current, batch);
	return new_patch(L, owner, name, &change, current, batch);
}

static int l_patch(lua_State *L)
{
	Patcher *self;
	const char *name;
	int refused = open_change(L, &self, &name);

	return refused ? refused : patch_step(L, self->owner, name, 3, NULL);
}

static INT64 field_number(const BYTE *bytes, int size)
{
	if (size == FIELD_BYTE)
		return bytes[0];
	return (INT32)((UINT32)bytes[0] | (UINT32)bytes[1] << 8 | (UINT32)bytes[2] << 16 | (UINT32)bytes[3] << 24);
}

static void field_bytes(INT64 number, int size, BYTE *out)
{
	UINT32 raw = (UINT32)(INT32)number;
	int i;

	for (i = 0; i < size; i++)
		out[i] = (BYTE)(raw >> (8 * i));
}

static const char *check_field(lua_Number size, lua_Number number, lua_Number low, lua_Number high)
{
	INT64 least = size == FIELD_BYTE ? 0 : -MAX_FIELD_NUMBER, most = size == FIELD_BYTE ? 255 : MAX_FIELD_NUMBER;

	if (size != FIELD_BYTE && size != FIELD_WORD)
		return "size must be 1 or 4";
	if (!is_whole(number, least, most) || !is_whole(low, least, most) || !is_whole(high, least, most))
		return "number, low and high must be whole numbers from 0 to 255 for size 1 and +-16777215 for size 4";
	if (low > high || number < low || number > high)
		return "number must lie between low and high";
	return NULL;
}

static int new_field(lua_State *L, int owner, const char *name, INT_PTR at, int size, const BYTE *wanted, const BYTE *current, lua_Number low, lua_Number high, Batch *batch)
{
	char holder[TAG_SIZE], tag[TAG_SIZE];
	INT64 now = field_number(current, size);
	int item;

	if (now < low || now > high)
		return refuse(L, "the current value is outside low and high");
	if (refuse_hooked_code(L, "set", at, (size_t)size))
		return refuse(L, hooked_bytes);
	if (claim_holder(at, (size_t)size, -1, holder, sizeof holder))
		return refuse_held(L, holder);
	if (!registry_room(1, 2 * (size_t)size))
		return refuse(L, full_message);
	if (batch)
		return plan_write(L, batch, ITEM_VALUE, -1, name, at, (size_t)size, current, wanted, TRUE);
	if (!write_code(at, (const char *)wanted, (size_t)size))
		return refuse(L, "failed to patch memory");
	item = add_item(owner, name, ITEM_VALUE, at);
	add_claim(item, at, (size_t)size, current, wanted);
	make_tag(tag, sizeof tag, owner, name);
	note_owned_change(L, "set", at, (size_t)size, tag);
	return succeed(L);
}

static int repeat_field(lua_State *L, int item, INT_PTR at, int size, const BYTE *wanted, const BYTE *current, Batch *batch)
{
	int first = first_claim(item);
	const Claim *claim;
	char tag[TAG_SIZE];

	if (first < 0)
		return refuse(L, different_change);
	claim = claim_at(first);
	if (item_at(item)->kind != ITEM_VALUE || claim->from != at || claim->size != size)
		return refuse(L, different_change);
	if (in_hooked_prologue(at, (size_t)size))
		return memcmp(wanted, wrote_bytes(claim), (size_t)size) == 0 ? succeed(L) : refuse(L, hooked_bytes);
	if (memcmp(current, wrote_bytes(claim), (size_t)size) != 0 && memcmp(current, held_bytes(claim), (size_t)size) != 0)
		return refuse(L, changed_bytes);
	if (batch)
		return plan_write(L, batch, ITEM_VALUE, item, item_at(item)->name, at, (size_t)size, current, wanted, memcmp(current, wanted, (size_t)size) != 0);
	if (memcmp(current, wanted, (size_t)size) != 0) {
		if (!write_code(at, (const char *)wanted, (size_t)size))
			return refuse(L, "failed to patch memory");
		make_tag(tag, sizeof tag, item_at(item)->owner, item_at(item)->name);
		note_owned_change(L, "set", at, (size_t)size, tag);
	}
	memcpy(wrote_bytes(claim), wanted, (size_t)size);
	return succeed(L);
}

static int set_step(lua_State *L, int owner, const char *name, int first, Batch *batch)
{
	BYTE wanted[FIELD_WORD], current[FIELD_WORD];
	const char *why;
	INT_PTR at;
	lua_Number size = luaL_checknumber(L, first + 1);
	lua_Number number = luaL_checknumber(L, first + 2);
	lua_Number low = luaL_checknumber(L, first + 3);
	lua_Number high = luaL_checknumber(L, first + 4);
	int item;

	why = check_field(size, number, low, high);
	if (why)
		return refuse(L, why);
	why = target_at(L, first, &at);
	if (why)
		return refuse(L, why);
	if (!in_game_image(at, (size_t)size))
		return refuse(L, "address is outside the game's exe");
	if (!copy_memory(current, at, (size_t)size))
		return refuse(L, "the bytes cannot be read");
	field_bytes((INT64)number, (int)size, wanted);
	item = find_item(owner, name);
	if (item >= 0)
		return repeat_field(L, item, at, (int)size, wanted, current, batch);
	return new_field(L, owner, name, at, (int)size, wanted, current, low, high, batch);
}

static int l_set(lua_State *L)
{
	Patcher *self;
	const char *name;
	int refused = open_change(L, &self, &name);

	return refused ? refused : set_step(L, self->owner, name, 3, NULL);
}

static int refuse_with_message(lua_State *L)
{
	lua_pushnil(L);
	lua_insert(L, -2);
	return 2;
}

static int plan_cave(lua_State *L, Batch *batch, const char *name, INT_PTR at, size_t copied, int spec)
{
	const char *why;

	if (!check_cave(L, at))
		return refuse_with_message(L);
	if (spec && prepare_asm_cave(L, at, spec) != CAVE_OK)
		return refuse_with_message(L);
	batch_begin(batch, ITEM_CAVE, -1, name);
	why = batch_span(batch, at, copied);
	return why ? refuse(L, why) : succeed(L);
}

static const char echo_key = 0;

static void echo_line(lua_State *L, const char *text)
{
	lua_pushlightuserdata(L, (void *)&echo_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (lua_istable(L, -1)) {
		lua_pushstring(L, text);
		lua_rawseti(L, -2, (int)lua_objlen(L, -2) + 1);
		lua_pop(L, 1);
		return;
	}
	lua_pop(L, 1);
	log_line(L, text);
}

void hold_echoes(lua_State *L)
{
	lua_pushlightuserdata(L, (void *)&echo_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	lua_pushlightuserdata(L, (void *)&echo_key);
	lua_newtable(L);
	lua_rawset(L, LUA_REGISTRYINDEX);
}

void send_echoes(lua_State *L, int previous)
{
	int count, i;

	lua_pushlightuserdata(L, (void *)&echo_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	lua_pushlightuserdata(L, (void *)&echo_key);
	lua_pushvalue(L, previous);
	lua_rawset(L, LUA_REGISTRYINDEX);
	count = lua_istable(L, -1) ? (int)lua_objlen(L, -1) : 0;
	for (i = 1; i <= count; i++) {
		lua_rawgeti(L, -1, i);
		echo_line(L, lua_tostring(L, -1));
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
}

static void echo_cave(lua_State *L, int owner, INT_PTR at, int spec)
{
	const char *listing = cave_listing(at);
	BOOL quiet;

	lua_pushliteral(L, "echo");
	lua_rawget(L, spec);
	quiet = lua_isboolean(L, -1) && !lua_toboolean(L, -1);
	lua_pop(L, 1);
	if (quiet || !listing)
		return;
	lua_pushfstring(L, "[%s] %s", owner_name(owner), listing);
	echo_line(L, lua_tostring(L, -1));
	lua_pop(L, 1);
}

static int make_cave(lua_State *L, INT_PTR at, const char *name, const CodeChange *code, int spec, BYTE **start)
{
	if (!spec)
		return try_cave(L, at, code->bytes, code->size, start);
	if (!check_cave(L, at))
		return CAVE_REFUSED;
	return try_asm_cave(L, at, spec, name, start);
}

static int new_cave(lua_State *L, int owner, const char *name, INT_PTR at, const CodeChange *code, int spec, Batch *batch)
{
	char holder[TAG_SIZE];
	size_t copied = (size_t)copied_length(at);
	BYTE *start = NULL;
	int item;

	if (claim_holder(at, copied, -1, holder, sizeof holder))
		return refuse_held(L, holder);
	if (!registry_room(1, 0))
		return refuse(L, full_message);
	if (batch)
		return plan_cave(L, batch, name, at, copied, spec);
	if (make_cave(L, at, name, code, spec, &start) != CAVE_OK)
		return refuse_with_message(L);
	item = add_item(owner, name, ITEM_CAVE, at);
	add_claim(item, at, copied, NULL, NULL);
	if (spec)
		echo_cave(L, owner, at, spec);
	push_value(L, VALUE_POINTER, (INT_PTR)start);
	return 1;
}

static int repeat_cave(lua_State *L, int item, INT_PTR at, const CodeChange *code, int spec)
{
	const BYTE *start = cave_start(at);
	const char *why = NULL;

	if (item_at(item)->kind != ITEM_CAVE || item_at(item)->at != at || !start)
		return refuse(L, different_change);
	if (spec)
		why = compare_asm_cave(L, at, spec);
	else if (memcmp(start, code->bytes, code->size) != 0)
		why = different_change;
	if (why)
		return refuse(L, why);
	push_value(L, VALUE_POINTER, (INT_PTR)start);
	return 1;
}

static int cave_step(lua_State *L, int owner, const char *name, int first, Batch *batch)
{
	CodeChange code = { 0, 0, NULL, NULL };
	int spec = lua_istable(L, first + 1) ? first + 1 : 0;
	const char *why;
	INT_PTR at;
	int item;

	if (!spec)
		code.bytes = luaL_checklstring(L, first + 1, &code.size);
	why = target_at(L, first, &at);
	if (why)
		return refuse(L, why);
	if (!at)
		return refuse(L, "address is NULL");
	if (!spec && code.size == 0)
		return refuse(L, "no cave bytes");
	code.at = at;
	item = find_item(owner, name);
	if (item >= 0)
		return repeat_cave(L, item, at, &code, spec);
	return new_cave(L, owner, name, at, &code, spec, batch);
}

static int l_cave(lua_State *L)
{
	Patcher *self;
	const char *name;
	int refused = open_change(L, &self, &name);

	return refused ? refused : cave_step(L, self->owner, name, 3, NULL);
}

static int plan_frame(lua_State *L, Batch *batch, const char *name, INT_PTR at, int by)
{
	Range sites[MAX_FRAME_SITES];
	const char *why = NULL;
	int count, i;

	if (check_growth(at, by, sites, &count, &why) != FRAME_OK)
		return refuse(L, why);
	batch_begin(batch, ITEM_FRAME, -1, name);
	why = batch_guard(batch, at);
	if (why)
		return refuse(L, why);
	for (i = 0; i < count; i++) {
		why = batch_span(batch, sites[i].at, sites[i].size);
		if (why)
			return refuse(L, why);
	}
	return succeed(L);
}

static int frame_step(lua_State *L, int owner, const char *name, int first, Batch *batch, const void *stack)
{
	const char *why = NULL;
	char holder[TAG_SIZE], tag[TAG_SIZE];
	INT_PTR at, function = 0;
	lua_Number grow = luaL_checknumber(L, first + 1);
	int by, item;

	if (callback_depth > 0)
		return refuse(L, hooked_call);
	why = target_at(L, first, &at);
	if (why)
		return refuse(L, why);
	by = is_whole(grow, 1, MAX_FRAME_GROWTH) ? (int)grow : 0;
	if (check_frame(at, by, &function, &why) != FRAME_OK)
		return refuse(L, why);
	item = find_item(owner, name);
	if (item >= 0)
		return item_at(item)->kind == ITEM_FRAME && item_at(item)->at == function && grown_amount(function) == by ? succeed(L) : refuse(L, different_change);
	if (frame_holder(function, -1, holder, sizeof holder))
		return refuse_held(L, holder);
	if (grown_amount(function)) {
		lua_pushnil(L);
		lua_pushfstring(L, "grown by %d already", grown_amount(function));
		return 2;
	}
	if (!registry_room(0, 0))
		return refuse(L, full_message);
	if (batch)
		return plan_frame(L, batch, name, at, by);
	make_tag(tag, sizeof tag, owner, name);
	item = add_item(owner, name, ITEM_FRAME, function);
	if (grow_frame_by(L, at, by, tag, item, stack, &why) != FRAME_OK) {
		remove_item(item);
		return refuse(L, why);
	}
	return succeed(L);
}

static int l_frame(lua_State *L)
{
	Patcher *self;
	const char *name;
	int refused = open_change(L, &self, &name);

	if (refused)
		return refused;
	return frame_step(L, self->owner, name, 3, NULL, _AddressOfReturnAddress());
}

static const char *read_site(lua_State *L, int sites, int number, CodeChange *site)
{
	size_t bytes_size;
	int top = lua_gettop(L);
	const char *why;

	lua_rawgeti(L, sites, number);
	if (!lua_istable(L, -1)) {
		lua_settop(L, top);
		return "is not a table {address, expected, bytes}";
	}
	lua_rawgeti(L, -1, 1);
	lua_rawgeti(L, -2, 2);
	lua_rawgeti(L, -3, 3);
	if (lua_type(L, -2) != LUA_TSTRING || lua_type(L, -1) != LUA_TSTRING) {
		why = "needs the expected and new bytes as strings";
	} else {
		why = target_at(L, top + 2, &site->at);
		site->expected = lua_tolstring(L, -2, &site->size);
		site->bytes = lua_tolstring(L, -1, &bytes_size);
		if (!why)
			why = check_change(site, bytes_size);
	}
	lua_settop(L, top);
	return why;
}

static int overlapping(const Range *ranges, int count, INT_PTR at, size_t size)
{
	int i;

	for (i = 0; i < count; i++) {
		if (ranges[i].at < at + (INT_PTR)size && at < ranges[i].at + (INT_PTR)ranges[i].size)
			return i + 1;
	}
	return 0;
}

static int refuse_overlap(lua_State *L, int first, int second)
{
	lua_pushnil(L);
	lua_pushfstring(L, "sites %d and %d overlap", first, second);
	return 2;
}

static int claim_for(int item, INT_PTR at, size_t size)
{
	int i;

	for (i = 0; i < claim_total(); i++) {
		if (claim_at(i)->item == item && claim_at(i)->from == at && (size_t)claim_at(i)->size == size)
			return i;
	}
	return -1;
}

static int check_old_site(lua_State *L, int item, int number, const CodeChange *site)
{
	BYTE current[MAX_PATCH_SIZE];
	int at = claim_for(item, site->at, site->size);
	const Claim *claim;

	if (at < 0)
		return refuse(L, different_change);
	claim = claim_at(at);
	if (claim->hold < 0)
		return refuse(L, different_change);
	if (memcmp(held_bytes(claim), site->expected, site->size) != 0 || memcmp(wrote_bytes(claim), site->bytes, site->size) != 0)
		return refuse(L, different_change);
	if (!copy_memory(current, site->at, site->size) || memcmp(current, wrote_bytes(claim), site->size) != 0)
		return refuse_site(L, number, changed_bytes);
	return 0;
}

static int repeat_relocate(lua_State *L, int item, int sites, int count)
{
	Range ranges[MAX_RELOCATE_SITES];
	CodeChange site;
	const char *why;
	int i, refused;

	if (item_at(item)->kind != ITEM_RELOCATE || count_claims(item) != count)
		return refuse(L, different_change);
	for (i = 1; i <= count; i++) {
		why = read_site(L, sites, i, &site);
		if (why)
			return refuse_site(L, i, why);
		if (overlapping(ranges, i - 1, site.at, site.size))
			return refuse_overlap(L, overlapping(ranges, i - 1, site.at, site.size), i);
		refused = check_old_site(L, item, i, &site);
		if (refused)
			return refused;
		ranges[i - 1].at = site.at;
		ranges[i - 1].size = site.size;
	}
	return succeed(L);
}

static int check_new_site(lua_State *L, int number, const CodeChange *site)
{
	BYTE current[MAX_PATCH_SIZE];
	char holder[TAG_SIZE];

	if (!copy_memory(current, site->at, site->size))
		return refuse_site(L, number, "the bytes cannot be read");
	if (memcmp(current, site->expected, site->size) != 0)
		return refuse_site(L, number, "does not hold the expected bytes");
	if (refuse_hooked_code(L, "relocate_field", site->at, site->size))
		return refuse_site(L, number, hooked_bytes);
	if (claim_holder(site->at, site->size, -1, holder, sizeof holder)) {
		lua_pushnil(L);
		lua_pushfstring(L, "site %d: held by %s", number, holder);
		return 2;
	}
	return 0;
}

static int plan_sites(lua_State *L, Batch *batch, const char *name, int sites, int count)
{
	CodeChange site;
	const char *why;
	int i;

	batch_begin(batch, ITEM_RELOCATE, -1, name);
	for (i = 1; i <= count; i++) {
		read_site(L, sites, i, &site);
		why = batch_write(batch, site.at, site.size, (const BYTE *)site.expected, (const BYTE *)site.bytes, TRUE);
		if (!why)
			why = batch_guard(batch, site.at);
		if (why)
			return refuse_site(L, i, why);
	}
	return succeed(L);
}

static int new_relocate(lua_State *L, int owner, const char *name, int sites, int count, Batch *batch)
{
	Range ranges[MAX_RELOCATE_SITES];
	CodeChange site;
	size_t total = 0;
	const char *why;
	int i, refused;

	for (i = 1; i <= count; i++) {
		why = read_site(L, sites, i, &site);
		if (why)
			return refuse_site(L, i, why);
		if (overlapping(ranges, i - 1, site.at, site.size))
			return refuse_overlap(L, overlapping(ranges, i - 1, site.at, site.size), i);
		refused = check_new_site(L, i, &site);
		if (refused)
			return refused;
		ranges[i - 1].at = site.at;
		ranges[i - 1].size = site.size;
		total += site.size;
	}
	if (!registry_room(count, 2 * total))
		return refuse(L, full_message);
	return plan_sites(L, batch, name, sites, count);
}

static int relocate_step(lua_State *L, int owner, const char *name, int first, Batch *batch)
{
	int count, item;

	luaL_checktype(L, first, LUA_TTABLE);
	if (callback_depth > 0)
		return refuse(L, hooked_call);
	count = (int)lua_objlen(L, first);
	if (count == 0)
		return refuse(L, "no sites");
	if (count > MAX_RELOCATE_SITES)
		return refuse(L, "at most 1024 sites");
	item = find_item(owner, name);
	if (item >= 0)
		return repeat_relocate(L, item, first, count);
	return new_relocate(L, owner, name, first, count, batch);
}

static int relocate_as_batch(lua_State *L, const char *name)
{
	size_t length = strlen(name);
	const char *why;
	int results, first;

	lua_settop(L, 3);
	lua_createtable(L, 1, 0);
	lua_createtable(L, 3, 0);
	lua_pushliteral(L, "relocate");
	lua_rawseti(L, -2, 1);
	lua_pushvalue(L, 2);
	lua_rawseti(L, -2, 2);
	lua_pushvalue(L, 3);
	lua_rawseti(L, -2, 3);
	lua_rawseti(L, -2, 1);
	lua_replace(L, 2);
	lua_settop(L, 2);
	results = l_batch(L);
	first = lua_gettop(L) - results + 1;
	if (lua_toboolean(L, first))
		return succeed(L);
	why = lua_tostring(L, first + 1);
	if (strncmp(why, name, length) == 0 && why[length] == ':' && why[length + 1] == ' ')
		why += length + 2;
	return refuse(L, why);
}

static int l_relocate(lua_State *L)
{
	Patcher *self;
	const char *name;
	int refused = open_change(L, &self, &name);

	if (refused)
		return refused;
	luaL_checktype(L, 3, LUA_TTABLE);
	return relocate_as_batch(L, name);
}

int patcher_owner(lua_State *L)
{
	return check_self(L)->owner;
}

int run_step(lua_State *L, Batch *batch, const void *stack, int owner, int kind, const char *name, int first)
{
	switch (kind) {
	case ITEM_PATCH:
		return patch_step(L, owner, name, first, batch);
	case ITEM_VALUE:
		return set_step(L, owner, name, first, batch);
	case ITEM_CAVE:
		return cave_step(L, owner, name, first, batch);
	case ITEM_FRAME:
		return frame_step(L, owner, name, first, batch, stack);
	}
	return relocate_step(L, owner, name, first, batch);
}

static const char *change_name(int kind)
{
	if (kind == ITEM_PATCH)
		return "patch";
	return kind == ITEM_VALUE ? "set" : "relocate_field";
}

void commit_step(lua_State *L, const Batch *batch, int owner, const Step *step)
{
	char tag[TAG_SIZE];
	int item = step->item, i;

	if (item < 0)
		item = add_item(owner, step->name, step->kind, batch->writes[step->first].at);
	make_tag(tag, sizeof tag, owner, step->name);
	for (i = 0; i < step->count; i++) {
		const Write *write = &batch->writes[step->first + i];

		if (step->item < 0)
			add_claim(item, write->at, (size_t)write->size, batch->old + write->offset, batch->wanted + write->offset);
		else if (step->kind == ITEM_VALUE)
			memcpy(wrote_bytes(claim_at(first_claim(item))), batch->wanted + write->offset, (size_t)write->size);
		if (write->write)
			note_owned_change(L, change_name(step->kind), write->at, (size_t)write->size, tag);
	}
}

static void call_hook_function(lua_State *L, lua_CFunction function, INT_PTR at, int callback)
{
	lua_pushcfunction(L, function);
	push_value(L, VALUE_POINTER, at);
	lua_pushvalue(L, callback);
	if (lua_pcall(L, 2, 0, 0))
		lua_pop(L, 1);
}

static int swap_callback(lua_State *L, int item)
{
	Item *entry = item_at(item);

	lua_getfenv(L, 1);
	lua_getfield(L, -1, entry->name);
	if (!lua_rawequal(L, -1, 4)) {
		mark_callback(entry->at, item);
		if (lua_isfunction(L, -1))
			call_hook_function(L, l_unhook, entry->at, lua_gettop(L));
	}
	entry->attached = callback_generation();
	lua_pop(L, 1);
	lua_pushvalue(L, 4);
	lua_setfield(L, -2, entry->name);
	lua_pop(L, 1);
	return succeed(L);
}

static int attach_site(lua_State *L, const char *name, INT_PTR at)
{
	lua_getfenv(L, 1);
	lua_getfield(L, -1, name);
	if (lua_rawequal(L, -1, 4)) {
		lua_pop(L, 2);
		return 0;
	}
	lua_pop(L, 2);
	lua_pushcfunction(L, l_hook_site);
	push_value(L, VALUE_POINTER, at);
	lua_pushvalue(L, 4);
	if (lua_pcall(L, 2, 0, 0)) {
		lua_pushnil(L);
		lua_insert(L, -2);
		return 2;
	}
	return 0;
}

static const char *check_priority(lua_State *L, int index, int *priority)
{
	lua_Number number;

	*priority = 0;
	if (lua_isnoneornil(L, index))
		return NULL;
	number = luaL_checknumber(L, index);
	if (!is_whole(number, -MAX_PRIORITY, MAX_PRIORITY))
		return "priority must be a whole number from -1000 to 1000";
	*priority = (int)number;
	return NULL;
}

static int l_site(lua_State *L)
{
	Patcher *self;
	const char *name, *why;
	char holder[TAG_SIZE];
	INT_PTR at;
	int refused, priority, item;

	refused = open_change(L, &self, &name);
	if (refused)
		return refused;
	luaL_checktype(L, 4, LUA_TFUNCTION);
	why = check_priority(L, 5, &priority);
	if (why)
		return refuse(L, why);
	why = target_at(L, 3, &at);
	if (why)
		return refuse(L, why);
	if (!at)
		return refuse(L, "address is NULL");
	item = find_item(self->owner, name);
	if (item >= 0 && (item_at(item)->kind != ITEM_SITE || item_at(item)->at != at))
		return refuse(L, different_change);
	if (item < 0 && !registry_room(0, 0))
		return refuse(L, full_message);
	if (item < 0 && claim_holder(at, (size_t)copied_length(at), -1, holder, sizeof holder))
		return refuse_held(L, holder);
	refused = attach_site(L, name, at);
	if (refused)
		return refused;
	if (item < 0)
		item = add_item(self->owner, name, ITEM_SITE, at);
	item_at(item)->priority = priority;
	return swap_callback(L, item);
}

static int create_function_hook(lua_State *L, INT_PTR at)
{
	lua_pushcfunction(L, l_function_hook);
	push_value(L, VALUE_POINTER, at);
	if (lua_pcall(L, 1, 0, 0)) {
		lua_pushnil(L);
		lua_insert(L, -2);
		return 2;
	}
	return 0;
}

static BOOL has_only_when_fields(lua_State *L)
{
	const char *key;

	lua_pushnil(L);
	while (lua_next(L, WHEN_INDEX)) {
		key = lua_type(L, -2) == LUA_TSTRING ? lua_tostring(L, -2) : "";
		if (strcmp(key, "arg") != 0 && strcmp(key, "reads") != 0 && strcmp(key, "set") != 0) {
			lua_pop(L, 2);
			return FALSE;
		}
		lua_pop(L, 1);
	}
	return TRUE;
}

static BOOL is_key_type(int type)
{
	return type == VALUE_POINTER || type == VALUE_INT64 || type == VALUE_UINT64;
}

static const char *when_argument(lua_State *L, const Signature *signature, LinkFilter *when)
{
	lua_Number number = 0;

	lua_getfield(L, WHEN_INDEX, "arg");
	if (lua_type(L, -1) == LUA_TNUMBER)
		number = lua_tonumber(L, -1);
	lua_pop(L, 1);
	if (!is_whole(number, 1, signature->count) || !is_key_type(signature->arguments[(int)number - 1]))
		return "when.arg must name a pointer, int64 or uint64 argument";
	when->argument = (int)number - 1;
	return NULL;
}

static const char *when_reads(lua_State *L, LinkFilter *when)
{
	const char *why = NULL;
	lua_Number number;
	int i, count;

	lua_getfield(L, WHEN_INDEX, "reads");
	if (!lua_isnil(L, -1) && !lua_istable(L, -1))
		why = "when.reads must be a list of offsets";
	count = why || lua_isnil(L, -1) ? 0 : (int)lua_objlen(L, -1);
	if (count > MAX_WHEN_READS)
		why = "when.reads takes at most 4 offsets";
	for (i = 1; !why && i <= count; i++) {
		lua_rawgeti(L, -1, i);
		number = lua_type(L, -1) == LUA_TNUMBER ? lua_tonumber(L, -1) : 0.5f;
		lua_pop(L, 1);
		if (!is_whole(number, -MAX_WHEN_OFFSET, MAX_WHEN_OFFSET))
			why = "when.reads must hold whole offsets from -16777215 to 16777215";
		else
			when->reads[i - 1] = (INT32)number;
	}
	lua_pop(L, 1);
	when->read_count = why ? 0 : count;
	return why;
}

static const char *parse_when(lua_State *L, const Signature *signature, LinkFilter *when, int *set_index)
{
	const char *why;

	memset(when, 0, sizeof *when);
	if (!has_only_when_fields(L))
		return "when has an unknown field";
	why = when_argument(L, signature, when);
	if (!why)
		why = when_reads(L, when);
	if (why)
		return why;
	lua_getfield(L, WHEN_INDEX, "set");
	when->set = to_set(L, -1);
	if (!when->set) {
		lua_pop(L, 1);
		return "when.set must be a pointer set";
	}
	*set_index = lua_gettop(L);
	return NULL;
}

static int add_link(lua_State *L, int kind)
{
	Patcher *self = check_self(L);
	Signature signature;
	LinkFilter when;
	const LinkFilter *filter = NULL;
	const char *name, *why;
	char holder[TAG_SIZE];
	INT_PTR at;
	size_t length;
	int refused, priority, item, set_index = 0;
	BOOL created;

	parse_signature(L, luaL_checkstring(L, 3), &signature);
	name = luaL_checklstring(L, 4, &length);
	luaL_checktype(L, 5, LUA_TFUNCTION);
	why = check_priority(L, 6, &priority);
	if (why)
		return refuse(L, why);
	if (!lua_isnoneornil(L, WHEN_INDEX)) {
		luaL_checktype(L, WHEN_INDEX, LUA_TTABLE);
		why = parse_when(L, &signature, &when, &set_index);
		if (why)
			return refuse(L, why);
		filter = &when;
	}
	if (batch_running())
		return refuse(L, batch_busy);
	flush_link_log(L);
	if (!valid_name(name, length, ITEM_NAME_SIZE - 1))
		return refuse(L, "name must be 1 to 47 letters, digits or underscores");
	why = target_at(L, 2, &at);
	if (why)
		return refuse(L, why);
	if (!at)
		return refuse(L, "address is NULL");
	item = find_item(self->owner, name);
	if (item >= 0 && (item_at(item)->kind != kind || item_at(item)->at != at))
		return refuse(L, different_change);
	if (item >= 0 && link_is_current(L, &signature, item, priority, 5, filter))
		return succeed(L);
	if (item < 0 && !registry_room(0, 0))
		return refuse(L, full_message);
	if (item < 0 && claim_holder(at, (size_t)copied_length(at), -1, holder, sizeof holder))
		return refuse_held(L, holder);
	refused = create_function_hook(L, at);
	if (refused)
		return refused;
	created = item < 0;
	if (created)
		item = add_item(self->owner, name, kind, at);
	why = attach_link(L, at, &signature, kind, priority, item, 5, filter, set_index);
	if (why && created)
		remove_item(item);
	return why ? refuse(L, why) : succeed(L);
}

static int l_prefix(lua_State *L)
{
	return add_link(L, ITEM_PREFIX);
}

static int l_postfix(lua_State *L)
{
	return add_link(L, ITEM_POSTFIX);
}

static int l_around(lua_State *L)
{
	return add_link(L, ITEM_AROUND);
}

static const char *restore_value(int item)
{
	BYTE current[MAX_PATCH_SIZE];
	const Claim *claim = claim_at(first_claim(item));
	size_t size = (size_t)claim->size;

	if (in_hooked_prologue(claim->from, size))
		return hooked_bytes;
	if (!copy_memory(current, claim->from, size))
		return changed_bytes;
	if (memcmp(current, held_bytes(claim), size) == 0)
		return NULL;
	if (memcmp(current, wrote_bytes(claim), size) != 0)
		return changed_bytes;
	return patch_memory(claim->from, (const char *)held_bytes(claim), size) ? NULL : "failed to patch memory";
}

static void detach_site(lua_State *L, const Item *item)
{
	lua_getfenv(L, 1);
	lua_getfield(L, -1, item->name);
	if (lua_isfunction(L, -1))
		call_hook_function(L, l_unhook, item->at, lua_gettop(L));
	lua_pop(L, 1);
	lua_pushnil(L);
	lua_setfield(L, -2, item->name);
	lua_pop(L, 1);
}

static const char *undo_item(lua_State *L, int item)
{
	const Item *entry = item_at(item);
	const char *why = NULL;

	if (entry->kind == ITEM_PATCH || entry->kind == ITEM_VALUE)
		why = restore_value(item);
	else if (entry->kind == ITEM_ROW)
		why = row_handler_get() ? row_handler_get()->undo(L, item) : changed_bytes;
	else if (entry->kind == ITEM_SITE)
		detach_site(L, entry);
	else if (entry->kind >= ITEM_PREFIX)
		remove_link(item);
	else
		return stays_message;
	if (!why)
		remove_item(item);
	return why;
}

static int l_remove(lua_State *L)
{
	Patcher *self;
	const char *name, *why;
	int refused, item;

	refused = open_change(L, &self, &name);
	if (refused)
		return refused;
	item = find_item(self->owner, name);
	if (item < 0)
		return refuse(L, "unknown name");
	why = undo_item(L, item);
	return why ? refuse(L, why) : succeed(L);
}

static int remove_owner_rows(lua_State *L, int owner)
{
	int item, removed = 0, progress = 1;

	while (progress) {
		progress = 0;
		for (item = item_total() - 1; item >= 0; item--) {
			if (!item_at(item)->used || item_at(item)->owner != owner || item_at(item)->kind != ITEM_ROW)
				continue;
			if (!undo_item(L, item)) {
				removed++;
				progress = 1;
			}
		}
	}
	return removed;
}

static int l_remove_all(lua_State *L)
{
	Patcher *self = check_self(L);
	int item, removed, stayed = 0, failed = 0;

	if (batch_running())
		return refuse(L, batch_busy);
	removed = remove_owner_rows(L, self->owner);
	for (item = 0; item < item_total(); item++) {
		const char *why;

		if (!item_at(item)->used || item_at(item)->owner != self->owner)
			continue;
		why = undo_item(L, item);
		if (!why)
			removed++;
		else if (why == stays_message)
			stayed++;
		else
			failed++;
	}
	if (failed) {
		lua_pushnil(L);
		lua_pushfstring(L, "%d changes could not be put back", failed);
	} else {
		lua_pushboolean(L, 1);
	}
	lua_pushinteger(L, removed);
	lua_pushinteger(L, stayed);
	return failed ? 4 : 3;
}

static void push_row(lua_State *L, int item)
{
	const Item *entry = item_at(item);

	lua_createtable(L, 0, 10);
	lua_pushstring(L, owner_name(entry->owner));
	lua_setfield(L, -2, "owner");
	lua_pushstring(L, entry->name);
	lua_setfield(L, -2, "name");
	lua_pushstring(L, item_kind_name(shown_kind(entry)));
	lua_setfield(L, -2, "kind");
	push_value(L, VALUE_POINTER, entry->at);
	lua_setfield(L, -2, "at");
	lua_pushstring(L, item_state(item));
	lua_setfield(L, -2, "state");
	if (entry->kind == ITEM_ROW && row_handler_get())
		row_handler_get()->describe(L, item);
	if (entry->kind < ITEM_PREFIX)
		return;
	lua_pushnumber(L, (lua_Number)entry->priority);
	lua_setfield(L, -2, "priority");
	lua_pushnumber(L, (lua_Number)entry->calls);
	lua_setfield(L, -2, "calls");
	lua_pushnumber(L, (lua_Number)entry->skips);
	lua_setfield(L, -2, "skips");
	lua_pushnumber(L, (lua_Number)entry->errors);
	lua_setfield(L, -2, "errors");
	if (entry->errors) {
		lua_pushstring(L, entry->error);
		lua_setfield(L, -2, "error");
	}
	push_filter_fields(L, item);
}

static int l_row(lua_State *L)
{
	Patcher *self;
	const char *name;
	int refused = open_change(L, &self, &name);

	if (refused)
		return refused;
	return row_handler_get() ? row_handler_get()->add(L, self->owner, name) : refuse(L, "rows are not available");
}

static int l_owner(lua_State *L)
{
	lua_pushstring(L, owner_name(check_self(L)->owner));
	return 1;
}

static int l_info(lua_State *L)
{
	Patcher *self;
	const char *name;
	int refused, item;

	refused = open_method(L, &self, &name);
	if (refused)
		return refused;
	item = find_item(self->owner, name);
	if (item < 0)
		return refuse(L, "unknown name");
	push_row(L, item);
	return 1;
}

static int l_patch_list(lua_State *L)
{
	const char *owner = luaL_optstring(L, 1, NULL);
	int wanted = owner ? find_owner(owner) : -1;
	int item, count = 0;

	flush_link_log(L);
	lua_createtable(L, 0, 0);
	for (item = 0; item < item_total(); item++) {
		if (!item_at(item)->used || (owner && item_at(item)->owner != wanted))
			continue;
		push_row(L, item);
		lua_rawseti(L, -2, ++count);
	}
	return 1;
}

static const luaL_Reg method_functions[] = {
	{ "patch", l_patch },
	{ "set", l_set },
	{ "cave", l_cave },
	{ "frame", l_frame },
	{ "relocate", l_relocate },
	{ "batch", l_batch },
	{ "site", l_site },
	{ "row", l_row },
	{ "prefix", l_prefix },
	{ "postfix", l_postfix },
	{ "around", l_around },
	{ "remove", l_remove },
	{ "remove_all", l_remove_all },
	{ "info", l_info },
	{ "owner", l_owner },
	{ NULL, NULL }
};

static void push_metatable(lua_State *L)
{
	lua_pushlightuserdata(L, &keys[METATABLE_KEY]);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (!lua_isnil(L, -1))
		return;
	lua_pop(L, 1);
	lua_createtable(L, 0, 1);
	lua_newtable(L);
	luaL_register(L, NULL, method_functions);
	lua_setfield(L, -2, "__index");
	lua_pushlightuserdata(L, &keys[METATABLE_KEY]);
	lua_pushvalue(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
}

static void create_handle(lua_State *L, int owner)
{
	Patcher *self = lua_newuserdata(L, sizeof *self);

	self->owner = owner;
	push_metatable(L);
	lua_setmetatable(L, -2);
	lua_newtable(L);
	lua_setfenv(L, -2);
}

static void push_handle(lua_State *L, int owner)
{
	lua_pushlightuserdata(L, &keys[HANDLES_KEY]);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushlightuserdata(L, &keys[HANDLES_KEY]);
		lua_pushvalue(L, -2);
		lua_rawset(L, LUA_REGISTRYINDEX);
	}
	lua_rawgeti(L, -1, owner + 1);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		create_handle(L, owner);
		lua_pushvalue(L, -1);
		lua_rawseti(L, -3, owner + 1);
	}
	lua_remove(L, -2);
}

static int l_patcher(lua_State *L)
{
	size_t length;
	const char *owner = luaL_checklstring(L, 1, &length);
	int index;

	if (!valid_name(owner, length, OWNER_SIZE - 1))
		return refuse(L, "owner must be 1 to 63 letters, digits or underscores");
	index = add_owner(owner);
	if (index < 0)
		return refuse(L, lua_pushfstring(L, "at most %d owners per game session", MAX_OWNERS));
	push_handle(L, index);
	return 1;
}

const luaL_Reg patcher_functions[] = {
	{ "patcher", l_patcher },
	{ "patch_list", l_patch_list },
	{ "patch_info", l_patch_info },
	{ "set_log", l_set_log },
	{ "flush_log", l_flush_log },
	{ NULL, NULL }
};
