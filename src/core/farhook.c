#include <string.h>

#include "common.h"
#include "MinHook.h"
#include "buffer.h"
#include "trampoline.h"
#include "hde/hde64.h"

enum { HOP_SIZE = 14, SITE_JUMP = 5, PROLOGUE_SCAN = 32, FAR_BUFFER_SIZE = 64, RIP_MODRM = 0x05, RIP_MODRM_MASK = 0xC7, STACK_GUARD_KEEP = 0x3000 };

#pragma pack(push, 1)
typedef struct {
	BYTE opcode[2];
	UINT32 zero;
	UINT64 address;
} AbsoluteJump;
#pragma pack(pop)

_Static_assert(sizeof(AbsoluteJump) == HOP_SIZE, "an absolute jump is 14 bytes");

static const BYTE JUMP_RIP[2] = { 0xFF, 0x25 };
static const BYTE INT3 = 0xCC;

static BYTE *padding_next;
static BYTE *padding_end;

static BYTE *find_padding_run(BYTE *from, BYTE *section_end)
{
	BYTE *run = from;

	while (run + HOP_SIZE <= section_end) {
		size_t length = 0;

		if (*run != INT3) {
			run++;
			continue;
		}
		while (run + length < section_end && run[length] == INT3)
			length++;
		if (length >= HOP_SIZE)
			return run;
		run += length;
	}
	return NULL;
}

static BYTE *find_hop_slot(void)
{
	if (!padding_next && !code_section(0, &padding_next, &padding_end))
		return NULL;
	return find_padding_run(padding_next, padding_end);
}

static BOOL padding_reaches(INT_PTR target)
{
	INT64 from_start, from_end;

	if (!padding_next && !code_section(0, &padding_next, &padding_end))
		return FALSE;
	from_start = (INT64)((INT_PTR)padding_next - (target + SITE_JUMP));
	from_end = (INT64)((INT_PTR)padding_end - (target + SITE_JUMP));
	return from_start == (INT32)from_start && from_end == (INT32)from_end;
}

static AbsoluteJump absolute_jump(UINT64 destination)
{
	AbsoluteJump jump = { { JUMP_RIP[0], JUMP_RIP[1] }, 0, destination };

	return jump;
}

void write_jump_back(BYTE *at, void *destination)
{
	AbsoluteJump jump = absolute_jump((UINT64)(ULONG_PTR)destination);

	memcpy(at, &jump, sizeof jump);
}

static BOOL prologue_relocatable(BYTE *target)
{
	UINT stolen = 0;

	while (stolen < SITE_JUMP) {
		hde64s hs;

		hde64_disasm(target + stolen, &hs);
		if (hs.flags & F_ERROR)
			return FALSE;
		if ((hs.modrm & RIP_MODRM_MASK) == RIP_MODRM)
			return FALSE;
		stolen += hs.len;
		if (stolen > PROLOGUE_SCAN)
			return FALSE;
	}
	return TRUE;
}

static void leave_prologue(HANDLE thread, INT_PTR target, const TRAMPOLINE *ct)
{
	CONTEXT context = { 0 };
	UINT i;

	context.ContextFlags = CONTEXT_CONTROL;
	if (!GetThreadContext(thread, &context))
		return;
	for (i = 0; i < ct->nIP; i++) {
		if (context.Rip == (DWORD64)target + ct->oldIPs[i]) {
			context.Rip = (DWORD64)(ULONG_PTR)ct->pTrampoline + ct->newIPs[i];
			SetThreadContext(thread, &context);
			return;
		}
	}
}

typedef struct {
	INT_PTR target;
	const TRAMPOLINE *trampoline;
} PrologueMove;

static void move_out_of_prologue(HANDLE thread, void *context)
{
	const PrologueMove *move = context;

	leave_prologue(thread, move->target, move->trampoline);
}

