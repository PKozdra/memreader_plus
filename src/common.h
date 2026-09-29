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
	VALUE_INT64,
	VALUE_UINT64,
	VALUE_TYPE_COUNT
};

enum CallType { CALL_BOOLEAN = VALUE_TYPE_COUNT, CALL_FLOAT, CALL_DOUBLE, CALL_VOID, CALL_TYPE_COUNT };

enum { MAX_ARGUMENTS = 16, REGISTER_ARGUMENTS = 4 };

enum ReadResult { READ_OK, READ_FAILED, READ_TOO_LARGE, READ_NOT_CA_STRING };

enum { SAVED_BYTES = 16 };

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
		INT64 int64;
		UINT64 uint64;
	};
} TypedValue;

typedef struct {
	DWORD code;
	ULONG_PTR address;
	PVOID instruction;
} Fault;

typedef union {
	struct {
		INT32 length;
		UINT32 capacity;
		INT_PTR data;
	} heap;
	struct {
		char text[15];
		BYTE tag_and_length;
	} in_place;
} CaString;

typedef struct {
	UINT32 capacity;
	INT32 size;
	INT_PTR data;
} CaVector;

typedef struct {
	INT32 size;
	UINT32 padding;
	INT_PTR last;
	INT_PTR first;
} CaList;

typedef struct {
	INT_PTR previous;
	INT_PTR next;
} CaListNode;

typedef struct {
	int result;
	int arguments[MAX_ARGUMENTS];
	int count;
} Signature;

typedef struct {
	INT_PTR start;
	const BYTE *bytes;
} SavedCode;

_Static_assert(sizeof(CaString) == 16 && sizeof(CaVector) == 16, "CA::String and CA_STD::VECTOR are 16 bytes");
_Static_assert(sizeof(CaList) == 0x18 && sizeof(CaListNode) == 0x10, "CA_STD::LIST is 0x18 bytes, a node header 0x10");

extern const char *const value_type_names[VALUE_TYPE_COUNT];

extern const luaL_Reg value_functions[];
extern const luaL_Reg memory_functions[];
extern const luaL_Reg process_functions[];
extern const luaL_Reg scan_functions[];
extern const luaL_Reg layout_functions[];
extern const luaL_Reg call_functions[];
extern const luaL_Reg hook_functions[];
extern const luaL_Reg crash_functions[];

TypedValue *push_value(lua_State *L, int type, INT64 number);
TypedValue *to_value(lua_State *L, int index);
INT64 value_to_integer(const TypedValue *value);
INT64 narrow_integer(int type, INT64 number);
size_t value_size(int type);

BOOL to_integer(lua_State *L, int index, size_t string_width, INT64 *result);
INT64 to_offset(lua_State *L, int index);
INT_PTR check_pointer(lua_State *L, int index);

int catch_fault(const EXCEPTION_RECORD *record, Fault *fault);
void restore_guard(ULONG_PTR address);
BOOL copy_memory(void *destination, INT_PTR address, size_t size);
int push_integer(lua_State *L, INT_PTR address, int type, BOOL exact);
int push_string(lua_State *L, INT_PTR address, size_t char_size);
int push_unistring(lua_State *L, INT_PTR address);
void push_read_error(lua_State *L, int result);
void check_read(lua_State *L, int result);

const char *call_type_name(int type);
void parse_signature(lua_State *L, const char *text, Signature *signature);
int call_with_signature(lua_State *L, INT_PTR function, const Signature *signature, int first);
BOOL saved_code(int index, SavedCode *code);
void save_handler_code(INT_PTR target);
const BYTE *find_code(const char *pattern, int *count);
BOOL read_ca_text(INT_PTR address, BOOL wide, char *out, size_t size);
void describe_session(void);
const char *session_text(size_t *length);
const char *game_crash_folder(void);
INT_PTR pointer_argument(lua_State *L, int index);
UINT64 argument_bits(lua_State *L, int index, int type);
BOOL is_float_type(int type);
void push_bits(lua_State *L, int type, UINT64 bits);
void prepare_hooks(void);
void watch_crashes(lua_State *L);
void begin_guarded_call(void);
void end_guarded_call(void);
BOOL in_guarded_call(void);
LONG pause_guarded_calls(void);
void resume_guarded_calls(LONG paused);
