-- One match: the GameCtrl tick order, hit and push detection, camera, map,
-- hit-stop / slow motion / bisha pauses, rounds and the HUD. Not attached to
-- any actor; BVNGame owns the current battle.
local D = setmetatable({}, {__index = function(_, k) return BVNDraw[k] end})
local WHITE, BLACK = {255, 255, 255}, {0, 0, 0}
local SW, SH = 1280, 720

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local Battle = {}
Battle.__index = Battle

-- Battle is exposed so other match types (musou) can inherit its methods.
BVNBattle = {Battle = Battle}

function BVNBattle.Intersects(a, b)
	return a[1] < b[1] + b[3] and b[1] < a[1] + a[3] and a[2] < b[2] + b[4] and b[2] < a[2] + a[4]
end

local function overlap(a, b)
	local x0, y0 = math.max(a[1], b[1]), math.max(a[2], b[2])
	local x1, y1 = math.min(a[1] + a[3], b[1] + b[3]), math.min(a[2] + a[4], b[2] + b[4])
	if x1 <= x0 or y1 <= y0 then return nil end
	return {x0, y0, x1 - x0, y1 - y0}
end

-- Map ---------------------------------------------------------------------------------

local function loadMap(id)
	local m = BVNMaps[id]
	local bottom = m.line_bottom and m.line_bottom[2] or 600
	local off = 600 - bottom
	local map = {id = id, layers = {}, off = off}
	map.left = m.line_left and m.line_left[1] or 0
	local mw = m.layers.map and m.layers.map.w or 800
	map.right = m.line_right and m.line_right[1] or mw
	map.bottom = 600
	map.playerBottom = (m.line_player_bottom and m.line_player_bottom[2] or bottom) + off
	map.p1 = m.p1 and {m.p1[1], m.p1[2] + off} or {map.left + (map.right - map.left) * 0.35, map.playerBottom}
	map.p2 = m.p2 and {m.p2[1], m.p2[2] + off} or {map.left + (map.right - map.left) * 0.65, map.playerBottom}
	map.floors = {}
	for _, fl in ipairs(m.floors or {}) do map.floors[#map.floors + 1] = {fl[1], fl[2], fl[3] + off} end
	for name, l in pairs(m.layers) do
		local parts
		if l.parts then
			parts = {}
			for _, p in ipairs(l.parts) do
				parts[#parts + 1] = {img = p.img, x = p.x, y = p.y + off, sx = p.sx, sy = p.sy, w = p.w, h = p.h, clip = p.clip}
			end
		end
		map.layers[name] = {img = l.img, x = l.x, y = l.y + (name == "bg" and 0 or off), w = l.w, h = l.h, sx = l.sx, sy = l.sy, parts = parts}
	end
	-- GameStage stage size: the map layer's width.
	local ml = m.layers.map
	map.stageW = ml and ml.w * (ml.sx or 1) or 800
	for _, d in ipairs(BVNConfig.map.map.data) do
		if d.id == id then map.name, map.bgm = d.name, d.bgm end
	end
	return map
end
BVNBattle.LoadMap = loadMap -- musou: BVNMusouBattle builds its stage from the same map data

-- Construction ---------------------------------------------------------------------------

-- opts: {p1 = {team, fighter, assist, cpu, noAI, attackRate}, p2 = {...}, map = id, mode, level,
-- time (seconds, -1 = no limit), fighterHP (config multiplier), hpRate (arcade stage), bgm}
function BVNBattle.New(opts)
	-- Keep only this match's characters in memory.
	local keep = {}
	for side = 1, 2 do
		local p = opts["p" .. side]
		p.team = p.team or {p.fighter}
		for _, id in ipairs(p.team) do
			local info = BVNMenu.FighterInfo(id)
			if info then keep[#keep + 1] = info.urls.file:gsub("%.swf$", "") end
		end
		local a = p.assist and BVNMenu.AssistInfo(p.assist)
		if a then keep[#keep + 1] = "fz_" .. a.urls.file:gsub("%.swf$", "") end
	end
	BVNRuntime.KeepCharacters(keep)
	BVNRuntime.ClearEnterFrame()
	local b = setmetatable({}, Battle)
	-- The stage's map layer as scripts see it: a solid bitmap added over the backdrop is mapFill.
	b.mapLayer = {
		addChildAt = function(_, bmp) b.mapFill = bmp and bmp.bitmapData or nil end,
		addChild = function(_, bmp) b.mapFill = bmp and bmp.bitmapData or nil end,
		removeChild = function() b.mapFill = nil end,
	}
	b.opts = opts
	b.mode = opts.mode
	b.training = opts.mode == "training"
	b.survivor = opts.mode == "survivor"
	b.arcade = opts.mode == "arcade" or b.survivor
	b.score = opts.score or 0
	b.map = loadMap(opts.map)
	b.fx = BVNEffects.New(b)
	b.tick, b.animCounter, b.animGap = 0, 0, 1
	b.slowRate = 0
	b.renderGame, b.renderHit = true, true
	b.wins = {0, 0}
	b.round = 1
	b.fighters = {}
	b.teamMode = #opts.p1.team > 1 or #opts.p2.team > 1
	b.teamIndex = {1, 1}
	-- GameLogic.resetFighterHP: hpMax = 1000 * config fighterHP * the arcade stage's hp_rate, both fighters, every round.
	b.hpRate = (opts.hpRate or 1) * (opts.fighterHP or 1)
	b.timeMax = b.training and -1 or (opts.time or 60)
	for side = 1, 2 do
		local f = b:CreateFighter(side, opts["p" .. side].team[1])
		-- GameStage.initFight: the stage's attack_rate applies once, to the first P2 fighter.
		if opts["p" .. side].attackRate then f:SetAttackRate(opts["p" .. side].attackRate) end
		b.fighters[side] = f
	end
	b:SameFighterColor()
	b:InitCamera()
	b:StartRound(-1)
	return b
end

function Battle:CreateFighter(side, id)
	local p = self.opts["p" .. side]
	local info = BVNMenu.FighterInfo(id)
	local char = BVNRuntime.Character(info.urls.file:gsub("%.swf$", ""))
	char.comic_type = info.comic_type
	local input = BVNInput.New(side, p.cpu)
	local f = BVNFighter.New(self, char, info.start_frame or 1, side, input)
	f.info = info
	f.kind = "fighter"
	f.baseHpMax = f.hpMax
	-- FighterAICtrl: the CPU logic is the fighter's input.
	if p.cpu and not p.noAI then
		f.ai = BVNAI.New(f, p.level or self.opts.level or 1)
		f.input = f.ai
	end
	if p.assist then
		local ainfo = BVNMenu.AssistInfo(p.assist)
		local achar = ainfo and BVNRuntime.Character("fz_" .. ainfo.urls.file:gsub("%.swf$", ""))
		if achar then
			achar.comic_type = ainfo.comic_type
			f.assist = BVNBullet.Assist(self, f, achar)
			f.assistInfo = ainfo
		end
	end
	return f
end

-- GameSpriteUtil.autoChangeSpColor: in a mirror match P2 (and its sprites) is tinted (green offset -85).
function Battle:SameFighterColor()
	local a, b = self.fighters[1], self.fighters[2]
	self.sameFighter = a.info.id == b.info.id
	self.sameAssist = a.assistInfo and b.assistInfo and a.assistInfo.id == b.assistInfo.id
	b.colorBase = self.sameFighter and {0, -85, 0} or nil
	b.color = b.colorBase
	if b.assist then b.assist.color = self.sameAssist and {0, -85, 0} or nil end
end

-- Team mode: the loser's next member enters (GameRoundCtrl.nextFighter).
-- Returns false when that team has nobody left.
function Battle:NextMember(side)
	local team = self.opts["p" .. side].team
	local i = self.teamIndex[side] + 1
	if i > #team then return false end
	-- A fresh FighterMain: qi 0, energy and fzqi full; the same series inherits the last loser's qi + 100.
	local f = self:CreateFighter(side, team[i])
	local ld = self.lastLoser
	if ld and ld.comic == (f.char.comic_type or 0) then f.qi = math.min(f.qiMax, ld.qi + 100) end
	self.teamIndex[side] = i
	self.fighters[side] = f
	self:SameFighterColor()
	return true
end

function Battle:HasNextMember(side) return self.teamIndex[side] < #self.opts["p" .. side].team end

function Battle:TargetOf(sp)
	local f = sp.kind == "fighter" and sp or sp.owner
	if not f or not f.side then f = f and f.owner end
	if not f then return nil end
	return self.fighters[3 - f.side]
end

-- GameStage.resetFight + GameStartCtrl. introTeam: -1 both, 1 / 2 one side, 0 none (next round).
function Battle:StartRound(introTeam)
	self.sprites = {}
	self.mapFill = nil
	for side, f in ipairs(self.fighters) do
		local p = side == 1 and self.map.p1 or self.map.p2
		f.x, f.y = p[1], p[2]
		f.dir = side == 1 and 1 or -1
		f.hpMax = (f.baseHpMax or 1000) * self.hpRate
		if not (self.teamMode and f.keepHp) then f.hp = f.hpMax end
		f.keepHp = nil
		f.alive = true
		f:SetVelocity(0, 0)
		f.allowLoseHP = false
		f.combo = 0
		f.inAir, f.touchBottom, f.isTouchFloor = false, true, true
		f.fmc.hurtFly, f.ghost = 0, nil
		f.explodeHit, f.explodeHitFrame, f.explodeSteelFrame = nil, 0, 0
		f.frameOut, f.delayCalls = {}, {}
		f.color = f.colorBase
		self.sprites[#self.sprites + 1] = f
		f:Idle()
	end
	self.time = self.timeMax
	self.timeFrame = 0
	self.actionEnable = false
	self.phase, self.phaseT = "intro", 0
	self.banner = nil
	self.winner, self.loser = nil, nil
	self.ko, self.endCtrl = nil, nil
	self.timeOver = false
	self.pause = 0
	self.bisha = nil
	self.winsShown = {self.wins[1], self.wins[2]}
	self.renderGame, self.renderHit = true, true
	self.fx:Reset()
	self:CameraResume()
	self.start = {introTeam = introTeam, step = introTeam == 0 and 5 or 0, hold = 0}
	if introTeam == 1 then self:CameraFocusOne(self.fighters[1]); self.start.step = 1
	elseif introTeam == 2 then self:CameraFocusOne(self.fighters[2]); self.start.step = 2 end
	local bgmOf = introTeam == 1 and self.fighters[1] or self.fighters[2]
	if introTeam ~= 0 or self.round == 1 then BVNSound.Music(self:MusicFor(bgmOf)) end
	self:Trans("Out")
end

-- SoundCtrl.smartPlayGameBGM: the fighter's theme with its rate, else the stage's.
function Battle:MusicFor(f)
	if self.opts.bgm then return self.opts.bgm end
	local info = f and f.info
	if info and info.bgm and info.bgm.url and (info.bgm.rate or 0) > 0 and BVNRuntime.RAND() <= info.bgm.rate / 100 then
		return "bvn/bgm/" .. info.bgm.url:gsub("%.mp3$", "")
	end
	return self.map.bgm and ("bvn/bgm/" .. self.map.bgm:gsub("%.mp3$", "")) or nil
end

-- StateCtrl.transIn / transOut (BVNTrans). A transition that never reports back
-- (no interface driving it) releases the battle after two seconds.
function Battle:Trans(dir, cb)
	if not cb then
		if BVNTrans and BVNTrans[dir] then BVNTrans[dir]() end
		return
	end
	local done = false
	local function once() if not done then done = true; cb() end end
	self.transWait = {t = 120, cb = once}
	if BVNTrans and BVNTrans[dir] then BVNTrans[dir](once) else once() end
end

-- Pause (GameCtrl.pause / resume): freezes, ultimates and the KO stop everything but
-- the effects, the camera and the interface.
function Battle:PauseGame() self.renderGame = false end
function Battle:ResumeGame() self.renderGame = true end

-- GameCtrl.slow: animation every (gap + 1) ticks; sprites move at 0.5 / rate.
function Battle:SetSlow(rate)
	self.slowRate = rate
	self.animGap = math.ceil(60 / (30 / (rate > 0 and rate or 1))) - 1
	self.animCounter = 0
	self.cam.tween = BVNRuntime.INT(2.5 * (rate > 0 and rate or 1))
end

-- Events from fighters --------------------------------------------------------------------

function Battle:OnIdle(f)
	local o = self.fighters[3 - f.side]
	if o then o.combo = 0 end
	if f.state == 60 then f.state = 0 end
end
function Battle:OnHurtResume(f) local o = self.fighters[3 - f.side] if o then o.combo = 0 end end

-- GameCtrl.onFighterDie -> gameEnd.
function Battle:OnDie(f)
	if self.phase ~= "fight" then return end
	self:GameEnd(self.fighters[3 - f.side], f)
end
function Battle:OnDead() end

-- GameCtrl.doGameEnd / drawGame: HP stops changing at once, the end sequence starts.
function Battle:GameEnd(winner, loser)
	self.actionEnable = false
	self.phase, self.phaseT = "ko", 0
	for _, o in ipairs(self.fighters) do o.allowLoseHP = false end
	self.winner = winner and winner.side or 0
	self.loser = loser
	if winner then
		self.wins[winner.side] = self.wins[winner.side] + 1
		if self.arcade and winner.side == 1 and loser.hp <= 0 then
			-- addScoreByKO
			if loser.hurtHit and BVNFighter.IsBisha(loser.hurtHit) then self:AddScore(2000) end
			self:AddScore(winner.hp >= winner.hpMax and 20000 or 3000)
		end
		self.lastLoser = {comic = loser.char.comic_type or 0, qi = loser.qi}
	end
	self.endCtrl = {step = 0, hold = 0, draw = winner == nil}
end

function Battle:Pause(t) self.pause = math.max(self.pause, t) end

-- FighterEventCtrl.addAssister (DO_SPECIAL): standing or guarding with a full assist meter.
function Battle:DoSpecial(f)
	if f.state ~= 0 and f.state ~= 20 then return end
	if f.fzqi < f.fzqiMax then return end
	self:CallAssist(f)
end

function Battle:CallAssist(f)
	local a = f.assist
	if not a or (not a.dead and a.clip) then return false end
	f.fzqi = 0
	if f.LogInput then f:LogInput("O") end
	a:Go()
	self.sprites[#self.sprites + 1] = a
	return true
end

function Battle:FireBullet(owner, name, params, hitModel)
	local b = BVNBullet.Fire(self, owner, name, params, hitModel)
	if not b then return false end
	self.sprites[#self.sprites + 1] = b
	return true
end

function Battle:AddAttacker(owner, name, params, hitModel)
	local a = BVNBullet.Attacker(self, owner, name, params, hitModel)
	if not a then return false end
	self.sprites[#self.sprites + 1] = a
	return true
end

function Battle:AddFollowEffect(owner, name, under)
	local v = BVNBullet.Follow(self, owner, name, under)
	if not v then return false end
	self.sprites[#self.sprites + 1] = v
	return true
end

function Battle:FindAttacker(name, team)
	for _, sp in ipairs(self.sprites) do
		if sp.kind == "attacker" and sp.name == name and sp.team == team and not sp.dead then return sp end
	end
	return nil
end

-- FighterEffectCtrl.bisha / startWanKai: pause, black backdrop, cut-in face.
function Battle:Bisha(f, super, face, wankai)
	local img = face and f.faces and f.faces[face] and f.char.faces[f.faces[face]]
	self.bisha = {f = f, super = super, img = img, t = 0, wankai = wankai}
	if wankai then
		self.fx:WanKai(f, img)
	else
		self.fx:Bisha(f, super, img)
		self.fx:StartRenderBlackBack()
	end
end
function Battle:EndBisha(f)
	if self.bisha and self.bisha.f == f then self.bisha = nil end
	self.fx:EndBisha(f)
end

-- Tick -------------------------------------------------------------------------------------

function Battle:IsInAir(sp)
	if sp.vy < 0 then return true end
	local m = self.map
	if sp.y > m.playerBottom - 12 then
		sp.y = m.playerBottom
		sp.touchBottom = true
		sp.onFloorVO = nil
		return false
	end
	sp.touchBottom = false
	if sp.vy < 2.5 then
		for _, fl in ipairs(m.floors) do
			if sp.y > fl[3] - 5 and sp.y < fl[3] + 5 and sp.x > fl[1] and sp.x < fl[2] then
				sp.y = fl[3]
				sp.onFloorVO = fl
				return false
			end
		end
	end
	sp.onFloorVO = nil
	return true
end

-- GameLogic.fixGameSpritePosition: map bounds; a moving fighter also stays inside the
-- camera's 800-pixel view once the camera is fully zoomed out.
function Battle:FixPosition(sp)
	local m = self.map
	local x0, x1 = m.left + 10, m.right - 10
	local c = self.cam
	if sp.kind == "fighter" and sp.vx ~= 0 and c.zoom == 1 then
		x0, x1 = math.max(x0, c.nx + 10), math.min(x1, c.nx + 800)
	end
	sp.touchSide = false
	if sp.x <= x0 then sp.x = x0; sp.touchSide = true end
	if sp.x >= x1 then sp.x = x1; sp.touchSide = true end
	if sp.y > m.bottom then sp.y = m.bottom end
end

function Battle:BannerDone()
	local bn = self.banner
	return not bn or bn.f >= bn.to
end

function Battle:Update()
	self.tick = self.tick + 1
	for _, f in ipairs(self.fighters) do f.input:Update(self.actionEnable) end
	BVNRuntime.EnterFrame()
	-- GameCtrl.render: effects, then the stage (camera, interface), then the game unless paused.
	self.fx:Render()
	self:UpdateCamera()
	BVNHud.StepBanner(self)
	self:RenderFightUI()
	if self.phase == "fight" and self.start then self:FinishStart() end
	local tw = self.transWait
	if tw then
		tw.t = tw.t - 1
		if tw.t <= 0 then self.transWait = nil; tw.cb() end
	end
	if not self.renderGame then
		local bs = self.bisha
		if bs then
			bs.t = bs.t + 1
			if bs.t > 900 then self:EndBisha(bs.f) end
		end
		return
	end
	if self.pause > 0 then self.pause = self.pause - 1 return end
	-- Animate ticks: every 2nd logic tick (every 3rd at slow rate 1.5, 4th at 2).
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
	if animate and self.actionEnable and self.phase == "fight" then
		for _, f in ipairs(self.fighters) do if f.ai then f.ai:Think() end end
		if self.timeMax ~= -1 then
			self.timeFrame = self.timeFrame + 1
			if self.timeFrame > 30 then
				self.timeFrame = 0
				self.time = self.time - 1
				if self.time <= 0 then self:TimeOver() end
			end
		end
	end
	for _, sp in ipairs(self.sprites) do
		if not sp.dead then
			if sp.kind == "fighter" then
				self:FixPosition(sp)
				local air = self:IsInAir(sp)
				if air then sp:ApplyG(12) end
				sp:SetInAir(air)
			end
			sp:Render()
			if animate and not sp.dead then sp:RenderAnimate() end
		end
	end
	if self.renderHit then
		self:Push()
		if animate then self:CheckHits() end
	end
	for i = #self.sprites, 1, -1 do
		if self.sprites[i].dead then table.remove(self.sprites, i) end
	end
	self.phaseT = self.phaseT + 1
	if self.skipHold then
		-- A skipped start opens the fight after half a second, without the banner.
		self.skipHold = self.skipHold - 1
		if self.skipHold <= 0 then
			self.skipHold = nil
			self.start = {}
			self:FinishStart()
		end
	end
	if self.start then self:RenderStart() end
	if self.endCtrl then self:RenderEndCtrl() end
	if self.training then self:UpdateTraining() end
end

-- GameMainLogicCtrl.fillVec: a fighter against the wall does not move; the other takes
-- the whole push. With both at a wall both move by the full amount.
local function split(a, b, rate)
	if a.touchSide and b.touchSide then return 1, 1 end
	if a.touchSide then return 0, 1 end
	if b.touchSide then return 1, 0 end
	return rate, 1 - rate
end

function Battle:Push()
	local a, b = self.fighters[1], self.fighters[2]
	if a.isCross or b.isCross then return end
	local ra, rb = a:RawBody(), b:RawBody()
	if not ra or not rb then return end
	local o = overlap(ra, rb)
	if not o then return end
	if b.x < a.x then a, b = b, a end
	if (a.vx < 0 and a.vx < b.vx) or (b.vx > 0 and b.vx > a.vx) then return end
	local ka, kb = split(a, b, clamp(b.heavy / a.heavy * 0.5, 0.1, 0.9))
	if o[3] > 2 then
		local push = 5 * a.speedPlus
		a:Move(-push * ka, 0)
		b:Move(push * kb, 0)
	end
	if a.vx ~= 0 then b:Move(a.vx * kb, 0); a:Move(-a.vx * ka, 0) end
	if b.vx ~= 0 then a:Move(b.vx * ka, 0); b:Move(-b.vx * kb, 0) end
end

-- GameMainLogicCtrl.checkHit: every pair is tested against the frames as they are,
-- then all hits apply, so both fighters of a trade are hit.
function Battle:CheckHits()
	local list = self.sprites
	local found = {}
	for i = 1, #list do
		for j = 1, #list do
			local A, B = list[i], list[j]
			if A ~= B and A.team ~= B.team and not A.dead and not B.dead then
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
			B:BeHit(h, o)
			-- GameLogic.hitTarget: a hit that leaves the target staggered or flying counts.
			local f = A.kind == "fighter" and A or A.owner
			if f and f.kind ~= "fighter" then f = f.owner end
			if f and f.combo and (B.state == 21 or B.state == 22) then
				f.combo = f.combo + 1
				if self.arcade and f.side == 1 then self:AddScoreByHit(h, f.combo) end
			end
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

-- Arcade score (GameLogic.addScore*): raw points; BVNGame.AddScore applies the key-mode rate
-- when the match ends.
function Battle:AddScore(n)
	self.score = self.score + n
end

function Battle:AddScoreByHit(h, hits)
	local score = h.power
	if BVNFighter.IsBisha(h) then score = h.power * 2 end
	if h.id == "sh1" or h.id == "sh2" then score = score + 500 end
	if h.isBreakDef then score = score + 200 end
	if h.hurtType == 1 then score = score + 200 end
	score = score + (hits < 4 and hits * 50 or hits * 100)
	self:AddScore(score)
end

-- GameRoundCtrl.fightTimeover.
function Battle:TimeOver()
	if self.phase ~= "fight" then return end
	self.timeOver = true
	local a, b = self.fighters[1], self.fighters[2]
	if a.hp == b.hp then self:GameEnd(nil, nil)
	elseif a.hp > b.hp then self:GameEnd(a, b)
	else self:GameEnd(b, a) end
end

-- Round start (GameStartCtrl) ----------------------------------------------------------------

function Battle:RenderStart()
	local st = self.start
	if self.phase == "go" then
		-- showStart: actions open when the banner completes.
		if self:BannerDone() then self:FinishStart() end
		return
	end
	for _, f in ipairs(self.fighters) do
		if f.state == 60 then
			f.introT = (f.introT or 0) + 1
			if f.introT > 600 then f:Idle() end
			return
		end
	end
	if st.hold > 0 then st.hold = st.hold - 1 return end
	local intro = st.introTeam
	if st.step == 0 then
		if intro == -1 or intro == 1 then self:CameraFocusOne(self.fighters[1]); st.hold, st.step = 30, 1 else st.step = 2 end
	elseif st.step == 1 then
		self:SayIntro(self.fighters[1]); st.hold, st.step = 18, 2
	elseif st.step == 2 then
		if intro == -1 or intro == 2 then self:CameraFocusOne(self.fighters[2]); st.hold, st.step = 30, 3 else st.step = 4 end
	elseif st.step == 3 then
		self:SayIntro(self.fighters[2]); st.hold, st.step = 18, 4
	elseif st.step == 4 then
		self:CameraResume(); st.hold, st.step = 6, 5
	elseif st.step == 5 then
		self.phase, self.phaseT = "go", 0
		BVNHud.Banner(self, self.round < 5 and "start" or "start_final", self.round < 5 and "start_final" or "go:fight", -50)
	end
end

-- GameStartCtrl.skip / GameEndCtrl.skip.
function Battle:Skip()
	local st = self.start
	if st and self.phase == "intro" and st.step < 5 then
		if BVNTrans and BVNTrans.Quick then BVNTrans.Quick() end
		self:CameraResume()
		for _, f in ipairs(self.fighters) do f:Idle() end
		self.start = nil
		self.skipHold = 30
	end
	local e = self.endCtrl
	if e and e.step == 2 then e.hold = 0 end
end

function Battle:SayIntro(f)
	if not f:HasLabel("开场") then return end
	f.introT = 0
	f.state = 60
	f:GoFrame("开场", true)
end

function Battle:FinishStart()
	self.start = nil
	self.phase, self.phaseT = "fight", 0
	self.actionEnable = true
	for _, f in ipairs(self.fighters) do f.allowLoseHP = true end
end

-- Round end (FightUI.showEnd / renderEnd, GameEndCtrl) ------------------------------------

local function isBishaState(s) return s == 12 or s == 13 end

-- FightUI: the KO or time-over clip, the slow fall, then the winner. Runs while paused.
function Battle:RenderFightUI()
	local k = self.ko
	if not k then return end
	k.t = k.t + 1
	if k.stage == "ko_pause" then
		if k.t == 30 then
			BVNHud.Banner(self, "ko", "winner", 0)
			BVNSound.Play(BVNFxData.sounds[k.bsKO and "snd_ko_bs" or "snd_ko"] or "ko", 128)
		end
		if k.t > 30 and self:BannerDone() then
			-- koBack
			self.fx.freezeEnabled, self.fx.blurEnabled = true, true
			k.stage, k.playOver = "end", true
			self:ResumeGame()
			self.fx:SlowDown(2, 0)
		end
	elseif k.stage == "timeover" then
		if self:BannerDone() then
			self.fx.freezeEnabled = true
			if k.draw then
				k.stage = "drawgame"
				BVNHud.Banner(self, "drawgame", nil, 0)
			else
				k.stage, k.playOver, k.delay = "end", true, 60
			end
		end
	elseif k.stage == "drawgame" then
		if self:BannerDone() then
			k.stage = "done"
			if self.endCtrl then self.endCtrl.hold = 0 end
		end
	elseif k.stage == "end" and k.playOver then
		if (k.delay or 0) > 0 then
			k.delay = k.delay - 1
			if k.delay <= 0 then
				local w = self.winner > 0 and self.fighters[self.winner]
				if w then
					self:CameraFocusOne(w)
					BVNHud.ShowWinner(self, w)
				end
				k.stage = "done"
				if self.endCtrl then self.endCtrl.hold = 0 end
			end
			return
		end
		local loser = self.loser
		if loser then
			if loser.state == 22 and not k.slowing then k.slowing, k.flyT = true, self.tick end
			if loser.state == 30 then
				k.delay = (k.slowing and self.tick - k.flyT >= 120) and 60 or 120
				self.fx:SlowResume()
			end
		end
	end
end

-- FightUI.playKO / playTimeOver.
function Battle:ShowEnd()
	local e = self.endCtrl
	if self.timeOver then
		self.ko = {stage = "timeover", t = 0, draw = e.draw}
		BVNHud.Banner(self, "timeover", "drawgame", 0)
		return
	end
	local loser = self.loser
	local k = {stage = "ko_pause", t = 0}
	self.ko = k
	self.fx.freezeEnabled = false
	self.fx.freeze = 0
	if loser then
		self.fx:Effect("hit_end", loser.x, loser.y)
		self.fx:Shine(0xffffff, 0.5)
		self:CameraFocusOne(loser)
	end
	self:PauseGame()
	for _, f in ipairs(self.fighters) do if isBishaState(f.state) then k.bsKO = true end end
	if k.bsKO then
		local v = self.fx:Effect("kobg")
		if v then v.hold = 60 end
	else
		self.fx:BgBlur(10, 0, 2000)
	end
	self.fx.blurEnabled = false
	self.fx:Shake(5, 0, 1.5)
	BVNSound.Play(BVNFxData.sounds.snd_over_hit or "heavy", 128)
end

-- GameEndCtrl.render (only while the game runs).
function Battle:RenderEndCtrl()
	local e = self.endCtrl
	if e.hold > 0 then e.hold = e.hold - 1 return end
	if e.step == 0 then
		self:ShowEnd()
		e.step, e.hold = 1, 600
	elseif e.step == 1 then
		if e.draw then
			e.step, e.hold = 2, 60
			return
		end
		local w = self.fighters[self.winner]
		local s = w.state
		if isBishaState(s) or s == 50 then return end
		w.state = 61
		if w:HasLabel("胜利") then w:GoFrame("胜利", true) end
		e.step, e.hold = 2, 180
		if self.teamMode or self.mode == "survivor" then
			-- The winner regains up to 20% HP, scaled by the time left.
			local rate = self.timeMax == -1 and 1 or math.max(0, self.time) / self.timeMax
			local cap = BVNRuntime.INT(w.hpMax * 0.2)
			local add = BVNRuntime.INT(cap * rate)
			if add < w.hpMax * 0.05 then add = BVNRuntime.INT(w.hpMax * 0.05) end
			w.hp = math.min(w.hpMax, w.hp + add)
		end
		self.lastWinnerHp = w.hp
	elseif e.step == 2 then
		e.step = 22
		if e.draw then
			e.step = 3
		else
			self:Trans("In", function() e.step = 3 end)
		end
	elseif e.step == 3 then
		self.endCtrl = nil
		self.ko = nil
		BVNHud.ClearWinner(self)
		self:EndRound()
	end
end

-- GameRoundCtrl.runNext.
function Battle:EndRound()
	local w = self.winner or 0
	self.round = self.round + 1
	if self.teamMode then
		local nextRound, introTeam = false, 0
		if w == 0 then
			local h1, h2 = self:HasNextMember(1), self:HasNextMember(2)
			if not h1 and not h2 then nextRound = true
			elseif h1 and not h2 then self.matchWinner = 1
			elseif h2 and not h1 then self.matchWinner = 2
			else
				self:NextMember(1)
				self:NextMember(2)
				nextRound = true
			end
		else
			if self:NextMember(3 - w) then
				nextRound, introTeam = true, 3 - w
				self.fighters[w].keepHp = true
				self.fighters[w].hp = self.lastWinnerHp or self.fighters[w].hp
			else
				self.matchWinner = w
			end
		end
		if nextRound then self:StartRound(introTeam) return end
	elseif self.survivor then
		self.matchWinner = w > 0 and w or 2
	elseif self.wins[1] < 2 and self.wins[2] < 2 then
		self:StartRound(0)
		return
	else
		self.matchWinner = self.wins[1] >= 2 and 1 or 2
	end
	self.phase, self.phaseT = "over", 0
end

-- TrainingCtrl: HP refills 60 T after a fighter recovers from a hit (120 T after other
-- loss); qi and fzqi refill 120 T after they drop.
function Battle:UpdateTraining()
	for _, f in ipairs(self.fighters) do
		local tr = f.training or {hp = f.hp, qi = f.qi, fz = f.fzqi, hpT = 0, qiT = 0, fzT = 0}
		f.training = tr
		local hurt = f.state == 21 or f.state == 22
		if hurt then tr.hpT = 60
		elseif f.hp < tr.hp then tr.hpT = 120 end
		if f.qi < tr.qi then tr.qiT = 120 end
		if f.fzqi < tr.fz then tr.fzT = 120 end
		if not hurt and tr.hpT > 0 then
			tr.hpT = tr.hpT - 1
			if tr.hpT == 0 then f.hp = f.hpMax end
		end
		if tr.qiT > 0 then tr.qiT = tr.qiT - 1 if tr.qiT == 0 then f.qi = f.qiMax end end
		if tr.fzT > 0 then tr.fzT = tr.fzT - 1 if tr.fzT == 0 then f.fzqi = f.fzqiMax end end
		tr.hp, tr.qi, tr.fz = f.hp, f.qi, f.fzqi
	end
end

-- Camera (GameCamera with GameStage's settings) --------------------------------------------
-- The original camera frames an 800x600 stage: auto zoom 800 / dx * 0.8 (600 / dy * 0.8)
-- clamped to [1, 2.5], bounded by the map, eased by 1 / tween per tick.

function Battle:InitCamera()
	local m = self.map
	local c = {zoom = 2, ss = 2, tween = 5, offY = m.bottom - m.playerBottom}
	self.cam = c
	c.focus = {self.fighters[1], self.fighters[2]}
	-- Ease into the stage from its top-left corner (setX / setY clamp to the bounds).
	c.nx, c.ny = self:CamClamp(-((m.stageW / 2) * 2 - 350), -(m.bottom - 200), 2)
	c.rx, c.ry = c.nx, c.ny
end

function Battle:CamClamp(x, y, z)
	local m = self.map
	x = clamp(x, 0, math.max(0, m.stageW - 800 / z))
	y = clamp(y, -1000 * z, 600 - 600 / z)
	return x, y
end

function Battle:CameraFocusOne(sp)
	local c = self.cam
	c.focus = {sp}
	c.zoom = 3.5
	c.tween = 5
end

function Battle:CameraResume()
	local c = self.cam
	c.focus = {self.fighters[1], self.fighters[2]}
	c.tween = 5
end

function Battle:CameraZoom() return self.cam.zoom end

function Battle:UpdateCamera()
	local c = self.cam
	local fs = c.focus
	local px, py
	if #fs > 1 then
		local a, b = fs[1], fs[#fs]
		local dx, dy = math.abs(a.x - b.x), math.abs(a.y - b.y)
		px, py = math.min(a.x, b.x) + dx * 0.5, math.min(a.y, b.y) + dy * 0.5
		local zx = dx > 0 and 800 / dx * 0.8 or math.huge
		local zy = dy > 0 and 600 / dy * 0.8 or math.huge
		c.zoom = clamp(math.min(zx, zy), 1, 2.5)
	else
		px, py = fs[1].x, fs[1].y
	end
	local z = c.zoom
	c.nx, c.ny = self:CamClamp(px - 400 / z, py - (300 / z + c.offY), z)
	local t = c.tween > 1 and c.tween or 1
	c.rx = c.rx + (c.nx - c.rx) / t
	c.ry = c.ry + (c.ny - c.ry) / t
	c.ss = c.ss + (z - c.ss) / t
end

-- Drawing ----------------------------------------------------------------------------------

-- The 800x600 stage maps to 960x720 in the middle of the 1280x720 screen; the extra
-- width shows more of the map when it has room.
function Battle:Draw()
	local c = self.cam
	local s = c.ss
	local zoom = 1.2 * s
	local cx, cy = c.rx + 400 / s, c.ry + 300 / s
	local m = self.map
	local hw = SW / 2 / zoom
	if m.stageW >= hw * 2 then cx = clamp(cx, hw, m.stageW - hw) else cx = m.stageW / 2 end
	local sx, sy = self.fx:ShakeOffset()
	-- The stage shake moves everything, the HUD included, by whole stage pixels.
	cx, cy = cx - sx / s, cy - sy / s
	Camera.SetZoom(zoom)
	Camera.SetPosition(cx / 100, cy / 100)
	self.view = {x = cx - hw, y = cy - SH / 2 / zoom, w = hw * 2, h = SH / zoom, zoom = zoom}
	local L = m.layers
	self.fx:DrawBack()
	if self.fx:MapVisible() then
		local mul = self.fx.darkMul
		local tint = math.floor(255 * mul)
		if L.bg then
			-- The backdrop is fixed to the screen; scale it to cover the wide screen.
			local k = math.max(SW / L.bg.w, SH / L.bg.h)
			self:ScreenImage(L.bg.img, SW / 2 - 400 * k + sx * 1.2, SH / 2 - 300 * k + sy * 1.2, k, k, tint, tint, tint, 255, 0)
		end
		-- A solid bitmap a script put over the backdrop (BVNBattle.MapLayer).
		local fill = self.mapFill
		if fill then
			local c = fill.color or 0
			local v = self.view
			D.Rect(v.x - 10, v.y - 10, v.w + 20, v.h + 20, {(c >> 16) & 255, (c >> 8) & 255, c & 255}, 255, 1)
		end
		if L.map then self:DrawLayerImage(L.map.img, L.map.x, L.map.y, L.map.sx, L.map.sy, tint, 255, 2) end
		-- Off-map strips when the wide view is wider than the map.
		local v = self.view
		if v.x < 0 then D.Rect(v.x - 10, v.y - 10, -v.x + 10, v.h + 20, BLACK, 255, 3) end
		if v.x + v.w > m.stageW then D.Rect(m.stageW, v.y - 10, v.x + v.w - m.stageW + 10, v.h + 20, BLACK, 255, 3) end
	end
	-- Fighters: the attacking one on top; an ultimate's owner above everything.
	self.fx:DrawShadows(15)
	local f1, f2 = self.fighters[1], self.fighters[2]
	local first, second = f1, f2
	if f1:IsAttacking() and not f2:IsAttacking() then first, second = f2, f1 end
	if self.bisha and self.bisha.f.kind == "fighter" then
		first, second = (self.bisha.f == f1) and f2 or f1, self.bisha.f
	end
	self:DrawFighter(first, 20)
	self:DrawFighter(second, 40)
	for _, sp in ipairs(self.sprites) do
		if sp.kind ~= "fighter" and not sp.dead and sp.clip then sp:Draw(sp.drawUnder and 12 or (sp.kind == "assist" and 30 or 60)) end
	end
	self.fx:Draw()
	if self.debugBoxes then
		for _, sp in ipairs(self.sprites) do
			if not sp.dead then
				local r = sp.RawBody and sp:RawBody()
				if r then D.Rect(r[1], r[2], r[3], r[4], {0, 255, 0}, 90, 95) end
				for _, h in ipairs(sp:CurrentHits()) do D.Rect(h[2][1], h[2][2], h[2][3], h[2][4], {255, 0, 0}, 90, 96) end
				D.Rect(sp.x - 1, sp.y - 20, 2, 20, {255, 255, 0}, 255, 97)
			end
		end
	end
	if self.fx:MapVisible() then
		-- MapMain.render: the front layer drifts with the camera (x * 0.1, y * 0.1 below its rest).
		local fdx = -c.rx * 0.1
		local fdy = math.max(0, (m.bottom - c.ry) * 0.1)
		local tint = math.floor(255 * self.fx.darkMul)
		self:DrawFront(L.front_fix, 0, 0, tint)
		self:DrawFront(L.front, fdx, fdy, tint)
	end
	BVNHud.shakeX, BVNHud.shakeY = sx, sy
	BVNHud.Draw(self)
	self.fx:DrawScreen()
end

-- A screen-space image (1280x720 pixels) drawn in the world under the scene: the
-- engine draws UI images above every world image.
function Battle:ScreenImage(img, px, py, kx, ky, r, g, b, a, order, blend)
	local v = self.view
	Image.DrawEx(img, (v.x + px / v.zoom) / 100, (v.y + py / v.zoom) / 100, 0, kx / v.zoom, ky / v.zoom,
		kx < 0 and 1 or 0, ky < 0 and 1 or 0, r, g, b, a, order, nil, blend)
end

-- Map layer with the background blur (EffectSlowHandler.bgBlur): a horizontal box blur.
function Battle:DrawLayerImage(img, x, y, sx, sy, tint, a, order)
	local blur = self.fx.blur
	if blur > 0 then
		local n = 3
		for i = 0, n - 1 do
			local off = (i - (n - 1) / 2) * blur / n
			Image.DrawEx(img, (x + off) / 100, y / 100, 0, sx, sy, 0, 0, tint, tint, tint, i == 0 and a or math.floor(a / (i + 1)), order)
		end
	else
		Image.DrawEx(img, x / 100, y / 100, 0, sx, sy, 0, 0, tint, tint, tint, a, order)
	end
end

-- Front layers: a movie clip a fighter overlaps is drawn half transparent (MapLayer.renderOptical).
function Battle:DrawFront(layer, dx, dy, tint)
	if not layer then return end
	if not layer.parts then
		self:DrawLayerImage(layer.img, layer.x + dx, layer.y + dy, layer.sx, layer.sy, tint, 255, 90)
		return
	end
	for _, p in ipairs(layer.parts) do
		local a = 255
		if p.clip then
			local r = {p.x + dx, p.y + dy, p.w * p.sx, p.h * p.sy}
			for _, f in ipairs(self.fighters) do
				local body = f:RawBody()
				if body and BVNBattle.Intersects(r, body) then a = 128 break end
			end
		end
		self:DrawLayerImage(p.img, p.x + dx, p.y + dy, p.sx, p.sy, tint, a, 90)
	end
end

function Battle:DrawFighter(f, order)
	if f.visible == false then return end
	local opt = {order = order, color = f.color, alpha = f.fade and math.floor(255 * f.fade) or nil}
	local fo = f.formOffset
	BVNClip.Draw(f.clip, f.x, f.y, f.dir, opt, {fo[3], 0, 0, fo[4], fo[1], fo[2]})
	if f.glow then
		-- startGlow: an outer glow (white, or yellow for 0xffff00) drawn additively around the fighter.
		local g = f.glow == 0xffff00 and {255, 255, 0} or {255, 255, 255}
		for i = 0, 7 do
			local ang = i * math.pi / 4
			local gx, gy = math.cos(ang) * 5, math.sin(ang) * 5
			BVNClip.Draw(f.clip, f.x + gx, f.y + gy, f.dir, {order = order - 1, tint = g, alpha = 70, blend = "add"},
				{fo[3], 0, 0, fo[4], fo[1], fo[2]})
		end
	end
end
