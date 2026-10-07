local plus = ...

local find = string.find_lua or string.find
local sub = string.sub_lua or string.sub
local match = string.match
local gsub = string.gsub

local MAX_OPS = 4096
local PATHS = {
	component = {},
	state = { 'states', '*' },
	image = { 'states', '*', 'imagemetrics', 'image' },
	text = { 'states', '*', 'component_text' },
	component_image = { 'componentimages', 'component_image' },
	engine = { 'LayoutEngine' },
}
local CHANGE_KINDS = { 'set', 'hide', 'add_callback' }
local CHANGE_KEYS = {
	set = { set = true, values = true, on = true, where = true, expect = true },
	hide = { hide = true, expect = true },
	add_callback = { add_callback = true, values = true },
}
local SPEC_KEYS = { owner = true, id = true, path = true, priority = true, once = true, changes = true, ops = true }
local SPECIAL_NODES = { { '<!--', '-->' }, { '<![CDATA[', ']]>' }, { '<?', '?>' }, { '<!', '>' } }
local ENTITIES = { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;', ['"'] = '&quot;', ['\t'] = '&#9;', ['\n'] = '&#10;', ['\r'] = '&#13;' }
local NAMED = { lt = '<', gt = '>', amp = '&', quot = '"', apos = "'" }

local function find_text(text, needle, from)
	return find(text, needle, from, true)
end

local function sorted_keys(map)
	local keys = {}
	for key in pairs(map) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

local function unknown_key(map, allowed)
	for key in pairs(map) do
		if not allowed[key] then return tostring(key) end
	end
	return nil
end

local function list_length(list)
	local count = 0
	for key in pairs(list) do
		if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) then return nil end
		count = count + 1
	end
	for index = 1, count do
		if list[index] == nil then return nil end
	end
	return count
end

