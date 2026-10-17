-- One match: the GameCtrl tick order, hit and push detection, camera, map,
-- hit-stop / slow motion / bisha pauses, rounds and the HUD. Not attached to
-- any actor; BVNGame owns the current battle.
local D = setmetatable({}, {__index = function(_, k) return BVNDraw[k] end})
local WHITE, BLACK = {255, 255, 255}, {0, 0, 0}
local SW, SH = 1280, 720

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local Battle = {}
Battle.__index = Battle

BVNBattle = {}

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
	for _, d in ipairs(BVNConfig.map.map.data) do
		if d.id == id then map.name, map.bgm = d.name, d.bgm end
	end
	return map
end

-- Construction ---------------------------------------------------------------------------

-- opts: {p1 = {fighter, assist, cpu}, p2 = {...}, map = id, mode, level, training}
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
	local b = setmetatable({}, Battle)
	b.opts = opts
	b.mode = opts.mode
	b.training = opts.mode == "training"
	b.map = loadMap(opts.map)
	b.fx = BVNEffects.New(b)
	b.tick, b.animCounter = 0, 0
	b.wins = {0, 0}
	b.round = 1
	b.cam = {x = 400, y = 300, w = 800}
	b.fighters = {}
	b.teamMode = #opts.p1.team > 1 or #opts.p2.team > 1
	b.teamIndex = {1, 1}
	for side = 1, 2 do b.fighters[side] = b:CreateFighter(side, opts["p" .. side].team[1]) end
	b:StartRound()
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
	-- Arcade stage multipliers (mission.json properties).
	if p.hpRate then f.hpMax = f.hpMax * p.hpRate; f.hp = f.hpMax end
	if p.attackRate then f.attackRate = p.attackRate end
	if p.cpu and not p.noAI then f.ai = BVNAI.New(f, p.level or self.opts.level or 3) end
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

-- Team mode: the loser's next member enters (GameRoundCtrl.startNextTeamFight).
-- Returns false when that team has nobody left.
function Battle:NextMember(side)
	local team = self.opts["p" .. side].team
	local i = self.teamIndex[side] + 1
	if i > #team then return false end
	local old = self.fighters[side]
	local f = self:CreateFighter(side, team[i])
	if (old.char.comic_type or 0) == (f.char.comic_type or 0) then f.qi = math.min(f.qiMax, old.qi + 100) end
	if old.assist then f.fzqi = old.fzqi end
	self.teamIndex[side] = i
	self.fighters[side] = f
	return true
end

function Battle:TargetOf(sp)
	local f = sp.kind == "fighter" and sp or sp.owner
	if not f or not f.side then f = f and f.owner end
	if not f then return nil end
	return self.fighters[3 - f.side]
end

