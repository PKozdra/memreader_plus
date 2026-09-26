if _G.memreader_plus then return _G.memreader_plus end

local function log(message)
	if type(ModLog) == 'function' then ModLog('[memreader_plus] ' .. message) end
end

local function load_dll()
	local chunk, load_error = loadfile('/script/memreader_plus/bin')
	if not chunk then return nil, 'bin.lua missing: ' .. tostring(load_error) end
	local bin = chunk()
	local filename = bin.module .. '.dll'

	local file = io.open(filename, 'rb')
	local existing = file and file:read('*a')
	if file then file:close() end
	if existing ~= bin.data then
		local output, open_error = io.open(filename, 'wb')
		if not output then return nil, 'cannot write ' .. filename .. ': ' .. tostring(open_error) end
		output:write(bin.data)
		output:close()
	end

	local ok, result = pcall(require, bin.module)
	if not ok then return nil, 'require ' .. bin.module .. ' failed: ' .. tostring(result) end
	return result
end

local memreader, load_error = load_dll()
if not memreader then
	log('not loaded: ' .. load_error)
	return nil
end

local replaced = _G.memreader ~= nil
package.loaded['twwh3-memreader'] = memreader
package.loaded['twwh2-memreader'] = memreader
_G.memreader = memreader
_G.memreader_plus = memreader

if replaced then
	log('loaded ' .. memreader.plus_version .. ', replaced another memreader in _G.memreader')
else
	log('loaded ' .. memreader.plus_version)
end
return memreader
