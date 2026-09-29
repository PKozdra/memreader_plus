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
	['plus_api'] = '5',
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
	['call bad address'] = 'false, true',
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
		check(mr.plus_api == 5, 'plus_api is 5')
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
		local found_after, count_after = mr.find_pattern(mixed_pattern)
		check(found_after == mixed and count_after == count_before, 'find_pattern sees through our hook: ' .. tostring(count_after))
		local cell = mr.alloc(4)
		mr.hook(store, 'void(pointer, int32)', function(p, value)
			mr.call(mr.hook_info(store).original, 'void(pointer, int32)', p, mr.add(value, 10))
		end)
		mr.call(store, 'void(pointer, int32)', cell, 5)
		check(mr.read_int32(cell, 0) == 16, 'void hook')

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
			{ run(hook, mr.base, TARGET, hooked), "error: bad argument #1 to 'hook' (not an address in read-only executable code)" },
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
elseif SCENARIO == 'fault_report' or SCENARIO == 'fault_report_no_log' or SCENARIO == 'fault_report_off' or SCENARIO == 'fault_report_in_callback' then
	io.stdout:setvbuf('no')
	local log = PASS == 1 and 'script_log_010203_0404.txt' or 'script_log_010203_0405.txt'
	if SCENARIO == 'fault_report' then io.open(log, 'wb'):close() end
	run_mod(OURS)
	local mr = _G.memreader_plus
	pcall(mr.call, mr.pointer(test_function('read_null')), 'int32()')
	check(
		not exists('memreader_crash_report_010203_0404.txt') and not exists('memreader_crash_report_010203_0405.txt'),
		'a fault inside a guarded call writes no report'
	)
	check(not pcall(mr.call, mr.pointer(test_function('raise_lua_error')), 'void(pointer)', mr.pointer(test_state())), 'a Lua error leaves a guarded call')
	check(not pcall(mr.set_crash_reports, 'yes'), 'set_crash_reports takes a boolean')
	if SCENARIO == 'fault_report_off' and PASS > 1 then mr.set_crash_reports(false) end
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
			else
				test_crash()
			end
			return marker
		end
		print('an unguarded fault on the script thread (expected to crash)')
		report_me()
		print('did not crash')
		os.exit(0)
	end
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
