-- The MUSOU (无双) fight: MusouCtrl, MusouFighterEventCtrl and the musou parts of
-- MusouLogic, GameCtrl, GameStage and the fighter kernel, on top of BVNBattle's
-- tick order, camera, map and drawing. The player's team of three switches with
-- the assist key (changeFighter), waves and repeats come from the mission,
-- mooks run EnemyFighterAICtrl, bosses EnemyBossAICtrl (the versus CPU at level
-- 2 without bankai, ghost steps, bursts, super ultimates or throws). Versus
-- battles are unaffected: this class only inherits BVNBattle.Battle's methods.
-- Not attached to any actor; BVNGame owns the current battle.
local D = setmetatable({}, {__index = function(_, k) return BVNDraw[k] end})
local BLACK = {0, 0, 0}
local SW, SH = 1280, 720
local FPS = 30 -- GameConfig.FPS_ANIMATE: animate ticks per second

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function RAND() return BVNRuntime.RAND() end

local function overlap(a, b)
	local x0, y0 = math.max(a[1], b[1]), math.max(a[2], b[2])
	local x1, y1 = math.min(a[1] + a[3], b[1] + b[3]), math.min(a[2] + a[4], b[2] + b[4])
	if x1 <= x0 or y1 <= y0 then return nil end
	return {x0, y0, x1 - x0, y1 - y0}
end

local function indexOf(list, v)
	for i, x in ipairs(list) do if x == v then return i end end
	return nil
end

local function removeValue(list, v)
	local i = indexOf(list, v)
	if i then table.remove(list, i) end
	return i ~= nil
end

local function copy(list)
	local out = {}
	for i, v in ipairs(list) do out[i] = v end
	return out
end

local M = {}
-- Methods resolve here first, then in BVNBattle.Battle (looked up when called:
-- component files load in any order).
local Meta = {__index = function(_, k)
	local v = M[k]
	if v ~= nil then return v end
	return BVNBattle.Battle[k]
end}

-- Musou enemy hit / guard effects (EffectModel.initMusouEnemyHitEffect / initMusouEnemyDefenseEffect).
local HIT_ENEMY = {
	[11] = {cls = "xg_catch_hit", snd = "snd_hit_cache", freeze = 200},
	[1] = {cls = "XG_kan2", snd = "snd_kan1", freeze = 50, rand = true},
	[6] = {cls = "XG_kanx2", snd = "snd_kan2", freeze = 200, shine = {0xffffff, 0.2}, rand = true, shake = {0, 2, 100}},
	[2] = {cls = "XG_qdj", snd = "snd_hit2", freeze = 0, rand = true},
	[3] = {cls = "XG_qdjx", snd = "snd_hit_heavy", rand = true, freeze = 200, shine = {0xffffff, 0.2}, shake = {0, 2, 100}},
	[4] = {cls = "XG_mfdj", snd = "snd_hit2", freeze = 0, rand = true},
	[5] = {cls = "XG_mfdjx", snd = "snd_mfdjx", freeze = 200, rand = true, shine = {0xffffff, 0.2}, shake = {0, 2, 100}},
	[7] = {cls = "XG_fire", snd = "snd_hit_fire", sp = "fire_ing", freeze = 200, shine = {0xFFFF67, 0.2}, shake = {0, 2, 100}},
	[8] = {cls = "XG_ice", snd = "snd_hit_ice", sp = "ice_ing", freeze = 200, shine = {0xA3E5F5, 0.2}, shake = {0, 2, 100}},
	[9] = {cls = "XG_leidian", snd = "snd_hit_dian", sp = "shock_ing", freeze = 200, shine = {0x8288D2, 0.2}, shake = {0, 2, 100}},
}
local GUARD_ENEMY = {
	[1] = {cls = "XG_fykan", snd = "snd_fykan", freeze = 50, follow = true},
	[6] = {cls = "XG_fykanx", snd = "snd_fykanx", freeze = 100, shine = {0xffffff, 0.1}, follow = true, shake = {0, 2, 100}},
	[2] = {cls = "XG_fyq", snd = "snd_def", freeze = 50, follow = true},
	[3] = {cls = "XG_fyqx", snd = "snd_defx", freeze = 100, follow = true, shine = {0xffffff, 0.1}, shake = {0, 2, 100}},
	[4] = {cls = "XG_mffy", snd = "snd_def", freeze = 50, follow = true},
	[5] = {cls = "XG_mffyx", snd = "snd_defx", freeze = 100, follow = true, shine = {0xffffff, 0.15}, shake = {0, 2, 100}},
	[7] = {cls = "XG_fire_fy", snd = "snd_defx", freeze = 100, follow = true, shine = {0xFFFF67, 0.2}, shake = {0, 2, 100}},
	[8] = {cls = "XG_ice_fy", snd = "snd_defx", freeze = 100, follow = true, shine = {0xA3E5F5, 0.2}, shake = {0, 2, 100}},
	[9] = {cls = "XG_dian_fy", snd = "snd_defx", freeze = 100, follow = true, shine = {0x8288D2, 0.2}, shake = {0, 2, 100}},
}
local HEAVY = {[3] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true}

local function isMook(f) return f and f.musouEnemy and not f.musouBoss end

-- The fighter behind a hit's owner (a fighter, or a bullet / attacker / assist's owner).
local function ownerFighter(sp)
	local f = sp
	local n = 0
	while f and f.kind ~= "fighter" and n < 4 do f, n = f.owner, n + 1 end
	return f
end

