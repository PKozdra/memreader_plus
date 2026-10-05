#include <string.h>

#include "common.h"
#include "hde/hde64.h"

enum {
	UNWIND_VERSION = 1,
	UNWIND_HANDLERS = 3,
	UNWIND_CHAIN = 4,
	OP_PUSH_NONVOL = 0,
	OP_ALLOC_LARGE = 1,
	OP_SAVE_NONVOL = 4,
	OP_SAVE_NONVOL_FAR = 5,
	OP_SAVE_XMM128 = 8,
	OP_SAVE_XMM128_FAR = 9,
	REG_RAX = 0,
	REG_RSP = 4,
	REG_RBP = 5,
	MOD_REGISTER = 3,
	OPCODE_GROUP1 = 0x81,
	OPCODE_LEA = 0x8D,
	GROUP1_ADD = 0,
	GROUP1_SUB = 5,
	MAX_SITES = 128,
	MAX_PARTS = 32,
	MAX_GROWN = 64,
	MAX_UNWIND = 4 + 2 * 256
};

typedef struct {
	INT_PTR address;
	int size;
	INT64 value;
	INT64 old;
} Site;

typedef struct {
	const BYTE *base;
	PRUNTIME_FUNCTION table;
	DWORD count;
	DWORD table_end;
} FunctionTable;

typedef struct {
	PRUNTIME_FUNCTION entry;
	BYTE *info;
	int pushes;
	DWORD frame;
	Site sites[MAX_SITES];
	int count;
	PRUNTIME_FUNCTION parts[MAX_PARTS];
	int part_count;
	const char *error;
} Plan;

static DWORD grown[MAX_GROWN];
static int grown_count;
static DWORD copy_next;

static FunctionTable function_table(void)
{
	const BYTE *base = (const BYTE *)GetModuleHandleA(NULL);
	const IMAGE_DATA_DIRECTORY *directory = &game_headers()->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
	FunctionTable table = { base, (PRUNTIME_FUNCTION)(base + directory->VirtualAddress), directory->Size / sizeof(RUNTIME_FUNCTION),
		directory->VirtualAddress + directory->Size };

	return table;
}

static BOOL was_grown(DWORD begin)
{
	int i;

	for (i = 0; i < grown_count; i++)
		if (grown[i] == begin)
			return TRUE;
	return FALSE;
}

static BOOL add_site(Plan *plan, INT_PTR address, int size, INT64 value)
{
	if (plan->count == MAX_SITES) {
		plan->error = "more sites than grow_frame can hold";
		return FALSE;
	}
	plan->sites[plan->count].address = address;
	plan->sites[plan->count].size = size;
	plan->sites[plan->count].value = value;
	plan->sites[plan->count].old = 0;
	if (!copy_memory(&plan->sites[plan->count].old, address, (size_t)size)) {
		plan->error = "a site cannot be read";
		return FALSE;
	}
	plan->count++;
	return TRUE;
}

static int code_slots(int op, int op_info)
{
	switch (op) {
	case OP_PUSH_NONVOL:
		return 1;
	case OP_ALLOC_LARGE:
		return op_info ? 3 : 2;
	case OP_SAVE_NONVOL:
	case OP_SAVE_XMM128:
		return 2;
	case OP_SAVE_NONVOL_FAR:
	case OP_SAVE_XMM128_FAR:
		return 3;
	}
	return 0;
}

static BOOL read_allocation(Plan *plan, int by)
{
	int count = plan->info[2], i, slots;
	BOOL found = FALSE;

	for (i = 0; i < count; i += slots) {
		BYTE *code = plan->info + 4 + 2 * i;
		int op = code[1] & 15, op_info = code[1] >> 4;
		BYTE *operand = code + 2;

		slots = code_slots(op, op_info);
		if (!slots) {
			plan->error = "unwind info uses an operation grow_frame does not handle";
			return FALSE;
		}
		if (op == OP_PUSH_NONVOL)
			plan->pushes++;
		if (op != OP_ALLOC_LARGE)
			continue;
		if (found) {
			plan->error = "more than one stack allocation";
			return FALSE;
		}
		found = TRUE;
		plan->frame = op_info ? *(UINT32 *)operand : *(UINT16 *)operand * 8u;
		if (!(op_info ? add_site(plan, (INT_PTR)operand, 4, plan->frame + by) : add_site(plan, (INT_PTR)operand, 2, (plan->frame + by) / 8)))
			return FALSE;
	}
	if (!found)
		plan->error = "the function has no large stack allocation";
	return found;
}

