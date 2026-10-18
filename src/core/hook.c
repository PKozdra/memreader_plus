#include <stddef.h>
#include <string.h>

#include "hook.h"
#include "MinHook.h"
#include "buffer.h"
#include "hde/hde64.h"

enum { TRAMPOLINE_SIZE = 64, MAX_REPORTED_HOOKS = 24, SITE_JUMP = 5, PROLOGUE_READ = 32 };

#pragma pack(push, 1)
typedef struct {
	BYTE load_hook[2];
	Hook *hook;
	BYTE jump_to_entry[6];
	void (*entry)(void);
} HookStub;
#pragma pack(pop)

static const BYTE MOV_RAX[2] = { 0x48, 0xB8 };
static const BYTE JMP_RIP_INDIRECT[6] = { 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 };
static const char state_watch_key = 0;

static Hook hooks[MAX_HOOKS];
static int hook_count;
static HookStub *stubs;
static LPVOID memory_near_game;
static DWORD script_thread;
int callback_depth;
static int runner = LUA_NOREF;
static int generation = 1;
HookCall *innermost;

void hook_entry(void);

static ULONG_PTR exe_offset(INT_PTR address)
{
	return (ULONG_PTR)address - (ULONG_PTR)GetModuleHandleW(NULL);
}

Hook *find_hook(INT_PTR target)
{
	int i;

	for (i = 0; i < hook_count; i++) {
		if (hooks[i].target == target)
			return &hooks[i];
	}
	return NULL;
}

BOOL in_hooked_prologue(INT_PTR address, size_t size)
{
	int i;

	for (i = 0; i < hook_count; i++) {
		if (address < hooks[i].target + hooks[i].copied && address + (INT_PTR)size > hooks[i].target)
			return TRUE;
	}
	return FALSE;
}

int copied_length(INT_PTR target)
{
	BYTE code[PROLOGUE_READ];
	int length = 0;

	if (!copy_memory(code, target, sizeof code))
		return SITE_JUMP;
	while (length < SITE_JUMP) {
		hde64s hs;

		hde64_disasm(code + length, &hs);
		if (hs.flags & F_ERROR)
			return SITE_JUMP;
		length += hs.len;
	}
	return length;
}

static BOOL is_read_only_code(INT_PTR address)
{
	MEMORY_BASIC_INFORMATION region;

	return VirtualQuery((LPCVOID)address, &region, sizeof region) && region.State == MEM_COMMIT &&
		region.Protect == PAGE_EXECUTE_READ;
}

static HookStub *make_stubs(void)
{
	SIZE_T size = sizeof(HookStub) * MAX_HOOKS;
	HookStub *made = VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
	DWORD old_protection;
	int i;

	if (!made)
		return NULL;
	for (i = 0; i < MAX_HOOKS; i++) {
		memcpy(made[i].load_hook, MOV_RAX, sizeof MOV_RAX);
		made[i].hook = &hooks[i];
		memcpy(made[i].jump_to_entry, JMP_RIP_INDIRECT, sizeof JMP_RIP_INDIRECT);
		made[i].entry = hook_entry;
	}
	VirtualProtect(made, size, PAGE_EXECUTE_READ, &old_protection);
	FlushInstructionCache(GetCurrentProcess(), made, size);
	return made;
}

static BOOL start_hooking(void)
{
	HMODULE module;
	MH_STATUS status;

	if (stubs)
		return TRUE;
	if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
			(LPCWSTR)(void *)hook_entry, &module))
		return FALSE;
	status = MH_Initialize();
	if (status != MH_OK && status != MH_ERROR_ALREADY_INITIALIZED)
		return FALSE;
	stubs = make_stubs();
	return stubs != NULL;
}

void prepare_hooks(void)
{
	if (start_hooking() && !memory_near_game)
		memory_near_game = AllocateBuffer(GetModuleHandleW(NULL));
}

static MH_STATUS install_code(INT_PTR target, void *detour, FinishHook finish, void *context, void **trampoline)
{
	MH_STATUS status = MH_CreateHook((LPVOID)target, detour, trampoline);

	if (status == MH_OK) {
		if (finish)
			finish(context, *trampoline);
		status = MH_EnableHook((LPVOID)target);
		if (status != MH_OK)
			MH_RemoveHook((LPVOID)target);
	}
	if (status == MH_ERROR_MEMORY_ALLOC)
		status = install_far_hook(target, detour, trampoline, finish, context);
	return status;
}

