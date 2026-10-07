#include <stdio.h>
#include <string.h>

#include "game.h"

enum {
	SESSION_SIZE = 1 << 17,
	MAX_MODS = 2048,
	MAX_PATHS = 1024,
	MAX_SHADOWED = 256,
	MAX_SCRIPT_SIZE = 1 << 20,
	MOD_ENTRY_SIZE = 0x20,
	MOD_LIST_CALL_AT = 31,
	PATHS_DATA = 0x18,
	PATHS_COUNT = 0x20,
	PATH_ENTRY_SIZE = 0x10,
	GETTER_BYTES = 0x30,
	RIP_INSTRUCTION_SIZE = 7,
	MAX_MASKS = 4,
	MASK_SIZE = 3 * MAX_PATH,
	SHORTEST_MASK = 4
};

typedef struct {
	char text[MASK_SIZE];
	size_t length;
	const char *replacement;
} Mask;

typedef struct {
	char name[MAX_PATH];
	char path[MAX_PATH];
	UINT64 size;
	FILETIME written;
	int copies;
} Mod;

typedef struct {
	int mod;
	int path;
} Shadowed;

typedef struct {
	UINT32 capacity;
	UINT32 count;
	INT_PTR data;
} ModArray;

static const char mod_list_call[] = "48 89 78 20 41 56 48 81 EC ?? ?? ?? ?? E8 ?? ?? ?? ?? 80 3D ?? ?? ?? ?? 00 0F 85 ?? ?? ?? ?? E8";
static const char search_paths_call[] = "E8 ?? ?? ?? ?? 48 8B 58 18 48 8B 78 20 48 C1 E7 04 48 03 FB 48 3B DF 0F 84 ?? ?? ?? ?? 48 8D 15";
static const BYTE LEA_RAX[3] = { 0x48, 0x8D, 0x05 };
static const BYTE MOV_RAX[3] = { 0x48, 0x8B, 0x05 };
static const char workshop_marker[] = "\\workshop\\content\\1142710\\";
static const char game_user_data[] = "\\The Creative Assembly\\Warhammer3";
static const WCHAR steam_apps[] = L"\\steamapps\\";

static Mod mods[MAX_MODS];
static int mod_count;
static char paths[MAX_PATHS][MAX_PATH];
static int path_count;
static Shadowed shadowed[MAX_SHADOWED];
static int shadowed_count;
static char session_buffer[SESSION_SIZE];
static Text session = { session_buffer, sizeof session_buffer, 0 };
static Mask masks[MAX_MASKS];
static int mask_count;
static char command_line[4 * MAX_PATH];
static char user_data[MAX_PATH];
static char crash_folder[MAX_PATH];
static char script_name[MAX_PATH];
static const char *mods_source = "none found";
static BOOL described;

static void add_mask(const WCHAR *path, UINT code_page, const char *replacement)
{
	Mask *mask;
	int length;

	if (mask_count == MAX_MASKS)
		return;
	mask = &masks[mask_count];
	length = WideCharToMultiByte(code_page, 0, path, -1, mask->text, MASK_SIZE, NULL, NULL);
	if (length <= SHORTEST_MASK)
		return;
	mask->length = (size_t)length - 1;
	mask->replacement = replacement;
	mask_count++;
}

static void add_masks(const WCHAR *path, const char *replacement)
{
	add_mask(path, CP_UTF8, replacement);
	add_mask(path, CP_ACP, replacement);
}

static WCHAR *find_steam_apps(WCHAR *path)
{
	for (; *path; path++) {
		if (_wcsnicmp(path, steam_apps, ARRAYSIZE(steam_apps) - 1) == 0)
			return path;
	}
	return NULL;
}

static void find_masks(void)
{
	WCHAR path[MAX_PATH];
	WCHAR *library_end;
	DWORD length = GetEnvironmentVariableW(L"USERPROFILE", path, MAX_PATH);

	if (length && length < MAX_PATH)
		add_masks(path, "%USERPROFILE%");
	length = GetModuleFileNameW(NULL, path, MAX_PATH);
	if (!length || length >= MAX_PATH || !(library_end = find_steam_apps(path)))
		return;
	*library_end = L'\0';
	add_masks(path, "<Steam library>");
}

static const BYTE *rip_target(const BYTE *instruction)
{
	INT32 displacement;

	if (!copy_memory(&displacement, (INT_PTR)instruction + 3, sizeof displacement))
		return NULL;
	return instruction + RIP_INSTRUCTION_SIZE + displacement;
}

static const BYTE *getter_target(const BYTE *getter, const BYTE *opcode)
{
	BYTE bytes[GETTER_BYTES];
	int i;

	if (!copy_memory(bytes, (INT_PTR)getter, sizeof bytes))
		return NULL;
	for (i = 0; i + (int)sizeof LEA_RAX <= GETTER_BYTES; i++) {
		if (memcmp(bytes + i, opcode, sizeof LEA_RAX) == 0)
			return rip_target(getter + i);
	}
	return NULL;
}

