#include <stddef.h>
#include <string.h>

#include "common.h"
#include "MinHook.h"
#include "buffer.h"

enum { MAX_HOOKS = 64, MAX_ERROR_LENGTH = 255, EXTRA_STACK_SLOTS = 8 };

typedef struct {
	INT_PTR target;
	void *original;
	Signature signature;
	lua_State *state;
	int thread;
	int callback;
	UINT32 calls;
	char error[MAX_ERROR_LENGTH + 1];
} Hook;

typedef struct {
	UINT64 registers[REGISTER_ARGUMENTS];
	UINT64 floats[REGISTER_ARGUMENTS];
	const UINT64 *stack;
	UINT64 result;
	UINT64 float_result;
	void *original;
} HookFrame;

_Static_assert(offsetof(HookFrame, floats) == 32 && offsetof(HookFrame, stack) == 64 &&
	offsetof(HookFrame, result) == 72 && offsetof(HookFrame, float_result) == 80 &&
	offsetof(HookFrame, original) == 88 && sizeof(HookFrame) == 96, "HookFrame layout is shared with thunk.asm");

#pragma pack(push, 1)
typedef struct {
	BYTE load_hook[2];
	Hook *hook;
	BYTE jump_to_entry[6];
	void (*entry)(void);
} HookStub;
#pragma pack(pop)

typedef struct {
	Hook *hook;
	HookFrame *frame;
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

void hook_entry(void);

static Hook *find_hook(INT_PTR target)
{
	int i;

	for (i = 0; i < hook_count; i++) {
		if (hooks[i].target == target)
			return &hooks[i];
	}
	return NULL;
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
	Hook *hook;
	MH_STATUS status;

	if (!is_read_only_code(target))
		luaL_argerror(L, 1, "not an address in read-only executable code");
	if (hook_count == MAX_HOOKS)
		luaL_error(L, "at most %d addresses can be hooked per game session", MAX_HOOKS);
	if (!start_hooking())
		luaL_error(L, "cannot start hooking");
	hook = &hooks[hook_count];
	hook->target = target;
	hook->callback = LUA_NOREF;
	status = MH_CreateHook((LPVOID)target, &stubs[hook_count], &hook->original);
	if (status == MH_OK) {
		status = MH_EnableHook((LPVOID)target);
		if (status != MH_OK)
			MH_RemoveHook((LPVOID)target);
	}
	if (status == MH_ERROR_MEMORY_ALLOC)
		luaL_error(L, "cannot hook %p: no free memory near the game's code for the trampoline", (void *)target);
	if (status != MH_OK)
		luaL_error(L, "cannot hook %p: %s", (void *)target, MH_StatusToString(status));
	hook_count++;
	return hook;
}

static int forget_callbacks(lua_State *L)
{
	int i;

	(void)L;
	for (i = 0; i < hook_count; i++) {
		hooks[i].callback = LUA_NOREF;
		hooks[i].state = NULL;
	}
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
	script_thread = GetCurrentThreadId();
}

static void detach(Hook *hook)
{
	luaL_unref(hook->state, LUA_REGISTRYINDEX, hook->callback);
	luaL_unref(hook->state, LUA_REGISTRYINDEX, hook->thread);
	hook->callback = LUA_NOREF;
	hook->state = NULL;
}

static UINT64 argument_slot(const HookFrame *frame, int index, int type)
{
	if (index >= REGISTER_ARGUMENTS)
		return frame->stack[index - REGISTER_ARGUMENTS];
	return is_float_type(type) ? frame->floats[index] : frame->registers[index];
}

static void store_result(lua_State *L, int type, HookFrame *frame)
{
	UINT64 bits;

	if (type == CALL_VOID)
		return;
	if (lua_isnil(L, -1))
		luaL_error(L, "the callback returned nothing, expected %s", call_type_name(type));
	lua_replace(L, 1);
	bits = argument_bits(L, 1, type);
	if (is_float_type(type))
		frame->float_result = bits;
	else
		frame->result = bits;
}

static int dispatch(lua_State *L)
{
	HookCall *call = lua_touserdata(L, 1);
	const Signature *signature = &call->hook->signature;
	int i;

	luaL_checkstack(L, MAX_ARGUMENTS + EXTRA_STACK_SLOTS, "hook arguments");
	lua_rawgeti(L, LUA_REGISTRYINDEX, call->hook->callback);
	for (i = 0; i < signature->count; i++)
		push_bits(L, signature->arguments[i], argument_slot(call->frame, i, signature->arguments[i]));
	lua_call(L, signature->count, 1);
	store_result(L, signature->result, call->frame);
	return 0;
}

static void keep_error(Hook *hook)
{
	size_t length;
	const char *message = lua_tolstring(hook->state, -1, &length);

	if (!message) {
		message = "the callback raised an error that is not a string";
		length = strlen(message);
	}
	if (length > MAX_ERROR_LENGTH)
		length = MAX_ERROR_LENGTH;
	memcpy(hook->error, message, length);
	hook->error[length] = '\0';
	lua_pop(hook->state, 1);
}

BOOL run_hook(Hook *hook, HookFrame *frame)
{
	HookCall call = { hook, frame };
	int failed;

	frame->original = hook->original;
	if (GetCurrentThreadId() != script_thread || hook->callback == LUA_NOREF || lua_status(hook->state) != 0)
		return FALSE;
	hook->calls++;
	callback_depth++;
	__try {
		failed = lua_cpcall(hook->state, dispatch, &call);
	} __finally {
		callback_depth--;
	}
	if (!failed)
		return TRUE;
	keep_error(hook);
	detach(hook);
	return FALSE;
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
	hook = find_hook(target);
	if (hook && hook->callback != LUA_NOREF)
		return luaL_error(L, "%p is already hooked in this mode; unhook it first", (void *)target);
	if (!hook)
		hook = install_hook(L, target);
	watch_state_close(L);
	hook->signature = signature;
	hook->calls = 0;
	hook->error[0] = '\0';
	hook->state = L;
	lua_pushthread(L);
	hook->thread = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_pushvalue(L, 3);
	hook->callback = luaL_ref(L, LUA_REGISTRYINDEX);
	return 0;
}

static int l_unhook(lua_State *L)
{
	Hook *hook = find_hook(pointer_argument(L, 1));

	if (hook && hook->callback != LUA_NOREF)
		detach(hook);
	return 0;
}

static int l_hook_info(lua_State *L)
{
	Hook *hook = find_hook(pointer_argument(L, 1));

	if (!hook) {
		lua_pushnil(L);
		return 1;
	}
	lua_createtable(L, 0, 4);
	push_value(L, VALUE_POINTER, (INT_PTR)hook->original);
	lua_setfield(L, -2, "original");
	lua_pushboolean(L, hook->callback != LUA_NOREF);
	lua_setfield(L, -2, "attached");
	lua_pushnumber(L, (lua_Number)hook->calls);
	lua_setfield(L, -2, "calls");
	if (hook->error[0]) {
		lua_pushstring(L, hook->error);
		lua_setfield(L, -2, "error");
	}
	return 1;
}

static int l_hook_depth(lua_State *L)
{
	lua_pushnumber(L, callback_depth);
	return 1;
}

const luaL_Reg hook_functions[] = {
	{ "hook", l_hook },
	{ "unhook", l_unhook },
	{ "hook_info", l_hook_info },
	{ "hook_depth", l_hook_depth },
	{ NULL, NULL }
};
