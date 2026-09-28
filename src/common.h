#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "lua.h"
#include "lauxlib.h"
#include "config.h"

enum ValueType {
	VALUE_POINTER,
	VALUE_UINT8,
	VALUE_INT8,
	VALUE_UINT16,
	VALUE_INT16,
	VALUE_UINT32,
	VALUE_INT32,
	VALUE_TYPE_COUNT
};

typedef struct {
	BYTE type;
	union {
		INT_PTR pointer;
		UINT8 uint8;
		INT8 int8;
		UINT16 uint16;
		INT16 int16;
		UINT32 uint32;
		INT32 int32;
	};
} TypedValue;

extern const luaL_Reg value_functions[];
extern const luaL_Reg memory_functions[];
extern const luaL_Reg process_functions[];
extern const luaL_Reg scan_functions[];

TypedValue *push_value(lua_State *L, int type, INT64 number);
TypedValue *to_value(lua_State *L, int index);
INT64 value_to_integer(const TypedValue *value);
size_t value_size(int type);

BOOL to_integer(lua_State *L, int index, size_t string_width, INT64 *result);
INT64 to_offset(lua_State *L, int index);
INT_PTR check_pointer(lua_State *L, int index);
