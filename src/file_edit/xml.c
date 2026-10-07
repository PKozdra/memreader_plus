#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "file_edit.h"

typedef struct {
	const char *name;
	size_t name_length;
	const char *value;
	const char *value_end;
} Attribute;

typedef struct {
	const char *start;
	const char *name;
	size_t name_length;
	const char *attributes_end;
	const char *end;
	BOOL closing;
	BOOL empty;
} Tag;

static const struct {
	const char *open;
	const char *close;
} special_nodes[] = { { "<!--", "-->" }, { "<![CDATA[", "]]>" }, { "<?", "?>" }, { "<!", ">" } };

static BOOL is_space(char c)
{
	return c == ' ' || (c >= '\t' && c <= '\r');
}

static const char *skip_space(const char *at, const char *end)
{
	while (at < end && is_space(*at))
		at++;
	return at;
}

static BOOL ends_name(char c)
{
	return is_space(c) || c == '=' || c == '/' || c == '>';
}

static BOOL next_attribute(const char **cursor, const char *end, Attribute *attribute)
{
	const char *at = skip_space(*cursor, end);
	const char *close;

	if (at == *cursor || at >= end || ends_name(*at))
		return FALSE;
	attribute->name = at;
	while (at < end && !ends_name(*at))
		at++;
	attribute->name_length = (size_t)(at - attribute->name);
	at = skip_space(at, end);
	if (at >= end || *at != '=')
		return FALSE;
	at = skip_space(at + 1, end);
	if (at >= end || (*at != '"' && *at != '\''))
		return FALSE;
	close = memchr(at + 1, *at, (size_t)(end - at - 1));
	if (!close)
		return FALSE;
	attribute->value = at;
	attribute->value_end = close + 1;
	*cursor = close + 1;
	return TRUE;
}

static BOOL read_tag(const char *at, const char *end, Tag *tag)
{
	Attribute attribute;

	tag->start = at++;
	tag->closing = at < end && *at == '/';
	if (tag->closing)
		at++;
	tag->name = at;
	while (at < end && !is_space(*at) && *at != '/' && *at != '>')
		at++;
	tag->name_length = (size_t)(at - tag->name);
	tag->attributes_end = at;
	while (next_attribute(&at, end, &attribute))
		tag->attributes_end = at;
	at = skip_space(at, end);
	tag->empty = at + 1 < end && at[0] == '/' && at[1] == '>';
	if (tag->empty)
		at++;
	if (tag->name_length == 0 || at >= end || *at != '>')
		return FALSE;
	tag->end = at + 1;
	return TRUE;
}

static const char *after_special(const char *at, const char *end)
{
	size_t i;

	for (i = 0; i < sizeof special_nodes / sizeof special_nodes[0]; i++) {
		size_t length = strlen(special_nodes[i].open);
		const char *close;

		if ((size_t)(end - at) < length || memcmp(at, special_nodes[i].open, length) != 0)
			continue;
		close = find_text(at + length, end, special_nodes[i].close);
		return close ? close + strlen(special_nodes[i].close) : NULL;
	}
	return at;
}

static BOOL same_name(const char *name, size_t length, const char *wanted)
{
	return strlen(wanted) == length && memcmp(name, wanted, length) == 0;
}

static BOOL tag_at(const char *text, const char *end, const char *from, Tag *tag, char *problem)
{
	const char *start = from - 1;

	while (start > text && *start != '<')
		start--;
	if (*start == '<' && read_tag(start, end, tag) && !tag->closing && from < tag->end)
		return TRUE;
	strcpy_s(problem, PROBLEM_SIZE, "the last anchor does not end inside a start tag");
	return FALSE;
}

BOOL is_xml_name(const char *text)
{
	const char *c;

	if (!(*text == '_' || *text == ':' || (*text >= 'A' && *text <= 'Z') || (*text >= 'a' && *text <= 'z')))
		return FALSE;
	for (c = text; *c; c++) {
		if (!(strchr("_:.-", *c) || (*c >= '0' && *c <= '9') || (*c >= 'A' && *c <= 'Z') || (*c >= 'a' && *c <= 'z')))
			return FALSE;
	}
	return TRUE;
}

static const char *entity(char c)
{
	switch (c) {
	case '&':
		return "&amp;";
	case '<':
		return "&lt;";
	case '>':
		return "&gt;";
	case '"':
		return "&quot;";
	case '\t':
		return "&#9;";
	case '\n':
		return "&#10;";
	case '\r':
		return "&#13;";
	default:
		return NULL;
	}
}

