#include <string.h>

#include "common.h"

#include <winternl.h>
#include <psapi.h>

enum {
	MAX_MODULES = 384,
	MODULE_NAME_SIZE = 64,
	MAX_NATIVE_FRAMES = 32,
	MAX_SCANNED_FRAMES = 12,
	SCAN_BYTES = 0x4000,
	CODE_BYTES_AROUND = 16,
	TEXT_PREVIEW = 40,
	SMALL_VALUE = 0x10000,
	CPP_EXCEPTION = 0xE06D7363,
	MEGABYTE = 1 << 20
};

typedef struct {
	ULONG_PTR base;
	ULONG_PTR end;
	BOOL other_program;
	char name[MODULE_NAME_SIZE];
} Module;

typedef struct {
	DWORD code;
	const char *name;
} CodeName;

static const CodeName code_names[] = {
	{ EXCEPTION_ACCESS_VIOLATION, "access violation" },
	{ EXCEPTION_ILLEGAL_INSTRUCTION, "illegal instruction" },
	{ EXCEPTION_PRIV_INSTRUCTION, "privileged instruction" },
	{ EXCEPTION_INT_DIVIDE_BY_ZERO, "integer division by zero" },
	{ EXCEPTION_INT_OVERFLOW, "integer overflow" },
	{ EXCEPTION_STACK_OVERFLOW, "stack overflow" },
	{ EXCEPTION_IN_PAGE_ERROR, "in-page error" },
	{ EXCEPTION_BREAKPOINT, "breakpoint" },
	{ EXCEPTION_DATATYPE_MISALIGNMENT, "misaligned data" },
	{ EXCEPTION_ARRAY_BOUNDS_EXCEEDED, "array bounds exceeded" },
	{ EXCEPTION_FLT_DIVIDE_BY_ZERO, "float division by zero" },
	{ EXCEPTION_FLT_INVALID_OPERATION, "invalid float operation" },
	{ 0xC0000374, "heap corruption" },
	{ 0xC0000409, "stack buffer overrun or fast fail" },
	{ (DWORD)CPP_EXCEPTION, "C++ exception" }
};

static const char *register_names[] = {
	"rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"
};

static Module modules[MAX_MODULES];
static int module_count;
static ULONG_PTR crash_stack;
static WCHAR windows_folder[MAX_PATH];
static size_t windows_length;
static WCHAR game_folder[MAX_PATH];
static size_t game_length;

void prepare_native_report(void)
{
	UINT length = GetWindowsDirectoryW(windows_folder, MAX_PATH);
	DWORD exe_length = GetModuleFileNameW(NULL, game_folder, MAX_PATH);

	windows_length = length < MAX_PATH ? length : 0;
	game_length = exe_length < MAX_PATH ? exe_length : 0;
	while (game_length > 0 && game_folder[game_length - 1] != L'\\')
		game_length--;
	prepare_clues();
}

static const char *exception_name(DWORD code)
{
	int i;

	for (i = 0; i < (int)(sizeof code_names / sizeof code_names[0]); i++) {
		if (code_names[i].code == code)
			return code_names[i].name;
	}
	return "exception";
}

static BOOL is_inside(const UNICODE_STRING *path, const WCHAR *folder, size_t length)
{
	return length && path->Length / sizeof(WCHAR) > length && _wcsnicmp(path->Buffer, folder, length) == 0;
}

static void copy_base_name(char *out, const UNICODE_STRING *path)
{
	int length = path->Length / sizeof(WCHAR), start = length, i;

	while (start > 0 && path->Buffer[start - 1] != L'\\')
		start--;
	for (i = 0; i < MODULE_NAME_SIZE - 1 && start + i < length; i++)
		out[i] = path->Buffer[start + i] < 128 ? (char)path->Buffer[start + i] : '?';
	out[i] = '\0';
}

static void add_module(const LDR_DATA_TABLE_ENTRY *entry)
{
	Module *module = &modules[module_count];

	module->base = (ULONG_PTR)entry->DllBase;
	module->end = module->base + ((ULONG_PTR)entry->Reserved3[1] & 0xFFFFFFFF);
	module->other_program = !is_inside(&entry->FullDllName, windows_folder, windows_length) &&
		!is_inside(&entry->FullDllName, game_folder, game_length);
	copy_base_name(module->name, &entry->FullDllName);
	module_count++;
}

