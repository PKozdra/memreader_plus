log_lines, sites_args = {}, {}

fake = {
	set_log = function() end,
	file_edit = function() end,
	file_edit_status = function()
		return { sites = {} }
	end,
	file_edit_list = function()
		return {}
	end,
	plus_version = 'test',
}

package.preload.fake_plus = function()
	return fake
end

io.open = function(_, mode)
	if mode == 'rb' then return nil end
	return { write = function() end, close = function() end }
end

function loadfile(path)
	if path == '/script/memreader_plus/bin' then
		return function()
			return { module = 'fake_plus', data = 'x' }
		end
	end
	if path == '/script/memreader_plus/agree' then return loadstring(AGREE_SOURCE, '@agree') end
	if path == '/script/memreader_plus/twui' then
		return function()
			return { edit = function() end }
		end
	end
	if path == '/script/memreader_plus/sites' then
		return function(...)
			sites_args = { ... }
			return { attach = function() end }
		end
	end
	return nil, 'missing ' .. path
end

function mod_log(text)
	log_lines[#log_lines + 1] = text
end