static BOOL is_absolute(const char *path)
{
	return (path[0] && path[1] == ':') || (path[0] == '\\' && path[1] == '\\');
}

static void add_path(const char *path)
{
	char full[MAX_PATH];
	size_t length;
	int i;

	if (path_count == MAX_PATHS || !path[0])
		return;
	if (!(length = GetFullPathNameA(path, MAX_PATH, full, NULL)) || length >= MAX_PATH)
		return;
	while (length > 3 && (full[length - 1] == '\\' || full[length - 1] == '/'))
		full[--length] = '\0';
	for (i = 0; i < path_count; i++) {
		if (_stricmp(paths[i], full) == 0)
			return;
	}
	strncpy_s(paths[path_count++], MAX_PATH, full, _TRUNCATE);
}

static void add_mod(const char *name)
{
	if (mod_count < MAX_MODS && name[0])
		strncpy_s(mods[mod_count++].name, MAX_PATH, name, _TRUNCATE);
}

static BOOL read_path_string(INT_PTR address, char *out)
{
	if (read_ca_text(address, FALSE, out, MAX_PATH) && out[0] && strlen(out) > 1)
		return TRUE;
	return read_ca_text(address, TRUE, out, MAX_PATH) && out[0];
}

static BOOL read_mods_from_memory(void)
{
	INT_PTR call = find_unique(mod_list_call);
	INT_PTR getter = call ? call_destination(call + MOD_LIST_CALL_AT) : 0;
	const BYTE *array;
	ModArray list;
	char name[MAX_PATH];
	int i;

	if (!getter)
		return FALSE;
	array = getter_target((const BYTE *)getter, LEA_RAX);
	if (!array || !copy_memory(&list, (INT_PTR)array, sizeof list) || list.count > MAX_MODS)
		return FALSE;
	for (i = 0; i < (int)list.count; i++) {
		if (!read_ca_text(list.data + (INT_PTR)i * MOD_ENTRY_SIZE, FALSE, name, sizeof name))
			return FALSE;
		add_mod(name);
	}
	return TRUE;
}

static BOOL read_paths_from_memory(void)
{
	INT_PTR call = find_unique(search_paths_call);
	const BYTE *getter = call ? (const BYTE *)call_destination(call) : NULL;
	const BYTE *slot;
	int i;
	INT_PTR collection, data;
	UINT32 total;
	char path[MAX_PATH];

	if (!getter || !(slot = getter_target(getter, MOV_RAX)))
		return FALSE;
	if (!copy_memory(&collection, (INT_PTR)slot, sizeof collection) || !collection ||
		!copy_memory(&data, collection + PATHS_DATA, sizeof data) ||
		!copy_memory(&total, collection + PATHS_COUNT, sizeof total) || total > MAX_PATHS)
		return FALSE;
	for (i = 0; i < (int)total; i++) {
		if (read_path_string(data + (INT_PTR)i * PATH_ENTRY_SIZE, path))
			add_path(path);
	}
	return path_count > 0;
}

