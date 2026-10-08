#include <string.h>

#include "common.h"

enum {
	MAX_JUMPS = 4,
	JUMP_BYTES = 14,
	REGISTERS = 16,
	SEARCH_AROUND = 64,
	DUMP_BEFORE = 64,
	DUMP_BYTES = 128,
	LINE_BYTES = 16,
	USER_NAME_SIZE = 64,
	MIN_USER_NAME = 3
};

typedef struct {
	const char *dll;
	const char *name;
	ULONG_PTR code;
	const ULONG_PTR *import_slot;
} TimingFunction;

static TimingFunction timing[] = {
	{ "kernel32.dll", "QueryPerformanceCounter", 0, NULL },
	{ "kernel32.dll", "GetTickCount", 0, NULL },
	{ "kernel32.dll", "GetTickCount64", 0, NULL },
	{ "kernel32.dll", "Sleep", 0, NULL },
	{ "winmm.dll", "timeGetTime", 0, NULL }
};

static const char *known_programs[] = {
	"steamclient64.dll", "gameoverlayrenderer64.dll", "tier0_s64.dll", "vstdlib_s64.dll", "MpOav.dll",
	"DiscordHook64.dll", "NvTelemetryAPI64.dll", "NvTelemetryBridge64.dll", "RTSSHooks64.dll", "nvspcap64.dll"
};

static const char *private_marks[] = { ":\\", ":/", "\\users\\", "/users/" };

static char user_name[USER_NAME_SIZE];

BOOL is_known_program(const char *name)
{
	int i;

	for (i = 0; i < (int)(sizeof known_programs / sizeof known_programs[0]); i++) {
		if (_stricmp(known_programs[i], name) == 0)
			return TRUE;
	}
	return FALSE;
}

static const ULONG_PTR *slot_named(ULONG_PTR image, const IMAGE_IMPORT_DESCRIPTOR *entry, const char *name)
{
	const IMAGE_THUNK_DATA *names = (const IMAGE_THUNK_DATA *)(image + entry->OriginalFirstThunk);
	const ULONG_PTR *slots = (const ULONG_PTR *)(image + entry->FirstThunk);
	const IMAGE_IMPORT_BY_NAME *imported;
	int i;

	for (i = 0; names[i].u1.AddressOfData; i++) {
		if (IMAGE_SNAP_BY_ORDINAL(names[i].u1.Ordinal))
			continue;
		imported = (const IMAGE_IMPORT_BY_NAME *)(image + names[i].u1.AddressOfData);
		if (strcmp(imported->Name, name) == 0)
			return &slots[i];
	}
	return NULL;
}

static const ULONG_PTR *import_slot(const char *dll, const char *name)
{
	ULONG_PTR image = (ULONG_PTR)GetModuleHandleW(NULL);
	const IMAGE_DATA_DIRECTORY *directory = &game_headers()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
	const IMAGE_IMPORT_DESCRIPTOR *entry;

	if (!directory->VirtualAddress)
		return NULL;
	for (entry = (const IMAGE_IMPORT_DESCRIPTOR *)(image + directory->VirtualAddress); entry->Name; entry++) {
		if (entry->OriginalFirstThunk && _stricmp((const char *)(image + entry->Name), dll) == 0)
			return slot_named(image, entry, name);
	}
	return NULL;
}

void prepare_clues(void)
{
	HMODULE module;
	DWORD length = GetEnvironmentVariableA("USERNAME", user_name, sizeof user_name);
	int i;

	if (length >= sizeof user_name)
		user_name[0] = '\0';
	for (i = 0; i < (int)(sizeof timing / sizeof timing[0]); i++) {
		module = GetModuleHandleA(timing[i].dll);
		timing[i].code = module ? (ULONG_PTR)GetProcAddress(module, timing[i].name) : 0;
		__try {
			timing[i].import_slot = import_slot(timing[i].dll, timing[i].name);
		} __except (EXCEPTION_EXECUTE_HANDLER) {
			timing[i].import_slot = NULL;
		}
	}
}

