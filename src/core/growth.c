#include "common.h"

void *resize_block(void *block, size_t size)
{
	HANDLE heap = GetProcessHeap();

	return block ? HeapReAlloc(heap, 0, block, size) : HeapAlloc(heap, 0, size);
}

int chunk_room(const Chunks *chunks)
{
	return (int)chunks->made * chunks->per_chunk;
}

void *chunk_slot(const Chunks *chunks, int index)
{
	return chunks->chunks[index / chunks->per_chunk] + (size_t)(index % chunks->per_chunk) * chunks->element_size;
}

BOOL reserve_chunks(Chunks *chunks, int needed)
{
	while (chunk_room(chunks) < needed) {
		LONG next = chunks->made;
		BYTE *block;

		if (next == chunks->max_chunks)
			return FALSE;
		block = VirtualAlloc(NULL, chunks->element_size * (size_t)chunks->per_chunk, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
		if (!block)
			return FALSE;
		chunks->chunks[next] = block;
		MemoryBarrier();
		InterlockedExchange(&chunks->made, next + 1);
	}
	return TRUE;
}

void push_capacity(lua_State *L, const char *name, Capacity use)
{
	lua_createtable(L, 0, 3);
	lua_pushnumber(L, (lua_Number)use.used);
	lua_setfield(L, -2, "used");
	lua_pushnumber(L, (lua_Number)use.room);
	lua_setfield(L, -2, "room");
	lua_pushnumber(L, (lua_Number)use.limit);
	lua_setfield(L, -2, "limit");
	lua_setfield(L, -2, name);
}

void push_core_capacity(lua_State *L)
{
	Capacity owners, items, claims, held, saved, cache;

	registry_capacity(&owners, &items, &claims, &held);
	scan_capacity(&saved, &cache);
	lua_createtable(L, 0, 13);
	push_capacity(L, "owners", owners);
	push_capacity(L, "items", items);
	push_capacity(L, "claims", claims);
	push_capacity(L, "held_bytes", held);
	push_capacity(L, "hooks", hook_capacity());
	push_capacity(L, "saved_code", saved);
	push_capacity(L, "pattern_cache", cache);
	push_capacity(L, "cave_pages", cave_capacity());
	lua_pushnumber(L, (lua_Number)hop_slots_left());
	lua_setfield(L, -2, "hop_slots");
}

void add_capacity(Text *report)
{
	Capacity owners, items, claims, held, saved, cache, hooks = hook_capacity();

	registry_capacity(&owners, &items, &claims, &held);
	scan_capacity(&saved, &cache);
	add_text(report, "memreader Plus capacity: owners %d/%d, items %d/%d, claims %d/%d, held bytes %d/%d, saved code %d/%d, hooks %d/%d\n", owners.used,
		owners.limit, items.used, items.limit, claims.used, claims.limit, held.used, held.limit, saved.used, saved.limit, hooks.used, hooks.limit);
}
