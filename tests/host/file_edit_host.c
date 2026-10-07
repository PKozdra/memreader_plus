#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

typedef struct {
	int status;
	INT64 offset;
	int encoding;
} ParseResult;

typedef struct {
	INT32 length;
	UINT32 capacity;
	const char *data;
} HeapString;

typedef ParseResult *(*LoadBuffer)(void *document, ParseResult *result, const void *contents, size_t size, UINT32 options, UINT32 encoding);
typedef void (*ParseBuffer)(BYTE *parser, const void *contents, UINT32 size);
typedef UINT64 (*LoadLayoutFile)(void *library, HeapString *path, void *parent, UINT64 precaching);
typedef BYTE *(*NewFastXml)(BYTE *parser, HeapString *path);

void fake_load_buffer(void);
void fake_open_file(void);
void fake_parse_buffer(void);
void fake_new_document(void);
void fake_destroy_document(void);
void fake_load_layout_file(void);
void fake_new_fast_xml(void);
void fake_clear_from_cache(void);
void spare_sites(void);
const char *host_file_bytes(const char *path, size_t *size);

static const struct {
	const char *name;
	void (*code)(void);
} fakes[] = {
	{ "load_buffer", fake_load_buffer },
	{ "open_file_for_reading", fake_open_file },
	{ "parse_buffer", fake_parse_buffer },
	{ "xml_document", fake_new_document },
	{ "xml_document_destroy", fake_destroy_document },
	{ "load_layout_file", fake_load_layout_file },
	{ "fast_xml_parser", fake_new_fast_xml },
	{ "clear_from_cache", fake_clear_from_cache },
};

enum { SPARE_BYTES = 64, LAST_SIZE = 4096 };

static char last_text[LAST_SIZE];
static size_t last_size;
static int from_cache_calls;
static char last_key[260];
static BYTE game_document[64];
static BYTE game_parser[64];

static int balanced(const char *text, size_t size)
{
	int depth = 0;
	size_t i;

	for (i = 0; i < size && depth >= 0; i++)
		depth += text[i] == '<' ? 1 : text[i] == '>' ? -1 : 0;
	return depth == 0;
}

static void keep_text(const void *contents, size_t size)
{
	last_size = size < LAST_SIZE ? size : LAST_SIZE;
	memcpy(last_text, contents, last_size);
}

ParseResult *host_load_buffer(void *document, ParseResult *result, const void *contents, size_t size, UINT32 options, UINT32 encoding)
{
	(void)document;
	(void)options;
	keep_text(contents, size);
	result->status = balanced(contents, size) ? 0 : 11;
	result->offset = 0;
	result->encoding = (int)encoding;
	return result;
}

static int has_text(const char *text, size_t size, const char *needle)
{
	size_t length = strlen(needle), i;

	for (i = 0; i + length <= size; i++) {
		if (memcmp(text + i, needle, length) == 0)
			return 1;
	}
	return 0;
}

void host_parse_buffer(BYTE *parser, const void *contents, UINT32 size)
{
	keep_text(contents, size);
	parser[0] = (BYTE)(balanced(contents, size) && !has_text(contents, size, "fast_fail"));
}

UINT64 host_load_layout(void *library, HeapString *path, void *parent, UINT64 precaching)
{
	ParseResult result = { -1, 0, 0 };
	size_t size;
	const char *bytes = host_file_bytes(path->data, &size);

	(void)library;
	(void)parent;
	(void)precaching;
	((LoadBuffer)fake_load_buffer)(game_document, &result, bytes, size, 0, 1);
	return (UINT64)result.status;
}

void host_fast_xml(BYTE *parser, HeapString *path)
{
	size_t size;
	const char *bytes = host_file_bytes(path->data, &size);

	((ParseBuffer)fake_parse_buffer)(parser, bytes, (UINT32)size);
}

void host_clear_from_cache(void *unused, void *slot, HeapString *key)
{
	(void)unused;
	(void)slot;
	from_cache_calls++;
	strncpy_s(last_key, sizeof last_key, key->data, (size_t)key->length);
}

static HeapString path_string(lua_State *L)
{
	HeapString path;

	path.data = luaL_checkstring(L, 1);
	path.length = (INT32)strlen(path.data);
	path.capacity = (UINT32)path.length;
	return path;
}

static int push_parse(lua_State *L, int status)
{
	lua_pushlstring(L, last_text, last_size);
	lua_pushinteger(L, status);
	return 2;
}

static int l_test_load_layout(lua_State *L)
{
	HeapString path = path_string(L);
	UINT64 status = ((LoadLayoutFile)fake_load_layout_file)(NULL, &path, NULL, 0);

	return push_parse(L, (int)status);
}

static int l_test_load_screen(lua_State *L)
{
	ParseResult result = { -1, 0, 0 };
	size_t size;
	const char *bytes = host_file_bytes(luaL_checkstring(L, 1), &size);

	((LoadBuffer)fake_load_buffer)(game_document, &result, bytes, size, 0, 1);
	return push_parse(L, result.status);
}

static int l_test_fast_xml(lua_State *L)
{
	HeapString path = path_string(L);

	((NewFastXml)fake_new_fast_xml)(game_parser, &path);
	return push_parse(L, game_parser[0]);
}

static int l_test_cache_clears(lua_State *L)
{
	lua_pushinteger(L, from_cache_calls);
	lua_pushstring(L, last_key);
	return 2;
}

static int l_test_twin_site(lua_State *L)
{
	const char *name = luaL_checkstring(L, 1);
	BYTE *spare = (BYTE *)spare_sites;
	DWORD old;
	int i;

	for (i = 0; i < (int)(sizeof fakes / sizeof fakes[0]); i++) {
		if (strcmp(fakes[i].name, name) != 0)
			continue;
		VirtualProtect(spare, sizeof fakes / sizeof fakes[0] * SPARE_BYTES, PAGE_EXECUTE_READWRITE, &old);
		memcpy(spare + i * SPARE_BYTES, (const void *)fakes[i].code, SPARE_BYTES);
		VirtualProtect(spare, sizeof fakes / sizeof fakes[0] * SPARE_BYTES, old, &old);
		return 0;
	}
	return luaL_error(L, "no fake site %s", name);
}

void register_file_edit_tests(lua_State *L)
{
	lua_register(L, "test_load_layout", l_test_load_layout);
	lua_register(L, "test_load_screen", l_test_load_screen);
	lua_register(L, "test_fast_xml", l_test_fast_xml);
	lua_register(L, "test_cache_clears", l_test_cache_clears);
	lua_register(L, "test_twin_site", l_test_twin_site);
}
