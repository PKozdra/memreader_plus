local FILE_NAME = 'memreader_plus_file_edits_off.txt'

local function switch_file_path()
	local screenshots = common and common.get_appdata_screenshots_path
	local folder = screenshots and screenshots()
	if type(folder) ~= 'string' or folder == '' then return nil end
	if string.match(folder, '[\128-\255]') then return FILE_NAME end
	folder = string.gsub(folder, 'screenshots[\\/]*$', '')
	if not string.match(folder, '[\\/]$') then folder = folder .. '\\' end
	return folder .. FILE_NAME
end

local switch = {}

function switch.saved_off()
	local path = switch_file_path()
	local file = path and io.open(path, 'rb')
	if not file then return false end
	file:close()
	return true
end

function switch.save(enabled)
	local path = switch_file_path()
	if not path then return end
	if enabled then
		os.remove(path)
		return
	end
	local file = io.open(path, 'wb')
	if not file then return end
	file:write('memreader Plus: the MCT option "File edits from mods" is off. Tick it in MCT to turn file edits back on.')
	file:close()
end

return switch
