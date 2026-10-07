#include <stdio.h>
#include <string.h>

#include "file_edit.h"

enum { PUGI_UTF8 = 1, DOCUMENT_SIZE = 1024 };

enum SiteIndex {
	LOAD_BUFFER,
	OPEN_FILE,
	PARSE_BUFFER,
	NEW_DOCUMENT,
	DESTROY_DOCUMENT,
	LOAD_LAYOUT_FILE,
	NEW_FAST_XML,
	CLEAR_FROM_CACHE,
	SITE_COUNT
};

typedef struct {
	int status;
	INT64 offset;
	int encoding;
} ParseResult;

typedef ParseResult *(*LoadBuffer)(void *document, ParseResult *result, const void *contents, size_t size, UINT32 options, UINT32 encoding);
typedef void (*ParseBuffer)(BYTE *parser, const void *contents, UINT32 size);
typedef UINT64 (*LoadLayoutFile)(void *library, const CaString *path, void *parent, UINT64 precaching);
typedef BYTE *(*NewFastXml)(BYTE *parser, const CaString *path);
typedef void (*DocumentFunction)(void *document);
typedef void (*ClearFromCache)(void *library, const CaString *path);

typedef struct {
	const char *name;
	const char *pattern;
	void *detour;
	const char *loss;
	INT_PTR address;
	void *next;
	char problem[32];
} Site;

static ParseResult *on_load_buffer(void *document, ParseResult *result, const void *contents, size_t size, UINT32 options, UINT32 encoding);
static void on_parse_buffer(BYTE *parser, const void *contents, UINT32 size);
static UINT64 on_load_layout_file(void *library, const CaString *path, void *parent, UINT64 precaching);
static BYTE *on_new_fast_xml(BYTE *parser, const CaString *path);

static Site sites[SITE_COUNT] = {
	{ "load_buffer",
		"48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC ?? 49 8B F9 49 8B F0 48 8B EA 48 8B D9 E8 ?? ?? ?? ?? 48 8B CB "
		"E8 ?? ?? ?? ?? 4C 8B 03",
		(void *)on_load_buffer, "file edits are off" },
	{ "open_file_for_reading", "4C 8B DC 49 89 5B 10 49 89 73 18 49 89 7B 20 49 89 4B 08 55 41 56 41 57 48 8B EC 48 83 EC ?? 45 33 FF", NULL, "file edits are off" },
	{ "parse_buffer", "48 89 5C 24 08 48 89 74 24 10 57 48 83 EC ?? 41 8B F8 48 8B D9 48 8B F2 8D 4F 01 E8 ?? ?? ?? ?? 48 8B 4B 08",
		(void *)on_parse_buffer, "edits to FAST_XML files such as models and materials are refused" },
	{ "xml_document", "48 83 EC ?? 48 83 21 00 4C 8B D1 48 83 61 08 00 E8 ?? ?? ?? ?? 49 8B C2 48 83 C4 ?? C3 CC CC CC 45 33 C9", NULL,
		"edits are not checked before use, and edits to FAST_XML files are refused" },
	{ "xml_document_destroy", "48 89 5C 24 08 57 48 83 EC ?? 48 8B F9 48 8B 49 08 48 85 C9 0F 85 ?? ?? ?? ?? 48 8B 07 48 8B 58 58", NULL,
		"edits are not checked before use, and edits to FAST_XML files are refused" },
	{ "load_layout_file",
		"48 89 5C 24 08 4C 89 44 24 18 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 E0 FD FF FF 48 81 EC 20 03 00 00",
		(void *)on_load_layout_file, "layout edits are matched by their bytes only" },
	{ "fast_xml_parser", "48 89 5C 24 10 48 89 74 24 18 57 48 83 EC ?? 33 FF 48 8B F1 40 88 39 48 8B DA 48 89 79 08 B9 ?? ?? ?? ?? E8",
		(void *)on_new_fast_xml, "FAST_XML edits are matched by their bytes only" },
	{ "clear_from_cache", "48 89 5C 24 08 57 48 83 EC ?? 48 8B DA E8 ?? ?? ?? ?? 44 8B C8 48 8D 54 24 20 4C 8B C3 8B F8 E8", NULL,
		"a layout edit reaches only layouts the game has not cached yet" },
};

