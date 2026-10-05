#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdbool.h>
#include <string.h>

typedef union {
	struct {
		INT32 length;
		UINT32 capacity;
		void *data;
	} heap;
	struct {
		char text[15];
		BYTE tag_and_length;
	} in_place;
} HostString;

enum { IN_PLACE_BYTES = 14, IN_PLACE_TAG = 0x80 };

static volatile LONG live_blocks;

void *host_game_malloc(size_t size)
{
	void *block = HeapAlloc(GetProcessHeap(), 0, size);
	if (block)
		InterlockedIncrement(&live_blocks);
	return block;
}

void host_game_free(void *block)
{
	if (!block)
		return;
	HeapFree(GetProcessHeap(), 0, block);
	InterlockedDecrement(&live_blocks);
}

static void construct_string(HostString *string, const void *text, size_t length, size_t char_size)
{
	memset(string, 0, sizeof *string);
	if (length * char_size <= IN_PLACE_BYTES) {
		memcpy(string->in_place.text, text, length * char_size);
		string->in_place.tag_and_length = (BYTE)(IN_PLACE_TAG | length);
		return;
	}
	string->heap.length = (INT32)length;
	string->heap.capacity = (UINT32)length;
	string->heap.data = host_game_malloc((length + 1) * char_size);
	memcpy(string->heap.data, text, (length + 1) * char_size);
}

void host_string_construct(HostString *string, const char *text)
{
	construct_string(string, text, strlen(text), sizeof(char));
}

void host_unistring_construct(HostString *string, const WCHAR *text)
{
	construct_string(string, text, wcslen(text), sizeof(WCHAR));
}

void host_string_release(void *data)
{
	if (((UINT64)data >> 60) == 8)
		return;
	host_game_free(data);
}

typedef struct {
	void **vtable;
	const char *data;
	UINT64 size;
} HostStream;

static const struct {
	const char *path;
	const char *data;
	size_t size;
} host_files[] = {
	{ "text\\test\\hello.txt", "hello from a pack", 17 },
	{ "db\\test_tables\\binary", "\0\1\2\377", 4 },
	{ "text\\test\\empty.txt", "", 0 },
};

static volatile LONG open_streams;
static char host_vfs_object;
extern char host_empty_string[16];

void *host_vfs(void)
{
	return &host_vfs_object;
}

UINT64 *host_file_name(UINT64 *name, HostString *path)
{
	size_t i;

	*name = 0;
	for (i = 0; i < sizeof host_files / sizeof host_files[0]; i++) {
		if (strlen(host_files[i].path) == (size_t)path->heap.length && memcmp(host_files[i].path, path->heap.data, path->heap.length) == 0)
			*name = i + 1;
	}
	return name;
}

bool host_file_exists(void *vfs, UINT64 *name, char flag)
{
	return vfs == &host_vfs_object && flag == 0 && *name != 0;
}

static void host_stream_release(HostStream *stream)
{
	HeapFree(GetProcessHeap(), 0, stream);
	InterlockedDecrement(&open_streams);
}

static const char *host_stream_data(HostStream *stream)
{
	return stream->data;
}

static UINT64 host_stream_size(HostStream *stream)
{
	return stream->size;
}

static void *host_stream_vtable[] = { NULL, host_stream_release, NULL, NULL, host_stream_data, NULL, host_stream_size };

UINT64 *host_open_file(void *vfs, UINT64 *holder, UINT64 *name, UINT64 *options)
{
	HostStream *stream = HeapAlloc(GetProcessHeap(), 0, sizeof *stream);

	stream->vtable = host_stream_vtable;
	stream->data = host_files[*name - 1].data;
	stream->size = host_files[*name - 1].size;
	holder[0] = (UINT64)stream;
	holder[1] = holder[2] = holder[3] = options[0];
	InterlockedIncrement(&open_streams);
	return holder;
}

static UINT32 host_rotate(UINT32 value, int bits)
{
	return (value << bits) | (value >> (32 - bits));
}

static UINT32 host_murmur(const BYTE *data, size_t length)
{
	UINT32 hash = 0x4a545eed, tail = 0, block;
	size_t i;

	for (i = 0; i + 4 <= length; i += 4) {
		memcpy(&block, data + i, 4);
		hash = host_rotate(hash ^ (host_rotate(block * 0xcc9e2d51, 15) * 0x1b873593), 13) * 5 + 0xe6546b64;
	}
	if (length & 3) {
		size_t k;
		for (k = length & 3; k > 0; k--)
			tail = (tail << 8) | data[i + k - 1];
		hash ^= host_rotate(tail * 0xcc9e2d51, 15) * 0x1b873593;
	}
	hash ^= (UINT32)length;
	hash = (hash ^ (hash >> 16)) * 0x85ebca6b;
	hash = (hash ^ (hash >> 13)) * 0xc2b2ae35;
	return hash ^ (hash >> 16);
}

typedef struct HostNode {
	struct HostNode *previous;
	struct HostNode *next;
	HostString key;
	UINT64 index;
	UINT64 source;
} HostNode;

typedef struct {
	INT32 size;
	UINT32 padding;
	HostNode *last;
	HostNode *first;
	UINT32 bucket_capacity;
	UINT32 bucket_size;
	HostNode **buckets;
} HostMap;

static const char *host_text(HostString *string, size_t *length)
{
	if (((UINT64)string->heap.data >> 60) == 8) {
		*length = string->in_place.tag_and_length & 0xF;
		return string->in_place.text;
	}
	*length = string->heap.length;
	return string->heap.data;
}

UINT64 *host_emplace(HostMap *map, UINT64 *out, HostString *value)
{
	UINT32 count = map->bucket_size - 1, bucket;
	size_t length, other;
	const char *key = host_text(value, &length);
	HostNode *end, *node, *before;
	INT64 j;

	bucket = count ? host_murmur((const BYTE *)key, length) % count : 0;
	end = map->buckets[bucket + 1];
	for (node = map->buckets[bucket]; node != end; node = node->next) {
		const char *text = host_text(&node->key, &other);
		if (other == length && memcmp(text, key, length) == 0) {
			out[0] = (UINT64)node;
			out[1] = 0;
			return out;
		}
	}
	node = host_game_malloc(sizeof *node);
	node->key = *value;
	value->heap.length = 0;
	value->heap.capacity = 0;
	value->heap.data = host_empty_string;
	node->index = ((UINT64 *)value)[2];
	node->source = ((UINT64 *)value)[3];
	before = end->previous;
	node->previous = before;
	node->next = end;
	if (before)
		before->next = node;
	else
		map->first = node;
	end->previous = node;
	for (j = bucket; j >= 0 && map->buckets[j] == end; j--)
		map->buckets[j] = node;
	map->size++;
	out[0] = (UINT64)node;
	out[1] = 1;
	return out;
}

LONG host_live_blocks(void)
{
	return live_blocks;
}

LONG host_open_streams(void)
{
	return open_streams;
}
