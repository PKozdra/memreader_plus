local BATCHES = 20

local function log(text)
	if ModLog then ModLog('[q5_load] ' .. text) end
end

local function run()
	if not _G.memreader_plus then return 'memreader_plus is not loaded at file scope' end
	local chunk = assert(loadfile('/script/q5/ingame_patcher'))
	setfenv(chunk, core:get_env())
	local q5 = chunk('module')
	local wrapped = q5.wrap_grow_frame()
	return wrapped .. ' | ' .. q5.load_batches(BATCHES)
end

local ok, result = pcall(run)
log(ok and result or ('stopped: ' .. tostring(result)))
