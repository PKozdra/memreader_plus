#include <string.h>

#include "hook.h"

typedef struct {
	struct TypedCall *typed;
} CallObject;

typedef struct AroundRun {
	const UINT64 *arguments;
	int position;
	BOOL called_game;
	BOOL returned;
	UINT64 kept;
	UINT64 value;
	struct AroundRun *outer;
} AroundRun;

typedef struct TypedCall {
	Hook *hook;
	const HookFrame *frame;
	UINT64 arguments[MAX_ARGUMENTS];
	UINT64 pending[MAX_ARGUMENTS];
	UINT64 pending_result;
	UINT64 replacement;
	UINT64 result;
	UINT32 pending_mask;
	BOOL pending_skip;
	BOOL replaced;
	BOOL faulted;
	BOOL reraise;
	int slot;
	int phase;
	int depth;
	int generation;
	LONG paused;
	AroundRun *around;
	CallObject *bound;
	BOOL skipped;
	LinkTag skipper;
	Fault fault;
} TypedCall;

static const char sink_key = 0;
static const char *const link_names[] = { "around", "prefix", "postfix", "around" };

static int link_runner = LUA_NOREF;
static int call_pool = LUA_NOREF;
static int call_meta = LUA_NOREF;
static int typed_depth;
static BOOL pending_log;
static char difference[TAG_SIZE + 48];

static int phase_of(int kind)
{
	if (kind == LINK_PREFIX)
		return PHASE_PREFIX;
	return kind == LINK_POSTFIX ? PHASE_POSTFIX : PHASE_AROUND;
}

static int oldest_hook_slot(const Hook *hook)
{
	int i;

	for (i = 0; i < hook->callback_count; i++) {
		if (hook->callbacks[i].kind == LINK_HOOK && holds_function(&hook->callbacks[i]))
			return i;
	}
	return 0;
}

static int place_of(const Hook *hook, int group, int slot)
{
	return hook->callbacks[slot].kind == LINK_HOOK ? group : slot;
}

static BOOL runs_before(const Hook *hook, int group, int a, int b)
{
	const Callback *first = &hook->callbacks[a], *second = &hook->callbacks[b];

	if (first->priority != second->priority)
		return first->priority > second->priority;
	if (place_of(hook, group, a) != place_of(hook, group, b))
		return place_of(hook, group, a) < place_of(hook, group, b);
	return first->kind == LINK_HOOK && a > b;
}

void rebuild_links(Hook *hook)
{
	int i, n, phase, group = oldest_hook_slot(hook);

	memset(hook->order_count, 0, sizeof hook->order_count);
	for (i = 0; i < hook->callback_count; i++) {
		if (!holds_function(&hook->callbacks[i]))
			continue;
		phase = phase_of(hook->callbacks[i].kind);
		n = hook->order_count[phase]++;
		while (n > 0 && runs_before(hook, group, i, hook->order[phase][n - 1])) {
			hook->order[phase][n] = hook->order[phase][n - 1];
			n--;
		}
		hook->order[phase][n] = (BYTE)i;
	}
}

static BOOL runnable(const Hook *hook, int slot)
{
	const Callback *callback = &hook->callbacks[slot];

	return holds_function(callback) && lua_status(callback->state) == 0;
}

static BOOL any_runnable(const Hook *hook)
{
	int phase, n;

	for (phase = 0; phase < PHASE_COUNT; phase++) {
		for (n = 0; n < hook->order_count[phase]; n++) {
			if (runnable(hook, hook->order[phase][n]))
				return TRUE;
		}
	}
	return FALSE;
}

static int next_around(const Hook *hook, int position)
{
	for (; position < hook->order_count[PHASE_AROUND]; position++) {
		if (runnable(hook, hook->order[PHASE_AROUND][position]))
			return position;
	}
	return -1;
}

static void push_arguments(lua_State *L, const Signature *signature, const UINT64 *arguments)
{
	int i;

	for (i = 0; i < signature->count; i++)
		push_bits(L, signature->arguments[i], arguments[i]);
}

