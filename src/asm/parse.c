#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "asm.h"

enum { WORD_SIZE = ASM_NAME_SIZE, MAX_ALIGN = 256 };

typedef struct {
	Program *p;
	const char *at;
	const char *end;
	const char *start;
	int line;
	int section;
	ZydisInstructionAttributes prefixes;
} Cursor;

static const struct {
	const char *word;
	int size;
} size_words[] = { { "byte", 1 }, { "word", 2 }, { "dword", 4 }, { "qword", 8 }, { "xmmword", 16 }, { "ymmword", 32 }, { "zmmword", 64 } };

static const struct {
	const char *word;
	int unit;
} data_words[] = { { "db", 1 }, { "dw", 2 }, { "dd", 4 }, { "dq", 8 } };

static const struct {
	const char *word;
	ZydisInstructionAttributes flag;
} prefix_words[] = { { "lock", ZYDIS_ATTRIB_HAS_LOCK }, { "rep", ZYDIS_ATTRIB_HAS_REP }, { "repe", ZYDIS_ATTRIB_HAS_REPE }, { "repz", ZYDIS_ATTRIB_HAS_REPE },
	{ "repne", ZYDIS_ATTRIB_HAS_REPNE }, { "repnz", ZYDIS_ATTRIB_HAS_REPNE } };

static const char *const aliases[][2] = { { "movabs", "mov" }, { "sal", "shl" } };

static const char *const conditions[][2] = { { "e", "z" }, { "ne", "nz" }, { "ae", "nb" }, { "nae", "b" }, { "c", "b" }, { "nc", "nb" }, { "a", "nbe" },
	{ "na", "be" }, { "g", "nle" }, { "ge", "nl" }, { "ng", "le" }, { "nge", "l" }, { "pe", "p" }, { "po", "np" } };

static const char *const condition_heads[] = { "j", "cmov", "set" };

static const double tens[] = { 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 };

static BOOL fail_with(Program *p, int line, int column, const char *format, va_list arguments)
{
	int used;

	if (p->error[0])
		return FALSE;
	used = _snprintf_s(p->error, sizeof p->error, _TRUNCATE, "%d:%d: ", line, column);
	_vsnprintf_s(p->error + used, sizeof p->error - used, _TRUNCATE, format, arguments);
	return FALSE;
}

BOOL asm_fail(Program *p, int line, int column, const char *format, ...)
{
	va_list arguments;

	va_start(arguments, format);
	fail_with(p, line, column, format, arguments);
	va_end(arguments);
	return FALSE;
}

static int column_of(const Cursor *c, const char *at)
{
	return (int)(at - c->start) + 1;
}

static BOOL fail_at(Cursor *c, const char *at, const char *format, ...)
{
	va_list arguments;

	va_start(arguments, format);
	fail_with(c->p, c->line, column_of(c, at), format, arguments);
	va_end(arguments);
	return FALSE;
}

static BOOL is_space(char ch)
{
	return ch == ' ' || ch == '\t' || ch == '\r';
}

static BOOL is_word_start(char ch)
{
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_' || ch == '.';
}

static BOOL is_word_char(char ch)
{
	return is_word_start(ch) || (ch >= '0' && ch <= '9');
}

static BOOL is_digit(char ch)
{
	return ch >= '0' && ch <= '9';
}

static void skip_spaces(Cursor *c)
{
	while (c->at < c->end && is_space(*c->at))
		c->at++;
}

static BOOL at_end(const Cursor *c)
{
	return c->at >= c->end || *c->at == ';' || (*c->at == '/' && c->at + 1 < c->end && c->at[1] == '/');
}

static char next_char(const Cursor *c)
{
	return c->at < c->end ? *c->at : '\0';
}

