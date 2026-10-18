-- The MUSOU fight HUD (MusouUI): the team bar (MusouFightBarUI with MusouHpBar /
-- HpBarLerp, MusouQiBar, MusouEnergyBar, the two MusouMiniHpBar), the KO count
-- (MusouKOsUI), the time (MusouTimeUI), the wave counter and its ring
-- (MusouWaveUI), the boss bar (BossHpUI) and the other bosses' bars
-- (EnemyHpUIGroup), the mooks' bars over their heads (MusouEnemyBarCtrl /
-- EnemyHpFollowUI), the hit counter (HitsUI) and the start / boss / KO / result
-- animation (startKOmc). Drawn from tools/convert_musou_ui.py's movies at their
-- slots in $musou$MC_ui; the 800x600 stage maps to the window at 1.2x, centred.
-- Not attached to any actor; BVNMusouBattle owns one.
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})
local ORDER = 100
local WHITE = {255, 255, 255}

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function scaleOf(v, max) return clamp(max > 0 and v / max or 0, 0.0001, 1) end

local sizes = {}
local function size(img)
	local s = sizes[img]
	if not s then
		local v = Image.GetSize(img)
		s = {v.x, v.y}
		sizes[img] = s
	end
	return s
end

-- A masked face (BVNMusouConfig.faces[kind][id]) at a content slot's matrix.
local function face(kind, id, m, alpha, order, mode)
	local fs = BVNMusouConfig and BVNMusouConfig.faces and BVNMusouConfig.faces[kind]
	local f = fs and id and fs[id]
	if not f then return end
	S.Image(f.img, S.Mul(m, {f.s, 0, 0, f.s, f.x, f.y}), alpha, order, mode)
end

-- A movie frame in battle world coordinates (stage pixels, no rotation).
local function drawWorld(m, f, tf, alpha, order, slots)
	if not m then return end
	local fr = m.frames[m.seq[(f or 0) + 1] or 1]
	if not fr then return end
	local i, n = 1, #fr
	while i <= n do
		local e = fr[i]
		if type(e) == "number" then
			local img = m.imgs[e][1]
			local mm = S.Mul(tf, {fr[i + 1], fr[i + 2], fr[i + 3], fr[i + 4], fr[i + 5], fr[i + 6]})
			local w, h = size(img)[1], size(img)[2]
			local x, y = mm[5] + math.min(0, mm[1] * w), mm[6] + math.min(0, mm[4] * h)
			Image.DrawEx(img, x / 100, y / 100, 0, mm[1], mm[4], 0, 0, 255, 255, 255, clamp(alpha * fr[i + 7] * 255, 0, 255), order)
			i = i + 8
		else
			if e.slot then
				local fn = slots and slots[e.slot]
				if fn and fn(S.Mul(tf, e.m), alpha * (e.a or 1), e) == "hide" then
					local path = e.slot
					repeat
						i = i + 1
						local x = fr[i]
						if type(x) == "number" then i = i + 7 end
					until i > n or (type(x) == "table" and x.slotEnd == path)
				end
			end
			i = i + 1
		end
	end
end

-- HpBarLerp: the bar eases to the HP, the red bar follows after the hit-stun.
local function newLerp() return {bar = 1, red = 1, rate = 1, moving = false, delay = 0, justFly = false} end

local function renderLerp(l, f)
	local rate = f.hp / f.hpMax
	if l.moving and rate ~= l.rate then
		l.red = l.rate
		l.moving = false
	end
	l.rate = rate
	local diff = rate - l.bar
	if math.abs(diff) < 0.01 then l.bar = rate else l.bar = l.bar + diff * (diff < 0 and 0.4 or 0.04) end
	local s = f.state
	if s == 21 then
		l.delay = 100
	elseif s == 22 or s == 23 then
		if l.delay > 0 then
			if not l.justFly then
				l.delay = 1.5 * 60
				l.justFly = true
			elseif l.delay > 0 then
				l.delay = l.delay - 1
			end
		end
	else
		l.delay = 0
		l.justFly = false
	end
	if l.delay <= 0 then
		local d2 = rate - l.red
		if math.abs(d2) < 0.01 then
			l.red = rate
			l.moving = false
		else
			l.red = l.red + d2 * (d2 < 0 and 0.1 or 0.02)
			l.moving = true
		end
	end
end

-- EnergyBarFill / EnergyBarLabel: frame 1 normal, 2 overload; flashing alternates.
local function newEnergy() return {scale = 1, over = false, flash = false, int = 0, nextFrame = 2, frame = 1} end