int install_far_hook(INT_PTR target, void *detour, void **original, FinishHook finish, void *context)
{
	TRAMPOLINE ct = { 0 };
	BYTE site_jump[SITE_JUMP] = { 0xE9, 0, 0, 0, 0 };
	BYTE *far_buffer;
	BYTE *hop;
	AbsoluteJump jump;
	INT32 distance;
	PrologueMove move = { target, &ct };
	FreezeJob job = { NULL, 0, move_out_of_prologue, &move };
	int busy;

	if (!prologue_relocatable((BYTE *)target))
		return MH_ERROR_UNSUPPORTED_FUNCTION;
	if (!padding_reaches(target))
		return MH_ERROR_MEMORY_ALLOC;
	far_buffer = VirtualAlloc(NULL, FAR_BUFFER_SIZE, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
	if (!far_buffer)
		return MH_ERROR_MEMORY_ALLOC;
	ct.pTarget = (LPVOID)target;
	ct.pDetour = detour;
	ct.pTrampoline = far_buffer;
	if (!CreateTrampolineFunction(&ct) || ct.patchAbove) {
		VirtualFree(far_buffer, 0, MEM_RELEASE);
		return MH_ERROR_UNSUPPORTED_FUNCTION;
	}
	hop = find_hop_slot();
	if (!hop) {
		VirtualFree(far_buffer, 0, MEM_RELEASE);
		return MH_ERROR_MEMORY_ALLOC;
	}
	remember_original((INT_PTR)hop, HOP_SIZE);
	VirtualProtect(far_buffer, FAR_BUFFER_SIZE, PAGE_EXECUTE_READ, &(DWORD){ 0 });
	FlushInstructionCache(GetCurrentProcess(), far_buffer, FAR_BUFFER_SIZE);
	if (finish)
		finish(context, far_buffer);
	distance = (INT32)((INT_PTR)hop - (target + SITE_JUMP));
	memcpy(site_jump + 1, &distance, sizeof distance);
	if (freeze_threads(&job, &busy) != FREEZE_OK)
		return FAR_HOOK_NO_FREEZE;
	jump = absolute_jump((UINT64)ct.pRelay);
	if (!patch_memory((INT_PTR)hop, (const char *)&jump, sizeof jump)) {
		thaw_threads();
		return MH_ERROR_MEMORY_PROTECT;
	}
	padding_next = hop + HOP_SIZE;
	if (!patch_memory(target, (const char *)site_jump, sizeof site_jump)) {
		thaw_threads();
		return MH_ERROR_MEMORY_PROTECT;
	}
	thaw_threads();
	*original = ct.pTrampoline;
	return MH_OK;
}

static int padding_slots_left(void)
{
	BYTE *start = padding_next;
	BYTE *end = padding_end;
	int count = 0;

	if (!start && !code_section(0, &start, &end))
		return 0;
	while (start + HOP_SIZE <= end) {
		BYTE *run = find_padding_run(start, end);

		if (!run)
			break;
		count++;
		start = run + HOP_SIZE;
	}
	return count;
}

int hop_slots_left(void)
{
	return padding_slots_left();
}

static int l_hop_slots(lua_State *L)
{
	lua_pushnumber(L, (lua_Number)padding_slots_left());
	return 1;
}

static int l_commit_stack(lua_State *L)
{
	ULONG_PTR low = 0, high = 0;
	INT64 keep = (INT64)luaL_optnumber(L, 1, STACK_GUARD_KEEP);
	SYSTEM_INFO system;
	DWORD old;
	BYTE *bottom, *limit;
	NT_TIB *tib = (NT_TIB *)NtCurrentTeb();

	GetCurrentThreadStackLimits(&low, &high);
	GetSystemInfo(&system);
	if (keep < system.dwPageSize || !low || (INT64)(high - low) <= keep + system.dwPageSize)
		return luaL_error(L, "the thread stack is too small to commit");
	bottom = (BYTE *)low + keep;
	limit = bottom + system.dwPageSize;
	if ((BYTE *)&old < limit)
		return luaL_error(L, "the stack is already used below the part commit_stack keeps");
	if ((BYTE *)tib->StackLimit <= limit) {
		lua_pushboolean(L, 1);
		return 1;
	}
	if (!VirtualAlloc(bottom, high - (ULONG_PTR)bottom, MEM_COMMIT, PAGE_READWRITE) ||
		!VirtualProtect(bottom, system.dwPageSize, PAGE_READWRITE | PAGE_GUARD, &old)) {
		lua_pushboolean(L, 0);
		return 1;
	}
	tib->StackLimit = limit;
	lua_pushboolean(L, 1);
	return 1;
}

const luaL_Reg farhook_functions[] = {
	{ "hop_slots", l_hop_slots },
	{ "commit_stack", l_commit_stack },
	{ NULL, NULL }
};