static BOOL read_word(Cursor *c, char *word, char *lower)
{
	const char *from = c->at;
	size_t length, i;

	while (c->at < c->end && is_word_char(*c->at))
		c->at++;
	length = (size_t)(c->at - from);
	if (length >= WORD_SIZE) {
		c->at = from;
		return fail_at(c, from, "a name is longer than 47 characters");
	}
	memcpy(word, from, length);
	word[length] = '\0';
	for (i = 0; i <= length; i++)
		lower[i] = word[i] >= 'A' && word[i] <= 'Z' ? word[i] + ('a' - 'A') : word[i];
	return TRUE;
}

static BOOL unexpected(Cursor *c)
{
	char text[2] = { next_char(c), '\0' };

	if (c->at >= c->end)
		return fail_at(c, c->at, "the line ends too early");
	if ((BYTE)text[0] < ' ' || (BYTE)text[0] > '~')
		return fail_at(c, c->at, "unexpected character");
	return fail_at(c, c->at, "unexpected '%s'", text);
}

static BOOL expect(Cursor *c, char wanted)
{
	skip_spaces(c);
	if (next_char(c) != wanted)
		return unexpected(c);
	c->at++;
	return TRUE;
}

static ZydisMnemonic exact_mnemonic(const char *word)
{
	int low = ZYDIS_MNEMONIC_INVALID + 1, high = ZYDIS_MNEMONIC_MAX_VALUE;

	while (low <= high) {
		int middle = (low + high) / 2;
		int order = strcmp(word, ZydisMnemonicGetString((ZydisMnemonic)middle));

		if (order == 0)
			return (ZydisMnemonic)middle;
		if (order < 0)
			high = middle - 1;
		else
			low = middle + 1;
	}
	return ZYDIS_MNEMONIC_INVALID;
}

static ZydisMnemonic condition_alias(const char *word)
{
	char spelled[WORD_SIZE];
	size_t h, i;

	for (h = 0; h < sizeof condition_heads / sizeof condition_heads[0]; h++) {
		size_t head = strlen(condition_heads[h]);

		if (strncmp(word, condition_heads[h], head) != 0)
			continue;
		for (i = 0; i < sizeof conditions / sizeof conditions[0]; i++) {
			if (strcmp(word + head, conditions[i][0]) == 0) {
				_snprintf_s(spelled, sizeof spelled, _TRUNCATE, "%s%s", condition_heads[h], conditions[i][1]);
				return exact_mnemonic(spelled);
			}
		}
	}
	return ZYDIS_MNEMONIC_INVALID;
}

static ZydisMnemonic find_mnemonic(const char *word)
{
	ZydisMnemonic found = exact_mnemonic(word);
	size_t i;

	for (i = 0; found == ZYDIS_MNEMONIC_INVALID && i < sizeof aliases / sizeof aliases[0]; i++) {
		if (strcmp(word, aliases[i][0]) == 0)
			found = exact_mnemonic(aliases[i][1]);
	}
	return found != ZYDIS_MNEMONIC_INVALID ? found : condition_alias(word);
}

static ZydisRegister find_register(const char *word)
{
	int r;

	for (r = ZYDIS_REGISTER_NONE + 1; r <= ZYDIS_REGISTER_MAX_VALUE; r++) {
		const char *name = ZydisRegisterGetString((ZydisRegister)r);

		if (name && strcmp(word, name) == 0)
			return (ZydisRegister)r;
	}
	return ZYDIS_REGISTER_NONE;
}

static int size_word(const char *word)
{
	size_t i;

	for (i = 0; i < sizeof size_words / sizeof size_words[0]; i++) {
		if (strcmp(word, size_words[i].word) == 0)
			return size_words[i].size;
	}
	return 0;
}

static int data_word(const char *word)
{
	size_t i;

	for (i = 0; i < sizeof data_words / sizeof data_words[0]; i++) {
		if (strcmp(word, data_words[i].word) == 0)
			return data_words[i].unit;
	}
	return 0;
}

static ZydisInstructionAttributes prefix_word(const char *word)
{
	size_t i;

	for (i = 0; i < sizeof prefix_words / sizeof prefix_words[0]; i++) {
		if (strcmp(word, prefix_words[i].word) == 0)
			return prefix_words[i].flag;
	}
	return 0;
}

