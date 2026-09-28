#include <string.h>

#include "common.h"

enum { MAX_PATTERN_SIZE = 256 };

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

static void parse_pattern(lua_State *L, const char *text, Pattern *pattern)
{
	pattern->size = 0;
	while (*text) {
		if (*text == ' ') {
			text++;
			continue;
		}
		if (pattern->size == MAX_PATTERN_SIZE)
			luaL_error(L, "pattern longer than %d bytes", MAX_PATTERN_SIZE);
		if (*text == '?') {
			pattern->known[pattern->size] = FALSE;
			text += text[1] == '?' ? 2 : 1;
		} else {
			int high = hex_digit(text[0]);
			int low = high < 0 ? -1 : hex_digit(text[1]);
			if (low < 0)
				luaL_argerror(L, 1, "expected hex bytes and ?? separated by spaces");
			pattern->bytes[pattern->size] = (BYTE)(high << 4 | low);
			pattern->known[pattern->size] = TRUE;
			text += 2;
		}
		pattern->size++;
	}
	if (pattern->size == 0 || !pattern->known[0])
		luaL_argerror(L, 1, "pattern must start with a byte, not ??");
}

static BOOL matches_at(const BYTE *memory, const Pattern *pattern)
{
	size_t i;
	for (i = 1; i < pattern->size; i++)
		if (pattern->known[i] && memory[i] != pattern->bytes[i])
			return FALSE;
	return TRUE;
}

static void scan_memory(const BYTE *start, size_t size, const Pattern *pattern, Matches *matches)
{
	const BYTE *last = start + size - pattern->size;
	const BYTE *at;

	if (size < pattern->size)
		return;
	for (at = start; at <= last; at++) {
		at = memchr(at, pattern->bytes[0], (size_t)(last - at) + 1);
		if (!at)
			return;
		if (matches_at(at, pattern)) {
			if (!matches->first)
				matches->first = at;
			matches->count++;
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
	MEMORY_BASIC_INFORMATION region;

	while (start < end && VirtualQuery(start, &region, sizeof region)) {
		const BYTE *region_end = (const BYTE *)region.BaseAddress + region.RegionSize;
		if (region_end > end)
			region_end = end;
		if (is_readable(&region))
			scan_memory(start, (size_t)(region_end - start), pattern, matches);
		start = region_end;
	}
}

static BOOL is_code(const IMAGE_SECTION_HEADER *section)
{
	return (section->Characteristics & IMAGE_SCN_MEM_EXECUTE) && !(section->Characteristics & IMAGE_SCN_MEM_WRITE);
}

static int l_find_pattern(lua_State *L)
{
	const BYTE *base = (const BYTE *)GetModuleHandleA(NULL);
	const IMAGE_NT_HEADERS *headers = (const IMAGE_NT_HEADERS *)(base + ((const IMAGE_DOS_HEADER *)base)->e_lfanew);
	const IMAGE_SECTION_HEADER *section = IMAGE_FIRST_SECTION(headers);
	Matches matches = { NULL, 0 };
	Pattern pattern;
	WORD i;

	parse_pattern(L, luaL_checkstring(L, 1), &pattern);
	for (i = 0; i < headers->FileHeader.NumberOfSections; i++, section++)
		if (is_code(section))
			scan_section(base + section->VirtualAddress, section->Misc.VirtualSize, &pattern, &matches);

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
