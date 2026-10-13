local guard = {}

local function numeric_locale(name)
	local ok, result = pcall(function()
		return os.setlocale(name, 'numeric')
	end)
	if ok and type(result) == 'string' then return result end
	return nil
end

local function with_c_numbers(run, ...)
	local before = numeric_locale(nil)
	if before == nil or before == 'C' then return run(...) end
	if numeric_locale('C') ~= 'C' then return run(...) end
	local ok, result = pcall(run, ...)
	numeric_locale(before)
	if not ok then error(result, 0) end
	return result
end

local function is_number_tail(text)
	return text:match('^%d+$') ~= nil or text:match('^%d+[eE][%+%-]?%d+$') ~= nil
end

local function repair_value(piece)
	return (
		piece:gsub('(%]=%-?%d+),([%deE%+%-]+)()', function(whole, tail, after)
			local next_text = piece:sub(after, after + 1)
			if not is_number_tail(tail) then return nil end
			if next_text:sub(1, 1) ~= '}' and next_text ~= ',[' then return nil end
			return whole .. '.' .. tail
		end)
	)
end

local function repair_key(piece)
	return (piece:gsub('([{,]%[%-?%d+),(%d+%]=)', '%1.%2'))
end

function guard.repair(text)
	local parts = {}
	local inside = false
	for piece, quote in text:gmatch('([^"]*)("?)') do
		if not inside then piece = repair_key(repair_value(piece)) end
		parts[#parts + 1] = piece .. quote
		if quote ~= '' then inside = not inside end
	end
	return table.concat(parts)
end

local function guard_saving(manager)
	local save = manager.saving_game
	manager.saving_game = function(self, context)
		with_c_numbers(save, self, context)
	end
end

local function guard_tables(manager)
	local serialise = manager.process_table_save
	if type(serialise) ~= 'function' then return end
	manager.process_table_save = function(self, tab)
		return with_c_numbers(serialise, self, tab)
	end
end

local function guard_loading(manager)
	local load_value = manager.load_named_value
	local load_string = manager.load_named_string
	local table_next = false
	manager.load_named_value = function(self, name, default, context, allow_nil)
		table_next = type(default) == 'table'
		local ok, result = pcall(load_value, self, name, default, context, allow_nil)
		table_next = false
		if not ok then error(result, 0) end
		return result
	end
	manager.load_named_string = function(self, name, default, context)
		local text = load_string(self, name, default, context)
		if not table_next then return text end
		table_next = false
		return type(text) == 'string' and guard.repair(text) or text
	end
end

function guard.install(manager)
	if type(manager) ~= 'table' or manager.numeric_locale_safe then return false end
	if type(os) ~= 'table' or type(os.setlocale) ~= 'function' then return false end
	if type(manager.saving_game) ~= 'function' or type(manager.load_named_value) ~= 'function' or type(manager.load_named_string) ~= 'function' then
		return false
	end
	manager.numeric_locale_safe = true
	guard_saving(manager)
	guard_tables(manager)
	guard_loading(manager)
	return true
end

return guard
