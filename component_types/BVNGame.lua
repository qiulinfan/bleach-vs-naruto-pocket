-- Bleach vs Naruto on Pocket2D: menus (BVNMenu), matches (BVNBattle) and the
-- arcade ladder. Characters, maps and music are converted from 5DPLAY's
-- assets by tools/convert_bvn.py and tools/convert_maps.py.
local D = setmetatable({}, {__index = function(_, k) return BVNDraw[k] end})
local WHITE = {255, 255, 255}

BVNGame = {
	-- Scalar properties for scenarios and the inspector.
	phase_name = "title",
	match_winner = 0,
	round_no = 0,
	p1_hp = 0,
	p2_hp = 0,

	OnStart = function(self)
		self:Init()
	end,

	Init = function(self)
		if self.inited then return end
		self.inited = true
		BVNRuntime.seed = 20261017
		self.prev_axis = {0, 0}
		BVNMenu.Enter(self, "title")
		self.menu.phase = "title"
		BVNSound.Music("bvn/bgm/op")
	end,

	Tap = function(self, side)
		local v = Input.GetActionValue("p" .. side .. "_move")
		local prev = self.prev_axis[side]
		self.prev_axis[side] = v
		if v > 0.5 and prev <= 0.5 then return 1 end
		if v < -0.5 and prev >= -0.5 then return -1 end
		return 0
	end,

	OnUpdate = function(self)
		local b = self.battle
		if b then
			if b.phase == "over" then
				b.phaseT = b.phaseT + 1
				b:Draw()
				self:DrawResult()
				local auto = self.mode == "watch" and b.phaseT > 300
				if b.phaseT > 60 and (Input.GetActionDown("confirm") or Input.GetActionDown("p1_attack") or auto) then
					self:AfterMatch()
				end
			else
				b:Update()
				b:Draw()
			end
			self.phase_name = "battle"
			self.round_no = b.round
			self.p1_hp, self.p2_hp = b.fighters[1].hp, b.fighters[2].hp
		else
			Camera.SetZoom(1)
			Camera.SetPosition(6.4, 3.6)
			BVNMenu.Update(self)
			if not self.battle then BVNMenu.Draw(self) end
			self.phase_name = self.menu.phase
		end
	end,

	StartBattle = function(self, picks, mapId)
		local mode = self.mode
		local opts = {mode = mode, map = mapId, level = self.level or 3,
			p1 = {fighter = picks[1].fighter, assist = picks[1].assist, cpu = mode == "watch"},
			p2 = {fighter = picks[2].fighter, assist = picks[2].assist, cpu = mode ~= "pvp", noAI = mode == "training"}}
		self.lastPicks, self.lastMap = picks, mapId
		self.battle = BVNBattle.New(opts)
		self.match_winner = 0
	end,

	-- Arcade: eight CPU opponents of rising level on random stages.
	StartArcade = function(self, pick)
		local pool = {}
		for _, d in ipairs(BVNConfig.fighter.fighter.data) do
			if d.id ~= pick.fighter and BVNMenu.Available(d.id) and not d.id:find("^random") then pool[#pool + 1] = d.id end
		end
		local ladder = {}
		for i = 1, math.min(8, #pool) do
			local j = i + math.floor(BVNRuntime.RAND() * (#pool - i + 1))
			pool[i], pool[j] = pool[j], pool[i]
			ladder[i] = pool[i]
		end
		self.arcade = {pick = pick, ladder = ladder, stage = 1}
		self:NextArcade()
	end,

	NextArcade = function(self)
		local a = self.arcade
		local maps = BVNConfig.map.map.data
		local mapId = maps[2 + math.floor(BVNRuntime.RAND() * (#maps - 1))].id
		local assist = BVNMenu.Resolve("random", true)
		self.level = math.min(6, 1 + a.stage // 2)
		self.mode = "arcade"
		self:StartBattle({a.pick, {fighter = a.ladder[a.stage], assist = assist}}, mapId)
	end,

	AfterMatch = function(self)
		local b = self.battle
		self.match_winner = b.matchWinner or 0
		self.battle = nil
		if self.arcade then
			local a = self.arcade
			if b.matchWinner == 1 then a.stage = a.stage + 1 end
			if a.stage > #a.ladder then
				self.arcade = nil
				BVNMenu.Enter(self, "title")
				self.menu.phase = "title"
				BVNSound.Music("bvn/bgm/congratulation")
				return
			end
			self:NextArcade()
			return
		end
		BVNMenu.Enter(self, "select")
		BVNSound.Music("bvn/bgm/select")
	end,

	DrawResult = function(self)
		local b = self.battle
		local w = b.fighters[b.matchWinner or 1]
		D.UI(0, 0, 1280, 720, {0, 0, 0}, 150, 50)
		if w.info.urls.face_win then Image.DrawUIScaled("bvn/face/" .. w.info.urls.face_win, 640 - 300, 140, 2, 2, 255, 255, 255, 255, 51) end
		D.TextC("WINNER", 640, 80, 50, {255, 220, 60})
		D.TextC(w.info.name, 640, 650, 40, WHITE)
		local says = w.info.says
		if says and #says > 0 then D.TextC(says[1 + (b.round % #says)], 640, 610, 20, {230, 230, 230}) end
	end,

	-- Agent interface ---------------------------------------------------------------------

	OnAgentObserve = function(self)
		local b = self.battle
		local function fighter(f)
			return {id = f.info.id, hp = f.hp, qi = f.qi, energy = f.energy, x = f.x, y = f.y, state = f.state,
				label = f:CurLabel(), dir = f.dir, cpu = f.ai ~= nil}
		end
		if not b then return {phase = self.menu and self.menu.phase} end
		return {phase = b.phase, mode = b.mode, map = b.map.id, round = b.round, wins = b.wins, time = b.time,
			p1 = fighter(b.fighters[1]), p2 = fighter(b.fighters[2]), sprites = #b.sprites, match_winner = b.matchWinner,
			bisha = b.bisha and {t = b.bisha.t, img = b.bisha.img} or nil, freeze = b.fx.freeze, pause = b.pause}
	end,

	OnAgentCommand = function(self, name, args)
		self:Init()
		if name == "start_battle" then
			self.mode = args.mode or "watch"
			self.level = args.level or 3
			self:StartBattle({{fighter = args.p1 or "ichigo", assist = args.p1_assist}, {fighter = args.p2 or "naruto", assist = args.p2_assist}},
				args.map or "xianshi")
			if args.skip_intro then
				local bt = self.battle
				for _, f in ipairs(bt.fighters) do f:Idle() end
				bt.phase, bt.phaseT, bt.actionEnable = "fight", 0, true
			end
			return {phase = self.battle.phase}
		elseif name == "set_qi" and self.battle then
			local f = self.battle.fighters[args.side or 1]
			f.qi = args.qi or 300
			return {qi = f.qi}
		elseif name == "set_hp" and self.battle then
			local f = self.battle.fighters[args.side or 1]
			f.hp = args.hp or f.hpMax
			return {hp = f.hp}
		end
		return nil
	end,
}
