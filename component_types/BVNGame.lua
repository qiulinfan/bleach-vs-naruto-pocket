-- BleachVsNaruto: title, character select, best-of-three fights and the result.
-- One component runs the whole game; fighters, projectiles and effects are plain
-- tables. Everything draws in screen pixels (see BVNDraw).
local D = BVNDraw
local GROUND = 610
local LEFT, RIGHT = 50, 1230
local GRAVITY = 0.9
local ROUND_TICKS = 99 * 60
local WHITE, BLACK = {255, 255, 255}, {0, 0, 0}
local MENU = {
	{text = "单人对战电脑", mode = "cpu"},
	{text = "双人对战", mode = "pvp"},
	{text = "电脑对战观战", mode = "watch"},
}

local function sign(v) return v > 0 and 1 or (v < 0 and -1 or 0) end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function grounded(f) return f.y >= GROUND - 0.01 end

-- Deterministic random numbers (a 31-bit LCG) so replays match.
local function rand(g)
	g.seed = (g.seed * 1103515245 + 12345) % 2147483648
	return g.seed / 2147483648
end

local channel = 0
local function play(clip)
	channel = channel % 8 + 1
	if Audio.HasClip(clip) then Audio.Play(channel, clip, false) end
end

-- Inputs ---------------------------------------------------------------------

local function humanInput(side)
	local p = "p" .. side .. "_"
	return {
		move = Input.GetActionValue(p .. "move"),
		up = Input.GetActionDown(p .. "up"),
		down = Input.GetAction(p .. "down"),
		light = Input.GetActionDown(p .. "light"),
		heavy = Input.GetActionDown(p .. "heavy"),
		special = Input.GetActionDown(p .. "special"),
		ult = Input.GetActionDown(p .. "ult"),
		dash = Input.GetActionDown(p .. "dash"),
	}
end

local function incoming(g, f)
	for _, pr in ipairs(g.proj) do
		if pr.owner ~= f then
			if pr.delay > 0 and math.abs(pr.x - f.x) < pr.w / 2 + 40 then return true end
			if pr.vx ~= 0 and sign(f.x - pr.x) == sign(pr.vx) and math.abs(pr.x - f.x) < 260 then return true end
		end
	end
	return false
end

local function cpuInput(g, f, o)
	local a = f.ai
	local inp = {move = 0}
	local dist = math.abs(o.x - f.x)
	local toward = sign(o.x - f.x)
	if a.block > 0 then
		a.block = a.block - 1
		inp.down = true
		return inp
	end
	-- React to attacks and projectiles by guarding or jumping.
	if f.state == "free" and grounded(f) and a.react <= 0 then
		local threat = (o.state == "move" and dist < o.ch.reach + 70) or incoming(g, f)
		if threat then
			a.react = 14
			local r = rand(g)
			if r < 0.55 then a.block = 20; inp.down = true; return inp end
			if r < 0.7 then inp.up = true; inp.move = -toward; return inp end
		end
	end
	a.react = a.react - 1
	-- Continue combos.
	if f.state == "move" and f.move.basic then
		local m = f.move
		if m.hit and (m.name == "light3" or m.name == "heavy") and f.energy >= 30 and rand(g) < 0.08 then inp.special = true end
		if m.hit and f.energy >= 100 and rand(g) < 0.03 then inp.ult = true end
		if m.def.next and rand(g) < 0.5 then inp.light = true end
		return inp
	end
	a.think = a.think - 1
	if a.think <= 0 then
		a.think = 6 + math.floor(rand(g) * 12)
		local r = rand(g)
		if f.energy >= 100 and r < 0.12 and dist < 700 then a.plan = "ult"
		elseif dist > 330 then
			if r < 0.3 and f.energy >= 30 then a.plan = "special"
			elseif r < 0.45 then a.plan = "dash"
			else a.plan = "approach" end
		elseif dist < f.ch.reach + 15 then
			if r < 0.55 then a.plan = "light"
			elseif r < 0.75 then a.plan = "heavy"
			elseif r < 0.85 then a.plan = "jumpin"
			elseif r < 0.92 and f.energy >= 30 then a.plan = "special"
			else a.plan = "retreat" end
		else
			if r < 0.15 then a.plan = "jumpin" elseif r < 0.25 then a.plan = "wait" else a.plan = "approach" end
		end
	end
	local plan = a.plan
	if plan == "approach" then inp.move = toward
	elseif plan == "retreat" then inp.move = -toward
	elseif plan == "dash" then inp.dash = true; a.plan = "approach"
	elseif plan == "light" then inp.light = true; a.plan = "wait"
	elseif plan == "heavy" then inp.heavy = true; a.plan = "wait"
	elseif plan == "special" then inp.special = true; a.plan = "wait"
	elseif plan == "ult" then inp.ult = true; a.plan = "wait"
	elseif plan == "jumpin" then
		if grounded(f) then inp.up = true; inp.move = toward
		else
			inp.move = toward
			if dist < f.ch.reach + 30 and f.y < GROUND - 40 then inp.light = true; a.plan = "wait" end
		end
	end
	return inp
end

-- Fighters ---------------------------------------------------------------------

local function newFighter(index, side, cpu)
	local ch = BVNData.CHARACTERS[index]
	return {
		ch = ch, index = index, side = side, cpu = cpu,
		x = side == 1 and 420 or 860, y = GROUND, vx = 0, vy = 0, face = side == 1 and 1 or -1,
		hp = 100, trail = 100, energy = 100,
		state = "free", t = 0, move = nil, knock = false, invuln = 0, flash = 0,
		buf = {light = 0, heavy = 0, special = 0, ult = 0, dash = 0},
		ai = {think = 0, plan = "approach", block = 0, react = 0},
		ghosts = {}, combo = 0, combo_show = 0, air_used = false,
	}
end

local function resetFighter(f)
	f.x = f.side == 1 and 420 or 860
	f.y, f.vx, f.vy = GROUND, 0, 0
	f.face = f.side == 1 and 1 or -1
	f.hp, f.trail = 100, 100
	f.state, f.t, f.move, f.knock, f.invuln, f.flash = "free", 0, nil, false, 0, 0
	f.ghosts, f.combo, f.combo_show = {}, 0, 0
