-- The controller objects 5DPLAY character scripts call: $mc_ctrler (McCtrl),
-- $effect_ctrler (EffCtrl) and $fighter_ctrler (FCtrl). Each holds `f`, the
-- fighter. Methods are called with Lua's `:` (self = controller).
local S = {NORMAL = 0, SKILL = 11, HURT_ACT = 16, HURT_FLY = 22, WANKAI = 50}

local function label(f, l, default)
	l = l or default
	if f:HasLabel(l) then return l end
	return nil
end

local McCtrl = {}
BVNCtrl = {Mc = McCtrl}

function McCtrl:idle(frame, ignoreAlive) self.f:Idle(frame, ignoreAlive) end
function McCtrl:endAct() self.f:EndAct() end
function McCtrl:loop(l) self.f:GoFrame(l, true) end
function McCtrl:gotoAndPlay(l) self.f:GoFrame(l, true) end
function McCtrl:gotoAndStop(l) self.f:GoFrame(l, false) end
function McCtrl:stop() self.f.fmc.play = false end
function McCtrl:addQi(n) self.f:AddQi(n or 0) end
function McCtrl:isApplyG(v) self.f.applyG = BVNRuntime.T(v) end

function McCtrl:move(x, y)
	local f = self.f
	x, y = x or 0, y or 0
	if x == 0 and y == 0 then f:SetVelocity(0, 0) return end
	if f.inAir and x ~= 0 then f.act.airMove = nil end
	f:SetVelocity(x * f.dir, y)
end
function McCtrl:movePercent(x, y) self:move(self.f.speed * (x or 0), self.f.speed * (y or 0)) end
function McCtrl:stopMove() self.f:SetVelocity(0, 0) end
function McCtrl:damping(x, y) self.f:SetDamping(x or 0, y or 0) end
function McCtrl:dampingPercent(x, y) self.f:SetDamping(self.f.speed * (x or 0), self.f.speed * (y or 0)) end

function McCtrl:dash(plus)
	local f = self.f
	f.isDashing = true
	f:SetVelocity(f.speed * (plus or 3) * f.dir, 0)
	f.isCross, f.allowBeHit = true, false
end
function McCtrl:dashStop(lose)
	local f = self.f
	f:SetDamping(math.abs(f.vx) * (lose or 0.5), 0)
	f.allowBeHit = true
	f.state = S.NORMAL
	f:ClearAction()
	f.isCross = false
	f.isDashing = false
	f.applyG = true
end

function McCtrl:setSteelBody(v, super)
	self.f.steel = BVNRuntime.T(v)
	self.f.steelSuper = BVNRuntime.T(v) and BVNRuntime.T(super)
end

local function win(field, default)
	return function(self, l)
		local lb = label(self.f, l, default)
		if lb then self.f.act[field] = lb end
	end
end
McCtrl.setAttack = win("attack", "砍1")
McCtrl.setSkill1 = win("skill1", "砍技1")
McCtrl.setSkill2 = win("skill2", "砍技2")
McCtrl.setZhao1 = win("zhao1", "招1")
McCtrl.setZhao2 = win("zhao2", "招2")
McCtrl.setZhao3 = win("zhao3", "招3")
McCtrl.setCatch1 = win("catch1", "摔1")
McCtrl.setCatch2 = win("catch2", "摔2")
McCtrl.setDash = win("dash", "瞬步")
McCtrl.setJump = function(self) self.f.act.jump = "跳" end
McCtrl.setJumpQuick = function(self) self.f.act.jumpQuick = "跳" end
McCtrl.setJumpDown = function(self) self.f.act.jumpDown = "落" end
McCtrl.setAttackAIR = win("attackAIR", "跳砍")
McCtrl.setSkillAIR = win("skillAIR", "跳招")
function McCtrl:setDefense() self.f.act.defense = true end
function McCtrl:setMove() self.f.act.moveLeft, self.f.act.moveRight = true, true end
function McCtrl:setMoveLeft() self.f.act.moveLeft = true end
function McCtrl:setMoveRight() self.f.act.moveRight = true end
function McCtrl:setAirMove(v) self.f.act.airMove = BVNRuntime.T(v) or nil end

local function bisha(field, default, defaultQi)
	return function(self, l, qi)
		local lb = label(self.f, l, default)
		if lb then
			self.f.act[field] = lb
			self.f.act[field .. "Qi"] = qi or defaultQi
		end
	end
end
McCtrl.setBisha = bisha("bisha", "必杀", 100)
McCtrl.setBishaUP = bisha("bishaUP", "上必杀", 100)
McCtrl.setBishaSUPER = bisha("bishaSUPER", "超必杀", 300)
McCtrl.setBishaAIR = bisha("bishaAIR", "空中必杀", 100)

function McCtrl:setWankai()
	local f = self.f
	if f:HasLabel("万解") then f.act.waiKai = "万解" end
	if f:HasLabel("万解W") then f.act.waiKaiW = "万解W" end
	if f:HasLabel("万解S") then f.act.waiKaiS = "万解S" end
