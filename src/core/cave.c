#include <stdio.h>
#include <string.h>

#include "batch.h"

enum { CAVE_ROOM = 4096, NEAR_REACH = 0x70000000, MAX_PREPARED = 1024, HEADER_SIZE = 160 };
enum { BLOCK_SIZE = 0x10000, BLOCK_PAGES = BLOCK_SIZE / CAVE_ROOM, FULL_BLOCK = (1 << BLOCK_PAGES) - 1, MAX_BLOCKS = 64 };
enum { MAX_NEAR_QUERIES = 1024, MAX_FAILED = 64, REGION_SHIFT = 24, BLOCKS_AT_LOAD = 4 };

typedef struct {
	INT_PTR address;
	BYTE *start;
	size_t size;
	size_t total;
} Cave;

typedef struct {
	INT_PTR site;
	const void *spec;
	BYTE *start;
	AssembledCave image;
} PreparedCave;

typedef struct {
	ULONG_PTR low;
	ULONG_PTR high;
	ULONG_PTR granularity;
} NearRange;

typedef struct {
	BYTE *base;
	unsigned used;
} NearBlock;

typedef struct {
	INT_PTR site;
	BOOL allocate;
	BYTE *start;
	BYTE *out;
	size_t room;
	AssembledCave *image;
	const char *why;
} AssembleCall;

static CaveAssembler assembler;
static PreparedCave prepared[MAX_PREPARED];
static int prepared_count;
static NearBlock near_blocks[MAX_BLOCKS];
static int block_count;
static ULONG_PTR failed_regions[MAX_FAILED];
static int failed_count;
static BOOL reserved_at_load;
static int blocks_at_load;
static BOOL load_note_pending;

static void seal_cave(void *context, void *original)
{
	const Cave *cave = context;
	DWORD old;

	VirtualProtect(cave->start, cave->total, PAGE_READWRITE, &old);
	write_jump_back(cave->start + cave->size, original);
	VirtualProtect(cave->start, cave->total, PAGE_EXECUTE_READ, &old);
	FlushInstructionCache(GetCurrentProcess(), cave->start, cave->total);
}

static int place_cave(lua_State *L)
{
	Cave *cave = lua_touserdata(L, 1);

	install_code_hook(L, cave->address, cave->start, cave->total, seal_cave, cave);
	return 0;
}

