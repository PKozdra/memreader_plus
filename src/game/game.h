#pragma once

#include "common.h"

extern const luaL_Reg crash_functions[];
extern const luaL_Reg heap_functions[];
extern const luaL_Reg vector_functions[];
extern const luaL_Reg text_functions[];
extern const luaL_Reg pack_functions[];
extern const luaL_Reg map_functions[];
extern const luaL_Reg list_functions[];

INT_PTR game_heap_alloc(lua_State *L, size_t size);
void game_heap_free(lua_State *L, INT_PTR block, BOOL defer);
void make_game_string(lua_State *L, CaString *slot, const char *text);
void free_game_string(lua_State *L, INT_PTR slot);
int push_game_file(lua_State *L, int index, INT_PTR open);
const char *pack_path_problem(const char *path, size_t length);
void describe_session(void);
const char *session_text(size_t *length);
void write_redacted(HANDLE file, const char *data, size_t length);
const char *game_crash_folder(void);
void watch_crashes(lua_State *L);
