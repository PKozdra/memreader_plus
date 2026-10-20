#pragma once

#include "common.h"
#include <Zydis/Zydis.h>

enum {
	ASM_MAX_TEXT = 262144,
	ASM_MAX_LINES = 4096,
	ASM_MAX_VALUES = 4096,
	ASM_MAX_LABELS = 1024,
	ASM_MAX_NAMES = 256,
	ASM_MAX_SLOTS = 256,
	ASM_MAX_CAVE = 4096,
	ASM_NAME_SIZE = 48,
	ASM_ERROR_SIZE = 256,
	ASM_ROUNDS = 16,
	MAX_EXACT_NUMBER = 16777215
};

enum OperandKind { OPERAND_REGISTER = 1, OPERAND_MEMORY, OPERAND_IMMEDIATE, OPERAND_TARGET };
enum LineKind { LINE_INSTRUCTION, LINE_DATA, LINE_ALIGN };
enum Section { SECTION_CODE, SECTION_DATA };
enum GivenKind { GIVEN_NONE, GIVEN_NUMBER, GIVEN_BITS, GIVEN_RAW };
enum LabelTarget { LABEL_UNDEFINED = -3, LABEL_PENDING = -2, LABEL_END = -1 };

typedef struct {
	BYTE kind;
	BYTE size;
	BYTE width;
	BYTE slot_size;
	BYTE is_float;
	BYTE scale;
	ZydisRegister reg;
	ZydisRegister index;
	short label;
	short name;
	int column;
	INT64 number;
	double real;
} Operand;

typedef struct {
	BYTE kind;
	BYTE section;
	BYTE wide;
	BYTE unit;
	ZydisMnemonic mnemonic;
	ZydisInstructionAttributes prefixes;
	int count;
	int first;
	int line;
	int column;
	int text;
	int text_length;
	int offset;
	int size;
	Operand operands[ZYDIS_ENCODER_MAX_OPERANDS];
} Line;

typedef struct {
	char name[ASM_NAME_SIZE];
	int target;
	int section;
	int line;
	int column;
} Label;

typedef struct {
	char name[ASM_NAME_SIZE];
	int line;
	int column;
	BYTE kind;
	BYTE raw_size;
	BYTE raw[8];
	INT64 number;
} Name;

typedef struct {
	short name;
	BYTE size;
	BYTE given;
	int offset;
	int line;
} Slot;

typedef struct {
	const char *text;
	size_t length;
	INT_PTR address;
	INT_PTR site;
	BOOL wildcards;
	int line_count;
	int value_count;
	int label_count;
	int name_count;
	int slot_count;
	int code_size;
	int data_size;
	int total;
	char error[ASM_ERROR_SIZE];
	Line lines[ASM_MAX_LINES];
	Operand values[ASM_MAX_VALUES];
	Label labels[ASM_MAX_LABELS];
	Name names[ASM_MAX_NAMES];
	Slot slots[ASM_MAX_SLOTS];
	BYTE image[ASM_MAX_CAVE];
} Program;

extern const luaL_Reg asm_functions[];

BOOL asm_fail(Program *p, int line, int column, const char *format, ...);
BOOL parse_program(Program *p);
BOOL build_program(Program *p);
BOOL plain_slot_range(int size, INT64 *low, INT64 *high);
BOOL plain_slot_fits(lua_Number number, int size);
size_t listing_size(const Program *p);
void write_listing(const Program *p, Text *out);
void prepare_asm_tools(void);
int disassemble_one(INT_PTR address, Text *out);
CaveLine *make_line_map(const Program *p);
BOOL format_instruction(const BYTE *code, size_t size, ULONG_PTR address, char *out, size_t room);
BOOL is_branch(ZydisMnemonic mnemonic);
const char *assemble_cave(lua_State *L, int spec, INT_PTR site, INT_PTR address, BYTE *out, size_t room, AssembledCave *result);