static MH_STATUS new_hook(INT_PTR target, int kind, void *detour, FinishHook finish, void *context, Hook **made)
{
	BYTE window[SAVED_BYTES];
	Hook *hook = &hooks[hook_count];
	int copied = copied_length(target);
	MH_STATUS status;

	if (in_hooked_prologue(target, copied))
		return MH_ERROR_ALREADY_CREATED;
	hook->target = target;
	hook->kind = kind;
	hook->copied = copied;
	hook->callback_count = 0;
	capture_code(target, window);
	status = install_code(target, detour, finish, context, &hook->trampoline);
	if (status != MH_OK)
		return status;
	remember_code(target, window);
	hook->original = hook->trampoline;
	hook_count++;
	*made = hook;
	return MH_OK;
}

static BOOL can_hook(INT_PTR target)
{
	return is_read_only_code(target) && !in_own_module(target);
}

static const char *kind_name(int kind)
{
	switch (kind) {
	case KIND_SITE: return "site hook";
	case KIND_CAVE: return "code cave";
	}
	return "function hook";
}

static void check_hook_start(lua_State *L, INT_PTR target, int kind)
{
	if (!can_hook(target)) {
		note_refusal(L, NULL, target);
		luaL_argerror(L, 1, "refused: this takes only read-only executable code outside memreader Plus's own module");
	}
	if (hook_count == MAX_HOOKS)
		luaL_error(L, "at most %d addresses can be hooked per game session", MAX_HOOKS);
	if (!start_hooking() || (kind == KIND_SITE && !prepare_site_stubs()))
		luaL_error(L, "cannot start hooking");
}

static void fill_detour(int kind, void **detour, FinishHook *finish, void **context)
{
	if (kind == KIND_FUNCTION)
		*detour = &stubs[hook_count];
	if (kind == KIND_SITE) {
		*detour = site_stub(hook_count);
		*finish = finish_site;
		*context = (void *)(INT_PTR)hook_count;
	}
}

static Hook *install_hook(lua_State *L, INT_PTR target, int kind, void *detour, FinishHook finish, void *context)
{
	Hook *hook = NULL;
	MH_STATUS status;

	check_hook_start(L, target, kind);
	if (kind != KIND_FUNCTION)
		check_site_target(L, target);
	fill_detour(kind, &detour, &finish, &context);
	status = new_hook(target, kind, detour, finish, context, &hook);
	if (status == MH_ERROR_MEMORY_ALLOC)
		luaL_error(L, "cannot hook %p: no free memory near the game's code for the trampoline", (void *)target);
	if (status == MH_ERROR_UNSUPPORTED_FUNCTION)
		luaL_error(L, "cannot hook %p: its first bytes cannot run from far memory once the near area is full", (void *)target);
	if (status == MH_ERROR_ALREADY_CREATED)
		luaL_error(L, "cannot hook %p: it overlaps the first bytes of another hook", (void *)target);
	if (status == FAR_HOOK_NO_FREEZE)
		luaL_error(L, "cannot hook %p: the other threads could not be stopped", (void *)target);
	if (status != MH_OK)
		luaL_error(L, "cannot hook %p: %s", (void *)target, MH_StatusToString(status));
	return hook;
}

void install_code_hook(lua_State *L, INT_PTR target, void *detour, size_t size, FinishHook finish, void *context)
{
	Hook *hook = find_hook(target);

	if (hook)
		luaL_error(L, "%p already holds a %s", (void *)target, kind_name(hook->kind));
	hook = install_hook(L, target, KIND_CAVE, detour, finish, context);
	hook->cave = detour;
	hook->cave_size = size;
}

static int check_cave_target(lua_State *L)
{
	INT_PTR target = (INT_PTR)lua_touserdata(L, 1);
	Hook *hook = find_hook(target);

	if (hook)
		luaL_error(L, "%p already holds a %s", (void *)target, kind_name(hook->kind));
	check_hook_start(L, target, KIND_CAVE);
	check_site_target(L, target);
	if (in_hooked_prologue(target, copied_length(target)))
		luaL_error(L, "cannot hook %p: it overlaps the first bytes of another hook", (void *)target);
	return 0;
}

BOOL check_cave(lua_State *L, INT_PTR target)
{
	return lua_cpcall(L, check_cave_target, (void *)target) == 0;
}

