local mr = _G.memreader_plus
local BAD_READ = '\72\184\97\0\32\0\116\0\111\0\72\139\0'
local SITES = {
	turn_number = { 0x2800000, 0x1ec84 },
	exit_cache = { 0x1e00000, 0x1034c },
	exit_crt = { 0x1000000, 0x165400 },
}

local probe = {}

local function arm(name)
	local at = mr.add(mr.add(mr.base, SITES[name][1]), SITES[name][2])
	local old = mr.read(at, 0, #BAD_READ)
	return mr.patch(at, old, BAD_READ) ~= nil
end

function probe.crash_now()
	arm('turn_number')
	return cm:model():turn_number()
end

function probe.arm_exit_crash()
	return arm('exit_cache')
end

function probe.arm_crt_exit_crash()
	return arm('exit_crt')
end

_G.crash_probe = probe
return 'loaded'
