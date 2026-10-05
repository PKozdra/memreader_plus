#include <stdio.h>
#include <string.h>

#include "common.h"

enum { MAX_LOGGED = 32, WHERE_SIZE = 160, LINE_SIZE = 320, MAX_CALLER_LEVELS = 8 };

enum { MAX_WRITES = 24, MAX_PATCHES = 32, WHAT_SIZE = 24 };

enum { EXECUTABLE = PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY };

extern IMAGE_DOS_HEADER __ImageBase;

static const char log_name[] = "memreader_plus_refused.txt";
static const WORD exe_tables[] = {
	IMAGE_DIRECTORY_ENTRY_EXPORT, IMAGE_DIRECTORY_ENTRY_IMPORT, IMAGE_DIRECTORY_ENTRY_IAT, IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT
};
typedef struct {
	INT_PTR low;
	INT_PTR high;
	size_t size;
	UINT32 count;
	ULONGLONG tick;
	char what[WHAT_SIZE];
	char where[WHERE_SIZE];
} Change;

static char logged[MAX_LOGGED][LINE_SIZE];
static int logged_count;
static Change writes[MAX_WRITES];
static int write_next;
static Change patches[MAX_PATCHES];
static int patch_count;

static BOOL overlaps(INT_PTR address, size_t size, INT_PTR start, INT_PTR end)
{
	return address < end && address + (INT_PTR)size > start;
}

static BOOL in_exe_tables(INT_PTR address, size_t size)
{
	INT_PTR base = (INT_PTR)GetModuleHandleA(NULL);
	const IMAGE_OPTIONAL_HEADER *header = &game_headers()->OptionalHeader;
	const IMAGE_DATA_DIRECTORY *table;
	int i;

	if (overlaps(address, size, base, base + (INT_PTR)header->SizeOfHeaders))
		return TRUE;
	for (i = 0; i < (int)(sizeof exe_tables / sizeof exe_tables[0]); i++) {
		table = &header->DataDirectory[exe_tables[i]];
		if (table->Size && overlaps(address, size, base + table->VirtualAddress, base + table->VirtualAddress + table->Size))
			return TRUE;
	}
	return FALSE;
}

static BOOL is_data_memory(INT_PTR address, size_t size)
{
	MEMORY_BASIC_INFORMATION region;
	INT_PTR at = address;

	while (at < address + (INT_PTR)size) {
		if (!VirtualQuery((LPCVOID)at, &region, sizeof region))
			return TRUE;
		if (region.State == MEM_COMMIT && (region.Type == MEM_IMAGE || (region.Protect & EXECUTABLE)))
			return FALSE;
		at = (INT_PTR)region.BaseAddress + (INT_PTR)region.RegionSize;
	}
	return TRUE;
}

BOOL may_write(INT_PTR address, size_t size)
{
	if (in_game_image(address, size))
		return !in_exe_tables(address, size);
	return is_data_memory(address, size);
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

static void caller_position(lua_State *L, char *where, size_t size)
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

void note_refusal(lua_State *L, const char *what, INT_PTR address)
{
	char where[WHERE_SIZE], line[LINE_SIZE];
	char *at;

	if (logged_count == MAX_LOGGED)
		return;
	caller_position(L, where, sizeof where);
	_snprintf_s(line, sizeof line, _TRUNCATE, "%s refused at %p, called from %s", function_name(L, what), (void *)address, where);
	for (at = line; *at; at++) {
		if ((BYTE)*at < ' ')
			*at = ' ';
	}
	if (already_logged(line))
		return;
	strcpy_s(logged[logged_count++], LINE_SIZE, line);
	write_log(line);
}

static void start_change(Change *change, const char *what, const char *where, INT_PTR address, size_t size)
{
	strncpy_s(change->what, sizeof change->what, what, _TRUNCATE);
	strncpy_s(change->where, sizeof change->where, where, _TRUNCATE);
	change->low = address;
	change->high = address;
	change->size = size;
	change->count = 1;
	change->tick = GetTickCount64();
}

static void repeat_change(Change *change, INT_PTR address)
{
	if (address < change->low)
		change->low = address;
	if (address > change->high)
		change->high = address;
	change->count++;
	change->tick = GetTickCount64();
}

static BOOL same_caller(const Change *change, const char *what, const char *where)
{
	return change->count && strcmp(change->what, what) == 0 && strcmp(change->where, where) == 0;
}

static void note_patch(const char *what, const char *where, INT_PTR address, size_t size)
{
	int i;

	for (i = 0; i < patch_count; i++) {
		if (patches[i].low == address && same_caller(&patches[i], what, where)) {
			repeat_change(&patches[i], address);
			return;
		}
	}
	if (patch_count < MAX_PATCHES)
		start_change(&patches[patch_count++], what, where, address, size);
}

static void note_write(const char *what, const char *where, INT_PTR address, size_t size)
{
	Change *last = &writes[(write_next + MAX_WRITES - 1) % MAX_WRITES];

	if (same_caller(last, what, where)) {
		repeat_change(last, address);
		return;
	}
	start_change(&writes[write_next], what, where, address, size);
	write_next = (write_next + 1) % MAX_WRITES;
}

void note_change(lua_State *L, const char *what, INT_PTR address, size_t size)
{
	char where[WHERE_SIZE];

	caller_position(L, where, sizeof where);
	if (in_exe_code(address))
		note_patch(what, where, address, size);
	else
		note_write(what, where, address, size);
}

static void add_change(Text *report, const Change *change, ULONGLONG now)
{
	ULONGLONG ago = now - change->tick;

	add_text(report, "  %s", change->what);
	if (change->count > 1)
		add_text(report, " x%u", change->count);
	add_text(report, " at ");
	add_address(report, (ULONG_PTR)change->low);
	if (change->high != change->low) {
		add_text(report, " to ");
		add_address(report, (ULONG_PTR)change->high);
	}
	if (change->size)
		add_text(report, ", %llu bytes", (unsigned long long)change->size);
	add_text(report, ", from %s, last %llu.%llu s before\n", change->where, ago / 1000, ago % 1000 / 100);
}

void add_changes(Text *report)
{
	ULONGLONG now = GetTickCount64();
	const Change *change;
	int i;

	if (patch_count)
		add_text(report, "Game code patched by mods this session:\n");
	for (i = 0; i < patch_count; i++)
		add_change(report, &patches[i], now);
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
	if (may_write(address, size)) {
		note_change(L, function_name(L, what), address, size);
		return;
	}
	note_refusal(L, what, address);
	luaL_argerror(L, argument, "refused: Plus writes only to the game's exe and to data memory, not to other modules, executable memory or the exe's headers and import or export tables");
}