void mark_callback(INT_PTR target, int item)
{
	Hook *hook = find_hook(target);

	if (hook && hook->callback_count > 0)
		hook->callbacks[hook->callback_count - 1].item = item;
}

void *cave_start(INT_PTR target)
{
	Hook *hook = find_hook(target);

	return hook && hook->kind == KIND_CAVE ? hook->cave : NULL;
}

BOOL hook_native(INT_PTR target, void *detour, const char *name, void **next)
{
	Hook *hook = find_hook(target);

	if (!hook && (hook_count == MAX_HOOKS || !can_hook(target) || !start_hooking() ||
			new_hook(target, KIND_FUNCTION, &stubs[hook_count], NULL, NULL, &hook) != MH_OK))
		return FALSE;
	if (hook->kind != KIND_FUNCTION)
		return FALSE;
	if (hook->native)
		return FALSE;
	*next = hook->trampoline;
	MemoryBarrier();
	hook->native = name;
	hook->original = detour;
	return TRUE;
}

BOOL holds_function(const Callback *callback)
{
	return callback->function != LUA_NOREF;
}

BOOL is_attached(const Callback *callback)
{
	return holds_function(callback) && !callback->doomed;
}

static int attached_count(const Hook *hook)
{
	int i, count = 0;

	for (i = 0; i < hook->callback_count; i++)
		count += is_attached(&hook->callbacks[i]);
	return count;
}


static int next_runnable(const Hook *hook, int below)
{
	int i;

	for (i = below - 1; i >= 0; i--) {
		if (is_attached(&hook->callbacks[i]) && lua_status(hook->callbacks[i].state) == 0)
			return i;
	}
	return -1;
}

void refresh_hook(Hook *hook)
{
	int i, kept = 0;

	if (hook->running)
		return;
	for (i = 0; i < hook->callback_count; i++) {
		if (hook->callbacks[i].doomed)
			detach(hook, i);
		if (holds_function(&hook->callbacks[i]))
			hook->callbacks[kept++] = hook->callbacks[i];
	}
	hook->callback_count = kept;
	if (hook->stale) {
		rebuild_links(hook);
		hook->stale = FALSE;
	}
}

void detach(Hook *hook, int index)
{
	Callback *callback = &hook->callbacks[index];

	if (!holds_function(callback))
		return;
	luaL_unref(callback->state, LUA_REGISTRYINDEX, callback->function);
	luaL_unref(callback->state, LUA_REGISTRYINDEX, callback->thread);
	luaL_unref(callback->state, LUA_REGISTRYINDEX, callback->when_ref);
	callback->function = LUA_NOREF;
	callback->state = NULL;
	callback->when = NULL;
	callback->when_ref = LUA_NOREF;
	callback->doomed = FALSE;
	hook->stale = TRUE;
}

static int find_callback(lua_State *L, const Hook *hook, int index)
{
	int i;
	BOOL same;

	for (i = 0; i < hook->callback_count; i++) {
		if (!is_attached(&hook->callbacks[i]))
			continue;
		lua_rawgeti(L, LUA_REGISTRYINDEX, hook->callbacks[i].function);
		same = lua_rawequal(L, -1, index);
		lua_pop(L, 1);
		if (same)
			return i;
	}
	return -1;
}

BOOL same_signature(const Signature *a, const Signature *b)
{
	return a->result == b->result && a->count == b->count &&
		memcmp(a->arguments, b->arguments, sizeof a->arguments[0] * (size_t)a->count) == 0;
}

static int forget_callbacks(lua_State *L)
{
	int i, j;

	(void)L;
	for (i = 0; i < hook_count; i++) {
		for (j = 0; j < hooks[i].callback_count; j++) {
			hooks[i].callbacks[j].function = LUA_NOREF;
			hooks[i].callbacks[j].state = NULL;
			hooks[i].callbacks[j].when = NULL;
			hooks[i].callbacks[j].when_ref = LUA_NOREF;
			hooks[i].callbacks[j].doomed = FALSE;
		}
		hooks[i].callback_count = 0;
		memset(hooks[i].order_count, 0, sizeof hooks[i].order_count);
		hooks[i].typed = 0;
		hooks[i].stale = FALSE;
	}
	forget_links();
	runner = LUA_NOREF;
	generation++;
	return 0;
}

int callback_generation(void)
{
	return generation;
}