void load_modules(void)
{
	const LIST_ENTRY *head, *link;

	module_count = 0;
	__try {
		head = &NtCurrentTeb()->ProcessEnvironmentBlock->Ldr->InMemoryOrderModuleList;
		for (link = head->Flink; link != head && module_count < MAX_MODULES; link = link->Flink)
			add_module(CONTAINING_RECORD(link, LDR_DATA_TABLE_ENTRY, InMemoryOrderLinks));
	} __except (EXCEPTION_EXECUTE_HANDLER) {
	}
}

static const Module *module_of(ULONG_PTR address)
{
	int i;

	for (i = 0; i < module_count; i++) {
		if (address >= modules[i].base && address < modules[i].end)
			return &modules[i];
	}
	return NULL;
}

void add_address(Text *text, ULONG_PTR address)
{
	const Module *module = module_of(address);
	char hook_code[96];

	if (module)
		add_text(text, "%s+0x%llx", module->name, (unsigned long long)(address - module->base));
	else if (describe_hook_code(address, hook_code, sizeof hook_code))
		add_text(text, "%016llx (%s)", (unsigned long long)address, hook_code);
	else
		add_text(text, "%016llx", (unsigned long long)address);
}

static void add_pointer(Text *text, ULONG_PTR address)
{
	const Module *module = module_of(address);

	if (module && module->other_program)
		add_text(text, "another program's DLL");
	else
		add_address(text, address);
}

static void add_function_start(Text *text, ULONG_PTR address, ULONG_PTR inside)
{
	const Module *module = module_of(address);
	ULONG64 image = 0;
	PRUNTIME_FUNCTION part = RtlLookupFunctionEntry(inside, &image, NULL);
	PRUNTIME_FUNCTION primary;
	ULONG_PTR part_start;

	if (!part || !module)
		return;
	primary = primary_function_entry(part, image);
	part_start = (ULONG_PTR)image + part->BeginAddress;
	add_text(text, "  function +0x%llx", (unsigned long long)(image + primary->BeginAddress - module->base));
	if (part != primary)
		add_text(text, ", part +0x%llx", (unsigned long long)(part_start - module->base));
	add_text(text, ", offset +0x%llx", (unsigned long long)(address - part_start));
}

static void add_code_location(Text *text, ULONG_PTR address)
{
	add_address(text, address);
	add_function_start(text, address, address);
}

static BOOL is_readable(ULONG_PTR address, size_t size)
{
	MEMORY_BASIC_INFORMATION region;

	return VirtualQuery((LPCVOID)address, &region, sizeof region) && region.State == MEM_COMMIT &&
		!(region.Protect & (PAGE_GUARD | PAGE_NOACCESS)) && address + size <= (ULONG_PTR)region.BaseAddress + region.RegionSize;
}

const char *other_program_at(ULONG_PTR address)
{
	const Module *module = module_of(address);

	return module && module->other_program ? module->name : NULL;
}

const char *register_name(int index)
{
	return register_names[index];
}

static BOOL is_code(ULONG_PTR address)
{
	MEMORY_BASIC_INFORMATION region;

	return VirtualQuery((LPCVOID)address, &region, sizeof region) && region.State == MEM_COMMIT &&
		(region.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY));
}

static void add_frame(Text *text, int number, ULONG_PTR rip, BOOL return_address, const char *note)
{
	add_text(text, "  #%d ", number);
	add_address(text, rip);
	add_function_start(text, rip, return_address ? rip - 1 : rip);
	add_text(text, "%s\n", note);
}

static BOOL follows_call(ULONG_PTR address)
{
	BYTE before[7];

	if (address < sizeof before || !copy_memory(before, (INT_PTR)(address - sizeof before), sizeof before))
		return FALSE;
	return before[2] == 0xE8 || (before[1] == 0xFF && (before[2] >> 3 & 7) == 2) ||
		(before[3] == 0xFF && (before[4] >> 3 & 7) == 2) || (before[4] == 0xFF && (before[5] >> 3 & 7) == 2) ||
		(before[5] == 0xFF && (before[6] >> 3 & 7) == 2) || (before[0] == 0xFF && (before[1] >> 3 & 7) == 2);
}

