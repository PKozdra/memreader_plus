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

enum { SAVED_BYTES = 16, DEBUG_RECORD_SIZE = 0x400, MAX_HOOKS = 1000, JUMP_BACK_SIZE = 14 };

enum HookKind { KIND_FUNCTION, KIND_SITE, KIND_CAVE };

enum { OWNER_SIZE = 64, ITEM_NAME_SIZE = 48, TAG_SIZE = OWNER_SIZE + ITEM_NAME_SIZE, CALLER_SIZE = 160, MAX_PATCH_SIZE = 4096, MAX_FRAME_GROWTH = 0x100000 };
enum { INSTRUCTION_TEXT = 256, HOOK_CODE_TEXT = TAG_SIZE * 4 + 96 + INSTRUCTION_TEXT };

enum OwnerText { OWNER_NONE, OWNER_NAMED, OWNER_CALLER };

enum ItemKind { ITEM_SITE, ITEM_VALUE, ITEM_CAVE, ITEM_PATCH, ITEM_FRAME, ITEM_RELOCATE, ITEM_ROW, ROW_KIND_COUNT, ITEM_PREFIX = ROW_KIND_COUNT, ITEM_POSTFIX, ITEM_AROUND, ITEM_KIND_COUNT };

enum { LINK_ERROR_SIZE = 256 };

enum { SET_MEMBERS = 262144, MAX_WHEN_READS = 4, MAX_WHEN_OFFSET = 0xFFFFFF };

enum FrameResult { FRAME_OK, FRAME_BAD_AMOUNT, FRAME_OUTSIDE, FRAME_NO_FUNCTION, FRAME_REFUSED };

enum FreezeResult { FREEZE_OK, FREEZE_BUSY, FREEZE_FAILED, FREEZE_UNCHECKED };

enum { MAX_FRAME_SITES = 128, MAX_FUNCTION_PARTS = 32, MAX_WHOLE_RANGES = 256 };

typedef struct {
	INT_PTR at;
	size_t size;
	BOOL whole;
} Range;

typedef struct {
	BYTE used;
	BYTE kind;
	BYTE listed;
	BYTE owner;
	int priority;
	int attached;
	INT_PTR at;
	UINT32 calls;
	UINT32 skips;
	UINT32 filtered;
	UINT32 errors;
	BYTE unlogged;
	char name[ITEM_NAME_SIZE];
	char error[LINK_ERROR_SIZE];
} Item;

typedef struct {
	INT_PTR from;
	int size;
	int item;
	int hold;
} Claim;

enum { MAX_CHUNKS = 32, MAX_OWNERS = 256, MAX_ITEMS = 8192, MAX_CLAIMS = 32768 };

typedef struct {
	int used;
	int room;
	int limit;
} Capacity;

typedef struct {
	size_t element_size;
	int per_chunk;
	int max_chunks;
	BYTE *chunks[MAX_CHUNKS];
	volatile LONG made;
} Chunks;

typedef struct {
	BOOL all;
	int count;
	unsigned mask;
	int shift;
	UINT64 *slots;
} PointerSet;

typedef struct {
	int argument;
	int read_count;
	INT32 reads[MAX_WHEN_READS];
	const PointerSet *set;
	BOOL broken;
	int fault_read;
	UINT64 fault_at;
} LinkFilter;

typedef struct {
	int (*add)(lua_State *L, int owner, const char *name);
	const char *(*undo)(lua_State *L, int item);
	const char *(*state)(int item);
	void (*describe)(lua_State *L, int item);
} RowKind;

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

typedef struct {
	UINT64 low;
	UINT64 high;
} FloatRegister;

enum { SITE_FLOATS = 6, SITE_VECTORS = 16, SITE_REGISTERS = 16 };

typedef struct {
	FloatRegister floats[SITE_FLOATS];
	FloatRegister upper[SITE_VECTORS];
	UINT64 upper_used;
	UINT64 spare;
	UINT64 registers[SITE_REGISTERS];
	UINT64 flags;
	UINT64 return_address;
} SiteFrame;

