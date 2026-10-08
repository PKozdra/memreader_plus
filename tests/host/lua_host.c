#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <intrin.h>
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
void filler_code(void);

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

void write_game_crash_file(void)
{
	SYSTEMTIME now;
	char name[64];
	HANDLE file;
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
int patch_target(void);
void register_file_edit_tests(lua_State *L);

__declspec(thread) static char host_thread_data[64];

static int l_test_open_streams(lua_State *L)
{
	lua_pushinteger(L, host_open_streams());
	return 1;
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
	{ "filler_code", filler_code },
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

void fake_dlfree(void *chunk);

static int l_test_allocator_crash(lua_State *L)
{
	static const WCHAR words[] = L"a tooltip text overwrote this chunk";
	BYTE *chunk = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, 256);

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
	lua_register(L, "test_thread_crash", l_test_thread_crash);
	lua_register(L, "test_allocator_crash", l_test_allocator_crash);
	lua_register(L, "test_hook_timing", l_test_hook_timing);
	lua_register(L, "test_stack_overflow", l_test_stack_overflow);
	lua_register(L, "test_fault", l_test_fault);
	lua_register(L, "test_sleep", l_test_sleep);
	lua_register(L, "test_protect", l_test_protect);
	lua_register(L, "test_access_faults", l_test_access_faults);
	lua_register(L, "test_heap_blocks", l_test_heap_blocks);
	lua_register(L, "test_open_streams", l_test_open_streams);
	lua_register(L, "exe_data_address", l_exe_data_address);
	register_file_edit_tests(L);
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
