#include <string.h>

#include "asm.h"

enum EncodeResult { ENCODE_NONE, ENCODE_OK, ENCODE_AMBIGUOUS, ENCODE_ERROR };

enum { REACH = 0x7FFFFFF0, LISTED_DATA = 16, LINE_TEXT = 256, LISTING_LINE = 220 };

typedef struct {
	BYTE bytes[ZYDIS_MAX_INSTRUCTION_LENGTH];
	ZyanUSize length;
} Encoded;

static const ZyanU16 memory_sizes[] = { 1, 2, 4, 8, 10, 16, 32, 64 };
static const INT64 sentinels[9] = { 0, 0x7F, 0x7FF0, 0, 0x7FFFFFF0, 0, 0, 0, 0x7FFFFFFFFFFFFFF0 };
static const char *const unit_words[9] = { "", "db", "dw", "", "dd", "", "", "", "dq" };
static const BYTE nops[9][9] = {
	{ 0x90 },
	{ 0x66, 0x90 },
	{ 0x0F, 0x1F, 0x00 },
	{ 0x0F, 0x1F, 0x40, 0x00 },
	{ 0x0F, 0x1F, 0x44, 0x00, 0x00 },
	{ 0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00 },
	{ 0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00 },
	{ 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 },
	{ 0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 },
};

static ZydisDecoder decoder;
static ZydisFormatter formatter;
static BOOL tools_ready;

static void prepare_tools(void)
{
	if (tools_ready)
		return;
	ZydisDecoderInit(&decoder, ZYDIS_MACHINE_MODE_LONG_64, ZYDIS_STACK_WIDTH_64);
	ZydisFormatterInit(&formatter, ZYDIS_FORMATTER_STYLE_INTEL);
	ZydisFormatterSetProperty(&formatter, ZYDIS_FORMATTER_PROP_FORCE_SIZE, ZYAN_TRUE);
	ZydisFormatterSetProperty(&formatter, ZYDIS_FORMATTER_PROP_HEX_UPPERCASE, ZYAN_FALSE);
	ZydisFormatterSetProperty(&formatter, ZYDIS_FORMATTER_PROP_ADDR_PADDING_ABSOLUTE, ZYDIS_PADDING_DISABLED);
	ZydisFormatterSetProperty(&formatter, ZYDIS_FORMATTER_PROP_IMM_PADDING, ZYDIS_PADDING_DISABLED);
	ZydisFormatterSetProperty(&formatter, ZYDIS_FORMATTER_PROP_DISP_PADDING, ZYDIS_PADDING_DISABLED);
	tools_ready = TRUE;
}

static INT_PTR section_base(const Program *p, int section)
{
	return section == SECTION_CODE ? p->address : p->address + p->code_size + JUMP_BACK_SIZE;
}

static int image_offset(const Program *p, const Line *line)
{
	return line->section == SECTION_CODE ? line->offset : p->code_size + JUMP_BACK_SIZE + line->offset;
}

static INT_PTR line_address(const Program *p, const Line *line)
{
	return p->address + image_offset(p, line);
}

static INT_PTR label_address(const Program *p, int index)
{
	const Label *label = &p->labels[index];

	if (label->target >= 0)
		return line_address(p, &p->lines[label->target]);
	return section_base(p, label->section) + (label->section == SECTION_CODE ? p->code_size : p->data_size);
}

static void place(Program *p)
{
	int offsets[2] = { 0, 0 }, i;

	for (i = 0; i < p->line_count; i++) {
		Line *line = &p->lines[i];

		line->offset = offsets[line->section];
		offsets[line->section] += line->size;
	}
	p->code_size = offsets[SECTION_CODE];
	p->data_size = offsets[SECTION_DATA];
}

static INT64 raw_number(const Name *name)
{
	UINT64 value = 0;
	int i;

	for (i = name->raw_size - 1; i >= 0; i--)
		value = value << 8 | name->raw[i];
	return name->raw_size == 4 ? (INT64)(INT32)(UINT32)value : (INT64)value;
}

