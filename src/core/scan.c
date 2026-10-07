#include <emmintrin.h>
#include <intrin.h>
#include <string.h>

#include "common.h"

enum {
	MAX_PATTERN_SIZE = 256,
	MAX_PATTERNS = 64,
	MAX_FOUND = 8,
	MAX_SAVED_CODE = 4096,
	MAX_CACHED = 1024,
	MAX_ORIGINAL_READ = 4096,
	HEAD_SIZE = 8,
	BLOCK_SIZE = 16,
	CALL_OPCODE = 0xE8,
	CALL_SIZE = 5
};

enum {
	INDIRECT_ENTRY = 1,
	UNWIND_FLAGS_SHIFT = 3,
	UNWIND_CHAIN_INFO = 4,
	UNWIND_HEADER_SIZE = 4,
	UNWIND_CODE_SIZE = 2,
	MAX_CHAIN_LENGTH = 32
};

enum PatternError { PATTERN_OK, PATTERN_TOO_LONG, PATTERN_BAD_BYTE, PATTERN_STARTS_UNKNOWN };

static const DWORD READABLE_PAGES = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ |
	PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;

typedef struct {
	BYTE bytes[MAX_PATTERN_SIZE];
	BYTE known[MAX_PATTERN_SIZE];
	size_t size;
	UINT64 head;
	UINT64 head_mask;
	int next;
} Pattern;

typedef struct {
	BYTE first;
	BYTE second;
	BOOL any_second;
	int patterns;
} Lead;

typedef struct {
	const BYTE *first;
	const BYTE *found[MAX_FOUND];
	int count;
} Matches;

typedef struct {
	Pattern patterns[MAX_PATTERNS];
	Matches matches[MAX_PATTERNS];
	Lead leads[MAX_PATTERNS];
	int count;
	int lead_count;
} Search;

typedef struct {
	INT_PTR start;
	BYTE bytes[SAVED_BYTES];
} SavedCode;

typedef struct {
	char *text;
	Matches matches;
} CachedSearch;

static Search search;
static SavedCode saved[MAX_SAVED_CODE];
static int saved_count;
static BOOL saved_full;
static CachedSearch cache[MAX_CACHED];
static int cache_count;
static INT_PTR cache_base;

void capture_code(INT_PTR address, BYTE *window)
{
	if (!copy_memory(window, address - SAVED_BYTES / 2, SAVED_BYTES))
		memset(window, 0, SAVED_BYTES);
}

static int saved_index(INT_PTR address)
{
	int i;

	for (i = 0; i < saved_count; i++) {
		if (address >= saved[i].start && address < saved[i].start + SAVED_BYTES)
			return i;
	}
	return -1;
}

static BOOL is_saved(INT_PTR address, size_t size)
{
	size_t i;

	for (i = 0; i < size; i++) {
		if (saved_index(address + (INT_PTR)i) < 0)
			return FALSE;
	}
	return TRUE;
}

static void report_full(void)
{
	char line[192];

	if (saved_full)
		return;
	saved_full = TRUE;
	_snprintf_s(line, sizeof line, _TRUNCATE,
		"saved original code is full (%d ranges): find_pattern and read_original no longer see the original bytes of code changed from now on",
		MAX_SAVED_CODE);
	note_line(line);
}

void remember_code(INT_PTR address, const BYTE *window)
{
	if (is_saved(address, SAVED_BYTES / 2))
		return;
	if (saved_count == MAX_SAVED_CODE) {
		report_full();
		return;
	}
	saved[saved_count].start = address - SAVED_BYTES / 2;
	memcpy(saved[saved_count].bytes, window, SAVED_BYTES);
	saved_count++;
}

void remember_original(INT_PTR address, size_t size)
{
	BYTE window[SAVED_BYTES];
	size_t offset;

	for (offset = 0; offset < size; offset += SAVED_BYTES / 2) {
		capture_code(address + (INT_PTR)offset, window);
		remember_code(address + (INT_PTR)offset, window);
	}
}

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

