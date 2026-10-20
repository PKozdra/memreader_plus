#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <intrin.h>
#include <immintrin.h>
#include <malloc.h>
#include <tlhelp32.h>
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

static volatile LONG exe_data;

#pragma optimize("", off)
static INT32 pattern_target(INT32 a, INT32 b)
{
	return a * 10 + b;
}
#pragma optimize("", on)

static int l_exe_data_address(lua_State *L)
{
	void *address = (void *)&exe_data;

	lua_pushlstring(L, (const char *)&address, sizeof address);
	return 1;
}

static volatile LONG cave_hits;

#pragma optimize("", off)
static INT32 cave_target(INT32 a, INT32 b)
{
	return a * 10 + b;
}
#pragma optimize("", on)

static int l_cave_count(lua_State *L)
{
	lua_pushinteger(L, cave_hits);
	return 1;
}

static int l_cave_count_address(lua_State *L)
{
	void *address = (void *)&cave_hits;

	lua_pushlstring(L, (const char *)&address, sizeof address);
	return 1;
}

static INT64 hook_single(INT64 x)
{
	return x * 3 + 1;
}

static INT64 host_source(void *list, void *source, void *effects, INT32 count, UINT8 flag)
{
	(void)list;
	(void)source;
	(void)effects;
	return (INT64)count * 10 + flag;
}

typedef INT64 (*SourceFunction)(void *, void *, void *, INT32, UINT8);

static BYTE source_block[64];

static int l_test_source_block(lua_State *L)
{
	void *block = source_block;

	lua_pushlstring(L, (const char *)&block, sizeof block);
	return 1;
}

static int l_test_source_loop(lua_State *L)
{
	SourceFunction function;
	LARGE_INTEGER start, end, frequency;
	INT64 sum = 0;
	int calls = (int)luaL_checknumber(L, 2), i;

	memcpy(&function, luaL_checkstring(L, 1), sizeof function);
	QueryPerformanceFrequency(&frequency);
	QueryPerformanceCounter(&start);
	for (i = 0; i < calls; i++)
		sum += function(NULL, source_block, NULL, 3, 5);
	QueryPerformanceCounter(&end);
	lua_pushnumber(L, (lua_Number)((double)(end.QuadPart - start.QuadPart) * 1e9 / (double)frequency.QuadPart / calls));
	lua_pushnumber(L, (lua_Number)sum);
	return 2;
}