UINT64 argument_slot(const HookFrame *frame, int index, int type)
{
	if (index >= REGISTER_ARGUMENTS)
		return frame->stack[index - REGISTER_ARGUMENTS];
	return is_float_type(type) ? frame->floats[index].low : frame->registers[index];
}

void set_result(HookFrame *frame, int type, UINT64 bits)
{
	if (is_float_type(type))
		frame->float_result = bits;
	else
		frame->result = bits;
}

static void store_result(lua_State *L, int type, HookFrame *frame)
{
	if (type == CALL_VOID)
		return;
	if (lua_isnil(L, -1))
		luaL_error(L, "the callback returned nothing, expected %s", call_type_name(type));
	lua_replace(L, 1);
	set_result(frame, type, argument_bits(L, 1, type));
}

static int dispatch(lua_State *L)
{
	HookCall *call = lua_touserdata(L, 1);
	const Signature *signature = &call->hook->signature;
	int i;

	luaL_checkstack(L, MAX_ARGUMENTS + EXTRA_STACK_SLOTS, "hook arguments");
	lua_rawgeti(L, LUA_REGISTRYINDEX, call->hook->callbacks[call->level].function);
	if (call->registers) {
		push_registers(L);
		lua_call(L, 1, 0);
		return 0;
	}
	for (i = 0; i < signature->count; i++)
		push_bits(L, signature->arguments[i], argument_slot(call->frame, i, signature->arguments[i]));
	lua_call(L, signature->count, 1);
	store_result(L, signature->result, call->frame);
	return 0;
}

