#include <string.h>

#include "common.h"

enum { MAX_ALLOCATED = 16 * 1024 * 1024, ALLOCATION_ALIGNMENT = 16, MAX_EXACT_INTEGER = 1 << 24 };

static const char *const more_call_type_names[CALL_TYPE_COUNT - VALUE_TYPE_COUNT] = { "boolean", "float", "double", "void" };
static const char allocations_key = 0;
static LONG guarded_calls;

UINT64 call_function(INT_PTR function, const UINT64 *arguments, UINT64 count, UINT64 *float_result);

const char *call_type_name(int type)
{
	return type < VALUE_TYPE_COUNT ? value_type_names[type] : more_call_type_names[type - VALUE_TYPE_COUNT];
}

static BOOL is_space(char c)
{
	return c == ' ' || c == '\t';
}

static BOOL ends_name(char c)
{
	return c == '\0' || c == ',' || c == '(' || c == ')' || is_space(c);
}

static const char *skip_spaces(const char *text)
{
	while (is_space(*text))
		text++;
	return text;
}

static int signature_error(lua_State *L, const char *expected, const char *found)
{
	if (*found)
		return luaL_argerror(L, 2, lua_pushfstring(L, "expected %s, found '%s'", expected, found));
	return luaL_argerror(L, 2, lua_pushfstring(L, "expected %s, found the end", expected));
}

static BOOL is_type_name(const char *start, size_t length, const char *name)
{
	return strlen(name) == length && strncmp(name, start, length) == 0;
}

static int parse_type(lua_State *L, const char **text)
{
	const char *start = skip_spaces(*text);
	const char *end = start;
	int type;

	while (!ends_name(*end))
		end++;
	if (end == start)
		return signature_error(L, "a type", start);
	for (type = 0; type < CALL_TYPE_COUNT; type++) {
		if (is_type_name(start, (size_t)(end - start), call_type_name(type))) {
			*text = skip_spaces(end);
			return type;
		}
	}
	lua_pushlstring(L, start, (size_t)(end - start));
	return luaL_argerror(L, 2, lua_pushfstring(L, "unknown type '%s' in the signature", lua_tostring(L, -1)));
}

static void add_argument(lua_State *L, const char **text, Signature *signature)
{
	int type = parse_type(L, text);

	if (type == CALL_VOID)
		luaL_argerror(L, 2, "'void' is only a result type");
	if (signature->count == MAX_ARGUMENTS)
		luaL_argerror(L, 2, lua_pushfstring(L, "more than %d arguments", MAX_ARGUMENTS));
	signature->arguments[signature->count++] = type;
}

static const char *parse_arguments(lua_State *L, const char *text, Signature *signature)
{
	text = skip_spaces(text);
	if (*text == ')')
		return text;
	for (;;) {
		add_argument(L, &text, signature);
		if (*text == ')')
			return text;
		if (*text != ',')
			signature_error(L, "',' or ')'", text);
		text++;
	}
}

void parse_signature(lua_State *L, const char *text, Signature *signature)
{
	signature->count = 0;
	signature->result = parse_type(L, &text);
	if (*text != '(')
		signature_error(L, "'(' after the result type", text);
	text = parse_arguments(L, text + 1, signature);
	text = skip_spaces(text + 1);
	if (*text)
		signature_error(L, "the end after ')'", text);
}

static INT64 number_argument(lua_State *L, int index, int type)
{
	lua_Number number = lua_tonumber(L, index);
	INT64 integer;

	if (!(number > -MAX_EXACT_INTEGER && number < MAX_EXACT_INTEGER) || number != (lua_Number)(INT64)number)
		luaL_argerror(L, index, lua_pushfstring(L, "a plain number must be a whole number from -%d to %d; pass a typed value or bytes",
			MAX_EXACT_INTEGER - 1, MAX_EXACT_INTEGER - 1));
	integer = (INT64)number;
	if (narrow_integer(type, integer) != integer)
		luaL_argerror(L, index, lua_pushfstring(L, "%d does not fit %s", (int)integer, value_type_names[type]));
	return integer;
}

static INT64 integer_argument(lua_State *L, int index, int type)
{
	INT64 integer;

	if (lua_type(L, index) == LUA_TNUMBER)
		return number_argument(L, index, type);
	if (!to_integer(L, index, value_size(type), &integer))
		luaL_typerror(L, index, value_type_names[type]);
	return narrow_integer(type, integer);
}

INT_PTR pointer_argument(lua_State *L, int index)
{
	TypedValue *value = to_value(L, index);
	INT_PTR pointer;

	if (lua_isnoneornil(L, index))
		return 0;
	if (value && value->type == VALUE_POINTER)
		return value->pointer;
	if (lua_type(L, index) == LUA_TSTRING && lua_objlen(L, index) == sizeof pointer) {
		memcpy(&pointer, lua_tostring(L, index), sizeof pointer);
		return pointer;
	}
	return luaL_argerror(L, index, "pointer expected: a pointer value, 8 bytes or nil; build a C string with alloc and write");
}

