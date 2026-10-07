local WORKSHOP_MR = ROOT .. '/../../workshop/2789863945_twwh3-memreader'
local failures = 0
local function check(cond, what)
	print((cond and 'ok   ' or 'FAIL ') .. what)
	if not cond then failures = failures + 1 end
end
ModLog = function(msg)
	print('  log: ' .. msg)
end

local real_loadfile = function(path)
	local f, err = io.open(path, 'rb')
	if not f then return nil, err end
	local src = f:read('*a')
	f:close()
	return loadstring(src, '@' .. path)
end
local PACK = ROOT .. '/dist/pack'
local VFS = { PACK, WORKSHOP_MR }
loadfile = function(path)
	if path:sub(1, 8) == '/script/' then
		local rel = path:sub(2)
		if not rel:match('%.lua$') then rel = rel .. '.lua' end
		for _, base in ipairs(VFS) do
			local f = io.open(base .. '/' .. rel, 'rb')
			if f then
				f:close()
				return real_loadfile(base .. '/' .. rel)
			end
		end
		return nil, 'not in VFS: ' .. path
	end
	return real_loadfile(path)
end

local function run_mod(path)
	local chunk, err = real_loadfile(path)
	assert(chunk, err)
	local ok, perr = pcall(chunk)
	check(ok, 'ran ' .. path:gsub('.*/script/', 'script/') .. (ok and '' or (': ' .. tostring(perr))))
end
local function exists(name)
	local f = io.open(name, 'rb')
	if f then f:close() end
	return f ~= nil
end

local function context_script_env(listeners)
	local model = {
		turn_number = function()
			return 42
		end,
		campaign_type = function()
			return 'sp'
		end,
	}
	local manager = {
		model = function()
			return model
		end,
		get_campaign_name = function()
			return 'main_warhammer'
		end,
		get_difficulty = function()
			return 'hard'
		end,
		get_local_faction_name = function()
			return 'wh_a'
		end,
		get_human_factions = function()
			return { 'wh_a', 'wh_b' }
		end,
	}
	local core = {
		is_campaign = function()
			return true
		end,
		is_battle = function()
			return false
		end,
		add_listener = function(_, _, event, _, callback)
			listeners[event] = callback
		end,
		event_callback = function(_, eventname, context)
			if listeners[eventname] then listeners[eventname](context) end
		end,
	}
	return setmetatable({ core = core, cm = manager }, { __index = _G }), core
end

local function fill_crash_context(mr)
	local listeners = {}
	local chunk = assert(real_loadfile(PACK .. '/script/_lib/mod/memreader_plus_context.lua'))
	local env, core = context_script_env(listeners)
	local faction = {
		faction = function()
			return {
				name = function()
					return 'wh_c'
				end,
			}
		end,
	}
	setfenv(chunk, env)
	chunk()
	listeners.FirstTickAfterWorldCreated()
	core:event_callback('FactionTurnStart', faction)
	for _ = 1, 3 do
		core:event_callback('CharacterTurnStart', faction)
	end
	local block = mr.alloc(16)
	for offset = 0, 4, 4 do
		mr.write(block, offset, mr.uint32(7))
	end
	mr.set_crash_context('temp', 'removed again')
	mr.set_crash_context('temp')
	mr.set_crash_context('note', 'first' .. string.char(10) .. 'second')
	check(listeners.WorldStartRound ~= nil, 'the context script listens for every round')
end

