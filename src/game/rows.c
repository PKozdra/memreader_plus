#include <string.h>

#include "game.h"

enum {
	FIRST_ROWS = 16,
	MAX_ROWS = 4096,
	MAX_EDITS = 128,
	MAX_ROW_KEY = 255,
	MIN_RECORD_SIZE = 16,
	MAX_RECORD_SIZE = 4096,
	MAX_ROW_INDEX = 0xFFFFFF,
	RECORD_HEADER = 8,
	FIRST_CAPACITY = 4,
	SCAN_CHUNK = 512,
	TABLE_RECORDS = 8,
	TABLE_KEYS = 0x28,
	VTABLE_RECORD_SIZE = 2,
	SIZE_FUNCTION_LENGTH = 6,
	ERROR_SIZE = 160
};

typedef struct {
	INT_PTR address;
	INT_PTR vtable;
	CaVector records;
	UINT32 record_size;
} Table;

typedef struct {
	UINT32 offset;
	const BYTE *bytes;
	size_t length;
} Edit;

typedef struct {
	BOOL used;
	int item;
	INT_PTR table;
	INT_PTR vtable;
	INT_PTR record;
	UINT32 index;
	size_t key_length;
	char key[MAX_ROW_KEY + 1];
} Entry;

typedef struct {
	Table table;
	INT64 template_row;
	const char *key;
	size_t key_length;
	BYTE bytes[MAX_RECORD_SIZE];
} Plan;

typedef struct {
	INT_PTR map;
	const char *key;
	size_t length;
	UINT32 index;
	INT_PTR source;
	const char *why;
} Put;

static const char not_a_table[] = "not a database table";
static const char write_failed[] = "failed to write memory";
static const char read_failed[] = "failed to read memory";

static Entry *entries;
static int entry_room;
static char put_error[ERROR_SIZE];

static int refuse(lua_State *L, const char *why)
{
	lua_pushnil(L);
	lua_pushstring(L, why);
	return 2;
}

static Entry *entry_of(int item)
{
	int i;

	for (i = 0; i < entry_room; i++) {
		if (entries[i].used && entries[i].item == item)
			return &entries[i];
	}
	return NULL;
}

static BOOL grow_entries(void)
{
	int room = entry_room ? entry_room * 2 : FIRST_ROWS;
	Entry *bigger;

	if (room > MAX_ROWS)
		return FALSE;
	bigger = resize_block(entries, (size_t)room * sizeof *entries);
	if (!bigger)
		return FALSE;
	memset(bigger + entry_room, 0, (size_t)(room - entry_room) * sizeof *bigger);
	entries = bigger;
	entry_room = room;
	return TRUE;
}

static Entry *free_entry(void)
{
	int i;

	for (i = 0; i < entry_room; i++) {
		if (!entries[i].used)
			return &entries[i];
	}
	return grow_entries() ? &entries[i] : NULL;
}

Capacity rows_capacity(void)
{
	int i, used = 0;

	for (i = 0; i < entry_room; i++)
		used += entries[i].used != 0;
	return (Capacity){ used, entry_room, MAX_ROWS };
}

static BOOL read_record_size(INT_PTR vtable, UINT32 *size)
{
	BYTE code[SIZE_FUNCTION_LENGTH];
	INT_PTR function;

	if (!copy_memory(&function, vtable + VTABLE_RECORD_SIZE * sizeof function, sizeof function) || !function ||
		!copy_memory(code, function, sizeof code) || code[0] != 0xB8 || code[5] != 0xC3)
		return FALSE;
	memcpy(size, code + 1, sizeof *size);
	return *size >= MIN_RECORD_SIZE && *size <= MAX_RECORD_SIZE;
}

static const char *read_table(Table *table, INT_PTR address)
{
	CaVector *records = &table->records;

	table->address = address;
	if (!address || !copy_memory(&table->vtable, address, sizeof table->vtable) || !table->vtable ||
		!read_record_size(table->vtable, &table->record_size) || !copy_memory(records, address + TABLE_RECORDS, sizeof *records))
		return not_a_table;
	if (records->size < 0 || records->size > MAX_ROW_INDEX || (UINT32)records->size > records->capacity || (records->size > 0 && !records->data))
		return not_a_table;
	return NULL;
}

