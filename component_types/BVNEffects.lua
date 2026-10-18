-- Port of the original EffectCtrl and its handlers: effect clips from the shared
-- effect library (EffectModel), hit-stop (freeze), slow motion, background blur,
-- screen flashes (shine), screen shake, afterimages (shadow), the black backdrop
-- of ultimates / ghost steps / substitution / energy bursts, and the fire / ice /
-- shock / buff / steel colour effects. Not attached to any actor.
--
-- Clock: Render runs every logic tick, also while the battle is paused (frozen);
-- effect animation runs on its own animate gap, which follows the slow rate.
local D = setmetatable({}, {__index = function(_, k) return BVNDraw[k] end})

local KAN, DA, DA_HEAVY, MAGIC_HEAVY, KAN_HEAVY = 1, 2, 3, 5, 6

-- EffectModel.as.
local E = {
	bisha = {cls = "XG_bs", snd = "snd_bs"}, bisha_super = {cls = "XG_cbs", snd = "snd_cbs"},
	dash = {cls = "XG_rush", snd = "snd_dash_air"}, dash_air = {cls = "XG_rush_air", snd = "snd_dash_air"},
	jump = {cls = "XG_jump", snd = "snd_jump"}, jump_air = {cls = "XG_jump_air", snd = "snd_jump"},
	touch_floor = {cls = "XG_luodi", snd = "snd_luodi"},
	hit_floor = {cls = "XG_hitfloor", snd = "snd_hitfloor"}, hit_floor_low = {cls = "xg_hitfloor_low", snd = "snd_hitfloor_low"},
	hit_floor_heavy = {cls = "xg_hitfllor_heavy", snd = "snd_hitfloor_heavy"}, hit_floor_yan = {cls = "xg_hitfloor_yan"},
	hit_end = {cls = "xg_hitover"},
	break_def = {cls = "XG_mfdjx", snd = "snd_mfdjx", slow = {1.5, 1500}, freeze = 500, shake = {6, 0, 400}},
	fz_bleach = {cls = "XG_fz_bleach_mc", snd = "snd_dash"}, fz_naruto = {cls = "XG_fz_naruto_mc", snd = "snd_fz"},
	replaceSp = {cls = "XG_tishen", snd = "snd_fz"}, replaceSp2 = {cls = "XG_tishen2"},
	explodeSp = {cls = "XG_bsq", snd = "snd_baoqi1"}, explodeSp2 = {cls = "XG_baoqi", snd = "snd_baoqi"},
	ghost_step = {cls = "XG_ghost_step", snd = "snd_ghost_step"}, kobg = {cls = "kobg_effect_mc", screen = true},
	level_up = {cls = "xg_mc_levelup", snd = "snd_level_up"}, level_up_new_act = {cls = "xg_mc_levelup_newaction", snd = "snd_level_up"},
	team_change = {cls = "xg_mc_change", snd = "snd_change1"},
	fire_ing = {cls = "xg_fire_ing", special = {-255, -255, -255}},
	ice_ing = {cls = "xg_ice_ing", special = {0, 0, 255}},
	shock_ing = {cls = "xg_dian_ing", special = {50, -75, 255}},
	buff_effect_speed = {cls = "xg_buff_effect_speed"}, buff_effect_power = {cls = "xg_buff_effect_power"},
	buff_effect_defense = {cls = "xg_buff_effect_defense"},
	buff_speed = {cls = "xg_buff_speed", buff = true}, buff_power = {cls = "xg_buff_power", buff = true},
	buff_defense = {cls = "xg_buff_defense", buff = true},
	steel_hit_kan = {cls = "XG_kan2", snd = "snd_hit11", freeze = 400, shine = {0xffffff, 0.2}, rand = true, steel = true},
	steel_hit_qdj = {cls = "XG_qdj", snd = "snd_hit11", freeze = 400, shine = {0xffffff, 0.2}, rand = true, steel = true},
	steel_hit_mfdj = {cls = "XG_mfdj", snd = "snd_hit11", freeze = 400, shine = {0xffffff, 0.2}, rand = true, steel = true},
}
-- Hit effects by hit type; a {pow, time} shake becomes shake(0, pow, time).
local HIT = {
	[11] = {cls = "xg_catch_hit", snd = "snd_hit_cache", freeze = 400},
	[KAN] = {cls = "XG_kan2", snd = "snd_kan1", freeze = 50, rand = true},
	[KAN_HEAVY] = {cls = "XG_kanx2", snd = "snd_kan2", freeze = 400, shine = {0xffffff, 0.2}, rand = true, shake = {0, 6, 400}},
	[DA] = {cls = "XG_qdj", snd = "snd_hit2", freeze = 50, rand = true},
	[DA_HEAVY] = {cls = "XG_qdjx", snd = "snd_hit_heavy", freeze = 400, rand = true, shine = {0xffffff, 0.2}, shake = {0, 6, 400}},
	[4] = {cls = "XG_mfdj", snd = "snd_hit2", freeze = 50, rand = true},
	[MAGIC_HEAVY] = {cls = "XG_mfdjx", snd = "snd_mfdjx", freeze = 400, rand = true, shine = {0xffffff, 0.2}, shake = {0, 6, 400}},
	[7] = {cls = "XG_fire", snd = "snd_hit_fire", sp = "fire_ing", freeze = 400, shine = {0xFFFF67, 0.2}, shake = {0, 6, 400}},
	[8] = {cls = "XG_ice", snd = "snd_hit_ice", sp = "ice_ing", freeze = 400, shine = {0xA3E5F5, 0.2}, shake = {0, 6, 400}},
	[9] = {cls = "XG_leidian", snd = "snd_hit_dian", sp = "shock_ing", freeze = 400, shine = {0x8288D2, 0.2}, shake = {0, 6, 400}},
}
local GUARD = {
	[KAN] = {cls = "XG_fykan", snd = "snd_fykan", freeze = 50, follow = true},
	[KAN_HEAVY] = {cls = "XG_fykanx", snd = "snd_fykanx", freeze = 400, shine = {0xffffff, 0.1}, follow = true, shake = {0, 6, 400}},
	[DA] = {cls = "XG_fyq", snd = "snd_def", freeze = 50, follow = true},
	[DA_HEAVY] = {cls = "XG_fyqx", snd = "snd_defx", freeze = 400, follow = true, shine = {0xffffff, 0.1}, shake = {0, 6, 400}},
	[4] = {cls = "XG_mffy", snd = "snd_def", freeze = 50, follow = true},
	[MAGIC_HEAVY] = {cls = "XG_mffyx", snd = "snd_defx", freeze = 400, follow = true, shine = {0xffffff, 0.15}, shake = {0, 6, 400}},
	[7] = {cls = "XG_fire_fy", snd = "snd_defx", freeze = 400, follow = true, shine = {0xFFFF67, 0.2}, shake = {0, 6, 400}},
	[8] = {cls = "XG_ice_fy", snd = "snd_defx", freeze = 400, follow = true, shine = {0xA3E5F5, 0.2}, shake = {0, 6, 400}},
	[9] = {cls = "XG_dian_fy", snd = "snd_defx", freeze = 400, follow = true, shine = {0x8288D2, 0.2}, shake = {0, 6, 400}},
}

