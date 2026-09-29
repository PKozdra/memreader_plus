#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <intrin.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

static int l_test_guard_page(lua_State *L)
{
	char *page = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE | PAGE_GUARD);
	lua_pushlstring(L, (const char *)&page, sizeof page);
	return 1;
}

static int l_test_is_guarded(lua_State *L)
{
	MEMORY_BASIC_INFORMATION page;
	void *address;
	memcpy(&address, luaL_checkstring(L, 1), sizeof address);
	VirtualQuery(address, &page, sizeof page);
	lua_pushboolean(L, (page.Protect & PAGE_GUARD) != 0);
	return 1;
}

static INT64 add_integers(INT64 a, INT32 b, UINT8 c)
{
	return a + b + c;
}

static const char *pointer_plus(const char *p, INT64 n)
{
	return p + n;
}

static float multiply_floats(float a, float b)
{
	return a * b;
}

static double add_doubles(double a, double b)
{
	return a + b;
}

static double mix(INT32 a, float b, double c, const INT32 *d)
{
	return a + b + c + *d;
}

static INT64 eight_digits(INT64 a, INT64 b, INT64 c, INT64 d, INT64 e, INT64 f, INT64 g, INT64 h)
{
	return ((((((a * 10 + b) * 10 + c) * 10 + d) * 10 + e) * 10 + f) * 10 + g) * 10 + h;
}

static double mixed_stack(INT32 a, double b, INT32 c, float d, INT32 e, double f, float g, INT8 h)
{
	return a * 1000000.0 + b * 100000.0 + c * 10000.0 + d * 1000.0 + e * 100.0 + f * 10.0 + g + h * 0.5;
}

static INT64 sixteen(INT64 a1, INT64 a2, INT64 a3, INT64 a4, INT64 a5, INT64 a6, INT64 a7, INT64 a8, INT64 a9,
	INT64 a10, INT64 a11, INT64 a12, INT64 a13, INT64 a14, INT64 a15, INT64 a16)
{
	return a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15 + a16 * 1000;
}

static bool is_positive(INT32 x)
{
	return x > 0;
}

static INT32 from_boolean(bool b)
{
	return b ? 7 : 3;
}

static UINT64 all_bits(void)
{
	return ~(UINT64)0;
}

static void store(INT32 *target, INT32 value)
{
	*target = value;
}

static INT32 read_null(void)
{
	return *(volatile INT32 *)16;
}

static void raise_lua_error(lua_State *L)
{
	luaL_error(L, "raised inside a called function");
}

static INT64 echo_int64(INT64 x)
{
	return x;
}

static UINT64 echo_raw(UINT64 x)
{
	return x;
}

static UINT32 echo_uint8(UINT8 x)
{
	return x;
}

static INT32 divide(INT32 a, INT32 b)
{
	return a / b;
}

static void breakpoint(void)
{
	__debugbreak();
}

static void illegal_instruction(void)
{
	__ud2();
}

static INT32 handle_own_exception(void)
{
	__try {
		RaiseException(0xE0000001, 0, 0, NULL);
	} __except (EXCEPTION_EXECUTE_HANDLER) {
		return 9;
	}
	return 0;
}

static volatile INT64 sink;

static INT64 recurse(INT64 n)
{
	volatile char buffer[4096];
	buffer[0] = (char)n;
	sink = buffer[0];
	return recurse(n + 1) + buffer[0];
}

static INT64 callback(lua_State *L, INT32 reference)
{
	INT64 result;
	lua_rawgeti(L, LUA_REGISTRYINDEX, reference);
	lua_call(L, 0, 1);
	result = (INT64)lua_tonumber(L, -1);
	lua_pop(L, 1);
	return result;
}

static UINT64 stack_misalignment(void)
{
	return ((UINT64)_AddressOfReturnAddress() + 8) & 15;
}

static UINT64 stack_misalignment_5(INT64 a, INT64 b, INT64 c, INT64 d, INT64 e)
{
	(void)a;
	(void)b;
	(void)c;
	(void)d;
	(void)e;
	return ((UINT64)_AddressOfReturnAddress() + 8) & 15;
}

static INT32 hook_target(INT32 a, INT32 b)
{
	return a * 10 + b;
}

static INT64 hook_single(INT64 x)
{
	return x * 3 + 1;
}

static float hook_float(float a, float b)
{
	return a - b;
}

static double hook_mixed(INT64 a, double b, float c, INT32 d, INT8 e, double f)
{
	return a * 100000.0 + b * 10000.0 + c * 1000.0 + d * 100.0 + e * 10.0 + f;
}

static void hook_store(INT32 *target, INT32 value)
{
	*target = value + 1;
}