BOOL is_branch(ZydisMnemonic mnemonic)
{
	const char *name = ZydisMnemonicGetString(mnemonic);

	return name[0] == 'j' || mnemonic == ZYDIS_MNEMONIC_CALL || mnemonic == ZYDIS_MNEMONIC_LOOP || mnemonic == ZYDIS_MNEMONIC_LOOPE ||
		mnemonic == ZYDIS_MNEMONIC_LOOPNE || mnemonic == ZYDIS_MNEMONIC_XBEGIN;
}

static int find_label(Program *p, const char *name)
{
	int i;

	for (i = 0; i < p->label_count; i++) {
		if (strcmp(p->labels[i].name, name) == 0)
			return i;
	}
	return -1;
}

static int add_label(Cursor *c, const char *name, const char *at)
{
	Program *p = c->p;
	Label *label;

	if (p->label_count == ASM_MAX_LABELS) {
		fail_at(c, at, "more than 1024 labels");
		return -1;
	}
	label = &p->labels[p->label_count];
	strcpy_s(label->name, sizeof label->name, name);
	label->target = LABEL_UNDEFINED;
	label->section = c->section;
	label->line = c->line;
	label->column = column_of(c, at);
	return p->label_count++;
}

static int use_label(Cursor *c, const char *name, const char *at)
{
	int found = find_label(c->p, name);

	return found >= 0 ? found : add_label(c, name, at);
}

static BOOL define_label(Cursor *c, const char *name, const char *lower, const char *at)
{
	int index = find_label(c->p, name);
	Label *label;

	if (find_register(lower) != ZYDIS_REGISTER_NONE)
		return fail_at(c, at, "label '%s' is a register name", name);
	if (index < 0)
		index = add_label(c, name, at);
	if (index < 0)
		return FALSE;
	label = &c->p->labels[index];
	if (label->target != LABEL_UNDEFINED)
		return fail_at(c, at, "label '%s' is defined twice", name);
	label->target = LABEL_PENDING;
	label->section = c->section;
	label->line = c->line;
	label->column = column_of(c, at);
	return TRUE;
}

static void bind_labels(Program *p, int section, int target)
{
	int i;

	for (i = 0; i < p->label_count; i++) {
		if (p->labels[i].target == LABEL_PENDING && p->labels[i].section == section)
			p->labels[i].target = target;
	}
}

static int use_name(Cursor *c, const char *name, const char *at)
{
	Program *p = c->p;
	Name *entry;
	int i;

	for (i = 0; i < p->name_count; i++) {
		if (strcmp(p->names[i].name, name) == 0)
			return i;
	}
	if (p->name_count == ASM_MAX_NAMES) {
		fail_at(c, at, "more than 256 different {names}");
		return -1;
	}
	entry = &p->names[p->name_count];
	memset(entry, 0, sizeof *entry);
	strcpy_s(entry->name, sizeof entry->name, name);
	entry->line = c->line;
	entry->column = column_of(c, at);
	return p->name_count++;
}

static BOOL parse_brace(Cursor *c, Operand *op)
{
	const char *open = c->at;
	char name[WORD_SIZE];
	size_t length = 0;

	c->at++;
	while (c->at < c->end && (is_word_char(*c->at) && *c->at != '.') && length < WORD_SIZE - 1)
		name[length++] = *c->at++;
	name[length] = '\0';
	if (length == 0)
		return fail_at(c, open, "a {name} needs a name of letters, digits or underscores");
	op->slot_size = 0;
	if (next_char(c) == ':') {
		char digit;

		c->at++;
		digit = next_char(c);
		if (digit != '1' && digit != '2' && digit != '4' && digit != '8')
			return fail_at(c, c->at, "a slot size is 1, 2, 4 or 8");
		op->slot_size = (BYTE)(digit - '0');
		c->at++;
	}
	if (next_char(c) != '}')
		return unexpected(c);
	c->at++;
	op->name = (short)use_name(c, name, open);
	return op->name >= 0;
}

