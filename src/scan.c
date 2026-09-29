#include <string.h>

#include "common.h"

enum { MAX_PATTERN_SIZE = 256 };

enum PatternError { PATTERN_OK, PATTERN_TOO_LONG, PATTERN_BAD_BYTE, PATTERN_STARTS_UNKNOWN };

static const DWORD READABLE_PAGES = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ |
	PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;

typedef struct {
	BYTE bytes[MAX_PATTERN_SIZE];
	BOOL known[MAX_PATTERN_SIZE];
	size_t size;
} Pattern;

typedef struct {
	const BYTE *first;
	int count;
} Matches;

static int hex_digit(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

static int parse_pattern(const char *text, Pattern *pattern)
{
	pattern->size = 0;
	while (*text) {
		if (*text == ' ') {
			text++;
			continue;
		}
		if (pattern->size == MAX_PATTERN_SIZE)
			return PATTERN_TOO_LONG;
		if (*text == '?') {
			pattern->known[pattern->size] = FALSE;
			text += text[1] == '?' ? 2 : 1;
		} else {
			int high = hex_digit(text[0]);
			int low = high < 0 ? -1 : hex_digit(text[1]);
			if (low < 0)
				return PATTERN_BAD_BYTE;
			pattern->bytes[pattern->size] = (BYTE)(high << 4 | low);
			pattern->known[pattern->size] = TRUE;
			text += 2;
		}
		pattern->size++;
	}
	if (pattern->size == 0 || !pattern->known[0])
		return PATTERN_STARTS_UNKNOWN;
	return PATTERN_OK;
}

static BOOL matches_at(const BYTE *memory, const Pattern *pattern)
{
	size_t i;
	for (i = 1; i < pattern->size; i++)
		if (pattern->known[i] && memory[i] != pattern->bytes[i])
			return FALSE;
	return TRUE;
}

static void add_match(Matches *matches, const BYTE *at)
{
	if (!matches->first || at < matches->first)
		matches->first = at;
	matches->count++;
}

static int saved_window(INT_PTR at, size_t size)
{
	SavedCode code;
	int i;

	for (i = 0; saved_code(i, &code); i++) {
		if (at < code.start + SAVED_BYTES && code.start < at + (INT_PTR)size)
			return i;
	}
	return -1;
}

static BOOL original_byte(INT_PTR address, const SavedCode *likely, BYTE *byte)
{
	SavedCode code;
	int i;

	if (address >= likely->start && address < likely->start + SAVED_BYTES) {
		*byte = likely->bytes[address - likely->start];
		return TRUE;
	}
	for (i = 0; saved_code(i, &code); i++) {
		if (address >= code.start && address < code.start + SAVED_BYTES) {
			*byte = code.bytes[address - code.start];
			return TRUE;
		}
	}
	return copy_memory(byte, address, 1);
}

static BOOL matches_original(INT_PTR at, const Pattern *pattern, const SavedCode *likely)
{
	size_t i;
	BYTE byte;

	for (i = 0; i < pattern->size; i++) {
		if (!pattern->known[i])
			continue;
		if (!original_byte(at + (INT_PTR)i, likely, &byte) || byte != pattern->bytes[i])
			return FALSE;
	}
	return TRUE;
}

static void scan_memory(const BYTE *start, size_t size, const Pattern *pattern, Matches *matches)
{
	const BYTE *last;
	const BYTE *at;

	if (size < pattern->size)
		return;
	last = start + size - pattern->size;
	for (at = start; at <= last; at++) {
		at = memchr(at, pattern->bytes[0], (size_t)(last - at) + 1);
		if (!at)
			return;
		if (matches_at(at, pattern) && saved_window((INT_PTR)at, pattern->size) < 0)
			add_match(matches, at);
	}
}

static void scan_hooked_code(const BYTE *start, size_t size, const Pattern *pattern, Matches *matches)
{
	INT_PTR first = (INT_PTR)start, last = (INT_PTR)(start + size) - (INT_PTR)pattern->size;
	SavedCode code;
	INT_PTR at;
	int i;

	for (i = 0; saved_code(i, &code); i++) {
		for (at = code.start - (INT_PTR)pattern->size + 1; at < code.start + SAVED_BYTES; at++) {
			if (at >= first && at <= last && matches_original(at, pattern, &code) &&
				saved_window(at, pattern->size) == i)
				add_match(matches, (const BYTE *)at);
		}
	}
}

static BOOL is_readable(const MEMORY_BASIC_INFORMATION *region)
{
	return region->State == MEM_COMMIT && (region->Protect & READABLE_PAGES) && !(region->Protect & PAGE_GUARD);
}

static void scan_section(const BYTE *start, size_t size, const Pattern *pattern, Matches *matches)
{
	const BYTE *end = start + size;
	const BYTE *readable = NULL;
	MEMORY_BASIC_INFORMATION region;

	while (start < end && VirtualQuery(start, &region, sizeof region)) {
		const BYTE *region_end = (const BYTE *)region.BaseAddress + region.RegionSize;
		if (region_end > end)
			region_end = end;
		if (is_readable(&region) && !readable)
			readable = start;
		if (!is_readable(&region) && readable) {
			scan_memory(readable, (size_t)(start - readable), pattern, matches);
			readable = NULL;
		}
		start = region_end;
	}
	if (readable)
		scan_memory(readable, (size_t)(start - readable), pattern, matches);
}

static BOOL is_code(const IMAGE_SECTION_HEADER *section)
{
	return (section->Characteristics & IMAGE_SCN_MEM_EXECUTE) && !(section->Characteristics & IMAGE_SCN_MEM_WRITE);
}

static void scan_code(const Pattern *pattern, Matches *matches)
{
	const BYTE *base = (const BYTE *)GetModuleHandleA(NULL);
	const IMAGE_NT_HEADERS *headers = (const IMAGE_NT_HEADERS *)(base + ((const IMAGE_DOS_HEADER *)base)->e_lfanew);
	const IMAGE_SECTION_HEADER *section = IMAGE_FIRST_SECTION(headers);
	WORD i;

	for (i = 0; i < headers->FileHeader.NumberOfSections; i++, section++) {
		if (is_code(section)) {
			scan_section(base + section->VirtualAddress, section->Misc.VirtualSize, pattern, matches);
			scan_hooked_code(base + section->VirtualAddress, section->Misc.VirtualSize, pattern, matches);
		}
	}
}

const BYTE *find_code(const char *text, int *count)
{
	Matches matches = { NULL, 0 };
	Pattern pattern;

	*count = 0;
	if (parse_pattern(text, &pattern) != PATTERN_OK)
		return NULL;
	scan_code(&pattern, &matches);
	*count = matches.count;
	return matches.first;
}

static int l_find_pattern(lua_State *L)
{
	Matches matches = { NULL, 0 };
	Pattern pattern;

	switch (parse_pattern(luaL_checkstring(L, 1), &pattern)) {
	case PATTERN_TOO_LONG:
		return luaL_error(L, "pattern longer than %d bytes", MAX_PATTERN_SIZE);
	case PATTERN_BAD_BYTE:
		return luaL_argerror(L, 1, "expected hex bytes and ?? separated by spaces");
	case PATTERN_STARTS_UNKNOWN:
		return luaL_argerror(L, 1, "pattern must start with a byte, not ??");
	}
	scan_code(&pattern, &matches);
	if (matches.first)
		push_value(L, VALUE_POINTER, (INT_PTR)matches.first);
	else
		lua_pushnil(L);
	lua_pushnumber(L, (lua_Number)matches.count);
	return 2;
}

const luaL_Reg scan_functions[] = {
	{ "find_pattern", l_find_pattern },
	{ NULL, NULL }
};
