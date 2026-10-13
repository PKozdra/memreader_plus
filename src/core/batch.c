#include <intrin.h>
#include <string.h>

#include "batch.h"
#include "hook.h"

enum { MAX_STEP_FIELDS = 7 };

typedef struct {
	int kind;
	char name[ITEM_NAME_SIZE];
} Entry;

static const struct {
	const char *word;
	int kind;
} kinds[] = {
	{ "patch", ITEM_PATCH }, { "set", ITEM_VALUE }, { "cave", ITEM_CAVE }, { "frame", ITEM_FRAME }, { "relocate", ITEM_RELOCATE }
};

static Batch plan;
static Entry entries[MAX_BATCH_STEPS];
static int stays[MAX_BATCH_STEPS];
static int stay_count;
static Range windows[MAX_BATCH_WRITES + MAX_WHOLE_RANGES];
static const char *window_names[MAX_BATCH_WRITES + MAX_WHOLE_RANGES];
static int leftovers[MAX_BATCH_WRITES];
static int leftover_count;
static UINT64 window_us;
static char reason[TAG_SIZE + 160];

void batch_begin(Batch *batch, int kind, int item, const char *name)
{
	Step *step = &batch->steps[batch->step_count++];

	step->kind = kind;
	step->item = item;
	step->first = batch->write_count;
	step->count = 0;
	strcpy_s(step->name, sizeof step->name, name);
	if (item < 0)
		batch->items++;
}

const char *batch_span(Batch *batch, INT_PTR at, size_t size)
{
	int current = batch->step_count - 1, i;

	if (batch->span_count == MAX_BATCH_SPANS)
		return "the batch touches too many ranges";
	for (i = 0; i < batch->span_count; i++) {
		const Span *other = &batch->spans[i];

		if (other->step != current && other->at < at + (INT_PTR)size && at < other->at + other->size) {
			_snprintf_s(batch->why, sizeof batch->why, _TRUNCATE, "overlaps %s in this batch", batch->steps[other->step].name);
			return batch->why;
		}
	}
	batch->spans[batch->span_count].at = at;
	batch->spans[batch->span_count].size = (int)size;
	batch->spans[batch->span_count++].step = current;
	if (batch->steps[current].item < 0)
		batch->claims++;
	return NULL;
}

const char *batch_guard(Batch *batch, INT_PTR at)
{
	Range parts[MAX_FUNCTION_PARTS];
	const Step *step = &batch->steps[batch->step_count - 1];
	int count, i;

	for (i = 0; i < batch->guard_count && step->kind != ITEM_FRAME; i++) {
		if (at >= batch->guards[i].at && at < batch->guards[i].at + (INT_PTR)batch->guards[i].size)
			return NULL;
	}
	count = function_extents(at, parts, MAX_FUNCTION_PARTS);
	if (batch->guard_count + count > MAX_WHOLE_RANGES)
		return "the batch touches too many functions";
	for (i = 0; i < count; i++) {
		batch->guards[batch->guard_count] = parts[i];
		batch->guard_frames[batch->guard_count] = step->kind == ITEM_FRAME;
		strcpy_s(batch->guard_names[batch->guard_count++], ITEM_NAME_SIZE, step->name);
	}
	return NULL;
}

const char *batch_write(Batch *batch, INT_PTR at, size_t size, const BYTE *old, const BYTE *wanted, BOOL write)
{
	Step *step = &batch->steps[batch->step_count - 1];
	const char *why = batch_span(batch, at, size);
	Write *entry;

	if (why)
		return why;
	if (batch->write_count == MAX_BATCH_WRITES || batch->bytes_used + (int)size > BATCH_BYTES)
		return "the batch writes too many bytes";
	entry = &batch->writes[batch->write_count++];
	entry->at = at;
	entry->size = (int)size;
	entry->step = batch->step_count - 1;
	entry->offset = batch->bytes_used;
	entry->write = write;
	memcpy(batch->old + entry->offset, old, size);
	memcpy(batch->wanted + entry->offset, wanted, size);
	batch->bytes_used += (int)size;
	step->count++;
	if (step->item < 0)
		batch->pool += 2 * size;
	return NULL;
}

