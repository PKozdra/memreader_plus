local mod_log = ...

if _G.memreader_plus then return _G.memreader_plus end

local entry_info = debug.getinfo(2, 'f')
local entry_env = entry_info and entry_info.func and getfenv(entry_info.func) or nil

local function log(message)
	if type(mod_log) == 'function' then mod_log('[memreader_plus] ' .. message) end
end

local function load_agree()
	local chunk = assert(loadfile('/script/memreader_plus/agree'))
	local agree, internals = chunk()
	_G.memreader_plus_agree = agree
	return internals
end

local function load_dll()
	local chunk, load_error = loadfile('/script/memreader_plus/bin')
	if not chunk then return nil, 'bin.lua missing: ' .. tostring(load_error) end
	local bin = chunk()
	local filename = bin.module .. '.dll'

	local file = io.open(filename, 'rb')
	local existing = file and file:read('*a')
	if file then file:close() end
	if existing ~= bin.data then
		local output, open_error = io.open(filename, 'wb')
		if not output then return nil, 'cannot write ' .. filename .. ': ' .. tostring(open_error) end
		output:write(bin.data)
		output:close()
	end

	local ok, result = pcall(require, bin.module)
	if not ok then return nil, 'require ' .. bin.module .. ' failed: ' .. tostring(result) end
	return result
end

local function install_locale_guard()
	local chunk = assert(loadfile('/script/memreader_plus/locale_guard'))
	return chunk().install(entry_env and entry_env.cm or nil)
end

local guard_ok, guard_problem = pcall(install_locale_guard)
if not guard_ok then log('number format guard not installed: ' .. tostring(guard_problem)) end

local agree_ok, agree_internals = pcall(load_agree)
if not agree_ok then log('agreement module not loaded: ' .. tostring(agree_internals)) end
if agree_ok then pcall(agree_internals.listen, entry_env) end

local memreader, load_error = load_dll()
if not memreader then
	_G.memreader_plus_load_error = load_error
	log('not loaded: ' .. load_error)
	if agree_ok then pcall(agree_internals.warn_blocked, entry_env) end
	return nil
end

if type(mod_log) == 'function' then memreader.set_log(mod_log) end

local function field(spec, key)
	return type(spec) == 'table' and tostring(spec[key]) or '?'
end

local function log_file_edit_notes(plus)
	local said = {}
	local function say(line)
		if said[line] then return end
		said[line] = true
		log(line)
	end
	local function report_skipped(spec)
		if type(spec) ~= 'table' or type(spec.path) ~= 'string' then return end
		local own = field(spec, 'owner') .. '/' .. field(spec, 'id')
		for _, file in ipairs(plus.file_edit_list(spec.path)) do
			for _, line in ipairs(file.patches) do
				local name, why = string.match(line, '^(.-) skipped: (.*)$')
				if name and name ~= own then say(('file edit %s on %s: %s'):format(name, spec.path, why)) end
			end
		end
	end
	local function report(spec, note)
		for name, problem in pairs(plus.file_edit_status().sites) do
			if problem ~= true then say(('file edits: %s %s'):format(name, problem)) end
		end
		if note and string.sub(note, 1, 4) == 'off:' then
			say('file edits ' .. note)
		elseif note then
			say(('file edit %s/%s on %s: %s'):format(field(spec, 'owner'), field(spec, 'id'), field(spec, 'path'), note))
		end
		report_skipped(spec)
	end
	local function logged(register)
		return function(spec)
			local ok, note = register(spec)
			report(spec, note)
			return ok, note
		end
	end
	plus.file_edit = logged(plus.file_edit)
	if plus.twui then plus.twui.edit = logged(plus.twui.edit) end
end

local function load_twui(plus)
	local chunk = assert(loadfile('/script/memreader_plus/twui'))
	plus.twui = chunk(plus)
end

local function load_sites(plus, agree)
	local chunk = assert(loadfile('/script/memreader_plus/sites'))
	chunk(plus, agree).attach()
end

local function register_spec(plus, owner, spec)
	if type(spec) ~= 'table' then error('the entry is not a table', 0) end
	spec.owner = owner
	if spec.changes == nil then
		plus.file_edit(spec)
	elseif plus.twui then
		plus.twui.edit(spec)
	else
		error('the TWUI module is not loaded', 0)
	end
end

local function load_spec_file(plus, folder, entry)
	local owner = string.match(entry, '([^/\\]+)%.lua$')
	if not owner then error('the name does not end in .lua', 0) end
	local chunk = assert(loadfile(folder .. owner))
	setfenv(chunk, {})
	local specs = chunk()
	if type(specs) ~= 'table' then error('it returns no table', 0) end
	for index, spec in ipairs(specs) do
		local ok, problem = pcall(register_spec, plus, owner, spec)
		if not ok then log(('file edit %d of %s not registered: %s'):format(index, entry, tostring(problem))) end
	end
end

local function load_file_edit_specs(plus, folder)
	local lookup = common and common.filesystem_lookup
	local found = lookup and lookup(folder, '*.lua') or ''
	for entry in string.gmatch(found, '[^,]+') do
		local ok, problem = pcall(load_spec_file, plus, folder, entry)
		if not ok then log(('file edits of %s not loaded: %s'):format(entry, tostring(problem))) end
	end
end

local twui_ok, twui_problem = pcall(load_twui, memreader)
if not twui_ok then log('TWUI module not loaded: ' .. tostring(twui_problem)) end
local sites_ok, sites_problem = pcall(load_sites, memreader, agree_ok and agree_internals or nil)
if not sites_ok then log('sites module not loaded: ' .. tostring(sites_problem)) end
log_file_edit_notes(memreader)
local edits_ok, edits_problem = pcall(function()
	load_file_edit_specs(memreader, '/script/memreader_plus/file_edits/')
end)
if not edits_ok then log('file edits from script/memreader_plus/file_edits not loaded: ' .. tostring(edits_problem)) end

local replaced = _G.memreader ~= nil
package.loaded['twwh3-memreader'] = memreader
package.loaded['twwh2-memreader'] = memreader
_G.memreader = memreader
_G.memreader_plus = memreader
memreader.agree = _G.memreader_plus_agree

if replaced then
	log('loaded ' .. memreader.plus_version .. ', replaced another memreader in _G.memreader')
else
	log('loaded ' .. memreader.plus_version)
end
return memreader