local function renderEnergy(e, f)
	local rate = f.energy / f.energyMax
	if f.overload then
		if not e.over then e.over, e.flash, e.frame = true, false, 2 end
	elseif rate < 0.3 then
		if not e.flash then e.flash, e.int, e.nextFrame = true, 0, 2 end
	elseif e.over or e.flash then
		e.over, e.flash, e.frame = false, false, 1
	end
	local diff = rate - e.scale
	if math.abs(diff) < 0.01 then e.scale = rate else e.scale = e.scale + diff * 0.4 end
	if e.flash then
		e.int = e.int + 1
		if e.int > 2 then
			e.int = 0
			e.frame = e.nextFrame
			e.nextFrame = e.nextFrame == 1 and 2 or 1
		end
	end
end

local Hud = {}
Hud.__index = Hud

BVNMusouHud = {
	ORDER = ORDER,
	Face = face,
	DrawWorld = drawWorld,

	New = function(b)
		local h = setmetatable({b = b, t = 0, bosses = {}, others = {}, follow = {}, lerp = newLerp(), bossLerp = newLerp(),
			energy = newEnergy(), qi = 0, maxT = 0, maxPlaying = false}, Hud)
		h.ko = {clip = S.Clip("musou_start_ko", 0, false), cbs = {}}
		h.hits = {clip = S.Clip("musou_hits", 0, false), shown = false, n = 0}
		h:BuildSlots()
		return h
	end,
}

-- MusouUI.render (every tick) and renderAnimate (every 2nd).
function Hud:Render()
	self.t = self.t + 1
	local b = self.b
	local p1 = b.current
	if p1 then
		renderLerp(self.lerp, p1)
		renderEnergy(self.energy, p1)
		-- MusouQiBar.render: 0..3 bars eased by 0.4.
		local rate = math.min(p1.qi / 100, 3)
		local per = self.qi
		local diff = rate - per
		if math.abs(diff) < 0.01 then per = rate else per = per + diff * 0.4 end
		self.qi = math.max(per, 0.0001)
		if self.qi >= 3 then
			if not self.maxPlaying then self.maxPlaying, self.maxT = true, 0 end
			self.maxT = self.maxT + 1
		else
			self.maxPlaying = false
		end
	end
	local boss = self.boss
	if boss then renderLerp(self.bossLerp, boss) end
	-- EnemyHpUIGroup.render: bars of dead bosses go.
	for i = #self.others, 1, -1 do
		if not self.others[i].alive then table.remove(self.others, i) end
	end
	-- MusouEnemyBarCtrl.render / EnemyHpFollowUI.render.
	for i = #self.follow, 1, -1 do
		local fb = self.follow[i]
		if fb.visible then
			fb.delay = fb.delay - 1
			if fb.delay <= 0 then fb.visible = false end
		end
		if not fb.f.alive then table.remove(self.follow, i) end
	end
	-- Clips inside the HUD play at the game's 60 fps; startKOmc is stepped at 30.
	self.hits.clip:Step()
	self.hits.clip:Step()
	local k = self.ko
	if k.playing and self.t % 2 == 0 then
		local c = k.clip
		if c.m and not (c.m.stops and c.m.stops[c.f]) then c:NextFrame() end
		-- Every COMPLETE listener added since the last one fires (they pile up when
		-- animations interrupt each other, as with addEventListener).
		if c.done and #k.cbs > 0 then
			local cbs = k.cbs
			k.cbs = {}
			for _, cb in ipairs(cbs) do cb() end
		end
	end
end

