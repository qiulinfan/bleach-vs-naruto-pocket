-- Hit-stop, slow motion, screen shake, flashes and stand-in hit sparks.
-- The original effect clips (XG_kan2, ...) live in 5DPLAY's shared effect
-- library, which is not converted yet; these sparks approximate them.
-- Not attached to any actor.
local D = setmetatable({}, {__index = function(_, k) return BVNDraw[k] end})

-- hitType -> {freeze ms on hit, freeze ms on guard, heavy, color, sound}
local HIT = {
	[1] = {50, 50, false, {255, 255, 255}, "hit"},
	[2] = {50, 50, false, {255, 230, 160}, "hit"},
	[3] = {400, 400, true, {255, 220, 120}, "heavy"},
	[4] = {50, 50, false, {170, 210, 255}, "hit"},
	[5] = {400, 400, true, {150, 200, 255}, "heavy"},
	[6] = {400, 400, true, {255, 255, 255}, "heavy"},
	[7] = {400, 400, true, {255, 150, 40}, "fire"},
	[8] = {400, 400, true, {170, 230, 255}, "ice"},
	[9] = {400, 400, true, {170, 170, 255}, "thunder"},
	[11] = {400, 400, false, {255, 255, 255}, "heavy"},
}

local Fx = {}
Fx.__index = Fx

BVNEffects = {
	New = function(battle)
		return setmetatable({battle = battle, freeze = 0, slowRate = 1, slowT = 0, shake = 0, shakeT = 0, sustained = 0,
			flash = nil, parts = {}}, Fx)
	end,
}

function Fx:Update()
	if self.freeze > 0 then self.freeze = self.freeze - 1 end
	if self.slowT > 0 then
		self.slowT = self.slowT - 1
		if self.slowT <= 0 then self.slowRate = 1 end
	end
	if self.shakeT > 0 then self.shakeT = self.shakeT - 1 else self.shake = 0 end
	if self.flash then
		self.flash.a = self.flash.a - 12
		if self.flash.a <= 0 then self.flash = nil end
	end
	for i = #self.parts, 1, -1 do
		local p = self.parts[i]
		p.life = p.life - 1
		if p.vx then p.x, p.y = p.x + p.vx, p.y + p.vy; p.vy = p.vy + (p.g or 0.15) end
		if p.life <= 0 then table.remove(self.parts, i) end
	end
end

function Fx:Freeze(ms)
	local n = math.floor(ms * 0.06)
	if n > self.freeze then self.freeze = n end
end

function Fx:Slow(rate, ms)
	if self.slowRate > rate and self.slowT > 0 then return end
	self.slowRate = rate
	self.slowT = math.floor(ms * 0.06)
end

function Fx:Shake(pow, sec)
	self.shake = math.max(self.shake, pow or 3)
	self.shakeT = math.max(self.shakeT, math.floor((sec and sec > 0 and sec or 0.25) * 60))
end
function Fx:StartShake(pow) self.sustained = pow or 3 end
function Fx:EndShake() self.sustained = 0 end

function Fx:ShakeOffset()
	local p = math.max(self.shake, self.sustained)
	if p <= 0 then return 0, 0 end
	local t = self.battle.tick
	return math.sin(t * 2.3) * p * 0.4, math.cos(t * 1.9) * p
end

function Fx:Shine(color, alpha)
	local r, g, b = (color >> 16) & 255, (color >> 8) & 255, color & 255
	self.flash = {c = {r, g, b}, a = (alpha or (color == 0xFFFFFF and 0.3 or 0.2)) * 255}
end

