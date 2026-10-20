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

local function windows_path(path)
	return (path:gsub('/', '\\'))
end

local function vfs_lookup(folder, pattern)
	local seen = {}
	local found = {}
	for _, base in ipairs(VFS) do
		local listing = io.popen('dir /b "' .. windows_path(base .. folder .. pattern) .. '" 2>nul')
		for name in listing:lines() do
			local entry = windows_path(folder:sub(2) .. name:gsub('\r$', '')):lower()
			if not seen[entry] then
				seen[entry] = true
				found[#found + 1] = entry
			end
		end
		listing:close()
	end
	table.sort(found)
	return table.concat(found, ',')
end

common = { filesystem_lookup = vfs_lookup }
local RELEASE = vfs_lookup('/script/memreader_plus/releases/', '*.lua'):match('([%d_]+)%.lua$')

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
		timers = {},
		get_tm = function(self)
			return {
				repeat_real_callback = function(_, callback, milliseconds, name)
					self.timers[#self.timers + 1] = { callback = callback, milliseconds = milliseconds, name = name }
				end,
			}
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
	local timer = core.timers[1]
	check(
		#core.timers == 1 and timer.milliseconds == 5000 and timer.name == 'memreader_plus_flush_log',
		'the context script flushes the link log every 5 seconds'
	)
	check(pcall(timer.callback), 'and the timer callback runs')
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
local LOADER = PACK .. '/script/memreader_plus/' .. RELEASE .. '/loader.lua'
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
	fault_report_overlap = { 'overlap', false },
	fault_report_worker_stuck = { 'worker_stuck', false },
	fault_report_worker_waits = { 'worker_waits', false },
	fault_report_worker_blocked = { 'worker_blocked', false },
	fault_report_worker_dead = { 'worker_dead', false },
	fault_report_move_retry = { 'move_retry', false },
	fault_report_move_fails = { 'move_fails', false },
}

local BOOT = 'script/_lib/mod/!memreader_plus_boot.lua'
local ENTRY = 'script/_lib/mod/memreader_plus.lua'
local OLD_LAYOUT = ROOT .. '/tests/fixtures/v0_11_0'
local FROZEN_LAYOUT = ROOT .. '/tests/fixtures/v0_12_0'

local function collect_log()
	local lines = {}
	ModLog = function(msg)
		lines[#lines + 1] = msg
		print('  log: ' .. msg)
	end
	return lines
end

local function count_logged(lines, part)
	local count = 0
	for _, line in ipairs(lines) do
		if has(line, part) then count = count + 1 end
	end
	return count
end

local function count_dll_writes(refuse)
	local writes = 0
	local open = io.open
	io.open = function(name, mode)
		if mode == 'wb' and has(tostring(name), '.dll') then
			writes = writes + 1
			if refuse then return nil, 'Permission denied' end
		end
		return open(name, mode)
	end
	return function()
		return writes
	end
end

local function write_vfs(relative, text)
	local path = 'vfs/' .. relative
	os.execute('mkdir "' .. windows_path(path:match('^(.*)/')) .. '" >nul 2>nul')
	local file = assert(io.open(path, 'wb'))
	file:write(text)
	file:close()
end

local function fake_manager()
	return {
		saving_game = function() end,
		load_named_value = function() end,
		load_named_string = function() end,
	}
end

local function run_entry(entry, env)
	local chunk = assert(loadfile('/' .. entry:gsub('\\', '/')))
	if env then setfenv(chunk, env) end
	local ok, problem = pcall(chunk)
	check(ok, 'ran ' .. entry .. (ok and '' or ': ' .. tostring(problem)))
end

local function run_lib_mod()
	local entries = {}
	for entry in vfs_lookup('/script/_lib/mod/', '*.lua'):gmatch('[^,]+') do
		local name = entry:match('([^\\]+)%.lua$')
		if name ~= 'memreader_plus_context' and name ~= 'memreader_plus_report' then entries[#entries + 1] = entry end
	end
	table.sort(entries, function(a, b)
		return a:lower() < b:lower()
	end)
	for _, entry in ipairs(entries) do
		run_entry(entry)
	end
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
elseif SCENARIO == 'links' then
	io.stdout:setvbuf('no')
	local logged = {}
	ModLog = function(message)
		logged[#logged + 1] = message
		print('  log: ' .. message)
	end
	run_mod(OURS)
	local mr = _G.memreader_plus
	local function address(name)
		return mr.pointer(test_function(name))
	end
	local target, single, float, store = address('hook_target'), address('hook_single'), address('hook_float'), address('hook_store')
	local TARGET, SINGLE, FLOAT, STORE = 'int32(int32, int32)', 'int64(int64)', 'float(float, float)', 'void(pointer, int32)'
	local function contains(text, part)
		return type(text) == 'string' and string.find(text, part, 1, true) ~= nil
	end
	local function error_of(f, ...)
		local ok, err = pcall(f, ...)
		return not ok and tostring(err) or nil
	end
	local function call_target(a, b)
		return mr.tonumber(mr.call(target, TARGET, a, b))
	end
	local trace = {}
	local function mark(text)
		trace[#trace + 1] = text
	end
	local function seen()
		local text = table.concat(trace, ' ')
		trace = {}
		return text
	end
	local function lines_with(part)
		local count = 0
		for _, line in ipairs(logged) do
			if contains(line, part) then count = count + 1 end
		end
		return count
	end
	local function prefix(p, name, priority)
		return p:prefix(target, TARGET, name, function()
			mark('P:' .. name)
		end, priority)
	end
	local function postfix(p, name, priority)
		return p:postfix(target, TARGET, name, function()
			mark('F:' .. name)
		end, priority)
	end
	local function around(p, name, priority)
		return p:around(target, TARGET, name, function(game, x, y)
			mark('>' .. name)
			local result = game(x, y)
			mark('<' .. name)
			return result
		end, priority)
	end
	local function clean(...)
		for _, p in ipairs({ ... }) do
			p:remove_all()
		end
		mr.unhook(target)
		seen()
	end

	if PASS == 1 then
		local a, b = mr.patcher('link_a'), mr.patcher('link_b')
		check(type(mr.patch_info) == 'function' and type(a.prefix) == 'function', 'patch_info and the link methods are part of the API')
		check(mr.patch_info(address('call_directly')) == nil, 'patch_info of an address with no hook and no claim is nil')

		check(call_target(1, 2) == 12, 'the original result before any link')
		for _, spec in ipairs({ { a, 'low', -5 }, { b, 'high', 10 }, { a, 'mid1', 0 }, { b, 'mid2', 0 } }) do
			local label = spec[2]
			check(spec[1]:prefix(target, TARGET, 'p_' .. label, function()
				mark('P:' .. label)
			end, spec[3]) == true, 'prefix ' .. label)
			check(spec[1]:postfix(target, TARGET, 'f_' .. label, function()
				mark('F:' .. label)
			end, spec[3]) == true, 'postfix ' .. label)
			check(spec[1]:around(target, TARGET, 'a_' .. label, function(game, x, y)
				mark('>' .. label)
				local result = game(x, y)
				mark('<' .. label)
				return result
			end, spec[3]) == true, 'around ' .. label)
		end
		check(call_target(1, 2) == 12, 'links that change nothing keep the result')
		check(
			seen() == 'P:high P:mid1 P:mid2 P:low >high >mid1 >mid2 >low <low <mid2 <mid1 <high F:high F:mid1 F:mid2 F:low',
			'every list runs highest priority first, ties by registration, the highest around is outermost'
		)
		check(
			#mr.patch_info(target).links == 12 and mr.hook_info(target).callbacks == 0 and not mr.hook_info(target).attached,
			'patch_info lists the links, hook_info counts old callbacks only'
		)
		mr.hook(target, TARGET, function(x, y)
			mark('>L1')
			local result = mr.hook_next(target, x, y)
			mark('<L1')
			return result
		end)
		mr.hook(target, TARGET, function(x, y)
			mark('>L2')
			local result = mr.hook_next(target, x, y)
			mark('<L2')
			return result
		end)
		check(call_target(1, 2) == 12, 'old callbacks and links on one address')
		check(
			seen() == 'P:high P:mid1 P:mid2 P:low >high >mid1 >mid2 >L2 >L1 >low <low <L1 <L2 <mid2 <mid1 <high F:high F:mid1 F:mid2 F:low',
			'old callbacks are one group of priority 0 arounds, newest first, placed at their oldest member, and hook_next and game walk one order'
		)
		check(
			mr.hook_info(target).callbacks == 2 and mr.hook_info(target).attached and #mr.patch_info(target).links == 14,
			'hook_info counts the old callbacks, patch_info all'
		)
		mr.unhook(target)
		check(
			mr.hook_info(target).callbacks == 0 and not mr.hook_info(target).attached and #mr.patch_info(target).links == 12,
			'unhook removes only the old callbacks'
		)
		check(call_target(1, 2) == 12 and seen() ~= '', 'the links still run after unhook')
		clean(a, b)
		check(mr.hook_info(target).callbacks == 0 and not mr.hook_info(target).attached, 'remove_all detaches every link')
		check(call_target(1, 2) == 12 and seen() == '', 'an address with no links runs the original')

		local skipped_by, skipped_result
		local cell = mr.alloc(4)
		prefix(a, 'before', 9)
		check(a:prefix(target, TARGET, 'skipper', function(call)
			mark('P:skipper')
			call:skip(77)
		end, 5) == true, 'a skipping prefix')
		prefix(a, 'after', 0)
		around(a, 'never', 0)
		check(a:postfix(target, TARGET, 'watcher', function(call, result)
			mark('F:watcher')
			skipped_by, skipped_result = call.skipped, mr.tonumber(result)
		end, 0) == true, 'a postfix')
		check(call_target(1, 2) == 77, 'a skip returns the given result')
		check(seen() == 'P:before P:skipper F:watcher', 'a skip removes the lower prefixes and the arounds, every postfix still runs')
		check(skipped_by == 'link_a/skipper' and skipped_result == 77, 'the postfix sees who skipped and the result: ' .. tostring(skipped_by))
		check(a:info('skipper').skips == 1 and a:info('skipper').calls == 1, 'the skipping link counts its skip')
		check(a:info('before').skips == 0 and a:info('after').calls == 0, 'other links count no skip, and a link that did not run counts no call')
		a:remove('skipper')
		check(call_target(1, 2) == 12 and skipped_by == nil, 'without the skipper the original runs and call.skipped is nil')
		seen()
		a:remove('never')
		check(a:around(target, TARGET, 'gate', function(game, x, y)
			mark('>gate')
			return 99
		end, 5) == true, 'an around that never calls game')
		around(a, 'below_gate', 0)
		check(call_target(1, 2) == 99, 'an around that returns without game skips the original')
		check(seen() == 'P:before P:after >gate F:watcher', 'an around skip removes the arounds below, every postfix runs')
		check(skipped_by == 'link_a/gate' and a:info('gate').skips == 1, 'the around that did not call game is the skipper and counts it')
		check(a:info('below_gate').calls == 0, 'the around below it never ran')
		clean(a)
		mr.hook(target, TARGET, function()
			return 5
		end)
		a:postfix(target, TARGET, 'watcher', function(call, result)
			skipped_by = call.skipped
		end)
		check(call_target(1, 2) == 5 and skipped_by == 'hook', 'an old callback that skips shows as hook')
		clean(a)
		check(a:prefix(store, STORE, 'void_skip', function(call, p, v)
			call:skip()
		end) == true, 'a prefix on a void function')
		mr.call(store, STORE, cell, 5)
		check(mr.read_int32(cell, 0) == 0, 'a skip on a void function runs no original')
		a:remove('void_skip')
		mr.call(store, STORE, cell, 5)
		check(mr.read_int32(cell, 0) == 6, 'and without it the original writes')
		local bare_value
		a:postfix(store, STORE, 'void_post', function(call, result, p, v)
			bare_value = { result, mr.tonumber(v) }
		end)
		a:prefix(store, STORE, 'void_set', function(call, p, v)
			call:set(2, 40)
		end)
		mr.call(store, STORE, cell, 5)
		check(
			mr.read_int32(cell, 0) == 41 and bare_value[1] == nil and bare_value[2] == 40,
			'set works on a void function and the postfix gets nil for the result'
		)
		a:remove_all()

		local boom = 0
		prefix(a, 'good_prefix', 0)
		check(a:prefix(target, TARGET, 'bad_prefix', function(call)
			boom = boom + 1
			call:set(2, 9)
			call:skip(55)
			error('prefix boom ' .. boom)
		end, 10) == true, 'a prefix that raises')
		check(call_target(1, 2) == 12 and seen() == 'P:good_prefix', 'a raising prefix loses its set and skip, the next prefix runs')
		check(call_target(1, 2) == 12, 'and again')
		seen()
		check(lines_with('link_a/bad_prefix') == 0, 'nothing is logged inside the call')
		local row = a:info('bad_prefix')
		check(
			row.errors == 2 and contains(row.error, 'prefix boom 1') and not contains(row.error, 'boom 2'),
			'the link counts its errors and keeps the first text: ' .. tostring(row.error)
		)
		check(a:info('bad_prefix').state == 'stays' and #mr.patch_info(target).links > 0, 'the link stays attached')
		check(mr.hook_info(target).error == nil and mr.hook_info(target).callbacks == 0, 'a link error does not touch hook_info')
		mr.patch_info(target)
		mr.patch_info(target)
		check(lines_with('[memreader Plus] link_a/bad_prefix (prefix): ') == 1 and lines_with('prefix boom 1') == 1, 'the first error is logged once')
		a:remove_all()

		check(a:around(target, TARGET, 'bad_around', function()
			error('around boom')
		end, 10) == true, 'an around that raises before game')
		around(a, 'inner', 0)
		check(call_target(1, 2) == 12 and seen() == '>inner <inner', 'a raising around is skipped as if absent, the ones below run')
		a:remove('inner')
		a:around(target, TARGET, 'inner', function(game, x, y)
			return mr.add(game(x, y), 1000)
		end, 0)
		check(call_target(1, 2) == 1012, 'and the inner chain result is used')
		a:remove('bad_around')
		a:around(target, TARGET, 'late_error', function(game, x, y)
			local result = game(x, y)
			error('late boom')
		end, 10)
		check(call_target(1, 2) == 1012, 'an around that raises after game keeps the result of game')
		check(a:info('late_error').errors == 1 and a:info('inner').errors == 0, 'only the raising around counts an error')
		a:remove_all()
		a:around(target, TARGET, 'wrong_type', function(game, x, y)
			game(x, y)
			return {}
		end, 0)
		check(
			call_target(1, 2) == 12 and contains(a:info('wrong_type').error, 'int32 expected'),
			'a result of the wrong type is an error and the kept result stands'
		)
		a:remove_all()
		a:around(target, TARGET, 'returns_nothing', function(game, x, y) end, 0)
		check(call_target(1, 2) == 12 and contains(a:info('returns_nothing').error, 'returned nothing'), 'returning nothing is an error and the original runs')
		a:remove_all()

		local final_seen
		a:postfix(target, TARGET, 'replace', function(call, result)
			return 50
		end, 10)
		a:postfix(target, TARGET, 'breaks', function(call, result)
			error('postfix boom')
		end, 0)
		a:postfix(target, TARGET, 'last', function(call, result)
			final_seen = mr.tonumber(result)
		end, -5)
		check(call_target(1, 2) == 50 and final_seen == 50, 'a postfix can replace the result and the next one sees it, a raising postfix leaves it as it was')
		a:remove('replace')
		a:postfix(target, TARGET, 'bad_type', function(call, result)
			return {}
		end, 20)
		check(
			call_target(1, 2) == 12 and final_seen == 12 and contains(a:info('bad_type').error, 'int32 expected'),
			'a postfix result of the wrong type leaves the result'
		)
		check(a:info('breaks').errors == 2 and #mr.patch_info(target).links == 3, 'raising postfixes stay attached')
		mr.patch_info(target)
		check(lines_with('link_a/breaks (postfix): ') == 1 and lines_with('link_a/bad_type (postfix): ') == 1, 'each raising link logs its first error once')
		clean(a)

		local objects, in_around, game_is_call = {}, {}, nil
		check(a:prefix(target, TARGET, 'setter', function(call, x, y)
			call:set(1, 5)
			call:set(2, 7)
		end, 10) == true, 'a prefix with set')
		a:around(target, TARGET, 'sees', function(game, x, y)
			in_around = { mr.tonumber(x), mr.tonumber(y) }
			return game(x, y)
		end)
		local post_seen
		a:postfix(target, TARGET, 'sees_post', function(call, result, x, y)
			post_seen = { mr.tonumber(x), mr.tonumber(y) }
		end)
		check(call_target(1, 2) == 57, 'the original runs with the changed arguments')
		check(in_around[1] == 5 and in_around[2] == 7, 'the around gets them')
		check(post_seen[1] == 5 and post_seen[2] == 7, 'the postfix gets the arguments as they were after the prefixes')
		a:remove('setter')
		local problems = {}
		a:prefix(target, TARGET, 'bad_sets', function(call)
			problems[1] = error_of(call.set, call, 3, 1)
			problems[2] = error_of(call.set, call, 1, {})
			problems[3] = error_of(call.skip, call)
			problems[4] = error_of(call.set, call, 0, 1)
		end, 10)
		a:around(target, TARGET, 'phase', function(game, x, y)
			problems[5] = error_of(game.set, game, 1, 1)
			problems[6] = error_of(game.skip, game, 1)
			return game(x, y)
		end, 10)
		check(call_target(1, 2) == 12, 'wrong set and skip calls change nothing')
		check(
			contains(problems[1], 'must be a whole number from 1 to 2') and contains(problems[4], 'must be a whole number from 1 to 2'),
			'an argument number outside the signature raises'
		)
		check(contains(problems[2], 'int32') and contains(problems[3], 'skip needs a result'), 'a wrong value or a missing skip result raises')
		check(
			contains(problems[5], 'set works only inside a prefix') and contains(problems[6], 'skip works only inside a prefix'),
			'set and skip outside a prefix raise'
		)
		clean(a)

		check(a:around(target, TARGET, 'thrice', function(game, x, y)
			return mr.tonumber(game(1, 1)) + mr.tonumber(game(2, 2)) + mr.tonumber(game(3, 3))
		end) == true, 'an around that calls game three times')
		check(call_target(9, 9) == 66, 'game runs the rest of the chain every time')
		check(a:around(target, TARGET, 'thrice', function(game, x, y)
			return 7
		end) == true and call_target(9, 9) == 7 and #mr.patch_info(target).links == 1, 'the same name replaces the link')
		clean(a)
		check(
			a:around(target, TARGET, 'wrong_count', function(game, x, y)
					return game(1)
				end) == true
				and call_target(1, 2) == 12
				and contains(a:info('wrong_count').error, 'the signature takes 2 arguments, got 1'),
			'game with the wrong number of arguments is an error'
		)
		clean(a)

		a:around(target, TARGET, 'lower', function(game, x, y)
			return mr.add(game(x, y), 1000)
		end, 0)
		a:around(target, TARGET, 'direct', function(game, x, y)
			return game:original(x, y)
		end, 10)
		a:prefix(target, TARGET, 'direct_prefix', function(call, x, y)
			mark('P')
		end, 0)
		check(call_target(1, 2) == 12 and seen() == 'P', 'call:original skips the arounds below')
		local nested = {}
		a:remove_all()
		a:prefix(target, TARGET, 'recurse', function(call, x, y)
			nested[#nested + 1] = { call.depth, call, call.site }
			if mr.tonumber(x) > 0 then mr.call(target, TARGET, mr.tonumber(x) - 1, y) end
		end)
		call_target(2, 0)
		check(#nested == 3 and nested[1][1] == 1 and nested[2][1] == 2 and nested[3][1] == 3, 'call.depth counts nested calls')
		check(nested[1][2] ~= nested[2][2] and nested[2][2] ~= nested[3][2], 'nested calls get their own call object')
		check(nested[1][3] == 'recurse', 'call.site is the link name')
		local first_objects = { nested[1][2], nested[2][2], nested[3][2] }
		nested = {}
		call_target(2, 0)
		check(nested[1][2] == first_objects[1] and nested[2][2] == first_objects[2], 'a later call reuses the object of its depth: no allocation')
		local stash
		a:remove_all()
		a:prefix(target, TARGET, 'stasher', function(call)
			stash = call
		end)
		call_target(1, 2)
		check(
			contains(
				error_of(function()
					return stash.skipped
				end),
				'call object used after its call returned'
			),
			'a call object used after its call raises'
		)
		check(contains(error_of(stash.set, stash, 1, 1), 'call object used after its call returned'), 'also its methods')
		check(
			contains(
				error_of(function()
					return stash.depth
				end),
				'call object used after its call returned'
			),
			'also call.depth'
		)
		check(
			contains(
				error_of(function()
					return stash(1, 2)
				end),
				'call object used after its call returned'
			),
			'also game'
		)
		check(
			contains(
				error_of(function()
					return stash:original(1, 2)
				end),
				'call object used after its call returned'
			),
			'also call:original'
		)
		check(error_of(a.prefix, stash, target, TARGET, 'x', function() end) ~= nil, 'a call object is not a handle')
		clean(a)

		local edited, late_ran = false, false
		a:postfix(target, TARGET, 'goner', function()
			mark('F:goner')
		end)
		a:prefix(target, TARGET, 'editor', function()
			if edited then return end
			edited = true
			mark('edit')
			mark(tostring(a:postfix(target, TARGET, 'newcomer', function()
				mark('F:newcomer')
			end)))
			mark(tostring(a:remove('goner')))
		end)
		call_target(1, 2)
		check(seen() == 'edit true true F:goner', 'a link added during a call runs from the next call, a removed one still finishes this call')
		call_target(1, 2)
		check(seen() == 'F:newcomer', 'the next call has the new set')
		check(#mr.patch_info(target).links == 2, 'the removed link is gone from patch_info')
		clean(a)

		a:remove_all()
		for i = 1, 32 do
			a:postfix(single, SINGLE, 'f' .. i, function() end)
		end
		check(select(2, a:postfix(single, SINGLE, 'f33', function() end)) == 'at most 32 links on this address', 'the 33rd link is refused')
		check(a:info('f33') == nil, 'and registers nothing')
		check(a:remove('f1') == true and a:postfix(single, SINGLE, 'f33', function() end) == true, 'a free slot takes the next one')
		a:remove_all()
		local midcall = {}
		for i = 1, 32 do
			a:postfix(single, SINGLE, 'g' .. i, function()
				if i == 1 then
					midcall[1] = a:remove('g2')
					midcall[2], midcall[3] = a:postfix(single, SINGLE, 'g33', function() end)
				end
			end)
		end
		mr.call(single, SINGLE, 1)
		check(
			midcall[1] == true and midcall[2] == nil and contains(midcall[3], 'removed links keep their place until the running call returns'),
			'during a call a removed link still holds its slot'
		)
		check(a:postfix(single, SINGLE, 'g33', function() end) == true, 'and the slot is free after the call')
		a:remove_all()
		check(mr.hook_info(single).callbacks == 0, 'remove_all frees every slot')

		for _ = 1, 16 do
			mr.hook(single, SINGLE, function(x)
				return mr.hook_next(single, x)
			end)
		end
		check(contains(error_of(mr.hook, single, SINGLE, function() end), 'at most 16 callbacks per address'), 'old callbacks keep their limit of 16')
		local made = 0
		for i = 1, 16 do
			if a:postfix(single, SINGLE, 'm' .. i, function() end) == true then made = made + 1 end
		end
		check(
			made == 16 and select(2, a:postfix(single, SINGLE, 'm17', function() end)) == 'at most 32 links on this address',
			'sixteen old callbacks and sixteen links fill the 32 places'
		)
		check(contains(error_of(mr.hook, single, SINGLE, function() end), 'at most 16 callbacks per address'), 'and the old limit holds')
		check(mr.tonumber(mr.call(single, SINGLE, 2)) == 7, 'a call through all of them')
		mr.unhook(single)
		a:remove_all()

		local c = mr.patcher('sig_c')
		check(c:prefix(single, SINGLE, 'first_link', function() end) == true, 'a first link sets the signature')
		local ok, why = c:prefix(single, 'int64(int64, int64)', 'second', function() end)
		check(ok == nil and why == 'signature differs from sig_c/first_link', 'another signature is refused with the holder: ' .. tostring(why))
		check(c:info('second') == nil, 'and registers nothing')
		check(
			contains(error_of(mr.hook, single, 'int64(int64, int64)', function() end), 'different signature'),
			'an old hook with another signature is refused too'
		)
		check(c:prefix(single, SINGLE, 'second', function() end) == true, 'the same signature is accepted')
		ok, why = c:prefix(single, 'int32(int32)', 'first_link', function() end)
		check(ok == nil and why == 'signature differs from sig_c/first_link', 'a replacement needs the same signature while other links exist')
		c:remove('second')
		check(c:prefix(single, 'int32(int32)', 'first_link', function() end) == true, 'a link replacing the only link may change the signature')
		c:remove_all()
		mr.hook(float, FLOAT, function(x, y)
			return mr.hook_next(float, x, y)
		end)
		ok, why = c:prefix(float, 'float(float)', 'other', function() end)
		check(ok == nil and why == 'signature differs from hook', 'an old callback holds the signature: ' .. tostring(why))
		mr.unhook(float)
		check(c:prefix(float, 'float(float)', 'other', function() end) == true, 'with the old callback gone another signature is accepted')
		c:remove_all()

		check(select(2, a:prefix(target, TARGET, 'bad name', function() end)) == 'name must be 1 to 47 letters, digits or underscores', 'a bad name is refused')
		check(
			select(2, a:prefix(target, TARGET, 'x', function() end, 5000)) == 'priority must be a whole number from -1000 to 1000',
			'a priority out of range is refused'
		)
		check(select(2, a:prefix(nil, TARGET, 'x', function() end)) == 'address is NULL', 'a NULL address is refused')
		check(not pcall(a.prefix, a, target, 'int(int)', 'x', function() end), 'an unknown type in the signature raises')
		check(not pcall(a.prefix, a, target, TARGET, 'x', nil), 'a missing function raises')
		check(not pcall(a.prefix, 5, target, TARGET, 'x', function() end), 'a call without the handle raises')
		a:prefix(target, TARGET, 'kind_name', function() end)
		check(
			select(2, a:postfix(target, TARGET, 'kind_name', function() end)) == 'the name is already used for a different change',
			'a name cannot change its kind'
		)
		check(select(2, a:prefix(single, SINGLE, 'kind_name', function() end)) == 'the name is already used for a different change', 'or its address')
		local same = function() end
		a:prefix(target, TARGET, 'same_function', same)
		local count_before = mr.hook_info(target).callbacks
		check(
			a:prefix(target, TARGET, 'same_function', same) == true and mr.hook_info(target).callbacks == count_before,
			'the same name with the same function is a no-op'
		)
		check(
			a:prefix(target, TARGET, 'same_function', function() end) == true and mr.hook_info(target).callbacks == count_before,
			'with another function it replaces the link'
		)
		check(a:prefix(target, TARGET, 'same_function', same, 7) == true and mr.hook_info(target).callbacks == count_before, 'with another priority too')
		check(
			a:remove('same_function') == true and select(2, a:remove('same_function')) == 'unknown name',
			'remove drops the link and answers unknown name afterwards'
		)
		local here = address('site_target_here')
		check(a:site('a_site', here, function() end) == true, 'a site on another address')
		ok, why = a:prefix(here, 'int32()', 'on_site', function() end)
		check(ok == nil and contains(why, 'already holds a site hook'), 'a link on a site address is refused: ' .. tostring(why))
		clean(a)
		local claim_target = address('patch_target')
		check(b:patch('claimed', claim_target, '\184\1\0\0\0', '\184\1\0\0\0') == true, 'a patch claims the start of a function')
		ok, why = a:prefix(claim_target, 'int32()', 'over_claim', function() end)
		check(
			ok == nil and why == 'held by link_b/claimed' and mr.hook_info(claim_target) == nil,
			'a link over a claimed range is refused and hooks nothing: ' .. tostring(why)
		)
		b:remove('claimed')

		check(a:prefix(target, TARGET, 'info_pre', function() end, 3) == true, 'rows')
		b:around(target, TARGET, 'info_around', function(game, x, y)
			return game(x, y)
		end)
		a:postfix(target, TARGET, 'info_post', function() end, 1)
		mr.hook(target, TARGET, function(x, y)
			return mr.hook_next(target, x, y)
		end)
		call_target(1, 2)
		local info = mr.patch_info(target)
		check(info.kind == 'function' and info.other_thread_calls == 0 and #info.links == 4 and #info.claims == 0, 'patch_info of a hooked function')
		local names = {}
		for i, row in ipairs(info.links) do
			names[i] = row.owner .. '/' .. row.name .. ':' .. row.link .. ':' .. row.priority
		end
		check(
			table.concat(names, ' ') == 'link_a/info_pre:prefix:3 link_b/info_around:around:0 /:around:0 link_a/info_post:postfix:1',
			'the rows are in run order, an old callback is an around with no owner: ' .. table.concat(names, ' ')
		)
		check(
			info.links[1].calls == 1 and info.links[1].skips == 0 and info.links[1].errors == 0 and info.links[1].error == nil,
			'rows carry calls, skips and errors'
		)
		check(info.links[3].calls == nil, 'an old callback has no counters')
		local list = mr.patch_list('link_a')
		local by_name = {}
		for _, entry in ipairs(list) do
			by_name[entry.name] = entry
		end
		check(
			by_name.info_pre.kind == 'prefix' and by_name.info_post.kind == 'postfix' and by_name.info_pre.state == 'stays',
			'patch_list names the link kinds'
		)
		check(by_name.info_pre.priority == 3 and by_name.info_pre.calls == 1 and mr.eq(by_name.info_pre.at, target), 'and gives counters and the address')
		check(b:info('info_around').kind == 'around' and b:info('info_around').calls == 1, 'info of one link')
		a:patch('claim_row', claim_target, '\184\1\0\0\0', '\184\2\0\0\0')
		local claim_info = mr.patch_info(claim_target)
		check(
			claim_info.kind == nil and #claim_info.claims == 1 and claim_info.claims[1].owner == 'link_a' and claim_info.claims[1].name == 'claim_row',
			'patch_info lists the claims over an address'
		)
		check(
			mr.type(claim_info.claims[1].from) == 'pointer' and mr.eq(mr.add(claim_info.claims[1].from, 5), claim_info.claims[1].to),
			'with the claimed range'
		)
		a:remove('claim_row')
		clean(a, b)

		a:prefix(single, SINGLE, 'worker', function()
			mark('P:worker')
		end)
		local before_calls = mr.hook_info(single).calls
		check(mr.tonumber(mr.call(address('call_on_thread'), 'int64(pointer, int64)', single, 5)) == 16, 'a call on another thread runs the original')
		check(seen() == '' and mr.hook_info(single).calls == before_calls, 'no link ran and the call is not counted')
		check(mr.patch_info(single).other_thread_calls == 1 and mr.hook_info(single).other_thread_calls == 1, 'it is counted apart')
		a:remove_all()

		local seen_float = {}
		a:prefix(float, FLOAT, 'f_set', function(call, x, y)
			call:set(1, 10.5)
		end)
		a:around(float, FLOAT, 'f_around', function(game, x, y)
			seen_float[1] = x
			return game(x, y)
		end)
		a:postfix(float, FLOAT, 'f_post', function(call, result, x, y)
			seen_float[2] = result
			return result * 2
		end)
		check(mr.call(float, FLOAT, 1.5, 2.5) == 16, 'float arguments and results through links')
		check(seen_float[1] == 10.5 and seen_float[2] == 8, 'floats reach the links as numbers')
		a:remove_all()
		a:prefix(float, FLOAT, 'f_skip', function(call)
			call:skip(2.25)
		end)
		check(mr.call(float, FLOAT, 1.5, 2.5) == 2.25, 'a float skip result')
		a:remove_all()
		local keeper, leaf = address('call_keeping_registers'), address('leaf_add_one')
		local saved = mr.alloc(152)
		local before = {}
		for i = 1, 152 do
			before[i] = string.char((i * 37 + 11) % 256)
		end
		mr.write(saved, 0, table.concat(before))
		a:postfix(leaf, 'uint64(uint64)', 'leaf_post', function() end)
		mr.call(keeper, 'void(pointer, pointer)', leaf, saved)
		check(
			mr.tostring(mr.read_uint64(saved, 144)) == mr.tostring(mr.add(mr.read_uint64(saved, 96), 1)),
			'a link on a leaf function gives the original result'
		)
		a:remove_all()

		local pattern_function = address('hook_mixed')
		local function hex_of(at, size)
			local bytes, parts = mr.read(at, 0, size), {}
			for i = 1, size do
				parts[i] = string.format('%02X', bytes:byte(i))
			end
			return table.concat(parts, ' ')
		end
		local pattern = hex_of(pattern_function, 40)
		local first, count = mr.find_pattern(pattern)
		check(count == 1 and mr.eq(first, pattern_function), 'the 40 byte pattern of hook_mixed is unique: ' .. tostring(count))
		local MIXED = 'double(int64, double, float, int32, int8, double)'
		local expect = hex_of(pattern_function, 6)
		check(a:prefix({ pattern = pattern }, MIXED, 'by_pattern', function() end) == true, 'a target table with a pattern')
		check(mr.eq(a:info('by_pattern').at, pattern_function), 'it hooks the address the pattern found')
		check(a:prefix({ pattern = pattern, at = 0, expect = expect }, MIXED, 'by_expect', function() end) == true, 'with at and expect')
		check(a:prefix({ pattern = pattern, expect = '?? ?? ??' }, MIXED, 'by_wild', function() end) == true, 'expect may start with a wildcard')
		check(mr.call(pattern_function, MIXED, 1, 2, 3, 4, -5, 6) == 123356, 'links on a function with register and stack arguments pass them all')
		check(a:prefix(pattern_function, MIXED, 'mixed_set', function(call)
			call:set(6, 10)
			call:set(3, 4)
		end) == true and mr.call(pattern_function, MIXED, 1, 2, 3, 4, -5, 6) == 124360, 'set changes a float register argument and a stack argument')
		ok, why = a:prefix({ pattern = pattern, at = 1, expect = expect }, MIXED, 'wrong_expect', function() end)
		check(ok == nil and why == 'unexpected bytes' and a:info('wrong_expect') == nil, 'unexpected bytes at the address are refused')
		ok, why = a:prefix({ pattern = 'C3' }, MIXED, 'many', function() end)
		check(
			ok == nil and string.match(tostring(why), '^pattern found %d+ times$') and why ~= 'pattern found 1 times',
			'a pattern that matches many places is refused: ' .. tostring(why)
		)
		ok, why = a:prefix({ pattern = 'DE AD BE EF DE AD BE EF 01 02 03 04 05 06 07' }, MIXED, 'none', function() end)
		check(ok == nil and why == 'pattern found 0 times', 'a pattern that matches nowhere is refused')
		ok, why = a:prefix({ pattern = 'zz' }, MIXED, 'bad', function() end)
		check(ok == nil and contains(why, 'bad pattern'), 'a bad pattern is refused: ' .. tostring(why))
		ok, why = a:prefix({ pattern = '?? 48' }, MIXED, 'bad', function() end)
		check(ok == nil and contains(why, 'bad pattern'), 'a pattern that starts with ?? is refused')
		ok, why = a:prefix({ at = 3 }, MIXED, 'bad', function() end)
		check(ok == nil and why == 'a target table needs a pattern string', 'a table without a pattern is refused')
		ok, why = a:prefix({ pattern = pattern, at = 1.5 }, MIXED, 'bad', function() end)
		check(ok == nil and why == 'at must be a whole number', 'a fractional offset is refused')
		ok, why = a:prefix({ pattern = pattern, expect = 'xx' }, MIXED, 'bad', function() end)
		check(ok == nil and contains(why, 'expect must be hex bytes'), 'a bad expect is refused')
		a:remove_all()

		local prologue = address('prologue_target')
		local prologue_pattern = hex_of(prologue, 32)
		local _, prologue_count = mr.find_pattern(prologue_pattern)
		check(prologue_count == 1, 'the 32 byte pattern of prologue_target is unique: ' .. tostring(prologue_count))
		check(
			a:patch('table_patch', { pattern = prologue_pattern, at = 5, expect = '01 00 00 00' }, '\1\0\0\0', '\2\0\0\0') == true
				and mr.tonumber(mr.call(prologue, 'int32()')) == 2,
			'an owned patch takes a target table'
		)
		ok, why = a:patch('table_patch_bad', { pattern = prologue_pattern, at = 5, expect = '07 00 00 00' }, '\1\0\0\0', '\2\0\0\0')
		check(ok == nil and why == 'unexpected bytes', 'and refuses unexpected bytes at the address')
		check(a:remove('table_patch') == true and mr.tonumber(mr.call(prologue, 'int32()')) == 1, 'remove puts the patch back')
		check(
			a:relocate('table_reloc', { { { pattern = prologue_pattern, at = 5, expect = '01 00 00 00' }, '\1\0\0\0', '\3\0\0\0' } }) == true,
			'a relocation takes target tables'
		)
		ok, why = a:relocate('table_reloc_bad', { { { pattern = 'C3' }, '\1\0\0\0', '\3\0\0\0' } })
		check(ok == nil and contains(why, 'site 1: pattern found'), 'a bad target in a relocation names the site: ' .. tostring(why))
		check(a:site('table_site', { pattern = hex_of(address('site_single_here'), 24) }, function() end) ~= nil, 'a site takes a target table')

		mr.set_log(nil)
		a:postfix(target, TARGET, 'unlogged', function()
			error('quiet')
		end)
		call_target(1, 2)
		local before_lines = #logged
		mr.patch_info(target)
		check(#logged == before_lines, 'without a log sink nothing is written')
		local sink_lines = {}
		mr.set_log(function(message)
			sink_lines[#sink_lines + 1] = message
		end)
		mr.patch_info(target)
		check(#sink_lines == 1 and contains(sink_lines[1], '[memreader Plus] link_a/unlogged (postfix): '), 'a sink set later gets the waiting line')
		check(not pcall(mr.set_log, 5), 'set_log refuses a non-function')
		mr.set_log(ModLog)
		a:remove_all()
		a:postfix(target, TARGET, 'inside', function()
			mr.patch_info(target)
			mark('depth ' .. mr.hook_depth())
		end)
		a:postfix(target, TARGET, 'raises_inside', function()
			error('late line')
		end, 10)
		call_target(1, 2)
		check(lines_with('late line') == 0, 'nothing is flushed from inside a callback')
		mr.patch_info(target)
		check(lines_with('late line') == 1, 'it is flushed at the next call from script code')
		seen()
		clean(a)

		local shorts = mr.patcher('review_short')
		local mixed_function = address('hook_mixed')
		local FULL = 'double(int64, double, float, int32, int8, double)'
		local seen_first = nil
		check(mr.call(mixed_function, FULL, 7, 2.5, 1.5, 4, 5, 0.25) == 726950.25, 'hook_mixed without links')
		check(shorts:postfix(mixed_function, 'double(int64)', 'short_post', function(call, result, first)
			seen_first = mr.tonumber(first)
		end) == true, 'a postfix with a one argument signature on a six argument function')
		check(
			mr.call(mixed_function, FULL, 7, 2.5, 1.5, 4, 5, 0.25) == 726950.25 and seen_first == 7,
			'it leaves the result and every argument of the game function intact'
		)
		check(shorts:prefix(mixed_function, 'double(int64)', 'short_pre', function(call, first)
			call:set(1, 8)
		end) == true, 'a prefix with a short signature')
		check(mr.call(mixed_function, FULL, 7, 2.5, 1.5, 4, 5, 0.25) == 826950.25, 'set changes only the named argument')
		check(shorts:around(mixed_function, 'double(int64)', 'short_around', function(game, first)
			return game(mr.tonumber(first) + 1)
		end) == true, 'an around with a short signature')
		check(mr.call(mixed_function, FULL, 7, 2.5, 1.5, 4, 5, 0.25) == 926950.25, 'game changes only the named argument as well')
		shorts:remove_all()
		check(shorts:around(mixed_function, FULL, 'forward', function(game, a, b, c, d, e, f)
			return game()
		end) == true and mr.call(mixed_function, FULL, 7, 2.5, 1.5, 4, 5, 0.25) == 726950.25, 'game() forwards the entry arguments unchanged')
		shorts:remove_all()
		shorts:prefix(target, TARGET, 'changer', function(call)
			call:set(1, 9)
		end, 10)
		shorts:around(target, TARGET, 'outer_around', function(game, x, y)
			return game(5, 6)
		end, 5)
		shorts:around(target, TARGET, 'inner_around', function(game, x, y)
			mark(mr.tonumber(x) .. mr.tonumber(y))
			return game()
		end, 0)
		check(call_target(1, 2) == 56 and seen() == '56', 'game() forwards what the outer around passed down')
		shorts:remove_all()

		local null_function = address('read_null')
		check(shorts:postfix(null_function, 'int32()', 'null_watch', function() end) == true, 'a link on a function that faults')
		local ok, why = pcall(mr.call, null_function, 'int32()')
		check(
			not ok and contains(why, 'the called function crashed'),
			'a guarded call of a linked function still turns a fault into an error: ' .. tostring(why)
		)
		check(call_target(1, 2) == 12, 'and the game goes on')
		mr.hook(null_function, 'int32()', function()
			return mr.hook_next(null_function)
		end)
		check(mr.tonumber(mr.call(null_function, 'int32()')) == 0, 'an old callback calling hook_next below links survives a fault in the original')
		check(
			contains(mr.hook_info(null_function).error, 'the called function crashed') and mr.hook_info(null_function).callbacks == 0,
			'it gets the error and detaches as before'
		)
		check(shorts:around(null_function, 'int32()', 'null_around', function(game)
			return game()
		end) == true, 'an around that calls game on a function that faults')
		ok, why = pcall(mr.call, null_function, 'int32()')
		check(
			not ok and contains(why, 'the called function crashed') and contains(why, 'access violation at 0000000000000010'),
			'a probing mr.call raises although an around covers the function: ' .. tostring(why)
		)
		check(call_target(1, 2) == 12 and not pcall(mr.call, null_function, 'int32()'), 'and the dispatcher is intact afterwards')
		check(contains(shorts:info('null_around').error, 'the called function crashed'), 'counted as the error of the link')
		shorts:remove_all()
		mr.unhook(null_function)

		local call_dir = address('call_directly')
		local DIRECT = 'int64(pointer, int64)'
		local kept, inner_error = nil, nil
		shorts:prefix(call_dir, DIRECT, 'keeper', function(call)
			kept = call
		end)
		shorts:prefix(single, SINGLE, 'inner_watch', function()
			inner_error = error_of(function()
				return kept.skipped
			end)
		end)
		mr.call(call_dir, DIRECT, single, 5)
		check(contains(inner_error, 'call object used after its call returned'), 'a kept call object raises in a link of another hook during the original')
		check(contains(error_of(kept.set, kept, 1, 1), 'call object used after its call returned'), 'and outside any call')
		local usable = 'unset'
		shorts:postfix(call_dir, DIRECT, 'same_call', function()
			usable = error_of(function()
				return kept.depth
			end)
		end)
		mr.call(call_dir, DIRECT, single, 5)
		check(usable == nil, 'inside a link of the same call it still works')
		shorts:remove_all()

		a:remove_all()
		around(a, 'first_around', 0)
		mr.hook(target, TARGET, function(x, y)
			mark('>L1')
			local result = mr.hook_next(target, x, y)
			mark('<L1')
			return result
		end)
		around(a, 'late_around', 0)
		call_target(1, 2)
		check(seen() == '>first_around >L1 >late_around <late_around <L1 <first_around', 'an old callback sits among the priority 0 arounds where it was added')
		clean(a)

		local function old_callback(name)
			mr.hook(target, TARGET, function(x, y)
				mark('>' .. name)
				local result = mr.hook_next(target, x, y)
				mark('<' .. name)
				return result
			end)
		end
		old_callback('O1')
		old_callback('O2')
		call_target(1, 2)
		check(seen() == '>O2 >O1 <O1 <O2', 'two old callbacks run newest first')
		around(a, 'added_later', 0)
		call_target(1, 2)
		check(seen() == '>O2 >O1 >added_later <added_later <O1 <O2', 'a link added after them leaves their order unchanged')
		clean(a)
		around(a, 'before_group', 0)
		old_callback('O1')
		around(a, 'between_group', 0)
		old_callback('O2')
		around(a, 'after_group', 0)
		call_target(1, 2)
		check(
			seen() == '>before_group >O2 >O1 >between_group >after_group <after_group <between_group <O1 <O2 <before_group',
			'the group sits at the registration place of its oldest member, links keep theirs'
		)
		clean(a)

		local sig = mr.patcher('review_sig')
		local same_function = function() end
		check(sig:prefix(single, SINGLE, 'swap', same_function) == true, 'a link with its first signature')
		check(sig:prefix(single, 'int32(int32)', 'swap', same_function) == true, 'the same name, function and priority with a new signature is applied')
		check(sig:prefix(single, 'int32(int32)', 'next', function() end) == true, 'the new signature is the one in force')
		check(select(2, sig:prefix(single, SINGLE, 'third', function() end)) == 'signature differs from review_sig/swap', 'and the old one is refused')
		sig:remove_all()

		local doomed_tag = nil
		a:prefix(target, TARGET, 'self_skip', function(call)
			a:remove('self_skip')
			call:skip(5)
		end, 10)
		a:postfix(target, TARGET, 'doomed_watch', function(call)
			doomed_tag = call.skipped
		end)
		check(
			call_target(1, 2) == 5 and doomed_tag == 'link_a/self_skip',
			'a link removed in its own call is still named when it skips: ' .. tostring(doomed_tag)
		)
		clean(a)

		a:postfix(target, TARGET, 'flush_one', function()
			error('flush me one')
		end)
		call_target(1, 2)
		check(lines_with('flush me one') == 0, 'a link error waits while no patcher method is called')
		mr.set_crash_context('flush_probe', 'x')
		check(lines_with('flush me one') == 1, 'set_crash_context flushes the link log')
		a:postfix(target, TARGET, 'flush_two', function()
			error('flush me two')
		end)
		call_target(1, 2)
		mr.flush_log()
		check(lines_with('flush me two') == 1, 'flush_log flushes it as well')
		clean(a)

		local worker = coroutine.create(function()
			a:postfix(target, TARGET, 'suspended', function()
				mark('F:suspended')
			end)
			coroutine.yield()
		end)
		coroutine.resume(worker)
		check(call_target(1, 2) == 12 and seen() == '', 'a link of a suspended coroutine does not run')
		coroutine.resume(worker)
		check(call_target(1, 2) == 12 and seen() == 'F:suspended', 'it runs once the coroutine can run')
		clean(a)

		local plain_calls = 20000
		local ENFORCE = os.getenv('PLUS_PERF') == '1'
		local ROUNDS = ENFORCE and 15 or 5
		local function block()
			local start = mr.ticks()
			for _ = 1, plain_calls do
				mr.call(target, TARGET, 1, 2)
			end
			return mr.elapsed_us(start) * 1000 / plain_calls
		end
		local function least(values)
			return math.min(unpack(values))
		end
		local function budget(met, what)
			if met or ENFORCE then
				check(met, what)
			else
				print('WARN ' .. what .. ' (a budget, enforced by tests\\run.ps1 -Perf)')
			end
		end
		local function measure(install, remove)
			install()
			local value = block()
			remove()
			return value
		end
		local function link(install)
			return function()
				install(mr.patcher('cost_mod'))
			end
		end
		local function drop_links()
			mr.patcher('cost_mod'):remove_all()
		end
		local function drop_hook()
			mr.unhook(target)
		end
		local PLAIN = {
			through = function()
				mr.hook(target, TARGET, function(x, y)
					return mr.hook_next(target, x, y)
				end)
			end,
			constant = function()
				mr.hook(target, TARGET, function(x, y)
					return x
				end)
			end,
		}
		local CASES = {
			{
				'bare_post',
				'through',
				link(function(p)
					p:postfix(target, TARGET, 'bare', function() end)
				end),
			},
			{
				'bare_pre',
				'through',
				link(function(p)
					p:prefix(target, TARGET, 'bare', function() end)
				end),
			},
			{
				'bare_through',
				'through',
				link(function(p)
					p:around(target, TARGET, 'bare', function(game, x, y)
						return game(x, y)
					end)
				end),
			},
			{
				'bare_constant',
				'constant',
				link(function(p)
					p:around(target, TARGET, 'bare', function(game, x, y)
						return x
					end)
				end),
			},
			{
				'field_post',
				'through',
				link(function(p)
					p:postfix(target, TARGET, 'fields', function(call)
						local site, skipped, depth = call.site, call.skipped, call.depth
					end)
				end),
			},
			{
				'field_pre',
				'through',
				link(function(p)
					p:prefix(target, TARGET, 'fields', function(call)
						local site, skipped, depth = call.site, call.skipped, call.depth
					end)
				end),
			},
			{
				'two_links',
				'through',
				link(function(p)
					p:prefix(target, TARGET, 'pre', function() end)
					p:postfix(target, TARGET, 'post', function() end)
				end),
			},
		}
		local absolute = { unhooked = {}, through = {}, constant = {} }
		for _, case in ipairs(CASES) do
			absolute[case[1]] = {}
		end
		for _ = 1, ROUNDS do
			table.insert(absolute.unhooked, block())
			table.insert(absolute.through, measure(PLAIN.through, drop_hook))
			table.insert(absolute.constant, measure(PLAIN.constant, drop_hook))
			for _, case in ipairs(CASES) do
				table.insert(absolute[case[1]], measure(case[3], drop_links))
			end
		end
		local function ns(name)
			return least(absolute[name])
		end
		local BASE = {}
		for _, case in ipairs(CASES) do
			BASE[case[1]] = case[2]
		end
		local function cost(name)
			local plain = ns(BASE[name]) - ns('unhooked')
			return plain > 0 and (ns(name) - ns('unhooked')) / plain or math.huge
		end
		local function total(name)
			return ns(name) / ns(BASE[name])
		end
		print(
			string.format(
				'  timing (ns per mr.call, host, least of %d rounds): unhooked %.0f, plain hook with hook_next %.0f, plain hook returning a value %.0f',
				ROUNDS,
				ns('unhooked'),
				ns('through'),
				ns('constant')
			)
		)
		print(
			string.format(
				'  timing: bare postfix %.0f, bare prefix %.0f, around with game %.0f, around returning a value %.0f, postfix reading 3 fields %.0f, prefix reading 3 fields %.0f, prefix and postfix %.0f',
				ns('bare_post'),
				ns('bare_pre'),
				ns('bare_through'),
				ns('bare_constant'),
				ns('field_post'),
				ns('field_pre'),
				ns('two_links')
			)
		)
		print(
			string.format(
				'  cost above unhooked, link / plain hook (least of the rounds): postfix %.2f, prefix %.2f, around with game %.2f, around returning a value %.2f, postfix with fields %.2f, prefix with fields %.2f',
				cost('bare_post'),
				cost('bare_pre'),
				cost('bare_through'),
				cost('bare_constant'),
				cost('field_post'),
				cost('field_pre')
			)
		)
		print(
			string.format(
				'  whole call, link / plain hook (least of the rounds): postfix %.2f, prefix %.2f, around with game %.2f, around returning a value %.2f, postfix with fields %.2f, prefix with fields %.2f',
				total('bare_post'),
				total('bare_pre'),
				total('bare_through'),
				total('bare_constant'),
				total('field_post'),
				total('field_pre')
			)
		)
		budget(total('bare_post') <= 1.2 and total('bare_pre') <= 1.2 and total('bare_through') <= 1.2, 'a bare link costs at most 1.2 times a plain hook')
		budget(total('field_post') <= 1.2 and total('field_pre') <= 1.2, 'a link reading call fields costs at most 1.2 times a plain hook')
		budget(total('bare_constant') <= 1.2, 'an around that returns a value costs at most 1.2 times a plain hook that does')
		for _, case in ipairs(CASES) do
			if cost(case[1]) > 1.2 then
				print(('  warning: %s costs %.2f times what a plain hook costs above an unhooked call (budget 1.2)'):format(case[1], cost(case[1])))
			end
			budget(cost(case[1]) <= 1.5, case[1] .. ' costs at most 1.5 times what a plain hook costs above an unhooked call')
		end

		a:prefix(target, TARGET, 'keep_pre', function() end, 4)
		a:postfix(target, TARGET, 'keep_post', function()
			error('first mode error')
		end)
		call_target(1, 2)
		NEXT_PASS = failures == 0
	else
		local a = mr.patcher('link_a')
		check(
			mr.hook_info(target) ~= nil and not mr.hook_info(target).attached and mr.hook_info(target).callbacks == 0,
			'a new state starts with every link detached'
		)
		check(a:info('keep_pre').state == 'detached' and a:info('keep_post').state == 'detached', 'the registry lists them as detached')
		check(lines_with('first mode error') == 0, 'a line that was waiting when the mode ended is not written in the next one')
		check(call_target(1, 2) == 12, 'the original runs')
		check(mr.patch_info(target).links[1] == nil, 'patch_info lists no links')
		check(a:prefix(target, TARGET, 'keep_pre', function()
			mark('P:keep')
		end, 4) == true and a:info('keep_pre').state == 'stays', 'the same name attaches again in the new mode')
		check(a:postfix(target, TARGET, 'keep_post', function()
			error('second mode error')
		end) == true, 'the postfix attaches again')
		check(a:info('keep_pre').calls == 0 and a:info('keep_post').calls == 0, 'counters start again')
		check(call_target(1, 2) == 12 and call_target(1, 2) == 12 and seen() == 'P:keep P:keep', 'the links run in the new mode')
		check(a:info('keep_post').errors == 2, 'and count their errors from zero: ' .. a:info('keep_post').errors)
		mr.patch_info(target)
		check(lines_with('link_a/keep_post (postfix): ') == 1 and lines_with('second mode error') == 1, 'the first error is logged once in every mode')
		check(#mr.patch_list('link_a') > 0, 'the registry survived')
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

	local victim = mr.pointer(test_function('hook_target'))
	local victim_head = mr.read(victim, 0, 16)
	local slots_before = mr.hop_slots()
	local TWO = 'int32(int32, int32)'
	test_deny_next_thread(true, mr.hop_slots)
	test_deny_snapshot(true, mr.hop_slots)
	test_force_far_hooks(true, mr.hop_slots)
	ok, message = pcall(mr.hook, victim, TWO, function()
		return 1
	end)
	test_force_far_hooks(false, mr.hop_slots)
	test_deny_snapshot(false, mr.hop_slots)
	test_deny_next_thread(false, mr.hop_slots)
	check(
		not ok and string.find(tostring(message), 'the other threads could not be stopped', 1, true) ~= nil,
		'a far hook is refused when the other threads cannot be stopped: ' .. tostring(message)
	)
	check(mr.read(victim, 0, 16) == victim_head and mr.hook_info(victim) == nil, 'and the function keeps its first bytes')
	check(mr.hop_slots() == slots_before, 'and no padding slot is used up')
	check(mr.tonumber(mr.call(victim, TWO, 3, 4)) == 34, 'and still runs')
	test_force_far_hooks(true, mr.hop_slots)
	mr.hook(victim, TWO, function()
		return 1
	end)
	test_force_far_hooks(false, mr.hop_slots)
	check(mr.tonumber(mr.call(victim, TWO, 3, 4)) == 1 and mr.read(victim, 0, 1) == '\233', 'once the threads can be stopped the same hook goes in')
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
	local jump = mr.read(far, 0, 5)
	local top = jump:byte(5)
	if top >= 128 then top = top - 256 end
	local hop = mr.add(far, 5 + jump:byte(2) + jump:byte(3) * 256 + jump:byte(4) * 65536 + top * 16777216)
	check(mr.eq(hop, fixture('hop_leaf_pad')), 'the far cave took the first padding run, the one after the hop fixture')
	check(mr.read_original(hop, 0, 14) == string.rep('\204', 14), 'the original bytes of a used hop slot are its padding')
	local relay_bytes = mr.read(hop, 6, 2)
	mr.write(hop, 6, mr.uint8(0xEB))
	mr.write(hop, 7, mr.uint8(0xF3))
	local hits = cave_count()
	local after_junk = error_of(mr.code_cave, fixture('hop_leaf_here'), code)
	mr.write(hop, 6, mr.uint8(relay_bytes:byte(1)))
	mr.write(hop, 7, mr.uint8(relay_bytes:byte(2)))
	check(after_junk == nil, 'a hop slot behind a leaf function does not refuse a cave whatever address it holds: ' .. tostring(after_junk))
	check(mr.tonumber(mr.call(fixture('hop_leaf_here'), 'int32(int32)', 3)) == 4 and cave_count() == hits + 1, 'that cave runs')
	check(mr.tonumber(mr.call(far, TARGET, 3, 4)) == 34, 'and the far cave still works with its address back')
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
	local mixed = mr.pointer(test_function('mixed_code'))
	local PAGE, FILLER_PAGES, MIXED_PAGES, RUN_PAGES = 4096, 272, 40, 38
	local zeros, nops = string.rep('\0', PAGE), string.rep('\144', PAGE)
	local ZERO16 = '00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00'
	test_fill_mixed(MIXED_PAGES * PAGE)
	local pages = {}
	for page = 0, MIXED_PAGES - 1 do
		pages[#pages + 1] = mr.read(mixed, page * PAGE, PAGE)
	end
	local original = table.concat(pages)
	local function original_at(offset, size)
		return original:sub(offset + 1, offset + size)
	end
	local zero_first, zero_count = mr.find_pattern(ZERO16)
	local filler_runs = FILLER_PAGES * PAGE - 15
	check(zero_count >= filler_runs, 'the filler holds a run of 16 zero bytes at every position: ' .. zero_count)

	local probes = {}
	for _, size in ipairs({ 6, 17, 33, 100, 256 }) do
		for _, edge in ipairs({ 65536, 131072 }) do
			for _, context in ipairs({ size - 1, 255 }) do
				for _, shift in ipairs({ 0, 8 }) do
					probes[#probes + 1] = { offset = edge - context - shift - math.floor(size / 2), size = size }
				end
			end
		end
	end
	local p = mr.patcher('expect_probe')
	local expect_at = 65536 - 300
	local function expect_result(expect_bytes, pad)
		local target = { pattern = hex(original_at(expect_at, 32)) .. pad, at = 8, expect = hex(expect_bytes) }
		local current = mr.read(mixed, expect_at + 8, 8)
		local ok, why, found = p:patch('probe', target, current, string.rep('\204', 8))
		if ok == true then p:remove('probe') end
		return ok == true or (why == 'unexpected bytes' and found == nil and 'refused') or tostring(why)
	end
	local level_count = 0
	local function check_level(label)
		level_count = level_count + 1
		local pad = string.rep(' ', 2 * level_count)
		local first, count = mr.find_pattern(ZERO16 .. pad)
		check(count == zero_count and mr.eq(first, zero_first), label .. ': every original run of zeros is found once, first at the same place: ' .. count)
		local every, list = true, {}
		for i, probe in ipairs(probes) do
			list[i] = hex(original_at(probe.offset, probe.size)) .. pad
			local at, found = mr.find_pattern(list[i])
			every = every and found == 1 and mr.eq(at, mr.add(mixed, probe.offset))
		end
		check(every, label .. ': a pattern of distinct bytes across a 64 KB piece edge is found once at its place, each length on its own')
		list[#list + 1] = ZERO16 .. pad .. ' '
		local found, counts = mr.find_patterns(list)
		local together = counts[#list] == zero_count and mr.eq(found[#list], zero_first)
		for i, probe in ipairs(probes) do
			together = together and counts[i] == 1 and mr.eq(found[i], mr.add(mixed, probe.offset))
		end
		check(together, label .. ': find_patterns of mixed lengths gives the same counts and first addresses')
		local right, wrong = expect_result(original_at(expect_at + 8, 8), pad), expect_result(mr.read(mixed, expect_at + 8, 8), pad .. '  ')
		local changed = mr.read(mixed, expect_at + 8, 8) ~= original_at(expect_at + 8, 8)
		check(
			right == true and (wrong == 'refused' or not changed),
			label .. ': expect compares the original bytes: ' .. tostring(right) .. ', ' .. tostring(wrong)
		)
	end
	check_level('before any change')

	for page = 0, RUN_PAGES - 1 do
		mr.patch(mr.add(mixed, page * PAGE), original_at(page * PAGE, PAGE), nops)
	end
	check(mr.read(mixed, 0, PAGE) == nops, 'the mixed bytes are patched over')
	check_level('mixed bytes saved')

	local spot = RUN_PAGES * PAGE + 512
	local SPOT_SIZE = 600
	local steps = { { 3, 40 }, { 20, 9 }, { 37, 30 }, { 1, 2 }, { 100, 1 }, { 101, 70 }, { 90, 200 }, { 0, 16 }, { 15, 2 }, { 299, 300 } }
	local used_before = mr.capacity().saved_code.used
	for i, step in ipairs(steps) do
		local at = mr.add(mixed, spot + step[1])
		mr.patch(at, mr.read(at, 0, step[2]), string.rep(string.char(i), step[2]))
	end
	local saved_by_steps = mr.capacity().saved_code.used - used_before
	print('  saved ranges for ' .. #steps .. ' overlapping patches: ' .. saved_by_steps)
	check(mr.read(mixed, spot, SPOT_SIZE) ~= original_at(spot, SPOT_SIZE), 'overlapping patches change the bytes')
	check(
		mr.read_original(mr.add(mixed, spot), 0, SPOT_SIZE) == original_at(spot, SPOT_SIZE),
		'read_original over overlapping patches gives the oldest bytes everywhere'
	)
	local exact = true
	for _, size in ipairs({ 5, 16, 33, 64, 200 }) do
		for offset = 0, SPOT_SIZE - size, 37 do
			local at, count = mr.find_pattern(hex(original_at(spot + offset, size)))
			exact = exact and count == 1 and mr.eq(at, mr.add(mixed, spot + offset))
		end
	end
	check(exact, 'every window of the original bytes under overlapping patches is found once at its place')
	mr.patch(mr.add(mixed, spot), mr.read(mixed, spot, SPOT_SIZE), mr.read_original(mr.add(mixed, spot), 0, SPOT_SIZE))
	check(mr.read(mixed, spot, SPOT_SIZE) == original_at(spot, SPOT_SIZE), 'patching back from read_original restores the bytes')

	local overlap = mr.add(filler, 135 * PAGE + 64)
	mr.patch(overlap, '\0', '\1')
	mr.patch(mr.add(overlap, 4), '\0\0\0\0', '\2\2\2\2')
	check(mr.read(overlap, 0, 8) == '\1\0\0\0\2\2\2\2', 'two patches whose saved ranges overlap are both written')
	check(mr.read_original(mr.add(overlap, -8), 24) == string.rep('\0', 24), 'overlapping saved ranges keep the oldest bytes')
	check(select(2, mr.find_pattern(ZERO16 .. string.rep(' ', 40))) == zero_count, 'a fresh scan across both ranges sees the original zeros at every position')
	mr.patch(mr.add(overlap, 4), '\2\2\2\2', '\0\0\0\0')
	mr.patch(overlap, '\1', '\0')

	local LIMIT = 65536
	local chunk = 0
	local function fill_until(used)
		while mr.capacity().saved_code.used < used and chunk < FILLER_PAGES do
			mr.patch(mr.add(filler, chunk * PAGE), zeros, nops)
			chunk = chunk + 1
		end
	end
	fill_until(4097)
	check(mr.capacity().saved_code.room > 4096 and count_in(log_text(), FULL_LINE) == 0, 'the saved original table grows past 4096 ranges without a full line')
	check(mr.read_original(filler, 0, 16) == string.rep('\0', 16), 'ranges saved before the table grew keep their original bytes')
	check_level('past 4096 ranges')
	local near = LIMIT - 600
	fill_until(near)
	local newest = mr.add(filler, (chunk - 1) * PAGE + 4080)
	check(mr.read_original(newest, 0, 16) == string.rep('\0', 16), 'and so do the newest ranges')
	check_level('nearly full')
	local list = {}
	for i = 1, 64 do
		list[i] = string.format('48 89 5C 24 %02X 48 89 74 24 %02X 57 48 83 EC %02X', i, (i * 7) % 256, (i * 13) % 256)
	end
	local started = mr.ticks()
	mr.find_patterns(list)
	local spent = mr.elapsed_us(started)
	print(string.format('  timing: find_patterns of 64 new patterns over %d saved ranges %.0f us', mr.capacity().saved_code.used, spent))
	check(spent < 50000, 'find_patterns of 64 new patterns with a nearly full saved table stays under 50 ms')
	local before_full = chunk
	while count_in(log_text(), FULL_LINE) == 0 and chunk < FILLER_PAGES do
		mr.patch(mr.add(filler, chunk * PAGE), zeros, nops)
		chunk = chunk + 1
	end
	check(count_in(log_text(), FULL_LINE) == 1, 'a full table is reported once in the log')
	check(string.find(log_text(), 'saved original code is full (65536 ranges)', 1, true) ~= nil, 'the full line names the 65536 ranges')
	check(mr.read_original(filler, 0, 16) == string.rep('\0', 16), 'the first ranges keep their original bytes')
	local last = mr.add(filler, (chunk - 1) * PAGE + PAGE - 16)
	check(mr.read_original(last, 0, 16) == string.rep('\144', 16), 'ranges changed after the table filled up show the new bytes')
	mr.patch(mr.add(filler, (chunk - 1) * PAGE), nops, zeros)
	check(count_in(log_text(), FULL_LINE) == 1, 'further changes do not repeat the report')
	print('  filler pages patched to fill the table: ' .. before_full .. ' to nearly full, ' .. chunk .. ' to full')
	check_level('full')

	local blocked, carry = {}, 11 * PAGE
	for i, byte in ipairs({ test_function('filler_code'):byte(1, 8) }) do
		blocked[i] = string.char((byte + carry) % 256)
		carry = math.floor((byte + carry) / 256)
	end
	blocked = table.concat(blocked)
	local old_protect = test_protect(blocked, PAGE, 1)
	started = mr.ticks()
	local blocked_first, blocked_count = mr.find_pattern(ZERO16 .. string.rep(' ', 41))
	spent = mr.elapsed_us(started)
	test_protect(blocked, PAGE, old_protect)
	print(string.format('  timing: a scan through saved code with one unreadable page %.0f us', spent))
	check(
		blocked_count == zero_count - PAGE - 15 and mr.eq(blocked_first, zero_first),
		'a page that cannot be read loses only the matches that touch it: ' .. blocked_count .. ' of ' .. zero_count
	)
	check(select(2, mr.find_pattern(ZERO16 .. string.rep(' ', 42))) == zero_count, 'and every match is back once the page can be read')
elseif
	SCENARIO == 'fault_report'
	or SCENARIO == 'fault_report_no_log'
	or SCENARIO == 'fault_report_off'
	or SCENARIO == 'fault_report_in_callback'
	or SCENARIO == 'fault_report_in_site'
	or SCENARIO == 'fault_report_in_cave'
	or SCENARIO == 'fault_report_in_link'
	or SCENARIO == 'fault_report_in_original'
	or SCENARIO == 'fault_report_in_around'
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
		local function crash_in_cave()
			local target = test_function('cave_target')
			mr.patcher('crash_owner'):cave('crash_cave', mr.pointer(target), '\72\49\192\139\64\16')
			test_run(target, 1, 2)
		end
		local function crash_in_link()
			local single = mr.pointer(test_function('hook_single'))
			local pad = mr.patcher('pad_owner')
			local filler = mr.pointer(test_function('filler_code'))
			for i = 1, 3 * 256 + 8 do
				pad:set('pad_' .. i, mr.add(filler, 0x10000 + i), 1, 0, 0, 255)
			end
			mr.patcher('crash_owner'):prefix(single, 'int64(int64)', 'crash_link', function()
				test_crash()
			end)
			mr.call(mr.pointer(test_function('call_directly')), 'int64(pointer, int64)', single, 1)
		end
		local function crash_in_original()
			local target = test_function('read_null')
			mr.patcher('crash_owner'):postfix(mr.pointer(target), 'int32()', 'crash_post', function() end)
			test_run(target, 0, 0)
		end
		local function crash_in_around()
			local target = test_function('read_null')
			mr.patcher('crash_owner'):around(mr.pointer(target), 'int32()', 'crash_around', function(game)
				return game()
			end)
			test_run(target, 0, 0)
		end
		local function report_me()
			local marker = 'event-under-test'
			if SCENARIO == 'fault_report_in_callback' then
				crash_in_callback()
			elseif SCENARIO == 'fault_report_in_cave' then
				crash_in_cave()
			elseif SCENARIO == 'fault_report_in_link' then
				crash_in_link()
			elseif SCENARIO == 'fault_report_in_original' then
				crash_in_original()
			elseif SCENARIO == 'fault_report_in_around' then
				crash_in_around()
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
elseif SCENARIO == 'owner_report' then
	io.stdout:setvbuf('no')
	load_other_program_dll()
	run_mod(OURS)
	local mr = _G.memreader_plus
	local function address(name)
		return mr.pointer(test_function(name))
	end
	local filler = address('filler_code')
	local ONES, ZEROS = '\1\0\0\0', '\0\0\0\0'
	local function relocation_sites()
		return { { mr.add(filler, 0x200), ZEROS, ONES }, { mr.add(filler, 0x208), ZEROS, ONES } }
	end
	local function install_all(p, code, with_site)
		local cave = p:cave('keep_health', address('cave_target'), code)
		local results = {
			{ 'cave', mr.type(cave) == 'pointer' },
			{ 'patch', p:patch('load_copy', address('patch_target'), '\184\1\0\0\0', '\184\2\0\0\0') == true },
			{ 'set', p:set('army_cap', mr.add(filler, 0x100), 4, 5, 0, 100) == true },
			{ 'frame', p:frame('planner', address('frame_target'), 0x360) == true },
			{ 'relocate', p:relocate('fields', relocation_sites()) == true },
		}
		if with_site then results[#results + 1] = { 'site', p:site('on_target', address('site_target_here'), function() end) == true } end
		for _, result in ipairs(results) do
			check(result[2], 'owned ' .. result[1] .. ' is installed or already ours')
		end
		return cave
	end
	local code = '\80\72\184' .. cave_count_address() .. '\255\0\88'
	if PASS == 1 then
		check(type(mr.patcher) == 'function' and type(mr.patch_list) == 'function', 'patcher and patch_list are part of the API')
		local p = mr.patcher('alpha_mod')
		check(type(p) == 'userdata' and mr.patcher('alpha_mod') == p, 'the same owner gets the same handle in a mode')
		check(mr.patcher('beta_mod') ~= p, 'another owner gets another handle')
		check(#mr.patch_list() == 0, 'patch_list starts empty')
		local cave = install_all(p, code, true)
		check(mr.tonumber(mr.call(address('cave_target'), 'int32(int32, int32)', 3, 4)) == 34 and cave_count() == 1, 'the owned cave runs')
		check(mr.patcher('beta_mod'):patch('other_patch', mr.add(filler, 0x300), ZEROS, ONES) == true, 'a second owner patches too')
		loadstring('local mr, target, code = ...; mr.code_cave(target, code)', 'raw_cave_caller')(mr, address('hook_target'), code)
		local rows = mr.patch_list('alpha_mod')
		local by_name = {}
		for _, row in ipairs(rows) do
			by_name[row.name] = row
		end
		check(#rows == 6 and #mr.patch_list('beta_mod') == 1 and #mr.patch_list() == 7, 'patch_list lists every owned item, by owner too')
		check(#mr.patch_list('nobody') == 0, 'an owner without items lists nothing')
		check(by_name.keep_health.kind == 'cave' and by_name.keep_health.state == 'stays', 'a cave stays for the session')
		check(by_name.load_copy.kind == 'patch' and by_name.load_copy.state == 'ours', 'a patch is ours while its bytes are there')
		check(by_name.army_cap.kind == 'value' and by_name.fields.kind == 'relocate' and by_name.planner.kind == 'frame', 'kinds are named')
		check(by_name.on_target.kind == 'site' and by_name.on_target.state == 'stays', 'an attached site stays')
		check(mr.eq(by_name.on_target.at, address('site_target_here')), 'a site row carries its address')
		check(mr.eq(p:info('load_copy').at, address('patch_target')) and p:info('load_copy').owner == 'alpha_mod', 'info gives the row of one name')
		check(p:info('nothing') == nil and select(2, p:info('nothing')) == 'unknown name', 'info of an unknown name is nil and why')
		local flood = mr.patcher('flood_mod')
		local floods = 0
		for i = 0, 40 do
			if flood:patch('flood_' .. i, mr.add(filler, 0x1000 + i * 8), ZEROS, ONES) == true then floods = floods + 1 end
		end
		loadstring('local mr, address = ...; mr.patch(address, "\\0", "\\1")', 'raw_hidden_patch')(mr, mr.add(filler, 0x2000))
		for i = 41, 46 do
			if flood:patch('flood_' .. i, mr.add(filler, 0x1000 + i * 8), ZEROS, ONES) == true then floods = floods + 1 end
		end
		check(floods == 47, 'one owner patches 47 named places from one line')
		NEXT_PASS = failures == 0
	else
		local p = mr.patcher('alpha_mod')
		check(#mr.patch_list('alpha_mod') == 6, 'the registry survives the mode switch')
		check(p:info('on_target').state == 'detached', 'a site without its callback after the mode switch is detached')
		local filtered = mr.patcher('filter_mod')
		local filter_set, broken_set = mr.pointer_set(), mr.pointer_set()
		filter_set:fill({ mr.uint64(5), mr.uint64(6) })
		broken_set:fill(true)
		check(
			filtered:prefix(address('hook_single'), 'int64(int64)', 'seen', function() end, nil, { arg = 1, reads = { 16, -8 }, set = filter_set }) == true
				and filtered:prefix(
						address('hook_mixed'),
						'double(int64, double, float, int32, int8, double)',
						'broken',
						function() end,
						nil,
						{ arg = 1, reads = { 0 }, set = broken_set }
					)
					== true,
			'two filtered links, one on a chain that will fault'
		)
		mr.call(address('hook_mixed'), 'double(int64, double, float, int32, int8, double)', mr.int64(test_reserved()), 0, 0, 0, 0, 0)
		local cave = install_all(p, code, false)
		check(mr.eq(cave, mr.hook_info(address('cave_target')).cave), 'repeating every name is a no-op and the cave pointer is the same')
		check(#mr.patch_list('alpha_mod') == 6, 'and adds nothing')
		fill_crash_context(mr)
		set_report_settings(mr)
		local first_name = mr.write_runtime_report()
		check(type(first_name) == 'string' and exists(first_name), 'a runtime report is written while the site has no callback: ' .. tostring(first_name))
		local first = read_all(first_name)
		check(has(first, '), 1 frame, 2 relocations, 1 link not attached\n'), 'the owner block counts the detached site as not attached')
		check(not has(first, '1 link, '), 'and not as a link')
		check(not has(first, 'by alpha_mod/on_target'), 'its hook line is not named after it')
		test_sleep(1100)
		local name
		check(p:site('on_target', address('site_target_here'), function()
			name = mr.write_runtime_report()
		end) == true, 'the site attaches again')
		check(p:info('on_target').state == 'stays', 'and is attached')
		check(
			mr.patcher('gamma_mod'):site('shared', address('site_target_here'), function() end) == true,
			'a second owner shares the site, its callback runs first'
		)
		mr.call(address('site_target'), 'int32(int32, int32)', 3, 4)
		check(type(name) == 'string' and exists(name), 'a runtime report is written from inside the site callback: ' .. tostring(name))
		local text = read_all(name)
		local owner_at, hooks_at = text:find('memreader Plus changes by owner:', 1, true), text:find('memreader Plus hooks: ', 1, true)
		check(owner_at and hooks_at and owner_at < hooks_at, 'the owner block comes before the hook list')
		for _, part in ipairs({
			'  alpha_mod: 1 link, 1 value, 1 cave (keep_health Warhammer3.exe+0x',
			'), 1 patch (load_copy Warhammer3.exe+0x',
			'), 1 frame, 2 relocations\n',
			'  beta_mod: 1 patch (other_patch Warhammer3.exe+0x',
			'  gamma_mod: 1 link\n',
			'  ?: 1 code cave at Warhammer3.exe+0x',
			' from [string "raw_cave_caller"]:1\n',
			'memreader Plus link running: alpha_mod/on_target (site) on Warhammer3.exe+0x',
			', code cave, by alpha_mod/keep_health\n',
			', code cave, from [string "raw_cave_caller"]:1\n',
			', site hook, RUNNING (on the stack)',
			', by alpha_mod/on_target, gamma_mod/shared\n',
			', by filter_mod/seen when arg 1 [+0x10] [-0x8] in 2\n',
			', by filter_mod/broken when arg 1 [+0x0] in all, off: read at 0x',
			', by alpha_mod/load_copy\n',
			', by alpha_mod/army_cap\n',
			', by alpha_mod/planner\n',
			'  relocate_field x2 spread between ',
			', by alpha_mod/fields\n',
			', by beta_mod/other_patch\n',
			'[string "raw_hidden_patch"]:1',
			'more owned patches not listed',
		}) do
			check(has(text, part), 'the report has: ' .. part:gsub('\n', '\\n'))
		end
		check(
			not has(text, 'link running: gamma_mod') and count_lines(text, 'memreader Plus link running') == 1,
			'link running names only the callback on the stack'
		)
		check(not has(text, 'alpha_mod: 1 link, 1 value, 1 cave (keep_health Warhammer3.exe+0x0'), 'the cave address is a real offset')
	end
elseif SCENARIO == 'change_rows' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local filler = mr.pointer(test_function('filler_code'))
	local EXE = 'Warhammer3%.exe%+0x(%x+)'
	local function relocate(name, offsets)
		local sites = {}
		for i, offset in ipairs(offsets) do
			sites[i] = { mr.add(filler, offset), '\0\0\0\0', '\1\0\0\0' }
		end
		assert(loadstring('local mr, sites = ...; assert(mr.relocate_field(sites))', name))(mr, sites)
	end
	local function patch(name, offsets)
		for _, offset in ipairs(offsets) do
			patch_from_chunk(name, mr, mr.add(filler, offset))
		end
	end
	relocate('spread_sites', { 0x400, 0x408, 0x410 })
	relocate('block_sites', { 0x500, 0x504, 0x508 })
	relocate('descending_sites', { 0x604, 0x600 })
	relocate('single_site', { 0x700 })
	patch('spread_patches', { 0x800, 0x900 })
	patch('block_patches', { 0xA00, 0xA01 })
	local text = read_all(assert(mr.write_runtime_report()))
	local function row(name)
		for line in text:gmatch('[^\r\n]+') do
			if has(line, '[string "' .. name .. '"]:1') then return line end
		end
		return ''
	end
	local function shape(name, pattern, distance, spread)
		local line = row(name)
		local low, high = line:match(pattern)
		local gap = low and high and tonumber(high, 16) - tonumber(low, 16)
		check(gap == distance, name .. ' row: ' .. line)
		check(has(line, 'not one block') == spread and has(line, 'spread between') == spread, name .. ' row spread flag is ' .. tostring(spread))
	end
	local ending = ', %d bytes, from '
	shape('spread_sites', '^  relocate_field x3 spread between ' .. EXE .. ' and ' .. EXE .. ' %(not one block%)' .. ending:format(4), 0x10, true)
	shape('block_sites', '^  relocate_field x3 at ' .. EXE .. ' to ' .. EXE .. ending:format(4), 8, false)
	shape('descending_sites', '^  relocate_field x2 at ' .. EXE .. ' to ' .. EXE .. ending:format(4), 4, false)
	shape('spread_patches', '^  patch x2 spread between ' .. EXE .. ' and ' .. EXE .. ' %(not one block%)' .. ending:format(1), 0x100, true)
	shape('block_patches', '^  patch x2 at ' .. EXE .. ' to ' .. EXE .. ending:format(1), 1, false)
	local single = row('single_site')
	check(single:match('^  relocate_field at ' .. EXE .. ', 4 bytes, from ') ~= nil, 'a single site keeps the plain form: ' .. single)
	check(not has(single, 'spread'), 'and says nothing about a spread')
elseif SCENARIO == 'claims' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local function address(name)
		return mr.pointer(test_function(name))
	end
	local function contains(text, part)
		return type(text) == 'string' and string.find(text, part, 1, true) ~= nil
	end
	local filler = address('filler_code')
	local function at(offset)
		return mr.add(filler, offset)
	end
	local Z4, ONE4, TWO4, NINE4 = '\0\0\0\0', '\1\0\0\0', '\2\0\0\0', '\9\9\9\9'
	local function bytes_at(offset, size)
		return mr.read(at(offset), 0, size)
	end
	local a, b = mr.patcher('claim_a'), mr.patcher('claim_b')
	check(select(2, mr.patcher('bad name')) == 'owner must be 1 to 63 letters, digits or underscores', 'an owner with a space is refused')
	check(mr.patcher('') == nil and mr.patcher(string.rep('x', 64)) == nil, 'an empty or 64 byte owner is refused')
	check(mr.patcher(string.rep('y', 63)) ~= nil, 'a 63 byte owner is accepted')
	check(not pcall(mr.patcher) and not pcall(mr.patcher, {}), 'a missing or wrong type owner raises')
	check(not pcall(a.patch, 'x', filler, Z4, ONE4), 'a method called without the handle raises')
	check(select(2, a:patch('bad name', at(0), Z4, ONE4)) == 'name must be 1 to 47 letters, digits or underscores', 'a name with a space is refused')
	check(a:patch('first', at(0), Z4, ONE4) == true and bytes_at(0, 4) == ONE4, 'claim_a patches 4 bytes')
	check(#mr.patch_list('claim_a') == 1, 'and owns one item')
	local ok, why, found = b:patch('overlap', at(2), Z4, TWO4)
	check(ok == nil and why == 'held by claim_a/first', 'claim_b is refused over claim_a bytes: ' .. tostring(why))
	check(bytes_at(2, 4) == '\0\0\0\0' and #mr.patch_list('claim_b') == 0, 'the refused patch wrote and registered nothing')
	ok, why = b:set('over_field', at(1), 1, 5, 0, 10)
	check(ok == nil and why == 'held by claim_a/first', 'claim_b set is refused over claim_a bytes')
	ok, why = b:relocate('over_sites', { { at(100), Z4, ONE4 }, { at(3), '\0', '\3' } })
	check(ok == nil and why == 'site 2: held by claim_a/first', 'a relocation with one held site is refused: ' .. tostring(why))
	check(bytes_at(100, 4) == Z4 and #mr.patch_list('claim_b') == 0, 'and writes none of its sites')
	ok, why, found = b:patch('wrong_bytes', at(200), ONE4, TWO4)
	check(ok == nil and why == 'unexpected bytes' and found == Z4, 'wrong expected bytes give nil, why and the bytes found')
	check(a:patch('first', at(0), Z4, ONE4) == true and #mr.patch_list('claim_a') == 1, 'the same owner and name again is a no-op')
	ok, why = a:patch('again', at(1), '\0\0\0\0', TWO4)
	check(ok == nil and why == 'held by claim_a/first', 'the same owner cannot overlap its own other name')
	ok, why = a:patch('first', at(0), Z4, TWO4)
	check(ok == nil and why == 'the name is already used for a different change', 'the same name with other bytes is refused')
	check(a:remove('first') == true and bytes_at(0, 4) == Z4 and #mr.patch_list('claim_a') == 0, 'remove puts the held bytes back')
	check(b:patch('overlap', at(2), Z4, TWO4) == true, 'after the removal claim_b may patch the range')
	check(select(2, a:remove('first')) == 'unknown name', 'removing a removed name is nil and why')
	mr.patch(at(2), TWO4, NINE4)
	ok, why = b:remove('overlap')
	check(ok == nil and why == 'the bytes were changed by something else', 'remove refuses bytes changed by someone else: ' .. tostring(why))
	check(b:info('overlap').state == 'missing' and bytes_at(2, 4) == NINE4, 'the state says missing and the bytes stay')
	mr.patch(at(2), NINE4, Z4)
	check(b:info('overlap').state == 'held', 'bytes put back by someone else read as held')
	check(b:remove('overlap') == true and #mr.patch_list('claim_b') == 0, 'then remove drops the item')

	check(a:set('cap', at(0x400), 4, 7, 0, 100) == true and mr.read_int32(at(0x400), 0) == 7, 'set writes a number')
	check(a:set('cap', at(0x400), 4, 9, 0, 100) == true and mr.read_int32(at(0x400), 0) == 9, 'the same name sets another number')
	ok, why = a:set('cap', at(0x400), 4, 400, 0, 100)
	check(ok == nil and contains(why, 'number must lie between low and high'), 'a number outside low and high is refused')
	ok, why = a:set('bad_start', at(0x500), 4, 20, 10, 100)
	check(ok == nil and why == 'the current value is outside low and high', 'a current value outside low and high is refused')
	ok, why = a:set('bad_size', at(0x500), 3, 5, 0, 100)
	check(ok == nil and why == 'size must be 1 or 4', 'a size other than 1 or 4 is refused')
	ok, why = b:set('cap_steal', at(0x400), 4, 5, 0, 100)
	check(ok == nil and why == 'held by claim_a/cap', 'another owner cannot set a held field')
	mr.patch(at(0x400), '\9\0\0\0', '\4\0\0\0')
	ok, why = a:set('cap', at(0x400), 4, 10, 0, 100)
	check(ok == nil and why == 'the bytes were changed by something else' and mr.read_int32(at(0x400), 0) == 4, 'set refuses a field changed by someone else')
	check(a:set('small', at(0x600), 1, 200, 0, 255) == true and bytes_at(0x600, 1) == '\200', 'a one byte field takes 0 to 255')
	check(a:remove('small') == true and bytes_at(0x600, 1) == '\0', 'remove puts the one byte field back')

	local target = address('hook_target')
	local first = mr.read(target, 0, 1)
	check(a:patch('claim_start', target, first, first) == true, 'a patch with equal bytes claims a range without changing it')
	ok, why = b:cave('cave_over', target, '\144')
	check(ok == nil and why == 'held by claim_a/claim_start' and mr.hook_info(target) == nil, 'a cave over a held range is refused and installs nothing')
	local cave = b:cave('own_cave', address('cave_target'), '\144')
	check(mr.type(cave) == 'pointer' and mr.eq(b:cave('own_cave', address('cave_target'), '\144'), cave), 'a cave and the same cave again return one pointer')
	ok, why = b:cave('own_cave', address('cave_target'), '\144\144')
	check(ok == nil and why == 'the name is already used for a different change', 'the same cave name with other bytes is refused')
	ok, why = a:cave('other_cave', address('cave_target'), '\144')
	check(
		ok == nil and (why == 'held by claim_b/own_cave' or contains(why, 'already holds a code cave')),
		'a second owner cannot cave the same address: ' .. tostring(why)
	)
	check(select(2, b:remove('own_cave')) == 'stays for the session', 'a cave stays for the session')

	local frame = address('frame_target')
	check(a:frame('planner', frame, 0x360) == true and a:frame('planner', frame, 0x360) == true, 'a frame grows once and the same name again is a no-op')
	ok, why = b:frame('stolen', frame, 0x360)
	check(ok == nil and why == 'held by claim_a/planner', 'another owner cannot claim a grown function')
	ok, why = a:frame('bad_amount', frame, 15)
	check(ok == nil and contains(why, 'multiple of 16'), 'a bad amount is refused with the reason')
	ok, why = a:frame('elsewhere', mr.alloc(16), 0x40)
	check(ok == nil and why == "address is outside the game's exe", 'a frame outside the exe is refused')
	check(select(2, a:remove('planner')) == 'stays for the session', 'a frame stays for the session')

	local under = address('prologue_target')
	check(a:patch('under_hook', mr.add(under, 5), ONE4, TWO4) == true, 'an owned patch inside a function prologue')
	mr.hook(under, 'int32()', function()
		return mr.hook_next(under)
	end)
	check(a:info('under_hook').state == 'copied', 'a hook installed later copies the patch, so the state says copied')
	ok, why = a:remove('under_hook')
	check(
		ok == nil and contains(why, 'refused: the first bytes of a hooked function'),
		'remove refuses a patch that now runs from a hook copy: ' .. tostring(why)
	)
	check(mr.tonumber(mr.call(under, 'int32()')) == 2 and a:info('under_hook') ~= nil, 'the patch still runs and stays listed')
	local field_function = address('patch_target')
	check(a:set('under_field', mr.add(field_function, 1), 4, 2, 0, 10) == true, 'an owned value inside a function prologue')
	mr.hook(field_function, 'int32()', function()
		return mr.hook_next(field_function)
	end)
	ok, why = a:set('under_field', mr.add(field_function, 1), 4, 3, 0, 10)
	check(ok == nil and contains(why, 'refused: the first bytes of a hooked function'), 'set refuses a new number under a hook: ' .. tostring(why))
	check(mr.tonumber(mr.call(field_function, 'int32()')) == 2, 'and the value is unchanged')
	local single = address('site_single_here')
	local single_byte = mr.read(single, 0, 1)
	check(a:patch('hold_site', single, single_byte, single_byte) == true, 'a patch with equal bytes claims the start of a site')
	ok, why = b:site('over_claim', single, function() end)
	check(
		ok == nil and why == 'held by claim_a/hold_site' and mr.hook_info(single) == nil,
		'a site over a claimed range is refused and hooks nothing: ' .. tostring(why)
	)

	check(mr.grow_frame(address('frame_twin'), 0x20) == true, 'a raw grow_frame still grows')
	ok, why = a:frame('adopt', address('frame_twin'), 0x20)
	check(ok == nil and why == 'grown by 32 already', 'a frame grown by a raw call is not adopted: ' .. tostring(why))
	ok, why = a:frame('planner', frame, 0x380)
	check(ok == nil and why == 'the name is already used for a different change', 'the same frame name with another amount is refused')
	local xmm = address('frame_xmm_target')
	local head = mr.read(xmm, 0, 16)
	check(b:patch('frame_head', xmm, head, head) == true, 'a patch with equal bytes claims the start of a function')
	ok, why = a:frame('blocked', xmm, 0x360)
	check(
		ok == nil and why == 'held by claim_b/frame_head' and mr.read(xmm, 0, 16) == head,
		'a frame is refused over another owner claim and writes nothing: ' .. tostring(why)
	)
	local pointer = address('frame_pointer_target')
	check(a:frame('claims_back', pointer, 0x100) == true, 'a frame grows a function with no claims in it')
	local grown_head = mr.read(pointer, 0, 16)
	ok, why = b:patch('after_frame', pointer, grown_head, grown_head)
	check(ok == nil and why == 'held by claim_a/claims_back', 'the bytes a frame rewrote are claimed by it: ' .. tostring(why))

	local hits = 0
	local here = address('site_target_here')
	local function call_target()
		mr.call(address('site_target'), 'int32(int32, int32)', 3, 4)
	end
	check(a:site('s1', here, function()
		hits = hits + 1
	end) == true, 'an owned site attaches')
	call_target()
	check(hits == 1, 'the site callback runs')
	check(a:site('s1', here, function()
		hits = hits + 10
	end) == true and mr.hook_info(here).callbacks == 1, 'the same name replaces the callback')
	hits = 0
	call_target()
	check(hits == 10, 'only the new callback runs')
	check(b:site('s2', here, function()
		hits = hits + 100
	end) == true and mr.hook_info(here).callbacks == 2, 'two owners share a site')
	hits = 0
	call_target()
	check(hits == 110, 'both callbacks run')
	check(a:remove('s1') == true and mr.hook_info(here).callbacks == 1, 'remove detaches only that link')
	hits = 0
	call_target()
	check(hits == 100 and a:info('s1') == nil, 'the other owner keeps its link and the item is gone')
	ok, why = b:site('s2', address('site_single_here'), function() end)
	check(ok == nil and why == 'the name is already used for a different change', 'a site name cannot move to another address')
	ok, why = b:site('s3', here, function() end, 5000)
	check(ok == nil and contains(why, 'priority'), 'a priority out of range is refused')
	check(b:site('s3', here, function() end, 5) == true, 'a priority in range is accepted')
	check(select(2, b:site('s4', nil, function() end)) == 'address is NULL', 'a NULL site is refused')

	check(b:remove_all() == true, 'remove_all succeeds')
	local summary = { b:remove_all() }
	check(
		summary[1] == true and summary[2] == 0 and summary[3] == 1,
		'a second remove_all removes nothing and counts what stays: ' .. tostring(summary[2]) .. ', ' .. tostring(summary[3])
	)
	check(#mr.patch_list('claim_b') == 1 and mr.patch_list('claim_b')[1].name == 'own_cave', 'only the cave of claim_b is left')

	local owners = 3
	for i = 1, 300 do
		if mr.patcher('limit_' .. i) then owners = owners + 1 end
	end
	check(owners == 256, 'at most 256 owners are accepted: ' .. owners)
	check(select(2, mr.patcher('one_more')) == 'at most 256 owners per game session', 'the 257th owner is refused with the reason')
	check(mr.patcher('claim_a') == a, 'an owner that exists still gets its handle')
	local last_owner = mr.patcher('limit_253')
	check(
		last_owner:set('last_owner', at(0x9300), 1, 1, 0, 255) == true and last_owner:info('last_owner').owner == 'limit_253',
		'the 256th owner makes a change under its own name'
	)
	check(last_owner:remove('last_owner') == true and mr.capacity().owners.used == 256, 'and the owner table says 256 of 256')

	local FIELDS = 0x10000
	local existing = #mr.patch_list()
	local made = 0
	while a:set('field_' .. made, at(FIELDS + made), 1, 1, 0, 255) == true do
		made = made + 1
	end
	check(made + existing == 8192, 'at most 8192 items are accepted: ' .. made .. ' new, ' .. existing .. ' before')
	check(select(2, a:set('field_over', at(0x30000), 1, 1, 0, 255)) == 'full', 'the item after that is refused as full')
	check(bytes_at(0x30000, 1) == '\0', 'and writes nothing')
	local items = mr.capacity().items
	check(items.used == 8192 and items.room == 8192 and items.limit == 8192, 'the item table says 8192 of 8192')
	local intact = true
	for i = 0, made - 1 do
		local edge = i % 256 < 2 or i % 256 > 253 or i % 61 == 0
		if edge then
			local row = a:info('field_' .. i)
			intact = intact and row ~= nil and row.state == 'ours' and row.kind == 'value' and bytes_at(FIELDS + i, 1) == '\1'
		end
	end
	check(intact, 'items on both sides of every chunk edge keep their names, states and bytes')
	local listed = 0
	for _, row in ipairs(mr.patch_list('claim_a')) do
		if row.name:sub(1, 6) == 'field_' then listed = listed + 1 end
	end
	check(listed == made, 'patch_list shows every one of them: ' .. listed)
	check(a:remove('field_300') == true and a:set('field_again', at(0x30000), 1, 2, 0, 255) == true, 'a removed item frees a slot the next one takes')
	check(a:info('field_again').state == 'ours' and bytes_at(0x30000, 1) == '\2', 'and the new item works')
	a:remove('field_again')
	for i = 0, made - 1 do
		a:remove('field_' .. i)
	end
	check(#mr.patch_list() == existing and bytes_at(FIELDS + 5000, 1) == '\0', 'removing them frees the slots and puts the bytes back')

	local WAVES = 0x40000
	local function site_list(base, count)
		local list = {}
		for i = 1, count do
			list[i] = { at(base + i * 4), Z4, ONE4 }
		end
		return list
	end
	local waves = 0
	while a:relocate('wave_' .. (waves + 1), site_list(WAVES + waves * 0x1000, 1000)) == true do
		waves = waves + 1
	end
	local used = mr.capacity().claims.used
	check(waves >= 32 and used > 32768 - 1000 and used <= 32768, 'relocations of 1000 sites fill the claim table: ' .. waves .. ' waves, ' .. used)
	local rest = 32768 - used
	check(a:relocate('wave_rest', site_list(WAVES + waves * 0x1000, rest)) == true, 'the last ' .. rest .. ' claims fit')
	local claims = mr.capacity().claims
	check(claims.used == 32768 and claims.room == 32768 and claims.limit == 32768, 'the claim table says 32768 of 32768')
	local over = WAVES + (waves + 1) * 0x1000
	ok, why = a:relocate('wave_over', site_list(over, 1))
	check(ok == nil and why == 'full', 'the claim after that is refused as full: ' .. tostring(why))
	check(bytes_at(over + 4, 4) == Z4, 'and nothing of the refused relocation was written')
	check(bytes_at(WAVES + 4, 4) == ONE4 and bytes_at(WAVES + (waves - 1) * 0x1000 + 4000, 4) == ONE4, 'the first and the last wave hold their bytes')
	check(
		select(2, a:relocate('wave_1', site_list(WAVES, 999))) == 'the name is already used for a different change',
		'a relocation name with other sites is refused'
	)
	check(a:relocate('wave_1', site_list(WAVES, 1000)) == true, 'the same relocation again is a no-op')
	check(select(2, a:relocate('too_many', site_list(0x9000, 1025))) == 'at most 1024 sites', 'more than 1024 sites are refused')
	check(select(2, a:relocate('none', {})) == 'no sites', 'no sites are refused')
	ok, why = a:relocate('overlap_sites', { { at(0x9100), Z4, ONE4 }, { at(0x9102), Z4, ONE4 } })
	check(ok == nil and why == 'sites 1 and 2 overlap', 'overlapping sites in one call are refused')
	ok, why = a:relocate('broken', { { at(0x9200), Z4, ONE4 }, 5 })
	check(ok == nil and why == 'site 2: is not a table {address, expected, bytes}', 'a site that is not a table is refused')
elseif SCENARIO == 'held_bytes' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local FULL_LINE = 'saved original code is full'
	local function address(name)
		return mr.pointer(test_function(name))
	end
	local function log_has(part)
		local log = io.open('memreader_plus_refused.txt', 'rb')
		local text = log and log:read('*a') or ''
		if log then log:close() end
		return string.find(text, part, 1, true) ~= nil
	end
	local filler = address('filler_code')
	local zeros, nops = string.rep('\0', 4096), string.rep('\144', 4096)
	local chunk = 0
	while chunk < 130 or (not log_has(FULL_LINE) and chunk < 272) do
		mr.patch(mr.add(filler, chunk * 4096), zeros, nops)
		chunk = chunk + 1
	end
	check(log_has(FULL_LINE) and chunk >= 130, 'raw patches of 4096 bytes fill the saved original table: ' .. chunk)
	local p = mr.patcher('hold_mod')
	local site = address('patch_target')
	check(mr.read(site, 0, 5) == '\184\1\0\0\0', 'patch_target holds mov eax, 1')
	check(p:patch('hold', site, '\184\1\0\0\0', '\184\2\0\0\0') == true, 'an owned patch works with the table full')
	check(mr.read_original(site, 0, 5) == '\184\2\0\0\0', 'read_original no longer has the original bytes')
	check(mr.tonumber(mr.call(site, 'int32()')) == 2, 'the function returns 2 while patched')
	check(p:remove('hold') == true, 'remove works')
	check(mr.read(site, 0, 5) == '\184\1\0\0\0' and mr.tonumber(mr.call(site, 'int32()')) == 1, 'and puts the held bytes back, not the lost originals')
	check(#mr.patch_list('hold_mod') == 0, 'the item is gone')

	local made = 0
	local function big(index)
		return p:patch('big_' .. index, mr.add(filler, index * 4096), nops, zeros)
	end
	check(p:patch('early', site, '\184\1\0\0\0', '\184\3\0\0\0') == true, 'a small patch made while the held bytes are small')
	check(mr.capacity().held_bytes.room == 64 * 1024, 'the held bytes start at 64 KB')
	for index = 0, 126 do
		if big(index) == true then made = made + 1 end
	end
	check(made == 127, '127 patches of 4096 bytes fit next to it: ' .. made)
	local held = mr.capacity().held_bytes
	check(
		held.room == 1024 * 1024 and held.limit == 1024 * 1024 and held.used == 127 * 8192 + 10,
		'the held bytes grew to 1 MB: ' .. held.used .. ' of ' .. held.room
	)
	check(mr.tonumber(mr.call(site, 'int32()')) == 3 and p:remove('early') == true, 'the early patch still runs and is removed after the growth')
	check(mr.read(site, 0, 5) == '\184\1\0\0\0' and mr.tonumber(mr.call(site, 'int32()')) == 1, 'and its held bytes put the original back')
	check(big(127) == true, 'its freed bytes take the 128th patch of 4096 bytes')
	local ok, why = big(128)
	check(ok == nil and why == 'full', 'the 129th is refused as full: ' .. tostring(why))
	check(mr.read(mr.add(filler, 128 * 4096), 0, 4096) == nops, 'and writes nothing')
	check(p:remove('big_0') == true and mr.read(filler, 0, 4096) == nops, 'removing the first one frees its bytes and restores it')
	local kept = true
	for index = 1, 127 do
		kept = kept and mr.read(mr.add(filler, index * 4096), 0, 4096) == zeros
	end
	check(kept, 'the other 127 keep their patches after the held bytes moved down')
	check(big(128) == true, 'the freed bytes take the 129th patch')
	check(p:remove('big_64') == true and mr.read(mr.add(filler, 64 * 4096), 0, 4096) == nops, 'a middle one is restored from its own held bytes')
	local fields = p:set('field', mr.add(filler, 129 * 4096 + 100), 1, 3, 0, 255)
	check(fields == true and mr.read(mr.add(filler, 129 * 4096 + 100), 0, 1) == '\3', 'a value fits in the freed bytes')
	check(p:relocate('moved', { { mr.add(filler, 129 * 4096 + 200), '\144\144\144\144', '\1\1\1\1' } }) == true, 'so does a relocation')
	local info = { p:remove_all() }
	check(
		info[1] == true and info[2] == 128 and info[3] == 1,
		'remove_all restores every patch and value and counts the relocation: ' .. tostring(info[2]) .. ', ' .. tostring(info[3])
	)
	local back = true
	for index = 0, 128 do
		back = back and mr.read(mr.add(filler, index * 4096), 0, 4096) == nops
	end
	check(back, 'every chunk is back to its original bytes')
	check(
		mr.read(mr.add(filler, 129 * 4096 + 100), 0, 1) == '\144' and mr.read(mr.add(filler, 129 * 4096 + 200), 0, 4) == '\1\1\1\1',
		'the value is back and the relocation stays'
	)
	check(mr.capacity().held_bytes.used == 8, 'only the relocation holds bytes now')
elseif SCENARIO == 'batch' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local function address(name)
		return mr.pointer(test_function(name))
	end
	local function contains(text, part)
		return type(text) == 'string' and string.find(text, part, 1, true) ~= nil
	end
	local cell = mr.alloc(8)
	local function raw(pointer)
		mr.write(cell, 0, pointer)
		return mr.read(cell, 0, 8)
	end
	local filler = address('filler_code')
	check(mr.tostring(filler):sub(-3) == '000', 'the filler starts on a page, so a failing protect call hits the page a test names: ' .. mr.tostring(filler))
	local function at(offset)
		return mr.add(filler, offset)
	end
	local Z4, ONE4, TWO4 = '\0\0\0\0', '\1\0\0\0', '\2\0\0\0'
	local function bytes_at(offset, size)
		return mr.read(at(offset), 0, size)
	end
	local function number_at(offset)
		return mr.read_int32(at(offset), 0)
	end
	local function rows(owner)
		local found = {}
		for _, row in ipairs(mr.patch_list(owner)) do
			found[row.name] = row
		end
		return found
	end
	local function microseconds()
		return test_microseconds()
	end
	local function elapsed(since)
		return (test_microseconds() - since) % 1e7
	end
	local p, q = mr.patcher('batch_mod'), mr.patcher('batch_other')
	check(type(p.batch) == 'function', 'a handle has batch')
	check(p:owner() == 'batch_mod' and q:owner() == 'batch_other', 'a handle names its owner')

	local nops, zeros = string.rep('\144', 4096), string.rep('\0', 4096)
	local big = {}
	for chunk = 0, 128 do
		big[#big + 1] = { 'patch', 'big_' .. chunk, at(chunk * 4096), zeros, nops }
	end
	local ok, why, stays = p:batch(big)
	check(
		ok == nil and why == 'big_128: the batch writes too many bytes' and stays == nil,
		'129 patches of 4096 bytes are more than one batch writes: ' .. tostring(why)
	)
	check(bytes_at(0, 4096) == zeros and bytes_at(128 * 4096, 4096) == zeros and #mr.patch_list('batch_mod') == 0, 'and nothing is written or registered')
	big[129] = nil
	check(q:patch('small', at(130 * 4096), Z4, ONE4) == true, 'another owner holds a few bytes')
	ok, why = p:batch(big)
	check(ok == nil and why == 'full', '128 patches of 4096 bytes then need more held bytes than the registry has: ' .. tostring(why))
	check(bytes_at(0, 4096) == zeros and bytes_at(127 * 4096, 4096) == zeros and #mr.patch_list('batch_mod') == 0, 'and nothing is written or registered')
	check(q:remove('small') == true, 'the other owner lets go')
	test_watch_window(mr.hop_slots)
	local done, stopped = p:batch(big)
	check(done == true and bytes_at(127 * 4096, 4096) == nops, '128 of them fit in one batch, 512 KB of writes')
	local allocations, suspends = test_window_counts()
	check(
		suspends >= 1 and allocations == 0,
		'nothing is allocated while the threads are stopped: ' .. allocations .. ' allocations, ' .. suspends .. ' threads stopped'
	)
	print(string.format('  batch of 128 patches of 4096 bytes: threads stopped %.0f us', stopped))
	check(p:remove_all() == true and bytes_at(0, 4096) == zeros and bytes_at(127 * 4096, 4096) == zeros, 'and remove_all puts every chunk back')
	for i = 1, 250 do
		q:set('pad_' .. i, at(0x60000 + i), 1, 0, 0, 255)
	end
	local edge_steps = {}
	for i = 1, 20 do
		edge_steps[i] = { 'set', 'edge_' .. i, at(0x61000 + i * 4), 4, 7, 0, 100 }
	end
	local room_before = mr.capacity().items.room
	test_watch_window(mr.hop_slots)
	check(p:batch(edge_steps) == true and mr.capacity().items.room > room_before, 'a batch whose items cross a chunk edge gets the chunk while it plans')
	allocations, suspends = test_window_counts()
	check(suspends >= 1 and allocations == 0, 'and allocates nothing while the threads are stopped: ' .. allocations)
	check(p:remove_all() == true and q:remove_all() == true, 'both owners remove everything')

	local good = {
		{ 'patch', 'first', at(0x100), Z4, ONE4 },
		{ 'set', 'cap', at(0x200), 4, 7, 0, 100 },
		{ 'relocate', 'moved', { { at(0x300), Z4, ONE4 }, { at(0x310), Z4, TWO4 } } },
		{ 'frame', 'plan', address('frame_target'), 0x360 },
	}
	ok, why, stays = p:batch(good)
	check(ok == true and stays == nil, 'a batch of a patch, a value, a relocation and a frame succeeds')
	check(type(why) == 'number' and why > 0 and why < 1000000, 'and reports how long the other threads were stopped: ' .. tostring(why) .. ' us')
	check(
		bytes_at(0x100, 4) == ONE4 and number_at(0x200) == 7 and bytes_at(0x300, 4) == ONE4 and bytes_at(0x310, 4) == TWO4,
		'every patch, value and relocation is written'
	)
	local listed = rows('batch_mod')
	check(
		listed.first.kind == 'patch' and listed.cap.kind == 'value' and listed.moved.kind == 'relocate' and listed.plan.kind == 'frame',
		'every step is owned under its kind'
	)
	check(listed.first.state == 'ours' and listed.cap.state == 'ours' and listed.moved.state == 'stays' and listed.plan.state == 'stays', 'with its state')
	check(mr.read_original(at(0x100), 0, 4) == Z4, 'read_original has the old bytes')
	check(p:batch(good) == true and #mr.patch_list('batch_mod') == 4, 'the same batch again is a no-op')
	check(p:batch({ { 'set', 'cap', at(0x200), 4, 9, 0, 100 } }) == true and number_at(0x200) == 9, 'a value in a batch can take another number')
	check(p:remove('first') == true and bytes_at(0x100, 4) == Z4, 'remove puts back the held bytes of a batch patch')
	check(p:remove('cap') == true and number_at(0x200) == 0, 'and of a batch value')
	check(p:batch({ good[1] }) == true and bytes_at(0x100, 4) == ONE4 and p:remove('first') == true, 'a removed patch can be batched again')

	q:patch('theirs', at(0x700), Z4, ONE4)
	local xmm = address('frame_xmm_target')
	local xmm_head = mr.read(xmm, 0, 16)
	q:patch('xmm_head', xmm, xmm_head, xmm_head)
	local pointer = address('frame_pointer_target')
	local pointer_head = mr.read(pointer, 0, 16)
	local before = #mr.patch_list()
	local head = { { 'patch', 'r_patch', at(0x400), Z4, ONE4 }, { 'set', 'r_set', at(0x500), 4, 5, 0, 100 } }
	local function with(step)
		return { head[1], head[2], step }
	end
	local function refused(list, part, label)
		local failed, reason, left = p:batch(list)
		check(failed == nil and contains(reason, part) and left == nil, label .. ': ' .. tostring(reason))
		check(bytes_at(0x400, 4) == Z4 and number_at(0x500) == 0 and bytes_at(0x600, 4) == Z4, label .. ': nothing is written')
		check(#mr.patch_list() == before, label .. ': nothing is registered')
	end
	refused(
		with({ 'relocate', 'r_sites', { { at(0x600), Z4, ONE4 }, { at(0x610), ONE4, TWO4 } } }),
		'r_sites: site 2: does not hold the expected bytes',
		'a wrong expected byte in the last step'
	)
	refused(with({ 'patch', 'r_claimed', at(0x702), Z4, TWO4 }), 'r_claimed: held by batch_other/theirs', 'a range held by another owner')
	refused(with({ 'patch', 'r_wrong', at(0x600), ONE4, TWO4 }), 'r_wrong: unexpected bytes', 'wrong expected bytes')
	refused(with({ 'set', 'r_range', at(0x600), 4, 500, 0, 100 }), 'r_range: number must lie between low and high', 'a number outside its range')
	refused(with({ 'patch', 'r_twin', at(0x402), Z4, TWO4 }), 'r_twin: overlaps r_patch in this batch', 'two steps over the same bytes')
	refused(
		with({ 'relocate', 'r_sites', { { at(0x502), Z4, ONE4 }, { at(0x600), Z4, ONE4 } } }),
		'r_sites: site 1: overlaps r_set in this batch',
		'a relocation site over another step'
	)
	refused(with({ 'frame', 'blocked', xmm, 0x360 }), 'blocked: held by batch_other/xmm_head', 'a frame over a claim')
	check(mr.read(xmm, 0, 16) == xmm_head, 'the function of the refused frame is untouched')
	refused(
		{ head[1], { 'patch', 'p_head', pointer, pointer_head, pointer_head }, { 'frame', 'p_frame', pointer, 0x100 } },
		'p_frame: overlaps p_head in this batch',
		'a frame over a patch of the same batch'
	)
	check(p:frame('later', pointer, 0x100) == true, 'the function was not grown by the refused batch')
	before = #mr.patch_list()
	refused(with({ 'cave', 'bad_cave', address('site_ret_here'), '\144' }), 'refused: a return or jump', 'a cave the site rules refuse')
	check(mr.hook_info(address('site_ret_here')) == nil, 'and no hook is left')
	refused(with({ 'patch', 'r_patch', at(0x600), Z4, ONE4 }), 'step 3: the name is used twice in this batch', 'the same name twice')
	refused({ { 'poke', 'x' } }, 'step 1: unknown kind', 'an unknown kind')
	refused({ 5 }, 'step 1: needs a table', 'a step that is not a table')
	refused({ { 'patch', 'long', 1, 2, 3, 4, 5, 6 } }, 'step 1: has too many fields', 'a step with too many fields')
	refused({ { 'patch', 'bad name', at(0x600), Z4, ONE4 } }, 'step 1: name must be 1 to 47 letters, digits or underscores', 'a bad name')
	refused({}, 'no steps', 'an empty list')
	local many = {}
	for i = 1, 1025 do
		many[i] = { 'set', 'many_' .. i, at(0x600), 4, 1, 0, 9 }
	end
	refused(many, 'at most 1024 steps', 'too many steps')
	check(
		not pcall(p.batch, p, 'steps') and not pcall(p.batch, p, { { 'patch', 'short' } }) and not pcall(p.batch, { { 'patch', 'x' } }),
		'a wrong argument type raises'
	)

	local function write_list(prefix)
		return {
			{ 'patch', prefix .. 'a', at(0x1000), Z4, ONE4 },
			{ 'set', prefix .. 'b', at(0x2000), 4, 9, 0, 100 },
			{ 'patch', prefix .. 'c', at(0x3000), Z4, TWO4 },
			{ 'relocate', prefix .. 'd', { { at(0x4000), Z4, ONE4 }, { at(0x4010), Z4, ONE4 } } },
		}
	end
	local function untouched(label)
		check(
			bytes_at(0x1000, 4) == Z4 and number_at(0x2000) == 0 and bytes_at(0x3000, 4) == Z4 and bytes_at(0x4000, 4) == Z4 and bytes_at(0x4010, 4) == Z4,
			label .. ': no patch, value or relocation of the batch is left'
		)
		check(#mr.patch_list() == before, label .. ': nothing is registered')
	end
	test_fail_protect(raw(at(0x3000)), 1, mr.hop_slots)
	ok, why, stays = p:batch(write_list('w_'))
	check(
		ok == nil and why == 'w_c: failed to patch memory, nothing of the batch was written' and stays == nil,
		'a write that fails in the third step: ' .. tostring(why)
	)
	untouched('the third write fails')
	test_fail_protect(raw(at(0x1000)), 1, mr.hop_slots)
	ok, why = p:batch(write_list('w_'))
	check(ok == nil and why == 'w_a: failed to patch memory, nothing of the batch was written', 'a write that fails first: ' .. tostring(why))
	untouched('the first write fails')
	test_fail_protect(raw(at(0x4010)), 1, mr.hop_slots)
	ok, why = p:batch(write_list('w_'))
	check(ok == nil and why == 'w_d: failed to patch memory, nothing of the batch was written', 'a write that fails last: ' .. tostring(why))
	untouched('the last write fails')
	local pair = { { 'patch', 'pb_a', at(0x9000), Z4, ONE4 }, { 'patch', 'pb_b', at(0xA100), Z4, TWO4 } }
	local listed_before = #mr.patch_list()
	test_relock(raw(at(0xA100)), mr.hop_slots, raw(at(0x9000)))
	local faults_before = test_access_faults()
	ok, why, stays = p:batch(pair)
	check(test_access_faults() == faults_before + 2, 'the write the lie let through and its put back fault once each: ' .. test_access_faults() - faults_before)
	check(
		ok == nil and why == 'pb_b: failed to patch memory, and 1 write could not be put back' and stays == nil,
		'a write that cannot be put back is counted, and one that never changed is not: ' .. tostring(why)
	)
	check(bytes_at(0x9000, 4) == ONE4 and bytes_at(0xA100, 4) == Z4, 'the first write is still in the code, the second was refused')
	check(
		test_protection(raw(at(0x9000))) == 0x20 and test_protection(raw(at(0xA100))) == 0x20,
		'both pages are back to their protection after a write and a put back failed in the window'
	)
	listed = rows('batch_mod')
	check(
		listed.pb_a ~= nil and listed.pb_a.state == 'stays' and listed.pb_b == nil and #mr.patch_list() == listed_before + 1,
		'the write that stays is registered as staying, so a report names it'
	)
	check(listed.pb_a.kind == 'patch', 'and under the kind of its step')
	local value_pair = { { 'set', 'pv_a', at(0x9040), 4, 5, 0, 100 }, { 'patch', 'pv_b', at(0xA140), Z4, TWO4 } }
	test_relock(raw(at(0xA140)), mr.hop_slots, raw(at(0x9040)))
	ok, why = p:batch(value_pair)
	check(ok == nil and why == 'pv_b: failed to patch memory, and 1 write could not be put back', 'the same with a value first: ' .. tostring(why))
	listed = rows('batch_mod')
	check(listed.pv_a ~= nil and listed.pv_a.kind == 'value' and listed.pv_a.state == 'stays', 'a value that stays is listed as a value')
	check(p:batch(write_list('w_')) == true and bytes_at(0x3000, 4) == TWO4 and bytes_at(0x4010, 4) == ONE4, 'after the failures the same batch goes through')
	check(rows('batch_mod').w_a.state == 'ours' and rows('batch_mod').w_d.state == 'stays', 'and is owned')

	local kind_mod = mr.patcher('kind_mod')
	test_relock(raw(at(0xB900)), mr.hop_slots, raw(at(0x7800)))
	ok, why = kind_mod:batch({ { 'patch', 'kp_a', at(0x7800), Z4, ONE4 }, { 'patch', 'kp_b', at(0xB900), Z4, TWO4 } })
	check(ok == nil and contains(why, 'could not be put back'), 'a patch that stays after a failed put back: ' .. tostring(why))
	test_relock(raw(at(0xBB00)), mr.hop_slots, raw(at(0x7A00)))
	ok, why = kind_mod:batch({ { 'set', 'kv_a', at(0x7A00), 4, 5, 0, 100 }, { 'patch', 'kp_c', at(0xBB00), Z4, TWO4 } })
	check(ok == nil and contains(why, 'could not be put back'), 'and a value that stays: ' .. tostring(why))
	ok, why = kind_mod:relocate('kp_a', { { at(0x7800), Z4, ONE4 } })
	check(
		ok == nil and why == 'the name is already used for a different change',
		'asking for a leftover patch as a relocation is a different change, not a read of the held bytes: ' .. tostring(why)
	)
	local report_name = mr.write_runtime_report()
	local report_text = type(report_name) == 'string' and read_all(report_name) or ''
	check(has(report_text, '  kind_mod: 1 value, 1 patch (kp_a '), 'the owner block counts a leftover patch and value under their kinds')
	local kind_line = report_text:match('  kind_mod:[^\n]*') or ''
	check(kind_line ~= '' and not has(kind_line, 'relocation'), 'and not as a relocation: ' .. kind_line)

	local function protection_of(offset)
		return test_protection(raw(at(offset)))
	end
	local function protections(offsets)
		local list = {}
		for i, offset in ipairs(offsets) do
			list[i] = string.format('%X', protection_of(offset))
		end
		return table.concat(list, ' ')
	end
	local function all_read_execute(count)
		local list = {}
		for i = 1, count do
			list[i] = '20'
		end
		return table.concat(list, ' ')
	end
	local guarded = mr.patcher('protect_mod')
	local spread_offsets, spread_sites = {}, {}
	for i = 0, 47 do
		spread_offsets[#spread_offsets + 1] = 0xC1000 + i * 0x1000 + i * 16
		spread_sites[#spread_sites + 1] = { at(spread_offsets[#spread_offsets]), '\0', '\1' }
	end
	check(protections(spread_offsets) == all_read_execute(48), 'the 48 pages start as PAGE_EXECUTE_READ')
	test_count_protect(raw(at(spread_offsets[5])), mr.hop_slots)
	test_watch_window(mr.hop_slots)
	ok, why = guarded:batch({ { 'relocate', 'spread', spread_sites } })
	local spread_allocations = test_window_counts()
	local spread_written = true
	for _, offset in ipairs(spread_offsets) do
		spread_written = spread_written and bytes_at(offset, 1) == '\1'
	end
	check(ok == true and spread_written, 'a batch of 48 one-byte writes on 48 pages goes through: ' .. tostring(why))
	check(protections(spread_offsets) == all_read_execute(48), 'every page is back to PAGE_EXECUTE_READ: ' .. protections(spread_offsets))
	check(test_protect_count() == 2, 'a page gets one protection change before the freeze and one after: ' .. test_protect_count())
	check(spread_allocations == 0, 'nothing is allocated while the threads are stopped')
	print(('  batch of 48 writes on 48 pages: threads stopped %.0f us'):format(why))

	local shared_sites = {}
	for i = 0, 7 do
		shared_sites[#shared_sites + 1] = { at(0xF1000 + i * 0x40), '\0', '\1' }
	end
	test_count_protect(raw(at(0xF1000)), mr.hop_slots)
	ok, why = guarded:batch({
		{ 'relocate', 'shared', shared_sites },
		{ 'patch', 'shared_patch', at(0xF1800), Z4, ONE4 },
		{ 'set', 'shared_value', at(0xF1900), 4, 7, 0, 100 },
	})
	check(
		ok == true and bytes_at(0xF11C0, 1) == '\1' and bytes_at(0xF1800, 4) == ONE4 and number_at(0xF1900) == 7,
		'ten writes on one page go through: ' .. tostring(why)
	)
	check(test_protect_count() == 2 and protection_of(0xF1000) == 0x20, 'the page is unlocked once and put back once: ' .. test_protect_count() .. ' calls')

	test_watch_suspend(mr.hop_slots, raw(at(0xF2000)))
	test_change_on_suspend(raw(at(0xF3000)), TWO4)
	ok, why = guarded:batch({ { 'patch', 'mm_a', at(0xF2000), Z4, ONE4 }, { 'patch', 'mm_b', at(0xF3000), Z4, ONE4 } })
	local _, at_first_stop = test_suspend_calls()
	check(at_first_stop == 0x40 or at_first_stop == 0x80, ('a page is writable and executable when the first thread is stopped: %X'):format(at_first_stop))
	check(ok == nil and why == 'mm_b: unexpected bytes', 'bytes changed after the pages were unlocked refuse the batch inside the window: ' .. tostring(why))
	check(bytes_at(0xF2000, 4) == Z4 and bytes_at(0xF3000, 4) == TWO4, 'and nothing of the batch was written')
	check(protections({ 0xF2000, 0xF3000 }) == '20 20', 'both pages are back to PAGE_EXECUTE_READ: ' .. protections({ 0xF2000, 0xF3000 }))

	local partway = { 0xF4000, 0xF5000, 0xF6000, 0xF7000 }
	local partway_steps = {}
	for i, offset in ipairs(partway) do
		partway_steps[i] = { 'patch', 'pw_' .. i, at(offset), Z4, ONE4 }
	end
	test_watch_suspend(mr.hop_slots)
	test_fail_protect(raw(at(0xF6000)), 1, mr.hop_slots)
	ok, why = guarded:batch(partway_steps)
	check(
		ok == nil and why == 'pw_3: failed to patch memory, nothing of the batch was written',
		'a protection change that fails on the third page: ' .. tostring(why)
	)
	check(test_suspend_calls() == 0, 'refuses before any thread is stopped')
	check(protections(partway) == '20 20 20 20', 'the two pages already unlocked are put back: ' .. protections(partway))
	check(bytes_at(0xF4000, 4) == Z4 and bytes_at(0xF6000, 4) == Z4 and bytes_at(0xF7000, 4) == Z4, 'and nothing is written')
	ok = guarded:batch(partway_steps)
	check(ok == true and bytes_at(0xF7000, 4) == ONE4 and protections(partway) == '20 20 20 20', 'the same batch goes through afterwards')

	local kinds_of_page = { 0x80, 0x04, 0x02, 0x40 }
	local batch_pages, twin_pages, set_as, kind_steps = {}, {}, {}, {}
	for i, protection in ipairs(kinds_of_page) do
		batch_pages[i] = 0xF8000 + (i - 1) * 0x1000
		twin_pages[i] = 0xFC000 + (i - 1) * 0x1000
		test_protect(raw(at(batch_pages[i])), 4096, protection)
		test_protect(raw(at(twin_pages[i])), 4096, protection)
		set_as[i] = string.format('%X', protection_of(batch_pages[i]))
		kind_steps[i] = { 'patch', 'kind_' .. i, at(batch_pages[i] + 0x10), Z4, ONE4 }
	end
	check(protections(batch_pages) == protections(twin_pages), 'the batch pages and their twins start alike: ' .. protections(batch_pages))
	print('  pages set as ' .. table.concat(set_as, ' ') .. ' (asked 80 4 2 40)')
	local kind_faults = test_access_faults()
	ok, why = guarded:batch(kind_steps)
	check(test_access_faults() == kind_faults, 'the copy-on-write copies are made without an access violation')
	for i = 1, #twin_pages do
		check(mr.patch(at(twin_pages[i] + 0x10), Z4, ONE4) == Z4, 'the twin page ' .. i .. ' takes the same write through the per-write path')
	end
	check(
		ok == true and bytes_at(0xF8010, 4) == ONE4 and bytes_at(0xFB010, 4) == ONE4,
		'a batch over pages that are not PAGE_EXECUTE_READ goes through: ' .. tostring(why)
	)
	check(
		protections(batch_pages) == protections(twin_pages),
		'each page ends with the protection the per-write path leaves: ' .. protections(batch_pages) .. ' and ' .. protections(twin_pages)
	)
	print('  after the writes: ' .. protections(batch_pages))
	local private_before = protections(batch_pages)
	for i = 1, #batch_pages do
		kind_steps[i] = { 'patch', 'kind_again_' .. i, at(batch_pages[i] + 0x20), Z4, TWO4 }
	end
	ok, why = guarded:batch(kind_steps)
	check(
		ok == true and bytes_at(0xF9020, 4) == TWO4 and protections(batch_pages) == private_before,
		'a second batch over the same pages, now private (PAGE_READWRITE and PAGE_EXECUTE_READWRITE among them), keeps them as they were: '
			.. protections(batch_pages)
	)
	for i = 1, #batch_pages do
		test_protect(raw(at(batch_pages[i])), 4096, 0x20)
		test_protect(raw(at(twin_pages[i])), 4096, 0x20)
	end

	local function plus_log()
		local file = io.open('memreader_plus_refused.txt', 'rb')
		local text = file and file:read('*a') or ''
		if file then file:close() end
		return text
	end
	test_relock(raw(at(0x101000)), mr.hop_slots)
	local relock_faults = test_access_faults()
	ok, why = guarded:batch({ { 'patch', 'rl_a', at(0x100000), Z4, ONE4 }, { 'patch', 'rl_b', at(0x101000), Z4, ONE4 } })
	check(test_access_faults() == relock_faults, 'the relocked page is found before any write, without a fault')
	check(
		contains(plus_log(), 'a batch left alone (another program changed their protection meanwhile) 1 page: the first, ')
			and contains(plus_log(), 'has protection 0x20, its original was 0x20'),
		'a page someone else set again in the gap is left as it is, with one log line'
	)
	check(
		ok == nil and why == 'rl_b: failed to patch memory, nothing of the batch was written',
		'a page made read-only again by someone else before the freeze refuses the batch inside the window: ' .. tostring(why)
	)
	check(bytes_at(0x100000, 4) == Z4 and bytes_at(0x101000, 4) == Z4, 'and nothing was written')
	check(protections({ 0x100000, 0x101000 }) == '20 20', 'both pages are PAGE_EXECUTE_READ: ' .. protections({ 0x100000, 0x101000 }))

	test_fail_restore(raw(at(0x105000)), mr.hop_slots)
	ok, why = guarded:batch({ { 'patch', 'kr_a', at(0x104000), Z4, ONE4 }, { 'patch', 'kr_b', at(0x105000), Z4, ONE4 } })
	check(
		ok == true and bytes_at(0x104000, 4) == ONE4 and bytes_at(0x105000, 4) == ONE4,
		'a batch whose page cannot be put back still writes: ' .. tostring(why)
	)
	check(
		protections({ 0x104000, 0x105000 }) == '20 40',
		'the other page is put back and that one keeps its unlocked protection: ' .. protections({ 0x104000, 0x105000 })
	)
	check(
		contains(plus_log(), 'a batch could not put back 1 page: the first, ') and contains(plus_log(), 'has protection 0x40, its original was 0x20'),
		'one log line names the page and the protection it kept'
	)
	test_protect(raw(at(0x105000)), 4096, 0x20)

	local cave_site = address('asm_site_f_here')
	local near_offset = 32
	if mr.tostring(mr.add(cave_site, near_offset)):sub(-8, -4) ~= mr.tostring(cave_site):sub(-8, -4) then near_offset = -32 end
	local near_cave = mr.add(cave_site, near_offset)
	local near_old = mr.read(near_cave, 0, 1)
	local near_new = string.char((near_old:byte() + 1) % 256)
	ok, why = guarded:batch({
		{ 'patch', 'mx_before', at(0x102000), Z4, ONE4 },
		{ 'cave', 'mx_cave', cave_site, '\144' },
		{ 'patch', 'mx_near', near_cave, near_old, near_new },
		{ 'set', 'mx_after', at(0x103000), 4, 9, 0, 100 },
	})
	check(ok == true, 'a batch of a cave and writes on its page and on others goes through: ' .. tostring(why))
	check(mr.hook_info(cave_site) and mr.hook_info(cave_site).kind == 'cave', 'the cave is hooked')
	check(mr.read(near_cave, 0, 1) == near_new and bytes_at(0x102000, 4) == ONE4 and number_at(0x103000) == 9, 'and every write is in place')
	check(
		test_protection(raw(cave_site)) == 0x20 and test_protection(raw(near_cave)) == 0x20 and protections({ 0x102000, 0x103000 }) == '20 20',
		'the cave page and the other pages are PAGE_EXECUTE_READ'
	)

	local caves = {
		{ 'patch', 'c_pre', at(0x5000), Z4, ONE4 },
		{ 'cave', 'cave_one', address('cave_target'), '\144' },
		{ 'cave', 'cave_two', address('hook_target'), '\144\144' },
		{ 'cave', 'cave_three', address('site_target_here'), '\144\144\144' },
		{ 'set', 'c_post', at(0x5100), 4, 3, 0, 100 },
	}
	test_fail_alloc(3 + 14, mr.hop_slots)
	ok, why, stays = p:batch(caves)
	check(ok == nil and contains(why, 'cave_three: no free memory for a cave at'), 'a cave that fails in the second phase: ' .. tostring(why))
	check(type(stays) == 'table' and #stays == 2 and stays[1] == 'cave_one' and stays[2] == 'cave_two', 'the caves it left are named')
	listed = rows('batch_mod')
	check(listed.cave_one.kind == 'cave' and listed.cave_one.state == 'stays' and listed.cave_one.owner == 'batch_mod', 'the first cave stays, owned and named')
	check(listed.cave_two.kind == 'cave' and listed.cave_two.state == 'stays' and listed.cave_three == nil, 'so does the second, the third was never made')
	check(mr.hook_info(address('cave_target')).kind == 'cave' and mr.hook_info(address('site_target_here')) == nil, 'the hooks agree')
	check(bytes_at(0x5000, 4) == Z4 and number_at(0x5100) == 0 and listed.c_pre == nil and listed.c_post == nil, 'no patch or value of the batch was written')
	ok, why, stays = p:batch(caves)
	check(ok == true and type(why) == 'number' and stays == nil, 'the same batch goes through: the made caves are kept, the third is made: ' .. tostring(why))
	check(bytes_at(0x5000, 4) == ONE4 and number_at(0x5100) == 3 and rows('batch_mod').cave_three.state == 'stays', 'and writes its patch and value')
	check(select(2, p:remove('cave_one')) == 'stays for the session', 'a cave of a batch stays for the session')

	local VALUE = 66051
	local function unit_list(prefix, origin, value, count)
		local list = {}
		for i = 0, count - 1 do
			list[#list + 1] = { 'set', prefix .. i, at(origin + 4 * i), 4, value, 0, 1000000 }
		end
		return list
	end
	local function median(values)
		table.sort(values)
		return values[math.ceil(#values / 2)]
	end
	local unit = 0x6000 + test_aligned_offset(raw(at(0x6000)), 64)
	local up, down = unit_list('fz', unit, VALUE, 4), unit_list('fz', unit, 0, 4)
	test_reader_start(raw(at(unit)))
	test_sleep(100)
	local idle_reads, idle_torn, idle_gap = test_reader_counts()
	check(
		idle_reads > 1000 and idle_torn == 0,
		'the reader thread reads the range with one 16 byte load: ' .. idle_reads .. ' reads while idle, longest gap ' .. idle_gap .. ' us'
	)
	local durations, going_up, loops, all_done = {}, true, 0, true
	local reads, torn, gap = 0, 0, 0
	repeat
		local started = microseconds()
		all_done = all_done and p:batch(going_up and up or down) == true
		durations[#durations + 1] = elapsed(started)
		going_up = not going_up
		loops = loops + 1
		reads, torn, gap = test_reader_counts()
	until (reads >= 1000000 and loops >= 100) or loops >= 3000
	reads, torn, gap = test_reader_stop()
	check(all_done, 'every batch of four values goes through')
	check(reads >= 1000000, 'the reader made ' .. reads .. ' reads while ' .. loops .. ' batches wrote four values each')
	check(torn == 0, 'no read saw a mix of old and new values: ' .. torn .. ' of ' .. reads)
	check(number_at(unit) == (going_up and 0 or VALUE) and number_at(unit + 12) == (going_up and 0 or VALUE), 'the values hold the last number')
	print(
		('  batch of four values: median %d us; the reader thread: %d reads, longest gap %d us (idle: %d us)'):format(median(durations), reads, gap, idle_gap)
	)

	local control = 0x6100 + test_aligned_offset(raw(at(0x6100)), 64)
	test_reader_start(raw(at(control)))
	local control_up, control_loops = true, 0
	repeat
		for i = 0, 3 do
			p:set('uf' .. i, at(control + 4 * i), 4, control_up and VALUE or 0, 0, 1000000)
		end
		control_up = not control_up
		control_loops = control_loops + 1
		reads, torn = test_reader_counts()
	until torn > 0 or control_loops >= 500
	reads, torn = test_reader_stop()
	check(
		torn > 0,
		'the same four writes one by one are seen half done ('
			.. torn
			.. ' of '
			.. reads
			.. ' reads in '
			.. control_loops
			.. ' rounds), so the test can see a mix'
	)

	local many_up, many_down = unit_list('bulk', 0x6400, VALUE, 128), unit_list('bulk', 0x6400, 0, 128)
	test_reader_start(raw(at(unit)))
	local bulk_times, bulk_windows, bulk_up, bulk_ok = {}, {}, true, true
	for round = 1, 60 do
		local started = microseconds()
		local done, window = p:batch(bulk_up and many_up or many_down)
		bulk_ok = bulk_ok and done == true
		bulk_times[#bulk_times + 1] = elapsed(started)
		bulk_windows[#bulk_windows + 1] = window
		bulk_up = not bulk_up
	end
	table.sort(bulk_windows)
	reads, torn, gap = test_reader_stop()
	check(bulk_ok and number_at(0x6400 + 4 * 127) == (bulk_up and 0 or VALUE), 'batches of 128 values go through')
	print(
		('  batch of 128 values: median %d us, max %d us; threads stopped: median %d us, max %d us; the reader thread: longest gap %d us'):format(
			median(bulk_times),
			bulk_times[#bulk_times],
			median(bulk_windows),
			bulk_windows[#bulk_windows],
			gap
		)
	)

	local small = { { 'set', 'small', at(0x7000), 4, 1, 0, 100 } }
	local small_other = { { 'set', 'small', at(0x7000), 4, 2, 0, 100 } }
	local small_times, small_windows = {}, {}
	for i = 1, 200 do
		local started = microseconds()
		local _, window = p:batch(i % 2 == 0 and small or small_other)
		small_times[#small_times + 1] = elapsed(started)
		small_windows[#small_windows + 1] = window
	end
	table.sort(small_times)
	table.sort(small_windows)
	local sites = {}
	for i = 1, 74 do
		sites[i] = { at(0x7100 + 8 * i), Z4, ONE4 }
	end
	local started = microseconds()
	check(p:batch({ { 'relocate', 'seventy_four', sites } }) == true, 'a relocation of 74 sites is one batch')
	print(
		('  batch of one value: median %d us, max %d us; threads stopped: median %d us, max %d us; batch of 74 relocation sites: %d us'):format(
			small_times[100],
			small_times[200],
			small_windows[100],
			small_windows[200],
			elapsed(started)
		)
	)

	local parked = address('parked_target')
	local PARK_BYTES = '\83\131\57\0\116\251\91\184'
	local park_list = { { 'patch', 'park', parked, PARK_BYTES, PARK_BYTES } }
	check(test_park_start(test_function('parked_target')), 'a thread spins inside parked_target')
	started = microseconds()
	ok, why, stays = p:batch(park_list)
	local waited = elapsed(started)
	check(ok == nil and why == 'a thread is inside batch_mod/park' and stays == nil, 'a thread inside the range refuses the batch: ' .. tostring(why))
	check(waited >= 5000, 'after retrying with a pause each time: ' .. waited .. ' us')
	check(mr.read(parked, 0, #PARK_BYTES) == PARK_BYTES and rows('batch_mod').park == nil, 'nothing is written or registered')
	test_park_leave_on_retry(mr.hop_slots)
	check(p:batch(park_list) == true and test_park_left(), 'the batch goes through when the thread leaves while it retries')
	check(test_park_finish() == 77, 'and the thread finished its function')
	check(rows('batch_mod').park.state == 'ours', 'the batch patch is owned')
	print(('  batch refused by a thread inside the range: %d us'):format(waited))

	local function bytes_of(text)
		return (text:gsub('%x%x', function(pair)
			return string.char(tonumber(pair, 16))
		end))
	end
	local frame_park = address('park_frame')
	check(mr.read(frame_park, 0, 11) == bytes_of('53B801000000BA03000000'), 'park_frame holds the expected bytes')
	local first_site = { { 'relocate', 'pf_first', { { mr.add(frame_park, 2), '\1\0\0\0', '\2\0\0\0' } } } }
	local second_site = { { 'relocate', 'pf_second', { { mr.add(frame_park, 7), '\3\0\0\0', '\4\0\0\0' } } } }
	check(test_park_start(test_function('parked_target')), 'a thread spins in another function')
	check(p:batch(second_site) == true and mr.read(frame_park, 7, 4) == '\4\0\0\0', 'a relocation in a function with no thread in it goes through')
	check(test_park_finish() == 77, 'and the thread finished')
	check(test_park_start(test_function('park_frame')), 'a thread spins in park_frame, outside the bytes of the relocation')
	started = microseconds()
	ok, why, stays = p:batch(first_site)
	waited = elapsed(started)
	check(
		ok == nil and why == 'a thread is inside batch_mod/pf_first' and stays == nil,
		'a thread elsewhere in the function refuses the relocation: ' .. tostring(why)
	)
	check(test_protection(raw(frame_park)) == 0x20, 'a batch refused for a busy thread puts the page back')
	check(
		waited >= 5000 and mr.read(frame_park, 2, 4) == '\1\0\0\0' and rows('batch_mod').pf_first == nil,
		'after the retries, with nothing written or registered: ' .. waited .. ' us'
	)
	ok, why = p:relocate('pf_single', first_site[1][3])
	check(
		ok == nil and why == 'a thread is inside batch_mod/pf_single' and mr.read(frame_park, 2, 4) == '\1\0\0\0' and rows('batch_mod').pf_single == nil,
		'a single p:relocate is frozen too: ' .. tostring(why)
	)
	check(p:batch({ { 'patch', 'pf_patch', frame_park, '\83', '\83' } }) == true, 'a patch with a narrow range lets the same thread through')
	test_park_leave_on_retry(mr.hop_slots)
	check(
		p:batch(first_site) == true and mr.read(frame_park, 2, 4) == '\2\0\0\0' and test_park_left(),
		'the relocation goes through when the thread leaves while it retries'
	)
	check(test_park_finish() == 78, 'and the thread finished its function')

	local parked_raw = test_function('parked_target')
	local grow = address('park_grow')
	local grow_before = mr.read(grow, 0, 32)
	check(test_park_start(test_function('park_grow')), 'a thread spins inside park_grow, a function with a frame')
	ok, why = mr.grow_frame(grow, 0x100)
	check(ok == nil and why == 'a thread is inside the function', 'grow_frame refuses to grow a frame with a thread inside: ' .. tostring(why))
	ok, why = p:frame('pg', grow, 0x100)
	check(ok == nil and why == 'a thread is inside the function', 'p:frame refuses it too: ' .. tostring(why))
	ok, why, stays = p:batch({ { 'patch', 'pg_other', at(0x9400), Z4, ONE4 }, { 'frame', 'pg', grow, 0x100 } })
	check(ok == nil and why == 'pg: a thread is inside the function' and stays == nil, 'a frame step of a batch refuses it: ' .. tostring(why))
	check(
		mr.read(grow, 0, 32) == grow_before and bytes_at(0x9400, 4) == Z4 and rows('batch_mod').pg == nil,
		'the function is not changed and nothing is written or registered'
	)
	test_park_leave_on_retry(mr.hop_slots)
	ok = p:frame('pg', grow, 0x100)
	check(ok == true and test_park_left(), 'p:frame grows the frame when the thread leaves while it retries')
	check(test_park_finish() == 79, 'and the thread finished its function')
	check(mr.read(grow, 4, 4) == '\192\1\0\0' and rows('batch_mod').pg.state == 'stays', 'the frame is grown and owned')
	check(test_park_start(test_function('park_grow')), 'a thread spins in the grown function')
	check(test_park_finish() == 79, 'and it returns through the grown epilogue')

	local outer = address('park_outer')
	check(mr.read(outer, 0, 9) == bytes_of('4883EC28B801000000'), 'park_outer holds the expected bytes')
	local outer_site = { { 'relocate', 'po', { { mr.add(outer, 5), '\1\0\0\0', '\2\0\0\0' } } } }
	check(test_park_start(test_function('park_outer'), 64), 'a thread runs park_outer')
	test_sleep(50)
	local inner_offset = tonumber(mr.tostring(mr.sub(mr.pointer(test_park_rip()), outer)), 16)
	check(inner_offset >= 19, 'and spins in park_inner, called from park_outer, outside its bytes: +' .. inner_offset)
	ok, why, stays = p:batch(outer_site)
	check(
		ok == nil and why == 'a thread is inside batch_mod/po' and stays == nil,
		'a return address on a thread stack refuses the relocation: ' .. tostring(why)
	)
	check(mr.read(outer, 5, 4) == '\1\0\0\0' and rows('batch_mod').po == nil, 'nothing is written or registered')
	test_park_leave_on_retry(mr.hop_slots)
	check(
		p:batch(outer_site) == true and mr.read(outer, 5, 4) == '\2\0\0\0' and test_park_left(),
		'the relocation goes through when the thread leaves while it retries'
	)
	check(test_park_finish() == 80, 'and the thread finished')

	local callback = address('callback')
	local inside = {}
	local function from_callback()
		local site = mr.read(callback, 8, 4)
		inside.stack = { p:batch({ { 'relocate', 'own_stack', { { mr.add(callback, 8), site, site } } } }) }
		inside.clean = { p:batch({ { 'relocate', 'own_stack', { { at(0x9500), Z4, ONE4 } } } }) }
		return 1
	end
	mr.call(callback, 'int64(pointer, int32)', mr.pointer(test_state()), test_ref(from_callback))
	check(
		inside.stack[1] == nil and inside.stack[2] == 'a thread is inside batch_mod/own_stack',
		'a return address on the stack of the script thread itself refuses the relocation: ' .. tostring(inside.stack[2])
	)
	check(inside.clean[1] == true and bytes_at(0x9500, 4) == ONE4, 'a relocation elsewhere from the same call goes through')

	local SINGLE = 'int64(int64)'
	local single = address('hook_single')
	local function from_hook(a)
		inside.frame = { p:frame('hook_frame', address('frame_twin'), 0x40) }
		inside.relocate = { p:relocate('hook_reloc', { { at(0x9600), Z4, ONE4 } }) }
		inside.batch = { p:batch({ { 'relocate', 'hook_batch', { { at(0x9600), Z4, ONE4 } } } }) }
		inside.patch = { p:batch({ { 'patch', 'hook_patch', at(0x9700), Z4, ONE4 } }) }
		return a
	end
	mr.hook(single, SINGLE, from_hook)
	mr.call(single, SINGLE, 1)
	mr.unhook(single)
	check(
		inside.frame[1] == nil and inside.frame[2] == 'not from inside a hooked call',
		'a frame is refused inside a hooked call: ' .. tostring(inside.frame[2])
	)
	check(
		inside.relocate[1] == nil and inside.relocate[2] == 'not from inside a hooked call',
		'a relocation is refused inside a hooked call: ' .. tostring(inside.relocate[2])
	)
	check(
		inside.batch[1] == nil and inside.batch[2] == 'not from inside a hooked call',
		'a batch with a relocation is refused inside a hooked call: ' .. tostring(inside.batch[2])
	)
	check(bytes_at(0x9600, 4) == Z4 and rows('batch_mod').hook_frame == nil, 'and nothing is written or registered')
	check(inside.patch[1] == true and bytes_at(0x9700, 4) == ONE4, 'a batch of patches only is allowed inside a hooked call')

	local twin = address('frame_twin')
	ok, why = p:batch({ { 'frame', 'tw', twin, 0x40 }, { 'cave', 'tw_cave', mr.add(twin, 24), '\144' } })
	check(
		ok == nil and why == 'tw_cave: inside the function of tw in this batch',
		'a cave inside the function of a frame of the same batch is refused in the first step: ' .. tostring(why)
	)
	check(rows('batch_mod').tw == nil and rows('batch_mod').tw_cave == nil, 'and neither is made')

	check(test_park_start(parked_raw), 'a thread spins so that there is someone to stop')
	test_watch_suspend(mr.hop_slots)
	test_change_on_suspend(raw(at(0x9200)), TWO4)
	ok, why, stays = p:batch({ { 'patch', 'cas', at(0x9200), Z4, ONE4 } })
	check(
		ok == nil and why == 'cas: unexpected bytes' and stays == nil,
		'bytes changed by someone else after the planning stop the batch inside the window: ' .. tostring(why)
	)
	check(bytes_at(0x9200, 4) == TWO4 and rows('batch_mod').cas == nil, 'their bytes stay and nothing is registered')

	local counted = { { 'set', 'sp', at(0x9300), 4, 1, 0, 100 } }
	local function stops(value)
		counted[1][5] = value
		test_watch_suspend(mr.hop_slots)
		ok, why = p:batch(counted)
		return ok == true and test_suspend_calls() or ok
	end
	local baseline = stops(1)
	check(type(baseline) == 'number' and baseline >= 1, 'a batch stops every other thread: ' .. tostring(baseline) .. ' stops')
	test_spawn_on_suspend(1)
	local with_new = stops(2)
	test_end_spawned()
	check(with_new == baseline + 1, 'and a thread created while the others are being stopped is stopped too: ' .. tostring(with_new) .. ' stops')

	test_deny_next_thread(true, mr.hop_slots)
	check(p:remove('park') == true, 'the first parked patch is removed')
	ok, why = p:batch(park_list)
	check(
		ok == nil and why == 'a thread is inside batch_mod/park',
		'without the thread enumeration of ntdll a thread inside the range still refuses: ' .. tostring(why)
	)
	check(test_park_finish() == 77, 'the thread finished')
	started = microseconds()
	check(stops(3) ~= nil and number_at(0x9300) == 3, 'and a clean batch goes through')
	print(('  batch through the system thread snapshot: %d us'):format(elapsed(started)))
	test_deny_next_thread(false, mr.hop_slots)

	check(test_park_start(parked_raw), 'a thread spins again')
	test_fail_context(1, mr.hop_slots)
	check(stops(5) ~= nil and number_at(0x9300) == 5, 'a thread whose context cannot be read is retried and the batch goes through')
	test_fail_context(1000, mr.hop_slots)
	counted[1][5] = 6
	ok, why = p:batch(counted)
	check(
		ok == nil and why == 'a thread could not be checked' and number_at(0x9300) == 5,
		'a thread that can never be checked refuses the batch: ' .. tostring(why)
	)
	check(protection_of(0x9300) == 0x20, 'and its page is put back')
	test_fail_context(0, mr.hop_slots)
	check(test_park_finish() == 77, 'the thread finished')
elseif SCENARIO == 'link_filter' then
	io.stdout:setvbuf('no')
	local logged = {}
	ModLog = function(message)
		logged[#logged + 1] = message
		print('  log: ' .. message)
	end
	run_mod(OURS)
	local mr = _G.memreader_plus
	local SIGNATURE = 'int64(pointer, pointer, pointer, int32, uint8)'
	local SINGLE = 'int64(int64)'
	local EXPECTED = 35
	local target, single = mr.pointer(test_function('host_source')), mr.pointer(test_function('hook_single'))
	local dummy = mr.alloc(16)
	local function contains(text, part)
		return type(text) == 'string' and string.find(text, part, 1, true) ~= nil
	end
	local function lines_with(part)
		local count = 0
		for _, line in ipairs(logged) do
			if contains(line, part) then count = count + 1 end
		end
		return count
	end
	local function call_with(source)
		return mr.tonumber(mr.call(target, SIGNATURE, dummy, source, dummy, 3, 5))
	end
	local function make_source(key)
		local block = mr.alloc(32)
		mr.write(block, 0x10, key)
		return block
	end
	local function pass_through(game)
		return game()
	end
	local trace = {}
	local function mark(text)
		trace[#trace + 1] = text
	end
	local function seen()
		local text = table.concat(trace, ' ')
		trace = {}
		return text
	end

	if PASS == 1 then
		local p = mr.patcher('filter_a')
		local f1, f2, f3 = mr.alloc(16), mr.alloc(16), mr.alloc(16)
		local s1, s2, s3 = make_source(f1), make_source(f2), make_source(f3)
		check(mr.eq(mr.read_pointer(s1, 0x10), f1), 'a test source holds its key at +0x10')
		check(call_with(s1) == EXPECTED, 'the original result before any link')

		local set = mr.pointer_set()
		check(set:fill({ f1 }) == true, 'fill takes a list of pointers')
		local hits = 0
		check(p:around(target, SIGNATURE, 'gate', function(game)
			hits = hits + 1
			return game()
		end, nil, { arg = 2, reads = { 0x10 }, set = set }) == true, 'an around with a when option and no priority')
		check(call_with(s1) == EXPECTED and hits == 1, 'a member runs the link')
		check(call_with(s2) == EXPECTED and call_with(s3) == EXPECTED and hits == 1, 'other keys run the original with no Lua entry, and the result is right')
		local row = p:info('gate')
		check(row.calls == 1 and row.filtered == 2 and row.errors == 0, 'the row counts calls and filtered: ' .. row.calls .. ' ' .. row.filtered)
		check(mr.hook_info(target).calls == 1, 'and the hook counts only the call that entered Lua')
		check(
			row.when.arg == 2 and row.when.reads[1] == 16 and #row.when.reads == 1 and row.when.members == 1 and row.when.off == nil,
			'the row shows the filter'
		)
		local listed = mr.patch_info(target).links[1]
		check(listed.filtered == 2 and listed.when.arg == 2 and listed.when.members == 1, 'patch_info shows it too')
		check(mr.patch_list('filter_a')[1].filtered == 2 and mr.patch_list('filter_a')[1].when.members == 1, 'and patch_list')

		check(set:fill({ f2, f3 }) == true, 'fill again')
		check(call_with(s1) == EXPECTED and hits == 1, 'fill replaces the whole content: the old member is out')
		check(call_with(s2) == EXPECTED and call_with(s3) == EXPECTED and hits == 3, 'and the new ones are in')
		check(p:info('gate').when.members == 2, 'members counts them')
		check(set:fill({}) == true and call_with(s2) == EXPECTED and hits == 3 and p:info('gate').when.members == 0, 'an empty list empties the set')
		check(set:fill(true) == true and p:info('gate').when.members == 'all', 'true makes every key a member')
		check(call_with(s1) == EXPECTED and call_with(s2) == EXPECTED and call_with(s3) == EXPECTED and hits == 6, 'all three run')

		local faults = test_access_faults()
		local filtered_before = p:info('gate').filtered
		local null_hop = mr.alloc(32)
		local junk_hop = make_source(mr.pointer('\52\18\0\0\0\0\0\0'))
		local rejected = {
			call_with(nil),
			call_with(mr.pointer('\0\16\0\0\0\0\0\0')),
			call_with(mr.pointer('\0\0\0\0\0\0\0\128')),
			call_with(mr.pointer('\0\0\255\255\255\127\0\0')),
			call_with(null_hop),
		}
		check(
			#rejected == 5 and rejected[1] == EXPECTED and rejected[5] == EXPECTED and hits == 6,
			'a NULL argument, a NULL key, a small value and values above user space run the original only'
		)
		check(p:info('gate').filtered == filtered_before + 5, 'and each counts as filtered')
		check(test_access_faults() == faults, 'without a single access violation: the range check comes before every read')
		check(call_with(junk_hop) == EXPECTED and hits == 7, 'the last key is only checked for NULL, a small value is looked up')
		p:remove_all()

		local q = mr.patcher('filter_b')
		local all = mr.pointer_set()
		all:fill(true)
		local chain_hits = 0
		check(q:around(target, SIGNATURE, 'chain', function(game)
			chain_hits = chain_hits + 1
			return game()
		end, nil, { arg = 2, reads = { 0x10, 0 }, set = all }) == true, 'an around that follows two reads')
		local tagged = mr.alloc(16)
		mr.write(tagged, 0, mr.uint64(77))
		local good_source = make_source(tagged)
		local reserved = mr.pointer(test_reserved())
		local bad_source = make_source(reserved)
		check(call_with(good_source) == EXPECTED and chain_hits == 1, 'a chain of two reads passes')
		faults = test_access_faults()
		check(call_with(bad_source) == EXPECTED and chain_hits == 1, 'a chain that faults runs the original and skips the link')
		check(test_access_faults() == faults + 1, 'it costs one access violation')
		local faulted = q:info('chain')
		check(
			faulted.errors == 1
				and contains(faulted.error, 'when: read at 0x')
				and contains(faulted.error, 'faulted (read 2)')
				and contains(faulted.error, 'the link is off until the next mode'),
			'the fault is an error of the link: ' .. tostring(faulted.error)
		)
		check(
			contains(faulted.when.off, 'faulted (read 2)') and mr.patch_info(target).links[1].when.off == faulted.when.off,
			'and the rows say the filter is off'
		)
		mr.flush_log()
		check(lines_with('filter_b/chain (around): when: read at 0x') == 1, 'and it is logged once')
		for _ = 1, 1000 do
			call_with(bad_source)
		end
		check(test_access_faults() == faults + 1, 'later calls do not read again: no more access violations')
		check(call_with(good_source) == EXPECTED and chain_hits == 1, 'the filter stays off for the mode, even for a chain that would pass')
		faulted = q:info('chain')
		check(faulted.errors == 1 and faulted.filtered == 1002, 'one error, every call counted as filtered: ' .. faulted.filtered)
		mr.flush_log()
		check(lines_with('filter_b/chain (around): when: read at 0x') == 1, 'and still logged once')

		local function refusal(when)
			return select(2, q:around(target, SIGNATURE, 'bad_when', pass_through, nil, when))
		end
		local ARG = 'when.arg must name a pointer, int64 or uint64 argument'
		local OFFSETS = 'when.reads must hold whole offsets from -16777215 to 16777215'
		check(refusal({ arg = 4, set = all }) == ARG, 'an int32 argument is refused')
		check(refusal({ arg = 5, set = all }) == ARG, 'a uint8 argument is refused')
		check(refusal({ arg = 0, set = all }) == ARG and refusal({ arg = 6, set = all }) == ARG, 'an argument outside the signature is refused')
		check(refusal({ arg = '2', set = all }) == ARG and refusal({ set = all }) == ARG, 'arg must be a number')
		check(refusal({ arg = 2, reads = { 1, 2, 3, 4, 5 }, set = all }) == 'when.reads takes at most 4 offsets', 'five reads are refused')
		check(
			refusal({ arg = 2, reads = { 0.5 }, set = all }) == OFFSETS and refusal({ arg = 2, reads = { 16777216 }, set = all }) == OFFSETS,
			'offsets are whole and bounded'
		)
		check(refusal({ arg = 2, reads = { 'x' }, set = all }) == OFFSETS, 'a text is not an offset')
		check(refusal({ arg = 2, reads = 5, set = all }) == 'when.reads must be a list of offsets', 'reads is a list')
		check(refusal({ arg = 2 }) == 'when.set must be a pointer set', 'a set is needed')
		check(
			refusal({ arg = 2, set = {} }) == 'when.set must be a pointer set' and refusal({ arg = 2, set = dummy }) == 'when.set must be a pointer set',
			'and it must be one'
		)
		check(refusal({ arg = 2, set = all, read = { 0x10 } }) == 'when has an unknown field', 'a misspelled field is refused')
		check(not pcall(q.around, q, target, SIGNATURE, 'bad_when', pass_through, nil, 5), 'a when that is not a table raises')
		check(q:info('bad_when') == nil and #mr.patch_info(target).links == 1, 'refusals register nothing')
		check(
			q:around(target, SIGNATURE, 'edge', pass_through, nil, { arg = 2, reads = { -16777215, 16777215, 0, 8 }, set = all }) == true,
			'four reads at the limits are accepted'
		)
		q:remove('edge')
		check(
			q:around(target, SIGNATURE, 'wide', pass_through, nil, { arg = 1 }) == nil,
			'a pointer argument is accepted as the key, but a set is still needed'
		)

		local tiny = mr.pointer_set()
		check(select(2, tiny:fill({ 5 })) == 'value 1 is not a pointer, int64 or uint64', 'a Lua number is not a value')
		check(select(2, tiny:fill({ f1, mr.uint32(5) })) == 'value 2 is not a pointer, int64 or uint64', 'a uint32 is not either')
		check(select(2, tiny:fill({ f1, 'text' })) == 'value 2 is not a pointer, int64 or uint64', 'and a string is not')
		check(
			not pcall(tiny.fill, tiny, 5) and not pcall(tiny.fill, tiny, false) and not pcall(tiny.fill, tiny),
			'fill of something else than a list or true raises'
		)
		check(not pcall(tiny.fill, {}, {}), 'fill needs a set')
		check(q:around(target, SIGNATURE, 'probe', pass_through, nil, { arg = 2, reads = { 0x10 }, set = tiny }) == true, 'a link on the small set')
		q:remove('chain')
		check(tiny:fill({ f1 }) == true, 'fill')
		local probe_before = q:info('probe').calls
		check(call_with(s1) == EXPECTED and q:info('probe').calls == probe_before + 1, 'f1 is in')
		local big = {}
		for i = 1, 262145 do
			big[i] = mr.uint64(i * 16)
		end
		local ok, why = tiny:fill(big)
		check(ok == nil and why == 'at most 262144 values', 'more than 262144 values are refused: ' .. tostring(why))
		big = nil
		ok, why = tiny:fill({ f2, mr.uint32(1) })
		check(ok == nil and q:info('probe').when.members == 1, 'a refusal leaves the set as it was')
		check(call_with(s1) == EXPECTED and q:info('probe').calls == probe_before + 2, 'and f1 is still in')
		check(call_with(s2) == EXPECTED and q:info('probe').calls == probe_before + 2, 'and f2 is not')

		local function key_of(i)
			return string.char((i * 16) % 256, math.floor(i * 16 / 256) % 256, math.floor(i * 16 / 65536) % 256, 1, 0, 0, 0x10, 0)
		end
		local MEMBERS = 262144
		local members = {}
		for i = 1, MEMBERS do
			members[i] = mr.uint64(key_of(i))
		end
		check(tiny:fill(members) == true and q:info('probe').when.members == MEMBERS and tiny:count() == MEMBERS, 'a set of 262144 values')
		local scratch = mr.alloc(32)
		local before = q:info('probe').calls
		for i = 1, MEMBERS do
			mr.write(scratch, 0x10, members[i])
			call_with(scratch)
		end
		check(q:info('probe').calls == before + MEMBERS, 'every one of them is found')
		before = q:info('probe').filtered
		local calls_before = q:info('probe').calls
		for i = MEMBERS + 1, MEMBERS + 4096 do
			mr.write(scratch, 0x10, mr.uint64(key_of(i)))
			call_with(scratch)
		end
		check(q:info('probe').filtered == before + 4096 and q:info('probe').calls == calls_before, 'and 4096 others are not')
		members = nil
		collectgarbage('collect')
		local memory_big = collectgarbage('count')
		check(tiny:fill({ f1 }) == true and tiny:count() == 1, 'a small fill after a big one')
		collectgarbage('collect')
		check(
			memory_big - collectgarbage('count') > 3 * 1024,
			'gives the slots of the big set back: ' .. math.floor(memory_big - collectgarbage('count')) .. ' KB'
		)
		check(call_with(s1) == EXPECTED and q:info('probe').calls == calls_before + 1, 'and f1 is found in the small set')
		local function fill_with_finalizers_due()
			local fill_runs, seen_in_fill, inside_fill = 0, nil, false
			local function finalizer()
				fill_runs = fill_runs + 1
				if inside_fill then
					local calls = q:info('probe').calls
					call_with(s1)
					seen_in_fill = q:info('probe').calls == calls + 1
				end
			end
			local list = {}
			for i = 1, 70000 do
				list[i] = mr.uint64(key_of(i))
			end
			local keep = {}
			for i = 1, 50 do
				keep[i] = newproxy(true)
				getmetatable(keep[i]).__gc = finalizer
			end
			local pause = collectgarbage('setpause', 0)
			local multiplier = collectgarbage('setstepmul', 0)
			collectgarbage('collect')
			keep = nil
			inside_fill = true
			local filled = tiny:fill(list)
			inside_fill = false
			collectgarbage('setpause', pause)
			collectgarbage('setstepmul', multiplier)
			return filled, seen_in_fill, fill_runs
		end
		local filled, seen_in_fill, fill_runs = fill_with_finalizers_due()
		check(filled == true and tiny:count() == 70000, 'a fill with finalizers due')
		check(seen_in_fill == true, 'a finalizer run inside fill calls a filtered function and the old content still holds f1: ' .. fill_runs .. ' runs')
		local filtered_before = q:info('probe').filtered
		check(call_with(s1) == EXPECTED and q:info('probe').filtered == filtered_before + 1, 'after the fill f1 is filtered out')
		local duplicates = { f1, f1, mr.pointer('\0\0\0\0\0\0\0\0'), mr.int64(5) }
		check(tiny:fill(duplicates) == true and q:info('probe').when.members == 2, 'a repeated value and a NULL are one member and none')
		q:remove_all()

		local c = mr.patcher('filter_c')
		local only_f1 = mr.pointer_set()
		only_f1:fill({ f1 })
		local replaced_by, seen_source = nil, nil
		c:prefix(target, SIGNATURE, 'pre', function(call)
			mark('P')
			if replaced_by then call:set(2, replaced_by) end
		end, 5)
		c:around(target, SIGNATURE, 'filtered', function(game, list, source)
			mark('A')
			seen_source = source
			return game()
		end, 0, { arg = 2, reads = { 0x10 }, set = only_f1 })
		c:postfix(target, SIGNATURE, 'post', function()
			mark('F')
		end, 0)
		replaced_by = s1
		check(
			call_with(s2) == EXPECTED and seen() == 'P F',
			'the filter reads the arguments the game passed: a prefix that sets a member source does not wake the around'
		)
		replaced_by = s2
		check(
			call_with(s1) == EXPECTED and seen() == 'P A F' and mr.eq(seen_source, s2),
			'and one that replaces a member source does not stop it, the around gets the new one'
		)
		replaced_by = nil
		c:remove_all()

		local d = mr.patcher('filter_d')
		d:prefix(target, SIGNATURE, 'pre', function()
			mark('P')
		end, 0, { arg = 2, reads = { 0x10 }, set = only_f1 })
		d:around(target, SIGNATURE, 'around', function(game)
			mark('A')
			return game()
		end, 0, { arg = 2, reads = { 0x10 }, set = only_f1 })
		d:postfix(target, SIGNATURE, 'post', function()
			mark('F')
		end, 0, { arg = 2, reads = { 0x10 }, set = only_f1 })
		check(call_with(s1) == EXPECTED and seen() == 'P A F', 'prefix, around and postfix can all be filtered, a member runs all three')
		local hook_calls = mr.hook_info(target).calls
		check(call_with(s2) == EXPECTED and call_with(s3) == EXPECTED and seen() == '', 'three filters saying no: no link runs and the result is the original')
		check(mr.hook_info(target).calls == hook_calls, 'the hook did not even count the calls: they went straight to the original')
		check(d:info('pre').filtered == 2 and d:info('around').filtered == 2 and d:info('post').filtered == 2, 'each link counts them')
		mr.hook(target, SIGNATURE, function(...)
			mark('H')
			return mr.hook_next(target, ...)
		end)
		check(call_with(s2) == EXPECTED and seen() == 'H', 'an old hook on the address is never filtered')
		check(
			mr.hook_info(target).calls == hook_calls + 1 and d:info('pre').filtered == 3,
			'it makes the call enter the full path, the filtered links stay out'
		)
		mr.unhook(target)
		d:remove_all()

		local e = mr.patcher('filter_e')
		local other_set = mr.pointer_set()
		other_set:fill({ f1 })
		local function install_same(set, reads)
			return e:around(target, SIGNATURE, 'same', pass_through, nil, { arg = 2, reads = reads, set = set })
		end
		check(install_same(only_f1, { 0x10 }) == true, 'a filtered link')
		call_with(s1)
		check(e:info('same').calls == 1, 'it ran once')
		check(install_same(only_f1, { 0x10 }) == true and e:info('same').calls == 1, 'the same name with the same function, set and reads is a no-op')
		check(install_same(other_set, { 0x10 }) == true and e:info('same').calls == 0, 'another set object replaces the link')
		call_with(s1)
		check(install_same(other_set, { 0x20 }) == true and e:info('same').calls == 0 and e:info('same').when.reads[1] == 32, 'other offsets replace it')
		check(e:around(target, SIGNATURE, 'same', pass_through) == true and e:info('same').when == nil, 'no when at all replaces it too')
		check(install_same(other_set, { 0x10 }) == true and e:info('same').when.arg == 2, 'and a when replaces the link without one')
		check(
			e:around(target, SIGNATURE, 'same', pass_through, nil, { arg = 3, set = other_set }) == true and e:info('same').when.arg == 3,
			'another argument replaces it'
		)
		e:remove_all()

		local g = mr.patcher('filter_g')
		local orphan_hits = 0
		g:around(
			target,
			SIGNATURE,
			'orphan',
			function(game)
				orphan_hits = orphan_hits + 1
				return game()
			end,
			nil,
			{
				arg = 2,
				reads = { 0x10 },
				set = (function()
					local made = mr.pointer_set()
					made:fill({ f1 })
					return made
				end)(),
			}
		)
		for _ = 1, 30 do
			mr.pointer_set():fill(true)
		end
		collectgarbage()
		collectgarbage()
		check(
			call_with(s1) == EXPECTED and orphan_hits == 1 and call_with(s2) == EXPECTED and orphan_hits == 1,
			'a set that only the link holds survives the garbage collector'
		)
		g:remove_all()
		for _ = 1, 30 do
			mr.pointer_set():fill({ f1 })
		end
		collectgarbage()
		collectgarbage()

		local refill = mr.pointer_set()
		refill:fill({ f1 })
		local h = mr.patcher('filter_h')
		h:around(target, SIGNATURE, 'refill', function(game)
			refill:fill({})
			return game()
		end, nil, { arg = 2, reads = { 0x10 }, set = refill })
		check(call_with(s1) == EXPECTED and h:info('refill').calls == 1, 'a link that empties its own set runs')
		check(call_with(s1) == EXPECTED and h:info('refill').calls == 1 and h:info('refill').filtered == 1, 'and the next call sees the new content')
		h:remove_all()

		local thread_set = mr.pointer_set()
		thread_set:fill({ mr.int64(5) })
		local t = mr.patcher('filter_t')
		local value_hits = 0
		t:around(single, SINGLE, 'by_value', function(game)
			value_hits = value_hits + 1
			return game()
		end, nil, { arg = 1, set = thread_set })
		check(mr.tonumber(mr.call(single, SINGLE, 5)) == 16 and value_hits == 1, 'an int64 argument without reads is the key')
		check(mr.tonumber(mr.call(single, SINGLE, 6)) == 19 and value_hits == 1 and t:info('by_value').filtered == 1, 'another value is filtered')
		check(
			mr.tonumber(mr.call(mr.pointer(test_function('call_on_thread')), 'int64(pointer, int64)', single, 5)) == 16,
			'a call on another thread runs the original'
		)
		check(
			mr.hook_info(single).other_thread_calls == 1 and value_hits == 1 and t:info('by_value').filtered == 1,
			'it is counted as an other thread call and the filter does not run there'
		)
		local unsigned_set = mr.pointer_set()
		unsigned_set:fill({ mr.uint64('\255\255\255\255\255\255\255\255') })
		t:around(single, SINGLE, 'by_value', function(game)
			value_hits = value_hits + 10
			return game()
		end, nil, { arg = 1, set = unsigned_set })
		check(mr.tonumber(mr.call(single, SINGLE, -1)) == -2 and value_hits == 11, 'an int64 -1 is the same key as a uint64 with all bits set')
		t:remove_all()

		local block = mr.pointer(test_source_block())
		mr.write(block, 0x10, f1)
		local function ns_per_call(calls)
			return (test_source_loop(test_function('host_source'), calls))
		end
		local function least(calls)
			local best = math.huge
			for _ = 1, os.getenv('PLUS_PERF') == '1' and 15 or 5 do
				local value = ns_per_call(calls)
				if value < best then best = value end
			end
			return best
		end
		local timing = mr.patcher('filter_timing')
		local none = mr.pointer_set()
		local detour_only = least(1000000)
		timing:around(target, SIGNATURE, 'timed', pass_through, nil, { arg = 2, reads = { 0x10 }, set = none })
		local rejected_ns = least(1000000)
		timing:remove_all()
		local crowded, crowd = mr.pointer_set(), {}
		for i = 1, 262144 do
			crowd[i] = mr.uint64(i * 16)
		end
		crowded:fill(crowd)
		crowd = nil
		timing:around(target, SIGNATURE, 'timed', pass_through, nil, { arg = 2, reads = { 0x10 }, set = crowded })
		local crowded_ns = least(1000000)
		timing:remove_all()
		timing:around(target, SIGNATURE, 'timed', pass_through)
		local around_ns = least(100000)
		timing:remove_all()
		local accepting = mr.pointer_set()
		accepting:fill(true)
		timing:around(target, SIGNATURE, 'timed', pass_through, nil, { arg = 2, reads = { 0x10 }, set = accepting })
		local accepted_ns = least(100000)
		timing:remove_all()
		print(
			string.format(
				'  timing (ns per native call, least of rounds): detour only %.1f, filtered link saying no %.1f (+%.1f), the same with 262144 members %.1f (+%.1f), unfiltered pass-through around %.1f (+%.1f), filtered around saying yes %.1f',
				detour_only,
				rejected_ns,
				rejected_ns - detour_only,
				crowded_ns,
				crowded_ns - detour_only,
				around_ns,
				around_ns - detour_only,
				accepted_ns
			)
		)
		local enforce = os.getenv('PLUS_PERF') == '1'
		local function budget(met, what)
			if met or enforce then
				check(met, what)
			else
				print('WARN ' .. what .. ' (a budget, enforced by tests\\run.ps1 -Perf)')
			end
		end
		budget(rejected_ns - detour_only <= (around_ns - detour_only) / 10, 'a rejected call costs at most a tenth of a pass-through around')
		budget(rejected_ns - detour_only < 60, 'and under 60 ns above the detour')
		budget(crowded_ns - detour_only < 60, 'and still under 60 ns with 262144 members in the set')

		local carry_set = mr.pointer_set()
		carry_set:fill(true)
		check(
			q:around(target, SIGNATURE, 'carry', pass_through, nil, { arg = 2, reads = { 0x10, 0 }, set = carry_set }) == true,
			'a link that stays attached into the next mode'
		)
		call_with(bad_source)
		check(q:info('carry').when.off ~= nil and q:info('carry').errors == 1, 'with its filter off')

		NEXT_PASS = failures == 0
	else
		local p = mr.patcher('filter_b')
		check(#mr.patch_info(target).links == 0, 'a new mode starts with every link detached')
		local row = p:info('carry')
		check(row ~= nil and row.state == 'detached', 'the old row says detached: ' .. tostring(row and row.state))
		local tagged = mr.alloc(16)
		mr.write(tagged, 0, mr.uint64(77))
		local good_source = make_source(tagged)
		local bad_source = make_source(mr.pointer(test_reserved()))
		local fresh = mr.pointer_set()
		fresh:fill(true)
		local chain_hits = 0
		check(p:around(target, SIGNATURE, 'carry', function(game)
			chain_hits = chain_hits + 1
			return game()
		end, nil, { arg = 2, reads = { 0x10, 0 }, set = fresh }) == true, 'the same link attaches again with a new set')
		row = p:info('carry')
		check(row.errors == 0 and row.filtered == 0 and row.when.off == nil and row.state == 'stays', 'with its counters and its filter fresh')
		check(call_with(good_source) == EXPECTED and chain_hits == 1, 'the filter works again')
		local faults = test_access_faults()
		check(call_with(bad_source) == EXPECTED and call_with(bad_source) == EXPECTED and test_access_faults() == faults + 1, 'and may fault once in this mode')
		mr.flush_log()
		check(lines_with('filter_b/carry (around): when: read at 0x') == 1, 'logged once in this mode as well')
		check(p:info('carry').errors == 1 and p:info('carry').when.off ~= nil and call_with(good_source) == EXPECTED and chain_hits == 1, 'and off again')
		p:remove_all()
	end
elseif SCENARIO == 'rows' then
	io.stdout:setvbuf('no')
	run_mod(OURS)
	local entry_live = test_heap_blocks()
	local mr = _G.memreader_plus
	local filler = mr.pointer(test_function('filler_code'))
	local RECORD_SIZE = 0x20
	local KEYS = 0x28
	local BUCKETS = 31
	local NODE_INDEX, NODE_SOURCE = 0x20, 0x28
	local STATE_FILE = 'rows_state.txt'
	local size_function = mr.game_alloc(8)
	mr.write(size_function, 0, '\184\32\0\0\0\195\0\0')
	local record_vtable = mr.game_alloc(8)

	local function hex(bytes)
		return (bytes:gsub('.', function(c)
			return ('%02x'):format(c:byte())
		end))
	end
	local function pointer_from_text(text)
		local raw = {}
		for i = #text - 1, 1, -2 do
			raw[#raw + 1] = string.char(tonumber(text:sub(i, i + 1), 16))
		end
		return mr.pointer(table.concat(raw))
	end

	local function make_table(names, capacity)
		local block = mr.game_alloc(KEYS + 0x30 + (BUCKETS + 1) * 8)
		local vtable = mr.game_alloc(24)
		local map = mr.add(block, KEYS)
		local finish, data = mr.add(map, 8), mr.add(map, 0x30)
		local buffer = mr.game_alloc(capacity * 8)
		local t = { block = block, map = map, vtable = vtable, records = {}, targets = {} }
		mr.write(vtable, 16, size_function)
		mr.write(block, 0, vtable)
		mr.write(map, 0x10, finish)
		mr.write(map, 0x18, mr.uint32(BUCKETS + 1))
		mr.write(map, 0x1C, mr.uint32(BUCKETS + 1))
		mr.write(map, 0x20, data)
		for i = 0, BUCKETS do
			mr.write(data, i * 8, finish)
		end
		mr.write(map, 0x28, 1.0)
		mr.write(block, 8, mr.uint32(capacity))
		mr.write(block, 12, mr.int32(#names))
		mr.write(block, 16, buffer)
		t.source = mr.game_alloc(8)
		for i, name in ipairs(names) do
			local record, target = mr.game_alloc(RECORD_SIZE), mr.game_alloc(8)
			mr.write(record, 0, record_vtable)
			mr.write(record, 8, target)
			mr.write(record, 0x18, mr.add(target, 4))
			mr.write(buffer, (i - 1) * 8, record)
			mr.map_add_key(map, name, i - 1, t.source)
			t.records[i], t.targets[i] = record, target
		end
		return t
	end
	local function snapshot(t)
		local count, data = mr.read_array(t.block, 8)
		local records, keys = {}, {}
		for i = 0, count - 1 do
			local record = mr.read_pointer(data, i * 8)
			records[#records + 1] = mr.tostring(record) .. ':' .. hex(mr.read(record, 0, RECORD_SIZE))
		end
		local nodes = mr.read_list(t.map, 0, { 0, 'struct', { key = { 0x10, 'string' }, index = { NODE_INDEX, 'uint32' } } })
		for _, node in ipairs(nodes) do
			keys[#keys + 1] = node.key .. '=' .. node.index
		end
		table.sort(keys)
		return count .. '|' .. table.concat(records, ';') .. '|' .. table.concat(keys, ' ')
	end
	local function key_index(t, key)
		local node = mr.map_find_key(t.map, key)
		return node and mr.read_uint32(node, NODE_INDEX)
	end
	local function row_count(t)
		return mr.read_int32(t.block, 12)
	end
	local function live()
		return test_heap_blocks()
	end
	local function refusal(...)
		local record, why = ...
		return record == nil and why
	end
	local DIFFERENT = 'the name is already used for a different change'

	if PASS == 1 then
		local deferred = 0
		local t = make_table({ 'a', 'b', 'c' }, 3)
		local u = make_table({ 'a', 'b', 'c' }, 16)
		local before_t, before_u = snapshot(t), snapshot(u)
		local p = mr.patcher('rows_a')
		check(type(p.row) == 'function' and mr.supports.rows == true, 'the handle has row and the flag says so')

		local live0, data0 = live(), mr.read_pointer(t.block, 16)
		local record, row = p:row('first', t.block, t.records[1], 'ax', { [0x18] = t.targets[2] })
		check(mr.type(record) == 'pointer' and row == 3, 'a row is added at the end of a full table: row ' .. tostring(row))
		check(row_count(t) == 4 and mr.read_uint32(t.block, 8) == 6, 'the vector grew to six')
		local data1 = mr.read_pointer(t.block, 16)
		check(not mr.eq(data1, data0), 'into a new buffer')
		check(mr.eq(mr.read_pointer(data1, 0), t.records[1]) and mr.eq(mr.read_pointer(data1, 16), t.records[3]), 'the old pointers moved over')
		check(mr.eq(mr.read_pointer(data1, 24), record), 'and the new one is last')
		check(mr.eq(mr.read_pointer(record, 0), record_vtable), 'the record has the template vtable')
		check(
			mr.eq(mr.read_pointer(record, 8), t.targets[1]) and mr.eq(mr.read_pointer(record, 0x18), t.targets[2]),
			'it holds the template bytes and the edit'
		)
		check(key_index(t, 'ax') == 3, 'the key maps to the new row')
		check(mr.eq(mr.read_pointer(mr.map_find_key(t.map, 'ax'), NODE_SOURCE), t.source), "and carries the template's source")
		check(live() == live0 + 3, 'one record, one buffer and one key node: ' .. (live() - live0))
		deferred = deferred + 1
		local info = p:info('first')
		check(info.kind == 'row' and info.state == 'ours' and mr.eq(info.at, record), 'info: kind, state, address')
		check(info.key == 'ax' and info.row == 3 and mr.eq(info.table, t.block), 'info: key, row, table')
		check(#mr.patch_list('rows_a') == 1 and mr.patch_list('rows_a')[1].kind == 'row', 'patch_list lists it')

		local again, again_row = p:row('first', t.block, t.records[1], 'ax', { [0x18] = t.targets[2] })
		check(mr.eq(again, record) and again_row == 3 and row_count(t) == 4 and live() == live0 + 3, 'the same call again is a no-op')
		check(refusal(p:row('first', t.block, t.records[1], 'ax', { [0x18] = t.targets[3] })) == DIFFERENT, 'other edits are a different change')
		check(refusal(p:row('first', t.block, t.records[1], 'ay', { [0x18] = t.targets[2] })) == DIFFERENT, 'another key is a different change')
		check(refusal(p:row('first', u.block, u.records[1], 'ax', { [0x18] = u.targets[2] })) == DIFFERENT, 'another table is a different change')
		check(row_count(t) == 4, 'and nothing was added')

		check(p:remove('first') == true, 'remove')
		check(snapshot(t) == before_t, 'the table has the same rows, bytes and keys again')
		check(mr.is_null(mr.read_pointer(mr.read_pointer(t.block, 16), 24)), 'the freed slot is zero')
		check(mr.map_find_key(t.map, 'ax') == nil and p:info('first') == nil, 'the key and the item are gone')
		check(live() == live0 + 3, 'the record and the key node are freed at the mode switch, not now')
		deferred = deferred + 2
		check(select(2, p:remove('first')) == 'unknown name', 'remove twice')
		local second, second_row = p:row('first', t.block, t.records[2], 'ax')
		check(second ~= nil and second_row == 3 and mr.read_uint32(t.block, 8) == 6, 'a row can be added again after a remove, no growth now')
		check(
			mr.eq(mr.read_pointer(second, 8), t.targets[2]) and mr.eq(mr.read_pointer(second, 0x18), mr.add(t.targets[2], 4)),
			'a row without edits copies the template'
		)
		check(p:remove('first') == true and snapshot(t) == before_t, 'removed again')
		deferred = deferred + 2

		local base = live()
		p:row('r1', u.block, u.records[1], 'k1', { [0x10] = mr.uint32(7) })
		p:row('r2', u.block, u.records[2], 'k2', { [0x1C] = 'abcd', [8] = u.targets[3] })
		p:row('r3', u.block, u.records[3], 'k3')
		check(row_count(u) == 6 and mr.read_uint32(u.block, 8) == 16 and live() == base + 6, 'three rows in a table with room: no growth')
		local function row_record(t, i)
			return mr.read_pointer(mr.read_pointer(t.block, 16), i * 8)
		end
		check(mr.read_uint32(row_record(u, 3), 0x10) == 7, 'a typed value edit writes its width')
		check(mr.read(row_record(u, 4), 0x1C, 4) == 'abcd' and mr.eq(mr.read_pointer(row_record(u, 4), 8), u.targets[3]), 'a string edit and a pointer edit')
		check(key_index(u, 'k1') == 3 and key_index(u, 'k2') == 4 and key_index(u, 'k3') == 5, 'keys and indices')
		p:row('first', t.block, t.records[1], 'ax')
		local ok, removed, stayed = p:remove_all()
		check(ok == true and removed == 4 and stayed == 0, 'remove_all takes the owner rows back, newest first: ' .. tostring(removed))
		check(snapshot(u) == before_u and snapshot(t) == before_t and #mr.patch_list('rows_a') == 0, 'both tables are as before')
		deferred = deferred + 8

		local q = mr.patcher('rows_b')
		check(p:row('p1', u.block, u.records[2], 'kp1') ~= nil and q:row('q1', u.block, u.records[3], 'kq1') ~= nil, 'two owners add one row each')
		check(refusal(p:remove('p1')) == 'rows were added after it' and p:info('p1').state == 'ours', 'a row under another owner row cannot go')
		local all_ok, all_why, all_removed, all_stayed = p:remove_all()
		check(
			all_ok == nil and all_why == '1 changes could not be put back' and all_removed == 0 and all_stayed == 0,
			'remove_all reports it: ' .. tostring(all_why)
		)
		check(row_count(u) == 5 and q:info('q1').state == 'ours', 'and leaves both rows')
		check(q:remove('q1') == true and p:remove('p1') == true and snapshot(u) == before_u, 'the newer owner goes first, then the older')
		deferred = deferred + 4
		q:row('q2', u.block, u.records[1], 'kq2')
		p:row('p2', u.block, u.records[1], 'kp2')
		check(p:remove_all() == true and q:info('q2').state == 'ours' and row_count(u) == 4, "an owner's restore leaves another owner's row alone")
		check(key_index(u, 'kq2') == 3 and key_index(u, 'kp2') == nil, 'its key is still there')
		check(q:remove_all() == true and snapshot(u) == before_u, 'and the other owner restores its own')
		deferred = deferred + 4

		check(refusal(p:row('bad', mr.game_alloc(64), u.records[1], 'zz')) == 'not a database table', 'a block of zeros is not a table')
		check(refusal(p:row('bad', nil, u.records[1], 'zz')) == 'not a database table', 'NULL is not a table')
		local other_table = make_table({ 'a' }, 4)
		mr.write(other_table.vtable, 16, mr.add(size_function, 2))
		check(
			refusal(p:row('bad', other_table.block, other_table.records[1], 'zz')) == 'not a database table',
			'a vtable without the record size function is not a table'
		)
		check(refusal(p:row('bad', u.block, mr.game_alloc(32), 'zz')) == 'the template is not a row of this table', 'the template must be a row of the table')
		check(refusal(p:row('bad', u.block, nil, 'zz')) == 'the template is not a row of this table', 'NULL is no template')
		check(refusal(p:row('bad', u.block, u.records[1], 'a')) == 'key exists', 'an existing key')
		local KEY = 'the key must be 1 to 255 bytes without a zero byte'
		check(
			refusal(p:row('bad', u.block, u.records[1], '')) == KEY and refusal(p:row('bad', u.block, u.records[1], ('x'):rep(256))) == KEY,
			'empty and long keys'
		)
		check(refusal(p:row('bad', u.block, u.records[1], 'a\0b')) == KEY, 'a key with a zero byte')
		check(p:row('long', u.block, u.records[1], ('x'):rep(255)) ~= nil and p:remove('long') == true, 'a key of 255 bytes works')
		deferred = deferred + 2
		check(not pcall(p.row, p, 'bad', u.block, u.records[1], {}), 'a key that is not text raises')
		check(not pcall(p.row, p, 'bad', u.block, u.records[1], 'zz', 5), 'edits that are not a table raise')
		local function bad_edits(edits)
			return select(2, p:row('bad', u.block, u.records[1], 'zz', edits))
		end
		check(bad_edits({ [0] = 'x' }) == 'an edit offset must be a whole number from 8 to the end of the record', 'the vtable cannot be edited')
		check(bad_edits({ [0x20] = 'x' }) == 'an edit offset must be a whole number from 8 to the end of the record', 'offsets stop at the record end')
		check(bad_edits({ [8.5] = 'x' }) == 'an edit offset must be a whole number from 8 to the end of the record', 'offsets are whole')
		check(bad_edits({ x = 'x' }) == 'edits are keyed by the offset in the record', 'edits are keyed by offsets')
		check(bad_edits({ [8] = 5 }) == 'an edit takes a typed value or a string', 'a Lua number is not a value')
		check(bad_edits({ [0x10] = ('x'):rep(17) }) == 'an edit does not fit in the record', 'a long edit is refused')
		check(bad_edits({ [8] = u.targets[1], [0xC] = mr.uint32(1) }) == 'edits overlap', 'overlapping edits')
		check(bad_edits({ [8] = '' }) == 'an edit does not fit in the record', 'an empty edit')
		local wide_size = mr.game_alloc(8)
		mr.write(wide_size, 0, '\184\0\1\0\0\195\0\0')
		local wide_vtable = mr.game_alloc(24)
		mr.write(wide_vtable, 16, wide_size)
		local wide = make_table({ 'a' }, 8)
		local wide_record = mr.game_alloc(0x100)
		mr.write(wide_record, 0, record_vtable)
		mr.write(wide.block, 0, wide_vtable)
		mr.write(mr.read_pointer(wide.block, 16), 0, wide_record)
		local edits, expected = {}, {}
		for offset = 8, 135 do
			edits[offset] = string.char(offset)
			expected[#expected + 1] = string.char(offset)
		end
		local wide_row = p:row('wide_row', wide.block, wide_record, 'w', edits)
		check(wide_row ~= nil and mr.read(wide_row, 8, 128) == table.concat(expected), '128 edits are applied')
		edits[136] = 'x'
		check(select(2, p:row('wide_more', wide.block, wide_record, 'w2', edits)) == 'at most 128 edits', '129 edits are refused')
		check(p:remove('wide_row') == true, 'the row with 128 edits is removed')
		deferred = deferred + 2
		check(snapshot(u) == before_u and #mr.patch_list('rows_a') == 0 and row_count(u) == 3, 'refusals change nothing')
		check(p:patch('dup', mr.add(filler, 0x300), '\0\0\0\0', '\1\0\0\0') == true, 'a patch takes a name')
		check(refusal(p:row('dup', u.block, u.records[1], 'zz')) == DIFFERENT, 'a row cannot use the name of another kind')
		check(p:remove('dup') == true and snapshot(u) == before_u, 'removed')

		local big = make_table({ 'a' }, 4200)
		local added, refused_growth = 0, nil
		for i = 1, 4200 do
			local rows = mr.capacity().rows
			if refused_growth == nil and rows.used == rows.room and rows.room >= 16 then
				local count_before = row_count(big)
				test_fail_memory('heap', mr.hop_slots)
				refused_growth = refusal(p:row('grow_' .. i, big.block, big.records[1], 'g' .. i)) == 'full'
					and row_count(big) == count_before
					and p:info('grow_' .. i) == nil
			end
			if p:row('f' .. i, big.block, big.records[1], 'f' .. i) then added = added + 1 end
		end
		check(refused_growth == true, 'a refused growth of the row table answers full and changes nothing')
		check(added == 4096 and refusal(p:row('f4097', big.block, big.records[1], 'f4097')) == 'full', 'at most 4096 rows: ' .. added)
		local rows = mr.capacity().rows
		check(rows.used == 4096 and rows.room == 4096 and rows.limit == 4096, 'the row table says 4096 of 4096')
		check(select(2, p:remove_all()) == 4096 and row_count(big) == 1, 'and all of them come back, whatever the order of their slots')
		deferred = deferred + 8192

		local lost = make_table({ 'a' }, 8)
		local lost_before, lost_live = snapshot(lost), live()
		test_fail_emplace(1)
		check(refusal(p:row('lost', lost.block, lost.records[1], 'zz')) == 'key exists', 'a key the game insert did not take is a refusal')
		check(snapshot(lost) == lost_before and p:info('lost') == nil, 'the append was rolled back and nothing was registered')
		check(live() == lost_live + 1, 'the record waits for the mode switch to be freed')
		deferred = deferred + 1
		check(p:row('lost', lost.block, lost.records[1], 'zz') ~= nil and p:remove('lost') == true and snapshot(lost) == lost_before, 'and the next call works')
		deferred = deferred + 2

		local moved = make_table({ 'a', 'b' }, 8)
		local moved_before = snapshot(moved)
		local mrec = p:row('moved', moved.block, moved.records[1], 'mv')
		local old_vtable, other_vtable = mr.read_pointer(moved.block, 0), mr.game_alloc(24)
		local row_bytes = mr.read(mr.read_pointer(moved.block, 16), 16, 8)
		mr.write(other_vtable, 16, size_function)
		mr.write(moved.block, 0, other_vtable)
		check(
			p:info('moved').state == 'missing' and refusal(p:remove('moved')) == 'the table changed',
			'a table with another vtable is missing, the remove is refused'
		)
		mr.write(moved.block, 0, old_vtable)
		check(p:info('moved').state == 'ours', 'and ours again when it is back')
		mr.vector_insert(moved.block, 8, 8, 4)
		check(refusal(p:remove('moved')) == 'rows were added after it', 'a raw element after the row blocks the remove')
		mr.vector_erase(moved.block, 8, 8, 4)
		mr.vector_erase(moved.block, 8, 8, 3)
		check(p:info('moved').state == 'missing' and refusal(p:remove('moved')) == 'the row is not in the table', 'a row the game dropped is missing')
		check(#mr.patch_list('rows_a') == 1, 'the item stays listed')
		check(refusal(p:row('moved', moved.block, moved.records[1], 'mv')) == DIFFERENT, 'and repeating its call does not claim it is there')
		mr.vector_insert(moved.block, 8, 8, 3, row_bytes)
		check(p:remove('moved') == true and snapshot(moved) == moved_before, 'put back by hand, it can be removed')
		deferred = deferred + 2

		local keep = p:row('keep', u.block, u.records[1], 'kk', { [0x18] = u.targets[3] })
		local live_end = live()
		local file = assert(io.open(STATE_FILE, 'wb'))
		file:write(table.concat({
			mr.tostring(u.block),
			mr.tostring(keep),
			mr.tostring(u.records[1]),
			mr.tostring(u.targets[3]),
			before_u,
			tostring(live_end - deferred - entry_live),
			tostring(entry_live),
		}, '\n'))
		file:close()
		NEXT_PASS = failures == 0
	else
		local lines = {}
		for line in assert(io.open(STATE_FILE, 'rb')):lines() do
			lines[#lines + 1] = line
		end
		local u = { block = pointer_from_text(lines[1]) }
		u.map = mr.add(u.block, KEYS)
		local keep, template, target = pointer_from_text(lines[2]), pointer_from_text(lines[3]), pointer_from_text(lines[4])
		local before_u, permanent, first_entry = lines[5], tonumber(lines[6]), tonumber(lines[7])
		check(
			entry_live - first_entry == permanent,
			'after the mode switch every deferred block is freed and nothing else: ' .. (entry_live - first_entry) .. ' vs ' .. permanent
		)
		local p = mr.patcher('rows_a')
		check(#mr.patch_list('rows_a') == 1 and p:info('keep').state == 'ours' and mr.eq(p:info('keep').at, keep), 'the registry survives the mode switch')
		check(p:info('keep').key == 'kk' and p:info('keep').row == 3 and key_index(u, 'kk') == 3, 'with its key and row')
		local again, again_row = p:row('keep', u.block, template, 'kk', { [0x18] = target })
		check(mr.eq(again, keep) and again_row == 3 and row_count(u) == 4, 'the same call in the new mode is a no-op')
		fill_crash_context(mr)
		set_report_settings(mr)
		local name = mr.write_runtime_report()
		check(type(name) == 'string' and exists(name), 'a runtime report is written: ' .. tostring(name))
		local text = read_all(name)
		check(has(text, '  rows_a: 1 row\n'), 'the owner block counts the row')
		local before_remove = live()
		check(p:remove('keep') == true and row_count(u) == 3 and key_index(u, 'kk') == nil, 'the new mode removes the row by name')
		check(snapshot(u) == before_u, 'the table is as it was before the row')
		check(live() == before_remove, 'and the record and the key node wait for the next switch')
	end
elseif SCENARIO == 'sites' then
	local logged = {}
	ModLog = function(message)
		logged[#logged + 1] = message
		print('  log: ' .. message)
	end
	run_mod(OURS)
	local mr = _G.memreader_plus
	local MIXED = 'double(int64, double, float, int32, int8, double)'
	local function address(name)
		return mr.pointer(test_function(name))
	end
	local function contains(text, part)
		return type(text) == 'string' and string.find(text, part, 1, true) ~= nil
	end
	local cell = mr.alloc(8)
	local function raw(pointer)
		mr.write(cell, 0, pointer)
		return mr.read(cell, 0, 8)
	end
	local function hex_of(at, size)
		local bytes, parts = mr.read(at, 0, size), {}
		for i = 1, size do
			parts[i] = string.format('%02X', bytes:byte(i))
		end
		return table.concat(parts, ' ')
	end
	local function unique(pattern)
		local _, count = mr.find_pattern(pattern)
		return count == 1
	end
	local function page_of(at)
		return math.floor(tonumber(mr.tostring(at):sub(-8), 16) / 4096)
	end
	local function rows(owner)
		local found = {}
		for _, row in ipairs(mr.patch_list(owner)) do
			found[row.name] = row
		end
		return found
	end
	local lines = {}
	local function log(line)
		lines[#lines + 1] = line
	end
	local function said(part)
		for _, line in ipairs(lines) do
			if contains(line, part) then return true end
		end
		return false
	end
	local function pick(names, size, avoid)
		for _, name in ipairs(names) do
			local at = address(name)
			if unique(hex_of(at, size)) and page_of(at) ~= avoid then return name, at end
		end
	end
	local function flipped(at, offset, size)
		local first = string.format('%02X', mr.read(at, offset, 1):byte() % 255 + 1)
		return size > 1 and first .. ' ' .. hex_of(mr.add(at, offset + 1), size - 1) or first
	end

	for _, line in ipairs(logged) do
		check(not contains(line, 'sites module'), 'the loader logged no failure to load the sites module')
	end
	check(type(mr.patcher) == 'function' and _G.memreader.patcher == mr.patcher, 'the loader leaves one patcher function')
	local p, q = mr.patcher('sites_mod'), mr.patcher('sites_other')
	check(type(p.sites) == 'function' and p:owner() == 'sites_mod', 'a handle has sites, and still names its owner')
	check(q.sites == p.sites, 'one sites method serves every handle')
	local nothing, problem = mr.patcher('two words')
	check(nothing == nil and problem ~= nil, 'a bad owner is refused as before: ' .. tostring(problem))
	local empty = p:sites({}, log)
	check(
		empty.report() == '' and empty.feature_ok('anything') == false and empty.found('anything') == false,
		'an empty table gives an object with the whole API'
	)
	local missing_api = {}
	for name in ('found why feature_ok address value install install_feature set remove disable cave_value log_missing report'):gmatch('%S+') do
		if type(empty[name]) ~= 'function' then missing_api[#missing_api + 1] = name end
	end
	check(#missing_api == 0 and empty.heal == nil, 'the API is the old one without heal: ' .. table.concat(missing_api, ' '))
	local bad = p:sites({ 5, { name = 'x' }, { name = 'ok', feature = 'f', kind = 'anchor', pattern = 'zz' } }, log)
	bad.log_missing()
	check(
		bad.report() == 'entry 1=missing,x=missing,ok=missing'
			and said('ok not found (bad entry: bad pattern): f off')
			and said('x not found (bad entry: no feature)'),
		'bad entries switch themselves off with a log line'
	)
	check(p:sites(nil, log).report() == '', 'no table at all is an empty table')

	local prologue = address('prologue_target')
	local cave_at = address('cave_target')
	local patch_name, patch_at = pick({ 'leaf_add_one', 'site_single', 'leaf_add_floats' }, 32, page_of(cave_at))
	test_fill_mixed(163840)
	local put_b_at = mr.add(address('mixed_code'), 0x2000)
	local value_name, value_at, value_offset = nil, nil, 0
	for _, name in ipairs({
		'all_bits',
		'is_positive',
		'multiply_floats',
		'add_integers',
		'mix',
		'eight_digits',
		'sixteen',
		'divide',
		'recurse',
		'callback',
		'store',
	}) do
		local at = address(name)
		for offset = 4, 24 do
			if not value_name and unique(hex_of(at, 32)) and math.abs(mr.read_int32(at, offset)) < 100000 then
				value_name, value_at, value_offset = name, at, offset
			end
		end
	end
	local reloc_name, reloc_at = pick({ 'hook_store' }, 32, nil)
	local mixed, here, xmm = address('hook_mixed'), address('site_single_here'), address('frame_xmm_target')
	local park_frame, park_grow, left_at = address('park_frame'), address('park_grow'), address('hook_target')
	check(
		patch_name and value_name and reloc_name,
		'unused host functions with unique code serve as targets: ' .. tostring(patch_name) .. ' ' .. tostring(value_name) .. ' ' .. tostring(reloc_name)
	)
	check(
		unique(hex_of(prologue, 32)) and unique(hex_of(cave_at, 24)) and unique(hex_of(mixed, 40)) and unique(hex_of(here, 24)) and unique(hex_of(xmm, 24)),
		'and so do the function the code runs and the cave, link, site and frame targets'
	)

	local first_number = mr.read_int32(value_at, value_offset)
	local entries = {
		{ name = 'ptch', feature = 'f_patch', kind = 'patch', pattern = hex_of(prologue, 32), at = 5, expect = '01 00 00 00', bytes = '02 00 00 00' },
		{
			name = 'pair_patch',
			feature = 'f_pair',
			kind = 'patch',
			pattern = hex_of(patch_at, 32),
			at = 12,
			expect = hex_of(mr.add(patch_at, 12), 1),
			bytes = flipped(patch_at, 12, 1),
		},
		{ name = 'pair_cave', feature = 'f_pair', kind = 'cave', pattern = hex_of(cave_at, 24), at = 0, expect = hex_of(cave_at, 5), bytes = '90 {extra:1}' },
		{
			name = 'cap',
			feature = 'f_cap',
			kind = 'value',
			pattern = hex_of(value_at, 32),
			at = value_offset,
			before = 2,
			expect = hex_of(mr.add(value_at, value_offset - 2), 2),
			size = 4,
			low = first_number - 1000,
			high = first_number + 1000,
		},
		{ name = 'twin_frame', feature = 'f_planner', kind = 'frame', pattern = hex_of(xmm, 24), at = 0, grow = 0x360 },
		{
			name = 'target_sites',
			feature = 'f_planner',
			kind = 'relocate',
			pattern = hex_of(reloc_at, 32),
			sites = {
				{ at = 8, expect = hex_of(mr.add(reloc_at, 8), 4), bytes = flipped(reloc_at, 8, 4) },
				{ at = 16, expect = hex_of(mr.add(reloc_at, 16), 4), bytes = flipped(reloc_at, 16, 4) },
			},
		},
		{
			name = 'link_pre',
			feature = 'f_links',
			kind = 'prefix',
			pattern = hex_of(mixed, 40),
			at = 0,
			expect = hex_of(mixed, 6),
			signature = MIXED,
			priority = 10,
		},
		{ name = 'link_post', feature = 'f_links', kind = 'postfix', pattern = hex_of(mixed, 40), at = 0, expect = hex_of(mixed, 6), signature = MIXED },
		{
			name = 'link_around',
			feature = 'f_links',
			kind = 'around',
			pattern = hex_of(mixed, 40),
			at = 0,
			expect = hex_of(mixed, 6),
			signature = MIXED,
			priority = 5,
		},
		{ name = 'link_hook', feature = 'f_links', kind = 'hook', pattern = hex_of(mixed, 40), at = 0, expect = hex_of(mixed, 6), signature = MIXED },
		{
			name = 'late_sites',
			feature = 'f_late',
			kind = 'relocate',
			pattern = hex_of(reloc_at, 32),
			sites = { { at = 24, expect = hex_of(mr.add(reloc_at, 24), 4), bytes = flipped(reloc_at, 24, 4) } },
		},
		{
			name = 'busy_reloc',
			feature = 'f_busy',
			kind = 'relocate',
			pattern = hex_of(park_frame, 24),
			sites = { { at = 2, expect = '01 00 00 00', bytes = '02 00 00 00' } },
		},
		{ name = 'busy_frame', feature = 'f_busy_frame', kind = 'frame', pattern = hex_of(park_grow, 24), at = 0, grow = 0x100 },
		{ name = 'left_cave', feature = 'f_left_busy', kind = 'cave', pattern = hex_of(left_at, 24), at = 0, expect = hex_of(left_at, 5), bytes = '90' },
		{ name = 'left_frame', feature = 'f_left_busy', kind = 'frame', pattern = hex_of(park_grow, 24), at = 0, grow = 0x200 },
		{
			name = 'put_a',
			feature = 'f_put',
			kind = 'patch',
			pattern = hex_of(patch_at, 32),
			at = 16,
			expect = hex_of(mr.add(patch_at, 16), 1),
			bytes = flipped(patch_at, 16, 1),
		},
		{
			name = 'put_b',
			feature = 'f_put',
			kind = 'patch',
			pattern = hex_of(put_b_at, 32),
			at = 18,
			expect = hex_of(mr.add(put_b_at, 18), 1),
			bytes = flipped(put_b_at, 18, 1),
		},
		{ name = 'site_one', feature = 'f_site', kind = 'site', pattern = hex_of(here, 24), at = 0, expect = hex_of(here, 5) },
	}

	local native = p:sites(entries, log)
	for _, entry in ipairs(entries) do
		check(native.found(entry.name), entry.name .. ' is found: ' .. tostring(native.why(entry.name)))
	end
	check(native.feature_ok('f_pair') and native.feature_ok('f_links') and not native.feature_ok('f_nothing'), 'features are ok when every entry is found')
	check(mr.eq(native.address('ptch'), mr.add(prologue, 5)), 'an address is match plus at')

	local WRONG = '\255\255\255\255'
	local ok, why = p:batch({ { 'patch', 'pin_a', mr.add(prologue, 5), WRONG, WRONG } })
	check(ok == nil and why == 'pin_a: unexpected bytes', 'a batch refusal reads <name>: <reason>, which the installer parses: ' .. tostring(why))
	ok, why = p:batch({ { 'patch', 'pin_a', mr.add(prologue, 5), '\1\0\0\0', '\2\0\0\0' }, { 'patch', 'pin_b', mr.add(prologue, 6), WRONG, WRONG } })
	check(ok == nil and why == 'pin_b: unexpected bytes', 'and names the failing step in a longer batch: ' .. tostring(why))
	check(#mr.patch_list('sites_mod') == 0 and mr.read_int32(prologue, 5) == 1, 'and writes and registers nothing')

	check(native.install('ptch') == true, 'a patch entry installs')
	check(mr.tonumber(mr.call(prologue, 'int32()')) == 2, 'the code runs the new bytes')
	local listed = rows('sites_mod')
	check(
		listed.ptch and listed.ptch.kind == 'patch' and listed.ptch.owner == 'sites_mod' and listed.ptch.state == 'ours',
		'and is listed under its name, owner and kind'
	)
	check(native.report():find('ptch=ours', 1, true) ~= nil, 'the report says ours')
	check(native.install('ptch') == true and #mr.patch_list('sites_mod') == 1, 'installing again changes nothing')
	check(native.remove('ptch') == true and mr.tonumber(mr.call(prologue, 'int32()')) == 1, 'remove puts the old bytes back')
	check(native.install('ptch') == true, 'and the patch can be made again')

	local patched_old = mr.read(patch_at, 12, 1)
	q:patch('theirs', mr.add(patch_at, 12), patched_old, patched_old)
	local refuser = p:sites(entries, log)
	ok, why = refuser.install_feature('f_pair', { pair_cave = { extra = 144 } })
	check(ok == false and mr.hook_info(cave_at) == nil, 'a batch that Plus refuses while checking writes nothing, not even the cave: ' .. tostring(why))
	check(
		contains(refuser.why('pair_patch'), 'held by sites_other/theirs') and not refuser.feature_ok('f_pair'),
		'the failing entry is named and the feature is off: ' .. tostring(refuser.why('pair_patch'))
	)
	check(rows('sites_mod').pair_cave == nil and rows('sites_mod').pair_patch == nil, 'and no row exists for either')
	check(not said('left in place'), 'a refusal leaves nothing to report')
	check(q:remove('theirs') == true, 'the other owner lets go')

	local failing = p:sites(entries, log)
	test_fail_protect(raw(mr.add(patch_at, 12)), 1, mr.hop_slots)
	ok, why = failing.install_feature('f_pair', { pair_cave = { extra = 144 } })
	check(ok == false and not failing.feature_ok('f_pair'), 'a write that fails after the cave was made turns the feature off: ' .. tostring(why))
	check(mr.read(patch_at, 12, 1) == patched_old, 'and the patch is not written')
	check(
		mr.hook_info(cave_at) and mr.hook_info(cave_at).kind == 'cave' and rows('sites_mod').pair_cave and rows('sites_mod').pair_cave.state == 'stays',
		'the cave stays, owned and named'
	)
	check(said('left in place: pair_cave'), 'one line says what was left in place')
	check(
		failing.report():find('pair_patch=missing', 1, true) ~= nil and failing.report():find('pair_cave=ours', 1, true) ~= nil,
		'the report says missing and ours: ' .. failing.report()
	)
	local before_retry, line_count = #mr.patch_list('sites_mod'), #lines
	check(
		failing.install_feature('f_pair', { pair_cave = { extra = 144 } }) == false and #mr.patch_list('sites_mod') == before_retry,
		'the failed feature is not tried again'
	)
	check(mr.read(patch_at, 12, 1) == patched_old and #lines == line_count, 'and nothing is written or said by the retry')

	local again = p:sites(entries, log)
	check(
		again.found('pair_cave') and again.install_feature('f_pair', { pair_cave = { extra = 144 } }) == true,
		'a later object takes the left cave as its own and finishes the feature'
	)
	check(mr.read(patch_at, 12, 1) ~= patched_old and rows('sites_mod').pair_patch.state == 'ours', 'the patch goes in')
	check(again.cave_value('pair_cave', 'extra') == 144, 'cave_value reads the argument back')

	check(again.install_feature('f_planner') == true, 'a frame and a relocation install as one batch')
	listed = rows('sites_mod')
	check(
		listed.twin_frame
			and listed.twin_frame.kind == 'frame'
			and listed.target_sites
			and listed.target_sites.kind == 'relocate'
			and listed.target_sites.state == 'stays',
		'both are listed under their kinds'
	)
	check(
		mr.read(reloc_at, 8, 4) ~= mr.read_original(reloc_at, 8, 4) and mr.read(reloc_at, 16, 4) ~= mr.read_original(reloc_at, 16, 4),
		'the relocation bytes are written'
	)
	check(
		again.remove('twin_frame') == false and select(2, again.remove('target_sites')) == 'stays for the session',
		'frames and relocations stay for the session'
	)

	local function number()
		return mr.read_int32(value_at, value_offset)
	end
	check(again.set('cap', first_number + 10) == true and number() == first_number + 10, 'a value entry writes its number')
	check(again.set('cap', first_number + 20) == true and number() == first_number + 20, 'and takes another')
	check(again.set('cap', first_number + 100000) == false and number() == first_number + 20, 'a number outside low and high is refused')
	check(rows('sites_mod').cap and rows('sites_mod').cap.kind == 'value' and rows('sites_mod').cap.state == 'ours', 'the value is listed')
	check(again.remove('cap') == true and number() == first_number, 'remove puts the old number back')

	local trace = {}
	local inside, late = nil, nil
	local callbacks = {
		link_pre = function(call)
			trace[#trace + 1] = 'pre'
			call:set(6, 10)
			call:set(3, 4)
			inside = { again.install('site_one', function() end) }
			late = { again.install_feature('f_late') }
		end,
		link_around = function(game, ...)
			trace[#trace + 1] = 'around<'
			local result = game(...)
			trace[#trace + 1] = 'around>'
			return result
		end,
		link_hook = function(game, ...)
			trace[#trace + 1] = 'hook<'
			local result = game(...)
			trace[#trace + 1] = 'hook>'
			return result
		end,
		link_post = function()
			trace[#trace + 1] = 'post'
		end,
	}
	check(again.install_feature('f_links', callbacks) == true, 'five link kinds install as one feature')
	check(mr.call(mixed, MIXED, 1, 2, 3, 4, -5, 6) == 124360, 'the function answers through the links')
	check(table.concat(trace, ' ') == 'pre around< hook< hook> around> post', 'links run by priority, then registration: ' .. table.concat(trace, ' '))
	check(
		inside ~= nil and inside[1] == false and inside[2] == 'not from inside a hooked call',
		'an install from inside a hooked call is refused: ' .. tostring(inside and inside[2])
	)
	check(again.found('site_one') and again.report():find('site_one=vanilla', 1, true) ~= nil, 'and the entry is not marked by it')
	check(
		late ~= nil and late[1] == false and late[2] == 'not from inside a hooked call',
		'a relocation install from inside a hooked call is refused too: ' .. tostring(late and late[2])
	)
	check(again.found('late_sites') and again.report():find('late_sites=vanilla', 1, true) ~= nil, 'and its entry is not marked missing by it')
	listed = rows('sites_mod')
	check(
		listed.link_pre
			and listed.link_pre.kind == 'prefix'
			and listed.link_post.kind == 'postfix'
			and listed.link_around.kind == 'around'
			and listed.link_hook.kind == 'around',
		'links are listed under their kinds, hook as around'
	)
	check(again.install_feature('f_late') == true and rows('sites_mod').late_sites ~= nil, 'the same relocation installs outside a call')
	check(again.install('site_one', function() end) == true and mr.hook_info(here) ~= nil, 'a site entry installs outside a call')

	trace = {}
	local rest = p:sites(entries, log)
	check(rest.install_feature('f_links', callbacks) == true, 'a second object over installed links installs without error')
	mr.call(mixed, MIXED, 1, 2, 3, 4, -5, 6)
	check(table.concat(trace, ' ') == 'pre around< hook< hook> around> post', 'and the links do not run twice: ' .. table.concat(trace, ' '))
	check(rest.remove('link_hook') == true and rows('sites_mod').link_hook == nil, 'remove detaches one link')

	local other = p:sites(
		{ { name = 'lone', feature = 'f_lone', kind = 'prefix', pattern = entries[7].pattern, at = 0, expect = entries[7].expect, signature = 'int32(int32)' } },
		log
	)
	ok, why = other.install('lone', function() end)
	check(ok == false and why ~= nil and other.why('lone') == why, 'a link with another signature is refused and the entry is off: ' .. tostring(why))
	other.log_missing()
	check(said('lone not found'), 'and logged once')
	check(not said('heal'), 'nothing mentions heal any more')

	local put = p:sites(entries, log)
	local put_old = mr.read(patch_at, 16, 1)
	test_relock(raw(mr.add(put_b_at, 18)), mr.hop_slots, raw(mr.add(patch_at, 16)))
	ok, why = put.install_feature('f_put')
	check(
		ok == false and contains(why, 'put_b: failed to patch memory, and 1 write could not be put back'),
		'a write that cannot be put back fails the feature: ' .. tostring(why)
	)
	check(
		mr.read(patch_at, 16, 1) ~= put_old and rows('sites_mod').put_a and rows('sites_mod').put_a.state == 'stays',
		'the first write stays in the code and Plus lists it'
	)
	check(
		put.report():find('put_a=missing', 1, true) ~= nil and put.report():find('put_b=missing', 1, true) ~= nil,
		'and the report names both entries missing, not vanilla: ' .. put.report()
	)

	local busy = p:sites(entries, log)
	local park_before = mr.read(park_frame, 2, 4)
	check(test_park_start(test_function('park_frame')), 'a thread spins in park_frame, outside the bytes of a relocation')
	ok, why = busy.install_feature('f_busy')
	check(ok == false and why == 'a thread is inside sites_mod/busy_reloc', 'a parked thread refuses the feature batch: ' .. tostring(why))
	check(busy.found('busy_reloc') and busy.feature_ok('f_busy') and busy.why('busy_reloc') == nil, 'the entry stays found, with no reason')
	check(busy.report():find('busy_reloc=vanilla', 1, true) ~= nil, 'and the report says vanilla, not missing')
	busy.log_missing()
	check(
		not said('busy_reloc not found') and mr.read(park_frame, 2, 4) == park_before and rows('sites_mod').busy_reloc == nil,
		'nothing is logged as missing, written or registered'
	)
	test_park_leave_on_retry(mr.hop_slots)
	check(busy.install_feature('f_busy') == true and test_park_left(), 'the same install succeeds once the thread leaves')
	check(
		test_park_finish() == 78 and mr.read(park_frame, 2, 4) == '\2\0\0\0' and rows('sites_mod').busy_reloc.state == 'stays',
		'the relocation is written and owned'
	)

	check(test_park_start(test_function('park_grow')), 'a thread spins in park_grow, a function with a frame')
	ok, why = busy.install_feature('f_busy_frame')
	check(ok == false and why == 'a thread is inside the function', 'a parked thread refuses a lone frame step too: ' .. tostring(why))
	check(
		busy.found('busy_frame') and busy.feature_ok('f_busy_frame') and busy.report():find('busy_frame=vanilla', 1, true) ~= nil,
		'and the frame entry stays found'
	)
	ok, why = busy.install_feature('f_left_busy')
	check(
		ok == false and why == 'left_frame: a thread is inside the function',
		'a feature with a cave and a frame is refused in the frame step: ' .. tostring(why)
	)
	check(said('left in place: left_cave') and mr.hook_info(left_at) and mr.hook_info(left_at).kind == 'cave', 'the cave it made stays and is logged')
	check(not busy.found('left_frame') and not busy.feature_ok('f_left_busy'), 'a feature with a cave left behind keeps the rule: it is off')
	check(busy.install_feature('f_left_busy') == false, 'and it is not tried again')
	test_park_leave_on_retry(mr.hop_slots)
	check(busy.install_feature('f_busy_frame') == true and test_park_left(), 'the lone frame installs once the thread leaves')
	check(test_park_finish() == 79 and rows('sites_mod').busy_frame.state == 'stays', 'and is owned')

	local source_at = address('host_source')
	local SOURCE = 'int64(pointer, pointer, pointer, int32, uint8)'
	local when_entries = {
		{
			name = 'when_around',
			feature = 'f_when',
			kind = 'around',
			pattern = hex_of(source_at, 32),
			signature = SOURCE,
			when = { arg = 2, reads = { 16 } },
		},
		{ name = 'when_plain', feature = 'f_when_plain', kind = 'prefix', pattern = hex_of(source_at, 32), signature = SOURCE },
		{ name = 'when_site', feature = 'f_when_site', kind = 'site', pattern = 'AA', expect = '90 90 90 90 90', when = { arg = 1 } },
	}
	check(unique(hex_of(source_at, 32)), 'the host function for the when entries has a unique pattern')
	check(mr.supports.link_when == true, 'sites.attach sets supports.link_when')
	local function when_object()
		return mr.patcher('when_mod'):sites(when_entries, log)
	end
	local when_fn = function(game)
		return game()
	end
	local member_set = mr.pointer_set()
	local member_key, other_key = mr.alloc(16), mr.alloc(16)
	local member_source, other_source = mr.alloc(32), mr.alloc(32)
	mr.write(member_source, 16, member_key)
	mr.write(other_source, 16, other_key)
	member_set:fill({ member_key })
	local function source_call(source)
		return mr.tonumber(mr.call(source_at, SOURCE, member_key, source, member_key, 3, 5))
	end
	local when_sites = when_object()
	check(when_sites.found('when_around') and when_sites.found('when_plain'), 'entries with and without when are found')
	local installed, reason = when_sites.install('when_around', when_fn)
	check(installed == false and reason == 'no set for when', 'a plain function on an entry with when is refused: ' .. tostring(reason))
	when_sites = when_object()
	installed, reason = when_sites.install('when_around', { fn = when_fn })
	check(installed == false and reason == 'no set for when', 'and so is a table without a set: ' .. tostring(reason))
	when_sites = when_object()
	installed, reason = when_sites.install('when_plain', { fn = when_fn, set = member_set })
	check(installed == false and reason == 'set given but the entry has no when', 'a set for an entry without when is refused: ' .. tostring(reason))
	check(mr.hook_info(source_at) == nil and #mr.patch_list('when_mod') == 0, 'the refusals hook nothing')
	when_sites = when_object()
	check(when_sites.install('when_around', { fn = when_fn, set = member_set }) == true, 'an entry with when installs with its function and set')
	local when_row = mr.patcher('when_mod'):info('when_around')
	check(
		when_row.kind == 'around' and when_row.when.arg == 2 and when_row.when.reads[1] == 16 and when_row.when.members == 1,
		'and the link has the filter: arg, offset, members'
	)
	check(source_call(member_source) == 35 and source_call(other_source) == 35, 'both calls give the original result')
	when_row = mr.patcher('when_mod'):info('when_around')
	check(when_row.calls == 1 and when_row.filtered == 1, 'the member ran the link and the other key was filtered')
	check(when_object().install('when_around', { fn = when_fn, set = member_set }) == true, 'a second object over the installed link installs without error')
	check(mr.patcher('when_mod'):info('when_around').calls == 1, 'and does not replace it')
	when_object().log_missing()
	check(said('when_site not found (bad entry: bad when): f_when_site off'), 'when on a site entry is a bad entry, off with a log line')
	mr.patcher('when_mod'):remove_all()

	assert(loadfile(ROOT .. '/tests/mp_agree_mock.lua'))()
	check(type(memreader_plus_agree) == 'function' and mr.agree == memreader_plus_agree, 'the loader exposes the agreement function on both names')
	H.configure({ mp = true, me = 'fac_a', cqi = 1, humans = { 'fac_a' }, names = { 'fac_a' }, host = false, synced = true, values = {} })
	local agree_owner = mr.patcher('agree_mod')
	local agree_entry = {
		name = 'cap',
		feature = 'caps',
		kind = 'value',
		pattern = hex_of(value_at, 32),
		at = value_offset,
		before = 2,
		expect = hex_of(mr.add(value_at, value_offset - 2), 2),
		size = 4,
		low = first_number - 1000,
		high = first_number + 1000,
	}
	local earlier = agree_owner:sites({ agree_entry }, log)
	check(earlier.set('cap', first_number + 7) == true and number() == first_number + 7, 'an earlier campaign wrote a value')
	local agreed = agree_owner:sites({ agree_entry }, log)
	local spec = { sites = agreed, features = { caps = 'same' }, options = { limit = 5 }, format = 1, title = 'Agree Mod', apply = H.apply_for('agree_mod') }
	check(memreader_plus_agree('agree_mod', spec) == true, 'agree takes a spec over the real sites object')
	check(number() == first_number and rows('agree_mod').cap == nil, 'the leftover of the earlier campaign is removed before the report')
	local refused, refusal = agreed.set('cap', first_number + 5)
	check(refused == false and refusal == 'waiting for the multiplayer agreement' and number() == first_number, 'a write before the agreement is refused')
	check(agreed.found('cap') and agreed.why('cap') == nil, 'and the entry stays found')
	local report = H.take_out()
	check(#report == 1 and #report[1][2] <= 255, 'one report message of at most 255 characters')
	H.deliver(report[1][1], report[1][2], 1)
	check(#H.applies == 1 and H.applies[1].on.caps == true and H.applies[1].values.limit == 5, 'the report completes the round and apply runs')
	check(agreed.set('cap', first_number + 5) == true and number() == first_number + 5, 'a write after the agreement goes through')
	check(agreed.ready('caps') == true and agreed.ready('caps', true) == true, 'ready sees an installed value')
	check(agreed.remove_feature('caps') == true and number() == first_number, 'remove_feature puts the held number back')
	check(agreed.found('cap') and rows('agree_mod').cap == nil, 'and the entry stays found')
	local ran = 0
	local function original_hex(at, size)
		local bytes, parts = mr.read_original(at, 0, size), {}
		for i = 1, size do
			parts[i] = string.format('%02X', bytes:byte(i))
		end
		return table.concat(parts, ' ')
	end
	local inert_sites = mr.patcher('inert_mod'):sites({
		{ name = 'inert_pre', feature = 'lk', kind = 'prefix', pattern = original_hex(mixed, 40), at = 0, expect = original_hex(mixed, 6), signature = MIXED },
		{
			name = 'inert_around',
			feature = 'lk',
			kind = 'around',
			pattern = original_hex(mixed, 40),
			at = 0,
			expect = original_hex(mixed, 6),
			signature = MIXED,
		},
	}, log)
	local function attach_links()
		local callbacks = {
			inert_pre = function()
				ran = ran + 1
			end,
			inert_around = function(game, ...)
				ran = ran + 100
				return game(...)
			end,
		}
		local attached, reason = inert_sites.install_feature('lk', callbacks)
		check(attached == true, 'prepare attaches the links of a shared feature: ' .. tostring(reason))
	end
	local inert_spec = {
		sites = inert_sites,
		features = { lk = 'same' },
		options = {},
		format = 1,
		title = 'Inert Mod',
		apply = H.apply_for('inert_mod'),
		prepare = attach_links,
	}
	check(memreader_plus_agree('inert_mod', inert_spec) == true, 'agree runs prepare')
	check(mr.call(mixed, MIXED, 1, 2, 3, 4, -5, 6) == 124360 and ran == 0, 'links attached by prepare are inert before the decision')
	local inert_report = H.take_out()
	H.deliver(inert_report[1][1], inert_report[1][2], 2)
	check(mr.call(mixed, MIXED, 1, 2, 3, 4, -5, 6) == 124360 and ran == 101, 'and run once the feature is on')
	H, cm, core, CampaignUI, common, UIComponent, find_uicomponent, uicomponent_descended_from, out, get_mct = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil

	print('  sites: ' .. #mr.patch_list('sites_mod') .. ' rows for sites_mod, ' .. #lines .. ' installer log lines')
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
		filesystem_lookup = function(folder, pattern)
			if has(folder, '/releases/') then return vfs_lookup(folder, pattern) end
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

		local switch = assert(loadfile('/script/memreader_plus/' .. RELEASE .. '/file_edit_switch'))()
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
		if path ~= '/script/memreader_plus/' .. RELEASE .. '/bin' then return plain_loadfile(path) end
		if bin_missing then return nil, 'no such file' end
		return function()
			return bin
		end
	end
	local function run_loader()
		_G.memreader_plus_load_error = nil
		return assert(real_loadfile(LOADER))(ModLog, RELEASE)
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
elseif SCENARIO == 'newest_wins_single' then
	local logged = collect_log()
	local manager = fake_manager()
	local env = setmetatable({ cm = manager }, { __index = _G })
	run_entry(PASS == 1 and BOOT or ENTRY, env)
	local plus = _G.memreader_plus
	check(plus ~= nil and type(plus.plus_version) == 'string', 'Plus is loaded, pass ' .. PASS)
	check(
		count_logged(logged, ('[memreader_plus] releases found: %s; loading %s'):format(RELEASE, RELEASE)) == 1,
		'the boot logs the one release it found and loaded'
	)
	check(_G.memreader == plus, '_G.memreader is _G.memreader_plus')
	check(_G.memreader_plus_release == RELEASE, 'the loader records its release')
	check(count_logged(logged, 'loaded ' .. plus.plus_version) == 1, 'one loaded line')
	check(manager.numeric_locale_safe == true, 'the loader read cm from the environment of its entry')
	run_entry('script/_lib/mod/memreader.lua', env)
	check(count_logged(logged, 'loaded ' .. plus.plus_version) == 1 and _G.memreader == plus, 'a second entry reaches the shim and changes nothing')
	NEXT_PASS = PASS == 1 and failures == 0
elseif SCENARIO == 'newest_wins_two_releases' then
	local logged = collect_log()
	write_vfs('script/memreader_plus/releases/0_0_1.lua', "return '0_0_1'\n")
	write_vfs('script/memreader_plus/0_0_1/loader.lua', "local log = ...\nlog('[lower release] ran')\n")
	table.insert(VFS, 1, 'vfs')
	run_entry(BOOT)
	check(_G.memreader_plus ~= nil, 'the higher release loaded')
	check(
		count_logged(logged, ('releases found: 0_0_1, %s; loading %s'):format(RELEASE, RELEASE)) == 1,
		'both releases are listed and the higher one is loaded'
	)
	check(count_logged(logged, '[lower release] ran') == 0, 'the lower loader never ran')
elseif SCENARIO == 'newest_wins_old_bundle_first' then
	local logged = collect_log()
	local dll_writes = count_dll_writes()
	table.insert(VFS, 1, OLD_LAYOUT)
	local old_loader = loadfile('/script/memreader_plus/loader')
	check(old_loader and has(debug.getinfo(old_loader, 'S').source, 'v0_11_0'), 'the old loader holds the legacy path')
	run_lib_mod()
	local plus = _G.memreader_plus
	check(plus ~= nil and _G.memreader == plus, 'Plus is loaded')
	check(count_logged(logged, 'loaded ' .. plus.plus_version) == 1, 'one loaded line')
	check(count_logged(logged, 'loaded 0.11.0') == 0, 'no loaded 0.11.0 line')
	check(count_logged(logged, 'cannot write') == 0 and count_logged(logged, 'not loaded') == 0, 'no write or load failure is logged')
	check(dll_writes() == 1, 'the DLL is written once')
elseif SCENARIO == 'newest_wins_cpecific_after' then
	collect_log()
	run_entry(BOOT)
	local plus = _G.memreader_plus
	run_mod(THEIRS)
	check(plus ~= nil and _G.memreader == plus, "Cpecific's loader after the boot leaves _G.memreader at Plus")
	check(not exists('twwh3-memreader.dll'), "Cpecific's DLL was never written")
	_G.memreader = {}
	package.loaded['twwh3-memreader'] = {}
	package.loaded['twwh2-memreader'] = nil
	run_mod(OURS)
	check(
		_G.memreader == plus and package.loaded['twwh3-memreader'] == plus and package.loaded['twwh2-memreader'] == plus,
		'the legacy entry puts the Plus names back'
	)
elseif SCENARIO == 'newest_wins_stale_cache' then
	local logged = collect_log()
	local dll_writes = count_dll_writes()
	local served = {}
	local stale = {
		['/script/memreader_plus/loader'] = OLD_LAYOUT .. '/script/memreader_plus/loader.lua',
		['/script/memreader_plus/bin'] = OLD_LAYOUT .. '/script/memreader_plus/bin.lua',
		['/script/_lib/mod/memreader'] = OLD_LAYOUT .. '/script/_lib/mod/memreader.lua',
		['/script/_lib/mod/memreader_plus'] = OLD_LAYOUT .. '/script/_lib/mod/memreader_plus.lua',
	}
	local fresh_loadfile = loadfile
	loadfile = function(path)
		local key = path:gsub('%.lua$', '')
		if not stale[key] then return fresh_loadfile(path) end
		served[key] = (served[key] or 0) + 1
		return real_loadfile(stale[key])
	end
	run_lib_mod()
	local plus = _G.memreader_plus
	check(
		served['/script/memreader_plus/loader'] == 2 and served['/script/memreader_plus/bin'] == nil,
		'the cache served the old loader twice and never the old bin'
	)
	check(plus ~= nil and _G.memreader == plus, 'the new release is loaded')
	check(count_logged(logged, 'loaded ' .. plus.plus_version) == 1, 'one loaded line')
	check(count_logged(logged, 'cannot write') == 0 and count_logged(logged, 'not loaded') == 0, 'no write or load failure is logged')
	check(dll_writes() == 1, 'the DLL is written once')
	local bin = assert(fresh_loadfile('/script/memreader_plus/' .. RELEASE .. '/bin'))()
	check(read_all('twwh3-memreader_plus.dll') == bin.data, "the DLL on disk is the release's own")
elseif SCENARIO == 'newest_wins_no_lookup' then
	local logged = collect_log()
	common = {}
	run_entry(BOOT)
	common = nil
	run_entry(BOOT)
	common = {
		filesystem_lookup = function()
			error('boom', 0)
		end,
	}
	run_entry(BOOT)
	check(_G.memreader_plus == nil, 'Plus is not loaded without a release list')
	check(
		#logged == 3 and count_logged(logged, 'common.filesystem_lookup is missing') == 2 and count_logged(logged, 'listing the releases failed: boom') == 1,
		'one log line per start and no error escapes'
	)
	local loader = assert(real_loadfile(LOADER))
	check(loader(ModLog) == nil and _G.memreader_plus == nil, 'a loader started without an id returns nil')
	check(count_logged(logged, 'started without a release id') == 1 and _G.memreader_plus_release == nil, 'and says so in one log line')
elseif SCENARIO == 'newest_wins_failed_start' then
	local logged = collect_log()
	local dll_writes = count_dll_writes(true)
	local started = { listeners = 0, popups = 0 }
	local core = {
		is_campaign = function()
			return true
		end,
		is_frontend = function()
			return false
		end,
		add_listener = function()
			started.listeners = started.listeners + 1
		end,
	}
	local cm = {
		add_first_tick_callback = function()
			started.popups = started.popups + 1
		end,
	}
	local env = setmetatable({ core = core, cm = cm }, { __index = _G })
	table.insert(VFS, 2, OLD_LAYOUT)
	local shim = loadfile('/script/memreader_plus/loader')
	check(shim and not has(debug.getinfo(shim, 'S').source, 'v0_11_0'), 'the shim holds the legacy loader path, the old bundle is mounted below it')
	run_entry(BOOT, env)
	check(_G.memreader_plus == nil and count_logged(logged, 'not loaded: cannot write') == 1, 'the DLL write fails and Plus does not start')
	check(dll_writes() == 1 and started.listeners == 1 and started.popups == 1, 'the loader ran once: one write, one agree listener, one blocked-popup call')
	run_entry('script/_lib/mod/memreader.lua', env)
	run_entry('script/_lib/mod/memreader_plus.lua', env)
	check(dll_writes() == 1 and started.listeners == 1 and started.popups == 1, 'the legacy entries start nothing again')
	check(count_logged(logged, 'releases found') == 1 and count_logged(logged, 'not loaded') == 1, 'no second boot run and no second failure line')
	check(
		count_logged(logged, 'agreement module not loaded') == 0 and count_logged(logged, 'number format guard not installed') == 0,
		'the old loader never ran'
	)
elseif SCENARIO == 'newest_wins_frozen_boot' then
	local logged = collect_log()
	local manager = fake_manager()
	local env = setmetatable({ cm = manager }, { __index = _G })
	table.insert(VFS, 1, FROZEN_LAYOUT)
	local function source_of(path)
		return debug.getinfo(assert(loadfile(path)), 'S').source
	end
	check(
		has(source_of('/script/_lib/mod/!memreader_plus_boot'), 'v0_12_0') and has(source_of('/script/memreader_plus/loader'), 'v0_12_0'),
		'the frozen 0.12.0 boot and shim hold their paths'
	)
	run_entry(PASS == 1 and BOOT or ENTRY, env)
	local plus = _G.memreader_plus
	check(plus ~= nil and _G.memreader == plus and _G.memreader_plus_release == RELEASE, 'the current release loads through the frozen files, pass ' .. PASS)
	check(
		count_logged(logged, ('releases found: %s; loading %s'):format(RELEASE, RELEASE)) == 1 and count_logged(logged, 'loaded ' .. plus.plus_version) == 1,
		'one boot line and one loaded line'
	)
	check(manager.numeric_locale_safe == true, 'the current loader reads cm from the environment the frozen files give it')
	NEXT_PASS = PASS == 1 and failures == 0
elseif SCENARIO == 'newest_wins_bad_markers' then
	local logged = collect_log()
	for _, name in ipairs({ 'x', '1_2', '999_0_0' }) do
		write_vfs('script/memreader_plus/releases/' .. name .. '.lua', "return 'x'\n")
	end
	table.insert(VFS, 1, 'vfs')
	run_entry(BOOT)
	check(_G.memreader_plus ~= nil, 'the release that has a folder is loaded')
	check(count_logged(logged, ('releases found: %s, 999_0_0; loading %s'):format(RELEASE, RELEASE)) == 1, 'names that are no release ids are skipped')
	check(count_logged(logged, 'release 999_0_0 did not load') == 1, 'a marker without a folder falls back to the next release')
elseif SCENARIO == 'cpecific_bigread' then
	io.stdout:setvbuf('no')
	run_mod(THEIRS)
	print("reading 1024 bytes with Cpecific's DLL (expected to crash)")
	_G.memreader.read(_G.memreader.base, 0, 1024)
	print('did not crash')
	os.exit(0)
elseif SCENARIO == 'capacity' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local filler = mr.pointer(test_function('filler_code'))
	local function at(offset)
		return mr.add(filler, offset)
	end
	local function bytes_at(offset, size)
		return mr.read(at(offset), 0, size)
	end
	local function log_text()
		local log = io.open('memreader_plus_refused.txt', 'rb')
		local text = log and log:read('*a') or ''
		if log then log:close() end
		return text
	end
	local Z4, ONE4 = '\0\0\0\0', '\1\0\0\0'

	check(mr.supports.capacity == true, 'sites.attach sets supports.capacity')
	local use = mr.capacity()
	local shaped = true
	for _, name in ipairs({ 'owners', 'items', 'claims', 'held_bytes', 'hooks', 'saved_code', 'pattern_cache', 'rows', 'file_edits', 'cave_pages' }) do
		local row = use[name]
		shaped = shaped and type(row) == 'table' and type(row.used) == 'number' and type(row.room) == 'number' and type(row.limit) == 'number'
		shaped = shaped and row.used <= row.room and row.room <= row.limit
	end
	check(shaped, 'capacity has used, room and limit for every table')
	check(use.hop_slots == mr.hop_slots(), 'and the hop slots left')
	check(
		use.owners.limit == 256
			and use.items.limit == 8192
			and use.claims.limit == 32768
			and use.held_bytes.limit == 1048576
			and use.hooks.limit == 1000
			and use.saved_code.limit == 65536
			and use.pattern_cache.limit == 8192
			and use.rows.limit == 4096
			and use.file_edits.limit == 4096
			and (use.cave_pages or {}).limit == 1024,
		'the limits are the documented ones'
	)
	check(use.items.room == 256 and use.claims.room == 4096, 'items and claims start with their first chunk')

	local p = mr.patcher('cap_owner')
	local filled = 0
	while mr.capacity().items.used < 256 do
		if p:set('fill_' .. filled, at(0x10000 + filled), 1, 0, 0, 255) ~= true then break end
		filled = filled + 1
	end
	check(mr.capacity().items.used == 256, 'the first chunk of items is full')
	test_fail_memory('virtual', mr.hop_slots)
	local ok, why = p:set('needs_chunk', at(0x20000), 1, 5, 0, 255)
	check(
		ok == nil and why == 'full' and bytes_at(0x20000, 1) == '\0' and p:info('needs_chunk') == nil,
		'a refused item chunk answers full and writes nothing: ' .. tostring(why)
	)
	check(mr.capacity().items.room == 256, 'and the item table did not grow')
	check(p:set('needs_chunk', at(0x20000), 1, 5, 0, 255) == true and mr.capacity().items.room == 512, 'the next try gets the chunk')

	local function sites(base, count)
		local list = {}
		for i = 1, count do
			list[i] = { at(base + i * 4), Z4, ONE4 }
		end
		return list
	end
	local wave = 0
	while mr.capacity().claims.used + 1024 <= 4096 do
		wave = wave + 1
		p:relocate('wave_' .. wave, sites(0x30000 + wave * 0x1000, 1024))
	end
	local rest = 4096 - mr.capacity().claims.used
	if rest > 0 then p:relocate('wave_rest', sites(0x38000, rest)) end
	check(mr.capacity().claims.used == 4096, 'the first chunk of claims is full')
	test_fail_memory('virtual', mr.hop_slots)
	ok, why = p:relocate('needs_claims', sites(0x3A000, 2))
	check(
		ok == nil and why == 'full' and bytes_at(0x3A004, 4) == Z4 and p:info('needs_claims') == nil,
		'a refused claim chunk answers full and writes nothing: ' .. tostring(why)
	)
	check(p:relocate('needs_claims', sites(0x3A000, 2)) == true and mr.capacity().claims.room == 8192, 'the next try gets the chunk')

	local nops, zeros = string.rep('\144', 4096), string.rep('\0', 4096)
	local chunk = 0x40
	local held = mr.capacity().held_bytes
	while held.used + 8192 <= held.room do
		p:patch('fill_held_' .. chunk, at(chunk * 4096), zeros, nops)
		chunk = chunk + 1
		held = mr.capacity().held_bytes
	end
	test_fail_memory('heap', mr.hop_slots)
	ok, why = p:patch('needs_pool', at(chunk * 4096), zeros, nops)
	check(ok == nil and why == 'full' and bytes_at(chunk * 4096, 4) == Z4, 'a refused pool growth answers full and writes nothing: ' .. tostring(why))
	check(mr.capacity().held_bytes.room == held.room, 'and the pool did not grow')
	local held_room = held.room
	check(p:patch('needs_pool', at(chunk * 4096), zeros, nops) == true and mr.capacity().held_bytes.room == held_room * 2, 'the next try doubles the pool')
	check(mr.read_original(at(0x40 * 4096), 0, 16) == string.rep('\0', 16), 'patches made before the pool grew keep their original bytes')
	check(p:remove('fill_held_64') == true and bytes_at(0x40 * 4096, 4096) == zeros, 'and come off from the moved pool')

	local saved = mr.capacity().saved_code
	local spot = 0x60000
	while saved.used < saved.room do
		mr.patch(at(spot), Z4, ONE4)
		spot = spot + 16
		saved = mr.capacity().saved_code
	end
	test_fail_memory('heap', mr.hop_slots)
	mr.patch(at(spot), Z4, ONE4)
	check(
		string.find(log_text(), ('saved original code is full (%d ranges)'):format(saved.room), 1, true) ~= nil,
		'a refused growth of saved code logs the full line'
	)
	check(mr.read_original(at(spot), 0, 4) == ONE4 and mr.capacity().saved_code.room == saved.room, 'and that change has no original bytes')
	mr.patch(at(spot + 16), Z4, ONE4)
	local saved_room = saved.room
	check(
		mr.read_original(at(spot + 16), 0, 4) == Z4 and mr.capacity().saved_code.room == saved_room * 2,
		'the next change grows the table and saves its original'
	)
	check(mr.read_original(at(0x60000), 0, 4) == Z4, 'the oldest saved range still holds its original')

	local cache = mr.capacity().pattern_cache
	local serial = 0
	local function fresh_pattern()
		serial = serial + 1
		return ('C3 CC CC 90 %02X %02X 48'):format(serial % 256, math.floor(serial / 256) % 256)
	end
	local strings = {}
	while mr.capacity().pattern_cache.used < 1023 do
		local text = fresh_pattern()
		strings[#strings + 1] = text
		mr.find_pattern(text)
	end
	local list = {}
	for i = 1, 64 do
		list[i] = fresh_pattern()
	end
	local found, counts = mr.find_patterns(list)
	local agree = mr.capacity().pattern_cache.used == 1087
	for i = 1, 64 do
		local first, count = mr.find_pattern(list[i] .. ' ')
		agree = agree and counts[i] == count and (found[i] == false) == (first == nil) and (first == nil or mr.eq(found[i], first))
	end
	check(agree, 'find_patterns growing the cache past 1024 entries returns the same results as fresh scans')
	cache = mr.capacity().pattern_cache
	check(cache.room == 2048, 'the cache grew to 2048 entries: ' .. cache.room)
	while mr.capacity().pattern_cache.used < cache.room do
		mr.find_pattern(fresh_pattern())
	end
	test_fail_memory('heap', mr.hop_slots)
	local text = fresh_pattern()
	local first, count = mr.find_pattern(text)
	local again_first, again_count = mr.find_pattern(text .. ' ')
	check(
		count == again_count and mr.capacity().pattern_cache.used == cache.room + 1,
		'a refused cache growth still answers right and leaves that search uncached'
	)
	while mr.capacity().pattern_cache.used < 8192 do
		mr.find_pattern(fresh_pattern())
	end
	text = fresh_pattern()
	first, count = mr.find_pattern(text)
	again_first, again_count = mr.find_pattern(text .. ' ')
	cache = mr.capacity().pattern_cache
	check(cache.used == 8192 and cache.room == 8192 and count == again_count, 'the cache stops at 8192 entries and results stay right')
	check(select(2, mr.find_pattern(strings[1])) == select(2, mr.find_pattern(strings[1] .. ' ')), 'an early entry still answers like a fresh scan')
	local function wave_steps(count)
		local steps = {}
		for step = 1, math.ceil(count / 1024) do
			local list = {}
			for i = 1, math.min(1024, count - (step - 1) * 1024) do
				list[i] = { at(0x80000 + ((step - 1) * 1024 + i - 1) * 4), Z4, ONE4 }
			end
			steps[step] = { 'relocate', 'cap_wave_' .. step, list }
		end
		return steps
	end
	ok, why = p:batch(wave_steps(2049))
	check(
		ok == nil and why == 'cap_wave_3: site 1: the batch writes too many bytes' and bytes_at(0x80000, 4) == Z4,
		'a batch of 2049 writes is refused and writes nothing: ' .. tostring(why)
	)
	local done, stopped = p:batch(wave_steps(2048))
	check(done == true and bytes_at(0x80000 + 2047 * 4, 4) == ONE4, 'a batch of 2048 writes goes through')
	print(string.format('  batch of 2048 relocation writes: threads stopped %.0f us', stopped))
elseif SCENARIO == 'report_during_growth' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local filler = mr.pointer(test_function('filler_code'))
	local function at(offset)
		return mr.add(filler, offset)
	end
	local started = mr.ticks()
	local p = mr.patcher('growth_owner')
	test_report_loop_start(mr.write_runtime_report)
	for i = 0, 2999 do
		p:set('g' .. i, at(0x10000 + i), 1, 0, 0, 255)
	end
	for wave = 1, 8 do
		local list = {}
		for i = 1, 1024 do
			list[i] = { at(0x20000 + (wave * 1024 + i) * 4), '\0\0\0\0', '\1\0\0\0' }
		end
		p:relocate('wave_' .. wave, list)
	end
	local peak = mr.capacity()
	local turns = 0
	while mr.elapsed_us(started) < 10e6 do
		turns = turns + 1
		for i = 0, 99 do
			p:remove('g' .. i)
		end
		for i = 0, 99 do
			p:set('g' .. i, at(0x10000 + i), 1, turns % 200, 0, 255)
		end
	end
	local reports, bad, most_items, most_claims = test_report_loop_stop()
	check(
		peak.items.used == 3008 and peak.claims.used == 3000 + 8 * 1024,
		'items and claims grew past several chunks: ' .. peak.items.used .. ', ' .. peak.claims.used
	)
	check(reports >= 10 and bad == 0, 'every runtime report written during the growth has the capacity line: ' .. reports .. ' reports, ' .. bad .. ' bad')
	check(
		most_items <= peak.items.used + 1 and most_claims <= peak.claims.used + 1,
		'no report counts more than the registry held: ' .. most_items .. ', ' .. most_claims
	)
	check(mr.elapsed_us(started) >= 10e6 and turns > 0, 'the reports ran for 10 s while the registry changed')
elseif SCENARIO == 'many_mods' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local name = mr.write_runtime_report()
	local text = name and read_all(name) or ''
	check(has(text, 'Mods in load order (2104, from the mod file on the command line)'), 'the mod count is the whole list')
	check(has(text, '  1. first.pack  3 bytes') and has(text, '2048. extra_2044.pack  not found in any search path'), 'the first 2048 mods are listed')
	check(not has(text, '2049. '), 'the 2049th is not')
	check(has(text, '  and 56 more mods not listed'), 'the rest are counted')
	check(has(text, '  80 more search paths were not searched'), 'and so are the search paths past 1024')
	check(has(text, 'memreader Plus capacity: owners '), 'the report goes on after the list')
elseif SCENARIO == 'many_mods_memory' then
	test_fake_session(2100, 1100)
	run_mod(OURS)
	local mr = _G.memreader_plus
	local name = mr.write_runtime_report()
	local text = name and read_all(name) or ''
	check(has(text, 'Mods in load order (2100, from game memory)'), 'the mod count read from memory is the whole list')
	check(has(text, '2048. extra_2048.pack  not found in any search path'), 'the first 2048 mods are listed')
	check(not has(text, '2049. '), 'the 2049th is not')
	check(has(text, '  and 52 more mods not listed'), 'the rest are counted')
	check(has(text, '  76 more search paths were not searched'), 'and so are the search paths past 1024')
	check(has(text, 'memreader Plus capacity: owners '), 'the report goes on after the list')
elseif SCENARIO == 'mods_memory_junk' then
	test_fake_session(16385, 4)
	run_mod(OURS)
	local mr = _G.memreader_plus
	local name = mr.write_runtime_report()
	local text = name and read_all(name) or ''
	check(
		has(text, 'Mods in load order (4, from the mod file on the command line)'),
		'a mod count above 16384 in memory is not a list, the mod file is read instead'
	)
	check(not has(text, 'extra_1.pack'), 'nothing of the memory list is shown')
elseif SCENARIO == 'asm' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local function contains(text, part)
		return type(text) == 'string' and string.find(text, part, 1, true) ~= nil
	end
	local function slot_bytes(name, size)
		local parts = {}
		for i = 1, size do
			parts[i] = string.char(size == 4 and i == 4 and 0 or (#name * 37 + i * 11 + name:byte(1)) % 256)
		end
		return table.concat(parts)
	end
	local function fill(template)
		local parts, slots, values, offset = {}, {}, {}, 0
		for token in template:gmatch('%S+') do
			local name, size = token:match('^{([%w_]+):(%d)}$')
			if name then
				size = tonumber(size)
				values[name] = slot_bytes(name, size)
				parts[#parts + 1] = values[name]
				slots[#slots + 1] = name .. '@' .. offset .. ':' .. size
				offset = offset + size
			else
				parts[#parts + 1] = string.char(tonumber(token, 16))
				offset = offset + 1
			end
		end
		return table.concat(parts), table.concat(slots, ' '), values
	end
	local function slot_list(slots)
		local parts = {}
		for i, slot in ipairs(slots or {}) do
			parts[i] = slot.name .. '@' .. slot.offset .. ':' .. slot.size
		end
		return table.concat(parts, ' ')
	end
	local function first_difference(a, b)
		if type(a) ~= 'string' or type(b) ~= 'string' then return 'no bytes' end
		for i = 1, math.max(#a, #b) do
			if a:byte(i) ~= b:byte(i) then return ('+%d: %s vs %s'):format(i - 1, tostring(a:byte(i)), tostring(b:byte(i))) end
		end
		return 'same'
	end
	local function le_number_of(text)
		local number = 0
		for i = #text, 1, -1 do
			number = number * 256 + text:byte(i)
		end
		return number
	end
	local function hex(text)
		return (text:gsub('.', function(ch)
			return string.format('%02X ', ch:byte())
		end))
	end

	local CAVES = {
		{
			'strength_bar',
			[[
push rcx
push rdx
push r8
mov r8, {block:8}
cmp dword ptr [r8], 0
je done
mov rcx, [rbp + {character_slot:4}]
test rcx, rcx
je done
mov rcx, [rcx + 0x3b0]
test rcx, rcx
je done
mov rcx, [rcx]
test rcx, rcx
je done
cmp dword ptr [rbp + {shape:4}], 4
jne unit
mov rcx, [rcx + 0x790]
test rcx, rcx
je done
unit:
mov edx, [rcx + 8]
cmp edx, [r8 + 8]
jae done
cmp dword ptr [r8 + rdx*4 + 0x10], 0
je done
mulss xmm0, [r8 + rdx*4 + 0x10]
minss xmm0, [r8 + 4]
done:
pop r8
pop rdx
pop rcx
]],
			'51 52 41 50 49 B8 {block:8} 41 83 38 00 74 53 48 8B 8D {character_slot:4} 48 85 C9 74 47 48 8B 89 B0 03 00 00 48 85 C9 74 3B 48 8B 09 48 85 C9 74 33 83 BD {shape:4} 04 75 0C 48 8B 89 90 07 00 00 48 85 C9 74 1E 8B 51 08 41 3B 50 08 73 15 41 83 7C 90 10 00 74 0D F3 41 0F 59 44 90 10 F3 41 0F 5D 40 04 41 58 5A 59',
		},
		{
			'strength_icon',
			[[
push rcx
push rdx
push r8
mov r8, {block:8}
cmp dword ptr [r8], 0
je cap
mov rcx, [rcx + {character:1}]
test rcx, rcx
je cap
mov rcx, [rcx + {force:4}]
test rcx, rcx
je cap
mov rcx, [rcx]
test rcx, rcx
je cap
mov edx, [rcx + 8]
cmp edx, [r8 + 8]
jae cap
cmp dword ptr [r8 + rdx*4 + 0x10], 0
je cap
mulss xmm6, [r8 + rdx*4 + 0x10]
cap:
minss xmm6, [r8 + 4]
pop r8
pop rdx
pop rcx
]],
			'51 52 41 50 49 B8 {block:8} 41 83 38 00 74 35 48 8B 49 {character:1} 48 85 C9 74 2C 48 8B 89 {force:4} 48 85 C9 74 20 48 8B 09 48 85 C9 74 18 8B 51 08 41 3B 50 08 73 0F 41 83 7C 90 10 00 74 07 F3 41 0F 59 74 90 10 F3 41 0F 5D 70 04 41 58 5A 59',
		},
		{
			'strength_percent',
			[[
push rcx
push rdx
push r8
mov r8, {block:8}
cmp dword ptr [r8], 0
je vanilla
mov rax, [rcx + {cco_force:4}]
test rax, rax
je vanilla
mov edx, [rax + 8]
cmp edx, [r8 + 8]
jae vanilla
cmp dword ptr [r8 + rdx*4 + 0x10], 0
je vanilla
mov eax, [rax + {force_units:4}]
cvtsi2ss xmm0, rax
mulss xmm0, [r8 + rdx*4 + 0x10]
mulss xmm0, [r8 + 0xc]
pop r8
pop rdx
pop rcx
ret
vanilla:
pop r8
pop rdx
pop rcx
]],
			'51 52 41 50 49 B8 {block:8} 41 83 38 00 74 3A 48 8B 81 {cco_force:4} 48 85 C0 74 2E 8B 50 08 41 3B 50 08 73 25 41 83 7C 90 10 00 74 1D 8B 80 {force_units:4} F3 48 0F 2A C0 F3 41 0F 59 44 90 10 F3 41 0F 59 40 0C 41 58 5A 59 C3 41 58 5A 59',
		},
		{
			'replay_tick_cave',
			[[
cmp byte ptr [rbx + {is_replay:4}], 0
je done
mov rax, [rbx + {replay:4}]
test rax, rax
je done
mov ecx, [rax + 0x14]
mov rdx, [rax + 0x18]
test rdx, rdx
je done
xor r8d, r8d
next:
cmp ecx, r8d
jbe done
mov rax, [rdx + r8*8]
test rax, rax
je skip
mov r9d, [rax]
test r9d, r9d
je skip
lea eax, [r9 - 0x64]
cmp eax, 0x190
ja done
mov rax, {period:8}
mov [rax], r9d
jmp done
skip:
inc r8d
jmp next
done:
]],
			'80 BB {is_replay:4} 00 74 50 48 8B 83 {replay:4} 48 85 C0 74 44 8B 48 14 48 8B 50 18 48 85 D2 74 38 45 31 C0 44 39 C1 76 30 4A 8B 04 C2 48 85 C0 74 22 44 8B 08 45 85 C9 74 1A 41 8D 41 9C 3D 90 01 00 00 77 14 48 B8 {period:8} 44 89 08 EB 05 41 FF C0 EB CB',
		},
		{
			'load_rescale',
			[[
mov r11, [r15]
test r11, r11
je done
mov r11, [r11 + {model:4}]
test r11, r11
je done
mov r11, [r11 + {settings:4}]
test r11, r11
je done
movss [r11 + {field:1}], xmm7
done:
]],
			'4D 8B 1F 4D 85 DB 74 1E 4D 8B 9B {model:4} 4D 85 DB 74 12 4D 8B 9B {settings:4} 4D 85 DB 74 06 F3 41 0F 11 7B {field:1}',
		},
		{
			'load_refresh_stash',
			[[
mov qword ptr [rsp + 0x30], 0
cmp byte ptr [rdx + {building:4}], 0
je done
cmp byte ptr [rdx + {new_game:4}], 0
jne done
mov rax, [rsp + 0x60]
mov eax, [rax]
test eax, eax
je done
mov r10d, [r9]
test r10d, r10d
je done
shl r10, 32
or r10, rax
mov [rsp + 0x30], r10
done:
]],
			'48 C7 44 24 30 00 00 00 00 80 BA {building:4} 00 74 28 80 BA {new_game:4} 00 75 1F 48 8B 44 24 60 8B 00 85 C0 74 14 45 8B 11 45 85 D2 74 0C 49 C1 E2 20 49 09 C2 4C 89 54 24 30',
		},
		{
			'load_refresh_share',
			[[
mov rax, {callee:8}
call rax
mov r10, [rsp + 0x30]
test r10, r10
je leave
test al, al
je leave
mov r11, [rsp + 0x28]
mov r11d, [r11]
mov rcx, [rsp + 0x20]
mov r8d, r10d
test r8d, r8d
je leave
shr r10, 32
mov rax, r10
imul rax, r11
mov rdx, r8
shr rdx, 1
add rax, rdx
xor edx, edx
div r8
cmp rax, r11
cmova rax, r11
test rax, rax
jne store
mov eax, 1
store:
mov [rcx], eax
mov eax, 1
leave:
add rsp, 0x38
ret
]],
			'48 B8 {callee:8} FF D0 4C 8B 54 24 30 4D 85 D2 74 4A 84 C0 74 46 4C 8B 5C 24 28 45 8B 1B 48 8B 4C 24 20 45 89 D0 45 85 C0 74 31 49 C1 EA 20 4C 89 D0 49 0F AF C3 4C 89 C2 48 D1 EA 48 01 D0 31 D2 49 F7 F0 4C 39 D8 49 0F 47 C3 48 85 C0 75 05 B8 01 00 00 00 89 01 B8 01 00 00 00 48 83 C4 38 C3',
		},
		{
			'result_share_cave',
			[[
mov r9, {block:8}
cmp dword ptr [r9], 0
je done
mov rax, [rcx + {record:4}]
cmp byte ptr [rax + {flag:4}], 0
jne other
mov r8d, [r10 + 0x98]
jmp read
other:
mov r8d, [r10 + 0xac]
read:
mov r11d, [rcx + 0x27c]
mov eax, [rcx + {current:4}]
test eax, eax
je done
test r8d, r8d
je done
test r11d, r11d
je done
cmp r8d, r11d
je done
imul rax, r11
mov rdx, r8
shr rdx, 1
add rax, rdx
xor edx, edx
div r8
test rax, rax
jne cap
mov eax, 1
cap:
cmp rax, r11
cmova rax, r11
mov [rcx + {current:4}], eax
done:
]],
			'49 B9 {block:8} 41 83 39 00 74 69 48 8B 81 {record:4} 80 B8 {flag:4} 00 75 09 45 8B 82 98 00 00 00 EB 07 45 8B 82 AC 00 00 00 44 8B 99 7C 02 00 00 8B 81 {current:4} 85 C0 74 38 45 85 C0 74 33 45 85 DB 74 2E 45 39 D8 74 29 49 0F AF C3 4C 89 C2 48 D1 EA 48 01 D0 31 D2 49 F7 F0 48 85 C0 75 05 B8 01 00 00 00 4C 39 D8 49 0F 47 C3 89 81 {current:4}',
		},
		{
			'strength_bar_probe',
			[[
push rcx
push rdx
push r8
mov r8, {block:8}
cmp dword ptr [r8], {limit:4}
je done
done:
pop r8
pop rdx
pop rcx
]],
			'51 52 41 50 49 B8 {block:8} 41 81 38 {limit:4} 74 00 41 58 5A 59',
		},
		{
			'melee_ap_armour',
			[[
cvtsi2ss xmm1, ebx
mulss xmm1, xmm6
mov eax, 100.0
movd xmm2, eax
minss xmm1, xmm2
mov eax, 0.01
movd xmm2, eax
mulss xmm1, xmm2
mov eax, 1.0
movd xmm2, eax
subss xmm2, xmm1
mulss xmm2, dword ptr [rsp+0x44]
movss dword ptr [rsp+0x44], xmm2
]],
			'F3 0F 2A CB F3 0F 59 CE B8 00 00 C8 42 66 0F 6E D0 F3 0F 5D CA B8 0A D7 23 3C 66 0F 6E D0 F3 0F 59 CA B8 00 00 80 3F 66 0F 6E D0 F3 0F 5C D1 F3 0F 59 54 24 44 F3 0F 11 54 24 44',
		},
		{
			'offline_counter',
			[[
push rax
mov rax, {counter:8}
inc dword ptr [rax]
pop rax
]],
			'50 48 B8 {counter:8} FF 00 58',
		},
	}

	check(type(mr.assemble) == 'function' and type(mr.disassemble) == 'function', 'assemble and disassemble are part of the API')
	for _, row in ipairs(CAVES) do
		local name, text, template = row[1], row[2], row[3]
		local expected, slots_expected, values = fill(template)
		local bytes, listing, slots, code = mr.assemble(text, nil, values)
		check(
			bytes == expected and code == #expected,
			name .. ': the asm text gives the bytes the mod ships: ' .. (bytes and first_difference(bytes, expected) or tostring(listing))
		)
		check(slot_list(slots) == slots_expected, name .. ': the slots sit where the hex template has them: ' .. slot_list(slots))
		local open, _, open_slots = mr.assemble(text, nil, nil, true)
		local zeroed = expected
		for _, slot in ipairs(open_slots or {}) do
			zeroed = zeroed:sub(1, slot.offset) .. string.rep('\0', slot.size) .. zeroed:sub(slot.offset + slot.size + 1)
		end
		local all_open = #(open_slots or {}) == #(slots or {})
		for _, slot in ipairs(open_slots or {}) do
			all_open = all_open and slot.given == false
		end
		check(open == zeroed and all_open, name .. ': without values the slots are zero and marked not given')
	end

	local ROUND_TRIP = { { 'load_rescale', 'asm_site_g', 'asm_site_h' }, { 'result_share_cave', 'asm_site_i', 'asm_site_j' } }
	local inventory = mr.patcher('asm_inventory')
	local function hex_of(at, size)
		local bytes, parts = mr.read_original(at, 0, size), {}
		for i = 1, size do
			parts[i] = string.format('%02X', bytes:byte(i))
		end
		return table.concat(parts, ' ')
	end
	local function same_value(a, b)
		if type(a) == 'number' then return a == b end
		return a ~= nil and b ~= nil and mr.eq(a, b)
	end
	for _, trip in ipairs(ROUND_TRIP) do
		local row
		for _, candidate in ipairs(CAVES) do
			if candidate[1] == trip[1] then row = candidate end
		end
		local expected, _, values = fill(row[3])
		local entries, sites = {}, {}
		for i, kind in ipairs({ 'asm', 'bytes' }) do
			local fn = mr.pointer(test_function(trip[i + 1]))
			sites[i] = mr.add(fn, 3)
			entries[i] = {
				name = trip[1] .. '_' .. kind,
				feature = trip[1] .. '_' .. kind,
				kind = 'cave',
				pattern = hex_of(fn, 16),
				at = 3,
				expect = hex_of(sites[i], 5),
			}
			entries[i][kind] = kind == 'asm' and row[2] or row[3]
		end
		local native = inventory:sites(entries, function() end)
		local asm_ok, asm_why = native.install(entries[1].name, values)
		local hex_ok, hex_why = native.install(entries[2].name, values)
		check(asm_ok and hex_ok, trip[1] .. ': the asm entry and the hex entry install with the same values: ' .. tostring(asm_why) .. ' ' .. tostring(hex_why))
		local asm_cave, hex_cave = mr.hook_info(sites[1]).cave, mr.hook_info(sites[2]).cave
		check(mr.read(asm_cave, 0, #expected) == expected and mr.read(hex_cave, 0, #expected) == expected, trip[1] .. ': both caves hold the same bytes')
		local all_same = true
		for name, value in pairs(values) do
			local from_asm, from_hex = native.cave_value(entries[1].name, name), native.cave_value(entries[2].name, name)
			all_same = all_same and same_value(from_asm, from_hex)
			if #value == 4 then all_same = all_same and from_asm == le_number_of(value) end
		end
		check(all_same, trip[1] .. ': cave_value reads every slot back the same from the asm cave and the hex cave')
	end

	local strength = fill(CAVES[1][3])
	local _, listing = mr.assemble(CAVES[1][2], nil, select(3, fill(CAVES[1][3])))
	check(
		contains(listing, '  +04 49 B8 ')
			and contains(listing, '{block:8} at +06')
			and contains(listing, 'mulss xmm0, dword ptr [r8+rdx*4+0x10]')
			and contains(listing, 'jump back'),
		'the listing shows offsets, instructions, slots and the jump back'
	)
	check(#strength == 107, 'the strength bar cave is 107 bytes')

	local at = mr.pointer(test_function('asm_site'))
	local shown = mr.disassemble(at, 3)
	check(
		contains(shown, 'mov eax, ecx') and contains(shown, 'imul eax, eax, 0x3') and select(2, shown:gsub('\n', '')) == 2,
		'disassemble shows the host code, one line per instruction'
	)
	check(contains(mr.disassemble(at), mr.tostring(at):lower():gsub('^0+', '')), 'one line names its address')

	local data_code, _, _, data_size = mr.assemble('movss xmm0, dword ptr [rip + one]\n.data\none: dd 1.0', mr.pointer(test_function('asm_float')))
	check(
		data_size == 8
			and #data_code == 8 + 14 + 4
			and data_code:sub(1, 8) == '\243\15\16\5\14\0\0\0'
			and data_code:sub(9, 22) == string.rep('\0', 14)
			and data_code:sub(23) == '\0\0\128\63',
		'.data goes after the 14 bytes of the jump back and rip + label reaches it: ' .. hex(data_code or '')
	)
	local folded = mr.assemble('MOV EAX, 0x10 ; comment\n// line comment\n\nlabel: Nop\nJMP label')
	check(folded == '\184\16\0\0\0\144\235\253', 'mnemonics and registers in any case, ; and // comments, a backward jump: ' .. hex(folded or ''))
	check(mr.assemble('mov al, {small}', nil, { small = '\255' }) == '\176\255', 'a 1-byte string value is used as its byte')
	check(mr.assemble('mov rax, {wide}', nil, { wide = '\255\255\255\255' }) == '\72\199\192\255\255\255\255', 'a 4-byte string value is sign-extended')
	check(mr.assemble('mov eax, {byte}', nil, { byte = '\200' }) == '\184\200\0\0\0', 'a 1-byte string value is zero-extended')
	local UNSIGNED = {
		{ 'mov eax, 0xffffffff', '\184\255\255\255\255' },
		{ 'cmp byte ptr [rax], 0xff', '\128\56\255' },
		{ 'mov ax, 0xffff', '\102\184\255\255' },
		{ 'and eax, 0x80000000', '\37\0\0\0\128' },
		{ 'mov eax, -1.0', '\184\0\0\128\191' },
		{ 'mov rax, 0xffffffff', '\72\184\255\255\255\255\0\0\0\0' },
	}
	for _, case in ipairs(UNSIGNED) do
		local code, why = mr.assemble(case[1])
		check(code == case[2], case[1] .. ' takes the value as written for the operand size: ' .. (code and hex(code) or tostring(why)))
	end
	local wide, wide_why = mr.assemble('add rax, 0x80000000')
	check(
		wide == nil and wide_why == "asm:1:1: no encoding for 'add rax, 0x80000000'",
		'a value a 64-bit operation would sign-extend is refused, not folded: ' .. tostring(wide_why)
	)
	check(mr.assemble('db 1, 2\ndw 0x0304\ndd -1\ndq 2.0\nalign 4\nnop') ~= nil, 'data and align lines assemble')
	local N1, N2, N3 = '\144', '\102\144', '\15\31\0'
	local N4, N5, N6 = '\15\31\64\0', '\15\31\68\0\0', '\102\15\31\68\0\0'
	local N7, N8, N9 = '\15\31\128\0\0\0\0', '\15\31\132\0\0\0\0\0', '\102\15\31\132\0\0\0\0\0'
	local PADS = { N1, N2, N3, N4, N5, N6, N7, N8, N9, N9 .. N1, N9 .. N2, N9 .. N3, N9 .. N4, N9 .. N5, N9 .. N6 }
	for pad, wanted in ipairs(PADS) do
		local aligned = mr.assemble('align 16\nnop', mr.pointer(string.char(16 - pad) .. '\0\1\0\0\0\0\0'))
		check(aligned == wanted .. '\144', ('align 16 pads %d bytes of code with the nops of the table: %s'):format(pad, hex(aligned or '')))
	end
	local data_aligned = mr.assemble('nop\n.data\ndb 1\ndb 1\nalign 4\ndb 2')
	check(data_aligned and data_aligned:sub(-6) == '\1\1\0\0\0\2', 'align pads .data with zeros: ' .. hex(data_aligned or ''))
	local SIGN_CASES = {
		{ 'add eax, {x:1}', { x = 200 }, '\131\192\200', 'a 1-byte field in add eax takes 200 as -56' },
		{ 'mov rax, {x:4}', { x = 1 }, '\72\199\192\1\0\0\0', 'a 4-byte field in mov rax is the sign-extended imm32 form' },
		{ 'mov eax, 1.5', nil, '\184\0\0\192\63', 'a float literal loads its bits' },
		{ 'xchg eax, eax', nil, '\144', 'xchg eax, eax encodes as the one-byte nop' },
	}
	for _, case in ipairs(SIGN_CASES) do
		local code = mr.assemble(case[1], nil, case[2])
		check(code == case[3], case[4] .. ': ' .. hex(code or ''))
	end

	local function relaxed(text)
		local code = mr.assemble(text)
		return code and code:byte(1), code and #code
	end
	local function nops(count)
		return string.rep('nop\n', count)
	end
	local op, size = relaxed('jz t\n' .. nops(127) .. 't: nop')
	check(op == 0x74 and size == 2 + 127 + 1, 'a forward jump of 127 stays short')
	op, size = relaxed('jz t\n' .. nops(128) .. 't: nop')
	check(op == 0x0F and size == 6 + 128 + 1, 'a forward jump of 128 becomes near')
	local back = mr.assemble('t: ' .. nops(126) .. 'jz t')
	check(back and #back == 128 and back:byte(127) == 0x74 and back:byte(128) == 0x80, 'a backward jump of -128 stays short')
	back = mr.assemble('t: ' .. nops(127) .. 'jz t')
	check(back and #back == 133 and back:byte(128) == 0x0F and back:sub(130) == '\123\255\255\255', 'a backward jump of -129 becomes near')
	local chain = mr.assemble('jz far_a\njz far_b\n' .. nops(123) .. 'far_a: nop\n' .. nops(5) .. 'far_b: nop')
	check(
		chain and chain:sub(1, 6) == '\15\132\129\0\0\0' and chain:sub(7, 12) == '\15\132\129\0\0\0',
		'widening one jump pushes the other out of reach and both become near: ' .. hex((chain or ''):sub(1, 12))
	)
	check(relaxed('jmp short t\nt: nop') == 0xEB, 'short forces a short jump')
	check(relaxed('jmp near t\nt: nop') == 0xE9, 'near forces a near jump')
	check(relaxed('call {f}', nil) == nil, 'a call to a value needs the value')
	local far_call = mr.assemble('call {f}', mr.pointer('\0\0\1\0\0\0\0\0'), { f = mr.pointer('\0\0\2\0\0\0\0\0') })
	check(far_call == '\232\251\255\0\0', 'a call to a value is rel32 from the cave address: ' .. hex(far_call or ''))

	local ERRORS = {
		{ 'nop\n  mulls xmm0, xmm1', nil, "asm:2:3: unknown mnemonic 'mulls'" },
		{ 'mulss xmn0, xmm1', nil, "asm:1:7: unknown register 'xmn0'" },
		{ 'add [rax], 1', nil, 'asm:1:1: say byte, word, dword or qword ptr: more than one size fits' },
		{ 'movss xmm0, rax', nil, "asm:1:1: no encoding for 'movss xmm0, rax'" },
		{ 'jmp done', nil, "asm:1:5: label 'done' is not defined" },
		{ 'a:\nnop\n a: nop', nil, "asm:3:2: label 'a' is defined twice" },
		{ 'mov rax, {block:8}', nil, 'asm:1:10: {block:8} has no value' },
		{ 'mov eax, {plain}', nil, 'asm:1:10: {plain} has no value' },
		{ 'mov byte ptr [rax + {field:1}], 0', { field = 500 }, 'asm:1:5: {field:1} does not fit 0x1f4' },
		{ 'mov al, {record:4}', { record = 1 }, 'asm:1:9: {record:4} cannot be a 4-byte field in this instruction' },
		{ 'call {f}', { f = mr.pointer('\0\0\0\0\0\128\0\0') }, 'asm:1:6: call target 0x800000000000 is out of rel32 reach of the cave' },
		{ 'mov eax, [rip + 0x10]', nil, 'asm:1:10: [rip + number] is not supported: use [rip + label] or [rip + {name}]' },
		{ string.rep('mov r8, 0x1122334455667788\n', 410), nil, 'asm:1:1: the cave is larger than 4096 bytes' },
		{ 'jmp short t\n' .. nops(200) .. 't: nop', nil, "asm:1:5: the short jump to 't' is out of range" },
		{ 'push 1.5', nil, 'asm:1:6: a float needs a 32-bit or 64-bit operand next to it' },
		{ 'align 3', nil, 'asm:1:1: align takes a power of two up to 256' },
		{ '.data\n.data', nil, 'asm:2:1: .data is given twice' },
		{ 'jmp ' .. string.rep('a', 48), nil, 'asm:1:5: a name is longer than 47 characters' },
		{ 'mov eax, [rax + rcx*3]', nil, 'asm:1:17: the scale must be 1, 2, 4 or 8' },
		{ 'rax: nop', nil, "asm:1:1: label 'rax' is a register name" },
		{ 'mov eax,, 1', nil, "asm:1:9: unexpected ','" },
		{ 'mov eax,', nil, 'asm:1:9: the line ends too early' },
		{ 'mov eax, short t\nt:', nil, 'asm:1:10: short and near go with jumps and calls' },
		{ 'jmp {t:4}', nil, 'asm:1:5: a jump target cannot be a slot' },
		{ 'mov eax, {x}', { x = 'abc' }, 'asm:1:10: {x} as a string must be 1, 2, 4 or 8 bytes' },
		{ 'mov eax, {x}', { x = 1.5 }, 'asm:1:10: {x} must be a whole number, a pointer value or a string of bytes' },
		{ 'dd 5\n.data', nil, nil },
		{ '', nil, 'asm:1:1: no instructions' },
		{ 'mov rax, 99999999999999999999', nil, 'asm:1:10: the number is too large' },
		{ 'mov eax, [rax - rcx]', nil, 'asm:1:17: a register cannot be subtracted' },
		{ 'mov eax, [rcx + {a:4} + 8]', nil, 'asm:1:10: a slot is the whole displacement: no number next to it' },
		{ 'mov eax, [rax + t]\nt:', nil, 'asm:1:10: a label in an address needs rip: [rip + label]' },
		{ 'db {x:4}', { x = 1 }, 'asm:1:4: {x:4} does not match db' },
		{ 'db 300', nil, 'asm:1:4: 0x12c does not fit db' },
		{ 'nop\n\255', nil, 'asm:2:1: unexpected character' },
		{ string.rep('a', 262145), nil, 'asm:1:1: the text is longer than 262144 bytes' },
	}
	for _, case in ipairs(ERRORS) do
		local ok, bytes, why = pcall(mr.assemble, case[1], nil, case[2])
		if case[3] then
			check(ok and bytes == nil and why == case[3], ('%s is refused: %s'):format(case[1]:sub(1, 40):gsub('\n', ' / '), tostring(why)))
		else
			check(ok and bytes ~= nil, ('%s assembles'):format(case[1]:sub(1, 40):gsub('\n', ' / ')))
		end
	end
	check(not pcall(mr.assemble, 5 > 4), 'text that is not a string raises')
	check(not pcall(mr.assemble, 'nop', nil, 5), 'values that are not a table raise')

	local seed = 7
	local function random(count)
		seed = (seed * 75 + 74) % 65537
		return seed % count + 1
	end
	local PIECES = {
		'[',
		']',
		'{',
		'}',
		':',
		',',
		'+',
		'-',
		'*',
		';',
		'.',
		'0x',
		'9',
		'a',
		'Z',
		' ',
		'\n',
		'\t',
		'\0',
		'\255',
		'rax',
		'ptr',
		'dword',
		'1.5',
		'{x:8}',
		'jmp',
		'e',
	}
	local function mutate(text)
		local kind, at = random(6), random(#text)
		if kind == 1 then return text:sub(1, at - 1) .. text:sub(at + 1) end
		if kind == 2 then return text:sub(1, at - 1) .. PIECES[random(#PIECES)] .. text:sub(at) end
		if kind == 3 then return text:sub(1, at - 1) .. PIECES[random(#PIECES)] .. text:sub(at + 1) end
		if kind == 4 then return text:sub(1, at) end
		if kind == 5 then return text:sub(at) .. text:sub(1, at - 1) end
		return text .. text:sub(at)
	end
	local decode_cell = mr.alloc(8192)
	local cell_low = tonumber(mr.tostring(decode_cell):match('(%x%x%x%x)$'), 16)
	local function code_starts(listing)
		local starts = {}
		for line in listing:gmatch('[^\n]+') do
			if contains(line, ' jump back') then break end
			starts[#starts + 1] = tonumber(line:match('^  %+(%x+) '), 16)
		end
		return starts
	end
	local function only_instructions(text)
		local lower = text:lower()
		return not (contains(lower, 'align') or lower:match('%f[%w]d[bwdq]%f[%W]'))
	end
	local function decodes_back(bytes, listing, code)
		local starts = code_starts(listing)
		starts[#starts + 1] = code
		mr.write(decode_cell, 0, bytes:sub(1, code) .. '\144')
		local index = 0
		for line in mr.disassemble(decode_cell, #starts):gmatch('[^\n]+') do
			index = index + 1
			local low = tonumber(line:match('^0x%x-(%x%x%x%x)  '), 16)
			if not low or (low - cell_low) % 65536 ~= starts[index] or contains(line, '(cannot be decoded)') then return false end
		end
		return index == #starts
	end
	local raised, odd, built, refused, decoded, undecoded = 0, 0, 0, 0, 0, 0
	for round = 1, 2400 do
		local row = CAVES[(round - 1) % #CAVES + 1]
		local text = row[2]
		for _ = 1, random(3) do
			text = mutate(text)
		end
		local ok, bytes, why, _, code = pcall(mr.assemble, text, nil, select(3, fill(row[3])))
		if not ok then
			raised = raised + 1
			print('  raised: ' .. tostring(bytes))
		elseif bytes then
			built = built + 1
			if only_instructions(text) and decodes_back(bytes, why, code) then
				decoded = decoded + 1
			elseif only_instructions(text) then
				undecoded = undecoded + 1
				print(('  decodes differently: %q'):format(text))
			end
		elseif type(why) == 'string' and why:match('^asm:%d+:%d+: ') then
			refused = refused + 1
		else
			odd = odd + 1
			print('  odd: ' .. tostring(why))
		end
	end
	print(('  fuzz: %d assembled, %d refused, %d decoded back'):format(built, refused, decoded))
	check(raised == 0 and odd == 0 and refused > 1000, 'mutated cave texts either assemble or are refused with a line and column, never raise')
	check(undecoded == 0 and decoded > 50, 'every assembled text without data decodes back to the same instructions at the same offsets: ' .. decoded)
elseif SCENARIO == 'asm_cave' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local function contains(text, part)
		return type(text) == 'string' and string.find(text, part, 1, true) ~= nil
	end
	local function address(name)
		return mr.pointer(test_function(name))
	end
	local cell = mr.alloc(8)
	local function raw(pointer)
		mr.write(cell, 0, pointer)
		return mr.read(cell, 0, 8)
	end
	local function hex_of(at, size)
		local bytes, parts = mr.read_original(at, 0, size), {}
		for i = 1, size do
			parts[i] = string.format('%02X', bytes:byte(i))
		end
		return table.concat(parts, ' ')
	end
	local function unique(pattern)
		local _, count = mr.find_pattern(pattern)
		return count == 1
	end
	local echoed = {}
	mr.set_log(function(message)
		echoed[#echoed + 1] = message
	end)
	local function echo_has(part)
		for _, line in ipairs(echoed) do
			if contains(line, part) then return true end
		end
		return false
	end
	local function blocks()
		return test_virtual_blocks(mr.hop_slots)
	end
	local PAGE_READWRITE, PAGE_EXECUTE_READ = 4, 0x20
	local p = mr.patcher('asm_mod')

	local call_site = address('asm_call_here')
	local hits = mr.pointer(cave_count_address())
	local double_spec = { asm = 'inc dword ptr [rip + {hits}]\nmov ecx, eax\ncall {double}', values = { hits = hits, double = address('asm_double') } }
	local before = blocks()
	local hits_before = cave_count()
	local cave, why = p:cave('double_call', call_site, double_spec)
	check(cave ~= nil, 'a table cave with asm installs: ' .. tostring(why))
	check(blocks() == before, 'and takes a page of the cave memory reserved at load')
	check(
		mr.tonumber(mr.call(address('asm_call'), 'int32(int32)', 5)) == 1010,
		'the cave calls the host helper through call {double} and the original code runs after it'
	)
	check(cave_count() == hits_before + 1, 'inc dword ptr [rip + {hits}] reached the host counter')
	local info = mr.hook_info(call_site)
	check(info and info.kind == 'cave' and mr.eq(info.cave, cave), 'hook_info names the cave')
	check(test_allocated_as(raw(cave)) == PAGE_READWRITE, 'the cave memory was allocated read-write, not executable')
	check(test_protection(raw(cave)) == PAGE_EXECUTE_READ, 'and is execute-read once installed')
	check(
		contains(info.listing, 'cave double_call at 0x') and contains(info.listing, 'call 0x') and contains(info.listing, 'jump back: original 05 E8 03 00 00'),
		'hook_info has the listing'
	)
	check(echo_has('[asm_mod] cave double_call at 0x'), 'the install echoes the listing through set_log')
	local again = p:cave('double_call', call_site, double_spec)
	check(again ~= nil and mr.eq(again, cave) and blocks() == before, 'the same cave again is a no-op')
	local other, other_why = p:cave('double_call', call_site, { asm = 'nop' })
	check(other == nil and other_why == 'the name is already used for a different change', 'other text under the same name is refused: ' .. tostring(other_why))
	local aligned_site = address('asm_site_k_here')
	local aligned_cave = p:cave('aligned', aligned_site, { asm = 'add eax, 1\nalign 16\nadd eax, 2', echo = false })
	check(aligned_cave ~= nil and not contains(mr.read(aligned_cave, 0, 16), '\204'), 'an aligned cave pads with nops, not int3')
	check(mr.tonumber(mr.call(address('asm_site_k'), 'int32(int32)', 1)) == 14 + 3 + 12001, 'and runs through the padding into the next instruction')

	local seal_site = address('asm_site_i_here')
	local hops_before = mr.hop_slots()
	test_fail_memory('private_heap', mr.hop_slots)
	local sealed, sealed_why = p:cave('double_seal', seal_site, { asm = 'add eax, 1', echo = false })
	local _, _, refusals_left = test_window_counts()
	check(refusals_left == 0, 'the thread list MinHook allocates while it enables the hook was refused')
	check(sealed ~= nil and mr.hop_slots() == hops_before - 1, 'the cave then takes the far path, sealed a second time: ' .. tostring(sealed_why))
	check(test_protection(raw(sealed)) == PAGE_EXECUTE_READ, 'and stays execute-read')
	check(mr.tonumber(mr.call(address('asm_site_i'), 'int32(int32)', 4)) == 15 + 1 + 10001, 'and jumps back into the far trampoline')

	local quiet_count = #echoed
	local quiet = p:cave('quiet_cave', address('asm_site_d_here'), { asm = 'nop', echo = false })
	check(quiet ~= nil and #echoed == quiet_count, 'echo = false installs without the echo')

	local float_site = address('asm_float_here')
	local AP_DATA = [[
cvtsi2ss xmm1, ebx
mulss xmm1, xmm6
minss xmm1, dword ptr [rip + hundred]
mulss xmm1, dword ptr [rip + percent]
movss xmm2, dword ptr [rip + one]
subss xmm2, xmm1
mulss xmm2, dword ptr [rsp+0x44]
movss dword ptr [rsp+0x44], xmm2
.data
hundred: dd 100.0
percent: dd 0.01
one: dd 1.0
]]
	local float_target = address('asm_float')
	local function ap(armour, low, damage)
		return mr.tonumber(mr.call(float_target, 'float(int32, float, float)', armour, low, damage))
	end
	check(ap(50, 0.5, 200) == 200, 'the host function returns the damage before the cave')
	local data_cave, data_why = p:cave('ap_data', float_site, { asm = AP_DATA, source = 'script/test/ap.asm' })
	check(data_cave ~= nil, 'the AP armour cave with .data constants installs: ' .. tostring(data_why))
	check(
		math.abs(ap(50, 0.5, 200) - 150) < 0.01 and math.abs(ap(0, 0.5, 200) - 200) < 0.01 and math.abs(ap(400, 0.5, 200)) < 0.01,
		'and reduces the damage by the armour roll: ' .. ap(50, 0.5, 200)
	)
	local _, _, _, ap_code = mr.assemble(AP_DATA, data_cave)
	check(ap_code == 48 and mr.read(data_cave, ap_code + 14, 4) == '\0\0\200\66', 'the constants sit after the jump back')

	local near_site = address('asm_site_c_here')
	before = blocks()
	check(test_force_far_hooks(true, mr.hop_slots), 'near memory is made unreachable')
	local far, far_why = p:cave('far_try', near_site, { asm = 'nop' })
	test_force_far_hooks(false, mr.hop_slots)
	check(far == nil and far_why == "no free memory near the game's code for the cave", 'without near memory the asm cave is refused: ' .. tostring(far_why))
	check(mr.hook_info(near_site) == nil and blocks() == before, 'and nothing is installed or left allocated')

	local site_bytes = mr.read(near_site, 0, 5)
	local function listed(name)
		for _, row in ipairs(mr.patch_list('asm_mod')) do
			if row.name == name then return true end
		end
		return false
	end
	local function untouched(what)
		check(
			mr.hook_info(near_site) == nil and mr.read(near_site, 0, 5) == site_bytes and blocks() == before,
			what .. ' leaves the code, the hooks and the memory as they were'
		)
	end
	local bad, bad_why = p:cave('bad_text', near_site, { asm = 'nop\nmulls xmm0, xmm1', source = 'script/test/bad.asm' })
	check(
		bad == nil and bad_why == "script/test/bad.asm:2:1: unknown mnemonic 'mulls'",
		'a bad text is refused with its source, line and column: ' .. tostring(bad_why)
	)
	untouched('a bad text')
	local mismatch, mismatch_why = p:cave('mismatch', near_site, { asm = 'nop\nnop', bytes = '\144\204' })
	check(mismatch == nil and mismatch_why == 'asm and bytes differ at +0x1', 'asm and bytes that differ are refused: ' .. tostring(mismatch_why))
	untouched('a mismatch')
	local raising = setmetatable({ asm = 'nop' }, {
		__index = function(_, key)
			if key == 'values' then error('values boom') end
		end,
	})
	local raised, raised_why = p:cave('raising', near_site, raising)
	check(raised == nil and contains(raised_why, 'values boom'), 'a cave table that raises while it is read is refused: ' .. tostring(raised_why))
	untouched('a table that raises after the memory was taken')
	local thrown = setmetatable({ asm = 'nop' }, {
		__index = function(_, key)
			if key == 'source' then error({}) end
		end,
	})
	local _, thrown_why = p:cave('thrown', near_site, thrown)
	check(thrown_why == 'the cave table raised an error', 'an error that is not a string gets a plain text: ' .. tostring(thrown_why))
	untouched('an error object')
	local done, batch_why = p:batch({ { 'cave', 'meta_step', near_site, raising } })
	check(
		done == nil and contains(batch_why, 'meta_step: ') and contains(batch_why, 'values boom'),
		'the same table in a batch is refused: ' .. tostring(batch_why)
	)
	untouched('that batch')

	local prologue = address('prologue_target')
	local prologue_bytes = mr.read(prologue, 5, 4)
	done, batch_why = p:batch({
		{ 'patch', 'batch_patch', mr.add(prologue, 5), '\1\0\0\0', '\2\0\0\0' },
		{ 'cave', 'batch_bad', near_site, { asm = 'jmp nowhere' } },
	})
	check(done == nil and batch_why == "batch_bad: asm:1:5: label 'nowhere' is not defined", 'a batch with a bad asm cave is refused: ' .. tostring(batch_why))
	check(mr.read(prologue, 5, 4) == prologue_bytes and not listed('batch_patch') and not listed('batch_bad'), 'and writes or registers no step')
	untouched('the refused batch')
	local prepared_site = address('asm_site_f_here')
	local thrown_ok = pcall(p.batch, p, { { 'cave', 'prepared_first', prepared_site, { asm = 'nop' } }, { 'patch', 'raises', mr.add(prologue, 5), {}, {} } })
	check(not thrown_ok, 'a batch whose second step raises raises')
	check(mr.hook_info(prepared_site) == nil and blocks() == before, 'and frees the cave it prepared')
	local fresh = p:cave('prepared_first', prepared_site, { asm = 'nop\nnop\nnop' })
	check(fresh ~= nil and mr.read(fresh, 0, 3) == '\144\144\144', 'a later cave at that address gets its own code, not the one the raised batch prepared')
	done = p:batch({
		{ 'patch', 'batch_patch', mr.add(prologue, 5), '\1\0\0\0', '\2\0\0\0' },
		{ 'cave', 'batch_good', address('asm_site_e_here'), { asm = 'add eax, 1' } },
	})
	check(done == true and mr.tonumber(mr.call(address('asm_site_e'), 'int32(int32)', 1)) == 6010, 'a batch of a patch and an asm cave installs both')
	check(mr.read(prologue, 5, 4) == '\2\0\0\0' and listed('batch_patch') and listed('batch_good'), 'and the patch is written and both are listed')
	p:remove('batch_patch')

	local late_inner = nil
	local late_target = setmetatable({ at = 3 }, {
		__index = function(_, key)
			if key == 'pattern' then
				late_inner = late_inner or { p:patch('reenter_patch', mr.add(prologue, 5), '\1\0\0\0', '\2\0\0\0') }
				return hex_of(address('asm_site_c'), 16)
			end
		end,
	})
	done, batch_why = p:batch({
		{ 'cave', 'double_call', call_site, double_spec },
		{ 'patch', 'late_patch', late_target, '\255\255\255\255', '\255\255\255\255' },
	})
	check(done == nil and batch_why == 'late_patch: unexpected bytes', 'a batch of a repeat cave and a patch is refused on the patch: ' .. tostring(batch_why))
	check(
		late_inner ~= nil and late_inner[1] == nil and late_inner[2] == 'a batch is already running',
		'a repeat cave step puts the batch flag back, so the next step still sees a batch running: ' .. tostring(late_inner and late_inner[2])
	)
	p:remove('reenter_patch')
	check(mr.read(prologue, 5, 4) == prologue_bytes and not listed('late_patch') and not listed('reenter_patch'), 'and nothing was written or listed')

	local seed = 11
	local function random(count)
		seed = (seed * 75 + 74) % 65537
		return seed % count + 1
	end
	local PIECES = { '[', ']', '{', '}', ':', ',', '+', '-', '*', ';', '.', '0x', '9', ' ', '\n', 'eax', 'ptr', 'jmp', 'ret', '{v:4}' }
	local BASE = 'add eax, 7\ncmp eax, 0x40\njz skip\nimul eax, eax, 3\nskip:\nlea eax, [rax + rax*2 + 1]'
	local WRONG = '\255\255\255\255'
	local assembled, refused = 0, 0
	before = blocks()
	for _ = 1, 300 do
		local at = random(#BASE)
		local text = BASE:sub(1, at - 1) .. PIECES[random(#PIECES)] .. BASE:sub(at + 1)
		local ok, made, fuzz_why =
			pcall(p.batch, p, { { 'cave', 'fuzz', near_site, { asm = text, echo = false } }, { 'patch', 'fuzz_stop', mr.add(prologue, 5), WRONG, WRONG } })
		if ok and made == nil and fuzz_why == 'fuzz_stop: unexpected bytes' then
			assembled = assembled + 1
		elseif ok and made == nil and type(fuzz_why) == 'string' and fuzz_why:match('^fuzz: asm:%d+:%d+: ') then
			refused = refused + 1
		else
			check(false, ('a mutated cave gave %s, %s: %q'):format(tostring(made), tostring(fuzz_why), text))
			break
		end
		if mr.hook_info(near_site) ~= nil or mr.read(near_site, 0, 5) ~= site_bytes or blocks() ~= before or listed('fuzz') then
			check(false, 'a mutated cave left something behind: ' .. text)
			break
		end
	end
	print(('  install fuzz: %d assembled then refused by the next step, %d refused at assembly'):format(assembled, refused))
	check(assembled > 0 and refused > 0, 'mutated texts in a batch were both assembled and refused, and none wrote or kept anything')

	local nested = nil
	local h_value = mr.add(address('asm_site_h'), 4)
	mr.set_log(function(message)
		echoed[#echoed + 1] = message
		if nested == nil and contains(message, 'cave echo_batch at') then
			nested = { p:batch({ { 'patch', 'from_sink', h_value, '\41\35\0\0', '\42\35\0\0' } }) }
		end
	end)
	done, batch_why = p:batch({
		{ 'cave', 'echo_batch', address('asm_site_g_here'), { asm = 'add eax, 1' } },
		{ 'patch', 'echo_patch', mr.add(prologue, 5), '\1\0\0\0', '\2\0\0\0' },
	})
	check(
		done == true and nested and nested[1] == true,
		'a log sink can run a batch on the echo of a batch cave: ' .. tostring(batch_why) .. ', ' .. tostring(nested and nested[2])
	)
	check(
		mr.read(prologue, 5, 4) == '\2\0\0\0' and listed('echo_patch') and listed('from_sink') and listed('echo_batch'),
		'the outer batch wrote its patch before the echo, and both batches are listed'
	)
	check(
		mr.tonumber(mr.call(address('asm_site_g'), 'int32(int32)', 0)) == 9 + 1 + 8001
			and mr.tonumber(mr.call(address('asm_site_h'), 'int32(int32)', 0)) == 10 + 9002,
		'the cave and the nested patch both run'
	)
	p:remove('echo_patch')
	p:remove('from_sink')

	local flush_target, FLUSH_SIGNATURE = address('hook_target'), 'int32(int32, int32)'
	local inner_done, in_sink, inner_lines, early_lines = nil, false, 0, 0
	mr.set_log(function(message)
		echoed[#echoed + 1] = message
		if contains(message, 'cave inner_echo at') then
			inner_lines = inner_lines + 1
			early_lines = early_lines + (in_sink and 1 or 0)
		end
		if inner_done == nil and contains(message, 'flush trigger') then
			in_sink = true
			inner_done = p:batch({ { 'cave', 'inner_echo', address('asm_site_j_here'), { asm = 'add eax, 1' } } })
			in_sink = false
		end
	end)
	p:postfix(flush_target, FLUSH_SIGNATURE, 'flush_trigger', function()
		error('flush trigger')
	end)
	mr.call(flush_target, FLUSH_SIGNATURE, 1, 2)
	done, batch_why = p:batch({ { 'patch', 'outer_stop', mr.add(prologue, 5), WRONG, WRONG } })
	check(inner_done == true, 'a batch run by the log sink while an outer batch flushes the link log installs its cave')
	check(done == nil and batch_why == 'outer_stop: unexpected bytes', 'and the outer batch is refused on its own step: ' .. tostring(batch_why))
	check(
		inner_lines == 1 and early_lines == 0,
		('the inner batch hands its echo to the outer one, which sends it when it ends: %d sent, %d early'):format(inner_lines, early_lines)
	)
	check(mr.tonumber(mr.call(address('asm_site_j'), 'int32(int32)', 0)) == 12 + 1 + 11001, 'and the inner cave runs')
	p:remove('flush_trigger')
	mr.set_log(function(message)
		echoed[#echoed + 1] = message
	end)

	local p2 = mr.patcher('asm_sites')
	local site_fn, site_here = address('asm_site'), address('asm_site_here')
	local b_fn, b_here = address('asm_site_b'), address('asm_site_b_here')
	local c_fn = address('asm_site_c')
	check(
		mr.eq(mr.add(site_fn, 5), site_here) and mr.eq(mr.add(b_fn, 10), b_here) and mr.eq(mr.add(c_fn, 3), near_site),
		'the host sites sit at the offsets the entries use'
	)
	check(unique(hex_of(site_fn, 24)) and unique(hex_of(b_fn, 24)) and unique(hex_of(c_fn, 16)), 'and their patterns are unique')
	local lines = {}
	local function said(part)
		for _, line in ipairs(lines) do
			if contains(line, part) then return true end
		end
		return false
	end
	local entries = {
		{
			name = 'inline_cave',
			feature = 'f_inline',
			kind = 'cave',
			pattern = hex_of(site_fn, 24),
			at = 5,
			expect = hex_of(site_here, 5),
			reads = { three = { at = 4, type = 'uint8' } },
			asm = [[
imul eax, eax, {three}
add eax, {bonus:4}
]],
			bytes = '6B C0 03 05 {bonus:4}',
		},
		{
			name = 'file_cave',
			feature = 'f_file',
			kind = 'cave',
			pattern = hex_of(b_fn, 24),
			at = 10,
			expect = hex_of(b_here, 5),
			reads = { seven = { at = 3, type = 'uint8' } },
			asm_file = 'script/test/cave.asm',
		},
		{
			name = 'mismatch_cave',
			feature = 'f_mismatch',
			kind = 'cave',
			pattern = hex_of(c_fn, 16),
			at = 3,
			expect = hex_of(near_site, 5),
			asm = 'nop\nnop',
			bytes = '90 CC',
		},
		{ name = 'lost_file', feature = 'f_lost', kind = 'cave', pattern = hex_of(c_fn, 16), at = 3, asm_file = 'script/test/none.asm' },
		{ name = 'ui_file', feature = 'f_ui_file', kind = 'cave', pattern = hex_of(c_fn, 16), at = 3, asm_file = 'ui/test/cave.asm' },
		{ name = 'text_file', feature = 'f_text_file', kind = 'cave', pattern = hex_of(c_fn, 16), at = 3, asm_file = 'script/test/cave.txt' },
		{ name = 'up_file', feature = 'f_up_file', kind = 'cave', pattern = hex_of(c_fn, 16), at = 3, asm_file = 'script/../ui/cave.asm' },
		{ name = 'tail_file', feature = 'f_tail_file', kind = 'cave', pattern = hex_of(c_fn, 16), at = 3, asm_file = 'script/test/cave.asm.txt' },
		{ name = 'dots_file', feature = 'f_dots_file', kind = 'cave', pattern = hex_of(c_fn, 16), at = 3, asm_file = 'script/test/cave.asm../../ui/x' },
		{ name = 'both_texts', feature = 'f_both', kind = 'cave', pattern = hex_of(c_fn, 16), at = 3, asm = 'nop', asm_file = 'script/test/cave.asm' },
		{ name = 'not_text', feature = 'f_not_text', kind = 'cave', pattern = hex_of(c_fn, 16), at = 3, asm = 5 },
	}
	local native = p2:sites(entries, function(line)
		lines[#lines + 1] = line
	end)
	check(mr.supports.cave_asm == true, 'supports.cave_asm is set')
	check(
		native.found('inline_cave') and native.found('file_cave') and native.found('mismatch_cave'),
		'asm, asm_file and asm with bytes entries are found: ' .. tostring(native.why('file_cave'))
	)
	check(
		not native.found('lost_file') and native.why('lost_file') == 'asm file not found: script/test/none.asm',
		'a missing asm file turns its entry off: ' .. tostring(native.why('lost_file'))
	)
	for _, name in ipairs({ 'ui_file', 'text_file', 'up_file', 'tail_file', 'dots_file' }) do
		check(
			not native.found(name) and native.why(name) == 'asm_file must be a script/<mod>/<name>.asm path',
			'an asm_file outside script/**.asm is refused before it is read: ' .. tostring(native.why(name))
		)
	end
	native.log_missing()
	check(said('both_texts not found (bad entry: asm and asm_file both given)'), 'asm and asm_file together are a bad entry')
	check(said('not_text not found (bad entry: asm, asm_file and bytes must be strings)'), 'asm that is not a string is a bad entry')
	check(native.install('inline_cave', { bonus = 10 }) == true, 'an asm entry with matching bytes installs')
	check(mr.tonumber(mr.call(site_fn, 'int32(int32)', 2)) == 2 * 9 + 2011, 'and runs: x*3, then *3 from the read, +10, +2001')
	check(native.cave_value('inline_cave', 'bonus') == 10, 'cave_value reads the slot back')
	check(said('cave inline_cave at 0x') and said('imul eax, eax, 0x3'), 'the site log has the echo')
	check(contains(native.listing('inline_cave'), 'cave inline_cave at 0x'), 'listing gives the echo text')
	local echo_lines = #lines
	check(native.install('inline_cave', { bonus = 10 }) == true and #lines == echo_lines, 'installing again is a no-op without a second echo')
	check(native.install('file_cave', { bonus = 20 }) == true, 'an asm_file entry installs: ' .. tostring(native.why('file_cave')))
	check(mr.tonumber(mr.call(b_fn, 'int32(int32)', 2)) == 2 * 49 + 3021, 'and runs the file text: x*7*7, +20, +3001')
	check(native.cave_value('file_cave', 'bonus') == 20 and native.cave_value('file_cave', 'seven') == nil, 'cave_value reads slots, not plain values')
	local ok, mismatch_reason = native.install('mismatch_cave')
	check(
		ok == false and contains(mismatch_reason, 'asm and bytes differ at +0x1'),
		'asm and bytes that differ refuse the entry: ' .. tostring(mismatch_reason)
	)
	check(mr.hook_info(near_site) == nil, 'and install nothing')
	local again_native = p2:sites(entries, function() end)
	check(
		again_native.cave_value('inline_cave', 'bonus') == 10 and again_native.cave_value('file_cave', 'bonus') == 20,
		'a second object recognises both caves as ours'
	)
	check(again_native.install('file_cave', { bonus = 20 }) == true, 'and installing through it changes nothing')
	local interrupted_object = p2:sites(entries, function() end)
	local raised = false
	debug.sethook(function()
		if not raised then
			raised = true
			error('the chunk ran longer than its budget')
		end
	end, '', 100)
	local interrupted = interrupted_object.cave_value('inline_cave', 'bonus')
	debug.sethook()
	check(raised and interrupted == nil, 'an error raised by a debug hook inside cave_value answers nil, as the budget hook did in the wave (F2)')
	check(interrupted_object.cave_value('inline_cave', 'bonus') == 10, 'and the next call on the same object reads the value')
	local plain_assemble, assembled_count = mr.assemble, 0
	mr.assemble = function(...)
		assembled_count = assembled_count + 1
		return plain_assemble(...)
	end
	local third = p2:sites(entries, function() end)
	local first_count = assembled_count
	check(first_count == 2, 'a new object assembles each installed asm cave once to recognise it: ' .. first_count)
	check(
		third.cave_value('inline_cave', 'bonus') == 10 and third.cave_value('inline_cave', 'bonus') == 10 and assembled_count == first_count,
		'cave_value then compares bytes without assembling again'
	)
	local inline_code = mr.hook_info(site_here).cave
	local imul_byte = mr.read(inline_code, 2, 1)
	test_protect(raw(inline_code), 4096, 0x40)
	mr.write(inline_code, 2, '\4')
	check(third.cave_value('inline_cave', 'bonus') == nil, 'a cave whose bytes changed is no longer recognised as ours')
	check(third.cave_value('inline_cave', 'bonus') == nil and assembled_count == first_count, 'and asking again does not assemble again')
	mr.write(inline_code, 2, imul_byte)
	test_protect(raw(inline_code), 4096, PAGE_EXECUTE_READ)
	check(third.cave_value('inline_cave', 'bonus') == 10 and assembled_count == first_count, 'the original bytes are ours again')
	mr.assemble = plain_assemble

	local BUSY = 'a batch is already running'
	local inner_site = address('asm_site_h_here')
	local frees_before = test_double_frees(mr.hop_slots)
	local prologue_pattern = hex_of(prologue, 9)
	check(unique(prologue_pattern), 'the prologue pattern is unique')

	local sink_results = nil
	local sink_spec = { asm = 'nop', echo = false }
	mr.set_log(function(message)
		echoed[#echoed + 1] = message
		if sink_results == nil and contains(message, 'sink trigger') then
			sink_results = {
				{ p:cave('sink_cave', inner_site, sink_spec) },
				{ p:batch({ { 'cave', 'sink_batch', inner_site, sink_spec } }) },
				{ p:patch('sink_patch', mr.add(prologue, 5), '\1\0\0\0', '\3\0\0\0') },
				{ p:postfix(flush_target, FLUSH_SIGNATURE, 'sink_link', function() end) },
				{ p:set('sink_set', nil, 4, 3, 0, 9) },
				{ p:frame('sink_frame', nil, 0x100) },
				{ p:relocate('sink_relocate', { { nil, '\1', '\3' } }) },
				{ p:site('sink_site', nil, function() end) },
				{ p:row('sink_row', nil, nil, 'sink_key') },
				{ p:remove('sink_trigger') },
				{ p:remove_all() },
				{ select(2, pcall(p.relocate, p, 'sink_relocate_arg', 5)) },
			}
		end
	end)
	p:postfix(flush_target, FLUSH_SIGNATURE, 'sink_trigger', function()
		error('sink trigger')
	end)
	local flushing_target = setmetatable({}, {
		__index = function(_, key)
			if key == 'pattern' then
				mr.call(flush_target, FLUSH_SIGNATURE, 1, 2)
				mr.flush_log()
				return prologue_pattern
			end
			if key == 'at' then return 5 end
		end,
	})
	done, batch_why = p:batch({ { 'patch', 'flushing_patch', flushing_target, '\1\0\0\0', '\2\0\0\0' } })
	check(sink_results ~= nil, 'the log sink ran while a batch read its target table')
	for i, call in ipairs({
		'p:cave',
		'p:batch',
		'p:patch',
		'p:postfix',
		'p:set',
		'p:frame',
		'p:relocate',
		'p:site',
		'p:row',
		'p:remove',
		'p:remove_all',
		'p:relocate with a number',
	}) do
		local result = sink_results and sink_results[i] or {}
		check(result[1] == nil and result[2] == BUSY, call .. ' from the sink during a batch is refused: ' .. tostring(result[2]))
	end
	check(done == true and mr.read(prologue, 5, 4) == '\2\0\0\0', 'the batch writes its own patch: ' .. tostring(batch_why))
	check(
		mr.hook_info(inner_site) == nil and not listed('sink_cave') and not listed('sink_batch') and not listed('sink_patch') and not listed('sink_link'),
		'and nothing the sink asked for was made'
	)
	p:remove('flushing_patch')
	p:remove('sink_trigger')
	mr.set_log(function(message)
		echoed[#echoed + 1] = message
	end)

	local inner_spec = { asm = 'add eax, 1', echo = false }
	local blocks_before = blocks()
	local inner = nil
	local function nested_spec(after_inner)
		return setmetatable({ echo = false }, {
			__index = function(_, key)
				if key == 'asm' then
					inner = { p:batch({ { 'cave', 'inner_cave', inner_site, inner_spec } }) }
					return after_inner()
				end
			end,
		})
	end
	done, batch_why = p:batch({
		{ 'cave', 'outer_cave', near_site, nested_spec(function()
			error('outer boom')
		end) },
	})
	check(
		inner and inner[1] == nil and inner[2] == BUSY,
		'a batch started from a cave table that a running batch reads is refused: ' .. tostring(inner and inner[2])
	)
	check(
		done == nil and contains(batch_why, 'outer_cave: ') and contains(batch_why, 'outer boom'),
		'the table raising after that refusal refuses the outer batch on its own step: ' .. tostring(batch_why)
	)
	check(test_double_frees(mr.hop_slots) == frees_before, 'and no cave listing is freed twice')
	check(
		mr.hook_info(near_site) == nil
			and mr.hook_info(inner_site) == nil
			and blocks() == blocks_before
			and not listed('outer_cave')
			and not listed('inner_cave'),
		'and nothing is installed, listed or left allocated'
	)
	inner = nil
	done, batch_why = p:batch({
		{ 'cave', 'outer_cave', near_site, nested_spec(function()
			return 'add eax, 1'
		end) },
		{ 'patch', 'outer_patch', mr.add(prologue, 5), '\1\0\0\0', '\2\0\0\0' },
	})
	check(inner and inner[1] == nil and inner[2] == BUSY, 'the same refusal when the table does not raise: ' .. tostring(inner and inner[2]))
	check(done == true, 'the outer batch goes on with its own plan: ' .. tostring(batch_why))
	check(
		mr.read(prologue, 5, 4) == '\2\0\0\0'
			and listed('outer_cave')
			and listed('outer_patch')
			and not listed('inner_cave')
			and mr.hook_info(inner_site) == nil,
		'and writes and lists its own steps only'
	)
	check(mr.tonumber(mr.call(address('asm_site_c'), 'int32(int32)', 0)) == 5 + 1 + 4001, 'and its cave runs')
	check(test_double_frees(mr.hop_slots) == frees_before, 'and no cave listing is freed twice')
	p:remove('outer_patch')

	local old_byte = mr.read(inner_site, 2, 1)
	local new_byte = old_byte == '\0' and '\1' or '\0'
	local reentered = {}
	local function reentering_spec(change)
		return setmetatable({ echo = false }, {
			__index = function(_, key)
				if key == 'asm' then
					reentered[#reentered + 1] = { change() }
					return 'nop'
				end
			end,
		})
	end
	local function patch_inside()
		return p:patch('reenter_patch', mr.add(inner_site, 2), old_byte, new_byte)
	end
	local function batch_inside()
		reentered.batch = { p:batch({ { 'patch', 'reenter_patch', mr.add(inner_site, 2), old_byte, new_byte } }) }
		return patch_inside()
	end
	check(p:cave('reenter_cave', inner_site, reentering_spec(batch_inside)) ~= nil, 'a single cave whose table changes something installs its own cave')
	check(
		reentered[1] and reentered[1][1] == nil and reentered[1][2] == BUSY,
		'a patch from the cave table is refused: ' .. tostring(reentered[1] and reentered[1][2])
	)
	check(
		reentered.batch and reentered.batch[1] == nil and reentered.batch[2] == BUSY,
		'a batch from the cave table is refused: ' .. tostring(reentered.batch and reentered.batch[2])
	)
	check(listed('reenter_cave') and not listed('reenter_patch'), 'and the patch is not listed next to the cave')
	check(p:cave(
		'reenter_cave',
		inner_site,
		reentering_spec(function()
			return p:remove('reenter_cave')
		end)
	) ~= nil, 'the same cave again compares and answers its start')
	check(
		reentered[2] and reentered[2][2] == BUSY and listed('reenter_cave'),
		'a remove from the table it compares is refused: ' .. tostring(reentered[2] and reentered[2][2])
	)
	local reading_site = setmetatable({}, {
		__index = function(_, key)
			if key == 'pattern' then
				reentered[3] = { patch_inside() }
				return prologue_pattern
			end
			if key == 'at' then return 5 end
		end,
	})
	local moved, moved_why = p:relocate('reenter_relocate', { { reading_site, '\9\9\9\9', '\4\0\0\0' } })
	check(moved == nil and not listed('reenter_relocate'), 'a relocation with wrong bytes is refused: ' .. tostring(moved_why))
	check(
		reentered[3] and reentered[3][2] == BUSY and not listed('reenter_patch'),
		'a patch from a relocation site table is refused: ' .. tostring(reentered[3] and reentered[3][2])
	)
elseif SCENARIO == 'cave_near' then
	run_mod(OURS)
	local mr = _G.memreader_plus
	local function address(name)
		return mr.pointer(test_function(name))
	end
	local cell = mr.alloc(8)
	local function raw(pointer)
		mr.write(cell, 0, pointer)
		return mr.read(cell, 0, 8)
	end
	local function blocks()
		return test_virtual_blocks(mr.hop_slots)
	end
	local function queries()
		return test_plus_queries(mr.hop_slots)
	end
	local function granule(pointer)
		return mr.tostring(pointer):sub(1, -5)
	end
	local function page(pointer)
		return mr.tostring(pointer):sub(1, -4)
	end
	local PAGE_READWRITE, PAGE_EXECUTE_READ = 4, 0x20
	local NO_MEMORY = "no free memory near the game's code for the cave"
	local CAVE = { asm = 'add eax, 1', echo = false }
	local first = address('many_site_0')
	local function site(i)
		return mr.add(first, 16 * i + 3)
	end
	local function run(i)
		return mr.tonumber(mr.call(mr.add(first, 16 * i), 'int32(int32)', 0))
	end
	local p = mr.patcher('near_mod')
	local function cave_pages()
		local row = mr.capacity().cave_pages or {}
		return ('%s/%s/%s'):format(tostring(row.used), tostring(row.room), tostring(row.limit))
	end
	check(cave_pages() == '0/64/1024', 'capacity shows 64 cave pages reserved at load, none used: ' .. cave_pages())
	local fill_site = address('asm_site_c_here')
	local filled = test_fill_near(raw(fill_site))
	check(filled > 0, ('the free memory near the site is taken after load: %d granules reserved'):format(filled))
	local before = blocks()
	queries()

	local caves, made, ran, reuse_queries = {}, 0, 0, 0
	for i = 0, 62 do
		local queries_before = queries()
		caves[i] = p:cave('many_' .. i, site(i), CAVE)
		if i == 1 then reuse_queries = queries() - queries_before end
		if caves[i] then made = made + 1 end
		if run(i) == i + 1 + 1000 + 1 then ran = ran + 1 end
	end
	print(('  queries of a cave in a block with room: %d'):format(reuse_queries))
	check(made == 63 and ran == 63, ('63 asm caves near one site install and run: %d made, %d ran'):format(made, ran))
	check(blocks() == before, ('from the blocks reserved at load, nothing reserved now: %d'):format(blocks() - before))

	local prologue = address('prologue_target')
	local WRONG = '\255\255\255\255'
	local seen = nil
	local watching = setmetatable({ echo = false }, {
		__index = function(_, key)
			if key ~= 'asm' then return nil end
			local start, protection = test_newest_allocation()
			local live = true
			for i = 48, 62 do
				live = live and test_protection(raw(caves[i])) == PAGE_EXECUTE_READ and run(i) == i + 1002
			end
			seen = { start = mr.pointer(start), allocated = protection, now = test_protection(start), live = live }
			return 'add eax, 1'
		end,
	})
	local done, batch_why = p:batch({ { 'cave', 'many_63', site(63), watching }, { 'patch', 'stop', mr.add(prologue, 5), WRONG, WRONG } })
	check(done == nil and batch_why == 'stop: unexpected bytes', 'a batch that prepares a 64th cave is refused on its patch: ' .. tostring(batch_why))
	check(
		seen ~= nil and seen.allocated == PAGE_READWRITE and seen.now == PAGE_READWRITE,
		'the prepared cave is committed read-write: ' .. tostring(seen and seen.allocated) .. ', ' .. tostring(seen and seen.now)
	)
	check(seen ~= nil and granule(seen.start) == granule(caves[48]), 'and shares its 64 KB block with caves that are already installed')
	local own_page = true
	for i = 0, 62 do
		own_page = own_page and not (seen and page(seen.start) == page(caves[i]))
	end
	check(own_page, 'but has a page of its own')
	check(seen ~= nil and seen.live, 'while it is read-write, the installed caves on its block stay execute-read and run')
	check(seen ~= nil and test_protection(raw(seen.start)) == 0, 'the refused batch gives the page back')
	local still = true
	for i = 0, 62 do
		still = still and test_protection(raw(caves[i])) == PAGE_EXECUTE_READ
	end
	check(still and blocks() == before, 'and every installed cave is execute-read, no block released or added')
	local last = p:cave('many_63', site(63), CAVE)
	check(last ~= nil and seen ~= nil and mr.eq(last, seen.start), 'the 64th cave then takes the page that was given back')
	check(last ~= nil and test_protection(raw(last)) == PAGE_EXECUTE_READ and run(63) == 63 + 1002, 'is execute-read and runs')
	caves[63] = last
	local granules, pages, granule_count, page_count = {}, {}, 0, 0
	for i = 0, 63 do
		if caves[i] and not granules[granule(caves[i])] then
			granules[granule(caves[i])] = true
			granule_count = granule_count + 1
		end
		if caves[i] and not pages[page(caves[i])] then
			pages[page(caves[i])] = true
			page_count = page_count + 1
		end
	end
	check(granule_count == 4 and page_count == 64 and blocks() == before, ('64 caves: %d blocks, %d pages'):format(granule_count, page_count))
	check(cave_pages() == '64/64/1024', 'capacity shows all 64 reserved pages used: ' .. cave_pages())

	local blocks_filled = blocks()
	local walk_start = queries()
	local started = mr.ticks()
	local refused, refused_why = p:cave('after_fill', fill_site, CAVE)
	local spent = mr.elapsed_us(started)
	local walked = queries() - walk_start
	print(('  near search with the range filled (%d granules reserved): %d queries, %.0f us'):format(filled, walked, spent))
	check(refused == nil and refused_why == NO_MEMORY, 'with no free memory in reach the cave is refused: ' .. tostring(refused_why))
	check(spent < 100000, ('and answers within 100 ms: %.0f us'):format(spent))
	check(mr.hook_info(fill_site) == nil and blocks() == blocks_filled, 'nothing is installed or reserved')
	walk_start = queries()
	started = mr.ticks()
	local again, again_why = p:cave('after_fill', fill_site, CAVE)
	local again_spent = mr.elapsed_us(started)
	local again_walked = queries() - walk_start
	print(('  the same cave again: %d queries, %.0f us'):format(again_walked, again_spent))
	check(again == nil and again_why == NO_MEMORY, 'a retry gets the same answer: ' .. tostring(again_why))
	check(again_walked <= reuse_queries, ('without searching again: %d queries'):format(again_walked))
	check(walked - again_walked <= 1024, ('the search stops after at most 1024 queries: %d'):format(walked - again_walked))
	test_unfill_near()
	walk_start = queries()
	local later, later_why = p:cave('later', address('asm_site_f_here'), CAVE)
	check(
		later == nil and later_why == NO_MEMORY and queries() - walk_start <= reuse_queries,
		'after the memory is free again a cave near the same code still answers at once for this session: ' .. tostring(later_why)
	)
	local all_run = true
	for i = 0, 63 do
		all_run = all_run and run(i) == i + 1002
	end
	check(all_run, 'the 64 caves still run')
elseif SCENARIO == 'cave_near_image_size' then
	local NEAR_REACH = 0x70000000
	local old_size = test_image_size(NEAR_REACH)
	run_mod(OURS)
	test_image_size(old_size)
	local mr = _G.memreader_plus
	local first = mr.pointer(test_function('many_site_0'))
	local first_text = mr.tostring(first)
	local above, ran = 0, 0
	for i = 0, 63 do
		local cave = mr.patcher('image_mod'):cave('many_' .. i, mr.add(first, 16 * i + 3), { asm = 'add eax, 1', echo = false })
		local text = cave and mr.tostring(cave) or ''
		if #text == #first_text and text > first_text then above = above + 1 end
		if mr.tonumber(mr.call(mr.add(first, 16 * i), 'int32(int32)', 0)) == i + 1002 then ran = ran + 1 end
	end
	local row = mr.capacity().cave_pages or {}
	check(
		row.used == 64 and row.room == 64,
		('a game image as long as the reach still gets 4 blocks at load: %s/%s'):format(tostring(row.used), tostring(row.room))
	)
	check(above == 64, ('every block lies above the image start, in reach of its end: %d of 64 caves'):format(above))
	check(ran == 64, ('and the caves run: %d of 64'):format(ran))
elseif SCENARIO == 'cave_near_unreserved' then
	local logged = collect_log()
	local NOTE = "[memreader Plus] cave memory near the game's code: 0 of 4 blocks reserved at load, later asm caves search for more"
	local function pages(mr)
		local row = mr.capacity().cave_pages or {}
		return ('%s/%s/%s'):format(tostring(row.used), tostring(row.room), tostring(row.limit))
	end
	if PASS == 1 then
		local filled = test_fill_near(test_function('asm_site_c_here'))
		check(filled > 0, ('the free memory near the site is taken before Plus loads: %d granules reserved'):format(filled))
		run_mod(OURS)
		local mr = _G.memreader_plus
		check(mr ~= nil and type(mr.plus_version) == 'string', 'Plus loads without cave memory near the game')
		check(count_logged(logged, NOTE) == 1, 'and logs once that it reserved none')
		check(mr ~= nil and pages(mr) == '0/0/1024', 'capacity shows no cave pages reserved: ' .. (mr and pages(mr) or '?'))
		mr.set_log(function(message)
			logged[#logged + 1] = message
		end)
		check(count_logged(logged, NOTE) == 1, 'a second log sink does not get the line again')
		test_unfill_near()
		local cave, why = mr.patcher('late_mod'):cave('late', mr.pointer(test_function('asm_site_c_here')), { asm = 'add eax, 1', echo = false })
		check(cave ~= nil, 'once memory near the game is free an asm cave finds a block by the search: ' .. tostring(why))
		check(pages(mr) == '1/16/1024', 'and reserves one block for it: ' .. pages(mr))
		NEXT_PASS = failures == 0
	else
		run_mod(OURS)
		local mr = _G.memreader_plus
		check(mr ~= nil, 'Plus loads again in a new Lua state')
		check(count_logged(logged, NOTE) == 0, 'without logging the line again')
		check(mr ~= nil and string.sub(pages(mr), -8) == '/16/1024', 'and keeps the block of the session: ' .. (mr and pages(mr) or '?'))
	end
else
	error('unknown scenario ' .. tostring(SCENARIO))
end

print(failures == 0 and 'PASS ' .. SCENARIO .. (PASS > 1 and ' pass ' .. PASS or '') or ('FAILED ' .. SCENARIO .. ': ' .. failures))
if NEXT_PASS then return end
os.exit(failures == 0 and 0 or 1)