static void set_head(Pattern *pattern)
{
	size_t i;

	pattern->head = 0;
	pattern->head_mask = 0;
	for (i = 0; i < HEAD_SIZE && i < pattern->size; i++) {
		if (pattern->known[i]) {
			pattern->head |= (UINT64)pattern->bytes[i] << (8 * i);
			pattern->head_mask |= (UINT64)0xFF << (8 * i);
		}
	}
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
			pattern->bytes[pattern->size] = 0;
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
	set_head(pattern);
	return PATTERN_OK;
}

static BOOL fits_lead(const Lead *lead, const Pattern *pattern)
{
	BOOL any_second = pattern->size < 2 || !pattern->known[1];

	return lead->first == pattern->bytes[0] && (lead->any_second || (!any_second && lead->second == pattern->bytes[1]));
}

static void add_to_lead(Pattern *pattern)
{
	Lead *lead;
	int i;

	for (i = 0; i < search.lead_count && !fits_lead(&search.leads[i], pattern); i++)
		;
	lead = &search.leads[i];
	if (i == search.lead_count) {
		lead->first = pattern->bytes[0];
		lead->any_second = pattern->size < 2 || !pattern->known[1];
		lead->second = lead->any_second ? 0 : pattern->bytes[1];
		lead->patterns = -1;
		search.lead_count++;
	}
	pattern->next = lead->patterns;
	lead->patterns = (int)(pattern - search.patterns);
}

static void start_search(void)
{
	memset(search.matches, 0, sizeof search.matches);
	search.count = 0;
	search.lead_count = 0;
}

static int add_pattern(const char *text)
{
	Pattern *pattern = &search.patterns[search.count];
	int error = parse_pattern(text, pattern);

	if (error != PATTERN_OK)
		return error;
	add_to_lead(pattern);
	search.count++;
	return PATTERN_OK;
}

static int saved_window(INT_PTR at, size_t size)
{
	int i;

	for (i = 0; i < saved_count; i++) {
		if (at < saved[i].start + SAVED_BYTES && saved[i].start < at + (INT_PTR)size)
			return i;
	}
	return -1;
}

static void add_match(Matches *matches, const BYTE *at)
{
	if (!matches->first || at < matches->first)
		matches->first = at;
	if (matches->count < MAX_FOUND)
		matches->found[matches->count] = at;
	matches->count++;
}

static BOOL matches_at(const BYTE *memory, const Pattern *pattern)
{
	size_t i;

	for (i = 1; i < pattern->size; i++) {
		if (pattern->known[i] && memory[i] != pattern->bytes[i])
			return FALSE;
	}
	return TRUE;
}

static void check_lead(const Lead *lead, const BYTE *at, const BYTE *end)
{
	int i;

	for (i = lead->patterns; i >= 0; i = search.patterns[i].next) {
		const Pattern *pattern = &search.patterns[i];

		if (at + pattern->size > end)
			continue;
		if (at + HEAD_SIZE <= end && (*(const UINT64 *)at & pattern->head_mask) != pattern->head)
			continue;
		if (matches_at(at, pattern) && saved_window((INT_PTR)at, pattern->size) < 0)
			add_match(&search.matches[i], at);
	}
}

static unsigned lead_hits(const Lead *lead, const BYTE *block)
{
	__m128i hits = _mm_cmpeq_epi8(_mm_loadu_si128((const __m128i *)block), _mm_set1_epi8((char)lead->first));

	if (!lead->any_second) {
		__m128i next = _mm_loadu_si128((const __m128i *)(block + 1));
		hits = _mm_and_si128(hits, _mm_cmpeq_epi8(next, _mm_set1_epi8((char)lead->second)));
	}
	return (unsigned)_mm_movemask_epi8(hits);
}

static void scan_block(const BYTE *block, const BYTE *end)
{
	int i;

	for (i = 0; i < search.lead_count; i++) {
		unsigned hits = lead_hits(&search.leads[i], block);

		while (hits) {
			unsigned long bit;

			_BitScanForward(&bit, hits);
			hits &= hits - 1;
			check_lead(&search.leads[i], block + bit, end);
		}
	}
}

