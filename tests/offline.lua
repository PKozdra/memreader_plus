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
local function load_other_program_dll()
	if exists('fake_overlay64.dll') then package.loadlib('.\\fake_overlay64.dll', 'luaopen_fake_overlay64') end
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

local function patch_from_chunk(name, mr, address)
	assert(loadstring('local mr, address = ...; mr.patch(address, "\\0", "\\144")', name))(mr, address)
end

local function fill_code_patches(mr)
	local filler = mr.pointer(test_function('filler_code'))
	local sites = {}
	for i = 1, 40 do
		sites[i] = { mr.add(filler, i * 8), '\0\0\0\0', '\1\0\0\0' }
	end
	check(mr.relocate_field(sites) == true, 'relocate_field patches 40 sites in one batch')
	patch_from_chunk('later_patch', mr, filler)
	for i = 1, 35 do
		patch_from_chunk('filler_patch_' .. i, mr, mr.add(filler, 1000 + i))
	end
	patch_from_chunk('newest_patch', mr, mr.add(filler, 2000))
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
	core.event_callback = function(_, eventname, context)
		if listeners[eventname] then listeners[eventname](context) end
	end
	listeners.FirstTickAfterWorldCreated()
	listeners.ComponentLClickUp({ string = 'button_windows' })
	listeners.ComponentLClickUp({ string = 'button_cancel' })
	listeners.ComponentLClickUp({ string = 'button_quit' })
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

local SETTINGS = table.concat({
	'[alpha_mod] Alpha Mod',
	'  enabled = true',
	'  strength = 2.5',
	'[beta_mod] Beta Mod',
	'  mode = fast',
	'  note = tab\tand\rreturn',
	'[gamma_mod] Gamma Mod',
	'  hours = 12',
}, '\n')

