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