_Static_assert(offsetof(SiteFrame, upper) == 96 && offsetof(SiteFrame, upper_used) == 352 &&
	offsetof(SiteFrame, registers) == 368 && offsetof(SiteFrame, flags) == 496 &&
	offsetof(SiteFrame, return_address) == 504 && sizeof(SiteFrame) == 512, "SiteFrame layout is shared with thunk.asm");

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
	const char *handler_note;
	const ULONG_PTR *allocator;
	int allocator_count;
	DWORD exit_code;
	const char *exit_call;
} CrashInput;

typedef struct {
	int result;
	int arguments[MAX_ARGUMENTS];
	int count;
} Signature;

enum { CALL_BLOCK_STACK = 16, CALL_BLOCK_SLOTS = REGISTER_ARGUMENTS + CALL_BLOCK_STACK };

typedef struct {
	UINT64 slots[CALL_BLOCK_SLOTS];
	UINT64 floats[REGISTER_ARGUMENTS];
} CallBlock;

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
extern const luaL_Reg farhook_functions[];
extern const luaL_Reg cave_functions[];
extern const luaL_Reg frame_functions[];
extern const luaL_Reg patcher_functions[];
extern const luaL_Reg set_functions[];

PointerSet *to_set(lua_State *L, int index);
BOOL set_has(const PointerSet *set, UINT64 key);
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
BOOL copy_original(INT_PTR address, BYTE *out, size_t size);
int find_code_all(const char *pattern, const BYTE **found, int max);
INT_PTR find_unique(const char *pattern);
INT_PTR call_destination(INT_PTR call);
PRUNTIME_FUNCTION primary_function_entry(PRUNTIME_FUNCTION entry, ULONG64 base);
UINT64 call_unguarded(INT_PTR function, const CallBlock *block, UINT64 *float_result);
BOOL call_block_guarded(INT_PTR function, const CallBlock *block, UINT64 *result, UINT64 *float_result, Fault *fault);
int call_crash_error(lua_State *L, const Fault *fault);
UINT64 call_game(lua_State *L, INT_PTR function, const UINT64 *arguments, int count);
BOOL call_native(INT_PTR function, const UINT64 *arguments, int count, UINT64 *result, Fault *fault);
BOOL write_memory(INT_PTR address, const void *source, size_t size);
void *resize_block(void *block, size_t size);
int chunk_room(const Chunks *chunks);
void *chunk_slot(const Chunks *chunks, int index);
BOOL reserve_chunks(Chunks *chunks, int needed);
BOOL zero_memory(INT_PTR address, size_t size);
const IMAGE_NT_HEADERS *game_headers(void);
BOOL in_game_image(INT_PTR address, size_t size);
BOOL patch_memory(INT_PTR address, const char *bytes, size_t size);
BOOL store_memory(INT_PTR address, const void *bytes, size_t size);
BOOL is_writable(INT_PTR address, size_t size);
DWORD writable_protection(DWORD protection);
BOOL in_exe_code(INT_PTR address);
BOOL is_executable(INT_PTR address);
BOOL in_own_module(INT_PTR address);
BOOL in_hooked_prologue(INT_PTR address, size_t size);
int find_pattern_count(const char *text, INT_PTR *first);
int original_matches(INT_PTR address, const char *text);
void note_line(const char *line);
void note_refusal(lua_State *L, const char *what, INT_PTR address);
void check_write(lua_State *L, int argument, const char *what, INT_PTR address, size_t size);
int string_view_result(INT_PTR address, size_t char_size);
BOOL read_ca_text(INT_PTR address, BOOL wide, char *out, size_t size);
void add_text(Text *text, const char *format, ...);
INT_PTR pointer_argument(lua_State *L, int index);
UINT64 argument_bits(lua_State *L, int index, int type);
BOOL is_float_type(int type);
void push_bits(lua_State *L, int type, UINT64 bits);
void prepare_hooks(void);
enum { FAR_HOOK_NO_FREEZE = 100 };
typedef void (*FinishHook)(void *context, void *original);
int install_far_hook(INT_PTR target, void *detour, void **original, FinishHook finish, void *context);
void write_jump_back(BYTE *at, void *destination);
BOOL hook_native(INT_PTR target, void *detour, const char *name, void **next);
void install_code_hook(lua_State *L, INT_PTR target, void *detour, size_t code, size_t total, FinishHook finish, void *context);
int copied_length(INT_PTR target);
void *cave_start(INT_PTR target);
int l_hook_site(lua_State *L);
int l_unhook(lua_State *L);
enum CaveResult { CAVE_OK, CAVE_NO_MEMORY, CAVE_REFUSED };
int try_cave(lua_State *L, INT_PTR address, const char *bytes, size_t size, BYTE **start);
typedef struct {
	UINT16 offset;
	UINT16 size;
	BYTE data;
	int line;
} CaveLine;
typedef struct {
	size_t code;
	size_t total;
	char *listing;
	CaveLine *lines;
} AssembledCave;
typedef const char *(*CaveAssembler)(lua_State *L, int spec, INT_PTR site, INT_PTR address, BYTE *out, size_t room, AssembledCave *result);
void register_cave_assembler(CaveAssembler assembler);
typedef BOOL (*InstructionFormatter)(const BYTE *code, size_t size, ULONG_PTR address, char *out, size_t room);
void register_instruction_formatter(InstructionFormatter formatter);
int try_asm_cave(lua_State *L, INT_PTR site, int spec, const char *tag, BYTE **start);
int prepare_asm_cave(lua_State *L, INT_PTR site, int spec);
const char *compare_asm_cave(lua_State *L, INT_PTR site, int spec);
void release_prepared_caves(void);
void set_cave_listing(INT_PTR target, char *listing, CaveLine *lines);
const char *cave_listing(INT_PTR target);
size_t cave_length(INT_PTR target);
BOOL log_line(lua_State *L, const char *text);
void reserve_near_caves(void);
void log_cave_reservation(lua_State *L);
Capacity cave_capacity(void);
int callback_generation(void);
void mark_callback(INT_PTR target, int item);
int l_function_hook(lua_State *L);
const char *attach_link(lua_State *L, INT_PTR at, const Signature *signature, int kind, int priority, int item, int function_index,
	const LinkFilter *when, int set_index);