static void clear_plan(Batch *batch)
{
	batch->step_count = 0;
	batch->write_count = 0;
	batch->span_count = 0;
	batch->bytes_used = 0;
	batch->items = 0;
	batch->claims = 0;
	batch->pool = 0;
}

static int find_kind(const char *word)
{
	size_t i;

	for (i = 0; i < sizeof kinds / sizeof kinds[0]; i++) {
		if (strcmp(kinds[i].word, word) == 0)
			return kinds[i].kind;
	}
	return -1;
}

static BOOL is_irreversible(int kind)
{
	return kind == ITEM_CAVE || kind == ITEM_FRAME;
}

static BOOL name_is_valid(const char *name, size_t length)
{
	size_t i;

	if (length == 0 || length >= ITEM_NAME_SIZE)
		return FALSE;
	for (i = 0; i < length; i++) {
		char c = name[i];

		if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && c != '_')
			return FALSE;
	}
	return TRUE;
}

static const char *step_text(int number, const char *text)
{
	_snprintf_s(reason, sizeof reason, _TRUNCATE, "step %d: %s", number, text);
	return reason;
}

static const char *check_entry(int number, const char *word, const char *name, size_t length)
{
	Entry *entry = &entries[number - 1];
	int i;

	entry->kind = find_kind(word);
	if (entry->kind < 0)
		return step_text(number, "unknown kind");
	if (!name_is_valid(name, length))
		return step_text(number, "name must be 1 to 47 letters, digits or underscores");
	strcpy_s(entry->name, sizeof entry->name, name);
	for (i = 0; i < number - 1; i++) {
		if (strcmp(entries[i].name, name) == 0)
			return step_text(number, "the name is used twice in this batch");
	}
	return NULL;
}

static const char *read_entry(lua_State *L, int list, int number)
{
	const char *word, *name, *why;
	size_t length = 0;

	lua_rawgeti(L, list, number);
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		return step_text(number, "needs a table {kind, name, ...}");
	}
	if (lua_objlen(L, -1) > MAX_STEP_FIELDS) {
		lua_pop(L, 1);
		return step_text(number, "has too many fields");
	}
	lua_rawgeti(L, -1, 1);
	lua_rawgeti(L, -2, 2);
	word = lua_type(L, -2) == LUA_TSTRING ? lua_tostring(L, -2) : "";
	name = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &length) : "";
	why = check_entry(number, word, name, length);
	lua_pop(L, 3);
	return why;
}

static const char *read_entries(lua_State *L, int list, int count)
{
	const char *why;
	int number;

	if (count == 0)
		return "no steps";
	if (count > MAX_BATCH_STEPS)
		return "at most 128 steps";
	for (number = 1; number <= count; number++) {
		why = read_entry(L, list, number);
		if (why)
			return why;
	}
	return NULL;
}

static const char *run_entry(lua_State *L, Batch *batch, const void *stack, int owner, int list, int number)
{
	const Entry *entry = &entries[number - 1];
	int base = lua_gettop(L), count, i, results, answer;
	BOOL refused;

	lua_rawgeti(L, list, number);
	count = (int)lua_objlen(L, base + 1);
	for (i = 3; i <= count; i++)
		lua_rawgeti(L, base + 1, i);
	results = run_step(L, batch, stack, owner, entry->kind, entry->name, base + 2);
	answer = lua_gettop(L) - results + 1;
	refused = lua_isnil(L, answer);
	if (refused)
		_snprintf_s(reason, sizeof reason, _TRUNCATE, "%s: %s", entry->name, lua_tostring(L, answer + 1));
	lua_settop(L, base);
	return refused ? reason : NULL;
}