CHANGED = {
	['uint8(bytes)'] = 'uint8:7',
	['add(p,-16)'] = 'pointer:0000000000000000',
	['div(int32(-8),2)'] = 'int32:-4',
	['eq(p,16)'] = 'true',
	['gt(uint8(5),1)'] = 'true',
	['gt(int32(-1),5)'] = 'false',
	['tonumber(uint8)'] = '9',
	['tonumber(int32(-1))'] = '-1',
	['offset uint8'] = '144',
	['type(modules entry)'] = 'bytes:7461626C65',
	['write read-only page'] = "error: bad argument #1 to 'write' (refused: Plus writes only to the game's exe and to data memory, not to other modules, executable memory or the exe's headers and import or export tables)",
}
FIXED = {
	['read(2048)'] = '2048',
	['read_string long'] = '1500',
	['write boolean'] = 'uint32:16843009',
	['write number'] = 'uint32:1069547520',
	['write bytes'] = 'uint32:513',
	['write nil'] = 'error: passed invalid argument type',
	['div(uint32,0)'] = 'error: attempt to divide by zero',
	['ud_topointer(5)'] = "error: bad argument #1 to 'ud_topointer' (userdata expected, got number)",
	['ud_topointer(value)'] = 'pointer:0000000000000005',
	['read_string inline'] = 'bytes:68656C6C6F',
	['read_string inline 15'] = 'bytes:6162636465666768696A6B6C6D6E6F',
	['read_string inline wide'] = 'bytes:68006900',
	['read_string inline wide too long'] = 'error: not a CA string',
	['read_string pointer to inline'] = 'bytes:6869',
	['read_unistring inline'] = 'bytes:6869',
	['read_unistring heap'] = 'bytes:C581C3B364C5BA',
	['read_unistring empty'] = 'bytes:',
	['is_null(null forms)'] = 'true, true, true, true, true, true',
	['is_null(non-null forms)'] = 'false, false, false, false, false',
	['is_null(table)'] = "error: bad argument #1 to 'is_null' (pointer, number, bytes, false or nil expected, got table)",
	['div(min pointer,-1)'] = 'pointer:8000000000000000',
	['read(nan)'] = 'bytes:',
	['read(32 MiB)'] = 'error: cannot read more than 16777216 bytes at once',
	['read_string garbage length'] = 'error: cannot read more than 16777216 bytes at once',
	['createtable(1e9)'] = 'bytes:7461626C65',
	['read_rowidx above 16 MiB'] = '5592408',
	['read_rowidx(size 0)'] = 'error: row size must be positive',
	['ud_topointer(empty userdata)'] = "error: bad argument #1 to 'ud_topointer' (userdata too small to hold a pointer)",
	['ud_debug()'] = "error: bad argument #1 to 'ud_debug' (value expected)",
	['find_pattern(entry point)'] = 'true, 1',
	['find_pattern(missing)'] = 'nil, 0',
	['find_pattern(?? first)'] = "error: bad argument #1 to 'find_pattern' (pattern must start with a byte, not ??)",
	['find_pattern(bad hex)'] = "error: bad argument #1 to 'find_pattern' (expected hex bytes and ?? separated by spaces)",
	['find_pattern(too long)'] = 'error: pattern longer than 256 bytes',
	['find_pattern across a protection change'] = 'true, true',
	['find_patterns across a protection change'] = 'true, true',
	['find_patterns agrees with a plain search'] = 'true',
	['read unmapped'] = 'error: failed to read memory',
	['read of a guard page'] = 'false, false, true',
	['read_int64/uint64/double'] = 'int64:-2, uint64:18446744073709551615, 2.5, true',
	['int64/uint64 constructors'] = 'int64:-5, uint64:18446744073709551615, bytes:696E743634',
	['div(uint64 max,2)'] = 'uint64:9223372036854775807',
	['div(int64,uint64 max)'] = 'int64:0',
	['add(float,uint64 max)'] = 'true',
	['64-bit values and 8 bytes'] = 'true, int64:4294967296',
	['exact values are shared'] = 'true, bytes:686974, true, true',
	['shared value after a write into it'] = 'uint32:4242, false',
	['is_null(false)'] = 'true',
	['read_struct scalars'] = '1, 1.5, -1, true, bytes:6869, uint32:1, true',
	['read_struct pointers'] = 'bytes:707472, false, false, true',
	['read_vector structs'] = '3, 1, 20, -30',
	['read_vector pointers with NULL'] = '3, bytes:7661, false, bytes:7662',
	['read_vector nested and empty'] = '2, 1, 7, 2, 9, 0',
	['read_vector element budget'] = 'error: more than 131072 elements in one read',
	['read_vector missing stride'] = "error: bad argument #4 to 'read_vector' (number expected, got no value)",
	['read_list'] = '2, 7, 9, 3',
	['read_list broken link'] = 'error: [2]: broken list link',
	['read_list wrong size'] = 'error: list shorter than its size',
	['read_struct self-reference'] = 'false, true',
	['read_struct struct budget'] = 'false, true',
	['read_struct error path'] = 'error: items[1]: failed to read memory',
	['read_struct unknown type'] = "error: a: unknown field type 'uint33'",
	['read_struct bad third value'] = "error: a: 'string' takes no third value",
	['read_struct bad offset'] = 'error: a: offset must be a whole number from 0 to 16777215',
	['read_chain'] = 'true, nil, nil, nil, bytes:656E64',
	['read_chain big number offset'] = "error: bad argument #2 to 'read_chain' (offsets from 16777216 on lose precision as numbers, pass a typed value)",
	['read_chain unreadable'] = 'error: failed to read memory at offset #1',
	['call integers'] = 'int64:-12',
	['call pointer'] = 'true, pointer:0000000000000010',
	['call floats and doubles'] = '3.75, 0.75',
	['call mixed registers'] = '42.75',
	['call stack arguments'] = 'int64:12345678',
	['call mixed stack arguments'] = '1234571',
	['call 16 arguments'] = 'int64:16120',
	['call 17 arguments'] = "error: bad argument #2 to 'call' (more than 16 arguments)",
	['call booleans'] = 'true, false, int32:7, int32:3',
	['call result types'] = 'uint8:255, int8:-1, int32:-1, uint64:18446744073709551615, pointer:FFFFFFFFFFFFFFFF',
	['call void with alloc'] = '-9, 0',
	['call varargs'] = 'int32:6, bytes:3720322E353000',
	['call crash'] = 'false, true, true',
	['call outside the exe'] = 'false, true',
	['call Lua error inside'] = 'false, true, true',
	['call unknown type'] = "error: bad argument #2 to 'call' (unknown type 'int' in the signature)",
	['call no parentheses'] = "error: bad argument #2 to 'call' (expected '(' after the result type, found the end)",
	['call void argument'] = "error: bad argument #2 to 'call' ('void' is only a result type)",
	['call text after signature'] = "error: bad argument #2 to 'call' (expected the end after ')', found 'x')",
	['call argument count'] = 'error: the signature takes 2 arguments, got 1',
	['call argument type'] = "error: bad argument #3 to 'call' (number expected, got string)",
	['call NULL'] = "error: bad argument #1 to 'call' (function address is NULL)",
	['call exact integers'] = 'int64:16777215, int64:-16777215, int64:1628994413, uint64:1628994413',
	['call integer from 2^24'] = "error: bad argument #3 to 'call' (a plain number must be a whole number from -16777215 to 16777215; pass a typed value or bytes)",
	['call integer hash as number'] = "error: bad argument #3 to 'call' (a plain number must be a whole number from -16777215 to 16777215; pass a typed value or bytes)",
	['call integer not whole'] = "error: bad argument #3 to 'call' (a plain number must be a whole number from -16777215 to 16777215; pass a typed value or bytes)",
	['call integer NaN and inf'] = 'true, true',
	['call small integer edges'] = 'uint64:255, uint64:18446744073709551488, uint64:65535, uint64:18446744073709518848, uint64:0',
	['call uint8 300'] = "error: bad argument #3 to 'call' (300 does not fit uint8)",
	['call int8 -129'] = "error: bad argument #3 to 'call' (-129 does not fit int8)",
	['call uint32 -1'] = "error: bad argument #3 to 'call' (-1 does not fit uint32)",
	['call typed values are narrowed'] = 'uint64:44, uint64:18446744073709551615, uint64:4294967295, uint64:44, uint64:18446744073709551615',
	['call pointer forms'] = 'uint64:16, uint64:0',
	['call pointer as text'] = "error: bad argument #3 to 'call' (pointer expected: a pointer value, 8 bytes or nil; build a C string with alloc and write)",
	['call pointer as integer value'] = "error: bad argument #3 to 'call' (pointer expected: a pointer value, 8 bytes or nil; build a C string with alloc and write)",
	['call address as text'] = "error: bad argument #1 to 'call' (pointer expected: a pointer value, 8 bytes or nil; build a C string with alloc and write)",
	['call stack alignment'] = 'uint64:0, uint64:0',
	['call breakpoint'] = 'error: the called function crashed at <code> (breakpoint); the game may be unstable now',
	['call illegal instruction'] = 'error: the called function crashed at <code> (illegal instruction); the game may be unstable now',
	['call division by zero'] = 'error: the called function crashed at <code> (integer division by zero); the game may be unstable now',
	['call exceptions handled inside'] = 'int32:9, int32:5',
	['call nested callbacks'] = 'int64:14, false, true, true',
	['call signature with tabs'] = 'uint64:7',
	['call upper case type'] = "error: bad argument #2 to 'call' (unknown type 'UINT64' in the signature)",
	['call Ghidra types'] = "error: bad argument #2 to 'call' (unknown type 'undefined8' in the signature)",
	['call char*'] = "error: bad argument #2 to 'call' (unknown type 'char*' in the signature)",
	['call trailing comma'] = "error: bad argument #2 to 'call' (expected a type, found ')')",
	['call 16 arguments and trailing comma'] = "error: bad argument #2 to 'call' (expected a type, found ')')",
	['call empty signature'] = "error: bad argument #2 to 'call' (expected a type, found the end)",
	['call missing comma'] = "error: bad argument #2 to 'call' (expected ',' or ')', found 'uint64)')",
	['call one argument missing'] = 'error: the signature takes 1 argument, got 0',
	['hook unhook then error'] = 'int32:12, false',
	['hook signature while running'] = 'int32:7, false, true',
	['hook_next then error'] = 'int32:12, 1',
	['void hook_next then error'] = '101',
	['hook limit while running'] = 'true',
	['alloc'] = 'true, true, true',
	['alloc size'] = "error: bad argument #1 to 'alloc' (size must be from 1 to 16777216 bytes)",
	['game_alloc and game_free'] = 'true, 1, 0',
	['game_alloc size'] = "error: bad argument #1 to 'game_alloc' (size must be from 1 to 67108864 bytes)",
	['game_free NULL'] = "error: bad argument #1 to 'game_free' (pointer is NULL)",
	['game_free deferred'] = '1',
	['patch code'] = 'int32:1, bytes:B801000000, int32:2, bytes:B802000000, int32:1',
	['patch mismatch'] = 'nil, bytes:B801000000',
	['patch read-only code'] = 'true, bytes:4142, true',
	['function_start'] = 'true, true, true, true',
	['function_start outside a function'] = 'true',
	['function_start outside the exe'] = "error: bad argument #1 to 'function_start' (address is outside the game's exe)",
	['relocate_field'] = 'true, bytes:4142, true',
	['relocate_field all or nothing'] = 'nil, 2, true',
	['relocate_field already applied'] = 'true, true',
	['relocate_field no sites'] = "error: bad argument #1 to 'relocate_field' (no sites)",
	['relocate_field site lengths'] = 'error: site 1: must be as long as the expected bytes',
	['patch text address'] = "error: bad argument #1 to 'patch' (pointer expected: a pointer value, 8 bytes or nil; build a C string with alloc and write)",
	['patch outside the exe'] = "error: bad argument #1 to 'patch' (address is outside the game's exe)",
	['patch lengths'] = "error: bad argument #3 to 'patch' (must be as long as the expected bytes)",
	['patch empty'] = "error: bad argument #2 to 'patch' (must be 1 to 4096 bytes)",
	['vector_insert'] = 'bytes:352031302031352032302033302030, 6, 15',
	['vector_insert into an empty vector'] = 'bytes:37, 4',
	['vector_erase'] = 'bytes:312035, 2, 0',
	['vector_reserve'] = 'true, false, 100, bytes:312032',
	['vector stride'] = "error: bad argument #3 to 'vector_insert' (stride must be a whole number from 1 to 4096)",
	['vector position'] = "error: bad argument #4 to 'vector_insert' (position must be a whole number from 1 to 2)",
	['vector element size'] = "error: bad argument #5 to 'vector_insert' (must be 8 bytes, the stride)",
	['vector broken header'] = 'error: not a CA vector (capacity 1, size 2)',
	['vector_erase empty'] = 'error: the vector is empty',
	['vector_erase count'] = "error: bad argument #5 to 'vector_erase' (count must be a whole number from 1 to 1)",
	['string_set'] = 'true, 1, bytes:73686F7274, 0',
	['unistring_set'] = 'true, 1, bytes:6F6B, 0',
	['string_set zero byte'] = "error: bad argument #3 to 'string_set' (must not contain a zero byte)",
	['string_set not a string'] = 'error: not a CA string',
	['unhook with a match count'] = 'false, true, true, false',
	['read_pack_file'] = 'bytes:68656C6C6F2066726F6D2061207061636B, true, 0',
	['read_pack_file binary and empty'] = 'bytes:000102FF, true, 0',
	['read_pack_file missing'] = 'nil, 0',
	['pack_file_exists'] = 'true, false',
	['read_pack_file empty path'] = "error: bad argument #1 to 'read_pack_file' (must be a path of 1 to 1024 bytes without a zero byte)",
	['read_pack_file disk paths'] = '5, false',
	['pack_file_exists drive'] = "error: bad argument #1 to 'pack_file_exists' (must be a path inside the packs: no drive letter, no leading \\\\ and no .. part)",
	['pack_file_exists zero byte'] = "error: bad argument #1 to 'pack_file_exists' (must be a path of 1 to 1024 bytes without a zero byte)",
	['map_add_key'] = 'true, false, true, true, true, 4, 5, nil, 3',
	['map_add_key one bucket'] = 'bytes:613D3020623D31, 0, 1',
	['map_find_key hash'] = 'true',
	['map_remove_key'] = 'true, true, false, bytes:623D3220643D34, nil, 2, 4, 2',
	['map_remove_key last'] = '0, true, true, true',
	['map keys own their strings'] = '2, 1, 0',
	['map not a map'] = 'error: not a CA unordered map (bucket capacity 0, size 0)',
	['map_add_key index'] = "error: bad argument #3 to 'map_add_key' (index must be a whole number from 0 to 16777215)",
	['list_insert'] = 'bytes:30203120322033, 1, 4',
	['list_erase'] = 'bytes:3120342035, bytes:34, 0, true, true',
	['list_insert position'] = "error: bad argument #3 to 'list_insert' (position must be a whole number from 1 to 1)",
	['list_insert empty value'] = "error: bad argument #4 to 'list_insert' (the value must be 1 to 4096 bytes)",
	['list_erase empty'] = 'error: the list is empty',
	['list broken links'] = "error: the list's links are broken at node 2",
	['alloc limit'] = 'error: alloc holds at most 16777216 bytes per mode (<n> in use); memory returns at the next mode switch, so reuse buffers',
	['alloc limit is exact'] = 'false',
}

