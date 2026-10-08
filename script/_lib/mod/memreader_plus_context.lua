local CAMPAIGN_FIELDS = { 'campaign', 'campaign type', 'multiplayer', 'difficulty', 'turn', 'player', 'humans', 'faction turn' }
local BATTLE_FIELDS = { 'battle type' }
local QUIT_BUTTONS = { button_quit = 'quitting', button_windows = 'quitting to Windows' }

local phase = nil
local phase_before_quit = nil

local function try(fn, ...)
	local ok, result = pcall(fn, ...)
	if ok then return result end
end

local function set(name, value)
	local plus = _G.memreader_plus
	if not plus or not plus.set_crash_context then return end
	if value ~= nil then value = tostring(value) end
	pcall(plus.set_crash_context, name, value)
end

local function set_phase(value)
	phase = value
	set('phase', value)
end

local function clear(names)
	for _, name in ipairs(names) do
		set(name, nil)
	end
end

local function human_list()
	local humans = try(cm.get_human_factions, cm)
	if type(humans) == 'table' then return table.concat(humans, ', ') end
end

local function capture_campaign()
	local model = try(cm.model, cm)
	set('mode', 'campaign')
	set('campaign', try(cm.get_campaign_name, cm))
	set('campaign type', model and try(model.campaign_type, model))
	set('multiplayer', try(cm.is_multiplayer, cm))
	set('difficulty', try(cm.get_difficulty, cm, true))
	set('turn', model and try(model.turn_number, model))
	set('player', try(cm.get_local_faction_name, cm, true))
	set('humans', human_list())
end

local function capture_battle()
	set('mode', 'battle')
	set('battle type', try(bm.battle_type, bm))
end

local function capture_faction_turn(context)
	set(
		'faction turn',
		try(function()
			return context:faction():name()
		end)
	)
end

local function safely(fn)
	return function(context)
		pcall(fn, context)
	end
end

local function watch_events()
	local plus = _G.memreader_plus
	local dispatch = core.event_callback
	if not plus or not plus.note_crash_event or type(dispatch) ~= 'function' or dispatch == rawget(core, 'memreader_plus_events') then return end
	local note = plus.note_crash_event
	local wrapper = function(self, eventname, context)
		note(eventname)
		return dispatch(self, eventname, context)
	end
	rawset(core, 'memreader_plus_events', wrapper)
	rawset(core, 'event_callback', wrapper)
end

local function on_click(context)
	local name = context.string
	if QUIT_BUTTONS[name] then
		phase_before_quit = phase_before_quit or phase
		set_phase(QUIT_BUTTONS[name])
	elseif name == 'button_cancel' and phase_before_quit then
		set_phase(phase_before_quit)
		phase_before_quit = nil
	end
end

local function is_quit_click(context)
	return QUIT_BUTTONS[context.string] ~= nil or (context.string == 'button_cancel' and phase_before_quit ~= nil)
end

local function watch_quit()
	core:add_listener('memreader_plus_context_quit', 'ComponentLClickUp', is_quit_click, safely(on_click), true)
end

local function enter_campaign()
	watch_events()
	set_phase('campaign')
	capture_campaign()
end

local function enter_battle()
	watch_events()
	set_phase('battle')
end

local function watch_battle_phases()
	for _, name in ipairs({ 'Deployment', 'Deployed' }) do
		bm:register_phase_change_callback(name, safely(enter_battle))
	end
end

watch_events()
watch_quit()
try(core.add_ui_created_callback, core, safely(watch_events))

if core:is_campaign() then
	clear(BATTLE_FIELDS)
	set('mode', 'campaign')
	set_phase('loading campaign')
	core:add_listener('memreader_plus_context_first_tick', 'FirstTickAfterWorldCreated', true, safely(enter_campaign), true)
	core:add_listener('memreader_plus_context_round', 'WorldStartRound', true, safely(capture_campaign), true)
	core:add_listener('memreader_plus_context_faction_turn', 'FactionTurnStart', true, safely(capture_faction_turn), true)
elseif core:is_battle() then
	set('mode', 'battle')
	set_phase('loading battle')
	safely(capture_battle)()
	safely(watch_battle_phases)()
else
	clear(CAMPAIGN_FIELDS)
	clear(BATTLE_FIELDS)
	set('mode', 'frontend')
	set_phase('main menu')
end
