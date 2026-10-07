#pragma once

#include "../game/game.h"

enum { MAX_EDITED_FILES = 4096, MAX_PATCHES = 4096, MAX_OPS = 4096, MAX_ANCHORS = 32, MAX_COUNT = 100000, NAME_SIZE = 64, PATH_SIZE = 260, PROBLEM_SIZE = 200 };

typedef struct {
	char *after[MAX_ANCHORS];
	int after_count;
	char *before;
	char *find;
	char *with;
	char *insert;
	char *attribute;
	char *value;
	char *child;
	int count;
} Op;

typedef struct {
	char owner[NAME_SIZE];
	char id[NAME_SIZE];
	lua_Number priority;
	BOOL once;
	BOOL applied;
	int op_count;
	int op_capacity;
	Op *ops;
	char problem[PROBLEM_SIZE];
} Patch;

typedef struct {
	LONG refs;
	BOOL once;
	size_t size;
	BYTE *bytes;
} Result;

typedef struct {
	char path[PATH_SIZE];
	BYTE *base;
	size_t base_size;
	int base_duplicates;
	Result *result;
	Result *after_once;
	Patch **patches;
	int patch_count;
	int patch_capacity;
	BOOL disabled;
	LONG used_once;
	LONG hits;
	LONG rejected;
	LONG vetoes;
	LONG misses;
} EditedFile;

typedef struct {
	EditedFile *file;
	Result *result;
} Taken;

extern const luaL_Reg file_edit_functions[];

const char *find_text(const char *from, const char *end, const char *needle);
char *splice(const char *text, size_t size, size_t at, size_t removed, const char *insert, size_t length, size_t *new_size);
char *apply_patch(const char *text, size_t size, Patch *patch, size_t *new_size);
void free_patch(Patch *patch);

BOOL is_xml_name(const char *text);
char *set_attribute(const char *text, size_t size, const char *from, const Op *op, size_t *new_size, char *problem);
char *insert_in_child(const char *text, size_t size, const char *from, const Op *op, size_t *new_size, char *problem);
int count_duplicate_attributes(const char *text, size_t size);

const char *start_file_edits(void);
const char *file_edit_state(void);
INT_PTR open_file_site(void);
BOOL can_edit(const char *path);
int parse_status(const char *text, size_t size);
const char *evict_layout(const char *path);
void count_hand_offs(LONG *pugi, LONG *fast_xml);
void push_sites(lua_State *L);
void push_parts_off(lua_State *L);

extern EditedFile **files;
extern LONG file_count;
extern BOOL turned_off;
extern LONG result_count;

BOOL grow_array(void **items, int *capacity, int needed, size_t item_size);
void normal_path(const char *text, BOOL layout, char *out);
BOOL take_edit(const void *contents, size_t size, const char *path, Taken *taken);
void give_back(Taken *taken, BOOL rejected);
Result *hold_result(EditedFile *file);
void release_result(Result *result);
void publish(EditedFile *file);
void forget_file(EditedFile *file);
void drop_patch(EditedFile *file, int at);
void sweep(void);
EditedFile *find_file(const char *path);
EditedFile *add_file(lua_State *L, int path_index, const char *path);
const EditedFile *find_twin(const EditedFile *file);
int find_patch(const EditedFile *file, const char *owner, const char *id);
BOOL put_patch(EditedFile *file, Patch *patch);
