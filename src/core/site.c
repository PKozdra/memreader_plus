#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"
#include "hde/hde64.h"

enum {
	STUB_SIZE = 16,
	CALL_LENGTH = 6,
	JUMP_LENGTH = 6,
	PAGE_BYTES = 4096,
	SITE_JUMP_BYTES = 5,
	WINDOW_BYTES = 32,
	DECODER_PADDING = 16,
	TABLE_CHUNK_WORDS = 4096,
	MAX_LEAF_BYTES = 0x4000
};

enum { VIEW_POINTER, VIEW_WORD, VIEW_DOUBLE, VIEW_FLOAT, VIEW_BITS, VIEW_FLAGS, VIEW_SHIFT = 4, INDEX_MASK = 15 };

enum { RSP_INDEX = 4, WRITABLE_FLAGS = 0xCD5 };

#pragma pack(push, 1)
typedef struct {
	BYTE call[2];
	INT32 call_offset;
	BYTE jump[2];
	INT32 jump_offset;
	BYTE padding[4];
} SiteStub;
#pragma pack(pop)

_Static_assert(sizeof(SiteStub) == STUB_SIZE, "a site stub is 16 bytes");

typedef struct {
	INT_PTR target;
	int length;
	DWORD first;
	DWORD last;
} SiteRange;

typedef struct {
	void *entry;
	void *originals[MAX_HOOKS];
} SiteTable;

static const BYTE CALL_RIP[2] = { 0xFF, 0x15 };
static const BYTE JUMP_RIP[2] = { 0xFF, 0x25 };
static const char registers_key = 0;
static SiteFrame *active_site;

static const char *const wide_names[SITE_REGISTERS] = {
	"rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"
};
static const char *const narrow_names[SITE_REGISTERS] = {
	"eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"
};
static const char *const double_names[SITE_FLOATS] = { "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5" };
static const char *const float_names[SITE_FLOATS] = { "xmm0f", "xmm1f", "xmm2f", "xmm3f", "xmm4f", "xmm5f" };
static const char *const bits_names[SITE_FLOATS] = { "xmm0q", "xmm1q", "xmm2q", "xmm3q", "xmm4q", "xmm5q" };

BYTE site_avx;
static SiteStub *stubs;
static SiteTable *table;

