local plus, agree = ...

local sites = {}

local MAX_EXACT = 16777215
local MAX_PATTERNS = 64
local MAX_PATTERN_BYTES = 256
local CALL_SIZE = 5
local READ_SIZES = { uint8 = 1, int32 = 4, call = 8, rip = 8 }
local ARG_LIMITS = { [1] = { -128, 255 }, [4] = { -MAX_EXACT, MAX_EXACT }, [8] = { 0, MAX_EXACT } }
local HOOK_KINDS = { hook = 'function', prefix = 'function', postfix = 'function', around = 'function', site = 'site' }
local LINK_METHODS = { hook = 'around', prefix = 'prefix', postfix = 'postfix', around = 'around' }
local WHEN_KINDS = { prefix = true, postfix = true, around = true }
local STAYS = { cave = true, frame = true, relocate = true }
local UNGATED = { anchor = true, frame = true, relocate = true }
local MUST_BE_INSTALLED = { frame = true, relocate = true }
local KINDS = { anchor = true, patch = true, value = true, cave = true, frame = true, relocate = true, site = true }
local NOTHING = {}
local IN_CALL = 'not from inside a hooked call'

for kind in pairs(LINK_METHODS) do
	KINDS[kind] = true
end

local function parse_hex(text)
	local list = {}
	for token in text:gmatch('[^ ]+') do
		if token == '??' then
			list[#list + 1] = false
		elseif token:match('^%x%x$') then
			list[#list + 1] = tonumber(token, 16)
		else
			return nil
		end
	end
	return list
end

local function parse_template(text)
	local items = {}
	for token in text:gmatch('[^ ]+') do
		local name, size = token:match('^{([%w_]+):(%d)}$')
		if name then
			items[#items + 1] = { name = name, size = tonumber(size) }
		elseif token:match('^%x%x$') then
			items[#items + 1] = tonumber(token, 16)
		else
			return nil
		end
	end
	return items
end

local function to_bytes(list)
	local out = {}
	for i, byte in ipairs(list) do
		out[i] = string.char(byte)
	end
	return table.concat(out)
end

local function fits(raw, template)
	if #raw ~= #template then return false end
	for i, wanted in ipairs(template) do
		if wanted and raw:byte(i) ~= wanted then return false end
	end
	return true
end

local function le_bytes(value, size)
	local negative = value < 0
	local rest = negative and -value - 1 or value
	local out = {}
	for i = 1, size do
		local byte = rest % 256
		out[i] = string.char(negative and 255 - byte or byte)
		rest = math.floor(rest / 256)
	end
	return table.concat(out)
end

local function le_number(raw, signed)
	local negative = signed and raw:byte(#raw) >= 128
	local value = 0
	for i = #raw, 1, -1 do
		local byte = raw:byte(i)
		value = value * 256 + (negative and 255 - byte or byte)
	end
	if negative then return -value - 1 end
	return value
end

local function address_bytes(address)
	local out = {}
	for pair in plus.tostring(address):gmatch('%x%x') do
		table.insert(out, 1, string.char(tonumber(pair, 16)))
	end
	return table.concat(out)
end

local function relative_target(from, after, raw, first)
	local low = raw:byte(first) + raw:byte(first + 1) * 256
	local high = raw:byte(first + 2) + raw:byte(first + 3) * 256
	if high >= 32768 then high = high - 65536 end
	return plus.add(plus.add(from, after + low), high * 65536)
end

local function jump_target(from, at, text)
	local template = parse_hex(text)
	local raw = plus.read_original(from, at, #template)
	if not fits(raw, template) or (raw:byte(1) ~= 0xE8 and raw:byte(1) ~= 0xE9) then return nil end
	return relative_target(plus.add(from, at), CALL_SIZE, raw, 2)
end

local function whole(value, low, high)
	return type(value) == 'number' and value == math.floor(value) and value >= low and value <= high
end

local function make_candidates(entry)
	if not entry.variants then return { entry } end
	local list = {}
	for index, variant in ipairs(entry.variants) do
		local spec = {}
		for key, value in pairs(entry) do
			spec[key] = value
		end
		for key, value in pairs(variant) do
			spec[key] = value
		end
		spec.variants = nil
		list[index] = spec
	end
	return list
end

local function shape_problem(entry, by_name)
	if type(entry) ~= 'table' then return 'not a table' end
	if type(entry.name) ~= 'string' or entry.name == '' then return 'no name' end
	if by_name[entry.name] then return 'name used twice' end
	if type(entry.feature) ~= 'string' or entry.feature == '' then return 'no feature' end
	if not KINDS[entry.kind] then return 'unknown kind' end
	local function bad_when(spec)
		return type(spec) == 'table' and spec.when ~= nil and (not WHEN_KINDS[entry.kind] or type(spec.when) ~= 'table')
	end
	if bad_when(entry) then return 'bad when' end
	if (entry.pattern == nil) == (entry.variants == nil) then return 'needs a pattern or variants, not both' end
	local list = entry.variants or { entry }
	if type(list) ~= 'table' or #list == 0 then return 'variants is empty' end
	for _, spec in ipairs(list) do
		if bad_when(spec) then return 'bad when' end
		local pattern = type(spec) == 'table' and (spec.pattern or entry.pattern) or nil
		local bytes = type(pattern) == 'string' and parse_hex(pattern) or nil
		if not bytes or #bytes == 0 or #bytes > MAX_PATTERN_BYTES or bytes[1] == false then return 'bad pattern' end
	end
	return nil
end

local function nothing()
	return true
end

local function mark_missing(rec, why)
	rec.found = false
	rec.why = why
	return false, why
end

local function read_one(match, name, read)
	local value = { type = read.type }
	if read.type == 'uint8' or read.type == 'int32' then
		value.raw = plus.read_original(match, read.at, READ_SIZES[read.type])
		value.number = le_number(value.raw, read.type == 'int32')
		local out_of_range = (read.equals and value.number ~= read.equals) or (read.low and value.number < read.low) or (read.high and value.number > read.high)
		if out_of_range then return nil, ('read %s out of range'):format(name) end
	elseif read.type == 'call' then
		local raw = plus.read_original(match, read.at, CALL_SIZE)
		if raw:byte(1) ~= 0xE8 then return nil, ('read %s is not a call'):format(name) end
		value.pointer = relative_target(plus.add(match, read.at), CALL_SIZE, raw, 2)
		value.raw = address_bytes(value.pointer)
	elseif read.type == 'chain' then
		local address = plus.add(match, read.at)
		for index, hop in ipairs(read.hops) do
			address = jump_target(address, hop.at, hop.expect)
			if not address then return nil, ('read %s: hop %d does not hold'):format(name, index) end
		end
		value.pointer = address
		value.raw = address_bytes(address)
	else
		local raw = plus.read_original(match, read.at, 4)
		value.pointer = relative_target(match, read.after, raw, 1)
		value.raw = address_bytes(value.pointer)
	end
	return value
end

local function arg_bytes(value, size)
	local kind = type(value)
	if kind == 'number' and whole(value, ARG_LIMITS[size][1], ARG_LIMITS[size][2]) then return le_bytes(value, size) end
	if kind == 'string' and #value == size then return value end
	if kind == 'userdata' and size == 8 and plus.type(value) == 'pointer' then return address_bytes(value) end
	return nil
end

local function expand(rec, args)
	local list = {}
	local missing = nil
	for _, item in ipairs(rec.items) do
		if type(item) == 'number' then
			list[#list + 1] = item
		else
			local read = rec.reads[item.name]
			local given = type(args) == 'table' and args[item.name] or nil
			local raw = read and read.raw or (given ~= nil and arg_bytes(given, item.size) or nil)
			if raw and #raw ~= item.size then raw = nil end
			if not raw then missing = missing or item.name end
			for i = 1, item.size do
				list[#list + 1] = raw and raw:byte(i) or false
			end
		end
	end
	return list, missing
end

local function cave_is_ours(self, rec)
	local info = plus.hook_info(rec.address)
	if not info or info.kind ~= 'cave' then return false end
	local owned = self.handle:info(rec.name)
	if not owned or owned.kind ~= 'cave' then return false end
	local list = expand(rec, nil)
	return fits(plus.read(info.cave, 0, #list), list)
end

local function held_reason(self, rec)
	if rec.kind ~= 'cave' and not HOOK_KINDS[rec.kind] then return nil end
	local info = plus.hook_info(rec.address)
	if not info then return nil end
	if rec.kind == 'cave' and cave_is_ours(self, rec) then return nil end
	if rec.kind ~= 'cave' and info.kind == HOOK_KINDS[rec.kind] then return nil end
	return 'held by another hook'
end

local resolve = nil

local function read_all(self, spec, match)
	local values = {}
	for name, read in pairs(spec.reads or {}) do
		if read.from then
			local other = self.by_name[read.from]
			if not other then return nil, ('needs unknown %s'):format(tostring(read.from)) end
			resolve(self, other)
			if not other.found then return nil, ('needs %s (%s)'):format(other.name, other.why) end
			values[name] = other.reads[name]
		else
			local value, why = read_one(match, name, read)
			if not value then return nil, why end
			values[name] = value
		end
	end
	return values
end

local function expect_holds(site, text)
	local template = parse_hex(text)
	return fits(plus.read_original(site, 0, #template), template)
end

local function bytes_hold(spec, match, site)
	for _, part in ipairs(spec.sites or {}) do
		if not expect_holds(plus.add(match, part.at), part.expect) then return false end
	end
	return spec.sites ~= nil or spec.expect == nil or expect_holds(plus.add(site, 0 - (spec.before or 0)), spec.expect)
end

local function target_of(spec, site, reads)
	local target = spec.target
	if target == 'call' then return jump_target(site, 0, spec.expect) end
	if target == 'start' then return (plus.function_start(site)) end
	return reads[target] and reads[target].pointer
end

local function check_candidate(self, spec)
	local count = self.counts[spec.pattern] or 0
	if count ~= 1 then return nil, ('pattern found %d times'):format(count) end
	local match = self.addresses[spec.pattern]
	local reads, why = read_all(self, spec, match)
	if not reads then return nil, why end
	local site = plus.add(match, spec.at or 0)
	if not bytes_hold(spec, match, site) then return nil, 'unexpected bytes' end
	local address = site
	if spec.target and spec.target ~= 'site' then
		local why = nil
		address, why = target_of(spec, site, reads)
		if not address then return nil, why or 'target not found' end
		if not expect_holds(address, spec.expect_target) then return nil, 'unexpected bytes at the target' end
	end
	return { spec = spec, match = match, site = site, address = address, reads = reads }
end

local function choose_reason(reasons)
	for _, why in ipairs(reasons) do
		if why ~= 'pattern found 0 times' then return why end
	end
	return reasons[1]
end

local function owned_target(rec, spec)
	if spec.target and spec.target ~= 'site' then return rec.address end
	local target = { pattern = spec.pattern, at = spec.at or 0 }
	if rec.kind ~= 'value' then target.expect = spec.expect end
	return target
end

local function adopt(rec, found)
	rec.found = true
	rec.why = nil
	rec.spec = found.spec
	rec.match = found.match
	rec.site = found.site
	rec.address = found.address
	rec.reads = found.reads
	rec.before = found.spec.before or 0
	rec.expect = found.spec.expect and parse_hex(found.spec.expect) or nil
	rec.expect_target = found.spec.expect_target and parse_hex(found.spec.expect_target) or nil
	rec.target = owned_target(rec, found.spec)
	if rec.kind == 'cave' then rec.items = parse_template(found.spec.bytes) end
	if rec.kind == 'patch' then rec.bytes = to_bytes(parse_hex(found.spec.bytes)) end
end

local function resolve_now(self, rec)
	local reasons = {}
	for _, spec in ipairs(make_candidates(rec.entry)) do
		local found, why = check_candidate(self, spec)
		if found then
			adopt(rec, found)
			local held = held_reason(self, rec)
			if held then mark_missing(rec, held) end
			return
		end
		reasons[#reasons + 1] = why
	end
	mark_missing(rec, choose_reason(reasons))
end

function resolve(self, rec)
	if rec.resolved then return end
	rec.resolved = true
	local ok, problem = pcall(resolve_now, self, rec)
	if not ok then mark_missing(rec, tostring(problem)) end
end

local function search(self)
	local patterns = {}
	local seen = {}
	for _, rec in ipairs(self.records) do
		for _, spec in ipairs(rec.resolved and {} or make_candidates(rec.entry)) do
			if not seen[spec.pattern] then
				seen[spec.pattern] = true
				patterns[#patterns + 1] = spec.pattern
			end
		end
	end
	for first = 1, #patterns, MAX_PATTERNS do
		local chunk = {}
		for i = first, math.min(first + MAX_PATTERNS - 1, #patterns) do
			chunk[#chunk + 1] = patterns[i]
		end
		local found, counts = plus.find_patterns(chunk)
		for i, pattern in ipairs(chunk) do
			self.addresses[pattern] = found[i] or nil
			self.counts[pattern] = counts[i] or 0
		end
	end
end

local function text_of(entry, key, fallback)
	local value = type(entry) == 'table' and entry[key] or nil
	return type(value) == 'string' and value or fallback
end

local function make_state(handle, owner, entries, log)
	local self = {
		handle = handle,
		owner = owner,
		log = log or nothing,
		records = {},
		by_name = {},
		addresses = {},
		counts = {},
		told = {},
		unknown = {},
	}
	for index, entry in ipairs(entries) do
		local problem = shape_problem(entry, self.by_name)
		local rec = {
			name = text_of(entry, 'name', 'entry ' .. index),
			feature = text_of(entry, 'feature', ''),
			kind = text_of(entry, 'kind', ''),
			entry = entry,
			found = false,
			resolved = problem ~= nil,
			why = problem and ('bad entry: ' .. problem) or nil,
		}
		self.records[#self.records + 1] = rec
		if not problem then self.by_name[rec.name] = rec end
	end
	return self
end

local function write_line(self, text)
	self.log(('[%s] %s'):format(self.owner, text))
end

local function lookup(self, name)
	local rec = self.by_name[name]
	if rec then return rec end
	if not self.unknown[tostring(name)] then
		self.unknown[tostring(name)] = true
		write_line(self, 'unknown site ' .. tostring(name))
	end
	return { name = tostring(name), found = false, why = 'unknown site', kind = 'anchor', feature = '' }
end

local PLANNERS = {}

function PLANNERS.patch(_, rec)
	local original = plus.read_original(rec.site, 0, #rec.expect)
	if not fits(original, rec.expect) then return nil, 'unexpected bytes' end
	return { step = { 'patch', rec.name, rec.target, original, rec.bytes } }
end

local function cave_problem(self, rec)
	local held = held_reason(self, rec)
	if held then return held end
	if not fits(plus.read(rec.site, 0, #rec.expect), rec.expect) then return 'unexpected bytes' end
	return nil
end

function PLANNERS.cave(self, rec, args)
	local held = held_reason(self, rec)
	if held then return nil, held end
	if cave_is_ours(self, rec) then return NOTHING end
	local list, missing = expand(rec, args)
	if missing then return nil, 'missing argument ' .. missing end
	local problem = cave_problem(self, rec)
	if problem then return nil, problem end
	return { step = { 'cave', rec.name, rec.target, to_bytes(list) } }
end

function PLANNERS.frame(_, rec)
	if rec.installed then return NOTHING end
	return { step = { 'frame', rec.name, rec.target, rec.spec.grow } }
end

function PLANNERS.relocate(_, rec)
	if rec.installed then return NOTHING end
	local list = {}
	for _, part in ipairs(rec.spec.sites) do
		local wanted = to_bytes(parse_hex(part.bytes))
		local original = plus.read_original(plus.add(rec.match, part.at), 0, #wanted)
		if not fits(original, parse_hex(part.expect)) then return nil, 'unexpected bytes' end
		list[#list + 1] = { { pattern = rec.spec.pattern, at = part.at, expect = part.expect }, original, wanted }
	end
	return { step = { 'relocate', rec.name, list } }
end

local function inert_until_agreed(self, rec, body)
	if not agree or not agree.shared(self.owner, rec.feature) then return body end
	local owner, feature, active = self.owner, rec.feature, agree.active
	rec.inert = true
	if rec.kind == 'around' or rec.kind == 'hook' then
		return function(game, ...)
			if active(owner, feature) then return body(game, ...) end
			return game()
		end
	end
	return function(first, ...)
		if active(owner, feature) then return body(first, ...) end
	end
end

local function link_when(rec, set)
	if not rec.spec.when then return nil end
	local when = {}
	for key, value in pairs(rec.spec.when) do
		when[key] = value
	end
	when.set = set
	return when
end

local function attach_link(self, rec, fn, set)
	local handle = self.handle
	local body = inert_until_agreed(self, rec, fn)
	if rec.kind == 'site' then return handle:site(rec.name, rec.target, body, rec.spec.priority) end
	return handle[LINK_METHODS[rec.kind]](handle, rec.target, rec.spec.signature, rec.name, body, rec.spec.priority, link_when(rec, set))
end

local function given_parts(given)
	if type(given) == 'table' then return given.fn, given.set end
	return given, nil
end

local function attach_problem(self, rec)
	local held = held_reason(self, rec)
	if held then return held end
	local expect = rec.expect
	if expect and not fits(plus.read_original(rec.site, 0, #expect), expect) then return 'unexpected bytes' end
	local target = rec.expect_target
	if target and not fits(plus.read_original(rec.address, 0, #target), target) then return 'unexpected bytes at the target' end
	return nil
end

local function plan_attach(self, rec, given)
	if rec.installed then return NOTHING end
	local body, set = given_parts(given)
	if type(body) ~= 'function' then return nil, 'no callback' end
	if rec.spec.when and set == nil then return nil, 'no set for when' end
	if set ~= nil and not rec.spec.when then return nil, 'set given but the entry has no when' end
	local problem = attach_problem(self, rec)
	if problem then return nil, problem end
	return {
		attach = function()
			return attach_link(self, rec, body, set)
		end,
	}
end

for kind in pairs(HOOK_KINDS) do
	PLANNERS[kind] = plan_attach
end

local function plan(self, rec, given)
	if not rec.found then return nil, rec.why end
	local planner = PLANNERS[rec.kind]
	if not planner then return NOTHING end
	local ok, step, why = pcall(planner, self, rec, given)
	if not ok then return nil, tostring(step) end
	return step, why
end

local function run_steps(self, steps)
	local handle = self.handle
	if #steps == 1 and steps[1][1] ~= 'relocate' then
		local step = steps[1]
		local done, why = handle[step[1]](handle, unpack(step, 2))
		return done, why
	end
	return handle:batch(steps)
end

local function note_left(self, why, left)
	for _, name in ipairs(left) do
		self.by_name[name].installed = true
	end
	if #left > 0 then write_line(self, ('install failed (%s), left in place: %s'):format(why, table.concat(left, ', '))) end
end

local function is_busy(reason)
	return reason:match('^a thread is inside') ~= nil or reason == 'a thread could not be checked' or reason == 'the other threads could not be suspended'
end

local function mark_steps(plans, why)
	for _, entry in ipairs(plans) do
		if entry.plan.step then mark_missing(entry.rec, why) end
	end
end

local function fail_bytes(self, plans, why, left)
	local full = tostring(why)
	left = type(left) == 'table' and left or {}
	local name, reason = full:match('^([%w_]+): (.*)$')
	local rec = name and self.by_name[name]
	if not rec then reason = full end
	if is_busy(reason) and #left == 0 then return end
	if rec and not reason:match('could not be put back') then
		mark_missing(rec, reason)
	else
		mark_steps(plans, reason)
	end
	note_left(self, full, left)
end

local function write_bytes(self, plans)
	local steps = {}
	for _, entry in ipairs(plans) do
		if entry.plan.step then steps[#steps + 1] = entry.plan.step end
	end
	if #steps == 0 then return true end
	local ok, done, why, left = pcall(run_steps, self, steps)
	if not ok then
		done, why = nil, tostring(done)
	end
	if done then return true end
	if why ~= IN_CALL then fail_bytes(self, plans, why, left) end
	return false, why
end

local function undo(self, plans, attached)
	local left = {}
	for index = #attached, 1, -1 do
		pcall(self.handle.remove, self.handle, attached[index].name)
		attached[index].installed = false
	end
	for _, entry in ipairs(plans) do
		local step = entry.plan.step
		if step and entry.fresh and entry.rec.kind == 'patch' then
			pcall(self.handle.remove, self.handle, entry.rec.name)
		elseif step and entry.fresh and STAYS[entry.rec.kind] then
			left[#left + 1] = entry.rec.name
		end
	end
	return left
end

local function attach_links(self, plans)
	local attached = {}
	for _, entry in ipairs(plans) do
		if entry.plan.attach then
			local ok, done, why = pcall(entry.plan.attach)
			if not ok then
				done, why = nil, tostring(done)
			end
			if not done then
				note_left(self, tostring(why), undo(self, plans, attached))
				return mark_missing(entry.rec, why)
			end
			entry.rec.installed = true
			attached[#attached + 1] = entry.rec
		end
	end
	return true
end

local function install_set(self, items)
	if plus.hook_depth() > 0 then return false, IN_CALL end
	local plans = {}
	for _, item in ipairs(items) do
		local one, why = plan(self, item.rec, item.given)
		if not one then return mark_missing(item.rec, why) end
		plans[#plans + 1] = { rec = item.rec, plan = one, fresh = not item.rec.installed }
	end
	local done, why = write_bytes(self, plans)
	if done then
		done, why = attach_links(self, plans)
	end
	if not done then return false, why end
	for _, entry in ipairs(plans) do
		if PLANNERS[entry.rec.kind] then entry.rec.installed = true end
	end
	return #plans > 0
end

local function safely(self, rec, action, ...)
	local ok, done, why = pcall(action, self, rec, ...)
	if ok then return done, why end
	mark_missing(rec, tostring(done))
	return false, rec.why
end

local function set_value(self, rec, number)
	if not rec.found then return false, rec.why end
	if rec.kind ~= 'value' then return false, 'not a value' end
	local spec = rec.spec
	if not whole(number, spec.low, spec.high) then return false, 'number outside low and high' end
	local guard = plus.read(plus.add(rec.site, 0 - rec.before), 0, #rec.expect)
	if not fits(guard, rec.expect) then return mark_missing(rec, 'unexpected bytes') end
	local done, why = self.handle:set(rec.name, rec.target, spec.size, number, spec.low, spec.high)
	if not done then return mark_missing(rec, why) end
	rec.installed = true
	return true
end

local function remove(self, rec)
	if not rec.found then return false end
	if STAYS[rec.kind] then return false, 'stays for the session' end
	local done, why = self.handle:remove(rec.name)
	if not done and why ~= 'unknown name' then return false, why end
	rec.installed = false
	return true
end

local function cave_value(self, rec, placeholder)
	if not rec.found or rec.kind ~= 'cave' or not cave_is_ours(self, rec) then return nil end
	local cave = plus.hook_info(rec.address).cave
	local offset = 0
	for _, item in ipairs(rec.items) do
		if type(item) == 'number' then
			offset = offset + 1
		elseif item.name == placeholder then
			local raw = plus.read(cave, offset, item.size)
			if item.size == 8 then return plus.pointer(raw) end
			return le_number(raw, false)
		else
			offset = offset + item.size
		end
	end
	return nil
end

local function value_problem(rec)
	local guard = plus.read(plus.add(rec.site, 0 - rec.before), 0, #rec.expect)
	if not fits(guard, rec.expect) then return 'unexpected bytes' end
	local current = le_number(plus.read(rec.site, 0, rec.spec.size), rec.spec.size == 4)
	if current < rec.spec.low or current > rec.spec.high then return 'the current value is outside low and high' end
	return nil
end

local function install_problem(self, rec)
	if rec.kind == 'patch' then
		local step, why = PLANNERS.patch(self, rec)
		if step then return nil end
		return why
	end
	if rec.kind == 'cave' then
		if cave_is_ours(self, rec) then return nil end
		return cave_problem(self, rec)
	end
	if rec.kind == 'value' then return value_problem(rec) end
	if MUST_BE_INSTALLED[rec.kind] then return 'not installed' end
	return attach_problem(self, rec)
end

local function entry_ready(self, rec, requirement)
	if not rec.found then return false, rec.spec and 'r' or 's', rec.why end
	if rec.kind == 'anchor' then return true end
	if rec.installed then
		if requirement == 'links' and HOOK_KINDS[rec.kind] and not rec.inert then return false, 'r', 'attached before the agreement' end
		return true
	end
	if requirement == true or (requirement == 'links' and HOOK_KINDS[rec.kind]) then return false, 'r', 'not installed' end
	local ok, problem = pcall(install_problem, self, rec)
	if ok and not problem then return true end
	return false, 'r', tostring(problem)
end

local function feature_ready(self, feature, requirement)
	for _, rec in ipairs(self.records) do
		if rec.feature == feature then
			local ok, code, why = entry_ready(self, rec, requirement)
			if not ok then return false, code, why end
		end
	end
	return true
end

local function remove_feature(self, feature)
	local failed = nil
	for _, rec in ipairs(self.records) do
		if rec.feature == feature and not STAYS[rec.kind] and rec.found then
			local done, why = safely(self, rec, remove)
			if not done and not failed then failed = why or 'could not be removed' end
		end
	end
	if failed then return false, failed end
	return true
end

local function clear_leftovers(self, feature)
	local count = 0
	for _, rec in ipairs(self.records) do
		local ours = self.by_name[rec.name] == rec and rec.feature == feature and not rec.installed
		if ours and not STAYS[rec.kind] and rec.kind ~= 'anchor' then
			local ok, done = pcall(self.handle.remove, self.handle, rec.name)
			if ok and done == true then count = count + 1 end
		end
	end
	return count
end

local function gated(self, rec)
	if not agree or UNGATED[rec.kind] then return nil end
	local ok, why = pcall(agree.gate, self.owner, rec.feature, rec.kind)
	if ok then return why end
	return 'the multiplayer agreement check failed'
end

local function gated_feature(self, items)
	for _, item in ipairs(items) do
		local why = gated(self, item.rec)
		if why then return why end
	end
	return nil
end

local function log_missing(self)
	for _, rec in ipairs(self.records) do
		if not rec.found and not self.told[rec] then
			self.told[rec] = true
			write_line(self, ('%s not found (%s): %s off'):format(rec.name, tostring(rec.why), rec.feature))
		end
	end
end

local function report(self)
	local parts = {}
	for _, rec in ipairs(self.records) do
		local state = 'missing'
		if rec.found then state = rec.installed and 'ours' or 'vanilla' end
		parts[#parts + 1] = rec.name .. '=' .. state
	end
	return table.concat(parts, ',')
end

local function feature_ok(self, feature)
	local count = 0
	for _, rec in ipairs(self.records) do
		if rec.feature == feature then
			count = count + 1
			if not rec.found then return false end
		end
	end
	return count > 0
end

local function feature_items(self, feature, given)
	local items = {}
	for _, rec in ipairs(self.records) do
		if rec.feature == feature then items[#items + 1] = { rec = rec, given = given and given[rec.name] } end
	end
	return items
end

local function installing(self, items)
	local ok, done, why = pcall(install_set, self, items)
	if not ok then return false, tostring(done) end
	if why == nil then return done end
	return done, why
end

local function build_api(self)
	local api = {}
	function api.found(name)
		return lookup(self, name).found
	end
	function api.why(name)
		return lookup(self, name).why
	end
	function api.feature_ok(feature)
		return feature_ok(self, feature)
	end
	function api.address(name)
		local rec = lookup(self, name)
		return rec.found and rec.address or nil
	end
	function api.value(name, read)
		local rec = lookup(self, name)
		local value = rec.found and rec.reads[read] or nil
		if not value then return nil end
		return value.pointer or value.number
	end
	function api.install(name, given)
		local rec = lookup(self, name)
		local why = gated(self, rec)
		if why then return false, why end
		return installing(self, { { rec = rec, given = given } })
	end
	function api.install_feature(feature, given)
		local items = feature_items(self, feature, given)
		local why = gated_feature(self, items)
		if why then return false, why end
		return installing(self, items)
	end
	function api.set(name, number)
		local rec = lookup(self, name)
		local why = gated(self, rec)
		if why then return false, why end
		local done, reason = safely(self, rec, set_value, number)
		if reason == nil then return done end
		return done, reason
	end
	function api.ready(feature, requirement)
		return feature_ready(self, feature, requirement)
	end
	function api.remove_feature(feature)
		return remove_feature(self, feature)
	end
	function api.clear_leftovers(feature)
		return clear_leftovers(self, feature)
	end
	function api.owner()
		return self.owner
	end
	function api.remove(name)
		local done, why = safely(self, lookup(self, name), remove)
		if why == nil then return done end
		return done, why
	end
	function api.disable(name, why)
		mark_missing(lookup(self, name), 'disabled: ' .. tostring(why))
	end
	function api.cave_value(name, placeholder)
		local ok, value = pcall(cave_value, self, lookup(self, name), placeholder)
		if ok then return value end
		return nil
	end
	function api.log_missing()
		log_missing(self)
	end
	function api.report()
		return report(self)
	end
	return api
end

function sites.load(handle, owner, entries, log)
	local self = make_state(handle, owner, type(entries) == 'table' and entries or {}, log)
	local why = nil
	local ok, problem = pcall(search, self)
	if not ok then why = 'pattern search failed: ' .. tostring(problem) end
	for _, rec in ipairs(self.records) do
		if why and not rec.resolved then
			mark_missing(rec, why)
			rec.resolved = true
		else
			resolve(self, rec)
		end
	end
	return build_api(self)
end

function sites.attach()
	local patcher = plus.patcher
	if not patcher then return end
	local function method(handle, entries, log)
		return sites.load(handle, handle:owner(), entries, log)
	end
	plus.patcher = function(owner)
		local handle, why = patcher(owner)
		if not handle then return nil, why end
		getmetatable(handle).__index.sites = method
		return handle
	end
	plus.supports = plus.supports or {}
	plus.supports.links_without_expect = true
	plus.supports.link_when = true
	plus.supports.rows = true
end

sites.parse_hex = parse_hex
sites.parse_template = parse_template
sites.make_candidates = make_candidates

return sites