static BOOL move_save(Plan *plan, int op, BYTE *operand, int by)
{
	DWORD scale = op == OP_SAVE_NONVOL ? 8 : op == OP_SAVE_XMM128 ? 16 : 1;
	DWORD offset = scale == 1 ? *(UINT32 *)operand : *(UINT16 *)operand * scale;

	if (offset < plan->frame)
		return TRUE;
	return add_site(plan, (INT_PTR)operand, scale == 1 ? 4 : 2, ((INT64)offset + by) / scale);
}

static BOOL read_saves(Plan *plan, int by)
{
	int count = plan->info[2], i, slots;

	for (i = 0; i < count; i += slots) {
		BYTE *code = plan->info + 4 + 2 * i;
		int op = code[1] & 15;

		slots = code_slots(op, code[1] >> 4);
		if (op != OP_PUSH_NONVOL && op != OP_ALLOC_LARGE && !move_save(plan, op, code + 2, by))
			return FALSE;
	}
	return TRUE;
}

static BOOL read_unwind(Plan *plan, const FunctionTable *table, int by)
{
	BYTE *info = (BYTE *)table->base + plan->entry->UnwindData;

	if ((info[0] & 7) != UNWIND_VERSION || (info[0] >> 3) & UNWIND_CHAIN || info[3] & 15) {
		plan->error = "unwind info has a frame register, a chain or an unknown version";
		return FALSE;
	}
	plan->info = info;
	return read_allocation(plan, by) && read_saves(plan, by);
}

static void find_parts(Plan *plan, const FunctionTable *table)
{
	DWORD i;

	plan->parts[plan->part_count++] = plan->entry;
	for (i = 0; i < table->count && plan->part_count < MAX_PARTS; i++) {
		PRUNTIME_FUNCTION part = &table->table[i];

		if (part != plan->entry && primary_function_entry(part, (ULONG64)table->base) == plan->entry)
			plan->parts[plan->part_count++] = part;
	}
}

static int base_register(const hde64s *hs)
{
	if (!(hs->flags & F_MODRM) || hs->modrm_mod == MOD_REGISTER)
		return -1;
	if (hs->modrm_rm == REG_RSP)
		return (hs->flags & F_SIB) && !(hs->modrm_mod == 0 && hs->sib_base == REG_RBP) ? hs->sib_base | hs->rex_b << 3 : -1;
	if (hs->modrm_mod == 0 && hs->modrm_rm == REG_RBP)
		return -1;
	return hs->modrm_rm | hs->rex_b << 3;
}

static int immediate_size(const hde64s *hs)
{
	if (hs->flags & F_IMM64)
		return 8;
	if (hs->flags & F_IMM32)
		return 4;
	if (hs->flags & F_IMM16)
		return 2;
	return hs->flags & F_IMM8 ? 1 : 0;
}

static INT_PTR displacement_at(INT_PTR at, const hde64s *hs)
{
	return at + hs->len - immediate_size(hs) - 4;
}

static BOOL is_rsp_group1(const hde64s *hs, int operation, DWORD value)
{
	return hs->opcode == OPCODE_GROUP1 && hs->rex_w && hs->modrm_mod == MOD_REGISTER && hs->modrm_reg == operation &&
		hs->modrm_rm == REG_RSP && !hs->rex_b && hs->imm.imm32 == value;
}

static BOOL grow_operand(Plan *plan, INT_PTR at, const hde64s *hs, INT64 disp, int by)
{
	if (!(hs->flags & F_DISP32)) {
		plan->error = "an 8-bit stack offset would need a longer instruction";
		return FALSE;
	}
	return add_site(plan, displacement_at(at, hs), 4, disp + by);
}

static INT64 displacement(const hde64s *hs)
{
	if (hs->flags & F_DISP32)
		return (INT32)hs->disp.disp32;
	return hs->flags & F_DISP8 ? (INT8)hs->disp.disp8 : 0;
}

