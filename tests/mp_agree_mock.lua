H = {
	out = {},
	logs = {},
	applies = {},
	popups = {},
	listeners = {},
	timers = {},
	fail = {},
	cleared = {},
	real_sites = {},
	now = 0,
	real = 0,
	seq = 0,
	depth = 0,
}

local function copy(map)
	local result = {}
	for key, value in pairs(map) do
		result[key] = value
	end
	return result
end

local function truthy(map)
	local result = {}
	for key, value in pairs(map) do
		if value then result[key] = true end
	end
	return result
end

function H.configure(config)
	H.mp, H.me, H.cqi, H.humans, H.names = config.mp, config.me, config.cqi, config.humans, config.names
	H.host, H.synced, H.mct_values = config.host, config.synced, config.values
	H.leaders = config.leaders or {}
	H.mode = config.mode or 'campaign'
	H.localised = config.localised or {}
	if config.has_mct then
		get_mct = function()
			return {
				get_mod_by_key = function()
					return {
						get_option_by_key = function(_, key)
							return {
								get_finalized_setting = function()
									return H.mct_values[key]
								end,
							}
						end,
					}
				end,
			}
		end
	end
end

local float_format = '^%%[%-%d.]*[fgeEG]$'

function H.comma_numbers()
	local format, to_text, to_number = string.format, tostring, tonumber
	string.format = function(pattern, ...)
		local text = format(pattern, ...)
		if pattern:match(float_format) then return (text:gsub('%.', ',')) end
		return text
	end
	tostring = function(value)
		local text = to_text(value)
		if type(value) == 'number' then return (text:gsub('%.', ',')) end
		return text
	end
	tonumber = function(value, base)
		if base ~= nil or type(value) ~= 'string' then return to_number(value, base) end
		if value:match('%.') then return nil end
		return to_number((value:gsub(',', '.')))
	end
end

