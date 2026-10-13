#include "common.h"
#include <tlhelp32.h>

enum {
	MAX_FROZEN = 1024,
	FREEZE_TRIES = 8,
	STACK_CHUNK = 512,
	MAX_STACK_SCAN = 8 * 1024 * 1024,
	THREAD_ACCESS = THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT | THREAD_QUERY_LIMITED_INFORMATION,
	NO_HIT = -1,
	UNREADABLE = -2
};

typedef LONG(NTAPI *NextThreadFunction)(HANDLE process, HANDLE thread, ACCESS_MASK access, ULONG attributes, ULONG flags, PHANDLE next);

static HANDLE threads[MAX_FROZEN];
static DWORD thread_ids[MAX_FROZEN];
static int thread_count;
static DWORD listed_ids[MAX_FROZEN];
static int listed_count;
static Range scan[MAX_WHOLE_RANGES];
static int scan_origin[MAX_WHOLE_RANGES];
static int scan_count;
static UINT64 scan_end;
static LARGE_INTEGER window_start;
static LARGE_INTEGER window_length;

const char *freeze_text(int result)
{
	switch (result) {
	case FREEZE_BUSY:
		return "a thread is inside the function";
	case FREEZE_UNCHECKED:
		return "a thread could not be checked";
	}
	return "the other threads could not be suspended";
}

UINT64 freeze_microseconds(void)
{
	LARGE_INTEGER frequency;

	QueryPerformanceFrequency(&frequency);
	return (UINT64)window_length.QuadPart * 1000000 / (UINT64)frequency.QuadPart;
}

static BOOL prepare_scan(const Range *ranges, int count)
{
	int i, j;

	scan_count = 0;
	scan_end = 0;
	for (i = 0; i < count; i++) {
		if (!ranges[i].whole)
			continue;
		if (scan_count == MAX_WHOLE_RANGES)
			return FALSE;
		for (j = scan_count; j > 0 && scan[j - 1].at > ranges[i].at; j--) {
			scan[j] = scan[j - 1];
			scan_origin[j] = scan_origin[j - 1];
		}
		scan[j] = ranges[i];
		scan_origin[j] = i;
		scan_count++;
		if ((UINT64)(ranges[i].at + (INT_PTR)ranges[i].size) > scan_end)
			scan_end = (UINT64)(ranges[i].at + (INT_PTR)ranges[i].size);
	}
	return TRUE;
}

static int scan_hit(UINT64 value)
{
	int low = 0, high = scan_count;

	if (scan_count == 0 || value < (UINT64)scan[0].at || value >= scan_end)
		return NO_HIT;
	while (high - low > 1) {
		int middle = (low + high) / 2;

		if ((UINT64)scan[middle].at <= value)
			low = middle;
		else
			high = middle;
	}
	return value < (UINT64)scan[low].at + scan[low].size ? scan_origin[low] : NO_HIT;
}

static int scan_stack(UINT64 from, UINT64 to)
{
	UINT64 words[STACK_CHUNK];
	UINT64 at = from & ~(UINT64)7;

	while (at < to) {
		size_t bytes = to - at < sizeof words ? (size_t)(to - at) : sizeof words;
		size_t i;

		if (!copy_memory(words, (INT_PTR)at, bytes))
			return UNREADABLE;
		for (i = 0; i < bytes / sizeof words[0]; i++) {
			int hit = scan_hit(words[i]);

			if (hit != NO_HIT)
				return hit;
		}
		at += bytes;
	}
	return NO_HIT;
}

static int check_stack(UINT64 rsp, int *busy)
{
	MEMORY_BASIC_INFORMATION region;
	UINT64 end;
	int hit;

	if (!VirtualQuery((LPCVOID)rsp, &region, sizeof region) || region.State != MEM_COMMIT)
		return FREEZE_UNCHECKED;
	end = (UINT64)region.BaseAddress + region.RegionSize;
	if (end > rsp + MAX_STACK_SCAN)
		end = rsp + MAX_STACK_SCAN;
	hit = scan_stack(rsp, end);
	if (hit == UNREADABLE)
		return FREEZE_UNCHECKED;
	*busy = hit;
	return hit == NO_HIT ? FREEZE_OK : FREEZE_BUSY;
}

static int check_own_stack(const void *entry, int *busy)
{
	UINT64 base = (UINT64)((NT_TIB *)NtCurrentTeb())->StackBase;
	int hit;

	if (scan_count == 0 || (UINT64)entry >= base)
		return FREEZE_OK;
	hit = scan_stack((UINT64)entry, base);
	if (hit == UNREADABLE)
		return FREEZE_UNCHECKED;
	*busy = hit;
	return hit == NO_HIT ? FREEZE_OK : FREEZE_BUSY;
}

static int find_range(DWORD64 rip, const Range *ranges, int count)
{
	int i;

	for (i = 0; i < count; i++) {
		DWORD64 start = (DWORD64)ranges[i].at;

		if ((ranges[i].whole ? rip >= start : rip > start) && rip < start + ranges[i].size)
			return i;
	}
	return NO_HIT;
}