static CallObject *push_call_object(lua_State *L, TypedCall *t)
{
	CallObject *object;

	lua_rawgeti(L, LUA_REGISTRYINDEX, call_pool);
	lua_rawgeti(L, -1, t->depth);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		object = lua_newuserdata(L, sizeof *object);
		object->typed = NULL;
		lua_rawgeti(L, LUA_REGISTRYINDEX, call_meta);
		lua_setmetatable(L, -2);
		lua_pushvalue(L, -1);
		lua_rawseti(L, -3, t->depth);
	} else {
		object = lua_touserdata(L, -1);
	}
	lua_remove(L, -2);
	object->typed = t;
	t->bound = object;
	t->generation = callback_generation();
	return object;
}

static void store_replacement(lua_State *L, TypedCall *t, int type)
{
	if (type == CALL_VOID || lua_isnil(L, -1))
		return;
	lua_replace(L, 1);
	t->replacement = argument_bits(L, 1, type);
	t->replaced = TRUE;
}

static void store_returned(lua_State *L, TypedCall *t, int type)
{
	if (type != CALL_VOID) {
		if (lua_isnil(L, -1))
			luaL_error(L, "the callback returned nothing, expected %s", call_type_name(type));
		lua_replace(L, 1);
		t->around->value = argument_bits(L, 1, type);
	}
	t->around->returned = TRUE;
}

static int run_in_lua(lua_State *L)
{
	TypedCall *t = lua_touserdata(L, 1);
	const Callback *callback = &t->hook->callbacks[t->slot];
	const Signature *signature = &t->hook->signature;
	int extra = callback->kind == LINK_HOOK ? 0 : 1;

	luaL_checkstack(L, MAX_ARGUMENTS + EXTRA_STACK_SLOTS, "link arguments");
	lua_rawgeti(L, LUA_REGISTRYINDEX, callback->function);
	if (extra)
		push_call_object(L, t);
	if (t->phase == PHASE_PREFIX) {
		push_arguments(L, signature, t->arguments);
		lua_call(L, signature->count + extra, 0);
	} else if (t->phase == PHASE_POSTFIX) {
		if (signature->result == CALL_VOID)
			lua_pushnil(L);
		else
			push_bits(L, signature->result, t->result);
		push_arguments(L, signature, t->arguments);
		lua_call(L, signature->count + 2, 1);
		store_replacement(L, t, signature->result);
	} else {
		push_arguments(L, signature, t->around->arguments);
		lua_call(L, signature->count + extra, 1);
		store_returned(L, t, signature->result);
	}
	return 0;
}

static void count_error(const Callback *callback, lua_State *L)
{
	Item *entry;
	size_t length;
	const char *message;

	if (callback->item < 0 || !item_at(callback->item)->used)
		return;
	entry = item_at(callback->item);
	if (entry->errors++ > 0)
		return;
	message = error_message(L, &length);
	memcpy(entry->error, message, length);
	entry->error[length] = '\0';
	entry->unlogged = TRUE;
	pending_log = TRUE;
}

static void record_failure(Hook *hook, int slot, lua_State *L)
{
	if (hook->callbacks[slot].kind == LINK_HOOK) {
		keep_error(hook, L);
		detach(hook, slot);
		return;
	}
	count_error(&hook->callbacks[slot], L);
	lua_pop(L, 1);
}

static void fill_tag(LinkTag *tag, const Callback *callback)
{
	const Item *entry = callback->item >= 0 && callback->kind != LINK_HOOK ? item_at(callback->item) : NULL;

	tag->owner = entry ? entry->owner : -1;
	if (!entry)
		return;
	tag->kind = entry->kind;
	memcpy(tag->name, entry->name, ITEM_NAME_SIZE);
}

static void release_object(TypedCall *t, CallObject *outer)
{
	if (t->bound && t->generation == callback_generation())
		t->bound->typed = outer ? t : NULL;
	t->bound = outer;
}