static const char *off_reason;
static BOOL started;
static LONG pugi_calls;
static LONG fast_calls;
static DWORD layout_slot = TLS_OUT_OF_INDEXES;
static DWORD fast_slot = TLS_OUT_OF_INDEXES;

static void slot_path(DWORD slot, BOOL layout, char *path)
{
	const CaString *named = TlsGetValue(slot);
	char raw[PATH_SIZE];

	TlsSetValue(slot, NULL);
	path[0] = '\0';
	if (named && read_ca_text((INT_PTR)named, FALSE, raw, sizeof raw))
		normal_path(raw, layout, path);
}

static ParseResult *on_load_buffer(void *document, ParseResult *result, const void *contents, size_t size, UINT32 options, UINT32 encoding)
{
	LoadBuffer original = (LoadBuffer)sites[LOAD_BUFFER].next;
	char path[PATH_SIZE];
	Taken taken;

	InterlockedIncrement(&pugi_calls);
	slot_path(layout_slot, TRUE, path);
	if (!take_edit(contents, size, path, &taken))
		return original(document, result, contents, size, options, encoding);
	original(document, result, taken.result->bytes, taken.result->size, options, encoding);
	give_back(&taken, result->status != 0);
	if (result->status == 0)
		return result;
	return original(document, result, contents, size, options, encoding);
}

static void on_parse_buffer(BYTE *parser, const void *contents, UINT32 size)
{
	ParseBuffer original = (ParseBuffer)sites[PARSE_BUFFER].next;
	char path[PATH_SIZE];
	Taken taken;

	InterlockedIncrement(&fast_calls);
	slot_path(fast_slot, FALSE, path);
	if (!take_edit(contents, size, path, &taken)) {
		original(parser, contents, size);
		return;
	}
	original(parser, taken.result->bytes, (UINT32)taken.result->size);
	give_back(&taken, !parser[0]);
}

static UINT64 on_load_layout_file(void *library, const CaString *path, void *parent, UINT64 precaching)
{
	void *outer = TlsGetValue(layout_slot);
	UINT64 result = 0;

	TlsSetValue(layout_slot, (void *)path);
	__try {
		result = ((LoadLayoutFile)sites[LOAD_LAYOUT_FILE].next)(library, path, parent, precaching);
	} __finally {
		TlsSetValue(layout_slot, outer);
	}
	return result;
}

static BYTE *on_new_fast_xml(BYTE *parser, const CaString *path)
{
	void *outer = TlsGetValue(fast_slot);
	BYTE *result = NULL;

	TlsSetValue(fast_slot, (void *)path);
	__try {
		result = ((NewFastXml)sites[NEW_FAST_XML].next)(parser, path);
	} __finally {
		TlsSetValue(fast_slot, outer);
	}
	return result;
}

static void find_site(Site *site)
{
	const BYTE *found[2];
	int count = find_code_all(site->pattern, found, 2);

	site->address = count == 1 ? (INT_PTR)found[0] : 0;
	if (count == 0)
		strcpy_s(site->problem, sizeof site->problem, "not found");
	else if (count > 1)
		sprintf_s(site->problem, sizeof site->problem, "found %d times", count);
}

static BOOL detour(Site *site)
{
	if (site->address && !hook_native(site->address, site->detour, "file edits", &site->next)) {
		site->address = 0;
		strcpy_s(site->problem, sizeof site->problem, "could not be hooked");
	}
	return site->address != 0;
}

static const char *off_because(const Site *site)
{
	static char reason[64];

	sprintf_s(reason, sizeof reason, "off: %s %s", site->name, site->problem);
	return reason;
}

