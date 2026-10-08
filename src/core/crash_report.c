#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "common.h"

enum {
	MAX_FRAMES = 40,
	MAX_FRAMES_WITH_LOCALS = 12,
	MAX_THREADS = 8,
	MAX_LOCALS = 8,
	MAX_LOCAL_TEXT = 80,
	MAX_CONTEXT = 12,
	CONTEXT_NAME_SIZE = 24,
	CONTEXT_VALUE_SIZE = 160,
	MAX_EVENTS = 32,
	EVENT_NAME_SIZE = 48,
	CUT_ROOM = 64,
	SETTINGS_SIZE = 16384,
	ALLOCATOR_DEPTH = 4,
	TICKS_PER_SECOND = 10000000
};

typedef struct {
	char name[CONTEXT_NAME_SIZE];
	char value[CONTEXT_VALUE_SIZE];
} ContextField;

typedef struct {
	char name[EVENT_NAME_SIZE];
	UINT32 count;
	UINT32 order;
	ULONGLONG last_tick;
} EventEntry;

typedef void (*Section)(Text *report, const CrashInput *input);

static const char settings_cut_line[] = "... cut: the settings list reached its size limit\n";

static ContextField context[MAX_CONTEXT];
static EventEntry events[MAX_EVENTS];
static UINT32 event_order;
static char settings_text[2][SETTINGS_SIZE];
static size_t settings_length[2];
static ULONGLONG settings_tick[2];
static volatile LONG settings_current;

void add_text(Text *text, const char *format, ...)
{
	va_list arguments;

	if (text->used >= text->size - 1)
		return;
	va_start(arguments, format);
	_vsnprintf_s(text->data + text->used, text->size - text->used, _TRUNCATE, format, arguments);
	va_end(arguments);
	text->used += strlen(text->data + text->used);
}

static void copy_clean(char *destination, size_t size, const char *source)
{
	size_t index;

	for (index = 0; index < size - 1 && source[index]; index++)
		destination[index] = (BYTE)source[index] < ' ' ? ' ' : source[index];
	destination[index] = '\0';
}

static ContextField *find_context_field(const char *name)
{
	ContextField *free_field = NULL;
	int index;

	for (index = 0; index < MAX_CONTEXT; index++) {
		if (strncmp(context[index].name, name, CONTEXT_NAME_SIZE - 1) == 0 && context[index].name[0])
			return &context[index];
		if (!free_field && !context[index].name[0])
			free_field = &context[index];
	}
	return free_field;
}

void set_crash_context(const char *name, const char *value)
{
	ContextField *field = find_context_field(name);

	if (!field)
		return;
	if (!value) {
		field->name[0] = '\0';
		return;
	}
	copy_clean(field->name, sizeof field->name, name);
	copy_clean(field->value, sizeof field->value, value);
}

void note_crash_event(const char *name)
{
	EventEntry *oldest = &events[0];
	int i;

	event_order++;
	for (i = 0; i < MAX_EVENTS; i++) {
		if (events[i].count && strncmp(events[i].name, name, EVENT_NAME_SIZE - 1) == 0) {
			events[i].count++;
			events[i].order = event_order;
			events[i].last_tick = GetTickCount64();
			return;
		}
		if (events[i].order < oldest->order)
			oldest = &events[i];
	}
	copy_clean(oldest->name, sizeof oldest->name, name);
	oldest->count = 1;
	oldest->order = event_order;
	oldest->last_tick = GetTickCount64();
}

static void add_bytes(Text *text, const char *bytes, size_t length)
{
	if (text->used >= text->size - 1)
		return;
	if (length > text->size - 1 - text->used)
		length = text->size - 1 - text->used;
	memcpy(text->data + text->used, bytes, length);
	text->used += length;
	text->data[text->used] = '\0';
}

static void copy_settings_clean(char *destination, const char *source, size_t length)
{
	size_t index;

	for (index = 0; index < length; index++)
		destination[index] = (BYTE)source[index] < ' ' && source[index] != '\n' ? ' ' : source[index];
}

static size_t whole_lines(const char *text, size_t room)
{
	while (room > 0 && text[room - 1] != '\n')
		room--;
	return room;
}