static int hex_value(char ch)
{
	if (ch >= '0' && ch <= '9')
		return ch - '0';
	if (ch >= 'a' && ch <= 'f')
		return ch - 'a' + 10;
	if (ch >= 'A' && ch <= 'F')
		return ch - 'A' + 10;
	return -1;
}

static BOOL add_digit(UINT64 *value, int base, int digit)
{
	if (*value > (~0ULL - (UINT64)digit) / (UINT64)base)
		return FALSE;
	*value = *value * (UINT64)base + (UINT64)digit;
	return TRUE;
}

static BOOL parse_hex_number(Cursor *c, const char *from, int skip, UINT64 *value)
{
	const char *digits = from + skip;

	*value = 0;
	for (c->at = digits; c->at < c->end && hex_value(*c->at) >= 0; c->at++) {
		if (!add_digit(value, 16, hex_value(*c->at)))
			return fail_at(c, from, "the number is too large");
	}
	if (c->at == digits)
		return fail_at(c, from, "a hex number needs digits");
	return TRUE;
}

static BOOL parse_real(Cursor *c, const char *from, Operand *op)
{
	UINT64 mantissa = 0;
	int exponent = 0, digits = 0, power = 0, sign = 1;
	BOOL fraction = FALSE;

	for (c->at = from; c->at < c->end && (is_digit(*c->at) || (*c->at == '.' && !fraction)); c->at++) {
		if (*c->at == '.') {
			fraction = TRUE;
			continue;
		}
		if (mantissa == 0 && *c->at == '0') {
			exponent -= fraction;
			continue;
		}
		if (digits == 19 || !add_digit(&mantissa, 10, *c->at - '0'))
			return fail_at(c, from, "the number has too many digits");
		digits++;
		exponent -= fraction;
	}
	if (c->at < c->end && (*c->at == 'e' || *c->at == 'E')) {
		c->at++;
		if (c->at < c->end && (*c->at == '-' || *c->at == '+'))
			sign = *c->at++ == '-' ? -1 : 1;
		if (c->at >= c->end || !is_digit(*c->at))
			return fail_at(c, from, "the exponent needs digits");
		while (c->at < c->end && is_digit(*c->at) && power < 1000)
			power = power * 10 + (*c->at++ - '0');
		exponent += sign * power;
	}
	while (mantissa != 0 && mantissa % 10 == 0) {
		mantissa /= 10;
		exponent++;
	}
	if (mantissa >= (1ULL << 53) || exponent > 22 || exponent < -22)
		return fail_at(c, from, "the number has too many digits");
	op->real = exponent >= 0 ? (double)mantissa * tens[exponent] : (double)mantissa / tens[-exponent];
	op->is_float = 1;
	return TRUE;
}

static BOOL parse_decimal(Cursor *c, const char *from, UINT64 *value)
{
	*value = 0;
	for (c->at = from; c->at < c->end && is_digit(*c->at); c->at++) {
		if (!add_digit(value, 10, *c->at - '0'))
			return fail_at(c, from, "the number is too large");
	}
	return TRUE;
}

static BOOL parse_digits(Cursor *c, Operand *op, UINT64 *value)
{
	const char *from = c->at, *scan = c->at;

	*value = 0;
	if (from[0] == '0' && from + 1 < c->end && (from[1] == 'x' || from[1] == 'X'))
		return parse_hex_number(c, from, 2, value);
	while (scan < c->end && hex_value(*scan) >= 0)
		scan++;
	if (scan < c->end && (*scan == 'h' || *scan == 'H')) {
		if (!parse_hex_number(c, from, 0, value))
			return FALSE;
		c->at++;
		return TRUE;
	}
	for (scan = from; scan < c->end && is_digit(*scan); scan++)
		;
	if (scan < c->end && (*scan == '.' || *scan == 'e' || *scan == 'E'))
		return parse_real(c, from, op);
	return parse_decimal(c, from, value);
}