static BOOL plan_code(Plan *plan, const FunctionTable *table, int by)
{
	const BYTE *start = table->base + plan->entry->BeginAddress;
	const BYTE *prolog_end = start + plan->info[1];
	BOOL starts_rax = start[0] == 0x48 && start[1] == 0x8B && start[2] == 0xC4;
	BOOL allocated = FALSE, has_frame_pointer = FALSE;
	INT64 frame_top = 0;
	int p;

	for (p = 0; p < plan->part_count; p++) {
		const BYTE *at = table->base + plan->parts[p]->BeginAddress;
		const BYTE *end = table->base + plan->parts[p]->EndAddress;

		while (at < end) {
			hde64s hs;
			BOOL in_prolog = at < prolog_end && p == 0;
			int base;

			hde64_disasm(at, &hs);
			if (hs.flags & F_ERROR) {
				plan->error = "an instruction the length decoder cannot read";
				return FALSE;
			}
			base = base_register(&hs);
			if (!allocated && in_prolog && hs.opcode == OPCODE_LEA && hs.rex_w && hs.modrm_reg == REG_RBP && !hs.rex_r &&
				(base == REG_RSP || (base == REG_RAX && starts_rax))) {
				INT64 disp = displacement(&hs);
				INT64 from_entry = base == REG_RAX ? disp : disp - 8 * plan->pushes;

				if (!grow_operand(plan, (INT_PTR)at, &hs, disp, -by))
					return FALSE;
				frame_top = from_entry + 8 * plan->pushes + plan->frame;
				has_frame_pointer = TRUE;
			} else if (!allocated && in_prolog && is_rsp_group1(&hs, GROUP1_SUB, plan->frame)) {
				if (!add_site(plan, (INT_PTR)at + hs.len - 4, 4, plan->frame + by))
					return FALSE;
				allocated = TRUE;
			} else if (allocated && in_prolog && !has_frame_pointer && hs.opcode == OPCODE_LEA && hs.rex_w && hs.modrm_reg == REG_RBP &&
				!hs.rex_r && base == REG_RSP) {
				frame_top = displacement(&hs);
				has_frame_pointer = TRUE;
			} else if (allocated && is_rsp_group1(&hs, GROUP1_ADD, plan->frame)) {
				if (!add_site(plan, (INT_PTR)at + hs.len - 4, 4, plan->frame + by))
					return FALSE;
			} else if (allocated && base == REG_RSP && displacement(&hs) >= (INT64)plan->frame) {
				if (!grow_operand(plan, (INT_PTR)at, &hs, displacement(&hs), by))
					return FALSE;
			} else if (allocated && has_frame_pointer && base == REG_RBP && frame_top + displacement(&hs) >= (INT64)plan->frame) {
				if (!grow_operand(plan, (INT_PTR)at, &hs, displacement(&hs), by))
					return FALSE;
			}
			at += hs.len;
		}
	}
	if (!allocated)
		plan->error = "no sub rsp with the frame size in the prologue";
	return allocated;
}

static BOOL shares_unwind(const Plan *plan, const FunctionTable *table)
{
	DWORD i;

	for (i = 0; i < table->count; i++)
		if (&table->table[i] != plan->entry && table->table[i].UnwindData == plan->entry->UnwindData)
			return TRUE;
	return FALSE;
}

static BOOL fits(const Site *site)
{
	if (site->size == 2)
		return site->value >= 0 && site->value <= 0xFFFF;
	return site->value >= MININT32 && site->value <= MAXUINT32;
}

static BYTE *private_copy(Plan *plan, const FunctionTable *table, size_t length)
{
	BYTE *slot;
	size_t i;
	DWORD page_end;

	if ((plan->info[0] >> 3) & UNWIND_HANDLERS || plan->part_count > 1) {
		plan->error = "shared unwind info with an exception handler or chained parts cannot be copied";
		return NULL;
	}
	if (!copy_next)
		copy_next = (table->table_end + 3) & ~3u;
	page_end = (table->table_end + 0xFFF) & ~0xFFFu;
	if (copy_next + length > page_end) {
		plan->error = "no room left after the function table for a private unwind copy";
		return NULL;
	}
	slot = (BYTE *)table->base + copy_next;
	for (i = 0; i < length; i++)
		if (slot[i]) {
			plan->error = "the space after the function table is not empty";
			return NULL;
		}
	return slot;
}