static char *quoted(const char *name, const char *value, size_t *length)
{
	size_t size = name ? strlen(name) + 4 : 2;
	const char *c;
	char *out, *write;

	for (c = value; *c; c++)
		size += entity(*c) ? strlen(entity(*c)) : 1;
	out = malloc(size + 1);
	if (!out)
		return NULL;
	write = out;
	if (name)
		write += sprintf_s(write, size + 1, " %s=", name);
	*write++ = '"';
	for (c = value; *c; c++) {
		const char *replacement = entity(*c);

		if (replacement) {
			memcpy(write, replacement, strlen(replacement));
			write += strlen(replacement);
		} else {
			*write++ = *c;
		}
	}
	*write++ = '"';
	*length = size;
	return out;
}

char *set_attribute(const char *text, size_t size, const char *from, const Op *op, size_t *new_size, char *problem)
{
	Attribute attribute, found = { NULL, 0, NULL, NULL };
	const char *cursor;
	char *value, *result;
	size_t length;
	Tag tag;

	if (!tag_at(text, text + size, from, &tag, problem))
		return NULL;
	cursor = tag.name + tag.name_length;
	while (next_attribute(&cursor, tag.end, &attribute)) {
		if (!same_name(attribute.name, attribute.name_length, op->attribute))
			continue;
		if (found.name) {
			sprintf_s(problem, PROBLEM_SIZE, "the tag has the attribute %s twice", op->attribute);
			return NULL;
		}
		found = attribute;
	}
	value = quoted(found.name ? NULL : op->attribute, op->value, &length);
	if (!value)
		return NULL;
	if (found.name)
		result = splice(text, size, (size_t)(found.value - text), (size_t)(found.value_end - found.value), value, length, new_size);
	else
		result = splice(text, size, (size_t)(tag.attributes_end - text), 0, value, length, new_size);
	free(value);
	return result;
}

static int find_child(const char *at, const char *end, const char *name, Tag *child)
{
	int depth = 0;

	while ((at = memchr(at, '<', (size_t)(end - at))) != NULL) {
		const char *skipped = after_special(at, end);

		if (skipped != at) {
			if (!skipped)
				return -1;
			at = skipped;
			continue;
		}
		if (!read_tag(at, end, child))
			return -1;
		if (!child->closing && depth == 0 && same_name(child->name, child->name_length, name))
			return 1;
		if (child->closing && depth-- == 0)
			return 0;
		if (!child->closing && !child->empty)
			depth++;
		at = child->end;
	}
	return -1;
}

static char *wrapped_insert(const char *text, size_t size, const Tag *element, const Op *op, size_t *new_size)
{
	size_t length = strlen(op->insert) + 2 * strlen(op->child) + 5;
	char *insert = malloc(length + 1);
	char *result;

	if (!insert)
		return NULL;
	sprintf_s(insert, length + 1, "<%s>%s</%s>", op->child, op->insert, op->child);
	result = splice(text, size, (size_t)(element->end - text), 0, insert, length, new_size);
	free(insert);
	return result;
}

char *insert_in_child(const char *text, size_t size, const char *from, const Op *op, size_t *new_size, char *problem)
{
	Tag element, child;
	int found;

	if (!tag_at(text, text + size, from, &element, problem))
		return NULL;
	if (element.empty) {
		strcpy_s(problem, PROBLEM_SIZE, "the element has no body");
		return NULL;
	}
	found = find_child(element.end, text + size, op->child, &child);
	if (found < 0) {
		strcpy_s(problem, PROBLEM_SIZE, "the element's body does not parse");
		return NULL;
	}
	if (found == 0)
		return wrapped_insert(text, size, &element, op, new_size);
	if (child.empty) {
		sprintf_s(problem, PROBLEM_SIZE, "the child %s has no body", op->child);
		return NULL;
	}
	return splice(text, size, (size_t)(child.end - text), 0, op->insert, strlen(op->insert), new_size);
}

static int duplicates_in(const Tag *tag)
{
	const char *outer = tag->name + tag->name_length;
	Attribute first, second;
	int count = 0;

	while (next_attribute(&outer, tag->end, &first)) {
		const char *inner = outer;

		while (next_attribute(&inner, tag->end, &second)) {
			if (first.name_length == second.name_length && memcmp(first.name, second.name, first.name_length) == 0) {
				count++;
				break;
			}
		}
	}
	return count;
}

int count_duplicate_attributes(const char *text, size_t size)
{
	const char *at = text, *end = text + size;
	int count = 0;
	Tag tag;

	while ((at = memchr(at, '<', (size_t)(end - at))) != NULL) {
		const char *skipped = after_special(at, end);

		if (skipped != at) {
			if (!skipped)
				break;
			at = skipped;
		} else if (read_tag(at, end, &tag)) {
			count += duplicates_in(&tag);
			at = tag.end;
		} else {
			at++;
		}
	}
	return count;
}