function Battle:StartRound()
	self.sprites = {}
	for side, f in ipairs(self.fighters) do
		local p = side == 1 and self.map.p1 or self.map.p2
		f.x, f.y = p[1], p[2]
		f.dir = side == 1 and 1 or -1
		if not (self.teamMode and f.keepHp) then f.hp = f.hpMax end
		f.keepHp = nil
		f.alive = true
		f.energy, f.overload = f.energyMax, false
		f:SetVelocity(0, 0)
		f.allowLoseHP = true
		f.combo = 0
		self.sprites[#self.sprites + 1] = f
	end
	self.time = self.training and -1 or 60
	self.timeFrame = 0
	self.actionEnable = false
	self.phase, self.phaseT = "intro", 0
	self.banner = nil
	self.winner = nil
	self.pause = 0
	self.bisha = nil
	for _, f in ipairs(self.fighters) do
		f.state = 60
		f.alive = true
		if f:HasLabel("开场") then f:DoAction("开场") ; f.state = 60 else f:Idle() end
	end
	BVNSound.Music(self:MusicFor())
end

function Battle:MusicFor()
	local p1 = self.fighters[1].info
	if p1.bgm and p1.bgm.url and BVNRuntime.RAND() * 100 < (p1.bgm.rate or 0) then return "bvn/bgm/" .. p1.bgm.url:gsub("%.mp3$", "") end
	return self.map.bgm and ("bvn/bgm/" .. self.map.bgm:gsub("%.mp3$", "")) or nil
end

-- Events from fighters --------------------------------------------------------------------

function Battle:OnIdle(f)
	local o = self.fighters[3 - f.side]
	if o then o.combo = 0 end
	if f.state == 60 then f.state = 0 end
end
function Battle:OnHurtResume(f) local o = self.fighters[3 - f.side] if o then o.combo = 0 end end
function Battle:OnDie(f)
	if self.phase ~= "fight" then return end
	self.actionEnable = false
	self.phase, self.phaseT = "ko", 0
	self.winner = 3 - f.side
	self.fx:Slow(2, 1200)
	BVNHud.Banner(self, "ko", "winner", 0)
	BVNSound.Play("ko", 128)
end
function Battle:OnDead() end

function Battle:Pause(t) self.pause = math.max(self.pause, t) end

function Battle:CallAssist(f)
	local a = f.assist
	if not a or (not a.dead and a.clip) then return false end
	f.fzqi = 0
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

function Battle:FindAttacker(name, team)
	for _, sp in ipairs(self.sprites) do
		if sp.kind == "attacker" and sp.name == name and sp.team == team and not sp.dead then return sp end
	end
	return nil
end

function Battle:Bisha(f, super, face, wankai)
	local img = face and f.faces and f.faces[face] and f.char.faces[f.faces[face]]
	self.bisha = {f = f, super = super, img = img, t = 0, wankai = wankai}
	self.fx:Named(super and "bisha_super" or "bisha", f.x, f.y - 50, f.dir)
end
function Battle:EndBisha(f)
	if self.bisha and self.bisha.f == f then self.bisha = nil end
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
	if sp.vy < 2.5 and not (sp.ignoreFloor and sp.ignoreFloor > 0) then
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

function Battle:FixPosition(sp)
	local m = self.map
	local x0, x1 = m.left + 10, m.right - 10
	sp.touchSide = false
	if sp.x < x0 then sp.x = x0; sp.touchSide = true end
	if sp.x > x1 then sp.x = x1; sp.touchSide = true end
	if sp.y > m.bottom then sp.y = m.bottom end
end

function Battle:Update()
	self.tick = self.tick + 1
	self.fx:Update()
	BVNHud.StepBanner(self)
	for _, f in ipairs(self.fighters) do f.input:Update(self.actionEnable) end
	self:UpdateCamera()
	if self.fx.freeze > 0 then return end
	if self.pause > 0 then self.pause = self.pause - 1 return end
	-- Animate ticks: every 2nd logic tick (every 3rd during 1.5x slow motion).
	local gap = math.ceil(60 / (30 / self.fx.slowRate))
	self.animCounter = self.animCounter + 1
	local animate = self.animCounter >= gap
	if animate then self.animCounter = 0 end
	local bisha = self.bisha
	if bisha then
		bisha.t = bisha.t + 1
		if animate then bisha.f:RenderAnimate() end
		if bisha.t > 600 and self.bisha == bisha then self.bisha = nil end
		return
	end
	if animate and self.phase == "fight" then
		for _, f in ipairs(self.fighters) do if f.ai then f.ai:Think() end end
		if self.time > 0 then
			self.timeFrame = self.timeFrame + 1
			if self.timeFrame > 30 then
				self.timeFrame = 0
				self.time = self.time - 1
				if self.time <= 0 then self:TimeOver() end
			end
		end
	end
	-- Ghost step pauses everything but its fighter.
	local only = self.ghostOwner
	if only and not only.ghost then self.ghostOwner, only = nil, nil end
	for _, sp in ipairs(self.sprites) do
		if not sp.dead and (not only or sp == only) then
			if sp.kind == "fighter" then
				self:FixPosition(sp)
				local air = self:IsInAir(sp)
				if air then sp:ApplyG(12) end
				sp:SetInAir(air)
				if sp.ignoreFloor then sp.ignoreFloor = sp.ignoreFloor - 1 end
			end
			sp:Render()
			if animate then sp:RenderAnimate() end
		end
	end
	if only then return end
	self:Push()
	if animate then self:CheckHits() end
	for i = #self.sprites, 1, -1 do
		if self.sprites[i].dead then table.remove(self.sprites, i) end
	end
	self:UpdatePhase(animate)
end

function Battle:Push()
	local a, b = self.fighters[1], self.fighters[2]
	if a.isCross or b.isCross then return end
	local ra, rb = a:BodyArea(), b:BodyArea()
	if not ra or not rb then return end
	local o = overlap(ra, rb)
	if not o then return end
	if b.x < a.x then a, b = b, a end
	if (a.vx < 0 and a.vx < b.vx) or (b.vx > 0 and b.vx > a.vx) then return end
	local rate = clamp(b.heavy / a.heavy * 0.5, 0.1, 0.9)
	if o[3] > 2 then
		local pa, pb = 2.5 * rate, 2.5 * (1 - rate)
		if a.touchSide and not b.touchSide then pa, pb = 0, 2.5 elseif b.touchSide and not a.touchSide then pa, pb = 2.5, 0 end
		a:Move(-pa, 0)
		b:Move(pb, 0)
	end
	if a.vx ~= 0 then b:Move(a.vx * (1 - rate), 0); a:Move(-a.vx * rate, 0) end
	if b.vx ~= 0 then a:Move(b.vx * rate, 0); b:Move(-b.vx * (1 - rate), 0) end
end

function Battle:CheckHits()
	local list = self.sprites
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
								local h = hr[1]
								if B.kind == "fighter" then
									if B.state == 21 or B.state == 22 then
										local f = A.kind == "fighter" and A or A.owner
										if f and f.combo then f.combo = f.combo + 1 end
									else
										local f = A.kind == "fighter" and A or A.owner
										if f and f.combo then f.combo = 1 end
									end
									B:BeHit(h, o)
								else
									B:BeHit(h, o, A)
								end
								if A.kind == "fighter" then
									if not BVNFighter.IsBisha(h) then A:AddQi(math.min(h.power * 0.17, 15)) end
								elseif A.OnHit then
									A:OnHit(B.kind == "fighter" and B or nil)
								end
								break
							end
						end
					end
				end
			end
		end
	end
end

function Battle:TimeOver()
	if self.phase ~= "fight" then return end
	self.actionEnable = false
	self.phase, self.phaseT = "ko", 0
	self.timeOver = true
	local a, b = self.fighters[1], self.fighters[2]
	self.winner = a.hp > b.hp and 1 or (b.hp > a.hp and 2 or 0)
	BVNHud.Banner(self, self.winner == 0 and "drawgame" or "timeover", nil, 0)
end

function Battle:UpdatePhase(animate)
	self.phaseT = self.phaseT + 1
	if self.phase == "intro" then
		local ready = true
		for _, f in ipairs(self.fighters) do if f.state == 60 then ready = false end end
		if (ready and self.phaseT > 60) or self.phaseT > 360 then
			for _, f in ipairs(self.fighters) do if f.state == 60 then f:Idle() end end
			self.phase, self.phaseT = "go", 0
			BVNHud.Banner(self, self.round < 5 and "start" or "start_final", self.round < 5 and "start_final" or "go:fight", -50)
		end
	elseif self.phase == "go" then
		local ready = self.banner and BVNHud.BannerAt(self, "fight")
		if (ready or (not self.banner and self.phaseT > 50)) and not self.actionEnable then
			self.phase, self.phaseT = "fight", 0
			self.actionEnable = true
		end
	elseif self.phase == "ko" then
		local w = self.winner and self.winner > 0 and self.fighters[self.winner]
		if w and self.phaseT > 60 and not w.posed and w.state ~= 12 and w.state ~= 13 and w.state ~= 50 and not w.inAir then
			w.posed = true
			for _, f in ipairs(self.fighters) do f.allowLoseHP = false end
			if w:HasLabel("胜利") then w:DoAction("胜利"); w.state = 61 end
		end
		if self.phaseT > 300 and self.teamMode then
			for _, f in ipairs(self.fighters) do f.posed = false end
			self.timeOver = false
			local w = self.winner or 0
			local over = false
			if w == 0 then
				local a, b2 = self:NextMember(1), self:NextMember(2)
				if not a or not b2 then over = true; self.matchWinner = a and 1 or (b2 and 2 or 1) end
			else
				local survivor = self.fighters[w]
				survivor.keepHp = true
				survivor.hp = math.min(survivor.hpMax, survivor.hp + math.max(survivor.hpMax * 0.2 * math.max(0, self.time) / 60, survivor.hpMax * 0.05))
				if not self:NextMember(3 - w) then over = true; self.matchWinner = w end
			end
			if over then
				self.phase, self.phaseT = "over", 0
			else
				self.round = self.round + 1
				self:StartRound()
			end
		elseif self.phaseT > 300 then
			if self.winner and self.winner > 0 then self.wins[self.winner] = self.wins[self.winner] + 1 end
			for _, f in ipairs(self.fighters) do f.posed = false end
			self.timeOver = false
			if self.wins[1] >= 2 or self.wins[2] >= 2 or self.round >= 5 or self.training then
				self.phase, self.phaseT = "over", 0
				self.matchWinner = self.wins[1] >= self.wins[2] and 1 or 2
			else
				self.round = self.round + 1
				self:StartRound()
			end
		end
	end
	if self.training then
		for _, f in ipairs(self.fighters) do
			f.qi = f.qiMax
			if f.side == 2 and f.state == 0 then f.hp = f.hpMax end
		end
	end
end

-- Camera -----------------------------------------------------------------------------------

function Battle:UpdateCamera()
	local a, b = self.fighters[1], self.fighters[2]
	local m = self.map
	local dx = math.abs(a.x - b.x)
	local w = clamp(dx + 260, 440, math.min(680, m.right - m.left))
	local h = w * SH / SW
	local cx = (a.x + b.x) / 2
	local focus = self.bisha and self.bisha.f
	if focus and self.bisha.super then cx, w = focus.x, math.max(460, w * 0.8); h = w * SH / SW end
	cx = clamp(cx, m.left + w / 2, m.right - w / 2)
	if m.right - m.left < w then cx = (m.left + m.right) / 2 end
	local top = math.min(m.bottom - h, math.min(a.y, b.y) - 190)
	local cy = top + h / 2
	local c = self.cam
	local k = 0.12
	c.x = c.x + (cx - c.x) * k
	c.y = c.y + (cy - c.y) * k
	c.w = c.w + (w - c.w) * k
end

-- Drawing ----------------------------------------------------------------------------------

function Battle:Draw()
	local c = self.cam
	local zoom = SW / c.w
	local sx, sy = self.fx:ShakeOffset()
	Camera.SetZoom(zoom)
	Camera.SetPosition((c.x + sx) / 100, (c.y + sy) / 100)
	local m = self.map
	local vw, vh = c.w, c.w * SH / SW
	local L = m.layers
	if L.bg then
		-- The far background follows the camera slowly, scaled to cover the view.
		local s = math.max(vw / L.bg.w, vh / L.bg.h) * 1.15
		local bx = c.x - L.bg.w * s / 2 - (c.x - (m.left + m.right) / 2) * 0.15
		local by = c.y - L.bg.h * s / 2
		Image.DrawEx(L.bg.img, bx / 100, by / 100, 0, s, s, 0, 0, 255, 255, 255, 255, 0)
	end
	if L.map then Image.DrawEx(L.map.img, L.map.x / 100, L.map.y / 100, 0, L.map.sx, L.map.sy, 0, 0, 255, 255, 255, 255, 2) end
	local dark = self.bisha or self.fighters[1].state == 12 or self.fighters[1].state == 13 or self.fighters[2].state == 12 or self.fighters[2].state == 13
	if dark then D.Rect(c.x - vw, c.y - vh, vw * 2, vh * 2, BLACK, self.bisha and 170 or 90, 9) end
	-- Fighters: the attacking one on top.
	local f1, f2 = self.fighters[1], self.fighters[2]
	local first, second = f1, f2
	if f1:IsAttacking() and not f2:IsAttacking() then first, second = f2, f1 end
	if self.bisha and self.bisha.f.kind == "fighter" then
		first, second = (self.bisha.f == f1) and f2 or f1, self.bisha.f
	end
	self:DrawFighter(first, 20)
	self:DrawFighter(second, 40)
	for _, sp in ipairs(self.sprites) do
		if sp.kind ~= "fighter" and not sp.dead and sp.clip then sp:Draw(sp.kind == "assist" and 30 or 60) end
	end
	self.fx:Draw()
	self:DrawFront(L.front, -(c.x - (m.left + m.right) / 2) * 0.1)
	self:DrawFront(L.front_fix, 0)
	self:DrawHud()
end

-- Front layers: a movie clip a fighter overlaps is drawn half transparent (MapLayer.renderOptical).
function Battle:DrawFront(layer, dx)
	if not layer then return end
	if not layer.parts then
		Image.DrawEx(layer.img, (layer.x + dx) / 100, layer.y / 100, 0, layer.sx, layer.sy, 0, 0, 255, 255, 255, 255, 90)
		return
	end
	for _, p in ipairs(layer.parts) do
		local a = 255
		if p.clip then
			local r = {p.x + dx, p.y, p.w * p.sx, p.h * p.sy}
			for _, f in ipairs(self.fighters) do
				local body = f:RawBody()
				if body and BVNBattle.Intersects(r, body) then a = 128 break end
			end
		end
		Image.DrawEx(p.img, (p.x + dx) / 100, p.y / 100, 0, p.sx, p.sy, 0, 0, 255, 255, 255, a, 90)
	end
end

function Battle:DrawFighter(f, order)
	local opt = {order = order}
	if f.shadow and self.tick % 4 < 2 then
		-- Afterimage: the previous positions, darkened.
		f.trail = f.trail or {}
	end
	if f.trail then
		for i, p in ipairs(f.trail) do
			BVNClip.Blit(p.img, p.x, p.y, p.sx, 0, 0, p.sy, p.ox, p.oy, p.wx, p.wy, p.dir, {alpha = 40 * i, tint = {90, 90, 140}}, order - 5)
		end
	end
	if f.steel then opt.tint = {255, 240, 170} end
	if not f.allowBeHit and f.state == 15 and self.tick % 4 < 2 then opt.alpha = 200 end
	local fo = f.formOffset
	local ox, oy = fo[1], fo[2]
	BVNClip.Draw(f.clip, f.x, f.y, f.dir, opt, {fo[3], 0, 0, fo[4], ox, oy})
	-- Afterimage bookkeeping.
	if f.shadow then
		local fr = f:Frame()
		if fr and fr.img and self.tick % 3 == 0 then
			f.trail = f.trail or {}
			table.insert(f.trail, 1, {img = fr.img, x = fr.x, y = fr.y, ox = ox, oy = oy, sx = fo[3], sy = fo[4], wx = f.x, wy = f.y, dir = f.dir})
			if #f.trail > 4 then table.remove(f.trail) end
		end
	else
		f.trail = nil
	end
end

-- HUD ---------------------------------------------------------------------------------------

local function bar(x, y, w, h, frac, col, back, right)
	D.UI(x - 2, y - 2, w + 4, h + 4, BLACK, 220, 10)
	D.UI(x, y, w, h, back, 255, 11)
	local fw = w * clamp(frac, 0, 1)
	D.UI(right and (x + w - fw) or x, y, fw, h, col, 255, 12)
end

function Battle:DrawHud()
	if BVNHud.Available() then
		BVNHud.Draw(self)
		self:DrawCenterText()
		return
	end
	for side = 1, 2 do
		local f = self.fighters[side]
		local right = side == 2
		local faceX = right and (SW - 16 - 102) or 16
		local info = f.info
		if info.urls.face_bar then Image.DrawUIScaled("bvn/face/" .. info.urls.face_bar, faceX + (right and 102 or 0), 12, right and -1 or 1, 1, 255, 255, 255, 255, 13) end
		local bx = right and (SW / 2 + 60) or (16 + 108)
		local bw = SW / 2 - 60 - 124
		f.hpShow = f.hpShow or f.hp
		f.hpShow = f.hpShow > f.hp and math.max(f.hp, f.hpShow - 6) or f.hp
		bar(bx, 20, bw, 20, f.hpShow / f.hpMax, {255, 250, 235}, {80, 16, 16}, right)
		local hfw = bw * clamp(f.hp / f.hpMax, 0, 1)
		D.UI(right and (bx + bw - hfw) or bx, 20, hfw, 20, f.hp > f.hpMax * 0.3 and {255, 200, 30} or {255, 60, 30}, 255, 13)
		bar(bx + (right and bw * 0.4 or 0), 46, bw * 0.6, 7, f.energy / f.energyMax, f.overload and {200, 80, 80} or {120, 230, 120}, {30, 40, 30}, right)
		local name = info.name
		local nw = D.TextWidth(name, 20)
		D.Text(name, right and (bx + bw - nw) or bx, 58, 20, WHITE)
		-- Round wins.
		for i = 1, 2 do
			local wx = right and (bx + 6 + (i - 1) * 18) or (bx + bw - 18 * i)
			D.UI(wx, 62, 12, 12, self.wins[side] >= i and {255, 220, 60} or {50, 50, 60}, 255, 13)
		end
		-- Qi (3 bars) and the assist meter.
		local qx = right and (SW - 16 - 300) or 16
		local bars = math.floor(f.qi / 100)
		local part = (f.qi % 100) / 100
		D.UI(qx - 2, SH - 34, 304, 18, BLACK, 210, 10)
		for i = 0, 2 do
			local slot = right and (2 - i) or i
			local fill = i < bars and 1 or (i == bars and part or 0)
			local w = 96 * fill
			local sx = qx + slot * 100 + 2
			D.UI(right and (sx + 96 - w) or sx, SH - 32, w, 14, i < bars and {80, 190, 255} or {40, 100, 160}, 255, 11)
		end
		local qt = tostring(bars)
		D.TextC(qt, right and (qx - 26) or (qx + 326), SH - 46, 36, {120, 210, 255})
		if f.assist and f.assistInfo then
			local ax = right and (SW - 16 - 300 - 70) or (16 + 300 + 50)
			Image.DrawUIScaled("bvn/face/" .. f.assistInfo.urls.face, right and ax - 50 or ax, SH - 86, 0.8, 0.8, 255, 255, 255, f.fzqi >= 100 and 255 or 120, 13)
			bar(right and ax - 50 or ax, SH - 44, 40, 5, f.fzqi / 100, {255, 160, 60}, {50, 30, 20}, right)
		end
		if f.combo >= 2 then
			D.TextC(f.combo .. " HIT", right and (SW - 160) or 160, 170, 40, {255, 230, 80})
		end
	end
	-- Timer.
	D.UI(SW / 2 - 50, 10, 100, 62, BLACK, 220, 10)
	D.TextC(self.time < 0 and "∞" or tostring(math.max(0, self.time)), SW / 2, 14, 46, WHITE)
	self:DrawCenterText()
end

function Battle:DrawCenterText()
	if self.banner or BVNHud.Available() then return end
	if self.phase == "intro" or self.phase == "go" then
		if self.phase == "go" then D.TextC("FIGHT!", SW / 2, 260, 110, {255, 80, 40}) end
		D.TextC("ROUND " .. self.round, SW / 2, 180, 50, WHITE, self.phase == "intro" and 255 or 120)
	elseif self.phase == "ko" then
		D.TextC(self.timeOver and "TIME UP" or "K.O.", SW / 2, 250, 120, {255, 50, 40})
	end
	if self.bisha and self.bisha.img then
		local b = self.bisha
		local slide = math.min(1, b.t / 8)
		local onLeft = b.f.side == 1
		local w = 480
		local x = onLeft and (-w + slide * (w + 40)) or (SW + w - slide * (w + 40) - w)
		D.UI(0, 250, SW, 150, b.f.char.comic_type == 1 and {200, 100, 20} or {30, 40, 90}, 140 * slide, 20)
		Image.DrawUIScaled(b.img, x, 230, 2, 2, 255, 255, 255, 255, 21)
	end
end
