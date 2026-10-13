#pragma once

#include "common.h"

enum { MAX_CALLBACKS = 32, MAX_HOOK_CALLBACKS = 16, MAX_ERROR_LENGTH = 255, EXTRA_STACK_SLOTS = 8, SAVED_REGISTERS = 6 };

enum HookOutcome { RUN_ORIGINAL, RETURN_RESULT, RETURN_FLOAT_RESULT };

enum LinkKind { LINK_HOOK, LINK_PREFIX, LINK_POSTFIX, LINK_AROUND };

enum Phase { PHASE_PREFIX, PHASE_AROUND, PHASE_POSTFIX, PHASE_COUNT };

typedef struct {
	lua_State *state;
	int thread;
	int function;
	int item;
	int priority;
	BYTE kind;
	BYTE doomed;
} Callback;

typedef struct {
	int owner;
	int kind;
	char name[ITEM_NAME_SIZE];
} LinkTag;

typedef struct {
	INT_PTR target;
	int kind;
	int copied;
	void *trampoline;
	void *original;
	void *cave;
	size_t cave_size;
	const char *native;
	Signature signature;
	Callback callbacks[MAX_CALLBACKS];
	int callback_count;
	BYTE order[PHASE_COUNT][MAX_CALLBACKS];
	int order_count[PHASE_COUNT];
	int typed;
	BOOL stale;
	int running;
	int current;
	const LinkTag *running_tag;
	UINT32 calls;
	LONG other_thread_calls;
	char error[MAX_ERROR_LENGTH + 1];
} Hook;

typedef struct {
	UINT64 registers[SAVED_REGISTERS];
	FloatRegister floats[SAVED_REGISTERS];
	const UINT64 *stack;
	UINT64 result;
	UINT64 float_result;
	void *original;
} HookFrame;

_Static_assert(offsetof(HookFrame, floats) == 48 && offsetof(HookFrame, stack) == 144 &&
	offsetof(HookFrame, result) == 152 && offsetof(HookFrame, float_result) == 160 &&
	offsetof(HookFrame, original) == 168 && sizeof(HookFrame) == 176, "HookFrame layout is shared with thunk.asm");

typedef struct HookCall {
	Hook *hook;
	HookFrame *frame;
	SiteFrame *registers;
	int level;
	int passed_down;
	struct HookCall *outer;
	struct TypedCall *typed;
} HookCall;

extern int callback_depth;
extern HookCall *innermost;

Hook *find_hook(INT_PTR target);
BOOL holds_function(const Callback *callback);
BOOL is_attached(const Callback *callback);
BOOL same_signature(const Signature *a, const Signature *b);
void detach(Hook *hook, int index);
void refresh_hook(Hook *hook);
void watch_state_close(lua_State *L);
const char *error_message(lua_State *L, size_t *length);
void keep_error(Hook *hook, lua_State *L);
UINT64 argument_slot(const HookFrame *frame, int index, int type);
void set_result(HookFrame *frame, int type, UINT64 bits);

int run_typed(Hook *hook, HookFrame *frame);
int hook_next_typed(lua_State *L, HookCall *call);
void prepare_links(lua_State *L);
void forget_links(void);
void rebuild_links(Hook *hook);