static char *trim(char *value)
{
	char *end;

	while (*value == ' ' || *value == '\t' || *value == '\r' || *value == '\n')
		value++;
	end = value + strlen(value);
	while (end > value && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n'))
		*--end = '\0';
	if (*value == '"' && end > value + 1 && end[-1] == '"') {
		end[-1] = '\0';
		value++;
	}
	return value;
}

static BOOL is_text_file(const char *name)
{
	size_t length = strlen(name);

	return length > 4 && _stricmp(name + length - 4, ".txt") == 0;
}

static void read_statement(char *statement, BOOL from_script)
{
	char *argument, *last;

	statement = trim(statement);
	argument = statement;
	last = strrchr(statement, ' ');
	last = last ? last + 1 : statement;
	if (!from_script && is_text_file(last) && strncmp(statement, "appdata_folder", 14) != 0) {
		strncpy_s(script_name, sizeof script_name, last, _TRUNCATE);
		return;
	}
	while (*argument && *argument != ' ' && *argument != '\t')
		argument++;
	if (*argument)
		*argument++ = '\0';
	argument = trim(argument);
	if (strcmp(statement, "appdata_folder") == 0)
		strncpy_s(user_data, sizeof user_data, argument, _TRUNCATE);
	else if (from_script && strcmp(statement, "add_working_directory") == 0)
		add_path(argument);
	else if (from_script && strcmp(statement, "mod") == 0)
		add_mod(argument);
}

static void read_statements(char *script, BOOL from_script)
{
	char *line = script;

	while (line && *line) {
		char *next = strchr(line, '\n');
		char *comment, *statement, *end;

		if (next)
			*next++ = '\0';
		if (from_script && (comment = strchr(line, '#')) != NULL)
			*comment = '\0';
		for (statement = line; statement; statement = end) {
			end = strchr(statement, ';');
			if (end)
				*end++ = '\0';
			read_statement(statement, from_script);
		}
		line = next;
	}
}

static const char *skip_program(const char *line)
{
	if (*line == '"') {
		line = strchr(line + 1, '"');
		return line ? line + 1 : "";
	}
	while (*line && *line != ' ')
		line++;
	return line;
}

static void read_command_line(void)
{
	char statements[sizeof command_line];

	WideCharToMultiByte(CP_UTF8, 0, GetCommandLineW(), -1, command_line, (int)sizeof command_line, NULL, NULL);
	command_line[sizeof command_line - 1] = '\0';
	strncpy_s(statements, sizeof statements, skip_program(command_line), _TRUNCATE);
	read_statements(statements, FALSE);
}

static char *read_script_file(const char *name)
{
	HANDLE file = CreateFileA(name, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
	DWORD size, got = 0;
	char *bytes, *utf8;
	int length;

	if (file == INVALID_HANDLE_VALUE)
		return NULL;
	size = GetFileSize(file, NULL);
	bytes = size < MAX_SCRIPT_SIZE ? HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, (SIZE_T)size + 2) : NULL;
	if (bytes)
		ReadFile(file, bytes, size, &got, NULL);
	CloseHandle(file);
	if (!bytes || got < 2 || (BYTE)bytes[0] != 0xFF || (BYTE)bytes[1] != 0xFE)
		return bytes;
	length = WideCharToMultiByte(CP_UTF8, 0, (WCHAR *)(bytes + 2), (int)(got - 2) / 2, NULL, 0, NULL, NULL);
	utf8 = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, (SIZE_T)length + 1);
	if (utf8)
		WideCharToMultiByte(CP_UTF8, 0, (WCHAR *)(bytes + 2), (int)(got - 2) / 2, utf8, length, NULL, NULL);
	HeapFree(GetProcessHeap(), 0, bytes);
	return utf8;
}

static void read_mods_from_script(void)
{
	char data[MAX_PATH];
	char *script;

	if (!script_name[0] || !(script = read_script_file(script_name)))
		return;
	if (GetFullPathNameA("data", MAX_PATH, data, NULL))
		add_path(data);
	read_statements(script + (strncmp(script, "\xEF\xBB\xBF", 3) == 0 ? 3 : 0), TRUE);
	HeapFree(GetProcessHeap(), 0, script);
	mods_source = "the mod file on the command line";
}

static void note_pack(int path, const WIN32_FIND_DATAA *found)
{
	int i;

	for (i = 0; i < mod_count; i++) {
		if (_stricmp(mods[i].name, found->cFileName) != 0)
			continue;
		if (mods[i].copies++ == 0) {
			_snprintf_s(mods[i].path, MAX_PATH, _TRUNCATE, "%s\\%s", paths[path], found->cFileName);
			mods[i].size = (UINT64)found->nFileSizeHigh << 32 | found->nFileSizeLow;
			mods[i].written = found->ftLastWriteTime;
		} else if (shadowed_count < MAX_SHADOWED) {
			shadowed[shadowed_count].mod = i;
			shadowed[shadowed_count++].path = path;
		}
	}
}

static void locate_packs(void)
{
	WIN32_FIND_DATAA found;
	char pattern[MAX_PATH + 8];
	HANDLE search;
	int i;

	for (i = 0; i < path_count; i++) {
		_snprintf_s(pattern, sizeof pattern, _TRUNCATE, "%s\\*.pack", paths[i]);
		search = FindFirstFileA(pattern, &found);
		if (search == INVALID_HANDLE_VALUE)
			continue;
		do {
			note_pack(i, &found);
		} while (FindNextFileA(search, &found));
		FindClose(search);
	}
	for (i = 0; i < mod_count; i++) {
		WIN32_FILE_ATTRIBUTE_DATA attributes;

		if (mods[i].copies || !is_absolute(mods[i].name) ||
			!GetFileAttributesExA(mods[i].name, GetFileExInfoStandard, &attributes))
			continue;
		strncpy_s(mods[i].path, MAX_PATH, mods[i].name, _TRUNCATE);
		mods[i].size = (UINT64)attributes.nFileSizeHigh << 32 | attributes.nFileSizeLow;
		mods[i].written = attributes.ftLastWriteTime;
		mods[i].copies = 1;
	}
}

