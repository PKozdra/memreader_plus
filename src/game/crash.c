#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "game.h"
#include "MinHook.h"

enum {
	REPORT_SIZE = 48 * 1024,
	STAMP_LENGTH = sizeof "DDMMYY_HHMM" - 1,
	REPORT_WAIT_MS = 5000,
	OTHER_REPORT_WAIT_MS = 2 * REPORT_WAIT_MS,
	POLL_MS = 10,
	MOVE_TRIES = 5,
	MOVE_RETRY_MS = 20,
	GAME_FILE_GRACE_SECONDS = 2,
	TICKS_PER_SECOND = 10000000
};

typedef int (*GameHandler)(DWORD code, EXCEPTION_POINTERS *info);
typedef void (*GameExit)(int code, int cleanup, int return_mode);
typedef void (NTAPI *ExitFunction)(LONG code);
typedef BOOL (WINAPI *TerminateFunction)(HANDLE process, UINT code);

typedef struct {
	EXCEPTION_POINTERS *info;
	DWORD thread;
	BOOL confirmed;
	DWORD exit_code;
	const char *exit_call;
} PendingReport;

extern IMAGE_DOS_HEADER __ImageBase;

static const char watch_key = 0;
static const char script_log_prefix[] = "script_log_";
static const char script_logs[] = "script_log_*.txt";
static const char report_format[] = "memreader_crash_report_%s.txt";
static const char temporary_reports[] = "memreader_crash_report_*.tmp";
static const char game_handler_pattern[] =
	"48 89 5C 24 08 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 ?? ?? ?? ?? B8 ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 2B E0 45 33 E4 "
	"4C 8B F2 44 38 25 ?? ?? ?? ?? 8B D9 74 0A 48 83 C9 FF E8 ?? ?? ?? ?? CC B8 8D 00 00 C0";
static const char *allocator_patterns[] = {
	"40 53 48 83 EC ?? 48 83 3D ?? ?? ?? ?? 00 48 8B D9 0F 84 ?? ?? ?? ?? F6 05 ?? ?? ?? ?? 02 74 13",
	"48 83 EC ?? 48 85 C9 0F 84 ?? ?? ?? ?? F6 05 ?? ?? ?? ?? 02 48 89 5C 24 68 48 8D 59 F0 74 13 B8"
};
static const char game_exit_pattern[] =
	"48 89 5C 24 08 44 89 44 24 18 89 54 24 10 55 48 8B EC 48 83 EC ?? 8B D9 45 85 C0 75 4A 33 C9 FF 15";
static const char game_file_format[] = "D%4d-%2d-%2d_T%2d-%2d-%2d";

static BOOL watching;
static BOOL enabled = TRUE;
static GameHandler game_handler;
static BOOL game_handler_hooked;
static char handler_note[128];
static ULONG_PTR allocator[sizeof allocator_patterns / sizeof allocator_patterns[0]];
static int allocator_count;
static FILETIME fault_time;
static char script_log[MAX_PATH];
static char report_path[MAX_PATH + sizeof report_format + STAMP_LENGTH];
static char written_path[sizeof report_path + 16];
static lua_State *watched;
static DWORD script_thread;
static HANDLE script_thread_handle;
static ULONG_PTR own_start;
static ULONG_PTR own_end;
static volatile LONG reporting_thread;
static volatile LONG script_paused;
static HANDLE worker;
static HANDLE wake_event;
static HANDLE done_event;
static volatile BOOL worker_late;
static PendingReport pending;
static EXCEPTION_RECORD pending_record;
static CONTEXT pending_context;
static EXCEPTION_POINTERS pending_info;
static GameExit game_exit;
static ExitFunction exit_process;
static TerminateFunction terminate_process;
static char report_buffer[REPORT_SIZE];
static Text report = { report_buffer, sizeof report_buffer, 0 };

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

static UINT64 ticks_of(FILETIME time)
{
	return (UINT64)time.dwHighDateTime << 32 | time.dwLowDateTime;
}

static BOOL write_file(const char *path, size_t header)
{
	HANDLE file = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
	const char *session;
	size_t session_length;

	if (file == INVALID_HANDLE_VALUE)
		return FALSE;
	session = session_text(&session_length);
	write_redacted(file, report.data, header);
	write_redacted(file, session, session_length);
	write_redacted(file, "\n", 1);
	write_redacted(file, report.data + header, report.used - header);
	FlushFileBuffers(file);
	CloseHandle(file);
	return TRUE;
}