static BOOL plain_value(Program *p, const Line *line, const Operand *op, INT64 *out)
{
	const Name *name = &p->names[op->name];

	if (name->kind == GIVEN_NONE)
		return asm_fail(p, line->line, op->column, "{%s} has no value", name->name);
	*out = name->kind == GIVEN_RAW ? raw_number(name) : name->number;
	return TRUE;
}

static BOOL operand_value(Program *p, const Line *line, const Operand *op, INT64 *out)
{
	INT64 value = op->number, named = 0;

	if (op->name >= 0 && op->slot_size)
		named = sentinels[op->slot_size];
	else if (op->name >= 0 && !plain_value(p, line, op, &named))
		return FALSE;
	if (op->label >= 0)
		value += label_address(p, op->label);
	*out = value + named;
	return TRUE;
}

static ZydisBranchWidth target_width(const Line *line, const Operand *op)
{
	if (op->width == 8)
		return ZYDIS_BRANCH_WIDTH_8;
	if (op->width == 32 || op->label < 0 || line->wide)
		return ZYDIS_BRANCH_WIDTH_32;
	return ZYDIS_BRANCH_WIDTH_8;
}

static int destination_bits(const Line *line)
{
	const Operand *first = &line->operands[0];

	if (first->kind == OPERAND_REGISTER)
		return ZydisRegisterGetWidth(ZYDIS_MACHINE_MODE_LONG_64, first->reg);
	return first->kind == OPERAND_MEMORY ? first->size * 8 : 0;
}

static INT64 signed_immediate(const Line *line, INT64 value)
{
	int bits = destination_bits(line);

	if (bits < 8 || bits > 32 || value < ((INT64)1 << (bits - 1)) || value >= ((INT64)1 << bits))
		return value;
	return value - ((INT64)1 << bits);
}

static BOOL fill_operand(Program *p, const Line *line, const Operand *op, ZydisEncoderRequest *request, int index)
{
	ZydisEncoderOperand *out = &request->operands[index];
	INT64 value;

	if (op->kind == OPERAND_REGISTER) {
		out->type = ZYDIS_OPERAND_TYPE_REGISTER;
		out->reg.value = op->reg;
		return TRUE;
	}
	if (!operand_value(p, line, op, &value))
		return FALSE;
	if (op->kind == OPERAND_MEMORY) {
		out->type = ZYDIS_OPERAND_TYPE_MEMORY;
		out->mem.base = op->reg;
		out->mem.index = op->index;
		out->mem.scale = op->index ? op->scale : 0;
		out->mem.displacement = value;
		out->mem.size = op->size;
		return TRUE;
	}
	out->type = ZYDIS_OPERAND_TYPE_IMMEDIATE;
	out->imm.s = value;
	if (op->kind == OPERAND_TARGET)
		request->branch_width = target_width(line, op);
	else
		out->imm.s = signed_immediate(line, value);
	return TRUE;
}

static BOOL fill_request(Program *p, const Line *line, ZydisEncoderRequest *request)
{
	int i;

	memset(request, 0, sizeof *request);
	request->machine_mode = ZYDIS_MACHINE_MODE_LONG_64;
	request->mnemonic = line->mnemonic;
	request->prefixes = line->prefixes;
	request->operand_count = (ZyanU8)line->count;
	for (i = 0; i < line->count; i++) {
		if (!fill_operand(p, line, &line->operands[i], request, i))
			return FALSE;
	}
	return TRUE;
}

static BOOL try_encode(const ZydisEncoderRequest *request, INT_PTR address, Encoded *out)
{
	ZydisEncoderRequest copy = *request;

	out->length = sizeof out->bytes;
	return ZYAN_SUCCESS(ZydisEncoderEncodeInstructionAbsolute(&copy, out->bytes, &out->length, (ZyanU64)address));
}

static int unsized_memory(const Line *line)
{
	int i;

	for (i = 0; i < line->count; i++) {
		if (line->operands[i].kind == OPERAND_MEMORY && line->operands[i].size == 0)
			return i;
	}
	return -1;
}

