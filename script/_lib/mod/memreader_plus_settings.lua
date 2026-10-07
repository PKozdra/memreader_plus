local function log(text)
	ModLog('[memreader_plus] ' .. text)
end

local function finalized(mod, key)
	local option = mod and mod:get_option_by_key(key)
	return option and option:get_finalized_setting()
end

local function apply_settings()
	local plus = _G.memreader_plus
	if not plus or not get_mct then return end
	local mod = get_mct():get_mod_by_key('memreader_plus')
	local crash_reports = finalized(mod, 'crash_reports')
	if type(crash_reports) == 'boolean' then plus.set_crash_reports(crash_reports) end
	local file_edits = finalized(mod, 'file_edits')
	if type(file_edits) ~= 'boolean' then return end
	local switch = assert(loadfile('/script/memreader_plus/file_edit_switch'))()
	switch.save(file_edits)
	if file_edits == plus.file_edit_status().enabled then return end
	plus.set_file_edits(file_edits)
	log(
		file_edits
				and 'file edits from mods turned on: edits refused while they were off come back when their mods make them again, for most mods at the next load'
			or 'file edits from mods turned off: the game reads files as they ship'
	)
end

local function apply_settings_safely()
	local ok, message = xpcall(apply_settings, debug.traceback)
	if not ok then log('cannot apply the MCT settings: ' .. tostring(message)) end
end

core:add_listener('memreader_plus_mct_initialized', 'MctInitialized', true, apply_settings_safely, true)
core:add_listener('memreader_plus_mct_finalized', 'MctFinalized', true, apply_settings_safely, true)