static size_t cut_settings(char *destination, const char *source)
{
	size_t cut_length = sizeof settings_cut_line - 1;
	size_t kept = whole_lines(source, SETTINGS_SIZE - cut_length);

	copy_settings_clean(destination, source, kept);
	memcpy(destination + kept, settings_cut_line, cut_length);
	return kept + cut_length;
}

static size_t copy_settings(char *destination, const char *source, size_t length)
{
	BOOL open_line = length > 0 && source[length - 1] != '\n';

	if (length + open_line > SETTINGS_SIZE)
		return cut_settings(destination, source);
	copy_settings_clean(destination, source, length);
	if (open_line)
		destination[length++] = '\n';
	return length;
}

void set_crash_settings(const char *text, size_t length)
{
	LONG spare = 1 - settings_current;

	settings_length[spare] = text ? copy_settings(settings_text[spare], text, length) : 0;
	settings_tick[spare] = GetTickCount64();
	InterlockedExchange(&settings_current, spare);
}

static void add_title(Text *report, const CrashInput *input, const char *kind)
{
	SYSTEMTIME time;

	FileTimeToSystemTime(&input->time, &time);
	add_text(report, "memreader Plus %s %s\n", MEMREADER_PLUS_VERSION, kind);
	add_text(report, "%04d-%02d-%02d %02d:%02d:%02d, ", time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond);
}

static void add_header(Text *report, const CrashInput *input)
{
	add_title(report, input, "crash report");
	add_fault(report, input->info->ExceptionRecord);
}

static void add_exit_header(Text *report, const CrashInput *input)
{
	add_title(report, input, "crash report");
	add_text(report, "the game ended itself with exit code %lu (0x%08lx) through %s\n", input->exit_code, input->exit_code,
		input->exit_call);
}

static void add_runtime_header(Text *report, const CrashInput *input)
{
	add_title(report, input, "runtime report");
	add_text(report, "written on request, nothing crashed\n");
}

static void add_thread_name(Text *report, const CrashInput *input)
{
	if (input->thread == input->script_thread)
		add_text(report, "Thread: the script thread\n");
	else
		add_text(report, "Thread: %lu, not the script thread (%lu)\n", input->thread, input->script_thread);
}

static void add_script_log(Text *report, const CrashInput *input)
{
	if (input->script_log[0])
		add_text(report, "Script log of this Lua state: %s\n", input->script_log);
	else
		add_text(report, "Script logging is off\n");
}

static void add_thread(Text *report, const CrashInput *input)
{
	add_thread_name(report, input);
	if (input->confirmed)
		add_text(report, "The game's crash handler caught it, so nothing recovered from this fault\n");
	else
		add_text(report, "Written when the fault happened: %s, so the game may have recovered\n",
			input->handler_note ? input->handler_note : "the game's crash handler was not found");
	add_script_log(report, input);
}

static void add_thread_and_log(Text *report, const CrashInput *input)
{
	add_thread_name(report, input);
	add_script_log(report, input);
}

static UINT64 ticks_of(FILETIME time)
{
	return (UINT64)time.dwHighDateTime << 32 | time.dwLowDateTime;
}

static void add_uptime(Text *report, const CrashInput *input)
{
	FILETIME start, exit, kernel, user, now;
	UINT64 minutes;

	if (!GetProcessTimes(GetCurrentProcess(), &start, &exit, &kernel, &user))
		return;
	GetSystemTimeAsFileTime(&now);
	minutes = (ticks_of(now) - ticks_of(start)) / TICKS_PER_SECOND / 60;
	add_text(report, "Game running for %llu h %llu min\n", minutes / 60, minutes % 60);
	add_memory_use(report);
	(void)input;
}

static void add_context(Text *report, const CrashInput *input)
{
	int index;

	add_text(report, "Game context set by script at safe moments:\n");
	for (index = 0; index < MAX_CONTEXT; index++) {
		if (context[index].name[0])
			add_text(report, "  %s: %s\n", context[index].name, context[index].value);
	}
	(void)input;
}

static void add_settings(Text *report, const CrashInput *input)
{
	LONG current = settings_current;
	ULONGLONG seconds = (GetTickCount64() - settings_tick[current]) / 1000;

	if (settings_length[current] == 0) {
		add_text(report, "MCT settings: none recorded (MCT is not installed or has not loaded yet)\n");
		return;
	}
	add_text(report, "MCT settings of the mods in this game (%llu seconds before this report):\n", seconds);
	add_bytes(report, settings_text[current], settings_length[current]);
	(void)input;
}

