local function apply_crash_reports()
	local plus = _G.memreader_plus
	if not plus or not get_mct then return end
	local mod = get_mct():get_mod_by_key('memreader_plus')
	local option = mod and mod:get_option_by_key('crash_reports')
	if option then plus.set_crash_reports(option:get_finalized_setting()) end
end

core:add_listener('memreader_plus_mct_initialized', 'MctInitialized', true, apply_crash_reports, true)
core:add_listener('memreader_plus_mct_finalized', 'MctFinalized', true, apply_crash_reports, true)
