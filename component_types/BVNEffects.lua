-- Hit-stop, slow motion, screen shake, flashes and stand-in hit sparks.
-- The original effect clips (XG_kan2, ...) live in 5DPLAY's shared effect
-- library, which is not converted yet; these sparks approximate them.
-- Not attached to any actor.
local D = setmetatable({}, {__index = function(_, k) return BVNDraw[k] end})

-- EffectModel.as: hit / guard effects by hitType, and named effects.
local HIT = {
	[11] = {cls = "xg_catch_hit", snd = "snd_hit_cache", freeze = 400},
	[1] = {cls = "XG_kan2", snd = "snd_kan1", freeze = 50, rand = true},
	[6] = {cls = "XG_kanx2", snd = "snd_kan2", freeze = 400, rand = true, shine = {0xffffff, 0.2}, shake = 6},
	[2] = {cls = "XG_qdj", snd = "snd_hit2", freeze = 50, rand = true},
	[3] = {cls = "XG_qdjx", snd = "snd_hit_heavy", freeze = 400, rand = true, shine = {0xffffff, 0.2}, shake = 6},
	[4] = {cls = "XG_mfdj", snd = "snd_hit2", freeze = 50, rand = true},
	[5] = {cls = "XG_mfdjx", snd = "snd_mfdjx", freeze = 400, rand = true, shine = {0xffffff, 0.2}, shake = 6},
	[7] = {cls = "XG_fire", snd = "snd_hit_fire", freeze = 400, shine = {0xFFFF67, 0.2}, shake = 6},
	[8] = {cls = "XG_ice", snd = "snd_hit_ice", freeze = 400, shine = {0xA3E5F5, 0.2}, shake = 6},
	[9] = {cls = "XG_leidian", snd = "snd_hit_dian", freeze = 400, shine = {0x8288D2, 0.2}, shake = 6},
}
local GUARD = {
	[1] = {cls = "XG_fykan", snd = "snd_fykan", freeze = 50, follow = true},
	[6] = {cls = "XG_fykanx", snd = "snd_fykanx", freeze = 400, follow = true, shine = {0xffffff, 0.1}, shake = 6},
	[2] = {cls = "XG_fyq", snd = "snd_def", freeze = 50, follow = true},
	[3] = {cls = "XG_fyqx", snd = "snd_defx", freeze = 400, follow = true, shine = {0xffffff, 0.1}, shake = 6},
	[4] = {cls = "XG_mffy", snd = "snd_def", freeze = 50, follow = true},
	[5] = {cls = "XG_mffyx", snd = "snd_defx", freeze = 400, follow = true, shine = {0xffffff, 0.15}, shake = 6},
	[7] = {cls = "XG_fire_fy", snd = "snd_defx", freeze = 400, follow = true, shine = {0xFFFF67, 0.2}, shake = 6},
	[8] = {cls = "XG_ice_fy", snd = "snd_defx", freeze = 400, follow = true, shine = {0xA3E5F5, 0.2}, shake = 6},
	[9] = {cls = "XG_dian_fy", snd = "snd_defx", freeze = 400, follow = true, shine = {0x8288D2, 0.2}, shake = 6},
}
local NAMED = {
	bisha = {cls = "XG_bs", snd = "snd_bs"}, bisha_super = {cls = "XG_cbs", snd = "snd_cbs"},
	dash = {cls = "XG_rush", snd = "snd_dash_air"}, dash_air = {cls = "XG_rush_air", snd = "snd_dash_air"},
	jump = {cls = "XG_jump", snd = "snd_jump"}, jump_air = {cls = "XG_jump_air", snd = "snd_jump"},
	touch_floor = {cls = "XG_luodi", snd = "snd_luodi"}, hit_floor = {cls = "XG_hitfloor", snd = "snd_hitfloor"},
	hit_floor_low = {cls = "xg_hitfloor_low", snd = "snd_hitfloor_low"},
	hit_floor_heavy = {cls = "xg_hitfllor_heavy", snd = "snd_hitfloor_heavy", also = "hit_floor_yan"},
	hit_floor_yan = {cls = "xg_hitfloor_yan"},
	break_def = {cls = "XG_mfdjx", snd = "snd_mfdjx", freeze = 500, slow = {1.5, 1500}, shake = 6},
	fz_bleach = {cls = "XG_fz_bleach_mc", snd = "snd_dash"}, fz_naruto = {cls = "XG_fz_naruto_mc", snd = "snd_fz"},
	replaceSp = {cls = "XG_tishen", snd = "snd_fz"}, explodeSp = {cls = "XG_bsq", snd = "snd_baoqi1"},
	ghost_step = {cls = "XG_ghost_step", snd = "snd_ghost_step"}, hit_end = {cls = "xg_hitover"},
	buff_effect_power = {cls = "xg_buff_effect_power"}, buff_effect_defense = {cls = "xg_buff_effect_defense"},
	buff_effect_speed = {cls = "xg_buff_effect_speed"},
}

