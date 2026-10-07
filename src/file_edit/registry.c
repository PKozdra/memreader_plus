#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "file_edit.h"

EditedFile **files;
LONG file_count;
static int file_capacity;
BOOL turned_off;
LONG result_count;
static SRWLOCK lock = SRWLOCK_INIT;

BOOL grow_array(void **items, int *capacity, int needed, size_t item_size)
{
	int bigger = *capacity ? *capacity : 4;
	void *grown;

	while (bigger < needed)
		bigger *= 2;
	if (bigger == *capacity)
		return TRUE;
	grown = realloc(*items, (size_t)bigger * item_size);
	if (!grown)
		return FALSE;
	memset((char *)grown + (size_t)*capacity * item_size, 0, (size_t)(bigger - *capacity) * item_size);
	*items = grown;
	*capacity = bigger;
	return TRUE;
}

void normal_path(const char *text, BOOL layout, char *out)
{
	size_t used = 0;

	for (; *text && used + 1 < PATH_SIZE; text++) {
		char c = *text == '/' ? '\\' : (char)tolower((unsigned char)*text);

		if (c == '\\' && (used == 0 || out[used - 1] == '\\'))
			continue;
		out[used++] = c;
	}
	out[used] = '\0';
	if (layout && !strchr(out, '.'))
		strncat_s(out, PATH_SIZE, ".twui.xml", _TRUNCATE);
}

void release_result(Result *result)
{
	if (result && InterlockedDecrement(&result->refs) == 0) {
		InterlockedDecrement(&result_count);
		free(result);
	}
}

Result *hold_result(EditedFile *file)
{
	Result *result;

	AcquireSRWLockShared(&lock);
	result = file->result;
	if (result)
		InterlockedIncrement(&result->refs);
	ReleaseSRWLockShared(&lock);
	return result;
}

static EditedFile *match_file(const void *contents, size_t size, const char *path)
{
	LONG i;

	for (i = 0; i < file_count; i++) {
		EditedFile *file = files[i];
		BOOL named_here = path[0] && strcmp(path, file->path) == 0;

		if (file->base && file->base_size == size && memcmp(file->base, contents, size) == 0) {
			if (!path[0] || named_here)
				return file;
			InterlockedIncrement(&file->vetoes);
		} else if (named_here) {
			InterlockedIncrement(&file->misses);
		}
	}
	return NULL;
}

static Result *use_once(EditedFile *file, Result *result)
{
	AcquireSRWLockExclusive(&lock);
	if (file->result == result) {
		file->result = file->after_once;
		file->after_once = NULL;
		file->used_once = TRUE;
	} else {
		result = NULL;
	}
	ReleaseSRWLockExclusive(&lock);
	return result;
}

BOOL take_edit(const void *contents, size_t size, const char *path, Taken *taken)
{
	EditedFile *file;
	Result *result = NULL;
	BOOL once;

	if (!file_count || turned_off)
		return FALSE;
	AcquireSRWLockShared(&lock);
	file = match_file(contents, size, path);
	if (file && !file->disabled)
		result = file->result;
	once = result && result->once;
	if (result && !once)
		InterlockedIncrement(&result->refs);
	ReleaseSRWLockShared(&lock);
	if (once)
		result = use_once(file, result);
	if (!result)
		return FALSE;
	InterlockedIncrement(&file->hits);
	taken->file = file;
	taken->result = result;
	return TRUE;
}

void give_back(Taken *taken, BOOL rejected)
{
	EditedFile *file = taken->file;
	Result *retired = NULL;

	if (rejected) {
		InterlockedIncrement(&file->rejected);
		AcquireSRWLockExclusive(&lock);
		if (file->result == taken->result) {
			retired = file->result;
			file->result = NULL;
		}
		ReleaseSRWLockExclusive(&lock);
	}
	release_result(retired);
	release_result(taken->result);
}

static int compare_patches(const void *left, const void *right)
{
	const Patch *a = *(const Patch *const *)left, *b = *(const Patch *const *)right;
	int order = strcmp(a->owner, b->owner);

	if (a->priority != b->priority)
		return a->priority < b->priority ? -1 : 1;
	return order ? order : strcmp(a->id, b->id);
}

