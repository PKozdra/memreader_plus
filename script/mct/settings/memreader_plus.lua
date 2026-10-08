local mod = get_mct():register_mod('memreader_plus')
mod:set_title('memreader Plus')
mod:set_author('Druwski')
mod:set_description('A library for reading, writing and hooking game memory.')

local option = mod:add_new_option('crash_reports', 'checkbox')
option:set_default_value(true)
option:set_text('Enable better crash reporting')
option:set_tooltip_text(
	'When the game crashes, writes memreader_crash_report_<date>_<time>.txt into the game folder, next to Warhammer3.exe (Steam: Manage > Browse local files).'
)
option:set_is_global(true)

local file_edits = mod:add_new_option('file_edits', 'checkbox')
file_edits:set_default_value(true)
file_edits:set_text('File edits from mods')
file_edits:set_tooltip_text(
	'Lets mods change game files, such as UI layouts, as the game reads them, without replacing the files. Untick it to have the game read every file as it ships. Applies the next time each file loads: a panel opened again, the next loading screen, battle or campaign. After ticking it again, some edits come back only after the next load.'
)
file_edits:set_is_global(true)

local function show_report_result()
	local ok, done, result = pcall(_G.memreader_plus_runtime_report)
	local text = nil
	if ok and done then
		text = ('Runtime report saved as %s\n\nIt is in the game folder, next to Warhammer3.exe (Steam: Manage > Browse local files). Send it together with your problem report.'):format(
			result
		)
	else
		text = ('The runtime report could not be written: %s'):format(tostring(ok and result or done))
	end
	GLib.TriggerPopup('memreader_plus_runtime_report', text, false)
end

local report = mod:add_new_action('runtime_report', ' ', function()
	local ok, problem = xpcall(show_report_result, debug.traceback)
	if not ok then ModLog('[memreader_plus] cannot show the runtime report result: ' .. tostring(problem)) end
end)
report:set_button_text('Generate a runtime report')
report:set_tooltip_text(
	'Writes memreader_runtime_report_<date>_<time>.txt into the game folder, next to Warhammer3.exe (Steam: Manage > Browse local files). It lists the game state, the settings of your MCT mods and the memreader Plus lines of the mod log. Send it when you report a problem.'
)
report:set_is_global(true)
