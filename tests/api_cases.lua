local STRING_HEADER = 0x18
local USERDATA_BODY = 0x28
local USERDATA_VALUE = 0x30

local cases = {}
local function case(name, run)
	cases[#cases + 1] = { name = name, run = run }
end

local function gc_pointer(mr, object)
	local _, pointer = mr.ud_debug(object)
	return pointer
end
local function string_address(mr, s)
	return mr.add(gc_pointer(mr, s), STRING_HEADER)
end
local function value_address(mr, v)
	return mr.add(gc_pointer(mr, v), USERDATA_VALUE)
end
local function pointer_bytes(mr, p)
	return mr.read(value_address(mr, mr.add(p, 0)), 0, 8)
end

local DOS_HEADER_SP = 0x10
local P = '\16\0\0\0\0\0\0\0'
local P2 = '\8\0\0\0\0\0\0\0'
local NULL = '\0\0\0\0\0\0\0\0'

case('version', function(mr)
	return mr.version
end)
case('type(nil)', function(mr)
	return mr.type(nil)
end)
case('type(true)', function(mr)
	return mr.type(true)
end)
case('type(1)', function(mr)
	return mr.type(1)
end)
case('type(x)', function(mr)
	return mr.type('x')
end)
case('type({})', function(mr)
	return mr.type({})
end)
case('tostring(nil)', function(mr)
	return mr.tostring(nil)
end)
case('tostring(true)', function(mr)
	return mr.tostring(true)
end)
case('tostring(1.5)', function(mr)
	return mr.tostring(1.5)
end)
case('tostring(bytes)', function(mr)
	return mr.tostring('ab\0\255')
end)
case('tostring(empty)', function(mr)
	return mr.tostring('')
end)
case('tostring({})', function(mr)
	return mr.tostring({})
end)

case('pointer(bytes)', function(mr)
	return mr.pointer(P)
end)
case('pointer(pointer)', function(mr)
	local p = mr.pointer(P)
	return rawequal(mr.pointer(p), p)
end)
case('pointer(123)', function(mr)
	return mr.pointer(123)
end)
case('uint8(200)', function(mr)
	return mr.uint8(200)
end)
case('uint8(300)', function(mr)
	return mr.uint8(300)
end)
case('int8(-5)', function(mr)
	return mr.int8(-5)
end)
case('uint16(65535)', function(mr)
	return mr.uint16(65535)
end)
case('int16(-300)', function(mr)
	return mr.int16(-300)
end)
case('uint32(4000000000)', function(mr)
	return mr.uint32(4000000000)
end)
case('int32(-7)', function(mr)
	return mr.int32(-7)
end)
case('uint32(bytes)', function(mr)
	return mr.uint32('\1\2\3\4')
end)
case('int32(bytes)', function(mr)
	return mr.int32('\255\255\255\255')
end)
case('uint8(bytes)', function(mr)
	return mr.uint8('\7')
end)
case('uint32(true)', function(mr)
	return mr.uint32(true)
end)

case('add(p,16)', function(mr)
	return mr.add(mr.pointer(P), 16)
end)
case('add(p,bytes)', function(mr)
	return mr.add(mr.pointer(P), '\16\0\0\0')
end)
case('add(p,uint8)', function(mr)
	return mr.add(mr.pointer(P), mr.uint8(3))
end)
case('add(p,p)', function(mr)
	return mr.add(mr.pointer(P), mr.pointer(P2))
end)
case('add(p,-16)', function(mr)
	return mr.add(mr.pointer(P), -16)
end)
case('sub(p,p2)', function(mr)
	return mr.sub(mr.pointer(P), mr.pointer(P2))
end)
case('sub(p,4)', function(mr)
	return mr.sub(mr.pointer(P), 4)
end)
case('div(p,2)', function(mr)
	return mr.div(mr.pointer(P), 2)
end)
case('mult(p,2)', function(mr)
	return mr.mult(mr.pointer(P), 2)
end)
case('add(5,6)', function(mr)
	return mr.add(5, 6)
end)
case('add(5,uint32)', function(mr)
	return mr.add(5, mr.uint32(3))
end)
case('div(7,2)', function(mr)
	return mr.div(7, 2)
end)
case('add(5,p)', function(mr)
	return mr.add(5, mr.pointer(P))
end)
case('add(nil,1)', function(mr)
	return mr.add(nil, 1)
end)
case('sub(uint16(1),2)', function(mr)
	return mr.sub(mr.uint16(1), 2)
end)
case('add(uint8(250),10)', function(mr)
	return mr.add(mr.uint8(250), 10)
end)
case('mult(int16(300),300)', function(mr)
	return mr.mult(mr.int16(300), 300)
end)
case('div(uint32(42),6)', function(mr)
	return mr.div(mr.uint32(42), 6)
end)
case('div(uint32(42),uint8)', function(mr)
	return mr.div(mr.uint32(42), mr.uint8(6))
end)
case('add(int32(-5),3)', function(mr)
	return mr.add(mr.int32(-5), 3)
end)
case('div(int32(-8),2)', function(mr)
	return mr.div(mr.int32(-8), 2)
end)
case('add(uint32,bytes)', function(mr)
	return mr.add(mr.uint32(1), '\2\0\0\0')
end)

case('eq(p,p)', function(mr)
	return mr.eq(mr.pointer(P), mr.pointer(P))
end)
case('eq(p,bytes)', function(mr)
	return mr.eq(mr.pointer(P), P)
end)
case('eq(null,bytes)', function(mr)
	return mr.eq(mr.pointer(NULL), NULL)
end)
case('eq(p,p2)', function(mr)
	return mr.eq(mr.pointer(P), mr.pointer(P2))
end)
case('gt(p,p2)', function(mr)
	return mr.gt(mr.pointer(P), mr.pointer(P2))
end)
case('lt(p,p2)', function(mr)
	return mr.lt(mr.pointer(P), mr.pointer(P2))
end)
case('eq(p,16)', function(mr)
	return mr.eq(mr.pointer(P), 16)
end)
case('lt(uint32(5),7)', function(mr)
	return mr.lt(mr.uint32(5), 7)
end)
case('eq(int32(5),bytes)', function(mr)
	return mr.eq(mr.int32(5), '\5\0\0\0')
end)
case('gt(uint32(10),uint32(3))', function(mr)
	return mr.gt(mr.uint32(10), mr.uint32(3))
end)
case('gt(uint8(5),1)', function(mr)
	return mr.gt(mr.uint8(5), 1)
end)
case('gt(int32(-1),5)', function(mr)
	return mr.gt(mr.int32(-1), 5)
end)
case('eq(5,p)', function(mr)
	return mr.eq(5, mr.pointer(P))
end)

case('tonumber(uint32)', function(mr)
	return mr.tonumber(mr.uint32(123))
end)
case('tonumber(int32(5))', function(mr)
	return mr.tonumber(mr.int32(5))
end)
case('tonumber(7.9)', function(mr)
	return mr.tonumber(7.9)
end)
case('tonumber(bytes)', function(mr)
	return mr.tonumber('\3\0\0\0')
end)
case('tonumber(nil)', function(mr)
	return mr.tonumber(nil)
end)
case('tonumber(p)', function(mr)
	return mr.tonumber(mr.pointer(P))
end)
case('tonumber(uint8)', function(mr)
	return mr.tonumber(mr.uint8(9))
end)
case('tonumber(int32(-1))', function(mr)
	return mr.tonumber(mr.int32(-1))
end)
case('createtable', function(mr)
	return type(mr.createtable(2, 3))
end)

case('read_uint8', function(mr)
	return mr.read_uint8(mr.base, 0)
end)
case('read_int8', function(mr)
	return mr.read_int8(mr.base, 0x3F)
end)
case('read_uint16', function(mr)
	return mr.read_uint16(mr.base)
end)
case('read_int16', function(mr)
	return mr.read_int16(mr.base, 1)
end)
case('read_uint32', function(mr)
	return mr.read_uint32(mr.base, DOS_HEADER_SP)
end)
case('read_int32', function(mr)
	return mr.read_int32(mr.base, DOS_HEADER_SP)
end)
case('read_uint8 ud', function(mr)
	return mr.read_uint8(mr.base, 0, true)
end)
case('read_int16 ud', function(mr)
	return mr.read_int16(mr.base, 0, true)
end)
case('read_uint32 ud', function(mr)
	return mr.read_uint32(mr.base, DOS_HEADER_SP, true)
end)
case('read_int32 ud', function(mr)
	return mr.read_int32(mr.base, DOS_HEADER_SP, true)
end)
case('read_float', function(mr)
	return mr.read_float(mr.base, 0x40)
end)
case('read_pointer', function(mr)
	return mr.read_pointer(mr.base, 0)
end)
case('read_boolean(1)', function(mr)
	return mr.read_boolean(mr.base, 0)
end)
case('read_boolean(0)', function(mr)
	return mr.read_boolean(mr.base, 0x3F)
end)
case('read(16)', function(mr)
	return mr.read(mr.base, 0, 16)
end)
case('read(0)', function(mr)
	return mr.read(mr.base, 2, 0)
end)
case('read(1023)', function(mr)
	return #mr.read(mr.base, 0, 1023)
end)
case('offset bytes', function(mr)
	return mr.read_uint16(mr.base, '\2\0\0\0')
end)
case('offset uint32', function(mr)
	return mr.read_uint16(mr.base, mr.uint32(2))
end)
case('offset uint8', function(mr)
	return mr.read_uint16(mr.base, mr.uint8(2))
end)
case('offset pointer', function(mr)
	return mr.read_uint16(mr.base, mr.pointer(P))
end)
case('read null', function(mr)
	return mr.read_pointer(mr.pointer(NULL))
end)
case('read number address', function(mr)
	return mr.read_uint8(5)
end)

case('read_string', function(mr)
	local data = 'hello'
	local s = '\5\0\0\0\5\0\0\0' .. pointer_bytes(mr, string_address(mr, data))
	return mr.read_string(string_address(mr, s), 0)
end)
case('read_string isPtr', function(mr)
	local data = 'hello'
	local s = '\5\0\0\0\5\0\0\0' .. pointer_bytes(mr, string_address(mr, data))
	local outer = pointer_bytes(mr, string_address(mr, s))
	return mr.read_string(string_address(mr, outer), 0, true)
end)
case('read_string wide', function(mr)
	local data = 'h\0i\0'
	local s = '\2\0\0\0\2\0\0\0' .. pointer_bytes(mr, string_address(mr, data))
	return mr.read_string(string_address(mr, s), 0, false, true)
end)
case('read_string empty', function(mr)
	return mr.read_string(string_address(mr, '\0\0\0\0\0\0\0\0' .. NULL), 0)
end)
case('read_array', function(mr)
	local data = 'abcdef'
	local s = '\9\0\0\0\3\0\0\0' .. pointer_bytes(mr, string_address(mr, data))
	local size, pointer = mr.read_array(string_address(mr, s))
	return size, mr.eq(pointer, pointer_bytes(mr, string_address(mr, data)))
end)
case('read_array ud', function(mr)
	local s = '\9\0\0\0\3\0\0\0' .. NULL
	local size = mr.read_array(string_address(mr, s), 0, true)
	return size
end)
case('read_array empty', function(mr)
	return mr.read_array(string_address(mr, '\0\0\0\0\0\0\0\0' .. P))
end)
case('read_rowidx', function(mr)
	local rows = string.rep('r', 64)
	local base = string_address(mr, rows)
	local s = pointer_bytes(mr, mr.add(base, 32))
	return mr.read_rowidx(string_address(mr, s), 0, base, 16)
end)

case('write uint32', function(mr)
	local box = mr.uint32(0)
	mr.write(value_address(mr, box), 0, mr.uint32(77))
	return box
end)
case('write uint8', function(mr)
	local box = mr.uint32(0x01010101)
	mr.write(value_address(mr, box), 0, mr.uint8(5))
	return box
end)
case('write pointer', function(mr)
	local box = mr.pointer(NULL)
	mr.write(value_address(mr, box), 0, mr.pointer(P))
	return box
end)
case('write offset', function(mr)
	local box = mr.uint32(0)
	mr.write(value_address(mr, box), 1, mr.uint8(1))
	return box
end)

case('write negative offset', function(mr)
	local box = mr.uint32(0)
	mr.write(mr.add(value_address(mr, box), 2), -1, mr.uint8(1))
	return box
end)
case('write read-only page', function(mr)
	mr.write(mr.base, 0, 'MZ')
	return mr.read(mr.base, 0, 2)
end)

case('modules', function(mr)
	for m in mr.modules() do
		return m.name, mr.eq(m.base, mr.base), type(m.size), type(m.path)
	end
end)
case('type(modules entry)', function(mr)
	for m in mr.modules() do
		return type(m)
	end
end)
case('ud_topointer', function(mr)
	local p = mr.ud_topointer(io.stdout)
	return mr.eq(p, mr.read_pointer(mr.add(gc_pointer(mr, io.stdout), USERDATA_BODY), 0)), mr.eq(p, mr.pointer(NULL))
end)
case('ud_debug', function(mr)
	local t = mr.ud_debug(mr.pointer(P))
	return t
end)

local fix_cases = {}
local function fix(name, run)
	fix_cases[#fix_cases + 1] = { name = name, run = run }
end
fix('read(2048)', function(mr)
	return #mr.read(mr.base, 0, 2048)
end)
fix('read_string long', function(mr)
	local data = string.rep('x', 1500)
	local s = '\220\5\0\0\220\5\0\0' .. pointer_bytes(mr, string_address(mr, data))
	return #mr.read_string(string_address(mr, s), 0)
end)
fix('write boolean', function(mr)
	local box = mr.uint32(0x01010100)
	mr.write(value_address(mr, box), 0, true)
	return box
end)
fix('write number', function(mr)
	local box = mr.uint32(0)
	mr.write(value_address(mr, box), 0, 1.5)
	return box
end)
fix('write bytes', function(mr)
	local box = mr.uint32(0)
	mr.write(value_address(mr, box), 0, '\1\2')
	return box
end)
fix('write nil', function(mr)
	return mr.write(mr.base, 0, nil)
end)
fix('div(uint32,0)', function(mr)
	return mr.div(mr.uint32(1), 0)
end)
fix('ud_topointer(5)', function(mr)
	return mr.ud_topointer(5)
end)
fix('ud_topointer(value)', function(mr)
	return mr.ud_topointer(mr.uint32(1))
end)
fix('read_string inline', function(mr)
	local s = 'hello' .. string.rep('\0', 10) .. '\133'
	return mr.read_string(string_address(mr, s), 0)
end)
fix('read_string inline 15', function(mr)
	local s = 'abcdefghijklmno\143'
	return mr.read_string(string_address(mr, s), 0)
end)
fix('read_string inline wide', function(mr)
	local s = 'h\0i\0' .. string.rep('\0', 11) .. '\130'
	return mr.read_string(string_address(mr, s), 0, false, true)
end)
fix('read_string inline wide too long', function(mr)
	local s = string.rep('\0', 15) .. '\143'
	return mr.read_string(string_address(mr, s), 0, false, true)
end)
fix('read_string pointer to inline', function(mr)
	local s = 'hi' .. string.rep('\0', 13) .. '\130'
	local holder = pointer_bytes(mr, string_address(mr, s))
	return mr.read_string(string_address(mr, holder), 0, true)
end)
fix('read_unistring inline', function(mr)
	local s = 'h\0i\0' .. string.rep('\0', 11) .. '\130'
	return mr.read_unistring(string_address(mr, s), 0)
end)
fix('read_unistring heap', function(mr)
	local text = 'A\1\243\0d\0z\1'
	local s = '\4\0\0\0\4\0\0\0' .. pointer_bytes(mr, string_address(mr, text))
	return mr.read_unistring(string_address(mr, s), 0)
end)
fix('read_unistring empty', function(mr)
	local s = '\0\0\0\0\0\0\0\0' .. NULL
	return mr.read_unistring(string_address(mr, s), 0)
end)
fix('is_null(null forms)', function(mr)
	return mr.is_null(nil), mr.is_null(), mr.is_null(mr.pointer(NULL)), mr.is_null(NULL), mr.is_null(0), mr.is_null(mr.uint8(0))
end)
fix('is_null(non-null forms)', function(mr)
	return mr.is_null(mr.pointer(P)), mr.is_null(P), mr.is_null(5), mr.is_null(mr.int32(-1)), mr.is_null(mr.base)
end)
fix('is_null(table)', function(mr)
	return mr.is_null({})
end)
fix('div(min pointer,-1)', function(mr)
	return mr.div(mr.pointer('\0\0\0\0\0\0\0\128'), -1)
end)
fix('read(nan)', function(mr)
	return mr.read(mr.base, 0, 0 / 0)
end)
fix('read(32 MiB)', function(mr)
	return mr.read(mr.base, 0, 32 * 1024 * 1024)
end)
fix('read_string garbage length', function(mr)
	local s = '\255\255\255\127\0\0\0\0' .. P
	return mr.read_string(string_address(mr, s), 0)
end)
fix('createtable(1e9)', function(mr)
	return type(mr.createtable(1e9, 1e9))
end)
fix('read_rowidx above 16 MiB', function(mr)
	local s = '\5\0\0\1\0\0\0\0'
	return mr.read_rowidx(string_address(mr, s), 0, mr.pointer(NULL), 3)
end)
fix('read_rowidx(size 0)', function(mr)
	local s = '\5\0\0\1\0\0\0\0'
	return mr.read_rowidx(string_address(mr, s), 0, mr.pointer(NULL), 0)
end)
fix('ud_topointer(empty userdata)', function(mr)
	return mr.ud_topointer(newproxy())
end)
fix('ud_debug()', function(mr)
	return mr.ud_debug()
end)

local function entry_point(mr)
	local headers = mr.read_int32(mr.base, 0x3C)
	return mr.add(mr.base, mr.read_uint32(mr.base, headers + 0x28, true))
end
local function hex_pattern(bytes)
	local parts = {}
	for i = 1, #bytes do
		parts[i] = string.format('%02X', bytes:byte(i))
	end
	parts[2] = '??'
	return table.concat(parts, ' ')
end
fix('find_pattern(entry point)', function(mr)
	local entry = entry_point(mr)
	local address, count = mr.find_pattern(hex_pattern(mr.read(entry, 0, 24)))
	return mr.eq(address, entry), count
end)
fix('find_pattern(missing)', function(mr)
	return mr.find_pattern('DE AD BE EF 0F 1E 2D 3C 4B 5A 69 78 87 96 A5 B4')
end)
fix('find_pattern(?? first)', function(mr)
	return mr.find_pattern('?? 01')
end)
fix('find_pattern(bad hex)', function(mr)
	return mr.find_pattern('B9 1')
end)
fix('find_pattern(too long)', function(mr)
	return mr.find_pattern('90' .. string.rep(' ??', 256))
end)
local PAGE_SIZE = 4096
local PAGE_EXECUTE_READWRITE = 0x40
fix('find_pattern across a protection change', function(mr)
	local headers = mr.read_int32(mr.base, 0x3C)
	local first_section = headers + 0x18 + mr.read_uint16(mr.base, headers + 0x14)
	local page = mr.add(mr.base, mr.read_uint32(mr.base, first_section + 0x0C) + PAGE_SIZE)
	local pattern = hex_pattern(mr.read(mr.add(page, -8), 0, 16))
	local address, count = mr.find_pattern(pattern)
	local old = test_protect(pointer_bytes(mr, page), PAGE_SIZE, PAGE_EXECUTE_READWRITE)
	local split_address, split_count = mr.find_pattern(pattern .. ' ')
	test_protect(pointer_bytes(mr, page), PAGE_SIZE, old)
	return count > 0 and split_count == count, mr.eq(split_address, address)
end)
fix('find_patterns across a protection change', function(mr)
	local headers = mr.read_int32(mr.base, 0x3C)
	local first_section = headers + 0x18 + mr.read_uint16(mr.base, headers + 0x14)
	local page = mr.add(mr.base, mr.read_uint32(mr.base, first_section + 0x0C) + PAGE_SIZE)
	local pattern = hex_pattern(mr.read(mr.add(page, -8), 0, 16))
	local before = mr.find_patterns({ pattern })
	local old = test_protect(pointer_bytes(mr, page), PAGE_SIZE, PAGE_EXECUTE_READWRITE)
	local split, counts = mr.find_patterns({ pattern .. ' ' })
	test_protect(pointer_bytes(mr, page), PAGE_SIZE, old)
	return counts[1] > 0, mr.eq(split[1], before[1])
end)
fix('find_patterns agrees with a plain search', function(mr)
	local headers = mr.read_int32(mr.base, 0x3C)
	local first_section = headers + 0x18 + mr.read_uint16(mr.base, headers + 0x14)
	local start = mr.add(mr.base, mr.read_uint32(mr.base, first_section + 0x0C))
	local code = mr.read(start, 0, mr.read_uint32(mr.base, first_section + 0x08))
	local function exact(bytes)
		return (bytes
			:gsub('.', function(char)
				return string.format('%02X ', char:byte())
			end)
			:gsub(' $', ''))
	end
	local function plain_count(bytes)
		local count, at = 0, 1
		while true do
			at = string.find(code, bytes, at, true)
			if not at then return count end
			count, at = count + 1, at + 1
		end
	end
	local samples = { code:sub(1, 24), code:sub(-5), code:sub(-2), '\195\204\204' }
	local patterns = {}
	for i, bytes in ipairs(samples) do
		patterns[i] = exact(bytes)
	end
	local _, counts = mr.find_patterns(patterns)
	for i, bytes in ipairs(samples) do
		local single = select(2, mr.find_pattern(patterns[i]))
		if counts[i] ~= plain_count(bytes) or single ~= counts[i] then return false, i, counts[i], plain_count(bytes), single end
	end
	return true
end)

local function inline(text)
	return text .. string.rep('\0', 15 - #text) .. string.char(0x80 + #text)
end
local function vector_bytes(mr, size, data)
	local count = string.char(size % 256, math.floor(size / 256) % 256, 0, 0)
	return count .. count .. (data and pointer_bytes(mr, string_address(mr, data)) or NULL)
end
local function make_list(mr, size, broken, tag)
	local header = string.char(size) .. string.rep(tag, 23)
	local first = string.rep(tag .. '1', 8) .. '\7\0\0\0'
	local second = string.rep(tag .. '2', 8) .. '\9\0\0\0'
	local h, a, b = string_address(mr, header), string_address(mr, first), string_address(mr, second)
	mr.write(h, 1, '\0\0\0\0\0\0\0')
	mr.write(h, 8, b)
	mr.write(h, 16, a)
	mr.write(a, 0, mr.pointer(NULL))
	mr.write(a, 8, b)
	mr.write(b, 0, broken and mr.pointer(NULL) or a)
	mr.write(b, 8, mr.add(h, 8))
	return h, { header, first, second }
end

fix('read unmapped', function(mr)
	return mr.read_uint32(mr.pointer(P), 0)
end)
fix('read of a guard page', function(mr)
	local page = test_guard_page()
	local first = pcall(mr.read_uint32, page, 0)
	local second = pcall(mr.read_uint32, page, 0)
	return first, second, test_is_guarded(page)
end)
fix('read_int64/uint64/double', function(mr)
	local s = '\254\255\255\255\255\255\255\255' .. string.rep('\255', 8) .. '\0\0\0\0\0\0\4\64'
	local a = string_address(mr, s)
	return mr.read_int64(a, 0), mr.read_uint64(a, 8), mr.read_double(a, 16), mr.gt(mr.read_uint64(a, 8), 1)
end)
fix('int64/uint64 constructors', function(mr)
	return mr.int64(-5), mr.uint64(string.rep('\255', 8)), mr.type(mr.int64(1))
end)
fix('div(uint64 max,2)', function(mr)
	return mr.div(mr.uint64(string.rep('\255', 8)), 2)
end)
fix('div(int64,uint64 max)', function(mr)
	return mr.div(mr.int64(10), mr.uint64(string.rep('\255', 8)))
end)
fix('add(float,uint64 max)', function(mr)
	return mr.add(5, mr.uint64(string.rep('\255', 8))) > 1e19
end)
fix('64-bit values and 8 bytes', function(mr)
	local high = '\0\0\0\0\1\0\0\0'
	return mr.eq(mr.uint64(high), high), mr.add(mr.int64(0), high)
end)
fix('exact values are shared', function(mr)
	local s = '\135\214\18\0'
	local a = mr.uint32(1234567)
	local b = mr.read_uint32(string_address(mr, s), 0, true)
	local keyed = { [a] = 'hit' }
	return a == b, keyed[b], mr.read_pointer(mr.base, 0) == mr.read_pointer(mr.base, 0), mr.add(mr.base, 8) == mr.add(mr.base, 8)
end)
fix('shared value after a write into it', function(mr)
	local box = mr.uint32(4242)
	mr.write(value_address(mr, box), 0, mr.uint32(4343))
	return mr.uint32(4242), rawequal(box, mr.uint32(4242))
end)
fix('is_null(false)', function(mr)
	return mr.is_null(false)
end)
fix('read_struct scalars', function(mr)
	local s = '\1\0\0\0\0\0\192\63\255\1\0\0\0\0\0\0' .. inline('hi')
	local a = string_address(mr, s)
	local r = mr.read_struct(a, 0, {
		a = { 0, 'uint32' },
		b = { 4, 'float' },
		c = { 8, 'int8' },
		d = { 9, 'boolean' },
		e = { 16, 'string' },
		f = { 0, 'uint32', true },
		g = { 4, 'address' },
	})
	return r.a, r.b, r.c, r.d, r.e, r.f, mr.eq(r.g, mr.add(a, 4))
end)
fix('read_struct pointers', function(mr)
	local target = inline('ptr')
	local holder = pointer_bytes(mr, string_address(mr, target)) .. NULL
	local r = mr.read_struct(string_address(mr, holder), 0, {
		text = { 0, 'pointer', { 0, 'string' } },
		empty = { 8, 'pointer' },
		empty_text = { 8, 'pointer', { 0, 'string' } },
		raw = { 0, 'pointer' },
	})
	return r.text, r.empty, r.empty_text, mr.eq(r.raw, string_address(mr, target))
end)
fix('read_vector structs', function(mr)
	local data = '\1\0\0\0\10\0\0\0\2\0\0\0\20\0\0\0\3\0\0\0\226\255\255\255'
	local header = vector_bytes(mr, 3, data)
	local element = { 0, 'struct', { id = { 0, 'uint32' }, v = { 4, 'int32' } } }
	local t = mr.read_vector(string_address(mr, header), 0, element, 8)
	return #t, t[1].id, t[2].v, t[3].v
end)
fix('read_vector pointers with NULL', function(mr)
	local first, last = inline('va'), inline('vb')
	local data = pointer_bytes(mr, string_address(mr, first)) .. NULL .. pointer_bytes(mr, string_address(mr, last))
	local header = vector_bytes(mr, 3, data)
	local t = mr.read_vector(string_address(mr, header), 0, { 0, 'pointer', { 0, 'string' } }, 8)
	return #t, t[1], t[2], t[3]
end)
fix('read_vector nested and empty', function(mr)
	local one, two = '\7\0\0\0', '\8\0\0\0\9\0\0\0'
	local elements = vector_bytes(mr, 1, one) .. vector_bytes(mr, 2, two)
	local outer = vector_bytes(mr, 2, elements)
	local empty = vector_bytes(mr, 0, nil)
	local t = mr.read_vector(string_address(mr, outer), 0, { 0, 'vector', { 0, 'int32' }, 4 }, 16)
	return #t, #t[1], t[1][1], #t[2], t[2][2], #mr.read_vector(string_address(mr, empty), 0, { 0, 'int32' }, 4)
end)
fix('read_vector element budget', function(mr)
	local header = '\0\0\0\0\1\0\2\0' .. NULL
	return mr.read_vector(string_address(mr, header), 0, { 0, 'uint8' }, 1)
end)
fix('read_vector missing stride', function(mr)
	return mr.read_vector(mr.base, 0, { 0, 'uint8' })
end)
fix('read_list', function(mr)
	local h, keep = make_list(mr, 2, false, 'A')
	local t = mr.read_list(h, 0, { 0x10, 'uint32' })
	return #t, t[1], t[2], #keep
end)
fix('read_list broken link', function(mr)
	local h, keep = make_list(mr, 2, true, 'B')
	return mr.read_list(h, 0, { 0x10, 'uint32' }), keep
end)
fix('read_list wrong size', function(mr)
	local h, keep = make_list(mr, 3, false, 'C')
	return mr.read_list(h, 0, { 0x10, 'uint32' }), keep
end)
fix('read_struct self-reference', function(mr)
	local cell = string.rep('\5', 8)
	local a = string_address(mr, cell)
	mr.write(a, 0, a)
	local node = {}
	node.next = { 0, 'pointer', { 0, 'struct', node } }
	local ok, err = pcall(mr.read_struct, a, 0, node)
	return ok, err:match('nested deeper than 16$') ~= nil
end)
fix('read_struct struct budget', function(mr)
	local layout = { v = { 0, 'uint8' } }
	for _ = 1, 11 do
		layout = { a = { 0, 'struct', layout }, b = { 0, 'struct', layout }, c = { 0, 'struct', layout } }
	end
	local ok, err = pcall(mr.read_struct, mr.base, 0, layout)
	return ok, err:match('more than 131072 structs in one read$') ~= nil
end)
fix('read_struct error path', function(mr)
	local header = vector_bytes(mr, 1, P)
	local layout = { items = { 0, 'vector', { 0, 'pointer', { 0, 'uint32' } }, 8 } }
	return mr.read_struct(string_address(mr, header), 0, layout)
end)
fix('read_struct unknown type', function(mr)
	return mr.read_struct(mr.base, 0, { a = { 0, 'uint33' } })
end)
fix('read_struct bad third value', function(mr)
	return mr.read_struct(mr.base, 0, { a = { 0, 'string', true } })
end)
fix('read_struct bad offset', function(mr)
	return mr.read_struct(mr.base, 0, { a = { -1, 'uint8' } })
end)
fix('read_chain', function(mr)
	local second = NULL .. 'chain2'
	local first = pointer_bytes(mr, string_address(mr, second)) .. 'chain1'
	local a = string_address(mr, first)
	return mr.eq(mr.read_chain(a, 0), string_address(mr, second)), mr.read_chain(a, 0, 0), mr.read_chain(nil, 0), mr.read_chain(mr.pointer(NULL), 0), 'end'
end)
fix('read_chain big number offset', function(mr)
	return mr.read_chain(mr.base, 2 ^ 25)
end)
fix('read_chain unreadable', function(mr)
	return mr.read_chain(mr.pointer(P), 0)
end)

local function test_address(mr, name)
	return mr.pointer(test_function(name))
end
fix('call integers', function(mr)
	return mr.call(test_address(mr, 'add_integers'), 'int64(int64, int32, uint8)', mr.int64(-10), -5, 3)
end)
fix('call pointer', function(mr)
	local p = mr.call(test_address(mr, 'pointer_plus'), 'pointer(pointer, int64)', mr.base, 2)
	return mr.eq(p, mr.add(mr.base, 2)), mr.call(test_address(mr, 'pointer_plus'), 'pointer(pointer, int64)', nil, 16)
end)
fix('call floats and doubles', function(mr)
	return mr.call(test_address(mr, 'multiply_floats'), 'float(float, float)', 1.5, 2.5),
		mr.call(test_address(mr, 'add_doubles'), 'double(double, double)', 0.25, 0.5)
end)
fix('call mixed registers', function(mr)
	local forty = '\40\0\0\0'
	return mr.call(test_address(mr, 'mix'), 'double(int32, float, double, pointer)', 2, 0.5, 0.25, string_address(mr, forty))
end)
fix('call stack arguments', function(mr)
	local signature = 'int64(int64, int64, int64, int64, int64, int64, int64, int64)'
	return mr.call(test_address(mr, 'eight_digits'), signature, 1, 2, 3, 4, 5, 6, 7, 8)
end)
fix('call mixed stack arguments', function(mr)
	local signature = 'double(int32, double, int32, float, int32, double, float, int8)'
	return mr.call(test_address(mr, 'mixed_stack'), signature, 1, 2, 3, 4, 5, 6, 7, 8)
end)
fix('call 16 arguments', function(mr)
	local signature = 'int64(' .. string.rep('int64, ', 15) .. 'int64)'
	return mr.call(test_address(mr, 'sixteen'), signature, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
end)
fix('call 17 arguments', function(mr)
	return mr.call(test_address(mr, 'sixteen'), 'int64(' .. string.rep('int64, ', 16) .. 'int64)')
end)
fix('call booleans', function(mr)
	local positive, choose = test_address(mr, 'is_positive'), test_address(mr, 'from_boolean')
	return mr.call(positive, 'boolean(int32)', 5),
		mr.call(positive, 'boolean(int32)', -5),
		mr.call(choose, 'int32(boolean)', true),
		mr.call(choose, 'int32(boolean)', false)
end)
fix('call result types', function(mr)
	local f = test_address(mr, 'all_bits')
	return mr.call(f, 'uint8()'), mr.call(f, 'int8()'), mr.call(f, 'int32()'), mr.call(f, 'uint64()'), mr.call(f, 'pointer()')
end)
fix('call void with alloc', function(mr)
	local p = mr.alloc(4)
	local results = select('#', mr.call(test_address(mr, 'store'), 'void(pointer, int32)', p, -9))
	return mr.read_int32(p, 0), results
end)
fix('call varargs', function(mr)
	local out, text = mr.alloc(32), mr.alloc(16)
	mr.write(text, 0, '%d %.2f')
	local signature = 'int32(pointer, uint64, pointer, int32, double)'
	local length = mr.call(test_address(mr, 'format'), signature, out, 32, text, 7, 2.5)
	return length, mr.read(out, 0, 7)
end)
fix('call crash', function(mr)
	local ok, err = pcall(mr.call, test_address(mr, 'read_null'), 'int32()')
	return ok,
		err:match('the called function crashed at %x+ %(access violation at 0000000000000010%); the game may be unstable now$') ~= nil,
		mr.call(test_address(mr, 'is_positive'), 'boolean(int32)', 1)
end)
fix('call outside the exe', function(mr)
	local ok, err = pcall(mr.call, mr.pointer(P), 'void()')
	return ok, err == "bad argument #1 to '?' (refused: call takes only code in the game's exe or a hook's original)"
end)
fix('call Lua error inside', function(mr)
	local ok, err = pcall(mr.call, test_address(mr, 'raise_lua_error'), 'void(pointer)', mr.pointer(test_state()))
	return ok, err == 'raised inside a called function', mr.call(test_address(mr, 'is_positive'), 'boolean(int32)', 1)
end)
fix('call unknown type', function(mr)
	return mr.call(mr.base, 'int(pointer)')
end)
fix('call no parentheses', function(mr)
	return mr.call(mr.base, 'int32')
end)
fix('call void argument', function(mr)
	return mr.call(mr.base, 'int32(void)')
end)
fix('call text after signature', function(mr)
	return mr.call(mr.base, 'int32() x')
end)
fix('call argument count', function(mr)
	return mr.call(test_address(mr, 'add_doubles'), 'double(double, double)', 1)
end)
fix('call argument type', function(mr)
	return mr.call(test_address(mr, 'add_doubles'), 'double(double, double)', 'x', 1)
end)
fix('call NULL', function(mr)
	return mr.call(mr.pointer(NULL), 'void()')
end)
fix('call exact integers', function(mr)
	local echo = test_address(mr, 'echo_int64')
	local hash = '\109\123\24\97'
	return mr.call(echo, 'int64(int64)', 16777215),
		mr.call(echo, 'int64(int64)', -16777215),
		mr.call(echo, 'int64(int64)', mr.int64(hash .. '\0\0\0\0')),
		mr.call(test_address(mr, 'echo_raw'), 'uint64(uint32)', hash)
end)
fix('call integer from 2^24', function(mr)
	return mr.call(test_address(mr, 'echo_int64'), 'int64(int64)', 16777216)
end)
fix('call integer hash as number', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'uint64(uint32)', 0x61187b6d)
end)
fix('call integer not whole', function(mr)
	return mr.call(test_address(mr, 'echo_int64'), 'int64(int64)', 1.9)
end)
fix('call integer NaN and inf', function(mr)
	local echo = test_address(mr, 'echo_int64')
	local _, nan = pcall(mr.call, echo, 'int64(int64)', 0 / 0)
	local _, inf = pcall(mr.call, echo, 'int64(int64)', -1 / 0)
	local _, big = pcall(mr.call, echo, 'int64(int64)', 16777216)
	return nan == big, inf == big
end)
fix('call small integer edges', function(mr)
	local echo = test_address(mr, 'echo_raw')
	return mr.call(echo, 'uint64(uint8)', 255),
		mr.call(echo, 'uint64(int8)', -128),
		mr.call(echo, 'uint64(uint16)', 65535),
		mr.call(echo, 'uint64(int16)', -32768),
		mr.call(echo, 'uint64(uint32)', 0)
end)
fix('call uint8 300', function(mr)
	return mr.call(test_address(mr, 'echo_uint8'), 'uint32(uint8)', 300)
end)
fix('call int8 -129', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'uint64(int8)', -129)
end)
fix('call uint32 -1', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'uint64(uint32)', -1)
end)
fix('call typed values are narrowed', function(mr)
	local echo = test_address(mr, 'echo_raw')
	return mr.call(echo, 'uint64(uint8)', mr.uint32(300)),
		mr.call(echo, 'uint64(int8)', mr.int32(255)),
		mr.call(echo, 'uint64(uint32)', mr.int64(-1)),
		mr.call(echo, 'uint64(uint8)', '\44\1'),
		mr.call(echo, 'uint64(int16)', '\255\255')
end)
fix('call pointer forms', function(mr)
	local echo = test_address(mr, 'echo_raw')
	return mr.call(echo, 'uint64(pointer)', P), mr.call(echo, 'uint64(pointer)', nil)
end)
fix('call pointer as text', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'uint64(pointer)', 'hello')
end)
fix('call pointer as integer value', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'uint64(pointer)', mr.int64(5))
end)
fix('call address as text', function(mr)
	return mr.call('hello', 'void()')
end)
fix('call stack alignment', function(mr)
	return mr.call(test_address(mr, 'stack_misalignment'), 'uint64()'),
		mr.call(test_address(mr, 'stack_misalignment_5'), 'uint64(int64, int64, int64, int64, int64)', 1, 2, 3, 4, 5)
end)
local function crash(mr, name, signature, ...)
	local ok, err = pcall(mr.call, test_address(mr, name), signature, ...)
	error(ok and 'no crash' or (err:gsub('^the called function crashed at %x+', 'the called function crashed at <code>')), 0)
