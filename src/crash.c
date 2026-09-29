#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "common.h"

enum {
	REPORT_SIZE = 16384,
	DEBUG_RECORD_SIZE = 0x400,
	MAX_FRAMES = 40,
	MAX_LOCALS = 6,
	MAX_LOCAL_TEXT = 80,
	STAMP_LENGTH = sizeof "DDMMYY_HHMM" - 1
};

typedef union {
	lua_Debug fields;
	char raw[DEBUG_RECORD_SIZE];
} DebugRecord;

_Static_assert(offsetof(lua_Debug, short_src) == 0x38, "the game's lua_Debug starts like stock Lua 5.1 on x64");

extern IMAGE_DOS_HEADER __ImageBase;

static const char watch_key = 0;
static const char script_log_prefix[] = "script_log_";
static const char script_logs[] = "script_log_*.txt";
static const char report_format[] = "memreader_crash_report_%s.txt";

static PVOID handler;
static lua_State *watched;
static DWORD script_thread;
static ULONG_PTR own_start;
static ULONG_PTR own_end;
static LONG guarded_calls;
static BOOL reporting;
static char report_path[MAX_PATH + sizeof report_format + STAMP_LENGTH];
static char report[REPORT_SIZE];
static size_t used;

void begin_guarded_call(void)
{
	InterlockedIncrement(&guarded_calls);
}

void end_guarded_call(void)
{
	InterlockedDecrement(&guarded_calls);
}

static void add(const char *format, ...)
{
	va_list arguments;

	if (used >= sizeof report - 1)
		return;
	va_start(arguments, format);
	_vsnprintf_s(report + used, sizeof report - used, _TRUNCATE, format, arguments);
	va_end(arguments);
	used += strlen(report + used);
}

static BOOL is_fatal(DWORD code)
{
	switch (code) {
	case EXCEPTION_ACCESS_VIOLATION:
	case EXCEPTION_ILLEGAL_INSTRUCTION:
	case EXCEPTION_PRIV_INSTRUCTION:
	case EXCEPTION_INT_DIVIDE_BY_ZERO:
	case EXCEPTION_STACK_OVERFLOW:
		return TRUE;
	}
	return FALSE;
}

static void add_string_locals(lua_State *L, lua_Debug *frame)
{
	int index;
	const char *name;

	for (index = 1; index <= MAX_LOCALS && (name = lua_getlocal(L, frame, index)) != NULL; index++) {
		if (lua_type(L, -1) == LUA_TSTRING)
			add("      %s = \"%.*s\"\n", name, MAX_LOCAL_TEXT, lua_tostring(L, -1));
		lua_pop(L, 1);
	}
}

static void add_lua_stack(lua_State *L)
{
	DebugRecord frame;
	int level;

	for (level = 0; level < MAX_FRAMES && lua_getstack(L, level, &frame.fields); level++) {
		if (!lua_getinfo(L, "Sln", &frame.fields))
			break;
		frame.raw[DEBUG_RECORD_SIZE - 1] = '\0';
		add("  #%d %s:%d in %s '%s' (%s)\n", level, frame.fields.short_src, frame.fields.currentline,
			frame.fields.namewhat, frame.fields.name ? frame.fields.name : "?", frame.fields.what);
		add_string_locals(L, &frame.fields);
	}
	if (level == 0)
		add("  no Lua function was running: the fault is in native game code\n");
}

static void add_location(const EXCEPTION_RECORD *record)
{
	ULONG_PTR address = (ULONG_PTR)record->ExceptionAddress;
	ULONG_PTR exe = (ULONG_PTR)GetModuleHandleA(NULL);
	const IMAGE_NT_HEADERS *headers = (const IMAGE_NT_HEADERS *)(exe + ((const IMAGE_DOS_HEADER *)exe)->e_lfanew);

	if (address >= exe && address < exe + headers->OptionalHeader.SizeOfImage)
		add("at Warhammer3.exe+0x%llx", (unsigned long long)(address - exe));
	else
		add("at %p (outside the game exe)", record->ExceptionAddress);
	if (record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && record->NumberParameters >= 2)
		add(", %s of %p", record->ExceptionInformation[0] == 0 ? "read" : "write", (void *)record->ExceptionInformation[1]);
}