-- playStartKO: gotoAndStop(label), then one frame per UI frame until a stop frame.
function Hud:PlayStartKO(label, cb)
	local k = self.ko
	k.clip:Goto(label, false)
	k.clip.done = false
	if cb then k.cbs[#k.cbs + 1] = cb end
	k.playing = true
end

function Hud:ShowStart(cb) self:PlayStartKO("mission_start", cb) end
function Hud:ShowBossIn(cb) self:PlayStartKO("boss_in", cb) end

-- showWin: "MISSION COMPLETE", the winner's pose; 4 s after the banner, back to the map.
function Hud:ShowWin(cb)
	self:PlayStartKO("mission_complete", function() self.b:After(240, cb) end)
	self.b:WinPose()
end

-- showLose: "MISSION FAILED"; 3 s after the banner, back to the map.
function Hud:ShowLose(cb)
	self:PlayStartKO("mission_fail", function() self.b:After(180, cb) end)
end

-- HitsUI.show / hide.
function Hud:ShowHits(n)
	local h = self.hits
	h.n = n
	if h.shown then
		h.clip:Goto("update", true)
		return
	end
	h.shown = true
	h.clip:Goto("fadin", true)
end

function Hud:HideHits()
	local h = self.hits
	if not h.shown then return end
	h.shown = false
	h.clip:Goto("fadout", true)
end

function Hud:UpdateFighter() end

-- setBossHp: the main boss bar; the other living bosses move to the small bars.
function Hud:SetBossHp(f)
	if f then
		if not self:HasBoss(f) then self.bosses[#self.bosses + 1] = f end
		for i = #self.others, 1, -1 do if self.others[i] == f then table.remove(self.others, i) end end
		for _, o in ipairs(self.bosses) do
			if o ~= f then
				local found = false
				for _, x in ipairs(self.others) do if x == o then found = true end end
				if not found then self.others[#self.others + 1] = o end
			end
		end
	end
	self.boss = f
end

function Hud:HasBoss(f)
	for _, x in ipairs(self.bosses) do if x == f then return true end end
	return false
end

function Hud:UpdateBossHp()
	for i = #self.bosses, 1, -1 do
		local f = self.bosses[i]
		if not f.alive or not f.active then table.remove(self.bosses, i) end
	end
	self:SetBossHp(self.bosses[1])
end

-- MusouEnemyBarCtrl.updateEnemyBar: a mook's bar appears for 3 s when it is hit.
function Hud:UpdateEnemyBar(f)
	if f.musouBoss then return end
	for _, fb in ipairs(self.follow) do
		if fb.f == f then
			fb.visible, fb.delay = true, 3 * 60
			return
		end
	end
	self.follow[#self.follow + 1] = {f = f, visible = false, delay = 0}
end

-- Drawing ---------------------------------------------------------------------------------------

local function bar(name, m, sx, alpha, frame)
	S.DrawFrame(S.Load(name), frame or 0, S.Mul(m, {sx, 0, 0, 1, 0, 0}), alpha, ORDER, "ui")
end

local function text(e, s, m, alpha)
	S.Text(s, m[5] + (e.left or 0) * m[1], m[6], (e.size or 12) * m[4], e.color or WHITE, e.align, (e.w or 0) * m[1], alpha, ORDER)
end

function Hud:MiniFighter(n)
	local b = self.b
	local k = 0
	for _, f in ipairs(b.team) do
		if f ~= b.current then
			k = k + 1
			if k == n then return f end
		end
	end
	return nil
end

function Hud:BuildSlots()
	local h = self
	local sl = {}
	sl["hpbarmc/hpbar"] = function(m, a) bar("musou_hpbar", m, h.lerp.bar, a) return "hide" end
	sl["hpbarmc/hpbar2"] = function(m, a) bar("musou_hpbar_red", m, h.lerp.red, a) return "hide" end
	for i = 1, 3 do
		sl["hpbarmc/qibar/bar" .. i] = function(m, a)
			local v = h.qi
			if v >= 3 or v <= i - 1 then return "hide" end
			bar("musou_qibar_seg", m, clamp(v - (i - 1), 0, 1), a)
			return "hide"
		end
	end
	sl["hpbarmc/qibar/maxmc"] = function(m, a)
		if h.qi >= 3 then
			local mv = S.Load("musou_qibar_max")
			if mv then S.DrawFrame(mv, (1 + h.maxT) % mv.n, m, a, ORDER, "ui") end
		end
		return "hide"
	end
	sl["hpbarmc/energybar/bar"] = function(m, a) bar("musou_energy_bar", m, h.energy.scale, a, h.energy.frame - 1) return "hide" end
	sl["hpbarmc/energybar/energy_txtmc"] = function(m, a)
		local p1 = h.b.current
		local comic = p1 and (p1.char.comic_type or 0) or 0
		S.DrawFrame(S.Load(h.energy.frame == 2 and "musou_energy_txt_red" or "musou_energy_txt"), comic == 1 and 1 or 0, m, a, ORDER, "ui")
		return "hide"
	end
	sl["hpbarmc/facemc/ct"] = function(m, a)
		local p1 = h.b.current
		if p1 then face("bar", p1.info.id, m, a, ORDER, "ui") end
	end
	for n = 1, 2 do
		local base = "hpbarmc/little_hp_" .. n
		sl[base] = function() if not h:MiniFighter(n) then return "hide" end end
		sl[base .. "/bar_hp"] = function(m, a)
			local f = h:MiniFighter(n)
			if f then bar("musou_mini_bar", m, scaleOf(f.hp, f.hpMax), a) end
			return "hide"
		end
		sl[base .. "/bar_qi"] = function(m, a)
			local f = h:MiniFighter(n)
			if f then bar("musou_mini_bar", m, scaleOf(f.qi, 300), a) end
			return "hide"
		end
		sl[base .. "/face/ct"] = function(m, a)
			local f = h:MiniFighter(n)
			if f then face("mini", f.info.id, m, a, ORDER, "ui") end
		end
	end
	-- MusouKOsUI: font1 digits at the counter's container.
	sl["kos_mc/ct"] = function(m, a) S.Font(tostring(h.b.koNum), 0, 0, 1, a, ORDER, "ui", nil, m) end
	sl["time_mc/text"] = function(m, a, e)
		local sec = math.floor(h.b.gameTime / 30)
		text(e, string.format("%02d:%02d", sec // 60, sec % 60), m, a)
	end
	sl["wave_mc/txt"] = function(m, a, e) text(e, tostring(h.b.currentWave), m, a) end
	sl["wave_mc/txt_max"] = function(m, a, e) text(e, tostring(h.b.waveCount), m, a) end
	sl["wave_mc/ct_circle"] = function(m, a)
		local k = math.floor(clamp(h.b:WavePercent(), 0, 1) * 72 + 0.5)
		local ring = BVNMusouConfig and BVNMusouConfig.bigmap and BVNMusouConfig.bigmap.ring
		if k > 0 and ring then S.Image(string.format(ring, k), m, a, ORDER, "ui") end
	end
	sl["bosshp_mc"] = function() if not h.boss then return "hide" end end
	sl["bosshp_mc/bar"] = function(m, a) bar("musou_boss_bar", m, h.bossLerp.bar, a) return "hide" end
	sl["bosshp_mc/redbar"] = function(m, a) bar("musou_hpbar_red", m, h.bossLerp.red, a) return "hide" end
	sl["bosshp_mc/ct_face"] = function(m, a) if h.boss then face("boss", h.boss.info.id, m, a, ORDER, "ui") end end
	sl["ct_enemybar"] = function(m, a) h:DrawEnemyBars(m, a) end
	sl["hitsmc"] = function(m, a)
		-- MC_hits frame scripts: hidden on frames 0..8 (this.visible = false), shown from "fadin".
		local hc = h.hits.clip
		if hc.f >= 9 and hc.f <= 54 then hc:Draw(m, a, ORDER, "ui", h.hitsSlots) end
		return "hide"
	end
	sl["startKOmc"] = function(m, a)
		local k = h.ko
		if k.playing then k.clip:Draw(m, a, ORDER + 1, "ui") end
		return "hide"
	end
	self.slots = sl
	-- HitsUI: MCNumber digits (35 px apart) right-aligned at the clip's container.
	self.hitsSlots = {ct = function(m, a)
		local mv = S.Load("musou_hits_digits")
		if not mv then return end
		local s = tostring(h.hits.n)
		local x0 = -#s * 35 + 45
		for i = 1, #s do
			local d = tonumber(s:sub(i, i))
			S.DrawFrame(mv, d, S.Mul(m, {1, 0, 0, 1, x0 + (i - 1) * 35, 0}), a, ORDER, "ui")
		end
	end}
end

-- EnemyHpUIGroup.sortUI: up to 12 bars, 4 a row, right to left.
function Hud:DrawEnemyBars(m, a)
	local mv = S.Load("musou_enemy_hp")
	if not mv then return end
	local x, y = 0, 0
	for i = 1, math.min(#self.others, 12) do
		local f = self.others[i]
		S.DrawFrame(mv, 0, S.Mul(m, {1, 0, 0, 1, x, y}), a, ORDER, "ui", {
			bar = function(bm, ba) bar("musou_enemy_hp_bar", bm, scaleOf(f.hp, f.hpMax), ba) return "hide" end,
			ct_face = function(fm, fa) face("enemy", f.info.id, fm, fa, ORDER, "ui") end,
		})
		x = x - 110
		if i % 4 == 0 then x, y = 0, y + 30 end
	end
end

-- The mooks' bars over their heads, in the battle's world (scale 0.5, 50 px up).
function Hud:DrawWorld()
	local mv = S.Load("musou_enemy_follow")
	if not mv then return end
	for _, fb in ipairs(self.follow) do
		local f = fb.f
		if fb.visible and f.active then
			local v = scaleOf(f.hp, f.hpMax)
			drawWorld(mv, 0, {0.5, 0, 0, 0.5, f.x, f.y - 50}, 1, 74, {barmc = function(m, a)
				drawWorld(S.Load("musou_enemy_follow_bar"), 0, S.Mul(m, {v, 0, 0, 1, 0, 0}), a, 74)
				return "hide"
			end})
		end
	end
end

function Hud:Draw(sx, sy)
	local ui = S.Load("musou_ui")
	if not ui then return end
	S.DrawFrame(ui, 0, {1, 0, 0, 1, sx or 0, sy or 0}, 1, ORDER, "ui", self.slots)
end