local SNAPSHOT = ROOT .. '/tests/api_cases.expected.tsv'
local function read_snapshot()
	local f = assert(io.open(SNAPSHOT, 'rb'))
	local text = f:read('*a')
	f:close()
	local rows = {}
	for line in text:gmatch('[^\n]+') do
		local name, value = line:gsub('\r$', ''):match('^([^\t]*)\t(.*)$')
		rows[#rows + 1] = { name = name, value = value }
	end
	return rows
end
local function write_snapshot(rows)
	local lines = {}
	for i, r in ipairs(rows) do
		assert(not (r.name .. r.value):find('[\t\r\n]'), 'snapshot value with a tab or newline: ' .. r.name)
		lines[i] = r.name .. '\t' .. r.value
	end
	local f = assert(io.open(SNAPSHOT, 'wb'))
	f:write(table.concat(lines, '\n'), '\n')
	f:close()
end
local function check_against_snapshot(rows)
	local snapshot = read_snapshot()
	local mismatches = #rows == #snapshot and 0 or 1
	if mismatches > 0 then print('  DIFF case count: ' .. #rows .. ' vs snapshot ' .. #snapshot) end
	for i, r in ipairs(rows) do
		local s = snapshot[i]
		if not s or s.name ~= r.name or s.value ~= r.value then
			mismatches = mismatches + 1
			print('  DIFF ' .. r.name)
			print('       snapshot: ' .. tostring(s and s.value))
			print('       plus:     ' .. r.value)
		end
	end
	return mismatches
end
local function check_fixes(rows)
	for _, r in ipairs(rows) do
		check(r.value == FIXED[r.name], 'fixed: ' .. r.name .. ' = ' .. r.value)
	end
end

local OURS = PACK .. '/script/_lib/mod/memreader_plus.lua'
local THEIRS = WORKSHOP_MR .. '/script/_lib/mod/memreader.lua'

local function api(mr, label, small_only)
	local r = {}
	local function rec(k, v)
		r[#r + 1] = k .. '=' .. tostring(v)
	end
	rec('version', mr.version)
	rec('base_is_userdata', type(mr.base) == 'userdata')
	rec('mz', mr.read(mr.base, 0, 2))
	rec('uint16_mz', mr.read_uint16(mr.base, 0))
	local lfanew = mr.read_int32(mr.base, 0x3C)
	rec('pe_sig', mr.read(mr.base, lfanew, 4) == 'PE\0\0')
	if not small_only then
		local big = mr.read(mr.base, 0, 2048)
		rec('big_read', #big == 2048 and big:sub(1, 2) == 'MZ')
	end
	rec('read_1023', #mr.read(mr.base, 0, 1023))
	rec('eq_add', mr.eq(mr.add(mr.base, 0x10), mr.add(mr.base, 0x10)))
	rec('tostring_base', mr.tostring(mr.base))
	rec('ud_topointer', type(mr.ud_topointer(io.stdout)) == 'userdata')
	for _, line in ipairs(r) do
		print('  ' .. label .. ' ' .. line)
	end
	return r
end

if SCENARIO == 'api' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	check(mr ~= nil, 'memreader_plus loaded')
	check(_G.memreader == mr, '_G.memreader is memreader Plus')
	check(mr.version == 1.2, 'version stays 1.2 for compatibility')
	check(type(mr.plus_version) == 'string', 'plus_version = ' .. tostring(mr.plus_version))
	local r = api(mr, 'plus')
	check(r[3] == 'mz=MZ' and r[5] == 'pe_sig=true' and r[6] == 'big_read=true', 'reads work, incl. >= 1 KB (fixed malloc)')
	run_mod(OURS)
	check(_G.memreader_plus == mr, 'second load is a no-op')
elseif SCENARIO == 'plus_first' then
	run_mod(OURS)
	local plus = _G.memreader_plus
	run_mod(THEIRS)
	check(_G.memreader == plus, "Cpecific's loader adopted memreader Plus")
	check(not exists('twwh3-memreader.dll'), "Cpecific's DLL was never written")
elseif SCENARIO == 'cpecific_first' then
	run_mod(THEIRS)
	local theirs = _G.memreader
	check(theirs ~= nil and theirs.plus_version == nil, "Cpecific's memreader loaded")
	check(exists('twwh3-memreader.dll'), "Cpecific's DLL written")
	local a = api(theirs, 'theirs', true)
	run_mod(OURS)
	local plus = _G.memreader_plus
	check(_G.memreader == plus and plus ~= theirs, 'memreader Plus replaced it in _G.memreader')
	check(package.loaded['twwh3-memreader'] == plus, "package.loaded['twwh3-memreader'] is ours")
	local b = api(plus, 'plus', true)
	local same = #a == #b
	for i = 1, #a do
		same = same and a[i] == b[i]
	end
	check(same, 'same API results from both DLLs (reads < 1 KB)')
	check(#plus.read(plus.base, 0, 2048) == 2048, 'memreader Plus survives the 2 KB read')

	local cases = dofile(ROOT .. '/tests/api_cases.lua')
	local old, new = cases.shared(theirs), cases.shared(plus)
	local expected_rows = {}
	local mismatches = 0
	for i, r in ipairs(new) do
		local expected = CHANGED[r.name] or old[i].value
		expected_rows[i] = { name = r.name, value = expected }
		if r.value ~= expected then
			mismatches = mismatches + 1
			print('  DIFF ' .. r.name)
			print('       memreader: ' .. old[i].value)
			print('       plus:      ' .. r.value)
			print('       expected:  ' .. expected)
		end
	end
	check(mismatches == 0, #new .. ' API cases match memreader, except the listed intended changes')
	if os.getenv('API_SNAPSHOT') then
		write_snapshot(expected_rows)
		print('  wrote ' .. SNAPSHOT)
	end
	check(check_against_snapshot(expected_rows) == 0, 'tests/api_cases.expected.tsv is current')
	check_fixes(cases.fixes(plus))
	local function feed(make)
		local p = make.add(make.base, 0x3C)
		local header = plus.read_struct(p, 0, { offset = { 0, 'int32' }, raw = { 0, 'uint32', true } })
		local results = {
			plus.type(p),
			plus.tostring(p),
			plus.read_int32(p, 0),
			plus.read_uint16(plus.base, make.uint32(2)),
			plus.tostring(plus.add(p, make.uint8(4))),
			plus.tostring(plus.sub(p, make.pointer(plus.read(plus.base, 0, 0) .. string.rep('\0', 8)))),
			tostring(plus.eq(p, plus.add(plus.base, 0x3C))),
			tostring(plus.gt(make.int32(-1), 5)),
			plus.tostring(plus.div(make.int32(-8), 2)),
			plus.tonumber(make.int32(-1)),
			tostring(plus.is_null(make.pointer(string.rep('\0', 8)))),
			header.offset,
			plus.tostring(header.raw),
			plus.tostring(plus.read_chain(make.base, make.uint32(0))),
			plus.tostring(plus.call(plus.pointer(test_function('pointer_plus')), 'pointer(pointer, int64)', p, make.int32(-4))),
			plus.tostring(plus.call(plus.pointer(test_function('add_integers')), 'int64(int64, int32, uint8)', make.uint32(7), make.int16(-2), make.uint8(1))),
		}
		return table.concat(results, ' | ')
	end
	local from_theirs, from_plus = feed(theirs), feed(plus)
	print('  theirs -> plus: ' .. from_theirs)
	print('  plus   -> plus: ' .. from_plus)
	check(from_theirs == from_plus, "values made by Cpecific's DLL work in ours like our own")
	check(not rawequal(theirs.uint32(7), plus.uint32(7)) and plus.eq(theirs.uint32(7), plus.uint32(7)), 'his values are separate objects, equal by eq')
elseif SCENARIO == 'api_cases' then
	run_mod(OURS)
	local plus = _G.memreader_plus
	local cases = dofile(ROOT .. '/tests/api_cases.lua')
	local rows = cases.shared(plus)
	check(check_against_snapshot(rows) == 0, #rows .. ' API cases match tests/api_cases.expected.tsv')
	check_fixes(cases.fixes(plus))
elseif SCENARIO == 'heap' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	if PASS == 1 then
		local before = test_heap_blocks()
		local block = mr.game_alloc(64)
		mr.game_free(mr.game_alloc(32), true)
		mr.game_free(block, true)
		check(test_heap_blocks() - before == 2, 'deferred game blocks stay until the Lua state closes')
		NEXT_PASS = failures == 0
	else
		check(test_heap_blocks() == 0, 'deferred game blocks were freed when the Lua state closed')
	end
elseif SCENARIO == 'call_cpp_exception' then
	io.stdout:setvbuf('no')
	run_mod(OURS)
	print('a C++ exception leaves the called function (expected to crash)')
	pcall(_G.memreader_plus.call, _G.memreader_plus.pointer(test_function('throw_out')), 'void()')
	print('did not crash')
	os.exit(0)
elseif SCENARIO == 'call_stack_overflow' then
	io.stdout:setvbuf('no')
	run_mod(OURS)
	print('the called function overflows the stack (expected to crash)')
	pcall(_G.memreader_plus.call, _G.memreader_plus.pointer(test_function('recurse')), 'int64(int64)', 0)
	print('did not crash')
	os.exit(0)
elseif SCENARIO == 'hook' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local function address(name)
		return mr.pointer(test_function(name))
	end
	local target, single, float, mixed, store =
		address('hook_target'), address('hook_single'), address('hook_float'), address('hook_mixed'), address('hook_store')
	local TARGET, SINGLE = 'int32(int32, int32)', 'int64(int64)'
	local function run(f, ...)
		local ok, result = pcall(f, ...)
		return ok and mr.tostring(result) or 'error: ' .. tostring(result):gsub('^.-:%d+: ', '')
	end
	local function hooked(a, b)
		return mr.tonumber(a) + mr.tonumber(b)
	end
	local function contains(text, part)
		return text ~= nil and string.find(text, part, 1, true) ~= nil
	end

	if PASS == 1 then
		check(mr.hook_depth() == 0, 'hook_depth is 0 outside callbacks')
		local start = mr.ticks()
		local later = mr.ticks()
		check(mr.type(start) == 'uint64' and not mr.gt(start, later), 'ticks are uint64 and never go back')
		local spent = mr.elapsed_us(start)
		check(type(spent) == 'number' and spent >= 0 and spent < 1000000, 'elapsed_us measures microseconds')
		check(not pcall(mr.elapsed_us, 5), 'elapsed_us refuses a plain number')
		check(mr.hook_info(target) == nil, 'hook_info of an address never hooked is nil')
		check(run(mr.call, target, TARGET, 1, 2) == '12', 'original result before hooking')

		mr.hook(target, TARGET, hooked)
		local info = mr.hook_info(target)
		check(run(mr.call, target, TARGET, 1, 2) == '3', 'the callback replaces the result')
		check(info.attached and mr.hook_info(target).calls == 1, 'hook_info counts the call')
		check(run(mr.call, info.original, TARGET, 1, 2) == '12', 'original skips the hook')
		check(contains(run(mr.hook, target, TARGET, hooked), 'this callback is already attached to'), 'the same callback twice is refused')
		check(
			contains(run(mr.hook, target, 'int32(int32)', hooked), 'is already hooked in this mode with a different signature'),
			'a different signature is refused'
		)
		local function plus_thousand(a, b)
			return mr.add(mr.hook_next(target, a, b), 1000)
		end
		mr.hook(target, TARGET, plus_thousand)
		check(run(mr.call, target, TARGET, 1, 2) == '1003', 'the newest callback runs first and hook_next runs the one below')
		check(mr.hook_info(target).callbacks == 2, 'hook_info counts the callbacks')
		mr.unhook(target, plus_thousand)
		check(run(mr.call, target, TARGET, 1, 2) == '3', 'unhook with a callback removes only that one')
		check(mr.hook_info(target).callbacks == 1, 'one callback left')
		check(contains(run(mr.hook_next, target, 1, 2), 'hook_next works only inside a callback of this address'), 'hook_next outside a callback is refused')
		mr.unhook(target)
		mr.hook(target, TARGET, function(a, b)
			return mr.hook_next(target, 5, 5)
		end)
		check(run(mr.call, target, TARGET, 1, 2) == '55', 'hook_next at the bottom calls the original with the given arguments')
		mr.unhook(target)
		mr.hook(target, TARGET, hooked)
		mr.hook(target, TARGET, function()
			error('top fails')
		end)
		check(run(mr.call, target, TARGET, 1, 2) == '3', 'a failing callback is skipped and the one below runs')
		check(
			mr.hook_info(target).callbacks == 1 and contains(mr.hook_info(target).error, 'top fails'),
			'the failing callback is detached: ' .. tostring(mr.hook_info(target).error)
		)
		mr.unhook(target)
		mr.hook(target, TARGET, function()
			error('bottom fails')
		end)
		mr.hook(target, TARGET, plus_thousand)
		check(run(mr.call, target, TARGET, 1, 2) == '1012', 'a failing callback below hook_next falls through to the original')
		check(mr.hook_info(target).callbacks == 1 and contains(mr.hook_info(target).error, 'bottom fails'), 'the failing lower callback is detached')
		mr.unhook(target)
		local once
		once = function(a, b)
			mr.unhook(target, once)
			return mr.add(mr.hook_next(target, a, b), 1)
		end
		mr.hook(target, TARGET, hooked)
		mr.hook(target, TARGET, once)
		check(run(mr.call, target, TARGET, 1, 2) == '4', 'a callback can unhook itself while running')
		check(run(mr.call, target, TARGET, 1, 2) == '3' and mr.hook_info(target).callbacks == 1, 'and is gone for the next call')
		mr.unhook(target)
		check(not mr.hook_info(target).attached, 'unhook detaches the callback')
		check(run(mr.call, target, TARGET, 1, 2) == '12', 'unhooked address runs the original')
		mr.hook(target, TARGET, function(a, b)
			return mr.add(mr.call(info.original, TARGET, a, b), 100)
		end)
		check(run(mr.call, target, TARGET, 1, 2) == '112', 'the callback calls the original')
		check(mr.hook_info(target).calls == 1, 'calls restart at 0 on a new hook')

		mr.hook(single, SINGLE, function(x)
			return mr.int64(-mr.tonumber(x))
		end)
		check(run(mr.call, address('call_directly'), 'int64(pointer, int64)', single, 5) == '65531', 'native callers go through the hook')
		check(run(mr.call, address('call_on_thread'), 'int64(pointer, int64)', single, 5) == '16', 'calls on another thread run the original')
		check(mr.hook_info(single).calls == 1, 'calls on another thread are not counted')
		check(mr.hook_info(single).other_thread_calls == 1, 'calls on another thread are counted apart')
		check(mr.hook_info(target).other_thread_calls == 0, 'no other-thread calls on a script-thread address')
		mr.unhook(single)
		local deepest = 0
		mr.hook(single, SINGLE, function(x)
			deepest = math.max(deepest, mr.hook_depth())
			if mr.tonumber(x) == 0 then return 0 end
			return mr.add(mr.call(single, SINGLE, mr.tonumber(x) - 1), 1)
		end)
		check(run(mr.call, single, SINGLE, 5) == '5', 'a callback can call its own hooked address')
		check(mr.hook_info(single).calls == 6, 'nested calls are counted')
		check(deepest == 6 and mr.hook_depth() == 0, 'hook_depth counts nested callbacks and returns to 0')

		mr.hook(float, 'float(float, float)', function(a, b)
			return a * b
		end)
		check(run(mr.call, float, 'float(float, float)', 1.5, 2.5) == '3.75', 'float arguments and result')

		local function hex_at(at, size)
			local bytes = mr.read(at, 0, size)
			local parts = {}
			for i = 1, size do
				parts[i] = string.format('%02X', bytes:byte(i))
			end
			return table.concat(parts, ' ')
		end
		local mixed_pattern = hex_at(mixed, 16)
		local found_before, count_before = mr.find_pattern(mixed_pattern)
		check(found_before == mixed and count_before >= 1, 'find_pattern finds the function before hooking')
		local seen
		mr.hook(mixed, 'double(int64, double, float, int32, int8, double)', function(...)
			seen = { ... }
			return mr.call(mr.hook_info(mixed).original, 'double(int64, double, float, int32, int8, double)', ...) + 0.5
		end)
		local result = mr.call(mixed, 'double(int64, double, float, int32, int8, double)', 1, 2, 3, 4, -5, 6)
		check(
			result == 123356.5
				and mr.tostring(seen[1]) == '1'
				and seen[2] == 2
				and seen[3] == 3
				and mr.tostring(seen[4]) == '4'
				and mr.tostring(seen[5]) == '-5'
				and seen[6] == 6,
			'mixed register and stack arguments reach the callback: ' .. tostring(result)
		)

		check(hex_at(mixed, 16) ~= mixed_pattern, 'hooking changed the first bytes')
		local found_after, count_after = mr.find_pattern(mixed_pattern .. ' ')
		check(found_after == mixed and count_after == count_before, 'find_pattern sees through our hook: ' .. tostring(count_after))
		local cell = mr.alloc(4)
		mr.hook(store, 'void(pointer, int32)', function(p, value)
			mr.call(mr.hook_info(store).original, 'void(pointer, int32)', p, mr.add(value, 10))
		end)
		mr.call(store, 'void(pointer, int32)', cell, 5)
		check(mr.read_int32(cell, 0) == 16, 'void hook')

		local keeper, leaf, float_leaf = address('call_keeping_registers'), address('leaf_add_one'), address('leaf_add_floats')
		local REGISTERS_SIZE = 152
		local registers = {}
		for i = 0, 5 do
			registers[#registers + 1] = { 'xmm' .. i, i * 16 }
			registers[#registers + 1] = { 'xmm' .. i .. ' high', i * 16 + 8 }
		end
		for i, name in ipairs({ 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11', 'rax' }) do
			registers[#registers + 1] = { name, 88 + i * 8 }
		end
		local function call_leaf(target)
			local bytes = {}
			for i = 1, REGISTERS_SIZE do
				bytes[i] = string.char((i * 37 + 11) % 256)
			end
			local before = table.concat(bytes)
			local saved = mr.alloc(REGISTERS_SIZE)
			mr.write(saved, 0, before)
			mr.call(keeper, 'void(pointer, pointer)', target, saved)
			local after = mr.read(saved, 0, REGISTERS_SIZE)
			local changed = {}
			for _, register in ipairs(registers) do
				local from = register[2] + 1
				if before:sub(from, from + 7) ~= after:sub(from, from + 7) then changed[#changed + 1] = register[1] end
			end
			return table.concat(changed, ', '), saved
		end
		local function leaf_result(saved)
			return mr.tostring(mr.read_uint64(saved, 144))
		end
		local function rcx_plus_one(saved)
			return mr.tostring(mr.add(mr.read_uint64(saved, 96), 1))
		end
		local changed, saved = call_leaf(leaf)
		check(changed == 'rax' and leaf_result(saved) == rcx_plus_one(saved), 'the unhooked leaf changes only rax')
		mr.hook(leaf, 'uint64(uint64)', function()
			return 42
		end)
		changed, saved = call_leaf(leaf)
		check(changed == 'rax' and leaf_result(saved) == '42', 'a callback result keeps every other volatile register: ' .. changed)
		mr.unhook(leaf)
		mr.hook(leaf, 'uint64(uint64)', function(x)
			return mr.hook_next(leaf, x)
		end)
		changed, saved = call_leaf(leaf)
		check(changed == 'rax' and leaf_result(saved) == rcx_plus_one(saved), 'hook_next to the original keeps every other volatile register: ' .. changed)
		mr.unhook(leaf)
		mr.hook(leaf, 'uint64(uint64)', function()
			error('fails')
		end)
		changed, saved = call_leaf(leaf)
		check(changed == 'rax' and leaf_result(saved) == rcx_plus_one(saved), 'a failing callback passes every register to the original: ' .. changed)
		mr.unhook(leaf)
		changed, saved = call_leaf(leaf)
		check(changed == 'rax' and leaf_result(saved) == rcx_plus_one(saved), 'an unhooked detour passes every register to the original: ' .. changed)
		check(call_leaf(float_leaf) == 'xmm0, rax', 'the unhooked float leaf changes only xmm0 and rax')
		mr.hook(float_leaf, 'float(float, float)', function()
			return 2.5
		end)
		changed, saved = call_leaf(float_leaf)
		check(changed == 'xmm0, rax' and mr.read_float(saved, 0) == 2.5, 'a float result keeps every other register and the high half of xmm0: ' .. changed)
		mr.unhook(float_leaf)
		mr.hook(float_leaf, 'float(float, float)', function(a, b)
			return mr.hook_next(float_leaf, a, b)
		end)
		changed = call_leaf(float_leaf)
		check(changed == 'xmm0, rax', 'float hook_next keeps every other register: ' .. changed)
		mr.unhook(float_leaf)

		mr.unhook(target)
		mr.hook(target, TARGET, function()
			error('boom')
		end)
		check(run(mr.call, target, TARGET, 1, 2) == '12', 'a failing callback falls back to the original')
		info = mr.hook_info(target)
		check(not info.attached and contains(info.error, 'boom'), 'the error is kept and the callback detached: ' .. tostring(info.error))
		check(mr.hook_depth() == 0, 'hook_depth is 0 after a failing callback')
		mr.hook(target, TARGET, function()
			return {}
		end)
		check(run(mr.call, target, TARGET, 1, 2) == '12', 'a wrong result type falls back to the original')
		check(contains(mr.hook_info(target).error, 'int32 expected, got table'), 'wrong result: ' .. mr.hook_info(target).error)
		mr.hook(target, TARGET, function() end)
		check(run(mr.call, target, TARGET, 1, 2) == '12', 'no result falls back to the original')
		check(mr.hook_info(target).error == 'the callback returned nothing, expected int32', 'no result: ' .. mr.hook_info(target).error)

		local function hook(...)
			mr.hook(...)
		end
		local refused = {
			{ run(hook, nil, TARGET, hooked), "error: bad argument #1 to 'hook' (address is NULL)" },
			{ run(hook, mr.base, TARGET, hooked), "error: bad argument #1 to 'hook' (refused: hook takes only read-only code in the game's exe)" },
			{ run(hook, target, 'int(int)', hooked), "error: bad argument #2 to 'hook' (unknown type 'int' in the signature)" },
			{ run(hook, target, TARGET, nil), "error: bad argument #3 to 'hook' (function expected, got nil)" },
		}
		for _, pair in ipairs(refused) do
			check(pair[1] == pair[2], 'refused: ' .. pair[1])
		end
		local hooking_thread, callback_thread
		local worker = coroutine.create(function()
			hooking_thread = coroutine.running()
			mr.hook(target, TARGET, function(a, b)
				callback_thread = coroutine.running()
				return hooked(a, b)
			end)
			coroutine.yield()
		end)
		coroutine.resume(worker)
		check(run(mr.call, target, TARGET, 1, 2) == '12', 'calls while the hooking thread is suspended run the original')
		coroutine.resume(worker)
		check(run(mr.call, target, TARGET, 1, 2) == '3', 'calls run the callback once the hooking thread can run')
		check(callback_thread == hooking_thread, 'the callback runs on the thread that called hook')
		mr.unhook(target)
		mr.hook(target, TARGET, hooked)
		check(run(mr.call, target, TARGET, 1, 2) == '3', 'attached before the state closes')
		local ROUNDS = 20000
		local function time_calls()
			local start = mr.ticks()
			for _ = 1, ROUNDS do
				mr.call(target, TARGET, 1, 2)
			end
			return mr.elapsed_us(start) * 1000 / ROUNDS
		end
		mr.unhook(target)
		local plain = time_calls()
		mr.hook(target, TARGET, hooked)
		local one = time_calls()
		mr.hook(target, TARGET, plus_thousand)
		local two = time_calls()
		mr.unhook(target)
		print(string.format('  timing: call %.0f ns, one callback +%.0f ns, two chained +%.0f ns', plain, one - plain, two - plain))
		mr.hook(target, TARGET, hooked)
		NEXT_PASS = failures == 0
	else
		local info = mr.hook_info(target)
		check(info and not info.attached, 'a new state starts with every callback detached')
		check(run(mr.call, target, TARGET, 1, 2) == '12', 'hooks from the closed state run the original')
		mr.hook(target, TARGET, hooked)
		check(run(mr.call, target, TARGET, 1, 2) == '3', 'the new state attaches again')
		check(mr.hook_info(target).calls == 1, 'calls restart in the new state')
	end
elseif SCENARIO == 'guard' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local function refused(f, ...)
		local ok, err = pcall(f, ...)
		return not ok and string.find(tostring(err), 'refused: ', 1, true) ~= nil
	end
	local function module_named(part)
		for m in mr.modules() do
			if string.find(m.name:lower(), part, 1, true) then return m end
		end
	end
	local function entry_point(base)
		local headers = mr.add(base, mr.read_int32(base, 0x3c))
		return mr.add(base, mr.read_uint32(headers, 0x28, true))
	end
	local function table_start(index)
		local headers = mr.add(mr.base, mr.read_int32(mr.base, 0x3c))
		return mr.add(mr.base, mr.read_uint32(headers, 0x18 + 0x70 + index * 8, true))
	end
	local system = module_named('kernel32.dll')
	local plus = module_named('memreader_plus')
	local target = mr.pointer(test_function('hook_target'))
	local TARGET = 'int32(int32, int32)'
	check(mr.code_cave == nil, 'code_cave is not part of the API')
	check(mr.hop_slots() > 0, 'the exe has int3 padding runs for far hooks')
	check(mr.commit_stack() == true, 'commit_stack commits the current thread stack')
	local function deep(n)
		if n == 0 then error('bottom') end
		local _, err = pcall(deep, n - 1)
		error(err, 0)
	end
	check(not pcall(deep, 150), 'Lua errors deep in the committed stack unwind')
	check(mr.commit_stack() == true, 'a second commit_stack keeps the stack as it is')
	check(system ~= nil and plus ~= nil, 'modules() lists a system DLL and Plus')

	check(refused(mr.call, system.base, 'void()'), 'call into a system DLL is refused')
	check(refused(mr.call, plus.base, 'void()'), "call into Plus's own module is refused")
	check(refused(mr.call, mr.alloc(16), 'void()'), 'call into alloc memory is refused')
	check(refused(mr.call, mr.base, 'void()'), "call into the exe's headers is refused")
	check(refused(mr.hook, entry_point(system.base), 'void()', function() end), "hook on a system DLL's code is refused")
	check(refused(mr.write, system.base, 0, mr.uint8(0)), 'write into a system DLL is refused')
	check(refused(mr.write, plus.base, 0, mr.uint8(0)), "write into Plus's own module is refused")
	check(refused(mr.patch, mr.base, 'MZ', 'MZ'), "patch on the exe's headers is refused")
	local imports = table_start(1)
	local import_bytes = mr.read(imports, 0, 4)
	check(refused(mr.patch, imports, import_bytes, import_bytes), "patch on the exe's import table is refused")
	check(refused(mr.write, imports, 0, import_bytes), "write into the exe's import table is refused")
	check(refused(mr.vector_reserve, system.base, 0, 4, 1), 'vector_reserve on a system DLL is refused')
	check(refused(mr.list_insert, system.base, 0, 1, '\1'), 'list_insert on a system DLL is refused')
	check(refused(mr.string_set, system.base, 0, 'x'), 'string_set on a system DLL is refused')
	check(refused(mr.game_free, mr.add(system.base, 0x100)), 'game_free inside a system DLL is refused')
	local function map_shape_in(base)
		for offset = 0x18, 0xff8, 8 do
			local capacity, size = mr.read_uint32(base, offset), mr.read_int32(base, offset + 4)
			if size >= 1 and size <= 0x10000 and size <= capacity and not mr.is_null(mr.read_pointer(base, offset + 8)) then
				return mr.add(base, offset - 0x18)
			end
		end
	end
	local system_map = map_shape_in(system.base)
	check(system_map ~= nil and refused(mr.map_remove_key, system_map, 'x'), 'map_remove_key on a system DLL is refused')
	check(system_map ~= nil and pcall(mr.map_find_key, system_map, 'x'), 'map_find_key reads a map in a system DLL')

	check(mr.tonumber(mr.call(target, TARGET, 1, 2)) == 12, 'call into the exe code works')
	mr.hook(target, TARGET, function(a, b)
		return mr.hook_next(target, a, b)
	end)
	local original = mr.hook_info(target).original
	check(mr.tonumber(mr.call(target, TARGET, 3, 4)) == 34, 'hook on the exe code works')
	check(mr.tonumber(mr.call(original, TARGET, 5, 6)) == 56, "call of a hook's original works")
	check(refused(mr.write, original, 0, mr.uint8(0x90)), "write into a hook's trampoline is refused")
	mr.unhook(target)
	local buffer = mr.alloc(16)
	mr.write(buffer, 0, mr.uint32(7))
	check(mr.read_uint32(buffer, 0) == 7, 'write into alloc memory works')
	local block = mr.game_alloc(16)
	mr.write(block, 0, mr.uint32(8))
	check(mr.read_uint32(block, 0) == 8, 'write into game heap memory works')
	mr.game_free(block)
	local data = mr.pointer(exe_data_address())
	mr.write(data, 0, mr.uint32(9))
	check(mr.read_uint32(data, 0) == 9, "write into the exe's data works")
	local code = mr.pointer(test_function('pattern_target'))
	local first = mr.read(code, 0, 1)
	mr.write(code, 0, first)
	check(mr.read(code, 0, 1) == first, "write into the exe's code works")

	local function refuse_call()
		return pcall(mr.call, mr.base, 'void()')
	end
	local where = 'offline.lua:' .. (debug.getinfo(refuse_call, 'S').linedefined + 1)
	for _ = 1, 3 do
		refuse_call()
	end
	local ok, err = pcall(function()
		mr.write(system.base, 0, mr.uint8(0))
	end)
	check(not ok and string.find(err, 'offline.lua:%d+: bad argument #1 to') ~= nil, 'the error names the script line: ' .. tostring(err))
	local log = io.open('memreader_plus_refused.txt', 'rb')
	local text = log and log:read('*a') or ''
	if log then log:close() end
	local lines, from_helper = 0, 0
	for line in text:gmatch('[^\n]+') do
		lines = lines + 1
		if string.find(line, where, 1, true) then from_helper = from_helper + 1 end
	end
	check(lines > 0 and lines <= 32, 'the refusal log has ' .. lines .. ' lines')
	check(from_helper == 1, 'three refusals from one line are logged once (' .. where .. ')')
	check(string.find(text, 'call refused at', 1, true) ~= nil, 'the log names the refused function')
elseif SCENARIO == 'frame' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local probe = mr.alloc(56)
	local function run_probe(name)
		local result = mr.tonumber(mr.call(mr.pointer(test_function('frame_call')), 'int64(pointer, pointer)', mr.pointer(test_function(name)), probe))
		local unwound = mr.eq(mr.read_pointer(probe, 0), mr.read_pointer(probe, 40)) and mr.eq(mr.read_pointer(probe, 8), mr.read_pointer(probe, 32))
		local registers = mr.tonumber(mr.read_uint64(probe, 16, true)) == 0x1111 and mr.tonumber(mr.read_uint64(probe, 24, true)) == 0x2222
		local xmm = mr.tonumber(mr.read_uint64(probe, 48, true)) == 0x3333
		return result, unwound and registers and xmm
	end
	local function table_entry(name)
		local base = mr.base
		local headers = mr.add(base, mr.read_int32(base, 0x3c))
		local table_start = mr.add(base, mr.read_uint32(headers, 0x18 + 0x70 + 3 * 8))
		local count = mr.read_uint32(headers, 0x18 + 0x70 + 3 * 8 + 4) / 12
		local start = mr.function_start(mr.pointer(test_function(name)))
		for i = 0, count - 1 do
			local entry = mr.add(table_start, i * 12)
			if mr.eq(mr.add(base, mr.read_uint32(entry, 0, true)), start) then return entry end
		end
	end
	local target_entry, twin_entry = table_entry('frame_target'), table_entry('frame_twin')
	check(target_entry and twin_entry, 'the test functions have function table entries')
	local result, unwinds = run_probe('frame_target')
	check(result == 0 and unwinds, 'frame_target runs and the probe unwinds through it to the caller with its saved registers')
	local twin_unwind = mr.read(twin_entry, 8, 4)
	mr.patch(mr.add(twin_entry, 8), twin_unwind, mr.read(target_entry, 8, 4))
	local twin_result, twin_unwinds = run_probe('frame_twin')
	check(twin_result == 0 and twin_unwinds, 'frame_twin shares the unwind info of frame_target and unwinds')
	local function code_pattern(name)
		return mr.tostring(mr.read(mr.pointer(test_function(name)), 0, 24)):gsub('%x%x', '%0 '):gsub(' $', '')
	end
	local original_target = code_pattern('frame_target')
	local before_grow = select(2, mr.find_pattern(original_target))
	local shared = mr.read(target_entry, 8, 4)
	check(mr.grow_frame(mr.pointer(test_function('frame_target')), 0x360) == true, 'grow_frame grows a frame with shared unwind info')
	check(mr.read(target_entry, 8, 4) ~= shared, 'the grown function points at a private unwind copy')
	check(mr.read(twin_entry, 8, 4) == shared, 'the other function keeps the shared unwind info')
	local grown_result, grown_unwinds = run_probe('frame_target')
	check(grown_result == 0, 'the grown function still reads its home slot back')
	check(grown_unwinds, 'unwinding through the grown frame restores the caller frame and saved registers')
	local twin_after_result, twin_after = run_probe('frame_twin')
	check(twin_after_result == 0 and twin_after, 'the function sharing the old unwind info still unwinds correctly')
	check(select(2, mr.find_pattern(original_target .. ' ')) == before_grow, 'find_pattern still finds the grown function by its original bytes')
	local xmm_result, xmm_unwinds = run_probe('frame_xmm_target')
	check(xmm_result == 0 and xmm_unwinds, 'frame_xmm_target runs and unwinds with xmm6 saved inside its frame')
	check(mr.grow_frame(mr.pointer(test_function('frame_xmm_target')), 0x360) == true, 'grow_frame grows a frame with an xmm save inside it')
	local xmm_after_result, xmm_after = run_probe('frame_xmm_target')
	check(xmm_after_result == 0, 'the grown function with an xmm save still runs')
	check(xmm_after, 'unwinding through it restores xmm6 from the slot inside the frame')
	local patch_site = mr.pointer(test_function('patch_target'))
	local patch_pattern = code_pattern('patch_target')
	local before_patch = select(2, mr.find_pattern(patch_pattern))
	mr.patch(patch_site, '\184\1\0\0\0', '\184\2\0\0\0')
	check(select(2, mr.find_pattern(patch_pattern .. ' ')) == before_patch, 'find_pattern still finds a patched site by its original bytes')
	mr.patch(patch_site, '\184\2\0\0\0', '\184\1\0\0\0')
	check(mr.grow_frame(mr.pointer(test_function('frame_target')), 0x360) == true, 'a second grow_frame of the same function changes nothing')
	check(run_probe('frame_target') == 0, 'the function still runs after the second call')
	local pointer_result, pointer_unwinds = run_probe('frame_pointer_target')
	check(pointer_result == 0 and pointer_unwinds, 'frame_pointer_target runs and unwinds')
	check(
		mr.grow_frame(mr.pointer(test_function('frame_pointer_target')), 0x100) == true,
		'grow_frame grows a frame with a frame pointer set before the allocation'
	)
	local pointer_after_result, pointer_after = run_probe('frame_pointer_target')
	check(pointer_after_result == 0, 'locals, home slots and stack slots stay consistent after growing')
	check(pointer_after, 'unwinding through the grown frame pointer function still works')
	check(not pcall(mr.grow_frame, mr.pointer(test_function('frame_twin')), 15), 'grow_frame refuses a size that is not a multiple of 16')
	check(not pcall(mr.grow_frame, mr.pointer(test_function('leaf_add_one')), 16), 'grow_frame refuses an address outside any listed function')
	local target_bytes = mr.tostring(mr.read(mr.pointer(test_function('frame_twin')), 0, 24)):gsub('%x%x', '%0 '):gsub(' $', '')
	local pointer_bytes = code_pattern('frame_call')
	local found, counts = mr.find_patterns({ target_bytes, pointer_bytes, 'C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3' })
	local single, single_count = mr.find_pattern(pointer_bytes)
	check(counts[2] == single_count and mr.eq(found[2], single), 'find_patterns agrees with find_pattern')
	check(found[3] == false and counts[3] == 0, 'find_patterns reports a missing pattern as false and 0')
	check(counts[1] >= 1, 'find_patterns finds the frame function')
	check(not pcall(mr.find_patterns, {}), 'find_patterns refuses an empty list')
	check(not pcall(mr.find_patterns, { '?? 00' }), 'find_patterns refuses a pattern that starts with ??')
elseif SCENARIO == 'hooked_code' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local FULL_LINE = 'saved original code is full'
	local function log_text()
		local log = io.open('memreader_plus_refused.txt', 'rb')
		local text = log and log:read('*a') or ''
		if log then log:close() end
		return text
	end
	local function count_in(text, part)
		local count, at = 0, 1
		while true do
			at = string.find(text, part, at, true)
			if not at then return count end
			count, at = count + 1, at + #part
		end
	end
	local function hex(bytes)
		return (bytes
			:gsub('.', function(char)
				return string.format('%02X ', char:byte())
			end)
			:gsub(' $', ''))
	end
	local function same_result(a, b)
		return mr.eq(a[1] or mr.pointer(0), b[1] or mr.pointer(0)) and a[2] == b[2]
	end

	local patch_site = mr.pointer(test_function('patch_target'))
	for _ = 1, 2500 do
		mr.patch(patch_site, '\184\1\0\0\0', '\184\2\0\0\0')
		mr.patch(patch_site, '\184\2\0\0\0', '\184\1\0\0\0')
	end
	check(count_in(log_text(), FULL_LINE) == 0, '5000 patches of one site save its original once and never fill the table')
	check(mr.read_original(patch_site, 0, 5) == '\184\1\0\0\0', 'read_original of a site patched and restored gives the original bytes')

	local target = mr.pointer(test_function('prologue_target'))
	local ORIGINAL = '\83\86\87\144\184\1\0\0\0\95\94\91\195'
	local pattern = hex(ORIGINAL)
	check(mr.read(target, 0, #ORIGINAL) == ORIGINAL, 'prologue_target holds the expected bytes')
	local first = { mr.find_pattern(pattern) }
	check(mr.eq(first[1], target) and first[2] == 1, 'the prologue pattern is found once before hooking')
	mr.hook(target, 'int32()', function()
		return mr.hook_next(target)
	end)
	check(mr.tonumber(mr.call(target, 'int32()')) == 1, 'the hooked function still returns 1')
	check(mr.read(target, 0, 1) == '\233', 'read of hooked code returns the jump the hook wrote')
	check(mr.read_original(target, 0, #ORIGINAL) == ORIGINAL, 'read_original returns the bytes from before the hook')
	check(mr.read_original(target, 4, 5) == '\184\1\0\0\0', 'read_original takes an offset like the reads')
	check(mr.read_original(target, nil, 3) == ORIGINAL:sub(1, 3), 'read_original takes nil as the offset')
	check(mr.read_original(mr.add(target, 4), 5) == '\184\1\0\0\0', 'read_original with two arguments takes the second as the size')
	check(not pcall(mr.read_original, target, 0, 0), 'read_original refuses 0 bytes')
	check(not pcall(mr.read_original, mr.alloc(4), 0, 4), 'read_original refuses an address outside the exe')
	local cached = { mr.find_pattern(pattern) }
	local fresh = { mr.find_pattern(pattern .. ' ') }
	check(same_result(cached, first), 'the cached result of a function hooked after the first scan is the first result')
	check(same_result(fresh, first), 'a fresh scan of the hooked function gives the same result as the cache')
	local trampoline = mr.hook_info(target).original
	check(mr.read(trampoline, 4, 5) == '\184\1\0\0\0', 'the trampoline holds the copied instructions')
	check(mr.read(trampoline, 9, 2) == '\255\37', 'past the copied instructions the trampoline holds its jump back')

	local site = mr.add(target, 5)
	local old, current = mr.patch(site, '\1\0\0\0', '\2\0\0\0')
	check(old == nil and current == '\1\0\0\0', 'patch inside the copied prologue gives nil and the bytes found')
	check(mr.tonumber(mr.call(target, 'int32()')) == 1 and mr.read(site, 0, 4) == '\1\0\0\0', 'and writes nothing')
	local done, index = mr.relocate_field({ { site, '\1\0\0\0', '\2\0\0\0' } })
	check(done == nil and index == 1, 'relocate_field refuses a site inside the copied prologue')
	local ok, err = pcall(mr.write, site, 0, mr.uint32(2))
	check(not ok and string.find(tostring(err), 'refused: the first bytes of a hooked function', 1, true) ~= nil, 'write inside the copied prologue is refused')
	check(not pcall(mr.write, target, 0, mr.uint8(0x90)), 'write over the hook jump is refused')
	check(mr.read(site, 0, 4) == '\1\0\0\0', 'the refused write changed nothing')
	local log = log_text()
	check(count_in(log, 'patch refused at') == 1 and count_in(log, 'relocate_field refused at') == 1, 'the log names the refused patch and relocate_field')
	check(count_in(log, 'write refused at') >= 1, 'the log names the refused write')
	local after = mr.add(target, 9)
	check(mr.patch(after, '\95', '\144') == '\95' and mr.read(after, 0, 1) == '\144', 'patch past the copied prologue still works')
	mr.patch(after, '\144', '\95')

	mr.patch(patch_site, '\184\1\0\0\0', '\184\2\0\0\0')
	mr.hook(patch_site, 'int32()', function()
		return mr.hook_next(patch_site)
	end)
	local jump = mr.read(patch_site, 0, 5)
	local again, found = mr.patch(patch_site, '\184\1\0\0\0', '\184\2\0\0\0')
	check(jump:sub(1, 1) == '\233' and again == nil and found == jump, 'a patch made before the hook and overlapping its jump gives nil and the jump bytes')
	check(mr.tonumber(mr.call(patch_site, 'int32()')) == 2, 'the hook runs the earlier patch from its copy')
	check(mr.read_original(patch_site, 5) == '\184\1\0\0\0', 'read_original under the hook gives the bytes from before the earlier patch')

	local frame = mr.pointer(test_function('frame_hooked'))
	check(mr.read(frame, 0, 3) == '\72\139\196', 'frame_hooked starts with mov rax, rsp')
	local frame_pattern = hex(mr.read(frame, 0, 24))
	mr.hook(frame, 'int64(pointer)', function(probe)
		return mr.hook_next(frame, probe)
	end)
	local grown, why = mr.grow_frame(frame, 0x40)
	check(grown == nil and why == 'the function is hooked', 'grow_frame refuses a hooked function: ' .. tostring(why))
	check(mr.read(frame, 0, 1) == '\233' and mr.read_original(frame, 0, 3) == '\72\139\196', 'read_original sees mov rax, rsp under the hook jump')
	local other = { mr.find_pattern(frame_pattern) }
	check(mr.eq(other[1], frame) and other[2] == 1, 'a different pattern scans on its own and finds its function through the hook')

	local list = { pattern, frame_pattern, 'C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3 C3' }
	local fresh_list = {}
	for i, text in ipairs(list) do
		fresh_list[i] = text .. '  '
	end
	local found_a, counts_a = mr.find_patterns(list)
	local found_b, counts_b = mr.find_patterns(fresh_list)
	local agree = true
	for i = 1, #list do
		agree = agree and counts_a[i] == counts_b[i] and (found_a[i] == found_b[i] or mr.eq(found_a[i], found_b[i]))
	end
	check(agree, 'find_patterns from the cache agrees with a fresh scan')
	check(counts_a[3] == 0 and found_a[3] == false, 'a missing pattern stays missing')

	local filler = mr.pointer(test_function('filler_code'))
	local zeros, nops = string.rep('\0', 4096), string.rep('\144', 4096)
	for chunk = 0, 9 do
		mr.patch(mr.add(filler, chunk * 4096), zeros, nops)
	end
	check(count_in(log_text(), FULL_LINE) == 1, 'a full table is reported once in the log')
	check(mr.read_original(filler, 0, 16) == string.rep('\0', 16), 'the first ranges keep their original bytes')
	check(mr.read_original(mr.add(filler, 9 * 4096), 0, 16) == string.rep('\144', 16), 'ranges changed after the table filled up show the new bytes')
	mr.patch(mr.add(filler, 9 * 4096), nops, zeros)
	check(count_in(log_text(), FULL_LINE) == 1, 'further changes do not repeat the report')
elseif
	SCENARIO == 'fault_report'
	or SCENARIO == 'fault_report_no_log'
	or SCENARIO == 'fault_report_off'
	or SCENARIO == 'fault_report_in_callback'
	or SCENARIO == 'fault_report_thread'
	or SCENARIO == 'fault_report_native_thread'
	or SCENARIO == 'fault_report_overflow'
	or SCENARIO == 'fault_report_cpp'
	or SCENARIO == 'fault_report_fallback'
then
	io.stdout:setvbuf('no')
	local log = PASS == 1 and 'script_log_010203_0404.txt' or 'script_log_010203_0405.txt'
	if SCENARIO == 'fault_report' then io.open(log, 'wb'):close() end
	if SCENARIO == 'fault_report_thread' then
		local env = coroutine.create(run_mod)
		test_ref(env)
		assert(coroutine.resume(env, OURS))
	else
		run_mod(OURS)
	end
	local mr = _G.memreader_plus
	pcall(mr.call, mr.pointer(test_function('read_null')), 'int32()')
	check(
		not exists('memreader_crash_report_010203_0404.txt') and not exists('memreader_crash_report_010203_0405.txt'),
		'a fault inside a guarded call writes no report'
	)
	check(not pcall(mr.call, mr.pointer(test_function('raise_lua_error')), 'void(pointer)', mr.pointer(test_state())), 'a Lua error leaves a guarded call')
	check(not pcall(mr.set_crash_reports, 'yes'), 'set_crash_reports takes a boolean')
	if SCENARIO == 'fault_report_off' and PASS > 1 then mr.set_crash_reports(false) end
	check(not pcall(mr.set_crash_context), 'set_crash_context needs a name')
	if PASS > 1 then fill_crash_context(mr) end
	if PASS == 1 then
		NEXT_PASS = true
	else
		local function crash_in_callback()
			local single = mr.pointer(test_function('hook_single'))
			mr.hook(single, 'int64(int64)', function()
				test_crash()
				return 0
			end)
			mr.call(mr.pointer(test_function('call_directly')), 'int64(pointer, int64)', single, 1)
		end
		local function report_me()
			local marker = 'event-under-test'
			if SCENARIO == 'fault_report_in_callback' then
				crash_in_callback()
			elseif SCENARIO == 'fault_report_no_log' then
				test_execute_crash()
			elseif SCENARIO == 'fault_report_native_thread' then
				test_thread_crash()
			elseif SCENARIO == 'fault_report_overflow' then
				test_stack_overflow()
			elseif SCENARIO == 'fault_report_cpp' then
				mr.call(mr.pointer(test_function('throw_out')), 'void()')
			else
				test_crash()
			end
			return marker
		end
		print('an unguarded fault on the script thread (expected to crash)')
		if SCENARIO == 'fault_report_thread' then
			local other = coroutine.create(function()
				report_me()
			end)
			test_ref(other)
			coroutine.resume(other)
		else
			report_me()
		end
		print('did not crash')
		os.exit(0)
	end
elseif SCENARIO == 'fault_report_stale' then
	io.stdout:setvbuf('no')
	run_mod(OURS)
	test_recovered_crash()
	check(#io.popen('dir /b memreader_crash_report_*.txt 2>nul'):read('*a') == 0, 'a fault the game recovers from writes no report')
	local function report_me()
		local marker = 'event-under-test'
		test_crash()
		return marker
	end
	print('a later crash (expected to crash)')
	report_me()
	print('did not crash')
	os.exit(0)
elseif SCENARIO == 'bench' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local ROUNDS = 100000
	local data = mr.alloc(4096)
	for i = 0, 255 do
		mr.write(data, i * 4, mr.uint32(i))
	end
	mr.write(data, 1024, mr.uint32(5))
	mr.write(data, 1028, mr.uint32(5))
	mr.write(data, 1032, mr.add(data, 1040))
	mr.write(data, 1040, 'hello\0')
	local LAYOUT = { a = { 0, 'uint32' }, b = { 4, 'float' }, c = { 8, 'pointer' }, d = { 12, 'uint32', true } }
	local function time(label, fn)
		local start = mr.ticks()
		for i = 1, ROUNDS do
			fn(i)
		end
		print(string.format('  bench %-28s %7.0f ns', label, mr.elapsed_us(start) * 1000 / ROUNDS))
	end
	time('read_uint32 number', function()
		mr.read_uint32(data, 8)
	end)
	time('read_uint32 exact, same', function()
		mr.read_uint32(data, 8, true)
	end)
	time('read_uint32 exact, new each', function(i)
		mr.write(data, 2048, mr.uint32(i))
		mr.read_uint32(data, 2048, true)
	end)
	time('read_pointer', function()
		mr.read_pointer(data, 1032)
	end)
	local value = mr.uint32(7)
	time('write uint32 alloc memory', function()
		mr.write(data, 2048, value)
	end)
	time('hook_depth, a bare C call', function()
		mr.hook_depth()
	end)
	time('note_crash_event, same name', function()
		mr.note_crash_event('CharacterTurnStart')
	end)
	local event_names = {}
	for i = 1, 40 do
		event_names[i] = 'Event' .. i
	end
	time('note_crash_event, 40 names', function(i)
		mr.note_crash_event(event_names[i % 40 + 1])
	end)
	local exe_data = mr.pointer(exe_data_address())
	time('write uint32 exe data', function()
		mr.write(exe_data, 0, value)
	end)
	time('read_float', function()
		mr.read_float(data, 4)
	end)
	time('read_string', function()
		mr.read_string(data, 1024)
	end)
	time('read_struct 4 fields', function()
		mr.read_struct(data, 0, LAYOUT)
	end)
	time('read_chain 2', function()
		mr.read_chain(data, 1032, 0)
	end)
	time('add pointer', function()
		mr.add(data, 16)
	end)
	local prologue = mr.tostring(mr.read(mr.pointer(test_function('pattern_target')), 0, 16)):gsub('%x%x', '%0 '):gsub(' $', '')
	local function fresh(round)
		return prologue .. string.rep(' ', round)
	end
	local function time_scans(label, scan)
		local start = mr.ticks()
		for round = 1, 20 do
			scan(round)
		end
		print(string.format('  bench %-28s %7.0f us', label, mr.elapsed_us(start) / 20))
	end
	time_scans('find_pattern cold', function(round)
		mr.find_pattern(fresh(round))
	end)
	time_scans('find_pattern cached', function()
		mr.find_pattern(fresh(1))
	end)
	local function batch(round)
		local list = {}
		for i = 1, 30 do
			list[i] = fresh(100 + round * 30 + i)
		end
		return list
	end
	time_scans('find_patterns 30 cold', function(round)
		mr.find_patterns(batch(round))
	end)
	local cached_batch = batch(1)
	time_scans('find_patterns 30 cached', function()
		mr.find_patterns(cached_batch)
	end)
	local target = mr.pointer(test_function('hook_target'))
	local TARGET = 'int32(int32, int32)'
	time('call', function()
		mr.call(target, TARGET, 1, 2)
	end)
	mr.hook(target, TARGET, function(a, b)
		return mr.hook_next(target, a, b)
	end)
	time('call hooked, hook_next', function()
		mr.call(target, TARGET, 1, 2)
	end)
	mr.unhook(target)
	mr.hook(target, TARGET, function(a, b)
		return a
	end)
	time('call hooked, replaced', function()
		mr.call(target, TARGET, 1, 2)
	end)
	mr.unhook(target)
elseif SCENARIO == 'cpecific_bigread' then
	io.stdout:setvbuf('no')
	run_mod(THEIRS)
	print("reading 1024 bytes with Cpecific's DLL (expected to crash)")
	_G.memreader.read(_G.memreader.base, 0, 1024)
	print('did not crash')
	os.exit(0)
else
	error('unknown scenario ' .. tostring(SCENARIO))
end

print(failures == 0 and 'PASS ' .. SCENARIO .. (PASS > 1 and ' pass ' .. PASS or '') or ('FAILED ' .. SCENARIO .. ': ' .. failures))
if NEXT_PASS then return end
os.exit(failures == 0 and 0 or 1)