static BOOL in_unwind(const Plan *plan, const Site *site, size_t length)
{
	return site->address >= (INT_PTR)plan->info && site->address < (INT_PTR)plan->info + (INT_PTR)length;
}

static void restore_code(const Plan *plan, int written, size_t length)
{
	int i;

	for (i = 0; i < written; i++)
		if (!in_unwind(plan, &plan->sites[i], length))
			patch_memory(plan->sites[i].address, (const char *)&plan->sites[i].old, (size_t)plan->sites[i].size);
}

static BOOL apply(Plan *plan, const FunctionTable *table, BOOL copy)
{
	size_t length = 4 + 2 * (((size_t)plan->info[2] + 1) & ~(size_t)1);
	BYTE unwind[MAX_UNWIND];
	BYTE *target = plan->info;
	int i;

	memcpy(unwind, plan->info, length);
	if (copy && !(target = private_copy(plan, table, length)))
		return FALSE;
	for (i = 0; i < plan->count; i++) {
		const Site *site = &plan->sites[i];

		if (!fits(site)) {
			plan->error = "a grown offset does not fit its field";
			return FALSE;
		}
		if (in_unwind(plan, site, length))
			memcpy(unwind + (site->address - (INT_PTR)plan->info), &site->value, (size_t)site->size);
	}
	for (i = 0; i < plan->count; i++) {
		const Site *site = &plan->sites[i];

		if (in_unwind(plan, site, length))
			continue;
		remember_original(site->address, (size_t)site->size);
		if (!patch_memory(site->address, (const char *)&site->value, (size_t)site->size)) {
			restore_code(plan, i, length);
			plan->error = "failed to write the code";
			return FALSE;
		}
	}
	if (!patch_memory((INT_PTR)target, (const char *)unwind, length)) {
		restore_code(plan, plan->count, length);
		plan->error = "failed to write the unwind info";
		return FALSE;
	}
	if (copy) {
		DWORD rva = (DWORD)((const BYTE *)target - table->base);

		if (!patch_memory((INT_PTR)&plan->entry->UnwindData, (const char *)&rva, sizeof rva)) {
			restore_code(plan, plan->count, length);
			memset(unwind, 0, length);
			patch_memory((INT_PTR)target, (const char *)unwind, length);
			plan->error = "failed to point the function at its unwind copy";
			return FALSE;
		}
		copy_next += (DWORD)length;
	}
	return TRUE;
}

static int l_grow_frame(lua_State *L)
{
	INT_PTR address = pointer_argument(L, 1);
	int by = (int)luaL_checknumber(L, 2);
	FunctionTable table = function_table();
	ULONG64 image = 0;
	PRUNTIME_FUNCTION part;
	Plan plan = { 0 };

	if (by <= 0 || by % 16 || by > 0x100000)
		return luaL_argerror(L, 2, "must be a positive multiple of 16, at most 1 MiB");
	if (!in_game_image(address, 1))
		return luaL_argerror(L, 1, "address is outside the game's exe");
	part = RtlLookupFunctionEntry((DWORD64)address, &image, NULL);
	if (!part || (const BYTE *)image != table.base)
		return luaL_argerror(L, 1, "not inside a function of the exe's function table");
	plan.entry = primary_function_entry(part, image);
	if (was_grown(plan.entry->BeginAddress)) {
		lua_pushboolean(L, 1);
		return 1;
	}
	if (grown_count == MAX_GROWN) {
		lua_pushnil(L);
		lua_pushfstring(L, "grow_frame grows at most %d functions", MAX_GROWN);
		return 2;
	}
	find_parts(&plan, &table);
	if (read_unwind(&plan, &table, by) && plan_code(&plan, &table, by) && apply(&plan, &table, shares_unwind(&plan, &table))) {
		grown[grown_count++] = plan.entry->BeginAddress;
		note_change(L, "grow_frame", (INT_PTR)image + plan.entry->BeginAddress, 0);
		lua_pushboolean(L, 1);
		return 1;
	}
	lua_pushnil(L);
	lua_pushstring(L, plan.error);
	return 2;
}

const luaL_Reg frame_functions[] = {
	{ "grow_frame", l_grow_frame },
	{ NULL, NULL }
};