static INT_PTR record_at(const Table *table, UINT32 index)
{
	INT_PTR record = 0;

	if (index >= (UINT32)table->records.size || !copy_memory(&record, table->records.data + (INT_PTR)index * sizeof record, sizeof record))
		return 0;
	return record;
}

static INT64 row_of(const Table *table, INT_PTR record)
{
	INT_PTR chunk[SCAN_CHUNK];
	INT64 start, count, i, size = table->records.size;

	if (!record)
		return -1;
	for (start = 0; start < size; start += SCAN_CHUNK) {
		count = size - start < SCAN_CHUNK ? size - start : SCAN_CHUNK;
		if (!copy_memory(chunk, table->records.data + (INT_PTR)start * sizeof record, (size_t)count * sizeof record))
			return -1;
		for (i = 0; i < count; i++) {
			if (chunk[i] == record)
				return start + i;
		}
	}
	return -1;
}

static const char *take_edit(lua_State *L, UINT32 record_size, Edit *edit)
{
	lua_Number offset;
	TypedValue *value = to_value(L, -1);
	size_t length = 0;

	if (lua_type(L, -2) != LUA_TNUMBER)
		return "edits are keyed by the offset in the record";
	offset = lua_tonumber(L, -2);
	if (!(offset >= RECORD_HEADER && offset < record_size) || offset != (lua_Number)(INT64)offset)
		return "an edit offset must be a whole number from 8 to the end of the record";
	edit->offset = (UINT32)offset;
	if (lua_type(L, -1) == LUA_TSTRING) {
		edit->bytes = (const BYTE *)lua_tolstring(L, -1, &length);
	} else if (value) {
		edit->bytes = (const BYTE *)&value->pointer;
		length = value_size(value->type);
	} else {
		return "an edit takes a typed value or a string";
	}
	edit->length = length;
	if (length == 0 || edit->offset + length > record_size)
		return "an edit does not fit in the record";
	return NULL;
}

static void sort_edits(Edit *edits, int count)
{
	int i, j;

	for (i = 1; i < count; i++) {
		Edit edit = edits[i];

		for (j = i - 1; j >= 0 && edits[j].offset > edit.offset; j--)
			edits[j + 1] = edits[j];
		edits[j + 1] = edit;
	}
}

static const char *edit_count_text(void)
{
	static char text[32];

	_snprintf_s(text, sizeof text, _TRUNCATE, "at most %d edits", MAX_EDITS);
	return text;
}

static const char *read_edits(lua_State *L, int index, UINT32 record_size, Edit *edits, int *count)
{
	const char *why;
	int i;

	*count = 0;
	if (lua_isnoneornil(L, index))
		return NULL;
	lua_pushnil(L);
	while (lua_next(L, index)) {
		why = *count == MAX_EDITS ? edit_count_text() : take_edit(L, record_size, &edits[*count]);
		if (why) {
			lua_pop(L, 2);
			return why;
		}
		(*count)++;
		lua_pop(L, 1);
	}
	sort_edits(edits, *count);
	for (i = 1; i < *count; i++) {
		if (edits[i - 1].offset + edits[i - 1].length > edits[i].offset)
			return "edits overlap";
	}
	return NULL;
}

static const char *plan_row(lua_State *L, Plan *plan)
{
	INT_PTR template_record = pointer_argument(L, 4);
	Edit edits[MAX_EDITS];
	const char *why;
	int count, i;

	plan->key = luaL_checklstring(L, 5, &plan->key_length);
	if (!lua_isnoneornil(L, 6))
		luaL_checktype(L, 6, LUA_TTABLE);
	if (plan->key_length < 1 || plan->key_length > MAX_ROW_KEY || strlen(plan->key) != plan->key_length)
		return "the key must be 1 to 255 bytes without a zero byte";
	why = read_table(&plan->table, pointer_argument(L, 3));
	if (why)
		return why;
	plan->template_row = row_of(&plan->table, template_record);
	if (plan->template_row < 0)
		return "the template is not a row of this table";
	why = read_edits(L, 6, plan->table.record_size, edits, &count);
	if (why)
		return why;
	if (!copy_memory(plan->bytes, template_record, plan->table.record_size))
		return read_failed;
	for (i = 0; i < count; i++)
		memcpy(plan->bytes + edits[i].offset, edits[i].bytes, edits[i].length);
	return NULL;
}

