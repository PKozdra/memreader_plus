#include <string.h>

#include "common.h"

enum {
	MAX_USERS = 64,
	MAX_GENERATIONS = 64,
	MODE_SIZE = 24,
	SOURCE_SIZE = 64,
	MAX_WALK = 8,
	NO_USER = -1
};

typedef struct {
	char source[SOURCE_SIZE];
	UINT32 counts[USE_KINDS];
	UINT64 generations;
} User;

static const char *const use_words[USE_KINDS][2] = {
	{ "call", "calls" }, { "write", "writes" }, { "patch", "patches" },
	{ "cave", "caves" }, { "hook", "hooks" }, { "link", "links" }, { "row", "rows" }
};

static const char *const own_names[] = { "memreader_plus", "!memreader_plus", "memreader.lua" };
static const char *const own_folders[] = { "script/memreader_plus/", "script\\memreader_plus\\" };

static User users[MAX_USERS];
static int user_count;
static BOOL users_left_out;
static char generation_modes[MAX_GENERATIONS][MODE_SIZE];
static UINT32 generation;
static const void *last_function;
static int last_user = NO_USER;
static char pin_key;

void start_use_generation(void)
{
	generation++;
	generation_modes[generation % MAX_GENERATIONS][0] = '\0';
	last_function = NULL;
	last_user = NO_USER;
}

void set_use_mode(const char *mode)
{
	strncpy_s(generation_modes[generation % MAX_GENERATIONS], MODE_SIZE, mode, _TRUNCATE);
}

static const char *file_name(const char *source)
{
	const char *slash = strrchr(source, '/'), *backslash = strrchr(source, '\\');

	if (backslash > slash)
		slash = backslash;
	return slash ? slash + 1 : source;
}

static BOOL is_own_script(const char *source)
{
	const char *name = file_name(source);
	int i;

	for (i = 0; i < (int)(sizeof own_names / sizeof own_names[0]); i++) {
		if (strncmp(name, own_names[i], strlen(own_names[i])) == 0)
			return TRUE;
	}
	for (i = 0; i < (int)(sizeof own_folders / sizeof own_folders[0]); i++) {
		if (strstr(source, own_folders[i]))
			return TRUE;
	}
	return FALSE;
}

static int user_named(const char *source)
{
	int i;

	for (i = 0; i < user_count; i++) {
		if (strcmp(users[i].source, source) == 0)
			return i;
	}
	if (user_count == MAX_USERS) {
		users_left_out = TRUE;
		return NO_USER;
	}
	strncpy_s(users[user_count].source, SOURCE_SIZE, source, _TRUNCATE);
	return user_count++;
}

static int user_of_frame(lua_Debug *frame)
{
	frame->short_src[LUA_IDSIZE - 1] = '\0';
	if (strcmp(frame->what, "C") == 0 || is_own_script(frame->short_src))
		return NO_USER;
	return user_named(frame->short_src);
}

static int user_up_the_stack(lua_State *L)
{
	DebugRecord frame;
	int level, user;

	for (level = 2; level <= MAX_WALK && lua_getstack(L, level, &frame.fields); level++) {
		if (lua_getinfo(L, "S", &frame.fields) && (user = user_of_frame(&frame.fields)) != NO_USER)
			return user;
	}
	return NO_USER;
}

static void pin_function(lua_State *L)
{
	lua_pushlightuserdata(L, &pin_key);
	lua_pushvalue(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
}

static int remember_function(lua_State *L, const void *function, lua_Debug *frame)
{
	pin_function(L);
	if (!lua_getinfo(L, ">S", frame))
		return NO_USER;
	if (strcmp(frame->what, "C") == 0) {
		last_function = NULL;
		return user_up_the_stack(L);
	}
	last_function = function;
	last_user = user_of_frame(frame);
	return last_user;
}

static int calling_user(lua_State *L)
{
	DebugRecord frame;
	const void *function;

	if (!lua_checkstack(L, 3) || !lua_getstack(L, 1, &frame.fields) || !lua_getinfo(L, "f", &frame.fields))
		return NO_USER;
	function = lua_topointer(L, -1);
	if (function && function == last_function) {
		lua_pop(L, 1);
		return last_user;
	}
	return remember_function(L, function, &frame.fields);
}

void note_use(lua_State *L, int kind)
{
	int user = calling_user(L);

	if (user == NO_USER && kind >= USE_WRITE)
		user = user_up_the_stack(L);
	if (user == NO_USER)
		return;
	users[user].counts[kind]++;
	users[user].generations |= 1ull << (generation % MAX_GENERATIONS);
}

static const char *mode_of(UINT32 g)
{
	const char *mode = generation_modes[g % MAX_GENERATIONS];

	return mode[0] ? mode : "loading";
}

static BOOL used_in(const User *user, UINT32 g)
{
	return (user->generations >> (g % MAX_GENERATIONS)) & 1;
}

static BOOL mode_shown_before(const User *user, UINT32 first, UINT32 g)
{
	UINT32 earlier;

	for (earlier = first; earlier < g; earlier++) {
		if (used_in(user, earlier) && strcmp(mode_of(earlier), mode_of(g)) == 0)
			return TRUE;
	}
	return FALSE;
}

static void add_modes(Text *report, const User *user)
{
	UINT32 first = generation >= MAX_GENERATIONS ? generation - MAX_GENERATIONS + 1 : 0, g;
	int shown = 0;

	for (g = first; g <= generation; g++) {
		if (used_in(user, g) && !mode_shown_before(user, first, g))
			add_text(report, "%s%s", shown++ ? ", " : "", mode_of(g));
	}
}

static void add_user(Text *report, const User *user)
{
	const char *name = file_name(user->source), *separator = ": ";
	int kind;

	add_text(report, "  %.*s (%s, ", (int)strcspn(name, "."), name, user->source);
	add_modes(report, user);
	add_text(report, ")");
	for (kind = USE_KINDS - 1; kind >= 0; kind--) {
		if (!user->counts[kind])
			continue;
		add_text(report, "%s%u %s", separator, user->counts[kind], use_words[kind][user->counts[kind] != 1]);
		separator = ", ";
	}
	add_text(report, "\n");
}

void add_users(Text *report)
{
	int i, count = user_count;

	if (!count) {
		add_text(report, "Mods using memreader Plus this session: none\n");
		return;
	}
	add_text(report, "Mods using memreader Plus this session, by script:\n");
	for (i = 0; i < count; i++)
		add_user(report, &users[i]);
	if (users_left_out)
		add_text(report, "  ... more scripts not listed\n");
}