static BOOL parse_number(Cursor *c, Operand *op, UINT64 *value)
{
	if (!parse_digits(c, op, value))
		return FALSE;
	if (c->at < c->end && (is_word_char(*c->at) || *c->at == '.'))
		return unexpected(c);
	return TRUE;
}

static BOOL parse_value(Cursor *c, Operand *op)
{
	BOOL negative = FALSE;
	UINT64 number;

	op->kind = OPERAND_IMMEDIATE;
	if (next_char(c) == '{')
		return parse_brace(c, op);
	if (next_char(c) == '-') {
		negative = TRUE;
		c->at++;
	}
	if (!is_digit(next_char(c)))
		return unexpected(c);
	if (!parse_number(c, op, &number))
		return FALSE;
	if (op->is_float)
		op->real = negative ? -op->real : op->real;
	else
		op->number = negative ? -(INT64)number : (INT64)number;
	return TRUE;
}

static BOOL add_register_term(Cursor *c, Operand *op, ZydisRegister reg, int sign, const char *at)
{
	UINT64 scale = 1;
	BOOL scaled = FALSE;

	skip_spaces(c);
	if (sign < 0)
		return fail_at(c, at, "a register cannot be subtracted");
	if (next_char(c) == '*') {
		c->at++;
		skip_spaces(c);
		if (!is_digit(next_char(c)) || !parse_decimal(c, c->at, &scale) || (scale != 1 && scale != 2 && scale != 4 && scale != 8))
			return fail_at(c, at, "the scale must be 1, 2, 4 or 8");
		scaled = TRUE;
	}
	if (!scaled && !op->reg) {
		op->reg = reg;
		return TRUE;
	}
	if (op->index)
		return fail_at(c, at, "more than two registers in an address");
	op->index = reg;
	op->scale = (BYTE)scale;
	return TRUE;
}

static BOOL add_word_term(Cursor *c, Operand *op, int sign, const char *at)
{
	char word[WORD_SIZE], lower[WORD_SIZE];
	ZydisRegister reg;

	if (!read_word(c, word, lower))
		return FALSE;
	reg = find_register(lower);
	if (reg != ZYDIS_REGISTER_NONE)
		return add_register_term(c, op, reg, sign, at);
	if (op->label >= 0 || sign < 0)
		return fail_at(c, at, "unexpected '%s'", word);
	op->label = (short)use_label(c, word, at);
	return op->label >= 0;
}

static BOOL add_term(Cursor *c, Operand *op, int sign)
{
	const char *at = c->at;
	char ch = next_char(c);
	UINT64 number;

	if (ch == '{') {
		if (op->name >= 0 || sign < 0)
			return fail_at(c, at, "one {name} per address, added");
		return parse_brace(c, op);
	}
	if (is_digit(ch)) {
		if (!parse_number(c, op, &number))
			return FALSE;
		if (op->is_float)
			return fail_at(c, at, "an address cannot hold a float");
		op->number += sign * (INT64)number;
		return TRUE;
	}
	if (is_word_start(ch))
		return add_word_term(c, op, sign, at);
	return unexpected(c);
}

static BOOL parse_memory(Cursor *c, Operand *op, int size)
{
	const char *open = c->at;
	int sign = 1;

	op->kind = OPERAND_MEMORY;
	op->size = (BYTE)size;
	if (!expect(c, '['))
		return FALSE;
	for (;;) {
		skip_spaces(c);
		if (!add_term(c, op, sign))
			return FALSE;
		skip_spaces(c);
		if (next_char(c) == ']')
			break;
		if (next_char(c) != '+' && next_char(c) != '-')
			return unexpected(c);
		sign = *c->at++ == '-' ? -1 : 1;
	}
	c->at++;
	if (op->reg == ZYDIS_REGISTER_RIP && op->label < 0 && op->name < 0)
		return fail_at(c, open, "[rip + number] is not supported: use [rip + label] or [rip + {name}]");
	if (op->label >= 0 && (op->reg != ZYDIS_REGISTER_RIP || op->index))
		return fail_at(c, open, "a label in an address needs rip: [rip + label]");
	if (op->name >= 0 && op->reg == ZYDIS_REGISTER_RIP && op->slot_size)
		return fail_at(c, open, "[rip + {name}] takes a value, not a slot");
	if (op->slot_size && (op->number || op->label >= 0))
		return fail_at(c, open, "a slot is the whole displacement: no number next to it");
	return TRUE;
}