BOOL prepare_site_stubs(void)
{
	size_t code_size = (sizeof(SiteStub) * MAX_HOOKS + PAGE_BYTES - 1) / PAGE_BYTES * PAGE_BYTES;
	BYTE *memory;
	DWORD old;
	int i;

	if (stubs)
		return TRUE;
	memory = VirtualAlloc(NULL, code_size + sizeof(SiteTable), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
	if (!memory)
		return FALSE;
	table = (SiteTable *)(memory + code_size);
	table->entry = (void *)site_entry;
	for (i = 0; i < MAX_HOOKS; i++) {
		SiteStub *stub = (SiteStub *)memory + i;

		memcpy(stub->call, CALL_RIP, sizeof CALL_RIP);
		stub->call_offset = (INT32)((BYTE *)&table->entry - ((BYTE *)stub + CALL_LENGTH));
		memcpy(stub->jump, JUMP_RIP, sizeof JUMP_RIP);
		stub->jump_offset = (INT32)((BYTE *)&table->originals[i] - ((BYTE *)stub + CALL_LENGTH + JUMP_LENGTH));
		memset(stub->padding, 0xCC, sizeof stub->padding);
	}
	VirtualProtect(memory, code_size, PAGE_EXECUTE_READ, &old);
	FlushInstructionCache(GetCurrentProcess(), memory, code_size);
	site_avx = (GetEnabledXStateFeatures() & XSTATE_MASK_AVX) != 0;
	stubs = (SiteStub *)memory;
	return TRUE;
}

void *site_stub(int index)
{
	return &stubs[index];
}

void finish_site(void *context, void *original)
{
	table->originals[(INT_PTR)context] = original;
	MemoryBarrier();
}

int site_stub_at(ULONG_PTR address)
{
	if (!stubs || address < (ULONG_PTR)stubs || address >= (ULONG_PTR)stubs + sizeof(SiteStub) * MAX_HOOKS)
		return -1;
	return (int)((address - (ULONG_PTR)stubs) / STUB_SIZE);
}

int site_index(const SiteFrame *frame)
{
	return (int)(((const BYTE *)frame->return_address - CALL_LENGTH - (const BYTE *)stubs) / STUB_SIZE);
}

static void refuse_site(lua_State *L, INT_PTR target, const char *reason)
{
	note_refusal(L, NULL, target);
	luaL_argerror(L, 1, reason);
}

static BOOL ends_block(const hde64s *hs)
{
	switch (hs->opcode) {
	case 0xC2: case 0xC3: case 0xCA: case 0xCB: case 0xE9: case 0xEB:
		return TRUE;
	case 0xFF:
		return hs->modrm_reg == 4 || hs->modrm_reg == 5;
	}
	return FALSE;
}

static BOOL branch_destination(const hde64s *hs, INT_PTR at, INT_PTR *destination)
{
	INT64 offset;

	if (!(hs->flags & F_RELATIVE))
		return FALSE;
	if (hs->flags & F_IMM8)
		offset = (INT8)hs->imm.imm8;
	else if (hs->flags & F_IMM32)
		offset = (INT32)hs->imm.imm32;
	else
		return FALSE;
	*destination = at + hs->len + offset;
	return TRUE;
}

static BOOL is_call(const hde64s *hs)
{
	return hs->opcode == 0xE8 || (hs->opcode == 0xFF && (hs->modrm_reg == 2 || hs->modrm_reg == 3));
}

static int replaced_length(lua_State *L, INT_PTR target)
{
	BYTE code[WINDOW_BYTES];
	hde64s hs;
	int length = 0;

	if (!copy_memory(code, target, sizeof code))
		refuse_site(L, target, "refused: the memory at the site cannot be read");
	while (length < SITE_JUMP_BYTES) {
		hde64_disasm(code + length, &hs);
		if (hs.flags & F_ERROR)
			refuse_site(L, target, "refused: the instructions at the site cannot be decoded");
		if (ends_block(&hs))
			refuse_site(L, target, "refused: a return or jump sits in the bytes the hook replaces");
		length += hs.len;
		if (is_call(&hs) && length < SITE_JUMP_BYTES)
			refuse_site(L, target, "refused: a call sits in the bytes the hook replaces and does not end them, a thread inside it would return into the patch");
	}
	return length;
}

static BOOL branch_inside(const hde64s *hs, INT_PTR at, const SiteRange *site)
{
	INT_PTR destination;

	return branch_destination(hs, at, &destination) && destination > site->target && destination < site->target + site->length;
}

static BOOL table_in_part(const BYTE *code, INT_PTR start, size_t size, const SiteRange *site)
{
	size_t at = (size_t)((4 - (start & 3)) & 3);
	DWORD word;

	for (; at + sizeof word <= size; at += sizeof word) {
		memcpy(&word, code + at, sizeof word);
		if (word >= site->first && word <= site->last)
			return TRUE;
	}
	return FALSE;
}

static const char *part_problem(INT_PTR start, INT_PTR end, const SiteRange *site)
{
	size_t size = (size_t)(end - start), at = 0;
	BYTE *code = calloc(size + DECODER_PADDING, 1);
	const char *problem = NULL;
	BOOL own = start <= site->target && site->target < end;
	BOOL broken = FALSE;
	hde64s hs;

	if (!code)
		return "refused: there is not enough memory to check the function around the site";
	if (!copy_original(start, code, size)) {
		free(code);
		return "refused: the function around the site cannot be read";
	}
	for (; at < size && !problem; at += hs.len) {
		INT_PTR here = start + (INT_PTR)at;

		hde64_disasm(code + at, &hs);
		if (hs.flags & F_ERROR) {
			broken = here <= site->target;
			break;
		}
		if (here < site->target && here + hs.len > site->target)
			problem = "refused: the address is inside an instruction, not at its start";
		else if (branch_inside(&hs, here, site))
			problem = own ? "refused: a jump in the function lands inside the bytes the hook replaces" :
				"refused: a jump in another part of the function lands inside the bytes the hook replaces";
	}
	if (!problem && own && broken)
		problem = "refused: the function around the site cannot be decoded up to the address";
	else if (!problem && own && site->target + site->length > end)
		problem = "refused: the bytes the hook replaces run past the end of the function";
	if (!problem && table_in_part(code, start, size, site))
		problem = "refused: a jump table in the function points inside the bytes the hook replaces";
	free(code);
	return problem;
}

static const IMAGE_NT_HEADERS *headers_of(const BYTE *base)
{
	return (const IMAGE_NT_HEADERS *)(base + ((const IMAGE_DOS_HEADER *)base)->e_lfanew);
}

static const BYTE *module_base(INT_PTR target)
{
	HMODULE module;

	if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCWSTR)target, &module))
		return NULL;
	return (const BYTE *)module;
}

