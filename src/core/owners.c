#include <string.h>

#include "common.h"

enum {
	MAX_OWNERS = 64,
	MAX_ITEMS = 2048,
	MAX_CLAIMS = 4096,
	HELD_POOL_SIZE = 64 * 1024,
	MAX_ANONYMOUS = 64,
	MAX_LISTED_NAMES = 8
};

typedef struct {
	INT_PTR address;
	char caller[CALLER_SIZE];
} AnonymousCave;

static const char *const kind_words[ROW_KIND_COUNT][2] = {
	{ "link", "links" }, { "value", "values" }, { "cave", "caves" },
	{ "patch", "patches" }, { "frame", "frames" }, { "relocation", "relocations" }, { "row", "rows" }
};

static const char *const kind_names[ITEM_KIND_COUNT] = {
	"site", "value", "cave", "patch", "frame", "relocate", "row", "prefix", "postfix", "around"
};

static const RowKind *row_handler;
static char owners[MAX_OWNERS][OWNER_SIZE];
static int owner_count;
static Item items[MAX_ITEMS];
static int item_count;
static Claim claims[MAX_CLAIMS];
static int claim_count;
static BYTE pool[HELD_POOL_SIZE];
static int pool_used;
static AnonymousCave anonymous[MAX_ANONYMOUS];
static int anonymous_count;
static int anonymous_unlisted;

void register_row_kind(const RowKind *kind)
{
	row_handler = kind;
}

const RowKind *row_handler_get(void)
{
	return row_handler;
}

BOOL is_link_kind(int kind)
{
	return kind == ITEM_SITE || kind >= ITEM_PREFIX;
}

const char *item_kind_name(int kind)
{
	return kind_names[kind];
}

int shown_kind(const Item *item)
{
	return item->listed ? item->listed - 1 : item->kind;
}

static int row_kind(int kind)
{
	return kind >= ITEM_PREFIX ? ITEM_SITE : kind;
}

int find_owner(const char *name)
{
	int i;

	for (i = 0; i < owner_count; i++) {
		if (strcmp(owners[i], name) == 0)
			return i;
	}
	return -1;
}

int add_owner(const char *name)
{
	int found = find_owner(name);

	if (found >= 0)
		return found;
	if (owner_count == MAX_OWNERS)
		return -1;
	strcpy_s(owners[owner_count], OWNER_SIZE, name);
	return owner_count++;
}

const char *owner_name(int owner)
{
	return owners[owner];
}

int find_item(int owner, const char *name)
{
	int i;

	for (i = 0; i < item_count; i++) {
		if (items[i].used && items[i].owner == owner && strcmp(items[i].name, name) == 0)
			return i;
	}
	return -1;
}

static int free_item_slot(void)
{
	int i;

	for (i = 0; i < item_count; i++) {
		if (!items[i].used)
			return i;
	}
	return item_count < MAX_ITEMS ? item_count : -1;
}

int add_item(int owner, const char *name, int kind, INT_PTR at)
{
	int slot = free_item_slot();
	Item *item;

	if (slot < 0)
		return -1;
	item = &items[slot];
	memset(item, 0, sizeof *item);
	item->kind = (BYTE)kind;
	item->owner = (BYTE)owner;
	item->at = at;
	strcpy_s(item->name, ITEM_NAME_SIZE, name);
	item->used = TRUE;
	if (slot == item_count)
		item_count++;
	return slot;
}

Item *item_at(int index)
{
	return &items[index];
}

int item_total(void)
{
	return item_count;
}

Claim *claim_at(int index)
{
	return &claims[index];
}

int claim_total(void)
{
	return claim_count;
}

int first_claim(int item)
{
	int i;

	for (i = 0; i < claim_count; i++) {
		if (claims[i].item == item)
			return i;
	}
	return -1;
}

BYTE *held_bytes(const Claim *claim)
{
	return pool + claim->hold;
}

BYTE *wrote_bytes(const Claim *claim)
{
	return pool + claim->hold + claim->size;
}