static BOOL parse_target(Cursor *c, Operand *op, int width)
{
	char word[WORD_SIZE], lower[WORD_SIZE];
	const char *at;

	skip_spaces(c);
	at = c->at;
	op->width = (BYTE)width;
	if (!is_word_start(next_char(c))) {
		if (!parse_value(c, op))
			return FALSE;
		op->kind = OPERAND_TARGET;
		return TRUE;
	}
	if (!read_word(c, word, lower))
		return FALSE;
	op->kind = OPERAND_TARGET;
	op->label = (short)use_label(c, word, at);
	return op->label >= 0;
}

static BOOL parse_word_operand(Cursor *c, Operand *op)
{
	char word[WORD_SIZE], lower[WORD_SIZE];
	const char *at = c->at;
	int size;

	if (!read_word(c, word, lower))
		return FALSE;
	size = size_word(lower);
	if (size) {
		skip_spaces(c);
		if (is_word_start(next_char(c))) {
			if (!read_word(c, word, lower))
				return FALSE;
			if (strcmp(lower, "ptr") != 0)
				return fail_at(c, at, "unexpected '%s'", word);
		}
		skip_spaces(c);
		return parse_memory(c, op, size);
	}
	if (strcmp(lower, "short") == 0 || strcmp(lower, "near") == 0)
		return parse_target(c, op, lower[0] == 's' ? 8 : 32);
	op->reg = find_register(lower);
	if (op->reg != ZYDIS_REGISTER_NONE) {
		op->kind = OPERAND_REGISTER;
		return TRUE;
	}
	op->kind = OPERAND_TARGET;
	op->label = (short)use_label(c, word, at);
	return op->label >= 0;
}

static BOOL parse_operand(Cursor *c, Operand *op)
{
	char ch;

	memset(op, 0, sizeof *op);
	op->label = -1;
	op->name = -1;
	skip_spaces(c);
	op->column = column_of(c, c->at);
	ch = next_char(c);
	if (ch == '[')
		return parse_memory(c, op, 0);
	if (ch == '{' || ch == '-' || is_digit(ch))
		return parse_value(c, op);
	if (is_word_start(ch))
		return parse_word_operand(c, op);
	return unexpected(c);
}

static Line *new_line(Cursor *c, int kind, const char *at)
{
	Program *p = c->p;
	Line *line;

	if (p->line_count == ASM_MAX_LINES) {
		fail_at(c, at, "more than 4096 statements");
		return NULL;
	}
	bind_labels(p, c->section, p->line_count);
	line = &p->lines[p->line_count++];
	memset(line, 0, sizeof *line);
	line->kind = (BYTE)kind;
	line->section = (BYTE)c->section;
	line->line = c->line;
	line->column = column_of(c, at);
	line->text = (int)(at - c->p->text);
	return line;
}

static void end_statement(Cursor *c, Line *line)
{
	const char *last = c->at;

	while (last > c->p->text + line->text && is_space(last[-1]))
		last--;
	line->text_length = (int)(last - (c->p->text + line->text));
}

static int float_width(const Operand *op)
{
	if (op->kind == OPERAND_REGISTER)
		return ZydisRegisterGetWidth(ZYDIS_MACHINE_MODE_LONG_64, op->reg);
	return op->kind == OPERAND_MEMORY ? op->size * 8 : 0;
}