static BOOL move_into_place(const char *temporary)
{
	int i;

	for (i = 0; i < MOVE_TRIES; i++) {
		if (MoveFileExA(temporary, report_path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
			return TRUE;
		Sleep(MOVE_RETRY_MS);
	}
	return FALSE;
}

static void write_report(size_t header)
{
	char temporary[sizeof written_path];

	_snprintf_s(temporary, sizeof temporary, _TRUNCATE, "%s.%lu.tmp", report_path, GetCurrentThreadId());
	if (!write_file(temporary, header))
		return;
	if (move_into_place(temporary) || write_file(report_path, header)) {
		DeleteFileA(temporary);
		strcpy_s(written_path, sizeof written_path, report_path);
	} else {
		strcpy_s(written_path, sizeof written_path, temporary);
	}
}

static BOOL resume_script_thread(void)
{
	return InterlockedExchange(&script_paused, FALSE) && ResumeThread(script_thread_handle) != (DWORD)-1;
}

static void make_crash_report(CrashInput *input)
{
	CONTEXT script = { 0 };
	size_t header;

	if (pending.thread != script_thread && script_thread_handle && SuspendThread(script_thread_handle) != (DWORD)-1) {
		InterlockedExchange(&script_paused, TRUE);
		if (worker_late)
			resume_script_thread();
		script.ContextFlags = CONTEXT_FULL;
		if (GetThreadContext(script_thread_handle, &script))
			input->script = &script;
	}
	header = build_crash_report(&report, input);
	resume_script_thread();
	write_report(header);
}

static void make_report(void)
{
	CrashInput input = { pending.info, pending.thread, script_thread, NULL, pending.exit_call ? NULL : watched, pending.confirmed, script_log };
	SYSTEMTIME now;

	GetLocalTime(&now);
	SystemTimeToFileTime(&now, &fault_time);
	input.time = fault_time;
	input.handler_note = handler_note[0] ? handler_note : NULL;
	input.allocator = allocator;
	input.allocator_count = allocator_count;
	input.exit_code = pending.exit_code;
	input.exit_call = pending.exit_call;
	if (pending.exit_call)
		write_report(build_exit_report(&report, &input));
	else
		make_crash_report(&input);
}

static void warm_up(void)
{
	char scratch[64];
	Text text = { scratch, sizeof scratch, 0 };
	MEMORY_BASIC_INFORMATION region;
	ULONG64 image;

	add_text(&text, "%s %.9g %p %llu", "x", 1.5, (void *)&text, 1ULL);
	VirtualQuery(&text, &region, sizeof region);
	RtlLookupFunctionEntry((DWORD64)(ULONG_PTR)warm_up, &image, NULL);
	GetTickCount64();
}

static DWORD WINAPI report_worker(LPVOID unused)
{
	(void)unused;
	warm_up();
	for (;;) {
		WaitForSingleObject(wake_event, INFINITE);
		make_report();
		SetEvent(done_event);
	}
}

static void start_worker(void)
{
	wake_event = CreateEventW(NULL, FALSE, FALSE, NULL);
	done_event = CreateEventW(NULL, FALSE, FALSE, NULL);
	if (wake_event && done_event)
		worker = CreateThread(NULL, 0, report_worker, NULL, 0, NULL);
}

static BOOL worker_ready(void)
{
	return !worker_late && WaitForSingleObject(worker, 0) == WAIT_TIMEOUT;
}

static BOOL worker_done(void)
{
	return WaitForSingleObject(done_event, REPORT_WAIT_MS) == WAIT_OBJECT_0;
}

static void make_report_on_worker(void)
{
	SetEvent(wake_event);
	if (worker_done())
		return;
	worker_late = TRUE;
	if (resume_script_thread() && worker_done())
		worker_late = FALSE;
}

static void copy_job(const PendingReport *job)
{
	pending = *job;
	pending_context = *job->info->ContextRecord;
	pending_info.ContextRecord = &pending_context;
	pending_info.ExceptionRecord = NULL;
	if (job->info->ExceptionRecord) {
		pending_record = *job->info->ExceptionRecord;
		pending_info.ExceptionRecord = &pending_record;
	}
	pending.info = &pending_info;
}

static BOOL make_report_now(const PendingReport *job)
{
	if (worker && !worker_ready())
		return FALSE;
	written_path[0] = '\0';
	copy_job(job);
	if (worker)
		make_report_on_worker();
	else
		make_report();
	return written_path[0] != '\0';
}

static void wait_for_other_report(LONG me)
{
	ULONGLONG give_up = GetTickCount64() + OTHER_REPORT_WAIT_MS;
	LONG owner;

	while ((owner = reporting_thread) != 0 && owner != me && GetTickCount64() < give_up)
		Sleep(POLL_MS);
}

static BOOL run_report(const PendingReport *job)
{
	LONG me = (LONG)job->thread;
	BOOL wrote;

	if (!enabled || !report_path[0] || (job->confirmed && written_path[0]))
		return FALSE;
	if (InterlockedCompareExchange(&reporting_thread, me, 0)) {
		wait_for_other_report(me);
		return FALSE;
	}
	wrote = make_report_now(job);
	InterlockedExchange(&reporting_thread, 0);
	return wrote;
}

static BOOL report_fault(EXCEPTION_POINTERS *info, BOOL confirmed)
{
	PendingReport job = { info, GetCurrentThreadId(), confirmed, 0, NULL };

	return run_report(&job);
}

static void leave_own_frames(CONTEXT *context)
{
	ULONG64 image, establisher;
	PRUNTIME_FUNCTION entry;
	PVOID handler_data;

	while (context->Rip >= own_start && context->Rip < own_end && (entry = RtlLookupFunctionEntry(context->Rip, &image, NULL)) != NULL)
		RtlVirtualUnwind(UNW_FLAG_NHANDLER, image, context->Rip, entry, context, &handler_data, &establisher, NULL);
}

static void report_exit(DWORD code, const char *call)
{
	CONTEXT context;
	EXCEPTION_POINTERS info = { NULL, &context };
	PendingReport job = { &info, GetCurrentThreadId(), TRUE, code, call };

	if (!code)
		return;
	RtlCaptureContext(&context);
	leave_own_frames(&context);
	run_report(&job);
}

static void on_game_exit(int code, int cleanup, int return_mode)
{
	report_exit((DWORD)code, "exit");
	game_exit(code, cleanup, return_mode);
}

static void NTAPI on_exit_process(LONG code)
{
	report_exit((DWORD)code, "ExitProcess");
	exit_process(code);
}

static BOOL WINAPI on_terminate_process(HANDLE process, UINT code)
{
	if (GetProcessId(process) == GetCurrentProcessId())
		report_exit(code, "TerminateProcess");
	return terminate_process(process, code);
}

static void hook_system_function(const WCHAR *module, const char *name, LPVOID detour, LPVOID *original)
{
	LPVOID target = (LPVOID)(INT_PTR)GetProcAddress(GetModuleHandleW(module), name);

	if (!target || MH_CreateHook(target, detour, original) != MH_OK)
		return;
	if (MH_EnableHook(target) != MH_OK)
		MH_RemoveHook(target);
}

static void hook_game_exit(void)
{
	INT_PTR target = find_unique(game_exit_pattern);
	BYTE window[SAVED_BYTES];

	if (!target || MH_CreateHook((LPVOID)target, (LPVOID)on_game_exit, (LPVOID *)&game_exit) != MH_OK)
		return;
	capture_code(target, window);
	if (MH_EnableHook((LPVOID)target) == MH_OK)
		remember_code(target, window);
	else
		MH_RemoveHook((LPVOID)target);
}

static void hook_exits(void)
{
	hook_game_exit();
	hook_system_function(L"ntdll.dll", "RtlExitUserProcess", (LPVOID)on_exit_process, (LPVOID *)&exit_process);
	hook_system_function(L"kernelbase.dll", "TerminateProcess", (LPVOID)on_terminate_process, (LPVOID *)&terminate_process);
}

static LONG CALLBACK on_exception(EXCEPTION_POINTERS *info)
{
	const EXCEPTION_RECORD *record = info->ExceptionRecord;
	ULONG_PTR address = (ULONG_PTR)record->ExceptionAddress;

	if (is_fatal(record->ExceptionCode) && watched && GetCurrentThreadId() == script_thread && !in_guarded_call() &&
		(address < own_start || address >= own_end))
		report_fault(info, FALSE);
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
	if (script_thread == GetCurrentThreadId() && script_thread_handle)
		return;
	if (script_thread_handle)
		CloseHandle(script_thread_handle);
	script_thread = GetCurrentThreadId();
	script_thread_handle = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT, FALSE, script_thread);
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

static void delete_temporary_reports(void)
{
	char path[sizeof report_path + 16];
	char *name;
	size_t room;
	WIN32_FIND_DATAA found;
	HANDLE search;

	memcpy(path, report_path, sizeof report_path);
	name = strrchr(path, '\\') + 1;
	room = sizeof path - (size_t)(name - path);
	memcpy(name, temporary_reports, sizeof temporary_reports);
	search = FindFirstFileA(path, &found);
	if (search == INVALID_HANDLE_VALUE)
		return;
	do {
		if (strlen(found.cFileName) < room) {
			memcpy(name, found.cFileName, strlen(found.cFileName) + 1);
			DeleteFileA(path);
		}
	} while (FindNextFileA(search, &found));
	FindClose(search);
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
	BOOL wrote = report_fault(info, TRUE);
	int result = game_handler(code, info);

	if (wrote)
		note_game_files();
	return result;
}

static INT_PTR find_game_handler(void)
{
	const BYTE *found[2];
	int count = find_code_all(game_handler_pattern, found, 2);

	if (count == 1)
		return (INT_PTR)found[0];
	if (count == 0)
		strcpy_s(handler_note, sizeof handler_note, "the game's crash handler was not found (its pattern matched nothing)");
	else
		strcpy_s(handler_note, sizeof handler_note, "the game's crash handler was not found (its pattern matched more than one place)");
	return 0;
}

static void hook_game_handler(void)
{
	INT_PTR target = find_game_handler();
	BYTE window[SAVED_BYTES];
	MH_STATUS status;

	if (!target)
		return;
	status = MH_CreateHook((LPVOID)target, (LPVOID)after_game_handler, (LPVOID *)&game_handler);
	if (status == MH_OK) {
		capture_code(target, window);
		status = MH_EnableHook((LPVOID)target);
		if (status == MH_OK) {
			remember_code(target, window);
			game_handler_hooked = TRUE;
			return;
		}
		MH_RemoveHook((LPVOID)target);
	}
	_snprintf_s(handler_note, sizeof handler_note, _TRUNCATE, "the game's crash handler was found but could not be hooked (MinHook %d)", status);
}

static void find_allocator(void)
{
	INT_PTR found;
	int i;

	for (i = 0; i < (int)(sizeof allocator_patterns / sizeof allocator_patterns[0]); i++) {
		found = find_unique(allocator_patterns[i]);
		if (found)
			allocator[allocator_count++] = (ULONG_PTR)found;
	}
}

static int l_set_crash_context(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	const char *value = lua_isnoneornil(L, 2) ? NULL : luaL_checkstring(L, 2);

	set_crash_context(name, value);
	return 0;
}

static int l_note_crash_event(lua_State *L)
{
	if (lua_type(L, 1) == LUA_TSTRING)
		note_crash_event(lua_tostring(L, 1));
	return 0;
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
	{ "set_crash_context", l_set_crash_context },
	{ "note_crash_event", l_note_crash_event },
	{ NULL, NULL }
};

static void start_watching(void)
{
	const IMAGE_NT_HEADERS *headers = (const IMAGE_NT_HEADERS *)((ULONG_PTR)&__ImageBase + __ImageBase.e_lfanew);
	HMODULE module;

	watching = TRUE;
	describe_session();
	prepare_native_report();
	own_start = (ULONG_PTR)&__ImageBase;
	own_end = own_start + headers->OptionalHeader.SizeOfImage;
	if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN, (LPCWSTR)(void *)on_exception, &module))
		return;
	delete_temporary_reports();
	start_worker();
	find_allocator();
	hook_game_handler();
	if (!game_handler_hooked)
		AddVectoredExceptionHandler(1, on_exception);
	hook_exits();
}

void watch_crashes(lua_State *L)
{
	if (!find_report_path())
		return;
	if (!watching)
		start_watching();
	remember_state(L);
}
