local function apply_crash_reports()
	local plus = _G.memreader_plus
	if not plus or not get_mct then return end
	local mod = get_mct():get_mod_by_key('memreader_plus')
	local option = mod and mod:get_option_by_key('crash_reports')
	local enabled = option and option:get_finalized_setting()
	if type(enabled) == 'boolean' then plus.set_crash_reports(enabled) end
end

local function apply_crash_reports_safely()
	local ok, message = xpcall(apply_crash_reports, debug.traceback)
	if not ok then ModLog('[memreader_plus] cannot apply the MCT setting: ' .. tostring(message)) end
end

core:add_listener('memreader_plus_mct_initialized', 'MctInitialized', true, apply_crash_reports_safely, true)
core:add_listener('memreader_plus_mct_finalized', 'MctFinalized', true, apply_crash_reports_safely, true)