end

local function hurtbox(f)
	local s = f.ch.scale
	return f.x - 24, f.y - 140 * s, f.x + 24, f.y
end

local function overlap(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1)
	return ax0 < bx1 and bx0 < ax1 and ay0 < by1 and by0 < ay1
end

local function spark(g, x, y, c, n, speed)
	for i = 1, n do
		local ang = rand(g) * math.pi * 2
		local v = speed * (0.4 + rand(g))
		table.insert(g.fx, {x = x, y = y, vx = math.cos(ang) * v, vy = math.sin(ang) * v, life = 14 + rand(g) * 10, max = 24, c = c, size = 4 + rand(g) * 5})
	end
	table.insert(g.fx, {ring = true, x = x, y = y, life = 10, max = 10, c = c, size = 18})
end

-- Applies a hit from `att` (a fighter) at source x `sx`. Returns whether it connected.
local function applyHit(g, att, def, h, sx)
	if def.invuln > 0 or def.state == "down" or def.state == "ko" or def.state == "getup" then return false end
	local dirx = sign(def.x - sx)
	if dirx == 0 then dirx = att.face end
	local hx, hy = (def.x + sx) / 2, def.y - 85 * def.ch.scale
	local blocking = def.state == "free" and grounded(def) and def.guard and def.face == -dirx and not h.unblockable
	if def.state == "blockstun" then blocking = true end
	if blocking then
		def.hp = math.max(1, def.hp - h.dmg * 0.15)
		def.state, def.t, def.stun = "blockstun", 0, 10 + math.floor(h.hitstun * 0.35)
		def.vx = dirx * (h.kb * 0.7 + 2)
		def.energy = math.min(300, def.energy + 3)
		g.hitstop = 3
		spark(g, def.x - dirx * 20, hy, {120, 200, 255}, 6, 4)
		play("block")
		return true
	end
	local chained = def.state == "hurt" or def.state == "frozen"
	att.combo = chained and att.combo + 1 or 1
	att.combo_show = 70
	local scale = math.max(0.45, 1 - 0.07 * (att.combo - 1))
	def.hp = math.max(0, def.hp - h.dmg * att.ch.power * scale)
	def.flash = 1
	if h.freeze and def.hp > 0 then
		def.state, def.t, def.stun, def.vx, def.vy = "frozen", 0, h.freeze, 0, 0
		def.y = math.min(def.y, GROUND)
		play("ice")
	else
		def.state, def.t, def.stun = "hurt", 0, h.hitstun
		def.vx = dirx * h.kb
		def.knock = h.knockdown or def.hp <= 0
		if h.launch or not grounded(def) or def.hp <= 0 then
			def.vy = h.launch or -6
			if def.hp <= 0 then def.vy = math.min(def.vy, -10); def.vx = dirx * 8 end
			def.y = def.y - 1
			def.knock = true
		end
	end
	def.move = nil
	att.energy = math.min(300, att.energy + 7)
	def.energy = math.min(300, def.energy + 5)
	g.hitstop = h.hitstop or 5
	g.shake = (h.hitstop or 5) * 1.2
	spark(g, hx, hy, h.color or {255, 230, 140}, 10, 6)
	play(h.sound or "hit")
	return true
end

local function startMove(g, f, name)
	local B = BVNData.BASIC[name]
	f.state, f.t = "move", 0
	f.move = {name = name, basic = true, def = B, t = 0, hit = false}
	f.buf.light, f.buf.heavy = 0, 0
	play(f.ch.weapon and "slash" or "whoosh")
end

local function startSpecial(g, f, ult)
	local info = ult and f.ch.ult or f.ch.special
	local def = BVNData.SPECIALS[info.kind]
	if f.energy < def.cost then return false end
	f.energy = f.energy - def.cost
	f.state, f.t = "move", 0
	f.move = {name = info.kind, basic = false, def = def, t = 0, hit = false, ult = ult}
	f.buf.special, f.buf.ult = 0, 0
	f.vx = 0
	if ult then
		g.cine = {f = f, t = 0, dur = 54, name = info.name}
		play("ult")
	else
		g.callout = {f = f, t = 0, name = info.name}
	end
	return true
end

local function opponent(g, f) return g.F[3 - f.side] end

