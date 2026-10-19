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
	f.explodeHitFrame, f.explodeSteelFrame = 0, 0
	f.isTouchFloor = true
	if battle.training then f.trainingInputs = {} end
	f.jumpTimes, f.airHitTimes = 2, 1

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
			-- A form's scripts move main_mc to another form (sasuke_susanoo's Susanoo,
			-- byakuya's bankai without the sword): its frame script builds that form.
			if k == "gotoAndStop" or k == "gotoAndPlay" then
				return function(_, frame) if type(frame) == "number" then f:SetMainFrame(frame) end end
			end
			if k == "nextFrame" then return function() f:SetMainFrame(f.mainFrame + 1) end end
			if k == "stop" or k == "play" then return function() end end
			return nil
		end})
	if main then for k, v in pairs(main.fields) do f.mainInst[k] = v end end
	f.mainInst.S_fighter_ctrler, f.mainInst.S_mc_ctrler, f.mainInst.S_effect_ctrler = f.fCtrl, f.mcCtrl, f.effCtrl
	-- main_mc.parent (FighterMain) .parent (the game layer) .parent (the stage), whose first child
	-- is the map: ulquiorra's ultimate puts a solid bitmap over the map's backdrop and takes it away.
	f.mainInst.parent = {parent = {parent = {getChildAt = function() return battle.mapLayer end}}}
	-- FighterMain: main_mc.gotoAndStop(startFrame + 1).
	f:SetMainFrame((form or 1) + 1)
	return f
end