static int l_test_reserved(lua_State *L)
{
	void *page = VirtualAlloc(NULL, 4096, MEM_RESERVE, PAGE_NOACCESS);

	lua_pushlstring(L, (const char *)&page, sizeof page);
	return 1;
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
UINT64 leaf_add_one(UINT64 x);
float leaf_add_floats(float a, float b);
void call_keeping_registers(void *leaf, void *registers);
INT64 frame_target(UINT64 *probe);
INT64 frame_twin(UINT64 *probe);
INT64 frame_xmm_target(UINT64 *probe);
INT64 frame_pointer_target(UINT64 *probe);
INT64 frame_call(void *function, UINT64 *probe);
INT64 frame_hooked(UINT64 *probe);
INT32 prologue_target(void);
INT32 parked_target(volatile LONG *flag);
INT32 park_frame(volatile LONG *flag);
INT32 park_grow(volatile LONG *flag);
INT32 park_outer(volatile LONG *flag);
void filler_code(void);
void mixed_code(void);
void hop_leaf_here(void);
void hop_leaf_pad(void);
void asm_double(void);
void asm_float(void);
void asm_float_here(void);
void asm_call(void);
void asm_call_here(void);
void asm_site(void);
void asm_site_here(void);
void asm_site_b(void);
void asm_site_b_here(void);
void asm_site_c(void);
void asm_site_c_here(void);
void asm_site_d(void);
void asm_site_d_here(void);
void asm_site_e(void);
void asm_site_e_here(void);
void asm_site_f(void);
void asm_site_f_here(void);
void asm_site_g(void);
void asm_site_g_here(void);
void asm_site_h(void);
void asm_site_h_here(void);
void asm_site_i(void);
void asm_site_i_here(void);
void asm_site_j(void);
void asm_site_j_here(void);
void asm_site_k(void);
void asm_site_k_here(void);
void many_site_0(void);
void site_target(void);
void site_target_here(void);
void site_far(void);
void site_far_here(void);
void site_overlap(void);
void site_overlap_here(void);
void site_overlap_b(void);
void site_overlap_b_here(void);
void site_flags_target(void);
void site_flags_here(void);
void site_single(void);
void site_single_here(void);
void site_rip_target(void);
void site_rip_here(void);
void site_inbound(void);
void site_inbound_here(void);
void site_ret_here(void);
void site_spin(void);
void site_spin_here(void);
void site_probe(void);
void site_probe_here(void);
void site_xmm_probe(void);
void site_xmm_here(void);
void site_vector_probe(void);
void site_vector_here(void);
void site_crash(void);
void site_crash_here(void);
void site_table(void);
void site_table_here(void);
void site_codetable(void);
void site_noise(void);
void site_noise_here(void);
void site_codetable_here(void);
void site_split(void);
void site_split_cold(void);
void site_split_here(void);
void site_split_free(void);
void site_callee(void);
void site_call_short(void);
void site_call_short_here(void);
void site_call_last(void);
void site_call_last_here(void);
void site_leaf(void);
void site_leaf_here(void);
void site_leaf_mid(void);
void site_leaf_mid_here(void);
void site_leaf_inbound(void);
void site_leaf_inbound_here(void);
void site_early(void);
void site_early_here(void);
void site_tail(void);
void site_tail_here(void);
void dirty_vectors(void);

__declspec(noinline) void host_unwind_probe(UINT64 *probe)
{
	CONTEXT context;
	DWORD64 image;
	PVOID handler_data;
	DWORD64 frame;
	int i;

	RtlCaptureContext(&context);
	for (i = 0; i < 2; i++) {
		PRUNTIME_FUNCTION function = RtlLookupFunctionEntry(context.Rip, &image, NULL);

		if (!function) {
			probe[0] = 0;
			return;
		}
		RtlVirtualUnwind(UNW_FLAG_NHANDLER, image, context.Rip, function, &context, &handler_data, &frame, NULL);
	}
	probe[0] = context.Rip;
	probe[1] = context.Rsp;
	probe[2] = context.Rsi;
	probe[3] = context.Rbx;
	probe[6] = context.Xmm6.Low;
}
int game_crash_handler(DWORD code, EXCEPTION_POINTERS *info);

static HANDLE first_crash_file;
static volatile LONG slow_crash_file;

void write_game_crash_file(void)
{
	SYSTEMTIME now;
	char name[64];
	HANDLE file;
	if (InterlockedExchange(&slow_crash_file, 0)) {
		SetEvent(first_crash_file);
		Sleep(300);
	}
	GetLocalTime(&now);
	snprintf(name, sizeof name, "crash_report\\D%04d-%02d-%02d_T%02d-%02d-%02d.mdmp", now.wYear, now.wMonth, now.wDay,
		now.wHour, now.wMinute, now.wSecond);
	file = CreateFileA(name, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
	if (file != INVALID_HANDLE_VALUE)
		CloseHandle(file);
}

static int format(char *out, size_t size, const char *text, ...)
{
	va_list arguments;
	int length;
	va_start(arguments, text);
	length = vsnprintf(out, size, text, arguments);
	va_end(arguments);
	return length;
}

LONG host_live_blocks(void);
LONG host_open_streams(void);
void host_fail_emplace(LONG count);
int patch_target(void);
void register_file_edit_tests(lua_State *L);
void register_session_tests(lua_State *L);

__declspec(thread) static char host_thread_data[64];

static int l_test_open_streams(lua_State *L)
{
	lua_pushinteger(L, host_open_streams());
	return 1;
}

static int l_test_fail_emplace(lua_State *L)
{
	host_fail_emplace((LONG)luaL_checknumber(L, 1));
	return 0;
}

static int l_test_heap_blocks(lua_State *L)
{
	lua_pushinteger(L, host_live_blocks() + host_thread_data[0]);
	return 1;
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
	{ "host_source", host_source },
	{ "hook_float", hook_float },
	{ "hook_mixed", hook_mixed },
	{ "hook_store", hook_store },
	{ "call_directly", call_directly },
	{ "call_on_thread", call_on_thread },
	{ "leaf_add_one", leaf_add_one },
	{ "leaf_add_floats", leaf_add_floats },
	{ "call_keeping_registers", call_keeping_registers },
	{ "patch_target", patch_target },
	{ "pattern_target", pattern_target },
	{ "frame_target", frame_target },
	{ "frame_twin", frame_twin },
	{ "frame_xmm_target", frame_xmm_target },
	{ "frame_pointer_target", frame_pointer_target },
	{ "frame_call", frame_call },
	{ "frame_hooked", frame_hooked },
	{ "prologue_target", prologue_target },
	{ "parked_target", parked_target },
	{ "park_frame", park_frame },
	{ "park_grow", park_grow },
	{ "park_outer", park_outer },
	{ "filler_code", filler_code },
	{ "mixed_code", mixed_code },
	{ "hop_leaf_here", hop_leaf_here },
	{ "hop_leaf_pad", hop_leaf_pad },
	{ "cave_target", cave_target },
	{ "asm_double", asm_double },
	{ "asm_float", asm_float },
	{ "asm_float_here", asm_float_here },
	{ "asm_call", asm_call },
	{ "asm_call_here", asm_call_here },
	{ "asm_site", asm_site },
	{ "asm_site_here", asm_site_here },
	{ "asm_site_b", asm_site_b },
	{ "asm_site_b_here", asm_site_b_here },
	{ "asm_site_c", asm_site_c },
	{ "asm_site_c_here", asm_site_c_here },
	{ "asm_site_d", asm_site_d },
	{ "asm_site_d_here", asm_site_d_here },
	{ "asm_site_e", asm_site_e },
	{ "asm_site_e_here", asm_site_e_here },
	{ "asm_site_f", asm_site_f },
	{ "asm_site_f_here", asm_site_f_here },
	{ "asm_site_g", asm_site_g },
	{ "asm_site_g_here", asm_site_g_here },
	{ "asm_site_h", asm_site_h },
	{ "asm_site_h_here", asm_site_h_here },
	{ "asm_site_i", asm_site_i },
	{ "asm_site_i_here", asm_site_i_here },
	{ "asm_site_j", asm_site_j },
	{ "asm_site_j_here", asm_site_j_here },
	{ "asm_site_k", asm_site_k },
	{ "asm_site_k_here", asm_site_k_here },
	{ "many_site_0", many_site_0 },
	{ "site_target", site_target },
	{ "site_target_here", site_target_here },
	{ "site_far", site_far },
	{ "site_far_here", site_far_here },
	{ "site_overlap", site_overlap },
	{ "site_overlap_here", site_overlap_here },
	{ "site_overlap_b", site_overlap_b },
	{ "site_overlap_b_here", site_overlap_b_here },
	{ "site_flags_target", site_flags_target },
	{ "site_flags_here", site_flags_here },
	{ "site_single", site_single },
	{ "site_single_here", site_single_here },
	{ "site_rip_target", site_rip_target },
	{ "site_rip_here", site_rip_here },
	{ "site_inbound", site_inbound },
	{ "site_inbound_here", site_inbound_here },
	{ "site_ret_here", site_ret_here },
	{ "site_spin", site_spin },
	{ "site_spin_here", site_spin_here },
	{ "site_probe", site_probe },
	{ "site_probe_here", site_probe_here },
	{ "site_xmm_probe", site_xmm_probe },
	{ "site_xmm_here", site_xmm_here },
	{ "site_vector_probe", site_vector_probe },
	{ "site_vector_here", site_vector_here },
	{ "site_crash", site_crash },
	{ "site_crash_here", site_crash_here },
	{ "site_table", site_table },
	{ "site_table_here", site_table_here },
	{ "site_codetable", site_codetable },
	{ "site_noise", site_noise },
	{ "site_noise_here", site_noise_here },
	{ "site_codetable_here", site_codetable_here },
	{ "site_split", site_split },
	{ "site_split_here", site_split_here },
	{ "site_split_free", site_split_free },
	{ "site_callee", site_callee },
	{ "site_call_short", site_call_short },
	{ "site_call_short_here", site_call_short_here },
	{ "site_call_last", site_call_last },
	{ "site_call_last_here", site_call_last_here },
	{ "site_leaf", site_leaf },
	{ "site_leaf_here", site_leaf_here },
	{ "site_leaf_mid", site_leaf_mid },
	{ "site_leaf_mid_here", site_leaf_mid_here },
	{ "site_leaf_inbound", site_leaf_inbound },
	{ "site_leaf_inbound_here", site_leaf_inbound_here },
	{ "site_early", site_early },
	{ "site_early_here", site_early_here },
	{ "site_tail", site_tail },
	{ "site_tail_here", site_tail_here },
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

int l_test_catch_site_call(lua_State *L);

static int l_test_recovered_crash(lua_State *L)
{
	__try {
		read_null();
	} __except (EXCEPTION_EXECUTE_HANDLER) {
	}
	return 0;
}

static int l_test_execute_crash(lua_State *L)
{
	BYTE *page = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
	page[0] = 0xC3;
	((void (*)(void))page)();
	return 0;
}

static int l_test_run(lua_State *L)
{
	INT32 (*function)(INT32, INT32);

	memcpy(&function, luaL_checkstring(L, 1), sizeof function);
	lua_pushinteger(L, function((INT32)luaL_checkinteger(L, 2), (INT32)luaL_checkinteger(L, 3)));
	return 1;
}

void fake_dlfree(void *chunk);

static int l_test_allocator_crash(lua_State *L)
{
	static const WCHAR words[] = L"a tooltip text overwrote this chunk";
	BYTE *chunk = (BYTE *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, 768) + 256;

	memcpy(chunk + 0x20, words, sizeof words);
	fake_dlfree(chunk + 0x10);
	return 0;
}

static ULONG_PTR *exe_import_slot(const char *dll, const char *name)
{
	BYTE *image = (BYTE *)GetModuleHandleW(NULL);
	IMAGE_NT_HEADERS *headers = (IMAGE_NT_HEADERS *)(image + ((IMAGE_DOS_HEADER *)image)->e_lfanew);
	IMAGE_DATA_DIRECTORY *directory = &headers->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
	IMAGE_IMPORT_DESCRIPTOR *entry = (IMAGE_IMPORT_DESCRIPTOR *)(image + directory->VirtualAddress);
	IMAGE_THUNK_DATA *names;
	int i;

	for (; entry->Name; entry++) {
		if (_stricmp((char *)(image + entry->Name), dll) != 0)
			continue;
		names = (IMAGE_THUNK_DATA *)(image + entry->OriginalFirstThunk);
		for (i = 0; names[i].u1.AddressOfData; i++) {
			if (!IMAGE_SNAP_BY_ORDINAL(names[i].u1.Ordinal) &&
				strcmp(((IMAGE_IMPORT_BY_NAME *)(image + names[i].u1.AddressOfData))->Name, name) == 0)
				return (ULONG_PTR *)(image + entry->FirstThunk) + i;
		}
	}
	return NULL;
}

static void write_code(void *at, const void *bytes, size_t size)
{
	DWORD old;

	VirtualProtect(at, size, PAGE_EXECUTE_READWRITE, &old);
	memcpy(at, bytes, size);
	VirtualProtect(at, size, old, &old);
}

static int l_test_hook_timing(lua_State *L)
{
	ULONG_PTR into = (ULONG_PTR)GetModuleHandleA(luaL_checkstring(L, 1)) + 0x1000;
	ULONG_PTR *slot = exe_import_slot("KERNEL32.dll", "QueryPerformanceCounter");
	BYTE jump[14] = { 0xFF, 0x25, 0, 0, 0, 0 };
	FARPROC time_function = GetProcAddress(LoadLibraryA("winmm.dll"), "timeGetTime");

	memcpy(jump + 6, &into, sizeof into);
	if (slot)
		write_code(slot, &into, sizeof into);
	if (time_function)
		write_code((void *)time_function, jump, sizeof jump);
	lua_pushboolean(L, slot != NULL && time_function != NULL);
	return 1;
}

static DWORD WINAPI crash_thread(LPVOID unused)
{
	(void)unused;
	return (DWORD)read_null();
}

static int l_test_thread_crash(lua_State *L)
{
	HANDLE thread = CreateThread(NULL, 0, crash_thread, NULL, 0, NULL);
	WaitForSingleObject(thread, INFINITE);
	return 0;
}

static int overflow(volatile int depth)
{
	volatile char padding[4096];
	padding[0] = (char)depth;
	if (depth < 0)
		return 0;
	return overflow(depth + 1) + padding[0];
}

static int l_test_stack_overflow(lua_State *L)
{
	lua_pushinteger(L, overflow(0));
	return 1;
}

static bool second_fault;

static void fault_av(void)
{
	read_null();
}

static void fault_overflow(void)
{
	overflow(0);
}

static void fault_fastfail(void)
{
	__fastfail(FAST_FAIL_FATAL_APP_EXIT);
}

static void fault_abort(void)
{
	abort();
}

static void fault_cpp(void)
{
	RaiseException(0xE06D7363, EXCEPTION_NONCONTINUABLE, 0, NULL);
}

static void fault_heap_double_free(void)
{
	HANDLE heap = GetProcessHeap();
	void *block = HeapAlloc(heap, 0, 512);

	HeapFree(heap, 0, block);
	HeapFree(heap, 0, block);
}

static void fault_heap_overrun(void)
{
	HANDLE heap = GetProcessHeap();
	char *first = HeapAlloc(heap, 0, 512);
	char *second = HeapAlloc(heap, 0, 512);

	memset(first, 0xAA, 512 + 64);
	HeapFree(heap, 0, second);
	HeapFree(heap, 0, first);
}

static void fault_exit_process(void)
{
	ExitProcess(7);
}

static void fault_terminate_process(void)
{
	TerminateProcess(GetCurrentProcess(), 8);
}

static void fault_crt_exit(void)
{
	exit(9);
}

static INT32 (*volatile divider)(INT32, INT32) = divide;

static void fault_divide(void)
{
	divider(1, 0);
}

static void fault_ud2(void)
{
	__ud2();
}

static void fault_second(void)
{
	second_fault = true;
	fault_divide();
}

static void fault_worker_stuck(void)
{
	THREADENTRY32 entry = { sizeof entry };
	HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
	DWORD self = GetCurrentThreadId();
	HANDLE thread;

	for (BOOL more = Thread32First(snapshot, &entry); more; more = Thread32Next(snapshot, &entry)) {
		if (entry.th32OwnerProcessID != GetCurrentProcessId() || entry.th32ThreadID == self)
			continue;
		thread = OpenThread(THREAD_SUSPEND_RESUME, FALSE, entry.th32ThreadID);
		if (thread)
			SuspendThread(thread);
	}
	CloseHandle(snapshot);
	read_null();
}

static HANDLE start_both;

static DWORD WINAPI wait_then_fault_now(LPVOID unused)
{
	(void)unused;
	return (DWORD)read_null();
}

static DWORD WINAPI wait_then_fault(LPVOID unused)
{
	(void)unused;
	WaitForSingleObject(start_both, INFINITE);
	return (DWORD)read_null();
}

static void fault_two_threads(void)
{
	HANDLE threads[2];

	start_both = CreateEventW(NULL, TRUE, FALSE, NULL);
	threads[0] = CreateThread(NULL, 0, wait_then_fault, NULL, 0, NULL);
	threads[1] = CreateThread(NULL, 0, wait_then_fault, NULL, 0, NULL);
	Sleep(200);
	SetEvent(start_both);
	WaitForMultipleObjects(2, threads, TRUE, INFINITE);
}

static DWORD WINAPI fault_after_first_crash_file(LPVOID unused)
{
	(void)unused;
	WaitForSingleObject(first_crash_file, INFINITE);
	return (DWORD)read_null();
}

static void fault_overlap(void)
{
	HANDLE threads[2];

	first_crash_file = CreateEventW(NULL, TRUE, FALSE, NULL);
	slow_crash_file = 1;
	threads[0] = CreateThread(NULL, 0, wait_then_fault_now, NULL, 0, NULL);
	threads[1] = CreateThread(NULL, 0, fault_after_first_crash_file, NULL, 0, NULL);
	WaitForMultipleObjects(2, threads, TRUE, INFINITE);
}

static volatile LONG spin_count;

static PRUNTIME_FUNCTION CALLBACK stall_lookup(DWORD64 pc, PVOID forever)
{
	LONG seen = spin_count;

	(void)pc;
	if (forever)
		Sleep(INFINITE);
	while (spin_count == seen)
		Sleep(10);
	return NULL;
}

static DWORD WINAPI fault_soon(LPVOID unused)
{
	(void)unused;
	Sleep(200);
	return (DWORD)read_null();
}

static void spin_while_another_thread_faults(bool forever)
{
	static const BYTE spin[] = { 0xF0, 0xFF, 0x01, 0xF3, 0x90, 0xEB, 0xF9 };
	BYTE *code = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);

	memcpy(code, spin, sizeof spin);
	RtlInstallFunctionTableCallback((DWORD64)code | 3, (DWORD64)code, 4096, stall_lookup, forever ? (PVOID)1 : NULL, NULL);
	CloseHandle(CreateThread(NULL, 0, fault_soon, NULL, 0, NULL));
	((void (*)(volatile LONG *))code)(&spin_count);
}

static void fault_worker_waits(void)
{
	spin_while_another_thread_faults(false);
}

static void fault_worker_blocked(void)
{
	spin_while_another_thread_faults(true);
}

static ULONG_PTR plus_start;
static ULONG_PTR plus_end;

static void find_plus(lua_State *L, int index)
{
	lua_CFunction function = lua_tocfunction(L, index);
	HMODULE module;
	IMAGE_NT_HEADERS *headers;

	if (!function || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
			(LPCWSTR)(void *)function, &module))
		luaL_error(L, "test_fault needs a function of memreader Plus");
	headers = (IMAGE_NT_HEADERS *)((BYTE *)module + ((IMAGE_DOS_HEADER *)module)->e_lfanew);
	plus_start = (ULONG_PTR)module;
	plus_end = plus_start + headers->OptionalHeader.SizeOfImage;
}

typedef LONG (NTAPI *QueryThread)(HANDLE thread, int what, PVOID out, ULONG size, PULONG used);

static HANDLE open_plus_worker(void)
{
	QueryThread query = (QueryThread)(void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationThread");
	THREADENTRY32 entry = { sizeof entry };
	HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
	HANDLE found = NULL;
	ULONG_PTR start;
	HANDLE thread;

	for (BOOL more = Thread32First(snapshot, &entry); more && !found; more = Thread32Next(snapshot, &entry)) {
		if (entry.th32OwnerProcessID != GetCurrentProcessId())
			continue;
		thread = OpenThread(THREAD_QUERY_INFORMATION | THREAD_TERMINATE | SYNCHRONIZE, FALSE, entry.th32ThreadID);
		start = 0;
		if (thread && query(thread, 9, &start, sizeof start, NULL) == 0 && start >= plus_start && start < plus_end)
			found = thread;
		else if (thread)
			CloseHandle(thread);
	}
	CloseHandle(snapshot);
	return found;
}

static void fault_worker_dead(void)
{
	HANDLE worker = open_plus_worker();

	TerminateThread(worker, 0);
	WaitForSingleObject(worker, INFINITE);
	read_null();
}

static BOOL (WINAPI *real_move)(LPCSTR from, LPCSTR to, DWORD flags);
static volatile LONG move_refusals;
static volatile LONG move_calls;

static BOOL WINAPI refusing_move(LPCSTR from, LPCSTR to, DWORD flags)
{
	InterlockedIncrement(&move_calls);
	if (InterlockedDecrement(&move_refusals) >= 0) {
		SetLastError(ERROR_SHARING_VIOLATION);
		return FALSE;
	}
	return real_move(from, to, flags);
}

static void replace_plus_import(const char *name, void *replacement, void **original)
{
	BYTE *base = (BYTE *)plus_start;
	IMAGE_NT_HEADERS *headers = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
	DWORD imports = headers->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
	IMAGE_THUNK_DATA *names, *slots;
	DWORD old;

	for (IMAGE_IMPORT_DESCRIPTOR *library = (IMAGE_IMPORT_DESCRIPTOR *)(base + imports); library->Name; library++) {
		names = (IMAGE_THUNK_DATA *)(base + library->OriginalFirstThunk);
		slots = (IMAGE_THUNK_DATA *)(base + library->FirstThunk);
		for (; names->u1.AddressOfData; names++, slots++) {
			if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal) || strcmp(((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name, name) != 0)
				continue;
			VirtualProtect(&slots->u1.Function, sizeof slots->u1.Function, PAGE_READWRITE, &old);
			*original = (void *)slots->u1.Function;
			slots->u1.Function = (ULONG_PTR)replacement;
			VirtualProtect(&slots->u1.Function, sizeof slots->u1.Function, old, &old);
		}
	}
}

static void fault_after_move_refusals(LONG refusals)
{
	move_refusals = refusals;
	replace_plus_import("MoveFileExA", (void *)refusing_move, (void **)&real_move);
	read_null();
}

static void fault_move_retry(void)
{
	fault_after_move_refusals(3);
}

static void fault_move_fails(void)
{
	fault_after_move_refusals(1000);
}

static DWORD WINAPI no_module_file_name(HMODULE module, LPSTR name, DWORD size)
{
	(void)module;
	(void)name;
	(void)size;
	return 0;
}

static void fault_no_report_folder(void)
{
	void *original = NULL;

	replace_plus_import("GetModuleFileNameA", (void *)no_module_file_name, &original);
}

static void write_move_calls(void)
{
	FILE *file;

	if (!move_calls || fopen_s(&file, "move_calls.txt", "w"))
		return;
	fprintf(file, "%ld", move_calls);
	fclose(file);
}

static volatile LONG park_flag;
static HANDLE park_thread;
static void (WINAPI *real_system_info)(LPSYSTEM_INFO info);

static DWORD WINAPI run_parked(void *function)
{
	return (DWORD)((INT32 (*)(volatile LONG *))function)(&park_flag);
}

static BOOL park_rip(DWORD64 *rip)
{
	CONTEXT context = { 0 };
	BOOL found;

	context.ContextFlags = CONTEXT_CONTROL;
	if (SuspendThread(park_thread) == (DWORD)-1)
		return FALSE;
	found = GetThreadContext(park_thread, &context);
	ResumeThread(park_thread);
	*rip = context.Rip;
	return found;
}

static int l_test_park_start(lua_State *L)
{
	DWORD64 function, rip = 0;
	int tries;
	DWORD64 span = (DWORD64)luaL_optinteger(L, 2, 16);

	memcpy(&function, luaL_checkstring(L, 1), sizeof function);
	park_flag = 0;
	park_thread = CreateThread(NULL, 0, run_parked, (void *)function, 0, NULL);
	for (tries = 0; tries < 200; tries++) {
		Sleep(10);
		if (park_rip(&rip) && rip >= function && rip < function + span) {
			lua_pushboolean(L, 1);
			return 1;
		}
	}
	lua_pushboolean(L, 0);
	return 1;
}

static int l_test_park_rip(lua_State *L)
{
	DWORD64 rip = 0;

	if (!park_rip(&rip))
		return 0;
	lua_pushlstring(L, (const char *)&rip, sizeof rip);
	return 1;
}

static int l_test_park_flag(lua_State *L)
{
	void *address = (void *)&park_flag;

	lua_pushlstring(L, (const char *)&address, sizeof address);
	return 1;
}

static int l_test_park_finish(lua_State *L)
{
	DWORD result = 0;
	BOOL finished;

	park_flag = 1;
	finished = WaitForSingleObject(park_thread, 5000) == WAIT_OBJECT_0;
	if (finished)
		GetExitCodeThread(park_thread, &result);
	else
		TerminateThread(park_thread, 0);
	CloseHandle(park_thread);
	if (!finished)
		return 0;
	lua_pushinteger(L, result);
	return 1;
}

static void (WINAPI *real_sleep)(DWORD milliseconds);
static volatile LONG leave_thread;
static volatile LONG left_in_retry;

static void WINAPI leaving_sleep(DWORD milliseconds)
{
	if (leave_thread && GetCurrentThreadId() == (DWORD)leave_thread) {
		leave_thread = 0;
		park_flag = 1;
		left_in_retry = WaitForSingleObject(park_thread, 5000) == WAIT_OBJECT_0;
	}
	real_sleep(milliseconds);
}

static int l_test_park_leave_on_retry(lua_State *L)
{
	find_plus(L, 1);
	if (!real_sleep)
		replace_plus_import("Sleep", (void *)leaving_sleep, (void **)&real_sleep);
	left_in_retry = 0;
	leave_thread = (LONG)GetCurrentThreadId();
	return 0;
}

static int l_test_park_left(lua_State *L)
{
	lua_pushboolean(L, left_in_retry);
	left_in_retry = 0;
	return 1;
}

static BOOL (WINAPI *real_protect)(LPVOID address, SIZE_T size, DWORD protection, PDWORD old);
static LPVOID (WINAPI *real_alloc)(LPVOID address, SIZE_T size, DWORD type, DWORD protection);
static volatile ULONG_PTR refused_page;
static volatile LONG protect_refusals;
static volatile LONG protect_skips;
static volatile LONG restore_refusals;
static volatile SIZE_T refused_size;

static volatile ULONG_PTR counted_page;
static volatile LONG counted_calls;
static volatile ULONG_PTR relock_page;
static volatile ULONG_PTR lie_page;
static volatile ULONG_PTR also_page;
static SIZE_T (WINAPI *real_query)(LPCVOID address, PMEMORY_BASIC_INFORMATION info, SIZE_T size);
static PVOID relock_handler;

static ULONG_PTR page_start(const void *address)
{
	return (ULONG_PTR)address & ~(ULONG_PTR)0xFFF;
}

static BOOL WINAPI refusing_protect(LPVOID address, SIZE_T size, DWORD protection, PDWORD old)
{
	BOOL done;
	DWORD unused;

	if (page_start(address) == counted_page)
		InterlockedIncrement(&counted_calls);
	if ((ULONG_PTR)address == refused_page && !(protection & (PAGE_READWRITE | PAGE_EXECUTE_READWRITE)) && InterlockedDecrement(&restore_refusals) >= 0) {
		SetLastError(ERROR_ACCESS_DENIED);
		return FALSE;
	}
	if ((ULONG_PTR)address == refused_page && (protection & (PAGE_READWRITE | PAGE_EXECUTE_READWRITE))) {
		if (protect_skips > 0)
			InterlockedDecrement(&protect_skips);
		else if (InterlockedDecrement(&protect_refusals) >= 0) {
			SetLastError(ERROR_ACCESS_DENIED);
			return FALSE;
		}
	}
	done = real_protect(address, size, protection, old);
	if (done && relock_page && page_start(address) == relock_page && (protection & (PAGE_READWRITE | PAGE_EXECUTE_READWRITE))) {
		relock_page = 0;
		real_protect(address, size, *old, &unused);
	}
	return done;
}

static SIZE_T WINAPI lying_query(LPCVOID address, PMEMORY_BASIC_INFORMATION info, SIZE_T size)
{
	SIZE_T result = real_query(address, info, size);

	if (result && lie_page && page_start(address) == lie_page)
		info->Protect = PAGE_EXECUTE_READWRITE;
	return result;
}

static LONG CALLBACK relock_on_fault(EXCEPTION_POINTERS *exception)
{
	const EXCEPTION_RECORD *record = exception->ExceptionRecord;
	DWORD unused;

	if (record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && lie_page && page_start((void *)record->ExceptionInformation[1]) == lie_page) {
		lie_page = 0;
		real_protect((LPVOID)also_page, 0x1000, PAGE_EXECUTE_READ, &unused);
	}
	return EXCEPTION_CONTINUE_SEARCH;
}

static LPVOID WINAPI refusing_alloc(LPVOID address, SIZE_T size, DWORD type, DWORD protection)
{
	if (refused_size && size == refused_size && protection == PAGE_EXECUTE_READWRITE) {
		refused_size = 0;
		SetLastError(ERROR_NOT_ENOUGH_MEMORY);
		return NULL;
	}
	return real_alloc(address, size, type, protection);
}

static int l_test_fail_protect(lua_State *L)
{
	void *address;

	memcpy(&address, luaL_checkstring(L, 1), sizeof address);
	find_plus(L, 3);
	if (!real_protect)
		replace_plus_import("VirtualProtect", (void *)refusing_protect, (void **)&real_protect);
	refused_page = (ULONG_PTR)address & ~(ULONG_PTR)0xFFF;
	protect_refusals = (LONG)luaL_checkinteger(L, 2);
	protect_skips = (LONG)luaL_optinteger(L, 4, 0);
	return 0;
}

static int l_test_fail_restore(lua_State *L)
{
	void *address;

	memcpy(&address, luaL_checkstring(L, 1), sizeof address);
	find_plus(L, 2);
	if (!real_protect)
		replace_plus_import("VirtualProtect", (void *)refusing_protect, (void **)&real_protect);
	refused_page = (ULONG_PTR)address & ~(ULONG_PTR)0xFFF;
	protect_refusals = 0;
	restore_refusals = 1;
	return 0;
}

static int l_test_relock(lua_State *L)
{
	void *address, *also = NULL;

	memcpy(&address, luaL_checkstring(L, 1), sizeof address);
	if (!lua_isnoneornil(L, 3))
		memcpy(&also, luaL_checkstring(L, 3), sizeof also);
	find_plus(L, 2);
	if (!real_protect)
		replace_plus_import("VirtualProtect", (void *)refusing_protect, (void **)&real_protect);
	if (!real_query)
		replace_plus_import("VirtualQuery", (void *)lying_query, (void **)&real_query);
	if (!relock_handler)
		relock_handler = AddVectoredExceptionHandler(1, relock_on_fault);
	relock_page = page_start(address);
	also_page = page_start(also);
	lie_page = also ? relock_page : 0;
	return 0;
}

static int l_test_count_protect(lua_State *L)
{
	void *address;

	memcpy(&address, luaL_checkstring(L, 1), sizeof address);
	find_plus(L, 2);
	if (!real_protect)
		replace_plus_import("VirtualProtect", (void *)refusing_protect, (void **)&real_protect);
	counted_page = page_start(address);
	counted_calls = 0;
	return 0;
}

static int l_test_protect_count(lua_State *L)
{
	lua_pushinteger(L, counted_calls);
	return 1;
}

static DWORD (WINAPI *real_suspend)(HANDLE thread);
static FARPROC (WINAPI *real_get_proc)(HMODULE module, LPCSTR name);
static volatile LONG suspend_calls;
static ULONG_PTR suspend_page;
static DWORD suspend_protection;
static volatile LONG spawn_at;
static volatile LONG next_thread_denied;
static void *change_address;
static BYTE change_bytes[16];
static size_t change_size;
static HANDLE spawn_event;

static DWORD WINAPI wait_for_spawn_event(void *unused)
{
	(void)unused;
	WaitForSingleObject(spawn_event, INFINITE);
	return 0;
}

static void change_code_now(void)
{
	DWORD old, unused;

	VirtualProtect(change_address, change_size, PAGE_EXECUTE_READWRITE, &old);
	memcpy(change_address, change_bytes, change_size);
	VirtualProtect(change_address, change_size, old, &unused);
	change_size = 0;
}

static DWORD protection_now(ULONG_PTR page)
{
	MEMORY_BASIC_INFORMATION region;

	return page && VirtualQuery((LPCVOID)page, &region, sizeof region) ? region.Protect : 0;
}

static DWORD WINAPI watching_suspend(HANDLE thread)
{
	LONG number = InterlockedIncrement(&suspend_calls);

	if (number == 1)
		suspend_protection = protection_now(suspend_page);
	if (change_size)
		change_code_now();
	if (spawn_at && number == spawn_at) {
		spawn_at = 0;
		CloseHandle(CreateThread(NULL, 0, wait_for_spawn_event, NULL, 0, NULL));
	}
	return real_suspend(thread);
}

static FARPROC WINAPI denying_get_proc(HMODULE module, LPCSTR name)
{
	if (next_thread_denied && (ULONG_PTR)name > 0xFFFF && strcmp(name, "NtGetNextThread") == 0)
		return NULL;
	return real_get_proc(module, name);
}

static int l_test_watch_suspend(lua_State *L)
{
	void *page = NULL;

	find_plus(L, 1);
	if (!lua_isnoneornil(L, 2))
		memcpy(&page, luaL_checkstring(L, 2), sizeof page);
	suspend_page = page_start(page);
	suspend_protection = 0;
	if (!real_suspend)
		replace_plus_import("SuspendThread", (void *)watching_suspend, (void **)&real_suspend);
	if (!spawn_event)
		spawn_event = CreateEventW(NULL, TRUE, FALSE, NULL);
	suspend_calls = 0;
	return 0;
}

static int l_test_suspend_calls(lua_State *L)
{
	lua_pushnumber(L, (lua_Number)suspend_calls);
	lua_pushnumber(L, (lua_Number)suspend_protection);
	return 2;
}

static int l_test_spawn_on_suspend(lua_State *L)
{
	ResetEvent(spawn_event);
	spawn_at = (LONG)luaL_checkinteger(L, 1);
	return 0;
}

static int l_test_end_spawned(lua_State *L)
{
	(void)L;
	SetEvent(spawn_event);
	return 0;
}

static int l_test_change_on_suspend(lua_State *L)
{
	size_t size;
	const char *bytes = luaL_checklstring(L, 2, &size);

	memcpy(&change_address, luaL_checkstring(L, 1), sizeof change_address);
	memcpy(change_bytes, bytes, size);
	change_size = size;
	return 0;
}

static int l_test_deny_next_thread(lua_State *L)
{
	find_plus(L, 2);
	if (!real_get_proc)
		replace_plus_import("GetProcAddress", (void *)denying_get_proc, (void **)&real_get_proc);
	next_thread_denied = lua_toboolean(L, 1);
	return 0;
}

static HANDLE (WINAPI *real_snapshot)(DWORD flags, DWORD process);
static volatile LONG snapshot_denied;

static HANDLE WINAPI denying_snapshot(DWORD flags, DWORD process)
{
	if (snapshot_denied) {
		SetLastError(ERROR_ACCESS_DENIED);
		return INVALID_HANDLE_VALUE;
	}
	return real_snapshot(flags, process);
}

static int l_test_deny_snapshot(lua_State *L)
{
	find_plus(L, 2);
	if (!real_snapshot)
		replace_plus_import("CreateToolhelp32Snapshot", (void *)denying_snapshot, (void **)&real_snapshot);
	snapshot_denied = lua_toboolean(L, 1);
	return 0;
}

static BOOL (WINAPI *real_context)(HANDLE thread, LPCONTEXT context);
static volatile LONG context_failures;

static BOOL WINAPI failing_context(HANDLE thread, LPCONTEXT context)
{
	if (InterlockedDecrement(&context_failures) >= 0) {
		SetLastError(ERROR_ACCESS_DENIED);
		return FALSE;
	}
	return real_context(thread, context);
}

static int l_test_fail_context(lua_State *L)
{
	find_plus(L, 2);
	if (!real_context)
		replace_plus_import("GetThreadContext", (void *)failing_context, (void **)&real_context);
	context_failures = (LONG)luaL_checkinteger(L, 1);
	return 0;
}

static int l_test_fail_alloc(lua_State *L)
{
	find_plus(L, 2);
	if (!real_alloc)
		replace_plus_import("VirtualAlloc", (void *)refusing_alloc, (void **)&real_alloc);
	refused_size = (SIZE_T)luaL_checkinteger(L, 1);
	return 0;
}

static LPVOID (WINAPI *plain_virtual_alloc)(LPVOID address, SIZE_T size, DWORD type, DWORD protection);
static LPVOID (WINAPI *plain_heap_alloc)(HANDLE heap, DWORD flags, SIZE_T size);
static LPVOID (WINAPI *plain_heap_realloc)(HANDLE heap, DWORD flags, LPVOID block, SIZE_T size);
static DWORD (WINAPI *plain_suspend)(HANDLE thread);
static DWORD (WINAPI *plain_resume)(HANDLE thread);
static volatile LONG refuse_virtual;
static volatile LONG refuse_heap;
static volatile LONG refuse_private_heap;
static volatile LONG threads_held;
static volatile LONG window_allocations;
static volatile LONG window_suspends;

static void note_allocation(void)
{
	if (threads_held > 0)
		InterlockedIncrement(&window_allocations);
}

static BOOL take_refusal(volatile LONG *counter)
{
	if (*counter <= 0)
		return FALSE;
	InterlockedDecrement(counter);
	SetLastError(ERROR_NOT_ENOUGH_MEMORY);
	return TRUE;
}

static LPVOID WINAPI watched_virtual_alloc(LPVOID address, SIZE_T size, DWORD type, DWORD protection)
{
	note_allocation();
	return take_refusal(&refuse_virtual) ? NULL : plain_virtual_alloc(address, size, type, protection);
}

static LPVOID WINAPI watched_heap_alloc(HANDLE heap, DWORD flags, SIZE_T size)
{
	note_allocation();
	if (heap != GetProcessHeap() && take_refusal(&refuse_private_heap))
		return NULL;
	return take_refusal(&refuse_heap) ? NULL : plain_heap_alloc(heap, flags, size);
}

static LPVOID WINAPI watched_heap_realloc(HANDLE heap, DWORD flags, LPVOID block, SIZE_T size)
{
	note_allocation();
	return take_refusal(&refuse_heap) ? NULL : plain_heap_realloc(heap, flags, block, size);
}

static DWORD WINAPI watched_window_suspend(HANDLE thread)
{
	DWORD result = plain_suspend(thread);

	if (result != (DWORD)-1) {
		InterlockedIncrement(&threads_held);
		InterlockedIncrement(&window_suspends);
	}
	return result;
}

static DWORD WINAPI watched_window_resume(HANDLE thread)
{
	DWORD result = plain_resume(thread);

	if (result != (DWORD)-1 && threads_held > 0)
		InterlockedDecrement(&threads_held);
	return result;
}

static void watch_memory(lua_State *L, int index)
{
	find_plus(L, index);
	if (plain_virtual_alloc)
		return;
	replace_plus_import("VirtualAlloc", (void *)watched_virtual_alloc, (void **)&plain_virtual_alloc);
	replace_plus_import("HeapAlloc", (void *)watched_heap_alloc, (void **)&plain_heap_alloc);
	replace_plus_import("HeapReAlloc", (void *)watched_heap_realloc, (void **)&plain_heap_realloc);
	replace_plus_import("SuspendThread", (void *)watched_window_suspend, (void **)&plain_suspend);
	replace_plus_import("ResumeThread", (void *)watched_window_resume, (void **)&plain_resume);
}

static int l_test_fail_memory(lua_State *L)
{
	const char *kind = luaL_checkstring(L, 1);

	watch_memory(L, 2);
	if (strcmp(kind, "virtual") == 0)
		refuse_virtual = 1;
	else if (strcmp(kind, "heap") == 0)
		refuse_heap = 1;
	else if (strcmp(kind, "private_heap") == 0)
		refuse_private_heap = 1;
	else
		luaL_argerror(L, 1, "virtual, heap or private_heap");
	return 0;
}

static int l_test_watch_window(lua_State *L)
{
	watch_memory(L, 1);
	threads_held = 0;
	window_allocations = 0;
	window_suspends = 0;
	return 0;
}

static int l_test_window_counts(lua_State *L)
{
	lua_pushnumber(L, (lua_Number)window_allocations);
	lua_pushnumber(L, (lua_Number)window_suspends);
	lua_pushnumber(L, (lua_Number)(refuse_virtual + refuse_heap + refuse_private_heap));
	return 3;
}

static lua_CFunction report_function;
static HANDLE report_thread;
static volatile LONG report_stop;
static int report_count;
static int report_bad;
static int report_max_items;
static int report_max_claims;
static char report_text[64 * 1024];

static void check_report_file(const char *name)
{
	int owners, owner_limit, items, item_limit, claims, claim_limit;
	const char *line;
	FILE *file;
	size_t size;

	if (fopen_s(&file, name, "rb")) {
		report_bad++;
		return;
	}
	size = fread(report_text, 1, sizeof report_text - 1, file);
	fclose(file);
	report_text[size] = '\0';
	line = strstr(report_text, "memreader Plus capacity: ");
	if (!line || !strstr(report_text, "memreader Plus hooks: ") ||
		sscanf_s(line, "memreader Plus capacity: owners %d/%d, items %d/%d, claims %d/%d", &owners, &owner_limit, &items, &item_limit, &claims, &claim_limit) != 6 ||
		items > item_limit || claims > claim_limit) {
		report_bad++;
		return;
	}
	report_count++;
	if (items > report_max_items)
		report_max_items = items;
	if (claims > report_max_claims)
		report_max_claims = claims;
}

static DWORD WINAPI report_loop(LPVOID unused)
{
	lua_State *L = luaL_newstate();

	(void)unused;
	while (!report_stop) {
		lua_settop(L, 0);
		if (report_function(L) == 1 && lua_type(L, -1) == LUA_TSTRING)
			check_report_file(lua_tostring(L, -1));
		else
			report_bad++;
		Sleep(10);
	}
	lua_close(L);
	return 0;
}

static int l_test_report_loop_start(lua_State *L)
{
	report_function = lua_tocfunction(L, 1);
	if (!report_function)
		luaL_argerror(L, 1, "write_runtime_report");
	report_stop = 0;
	report_count = report_bad = report_max_items = report_max_claims = 0;
	report_thread = CreateThread(NULL, 0, report_loop, NULL, 0, NULL);
	return 0;
}

static int l_test_report_loop_stop(lua_State *L)
{
	report_stop = 1;
	WaitForSingleObject(report_thread, INFINITE);
	CloseHandle(report_thread);
	lua_pushnumber(L, report_count);
	lua_pushnumber(L, report_bad);
	lua_pushnumber(L, report_max_items);
	lua_pushnumber(L, report_max_claims);
	return 4;
}

static int l_test_microseconds(lua_State *L)
{
	LARGE_INTEGER now, frequency;

	QueryPerformanceCounter(&now);
	QueryPerformanceFrequency(&frequency);
	lua_pushnumber(L, (lua_Number)((double)(now.QuadPart % (frequency.QuadPart * 10)) * 1e6 / (double)frequency.QuadPart));
	return 1;
}

static const BYTE *reader_address;
static volatile LONG reader_stop;
static volatile LONG64 reader_reads;
static volatile LONG64 reader_torn;
static volatile LONG reader_gap;
static HANDLE reader_thread;

static DWORD WINAPI run_reader(void *unused)
{
	UINT32 words[4];
	LARGE_INTEGER frequency, now, last;
	LONG gap;

	(void)unused;
	QueryPerformanceFrequency(&frequency);
	QueryPerformanceCounter(&last);
	while (!reader_stop) {
		_mm_storeu_si128((__m128i *)words, _mm_loadu_si128((const __m128i *)reader_address));
		if (words[0] != words[1] || words[1] != words[2] || words[2] != words[3])
			reader_torn++;
		reader_reads++;
		QueryPerformanceCounter(&now);
		gap = (LONG)((now.QuadPart - last.QuadPart) * 1000000 / frequency.QuadPart);
		if (gap > reader_gap)
			reader_gap = gap;
		last = now;
	}
	return 0;
}

static int l_test_aligned_offset(lua_State *L)
{
	ULONG_PTR address;
	ULONG_PTR alignment = (ULONG_PTR)luaL_checkinteger(L, 2);

	memcpy(&address, luaL_checkstring(L, 1), sizeof address);
	lua_pushnumber(L, (lua_Number)((alignment - address % alignment) % alignment));
	return 1;
}

static int l_test_reader_start(lua_State *L)
{
	memcpy(&reader_address, luaL_checkstring(L, 1), sizeof reader_address);
	reader_stop = 0;
	reader_reads = 0;
	reader_torn = 0;
	reader_gap = 0;
	reader_thread = CreateThread(NULL, 0, run_reader, NULL, 0, NULL);
	return 0;
}

static int l_test_reader_counts(lua_State *L)
{
	lua_pushnumber(L, (lua_Number)reader_reads);
	lua_pushnumber(L, (lua_Number)reader_torn);
	lua_pushnumber(L, (lua_Number)reader_gap);
	return 3;
}

static int l_test_reader_stop(lua_State *L)
{
	reader_stop = 1;
	WaitForSingleObject(reader_thread, 5000);
	CloseHandle(reader_thread);
	return l_test_reader_counts(L);
}

static void WINAPI far_only_system_info(LPSYSTEM_INFO info)
{
	real_system_info(info);
	info->lpMinimumApplicationAddress = info->lpMaximumApplicationAddress;
	info->lpMaximumApplicationAddress = (LPVOID)(ULONG_PTR)0x10000;
}

static int l_test_far_function(lua_State *L)
{
	static const BYTE code[] = { 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3, 0x90, 0x90 };
	ULONG_PTR exe = (ULONG_PTR)GetModuleHandleW(NULL);
	ULONG_PTR distance;
	BYTE *page = NULL;
	DWORD old;

	for (distance = 0x100000000ULL; !page && distance < 0x400000000ULL; distance += 0x10000000ULL)
		page = VirtualAlloc((LPVOID)((exe - distance) & ~(ULONG_PTR)0xFFFF), 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
	if (!page)
		return 0;
	memcpy(page, code, sizeof code);
	VirtualProtect(page, 4096, PAGE_EXECUTE_READ, &old);
	lua_pushlstring(L, (const char *)&page, sizeof page);
	return 1;
}

static LPVOID (WINAPI *counted_alloc_next)(LPVOID address, SIZE_T size, DWORD type, DWORD protection);
static BOOL (WINAPI *counted_free_next)(LPVOID address, SIZE_T size, DWORD type);
static volatile LONG virtual_blocks;
static struct {
	LPVOID address;
	DWORD protection;
} recent_allocations[64];
static volatile LONG allocation_count;

static LPVOID WINAPI counted_alloc(LPVOID address, SIZE_T size, DWORD type, DWORD protection)
{
	LPVOID result = counted_alloc_next(address, size, type, protection);
	LONG slot;

	if (!result)
		return NULL;
	if (type & MEM_RESERVE)
		InterlockedIncrement(&virtual_blocks);
	slot = InterlockedIncrement(&allocation_count) % 64;
	recent_allocations[slot].address = result;
	recent_allocations[slot].protection = protection;
	return result;
}

static BOOL WINAPI counted_free(LPVOID address, SIZE_T size, DWORD type)
{
	BOOL result = counted_free_next(address, size, type);

	if (result && type == MEM_RELEASE)
		InterlockedDecrement(&virtual_blocks);
	return result;
}

static int l_test_virtual_blocks(lua_State *L)
{
	find_plus(L, 1);
	if (!counted_alloc_next) {
		replace_plus_import("VirtualAlloc", (void *)counted_alloc, (void **)&counted_alloc_next);
		replace_plus_import("VirtualFree", (void *)counted_free, (void **)&counted_free_next);
	}
	lua_pushinteger(L, virtual_blocks);
	return 1;
}

enum { FREED_BLOCKS = 1024 };

static LPVOID (WINAPI *checked_alloc_next)(HANDLE heap, DWORD flags, SIZE_T size);
static LPVOID (WINAPI *checked_realloc_next)(HANDLE heap, DWORD flags, LPVOID block, SIZE_T size);
static BOOL (WINAPI *checked_free_next)(HANDLE heap, DWORD flags, LPVOID block);
static SRWLOCK freed_lock = SRWLOCK_INIT;
static LPVOID freed_blocks[FREED_BLOCKS];
static int freed_next;
static volatile LONG double_frees;

static void forget_block(LPVOID block)
{
	int i;

	AcquireSRWLockExclusive(&freed_lock);
	for (i = 0; i < FREED_BLOCKS; i++) {
		if (freed_blocks[i] == block)
			freed_blocks[i] = NULL;
	}
	ReleaseSRWLockExclusive(&freed_lock);
}

static BOOL freed_before(LPVOID block)
{
	BOOL found = FALSE;
	int i;

	AcquireSRWLockExclusive(&freed_lock);
	for (i = 0; i < FREED_BLOCKS && !found; i++)
		found = freed_blocks[i] == block;
	if (!found) {
		freed_blocks[freed_next] = block;
		freed_next = (freed_next + 1) % FREED_BLOCKS;
	}
	ReleaseSRWLockExclusive(&freed_lock);
	return found;
}

static LPVOID WINAPI checked_heap_alloc(HANDLE heap, DWORD flags, SIZE_T size)
{
	LPVOID block = checked_alloc_next(heap, flags, size);

	if (block)
		forget_block(block);
	return block;
}

static LPVOID WINAPI checked_heap_realloc(HANDLE heap, DWORD flags, LPVOID old, SIZE_T size)
{
	LPVOID block = checked_realloc_next(heap, flags, old, size);

	if (block)
		forget_block(block);
	return block;
}

static BOOL WINAPI checked_heap_free(HANDLE heap, DWORD flags, LPVOID block)
{
	if (block && freed_before(block)) {
		InterlockedIncrement(&double_frees);
		return TRUE;
	}
	return checked_free_next(heap, flags, block);
}

static int l_test_double_frees(lua_State *L)
{
	find_plus(L, 1);
	if (!checked_free_next) {
		replace_plus_import("HeapAlloc", (void *)checked_heap_alloc, (void **)&checked_alloc_next);
		replace_plus_import("HeapReAlloc", (void *)checked_heap_realloc, (void **)&checked_realloc_next);
		replace_plus_import("HeapFree", (void *)checked_heap_free, (void **)&checked_free_next);
	}
	lua_pushinteger(L, double_frees);
	return 1;
}

static int l_test_allocated_as(lua_State *L)
{
	LPVOID address;
	int i;

	memcpy(&address, luaL_checkstring(L, 1), sizeof address);
	for (i = 0; i < 64; i++) {
		int slot = ((allocation_count - i) % 64 + 64) % 64;

		if (recent_allocations[slot].address == address) {
			lua_pushinteger(L, (lua_Integer)recent_allocations[slot].protection);
			return 1;
		}
	}
	return 0;
}

static int l_test_newest_allocation(lua_State *L)
{
	int slot = allocation_count % 64;

	lua_pushlstring(L, (const char *)&recent_allocations[slot].address, sizeof recent_allocations[slot].address);
	lua_pushinteger(L, (lua_Integer)recent_allocations[slot].protection);
	return 2;
}

static SIZE_T (WINAPI *counted_query_next)(LPCVOID address, PMEMORY_BASIC_INFORMATION region, SIZE_T size);
static volatile LONG plus_queries;

static SIZE_T WINAPI counted_query(LPCVOID address, PMEMORY_BASIC_INFORMATION region, SIZE_T size)
{
	InterlockedIncrement(&plus_queries);
	return counted_query_next(address, region, size);
}

static int l_test_plus_queries(lua_State *L)
{
	find_plus(L, 1);
	if (!counted_query_next)
		replace_plus_import("VirtualQuery", (void *)counted_query, (void **)&counted_query_next);
	lua_pushinteger(L, plus_queries);
	return 1;
}

enum { FILL_REACH = 0x70010000, FILL_STEP = 0x10000 };

static void **filled_blocks;
static int filled_count;

static int l_test_fill_near(lua_State *L)
{
	ULONG_PTR site, at, end;
	void *block;

	memcpy(&site, luaL_checkstring(L, 1), sizeof site);
	at = (site - FILL_REACH) & ~(ULONG_PTR)(FILL_STEP - 1);
	end = site + FILL_REACH;
	filled_blocks = HeapAlloc(GetProcessHeap(), 0, ((end - at) / FILL_STEP + 1) * sizeof *filled_blocks);
	filled_count = 0;
	for (; filled_blocks && at < end; at += FILL_STEP) {
		block = VirtualAlloc((void *)at, FILL_STEP, MEM_RESERVE, PAGE_NOACCESS);
		if (block)
			filled_blocks[filled_count++] = block;
	}
	lua_pushinteger(L, filled_count);
	return 1;
}

static int l_test_unfill_near(lua_State *L)
{
	while (filled_count > 0)
		VirtualFree(filled_blocks[--filled_count], 0, MEM_RELEASE);
	HeapFree(GetProcessHeap(), 0, filled_blocks);
	filled_blocks = NULL;
	(void)L;
	return 0;
}

static int l_test_image_size(lua_State *L)
{
	BYTE *image = (BYTE *)GetModuleHandleW(NULL);
	IMAGE_NT_HEADERS *headers = (IMAGE_NT_HEADERS *)(image + ((IMAGE_DOS_HEADER *)image)->e_lfanew);
	DWORD *size = &headers->OptionalHeader.SizeOfImage;
	DWORD old_size = *size, protection;

	VirtualProtect(size, sizeof *size, PAGE_READWRITE, &protection);
	*size = (DWORD)luaL_checkinteger(L, 1);
	VirtualProtect(size, sizeof *size, protection, &protection);
	lua_pushinteger(L, (lua_Integer)old_size);
	return 1;
}

static int l_test_force_far_hooks(lua_State *L)
{
	BOOL on = lua_toboolean(L, 1);
	void *ignored = NULL;

	find_plus(L, 2);
	if (on && !real_system_info) {
		replace_plus_import("GetSystemInfo", (void *)far_only_system_info, (void **)&real_system_info);
	} else if (!on && real_system_info) {
		replace_plus_import("GetSystemInfo", (void *)real_system_info, &ignored);
		real_system_info = NULL;
	}
	lua_pushboolean(L, !on || real_system_info != NULL);
	return 1;
}

static const struct {
	const char *name;
	void (*function)(void);
} faults[] = {
	{ "av", fault_av },
	{ "overflow", fault_overflow },
	{ "fastfail", fault_fastfail },
	{ "abort", fault_abort },
	{ "cpp", fault_cpp },
	{ "heap_double_free", fault_heap_double_free },
	{ "heap_overrun", fault_heap_overrun },
	{ "exit_process", fault_exit_process },
	{ "terminate_process", fault_terminate_process },
	{ "crt_exit", fault_crt_exit },
	{ "divide", fault_divide },
	{ "ud2", fault_ud2 },
	{ "second", fault_second },
	{ "worker_stuck", fault_worker_stuck },
	{ "two_threads", fault_two_threads },
	{ "overlap", fault_overlap },
	{ "worker_waits", fault_worker_waits },
	{ "worker_blocked", fault_worker_blocked },
	{ "worker_dead", fault_worker_dead },
	{ "move_retry", fault_move_retry },
	{ "move_fails", fault_move_fails },
	{ "no_report_folder", fault_no_report_folder },
};

static DWORD WINAPI fault_thread(LPVOID function)
{
	((void (*)(void))function)();
	return 0;
}

static int l_test_fault(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	size_t i;

	SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
	if (!lua_isnoneornil(L, 3))
		find_plus(L, 3);
	for (i = 0; i < sizeof faults / sizeof faults[0]; i++) {
		if (strcmp(faults[i].name, name) != 0)
			continue;
		if (lua_toboolean(L, 2)) {
			HANDLE thread = CreateThread(NULL, 0, fault_thread, (LPVOID)faults[i].function, 0, NULL);
			WaitForSingleObject(thread, INFINITE);
		} else {
			faults[i].function();
		}
		return 0;
	}
	return luaL_error(L, "no fault %s", name);
}

static int l_test_sleep(lua_State *L)
{
	Sleep((DWORD)luaL_checkinteger(L, 1));
	return 0;
}

static int l_test_protect(lua_State *L)
{
	void *address;
	DWORD old = 0;
	memcpy(&address, luaL_checkstring(L, 1), sizeof address);
	VirtualProtect(address, (SIZE_T)luaL_checkinteger(L, 2), (DWORD)luaL_checkinteger(L, 3), &old);
	lua_pushinteger(L, old);
	return 1;
}

static int l_test_fill_mixed(lua_State *L)
{
	BYTE *at = (BYTE *)mixed_code;
	size_t size = (size_t)luaL_checkinteger(L, 1), i;
	UINT32 state = 0x9E3779B9;
	DWORD old;

	VirtualProtect(at, size, PAGE_EXECUTE_READWRITE, &old);
	for (i = 0; i < size; i++) {
		state ^= state << 13;
		state ^= state >> 17;
		state ^= state << 5;
		at[i] = (BYTE)(state >> 24);
	}
	VirtualProtect(at, size, old, &old);
	return 0;
}

static int l_test_page(lua_State *L)
{
	char *page = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);

	lua_pushlstring(L, (const char *)&page, sizeof page);
	return 1;
}

static int l_test_protection(lua_State *L)
{
	MEMORY_BASIC_INFORMATION region;
	void *address;

	memcpy(&address, luaL_checkstring(L, 1), sizeof address);
	VirtualQuery(address, &region, sizeof region);
	lua_pushinteger(L, region.Protect);
	return 1;
}

static int l_test_system_address(lua_State *L)
{
	FARPROC function = GetProcAddress(GetModuleHandleA(luaL_checkstring(L, 1)), luaL_checkstring(L, 2));

	lua_pushlstring(L, (const char *)&function, sizeof function);
	return 1;
}

static int l_test_process_id(lua_State *L)
{
	lua_pushinteger(L, GetCurrentProcessId());
	return 1;
}

static int l_test_has_avx(lua_State *L)
{
	lua_pushboolean(L, (GetEnabledXStateFeatures() & XSTATE_MASK_AVX) != 0);
	return 1;
}

static int l_test_clobber_vectors(lua_State *L)
{
	(void)L;
	_mm256_zeroupper();
	return 0;
}

static struct {
	BYTE header[4];
	RUNTIME_FUNCTION parent;
} chain_info = { { 0x21, 0, 0, 0 } };

static int l_test_chain_cold_part(lua_State *L)
{
	DWORD64 base = 0;
	PRUNTIME_FUNCTION hot = RtlLookupFunctionEntry((DWORD64)site_split, &base, NULL);
	PRUNTIME_FUNCTION cold = RtlLookupFunctionEntry((DWORD64)site_split_cold, &base, NULL);
	DWORD old;

	chain_info.parent = *hot;
	VirtualProtect(cold, sizeof *cold, PAGE_READWRITE, &old);
	cold->UnwindData = (DWORD)((BYTE *)&chain_info - (BYTE *)base);
	VirtualProtect(cold, sizeof *cold, old, &old);
	lua_pushboolean(L, hot && cold && hot != cold);
	return 1;
}

static int l_test_dirty_vectors(lua_State *L)
{
	(void)L;
	dirty_vectors();
	return 0;
}

static LONG access_faults;

static LONG CALLBACK count_access_fault(EXCEPTION_POINTERS *info)
{
	if (info->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION)
		InterlockedIncrement(&access_faults);
	return EXCEPTION_CONTINUE_SEARCH;
}

static int l_test_access_faults(lua_State *L)
{
	lua_pushinteger(L, access_faults);
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
	lua_register(L, "test_recovered_crash", l_test_recovered_crash);
	lua_register(L, "test_execute_crash", l_test_execute_crash);
	lua_register(L, "test_run", l_test_run);
	lua_register(L, "test_thread_crash", l_test_thread_crash);
	lua_register(L, "test_allocator_crash", l_test_allocator_crash);
	lua_register(L, "test_hook_timing", l_test_hook_timing);
	lua_register(L, "test_stack_overflow", l_test_stack_overflow);
	lua_register(L, "test_fault", l_test_fault);
	lua_register(L, "test_sleep", l_test_sleep);
	lua_register(L, "test_protect", l_test_protect);
	lua_register(L, "test_fill_mixed", l_test_fill_mixed);
	lua_register(L, "test_protection", l_test_protection);
	lua_register(L, "test_page", l_test_page);
	lua_register(L, "test_system_address", l_test_system_address);
	lua_register(L, "test_process_id", l_test_process_id);
	lua_register(L, "test_has_avx", l_test_has_avx);
	lua_register(L, "test_clobber_vectors", l_test_clobber_vectors);
	lua_register(L, "test_dirty_vectors", l_test_dirty_vectors);
	lua_register(L, "test_chain_cold_part", l_test_chain_cold_part);
	lua_register(L, "cave_count", l_cave_count);
	lua_register(L, "cave_count_address", l_cave_count_address);
	lua_register(L, "test_access_faults", l_test_access_faults);
	lua_register(L, "test_source_block", l_test_source_block);
	lua_register(L, "test_source_loop", l_test_source_loop);
	lua_register(L, "test_reserved", l_test_reserved);
	lua_register(L, "test_fail_emplace", l_test_fail_emplace);
	lua_register(L, "test_park_start", l_test_park_start);
	lua_register(L, "test_park_rip", l_test_park_rip);
	lua_register(L, "test_park_flag", l_test_park_flag);
	lua_register(L, "test_park_finish", l_test_park_finish);
	lua_register(L, "test_park_leave_on_retry", l_test_park_leave_on_retry);
	lua_register(L, "test_park_left", l_test_park_left);
	lua_register(L, "test_fail_protect", l_test_fail_protect);
	lua_register(L, "test_relock", l_test_relock);
	lua_register(L, "test_fail_restore", l_test_fail_restore);
	lua_register(L, "test_count_protect", l_test_count_protect);
	lua_register(L, "test_protect_count", l_test_protect_count);
	lua_register(L, "test_fail_alloc", l_test_fail_alloc);
	lua_register(L, "test_fail_memory", l_test_fail_memory);
	lua_register(L, "test_watch_window", l_test_watch_window);
	lua_register(L, "test_window_counts", l_test_window_counts);
	lua_register(L, "test_report_loop_start", l_test_report_loop_start);
	lua_register(L, "test_report_loop_stop", l_test_report_loop_stop);
	lua_register(L, "test_watch_suspend", l_test_watch_suspend);
	lua_register(L, "test_suspend_calls", l_test_suspend_calls);
	lua_register(L, "test_spawn_on_suspend", l_test_spawn_on_suspend);
	lua_register(L, "test_end_spawned", l_test_end_spawned);
	lua_register(L, "test_change_on_suspend", l_test_change_on_suspend);
	lua_register(L, "test_deny_next_thread", l_test_deny_next_thread);
	lua_register(L, "test_deny_snapshot", l_test_deny_snapshot);
	lua_register(L, "test_fail_context", l_test_fail_context);
	lua_register(L, "test_microseconds", l_test_microseconds);
	lua_register(L, "test_aligned_offset", l_test_aligned_offset);
	lua_register(L, "test_reader_start", l_test_reader_start);
	lua_register(L, "test_reader_counts", l_test_reader_counts);
	lua_register(L, "test_reader_stop", l_test_reader_stop);
	lua_register(L, "test_force_far_hooks", l_test_force_far_hooks);
	lua_register(L, "test_virtual_blocks", l_test_virtual_blocks);
	lua_register(L, "test_allocated_as", l_test_allocated_as);
	lua_register(L, "test_newest_allocation", l_test_newest_allocation);
	lua_register(L, "test_plus_queries", l_test_plus_queries);
	lua_register(L, "test_fill_near", l_test_fill_near);
	lua_register(L, "test_unfill_near", l_test_unfill_near);
	lua_register(L, "test_image_size", l_test_image_size);
	lua_register(L, "test_double_frees", l_test_double_frees);
	lua_register(L, "test_far_function", l_test_far_function);
	lua_register(L, "test_catch_site_call", l_test_catch_site_call);
	lua_register(L, "test_heap_blocks", l_test_heap_blocks);
	lua_register(L, "test_open_streams", l_test_open_streams);
	lua_register(L, "exe_data_address", l_exe_data_address);
	register_file_edit_tests(L);
	register_session_tests(L);
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

enum { CONTEXT_ROOM = 12 * 1024 };

static bool handler_hidden;

static int main_filter(DWORD code, EXCEPTION_POINTERS *info)
{
	int result = EXCEPTION_CONTINUE_SEARCH;
	volatile char *context_room;

	if (code == EXCEPTION_STACK_OVERFLOW) {
		context_room = _alloca(CONTEXT_ROOM);
		context_room[0] = 1;
	}
	if (!handler_hidden)
		result = game_crash_handler(code, info);
	else
		write_game_crash_file();
	write_move_calls();
	if (second_fault) {
		second_fault = false;
		__try {
			read_null();
		} __except (main_filter(GetExceptionCode(), GetExceptionInformation())) {
		}
	}
	return result;
}

static LONG WINAPI unhandled_filter(EXCEPTION_POINTERS *info)
{
	main_filter(info->ExceptionRecord->ExceptionCode, info);
	return EXCEPTION_EXECUTE_HANDLER;
}

static void hide_game_handler(void)
{
	BYTE *first = (BYTE *)game_crash_handler;
	DWORD old;
	VirtualProtect(first, 1, PAGE_EXECUTE_READWRITE, &old);
	*first = 0xCC;
	VirtualProtect(first, 1, old, &old);
	handler_hidden = true;
}

int main(int argc, char **argv)
{
	int pass = 1;
	if (argc < 3) {
		fprintf(stderr, "usage: lua_host <script.lua> <mod root> [scenario]\n");
		return 2;
	}
	if (argc > 3 && strcmp(argv[3], "fault_report_fallback") == 0)
		hide_game_handler();
	SetUnhandledExceptionFilter(unhandled_filter);
	AddVectoredExceptionHandler(1, count_access_fault);
	__try {
		while (run_pass(argv, argc, pass))
			pass++;
	} __except (main_filter(GetExceptionCode(), GetExceptionInformation())) {
	}
	return 0;
}
