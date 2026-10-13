#include <stdio.h>
#include <string.h>

#include "common.h"

enum { MAX_LOGGED = 32, LINE_SIZE = 320, MAX_CALLER_LEVELS = 8 };

enum { MAX_WRITES = 24, MAX_PATCHES = 32, WHAT_SIZE = 24 };

enum { EXECUTABLE = PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY };

extern IMAGE_DOS_HEADER __ImageBase;

static const char log_name[] = "memreader_plus_refused.txt";
typedef struct {
	INT_PTR low;
	INT_PTR high;
	INT_PTR end;
	size_t size;
	BOOL spread;
	UINT32 count;
	ULONGLONG tick;
	char what[WHAT_SIZE];
	char where[CALLER_SIZE];
	char tag[TAG_SIZE];
} Change;

static char logged[MAX_LOGGED][LINE_SIZE];
static int logged_count;
static Change writes[MAX_WRITES];
static int write_next;
typedef struct {
	Change rows[MAX_PATCHES];
	int count;
	UINT32 not_listed;
} PatchTable;

static PatchTable raw_patches;
static PatchTable owned_patches;

BOOL is_executable(INT_PTR address)
{
	MEMORY_BASIC_INFORMATION region;

	return VirtualQuery((LPCVOID)address, &region, sizeof region) && region.State == MEM_COMMIT &&
		(region.Protect & EXECUTABLE) && !(region.Protect & (PAGE_GUARD | PAGE_NOACCESS));
}

BOOL in_own_module(INT_PTR address)
{
	INT_PTR start = (INT_PTR)&__ImageBase;
	const IMAGE_NT_HEADERS *headers = (const IMAGE_NT_HEADERS *)(start + __ImageBase.e_lfanew);

	return address >= start && address < start + (INT_PTR)headers->OptionalHeader.SizeOfImage;
}

BOOL in_exe_code(INT_PTR address)
{
	BYTE *start, *end;
	int i;

	for (i = 0; code_section(i, &start, &end); i++) {
		if ((BYTE *)address >= start && (BYTE *)address < end)
			return TRUE;
	}
	return FALSE;
}

static const char *function_name(lua_State *L, const char *what)
{
	DebugRecord frame;

	if (what)
		return what;
	if (lua_getstack(L, 0, &frame.fields) && lua_getinfo(L, "n", &frame.fields) && frame.fields.name)
		return frame.fields.name;
	return "a Plus function";
}

void caller_position(lua_State *L, char *where, size_t size)
{
	DebugRecord frame;
	int level;

	strcpy_s(where, size, "unknown script");
	for (level = 1; level <= MAX_CALLER_LEVELS && lua_getstack(L, level, &frame.fields); level++) {
		if (lua_getinfo(L, "Sl", &frame.fields) && frame.fields.currentline > 0) {
			frame.raw[DEBUG_RECORD_SIZE - 1] = '\0';
			_snprintf_s(where, size, _TRUNCATE, "%s:%d", frame.fields.short_src, frame.fields.currentline);
			return;
		}
	}
}

static BOOL already_logged(const char *line)
{
	int i;

	for (i = 0; i < logged_count; i++) {
		if (strcmp(logged[i], line) == 0)
			return TRUE;
	}
	return FALSE;
}

static HANDLE open_log(void)
{
	char path[MAX_PATH + sizeof log_name];
	DWORD length = GetModuleFileNameA((HMODULE)&__ImageBase, path, MAX_PATH);
	char *name;

	if (length == 0 || length >= MAX_PATH || !(name = strrchr(path, '\\')))
		return INVALID_HANDLE_VALUE;
	memcpy(name + 1, log_name, sizeof log_name);
	return CreateFileA(path, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, logged_count == 1 ? CREATE_ALWAYS : OPEN_ALWAYS,
		FILE_ATTRIBUTE_NORMAL, NULL);
}

static void write_log(const char *line)
{
	char text[LINE_SIZE + 16];
	SYSTEMTIME time;
	HANDLE file = open_log();
	DWORD written;

	if (file == INVALID_HANDLE_VALUE)
		return;
	GetLocalTime(&time);
	_snprintf_s(text, sizeof text, _TRUNCATE, "%02d:%02d:%02d %s\r\n", time.wHour, time.wMinute, time.wSecond, line);
	WriteFile(file, text, (DWORD)strlen(text), &written, NULL);
	CloseHandle(file);
}

void note_line(const char *line)
{
	if (logged_count == MAX_LOGGED || already_logged(line))
		return;
	strcpy_s(logged[logged_count++], LINE_SIZE, line);
	write_log(line);
}

void note_refusal(lua_State *L, const char *what, INT_PTR address)
{
	char where[CALLER_SIZE], line[LINE_SIZE];
	char *at;

	if (logged_count == MAX_LOGGED)
		return;
	caller_position(L, where, sizeof where);
	_snprintf_s(line, sizeof line, _TRUNCATE, "%s refused at %p, called from %s", function_name(L, what), (void *)address, where);
	for (at = line; *at; at++) {
		if ((BYTE)*at < ' ')
			*at = ' ';
	}
	note_line(line);
}