static void scan_stack(Text *text, ULONG_PTR rsp, int number)
{
	ULONG_PTR at, value;
	int found = 0;

	for (at = rsp & ~(ULONG_PTR)7; at < rsp + SCAN_BYTES && found < MAX_SCANNED_FRAMES; at += sizeof value) {
		if (!copy_memory(&value, (INT_PTR)at, sizeof value))
			break;
		if (module_of(value) && is_code(value) && follows_call(value)) {
			add_frame(text, number + found, value, TRUE, "  (stack scan)");
			found++;
		}
	}
}

void add_native_stack(Text *text, const CONTEXT *start)
{
	CONTEXT context = *start;
	ULONG64 image, establisher, previous;
	PRUNTIME_FUNCTION entry;
	PVOID handler_data;
	const char *note = "";
	int number;

	for (number = 0; number < MAX_NATIVE_FRAMES; number++) {
		add_frame(text, number, context.Rip, number > 0, note);
		note = "";
		previous = context.Rsp;
		entry = RtlLookupFunctionEntry(context.Rip, &image, NULL);
		__try {
			if (entry) {
				RtlVirtualUnwind(UNW_FLAG_NHANDLER, image, context.Rip, entry, &context, &handler_data, &establisher, NULL);
			} else if (number == 0 && copy_memory(&context.Rip, (INT_PTR)context.Rsp, sizeof context.Rip)) {
				context.Rsp += sizeof context.Rip;
				note = "  (no unwind data for #0, return address read at rsp)";
			} else {
				scan_stack(text, context.Rsp, number + 1);
				return;
			}
		} __except (EXCEPTION_EXECUTE_HANDLER) {
			scan_stack(text, previous, number + 1);
			return;
		}
		if (!context.Rip || context.Rsp <= previous)
			return;
	}
}

static BOOL starts_one_of(ULONG_PTR address, const ULONG_PTR *functions, int count)
{
	ULONG64 image = 0;
	PRUNTIME_FUNCTION entry = RtlLookupFunctionEntry(address, &image, NULL);
	ULONG_PTR start;
	int i;

	if (!entry)
		return FALSE;
	start = (ULONG_PTR)image + primary_function_entry(entry, image)->BeginAddress;
	for (i = 0; i < count; i++) {
		if (functions[i] == start)
			return TRUE;
	}
	return FALSE;
}

BOOL stack_enters(const CONTEXT *start, const ULONG_PTR *functions, int count, int depth)
{
	CONTEXT context = *start;
	ULONG64 image, establisher;
	PRUNTIME_FUNCTION entry;
	PVOID handler_data;
	int number;

	for (number = 0; number < depth && context.Rip; number++) {
		if (starts_one_of(number ? context.Rip - 1 : context.Rip, functions, count))
			return TRUE;
		entry = RtlLookupFunctionEntry(context.Rip, &image, NULL);
		if (!entry)
			return FALSE;
		RtlVirtualUnwind(UNW_FLAG_NHANDLER, image, context.Rip, entry, &context, &handler_data, &establisher, NULL);
	}
	return FALSE;
}

BOOL is_printable(BYTE value)
{
	return value >= ' ' && value < 127;
}

static int printable_length(const char *text, int size)
{
	int length = 0;

	while (length < size && is_printable((BYTE)text[length]))
		length++;
	return length;
}

int wide_text_length(const BYTE *bytes, int units)
{
	int length = 0;

	while (length < units && bytes[2 * length + 1] == 0 && is_printable(bytes[2 * length]))
		length++;
	return length;
}

static void add_wide_text(Text *text, const char *label, const BYTE *bytes, int length)
{
	int i;

	add_text(text, "%stext \"", label);
	for (i = 0; i < length; i++)
		add_text(text, "%c", bytes[2 * i]);
	add_text(text, "\"");
}