static const char *other_parts_problem(const BYTE *base, PRUNTIME_FUNCTION own, const SiteRange *site)
{
	const IMAGE_DATA_DIRECTORY *directory = &headers_of(base)->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
	const RUNTIME_FUNCTION *table = (const RUNTIME_FUNCTION *)(base + directory->VirtualAddress);
	DWORD count = directory->Size / sizeof(RUNTIME_FUNCTION), i;
	DWORD primary = primary_function_entry(own, (ULONG64)base)->BeginAddress;
	const char *problem = NULL;

	for (i = 0; i < count && !problem; i++) {
		if (table[i].BeginAddress != own->BeginAddress && primary_function_entry((PRUNTIME_FUNCTION)&table[i], (ULONG64)base)->BeginAddress == primary)
			problem = part_problem((INT_PTR)base + table[i].BeginAddress, (INT_PTR)base + table[i].EndAddress, site);
	}
	return problem;
}

static const IMAGE_SECTION_HEADER *code_section_of(const IMAGE_NT_HEADERS *headers, DWORD rva)
{
	const IMAGE_SECTION_HEADER *section = IMAGE_FIRST_SECTION(headers);
	int i;

	for (i = 0; i < headers->FileHeader.NumberOfSections; i++, section++) {
		if ((section->Characteristics & IMAGE_SCN_MEM_EXECUTE) && rva >= section->VirtualAddress &&
				rva - section->VirtualAddress < section->Misc.VirtualSize)
			return section;
	}
	return NULL;
}

static BOOL is_code_rva(const IMAGE_NT_HEADERS *headers, DWORD rva)
{
	return code_section_of(headers, rva) != NULL;
}

static BOOL has_table_entry(const IMAGE_NT_HEADERS *headers, const DWORD *words, size_t count, const SiteRange *site)
{
	size_t i;

	for (i = 0; i < count; i++) {
		if (words[i] >= site->first && words[i] <= site->last && ((i > 0 && is_code_rva(headers, words[i - 1])) ||
				(i + 1 < count && is_code_rva(headers, words[i + 1]))))
			return TRUE;
	}
	return FALSE;
}

static BOOL words_in_range(const IMAGE_NT_HEADERS *headers, INT_PTR start, size_t size, const SiteRange *site)
{
	DWORD words[TABLE_CHUNK_WORDS];
	size_t chunk;

	while (size >= sizeof(DWORD)) {
		chunk = size < sizeof words ? size : sizeof words;
		chunk -= chunk % sizeof(DWORD);
		if (copy_memory(words, start, chunk) && has_table_entry(headers, words, chunk / sizeof(DWORD), site))
			return TRUE;
		if (size - chunk < sizeof(DWORD))
			break;
		start += (INT_PTR)(chunk - sizeof(DWORD));
		size -= chunk - sizeof(DWORD);
	}
	return FALSE;
}

static BOOL tables_point_inside(const BYTE *base, const SiteRange *site)
{
	const IMAGE_NT_HEADERS *headers = headers_of(base);
	const IMAGE_SECTION_HEADER *section = IMAGE_FIRST_SECTION(headers);
	int i;

	for (i = 0; i < headers->FileHeader.NumberOfSections; i++, section++) {
		DWORD size = section->Misc.VirtualSize ? section->Misc.VirtualSize : section->SizeOfRawData;
		DWORD flags = section->Characteristics;

		if ((flags & IMAGE_SCN_MEM_READ) && !(flags & (IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_WRITE)) &&
				words_in_range(headers, (INT_PTR)base + section->VirtualAddress, size, site))
			return TRUE;
	}
	return FALSE;
}