local SHAKE_POW_MAX = 10
local SCALE, OX = 1.2, 160 -- the 800x600 stage on the 1280x720 screen

local Fx = {}
Fx.__index = Fx

BVNEffects = {
	New = function(battle)
		local fx = setmetatable({battle = battle, freeze = 0, freezeEnabled = true, onFreezeOver = {},
			slowRate = 0, slowFrames = 0, fxGap = 1, fxFrame = 0, blur = 0, blurFrames = 0, blurEnabled = true,
			shines = {}, effects = {}, shadows = {}, frameCount = {},
			sx = {hold = 0, pow = 0, dir = 1, frame = 0, lose = 0, off = 0}, sy = {hold = 0, pow = 0, dir = 1, frame = 0, lose = 0, off = 0},
			black = false, mapHidden = false, justRender = {}, justAnimate = {}, darkMul = 1, renderDark = false,
			replaceFrame = 0, replaceHold = 0, explodeFrame = 0, face = nil}, Fx)
		return fx
	end,
	HIT = HIT, GUARD = GUARD,
}

-- Between rounds: nothing from the last round carries over.
function Fx:Reset()
	self.freeze, self.freezeEnabled, self.blurEnabled, self.onFreezeOver = 0, true, true, {}
	self:SlowResume()
	self:CancelBlur()
	self:HideBlack()
	self.justRender, self.justAnimate = {}, {}
	self.renderDark, self.darkMul = false, 1
	self.replaceHold, self.explodeFrame = 0, 0
	self.shadows, self.effects, self.shines = {}, {}, {}
	self:EndShake()
	self.sx.pow, self.sy.pow = 0, 0
	self.hitFocus = nil
