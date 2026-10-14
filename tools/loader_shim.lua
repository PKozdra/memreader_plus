local plus = _G.memreader_plus
if plus then
	_G.memreader = plus
	package.loaded['twwh3-memreader'] = plus
	package.loaded['twwh2-memreader'] = plus
	return plus
end

if _G.memreader_plus_release ~= nil then return nil end

local caller = debug.getinfo(2, 'f')
local boot = assert(loadfile('/script/_lib/mod/!memreader_plus_boot'))
if caller and caller.func then setfenv(boot, getfenv(caller.func)) end
local loaded = boot()
return loaded
