# memreader Plus (TWWH3)

memreader Plus is a Lua module that lets mod scripts for Total War: WARHAMMER III read and write the game's memory, call the game's own functions, and hook them to change what they do.

Based on [memreader by Cpecific](https://github.com/Cpecific/twwh2-memreader), who wrote the WH2 and the WH3 build. Cpecific's module was based on [squeek502/memreader](https://github.com/squeek502/memreader).

Only works on Windows x64.

Mods written for memreader will keep working when memreader Plus is installed: `_G.memreader` has the same functions, arguments and result types as memreader 1.2. However, where 1.2 gave a buggy result, or at least one that probably wasn't intended, memreader Plus gives the right one. A mod that relied on one of those bugs can behave differently. `_G.memreader_plus` is the same table as `_G.memreader`, and the new functions are in both.

## What changed from memreader 1.2 by Cpecific

### New

- `call` runs a function from the game's code with arguments you pass from Lua and gives you its return value. You can use it to look up a DB row or to hash a string the way the game does. See [Calling game functions](#calling-game-functions).

- `hook` makes your Lua callback run every time the game calls a given function. The callback can read or change the arguments, replace the return value, or skip the game's function completely. Several mods can hook the same function. See [Hooking game functions](#hooking-game-functions).

- `find_pattern` searches the game's code for a byte pattern and returns its address. A mod that finds its addresses this way keeps working after a game patch, as long as the bytes it searches for did not change. memreader Plus keeps each result for the game session, so a mod that searches again in the next game mode gets its addresses at once. `read_original` reads code as it was before a hook or patch changed it.

- When the game crashes while a script is running, memreader Plus writes a text file with the Lua call stack and the list of loaded mods.

- `game_alloc`, `patch`, `vector_insert` and `string_set` change game data in place: memory from the game's own heap, code patches that check the old bytes first, CA vectors that grow and shrink, and CA strings set to new text. `map_add_key` and `list_insert` add entries to the game's hash maps and lists. See [Changing game data](#changing-game-data).

- `read_pack_file` reads any file from the loaded packs, text or binary, the same way the game reads its own files. See [Reading files from packs](#reading-files-from-packs).

- `file_edit` changes the text of a game file, such as a UI layout, each time the game reads it. Several mods can edit the same vanilla file without shipping a copy of it. With `file_edit_list`, `file_edit_preview`, `file_edit_apply`, `file_edit_remove`, `file_edit_status` and `set_file_edits` you can look at the edits, try ops on a text, remove an edit and turn edits off. `memreader_plus.twui` writes the ops of a layout edit for you from component ids. See [Editing game files as they load](#editing-game-files-as-they-load).

- There are new read functions for `CA::UniString` text (`read_unistring`), for 64-bit integers and doubles, and for null checks (`is_null`). `read_struct`, `read_vector`, `read_list` and `read_chain` read a whole structure in one call.

### Fixes

- Reads of 1 KB or more no longer crash the game. `div`, `gt`, `lt` and `tonumber` treat `int8` to `int32` as signed. `add(pointer, -16)` subtracts 16. A typed value used as an offset is no longer ignored. `read_string` reads short CA strings (up to 14 characters, stored inline) correctly.

- Plain reads are several times faster. memreader Plus copies the memory directly, with a guard against bad addresses, instead of calling `ReadProcessMemory`: about 120 ns instead of about 800 ns for a `read_uint32` in game. A bad address still gives a Lua error.

Every difference, with before and after values, is in [Differences from memreader 1.2](#differences-from-memreader-12).

## Contents

- [Quick look](#quick-look)
- [Installation](#installation)
- [Before you start](#before-you-start)
- [Reading structures](#reading-structures)
- [Game structures](#game-structures)
- [Calling game functions](#calling-game-functions)
- [Hooking game functions](#hooking-game-functions)
- [Changing game data](#changing-game-data)
- [Reading files from packs](#reading-files-from-packs)
- [Editing game files as they load](#editing-game-files-as-they-load)
- [Understanding userdata](#understanding-userdata)
- [Crash reports](#crash-reports)
- [Both mods installed](#both-mods-installed)
- [API reference](#api-reference)
- [Differences from memreader 1.2](#differences-from-memreader-12)
- [Building from source](#building-from-source)
- [Credits and license](#credits-and-license)

## Quick look

```lua
local mr = assert(_G.memreader)
local ptr = mr.base -- the game's exe in memory: 0x0000000140000000
out(mr.tostring(ptr)) -- 0000000140000000
-- read the pointer at address (base + 0x03601F98)
ptr = mr.read_pointer(ptr, '\152\31\96\3') -- 0x03601F98 as 4 raw bytes (uint32)
-- if (ptr == NULL)
if mr.is_null(ptr) then return end
-- read the value at address (ptr + 0x14)
local luaNumber = mr.read_int32(ptr, 0x14)
-- Lua numbers in the game are 32-bit floats. Precision drops after 0x00FFFFFF (16,777,215).
local rawNumber = mr.read_int32(ptr, 0x14, true) -- returns an exact typed value (userdata)
assert(luaNumber == mr.tonumber(rawNumber)) -- conversion to a Lua number
-- !!! DO NOT USE BASIC LUA OPERATORS ON RETURNED userdata !!!
-- !!! USE THE LIBRARY FUNCTIONS INSTEAD                    !!!
rawNumber = mr.add(rawNumber, 0x0150) -- also: sub, mult, div

-- CA::String: text stored inline (up to 14 characters) or behind a pointer
local name = mr.read_string(ptr, 0x20) -- ex: Adam
-- a pointer to a CA::String
local name2 = mr.read_string(ptr, 0x30, true) -- ex: Adam
-- CA::UniString (wide characters), returned as UTF-8 text
local title = mr.read_unistring(ptr, 0x40) -- ex: Adam

-- CA vector: { UINT32 capacity; INT32 size; T *data; }
local size, pdata = mr.read_array(ptr, 0x50)
-- or read every element in one call: an array of numbers
local values = mr.read_vector(ptr, 0x50, { 0, 'int32' }, 4)

-- a script interface object gives you the address of the game object behind it
local character = cm:get_faction('wh_main_emp_empire'):faction_leader()
local chptr = mr.ud_topointer(character)
tostring(character) -- ex: CHARACTER_SCRIPT_INTERFACE (0000000049376488)
mr.tostring(chptr) -- ex: 0000000049376488

-- here's how you can call a function from the game's own code: its hash function (MurmurHash3, 32-bit)
-- it turns a text into a number, and the same text always gives the same number
-- the game uses that number to find entries in its string-key tables, such as the key map of a DB table, so this gives you the number it would look up:

-- 1. find the function by the bytes it starts with (they survive game patches that do not touch it)
local address, count = mr.find_pattern('48 89 5C 24 08 44 8B CA 8B DA 41 C1 E9 02 41 BA ED 5E 54 4A')
assert(count == 1)
-- 2. the function reads its text from memory, so put the text in a buffer of your own
local key = 'wh2_main_hef_bow_arrow'
local text = mr.alloc(#key + 1)
mr.write(text, 0, key)
-- 3. call it: a pointer to the text and its length go in, a 32-bit number comes out
local hash = mr.call(address, 'uint32(pointer, uint32)', text, #key)
out(mr.tostring(hash)) -- 1628994413 (0x61187B6D)

-- a hook runs your Lua function whenever the game calls one of its own functions
-- this one tells the game how many units an army may have (20)
-- armies above 20 units can crash the end turn unless other parts of the game are fixed too, so use this only to try hooks out
local unit_cap, found = mr.find_pattern('80 B9 ?? ?? ?? ?? ?? 73 ?? 48 8B 81 ?? ?? ?? ?? 48 8B 88 ?? ?? ?? ?? 48 8B 81 ?? ?? ?? ?? B9 ?? ?? ?? ?? 8B 80 ?? ?? ?? ?? 3B C1 0F 47 C1 C3 B8 ?? ?? ?? ?? C3')
assert(found == 1)
mr.hook(unit_cap, 'uint32(pointer)', function(faction)
	return 30 -- the game now allows 30 units in every army, player and AI
end)
local army = cm:get_faction('wh_main_emp_empire'):military_force_list():item_at(0)
out(army:unit_count_limit()) -- 30
mr.unhook(unit_cap) -- back to 20
```

The addresses and offsets above are examples. Real ones depend on the game build and the structure you read.

## Installation

### Players

Subscribe to memreader Plus on the Steam Workshop and enable it in the launcher. A mod that requires memreader also works with memreader Plus instead, and you can enable both together. memreader Plus loads `twwh3-memreader_plus.dll` from the folder of `Warhammer3.exe`. When the file is missing there, or differs from the copy in the pack, memreader Plus writes it first.

### Modders

List memreader Plus as a required item of your mod, and use the module from your script:

```lua
local mr = _G.memreader_plus
```

Read `_G.memreader_plus` inside a function or a listener, or from a script in `script/campaign/mod`. Do not read it at the top of a file in `script/_lib/mod`: those files load in alphabetical order, and yours may run before memreader Plus has loaded, when the global is still `nil`.

## Before you start

### Numbers lose precision above 16,777,216

Lua numbers in the game are 32-bit floats. `read_int32`, `read_uint32` and the other integer reads return a plain number unless the third argument is `true`, which returns an exact typed value instead. Pass `true` when the value can be large, such as an address, an ID, a hash or a `uint32` field. A constant you write in your script is also a Lua number and is rounded the same way: `0x2480833` becomes `0x2480834`, so `add(base, 0x2480833)` is one byte off. Write large constants as raw bytes (`'\51\8\72\2'`), add exact parts (`add(add(base, 0x2480000), 0x833)`), or find the address with `find_pattern`.

### Typed values have no operators

Pointers and typed integers are userdata without metatables. `+`, `-`, `<` and the other operators do not work on them. Use the library functions:

```lua
local ptr = base + 32 * idx -- does not work
local ptr = mr.add(base, 32 * idx) -- works
local diff = mr.sub(ptr, base)
```

`==` does work: the same type and value always give the same userdata, so `a == b` and `t[v]` work for pointers and typed integers. Values made by Cpecific's DLL are different objects even when they hold the same value. Compare them with `eq`. `cm:set_saved_value` cannot store userdata. To keep an integer in a saved game, store `mr.tostring(v)` and restore it with `mr.uint32(tonumber(text))`, which is exact when the value is below 16,777,216. Don't save a pointer: heap addresses change every run.

### Searching bytes you read

Use `string.find_lua(bytes, text, 1, true)`. CA replaced `string.find` with a UTF-8 version that searches for plain text only. Called with a fourth argument, it returns nothing and breaks CA's other Lua functions (UI included) until the game mode ends.

### Multiplayer

Reading memory never desyncs. Decisions based on pointer values, on the order of pointers, or on memory that only one player has (such as UI state) can desync. Change the game model only from data every client shares, and only with calls, hooks and writes that every client makes.

## Reading structures

These four functions read many fields in one call. You describe the memory layout with fields. A field is `{ offset, type }` and reads what `read_<type>(p, offset)` would read:

| Field | Result |
|---|---|
| `{ off, 'uint8' }` .. `{ off, 'int32' }` | number |
| `{ off, 'uint32', true }` | exact typed value, like `read_uint32(p, off, true)` |
| `{ off, 'int64' }`, `{ off, 'uint64' }` | exact typed value |
| `{ off, 'float' }`, `{ off, 'double' }`, `{ off, 'boolean' }` | number or boolean |
| `{ off, 'string' }`, `{ off, 'unistring' }` | text of a `CA::String` or `CA::UniString` |
| `{ off, 'address' }` | the pointer `p + off`; nothing is read |
| `{ off, 'pointer' }` | pointer, or `false` when NULL |
| `{ off, 'pointer', field }` | follows the pointer and reads `field` there; `false` when NULL |
| `{ off, 'struct', layout }` | a table; `layout` is `{ name = field, ... }` |
| `{ off, 'vector', field, stride }` | a CA vector at `off`: an array, `field` read in each element |
| `{ off, 'list', field }` | a CA list (also the node list of a CA hash map): `field` read in each node |

#### `read_struct(pointer, offset, layout): table`
Returns a table with one entry for each name in the layout.
#### `read_vector(pointer, offset, field, stride): table`
Returns an array of the vector's elements. `stride` is the size of one element, from 1 to 16,777,215.
#### `read_list(pointer, offset, field): table`
Returns an array in list order. `field` offsets count from the node: links at +0 and +8, the value from +0x10.

In these three functions `offset` can be `nil` (0), but you can't leave it out, because the layout or field is always the third argument.
#### `read_chain(pointer, off1, off2, ...): pointer | nil`
Does what `read_pointer(read_pointer(p, off1), off2) ...` does, but returns `nil` as soon as a pointer is NULL.

```lua
local mr = memreader_plus
local NODE = { key = { 0x00, 'pointer', { 0x08, 'pointer', { 0x08, 'string' } } }, points = { 0x10, 'uint8' } }
local tiers = mr.read_vector(details, 0x200, { 0, 'vector', { 0, 'struct', NODE }, 48 }, 16)
local xp = mr.read_vector(xp_table, 0, { 0, 'int32' }, 4)
local keys = mr.read_list(map, 0, { 0, 'struct', { key = { 0x10, 'string' }, row = { 0x20, 'uint32' } } })
local target = mr.read_chain(object, 0x10, 0x28)
```

- A NULL pointer comes back as `false`, so arrays have no gaps and a check like `if row.mount then` works.

- Each result has the type its field names, whatever bytes are in memory. Integers are numbers unless the field has `true`. `int64`, `uint64` and `address` fields always give typed values. A plain `pointer` field gives a typed pointer or `false`, and a `pointer` field with an inner field gives what the inner field reads.

- Offsets are whole numbers from 0 to 16,777,215, and strides from 1 to 16,777,215. `read_chain` refuses larger number offsets, because they have already lost precision. Pass a typed value instead.

- To keep a wrong layout from freezing or crashing the game, fields can nest at most 16 levels deep, and one call reads at most 131,072 vector or list elements and 131,072 structs. Going over a limit is an error.

- `read_list` checks each list as it reads it. Every node's back link must point to the previous node, and the number of nodes must match the list's size. If the list changes while it is being read, the call fails with an error.

- An error message names the field where the read failed, for example `tiers[3].nodes[12].key: failed to read memory`.

- A field costs about 0.3 µs in game. These functions are shorter to write and add the checks above, but they are not faster than reading the fields one by one.

## Game structures

Most of the memory you read is built from a few container types of the game. This section lists their layouts and where the game uses them, with offsets that can change in any game patch.

The names for the containers are `CA::String`, `CA::UniString`, `CA_STD::VECTOR`, `CA_STD::LIST` and `CA_STD::UNORDERED`. The rest of this README calls the last three CA vector, CA list and CA hash map.

### `CA::String`

```c
union CA_STRING {             // 16 bytes
    struct {                  // long text
        UINT32 length;        // +0x00
        UINT32 capacity;      // +0x04
        char  *data;          // +0x08
    };
    struct {                  // short text, up to 14 characters
        char text[15];        // +0x00 the characters and a terminating zero
        BYTE tag;             // +0x0F high nibble 8 marks this form, low nibble is the length
    };
};
```

Read it with `read_string` or the field type `string`. The game uses it for the name of a DB table (`DATABASE_TABLE` +0x58, a pointer to the string), the key of a region (`REGION` +0x78, a pointer) and the key of a unit record (`MAIN_UNIT_RECORD` +0x3E0, where the 16-byte string is part of the record and not behind a pointer).

### `CA::UniString`

```c
union CA_UNISTRING {          // 16 bytes
    struct {                  // long text
        UINT32   length;      // +0x00 in wide characters
        UINT32   capacity;    // +0x04
        wchar_t *data;        // +0x08
    };
    struct {                  // short text, up to 7 characters
        wchar_t text[7];      // +0x00 the characters
        BYTE tag;             // +0x0F as in CA::String
    };
};
```

Read it with `read_unistring` or the field type `unistring`. The game almost never stores one inline, so nearly every UniString you meet is on the heap. Localised text in DB records is a pointer to a UniString, for example the culture name (`CULTURE_RECORD` +0x28, "Kislev") and the on-screen name of a land unit (`UNIT_LAND_RECORD` +0x128, "Tomb Guard"). Before a campaign loads, the pointer at +0x128 can be NULL.

### `CA_STD::VECTOR` (CA vector)

```c
struct CA_STD_VECTOR {        // 16 bytes
    UINT32 capacity;          // +0x00
    INT32 size;               // +0x04
    T    *data;               // +0x08 the elements, one after another
};
```

Read it with `read_array`, `read_vector` or the field type `vector`. The game uses it for the rows of a DB table (`DATABASE_TABLE` +0x08), the factions of the world (`WORLD` +0xA0), the characters, regions and armies of a faction (`FACTION` +0xF20, +0xF38, +0xF60) and the units of an army (`MILITARY_FORCE` +0x6D0).

### `CA_STD::LIST` (CA list)

```c
struct CA_STD_LIST_NODE {
    CA_STD_LIST_NODE *prev;   // +0x00 NULL for the first node
    CA_STD_LIST_NODE *next;   // +0x08
    T                 value;  // +0x10
};

struct CA_STD_LIST {          // 0x18 bytes
    INT32             size;   // +0x00
    UINT32            pad;    // +0x04
    CA_STD_LIST_NODE *last;   // +0x08 the address of this field, list + 8, is the end marker
    CA_STD_LIST_NODE *first;  // +0x10
};
```

Read it with `read_list` or the field type `list`. You mostly meet lists as the node list inside a hash map.

### `CA_STD::UNORDERED` (CA hash map)

```c
struct CA_STD_UNORDERED {     // 0x30 bytes
    CA_STD_LIST   nodes;      // +0x00 every entry, grouped by bucket
    CA_STD_VECTOR buckets;    // +0x18 the first node of each bucket, one more entry than there are buckets
    float         max_load;   // +0x28
};                            // a node is a list node with the key at +0x10 and the value after it
```

A string key is hashed with MurmurHash3 (32-bit), and the bucket is the hash modulo the number of buckets. Read it with `read_list` on the map. That walks every node and does no lookup. The game uses it for the key map of a DB table (`DATABASE_TABLE` +0x28, key to row number) and for the faction by key in the world (`WORLD` +0xF0).

The game also has tree maps (`CA_STD::MAP`). memreader Plus has no reader for them.

The vector of factions in the world holds the faction pointers themselves. The vectors in a faction and in an army hold pointers to a link, and the game object is the first field of that link, so you read two pointers per element.

For a script interface object, `ud_topointer` returns the address of the interface, and the game object is the pointer at +0x10 in it. This holds for factions, characters, armies and the world. This example reads the character numbers (`command_queue_index`) of a faction:

```lua
local faction_i = cm:get_faction('wh3_dlc29_nag_host_of_nagash')
local faction = mr.read_pointer(mr.ud_topointer(faction_i), 0x10)
local cqis = mr.read_vector(faction, 0xf20, { 0, 'pointer', { 0, 'pointer', { 0x110, 'uint32' } } }, 8)
out(table.concat(cqis, ',')) -- ex: 1,2,1068
local nagash = cm:get_character_by_cqi(cqis[1])
out(nagash:character_subtype_key()) -- wh3_dlc29_nag_nagash
```

The list holds the same numbers, in the same order, as `faction_i:character_list()`. Only the first ones stay the same between campaigns; later numbers depend on how many characters the game created before them.

To read a DB table, find the game's list of tables, pick the table whose name (`read_string(table, 0x58, true)`) you want, then read its rows with `read_array(table, 0x08)` and its keys with `read_list(table, 0x28, ...)`. `find_projectiles` in `tests/ingame_smoke.lua` shows one way to find the `projectiles` table. The key of a record sits at a different place in each table, so take the keys from the key map. In the unmodded game, the `cultures` table has 28 rows and 28 keys.

## Calling game functions

`call(address, signature, ...)` calls the game's code at `address` and returns its result. The signature is written like a C prototype with the type names below:

```lua
local result = mr.call(address, 'double(int32, float, pointer)', 5, 0.5, p)
```

| In the signature | Pass | Result |
|---|---|---|
| `pointer` | a pointer, exactly 8 raw bytes, or `nil` for NULL | pointer |
| `uint8` .. `int32`, `int64`, `uint64` | a typed value, raw bytes, or a whole number from -16,777,215 to 16,777,215 that fits the type | typed value |
| `boolean` | `true` or `false` | boolean |
| `float`, `double` | a number | number |
| `void` | (result only) | nothing |

#### `call(address: pointer, signature: string, ...): result`
Calls the function. At most 16 arguments, and the count must match the signature. `address` must be in the code of `Warhammer3.exe`, or be the `original` that `hook_info` returns. Any other address is refused.
#### `alloc(size: float): pointer`
Returns a pointer to `size` zeroed bytes (16-byte aligned, 1 byte to 16 MiB), for a function's arguments or results. Fill it with `write`. There is no `free`: the memory lives until the next game mode switch, and all `alloc` blocks of one mode together hold at most 16 MiB. Allocate a buffer once and reuse it.

memreader Plus refuses an integer argument that it cannot pass on exactly. A plain number must be whole, below 16,777,216 and inside the type's range (`uint8` takes 0 to 255). Anything else is an error that names the argument. A hash written in the script, such as `0x61187b6d`, is already `0x61187b80` as a Lua number, and passing it on would call the game with a wrong value. Pass large values as typed values (`read_uint32(p, off, true)`, `add`) or as raw bytes (`'\109\123\24\97'`). Typed values and bytes are cut to the type like a C cast: a `uint32` of 300 passed as `uint8` gives 44. A string is read as raw bytes, not as digits: `'12'` is 12849.

Use the type names from the table, in lower case. Other type names are not accepted. Write `longlong` as `int64`, `ulonglong` as `uint64`, `int` and `uint` as `int32` and `uint32`, `short` and `ushort` as `int16` and `uint16`, `char` and `byte` as `int8` and `uint8`, `bool` as `boolean`, and every pointer (`char *`, `void *`, `Foo *`) as `pointer`.

Methods and structs follow the Microsoft x64 calling convention:

- `this` is the first `pointer` argument.

- Check the function's signature before you call a function that returns a class or struct. Many of them return it through a hidden buffer. The caller passes the buffer as an extra `pointer` argument, and the function returns that same pointer. Pass the buffer yourself (`alloc`) and use `pointer` as the result.

- A free function returns a plain struct of 1, 2, 4 or 8 bytes in RAX: write it as `uint8` .. `uint64` in the signature. Any other size, and any class with a constructor, destructor, base class or virtual functions, comes back through the hidden buffer, which is then the first argument. A method returns every class or struct through the hidden buffer, even a plain one of 8 bytes or less, and the buffer comes right after `this`.

- A struct passed by value goes in as `uint8` .. `uint64` holding its bytes when it is 1, 2, 4 or 8 bytes. Any other size goes in as a `pointer` to a copy, which the called function may change. A class with a destructor passed by value (a `CA::String` parameter without `&`) is destroyed by the called function.

- Varargs functions (`printf` style) take `double` for every floating-point value, never `float`.
- `__vectorcall` functions and SSE vector (`__m128`) arguments or results are not supported.

This example builds a `CA::String` in its long form in one reused buffer and uses it for a lookup:

```lua
local MAX_KEY_LENGTH = 255
local key_buffer

local function ca_string(text)
	assert(#text <= MAX_KEY_LENGTH, 'key too long')
	key_buffer = key_buffer or mr.alloc(16 + MAX_KEY_LENGTH + 1)
	mr.write(key_buffer, 16, text .. '\0')
	mr.write(key_buffer, 0, mr.uint32(#text))
	mr.write(key_buffer, 4, mr.uint32(#text))
	mr.write(key_buffer, 8, mr.add(key_buffer, 16))
	return key_buffer
end

local record_index, count = mr.find_pattern('48 89 5C 24 10 48 89 6C 24 18 56 57 41 56 48 83 EC 30 48 8D 71 28 4C 8B F2 8B 5E 1C 48 8B E9 83 EB 01')
assert(count == 1)
local row = mr.call(record_index, 'uint32(pointer, pointer)', projectiles_table, ca_string('wh2_main_hef_bow_arrow'))
```

`record_index` is the game's `DATABASE_TABLE::record_index(table, key)`. It returns the key's row number, or the table's row count when the key is not in the table. `projectiles_table` is the `DATABASE_TABLE` of `projectiles` (see [Game structures](#game-structures)).

### Rules for calls

- Find addresses with `find_pattern` and check that the count is 1. With a wrong address or a wrong signature, the game's code runs on wrong values.

- Lua owns the memory that `alloc` returns and frees it at the next mode switch. Give it only to functions that use it during the call (a key to look up, a buffer to fill). Never give it to a function that keeps it, frees it or reallocates it: a by-value `CA::String`, a string assigned into a game object, a container that takes ownership, a listener registration. The game would free Lua's memory, or keep a pointer that dangles after the mode switch. For anything the game keeps, build it with the game's own constructors.

- A crash inside the called function becomes a Lua error: `the called function crashed at <address> (...); the game may be unstable now`. This covers access violations, illegal instructions, the `int3` padding between functions, integer division by zero and similar CPU faults. The game's code stopped halfway, so a lock may still be held or an object may be half changed. Stop calling game functions, and let the player save and restart. C++ exceptions and stack overflows still crash the game.

- Call game functions only from Lua code that the game runs: your script, a listener or a hook callback. Game functions that wait for the loading thread, or take locks the script thread holds, can hang the game.

- Do not call inside a coroutine a game function that runs script events or calls back into Lua. A Lua error in such a callback leaves the coroutine unable to resume ("cannot resume non-suspended coroutine").

- A call that changes the game model desyncs multiplayer unless every client makes it.
- A call costs about 0.3 µs.
- `double` arguments and results carry Lua's float precision: 16777216 + 1 gives 16777216.
- Spaces and tabs between names in the signature are allowed. A trailing comma is an error.
- A call into the middle of an instruction can execute invalid code without raising a fault.

## Hooking game functions

`hook(address, signature, callback)` sends every call the game makes to the function at `address` through `callback`. The signature is the same as for `call`. The callback gets the arguments, converted like `call` results, and returns the result the game sees. `hook_next(address, ...)` runs the rest of the chain with the arguments you give it: the next callback below yours, or the original function when there is none.

This example hooks the game's hash function from the Quick look example and passes every call through unchanged. To change what the game gets, return a different value instead of `hash`.

```lua
local HASH = 'uint32(pointer, uint32)'
local murmur = mr.find_pattern('48 89 5C 24 08 44 8B CA 8B DA 41 C1 E9 02 41 BA ED 5E 54 4A')
mr.hook(murmur, HASH, function(data, length)
	local hash = mr.hook_next(murmur, data, length)
	return hash
end)
-- the game hashes strings very often, so remove the hook when you are done
mr.unhook(murmur)
```

A callback can run code before or after the original, change the arguments, replace the result, or skip the original. An integer result follows the rules for integer arguments of `call`: a typed value, raw bytes, or a whole number that fits the type.

Several mods can hook the same address. The newest callback runs first. Each callback calls `hook_next` to pass the call down, or returns its own result without it.

#### `hook(address: pointer, signature: string, callback: function)`
Adds `callback` on top of the address's chain. The first hook of an address also patches the game's code. An address takes at most 16 callbacks, all with the same signature. A different signature, or the same function twice, is an error.
#### `hook_next(address: pointer, ...): result`
Call it inside a callback of `address`. It runs the next callback down with these arguments, or the original function when yours is the last callback, and returns its result.
#### `unhook(address: pointer, [callback: function])`
Removes that callback. Without `callback` it removes all of them, and the game calls the original function directly again. A second argument that is not a function is an error. This catches `mr.unhook(mr.find_pattern(pattern))`, which passes the match count as a second argument and would otherwise remove nothing. A callback may unhook itself or others while it runs. A callback that is already running finishes, and an unhooked one below it does not run any more. Until the running call returns, unhooked callbacks keep their place among the 16, and `hook` refuses a different signature for the address.
#### `hook_info(address: pointer): table | nil`
`nil` if the address was never hooked, else `{ original, attached, callbacks, calls, other_thread_calls, error }`. `original` is the original function. Calling it with `call` skips every other callback. `calls` counts how often the hook fired on the script thread. `other_thread_calls` counts the calls from the game's other threads, which skip the callbacks and run the original function. Both are plain numbers, exact up to 16,777,216, and both start again from 0 when a new chain starts. `error` holds the message of the last callback that failed.

memreader Plus hooks four of the game's file reading functions itself once a mod calls `file_edit` (see [Editing game files as they load](#editing-game-files-as-they-load)). Your callbacks on those functions still work. They run first and see the file as it ships, and `hook_next` or `original` then goes through the file edits before the game's function.
#### `hook_depth(): float`
Returns the number of hook callbacks that are running (0 outside a callback).

### Rules for hooks

- The patch stays for the whole game session, but callbacks last only one game mode. At every mode switch (frontend, campaign, battle) the game closes Lua and every callback is detached. Until a script hooks the address again, the game's calls run the original function directly. Your script must hook again in each mode, just as it registers its listeners again. At most 1000 addresses can be hooked per session, and the file reading functions that `file_edit` hooks count toward them (up to four).

- The hook writes a 5-byte jump over the first instructions of the function. The jump stays after `unhook` and in later game modes. Reads of those bytes return the jump, so read operands there with `read_original`. `patch`, `relocate_field`, `write` and `grow_frame` refuse to change the first instructions of a hooked function, because the game now runs a copy of them.

- Call `hook` from your script's own code or a listener, never inside a coroutine. The callback runs on the same Lua thread as the `hook` call. While that thread is suspended, the game's calls skip the callback.

- Do not call the game's script functions inside a callback (`common.*`, `cm:*`, `ModLog`, interface methods). The hooked function often runs while another script function is still in progress. A callback that called `common.get_localised_string` crashed the campaign later, in a `context:character()`, probably because the second script function corrupted the state of the first. Inside a callback, read memory with memreader Plus and use Lua's own `string.*`, `math.*` and `table.*`. Store the values you need in a variable, and call the game's script functions later from a listener or a timer. A library that calls the game's functions can refuse to run inside a callback with `if mr.hook_depth() > 0 then`.

- Only calls on the script thread reach the callback. Calls from the game's other threads, and every call while no callback is attached, run the original function directly.

- A callback that raises an error is detached, and the call continues with the next callback down, or with the original function and the arguments the game passed. If the callback already passed the call down with `hook_next`, nothing below runs again and the game gets the result that `hook_next` returned. The message stays in `hook_info(address).error` until the chain is empty and a new `hook` call starts a new chain. Returning nothing where the signature has a result counts as an error.

- A crash in a callback crashes the game and, with crash reports on, writes a crash report. This also happens when the hooked function was reached through `call`. A `call` made inside the callback still turns a crash in the code it calls into a Lua error.

- Only the read-only code of `Warhammer3.exe` can be hooked. Other DLLs are refused, and so is the copy-protection region, because it is writable. The error is `refused: hook takes only read-only code in the game's exe`.

- Every hooked call on the script thread runs your Lua. A hook whose callback returns its own result costs about 0.4 µs per call. With `hook_next` down to the original it costs about 0.5 to 0.75 µs, and each further `hook_next` level adds about 0.3 to 0.4 µs. Hooking a function the game calls thousands of times per frame slows the game down. Check how often a hook fired with `hook_info(address).calls`.

- Do not hook Lua's own functions or the allocator Lua uses, because the callback itself runs Lua. Do not hook functions that raise Lua errors, such as script bindings: the error jumps past the hook and leaves it in a broken state. `__vectorcall` functions are not supported, because the hook does not save all the registers they use. MinHook refuses functions shorter than 5 bytes.

- A hook that changes the game model desyncs multiplayer unless every client has it.

## Changing game data

These functions change memory the game owns. The game frees what it owns with its own allocator, so a block it keeps must come from that allocator and not from `alloc`.

A function here that takes one address (`patch`, `grow_frame`, `game_free`, the `map_*` functions, and also `call`, `hook` and `function_start`) takes a pointer value or exactly 8 raw bytes. Any other string is an argument error. Functions that take a pointer and an offset, like the reads, accept the same arguments as the reads.

```lua
local mr = memreader_plus
local site = mr.find_pattern('B8 ?? 00 00 00 C3') -- check the count is 1 first
local old = mr.patch(site, '\184\1\0\0\0', '\184\2\0\0\0') -- mov eax, 1 becomes mov eax, 2
local entry = mr.vector_insert(owner, 0x40, 8, 3, mr.read(new_pointer, 0, 8)) -- new third element of a pointer vector
mr.string_set(row, 0x10, 'my_new_key')
```

#### `game_alloc(size: float): pointer`
Returns `size` zeroed bytes from the game's heap, 1 byte to 64 MiB. Free the block with `game_free`, unless the game keeps it and frees it later.
#### `game_free(pointer, [defer: boolean])`
Gives a `game_alloc` block, or any block the game allocated, back to the game's heap. With `defer = true` the block stays valid until the next mode switch, for memory another part of the game may still read.
#### `patch(address: pointer, expected: string, bytes: string): string | nil, string`
Writes `bytes` at `address` when the bytes there equal `expected`, and returns the old bytes. When `bytes` are already there, it writes nothing and returns them, so a script can run again after a mode switch. Memory that holds neither is left alone, and the result is `nil` and the bytes found there. Both strings must have the same length, 1 to 4096 bytes, and the address must be inside `Warhammer3.exe` but outside its headers and its import and export tables. Code and read-only pages are made writable for the write and get their old protection back afterwards.\
A site in the first instructions of a function that memreader Plus has hooked counts as holding other bytes, even when they equal `expected`: the result is `nil` and the bytes found there, and nothing is written. The game runs those instructions from the hook's copy, so a patch there would never run. Patch the function before anything hooks it.\
When your script patched a site before the hook and the site overlaps the hook's 5-byte jump, the hook wrote its jump over your bytes. A second call then gives `nil` and the jump bytes, while the game still runs your change from the hook's copy. A site that lies wholly after those 5 bytes, inside the copied instructions, still holds your bytes, and the call returns them as done.\
Each refused site also adds a line to `memreader_plus_refused.txt`, next to memreader Plus's DLL in the game folder, with the address and the script line that called `patch` or `relocate_field`. A refused `write` also adds a line to this file. The file starts empty in each game session. A line already in it is not written again, and once it holds 32 different lines nothing more is added.
#### `vector_reserve(pointer, offset, stride: float, capacity: float)`
Makes the CA vector at `pointer + offset` hold at least `capacity` elements of `stride` bytes without growing again.
#### `vector_insert(pointer, offset, stride: float, position: float, [bytes: string]): pointer`
Inserts one element at `position` (1 to size + 1, the same numbering as `read_vector`), moves the later ones up and returns the new element's address. `bytes` must be exactly `stride` bytes. Without `bytes` the element is zeroed.
#### `vector_erase(pointer, offset, stride: float, position: float, [count: float])`
Removes `count` elements (default 1) from `position` on and moves the later ones down. The freed slots at the end are zeroed.
#### `string_set(pointer, offset, text: string)`
#### `unistring_set(pointer, offset, text: string)`
Replaces the `CA::String` or `CA::UniString` at `pointer + offset` with `text`, built by the game's own string code, and frees the old text. `unistring_set` takes UTF-8 text and refuses text that is not valid UTF-8. Text with a zero byte, or a field that does not hold a CA string, is an error.
#### `relocate_field(sites: table): true | nil, float`
Applies a list of byte patches as one unit. Each site is a table `{address, expected, bytes}` with the same meaning as `patch`. Every site is checked first. When one holds neither its `expected` nor its `bytes`, nothing is written and the result is `nil` and that site's number. When all sites hold `expected` or are already patched, every unpatched one is written and the result is `true`. Each site has the limits of `patch`, and an error names the site by its number (`site 2: ...`). Use it to move a struct field or grow an array across several code sites, so a build the patches do not fit leaves the game untouched. A site in the first instructions of a hooked function gives `nil` and its number, the same way it does in `patch`.
#### `grow_frame(address: pointer, by: float): true | nil, string`
Makes the stack frame of the game function that holds `address` larger by `by` bytes, a multiple of 16 from 16 to 1 MiB (1,048,576). The new space sits between the function's locals and the registers it saves, so a local array in that function can hold more items. Every `rsp`-based slot above the old frame, the `sub rsp` and `add rsp` sizes, the frame-pointer set-up and the function's unwind info move with it, so exceptions and crash reports still walk through the function. When other functions share the same unwind info, the function gets a private copy in the free space after the exe's function table. A second call for the same function does nothing and returns `true`. When the function has a shape `grow_frame` cannot handle safely (a frame register in the unwind info, an 8-bit offset that would need a longer instruction, an exception handler on shared unwind info), nothing is written and the result is `nil` and the reason. A function that memreader Plus has hooked anywhere in its code, in this game mode or an earlier one, gives `nil` and `'the function is hooked'`, so grow the frame before anything hooks the function. A function that `grow_frame` grew before it was hooked still gives `true` on a later call. Call `commit_stack` first when the new frame is large.
#### `commit_stack([keep: float]): boolean`
Commits the current thread's stack down to `keep` bytes above its limit (default `0x3000`), so a larger stack frame installed by a patch does not hit an uncommitted page. The lowest committed page becomes the stack's guard page again, so a stack overflow on that thread is still reported as one. `keep` must be at least one page (4096 bytes). Returns whether the commit succeeded. A stack too small to keep `keep` bytes and one more page is an error.
#### `hop_slots(): float`
Returns how many 14-byte runs of `int3` padding in the exe are still free for far-reach stubs. A hook that falls back to far memory takes one. The game's exe has about 10,700 of them.
#### `map_find_key(map: pointer, key: string): pointer | nil`
Looks `key` up in the `CA_STD::UNORDERED` hash map at `map` and returns its node, or `nil`. The map must have `CA::String` keys, like the key map of a DB table (`DATABASE_TABLE` +0x28). The lookup hashes the key and walks one bucket, the same way the game does. Keys are compared byte for byte, so case matters. In all three `map_*` functions a key is at most 4096 bytes long and has no zero byte.
#### `map_add_key(map: pointer, key: string, index: float, [source: pointer]): pointer, boolean`
Adds `key` to a DB key map through the game's own insert function and returns the node and `true`. The new node maps the key to row `index` (0 to 16,777,215) and holds `source` at +0x28 (the pack the row came from, NULL when left out). If the key is already there, nothing changes, and the result is the existing node and `false`. The game grows the bucket array when the map gets too full. Use it only on DB key maps: the game's insert builds nodes of that shape (a key, a row number and a source pointer).
#### `map_remove_key(map: pointer, key: string): boolean`
Removes `key` from a map with `CA::String` keys and returns `true`, or `false` when the key is not there. The key text is freed at once, and the node at the next mode switch.
#### `list_insert(pointer, offset, position: float, bytes: string): pointer`
Inserts a node holding `bytes` (1 to 4096 bytes) into the `CA_STD::LIST` at `pointer + offset`, at `position` (1 to size + 1, the same numbering as `read_list`), and returns the new node. The node comes from the game's heap, with the value at +0x10.
#### `list_erase(pointer, offset, position: float, [count: float])`
Removes `count` nodes (default 1) from `position` on. Each node's memory is freed at the next mode switch. Anything the value points to, such as the text of a CA string in it, is not freed. Before it changes anything, `list_erase` checks the back links of the nodes before `position`, and refuses the list when one does not match. The nodes from `position` on are not checked.

### Rules for changing game data

- A vector that grows gets a new buffer from the game's heap. The old buffer goes back to the game's heap at the next mode switch, which keeps it valid for code that is still reading it. So grow only vectors whose data came from the game's heap: data the game allocated, or a `game_alloc` block. Pointers you or the game kept to elements of the old buffer still point into the old buffer.

- Insert and erase move elements by copying their bytes. That is safe for numbers, pointers and structs of plain values. Do not use them on vectors whose elements are pointed to from elsewhere, or that point into themselves.

- The stride is 1 to 4096 bytes. A vector whose size is above its capacity, or whose data pointer is NULL while it has elements, is refused with `not a CA vector`.

- Change a structure only while the game is not using it on another thread, for example from a listener on the script thread.

- Any of these changes desyncs multiplayer unless every client makes the same change at the same time.

- A key added to a DB key map exists only until the game exits. A save that refers to that key loads only when the key exists again before the load, so add keys in the frontend, before any campaign loads.

## Reading files from packs

```lua
local text = mr.read_pack_file('text/my_mod/config.json')
if text then
	-- text holds the whole file, byte for byte
end
```

#### `read_pack_file(path: string): string | nil`
Returns the whole content of the file at `path` in the loaded packs, or `nil` when no pack has it. When several packs have the same path, it returns the copy the game itself would load. DB tables come back as the game reads them, unpacked from the compressed data packs. Reading `db/land_units_tables/data__` (about 1.7 MB) takes about 1 ms. The first call in a session also searches the game's code for its file functions, which took about 40 ms.
#### `pack_file_exists(path: string): boolean`
Returns whether any loaded pack has a file at `path`.

Both functions take a path inside the packs, with `/` or `\` between folders, 1 to 1024 bytes long. A path with a drive letter or any other `:`, one that starts with `\\`, or one with a `..` part is an argument error. The game keeps every distinct path in its table of file names until it closes, and each new path costs a little memory for the rest of the session. Look up the files your mod needs and avoid generating thousands of names.

- Paths take `/` or `\`, upper or lower case, with or without a leading `/`.
- A path must be 1 to 1024 bytes without a zero byte. A file over 64 MiB is an error.
- The files come from the game's own file system, so this works in the frontend, in a campaign and in a battle. Call it from your script, not from inside a hook callback.

## Editing game files as they load

`file_edit` changes the text of a game file each time the game reads it, so your mod doesn't have to ship its own copy of a vanilla file. It works on UI layouts (`.twui.xml`, loading screens included) and on the XML the game reads for models and materials, such as `.wsmodel` and `.xml.material` files. Several mods can edit the same file, and each mod's edit still applies when another mod ships its own copy of that file, as long as the text it looks for is in that copy.

```lua
local ok, why = mr.file_edit({
	owner = 'my_mod', -- your mod's name, the same for all your edits
	id = 'wider_line', -- your name for this edit
	path = 'ui/frontend ui/fe_line_test.twui.xml',
	ops = {
		-- find width="400" after these two texts and before the next <image, exactly once
		{ after = { 'id="fe_line_test"', '<newstate' }, before = '<image', find = 'width="400"', with = 'width="650"' },
	},
})
if not ok then
	-- why says which op failed and how, e.g. 'op 1: find text found 0 times, expected 1'
end
```

The edit is made once, when you call `file_edit`, and the game gets the edited text on every later read of that file in the session, in every game mode. A layout the game already holds in its layout cache is dropped from the cache when you register the edit, so the next panel or component made from it uses the edited text. Components that already exist keep their old look until the game creates them again.

Templates in `ui/templates/` reach fewer layouts. Each layout in the cache carries its own copy of every template it uses, made when the game read the layout, so a template edit reaches only layouts the game reads after the edit. `file_edit` says so in its second result. On its first start the game reads its templates and its common layouts before any mod script runs, so in the main menu those layouts keep the old templates. When a campaign loads, the game reads the campaign's layouts after the `campaign/mod` scripts have loaded, so a template edit made in a declared file or when your campaign script loads reaches them.

#### `file_edit(edit: table): true | nil, string`
Registers an edit and returns `true`, or `nil` and the reason when it was skipped. A wrong field also gives `nil` and the reason, never an error, and so does a key that `file_edit` doesn't know, such as a misspelt `prioriy`. The fields of `edit`:

- `owner`, `id`: strings of up to 63 bytes. Together they name one edit across all files. Registering the same `owner` and `id` again replaces the earlier edit, also when the new one is on another file.
- `path`: the file inside the packs, with `/` or `\`, any case, up to 259 bytes. A path with a drive letter or a `..` part is refused.
- `ops`: a list of 1 to 4096 ops, without gaps. All of them apply, or none of them.
- `priority`: a number, default 0. Edits on one file run from the lowest priority to the highest, then by `owner` and `id`, and each one works on the text the earlier ones made.
- `once`: `true` makes the edit apply to the next read of the file only. Use it for edits you register again each time, such as a loading screen sized for the next battle.

Each op starts at the top of the file and looks for each text in `after` in order (a string or a list of up to 32 strings). Then it does one of four things:

- `find` and `with`: replaces `find` with `with` between the last `after` text and the next `before` text, or the end of the file without `before`. `with = ''` removes the text, and an op without `with` is refused. `find` must occur exactly `count` times there (a whole number from 1 to 100000, default 1), and every occurrence is replaced. `before` and `count` go only with `find`.
- `insert`: puts the text right after the last `after` text, or at the top of the file when the op has no `after`.
- `attribute` and `value`: sets an attribute of the XML tag that the last `after` text ends in, whatever its value is now, and adds the attribute when the tag doesn't have it. memreader Plus writes `&`, `<`, `>`, `"`, tabs and line breaks in `value` as character references, the way CA's files do. Other control characters are refused.
- `child` and `insert`: puts the text at the start of the first child element named `child` of the element whose tag the last `after` text ends in. When the element has no such child, memreader Plus adds one around the text. An element or child written as a single tag that closes itself, such as `<callbackwithcontextlist/>`, has no body to insert into, and the op is refused with `the element has no body` or `the child <name> has no body`.

The last two need `after`, and the last `after` text must end inside the tag, before its `>`. They work on the text as the earlier edits left it, so several mods can set the same attribute: the edit that runs later wins, and each edit keeps its other changes. Use them for anything another mod may also change. This op sets the width of one component:

```lua
{ after = { '<components>', 'this="DE199156-E9F2-443F-8E2AB30457AEE911"' }, attribute = 'width', value = '290' }
```

When a `find` op no longer finds its text because an earlier edit changed it, the edit that runs later wins as well. The earlier one is skipped with a reason like `replaced by other_mod/wide_panel, which runs later`, so a higher priority beats a lower one.

`file_edit` also checks that the edited file still reads as valid XML and that no tag has an attribute twice. An edit that breaks either is skipped with a reason like `the edited file does not parse (status 11)` or `the edited file has an attribute twice in one tag`, and the other edits on that file stay. If the game's UI reader ever rejects an edited layout, it reads the layout as it ships. The reader of models and materials has no such second try. If it rejects an edited file, that one read gets whatever the reader made of the text, probably a broken model, and the next read gets the file as it ships. Up to 4096 files can carry edits at a time, with up to 4096 edits each.

Only XML files can be edited. An edit to a script, a DB table or any other file that isn't XML fails the XML check and is skipped with `the edited file does not parse (status ...)`. A file saved as UTF-16, such as a `.loc` file, is refused with `no such file, or a UTF-16 file`, the same reason a path that no pack has gets.

`file_edit` returns a second result with `true` in three cases:

- A template edit gives `applies to layouts read from now on: ...`, as explained above.
- If memreader Plus can't find the game's function that clears the layout cache, every layout edit gives `applies from the next parse only: ...`. Layouts the game already holds then keep the old text, and only layouts it reads for the first time get the edit.
- A file with exactly the same bytes as another registered file gives `same bytes as <path>: ...`. A loading screen, or another reader that doesn't name the file it reads, gets the edits of the file registered first.

A reason that starts with `off:` means memreader Plus can't make this edit now, so give your mod a fallback for it:

- `off: switched off by the player`: the player turned file edits off.
- `off: fast_xml`: after a game patch memreader Plus can't edit or check model and material files. Layout edits still work.
- `off: load_buffer not found` and the like: memreader Plus can't find the game's file reader after a patch. Every file loads as it ships.

memreader Plus writes one line in `lua_mod_log.txt` for each skipped edit, once per game mode. That includes an edit of another mod that a new edit replaced, so both mods' authors see it. It also writes one line for each game function it can't find.

#### `file_edit_remove(owner: string, id: string): boolean`
Removes the edit, and the next read of the file gets the text without it. Returns `false` when there was no such edit.
#### `file_edit_list([path: string]): table`
One entry per edited file, or only the entry of `path`: `path`, `size`, `edited_size`, `disabled`, `hits` (reads that got the edited text), `rejected` (reads where the game's reader refused the edited text), `vetoes` (reads of a file with the same bytes under another path, which got no edits), `misses` (reads of this path whose bytes differ from the ones registered) and `patches`, a list of strings like `my_mod/wider_line applied` or `my_mod/wider_line skipped: <reason>`.
#### `file_edit_preview(path: string): string | nil, string`
Returns the edited text and the original text of a file you registered edits on, or nothing for other files.
#### `file_edit_apply(text: string, ops: table): string | nil, string`
Runs `ops` on `text` and returns the edited text, or `nil` and the reason. It checks the ops the same way `file_edit` does and registers nothing. It doesn't check that the result is still valid XML.
#### `file_edit_status(): table`
`state` (`on`, `not started` before the first `file_edit`, or `off: <reason>`), `enabled` (the player's switch), `files`, `results` (edited texts held in memory), `pugi_calls` and `fast_xml_calls` (how many times the game's layout reader and its model and material reader have read a file since the first `file_edit`), `off`, a list of the parts that don't work on this game build (`fast_xml`, `validation`, `path_check`, `eviction`), and `sites`, with `true` for each game function that was found or the reason it wasn't.
#### `set_file_edits(enabled: boolean, [path: string]): true | nil, string`
Without `path`, turns every file edit on or off for the session. While they are off, `file_edit` returns `nil, 'off: switched off by the player'` and keeps nothing, and edits registered earlier wait until they are turned on again. The edits that were refused come back only when their mods register them again, which most mods do at the next load. With MCT installed, players do the same with the option **File edits from mods** on memreader Plus's MCT page, which is ticked by default. memreader Plus remembers an unticked option in `memreader_plus_file_edits_off.txt` in the game's user data folder (`%APPDATA%\The Creative Assembly\Warhammer3\` unless the game was started with another one) and reads it as soon as it loads, so edits stay off even for files the game reads before MCT loads its settings. When the path of that folder has letters outside ASCII, the file goes into the game folder instead. Without MCT the file is ignored. memreader Plus also ignores it when another mod loads memreader Plus from a `_lib/mod` script that runs before MCT's own, and then edits stay on until MCT sends its settings. With `path`, turns off the edits of that one file. The files load as they ship from their next read, and layouts in the cache are dropped so the change shows the next time the game creates them.

### Editing layouts by component

`memreader_plus.twui` writes the ops for you from component ids, so your layout edit doesn't depend on how the file is formatted. When your script calls `twui.edit`, memreader Plus reads the layout the game will load (the vanilla file or another mod's copy), finds each component, checks the values you expect and registers one `file_edit` whose ops set attributes by the GUID of each element.

```lua
local twui = memreader_plus.twui
local ok, why = twui.edit({
	owner = 'my_mod',
	id = 'small_cards',
	path = 'ui/loading_ui/battle.twui.xml',
	once = true,
	changes = {
		-- every state of unit_card_parent gets width 290, only if its width is 250 now
		{ set = 'unit_card_parent', on = 'state', values = { width = 290 }, expect = { width = 250 } },
		{ set = 'unit_card_small', on = 'image', values = { width = 22, height = 49 } },
		{ hide = 'battle/docker/radar_frame' },
	},
})
```

#### `twui.edit(edit: table): true | nil, string`
Takes the fields of `file_edit` (`owner`, `id`, `path`, `priority`, `once`) with `changes` in place of `ops`, and returns what `file_edit` returns. All changes of one call apply, or none of them. A key it doesn't know, a bad path or a missing file gives `nil` and the reason. A `set` registers even when the file already has the value, so it still wins over an earlier mod's edit of that attribute.
#### `twui.preview(edit: table, [text: string]): string, table | nil, string`
Returns the edited text and the list of ops that `twui.edit` would register, and registers nothing. `edit.path` is needed even when you pass `text`, which is then edited instead of the file. It also takes an edit with `ops` in place of `changes`. The ops run through `file_edit_apply` on the copy of the file the game would load, so the text shows what your ops do to that copy on their own. It leaves out the edits of other mods, the order that `priority` sets and the XML check, so an edit that previews well can still be skipped or replaced when you register it.

Each change names one component with a selector:

- An id path such as `'radar_frame/frame'`. The last id is the component. Each id before it names one of its ancestors, in that order, at any depth. One id is enough when only one component in the layout has it. The ids are the names in the layout's `<hierarchy>` block, which writes each component's `id` in lower case with `_` for other characters. Both spellings work, so `kill_ratio_PH` and `kill_ratio_ph` name the same component.
- A GUID such as `'DE199156-E9F2-443F-8E2AB30457AEE911'`, the component's `this` value.

A selector that matches no component, or more than one, makes the call return `nil` and a reason like `change 2, hide frame: matches 3 components, expected 1`, and memreader Plus writes that line in `lua_mod_log.txt`.

The changes:

- `{ set = selector, values = { name = value }, on = ..., where = { ... }, expect = { ... } }` sets attributes. `on` picks the elements that get them: `'component'` (the default, the component's own element), `'state'` (each of its states), `'image'` (the image sizes in each state), `'text'` (the text settings in each state, such as `font_m_size`, `textxoffset` and `texthalign`), `'component_image'` (its list of images, where `imagepath` is) or `'engine'` (its `LayoutEngine`). `where` keeps only the elements whose attributes have these values, for example `where = { name = 'active' }` for one state. With `expect`, the call is refused unless every chosen element has these values now. An attribute the element doesn't have is added. Values are text or whole numbers below 10000000. memreader Plus escapes `&`, `<`, `>`, `"`, tabs and line breaks in them, so write context expressions as plain text.
- `{ hide = selector, expect = { ... } }` sets `visible="false"` on the component.
- `{ add_callback = selector, values = { callback_id = 'ContextListEngineItemsPerRowSetter', ... } }` adds a `callback_with_context` with these attributes to the component, and gives the component a callback list when it has none.

A change with a key it doesn't take, such as `exepct`, is refused. To swap a template, `set` the component's `template_id`. Adding new components isn't supported.

Several mods can change the same layout. When two of them `set` the same attribute of one element, the edit that runs later wins (higher priority, then `owner` and `id`), and both keep their other changes. Callbacks that two mods add to one component end up in one callback list. `expect` and `where` check the file as it ships, before any mod's edits.

The game ignores states, images, texts and engines written on a component that is part of a template (`part_of_template="true"`), so `set` with any `on` other than `'component'` returns `nil` and the reason there. Edit the template file in `ui/templates/` instead. A template edit reaches only layouts the game reads after your call, as with `file_edit`.

`twui.edit` works out the ops from the file that wins in the packs at the time of the call. After a game patch, an edit still applies when CA only moved or reformatted the component. When the id is gone, or a value in `expect` changed, the edit is skipped with a reason. The module reads layouts written the way CA writes them. A `>` inside a value, single quotes and comments are fine, but a component's `this="..."` must have no spaces around the `=`.

### Edits declared in a file

Edits that never change can go in `script/memreader_plus/file_edits/<your mod>.lua` in your pack. The file returns a list of edits without `owner`, and memreader Plus registers them right after it loads in each game mode, with the file name as the owner:

```lua
return {
	{ id = 'wider_line', path = 'ui/frontend ui/fe_line_test.twui.xml', ops = { { find = 'width="400"', with = 'width="650"', after = 'id="fe_line_test"' } } },
}
```

An entry with `changes` in place of `ops` is registered through `twui.edit`. The file runs with no access to the game or to Lua's libraries, so it can only build the table. A file that fails to load, or an entry that isn't a valid edit, is skipped with one line in `lua_mod_log.txt` naming the file, and the other files and entries still register.

Name the file after your mod, for example after your pack. When two packs have a file at the same path, the game loads only one of them, and memreader Plus can't tell that the other existed. Leave commas out of the name, since the game lists the files to memreader Plus separated by commas.

### When an edit reaches the game

- An edit reaches every read after your call. Register campaign and battle layout edits in a declared file or when your `campaign/mod` script loads. A `_lib/mod` file can run before memreader Plus has loaded (see [Modders](#modders)), so register them there inside a function or a listener. Register loading screen edits before the loading screen starts: from the campaign for the battle's loading screen, from the battle script for the one after the battle.
- The first time the game reaches the main menu, it reads the main menu layouts before any mod script runs. Edits to those layouts show from the second visit to the main menu in a session.
- A model or material the game already loaded and keeps in memory probably stays as it was until the game loads it again.
- File edits are local to each player's game. UI layouts, models and materials only change what is drawn on your screen, so editing them probably doesn't desync multiplayer.

## Understanding userdata

Userdata is a block of bytes that C code allocates and Lua can hold. A script interface such as a character is userdata:

```lua
local function get_chptr(character) return mr.read_pointer(mr.ud_topointer(character), 0x10) end
```

`get_chptr` reads at offset `0x10` because the game's character object is stored there, as explained below. CA's `tostring` prints the type of the userdata and the address of the interface object:

```lua
tostring(character)                    'CHARACTER_SCRIPT_INTERFACE (0000000049376488)' -- CA's userdata
mr.tostring(mr.ud_topointer(character)) '0000000049376488' -- the CHARACTER_SCRIPT_INTERFACE object
mr.tostring(get_chptr(character))       '00000000496D8E70' -- the game's character object
```

In WH3 a script interface userdata holds 8 bytes: the address of the `*_SCRIPT_INTERFACE` object, which `ud_topointer` returns. The game object the interface stands for is stored inside that object. Cpecific's Skill Queue reads the character at `+0x10`. For other interfaces, check the offset yourself: open the address in a memory viewer (ReClass.NET, Cheat Engine), compare several objects of the same type, and look for the heap pointer.

The same game object always gives the same userdata while it exists, so `==` works on script interfaces. Heap addresses change every run and every game mode: never keep a pointer from one mode in the next.

## Crash reports

When the game crashes, memreader Plus writes `memreader_crash_report_DDMMYY_HHMM.txt` next to `Warhammer3.exe`. It writes the report from inside the game's own crash handler, so a crash on any thread gets one, and a fault the game recovers from writes nothing. The report is plain text, usually 8 to 50 KB, small enough for pastebin. If a game patch moves the crash handler so that memreader Plus can't find it, memreader Plus writes the report as soon as a fatal fault (access violation, illegal instruction, integer division by zero, stack overflow) happens on the script thread, and the report says so and why.

The first lines give the time, the exception and where it happened, as `Warhammer3.exe+offset` with the start of the function around it. A C++ exception also gives its type, and an access violation gives the address that was read or written. Then the report says which thread crashed, how long the game had been running, and how much memory the game used and the PC had left.

The Lua stack comes next, innermost first, with the source file, line and function of each frame and the string, number and boolean locals of the first 12 frames. A C function's frame shows its address in the exe, which tells you which game binding the script was calling. An event handler's `eventname` is one of the locals. If the stack says `no Lua function was running`, the fault is in the game's own code. For a crash on another thread, memreader Plus pauses the script thread for a moment and shows where it was.

For the crashing thread, the report shows up to 32 frames of the native call stack, each with its function, then the registers and the bytes of code around the crash. A register that points somewhere gets a short note: an address in a module, the stack, an object and its vtable, or the start of a text. When a register points into a DLL of another program, the note says `another program's DLL` and leaves out the DLL's name. A register that holds text where an address should be shows the text, such as `not readable, text "a to"`. Frames found by searching the stack for return addresses, after the function tables run out, are marked `(stack scan)` and can be wrong.

When the crash is inside the game's memory allocator, a line under the stack says that memory was damaged earlier and the code on the stack only found it. Something else wrote over the game's memory before the crash, so the function names on that stack don't point to the cause. When a register holds a bad value that sits in memory next to another register, the report shows the 128 bytes around that spot, as bytes and as text. The text often names what wrote over the memory, for example a mod's text. If that text holds a file path or your Windows user name, the report leaves the bytes out.

After that the report lists what mods did through memreader Plus. Hooks come first, the ones running when the game crashed at the top, each with the file and line of its callbacks. Then every piece of game code patched in this session, and the last 24 memory writes, newest first. Each patch and write names the script line that made it, and repeated patches or writes from one line are counted in one entry with their address range.

Near the end, the report gives the number of DLLs that other programs loaded into the game, such as overlays and antivirus, from outside the Windows folder and the game folder, and how many of them are well-known overlays, drivers and antivirus. It doesn't name them, because people post these reports in public and the names would show what else runs on their PC. A DLL's name appears only where the DLL is part of the crash: as the module the fault happened in, or in a frame of the native or Lua stack. It also appears when the DLL changes how the game measures time, as speed hacks and trainers do: the report names the DLL and each timing function it hooks, such as `QueryPerformanceCounter`. After the count come the game version, the command line and the crash folder. It lists every mod in load order with its file size, date, Workshop id and folder. Last, it names the game's own crash files for the same crash (`.mdmp` and `.stack.txt`).

A short `Game context` block says what was going on: the mode (frontend, campaign or battle), the phase (main menu, loading a campaign, campaign, loading a battle, battle, or quitting after the player clicked Quit) and, in a campaign, the campaign, campaign type, whether it is multiplayer, difficulty, turn number, your faction, the human factions and the faction whose turn it is. In a battle it adds the battle type. A small script in memreader Plus's pack fills these in at safe moments, because the Lua state may be broken when the game crashes. In a campaign it runs on the first tick, at every new turn and at the start of every faction's turn, and in a battle when the battle scripts load. A turn number is the turn of the last update, so a crash in the middle of a round shows that round.

A `Recent script events` block lists the last 32 different events the game sent to scripts, newest first, with how often each one came and how long before the crash it came last. The same script records them by wrapping `core:event_callback`, which adds about 0.06 to 0.34 µs to each event. When another mod replaces `core:event_callback` later, the script wraps the new one once the game has created its interface, at the first tick of a campaign and when a battle starts.

Paths under your user profile show as `%USERPROFILE%`, and the folder of the Steam library the game is installed in shows as `<Steam library>`, whichever kind of slash the path uses. memreader Plus doesn't write your computer name, Steam account or IP address into the report.

The time stamp in the report's file name is the same as in the name of the script log of that Lua state (`script_log_DDMMYY_HHMM.txt`), so you can find the log that belongs to a report. If script logging is off, the time stamp is the time the game started.

Crash reports are on by default. With MCT installed, memreader Plus's MCT page has the option **Enable better crash reporting**. To change the setting from Lua, call:

#### `set_crash_reports(enabled: boolean): boolean`
Turns crash reports on or off and returns the previous setting.

#### `set_crash_context(name: string, value?: string)`
Adds or changes one line of the report's `Game context` block. Without a value, the line is removed. A name is cut at 23 characters and a value at 159, new lines become spaces, and there is room for 12 lines. Your mod can use it to put its own state in the report.

#### `note_crash_event(name: string)`
Adds `name` to the report's `Recent script events` block, the way memreader Plus's own script records each game event. Your mod can use it to mark its own steps, for example right before it changes game data. A name is cut at 47 characters, and a value that is not a string is ignored.

## Both mods installed

Players will often have memreader and memreader Plus enabled together. Both mods ship a loader at the same path, `script/_lib/mod/memreader.lua`. The game runs the `_lib/mod` files in alphabetical order, and that loader runs before `memreader_plus.lua`. Of the two copies, the game uses the one from the pack whose `mod` line comes first in the mod list. Mod managers usually write that list in alphabetical order by pack name, which puts `memreader_plus.pack` before Cpecific's `twwh3-memreader.pack`. That order is only a default, and the player can change it.

1. If memreader Plus is listed first, its `memreader.lua` loads memreader Plus, and Cpecific's loader never runs.
2. If Cpecific's memreader is listed first, Cpecific's loader loads Cpecific's DLL and sets `_G.memreader`. Then `memreader_plus.lua` loads memreader Plus, which replaces `_G.memreader`. Cpecific's DLL stays loaded but is not used.

memreader Plus replaces Cpecific's memreader in both cases, and every mod that uses `_G.memreader` ends up using memreader Plus. This holds for any script that reads `_G.memreader` after the `_lib/mod` files have loaded, for example a script in `script/campaign/mod`. If Cpecific's memreader is listed first, a `_lib/mod` file that sorts before `memreader_plus.lua` can still see Cpecific's version. If memreader Plus cannot write its DLL (two game instances running different versions lock the file), it logs `cannot write ...` and does not load, and `_G.memreader` stays Cpecific's.

## API reference

`typeA:typeB` means that you pass a `typeA` value and the library casts it to `typeB`.\
`argName: type` names an argument.

| Name in this reference | What it is |
|---|---|
| `float` | a Lua number (a 32-bit float in the game) |
| `string` | a Lua string. As an address or integer it is raw little-endian bytes: `'\16\0\0\0'` is 16 |
| `pointer` | a typed 64-bit address (userdata) |
| `uint8..int32` | a typed integer (userdata): `uint8`, `int8`, `uint16`, `int16`, `uint32`, `int32` |
| `int64`, `uint64` | a typed 64-bit integer (userdata) |

### Values

#### `pointer(string:LPVOID): pointer`
#### `pointer(pointer): pointer`
Returns a pointer. A string gives its first 8 bytes. A shorter string is padded with zeros.
#### `uint8(float): uint8`
#### `uint8(string:UINT8): uint8`
`int8`, `uint16`, `int16`, `uint32`, `int32`, `int64` and `uint64` have the same declarations.\
Returns a typed integer. A number is cut to the type like a C cast. A string gives as many bytes as the type holds. A shorter string is padded with zeros.
#### `base: pointer`
The address of `Warhammer3.exe` in memory: `0x0000000140000000`. The game always loads its exe at this address.
#### `version: float`
`1.2`, the memreader API version. memreader Plus keeps it at 1.2 on purpose (see [Both mods installed](#both-mods-installed)).
#### `plus_version: string`
The version of memreader Plus, for example `'0.8.0'`.

### Addition +
#### `add(float, float): float`
#### `add(float, uint8..int32): float`
#### `add(pointer, float:INT64): pointer`
#### `add(pointer, string:UINT32): pointer`
#### `add(pointer, uint8..int32): pointer`
#### `add(uint8..int32, float:UINT32): uint8..int32`
#### `add(uint8..int32, string:UINT32): uint8..int32`
#### `add(uint8..int32, uint8..int32): uint8..int32`
`add(pointer, -16)` subtracts 16. (memreader 1.2 added `0xFFFFFFF0`.)

### Subtraction -
#### `sub(float, float): float`
#### `sub(float, uint8..int32): float`
#### `sub(pointer, float:INT64): pointer`
#### `sub(pointer, string:UINT32): pointer`
#### `sub(pointer, pointer): pointer`
#### `sub(pointer, uint8..int32): pointer`
#### `sub(uint8..int32, float:UINT32): uint8..int32`
#### `sub(uint8..int32, string:UINT32): uint8..int32`
#### `sub(uint8..int32, uint8..int32): uint8..int32`

### Multiplication *
#### `mult(float, float): float`
#### `mult(float, uint8..int32): float`
#### `mult(uint8..int32, float:UINT32): uint8..int32`
#### `mult(uint8..int32, string:UINT32): uint8..int32`
#### `mult(uint8..int32, uint8..int32): uint8..int32`

### Division /
#### `div(float, float): float`
#### `div(float, uint8..int32): float`
#### `div(pointer:ptrdiff_t, float:UINT32): pointer`
#### `div(pointer:ptrdiff_t, string:UINT32): pointer`
#### `div(pointer:ptrdiff_t, uint8..int32): pointer`
#### `div(uint8..int32, float:UINT32): uint8..int32`
#### `div(uint8..int32, string:UINT32): uint8..int32`
#### `div(uint8..int32, uint8..int32): uint8..int32`
Signed types divide as signed: `div(int32(-8), 2)` is -4. Division of a typed integer by zero is a Lua error. `div(float, 0)` gives `inf` or `nan`, as in Lua.

The arithmetic and comparison functions also take `int64` and `uint64`. `uint64` compares and divides as unsigned: `div(uint64 0xFFFFFFFFFFFFFFFF, 2)` is 0x7FFFFFFFFFFFFFFF. A string used with an `int64` or `uint64` counts as its first 8 bytes.

### Comparison
#### `eq(pointer, string:LPVOID): boolean`
#### `eq(pointer, pointer): boolean`
#### `eq(uint8..int32, float:UINT32): boolean`
#### `eq(uint8..int32, string:UINT32): boolean`
#### `eq(uint8..int32, uint8..int32): boolean`
#### `eq := ==`
#### `lt := <`
#### `gt := >`
`lt` and `gt` take the same argument types as `eq`. Signed types compare as signed: `gt(int32(-1), 5)` is false.
#### `is_null(value): boolean`
`true` for `nil`, `false`, a null pointer, a string whose first 8 bytes are zero (or all of it, when it is shorter, so `''` counts), a number between -1 and 1 and a zero typed integer. Any other pointer, string, number or typed integer gives `false`. A table or `true` raises an error.\
memreader 1.2 has no `is_null`. A mod that must also run with only Cpecific's DLL installed compares with `mr.eq(ptr, '\0\0\0\0\0\0\0\0')`.

### Reading
Every read takes an address and an optional `offset`, and reads at `address + offset`.\
`offset` can be `nil` (0), `float:INT64`, `string:UINT32` or a typed integer. A value of any other type counts as 0.\
To pass a later argument, you must also pass the offset, for example `read_uint32(p, nil, true)`. In `read_uint32(p, true)`, `true` is taken as the offset, which counts as 0, and the call returns a plain number.\
A read of an address that cannot be read is a Lua error: `failed to read memory`.

#### `read_float(pointer, [offset]): float`
#### `read_double(pointer, [offset]): float`
The double is returned as a Lua number, so it has float precision.
#### `read_pointer(pointer, [offset]): pointer`
#### `read_uint8(pointer, [offset]): float`
#### `read_uint8(pointer, [offset], return_userdata: boolean): uint8`
`int8`, `uint16`, `int16`, `uint32` and `int32` have the same declarations.\
If you pass `return_userdata=true`, the function returns a typed integer instead of a Lua number.
#### `read_int64(pointer, [offset]): int64`
#### `read_uint64(pointer, [offset]): uint64`
These two always return a typed integer.
#### `read_boolean(pointer, [offset]): boolean`
Returns `true` if the byte is not `0x00`.
#### `read_string(pointer, [offset], isPtr: boolean, isWide: boolean): string`
Reads a `CA::String`. Long text is stored as `{ UINT32 length; UINT32 capacity; char *text; }`. The game stores text of up to 14 characters inline in the same 16 bytes. `read_string` reads both forms. If the inline text is longer than the 15 bytes the inline form holds, the call raises the error `not a CA string`. This can happen only with `isWide=true`, for an inline length above 7.\
`isWide=true` returns the raw UTF-16 bytes, as in memreader 1.2. Use `read_unistring` for readable text.\
With `isPtr=true`, `read_string` behaves like this code:
```lua
local p = read_pointer(ptr, offset)
return read_string(p, 0, false, isWide)
```
`read_string(read_pointer(p, off), 0)` gives the same result and reads more clearly. The flag form does not create the intermediate pointer value, which helps in tight loops.
#### `read_unistring(pointer, [offset]): string`
Reads a `CA::UniString` (wide characters, inline or behind a pointer) and returns UTF-8 text.
#### `read_array(pointer, [offset]): float, pointer`
#### `read_array(pointer, [offset], return_userdata: boolean): int32, pointer`
Structure for a CA vector: `{ UINT32 capacity; INT32 size; T *data; }`\
Returns the size of the vector and a pointer to its data. The pointer is NULL when the size is 0 or less. To read the elements as well, use `read_vector` (see [Reading structures](#reading-structures)).
#### `read_rowidx(pEntry: pointer, [offset], base: pointer, entry_size: float): float`
`read_rowidx` behaves like this code:
```lua
local entry = read_pointer(pEntry, offset)
return 1 + (entry - base) / entry_size
```
The division is done in integers. An `entry_size` below 1 is an error.
#### `read(pointer, [offset], bytes: float): string`
Reads `bytes` from memory. The string holds raw data and is not null terminated. At most 16 MiB per call. A size below 1, NaN, or a size that is not a number gives `''`.

### Writing
#### `write(pointer, [offset], boolean)`
Writes 1 byte.
#### `write(pointer, [offset], float)`
Writes a 4-byte float.
#### `write(pointer, [offset], string)`
Writes the string's bytes.
#### `write(pointer, [offset], pointer)`
#### `write(pointer, [offset], uint8..int32)`
Writes as many bytes as the type has: 1 byte for `uint8`, 8 bytes for a pointer, `int64` or `uint64`.

```lua
mr.write(ptr, 0x0100, false) -- boolean (1 byte)
mr.write(ptr, 0x0100, 165.48) -- float
mr.write(ptr, 0x0100, 'das\0\0\0\1\2\89fuw') -- array of bytes
mr.write(ptr, 0x0100, mr.pointer('\0\0\0\64\1\0\0\0')) -- pointer 0x0000000140000000
mr.write(ptr, 0x0100, mr.uint32('\0\0\0\64')) -- uint32 0x40000000
mr.write(ptr, 0x0100, mr.uint16(0x4000)) -- uint16 0x4000
mr.write(ptr, 0x0100, mr.uint8(0x40)) -- uint8 0x40
```

`write` also writes into the game's code. It copies directly when the memory is writable, and uses `WriteProcessMemory` otherwise, but only inside `Warhammer3.exe`. It can't write to the exe's read-only data, such as its constant tables and text, and fails there with `failed to write memory`. Use `patch` for those bytes, because `patch` makes the page writable for the write. Outside the exe, `write` writes only to data memory such as the game's heap.

A `write` into the first instructions of a function that memreader Plus has hooked is refused with a Lua error. The game runs those instructions from the hook's copy, so a change there would never run.

### Finding code
#### `find_pattern(pattern: string): pointer | nil, float`
Searches the game's code for bytes written as hex, with `??` for any byte, for example `'B9 ?? 00 00 00 8B 80 ?? ?? ?? ??'`. Returns the address of the first match (or `nil`) and the number of matches. The pattern must start with a known byte and can be at most 256 bytes long.\
Check that the count is exactly 1 before you use the address: 0 means the code changed, more than 1 means the pattern is too short. Put `??` over every byte a game patch may move (struct offsets, call targets) and over every byte your mod changes, so the pattern still matches after the next patch and after your script runs again in the next game mode.\
`find_pattern` ignores hooks made by memreader Plus. Where one of them has replaced bytes, it compares the original bytes. Hooks made by other tools change the bytes, and a pattern that covers them may stop matching. The reads do not ignore hooks: `read`, `read_uint8` and the other reads of a hooked function's first bytes return the hook's jump. `read_original` returns the bytes that `find_pattern` compares.\
The game's code stays at the same address for the whole game session, so memreader Plus keeps the result of each pattern it has searched, for up to 1024 different patterns. When your script calls `find_pattern` again with the same pattern string, in the same game mode or a later one, it gets the kept address and count at once, also when the count was 0 or more than 1. Only the exact text counts: `'B9 ?? 00'` and `'B9 ?? 00 '` are searched separately. The kept result describes the code at the first search. If something other than a memreader Plus hook, `patch`, `relocate_field` or `grow_frame` changes the code later, for example `write` or another tool, a new search could give a different result, but the kept one is returned. Patterns beyond the first 1024 are searched again on every call, and a pattern that fails to parse is never kept.
#### `find_patterns(patterns: table): table, table`
Searches for up to 64 patterns in one pass over the game's code. `patterns` is an array of pattern strings in the `find_pattern` format. The first result holds, for each pattern, the address of its first match or `false`. The second holds the number of matches. Patterns searched before, by either function, come from the kept results, and only the others are searched. A mod with many patterns loads faster this way. One `find_pattern` call takes about 18 ms, and one `find_patterns` call with the 30 patterns of Adjustable Army Size takes about 130 ms. In one game session on build 9.0.2.0, the 86 patterns of Adjustable Army Size, Legendary Unlocked and Unit Size Multiplier took 460 to 640 ms the first time they were searched. Every later search of them took about 0.3 ms, in the frontend, in a campaign and in a battle.
#### `read_original(pointer, [offset], bytes: float): string`
Returns `bytes` bytes (1 to 4096) of the game's code at `pointer + offset` as `find_pattern` sees them. Where a memreader Plus hook, `patch`, `relocate_field` or `grow_frame` changed the code, you get the bytes from before the change. Everywhere else, including code changed with `write`, you get the bytes that are there now. The range must be inside `Warhammer3.exe`, and a size outside 1 to 4096 is an error.\
With two arguments the second one is the size, so `read_original(p, 16)` reads 16 bytes at `p`. The other reads always take the second argument as the offset: `read(p, 16)` reads at `p + 16`, has no size and returns `''`.\
Use it to read an operand from the first bytes of a function that may be hooked, by your mod or another one, in this game mode or an earlier one. `hook_info(address).original` is no replacement. It is the hook's trampoline, a copy of the first instructions in other memory. An instruction there that addresses memory relative to its own position has different offset bytes than in the game's code. After the copied instructions the trampoline holds its jump back into the game's code, not the rest of the function.\
memreader Plus keeps the original bytes of up to 4096 changed spots per session. A change takes one spot for every 8 bytes it covers, at least one, and a change to code whose original bytes are already kept takes none. Once all 4096 are used, code changed later shows its new bytes to `find_pattern` and `read_original`. memreader Plus then writes one line about it to `memreader_plus_refused.txt`, unless the file already holds 32 lines for the session.
#### `function_start(address: pointer): pointer, pointer | nil`
Returns the start of the game function that contains `address`, and the end of the code range that holds `address`. It reads the exe's function table, the same one Windows uses to unwind the stack. Some functions are split into several ranges, and then the start is that of the first range while the end belongs to the range around `address`. Returns `nil` for an address in no listed function: data, padding between functions, or a small function that never calls anything and so has no table entry. An address outside `Warhammer3.exe` is an error.\
Use it to hook a function you find by a pattern inside its body. The middle of a function often stays the same across game patches when its first bytes change, so one pattern there plus `function_start` can replace a list of per-build patterns for the start.

### Modules
#### `modules(): iterator of { base: pointer, size: float, name: string, path: string }`
```lua
for module in mr.modules() do
	out('base = ' .. mr.tostring(module.base) .. ', size = ' .. tostring(module.size) .. ', name = ' .. module.name .. ', path = ' .. module.path)
end
```
The entries are plain tables. (In memreader 1.2 they are userdata with the same fields.)

### Misc: type
#### `type(nil): 'nil'`
#### `type(boolean): 'boolean'`
#### `type(float): 'float'`
#### `type(string): 'bytes'`
#### `type(pointer): 'pointer'`
#### `type(uint8..int32): 'uint8'..'int32'`
#### `type(int64 | uint64): 'int64' | 'uint64'`
Any other type (a table, a function) is an error.

### Misc: tostring
#### `tostring(nil | boolean | float): string`
Returns what Lua's `tostring` returns.
#### `tostring(string): string`
Returns the hex representation of the bytes.
#### `tostring(pointer): string // %p`
16 hex digits, no `0x`: `0000000140000000`.
#### `tostring(uint8..int64): string // %lld`
#### `tostring(uint64): string // %llu`
The value in decimal.

### Misc: tonumber
#### `tonumber(float:UINT32): float`
#### `tonumber(string:UINT32): float`
#### `tonumber(pointer): 0`
A pointer gives 0. Print pointers with `mr.tostring`.
#### `tonumber(uint8..uint64): float`
Signed types give negative numbers: `tonumber(int32(-1))` is -1.

### Misc: userdata
#### `ud_topointer(userdata): pointer`
Returns the pointer stored in a userdata. For a script interface such as `CHARACTER_SCRIPT_INTERFACE`, that is the address of the interface object. See [Understanding userdata](#understanding-userdata).
```lua
local chptr = mr.ud_topointer(character)
chptr = mr.read_pointer(chptr, 0x10)
```
#### `ud_debug(userdata): float, pointer`
Returns the Lua type of the value (`TValue.tt`) and its pointer (`TValue.value.p`). The field names are from the Lua 5.1 source.

### Misc: createtable
#### `createtable(narr, nrec): table`
Creates a new table with space for `narr` array entries and `nrec` hash entries.\
`narr` and `nrec` can be `float:UINT32`, `string:UINT32` or `uint8..int32`. Each is capped at 2^20.

### Misc: timing
#### `ticks(): uint64`
Returns the current value of the high-resolution clock (`QueryPerformanceCounter`).
#### `elapsed_us(since: uint64): float`
Returns the microseconds since a `ticks()` value. Any other argument is an error. The result is exact for about the first 16 seconds and has about 7 significant digits after that.
```lua
local start = mr.ticks()
do_work()
out(('took %.1f us'):format(mr.elapsed_us(start)))
```

## Differences from memreader 1.2

| | memreader 1.2 (Workshop 2789863945) | memreader Plus |
|---|---|---|
| Every read | a `ReadProcessMemory` call: about 800 ns per read in game | a guarded direct copy: about 120 ns per `read_uint32` in game (a new exact typed value costs more); a bad address is still a Lua error |
| `read` / `read_string` of 1024 bytes or more | crashes the game | works |
| Signed types in `div`, `gt`, `lt`, `tonumber` | treated as unsigned: `div(int32(-8), 2)` = 2147483644, `gt(int32(-1), 5)` = true, `tonumber(int32(-1))` = 1.8e19 | signed: -4, false, -1 |
| `add(pointer, -16)` | adds 0xFFFFFFF0 | subtracts 16 |
| Typed value as offset (`read_uint16(base, uint8(2))`) | offset ignored, reads at `base` | reads at `base + 2` |
| `tonumber(uint8(9))` | 0 | 9 |
| `uint8('\7')`, `gt(uint8(5), 1)`, `eq(pointer, 16)` | error | 7, true, true |
| `read_string` of a short CA string (up to 14 characters) | reads the characters as a length and a pointer: garbage, an error or a crash | returns the text |
| Two reads of the same value | two different userdata: `a == b` is false | the same userdata: `==` and table keys work |
| `modules()` entries | userdata | plain tables with the same fields |
| `div(x, 0)`, `write(addr, 0, nil)`, `ud_topointer(5)` | undefined | a Lua error that names the problem |
| `div(pointer 0x8000000000000000, -1)` | crashes the game | wraps to 0x8000000000000000 |
| `read` of more than 16 MiB | tries to allocate it | error `cannot read more than 16777216 bytes at once` |
| `createtable(1e9)` | asks for about 16 GB | size hints capped at 2^20 each |
| `read_rowidx` | divides in float: off by one above 16 MiB | integer division; a row size below 1 is an error |
| Padding bytes of typed values | not initialised | zeroed |
| `write` to another DLL, to executable memory outside the exe, or to the exe's headers and import or export tables | writes it | refused with a Lua error |
| New functions | | `int64`, `uint64`, `is_null`, `read_int64`, `read_uint64`, `read_double`, `read_unistring`, `read_struct`, `read_vector`, `read_list`, `read_chain`, `find_pattern`, `find_patterns`, `function_start`, `read_original`, `call`, `alloc`, `hook`, `hook_next`, `unhook`, `hook_info`, `hook_depth`, `game_alloc`, `game_free`, `patch`, `relocate_field`, `grow_frame`, `commit_stack`, `hop_slots`, `vector_reserve`, `vector_insert`, `vector_erase`, `string_set`, `unistring_set`, `map_find_key`, `map_add_key`, `map_remove_key`, `list_insert`, `list_erase`, `read_pack_file`, `pack_file_exists`, `file_edit`, `file_edit_remove`, `file_edit_list`, `file_edit_preview`, `file_edit_apply`, `file_edit_status`, `set_file_edits`, `ticks`, `elapsed_us`, `set_crash_reports`, `set_crash_context`, `note_crash_event`, the field `plus_version` and the table `twui` |
| Lua globals | `_G.memreader` | `_G.memreader_plus`, and `_G.memreader` for compatibility |
| DLL in the game folder | `twwh3-memreader.dll`, rewritten only when the loaded `version` differs | `twwh3-memreader_plus.dll`, rewritten whenever its bytes differ from the pack |
| Metatables | `memreader.module`, `memreader.snapshot` | none, so nothing collides when both DLLs load |

`tests/offline.lua` lists every intended difference from memreader 1.2 in `CHANGED` and `FIXED`.

The module is a Windows DLL that the loader loads with `require`, so it works only on Windows x64.

## Building from source

Needs Visual Studio 2022 (C tools, with `ml64` for the assembly file), CMake and Python 3.13. You don't need RPFM to build the pack. `build.ps1` calls `tools/build_pack.py`, which writes the `.pack` file directly.

```
pwsh -File build.ps1          # DLL -> dist\pack -> ..\memreader_plus.pack
pwsh -File tests\run.ps1      # tests
```

| Folder | What |
|---|---|
| `script/` | the Lua in the pack: loaders, MCT page |
| `src/` | the DLL's C and assembly source |
| `vendor/` | Lua 5.1 (with the game's float numbers) and MinHook |
| `tools/` | pack building and helper scripts |
| `tests/` | tests |

## Credits and license

memreader by Cpecific (MIT, https://github.com/Cpecific/twwh2-memreader), which was based on [squeek502/memreader](https://github.com/squeek502/memreader). memreader Plus keeps Cpecific's API and license. See `LICENSE.md`.

Lua 5.1 by Lua.org, PUC-Rio (MIT, https://www.lua.org), in `vendor/lua-5.1/`, set up for the game's 32-bit float numbers.

MinHook by Tsuda Kageyu (BSD 2-clause, https://github.com/TsudaKageyu/minhook), in `vendor/minhook/` with its `LICENSE.txt`. The only change is in `src/buffer.c`, where `MEMORY_BLOCK_SIZE` is 64 KB instead of 4 KB. One block therefore holds 1023 hook trampolines instead of 63.