end

local function sound(name)
	local clip = name and BVNFxData and BVNFxData.sounds[name]
	if clip then BVNSound.Play(clip, 110) end
end

-- Per logic tick ------------------------------------------------------------------------

function Fx:Render()
	if self.freezeEnabled then self:RenderFreeze() end
	if self.slowFrames > 0 then
		self.slowFrames = self.slowFrames - 1
		if self.slowFrames <= 0 then self:SlowResume() end
	end
	self:RenderShine()
	self.frameCount = {}
	for i = #self.effects, 1, -1 do
		local e = self.effects[i]
		if e.active then self:RenderEffect(e) end
	end
	if self.fxFrame >= self.fxGap then
		self.fxFrame = 0
		self:RenderAnimate()
	else
		self.fxFrame = self.fxFrame + 1
	end
	self:RenderBlackBack()
	for i = #self.effects, 1, -1 do
		if not self.effects[i].active then table.remove(self.effects, i) end
	end
end

function Fx:RenderAnimate()
	for _, e in ipairs(self.effects) do
		if e.active then self:AnimateEffect(e) end
	end
	self:RenderShadows()
	for _, f in ipairs(self.justAnimate) do f:RenderAnimate() end
	self:RenderShake(self.sx)
	self:RenderShake(self.sy)
	self:RenderRemoveEnemy()
	if self.blurFrames > 0 then
		self.blurFrames = self.blurFrames - 1
		if self.blurFrames <= 0 then self:CancelBlur() end
	end
end

-- Freeze (hit-stop) -----------------------------------------------------------------------

function Fx:Freeze(ms)
	if not self.freezeEnabled or ms < 1 then return end
	local n = BVNRuntime.INT(ms * 0.001 * 60)
	if n < 1 or self.freeze > n then return end
	self.freeze = n
	if ms > 300 and self.slowRate > 0 then self:BgBlur(self.slowRate * 4, 0, 500) end
	self.battle:PauseGame()
end

function Fx:RenderFreeze()
	if self.freeze <= 0 then return end
	self.freeze = self.freeze - 1
	if self.freeze <= 0 then
		local calls = self.onFreezeOver
		self.onFreezeOver = {}
		for _, fn in ipairs(calls) do fn() end
		if self.hitFocus then
			self.hitFocus = nil
			self.battle:CameraResume()
		end
		self.battle:ResumeGame()
	end
end

-- Slow motion and background blur (EffectSlowHandler) ---------------------------------------

-- time 0: no limit, until SlowResume.
function Fx:SlowDown(rate, ms)
	if self.slowRate > rate then return end
	self.slowRate = rate
	self.battle:SetSlow(rate)
	self:BgBlur(rate * 2, 0, 250)
	self.fxGap = math.ceil(60 / (30 / rate)) - 1
	self.slowFrames = (ms or 0) == 0 and 0 or BVNRuntime.INT(ms * 0.001 * 60)
