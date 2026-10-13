local loaded = package.loaded.memreader_plus_agree_state
if loaded then return loaded.agree, loaded.internals end

local PREFIX = 'mrp|'
local PROTOCOL = '1'
local LIMIT = 255
local PIECE_MARK = 12
local MAX_PIECES = 6000
local MAX_BODY = 1000000
local MAX_VALUES = 990000
local TICK_BUDGET = 8192
local PIECE_COST = 262
local MAX_WAVES = 10
local MAX_ROUNDS = 8
local MAX_PENDING = 200
local MAX_LEVELS = 20
local TIMEOUT_SECONDS = 60
local POLL_MS = 1000
local POPUP_MS = 5000
local MODULUS = 65521
local LISTENER = 'mrp_messages'
local MODES = { same = true, ['local'] = true, load = true }
local REQUIRED = { same = 'links', load = true }
local KINDS = { r = true, s = true, v = true, t = true }
local LINKS = { hook = true, prefix = true, postfix = true, around = true, site = true }
local WAITING = 'waiting for the multiplayer agreement'
local OFF = 'off in this multiplayer campaign'
local CODE_ORDER = { 'p', 'r', 's', 'c', 'v', 'z', 'n', 'm', 'x' }
local BLOCKED_CAUSE =
	'memreader Plus may have been stopped by an antivirus, by Windows Smart App Control, or by a second copy of Total War: WARHAMMER III that is still open.'
local BLOCKED_HEADLINE = 'memreader Plus could not start, so mods that use it do nothing.'
local BLOCKED_ACTION = ' Close every copy of the game and %s. The file lua_mod_log.txt in the game folder shows the reason.'
local BLOCKED_TEXT = BLOCKED_HEADLINE .. '\n\n' .. BLOCKED_CAUSE .. BLOCKED_ACTION:format('start the game again')
local LARGE_TEXT =
	"%s: your change to the mod settings was too large to send.\n\nEveryone keeps the previous settings. Reset some of the mod's settings to their defaults, then make the change again."
local TEXTS = {
	p = {
		line = 'memreader Plus could not start.',
		explain = BLOCKED_CAUSE .. ' {who} should close every copy of the game and load this campaign again.',
		own = BLOCKED_CAUSE .. BLOCKED_ACTION:format('load this campaign again'),
	},
	r = {
		line = 'memreader Plus could not change the game code.',
		explain = "Another mod or program is probably using the same game code. {who} should turn off other mods that change the game's code, then load this campaign again.",
	},
	s = {
		line = 'the mod could not find the game code it needs.',
		explain = 'A game update, or another mod that changes the same game code, is the usual cause. {who} should check that the game and their mods are up to date, then load this campaign again.',
	},
	c = {
		line = 'the mod could not start.',
		explain = '{who} should load this campaign again. If it happens again, lua_mod_log.txt in their game folder shows the reason.',
		own = 'Load this campaign again. If it happens again, lua_mod_log.txt in your game folder shows the reason.',
	},
	v = {
		line = 'they have another version of the mod.',
		explain = 'Every player needs the same version of the mod and of memreader Plus. Whoever is behind should update both on the Workshop, then load this campaign again.',
	},
	z = {
		line = 'the mod settings are too large to send.',
		explain = "{who} should reset some of the mod's settings to their defaults, then load this campaign again.",
		own = "Reset some of the mod's settings to their defaults, then load this campaign again.",
	},
	n = {
		line = 'their game did not answer.',
		explain = "A script error in a game named above is the usual cause, and that player's script log shows it. Loading this campaign again usually fixes it.",
	},
	m = { line = "The host's mod settings did not arrive.", explain = 'Everyone should load this campaign again.', nameless = true },
	x = { line = "The players' games could not settle on the mod.", explain = 'Everyone should load this campaign again.', nameless = true },
}

local BLOCKED_FLAG = 'memreader_plus_blocked_shown'
local BLOCKED_NAME = 'memreader_plus_blocked_message'
local QUICK_POPUP_MS = 500

local host = _G
local entry = nil
local blocked_scheduled = false
local owners = {}
local order = {}
local pending = {}
local listening = false
local finalizing = false
local received = 0
local inflight = 0
local turn = 0

local function out(text)
	local write = host.ModLog or _G.ModLog or host.out
	if type(write) == 'function' then write('[memreader_plus] ' .. text) end
end

local function guarded(name, fn)
	return function(context)
		local ok, result = xpcall(function()
			return fn(context)
		end, debug.traceback)
		if ok then return result end
		out(name .. ' failed: ' .. tostring(result))
		return false
	end
end

local function slice(text, first, last)
	return string.char(text:byte(first, last))
end