end

function McCtrl:setAllAct() self.f:SetAllAct() end
function McCtrl:setAirAllAct() self.f:SetAirAllAct() end

function McCtrl:setTouchFloor(l, breakAct)
	local f = self.f
	f.act.touchFloor = label(f, l, "落地")
	if breakAct == nil then breakAct = true end
	f.act.touchFloorBreakAct = BVNRuntime.T(breakAct) or nil
	if not BVNRuntime.T(breakAct) then f.act.touchFloorBreakAct = false end
end

function McCtrl:setHitTarget(checker, l)
	local f = self.f
	local lb = label(f, l, nil)
	if lb then
		f.act.hitTarget = lb
		f.act.hitTargetChecker = checker
	end
end

function McCtrl:setHurtAction(l)
	local lb = label(self.f, l, nil)
	if lb then
		self.f.act.hurtAction = lb
		self.f.state = S.HURT_ACT
	end
end

function McCtrl:fire(name, params)
	local f = self.f
	if not f.battle:FireBullet(f, name, params or {}) then
		f:FrameOut(function() f.battle:FireBullet(f, name, params or {}) end, 1)
	end
end

function McCtrl:addAttacker(name, params)
	local f = self.f
	if not f.battle:AddAttacker(f, name, params or {}) then
		f:FrameOut(function() f.battle:AddAttacker(f, name, params or {}) end, 1)
	end
end

function McCtrl:getAttacker(name)
	local a = self.f.battle:FindAttacker(name, self.f.team)
	return a and a.ctrl or nil
end

function McCtrl:moveTarget(params)
	local f = self.f
	if params == nil then
		f.moveTarget = nil
		local t = f:Target()
		if t then t.applyG = true end
		return
	end
	f.moveTarget = params
	local t = f:Target()
	if t then t:SetVelocity(0, 0) end
end

function McCtrl:justHitToPlay(id, l, noIdle, inclDef)
	local f = self.f
	if f.fCtrl:justHit(id, inclDef) then
		f:GoFrame(l, true)
	elseif BVNRuntime.T(noIdle) then
		f:Idle()
	end
end

function McCtrl:hurtFly(x, y)
	local f = self.f
	f.isHurtFlying = true
	f.state = S.HURT_FLY
	f:PlayHurtFly((x or 0) * f.dir, y or 0)
end

function McCtrl:getAction() return self.f.act end
function McCtrl:getCurAction() return self.f.doingAction end
function McCtrl:doAction(l) self.f:DoAction(l) end
function McCtrl:setHitTargetChecker() end
function McCtrl:moveMC() end

-- $effect_ctrler -----------------------------------------------------------------------

local EffCtrl = {}
BVNCtrl.Eff = EffCtrl

function EffCtrl:shine(color) self.f.battle.fx:Shine(color or 0xFFFFFF) end
function EffCtrl:shake(px, py, time) self.f.battle.fx:Shake(math.max(px or 0, py or 3) * 2, time) end
function EffCtrl:startShake(px, py) self.f.battle.fx:StartShake(math.max(px or 0, py or 3)) self.f.shaking = true end
function EffCtrl:endShake() if self.f.shaking then self.f.battle.fx:EndShake() self.f.shaking = false end end
function EffCtrl:shadow(r, g, b) self.f.shadow = {r or 0, g or 0, b or 0} end
function EffCtrl:endShadow() self.f.shadow = nil end
function EffCtrl:dash() self.f.battle.fx:Effect(self.f.inAir and "dash_air" or "dash", self.f.x, self.f.y, self.f.dir) end
function EffCtrl:bisha(super, face) self.f.battle:Bisha(self.f, BVNRuntime.T(super), face) end
function EffCtrl:endBisha() self.f.battle:EndBisha(self.f) end
function EffCtrl:startWanKai(face) self.f.battle:Bisha(self.f, true, face, true) end
function EffCtrl:endWanKai() if self.f.state == S.WANKAI then self.f.battle:EndBisha(self.f) end end
function EffCtrl:walk() BVNSound.Play("bvn/step" .. (1 + math.floor(BVNRuntime.RAND() * 3)), 60) end
function EffCtrl:slowDown(sec) self.f.battle.fx:Slow(1.5, (sec or 1) * 1000) end
function EffCtrl:jump() self.f.battle.fx:Effect("jump", self.f.x, self.f.y, self.f.dir) end
function EffCtrl:jumpAir() self.f.battle.fx:Effect("jump_air", self.f.x, self.f.y, self.f.dir) end
function EffCtrl:touchFloor() self.f.battle.fx:Effect("touch_floor", self.f.x, self.f.y, self.f.dir) end
function EffCtrl:hitFloor() self.f.battle.fx:Effect("hit_floor", self.f.x, self.f.y, self.f.dir) end
function EffCtrl:startGlow(color) self.f.glow = color end
function EffCtrl:endGlow() self.f.glow = nil end
function EffCtrl:addFollowEffect() end
function EffCtrl:ghostStep() end
function EffCtrl:endGhostStep() end

