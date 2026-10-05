local lines = {}
local failures = 0
local function say(s)
	lines[#lines + 1] = s
	if ModLog then ModLog('[mrp_smoke] ' .. s) end
end
local function check(ok, what)
	if not ok then failures = failures + 1 end
	say((ok and 'ok   ' or 'FAIL ') .. what)
end

local MURMUR = '48 89 5C 24 08 44 8B CA 8B DA 41 C1 E9 02 41 BA ED 5E 54 4A'
local DB_ROOT = '48 8B 0D ?? ?? ?? ?? 4C 8B C0 48 8B 91 ?? ?? ?? ?? 48 8B CB E8 ?? ?? ?? ?? 48 85 C0 74 ?? 48 8B 0D ?? ?? ?? ?? 48 89 81'
local KEY_MAP_AND_NAME = '48 8D 41 28 48 89 02 48 8B 41 58 49 89 00 C3'
local RECORD_INDEX = '48 89 5C 24 10 48 89 6C 24 18 56 57 41 56 48 83 EC 30 48 8D 71 28 4C 8B F2 8B 5E 1C 48 8B E9 83 EB 01'
local DB_SLOTS, DB_SLOT_SIZE, DB_LOADED = 1812, 0x38, 0x19d4e

local mr = _G.memreader_plus

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

local function check_globals()
	check(_G.memreader == mr, '_G.memreader is memreader Plus')
	check(package.loaded['twwh3-memreader'] == mr, "package.loaded['twwh3-memreader'] is ours")
	check(mr.free == nil, 'no free: alloc memory lives until the mode ends')
	say('plus_version ' .. tostring(mr.plus_version) .. ', version ' .. tostring(mr.version))
end

local function check_reads()
	check(mr.read(mr.base, 0, 2) == 'MZ', 'read exe header')
	local lfanew = mr.read_int32(mr.base, 0x3C)
	check(mr.read(mr.base, lfanew, 4) == 'PE\0\0', 'PE signature at e_lfanew')
	check(#mr.read(mr.base, 0, 4096) == 4096, '4 KB read (crashes the original memreader)')
	check(not pcall(mr.read_uint32, mr.pointer('\16\0\0\0\0\0\0\0'), 0), 'bad address is a Lua error')
	local p = mr.alloc(24)
	mr.write(p, 0, '\254\255\255\255\255\255\255\255' .. string.rep('\255', 8) .. '\0\0\0\0\0\0\4\64')
	check(mr.tostring(mr.read_int64(p, 0)) == '-2', 'read_int64')
	check(mr.tostring(mr.read_uint64(p, 8)) == '18446744073709551615', 'read_uint64')
	check(mr.read_double(p, 16) == 2.5, 'read_double')
	mr.write(p, 0, mr.uint32(1234567))
	local keyed = { [mr.uint32(1234567)] = true }
	check(mr.read_uint32(p, 0, true) == mr.uint32(1234567) and keyed[mr.read_uint32(p, 0, true)], 'interned values')
end

local function check_bulk_reads()
	local header = mr.read_struct(mr.base, 0, { mz = { 0, 'uint16' }, lfanew = { 0x3C, 'int32' }, start = { 0, 'address' } })
	check(header.mz == 0x5A4D and header.lfanew > 0 and header.start == mr.base, 'read_struct on the PE header')

	local vector = mr.alloc(16 + 12)
	mr.write(vector, 0, mr.uint32(3))
	mr.write(vector, 4, mr.uint32(3))
	mr.write(vector, 8, mr.add(vector, 16))
	for i = 0, 2 do
		mr.write(vector, 16 + i * 4, mr.int32((i + 1) * 10))
	end
	local numbers = mr.read_vector(vector, 0, { 0, 'int32' }, 4)
	check(#numbers == 3 and numbers[1] == 10 and numbers[3] == 30, 'read_vector')

	local list, first, second = mr.alloc(0x18), mr.alloc(0x18), mr.alloc(0x18)
	mr.write(list, 0, mr.uint32(2))
	mr.write(list, 8, second)
	mr.write(list, 0x10, first)
	mr.write(first, 8, second)
	mr.write(first, 0x10, mr.uint32(7))
	mr.write(second, 0, first)
	mr.write(second, 8, mr.add(list, 8))
	mr.write(second, 0x10, mr.uint32(9))
	local values = mr.read_list(list, 0, { 0x10, 'uint32' })
	check(#values == 2 and values[1] == 7 and values[2] == 9, 'read_list')

	local text = mr.alloc(16)
	mr.write(text, 0, 'hello' .. string.rep('\0', 10) .. '\133')
	check(mr.read_struct(text, 0, { s = { 0, 'string' } }).s == 'hello', 'inline CA string field')
	mr.write(first, 0, text)
	check(mr.read_chain(first, 0) == text and mr.read_chain(list, 0x10, 0) == text, 'read_chain')
end

local function find_projectiles()
	local root, count = mr.find_pattern(DB_ROOT)
	if count ~= 1 then return nil, 'database pattern matched ' .. count .. ' times' end
	local app = mr.add(mr.add(root, 7), mr.read_int32(root, 3, true))
	local db = mr.read_pointer(mr.read_pointer(app, 0), mr.read_int32(root, 13, true))
	if mr.read_uint8(db, DB_LOADED) == 0 then return nil, 'database not loaded yet' end
	local key_map_and_name = mr.find_pattern(KEY_MAP_AND_NAME)
	for i = 0, DB_SLOTS - 1 do
		local t = mr.read_pointer(db, i * DB_SLOT_SIZE)
		if not mr.is_null(t) and mr.read_chain(t, 0, 0) == key_map_and_name then
			if mr.read_string(mr.read_pointer(t, 0x58), 0) == 'projectiles' then return t end
		end
	end
	return nil, 'no projectiles table'
end

local function check_hook(murmur, text, length, run_game_code)
	local HASH = 'uint32(pointer, uint32)'
	local info = mr.hook_info(murmur)
	if info and info.attached then mr.unhook(murmur) end
	local ours = 0
	mr.hook(murmur, HASH, function(data, size)
		if mr.eq(data, text) then
			ours = ours + 1
			return 7
		end
		return mr.call(mr.hook_info(murmur).original, HASH, data, size)
	end)
	info = mr.hook_info(murmur)
	check(mr.tostring(mr.call(murmur, HASH, text, length)) == '7', 'hook replaces the result for our text')
	check(mr.tostring(mr.call(info.original, HASH, text, length)) == '1628994413', 'hook original gives the real hash')
	local keys, changed = run_game_code()
	info = mr.hook_info(murmur)
	check(changed == 0 and info.attached and not info.error, 'game code through a hooked function is unchanged')
	say('hook murmur: ' .. info.calls .. ' callback calls (' .. ours .. ' ours) for ' .. keys .. ' record_index calls')
	mr.unhook(murmur)
	check(mr.tostring(mr.call(murmur, HASH, text, length)) == '1628994413', 'unhook runs the original again')
end

local MURMUR_9_0_1 = 0x4df770

local function check_call()
	local murmur, count = mr.find_pattern(MURMUR)
	if count == 0 and mr.hook_info(mr.add(mr.base, MURMUR_9_0_1)) then
		murmur, count = mr.add(mr.base, MURMUR_9_0_1), 1
	end
	if count ~= 1 then
		say('skip call: murmur pattern matched ' .. count .. ' times (not 9.0.1.0?)')
		return
	end
	local key = 'wh2_main_hef_bow_arrow'
	local text = mr.alloc(#key + 1)
	mr.write(text, 0, key)
	check(mr.tostring(mr.call(murmur, 'uint32(pointer, uint32)', text, #key)) == '1628994413', 'call murmur_hash3_32')
	local ok, err = pcall(mr.call, mr.pointer('\16\0\0\0\0\0\0\0'), 'void()')
	check(not ok and err:match('refused') ~= nil, 'call of an address outside the exe is refused')
	check(not pcall(mr.call, murmur, 'uint32(pointer, uint32)', text, 0x61187b6d), 'call refuses an inexact number')
	check(not pcall(mr.call, murmur, 'uint32(pointer, uint32)', key, #key), 'call refuses text as a pointer')
	if mr.read_uint8(murmur, -1) == 0xCC then
		ok, err = pcall(mr.call, mr.sub(murmur, 1), 'void()')
		check(not ok and err:match('%(breakpoint%)') ~= nil, 'call into int3 padding is a Lua error')
	end

	local projectiles, reason = find_projectiles()
	local record_index = mr.find_pattern(RECORD_INDEX)
	if not projectiles or not record_index then
		say('skip record_index: ' .. tostring(reason or 'pattern not found'))
		return
	end
	local keys = mr.read_list(projectiles, 0x28, { 0, 'struct', { key = { 0x10, 'string' }, row = { 0x20, 'uint32' } } })
	local wrong = 0
	for _, k in ipairs(keys) do
		if mr.tonumber(mr.call(record_index, 'uint32(pointer, pointer)', projectiles, ca_string(k.key))) ~= k.row then wrong = wrong + 1 end
	end
	check(#keys > 0 and wrong == 0, 'call record_index agrees with read_list on ' .. #keys .. ' projectile keys')
	check_hook(murmur, text, #key, function()
		local changed = 0
		for _, k in ipairs(keys) do
			if mr.tonumber(mr.call(record_index, 'uint32(pointer, pointer)', projectiles, ca_string(k.key))) ~= k.row then changed = changed + 1 end
		end
		return #keys, changed
	end)
end

if not mr then
	check(false, 'memreader_plus loaded')
else
	check_globals()
	check_reads()
	check_bulk_reads()
	check_call()
	if cm and cm.get_local_faction_name then
		local faction = cm:get_faction(cm:get_local_faction_name(true))
		local leader = faction and faction:has_faction_leader() and faction:faction_leader()
		if leader then
			local p = mr.ud_topointer(leader)
			say('faction leader interface ' .. mr.tostring(p) .. ', object ' .. mr.tostring(mr.read_pointer(p, 0x10)))
		end
	end
end
say(failures == 0 and 'PASS' or ('FAILED ' .. failures))
local text = table.concat(lines, '\n')
if console_print then
	console_print(text)
else
	print(text)
end
return text