static void drop_claim(int index)
{
	int hold = claims[index].hold;
	int length = hold < 0 ? 0 : 2 * claims[index].size;
	int i;

	if (length) {
		memmove(pool + hold, pool + hold + length, (size_t)(pool_used - hold - length));
		pool_used -= length;
		for (i = 0; i < claim_count; i++) {
			if (claims[i].hold > hold)
				claims[i].hold -= length;
		}
	}
	claims[index] = claims[--claim_count];
}

void remove_item(int index)
{
	int i;

	for (i = claim_count - 1; i >= 0; i--) {
		if (claims[i].item == index)
			drop_claim(i);
	}
	items[index].used = FALSE;
}

void make_tag(char *out, size_t size, int owner, const char *name)
{
	_snprintf_s(out, size, _TRUNCATE, "%s/%s", owners[owner], name);
}

BOOL claim_room(int claim_needed, size_t bytes_needed)
{
	return claim_count + claim_needed <= MAX_CLAIMS && (size_t)pool_used + bytes_needed <= HELD_POOL_SIZE;
}

BOOL item_room(int needed)
{
	int i, free_slots = MAX_ITEMS - item_count;

	for (i = 0; i < item_count; i++)
		free_slots += !items[i].used;
	return free_slots >= needed;
}

BOOL registry_room(int claim_needed, size_t bytes_needed)
{
	return free_item_slot() >= 0 && claim_room(claim_needed, bytes_needed);
}

BOOL add_claim(int item, INT_PTR from, size_t size, const BYTE *held, const BYTE *wrote)
{
	Claim *claim = &claims[claim_count];

	if (!claim_room(1, held ? 2 * size : 0))
		return FALSE;
	claim->from = from;
	claim->size = (int)size;
	claim->item = item;
	claim->hold = -1;
	if (held) {
		claim->hold = pool_used;
		memcpy(pool + pool_used, held, size);
		memcpy(pool + pool_used + size, wrote, size);
		pool_used += 2 * (int)size;
	}
	claim_count++;
	return TRUE;
}

BOOL claim_holder(INT_PTR from, size_t size, int except, char *holder, size_t holder_size)
{
	int i;

	for (i = 0; i < claim_count; i++) {
		const Claim *claim = &claims[i];

		if (claim->item == except || claim->from >= from + (INT_PTR)size || from >= claim->from + claim->size)
			continue;
		make_tag(holder, holder_size, items[claim->item].owner, items[claim->item].name);
		return TRUE;
	}
	return FALSE;
}

BOOL frame_holder(INT_PTR function, int except, char *holder, size_t holder_size)
{
	int i;

	for (i = 0; i < item_count; i++) {
		if (items[i].used && items[i].kind == ITEM_FRAME && items[i].at == function && i != except) {
			make_tag(holder, holder_size, items[i].owner, items[i].name);
			return TRUE;
		}
	}
	return FALSE;
}

static BOOL is_detached(const Item *item)
{
	return is_link_kind(item->kind) && item->attached != callback_generation();
}

const char *item_state(int index)
{
	BYTE current[MAX_PATCH_SIZE];
	int at = first_claim(index);
	const Claim *claim;

	if (is_detached(&items[index]))
		return "detached";
	if (items[index].kind == ITEM_ROW)
		return row_handler ? row_handler->state(index) : "missing";
	if ((items[index].kind != ITEM_PATCH && items[index].kind != ITEM_VALUE) || at < 0)
		return "stays";
	claim = &claims[at];
	if (in_hooked_prologue(claim->from, (size_t)claim->size))
		return "copied";
	if (!copy_memory(current, claim->from, (size_t)claim->size))
		return "missing";
	if (memcmp(current, wrote_bytes(claim), (size_t)claim->size) == 0)
		return "ours";
	if (memcmp(current, held_bytes(claim), (size_t)claim->size) == 0)
		return "held";
	return "missing";
}

void note_anonymous_cave(lua_State *L, INT_PTR address)
{
	if (anonymous_count == MAX_ANONYMOUS) {
		anonymous_unlisted++;
		return;
	}
	anonymous[anonymous_count].address = address;
	caller_position(L, anonymous[anonymous_count].caller, CALLER_SIZE);
	anonymous_count++;
}

