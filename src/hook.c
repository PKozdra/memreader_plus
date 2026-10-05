#include <stddef.h>
#include <string.h>

#include "common.h"
#include "MinHook.h"
#include "buffer.h"

enum { MAX_HOOKS = 1000, MAX_CALLBACKS = 16, MAX_ERROR_LENGTH = 255, EXTRA_STACK_SLOTS = 8, SAVED_REGISTERS = 6 };

enum { TRAMPOLINE_SIZE = 64, MAX_REPORTED_HOOKS = 24 };

enum HookOutcome { RUN_ORIGINAL, RETURN_RESULT, RETURN_FLOAT_RESULT };

typedef struct {
	lua_State *state;
	int thread;
	int function;
} Callback;

typedef struct {
	INT_PTR target;
	void *original;
	Signature signature;
	Callback callbacks[MAX_CALLBACKS];
	int callback_count;
	int running;
	UINT32 calls;
	LONG other_thread_calls;
	char error[MAX_ERROR_LENGTH + 1];
} Hook;

typedef struct {
	UINT64 low;
	UINT64 high;
} FloatRegister;

typedef struct {
	UINT64 registers[SAVED_REGISTERS];
	FloatRegister floats[SAVED_REGISTERS];
	const UINT64 *stack;
	UINT64 result;
	UINT64 float_result;
	void *original;
} HookFrame;

_Static_assert(offsetof(HookFrame, floats) == 48 && offsetof(HookFrame, stack) == 144 &&
	offsetof(HookFrame, result) == 152 && offsetof(HookFrame, float_result) == 160 &&
	offsetof(HookFrame, original) == 168 && sizeof(HookFrame) == 176, "HookFrame layout is shared with thunk.asm");

#pragma pack(push, 1)
typedef struct {
	BYTE load_hook[2];
	Hook *hook;
	BYTE jump_to_entry[6];
	void (*entry)(void);
} HookStub;
#pragma pack(pop)

typedef struct HookCall {
	Hook *hook;
	HookFrame *frame;
	int level;
	int passed_down;
	struct HookCall *outer;
} HookCall;

static const BYTE MOV_RAX[2] = { 0x48, 0xB8 };
static const BYTE JMP_RIP_INDIRECT[6] = { 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 };
static const char state_watch_key = 0;

static Hook hooks[MAX_HOOKS];
static int hook_count;
static HookStub *stubs;
static LPVOID memory_near_game;
static DWORD script_thread;
static int callback_depth;
static int runner = LUA_NOREF;
static HookCall *innermost;

void hook_entry(void);

static ULONG_PTR exe_offset(INT_PTR address)
{
	return (ULONG_PTR)address - (ULONG_PTR)GetModuleHandleW(NULL);
}

static Hook *find_hook(INT_PTR target)
{
	int i;

	for (i = 0; i < hook_count; i++) {
		if (hooks[i].target == target)
			return &hooks[i];
	}
	return NULL;
}