BOOL link_is_current(lua_State *L, const Signature *signature, int item, int priority, int function_index, const LinkFilter *when);
void remove_link(int item);
void push_filter_fields(lua_State *L, int item);
void flush_link_log(lua_State *L);
int l_flush_log(lua_State *L);
int l_set_log(lua_State *L);
int l_patch_info(lua_State *L);
int check_frame(INT_PTR address, int by, INT_PTR *function, const char **why);
int grown_amount(INT_PTR function);
int grow_frame_by(lua_State *L, INT_PTR address, int by, const char *tag, int item, const void *entry, const char **why);
int function_extents(INT_PTR address, Range *parts, int max);
int check_growth(INT_PTR address, int by, Range *sites, int *count, const char **why);
BOOL check_cave(lua_State *L, INT_PTR target);
typedef void (*ThreadVisit)(HANDLE thread, void *context);
typedef struct {
	const Range *ranges;
	int count;
	ThreadVisit visit;
	void *context;
	const void *entry;
} FreezeJob;
int freeze_threads(const FreezeJob *job, int *busy);
void thaw_threads(void);
const char *freeze_text(int result);
UINT64 freeze_microseconds(void);
BOOL prepare_site_stubs(void);
void *site_stub(int index);
void finish_site(void *context, void *original);
int site_index(const SiteFrame *frame);
int site_stub_at(ULONG_PTR address);
void check_site_target(lua_State *L, INT_PTR target);
void push_registers(lua_State *L);
SiteFrame *swap_active_site(SiteFrame *frame);
void site_entry(void);
extern BYTE site_avx;
void caller_position(lua_State *L, char *where, size_t size);
void note_change(lua_State *L, const char *what, INT_PTR address, size_t size);
void note_owned_change(lua_State *L, const char *what, INT_PTR address, size_t size, const char *tag);
void add_changes(Text *report);
BOOL describe_hook_code(ULONG_PTR address, char *out, size_t size);
void add_hooks(Text *report, lua_State *live);
void add_running_links(Text *report);
int find_owner(const char *name);
int add_owner(const char *name);
const char *owner_name(int owner);
int find_item(int owner, const char *name);
int add_item(int owner, const char *name, int kind, INT_PTR at);
Item *item_at(int index);
int item_total(void);
void remove_item(int index);
void make_tag(char *out, size_t size, int owner, const char *name);
BOOL claim_room(int claims, size_t bytes);
void registry_capacity(Capacity *owners, Capacity *items, Capacity *claims, Capacity *held);
void scan_capacity(Capacity *saved, Capacity *cache);
Capacity hook_capacity(void);
int hop_slots_left(void);
void push_capacity(lua_State *L, const char *name, Capacity use);
void push_core_capacity(lua_State *L);
void add_capacity(Text *report);
BOOL registry_room(int claims, size_t bytes);
BOOL item_room(int needed);
BOOL add_claim(int item, INT_PTR from, size_t size, const BYTE *held, const BYTE *wrote);
BOOL claim_holder(INT_PTR from, size_t size, int except, char *holder, size_t holder_size);
BOOL frame_holder(INT_PTR function, int except, char *holder, size_t holder_size);
Claim *claim_at(int index);
int claim_total(void);
int first_claim(int item);
int count_claims(int item);
BYTE *held_bytes(const Claim *claim);
BYTE *wrote_bytes(const Claim *claim);
const char *item_state(int index);
extern const char different_change[];
void register_row_kind(const RowKind *kind);
const RowKind *row_handler_get(void);
BOOL is_link_kind(int kind);
const char *item_kind_name(int kind);
int shown_kind(const Item *item);
void note_anonymous_cave(lua_State *L, INT_PTR address);
int describe_owner(INT_PTR address, char *out, size_t size);
void add_owners(Text *report);
void prepare_native_report(void);
void load_modules(void);
void set_crash_stack(ULONG_PTR rsp);
void add_address(Text *text, ULONG_PTR address);
void add_fault(Text *text, const EXCEPTION_RECORD *record);
void add_native_stack(Text *text, const CONTEXT *start);
void add_registers(Text *text, const CONTEXT *context);
void add_code_bytes(Text *text, ULONG_PTR rip);
void add_memory_use(Text *text);
const char *other_program_at(ULONG_PTR address);
const char *register_name(int index);
BOOL is_printable(BYTE value);
int wide_text_length(const BYTE *bytes, int units);
BOOL is_bad_pointer(ULONG_PTR value);
BOOL is_heap_pointer(ULONG_PTR value);
BOOL stack_enters(const CONTEXT *start, const ULONG_PTR *functions, int count, int depth);
void prepare_clues(void);
void add_timing_hooks(Text *text);
void add_damaged_memory(Text *text, const CONTEXT *context, const EXCEPTION_RECORD *record);
void set_crash_context(const char *name, const char *value);
void note_crash_event(const char *name);
void set_crash_settings(const char *text, size_t length);
size_t build_crash_report(Text *report, const CrashInput *input);
size_t build_exit_report(Text *report, const CrashInput *input);
size_t build_runtime_report(Text *report, const CrashInput *input);
BOOL in_guarded_call(void);
LONG pause_guarded_calls(void);
void resume_guarded_calls(LONG paused);
