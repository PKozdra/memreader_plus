local mr = _G.memreader_plus
local coverage = {}

local PAYLOADS = {
	av = '\72\139\4\37\16\0\0\0',
	fastfail = '\185\7\0\0\0\205\41',
	overflow = '\232\251\255\255\255',
}
local HANDLER = '48 89 5C 24 08 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 ?? ?? ?? ?? B8 ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 2B E0 45 33 E4 '
	.. '4C 8B F2 44 38 25 ?? ?? ?? ?? 8B D9 74 0A 48 83 C9 FF E8 ?? ?? ?? ?? CC B8 8D 00 00 C0'

local function export_address(name)
	local base = mr.base
	local headers = mr.add(base, mr.read_uint32(base, 0x3C, true))
	local directory = mr.add(base, mr.read_uint32(headers, 0x88, true))
	local count = mr.read_uint32(directory, 0x18)
	local functions = mr.add(base, mr.read_uint32(directory, 0x1C, true))
	local names = mr.add(base, mr.read_uint32(directory, 0x20, true))
	local ordinals = mr.add(base, mr.read_uint32(directory, 0x24, true))
	for i = 0, count - 1 do
		local at = mr.add(base, mr.read_uint32(names, i * 4, true))
		if mr.read(at, 0, #name + 1) == name .. '\0' then return mr.add(base, mr.read_uint32(functions, mr.read_uint16(ordinals, i * 2) * 4, true)) end
	end
	return nil
end

function coverage.arm(kind, export)
	local at = export_address(export)
	if not at then return 'no export ' .. export end
	local old = mr.read(at, 0, #PAYLOADS[kind])
	local ok = mr.patch(at, old, PAYLOADS[kind])
	return ok and 'armed ' .. kind .. ' in ' .. export or 'patch failed'
end

function coverage.trigger()
	coroutine.resume(coroutine.create(function() end))
	return 'did not crash'
end

function coverage.hooks()
	local at, count = mr.find_pattern(HANDLER)
	local jump = at and mr.read(at, 0, 1)
	local modules = 0
	for _ in pairs(mr.modules()) do
		modules = modules + 1
	end
	return {
		handler_matches = count,
		handler_first_byte = jump and jump:byte(1),
		plus_loaded = mr.plus_version,
		plus_dll_base = plus_dll,
	}
end

_G.crash_coverage = coverage
return 'loaded'