BOOL is_hook_original(INT_PTR address)
{
	int i;

	for (i = 0; i < hook_count; i++) {
		if ((INT_PTR)hooks[i].original == address)
			return TRUE;
	}
	return FALSE;
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

static Hook *install_hook(lua_State *L, INT_PTR target)
{
	BYTE window[SAVED_BYTES];
	Hook *hook;
	MH_STATUS status;

	if (!in_exe_code(target) || !is_read_only_code(target)) {
		note_refusal(L, "hook", target);
		luaL_argerror(L, 1, "refused: hook takes only read-only code in the game's exe");
	}
	if (hook_count == MAX_HOOKS)
		luaL_error(L, "at most %d addresses can be hooked per game session", MAX_HOOKS);
	if (!start_hooking())
		luaL_error(L, "cannot start hooking");
	hook = &hooks[hook_count];
	hook->target = target;
	hook->callback_count = 0;
	capture_code(target, window);
	status = MH_CreateHook((LPVOID)target, &stubs[hook_count], &hook->original);
	if (status == MH_OK) {
		status = MH_EnableHook((LPVOID)target);
		if (status != MH_OK)
			MH_RemoveHook((LPVOID)target);
	}
	if (status == MH_ERROR_MEMORY_ALLOC)
		status = install_far_hook(target, &stubs[hook_count], &hook->original);
	if (status == MH_ERROR_MEMORY_ALLOC)
		luaL_error(L, "cannot hook %p: no free memory near the game's code for the trampoline", (void *)target);
	if (status == MH_ERROR_UNSUPPORTED_FUNCTION)
		luaL_error(L, "cannot hook %p: its first bytes cannot run from far memory once the near area is full", (void *)target);
	if (status != MH_OK)
		luaL_error(L, "cannot hook %p: %s", (void *)target, MH_StatusToString(status));
	remember_code(target, window);
	hook_count++;
	return hook;
}

static BOOL is_attached(const Callback *callback)
{
	return callback->function != LUA_NOREF;
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

static void compact(Hook *hook)
{
	int i, kept = 0;

	if (hook->running)
		return;
	for (i = 0; i < hook->callback_count; i++) {
		if (is_attached(&hook->callbacks[i]))
			hook->callbacks[kept++] = hook->callbacks[i];
	}
	hook->callback_count = kept;
}

static void detach(Hook *hook, int index)
{
	Callback *callback = &hook->callbacks[index];

	if (!is_attached(callback))
		return;
	luaL_unref(callback->state, LUA_REGISTRYINDEX, callback->function);
	luaL_unref(callback->state, LUA_REGISTRYINDEX, callback->thread);
	callback->function = LUA_NOREF;
	callback->state = NULL;
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

static BOOL same_signature(const Signature *a, const Signature *b)
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
		}
		hooks[i].callback_count = 0;
	}
	runner = LUA_NOREF;
	return 0;
}

static UINT64 argument_slot(const HookFrame *frame, int index, int type)
{
	if (index >= REGISTER_ARGUMENTS)
		return frame->stack[index - REGISTER_ARGUMENTS];
	return is_float_type(type) ? frame->floats[index].low : frame->registers[index];
}

static void set_result(HookFrame *frame, int type, UINT64 bits)
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
	for (i = 0; i < signature->count; i++)
		push_bits(L, signature->arguments[i], argument_slot(call->frame, i, signature->arguments[i]));
	lua_call(L, signature->count, 1);
	store_result(L, signature->result, call->frame);
	return 0;
}

static void watch_state_close(lua_State *L)
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
	script_thread = GetCurrentThreadId();
}

static void keep_error(Hook *hook, lua_State *L)
{
	size_t length;
	const char *message = lua_tolstring(L, -1, &length);

	if (!message) {
		message = "the callback raised an error that is not a string";
		length = strlen(message);
	}
	if (length > MAX_ERROR_LENGTH)
		length = MAX_ERROR_LENGTH;
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
		if (lua_pcall(L, 1, 0, 0) == 0)
			return TRUE;
		keep_error(hook, L);
		detach(hook, call->level);
		if (call->passed_down == call->level)
			return TRUE;
	}
	return FALSE;
}

int run_hook(Hook *hook, HookFrame *frame)
{
	HookCall call = { hook, frame, hook->callback_count, -1, innermost };
	enum HookOutcome outcome;
	LONG paused;
	BOOL done;

	frame->original = hook->original;
	if (GetCurrentThreadId() != script_thread) {
		InterlockedIncrement(&hook->other_thread_calls);
		return RUN_ORIGINAL;
	}
	if (runner == LUA_NOREF || next_runnable(hook, call.level) < 0)
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
		compact(hook);
	}
	return done ? outcome : RUN_ORIGINAL;
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

