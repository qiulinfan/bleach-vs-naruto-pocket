-- Port of the Bleach vs Naruto fighter kernel (5DPLAY, GPL-3.0): FighterMain,
-- FighterMC, FighterMcCtrler and its floor / air / hurt / defense handlers,
-- and the $mc_ctrler / $effect_ctrler / $fighter_ctrler objects that the
-- translated character scripts call. Rules and constants follow the kernel;
-- see the game's AGENTS.md. Not attached to any actor.
--
-- Clock: logic ticks (T) at 60 Hz; the timeline advances on animate ticks (A),
-- every 2nd T. Velocities move v*0.5 px per T; damping subtracts per T.

local S = {NORMAL = 0, ATTACK = 10, SKILL = 11, BISHA = 12, BISHA_SUPER = 13, JUMP = 14, DASH = 15, HURT_ACT = 16,
	DEFENSE = 20, HURT = 21, HURT_FLY = 22, HURT_DOWN = 23, HURT_DOWN_TAN = 24, DEAD = 30, FREEZE = 40, WANKAI = 50,
	INTRO = 60, WIN = 61, LOSE = 62}
local HEAVY_TYPES = {[3] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true}

local function sign(v) return v > 0 and 1 or (v < 0 and -1 or 0) end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function weaken(v, d)
	if v > 0 then return math.max(0, v - d) end
	if v < 0 then return math.min(0, v + d) end
	return 0
end

local Fighter = {}
Fighter.__index = Fighter

BVNFighter = {S = S, Fighter = Fighter}

local function newAction()
	return {jumpTimes = 2, airHitTimes = 1, bishaQi = 100, bishaUPQi = 100, bishaAIRQi = 100, bishaSUPERQi = 300}
end

local WINDOWS = {"moveLeft", "moveRight", "defense", "jump", "jumpQuick", "jumpDown", "dash", "attack", "skill1", "skill2",
	"zhao1", "zhao2", "zhao3", "catch1", "catch2", "bisha", "bishaUP", "bishaSUPER", "attackAIR", "skillAIR", "bishaAIR",
	"waiKai", "touchFloor", "hitTarget", "hitTargetChecker", "hurtAction", "airMove"}

-- HitVO ---------------------------------------------------------------------

local function newHitVO(id, obj, owner)
	local h = {id = id, power = 0, powerAdd = 0, powerRate = 1, hitType = 1, isBreakDef = false, hitx = 0, hity = 0,
		hurtTime = 300, hurtType = 0, slowDown = 0, checkDirect = true, focusTarget = false, targetApplyG = true, owner = owner}
	for k, v in pairs(obj or {}) do h[k] = v end
	if h.hitType == 1 and h.hurtTime < 100 then h.hurtTime = 100 end
	return h
end

local function damageOf(h)
	return BVNRuntime.INT((h.power + h.power * (h.powerAdd or 0) / 100) * (h.powerRate or 1))
end

BVNFighter.NewHitVO = newHitVO
BVNFighter.Damage = damageOf
BVNFighter.IsBisha = function(h) return h.id:find("bs") ~= nil end
BVNFighter.IsCatch = function(h) return h.hitType == 11 and h.isBreakDef end

-- Construction ----------------------------------------------------------------

-- char: BVNF_<id>; form: 1-based form index (start_frame); side 1/2.
function BVNFighter.New(battle, char, form, side, input)
	local f = setmetatable({}, Fighter)
	f.battle, f.char, f.side, f.team = battle, char, side, side
	f.input = input
	f.x, f.y, f.vx, f.vy, f.dx, f.dy = 0, 0, 0, 0, 0, 0
	f.v2x, f.v2y, f.d2x, f.d2y = 0, 0, 0, 0
	f.g, f.speedPlus, f.dampingRate = 0, 0.5, 1
	f.heavy, f.speed, f.jumpPower = 2, 6, 15
	f.dir = side == 1 and 1 or -1
	f.inAir, f.touchBottom, f.touchSide = false, true, false
	f.allowBeHit, f.isCross, f.applyG, f.alive, f.allowLoseHP = true, false, true, true, true
	f.hpMax, f.hp, f.defense, f.attackRate, f.defenseRate = 1000, 1000, 0, 1, 1
	f.qi, f.qiMax, f.energy, f.energyMax, f.overload, f.energyPause = 0, 300, 100, 100, false, 0
	f.fzqi, f.fzqiMax = 100, 100
	f.state = S.NORMAL
	f.act = newAction()
	f.hitModel = {}
	f.faces, f.voices = {}, {}
	f.frameOut, f.delayCalls = {}, {}
	f.defenseType = 0
	f.beHitGap, f.justDefenseFrame, f.defenseFrameDelay = 0, 0, 0
	f.doActionFrame = 0
	f.currentHurts = {}
	f.currentHurtDamage = 0
	f.combo = 0
	f.ghosts = {}

	f.mcCtrl = setmetatable({f = f}, {__index = BVNCtrl.Mc})
	f.effCtrl = setmetatable({f = f}, {__index = BVNCtrl.Eff})
	f.fCtrl = setmetatable({f = f}, {__index = BVNCtrl.F.Get, __newindex = BVNCtrl.F.Set})
	-- The main_mc instance: its script defines moves and builds each form.
	local main = char.main
	f.mainMethods = main and main.methods or {}
	f.mainInst = setmetatable({S_fighter_ctrler = f.fCtrl, S_mc_ctrler = f.mcCtrl, S_effect_ctrler = f.effCtrl},
		{__index = function(t, k)
			local m = f.mainMethods[k]
			if m then return m end
			if k == "defineAction" then return function(_, id, obj) f.fCtrl:defineAction(id, obj) end end
			if k == "stop" or k == "gotoAndStop" or k == "gotoAndPlay" or k == "play" then return function() end end
			return nil
		end})
	if main then for k, v in pairs(main.fields) do f.mainInst[k] = v end end
	f.mainInst.S_fighter_ctrler, f.mainInst.S_mc_ctrler, f.mainInst.S_effect_ctrler = f.fCtrl, f.mcCtrl, f.effCtrl
	f:SetForm(form or 1)
	return f