-- HitVO.isWeakHit: a light hit from a mook does not stagger.
local function weakHit(h)
	if not h.owner or HEAVY[h.hitType] or h.hurtType == 1 then return false end
	return isMook(ownerFighter(h.owner))
end

-- FighterMcHurtCtrl.doHurt / doHurtAnimate with the musou branches (instance override).
local function hurtAnimate(self, h)
	if self.alive and weakHit(h) then return end
	if isMook(self) and not self.alive then
		-- A dying mook flies a little further and higher.
		local hy = h.hity
		if hy > 0 then hy = hy + RAND() * 3 else hy = hy - 3 - RAND() * 3 end
		local hx = h.hitx + 2 + RAND() * 3
		h = setmetatable({hitx = hx, hity = hy}, {__index = h})
	end
	BVNFighter.Fighter.DoHurtAnimate(self, h)
end

-- EnemyFighterAICtrl: the mook's input and its per-animate-tick decisions.
local Mook = {}
Mook.__index = Mook

local function newMook(f)
	return setmetatable({f = f, followFrame = 0, following = false, followDis = 0, ml = false, mr = false, jmp = false,
		jmpDown = false, attackFrame = 0, atk = false, zhao = false}, Mook)
end

function Mook:Update() end
function Mook:Release() end

function Mook:Think()
	local f = self.f
	local t = f:Target()
	self.target = t
	if not t then
		self.following, self.atk, self.zhao = false, false, false
		return
	end
	-- renderFollow: every 2 s, follow at a short or long distance half the time.
	local ff = self.followFrame
	self.followFrame = ff - 1
	if ff <= 0 then
		self.followFrame = FPS * 2
		self.following = RAND() < 0.5
		if self.following then
			if RAND() > 0.6 then self.followDis = 10 + RAND() * 20 else self.followDis = 50 + RAND() * 100 end
		end
	end
	-- renderMove (the move flags stay set after following stops).
	if self.following then
		local aimX = f.x > t.x and t.x + self.followDis or t.x - self.followDis
		self.ml, self.mr = false, false
		if f.x < aimX - 20 then self.mr = true end
		if f.x > aimX + 20 then self.ml = true end
		if math.abs(f.y - t.y) < 30 then
			self.jmp, self.jmpDown = false, false
		else
			self.jmp, self.jmpDown = f.y > t.y, f.y < t.y
		end
		if not self.ml and not self.mr and not self.jmp and not self.jmpDown then self.following = false end
	end
	-- renderAttack: mid-attack keep attacking 5% of the time; otherwise roll every 3 s.
	if f:IsAttacking() then
		self.atk = RAND() < 0.05
		self.zhao = false
		return
	end
	local af = self.attackFrame
	self.attackFrame = af + 1
	if af < FPS * 3 then return end
	self.attackFrame = 0
	self.atk = RAND() < 0.2
	self.zhao = RAND() < 0.1
end

function Mook:InRange(id)
	local t = self.target
	local body = t and t:BodyArea()
	if not body then return false end
	local hr = self.f:Range(id)
	return hr ~= nil and BVNBattle.Intersects(body, hr)
end

function Mook:moveLEFT() return self.ml end
function Mook:moveRIGHT() return self.mr end
function Mook:defense() return false end
function Mook:attack() return self.atk and self:InRange("kanmian") end
function Mook:jump() return self.jmp end
function Mook:jumpQuick() return false end
function Mook:jumpDown() return self.jmpDown end
function Mook:dash() return false end
function Mook:dashJump() return false end
function Mook:skill1() return self.zhao and self:InRange("kj1mian") end
function Mook:skill2() return self.zhao and self:InRange("kj2mian") end
function Mook:zhao1() return self.zhao and self:InRange("zh1mian") end
function Mook:zhao2() return self.zhao and self:InRange("zh2mian") end
function Mook:zhao3() return self.zhao and self:InRange("zh3mian") end
function Mook:attackAIR() return self.atk and self:InRange("tkanmian") end
function Mook:skillAIR() return self.zhao and self:InRange("tzmian") end
local function no() return false end
Mook.catch1, Mook.catch2, Mook.bisha, Mook.bishaUP, Mook.bishaSUPER, Mook.bishaAIR = no, no, no, no, no, no
Mook.wankai, Mook.waiKai, Mook.waiKaiW, Mook.waiKaiS, Mook.special, Mook.ghostStep, Mook.ghostJump = no, no, no, no, no, no, no

-- EnemyBossAICtrl: FighterAICtrl without these inputs.
local BOSS_OFF = {"waiKai", "waiKaiW", "waiKaiS", "ghostStep", "ghostJump", "special", "bishaSUPER", "catch1", "catch2"}

-- FighterActionLogic's musou checks: input -> MusouFighterLogic move level.
local GATES = {skill1 = "skill1", skill2 = "skill2", skillAIR = "skillAir", zhao1 = "zhao1", zhao2 = "zhao2", zhao3 = "zhao3",
	catch1 = "catch1", catch2 = "catch2", bisha = "bisha", bishaUP = "bishaUp", bishaSUPER = "bishaSuper", bishaAIR = "bishaAir",
	ghostStep = "ghostStep", ghostJump = "ghostStep", waiKai = "bankai", waiKaiW = "bankai", waiKaiS = "bankai"}

-- SoundCtrl.playFighterBGM: true (sic) when the fighter has no music.
local function fighterBgm(info)
	local u = info and info.bgm and info.bgm.url
	if not u then return true end
	BVNSound.Music("bvn/bgm/" .. u:gsub("%.mp3$", ""))
	return false
end

-- Music played once (SoundCtrl.BGM(sound, false)).
local function musicOnce(name)
	BVNSound.music = name
	if Audio.HasClip(name) then Music.Play(name, false) else Music.Halt() end