static const char *check_caves(const Batch *batch)
{
	int i, g;

	for (i = 0; i < batch->span_count; i++) {
		const Span *span = &batch->spans[i];

		if (batch->steps[span->step].kind != ITEM_CAVE)
			continue;
		for (g = 0; g < batch->guard_count; g++) {
			if (batch->guard_frames[g] && span->at >= batch->guards[g].at && span->at < batch->guards[g].at + (INT_PTR)batch->guards[g].size) {
				_snprintf_s(reason, sizeof reason, _TRUNCATE, "%s: inside the function of %s in this batch", batch->steps[span->step].name, batch->guard_names[g]);
				return reason;
			}
		}
	}
	return NULL;
}

static const char *plan_steps(lua_State *L, int owner, int list, int count, BOOL bytes_only)
{
	const char *why;
	int number;

	clear_plan(&plan);
	for (number = 1; number <= count; number++) {
		if (bytes_only && is_irreversible(entries[number - 1].kind))
			continue;
		why = run_entry(L, &plan, NULL, owner, list, number);
		if (why)
			return why;
	}
	if (!item_room(plan.items) || !claim_room(plan.claims, plan.pool))
		return "full";
	return bytes_only ? NULL : check_caves(&plan);
}

static const char *make_irreversible(lua_State *L, const void *stack, int owner, int list, int count)
{
	const char *why;
	int number;

	stay_count = 0;
	for (number = 1; number <= count; number++) {
		const Entry *entry = &entries[number - 1];
		BOOL made;

		if (!is_irreversible(entry->kind))
			continue;
		made = find_item(owner, entry->name) < 0;
		why = run_entry(L, NULL, stack, owner, list, number);
		if (why)
			return why;
		if (made)
			stays[stay_count++] = number - 1;
	}
	return NULL;
}

static int collect_windows(const Batch *batch)
{
	int i, count = 0;

	for (i = 0; i < batch->write_count; i++) {
		if (!batch->writes[i].write)
			continue;
		windows[count].at = batch->writes[i].at;
		windows[count].size = (size_t)batch->writes[i].size;
		windows[count].whole = FALSE;
		window_names[count++] = batch->steps[batch->writes[i].step].name;
	}
	if (count == 0)
		return 0;
	for (i = 0; i < batch->guard_count; i++) {
		windows[count] = batch->guards[i];
		window_names[count++] = batch->guard_names[i];
	}
	return count;
}

static BOOL matches_old(const Batch *batch, const Write *write)
{
	BYTE current[MAX_PATCH_SIZE];

	return copy_memory(current, write->at, (size_t)write->size) && memcmp(current, batch->old + write->offset, (size_t)write->size) == 0;
}

static int first_changed(const Batch *batch)
{
	int i;

	for (i = 0; i < batch->write_count; i++) {
		if (batch->writes[i].write && !matches_old(batch, &batch->writes[i]))
			return i;
	}
	return -1;
}

static void put_back(const Batch *batch, int count)
{
	int i;

	for (i = count - 1; i >= 0; i--) {
		const Write *write = &batch->writes[i];

		if (!write->write || matches_old(batch, write))
			continue;
		patch_memory(write->at, (const char *)batch->old + write->offset, (size_t)write->size);
		if (!matches_old(batch, write))
			leftovers[leftover_count++] = i;
	}
}

static int write_all(const Batch *batch)
{
	int i;

	for (i = 0; i < batch->write_count; i++) {
		const Write *write = &batch->writes[i];

		if (write->write && !patch_memory(write->at, (const char *)batch->wanted + write->offset, (size_t)write->size)) {
			put_back(batch, i + 1);
			return i;
		}
	}
	return -1;
}

static void register_leftovers(const Batch *batch, int owner)
{
	int i;

	for (i = 0; i < leftover_count; i++) {
		const Write *write = &batch->writes[leftovers[i]];
		const Step *step = &batch->steps[write->step];
		int item;

		if (step->item >= 0)
			continue;
		item = find_item(owner, step->name);
		if (item < 0) {
			item = add_item(owner, step->name, ITEM_RELOCATE, write->at);
			if (item >= 0)
				item_at(item)->listed = (BYTE)(step->kind + 1);
		}
		if (item >= 0)
			add_claim(item, write->at, (size_t)write->size, NULL, NULL);
	}
}

