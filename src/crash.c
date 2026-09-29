#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "common.h"
#include "MinHook.h"

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
static const char game_handler_pattern[] =
	"48 89 5C 24 08 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 ?? ?? ?? ?? B8 ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 2B E0 45 33 E4 "
	"4C 8B F2 44 38 25 ?? ?? ?? ?? 8B D9 74 0A 48 83 C9 FF E8 ?? ?? ?? ?? CC B8 8D 00 00 C0";
static const char game_file_format[] = "D%4d-%2d-%2d_T%2d-%2d-%2d";

enum { GAME_FILE_GRACE_SECONDS = 2, TICKS_PER_SECOND = 10000000 };

typedef int (*GameHandler)(DWORD code, EXCEPTION_POINTERS *info);

static PVOID handler;
static BOOL enabled = TRUE;
static BOOL reported;
static GameHandler game_handler;
static FILETIME fault_time;
static char script_log[MAX_PATH];
static char written_path[MAX_PATH + sizeof report_format + STAMP_LENGTH];
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
	const char *session;
	size_t session_length;
	DWORD written;

	if (file == INVALID_HANDLE_VALUE)
		return;
	session = session_text(&session_length);
	WriteFile(file, report, (DWORD)used, &written, NULL);
	WriteFile(file, session, (DWORD)session_length, &written, NULL);
	CloseHandle(file);
	memcpy(written_path, report_path, sizeof written_path);
	reported = TRUE;
}

static void build_report(const EXCEPTION_RECORD *record)
{
	SYSTEMTIME time;

	GetLocalTime(&time);
	SystemTimeToFileTime(&time, &fault_time);
	used = 0;
	add("memreader Plus %s: the game hit a fatal fault on the script thread.\n", MEMREADER_PLUS_VERSION);
	add("%04d-%02d-%02d %02d:%02d:%02d, exception 0x%08lx ", time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
		time.wSecond, record->ExceptionCode);
	add_location(record);
	if (script_log[0])
		add("\nScript log of this Lua state: %s", script_log);
	else
		add("\nScript logging is off");
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

	if (!enabled || !is_fatal(record->ExceptionCode) || !watched || GetCurrentThreadId() != script_thread || reporting ||
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
	script_log[0] = '\0';
	if (script_log_stamp(name, started, stamp))
		_snprintf_s(script_log, sizeof script_log, _TRUNCATE, "%s%s.txt", script_log_prefix, stamp);
	else
		time_stamp(started, stamp);
	_snprintf_s(name, sizeof report_path - (size_t)(name - report_path), _TRUNCATE, report_format, stamp);
	return TRUE;
}

static UINT64 ticks_of(FILETIME time)
{
	return (UINT64)time.dwHighDateTime << 32 | time.dwLowDateTime;
}

static BOOL game_file_time(const char *name, FILETIME *time)
{
	SYSTEMTIME parts = { 0 };
	int year, month, day, hour, minute, second;

	if (sscanf_s(name, game_file_format, &year, &month, &day, &hour, &minute, &second) != 6)
		return FALSE;
	parts.wYear = (WORD)year;
	parts.wMonth = (WORD)month;
	parts.wDay = (WORD)day;
	parts.wHour = (WORD)hour;
	parts.wMinute = (WORD)minute;
	parts.wSecond = (WORD)second;
	return SystemTimeToFileTime(&parts, time);
}

static void note_game_files(void)
{
	char pattern[MAX_PATH + 8], names[1024] = "", line[1200];
	WIN32_FIND_DATAA found;
	FILETIME written;
	HANDLE search, file;
	DWORD length;

	_snprintf_s(pattern, sizeof pattern, _TRUNCATE, "%s\\D*.*", game_crash_folder());
	search = FindFirstFileA(pattern, &found);
	if (search != INVALID_HANDLE_VALUE) {
		do {
			if (game_file_time(found.cFileName, &written) &&
				ticks_of(written) + (UINT64)GAME_FILE_GRACE_SECONDS * TICKS_PER_SECOND >= ticks_of(fault_time)) {
				strncat_s(names, sizeof names, " ", _TRUNCATE);
				strncat_s(names, sizeof names, found.cFileName, _TRUNCATE);
			}
		} while (FindNextFileA(search, &found));
		FindClose(search);
	}
	if (names[0])
		_snprintf_s(line, sizeof line, _TRUNCATE, "The game's own crash files for this crash, in the game crash folder:%s\n", names);
	else
		_snprintf_s(line, sizeof line, _TRUNCATE, "The game wrote no crash files for this crash (it skips them when a debugger is attached)\n");
	file = CreateFileA(written_path, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
	if (file == INVALID_HANDLE_VALUE)
		return;
	WriteFile(file, line, (DWORD)strlen(line), &length, NULL);
	CloseHandle(file);
}

static int after_game_handler(DWORD code, EXCEPTION_POINTERS *info)
{
	int result = game_handler(code, info);

	if (reported) {
		note_game_files();
		reported = FALSE;
	}
	return result;
}

static void hook_game_handler(void)
{
	int count;
	const BYTE *target = find_code(game_handler_pattern, &count);

	if (count != 1 || MH_CreateHook((LPVOID)target, (LPVOID)after_game_handler, (LPVOID *)&game_handler) != MH_OK)
		return;
	if (MH_EnableHook((LPVOID)target) != MH_OK)
		MH_RemoveHook((LPVOID)target);
}

static int l_set_crash_reports(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TBOOLEAN);
	lua_pushboolean(L, enabled);
	enabled = lua_toboolean(L, 1);
	return 1;
}

const luaL_Reg crash_functions[] = {
	{ "set_crash_reports", l_set_crash_reports },
	{ NULL, NULL }
};

void watch_crashes(lua_State *L)
{
	if (!find_report_path())
		return;
	if (!handler) {
		describe_session();
		hook_game_handler();
		const IMAGE_NT_HEADERS *headers = (const IMAGE_NT_HEADERS *)((ULONG_PTR)&__ImageBase + __ImageBase.e_lfanew);
		HMODULE module;

		own_start = (ULONG_PTR)&__ImageBase;
		own_end = own_start + headers->OptionalHeader.SizeOfImage;
		if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN, (LPCWSTR)(void *)on_exception, &module))
			return;
		handler = AddVectoredExceptionHandler(1, on_exception);
	}
	remember_state(L);
}
