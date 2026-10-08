local kind = SCENARIO:match('^crash_coverage_(.+)$')
local on_thread = kind:sub(-7) == '_thread'
if on_thread then kind = kind:sub(1, -8) end

io.stdout:setvbuf('no')
ModLog = function(msg)
	print('  log: ' .. msg)
end
local function read_file(path)
	local file = assert(io.open(path, 'rb'))
	local text = file:read('*a')
	file:close()
	return text
end
loadfile = function(path)
	if path:sub(1, 8) ~= '/script/' then return nil, 'not in VFS: ' .. path end
	local name = ROOT .. '/dist/pack' .. path
	if not name:match('%.lua$') then name = name .. '.lua' end
	return loadstring(read_file(name), '@' .. name)
end

assert(loadstring(read_file(ROOT .. '/dist/pack/script/_lib/mod/memreader_plus.lua'), '@loader'))()
if PASS == 1 then
	NEXT_PASS = true
	return
end
print('crash case ' .. kind .. (on_thread and ' on a worker thread' or ' on the script thread'))
test_fault(kind, on_thread)
print('did not crash')
os.exit(0)