static BOOL add_text_preview(Text *text, ULONG_PTR address)
{
	char preview[TEXT_PREVIEW + 1];
	BYTE wide[2 * TEXT_PREVIEW];
	int length;

	if (read_ca_text((INT_PTR)address, FALSE, preview, sizeof preview) && preview[0] &&
		printable_length(preview, TEXT_PREVIEW) == (int)strlen(preview)) {
		add_text(text, "  CA string \"%s\"", preview);
		return TRUE;
	}
	if (!copy_memory(preview, (INT_PTR)address, TEXT_PREVIEW))
		return FALSE;
	length = printable_length(preview, TEXT_PREVIEW);
	if (length >= 4) {
		add_text(text, "  text \"%.*s\"", length, preview);
		return TRUE;
	}
	if (!copy_memory(wide, (INT_PTR)address, sizeof wide) || (length = wide_text_length(wide, TEXT_PREVIEW)) < 4)
		return FALSE;
	add_wide_text(text, "  ", wide, length);
	return TRUE;
}

static void add_value_as_text(Text *text, ULONG_PTR value)
{
	const BYTE *bytes = (const BYTE *)&value;
	int length = printable_length((const char *)bytes, sizeof value), i;

	if (wide_text_length(bytes, sizeof value / 2) == sizeof value / 2) {
		add_wide_text(text, ", ", bytes, sizeof value / 2);
		return;
	}
	if (length < 4)
		return;
	for (i = length; i < (int)sizeof value; i++) {
		if (bytes[i])
			return;
	}
	add_text(text, ", text \"%.*s\"", length, (const char *)bytes);
}

BOOL is_bad_pointer(ULONG_PTR value)
{
	return value >= SMALL_VALUE && !is_readable(value, 1);
}

void set_crash_stack(ULONG_PTR rsp)
{
	MEMORY_BASIC_INFORMATION region;

	crash_stack = VirtualQuery((LPCVOID)rsp, &region, sizeof region) ? (ULONG_PTR)region.AllocationBase : 0;
}

static BOOL on_crash_stack(ULONG_PTR address)
{
	MEMORY_BASIC_INFORMATION region;

	return crash_stack && VirtualQuery((LPCVOID)address, &region, sizeof region) && (ULONG_PTR)region.AllocationBase == crash_stack;
}

BOOL is_heap_pointer(ULONG_PTR value)
{
	return value >= SMALL_VALUE && !module_of(value) && !on_crash_stack(value) && is_readable(value, sizeof value);
}

static BOOL is_vtable(ULONG_PTR address)
{
	ULONG_PTR first_slot;

	return module_of(address) && !is_code(address) && copy_memory(&first_slot, (INT_PTR)address, sizeof first_slot) &&
		module_of(first_slot) && is_code(first_slot);
}

static void add_value(Text *text, ULONG_PTR value)
{
	ULONG_PTR first;

	if (value < SMALL_VALUE)
		return;
	if (module_of(value) || describe_hook_code(value, NULL, 0)) {
		add_text(text, "  -> ");
		add_pointer(text, value);
		return;
	}
	if (on_crash_stack(value)) {
		add_text(text, "  stack");
		return;
	}
	if (!is_readable(value, sizeof first)) {
		add_text(text, "  not readable");
		add_value_as_text(text, value);
		return;
	}
	if (copy_memory(&first, (INT_PTR)value, sizeof first) && is_vtable(first)) {
		add_text(text, "  object, vtable ");
		add_pointer(text, first);
		return;
	}
	if (!add_text_preview(text, value))
		add_text(text, "  readable");
}

void add_registers(Text *text, const CONTEXT *context)
{
	const DWORD64 *values = &context->Rax;
	int i;

	for (i = 0; i < 16; i++) {
		add_text(text, "  %-3s %016llx", register_names[i], (unsigned long long)values[i]);
		add_value(text, (ULONG_PTR)values[i]);
		add_text(text, "\n");
	}
	add_text(text, "  rip %016llx  eflags %08lx\n", (unsigned long long)context->Rip, context->EFlags);
}