end
fix('call breakpoint', function(mr)
	crash(mr, 'breakpoint', 'void()')
end)
fix('call illegal instruction', function(mr)
	crash(mr, 'illegal_instruction', 'void()')
end)
fix('call division by zero', function(mr)
	crash(mr, 'divide', 'int32(int32, int32)', 1, 0)
end)
fix('call exceptions handled inside', function(mr)
	return mr.call(test_address(mr, 'handle_own_exception'), 'int32()'), mr.call(test_address(mr, 'throw_and_catch'), 'int32()')
end)
fix('call nested callbacks', function(mr)
	local state, callback = mr.pointer(test_state()), test_address(mr, 'callback')
	local depth, fail_at_bottom, reference = 0, false, nil
	reference = test_ref(function()
		depth = depth + 1
		mr.alloc(128)
		collectgarbage('collect')
		if depth < 5 then return mr.tonumber(mr.call(callback, 'int64(pointer, int32)', state, reference)) + 1 end
		if fail_at_bottom then error('deep error', 0) end
		return 10
	end)
	local sum = mr.call(callback, 'int64(pointer, int32)', state, reference)
	depth, fail_at_bottom = 0, true
	local ok, err = pcall(mr.call, callback, 'int64(pointer, int32)', state, reference)
	return sum, ok, err == 'deep error', mr.call(test_address(mr, 'is_positive'), 'boolean(int32)', 1)
end)
fix('call signature with tabs', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'uint64(\tuint64\t)\t', 7)
end)
fix('call upper case type', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'UINT64(uint64)', 7)
end)
fix('call Ghidra types', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'undefined8(longlong)', 7)
end)
fix('call char*', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'uint64(char*)', 7)
end)
fix('call trailing comma', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'uint64(uint64,)', 7)
end)
fix('call 16 arguments and trailing comma', function(mr)
	return mr.call(test_address(mr, 'sixteen'), 'int64(' .. string.rep('int64, ', 16) .. ')')
end)
fix('call empty signature', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), '')
end)
fix('call missing comma', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'uint64(uint64 uint64)', 7, 7)
end)
fix('call one argument missing', function(mr)
	return mr.call(test_address(mr, 'echo_raw'), 'uint64(uint64)')
end)
local HOOK_TARGET = 'int32(int32, int32)'
fix('hook unhook then error', function(mr)
	local target = test_address(mr, 'hook_target')
	local callback
	callback = function()
		mr.unhook(target, callback)
		error('fails after unhook')
	end
	mr.hook(target, HOOK_TARGET, callback)
	return mr.call(target, HOOK_TARGET, 1, 2), mr.hook_info(target).attached
end)
fix('unhook with a match count', function(mr)
	local target = test_address(mr, 'hook_target')
	mr.hook(target, HOOK_TARGET, function()
		return 7
	end)
	local ok, err = pcall(mr.unhook, target, 1)
	local still = mr.hook_info(target).attached
	mr.unhook(target)
	return ok, err:match('function expected, got number') ~= nil, still, mr.hook_info(target).attached
end)
fix('hook signature while running', function(mr)
	local target = test_address(mr, 'hook_target')
	local ok, err
	mr.hook(target, HOOK_TARGET, function()
		mr.unhook(target)
		ok, err = pcall(mr.hook, target, 'int32(int32)', function() end)
		return 7
	end)
	return mr.call(target, HOOK_TARGET, 1, 2), ok, err:match('different signature$') ~= nil
end)
fix('hook_next then error', function(mr)
	local target = test_address(mr, 'hook_target')
	local lower_calls = 0
	mr.hook(target, HOOK_TARGET, function(a, b)
		lower_calls = lower_calls + 1
		return mr.hook_next(target, a, b)
	end)
	mr.hook(target, HOOK_TARGET, function(a, b)
		mr.hook_next(target, a, b)
		error('fails after hook_next')
	end)
	local result = mr.call(target, HOOK_TARGET, 1, 2)
	mr.unhook(target)
	return result, lower_calls
end)
fix('void hook_next then error', function(mr)
	local store = test_address(mr, 'hook_store')
	local cell = mr.alloc(4)
	mr.hook(store, 'void(pointer, int32)', function(p)
		mr.hook_next(store, p, 100)
		error('fails after hook_next')
	end)
	mr.call(store, 'void(pointer, int32)', cell, 5)
	mr.unhook(store)
	return mr.read_int32(cell, 0)
end)
fix('hook limit while running', function(mr)
	local target = test_address(mr, 'hook_target')
	local function pass_down(a, b)
		return mr.hook_next(target, a, b)
	end
	for _ = 1, 15 do
		mr.hook(target, HOOK_TARGET, function(a, b)
			return pass_down(a, b)
		end)
	end
	local message
	local top
	top = function(a, b)
		mr.unhook(target, top)
		message = select(2, pcall(mr.hook, target, HOOK_TARGET, pass_down))
		return pass_down(a, b)
	end
	mr.hook(target, HOOK_TARGET, top)
	mr.call(target, HOOK_TARGET, 1, 2)
	mr.unhook(target)
	return message:match('keep their place until the running call returns') ~= nil
end)
fix('alloc', function(mr)
	local p = mr.alloc(24)
	local zeroed = mr.read(p, 0, 24) == string.rep('\0', 24)
	local aligned = mr.tostring(p):sub(-1) == '0'
	return zeroed, aligned, mr.free == nil
end)
fix('alloc size', function(mr)
	return mr.alloc(0)
end)
local function int64_bytes(n)
	return string.char(n, 0, 0, 0, 0, 0, 0, 0)
