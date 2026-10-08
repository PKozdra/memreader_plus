local LOG_FILE = 'lua_mod_log.txt'
local MAX_LOG_LINES = 60
local LOG_LINE_LIMIT = 300
local VALUE_LIMIT = 80
local MOD_LIMIT = 6000
local TOTAL_LIMIT = 15000
local SKIPPED_TYPES = { ['MCT.Option.Dummy'] = true, ['MCT.Option.Action'] = true }

local said = {}

local function log(text)
	ModLog('[memreader_plus_report] ' .. text)
end

local function log_once(text)
	if said[text] then return end
	said[text] = true
	log(text)
end

local function clean(text, limit)
	text = string.gsub(text, '%c', ' ')
	return string.sub(text, 1, limit)
end

local function format_value(value)
	local kind = type(value)
	if kind == 'boolean' then return tostring(value) end
	if kind == 'number' then return ('%.6g'):format(value) end
	if kind == 'string' then return clean(value, VALUE_LIMIT) end
end

local function sorted_keys(items)
	local keys = {}
	for key in pairs(items) do
		if type(key) == 'string' then keys[#keys + 1] = key end
	end
	table.sort(keys)
	return keys
end

local function option_line(key, option)
	if SKIPPED_TYPES[option:get_type()] then return nil end
	local value = format_value(option:get_finalized_setting())
	if value then return ('  %s = %s'):format(key, value) end
end

local function read_option(mod_key, key, option)
	local ok, line = pcall(option_line, key, option)
	if ok then return line end
	log_once(('cannot read option %s of mod %s: %s'):format(key, mod_key, tostring(line)))
end

local function heading(key, mod)
	local ok, title = pcall(mod.get_title, mod)
	local text = '[' .. key .. ']'
	if ok and type(title) == 'string' and title ~= '' then text = text .. ' ' .. clean(title, VALUE_LIMIT) end
	return text
end

local function mod_block(key, mod)
	local lines = { heading(key, mod) }
	local options = mod:get_options()
	local keys = sorted_keys(options)
	local size = #lines[1]
	for index, option_key in ipairs(keys) do
		if size > MOD_LIMIT then
			lines[#lines + 1] = ('  ... %d more options'):format(#keys - index + 1)
			break
		end
		local line = read_option(key, option_key, options[option_key])
		if line then
			lines[#lines + 1] = line
			size = size + #line + 1
		end
	end
	return lines
end

local function safe_mod_block(key, mod)
	local ok, lines = pcall(mod_block, key, mod)
	if ok then return lines end
	log_once(('cannot read the options of mod %s: %s'):format(key, tostring(lines)))
	return { ('[%s] (its settings could not be read)'):format(key) }
end

local function mct_mods()
	if not get_mct then return nil end
	local ok, mods = pcall(function()
		return get_mct():get_mods()
	end)
	if ok and type(mods) == 'table' then return mods end
	log_once('cannot list the MCT mods: ' .. tostring(mods))
end

local function build_snapshot()
	local mods = mct_mods()
	if not mods then return nil end
	local keys = sorted_keys(mods)
	local lines = {}
	local size = 0
	for index, key in ipairs(keys) do
		local text = table.concat(safe_mod_block(key, mods[key]), '\n')
		if size + #text + 1 > TOTAL_LIMIT then
			lines[#lines + 1] = ('... %d more mods'):format(#keys - index + 1)
			break
		end
		lines[#lines + 1] = text
		size = size + #text + 1
	end
	return table.concat(lines, '\n')
end

local function refresh()
	local plus = _G.memreader_plus
	if not plus or not plus.set_crash_settings then return end
	local ok, text = pcall(build_snapshot)
	if not ok then
		log('cannot build the MCT settings list: ' .. tostring(text))
		return
	end
	pcall(plus.set_crash_settings, text)
end

local function refresh_safely()
	local ok, problem = xpcall(refresh, debug.traceback)
	if not ok then log('cannot refresh the MCT settings list: ' .. tostring(problem)) end
end

local function mask_paths(text)
	text = string.gsub(text, '%a:[\\/][Uu][Ss][Ee][Rr][Ss][\\/][^\\/\r\n]+', '%%USERPROFILE%%')
	return (string.gsub(text, '%a:[\\/][^"<>|*?\r\n]-([\\/][Ss][Tt][Ee][Aa][Mm][Aa][Pp][Pp][Ss][\\/])', '<Steam library>%1'))
end

local function load_bin()
	local chunk, load_error = loadfile('/script/memreader_plus/bin')
	if not chunk then error('bin.lua missing: ' .. tostring(load_error), 0) end
	return chunk()
end

local function loader_lines()
	local plus = _G.memreader_plus
	local old = _G.memreader
	return {
		'  load error: ' .. (_G.memreader_plus_load_error or 'none recorded'),
		'  memreader_plus: ' .. (plus and 'loaded, version ' .. tostring(plus.plus_version) or 'not loaded'),
		'  old memreader: ' .. (old and old ~= plus and 'loaded' or 'not loaded'),
	}
end

local function dll_lines()
	local bin = load_bin()
	local name = bin.module .. '.dll'
	local file = io.open(name, 'rb')
	if not file then return { '  ' .. name .. ': not found in the game folder' } end
	local data = file:read('*a')
	file:close()
	local same = data == bin.data and 'the same bytes as the copy inside the pack' or 'different bytes than the copy inside the pack'
	return { ('  %s: %d bytes, expected %d bytes, %s'):format(name, #data, #bin.data, same) }
end

local function settings_lines()
	local text = build_snapshot()
	if not text then return { '  none recorded (MCT is not installed or has not loaded yet)' } end
	return { text }
end

local function log_lines()
	local file, open_error = io.open(LOG_FILE, 'rb')
	if not file then return { '  ' .. LOG_FILE .. ' could not be opened: ' .. tostring(open_error) } end
	local lines = {}
	for line in file:lines() do
		if string.find(string.lower(line), 'memreader') then
			lines[#lines + 1] = '  ' .. clean(string.gsub(line, '\r$', ''), LOG_LINE_LIMIT)
			if #lines > MAX_LOG_LINES then table.remove(lines, 1) end
		end
	end
	file:close()
	if #lines == 0 then return { '  no such lines' } end
	return lines
end

local function section(title, build)
	local ok, lines = pcall(build)
	if not ok then lines = { '  could not be read: ' .. tostring(lines) } end
	return title .. '\n' .. table.concat(lines, '\n')
end

local function lua_only_title()
	if _G.memreader_plus then return 'memreader Plus runtime report (Lua only: this memreader Plus build cannot write the full report)' end
	return 'memreader Plus runtime report (Lua only: the DLL is not loaded)'
end

local function lua_only_text()
	local parts = {
		lua_only_title() .. '\n' .. os.date('%Y-%m-%d %H:%M:%S') .. ', written on request, nothing crashed',
		section('Loader:', loader_lines),
		section('DLL file the loader writes:', dll_lines),
		section('MCT settings of the mods in this game:', settings_lines),
		section(('Lines of %s that mention memreader (newest %d at most):'):format(LOG_FILE, MAX_LOG_LINES), log_lines),
	}
	return mask_paths(table.concat(parts, '\n\n') .. '\n')
end

local function write_file(path, text)
	local file, open_error = io.open(path, 'wb')
	if not file then return false, open_error end
	local written, write_error = file:write(text)
	file:close()
	if not written then return false, write_error end
	return true
end

local function save_file(name, text)
	local temporary = name .. '.tmp'
	local ok, problem = write_file(temporary, text)
	if not ok then return false, tostring(problem) end
	if os.rename(temporary, name) then return true end
	ok, problem = write_file(name, text)
	os.remove(temporary)
	if ok then return true end
	return false, tostring(problem)
end

local function lua_only_report()
	local name = 'memreader_runtime_report_' .. os.date('%d%m%y_%H%M%S') .. '.txt'
	local ok, problem = save_file(name, lua_only_text())
	if ok then return true, name end
	return false, problem
end

local function native_report(plus)
	local ok, name, problem = pcall(plus.write_runtime_report)
	if not ok then return false, tostring(name) end
	if not name then return false, tostring(problem) end
	return true, name
end

local function build_report()
	refresh_safely()
	local plus = _G.memreader_plus
	if plus and plus.write_runtime_report then return native_report(plus) end
	return lua_only_report()
end

function _G.memreader_plus_runtime_report()
	local ok, done, result = pcall(build_report)
	if not ok then
		result = tostring(done)
		done = false
	end
	log(done and 'runtime report written: ' .. result or 'runtime report failed: ' .. result)
	return done, result
end

core:add_listener('memreader_plus_report_mct_initialized', 'MctInitialized', true, refresh_safely, true)
core:add_listener('memreader_plus_report_mct_finalized', 'MctFinalized', true, refresh_safely, true)
