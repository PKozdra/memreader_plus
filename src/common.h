#pragma once

#define WIN32_LEAN_AND_MEAN
#include <stddef.h>
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

enum { SAVED_BYTES = 16, DEBUG_RECORD_SIZE = 0x400 };

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
	char *data;
	size_t size;
	size_t used;
} Text;

typedef union {
	lua_Debug fields;
	char raw[DEBUG_RECORD_SIZE];
} DebugRecord;

typedef struct {
	const EXCEPTION_POINTERS *info;
	DWORD thread;
	DWORD script_thread;
	const CONTEXT *script;
	lua_State *lua;
	BOOL confirmed;
	const char *script_log;
	FILETIME time;
} CrashInput;

typedef struct {
	int result;
	int arguments[MAX_ARGUMENTS];
	int count;
} Signature;

enum {
	LIST_SIZE = offsetof(CaList, size),
	LIST_END = offsetof(CaList, last),
	LIST_FIRST = offsetof(CaList, first),
	NODE_PREVIOUS = offsetof(CaListNode, previous),
	NODE_NEXT = offsetof(CaListNode, next),
	NODE_VALUE = sizeof(CaListNode)
};

_Static_assert(sizeof(CaString) == 16 && sizeof(CaVector) == 16, "CA::String and CA_STD::VECTOR are 16 bytes");
_Static_assert(offsetof(lua_Debug, short_src) == 0x38, "the game's lua_Debug starts like stock Lua 5.1 on x64");
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
extern const luaL_Reg heap_functions[];
extern const luaL_Reg vector_functions[];
extern const luaL_Reg text_functions[];
extern const luaL_Reg farhook_functions[];
extern const luaL_Reg pack_functions[];
extern const luaL_Reg map_functions[];
extern const luaL_Reg list_functions[];
extern const luaL_Reg frame_functions[];

TypedValue *push_value(lua_State *L, int type, INT64 number);
TypedValue *to_value(lua_State *L, int index);
INT64 value_to_integer(const TypedValue *value);
INT64 narrow_integer(int type, INT64 number);
size_t value_size(int type);

BOOL to_integer(lua_State *L, int index, size_t string_width, INT64 *result);
INT64 to_offset(lua_State *L, int index);
INT64 whole_argument(lua_State *L, int index, INT64 low, INT64 high, const char *name);
INT_PTR check_pointer(lua_State *L, int index);
INT_PTR address_argument(lua_State *L, int index);

int catch_fault(const EXCEPTION_RECORD *record, Fault *fault);
void restore_guard(ULONG_PTR address);
BOOL copy_memory(void *destination, INT_PTR address, size_t size);
int push_integer(lua_State *L, INT_PTR address, int type, BOOL exact);
int push_string(lua_State *L, INT_PTR address, size_t char_size);
int push_unistring(lua_State *L, INT_PTR address);
void push_read_error(lua_State *L, int result);

const char *call_type_name(int type);
void parse_signature(lua_State *L, const char *text, Signature *signature);
int call_with_signature(lua_State *L, INT_PTR function, const Signature *signature, int first);
void capture_code(INT_PTR address, BYTE *window);
void remember_code(INT_PTR address, const BYTE *window);
void remember_original(INT_PTR address, size_t size);
BOOL code_section(int index, BYTE **start, BYTE **end);
int find_code_all(const char *pattern, const BYTE **found, int max);
INT_PTR find_unique(const char *pattern);
INT_PTR call_destination(INT_PTR call);
PRUNTIME_FUNCTION primary_function_entry(PRUNTIME_FUNCTION entry, ULONG64 base);
UINT64 call_game(lua_State *L, INT_PTR function, const UINT64 *arguments, int count);
void make_game_string(lua_State *L, CaString *slot, const char *text);
void free_game_string(lua_State *L, INT_PTR slot);
BOOL call_native(INT_PTR function, const UINT64 *arguments, int count, UINT64 *result, Fault *fault);
BOOL write_memory(INT_PTR address, const void *source, size_t size);
BOOL zero_memory(INT_PTR address, size_t size);
const IMAGE_NT_HEADERS *game_headers(void);
BOOL in_game_image(INT_PTR address, size_t size);
BOOL patch_memory(INT_PTR address, const char *bytes, size_t size);
BOOL may_write(INT_PTR address, size_t size);
BOOL in_exe_code(INT_PTR address);
BOOL is_hook_original(INT_PTR address);
void note_refusal(lua_State *L, const char *what, INT_PTR address);
void check_write(lua_State *L, int argument, const char *what, INT_PTR address, size_t size);
INT_PTR game_heap_alloc(lua_State *L, size_t size);
void game_heap_free(lua_State *L, INT_PTR block, BOOL defer);
int string_view_result(INT_PTR address, size_t char_size);
BOOL read_ca_text(INT_PTR address, BOOL wide, char *out, size_t size);
void add_text(Text *text, const char *format, ...);
void describe_session(void);
const char *session_text(size_t *length);
void write_redacted(HANDLE file, const char *data, size_t length);
const char *game_crash_folder(void);
INT_PTR pointer_argument(lua_State *L, int index);
UINT64 argument_bits(lua_State *L, int index, int type);
BOOL is_float_type(int type);
void push_bits(lua_State *L, int type, UINT64 bits);
void prepare_hooks(void);
int install_far_hook(INT_PTR target, void *detour, void **original);
void watch_crashes(lua_State *L);
void note_change(lua_State *L, const char *what, INT_PTR address, size_t size);
void add_changes(Text *report);
BOOL describe_hook_code(ULONG_PTR address, char *out, size_t size);
void add_hooks(Text *report, lua_State *live);
void prepare_native_report(void);
void load_modules(void);
void set_crash_stack(ULONG_PTR rsp);
void add_address(Text *text, ULONG_PTR address);
void add_fault(Text *text, const EXCEPTION_RECORD *record);
void add_native_stack(Text *text, const CONTEXT *start);
void add_registers(Text *text, const CONTEXT *context);
void add_code_bytes(Text *text, ULONG_PTR rip);
void add_memory_use(Text *text);
void add_other_modules(Text *text);
void set_crash_context(const char *name, const char *value);
void note_crash_event(const char *name);
size_t build_crash_report(Text *report, const CrashInput *input);
void begin_guarded_call(void);
void end_guarded_call(void);
BOOL in_guarded_call(void);
LONG pause_guarded_calls(void);
void resume_guarded_calls(LONG paused);
