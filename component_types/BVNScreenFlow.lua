-- The original stages between menus and fights: GameLoadingStage (boot),
-- LogoStage, HowToPlayStage, LoadingStage (the VS screen with the team order
-- choice, SelectIndexUI), WinnerStage, GameOverStage (continue / game over),
-- CongratulateStage and CreditsStage. Each New* returns a stage with
-- Update(g) / Draw(g); BVNGame switches between them. Not attached to any actor.
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})
local D = setmetatable({}, {__index = function(_, k) return BVNScreenDialog[k] end})
local WHITE = {255, 255, 255}
local ORDER = 10

local function faceImg(fv, kind)
	local u = fv and fv.urls
	local f = u and u[kind]
	return f and ("bvn/face/" .. f) or nil
end

local function stage(name, t)
	t.name = name
	t.phase = t.phase or name
	t.t = 0
	return t
end

-- Each update ticks the stage clock and its timers.
local function tick(st)
	st.t = st.t + 1
	if st.timers then
		for i = #st.timers, 1, -1 do
			local tm = st.timers[i]
			if st.t >= tm.at then
				table.remove(st.timers, i)
				tm.fn()
			end
		end
	end
end

local function later(st, ticks, fn)
	st.timers = st.timers or {}
	st.timers[#st.timers + 1] = {at = st.t + ticks, fn = fn}
end

-- Bounds of a movie frame's images (stage units).
local function bounds(m, f)
	local fr = m.frames[m.seq[(f or 0) + 1] or 1]
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	local i = 1
	while fr and i <= #fr do
		local e = fr[i]
		if type(e) == "number" then
			local img = m.imgs[e]
			local a, b, c, d, tx, ty = fr[i + 1], fr[i + 2], fr[i + 3], fr[i + 4], fr[i + 5], fr[i + 6]
			for _, p in ipairs({{0, 0}, {img[2], 0}, {0, img[3]}, {img[2], img[3]}}) do
				local x, y = a * p[1] + c * p[2] + tx, b * p[1] + d * p[2] + ty
				x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
			end
			i = i + 8
		else
			i = i + 1
		end
	end
	return x0, y0, x1, y1
end

BVNScreenFlow = {
	-- GameLoadingStage: the cover with its loading bar while the game starts.
	NewBoot = function(g)
		local st = stage("boot", {})
		function st:Update()
			tick(self)
			if self.t >= 40 then g:GoLogo() end
		end
		function st:Draw()
			local cover = S.Load("loading_cover")
			S.DrawFrame(cover, 0, nil, 1, ORDER, "world", {bar = function(m)
				S.DrawFrame(S.Load("loading_bar"), 0, m, 1, ORDER + 1, "world", {
					bar = function(bm) S.DrawFrame(S.Load("loading_bar_fill"), 0, S.Mul(bm, {math.min(1, self.t / 36), 0, 0, 1, 0, 0}), 1,
						ORDER + 1, "world") end,
					txt = function(tm, a, e)
						S.Text("游戏初始化：正在加载游戏资源", tm[5], tm[6], e.size, e.color, e.align, e.w, a, ORDER + 2)
					end})
			end})
		end
		return st
	end,

	-- LogoStage: $common$MC_logo from frame 2 to its COMPLETE, then the menu.
	NewLogo = function(g)
		local st = stage("logo", {clip = S.Clip("logo", 1, true)})
		BVNSound.Music(nil)
		function st:Update()
			tick(self)
			self.clip:Step()
			if self.clip.done then g:GoMenu() end
		end
		function st:Draw()
			S.Fill({0, 0, 0}, 255, ORDER - 1, "world")
			self.clip:Draw(nil, 1, ORDER, "world")
		end
		return st
	end,

	-- HowToPlayStage: the tutorial movie; back or a menu key jumps to "skip".
	NewHowToPlay = function(g)
		local st = stage("howtoplay", {clip = S.Clip("how2play", 1, true)})
		BVNSound.Music("bvn/bgm/back")
		-- setKeyText: player 1's keys (KyoKeyCode names).
		local keys = {txt_up = "W", txt_down = "S", txt_left = "A", txt_right = "D", txt_attack = "J", txt_jump = "K",
			txt_dash = "L", txt_skill = "U", txt_bisha = "I", txt_special = "O"}
		local slots = {}
		for k, v in pairs(keys) do
			slots[k] = function(m, a, e)
				S.Text(v, m[5] + (e.left or 0) * m[1], m[6], e.size * m[4], e.color, e.align, (e.w or 0) * m[1], a, ORDER + 1)
			end
		end
		function st:Update()
			tick(self)
			self.clip:Step()
			if not self.skipping and self.t > 6 and (S.Down("back", "menu") or S.Down("select", "menu")) then
				self.skipping = true
				self.clip:Goto("skip", true)
			end
			if self.clip.done then
				BVNScreen.Release()
				g:GoSelect()
			end
		end
		function st:Draw()
			S.Fill({0, 0, 0}, 255, ORDER - 1, "world")
			self.clip:Draw(nil, 1, ORDER, "world", slots)
		end
		return st
	end,

	-- LoadingStage: the VS screen. Each side's fighters as select bars with the
	-- assist below; in team modes the players choose the fighting order
	-- (SelectIndexUI / SelectIndexUIGroup), then the bar slides away and the fight starts.
	NewLoading = function(g, p1, p2, onGo)
		local st = stage("loading", {groups = {}, barY = 0, progress = 0, bg = S.Clip("loading_fight", 0, false)})
		BVNSound.Music("bvn/bgm/loading")
		local mode, team = g.mode, g.team
		local function group(side, pick)
			local gr = {side = side, x = side == 1 and 70 or 480, y = 85, fzx = side == 1 and -30 or 25, fzy = 325, items = {},
				assist = pick.assist, cur = 1, nextId = 1, finish = false, arrowX = side == 1 and -10 or 260}
			for i, id in ipairs(pick.team) do
				gr.items[i] = {id = id, fv = BVNMenu.FighterInfo(id), index = -1, y = (i - 1) * 100, fromY = (i - 1) * 100, t = 99}
			end
			return gr
		end
		st.groups[1] = group(1, p1)
		st.groups[2] = group(2, p2)
		local function sortOrder(gr)
			local list = {}
			for _, it in ipairs(gr.items) do list[#list + 1] = it end
			table.sort(list, function(a, b)
				local ai, bi = a.index == -1 and 10 or a.index, b.index == -1 and 10 or b.index
				if ai ~= bi then return ai < bi end
				return a.y < b.y
			end)
			return list
		end
		local function updateOrder(gr)
			local list = sortOrder(gr)
			for i, it in ipairs(list) do
				local ty = (i - 1) * 100
				if math.abs(ty - it.y) > 2 then it.fromY, it.t = it.y, 0 end
				it.y = ty
			end
			gr.items = list
		end
		local function selectIndex(gr, index, dir)
			local n = #gr.items
			if index < 1 then index = n end
			if index > n then index = 1 end
			if gr.items[index].index ~= -1 then
				if dir ~= 0 then return selectIndex(gr, index + dir, dir) end
				return
			end
			gr.cur = index
		end
		local function finishGroup(gr)
			gr.who = nil
			gr.finish = true
			updateOrder(gr)
			if gr.onFinish then gr.onFinish() end
		end
		local function allDone()
			if st.groups[1].finish and st.groups[2].finish and not st.orderDone then
				later(st, 60, function() st.orderDone = true; st:TryGo() end)
			end
		end
		local function keys(gr, who, after)
			gr.who = who
			gr.onFinish = function()
				if after then after() end
				allDone()
			end
		end
		local function auto(gr)
			local idx = {}
			for i = 1, #gr.items do idx[i] = i end
			for i = #idx, 2, -1 do
				local j = 1 + math.floor(BVNRuntime.RAND() * i)
				idx[i], idx[j] = idx[j], idx[i]
			end
			for n, i in ipairs(idx) do gr.items[i].index = n end
			finishGroup(gr)
			allDone()
		end
		if team and mode == "arcade" then
			keys(st.groups[1], 1)
			auto(st.groups[2])
		elseif team and mode == "pvp" then
			keys(st.groups[1], 1)
			keys(st.groups[2], 2)
		elseif team and (mode == "cpu" or mode == "watch") then
			keys(st.groups[1], 1, function() keys(st.groups[2], 1) end)
		else
			st.groups[1].finish, st.groups[2].finish = true, true
			allDone()
		end
		-- The load: the bar fills, the whole panel slides down 80 px in 1 s, then 2 s later the fight.
		function st:TryGo()
			if self.gone or not (self.orderDone and self.loadFin) then return end
			self.gone = true
			local order = {}
			for side = 1, 2 do
				local list = sortOrder(self.groups[side])
				order[side] = {}
				for i, it in ipairs(list) do order[side][i] = it.id end
			end
			BVNTrans.In(function() onGo(order[1], order[2]) end)
		end
		function st:Update()
			tick(self)
			self.bg:Step()
			if self.t == 1 then BVNTrans.Out(function() self.loading = true end) end
			if self.loading and not self.loaded then
				self.progress = math.min(1, self.progress + 1 / 30)
				if self.progress >= 1 then
					self.loaded, self.slideT = true, 0
					later(self, 60 + 120, function() self.loadFin = true; self:TryGo() end)
				end
			end
			if self.slideT then self.slideT = self.slideT + 1 end
			for _, gr in ipairs(self.groups) do
				for _, it in ipairs(gr.items) do it.t = it.t + 1 end
			end
			if self.confirm then
				if D.UpdateConfirm(self.confirm) then self.confirm = nil end
				return
			end
			if S.Down("back", "menu") then
				self.confirm = D.Confirm("BACK TITLE?", "返回到主菜单？", function() g:GoMenu() end, nil)
				return
			end
			for _, gr in ipairs(self.groups) do
				local who = gr.who
				if who and not gr.finish then
					if S.Down("up", who) then selectIndex(gr, gr.cur - 1, -1); S.Snd("snd_menu1") end
					if S.Down("down", who) then selectIndex(gr, gr.cur + 1, 1); S.Snd("snd_menu1") end
					if S.Down("select", who) then
						gr.items[gr.cur].index = gr.nextId
						gr.nextId = gr.nextId + 1
						S.Snd("snd_menu2")
						if gr.nextId > #gr.items - 1 then
							for _, it in ipairs(gr.items) do
								if it.index == -1 then it.index = gr.nextId end
							end
							finishGroup(gr)
						else
							updateOrder(gr)
							selectIndex(gr, 2, 1)
						end
					end
				end
			end
		end
		local function bar(side, fv, x, y, alpha, index, isAssist)
			local m = S.Load(side == 1 and "select_bar_p1" or "select_bar_p2")
			local tf = S.T(x, y)
			S.DrawFrame(m, 0, tf, alpha, ORDER + 2, "world", {["ct/ct"] = function(mm)
				local f = faceImg(fv, "face_big")
				if f then S.Image(f, mm, alpha, ORDER + 2, "world") end
			end})
			if fv then
				S.Text(fv.name or "", x + (side == 1 and 0 or 10), y + 40, 14, WHITE, side == 1 and "right" or "left", 243, alpha,
					ORDER + 3)
			end
			-- $loading$MC_selectText: 1st / 2nd / 3rd or "assist", at the bar's corner.
			local txt = S.Load("select_text")
			local f = isAssist and 3 or (index and index > 0 and index - 1)
			if txt and f then
				local w = txt.imgs[f + 1][2]
				local ax = isAssist and (side == 1 and -8 or 176) or (side == 1 and -8 or 252 - w)
				S.DrawFrame(txt, f, S.T(x + ax, y - 5), alpha, ORDER + 3, "world")
			end
		end
		function st:Draw()
			self.bg:Draw(nil, 1, ORDER, "world")
			local dy = self.slideT and S.Tw(self.slideT, 0, 80, 60, 0, S.Ease.quadOut) or 0
			for side, gr in ipairs(self.groups) do
				for _, it in ipairs(gr.items) do
					local y = it.t < 12 and S.Tw(it.t, it.fromY, it.y, 12, 0, S.Ease.quadOut) or it.y
					bar(side, it.fv, gr.x, gr.y + y + dy, 1, it.index)
				end
				if gr.assist then
					bar(side, BVNMenu.AssistInfo(gr.assist), gr.x + gr.fzx, gr.y + gr.fzy + dy, 1, nil, true)
				end
				if gr.who and not gr.finish then
					local arrow = S.Load(side == 1 and "select_arrow1" or "select_arrow2")
					local it = gr.items[gr.cur]
					if arrow and it then S.DrawFrame(arrow, 0, S.T(gr.x + gr.arrowX, gr.y + it.y + 30 + dy), 1, ORDER + 4, "world") end
				end
			end
			-- MC_selectUI's loading bar at (17, 555).
			S.DrawFrame(S.Load("loading_bar"), 0, S.T(17, 555 + dy), 1, ORDER + 4, "world", {
				bar = function(m) S.DrawFrame(S.Load("loading_bar_fill"), 0, S.Mul(m, {math.max(0.001, self.progress), 0, 0, 1, 0, 0}), 1,
					ORDER + 4, "world") end})
			if self.confirm then D.DrawConfirm(self.confirm, 1500, "ui") end
		end
		return st
	end,

	-- WinnerStage: the winning team's faces, the score, the winner's line; continue to the next stage.
	NewWinner = function(g, winnerId, team, says, score)
		local st = stage("winner", {clip = S.Clip("winner", 0, true)})
		BVNSound.Music(nil)
		BVNSound.Play("bvn/bgm/win", 128)
		later(st, 390, function() BVNSound.Music("bvn/bgm/winloop") end)
		local faces = {}
		local others = {}
		for _, id in ipairs(team) do
			if id ~= winnerId then others[#others + 1] = id end
		end
		faces[1] = winnerId
		for i, id in ipairs(others) do faces[i + 1] = id end
		if #team == 1 then faces = {team[1]} end
		st.say = (says or ""):gsub("|", "\n")
		function st:Update()
			tick(self)
			self.clip:Step()
			if self.clip.done and not self.ready then
				self.ready = true
				self.txt = S.Clip("winner_txt", 1, true)
			end
			if self.txt then self.txt:Step() end
			if self.confirm then
				if D.UpdateConfirm(self.confirm) then self.confirm = nil end
				return
			end
			if not self.ready or self.leaving then return end
			if S.Down("select", "menu") then
				self.leaving = true
				S.Snd("snd_menu2")
				BVNTrans.In(function() g:NextMission() end)
			elseif S.Down("back", "menu") then
				-- The EXIT button (mouse in the original).
				self.confirm = D.Confirm("BACK TITLE?", "返回到主菜单？", function() g:GoMenu() end, nil)
			end
		end
		function st:Draw()
			local slots = {}
			for i = 1, 3 do
				slots["f" .. (i - 1)] = function(m, a)
					local fv = faces[i] and BVNMenu.FighterInfo(faces[i])
					local f = faceImg(fv, "face_win")
					if f then S.Image(f, m, a, ORDER, "world") end
				end
			end
			slots.scoremc = function(m, a)
				local s = "SCORE " .. tostring(score or 0)
				local w = S.FontWidth(s)
				S.Font(s, -w / 2, -S.FontHeight() / 2, 1, a, ORDER + 1, "world", nil, m)
			end
			slots.txtmc = function(m, a)
				if not self.txt then return end
				self.txt:Draw(m, a, ORDER + 1, "world")
				if self.txt.done then
					local lines = select(2, self.say:gsub("\n", "")) + 1
					local h = lines * 18 * 1.3
					local p = S.Mul(m, {1, 0, 0, 1, 33, 10 + (90 - h) / 2})
					S.Text(self.say, p[5], p[6], 18, {0, 0, 0}, "center", 548, a, ORDER + 2)
				end
			end
			-- f1 / f2 stay hidden in single mode.
			if not faces[2] then slots.f1 = function() return "hide" end end
			if not faces[3] then slots.f2 = function() return "hide" end end
			self.clip:Draw(nil, 1, ORDER, "world", slots)
			if self.confirm then D.DrawConfirm(self.confirm, 1500, "ui") end
		end
		return st
	end,

	-- GameOverStage: "continue" (YES / NO under the loser), then "gameover" with the score.
	NewGameOver = function(g, loserId, score, showContinue)
		local st = stage(showContinue and "continue" or "gameover", {clip = S.Clip("game_over", 0, false)})
		BVNTrans.Clear()
		function st:ShowContinue()
			self.clip:Goto("continue", true)
			self.onDone = function() self.keys, self.arrow = {"btn_yes", "btn_no"}, "btn_yes" end
			BVNSound.Music("bvn/bgm/continue")
		end
		function st:ShowGameOver()
			self.phase = "gameover"
			self.clip:Goto("gameover", true)
			S.Snd("snd_gameover")
			BVNSound.Music(nil)
			self.showScore = true
			self.onDone = function() self.keys, self.arrow = {"btn_back"}, "btn_back" end
		end
		if showContinue then st:ShowContinue() else st:ShowGameOver() end
		function st:Update()
			tick(self)
			self.clip:Step()
			if self.clip.done and self.onDone then
				local f = self.onDone
				self.onDone = nil
				f()
			end
			if not self.keys then return end
			if self.arrow ~= "btn_back" then
				if S.Down("left", "menu") then self.arrow = "btn_yes"; S.Snd("snd_menu1") end
				if S.Down("right", "menu") then self.arrow = "btn_no"; S.Snd("snd_menu1") end
			end
			if S.Down("select", "menu") then
				S.Snd("snd_menu2")
				local a = self.arrow
				self.keys = nil
				if a == "btn_yes" then
					self.clip:Goto("continue_yes", true)
					self.onDone = function() g:Continue() end
				elseif a == "btn_no" then
					self.clip:Goto("continue_no", true)
					self.onDone = function() self:ShowGameOver() end
				else
					g:GoLogo()
				end
			end
		end
		function st:Draw()
			local pos = {}
			local slots = {
				ct_char = function(m, a)
					-- The loser (a fighter in its lose pose, 3x, in the original); here its win portrait.
					local fv = loserId and BVNMenu.FighterInfo(loserId)
					local f = faceImg(fv, "face_win")
					if f then
						local sz = S.Size(f)
						S.Image(f, S.Mul(m, {1, 0, 0, 1, -sz[1] / 2, -sz[2]}), a, ORDER, "world")
					end
				end,
				ct_score = function(m, a)
					if not self.showScore then return end
					local s = "SCORE " .. tostring(score or 0)
					S.Font(s, -S.FontWidth(s) / 2, 0, 1, a, ORDER + 1, "world", nil, m)
				end,
			}
			for _, k in ipairs({"btn_yes", "btn_no", "btn_back"}) do
				slots[k] = function(m) pos[k] = m end
			end
			self.clip:Draw(nil, 1, ORDER, "world", slots)
			if self.keys and pos[self.arrow] then
				local arrow = S.Load("slt_arrow")
				local m = pos[self.arrow]
				S.DrawFrame(arrow, math.floor(self.t / 2) % arrow.n, S.T(m[5], m[6]), 1, ORDER + 2, "world")
			end
		end
		return st
	end,

	-- CongratulateStage: the clear animation, then the message scrolls up over the cover.
	NewCongratulations = function(g, score)
		local st = stage("congratulations", {clip = S.Clip("congratulations", 1, true), uiY = 0, bgA = -1})
		BVNSound.Music("bvn/bgm/congratulation")
		function st:Update()
			tick(self)
			self.clip:Step()
			if self.clip.done and not self.text then
				local wt = S.Load("win_text")
				local _, y0, _, y1 = bounds(wt, 0)
				self.text = {y = 600, h = math.max(0, y1) + 120}
				self.scoreY = 600 + self.text.h + 100
				self.exitH = self.scoreY - 320
				self.group = D.Group({{label = "BACK", cn = "返回"}}, {x = 230, y = self.scoreY + S.FontHeight() + 100})
				self.group.keyEnable = false
				self.scrolling = true
			end
			if self.scrolling and self.t % 2 == 0 then
				if S.Down("back", "menu") then
					self.uiY = -self.exitH
					S.Snd("snd_menu1")
				end
				self.uiY = self.uiY - 1
				self.bgA = self.bgA + 0.005
				if self.uiY < -self.exitH then
					self.scrolling = false
					self.bgA = 1
					self.group.keyEnable = true
				end
			elseif self.scrolling and S.Down("back", "menu") then
				self.uiY = -self.exitH
			end
			if self.group then
				local ev = self.group:Update()
				if ev and ev.select == "BACK" then g:GoLogo() end
			end
		end
		function st:Draw()
			S.Fill({0, 0, 0}, 255, ORDER - 2, "world")
			if self.bgA > 0 then
				local sz = S.Size("bvn/ui/misc/cover_bg.png")
				S.Image("bvn/ui/misc/cover_bg.png", {800 / sz[1], 0, 0, 600 / sz[2], 0, 0}, math.min(1, self.bgA), ORDER - 1, "world")
			end
			self.clip:Draw(S.T(0, self.uiY), 1, ORDER, "world")
			if self.text then
				S.DrawFrame(S.Load("win_text"), 0, S.T(0, self.text.y + self.uiY), 1, ORDER, "world")
				local s = "FINAL SCORE " .. tostring(score or 0)
				S.Font(s, (800 - S.FontWidth(s)) / 2, self.scoreY + self.uiY, 1, 1, ORDER + 1, "world")
				self.group:Draw(0, self.uiY, ORDER + 1, "world")
			end
		end
		return st
	end,

	-- CreditsStage: the credits text over the cover, BACK to the menu.
	NewCredits = function(g)
		local st = stage("credits", {})
		BVNSound.Music("bvn/bgm/back")
		st.group = D.Group({{label = "BACK", cn = "返回"}}, {y = 600 - 150})
		st.lines = {
			"原作：剑jian",
			"企划：数字化流天、L、社长、Diazynez",
			"程序：Nagisa、Diazynez、BearBrine、パチュリー",
			"美术：数字化流天、L、V.临界幻想、小数、Azreal、影、赤炎、小海、主流、曦城子、酸菜鱼、",
			"          卡布托、Future、Nagisa、惊鸿、杯梓、星空幻梦、花里、Just...",
			"测试：ゞ影孞&僮畵ヾ、成环、cat232181、无宇逆风、叽咕村夫、默默、小皮、山之叟、欲上天、",
			"          LOTTU、肥宅正品、ppx、七米、星空幻梦、逝时_流光...",
			"贡献：灰原·银、Grimm（WEB发行）",
			"对接：Lemon_kenbai、黑羽、诺斯给给...",
			"运营：多情丶回忆、FZCL石头门、纯白暮弦、风之旅人、寒窗听雨、黑猫、老秦、凌辰夜风、",
			"          萌新、某个热爱理科的死宅、天双、御礼...",
		}
		function st:Update()
			tick(self)
			local ev = self.group:Update()
			if ev and ev.select == "BACK" then g:GoMenu() end
		end
		function st:Draw()
			local sz = S.Size("bvn/ui/misc/cover_bg.png")
			S.Image("bvn/ui/misc/cover_bg.png", {800 / sz[1], 0, 0, 600 / sz[2], 0, 0}, 1, ORDER, "world")
			for i, line in ipairs(self.lines) do
				S.Text(line, 30, 25 + (i - 1) * 27, 17, {255, 255, 0}, "left", nil, 1, ORDER + 1)
			end
			self.group:Draw(0, 0, ORDER + 1, "world")
		end
		return st
	end,
}