static const char *write_failed(const Batch *batch, int index)
{
	const char *name = batch->steps[batch->writes[index].step].name;

	if (leftover_count)
		_snprintf_s(reason, sizeof reason, _TRUNCATE, "%s: failed to patch memory, and %d write%s could not be put back", name, leftover_count, leftover_count == 1 ? "" : "s");
	else
		_snprintf_s(reason, sizeof reason, _TRUNCATE, "%s: failed to patch memory, nothing of the batch was written", name);
	return reason;
}

static const char *write_window(const Batch *batch, const void *stack, int owner)
{
	FreezeJob job = { windows, 0, NULL, NULL, stack };
	int busy = -1, changed, failed = -1, result, i;

	window_us = 0;
	leftover_count = 0;
	job.count = collect_windows(batch);
	if (job.count == 0)
		return NULL;
	for (i = 0; i < batch->write_count; i++) {
		if (batch->writes[i].write)
			remember_original(batch->writes[i].at, (size_t)batch->writes[i].size);
	}
	result = freeze_threads(&job, &busy);
	if (result == FREEZE_BUSY) {
		_snprintf_s(reason, sizeof reason, _TRUNCATE, "a thread is inside %s/%s", owner_name(owner), window_names[busy]);
		return reason;
	}
	if (result != FREEZE_OK)
		return freeze_text(result);
	changed = first_changed(batch);
	if (changed < 0)
		failed = write_all(batch);
	thaw_threads();
	window_us = freeze_microseconds();
	if (changed >= 0) {
		_snprintf_s(reason, sizeof reason, _TRUNCATE, "%s: unexpected bytes", batch->steps[batch->writes[changed].step].name);
		return reason;
	}
	if (failed < 0)
		return NULL;
	register_leftovers(batch, owner);
	return write_failed(batch, failed);
}

static int fail(lua_State *L, const char *why, const int *list, int count)
{
	int i;

	lua_pushnil(L);
	lua_pushstring(L, why);
	if (count == 0)
		return 2;
	lua_createtable(L, count, 0);
	for (i = 0; i < count; i++) {
		lua_pushstring(L, entries[list[i]].name);
		lua_rawseti(L, -2, i + 1);
	}
	return 3;
}

static void commit_plan(lua_State *L, int owner)
{
	int i;

	for (i = 0; i < plan.step_count; i++) {
		if (!is_irreversible(plan.steps[i].kind))
			commit_step(L, &plan, owner, &plan.steps[i]);
	}
}

static BOOL holds_rewrite(int count)
{
	int i;

	for (i = 0; i < count; i++) {
		if (entries[i].kind == ITEM_FRAME || entries[i].kind == ITEM_RELOCATE)
			return TRUE;
	}
	return FALSE;
}

int l_batch(lua_State *L)
{
	const void *stack = _AddressOfReturnAddress();
	int owner = patcher_owner(L), count;
	const char *why;

	flush_link_log(L);
	luaL_checktype(L, 2, LUA_TTABLE);
	count = (int)lua_objlen(L, 2);
	stay_count = 0;
	plan.guard_count = 0;
	why = read_entries(L, 2, count);
	if (!why && callback_depth > 0 && holds_rewrite(count))
		why = hooked_call;
	if (!why)
		why = plan_steps(L, owner, 2, count, FALSE);
	if (why)
		return fail(L, why, stays, 0);
	why = make_irreversible(L, stack, owner, 2, count);
	if (!why && stay_count)
		why = plan_steps(L, owner, 2, count, TRUE);
	if (!why)
		why = write_window(&plan, stack, owner);
	if (why)
		return fail(L, why, stays, stay_count);
	commit_plan(L, owner);
	lua_pushboolean(L, 1);
	lua_pushnumber(L, (lua_Number)window_us);
	return 2;
}