static BOOL valid_text(const EditedFile *file, const char *text, size_t size, char *problem)
{
	int status = parse_status(text, size);

	if (status != 0) {
		sprintf_s(problem, PROBLEM_SIZE, "the edited file does not parse (status %d)", status);
		return FALSE;
	}
	if (count_duplicate_attributes(text, size) > file->base_duplicates) {
		strcpy_s(problem, PROBLEM_SIZE, "the edited file has an attribute twice in one tag");
		return FALSE;
	}
	return TRUE;
}

static char *checked_patch(const EditedFile *file, const char *text, size_t size, Patch *patch, BOOL validate, size_t *new_size)
{
	char *next = apply_patch(text, size, patch, new_size);

	if (next && validate && !valid_text(file, next, *new_size, patch->problem)) {
		free(next);
		next = NULL;
	}
	return next;
}

static char *build_text(EditedFile *file, const BOOL *used, int last, BOOL validate, size_t *size)
{
	char *text = NULL;
	int i;

	*size = file->base_size;
	for (i = 0; i <= last; i++) {
		char *next;

		if (!used[i])
			continue;
		next = checked_patch(file, text ? text : (const char *)file->base, *size, file->patches[i], validate, size);
		free(text);
		if (!next)
			return NULL;
		text = next;
	}
	return text;
}

static char *take_over(EditedFile *file, BOOL *used, int at, BOOL validate, size_t *size)
{
	int i;

	for (i = at - 1; i >= 0; i--) {
		char *text;

		if (!used[i])
			continue;
		used[i] = FALSE;
		text = build_text(file, used, at, validate, size);
		if (text) {
			sprintf_s(file->patches[i]->problem, PROBLEM_SIZE, "replaced by %s/%s, which runs later", file->patches[at]->owner,
				file->patches[at]->id);
			return text;
		}
		used[i] = TRUE;
	}
	return NULL;
}

static char *choose(EditedFile *file, BOOL *used, BOOL skip_once, BOOL validate, size_t *size)
{
	char *text = NULL;
	int i;

	*size = file->base_size;
	for (i = 0; i < file->patch_count; i++) {
		Patch *patch = file->patches[i];
		char reason[PROBLEM_SIZE];
		size_t next_size;
		char *next;

		used[i] = !skip_once || !patch->once;
		if (!used[i])
			continue;
		next = checked_patch(file, text ? text : (const char *)file->base, *size, patch, validate, &next_size);
		strcpy_s(reason, PROBLEM_SIZE, patch->problem);
		if (!next)
			next = take_over(file, used, i, validate, &next_size);
		if (!next) {
			strcpy_s(patch->problem, PROBLEM_SIZE, reason);
			used[i] = FALSE;
			continue;
		}
		free(text);
		text = next;
		*size = next_size;
	}
	return text;
}

static Result *new_result(const char *text, size_t size)
{
	Result *result = malloc(sizeof *result + size);

	if (!result)
		return NULL;
	InterlockedIncrement(&result_count);
	result->refs = 1;
	result->once = FALSE;
	result->size = size;
	result->bytes = (BYTE *)(result + 1);
	memcpy(result->bytes, text, size);
	return result;
}

static Result *build(EditedFile *file, BOOL skip_once)
{
	BOOL *used = calloc((size_t)file->patch_count + 1, sizeof *used);
	size_t size = 0;
	char *text;
	Result *result = NULL;
	char problem[PROBLEM_SIZE];
	int i;

	if (!used)
		return NULL;
	text = choose(file, used, skip_once, FALSE, &size);
	if (text && !valid_text(file, text, size, problem)) {
		free(text);
		text = choose(file, used, skip_once, TRUE, &size);
	}
	if (text)
		result = new_result(text, size);
	free(text);
	for (i = 0; i < file->patch_count; i++) {
		if (!skip_once)
			file->patches[i]->applied = used[i];
		if (result && used[i] && file->patches[i]->once)
			result->once = TRUE;
	}
	free(used);
	return result;
}