end

function Fx:SlowResume()
	self.slowRate = 0
	self.battle:SetSlow(0)
	self.fxGap, self.fxFrame = 1, 0
	self.slowFrames = 0
end

function Fx:BgBlur(bx, _, ms)
	if not self.blurEnabled or self.blur > bx then return end
	self.blur = bx
	self.blurFrames = BVNRuntime.INT((ms or 1000) * 0.001 * 30)
end

function Fx:CancelBlur() self.blur, self.blurFrames = 0, 0 end

-- Shine (ShineEffectView): a full-screen flash, additive for light colours.
function Fx:Shine(color, alpha)
	color = color or 0xffffff
	alpha = alpha or 0.2
	if #self.shines > 3 then table.remove(self.shines, 1) end
	local add = color > (0xffffff >> 1)
	if not add then alpha = alpha * 0.8 end
	self.shines[#self.shines + 1] = {c = {(color >> 16) & 255, (color >> 8) & 255, color & 255}, a = BVNRuntime.INT(alpha * 100),
		add = add, frame = 0}
end

function Fx:RenderShine()
	for i = #self.shines, 1, -1 do
		local s = self.shines[i]
		s.frame = s.frame + 1
		if s.frame % 3 == 0 then
			s.a = s.a - 4
			if s.a <= 5 then table.remove(self.shines, i) end
		end
	end
end

-- Shake (EffectShakeHandler): the whole stage moves by whole pixels, alternating sign
-- every animate frame and losing power every second one.
function Fx:Shake(powX, powY, ms)
	powX, powY = powX or 0, powY or 3
	local X, Y = self.sx, self.sy
	if math.abs(X.pow) > math.abs(powX) or math.abs(Y.pow) > math.abs(powY) then return end
	for _, p in ipairs({{X, powX}, {Y, powY}}) do
		local s, pow = p[1], p[2]
		if pow ~= 0 then
			if s.pow == 0 then
				s.dir = pow > 0 and 1 or -1
				s.pow = BVNRuntime.INT(math.abs(pow))
			else
				s.pow = BVNRuntime.INT(s.pow + math.abs(pow) * 0.5)
			end
			if s.pow > SHAKE_POW_MAX then s.pow = SHAKE_POW_MAX end
		end
	end
	if not ms or ms <= 0 then ms = 500 end
	local frames = ms * 0.001 * 30
	X.lose = math.max(1, math.ceil(X.pow / frames))
	Y.lose = math.max(1, math.ceil(Y.pow / frames))
end

function Fx:StartShake(px, py) self.sx.hold, self.sy.hold = BVNRuntime.INT(px or 0), BVNRuntime.INT(py or 0) end
function Fx:EndShake()
	self.sx.hold, self.sy.hold = 0, 0
	self.sx.off, self.sy.off = 0, 0
end

function Fx:RenderShake(s)
	local v = s.hold + s.pow
	if v <= 0 then return end
	s.off = v * s.dir
	if s.pow > 0 and s.frame % 2 == 0 then
		s.pow = s.pow - s.lose
		if s.pow < s.lose then
			s.pow, s.off, s.frame, s.lose = 0, 0, 0, 0
			return
		end
	end
	s.frame = s.frame + 1
	s.dir = -s.dir
end

-- Stage offset in 800x600 pixels.
function Fx:ShakeOffset() return self.sx.off, self.sy.off end

-- Effect clips (EffectView) -------------------------------------------------------------------

local function clipOf(e) return BVNFxData and BVNFxData.effects[e.cls] end