static BOOL run_link(TypedCall *t, int slot, int phase, LinkTag *tag)
{
	Hook *hook = t->hook;
	const Callback *callback = &hook->callbacks[slot];
	lua_State *L = callback->state;
	const LinkTag *saved_tag = hook->running_tag;
	CallObject *saved_object = t->bound;
	int saved_slot = t->slot, saved_phase = t->phase, saved_current = hook->current;
	BOOL ok;

	if (!lua_checkstack(L, 2))
		return FALSE;
	if (callback->item >= 0 && callback->kind != LINK_HOOK)
		item_at(callback->item)->calls++;
	fill_tag(tag, callback);
	t->slot = slot;
	t->phase = phase;
	hook->current = slot;
	hook->running_tag = tag;
	lua_rawgeti(L, LUA_REGISTRYINDEX, link_runner);
	lua_pushlightuserdata(L, t);
	ok = lua_pcall(L, 1, 0, 0) == 0;
	release_object(t, saved_object);
	hook->running_tag = saved_tag;
	t->slot = saved_slot;
	t->phase = saved_phase;
	hook->current = saved_current;
	if (!ok)
		record_failure(hook, slot, L);
	return ok;
}

static void mark_skip(TypedCall *t, const Callback *callback, const LinkTag *tag)
{
	if (callback->item >= 0 && callback->kind != LINK_HOOK)
		item_at(callback->item)->skips++;
	if (t->skipped)
		return;
	t->skipped = TRUE;
	t->skipper = *tag;
}

static void fill_block(const TypedCall *t, const UINT64 *arguments, CallBlock *block)
{
	const HookFrame *frame = t->frame;
	const Signature *signature = &t->hook->signature;
	int i;

	for (i = 0; i < REGISTER_ARGUMENTS; i++) {
		block->slots[i] = frame->registers[i];
		block->floats[i] = frame->floats[i].low;
	}
	memcpy(block->slots + REGISTER_ARGUMENTS, frame->stack, CALL_BLOCK_STACK * sizeof *block->slots);
	for (i = 0; i < signature->count; i++) {
		if (i < REGISTER_ARGUMENTS && is_float_type(signature->arguments[i]))
			block->floats[i] = arguments[i];
		else
			block->slots[i] = arguments[i];
	}
}

static void call_bottom(TypedCall *t, const UINT64 *arguments, UINT64 *result)
{
	INT_PTR function = (INT_PTR)t->hook->original;
	int type = t->hook->signature.result;
	BOOL old_callback = t->around && t->hook->callbacks[t->slot].kind == LINK_HOOK;
	CallBlock block;
	UINT64 bits = 0, float_bits = 0;

	fill_block(t, arguments, &block);
	if (t->around && (old_callback || t->paused > 0)) {
		t->faulted = !call_block_guarded(function, &block, &bits, &float_bits, &t->fault);
		t->reraise = t->reraise || (t->faulted && !old_callback);
	} else {
		resume_guarded_calls(t->paused);
		bits = call_unguarded(function, &block, &float_bits);
		pause_guarded_calls();
	}
	*result = is_float_type(type) ? float_bits : bits;
}

static void run_chain(TypedCall *t, int position, const UINT64 *arguments, UINT64 *result);

static void run_around(TypedCall *t, int position, const UINT64 *arguments, UINT64 *result)
{
	int slot = t->hook->order[PHASE_AROUND][position];
	AroundRun run = { arguments, position, FALSE, FALSE, 0, 0, t->around };
	LinkTag tag;
	BOOL ok;

	t->around = &run;
	ok = run_link(t, slot, PHASE_AROUND, &tag);
	t->around = run.outer;
	if (ok) {
		if (!run.called_game)
			mark_skip(t, &t->hook->callbacks[slot], &tag);
		*result = run.value;
	} else if (run.called_game) {
		*result = run.kept;
	} else {
		run_chain(t, position + 1, arguments, result);
	}
}

static void run_chain(TypedCall *t, int position, const UINT64 *arguments, UINT64 *result)
{
	position = next_around(t->hook, position);
	if (position < 0)
		call_bottom(t, arguments, result);
	else
		run_around(t, position, arguments, result);
}

static void apply_prefix(TypedCall *t, const Callback *callback, const LinkTag *tag)
{
	int i;

	for (i = 0; i < t->hook->signature.count; i++) {
		if (t->pending_mask & (1u << i))
			t->arguments[i] = t->pending[i];
	}
	if (t->pending_skip) {
		t->result = t->pending_result;
		mark_skip(t, callback, tag);
	}
}

