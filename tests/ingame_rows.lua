local mr = _G.memreader_plus
local PHASE = ROWS_PHASE or 'add'
local OWNER = 'rows_probe'
local TABLE_NAME = 'battle_currency_modifiers_to_source_types'
local SOURCE_TABLE = 'battle_secondary_currency_source_types'
local MODIFIER = 'Unit_size_setting'
local SOURCES = { 'army_losses', 'army_losses_own_army', 'army_entities_in_melee', 'casualties_amongst_own_lowly_infantry', 'hp_damage_inflicted' }
local DATABASES = '48 8B 0D ?? ?? ?? ?? 4C 8B C0 48 8B 91 ?? ?? ?? ?? 48 8B CB E8 ?? ?? ?? ?? 48 85 C0 74 ?? 48 8B 0D ?? ?? ?? ?? 48 89 81'
local KEY_MAP_METHOD = '48 8D 41 28 48 89 02 48 8B 41 58 49 89 00 C3'
local SLOT_SIZE, LOCK_AT, NAME_AT, RECORDS_AT, KEYS_AT = 0x38, 0x18, 0x58, 8, 0x28
local NODE_INDEX = 0x20

local result = { lines = {}, failed = 0 }
local function check(ok, what)
	result.lines[#result.lines + 1] = (ok and 'ok   ' or 'FAIL ') .. what
	if not ok then result.failed = result.failed + 1 end
end
local function note(text)
	result.lines[#result.lines + 1] = '     ' .. text
end

local function hex(bytes)
	return (bytes:gsub('.', function(c)
		return ('%02x'):format(c:byte())
	end))
end

local function find_tables()
	local match, count = mr.find_pattern(DATABASES)
	if count ~= 1 then return nil, 'databases pattern found ' .. tostring(count) end
	local global = mr.add(mr.add(match, 7), mr.read_int32(match, 3, true))
	local db = mr.read_chain(global, 0, mr.read_uint32(match, 13))
	local method, method_count = mr.find_pattern(KEY_MAP_METHOD)
	if method_count ~= 1 then return nil, 'key map method found ' .. tostring(method_count) end
	local found = {}
	for slot = 0, 2000 do
		local at = slot * SLOT_SIZE
		if mr.read_int32(db, at + LOCK_AT) ~= -1 then break end
		local t = mr.read_pointer(db, at)
		if not mr.is_null(t) then
			local first = mr.read_pointer(mr.read_pointer(t, 0), 0)
			if mr.eq(first, method) then found[mr.read_string(mr.read_pointer(t, NAME_AT), 0)] = t end
		end
	end
	return found
end

local function keys_of(t)
	local nodes = mr.read_list(mr.add(t, KEYS_AT), 0, { 0, 'struct', { key = { 0x10, 'string' }, index = { NODE_INDEX, 'uint32' } } })
	local list = {}
	for _, node in ipairs(nodes) do
		list[#list + 1] = node.key .. '=' .. node.index
	end
	table.sort(list)
	return list
end

local function record_pointer(t, key)
	local node = mr.map_find_key(mr.add(t, KEYS_AT), key)
	if not node then return nil end
	local _, data = mr.read_array(t, RECORDS_AT)
	return mr.read_pointer(data, mr.read_uint32(node, NODE_INDEX) * 8)
end

local function digest(text)
	local a, b = 0, 0
	for i = 1, #text do
		local c = text:byte(i)
		a = (a * 3 + c) % 65521
		b = (b * 5 + c + a) % 65519
	end
	return #text .. ':' .. a .. ':' .. b
end

local function snapshot(t, size)
	local count, data = mr.read_array(t, RECORDS_AT)
	local records = {}
	for i = 0, count - 1 do
		local record = mr.read_pointer(data, i * 8)
		records[#records + 1] = mr.tostring(record) .. ':' .. hex(mr.read(record, 0, size))
	end
	return digest(count .. '|' .. table.concat(records, ';') .. '|' .. table.concat(keys_of(t), ' '))
end

local tables, why = find_tables()
if not tables then
	check(false, 'tables: ' .. tostring(why))
	return result
end
local t, sources = tables[TABLE_NAME], tables[SOURCE_TABLE]
check(t ~= nil and sources ~= nil, 'both tables found')
local RECORD_SIZE = 0x20
local p = mr.patcher(OWNER)

local function new_rows()
	local list = {}
	for _, source in ipairs(SOURCES) do
		list[#list + 1] = { name = 'row_' .. source, key = MODIFIER .. source, source = source }
	end
	return list
end

if PHASE == 'add' then
	local keys = keys_of(t)
	note('rows ' .. mr.read_int32(t, RECORDS_AT + 4) .. ', capacity ' .. mr.read_uint32(t, RECORDS_AT) .. ', keys ' .. #keys)
	for _, key in ipairs(keys) do
		if key:sub(1, #MODIFIER) == MODIFIER then note('vanilla key ' .. key) end
	end
	local template = record_pointer(t, MODIFIER .. 'kills')
	check(template ~= nil, 'the vanilla key is the modifier and the source joined: ' .. MODIFIER .. 'kills')
	local before = snapshot(t, RECORD_SIZE)
	local before_count = mr.read_int32(t, RECORDS_AT + 4)
	note('template bytes ' .. hex(mr.read(template, 0, RECORD_SIZE)))
	local added = {}
	for _, row in ipairs(new_rows()) do
		local target = record_pointer(sources, row.source)
		if not target then
			check(false, 'source type record ' .. row.source)
		else
			local record, index = p:row(row.name, t, template, row.key, { [0x18] = target })
			check(record ~= nil, 'added ' .. row.key .. ' at row ' .. tostring(index))
			added[#added + 1] = { row = row, record = record, index = index, target = target }
		end
	end
	local after_count = mr.read_int32(t, RECORDS_AT + 4)
	check(after_count == before_count + #SOURCES, 'five more rows: ' .. before_count .. ' to ' .. after_count)
	local listed = keys_of(t)
	for _, entry in ipairs(added) do
		local found = false
		for _, key in ipairs(listed) do
			found = found or key == entry.row.key .. '=' .. entry.index
		end
		check(found, 'the key map lists ' .. entry.row.key .. '=' .. entry.index)
		local _, data = mr.read_array(t, RECORDS_AT)
		check(mr.eq(mr.read_pointer(data, entry.index * 8), entry.record), 'the records vector holds it at ' .. entry.index)
		check(mr.eq(mr.read_pointer(entry.record, 0x18), entry.target), 'its source pointer is the source type row')
		check(
			mr.eq(mr.read_pointer(entry.record, 8), mr.read_pointer(template, 8)) and mr.eq(mr.read_pointer(entry.record, 0), mr.read_pointer(template, 0)),
			'modifier pointer and vtable come from the template'
		)
		check(mr.is_null(mr.read_pointer(entry.record, 0x10)) == mr.is_null(mr.read_pointer(template, 0x10)), 'currency pointer as in the template')
		local info = p:info(entry.row.name)
		check(info.state == 'ours' and info.key == entry.row.key and info.row == entry.index, 'info says ours')
	end
	local repeated = p:row(new_rows()[1].name, t, template, new_rows()[1].key, { [0x18] = added[1].target })
	check(repeated ~= nil and mr.eq(repeated, added[1].record) and mr.read_int32(t, RECORDS_AT + 4) == after_count, 'calling again changes nothing')
	result.before = before
	result.while_added = snapshot(t, RECORD_SIZE)
	result.capacity = mr.read_uint32(t, RECORDS_AT)
	ROWS_BEFORE = before
elseif PHASE == 'remove' then
	local ok, removed, stayed = p:remove_all()
	check(ok == true and removed == #SOURCES and stayed == 0, 'remove_all took the rows back: ' .. tostring(removed))
	local now = snapshot(t, RECORD_SIZE)
	result.after = now
	check(#mr.patch_list(OWNER) == 0, 'nothing is listed')
	for _, row in ipairs(new_rows()) do
		check(mr.map_find_key(mr.add(t, KEYS_AT), row.key) == nil, row.key .. ' is gone')
	end
	result.capacity = mr.read_uint32(t, RECORDS_AT)
elseif PHASE == 'info' then
	local list = mr.patch_list(OWNER)
	check(#list == #SOURCES, 'the registry still lists five rows: ' .. #list)
	for _, row in ipairs(list) do
		check(row.kind == 'row' and row.state == 'ours', row.name .. ' is ours')
	end
	result.now = snapshot(t, RECORD_SIZE)
elseif PHASE == 'read' then
	result.now = snapshot(t, RECORD_SIZE)
	check(#mr.patch_list(OWNER) == 0, 'no rows listed')
end

result.passed = result.failed == 0
return result