static BOOL store_float(Cursor *c, Operand *op, int bits)
{
	float single;
	double whole = op->real;

	if (bits == 32) {
		single = (float)whole;
		op->number = 0;
		memcpy(&op->number, &single, sizeof single);
	} else if (bits == 64) {
		memcpy(&op->number, &whole, sizeof whole);
	} else {
		return asm_fail(c->p, c->line, op->column, "a float needs a 32-bit or 64-bit operand next to it");
	}
	op->is_float = 0;
	return TRUE;
}

static BOOL check_operand(Cursor *c, Line *line, Operand *op, BOOL branch)
{
	if (op->is_float)
		return store_float(c, op, line->count > 1 ? float_width(&line->operands[0]) : 0);
	if (branch && op->kind == OPERAND_IMMEDIATE) {
		if (op->slot_size)
			return asm_fail(c->p, c->line, op->column, "a jump target cannot be a slot");
		op->kind = OPERAND_TARGET;
	}
	if (op->kind == OPERAND_TARGET && !branch) {
		if (op->label >= 0 && !op->width)
			return asm_fail(c->p, c->line, op->column, "unknown register '%s'", c->p->labels[op->label].name);
		return asm_fail(c->p, c->line, op->column, "short and near go with jumps and calls");
	}
	if (op->kind == OPERAND_TARGET && op->slot_size)
		return asm_fail(c->p, c->line, op->column, "a jump target cannot be a slot");
	return TRUE;
}

static BOOL parse_operands(Cursor *c, Line *line)
{
	BOOL branch = is_branch(line->mnemonic);
	int i;

	skip_spaces(c);
	while (!at_end(c)) {
		if (line->count == ZYDIS_ENCODER_MAX_OPERANDS)
			return unexpected(c);
		if (!parse_operand(c, &line->operands[line->count]))
			return FALSE;
		line->count++;
		skip_spaces(c);
		if (at_end(c))
			break;
		if (next_char(c) != ',')
			return unexpected(c);
		c->at++;
		skip_spaces(c);
		if (at_end(c))
			return unexpected(c);
	}
	for (i = 0; i < line->count; i++) {
		if (!check_operand(c, line, &line->operands[i], branch))
			return FALSE;
	}
	return TRUE;
}

static BOOL parse_data_value(Cursor *c, Line *line)
{
	Program *p = c->p;
	Operand *op;

	if (p->value_count == ASM_MAX_VALUES)
		return fail_at(c, c->at, "more than 4096 data values");
	op = &p->values[p->value_count++];
	memset(op, 0, sizeof *op);
	op->label = -1;
	op->name = -1;
	op->column = column_of(c, c->at);
	if (!parse_value(c, op))
		return FALSE;
	line->count++;
	if (op->is_float)
		return store_float(c, op, line->unit == 4 ? 32 : line->unit == 8 ? 64 : 0);
	return TRUE;
}

static BOOL parse_data(Cursor *c, Line *line, int unit)
{
	line->unit = (BYTE)unit;
	line->first = c->p->value_count;
	for (;;) {
		skip_spaces(c);
		if (!parse_data_value(c, line))
			return FALSE;
		skip_spaces(c);
		if (at_end(c))
			return TRUE;
		if (next_char(c) != ',')
			return unexpected(c);
		c->at++;
	}
}

static BOOL parse_align(Cursor *c, Line *line)
{
	UINT64 amount = 0;
	Operand ignored;

	skip_spaces(c);
	memset(&ignored, 0, sizeof ignored);
	if (!is_digit(next_char(c)) || !parse_number(c, &ignored, &amount) || ignored.is_float || amount == 0 || amount > MAX_ALIGN || (amount & (amount - 1)))
		return asm_fail(c->p, c->line, line->column, "align takes a power of two up to 256");
	line->unit = 0;
	line->first = (int)amount;
	return TRUE;
}