static int encode_any_size(ZydisEncoderRequest *request, int memory, INT_PTR address, Encoded *out)
{
	Encoded candidate;
	BOOL found = FALSE;
	size_t i;

	for (i = 0; i < sizeof memory_sizes / sizeof memory_sizes[0]; i++) {
		request->operands[memory].mem.size = memory_sizes[i];
		if (!try_encode(request, address, &candidate))
			continue;
		if (found && (candidate.length != out->length || memcmp(candidate.bytes, out->bytes, candidate.length) != 0))
			return ENCODE_AMBIGUOUS;
		*out = candidate;
		found = TRUE;
	}
	request->operands[memory].mem.size = 0;
	return found ? ENCODE_OK : ENCODE_NONE;
}

static int encode_request(const Line *line, ZydisEncoderRequest *request, INT_PTR address, Encoded *out)
{
	int memory = unsized_memory(line);

	if (memory >= 0)
		return encode_any_size(request, memory, address, out);
	return try_encode(request, address, out) ? ENCODE_OK : ENCODE_NONE;
}

static int encode_once(Program *p, const Line *line, INT_PTR address, Encoded *out, ZydisEncoderRequest *request)
{
	if (!fill_request(p, line, request))
		return ENCODE_ERROR;
	return encode_request(line, request, address, out);
}

static BOOL can_widen(const Line *line)
{
	int i;

	for (i = 0; i < line->count; i++) {
		const Operand *op = &line->operands[i];

		if (op->kind == OPERAND_TARGET && op->label >= 0 && op->width == 0 && !line->wide)
			return TRUE;
	}
	return FALSE;
}

static BOOL out_of_reach(INT64 target, INT_PTR address)
{
	INT64 distance = target - (INT64)address;

	return distance > REACH || distance < -REACH;
}

static BOOL slot_is_the_problem(const Line *line, ZydisEncoderRequest *request, INT_PTR address, int index)
{
	const Operand *op = &line->operands[index];
	ZydisEncoderOperand *out = &request->operands[index];
	Encoded ignored;

	if (op->kind == OPERAND_MEMORY)
		out->mem.displacement -= sentinels[op->slot_size];
	else
		out->imm.s -= sentinels[op->slot_size];
	return encode_request(line, request, address, &ignored) == ENCODE_OK;
}

static BOOL explain_operand(Program *p, const Line *line, ZydisEncoderRequest *request, INT_PTR address, int index)
{
	const Operand *op = &line->operands[index];
	const ZydisEncoderOperand *out = &request->operands[index];
	const char *mnemonic = ZydisMnemonicGetString(line->mnemonic);

	if (op->kind == OPERAND_TARGET && op->width == 8 && op->label >= 0)
		return asm_fail(p, line->line, op->column, "the short jump to '%s' is out of range", p->labels[op->label].name);
	if (op->kind == OPERAND_TARGET && op->label < 0 && out_of_reach(out->imm.s, address))
		return asm_fail(p, line->line, op->column, "%s target 0x%llx is out of rel32 reach of the cave", mnemonic, out->imm.u);
	if (op->kind == OPERAND_MEMORY && op->reg == ZYDIS_REGISTER_RIP && out_of_reach(out->mem.displacement, address))
		return asm_fail(p, line->line, op->column, "rip target 0x%llx is out of rel32 reach of the cave", (UINT64)out->mem.displacement);
	if (op->name >= 0 && op->slot_size && slot_is_the_problem(line, request, address, index))
		return asm_fail(p, line->line, op->column, "{%s:%d} cannot be a %d-byte field in this instruction", p->names[op->name].name, op->slot_size, op->slot_size);
	return TRUE;
}

static BOOL explain_failure(Program *p, const Line *line, INT_PTR address)
{
	ZydisEncoderRequest request;
	int i;

	for (i = 0; i < line->count; i++) {
		if (!fill_request(p, line, &request) || !explain_operand(p, line, &request, address, i))
			return FALSE;
	}
	return asm_fail(p, line->line, line->column, "no encoding for '%.*s'", line->text_length, p->text + line->text);
}

static BOOL encode_instruction(Program *p, Line *line, INT_PTR address, Encoded *out)
{
	ZydisEncoderRequest request;
	int result = encode_once(p, line, address, out, &request);

	if (result == ENCODE_NONE && can_widen(line)) {
		line->wide = 1;
		result = encode_once(p, line, address, out, &request);
	}
	if (result == ENCODE_OK)
		return TRUE;
	if (result == ENCODE_AMBIGUOUS)
		return asm_fail(p, line->line, line->column, "say byte, word, dword or qword ptr: more than one size fits");
	return result == ENCODE_ERROR ? FALSE : explain_failure(p, line, address);
}