static BOOL leaf_span(const BYTE *base, DWORD rva, INT_PTR *start, INT_PTR *end)
{
	const IMAGE_NT_HEADERS *headers = headers_of(base);
	const IMAGE_SECTION_HEADER *section = code_section_of(headers, rva);
	const IMAGE_DATA_DIRECTORY *directory = &headers->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
	const RUNTIME_FUNCTION *table = (const RUNTIME_FUNCTION *)(base + directory->VirtualAddress);
	DWORD count = directory->Size / sizeof(RUNTIME_FUNCTION), low, high, first = 0, last;

	if (!section)
		return FALSE;
	low = section->VirtualAddress;
	high = low + section->Misc.VirtualSize;
	for (last = count; first < last;) {
		DWORD middle = first + (last - first) / 2;

		if (table[middle].BeginAddress <= rva)
			first = middle + 1;
		else
			last = middle;
	}
	if (first > 0 && table[first - 1].EndAddress > rva)
		return FALSE;
	if (first > 0 && table[first - 1].EndAddress > low)
		low = table[first - 1].EndAddress;
	if (first < count && table[first].BeginAddress < high)
		high = table[first].BeginAddress;
	if (high <= low || high - low > MAX_LEAF_BYTES)
		return FALSE;
	*start = (INT_PTR)base + low;
	*end = (INT_PTR)base + high;
	return TRUE;
}

static const char *function_problem(const BYTE *base, INT_PTR target, const SiteRange *site)
{
	ULONG64 entry_base = 0;
	PRUNTIME_FUNCTION own = RtlLookupFunctionEntry((DWORD64)target, &entry_base, NULL);
	INT_PTR start, end;
	const char *problem;

	if (own && entry_base == (ULONG64)base) {
		problem = part_problem((INT_PTR)base + own->BeginAddress, (INT_PTR)base + own->EndAddress, site);
		return problem ? problem : other_parts_problem(base, own, site);
	}
	if (!leaf_span(base, (DWORD)(target - (INT_PTR)base), &start, &end))
		return "refused: the code around the site has no unwind entry and cannot be checked";
	return part_problem(start, end, site);
}

static void check_function_around(lua_State *L, INT_PTR target, int length)
{
	const BYTE *base = module_base(target);
	SiteRange site = { target, length, 0, 0 };
	const char *problem;

	if (!base)
		refuse_site(L, target, "refused: the address is not inside a loaded module, so the code around it cannot be checked");
	site.first = (DWORD)(target - (INT_PTR)base) + 1;
	site.last = site.first + length - 2;
	problem = function_problem(base, target, &site);
	if (problem)
		refuse_site(L, target, problem);
	if (tables_point_inside(base, &site))
		refuse_site(L, target, "refused: a jump table in the module points inside the bytes the hook replaces");
}

void check_site_target(lua_State *L, INT_PTR target)
{
	if (in_hooked_prologue(target, 1))
		refuse_site(L, target, "refused: the address lies in bytes another hook replaced");
	check_function_around(L, target, replaced_length(L, target));
}

static UINT64 plain_bits(lua_State *L, int index, BOOL narrow)
{
	lua_Number number = luaL_checknumber(L, index);
	double low = narrow ? -2147483648.0 : -9223372036854775808.0;
	double high = narrow ? 4294967296.0 : 9223372036854775808.0;

	if (!(number >= low && number < high) || number != floor(number)) {
		if (narrow)
			luaL_error(L, "a 32-bit register takes a whole number from -2147483648 to 4294967295, or a typed value such as mr.uint32");
		luaL_error(L, "a 64-bit register takes a whole number from -2^63 to 2^63 - 1, or a typed value such as mr.uint64");
	}
	return (UINT64)(INT64)number;
}

static UINT64 register_bits(lua_State *L, int index, BOOL narrow)
{
	const TypedValue *value = to_value(L, index);
	UINT64 bits;

	if (value)
		return (UINT64)value_to_integer(value);
	if (lua_type(L, index) == LUA_TSTRING && lua_objlen(L, index) == sizeof bits) {
		memcpy(&bits, lua_tostring(L, index), sizeof bits);
		return bits;
	}
	return plain_bits(L, index, narrow);
}

SiteFrame *swap_active_site(SiteFrame *frame)
{
	SiteFrame *outer = active_site;

	active_site = frame;
	return outer;
}

static SiteFrame *active_frame(lua_State *L)
{
	if (!active_site)
		luaL_error(L, "the registers can be used only inside a site callback");
	return active_site;
}

static int register_code(lua_State *L)
{
	int code;

	lua_pushvalue(L, 2);
	lua_rawget(L, lua_upvalueindex(1));
	if (lua_isnil(L, -1))
		return luaL_error(L, "unknown register '%s'", lua_type(L, 2) == LUA_TSTRING ? lua_tostring(L, 2) : "?");
	code = (int)lua_tointeger(L, -1);
	lua_pop(L, 1);
	return code;
}

