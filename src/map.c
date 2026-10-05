#include <string.h>

#include "common.h"

enum {
	BUCKETS = sizeof(CaList),
	MAP_SIZE = BUCKETS + sizeof(CaVector),
	MAX_KEY_LENGTH = 4096,
	MAX_BUCKETS = 1 << 24,
	MAX_BUCKET_NODES = 1 << 20,
	MAX_INDEX = 0xFFFFFF
};

static const UINT32 HASH_SEED = 0x4a545eed;

static const char emplace_pattern[] =
	"48 8B C4 48 89 58 10 55 56 57 41 54 41 55 41 56 41 57 48 83 EC ?? 44 8B 69 1C 4D 8B E0 4C 89 40 18 48 8B F2 "
	"33 C0 4C 8B F1";

typedef struct {
	INT_PTR address;
	CaVector buckets;
	const char *key;
	size_t length;
} Map;

typedef struct {
	CaString key;
	UINT32 index;
	UINT32 padding;
	INT_PTR source;
} KeyValue;

_Static_assert(sizeof(KeyValue) == 0x20, "a DB key map value is a CA::String, an index and a source pointer");

static INT_PTR emplace_unique;

static UINT32 rotate(UINT32 value, int bits)
{
	return (value << bits) | (value >> (32 - bits));
}

static UINT32 mix_block(UINT32 block)
{
	return rotate(block * 0xcc9e2d51, 15) * 0x1b873593;
}

static UINT32 murmur_hash(const BYTE *data, size_t length)
{
	UINT32 hash = HASH_SEED, tail = 0;
	size_t i, blocks = length / 4;

	for (i = 0; i < blocks; i++) {
		UINT32 block;

		memcpy(&block, data + i * 4, sizeof block);
		hash = rotate(hash ^ mix_block(block), 13) * 5 + 0xe6546b64;
	}
	for (i = length & 3; i > 0; i--)
		tail = (tail << 8) | data[blocks * 4 + i - 1];
	if (length & 3)
		hash ^= mix_block(tail);
	hash ^= (UINT32)length;
	hash = (hash ^ (hash >> 16)) * 0x85ebca6b;
	hash = (hash ^ (hash >> 13)) * 0xc2b2ae35;
	return hash ^ (hash >> 16);
}

static void open_map(lua_State *L, Map *map)
{
	CaVector *buckets = &map->buckets;

	map->address = pointer_argument(L, 1);
	map->key = luaL_checklstring(L, 2, &map->length);
	if (map->length > MAX_KEY_LENGTH || strlen(map->key) != map->length)
		luaL_argerror(L, 2, lua_pushfstring(L, "must be a key of at most %d bytes without a zero byte", MAX_KEY_LENGTH));
	if (!copy_memory(buckets, map->address + BUCKETS, sizeof *buckets))
		luaL_error(L, "failed to read memory");
	if (buckets->size < 1 || buckets->size > MAX_BUCKETS || (UINT32)buckets->size > buckets->capacity || !buckets->data)
		luaL_error(L, "not a CA unordered map (bucket capacity %d, size %d)", (int)buckets->capacity, buckets->size);
}

static INT_PTR bucket_entry(const Map *map, UINT32 index)
{
	INT_PTR node = 0;

	copy_memory(&node, map->buckets.data + (INT_PTR)index * 8, sizeof node);
	return node;
}

static BOOL node_has_key(INT_PTR node, const Map *map)
{
	char text[MAX_KEY_LENGTH + 2];

	if (!read_ca_text(node + NODE_VALUE, FALSE, text, map->length + 2))
		return FALSE;
	return strlen(text) == map->length && memcmp(text, map->key, map->length) == 0;
}

static INT_PTR find_node(const Map *map)
{
	UINT32 count = (UINT32)map->buckets.size - 1;
	UINT32 bucket = count ? murmur_hash((const BYTE *)map->key, map->length) % count : 0;
	INT_PTR node = bucket_entry(map, bucket), end = bucket_entry(map, bucket + 1);
	int steps;

	for (steps = 0; node && node != end && steps < MAX_BUCKET_NODES; steps++) {
		if (node_has_key(node, map))
			return node;
		if (!copy_memory(&node, node + NODE_NEXT, sizeof node))
			return 0;
	}
	return 0;
}

static int l_map_find_key(lua_State *L)
{
	Map map;
	INT_PTR node;

	open_map(L, &map);
	node = find_node(&map);
	if (node)
		push_value(L, VALUE_POINTER, node);
	else
		lua_pushnil(L);
	return 1;
}

static int l_map_add_key(lua_State *L)
{
	Map map;
	__declspec(align(16)) KeyValue value;
	__declspec(align(16)) UINT64 result[2] = { 0, 0 };
	UINT64 arguments[3];

	open_map(L, &map);
	check_write(L, 1, NULL, map.address, MAP_SIZE);
	memset(&value, 0, sizeof value);
	value.index = (UINT32)whole_argument(L, 3, 0, MAX_INDEX, "index");
	value.source = pointer_argument(L, 4);
	if (!emplace_unique)
		emplace_unique = find_unique(emplace_pattern);
	if (!emplace_unique)
		return luaL_error(L, "the game's map insert was not found in this game build");
	make_game_string(L, &value.key, map.key);
	arguments[0] = (UINT64)map.address;
	arguments[1] = (UINT64)result;
	arguments[2] = (UINT64)&value;
	call_game(L, emplace_unique, arguments, 3);
	free_game_string(L, (INT_PTR)&value.key);
	push_value(L, VALUE_POINTER, (INT_PTR)result[0]);
	lua_pushboolean(L, (BYTE)result[1] != 0);
	return 2;
}

static BOOL write_pointer(INT_PTR address, INT_PTR value)
{
	return write_memory(address, &value, sizeof value);
}

static BOOL unhook_buckets(const Map *map, INT_PTR node, INT_PTR next)
{
	UINT32 i;

	for (i = 0; i < (UINT32)map->buckets.size; i++) {
		if (bucket_entry(map, i) == node && !write_pointer(map->buckets.data + (INT_PTR)i * 8, next))
			return FALSE;
	}
	return TRUE;
}

static BOOL unlink_node(const Map *map, INT_PTR node)
{
	INT_PTR links[2], first;
	INT32 size;

	if (!copy_memory(links, node + NODE_PREVIOUS, sizeof links) || !copy_memory(&first, map->address + LIST_FIRST, sizeof first) ||
		!copy_memory(&size, map->address + LIST_SIZE, sizeof size) || !unhook_buckets(map, node, links[1]))
		return FALSE;
	if (!write_pointer(first == node ? map->address + LIST_FIRST : links[0] + NODE_NEXT, links[1]))
		return FALSE;
	size--;
	return write_pointer(links[1] + NODE_PREVIOUS, links[0]) && write_memory(map->address + LIST_SIZE, &size, sizeof size);
}

static int l_map_remove_key(lua_State *L)
{
	Map map;
	INT_PTR node;

	open_map(L, &map);
	check_write(L, 1, NULL, map.address, MAP_SIZE);
	node = find_node(&map);
	if (!node) {
		lua_pushboolean(L, FALSE);
		return 1;
	}
	if (!unlink_node(&map, node))
		return luaL_error(L, "failed to write memory");
	free_game_string(L, node + NODE_VALUE);
	game_heap_free(L, node, TRUE);
	lua_pushboolean(L, TRUE);
	return 1;
}

const luaL_Reg map_functions[] = {
	{ "map_find_key", l_map_find_key },
	{ "map_add_key", l_map_add_key },
	{ "map_remove_key", l_map_remove_key },
	{ NULL, NULL }
};
