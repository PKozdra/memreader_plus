local mr = _G.memreader_plus
local HASH = 'uint32(pointer, uint32)'
local MURMUR = '48 89 5C 24 08 44 8B CA 8B DA 41 C1 E9 02 41 BA ED 5E 54 4A'
local MURMUR_9_0_1 = 0x4df770
local STR_REVERSE_9_0_1 = 0x18556b4
local STRING_HASH_9_0_1 = 0x4fc0d0
local UNIT_CAP =
	'80 B9 ?? ?? ?? ?? ?? 73 ?? 48 8B 81 ?? ?? ?? ?? 48 8B 88 ?? ?? ?? ?? 48 8B 81 ?? ?? ?? ?? B9 ?? ?? ?? ?? 8B 80 ?? ?? ?? ?? 3B C1 0F 47 C1 C3 B8 ?? ?? ?? ?? C3'
local LIMIT = 'uint32(pointer)'
local STRING_HASH = 'uint32(pointer, pointer)'
local KEY = 'wh2_main_hef_bow_arrow'

local steps = {}

local function murmur_text()
	local text = mr.alloc(#KEY + 1)
	mr.write(text, 0, KEY)
	return mr.add(mr.base, MURMUR_9_0_1), text
end

function steps.rules()
	return {
		exact_2_24 = tostring(2 ^ 24 + 1 == 2 ^ 24),
		point_one = tostring(0.1),
		bit = tostring(bit) .. ' ' .. tostring(bit and bit.bits),
		format_2_31 = string.format('%d', 2 ^ 31),
		coroutine = tostring(coroutine),
	}
end

function steps.alone()
	local names = {}
	for name in pairs(package.loaded) do
		if string.match(name, 'memreader') then names[#names + 1] = name end
	end
	return { plus_version = mr.plus_version, plus_api = mr.plus_api, same = _G.memreader == mr, loaded = table.concat(names, ' ') }
end

function steps.pattern()
	local murmur = mr.add(mr.base, MURMUR_9_0_1)
	local found, count = mr.find_pattern(MURMUR)
	local info = mr.hook_info(murmur)
	return { hooked = info ~= nil, found_at_murmur = found == murmur, count = count }
end

function steps.chain()
	local murmur, text = murmur_text()
	mr.unhook(murmur)
	local lower, upper, game_calls = 0, 0, 0
	local function bottom(data, size)
		if mr.eq(data, text) then
			lower = lower + 1
		else
			game_calls = game_calls + 1
		end
		return mr.hook_next(murmur, data, size)
	end
	local function top(data, size)
		if mr.eq(data, text) then upper = upper + 1 end
		return mr.hook_next(murmur, data, size)
	end
	mr.hook(murmur, HASH, bottom)
	mr.hook(murmur, HASH, top)
	local hash = mr.tostring(mr.call(murmur, HASH, text, #KEY))
	local info = mr.hook_info(murmur)
	mrp_chain = {
		murmur = murmur,
		top = top,
		counts = function()
			return upper, lower, game_calls
		end,
	}
	return { hash = hash, upper = upper, lower = lower, callbacks = info.callbacks, error = info.error }
end

function steps.chain_after()
	local upper, lower, game_calls = mrp_chain.counts()
	local info = mr.hook_info(mrp_chain.murmur)
	mr.unhook(mrp_chain.murmur, mrp_chain.top)
	local left = mr.hook_info(mrp_chain.murmur).callbacks
	mr.unhook(mrp_chain.murmur)
	return { game_calls = game_calls, calls = info.calls, callbacks = info.callbacks, error = info.error, left_after_one_unhook = left }
end

function steps.probe_start()
	local murmur = mr.add(mr.base, MURMUR_9_0_1)
	mr.unhook(murmur)
	mrp_probe = { calls = 0, murmur = murmur, start = mr.ticks() }
	mr.hook(murmur, HASH, function(data, size)
		mrp_probe.calls = mrp_probe.calls + 1
		return mr.hook_next(murmur, data, size)
	end)
	local _, text = murmur_text()
	return { mine = mr.tostring(mr.call(murmur, HASH, text, #KEY)), calls = mrp_probe.calls }
end

function steps.probe_end()
	local info = mr.hook_info(mrp_probe.murmur)
	mr.unhook(mrp_probe.murmur)
	return { calls = mrp_probe.calls, counted = info.calls, error = info.error, seconds = mr.elapsed_us(mrp_probe.start) / 1e6 }
end

local function function_starts(limit)
	local lfanew = mr.read_int32(mr.base, 0x3C)
	local pdata = mr.add(mr.base, mr.read_uint32(mr.base, lfanew + 24 + 112 + 3 * 8, true))
	local size = mr.read_uint32(mr.base, lfanew + 24 + 112 + 3 * 8 + 4)
	local starts = {}
	local step = math.max(1, math.floor(size / 12 / (limit * 4)))
	for i = 0, size / 12 - 1, step do
		local b = mr.read_uint32(pdata, i * 12, true)
		local e = mr.read_uint32(pdata, i * 12 + 4, true)
		local unwind = mr.add(mr.base, mr.read_uint32(pdata, i * 12 + 8, true))
		local ok_read, flags = pcall(mr.read_uint8, unwind, 0)
		if ok_read and mr.tonumber(mr.sub(e, b)) >= 32 then
			local prolog = mr.read_uint8(unwind, 1)
			local chained = math.floor(flags / 8) % 8 >= 4
			if not chained and prolog >= 5 then starts[#starts + 1] = mr.add(mr.base, b) end
		end
		if #starts >= limit * 2 then break end
	end
	return starts
end

function steps.capacity(want)
	want = want or 300
	local starts = function_starts(want)
	local function noop() end
	local hooked, refused, before = 0, 0, 0
	local memory_error, other_error
	local began = mr.ticks()
	for _, address in ipairs(starts) do
		if hooked + before >= want or mr.elapsed_us(began) > 8000000 then break end
		if mr.hook_info(address) then
			before = before + 1
		else
			local ok, err = pcall(mr.hook, address, 'void()', noop)
			if ok then
				mr.unhook(address)
				hooked = hooked + 1
			elseif string.match(err, 'no free memory') or string.match(err, 'at most') then
				memory_error = err
				break
			elseif string.match(err, 'read%-only executable') then
				refused = refused + 1
			else
				other_error = other_error or err
				refused = refused + 1
			end
		end
	end
	return { candidates = #starts, hooked = hooked, refused = refused, already = before, memory_error = memory_error, other_error = other_error }
end

local function ca_string(text)
	local s = mr.alloc(16 + #text + 1)
	mr.write(s, 16, text .. '\0')
	mr.write(s, 0, mr.uint32(#text))
	mr.write(s, 4, mr.uint32(#text))
	mr.write(s, 8, mr.add(s, 16))
	return s
end

function steps.next_then_error()
	local murmur, string_hash = mr.add(mr.base, MURMUR_9_0_1), mr.add(mr.base, STRING_HASH_9_0_1)
	local key = ca_string(KEY)
	local data = mr.add(key, 16)
	local hashed = 0
	mr.unhook(murmur)
	mr.unhook(string_hash)
	mr.hook(murmur, HASH, function(bytes, size)
		if mr.eq(bytes, data) then hashed = hashed + 1 end
		return mr.hook_next(murmur, bytes, size)
	end)
	local plain = mr.tostring(mr.call(string_hash, STRING_HASH, nil, key))
	local plain_hashed = hashed
	hashed = 0
	mr.hook(string_hash, STRING_HASH, function(hasher, text)
		mr.hook_next(string_hash, hasher, text)
		error('fails after hook_next')
	end)
	local result = mr.tostring(mr.call(string_hash, STRING_HASH, nil, key))
	local info = mr.hook_info(string_hash)
	mr.unhook(murmur)
	return { plain = plain, plain_hashed = plain_hashed, result = result, hashed = hashed, attached = info.attached, error = info.error }
end

local function find_unit_cap()
	local address, count = mr.find_pattern(UNIT_CAP)
	assert(count == 1, 'unit cap pattern matched ' .. count .. ' times')
	return address
end

local function first_army(faction)
	local forces = faction:military_force_list()
	for i = 0, forces:num_items() - 1 do
		local force = forces:item_at(i)
		if force:has_general() and not force:is_armed_citizenry() then return force end
	end
end

local function limits(ai_key)
	local human = first_army(cm:get_faction(cm:get_local_faction_name(true)))
	local ai = first_army(cm:get_faction(ai_key or 'wh_main_emp_empire'))
	local human_limit = human:unit_count_limit()
	return { human = human_limit, human_type = type(human_limit), ai = ai and ai:unit_count_limit(), units = human:unit_list():num_items() }
end

function steps.unit_cap(value)
	local unit_cap = find_unit_cap()
	mr.unhook(unit_cap)
	mr.hook(unit_cap, LIMIT, function()
		return value or 30
	end)
	local result = limits()
	local info = mr.hook_info(unit_cap)
	result.calls, result.error = info.calls, info.error
	return result
end

function steps.unit_cap_grant()
	local force = first_army(cm:get_faction(cm:get_local_faction_name(true)))
	local lookup = cm:char_lookup_str(force:general_character())
	local unit = force:unit_list():item_at(1):unit_key()
	local before = force:unit_list():num_items()
	cm:grant_unit_to_character(lookup, unit)
	local after = force:unit_list():num_items()
	if after > before then cm:remove_unit_from_character(lookup, unit) end
	return { before = before, after = after, back = force:unit_list():num_items() }
end

function steps.unit_cap_end()
	local unit_cap = find_unit_cap()
	local info = mr.hook_info(unit_cap)
	mr.unhook(unit_cap)
	local result = limits()
	result.calls, result.error = info.calls, info.error
	return result
end

function steps.callback_fault()
	local unit_cap = find_unit_cap()
	local target = mr.add(mr.base, STR_REVERSE_9_0_1)
	local function report_me()
		local marker = 'fault-in-callback-through-call'
		mr.write(target, 0, '\15\11')
		return string.reverse(marker)
	end
	mr.unhook(unit_cap)
	mr.hook(unit_cap, LIMIT, function()
		report_me()
		return 30
	end)
	return mr.call(unit_cap, LIMIT, nil)
end

function steps.crash()
	local target = mr.add(mr.base, STR_REVERSE_9_0_1)
	local function report_me()
		local marker = 'forced-by-mrp-session'
		mr.write(target, 0, '\15\11')
		return string.reverse(marker)
	end
	return report_me()
end

return steps[MRP_STEP](MRP_ARG)
