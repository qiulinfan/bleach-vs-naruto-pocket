-- Bullets (fire), attackers (addAttacker) and assists: sprites detached from a
-- fighter with their own timelines (Bullet.as, FighterAttacker.as, Assister.as).
-- Not attached to any actor.
local function sign(v) return v > 0 and 1 or (v < 0 and -1 or 0) end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

-- Bullet.as reads params with AS3 truthiness: 0 keeps the default.
local function truthy(v) return v ~= nil and v ~= 0 and v ~= false end

local function speedParam(p, default)
	if not truthy(p) then return {start = default, add = 0, max = 999, min = -999} end
	if type(p) == "number" then return {start = p, add = 0, max = 999, min = -999} end
	return {start = p.start or default, add = (p.add or 0) * 2, max = p.max or 999, min = p.min or -999, hit = p.hit}
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
	local px, py, p = owner:ChildPos(name)
	local ids = owner.char.attackers[name]
	if not px or not ids then return nil end
	return px, py, ids[1], p
end

-- The child's placement in its parent's frame, which the detached sprite keeps: a matrix
-- (x scale and rotation mirrored with the owner's facing, as the world draw mirrors), alpha
-- and colour transform. FighterAttacker's direct setter resets the x scale to 1 (resetX).
local function placement(p, resetX)
	if not p or not p[3] then return nil end
	local a, b, c, d = p[3], p[4], p[5], p[6]
	if resetX then
		local sx = math.sqrt(a * a + b * b)
		if sx > 0 then a, b = a / sx, b / sx end
	end
	return {m = {a, b, c, d, 0, 0}, alpha = p[7] and p[7] < 1 and p[7] or nil, ct = p[8]}
end

-- Draw options and matrix for a sprite with a placement.
local function placedDraw(sp, opt)
	local pl = sp.place
	if not pl then return opt, nil end
	if pl.alpha then opt.alpha = math.floor((opt.alpha or 255) * pl.alpha) end
	local ct = pl.ct
	if ct then
		opt.tint = {255 * ct[1], 255 * ct[2], 255 * ct[3]}
		local c = opt.color or {0, 0, 0}
		opt.color = {c[1] + ct[4], c[2] + ct[5], c[3] + ct[6]}
	end
	return opt, pl.m
end

-- The axis-aligned bounds of rect {x, y, w, h} under matrix m.
local function boundsUnder(m, r)
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, q in ipairs({{r[1], r[2]}, {r[1] + r[3], r[2]}, {r[1], r[2] + r[4]}, {r[1] + r[3], r[2] + r[4]}}) do
		local x, y = m[1] * q[1] + m[3] * q[2], m[2] * q[1] + m[4] * q[2]
		x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
	end
	return {x0, y0, x1 - x0, y1 - y0}
end

BVNBullet = {}

-- Bullet ---------------------------------------------------------------------------

local Bullet = {}
Bullet.__index = Bullet

function BVNBullet.Fire(battle, owner, name, params, hitModel)
	local px, py, sid, p = spawnOf(owner, name)
	if not px then return nil end
	local b = setmetatable({kind = "bullet", battle = battle, owner = owner, team = owner.team, name = name}, Bullet)
	b.char = owner.char
	b.clip = BVNClip.New(owner.char, sid, BVNClip.LayerFor(owner), b)
	if not b.clip then return nil end
	BVNClip.Enter(b.clip, 1)
	-- Bullet keeps the child's scale and rotation (only mirrored with the facing).
	b.place = placement(p, false)
	-- Its hit area is measured in the fighter's space: the placement under the form's scale.
	local m, fo = b.place and b.place.m or {1, 0, 0, 1}, owner.formOffset
	if fo then m = {m[1] * fo[3], m[2] * fo[4], m[3] * fo[3], m[4] * fo[4]} end
	if m[1] ~= 1 or m[2] ~= 0 or m[3] ~= 0 or m[4] ~= 1 then b.areaM = m end
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
	b.hitVx, b.hitVy = b.sx.hit and b.sx.hit * b.dir, b.sy.hit
	b.hold = (truthy(params.hold) and params.hold ~= -1) and params.hold * 60 or -1
	b.hits = truthy(params.hits) and params.hits or -1
	b.hpMax = truthy(params.hp) and params.hp or 100
	b.hp = b.hpMax
	b.isAttacking = true
	b.allowBeHit = true
	return b
end

-- Bullet.setHitVO: the hit area is fixed at spawn, from the "main" child or the whole
-- first frame, as placed (getBounds in the owner's space).
local function spawnArea(clip, m)
	local f = clip.data.frames[1]
	local r
	if f and f.main then
		r = f.main
	elseif f and f.img then
		local sz = Image.GetSize(f.img)
		r = {f.x, f.y, sz.x, sz.y}
	else
		local bd = clip.data.bounds
		if bd then r = {bd[1], bd[2], bd[3] - bd[1], bd[4] - bd[2]} end
	end
	if r and m then r = boundsUnder(m, r) end
	return r
end

function Bullet:Area()
	self.area = self.area or spawnArea(self.clip, self.areaM)
	return self.area and worldRect(self, self.area)
end

-- The body stays hittable after the hit; the bullet only stops hitting.
function Bullet:BodyArea() if self.dead then return nil end return self:Area() end

function Bullet:CurrentHits()
	if self.dead or self.hitOver or not self.hit then return {} end
	local a = self:Area()
	if not a then return {} end
	return {{self.hit, a}}
end

function Bullet:Render()
	-- After its hit the bullet only plays out its clip.
	if self.dead or self.stopped then return end
	local sp = 0.5 * (self.battle.speedK or 1)
	self.x = self.x + self.vx * sp
	self.y = self.y + self.vy * sp
	self.vx = self.vx + self.ax * sp
	self.vy = self.vy + self.ay * sp
	local mx, mn = self.sx.max, self.sx.min
	if self.dir > 0 then self.vx = clamp(self.vx, mn, mx) else self.vx = clamp(self.vx, -mx, -mn) end
	self.vy = clamp(self.vy, self.sy.min, self.sy.max)
	if self.hold > 0 and not self.timedOut then
		self.hold = self.hold - 1
		if self.hold <= 0 then
			-- A timed-out bullet keeps moving and hitting until its clip ends.
			if BVNClip.HasLabel(self.clip, "timeout") then BVNClip.Goto(self.clip, "timeout"); self.timedOut = true
			else self.dead = true return end
		end
	end
	local m = self.battle.map
	if self.y > m.playerBottom then
		self:OnHit(nil)
		self.battle.fx:Shake(0, 1, 200)
		return
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
	elseif c.frame >= #c.data.frames - 1 then
		-- Bullet.renderAnimate removes on the last frame but one.
		self.dead = true
	end
end

-- Bullet.hit: another bullet only changes the speed; a fighter costs one hit and gives
-- the owning fighter qi; the hit speed is halved against a wall.
function Bullet:OnHit(target)
	if target and target.kind == "bullet" then
		if self.hitVx then self.vx = self.hitVx end
		if self.hitVy then self.vy = self.hitVy end
		return
	end
	if self.hits ~= -1 then
		self.hits = self.hits - 1
		if self.hits <= 0 then self:DoHit() end
	end
	if target and self.owner.kind == "fighter" then self.owner:AddQi(self.hit and self.hit.power * 0.1 or 0) end
	if target then
		if self.hitVx == 0 and self.hitVy == 0 then return end
		if target.touchSide then
			local hx, hy = self.hitVx or self.vx, self.hitVy or self.vy
			self.hitVx = math.abs(hx) < 1 and 0 or hx * 0.5
			self.hitVy = math.abs(hy) < 1 and 0 or hy * 0.5
		end
		if self.hitVx then self.vx = self.hitVx end
		if self.hitVy then self.vy = self.hitVy end
	end
end

function Bullet:DoHit()
	if not self.stopped and BVNClip.HasLabel(self.clip, "hit") then BVNClip.Goto(self.clip, "hit") end
	self.stopped = true
	self.hitOver = true
end

function Bullet:BeHit(h, _, src)
	if src and src.kind == "bullet" then self.hp = self.hp - src.hpMax else self.hp = self.hp - (h.power or 0) end
	if self.hp <= 0 then self:DoHit() end
end

function Bullet:Draw(order)
	local opt, m = placedDraw(self, {order = order})
	BVNClip.Draw(self.clip, self.x, self.y, self.dir, opt, m)
end

-- Follow effect (FollowEffectView) ----------------------------------------------------
-- A child clip detached from the fighter that keeps its offset from the fighter and
-- plays on its own; it ends when the fighter's timeline jumps, or at its last frame
-- but one.

local Follow = {}
Follow.__index = Follow

function BVNBullet.Follow(battle, owner, name, under)
	local px, py, sid, p = spawnOf(owner, name)
	if not px then return nil end
	local v = setmetatable({kind = "follow", battle = battle, owner = owner, team = owner.team, name = name, under = under}, Follow)
	v.char = owner.char
	v.clip = BVNClip.New(owner.char, sid, BVNClip.LayerFor(owner), v)
	if not v.clip then return nil end
	BVNClip.Enter(v.clip, 1)
	v.place = placement(p, false)
	v.cx, v.cy = (px - owner.x) * owner.dir, py - owner.y
	v.dir = owner.dir
	v.x, v.y = px, py
	v.lastFrame = owner.clip.frame
	v.loopFrame = BVNClip.HasLabel(v.clip, "loop_start") and "loop_start" or 1
	v.drawUnder = under
	return v
end

function Follow:BodyArea() return nil end
function Follow:RawBody() return nil end
function Follow:CurrentHits() return {} end
function Follow:BeHit() end

function Follow:Render()
	local o = self.owner
	self.dir = o.dir
	self.x, self.y = o.x + self.cx * o.dir, o.y + self.cy
	local cur = o.clip.frame
	local d = cur - self.lastFrame
	if d == 0 or d == 1 then self.lastFrame = cur else self.dead = true end
end

function Follow:RenderAnimate()
	if self.dead then return end
	local c = self.clip
	BVNClip.Next(c)
	BVNClip.AdvanceKids(c)
	local l = BVNClip.LabelHere(c)
	if l == "loop" then BVNClip.Goto(c, self.loopFrame)
	elseif l == "remove" then self.dead = true
	elseif c.frame >= #c.data.frames - 1 then self.dead = true end
end

function Follow:Draw(order)
	local opt, m = placedDraw(self, {order = order, color = self.owner.color})
	BVNClip.Draw(self.clip, self.x, self.y, self.dir, opt, m)
end

-- Attacker -------------------------------------------------------------------------

local Attacker = {}
Attacker.__index = Attacker

local function axisParam(p)
	if p == nil then return {} end
	if type(p) == "number" then return {num = p} end
	return p
end

local function rangeOf(r) return r and (rawget(r, "_a") or r) end

function BVNBullet.Attacker(battle, owner, name, params, hitModel)
	local px, py, sid, p = spawnOf(owner, name)
	if not px then return nil end
	local a = setmetatable({kind = "attacker", battle = battle, owner = owner, team = owner.team, name = name}, Attacker)
	a.char = owner.char
	a.hitModel = hitModel or owner.hitModel
	a.ctrl = setmetatable({a = a}, ctrlMT(BVNBullet.AttackerCtrl))
	a.clip = BVNClip.New(owner.char, sid, BVNClip.LayerFor(owner), a)
	if not a.clip then return nil end
	a.clip.inst.S_attacker_ctrler = a.ctrl
	if a.clip.methods and a.clip.methods.setAttackerCtrler then BVNClip.Call(a.clip, "setAttackerCtrler", a.ctrl) end
	a.dir = owner.dir
	a.place = placement(p, true)
	a.vx, a.vy, a.dx, a.dy, a.g = 0, 0, 0, 0, 0
	a.applyG = params.applyG ~= false
	a.px, a.py = axisParam(params.x), axisParam(params.y)
	-- FighterAttacker: the start point is the child's own offset, plus a number param, or
	-- replaced by {offset}; x mirrors with the owner's facing.
	local cx, cy = (px - owner.x) * owner.dir, py - owner.y
	a.startX = a.px.num and (a.px.num + cx) or (a.px.offset or cx)
	a.startY = a.py.num and (a.py.num + cy) or (a.py.offset or cy)
	a.x, a.y = owner.x + a.startX * a.dir, owner.y + a.startY
	a.isAttacking = false
	a:Place(true)
	BVNClip.Enter(a.clip, 1)
	return a
end

-- init (moveToTarget) and the per-tick follow (followTarget): aim at the target within range.
function Attacker:Place(init)
	local o, t = self.owner, self.owner:Target()
	local px, py = self.px, self.py
	local mx = init and px.moveToTarget or px.followTarget
	local my = init and py.moveToTarget or py.followTarget
	if t and mx then
		local tx = t.x + self.startX * self.dir
		local r = rangeOf(px.range)
		if r then
			local d = (tx - o.x) * self.dir
			if d < r[1] then tx = o.x + r[1] * self.dir end
			if d > r[2] then tx = o.x + r[2] * self.dir end
		end
		self.x = tx
	end
	if t and my then
		local ty = t.y + self.startY
		local r = rangeOf(py.range)
		if r then
			local d = ty - o.y
			if d < r[1] then ty = t.y + r[1] end
			if d > r[2] then ty = t.y + r[2] end
		end
		self.y = ty
	end
	if init and (px.moveToTarget or py.moveToTarget) then self.isAttacking = true end
end

function Attacker:BodyArea() return nil end
function Attacker:RawBody() return nil end
function Attacker:Target() return self.owner:Target() end
function Attacker:ChildPos(name)
	local f = self.clip and self.clip.data.frames[self.clip.frame]
	local p = f and f.hits and f.hits["@" .. name]
	if p then return self.x + p[1] * self.dir, self.y + p[2], p end
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
	if self.px.followTarget or self.py.followTarget then self:Place(false) end
	local k = self.battle.speedK or 1
	local sp = 0.5 * k
	local mx, my = self.vx, self.vy
	if self.dx > 0 then self.vx = self.vx > 0 and math.max(0, self.vx - self.dx * k) or math.min(0, self.vx + self.dx * k) end
	if self.dy > 0 then self.vy = self.vy > 0 and math.max(0, self.vy - self.dy * k) or math.min(0, self.vy + self.dy * k) end
	self.x = self.x + mx * sp
	self.y = self.y + my * sp
	if self.applyG and self.vy >= 0 and self.y < self.battle.map.playerBottom then
		self.g = math.min(12, self.g + 1.2 * sp)
		self.y = self.y + self.g * sp
	end
	local m = self.battle.map
	if self.y >= m.playerBottom then
		if self.y > m.playerBottom then self.y = m.playerBottom end
		self.g = 4
		if self.touchFloor then
			local l = self.touchFloor
			self.touchFloor = nil
			BVNClip.Goto(self.clip, l)
			self.held = false
		end
	end
	if not self.crossMap then self.x = clamp(self.x, m.left, m.right) end
	if self.hitTarget then
		local f = self.clip.data.frames[self.clip.frame]
		local r = f and f.hits and (f.hits[self.hitTarget[1]] or f.hits["#" .. self.hitTarget[1]])
		local t = self.owner:Target()
		local body = t and t:RawBody()
		if r and #r == 4 and body and BVNBattle.Intersects(worldRect(self, r), body) then
			local l = self.hitTarget[2]
			self.hitTarget = nil
			BVNClip.Goto(self.clip, l)
			self.held = false
		end
	end
end

-- FighterAttacker.renderAnimate: the kernel moves the clip on itself every animation tick (the
-- clip's own stop() only halts Flash's playback); the attacker controller's stop / gotoAndStop
-- hold it (held).
function Attacker:RenderAnimate()
	if self.dead or self.held then return end
	local c = self.clip
	BVNClip.Next(c)
	BVNClip.AdvanceKids(c)
	if c.frame >= math.max(1, #c.data.frames - 1) then self.dead = true end
end

-- FighterAttacker.hit: the owning fighter gains qi, more for an assist's attacker.
local function fighterOf(a) return a.owner.fCtrl and a.owner or a.owner.owner end

function Attacker:OnHit(target, h)
	if target and h then fighterOf(self):AddQi(h.power * (self.owner.kind == "assist" and 0.15 or 0.13)) end
end

function Attacker:Draw(order)
	local opt, m = placedDraw(self, {order = order})
	BVNClip.Draw(self.clip, self.x, self.y, self.dir, opt, m)
end

local AC = {}
BVNBullet.AttackerCtrl = AC
function AC:move(x, y) self.a.vx, self.a.vy, self.a.dx, self.a.dy = (x or 0) * self.a.dir, y or 0, 0, 0 end
function AC:damping(x, y) self.a.dx, self.a.dy = x or 0, y or 0 end
function AC:stop() self.a.held = true end
function AC:gotoAndPlay(l) BVNClip.Goto(self.a.clip, l); self.a.held = false end
function AC:gotoAndStop(l) BVNClip.Goto(self.a.clip, l); self.a.held = true end
function AC:setTouchFloor(l) self.a.touchFloor = l end
function AC:setHitTarget(checker, l) self.a.hitTarget = {checker, l} end
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
	self.clip = BVNClip.New(self.char, self.char.forms[1].sprite, BVNClip.LayerFor(self), self)
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
	self.held = false
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

-- Assister.renderAnimate: as attackers, held only by its controller.
function Assist:RenderAnimate()
	if self.dead or self.held then return end
	local c = self.clip
	BVNClip.Next(c)
	BVNClip.AdvanceKids(c)
	if c.frame >= #c.data.frames - 1 then self:Finish() end
end

function Assist:Finish()
	self.battle.fx:Effect((self.char.comic_type or 0) == 1 and "fz_naruto" or "fz_bleach", self.x, self.y, self.dir)
	self.dead = true
end

-- Assister.hit
function Assist:OnHit(target, h)
	if target and h then self.owner:AddQi(h.power * 0.15) end
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
-- AssisterCtrler.moveToTarget: values go through Number() (true is 1).
function SC:moveToTarget(x, y, setDirect)
	local a = self.a
	local t = a.owner:Target()
	if not t then return end
	local function num(v) if v == true then return 1 elseif v == false then return 0 end return tonumber(v) or 0 end
	if x ~= nil then a.x = t.x + num(x) * a.dir end
	if y ~= nil then a.y = t.y + num(y) end
	if setDirect == nil or BVNRuntime.T(setDirect) then a.dir = a.x < t.x and 1 or -1 end
end
function SC:justHit(id, frame, inclDef)
	local ok = fighterOf(self.a).fCtrl:justHit(id, inclDef)
	if ok and frame then BVNClip.Goto(self.a.clip, frame); self.a.held = false end
	return ok
end
function SC:fire(name, params) self.a.battle:FireBullet(self.a, name, params or {}, self.a.hitModel) end
function SC:addAttacker(name, params) self.a.battle:AddAttacker(self.a, name, params or {}, self.a.hitModel) end
-- AssisterCtrler.checkHitOwner: the named child's rect touches the owner.
function SC:checkHitOwner(name)
	local a = self.a
	local f = a.clip and a.clip.data.frames[a.clip.frame]
	local r = f and f.hits and (f.hits[name] or f.hits["#" .. name])
	local body = a.owner:RawBody()
	if not r or #r ~= 4 or not body then return false end
	return BVNBattle.Intersects(worldRect(a, r), body)
end
