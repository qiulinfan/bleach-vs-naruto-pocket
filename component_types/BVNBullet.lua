-- Bullets (fire), attackers (addAttacker) and assists: sprites detached from a
-- fighter with their own timelines (Bullet.as, FighterAttacker.as, Assister.as).
-- Not attached to any actor.
local function sign(v) return v > 0 and 1 or (v < 0 and -1 or 0) end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local function speedParam(p, default)
	if p == nil then return {start = default, add = 0, max = 999, min = -999} end
	if type(p) == "number" then return {start = p, add = 0, max = 999, min = -999} end
	return {start = p.start or default, add = p.add or 0, max = p.max or 999, min = p.min or -999, hit = p.hit}
end

local function ctrlMT(methods)
	return {__index = function(t, k)
		local a = rawget(t, "a")
		local fighter = a.owner.fCtrl and a.owner or a.owner.owner
		if k == "effect" then
			-- Bound to the sprite itself: a bisha pause keeps that sprite's timeline running.
			local e = rawget(a, "effCtrl")
			if not e then
				e = setmetatable({f = a}, {__index = BVNCtrl.Eff})
				rawset(a, "effCtrl", e)
			end
			return e
		end
		if k == "owner_fighter_ctrler" then return fighter.fCtrl end
		if k == "owner_mc_ctrler" then return fighter.mcCtrl end
		if k == "camera" then return nil end
		if k == "hitModel" then
			local model = rawget(a, "hitModel") or fighter.hitModel
			return {getHitVO = function(_, id) return model[id] end}
		end
		local m = methods[k]
		if m ~= nil then return m end
		return function() end
	end}
end

local function worldRect(sp, r)
	local x = r[1] * sp.dir + sp.x - (sp.dir < 0 and r[3] or 0)
	return {x, r[2] + sp.y, r[3], r[4]}
end

-- A child's world position and the clip to detach: the owner's current frame
-- must place a child named `name` (the converter keeps its spawn point).
local function spawnOf(owner, name)
	local px, py = owner:ChildPos(name)
	local ids = owner.char.attackers[name]
	if not px or not ids then return nil end
	return px, py, ids[1]
end

BVNBullet = {}

-- Bullet ---------------------------------------------------------------------------

local Bullet = {}
Bullet.__index = Bullet

function BVNBullet.Fire(battle, owner, name, params, hitModel)
	local px, py, sid = spawnOf(owner, name)
	if not px then return nil end
	local b = setmetatable({kind = "bullet", battle = battle, owner = owner, team = owner.team, name = name}, Bullet)
	b.char = owner.char
	b.clip = BVNClip.New(owner.char, sid, nil, b)
	if not b.clip then return nil end
	BVNClip.Enter(b.clip, 1)
	local model = hitModel or owner.hitModel
	local base = model[name] or model[(name:gsub("atm", ""))]
	if base then
		b.hit = {}
		for k, v in pairs(base) do b.hit[k] = v end
		b.hit.owner = b
	end
	b.dir = owner.dir
	b.x, b.y = px, py
	b.sx = speedParam(params.x, 5)
	b.sy = speedParam(params.y, 0)
	b.vx, b.vy = b.sx.start * b.dir, b.sy.start
	b.ax, b.ay = b.sx.add * b.dir, b.sy.add
	b.hold = (params.hold and params.hold ~= -1) and params.hold * 60 or -1
	b.hits = params.hits or -1
	b.hpMax = params.hp or 100
	b.hp = b.hpMax
	b.isAttacking = true
	b.allowBeHit = true
	return b
end

function Bullet:Area()
	local f = self.clip.data.frames[self.clip.frame]
	if not f then return nil end
	local r = f.main or (f.hits and next(f.hits) and select(2, next(f.hits)))
	if not r or #r ~= 4 then
		local bd = self.clip.data.bounds
		if not bd then return nil end
		r = {bd[1], bd[2], bd[3] - bd[1], bd[4] - bd[2]}
	end
	return worldRect(self, r)
end

function Bullet:BodyArea() if self.dead or self.hitOver then return nil end return self:Area() end

function Bullet:CurrentHits()
	if self.dead or self.hitOver or not self.hit then return {} end
	local a = self:Area()
	if not a then return {} end
	return {{self.hit, a}}
end