function Fx:Add(e, x, y, dir, playSnd)
	local data = clipOf(e)
	if not data then return nil end
	local v = {e = e, data = data, x = x, y = y, cur = 0, shown = 0, rot = 0, dir = dir or 1, active = true, hold = -1,
		loop = e.buff or false}
	if e.rand then v.rot = math.floor(BVNRuntime.RAND() * 360) end
	if v.rot ~= 0 then v.dir = 1 end
	if playSnd ~= false then sound(e.snd) end
	self.effects[#self.effects + 1] = v
	return v
end

-- EffectCtrl.doEffectVO: at most three of one effect per frame.
function Fx:Play(e, x, y, dir, target, playSnd)
	local n = (self.frameCount[e] or 0) + 1
	self.frameCount[e] = n
	if n > 3 then return nil end
	local v = self:Add(e, x, y, dir, playSnd)
	if e.freeze then self:Freeze(e.freeze) end
	if e.shake then self:Shake(e.shake[1], e.shake[2], e.shake[3]) end
	if e.shine then self:Shine(e.shine[1], e.shine[2]) end
	if e.slow then self:SlowDown(e.slow[1], e.slow[2]) end
	if v and target then self:SetTarget(v, target) end
	if e.sp and target and target.kind == "fighter" then
		local sv = self:Add(E[e.sp], target.x, target.y, target.dir)
		if sv then self:SetTarget(sv, target) end
	end
	return v
end

function Fx:SetTarget(v, t)
	v.target = t
	local e = v.e
	if e.special and t.kind == "fighter" then t:ChangeColor(e.special) end
	if e.buff and t.kind == "fighter" and e.offset then t:ChangeColor(e.offset) end
	if e.steel and t.kind == "fighter" and t.steel then
		-- SteelHitEffect: the armoured fighter flashes white (yellow with super armour) until the freeze ends.
		local ct = {150, 150, 150}
		if t.steelSuper then
			ct[3] = 0
			self:Shine(0xffff00, 0.3)
		end
		t:ChangeColor(ct)
		self.onFreezeOver[#self.onFreezeOver + 1] = function() t:ResumeColor() end
	end
end

function Fx:Effect(id, x, y, dir, target, playSnd)
	local e = E[id]
	if not e then return nil end
	if e.screen then return self:ScreenEffect(e) end
	return self:Play(e, x, y, dir, target, playSnd)
end
Fx.Named = Fx.Effect

function Fx:RenderEffect(v)
	local t, e = v.target, v.e
	if not t then return end
	if e.special then
		-- SpecialEffectView: follows until the target lands or recovers, then plays "finish".
		if v.finished then return end
		local s = t.state
		if s == 23 or s == 24 or s == 0 then
			local f = v.data.labels and v.data.labels.finish
			if f then v.cur = f - 1 end
			v.finished = true
			t:ResumeColor()
		else
			v.x, v.y = t.x, t.y
		end
	elseif e.buff then
		if not v.buffRef or v.buffRef.done then
			t:ResumeColor()
			v.active = false
		else
			v.x, v.y = t.x, t.y
		end
	end
end

function Fx:AnimateEffect(v)
	local n = #v.data.frames
	local last = n - 1
	if v.loop then
		if v.cur == last then v.cur = 0 end
	else
		if v.cur == last then
			if v.hold == -1 then v.active = false return end
			v.cur = 0
		end
		if v.hold ~= -1 then
			v.hold = v.hold - 1
			if v.hold < 0 then v.active = false return end
		end
	end
	local labels = v.data.labels
	if labels and labels.loop and labels.loop - 1 == v.cur then v.cur = 1 end
	v.shown = v.cur
	v.cur = v.cur + 1
end

-- BGEffect: a screen-space backdrop clip (kobg) that hides the map while it plays.
function Fx:ScreenEffect(e, holdSec)
	local v = self:Add(e, 0, 0, 1)
	if not v then return nil end
	v.screen = true
	if holdSec then v.hold = holdSec * 30 end
	return v
end

function Fx:HitEffect(h, rect, target)
	local e = HIT[h.hitType]
	if not e then return end
	local cx, cy = rect[1] + rect[3] / 2, rect[2] + rect[4] / 2
	local dir = 1
	if (h.slowDown or 0) > 0 then self:SlowDown(1.5, h.slowDown * 1000) end
	if h.focusTarget and target then
		self.hitFocus = target
		self.battle:CameraFocusOne(target)
	elseif self.hitFocus == target then
		self.hitFocus = nil
	end
	self:Play(e, cx, cy, dir, target)
end

-- defenseType 1 (hand): cuts are guarded like blows.
function Fx:DefenseEffect(h, rect, defenseType, target)
	local t = h.hitType
	if defenseType == 1 then
		if t == KAN then t = DA elseif t == KAN_HEAVY then t = DA_HEAVY end
	end
	local e = GUARD[t] or GUARD[MAGIC_HEAVY]
	local dir = (e.follow and h.owner and h.owner.dir) or 1
	self:Play(e, rect[1] + rect[3] / 2, rect[2] + rect[4] / 2, dir, target)
end

function Fx:SteelEffect(h, rect, target)
	local t = h.hitType
	if t == 0 then return end
	local id = (t == KAN or t == KAN_HEAVY) and "steel_hit_kan" or ((t == DA or t == DA_HEAVY) and "steel_hit_qdj" or "steel_hit_mfdj")
	self:Play(E[id], rect[1] + rect[3] / 2, rect[2] + rect[4] / 2, 1, target)
end

-- doBuffEffect: a looping clip on the fighter while the buff lasts.
function Fx:BuffEffect(id, target, buff)
	local v = self:Add(E[id], target.x, target.y, target.dir)
	if v then
		v.buffRef = buff
		self:SetTarget(v, target)
	end
end

-- Afterimages (EffectShadowHandler / ShadowEffectView) ----------------------------------------

function Fx:StartShadow(f, r, g, b)
	local s = self.shadows[f]
	if s then
		s.r, s.g, s.b, s.stop = r or 0, g or 0, b or 0, false
		return
	end
	self.shadows[f] = {f = f, r = r or 0, g = g or 0, b = b or 0, snaps = {}, add = 0}
end

function Fx:EndShadow(f)
	local s = self.shadows[f]
	if s then s.stop = true end
end

function Fx:RenderShadows()
	for f, s in pairs(self.shadows) do
		if f.dead then s.stop = true end
		if s.stop then
			if #s.snaps == 0 then self.shadows[f] = nil end
		else
			if s.add > 1 then
				s.add = 0
				local snap
				if f.Snapshot then snap = f:Snapshot()
				elseif f.clip and not f.dead then
					snap = {}
					BVNClip.Draw(f.clip, f.x, f.y, f.dir, {capture = snap})
					if #snap == 0 then snap = nil end
				end
				if snap then s.snaps[#s.snaps + 1] = {blits = snap, a = 0.8} end
			else
				s.add = s.add + 1
			end
		end
		for i = #s.snaps, 1, -1 do
			local p = s.snaps[i]
			p.a = p.a - 0.1
			if p.a <= 0.001 then table.remove(s.snaps, i) end
		end
	end
end

-- Musou enemies fade out before removal (removeEnemyEffect).
function Fx:RemoveEnemy(f, callback) self.removing = self.removing or {}; self.removing[#self.removing + 1] = {f = f, cb = callback} end
function Fx:RenderRemoveEnemy()
	if not self.removing then return end
	for i = #self.removing, 1, -1 do
		local o = self.removing[i]
		o.f.fade = (o.f.fade or 1) - 0.05
		if o.f.fade <= 0 then
			table.remove(self.removing, i)
			if o.cb then o.cb() end
		end
	end
end

-- Black backdrop (EffectBlackBackHandler) -----------------------------------------------------

local function addOnce(list, v)
	for _, x in ipairs(list) do if x == v then return end end
	list[#list + 1] = v
end
local function removeFrom(list, v)
	for i, x in ipairs(list) do if x == v then table.remove(list, i) break end end
	return #list < 1
end

function Fx:ShowBlack()
	self.black, self.mapHidden = true, true
end
function Fx:HideBlack()
	self.black, self.mapHidden = false, false
	self.face = nil
end

function Fx:Bisha(target, super, faceImg)
	addOnce(self.justAnimate, target)
	self.battle:PauseGame()
	self.battle.renderHit = false
	self:ShowBlack()
	if faceImg and target.kind == "fighter" then self:ShowFace(target, faceImg) end
	if super then
		self.battle:CameraFocusOne(target)
		self:Effect("bisha_super", target.x, target.y - 50)
	else
		self:Effect("bisha", target.x, target.y - 50)
	end
end

function Fx:EndBisha(target)
	if removeFrom(self.justAnimate, target) then
		self.battle:ResumeGame()
		self.battle:CameraResume()
		self.battle.renderHit = true
		self:HideBlack()
	end
end

function Fx:WanKai(target, faceImg)
	addOnce(self.justAnimate, target)
	self.battle:PauseGame()
	self.battle.renderHit = false
	self:ShowBlack()
	if faceImg then self:ShowFace(target, faceImg) end
	self.battle:CameraFocusOne(target)
	self:Effect("bisha_super", target.x, target.y - 50)
end
Fx.EndWanKai = Fx.EndBisha

function Fx:ShowFace(target, img)
	local t = target:Target()
	local side = (t and target.x > t.x) and 2 or 1
	local data = BVNFxData and BVNFxData.effects.bisha_face_mc
	if not data then return end
	self.face = {data = data, side = side, img = img, t = 1, y = 100 + 100 / self.battle:CameraZoom()}
end

function Fx:ReplaceSkill(target)
	self.battle:PauseGame()
	self:ShowBlack()
	self.black = true
	self:Effect("replaceSp", target.x, target.y)
	self.replacePos = {target.x, target.y}
	self.replaceFrame, self.replaceHold = 0, 60
end

function Fx:EnergyExplode(target)
	self.battle:PauseGame()
	self:ShowBlack()
	self:Effect("explodeSp", target.x, target.y)
	self.explodePos = {target.x, target.y}
	self.explodeFrame = BVNRuntime.INT(0.7 * 60)
end

function Fx:GhostStep(target)
	addOnce(self.justRender, target)
	addOnce(self.justAnimate, target)
	self.battle:PauseGame()
	self:ShowBlack()
	sound("snd_ghost_jump")
end

function Fx:EndGhostStep(target)
	local a = removeFrom(self.justRender, target)
	local b = removeFrom(self.justAnimate, target)
	if a and b then
		self.battle:ResumeGame()
		self:HideBlack()
	end
end

function Fx:StartRenderBlackBack() self.renderDark = true end

function Fx:RenderBlackBack()
	if self.renderDark then
		local bishaIng = false
		for _, f in ipairs(self.battle.fighters) do
			if f.state == 12 or f.state == 13 then bishaIng = true end
		end
		if bishaIng then
			self.darkMul = 0.3
		elseif self.darkMul + 0.025 >= 1 then
			self.darkMul, self.renderDark = 1, false
		else
			self.darkMul = self.darkMul + 0.025
		end
	end
	if self.replaceHold > 0 then
		self.replaceFrame = self.replaceFrame + 1
		if self.replaceFrame == 1 then self:Effect("replaceSp2", self.replacePos[1], self.replacePos[2]) end
		if self.replaceFrame > self.replaceHold then
			self.battle:ResumeGame()
			self:HideBlack()
			self.replaceHold = 0
		end
	end
	if self.explodeFrame > 0 then
		self.explodeFrame = self.explodeFrame - 1
		if self.explodeFrame <= 0 then
			self:Effect("explodeSp2", self.explodePos[1], self.explodePos[2])
			self.battle:ResumeGame()
			self:HideBlack()
		end
	end
	for _, f in ipairs(self.justRender) do
		f:Render()
		self.battle:FixPosition(f)
	end
	if self.face then
		if self.face.t < #self.face.data.frames - 1 then self.face.t = self.face.t + 0.5 end
	end
end

-- Drawing -----------------------------------------------------------------------------------

function Fx:MapVisible()
	if self.mapHidden then return false end
	for _, v in ipairs(self.effects) do
		if v.screen and v.active then return false end
	end
	return true
end

-- Screen-space backdrops (kobg) under the scene.
function Fx:DrawBack()
	local b = self.battle
	local ox, oy = self:ShakeOffset()
	if self.black then b:ScreenImage("pixel.png", -20, -20, 1320, 760, 0, 0, 0, 255, 1) end
	for _, v in ipairs(self.effects) do
		if v.screen and v.active then
			local f = v.data.frames[v.shown + 1]
			if f and f.img then
				b:ScreenImage(f.img, OX + (f.x + ox) * SCALE, (f.y + oy) * SCALE, SCALE, SCALE, 255, 255, 255, 255, 2,
					v.data.add and "add" or nil)
			end
		end
	end
	-- BlackBackView: the ultimate cut-in sits on the backdrop, behind the fighters.
	local fc = self.face
	if fc then
		local fr = fc.data.frames[math.floor(fc.t)]
		local function at(x, y) return OX + (x + ox) * SCALE, (fc.y + y + oy) * SCALE end
		if fr and fr.img then
			local x, y = at(fr.x, fr.y)
			b:ScreenImage(fr.img, x, y, SCALE, SCALE, 255, 255, 255, 255, 5)
		end
		local m = fc.data.holders and fc.data.holders["facemc" .. fc.side]
		m = m and m[math.floor(fc.t)]
		if m and fc.img then
			local sz = Image.GetSize(fc.img)
			local sx, sy = 254 / sz.x * m[1], 180 / sz.y * m[4]
			local x, y = at(m[5], m[6])
			if sx < 0 then x = x + 254 * m[1] * SCALE end
			b:ScreenImage(fc.img, x, y, sx * SCALE, sy * SCALE, 255, 255, 255, 255, 6)
		end
	end
end

function Fx:DrawShadows(order)
	for _, s in pairs(self.shadows) do
		for _, p in ipairs(s.snaps) do
			for _, b in ipairs(p.blits) do
				Image.DrawEx(b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], 255, 255, 255, math.floor(255 * p.a), order)
				if s.r > 0 or s.g > 0 or s.b > 0 then
					Image.DrawEx(b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], s.r, s.g, s.b, math.floor(255 * p.a), order, nil, "add")
				end
			end
		end
	end
end

function Fx:Draw()
	for _, v in ipairs(self.effects) do
		if v.active and not v.screen then
			local f = v.data.frames[v.shown + 1]
			if f and f.img then
				-- A mirrored image is flipped in place: put the pivot at the origin's mirror.
				local px = v.dir < 0 and (1 + f.x / f.w) or (-f.x / f.w)
				local a = 255
				if v.target and v.target.fade then a = math.floor(255 * v.target.fade) end
				Image.DrawEx(f.img, v.x / 100, v.y / 100, v.rot * v.dir, v.dir, 1, px, -f.y / f.h, 255, 255, 255, a, 72,
					nil, v.data.add and "add" or nil)
			end
		end
	end
end

-- Screen overlays: shines and the ultimate cut-in.
function Fx:DrawScreen(fighters)
	for _, s in ipairs(self.shines) do
		if s.add then
			Image.DrawUIScaled("pixel.png", 0, 0, 1280, 720, s.c[1], s.c[2], s.c[3], math.floor(s.a * 2.55), 40, "add")
		else
			D.UI(0, 0, 1280, 720, s.c, s.a * 2.55, 40)
		end
	end

end
