local mr = _G.memreader_plus
local HASH = 'uint32(pointer, uint32)'
local MURMUR = '48 89 5C 24 08 44 8B CA 8B DA 41 C1 E9 02 41 BA ED 5E 54 4A'
local MURMUR_9_0_1 = 0x4df770
local STR_REVERSE_9_0_1 = 0x18556b4
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