BVNGame = {
	-- Scalar properties for scenarios and the inspector.
	phase_name = "title",
	match_winner = 0,
	round_no = 1,
	p1_hp = 100,
	p2_hp = 100,

	OnStart = function(self)
		self:Init()
		Camera.SetZoom(1)
		Camera.SetPosition(6.4, 3.6)
	end,

	-- Also called by agent commands that may arrive before OnStart.
	Init = function(self)
		if self.inited then return end
		self.inited = true
		self.seed = 20261017
		self.frame = 0
		self.menu = 1
		self.stage = 1
		self.proj, self.fx = {}, {}
		self.prev_axis = {0, 0}
		self:EnterTitle()
	end,

	EnterTitle = function(self)
		self.phase = "title"
		self.phase_t = 0
		self.match_winner = 0
	end,

	EnterSelect = function(self)
		self.phase = "select"
		self.phase_t = 0
		self.cursor = self.cursor or {1, 3}
		self.ready = {false, false}
	end,

	StartMatch = function(self, mode, p1, p2, stage)
		self.mode = mode
		self.F = {newFighter(p1, 1, mode == "watch"), newFighter(p2, 2, mode ~= "pvp")}
		self.stage = stage or self.stage
		self.wins = {0, 0}
		self.round_no = 1
		self.match_winner = 0
		self.phase = "fight"
		self:StartRound()
	end,

	StartRound = function(self)
		for _, f in ipairs(self.F) do resetFighter(f) end
		self.proj, self.fx = {}, {}
		self.rs, self.rs_t = "intro", 0
		self.time = ROUND_TICKS
		self.hitstop, self.shake, self.flash = 0, 0, 0
		self.cine, self.callout = nil, nil
		self.round_winner = 0
	end,

	OnUpdate = function(self)
		self.frame = self.frame + 1
		self.phase_t = (self.phase_t or 0) + 1
		if self.phase == "title" then self:UpdateTitle()
		elseif self.phase == "select" then self:UpdateSelect()
		elseif self.phase == "fight" then self:UpdateFight()
		elseif self.phase == "result" then self:UpdateResult() end
		self.phase_name = self.phase
		if self.F then
			self.p1_hp, self.p2_hp = self.F[1].hp, self.F[2].hp
		end
		self:Render()
	end,

	-- Edge-detected axis taps for menus: -1, 0 or 1.
	Tap = function(self, side)
		local v = Input.GetActionValue("p" .. side .. "_move")
		local prev = self.prev_axis[side]
		self.prev_axis[side] = v
		if v > 0.5 and prev <= 0.5 then return 1 end
		if v < -0.5 and prev >= -0.5 then return -1 end
		return 0
	end,

	UpdateTitle = function(self)
		local dy = 0
		if Input.GetActionDown("p1_up") or Input.GetActionDown("p2_up") then dy = -1 end
		if Input.GetActionDown("p1_down") or Input.GetActionDown("p2_down") then dy = 1 end
		if dy ~= 0 then
			self.menu = (self.menu - 1 + dy) % #MENU + 1
			play("select")
		end
		if self.phase_t > 10 and (Input.GetActionDown("confirm") or Input.GetActionDown("p1_light")) then
			self.mode = MENU[self.menu].mode
			play("confirm")
			self:EnterSelect()
		end
	end,

	UpdateSelect = function(self)
		local n = #BVNData.CHARACTERS
		local twoHumans = self.mode == "pvp"
		-- Without a second human, player 1 picks both sides in turn.
		local active = {}
		if twoHumans then active = {{1, 1}, {2, 2}}
		elseif not self.ready[1] then active = {{1, 1}}
		else active = {{2, 1}} end
		for _, pair in ipairs(active) do
			local slot, side = pair[1], pair[2]
			if not self.ready[slot] then
				local d = self:Tap(side)
				if d ~= 0 then
					self.cursor[slot] = (self.cursor[slot] - 1 + d) % n + 1
					play("select")
				end
				local ok = Input.GetActionDown("p" .. side .. "_light") or (side == 1 and Input.GetActionDown("confirm"))
				if ok and self.phase_t > 8 then
					self.ready[slot] = true
					self.ready_t = 0
					play("confirm")
					return
				end
			end
		end
		local back = Input.GetActionDown("back") or Input.GetActionDown("p1_heavy")
		if back then
			if self.ready[2] and not twoHumans then self.ready[2] = false
			elseif self.ready[1] then self.ready[1] = false
			else self:EnterTitle() end
			play("select")
			return
		end
		if self.ready[1] and self.ready[2] then
			self.ready_t = self.ready_t + 1
			if self.ready_t > 40 then
				self.stage = self.stage % #BVNData.STAGES + 1
				self:StartMatch(self.mode, self.cursor[1], self.cursor[2])
			end
		end
	end,

	UpdateResult = function(self)
		for _, f in ipairs(self.F) do self:StepPhysics(f) end
		self:StepFx()
		local auto = self.mode == "watch" and self.phase_t > 360
		if self.phase_t > 60 and (Input.GetActionDown("confirm") or Input.GetActionDown("p1_light") or auto) then
			play("confirm")
			self:EnterSelect()
		end
	end,

	UpdateFight = function(self)
		self.rs_t = self.rs_t + 1
		local F = self.F
		if self.cine then
			self.cine.t = self.cine.t + 1
			if self.cine.t >= self.cine.dur then self.cine = nil end
			return
		end
		if self.hitstop > 0 then
			self.hitstop = self.hitstop - 1
			return
		end
		self.shake = math.max(0, self.shake - 1)
		self.flash = math.max(0, self.flash - 12)
		if self.rs == "intro" then
			for _, f in ipairs(F) do self:StepPhysics(f) end
			if self.rs_t >= 100 then self.rs, self.rs_t = "play", 0 end
			return
		end
		if self.rs == "ko" and self.rs_t < 50 and self.rs_t % 2 == 1 then return end
		local playing = self.rs == "play"
		for _, f in ipairs(F) do
			local inp = {move = 0}
			if playing then
				if f.cpu then inp = cpuInput(self, f, opponent(self, f)) else inp = humanInput(f.side) end
			end
			self:StepFighter(f, inp)
		end
		self:StepProjectiles()
		self:StepFx()
		self:Separate()
		for _, f in ipairs(F) do
			f.trail = f.trail > f.hp and math.max(f.hp, f.trail - 0.35) or f.hp
			f.combo_show = math.max(0, f.combo_show - 1)
		end
		if self.callout then
			self.callout.t = self.callout.t + 1
			if self.callout.t > 60 then self.callout = nil end
		end
		if playing then
			self.time = self.time - 1
			local dead1, dead2 = F[1].hp <= 0, F[2].hp <= 0
			if dead1 or dead2 or self.time <= 0 then
				if dead1 and not dead2 then self.round_winner = 2
				elseif dead2 and not dead1 then self.round_winner = 1
				elseif not dead1 and not dead2 then
					self.round_winner = F[1].hp > F[2].hp and 1 or (F[2].hp > F[1].hp and 2 or 0)
				end
				self.time_over = not dead1 and not dead2
				self.rs, self.rs_t = "ko", 0
				play("ko")
			end
		elseif self.rs == "ko" and self.rs_t > 170 then
			local w = self.round_winner
			if w > 0 then
				self.wins[w] = self.wins[w] + 1
				F[w].state = "win"
			end
			if (w > 0 and self.wins[w] >= 2) or self.round_no >= 5 then
				self.match_winner = w > 0 and w or (self.wins[1] >= self.wins[2] and 1 or 2)
				self.phase, self.phase_t = "result", 0
				local champion = F[self.match_winner]
				champion.state, champion.move = "win", nil
				return
			end
			self.round_no = self.round_no + 1
			self:StartRound()
		end
	end,

	StepFighter = function(self, f, inp)
		local o = opponent(self, f)
		for k, v in pairs(f.buf) do f.buf[k] = math.max(0, v - 1) end
		for _, k in ipairs({"light", "heavy", "special", "ult", "dash"}) do
			if inp[k] then f.buf[k] = 8 end
		end
		f.guard = inp.down and true or false
		f.invuln = math.max(0, f.invuln - 1)
		f.flash = math.max(0, f.flash - 0.15)
		f.t = f.t + 1
		local st = f.state
		if st == "free" then
			if grounded(f) then
				f.air_used = false
				f.face = sign(o.x - f.x) ~= 0 and sign(o.x - f.x) or f.face
				if f.buf.ult > 0 and f.energy >= 100 then startSpecial(self, f, true)
				elseif f.buf.special > 0 and f.energy >= 30 then startSpecial(self, f, false)
				elseif f.buf.heavy > 0 then startMove(self, f, "heavy")
				elseif f.buf.light > 0 then startMove(self, f, "light1")
				elseif f.buf.dash > 0 and not f.guard then
					f.state, f.t = "dash", 0
					f.dash_dir = inp.move ~= 0 and sign(inp.move) or f.face
					f.buf.dash = 0
					play("whoosh")
				elseif f.guard then f.vx = 0
				elseif inp.up then
					f.vy = -17
					f.vx = inp.move * f.ch.speed * 1.1
					play("whoosh")
				else
					f.vx = inp.move * f.ch.speed * (sign(inp.move) == f.face and 1 or 0.8)
				end
			else
				f.vx = f.vx + (inp.move * f.ch.speed - f.vx) * 0.06
				if not f.air_used and (f.buf.light > 0 or f.buf.heavy > 0) then
					f.air_used = true
					startMove(self, f, "air")
				elseif f.buf.special > 0 and f.energy >= 30 and not f.air_used then
					f.air_used = true
					startSpecial(self, f, false)
				end
			end
		elseif st == "move" then
			self:StepMove(f, o)
		elseif st == "dash" then
			f.vx = f.dash_dir * 14
			if f.t % 3 == 0 then
				table.insert(f.ghosts, {pose = self:PoseFor(f), x = f.x, y = f.y, face = f.face, life = 12})
			end
			if f.t >= 12 then f.state, f.t, f.vx = "free", 0, f.dash_dir * 3 end
		elseif st == "hurt" then
			if grounded(f) then
				f.vx = f.vx * 0.85
				if f.knock then f.state, f.t = "down", 0
				elseif f.t >= f.stun then f.state, f.t = "free", 0 end
			end
		elseif st == "blockstun" or st == "frozen" then
			f.vx = f.vx * 0.8
			if f.t >= f.stun then f.state, f.t = "free", 0 end
		elseif st == "down" then
			f.vx = f.vx * 0.8
			if f.t >= 40 and f.hp > 0 then f.state, f.t = "getup", 0
			elseif f.hp <= 0 then f.state = "ko" end
		elseif st == "getup" then
			f.invuln = 2
			if f.t >= 16 then f.state, f.t, f.invuln = "free", 0, 12 end
		elseif st == "ko" or st == "win" then
			f.vx = f.vx * 0.8
		end
		self:StepPhysics(f)
	end,

	StepPhysics = function(self, f)
		if not grounded(f) or f.vy < 0 then
			f.vy = f.vy + GRAVITY
			f.y = f.y + f.vy
			if f.y >= GROUND then
				f.y, f.vy = GROUND, 0
				if f.state == "move" and f.move and f.move.name == "air" then f.state, f.move = "free", nil end
				if f.state == "hurt" and f.knock then f.state, f.t = "down", 0; self.shake = math.max(self.shake, 4); play("land") end
			end
		end
		f.x = clamp(f.x + f.vx, LEFT, RIGHT)
		for i = #f.ghosts, 1, -1 do
			local gh = f.ghosts[i]
			gh.life = gh.life - 1
			if gh.life <= 0 then table.remove(f.ghosts, i) end
		end
	end,

	StepMove = function(self, f, o)
		local m = f.move
		m.t = m.t + 1
		local d = m.def
		if m.basic then
			local reach = (m.name == "air" and 0.85 or 1) * f.ch.reach
			if m.t == d.startup + 1 and d.lunge and grounded(f) then f.vx = f.face * d.lunge end
			if grounded(f) then f.vx = f.vx * 0.8 end
			if m.t > d.startup and m.t <= d.startup + d.active and not m.hit then
				local x0, x1 = f.x, f.x + f.face * reach
				local s = f.ch.scale
				local y0, y1 = f.y - 130 * s, f.y - 25
				if m.name == "air" then y0, y1 = f.y - 110 * s, f.y + 20 end
				local bx0, by0, bx1, by1 = hurtbox(o)
				if overlap(math.min(x0, x1), y0, math.max(x0, x1), y1, bx0, by0, bx1, by1) then
					local h = {dmg = d.dmg, hitstun = d.hitstun, kb = d.kb, launch = d.launch, knockdown = d.knockdown,
						hitstop = d.hitstop, sound = m.name == "heavy" and "heavy" or "hit"}
					if applyHit(self, f, o, h, f.x) then m.hit = true end
				end
			end
			-- Chains and cancels.
			if m.t > d.startup + d.active then
				if m.hit and f.buf.ult > 0 and f.energy >= 100 and grounded(f) then startSpecial(self, f, true); return end
				if m.hit and f.buf.special > 0 and f.energy >= 30 and grounded(f) then startSpecial(self, f, false); return end
				if d.next and f.buf.light > 0 then startMove(self, f, d.next); return end
				if m.name ~= "heavy" and m.name ~= "air" and f.buf.heavy > 0 and m.hit then startMove(self, f, "heavy"); return end
			end
			if m.t >= d.startup + d.active + d.recovery then
				if m.name ~= "air" or grounded(f) then f.state, f.move = "free", nil
				else f.move.t = d.startup + d.active + d.recovery - 1 end
			end
			return
		end
		-- Specials.
		if grounded(f) then f.vx = f.vx * 0.7 end
		if d.spawn then
			for i, at in ipairs(d.spawn) do
				if m.t == at then self:Spawn(f, o, m.name, i) end
			end
		end
		if d.dash and m.t >= d.dash[1] and m.t <= d.dash[2] then
			f.vx = f.face * d.dash[3]
			if not m.hit then
				local bx0, by0, bx1, by1 = hurtbox(o)
				local x0, x1 = f.x, f.x + f.face * 70
				if overlap(math.min(x0, x1), f.y - 120, math.max(x0, x1), f.y - 30, bx0, by0, bx1, by1) then
					if applyHit(self, f, o, {dmg = 12, hitstun = 30, kb = 14, launch = -9, knockdown = true, hitstop = 10,
						color = {140, 200, 255}, sound = "beam"}, f.x) then
						m.hit = true
						f.vx = 0
					end
				end
			end
			if m.hit then f.vx = 0 end
		end
		if m.t >= d.frames then f.state, f.move = "free", nil end
	end,

	Spawn = function(self, f, o, kind, i)
		local fc = f.face
		local p = {owner = f, kind = kind, x = f.x + fc * 60, y = f.y - 80, vx = 0, w = 50, h = 110,
			dmg = 10, hits = 1, interval = 6, cool = 0, life = 80, delay = 0, hitstun = 22, kb = 8, t = 0, face = fc, hitstop = 6}
		if kind == "getsuga" then
			p.vx, p.color, p.sound = fc * 13, {150, 220, 255}, "beam"
			play("beam")
		elseif kind == "getsuga_black" then
			p.y, p.w, p.h, p.vx = f.y - 110, 90, 230, fc * 15
			p.dmg, p.hits, p.interval, p.knockdown, p.launch, p.hitstun, p.kb = 11, 3, 5, true, -9, 30, 5
			p.color, p.sound, p.hitstop = {230, 40, 50}, "heavy", 7
			self.shake, self.flash = 10, 120
			play("beam")
		elseif kind == "hakuren" then
			p.x, p.y, p.w, p.h, p.vx, p.life = f.x + fc * 70, GROUND - 50, 90, 100, fc * 10, 70
			p.dmg, p.freeze, p.color = 8, 45, {200, 240, 255}
			play("ice")
		elseif kind == "tsukishiro" then
			p.x, p.y, p.w, p.h, p.delay, p.life = o.x, GROUND - 140, 130, 280, 26, 22
			p.dmg, p.freeze, p.hitstop, p.color = 24, 80, 10, {220, 245, 255}
		elseif kind == "clones" then
			p.x, p.y, p.w, p.h, p.vx, p.life = f.x - fc * 140, GROUND - 70, 50, 140, fc * 17, 90
			p.dmg, p.hitstun, p.kb, p.sound = 6, 34, 3, "hit"
			p.ghost_t = i
			if i == 5 then
				p.dmg, p.knockdown, p.launch, p.kb, p.hitstop, p.color, p.sound = 13, true, -13, 12, 10, {140, 200, 255}, "beam"
				p.rasengan = true
			end
			play("whoosh")
		elseif kind == "fireball" then
			p.x, p.y, p.w, p.h, p.vx, p.life = f.x + fc * 80, f.y - 95, 100, 100, fc * 7.5, 150
			p.dmg, p.hits, p.interval, p.knockdown, p.launch, p.kb, p.color, p.sound = 6, 2, 8, true, -8, 10, {255, 160, 40}, "fire"
			play("fire")
		elseif kind == "kirin" then
			p.x, p.y, p.w, p.h, p.delay, p.life = o.x, GROUND / 2, 110, GROUND, 34, 16
			p.dmg, p.knockdown, p.launch, p.kb, p.hitstop, p.color, p.sound = 30, true, -14, 4, 12, {180, 190, 255}, "thunder"
		end
		table.insert(self.proj, p)
	end,

	StepProjectiles = function(self)
		for i = #self.proj, 1, -1 do
			local p = self.proj[i]
			p.t = p.t + 1
			local keep = true
			if p.delay > 0 then
				p.delay = p.delay - 1
				if p.delay == 0 then
					if p.kind == "kirin" then self.flash, self.shake = 255, 16; play("thunder")
					elseif p.kind == "tsukishiro" then self.flash, self.shake = 160, 8; play("ice") end
				end
			else
				p.x = p.x + p.vx
				p.life = p.life - 1
				p.cool = p.cool - 1
				local o = opponent(self, p.owner)
				local bx0, by0, bx1, by1 = hurtbox(o)
				if p.cool <= 0 and overlap(p.x - p.w / 2, p.y - p.h / 2, p.x + p.w / 2, p.y + p.h / 2, bx0, by0, bx1, by1) then
					local src = p.vx ~= 0 and p.x - sign(p.vx) * 100 or p.owner.x
					if applyHit(self, p.owner, o, p, src) then
						p.hits = p.hits - 1
						p.cool = p.interval
						if o.state == "blockstun" then p.hits = 0 end
						if p.hits <= 0 then keep = false end
						if p.kind == "clones" then self:Smoke(p.x, p.y) end
					end
				end
				if p.life <= 0 or p.x < -200 or p.x > 1480 then
					keep = false
					if p.kind == "clones" then self:Smoke(p.x, p.y) end
				end
			end
			if not keep then table.remove(self.proj, i) end
		end
	end,

	Smoke = function(self, x, y)
		for _ = 1, 8 do
			table.insert(self.fx, {x = x + (rand(self) - 0.5) * 50, y = y + (rand(self) - 0.5) * 90, vx = (rand(self) - 0.5) * 2,
				vy = -rand(self) * 2, life = 24, max = 24, c = {235, 235, 235}, size = 22 + rand(self) * 18, puff = true})
		end
	end,

	StepFx = function(self)
		for i = #self.fx, 1, -1 do
			local e = self.fx[i]
			e.life = e.life - 1
			if e.vx then
				e.x, e.y = e.x + e.vx, e.y + e.vy
				e.vy = e.vy + (e.puff and -0.02 or 0.25)
			end
			if e.life <= 0 then table.remove(self.fx, i) end
		end
	end,

	Separate = function(self)
		local a, b = self.F[1], self.F[2]
		local dx = b.x - a.x
		if math.abs(dx) < 46 and math.abs(a.y - b.y) < 110 and a.state ~= "down" and b.state ~= "down" then
			local push = (46 - math.abs(dx)) / 2
			local s = dx >= 0 and 1 or -1
			if dx == 0 then s = a.face end
			a.x = clamp(a.x - s * push, LEFT, RIGHT)
			b.x = clamp(b.x + s * push, LEFT, RIGHT)
		end
	end,

	-- Poses -------------------------------------------------------------------

	PoseFor = function(self, f)
		local S = BVNData.POSES[f.ch.style]
		local L = BVNRig.LerpPose
		local st = f.state
		local idle = L(S.idle, S.idle, 0)
		idle.lean = idle.lean + math.sin(self.frame * 0.08 + f.side) * 2
		idle.ua1 = idle.ua1 + math.sin(self.frame * 0.08 + f.side) * 3
		if st == "free" then
			if not grounded(f) then return f.vy < 0 and S.jump or S.fall end
			if f.guard then return S.block end
			if math.abs(f.vx) > 0.5 then
				local ph = self.frame * 0.28 * sign(f.vx) * f.face
				local s1 = math.sin(ph)
				local p = L(S.idle, S.idle, 0)
				p.th1, p.sh1 = 26 * s1, 26 * s1 - 16 - 10 * math.max(0, -s1)
				p.th2, p.sh2 = -26 * s1, -26 * s1 - 16 - 10 * math.max(0, s1)
				p.lean = p.lean + 4
				return p
			end
			return idle
		elseif st == "move" then
			local m = f.move
			local d = m.def
			if m.basic then
				local A = BVNData.ATTACKS[f.ch.style][m.name]
				local base = m.name == "air" and S.jump or idle
				if m.t <= d.startup then return L(base, A[1], m.t / d.startup) end
				if m.t <= d.startup + d.active then return L(A[1], A[2], math.min(1, (m.t - d.startup) / 2)) end
				local r = (m.t - d.startup - d.active) / d.recovery
				return L(A[2], base, math.max(0, r * 1.6 - 0.6))
			end
			local target = S[d.pose]
			if d.dash and m.t >= d.dash[1] and m.t <= d.dash[2] then target = S.cast end
			if m.t < 6 then return L(idle, target, m.t / 6) end
			if m.t > d.frames - 8 then return L(target, idle, (m.t - (d.frames - 8)) / 8) end
			return target
		elseif st == "dash" then return S.dash
		elseif st == "hurt" then return grounded(f) and S.hurt or L(S.hurt, S.down, 0.4)
		elseif st == "frozen" then return S.hurt
		elseif st == "blockstun" then return S.block
		elseif st == "down" or st == "ko" then return S.down
		elseif st == "getup" then return L(S.down, idle, f.t / 16)
		elseif st == "win" then return S.win
		end
		return idle
	end,

	-- Agent interface ------------------------------------------------------------

	OnAgentObserve = function(self)
		local function fighter(f)
			if not f then return nil end
			return {character = f.ch.id, hp = f.hp, energy = f.energy, x = f.x, y = f.y, state = f.state,
				facing = f.face, move = f.move and f.move.name or nil, cpu = f.cpu}
		end
		return {
			phase = self.phase, mode = self.mode, round = self.round_no, round_state = self.rs,
			wins = self.wins, time = self.time and math.ceil(self.time / 60) or nil,
			match_winner = self.match_winner,
			p1 = self.F and fighter(self.F[1]) or nil, p2 = self.F and fighter(self.F[2]) or nil,
			projectiles = self.proj and #self.proj or 0,
		}
	end,

	OnAgentCommand = function(self, name, args)
		self:Init()
		if name == "start_match" then
			local ids = {}
			for i, ch in ipairs(BVNData.CHARACTERS) do ids[ch.id] = i end
			local p1 = ids[args.p1 or "ichigo"] or error("unknown character " .. tostring(args.p1))
			local p2 = ids[args.p2 or "naruto"] or error("unknown character " .. tostring(args.p2))
			self:StartMatch(args.mode or "cpu", p1, p2, args.stage)
			if args.skip_intro then self.rs, self.rs_t = "play", 0 end
			return {phase = self.phase}
		elseif name == "set_energy" and self.F then
			self.F[args.side or 1].energy = args.energy or 300
			return {energy = self.F[args.side or 1].energy}
		elseif name == "set_hp" and self.F then
			self.F[args.side or 1].hp = args.hp or 100
			return {hp = self.F[args.side or 1].hp}
		end
		return nil
	end,

	-- Rendering ------------------------------------------------------------------

	Render = function(self)
		local sx, sy = 0, 0
		if self.shake and self.shake > 0 then
			sx = math.sin(self.frame * 2.1) * self.shake
			sy = math.cos(self.frame * 1.7) * self.shake * 0.6
		end
		Camera.SetPosition(6.4 + sx / 100, 3.6 + sy / 100)
		if self.phase == "title" then self:RenderTitle()
		elseif self.phase == "select" then self:RenderSelect()
		else self:RenderFight() end
	end,

	RenderTitle = function(self)
		BVNStage.Draw(1, self.frame)
		local t = self.phase_t
		local C = BVNData.CHARACTERS
		local S = BVNData.POSES
		BVNRig.Draw(C[1], 380, GROUND, 1, BVNRig.LerpPose(S.sword.idle, S.sword.cast, 0.5 + 0.5 * math.sin(t * 0.05)), {order = 20})
		BVNRig.Draw(C[3], 900, GROUND, -1, BVNRig.LerpPose(S.fist.idle, S.fist.cast, 0.5 + 0.5 * math.sin(t * 0.05 + 1)), {order = 20})
		D.Circle(900 - 62, 470 + math.sin(t * 0.05 + 1) * 3, 14, {120, 190, 255}, 170, 30)
		D.Circle(900 - 62, 470 + math.sin(t * 0.05 + 1) * 3, 8, {230, 245, 255}, 230, 31)
		D.UI(0, 90, 1280, 150, BLACK, 140, 0)
		D.UI(0, 236, 1280, 4, {255, 140, 30}, 255, 1)
		D.UI(0, 90, 1280, 4, {255, 140, 30}, 255, 1)
		D.TextC("死神", 470, 108, 92, {245, 245, 255})
		D.TextC("VS", 640, 128, 64, {255, 70, 50})
		D.TextC("火影", 810, 108, 92, {255, 160, 40})
		D.TextC("Pocket2D 格斗", 640, 250, 24, {220, 220, 230})
		for i, item in ipairs(MENU) do
			local y = 330 + (i - 1) * 56
			local on = i == self.menu
			D.UI(490, y - 6, 300, 46, on and {255, 120, 30} or BLACK, on and 220 or 140, 0)
			D.TextC(item.text, 640, y, 30, on and WHITE or {200, 200, 210})
		end
		D.TextC("W/S 选择 · J 或 Enter 确认", 640, 670, 20, {230, 230, 230})
	end,

	RenderSelect = function(self)
		BVNStage.Draw(2, self.frame)
		D.Rect(-60, -60, 1400, 840, BLACK, 150, 10)
		D.TextC("选择角色", 640, 40, 46, WHITE)
		local n = #BVNData.CHARACTERS
		local cw, gap = 230, 30
		local x0 = 640 - (n * cw + (n - 1) * gap) / 2
		for i, ch in ipairs(BVNData.CHARACTERS) do
			local x = x0 + (i - 1) * (cw + gap)
			local y = 140
			local bleach = ch.series == "死神"
			D.Rect(x, y, cw, 330, bleach and {30, 34, 60} or {70, 40, 20}, 230, 11)
			D.Rect(x, y, cw, 6, ch.theme, 255, 12)
			-- World-space rig inside the card (the camera maps world pixels 1:1 here).
			local S = BVNData.POSES[ch.style]
			local hot = self.cursor[1] == i or self.cursor[2] == i
			local pose = hot and BVNRig.LerpPose(S.idle, S.win, 0.5 + 0.5 * math.sin(self.frame * 0.1)) or S.idle
			BVNRig.Draw(ch, x + cw / 2, y + 290, 1, pose, {order = 200})
			D.TextC(ch.name, x + cw / 2, y + 300, 22, WHITE)
			D.TextC(ch.series, x + cw / 2, y + 16, 18, ch.theme)
			for slot = 1, 2 do
				if self.cursor[slot] == i then
					local c = slot == 1 and {255, 70, 60} or {70, 140, 255}
					local inset = slot == 1 and 0 or 6
					local a = self.ready[slot] and 255 or (180 + 70 * math.sin(self.frame * 0.2))
					D.UI(x - 4 + inset, y - 4 + inset, cw + 8 - inset * 2, 5, c, a, 3)
					D.UI(x - 4 + inset, y + 329 - inset, cw + 8 - inset * 2, 5, c, a, 3)
					D.UI(x - 4 + inset, y - 4 + inset, 5, 338 - inset * 2, c, a, 3)
					D.UI(x + cw - 1 - inset, y - 4 + inset, 5, 338 - inset * 2, c, a, 3)
					local label = slot == 1 and "1P" or (self.mode == "pvp" and "2P" or "CPU")
					if self.mode == "watch" then label = slot == 1 and "CPU1" or "CPU2" end
					D.TextC(label .. (self.ready[slot] and " 就绪" or ""), x + cw / 2, y - 40 - (slot - 1) * 0, 22, c)
				end
			end
		end
		for slot = 1, 2 do
			local ch = BVNData.CHARACTERS[self.cursor[slot]]
			local info = ch.special.name .. " / 奥义: " .. ch.ult.name
			D.TextC(info, 640, 500 + (slot - 1) * 34, 20, slot == 1 and {255, 150, 140} or {150, 190, 255})
		end
		local hint = self.mode == "pvp" and "1P: A/D 选择 J 确认    2P: ←/→ 选择 小键盘1 或 , 确认" or "A/D 选择 · J 确认 · K 返回"
		D.TextC(hint, 640, 600, 20, {230, 230, 230})
		D.TextC("操作: A/D 移动 W 跳 S 防御 J 轻攻击 K 重攻击 L 必杀 U 奥义 I 冲刺", 640, 640, 18, {200, 200, 210})
	end,

	RenderFight = function(self)
		BVNStage.Draw(self.stage, self.frame)
		local F = self.F
		-- The fighter acting later draws on top.
		local first, second = F[1], F[2]
		if F[1].state == "move" and F[2].state ~= "move" then first, second = F[2], F[1] end
		self:DrawFighter(first, 20)
		self:DrawFighter(second, 40)
		for _, p in ipairs(self.proj) do BVNFx.Projectile(p, self.frame) end
		for _, e in ipairs(self.fx) do BVNFx.Particle(e) end
		if self.flash > 0 then D.UI(0, 0, 1280, 720, WHITE, self.flash * 0.6, 50) end
		if self.cine then
			local c = self.cine
			D.Rect(-50, -50, 1400, 820, BLACK, math.min(180, c.t * 20), 90)
			self:DrawFighter(c.f, 100)
			local slide = math.min(1, c.t / 10)
			local bx = c.f.side == 1 and -800 + slide * 800 or 800 - slide * 800
			D.UI(bx, 300, 1280, 110, c.f.ch.theme, 210, 5)
			D.UI(bx, 296, 1280, 4, WHITE, 255, 6)
			D.UI(bx, 410, 1280, 4, WHITE, 255, 6)
			D.TextC(c.name, 640 + bx, 318, 64, WHITE)
			D.TextC(c.f.ch.name, 640 + bx, 260, 28, c.f.ch.theme)
		end
		self:DrawHud()
	end,

	DrawFighter = function(self, f, order)
		for _, gh in ipairs(f.ghosts) do
			BVNRig.Draw(f.ch, gh.x, gh.y, gh.face, gh.pose, {order = order - 10, alpha = gh.life * 12, tint = f.ch.theme, tint_amount = 0.7})
		end
		local pose = self:PoseFor(f)
		local o = {order = order, flash = f.flash}
		if f.state == "frozen" then o.tint, o.tint_amount = {170, 225, 255}, 0.55 end
		if f.invuln > 0 and f.state ~= "getup" and self.frame % 4 < 2 then o.alpha = 150 end
		local m = f.move
		if m and m.ult and f.ch.id == "ichigo" then o.bankai = true end
		if m and m.ult and f.ch.id == "sasuke" then o.eye = {230, 20, 20} end
		local pts = BVNRig.Draw(f.ch, f.x, f.y, f.face, pose, o)
		if m and m.name == "rasengan" then
			BVNFx.Orb(pts.hand_x + f.face * 10, pts.hand_y, 18, self.frame, order + 8)
		elseif m and m.name == "fireball" and m.t < 16 then
			D.Circle(pts.head_x + f.face * 18, pts.head_y + 6, 6 + m.t * 0.4, {255, 160, 40}, 200, order + 8)
		elseif m and m.name == "kirin" then
			BVNFx.Chidori(pts.hand_x, pts.hand_y, self.frame, order + 8)
		elseif m and (m.name == "getsuga" or m.name == "getsuga_black") and m.t < 14 then
			D.Circle(pts.hand_x, pts.hand_y, 10 + m.t, m.name == "getsuga" and {150, 220, 255} or {200, 30, 40}, 120, order + 8)
		elseif m and (m.name == "hakuren" or m.name == "tsukishiro") then
			BVNFx.Snow(pts.hand_x, pts.hand_y, self.frame, order + 8)
		end
		if f.state == "frozen" then
			local s = f.ch.scale
			D.Rect(f.x - 38, f.y - 150 * s, 76, 150 * s, {190, 235, 255}, 110, order + 9)
			D.Rect(f.x - 38, f.y - 150 * s, 76, 5, WHITE, 180, order + 9)
		end
	end,

	DrawHud = function(self)
		local F = self.F
		for side = 1, 2 do
			local f = F[side]
			local x, w = side == 1 and 40 or 740, 500
			D.UI(x - 4, 26, w + 8, 34, BLACK, 200, 10)
			D.UI(x, 30, w, 26, {90, 20, 20}, 255, 11)
			local tw, hw = w * f.trail / 100, w * f.hp / 100
			local hc = f.hp > 30 and {255, 210, 40} or {255, 70, 40}
			if side == 1 then
				D.UI(x + w - tw, 30, tw, 26, {255, 245, 230}, 255, 12)
				D.UI(x + w - hw, 30, hw, 26, hc, 255, 13)
			else
				D.UI(x, 30, tw, 26, {255, 245, 230}, 255, 12)
				D.UI(x, 30, hw, 26, hc, 255, 13)
			end
			local name = f.ch.name .. (f.cpu and "  CPU" or "")
			local nw = D.TextWidth(name, 24)
			D.TextC(name, side == 1 and x + nw / 2 or x + w - nw / 2, 64, 24, WHITE)
			-- Round wins.
			for i = 1, 2 do
				local wx = side == 1 and (x + w - 18 * i) or (x + 18 * (i - 1) + 4)
				D.UI(wx, 64, 12, 12, (self.wins[side] >= i) and {255, 220, 60} or {60, 60, 70}, 255, 14)
			end
			-- Energy.
			local ex, ew = side == 1 and 40 or 940, 300
			D.UI(ex - 3, 672, ew + 6, 20, BLACK, 200, 10)
			local bars = math.floor(f.energy / 100)
			local part = (f.energy % 100) / 100
			for b = 0, 2 do
				local bx = ex + b * 100
				local fill = b < bars and 1 or (b == bars and part or 0)
				local c = b < bars and {80, 200, 255} or {40, 110, 170}
				if side == 2 then bx = ex + (2 - b) * 100 end
				local fw = 96 * fill
				D.UI(side == 1 and bx + 2 or bx + 98 - fw, 675, fw, 14, c, 255, 11)
			end
			local label = "气 " .. bars
			if side == 1 then D.Text(label, ex + ew + 12, 666, 26, {120, 220, 255})
			else D.Text(label, ex - 12 - D.TextWidth(label, 26), 666, 26, {120, 220, 255}) end
			if f.combo >= 2 and f.combo_show > 0 then
				local cx = side == 1 and 150 or 1130
				D.TextC(f.combo .. " 连击!", cx, 200, 44, {255, 230, 80}, math.min(255, f.combo_show * 8))
			end
		end
		D.UI(596, 22, 88, 60, BLACK, 220, 10)
		D.TextC(tostring(math.max(0, math.ceil(self.time / 60))), 640, 26, 44, WHITE)
		D.TextC(BVNData.STAGES[self.stage].name, 640, 88, 18, {220, 220, 230})
		if self.callout then
			local c = self.callout
			local a = math.min(255, (60 - c.t) * 10)
			local cx = c.f.side == 1 and 260 or 1020
			D.TextC(c.name, cx, 140, 34, c.f.ch.theme, a)
		end
		if self.phase == "fight" and self.rs == "intro" then
			local t = self.rs_t
			if t < 60 then D.TextC("第 " .. self.round_no .. " 回合", 640, 280, 72, WHITE, math.min(255, t * 12))
			else D.TextC("开始!", 640, 270, 96, {255, 90, 50}, 255) end
		elseif self.phase == "fight" and self.rs == "ko" and self.rs_t > 10 then
			local text = self.time_over and "时间到!" or "K.O.!"
			D.TextC(text, 640, 260, 110, {255, 60, 40})
			if self.rs_t > 80 then
				local w = self.round_winner
				D.TextC(w > 0 and (F[w].ch.name .. " 胜") or "平局", 640, 400, 40, WHITE)
			end
		elseif self.phase == "result" then
			local champ = F[self.match_winner]
			D.UI(0, 230, 1280, 200, BLACK, 170, 20)
			D.TextC("胜者", 640, 250, 40, {255, 220, 60})
			D.TextC(champ.ch.name, 640, 300, 80, champ.ch.theme)
			if self.phase_t > 60 then D.TextC("按 J 或 Enter 返回角色选择", 640, 395, 22, WHITE, 200 + 55 * math.sin(self.frame * 0.1)) end
		end
	end,
}