end

-- Switches main_mc to the frame of form index `n` and runs its script (defineAction..., initMc).
function Fighter:SetForm(n)
	local forms = self.char.forms
	n = clamp(n, 1, #forms)
	self.formIndex = n
	local form = forms[n]
	self.formOffset = {form.x, form.y, form.sx or 1, form.sy or 1}
	local clip = BVNClip.New(self.char, form.sprite, self.mainInst, self)
	self.clip = clip
	self.mainInst.mc = clip.inst
	local frameName = "frame" .. form.form_frame
	local fn = self.mainMethods[frameName]
	if fn then
		local ok, err = pcall(fn, self.mainInst)
		if not ok then Debug.Log("BVN main script " .. self.char.id .. ": " .. tostring(err)) end
	end
	if not self.mcReady then self:InitMc() end
end

function Fighter:InitMc()
	self.mcReady = true
	self.fmc = {play = false, playFrame = 0, curFrameCount = 0, curMainFrameCount = 0, delay = nil, name = nil,
		hurtFly = 0, hurtFlyFrame = 0, downFrame = 0, yMin = 0}
	if self.doingWankai then
		self.doingWankai = false
		self.state = S.WANKAI
		self:GoFrame("开场", true)
	else
		self:Idle()
	end
end

-- FighterMC -------------------------------------------------------------------

function Fighter:HasLabel(name) return name and self.clip.data.labels[name] ~= nil end

function Fighter:GoFrame(name, isPlay, playFrame, delay)
	local m = self.fmc
	if isPlay == nil then isPlay = true end
	m.name = name
	m.curMainFrameCount, m.curFrameCount = 0, 0
	m.play = isPlay
	m.playFrame = isPlay and (playFrame or 0) or 0
	if delay and (delay.name or delay.call) and BVNRuntime.INT(delay.delay) > 0 then
		if delay.isPlay == nil then delay.isPlay = true end
		delay.playFrame = delay.playFrame or 0
		m.delay = delay
	else
		m.delay = nil
	end
	local n = BVNClip.Find(self.clip, name)
	if n then
		-- gotoAndStop runs the destination frame's script even when re-entering it.
		BVNClip.Enter(self.clip, n)
	end
	BVNClip.AdvanceKids(self.clip)
end

function Fighter:RenderMcAnimate()
	local m = self.fmc
	if m.play then
		if m.playFrame > 0 then
			m.playFrame = m.playFrame - 1
			if m.playFrame <= 0 then m.play = false end
			m.curMainFrameCount = m.curMainFrameCount + 1
		end
		BVNClip.Next(self.clip)
	end
	BVNClip.AdvanceKids(self.clip)
	if m.hurtFly ~= 0 then self:RenderHurtFly() end
	m.curFrameCount = m.curFrameCount + 1
	if m.delay then
		local d = m.delay
		d.delay = d.delay - 1
		if d.delay < 0 then
			m.delay = nil
			if d.call then d.call() else self:GoFrame(d.name, d.isPlay, d.playFrame, nil) end
		end
	end
end

function Fighter:Frame() return self.clip.data.frames[self.clip.frame] end
function Fighter:CurLabel() return BVNClip.Label(self.clip) end

-- World rect of an action-clip-local rect {x, y, w, h}.
function Fighter:WorldRect(r)
	local fo = self.formOffset
	local w, h = r[3] * fo[3], r[4] * fo[4]
	local x = (r[1] * fo[3] + fo[1]) * self.dir + self.x - (self.dir < 0 and w or 0)
	return {x, r[2] * fo[4] + fo[2] + self.y, w, h}
end

function Fighter:BodyArea()
	if not self.allowBeHit then return nil end
	local f = self:Frame()
	if not f or not f.body then return nil end
	return self:WorldRect(f.body)
end

function Fighter:RawBody()
	local f = self:Frame()
	return f and f.body and self:WorldRect(f.body) or nil
end

-- The hit boxes of the current frame with a defined HitVO.
function Fighter:CurrentHits()
	local f = self:Frame()
	local out = {}
	if not f or not f.hits then return out end
	for name, r in pairs(f.hits) do
		if name:sub(1, 1) ~= "@" then
			local h = self.hitModel[name] or self.hitModel[(name:gsub("atm", ""))]
			if h then out[#out + 1] = {h, self:WorldRect(r)} end
		end
	end
	if self.explodeHit then out[#out + 1] = self.explodeHit end
	return out
end

-- World rect of a named child checker (setHitTarget), or nil.
function Fighter:CheckerRect(name)
	local f = self:Frame()
	local r = f and f.hits and f.hits[name]
	if r and #r == 4 then return self:WorldRect(r) end
	return nil
end

function Fighter:ChildPos(name)
	local f = self:Frame()
	local p = f and f.hits and f.hits["@" .. name]
	local fo = self.formOffset
	if p then return self.x + (p[1] * fo[3] + fo[1]) * self.dir, self.y + p[2] * fo[4] + fo[2] end
	return nil
end

function Fighter:Range(name)
	local r = self.clip.data.ranges and self.clip.data.ranges[name]
	if not r then return nil end
	return self:WorldRect(r)
end

-- BaseGameSprite physics ---------------------------------------------------------

function Fighter:Move(x, y)
	self.x = self.x + (x or 0) * self.speedPlus
	self.y = self.y + (y or 0) * self.speedPlus
end
function Fighter:SetVelocity(x, y) self.vx, self.vy, self.dx, self.dy = x or 0, y or 0, 0, 0 end
function Fighter:SetDamping(x, y) self.dx, self.dy = x or 0, y or 0 end
function Fighter:SetVec2(x, y, dx, dy) self.v2x, self.v2y, self.d2x, self.d2y = x, y, dx * 3, dy * 3 end

function Fighter:RenderVelocity()
	local mx, my = 0, 0
	if self.vx ~= 0 then mx = mx + self.vx end
	if self.vy ~= 0 then my = my + self.vy end
	if self.dx > 0 then self.vx = weaken(self.vx, self.dx * self.dampingRate) end
	if self.dy > 0 then self.vy = weaken(self.vy, self.dy * self.dampingRate) end
	if self.v2x ~= 0 then mx = mx + self.v2x end
	if self.v2y ~= 0 then my = my + self.v2y end
	if self.d2x > 0 then self.v2x = weaken(self.v2x, self.d2x * self.dampingRate) end
	if self.d2y > 0 then self.v2y = weaken(self.v2y, self.d2y * self.dampingRate) end
	if mx ~= 0 or my ~= 0 then self:Move(mx, my) end
end

function Fighter:ApplyG(G)
	if not self.applyG then self.g = 0 return end
	if self.vy < 0 then self.g = 0 return end
	self.g = math.min(G, self.g + 1.2 * self.speedPlus)
	self:Move(0, self.g)
end

function Fighter:SetInAir(v)
	if not v and self.inAir then self.g = 4 end
	if not v then self.g = 4 end
	self.inAir = v
end

function Fighter:LoseHp(v)
	if not self.allowLoseHP then return end
	local dr = clamp(2 - self.defenseRate, 0.1, 1)
	local lose = v * dr - self.defense
	if lose < 0 then return end
	self.hp = math.max(0, self.hp - lose)
end

function Fighter:FrameOut(fn, n) self.frameOut[#self.frameOut + 1] = {fn = fn, n = n} end
function Fighter:DelayCall(fn, n) self.delayCalls[#self.delayCalls + 1] = {fn = fn, n = n} end

local function runTimers(list)
	for i = #list, 1, -1 do
		local t = list[i]
		t.n = t.n - 1
		if t.n < 1 then
			table.remove(list, i)
			t.fn()
		end
	end
end

-- Resources ----------------------------------------------------------------------

function Fighter:AddQi(v) self.qi = clamp(self.qi + v, 0, self.qiMax) end
function Fighter:UseQi(v)
	if self.qi < v then return false end
	self.qi = self.qi - v
	return true
end
function Fighter:HasEnergy(v, allowOverflow)
	return self.energy >= v or (allowOverflow and not self.overload)
end
function Fighter:UseEnergy(v)
	self.energy = self.energy - v
	self.energyPause = 24
	if self.energy < 0 then
		self.energy = 0
		self.overload = true
	end
end

function Fighter:RenderEnergy()
	if self.energyPause > 0 then self.energyPause = self.energyPause - 1 return end
	local add
	if self.overload then
		add = 0.6
		if self.energy > 30 then self.overload = false end
	elseif self.state == S.DEFENSE then add = 0.8
	elseif self:IsAttacking() then add = 1.1
	else add = 2 end
	self.energy = math.min(self.energyMax, self.energy + add)
end

function Fighter:IsAttacking() local s = self.state return s == 10 or s == 11 or s == 12 or s == 13 end
function Fighter:IsHurting() local s = self.state return s >= 21 and s <= 24 end

-- Targets ---------------------------------------------------------------------------

function Fighter:Target() return self.battle:TargetOf(self) end

function Fighter:FaceTarget()
	local t = self:Target()
	if t and t.x ~= self.x then self.dir = t.x > self.x and 1 or -1 end
end

-- Action windows ----------------------------------------------------------------------

function Fighter:ClearAction()
	local a = self.act
	for _, k in ipairs(WINDOWS) do a[k] = nil end
	a.bishaQi, a.bishaUPQi, a.bishaAIRQi, a.bishaSUPERQi = 100, 100, 100, 300
end

function Fighter:ClearState()
	self.isHurting, self.isHurtFlying, self.isDefenseHiting = false, false, false
	self.act.touchFloorBreakAct = nil
	self.moveTarget = nil
end

function Fighter:SetAllAct()
	local a, mc = self.act, self.mcCtrl
	a.moveLeft, a.moveRight, a.defense = true, true, true
	mc:setJump(); mc:setJumpDown(); mc:setDash(); mc:setAttack(); mc:setSkill1(); mc:setSkill2()
	mc:setZhao1(); mc:setZhao2(); mc:setZhao3(); mc:setCatch1(); mc:setCatch2()
	mc:setBisha(); mc:setBishaUP(); mc:setBishaSUPER(); mc:setWankai()
end

function Fighter:SetAirAllAct()
	local mc = self.mcCtrl
	mc:setDash(); mc:setAttackAIR(); mc:setSkillAIR(); mc:setBishaAIR()
	self.act.airMove = true
end

function Fighter:DoAction(label, airAct, delay)
	self.effCtrl:endShadow()
	self.effCtrl:endShake()
	self:SetVelocity(0, 0)
	self.isMoving, self.isDefensing, self.isDashing = false, false, false
	self.doingAction = label
	self.doingAirAction = airAct and label or nil
	self:ClearAction()
	self.isFalling = false
	self.isDefense = false
	self.allowBeHit, self.isCross, self.applyG = true, false, true
	self.doActionFrame = 0
	self:GoFrame(label, true, 0, delay)
end

function Fighter:Idle(frame, ignoreAlive)
	if not self.alive and not ignoreAlive then return end
	if self.inAir and not self.touchBottom and not frame and not self.onFloorVO then
		self.doingAction = nil
		self:Fall()
		return
	end
	self.effCtrl:endShadow()
	self.effCtrl:endShake()
	self:ClearAction()
	self:ClearState()
	self.isMoving, self.isDefensing, self.isDashing, self.isJumping, self.isFalling = false, false, false, false, false
	self.doingAction, self.doingAirAction = nil, nil
	self.state = S.NORMAL
	self.allowBeHit = not self.justHurtResume
	self.applyG, self.isCross = true, false
	self.hurtHit, self.defenseHit = nil, nil
	self.steel, self.steelSuper = false, false
	self:SetVelocity(0, 0)
	self.justDefenseFrame = 6
	self.act.jumpTimes, self.act.airHitTimes = 2, 1
	self.currentHurts, self.currentHurtDamage = {}, 0
	self.battle:OnIdle(self)
	if frame then
		self:GoFrame(frame, true)
	else
		self:GoFrame("站立", false)
		self:SetAllAct()
	end
end

function Fighter:EndAct()
	self:ClearAction()
	self.state = S.FREEZE
	self.moveTarget = nil
	self.steel, self.steelSuper = false, false
end

-- Per logic tick (T) ----------------------------------------------------------------

function Fighter:Render()
	self:RenderVelocity()
	runTimers(self.delayCalls)
	self.justDefenseFrame = self.justDefenseFrame - 1
	if self.moveTarget then self:RenderMoveTarget() end
	if self.ghost then return end
	local inp = self.input
	if self.isHurtFlying then self:RenderHurtFlying() return end
	if self.isHurting then self:RenderHurtBreak() return end
	if self.isDefenseHiting then self:RenderDefense(false, true) return end
	if not self.battle.actionEnable then
		if self.state == S.NORMAL and (self:CurLabel() == "走" or self:CurLabel() == "防御") then self:Idle() end
		return
	end
	if self.act.hitTarget and self.act.hitTargetChecker then
		local r = self:CheckerRect(self.act.hitTargetChecker)
		local t = self:Target()
		local body = t and t:RawBody()
		if r and body and BVNBattle.Intersects(r, body) then
			local label = self.act.hitTarget
			self:DoAction(label)
			return
		end
	end
	if self:RenderWanKai() then return end
	if self.inAir or (self.doingAirAction and not self.act.touchFloorBreakAct) then
		self:RenderAirAction()
	else
		self:RenderFloorAction()
	end
end

-- Per animate tick (A).
function Fighter:RenderAnimate()
	runTimers(self.frameOut)
	if self.justHurtResume then
		self.justHurtResume = false
		self.allowBeHit = true
	end
	if self.beHitGap > 0 then
		self.beHitGap = self.beHitGap - 1
		if self.beHitGap <= 0 then self.allowBeHit = true end
	end
	self:RenderMcAnimate()
	if self.isHurting then self:RenderHurtAnimate() end
	if self.isDefenseHiting then self:RenderDefenseHiting() end
	if self.isJumping and not self.doingAction then self:RenderJumpAnimate() end
	self.doActionFrame = self.doActionFrame + 1
	if self.isDefensing then self:RenderDefenseAnimate() end
	if self.state == S.NORMAL and self:CurLabel() == "站立" and self.fmc.curFrameCount % 6 == 0 then self:FaceTarget() end
	if self.explodeHit then
		self.explodeFrame = self.explodeFrame + 1
		if self.explodeFrame >= 8 then self.explodeHit = nil end
	end
	if self.battle.actionEnable then self:RenderEnergy() end
	self.fzqi = math.min(self.fzqiMax, self.fzqi + 0.2)
end

-- Floor actions (FighterMcFloorHandler) ------------------------------------------------

function Fighter:RenderFloorAction()
	if not self.alive then return end
	if self.wasInAir then self:TouchFloor() end
	local k, a = self.input, self.act
	local function ok(win, pred) return a[win] and k[pred](k) end
	if k:special() and (self.state == S.NORMAL or self.state == S.DEFENSE) and self.fzqi >= 100 then
		if self.battle:CallAssist(self) then return end
	end
	if ok("catch1", "catch1") and self:AllowCatch() then self:DoCatch(a.catch1) return end
	if ok("catch2", "catch2") and self:AllowCatch() then self:DoCatch(a.catch2) return end
	if ok("bishaSUPER", "bishaSUPER") and self:DoBisha(a.bishaSUPER, a.bishaSUPERQi, true) then return end
	if ok("bishaUP", "bishaUP") and self:DoBisha(a.bishaUP, a.bishaUPQi) then return end
	if ok("bisha", "bisha") and self:DoBisha(a.bisha, a.bishaQi) then return end
	if ok("skill2", "skill2") then self:DoSkill(a.skill2) return end
	if ok("skill1", "skill1") then self:DoSkill(a.skill1) return end
	if ok("zhao3", "zhao3") then self:DoSkill(a.zhao3) return end
	if ok("zhao2", "zhao2") then self:DoSkill(a.zhao2) return end
	if ok("attack", "attack") then self:DoAttack(a.attack) return end
	if ok("zhao1", "zhao1") then self:DoSkill(a.zhao1) return end
	if ok("defense", "defense") then self:DoDefense() return end
	if self.isDefensing then
		self:RenderDefense(true)
		return
	end
	if ok("dash", "dash") and self:HasEnergy(20, true) then self:DoDash() return end
	if a.jumpDown and k:jumpDown() and self.onFloorVO then self:DoJumpDown() return end
	if (a.jump and k:jump()) then self:DoJump() return end
	if (a.moveLeft and k:moveLEFT()) or (a.moveRight and k:moveRIGHT()) or self.isMoving then
		if self:RenderMoving() then return end
	end
	if self:IsAttacking() then
		if ok("attackAIR", "attackAIR") then self:DoAirAttack(a.attackAIR) return end
		if ok("skillAIR", "skillAIR") then self:DoAirSkill(a.skillAIR) return end
		if ok("bishaAIR", "bishaAIR") then self:DoAirBisha(a.bishaAIR) return end
	end
end

function Fighter:RenderMoving()
	local k = self.input
	local left = self.act.moveLeft and k:moveLEFT()
	local right = self.act.moveRight and k:moveRIGHT()
	if not left and not right then
		if self.isMoving then self:Idle() end
		return false
	end
	if not self.isMoving then
		self.isMoving = true
		self:GoFrame("走", true)
		self.state = S.NORMAL
		self:SetMoveAction()
	end
	self.dir = left and -1 or 1
	self:SetVelocity(self.speed * self.dir, 0)
	return true
end

function Fighter:SetMoveAction()
	self:ClearAction()
	local a, mc = self.act, self.mcCtrl
	a.moveLeft, a.moveRight, a.defense = true, true, true
	mc:setAttack(); mc:setZhao1(); mc:setZhao3(); mc:setSkill2(); mc:setJump(); mc:setDash()
	mc:setBisha(); mc:setBishaUP(); mc:setCatch1(); mc:setCatch2()
end

function Fighter:DoAttack(label)
	self:DoAction(label)
	self.state = S.ATTACK
end

function Fighter:DoSkill(label)
	self:DoAction(label)
	self.state = S.SKILL
end

function Fighter:DoBisha(label, qi, super)
	if not self:UseQi(qi or 100) then return false end
	self.state = super and S.BISHA_SUPER or S.BISHA
	self:DoAction(label)
	self.state = super and S.BISHA_SUPER or S.BISHA
	return true
end

function Fighter:AllowCatch()
	local t = self:Target()
	if not t or t.state == S.HURT or not t.alive then return false end
	if sign(t.x - self.x) ~= self.dir then return false end
	local a, b = self:RawBody(), t:RawBody()
	if not a or not b then return false end
	local gap = math.max(b[1] - (a[1] + a[3]), a[1] - (b[1] + b[3]))
	return gap < 2 and math.abs(t.y - self.y) < 1
end

function Fighter:DoCatch(label)
	self:DoAction(label)
	self.state = S.SKILL
end

function Fighter:DoDash()
	self:UseEnergy(20)
	local k = self.input
	if k:moveLEFT() then self.dir = -1 elseif k:moveRIGHT() then self.dir = 1 end
	self:DoAction("瞬步")
	self.state = S.DASH
	self.allowBeHit, self.applyG = false, false
end

-- Defense ----------------------------------------------------------------------------

function Fighter:DoDefense()
	if self.isDefensing then return end
	self.state = S.DEFENSE
	self.isDefensing = true
	self.mcCtrl:dampingPercent(1, 1)
	self:SetDefenseAction()
end

function Fighter:SetDefenseAction()
	self:ClearAction()
	local mc = self.mcCtrl
	mc:setSkill1(); mc:setZhao2(); mc:setBishaSUPER(); mc:setJumpDown()
	self:GoFrame("防御", true, 3)
	self.defenseFrameDelay = 1
	self.isDefense = self.justDefenseFrame > 0
	self.isMoving = false
end

function Fighter:RenderDefense(fromFloor, hiting)
	local k = self.input
	local t = self:Target()
	local want = self.dir
	if k:moveLEFT() then want = -1 elseif k:moveRIGHT() then want = 1 end
	if want ~= self.dir and fromFloor and not hiting then
		self.dir = want
		self:SetDefenseAction()
		return
	end
	if hiting and want ~= self.dir then
		self.dir = want
		self.isDefense = true
	end
	if fromFloor then
		local a = self.act
		if a.skill1 and k:skill1() then self:DoSkill(a.skill1) return end
		if a.zhao2 and k:zhao2() then self:DoSkill(a.zhao2) return end
		if a.bishaSUPER and k:bishaSUPER() then self:DoBisha(a.bishaSUPER, a.bishaSUPERQi, true) return end
	end
end

function Fighter:RenderDefenseAnimate()
	local k = self.input
	self.defenseFrameDelay = self.defenseFrameDelay - 1
	if k:defense() then
		if self.defenseFrameDelay < 0 then self.isDefense = true end
		return
	end
	if self.defenseFrameDelay < -5 and not self.isDefenseHiting then
		self.isDefensing = false
		self.isDefense = false
		self:GoFrame("防御恢复", false)
		self:FrameOut(function() if self.state == S.DEFENSE or self.state == S.NORMAL then self:Idle() end end, 1)
	end
end

function Fighter:RenderDefenseHiting()
	if self.defenseHold > 0 then
		self.defenseHold = self.defenseHold - 1
		return
	end
	if self.vx == 0 then
		self.isDefenseHiting = false
		if self.input:defense() and self.alive then
			self.state = S.DEFENSE
			self.isDefensing = true
			self:SetDefenseAction()
			self.isDefense = true
		else
			self:Idle()
		end
	end
end

-- Air (FighterMcAirHandler) ------------------------------------------------------------

function Fighter:DoJump()
	if self.act.jumpTimes <= 0 then return end
	self:ClearAction()
	self:ClearState()
	self.doingAction = nil
	self.isMoving = false
	self:GoFrame("起跳", false)
	self.jumpDelay = 2
	self.isJumping = true
	self.isFalling = false
	self.state = S.JUMP
end

function Fighter:DoAirJump()
	if self.act.jumpTimes <= 0 then return end
	self:ClearAction()
	self.doingAction = nil
	self.jumpDelay = 1
	self.isJumping = true
	self.isFalling = false
	self.state = S.JUMP
end

function Fighter:RenderJumpAnimate()
	if self.jumpDelay > 0 then
		self.jumpDelay = self.jumpDelay - 1
		if self.jumpDelay <= 0 then
			self.act.jumpTimes = self.act.jumpTimes - 1
			self:GoFrame("跳", false)
			local air = self.inAir
			self.g = 0
			self:SetVelocity(0, -self.jumpPower)
			self:SetDamping(0, 0.5)
			self:SetAirAllAct()
			self.battle.fx:Effect(air and "jump_air" or "jump", self.x, self.y, self.dir)
			self.wasInAir = true
		end
		return
	end
	if self.fmc.curFrameCount == 2 then self.mcCtrl:setJumpQuick() end
	if self.vy > -self.jumpPower * 0.35 and self:CurLabel() ~= "跳中" and self:HasLabel("跳中") then
		self:GoFrame("跳中", false)
		self:FrameOut(function() self.mcCtrl:setJump() end, 5)
	end
	if self.vy >= 0 then
		self.isJumping = false
		self.isFalling = false
	end
end

function Fighter:Fall()
	if self.isFalling or self.doingAction then return end
	self:ClearState()
	self:ClearAction()
	self.state = S.NORMAL
	self:SetAirAllAct()
	self.mcCtrl:setJump()
	self.isFalling = true
	self.doingAirAction = nil
	self.isDefense = false
	self.vx = 0
	self.mcCtrl:setTouchFloor("落地", true)
	self:GoFrame("落", false)
end

function Fighter:RenderAirAction()
	local k, a = self.input, self.act
	if not self.isJumping then self:Fall() end
	self.wasInAir = true
	local function ok(win, pred) return a[win] and k[pred](k) end
	if ok("attackAIR", "attackAIR") and self:DoAirAttack(a.attackAIR) then return end
	if ok("skillAIR", "skillAIR") and self:DoAirSkill(a.skillAIR) then return end
	if ok("bishaAIR", "bishaAIR") and self:DoAirBisha(a.bishaAIR) then return end
	if (a.jump and k:jump()) or (a.jumpQuick and k:jumpQuick()) then
		if self.act.jumpTimes > 0 and not self.isJumping then self:DoAirJump() return end
	end
	if self:IsAttacking() then
		if ok("bishaSUPER", "bishaSUPER") and self:DoBisha(a.bishaSUPER, a.bishaSUPERQi, true) then return end
		if ok("bishaUP", "bishaUP") and self:DoBisha(a.bishaUP, a.bishaUPQi) then return end
		if ok("bisha", "bisha") and self:DoBisha(a.bisha, a.bishaQi) then return end
		if ok("skill2", "skill2") then self:DoSkill(a.skill2) return end
		if ok("skill1", "skill1") then self:DoSkill(a.skill1) return end
		if ok("zhao3", "zhao3") then self:DoSkill(a.zhao3) return end
		if ok("zhao2", "zhao2") then self:DoSkill(a.zhao2) return end
		if ok("attack", "attack") then self:DoAttack(a.attack) return end
		if ok("zhao1", "zhao1") then self:DoSkill(a.zhao1) return end
	end
	if ok("dash", "dash") and self.act.jumpTimes >= 1 and self:HasEnergy(30, true) then
		self:UseEnergy(30)
		self.act.jumpTimes = 0
		if k:moveLEFT() then self.dir = -1 elseif k:moveRIGHT() then self.dir = 1 end
		self:DoAction("瞬步")
		self.state = S.DASH
		self.allowBeHit, self.applyG = false, false
		return
	end
	if a.airMove then
		if k:moveLEFT() then self:Move(-self.speed, 0) elseif k:moveRIGHT() then self:Move(self.speed, 0) end
	end
end

function Fighter:DoAirAttack(label)
	if not (self.doingAction or self.act.airHitTimes > 0) then return false end
	self.act.airHitTimes = self.act.airHitTimes - 1
	self.act.jumpTimes = 0
	self.isJumping = false
	self:DoAction(label, true)
	self.state = S.ATTACK
	return true
end

function Fighter:DoAirSkill(label)
	if not (self.doingAction or self.act.airHitTimes > 0) then return false end
	local k = self.input
	if self.isJumping then
		if k.up and self:HasLabel("跳招-上") then label = "跳招-上"
		elseif k.down and self:HasLabel("跳招-下") then label = "跳招-下" end
	end
	self.act.airHitTimes, self.act.jumpTimes = 0, 0
	self.isJumping = false
	self:DoAction(label, true)
	self.state = S.SKILL
	return true
end

function Fighter:DoAirBisha(label)
	if not (self.doingAction or self.act.airHitTimes > 0) then return false end
	if not self:UseQi(self.act.bishaAIRQi or 100) then return false end
	self.act.airHitTimes = 0
	self.isJumping = false
	self:DoAction(label, true)
	self.state = S.BISHA
	return true
end

function Fighter:TouchFloor()
	self.wasInAir = false
	local act = self.act.touchFloor
	if not act and self.isFalling then act = "落地" end
	self.act.airHitTimes, self.act.jumpTimes = 1, 2
	if not act then return end
	self.isJumping = false
	self.battle.fx:Effect("touch_floor", self.x, self.y, self.dir)
	if act == "落地" then
		self:DoAction(act, false, {call = function() self.mcCtrl:setAttack() end, delay = 1})
		self.state = S.NORMAL
	else
		self:DoAction(act)
	end
end

function Fighter:DoJumpDown()
	self.ignoreFloor = 12
	self:Fall()
end

-- Bankai -------------------------------------------------------------------------------

function Fighter:RenderWanKai()
	local k = self.input
	if not k:waiKai() then return false end
	local a = self.act
	local label = nil
	if k.up and a.waiKaiW then label = a.waiKaiW
	elseif k.down and a.waiKaiS then label = a.waiKaiS
	elseif a.waiKai then label = a.waiKai end
	if not label and self:CurLabel() == "砍1" and self.doActionFrame < 2 then label = "万解" end
	if not label or not self:HasLabel(label) then return false end
	if not self:UseQi(300) then return false end
	self.state = S.WANKAI
	self:DoAction(label)
	self.state = S.WANKAI
	self.allowBeHit = false
	return true
end

-- Hurt (FighterMcHurtCtrl) ----------------------------------------------------------------

function Fighter:BeHit(h, rect)
	if not self.allowBeHit then return end
	self:BeHitInner(h, rect)
	self:AddQi(math.min(h.power * 0.08, 20))
	if self.state == S.HURT or self.state == S.HURT_FLY then
		self.currentHurts[#self.currentHurts + 1] = h
		self.currentHurtDamage = self.currentHurtDamage + damageOf(h)
	end
end

function Fighter:BeHitInner(h, rect)
	local owner = h.owner
	if self.act.hurtAction then
		local label = self.act.hurtAction
		self:DoAction(label)
		self.state = S.SKILL
		return
	end
	if self.touchSide and owner and owner.isAllowReversePush ~= false and owner.SetVec2 and math.abs(self.x - owner.x) < 100 then
		owner:SetVec2(clamp(-h.hitx * owner.dir * 1.4, -20, 20), 0, 0.3, 0)
	end
	if self.steel then
		self:DoSteelHurt(h, rect)
	elseif self.isDefense and not BVNFighter.IsCatch(h) and not (h.checkDirect and owner and self:BehindOf(owner)) then
		self:DoDefenseHit(h, rect)
	else
		self:DoHurt(h, rect)
	end
end

function Fighter:BehindOf(owner)
	if self.x < owner.x - 5 and self.dir < 0 and owner.dir < 0 then return true end
	if self.x > owner.x + 5 and self.dir > 0 and owner.dir > 0 then return true end
	return false
end

function Fighter:DoHurt(h, rect)
	self.battle.fx:HitEffect(h, rect, false, self)
	self.hurtHit = h
	self:LoseHp(damageOf(h))
	self.allowBeHit, self.beHitGap = false, 4
	if self.hp <= 0 and not self.battle.training then
		self.alive = false
		self.battle:OnDie(self)
	end
	self:DoHurtAnimate(h)
	if self.alive and h.hurtType == 0 then self.applyG = h.targetApplyG end
end

function Fighter:DoHurtAnimate(h)
	local owner = h.owner
	local hx = h.hitx * (owner and owner.dir or 1)
	local hy = h.hity
	if self.inAir then
		if hy <= 0 then hy = hy - 3 end
	elseif hy < 0 then
		hy = hy - 6
		self.inAir = true
	end
	self:ClearState()
	self:ClearAction()
	self.doingAction, self.doingAirAction = nil, nil
	self.isMoving, self.isDefensing, self.isDashing, self.isJumping, self.isFalling = false, false, false, false, false
	self.isDefense = false
	self.steel = false
	self.effCtrl:endShadow()
	self.effCtrl:endShake()
	self.moveTarget = nil
	if h.hurtType == 0 then
		self.isHurting = true
		self.hurtHold = math.max(4, BVNRuntime.ROUND(h.hurtTime / 1000 * 30) + 3)
		if h.hitType == 11 then self:GoFrame("被打", false) else self:GoFrame("被打", true, 7) end
		self.state = S.HURT
		self:SetVelocity(hx, hy)
		self:SetDamping(0.1, 0.5)
		if self.alive and HEAVY_TYPES[h.hitType] and BVNRuntime.RAND() < 0.5 then self:Voice("hurt") end
	else
		self.isHurtFlying = true
		self.state = S.HURT_FLY
		self:PlayHurtFly(hx, hy)
		self:Voice(self.alive and "hurtFly" or "die")
	end
end

function Fighter:RenderHurtAnimate()
	self.hurtHold = self.hurtHold - 1
	if self.hurtHold > 0 then return end
	self.isHurting = false
	if not self.alive then
		if self.inAir then
			self.isHurtFlying = true
			self.state = S.HURT_FLY
			self:PlayHurtFly(self.vx, self.vy)
		else
			self:PlayHurtDown()
		end
		self:Voice("die")
		return
	end
	self.justHurtResume = true
	self:Idle()
	self.allowBeHit = false
	self.battle:OnHurtResume(self)
end

function Fighter:DoDefenseHit(h, rect)
	local dmg = damageOf(h)
	self:LoseHp(dmg * 0.05)
	if self.hp <= 0 then self.hp = 1 end
	self.defenseHit = h
	local cost = h.isBreakDef and self.energyMax * 0.9 or math.min(dmg * 0.2, 50)
	cost = BVNRuntime.INT(cost)
	self.battle.fx:HitEffect(h, rect, true, self)
	if not self:HasEnergy(cost, false) then
		self:UseEnergy(cost)
		self:DoBreakDefense(h)
		return
	end
	self:UseEnergy(cost)
	self.allowBeHit, self.beHitGap = false, h.hurtType == 1 and 8 or 4
	self.isDefenseHiting = true
	if h.hurtType == 0 then
		self.defenseHold = clamp(BVNRuntime.INT(h.hurtTime / 1000 * 60 * 0.2), 5, 10)
	else
		self.defenseHold = 10
	end
	self:SetVelocity(h.hitx * (h.owner and h.owner.dir or 1), 0)
	self:SetDamping(1, 0)
end

function Fighter:DoBreakDefense(h)
	self:LoseHp(damageOf(h) * 0.1)
	self.allowBeHit, self.beHitGap = false, h.hurtType == 1 and 10 or 4
	self.overload = false
	self.isDefense, self.isDefensing, self.isDefenseHiting = false, false, false
	local hx = clamp(math.abs(h.hitx), 5, 10) * (h.owner and h.owner.dir or 1)
	self:ClearAction()
	self.isHurting = true
	self.hurtHold = 42
	self:GoFrame("被打", true, 7)
	self.state = S.HURT
	self:SetVelocity(hx, 0)
	self:SetDamping(0.1, 0)
	self.battle.fx:Named("break_def", self.x, self.y - 50, self.dir)
end

function Fighter:DoSteelHurt(h, rect)
	local dmg = damageOf(h)
	if not self.steelSuper and (self.overload or BVNFighter.IsBisha(h) or BVNFighter.IsCatch(h)) then
		self:DoHurt(h, rect)
		return
	end
	if self.steelSuper then
		self:LoseHp(dmg * 0.3)
		self.energy = math.max(0, self.energy - dmg * 0.2)
	else
		self:LoseHp(dmg * 0.65)
		self.energy = self.energy - (h.isBreakDef and dmg or dmg * 0.4)
		if self.energy < 0 then self.energy, self.overload = 0, true end
		local m = h.isBreakDef and 2 or 1
		local dir = h.owner and h.owner.dir or 1
		self:SetVec2(h.hitx * dir * m, h.hity * m, math.abs(h.hitx * 0.1), math.abs(h.hity * 0.1))
	end
	if self.hp <= 0 then self.hp = 0; self:DoHurt(h, rect) return end
	self.allowBeHit, self.beHitGap = false, h.hurtType == 1 and 10 or 4
	self.battle.fx:SteelEffect(h, rect)
end

-- Launch state machine (FighterMC.playHurtFly / renderHurtFly).
function Fighter:PlayHurtFly(hx, hy)
	if hx ~= 0 then self.dir = hx > 0 and -1 or 1 end
	local m = self.fmc
	self:GoFrame("被打", false)
	self:FrameOut(function() if self.fmc.hurtFly == 1 then self:GoFrame("击飞", false) end end, 1)
	m.heavy = hy > 5
	m.hurtFlyFrame = (m.heavy or self.inAir) and 0 or 15
	self:SetVelocity(hx, hy)
	self:SetDamping(0, 0.5)
	m.hurtFly = 1
	m.yMin = self.y
	m.stateFrames = 0
	m.hity = hy
end

function Fighter:PlayHurtDown()
	local m = self.fmc
	self:GoFrame("击飞_弹", false)
	self:FrameOut(function() self:GoFrame("击飞_倒", false) end, 2)
	m.downFrame = 15
	m.hurtFly = 4
	self.state = S.HURT_DOWN
	self:SetDamping(2, 0)
end

function Fighter:RenderHurtFly()
	local m = self.fmc
	m.stateFrames = (m.stateFrames or 0) + 1
	if m.hurtFly == 1 then
		m.yMin = math.min(m.yMin, self.y)
		m.hurtFlyFrame = m.hurtFlyFrame - 1
		if m.hurtFlyFrame <= 0 and not self.inAir then
			self:GoFrame("击飞_落", false)
			m.hurtFly, m.stateFrames = 2, 0
		end
	elseif m.hurtFly == 2 then
		if m.stateFrames >= 2 then
			local drop = self.y - m.yMin
			if m.heavy then
				self:GoFrame("击飞_倒", false)
				self.state = S.HURT_DOWN
				self:SetDamping(4, 0)
				m.downFrame = 30
				self.battle.fx:Shake(clamp(drop * 0.04 * (1 + (m.hity or 0) * 0.1), 2, 5))
				self.battle.fx:Effect("hit_floor_heavy", self.x, self.y, self.dir)
				m.hurtFly, m.stateFrames = 4, 0
			else
				self:GoFrame("击飞_弹", false)
				self.vy = -clamp(drop * 0.04, 3, 8)
				self.inAir = true
				self.state = S.HURT_DOWN_TAN
				self.battle.fx:Shake(clamp(drop * 0.04, 0.5, 3))
				self.battle.fx:Effect("hit_floor", self.x, self.y, self.dir)
				m.hurtFly, m.stateFrames = 3, 0
				self.downCounter = 1
			end
		end
	elseif m.hurtFly == 3 then
		if m.stateFrames >= 2 and not self.inAir then
			self:GoFrame("击飞_倒", false)
			self:SetDamping(2, 0)
			m.downFrame = 15
			self.state = S.HURT_DOWN
			self.battle.fx:Effect("hit_floor_low", self.x, self.y, self.dir)
			self.battle.fx:Shake(1)
			m.hurtFly, m.stateFrames = 4, 0
		end
	elseif m.hurtFly == 4 then
		if not self.alive then
			self.state = S.DEAD
			m.hurtFly = 0
			self.battle:OnDead(self)
			return
		end
		m.downFrame = m.downFrame - 1
		if m.downFrame <= 0 then
			m.hurtFly = 0
			self.isHurtFlying = false
			self:GoFrame("击飞_起", true)
		end
	end
end

-- Quick get-up while bouncing (T rate).
function Fighter:RenderHurtFlying()
	if self.state == S.HURT_DOWN_TAN then self.downCounter = 1 end
	if (self.downCounter or 0) > 0 then
		self.downCounter = self.downCounter + 1
		if self.downCounter < 20 and self.input:dashJump() and self.currentHurtDamage <= 240 and self:HasEnergy(30) and self.alive then
			self.fmc.hurtFly = 0
			self.isHurtFlying = false
			self:UseEnergy(30)
			local vx = self.vx
			self:DoAction("起身")
			self.allowBeHit = false
			self.vx = vx
			self.dx = math.abs(vx * 0.1)
			self.state = S.NORMAL
			self.battle:OnHurtResume(self)
		end
	end
end

-- Burst / substitution while staggered (T rate).
function Fighter:RenderHurtBreak()
	local k = self.input
	if not (k:special() and self.energy >= 50 and self.qi >= 100 and self.alive) then return end
	if self.hurtHit and BVNFighter.IsBisha(self.hurtHit) then return end
	for _, h in ipairs(self.currentHurts) do if h.isBreakDef then return end end
	if self.currentHurtDamage > 210 then return end
	self:UseQi(100)
	self:UseEnergy(100)
	self.isHurting = false
	if (self.char.comic_type or 0) == 1 then
		self:Move(250 * self.dir, 0)
		self:Idle()
		self.allowBeHit, self.beHitGap = false, 30
		self:FaceTarget()
		self.battle.fx:Named("replaceSp", self.x, self.y - 40, self.dir)
		self.battle:Pause(60)
	else
		self:Idle()
		self.steel, self.steelSuper = true, true
		self:DelayCall(function() self.steel, self.steelSuper = false, false end, 120)
		local h = newHitVO("explode", {power = 50, hitx = 15, hity = 0, hitType = 5, hurtType = 1}, self)
		local r = {self.x - 100, self.y - 200, 200, 210}
		self.explodeHit = {h, r}
		self.explodeFrame = 0
		self.allowBeHit, self.beHitGap = false, 10
		self.battle.fx:Named("explodeSp", self.x, self.y - 60, self.dir)
		self.battle:Pause(42)
	end
end

-- Move-target: drag the opponent toward an aim point (T rate).
function Fighter:RenderMoveTarget()
	local p = self.moveTarget
	local t = self:Target()
	if not t then return end
	local ax, ay = p.x or 0, p.y or 0
	if p.followmc then
		local cx, cy = self:ChildPos(p.followmc)
		if not cx then return end
		ax, ay = cx, cy
	end
	local spd = p.speed
	if spd and spd ~= 0 then
		local sx = type(spd) == "table" and (spd.x or 0) or spd
		local sy = type(spd) == "table" and (spd.y or 0) or spd
		sx, sy = sx * 0.5, sy * 0.5
		if math.abs(t.x - ax) <= sx then t.x = ax else t.x = t.x + sign(ax - t.x) * sx end
		if sy ~= 0 then t.vy = sign(ay - t.y) * sy; t.dy = 1 end
	else
		t.x, t.y = ax, ay
	end
end

-- Voices ------------------------------------------------------------------------------------

function Fighter:Voice(kind)
	local pool = self.voices[kind]
	if not pool or #pool == 0 then return end
	if self.voiceUntil and self.battle.tick < self.voiceUntil then return end
	local cls = pool[1 + math.floor(BVNRuntime.RAND() * #pool)]
	local clip = self.char.sounds[type(cls) == "table" and cls.name or cls]
	if clip then
		BVNSound.Play(clip, 110)
		self.voiceUntil = self.battle.tick + 40
	end
end