static void scan_tail(const BYTE *at, const BYTE *end)
{
	int i;

	for (; at < end; at++) {
		for (i = 0; i < search.lead_count; i++) {
			const Lead *lead = &search.leads[i];

			if (*at == lead->first && (lead->any_second || (at + 1 < end && at[1] == lead->second)))
				check_lead(lead, at, end);
		}
	}
}

static void scan_memory(const BYTE *start, const BYTE *end)
{
	const BYTE *block = start;

	for (; block + BLOCK_SIZE + 1 <= end; block += BLOCK_SIZE)
		scan_block(block, end);
	scan_tail(block, end);
}

static BOOL is_readable(const MEMORY_BASIC_INFORMATION *region)
{
	return region->State == MEM_COMMIT && (region->Protect & READABLE_PAGES) && !(region->Protect & PAGE_GUARD);
}

static void scan_section(const BYTE *start, const BYTE *end)
{
	const BYTE *readable = NULL;
	MEMORY_BASIC_INFORMATION region;

	while (start < end && VirtualQuery(start, &region, sizeof region)) {
		const BYTE *region_end = (const BYTE *)region.BaseAddress + region.RegionSize;

		if (region_end > end)
			region_end = end;
		if (is_readable(&region) && !readable)
			readable = start;
		if (!is_readable(&region) && readable) {
			scan_memory(readable, start);
			readable = NULL;
		}
		start = region_end;
	}
	if (readable)
		scan_memory(readable, start);
}

static BOOL original_byte(INT_PTR address, BYTE *byte)
{
	int i = saved_index(address);

	if (i >= 0) {
		*byte = saved[i].bytes[address - saved[i].start];
		return TRUE;
	}
	return copy_memory(byte, address, 1);
}

static void overlay_saved(const SavedCode *code, INT_PTR address, BYTE *out, size_t size)
{
	INT_PTR from = code->start > address ? code->start : address;
	INT_PTR to = code->start + SAVED_BYTES;

	if (to > address + (INT_PTR)size)
		to = address + (INT_PTR)size;
	if (from < to)
		memcpy(out + (from - address), code->bytes + (from - code->start), (size_t)(to - from));
}

static BOOL copy_original(INT_PTR address, BYTE *out, size_t size)
{
	int i;

	if (!copy_memory(out, address, size))
		return FALSE;
	for (i = saved_count - 1; i >= 0; i--)
		overlay_saved(&saved[i], address, out, size);
	return TRUE;
}

static BOOL matches_original(INT_PTR at, const Pattern *pattern)
{
	size_t i;
	BYTE byte;

	for (i = 0; i < pattern->size; i++) {
		if (!pattern->known[i])
			continue;
		if (!original_byte(at + (INT_PTR)i, &byte) || byte != pattern->bytes[i])
			return FALSE;
	}
	return TRUE;
}

static void scan_saved_code(const BYTE *start, const BYTE *end)
{
	int i, p;

	for (i = 0; i < saved_count; i++) {
		for (p = 0; p < search.count; p++) {
			const Pattern *pattern = &search.patterns[p];
			INT_PTR at = saved[i].start - (INT_PTR)pattern->size + 1;
			INT_PTR last = (INT_PTR)end - (INT_PTR)pattern->size;

			for (; at < saved[i].start + SAVED_BYTES; at++) {
				if (at >= (INT_PTR)start && at <= last && matches_original(at, pattern) && saved_window(at, pattern->size) == i)
					add_match(&search.matches[p], (const BYTE *)at);
			}
		}
	}
}

BOOL code_section(int index, BYTE **start, BYTE **end)
{
	BYTE *base = (BYTE *)GetModuleHandleA(NULL);
	const IMAGE_NT_HEADERS *headers = game_headers();
	const IMAGE_SECTION_HEADER *section = IMAGE_FIRST_SECTION(headers);
	WORD i;

	for (i = 0; i < headers->FileHeader.NumberOfSections; i++, section++) {
		if (!(section->Characteristics & IMAGE_SCN_MEM_EXECUTE) || (section->Characteristics & IMAGE_SCN_MEM_WRITE))
			continue;
		if (index-- > 0)
			continue;
		*start = base + section->VirtualAddress;
		*end = *start + section->Misc.VirtualSize;
		return TRUE;
	}
	return FALSE;
}