static BOOL measure_line(Program *p, Line *line, int *size)
{
	INT_PTR address = line_address(p, line);
	Encoded code;

	if (line->kind == LINE_DATA) {
		*size = line->unit * line->count;
		return TRUE;
	}
	if (line->kind == LINE_ALIGN) {
		*size = (int)((UINT64)(-(INT64)address) & (UINT64)(line->first - 1));
		return TRUE;
	}
	if (!encode_instruction(p, line, address, &code))
		return FALSE;
	*size = (int)code.length;
	return TRUE;
}

static BOOL measure(Program *p)
{
	int round, i, size;

	for (round = 0; round < ASM_ROUNDS; round++) {
		BOOL changed = FALSE;

		place(p);
		for (i = 0; i < p->line_count; i++) {
			if (!measure_line(p, &p->lines[i], &size))
				return FALSE;
			changed |= size != p->lines[i].size;
			p->lines[i].size = size;
		}
		if (!changed)
			return TRUE;
	}
	return asm_fail(p, 1, 1, "the jumps did not settle in %d rounds", ASM_ROUNDS);
}

static BOOL fits(INT64 value, int size)
{
	INT64 low, high;

	if (size == 8)
		return TRUE;
	low = -((INT64)1 << (size * 8 - 1));
	high = ((INT64)1 << (size * 8)) - 1;
	return value >= low && value <= high;
}

static const char *sign_of(INT64 value)
{
	return value < 0 ? "-" : "";
}

static UINT64 magnitude(INT64 value)
{
	return value < 0 ? 0 - (UINT64)value : (UINT64)value;
}

static BOOL slot_bytes(Program *p, const Line *line, const Operand *op, BYTE *out, BYTE *given)
{
	const Name *name = &p->names[op->name];
	int size = op->slot_size;

	*given = name->kind != GIVEN_NONE;
	if (!*given && !p->wildcards)
		return asm_fail(p, line->line, op->column, "{%s:%d} has no value", name->name, size);
	if (!*given) {
		memset(out, 0, (size_t)size);
		return TRUE;
	}
	if (name->kind == GIVEN_RAW && name->raw_size != size)
		return asm_fail(p, line->line, op->column, "{%s:%d} needs %d bytes, the value has %d", name->name, size, size, name->raw_size);
	if (name->kind == GIVEN_RAW) {
		memcpy(out, name->raw, (size_t)size);
		return TRUE;
	}
	if (!fits(name->number, size))
		return asm_fail(p, line->line, op->column, "{%s:%d} does not fit %s0x%llx", name->name, size, sign_of(name->number), magnitude(name->number));
	memcpy(out, &name->number, (size_t)size);
	return TRUE;
}

static BOOL write_slot(Program *p, const Line *line, const Operand *op, int at)
{
	Slot *slot;
	BYTE given;

	if (p->slot_count == ASM_MAX_SLOTS)
		return asm_fail(p, line->line, op->column, "more than %d slots", ASM_MAX_SLOTS);
	if (!slot_bytes(p, line, op, p->image + at, &given))
		return FALSE;
	slot = &p->slots[p->slot_count++];
	slot->name = op->name;
	slot->size = op->slot_size;
	slot->given = given;
	slot->offset = at;
	slot->line = (int)(line - p->lines);
	return TRUE;
}

static BOOL field_of(Program *p, const Line *line, const Operand *op, const ZydisDecodedInstruction *decoded, int immediate, int *offset)
{
	int bits = op->kind == OPERAND_MEMORY ? decoded->raw.disp.size : decoded->raw.imm[immediate].size;
	int size = op->slot_size;

	*offset = op->kind == OPERAND_MEMORY ? decoded->raw.disp.offset : decoded->raw.imm[immediate].offset;
	if (bits == size * 8)
		return TRUE;
	return asm_fail(p, line->line, op->column, "{%s:%d} cannot be a %d-byte field in this instruction", p->names[op->name].name, size, size);
}