function Bullet:Render()
	if self.dead then return end
	if not self.stopped then
		self.x = self.x + self.vx * 0.5
		self.y = self.y + self.vy * 0.5
		self.vx = self.vx + self.ax
		self.vy = self.vy + self.ay
		local mx, mn = self.sx.max, self.sx.min
		if self.dir > 0 then self.vx = clamp(self.vx, mn, mx) else self.vx = clamp(self.vx, -mx, -mn) end
		self.vy = clamp(self.vy, math.min(self.sy.min, self.sy.max), math.max(self.sy.min, self.sy.max))
	end
	if self.hold > 0 then
		self.hold = self.hold - 1
		if self.hold <= 0 then
			if BVNClip.HasLabel(self.clip, "timeout") then BVNClip.Goto(self.clip, "timeout"); self.stopped = true; self.hitOver = true
			else self.dead = true end
		end
	end
	local m = self.battle.map
	if not self.hitOver and self.y > m.playerBottom then
		self:OnHit(nil)
		self.battle.fx:Shake(1, 0.2)
	end
	if self.x > m.right + 20 or self.x < m.left - 20 or self.y > m.bottom + 20 then self.dead = true end
end

function Bullet:RenderAnimate()
	if self.dead then return end
	local c = self.clip
	BVNClip.Next(c)
	BVNClip.AdvanceKids(c)
	local here = BVNClip.LabelHere(c)
	if here == "loop" then
		BVNClip.Goto(c, BVNClip.HasLabel(c, "loop_start") and "loop_start" or 1)
	elseif here == "remove" then
		self.dead = true
	elseif here == "hit_over" then
		self.hitOver = true
	elseif c.frame >= #c.data.frames then
		self.dead = true
	end
end

function Bullet:OnHit(target)
	if self.hits ~= -1 then
		self.hits = self.hits - 1
		if self.hits <= 0 then self:DoHit() end
	end
	if target and self.owner.AddQi then self.owner:AddQi(self.hit and self.hit.power * 0.1 or 0) end
end

function Bullet:DoHit()
	if BVNClip.HasLabel(self.clip, "hit") then
		BVNClip.Goto(self.clip, "hit")
		self.stopped = true
		self.hitOver = true
	else
		self.dead = true
	end
end

function Bullet:BeHit(h, _, src)
	if src and src.kind == "bullet" then self.hp = self.hp - src.hpMax else self.hp = self.hp - (h.power or 0) end
	if self.hp <= 0 then self:DoHit() end
end

function Bullet:Draw(order)
	BVNClip.Draw(self.clip, self.x, self.y, self.dir, {order = order})
end

-- Attacker -------------------------------------------------------------------------

local Attacker = {}
Attacker.__index = Attacker

local function axisParam(p)
	if p == nil then return {offset = 0} end
	if type(p) == "number" then return {offset = p, plain = true} end
	return p
end

function BVNBullet.Attacker(battle, owner, name, params, hitModel)
	local px, py, sid = spawnOf(owner, name)
	if not px then return nil end
	local a = setmetatable({kind = "attacker", battle = battle, owner = owner, team = owner.team, name = name}, Attacker)
	a.char = owner.char
	a.hitModel = hitModel or owner.hitModel
	a.ctrl = setmetatable({a = a}, ctrlMT(BVNBullet.AttackerCtrl))
	a.clip = BVNClip.New(owner.char, sid, nil, a)
	if not a.clip then return nil end
	a.clip.inst.S_attacker_ctrler = a.ctrl
	if a.clip.methods and a.clip.methods.setAttackerCtrler then BVNClip.Call(a.clip, "setAttackerCtrler", a.ctrl) end
	a.dir = owner.dir
	a.x, a.y = px, py
	a.vx, a.vy, a.dx, a.dy, a.g = 0, 0, 0, 0, 0
	a.applyG = params.applyG ~= false
	a.px, a.py = axisParam(params.x), axisParam(params.y)
	a.isAttacking = false
	a:Place()
	BVNClip.Enter(a.clip, 1)
	return a
end

function Attacker:Place()
	local t = self.owner:Target()
	local px, py = self.px, self.py
	if px.plain then self.x = self.owner.x + px.offset * self.dir end
	if px.moveToTarget or px.followTarget then
		if t then
			local nx = t.x + (px.offset or 0) * self.dir
			if px.range then
				local r = px.range._a or px.range
				local d = (nx - self.owner.x) * self.dir
				d = clamp(d, r[1], r[2])
				nx = self.owner.x + d * self.dir
			end
			self.x = nx
		end
		self.isAttacking = true
	end
	if py.moveToTarget or py.followTarget then
		if t then
			local ny = t.y + (py.offset or 0)
			if py.range then
				local r = py.range._a or py.range
				ny = t.y + clamp(ny - t.y, r[1], r[2])
			end
			self.y = ny
		end
		self.isAttacking = true
	end