static const EventEntry *next_newest(UINT32 below)
{
	const EventEntry *newest = NULL;
	int i;

	for (i = 0; i < MAX_EVENTS; i++) {
		if (events[i].count && events[i].order < below && (!newest || events[i].order > newest->order))
			newest = &events[i];
	}
	return newest;
}

static void add_events(Text *report, const CrashInput *input)
{
	ULONGLONG now = GetTickCount64(), ago;
	const EventEntry *entry = next_newest(MAXUINT32);

	if (!entry)
		return;
	add_text(report, "Recent script events, newest first:\n");
	for (; entry; entry = next_newest(entry->order)) {
		ago = now - entry->last_tick;
		add_text(report, "  %s x%u, last %llu.%llu s before\n", entry->name, entry->count, ago / 1000, ago % 1000 / 100);
	}
	(void)input;
}

static void add_local(Text *report, lua_State *L, const char *name)
{
	switch (lua_type(L, -1)) {
	case LUA_TSTRING:
		add_text(report, "      %s = \"%.*s\"\n", name, MAX_LOCAL_TEXT, lua_tostring(L, -1));
		break;
	case LUA_TNUMBER:
		add_text(report, "      %s = %.9g\n", name, (double)lua_tonumber(L, -1));
		break;
	case LUA_TBOOLEAN:
		add_text(report, "      %s = %s\n", name, lua_toboolean(L, -1) ? "true" : "false");
		break;
	}
}

static void add_locals(Text *report, lua_State *L, lua_Debug *frame)
{
	int index;
	const char *name;

	for (index = 1; index <= MAX_LOCALS && (name = lua_getlocal(L, frame, index)) != NULL; index++) {
		if (name[0] != '(')
			add_local(report, L, name);
		lua_pop(L, 1);
	}
}

static void add_c_function(Text *report, lua_State *L)
{
	lua_CFunction function = lua_tocfunction(L, -1);

	if (function) {
		add_text(report, "      C function ");
		add_address(report, (ULONG_PTR)function);
		add_text(report, "\n");
	}
}

static int add_lua_stack(Text *report, lua_State *L)
{
	DebugRecord frame;
	int level;

	for (level = 0; level < MAX_FRAMES && lua_getstack(L, level, &frame.fields); level++) {
		if (!lua_getinfo(L, "Slnf", &frame.fields))
			break;
		frame.raw[DEBUG_RECORD_SIZE - 1] = '\0';
		add_text(report, "  #%d %s:%d in %s '%s' (%s)\n", level, frame.fields.short_src, frame.fields.currentline,
			frame.fields.namewhat, frame.fields.name ? frame.fields.name : "?", frame.fields.what);
		add_c_function(report, L);
		lua_pop(L, 1);
		if (level < MAX_FRAMES_WITH_LOCALS)
			add_locals(report, L, &frame.fields);
	}
	return level;
}

static BOOL is_running(lua_State *thread)
{
	DebugRecord frame;

	return lua_getstack(thread, 0, &frame.fields);
}

static int add_thread_stacks(Text *report, lua_State *L)
{
	lua_State *thread;
	int shown = 0;

	lua_pushnil(L);
	while (lua_next(L, LUA_REGISTRYINDEX)) {
		thread = lua_type(L, -1) == LUA_TTHREAD ? lua_tothread(L, -1) : NULL;
		lua_pop(L, 1);
		if (thread && thread != L && shown < MAX_THREADS && is_running(thread)) {
			add_text(report, "Lua thread %p, innermost first:\n", (void *)thread);
			add_lua_stack(report, thread);
			shown++;
		}
	}
	return shown;
}