end
local function game_vector(mr, values)
	local header = mr.alloc(16)
	local data = mr.game_alloc(#values * 8)
	for i, value in ipairs(values) do
		mr.write(data, (i - 1) * 8, int64_bytes(value))
	end
	mr.write(header, 0, mr.uint32(#values))
	mr.write(header, 4, mr.int32(#values))
	mr.write(header, 8, data)
	return header
end
local function vector_values(mr, header)
	return table.concat(mr.read_vector(header, 0, { 0, 'int32' }, 8), ' ')
end
local function patch_target(mr)
	return mr.pointer(test_function('patch_target'))
end
local MOV_EAX_1 = '\184\1\0\0\0'
local MOV_EAX_2 = '\184\2\0\0\0'

fix('game_alloc and game_free', function(mr)
	local before = test_heap_blocks()
	local block = mr.game_alloc(32)
	local zeroed = mr.read(block, 0, 32) == string.rep('\0', 32)
	local during = test_heap_blocks() - before
	mr.game_free(block)
	return zeroed, during, test_heap_blocks() - before
end)
fix('game_alloc size', function(mr)
	return mr.game_alloc(0)
end)
fix('game_free NULL', function(mr)
	return mr.game_free(mr.pointer(NULL))
end)
fix('game_free deferred', function(mr)
	local before = test_heap_blocks()
	mr.game_free(mr.game_alloc(8), true)
	return test_heap_blocks() - before
end)
fix('patch code', function(mr)
	local f = patch_target(mr)
	local before = mr.call(f, 'int32()')
	local old = mr.patch(f, MOV_EAX_1, MOV_EAX_2)
	local after = mr.call(f, 'int32()')
	local again = mr.patch(f, MOV_EAX_1, MOV_EAX_2)
	mr.patch(f, MOV_EAX_2, MOV_EAX_1)
	return before, old, after, again, mr.call(f, 'int32()')
end)
fix('patch mismatch', function(mr)
	return mr.patch(patch_target(mr), '\184\9\0\0\0', MOV_EAX_2)
end)
fix('function_start', function(mr)
	local f = mr.pointer(test_function('call_directly'))
	local start, finish = mr.function_start(f)
	local mid_start, mid_finish = mr.function_start(mr.add(f, 4))
	return mr.eq(start, f), mr.eq(mid_start, f), mr.eq(finish, mid_finish), mr.eq(mr.function_start(mr.add(finish, -1)), f)
end)
fix('function_start outside a function', function(mr)
	return mr.function_start(mr.add(mr.base, DOS_HEADER_SP)) == nil
end)
fix('function_start outside the exe', function(mr)
	return mr.function_start(mr.alloc(4))
end)
fix('relocate_field', function(mr)
	local site = test_address(mr, 'pattern_target')
	local original = mr.read(site, 0, 2)
	local ok = mr.relocate_field({ { site, original, 'AB' } })
	local changed = mr.read(site, 0, 2)
	mr.relocate_field({ { site, 'AB', original } })
	return ok, changed, mr.read(site, 0, 2) == original
end)
fix('relocate_field all or nothing', function(mr)
	local site = test_address(mr, 'pattern_target')
	local original = mr.read(site, 0, 2)
	local result, which = mr.relocate_field({ { site, original, 'AB' }, { mr.add(site, 4), 'ZZ', 'QQ' } })
	return result, which, mr.read(site, 0, 2) == original
end)
fix('relocate_field already applied', function(mr)
	local site = test_address(mr, 'pattern_target')
	local original = mr.read(site, 0, 2)
	return mr.relocate_field({ { site, original, original } }), mr.read(site, 0, 2) == original
end)
fix('relocate_field no sites', function(mr)
	return mr.relocate_field({})
end)
fix('relocate_field site lengths', function(mr)
	return mr.relocate_field({ { mr.add(mr.base, DOS_HEADER_SP), 'AB', 'ABC' } })
end)
fix('patch text address', function(mr)
	return mr.patch('MZ', 'AB', 'CD')
end)
fix('patch read-only code', function(mr)
	local at = test_address(mr, 'pattern_target')
	local original = mr.read(at, 0, 2)
	local old = mr.patch(at, original, 'AB')
	local changed = mr.read(at, 0, 2)
	mr.patch(at, 'AB', original)
	return old == original, changed, mr.read(at, 0, 2) == original
end)
fix('patch outside the exe', function(mr)
	return mr.patch(mr.alloc(4), '\0\0\0\0', '\1\0\0\0')
end)
fix('patch lengths', function(mr)
	return mr.patch(mr.base, 'MZ', 'M')
end)
fix('patch empty', function(mr)
	return mr.patch(mr.base, '', '')
end)
fix('vector_insert', function(mr)
	local v = game_vector(mr, { 10, 20, 30 })
	local at = mr.vector_insert(v, 0, 8, 2, int64_bytes(15))
	local inserted = mr.read_int32(at, 0)
	mr.vector_insert(v, 0, 8, 1, int64_bytes(5))
	mr.vector_insert(v, 0, 8, 6)
	return vector_values(mr, v), mr.read_uint32(v, 0), inserted
end)
fix('vector_insert into an empty vector', function(mr)
	local header = mr.alloc(16)
	mr.vector_insert(header, 0, 8, 1, int64_bytes(7))
	return vector_values(mr, header), mr.read_uint32(header, 0)
end)
fix('vector_erase', function(mr)
	local v = game_vector(mr, { 1, 2, 3, 4, 5 })
	mr.vector_erase(v, 0, 8, 2)
	mr.vector_erase(v, 0, 8, 2, 2)
	return vector_values(mr, v), mr.read_int32(v, 4), mr.read_int32(mr.read_pointer(v, 8), 16)
end)
fix('vector_reserve', function(mr)
	local v = game_vector(mr, { 1, 2 })
	local data = mr.read_pointer(v, 8)
	mr.vector_reserve(v, 0, 8, 2)
	local same = mr.eq(mr.read_pointer(v, 8), data)
	mr.vector_reserve(v, 0, 8, 100)
	return same, mr.eq(mr.read_pointer(v, 8), data), mr.read_uint32(v, 0), vector_values(mr, v)
end)
fix('vector stride', function(mr)
	return mr.vector_insert(mr.alloc(16), 0, 0)
end)
fix('vector position', function(mr)
	return mr.vector_insert(game_vector(mr, { 1 }), 0, 8, 3)
end)
fix('vector element size', function(mr)
	return mr.vector_insert(game_vector(mr, { 1 }), 0, 8, 1, 'abc')
end)
fix('vector broken header', function(mr)
	local header = mr.alloc(16)
	mr.write(header, 0, mr.uint32(1))
	mr.write(header, 4, mr.int32(2))
	return mr.vector_erase(header, 0, 8, 1)
end)
fix('vector_erase empty', function(mr)
	return mr.vector_erase(mr.alloc(16), 0, 8, 1)
end)
fix('vector_erase count', function(mr)
	return mr.vector_erase(game_vector(mr, { 1, 2 }), 0, 8, 2, 2)
end)
fix('string_set', function(mr)
	local field = mr.alloc(16)
	local long = 'a text longer than fourteen characters'
	mr.write(field, 0, inline('old'))
	local before = test_heap_blocks()
	mr.string_set(field, 0, long)
	local set_long = mr.read_string(field, 0) == long
	local grew = test_heap_blocks() - before
	mr.string_set(field, 0, 'short')
	return set_long, grew, mr.read_string(field, 0), test_heap_blocks() - before
end)
fix('unistring_set', function(mr)
	local field = mr.alloc(16)
	local long = 'zażółć gęślą jaźń'
	local before = test_heap_blocks()
	mr.unistring_set(field, 0, long)
	local set_long = mr.read_unistring(field, 0) == long
	local grew = test_heap_blocks() - before
	mr.unistring_set(field, 0, 'ok')
	return set_long, grew, mr.read_unistring(field, 0), test_heap_blocks() - before
end)
fix('string_set zero byte', function(mr)
	return mr.string_set(mr.alloc(16), 0, 'a\0b')
end)
fix('string_set not a string', function(mr)
	local field = mr.alloc(16)
	mr.write(field, 0, '\255\255\255\127' .. string.rep('\0', 12))
	return mr.string_set(field, 0, 'x')
end)
fix('read_pack_file', function(mr)
	local text = mr.read_pack_file('text/test/hello.txt')
	return text, mr.read_pack_file('text\\test\\hello.txt') == text, test_open_streams()
end)
fix('read_pack_file binary and empty', function(mr)
	return mr.read_pack_file('db/test_tables/binary'), mr.read_pack_file('text/test/empty.txt') == '', test_open_streams()
end)
fix('read_pack_file missing', function(mr)
	return mr.read_pack_file('text/test/missing.txt'), test_open_streams()
end)
fix('pack_file_exists', function(mr)
	return mr.pack_file_exists('text/test/hello.txt'), mr.pack_file_exists('text/test/missing.txt')
end)
fix('read_pack_file empty path', function(mr)
	return mr.read_pack_file('')
end)
fix('read_pack_file disk paths', function(mr)
	local refused = 0
	for _, path in ipairs({ 'C:/Windows/win.ini', '../x', 'text/../../x', '//server/share/x', 'text/..' }) do
		if not pcall(mr.read_pack_file, path) then refused = refused + 1 end
	end
	return refused, mr.pack_file_exists('text/a..b/c')
end)
fix('pack_file_exists drive', function(mr)
	return mr.pack_file_exists('d:x')
end)
fix('pack_file_exists zero byte', function(mr)
	return mr.pack_file_exists('text/a\0b')
end)

local MAP_BUCKETS = 0x18
local MAP_HEADER = 0x30
local NODE_INDEX = 0x20
local NODE_SOURCE = 0x28
local function empty_map(mr, buckets)
	local map = mr.alloc(MAP_HEADER + (buckets + 1) * 8)
	local finish = mr.add(map, 8)
	local data = mr.add(map, MAP_HEADER)
	mr.write(map, 0x10, finish)
	mr.write(map, MAP_BUCKETS, mr.uint32(buckets + 1))
	mr.write(map, MAP_BUCKETS + 4, mr.uint32(buckets + 1))
	mr.write(map, MAP_BUCKETS + 8, data)
	for i = 0, buckets do
		mr.write(data, i * 8, finish)
	end
	mr.write(map, 0x28, 1.0)
	return map
end
local function map_keys(mr, map)
	local keys = mr.read_list(map, 0, { 0, 'struct', { key = { 0x10, 'string' }, index = { NODE_INDEX, 'uint32' } } })
	local texts = {}
	for i, node in ipairs(keys) do
		texts[i] = node.key .. '=' .. node.index
	end
	return table.concat(texts, ' ')
end
local function map_index(mr, map, key)
	local node = mr.map_find_key(map, key)
	return node and mr.read_uint32(node, NODE_INDEX)
end

fix('map_add_key', function(mr)
	local map = empty_map(mr, 7)
	local source = mr.alloc(8)
	local node, inserted = mr.map_add_key(map, 'alpha', 3, source)
	mr.map_add_key(map, 'beta', 4)
	mr.map_add_key(map, 'gamma', 5)
	local again, inserted_again = mr.map_add_key(map, 'alpha', 9)
	local found = mr.map_find_key(map, 'alpha')
	return inserted,
		inserted_again,
		mr.eq(again, node),
		mr.eq(found, node),
		mr.eq(mr.read_pointer(node, NODE_SOURCE), source),
		map_index(mr, map, 'beta'),
		map_index(mr, map, 'gamma'),
		mr.map_find_key(map, 'delta'),
		mr.read_uint32(map, 0)
end)
fix('map_add_key one bucket', function(mr)
	local map = empty_map(mr, 1)
	mr.map_add_key(map, 'a', 0)
	mr.map_add_key(map, 'b', 1)
	return map_keys(mr, map), map_index(mr, map, 'a'), map_index(mr, map, 'b')
end)
fix('map_find_key hash', function(mr)
	local key = 'wh2_main_hef_bow_arrow'
	local map = empty_map(mr, 2047)
	local node = mr.alloc(0x30)
	local finish = mr.add(map, 8)
	local data = mr.add(map, MAP_HEADER)
	mr.write(node, 8, finish)
	mr.write(node, 0x10, mr.uint32(#key))
	mr.write(node, 0x14, mr.uint32(#key))
	mr.write(node, 0x18, mr.add(string_address(mr, key), 0))
	mr.write(map, 0, mr.uint32(1))
	mr.write(map, 8, node)
	mr.write(map, 0x10, node)
	mr.write(data, 0, node)
	mr.write(data, 8, node)
	return mr.eq(mr.map_find_key(map, key), node), mr.map_find_key(map, 'wh2_main_hef_bow_arrows')
end)
fix('map_remove_key', function(mr)
	local map = empty_map(mr, 7)
	for i, key in ipairs({ 'a', 'b', 'c', 'd', 'e' }) do
		mr.map_add_key(map, key, i)
	end
	local removed = mr.map_remove_key(map, 'c')
	local first = mr.map_remove_key(map, 'a') and mr.map_remove_key(map, 'e')
	return removed,
		first,
		mr.map_remove_key(map, 'c'),
		map_keys(mr, map),
		mr.map_find_key(map, 'c'),
		map_index(mr, map, 'b'),
		map_index(mr, map, 'd'),
		mr.read_uint32(map, 0)
end)
fix('map_remove_key last', function(mr)
	local map = empty_map(mr, 3)
	mr.map_add_key(map, 'only', 0)
	mr.map_remove_key(map, 'only')
	local finish = mr.add(map, 8)
	return mr.read_uint32(map, 0),
		mr.eq(mr.read_pointer(map, 0x10), finish),
		mr.is_null(mr.read_pointer(map, 8)),
		mr.eq(mr.read_pointer(mr.read_pointer(map, 0x20), 0), finish)
end)
fix('map keys own their strings', function(mr)
	local map = empty_map(mr, 3)
	local before = test_heap_blocks()
	mr.map_add_key(map, 'a key longer than fourteen bytes', 1)
	local added = test_heap_blocks() - before
	mr.map_remove_key(map, 'a key longer than fourteen bytes')
	return added, test_heap_blocks() - before, mr.read_uint32(map, 0)
end)
fix('map not a map', function(mr)
	return mr.map_find_key(mr.alloc(0x30), 'x')
end)
fix('map_add_key index', function(mr)
	return mr.map_add_key(empty_map(mr, 1), 'x', -1)
end)

local function empty_list(mr)
	local list = mr.alloc(0x18)
	mr.write(list, 0x10, mr.add(list, 8))
	return list
end
local function list_values(mr, list)
	return table.concat(mr.read_list(list, 0, { 0x10, 'int32' }), ' ')
end
local function int32_bytes(n)
	return string.char(n, 0, 0, 0)
end

fix('list_insert', function(mr)
	local list = empty_list(mr)
	local node = mr.list_insert(list, 0, 1, int32_bytes(1))
	mr.list_insert(list, 0, 2, int32_bytes(3))
	mr.list_insert(list, 0, 2, int32_bytes(2))
	mr.list_insert(list, 0, 1, int32_bytes(0))
	return list_values(mr, list), mr.read_int32(node, 0x10), mr.read_uint32(list, 0)
end)
fix('list_erase', function(mr)
	local list = empty_list(mr)
	for i = 1, 5 do
		mr.list_insert(list, 0, i, int32_bytes(i))
	end
	mr.list_erase(list, 0, 2, 2)
	local middle = list_values(mr, list)
	mr.list_erase(list, 0, 3)
	mr.list_erase(list, 0, 1)
	local last = list_values(mr, list)
	mr.list_erase(list, 0, 1)
	return middle, last, mr.read_uint32(list, 0), mr.eq(mr.read_pointer(list, 0x10), mr.add(list, 8)), mr.is_null(mr.read_pointer(list, 8))
end)
fix('list_insert position', function(mr)
	return mr.list_insert(empty_list(mr), 0, 2, 'x')
end)
fix('list_insert empty value', function(mr)
	return mr.list_insert(empty_list(mr), 0, 1, '')
end)
fix('list_erase empty', function(mr)
	return mr.list_erase(empty_list(mr), 0, 1)
end)
fix('list broken links', function(mr)
	local list = empty_list(mr)
	mr.list_insert(list, 0, 1, int32_bytes(1))
	local node = mr.list_insert(list, 0, 2, int32_bytes(2))
	mr.list_insert(list, 0, 3, int32_bytes(3))
	mr.write(node, 0, mr.alloc(8))
	return mr.list_erase(list, 0, 3)
end)
fix('alloc limit', function(mr)
	local blocks = 0
	while pcall(mr.alloc, 1024 * 1024) do
		blocks = blocks + 1
	end
	local _, err = pcall(mr.alloc, 1024 * 1024)
	error((err:gsub('%(%d+ in use%)', '(<n> in use)')), 0)
end)
fix('alloc limit is exact', function(mr)
	local limit = 16 * 1024 * 1024
	local _, err = pcall(mr.alloc, limit)
	local in_use = tonumber(err:match('%((%d+) in use%)'))
	if in_use < limit then mr.alloc(limit - in_use) end
	return (pcall(mr.alloc, 1))
end)

local function show(mr, ...)
	local parts = {}
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		local t = type(v)
		if t == 'userdata' then
			parts[i] = mr.type(v) .. ':' .. mr.tostring(v)
		elseif t == 'string' then
			parts[i] = 'bytes:' .. mr.tostring(v)
		else
			parts[i] = tostring(v)
		end
	end
	return table.concat(parts, ', ')
end

local function run(mr, list)
	local results = {}
	for _, c in ipairs(list) do
		local r = { pcall(c.run, mr) }
		if r[1] then
			results[#results + 1] = { name = c.name, value = show(mr, unpack(r, 2, table.maxn(r))) }
		else
			results[#results + 1] = { name = c.name, value = 'error: ' .. tostring(r[2]):gsub('^.-:%d+: ', '') }
		end
	end
	return results
end

return {
	shared = function(mr)
		return run(mr, cases)
	end,
	fixes = function(mr)
		return run(mr, fix_cases)
	end,
}