local Fx = {}
Fx.__index = Fx

BVNEffects = {
	New = function(battle)
		return setmetatable({battle = battle, freeze = 0, slowRate = 1, slowT = 0, shake = 0, shakeT = 0, sustained = 0,
			flash = nil, parts = {}, anims = {}, animTick = 0}, Fx)
	end,
}

function Fx:Update()
	self.animTick = self.animTick + 1
	if self.animTick >= math.ceil(2 * self.slowRate) then
		self.animTick = 0
		self:Animate()
	end
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
	if self.noFreeze then return end
	local n = math.floor(ms * 0.06)
	if n > self.freeze then self.freeze = n end
end

function Fx:Slow(rate, ms)
	if self.slowRate > rate and self.slowT > 0 then return end
	self.slowRate = rate
	self.slowT = math.floor(ms * 0.06)
end

-- slowDown(rate, 0): no time limit, until EndSlow (the KO fall).
function Fx:SlowOpen(rate)
	self.slowRate, self.slowT = rate, math.huge
end
function Fx:EndSlow() self.slowRate, self.slowT = 1, 0 end

function Fx:Shake(pow, sec)
	self.shake = math.max(self.shake, pow or 3)
	self.shakeT = math.max(self.shakeT, math.floor((sec and sec > 0 and sec or 0.5) * 60))
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

local function sound(name)
	local clip = name and BVNFxData and BVNFxData.sounds[name]
	if clip then BVNSound.Play(clip, 110) elseif name then BVNSound.Play(({snd_kan1 = "hit", snd_hit2 = "hit"})[name] or "heavy", 110) end
end

-- Plays an effect clip at world (x, y); frames advance on animate ticks.
function Fx:Play(cls, x, y, dir, rot)
	local data = BVNFxData and BVNFxData.effects[cls]
	if not data then return false end
	self.anims[#self.anims + 1] = {data = data, t = 1, x = x, y = y, dir = dir or 1, rot = rot or 0}
	return true
end

function Fx:Apply(e, x, y, dir, rot)
	if e.freeze then self:Freeze(e.freeze) end
	if e.shine then self:Shine(e.shine[1], e.shine[2]) end
	if e.shake then self:Shake(e.shake, 0.4) end
	if e.slow then self:Slow(e.slow[1], e.slow[2]) end
	if not self:Play(e.cls, x, y, dir, rot) then self:Burst(x, y, {255, 240, 200}, 8, 3) end
	sound(e.snd)
	if e.also then self:Named(e.also, x, y, dir) end
end

function Fx:HitEffect(h, rect, guarded, target)
	local cx, cy = rect[1] + rect[3] / 2, rect[2] + rect[4] / 2
	local t = h.hitType
	local owner = h.owner
	local dir = owner and owner.dir or 1
	if guarded then
		if target and target.defenseType == 1 then
			if t == 1 then t = 2 elseif t == 6 then t = 3 end
		end
		local e = GUARD[t] or GUARD[5]
		self:Apply(e, cx, cy, e.follow and dir or 1, 0)
		return
	end
	local e = HIT[t]
	if not e then return end
	self:Apply(e, cx, cy, dir, e.rand and math.floor(BVNRuntime.RAND() * 360) or 0)
	if (h.slowDown or 0) > 0 then self:Slow(1.5, h.slowDown * 1000) end
end

function Fx:SteelEffect(h, rect)
	local t = h.hitType
	local cls = (t == 1 or t == 6) and "XG_kan2" or ((t == 2 or t == 3) and "XG_qdj" or "XG_mfdj")
	if t == 0 then return end
	self:Apply({cls = cls, snd = "snd_hit11", freeze = 400, shine = {0xffffff, 0.2}}, rect[1] + rect[3] / 2, rect[2] + rect[4] / 2, h.owner and h.owner.dir or 1, 0)
end

function Fx:Effect(id, x, y, dir) self:Named(id, x, y, dir) end

function Fx:Named(id, x, y, dir)
	local e = NAMED[id]
	if e then self:Apply(e, x, y, dir, 0) end
end

function Fx:Animate()
	for i = #self.anims, 1, -1 do
		local a = self.anims[i]
		a.t = a.t + 1
		if a.t > #a.data.frames then table.remove(self.anims, i) end
	end
end

function Fx:Draw()
	for _, a in ipairs(self.anims) do
		local f = a.data.frames[a.t]
		if f and f.img then
			-- Rotate and mirror around the effect origin.
			-- A mirrored image is flipped in place: put the pivot at the origin's mirror.
			local px = a.dir < 0 and (1 + f.x / f.w) or (-f.x / f.w)
			Image.DrawEx(f.img, a.x / 100, a.y / 100, a.rot * a.dir, a.dir, 1, px, -f.y / f.h, 255, 255, 255, 255, 72,
				nil, a.data.add and "add" or nil)
		end
	end
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