static BOOL switch_section(Cursor *c, const char *at)
{
	if (c->section == SECTION_DATA)
		return fail_at(c, at, ".data is given twice");
	bind_labels(c->p, SECTION_CODE, LABEL_END);
	c->section = SECTION_DATA;
	return TRUE;
}

static BOOL parse_instruction(Cursor *c, const char *word, const char *lower, const char *at)
{
	ZydisInstructionAttributes prefixes = 0, flag;
	ZydisMnemonic mnemonic;
	char next[WORD_SIZE], next_lower[WORD_SIZE];
	Line *line;

	while ((flag = prefix_word(lower)) != 0) {
		prefixes |= flag;
		skip_spaces(c);
		at = c->at;
		if (!is_word_start(next_char(c)))
			return unexpected(c);
		if (!read_word(c, next, next_lower))
			return FALSE;
		word = next;
		lower = next_lower;
	}
	mnemonic = find_mnemonic(lower);
	if (mnemonic == ZYDIS_MNEMONIC_INVALID)
		return fail_at(c, at, "unknown mnemonic '%s'", word);
	line = new_line(c, LINE_INSTRUCTION, at);
	if (!line)
		return FALSE;
	line->mnemonic = mnemonic;
	line->prefixes = prefixes;
	if (!parse_operands(c, line))
		return FALSE;
	end_statement(c, line);
	return TRUE;
}

static BOOL parse_statement(Cursor *c, const char *word, const char *lower, const char *at)
{
	int unit = data_word(lower);
	Line *line;

	if (strcmp(lower, ".data") == 0) {
		if (!switch_section(c, at))
			return FALSE;
		skip_spaces(c);
		return at_end(c) ? TRUE : unexpected(c);
	}
	if (!unit && strcmp(lower, "align") != 0)
		return parse_instruction(c, word, lower, at);
	line = new_line(c, unit ? LINE_DATA : LINE_ALIGN, at);
	if (!line || !(unit ? parse_data(c, line, unit) : parse_align(c, line)))
		return FALSE;
	skip_spaces(c);
	if (!at_end(c))
		return unexpected(c);
	end_statement(c, line);
	return TRUE;
}

static BOOL parse_line(Cursor *c)
{
	char word[WORD_SIZE], lower[WORD_SIZE];
	const char *at;

	skip_spaces(c);
	if (at_end(c))
		return TRUE;
	at = c->at;
	if (!is_word_start(next_char(c)))
		return unexpected(c);
	if (!read_word(c, word, lower))
		return FALSE;
	if (next_char(c) == ':') {
		c->at++;
		if (!define_label(c, word, lower, at))
			return FALSE;
		skip_spaces(c);
		if (at_end(c))
			return TRUE;
		at = c->at;
		if (!is_word_start(next_char(c)))
			return unexpected(c);
		if (!read_word(c, word, lower))
			return FALSE;
		if (next_char(c) == ':')
			return unexpected(c);
	}
	return parse_statement(c, word, lower, at);
}

static BOOL check_labels(Program *p)
{
	int i;

	for (i = 0; i < p->label_count; i++) {
		Label *label = &p->labels[i];

		if (label->target == LABEL_UNDEFINED)
			return asm_fail(p, label->line, label->column, "label '%s' is not defined", label->name);
		if (label->target == LABEL_PENDING)
			label->target = LABEL_END;
	}
	return TRUE;
}

BOOL parse_program(Program *p)
{
	Cursor c;
	const char *line_end;

	memset(&c, 0, sizeof c);
	c.p = p;
	c.start = p->text;
	c.line = 1;
	for (;;) {
		line_end = memchr(c.start, '\n', (size_t)(p->text + p->length - c.start));
		c.at = c.start;
		c.end = line_end ? line_end : p->text + p->length;
		if (!parse_line(&c))
			return FALSE;
		skip_spaces(&c);
		if (c.at < c.end && !at_end(&c))
			return unexpected(&c);
		if (!line_end)
			break;
		c.start = line_end + 1;
		c.line++;
	}
	return check_labels(p);
}