static void add_workshop_id(const char *path)
{
	const char *at;
	size_t i;

	for (at = path; *at; at++) {
		if (_strnicmp(at, workshop_marker, sizeof workshop_marker - 1) != 0)
			continue;
		at += sizeof workshop_marker - 1;
		for (i = 0; at[i] >= '0' && at[i] <= '9'; i++)
			;
		add_text(&session, "  workshop %.*s", (int)i, at);
		return;
	}
}

static void add_mod_line(int index)
{
	const Mod *mod = &mods[index];
	FILETIME local;
	SYSTEMTIME time;

	add_text(&session, "  %3d. %s", index + 1, mod->name);
	if (!mod->copies) {
		add_text(&session, "  not found in any search path\n");
		return;
	}
	FileTimeToLocalFileTime(&mod->written, &local);
	FileTimeToSystemTime(&local, &time);
	add_text(&session, "  %llu bytes  %04d-%02d-%02d %02d:%02d", (unsigned long long)mod->size, time.wYear, time.wMonth, time.wDay,
		time.wHour, time.wMinute);
	add_workshop_id(mod->path);
	add_text(&session, "  %s\n", mod->path);
}

static void add_game_version(void)
{
	WCHAR exe[MAX_PATH];
	DWORD ignored, size;
	VS_FIXEDFILEINFO *info;
	UINT info_size;
	void *block;

	if (!GetModuleFileNameW(NULL, exe, MAX_PATH) || !(size = GetFileVersionInfoSizeW(exe, &ignored)) ||
		!(block = HeapAlloc(GetProcessHeap(), 0, size))) {
		add_text(&session, "unknown version");
		return;
	}
	if (GetFileVersionInfoW(exe, 0, size, block) && VerQueryValueW(block, L"\\", (void **)&info, &info_size))
		add_text(&session, "%u.%u.%u.%u", HIWORD(info->dwFileVersionMS), LOWORD(info->dwFileVersionMS), HIWORD(info->dwFileVersionLS),
			LOWORD(info->dwFileVersionLS));
	else
		add_text(&session, "unknown version");
	HeapFree(GetProcessHeap(), 0, block);
}

static void find_user_data(void)
{
	if (!user_data[0]) {
		GetEnvironmentVariableA("APPDATA", user_data, MAX_PATH);
		strncat_s(user_data, sizeof user_data, game_user_data, _TRUNCATE);
	}
	_snprintf_s(crash_folder, sizeof crash_folder, _TRUNCATE, "%s\\crash_report", user_data);
}

void describe_session(void)
{
	int i;

	if (described)
		return;
	described = TRUE;
	find_masks();
	read_command_line();
	find_user_data();
	if (read_mods_from_memory() && read_paths_from_memory())
		mods_source = "game memory";
	else {
		mod_count = path_count = 0;
		read_mods_from_script();
	}
	locate_packs();

	add_text(&session, "\nGame: Warhammer3.exe ");
	add_game_version();
	add_text(&session, ", memreader Plus %s\nCommand line: %s\nGame crash folder: %s\nMods in load order (%d, from %s):\n",
		MEMREADER_PLUS_VERSION, command_line, crash_folder, mod_count, mods_source);
	for (i = 0; i < mod_count; i++)
		add_mod_line(i);
	if (shadowed_count) {
		add_text(&session, "Same name in a later search path, not loaded:\n");
		for (i = 0; i < shadowed_count; i++)
			add_text(&session, "  %s  %s\n", mods[shadowed[i].mod].name, paths[shadowed[i].path]);
	}
}

static char path_char(char c)
{
	if (c == '/')
		return '\\';
	return c >= 'A' && c <= 'Z' ? (char)(c - 'A' + 'a') : c;
}

static BOOL is_mask_at(const char *at, size_t left, const Mask *mask)
{
	size_t i;

	if (mask->length > left)
		return FALSE;
	for (i = 0; i < mask->length; i++) {
		if (path_char(at[i]) != path_char(mask->text[i]))
			return FALSE;
	}
	return TRUE;
}

static const Mask *mask_at(const char *at, size_t left)
{
	int i;

	for (i = 0; i < mask_count; i++) {
		if (is_mask_at(at, left, &masks[i]))
			return &masks[i];
	}
	return NULL;
}

void write_redacted(HANDLE file, const char *data, size_t length)
{
	const Mask *mask;
	size_t start = 0, at = 0;
	DWORD written;

	while (at < length) {
		mask = mask_at(data + at, length - at);
		if (!mask) {
			at++;
			continue;
		}
		WriteFile(file, data + start, (DWORD)(at - start), &written, NULL);
		WriteFile(file, mask->replacement, (DWORD)strlen(mask->replacement), &written, NULL);
		at += mask->length;
		start = at;
	}
	WriteFile(file, data + start, (DWORD)(length - start), &written, NULL);
}

const char *session_text(size_t *length)
{
	*length = session.used;
	return session.data;
}

const char *game_crash_folder(void)
{
	return crash_folder;
}
