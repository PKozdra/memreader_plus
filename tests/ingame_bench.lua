local mr = memreader_plus
local ROUNDS = 20000
local MURMUR = '48 89 5C 24 08 44 8B CA 8B DA 41 C1 E9 02 41 BA ED 5E 54 4A'
local INTERNAL = {
	'48 89 5C 24 08 57 48 83 EC ?? 65 48 8B 04 25 58 00 00 00 48 8B F9 B9 ?? ?? ?? ?? 48 8B 10 8B 04 11 39 05 ?? ?? ?? ?? 7F ?? 48 8B CF E8 ?? ?? ?? ?? 48 8B D8 48 85 C0',
	'48 85 C9 74 ?? 53 48 83 EC ?? 48 8B D9 E8 ?? ?? ?? ?? 48 8B 05 ?? ?? ?? ?? 48 85 C0 75 ?? 48 83 C4 ?? 5B C3 33 D2 48 8B CB FF D0 EB ??',
	'40 53 48 83 EC ?? 48 8B D9 48 C7 41 08 00 00 00 00 48 C7 C0',
	'40 53 48 83 EC ?? 48 8B 59 08 48 8D 05 ?? ?? ?? ?? 48 3B D8 74 ?? 48 8B',
	'40 53 48 83 EC ?? 48 8B D9 4C 8B C2 33 C9 48 89',
	'48 8B C4 48 89 58 10 55 56 57 41 54 41 55 41 56 41 57 48 83 EC ?? 44 8B 69 1C 4D 8B E0 4C 89 40 18 48 8B F2 33 C0 4C 8B F1',
	'E8 ?? ?? ?? ?? 48 8D 55 E7 48 8D 4D 77 E8 ?? ?? ?? ?? 45 33 C0 48 8B D0 E8 ?? ?? ?? ?? 84 C0 75 08 83 CB FF E9 ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 8D 55 E7 48 89 7D 27 48 8D 4D 77 48 89 7D 2F 40 88 7D 37 E8 ?? ?? ?? ?? 4C 8D 4D 27 4C 8B C0 48 8D 55 F7 E8 ?? ?? ?? ?? 48 8B 75 F7',
	'E8 ?? ?? ?? ?? 48 8B 58 08 E8 ?? ?? ?? ?? 8B 48 04 48 C1 E1 05 48 03 48 08 48 3B D9 0F 85',
	MURMUR,
}

local lines = {}
local function report(label, value, unit)
	lines[#lines + 1] = ('%-28s %8.1f %s'):format(label, value, unit)
end

local function time(label, rounds, fn)
	local start = mr.ticks()
	for i = 1, rounds do
		fn(i)
	end
	report(label, mr.elapsed_us(start) * 1000 / rounds, 'ns')
end

local data = mr.alloc(4096)
for i = 0, 255 do
	mr.write(data, i * 4, mr.uint32(i))
end
mr.write(data, 1024, mr.uint32(5))
mr.write(data, 1028, mr.uint32(5))
mr.write(data, 1032, mr.add(data, 1040))
mr.write(data, 1040, 'hello\0')
local LAYOUT = { a = { 0, 'uint32' }, b = { 4, 'float' }, c = { 8, 'pointer' }, d = { 12, 'uint32', true } }

time('read_uint32 number', ROUNDS, function()
	mr.read_uint32(data, 8)
end)
time('read_uint32 exact, same', ROUNDS, function()
	mr.read_uint32(data, 8, true)
end)
time('read_pointer', ROUNDS, function()
	mr.read_pointer(data, 1032)
end)
time('read_string', ROUNDS, function()
	mr.read_string(data, 1024)
end)
time('read_struct 4 fields', ROUNDS, function()
	mr.read_struct(data, 0, LAYOUT)
end)

local start = mr.ticks()
local murmur, count = mr.find_pattern(MURMUR)
report('find_pattern murmur', mr.elapsed_us(start) / 1000, 'ms')
assert(count == 1, 'murmur not found')

start = mr.ticks()
for _, pattern in ipairs(INTERNAL) do
	mr.find_pattern(pattern)
end
report('find_pattern x' .. #INTERNAL, mr.elapsed_us(start) / 1000, 'ms')

if mr.find_patterns then
	start = mr.ticks()
	local _, counts = mr.find_patterns(INTERNAL)
	report('find_patterns ' .. #INTERNAL, mr.elapsed_us(start) / 1000, 'ms')
	local found = {}
	for i = 1, #counts do
		found[i] = counts[i]
	end
	lines[#lines + 1] = 'counts ' .. table.concat(found, ' ')
end

local text = mr.alloc(32)
mr.write(text, 0, 'wh2_main_hef_bow_arrow')
local HASH = 'uint32(pointer, uint32)'
local function hash_calls()
	local begin = mr.ticks()
	for _ = 1, ROUNDS do
		mr.call(murmur, HASH, text, 22)
	end
	return mr.elapsed_us(begin) * 1000 / ROUNDS
end
local plain = hash_calls()
local function pass(data_pointer, length)
	return mr.hook_next(murmur, data_pointer, length)
end
mr.hook(murmur, HASH, pass)
local hooked = hash_calls()
mr.unhook(murmur, pass)
report('call murmur', plain, 'ns')
report('hook + hook_next overhead', hooked - plain, 'ns')
return table.concat(lines, '\n')
