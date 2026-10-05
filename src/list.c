#include "common.h"

enum { MAX_VALUE = 4096, MAX_NODES = 131072 };

typedef struct {
	INT_PTR address;
	INT_PTR end;
	INT32 size;
} List;

static void open_list(lua_State *L, List *list)
{
	list->address = address_argument(L, 1);
	check_write(L, 1, NULL, list->address, sizeof(CaList));
	list->end = list->address + LIST_END;
	if (!copy_memory(&list->size, list->address + LIST_SIZE, sizeof list->size))
		luaL_error(L, "failed to read memory");
	if (list->size < 0 || list->size > MAX_NODES)
		luaL_error(L, "not a CA list (size %d)", list->size);
}

static INT_PTR read_link(lua_State *L, INT_PTR node, int offset)
{
	INT_PTR link;

	if (!copy_memory(&link, node + offset, sizeof link))
		luaL_error(L, "failed to read memory");
	return link;
}

static INT_PTR node_at(lua_State *L, const List *list, INT64 position)
{
	INT_PTR node = read_link(L, list->address, LIST_FIRST), previous = 0;
	INT64 i;

	for (i = 1; i < position; i++) {
		if (node == list->end || read_link(L, node, NODE_PREVIOUS) != previous)
			luaL_error(L, "the list's links are broken at node %d", (int)i);
		previous = node;
		node = read_link(L, node, NODE_NEXT);
	}
	return node;
}

static BOOL write_link(INT_PTR node, int offset, INT_PTR link)
{
	return write_memory(node + offset, &link, sizeof link);
}

static BOOL write_size(const List *list, INT32 size)
{
	return write_memory(list->address + LIST_SIZE, &size, sizeof size);
}

static int l_list_insert(lua_State *L)
{
	List list;
	INT64 position;
	INT_PTR after, before, node;
	size_t length;
	const char *bytes;

	open_list(L, &list);
	position = whole_argument(L, 3, 1, (INT64)list.size + 1, "position");
	bytes = luaL_checklstring(L, 4, &length);
	if (length < 1 || length > MAX_VALUE)
		return luaL_argerror(L, 4, lua_pushfstring(L, "the value must be 1 to %d bytes", MAX_VALUE));
	after = node_at(L, &list, position);
	before = read_link(L, after, NODE_PREVIOUS);
	node = game_heap_alloc(L, NODE_VALUE + length);
	if (!write_link(node, NODE_PREVIOUS, before) || !write_link(node, NODE_NEXT, after) ||
		!write_memory(node + NODE_VALUE, bytes, length) ||
		!write_link(before ? before : list.address, before ? NODE_NEXT : LIST_FIRST, node) ||
		!write_link(after, NODE_PREVIOUS, node) || !write_size(&list, list.size + 1))
		return luaL_error(L, "failed to write memory");
	push_value(L, VALUE_POINTER, node);
	return 1;
}

static void erase_node(lua_State *L, const List *list, INT_PTR node)
{
	INT_PTR before = read_link(L, node, NODE_PREVIOUS), after = read_link(L, node, NODE_NEXT);

	if (!write_link(before ? before : list->address, before ? NODE_NEXT : LIST_FIRST, after) ||
		!write_link(after, NODE_PREVIOUS, before))
		luaL_error(L, "failed to write memory");
	game_heap_free(L, node, TRUE);
}

static int l_list_erase(lua_State *L)
{
	List list;
	INT64 position, count, i;
	INT_PTR node;

	open_list(L, &list);
	if (list.size == 0)
		return luaL_error(L, "the list is empty");
	position = whole_argument(L, 3, 1, list.size, "position");
	count = lua_isnoneornil(L, 4) ? 1 : whole_argument(L, 4, 1, list.size - position + 1, "count");
	node = node_at(L, &list, position);
	for (i = 0; i < count; i++) {
		INT_PTR next = read_link(L, node, NODE_NEXT);

		erase_node(L, &list, node);
		node = next;
	}
	if (!write_size(&list, list.size - (INT32)count))
		return luaL_error(L, "failed to write memory");
	return 0;
}

const luaL_Reg list_functions[] = {
	{ "list_insert", l_list_insert },
	{ "list_erase", l_list_erase },
	{ NULL, NULL }
};