static void start_change(Change *change, const char *what, const char *where, const char *tag, INT_PTR address, size_t size)
{
	strncpy_s(change->what, sizeof change->what, what, _TRUNCATE);
	strncpy_s(change->where, sizeof change->where, where, _TRUNCATE);
	strncpy_s(change->tag, sizeof change->tag, tag, _TRUNCATE);
	change->low = address;
	change->high = address;
	change->end = address + (INT_PTR)size;
	change->size = size;
	change->spread = FALSE;
	change->count = 1;
	change->tick = GetTickCount64();
}

static void repeat_change(Change *change, INT_PTR address, size_t size)
{
	INT_PTR end = address + (INT_PTR)size;

	if (size != change->size)
		change->size = 0;
	if (address > change->end || end < change->low)
		change->spread = TRUE;
	if (end > change->end)
		change->end = end;
	if (address < change->low)
		change->low = address;
	if (address > change->high)
		change->high = address;
	change->count++;
	change->tick = GetTickCount64();
}

static BOOL same_caller(const Change *change, const char *what, const char *where, const char *tag)
{
	return change->count && strcmp(change->what, what) == 0 && strcmp(change->where, where) == 0 && strcmp(change->tag, tag) == 0;
}

static void note_patch(const char *what, const char *where, const char *tag, INT_PTR address, size_t size)
{
	PatchTable *table = tag[0] ? &owned_patches : &raw_patches;
	Change *last = &table->rows[MAX_PATCHES - 1];
	int i;

	for (i = 0; i < table->count; i++) {
		if (same_caller(&table->rows[i], what, where, tag)) {
			repeat_change(&table->rows[i], address, size);
			return;
		}
	}
	if (table->count < MAX_PATCHES) {
		start_change(&table->rows[table->count++], what, where, tag, address, size);
		return;
	}
	table->not_listed += last->count;
	start_change(last, what, where, tag, address, size);
}

static void note_write(const char *what, const char *where, const char *tag, INT_PTR address, size_t size)
{
	Change *last = &writes[(write_next + MAX_WRITES - 1) % MAX_WRITES];

	if (same_caller(last, what, where, tag)) {
		repeat_change(last, address, size);
		return;
	}
	start_change(&writes[write_next], what, where, tag, address, size);
	write_next = (write_next + 1) % MAX_WRITES;
}

void note_owned_change(lua_State *L, const char *what, INT_PTR address, size_t size, const char *tag)
{
	char where[CALLER_SIZE];

	caller_position(L, where, sizeof where);
	if (in_exe_code(address))
		note_patch(what, where, tag, address, size);
	else
		note_write(what, where, tag, address, size);
}

void note_change(lua_State *L, const char *what, INT_PTR address, size_t size)
{
	note_owned_change(L, what, address, size, "");
}

static void add_change(Text *report, const Change *change, ULONGLONG now)
{
	ULONGLONG ago = now - change->tick;

	add_text(report, "  %s", change->what);
	if (change->count > 1)
		add_text(report, " x%u", change->count);
	add_text(report, change->spread ? " spread between " : " at ");
	add_address(report, (ULONG_PTR)change->low);
	if (change->high != change->low) {
		add_text(report, change->spread ? " and " : " to ");
		add_address(report, (ULONG_PTR)change->high);
	}
	if (change->spread)
		add_text(report, " (not one block)");
	if (change->size)
		add_text(report, ", %llu bytes", (unsigned long long)change->size);
	add_text(report, ", from %s, last %llu.%llu s before", change->where, ago / 1000, ago % 1000 / 100);
	if (change->tag[0])
		add_text(report, ", by %s", change->tag);
	add_text(report, "\n");
}

static void add_patch_table(Text *report, const PatchTable *table, const char *not_listed, ULONGLONG now)
{
	int i;

	for (i = 0; i < table->count; i++) {
		if (i == MAX_PATCHES - 1 && table->not_listed)
			add_text(report, not_listed, table->not_listed);
		add_change(report, &table->rows[i], now);
	}
}

void add_changes(Text *report)
{
	ULONGLONG now = GetTickCount64();
	const Change *change;
	int i;

	if (raw_patches.count || owned_patches.count)
		add_text(report, "Game code patched by mods this session:\n");
	add_patch_table(report, &raw_patches, "  ... %u more patches not listed\n", now);
	add_patch_table(report, &owned_patches, "  ... %u more owned patches not listed\n", now);
	if (writes[(write_next + MAX_WRITES - 1) % MAX_WRITES].count)
		add_text(report, "Recent memory writes by mods, newest first:\n");
	for (i = 1; i <= MAX_WRITES; i++) {
		change = &writes[(write_next + MAX_WRITES - i) % MAX_WRITES];
		if (!change->count)
			break;
		add_change(report, change, now);
	}
}

void check_write(lua_State *L, int argument, const char *what, INT_PTR address, size_t size)
{
	if (in_hooked_prologue(address, size)) {
		note_refusal(L, what, address);
		luaL_argerror(L, argument, "refused: the first bytes of a hooked function run from the hook's copy, so a change there would never run");
	}
	note_change(L, function_name(L, what), address, size);
}