static BOOL place_slots(Program *p, const Line *line, const Encoded *code, int at)
{
	ZydisDecodedInstruction decoded;
	int i, immediates = 0, offset;

	if (!ZYAN_SUCCESS(ZydisDecoderDecodeInstruction(&decoder, NULL, code->bytes, code->length, &decoded)))
		return asm_fail(p, line->line, line->column, "the encoded bytes do not decode");
	for (i = 0; i < line->count; i++) {
		const Operand *op = &line->operands[i];

		if (op->kind == OPERAND_IMMEDIATE)
			immediates++;
		if (op->name < 0 || !op->slot_size)
			continue;
		if (!field_of(p, line, op, &decoded, immediates - 1, &offset))
			return FALSE;
		if (memcmp(code->bytes + offset, &sentinels[op->slot_size], op->slot_size) != 0)
			return asm_fail(p, line->line, op->column, "{%s:%d} cannot be a %d-byte field in this instruction", p->names[op->name].name, op->slot_size, op->slot_size);
		if (!write_slot(p, line, op, at + offset))
			return FALSE;
	}
	return TRUE;
}

static BOOL emit_instruction(Program *p, Line *line, int at)
{
	Encoded code;

	if (!encode_instruction(p, line, line_address(p, line), &code))
		return FALSE;
	if ((int)code.length != line->size)
		return asm_fail(p, line->line, line->column, "the encoding changed between passes");
	memcpy(p->image + at, code.bytes, code.length);
	return place_slots(p, line, &code, at);
}

static BOOL emit_value(Program *p, const Line *line, const Operand *op, int at)
{
	INT64 value;

	if (op->name >= 0 && op->slot_size) {
		if (op->slot_size != line->unit)
			return asm_fail(p, line->line, op->column, "{%s:%d} does not match %s", p->names[op->name].name, op->slot_size, unit_words[line->unit]);
		return write_slot(p, line, op, at);
	}
	if (!operand_value(p, line, op, &value))
		return FALSE;
	if (!fits(value, line->unit))
		return asm_fail(p, line->line, op->column, "%s0x%llx does not fit %s", sign_of(value), magnitude(value), unit_words[line->unit]);
	memcpy(p->image + at, &value, line->unit);
	return TRUE;
}

static void fill_nops(BYTE *out, int size)
{
	while (size > 0) {
		int length = size < 9 ? size : 9;

		memcpy(out, nops[length - 1], (size_t)length);
		out += length;
		size -= length;
	}
}

static BOOL emit_line(Program *p, Line *line)
{
	int at = image_offset(p, line), i;

	if (line->kind == LINE_INSTRUCTION)
		return emit_instruction(p, line, at);
	if (line->kind == LINE_ALIGN && line->section == SECTION_CODE)
		fill_nops(p->image + at, line->size);
	if (line->kind == LINE_ALIGN)
		return TRUE;
	for (i = 0; i < line->count; i++) {
		if (!emit_value(p, line, &p->values[line->first + i], at + i * line->unit))
			return FALSE;
	}
	return TRUE;
}

static BOOL emit(Program *p)
{
	int i;

	place(p);
	if (p->code_size == 0)
		return asm_fail(p, 1, 1, "no instructions");
	if (p->code_size + JUMP_BACK_SIZE + p->data_size > ASM_MAX_CAVE)
		return asm_fail(p, 1, 1, "the cave is larger than %d bytes", ASM_MAX_CAVE);
	p->total = p->data_size ? p->code_size + JUMP_BACK_SIZE + p->data_size : p->code_size;
	memset(p->image, 0, sizeof p->image);
	p->slot_count = 0;
	for (i = 0; i < p->line_count; i++) {
		if (!emit_line(p, &p->lines[i]))
			return FALSE;
	}
	return TRUE;
}

BOOL build_program(Program *p)
{
	prepare_tools();
	return measure(p) && emit(p);
}

size_t listing_size(const Program *p)
{
	return (size_t)(p->line_count + 4) * LISTING_LINE + (size_t)p->slot_count * 64;
}