void watch_state_close(lua_State *L)
{
	lua_pushlightuserdata(L, (void *)&state_watch_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (!lua_isnil(L, -1)) {
		lua_pop(L, 1);
		return;
	}
	lua_pop(L, 1);
	lua_pushlightuserdata(L, (void *)&state_watch_key);
	lua_newuserdata(L, 1);
	lua_createtable(L, 0, 1);
	lua_pushcfunction(L, forget_callbacks);
	lua_setfield(L, -2, "__gc");
	lua_setmetatable(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
	lua_pushcfunction(L, dispatch);
	runner = luaL_ref(L, LUA_REGISTRYINDEX);
	prepare_links(L);
	script_thread = GetCurrentThreadId();
}

const char *error_message(lua_State *L, size_t *length)
{
	const char *message = lua_tolstring(L, -1, length);

	if (!message) {
		message = "the callback raised an error that is not a string";
		*length = strlen(message);
	}
	if (*length > MAX_ERROR_LENGTH)
		*length = MAX_ERROR_LENGTH;
	return message;
}

void keep_error(Hook *hook, lua_State *L)
{
	size_t length;
	const char *message = error_message(L, &length);

	memcpy(hook->error, message, length);
	hook->error[length] = '\0';
	lua_pop(L, 1);
}

static BOOL run_callbacks(HookCall *call)
{
	Hook *hook = call->hook;
	lua_State *L;

	while ((call->level = next_runnable(hook, call->level)) >= 0) {
		L = hook->callbacks[call->level].state;
		if (!lua_checkstack(L, 2))
			return FALSE;
		lua_rawgeti(L, LUA_REGISTRYINDEX, runner);
		lua_pushlightuserdata(L, call);
		hook->current = call->level;
		if (lua_pcall(L, 1, 0, 0) == 0) {
			if (!call->registers)
				return TRUE;
			continue;
		}
		keep_error(hook, L);
		detach(hook, call->level);
		if (call->passed_down == call->level)
			return TRUE;
	}
	return FALSE;
}

static int run_legacy(Hook *hook, HookFrame *frame)
{
	HookCall call = { hook, frame, NULL, hook->callback_count, -1, innermost, NULL };
	enum HookOutcome outcome;
	LONG paused;
	BOOL done;

	if (next_runnable(hook, call.level) < 0)
		return RUN_ORIGINAL;
	outcome = is_float_type(hook->signature.result) ? RETURN_FLOAT_RESULT : RETURN_RESULT;
	frame->result = 0;
	frame->float_result = 0;
	hook->calls++;
	hook->running++;
	callback_depth++;
	innermost = &call;
	paused = pause_guarded_calls();
	__try {
		done = run_callbacks(&call);
	} __finally {
		resume_guarded_calls(paused);
		innermost = call.outer;
		callback_depth--;
		hook->running--;
		refresh_hook(hook);
	}
	return done ? outcome : RUN_ORIGINAL;
}

int run_hook(Hook *hook, HookFrame *frame)
{
	frame->original = hook->original;
	if (GetCurrentThreadId() != script_thread) {
		InterlockedIncrement(&hook->other_thread_calls);
		return RUN_ORIGINAL;
	}
	if (runner == LUA_NOREF)
		return RUN_ORIGINAL;
	if (hook->typed > 0)
		return run_typed(hook, frame);
	return run_legacy(hook, frame);
}

static BOOL has_dirty_upper_halves(const SiteFrame *frame)
{
	int i;

	for (i = 0; i < SITE_VECTORS; i++) {
		if (frame->upper[i].low | frame->upper[i].high)
			return TRUE;
	}
	return FALSE;
}

void run_site(SiteFrame *frame)
{
	Hook *hook = &hooks[site_index(frame)];
	HookCall call = { hook, NULL, frame, hook->callback_count, -1, innermost, NULL };
	SiteFrame *outer;
	LONG paused;

	frame->upper_used = site_avx && has_dirty_upper_halves(frame);
	if (GetCurrentThreadId() != script_thread) {
		InterlockedIncrement(&hook->other_thread_calls);
		return;
	}
	if (runner == LUA_NOREF || next_runnable(hook, call.level) < 0)
		return;
	hook->calls++;
	hook->running++;
	callback_depth++;
	paused = pause_guarded_calls();
	outer = swap_active_site(frame);
	frame->spare = frame->return_address;
	frame->return_address = (UINT64)(hook->target + hook->copied);
	__try {
		run_callbacks(&call);
	} __finally {
		if (!AbnormalTermination())
			frame->return_address = frame->spare;
		swap_active_site(outer);
		resume_guarded_calls(paused);
		callback_depth--;
		hook->running--;
		refresh_hook(hook);
	}
}

static HookCall *find_call(INT_PTR target)
{
	HookCall *call;

	for (call = innermost; call; call = call->outer) {
		if (call->hook->target == target)
			return call;
	}
	return NULL;
}

static int call_next(lua_State *L, HookCall *call, int arguments)
{
	Hook *hook = call->hook;
	int result = hook->signature.result;
	int i, failed;

	luaL_checkstack(L, arguments + EXTRA_STACK_SLOTS, "hook_next arguments");
	lua_rawgeti(L, LUA_REGISTRYINDEX, hook->callbacks[call->level].function);
	for (i = 0; i < arguments; i++)
		lua_pushvalue(L, i + 2);
	callback_depth++;
	failed = lua_pcall(L, arguments, 1, 0);
	callback_depth--;
	if (!failed && result != CALL_VOID && lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_pushfstring(L, "the callback returned nothing, expected %s", call_type_name(result));
		failed = 1;
	}
	if (failed) {
		keep_error(hook, L);
		detach(hook, call->level);
		return -1;
	}
	if (result != CALL_VOID)
		return 1;
	lua_pop(L, 1);
	return 0;
}

static int store_next_result(lua_State *L)
{
	HookCall *call = lua_touserdata(L, 1);
	int type = call->hook->signature.result;

	set_result(call->frame, type, argument_bits(L, 2, type));
	return 0;
}

static void keep_callback_result(lua_State *L, HookCall *call, int results)
{
	if (results == 0 || !lua_checkstack(L, 3))
		return;
	lua_pushcfunction(L, store_next_result);
	lua_pushlightuserdata(L, call);
	lua_pushvalue(L, -3);
	if (lua_pcall(L, 2, 0, 0))
		lua_pop(L, 1);
}

static int push_kept_result(lua_State *L, const HookCall *call)
{
	int type = call->hook->signature.result;

	if (type == CALL_VOID)
		return 0;
	push_bits(L, type, is_float_type(type) ? call->frame->float_result : call->frame->result);
	return 1;
}

static int passed_down(HookCall *call, int level, int results)
{
	call->level = level;
	call->passed_down = level;
	return results;
}

static int l_hook_next(lua_State *L)
{
	HookCall *call = find_call(pointer_argument(L, 1));
	int arguments = lua_gettop(L) - 1;
	int type, level, results;

	if (!call)
		return luaL_error(L, "hook_next works only inside a callback of this address");
	if (call->typed)
		return hook_next_typed(L, call);
	type = call->hook->signature.result;
	level = call->level;
	while ((call->level = next_runnable(call->hook, call->level)) >= 0) {
		results = call_next(L, call, arguments);
		if (results >= 0) {
			keep_callback_result(L, call, results);
			return passed_down(call, level, results);
		}
		if (call->passed_down == call->level)
			return passed_down(call, level, push_kept_result(L, call));
	}
	call->level = level;
	results = call_with_signature(L, (INT_PTR)call->hook->original, &call->hook->signature, 2);
	if (results > 0)
		set_result(call->frame, type, argument_bits(L, -1, type));
	return passed_down(call, level, results);
}

static int count_hook_slots(const Hook *hook, BOOL attached_only)
{
	int i, count = 0;

	for (i = 0; i < hook->callback_count; i++) {
		if (hook->callbacks[i].kind == LINK_HOOK && (!attached_only || is_attached(&hook->callbacks[i])))
			count++;
	}
	return count;
}

static int add_callback(lua_State *L, Hook *hook, int function, const Signature *signature)
{
	Callback *callback;
	int slots;

	refresh_hook(hook);
	slots = count_hook_slots(hook, FALSE);
	if (slots == MAX_HOOK_CALLBACKS && count_hook_slots(hook, TRUE) < MAX_HOOK_CALLBACKS)
		return luaL_error(L, "unhooked callbacks keep their place until the running call returns; at most %d per address", MAX_HOOK_CALLBACKS);
	if (slots == MAX_HOOK_CALLBACKS)
		return luaL_error(L, "at most %d callbacks per address", MAX_HOOK_CALLBACKS);
	if (hook->callback_count == MAX_CALLBACKS)
		return luaL_error(L, "at most %d links on this address", MAX_CALLBACKS);
	watch_state_close(L);
	if (attached_count(hook) == 0) {
		if (signature)
			hook->signature = *signature;
		hook->calls = 0;
		InterlockedExchange(&hook->other_thread_calls, 0);
		hook->error[0] = '\0';
	}
	callback = &hook->callbacks[hook->callback_count++];
	callback->state = L;
	callback->item = -1;
	callback->priority = 0;
	callback->kind = LINK_HOOK;
	callback->doomed = FALSE;
	callback->when = NULL;
	callback->when_ref = LUA_NOREF;
	hook->stale = TRUE;
	lua_pushthread(L);
	callback->thread = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_pushvalue(L, function);
	callback->function = luaL_ref(L, LUA_REGISTRYINDEX);
	refresh_hook(hook);
	return 0;
}

static Hook *find_hook_of_kind(lua_State *L, INT_PTR target, int kind)
{
	Hook *hook = find_hook(target);

	if (hook && hook->kind != kind)
		luaL_error(L, "%p already holds a %s", (void *)target, kind_name(hook->kind));
	return hook;
}

static int l_hook(lua_State *L)
{
	INT_PTR target = pointer_argument(L, 1);
	Signature signature;
	Hook *hook;

	parse_signature(L, luaL_checkstring(L, 2), &signature);
	luaL_checktype(L, 3, LUA_TFUNCTION);
	if (!target)
		return luaL_argerror(L, 1, "address is NULL");
	hook = find_hook_of_kind(L, target, KIND_FUNCTION);
	if (hook && (attached_count(hook) > 0 || hook->running > 0)) {
		if (!same_signature(&hook->signature, &signature))
			return luaL_error(L, "%p is already hooked in this mode with a different signature", (void *)target);
		if (find_callback(L, hook, 3) >= 0)
			return luaL_error(L, "this callback is already attached to %p", (void *)target);
	}
	if (!hook)
		hook = install_hook(L, target, KIND_FUNCTION, NULL, NULL, NULL);
	return add_callback(L, hook, 3, &signature);
}

int l_function_hook(lua_State *L)
{
	INT_PTR target = pointer_argument(L, 1);

	if (!target)
		return luaL_argerror(L, 1, "address is NULL");
	if (!find_hook_of_kind(L, target, KIND_FUNCTION))
		install_hook(L, target, KIND_FUNCTION, NULL, NULL, NULL);
	return 0;
}

int l_hook_site(lua_State *L)
{
	INT_PTR target = pointer_argument(L, 1);
	Hook *hook;

	luaL_checktype(L, 2, LUA_TFUNCTION);
	if (!target)
		return luaL_argerror(L, 1, "address is NULL");
	hook = find_hook_of_kind(L, target, KIND_SITE);
	if (hook && find_callback(L, hook, 2) >= 0)
		return luaL_error(L, "this callback is already attached to %p", (void *)target);
	if (!hook)
		hook = install_hook(L, target, KIND_SITE, NULL, NULL, NULL);
	return add_callback(L, hook, 2, NULL);
}

int l_unhook(lua_State *L)
{
	Hook *hook = find_hook(pointer_argument(L, 1));
	int i;

	if (!lua_isnoneornil(L, 2))
		luaL_checktype(L, 2, LUA_TFUNCTION);
	if (!hook)
		return 0;
	if (lua_isnoneornil(L, 2)) {
		for (i = 0; i < hook->callback_count; i++) {
			if (is_attached(&hook->callbacks[i]) && hook->callbacks[i].kind == LINK_HOOK)
				detach(hook, i);
		}
	} else if ((i = find_callback(L, hook, 2)) >= 0 && hook->callbacks[i].kind == LINK_HOOK) {
		detach(hook, i);
	}
	refresh_hook(hook);
	return 0;
}

static int l_hook_info(lua_State *L)
{
	Hook *hook = find_hook(pointer_argument(L, 1));
	int attached;

	if (!hook) {
		lua_pushnil(L);
		return 1;
	}
	attached = count_hook_slots(hook, TRUE);
	lua_createtable(L, 0, 8);
	lua_pushstring(L, hook->kind == KIND_SITE ? "site" : hook->kind == KIND_CAVE ? "cave" : "function");
	lua_setfield(L, -2, "kind");
	push_value(L, VALUE_POINTER, (INT_PTR)hook->original);
	lua_setfield(L, -2, "original");
	lua_pushboolean(L, attached > 0);
	lua_setfield(L, -2, "attached");
	lua_pushnumber(L, (lua_Number)attached);
	lua_setfield(L, -2, "callbacks");
	lua_pushnumber(L, (lua_Number)hook->calls);
	lua_setfield(L, -2, "calls");
	lua_pushnumber(L, (lua_Number)hook->other_thread_calls);
	lua_setfield(L, -2, "other_thread_calls");
	if (hook->cave) {
		push_value(L, VALUE_POINTER, (INT_PTR)hook->cave);
		lua_setfield(L, -2, "cave");
	}
	if (hook->error[0]) {
		lua_pushstring(L, hook->error);
		lua_setfield(L, -2, "error");
	}
	return 1;
}

static void describe_target(char *out, size_t size, const char *what, INT_PTR target)
{
	if (in_game_image(target, 1))
		_snprintf_s(out, size, _TRUNCATE, "%s Warhammer3.exe+0x%llx", what, (unsigned long long)exe_offset(target));
	else
		_snprintf_s(out, size, _TRUNCATE, "%s %016llx", what, (unsigned long long)target);
}

static void owner_phrase(char *out, size_t size, INT_PTR target)
{
	char text[TAG_SIZE * 4];
	int kind = describe_owner(target, text, sizeof text);

	out[0] = '\0';
	if (kind != OWNER_NONE)
		_snprintf_s(out, size, _TRUNCATE, ", %s %s", kind == OWNER_NAMED ? "by" : "from", text);
}

static BOOL describe_hook(char *out, size_t size, const char *what, const Hook *hook)
{
	char owner[TAG_SIZE * 4 + 16];
	size_t used;

	if (!out)
		return TRUE;
	describe_target(out, size, what, hook->target);
	used = strlen(out);
	owner_phrase(owner, sizeof owner, hook->target);
	_snprintf_s(out + used, size - used, _TRUNCATE, "%s", owner);
	return TRUE;
}

BOOL describe_hook_code(ULONG_PTR address, char *out, size_t size)
{
	ULONG_PTR stub_start = (ULONG_PTR)stubs, original;
	int i = site_stub_at(address);

	if (i >= 0 && i < hook_count)
		return describe_hook(out, size, "Plus site stub for", &hooks[i]);
	if (stubs && address >= stub_start && address < stub_start + sizeof(HookStub) * hook_count) {
		i = (int)((address - stub_start) / sizeof(HookStub));
		return describe_hook(out, size, "Plus hook stub for", &hooks[i]);
	}
	for (i = 0; i < hook_count; i++) {
		if (hooks[i].cave && address >= (ULONG_PTR)hooks[i].cave && address < (ULONG_PTR)hooks[i].cave + hooks[i].cave_size)
			return describe_hook(out, size, "Plus code cave for", &hooks[i]);
		original = (ULONG_PTR)hooks[i].trampoline;
		if (original && address >= original && address < original + TRAMPOLINE_SIZE)
			return describe_hook(out, size, "trampoline of the Plus hook on", &hooks[i]);
	}
	return FALSE;
}

static void add_callback_sources(Text *report, lua_State *live, const Hook *hook)
{
	DebugRecord record;
	int i, top;

	for (i = 0; i < hook->callback_count; i++) {
		if (!is_attached(&hook->callbacks[i]) || hook->callbacks[i].state != live)
			continue;
		top = lua_gettop(live);
		lua_rawgeti(live, LUA_REGISTRYINDEX, hook->callbacks[i].function);
		if (lua_isfunction(live, -1) && lua_getinfo(live, ">S", &record.fields)) {
			record.raw[DEBUG_RECORD_SIZE - 1] = '\0';
			add_text(report, ", callback %s:%d", record.fields.short_src, record.fields.linedefined);
		}
		lua_settop(live, top);
	}
}

static void add_hook_line(Text *report, lua_State *live, const Hook *hook)
{
	char owner[TAG_SIZE * 4 + 16];

	add_text(report, "  ");
	add_address(report, (ULONG_PTR)hook->target);
	add_text(report, "  calls %lu", (unsigned long)hook->calls);
	if (hook->other_thread_calls)
		add_text(report, ", other threads %ld", hook->other_thread_calls);
	if (hook->kind != KIND_FUNCTION)
		add_text(report, ", %s", kind_name(hook->kind));
	if (hook->native)
		add_text(report, ", native %s", hook->native);
	if (hook->running)
		add_text(report, ", RUNNING (on the stack)");
	if (live) {
		__try {
			add_callback_sources(report, live, hook);
		} __except (EXCEPTION_EXECUTE_HANDLER) {
			add_text(report, ", callbacks unreadable");
		}
	}
	if (hook->error[0])
		add_text(report, ", last callback error: %s", hook->error);
	owner_phrase(owner, sizeof owner, hook->target);
	add_text(report, "%s", owner);
	add_filter_text(report, hook);
	add_text(report, "\n");
}

static BOOL running_link(const Hook *hook, LinkTag *out)
{
	int item;

	if (hook->running_tag && hook->running_tag->owner >= 0) {
		*out = *hook->running_tag;
		return TRUE;
	}
	if (hook->current < 0 || hook->current >= hook->callback_count)
		return FALSE;
	item = hook->callbacks[hook->current].item;
	if (item < 0 || !item_at(item)->used)
		return FALSE;
	out->owner = item_at(item)->owner;
	out->kind = item_at(item)->kind;
	memcpy(out->name, item_at(item)->name, ITEM_NAME_SIZE);
	return TRUE;
}

void add_running_links(Text *report)
{
	char tag[TAG_SIZE];
	LinkTag running;
	int i;

	for (i = 0; i < hook_count; i++) {
		if (hooks[i].running <= 0 || !running_link(&hooks[i], &running))
			continue;
		make_tag(tag, sizeof tag, running.owner, running.name);
		add_text(report, "memreader Plus link running: %s (%s) on ", tag, item_kind_name(running.kind));
		add_address(report, (ULONG_PTR)hooks[i].target);
		add_text(report, "\n");
	}
}

void add_hooks(Text *report, lua_State *live)
{
	int i, shown = 0, pass;

	add_text(report, "memreader Plus hooks: %d\n", hook_count);
	for (pass = 0; pass < 2; pass++) {
		for (i = 0; i < hook_count && shown < MAX_REPORTED_HOOKS; i++) {
			if ((pass == 0) == (hooks[i].running > 0 || hooks[i].error[0] != '\0')) {
				add_hook_line(report, live, &hooks[i]);
				shown++;
			}
		}
	}
	if (shown < hook_count)
		add_text(report, "  and %d more\n", hook_count - shown);
}

static int l_hook_depth(lua_State *L)
{
	lua_pushnumber(L, (lua_Number)callback_depth);
	return 1;
}

const luaL_Reg hook_functions[] = {
	{ "hook", l_hook },
	{ "hook_site", l_hook_site },
	{ "unhook", l_unhook },
	{ "hook_next", l_hook_next },
	{ "hook_info", l_hook_info },
	{ "hook_depth", l_hook_depth },
	{ NULL, NULL }
};
