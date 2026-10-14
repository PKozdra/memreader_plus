local function log(message)
	if type(ModLog) == 'function' then ModLog('[memreader_plus] ' .. message) end
end

local function newer(a, b)
	if a.major ~= b.major then return a.major > b.major end
	if a.minor ~= b.minor then return a.minor > b.minor end
	return a.patch > b.patch
end

local function list_markers()
	local lookup = common and common.filesystem_lookup
	if type(lookup) ~= 'function' then return nil, 'common.filesystem_lookup is missing' end
	local ok, found = pcall(lookup, '/script/memreader_plus/releases/', '*.lua')
	if not ok then return nil, 'listing the releases failed: ' .. tostring(found) end
	return tostring(found)
end

local function find_releases()
	local found, problem = list_markers()
	if not found then return nil, problem end
	local releases = {}
	local seen = {}
	for entry in string.gmatch(found, '[^,]+') do
		local name = string.match(entry, '[^/\\]+$') or ''
		local id, major, minor, patch = string.match(name, '^((%d+)_(%d+)_(%d+))%.lua$')
		if id and not seen[id] then
			seen[id] = true
			releases[#releases + 1] = { id = id, major = tonumber(major), minor = tonumber(minor), patch = tonumber(patch) }
		end
	end
	table.sort(releases, newer)
	return releases
end

local function id_list(releases)
	local ids = {}
	for index = #releases, 1, -1 do
		ids[#ids + 1] = releases[index].id
	end
	if #ids == 0 then return 'none' end
	return table.concat(ids, ', ')
end

local function load_newest(releases)
	for _, release in ipairs(releases) do
		local chunk, why = loadfile('/script/memreader_plus/' .. release.id .. '/loader')
		if chunk then return chunk, release.id end
		log(('release %s did not load (%s), trying the next lower one'):format(release.id, tostring(why)))
	end
	return nil
end

if _G.memreader_plus then return _G.memreader_plus end

local releases, problem = find_releases()
if not releases then
	log('not loaded: ' .. problem)
	return nil
end

local chunk, id = load_newest(releases)
if not chunk then
	log('not loaded: no release could be loaded, found: ' .. id_list(releases))
	return nil
end

log(('releases found: %s; loading %s'):format(id_list(releases), id))
local plus = chunk(ModLog, id)
return plus