local function remove_timers(kind, name)
	local kept = {}
	for _, timer in ipairs(H.timers) do
		if timer.kind ~= kind or timer.name ~= name then kept[#kept + 1] = timer end
	end
	H.timers = kept
end

local function add_timer(kind, fn, wait, name)
	H.timers[#H.timers + 1] = { kind = kind, fn = fn, name = name, due = (kind == 'game' and H.now or H.real) + wait }
end

local function run_due(kind, clock)
	while true do
		local best = nil
		for index, timer in ipairs(H.timers) do
			if timer.kind == kind and timer.due <= clock and (not best or timer.due < H.timers[best].due) then best = index end
		end
		if not best then return end
		local timer = table.remove(H.timers, best)
		timer.fn()
	end
end

function H.advance(seconds)
	for _ = 1, seconds do
		H.now = H.now + 1
		run_due('game', H.now)
	end
end

function H.advance_real(ms)
	H.real = H.real + ms
	run_due('real', H.real)
end

cm = {}
function cm:is_multiplayer()
	return H.mp
end
function cm:get_human_factions()
	return H.humans
end
function cm:get_local_faction_name()
	return H.me
end
function cm:get_local_faction()
	return {
		command_queue_index = function()
			return H.cqi
		end,
	}
end
function cm:model()
	return {
		faction_for_command_queue_index = function(_, cqi)
			return {
				name = function()
					return H.names[cqi]
				end,
			}
		end,
	}
end
function cm:get_saved_value(key)
	if key == 'mct_mp_init' then return H.synced end
	return nil
end
function cm:get_faction(key)
	return {
		faction_leader = function()
			local leader = H.leaders[key]
			return {
				get_forename = function()
					return leader and leader[1] or ''
				end,
				get_surname = function()
					return leader and leader[2] or ''
				end,
			}
		end,
	}
end
function cm:add_first_tick_callback(fn)
	H.first_ticks[#H.first_ticks + 1] = fn
end
function cm:callback(fn, seconds, name)
	add_timer('game', fn, seconds, name)
end
function cm:remove_callback(name)
	remove_timers('game', name)
end
function cm:real_callback(fn, ms, name)
	add_timer('real', fn, ms, name)
end

core = {}
H.broken_listeners = 0
function core:add_listener(name, event, condition, callback, persistent)
	if H.broken_listeners > 0 then
		H.broken_listeners = H.broken_listeners - 1
		error('add_listener exploded')
	end
	H.listeners[#H.listeners + 1] = { name = name, event = event, condition = condition, callback = callback, persistent = persistent }
end
function core:remove_listener(name)
	local kept = {}
	for _, listener in ipairs(H.listeners) do
		if listener.name ~= name then kept[#kept + 1] = listener end
	end
	H.listeners = kept
end
H.svr = {}
H.ui_created = {}
H.first_ticks = {}
H.mode = 'campaign'
function core:svr_load_bool(key)
	if key == 'mct_local_is_host' then return H.host end
	return H.svr[key]
end
function core:svr_save_bool(key, value)
	H.svr[key] = value
end
function core:is_frontend()
	return H.mode == 'frontend'
end
function core:is_campaign()
	return H.mode == 'campaign'
end
function core:add_ui_created_callback(fn)
	H.ui_created[#H.ui_created + 1] = fn
end
function core:get_tm()
	return {
		real_callback = function(_, fn, ms)
			add_timer('real', fn, ms)
		end,
	}
end
local function make_box(name)
	local box = { name = name, locked = false }
	function box:PropagatePriority() end
	function box:LockPriority()
		self.locked = true
	end
	function box:UnLockPriority()
		self.locked = false
	end
	function box:Destroy()
		H.boxes[self.name] = nil
		H.destroyed[#H.destroyed + 1] = self.name
	end
	box.tick = { name = 'button_tick', parent = box }
	return box
end

H.boxes = {}
H.destroyed = {}
local root = {
	CreateComponent = function(_, name)
		local box = make_box(name)
		H.boxes[name] = box
		return box
	end,
}
function core:get_ui_root()
	return root
end
function uicomponent_descended_from(component, name)
	while component do
		if component.name == name then return true end
		component = component.parent
	end
	return false
end

CampaignUI = {}
function CampaignUI.TriggerCampaignScriptEvent(cqi, text)
	H.out[#H.out + 1] = { cqi, text }
end

common = {}
function common.get_localised_string(key)
	return H.localised[key] or ''
end

function UIComponent(box)
	return box
end
function find_uicomponent(box, name)
	if box == root then return H.boxes[name] end
	if name == 'DY_text' then return {
		SetStateText = function(_, text)
			H.popups[#H.popups + 1] = text
		end,
	} end
	if name == 'button_cancel' then return { SetVisible = function() end } end
	return nil
end

H.mod_lines = {}
H.script_lines = {}
function out(text)
	H.logs[#H.logs + 1] = text
	H.script_lines[#H.script_lines + 1] = text
end
function ModLog(text)
	H.logs[#H.logs + 1] = text
	H.mod_lines[#H.mod_lines + 1] = text
end

memreader_plus = {
	hook_depth = function()
		return H.depth
	end,
}

local function fire(event, context)
	local snapshot = {}
	for index, listener in ipairs(H.listeners) do
		snapshot[index] = listener
	end
	for _, listener in ipairs(snapshot) do
		if listener.event == event and (listener.condition == true or listener.condition(context)) then
			if not listener.persistent then core:remove_listener(listener.name) end
			listener.callback(context)
		end
	end
end

function H.click(box_name, button)
	local box = H.boxes[box_name]
	local component = button == 'button_tick' and box and box.tick or { name = button }
	fire('ComponentLClickUp', { string = button, component = component })
end

function H.deliver(cqi, text, seq)
	H.seq = seq
	fire('UITrigger', {
		trigger = function()
			return text
		end,
		faction_cqi = function()
			return cqi
		end,
	})
end

function H.finalize()
	fire('MctFinalized', {})
end

function H.run_load_callbacks()
	for _, fn in ipairs(H.ui_created) do
		fn()
	end
	for _, fn in ipairs(H.first_ticks) do
		fn()
	end
	H.ui_created, H.first_ticks = {}, {}
end

function H.take_out()
	local list = H.out
	H.out = {}
	return list
end

function H.listening(event)
	for _, listener in ipairs(H.listeners) do
		if listener.event == event then return true end
	end
	return false
end

function H.apply_for(owner)
	return function(values, on, why)
		local order = {}
		for name in pairs(on) do
			order[#order + 1] = name
		end
		H.applies[#H.applies + 1] = { owner = owner, seq = H.seq, values = copy(values), on = truthy(on), why = copy(why), order = table.concat(order, ',') }
		local plan = H.fail[owner]
		local step = plan and table.remove(plan, 1)
		if step == 'raise' then error('apply exploded') end
		if H.apply_hook then return H.apply_hook(owner, values, on, why) end
		return step
	end
end

function H.install_on_apply(owner, names)
	H.apply_hook = function(_, _, on)
		local failures = nil
		for _, name in ipairs(names) do
			if on[name] then
				local done, why = H.real_sites[owner].install_feature(name)
				if not done then
					failures = failures or {}
					failures[name] = why or 'install failed'
				end
			end
		end
		return failures
	end
end

function H.fake_sites(owner, states)
	local site = {}
	function site.owner()
		return owner
	end
	function site.ready(feature)
		local state = states[feature]
		if state == nil or state == true then return true end
		return false, state, 'fake ' .. state
	end
	function site.remove_feature()
		return true
	end
	function site.clear_leftovers(feature)
		H.cleared[#H.cleared + 1] = feature
		return 0
	end
	return site
end

H.hits = {}
H.prepared = {}

local function counted(owner)
	return function()
		H.hits[owner] = (H.hits[owner] or 0) + 1
	end
end

function H.link_callbacks(owner)
	local function around(game, first, second)
		H.hits[owner] = (H.hits[owner] or 0) + 1
		return game(first, second)
	end
	return {
		count_pre_high = counted(owner),
		count_pre_low = counted(owner),
		count_hook_alias = around,
		count_around = around,
		count_post = counted(owner),
	}
end

function H.prepare_for(owner, names)
	return function()
		for _, name in ipairs(names) do
			local done, why = H.real_sites[owner].install_feature(name, H.link_callbacks(owner))
			H.prepared[#H.prepared + 1] = { owner = owner, feature = name, done = done, why = why }
		end
	end
end

function H.attach_early(owner, names)
	H.prepare_for(owner, names)()
end

local function prepared_spec(owner, spec, states, prepare)
	if spec.sites == 'fake' then spec.sites = H.fake_sites(owner, states or {}) end
	if prepare then spec.prepare = H.prepare_for(owner, prepare) end
	if spec.sites == 'real' then spec.sites = H.real_sites[owner] end
	if spec.sites == false then spec.sites = nil end
	spec.apply = H.apply_for(owner)
	return spec
end

function H.start(owner, spec, states, prepare)
	local started, why = memreader_plus_agree(owner, prepared_spec(owner, spec, states, prepare))
	return started, why
end

local function poor_wrap(inner)
	local maker = loadstring('local inner = ... return function(...) return pcall(inner, ...) end')
	setfenv(maker, { pcall = pcall, cm = cm })
	return maker(inner)
end

function H.spec_for(owner, spec, states)
	return prepared_spec(owner, spec, states, nil)
end

function H.poor_chain(depth)
	local call = memreader_plus_agree
	for _ = 1, depth do
		call = poor_wrap(call)
	end
	return call
end

function H.start_kit(owner, spec, states, depth)
	return pcall(H.poor_chain(depth), owner, prepared_spec(owner, spec, states, nil))
end

function H.load_agree(source)
	local chunk = assert(loadstring(source, '@agree'))
	local agree, internals = chunk()
	memreader_plus_agree = agree
	H.gate = internals.gate
	H.internals = internals
	return internals
end

function H.listen_at_load()
	return H.internals.listen(GAME or _G)
end

function H.load_mod_script(path, source, env)
	local name = path:gsub('.*[\\/]', ''):gsub('%.lua$', '')
	if package.loaded[name] then
		ModLog('Failed to load mod: [' .. path .. ']')
		return false
	end
	local chunk = assert(loadstring(source, '@' .. path))
	setfenv(chunk, env or GAME or _G)
	package.loaded[name] = true
	local ok, problem = pcall(chunk)
	if not ok then
		ModLog('Failed to execute loaded mod file [' .. path .. '], error is: ' .. tostring(problem))
		return false
	end
	return true
end

function H.run_campaign_file(source)
	local chunk = assert(loadstring(source, '@campaign'))
	if GAME then setfenv(chunk, GAME) end
	chunk()
end

function H.rerun_agree(source)
	local chunk = assert(loadstring(source, '@agree'))
	local agree, internals = chunk()
	return agree == memreader_plus_agree, internals.gate == H.gate
end