static int index_register(lua_State *L)
{
	SiteFrame *frame = active_frame(L);
	int code = register_code(L);
	int index = code & INDEX_MASK;
	UINT64 low;
	double number;
	float single;

	switch (code >> VIEW_SHIFT) {
	case VIEW_POINTER:
		push_value(L, VALUE_POINTER, (INT64)frame->registers[index]);
		break;
	case VIEW_WORD:
		push_value(L, VALUE_UINT32, (UINT32)frame->registers[index]);
		break;
	case VIEW_BITS:
		push_value(L, VALUE_UINT64, (INT64)frame->floats[index].low);
		break;
	case VIEW_DOUBLE:
		low = frame->floats[index].low;
		memcpy(&number, &low, sizeof number);
		lua_pushnumber(L, (lua_Number)number);
		break;
	case VIEW_FLOAT:
		memcpy(&single, &frame->floats[index].low, sizeof single);
		lua_pushnumber(L, single);
		break;
	default:
		lua_pushnumber(L, (lua_Number)(UINT32)frame->flags);
		break;
	}
	return 1;
}

static void store_float(FloatRegister *target, lua_State *L)
{
	float single = (float)luaL_checknumber(L, 3);

	memcpy(&target->low, &single, sizeof single);
}

static int newindex_register(lua_State *L)
{
	SiteFrame *frame = active_frame(L);
	int code = register_code(L);
	int index = code & INDEX_MASK;
	double number;

	if ((code >> VIEW_SHIFT) <= VIEW_WORD && index == RSP_INDEX)
		return luaL_error(L, "rsp is read only");
	switch (code >> VIEW_SHIFT) {
	case VIEW_POINTER:
		frame->registers[index] = register_bits(L, 3, FALSE);
		break;
	case VIEW_WORD:
		frame->registers[index] = (UINT32)register_bits(L, 3, TRUE);
		break;
	case VIEW_BITS:
		frame->floats[index].low = register_bits(L, 3, FALSE);
		break;
	case VIEW_DOUBLE:
		number = luaL_checknumber(L, 3);
		memcpy(&frame->floats[index].low, &number, sizeof number);
		break;
	case VIEW_FLOAT:
		store_float(&frame->floats[index], L);
		break;
	default:
		frame->flags = (frame->flags & ~(UINT64)WRITABLE_FLAGS) | (register_bits(L, 3, TRUE) & WRITABLE_FLAGS);
		break;
	}
	return 0;
}

static void name_registers(lua_State *L, const char *const *names, int count, int view)
{
	int i;

	for (i = 0; i < count; i++) {
		lua_pushstring(L, names[i]);
		lua_pushinteger(L, view << VIEW_SHIFT | i);
		lua_rawset(L, -3);
	}
}

static void push_register_names(lua_State *L)
{
	lua_createtable(L, 0, SITE_REGISTERS * 2 + SITE_FLOATS * 3 + 1);
	name_registers(L, wide_names, SITE_REGISTERS, VIEW_POINTER);
	name_registers(L, narrow_names, SITE_REGISTERS, VIEW_WORD);
	name_registers(L, double_names, SITE_FLOATS, VIEW_DOUBLE);
	name_registers(L, float_names, SITE_FLOATS, VIEW_FLOAT);
	name_registers(L, bits_names, SITE_FLOATS, VIEW_BITS);
	lua_pushliteral(L, "rflags");
	lua_pushinteger(L, VIEW_FLAGS << VIEW_SHIFT);
	lua_rawset(L, -3);
}

static void create_registers(lua_State *L)
{
	lua_newuserdata(L, 1);
	lua_createtable(L, 0, 2);
	push_register_names(L);
	lua_pushvalue(L, -1);
	lua_pushcclosure(L, index_register, 1);
	lua_setfield(L, -3, "__index");
	lua_pushcclosure(L, newindex_register, 1);
	lua_setfield(L, -2, "__newindex");
	lua_setmetatable(L, -2);
	lua_pushlightuserdata(L, (void *)&registers_key);
	lua_pushvalue(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
}

void push_registers(lua_State *L)
{
	lua_pushlightuserdata(L, (void *)&registers_key);
	lua_rawget(L, LUA_REGISTRYINDEX);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		create_registers(L);
	}
}