-- $fighter_ctrler ---------------------------------------------------------------------

local FCtrl = {methods = {}}
BVNCtrl.F = FCtrl
local M = FCtrl.methods

-- Properties with setters/getters.
local PROPS = {speed = true, jumpPower = true, heavy = true, defenseType = true}
function FCtrl.Get(t, k)
	local f = rawget(t, "f")
	if PROPS[k] then return f[k] end
	if k == "hp" then return f.hp end
	if k == "energy" then return f.energy end
	if k == "hitModel" then return FCtrl.HitModel(f) end
	if k == "target" then return f:Target() end
	if k == "self" then return f end
	return M[k]
end
function FCtrl.Set(t, k, v)
	local f = rawget(t, "f")
	if PROPS[k] then f[k] = v return end
	if k == "hp" then f.hp, f.hpMax = v, v return end
	if k == "energy" then f.energy, f.energyMax = v, v return end
	rawset(t, k, v)
end

function FCtrl.HitModel(f)
	return {getHitVO = function(_, id) return f.hitModel[id] end, f = f}
end

function M:defineAction(id, obj) self.f.hitModel[id] = BVNFighter.NewHitVO(id, obj, self.f) end
function M:defineBishaFace(id, cls) self.f.faces[id] = type(cls) == "table" and cls.name or cls end
function M:defineHurtSound(...) self.f.voices.hurt = {...} end
function M:defineHurtFlySound(...) self.f.voices.hurtFly = {...} end
function M:defineDieSound(...) self.f.voices.die = {...} end
function M:initMc() self.f:InitMc() end
function M:doWanKai(frame)
	local f = self.f
	f.doingWankai = true
	f.mcReady = false
	local n = (frame and frame > 0) and (frame - 1) or (f.formIndex + 1)
	f:SetForm(n)
end
function M:setDirectToTarget() self.f:FaceTarget() end
function M:setCross(v) self.f.isCross = BVNRuntime.T(v) end
function M:moveOnce(x, y) self.f.x = self.f.x + (x or 0) * self.f.dir; self.f.y = self.f.y + (y or 0) end
function M:moveToTarget(x, y, setDirect)
	local f = self.f
	local t = f:Target()
	if not t then return end
	if x ~= nil then
		local nx = t.x + x * f.dir
		local b = f.battle.map
		if x > 0 and (nx < b.left or nx > b.right) then nx = t.x - x * f.dir end
		f.x = nx
	end
	if y ~= nil then f.y = t.y + y end
	if setDirect == nil or BVNRuntime.T(setDirect) then f:FaceTarget() end
end
function M:justHit(id, inclDef)
	local t = self.f:Target()
	if not t then return false end
	if t.hurtHit and t.hurtHit.id == id then return true end
	if BVNRuntime.T(inclDef) and t.defenseHit and t.defenseHit.id == id then return true end
	return false
end
function M:getTargetState() local t = self.f:Target() return t and t.state or 0 end
function M:targetInRange(xr, yr)
	local f = self.f
	local t = f:Target()
	if not t then return false end
	local dx = (t.x - f.x) * f.dir
	local dy = t.y - f.y
	local function arr(v) if type(v) == "table" and rawget(v, "_a") then return rawget(v, "_a") end return v end
	xr, yr = arr(xr), arr(yr)
	if xr and (dx < xr[1] or dx > xr[2]) then return false end
	if yr and (dy < yr[1] or dy > yr[2]) then return false end
	return true
end
function M:getTargetSP() return self.f:Target() end
function M:getTarget() return self.f:Target() end
function M:setTargetVelocity(x, y) local t = self.f:Target() if t then t:SetVelocity((x or 0) * self.f.dir, y or 0) end end
function M:setTargetDamping(x, y) local t = self.f:Target() if t then t:SetDamping(x or 0, y or 0) end end
function M:addHp(v) self.f.hp = math.min(self.f.hpMax, self.f.hp + (v or 0)) end
function M:addHpPercent(p) self:addHp(self.f.hpMax * (p or 0)) end
function M:loseHp(v) self.f:LoseHp(v or 0) end
function M:loseHpPercent(p) self.f:LoseHp(self.f.hpMax * (p or 0)) end
function M:getEnergy() return self.f.energy end
function M:getEnergyOverload() return self.f.overload end
function M:loseEnergy(v) self.f:UseEnergy(v or 0) end
function M:addEnergy(v) self.f.energy = math.min(self.f.energyMax, self.f.energy + (v or 0)) end
function M:loseQi(v) self.f:UseQi(math.min(self.f.qi, v or 0)) end
function M:getBuffCtrl()
	local f = self.f
	return {attackUp = function(_, rate, sec) f.attackRate = 1 + (rate or 0) f:DelayCall(function() f.attackRate = 1 end, (sec or 5) * 60) end,
		defenseUp = function(_, rate, sec) f.defenseRate = 1 + (rate or 0) f:DelayCall(function() f.defenseRate = 1 end, (sec or 5) * 60) end,
		speedUp = function() end}
end