static void add_lua_part(Text *report, const CrashInput *input)
{
	lua_State *L = input->lua;
	int top;

	if (input->thread == input->script_thread)
		add_text(report, "Lua stack of the script thread, innermost first:\n");
	else
		add_text(report, "Lua stack of the script thread, paused while the other thread crashed, innermost first:\n");
	if (!L) {
		add_text(report, "  no Lua state: the game was between modes\n");
		return;
	}
	top = lua_gettop(L);
	__try {
		if (add_lua_stack(report, L) == 0 && add_thread_stacks(report, L) == 0)
			add_text(report, "  no Lua function was running: the fault is in native game code\n");
	} __except (EXCEPTION_EXECUTE_HANDLER) {
		add_text(report, "  the Lua state could not be read any further\n");
	}
	lua_settop(L, top);
}

static void add_crashed_stack(Text *report, const CrashInput *input)
{
	add_text(report, "Native stack of the crashing thread, innermost first:\n");
	add_native_stack(report, input->info->ContextRecord);
	if (input->allocator_count && stack_enters(input->info->ContextRecord, input->allocator, input->allocator_count, ALLOCATOR_DEPTH))
		add_text(report, "This fault is in the game's memory allocator: memory was damaged earlier, and the code on this stack only found it\n");
}

static void add_exit_stack(Text *report, const CrashInput *input)
{
	add_text(report, "Native stack of the thread that ended the game, innermost first:\n");
	add_native_stack(report, input->info->ContextRecord);
}

static void add_crashed_registers(Text *report, const CrashInput *input)
{
	add_text(report, "Registers of the crashing thread:\n");
	add_registers(report, input->info->ContextRecord);
	add_code_bytes(report, (ULONG_PTR)input->info->ContextRecord->Rip);
}

static void add_crashed_memory(Text *report, const CrashInput *input)
{
	add_damaged_memory(report, input->info->ContextRecord, input->info->ExceptionRecord);
}

static void add_script_stack(Text *report, const CrashInput *input)
{
	if (!input->script)
		return;
	add_text(report, "Native stack of the script thread at the time, innermost first:\n");
	add_native_stack(report, input->script);
}

static void add_plus_hooks(Text *report, const CrashInput *input)
{
	add_hooks(report, input->lua);
}

static void add_plus_changes(Text *report, const CrashInput *input)
{
	add_changes(report);
	(void)input;
}

static void add_modules(Text *report, const CrashInput *input)
{
	add_other_module_count(report);
	add_timing_hooks(report);
	(void)input;
}

static const Section crash_sections[] = {
	add_header, add_thread, add_uptime, add_context, add_settings, add_events, add_lua_part, add_crashed_stack,
	add_crashed_registers, add_crashed_memory, add_script_stack, add_plus_hooks, add_plus_changes, add_modules
};

static const Section exit_sections[] = {
	add_exit_header, add_thread_and_log, add_uptime, add_context, add_settings, add_events, add_exit_stack, add_plus_hooks,
	add_plus_changes, add_modules
};

static const Section runtime_sections[] = {
	add_runtime_header, add_thread_and_log, add_uptime, add_context, add_settings, add_events, add_plus_hooks, add_plus_changes,
	add_modules
};

static void run_section(Text *report, const CrashInput *input, Section section)
{
	__try {
		section(report, input);
	} __except (EXCEPTION_EXECUTE_HANDLER) {
		add_text(report, "\n  (this part stopped early: memreader Plus faulted while writing it)\n");
	}
}

static size_t build_report(Text *report, const CrashInput *input, const Section *list, int count)
{
	Text body = { report->data, report->size - CUT_ROOM, 0 };
	size_t header = 0;
	int i;

	load_modules();
	set_crash_stack((ULONG_PTR)input->info->ContextRecord->Rsp);
	for (i = 0; i < count; i++) {
		run_section(&body, input, list[i]);
		if (i == 0)
			header = body.used;
	}
	report->used = body.used;
	if (body.used >= body.size - 1)
		add_text(report, "\n(the report was cut here: it reached its size limit)\n");
	return header;
}

size_t build_crash_report(Text *report, const CrashInput *input)
{
	return build_report(report, input, crash_sections, (int)(sizeof crash_sections / sizeof crash_sections[0]));
}

size_t build_exit_report(Text *report, const CrashInput *input)
{
	return build_report(report, input, exit_sections, (int)(sizeof exit_sections / sizeof exit_sections[0]));
}

size_t build_runtime_report(Text *report, const CrashInput *input)
{
	return build_report(report, input, runtime_sections, (int)(sizeof runtime_sections / sizeof runtime_sections[0]));
}
