local mr = _G.memreader_plus
local shared = package.loaded.q5_shared or {}
package.loaded.q5_shared = shared

local q5 = {}

local SIGNATURE = 'int32(pointer, pointer)'
local PATTERNS = {
	link = '40 53 48 83 EC ?? 48 8B D9 48 8B CA E8 ?? ?? ?? ?? 48 8B 53 18 33 C9 48 85 D2 74 06 8B 8A ?? ?? ?? ?? 8B D1',
	cave = '40 53 48 83 EC ?? 48 83 79 18 00 48 8B D9 74 25 48 8B CA E8 ?? ?? ?? ?? 48 8B 4B 18 48 8B 91 ?? ?? ?? ?? 48 8B C8 8B 52 34',
	raw = '40 53 48 83 EC ?? 48 83 79 18 00 48 8B D9 74 21 48 8B CA E8 ?? ?? ?? ?? 48 8B 4B 18 8B 91 ?? ?? ?? ?? 48 8B C8 E8 ?? ?? ?? ?? B8 ?? ?? ?? ?? EB 02 33 C0 48 83 C4 ?? 5B C3 CC CC CC 48 8B 41 20 48 85 C0',
}
local TAGS = { 'b_pre', 'a_pre', 'a_post', 'b_post', 'a_post!', 'b_post!' }
local CAVE_BYTES = '\144\144\144\144'
local STEP_BYTES = 1
local STEP_COUNT = 8
local PAD_SIZE = STEP_BYTES * STEP_COUNT
local PAD_FIRST = 256
local PAD_BLOCK = 4000
local PAD_BLOCKS = 80
local PAD_READ = 4096
local LOAD_TRIES = 4
local RETRY_US = 2000
local KERNEL_NAMES = {
	pid = 'GetCurrentProcessId',
	snapshot = 'CreateToolhelp32Snapshot',
	first = 'Thread32First',
	step = 'Thread32Next',
	close = 'CloseHandle',
}

local state = { skip = false, driving = false, order = {}, ran = {}, found = {}, counts = {}, pad = nil, kernel = nil, entry = nil, baseline = nil }

local function offset_text(at)
	local text = string.lower(mr.tostring(mr.sub(at, mr.base)))
	return (string.gsub(text, '^0+', ''))
end

local function find_once(name)
	if state.found[name] then return state.found[name] end
	local at, count = mr.find_pattern(PATTERNS[name])
	state.counts[name] = count
	if count ~= 1 then return nil, name .. ' pattern matched ' .. tostring(count) .. ' times' end
	state.found[name] = at
	return at
end

local function owner(name)
	local handle, why = mr.patcher(name)
	if not handle then error('no patcher for ' .. name .. ': ' .. tostring(why)) end
	return handle
end

local function ui_root()
	return core and core:get_ui_root() or nil
end