static int check_thread(HANDLE thread, const FreezeJob *job, int *busy)
{
	CONTEXT context;

	context.ContextFlags = CONTEXT_CONTROL;
	if (!GetThreadContext(thread, &context))
		return FREEZE_UNCHECKED;
	*busy = find_range(context.Rip, job->ranges, job->count);
	if (*busy != NO_HIT)
		return FREEZE_BUSY;
	return scan_count ? check_stack(context.Rsp, busy) : FREEZE_OK;
}

static BOOL is_known(DWORD id)
{
	int i;

	if (id == GetCurrentThreadId())
		return TRUE;
	for (i = 0; i < thread_count; i++) {
		if (thread_ids[i] == id)
			return TRUE;
	}
	return FALSE;
}

static int adopt(HANDLE thread, DWORD id, const FreezeJob *job, int *busy, BOOL *kept)
{
	if (thread_count == MAX_FROZEN)
		return FREEZE_FAILED;
	if (SuspendThread(thread) == (DWORD)-1)
		return FREEZE_OK;
	threads[thread_count] = thread;
	thread_ids[thread_count++] = id;
	*kept = TRUE;
	if (job->visit)
		job->visit(thread, job->context);
	return job->count ? check_thread(thread, job, busy) : FREEZE_OK;
}

static int walk_threads(NextThreadFunction next_thread, const FreezeJob *job, int *busy, BOOL *found)
{
	HANDLE previous = NULL, handle = NULL;
	BOOL kept = FALSE;
	int result = FREEZE_OK;

	*found = FALSE;
	while (result == FREEZE_OK && next_thread(GetCurrentProcess(), previous, THREAD_ACCESS, 0, 0, &handle) == 0) {
		DWORD id = GetThreadId(handle);

		if (previous && !kept)
			CloseHandle(previous);
		previous = handle;
		kept = FALSE;
		if (is_known(id))
			continue;
		result = adopt(handle, id, job, busy, &kept);
		*found = *found || kept;
	}
	if (previous && !kept)
		CloseHandle(previous);
	return result;
}

static BOOL list_threads(void)
{
	HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
	THREADENTRY32 entry = { sizeof entry };
	DWORD process = GetCurrentProcessId();
	BOOL more, fits = TRUE;

	if (snapshot == INVALID_HANDLE_VALUE)
		return FALSE;
	listed_count = 0;
	for (more = Thread32First(snapshot, &entry); more && fits; more = Thread32Next(snapshot, &entry)) {
		if (entry.th32OwnerProcessID != process)
			continue;
		fits = listed_count < MAX_FROZEN;
		if (fits)
			listed_ids[listed_count++] = entry.th32ThreadID;
	}
	CloseHandle(snapshot);
	return fits;
}

static int open_listed(const FreezeJob *job, int *busy)
{
	DWORD process = GetCurrentProcessId();
	int i, result = FREEZE_OK;

	for (i = 0; i < listed_count && result == FREEZE_OK; i++) {
		HANDLE thread;
		BOOL kept = FALSE;

		if (is_known(listed_ids[i]))
			continue;
		thread = OpenThread(THREAD_ACCESS, FALSE, listed_ids[i]);
		if (!thread)
			continue;
		if (GetProcessIdOfThread(thread) == process)
			result = adopt(thread, listed_ids[i], job, busy, &kept);
		if (!kept)
			CloseHandle(thread);
	}
	return result;
}

static int suspend_all(NextThreadFunction next_thread, const FreezeJob *job, int *busy)
{
	BOOL found = TRUE;
	int result = FREEZE_OK;

	QueryPerformanceCounter(&window_start);
	if (!next_thread)
		return open_listed(job, busy);
	while (result == FREEZE_OK && found)
		result = walk_threads(next_thread, job, busy, &found);
	return result;
}

void thaw_threads(void)
{
	LARGE_INTEGER now;
	int i;

	for (i = 0; i < thread_count; i++)
		ResumeThread(threads[i]);
	QueryPerformanceCounter(&now);
	window_length.QuadPart = now.QuadPart - window_start.QuadPart;
	for (i = 0; i < thread_count; i++)
		CloseHandle(threads[i]);
	thread_count = 0;
}

int freeze_threads(const FreezeJob *job, int *busy)
{
	NextThreadFunction next_thread = (NextThreadFunction)(void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtGetNextThread");
	int attempt, result = FREEZE_BUSY;

	if (!prepare_scan(job->ranges, job->count) || (scan_count && !job->entry))
		return FREEZE_FAILED;
	result = check_own_stack(job->entry, busy);
	if (result != FREEZE_OK)
		return result;
	if (!next_thread && !list_threads())
		return FREEZE_FAILED;
	for (attempt = 0; attempt < FREEZE_TRIES; attempt++) {
		if (attempt)
			Sleep(1);
		result = suspend_all(next_thread, job, busy);
		if (result == FREEZE_OK)
			return result;
		thaw_threads();
		if (result == FREEZE_FAILED)
			return result;
	}
	return result;
}
