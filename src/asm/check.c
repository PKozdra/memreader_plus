#include <fcntl.h>
#include <io.h>
#include <stdio.h>
#include <string.h>

#include "asm.h"

enum { CHECK_ADDRESS = 0x10000 };

static Program program;
static char text[ASM_MAX_TEXT + 1];
static BYTE moving[ASM_MAX_CAVE];

BOOL copy_original(INT_PTR address, BYTE *out, size_t size)
{
	(void)address;
	(void)out;
	(void)size;
	return FALSE;
}

int copied_length(INT_PTR target)
{
	(void)target;
	return 0;
}

void add_text(Text *out, const char *format, ...)
{
	(void)out;
	(void)format;
}

static void give_every_name_zero(Program *p)
{
	int i;

	for (i = 0; i < p->name_count; i++) {
		p->names[i].kind = GIVEN_NUMBER;
		p->names[i].number = 0;
	}
}

static BOOL check_text(Program *p)
{
	if (p->length > ASM_MAX_TEXT)
		return asm_fail(p, 1, 1, "the text is longer than %d bytes", ASM_MAX_TEXT);
	if (!parse_program(p))
		return FALSE;
	give_every_name_zero(p);
	return build_program(p);
}

static BOOL is_relative(const Operand *op)
{
	return op->kind == OPERAND_TARGET || (op->kind == OPERAND_MEMORY && op->reg == ZYDIS_REGISTER_RIP);
}

static BOOL moves(const Operand *op)
{
	return op->name >= 0 || (is_relative(op) ? op->label < 0 : op->label >= 0);
}

static void mark_moving(const Program *p)
{
	int i, j;

	for (i = 0; i < p->line_count; i++) {
		const Line *line = &p->lines[i];

		if (line->section != SECTION_CODE)
			continue;
		for (j = 0; j < line->count; j++) {
			if (line->kind == LINE_INSTRUCTION && moves(&line->operands[j]))
				memset(moving + line->offset, 1, (size_t)line->size);
			if (line->kind == LINE_DATA && moves(&p->values[line->first + j]))
				memset(moving + line->offset + j * line->unit, 1, line->unit);
		}
	}
}

static void print_code(const Program *p)
{
	int i;

	mark_moving(p);
	fputs("ok", stdout);
	for (i = 0; i < p->code_size; i++) {
		if (moving[i])
			fputs(" ??", stdout);
		else
			printf(" %02X", p->image[i]);
	}
	putchar('\n');
}

int main(void)
{
	size_t length;

	_setmode(_fileno(stdin), _O_BINARY);
	length = fread(text, 1, sizeof text, stdin);
	program.text = text;
	program.length = length;
	program.address = CHECK_ADDRESS;
	if (check_text(&program)) {
		print_code(&program);
		return 0;
	}
	printf("asm:%s\n", program.error);
	return 1;
}