static void run_search(void)
{
	BYTE *start, *end;
	int i;

	for (i = 0; code_section(i, &start, &end); i++) {
		scan_section(start, end);
		scan_saved_code(start, end);
	}
}

static void clear_cache(void)
{
	int i;

	for (i = 0; i < cache_count; i++)
		HeapFree(GetProcessHeap(), 0, cache[i].text);
	cache_count = 0;
}

static const Matches *cached_matches(const char *text)
{
	INT_PTR base = (INT_PTR)GetModuleHandleA(NULL);
	int i;

	if (base != cache_base) {
		clear_cache();
		cache_base = base;
	}
	for (i = 0; i < cache_count; i++) {
		if (strcmp(cache[i].text, text) == 0)
			return &cache[i].matches;
	}
	return NULL;
}

static const Matches *cache_matches(const char *text, const Matches *matches)
{
	size_t size = strlen(text) + 1;
	char *copy;

	if (cache_count == MAX_CACHED || !(copy = HeapAlloc(GetProcessHeap(), 0, size)))
		return matches;
	memcpy(copy, text, size);
	cache[cache_count].text = copy;
	cache[cache_count].matches = *matches;
	return &cache[cache_count++].matches;
}

static const Matches *search_one(const char *text, int *error)
{
	const Matches *cached = cached_matches(text);

	*error = PATTERN_OK;
	if (cached)
		return cached;
	start_search();
	*error = add_pattern(text);
	if (*error != PATTERN_OK)
		return NULL;
	run_search();
	return cache_matches(text, &search.matches[0]);
}

int find_code_all(const char *text, const BYTE **found, int max)
{
	int error, i;
	const Matches *matches = search_one(text, &error);

	if (!matches)
		return 0;
	for (i = 0; i < matches->count && i < max && i < MAX_FOUND; i++)
		found[i] = matches->found[i];
	return matches->count;
}

INT_PTR find_unique(const char *text)
{
	int error;
	const Matches *matches = search_one(text, &error);

	return matches && matches->count == 1 ? (INT_PTR)matches->first : 0;
}

INT_PTR call_destination(INT_PTR call)
{
	BYTE opcode;
	INT32 distance;

	if (!call || !copy_memory(&opcode, call, 1) || opcode != CALL_OPCODE || !copy_memory(&distance, call + 1, sizeof distance))
		return 0;
	return call + CALL_SIZE + distance;
}

static int pattern_error(lua_State *L, int error, int index)
{
	switch (error) {
	case PATTERN_TOO_LONG:
		return luaL_error(L, "pattern %d is longer than %d bytes", index, MAX_PATTERN_SIZE);
	case PATTERN_BAD_BYTE:
		return luaL_error(L, "pattern %d: expected hex bytes and ?? separated by spaces", index);
	default:
		return luaL_error(L, "pattern %d must start with a byte, not ??", index);
	}
}

static void push_first(lua_State *L, const Matches *matches, BOOL nil_when_missing)
{
	if (matches->first)
		push_value(L, VALUE_POINTER, (INT_PTR)matches->first);
	else if (nil_when_missing)
		lua_pushnil(L);
	else
		lua_pushboolean(L, 0);
}

static int l_find_pattern(lua_State *L)
{
	int error;
	const Matches *matches = search_one(luaL_checkstring(L, 1), &error);

	if (error == PATTERN_TOO_LONG)
		return luaL_error(L, "pattern longer than %d bytes", MAX_PATTERN_SIZE);
	if (error == PATTERN_BAD_BYTE)
		return luaL_argerror(L, 1, "expected hex bytes and ?? separated by spaces");
	if (error == PATTERN_STARTS_UNKNOWN)
		return luaL_argerror(L, 1, "pattern must start with a byte, not ??");
	push_first(L, matches, TRUE);
	lua_pushnumber(L, (lua_Number)matches->count);
	return 2;
}

static const char *pattern_at(lua_State *L, int index)
{
	const char *text;

	lua_rawgeti(L, 1, index);
	if (lua_type(L, -1) != LUA_TSTRING)
		luaL_error(L, "pattern %d is not a string", index);
	text = lua_tostring(L, -1);
	lua_pop(L, 1);
	return text;
}

