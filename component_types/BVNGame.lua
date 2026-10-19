-- Bleach vs Naruto on Pocket2D: the original stage flow (MainGame): boot,
-- logo, title menu, how-to-play, fighter select, the VS loading screen,
-- fights (BVNBattle) with the pause dialog, winner / continue / game over /
-- congratulations for arcade (MessionModel), options and credits, and MUSOU
-- ACRADE: the world map, LoadingMusouStage and the musou fight (BVNMusou*).
-- Characters, maps and music are converted from 5DPLAY's assets by
-- tools/convert_bvn.py and tools/convert_maps.py, the screens by tools/convert_ui.py
-- and tools/convert_musou_ui.py.
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})

BVNGame = {
	-- Scalar properties for scenarios and the inspector.
	phase_name = "boot",
	match_winner = 0,
	round_no = 0,
	p1_hp = 0,
	p2_hp = 0,
	score = 0,
	-- MUSOU: the last mission's result (1 complete, 2 failed), the wave and the KO count.
	musou_result = 0,
	musou_wave = 0,
	musou_ko = 0,

	-- Adds arcade score (GameLogic.addScore: x0.8 in the classic key mode).
	-- The battle calls it for hits and KOs: `if BVNGame.AddScore then BVNGame.AddScore(points) end`.
	AddScore = function(points)
		local g = BVNGame.current
		if not g then return end
		local rate = BVNSettings.keyMode == 0 and 1 or 0.8
		g.score = math.floor(g.score + points * rate)
	end,

	OnStart = function(self)
		self:Init()
	end,

	Init = function(self)
		if self.inited then return end
		self.inited = true
		BVNGame.current = self
		-- Converted data never changes: netplay rollback snapshots leave it out.
		Net.Static(BVNConfig, BVNFxData, BVNMaps, BVNMusouConfig, BVNUIData)
		BVNRuntime.seed = 20261017
		BVNSettings.Load()
		BVNKeys.Load()
		-- Packaged builds look for a newer release at start (in the background).
		if Update.Status().installable then Update.Check() end
		self.mission = {id = 0}
		self:Go(BVNScreenFlow.NewBoot(self))
	end,

	Go = function(self, st)
		self.stage = st
		self.battle = nil
		self.paused = nil
		self.phase_name = st.phase or st.name
	end,

	-- MainGame navigation -------------------------------------------------------------------
	GoLogo = function(self) self:Go(BVNScreenFlow.NewLogo(self)) end,

	GoMenu = function(self)
		-- In a net session the title (pause GAME TITLE, back on select) ends it on both machines.
		if BVNNet.Active() then
			BVNNet.Stop(self, nil)
			return
		end
		BVNTrans.Clear()
		BVNScreen.Release()
		self:Go(BVNMenu.NewTitle(self))
	end,

	GoHowToPlay = function(self) self:Go(BVNScreenFlow.NewHowToPlay(self)) end,
	GoSelect = function(self) self:Go(BVNMenu.NewSelect(self)) end,
	GoOption = function(self) self:Go(BVNScreenSetting.New(self)) end,
	GoCredits = function(self) self:Go(BVNScreenFlow.NewCredits(self)) end,

	-- MUSOU ACRADE (MainGame.goWorldMap / loadGame / goMusouGame): the world map
	-- (BVNMusouMap), LoadingMusouStage, then the musou fight (BVNMusouBattle).
	GoWorldMap = function(self)
		self.mode, self.team = "musou", true
		BVNScreen.Release()
		self:Go(BVNMusouMap.NewWorldMap(self))
	end,

	LoadMusou = function(self, mission)
		self:Go(BVNMusouMap.NewLoading(self, mission))
	end,

	-- opts (agent tests): auto = the CPU plays the team, aiLevel.
	StartMusou = function(self, mission, opts)
		opts = opts or {}
		BVNScreen.Release()
		BVNMusouDialog.Clear()
		self.stage = nil
		self.paused, self.pauseQueued, self.ending = nil, nil, nil
		self.musou_result = 0
		self.battle = BVNMusouBattle.New({mission = mission, team = BVNMusouData.Team(), auto = opts.auto, aiLevel = opts.aiLevel})
		self.battleTicks = 0
		self.match_winner = 0
		self.phase_name = "musou"
	end,

	-- The musou fight: MusouPauseDialog, and back to the world map when it is over.
	UpdateMusou = function(self, b)
		self.battleTicks = (self.battleTicks or 0) + 1
		if self.battleTicks == 2 and BVNTrans.Covered() then BVNTrans.Out() end
		local draw = not BVNTrans.Covered()
		if self.paused then
			local r = BVNMusouDialog.UpdatePause(self.paused)
			if r == "map" then
				BVNMusouDialog.Clear()
				self:GoWorldMap()
				return
			end
			if r == "continue" then self.paused = nil end
			b:Draw()
			if self.paused and self.battle == b then
				BVNScreen.textFloor = 1400
				BVNMusouDialog.DrawPause(self.paused)
			end
		else
			if b.phase == "over" and not self.ending then
				self.ending = true
				self.musou_result = b.result == "win" and 1 or 2
				BVNTrans.In(function() self:GoWorldMap() end)
			end
			-- GameCtrl.renderPause: back pauses, after the start banner if it is still playing.
			if S.Down("back", "menu") and not b.gameFinish then self.pauseQueued = true end
			if self.pauseQueued and b:CanPause() and not BVNTrans.Busy() then
				self.pauseQueued = nil
				self.paused = BVNMusouDialog.Pause()
				b:Draw()
				BVNMusouDialog.DrawPause(self.paused)
				return
			end
			b:Update()
			if draw and self.battle == b then b:Draw() end
		end
		if self.battle == b then
			self.phase_name = self.paused and "musou_pause" or "musou"
			self.musou_wave, self.musou_ko = b.currentWave, b.koNum
			self.p1_hp = b.current and b.current.hp or 0
		end
	end,

	-- STUB (owned by the coordinator next): SURVIVOR after the select screen
	-- (picks[1] = {team, assist}). Until survivor mode exists it plays an
	-- arcade-style ladder (survivor counts as arcade in GameMode.isArcade).
	StartSurvivor = function(self, picks)
		self.mode = "survivor"
		self:InitMission(picks[1])
		self:LoadGame()
	end,

	-- MessionModel ----------------------------------------------------------------------------
	ResetMission = function(self)
		self.mission = {id = 0}
		self.score = 0
	end,

	-- initMession: the stage list for player 1's series and mode, the current stage's opponents.
	InitMission = function(self, p1)
		self.p1Select = p1
		local info = BVNMenu.FighterInfo(p1.team[1])
		local comic = info and info.comic_type or 0
		local gm = self.team and 0 or 1
		local level
		for _, l in ipairs(BVNConfig.mission.level) do
			if l.comic_type == comic and l.game_mode == gm then level = l end
		end
		local ms = self.mission
		ms.stages = level and level.stage or {}
		local st = ms.stages[ms.id + 1]
		local team = {}
		for _, id in ipairs(st and st.fighter or {}) do
			if BVNMenu.Available(id) and #team < (self.team and 3 or 1) then team[#team + 1] = id end
		end
		if #team == 0 then team = {BVNMenu.Resolve("random")} end
		local assist = st and st.assistant
		if not (assist and BVNMenu.Available(assist, true)) then assist = BVNMenu.Resolve("random", true) end
		local props = st and st.properties or {}
		self.p2Select = {team = team, assist = assist, hpRate = props.hp_rate, attackRate = props.attack_rate}
		self.selectMap = st and BVNMaps[st.map] and st.map or "xianshi"
	end,

	MissionAllComplete = function(self)
		local ms = self.mission
		return ms.id >= #(ms.stages or {}) - 1
	end,

	-- WinnerStage.goNext: messionComplete, then the next loading screen.
	NextMission = function(self)
		if not self:MissionAllComplete() then
			self.mission.id = self.mission.id + 1
			self:InitMission(self.p1Select)
			-- addScoreByPassMission: 15000 in team arcade when the first fighter is still the leader, else 5000.
			local lead = self.team and self.lastP1 == self.p1Select.team[1]
			BVNGame.AddScore(lead and 15000 or 5000)
		end
		self:LoadGame()
	end,

	-- GameOverStage YES: -10000 score, back to the select screen at the same stage.
	Continue = function(self)
		self.score = math.max(0, self.score - 10000)
		self:GoSelect()
	end,

	IsArcade = function(self)
		return self.mode == "arcade" or self.mode == "survivor"
	end,

	-- MainGame.loadGame: the VS loading screen, then the fight in the chosen order.
	LoadGame = function(self)
		local p1, p2 = self.p1Select, self.p2Select
		self:Go(BVNScreenFlow.NewLoading(self, p1, p2, function(order1, order2)
			local a = {team = order1, fighter = order1[1], assist = p1.assist}
			local b = {team = order2, fighter = order2[1], assist = p2.assist, hpRate = p2.hpRate, attackRate = p2.attackRate}
			self:StartBattle({a, b}, self.selectMap)
		end))
	end,

	-- Builds BVNBattle's options from the mode and the saved options.
	StartBattle = function(self, picks, mapId, level)
		local mode = self.mode or "watch"
		local battleMode = mode == "survivor" and "arcade" or mode
		local opts = {mode = battleMode, map = mapId, level = level or BVNSettings.aiLevel, time = BVNSettings.gameTime,
			fighterHP = BVNSettings.fighterHP, hpRate = picks[2].hpRate,
			p1 = {team = picks[1].team or {picks[1].fighter}, assist = picks[1].assist, cpu = mode == "watch"},
			p2 = {team = picks[2].team or {picks[2].fighter}, assist = picks[2].assist, cpu = mode ~= "pvp",
				noAI = mode == "training", attackRate = picks[2].attackRate}}
		BVNScreen.Release()
		self.lastPicks, self.lastMap = picks, mapId
		self.stage = nil
		self.paused, self.pauseQueued, self.ending = nil, nil, nil
		self.battle = BVNBattle.New(opts)
		self.battleTicks = 0
		self.match_winner = 0
		self.phase_name = "battle"
	end,

	-- GameCtrl.fightFinish.
	AfterMatch = function(self)
		local b = self.battle
		self.match_winner = b.matchWinner or 0
		self.battle = nil
		if b.score then BVNGame.AddScore(b.score) end
		local p1 = b.fighters[1]
		self.lastP1 = p1 and p1.info and p1.info.id
		if self:IsArcade() and self.p1Select then
			if b.matchWinner == 1 then
				if self:MissionAllComplete() then
					self:Go(BVNScreenFlow.NewCongratulations(self, self.score))
				else
					local says = p1.info.says
					local say = says and #says > 0 and says[1 + math.floor(BVNRuntime.RAND() * #says)] or ""
					self:Go(BVNScreenFlow.NewWinner(self, p1.info.id, self.p1Select.team, say, self.score))
				end
			else
				self:Go(BVNScreenFlow.NewGameOver(self, p1 and p1.info and p1.info.id, self.score, true))
			end
			BVNTrans.Clear()
			return
		end
		BVNTrans.Clear()
		self:GoSelect()
	end,

	OnUpdate = function(self)
		self:Init()
		BVNNet.Update(self)
		BVNScreen.Poll()
		Camera.SetZoom(1)
		Camera.SetPosition(6.4, 3.6)
		BVNTrans.Update()
		local b = self.battle
		BVNScreen.textFloor = -math.huge
		if b then
			self:UpdateBattle(b)
		elseif self.stage then
			local st = self.stage
			st:Update(self)
			if self.stage == st and not self.battle then
				if st.confirm then BVNScreen.textFloor = 1500 end
				if BVNTrans.Hiding() then BVNScreen.textFloor = 2000 end
				st:Draw(self)
				BVNScreen.Bars(900)
			end
			if self.stage then self.phase_name = self.stage.phase or self.stage.name end
		end
		BVNTrans.Draw()
		BVNNet.Draw(self)
	end,

	UpdateBattle = function(self, b)
		if b.musou then return self:UpdateMusou(b) end
		self.battleTicks = (self.battleTicks or 0) + 1
		-- GameStartCtrl uncovers the screen; if the battle does not, do it here.
		if self.battleTicks == 2 and BVNTrans.Covered() then BVNTrans.Out() end
		-- A fully covered screen draws nothing beneath (the HUD's text would show through).
		local draw = not BVNTrans.Covered()
		if self.paused then
			if BVNScreenDialog.UpdatePause(self.paused) == "continue" then self.paused = nil end
			b:Draw()
			if self.paused and self.battle == b then
				BVNScreen.textFloor = 1400
				BVNScreenDialog.DrawPause(self.paused)
			end
		elseif b.phase == "over" then
			b.phaseT = b.phaseT + 1
			if draw then b:Draw() end
			if b.phaseT > 90 and not self.ending then
				self.ending = true
				BVNTrans.In(function() self:AfterMatch() end)
			end
		else
			-- GameCtrl.renderPause: during the start and end sequences back (or select) skips
			-- them; otherwise back pauses.
			if b.start or b.endCtrl then
				if S.Down("back", "menu") or S.Down("select", "menu") then b:Skip() end
			elseif S.Down("back", "menu") then
				self.pauseQueued = true
			end
			if self.pauseQueued and b.phase == "fight" and not BVNTrans.Busy() then
				self.pauseQueued = nil
				self.paused = BVNScreenDialog.Pause(function() self:GoMenu() end, nil)
				b:Draw()
				BVNScreenDialog.DrawPause(self.paused)
				return
			end
			b:Update()
			if draw then b:Draw() end
		end
		if self.battle == b then
			self.phase_name = self.paused and "pause" or "battle"
			self.round_no = b.round
			self.p1_hp, self.p2_hp = b.fighters[1].hp, b.fighters[2].hp
		end
	end,

	-- Agent interface ---------------------------------------------------------------------

	OnAgentObserve = function(self)
		local b = self.battle
		local function fighter(f)
			return {id = f.info.id, hp = f.hp, qi = f.qi, energy = f.energy, x = f.x, y = f.y, state = f.state,
				label = f:CurLabel(), dir = f.dir, cpu = f.ai ~= nil}
		end
		if not b then
			local st = self.stage
			local o = {phase = st and (st.phase or st.name), score = self.score, mode = self.mode}
			if self.mode == "musou" then o.musou = BVNGame.MusouSummary() end
			return o
		end
		if b.musou then
			local o = b:Observe()
			o.paused = self.paused ~= nil
			o.data = BVNGame.MusouSummary()
			return o
		end
		return {phase = b.phase, mode = b.mode, map = b.map.id, round = b.round, wins = b.wins, time = b.time,
			p1 = fighter(b.fighters[1]), p2 = fighter(b.fighters[2]), sprites = #b.sprites, match_winner = b.matchWinner,
			paused = self.paused ~= nil,
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
			self.team = args.p1_team ~= nil and #args.p1_team > 1
			local t1 = args.p1_team or {args.p1 or "ichigo"}
			local t2 = args.p2_team or {args.p2 or "naruto"}
			BVNTrans.Clear()
			self:StartBattle({{team = t1, fighter = t1[1], assist = args.p1_assist}, {team = t2, fighter = t2[1], assist = args.p2_assist}},
				args.map or "xianshi", args.level)
			if args.skip_intro then
				local bt = self.battle
				for _, f in ipairs(bt.fighters) do f:Idle() end
				bt.phase, bt.phaseT, bt.actionEnable = "fight", 0, true
			end
			return {phase = self.battle.phase}
		elseif name == "debug_boxes" and self.battle then
			self.battle.debugBoxes = args.on ~= false
			return {on = self.battle.debugBoxes}
		elseif name == "set_qi" and self.battle then
			local f = self.battle.fighters[args.side or 1]
			f.qi = args.qi or 300
			return {qi = f.qi}
		elseif name == "audit_fill" and self.battle then
			-- tools/battle_audit.py: full qi, energy, assist and HP on both sides, so every move can run.
			local m = self.battle.map
			for i, f in ipairs(self.battle.fighters) do
				f.qi, f.energy, f.fzqi, f.hp = f.qiMax or 300, f.energyMax or 100, f.fzqiMax or 100, f.hpMax
				f.overload = false
				-- reset: back to the middle of the map, facing each other, so the camera stays close.
				if args.reset and m and not f.inAir then
					f.x, f.vx = (m.left + m.right) / 2 + (i == 1 and -90 or 90), 0
					f.dir = i == 1 and 1 or -1
				end
			end
			return true
		elseif name == "audit_sprites" and self.battle then
			-- The battle's other sprites (attackers, bullets, assists): what plays and where.
			local out = {}
			for _, sp in ipairs(self.battle.sprites) do
				if sp.kind ~= "fighter" then
					local c = sp.clip
					out[#out + 1] = {kind = sp.kind, name = sp.name, sprite = c and c.sid, frame = c and c.frame,
						frames = c and #c.data.frames, label = c and BVNClip.Label(c), dead = sp.dead or false,
						x = math.floor(sp.x or 0), y = math.floor(sp.y or 0), playing = c and c.playing}
				end
			end
			for f, sh in pairs(self.battle.fx.shadows or {}) do
				out[#out + 1] = {kind = "shadow", name = f.char and f.char.id, frames = #sh.snaps}
			end
			for _, v in ipairs(self.battle.fx.effects or {}) do
				if v.active then out[#out + 1] = {kind = "effect", name = v.e.cls, frame = v.cur, x = math.floor(v.x or 0), y = math.floor(v.y or 0)} end
			end
			return out
		elseif name == "audit_state" and self.battle then
			-- The fighter's converted character, form (main_mc frame) and the sprite it plays.
			local f = self.battle.fighters[args.side or 1]
			return {char = f.char.id, form = f.mainFrame, form_index = f.formIndex, sprite = f.clip and f.clip.sid,
				label = f.clip and BVNClip.Label(f.clip), state = f.state, sprites = #self.battle.sprites,
				x = f.x, y = f.y, inAir = f.inAir, bottom = self.battle.map.bottom, frame = f.clip and f.clip.frame,
				kids = (function()
					local k = {}
					for serial, kid in pairs(f.clip and f.clip.kids or {}) do k[#k + 1] = kid.sid .. "@" .. kid.frame end
					table.sort(k)
					return k
				end)()}
		elseif name == "set_hp" and self.battle then
			local f = self.battle.fighters[args.side or 1]
			f.hp = args.hp or f.hpMax
			return {hp = f.hp}
		elseif name == "set_option" then
			-- Options for tests: {key = "aiLevel", value = 3, save = true}.
			if args.key and BVNSettings.Valid(args.key, args.value) then
				BVNSettings[args.key] = args.value
				BVNSettings.Apply()
				if args.save then BVNSettings.Save() end
				return {ok = true, [args.key] = args.value}
			end
			return {ok = false}
		elseif name == "end_match" and self.battle then
			-- Ends the fight at once with `winner` (1 or 2), as if its last round was decided.
			local bt = self.battle
			bt.matchWinner = args.winner or 1
			bt.phase, bt.phaseT = "over", 0
			return {phase = bt.phase, winner = bt.matchWinner}
		elseif name == "goto" then
			-- Opens a screen directly (tests and agents): title, select, option, credits, howtoplay,
			-- logo, winner, continue, gameover, congratulations, worldmap, netplay, keys. mode / team pick the game mode.
			local stg = args.stage
			self.mode = args.mode or self.mode or "arcade"
			if args.team ~= nil then self.team = args.team end
			BVNTrans.Clear()
			local p1 = args.p1_team or {args.p1 or "ichigo"}
			if stg == "title" then self:GoMenu()
			elseif stg == "select" then self:GoSelect()
			elseif stg == "option" then self:GoOption()
			elseif stg == "keys" then self:Go(BVNKeys.New(self))
			elseif stg == "credits" then self:GoCredits()
			elseif stg == "howtoplay" then self:GoHowToPlay()
			elseif stg == "logo" then self:GoLogo()
			elseif stg == "winner" then
				self.p1Select = {team = p1}
				local inf = BVNMenu.FighterInfo(p1[1])
				self:Go(BVNScreenFlow.NewWinner(self, p1[1], p1, inf and inf.says and inf.says[1] or "", self.score))
			elseif stg == "continue" or stg == "gameover" then
				self:Go(BVNScreenFlow.NewGameOver(self, p1[1], self.score, stg == "continue"))
			elseif stg == "congratulations" then
				self:Go(BVNScreenFlow.NewCongratulations(self, self.score))
			elseif stg == "worldmap" then
				self:GoWorldMap()
			elseif stg == "netplay" then
				self:Go(BVNNet.New(self))
			else
				return {ok = false}
			end
			return {ok = true, phase = self.phase_name}
		elseif name == "options" then
			return BVNSettings.Snapshot()
		elseif name == "net_host" or name == "net_join" then
			-- NET PLAY for tests: net_host {how = "room" | "lan" | "code", port, team, netcode, relay,
			-- stun, discovery_port}; net_join {how, room | address | code, netcode, relay, stun}.
			BVNTrans.Clear()
			local st = BVNNet.New(self)
			self:Go(st)
			if args.team ~= nil then BVNNet.team = args.team end
			if args.netcode then BVNNet.netcode = args.netcode end
			if args.delay then BVNNet.delay = args.delay end
			BVNNet.relay = args.relay == true
			BVNNet.lanPort = args.port
			BVNNet.stun = args.stun
			BVNNet.discoveryPort = args.discovery_port
			local how = args.how or (args.lan and "lan") or (args.address and "lan") or (args.code and "code") or "room"
			if name == "net_host" then st.Start(true, how)
			else st.Start(false, how, args.room or args.address or args.code) end
			return {view = st.view, message = st.message, status = Net.Status()}
		elseif name == "net_code_connect" then
			-- The code host takes the guest's code: {code}.
			return {ok = Net.CodeConnect(args.code or "")}
		elseif name == "net_discover" then
			-- LAN discovery: {on}; returns the hosts found so far.
			BVNNet.discoveryPort = args.discovery_port or BVNNet.discoveryPort
			Net.Configure({game = "bleach_vs_naruto", discovery_port = BVNNet.discoveryPort})
			if args.on ~= nil then Net.Discover(args.on) end
			return {hosts = Net.Hosts()}
		elseif name == "net_bench" then
			-- Rollback snapshot cost of the current state: {n} saves, a load and a hash.
			Net.Track(_G)
			local n = args.n or 20
			local t0 = os.clock()
			for _ = 1, n do Net.Snapshot(0, "save") end
			local t1 = os.clock()
			Net.Snapshot(0, "load")
			local t2 = os.clock()
			local h = Net.Snapshot(0, "hash")
			local t3 = os.clock()
			return {objects = Net.Snapshot(0, "objects"), save_ms = (t1 - t0) * 1000 / n, load_ms = (t2 - t1) * 1000,
				hash_ms = (t3 - t2) * 1000, hash = h}
		elseif name == "net_synctest" then
			-- A rollback sync test of whatever runs now (start a battle first): {frames}.
			Net.Track(_G)
			return {ok = Net.SyncTest(args.frames or 7)}
		elseif name == "net_state" then
			local ses = BVNNet.session
			return {status = Net.Status(), phase = self.phase_name, mode = self.mode, team = self.team,
				started = ses and ses.started or false, frame = ses and ses.frame, desync = ses and ses.desync,
				hash = BVNNet.Hash(self), seed = BVNRuntime.seed, message = self.stage and self.stage.message,
				lua_kb = math.floor(collectgarbage("count"))}
		elseif name:sub(1, 6) == "musou_" then
			return self:MusouCommand(name, args)
		end
		return nil
	end,

	-- The musou player data in brief (agents and tests).
	MusouSummary = function()
		local team = {}
		for i, f in ipairs(BVNMusouData.Team()) do team[i] = {id = f.id, level = f.level, exp = f.exp} end
		local areas = {}
		for _, a in ipairs((BVNMusouData.Map(BVNMusouData.CurrentMapId()) or {areas = {}}).areas) do
			if BVNMusouData.CheckAreaIsOpen(a.id) then areas[#areas + 1] = {id = a.id, percent = BVNMusouData.AreaPercent(a.id)} end
		end
		return {money = BVNMusouData.Money(), area = BVNMusouData.CurrentAreaId(), team = team, fighters = #BVNMusouData.Fighters(),
			open = areas}
	end,

	-- Musou agent commands:
	--   musou_start {area, mission, team = {ids}, auto, ai_level, fresh, skip_intro}: a mission at once
	--     (default: the current area's next mission); fresh starts from new player data (written when the game next saves).
	--   musou_state: the mission, or the player data outside a mission.
	--   musou_debug {kill = "mooks" | "all" | "boss", hp, time, wave, qi}: test shortcuts in a mission.
	--   musou_data {money, level = {id = lv}, open = {area ids}, pass = {area, mission}, current, team = {ids},
	--     fighters = {ids}, save, reset}: edit the player data.
	--   musou_dialog {name = "state" | "select" | "confirm" | "alert"}: open a world map dialog.
	MusouCommand = function(self, name, args)
		local D = BVNMusouData
		if name == "musou_start" then
			if args.fresh then D.New() end
			if args.team then for i, id in ipairs(args.team) do D.AddFighter(id); D.SetTeam(i, id) end end
			if args.area then
				D.OpenArea(D.CurrentMapId(), args.area)
				D.SetCurrentArea(args.area)
			end
			local area = args.area or D.CurrentAreaId()
			local mission = args.mission and D.Mission(D.CurrentMapId(), area, tostring(args.mission)) or D.NextMission(area)
			if not mission then return {ok = false, error = "no mission"} end
			BVNTrans.Clear()
			self:StartMusou(mission, {auto = args.auto, aiLevel = args.ai_level})
			local b = self.battle
			if args.skip_intro then
				b.hud.ko.playing, b.hud.ko.cbs = false, {}
				b.startDone = true
			end
			return {ok = true, mission = mission.id, area = area, map = mission.map, waves = #mission.waves}
		elseif name == "musou_state" then
			local b = self.battle
			if b and b.musou then return b:Observe() end
			return {phase = self.phase_name, result = self.musou_result, data = BVNGame.MusouSummary()}
		elseif name == "musou_debug" then
			local b = self.battle
			if not (b and b.musou) then return {ok = false} end
			if args.kill then
				for _, f in ipairs(b.stageEnemies) do
					if f.alive and f.active and (args.kill == "all" or (args.kill == "boss") == (f.musouBoss == true)) then
						f.hp = 0
						f.alive = false
						b:OnDie(f)
						if not f:IsHurting() and f.state ~= 30 then f:PlayHurtDown() end
					end
				end
			end
			if args.hp then b.current.hp = args.hp end
			if args.qi then b.current.qi = args.qi end
			if args.time then b.gameTime = args.time * 30 end
			if args.wave then b.renderTimer = -1 end
			return {ok = true, state = b:Observe()}
		elseif name == "musou_data" then
			if args.reset then D.New() end
			if args.money then D.LoseMoney(D.Money()); D.AddMoney(args.money) end
			for _, id in ipairs(args.fighters or {}) do D.AddFighter(id) end
			if args.team then for i, id in ipairs(args.team) do D.AddFighter(id); D.SetTeam(i, id) end end
			for id, lv in pairs(args.level or {}) do
				local f = D.FighterData(id)
				if f then f:UpdateLevel(lv) end
			end
			for _, a in ipairs(args.open or {}) do D.OpenArea(D.CurrentMapId(), a) end
			if args.pass then
				local cur = D.CurrentAreaId()
				D.SetCurrentArea(args.pass.area)
				local m = D.Mission(D.CurrentMapId(), args.pass.area, tostring(args.pass.mission))
				if m then D.PassMission(m) end
				D.SetCurrentArea(cur)
			end
			if args.current then D.SetCurrentArea(args.current) end
			if args.save then D.Save() end
			return BVNGame.MusouSummary()
		elseif name == "musou_dialog" then
			local st = self.stage
			if not (st and st.name == "worldmap") then return {ok = false} end
			if args.name == "state" then BVNMusouDialog.Show(BVNMusouDialog.NewState())
			elseif args.name == "select" then BVNMusouDialog.Show(BVNMusouDialog.NewSelect(args.index or 1))
			elseif args.name == "confirm" then st:GotoMission(D.Area(D.CurrentMapId(), D.CurrentAreaId()))
			elseif args.name == "alert" then BVNMusouDialog.Alert("NOT OPEN", "暂未开放") end
			return {ok = true}
		end
		return nil
	end,
}