UINT64 argument_bits(lua_State *L, int index, int type)
{
	UINT64 bits = 0;
	float single;
	double number;

	switch (type) {
	case VALUE_POINTER:
		return (UINT64)pointer_argument(L, index);
	case CALL_BOOLEAN:
		luaL_checktype(L, index, LUA_TBOOLEAN);
		return (UINT64)lua_toboolean(L, index);
	case CALL_FLOAT:
		single = (float)luaL_checknumber(L, index);
		memcpy(&bits, &single, sizeof single);
		return bits;
	case CALL_DOUBLE:
		number = luaL_checknumber(L, index);
		memcpy(&bits, &number, sizeof number);
		return bits;
	}
	return (UINT64)integer_argument(L, index, type);
}

static void begin_guarded_call(void)
{
	InterlockedIncrement(&guarded_calls);
}

static void end_guarded_call(void)
{
	InterlockedDecrement(&guarded_calls);
}

BOOL in_guarded_call(void)
{
	return guarded_calls > 0;
}

LONG pause_guarded_calls(void)
{
	return InterlockedExchange(&guarded_calls, 0);
}

void resume_guarded_calls(LONG paused)
{
	InterlockedExchange(&guarded_calls, paused);
}

static BOOL is_memory_fault(DWORD code)
{
	return code == EXCEPTION_ACCESS_VIOLATION || code == STATUS_GUARD_PAGE_VIOLATION || code == EXCEPTION_IN_PAGE_ERROR;
}

static int catch_call_fault(const EXCEPTION_RECORD *record, Fault *fault)
{
	if (!in_guarded_call())
		return EXCEPTION_CONTINUE_SEARCH;
	if (catch_fault(record, fault) == EXCEPTION_EXECUTE_HANDLER)
		return EXCEPTION_EXECUTE_HANDLER;
	switch (record->ExceptionCode) {
	case EXCEPTION_BREAKPOINT:
	case EXCEPTION_ILLEGAL_INSTRUCTION:
	case EXCEPTION_PRIV_INSTRUCTION:
	case EXCEPTION_INT_DIVIDE_BY_ZERO:
	case EXCEPTION_INT_OVERFLOW:
	case EXCEPTION_DATATYPE_MISALIGNMENT:
	case EXCEPTION_FLT_DENORMAL_OPERAND:
	case EXCEPTION_FLT_DIVIDE_BY_ZERO:
	case EXCEPTION_FLT_INEXACT_RESULT:
	case EXCEPTION_FLT_INVALID_OPERATION:
	case EXCEPTION_FLT_OVERFLOW:
	case EXCEPTION_FLT_STACK_CHECK:
	case EXCEPTION_FLT_UNDERFLOW:
	case STATUS_FLOAT_MULTIPLE_FAULTS:
	case STATUS_FLOAT_MULTIPLE_TRAPS:
		return EXCEPTION_EXECUTE_HANDLER;
	}
	return EXCEPTION_CONTINUE_SEARCH;
}

static const char *fault_name(DWORD code)
{
	switch (code) {
	case EXCEPTION_ACCESS_VIOLATION:      return "access violation";
	case STATUS_GUARD_PAGE_VIOLATION:     return "guard page";
	case EXCEPTION_IN_PAGE_ERROR:         return "in-page error";
	case EXCEPTION_BREAKPOINT:            return "breakpoint";
	case EXCEPTION_ILLEGAL_INSTRUCTION:   return "illegal instruction";
	case EXCEPTION_PRIV_INSTRUCTION:      return "privileged instruction";
	case EXCEPTION_INT_DIVIDE_BY_ZERO:    return "integer division by zero";
	case EXCEPTION_INT_OVERFLOW:          return "integer overflow";
	case EXCEPTION_DATATYPE_MISALIGNMENT: return "misaligned data";
	default:                              return "floating-point fault";
	}
}

static BOOL guarded_call(INT_PTR function, const UINT64 *arguments, int count, UINT64 *result, UINT64 *float_result,
	Fault *fault)
{
	BOOL done = FALSE;

	begin_guarded_call();
	__try {
		__try {
			*result = call_function(function, arguments, (UINT64)count, float_result);
			done = TRUE;
		} __except (catch_call_fault(GetExceptionInformation()->ExceptionRecord, fault)) {
			if (fault->code == STATUS_GUARD_PAGE_VIOLATION)
				restore_guard(fault->address);
		}
	} __finally {
		end_guarded_call();
	}
	return done;
}