static BOOL same_row(const Plan *plan, const Entry *entry)
{
	BYTE current[MAX_RECORD_SIZE];

	return entry->table == plan->table.address && entry->key_length == plan->key_length && memcmp(entry->key, plan->key, plan->key_length) == 0 &&
		record_at(&plan->table, entry->index) == entry->record && copy_memory(current, entry->record, plan->table.record_size) &&
		memcmp(current, plan->bytes, plan->table.record_size) == 0;
}

static BOOL store_header_field(const Table *table, int offset, const void *value, size_t size)
{
	return write_memory(table->address + TABLE_RECORDS + offset, value, size);
}

static UINT32 next_capacity(const CaVector *records)
{
	INT64 capacity = records->size ? (INT64)records->size * 2 : FIRST_CAPACITY;

	return (UINT32)(capacity > MAX_ROW_INDEX + 1 ? (INT64)records->size + 1 : capacity);
}

static const char *grow_records(lua_State *L, const CaVector *records, INT_PTR *data)
{
	*data = game_heap_alloc(L, (size_t)next_capacity(records) * sizeof(INT_PTR));
	if (records->size > 0 && !copy_memory((void *)*data, records->data, (size_t)records->size * sizeof(INT_PTR))) {
		game_heap_free(L, *data, FALSE);
		return read_failed;
	}
	return NULL;
}

static const char *append_record(lua_State *L, const Table *table, INT_PTR record)
{
	const CaVector *records = &table->records;
	INT_PTR data = records->data;
	UINT32 capacity = records->capacity;
	INT32 size = records->size + 1;
	const char *why;

	if ((UINT32)records->size == capacity) {
		why = grow_records(L, records, &data);
		if (why)
			return why;
		capacity = next_capacity(records);
	}
	if (!write_memory(data + (INT_PTR)records->size * sizeof record, &record, sizeof record)) {
		if (data != records->data)
			game_heap_free(L, data, FALSE);
		return write_failed;
	}
	if (data != records->data) {
		if (!store_header_field(table, offsetof(CaVector, data), &data, sizeof data)) {
			game_heap_free(L, data, FALSE);
			return write_failed;
		}
		store_header_field(table, offsetof(CaVector, capacity), &capacity, sizeof capacity);
		if (records->data)
			game_heap_free(L, records->data, TRUE);
	}
	return store_header_field(table, offsetof(CaVector, size), &size, sizeof size) ? NULL : write_failed;
}

static BOOL pop_record(const Table *table, UINT32 index)
{
	CaVector records;
	INT32 size = (INT32)index;

	if (!copy_memory(&records, table->address + TABLE_RECORDS, sizeof records) || !store_header_field(table, offsetof(CaVector, size), &size, sizeof size))
		return FALSE;
	return zero_memory(records.data + (INT_PTR)index * sizeof(INT_PTR), sizeof(INT_PTR));
}

static int run_put(lua_State *L)
{
	Put *put = lua_touserdata(L, 1);
	INT_PTR node = 0;

	put->why = map_put(L, put->map, put->key, put->length, put->index, put->source, &node);
	return 0;
}

static const char *put_key(lua_State *L, Put *put)
{
	const char *text;

	put->why = NULL;
	if (lua_cpcall(L, run_put, put)) {
		text = lua_tostring(L, -1);
		_snprintf_s(put_error, sizeof put_error, _TRUNCATE, "%s", text ? text : "the key could not be added");
		lua_pop(L, 1);
		return put_error;
	}
	return put->why;
}

static const char *publish_row(lua_State *L, const Plan *plan, INT_PTR *record)
{
	const Table *table = &plan->table;
	UINT32 index = (UINT32)table->records.size;
	Put put = { table->address + TABLE_KEYS, plan->key, plan->key_length, index, 0, NULL };
	const char *why;

	put.source = map_source_of(put.map, (UINT32)plan->template_row);
	*record = game_heap_alloc(L, table->record_size);
	if (!write_memory(*record, plan->bytes, table->record_size)) {
		game_heap_free(L, *record, FALSE);
		return write_failed;
	}
	why = append_record(L, table, *record);
	if (why) {
		game_heap_free(L, *record, FALSE);
		return why;
	}
	why = put_key(L, &put);
	if (why) {
		pop_record(table, index);
		game_heap_free(L, *record, TRUE);
		map_take(L, put.map, put.key, put.length, index);
	}
	return why;
}