-- The form main_mc shows on its frame `frame` (forms start at frame 2).
function Fighter:FormAt(frame)
	local forms = self.char.forms
	local found
	for i, form in ipairs(forms) do
		if form.form_frame == frame then return i end
		if form.form_frame and form.form_frame < frame then found = i end
	end
	return found or clamp(frame - 1, 1, #forms)
end

function Fighter:SetMainFrame(frame)
	self:SetForm(self:FormAt(frame))
end

-- Switches main_mc to the frame of form index `n` and runs its script (defineAction..., initMc).
function Fighter:SetForm(n)
	local forms = self.char.forms
	n = clamp(n, 1, #forms)
	self.formIndex = n
	local form = forms[n]
	self.mainFrame = form.form_frame or (n + 1)
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
	if self.explodeHit and self.explodeHitFrame < 8 then out[#out + 1] = self.explodeHit end
	return out
end

-- World rect of a named child checker (setHitTarget), or nil.
function Fighter:CheckerRect(name)
	local f = self:Frame()
	local r = f and f.hits and (f.hits[name] or f.hits["#" .. name])
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

-- FighterAction.clearState.
function Fighter:ClearState()
	self.isMoving, self.isJumping, self.isDefensing, self.isDashing = false, false, false, false
	self.isHurting, self.isHurtFlying, self.isDefenseHiting = false, false, false
	self.act.touchFloorBreakAct = nil
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

-- FighterEvent.DO_ACTION input text (FighterInputCmd), read by the training input history.
function Fighter:LogInput(text, action, highlight)
	if not self.battle.training or not text then return end
	self.trainingInputs = self.trainingInputs or {}
	local t = self.trainingInputs
	t[#t + 1] = {input = text, action = action, highlight = highlight}
	if #t > 20 then table.remove(t, 1) end
end

-- FighterMcCtrler.doAction.
function Fighter:DoAction(label, airAct, delay)
	if label == nil then return end
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

-- FighterMcCtrler.idle.
function Fighter:Idle(frame, ignoreAlive)
	if not self.alive and not ignoreAlive then return end
	-- FighterMcHurtCtrl.onIdleEnter.
	if self:IsHurting() then self.justHurtResume = true end
	self.justDefenseFrame = 6
	self.isDefense = false
	self:EndAct()
	self.doingAction, self.doingAirAction = nil, nil
	self.steel, self.steelSuper = false, false
	self.effCtrl:endShadow()
	self.effCtrl:endShake()
	self:ClearAction()
	self:ClearState()
	self.state = S.NORMAL
	self.allowBeHit = not self.justHurtResume
	self.applyG, self.isCross = true, false
	self.hurtHit, self.defenseHit = nil, nil
	self.currentHurts, self.currentHurtDamage = {}, 0
	self.autoDirect = 0
	self.visible = true
	if not self.isTouchFloor and self.inAir then
		self:Fall()
	else
		self:SetVelocity(0, 0)
		if frame and frame ~= "站立" then
			self:GoFrame(frame, true)
		else
			self.act.jumpTimes, self.act.airHitTimes = self.jumpTimes, self.airHitTimes
			self:SetAllAct()
			self:GoFrame("站立", false)
		end
	end
	self.battle:OnIdle(self)
end

function Fighter:EndAct()
	self:ClearAction()
	self.state = S.FREEZE
	self.moveTarget = nil
end

-- Per logic tick (FighterMain.render -> FighterMcCtrler.render) -----------------------

function Fighter:Render()
	self:RenderVelocity()
	self:RenderBuffs()
	runTimers(self.delayCalls)
	if self.ghost then return end
	if self.justDefenseFrame > 0 then self.justDefenseFrame = self.justDefenseFrame - 1 end
	if self.moveTarget then self:RenderMoveTarget() end
	if self.isHurtFlying then self:RenderHurtFlying() return end
	if self.isHurting then
		if self.alive then self:RenderHurtBreak() end
		return
	end
	if self.isDefenseHiting then self:RenderDefense(false, true) return end
	if self.act.hitTarget then self:RenderCheckTargetHit() end
	if self:RenderWanKai() then return end
	if self.inAir or (self.doingAirAction and not self.act.touchFloorBreakAct) then
		self:RenderAirAction()
	else
		self:RenderFloorAction()
	end
end

-- FighterMcActionCtrl.renderCheckTargetHit.
function Fighter:RenderCheckTargetHit()
	local name = self.act.hitTargetChecker
	if not name then return end
	local r = self:CheckerRect(name)
	local t = self:Target()
	local body = t and t:BodyArea()
	if r and body and BVNBattle.Intersects(r, body) then self:DoAction(self.act.hitTarget) end
end

-- Per animate tick (FighterMain.renderAnimate -> FighterMcCtrler.renderAnimate).
function Fighter:RenderAnimate()
	runTimers(self.frameOut)
	-- FighterMcHurtCtrl.renderAnimatePrelude.
	if self.justHurtResume then
		self.allowBeHit = true
		self.justHurtResume = false
	end
	if self.beHitGap > 0 then
		self.beHitGap = self.beHitGap - 1
		if self.beHitGap <= 0 then self.allowBeHit = true end
	end
	self:RenderMcAnimate()
	if self.ghost then
		self:RenderGhost()
	else
		if self.isHurting then self:RenderHurtAnimate() end
		if self.isDefenseHiting then self:RenderDefenseHiting() end
		if self.isJumping then self:RenderJumpAnimate() end
		if self.doingAction then self.doActionFrame = self.doActionFrame + 1 end
		if self.isDefensing then self:RenderDefenseAnimate() end
	end
	-- tickAutoDirect: the idle pose turns toward the target every sixth frame.
	if self:CurLabel() == "站立" then
		self.autoDirect = (self.autoDirect or 0) + 1
		if self.autoDirect > 5 then
			self:FaceTarget()
			self.autoDirect = 0
		end
	end
	self:RenderEnergy()
	self.fzqi = math.min(self.fzqiMax, self.fzqi + 0.2)
	-- FighterMain.renderAnimate: the burst hit is live while its counter runs 7..1 of 10;
	-- its super armour is reasserted every A for 60 A.
	if self.explodeHitFrame > 0 then
		self.explodeHitFrame = self.explodeHitFrame - 1
		if self.explodeHitFrame == 8 then
			self:Idle()
			self.allowBeHit = false
		end
		if self.explodeHitFrame <= 0 then
			self.explodeHit = nil
			self.allowBeHit = true
		end
	end
	if self.explodeSteelFrame > 0 then
		self.explodeSteelFrame = self.explodeSteelFrame - 1
		self.steel, self.steelSuper = self.explodeSteelFrame > 0, self.explodeSteelFrame > 0
	end
	if (self.replaceSkillFrame or 0) > 0 then
		self.replaceSkillFrame = self.replaceSkillFrame - 1
		if self.replaceSkillFrame <= 0 then self.allowBeHit = true end
	end
end

-- Floor actions (FighterMcFloorHandler): every check runs in order; an action clears
-- the windows, which disables the later ones.
function Fighter:RenderFloorAction()
	if not self.alive then return end
	if not self.isTouchFloor then self:TouchFloor() end
	if not self.battle.actionEnable then
		local l = self:CurLabel()
		if l == "走" or l == "防御" then self:Idle() end
		return
	end
	local k, a = self.input, self.act
	local function L(win, pred) return a[win] and k[pred](k) end
	if k:special() then self.battle:DoSpecial(self) end
	if L("catch1", "catch1") then self:DoCatch(a.catch1, "J") end
	if L("catch2", "catch2") then self:DoCatch(a.catch2, "U") end
	if L("bishaSUPER", "bishaSUPER") then self:DoBisha(a.bishaSUPER, a.bishaSUPERQi, true, "SI") end
	if L("bishaUP", "bishaUP") then self:DoBisha(a.bishaUP, a.bishaUPQi, false, "WI") end
	if L("bisha", "bisha") then self:DoBisha(a.bisha, a.bishaQi, false, "I") end
	if L("skill2", "skill2") then self:DoSkill(a.skill2, "WJ") end
	if L("skill1", "skill1") then self:DoSkill(a.skill1, "SJ") end
	if L("zhao3", "zhao3") then self:DoSkill(a.zhao3, "WU") end
	if L("zhao2", "zhao2") then self:DoSkill(a.zhao2, "SU") end
	if L("attack", "attack") then self:DoAttack(a.attack) end
	if L("zhao1", "zhao1") then self:DoSkill(a.zhao1, "U") end
	if L("defense", "defense") then self:DoDefense() end
	if L("dash", "dash") then self:DoDash(a.dash) end
	if L("moveLeft", "moveLEFT") then self:DoMove() end
	if L("moveRight", "moveRIGHT") then self:DoMove() end
	if L("jump", "jump") then self:DoJump() end
	if L("jumpDown", "jumpDown") then self:DoJumpDown(a.jumpDown) end
	if self.isMoving then self:RenderMoving() end
	if self.isDefensing then self:RenderDefense(true, false) end
	if self:AllowGhost() and k:ghostStep() then self:StartGhost(0) end
	if self:AllowGhost() and k:ghostJump() then self:StartGhost(1) end
	if self:IsAttacking() then
		if L("attackAIR", "attackAIR") then self:DoAirAttack(a.attackAIR) end
		if L("skillAIR", "skillAIR") then self:DoAirSkill(a.skillAIR) end
		if L("bishaAIR", "bishaAIR") then self:DoAirBisha(a.bishaAIR, a.bishaAIRQi) end
	end
end

function Fighter:RenderMoving()
	local k = self.input
	if k:moveLEFT() then
		self.dir = -1
		self.mcCtrl:move(self.speed)
	elseif k:moveRIGHT() then
		self.dir = 1
		self.mcCtrl:move(self.speed)
	else
		self:Idle()
	end
end

function Fighter:DoMove()
	if self.isMoving then return end
	self:GoFrame(self.act.moveLeft == true and "走" or (self.act.moveLeft or "走"), true)
	self.state = S.NORMAL
	self:SetMoveAction()
end

function Fighter:SetMoveAction()
	self:ClearAction()
	self.isMoving = true
	local a, mc = self.act, self.mcCtrl
	a.moveLeft, a.moveRight = true, true
	mc:setAttack(); mc:setZhao1(); mc:setZhao3(); mc:setSkill2(); mc:setJump(); mc:setDash()
	mc:setBisha(); mc:setBishaUP(); a.defense = true; mc:setCatch1(); mc:setCatch2()
end

function Fighter:DoAttack(label)
	self:DoAction(label)
	self.state = S.ATTACK
	self:LogInput("J", label)
end

function Fighter:DoSkill(label, cmd)
	self:DoAction(label)
	self.state = S.SKILL
	self:LogInput(cmd, label)
end

function Fighter:DoBisha(label, qi, super, cmd)
	if not self:UseQi(qi or 100) then return false end
	self.state = super and S.BISHA_SUPER or S.BISHA
	self:DoAction(label)
	self:LogInput(cmd, label)
	return true
end

function Fighter:AllowCatch()
	local t = self:Target()
	if not t then return false end
	if t.kind == "fighter" and t.state == S.HURT then return false end
	local tb, sb = t:BodyArea(), self:BodyArea()
	if not tb or not sb then return false end
	local disY = math.abs(self.y - t.y)
	local disX
	if sb[1] < tb[1] then
		if self.dir < 0 then return false end
		disX = tb[1] - (sb[1] + sb[3])
	else
		if self.dir > 0 then return false end
		disX = sb[1] - (tb[1] + tb[3])
	end
	return disX < 2 and disY < 1
end

function Fighter:DoCatch(label, btn)
	if not self:AllowCatch() then return end
	local k = self.input
	local side = (k:moveRIGHT() and "D") or (k:moveLEFT() and "A") or (self.dir > 0 and "D" or "A")
	self:DoAction(label)
	self.state = S.SKILL
	self:LogInput(side .. (btn or "J"), label)
end

function Fighter:DoDash(label)
	if not self:HasEnergy(20, true) then return end
	self:UseEnergy(20)
	local k = self.input
	if k:moveLEFT() then self.dir = -1 end
	if k:moveRIGHT() then self.dir = 1 end
	self:DoAction(label or "瞬步")
	self.state = S.DASH
	self.allowBeHit, self.applyG = false, false
	self:LogInput("L", label)
end

-- Defense (FighterMcHurtCtrl) ------------------------------------------------------------

function Fighter:DoDefense()
	if self.isDefensing then return end
	self.state = S.DEFENSE
	self.mcCtrl:dampingPercent(1, 1)
	self:SetDefenseAction(true, false)
end

function Fighter:SetDefenseAction(setActions, justDefense)
	if setActions then
		self:ClearAction()
		self:ClearState()
		self.isDefensing = true
		local mc = self.mcCtrl
		mc:setSkill1(); mc:setZhao2(); mc:setBishaSUPER(); mc:setJumpDown()
	end
	if justDefense then self.isDefense = true else self.isDefense = self.justDefenseFrame > 0 end
	self.defenseFrameDelay = 1
	self:GoFrame("防御", true, 3)
end

-- renderDefense: turning while guarding re-enters the guard.
function Fighter:RenderDefense(setActions, justDefense)
	local k = self.input
	if k:moveLEFT() and self.dir ~= -1 then
		self.dir = -1
		self:SetDefenseAction(setActions, justDefense)
	end
	if k:moveRIGHT() and self.dir ~= 1 then
		self.dir = 1
		self:SetDefenseAction(setActions, justDefense)
	end
end

function Fighter:RenderDefenseAnimate()
	if self.isDefenseHiting then return end
	local d = self.defenseFrameDelay
	self.defenseFrameDelay = d - 1
	if d > 0 then return end
	if self.battle.actionEnable and self.input:defense() then
		self.isDefense = true
		return
	end
	if self.defenseFrameDelay > -5 then return end
	-- Still guarding through 防御恢复 until idle runs one A later.
	self.isDefensing = false
	self:GoFrame("防御恢复", false, 0, {delay = 1, call = function() self:Idle() end})
end

-- After the guard knockback the fighter simply keeps guarding.
function Fighter:RenderDefenseHiting()
	if self.defenseHold > 0 then
		self.defenseHold = self.defenseHold - 1
	elseif self.vx == 0 then
		self.isDefenseHiting = false
	end
end

-- Air (FighterMcAirHandler) ------------------------------------------------------------

function Fighter:TouchFloor()
	if not self.alive then return end
	local act = self.act.touchFloor
	if self.isFalling and not act then act = "落地" end
	if act == nil then return end
	local delay = act == "落地" and {call = function() self.mcCtrl:setAttack() end, delay = 1} or nil
	self:DoAction(act, false, delay)
	self.effCtrl:touchFloor()
	self.act.airHitTimes, self.act.jumpTimes = self.airHitTimes, self.jumpTimes
	self.isTouchFloor = true
	self.isFalling = false
end

function Fighter:RenderJumpAnimate()
	if self.doingAction then return end
	if (self.jumpDelay or 0) > 0 then
		self.jumpDelay = self.jumpDelay - 1
		if self.jumpDelay == 0 then
			self.isFalling = false
			self.act.jumpTimes = self.act.jumpTimes - 1
			self:GoFrame("跳", false)
			-- FighterMain.jump
			self.g = 0
			self:SetVelocity(0, -self.jumpPower)
			self:SetDamping(0, 0.5)
			self:SetAirAllAct()
			if self.inAir then self.effCtrl:jumpAir() else self.effCtrl:jump() end
		end
		return
	end
	if self.fmc.curFrameCount == 2 then self.mcCtrl:setJumpQuick() end
	if self:CurLabel() ~= "跳中" and self.vy > -self.jumpPower * 0.35 then
		self:GoFrame("跳中", false)
		self:FrameOut(function() self.mcCtrl:setJump() end, 5)
	end
	if self.vy >= 0 then
		self.isJumping = false
		self.isFalling = true
	end
end

function Fighter:RenderAirAction()
	if not self.alive then return end
	if not self.isJumping then self:Fall() end
	self.isTouchFloor = false
	if not self.battle.actionEnable then return end
	local k, a = self.input, self.act
	local function L(win, pred) return a[win] and k[pred](k) end
	if L("attackAIR", "attackAIR") then self:DoAirAttack(a.attackAIR) end
	if L("skillAIR", "skillAIR") then self:DoAirSkill(a.skillAIR) end
	if L("bishaAIR", "bishaAIR") then self:DoAirBisha(a.bishaAIR, a.bishaAIRQi) end
	if L("jump", "jump") then self:DoAirJump() end
	if L("jumpQuick", "jumpQuick") then self:DoAirJump() end
	if self:IsAttacking() then
		if L("bishaSUPER", "bishaSUPER") then self:DoBisha(a.bishaSUPER, a.bishaSUPERQi, true, "SI") end
		if L("bishaUP", "bishaUP") then self:DoBisha(a.bishaUP, a.bishaUPQi, false, "WI") end
		if L("bisha", "bisha") then self:DoBisha(a.bisha, a.bishaQi, false, "I") end
		if L("skill2", "skill2") then self:DoSkill(a.skill2, "WJ") end
		if L("skill1", "skill1") then self:DoSkill(a.skill1, "SJ") end
		if L("zhao3", "zhao3") then self:DoSkill(a.zhao3, "WU") end
		if L("zhao2", "zhao2") then self:DoSkill(a.zhao2, "SU") end
		if L("attack", "attack") then self:DoAttack(a.attack) end
		if L("zhao1", "zhao1") then self:DoSkill(a.zhao1, "U") end
	end
	if L("dash", "dash") then self:DoDashAir(a.dash) end
	if a.airMove then
		if k:moveLEFT() then self:Move(-self.speed, 0) end
		if k:moveRIGHT() then self:Move(self.speed, 0) end
	end
	if self:AllowGhost() and k:ghostJump() then self:StartGhost(1) end
	if self:AllowGhost() and k:ghostStep() then self:StartGhost(2) end
end

function Fighter:Fall()
	if self.isFalling or self.doingAction then return end
	self:ClearState()
	self:ClearAction()
	self:SetAirAllAct()
	self.mcCtrl:setJump()
	self.isFalling = true
	self.doingAirAction = nil
	self.isTouchFloor = false
	self.isDefense = false
	self.vx = 0
	self.mcCtrl:setTouchFloor("落地", true)
	self:GoFrame("落", false)
end

function Fighter:DoDashAir(label)
	if self.act.jumpTimes < 1 or not self:HasEnergy(30, true) then return end
	self:UseEnergy(30)
	self:DoAction(label or "瞬步")
	self.state = S.DASH
	self.allowBeHit, self.applyG = false, false
	self.act.jumpTimes = 0
	self:LogInput("L", label)
end

function Fighter:DoJump()
	if self.act.jumpTimes <= 0 then return end
	self:ClearAction()
	self:ClearState()
	self.doingAction, self.doingAirAction = nil, nil
	self:GoFrame("起跳", false)
	self.jumpDelay = 2
	self.isJumping = true
	self.state = S.JUMP
	self:LogInput("K", "跳")
end

-- doJumpDown: drop through a platform at speed 5 (platforms refuse vy >= 2.5).
function Fighter:DoJumpDown(label)
	if self.touchBottom then return end
	self:ClearState()
	self:ClearAction()
	self.act.jumpTimes = 0
	self.vy = 5
	self:SetDamping(0, 1)
	self.y = self.y + 1
	self.isDefense = false
	if label and label ~= true then self:GoFrame(label, false) end
	self.mcCtrl:setTouchFloor()
end

function Fighter:DoAirJump()
	if self.act.jumpTimes <= 0 then return end
	self:ClearAction()
	self:ClearState()
	self.doingAction, self.doingAirAction = nil, nil
	self.jumpDelay = 1
	self.isJumping = true
	self.state = S.JUMP
	self:LogInput("K", "跳")
end

function Fighter:DoAirAttack(label)
	if not self.doingAction and self.act.airHitTimes <= 0 then return end
	self.dy = self.dy + 3
	self.act.airHitTimes = self.act.airHitTimes - 1
	self.act.jumpTimes = 0
	self:DoAction(label, true)
	self.state = S.ATTACK
	self:LogInput("KJ", label)
end

function Fighter:DoAirSkill(label)
	if not self.doingAction and self.act.airHitTimes <= 0 then return end
	local cmd = "KU"
	if self.isJumping then
		local k, act = self.input, nil
		if k:zhao3() then act = "跳招-上" end
		if k:zhao2() then act = "跳招-下" end
		if act and self:HasLabel(act) then label, cmd = act, act == "跳招-上" and "WKU" or "SKU" end
	end
	self.act.airHitTimes, self.act.jumpTimes = 0, 0
	self:DoAction(label, true)
	self.state = S.SKILL
	self:LogInput(cmd, label)
end

function Fighter:DoAirBisha(label, qi)
	if not self.doingAction and self.act.airHitTimes <= 0 then return end
	if not self:UseQi(qi or 100) then return end
	self.state = S.BISHA
	self.act.airHitTimes = 0
	self:DoAction(label, true)
	self:LogInput("KI", label)
end

-- Ghost step (FighterMcGhostHandler): dash with down (step / drop) or up (jump).
function Fighter:AllowGhost()
	local s = self.state
	return not self.ghost and s ~= S.BISHA and s ~= S.BISHA_SUPER and s ~= S.WANKAI and self.alive
end

function Fighter:StartGhost(kind)
	if self.qi < 60 or not self:HasEnergy(80, true) then return false end
	self:UseQi(60)
	self:UseEnergy(80)
	self:FaceTarget()
	self.ghost = {frames = 12, kind = kind}
	self.allowBeHit, self.isCross = false, true
	if kind == 0 then
		self.mcCtrl:move(8, 0)
		self:GoFrame("走", true)
	elseif kind == 1 then
		self.mcCtrl:move(0, -12)
		self:SetDamping(0, 0.1)
		self:GoFrame("跳", false)
		self.act.jumpTimes = self.act.jumpTimes - 1
	else
		self.mcCtrl:move(0, 15)
		self:GoFrame("落", false)
	end
	-- FighterEffectCtrl.ghostStep: blue afterimages, the black backdrop, only this fighter runs.
	self.battle.fx:StartShadow(self, 0, 0, 255)
	self.battle.fx:GhostStep(self)
	self:LogInput(kind == 1 and "WL" or "SL")
	return true
end

-- renderGhostStep: `if (_ghostStepFrame-- <= 0)` with 0.4 s of animate frames.
function Fighter:RenderGhost()
	local g = self.ghost
	local n = g.frames
	g.frames = n - 1
	if n <= 0 then
		if g.kind == 1 then
			local vy = self.vy
			self.isJumping = false
			self:EndGhost()
			self:SetVelocity(0, vy)
			self:SetDamping(0, -vy / 10)
			self.mcCtrl:setAirMove(true)
			return
		end
		self:EndGhost()
	end
	if self.ghost and g.kind == 2 and self.touchBottom then self:EndGhost() end
end

function Fighter:EndGhost()
	self.ghost = nil
	self.battle.fx:EndShadow(self)
	self.battle.fx:EndGhostStep(self)
	self:FaceTarget()
	self:Idle()
end

-- Bankai -------------------------------------------------------------------------------

-- renderWanKaiCtrl: attack + jump (+ up / down). Early in 砍1 each falls back to 万解 / 万解W / 万解S.
-- A bankai input ends the tick even when it cannot be paid for.
function Fighter:RenderWanKai()
	if not self.battle.actionEnable then return false end
	local k, a = self.input, self.act
	local function check(win, fallback)
		if win then self:DoWaiKai(win) return true end
		if self.doingAction == "砍1" and self.doActionFrame < 2 then self:DoWaiKai(fallback) return true end
		return false
	end
	if k:waiKai() then return check(a.waiKai, "万解") end
	if k:waiKaiW() then return check(a.waiKaiW, "万解W") end
	if k:waiKaiS() then return check(a.waiKaiS, "万解S") end
	return false
end

function Fighter:DoWaiKai(label)
	if not self:HasLabel(label) or not self:UseQi(300) then return end
	self.state = S.WANKAI
	self:DoAction(label)
	self.allowBeHit = false
	self:LogInput(({["万解"] = "JK", ["万解W"] = "WJK", ["万解S"] = "SJK"})[label] or "JK", label)
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
		self.state = S.HURT_ACT
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
	self.battle.fx:HitEffect(h, rect, self)
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
		self.isTouchFloor = false
	end
	self:ClearState()
	self:ClearAction()
	self.doingAction, self.doingAirAction = nil, nil
	self.isMoving, self.isDefensing, self.isDashing, self.isJumping, self.isFalling = false, false, false, false, false
	self.isDefense = false
	self.applyG = true
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
	-- `if (_hurtHoldFrame-- <= 0)`: the stagger ends on call hold + 1.
	if self.hurtHold > 0 then self.hurtHold = self.hurtHold - 1 return end
	self.isHurting = false
	if not self.alive then
		if self.inAir then
			-- hurtFly(vec2): the second velocity, mirrored by facing, straight to 击飞.
			self.mcCtrl:hurtFly(self.v2x, self.v2y)
		else
			self:PlayHurtDown()
		end
		self:Voice("die")
		return
	end
	-- hurtResume: back on the floor without a landing.
	if not self.inAir and not self.isTouchFloor then self.isTouchFloor = true end
	self:Idle()
	self.battle:OnHurtResume(self)
end

function Fighter:DoDefenseHit(h, rect)
	local dmg = damageOf(h)
	self:LoseHp(dmg * 0.05)
	if self.alive and self.hp <= 0 and not self.battle.training then
		self.alive = false
		self.battle:OnDie(self)
		self:DoHurt(h, rect)
		return
	end
	self.defenseHit = h
	local cost = h.isBreakDef and self.energyMax * 0.9 or math.min(dmg * 0.2, 50)
	cost = BVNRuntime.INT(cost)
	if not self:HasEnergy(cost, false) then
		self:UseEnergy(cost)
		self:DoBreakDefense(h, rect)
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
	self.battle.fx:DefenseEffect(h, rect, self.defenseType, self)
end

function Fighter:DoBreakDefense(h, rect)
	self:LoseHp(damageOf(h) * 0.1)
	self.allowBeHit, self.beHitGap = false, h.hurtType == 1 and 10 or 4
	self.overload = false
	self.isDefense, self.isDefensing, self.isDefenseHiting = false, false, false
	local hx = clamp(h.hitx, 5, 10) * (h.owner and h.owner.dir or 1)
	self:ClearAction()
	self.isHurting = true
	self.hurtHold = 42
	self:GoFrame("被打", true, 7)
	self.state = S.HURT
	self:SetVelocity(hx, 0)
	self:SetDamping(0.1, 0)
	if rect then
		local r = rect
		self.battle.fx:DefenseEffect(h, r, self.defenseType, self)
		self.battle.fx:Effect("break_def", r[1] + r[3] * 0.5, r[2] + r[4] * 0.5, self.dir)
	end
end

function Fighter:DoSteelHurt(h, rect)
	local dmg = damageOf(h)
	if not self.steelSuper and (self.overload or BVNFighter.IsBisha(h) or BVNFighter.IsCatch(h)) then
		self:DoHurt(h, rect)
		return
	end
	if self.steelSuper then
		self:LoseHp(dmg * 0.3)
		self:UseEnergy(dmg * 0.2)
	else
		self:LoseHp(dmg * 0.65)
		self:UseEnergy(h.isBreakDef and dmg or dmg * 0.4)
		local m = h.isBreakDef and 2 or 1
		local dir = h.owner and h.owner.dir or 1
		self:SetVec2(h.hitx * dir * m, h.hity * m, math.abs(h.hitx * 0.1), math.abs(h.hity * 0.1))
	end
	if self.hp <= 0 then self.hp = 0; self:DoHurt(h, rect) return end
	self.allowBeHit, self.beHitGap = false, h.hurtType == 1 and 10 or 4
	self.battle.fx:SteelEffect(h, rect, self)
end

-- FighterEffectCtrl.hitFloor: a floor impact effect and a vertical shake of twice the power.
function Fighter:HitFloor(effect, pow)
	if self.musouEnemy and not self.musouBoss and pow > 1 then pow = 1 end
	if pow > 0 then self.battle.fx:Shake(0, pow * 2, 0) end
	self.battle.fx:Effect(effect, self.x, self.y)
	if effect == "hit_floor_heavy" then self.battle.fx:Effect("hit_floor_yan", self.x, self.y) end
end

-- Launch state machine (FighterMC.playHurtFly / renderHurtFly).
function Fighter:PlayHurtFly(hx, hy, showBeHit)
	if hx ~= 0 then self.dir = hx > 0 and -1 or 1 end
	local m = self.fmc
	self.downCounter = 0
	if showBeHit == false then
		self:GoFrame("击飞", false)
	else
		self:GoFrame("被打", false)
		self:FrameOut(function() if self.fmc.hurtFly == 1 then self:GoFrame("击飞", false) end end, 1)
	end
	m.heavy = hy > 5
	m.hurtFlyFrame = (m.heavy or self.inAir) and 0 or 15
	self:SetVelocity(hx, hy)
	self:SetDamping(0, 0.5)
	m.hurtFly = 1
	m.yMin = self.y
	m.hity = hy
end

function Fighter:PlayHurtDown()
	local m = self.fmc
	m.hurtFly = 0
	self:GoFrame("击飞_弹", false, 0, {delay = 2, call = function()
		self:GoFrame("击飞_倒", false)
		m.downFrame = 15
		m.hurtFly = 4
		self.state = S.HURT_DOWN
	end})
	self:HitFloor("hit_floor_low", 2)
	self:SetDamping(2, 0)
end

function Fighter:RenderHurtFly()
	local m = self.fmc
	if m.hurtFly == 1 then
		m.yMin = math.min(m.yMin, self.y)
		m.hurtFlyFrame = m.hurtFlyFrame - 1
		if m.hurtFlyFrame <= 0 and not self.inAir then
			self:GoFrame("击飞_落", true)
			m.hurtFly = 2
		end
	elseif m.hurtFly == 2 then
		if m.curFrameCount >= 2 then
			local drop = self.y - m.yMin
			if m.heavy then
				self:GoFrame("击飞_倒", false)
				self.state = S.HURT_DOWN
				self:SetDamping(4, 0)
				m.downFrame = 30
				self:HitFloor("hit_floor_heavy", clamp(drop * 0.04 * (1 + (m.hity or 0) * 0.1), 2, 5))
				m.hurtFly = 4
			else
				self:GoFrame("击飞_弹", false)
				self.vy = -clamp(drop * 0.04, 3, 8)
				self.state = S.HURT_DOWN_TAN
				-- The clamped bounce speed is >= 3, so the shake power is always 3.
				self:HitFloor("hit_floor", 3)
				m.hurtFly = 3
				self.downCounter = 1
			end
		end
	elseif m.hurtFly == 3 then
		if m.curFrameCount >= 2 and not self.inAir then
			self:GoFrame("击飞_倒", false)
			self:SetDamping(2, 0)
			m.downFrame = 15
			self.state = S.HURT_DOWN
			self:HitFloor("hit_floor_low", 1)
			m.hurtFly = 4
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
-- FighterMcHurtCtrl.renderHurtFlying: quick get-up (受身) within 20 T of a bounce.
function Fighter:RenderHurtFlying()
	if not self.inAir then self.isTouchFloor = true end
	if not self.alive then return end
	if self.state == S.HURT_DOWN_TAN then self.downCounter = 1 end
	if (self.downCounter or 0) > 0 then
		if not self.battle.actionEnable then return end
		self.downCounter = self.downCounter + 1
		if self.downCounter < 20 and self.input:dashJump() then
			self:DoHurtDownJump()
			self.downCounter = 0
		end
	end
end

function Fighter:DoHurtDownJump()
	if self.doingAction == "起身" or self.currentHurtDamage > 240 or not self:HasEnergy(30) then return end
	self.fmc.hurtFly = 0
	self:UseEnergy(30)
	local vx = self.vx
	self:DoAction("起身")
	self:LogInput("L", "起身", true)
	self.allowBeHit = false
	self.vx = vx
	-- setDamping(vecx * 0.1) is signed: a negative speed is never damped.
	self.dx = vx * 0.1
	self.battle:OnHurtResume(self)
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
	self:LogInput("O", nil, true)
	self.isHurting = false
	if (self.char.comic_type or 0) == 1 then
		-- FighterMain.replaceSkill: substitution 250 ahead, untouchable for 30 A.
		self.battle.fx:ReplaceSkill(self)
		self:Move(250 * self.dir, 0)
		self:Idle()
		self.allowBeHit = false
		self:RenderAnimate()
		self:FaceTarget()
		self.replaceSkillFrame = 30
	else
		-- FighterMain.energyExplode (hitx = 15 * direct, which the hurt code multiplies by direct again).
		self.battle.fx:EnergyExplode(self)
		self.steel, self.steelSuper = true, true
		local h = newHitVO("explode", {power = 50, hitx = 15 * self.dir, hity = 0, hitType = 5, hurtType = 1}, self)
		local r = {self.x - 100, self.y - 200, 200, 210}
		self.explodeHit = {h, r}
		self.explodeHitFrame = 10
		self.explodeSteelFrame = 60
		self.allowBeHit = false
	end
	self.battle:OnHurtResume(self)
end

-- Move-target (FighterMcActionCtrl.renderMoveTarget): pin the opponent to a child of the
-- action clip (followmc), or step it toward a point at speed * SPEED_PLUS per tick.
function Fighter:RenderMoveTarget()
	local p = self.moveTarget
	local t = self:Target()
	if not t then return end
	local ax, ay
	if p.followmc then
		local f = self:Frame()
		local c = f and f.hits and f.hits["@" .. p.followmc]
		if not c then return end
		ax, ay = self.x + c[1] * self.dir, self.y + c[2]
	else
		ax, ay = p.x or 0, p.y or 0
	end
	local spd = p.speed
	if spd and spd ~= 0 then
		local sx = (type(spd) == "table" and (spd.x or 0) or spd) * 0.5
		local sy = (type(spd) == "table" and (spd.y or 0) or spd) * 0.5
		if sx > 0 then
			if t.x > ax + sx then t.x = t.x - sx end
			if t.x < ax - sx then t.x = t.x + sx end
			if t.y > ay + sy then t.vy, t.dy = -sy, 1 end
			if t.y < ay - sy then t.vy, t.dy = sy, 1 end
		end
	else
		t.x, t.y = ax, ay
	end
end

-- FighterMain.attackRate setter: the rate becomes powerRate of every HitVO defined
-- so far (moves a later form defines start again at 1, as in the original).
function Fighter:SetAttackRate(v)
	self.attackRate = v
	for _, h in pairs(self.hitModel) do h.powerRate = v end
end

-- FighterBuffCtrler: a buff changes one field for `hold` seconds, then restores it.
function Fighter:AddBuff(param, value, hold)
	self.buffs = self.buffs or {}
	local b = self.buffs[param]
	if not b then
		b = {resume = self[param]}
		self.buffs[param] = b
	end
	b.frames = (hold or 5) * 60
	local v = b.resume + value
	if param == "attackRate" then self:SetAttackRate(v) else self[param] = v end
	return b
end

function Fighter:RenderBuffs()
	if not self.buffs then return end
	for param, b in pairs(self.buffs) do
		b.frames = b.frames - 1
		if b.frames <= 0 then
			if param == "attackRate" then self:SetAttackRate(b.resume) else self[param] = b.resume end
			b.done = true
			self.buffs[param] = nil
		end
	end
end

-- Script-facing FighterMain methods (assist scripts reach the owner and target directly).
function Fighter:getCtrler() return self.fCtrl end
function Fighter:getBuffCtrl() return self.fCtrl:getBuffCtrl() end
function Fighter:getCurrentTarget() return self end
function Fighter:getMcCtrl() return self.mcCtrl end
function Fighter:useEnergy(v) self:UseEnergy(v or 0) end
function Fighter:addHp(v) self.hp = math.min(self.hpMax, self.hp + (v or 0)) end
function Fighter:loseHp(v) self:LoseHp(v or 0) end
function Fighter:getIsTouchSide() return self.touchSide end
function Fighter:getDisplay() return BVNClip.Facade(self) end

-- Colour transforms (changeColor / resumeColor): {r, g, b} offsets over the base colour.
function Fighter:ChangeColor(ct) self.color = ct end
function Fighter:ResumeColor() self.color = self.colorBase end

-- The current pose as world-space image draws, for afterimages.
function Fighter:Snapshot()
	local fo = self.formOffset
	local out = {}
	BVNClip.Draw(self.clip, self.x, self.y, self.dir, {capture = out}, {fo[3], 0, 0, fo[4], fo[1], fo[2]})
	return #out > 0 and out or nil
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