local function note(tag)
	if not state.driving then return end
	local order = state.order
	order[#order + 1] = tag
	state.ran[tag] = (state.ran[tag] or 0) + 1
end

local function a_prefix()
	note('a_pre')
end

local function b_prefix(call)
	note('b_pre')
	if state.skip then call:skip(0) end
end

local function a_postfix(call)
	note(call.skipped and 'a_post!' or 'a_post')
end

local function b_postfix(call)
	note(call.skipped and 'b_post!' or 'b_post')
end

local function raw_cave(at, code)
	local start = mr.code_cave(at, code)
	return start
end

local function line_of(f)
	local ok, info = pcall(function()
		return debug.getinfo(f, 'S')
	end)
	return ok and info and info.linedefined or nil
end

local function free_padding(at)
	return not mr.function_start(at) and not mr.function_start(mr.add(at, PAD_SIZE - 1))
end

local function pad_at()
	if state.pad then return state.pad end
	local start, why = find_once('link')
	if not start then return nil, why end
	local run = string.rep('\204', PAD_SIZE)
	for block = 0, PAD_BLOCKS - 1 do
		local offset = PAD_FIRST + block * PAD_BLOCK
		local bytes = mr.read_original(start, offset, PAD_READ)
		local from = string.find_lua(bytes, run, 1, true)
		while from do
			local at = mr.add(start, offset + from - 1)
			if free_padding(at) then
				state.pad = at
				return at
			end
			from = string.find_lua(bytes, run, from + 1, true)
		end
	end
	return nil, 'no free padding found'
end

local function export_address(module, name)
	local base = module.base
	local headers = mr.add(base, mr.read_uint32(base, 0x3C, true))
	local forwards_from = mr.read_uint32(headers, 0x88, true)
	local forwards_to = mr.tonumber(forwards_from) + mr.read_uint32(headers, 0x8C)
	local directory = mr.add(base, forwards_from)
	local functions = mr.add(base, mr.read_uint32(directory, 0x1C, true))
	local names = mr.add(base, mr.read_uint32(directory, 0x20, true))
	local ordinals = mr.add(base, mr.read_uint32(directory, 0x24, true))
	for i = 0, mr.read_uint32(directory, 0x18) - 1 do
		if mr.read(mr.add(base, mr.read_uint32(names, i * 4, true)), 0, #name + 1) == name .. '\0' then
			local rva = mr.read_uint32(functions, mr.read_uint16(ordinals, i * 2) * 4, true)
			if mr.tonumber(rva) >= mr.tonumber(forwards_from) and mr.tonumber(rva) < forwards_to then return nil end
			return mr.add(base, rva)
		end
	end
	return nil
end

local function kernel_api()
	if state.kernel ~= nil then return state.kernel or nil end
	state.kernel = false
	for module in mr.modules() do
		if string.lower(module.name) == 'kernel32.dll' then
			local api = {}
			for key, name in pairs(KERNEL_NAMES) do
				api[key] = export_address(module, name)
			end
			if api.pid and api.snapshot and api.first and api.step and api.close then state.kernel = api end
			break
		end
	end
	return state.kernel or nil
end

local function thread_count()
	local api = kernel_api()
	if not api then return nil end
	local pid = mr.tonumber(mr.call(api.pid, 'uint32()'))
	local snapshot = mr.call(api.snapshot, 'uint64(uint32, uint32)', 4, 0)
	if mr.tonumber(snapshot) == 0 or mr.tonumber(snapshot) >= 16777216 then return nil end
	state.entry = state.entry or mr.alloc(32)
	mr.write(state.entry, 0, mr.uint32(28))
	local count = 0
	local more = mr.tonumber(mr.call(api.first, 'int32(uint64, pointer)', snapshot, state.entry))
	local guard = 0
	while more ~= 0 and guard < 50000 do
		if mr.read_uint32(state.entry, 12) == pid then count = count + 1 end
		more = mr.tonumber(mr.call(api.step, 'int32(uint64, pointer)', snapshot, state.entry))
		guard = guard + 1
	end
	mr.call(api.close, 'int32(uint64)', snapshot)
	return count
end

local function threads_text()
	local ok, count = pcall(thread_count)
	return ok and count and tostring(count) or '?'
end

local function spin(microseconds)
	local started = mr.ticks()
	while mr.elapsed_us(started) < microseconds do
	end
end

local function run_window(owner_name, prefix, count)
	local pad, why = pad_at()
	if not pad then return nil, why end
	local handle = owner(owner_name)
	local steps = {}
	for i = 1, count do
		steps[i] = { 'patch', prefix .. i, mr.add(pad, (i - 1) * STEP_BYTES), string.rep('\204', STEP_BYTES), string.rep('\144', STEP_BYTES) }
	end
	local started = mr.ticks()
	local ok, result = handle:batch(steps)
	local call_us = mr.elapsed_us(started)
	if not ok then return nil, result end
	for _, step in ipairs(steps) do
		handle:remove(step[2])
	end
	return result, call_us, mr.read(pad, 0, PAD_SIZE) == string.rep('\204', PAD_SIZE)
end

local function reason_key(why)
	local text = string.gsub(tostring(why), 'inside .*$', 'inside')
	return (string.gsub(text, 'q5_l%d*', 'q5_l'))
end

local function counts_text(counts)
	local parts = {}
	for key, count in pairs(counts) do
		parts[#parts + 1] = ('%s x%d'):format(key, count)
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ', ') or 'none'
end

function q5.where()
	local parts = { 'plus ' .. tostring(mr.plus_version) }
	for _, name in ipairs({ 'link', 'cave', 'raw' }) do
		local at, why = find_once(name)
		parts[#parts + 1] = ('%s=%s (%d matches)'):format(name, at and ('+0x' .. offset_text(at)) or tostring(why), state.counts[name] or 0)
	end
	local pad, why = pad_at()
	parts[#parts + 1] = 'pad=' .. (pad and ('+0x' .. offset_text(pad)) or tostring(why))
	local line = line_of(raw_cave)
	parts[#parts + 1] = 'raw_cave_line=' .. (line and tostring(line + 1) or '?')
	parts[#parts + 1] = 'ui_root=' .. tostring(ui_root() ~= nil)
	parts[#parts + 1] = 'threads=' .. threads_text()
	return table.concat(parts, ' | ')
end

function q5.links_install()
	local target, why = find_once('link')
	if not target then return 'FAIL ' .. why end
	local a, b = owner('q5_a'), owner('q5_b')
	local failures = {}
	local function add(handle, kind, name, fn, priority)
		local ok, problem = handle[kind](handle, target, SIGNATURE, name, fn, priority)
		if not ok then failures[#failures + 1] = name .. ': ' .. tostring(problem) end
	end
	add(b, 'postfix', 'q5_b_post', b_postfix, 0)
	add(a, 'prefix', 'q5_a_pre', a_prefix, 0)
	add(b, 'prefix', 'q5_b_pre', b_prefix, 10)
	add(a, 'postfix', 'q5_a_post', a_postfix, 5)
	return #failures == 0 and 'links installed on +0x' .. offset_text(target) or 'FAIL ' .. table.concat(failures, '; ')
end

function q5.skip(flag)
	state.skip = flag and true or false
	return 'skip ' .. tostring(state.skip)
end

function q5.drive(count)
	local root = ui_root()
	if not root then return 'no ui root' end
	state.ran = {}
	state.order = {}
	state.driving = true
	local failed = nil
	local value = nil
	for _ = 1, count do
		state.order = {}
		local ok, result = pcall(root.NumStates, root)
		if ok then
			value = result
		else
			failed = result
		end
	end
	state.driving = false
	return ('drove %d, skip %s, last result %s, error %s | order %s'):format(
		count,
		tostring(state.skip),
		tostring(value),
		tostring(failed),
		table.concat(state.order, ' ')
	)
end

function q5.links_read()
	local target, why = find_once('link')
	if not target then return why end
	local info = mr.patch_info(target)
	if not info then return 'no patch_info for the target' end
	local rows = {}
	for _, link in ipairs(info.links) do
		local row = ('%s/%s %s p%d c%d s%d e%d'):format(link.owner, link.name, link.link, link.priority, link.calls or 0, link.skips or 0, link.errors or 0)
		rows[#rows + 1] = link.error and (row .. ' error ' .. link.error) or row
	end
	local ran = {}
	for _, tag in ipairs(TAGS) do
		if state.ran[tag] then ran[#ran + 1] = tag .. '=' .. state.ran[tag] end
	end
	local hook = mr.hook_info(target)
	return ('kind %s, other_thread_calls %s, hook calls %s | links in run order: %s | ran: %s | skip %s'):format(
		tostring(info.kind),
		tostring(info.other_thread_calls),
		tostring(hook and hook.calls),
		table.concat(rows, '; '),
		table.concat(ran, ' '),
		tostring(state.skip)
	)
end

local function binding_results(root)
	local images = select(2, pcall(root.NumCurrentStateImages, root))
	local animations = select(2, pcall(root.NumAnimations, root))
	return tostring(images) .. '/' .. tostring(animations)
end

function q5.caves_install()
	local owned, why = find_once('cave')
	local raw, raw_why = find_once('raw')
	if not owned or not raw then return 'FAIL ' .. tostring(why or raw_why) end
	local root = ui_root()
	if root and not state.baseline then state.baseline = binding_results(root) end
	local parts = {}
	local start, problem = owner('q5_a'):cave('q5_cave', owned, CAVE_BYTES)
	parts[#parts + 1] = start and ('q5_cave at ' .. mr.tostring(start)) or ('FAIL q5_cave: ' .. tostring(problem))
	if mr.hook_info(raw) then
		parts[#parts + 1] = 'raw cave stays from an earlier mode'
	else
		local ok, result = pcall(raw_cave, raw, CAVE_BYTES)
		parts[#parts + 1] = ok and ('raw cave at ' .. mr.tostring(result)) or ('FAIL raw cave: ' .. tostring(result))
	end
	parts[#parts + 1] = 'baseline images/animations ' .. tostring(state.baseline)
	return table.concat(parts, ' | ')
end

function q5.caves_drive(count)
	local root = ui_root()
	if not root then return 'no ui root' end
	local now = nil
	for _ = 1, count do
		now = binding_results(root)
	end
	return ('drove %d, now %s, baseline %s, same %s'):format(count, tostring(now), tostring(state.baseline), tostring(now == state.baseline))
end

function q5.list()
	local rows = mr.patch_list()
	local lines = {}
	for _, row in ipairs(rows) do
		lines[#lines + 1] = ('%s/%s %s %s +0x%s'):format(row.owner, row.name, row.kind, row.state, offset_text(row.at))
	end
	return ('%d rows: %s'):format(#rows, table.concat(lines, '; '))
end

function q5.report()
	local name, why = mr.write_runtime_report()
	return name or ('no report: ' .. tostring(why))
end

function q5.window(count)
	local steps = count or STEP_COUNT
	local window, call_us, restored = run_window('q5_w', 'q5_w', steps)
	if not window then return 'REFUSED: ' .. tostring(call_us) end
	return ('window_us=%d call_us=%d steps=%d threads=%s restored=%s'):format(window, call_us, steps, threads_text(), tostring(restored))
end

function q5.load_batches(count)
	local stats = { ok = 0, retried = 0, failed = 0, refusals = {}, sum = 0, max = 0, restored = true }
	for _ = 1, count do
		local tries = 0
		local done = false
		while not done and tries < LOAD_TRIES do
			tries = tries + 1
			local window, why, restored = run_window('q5_l', 'q5_l', STEP_COUNT)
			if window then
				done = true
				stats.ok = stats.ok + 1
				stats.retried = stats.retried + (tries > 1 and 1 or 0)
				stats.sum = stats.sum + window
				stats.max = math.max(stats.max, window)
				stats.restored = stats.restored and restored
			else
				local key = reason_key(why)
				stats.refusals[key] = (stats.refusals[key] or 0) + 1
				spin(RETRY_US)
			end
		end
		stats.failed = stats.failed + (done and 0 or 1)
	end
	local text = ('batches %d, ok %d (after a retry %d), never ok %d, refusals: %s, window_us avg %d max %d, restored %s, threads %s'):format(
		count,
		stats.ok,
		stats.retried,
		stats.failed,
		counts_text(stats.refusals),
		stats.ok > 0 and stats.sum / stats.ok or 0,
		stats.max,
		tostring(stats.restored),
		threads_text()
	)
	shared.load = text
	return text
end

function q5.load_result()
	return shared.load or 'nothing recorded'
end

function q5.wrap_grow_frame()
	if shared.grow then return 'already wrapped' end
	local original = mr.grow_frame
	if not original then return 'no grow_frame' end
	local stats = { calls = 0, refused = 0, total_us = 0, max_us = 0, reasons = {} }
	shared.grow = stats
	mr.grow_frame = function(at, by)
		local started = mr.ticks()
		local ok, why = original(at, by)
		local microseconds = mr.elapsed_us(started)
		stats.calls = stats.calls + 1
		stats.total_us = stats.total_us + microseconds
		stats.max_us = math.max(stats.max_us, microseconds)
		if not ok then
			stats.refused = stats.refused + 1
			stats.reasons[tostring(why)] = (stats.reasons[tostring(why)] or 0) + 1
		end
		return ok, why
	end
	return 'grow_frame wrapped'
end

function q5.grow_read()
	local stats = shared.grow
	if not stats then return 'grow_frame is not wrapped' end
	return ('grow_frame calls %d, refused %d (%s), call time us: total %d max %d'):format(
		stats.calls,
		stats.refused,
		counts_text(stats.reasons),
		stats.total_us,
		stats.max_us
	)
end

_G.q5_patcher = q5

if ... == 'module' then return q5 end
return 'loaded'