static int l_find_patterns(lua_State *L)
{
	const Matches *results[MAX_PATTERNS];
	int slots[MAX_PATTERNS];
	int count, i;

	luaL_checktype(L, 1, LUA_TTABLE);
	count = (int)lua_objlen(L, 1);
	if (count < 1 || count > MAX_PATTERNS)
		return luaL_argerror(L, 1, lua_pushfstring(L, "must hold 1 to %d patterns", MAX_PATTERNS));
	start_search();
	for (i = 0; i < count; i++) {
		const char *text = pattern_at(L, i + 1);
		int error;

		results[i] = cached_matches(text);
		slots[i] = search.count;
		if (results[i])
			continue;
		error = add_pattern(text);
		if (error != PATTERN_OK)
			return pattern_error(L, error, i + 1);
	}
	if (search.count)
		run_search();
	for (i = 0; i < count; i++) {
		const char *text = pattern_at(L, i + 1);

		if (!results[i])
			results[i] = cached_matches(text);
		if (!results[i])
			results[i] = cache_matches(text, &search.matches[slots[i]]);
	}
	lua_createtable(L, count, 0);
	lua_createtable(L, count, 0);
	for (i = 0; i < count; i++) {
		push_first(L, results[i], FALSE);
		lua_rawseti(L, -3, i + 1);
		lua_pushnumber(L, (lua_Number)results[i]->count);
		lua_rawseti(L, -2, i + 1);
	}
	return 2;
}

static int l_read_original(lua_State *L)
{
	int size_index = lua_gettop(L) == 2 ? 2 : 3;
	INT_PTR address = size_index == 2 ? check_pointer(L, 1) : address_argument(L, 1);
	lua_Number size = luaL_checknumber(L, size_index);
	BYTE bytes[MAX_ORIGINAL_READ];

	if (!(size >= 1 && size <= MAX_ORIGINAL_READ))
		return luaL_argerror(L, size_index, lua_pushfstring(L, "must be 1 to %d bytes", MAX_ORIGINAL_READ));
	if (!in_game_image(address, (size_t)size))
		return luaL_argerror(L, 1, "address is outside the game's exe");
	if (!copy_original(address, bytes, (size_t)size))
		return luaL_error(L, "failed to read memory");
	lua_pushlstring(L, (const char *)bytes, (size_t)size);
	return 1;
}

PRUNTIME_FUNCTION primary_function_entry(PRUNTIME_FUNCTION entry, ULONG64 base)
{
	int i;

	for (i = 0; i < MAX_CHAIN_LENGTH; i++) {
		const BYTE *info;

		if (entry->UnwindData & INDIRECT_ENTRY) {
			entry = (PRUNTIME_FUNCTION)(base + entry->UnwindData - INDIRECT_ENTRY);
			continue;
		}
		info = (const BYTE *)(base + entry->UnwindData);
		if (!((info[0] >> UNWIND_FLAGS_SHIFT) & UNWIND_CHAIN_INFO))
			return entry;
		entry = (PRUNTIME_FUNCTION)(info + UNWIND_HEADER_SIZE + UNWIND_CODE_SIZE * ((info[2] + 1) & ~1));
	}
	return entry;
}

static int l_function_start(lua_State *L)
{
	INT_PTR address = pointer_argument(L, 1);
	ULONG64 base = 0;
	PRUNTIME_FUNCTION part;

	if (!in_game_image(address, 1))
		return luaL_argerror(L, 1, "address is outside the game's exe");
	part = RtlLookupFunctionEntry((DWORD64)address, &base, NULL);
	if (!part) {
		lua_pushnil(L);
		return 1;
	}
	push_value(L, VALUE_POINTER, (INT_PTR)(base + primary_function_entry(part, base)->BeginAddress));
	push_value(L, VALUE_POINTER, (INT_PTR)(base + part->EndAddress));
	return 2;
}

const luaL_Reg scan_functions[] = {
	{ "find_pattern", l_find_pattern },
	{ "find_patterns", l_find_patterns },
	{ "function_start", l_function_start },
	{ "read_original", l_read_original },
	{ NULL, NULL }
};