static int l_hook(lua_State *L)
{
	INT_PTR target = pointer_argument(L, 1);
	Signature signature;
	Callback *callback;
	Hook *hook;

	parse_signature(L, luaL_checkstring(L, 2), &signature);
	luaL_checktype(L, 3, LUA_TFUNCTION);
	if (!target)
		return luaL_argerror(L, 1, "address is NULL");
	hook = find_hook(target);
	if (hook && (attached_count(hook) > 0 || hook->running > 0)) {
		if (!same_signature(&hook->signature, &signature))
			return luaL_error(L, "%p is already hooked in this mode with a different signature", (void *)target);
		if (find_callback(L, hook, 3) >= 0)
			return luaL_error(L, "this callback is already attached to %p", (void *)target);
	}
	if (!hook)
		hook = install_hook(L, target);
	compact(hook);
	if (hook->callback_count == MAX_CALLBACKS && attached_count(hook) < MAX_CALLBACKS)
		return luaL_error(L, "unhooked callbacks keep their place until the running call returns; at most %d per address", MAX_CALLBACKS);
	if (hook->callback_count == MAX_CALLBACKS)
		return luaL_error(L, "at most %d callbacks per address", MAX_CALLBACKS);
	watch_state_close(L);
	if (attached_count(hook) == 0) {
		hook->signature = signature;
		hook->calls = 0;
		InterlockedExchange(&hook->other_thread_calls, 0);
		hook->error[0] = '\0';
	}
	callback = &hook->callbacks[hook->callback_count++];
	callback->state = L;
	lua_pushthread(L);
	callback->thread = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_pushvalue(L, 3);
	callback->function = luaL_ref(L, LUA_REGISTRYINDEX);
	return 0;
}

static int l_unhook(lua_State *L)
{
	Hook *hook = find_hook(pointer_argument(L, 1));
	int i;

	if (!lua_isnoneornil(L, 2))
		luaL_checktype(L, 2, LUA_TFUNCTION);
	if (!hook)
		return 0;
	if (lua_isnoneornil(L, 2)) {
		for (i = 0; i < hook->callback_count; i++) {
			if (is_attached(&hook->callbacks[i]))
				detach(hook, i);
		}
	} else if ((i = find_callback(L, hook, 2)) >= 0) {
		detach(hook, i);
	}
	compact(hook);
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
	attached = attached_count(hook);
	lua_createtable(L, 0, 6);
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
	if (hook->error[0]) {
		lua_pushstring(L, hook->error);
		lua_setfield(L, -2, "error");
	}
	return 1;
}

BOOL describe_hook_code(ULONG_PTR address, char *out, size_t size)
{
	ULONG_PTR stub_start = (ULONG_PTR)stubs, original;
	int i;

	if (stubs && address >= stub_start && address < stub_start + sizeof(HookStub) * hook_count) {
		i = (int)((address - stub_start) / sizeof(HookStub));
		if (out)
			_snprintf_s(out, size, _TRUNCATE, "Plus hook stub for Warhammer3.exe+0x%llx", (unsigned long long)exe_offset(hooks[i].target));
		return TRUE;
	}
	for (i = 0; i < hook_count; i++) {
		original = (ULONG_PTR)hooks[i].original;
		if (original && address >= original && address < original + TRAMPOLINE_SIZE) {
			if (out)
				_snprintf_s(out, size, _TRUNCATE, "trampoline of the Plus hook on Warhammer3.exe+0x%llx",
					(unsigned long long)exe_offset(hooks[i].target));
			return TRUE;
		}
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
	add_text(report, "  Warhammer3.exe+0x%llx  calls %lu", (unsigned long long)exe_offset(hook->target), (unsigned long)hook->calls);
	if (hook->other_thread_calls)
		add_text(report, ", other threads %ld", hook->other_thread_calls);
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
	add_text(report, "\n");
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
	{ "unhook", l_unhook },
	{ "hook_next", l_hook_next },
	{ "hook_info", l_hook_info },
	{ "hook_depth", l_hook_depth },
	{ NULL, NULL }
};
