-- MUSOU (无双) mode data, ported from the original kernel: MusouModel (the world
-- map, its areas and missions from tools/convert_musou_ui.py's BVNMusouConfig),
-- MusouFighterModel (the fighters the dialogs sell), MusouPlayerData with
-- MusouFighterVO / MusouWorldMap*PlayerVO (money, owned fighters with level and
-- exp, the team of three, opened areas and passed missions), LevelModel and
-- MusouLogic (area progress, unlocking, next mission, buying, enemy levels).
-- The player data is saved with the engine Save API in slot "musou"
-- (GameData.saveData). Not attached to any actor.
local SCHEMA = 1
local LEVEL_MAX = 80

-- MusouFighterModel.initFighters: fighter -> price, in the dialog's order.
local PRICES = {
	{"ichigo", 5000}, {"ichigo_zero", 5000}, {"rukia", 5000}, {"renji", 5000}, {"naruto", 5000}, {"sakura", 5000},
	{"uryuu", 5000}, {"lee", 5000}, {"neji", 5000}, {"temari", 5000}, {"chad", 7000}, {"karin", 7000}, {"gaara", 7000},
	{"sasuke", 8000}, {"orihime", 8000}, {"ikkaku", 8000}, {"gin", 8000}, {"juggo", 8000}, {"suigetsu", 8000},
	{"kakashi", 8000}, {"sakura_sr", 8000}, {"hinata", 8000}, {"kimimaro", 9000}, {"killerbee", 9000},
	{"toushirou", 10000}, {"byakuya", 10000}, {"jiraiya", 10000}, {"orochimaru", 10000}, {"deidara", 10000},
	{"soifon", 10000}, {"konan", 10000}, {"grimmjow", 10000}, {"mayuri", 12000}, {"yoruichi", 15000},
	{"kenpachi", 15000}, {"itachi", 15000}, {"pain", 15000}, {"ichigo_bankai", 15000}, {"naruto_oneTail", 15000},
	{"sasuke_susanoo", 15000}, {"ichigo_vizored_half", 18000}, {"naruto_hermit", 18000}, {"starrk", 20000},
	{"ulquiorra", 23000}, {"obito", 25000}, {"aizen", 40000}, {"madara", 42000}, {"kenshin", 45000},
}

-- MusouFighterLogic: the level each move needs. All 0 in the released kernel (the
-- commented-out table gated air dash at 4, ghost step at 12, bankai at 10, ...).
local LV = {dashAir = 0, ghostStep = 0, skill1 = 0, skill2 = 0, skillAir = 0, zhao1 = 0, zhao2 = 0, zhao3 = 0, catch1 = 0,
	catch2 = 0, bisha = 0, bishaAir = 0, bishaUp = 0, bishaSuper = 0, bankai = 0}
local ALL_ACTION_LEVELS = {}
for _, v in pairs(LV) do ALL_ACTION_LEVELS[#ALL_ACTION_LEVELS + 1] = v end

local INT = function(v) return BVNRuntime.INT(v) end

-- LevelModel.getLevelUpExp: exp to reach the next level (the sum over levels 1..level).
local function levelUpExp(level)
	if level <= 0 then return 0 end
	local function solve(n) return INT(3.8 * n * n - 1.2 * n + 48.6) end
	local exp = solve(level)
	for i = 1, level - 1 do exp = exp + solve(i) end
	return exp
end

-- MusouFighterVO ---------------------------------------------------------------------------

local Fighter = {}
Fighter.__index = Fighter

local function newFighter(id)
	local f = setmetatable({id = id, level = 1, exp = 0}, Fighter)
	f:UpdateLevel(1)
	return f
end

-- updateLevel: returns true when the level hit the cap.
function Fighter:UpdateLevel(lv)
	local limit = false
	if lv < 1 then lv = 1 end
	if lv > LEVEL_MAX then lv, limit = LEVEL_MAX, true end
	self.level = lv
	self.atk, self.skillAtk, self.bishaAtk = lv * 10, lv * 15, lv * 17
	self.hp = 1000 + lv * 150
	self.energy = 50 + lv * 10
	self.qi = math.min(100 + lv * 20, 300)
	return limit
end

-- addExp: one level at most per call; LEVEL_UP goes to BVNMusouData.onLevelUp.
function Fighter:AddExp(v)
	local lv = self.level
	local val = self.exp + v
	local nextExp = levelUpExp(lv)
	if val >= nextExp then
		if not self:UpdateLevel(lv + 1) then
			self.exp = val - nextExp
			local cb = BVNMusouData.onLevelUp
			if cb then cb(self) end
		else
			self.exp = nextExp
		end
		return
	end
	self.exp = val
end

-- MusouFighterLogic: per-move level checks (FighterActionLogic asks these).
function Fighter:Can(move) return self.level >= (LV[move] or 0) end

-- Model (MusouModel) ---------------------------------------------------------------------

local maps

-- MusouEnemyVO.createByJSON: `amount` copies; hp 0 keeps the script's HP, exp / money 0 default by kind.
local function enemiesOf(list, wave, rep)
	local out = {}
	for _, e in ipairs(list or {}) do
		for _ = 1, INT(e.amount or 0) do
			local boss = e.isBoss == true
			local exp, money = INT(e.exp or 0), INT(e.money or 0)
			out[#out + 1] = {fighterID = e.id, maxHp = math.max(0, INT(e.hp or 0)), atk = INT(e.atk or 0), isBoss = boss,
				exp = exp > 0 and exp or (boss and 100 or 10), money = money > 0 and money or (boss and 100 or 10),
				wave = wave, rep = rep, level = 1}
		end
	end
	return out
end

-- MusouMissionVO.initByJsonObject: fresh objects per call (waves keep per-run state).
local function missionOf(raw, area)
	local m = {id = raw.id, name = raw.name, map = raw.map, time = INT(raw.time), enemyLevel = math.max(1, INT(raw.enemyLevel)),
		waves = {}, area = area}
	for i, w in ipairs(raw.waves or {}) do
		local wave = {id = i, hold = INT(w.hold)}
		wave.enemies = enemiesOf(w.enemies, wave, nil)
		if w["repeat"] then
			local r = {type = INT(w["repeat"].type), hold = INT(w["repeat"].hold), holdFrame = 0}
			-- MusouWaveRepeatVO.addEnemy: the repeat's wave is never set.
			r.enemies = enemiesOf(w["repeat"].enemies, nil, r)
			wave.repeats = {r}
		end
		m.waves[i] = wave
	end
	return m
end

local function loadMaps()
	if maps then return maps end
	maps = {}
	local cfg = BVNMusouConfig and BVNMusouConfig.maps or {}
	for id, raw in pairs(cfg) do
		local mp = {id = raw.id, name = raw.name, areas = {}, areaMap = {}}
		-- MusouWorldMapVO.initWay: areas in way order, then preOpens (N, one id or a list).
		for _, w in ipairs(raw.way) do
			local a = {id = w.P, raw = raw.areas[w.P]}
			mp.areas[#mp.areas + 1] = a
			mp.areaMap[a.id] = a
		end
		for _, w in ipairs(raw.way) do
			local a = mp.areaMap[w.P]
			if a and w.N then
				a.preOpens = {}
				local list = type(w.N) == "table" and w.N or {w.N}
				for _, n in ipairs(list) do
					if mp.areaMap[n] then a.preOpens[#a.preOpens + 1] = mp.areaMap[n] end
				end
			end
		end
		for _, a in ipairs(mp.areas) do
			a.name = a.raw and a.raw.name
			a.missionIds = {}
			for i, ms in ipairs(a.raw and a.raw.missions or {}) do a.missionIds[i] = ms.id end
		end
		maps[id] = mp
	end
	return maps
end

local function area(mapId, areaId)
	local mp = loadMaps()[mapId]
	return mp and mp.areaMap[areaId]
end

-- MusouWorldMapAreaVO.building: an area without missions is not open in this version.
local function building(a) return not a or #a.missionIds < 1 end

-- Player data (MusouPlayerData) ------------------------------------------------------------

local P -- the player data

local function playerArea(mp, id)
	for _, a in ipairs(mp.areas) do if a.id == id then return a end end
	return nil
end

local function mapData(id)
	for _, m in ipairs(P.maps) do if m.id == id then return m end end
	return nil
end

local function openArea(mapId, areaId)
	local mp = mapData(mapId)
	if mp and not playerArea(mp, areaId) then mp.areas[#mp.areas + 1] = {id = areaId, missions = {}} end
end

local function fighterData(id)
	for _, f in ipairs(P.fighters) do if f.id == id then return f end end
	return nil
end

-- MusouPlayerData.init: map1 with its first areas, 3000 coins, Ichigo, Naruto and Sakura.
local function init()
	P = {money = 3000, maps = {}, fighters = {}, team = {}, currentMapId = "map1", currentAreaId = "p1", lastLogin = 0}
	P.maps[1] = {id = P.currentMapId, areas = {}}
	local mp = loadMaps()[P.currentMapId]
	for _, a in ipairs(mp and mp.areas or {}) do
		if not a.preOpens or #a.preOpens < 1 then openArea(P.currentMapId, a.id) end
	end
	for _, id in ipairs({"ichigo", "naruto", "sakura"}) do P.fighters[#P.fighters + 1] = newFighter(id) end
	for i, f in ipairs(P.fighters) do P.team[i] = f end
end

-- readSaveObj, with the original's truthiness checks (a saved 0 money keeps the default).
local function read(o)
	if type(o) ~= "table" then return end
	P.userId, P.userName = o.userId, o.userName
	if BVNRuntime.T(o.money) then P.money = INT(o.money) end
	if BVNRuntime.T(o.lastLogin) then P.lastLogin = o.lastLogin end
	if type(o.mapData) == "table" then
		P.maps = {}
		for _, m in ipairs(o.mapData) do
			local mv = {id = m.id, areas = {}}
			for _, a in ipairs(type(m.areas) == "table" and m.areas or {}) do
				local av = {id = a.id, name = a.name, missions = {}}
				for _, ms in ipairs(type(a.missions) == "table" and a.missions or {}) do
					av.missions[#av.missions + 1] = {id = ms.id, stars = INT(ms.stars or 0)}
				end
				mv.areas[#mv.areas + 1] = av
			end
			P.maps[#P.maps + 1] = mv
		end
	end
	if type(o.fighterData) == "table" then
		P.fighters = {}
		for _, d in ipairs(o.fighterData) do
			local f = newFighter(d.id)
			if BVNRuntime.T(d.exp) then f.exp = INT(d.exp) end
			if BVNRuntime.T(d.level) then f:UpdateLevel(INT(d.level)) end
			if f.id then P.fighters[#P.fighters + 1] = f end
		end
	end
	if BVNRuntime.T(o.currentMapId) then P.currentMapId = o.currentMapId end
	if BVNRuntime.T(o.currentAreaId) then P.currentAreaId = o.currentAreaId end
	if type(o.fighterTeam) == "table" then
		P.team = {}
		for _, id in ipairs(o.fighterTeam) do
			local f = fighterData(id)
			if f then P.team[#P.team + 1] = f end
		end
	end
end

local function saveObj()
	local o = {userId = P.userId, userName = P.userName, money = P.money, lastLogin = P.lastLogin, mapData = {},
		fighterData = {}, currentMapId = P.currentMapId, currentAreaId = P.currentAreaId, fighterTeam = {}}
	for _, m in ipairs(P.maps) do
		local mv = {id = m.id, areas = {}}
		for _, a in ipairs(m.areas) do
			local av = {id = a.id, missions = {}}
			if a.name then av.name = a.name end
			for _, ms in ipairs(a.missions) do av.missions[#av.missions + 1] = {id = ms.id, stars = ms.stars} end
			mv.areas[#mv.areas + 1] = av
		end
		o.mapData[#o.mapData + 1] = mv
	end
	for _, f in ipairs(P.fighters) do o.fighterData[#o.fighterData + 1] = {id = f.id, level = f.level, exp = f.exp} end
	for _, f in ipairs(P.team) do o.fighterTeam[#o.fighterTeam + 1] = f.id end
	return o
end

local function player()
	if not P then BVNMusouData.Load() end
	return P
end

BVNMusouData = {
	LEVEL_MAX = LEVEL_MAX,
	PRICES = PRICES,
	LV = LV,
	ALL_ACTION_LEVELS = ALL_ACTION_LEVELS,
	LevelUpExp = levelUpExp,
	-- Called with the MusouFighterVO when a fighter levels up (GameEvent.LEVEL_UP).
	onLevelUp = nil,

	-- GameData.initData + loadSaveData: defaults, then the save (slot "musou") over them.
	Load = function()
		init()
		local r = Save and Save.Read("musou", {fallback = true})
		if r and r.ok and r.schema_version == SCHEMA and type(r.data) == "table" then
			read(r.data)
			-- A damaged save was replaced by its previous version: keep that one as the save.
			if r.recovered then
				Debug.Log("BVN: the musou save was damaged; its previous version was loaded")
				BVNMusouData.Save()
			end
		end
		return P
	end,

	-- GameData.saveData.
	Save = function()
		if not P or not Save then return false end
		local r = Save.Write("musou", SCHEMA, saveObj())
		if not r.ok then Debug.Log("BVN: cannot save musou data: " .. tostring(r.code) .. " " .. tostring(r.error)) end
		return r.ok
	end,

	-- Forgets the loaded data (tests): the next access reads the save again.
	Reset = function() P = nil end,
	-- Fresh default data (tests), not saved until something saves.
	New = function() init() return P end,
	Snapshot = function() return saveObj() end,

	Player = player,
	Maps = loadMaps,
	Map = function(id) return loadMaps()[id] end,
	Area = area,
	Building = building,
	Mission = function(mapId, areaId, missionId)
		local a = area(mapId, areaId)
		for _, raw in ipairs(a and a.raw and a.raw.missions or {}) do
			if raw.id == missionId then return missionOf(raw, a) end
		end
		return nil
	end,

	-- Money -----------------------------------------------------------------------------
	Money = function() return player().money end,
	AddMoney = function(v) local p = player(); p.money = INT(p.money + v) end,
	LoseMoney = function(v) local p = player(); p.money = math.max(0, INT(p.money - v)) end,

	-- Fighters --------------------------------------------------------------------------
	Fighters = function() return player().fighters end,
	FighterData = function(id) player() return fighterData(id) end,
	AddFighter = function(id)
		player()
		local f = fighterData(id)
		if f then return f end
		f = newFighter(id)
		P.fighters[#P.fighters + 1] = f
		return f
	end,
	Team = function() return player().team end,
	TeamIds = function()
		local ids = {}
		for i, f in ipairs(player().team) do ids[i] = f.id end
		return ids
	end,
	SetTeam = function(index, id)
		player()
		local f = fighterData(id)
		if f then P.team[index] = f end
	end,
	Leader = function() return player().team[1] end,
	-- setLeader: the chosen fighter moves to the front, the others keep their order around it.
	SetLeader = function(f)
		local t = player().team
		local index
		for i, x in ipairs(t) do if x == f then index = i end end
		if not index or index == 1 then return end
		local tmp = {t[1], t[2], t[3]}
		if index == 2 then t[3], t[2], t[1] = tmp[1], tmp[3], tmp[2]
		else t[3], t[2], t[1] = tmp[2], tmp[1], tmp[3] end
	end,
	-- addFighterExp: the leader gets double.
	AddFighterExp = function(v)
		for i, f in ipairs(player().team) do f:AddExp(i == 1 and v * 2 or v) end
	end,
	Price = function(id)
		for _, p in ipairs(PRICES) do if p[1] == id then return p[2] end end
		return nil
	end,

	-- Areas and missions (MusouLogic) ----------------------------------------------------
	CurrentMapId = function() return player().currentMapId end,
	CurrentAreaId = function() return player().currentAreaId end,
	SetCurrentArea = function(id) player().currentAreaId = id end,
	CheckCurrentArea = function(id)
		local p = player()
		local mp = mapData(p.currentMapId)
		local a = mp and playerArea(mp, p.currentAreaId)
		return a ~= nil and a.id == id
	end,
	CheckAreaIsOpen = function(id)
		local mp = mapData(player().currentMapId)
		return mp ~= nil and playerArea(mp, id) ~= nil
	end,
	OpenArea = function(mapId, areaId) player() openArea(mapId, areaId) end,
	-- getAreaPercent: passed missions / missions.
	AreaPercent = function(id)
		local p = player()
		local mp = mapData(p.currentMapId)
		local a = mp and playerArea(mp, id)
		local a2 = a and area(mp.id, id)
		if not a2 or #a2.missionIds == 0 then return 0 end
		return #a.missions / #a2.missionIds
	end,
	-- getNextMission: the one after the last passed, or the first; the last again when all are passed.
	NextMission = function(id)
		local p = player()
		local mp = mapData(p.currentMapId)
		local a = mp and playerArea(mp, id)
		local a2 = a and area(mp.id, id)
		if not a2 or #a2.missionIds == 0 then return nil end
		local raws = a2.raw.missions
		local last = a.missions[#a.missions]
		if not last then return missionOf(raws[1], a2) end
		for i, raw in ipairs(raws) do
			if raw.id == last.id then
				if raws[i + 1] then return missionOf(raws[i + 1], a2) end
				break
			end
		end
		return missionOf(raws[#raws], a2)
	end,
	-- updateMapAreas: an area opens once each of its preOpens is more than 60% passed.
	UpdateMapAreas = function()
		local p = player()
		local mp = loadMaps()[p.currentMapId]
		for _, a in ipairs(mp and mp.areas or {}) do
			if a.preOpens and #a.preOpens > 0 then
				local ok = true
				for _, pre in ipairs(a.preOpens) do
					if not (BVNMusouData.AreaPercent(pre.id) > 0.6) then ok = false break end
				end
				if ok then openArea(p.currentMapId, a.id) end
			end
		end
	end,
	-- passMission: 2000 coins the first time, 500 after; then areas update and the data is saved.
	PassMission = function(mission)
		local p = player()
		local mp = mapData(p.currentMapId)
		local a = mp and playerArea(mp, p.currentAreaId)
		if not a then return end
		local found
		for _, ms in ipairs(a.missions) do if ms.id == mission.id then found = ms end end
		if not found then
			a.missions[#a.missions + 1] = {id = mission.id, stars = 1}
			BVNMusouData.AddMoney(2000)
		else
			found.stars = 1
			BVNMusouData.AddMoney(500)
		end
		BVNMusouData.UpdateMapAreas()
		BVNMusouData.Save()
	end,

	-- initEnemyProps: HP, energy and attack bonuses by the mission's enemy level.
	InitEnemyProps = function(f, data, level)
		data.level = level
		local lv = level
		if data.isBoss then
			if data.maxHp > 0 then f.hp, f.hpMax = data.maxHp, data.maxHp
			else f.hp, f.hpMax = 1000 + lv * 400, 1000 + lv * 400 end
			f.energy, f.energyMax = 80 + lv * 10, 80 + lv * 10
			BVNMusouData.InitAttackAddDmg(f, lv * 13, lv * 14, lv * 15)
		else
			if data.maxHp > 0 then
				f.hp, f.hpMax = data.maxHp, data.maxHp
			else
				local rate = 1 + (lv - 1) * 0.08
				if rate > 1 then f.hp, f.hpMax = f.hp * rate, f.hp * rate end
			end
			BVNMusouData.InitAttackAddDmg(f, lv * 5, lv * 10, lv * 20)
		end
	end,

	-- FighterMain.initAttackAddDmg: bonus percent by move kind (HitVO.isBisha / isSkill).
	InitAttackAddDmg = function(f, normal, skill, bisha)
		for id, h in pairs(f.hitModel) do
			if id:find("bs") then h.powerAdd = bisha
			elseif id:find("tz") or id:find("kj") or id:find("zh") or id:find("sh") then h.powerAdd = skill
			else h.powerAdd = normal end
		end
	end,

	-- MusouEnemyVO.getExp / getMoney.
	EnemyExp = function(d) return d.exp + (d.isBoss and d.level * 10 or d.level * 2) end,
	EnemyMoney = function(d) return d.money + (d.isBoss and d.level * 5 or d.level) end,

	-- MusouMissionVO helpers.
	MissionEnemyIds = function(m)
		local ids, seen = {}, {}
		for _, w in ipairs(m.waves) do
			local all = {}
			for _, e in ipairs(w.enemies) do all[#all + 1] = e end
			for _, r in ipairs(w.repeats or {}) do for _, e in ipairs(r.enemies) do all[#all + 1] = e end end
			for _, e in ipairs(all) do
				if not seen[e.fighterID] then seen[e.fighterID] = true; ids[#ids + 1] = e.fighterID end
			end
		end
		return ids
	end,
	MissionBossIds = function(m)
		local ids, seen = {}, {}
		for _, w in ipairs(m.waves) do
			local all = {}
			for _, e in ipairs(w.enemies) do all[#all + 1] = e end
			for _, r in ipairs(w.repeats or {}) do for _, e in ipairs(r.enemies) do all[#all + 1] = e end end
			for _, e in ipairs(all) do
				if e.isBoss and not seen[e.fighterID] then seen[e.fighterID] = true; ids[#ids + 1] = e.fighterID end
			end
		end
		return ids
	end,
	-- bossCount counts the bosses of the waves' own enemies (not their repeats).
	MissionBossCount = function(m)
		local n = 0
		for _, w in ipairs(m.waves) do for _, e in ipairs(w.enemies) do if e.isBoss then n = n + 1 end end end
		return n
	end,
}
