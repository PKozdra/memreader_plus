#include <string.h>

#include "common.h"

enum {
	MAX_PATH_LENGTH = 1024,
	MAX_FILE_SIZE = 64 * 1024 * 1024,
	VFS_CALL = 0,
	FILE_NAME_CALL = 13,
	EXISTS_CALL = 24,
	OPEN_CALL = 82,
	HOLDER_WORDS = 4,
	OPTION_WORDS = 3,
	RELEASE_SLOT = 1,
	DATA_SLOT = 4,
	SIZE_SLOT = 6
};

static const char loader_pattern[] =
	"E8 ?? ?? ?? ?? 48 8D 55 E7 48 8D 4D 77 E8 ?? ?? ?? ?? 45 33 C0 48 8B D0 E8 ?? ?? ?? ?? 84 C0 75 08 83 CB FF "
	"E9 ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 8D 55 E7 48 89 7D 27 48 8D 4D 77 48 89 7D 2F 40 88 7D 37 E8 ?? ?? ?? ?? "
	"4C 8D 4D 27 4C 8B C0 48 8D 55 F7 E8 ?? ?? ?? ?? 48 8B 75 F7";

typedef struct {
	INT_PTR vfs;
	INT_PTR file_name;
	INT_PTR exists;
	INT_PTR open;
} FileFunctions;

typedef struct {
	UINT64 vfs;
	UINT64 name;
} PackFile;

static FileFunctions files;

static void find_files(lua_State *L)
{
	INT_PTR loader;

	if (files.open)
		return;
	loader = find_unique(loader_pattern);
	if (loader) {
		files.vfs = call_destination(loader + VFS_CALL);
		files.file_name = call_destination(loader + FILE_NAME_CALL);
		files.exists = call_destination(loader + EXISTS_CALL);
		files.open = call_destination(loader + OPEN_CALL);
	}
	if (!files.vfs || !files.file_name || !files.exists || !files.open) {
		files.open = 0;
		luaL_error(L, "the game's file functions were not found in this game build");
	}
}

static BOOL is_disk_path(const char *text, size_t length)
{
	size_t i;

	if (memchr(text, ':', length) || (text[0] == '\\' && text[1] == '\\'))
		return TRUE;
	for (i = 0; i + 1 < length; i++) {
		BOOL starts = i == 0 || text[i - 1] == '\\';
		BOOL ends = i + 2 == length || text[i + 2] == '\\';

		if (starts && ends && text[i] == '.' && text[i + 1] == '.')
			return TRUE;
	}
	return FALSE;
}

static void open_name(lua_State *L, PackFile *file)
{
	size_t length, i;
	const char *path = luaL_checklstring(L, 1, &length);
	char text[MAX_PATH_LENGTH + 1];
	__declspec(align(16)) CaString name;
	UINT64 arguments[2] = { 0, 0 };

	if (length == 0 || length > MAX_PATH_LENGTH || strlen(path) != length)
		luaL_argerror(L, 1, lua_pushfstring(L, "must be a path of 1 to %d bytes without a zero byte", MAX_PATH_LENGTH));
	for (i = 0; i < length; i++)
		text[i] = path[i] == '/' ? '\\' : path[i];
	text[length] = '\0';
	if (is_disk_path(text, length))
		luaL_argerror(L, 1, "must be a path inside the packs: no drive letter, no leading \\\\ and no .. part");
	find_files(L);
	name.heap.length = (INT32)length;
	name.heap.capacity = (UINT32)length;
	name.heap.data = (INT_PTR)text;
	file->vfs = call_game(L, files.vfs, arguments, 0);
	arguments[0] = (UINT64)&file->name;
	arguments[1] = (UINT64)&name;
	call_game(L, files.file_name, arguments, 2);
}

static BOOL exists(lua_State *L, PackFile *file)
{
	UINT64 arguments[3] = { file->vfs, (UINT64)&file->name, 0 };

	return (BYTE)call_game(L, files.exists, arguments, 3) != 0;
}

static UINT64 stream_call(lua_State *L, INT_PTR stream, int slot)
{
	INT_PTR vtable = 0, function = 0;
	UINT64 argument = (UINT64)stream;

	if (!copy_memory(&vtable, stream, sizeof vtable) || !copy_memory(&function, vtable + slot * 8, sizeof function))
		luaL_error(L, "failed to read memory");
	return call_game(L, function, &argument, 1);
}

static int read_stream(lua_State *L)
{
	INT_PTR stream = (INT_PTR)lua_touserdata(L, 1);
	UINT64 size = stream_call(L, stream, SIZE_SLOT);
	INT_PTR data;
	void *buffer;

	if (size > MAX_FILE_SIZE)
		return luaL_error(L, "the file is larger than %d bytes", MAX_FILE_SIZE);
	if (size == 0) {
		lua_pushliteral(L, "");
		return 1;
	}
	data = (INT_PTR)stream_call(L, stream, DATA_SLOT);
	buffer = lua_newuserdata(L, (size_t)size);
	if (!data || !copy_memory(buffer, data, (size_t)size))
		return luaL_error(L, "failed to read memory");
	lua_pushlstring(L, buffer, (size_t)size);
	lua_remove(L, -2);
	return 1;
}

static int l_read_pack_file(lua_State *L)
{
	PackFile file;
	__declspec(align(16)) UINT64 holder[HOLDER_WORDS] = { 0 };
	__declspec(align(16)) UINT64 options[OPTION_WORDS] = { 0 };
	UINT64 arguments[4];
	int status;

	open_name(L, &file);
	if (!exists(L, &file)) {
		lua_pushnil(L);
		return 1;
	}
	arguments[0] = file.vfs;
	arguments[1] = (UINT64)holder;
	arguments[2] = (UINT64)&file.name;
	arguments[3] = (UINT64)options;
	call_game(L, files.open, arguments, 4);
	if (!holder[0])
		return luaL_error(L, "the game opened no stream for this file");
	lua_pushcfunction(L, read_stream);
	lua_pushlightuserdata(L, (void *)holder[0]);
	status = lua_pcall(L, 1, 1, 0);
	stream_call(L, (INT_PTR)holder[0], RELEASE_SLOT);
	if (status)
		return lua_error(L);
	return 1;
}

static int l_pack_file_exists(lua_State *L)
{
	PackFile file;

	open_name(L, &file);
	lua_pushboolean(L, exists(L, &file));
	return 1;
}

const luaL_Reg pack_functions[] = {
	{ "read_pack_file", l_read_pack_file },
	{ "pack_file_exists", l_pack_file_exists },
	{ NULL, NULL }
};