local function is_name(value)
	return type(value) == 'string' and #value <= 47 and value:match('^[%w_]+$') ~= nil
end

local function sorted_keys(map)
	local list = {}
	for key in pairs(map) do
		list[#list + 1] = key
	end
	table.sort(list)
	return list
end

local function copy(map)
	local result = {}
	for key, value in pairs(map) do
		result[key] = value
	end
	return result
end

local function joined(list)
	if #list == 0 then return '-' end
	return table.concat(list, ',')
end

local function escape_char(char)
	return ('%%%02X'):format(char:byte())
end

local function escape(text)
	return (text:gsub('[%%|,]', escape_char):gsub('[^ -~]', escape_char))
end

local function unescape(text)
	if text:gsub('%%%x%x', ''):match('%%') then return nil end
	return (text:gsub('%%(%x%x)', function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

local function plain_number(text)
	return text:match('^%-?[%d%.e%+%-]+$') ~= nil
end

local function number_text(value)
	return (('%.9g'):format(value):gsub(',', '.'))
end

local function text_number(text)
	local mark = ('%.1f'):format(0.5):match('^%d(%D)')
	return tonumber((text:gsub('%.', mark)))
end

local function encode_value(value)
	local kind = type(value)
	if kind == 'boolean' then return value and 't' or 'f' end
	if kind == 'number' then return 'n' .. number_text(value) end
	if kind == 'string' then return 's' .. escape(value) end
	return '_'
end

local function encode_values(keys, values)
	local items = {}
	for index, key in ipairs(keys) do
		items[index] = encode_value(values[key])
	end
	return table.concat(items, ',')
end

local function decode_value(item)
	local tag, rest = item:match('^(.)(.*)$')
	if tag == 't' or tag == 'f' then return rest == '', tag == 't' end
	if tag == 'n' then
		local number = text_number(rest)
		return plain_number(rest) and number ~= nil, number
	end
	if tag == 's' then
		local text = unescape(rest)
		return text ~= nil, text
	end
	return item == '_', nil
end

local function decode_values(text, keys, defaults)
	local items = {}
	for item in (text .. ','):gmatch('([^,]*),') do
		items[#items + 1] = item
	end
	if #keys == 0 then return text == '' and {} or nil end
	if #items ~= #keys then return nil end
	local values = {}
	for index, key in ipairs(keys) do
		local ok, value = decode_value(items[index])
		if not ok or type(value) ~= type(defaults[key]) then return nil end
		values[key] = value
	end
	return values
end

local function sums(text)
	local first, second = 1, 0
	for index = 1, #text do
		first = (first + text:byte(index)) % MODULUS
		second = (second + first) % MODULUS
	end
	return first, second
end

local function usable(env)
	return type(env) == 'table' and env.core ~= nil and env.cm ~= nil
end

local function find_host()
	for level = 3, MAX_LEVELS do
		local info = debug.getinfo(level, 'f')
		if not info then break end
		local env = getfenv(info.func)
		if usable(env) then return env end
	end
	if usable(entry) then return entry end
	return nil
end

local function local_name()
	return host.cm:get_local_faction_name(true)
end

local function humans()
	return host.cm:get_human_factions()
end

local function sender_faction(context)
	return host.cm:model():faction_for_command_queue_index(context:faction_cqi()):name()
end

local function is_host()
	return host.core:svr_load_bool('mct_local_is_host') and true or false
end

local function mct_synced()
	if not host.get_mct then return true end
	return host.cm:get_saved_value('mct_mp_init') and true or false
end

local function is_candidate()
	return is_host() or local_name() == humans()[1]
end

local function timer_name(o, round, wave)
	return ('mrp_%s_%d_%d'):format(o.owner, round, wave)
end

local function hook_depth()
	local plus = _G.memreader_plus
	if not plus or type(plus.hook_depth) ~= 'function' then return '-' end
	local ok, depth = pcall(plus.hook_depth)
	return ok and tostring(depth) or '-'
end

local function site_list(sites)
	if sites == nil then return {} end
	if type(sites.ready) == 'function' then return { sites } end
	return sites
end

local function check(condition, text)
	if not condition then error('memreader_plus_agree: ' .. text, 0) end
end

local function check_spec(owner, spec)
	check(is_name(owner), 'the owner must be 1 to 47 letters, digits or underscores')
	check(type(spec) == 'table', 'the second argument must be a table')
	check(type(spec.features) == 'table', 'features must be a table')
	for name, mode in pairs(spec.features) do
		check(is_name(name) and MODES[mode], 'a feature needs a plain name and the mode same, local or load')
	end
	for key, default in pairs(spec.options or {}) do
		check(
			is_name(key) and (type(default) == 'boolean' or type(default) == 'number' or type(default) == 'string'),
			'an option needs a plain key and a default'
		)
	end
	check(type(spec.format) == 'number' and spec.format == math.floor(spec.format) and spec.format >= 1, 'format must be a whole number from 1')
	check(type(spec.apply) == 'function', 'apply must be a function')
	check(spec.ready == nil or type(spec.ready) == 'function', 'ready must be a function')
	check(spec.prepare == nil or type(spec.prepare) == 'function', 'prepare must be a function')
	check(spec.title == nil or type(spec.title) == 'string', 'title must be text')
	check(spec.mct == nil or type(spec.mct) == 'string', 'mct must be text')
	check(spec.sites == nil or type(spec.sites) == 'table', 'sites must be a table')
	for _, site in ipairs(site_list(spec.sites)) do
		check(type(site.ready) == 'function' and site.owner() == owner, 'sites must belong to the same owner')
	end
end

local function schema_of(o)
	local parts = { o.owner, tostring(o.format) }
	for _, name in ipairs(o.reported) do
		parts[#parts + 1] = name .. '=' .. o.modes[name]
	end
	for _, key in ipairs(o.keys) do
		parts[#parts + 1] = key .. ':' .. type(o.options[key])
	end
	local first, second = sums(table.concat(parts, '|'))
	return ('%d.%d'):format(first, second)
end

local function new_owner(owner, spec)
	local o = {
		owner = owner,
		spec = spec,
		modes = copy(spec.features),
		options = copy(spec.options or {}),
		format = spec.format,
		title = spec.title,
		mct = spec.mct or owner,
		sites = site_list(spec.sites),
		failed = {},
		detail = {},
		sent = {},
		bad = {},
		reports = {},
		pieces = {},
		reported = {},
		queue = {},
		head = 1,
		round = 0,
	}
	o.keys = sorted_keys(o.options)
	o.names = sorted_keys(o.modes)
	for _, name in ipairs(o.names) do
		if o.modes[name] ~= 'local' then o.reported[#o.reported + 1] = name end
	end
	o.schema = schema_of(o)
	return o
end

local function requirement_of(o, feature)
	local requirement = REQUIRED[o.modes[feature]]
	if requirement == 'links' and not o.mp then return nil end
	return requirement
end

local function feature_state(o, feature)
	if #o.sites == 0 then return 'p' end
	if o.failed[feature] then return 'r', o.failed[feature] end
	for _, site in ipairs(o.sites) do
		local ok, done, code, why = pcall(site.ready, feature, requirement_of(o, feature))
		if not ok then return 'r', tostring(done) end
		if done ~= true then return code or 'r', why end
	end
	if o.spec.ready then
		local ok, done, why = pcall(o.spec.ready, feature)
		if not ok then return 'c', tostring(done) end
		if done ~= true then return 'c', why end
	end
	return '1'
end

local function local_codes(o)
	local codes = {}
	for index, name in ipairs(o.reported) do
		local code, why = feature_state(o, name)
		codes[index] = code
		o.detail[name] = why
	end
	return table.concat(codes)
end

local function read_setting(mod, key, default)
	local ok, value = pcall(function()
		local option = mod:get_option_by_key(key)
		return option and option:get_finalized_setting()
	end)
	if not ok or type(value) ~= type(default) then return default end
	if type(value) == 'number' and not plain_number(number_text(value)) then return default end
	return value
end

local function read_values(o)
	local mod = nil
	if host.get_mct then
		local ok, found = pcall(function()
			local mct = host.get_mct()
			return mct and mct:get_mod_by_key(o.mct)
		end)
		mod = ok and found or nil
	end
	local values = {}
	for _, key in ipairs(o.keys) do
		values[key] = o.options[key]
		if mod then values[key] = read_setting(mod, key, o.options[key]) end
	end
	return values
end

local function window()
	local players = math.max(1, #humans())
	return math.max(1, math.floor(TICK_BUDGET / (PIECE_COST * players)))
end

local function queued(o)
	return o.head <= #o.queue
end

local function send_next(o, cqi)
	host.CampaignUI.TriggerCampaignScriptEvent(cqi, o.queue[o.head])
	o.queue[o.head] = false
	o.head = o.head + 1
	if o.head > #o.queue then
		o.queue, o.head = {}, 1
	end
	inflight = inflight + 1
end

local function next_owner()
	for offset = 1, #order do
		local index = (turn + offset - 1) % #order + 1
		if queued(owners[order[index]]) then
			turn = index
			return owners[order[index]]
		end
	end
	return nil
end

local function pump()
	local cqi = nil
	local limit = window()
	while inflight < limit do
		local o = next_owner()
		if not o then break end
		cqi = cqi or host.cm:get_local_faction(true):command_queue_index()
		send_next(o, cqi)
	end
end

local function came_back()
	if inflight > 0 then inflight = inflight - 1 end
	pump()
end

local function send(o, kind, round, body)
	if #body > MAX_BODY then return out(('%s: a %s message of %d characters is too long to send'):format(o.owner, kind, #body)) end
	local header = ('%s%s|%s|%s|%d|'):format(PREFIX, PROTOCOL, kind, o.owner, round)
	local room = LIMIT - #header - PIECE_MARK
	local count = math.max(1, math.ceil(#body / room))
	for index = 1, count do
		o.queue[#o.queue + 1] = ('%s%d/%d|%s'):format(header, index, count, slice(body, (index - 1) * room + 1, index * room))
	end
	pump()
end

local function values_field(o)
	local text = encode_values(o.keys, read_values(o))
	if #text <= MAX_VALUES then return '=' .. text end
	out(('%s: the settings are %d characters, more than the %d that can be sent'):format(o.owner, #text, MAX_VALUES))
	return '!'
end

local function report_body(o)
	local synced = mct_synced()
	local values = '-'
	if synced and is_candidate() then values = values_field(o) end
	return table.concat({ o.schema, synced and '1' or '0', is_host() and '1' or '0', local_codes(o), values }, '|')
end

local function poll_settings(o, round)
	host.cm:real_callback(
		guarded('settings poll', function()
			if o.exhausted or o.round > round or (o.round == round and o.decided) then return end
			if not mct_synced() then return poll_settings(o, round) end
			send(o, 's', round, values_field(o))
		end),
		POLL_MS,
		('mrp_poll_%s_%d'):format(o.owner, round)
	)
end

local function send_report(o, round)
	if o.sent[round] then return end
	o.sent[round] = true
	send(o, 'r', round, report_body(o))
	if not mct_synced() and is_candidate() then poll_settings(o, round) end
end

local function arm_timer(o, round, wave)
	host.cm:callback(
		guarded('timeout', function()
			if o.round == round and o.wave == wave and not o.decided then send(o, 't', round, tostring(wave)) end
		end),
		TIMEOUT_SECONDS,
		timer_name(o, round, wave)
	)
end

local function player_label(key)
	if key == local_name() then return 'Your game' end
	local ok, text = pcall(host.common.get_localised_string, 'factions_screen_name_' .. key)
	if not ok or type(text) ~= 'string' or text == '' then return key end
	return text
end

local function popup_group(code, problems)
	local texts = TEXTS[code]
	local lines, own = {}, false
	for _, problem in ipairs(problems) do
		if problem.code == code then
			if texts.nameless then
				lines[#lines + 1] = texts.line
			else
				lines[#lines + 1] = ('%s: %s'):format(player_label(problem.key), texts.line)
				own = own or problem.key == local_name()
			end
		end
	end
	if #lines == 0 then return nil end
	local who = #lines == 1 and 'The player named above' or 'Each player named above'
	local explain = (own and #lines == 1 and texts.own or texts.explain):gsub('{who}', who)
	lines[#lines + 1] = explain
	return table.concat(lines, '\n')
end

local function popup_text(o, outcome)
	local parts = {}
	if outcome.load_only then
		parts[1] = ('%s: this campaign may go out of sync.'):format(o.title)
	else
		parts[1] = ('%s: %s is off for everyone in this campaign.'):format(o.title, outcome.all_off and 'the mod' or 'part of the mod')
	end
	for _, code in ipairs(CODE_ORDER) do
		parts[#parts + 1] = popup_group(code, outcome.lines)
	end
	return table.concat(parts, '\n\n')
end

local function show_dialog(name, text)
	local root = host.core:get_ui_root()
	local box = host.UIComponent(root:CreateComponent(name, 'UI/Common UI/dialogue_box'))
	host.find_uicomponent(box, 'DY_text'):SetStateText(text, name)
	local cancel = host.find_uicomponent(box, 'button_cancel')
	if cancel then cancel:SetVisible(false) end
	box:PropagatePriority(99)
	box:LockPriority()
	host.core:add_listener(
		name .. '_ok',
		'ComponentLClickUp',
		guarded('popup condition', function(context)
			return context.string == 'button_tick' and host.uicomponent_descended_from(host.UIComponent(context.component), name)
		end),
		guarded('popup close', function()
			local open = host.find_uicomponent(root, name)
			if open then
				open:UnLockPriority()
				open:Destroy()
			end
		end),
		false
	)
end

local function schedule_popup(o, outcome)
	if not o.title or not outcome.shows_popup then return end
	local round = o.round
	host.cm:real_callback(
		guarded('popup', function()
			if o.round ~= round or o.popup_shown then return end
			o.popup_shown = true
			show_dialog(('mrp_%s_message'):format(o.owner), popup_text(o, outcome))
		end),
		POPUP_MS,
		('mrp_popup_%s_%d'):format(o.owner, round)
	)
end

local function log_decision(o, outcome)
	local on, off = {}, {}
	for _, name in ipairs(o.reported) do
		local list = outcome.on[name] and on or off
		list[#list + 1] = name
	end
	if o.mp then
		out(
			('%s round %d: on=%s off=%s sender=%s synced=%s hook_depth=%s'):format(
				o.owner,
				o.round,
				joined(on),
				joined(off),
				tostring(outcome.sender),
				tostring(outcome.synced),
				hook_depth()
			)
		)
	else
		out(('%s single player: on=%s off=%s'):format(o.owner, joined(on), joined(off)))
	end
	for _, name in ipairs(off) do
		out(('%s %s off: %s%s'):format(o.owner, name, tostring(outcome.why[name]), o.detail[name] and (' (here: ' .. tostring(o.detail[name]) .. ')') or ''))
	end
end

local open_round = nil

local function fail_features(o, failures)
	local changed = false
	for name, why in pairs(failures) do
		if o.outcome.on[name] then
			o.failed[name] = tostring(why)
			changed = true
			out(('%s %s failed here: %s'):format(o.owner, name, tostring(why)))
		end
	end
	if changed and o.mp and not o.exhausted then send_report(o, o.round + 1) end
end

local function run_apply(o)
	local outcome = o.outcome
	local on = {}
	for _, name in ipairs(o.names) do
		on[name] = outcome.on[name] or (o.modes[name] == 'local' and feature_state(o, name) == '1') or false
	end
	local ok, result = xpcall(function()
		return o.spec.apply(copy(outcome.values), on, copy(outcome.why))
	end, debug.traceback)
	if not ok then
		out(('%s apply failed: %s'):format(o.owner, tostring(result)))
		result = {}
		for name in pairs(outcome.on) do
			result[name] = 'apply raised an error'
		end
	end
	if type(result) == 'table' then fail_features(o, result) end
end

local function warn_large(o)
	if not o.title or o.large_warned then return end
	o.large_warned = true
	host.cm:real_callback(
		guarded('large settings popup', function()
			show_dialog(('mrp_%s_large'):format(o.owner), LARGE_TEXT:format(o.title))
		end),
		QUICK_POPUP_MS,
		('mrp_large_%s'):format(o.owner)
	)
end

local function refresh(o)
	local values = read_values(o)
	local text = encode_values(o.keys, values)
	if text == o.values_text then return out(o.owner .. ': the shared settings did not change') end
	if not o.mp then
		out(o.owner .. ': the shared settings changed, applying them again')
		o.values_text = text
		o.outcome.values = values
		return run_apply(o)
	end
	if not (o.decided and o.outcome.synced and o.sender == local_name()) then return end
	if #text > MAX_VALUES then
		out(('%s: the changed settings are %d characters, more than the %d that can be sent, the others keep the old ones'):format(o.owner, #text, MAX_VALUES))
		return warn_large(o)
	end
	send(o, 'v', o.round, o.schema .. '|' .. text)
end

local function finish(o, outcome)
	o.decided = true
	o.outcome = outcome
	o.on = outcome.on
	o.applied = true
	o.sender = outcome.sender
	o.values_text = outcome.text
	host.cm:remove_callback(timer_name(o, o.round, o.wave))
	log_decision(o, outcome)
	schedule_popup(o, outcome)
	run_apply(o)
	refresh(o)
end

local function choose_sender(o, list)
	for _, key in ipairs(list) do
		local report = o.reports[key]
		if report and report.host then return key end
	end
	return list[1]
end

local function reference_report(o, list, sender)
	if o.reports[sender] and not o.bad[sender] then return o.reports[sender] end
	for _, key in ipairs(list) do
		if o.reports[key] and not o.bad[key] then return o.reports[key] end
	end
	return nil
end

local function verdict(o, key, reference)
	if o.bad[key] then return 'v' end
	local report = o.reports[key]
	if not report then return 'n' end
	if not reference or report.schema ~= reference.schema then return 'v' end
	return nil
end

local function why_text(blamed)
	local parts = {}
	for index, item in ipairs(blamed) do
		parts[index] = item.key and (item.code .. ':' .. item.key) or item.code
	end
	return table.concat(parts, ',')
end

local function note_problems(problems, seen, blamed)
	for _, item in ipairs(blamed) do
		local id = tostring(item.key) .. item.code
		if not seen[id] then
			seen[id] = true
			problems[#problems + 1] = item
		end
	end
end

local function blame_feature(o, list, verdicts, index, differs, settings_problem)
	local blamed = {}
	for _, key in ipairs(list) do
		local code = verdicts[key] or (not differs and slice(o.reports[key].codes, index, index)) or '1'
		if code ~= '1' then blamed[#blamed + 1] = { key = key, code = code } end
	end
	if settings_problem then blamed[#blamed + 1] = settings_problem end
	return blamed
end

local function build_outcome(o, list, verdicts, sender, differs, settings_problem)
	local source = o.reports[sender]
	local usable = not differs and source ~= nil and source.values ~= nil and verdicts[sender] == nil
	local outcome = { round = o.round, on = {}, why = {}, synced = usable, sender = sender }
	outcome.values = usable and source.values or (differs and {} or copy(o.options))
	outcome.text = usable and source.values_text or nil
	local seen = { same = {}, load = {} }
	local problems = { same = {}, load = {} }
	for index, name in ipairs(o.reported) do
		local blamed = blame_feature(o, list, verdicts, index, differs, settings_problem)
		if #blamed == 0 then
			outcome.on[name] = true
		else
			outcome.why[name] = why_text(blamed)
			note_problems(problems[o.modes[name]], seen[o.modes[name]], blamed)
		end
	end
	outcome.load_only = #problems.same == 0
	outcome.lines = outcome.load_only and problems.load or problems.same
	outcome.shows_popup = #outcome.lines > 0
	outcome.all_off = next(outcome.on) == nil
	return outcome
end

local function evaluate(o, list)
	local complete = true
	for _, key in ipairs(list) do
		complete = complete and (o.reports[key] ~= nil or o.bad[key] == true)
	end
	if not complete and not o.timeout then return nil end
	local sender = choose_sender(o, list)
	local reference = reference_report(o, list, sender)
	local verdicts, differs = {}, false
	for _, key in ipairs(list) do
		verdicts[key] = verdict(o, key, reference)
		differs = differs or verdicts[key] == 'v'
	end
	local settings_problem = nil
	if not differs and verdicts[sender] == nil then
		local report = o.reports[sender]
		if report.too_large then
			settings_problem = { key = sender, code = 'z' }
		elseif not report.values then
			if not o.timeout then return nil end
			settings_problem = { code = 'm' }
		end
	end
	return build_outcome(o, list, verdicts, sender, differs, settings_problem)
end

local function try_decide(o)
	local list = humans()
	if o.decided or o.exhausted or #list == 0 then return end
	local outcome = evaluate(o, list)
	if outcome then finish(o, outcome) end
end

local function give_up(o)
	o.exhausted = true
	local outcome = { round = o.round, on = {}, why = {}, lines = { { code = 'x' } }, values = copy(o.options), shows_popup = true, all_off = true }
	for _, name in ipairs(o.reported) do
		outcome.why[name] = 'rounds'
	end
	out(('%s: no agreement after %d rounds, every shared feature is off'):format(o.owner, MAX_ROUNDS))
	finish(o, outcome)
end

function open_round(o, round)
	o.round = round
	o.reports = {}
	o.pieces = {}
	o.decided = false
	o.timeout = false
	o.wave = 1
	o.wave_pieces = 0
	if round > MAX_ROUNDS then return give_up(o) end
	send_report(o, round)
	arm_timer(o, round, 1)
end

local function parse_report(o, body)
	local schema, synced, claims, codes, values = body:match('^(%d+%.%d+)|([01])|([01])|(%w*)|(.*)$')
	if not schema then return nil end
	local report = { schema = schema, synced = synced == '1', host = claims == '1', codes = codes }
	if schema ~= o.schema then return report end
	if #codes ~= #o.reported or not codes:match('^[1psrc]*$') then return nil end
	if values == '-' then return report end
	if values == '!' then
		report.too_large = true
		return report
	end
	local text = values:match('^=(.*)$')
	report.values = text and decode_values(text, o.keys, o.options)
	report.values_text = text
	if not report.values then return nil end
	return report
end

local function mark_bad(o, faction)
	if o.bad[faction] then return end
	o.bad[faction] = true
	out(('%s: a message of %s could not be read'):format(o.owner, tostring(faction)))
	if o.decided then return open_round(o, o.round + 1) end
	try_decide(o)
end

local function on_report(o, faction, body)
	if o.decided or o.reports[faction] or o.bad[faction] then return end
	local report = parse_report(o, body)
	if not report then return mark_bad(o, faction) end
	o.reports[faction] = report
	try_decide(o)
end

local function on_timeout(o, _, body)
	local wave = tonumber(body)
	if o.decided or wave ~= o.wave then return end
	if o.wave_pieces > 0 and next(o.pieces) ~= nil and o.wave < MAX_WAVES then
		host.cm:remove_callback(timer_name(o, o.round, o.wave))
		o.wave, o.wave_pieces = o.wave + 1, 0
		return arm_timer(o, o.round, o.wave)
	end
	o.timeout = true
	try_decide(o)
end

local function on_settings(o, faction, body)
	local report = o.reports[faction]
	if o.decided or not report or report.values or report.too_large or report.schema ~= o.schema then return end
	if body == '!' then
		report.too_large = true
		return try_decide(o)
	end
	local text = body:match('^=(.*)$')
	local values = text and decode_values(text, o.keys, o.options)
	if not values then return mark_bad(o, faction) end
	report.values, report.values_text = values, text
	try_decide(o)
end

local function on_update(o, faction, body)
	if not o.decided or not o.outcome.synced or faction ~= o.sender then return end
	local schema, text = body:match('^([%d%.]+)|(.*)$')
	if schema ~= o.schema or text == o.values_text then return end
	local values = decode_values(text, o.keys, o.options)
	if not values then return end
	o.values_text = text
	o.outcome.values = values
	run_apply(o)
end

local HANDLERS = { r = on_report, t = on_timeout, s = on_settings, v = on_update }

local function take_piece(o, faction, header)
	local key = faction .. '|' .. header.kind
	local slot = o.pieces[key]
	if header.index == 1 then
		slot = { count_of = header.count, parts = {}, size = 0 }
		o.pieces[key] = slot
	elseif not slot or slot.count_of ~= header.count or header.index ~= #slot.parts + 1 then
		o.pieces[key] = nil
		mark_bad(o, faction)
		return nil
	end
	slot.size = slot.size + #header.piece
	if slot.size > MAX_BODY then
		o.pieces[key] = nil
		mark_bad(o, faction)
		return nil
	end
	slot.parts[header.index] = header.piece
	if header.index < slot.count_of then return nil end
	o.pieces[key] = nil
	return table.concat(slot.parts)
end

local function receive(o, faction, header)
	if header.round < o.round then return end
	if header.round > o.round then
		open_round(o, header.round)
	elseif o.decided and header.kind == 'r' and not o.reports[faction] and not o.bad[faction] then
		open_round(o, o.round + 1)
	end
	if o.exhausted or header.round ~= o.round then return end
	if header.kind ~= 't' then o.wave_pieces = o.wave_pieces + 1 end
	local body = take_piece(o, faction, header)
	if body then HANDLERS[header.kind](o, faction, body) end
end

local function parse_header(text)
	local protocol, kind, owner, round, index, count, piece = text:match('^mrp|(%d+)|(%a)|([%w_]+)|(%d+)|(%d+)/(%d+)|(.*)$')
	if protocol ~= PROTOCOL or not KINDS[kind] then return nil end
	round, index, count = tonumber(round), tonumber(index), tonumber(count)
	if round < 1 or round > 99 or count < 1 or count > MAX_PIECES or index < 1 or index > count then return nil end
	return { kind = kind, owner = owner, round = round, index = index, count = count, piece = piece }
end

local function reject(text, faction, only)
	local named = text:match('^mrp|[^|]*|[^|]*|([%w_]+)|')
	if named then
		local o = owners[named]
		if not o or (only and o ~= only) then return false end
		if o.mp and not o.exhausted then mark_bad(o, faction) end
		return true
	end
	for _, name in ipairs(order) do
		local o = owners[name]
		if (not only or o == only) and o.mp and not o.decided then mark_bad(o, faction) end
	end
	return false
end

local function dispatch(text, faction, only)
	local header = parse_header(text)
	if not header then return reject(text, faction, only) end
	local o = owners[header.owner]
	if not o or (only and o ~= only) then return false end
	if not o.mp or o.exhausted then return true end
	received = received + 1
	if header.index == 1 or header.index == header.count then
		out(('message %d: %s %s round %d piece %d/%d from %s'):format(received, header.owner, header.kind, header.round, header.index, header.count, faction))
	end
	receive(o, faction, header)
	return true
end

local function on_trigger(context)
	local text = context:trigger()
	local faction = sender_faction(context)
	if faction == local_name() then came_back() end
	if dispatch(text, faction) then return end
	if #pending < MAX_PENDING then pending[#pending + 1] = { text = text, faction = faction } end
end

local function replay(o)
	local kept = {}
	for _, item in ipairs(pending) do
		if not dispatch(item.text, item.faction, o) then kept[#kept + 1] = item end
	end
	pending = kept
	if o.decided then out(('%s: round %d was decided while replaying messages that arrived before agree'):format(o.owner, o.round)) end
end

local function on_finalized()
	out('MCT settings finalized, checking ' .. #order .. ' owner(s)')
	for _, name in ipairs(order) do
		if owners[name].applied then refresh(owners[name]) end
	end
end

local function listen_for_finalize()
	if finalizing then return end
	host.core:add_listener('mrp_mct_finalized', 'MctFinalized', true, guarded('settings changed', on_finalized), true)
	finalizing = true
end

local function register_listener()
	if listening or not host.core then return end
	host.core:add_listener(
		LISTENER,
		'UITrigger',
		guarded('message condition', function(context)
			return context:trigger():match('^mrp|') ~= nil
		end),
		guarded('message', on_trigger),
		true
	)
	listening = true
end

local function listen(env)
	if type(env) ~= 'table' or not env.core or not env.core:is_campaign() then return false end
	entry = env
	if not host.core then host = env end
	register_listener()
	return listening
end

local function show_blocked(env)
	local core = env.core
	if core:svr_load_bool(BLOCKED_FLAG) then return end
	if core:is_campaign() and env.cm:is_multiplayer() then return end
	core:svr_save_bool(BLOCKED_FLAG, true)
	show_dialog(BLOCKED_NAME, BLOCKED_TEXT)
end

local function warn_blocked(env)
	if blocked_scheduled or type(env) ~= 'table' or not env.core then return false end
	local campaign = env.core:is_campaign()
	if campaign and not (env.cm and type(env.cm.add_first_tick_callback) == 'function') then return false end
	blocked_scheduled = true
	host = env
	local function later()
		env.core:get_tm():real_callback(
			guarded('blocked popup', function()
				show_blocked(env)
			end),
			QUICK_POPUP_MS
		)
	end
	local delayed = guarded('blocked popup', later)
	if env.core:is_frontend() then env.core:add_ui_created_callback(delayed) end
	if campaign then env.cm:add_first_tick_callback(delayed) end
	return true
end

local function clear_leftovers(o)
	for _, name in ipairs(o.reported) do
		if o.modes[name] == 'same' then
			for _, site in ipairs(o.sites) do
				local ok, problem = pcall(site.clear_leftovers, name)
				if not ok then out(('%s: leftovers of %s not cleared: %s'):format(o.owner, name, tostring(problem))) end
			end
		end
	end
end

local function prepare(o)
	if not o.spec.prepare then return end
	o.preparing = true
	local ok, problem = xpcall(o.spec.prepare, debug.traceback)
	o.preparing = false
	if not ok then out(('%s prepare failed: %s'):format(o.owner, tostring(problem))) end
end

local function start_multiplayer(o)
	register_listener()
	prepare(o)
	open_round(o, 1)
	replay(o)
end

local function start_single(o)
	if listening then
		listening = false
		host.core:remove_listener(LISTENER)
	end
	prepare(o)
	local values = read_values(o)
	o.outcome = { on = {}, why = {}, values = values, synced = true }
	for _, name in ipairs(o.reported) do
		local code, why = feature_state(o, name)
		if code == '1' then
			o.outcome.on[name] = true
		else
			o.outcome.why[name] = why
		end
	end
	o.values_text = encode_values(o.keys, values)
	o.applied = true
	log_decision(o, o.outcome)
	run_apply(o)
end

local function agree(owner, spec)
	check_spec(owner, spec)
	local found = find_host()
	if not found then return nil, 'campaign only' end
	host = found
	if owners[owner] then return nil, 'already called' end
	local o = new_owner(owner, spec)
	o.mp = host.cm:is_multiplayer() and true or false
	owners[owner] = o
	order[#order + 1] = owner
	clear_leftovers(o)
	listen_for_finalize()
	if o.mp then
		start_multiplayer(o)
	else
		start_single(o)
	end
	return true
end

local function gate(owner, feature, kind)
	local o = owners[owner]
	if not o or not o.mp or o.modes[feature] ~= 'same' then return nil end
	if o.preparing and LINKS[kind] then return nil end
	if not o.applied then return WAITING end
	if o.on[feature] then return nil end
	return OFF
end

local function shared(owner, feature)
	local o = owners[owner]
	return o ~= nil and o.mp and o.modes[feature] == 'same'
end

local function active(owner, feature)
	local o = owners[owner]
	return o ~= nil and o.on ~= nil and o.on[feature] == true
end

local internals = { gate = gate, shared = shared, active = active, listen = listen, warn_blocked = warn_blocked }
package.loaded.memreader_plus_agree_state = { agree = agree, internals = internals }
return agree, internals