local function entry_for(group, key, new_entry)
	if not group.by_key[key] then
		group.by_key[key] = new_entry
		group.list[#group.list + 1] = new_entry
	end
	return group.by_key[key]
end

local function escape(value)
	return (gsub(value, '[&<>"\t\n\r]', ENTITIES))
end

local function character(code)
	if code and code < 128 then return string.char(code) end
	return nil
end

local function decoded(value)
	if not value then return nil end
	value = gsub(value, '&#x(%x+);', function(hex)
		return character(tonumber(hex, 16))
	end)
	value = gsub(value, '&#(%d+);', function(digits)
		return character(tonumber(digits))
	end)
	return (gsub(value, '&(%a+);', NAMED))
end

local function read_tag(text, at)
	local closing, name, position = match(text, '^<(/?)([^%s/>]+)()', at)
	if not name then return nil end
	local tag = { start = at, closing = closing == '/', name = name, attributes = {}, spans = {}, counts = {}, attributes_end = position }
	while true do
		local key, quote, value_start = match(text, '^%s+([^%s=/>]+)%s*=%s*(["\'])()', position)
		if not key then break end
		local value_end = find_text(text, quote, value_start)
		if not value_end then return nil end
		if not tag.spans[key] then
			tag.attributes[key] = sub(text, value_start, value_end - 1)
			tag.spans[key] = { value_start - 1, value_end + 1 }
		end
		tag.counts[key] = (tag.counts[key] or 0) + 1
		position = value_end + 1
		tag.attributes_end = position
	end
	local empty, finish = match(text, '^%s*(/?)>()', position)
	if not finish then return nil end
	tag.empty = empty == '/'
	tag.finish = finish
	return tag
end

local function after_special(text, at)
	for _, node in ipairs(SPECIAL_NODES) do
		if sub(text, at, at + #node[1] - 1) == node[1] then
			local close = find_text(text, node[2], at + #node[1])
			return close and close + #node[2] or false
		end
	end
	return nil
end

local function next_tag(text, position)
	while true do
		local at = find_text(text, '<', position)
		if not at then return nil end
		local skipped = after_special(text, at)
		if skipped == false then return nil end
		if not skipped then return read_tag(text, at) end
		position = skipped
	end
end

local function read_element(text, from, nodes)
	local stack = {}
	local root = nil
	local position = from
	repeat
		local tag = next_tag(text, position)
		if not tag then return nil end
		position = tag.finish
		if tag.closing then
			local node = table.remove(stack)
			if not node or node.name ~= tag.name then return nil end
			node.finish = tag.finish
		else
			local parent = stack[#stack]
			tag.open_end = tag.finish
			tag.guid = tag.attributes.this
			tag.parent = parent
			tag.children = {}
			root = root or tag
			if parent then parent.children[#parent.children + 1] = tag end
			if nodes then nodes[#nodes + 1] = tag end
			if not tag.empty then stack[#stack + 1] = tag end
		end
	until #stack == 0
	return root
end

local function read_layout(text)
	if sub(text, 1, 2) == '\255\254' then return nil, 'the file is UTF-16' end
	local hierarchy = find_text(text, '<hierarchy', 1)
	local components = find_text(text, '<components>', 1)
	if not hierarchy or not components then return nil, 'not a TWUI layout: <hierarchy> or <components> is missing' end
	local nodes = {}
	if not read_element(text, hierarchy, nodes) then return nil, 'the <hierarchy> block does not parse' end
	return { text = text, nodes = nodes, components = components + #'<components>' }
end

local function definition(layout, guid)
	local text = layout.text
	local needle = 'this="' .. guid .. '"'
	local at = find_text(text, needle, layout.components)
	if not at then return nil, 'its definition is missing' end
	if find_text(text, needle, at + 1) then return nil, 'its GUID is defined twice' end
	local window = math.max(layout.components, at - 4096)
	local offset = match(sub(text, window, at), '.*()<')
	local element = offset and read_element(text, window + offset - 1)
	if not element or element.guid ~= guid then return nil, 'its definition does not parse' end
	return element
end

local function hierarchy_name(id)
	local name = gsub(gsub(string.lower(id), '[^%w_]', '_'), '_+', '_')
	if match(name, '^%d') then return '_' .. name end
	return name
end

local function same_id(node, step)
	return node.name == step or node.name == hierarchy_name(step)
end

local function has_ancestors(node, steps)
	local index = #steps - 1
	local parent = node.parent
	while index > 0 and parent do
		if same_id(parent, steps[index]) then index = index - 1 end
		parent = parent.parent
	end
	return index == 0
end

local function find_component(layout, selector)
	local by_guid = match(selector, '^%x+%-%x+%-%x+%-%x+$') ~= nil
	local steps = {}
	for step in string.gmatch(selector, '[^/]+') do
		steps[#steps + 1] = step
	end
	local found = {}
	for _, node in ipairs(layout.nodes) do
		local hit = node.guid == selector
		if not by_guid then hit = node.guid ~= nil and #steps > 0 and same_id(node, steps[#steps]) and has_ancestors(node, steps) end
		if hit then found[#found + 1] = node end
	end
	if #found == 0 then return nil, "matches 0 components, expected 1 (an id matches as written or as the layout's <hierarchy> block spells it)" end
	if #found > 1 then return nil, ('matches %d components, expected 1'):format(#found) end
	return definition(layout, found[1].guid)
end

local function descendants(element, path, depth, found)
	if depth > #path then
		found[#found + 1] = element
		return found
	end
	for _, child in ipairs(element.children) do
		if path[depth] == '*' or child.name == path[depth] then descendants(child, path, depth + 1, found) end
	end
	return found
end

local function mismatch(element, wanted)
	for _, name in ipairs(sorted_keys(wanted)) do
		local current = decoded(element.attributes[name])
		if current ~= wanted[name] then
			return ('%s %s is %s, expected "%s"'):format(element.name, name, current and ('"' .. current .. '"') or 'missing', wanted[name])
		end
	end
	return nil
end

local function read_values(values, field, optional)
	if values == nil and optional then return {} end
	if type(values) ~= 'table' or next(values) == nil then return nil, field .. ' must be a table of attribute = value' end
	local texts = {}
	for name, value in pairs(values) do
		if type(name) ~= 'string' or not match(name, '^[%a_][%w_]*$') then return nil, ('%s: %s is not an attribute name'):format(field, tostring(name)) end
		local whole = type(value) == 'number' and value == math.floor(value) and math.abs(value) < 1e7
		if type(value) ~= 'string' and not whole then return nil, ('%s: %s must be text or a whole number below 10000000'):format(field, name) end
		if type(value) == 'string' and match(value, '[%z\1-\8\11\12\14-\31]') then
			return nil, ('%s: %s holds a control character other than tab or a line break'):format(field, name)
		end
		texts[name] = whole and ('%d'):format(value) or value
	end
	return texts
end

local function add_set(edits, component, change, values)
	local on = change.on or 'component'
	if not PATHS[on] then return nil, 'on must be component, state, image, text, component_image or engine' end
	if on ~= 'component' and component.attributes.part_of_template == 'true' then
		return nil, 'it is part of a template: the game ignores its states, images, texts and engine, so edit the template'
	end
	local where, where_error = read_values(change.where, 'where', true)
	if not where then return nil, where_error end
	local expect, expect_error = read_values(change.expect, 'expect', true)
	if not expect then return nil, expect_error end
	local targets = 0
	for _, element in ipairs(descendants(component, PATHS[on], 1, {})) do
		if not mismatch(element, where) then
			local problem = mismatch(element, expect)
			if problem then return nil, problem end
			local entry = entry_for(edits, element.start, { component = component, element = element, values = {} })
			for key, value in pairs(values) do
				entry.values[key] = value
			end
			targets = targets + 1
		end
	end
	if targets == 0 then return nil, ('no %s matches'):format(on) end
	return true
end

local function add_callback(callbacks, component, values)
	if not values.callback_id then return nil, 'values needs callback_id' end
	if component.empty then return nil, ('%s has no body to add a callback to'):format(component.name) end
	local parts = { '<callback_with_context callback_id="' .. escape(values.callback_id) .. '"' }
	for _, name in ipairs(sorted_keys(values)) do
		if name ~= 'callback_id' then parts[#parts + 1] = (' %s="%s"'):format(name, escape(values[name])) end
	end
	parts[#parts + 1] = '/>'
	local entry = entry_for(callbacks, component.start, { component = component, texts = {} })
	entry.texts[#entry.texts + 1] = table.concat(parts)
	return true
end

local function change_kind(change)
	if type(change) ~= 'table' then return nil, 'is not a table' end
	local kind = nil
	for _, name in ipairs(CHANGE_KINDS) do
		if change[name] ~= nil then
			if kind then return nil, 'has more than one of set, hide and add_callback' end
			kind = name
		end
	end
	if not kind then return nil, 'needs set, hide or add_callback' end
	if type(change[kind]) ~= 'string' then return nil, kind .. ' must be a component id path or GUID' end
	return kind
end

local function add_change(layout, edits, callbacks, kind, change)
	local key = unknown_key(change, CHANGE_KEYS[kind])
	if key then return nil, ("unknown key '%s'"):format(key) end
	local component, why = find_component(layout, change[kind])
	if not component then return nil, why end
	if kind == 'hide' then return add_set(edits, component, { expect = change.expect }, { visible = 'false' }) end
	local values, problem = read_values(change.values, 'values')
	if not values then return nil, problem end
	if kind == 'set' then return add_set(edits, component, change, values) end
	return add_callback(callbacks, component, values)
end

local function read_change(layout, edits, callbacks, change)
	local kind, why = change_kind(change)
	if not kind then return nil, why end
	local ok, problem = add_change(layout, edits, callbacks, kind, change)
	if not ok then return nil, ('%s %s: %s'):format(kind, change[kind], problem) end
	return true
end

local function locate(text, after)
	local from = 1
	for _, anchor in ipairs(after) do
		local at = find_text(text, anchor, from)
		if not at then return nil end
		from = at + #anchor
	end
	return from
end

local function anchor(text, element)
	local owner = element
	while not owner.guid do
		owner = owner.parent
	end
	local after = { '<components>', 'this="' .. owner.guid .. '"' }
	if owner ~= element then after[3] = '<' .. element.name end
	local from = locate(text, after)
	if from and from > element.start and from < element.open_end then return after end
	return nil, ('cannot anchor an op in %s'):format(element.name)
end

local function build_ops(text, edits, callbacks)
	local ops = {}
	for _, entry in ipairs(edits.list) do
		local after, why = anchor(text, entry.element)
		if not after then return nil, why end
		for _, name in ipairs(sorted_keys(entry.values)) do
			ops[#ops + 1] = { after = after, attribute = name, value = entry.values[name] }
		end
	end
	for _, entry in ipairs(callbacks.list) do
		local after = { '<components>', 'this="' .. entry.component.guid .. '"' }
		ops[#ops + 1] = { after = after, child = 'callbackwithcontextlist', insert = table.concat(entry.texts) }
	end
	if #ops > MAX_OPS then return nil, ('the changes need %d ops, at most %d: split them into several edits'):format(#ops, MAX_OPS) end
	return ops
end

local function ops_of(spec, text)
	if spec.changes ~= nil and spec.ops ~= nil then return nil, 'takes changes or ops, not both' end
	if spec.changes == nil and spec.ops ~= nil then return spec.ops end
	local count = type(spec.changes) == 'table' and list_length(spec.changes)
	if not count or count == 0 then return nil, 'changes must be a list of one or more changes' end
	local layout, why = read_layout(text)
	if not layout then return nil, why end
	local edits = { list = {}, by_key = {} }
	local callbacks = { list = {}, by_key = {} }
	for index, change in ipairs(spec.changes) do
		local ok, problem = read_change(layout, edits, callbacks, change)
		if not ok then return nil, ('change %d, %s'):format(index, problem) end
	end
	return build_ops(text, edits, callbacks)
end

local function read_file(spec, text)
	if type(spec) ~= 'table' or type(spec.path) ~= 'string' then return nil, 'takes an edit table with a path' end
	local key = unknown_key(spec, SPEC_KEYS)
	if key then return nil, ("unknown key '%s' in the edit"):format(key) end
	if text then return text end
	local ok, file = pcall(plus.read_pack_file, spec.path)
	if not ok then
		local problem = tostring(file)
		return nil, 'path ' .. (match(problem, "^bad argument #1 to '[^']*' %((.*)%)$") or problem)
	end
	if not file then return nil, 'no such file: ' .. spec.path end
	return file
end

local twui = {}

function twui.preview(spec, text)
	local file, why = read_file(spec, text)
	if not file then return nil, why end
	local ops, problem = ops_of(spec, file)
	if not ops then return nil, problem end
	local edited, op_problem = plus.file_edit_apply(file, ops)
	if not edited then return nil, op_problem end
	return edited, ops
end

function twui.edit(spec)
	local text, why = read_file(spec)
	if not text then return nil, why end
	if type(spec.owner) ~= 'string' or type(spec.id) ~= 'string' then return nil, 'owner and id must be strings' end
	if not plus.file_edit_status().enabled then return nil, 'off: switched off by the player' end
	local ops, problem = ops_of(spec, text)
	if not ops then return nil, problem end
	return plus.file_edit({ owner = spec.owner, id = spec.id, path = spec.path, priority = spec.priority, once = spec.once, ops = ops })
end

return twui
