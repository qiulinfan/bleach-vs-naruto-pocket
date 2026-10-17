-- Helpers the translated 5DPLAY scripts call (see tools/as3lua.py), and the
-- registry of converted characters. Not attached to any actor.
BVNRuntime = {seed = 1}
local R = BVNRuntime

-- ActionScript truthiness: 0, NaN, "" and nil are false.
function R.T(v)
	if v == nil or v == false or v == 0 or v == "" then return false end
	if v ~= v then return false end
	return true
end

function R.INT(v)
	v = tonumber(v) or 0
	if v ~= v then return 0 end
	return v >= 0 and math.floor(v) or -math.floor(-v)
end

function R.ROUND(v) return math.floor(v + 0.5) end
function R.TERN(c, a, b) if c then return a end return b end
function R.ISNAN(v) return v ~= v end
function R.TRACE() end
function R.TIMER() return math.floor(Application.GetFrame() * 1000 / 60) end

function R.ADD(a, b)
	if type(a) == "string" or type(b) == "string" then return tostring(a) .. tostring(b) end
	return (a or 0) + (b or 0)
end

function R.TYPEOF(v)
	local t = type(v)
	if t == "nil" then return "undefined" end
	if t == "table" then return "object" end
	return t
end

-- Deterministic Math.random(), seeded per match by BVN.Seed.
function R.RAND()
	R.seed = (R.seed * 1103515245 + 12345) % 2147483648
	return R.seed / 2147483648
end

-- AS3 arrays are 0-based; scripts mostly push/pop and read length.
local ArrayMT = {}
ArrayMT.__index = function(t, k)
	if k == "length" then return #rawget(t, "_a") end
	if type(k) == "number" then return rawget(t, "_a")[k + 1] end
	return ArrayMT[k]
end
ArrayMT.__newindex = function(t, k, v)
	if type(k) == "number" then rawget(t, "_a")[k + 1] = v else rawset(t, k, v) end
end
function ArrayMT.push(t, v) local a = rawget(t, "_a"); a[#a + 1] = v; return #a end
function ArrayMT.pop(t) local a = rawget(t, "_a"); return table.remove(a) end
function ArrayMT.shift(t) return table.remove(rawget(t, "_a"), 1) end
function ArrayMT.indexOf(t, v)
	for i, x in ipairs(rawget(t, "_a")) do if x == v then return i - 1 end end
	return -1
end
function R.ARRAY(items) return setmetatable({_a = items}, ArrayMT) end

function R.PAIRS(t)
	if type(t) == "table" and rawget(t, "_a") then
		local a, i = rawget(t, "_a"), 0
		return function() i = i + 1; if a[i] ~= nil then return i - 1, a[i] end end
	end
	return pairs(t or {})
end

-- Objects scripts construct with `new` (Point, ColorTransform, ...): plain tables.
function R.NEW(cls, a, b)
	if cls == "Point" or cls == "flash.geom.Point" then return {x = a or 0, y = b or 0} end
	if cls == "Array" then return R.ARRAY({}) end
	return {}
end

local warned = {}
function R.UNSUPPORTED(name)
	if not warned[name] then
		warned[name] = true
		Debug.Log("BVN: script not translated: " .. name)
	end
end

-- Character registry: converted data lives in globals BVNF_<id>.
-- Converted characters live in data/bvn/BVNF_<id>.lua and are loaded on first
-- use (all of them would take ~100 MB of Lua heap). Files either return their
-- table or (older converter output) assign a global of the same name.
local cache, exists = {}, {}
local function dataPath(var)
	return Application.GetProjectDirectory() .. "/data/bvn/" .. var .. ".lua"
end

function R.HasCharacter(id)
	local var = "BVNF_" .. id:gsub("%W", "_")
	if cache[var] then return true end
	if exists[var] == nil then
		local f = io.open(dataPath(var), "rb")
		exists[var] = f ~= nil
		if f then f:close() end
	end
	return exists[var]
end

function R.Character(id)
	local var = "BVNF_" .. id:gsub("%W", "_")
	local c = cache[var]
	if c then return c end
	local f = io.open(dataPath(var), "rb")
	if not f then return nil end
	local src = f:read("a")
	f:close()
	local chunk, err = load(src, "@" .. var .. ".lua", "t")
	if not chunk then Debug.Log("BVN: cannot load " .. var .. ": " .. tostring(err)) return nil end
	c = chunk()
	if c == nil then
		c = rawget(_G, var)
		rawset(_G, var, nil)
	end
	cache[var] = c
	return c
end

-- Drops loaded characters not listed in `keep` (ids with the BVNF_ prefix rules applied).
function R.KeepCharacters(keep)
	local want = {}
	for _, id in ipairs(keep) do want["BVNF_" .. id:gsub("%W", "_")] = true end
	for var in pairs(cache) do
		if not want[var] then cache[var] = nil end
	end
	collectgarbage()
end

-- A class referenced by name in a script (faces, sounds, Event, ...).
local classCache = {}
function R.CLASS(name)
	local c = classCache[name]
	if not c then
		c = setmetatable({name = name}, {__index = function(_, k) return name .. "." .. k end})
		classCache[name] = c
	end
	return c
end