static void run_prefixes(TypedCall *t)
{
	Hook *hook = t->hook;
	LinkTag tag;
	int n, slot;

	for (n = 0; n < hook->order_count[PHASE_PREFIX]; n++) {
		slot = hook->order[PHASE_PREFIX][n];
		if (!runnable(hook, slot))
			continue;
		t->pending_mask = 0;
		t->pending_skip = FALSE;
		if (!run_link(t, slot, PHASE_PREFIX, &tag))
			continue;
		apply_prefix(t, &hook->callbacks[slot], &tag);
		if (t->skipped)
			return;
	}
}

static void run_postfixes(TypedCall *t)
{
	Hook *hook = t->hook;
	LinkTag tag;
	int n, slot;

	for (n = 0; n < hook->order_count[PHASE_POSTFIX]; n++) {
		slot = hook->order[PHASE_POSTFIX][n];
		if (!runnable(hook, slot))
			continue;
		t->replaced = FALSE;
		if (run_link(t, slot, PHASE_POSTFIX, &tag) && t->replaced)
			t->result = t->replacement;
	}
}

static void raise_fault(const Fault *fault)
{
	ULONG_PTR information[2] = { 0, fault->address };

	RaiseException(fault->code, 0, fault->address ? 2 : 0, information);
}

int run_typed(Hook *hook, HookFrame *frame)
{
	TypedCall t;
	HookCall call = { hook, frame, NULL, 0, -1, innermost, &t };
	const Signature *signature = &hook->signature;
	enum HookOutcome outcome = is_float_type(signature->result) ? RETURN_FLOAT_RESULT : RETURN_RESULT;
	LONG paused;
	int i;

	if (!any_runnable(hook))
		return RUN_ORIGINAL;
	t.hook = hook;
	t.frame = frame;
	t.result = 0;
	t.pending_mask = 0;
	t.pending_skip = FALSE;
	t.replaced = FALSE;
	t.slot = 0;
	t.phase = PHASE_PREFIX;
	t.generation = 0;
	t.around = NULL;
	t.bound = NULL;
	t.skipped = FALSE;
	t.faulted = FALSE;
	t.reraise = FALSE;
	for (i = 0; i < signature->count; i++)
		t.arguments[i] = argument_slot(frame, i, signature->arguments[i]);
	frame->result = 0;
	frame->float_result = 0;
	hook->calls++;
	if (hook->running == 0)
		hook->current = -1;
	hook->running++;
	callback_depth++;
	innermost = &call;
	t.depth = ++typed_depth;
	paused = pause_guarded_calls();
	t.paused = paused;
	__try {
		run_prefixes(&t);
		if (!t.skipped)
			run_chain(&t, 0, t.arguments, &t.result);
		if (t.reraise) {
			resume_guarded_calls(paused);
			raise_fault(&t.fault);
		}
		run_postfixes(&t);
	} __finally {
		resume_guarded_calls(paused);
		typed_depth--;
		innermost = call.outer;
		callback_depth--;
		hook->running--;
		refresh_hook(hook);
	}
	set_result(frame, signature->result, t.result);
	return outcome;
}

static int run_below(lua_State *L, TypedCall *t, int first)
{
	const Signature *signature = &t->hook->signature;
	UINT64 arguments[MAX_ARGUMENTS] = { 0 };
	UINT64 result = 0;
	AroundRun *run = t->around;
	int given = lua_gettop(L) - first + 1;
	int i;

	if (given != 0 && given != signature->count)
		return luaL_error(L, "the signature takes %d %s, got %d", signature->count,
			signature->count == 1 ? "argument" : "arguments", given);
	for (i = 0; i < given; i++)
		arguments[i] = argument_bits(L, i + first, signature->arguments[i]);
	run->called_game = TRUE;
	run_chain(t, run->position + 1, given ? arguments : run->arguments, &result);
	run->kept = result;
	if (t->faulted) {
		t->faulted = FALSE;
		return call_crash_error(L, &t->fault);
	}
	if (signature->result == CALL_VOID)
		return 0;
	push_bits(L, signature->result, result);
	return 1;
}

int hook_next_typed(lua_State *L, HookCall *call)
{
	if (!call->typed->around)
		return luaL_error(L, "hook_next works only inside a callback of this address");
	return run_below(L, call->typed, 2);
}