const char *start_file_edits(void)
{
	int i;

	if (started)
		return off_reason;
	started = TRUE;
	layout_slot = TlsAlloc();
	fast_slot = TlsAlloc();
	for (i = 0; i < SITE_COUNT; i++)
		find_site(&sites[i]);
	if (layout_slot == TLS_OUT_OF_INDEXES || fast_slot == TLS_OUT_OF_INDEXES)
		off_reason = "off: no thread slots";
	else if (!sites[OPEN_FILE].address)
		off_reason = off_because(&sites[OPEN_FILE]);
	else if (!detour(&sites[LOAD_BUFFER]))
		off_reason = off_because(&sites[LOAD_BUFFER]);
	if (off_reason)
		return off_reason;
	for (i = PARSE_BUFFER; i < SITE_COUNT; i++) {
		if (sites[i].detour)
			detour(&sites[i]);
	}
	return NULL;
}

const char *file_edit_state(void)
{
	return !started ? "not started" : off_reason ? off_reason : "on";
}

INT_PTR open_file_site(void)
{
	return sites[OPEN_FILE].address;
}

static BOOL can_validate(void)
{
	return sites[NEW_DOCUMENT].address && sites[DESTROY_DOCUMENT].address;
}

static BOOL ends_with(const char *text, const char *end)
{
	size_t length = strlen(text), end_length = strlen(end);

	return length >= end_length && strcmp(text + length - end_length, end) == 0;
}

BOOL can_edit(const char *path)
{
	BOOL pugi = ends_with(path, ".twui.xml") || ends_with(path, ".warscape_req.xml");

	return pugi || (sites[PARSE_BUFFER].address && can_validate());
}

int parse_status(const char *text, size_t size)
{
	__declspec(align(16)) BYTE document[DOCUMENT_SIZE] = { 0 };
	ParseResult result = { -1, 0, 0 };

	if (!can_validate())
		return 0;
	__try {
		((DocumentFunction)sites[NEW_DOCUMENT].address)(document);
		((LoadBuffer)sites[LOAD_BUFFER].next)(document, &result, text, size, 0, PUGI_UTF8);
		((DocumentFunction)sites[DESTROY_DOCUMENT].address)(document);
	} __except (EXCEPTION_EXECUTE_HANDLER) {
		return -1;
	}
	return result.status;
}

const char *evict_layout(const char *path)
{
	static const char cannot[] = "applies from the next parse only: the layout cache cannot be cleared";
	INT_PTR clear = sites[CLEAR_FROM_CACHE].address;
	CaString key = { 0 };

	if (!ends_with(path, ".twui.xml"))
		return NULL;
	if (!clear)
		return cannot;
	key.heap.length = (INT32)strlen(path);
	key.heap.capacity = (UINT32)key.heap.length;
	key.heap.data = (INT_PTR)path;
	__try {
		((ClearFromCache)clear)(NULL, &key);
	} __except (EXCEPTION_EXECUTE_HANDLER) {
		return cannot;
	}
	if (strncmp(path, "ui\\templates\\", 13) == 0)
		return "applies to layouts read from now on: layouts the game already holds keep the old template";
	return NULL;
}

void count_hand_offs(LONG *pugi, LONG *fast_xml)
{
	*pugi = pugi_calls;
	*fast_xml = fast_calls;
}

void push_sites(lua_State *L)
{
	int i;

	lua_createtable(L, 0, SITE_COUNT);
	for (i = 0; started && i < SITE_COUNT; i++) {
		if (sites[i].problem[0])
			lua_pushfstring(L, "%s: %s", sites[i].problem, sites[i].loss);
		else
			lua_pushboolean(L, 1);
		lua_setfield(L, -2, sites[i].name);
	}
}

static void add_part(lua_State *L, const char *part, BOOL off)
{
	if (!off)
		return;
	lua_pushstring(L, part);
	lua_rawseti(L, -2, (int)lua_objlen(L, -2) + 1);
}

void push_parts_off(lua_State *L)
{
	lua_newtable(L);
	if (!started || off_reason)
		return;
	add_part(L, "fast_xml", !sites[PARSE_BUFFER].address || !can_validate());
	add_part(L, "validation", !can_validate());
	add_part(L, "path_check", !sites[LOAD_LAYOUT_FILE].address || !sites[NEW_FAST_XML].address);
	add_part(L, "eviction", !sites[CLEAR_FROM_CACHE].address);
}
