local mr = _G.memreader_plus
local MURMUR = '48 89 5C 24 08 44 8B CA 8B DA 41 C1 E9 02 41 BA ED 5E 54 4A'
local HASH = 'uint32(pointer, uint32)'
local KEY = 'wh2_main_hef_bow_arrow'
local lines, failures = {}, 0

local function say(text)
	lines[#lines + 1] = text
	if ModLog then ModLog('[mrp_site_smoke] ' .. text) end
end

local function check(ok, what)
	if not ok then failures = failures + 1 end
	say((ok and 'ok   ' or 'FAIL ') .. what)
end

local function hash(address, text, length)
	return mr.tostring(mr.call(address, HASH, text, length))
end

local function refusal(f, ...)
	local ok, err = pcall(f, ...)
	return not ok and tostring(err) or nil
end

local function contains(text, part)
	return text ~= nil and string.find_lua(text, part, 1, true) ~= nil
end

local function counter_bytes(scratch, counter)
	mr.write(scratch, 0, counter)
	return mr.read(scratch, 0, 8)
end

local function run()
	check(mr.plus_version == '0.10.0', 'plus_version is ' .. tostring(mr.plus_version))
	local murmur, count = mr.find_pattern(MURMUR)
	check(count == 1, 'the murmur hash pattern matches once: ' .. tostring(count))
	local text = mr.alloc(#KEY + 1)
	mr.write(text, 0, KEY)
	local expected, short = hash(murmur, text, #KEY), hash(murmur, text, 3)
	check(expected ~= short, 'the test hash changes with the length: ' .. expected .. ' and ' .. short)

	local counter, scratch = mr.alloc(16), mr.alloc(16)
	local cave_code = '\80\72\184' .. counter_bytes(scratch, counter) .. '\255\0\88'
	local cave_ok, cave_result = pcall(mr.code_cave, murmur, cave_code)
	check(cave_ok, 'code_cave on the start of the murmur hash: ' .. tostring(cave_result))
	check(mr.hook_info(murmur) and mr.hook_info(murmur).kind == 'cave', 'hook_info calls it a cave')
	local cave_at = mr.hook_info(murmur).cave
	check(
		cave_ok and cave_at and mr.eq(cave_at, cave_result) and mr.read(cave_at, 0, #cave_code) == cave_code,
		'hook_info gives the cave address and its bytes'
	)
	check(hash(murmur, text, #KEY) == expected, 'the hash is unchanged through the cave')
	check(mr.read_uint32(counter, 0) >= 1, 'the cave ran: ' .. tostring(mr.read_uint32(counter, 0)))

	local site = mr.add(murmur, 5)
	local seen, write_length = { calls = 0 }, false
	local ok, site_error = pcall(mr.hook_site, site, function(regs)
		if not mr.eq(regs.rcx, text) then return end
		seen.calls = seen.calls + 1
		seen.types = mr.type(regs.rcx) .. ' ' .. mr.type(regs.edx) .. ' ' .. mr.type(regs.xmm0q)
		seen.length = mr.tonumber(regs.edx)
		regs.xmm0q = regs.xmm0q
		regs.xmm1q = regs.xmm1q
		regs.r11d = mr.uint32('\255\255\255\255')
		seen.r11 = mr.tostring(regs.r11d)
		regs.r10d = regs.r10d
		if write_length then regs.edx = mr.uint32(3) end
	end)
	check(ok, 'hook_site 5 bytes into the murmur hash: ' .. tostring(site_error))
	check(hash(murmur, text, #KEY) == expected, 'the hash is unchanged through a site that only reads and writes back')
	check(seen.calls == 1, 'the site callback ran once for our call: ' .. seen.calls)
	check(seen.types == 'pointer uint32 uint64', 'register types: ' .. tostring(seen.types))
	check(seen.length == #KEY, 'edx held the length: ' .. tostring(seen.length))
	check(seen.r11 == '4294967295', 'a 32-bit register written with 0xFFFFFFFF reads back exactly: ' .. tostring(seen.r11))
	write_length = true
	check(hash(murmur, text, #KEY) == short, 'a write to edx changes the hash to the one for length 3')
	write_length = false
	local info = mr.hook_info(site)
	check(info and info.kind == 'site' and info.attached and info.error == nil, 'hook_info of the site: ' .. tostring(info and info.error))
	say('site calls ' .. tostring(info and info.calls) .. ', other thread calls ' .. tostring(info and info.other_thread_calls))

	check(contains(refusal(mr.hook_site, mr.add(murmur, 1), function() end), 'refused: '), 'a site inside an instruction is refused')
	check(contains(refusal(mr.code_cave, mr.add(murmur, 1), cave_code), 'refused: '), 'a cave inside an instruction is refused')
	check(contains(refusal(mr.code_cave, site, cave_code), 'already holds a site hook'), 'a cave on a site is refused')

	mr.unhook(site)
	check(hash(murmur, text, #KEY) == expected and seen.calls == 2, 'after unhook the site stops and the hash is unchanged')

	local spec = {
		owner = 'plus_smoke',
		id = 'pre_comment',
		path = 'ui/loading_ui/battle.twui.xml',
		once = true,
		ops = { { after = '<layout', attribute = 'comment', value = 'plus_smoke' } },
	}
	local registered, why = mr.file_edit(spec)
	local status = mr.file_edit_status()
	local off = status.off and #status.off or 0
	say(
		'file edits: state '
			.. tostring(status.state)
			.. ', files '
			.. tostring(status.files)
			.. ', results '
			.. tostring(status.results)
			.. ', parts off '
			.. off
	)
	check(registered == true and status.state == 'on' and status.results >= 1 and off == 0, 'a file edit registers and is held: ' .. tostring(why))
	check(mr.twui ~= nil and mr.hop_slots() > 0, 'twui and hop_slots are there')
end

if not mr then
	check(false, 'memreader_plus loaded')
else
	local ok, err = pcall(run)
	if not ok then check(false, 'the smoke stopped with an error: ' .. tostring(err)) end
end
say(failures == 0 and 'PASS' or ('FAILED ' .. failures))
return table.concat(lines, '\n')