end

BVNMusouBattle = {
	HIT_ENEMY = HIT_ENEMY,
	GUARD_ENEMY = GUARD_ENEMY,
	Battle = M,

	-- opts: {mission = BVNMusouData mission, team = {MusouFighterVO x3}, auto = CPU plays the team, aiLevel}
	New = function(opts)
		local mission = opts.mission
		local keep = {}
		local function keepId(id)
			local info = BVNMenu.FighterInfo(id)
			if info and info.urls and info.urls.file then keep[#keep + 1] = info.urls.file:gsub("%.swf$", "") end
		end
		for _, fv in ipairs(opts.team) do keepId(fv.id) end
		for _, id in ipairs(BVNMusouData.MissionEnemyIds(mission)) do keepId(id) end
		BVNRuntime.KeepCharacters(keep)
		BVNRuntime.ClearEnterFrame()
		local b = setmetatable({}, Meta)
		b.opts = opts
		b.mode, b.musou, b.training, b.arcade, b.teamMode = "musou", true, false, false, false
		b.mission = mission
		b.map = BVNBattle.LoadMap(mission.map)
		b.fx = BVNEffects.New(b)
		b:InstallEffects()
		b.tick, b.animCounter, b.animGap, b.slowRate, b.speedK = 0, 0, 1, 0, 1
		b.renderGame, b.renderHit = true, true
		b.pause, b.round, b.wins, b.score = 0, 1, {0, 0}, 0
		b.timeMax, b.time = -1, -1
		b.sprites, b.fighters, b.timers = {}, {}, {}
		b.phase, b.phaseT = "start", 0
		-- MusouCtrl.initialize / LoadingMusouStage.initGameRunData.
		b.bossCount = BVNMusouData.MissionBossCount(mission)
		b.stageEnemies, b.creators = {}, {}
		b.waveCount, b.currentWave = #mission.waves, 0
		b.runningWaves = copy(mission.waves)
		b.renderTimer, b.renderTimerMax, b.changeGap, b.resumeGap = 0, 0, 0, 0
		b.gameFinish, b.missionDone = false, false
		b.koNum = 0
		b.gameTimeMax = mission.time * FPS
		b.gameTime = b.gameTimeMax
		b.hitNum, b.hitTargets = 0, {}
		-- buildGame: the team (only the first on the stage), the stage, the interface.
		b.team = {}
		for i, fv in ipairs(opts.team) do b.team[i] = b:CreatePlayer(fv) end
		b.current = b.team[1]
		local p1 = b.current
		p1.x, p1.y, p1.dir = b.map.p1[1], b.map.p1[2], 1
		b:AddFighterSprite(p1)
		b.camFocus = {p1}
		b:InitCamera()
		b.hud = BVNMusouHud.New(b)
		-- GameStartCtrl.startMusou: actions open when the start banner completes.
		b.actionEnable = false
		b.start = true
		b.hud:ShowStart(function() b.startDone = true end)
		if RAND() < 0.7 then fighterBgm(p1.info) else b:MapMusic() end
		BVNMusouData.onLevelUp = function(fv) if BVNGame.current and BVNGame.current.battle == b then b:OnLevelUp(fv) end end
		return b
	end,
}

function M:MapMusic()
	BVNSound.Music(self.map.bgm and ("bvn/bgm/" .. self.map.bgm:gsub("%.mp3$", "")) or nil)
end

-- Effects: musou enemies use their own hit and guard tables (EffectManager).
function M:InstallEffects()
	local fx = self.fx
	local Fx = getmetatable(fx).__index
	fx.HitEffect = function(s, h, rect, target)
		if not isMook(target) then return Fx.HitEffect(s, h, rect, target) end
		local e = HIT_ENEMY[h.hitType]
		if not e then return end
		if (h.slowDown or 0) > 0 then s:SlowDown(1.5, h.slowDown * 1000) end
		if h.focusTarget and target then
			s.hitFocus = target
			self:CameraFocusOne(target)
		elseif s.hitFocus == target then
			s.hitFocus = nil
		end
		s:Play(e, rect[1] + rect[3] / 2, rect[2] + rect[4] / 2, 1, target)
	end
	fx.DefenseEffect = function(s, h, rect, defenseType, target)
		if not isMook(target) then return Fx.DefenseEffect(s, h, rect, defenseType, target) end
		local t = h.hitType
		if defenseType == 1 then
			if t == 1 then t = 2 elseif t == 6 then t = 3 end
		end
		local e = GUARD_ENEMY[t]
		if not e then return end
		local dir = (e.follow and h.owner and h.owner.dir) or 1
		s:Play(e, rect[1] + rect[3] / 2, rect[2] + rect[4] / 2, dir, target)
	end
end

-- Fighters ------------------------------------------------------------------------------------

local function characterOf(info)
	local char = BVNRuntime.Character(info.urls.file:gsub("%.swf$", ""))
	if char then char.comic_type = info.comic_type end
	return char
end

-- GameRunFactory.createFighterByMusouData + FighterMain.initMusouFighter.
function M:CreatePlayer(fv)
	local info = BVNMenu.FighterInfo(fv.id)
	local char = info and characterOf(info)
	if not char then error("BVN musou: no character " .. tostring(fv.id)) end
	local auto = self.opts.auto and true or false
	local input = BVNInput.New(1, auto)
	local ai
	if auto then
		-- FighterAICtrl: the CPU logic is the input.
		ai = BVNAI.New({}, self.opts.aiLevel or 3)
		input = ai
	end
	for name, move in pairs(GATES) do
		local orig = input[name]
		input[name] = function(k) if not fv:Can(move) then return false end return orig(k) end
	end
	local f = BVNFighter.New(self, char, info.start_frame or 1, 1, input)
	f.info, f.kind, f.team = info, "fighter", 1
	f.musouPlayer = fv
	f.DoHurtAnimate = hurtAnimate
	if ai then ai.f = f; f.ai = ai end
	self:UpdateProperties(f)
	f.active = false
	return f
end

-- FighterMain.updateProperties: HP, qi and energy from the level, all full.
function M:UpdateProperties(f)
	local fv = f.musouPlayer
	if not fv then return end
	f.hp, f.hpMax = fv.hp, fv.hp
	f.qiMax = fv.qi
	f.energy, f.energyMax = fv.energy, fv.energy
	f.qi = f.qiMax
	BVNMusouData.InitAttackAddDmg(f, fv.atk, fv.skillAtk, fv.bishaAtk)
end

-- GameRunFactory.createEnemyByData + MusouCtrl.addEnemyFighter.
function M:AddEnemy(data)
	local info = BVNMenu.FighterInfo(data.fighterID)
	local char = info and BVNMenu.Available(data.fighterID) and characterOf(info)
	if not char then
		Debug.Log("BVN musou: enemy not available: " .. tostring(data.fighterID))
		return nil
	end
	local input = data.isBoss and BVNAI.New({}, 2) or nil
	local f = BVNFighter.New(self, char, info.start_frame or 1, 2, input or {Update = function() end})
	f.info, f.kind, f.team = info, "fighter", 2
	f.musouEnemyData, f.musouEnemy, f.musouBoss = data, true, data.isBoss
	f.DoHurtAnimate = hurtAnimate
	if data.isBoss then
		for _, n in ipairs(BOSS_OFF) do input[n] = no end
		input.f = f
		f.ai = input
	else
		f.input = newMook(f)
		f.ai = f.input
	end
	BVNMusouData.InitEnemyProps(f, data, self.mission.enemyLevel)
	self.stageEnemies[#self.stageEnemies + 1] = f
	-- addEnemyFighter: 100..200 px to either side of the player and 50..100 above or below.
	local p1 = self.current
	local disX, disY = 100 + RAND() * 100, 50 + RAND() * 50
	f.x = RAND() > 0.5 and p1.x + disX or p1.x - disX
	f.y = RAND() > 0.5 and p1.y + disY or p1.y - disY
	-- EffectCtrl.enemyBirthEffect.
	f.fade = nil
	self.fx:Effect((char.comic_type or 0) == 0 and "fz_bleach" or "fz_naruto", f.x, f.y, f.dir, nil, false)
	self:AddFighterSprite(f)
	-- FighterEvent.BIRTH -> MusouFighterEventCtrl.onEnemyBirth.
	if data.isBoss then self:OnBossBirth(f) end
	self:UpdateEnemy(f)
	return f
end

function M:AddFighterSprite(f)
	f.active, f.removed = true, nil
	if not indexOf(self.sprites, f) then self.sprites[#self.sprites + 1] = f end
	if not indexOf(self.fighters, f) then self.fighters[#self.fighters + 1] = f end
end

-- GameCtrl.removeFighter: off the stage at once; the sprite list drops it after the tick.
function M:RemoveFighterSprite(f)
	f.active, f.removed = false, true
	removeValue(self.fighters, f)
	self.fx:EndShadow(f)
end

function M:IsOnStage(f) return f.active == true end

-- FighterMain.getCurrentTarget: keep the target while it lives on the stage; else the
-- first fighter (boss or player) of the other team, then the first mook.
function M:TargetOf(sp)
	local f = ownerFighter(sp)
	if not f or not f.team then return nil end
	local cur = f.musouTarget
	if cur and cur.alive and cur.active then return cur end
	local best, bestOrder = nil, math.huge
	for _, o in ipairs(self.fighters) do
		if o.team ~= f.team and o.alive and o.active then
			local order
			if not o:RawBody() then order = 5 elseif isMook(o) then order = 1 else order = 0 end
			if order < bestOrder then best, bestOrder = o, order end
		end
	end
	f.musouTarget = best
	return best
end

-- Fighter events (MusouFighterEventCtrl) ------------------------------------------------------

function M:OnIdle(f)
	if f.state == 60 then f.state = 0 end
	if f.musouEnemy then self:RemoveHitTarget(f) end
end

function M:OnHurtResume(f)
	if f.musouEnemy then self:RemoveHitTarget(f) end
end

function M:OnDie(f)
	if f.team == 1 then
		self:OnSelfDie(f)
	else
		self:RemoveHitTarget(f)
		if f.musouBoss then self:OnBossDie(f) end
	end
end

function M:OnDead(f)
	if f.team == 1 then self:OnSelfDead(f) else self:OnEnemyDead(f) end
end

-- DO_SPECIAL: the assist key switches to the next living team member.
function M:DoSpecial(f)
	if f.team ~= 1 then return end
	self:ChangeNextFighter()
end

function M:CallAssist() return false end

function M:AliveTeam()
	local out = {}
	for _, f in ipairs(self.team) do if f.alive then out[#out + 1] = f end end
	return out
end

function M:ChangeNextFighter()
	local alive = self:AliveTeam()
	if #alive < 2 then return false end
	local i = indexOf(alive, self.current)
	local nextF = (not i or i == #alive) and alive[1] or alive[i + 1]
	self:ChangeFighter(self.current, nextF)
	return true
end

-- MusouCtrl.changeFighter: once per second at most.
function M:ChangeFighter(from, to)
	if self.changeGap > 0 then return end
	self:RemoveFighterSprite(from)
	to.x, to.y = from.x, from.y
	to.fzqi = to.fzqiMax
	to.dir = from.dir
	self:AddFighterSprite(to)
	self.current = to
	self.changeGap = FPS
	self.hud:UpdateFighter()
	self.fx:Effect("team_change", to.x, to.y)
	self:UpdateCameraFocus()
end

function M:UpdateEnemy(f) self.hud:UpdateEnemyBar(f) end

function M:OnEnemyDead(f)
	self.koNum = self.koNum + 1
	local d = f.musouEnemyData
	BVNMusouData.AddMoney(BVNMusouData.EnemyMoney(d))
	BVNMusouData.AddFighterExp(BVNMusouData.EnemyExp(d))
	if d.isBoss then
		self:OnBossDead(f)
		self.hud:UpdateBossHp()
		return
	end
	self.fx:RemoveEnemy(f, function() self:RemoveEnemy(f) end)
end

function M:RemoveEnemy(enemy)
	removeValue(self.stageEnemies, enemy)
	self:RemoveFighterSprite(enemy)
	self:CheckNextOrWin(false)
end

-- MusouLogic.addHits / removeHitTarget: the hit counter over every target in hit-stun.
function M:AddHits(target)
	if not indexOf(self.hitTargets, target) then self.hitTargets[#self.hitTargets + 1] = target end
	self.hitNum = self.hitNum + 1
	if self.hitNum > 1 then self.hud:ShowHits(self.hitNum) end
	return self.hitNum
end

function M:RemoveHitTarget(target)
	if not removeValue(self.hitTargets, target) then return end
	if #self.hitTargets < 1 then
		self.hitNum = 0
		self.hud:HideHits()
	end
end

-- Player death, time over, mission complete -------------------------------------------------

function M:OnSelfDie(f)
	self.actionEnable = false
	self.phase = "end"
	self.fx:Effect("hit_end", f.x, f.y)
	self.fx:Shine(0xff0000, 0.8)
	self:CameraFocusOne(f)
	self.fx:SlowDown(2, 5000)
end

function M:OnSelfDead()
	self.gameFinish = true
	self.hud:ShowLose(function() self:BackToWorldMap("lose") end)
end

function M:OnTimeOver()
	self.actionEnable = false
	self.phase = "end"
	self.timeOver = true
	self.hud:ShowLose(function() self:BackToWorldMap("lose") end)
end

function M:MissionComplete()
	if self.missionDone then return end
	self.gameFinish, self.missionDone = true, true
	self.runningWave = nil
	self.phase = "end"
	musicOnce("bvn/bgm/win")
	self.actionEnable = false
	self.hud:ShowWin(function()
		BVNMusouData.PassMission(self.mission)
		self:BackToWorldMap("win")
	end)
end

-- MusouUI.showWin's camera and the winner's pose a second in.
function M:WinPose()
	local p1 = self.current
	self:CameraFocusOne(p1)
	self:After(60, function()
		if p1.alive then
			p1.state = 61
			if p1:HasLabel("胜利") then p1:GoFrame("胜利", true) end
		end
	end)
end

-- backToWorldMap: BVNGame covers the screen and opens the world map.
function M:BackToWorldMap(result)
	self.result = result
	self.phase, self.phaseT = "over", 0
end

function M:CanPause() return not self.start and not self.gameFinish end

-- Bosses ----------------------------------------------------------------------------------------

function M:BossEnemies(aliveOnly)
	local out = {}
	for _, f in ipairs(self.stageEnemies) do
		if f.musouBoss and (not aliveOnly or f.alive) then out[#out + 1] = f end
	end
	return out
end

function M:AliveEnemies()
	local out = {}
	for _, f in ipairs(self.stageEnemies) do
		if not f.musouEnemyData.rep and f.alive then out[#out + 1] = f end
	end
	return out
end

function M:EnemyByData(d)
	for _, f in ipairs(self.stageEnemies) do if f.musouEnemyData == d then return f end end
	return nil
end

-- onBossBirth: the game holds while the boss lands, says its intro and the warning plays.
function M:OnBossBirth(f)
	self.actionEnable = false
	self.introBoss = f
	f:FaceTarget()
	self:CameraFocusOne(f)
	self.hud:SetBossHp(f)
	self.bossInAnimate = true
	BVNSound.Music(nil)
	self.hud:ShowBossIn(function()
		self.bossInAnimate = false
		local played = false
		if RAND() < 0.5 then played = fighterBgm(f.info) end
		if not played then
			local naruto = (f.char.comic_type or 0) == 1
			BVNSound.Music(naruto and "bvn/bgm/narutoboss" or "bvn/bgm/bleachboss")
		end
	end)
end

function M:RenderBossIn()
	local f = self.introBoss
	if not f then return end
	if not f.introSaid then
		if not f.inAir then
			f.introSaid = true
			f.introT = 0
			if f:HasLabel("开场") then
				f.state = 60
				f:GoFrame("开场", true)
			end
		end
		return
	end
	if f.state == 60 then
		f.introT = (f.introT or 0) + 1
		if f.introT > 300 then f:Idle() end
	end
	if not self.bossInAnimate and f.state ~= 60 then
		self.introBoss = nil
		self.actionEnable = true
		self:UpdateCameraFocus()
	end
end

-- MusouUI.showBossKO: the KO stop, slow motion, then "BOSS KO".
function M:OnBossDie(boss)
	local fx = self.fx
	fx:Effect("hit_end", boss.x, boss.y)
	fx:Shine(0xffffff, 0.5)
	self:CameraFocusOne(boss)
	fx.freezeEnabled = false
	fx.freeze = 0
	self:PauseGame()
	local p1 = self.current
	local bsKO = p1.state == 12 or p1.state == 13
	if bsKO then
		local v = fx:Effect("kobg")
		if v then v.hold = 2 * FPS end
	end
	fx:SlowDown(2, 5000)
	fx:Shake(5, 0, 1.5)
	BVNSound.Play(BVNFxData.sounds.snd_over_hit or "heavy", 128)
	self:After(60, function()
		self.hud:PlayStartKO("boss_ko", function()
			fx.freezeEnabled = true
			self:ResumeGame()
		end)
		BVNSound.Play(BVNFxData.sounds[bsKO and "snd_ko_bs" or "snd_ko"] or "ko", 128)
	end)
end

function M:OnBossDead()
	self:UpdateCameraFocus()
	self:CheckNextOrWin(true)
end

-- FighterMain.die: the remaining mooks fall when the last boss dies.
function M:KillEnemy(m)
	m.hp = 0
	m.alive = false
	if not m:IsHurting() and m.state ~= 30 then m:PlayHurtDown() end
end

function M:CheckNextOrWin(onBossDie)
	local alive = self:AliveEnemies()
	if #self.runningWaves > 0 then
		if #alive < 1 and self.renderTimer > 2 * FPS then self.renderTimer = 2 * FPS end
		return
	end
	if onBossDie then
		if #self:BossEnemies(true) < 1 then
			for _, m in ipairs(alive) do self:KillEnemy(m) end
			self:MissionComplete()
		end
		return
	end
	if #alive < 1 then self:MissionComplete() end
end

-- Level up (GameEvent.LEVEL_UP): the fighter on the stage refills and shows the effect.
function M:OnLevelUp(fv)
	local p1 = self.current
	if not p1 or p1.musouPlayer ~= fv then return end
	self:UpdateProperties(p1)
	local newAct = indexOf(BVNMusouData.ALL_ACTION_LEVELS, fv.level) ~= nil
	self.fx:Effect(newAct and "level_up_new_act" or "level_up", p1.x, p1.y)
end

-- MusouCtrl.renderAnimate -----------------------------------------------------------------------

function M:RenderMusou()
	self:RenderBossIn()
	if not self.actionEnable then return end
	-- renderWave: `if (_renderTimer-- < 0) nextWave()`.
	if #self.runningWaves > 0 then
		local t = self.renderTimer
		self.renderTimer = t - 1
		if t < 0 then self:NextWave() end
	end
	if self.runningWave and self.runningWave.repeats then
		for _, r in ipairs(self.runningWave.repeats) do self:RenderRepeat(r) end
	end
	-- renderAddEnemy: one enemy per animate tick.
	local c = self.creators[1]
	if c then
		local ev = table.remove(c, 1)
		if ev then self:AddEnemy(ev) else table.remove(self.creators, 1) end
	end
	if self.gameTime > 0 then
		self.gameTime = self.gameTime - 1
		if self.gameTime <= 0 then
			self.gameTime = 0
			self:OnTimeOver()
		end
	end
	self:RenderResumeFighters()
	if self.changeGap > 0 then self.changeGap = self.changeGap - 1 end
end

function M:NextWave()
	local wave = table.remove(self.runningWaves, 1)
	if not wave then return end
	self.runningWave = wave
	self.currentWave = self.currentWave + 1
	self.renderTimerMax = wave.hold * FPS
	self.renderTimer = self.renderTimerMax
	if wave.enemies then self.creators[#self.creators + 1] = copy(wave.enemies) end
end

-- Repeats: type 0 every `hold` seconds; type 1 brings back its dead (or never born) enemies.
function M:RenderRepeat(r)
	if not r.enemies or #r.enemies < 1 then return end
	if r.holdFrame > 0 then
		r.holdFrame = r.holdFrame - 1
		return
	end
	r.holdFrame = FPS * r.hold
	local result
	if r.type == 1 then
		result = {}
		for _, d in ipairs(r.enemies) do
			local f = self:EnemyByData(d)
			if not f or not f.alive or not f.active then result[#result + 1] = d end
		end
	else
		result = r.enemies
	end
	if #result > 0 then self.creators[#self.creators + 1] = copy(result) end
end

-- The waiting team members regain 1% HP, 2% qi and 8% energy every second.
function M:RenderResumeFighters()
	local g = self.resumeGap
	self.resumeGap = g - 1
	if g > 0 then return end
	for _, f in ipairs(self:AliveTeam()) do
		if f ~= self.current then
			if f.hp < f.hpMax then f.hp = math.min(f.hpMax, f.hp + f.hpMax * 0.01) end
			if f.qi < f.qiMax then f.qi = math.min(f.qiMax, f.qi + f.qiMax * 0.02) end
			if f.energy < f.energyMax then f.energy = math.min(f.energyMax, f.energy + f.energyMax * 0.08) end
		end
	end
	self.resumeGap = FPS
end

function M:WavePercent()
	if self.currentWave >= self.waveCount then return 1 end
	if self.renderTimerMax < 1 then return 0 end
	return 1 - self.renderTimer / self.renderTimerMax
end

-- KyoTimeout.setTimeout: ticks of the 60 Hz game clock; they run while the game is paused.
function M:After(ticks, fn) self.timers[#self.timers + 1] = {n = ticks, fn = fn} end

function M:RenderTimers()
	local list = self.timers
	for i = #list, 1, -1 do
		local t = list[i]
		t.n = t.n - 1
		if t.n <= 0 then
			table.remove(list, i)
			t.fn()
		end
	end
end

-- Camera ------------------------------------------------------------------------------------------

function M:InitCamera()
	local m = self.map
	local c = {zoom = 2, ss = 2, tween = 5, offY = m.bottom - m.playerBottom}
	self.cam = c
	c.focus = self.camFocus
	c.nx, c.ny = self:CamClamp(-((m.stageW / 2) * 2 - 350), -(m.bottom - 200), 2)
	c.rx, c.ry = c.nx, c.ny
end

-- MusouCtrl.updateCamera / GameStage.updateCameraFocus: the player and the first living boss.
function M:UpdateCameraFocus()
	local focus = {self.current}
	local boss = self:BossEnemies(true)[1]
	if boss then focus[2] = boss end
	self.camFocus = focus
	local c = self.cam
	c.focus = focus
	c.zoom = 2
	c.tween = 5
end

function M:CameraResume()
	local c = self.cam
	c.focus = self.camFocus
	if #self.camFocus < 2 then c.zoom = 2 end
	c.tween = 5
end

-- Tick ---------------------------------------------------------------------------------------------

function M:Update()
	self.tick = self.tick + 1
	for _, f in ipairs(self.fighters) do f.input:Update(self.actionEnable) end
	BVNRuntime.EnterFrame()
	self.fx:Render()
	self:UpdateCamera()
	self.hud:Render()
	self:RenderTimers()
	local tw = self.transWait
	if tw then
		tw.t = tw.t - 1
		if tw.t <= 0 then self.transWait = nil; tw.cb() end
	end
	self.phaseT = self.phaseT + 1
	if not self.renderGame then
		local bs = self.bisha
		if bs then
			bs.t = bs.t + 1
			if bs.t > 900 then self:EndBisha(bs.f) end
		end
		return
	end
	if self.pause > 0 then self.pause = self.pause - 1 return end
	local animate = false
	if self.animCounter >= self.animGap then
		self.animCounter = 0
		animate = true
	else
		self.animCounter = self.animCounter + 1
	end
	local k = self.slowRate > 0 and 1 / self.slowRate or 1
	self.speedK = k
	for _, sp in ipairs(self.sprites) do sp.speedPlus, sp.dampingRate = 0.5 * k, k end
	if self.start then self.actionEnable = false end
	if animate then
		self:RenderMusou()
		for _, f in ipairs(self.fighters) do if f.ai then f.ai:Think() end end
	end
	local list = self.sprites
	local n = #list
	for i = 1, n do
		local sp = list[i]
		if not sp.dead and not sp.removed then
			if sp.kind == "fighter" then
				self:FixPosition(sp)
				local air = self:IsInAir(sp)
				if air then sp:ApplyG(12) end
				sp:SetInAir(air)
			end
			sp:Render()
			if animate and not sp.dead and not sp.removed then sp:RenderAnimate() end
		end
	end
	if self.renderHit then
		self:Push()
		if animate then self:CheckHits() end
	end
	for i = #list, 1, -1 do
		if list[i].dead or list[i].removed then table.remove(list, i) end
	end
	if self.start and self.startDone then
		self.start = nil
		self.actionEnable = true
		self.phase, self.phaseT = "fight", 0
	end
	-- FighterEvent.HURT_DOWN: the target leaves the hit counter.
	for _, f in ipairs(self.fighters) do
		if f.musouEnemy and f.state == 23 and f.musouLastState ~= 23 then self:RemoveHitTarget(f) end
		f.musouLastState = f.state
	end
end

-- GameMainLogicCtrl.checkBodyHit between the teams.
function M:PushPair(a, b)
	if a.isCross or b.isCross then return end
	local ra, rb = a:RawBody(), b:RawBody()
	if not ra or not rb then return end
	local o = overlap(ra, rb)
	if not o then return end
	if b.x < a.x then a, b = b, a end
	if (a.vx < 0 and a.vx < b.vx) or (b.vx > 0 and b.vx > a.vx) then return end
	local function split(rate)
		if a.touchSide and b.touchSide then return 1, 1 end
		if a.touchSide then return 0, 1 end
		if b.touchSide then return 1, 0 end
		return rate, 1 - rate
	end
	local ka, kb = split(clamp(b.heavy / a.heavy * 0.5, 0.1, 0.9))
	if o[3] > 2 then
		local push = 5 * a.speedPlus
		a:Move(-push * ka, 0)
		b:Move(push * kb, 0)
	end
	if a.vx ~= 0 then b:Move(a.vx * kb, 0); a:Move(-a.vx * ka, 0) end
	if b.vx ~= 0 then a:Move(b.vx * ka, 0); b:Move(-b.vx * kb, 0) end
end

function M:Push()
	local p1 = self.current
	if not p1 or not p1.active then return end
	for _, f in ipairs(self.fighters) do
		if f.team ~= p1.team and f.active then self:PushPair(p1, f) end
	end
end

-- GameMainLogicCtrl.checkHit for every pair of opposing sprites, plus the musou events
-- (HIT_TARGET -> addHits, HURT / DEFENSE -> the enemy's bar).
function M:CheckHits()
	local list = self.sprites
	local found = {}
	for i = 1, #list do
		for j = 1, #list do
			local A, B = list[i], list[j]
			if A ~= B and A.team ~= B.team and not A.dead and not B.dead and not A.removed and not B.removed then
				if math.abs(A.x - B.x) <= 600 and math.abs(A.y - B.y) <= 600 then
					local body = B:BodyArea()
					if body then
						for _, hr in ipairs(A:CurrentHits()) do
							local o = overlap(hr[2], body)
							if o then
								found[#found + 1] = {A, B, hr[1], o}
								break
							end
						end
					end
				end
			end
		end
	end
	for _, hit in ipairs(found) do
		local A, B, h, o = hit[1], hit[2], hit[3], hit[4]
		if B.kind == "fighter" then
			local accepted = B.allowBeHit
			B:BeHit(h, o)
			if accepted and B.musouEnemy then self:UpdateEnemy(B) end
			local f = ownerFighter(A)
			if f and f.team == 1 and (B.state == 21 or B.state == 22) then self:AddHits(B) end
		else
			B:BeHit(h, o, A)
		end
		if A.kind == "fighter" then
			if not BVNFighter.IsBisha(h) then A:AddQi(math.min(h.power * 0.17, 15)) end
		elseif A.OnHit then
			A:OnHit(B, h)
		end
	end
end

-- Drawing --------------------------------------------------------------------------------------------

function M:Draw()
	local c = self.cam
	local s = c.ss
	local zoom = 1.2 * s
	local cx, cy = c.rx + 400 / s, c.ry + 300 / s
	local m = self.map
	local hw = SW / 2 / zoom
	if m.stageW >= hw * 2 then cx = clamp(cx, hw, m.stageW - hw) else cx = m.stageW / 2 end
	local sx, sy = self.fx:ShakeOffset()
	cx, cy = cx - sx / s, cy - sy / s
	Camera.SetZoom(zoom)
	Camera.SetPosition(cx / 100, cy / 100)
	self.view = {x = cx - hw, y = cy - SH / 2 / zoom, w = hw * 2, h = SH / zoom, zoom = zoom}
	local L = m.layers
	self.fx:DrawBack()
	if self.fx:MapVisible() then
		local tint = math.floor(255 * self.fx.darkMul)
		if L.bg then
			local k = math.max(SW / L.bg.w, SH / L.bg.h)
			self:ScreenImage(L.bg.img, SW / 2 - 400 * k + sx * 1.2, SH / 2 - 300 * k + sy * 1.2, k, k, tint, tint, tint, 255, 0)
		end
		if L.map then self:DrawLayerImage(L.map.img, L.map.x, L.map.y, L.map.sx, L.map.sy, tint, 255, 2) end
		local v = self.view
		if v.x < 0 then D.Rect(v.x - 10, v.y - 10, -v.x + 10, v.h + 20, BLACK, 255, 3) end
		if v.x + v.w > m.stageW then D.Rect(m.stageW, v.y - 10, v.x + v.w - m.stageW + 10, v.h + 20, BLACK, 255, 3) end
	end
	self.fx:DrawShadows(15)
	-- The player above the enemies; attacking enemies above the others; an ultimate's owner on top.
	for _, f in ipairs(self.fighters) do
		local order = 20
		if f.team == 1 then order = 40 elseif f:IsAttacking() then order = 30 end
		if self.bisha and self.bisha.f == f then order = 44 end
		self:DrawFighter(f, order)
	end
	for _, sp in ipairs(self.sprites) do
		if sp.kind ~= "fighter" and not sp.dead and sp.clip then sp:Draw(sp.drawUnder and 12 or (sp.kind == "assist" and 30 or 60)) end
	end
	self.fx:Draw()
	if self.debugBoxes then
		for _, sp in ipairs(self.sprites) do
			if not sp.dead and not sp.removed then
				local r = sp.RawBody and sp:RawBody()
				if r then D.Rect(r[1], r[2], r[3], r[4], {0, 255, 0}, 90, 95) end
				for _, h in ipairs(sp:CurrentHits()) do D.Rect(h[2][1], h[2][2], h[2][3], h[2][4], {255, 0, 0}, 90, 96) end
			end
		end
	end
	if self.fx:MapVisible() then
		local fdx = -c.rx * 0.1
		local fdy = math.max(0, (m.bottom - c.ry) * 0.1)
		local tint = math.floor(255 * self.fx.darkMul)
		self:DrawFront(L.front_fix, 0, 0, tint)
		self:DrawFront(L.front, fdx, fdy, tint)
	end
	self.hud:DrawWorld()
	self.hud:Draw(sx, sy)
	self.fx:DrawScreen()
end

-- Agent observation of the mission.
function M:Observe()
	local function fighter(f)
		return {id = f.info.id, hp = f.hp, hpMax = f.hpMax, qi = f.qi, energy = f.energy, x = f.x, y = f.y, state = f.state,
			alive = f.alive, label = f:CurLabel(), level = f.musouPlayer and f.musouPlayer.level or nil,
			boss = f.musouBoss or nil}
	end
	local team, enemies = {}, {}
	for i, f in ipairs(self.team) do team[i] = fighter(f) end
	for _, f in ipairs(self.stageEnemies) do enemies[#enemies + 1] = fighter(f) end
	return {phase = self.phase, result = self.result, mission = self.mission.id, area = self.mission.area and self.mission.area.id,
		map = self.map.id, wave = self.currentWave, waves = self.waveCount, wavePercent = self:WavePercent(),
		pendingWaves = #self.runningWaves, time = math.floor(self.gameTime / FPS), ko = self.koNum, hits = self.hitNum,
		current = indexOf(self.team, self.current), team = team, enemies = enemies, aliveEnemies = #self:AliveEnemies(),
		bosses = #self:BossEnemies(true), actionEnable = self.actionEnable, money = BVNMusouData.Money(),
		sprites = #self.sprites, freeze = self.fx.freeze, renderGame = self.renderGame}
end