local function big_settings()
	local lines = { '[big_mod] Big Mod' }
	for i = 1, 2000 do
		lines[#lines + 1] = ('  option_%04d = value'):format(i)
	end
	return table.concat(lines, '\n')
end

local function block_runtime_report_names()
	local now = os.date('*t')
	local day = ('%02d%02d%02d'):format(now.day, now.month, now.year % 100)
	local start = now.hour * 3600 + now.min * 60 + now.sec
	for second = start - 1, start + 3 do
		local time = ('%02d%02d%02d'):format(math.floor(second / 3600), math.floor(second / 60) % 60, second % 60)
		os.execute(('mkdir "memreader_runtime_report_%s_%s.txt" >nul 2>nul'):format(day, time))
	end
end

local function set_report_settings(mr)
	if SCENARIO == 'settings_none' then
		mr.set_crash_settings(SETTINGS)
		check(mr.set_crash_settings(nil) == true, 'set_crash_settings(nil) clears the snapshot')
		mr.set_crash_settings(SETTINGS)
		check(mr.set_crash_settings(5) == true, 'a value that is not a string clears the snapshot')
	elseif SCENARIO == 'settings_cut' then
		check(mr.set_crash_settings(big_settings()) == true, 'set_crash_settings takes a 40 KB snapshot')
	else
		check(mr.set_crash_settings(SETTINGS) == true, 'set_crash_settings returns true')
	end
end

local function read_all(name)
	local file = assert(io.open(name, 'rb'))
	local text = file:read('*a')
	file:close()
	return text
end

local function stub_option(kind, value)
	return {
		get_type = function()
			return kind
		end,
		get_finalized_setting = function()
			return value
		end,
	}
end

local function failing_option(kind)
	return {
		get_type = function()
			return kind
		end,
		get_finalized_setting = function()
			error('getter failed', 0)
		end,
	}
end

local function stub_mod(title, options)
	return {
		get_title = function()
			if title == nil then error('no title', 0) end
			return title
		end,
		get_options = function()
			if options == nil then error('no options', 0) end
			return options
		end,
	}
end

local function install_mct(mods)
	get_mct = function()
		return {
			get_mods = function()
				return mods
			end,
		}
	end
end

local function settings_mods()
	return {
		gamma_mod = stub_mod('Gamma Mod', { hours = stub_option('MCT.Option.Slider', 12) }),
		alpha_mod = stub_mod('Alpha Mod', {
			enabled = stub_option('MCT.Option.Checkbox', true),
			strength = stub_option('MCT.Option.Slider', 2.5),
			spacer = failing_option('MCT.Option.Dummy'),
			button = failing_option('MCT.Option.Action'),
		}),
		beta_mod = stub_mod('Beta Mod', {
			mode = stub_option('MCT.Option.Dropdown', 'fast'),
			note = stub_option('MCT.Option.TextInput', 'tab\tand\rreturn'),
		}),
	}
end

local function installed_core(listeners)
	core = {
		add_listener = function(_, name, event, condition, callback, persistent)
			listeners[#listeners + 1] = { name = name, event = event, condition = condition, callback = callback, persistent = persistent }
			listeners[event] = callback
		end,
	}
end

local function many_options(count)
	local options = {}
	for i = 1, count do
		options[('option_%03d'):format(i)] = stub_option('MCT.Option.Checkbox', 'x')
	end
	return options
end

local REPORT_NAME = '^memreader_runtime_report_%d%d%d%d%d%d_%d%d%d%d%d%d%.txt$'

local function has(text, part)
	return string.find(text, (string.gsub(part, '%W', '%%%0'))) ~= nil
end

local function count_lines(text, part)
	local count = 0
	for line in text:gmatch('[^\n]+') do
		if has(line, part) then count = count + 1 end
	end
	return count
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
	['write read-only page'] = 'bytes:4D5A',
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
local REPORT = PACK .. '/script/_lib/mod/memreader_plus_report.lua'
local LOADER = PACK .. '/script/memreader_plus/loader.lua'
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

local HOST_FAULTS = {
	exit_report = { 'exit_process', false },
	exit_report_off = { 'exit_process', false },
	exit_report_terminate = { 'terminate_process', true },
	exit_report_crt = { 'crt_exit', false },
	fault_report_two_threads = { 'two_threads', false },
	fault_report_worker_stuck = { 'worker_stuck', false },
	fault_report_worker_waits = { 'worker_waits', false },
	fault_report_worker_blocked = { 'worker_blocked', false },
	fault_report_worker_dead = { 'worker_dead', false },
	fault_report_move_retry = { 'move_retry', false },
	fault_report_move_fails = { 'move_fails', false },
}

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
			{
				run(hook, mr.base, TARGET, hooked),
				"error: bad argument #1 to 'hook' (refused: this takes only read-only executable code outside memreader Plus's own module)",
			},
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
elseif SCENARIO == 'far_hook' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local raw = test_function('parked_target')
	local target = mr.pointer(raw)
	local BYTES = '\83\131\57\0\116\251\91\184'
	local function offset_in(base)
		return tonumber(mr.tostring(mr.sub(mr.pointer(test_park_rip()), base)), 16)
	end
	check(mr.read(target, 0, #BYTES) == BYTES, 'parked_target holds the expected bytes')
	check(test_park_start(raw), 'a thread spins inside parked_target')
	local at = offset_in(target)
	check(at == 1 or at == 4, 'it spins on an instruction inside the 6 bytes the hook copies, at offset ' .. tostring(at))

	check(test_force_far_hooks(true, mr.hop_slots), 'the near trampoline block is made unreachable')
	local slots = mr.hop_slots()
	mr.hook(target, 'int32(pointer)', function(flag)
		return mr.add(mr.hook_next(target, flag), 1000)
	end)
	test_force_far_hooks(false, mr.hop_slots)
	check(mr.hop_slots() == slots - 1, 'the hook took a padding slot, so it ran the far path')
	check(mr.read(target, 0, 1) == '\233', 'the site holds the jump')

	local trampoline = mr.hook_info(target).original
	local moved = offset_in(trampoline)
	check(moved == at, 'the spinning thread was moved to the same instruction in the trampoline, at offset ' .. tostring(moved))
	check(test_park_finish() == 77, 'the thread leaves the loop and finishes the function')
	check(mr.tonumber(mr.call(target, 'int32(pointer)', mr.pointer(test_park_flag()))) == 1077, 'the hooked function runs the callback and the original')

	local distant = mr.pointer(test_far_function())
	local before = mr.hop_slots()
	test_force_far_hooks(true, mr.hop_slots)
	local ok, message = pcall(mr.hook, distant, 'int32()', function()
		return 7
	end)
	test_force_far_hooks(false, mr.hop_slots)
	check(
		not ok and string.find(tostring(message), "no free memory near the game's code", 1, true) ~= nil,
		'a function more than 2 GB from the exe cannot take the far path: ' .. tostring(message)
	)
	check(mr.hop_slots() == before, 'and no padding slot is used')
	check(mr.read(distant, 0, 1) == '\184' and mr.hook_info(distant) == nil, 'the distant function is left alone')
	if mr.read(distant, 0, 1) == '\184' then check(mr.tonumber(mr.call(distant, 'int32()')) == 42, 'the distant function still runs') end
elseif SCENARIO == 'cave' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	check(test_chain_cold_part(), 'the cold part of the split function is chained to its hot part')
	local TARGET = 'int32(int32, int32)'
	local function bytes(hex)
		return (hex:gsub('%x%x', function(pair)
			return string.char(tonumber(pair, 16))
		end))
	end
	local function contains(text, part)
		return text ~= nil and string.find(text, part, 1, true) ~= nil
	end
	local function error_of(f, ...)
		local ok, err = pcall(f, ...)
		return not ok and tostring(err) or nil
	end
	check(type(mr.code_cave) == 'function', 'code_cave is part of the API')
	check(mr.hop_slots() > 0, 'the exe has int3 padding runs for far caves')
	local counter = cave_count_address()
	local code = bytes('50' .. '48B8') .. counter .. bytes('FF0058')

	local far = mr.pointer(test_function('hook_target'))
	check(test_force_far_hooks(true, mr.hop_slots), 'the near trampoline block is made unreachable')
	local slots = mr.hop_slots()
	local far_cave = mr.code_cave(far, code)
	test_force_far_hooks(false, mr.hop_slots)
	check(not mr.is_null(far_cave) and mr.hop_slots() == slots - 1, 'a far cave takes one padding slot')
	check(cave_count() == 0, 'the far cave has not run yet')
	check(mr.tonumber(mr.call(far, TARGET, 3, 4)) == 34, 'the function returns 3*10+4 through the far cave')
	check(cave_count() == 1, 'the far cave ran')
	check(mr.tonumber(mr.call(mr.hook_info(far).original, TARGET, 5, 6)) == 56, "call of a cave's original works")

	local target = mr.pointer(test_function('cave_target'))
	local prologue = mr.tostring(mr.read(target, 0, 16)):gsub('%x%x', '%0 '):gsub(' $', '')
	local first, count = mr.find_pattern(prologue)
	local before = mr.hop_slots()
	local cave = mr.code_cave(target, code)
	local first_after, count_after = mr.find_pattern(prologue)
	check(count_after == count and mr.eq(first_after, first), 'find_pattern sees through the cave')
	check(not mr.is_null(cave), 'code_cave returned a cave address')
	check(mr.hop_slots() == before, 'a cave near the exe takes no padding slot')
	check(mr.hook_info(target).kind == 'cave', 'hook_info calls it a cave')
	check(mr.type(mr.hook_info(target).cave) == 'pointer' and mr.eq(mr.hook_info(target).cave, cave), 'hook_info gives the cave address')
	check(mr.read(cave, 0, #code) == code, 'the cave starts with the bytes the mod gave')
	check(mr.eq(mr.hook_info(far).cave, far_cave), 'a far cave has its address in hook_info too')
	check(mr.tonumber(mr.call(target, TARGET, 3, 4)) == 34, 'the function still returns 3*10+4 through the cave')
	check(cave_count() == 2, 'the cave ran once')
	mr.call(target, TARGET, 1, 1)
	check(cave_count() == 3, 'the cave ran again')
	mr.call(mr.pointer(test_function('call_on_thread')), 'int64(pointer, int64)', target, 5)
	check(cave_count() == 4, 'a cave runs on another thread')
	check(contains(error_of(mr.code_cave, target, code), 'already holds a code cave'), 'a second cave on the same address is refused')
	check(contains(error_of(mr.hook, target, TARGET, function() end), 'already holds a code cave'), 'hook on a cave address is refused')
	check(contains(error_of(mr.hook_site, target, function() end), 'already holds a code cave'), 'hook_site on a cave address is refused')
	check(contains(error_of(mr.code_cave, target, ''), 'no cave bytes'), 'empty bytes are refused')
	check(contains(error_of(mr.code_cave, nil, code), 'address is NULL'), 'a NULL address is refused')
	check(contains(error_of(mr.code_cave, mr.alloc(16), code), 'refused: '), 'a cave on data memory is refused')
	check(contains(error_of(mr.write, target, 0, mr.uint8(0x90)), 'refused: the first bytes of a hooked function'), 'a write into the cave site is refused')
	check(mr.commit_stack() == true, 'commit_stack commits the current thread stack')
	local function fixture(name)
		return mr.pointer(test_function(name))
	end
	local inside = mr.add(fixture('site_target_here'), 1)
	check(contains(error_of(mr.code_cave, inside, code), 'refused: '), 'a cave inside an instruction is refused')
	check(mr.hook_info(inside) == nil, 'a refused cave leaves no hook behind')
	check(contains(error_of(mr.code_cave, fixture('site_ret_here'), code), 'refused: a return or jump'), 'a cave on a return is refused')
	check(
		contains(error_of(mr.code_cave, fixture('site_inbound_here'), code), 'refused: a jump in the function lands inside'),
		'a cave with a jump into its bytes is refused'
	)
	check(
		contains(error_of(mr.code_cave, fixture('site_split_here'), code), 'refused: a jump in another part of the function lands inside'),
		'a cave with a jump into its bytes from another part is refused'
	)
	check(
		contains(error_of(mr.code_cave, fixture('site_table_here'), code), 'refused: a jump table'),
		'a cave with a jump table entry into its bytes is refused'
	)
	check(
		contains(error_of(mr.code_cave, fixture('site_codetable_here'), code), 'refused: a jump table in the function'),
		'a cave with a jump table in the code of its function is refused'
	)
	check(contains(error_of(mr.code_cave, fixture('site_call_short_here'), code), 'refused: a call'), 'a cave over a short call is refused')
	check(mr.hook_info(fixture('site_call_short_here')) == nil, 'and installs nothing')
	check(
		contains(error_of(mr.code_cave, fixture('site_early_here'), code), 'cannot be decoded up to the address'),
		'a cave after bytes that do not decode is refused'
	)
	check(
		contains(error_of(mr.code_cave, fixture('site_tail_here'), code), 'run past the end of the function'),
		'a cave whose bytes run into the next function is refused'
	)
	check(
		contains(error_of(mr.code_cave, mr.add(fixture('site_leaf_mid_here'), 1), code), 'inside an instruction'),
		'a cave inside an instruction of a leaf function is refused'
	)
	check(
		contains(error_of(mr.code_cave, fixture('site_leaf_inbound_here'), code), 'a jump in the function lands inside'),
		'a cave with a jump into its bytes in a leaf function is refused'
	)
elseif SCENARIO == 'cave_session' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local target = mr.pointer(test_function('cave_target'))
	local code = string.rep('\144', 8)
	if PASS == 1 then
		local cave = mr.code_cave(target, code)
		local file = io.open('cave_address.txt', 'wb')
		file:write(mr.tostring(cave))
		file:close()
		check(mr.eq(mr.hook_info(target).cave, cave), 'the first mode sees its cave address')
		NEXT_PASS = failures == 0
	else
		local file = io.open('cave_address.txt', 'rb')
		local saved = file:read('*a')
		file:close()
		local info = mr.hook_info(target)
		check(
			info and info.kind == 'cave' and mr.tostring(info.cave) == saved,
			'a later mode finds the cave of the first one: ' .. tostring(info and info.cave)
		)
		check(mr.read(info.cave, 0, #code) == code, 'and its bytes')
		check(mr.tonumber(mr.call(target, 'int32(int32, int32)', 3, 4)) == 34, 'the function still works through the cave')
	end
elseif SCENARIO == 'site' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	check(test_chain_cold_part(), 'the cold part of the split function is chained to its hot part')
	local function address(name)
		return mr.pointer(test_function(name))
	end
	local function contains(text, part)
		return text ~= nil and string.find(text, part, 1, true) ~= nil
	end
	local function error_of(f, ...)
		local ok, err = pcall(f, ...)
		return not ok and tostring(err) or nil
	end
	local function has_bit(value, bit)
		return math.floor(value / bit) % 2 == 1
	end
	local TARGET = 'int32(int32, int32)'
	local target, here = address('site_target'), address('site_target_here')
	local function call_target(a, b)
		return mr.tonumber(mr.call(target, TARGET, a, b))
	end
	local function put(buffer, slot, value)
		mr.write(buffer, slot * 8, mr.uint64(value))
	end
	local function get(buffer, slot)
		return mr.tonumber(mr.read_uint64(buffer, slot * 8, true))
	end

	check(type(mr.hook_site) == 'function', 'hook_site is part of the API')
	local far_target, far_here = address('site_far'), address('site_far_here')
	check(test_force_far_hooks(true, mr.hop_slots), 'the near trampoline block is made unreachable')
	local far_slots = mr.hop_slots()
	mr.hook_site(far_here, function(regs)
		regs.eax = mr.add(regs.eax, 100)
	end)
	test_force_far_hooks(false, mr.hop_slots)
	check(mr.hop_slots() == far_slots - 1, 'the site took a padding slot, so it ran the far path')
	check(mr.tonumber(mr.call(far_target, 'int32(int32)', 5)) == 211, 'a far site runs its callback')
	check(mr.hook_info(far_here).calls == 1, 'and counts it')
	check(call_target(3, 4) == 34, 'the test function returns a*10+b')
	check(mr.hook_info(here) == nil, 'hook_info of a site never hooked is nil')

	local seen = {}
	mr.hook_site(here, function(regs)
		seen.a, seen.b, seen.kind, seen.pointer = mr.tonumber(regs.r10d), mr.tonumber(regs.r11d), type(regs), regs.r10
	end)
	check(call_target(3, 4) == 34, 'a callback that only reads leaves the result alone')
	check(seen.a == 3 and seen.b == 4, 'r10d and r11d hold the arguments at the site: ' .. tostring(seen.a) .. ', ' .. tostring(seen.b))
	check(mr.type(seen.pointer) == 'pointer' and mr.tostring(seen.pointer) == '0000000000000003', 'a 64-bit register reads as a pointer value')
	local info = mr.hook_info(here)
	check(info.kind == 'site' and info.attached and info.callbacks == 1 and info.calls == 1 and info.other_thread_calls == 0, 'hook_info describes the site')
	check(info.cave == nil, 'a site has no cave')
	check(mr.tonumber(mr.call(info.original, TARGET, 3, 4)) ~= nil, 'the original of a site is a callable address')
	check(
		contains(
			error_of(function()
				return seen.pointer.x
			end),
			'index'
		),
		'plain values are not registers'
	)
	mr.unhook(here)
	check(call_target(3, 4) == 34 and not mr.hook_info(here).attached, 'unhook detaches the callback')

	mr.hook_site(here, function(regs)
		regs.r11d = mr.add(regs.r11d, 100)
	end)
	check(call_target(3, 4) == 134, 'a write to r11d changes the result')
	mr.unhook(here)
	mr.hook_site(here, function(regs)
		regs.r11 = mr.pointer('\100\0\0\0\0\0\0\0')
	end)
	check(call_target(3, 4) == 130, 'a pointer value can be written to a 64-bit register')
	mr.unhook(here)
	mr.hook_site(here, function(regs)
		regs.r11 = -1
	end)
	check(call_target(3, 4) == 29, 'a negative number is written as a 64-bit value')
	mr.unhook(here)
	mr.hook_site(here, function(regs)
		regs.r11 = '\200\0\0\0\0\0\0\0'
	end)
	check(call_target(3, 4) == 230, 'eight raw bytes can be written to a register')
	mr.unhook(here)

	local function failing(what, callback)
		mr.hook_site(here, callback)
		local result = call_target(3, 4)
		local error_text = mr.hook_info(here).error
		check(result == 34 and contains(error_text, what), what .. ': ' .. tostring(error_text) .. ', result ' .. tostring(result))
		check(not mr.hook_info(here).attached, 'a failing site callback is detached: ' .. what)
	end
	failing("unknown register 'foo'", function(regs)
		return regs.foo
	end)
	failing('rsp is read only', function(regs)
		regs.rsp = mr.pointer('\0\0\0\0\0\0\0\0')
	end)
	failing('boom', function()
		error('boom')
	end)
	mr.hook_site(here, function(regs)
		seen.regs = regs
	end)
	call_target(3, 4)
	mr.unhook(here)
	check(
		contains(
			error_of(function()
				return seen.regs.rax
			end),
			'can be used only inside a site callback'
		),
		'a stored register object is dead outside its callback'
	)
	check(
		contains(
			error_of(function()
				seen.regs.rax = 1
			end),
			'can be used only inside a site callback'
		),
		'a stored register object cannot be written outside its callback'
	)
	mr.hook_site(here, function(regs)
		regs.r11d = 7
		error('after the write')
	end)
	check(call_target(3, 4) == 37, 'a write made before an error stays')
	mr.unhook(here)
	local broken = 0
	mr.hook_site(here, function(regs)
		broken = broken + 1
		regs.r11d = mr.add(regs.r11d, 1)
	end)
	mr.hook_site(here, function()
		error('first fails')
	end)
	check(call_target(3, 4) == 35 and broken == 1, 'a failing callback does not stop the ones after it')
	mr.unhook(here)

	mr.hook_site(here, function(regs)
		regs.r11d = mr.add(regs.r11d, 1)
	end)
	check(call_target(3, 4) == 35, 'a hook can be attached again after unhook')
	mr.unhook(here)

	local order = {}
	local function first_callback(regs)
		order[#order + 1] = 'first:' .. mr.tostring(regs.r11d)
		regs.r11d = mr.add(regs.r11d, 1)
	end
	local function second_callback(regs)
		order[#order + 1] = 'second:' .. mr.tostring(regs.r11d)
		regs.r11d = mr.mult(regs.r11d, 2)
	end
	mr.hook_site(here, first_callback)
	mr.hook_site(here, second_callback)
	check(call_target(3, 4) == 30 + 9, "callbacks run newest first and see each other's writes")
	check(order[1] == 'second:4' and order[2] == 'first:8', 'the order is second then first: ' .. table.concat(order, ' '))
	check(contains(error_of(mr.hook_site, here, first_callback), 'this callback is already attached'), 'the same callback twice is refused')
	mr.unhook(here, second_callback)
	check(call_target(3, 4) == 35 and mr.hook_info(here).callbacks == 1, 'unhook with a callback removes only that one')
	mr.unhook(here)

	mr.hook_site(here, function(regs)
		regs.r11d = 0
	end)
	local normal_calls = 0
	mr.hook(target, TARGET, function(a, b)
		normal_calls = normal_calls + 1
		return mr.hook_next(target, a, b)
	end)
	check(call_target(3, 4) == 30 and normal_calls == 1, 'a function hook and a site hook in one function both run')
	check(mr.hook_info(target).kind == 'function' and mr.hook_info(here).kind == 'site', 'each keeps its kind')
	check(mr.hook_info(target).cave == nil, 'a function hook has no cave')
	check(mr.hook_info(target).calls == 1 and mr.hook_info(here).calls == 1, 'each counts its own calls: ' .. mr.hook_info(here).calls)
	mr.unhook(target)
	check(call_target(3, 4) == 30 and normal_calls == 1, 'the site still runs after the function hook is detached')
	mr.unhook(here)
	mr.hook(target, TARGET, function(a, b)
		normal_calls = normal_calls + 1
		return mr.hook_next(target, a, b)
	end)
	check(call_target(3, 4) == 34 and normal_calls == 2, 'the function hook still runs after the site hook is detached')
	mr.unhook(target)

	check(contains(error_of(mr.hook, here, TARGET, function() end), 'already holds a site hook'), 'hook on a site address is refused')
	check(contains(error_of(mr.hook_site, target, function() end), 'already holds a function hook'), 'hook_site on a function hook address is refused')
	check(contains(error_of(mr.code_cave, here, '\144'), 'already holds a site hook'), 'code_cave on a site address is refused')
	check(contains(error_of(mr.write, here, 0, mr.uint8(0x90)), 'refused: the first bytes of a hooked function'), 'a write into the site is refused')
	check(contains(error_of(mr.hook_site, mr.add(here, 1), function() end), 'refused: '), 'a site inside an instruction is refused')
	local overlap, overlap_here = address('site_overlap'), address('site_overlap_here')
	mr.hook(overlap, TARGET, function(a, b)
		return mr.hook_next(overlap, a, b)
	end)
	check(
		contains(error_of(mr.hook_site, overlap_here, function() end), 'refused: the address lies in bytes another hook replaced'),
		'a site inside the bytes of a function hook is refused'
	)
	local overlap_b, overlap_b_here = address('site_overlap_b'), address('site_overlap_b_here')
	mr.hook_site(overlap_b_here, function() end)
	check(
		contains(error_of(mr.hook, overlap_b, TARGET, function() end), 'overlaps the first bytes of another hook'),
		'a function hook over the bytes of a site is refused'
	)
	check(contains(error_of(mr.hook_site, address('site_ret_here'), function() end), 'refused: a return or jump'), 'a site on a return is refused')
	check(
		contains(error_of(mr.hook_site, address('site_inbound_here'), function() end), 'refused: a jump in the function lands inside'),
		'a site with a jump into its bytes is refused'
	)
	check(
		contains(error_of(mr.hook_site, address('site_split_here'), function() end), 'refused: a jump in another part of the function lands inside'),
		'a site with a jump into its bytes from a cold part of the function is refused'
	)
	check(mr.hook_info(address('site_split_here')) == nil, 'and installs nothing')
	check(
		contains(error_of(mr.hook_site, address('site_table_here'), function() end), 'refused: a jump table'),
		'a site with a jump table entry into its bytes is refused'
	)
	check(
		contains(error_of(mr.hook_site, address('site_codetable_here'), function() end), 'refused: a jump table in the function'),
		'a site with a jump table entry in the code of its own function is refused'
	)
	check(contains(error_of(mr.hook_site, address('site_call_short_here'), function() end), 'refused: a call'), 'a site over a short call is refused')
	check(mr.hook_info(address('site_call_short_here')) == nil, 'and installs nothing')
	mr.hook_site(address('site_call_last_here'), function(regs)
		regs.rcx = 100
	end)
	check(mr.tonumber(mr.call(address('site_call_last'), 'int32(int32)', 5)) == 111, 'a call that ends the replaced bytes is allowed and works')
	mr.unhook(address('site_call_last_here'))
	check(
		contains(error_of(mr.hook_site, address('site_early_here'), function() end), 'cannot be decoded up to the address'),
		'a site after bytes that do not decode is refused'
	)
	check(
		contains(error_of(mr.hook_site, address('site_tail_here'), function() end), 'run past the end of the function'),
		'a site whose bytes run into the next function is refused'
	)
	check(
		contains(error_of(mr.hook_site, mr.add(address('site_leaf_mid_here'), 1), function() end), 'inside an instruction'),
		'a site inside an instruction of a leaf function is refused'
	)
	check(
		contains(error_of(mr.hook_site, address('site_leaf_inbound_here'), function() end), 'a jump in the function lands inside'),
		'a site with a jump into its bytes in a leaf function is refused'
	)
	mr.hook_site(address('site_leaf_here'), function(regs)
		regs.rax = 40
	end)
	check(mr.tonumber(mr.call(address('site_leaf'), 'int32(int32)', 5)) == 81, 'a site in a leaf function that nothing jumps into works')
	mr.unhook(address('site_leaf_here'))
	mr.hook_site(address('site_noise_here'), function(regs)
		regs.rax = 40
	end)
	check(mr.tonumber(mr.call(address('site_noise'), 'int32()')) == 41, 'a lone DWORD in read-only data that equals an address inside the bytes is not a table')
	mr.unhook(address('site_noise_here'))
	mr.hook_site(address('site_split_free'), function(regs)
		regs.rax = 40
	end)
	check(mr.tonumber(mr.call(address('site_split'), 'int32(int32)', 0)) == 40, 'a site in a split function that nothing jumps into works')
	mr.unhook(address('site_split_free'))
	check(contains(error_of(mr.hook_site, mr.alloc(16), function() end), 'refused: '), 'a site in data memory is refused')
	check(contains(error_of(mr.hook_site, mr.base, function() end), 'refused: '), 'a site in the exe headers is refused')
	check(contains(error_of(mr.hook_site, nil, function() end), 'address is NULL'), 'a NULL site is refused')
	check(contains(error_of(mr.hook_site, here, nil), 'function expected'), 'a missing callback is refused')
	local plus
	for module in mr.modules() do
		if string.find(module.name:lower(), 'memreader_plus', 1, true) then plus = module end
	end
	check(plus ~= nil and contains(error_of(mr.hook_site, mr.add(plus.base, 0x1000), function() end), 'refused: '), "a site in Plus's own module is refused")
	check(contains(error_of(mr.hook, mr.add(plus.base, 0x1000), 'void()', function() end), 'refused: '), "a hook in Plus's own module is refused")
	check(call_target(3, 4) == 34, 'refused sites leave the function alone')

	local flags_target = address('site_flags_target')
	check(mr.tonumber(mr.call(flags_target, 'int32()')) == 1, 'the flags test function sees ZF set')
	local flags_seen
	mr.hook_site(address('site_flags_here'), function(regs)
		flags_seen = regs.rflags
		regs.rflags = regs.rflags - 0x40
	end)
	check(mr.tonumber(mr.call(flags_target, 'int32()')) == 2, 'clearing ZF in rflags changes the branch')
	check(has_bit(flags_seen, 0x40), 'rflags shows ZF at the site: ' .. tostring(flags_seen))
	mr.unhook(address('site_flags_here'))
	mr.hook_site(address('site_flags_here'), function(regs)
		regs.rflags = regs.rflags + 0x100
	end)
	check(mr.tonumber(mr.call(flags_target, 'int32()')) == 1, 'the trap flag cannot be set from a callback')
	mr.unhook(address('site_flags_here'))

	local rip_target = address('site_rip_target')
	check(mr.tonumber(mr.call(rip_target, 'int32(int32)', 3)) == 10, 'the RIP-relative test function reads its data')
	mr.hook_site(address('site_rip_here'), function(regs)
		regs.rcx = 100
	end)
	check(mr.tonumber(mr.call(rip_target, 'int32(int32)', 3)) == 107, 'a site with a RIP-relative instruction in its bytes relocates it')
	mr.unhook(address('site_rip_here'))

	local probe, probe_here = address('site_probe'), address('site_probe_here')
	local buffer = mr.alloc(40 * 8)
	local FLAGS_IN, MISALIGN, OUT, FLAGS_OUT, RSP_AT_SITE = 16, 17, 18, 34, 35
	local names = { 'rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15' }
	local function value_of(slot)
		return (slot + 1) * 0x100000000 + (slot + 1) * 0x111
	end
	local function load_probe(misalign, raw)
		for slot = 0, 15 do
			put(buffer, slot, value_of(slot))
		end
		for slot, bytes in pairs(raw or {}) do
			mr.write(buffer, slot * 8, bytes)
		end
		put(buffer, FLAGS_IN, 0x247)
		put(buffer, MISALIGN, misalign)
		for slot = OUT, RSP_AT_SITE do
			put(buffer, slot, 0)
		end
		mr.call(probe, 'void(pointer)', buffer)
	end
	local function probe_preserved()
		for slot = 0, 15 do
			if slot ~= 4 and get(buffer, OUT + slot) ~= value_of(slot) then return false, names[slot + 1] end
		end
		return get(buffer, FLAGS_OUT) == 0x247 and get(buffer, OUT + 4) == get(buffer, RSP_AT_SITE), 'flags or rsp'
	end
	load_probe(0)
	check(probe_preserved(), 'the probe keeps every register without a hook')
	mr.hook_site(probe_here, function() end)
	for _, misalign in ipairs({ 0, 1 }) do
		load_probe(misalign)
		local kept, which = probe_preserved()
		check(kept, 'an empty site callback keeps every register, flags and rsp (misaligned ' .. misalign .. '): ' .. tostring(which))
	end
	mr.unhook(probe_here)
	local read_all
	mr.hook_site(probe_here, function(regs)
		read_all = { rsp = regs.rsp, rflags = regs.rflags, same = {} }
		for slot = 0, 15 do
			if slot ~= 4 then read_all.same[names[slot + 1]] = mr.eq(regs[names[slot + 1]], mr.read_pointer(buffer, slot * 8)) end
		end
		read_all.eax, read_all.r15d = mr.tonumber(regs.eax), mr.tonumber(regs.r15d)
	end)
	load_probe(0)
	local reads_ok = true
	for slot = 0, 15 do
		if slot ~= 4 and not read_all.same[names[slot + 1]] then
			reads_ok = false
			print('  register ' .. names[slot + 1] .. ' differs')
		end
	end
	check(reads_ok, 'a callback reads every general register at the site')
	check(read_all.eax == value_of(0) % 4294967296 and read_all.r15d == value_of(15) % 4294967296, 'the 32-bit views hold the low half')
	check(mr.eq(read_all.rsp, mr.read_pointer(buffer, RSP_AT_SITE * 8)), 'rsp reads the stack pointer at the site')
	check(read_all.rflags == 0x247, 'rflags reads the flags at the site: ' .. tostring(read_all.rflags))
	mr.unhook(probe_here)
	mr.hook_site(probe_here, function(regs)
		regs.rax = 0x123456789
		regs.rbx = mr.pointer('\1\2\3\4\5\6\0\0')
		regs.r9d = 5
		regs.r15 = regs.rcx
		regs.rbp = 0
		regs.rflags = 0
	end)
	load_probe(0)
	check(get(buffer, OUT) == 0x123456789, 'a callback writes rax')
	check(get(buffer, OUT + 3) == 0x060504030201, 'a callback writes rbx from a pointer value')
	check(get(buffer, OUT + 9) == 5, 'a write to r9d clears the upper half like the hardware')
	check(get(buffer, OUT + 15) == value_of(1), 'a callback copies one register into another')
	check(get(buffer, OUT + 5) == 0, 'a callback writes rbp')
	check(get(buffer, FLAGS_OUT) == 0x202, 'writing rflags 0 clears the status flags and keeps the rest: ' .. string.format('%x', get(buffer, FLAGS_OUT)))
	check(get(buffer, OUT + 1) == value_of(1) and get(buffer, OUT + 12) == value_of(12), 'registers the callback does not touch stay')
	check(get(buffer, OUT + 4) == get(buffer, RSP_AT_SITE), 'rsp is the same after the site')
	mr.unhook(probe_here)

	local WORDS = {
		ecx = { 1, '\255\255\255\255\0\0\0\0', 'uint32 4294967295' },
		edx = { 2, '\0\0\0\128\0\0\0\0', 'uint32 2147483648' },
		r8d = { 8, '\1\0\0\1\0\0\0\0', 'uint32 16777217' },
		r9d = { 9, '\121\86\52\18\0\0\0\0', 'uint32 305419897' },
	}
	local raw_words, seen_words = {}, {}
	for _, word in pairs(WORDS) do
		raw_words[word[1]] = word[2]
	end
	mr.hook_site(probe_here, function(regs)
		for name in pairs(WORDS) do
			seen_words[name] = mr.type(regs[name]) .. ' ' .. mr.tostring(regs[name])
			regs[name] = regs[name]
		end
	end)
	load_probe(0, raw_words)
	check(mr.hook_info(probe_here).error == nil, '32-bit views read and write without an error: ' .. tostring(mr.hook_info(probe_here).error))
	for name, word in pairs(WORDS) do
		check(seen_words[name] == word[3], name .. ' reads as ' .. word[3] .. ': ' .. tostring(seen_words[name]))
		check(mr.read(buffer, (OUT + word[1]) * 8, 8) == word[2], name .. ' keeps its value through a read and a write back')
	end
	mr.unhook(probe_here)
	mr.hook_site(probe_here, function(regs)
		regs.ecx = mr.uint32('\255\255\255\255')
		regs.edx = -1
		regs.r8d = 2147483648
		regs.r9d = mr.int32(-2147483648)
	end)
	load_probe(0, raw_words)
	check(mr.read(buffer, (OUT + 1) * 8, 8) == '\255\255\255\255\0\0\0\0', 'a typed uint32 is written exactly')
	check(mr.read(buffer, (OUT + 2) * 8, 8) == '\255\255\255\255\0\0\0\0', 'a plain -1 is written as 0xFFFFFFFF')
	check(mr.read(buffer, (OUT + 8) * 8, 8) == '\0\0\0\128\0\0\0\0', 'a plain 2^31 is written exactly')
	check(mr.read(buffer, (OUT + 9) * 8, 8) == '\0\0\0\128\0\0\0\0', 'a typed int32 is written as its 32 bits')
	mr.unhook(probe_here)
	local function refused_write(register, value, what)
		mr.hook_site(probe_here, function(regs)
			regs[register] = value
		end)
		load_probe(0, raw_words)
		local message = mr.hook_info(probe_here).error
		mr.unhook(probe_here)
		check(
			contains(message, what) and mr.read(buffer, (OUT + 1) * 8, 8) == raw_words[1],
			register .. ' refuses ' .. tostring(value) .. ': ' .. tostring(message)
		)
	end
	refused_write('ecx', 4294967296, 'whole number')
	refused_write('ecx', 1.5, 'whole number')
	refused_write('ecx', -3000000000, 'whole number')
	refused_write('rcx', 9223372036854775808, 'whole number')
	refused_write('rcx', 0.5, 'whole number')

	local xmm_probe, xmm_here = address('site_xmm_probe'), address('site_xmm_here')
	local xmm = mr.alloc(12 * 16)
	local DOUBLE_2_5 = '\0\0\0\0\0\0\4\64'
	local FLOAT_1_5 = '\0\0\192\63'
	local MARK = '\1\2\3\4'
	for slot = 0, 5 do
		mr.write(xmm, slot * 16, DOUBLE_2_5 .. string.rep(string.char(slot + 1), 8))
	end
	mr.write(xmm, 16, FLOAT_1_5 .. MARK .. string.rep('\2', 8))
	mr.call(xmm_probe, 'void(pointer)', xmm)
	check(mr.read(xmm, 96, 8) == DOUBLE_2_5, 'the xmm probe copies the registers without a hook')
	local doubles
	mr.hook_site(xmm_here, function(regs)
		doubles = { regs.xmm0, regs.xmm1f, regs.xmm5 }
		regs.xmm0 = 6.25
		regs.xmm1f = 4.5
		regs.xmm3 = 0
	end)
	mr.call(xmm_probe, 'void(pointer)', xmm)
	check(doubles[1] == 2.5 and doubles[2] == 1.5 and doubles[3] == 2.5, 'a callback reads xmm as double and as float')
	check(mr.read(xmm, 96, 16) == '\0\0\0\0\0\0\25\64' .. string.rep('\1', 8), 'a double write keeps the upper half of xmm0')
	check(mr.read(xmm, 96 + 16, 16) == '\0\0\144\64' .. MARK .. string.rep('\2', 8), 'a float write keeps the rest of xmm1')
	check(mr.read(xmm, 96 + 48, 16) == string.rep('\0', 8) .. string.rep('\4', 8), 'a double write of 0 clears the low half of xmm3')
	check(mr.read(xmm, 96 + 32, 16) == DOUBLE_2_5 .. string.rep('\3', 8), 'untouched xmm registers stay')
	mr.unhook(xmm_here)
	local PI = '\24\45\68\84\251\33\9\64'
	local EPSILON = '\1\0\0\0\0\0\240\63'
	for slot = 0, 5 do
		mr.write(xmm, slot * 16, string.rep(string.char(slot + 1), 16))
	end
	mr.write(xmm, 0, PI)
	mr.write(xmm, 16, EPSILON)
	local bit_type
	mr.hook_site(xmm_here, function(regs)
		bit_type = mr.type(regs.xmm0q)
		regs.xmm0q = regs.xmm0q
		regs.xmm2q = regs.xmm1q
		regs.xmm4q = mr.uint64('\1\2\3\4\5\6\7\8')
	end)
	mr.call(xmm_probe, 'void(pointer)', xmm)
	check(mr.hook_info(xmm_here).error == nil and bit_type == 'uint64', 'xmmNq reads as a uint64: ' .. tostring(mr.hook_info(xmm_here).error))
	check(mr.read(xmm, 96, 16) == PI .. string.rep('\1', 8), 'a double keeps all its bits through xmm0q')
	check(mr.read(xmm, 96 + 32, 16) == EPSILON .. string.rep('\3', 8), 'xmm2q takes the bits of xmm1q and keeps the upper half')
	check(mr.read(xmm, 96 + 64, 16) == '\1\2\3\4\5\6\7\8' .. string.rep('\5', 8), 'xmm4q takes a typed uint64')
	mr.unhook(xmm_here)

	if test_has_avx() then
		local vector_probe, vector_here = address('site_vector_probe'), address('site_vector_here')
		local vectors = mr.alloc(32 * 32)
		local pattern = {}
		for i = 0, 511 do
			pattern[#pattern + 1] = string.char((i * 7 + 3) % 251)
		end
		pattern = table.concat(pattern)
		mr.write(vectors, 0, pattern)
		mr.call(vector_probe, 'void(pointer)', vectors)
		check(mr.read(vectors, 512, 512) == pattern, 'the vector probe copies ymm0-15 without a hook')
		mr.hook_site(vector_here, function()
			test_clobber_vectors()
		end)
		mr.write(vectors, 512, string.rep('\0', 512))
		mr.call(vector_probe, 'void(pointer)', vectors)
		check(mr.read(vectors, 512, 512) == pattern, 'ymm0-15 survive a callback that runs vzeroupper')
		mr.unhook(vector_here)
		mr.write(vectors, 0, string.rep('\0', 512))
		mr.hook_site(vector_here, function()
			test_clobber_vectors()
		end)
		mr.write(vectors, 512, string.rep('\255', 512))
		mr.call(vector_probe, 'void(pointer)', vectors)
		check(mr.read(vectors, 512, 512) == string.rep('\0', 512), 'clean upper halves stay clean')
		mr.unhook(vector_here)
		mr.hook_site(vector_here, function()
			test_dirty_vectors()
		end)
		mr.write(vectors, 512, string.rep('\255', 512))
		mr.call(vector_probe, 'void(pointer)', vectors)
		check(mr.read(vectors, 512, 512) == string.rep('\0', 512), 'upper halves a callback dirtied are cleared when the game had none')
		mr.unhook(vector_here)
	else
		print('  skipped: this CPU has no AVX')
	end

	local single, single_here = address('site_single'), address('site_single_here')
	mr.hook_site(single_here, function(regs)
		regs.rcx = 100
	end)
	check(mr.tonumber(mr.call(single, 'int64(int64)', 5)) == 201, 'the single-argument site changes the result on the script thread')
	check(mr.tonumber(mr.call(address('call_on_thread'), 'int64(pointer, int64)', single, 5)) == 11, 'a call on another thread runs the original')
	check(mr.hook_info(single_here).calls == 1 and mr.hook_info(single_here).other_thread_calls == 1, 'calls on another thread are counted apart')
	mr.unhook(single_here)
	check(mr.tonumber(mr.call(single, 'int64(int64)', 5)) == 11, 'after unhook the original result returns')
	mr.hook_site(single_here, function(regs)
		regs.rcx = 100
	end)
	check(mr.hook_info(single_here).calls == 0, 'calls restart with a new chain')
	check(mr.tonumber(mr.call(single, 'int64(int64)', 5)) == 201, 'the site works again after unhook')

	local nested = {}
	mr.hook_site(here, function(outer)
		nested.outer_before = mr.tonumber(outer.r10d)
		mr.call(single, 'int64(int64)', 1)
		nested.outer_after = mr.tonumber(outer.r10d)
		nested.depth = mr.hook_depth()
	end)
	check(call_target(3, 4) == 34, 'nested site callbacks return')
	check(
		nested.outer_before == 3 and nested.outer_after == 3 and nested.depth == 1,
		'the outer registers survive a nested site: ' .. tostring(nested.outer_after)
	)
	mr.unhook(here)
	mr.unhook(single_here)

	local spin, spin_here = address('site_spin'), address('site_spin_here')
	local ROUNDS = 200000
	local function time_spin()
		local start = mr.ticks()
		mr.call(spin, 'void(int64)', ROUNDS)
		return mr.elapsed_us(start) * 1000 / ROUNDS
	end
	local function timed(callback)
		mr.hook_site(spin_here, callback)
		local result = time_spin()
		mr.unhook(spin_here)
		return result
	end
	local plain = time_spin()
	local empty = timed(function() end) - plain
	local one_pointer = timed(function(regs)
		local _ = regs.rdx
	end) - plain
	local numbers = timed(function(regs)
		regs.edx = regs.ecx
	end) - plain
	local pointers = timed(function(regs)
		regs.rdx = regs.rcx
	end) - plain
	mr.hook_site(spin_here, function() end)
	time_spin()
	check(mr.hook_info(spin_here).calls == ROUNDS, 'every loop pass ran the callback: ' .. tostring(mr.hook_info(spin_here).calls))
	mr.unhook(spin_here)
	print(
		string.format(
			'  timing: site loop %.0f ns, empty callback +%.0f ns, read a constant pointer register +%.0f ns, read and write 32-bit numbers +%.0f ns, read and write changing pointers +%.0f ns',
			plain,
			empty,
			one_pointer,
			numbers,
			pointers
		)
	)
elseif SCENARIO == 'site_unwind' then
	run_mod(OURS)
	io.stdout:setvbuf('no')
	local mr = _G.memreader_plus
	local here = mr.pointer(test_function('site_call_last_here'))
	local entry = test_function('site_call_last')
	local caught, result = test_catch_site_call(entry)
	check(not caught and result == 14, 'the function runs without a hook: ' .. tostring(result))
	mr.hook_site(here, function()
		test_crash()
	end)
	caught, result = test_catch_site_call(entry)
	check(caught, 'an exception raised in a site callback is handled by the game code around the hooked function')
	check(mr.hook_depth() == 0, 'the callback depth is back at 0 after the exception')
	check(mr.hook_info(here).calls == 1, 'the site ran the callback once')
	mr.unhook(here)
	mr.hook_site(here, function(regs)
		regs.rcx = 100
	end)
	caught, result = test_catch_site_call(entry)
	check(not caught and result == 111, 'the site works again after the exception: ' .. tostring(result))
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
	local function table_start(index)
		local headers = mr.add(mr.base, mr.read_int32(mr.base, 0x3c))
		return mr.add(mr.base, mr.read_uint32(headers, 0x18 + 0x70 + index * 8, true))
	end
	local system = module_named('kernel32.dll')
	local plus = module_named('memreader_plus')
	local target = mr.pointer(test_function('hook_target'))
	local TARGET = 'int32(int32, int32)'
	check(type(mr.code_cave) == 'function' and type(mr.hook_site) == 'function', 'code_cave and hook_site are part of the API')
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

	local cell = mr.alloc(8)
	local function raw(pointer)
		mr.write(cell, 0, pointer)
		return mr.read(cell, 0, 8)
	end
	local PAGE_READONLY, PAGE_READWRITE = 2, 4
	check(refused(mr.call, system.base, 'void()'), 'call into a system DLL header is refused')
	check(refused(mr.call, plus.base, 'void()'), "call into Plus's own module header is refused")
	check(refused(mr.call, mr.alloc(16), 'void()'), 'call into alloc memory is refused')
	check(refused(mr.call, mr.base, 'void()'), "call into the exe's headers is refused")
	local process_id = mr.pointer(test_system_address('kernel32.dll', 'GetCurrentProcessId'))
	check(mr.tonumber(mr.call(process_id, 'uint32()')) == test_process_id(), 'call into the executable code of a system DLL works')
	mr.hook(process_id, 'uint32()', function()
		return 4242
	end)
	check(mr.tonumber(mr.call(process_id, 'uint32()')) == 4242, "hook on a system DLL's code works")
	mr.unhook(process_id)
	check(mr.tonumber(mr.call(process_id, 'uint32()')) == test_process_id(), 'unhook of a system DLL function runs the original')
	check(refused(mr.hook, system.base, 'void()', function() end), "hook on a system DLL's header is refused")
	check(refused(mr.hook, mr.add(plus.base, 0x1000), 'void()', function() end), "hook on Plus's own code is refused")
	for _, module in ipairs({ system, plus }) do
		local first_byte = mr.read(module.base, 0, 1)
		check(test_protection(raw(module.base)) == PAGE_READONLY, module.name .. ' has a read-only header')
		check(pcall(mr.write, module.base, 0, first_byte) and mr.read(module.base, 0, 1) == first_byte, 'write into ' .. module.name .. ' works')
		check(test_protection(raw(module.base)) == PAGE_READONLY, 'and the header is read-only again')
	end
	check(mr.patch(mr.base, 'MZ', 'MZ') == 'MZ', "patch on the exe's headers with the bytes already there is a no-op")
	local imports = table_start(1)
	local import_bytes = mr.read(imports, 0, 4)
	check(mr.patch(imports, import_bytes, import_bytes) == import_bytes, "patch on the exe's import table with the bytes already there is a no-op")
	check(pcall(mr.write, imports, 0, import_bytes), "write into the exe's import table works")

	check(mr.tonumber(mr.call(target, TARGET, 1, 2)) == 12, 'call into the exe code works')
	mr.hook(target, TARGET, function(a, b)
		return mr.hook_next(target, a, b)
	end)
	local original = mr.hook_info(target).original
	check(mr.tonumber(mr.call(target, TARGET, 3, 4)) == 34, 'hook on the exe code works')
	check(mr.tonumber(mr.call(original, TARGET, 5, 6)) == 56, "call of a hook's original works")
	local trampoline_byte, trampoline_protection = mr.read(original, 0, 1), test_protection(raw(original))
	check(pcall(mr.write, original, 0, trampoline_byte) and mr.read(original, 0, 1) == trampoline_byte, "write into a hook's trampoline works")
	check(test_protection(raw(original)) == trampoline_protection, 'and the trampoline keeps its protection')
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
	local faults = test_access_faults()
	mr.write(code, 0, first)
	check(mr.read(code, 0, 1) == first, "write into the exe's code works")
	check(test_access_faults() == faults, "write into the exe's code raises no fault")
	local page = test_page()
	local read_only = mr.pointer(page)
	test_protect(page, 16, PAGE_READONLY)
	faults = test_access_faults()
	local wrote, why = pcall(mr.write, read_only, 0, mr.uint32(1))
	check(wrote and mr.read_uint32(read_only, 0) == 1, 'write into read-only data memory works: ' .. tostring(why))
	check(test_protection(page) == PAGE_READONLY, 'and the page is read-only again')
	check(test_access_faults() == faults + 1, 'the first try faults once and is recovered')
	test_protect(page, 16, PAGE_READWRITE)
	faults = test_access_faults()
	mr.write(read_only, 0, mr.uint32(3))
	check(mr.read_uint32(read_only, 0) == 3 and test_access_faults() == faults, 'write into data memory works without a fault')

	local function refuse_call()
		return pcall(mr.call, mr.base, 'void()')
	end
	local where = 'offline.lua:' .. (debug.getinfo(refuse_call, 'S').linedefined + 1)
	for _ = 1, 3 do
		refuse_call()
	end
	local ok, err = pcall(function()
		mr.write(target, 0, mr.uint8(0))
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
	or SCENARIO == 'fault_report_in_site'
	or SCENARIO == 'fault_report_thread'
	or SCENARIO == 'fault_report_native_thread'
	or SCENARIO == 'fault_report_overflow'
	or SCENARIO == 'fault_report_cpp'
	or SCENARIO == 'fault_report_fallback'
	or SCENARIO == 'fault_report_clues'
	or SCENARIO == 'exit_report_quiet'
	or SCENARIO == 'runtime_report_then_crash'
	or SCENARIO == 'settings_cut'
	or SCENARIO == 'settings_none'
	or HOST_FAULTS[SCENARIO]
then
	io.stdout:setvbuf('no')
	load_other_program_dll()
	if SCENARIO == 'fault_report_clues' then
		package.loadlib('.\\fake_speedhack64.dll', 'luaopen_fake_speedhack64')
		check(test_hook_timing('fake_speedhack64.dll'), 'the test hooks QueryPerformanceCounter and timeGetTime')
	end
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
	if (SCENARIO == 'fault_report_off' or SCENARIO == 'exit_report_off') and PASS > 1 then mr.set_crash_reports(false) end
	check(not pcall(mr.set_crash_context), 'set_crash_context needs a name')
	if PASS > 1 then fill_crash_context(mr) end
	if PASS > 1 then set_report_settings(mr) end
	if PASS > 1 and SCENARIO == 'fault_report' then fill_code_patches(mr) end
	if PASS > 1 and SCENARIO == 'runtime_report_then_crash' then
		local name = mr.write_runtime_report()
		check(type(name) == 'string' and exists(name), 'a runtime report is written before the crash: ' .. tostring(name))
	end
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
		local function crash_in_site()
			mr.hook_site(mr.pointer(test_function('site_crash_here')), function()
				test_crash()
			end)
			mr.call(mr.pointer(test_function('site_crash')), 'void()')
		end
		local function report_me()
			local marker = 'event-under-test'
			if SCENARIO == 'fault_report_in_callback' then
				crash_in_callback()
			elseif SCENARIO == 'fault_report_in_site' then
				crash_in_site()
			elseif SCENARIO == 'fault_report_no_log' then
				test_execute_crash()
			elseif SCENARIO == 'fault_report_native_thread' then
				test_thread_crash()
			elseif SCENARIO == 'fault_report_overflow' then
				test_stack_overflow()
			elseif SCENARIO == 'fault_report_cpp' then
				mr.call(mr.pointer(test_function('throw_out')), 'void()')
			elseif SCENARIO == 'fault_report_clues' then
				test_allocator_crash()
			elseif SCENARIO == 'exit_report_quiet' then
				os.exit(0)
			elseif HOST_FAULTS[SCENARIO] then
				test_fault(HOST_FAULTS[SCENARIO][1], HOST_FAULTS[SCENARIO][2], mr.set_crash_context)
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
	load_other_program_dll()
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
elseif SCENARIO:sub(1, 14) == 'runtime_report' then
	io.stdout:setvbuf('no')
	load_other_program_dll()
	run_mod(OURS)
	local mr = _G.memreader_plus
	if SCENARIO == 'runtime_report_no_folder' and PASS == 1 then
		test_fault('no_report_folder', false, mr.set_crash_context)
		NEXT_PASS = true
	else
		fill_crash_context(mr)
		set_report_settings(mr)
		if SCENARIO == 'runtime_report_reports_off' then mr.set_crash_reports(false) end
		if SCENARIO == 'runtime_report_write_fails' then block_runtime_report_names() end
		local name, why = mr.write_runtime_report()
		if SCENARIO == 'runtime_report_no_folder' or SCENARIO == 'runtime_report_write_fails' then
			check(name == nil and type(why) == 'string' and why ~= '', 'write_runtime_report gives nil and a message: ' .. tostring(why))
		else
			check(
				type(name) == 'string' and name:match('^memreader_runtime_report_%d%d%d%d%d%d_%d%d%d%d%d%d%.txt$') ~= nil,
				'write_runtime_report returns the file name: ' .. tostring(name)
			)
			check(exists(name), 'the named file is in the report folder')
		end
	end
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
elseif SCENARIO:sub(1, 9) == 'file_edit' then
	local logged = {}
	ModLog = function(msg)
		logged[#logged + 1] = msg
		print('  log: ' .. msg)
	end
	local function log_count(text)
		local count = 0
		for _, line in ipairs(logged) do
			if line:find(text, 1, true) then count = count + 1 end
		end
		return count
	end
	local spec_folder = 'vfs/script/memreader_plus/file_edits/'
	os.execute('mkdir "' .. spec_folder:gsub('/', '\\') .. '"')
	local function write(name, text)
		local file = io.open(spec_folder .. name, 'wb')
		file:write(text)
		file:close()
	end
	write(
		'good.lua',
		[[return {
	{ id = 'wide', path = 'ui/test/panel.twui.xml', ops = { { find = 'width="400"', with = 'width="500"' } } },
	'not a table',
	{ id = 'bad', path = 'ui/test/panel.twui.xml', ops = { { find = 'height="20"' } } },
	{ id = 'box', path = 'ui/test/module.twui.xml', changes = { { set = 'root/box', values = { width = 9 } } } },
	{ id = 'nobox', path = 'ui/test/module.twui.xml', changes = { { hide = 'nothing' } } },
}]]
	)
	write('broken.lua', "error('boom')")
	write('notable.lua', 'return 5')
	table.insert(VFS, 1, 'vfs')
	local lookup =
		'script/memreader_plus/file_edits/good.lua,script/memreader_plus/file_edits/broken.lua,script/memreader_plus/file_edits/notable.lua,script/memreader_plus/file_edits/readme.txt'
	os.execute('mkdir appdata')
	common = {
		filesystem_lookup = function()
			return lookup
		end,
		get_appdata_screenshots_path = function()
			return 'appdata/screenshots/'
		end,
	}
	local panel = 'ui\\test\\panel.twui.xml'
	if SCENARIO == 'file_edit_sites' then
		for _, name in ipairs({
			'parse_buffer',
			'xml_document',
			'xml_document_destroy',
			'load_layout_file',
			'fast_xml_parser',
			'clear_from_cache',
		}) do
			test_twin_site(name)
		end
	elseif SCENARIO == 'file_edit_off' then
		test_twin_site('load_buffer')
	elseif SCENARIO == 'file_edit_saved_off' then
		io.open('appdata/memreader_plus_file_edits_off.txt', 'wb'):close()
		get_mct = function() end
	end
	run_mod(OURS)
	local mr = _G.memreader_plus
	check(mr ~= nil, 'Plus loaded although three spec files are broken')
	local function edit(spec)
		local ok, why = mr.file_edit(spec)
		print('  file_edit ' .. tostring(spec.id) .. ': ' .. tostring(ok) .. ', ' .. tostring(why))
		return ok, why
	end
	local function width(id, priority, value)
		return edit({
			owner = id,
			id = 'w',
			path = 'ui/test/panel.twui.xml',
			priority = priority,
			ops = { { find = 'width="400"', with = 'width="' .. value .. '"' } },
		})
	end
	local function layout_has(text)
		return test_load_layout(panel):find(text, 1, true) ~= nil
	end
	local function patch_line(path, prefix)
		for _, file in ipairs(mr.file_edit_list()) do
			if file.path == path then
				for _, line in ipairs(file.patches) do
					if line:sub(1, #prefix) == prefix then return line end
				end
			end
		end
	end
	if SCENARIO == 'file_edit_off' then
		local ok, why = width('x', 0, 500)
		check(ok == nil and why == 'off: load_buffer found 2 times', 'a second load_buffer turns file edits off: ' .. tostring(why))
		check(mr.file_edit_status().state == why, 'state names the site')
		check(log_count('file edits off: load_buffer found 2 times') == 1, 'one log line for the site')
		check(layout_has('width="400"'), 'layouts load as they ship')
	elseif SCENARIO == 'file_edit_saved_off' then
		check(mr.file_edit_status().enabled == true, 'a switch file left from the old MCT option is ignored')
		check(width('x', 0, 500) == true and layout_has('width="500"'), 'edits register')
	elseif SCENARIO == 'file_edit_sites' then
		local ok, why = edit({ owner = 'x', id = 'model', path = 'models/test/unit.wsmodel', ops = { { find = 'skin_a', with = 'skin_b' } } })
		check(ok == nil and why == 'off: fast_xml', 'FAST_XML edits are refused without parse_buffer and validation')
		local status = mr.file_edit_status()
		check(table.concat(status.off, ',') == 'fast_xml,validation,path_check,eviction', 'parts off: ' .. table.concat(status.off, ','))
		check(status.state == 'on', 'the rest stays on')
		check(
			status.sites.parse_buffer == 'found 2 times: edits to FAST_XML files such as models and materials are refused',
			'site text: ' .. tostring(status.sites.parse_buffer)
		)
		check(status.sites.load_buffer == true, 'load_buffer found')
		ok, why = width('x', 0, 500)
		check(ok == true and why == 'applies from the next parse only: the layout cache cannot be cleared', 'layout edit registers with the eviction note')
		check(layout_has('width="500"'), 'content pairing works without the path check')
		for _, name in ipairs({
			'parse_buffer',
			'xml_document',
			'xml_document_destroy',
			'load_layout_file',
			'fast_xml_parser',
			'clear_from_cache',
		}) do
			check(log_count('file edits: ' .. name .. ' found 2 times: ') == 1, 'one log line for ' .. name)
		end
		ok = edit({ owner = 'x', id = 'broken', path = 'ui/test/panel.twui.xml', priority = 1, ops = { { find = 'height="20"', with = 'height="20"<' } } })
		check(ok == true, 'without validation a broken edit registers')
		local text, parse = test_load_layout(panel)
		check(parse == 0 and text:find('width="400"', 1, true) ~= nil, 'the hand-off parses the game bytes after the rejection')
		check(mr.file_edit_list()[1].rejected == 1, 'rejected counted')
	else
		check(
			log_count('file edit 2 of script/memreader_plus/file_edits/good.lua not registered: the entry is not a table') == 1,
			'a non-table entry is skipped with a log line'
		)
		check(
			log_count("file edit good/bad on ui/test/panel.twui.xml: file_edit: an op with find needs with ('' removes the text)") == 1,
			'with = nil is refused with a log line'
		)
		check(log_count('file edits of script/memreader_plus/file_edits/broken.lua not loaded: ') == 1, 'a spec file that errors is skipped')
		check(
			log_count('file edits of script/memreader_plus/file_edits/notable.lua not loaded: it returns no table') == 1,
			'a spec file without a table is skipped'
		)
		check(
			log_count('file edits of script/memreader_plus/file_edits/readme.txt not loaded: the name does not end in .lua') == 1,
			'a name without .lua is skipped'
		)
		check(layout_has('width="500"'), 'the good spec applies through LoadLayoutFile')
		local status = mr.file_edit_status()
		check(status.state == 'on' and #status.off == 0, 'all sites found')
		local from_cache, key = test_cache_clears()
		check(from_cache >= 2 and key == 'ui\\test\\module.twui.xml', 'the edited layouts were evicted: ' .. tostring(key))

		local ok, why = width('aaa', 5, 650)
		check(ok == true and layout_has('width="650"'), 'higher priority runs later and wins')
		check(patch_line(panel, 'good/wide') == 'good/wide skipped: replaced by aaa/w, which runs later', 'the loser names the winner')
		check(log_count('file edit good/wide on ui/test/panel.twui.xml: replaced by aaa/w, which runs later') == 1, 'the losing mod gets a log line')
		ok, why = width('aaa', -1, 650)
		check(ok == nil and why == 'replaced by good/wide, which runs later', 'lower priority loses: ' .. tostring(why))
		check(layout_has('width="500"'), 'the higher one shows')
		local before = test_cache_clears()
		check(mr.file_edit_remove('aaa', 'w') == true and test_cache_clears() == before + 1, 'remove evicts')
		check(layout_has('width="500"'), 'still the spec edit')

		check(edit({ owner = 'x', id = 'ins', path = panel, ops = { { after = { '<layout>', '<panel' }, insert = ' extra="1"' } } }) == true, 'insert')
		check(layout_has('<panel extra="1" id="a" width="500"'), 'insert lands after the last anchor')
		ok, why = edit({
			owner = 'x',
			id = 'atomic',
			path = panel,
			ops = { { find = 'height="20"', with = 'height="30"' }, { after = 'nothing here', find = 'a', with = 'b' } },
		})
		check(ok == nil and why == 'op 2: anchor 1 not found' and layout_has('height="20"'), 'a patch applies all ops or none')
		ok, why = edit({ owner = 'x', id = 'stop', path = panel, ops = { { after = '<panel', before = 'nothing', find = 'a', with = 'b' } } })
		check(ok == nil and why == 'op 1: stop text not found', 'missing stop text')
		ok, why = edit({ owner = 'x', id = 'broken', path = panel, ops = { { find = 'height="20"', with = 'height="20"<' } } })
		check(ok == nil and why == 'the edited file does not parse (status 11)', 'validation refuses a broken edit')
		check(layout_has('extra="1"') and layout_has('width="500"'), 'the other edits stay')
		mr.file_edit_remove('x', 'broken')

		local screen = 'ui\\loading_ui\\battle.twui.xml'
		ok, why = edit({ owner = 'x', id = 'two', path = screen, ops = { { find = 'width="31"', with = 'width="22"' } } })
		check(ok == nil and why == 'op 1: find text found 2 times, expected 1', 'count mismatch')
		check(
			edit({ owner = 'x', id = 'two', path = screen, once = true, ops = { { find = 'width="31"', with = 'width="22"', count = 2 } } }) == true,
			'count 2'
		)
		check(test_load_screen(screen) == '<screen><card width="22"/><card width="22"/></screen>', 'once edit on a content-only read')
		check(test_load_screen(screen):find('width="31"', 1, true) ~= nil, 'once: the next read gets the game bytes')
		check(patch_line('ui\\loading_ui\\battle.twui.xml', 'x/two') == nil, 'used once edit swept')
		check(
			edit({ owner = 'x', id = 'first', path = screen, ops = { { after = '<card', before = '/>', find = 'width="31"', with = 'width="5"' } } }) == true,
			'stop text bounds the find'
		)
		check(test_load_screen(screen) == '<screen><card width="5"/><card width="31"/></screen>', 'only the first card changed')

		check(edit({ owner = 'x', id = 'ta', path = 'ui/test/twin_a.twui.xml', ops = { { find = '1', with = 'A' } } }) == true, 'twin a')
		ok, why = edit({ owner = 'x', id = 'tb', path = 'ui/test/twin_b.twui.xml', ops = { { find = '1', with = 'B' } } })
		check(
			ok == true and why == 'same bytes as ui\\test\\twin_a.twui.xml: a reader that gives no path gets the edits of the file registered first',
			'twin warning: ' .. tostring(why)
		)
		check(test_load_layout('ui\\test\\twin_b.twui.xml') == '<twin size="B"/>', 'the path check picks the named twin')
		check(test_load_screen('ui\\test\\twin_b.twui.xml') == '<twin size="A"/>', 'a content-only read gets the first twin')

		local evictions_before = test_cache_clears()
		local tpl_ok, tpl_why = edit({ owner = 'x', id = 'tpl', path = 'ui/templates/button.twui.xml', ops = { { find = '10', with = '12' } } })
		check(
			tpl_ok == true
				and tpl_why == 'applies to layouts read from now on: layouts the game already holds keep the old template'
				and test_cache_clears() == evictions_before + 1,
			'a template edit evicts only the template: ' .. tostring(tpl_why)
		)

		check(edit({ owner = 'x', id = 'model', path = 'models/test/unit.wsmodel', ops = { { find = 'skin_a', with = 'skin_b' } } }) == true, 'FAST_XML edit')
		local text, parsed = test_fast_xml('models\\test\\unit.wsmodel')
		check(text == '<model><material>skin_b</material></model>' and parsed == 1, 'FAST_XML hand-off gets the edit')
		ok, why = edit({ owner = 'x', id = 'model2', path = 'models/test/unit.wsmodel', ops = { { find = '</model>', with = '</model' } } })
		check(ok == nil and why == 'the edited file does not parse (status 11)', 'broken FAST_XML edit refused')

		ok, why = edit({ owner = 'x', id = 'w', path = 'ui/test/wide.twui.xml', ops = { { find = 'a', with = 'b' } } })
		check(ok == nil and why == 'no such file, or a UTF-16 file', 'UTF-16 refused')
		ok, why = edit({ owner = 'x', id = 'm', path = 'ui/test/missing.twui.xml', ops = { { find = 'a', with = 'b' } } })
		check(ok == nil and why == 'no such file, or a UTF-16 file', 'missing file refused')

		local files_before = mr.file_edit_status().files
		local nine = {}
		for i = 1, 33 do
			nine[i] = 'a'
		end
		local ops = {}
		for i = 1, 4097 do
			ops[i] = { find = 'x', with = 'y' }
		end
		local bad = {
			{ 5, 'file_edit: takes a table' },
			{ { owner = 'x', id = 'b', ops = {} }, 'file_edit: path must be a string' },
			{ { owner = 'x', id = 'b', path = panel, ops = { { after = nine, find = 'a', with = 'b' } } }, 'file_edit: after takes at most 32 texts' },
			{
				{ owner = 'x', id = 'b', path = panel, ops = { { after = '', find = 'a', with = 'b' } } },
				'file_edit: after must be a string of 1 byte or more without a zero byte',
			},
			{
				{ owner = 'x', id = 'b', path = panel, ops = { { after = { 'a', 5 }, find = 'a', with = 'b' } } },
				'file_edit: each text in after must be a string of 1 byte or more without a zero byte',
			},
			{ { owner = 'x', id = 'b', path = panel, ops = { { find = 'a' } } }, "file_edit: an op with find needs with ('' removes the text)" },
			{ { owner = 'x', id = 'b', path = panel, priority = 0 / 0, ops = { { find = 'a', with = 'b' } } }, 'file_edit: priority must be a finite number' },
			{
				{ owner = 'x', id = 'b', path = panel, priority = math.huge, ops = { { find = 'a', with = 'b' } } },
				'file_edit: priority must be a finite number',
			},
			{ { owner = 'x', id = 'b', path = panel, priority = '5', ops = { { find = 'a', with = 'b' } } }, 'file_edit: priority must be a number' },
			{
				{ owner = 'x', id = 'b', path = panel, ops = { { find = 'a', with = 'b', count = 1.5 } } },
				'file_edit: count must be a whole number from 1 to 100000',
			},
			{ { owner = 'x', id = 'b', path = panel, ops = ops }, 'file_edit: at most 4096 ops per edit' },
			{ { owner = 'x', id = 'b', path = panel, ops = { 'op' } }, 'file_edit: each op must be a table' },
			{ { owner = 'x', id = 'b', path = panel, ops = {} }, 'file_edit: ops must list at least one op' },
			{
				{ owner = 'x', id = 'b', path = panel, ops = { { find = 'a', insert = 'b' } } },
				'file_edit: each op needs one of find, insert, attribute or child',
			},
			{ { owner = 5, id = 'b', path = panel, ops = { { find = 'a', with = 'b' } } }, 'file_edit: owner must be a string' },
			{ { owner = 'x', id = 'b', path = panel, prioriy = 1, ops = { { find = 'a', with = 'b' } } }, "file_edit: unknown key 'prioriy' in the edit" },
			{ { owner = 'x', id = 'b', path = panel, ops = { { find = 'a', wiht = 'b' } } }, "file_edit: unknown key 'wiht' in an op" },
			{
				{ owner = 'x', id = 'b', path = panel, ops = { [1] = { find = 'a', with = 'b' }, [3] = { find = 'a', with = 'b' } } },
				'file_edit: ops must be a list without gaps',
			},
			{ { owner = 'x', id = 'b', path = panel, once = 'yes', ops = { { find = 'a', with = 'b' } } }, 'file_edit: once must be true or false' },
			{
				{ owner = 'x', id = 'b', path = '../x.twui.xml', ops = { { find = 'a', with = 'b' } } },
				'file_edit: path must be a path inside the packs: no drive letter, no leading \\\\ and no .. part',
			},
			{ { owner = 'x', id = 'b', path = panel, ops = { { attribute = 'w', value = '1' } } }, 'file_edit: an op with attribute or child needs after' },
			{
				{ owner = 'x', id = 'b', path = panel, ops = { { after = 'a', attribute = '1w', value = '1' } } },
				'file_edit: attribute and child must be XML names',
			},
			{ { owner = 'x', id = 'b', path = panel, ops = { { after = 'a', attribute = 'w' } } }, 'file_edit: an op with attribute needs value' },
			{
				{ owner = 'x', id = 'b', path = panel, ops = { { after = 'a', insert = 'x', before = 'y' } } },
				'file_edit: with, before and count go only with find',
			},
			{
				{ owner = 'x', id = 'b', path = panel, ops = { { after = 'a', attribute = 'w', value = 'a\1' } } },
				'file_edit: value holds a control character other than tab or a line break',
			},
			{ { owner = 'x', id = 'b', path = panel, ops = { { after = 'a', child = 'list' } } }, 'file_edit: an op with child needs insert' },
		}
		for _, case in ipairs(bad) do
			local call_ok, result, message = pcall(mr.file_edit, case[1])
			check(call_ok and result == nil and message == case[2], 'nil, why: ' .. tostring(message))
		end
		check(mr.file_edit_status().files == files_before, 'bad input registers nothing')

		local edited, base = mr.file_edit_preview(panel)
		check(edited:find('extra="1"', 1, true) and base:find('width="400"', 1, true), 'preview gives edited and base text')
		check(mr.file_edit_list()[1].edited_size > 0, 'list gives the edited size')

		mr.set_file_edits(false)
		ok, why = width('y', 0, 700)
		check(ok == nil and why == 'off: switched off by the player', 'player switch refuses new edits')
		check(layout_has('width="400"'), 'player switch serves the game bytes')
		mr.set_file_edits(true)
		check(layout_has('width="500"'), 'back on')
		mr.set_file_edits(false, panel)
		check(layout_has('width="400"'), 'per-file switch')
		mr.set_file_edits(true, panel)
		check(layout_has('width="500"'), 'per-file switch back on')

		local module = 'ui\\test\\module.twui.xml'
		check(test_load_layout(module):find('width="9"', 1, true) ~= nil, 'a declared TWUI change applies through LoadLayoutFile')
		check(
			log_count('file edit good/nobox on ui/test/module.twui.xml: change 1, hide nothing: matches 0 components, expected 1') == 1,
			'a broken selector is refused with one log line'
		)
		ok, why = mr.twui.edit({ owner = 'x', id = 'box', path = module, changes = { { set = 'box', values = { width = 9 }, expect = { width = 8 } } } })
		check(ok == nil and why == 'change 1, set box: box width is "7", expected "8"', 'expect check: ' .. tostring(why))
		local edited = mr.twui.preview({ path = module, changes = { { hide = 'root/box' } } })
		check(edited and edited:find('width="7" visible="false"/>', 1, true) ~= nil, 'preview adds the attribute at the end of the tag')
		ok, why = mr.twui.edit({ owner = 'x', id = 'same', path = module, changes = { { set = 'box', values = { width = 7 } } } })
		check(ok == true and why == nil, 'a value the file already has still registers: ' .. tostring(why))
		mr.file_edit_remove('x', 'same')

		local twui = mr.twui
		local layout = table.concat({
			'<layout><hierarchy><root this="R"><panel this="0A-0B-0C-0D"><icon this="I1"/></panel><other this="O"><icon this="I2"/></other>',
			'<bare this="N"/><tpl this="T"/></root></hierarchy><components><root this="R" id="root"/>',
			'<panel this="0A-0B-0C-0D" id="panel" width="15"><callbackwithcontextlist><callback_with_context callback_id="Old"/></callbackwithcontextlist>',
			'<states><a this="S1" name="a" width="10"><imagemetrics><image this="M1" width="10"/></imagemetrics></a><b this="S2" name="b" width="10"/></states>',
			'<componentimages><component_image this="C1" imagepath="a.png"/></componentimages><LayoutEngine type="List" spacing="2"/></panel>',
			'<icon this="I1" id="icon"/><other this="O" id="other"><states/></other><icon this="I2" id="icon"/><bare this="N" id="bare"/>',
			'<tpl this="T" id="tpl" part_of_template="true"><states><s this="S3" width="1"/></states></tpl></components></layout>',
		})
		local function preview(...)
			return twui.preview({ path = 'x', changes = { ... } }, layout)
		end
		local function refused(expected, ...)
			local edited, problem = preview(...)
			check(edited == nil and problem == expected, 'twui refuses: ' .. expected .. ' (got ' .. tostring(problem) .. ')')
		end
		local function previewed(label, wanted, op_count, ...)
			local edited, ops = preview(...)
			local found = edited ~= nil and edited:find(wanted, 1, true) ~= nil
			check(found and #ops == op_count, ('twui %s: %s ops'):format(label, edited and #ops or tostring(ops)))
			return edited, ops
		end
		previewed('component attribute', 'id="panel" width="12"', 1, { set = 'panel', values = { width = 12 } })
		previewed('escaped value', 'id="bare" tooltip_text="a &lt; b &amp; &quot;c&quot;"/>', 1, { set = 'bare', values = { tooltip_text = 'a < b & "c"' } })
		previewed('negative whole number', 'id="panel" width="-3"', 1, { set = 'panel', values = { width = -3 } })
		local _, ops = previewed('all states', 'name="b" width="20"', 2, { set = 'panel', on = 'state', values = { width = 20 } })
		check(ops[1].attribute == 'width' and ops[1].value == '20' and ops[1].find == nil, 'twui sets are attribute ops')
		previewed('where', 'name="a" width="20"', 1, { set = 'panel', on = 'state', where = { name = 'a' }, values = { width = 20 } })
		_, ops = previewed(
			'state and image',
			'this="M1" width="5"',
			3,
			{ set = 'panel', on = 'state', values = { width = 5 } },
			{ set = 'panel', on = 'image', values = { width = 5 } }
		)
		check(ops[3].after[2] == 'this="M1"', 'twui anchors each element at its own GUID')
		previewed('component_image', 'imagepath="b.png"', 1, { set = 'panel', on = 'component_image', values = { imagepath = 'b.png' } })
		previewed('engine', 'type="List" spacing="4"', 1, { set = 'panel', on = 'engine', values = { spacing = 4 } })
		previewed('engine insert', '<LayoutEngine type="List" spacing="2" margin="1"/>', 1, { set = 'panel', on = 'engine', values = { margin = 1 } })
		previewed('GUID selector', 'width="15" visible="false">', 1, { hide = '0A-0B-0C-0D' })
		previewed('id path', 'this="I2" id="icon" visible="false"', 1, { hide = 'root/other/icon' })
		previewed('short id path', 'this="I1" id="icon" visible="false"', 1, { hide = 'panel/icon' })
		refused('change 1, hide root/icon: matches 2 components, expected 1', { hide = 'root/icon' })
		previewed('expect', 'id="panel" width="11"', 1, { set = 'panel', values = { width = 11 }, expect = { width = 15, id = 'panel' } })
		previewed(
			'existing callback list',
			'<callbackwithcontextlist><callback_with_context callback_id="New" context_object_id="C"/><callback_with_context callback_id="Old"/>',
			1,
			{
				add_callback = 'panel',
				values = { callback_id = 'New', context_object_id = 'C' },
			}
		)
		previewed('new callback list', 'id="other"><callbackwithcontextlist><callback_with_context callback_id="A"/></callbackwithcontextlist><states/>', 1, {
			add_callback = 'other',
			values = { callback_id = 'A' },
		})
		previewed('mixed changes', 'id="panel" width="12" visible="false">', 3, { set = 'panel', values = { width = 12 } }, { hide = 'panel' }, {
			add_callback = 'panel',
			values = { callback_id = 'New' },
		})
		previewed('later change wins', 'id="panel" width="13"', 1, { set = 'panel', values = { width = 12 } }, { set = 'panel', values = { width = 13 } })
		previewed(
			'callbacks share one new list',
			'<callbackwithcontextlist><callback_with_context callback_id="A"/><callback_with_context callback_id="B"/></callbackwithcontextlist><states/>',
			1,
			{ add_callback = 'other', values = { callback_id = 'A' } },
			{ add_callback = 'other', values = { callback_id = 'B' } }
		)
		local same, one = preview({ set = 'panel', values = { width = 15 } })
		check(same == layout and #one == 1, 'twui preview of a value the file has gives the file back and one op')
		refused('change 1, hide icon: matches 2 components, expected 1', { hide = 'icon' })
		refused(
			"change 1, hide nothing: matches 0 components, expected 1 (an id matches as written or as the layout's <hierarchy> block spells it)",
			{ hide = 'nothing' }
		)
		refused('change 2, is not a table', { hide = 'bare' }, 5)
		refused('change 1, needs set, hide or add_callback', { on = 'state' })
		refused('change 1, has more than one of set, hide and add_callback', { set = 'bare', hide = 'bare' })
		refused('change 1, set must be a component id path or GUID', { set = 5, values = { width = 1 } })
		refused('change 1, set bare: values must be a table of attribute = value', { set = 'bare' })
		refused('change 1, set bare: values must be a table of attribute = value', { set = 'bare', values = {} })
		refused('change 1, set bare: values: 1a is not an attribute name', { set = 'bare', values = { ['1a'] = 1 } })
		refused('change 1, set bare: values: width must be text or a whole number below 10000000', { set = 'bare', values = { width = 1.5 } })
		refused('change 1, set bare: values: width must be text or a whole number below 10000000', { set = 'bare', values = { width = 1e8 } })
		refused('change 1, set bare: values: width must be text or a whole number below 10000000', { set = 'bare', values = { width = true } })
		refused('change 1, set bare: values: width holds a control character other than tab or a line break', { set = 'bare', values = { width = 'a\1' } })
		refused(
			'change 1, set bare: on must be component, state, image, text, component_image or engine',
			{ set = 'bare', on = 'states', values = { width = 1 } }
		)
		refused('change 1, set bare: where must be a table of attribute = value', { set = 'bare', where = 5, values = { width = 1 } })
		refused('change 1, set bare: expect must be a table of attribute = value', { set = 'bare', expect = {}, values = { width = 1 } })
		refused('change 1, set bare: no state matches', { set = 'bare', on = 'state', values = { width = 1 } })
		refused('change 1, set panel: no state matches', { set = 'panel', on = 'state', where = { name = 'c' }, values = { width = 1 } })
		refused('change 1, set panel: panel height is missing, expected "1"', { set = 'panel', values = { width = 1 }, expect = { height = 1 } })
		refused('change 1, set panel: a width is "10", expected "9"', { set = 'panel', on = 'state', values = { width = 1 }, expect = { width = 9 } })
		refused(
			'change 1, set tpl: it is part of a template: the game ignores its states, images, texts and engine, so edit the template',
			{ set = 'tpl', on = 'state', values = { width = 2 } }
		)
		previewed('template part component attribute', 'part_of_template="true" width="2">', 1, { set = 'tpl', values = { width = 2 } })
		refused('change 1, add_callback panel: values needs callback_id', { add_callback = 'panel', values = { x = 1 } })
		refused('change 1, add_callback bare: bare has no body to add a callback to', { add_callback = 'bare', values = { callback_id = 'A' } })
		local edited, problem = twui.preview({ path = 'x', changes = {} }, layout)
		check(edited == nil and problem == 'changes must be a list of one or more changes', 'twui empty changes')
		edited, problem = twui.preview({ path = 'x', changes = 'hide' }, layout)
		check(edited == nil and problem == 'changes must be a list of one or more changes', 'twui changes not a table')
		edited, problem = twui.preview({ changes = { { hide = 'bare' } } }, layout)
		check(edited == nil and problem == 'takes an edit table with a path', 'twui spec without a path')
		edited, problem = twui.preview(5)
		check(edited == nil and problem == 'takes an edit table with a path', 'twui spec not a table')
		edited, problem = twui.preview({ path = 'x', changes = { { hide = 'a' } } }, '\255\254<\0')
		check(edited == nil and problem == 'the file is UTF-16', 'twui UTF-16')
		edited, problem = twui.preview({ path = 'x', changes = { { hide = 'a' } } }, '<a/>')
		check(edited == nil and problem == 'not a TWUI layout: <hierarchy> or <components> is missing', 'twui not a layout')
		edited, problem = twui.preview({ path = 'x', changes = { { hide = 'a' } } }, '<l><hierarchy><a this="x"></hierarchy><components></components></l>')
		check(edited == nil and problem == 'the <hierarchy> block does not parse', 'twui broken hierarchy')
		edited, problem = twui.preview({ path = 'x', changes = { { hide = 'bare' } } }, (layout:gsub('<bare this="N" id="bare"/>', '')))
		check(edited == nil and problem == 'change 1, hide bare: its definition is missing', 'twui definition missing')
		edited, problem = twui.preview({ path = 'x', changes = { { hide = 'bare' } } }, (layout:gsub('<bare this="N" id="bare"/>', '%0%0')))
		check(edited == nil and problem == 'change 1, hide bare: its GUID is defined twice', 'twui GUID twice')
		edited = twui.preview({ path = 'x', ops = { { after = '<bare', before = '/>', find = 'this', with = 'that' } } }, layout)
		check(edited and edited:find('<bare that="N"', 1, true) ~= nil, 'twui preview applies plain ops')
		edited, problem = twui.preview({ path = 'x', ops = { { find = 'this', with = 'that' } } }, layout)
		check(edited == nil and problem:find('^op 1: find text found %d+ times, expected 1') ~= nil, 'twui preview op problem: ' .. tostring(problem))
		local files_before = #mr.file_edit_list()
		edited = mr.file_edit_apply('<a x="1"/>', { { after = '<a', attribute = 'x', value = '2&' }, { after = '<a', attribute = 'y', value = '3' } })
		check(edited == '<a x="2&amp;" y="3"/>', 'file_edit_apply runs the core ops on a text: ' .. tostring(edited))
		edited, problem = mr.file_edit_apply('<a/>', { { after = '<b', insert = 'x' } })
		check(edited == nil and problem == 'op 1: anchor 1 not found', 'file_edit_apply op problem: ' .. tostring(problem))
		edited, problem = mr.file_edit_apply('<a/>', { { insert = 'x', count = 2 } })
		check(
			edited == nil and problem == 'file_edit: with, before and count go only with find',
			'file_edit_apply checks ops like file_edit: ' .. tostring(problem)
		)
		edited, problem = mr.file_edit_apply('<a/>', {})
		check(edited == nil and problem == 'file_edit: ops must list at least one op', 'file_edit_apply refuses no ops: ' .. tostring(problem))
		edited, problem = mr.file_edit_apply(5, 'x')
		check(edited == nil and problem == 'file_edit: ops must be a list of ops', 'file_edit_apply refuses ops that are not a list: ' .. tostring(problem))
		check(#mr.file_edit_list() == files_before, 'file_edit_apply registers nothing')
		edited = twui.preview({ path = module, changes = { { set = 'box', values = { width = 4 } } } })
		check(edited and edited:find('id="box" width="4"', 1, true) ~= nil, 'twui preview reads the pack file')
		edited, problem = twui.preview({ path = 'ui/test/none.twui.xml', changes = { { hide = 'box' } } })
		check(edited == nil and problem == 'no such file: ui/test/none.twui.xml', 'twui preview of a missing file')
		local states = {}
		for i = 1, 4097 do
			states[i] = ('<s%d this="Q%d"/>'):format(i, i)
		end
		local big = '<l><hierarchy><big this="G"/></hierarchy><components><big this="G" id="big"><states>'
			.. table.concat(states)
			.. '</states></big></components></l>'
		edited, problem = twui.preview({ path = 'x', changes = { { set = 'big', on = 'state', values = { width = 1 } } } }, big)
		check(edited == nil and problem == 'the changes need 4097 ops, at most 4096: split them into several edits', 'twui op cap: ' .. tostring(problem))

		ok, why = twui.edit({ owner = 5, id = 'x', path = module, changes = { { hide = 'box' } } })
		check(ok == nil and why == 'owner and id must be strings', 'twui edit owner check')
		ok, why = twui.edit({ owner = 'x', id = 'x', path = 'ui/test/none.twui.xml', changes = { { hide = 'box' } } })
		check(ok == nil and why == 'no such file: ui/test/none.twui.xml', 'twui edit of a missing file')
		ok, why = twui.edit({ owner = 'x', id = 'x', path = module, priority = '5', changes = { { hide = 'box' } } })
		check(ok == nil and why == 'file_edit: priority must be a number', 'twui edit passes priority on: ' .. tostring(why))
		mr.file_edit_remove('good', 'box')
		check(
			twui.edit({ owner = 'x', id = 'once', path = module, once = true, changes = { { set = 'box', values = { width = 3 } } } }) == true,
			'twui once edit'
		)
		check(test_load_screen(module):find('width="3"', 1, true) ~= nil, 'twui once edit applies')
		check(test_load_screen(module):find('width="7"', 1, true) ~= nil, 'twui once edit used once')
		ok, why = twui.edit({ owner = 'x', id = 'hide', path = module, changes = { { hide = 'box' } } })
		check(ok == true and test_load_layout(module):find('visible="false"', 1, true) ~= nil, 'twui edit applies: ' .. tostring(why))
		local unknown = "change 1, hide nothing: matches 0 components, expected 1 (an id matches as written or as the layout's <hierarchy> block spells it)"
		ok, why = twui.edit({ owner = 'x', id = 'hide', path = module, changes = { { hide = 'nothing' } } })
		check(ok == nil and why == unknown, 'twui edit refusal')
		check(log_count('file edit x/hide on ' .. module .. ': ' .. unknown) == 1, 'twui edit refusal logged once')
		ok, why = twui.edit({ owner = 'x', id = 'hide', path = module, changes = { { set = 'box', values = { width = 7 } } } })
		check(ok == true and test_load_layout(module):find('visible="false"', 1, true) == nil, 'registering the id again replaces the old edit')
		mr.file_edit_remove('x', 'hide')

		local rich = 'ui/test/rich.twui.xml'
		local rich_file = 'ui\\test\\rich.twui.xml'
		local function count_text(text, needle)
			local count, at = 0, text:find(needle, 1, true)
			while at do
				count = count + 1
				at = text:find(needle, at + 1, true)
			end
			return count
		end
		local all_kinds = {
			{ set = 'panel', values = { width = 20 } },
			{ set = 'panel', on = 'state', where = { name = 'a' }, values = { width = 11 } },
			{ set = 'panel', on = 'text', values = { font_m_size = 8 }, expect = { font_m_size = 12 } },
			{ hide = 'panel/kills' },
			{ add_callback = 'panel', values = { callback_id = 'A', context_object_id = 'x > y' } },
		}
		local previewed_text = twui.preview({ path = rich, changes = all_kinds })
		ok, why = twui.edit({ owner = 'eq', id = 'all', path = rich, changes = all_kinds })
		check(ok == true and test_load_layout(rich_file) == previewed_text, 'the core makes the same text as the module preview: ' .. tostring(why))
		check(
			previewed_text:find('<component_text font_m_size="8"/></a><b this="S2" name="b" width="10"><component_text font_m_size="8"/>', 1, true) ~= nil,
			'on text sets every state text'
		)
		check(previewed_text:find('context_object_id="x &gt; y"', 1, true) ~= nil, 'callback values are escaped')
		mr.file_edit_remove('eq', 'all')

		ok = twui.edit({ owner = 'mod_a', id = 'a', path = rich, changes = { { set = 'panel', values = { width = 100 } }, { hide = 'kills' } } })
		why = select(2, twui.edit({ owner = 'mod_b', id = 'b', path = rich, priority = 1, changes = { { set = 'panel', values = { width = 200 } } } }))
		local text = test_load_layout(rich_file)
		check(
			ok == true and why == nil and text:find('width="200"', 1, true) and text:find('id="kills" visible="false"', 1, true),
			'two mods set one attribute: the later wins, the earlier keeps its other changes'
		)
		check(patch_line('ui\\test\\rich.twui.xml', 'mod_a/a') == 'mod_a/a applied', 'the earlier mod stays applied')
		twui.edit({ owner = 'mod_b', id = 'b', path = rich, priority = -1, changes = { { set = 'panel', values = { width = 200 } } } })
		check(test_load_layout(rich_file):find('id="panel" width="100"', 1, true) ~= nil, 'with a lower priority it runs first and loses that attribute')
		twui.edit({ owner = 'mod_b', id = 'b', path = rich, changes = { { hide = 'kills' }, { add_callback = 'panel', values = { callback_id = 'B' } } } })
		twui.edit({ owner = 'mod_c', id = 'c', path = rich, changes = { { add_callback = 'panel', values = { callback_id = 'C' } } } })
		text = test_load_layout(rich_file)
		check(count_text(text, 'visible=') == 1, 'two mods hiding one component give one visible attribute')
		check(
			count_text(text, '<callbackwithcontextlist>') == 1 and text:find('callback_id="B"', 1, true) and text:find('callback_id="C"', 1, true),
			'callbacks of two mods share one list'
		)
		ok, why =
			mr.file_edit({ owner = 'raw_a', id = 'v', path = rich, ops = { { after = { '<components>', '<kills this="K"' }, insert = ' visible="true"' } } })
		check(ok == nil and why == 'the edited file has an attribute twice in one tag', 'an insert that doubles an attribute is refused: ' .. tostring(why))
		mr.file_edit_remove('raw_a', 'v')
		ok, why = twui.edit({ owner = 'mod_d', id = 'd', path = rich, changes = { { hide = 'kill_ratio_PH' } } })
		check(
			ok == true and test_load_layout(rich_file):find('id="kill_ratio_PH" visible="false"', 1, true) ~= nil,
			'a selector may use the component id as written: ' .. tostring(why)
		)
		for _, owner in ipairs({ 'mod_a', 'mod_b', 'mod_c', 'mod_d' }) do
			mr.file_edit_remove(owner, owner:sub(-1))
		end
		check(#mr.file_edit_list(rich) == 0, 'file_edit_list takes a path')

		local function stress_width(owner, priority, find, with, once)
			return edit({ owner = owner, id = 'w', path = 'ui/stress/order.twui.xml', priority = priority, once = once, ops = { { find = find, with = with } } })
		end
		stress_width('k', -2, 'width="1"', 'width="500"')
		stress_width('i', 0, 'width="1"', 'width="600"')
		ok, why = stress_width('z', 9, '</layout>', '</layout><')
		check(ok == nil and why == 'the edited file does not parse (status 11)', 'the broken edit is refused')
		check(test_load_layout('ui\\stress\\order.twui.xml'):find('width="600"', 1, true) ~= nil, 'a refused edit of a third mod keeps the priority order')
		check(patch_line('ui\\stress\\order.twui.xml', 'i/w') == 'i/w applied', 'the winner stays applied')
		check(patch_line('ui\\stress\\order.twui.xml', 'k/w') == 'k/w skipped: replaced by i/w, which runs later', 'the loser names the winner')
		check(log_count('file edit k/w on ui/stress/order.twui.xml: replaced by i/w, which runs later') == 1, 'the losing mod gets a log line')
		for _, owner in ipairs({ 'k', 'i', 'z' }) do
			mr.file_edit_remove(owner, 'w')
		end
		stress_width('p', 0, 'width="1"', 'width="5"')
		stress_width('o', 1, 'width="1"', 'width="22"', true)
		check(patch_line('ui\\stress\\order.twui.xml', 'p/w') == 'p/w skipped: replaced by o/w, which runs later', 'the once edit wins first')
		check(test_load_screen('ui\\stress\\order.twui.xml'):find('width="22"', 1, true) ~= nil, 'the once edit applies once')
		check(patch_line('ui\\stress\\order.twui.xml', 'p/w') == 'p/w applied', 'after the once edit is used the other edit says applied')
		check(test_load_layout('ui\\stress\\order.twui.xml'):find('width="5"', 1, true) ~= nil, 'and applies')
		mr.file_edit_remove('p', 'w')

		edit({ owner = 'x', id = 'move', path = 'ui/stress/first.twui.xml', ops = { { after = '<box', insert = ' a="1"' } } })
		edit({ owner = 'x', id = 'move', path = 'ui/stress/second.twui.xml', ops = { { after = '<box', insert = ' a="1"' } } })
		check(
			#mr.file_edit_list('ui/stress/first.twui.xml') == 0 and #mr.file_edit_list('ui/stress/second.twui.xml') == 1,
			'owner and id name one edit across files'
		)
		mr.file_edit_remove('x', 'move')

		ok = edit({ owner = 'f', id = 'fail', path = 'models/test/unit.wsmodel', priority = 5, ops = { { find = 'skin_b', with = 'fast_fail' } } })
		local fast_text, fast_parsed = test_fast_xml('models\\test\\unit.wsmodel')
		check(ok == true and fast_parsed == 0 and fast_text:find('fast_fail', 1, true) ~= nil, 'a FAST_XML parse that rejects the edit fails once')
		fast_text, fast_parsed = test_fast_xml('models\\test\\unit.wsmodel')
		check(fast_parsed == 1 and fast_text:find('skin_a', 1, true) ~= nil, 'the next read gets the game bytes')
		mr.file_edit_remove('f', 'fail')

		ok, why = twui.edit({ owner = 'x', id = 'p', path = '../x.twui.xml', changes = { { hide = 'box' } } })
		check(
			ok == nil and why == 'path must be a path inside the packs: no drive letter, no leading \\\\ and no .. part',
			'twui.edit refuses a bad path: ' .. tostring(why)
		)
		ok, why = twui.preview({ path = 'C:/x.twui.xml', changes = { { hide = 'box' } } })
		check(ok == nil and why == 'path must be a path inside the packs: no drive letter, no leading \\\\ and no .. part', 'twui.preview refuses a bad path')
		ok, why = twui.preview({ path = 'x', prioriy = 1, changes = { { hide = 'bare' } } }, layout)
		check(ok == nil and why == "unknown key 'prioriy' in the edit", 'twui refuses a misspelt edit key')
		ok, why = twui.preview({ path = 'x', changes = { [1] = { hide = 'bare' }, [3] = { hide = 'bare' } } }, layout)
		check(ok == nil and why == 'changes must be a list of one or more changes', 'twui refuses changes with a gap')
		refused("change 1, set panel: unknown key 'exepct'", { set = 'panel', exepct = { width = 15 }, values = { width = 1 } })
		refused("change 1, hide panel: unknown key 'values'", { hide = 'panel', values = { width = 1 } })
		refused('change 1, hide panel: panel width is "15", expected "99"', { hide = 'panel', expect = { width = 99 } })

		local function quirks(source, change)
			return twui.preview({ path = 'x', changes = { change } }, '<l><hierarchy><box this="B"/></hierarchy><components>' .. source .. '</components></l>')
		end
		check(
			(quirks('<box this="B" ctx="a > b" id="box" width="7"/>', { set = 'box', values = { width = 9 } }) or ''):find(
				'ctx="a > b" id="box" width="9"/>',
				1,
				true
			),
			'a > in a value of the file'
		)
		check(
			(quirks("<box this=\"B\" w='1' name='x'/>", { set = 'box', where = { name = 'x' }, values = { w = 2 } }) or ''):find('w="2" name=', 1, true),
			'single-quoted attributes'
		)
		check(
			(quirks('<!-- <box> --><box this="B" id="box"/>', { hide = 'box' }) or ''):find('id="box" visible="false"', 1, true),
			'a comment before the component'
		)
		check(
			(quirks('<box this="B" t="a&amp;b"/>', { set = 'box', values = { t = 'a\nb\tc>' }, expect = { t = 'a&b' } }) or ''):find(
				't="a&#10;b&#9;c&gt;"',
				1,
				true
			),
			'line breaks and tabs become references, expect reads references'
		)
		check(
			select(2, quirks('<box this = "B"/>', { hide = 'box' })) == 'change 1, hide box: its definition is missing',
			'this with spaces around = is not found'
		)
		local hierarchy_names = '<l><hierarchy><upper_panel this="U"/></hierarchy><components><upper_panel this="U" id="upper panel"/></components></l>'
		check(twui.preview({ path = 'x', changes = { { hide = 'upper panel' } } }, hierarchy_names) ~= nil, 'an id with a space matches its hierarchy name')
		ok, why = twui.preview({ path = 'x', ops = { { after = '</l', attribute = 'a', value = '1' } } }, hierarchy_names)
		check(ok == nil and why == 'op 1: the last anchor does not end inside a start tag', 'attribute op outside a start tag')

		local switch = assert(loadfile('/script/memreader_plus/file_edit_switch'))()
		local screenshots = common.get_appdata_screenshots_path
		common.get_appdata_screenshots_path = function()
			return 'appdata/\197\129ukasz/screenshots/'
		end
		switch.save(false)
		check(
			exists('memreader_plus_file_edits_off.txt') and switch.saved_off(),
			'a user data path with non-ASCII bytes keeps the switch file in the game folder'
		)
		switch.save(true)
		check(not exists('memreader_plus_file_edits_off.txt'), 'and removes it there')
		common.get_appdata_screenshots_path = screenshots

		local started = os.clock()
		for i = 1, 200 do
			check(
				edit({ owner = 's', id = 'f' .. i, path = 'ui/stress/f' .. i .. '.twui.xml', ops = { { find = '"1"', with = '"2"' } } }) == true,
				'file ' .. i
			)
		end
		local after_files = os.clock()
		for i = 1, 50 do
			local spec = { owner = 'p' .. i, id = 'a', path = 'ui/stress/many.twui.xml', ops = { { after = '<box', insert = ' a' .. i .. '="1"' } } }
			check(edit(spec) == true, 'patch ' .. i)
		end
		local after_patches = os.clock()
		local many_ops = {}
		for i = 1, 500 do
			many_ops[i] = { after = '<layout>', insert = '<i/>' }
		end
		check(edit({ owner = 's', id = 'ops', path = 'ui/stress/ops.twui.xml', ops = many_ops }) == true, '500 ops in one edit')
		local deep = {}
		local stress_text = '<layout><box width="1"/></layout>'
		for i = 1, 19 do
			deep[i] = stress_text:sub(i, i)
		end
		for i = 20, 30 do
			deep[i] = ' '
		end
		ok, why = edit({ owner = 's', id = 'deep', path = 'ui/stress/deep.twui.xml', ops = { { after = deep, find = '1', with = '3' } } })
		check(ok == nil and why == 'op 1: anchor 20 not found', '30 anchors are read: ' .. tostring(why))
		for i = 20, 30 do
			deep[i] = nil
		end
		deep[20] = '"'
		check(edit({ owner = 's', id = 'deep', path = 'ui/stress/deep.twui.xml', ops = { { after = deep, find = '1', with = '3' } } }) == true, 'deep anchors')
		local done = os.clock()
		local status = mr.file_edit_status()
		print(
			('  stress: 200 files %.0f ms, 50 patches %.0f ms, 500 ops and deep anchors %.0f ms, %d files, %d results'):format(
				(after_files - started) * 1000,
				(after_patches - after_files) * 1000,
				(done - after_patches) * 1000,
				status.files,
				status.results
			)
		)
		for _, file in ipairs(mr.file_edit_list()) do
			if file.path == 'ui\\stress\\many.twui.xml' then check(#file.patches == 50, '50 patches listed') end
			if file.path == 'ui\\stress\\ops.twui.xml' then check(file.edited_size == #stress_text + 2000, '500 inserts applied') end
		end
		local long_name = string.rep('n', 64)
		ok, why = edit({ owner = long_name, id = 'x', path = panel, ops = { { find = 'a', with = 'b' } } })
		check(ok == nil and why == 'file_edit: owner must be at most 63 bytes', 'long owner refused: ' .. tostring(why))
		local too_deep = {}
		for i = 1, 33 do
			too_deep[i] = 'a'
		end
		ok, why = edit({ owner = 'x', id = 'x', path = panel, ops = { { after = too_deep, find = 'a', with = 'b' } } })
		check(ok == nil and why == 'file_edit: after takes at most 32 texts', '33 anchors refused')
		for i = 1, 200 do
			mr.file_edit_remove('s', 'f' .. i)
		end
		for i = 1, 50 do
			mr.file_edit_remove('p' .. i, 'a')
		end
		mr.file_edit_remove('s', 'ops')
		mr.file_edit_remove('s', 'deep')
		check(mr.file_edit_status().results == status.results - 203, 'removing frees the results: ' .. mr.file_edit_status().results)
	end
elseif SCENARIO == 'report_snapshot' then
	local logged = {}
	ModLog = function(msg)
		logged[#logged + 1] = msg
		print('  log: ' .. msg)
	end
	local function log_count(part)
		local count = 0
		for _, line in ipairs(logged) do
			if has(line, part) then count = count + 1 end
		end
		return count
	end
	local pushed = {}
	local seen_by_native = nil
	_G.memreader_plus = {
		set_crash_settings = function(text)
			pushed[#pushed + 1] = { text = text }
			return true
		end,
		write_runtime_report = function()
			seen_by_native = pushed[#pushed].text
			return 'memreader_runtime_report_010203_040506.txt'
		end,
	}
	local listeners = {}
	installed_core(listeners)
	local enabled_now = true
	local enabled = stub_option('MCT.Option.Checkbox', true)
	enabled.get_finalized_setting = function()
		return enabled_now
	end
	install_mct({
		alpha_mod = stub_mod('Alpha Mod', {
			broken = failing_option('MCT.Option.Checkbox'),
			dd = stub_option('MCT.Option.Dropdown', 'fast'),
			enabled = enabled,
			nothing = stub_option('MCT.Option.Checkbox', nil),
			pad = failing_option('MCT.Option.Dummy'),
			radio = stub_option('MCT.Option.RadioButton', 'second'),
			run = failing_option('MCT.Option.Action'),
			strength = stub_option('MCT.Option.Slider', 2.5),
			tabled = stub_option('MCT.Option.Checkbox', { 1, 2 }),
			tiny = stub_option('MCT.Option.Slider', 0.1),
			words = stub_option('MCT.Option.TextInput', 'tab\tand\rreturn\nline'),
		}),
		beta_mod = stub_mod('Beta Mod', { long = stub_option('MCT.Option.TextInput', string.rep('x', 300)) }),
		big_mod = stub_mod('Big Mod', many_options(400)),
		gamma_mod = stub_mod(nil, { hours = stub_option('MCT.Option.Slider', 12) }),
		zeta_mod = stub_mod('Zeta Mod', nil),
	})
	run_mod(REPORT)
	check(type(_G.memreader_plus_runtime_report) == 'function', 'the report script defines memreader_plus_runtime_report')
	check(#listeners == 2 and listeners[1].event == 'MctInitialized' and listeners[2].event == 'MctFinalized', 'two listeners, registered once')
	check(listeners[1].persistent == true and listeners[2].persistent == true, 'both listeners are persistent')
	check(#pushed == 0, 'nothing is pushed while the file loads')

	local expected = {
		'[alpha_mod] Alpha Mod',
		'  dd = fast',
		'  enabled = true',
		'  radio = second',
		'  strength = 2.5',
		'  tiny = 0.1',
		'  words = tab and return line',
		'[beta_mod] Beta Mod',
		'  long = ' .. string.rep('x', 80),
		'[big_mod] Big Mod',
	}
	for i = 1, 352 do
		expected[#expected + 1] = ('  option_%03d = x'):format(i)
	end
	expected[#expected + 1] = '  ... 48 more options'
	expected[#expected + 1] = '[gamma_mod]'
	expected[#expected + 1] = '  hours = 12'
	expected[#expected + 1] = '[zeta_mod] (its settings could not be read)'
	local expected_text = table.concat(expected, '\n')

	listeners.MctInitialized()
	local text = pushed[#pushed].text
	if text ~= expected_text then
		local i = 1
		while text:sub(i, i) == expected_text:sub(i, i) do
			i = i + 1
		end
		print(('  first difference at byte %d: got %q, expected %q'):format(i, text:sub(i, i + 40), expected_text:sub(i, i + 40)))
	end
	check(text == expected_text, 'the snapshot text matches exactly (' .. #text .. ' bytes)')
	check(#text <= 16384, 'the snapshot fits the native limit')
	listeners.MctFinalized()
	check(#pushed == 2 and pushed[2].text == expected_text, 'MctFinalized pushes the same text again')
	check(log_count('cannot read option broken of mod alpha_mod: getter failed') == 1, 'the failing option is logged once, by name, in two refreshes')
	check(log_count('cannot read the options of mod zeta_mod: no options') == 1, 'the failing mod is logged once, by name')
	check(
		log_count('option pad') + log_count('option run') + log_count('option nothing') + log_count('option tabled') == 0,
		'dummy, action, nil and table options are never read as errors'
	)
	check(logged[1]:sub(1, 22) == '[memreader_plus_report', 'log lines carry the file tag')

	enabled_now = false
	local done, name = _G.memreader_plus_runtime_report()
	check(done == true and name == 'memreader_runtime_report_010203_040506.txt', 'the report function returns true and the native file name')
	check(seen_by_native ~= nil and has(seen_by_native, '  enabled = false'), 'the snapshot is refreshed right before the native report is requested')
	check(log_count('runtime report written: memreader_runtime_report_010203_040506.txt') == 1, 'the result is logged')
	_G.memreader_plus.write_runtime_report = function()
		return nil, 'no folder'
	end
	done, name = _G.memreader_plus_runtime_report()
	check(done == false and name == 'no folder', 'a native failure comes back as false and its message')
	check(log_count('runtime report failed: no folder') == 1, 'the failure is logged')
	_G.memreader_plus.write_runtime_report = function()
		error('exploded', 0)
	end
	done, name = _G.memreader_plus_runtime_report()
	check(done == false and name == 'exploded', 'an error inside the native call comes back as false and its message')

	local big = {}
	for _, key in ipairs({ 'big_a', 'big_b', 'big_c', 'big_d' }) do
		big[key] = stub_mod(key:sub(-1):upper(), many_options(400))
	end
	install_mct(big)
	listeners.MctFinalized()
	text = pushed[#pushed].text
	check(text:match('%.%.%. 2 more mods$') ~= nil, 'mods that do not fit are replaced by a "more mods" line')
	check(has(text, '[big_a] A') and has(text, '[big_b] B') and not has(text, '[big_c]'), 'whole mods are kept or left out')
	check(#text <= 16384, 'four 400-option mods still fit the native limit: ' .. #text)

	get_mct = nil
	listeners.MctFinalized()
	check(#pushed > 0 and pushed[#pushed].text == nil, 'without MCT the snapshot is cleared')
	_G.memreader_plus = nil
	check(pcall(listeners.MctFinalized), 'without the DLL the listener does nothing and raises nothing')
elseif SCENARIO == 'report_native' then
	io.stdout:setvbuf('no')
	load_other_program_dll()
	run_mod(OURS)
	local mr = _G.memreader_plus
	fill_crash_context(mr)
	installed_core({})
	install_mct(settings_mods())
	run_mod(REPORT)
	local done, name = _G.memreader_plus_runtime_report()
	check(done == true and type(name) == 'string' and name:match(REPORT_NAME) ~= nil, 'the report goes through the DLL: ' .. tostring(name))
	check(exists(name), 'the named file exists')
	local text = read_all(name)
	check(has(text, '[beta_mod] Beta Mod') and has(text, '  note = tab and return'), 'it lists the settings built by the Lua snapshot')
	check(not has(text, 'Lua only'), 'it is the native report')
elseif SCENARIO == 'report_lua_only' then
	local logged = {}
	ModLog = function(msg)
		logged[#logged + 1] = msg
		print('  log: ' .. msg)
	end
	run_mod(OURS)
	_G.memreader_plus = nil
	_G.memreader = nil
	_G.memreader_plus_load_error = 'cannot write C:\\Users\\Alice\\twwh3-memreader_plus.dll: Permission denied'
	installed_core({})
	local mods = settings_mods()
	mods.delta_mod = stub_mod('Delta Mod', { folder = stub_option('MCT.Option.TextInput', 'C:\\Users\\Alice\\Documents\\notes') })
	install_mct(mods)
	run_mod(REPORT)

	local lines = {}
	for i = 1, 75 do
		lines[#lines + 1] = ('[memreader_plus] line %03d C:\\Users\\Alice\\AppData\\Roaming'):format(i)
		if i % 10 == 0 then lines[#lines + 1] = '[other_mod] noise ' .. i .. ' C:\\Users\\Bob\\secret' end
	end
	lines[#lines + 1] = '[memreader_plus] loaded from D:\\Program Files (x86)\\Steam\\steamapps\\common\\Total War WARHAMMER III\\data\\memreader_plus.pack'
	lines[#lines + 1] = 'MEMREADER caps c:/Games/SteamLibrary/SteamApps/common/x and C:/USERS/Alice/y'
	lines[#lines + 1] = '[other_mod] unrelated C:\\Users\\Bob\\other'
	lines[#lines + 1] = '[memreader_plus] ' .. string.rep('z', 400)
	local log_file = assert(io.open('lua_mod_log.txt', 'wb'))
	log_file:write(table.concat(lines, '\r\n'), '\r\n')
	log_file:close()

	local function tmp_files()
		return #io.popen('dir /b memreader_runtime_report_*.tmp 2>nul'):read('*a')
	end
	local done, name = _G.memreader_plus_runtime_report()
	check(done == true and type(name) == 'string' and name:match(REPORT_NAME) ~= nil, 'the Lua-only report is written: ' .. tostring(name))
	check(tmp_files() == 0, 'no temporary file is left')
	local text = read_all(name)
	local needles = {
		'memreader Plus runtime report (Lua only: the DLL is not loaded)\n',
		', written on request, nothing crashed\n',
		'Loader:\n',
		'  load error: cannot write %USERPROFILE%\\twwh3-memreader_plus.dll: Permission denied\n',
		'  memreader_plus: not loaded\n',
		'  old memreader: not loaded\n',
		'DLL file the loader writes:\n',
		'  twwh3-memreader_plus.dll: ',
		' bytes, the same bytes as the copy inside the pack\n',
		'MCT settings of the mods in this game:\n',
		'[alpha_mod] Alpha Mod\n  enabled = true\n  strength = 2.5\n',
		'[beta_mod] Beta Mod\n  mode = fast\n  note = tab and return\n',
		'[delta_mod] Delta Mod\n  folder = %USERPROFILE%\\Documents\\notes\n',
		'Lines of lua_mod_log.txt that mention memreader (newest 60 at most):\n',
		'  [memreader_plus] line 075 %USERPROFILE%\\AppData\\Roaming\n',
		'  [memreader_plus] line 019 %USERPROFILE%\\AppData\\Roaming\n',
		'  [memreader_plus] loaded from <Steam library>\\steamapps\\common\\Total War WARHAMMER III\\data\\memreader_plus.pack\n',
		'  MEMREADER caps <Steam library>/SteamApps/common/x and %USERPROFILE%/y\n',
	}
	for _, needle in ipairs(needles) do
		check(has(text, needle), 'Lua-only report holds: ' .. needle:gsub('\n', '|'))
	end
	check(text:match('\n%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d, written') ~= nil, 'it carries the date and time')
	check(not has(text, 'line 018'), 'only the newest 60 matching lines are kept')
	check(not has(text, 'noise') and not has(text, 'unrelated'), 'lines without memreader are left out')
	check(not has(text, 'Alice') and not has(text, 'Bob'), 'no user name is left')
	check(not has(text, 'Program Files') and not has(text, 'SteamLibrary') and not has(text, 'C:\\'), 'no Steam library path is left')
	local log_part = text:match('newest 60 at most%):\n(.*)$')
	check(select(2, log_part:gsub('\n', '\n')) == 60, 'exactly 60 log lines')
	local longest = 0
	for line in text:gmatch('[^\n]+') do
		longest = math.max(longest, #line)
	end
	check(longest <= 303, 'long log lines are cut: ' .. longest)

	_G.memreader_plus = { plus_version = '9.9.9' }
	_G.memreader = {}
	done, name = _G.memreader_plus_runtime_report()
	text = read_all(name)
	check(has(text, '(Lua only: this memreader Plus build cannot write the full report)'), 'a build without the native report says so in the title')
	check(has(text, '  memreader_plus: loaded, version 9.9.9\n') and has(text, '  old memreader: loaded\n'), 'loaded modules are listed')

	_G.memreader_plus = nil
	local real_open = io.open
	io.open = function(path, mode)
		if mode == 'wb' and has(path, 'memreader_runtime_report_') then return nil, path .. ': Permission denied' end
		return real_open(path, mode)
	end
	done, name = _G.memreader_plus_runtime_report()
	io.open = real_open
	check(done == false and has(name, 'Permission denied'), 'a file that cannot be opened gives false and the message: ' .. tostring(name))
	check(tmp_files() == 0, 'and leaves no temporary file')
	check(has(logged[#logged], 'runtime report failed: '), 'the failure is logged')

	local real_rename = os.rename
	os.rename = function()
		return nil, 'denied'
	end
	done, name = _G.memreader_plus_runtime_report()
	os.rename = real_rename
	check(done == true and exists(name), 'when the rename fails the final file is written directly')
	check(tmp_files() == 0, 'and the temporary file is removed')

	os.execute('del /q memreader_runtime_report_*.txt >nul 2>nul')
	block_runtime_report_names()
	done, name = _G.memreader_plus_runtime_report()
	check(done == false and type(name) == 'string' and name ~= '', 'a folder that refuses the final name gives false and a message: ' .. tostring(name))
	check(tmp_files() == 0, 'and leaves no temporary file')
elseif SCENARIO == 'report_loader' then
	local logged = {}
	ModLog = function(msg)
		logged[#logged + 1] = msg
		print('  log: ' .. msg)
	end
	local bin = nil
	local bin_missing = false
	local plain_loadfile = loadfile
	loadfile = function(path)
		if path ~= '/script/memreader_plus/bin' then return plain_loadfile(path) end
		if bin_missing then return nil, 'no such file' end
		return function()
			return bin
		end
	end
	local function run_loader()
		_G.memreader_plus_load_error = nil
		return assert(real_loadfile(LOADER))(ModLog)
	end

	bin = { module = 'missing_folder/twwh3-memreader_plus', data = 'x' }
	check(run_loader() == nil and _G.memreader_plus == nil, 'a DLL that cannot be written leaves Plus unloaded')
	check(
		_G.memreader_plus_load_error:sub(1, 52) == 'cannot write missing_folder/twwh3-memreader_plus.dll',
		'and records why: ' .. tostring(_G.memreader_plus_load_error)
	)
	check(has(logged[#logged], 'not loaded: ' .. _G.memreader_plus_load_error), 'the recorded reason is the logged one')
	bin = { module = 'junk_module', data = 'not a dll' }
	check(run_loader() == nil, 'a file that is no DLL leaves Plus unloaded')
	check(_G.memreader_plus_load_error:sub(1, 28) == 'require junk_module failed: ', 'and records why: ' .. tostring(_G.memreader_plus_load_error))
	bin_missing = true
	check(
		run_loader() == nil and _G.memreader_plus_load_error == 'bin.lua missing: no such file',
		'a missing bin.lua records why: ' .. tostring(_G.memreader_plus_load_error)
	)

	installed_core({})
	install_mct(settings_mods())
	run_mod(REPORT)
	local function report_text()
		local done, name = _G.memreader_plus_runtime_report()
		check(done == true, 'the Lua-only report is written: ' .. tostring(name))
		return read_all(name)
	end
	local text = report_text()
	check(has(text, '  load error: bin.lua missing: no such file\n'), 'the report shows the loader error')
	check(
		has(text, 'DLL file the loader writes:\n  could not be read: bin.lua missing: no such file\n'),
		'a missing bin.lua is a failed section, not a failed report'
	)
	check(has(text, '[alpha_mod] Alpha Mod\n'), 'the other sections still print')

	bin_missing = false
	run_loader()
	text = report_text()
	check(has(text, '  load error: require junk_module failed: '), 'the report shows the require error')
	check(has(text, '  junk_module.dll: 9 bytes, expected 9 bytes, the same bytes as the copy inside the pack\n'), 'the DLL on disk equals the packed copy')
	local junk = assert(io.open('junk_module.dll', 'wb'))
	junk:write('changed')
	junk:close()
	check(
		has(report_text(), '  junk_module.dll: 7 bytes, expected 9 bytes, different bytes than the copy inside the pack\n'),
		'a changed DLL is reported with both sizes'
	)
	bin = { module = 'absent_module', data = 'x' }
	check(has(report_text(), '  absent_module.dll: not found in the game folder\n'), 'a missing DLL is reported')
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