void publish(EditedFile *file)
{
	Result *result, *after_once = NULL, *old_result, *old_after_once;

	qsort(file->patches, (size_t)file->patch_count, sizeof file->patches[0], compare_patches);
	result = build(file, FALSE);
	if (result && result->once)
		after_once = build(file, TRUE);
	AcquireSRWLockExclusive(&lock);
	old_result = file->result;
	old_after_once = file->after_once;
	file->result = result;
	file->after_once = after_once;
	ReleaseSRWLockExclusive(&lock);
	release_result(old_result);
	release_result(old_after_once);
}

void forget_file(EditedFile *file)
{
	EditedFile old;

	AcquireSRWLockExclusive(&lock);
	old = *file;
	memset(file, 0, sizeof *file);
	ReleaseSRWLockExclusive(&lock);
	free(old.base);
	free(old.patches);
	release_result(old.result);
	release_result(old.after_once);
}

void drop_patch(EditedFile *file, int at)
{
	free_patch(file->patches[at]);
	file->patches[at] = file->patches[--file->patch_count];
}

void sweep(void)
{
	LONG i;
	int j;

	for (i = 0; i < file_count; i++) {
		EditedFile *file = files[i];

		if (!InterlockedExchange(&file->used_once, FALSE))
			continue;
		for (j = file->patch_count - 1; j >= 0; j--) {
			if (file->patches[j]->once)
				drop_patch(file, j);
		}
		if (file->patch_count)
			publish(file);
		else
			forget_file(file);
	}
}

EditedFile *find_file(const char *path)
{
	LONG i;

	for (i = 0; i < file_count; i++) {
		if (files[i]->base && strcmp(files[i]->path, path) == 0)
			return files[i];
	}
	return NULL;
}

static EditedFile *free_slot(lua_State *L)
{
	EditedFile *file;
	BOOL grown;
	LONG i;

	for (i = 0; i < file_count; i++) {
		if (!files[i]->base)
			return files[i];
	}
	if (file_count == MAX_EDITED_FILES)
		luaL_error(L, "file_edit: at most %d files can carry edits at once", MAX_EDITED_FILES);
	file = calloc(1, sizeof *file);
	AcquireSRWLockExclusive(&lock);
	grown = file && grow_array((void **)&files, &file_capacity, file_count + 1, sizeof *files);
	if (grown)
		files[file_count++] = file;
	ReleaseSRWLockExclusive(&lock);
	if (!grown) {
		free(file);
		luaL_error(L, "out of memory");
	}
	return file;
}

EditedFile *add_file(lua_State *L, int path_index, const char *path)
{
	EditedFile *file;
	const char *bytes;
	size_t size;
	BYTE *copy;

	push_game_file(L, path_index, open_file_site());
	bytes = lua_tolstring(L, -1, &size);
	if (!bytes || size < 2 || (BYTE)bytes[0] == 0xFF || (BYTE)bytes[0] == 0xFE)
		return NULL;
	file = free_slot(L);
	copy = malloc(size);
	if (!copy)
		luaL_error(L, "out of memory");
	memcpy(copy, bytes, size);
	strcpy_s(file->path, PATH_SIZE, path);
	file->base_size = size;
	file->base_duplicates = count_duplicate_attributes(bytes, size);
	AcquireSRWLockExclusive(&lock);
	file->base = copy;
	ReleaseSRWLockExclusive(&lock);
	return file;
}

const EditedFile *find_twin(const EditedFile *file)
{
	LONG i;

	for (i = 0; i < file_count; i++) {
		const EditedFile *other = files[i];

		if (other != file && other->base && other->base_size == file->base_size && memcmp(other->base, file->base, file->base_size) == 0)
			return other;
	}
	return NULL;
}

int find_patch(const EditedFile *file, const char *owner, const char *id)
{
	int i;

	for (i = 0; i < file->patch_count; i++) {
		if (strcmp(file->patches[i]->owner, owner) == 0 && strcmp(file->patches[i]->id, id) == 0)
			return i;
	}
	return -1;
}

BOOL put_patch(EditedFile *file, Patch *patch)
{
	int at = find_patch(file, patch->owner, patch->id);

	if (at >= 0)
		drop_patch(file, at);
	if (file->patch_count == MAX_PATCHES || !grow_array((void **)&file->patches, &file->patch_capacity, file->patch_count + 1, sizeof *file->patches)) {
		free_patch(patch);
		return FALSE;
	}
	file->patches[file->patch_count++] = patch;
	return TRUE;
}