static ULONG_PTR read_pointer(ULONG_PTR address)
{
	ULONG_PTR value = 0;

	return copy_memory(&value, (INT_PTR)address, sizeof value) ? value : 0;
}

static ULONG_PTR jump_target(ULONG_PTR at)
{
	BYTE code[JUMP_BYTES];
	INT32 distance;
	ULONG_PTR target;

	if (!copy_memory(code, (INT_PTR)at, sizeof code))
		return 0;
	memcpy(&distance, code + 1, sizeof distance);
	if (code[0] == 0xE9)
		return at + 5 + distance;
	if (code[0] == 0xEB)
		return at + 2 + (INT8)code[1];
	memcpy(&distance, code + 2, sizeof distance);
	if (code[0] == 0xFF && code[1] == 0x25)
		return read_pointer(at + 6 + distance);
	memcpy(&distance, code + 3, sizeof distance);
	if (code[0] == 0x48 && code[1] == 0xFF && code[2] == 0x25)
		return read_pointer(at + 7 + distance);
	memcpy(&target, code + 2, sizeof target);
	if (code[0] == 0x48 && code[1] == 0xB8 && code[10] == 0xFF && code[11] == 0xE0)
		return target;
	if (code[0] == 0x49 && code[1] == 0xBB && code[10] == 0x41 && code[11] == 0xFF && code[12] == 0xE3)
		return target;
	return 0;
}

static const char *hooker_of(ULONG_PTR address)
{
	const char *name = other_program_at(address);
	int hop;

	for (hop = 0; !name && hop < MAX_JUMPS && (address = jump_target(address)) != 0; hop++)
		name = other_program_at(address);
	return name;
}

static const char *timing_hooker(const TimingFunction *function)
{
	const char *by = function->code ? hooker_of(function->code) : NULL;

	if (!by && function->import_slot)
		by = hooker_of(read_pointer((ULONG_PTR)function->import_slot));
	return by;
}

void add_timing_hooks(Text *text)
{
	const char *by;
	int i, found = 0;

	for (i = 0; i < (int)(sizeof timing / sizeof timing[0]); i++) {
		by = timing_hooker(&timing[i]);
		if (!by)
			continue;
		if (!found++)
			add_text(text, "Other programs' DLLs that hook timing functions the game uses:\n");
		add_text(text, "  %s hooks %s\n", by, timing[i].name);
	}
	if (!found)
		add_text(text, "No other program's DLL hooks the game's timing functions\n");
}

static BOOL holds_value(ULONG_PTR around, ULONG_PTR value, ULONG_PTR *at)
{
	ULONG_PTR spot;

	for (spot = (around - SEARCH_AROUND) & ~(ULONG_PTR)7; spot <= around + SEARCH_AROUND; spot += sizeof spot) {
		if (read_pointer(spot) == value) {
			*at = spot;
			return TRUE;
		}
	}
	return FALSE;
}

static int holder_of(const DWORD64 *values, ULONG_PTR bad, ULONG_PTR *at)
{
	int i;

	for (i = 0; i < REGISTERS; i++) {
		if (is_heap_pointer((ULONG_PTR)values[i]) && holds_value((ULONG_PTR)values[i], bad, at))
			return i;
	}
	return -1;
}

static BOOL looks_like_text(ULONG_PTR value)
{
	return wide_text_length((const BYTE *)&value, sizeof value / 2) == sizeof value / 2;
}

static BOOL is_wide_line(const BYTE *line)
{
	int i, printable = 0;

	for (i = 0; i < LINE_BYTES; i += 2) {
		if (line[i + 1])
			return FALSE;
		if (is_printable(line[i]))
			printable++;
	}
	return printable >= 2;
}