int try_cave(lua_State *L, INT_PTR address, const char *bytes, size_t size, BYTE **start)
{
	Cave cave = { address, NULL, size, size + JUMP_BACK_SIZE };

	cave.start = VirtualAlloc(NULL, size + JUMP_BACK_SIZE, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
	if (!cave.start) {
		lua_pushfstring(L, "no free memory for a cave at %p", (void *)address);
		return CAVE_NO_MEMORY;
	}
	memcpy(cave.start, bytes, size);
	if (lua_cpcall(L, place_cave, &cave)) {
		VirtualFree(cave.start, 0, MEM_RELEASE);
		return CAVE_REFUSED;
	}
	*start = cave.start;
	return CAVE_OK;
}

void register_cave_assembler(CaveAssembler build)
{
	assembler = build;
}

static NearRange near_range(INT_PTR site)
{
	SYSTEM_INFO system;
	NearRange range;
	ULONG_PTR at = (ULONG_PTR)site;

	GetSystemInfo(&system);
	range.granularity = system.dwAllocationGranularity;
	range.low = at > NEAR_REACH ? at - NEAR_REACH : 0;
	range.low = range.low < (ULONG_PTR)system.lpMinimumApplicationAddress ? (ULONG_PTR)system.lpMinimumApplicationAddress : range.low;
	range.high = at + NEAR_REACH;
	range.high = range.high > (ULONG_PTR)system.lpMaximumApplicationAddress ? (ULONG_PTR)system.lpMaximumApplicationAddress : range.high;
	return range;
}

static BOOL block_in_range(ULONG_PTR base, const NearRange *range)
{
	return base >= range->low && base + BLOCK_SIZE <= range->high;
}

static NearBlock *block_with_room(const NearRange *range)
{
	int i;

	for (i = 0; i < block_count; i++) {
		if (near_blocks[i].used != FULL_BLOCK && block_in_range((ULONG_PTR)near_blocks[i].base, range))
			return &near_blocks[i];
	}
	return NULL;
}

static BYTE *reserve_block(ULONG_PTR at)
{
	return VirtualAlloc((void *)at, BLOCK_SIZE, MEM_RESERVE, PAGE_NOACCESS);
}

static BYTE *look_up(ULONG_PTR *up, const NearRange *range)
{
	MEMORY_BASIC_INFORMATION region;
	ULONG_PTR end;
	BYTE *found = NULL;

	if (!VirtualQuery((void *)*up, &region, sizeof region)) {
		*up = range->high;
		return NULL;
	}
	end = (ULONG_PTR)region.BaseAddress + region.RegionSize;
	if (region.State == MEM_FREE && end >= *up + BLOCK_SIZE)
		found = reserve_block(*up);
	*up = (end + range->granularity - 1) & ~(range->granularity - 1);
	return found;
}

static BYTE *look_down(ULONG_PTR *down, const NearRange *range)
{
	MEMORY_BASIC_INFORMATION region;
	BYTE *found = NULL;

	if (!VirtualQuery((void *)*down, &region, sizeof region)) {
		*down = 0;
		return NULL;
	}
	if (region.State == MEM_FREE && region.RegionSize >= BLOCK_SIZE)
		found = reserve_block(*down);
	if (region.State == MEM_FREE)
		*down -= range->granularity;
	else
		*down = (ULONG_PTR)region.AllocationBase - range->granularity;
	return found;
}

static BYTE *search_near(INT_PTR site, const NearRange *range)
{
	ULONG_PTR step = range->granularity;
	ULONG_PTR down = ((ULONG_PTR)site & ~(step - 1)) - step;
	ULONG_PTR up = ((ULONG_PTR)site + step - 1) & ~(step - 1);
	BYTE *found = NULL;
	int queries;

	for (queries = 0; !found && queries < MAX_NEAR_QUERIES; queries++) {
		BOOL can_up = up + BLOCK_SIZE <= range->high, can_down = down >= range->low;

		if (can_up && (!can_down || queries % 2 == 0))
			found = look_up(&up, range);
		else if (can_down)
			found = look_down(&down, range);
		else
			break;
	}
	return found;
}

static BOOL failed_before(INT_PTR site)
{
	int i;

	for (i = 0; i < failed_count; i++) {
		if (failed_regions[i] == (ULONG_PTR)site >> REGION_SHIFT)
			return TRUE;
	}
	return FALSE;
}

static void remember_failure(INT_PTR site)
{
	if (failed_count < MAX_FAILED)
		failed_regions[failed_count++] = (ULONG_PTR)site >> REGION_SHIFT;
}

static NearBlock *add_block(BYTE *base)
{
	near_blocks[block_count].base = base;
	near_blocks[block_count].used = 0;
	return &near_blocks[block_count++];
}

static NearBlock *new_block(INT_PTR site, const NearRange *range)
{
	BYTE *base;

	if (block_count == MAX_BLOCKS || range->low + BLOCK_SIZE > range->high || failed_before(site))
		return NULL;
	base = search_near(site, range);
	if (!base) {
		remember_failure(site);
		return NULL;
	}
	return add_block(base);
}

static NearRange game_image_range(void)
{
	BYTE *image = (BYTE *)GetModuleHandleW(NULL);
	IMAGE_NT_HEADERS *headers = (IMAGE_NT_HEADERS *)(image + ((IMAGE_DOS_HEADER *)image)->e_lfanew);
	NearRange range = near_range((INT_PTR)image);
	NearRange end = near_range((INT_PTR)image + headers->OptionalHeader.SizeOfImage - 1);

	range.low = end.low > range.low ? end.low : range.low;
	range.high = end.high < range.high ? end.high : range.high;
	return range;
}

void reserve_near_caves(void)
{
	INT_PTR image = (INT_PTR)GetModuleHandleW(NULL);
	NearRange range;

	if (reserved_at_load)
		return;
	reserved_at_load = TRUE;
	range = game_image_range();
	while (block_count < BLOCKS_AT_LOAD) {
		BYTE *base = search_near(image, &range);

		if (!base)
			break;
		add_block(base);
	}
	blocks_at_load = block_count;
	load_note_pending = blocks_at_load < BLOCKS_AT_LOAD;
}

void log_cave_reservation(lua_State *L)
{
	char text[160];

	if (!load_note_pending)
		return;
	_snprintf_s(text, sizeof text, _TRUNCATE,
		"[memreader Plus] cave memory near the game's code: %d of %d blocks reserved at load, later asm caves search for more", blocks_at_load,
		BLOCKS_AT_LOAD);
	load_note_pending = !log_line(L, text);
}

Capacity cave_capacity(void)
{
	int used = 0, i;
	unsigned page;

	for (i = 0; i < block_count; i++) {
		for (page = 0; page < BLOCK_PAGES; page++)
			used += (int)((near_blocks[i].used >> page) & 1);
	}
	return (Capacity){ used, block_count * BLOCK_PAGES, MAX_BLOCKS * BLOCK_PAGES };
}

static BYTE *take_page(NearBlock *block)
{
	unsigned page = 0;
	BYTE *start;

	while (block->used & (1u << page))
		page++;
	start = VirtualAlloc(block->base + page * CAVE_ROOM, CAVE_ROOM, MEM_COMMIT, PAGE_READWRITE);
	if (start)
		block->used |= 1u << page;
	return start;
}

static BYTE *allocate_near(INT_PTR site)
{
	NearRange range = near_range(site);
	NearBlock *block = block_with_room(&range);

	if (!block)
		block = new_block(site, &range);
	return block ? take_page(block) : NULL;
}

static void give_back_page(BYTE *start)
{
	int i;

	for (i = 0; i < block_count; i++) {
		if (start >= near_blocks[i].base && start < near_blocks[i].base + BLOCK_SIZE) {
			VirtualFree(start, CAVE_ROOM, MEM_DECOMMIT);
			near_blocks[i].used &= ~(1u << (unsigned)((start - near_blocks[i].base) / CAVE_ROOM));
		}
	}
}

static void free_listing(AssembledCave *image)
{
	if (image->listing)
		HeapFree(GetProcessHeap(), 0, image->listing);
	image->listing = NULL;
}

static void free_prepared(PreparedCave *cave)
{
	if (cave->start)
		give_back_page(cave->start);
	cave->start = NULL;
	free_listing(&cave->image);
}

static int run_assembler(lua_State *L)
{
	AssembleCall *call = lua_touserdata(L, 2);

	if (call->allocate) {
		call->start = allocate_near(call->site);
		call->out = call->start;
	}
	if (call->start)
		call->why = assembler(L, 1, call->site, (INT_PTR)call->start, call->out, call->room, call->image);
	return 0;
}

static int assemble_safely(lua_State *L, int spec, AssembleCall *call)
{
	BOOL was;
	int failed;

	memset(call->image, 0, sizeof *call->image);
	lua_pushcfunction(L, run_assembler);
	lua_pushvalue(L, spec);
	lua_pushlightuserdata(L, call);
	was = mark_running(TRUE);
	failed = lua_pcall(L, 2, 0, 0);
	mark_running(was);
	if (failed && !lua_isstring(L, -1)) {
		lua_pop(L, 1);
		lua_pushliteral(L, "the cave table raised an error");
	}
	if (!failed && !call->start) {
		lua_pushliteral(L, "no free memory near the game's code for the cave");
		return CAVE_NO_MEMORY;
	}
	if (!failed && call->why) {
		lua_pushstring(L, call->why);
		failed = 1;
	}
	if (failed)
		free_listing(call->image);
	return failed ? CAVE_REFUSED : CAVE_OK;
}

static int build_asm_cave(lua_State *L, INT_PTR site, int spec, PreparedCave *cave)
{
	AssembleCall call = { site, TRUE, NULL, NULL, CAVE_ROOM, &cave->image, NULL };
	int result = assemble_safely(L, spec, &call);

	cave->site = site;
	cave->spec = lua_topointer(L, spec);
	cave->start = call.start;
	if (result != CAVE_OK)
		free_prepared(cave);
	return result;
}

int prepare_asm_cave(lua_State *L, INT_PTR site, int spec)
{
	int result;

	if (prepared_count == MAX_PREPARED) {
		lua_pushliteral(L, "too many caves in one batch");
		return CAVE_REFUSED;
	}
	result = build_asm_cave(L, site, spec, &prepared[prepared_count]);
	if (result == CAVE_OK)
		prepared_count++;
	return result;
}

static BOOL take_prepared(INT_PTR site, const void *spec, PreparedCave *cave)
{
	int i;

	for (i = 0; i < prepared_count; i++) {
		if (prepared[i].site == site && prepared[i].spec == spec) {
			*cave = prepared[i];
			prepared[i] = prepared[--prepared_count];
			return TRUE;
		}
	}
	return FALSE;
}

void release_prepared_caves(void)
{
	while (prepared_count > 0)
		free_prepared(&prepared[--prepared_count]);
}

static char *echo_text(const char *name, const PreparedCave *cave)
{
	const char *listing = cave->image.listing ? cave->image.listing : "";
	size_t size = strlen(listing) + HEADER_SIZE + strlen(name), used;
	char *text = HeapAlloc(GetProcessHeap(), 0, size);

	if (!text)
		return NULL;
	_snprintf_s(text, size, _TRUNCATE, "cave %s at 0x%llx -> 0x%llx, %u bytes\n%s", name, (UINT64)cave->site, (UINT64)(ULONG_PTR)cave->start,
		(unsigned)cave->image.code, listing);
	used = strlen(text);
	while (used > 0 && text[used - 1] == '\n')
		text[--used] = '\0';
	return text;
}

int try_asm_cave(lua_State *L, INT_PTR site, int spec, const char *name, BYTE **start)
{
	PreparedCave cave;
	Cave install;
	DWORD old;
	int result = take_prepared(site, lua_topointer(L, spec), &cave) ? CAVE_OK : build_asm_cave(L, site, spec, &cave);

	if (result != CAVE_OK)
		return result;
	install.address = site;
	install.start = cave.start;
	install.size = cave.image.code;
	install.total = cave.image.total;
	VirtualProtect(cave.start, cave.image.total, PAGE_EXECUTE_READ, &old);
	if (lua_cpcall(L, place_cave, &install)) {
		free_prepared(&cave);
		return CAVE_REFUSED;
	}
	set_cave_listing(site, echo_text(name, &cave));
	free_listing(&cave.image);
	*start = cave.start;
	return CAVE_OK;
}

static BOOL same_part(const BYTE *a, const BYTE *b, size_t from, size_t to)
{
	return to <= from || memcmp(a + from, b + from, to - from) == 0;
}

const char *compare_asm_cave(lua_State *L, INT_PTR site, int spec)
{
	static BYTE copy[CAVE_ROOM];
	BYTE *start = cave_start(site);
	AssembledCave image;
	AssembleCall call = { site, FALSE, start, copy, sizeof copy, &image, NULL };

	if (!start)
		return different_change;
	if (assemble_safely(L, spec, &call) != CAVE_OK)
		return lua_tostring(L, -1);
	free_listing(&image);
	if (image.total != cave_length(site) || !same_part(copy, start, 0, image.code) || !same_part(copy, start, image.code + JUMP_BACK_SIZE, image.total))
		return different_change;
	return NULL;
}

static int l_code_cave(lua_State *L)
{
	INT_PTR address = pointer_argument(L, 1);
	size_t size;
	const char *bytes = luaL_checklstring(L, 2, &size);
	BYTE *start = NULL;
	int result;

	if (!address)
		return luaL_argerror(L, 1, "address is NULL");
	if (size == 0)
		return luaL_argerror(L, 2, "no cave bytes");
	result = try_cave(L, address, bytes, size, &start);
	if (result == CAVE_NO_MEMORY)
		return luaL_error(L, "%s", lua_tostring(L, -1));
	if (result == CAVE_REFUSED)
		return lua_error(L);
	note_anonymous_cave(L, address);
	push_value(L, VALUE_POINTER, (INT_PTR)start);
	return 1;
}

const luaL_Reg cave_functions[] = {
	{ "code_cave", l_code_cave },
	{ NULL, NULL }
};