static const char *check_new_row(const Plan *plan)
{
	INT_PTR node = 0;
	const char *why;

	if (!registry_room(0, 0) || !free_entry())
		return "full";
	if (!game_heap_found())
		return "the game's allocator was not found in this game build";
	if ((UINT32)plan->table.records.size >= MAX_ROW_INDEX)
		return "the table has too many rows";
	why = map_find(plan->table.address + TABLE_KEYS, plan->key, plan->key_length, &node);
	if (why)
		return why;
	return node ? "key exists" : NULL;
}

static void register_row(lua_State *L, int owner, const char *name, const Plan *plan, INT_PTR record)
{
	Entry *entry = free_entry();
	UINT32 index = (UINT32)plan->table.records.size;
	char tag[TAG_SIZE];

	memset(entry, 0, sizeof *entry);
	entry->used = TRUE;
	entry->item = add_item(owner, name, ITEM_ROW, record);
	entry->table = plan->table.address;
	entry->vtable = plan->table.vtable;
	entry->record = record;
	entry->index = index;
	entry->key_length = plan->key_length;
	memcpy(entry->key, plan->key, plan->key_length);
	make_tag(tag, sizeof tag, owner, name);
	note_owned_change(L, "row", plan->table.address + TABLE_RECORDS, sizeof(CaVector), tag);
}

static int push_row(lua_State *L, INT_PTR record, UINT32 index)
{
	push_value(L, VALUE_POINTER, record);
	lua_pushnumber(L, (lua_Number)index);
	return 2;
}

static int add_row(lua_State *L, int owner, const char *name)
{
	Plan plan;
	INT_PTR record = 0;
	const char *why = plan_row(L, &plan);
	int item;

	if (why)
		return refuse(L, why);
	item = find_item(owner, name);
	if (item >= 0) {
		const Entry *entry = item_at(item)->kind == ITEM_ROW ? entry_of(item) : NULL;

		return entry && same_row(&plan, entry) ? push_row(L, entry->record, entry->index) : refuse(L, different_change);
	}
	why = check_new_row(&plan);
	if (!why)
		why = publish_row(L, &plan, &record);
	if (why)
		return refuse(L, why);
	register_row(L, owner, name, &plan, record);
	return push_row(L, record, (UINT32)plan.table.records.size);
}

static const char *undo_row(lua_State *L, int item)
{
	Entry *entry = entry_of(item);
	Table table;
	const char *why;

	if (!entry)
		return "the row is not in the table";
	if (read_table(&table, entry->table) || table.vtable != entry->vtable)
		return "the table changed";
	if (record_at(&table, entry->index) != entry->record)
		return "the row is not in the table";
	if ((UINT32)table.records.size != entry->index + 1)
		return "rows were added after it";
	why = map_take(L, table.address + TABLE_KEYS, entry->key, entry->key_length, entry->index);
	if (why)
		return why;
	if (!pop_record(&table, entry->index))
		return write_failed;
	game_heap_free(L, entry->record, TRUE);
	entry->used = FALSE;
	return NULL;
}

static const char *row_state(int item)
{
	const Entry *entry = entry_of(item);
	Table table;

	if (!entry || read_table(&table, entry->table) || table.vtable != entry->vtable)
		return "missing";
	return record_at(&table, entry->index) == entry->record ? "ours" : "missing";
}

static void describe_row(lua_State *L, int item)
{
	const Entry *entry = entry_of(item);

	if (!entry)
		return;
	push_value(L, VALUE_POINTER, entry->table);
	lua_setfield(L, -2, "table");
	lua_pushstring(L, entry->key);
	lua_setfield(L, -2, "key");
	lua_pushnumber(L, (lua_Number)entry->index);
	lua_setfield(L, -2, "row");
}

const RowKind rows_kind = { add_row, undo_row, row_state, describe_row };
