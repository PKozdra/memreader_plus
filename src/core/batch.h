#pragma once

#include "common.h"

enum { MAX_BATCH_STEPS = 128, MAX_BATCH_WRITES = 2048, MAX_BATCH_SPANS = 4096, BATCH_BYTES = 64 * 1024 };

typedef struct {
	INT_PTR at;
	int size;
	int step;
	int offset;
	BOOL write;
} Write;

typedef struct {
	INT_PTR at;
	int size;
	int step;
} Span;

typedef struct {
	int kind;
	int item;
	int first;
	int count;
	char name[ITEM_NAME_SIZE];
} Step;

typedef struct {
	Step steps[MAX_BATCH_STEPS];
	Write writes[MAX_BATCH_WRITES];
	Span spans[MAX_BATCH_SPANS];
	Range guards[MAX_WHOLE_RANGES];
	char guard_names[MAX_WHOLE_RANGES][ITEM_NAME_SIZE];
	BOOL guard_frames[MAX_WHOLE_RANGES];
	int guard_count;
	BYTE old[BATCH_BYTES];
	BYTE wanted[BATCH_BYTES];
	int step_count;
	int write_count;
	int span_count;
	int bytes_used;
	int items;
	int claims;
	size_t pool;
	char why[TAG_SIZE + 64];
} Batch;

void batch_begin(Batch *batch, int kind, int item, const char *name);
const char *batch_span(Batch *batch, INT_PTR at, size_t size);
const char *batch_guard(Batch *batch, INT_PTR at);
const char *batch_write(Batch *batch, INT_PTR at, size_t size, const BYTE *old, const BYTE *wanted, BOOL write);

extern const char hooked_call[];

int l_batch(lua_State *L);
int patcher_owner(lua_State *L);
int run_step(lua_State *L, Batch *batch, const void *stack, int owner, int kind, const char *name, int first);
void commit_step(lua_State *L, const Batch *batch, int owner, const Step *step);