static void add_tag(char *out, size_t size, const Item *item)
{
	size_t used = strlen(out);
	char tag[TAG_SIZE];

	make_tag(tag, sizeof tag, item->owner, item->name);
	_snprintf_s(out + used, size - used, _TRUNCATE, "%s%s", used ? ", " : "", tag);
}

int describe_owner(INT_PTR address, char *out, size_t size)
{
	int i;

	out[0] = '\0';
	for (i = 0; i < item_count; i++) {
		if (items[i].used && items[i].at == address && (is_link_kind(items[i].kind) || items[i].kind == ITEM_CAVE) && !is_detached(&items[i]))
			add_tag(out, size, &items[i]);
	}
	if (out[0])
		return OWNER_NAMED;
	for (i = 0; i < anonymous_count; i++) {
		if (anonymous[i].address == address) {
			strcpy_s(out, size, anonymous[i].caller);
			return OWNER_CALLER;
		}
	}
	return OWNER_NONE;
}

int count_claims(int item)
{
	int i, count = 0;

	for (i = 0; i < claim_count; i++)
		count += claims[i].item == item;
	return count;
}

static int count_kind(int owner, int kind)
{
	int i, count = 0;

	for (i = 0; i < item_count; i++) {
		if (items[i].used && items[i].owner == owner && row_kind(shown_kind(&items[i])) == kind && !is_detached(&items[i]))
			count += kind == ITEM_RELOCATE ? count_claims(i) : 1;
	}
	return count;
}

static int count_detached(int owner)
{
	int i, count = 0;

	for (i = 0; i < item_count; i++)
		count += items[i].used && items[i].owner == owner && is_detached(&items[i]);
	return count;
}

static void cut_text(Text *report, size_t used)
{
	report->used = used;
	report->data[used] = '\0';
}

static void add_names(Text *report, int owner, int kind)
{
	int i, listed = 0, count = 0;

	for (i = 0; i < item_count; i++) {
		if (!items[i].used || items[i].owner != owner || shown_kind(&items[i]) != kind)
			continue;
		count++;
		if (listed < MAX_LISTED_NAMES) {
			add_text(report, "%s%s ", listed ? ", " : " (", items[i].name);
			add_address(report, (ULONG_PTR)items[i].at);
			listed++;
		}
	}
	if (count > listed)
		add_text(report, ", and %d more", count - listed);
	add_text(report, ")");
}

static void add_owner_row(Text *report, int owner)
{
	const char *separator = "";
	size_t start = report->used;
	int kind, count;

	add_text(report, "  %s: ", owners[owner]);
	for (kind = 0; kind < ROW_KIND_COUNT; kind++) {
		count = count_kind(owner, kind);
		if (!count)
			continue;
		add_text(report, "%s%d %s", separator, count, kind_words[kind][count != 1]);
		if (kind == ITEM_CAVE || kind == ITEM_PATCH)
			add_names(report, owner, kind);
		separator = ", ";
	}
	count = count_detached(owner);
	if (count) {
		add_text(report, "%s%d %s not attached", separator, count, kind_words[ITEM_SITE][count != 1]);
		separator = ", ";
	}
	if (separator[0])
		add_text(report, "\n");
	else
		cut_text(report, start);
}

static void add_anonymous_rows(Text *report)
{
	int i;

	for (i = 0; i < anonymous_count; i++) {
		add_text(report, "  ?: 1 code cave at ");
		add_address(report, (ULONG_PTR)anonymous[i].address);
		add_text(report, " from %s\n", anonymous[i].caller);
	}
	if (anonymous_unlisted)
		add_text(report, "  ?: %d more code caves not listed\n", anonymous_unlisted);
}

void add_owners(Text *report)
{
	size_t start = report->used, header;
	int i;

	add_text(report, "memreader Plus changes by owner:\n");
	header = report->used;
	for (i = 0; i < owner_count; i++)
		add_owner_row(report, i);
	add_anonymous_rows(report);
	if (report->used == header)
		cut_text(report, start);
}
