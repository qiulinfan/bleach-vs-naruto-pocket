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
		if b and self.vs then
			-- The pre-fight VS screen (LoadingStage): faces, names and the stage.
			self.vs = self.vs + 1
			Camera.SetZoom(1)
			Camera.SetPosition(6.4, 3.6)
			self:DrawVs(b)
			if self.vs > 150 or (self.vs > 30 and (Input.GetActionDown("confirm") or Input.GetActionDown("p1_attack"))) then
				self.vs = nil
			end
			return
		end
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
			p1 = {team = picks[1].team or {picks[1].fighter}, assist = picks[1].assist, cpu = mode == "watch"},
			p2 = {team = picks[2].team or {picks[2].fighter}, assist = picks[2].assist, cpu = mode ~= "pvp", noAI = mode == "training",
				hpRate = picks[2].hpRate, attackRate = picks[2].attackRate}}
		self.lastPicks, self.lastMap = picks, mapId
		self.battle = BVNBattle.New(opts)
		self.match_winner = 0
		self.vs = 0
	end,

	-- Arcade (MessionModel): the stage list for the player's series and mode from mission.json.
	StartArcade = function(self, pick)
		local info = BVNMenu.FighterInfo(pick.team and pick.team[1] or pick.fighter)
		local comic = info and info.comic_type or 0
		local mode = self.team and 0 or 1
		local level
		for _, l in ipairs(BVNConfig.mission.level) do
			if l.comic_type == comic and l.game_mode == mode then level = l end
		end
		self.arcade = {pick = pick, stages = level and level.stage or {}, stage = 1}
		self:NextArcade()
	end,

	NextArcade = function(self)
		local a = self.arcade
		local st = a.stages[a.stage]
		local team = {}
		for _, id in ipairs(st and st.fighter or {}) do
			if BVNMenu.Available(id) and (#team < (self.team and 3 or 1)) then team[#team + 1] = id end
		end
		if #team == 0 then team = {BVNMenu.Resolve("random")} end
		local assist = st and st.assistant
		if not (assist and BVNMenu.Available(assist, true)) then assist = BVNMenu.Resolve("random", true) end
		local props = st and st.properties or {}
		self.level = 3
		self.mode = "arcade"
		self:StartBattle({a.pick, {team = team, fighter = team[1], assist = assist, hpRate = props.hp_rate, attackRate = props.attack_rate}},
			st and BVNMaps[st.map] and st.map or "xianshi")
	end,

	AfterMatch = function(self)
		local b = self.battle
		self.match_winner = b.matchWinner or 0
		self.battle = nil
		if self.arcade then
			local a = self.arcade
			if b.matchWinner == 1 then a.stage = a.stage + 1 end
			if a.stage > #a.stages then
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

	DrawVs = function(self, b)
		local sel = BVNUIData and BVNUIData["$select$MC_stgSelect"]
		if sel then Image.DrawUIScaled(sel.parts[1].parts[1].img, 0, 0, 1.6, 1.6, 255, 255, 255, 255, 0) end
		local t = math.min(1, self.vs / 20)
		for side = 1, 2 do
			local team = b.opts["p" .. side].team
			for i = #team, 1, -1 do
				local info = BVNMenu.FighterInfo(team[i])
				if info and info.urls.face_win then
					local k = i == 1 and 1.6 or 0.9
					local w = 300 * k
					local x = side == 1 and (-w + t * (w + 20) + (i - 1) * 170) or (1280 + w - t * (w + 20) - w - (i - 1) * 170)
					local y = i == 1 and 140 or 360
					Image.DrawUIScaled("bvn/face/" .. info.urls.face_win, x, y, side == 1 and k or -k, k, 255, 255, 255, 255, 2 + (3 - i))
				end
			end
			local info = BVNMenu.FighterInfo(team[1])
			D.TextC(info and info.name or "", side == 1 and 260 or 1020, 560, 34, WHITE)
		end
		D.TextC("VS", 640, 300, 120, {255, 80, 40}, 255 * t)
		D.TextC(b.map.name or "", 640, 640, 28, {230, 230, 255})
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
			bisha = b.bisha and {t = b.bisha.t, img = b.bisha.img, kind = b.bisha.f.kind} or nil, freeze = b.fx.freeze, pause = b.pause,
			others = (function()
				local out = {}
				for _, sp in ipairs(b.sprites) do
					if sp.kind ~= "fighter" and sp.clip then
						out[#out + 1] = {kind = sp.kind, frame = sp.clip.frame, total = #sp.clip.data.frames, playing = sp.clip.playing,
							label = BVNClip.Label(sp.clip), x = sp.x, y = sp.y}
					end
				end
				return out
			end)()}
	end,

	OnAgentCommand = function(self, name, args)
		self:Init()
		if name == "start_battle" then
			self.mode = args.mode or "watch"
			self.level = args.level or 3
			local t1 = args.p1_team or {args.p1 or "ichigo"}
			local t2 = args.p2_team or {args.p2 or "naruto"}
			self:StartBattle({{team = t1, fighter = t1[1], assist = args.p1_assist}, {team = t2, fighter = t2[1], assist = args.p2_assist}},
				args.map or "xianshi")
			if args.skip_intro then
				self.vs = nil
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
