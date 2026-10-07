#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "file_edit.h"

const char *find_text(const char *from, const char *end, const char *needle)
{
	size_t length = strlen(needle);

	for (; from + length <= end; from++) {
		if (*from == *needle && memcmp(from, needle, length) == 0)
			return from;
	}
	return NULL;
}

static int count_in(const char *from, const char *end, const char *needle)
{
	int count = 0;

	while ((from = find_text(from, end, needle)) != NULL) {
		count++;
		from += strlen(needle);
	}
	return count;
}

static BOOL locate(const char *text, size_t size, const Op *op, const char **from, const char **end, char *problem)
{
	int i;

	*from = text;
	*end = text + size;
	for (i = 0; i < op->after_count; i++) {
		const char *anchor = find_text(*from, *end, op->after[i]);

		if (!anchor) {
			sprintf_s(problem, PROBLEM_SIZE, "anchor %d not found", i + 1);
			return FALSE;
		}
		*from = anchor + strlen(op->after[i]);
	}
	if (op->before && (*end = find_text(*from, *end, op->before)) == NULL) {
		sprintf_s(problem, PROBLEM_SIZE, "stop text not found");
		return FALSE;
	}
	return TRUE;
}

char *splice(const char *text, size_t size, size_t at, size_t removed, const char *insert, size_t length, size_t *new_size)
{
	char *result = malloc(size - removed + length);

	if (!result)
		return NULL;
	memcpy(result, text, at);
	memcpy(result + at, insert, length);
	memcpy(result + at + length, text + at + removed, size - at - removed);
	*new_size = size - removed + length;
	return result;
}

static char *replace_in(const char *text, size_t size, const char *from, const char *end, const Op *op, size_t *new_size)
{
	size_t find_length = strlen(op->find), with_length = strlen(op->with);
	char *result = malloc(size + (size_t)op->count * with_length);
	char *write = result;
	const char *read = text;
	const char *hit;

	if (!result)
		return NULL;
	while ((hit = find_text(from, end, op->find)) != NULL) {
		memcpy(write, read, (size_t)(hit - read));
		write += hit - read;
		memcpy(write, op->with, with_length);
		write += with_length;
		read = from = hit + find_length;
	}
	memcpy(write, read, (size_t)(text + size - read));
	*new_size = (size_t)(write - result) + (size_t)(text + size - read);
	return result;
}

static char *apply_op(const char *text, size_t size, const Op *op, size_t *new_size, char *problem)
{
	const char *from, *end;
	int found;

	if (!locate(text, size, op, &from, &end, problem))
		return NULL;
	if (op->attribute)
		return set_attribute(text, size, from, op, new_size, problem);
	if (op->child)
		return insert_in_child(text, size, from, op, new_size, problem);
	if (op->insert)
		return splice(text, size, (size_t)(from - text), 0, op->insert, strlen(op->insert), new_size);
	found = count_in(from, end, op->find);
	if (found != op->count) {
		sprintf_s(problem, PROBLEM_SIZE, "find text found %d times, expected %d", found, op->count);
		return NULL;
	}
	return replace_in(text, size, from, end, op, new_size);
}

char *apply_patch(const char *text, size_t size, Patch *patch, size_t *new_size)
{
	char reason[PROBLEM_SIZE] = "out of memory";
	char *current = NULL;
	int i;

	*new_size = size;
	for (i = 0; i < patch->op_count; i++) {
		char *next = apply_op(current ? current : text, *new_size, &patch->ops[i], new_size, reason);

		free(current);
		if (!next) {
			sprintf_s(patch->problem, PROBLEM_SIZE, "op %d: %s", i + 1, reason);
			return NULL;
		}
		current = next;
	}
	return current;
}

void free_patch(Patch *patch)
{
	int i, j;

	for (i = 0; i < patch->op_count; i++) {
		Op *op = &patch->ops[i];

		for (j = 0; j < op->after_count; j++)
			free(op->after[j]);
		free(op->before);
		free(op->find);
		free(op->with);
		free(op->insert);
		free(op->attribute);
		free(op->value);
		free(op->child);
	}
	free(patch->ops);
	free(patch);
}