static TypedCall *bound_call(lua_State *L)
{
	CallObject *object = lua_touserdata(L, 1);
	BOOL ours = FALSE;

	if (object && lua_getmetatable(L, 1)) {
		lua_rawgeti(L, LUA_REGISTRYINDEX, call_meta);
		ours = lua_rawequal(L, -1, -2);
		lua_pop(L, 2);
	}
	if (!ours)
		luaL_typerror(L, 1, "call");
	if (!object->typed)
		luaL_error(L, "call object used after its call returned");
	return object->typed;
}

static int call_set(lua_State *L)
{
	TypedCall *t = bound_call(L);
	const Signature *signature = &t->hook->signature;
	lua_Number number = luaL_checknumber(L, 2);
	int index;

	if (t->phase != PHASE_PREFIX)
		return luaL_error(L, "set works only inside a prefix");
	if (!(number >= 1 && number <= signature->count && number == (int)number))
		return luaL_error(L, "the argument number must be a whole number from 1 to %d", signature->count);
	index = (int)number - 1;
	t->pending[index] = argument_bits(L, 3, signature->arguments[index]);
	t->pending_mask |= 1u << index;
	return 0;
}

static int call_skip(lua_State *L)
{
	TypedCall *t = bound_call(L);
	int type = t->hook->signature.result;

	if (t->phase != PHASE_PREFIX)
		return luaL_error(L, "skip works only inside a prefix");
	if (type != CALL_VOID) {
		if (lua_isnoneornil(L, 2))
			return luaL_error(L, "skip needs a result, expected %s", call_type_name(type));
		t->pending_result = argument_bits(L, 2, type);
	}
	t->pending_skip = TRUE;
	return 0;
}

static int call_original(lua_State *L)
{
	TypedCall *t = bound_call(L);

	return call_with_signature(L, (INT_PTR)t->hook->original, &t->hook->signature, 2);
}

static int call_below(lua_State *L)
{
	TypedCall *t = bound_call(L);

	if (!t->around)
		return luaL_error(L, "game works only inside an around");
	return run_below(L, t, 2);
}

static int call_field(lua_State *L, const char *key)
{
	TypedCall *t = bound_call(L);
	const LinkTag *running = t->hook->running_tag;

	if (strcmp(key, "depth") == 0)
		lua_pushnumber(L, (lua_Number)callback_depth);
	else if (strcmp(key, "site") == 0)
		lua_pushstring(L, running->owner >= 0 ? running->name : "");
	else if (!t->skipped)
		lua_pushnil(L);
	else if (t->skipper.owner < 0)
		lua_pushliteral(L, "hook");
	else
		lua_pushfstring(L, "%s/%s", owner_name(t->skipper.owner), t->skipper.name);
	return 1;
}

static int call_index(lua_State *L)
{
	const char *key = luaL_checkstring(L, 2);

	if (strcmp(key, "site") == 0 || strcmp(key, "skipped") == 0 || strcmp(key, "depth") == 0)
		return call_field(L, key);
	if (strcmp(key, "set") == 0)
		lua_pushcfunction(L, call_set);
	else if (strcmp(key, "skip") == 0)
		lua_pushcfunction(L, call_skip);
	else if (strcmp(key, "original") == 0)
		lua_pushcfunction(L, call_original);
	else
		lua_pushnil(L);
	return 1;
}

void prepare_links(lua_State *L)
{
	lua_pushcfunction(L, run_in_lua);
	link_runner = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_newtable(L);
	call_pool = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_newtable(L);
	lua_pushcfunction(L, call_index);
	lua_setfield(L, -2, "__index");
	lua_pushcfunction(L, call_below);
	lua_setfield(L, -2, "__call");
	call_meta = luaL_ref(L, LUA_REGISTRYINDEX);
}

void forget_links(void)
{
	link_runner = LUA_NOREF;
	call_pool = LUA_NOREF;
	call_meta = LUA_NOREF;
}

static int slot_of(const Hook *hook, int item)
{
	int i;

	for (i = 0; i < hook->callback_count; i++) {
		if (is_attached(&hook->callbacks[i]) && hook->callbacks[i].kind != LINK_HOOK && hook->callbacks[i].item == item)
			return i;
	}
	return -1;
}

static int live_count(const Hook *hook)
{
	int i, count = 0;

	for (i = 0; i < hook->callback_count; i++)
		count += is_attached(&hook->callbacks[i]);
	return count;
}

