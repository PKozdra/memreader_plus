# memreader Plus (TWWH3)

memreader Plus is a Lua module that lets mod scripts for Total War: WARHAMMER III read and write the game's memory, call the game's own functions, and hook them to change what they do.\
Based on [memreader by Cpecific](https://github.com/Cpecific/twwh2-memreader), who wrote the WH2 and the WH3 build. Cpecific's module was itself based on [squeek502/memreader](https://github.com/squeek502/memreader).\
Only works on Windows x64. Tested on game build 9.0.1.0.

Mods written for memreader will keep working when memreader Plus is installed: `_G.memreader` has the same functions, arguments and result types as memreader 1.2. However, where 1.2 gave a buggy result, or at least one that probably wasn't intended, memreader Plus gives the right one. A mod that relied on one of those bugs can behave differently. New functions are also available under `_G.memreader_plus` as an alias to `_G.memreader`.

## What changed from memreader 1.2

### New

- `call` runs a function from the game's code with arguments you pass from Lua and gives you its return value. You can use it to look up a DB row or to hash a string the way the game does. See [Calling game functions](#calling-game-functions).
- `hook` makes your Lua callback run every time the game calls a given function. The callback can read or change the arguments, replace the return value, or skip the game's function completely. Several mods can hook the same function. See [Hooking game functions](#hooking-game-functions).
- `find_pattern` searches the game's code for a byte pattern and returns its address. A mod that finds its addresses this way keeps working after a game patch, as long as the bytes it searches for did not change.
- When the game crashes while a script is running, memreader Plus writes a text file with the Lua call stack and the list of loaded mods.
- There are new read functions for `CA::UniString` text (`read_unistring`), for 64-bit integers and doubles, and for null checks (`is_null`). `read_struct`, `read_vector`, `read_list` and `read_chain` read a whole structure in one call.

### Fixed and faster

- Reads of 1 KB or more no longer crash the game. `div`, `gt`, `lt` and `tonumber` treat `int8` to `int32` as signed. `add(pointer, -16)` subtracts 16. A typed value used as an offset is no longer ignored. `read_string` reads short CA strings (up to 15 characters, stored inline) correctly.
- Plain reads are about ten times faster. memreader Plus copies the memory directly, with a guard against bad addresses, instead of calling `ReadProcessMemory`: about 75 ns instead of about 800 ns for a `read_uint32` in game. A bad address will still result in a Lua error.

Every difference, with before and after values, is in [Differences from memreader 1.2](#differences-from-memreader-12).

## Contents

- [Quick look](#quick-look)
- [Installation](#installation)
- [Before you start](#before-you-start)
- [API reference](#api-reference)
- [Reading structures](#reading-structures)
- [Calling game functions](#calling-game-functions)
- [Hooking game functions](#hooking-game-functions)
- [Understanding userdata](#understanding-userdata)
- [Crash reports](#crash-reports)
- [Both mods installed](#both-mods-installed)
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

-- CA::String: text stored inline (up to 15 characters) or behind a pointer
local name = mr.read_string(ptr, 0x20) -- ex: Adam
-- a pointer to a CA::String
local name2 = mr.read_string(ptr, 0x30, true) -- ex: Adam
-- CA::UniString (wide characters), returned as UTF-8 text
local title = mr.read_unistring(ptr, 0x40) -- ex: Adam

-- CA vector: { INT32 capacity; INT32 size; T *data; }
local size, pdata = mr.read_array(ptr, 0x50)
-- or read every element in one call: an array of numbers
local values = mr.read_vector(ptr, 0x50, { 0, 'int32' }, 4)

-- a script interface object gives you the address of the game object behind it
local character = cm:get_character_by_cqi(cqi)
local chptr = mr.ud_topointer(character)
tostring(character) -- ex: CHARACTER_SCRIPT_INTERFACE (0000000049376488)
mr.tostring(chptr) -- ex: 0000000049376488

-- find game code by its bytes, so the mod survives game patches
local address, count = mr.find_pattern('48 89 5C 24 08 44 8B CA 8B DA 41 C1 E9 02 41 BA ED 5E 54 4A')
-- call it: CA::murmur_hash3_32(data, length)
local key = 'wh2_main_hef_bow_arrow'
local text = mr.alloc(#key + 1)
mr.write(text, 0, key)
local hash = mr.call(address, 'uint32(pointer, uint32)', text, #key)
```

The addresses and offsets above are examples. Real ones depend on the game build and the structure you read.

## Installation

### Players

Subscribe to memreader Plus on the Steam Workshop and enable it in the launcher. When a mod needs memreader, memreader Plus can also be used as an alternative, and both can be enabled together. On its first load in a session, memreader Plus writes `twwh3-memreader_plus.dll` next to `Warhammer3.exe` and loads it from there.

### Modders

List memreader Plus as a required item of your mod, and use the module from your script:

```lua
local mr = _G.memreader_plus
```

Read `_G.memreader_plus` inside a function or a listener, or from a script in `script/campaign/mod`. Do not read it at the top of a file in `script/_lib/mod`: those files load in alphabetical order, and yours may run before memreader Plus has loaded, when the global is still `nil`.

If your mod must also work when only Cpecific's memreader is installed, use `_G.memreader` and only the functions memreader 1.2 has.

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

Use `string.find_lua(bytes, text, 1, true)`. CA's own `string.find` works on characters, and with a fourth argument it returns nothing and breaks CA's other Lua functions (UI included) until the game mode ends.

### Multiplayer

Reading memory never desyncs. Decisions based on pointer values, on the order of pointers, or on memory that only one player has (such as UI state) can desync. Change the game model only from data every client shares, and only with calls, hooks and writes that every client makes.

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
Returns a pointer. A string gives its first 8 bytes; a shorter string is padded with zeros.
#### `uint8(float): uint8`
#### `uint8(string:UINT8): uint8`
`int8`, `uint16`, `int16`, `uint32`, `int32`, `int64` and `uint64` have the same declarations.\
Returns a typed integer. A number is cut to the type like a C cast. A string gives as many bytes as the type holds; a shorter string is padded with zeros.
#### `base: pointer`
The address of `Warhammer3.exe` in memory: `0x0000000140000000`. The game always loads its exe at this address.
#### `version: float`
`1.2`, the memreader API version. memreader Plus keeps it at 1.2 on purpose (see [Both mods installed](#both-mods-installed)).
#### `plus_version: string`
The version of memreader Plus, for example `'0.5.0'`.
#### `plus_api: float`
An integer that goes up by one whenever the API gets new functions. Level 1 added the bulk reads, level 2 `call`, level 3 `hook`, level 4 `hook_depth`, `ticks` and `elapsed_us`, and level 5 several callbacks per address, `hook_next` and `set_crash_reports`.

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
Signed types divide as signed: `div(int32(-8), 2)` is -4. Division of a typed integer by zero is a Lua error; `div(float, 0)` gives `inf` or `nan`, as in Lua.

The arithmetic and comparison functions also take `int64` and `uint64`. `uint64` compares as unsigned.

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
`true` for `nil`, `false`, a null pointer, a string of zero bytes (any length, including `''`), a number below 1 and a zero typed integer. Any other `nil`, pointer, string, number or typed integer gives `false`. A table or `true` raises an error.\
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
Reads a `CA::String`. Long text is stored as `{ UINT32 length; UINT32 capacity; char *text; }`; text of up to 15 characters is stored inline in the same 16 bytes. `read_string` reads both forms. If the inline length is longer than the 15 bytes the inline form holds, the call raises the error `not a CA string`.\
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
Structure for a CA vector: `{ INT32 capacity; INT32 size; T *data; }`\
Returns the size of the vector and a pointer to its data. The pointer is NULL when the size is 0 or less. To read the elements as well, use `read_vector` (see [Reading structures](#reading-structures)).
#### `read_rowidx(pEntry: pointer, [offset], base: pointer, entry_size: float): float`
`read_rowidx` behaves like this code:
```lua
local entry = read_pointer(pEntry, offset)
return 1 + (entry - base) / entry_size
```
The division is done in integers. `entry_size` 0 is an error.
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

`write` also writes into the game's code and read-only data. It copies directly when the memory is writable, and uses `WriteProcessMemory` otherwise.

### Finding code
#### `find_pattern(pattern: string): pointer | nil, float`
Searches the game's code for bytes written as hex, with `??` for any byte, for example `'B9 ?? 00 00 00 8B 80 ?? ?? ?? ??'`. Returns the address of the first match (or `nil`) and the number of matches. The pattern must start with a known byte.\
Check that the count is exactly 1 before you use the address: 0 means the code changed, more than 1 means the pattern is too short. Put `??` over every byte a game patch may move (struct offsets, call targets) and over every byte your mod changes, so the pattern still matches after the next patch and after your script runs again in the next game mode.\
`find_pattern` ignores hooks made by memreader Plus. Where one of them has replaced bytes, it compares the original bytes. Hooks made by other tools change the bytes, and a pattern that covers them may stop matching.

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
Behaves the same as Lua's `tostring`.
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
Returns the Lua type of the value (`TValue.tt`) and its pointer (`TValue.value.p`). Refer to the Lua 5.1 source.

### Misc: createtable
#### `createtable(narr, nrec): table`
Creates a new table with space for `narr` array entries and `nrec` hash entries.\
`narr` and `nrec` can be `float:UINT32`, `string:UINT32` or `uint8..int32`. Each is capped at 2^20.

### Misc: timing
#### `ticks(): uint64`
The high-resolution clock (`QueryPerformanceCounter`).
#### `elapsed_us(since: uint64): float`
Returns the microseconds since a `ticks()` value. Any other argument is an error. The result is exact for about the first 16 seconds and has about 7 significant digits after that.
```lua
local start = mr.ticks()
do_work()
out(('took %.1f us'):format(mr.elapsed_us(start)))
```

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

#### `read_struct(pointer, [offset], layout): table`
A table with the layout's names.
#### `read_vector(pointer, [offset], field, stride): table`
An array of the vector's elements. `stride` is the size of one element.
#### `read_list(pointer, [offset], field): table`
An array in list order. `field` offsets count from the node: links at +0 and +8, the value from +0x10.
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
- The field decides the type of the result, whatever value is read. Integers are numbers unless the field has `true`. `int64`, `uint64`, `pointer` and `address` fields always give typed values.
- Offsets and strides are whole numbers from 0 to 16,777,215. `read_chain` refuses larger number offsets, because they have already lost precision; pass a typed value.
- To keep a wrong layout from freezing or crashing the game, fields can nest at most 16 levels deep, and one call reads at most 131,072 vector or list elements. Going over either limit is an error.
- `read_list` checks each list as it reads it. Every node's back link must point to the previous node, and the number of nodes must match the list's size. If the list changes while it is being read, the call fails with an error.
- An error message names the field where the read failed, for example `tiers[3].nodes[12].key: failed to read memory`.
- A field costs about 0.3 µs in game. These functions are shorter to write and add the checks above, but they are not faster than reading the fields one by one.

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
Calls the function. At most 16 arguments, and the count must match the signature.
#### `alloc(size: float): pointer`
Returns a pointer to `size` zeroed bytes (16-byte aligned, 1 byte to 16 MiB), for a function's arguments or results. Fill it with `write`. There is no `free`: the memory lives until the next game mode switch, and all `alloc` blocks of one mode together hold at most 16 MiB. Allocate a buffer once and reuse it.

memreader Plus refuses an integer argument that it cannot pass on exactly. A plain number must be whole, below 16,777,216 and inside the type's range (`uint8` takes 0 to 255); anything else is an error that names the argument. A hash written in the script, such as `0x61187b6d`, is already `0x61187b80` as a Lua number, and passing it on would call the game with a wrong value. Pass large values as typed values (`read_uint32(p, off, true)`, `add`) or as raw bytes (`'\109\123\24\97'`). Typed values and bytes are cut to the type like a C cast: a `uint32` of 300 passed as `uint8` gives 44. A string is read as raw bytes, not as digits: `'12'` is 12849.

Use the type names from the table, in lower case. Ghidra's type names are not accepted. Write `longlong` as `int64`, `ulonglong` as `uint64`, `int` and `uint` as `int32` and `uint32`, `short` and `ushort` as `int16` and `uint16`, `char` and `byte` as `int8` and `uint8`, `bool` as `boolean`, and every pointer (`char *`, `void *`, `Foo *`) as `pointer`.

Methods and structs follow the Microsoft x64 calling convention:

- `this` is the first `pointer` argument.
- A method that returns a class or struct returns it through a hidden buffer, passed right after `this`, even when it is 8 bytes or smaller. A free function also returns it through a hidden buffer, unless the struct is 1, 2, 4 or 8 bytes, in which case it comes back as `uint8` .. `uint64`. Pass the buffer yourself (`alloc`) and use `pointer` as the result: it is the buffer.
- A struct passed by value: 1, 2, 4 or 8 bytes go in as `uint8` .. `uint64` holding its bytes; any other size goes in as a `pointer` to a copy, which the called function may change. A class with a destructor passed by value (a `CA::String` parameter without `&`) is destroyed by the called function.
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

local row = mr.call(record_index, 'uint32(pointer, pointer)', projectiles_table, ca_string('wh2_main_hef_bow_arrow'))
```

`record_index` is `DATABASE_TABLE::record_index(table, key)` in game build 9.0.1.0.

### Rules for calls

- Find addresses with `find_pattern` and check that the count is 1. With a wrong address or a wrong signature, the game's code runs on wrong values.
- Lua owns the memory that `alloc` returns and frees it at the next mode switch. Give it only to functions that use it during the call (a key to look up, a buffer to fill). Never give it to a function that keeps it, frees it or reallocates it: a by-value `CA::String`, a string assigned into a game object, a container that takes ownership, a listener registration. The game would free Lua's memory, or keep a pointer that dangles after the mode switch. For anything the game keeps, build it with the game's own constructors.
- A crash inside the called function becomes a Lua error: `the called function crashed at <address> (...); the game may be unstable now`. This covers access violations, illegal instructions, the `int3` padding between functions, integer division by zero and similar CPU faults. The game's code stopped halfway, so a lock may still be held or an object may be half changed. Stop calling game functions, and let the player save and restart. C++ exceptions and stack overflows still crash the game.
- Call game functions only from Lua code that the game runs: your script, a listener or a hook callback. Game functions that wait for the loading thread, or take locks the script thread holds, can hang the game.
- Do not call inside a coroutine a game function that runs script events or calls back into Lua. A Lua error in such a callback leaves the coroutine unable to resume ("cannot resume non-suspended coroutine").
- A call that changes the game model desyncs multiplayer unless every client makes it.
- A call costs about 0.3 µs.
- `double` arguments and results carry Lua's float precision: 16777216 + 1 gives 16777216.
- Spaces and tabs between names in the signature are allowed; a trailing comma is an error.
- A call into the middle of an instruction can execute invalid code without raising a fault.

## Hooking game functions

`hook(address, signature, callback)` sends every call the game makes to the function at `address` through `callback`. The signature is the same as for `call`. The callback gets the arguments, converted like `call` results, and returns the result the game sees. `hook_next(address, ...)` runs the rest of the chain with the arguments you give it: the next callback below yours, or the original function when there is none.

```lua
local HASH = 'uint32(pointer, uint32)'
local murmur = mr.find_pattern('48 89 5C 24 08 44 8B CA 8B DA 41 C1 E9 02 41 BA ED 5E 54 4A')
mr.hook(murmur, HASH, function(data, length)
	local hash = mr.hook_next(murmur, data, length)
	return hash
end)
```

A callback can run code before or after the original, change the arguments, replace the result, or skip the original. An integer result follows the rules for integer arguments of `call`: a typed value, raw bytes, or a whole number that fits the type.

Several mods can hook the same address. The newest callback runs first. Each callback calls `hook_next` to pass the call down, or returns its own result without it.

#### `hook(address: pointer, signature: string, callback: function)`
Adds `callback` on top of the address's chain. The first hook of an address also patches the game's code. An address takes at most 16 callbacks, all with the same signature. A different signature, or the same function twice, is an error.
#### `hook_next(address: pointer, ...): result`
Call it inside a callback of `address`. It runs the next callback down with these arguments, or the original function when yours is the last callback, and returns its result.
#### `unhook(address: pointer, [callback: function])`
Removes that callback. Without `callback` it removes all of them, and the game calls the original function directly again. A callback may unhook itself or others while it runs; the change applies from the next call.
#### `hook_info(address: pointer): table | nil`
`nil` if the address was never hooked, else `{ original, attached, callbacks, calls, error }`. `original` is the original function; calling it with `call` skips every other callback. `calls` counts how often the hook fired. It is a plain number, exact up to 16,777,216. `error` holds the message of the last callback that failed.
#### `hook_depth(): float`
Returns the number of hook callbacks that are running (0 outside a callback).

### Rules for hooks

- The patch stays for the whole game session, but callbacks last only one game mode. At every mode switch (frontend, campaign, battle) the game closes Lua and every callback is detached. Until a script hooks the address again, the game's calls run the original function directly. Your script must hook again in each mode, just as it registers its listeners again. At most 1000 hooked addresses per session.
- Call `hook` from your script's own code or a listener, never inside a coroutine. The callback runs on the same Lua thread as the `hook` call. While that thread is suspended, the game's calls run the original function directly.
- Do not call the game's script functions inside a callback (`common.*`, `cm:*`, `ModLog`, interface methods). The hooked function often runs while another script function is still in progress. A callback that called `common.get_localised_string` crashed the campaign later, in a `context:character()`, probably because the second script function corrupted the state of the first. Inside a callback, read memory with memreader Plus and use Lua's own `string.*`, `math.*` and `table.*`. Store the values you need in a variable, and call the game's script functions later from a listener or a timer. A library that calls the game's functions can refuse to run inside a callback with `if mr.hook_depth() > 0 then`.
- Only calls on the script thread reach the callback. Calls from the game's other threads, and every call while no callback is attached, run the original function directly.
- A callback that raises an error is detached, and the call continues with the next callback down, or with the original function and the arguments the game passed. The message stays in `hook_info(address).error` until the chain is empty and a new `hook` call starts a new chain. Returning nothing where the signature has a result counts as an error.
- Only the game's read-only code can be hooked. The copy-protection region is writable, so `hook` refuses it with `not an address in read-only executable code`.
- Every hooked call on the script thread runs your Lua. The hook adds about 400 ns per call before the callback does anything, and each further callback in a chain about 150 ns more. Hooking a function the game calls thousands of times per frame slows the game down. Check how often a hook fired with `hook_info(address).calls`.
- Do not hook Lua's own functions or the allocator Lua uses, because the callback itself runs Lua. Do not hook functions that raise Lua errors, such as script bindings: the error jumps past the hook and leaves it in a broken state. `__vectorcall` functions are not supported, because the hook does not save all the registers they use. MinHook refuses functions shorter than 5 bytes.
- A hook that changes the game model desyncs multiplayer unless every client has it.

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

In WH3 a script interface userdata holds 8 bytes: the address of the `*_SCRIPT_INTERFACE` object, which `ud_topointer` returns. The game object the interface stands for is stored inside that object; Cpecific's Skill Queue reads the character at `+0x10`. For other interfaces, check the offset yourself: open the address in a memory viewer (ReClass.NET, Cheat Engine), compare several objects of the same type, and look for the heap pointer.

The same game object always gives the same userdata while it exists, so `==` works on script interfaces. Heap addresses change every run and every game mode: never keep a pointer from one mode in the next.

## Crash reports

When the game hits a fatal fault on its script thread (access violation, illegal instruction, integer division by zero, stack overflow), memreader Plus writes `memreader_crash_report_DDMMYY_HHMM.txt` next to `Warhammer3.exe`. Nothing is sent anywhere.

The report gives the time, the exception and where it happened (`Warhammer3.exe+offset`). It lists the Lua call stack, innermost first, with the source file, line, function and string locals of each frame. An event handler's `eventname` is one of those locals. If the stack says `no Lua function was running`, the fault is in the game's own code.

The report also gives the game version, the command line and the crash folder. It lists every mod in load order with its file size, date, Workshop id and folder, and it names packs in the mod list that exist nowhere and same-named packs that the game did not load. Last, it names the game's own crash files for the same crash (`.mdmp` and `.stack.txt`). Attach the `.mdmp` to a bug report for crashes in the game's code.

Paths under your user profile are written as `%USERPROFILE%`, and you can post the file without editing it.

The time stamp in the report's file name is the same as in the name of the script log of that Lua state (`script_log_DDMMYY_HHMM.txt`), so you can find the log that belongs to a report. If script logging is off, the time stamp is the time the game started. If the game crashes again while the same script log is in use, the new report overwrites the old one.

Crash reports are on by default. With MCT installed, memreader Plus's MCT page has one option, **Enable better crash reporting**. To change the setting from Lua, call:

#### `set_crash_reports(enabled: boolean): boolean`
Turns crash reports on or off and returns the previous setting.

### Limits

- Faults that memreader Plus already turns into Lua errors (a failed read, a crash inside `call`) do not produce a report.
- The report shows the Lua state that loaded memreader Plus. Code that runs in another script environment or in a coroutine may be missing from it.
- The report is also written for a fault that the game catches and recovers from, so finding a report does not prove that the game crashed.

## Both mods installed

Players will often have memreader and memreader Plus enabled together. Both mods ship a loader at the same path, `script/_lib/mod/memreader.lua`. The game runs the `_lib/mod` files in alphabetical order, and that loader runs before `memreader_plus.lua`. Of the two copies, the game uses the one from the pack whose `mod` line comes first in the mod list. Mod managers write that list in alphabetical order by default, which puts memreader Plus first unless the player reorders it.

1. If memreader Plus is listed first, its `memreader.lua` loads memreader Plus, and Cpecific's loader never runs.
2. If Cpecific's memreader is listed first, his loader loads his DLL and sets `_G.memreader`. Then `memreader_plus.lua` loads memreader Plus, which replaces `_G.memreader`. His DLL stays loaded but is not used.

memreader Plus replaces Cpecific's memreader in both cases, and every mod that uses `_G.memreader` ends up using memreader Plus. This holds for any script that reads `_G.memreader` after the `_lib/mod` files have loaded, for example a script in `script/campaign/mod`. If Cpecific's memreader is listed first, a `_lib/mod` file that sorts before `memreader_plus.lua` can still see Cpecific's version. If memreader Plus cannot write its DLL (two game instances running different versions lock the file), it logs `cannot write ...` and does not load, and `_G.memreader` stays Cpecific's.

## Differences from memreader 1.2

| | memreader 1.2 (Workshop 2789863945) | memreader Plus |
|---|---|---|
| Every read | a `ReadProcessMemory` call: about 800 ns per read in game | a guarded direct copy: about 75 ns per `read_uint32` in game (a new exact typed value costs more); a bad address is still a Lua error |
| `read` / `read_string` of 1024 bytes or more | crashes the game | works |
| Signed types in `div`, `gt`, `lt`, `tonumber` | treated as unsigned: `div(int32(-8), 2)` = 2147483644, `gt(int32(-1), 5)` = true, `tonumber(int32(-1))` = 1.8e19 | signed: -4, false, -1 |
| `add(pointer, -16)` | adds 0xFFFFFFF0 | subtracts 16 |
| Typed value as offset (`read_uint16(base, uint8(2))`) | offset ignored, reads at `base` | reads at `base + 2` |
| `tonumber(uint8(9))` | 0 | 9 |
| `uint8('\7')`, `gt(uint8(5), 1)`, `eq(pointer, 16)` | error | 7, true, true |
| `read_string` of a short CA string (up to 15 characters) | reads the characters as a length and a pointer: garbage, an error or a crash | returns the text |
| Two reads of the same value | two different userdata: `a == b` is false | the same userdata: `==` and table keys work |
| `modules()` entries | userdata | plain tables with the same fields |
| `div(x, 0)`, `write(addr, 0, nil)`, `ud_topointer(5)` | undefined | a Lua error that names the problem |
| `div(pointer 0x8000000000000000, -1)` | crashes the game | wraps to 0x8000000000000000 |
| `read` of more than 16 MiB | tries to allocate it | error `cannot read more than 16777216 bytes at once` |
| `createtable(1e9)` | asks for about 16 GB | size hints capped at 2^20 each |
| `read_rowidx` | divides in float: off by one above 16 MiB | integer division; row size 0 is an error |
| Padding bytes of typed values | not initialised | zeroed |
| New functions | | `read_unistring`, `is_null`, `read_int64`, `read_uint64`, `read_double`, `int64`, `uint64`, `read_struct`, `read_vector`, `read_list`, `read_chain`, `find_pattern`, `call`, `alloc`, `hook`, `hook_next`, `unhook`, `hook_info`, `hook_depth`, `ticks`, `elapsed_us`, `set_crash_reports`, `plus_version`, `plus_api` |
| Lua globals | `_G.memreader` | `_G.memreader_plus`, and `_G.memreader` for compatibility |
| DLL in the game folder | `twwh3-memreader.dll`, rewritten only when the loaded `version` differs | `twwh3-memreader_plus.dll`, rewritten whenever its bytes differ from the pack |
| Metatables | `memreader.module`, `memreader.snapshot` | none, so nothing collides when both DLLs load |

`tests/offline.lua` lists every intended difference from memreader 1.2 in `CHANGED` and `FIXED`.

The module is a Windows DLL that Lua loads with `package.loadlib`, so it works only on Windows x64.

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

memreader by Cpecific (MIT, https://github.com/Cpecific/twwh2-memreader), itself based on [squeek502/memreader](https://github.com/squeek502/memreader). memreader Plus keeps Cpecific's API and license; see `LICENSE.md`.

MinHook by Tsuda Kageyu (BSD 2-clause, https://github.com/TsudaKageyu/minhook), in `vendor/minhook/` with its `LICENSE.txt`. The only change is in `src/buffer.c`, where `MEMORY_BLOCK_SIZE` is 64 KB instead of 4 KB. One block therefore holds 1023 hook trampolines instead of 63.
