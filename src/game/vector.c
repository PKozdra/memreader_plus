#include "game.h"

enum { MAX_STRIDE = 4096, FIRST_CAPACITY = 4 };

static const INT64 MAX_VECTOR_BYTES = 0x7FFFFFFF;

typedef struct {
	INT_PTR address;
	CaVector header;
	size_t stride;
} Vector;

static void check_vector(lua_State *L, Vector *vector)
{
	CaVector *header = &vector->header;

	if (!copy_memory(header, vector->address, sizeof *header))
		luaL_error(L, "failed to read memory");
	if (header->size < 0 || (UINT32)header->size > header->capacity || (header->size > 0 && !header->data) ||
		(INT64)header->capacity * (INT64)vector->stride > MAX_VECTOR_BYTES)
		luaL_error(L, "not a CA vector (capacity %d, size %d)", (int)header->capacity, header->size);
}

static void open_vector(lua_State *L, Vector *vector)
{
	vector->address = address_argument(L, 1);
	check_write(L, 1, NULL, vector->address, sizeof vector->header);
	vector->stride = (size_t)whole_argument(L, 3, 1, MAX_STRIDE, "stride");
	check_vector(L, vector);
}

static void grow(lua_State *L, Vector *vector, INT64 capacity)
{
	CaVector *header = &vector->header;
	INT_PTR data;

	if (capacity <= (INT64)header->capacity)
		return;
	if (capacity * (INT64)vector->stride > MAX_VECTOR_BYTES)
		luaL_error(L, "a vector of %d elements of %d bytes is too large", (int)capacity, (int)vector->stride);
	data = game_heap_alloc(L, (size_t)capacity * vector->stride);
	if (header->size > 0 && !copy_memory((void *)data, header->data, (size_t)header->size * vector->stride))
		luaL_error(L, "failed to read memory");
	if (header->data)
		game_heap_free(L, header->data, TRUE);
	header->capacity = (UINT32)capacity;
	header->data = data;
	write_memory(vector->address, header, sizeof *header);
}

static INT64 next_capacity(const Vector *vector)
{
	INT64 size = vector->header.size;
	INT64 doubled = size ? size * 2 : FIRST_CAPACITY;

	return doubled * (INT64)vector->stride > MAX_VECTOR_BYTES ? size + 1 : doubled;
}

static BOOL move_elements(const Vector *vector, INT64 from, INT64 to, INT64 count)
{
	INT_PTR data = vector->header.data;
	INT64 stride = (INT64)vector->stride;

	return count <= 0 || write_memory(data + (INT_PTR)(to * stride), (const void *)(data + (INT_PTR)(from * stride)), (size_t)(count * stride));
}

static int l_vector_reserve(lua_State *L)
{
	Vector vector;

	open_vector(L, &vector);
	grow(L, &vector, whole_argument(L, 4, 0, MAX_VECTOR_BYTES, "capacity"));
	return 0;
}

static int l_vector_insert(lua_State *L)
{
	Vector vector;
	INT64 position, size;
	size_t length = 0;
	const char *bytes;
	INT_PTR element;

	open_vector(L, &vector);
	size = vector.header.size;
	position = whole_argument(L, 4, 1, size + 1, "position");
	bytes = lua_isnoneornil(L, 5) ? NULL : luaL_checklstring(L, 5, &length);
	if (bytes && length != vector.stride)
		return luaL_argerror(L, 5, lua_pushfstring(L, "must be %d bytes, the stride", (int)vector.stride));
	if (size == (INT64)vector.header.capacity)
		grow(L, &vector, next_capacity(&vector));
	element = vector.header.data + (INT_PTR)((position - 1) * (INT64)vector.stride);
	if (!move_elements(&vector, position - 1, position, size - position + 1) ||
		!(bytes ? write_memory(element, bytes, vector.stride) : zero_memory(element, vector.stride)))
		return luaL_error(L, "failed to write memory");
	vector.header.size++;
	write_memory(vector.address, &vector.header, sizeof vector.header);
	push_value(L, VALUE_POINTER, element);
	return 1;
}

static int l_vector_erase(lua_State *L)
{
	Vector vector;
	INT64 position, count, size;

	open_vector(L, &vector);
	size = vector.header.size;
	if (size == 0)
		return luaL_error(L, "the vector is empty");
	position = whole_argument(L, 4, 1, size, "position");
	count = lua_isnoneornil(L, 5) ? 1 : whole_argument(L, 5, 1, size - position + 1, "count");
	if (!move_elements(&vector, position - 1 + count, position - 1, size - position + 1 - count))
		return luaL_error(L, "failed to write memory");
	zero_memory(vector.header.data + (INT_PTR)((size - count) * (INT64)vector.stride), (size_t)count * vector.stride);
	vector.header.size = (INT32)(size - count);
	write_memory(vector.address, &vector.header, sizeof vector.header);
	return 0;
}

const luaL_Reg vector_functions[] = {
	{ "vector_reserve", l_vector_reserve },
	{ "vector_insert", l_vector_insert },
	{ "vector_erase", l_vector_erase },
	{ NULL, NULL }
};