static const char *signature_difference(const Hook *hook)
{
	char tag[TAG_SIZE] = "hook";
	int i;

	for (i = 0; i < hook->callback_count; i++) {
		const Callback *callback = &hook->callbacks[i];

		if (is_attached(callback) && callback->kind != LINK_HOOK && callback->item >= 0) {
			make_tag(tag, sizeof tag, item_at(callback->item)->owner, item_at(callback->item)->name);
			break;
		}
		if (is_attached(callback) && callback->kind == LINK_HOOK)
			break;
	}
	_snprintf_s(difference, sizeof difference, _TRUNCATE, "signature differs from %s", tag);
	return difference;
}

static void unlink_slot(Hook *hook, int slot)
{
	Callback *callback = &hook->callbacks[slot];

	callback->item = -1;
	hook->typed--;
	hook->stale = TRUE;
	if (hook->running)
		callback->doomed = TRUE;
	else
		detach(hook, slot);
	refresh_hook(hook);
}

static const char *check_room(const Hook *hook, int old)
{
	int free_slots = MAX_CALLBACKS - hook->callback_count + (old >= 0 && hook->running == 0 ? 1 : 0);

	if (free_slots > 0)
		return NULL;
	if (live_count(hook) < MAX_CALLBACKS)
		return "removed links keep their place until the running call returns; at most 32 per address";
	return "at most 32 links on this address";
}

const char *attach_link(lua_State *L, INT_PTR at, const Signature *signature, int kind, int priority, int item, int function_index)
{
	Hook *hook = find_hook(at);
	Item *entry = item_at(item);
	Callback *callback;
	const char *why;
	int old, others, thread, function;

	if (!hook || hook->kind != KIND_FUNCTION)
		return "the address holds no function hook";
	refresh_hook(hook);
	old = slot_of(hook, item);
	others = live_count(hook) - (old >= 0);
	if ((hook->running > 0 || others > 0) && !same_signature(&hook->signature, signature))
		return signature_difference(hook);
	why = check_room(hook, old);
	if (why)
		return why;
	watch_state_close(L);
	lua_pushthread(L);
	thread = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_pushvalue(L, function_index);
	function = luaL_ref(L, LUA_REGISTRYINDEX);
	if (others == 0 && hook->running == 0) {
		hook->signature = *signature;
		if (old < 0) {
			hook->calls = 0;
			InterlockedExchange(&hook->other_thread_calls, 0);
			hook->error[0] = '\0';
		}
	}
	if (old >= 0)
		unlink_slot(hook, old);
	callback = &hook->callbacks[hook->callback_count++];
	callback->state = L;
	callback->thread = thread;
	callback->function = function;
	callback->item = item;
	callback->priority = priority;
	callback->kind = (BYTE)(kind - ITEM_PREFIX + LINK_PREFIX);
	callback->doomed = FALSE;
	hook->typed++;
	hook->stale = TRUE;
	entry->priority = priority;
	entry->attached = callback_generation();
	entry->calls = 0;
	entry->skips = 0;
	entry->errors = 0;
	entry->unlogged = FALSE;
	entry->error[0] = '\0';
	refresh_hook(hook);
	return NULL;
}

BOOL link_is_current(lua_State *L, const Signature *signature, int item, int priority, int function_index)
{
	Hook *hook = find_hook(item_at(item)->at);
	int slot = hook ? slot_of(hook, item) : -1;
	BOOL same;

	if (slot < 0 || hook->callbacks[slot].priority != priority || !same_signature(&hook->signature, signature))
		return FALSE;
	lua_rawgeti(L, LUA_REGISTRYINDEX, hook->callbacks[slot].function);
	same = lua_rawequal(L, -1, function_index);
	lua_pop(L, 1);
	return same;
}

void remove_link(int item)
{
	Hook *hook = find_hook(item_at(item)->at);
	int slot = hook ? slot_of(hook, item) : -1;

	if (slot >= 0)
		unlink_slot(hook, slot);
}

int l_set_log(lua_State *L)
{
	if (!lua_isnoneornil(L, 1))
		luaL_checktype(L, 1, LUA_TFUNCTION);
	lua_settop(L, 1);
	lua_pushlightuserdata(L, (void *)&sink_key);
	lua_insert(L, 1);
	lua_rawset(L, LUA_REGISTRYINDEX);
	return 0;
}