static void line_text(const BYTE *line, char *out)
{
	int step = is_wide_line(line) ? 2 : 1, i, n = 0;

	for (i = 0; i < LINE_BYTES; i += step)
		out[n++] = is_printable(line[i]) ? (char)line[i] : '.';
	out[n] = '\0';
}

static BOOL contains_ignoring_case(const char *text, const char *part)
{
	size_t length = strlen(part), i;

	for (i = 0; length && text[i]; i++) {
		if (_strnicmp(text + i, part, length) == 0)
			return TRUE;
	}
	return FALSE;
}

static BOOL is_private(const char *text)
{
	int i;

	for (i = 0; i < (int)(sizeof private_marks / sizeof private_marks[0]); i++) {
		if (contains_ignoring_case(text, private_marks[i]))
			return TRUE;
	}
	return strlen(user_name) >= MIN_USER_NAME && contains_ignoring_case(text, user_name);
}

static int read_dump(ULONG_PTR start, BYTE *bytes, char *seen)
{
	char text[LINE_BYTES + 1];
	int lines = 0;

	seen[0] = '\0';
	while (lines < DUMP_BYTES / LINE_BYTES &&
		copy_memory(bytes + lines * LINE_BYTES, (INT_PTR)(start + lines * LINE_BYTES), LINE_BYTES)) {
		line_text(bytes + lines * LINE_BYTES, text);
		strcat_s(seen, DUMP_BYTES + 1, text);
		lines++;
	}
	return lines;
}

static void add_dump(Text *text, ULONG_PTR center)
{
	BYTE bytes[DUMP_BYTES];
	char seen[DUMP_BYTES + 1], shown[LINE_BYTES + 1];
	ULONG_PTR start = (center - DUMP_BEFORE) & ~(ULONG_PTR)(LINE_BYTES - 1), at;
	int lines = read_dump(start, bytes, seen), line, i;

	if (is_private(seen)) {
		add_text(text, "  (left out: it holds a file path or the Windows user name)\n");
		return;
	}
	for (line = 0; line < lines; line++) {
		at = start + line * LINE_BYTES;
		add_text(text, "  %s%016llx ", center >= at && center < at + LINE_BYTES ? ">" : " ", (unsigned long long)at);
		for (i = 0; i < LINE_BYTES; i++)
			add_text(text, " %02X", bytes[line * LINE_BYTES + i]);
		line_text(bytes + line * LINE_BYTES, shown);
		add_text(text, "  %s\n", shown);
	}
}

static BOOL add_holder(Text *text, const DWORD64 *values, ULONG_PTR bad, const char *what)
{
	ULONG_PTR at;
	int holder = holder_of(values, bad, &at);

	if (holder < 0)
		return FALSE;
	add_text(text, "Memory around %s%+lld, which holds the bad value of %s:\n", register_name(holder),
		(long long)(at - (ULONG_PTR)values[holder]), what);
	add_dump(text, at);
	return TRUE;
}

static BOOL add_bad_registers(Text *text, const DWORD64 *values, BOOL text_only)
{
	int i;

	for (i = 0; i < REGISTERS; i++) {
		if (is_bad_pointer((ULONG_PTR)values[i]) && looks_like_text((ULONG_PTR)values[i]) == text_only &&
			add_holder(text, values, (ULONG_PTR)values[i], register_name(i)))
			return TRUE;
	}
	return FALSE;
}

void add_damaged_memory(Text *text, const CONTEXT *context, const EXCEPTION_RECORD *record)
{
	const DWORD64 *values = &context->Rax;
	ULONG_PTR fault = 0;

	if (record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && record->NumberParameters >= 2)
		fault = record->ExceptionInformation[1];
	if (add_bad_registers(text, values, TRUE) || add_bad_registers(text, values, FALSE))
		return;
	if (fault && is_bad_pointer(fault) && add_holder(text, values, fault, "the fault address"))
		return;
	if (fault && is_heap_pointer(fault)) {
		add_text(text, "Memory at the fault address:\n");
		add_dump(text, fault);
	}
}