static void write_report(void)
{
	HANDLE file = CreateFileA(report_path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
	DWORD written;

	if (file == INVALID_HANDLE_VALUE)
		return;
	WriteFile(file, report, (DWORD)used, &written, NULL);
	CloseHandle(file);
}

static void build_report(const EXCEPTION_RECORD *record)
{
	SYSTEMTIME time;

	GetLocalTime(&time);
	used = 0;
	add("memreader Plus %s: the game hit a fatal fault on the script thread.\n", MEMREADER_PLUS_VERSION);
	add("%04d-%02d-%02d %02d:%02d:%02d, exception 0x%08lx ", time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
		time.wSecond, record->ExceptionCode);
	add_location(record);
	add("\nLua stack of the script thread, innermost first:\n");
	__try {
		add_lua_stack(watched);
	} __except (EXCEPTION_EXECUTE_HANDLER) {
		add("  the Lua state could not be read any further\n");
	}
}

static LONG CALLBACK on_exception(EXCEPTION_POINTERS *info)
{
	const EXCEPTION_RECORD *record = info->ExceptionRecord;
	ULONG_PTR address = (ULONG_PTR)record->ExceptionAddress;

	if (!is_fatal(record->ExceptionCode) || !watched || GetCurrentThreadId() != script_thread || reporting ||
		guarded_calls > 0 || (address >= own_start && address < own_end))
		return EXCEPTION_CONTINUE_SEARCH;
	reporting = TRUE;
	build_report(record);
	write_report();
	reporting = FALSE;
	return EXCEPTION_CONTINUE_SEARCH;
}

static int forget_state(lua_State *L)
{
	(void)L;
	watched = NULL;
	return 0;
}

static void remember_state(lua_State *L)
{
	lua_pushlightuserdata(L, (void *)&watch_key);
	lua_newuserdata(L, 1);
	lua_createtable(L, 0, 1);
	lua_pushcfunction(L, forget_state);
	lua_setfield(L, -2, "__gc");
	lua_setmetatable(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
	watched = L;
	script_thread = GetCurrentThreadId();
}

static FILETIME process_start(void)
{
	FILETIME start = { 0, 0 }, exit, kernel, user;

	GetProcessTimes(GetCurrentProcess(), &start, &exit, &kernel, &user);
	return start;
}

static BOOL script_log_stamp(char *folder_end, FILETIME since, char *stamp)
{
	WIN32_FIND_DATAA found;
	HANDLE search;
	BOOL any = FALSE;

	memcpy(folder_end, script_logs, sizeof script_logs);
	search = FindFirstFileA(report_path, &found);
	if (search == INVALID_HANDLE_VALUE)
		return FALSE;
	do {
		if (strlen(found.cFileName) == sizeof script_log_prefix - 1 + STAMP_LENGTH + sizeof ".txt" - 1 &&
			CompareFileTime(&found.ftCreationTime, &since) >= 0) {
			memcpy(stamp, found.cFileName + sizeof script_log_prefix - 1, STAMP_LENGTH);
			stamp[STAMP_LENGTH] = '\0';
			since = found.ftCreationTime;
			any = TRUE;
		}
	} while (FindNextFileA(search, &found));
	FindClose(search);
	return any;
}

static void time_stamp(FILETIME time, char *stamp)
{
	FILETIME local;
	SYSTEMTIME parts;

	FileTimeToLocalFileTime(&time, &local);
	FileTimeToSystemTime(&local, &parts);
	_snprintf_s(stamp, STAMP_LENGTH + 1, _TRUNCATE, "%02d%02d%02d_%02d%02d", parts.wDay, parts.wMonth, parts.wYear % 100,
		parts.wHour, parts.wMinute);
}

static BOOL find_report_path(void)
{
	DWORD length = GetModuleFileNameA((HMODULE)&__ImageBase, report_path, MAX_PATH);
	FILETIME started = process_start();
	char stamp[STAMP_LENGTH + 1];
	char *name;

	if (length == 0 || length >= MAX_PATH)
		return FALSE;
	name = strrchr(report_path, '\\');
	if (!name)
		return FALSE;
	name++;
	if (!script_log_stamp(name, started, stamp))
		time_stamp(started, stamp);
	_snprintf_s(name, sizeof report_path - (size_t)(name - report_path), _TRUNCATE, report_format, stamp);
	return TRUE;
}

void watch_crashes(lua_State *L)
{
	if (!handler) {
		const IMAGE_NT_HEADERS *headers = (const IMAGE_NT_HEADERS *)((ULONG_PTR)&__ImageBase + __ImageBase.e_lfanew);
		HMODULE module;

		own_start = (ULONG_PTR)&__ImageBase;
		own_end = own_start + headers->OptionalHeader.SizeOfImage;
		if (!find_report_path() ||
			!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN, (LPCWSTR)(void *)on_exception, &module))
			return;
		handler = AddVectoredExceptionHandler(1, on_exception);
	}
	remember_state(L);
}