static void log_error(lua_State *L, const Item *entry)
{
	lua_pushvalue(L, -1);
	lua_pushfstring(L, "[memreader Plus] %s/%s (%s): %s", owner_name(entry->owner), entry->name, item_kind_name(entry->kind), entry->error);
	if (lua_pcall(L, 1, 0, 0))
		lua_pop(L, 1);
}

void flush_link_log(lua_State *L)
{
	int i;

	if (!pending_log || callback_depth > 0)
		return;
	lua_pushlightuserdata(L, (void *)&sink_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (!lua_isfunction(L, -1)) {
		lua_pop(L, 1);
		return;
	}
	pending_log = FALSE;
	for (i = 0; i < item_total(); i++) {
		Item *entry = item_at(i);

		if (!entry->used || !entry->unlogged)
			continue;
		entry->unlogged = FALSE;
		if (entry->attached == callback_generation())
			log_error(L, entry);
	}
	lua_pop(L, 1);
}

int l_flush_log(lua_State *L)
{
	flush_link_log(L);
	return 0;
}

static void push_link_row(lua_State *L, const Hook *hook, const Callback *callback)
{
	const Item *entry = callback->item >= 0 ? item_at(callback->item) : NULL;
	BOOL counted = entry && callback->kind != LINK_HOOK;

	lua_createtable(L, 0, 8);
	lua_pushstring(L, entry ? owner_name(entry->owner) : "");
	lua_setfield(L, -2, "owner");
	lua_pushstring(L, entry ? entry->name : "");
	lua_setfield(L, -2, "name");
	lua_pushstring(L, callback->kind == LINK_HOOK && hook->kind == KIND_SITE ? "site" : link_names[callback->kind]);
	lua_setfield(L, -2, "link");
	lua_pushnumber(L, (lua_Number)callback->priority);
	lua_setfield(L, -2, "priority");
	if (!counted)
		return;
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
}

static void push_links(lua_State *L, const Hook *hook)
{
	int phase, n, count = 0;

	lua_createtable(L, 0, 0);
	if (!hook)
		return;
	for (phase = 0; phase < PHASE_COUNT; phase++) {
		for (n = 0; n < hook->order_count[phase]; n++) {
			const Callback *callback = &hook->callbacks[hook->order[phase][n]];

			if (!is_attached(callback))
				continue;
			push_link_row(L, hook, callback);
			lua_rawseti(L, -2, ++count);
		}
	}
}

static int push_claims(lua_State *L, INT_PTR from, INT_PTR to)
{
	int i, count = 0;

	lua_createtable(L, 0, 0);
	for (i = 0; i < claim_total(); i++) {
		const Claim *claim = claim_at(i);
		const Item *entry = item_at(claim->item);

		if (claim->from >= to || from >= claim->from + claim->size)
			continue;
		lua_createtable(L, 0, 4);
		lua_pushstring(L, owner_name(entry->owner));
		lua_setfield(L, -2, "owner");
		lua_pushstring(L, entry->name);
		lua_setfield(L, -2, "name");
		push_value(L, VALUE_POINTER, claim->from);
		lua_setfield(L, -2, "from");
		push_value(L, VALUE_POINTER, claim->from + claim->size);
		lua_setfield(L, -2, "to");
		lua_rawseti(L, -2, ++count);
	}
	return count;
}

int l_patch_info(lua_State *L)
{
	INT_PTR at = pointer_argument(L, 1);
	const Hook *hook = find_hook(at);
	int claims;

	flush_link_log(L);
	lua_settop(L, 0);
	lua_createtable(L, 0, 4);
	if (hook) {
		lua_pushstring(L, hook->kind == KIND_SITE ? "site" : hook->kind == KIND_CAVE ? "cave" : "function");
		lua_setfield(L, -2, "kind");
		lua_pushnumber(L, (lua_Number)hook->other_thread_calls);
		lua_setfield(L, -2, "other_thread_calls");
	}
	push_links(L, hook);
	lua_setfield(L, -2, "links");
	claims = push_claims(L, at, at + (hook ? hook->copied : 1));
	lua_setfield(L, -2, "claims");
	if (!hook && !claims) {
		lua_settop(L, 0);
		lua_pushnil(L);
	}
	return 1;
}