static INT64 call_directly(INT64 (*function)(INT64), INT64 x)
{
	return function(x) + 0x10000;
}

typedef struct {
	INT64 (*function)(INT64);
	INT64 x;
	INT64 result;
} ThreadCall;

static DWORD WINAPI run_thread_call(void *parameter)
{
	ThreadCall *call = parameter;
	call->result = call->function(call->x);
	return 0;
}

static INT64 call_on_thread(INT64 (*function)(INT64), INT64 x)
{
	ThreadCall call = { function, x, 0 };
	HANDLE thread = CreateThread(NULL, 0, run_thread_call, &call, 0, NULL);
	WaitForSingleObject(thread, INFINITE);
	CloseHandle(thread);
	return call.result;
}

int throw_and_catch(void);
void throw_out(void);

static int format(char *out, size_t size, const char *text, ...)
{
	va_list arguments;
	int length;
	va_start(arguments, text);
	length = vsnprintf(out, size, text, arguments);
	va_end(arguments);
	return length;
}

static const struct {
	const char *name;
	void *function;
} test_functions[] = {
	{ "add_integers", add_integers },
	{ "pointer_plus", pointer_plus },
	{ "multiply_floats", multiply_floats },
	{ "add_doubles", add_doubles },
	{ "mix", mix },
	{ "eight_digits", eight_digits },
	{ "mixed_stack", mixed_stack },
	{ "sixteen", sixteen },
	{ "is_positive", is_positive },
	{ "from_boolean", from_boolean },
	{ "all_bits", all_bits },
	{ "store", store },
	{ "read_null", read_null },
	{ "raise_lua_error", raise_lua_error },
	{ "format", format },
	{ "echo_int64", echo_int64 },
	{ "echo_raw", echo_raw },
	{ "echo_uint8", echo_uint8 },
	{ "divide", divide },
	{ "breakpoint", breakpoint },
	{ "illegal_instruction", illegal_instruction },
	{ "handle_own_exception", handle_own_exception },
	{ "recurse", recurse },
	{ "callback", callback },
	{ "stack_misalignment", stack_misalignment },
	{ "stack_misalignment_5", stack_misalignment_5 },
	{ "throw_and_catch", throw_and_catch },
	{ "throw_out", throw_out },
	{ "hook_target", hook_target },
	{ "hook_single", hook_single },
	{ "hook_float", hook_float },
	{ "hook_mixed", hook_mixed },
	{ "hook_store", hook_store },
	{ "call_directly", call_directly },
	{ "call_on_thread", call_on_thread },
};

static int l_test_function(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	size_t i;
	for (i = 0; i < sizeof test_functions / sizeof test_functions[0]; i++) {
		if (strcmp(test_functions[i].name, name) == 0) {
			lua_pushlstring(L, (const char *)&test_functions[i].function, sizeof(void *));
			return 1;
		}
	}
	return luaL_error(L, "no test function %s", name);
}

static int l_test_crash(lua_State *L)
{
	lua_pushinteger(L, read_null());
	return 1;
}

static int l_test_ref(lua_State *L)
{
	lua_settop(L, 1);
	lua_pushinteger(L, luaL_ref(L, LUA_REGISTRYINDEX));
	return 1;
}

static int l_test_state(lua_State *L)
{
	lua_pushlstring(L, (const char *)&L, sizeof L);
	return 1;
}

static int run_pass(char **argv, int argc, int pass)
{
	lua_State *L = luaL_newstate();
	int next_pass;
	luaL_openlibs(L);
	lua_register(L, "test_guard_page", l_test_guard_page);
	lua_register(L, "test_is_guarded", l_test_is_guarded);
	lua_register(L, "test_function", l_test_function);
	lua_register(L, "test_state", l_test_state);
	lua_register(L, "test_ref", l_test_ref);
	lua_register(L, "test_crash", l_test_crash);
	lua_pushstring(L, argv[2]);
	lua_setglobal(L, "ROOT");
	lua_pushstring(L, argc > 3 ? argv[3] : "");
	lua_setglobal(L, "SCENARIO");
	lua_pushinteger(L, pass);
	lua_setglobal(L, "PASS");
	if (luaL_dofile(L, argv[1])) {
		fprintf(stderr, "%s\n", lua_tostring(L, -1));
		exit(1);
	}
	lua_getglobal(L, "NEXT_PASS");
	next_pass = lua_toboolean(L, -1);
	lua_close(L);
	return next_pass;
}

int main(int argc, char **argv)
{
	int pass = 1;
	if (argc < 3) {
		fprintf(stderr, "usage: lua_host <script.lua> <mod root> [scenario]\n");
		return 2;
	}
	while (run_pass(argv, argc, pass))
		pass++;
	return 0;
}