static void add_bytes(Text *out, const BYTE *bytes, int count, int shown)
{
	int i, used = 0;

	for (i = 0; i < count && i < shown; i++) {
		add_text(out, "%02X ", bytes[i]);
		used += 3;
	}
	if (count > shown) {
		add_text(out, "... ");
		used += 4;
	}
	add_text(out, "%*s", used < 24 ? 24 - used : 1, "");
}

static void add_slot_notes(const Program *p, Text *out, int line)
{
	int i;

	for (i = 0; i < p->slot_count; i++) {
		const Slot *slot = &p->slots[i];

		if (slot->line == line)
			add_text(out, "  {%s:%d} at +%02x", p->names[slot->name].name, slot->size, slot->offset);
	}
}

static void add_instruction(const Program *p, Text *out, const Line *line, int at)
{
	ZydisDecodedInstruction decoded;
	ZydisDecodedOperand operands[ZYDIS_MAX_OPERAND_COUNT];
	char text[LINE_TEXT] = "";

	if (ZYAN_SUCCESS(ZydisDecoderDecodeFull(&decoder, p->image + at, (ZyanUSize)line->size, &decoded, operands)))
		ZydisFormatterFormatInstruction(&formatter, &decoded, operands, decoded.operand_count_visible, text, sizeof text, (ZyanU64)(p->address + at), ZYAN_NULL);
	add_text(out, "%s", text);
}

static void add_line(const Program *p, Text *out, const Line *line)
{
	int at = image_offset(p, line);

	add_text(out, "  +%02x ", at);
	add_bytes(out, p->image + at, line->size, line->kind == LINE_INSTRUCTION ? ZYDIS_MAX_INSTRUCTION_LENGTH : LISTED_DATA);
	if (line->kind == LINE_INSTRUCTION)
		add_instruction(p, out, line, at);
	else
		add_text(out, "%.*s", line->text_length, p->text + line->text);
	add_slot_notes(p, out, (int)(line - p->lines));
	add_text(out, "\n");
}

static void add_jump_line(const Program *p, Text *out)
{
	BYTE original[2 * ZYDIS_MAX_INSTRUCTION_LENGTH];
	int copied, i;

	add_text(out, "  +%02x jump back", p->code_size);
	if (!p->site) {
		add_text(out, "\n");
		return;
	}
	copied = copied_length(p->site);
	if (copied > (int)sizeof original || !copy_original(p->site, original, (size_t)copied)) {
		add_text(out, " to 0x%llx\n", (UINT64)p->site);
		return;
	}
	add_text(out, ": original");
	for (i = 0; i < copied; i++)
		add_text(out, " %02X", original[i]);
	add_text(out, " then 0x%llx\n", (UINT64)(p->site + copied));
}

void write_listing(const Program *p, Text *out)
{
	int section, i;

	prepare_tools();
	for (section = SECTION_CODE; section <= SECTION_DATA; section++) {
		for (i = 0; i < p->line_count; i++) {
			if (p->lines[i].section == section && p->lines[i].size > 0)
				add_line(p, out, &p->lines[i]);
		}
		if (section == SECTION_CODE)
			add_jump_line(p, out);
	}
}

int disassemble_one(INT_PTR address, Text *out)
{
	BYTE code[ZYDIS_MAX_INSTRUCTION_LENGTH];
	ZydisDecodedInstruction decoded;
	ZydisDecodedOperand operands[ZYDIS_MAX_OPERAND_COUNT];
	char text[LINE_TEXT] = "";
	size_t readable = sizeof code;

	prepare_tools();
	while (readable > 0 && !copy_original(address, code, readable))
		readable--;
	add_text(out, "0x%llx  ", (UINT64)address);
	if (readable == 0) {
		add_text(out, "(cannot be read)");
		return 0;
	}
	if (!ZYAN_SUCCESS(ZydisDecoderDecodeFull(&decoder, code, readable, &decoded, operands))) {
		add_text(out, "%02X  (cannot be decoded)", code[0]);
		return 0;
	}
	ZydisFormatterFormatInstruction(&formatter, &decoded, operands, decoded.operand_count_visible, text, sizeof text, (ZyanU64)address, ZYAN_NULL);
	add_bytes(out, code, decoded.length, ZYDIS_MAX_INSTRUCTION_LENGTH);
	add_text(out, "%s", text);
	return decoded.length;
}