end

function Attacker:BodyArea() return nil end
function Attacker:RawBody() return nil end
function Attacker:Target() return self.owner:Target() end
function Attacker:ChildPos(name)
	local f = self.clip and self.clip.data.frames[self.clip.frame]
	local p = f and f.hits and f.hits["@" .. name]
	if p then return self.x + p[1] * self.dir, self.y + p[2] end
	return nil
end
function Attacker:AddQi(v) local o = self.owner if o.AddQi then o:AddQi(v) end end

function Attacker:CurrentHits()
	if self.dead then return {} end
	local f = self.clip.data.frames[self.clip.frame]
	local out = {}
	if f and f.hits then
		for nm, r in pairs(f.hits) do
			if #r == 4 then
				local h = self.hitModel[nm] or self.hitModel[(nm:gsub("atm", ""))]
				if h then out[#out + 1] = {h, worldRect(self, r)} end
			end
		end
	end
	return out
end

function Attacker:Render()
	if self.dead then return end
	if self.px.followTarget or self.py.followTarget then self:Place() end
	local mx, my = self.vx, self.vy
	if self.dx > 0 then self.vx = self.vx > 0 and math.max(0, self.vx - self.dx) or math.min(0, self.vx + self.dx) end
	if self.dy > 0 then self.vy = self.vy > 0 and math.max(0, self.vy - self.dy) or math.min(0, self.vy + self.dy) end
	self.x = self.x + mx * 0.5
	self.y = self.y + my * 0.5
	if self.applyG and self.vy >= 0 and self.y < self.battle.map.playerBottom then
		self.g = math.min(12, self.g + 0.6)
		self.y = self.y + self.g * 0.5
	end
	local m = self.battle.map
	if self.y >= m.playerBottom then
		if self.y > m.playerBottom then self.y = m.playerBottom end
		if self.touchFloor then
			local l = self.touchFloor
			self.touchFloor = nil
			BVNClip.Goto(self.clip, l)
			self.clip.playing = true
		end
	end
	if not self.crossMap then self.x = clamp(self.x, m.left, m.right) end
	if self.hitTarget then
		local f = self.clip.data.frames[self.clip.frame]
		local r = f and f.hits and f.hits[self.hitTarget[1]]
		local t = self.owner:Target()
		local body = t and t:RawBody()
		if r and #r == 4 and body and BVNBattle.Intersects(worldRect(self, r), body) then
			local l = self.hitTarget[2]
			self.hitTarget = nil
			BVNClip.Goto(self.clip, l)
			self.clip.playing = true
		end
	end
end

function Attacker:RenderAnimate()
	if self.dead then return end
	local c = self.clip
	if c.playing then BVNClip.Next(c) end
	BVNClip.AdvanceKids(c)
	if c.frame >= #c.data.frames and c.playing ~= false then self.dead = true end
end

function Attacker:OnHit(target)
	if target then self.owner:AddQi(self.hit and self.hit.power * 0.13 or 0) end
end

function Attacker:Draw(order)
	BVNClip.Draw(self.clip, self.x, self.y, self.dir, {order = order})
end

local AC = {}
BVNBullet.AttackerCtrl = AC
function AC:move(x, y) self.a.vx, self.a.vy, self.a.dx, self.a.dy = (x or 0) * self.a.dir, y or 0, 0, 0 end
function AC:damping(x, y) self.a.dx, self.a.dy = x or 0, y or 0 end
function AC:stop() self.a.clip.playing = false end
function AC:gotoAndPlay(l) BVNClip.Goto(self.a.clip, l); self.a.clip.playing = true end
function AC:gotoAndStop(l) BVNClip.Goto(self.a.clip, l); self.a.clip.playing = false end
function AC:setTouchFloor(l) self.a.touchFloor = l end
function AC:setHitTarget(checker, l) self.a.hitTarget = {checker, l} end
local function fighterOf(a) return a.owner.fCtrl and a.owner or a.owner.owner end
function AC:justHit(id, d) return fighterOf(self.a).fCtrl:justHit(id, d) end
function AC:getOwner() return fighterOf(self.a) end
function AC:getTarget() return fighterOf(self.a):Target() end
function AC:getSelf() return self.a end
function AC:moveToTarget(ox, oy)
	local a = self.a
	local t = a.owner:Target()
	if not t then return end
	if ox then a.x = t.x + ox * a.dir end
	if oy then a.y = t.y + oy end
end
function AC:stopFollowTarget() self.a.px.followTarget, self.a.py.followTarget = nil, nil end
function AC:setCrossMap(v) self.a.crossMap = BVNRuntime.T(v) end
function AC:removeSelf() self.a.dead = true end
function AC:endAct() self.a.isAttacking = false end
function AC:fire(name, params) self.a.battle:FireBullet(self.a.owner, name, params or {}) end
function AC:setApplyG(v) self.a.applyG = BVNRuntime.T(v) end

-- Assist ----------------------------------------------------------------------------

local Assist = setmetatable({}, {__index = Attacker})
Assist.__index = Assist

function BVNBullet.Assist(battle, owner, char)
	local a = setmetatable({kind = "assist", battle = battle, owner = owner, team = owner.team, char = char}, Assist)
	a.hitModel = {}
	a.ctrl = setmetatable({a = a}, ctrlMT(BVNBullet.AssistCtrl))
	return a
end

function Assist:Go()
	local owner = self.owner
	self.clip = BVNClip.New(self.char, self.char.forms[1].sprite, nil, self)
	local inst = self.clip.inst
	inst.S_assisterCtrler = self.ctrl
	if self.clip.methods and self.clip.methods.setAssistCtrler then BVNClip.Call(self.clip, "setAssistCtrler", self.ctrl) end
	self.dir = owner.dir
	self.x, self.y = owner.x - 30 * self.dir, owner.y
	self.vx, self.vy, self.dx, self.dy, self.g = 0, 0, 0, 0, 0
	self.applyG = true
	self.px, self.py = {offset = 0}, {offset = 0}
	self.dead = false
	self.isAttacking = true
	BVNClip.Enter(self.clip, 1)
	BVNClip.Goto(self.clip, 2)
	self.clip.playing = true
	self.battle.fx:Effect((self.char.comic_type or 0) == 1 and "fz_naruto" or "fz_bleach", self.x, self.y, self.dir)
end

function Assist:CurrentHits()
	if self.dead then return {} end
	local f = self.clip.data.frames[self.clip.frame]
	local out = {}
	if f and f.hits then
		for nm, r in pairs(f.hits) do
			local h = #r == 4 and self.hitModel[nm]
			if h then out[#out + 1] = {h, worldRect(self, r)} end
		end
	end
	return out
end

function Assist:RenderAnimate()
	if self.dead then return end
	local c = self.clip
	if c.playing then BVNClip.Next(c) end
	BVNClip.AdvanceKids(c)
	if c.frame >= #c.data.frames - 1 then self:Finish() end
end

function Assist:Finish()
	self.battle.fx:Effect((self.char.comic_type or 0) == 1 and "fz_naruto" or "fz_bleach", self.x, self.y, self.dir)
	self.dead = true
end

function Assist:OnHit(target)
	if target then self.owner:AddQi(self.hit and self.hit.power * 0.15 or 0) end
end

local SC = setmetatable({}, {__index = AC})
BVNBullet.AssistCtrl = SC
function SC:defineAction(id, obj) self.a.hitModel[id] = BVNFighter.NewHitVO(id, obj, self.a) end
function SC:finish() self.a:Finish() end
function SC:getOwner() return self.a.owner end
function SC:setDirectToTarget()
	local t = self.a.owner:Target()
	if t then self.a.dir = t.x >= self.a.x and 1 or -1 end
end
function SC:moveToTarget(x, y, setDirect)
	AC.moveToTarget(self, x, y)
	if setDirect == nil or BVNRuntime.T(setDirect) then self:setDirectToTarget() end
end
function SC:justHit(id, frame, inclDef)
	local ok = fighterOf(self.a).fCtrl:justHit(id, inclDef)
	if ok and frame then BVNClip.Goto(self.a.clip, frame); self.a.clip.playing = true end
	return ok
end
function SC:fire(name, params) self.a.battle:FireBullet(self.a, name, params or {}, self.a.hitModel) end
function SC:addAttacker(name, params) self.a.battle:AddAttacker(self.a, name, params or {}, self.a.hitModel) end
function SC:checkHitOwner() return false end