void add_code_bytes(Text *text, ULONG_PTR rip)
{
	BYTE code[2 * CODE_BYTES_AROUND];
	int i, first = 0;

	if (!copy_memory(code, (INT_PTR)(rip - CODE_BYTES_AROUND), sizeof code)) {
		first = CODE_BYTES_AROUND;
		if (!copy_memory(code + first, (INT_PTR)rip, CODE_BYTES_AROUND))
			return;
	}
	add_text(text, "Code at rip:");
	for (i = first; i < (int)sizeof code; i++)
		add_text(text, i == CODE_BYTES_AROUND ? " [%02X" : i == CODE_BYTES_AROUND + 1 ? "] %02X" : " %02X", code[i]);
	add_text(text, "\n");
}

static void add_fault_target(Text *text, ULONG_PTR target)
{
	if (target < SMALL_VALUE)
		add_text(text, " (a NULL pointer + 0x%llx)", (unsigned long long)target);
	else
		add_value(text, target);
}

static BOOL read_rva(ULONG_PTR image, DWORD rva, void *out, size_t size)
{
	return rva && copy_memory(out, (INT_PTR)(image + rva), size);
}

static void add_cpp_type(Text *text, const EXCEPTION_RECORD *record)
{
	ULONG_PTR image;
	DWORD throw_info[4], types[2], catchable[2];
	char name[MODULE_NAME_SIZE * 2];

	if (record->ExceptionCode != (DWORD)CPP_EXCEPTION || record->NumberParameters < 4)
		return;
	image = record->ExceptionInformation[3];
	if (!copy_memory(throw_info, (INT_PTR)record->ExceptionInformation[2], sizeof throw_info) ||
		!read_rva(image, throw_info[3], types, sizeof types) || types[0] == 0 ||
		!read_rva(image, types[1], catchable, sizeof catchable) ||
		!read_rva(image, catchable[1] + 2 * sizeof(ULONG_PTR), name, sizeof name))
		return;
	name[sizeof name - 1] = '\0';
	add_text(text, ", type %s", name);
}

static const char *access_name(ULONG_PTR access)
{
	switch (access) {
	case EXCEPTION_READ_FAULT:    return "read";
	case EXCEPTION_EXECUTE_FAULT: return "execution";
	default:                      return "write";
	}
}

void add_fault(Text *text, const EXCEPTION_RECORD *record)
{
	add_text(text, "exception 0x%08lx (%s", record->ExceptionCode, exception_name(record->ExceptionCode));
	add_cpp_type(text, record);
	add_text(text, ") at ");
	add_code_location(text, (ULONG_PTR)record->ExceptionAddress);
	if (record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && record->NumberParameters >= 2) {
		add_text(text, ", %s of %p", access_name(record->ExceptionInformation[0]), (void *)record->ExceptionInformation[1]);
		add_fault_target(text, record->ExceptionInformation[1]);
	}
	add_text(text, "\n");
}

void add_memory_use(Text *text)
{
	PROCESS_MEMORY_COUNTERS_EX process = { sizeof process };
	MEMORYSTATUSEX system = { sizeof system };

	if (GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS *)&process, sizeof process))
		add_text(text, "Memory: game %llu MB committed, %llu MB in RAM", (unsigned long long)(process.PrivateUsage / MEGABYTE),
			(unsigned long long)(process.WorkingSetSize / MEGABYTE));
	if (GlobalMemoryStatusEx(&system))
		add_text(text, "; PC %llu of %llu MB RAM free, %llu of %llu MB commit free",
			(unsigned long long)(system.ullAvailPhys / MEGABYTE), (unsigned long long)(system.ullTotalPhys / MEGABYTE),
			(unsigned long long)(system.ullAvailPageFile / MEGABYTE), (unsigned long long)(system.ullTotalPageFile / MEGABYTE));
	add_text(text, "\n");
}

void add_other_module_count(Text *text)
{
	int count = 0, known = 0;
	int i;

	for (i = 1; i < module_count; i++) {
		if (!modules[i].other_program)
			continue;
		count++;
		if (is_known_program(modules[i].name))
			known++;
	}
	add_text(text, "Other programs' DLLs loaded: %d", count);
	if (known)
		add_text(text, ", %d of them known overlays, drivers and antivirus", known);
	add_text(text, "\n");
}
