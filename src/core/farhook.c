#include <string.h>

#include "common.h"
#include <tlhelp32.h>
#include "MinHook.h"
#include "buffer.h"
#include "trampoline.h"
#include "hde/hde64.h"

enum { HOP_SIZE = 14, SITE_JUMP = 5, PROLOGUE_SCAN = 32, FAR_BUFFER_SIZE = 64, RIP_MODRM = 0x05, RIP_MODRM_MASK = 0xC7, STACK_GUARD_KEEP = 0x3000, MAX_THREADS = 1024 };

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

static HANDLE suspended[MAX_THREADS];
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

static BYTE *take_hop_slot(void)
{
	BYTE *run;

	if (!padding_next && !code_section(0, &padding_next, &padding_end))
		return NULL;
	run = find_padding_run(padding_next, padding_end);
	if (!run)
		return NULL;
	padding_next = run + HOP_SIZE;
	return run;
}

static void write_absolute_jump(BYTE *at, UINT64 destination)
{
	AbsoluteJump jump = { { JUMP_RIP[0], JUMP_RIP[1] }, 0, destination };

	patch_memory((INT_PTR)at, (const char *)&jump, sizeof jump);
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

static int suspend_others(void)
{
	HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
	THREADENTRY32 entry = { sizeof entry };
	DWORD self = GetCurrentThreadId();
	DWORD process = GetCurrentProcessId();
	int count = 0;

	if (snapshot == INVALID_HANDLE_VALUE)
		return 0;
	for (BOOL more = Thread32First(snapshot, &entry); more && count < MAX_THREADS; more = Thread32Next(snapshot, &entry)) {
		HANDLE thread;

		if (entry.th32OwnerProcessID != process || entry.th32ThreadID == self)
			continue;
		thread = OpenThread(THREAD_SUSPEND_RESUME, FALSE, entry.th32ThreadID);
		if (thread && SuspendThread(thread) != (DWORD)-1)
			suspended[count++] = thread;
		else if (thread)
			CloseHandle(thread);
	}
	CloseHandle(snapshot);
	return count;
}

static void resume_others(int count)
{
	int i;

	for (i = 0; i < count; i++) {
		ResumeThread(suspended[i]);
		CloseHandle(suspended[i]);
	}
}

int install_far_hook(INT_PTR target, void *detour, void **original)
{
	TRAMPOLINE ct = { 0 };
	BYTE site_jump[SITE_JUMP] = { 0xE9, 0, 0, 0, 0 };
	BYTE *far_buffer;
	BYTE *hop;
	INT32 distance;
	int suspended_count;

	if (!prologue_relocatable((BYTE *)target))
		return MH_ERROR_UNSUPPORTED_FUNCTION;
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
	hop = take_hop_slot();
	if (!hop) {
		VirtualFree(far_buffer, 0, MEM_RELEASE);
		return MH_ERROR_MEMORY_ALLOC;
	}
	VirtualProtect(far_buffer, FAR_BUFFER_SIZE, PAGE_EXECUTE_READ, &(DWORD){ 0 });
	FlushInstructionCache(GetCurrentProcess(), far_buffer, FAR_BUFFER_SIZE);
	write_absolute_jump(hop, (UINT64)ct.pRelay);
	distance = (INT32)((INT_PTR)hop - (target + SITE_JUMP));
	memcpy(site_jump + 1, &distance, sizeof distance);
	suspended_count = suspend_others();
	patch_memory(target, (const char *)site_jump, sizeof site_jump);
	resume_others(suspended_count);
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