static int call_crash_error(lua_State *L, const Fault *fault)
{
	if (is_memory_fault(fault->code))
		return luaL_error(L, "the called function crashed at %p (%s at %p); the game may be unstable now",
			fault->instruction, fault_name(fault->code), (void *)fault->address);
	return luaL_error(L, "the called function crashed at %p (%s); the game may be unstable now", fault->instruction,
		fault_name(fault->code));
}

BOOL call_native(INT_PTR function, const UINT64 *arguments, int count, UINT64 *result, Fault *fault)
{
	UINT64 float_result = 0;

	return guarded_call(function, arguments, count, result, &float_result, fault);
}

UINT64 call_game(lua_State *L, INT_PTR function, const UINT64 *arguments, int count)
{
	UINT64 result = 0;
	Fault fault = { 0, 0, NULL };

	if (!call_native(function, arguments, count, &result, &fault))
		call_crash_error(L, &fault);
	return result;
}

BOOL is_float_type(int type)
{
	return type == CALL_FLOAT || type == CALL_DOUBLE;
}

void push_bits(lua_State *L, int type, UINT64 bits)
{
	float single;
	double number;

	switch (type) {
	case CALL_BOOLEAN:
		lua_pushboolean(L, (BYTE)bits != 0);
		return;
	case CALL_FLOAT:
		memcpy(&single, &bits, sizeof single);
		lua_pushnumber(L, single);
		return;
	case CALL_DOUBLE:
		memcpy(&number, &bits, sizeof number);
		lua_pushnumber(L, (lua_Number)number);
		return;
	}
	push_value(L, type, (INT64)bits);
}

int call_with_signature(lua_State *L, INT_PTR function, const Signature *signature, int first)
{
	UINT64 arguments[MAX_ARGUMENTS] = { 0 };
	UINT64 result = 0, float_result = 0;
	Fault fault = { 0, 0, NULL };
	int given = lua_gettop(L) - first + 1;
	int i;

	if (given != signature->count)
		return luaL_error(L, "the signature takes %d %s, got %d", signature->count,
			signature->count == 1 ? "argument" : "arguments", given);
	for (i = 0; i < signature->count; i++)
		arguments[i] = argument_bits(L, i + first, signature->arguments[i]);
	if (!function)
		return luaL_argerror(L, 1, "function address is NULL");
	if (!guarded_call(function, arguments, signature->count, &result, &float_result, &fault))
		return call_crash_error(L, &fault);
	if (signature->result == CALL_VOID)
		return 0;
	push_bits(L, signature->result, is_float_type(signature->result) ? float_result : result);
	return 1;
}

static int l_call(lua_State *L)
{
	INT_PTR function = pointer_argument(L, 1);
	Signature signature;

	parse_signature(L, luaL_checkstring(L, 2), &signature);
	if (function && !in_exe_code(function) && !is_hook_original(function)) {
		note_refusal(L, "call", function);
		return luaL_argerror(L, 1, "refused: call takes only code in the game's exe or a hook's original");
	}
	return call_with_signature(L, function, &signature, 3);
}

static void push_allocations(lua_State *L)
{
	lua_pushlightuserdata(L, (void *)&allocations_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (!lua_isnil(L, -1))
		return;
	lua_pop(L, 1);
	lua_newtable(L);
	lua_pushlightuserdata(L, (void *)&allocations_key);
	lua_pushvalue(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
}

static int l_alloc(lua_State *L)
{
	lua_Number requested = luaL_checknumber(L, 1);
	lua_Number in_use;
	size_t size, block_size;
	BYTE *block;
	INT_PTR address;

	if (!(requested >= 1 && requested <= MAX_ALLOCATED))
		return luaL_argerror(L, 1, lua_pushfstring(L, "size must be from 1 to %d bytes", MAX_ALLOCATED));
	size = (size_t)requested;
	push_allocations(L);
	lua_getfield(L, -1, "bytes");
	in_use = lua_tonumber(L, -1);
	lua_pop(L, 1);
	if ((lua_Number)size > MAX_ALLOCATED - in_use)
		return luaL_error(L, "alloc holds at most %d bytes per mode (%d in use); memory returns at the next mode switch, so reuse buffers",
			MAX_ALLOCATED, (int)in_use);
	block_size = size + ALLOCATION_ALIGNMENT - 1;
	block = lua_newuserdata(L, block_size);
	memset(block, 0, block_size);
	lua_pushboolean(L, 1);
	lua_rawset(L, -3);
	lua_pushnumber(L, in_use + (lua_Number)size);
	lua_setfield(L, -2, "bytes");
	address = ((INT_PTR)block + ALLOCATION_ALIGNMENT - 1) & ~(INT_PTR)(ALLOCATION_ALIGNMENT - 1);
	push_value(L, VALUE_POINTER, address);
	return 1;
}

const luaL_Reg call_functions[] = {
	{ "call", l_call },
	{ "alloc", l_alloc },
	{ NULL, NULL }
};
