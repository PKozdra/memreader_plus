#pragma once

#include "common.h"

extern const luaL_Reg crash_functions[];
extern const luaL_Reg heap_functions[];
extern const luaL_Reg vector_functions[];
extern const luaL_Reg text_functions[];
extern const luaL_Reg pack_functions[];
extern const luaL_Reg map_functions[];
extern const luaL_Reg list_functions[];
extern const RowKind rows_kind;

BOOL game_heap_found(void);
INT_PTR game_heap_alloc(lua_State *L, size_t size);
void game_heap_free(lua_State *L, INT_PTR block, BOOL defer);
const char *map_find(INT_PTR map, const char *key, size_t length, INT_PTR *node);
BOOL map_node_index(INT_PTR node, UINT32 *index);
INT_PTR map_source_of(INT_PTR map, UINT32 index);
const char *map_put(lua_State *L, INT_PTR map, const char *key, size_t length, UINT32 index, INT_PTR source, INT_PTR *node);
const char *map_take(lua_State *L, INT_PTR map, const char *key, size_t length, UINT32 index);
void make_game_string(lua_State *L, CaString *slot, const char *text);
void free_game_string(lua_State *L, INT_PTR slot);
int push_game_file(lua_State *L, int index, INT_PTR open);
const char *pack_path_problem(const char *path, size_t length);
void describe_session(void);
const char *session_text(size_t *length);
void write_redacted(HANDLE file, const char *data, size_t length);
const char *game_crash_folder(void);
void watch_crashes(lua_State *L);