function Fx:Burst(x, y, c, n, speed, size)
	for _ = 1, n do
		local ang = BVNRuntime.RAND() * math.pi * 2
		local v = speed * (0.3 + BVNRuntime.RAND())
		self.parts[#self.parts + 1] = {x = x, y = y, vx = math.cos(ang) * v, vy = math.sin(ang) * v, life = 10 + BVNRuntime.RAND() * 8,
			max = 18, c = c, size = size or (2 + BVNRuntime.RAND() * 3)}
	end
	self.parts[#self.parts + 1] = {ring = true, x = x, y = y, life = 8, max = 8, c = c, size = (size or 3) * 5}
end

function Fx:HitEffect(h, rect, guarded, target)
	local cx, cy = rect[1] + rect[3] / 2, rect[2] + rect[4] / 2
	local def = HIT[h.hitType]
	if not def then
		if guarded then def = HIT[5] else return end
	end
	if guarded then
		self:Freeze(def[2])
		self:Burst(cx, cy, {150, 210, 255}, 6, 2.5, 2)
		BVNSound.Play("block", 100)
		if def[3] then self:Shake(6, 0.4) end
		return
	end
	self:Freeze(def[1])
	self:Burst(cx, cy, def[4], def[3] and 14 or 8, def[3] and 4 or 3)
	BVNSound.Play(def[5], 110)
	if def[3] then
		self:Shine(0xFFFFFF, 0.2)
		self:Shake(6, 0.4)
	end
	if (h.slowDown or 0) > 0 then self:Slow(1.5, h.slowDown * 1000) end
end

function Fx:SteelEffect(h, rect)
	self:Freeze(400)
	self:Burst(rect[1] + rect[3] / 2, rect[2] + rect[4] / 2, {255, 240, 150}, 8, 3)
	self:Shine(0xFFFFFF, 0.15)
	BVNSound.Play("block", 110)
end

function Fx:Effect(id, x, y, dir)
	if id == "jump" or id == "touch_floor" or id == "jump_air" then
		for _ = 1, 5 do
			self.parts[#self.parts + 1] = {x = x + (BVNRuntime.RAND() - 0.5) * 20, y = y - 2, vx = (BVNRuntime.RAND() - 0.5) * 2, vy = -BVNRuntime.RAND() * 0.8,
				g = 0, life = 14, max = 14, c = {220, 210, 190}, size = 5 + BVNRuntime.RAND() * 4, puff = true}
		end
	elseif id == "dash" or id == "dash_air" then
		for _ = 1, 6 do
			self.parts[#self.parts + 1] = {x = x - dir * 10, y = y - 4 - BVNRuntime.RAND() * 30, vx = -dir * (1 + BVNRuntime.RAND() * 2), vy = 0,
				g = 0, life = 12, max = 12, c = {230, 230, 255}, size = 3, puff = true}
		end
		BVNSound.Play("whoosh", 80)
	elseif id == "hit_floor" or id == "hit_floor_heavy" or id == "hit_floor_low" then
		for _ = 1, id == "hit_floor_heavy" and 10 or 5 do
			self.parts[#self.parts + 1] = {x = x + (BVNRuntime.RAND() - 0.5) * 40, y = y - 2, vx = (BVNRuntime.RAND() - 0.5) * 3, vy = -BVNRuntime.RAND() * 1.5,
				g = 0.05, life = 18, max = 18, c = {200, 190, 170}, size = 6 + BVNRuntime.RAND() * 6, puff = true}
		end
		BVNSound.Play("land", 100)
	elseif id == "fz_bleach" or id == "fz_naruto" then
		for _ = 1, 10 do
			self.parts[#self.parts + 1] = {x = x + (BVNRuntime.RAND() - 0.5) * 40, y = y - BVNRuntime.RAND() * 70, vx = (BVNRuntime.RAND() - 0.5) * 2,
				vy = -BVNRuntime.RAND(), g = 0, life = 20, max = 20, c = {240, 240, 240}, size = 10 + BVNRuntime.RAND() * 8, puff = true}
		end
		BVNSound.Play("whoosh", 100)
	end
end

function Fx:Named(id, x, y, dir)
	if id == "bisha" or id == "bisha_super" then
		self:Shine(0xFFFFFF, 0.35)
		self:Burst(x, y, {255, 240, 200}, 16, 4, 3)
		BVNSound.Play("ult", 110)
	elseif id == "break_def" then
		self:Freeze(500)
		self:Slow(1.5, 1500)
		self:Shake(6, 0.4)
		self:Burst(x, y, {255, 120, 80}, 16, 4)
		BVNSound.Play("heavy", 128)
	elseif id == "explodeSp" or id == "replaceSp" then
		self:Shine(0xFFFFFF, 0.3)
		self:Burst(x, y, {255, 255, 200}, 20, 5, 4)
		BVNSound.Play("beam", 110)
	end
end

function Fx:Draw()
	for _, p in ipairs(self.parts) do
		local a = 255 * p.life / p.max
		if p.ring then
			local s = p.size * (1 + (p.max - p.life) * 0.35)
			D.Square(p.x, p.y, s, 45, p.c, a * 0.5, 70)
		elseif p.puff then
			D.Square(p.x, p.y, p.size * (1.4 - p.life / p.max * 0.4), 0, p.c, a * 0.6, 70)
		else
			D.Square(p.x, p.y, p.size, 45, p.c, a, 71)
		end
	end
	if self.flash then D.UI(0, 0, 1280, 720, self.flash.c, self.flash.a, 40) end
end
