-- The original title menu (MenuStage + MenuBtnGroup / MenuBtn) and fighter
-- select (SelectFighterStage: SelectFighterListCtrl, SelectFighterCursorCtrl,
-- SelecterItemUI, SelectedFighterGroup, SelectMapUI and the select-mode
-- flows), drawn from the converted interface movies on the 800x600 stage.
-- Also the fighter / assist lookups the battle uses. Not attached to any actor;
-- BVNGame owns the current stage and calls stage:Update(g) / stage:Draw(g).
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})
local WHITE = {255, 255, 255}
local ORDER = 10

local function fighterList() return BVNConfig.fighter.fighter.data end
local function assistList() return BVNConfig.assist.fighter.data end

-- Menus (GameInterfaceManager.getGameMenu, PC). SURVIVOR is commented out there
-- ("暂未开放"); it is listed here where that comment sits. MORE GAMES and EXIT are
-- web / desktop-shell entries and are left out; the Flash LAN PLAY entry becomes
-- NET PLAY, Pocket2D netplay (BVNNet).
local MENU = {
	{txt = "TEAM PLAY", cn = "小队模式", children = {
		{txt = "TEAM ACRADE", cn = "闯关模式"}, {txt = "TEAM VS PEOPLE", cn = "2P对战"},
		{txt = "TEAM VS CPU", cn = "对战电脑"}, {txt = "TEAM WATCH", cn = "观战电脑"}}},
	{txt = "SINGLE PLAY", cn = "单人模式", children = {
		{txt = "SINGLE ACRADE", cn = "闯关模式"}, {txt = "SINGLE VS PEOPLE", cn = "2P对战"},
		{txt = "SINGLE VS CPU", cn = "对战电脑"}, {txt = "SINGLE WATCH", cn = "观战电脑"}}},
	{txt = "MUSOU PLAY", cn = "无双模式", children = {{txt = "MUSOU ACRADE", cn = "无双模式"}}},
	{txt = "NET PLAY", cn = "联机对战"},
	{txt = "SURVIVOR", cn = "挑战模式"},
	{txt = "OPTION", cn = "游戏设置"},
	{txt = "TRAINING", cn = "练习模式"},
	{txt = "CREDITS", cn = "制作组"},
}

-- MenuBtnGroup.getFucByLabel: label -> game mode (mode, team, how-to-play first).
local MODES = {
	["TEAM ACRADE"] = {mode = "arcade", team = true, how = true},
	["TEAM VS PEOPLE"] = {mode = "pvp", team = true},
	["TEAM VS CPU"] = {mode = "cpu", team = true},
	["TEAM WATCH"] = {mode = "watch", team = true},
	["SINGLE ACRADE"] = {mode = "arcade", team = false, how = true},
	["SINGLE VS PEOPLE"] = {mode = "pvp", team = false},
	["SINGLE VS CPU"] = {mode = "cpu", team = false},
	["SINGLE WATCH"] = {mode = "watch", team = false},
	["SURVIVOR"] = {mode = "survivor", team = false},
	["TRAINING"] = {mode = "training", team = false},
}

-- Title stage -------------------------------------------------------------------------------

local Title = {}
Title.__index = Title

local function menuBtn(o, child)
	local b = {label = o.txt, cn = o.cn, child = child, height = child and 55 or 75, x = 0, y = 0, fx = 0, fy = 0, moveT = 99,
		sx = 1, sxFrom = 1, sxT = 99, sxDelay = 0, bgVisible = false, bgT = 99, open = false, selT = nil}
	if o.children then
		b.children = {}
		for j, c in ipairs(o.children) do
			local cb = menuBtn(c, true)
			cb.index = j - 1
			b.children[j] = cb
		end
	end
	return b
end

local function btnPos(b)
	local k = math.min(1, b.moveT / 12)
	return b.fx + (b.x - b.fx) * S.Ease.quadOut(k), b.fy + (b.y - b.fy) * S.Ease.quadOut(k)
end

local function btnScale(b)
	if b.sxT >= 999 then return b.sx end
	return S.Tw(b.sxT, b.sxFrom, b.sx, 12, b.sxDelay, S.Ease.backOut)
end

function Title:SetBtns(tween)
	local lx, ly = 0, 0
	for _, b in ipairs(self.btns) do
		local px, py = btnPos(b)
		b.fx, b.fy = px, py
		b.x, b.y = lx, ly
		b.moveT = tween and 0 or 99
		lx, ly = lx - 40, ly + b.height + 5
		if self.showing == b then
			for j, cb in ipairs(b.children) do
				cb.x, cb.y, cb.fx, cb.fy, cb.moveT = lx, ly, lx, ly, 99
				if tween then cb.sxFrom, cb.sx, cb.sxT, cb.sxDelay = 0.01, 1, 0, (j - 1) * 2.4 end
				lx, ly = lx - 40, ly + cb.height + 5
			end
		end
	end
end

function Title:Hover(b, scroll)
	if self.hover == b then return end
	if self.hover and not self.hover.open then self.hover.bgVisible = false end
	if not b.open and not b.bgVisible then
		b.bgVisible, b.bgT = true, 0
		S.Snd("snd_menu1")
	end
	self.hover = b
	if self.showing then
		for j, cb in ipairs(self.showing.children) do
			if cb == b then
				self.index = j - 1
				return
			end
		end
	end
	for i, tb in ipairs(self.btns) do
		if tb == b then self.index = i - 1 end
	end
	if scroll ~= false then
		-- moveScroll (7 buttons or more): the list slides so the hovered one stays in view.
		local n = #self.btns
		local stepX, stepY = (780 - 470) / n, (590 - 100) / n
		self.gFrom = {self:GroupPos()}
		self.gTo = {self.index * (stepX + 40) * 0.1 + 470, self.index * (stepY - 80) + 100}
		self.gT = 0
	end
end

function Title:GroupPos()
	if not self.gTo then return 470, 100 end
	local k = S.Ease.quadOut(math.min(1, self.gT / 12))
	return self.gFrom[1] + (self.gTo[1] - self.gFrom[1]) * k, self.gFrom[2] + (self.gTo[2] - self.gFrom[2]) * k
end

function Title:ShowBtns()
	self.clip:Goto("menu", true)
	S.Snd("snd_menu5")
	self.btns = {}
	for i, o in ipairs(MENU) do
		local b = menuBtn(o, false)
		b.index = i - 1
		self.btns[i] = b
	end
	self:SetBtns(false)
	-- fadIn(0.2, 0.04): each button opens from scaleX 0.01.
	for i, b in ipairs(self.btns) do b.sxFrom, b.sx, b.sxT, b.sxDelay = 0.01, 1, 0, (i - 1) * 2.4 end
	self.index = 0
	self:Hover(self.btns[1])
	self.enableAt = self.t + 24
	self.phase = "menu"
end

function Title:CloseChildren(setBtns, tween)
	local p = self.showing
	for _, cb in ipairs(p.children) do
		if self.hover == cb then self.hover = nil end
	end
	p.open = false
	self.showing = nil
	if setBtns then self:SetBtns(tween) end
end

function Title:Toggle(b)
	if self.showing then
		local same = b == self.showing
		if not same then self.showing.bgVisible = false end
		self:CloseChildren(same, same)
		if same then return end
	end
	self.showing = b
	self:SetBtns(true)
	b.open = true
	self:Hover(b.children[1])
end

function Title:Select(g, b)
	if b.children then
		self:Toggle(b)
		return
	end
	-- MenuBtn.select: alpha from -1 back to 1 in 1 s (Elastic.easeOut), then the action.
	self.enabled = false
	b.selT = 0
	S.Snd("snd_menu2")
	self.pending = {b = b, at = self.t + 60}
end

function Title:Run(g, label)
	local m = MODES[label]
	if m then
		g.mode, g.team = m.mode, m.team
		if m.mode == "arcade" or m.mode == "survivor" then g:ResetMission() end
		if m.how then g:GoHowToPlay() else g:GoSelect() end
	elseif label == "MUSOU ACRADE" then
		g.mode, g.team = "musou", true
		g:GoWorldMap()
	elseif label == "NET PLAY" then
		g:Go(BVNNet.New(g))
	elseif label == "OPTION" then
		g:GoOption()
	elseif label == "CREDITS" then
		g:GoCredits()
	end
end

function Title:Update(g)
	self.t = self.t + 1
	self.clip:Step()
	if not self.btns then
		-- Any key (after 0.8 s) shows the menu.
		if self.t > 48 and S.AnyKey() then self:ShowBtns() end
		return
	end
	for _, b in ipairs(self.btns) do
		b.moveT, b.sxT, b.bgT = b.moveT + 1, b.sxT + 1, b.bgT + 1
		if b.selT then b.selT = b.selT + 1 end
		for _, cb in ipairs(b.children or {}) do
			cb.moveT, cb.sxT, cb.bgT = cb.moveT + 1, cb.sxT + 1, cb.bgT + 1
			if cb.selT then cb.selT = cb.selT + 1 end
		end
	end
	if self.gT then self.gT = self.gT + 1 end
	if self.pending and self.t >= self.pending.at then
		local p = self.pending
		self.pending = nil
		p.b.selT = nil
		self.enabled = true
		self:Run(g, p.b.label)
		return
	end
	if not self.enabled or self.t < self.enableAt then return end
	local list = self.showing and self.showing.children or self.btns
	if S.Down("up", "menu") then
		self.index = self.index - 1
		if self.index < 0 then self.index = #list - 1 end
		self:Hover(list[self.index + 1])
	end
	if S.Down("down", "menu") then
		self.index = self.index + 1
		if self.index > #list - 1 then self.index = 0 end
		self:Hover(list[self.index + 1])
	end
	if S.Down("select", "menu") then
		self:Select(g, list[self.index + 1])
	elseif S.Down("back", "menu") and self.showing then
		self.index = self.showing.index
		self:CloseChildren(true, true)
	end
end

function Title:DrawBtn(b, gx, gy)
	local x, y = btnPos(b)
	x, y = gx + x, gy + y
	local sx = btnScale(b)
	local alpha = 1
	if b.selT then alpha = math.max(0, math.min(1, -1 + 2 * S.Ease.elasticOut(math.min(1, b.selT / 60)))) end
	local tf = {sx, 0, 0, 1, x, y}
	local bg = S.Load("menubtn_bg")
	if (b.bgVisible or b.open) and bg then
		local bsx, bsy = 1, 1
		if b.child then bsx, bsy = 0.9, 0.75 end
		local k = S.Tw(b.bgT, 0.01, 1, 12, 0, S.Ease.quadOut)
		local btf = S.Mul(tf, {bsx * k, 0, 0, bsy, 0, -5})
		S.DrawFrame(bg, (b.child or b.open) and 1 or 0, btf, alpha, ORDER + 2, "world")
		-- The Chinese caption sits inside the highlight (MenuBtn: x 10, y 43, size 18).
		if k > 0.9 then
			local p = S.Mul(btf, {1, 0, 0, 1, 10, 43})
			S.Text(b.cn, p[5], p[6], 18 * bsy, WHITE, "left", nil, alpha, ORDER + 3)
		end
	end
	local scale = b.child and 0.75 or 1
	local w = S.FontWidth(b.label, scale)
	-- Children and open parents: red +50, green / blue -30 (ColorTransform offsets).
	local tint = (b.child or b.open) and {255, 205, 205} or nil
	S.Font(b.label, -w / 2, 0, scale, alpha, ORDER + 3, "world", tint, tf)
end

function Title:Draw(g)
	local gx, gy
	self.clip:Draw(nil, 1, ORDER, "world", {btnct = function(m)
		if not self.btns then return end
		gx, gy = self:GroupPos()
		for _, b in ipairs(self.btns) do
			self:DrawBtn(b, m[5] + gx, m[6] + gy)
			if self.showing == b then
				for _, cb in ipairs(b.children) do self:DrawBtn(cb, m[5] + gx, m[6] + gy) end
			end
		end
	end})
	-- Version label, bottom right (MenuStage: black, size 18).
	S.Text(BVNMenu.VERSION or "", 0, 600 - 32, 18, {0, 0, 0}, "right", 800 - 15, 1, ORDER + 1)
end

-- Select stage ------------------------------------------------------------------------------

-- ISelectModeFlow.resolveNextStep: {action, next step}.
local FLOWS = {
	arcade = {[0] = {"fighter", 1}, [1] = {"assist", 3}, [3] = {"arcade", -1}},
	musou = {[0] = {"fighter", 1}, [1] = {"assist", 3}, [3] = {"musou", -1}},
	vscpu = {[0] = {"fighter", 1}, [1] = {"p2_by_p1", 2}, [2] = {"assist", 3}, [3] = {"p2_by_p1", 4}, [4] = {"map", 5},
		[5] = {"finish", -1}},
	vspeople = {[0] = {"fighter", 1}, [1] = {"assist", 3}, [3] = {"map", 5}, [5] = {"finish", -1}},
}

local Select = {}
Select.__index = Select

local function info(id, assist)
	if assist then return BVNMenu.AssistInfo(id) end
	return BVNMenu.FighterInfo(id)
end

-- GameLogic.canSelectFighter / canSelectAssist, plus "converted on this machine".
local function selectable(id, assist)
	return id and not id:find("random") and BVNMenu.Available(id, assist)
end

function Select:Flow()
	local mode = self.g.mode
	if mode == "pvp" then return FLOWS.vspeople end
	if mode == "cpu" or mode == "watch" or mode == "training" then return FLOWS.vscpu end
	if mode == "musou" then return FLOWS.musou end
	return FLOWS.arcade
end

function Select:Later(ticks, fn)
	self.timers[#self.timers + 1] = {at = self.t + ticks, fn = fn}
end

function Select:NextStep()
	local a = self.flow[self.step]
	if not a then return end
	if a[2] >= 0 then self.step = a[2] end
	local act = a[1]
	if act == "fighter" then
		self:InitList(false)
	elseif act == "p2_by_p1" then
		-- ENABLE_P2_WITH_P1_INPUT: player 1 now picks for player 2.
		local p1 = self.slts[1]
		if p1 then p1.cursorHidden, p1.enabled = true, false end
		self:InitSelecter(2)
		self.slts[2].who = 1
	elseif act == "assist" then
		self:FadeOutList(function() self:InitList(true) end)
	elseif act == "map" then
		self:FadeOutList(function() self:InitMap() end)
	else
		self:Finish(act)
	end
end

function Select:Clear()
	self.items, self.cells, self.more = {}, {}, {}
	self.slts = {}
	self.map = nil
end

-- SelectFighterListCtrl.buildList: cells fly in from the centre (0.3 s, random delay).
function Select:InitList(assist)
	self:Clear()
	self.assist = assist
	local cfg = BVNUIData.select
	local list = assist and cfg.assistList or cfg.charList
	self.listCfg = list
	local L = cfg.layout
	local gapX = list.HCount > 1 and (L.width - 50 - L.left - L.right) / (list.HCount - 1) or 0
	local gapY = list.VCount > 1 and (L.height - 50 - L.top - L.bottom) / (list.VCount - 1) or 0
	for _, c in ipairs(list.list) do
		local fv = info(c.id, assist)
		if fv then
			local it = {cell = c, fv = fv, x = L.x + L.left + gapX * c.x + c.offset[1], y = L.y + L.top + gapY * c.y + c.offset[2],
				fromX = 370, fromY = 270, t = 0, dur = 18, delay = math.floor(BVNRuntime.RAND() * 12), ease = S.Ease.backOut, s0 = 0,
				s1 = 1}
			self.items[#self.items + 1] = it
			self.cells[c.x .. "," .. c.y] = it
		end
	end
	if not assist then
		self.picks = {{team = {}}, (self.flow ~= FLOWS.arcade and self.flow ~= FLOWS.musou) and {team = {}} or nil}
	end
	self.inputOn = false
	self:Later(30, function() self:InitSelecters() end)
end

function Select:FadeOutList(back)
	self.inputOn = false
	for _, it in ipairs(self.items) do
		local x, y = self:ItemPos(it)
		it.fromX, it.fromY, it.x, it.y = x, y, 370, 270
		it.t, it.dur, it.delay, it.ease, it.s0, it.s1 = 0, 12, math.floor(BVNRuntime.RAND() * 6), S.Ease.quadOut, 1, 0
	end
	self.more = {}
	self:Later(18, back)
end

function Select:ItemPos(it)
	local k = S.Tw(it.t, 0, 1, it.dur, it.delay, it.ease)
	local s = it.s0 + (it.s1 - it.s0) * k
	return it.fromX + (it.x - it.fromX) * k, it.fromY + (it.y - it.fromY) * k, s
end

function Select:InitSelecters()
	self.inputOn = true
	if self.flow == FLOWS.vspeople then
		self:InitSelecter(1)
		self:InitSelecter(2)
		self.twoFin = false
	else
		self:InitSelecter(1)
	end
end

-- SelectUIFactory.createSelecter + SelectFighterStage.initSelecterP1/P2.
function Select:InitSelecter(side)
	local slt = {side = side, who = side, x = 0, y = 0, moreX = 0, moreY = 0, times = 0, enabled = true,
		count = (self.g.team and not self.assist) and 3 or 1, assist = self.assist, group = {uis = {}}, selT = nil}
	slt.pick = self.picks[side]
	self.slts[side] = slt
	self:GroupAdd(slt, nil)
	self:MoveSlt(slt, side == 1 and 0 or 9, 0, true)
end

function Select:IsSelected(slt, id)
	local pk = slt.pick
	if not pk then return false end
	if slt.assist then return pk.assist == id end
	for _, t in ipairs(pk.team) do
		if t == id then return true end
	end
	return false
end

function Select:CheckSelected(slt, it)
	if not it.cell then return self:IsSelected(slt, it.fv.id) end
	for _, id in ipairs(it.cell.more or {}) do
		if self:IsSelected(slt, id) then return true end
	end
	return self:IsSelected(slt, it.cell.id)
end

function Select:HLine(startX, Y)
	local k = 0
	local H = self.listCfg.HCount
	while true do
		local X = startX + k
		if X >= 0 and X < H then
			local it = self.cells[X .. "," .. Y]
			if it then return it end
		end
		if k == 0 then k = 1
		elseif k > 0 then k = -k
		else
			if k < -H then return nil end
			k = -k + 1
		end
	end
end

-- SelectFighterCursorCtrl.moveSlt (with its search quirks).
function Select:MoveSlt(slt, x, y, fix)
	local H, V = self.listCfg.HCount, self.listCfg.VCount
	local sf = self.cells[x .. "," .. y]
	local up, down = false, false
	if not sf or self:CheckSelected(slt, sf) then
		if not fix then return true end
		if x > slt.x then
			for i = 0, H - 1 do
				local j = x + i
				if j > H - 1 then j = j - H end
				sf = self.cells[j .. "," .. slt.y]
				if sf and not self:CheckSelected(slt, sf) then break end
			end
		end
		if x < slt.x then
			for i = 0, H - 1 do
				local j = x - i
				if j < 0 then j = H + j end
				sf = self.cells[j .. "," .. slt.y]
				if sf and not self:CheckSelected(slt, sf) then break end
			end
		end
		if y > slt.y then
			down = true
			if y > V - 1 then y = 0 end
			for i = y, V - 1 do
				sf = self:HLine(slt.x, i)
				if sf then break end
			end
		end
		if y < slt.y then
			up = true
			if y < 0 then y = V - 1 end
			for i = y, 0, -1 do
				sf = self:HLine(slt.x, i)
				if sf then break end
			end
		end
	end
	if not sf then return false end
	slt.x, slt.y = sf.cell.x, sf.cell.y
	if self:CheckSelected(slt, sf) then
		if up or down then
			local ok = self:MoveSlt(slt, slt.x + 1, slt.y, true)
			if not ok then
				if up then self:MoveSlt(slt, slt.x, slt.y - 1, true) end
				if down then self:MoveSlt(slt, slt.x, slt.y + 1, true) end
			end
		end
		return true
	end
	self:MoveTo(slt, sf)
	return true
end

function Select:MoveTo(slt, sf)
	slt.randoms = nil
	slt.x, slt.y = sf.cell.x, sf.cell.y
	slt.item = sf
	slt.current = sf.fv
	self:GroupUpdate(slt, slt.current)
	self:CheckRandom(slt)
	self:ShowMore(slt, sf)
end

-- Random cells cycle through the selectable fighters of their series (every other UI frame).
function Select:CheckRandom(slt)
	local fv = slt.current
	if not (fv and fv.id:find("random")) then return end
	local list = {}
	local src = slt.assist and assistList() or fighterList()
	for _, d in ipairs(src) do
		local okType = (fv.comic_type or -1) == -1 or (d.comic_type or 0) == fv.comic_type
		if okType and selectable(d.id, slt.assist) and (slt.assist or not self:IsSelected(slt, d.id)) then
			list[#list + 1] = d
		end
	end
	slt.randoms = list
	slt.randFrame = 0
	self:RenderRandom(slt)
end

function Select:RenderRandom(slt)
	local r = slt.randoms
	if not r or #r == 0 then return end
	if slt.randFrame > 0 then
		slt.randFrame = 0
		return
	end
	slt.randFrame = slt.randFrame + 1
	slt.current = r[1 + math.floor(BVNRuntime.RAND() * #r)]
	self:GroupUpdate(slt, slt.current)
end

local MORE_POS = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}, {-1, -1}, {1, -1}, {-1, 1}, {1, 1}}

-- Alternate forms open around the hovered cell (showMoreFighters).
function Select:ShowMore(slt, sf)
	if slt.showingMore == sf then return end
	local old = self.more[slt.side]
	if old then
		for _, it in ipairs(old.items) do
			it.fromX, it.fromY, it.x, it.y = it.x, it.y, it.fromX, it.fromY
			it.t, it.dur, it.delay, it.ease, it.hiding = 0, 6, 0, S.Ease.quadOut, true
		end
		self.closing = self.closing or {}
		self.closing[#self.closing + 1] = {items = old.items, at = self.t + 6}
		self.more[slt.side] = nil
	end
	self:SetMoreEnabled(slt, false)
	local ids = sf.cell.more
	if not ids or #ids < 1 then return end
	local items = {}
	local posSN = 0
	for _, fid in ipairs(ids) do
		local fv = info(fid, slt.assist)
		if fv then
			local pos, mx, my
			while not pos do
				local p = MORE_POS[posSN % 8 + 1]
				posSN = posSN + 1
				local x, y = sf.x + p[1] * 65, sf.y + p[2] * 65
				if x >= 0 and x <= 800 and y >= 0 and y <= 600 then pos, mx, my = p, x, y end
			end
			items[#items + 1] = {fv = fv, isMore = true, pos = pos, fromX = sf.x, fromY = sf.y, x = mx, y = my, t = 0, dur = 12,
				delay = #items * 0.6, ease = S.Ease.backOut, s0 = 1, s1 = 1}
		end
	end
	self.more[slt.side] = {items = items, owner = sf}
	self:SetMoreEnabled(slt, true, sf)
end

function Select:SetMoreEnabled(slt, on, sf)
	slt.moreOn = on
	if on then
		slt.moreX, slt.moreY = 0, 0
		slt.showingMore = sf
	else
		slt.showingMore = nil
	end
end

function Select:MoveMore(slt, x, y)
	local m = self.more[slt.side]
	if not m or #m.items < 1 then return false end
	if x == 0 and y == 0 and slt.showingMore then
		slt.moreX, slt.moreY = 0, 0
		slt.item = slt.showingMore
		slt.current = slt.showingMore.fv
		self:GroupUpdate(slt, slt.current)
		return true
	end
	for _, it in ipairs(m.items) do
		if it.pos[1] == x and it.pos[2] == y then
			if self:IsSelected(slt, it.fv.id) then return false end
			slt.randoms = nil
			slt.moreX, slt.moreY = x, y
			slt.item = it
			slt.current = it.fv
			self:GroupUpdate(slt, slt.current)
			return true
		end
	end
	return false
end

function Select:MoveSelecter(slt, dx, dy)
	if slt.moreOn then
		if self:MoveMore(slt, slt.moreX + dx, slt.moreY + dy) then return end
		self:SetMoreEnabled(slt, false)
	end
	self:MoveSlt(slt, slt.x + dx, slt.y + dy, true)
end

-- SelectedFighterGroup: the picked bars stack upwards, smaller and fainter.
function Select:GroupAdd(slt, fv)
	local uis = slt.group.uis
	local n = #uis
	local addy = 20 - (n - 1) * 3
	local ty = n * -20
	local alpha = 0.7 - (n - 1) * 0.3
	local scale = 0.85 - (n - 1) * 0.15
	for _, ui in ipairs(uis) do
		ui.from = {ui.y, ui.a, ui.s}
		ui.to = {ty, alpha, scale}
		ui.t = 0
		ui.y, ui.a, ui.s = ty, alpha, scale
		ty, alpha, scale = ty + addy, alpha + 0.3, scale + 0.15
	end
	uis[#uis + 1] = {fv = fv, y = 0, a = 1, s = 1, from = {50, 1, 1}, to = {0, 1, 1}, t = 0, delay = 3}
end

function Select:GroupUpdate(slt, fv)
	local uis = slt.group.uis
	if uis[#uis] and fv then uis[#uis].fv = fv end
end

-- SelecterItemUI.select.
function Select:DoSelect(slt)
	if not slt.current then return end
	local pk = slt.pick
	if slt.assist then pk.assist = slt.current.id
	else pk.team[slt.times + 1] = slt.current.id end
	slt.times = slt.times + 1
	if slt.times < slt.count then self:GroupAdd(slt, slt.current) end
	slt.enabled = false
	slt.selT = 0
	-- updateRandom: picked fighters leave the random pool.
	if slt.randoms then
		for i = #slt.randoms, 1, -1 do
			if self:IsSelected(slt, slt.randoms[i].id) then table.remove(slt.randoms, i) end
		end
	end
	S.Snd("snd_menu2")
end

-- playerSeltBack, when the cursor's select animation ends.
function Select:SelectDone(slt)
	if slt.times < slt.count then slt.enabled = true end
	if slt.times >= slt.count then
		if self.flow == FLOWS.vspeople then
			local other = self.slts[3 - slt.side]
			if other and other.times >= other.count and not self.twoFin then
				self.twoFin = true
				self:NextStep()
			end
		else
			self:NextStep()
		end
		-- selt.destroy(): the cursor and its bars go away.
		if self.slts[slt.side] == slt then self.slts[slt.side] = nil end
		slt.dead = true
	else
		if not slt.randoms then
			self:MoveSlt(slt, slt.x + (slt.side == 1 and 1 or -1), slt.y, true)
		end
	end
end

-- SelectMapUI.
function Select:InitMap()
	self:Clear()
	local maps = {}
	for _, d in ipairs(BVNConfig.map.map.data) do
		if d.id == "random" or BVNMaps[d.id] then maps[#maps + 1] = d end
	end
	self.map = {maps = maps, cur = 1, t = 0, enabled = false}
	self.inputOn = false
	self:Later(18, function()
		if self.map then self.map.enabled = true end
		self.inputOn = true
	end)
end

function Select:Finish(act)
	local g = self.g
	if self.finished then return end
	self.finished = true
	local picks = self.picks
	if act == "arcade" then
		if g.mode == "survivor" then
			g:StartSurvivor(picks)
		else
			g:InitMission(picks[1])
			g:LoadGame()
		end
	elseif act == "musou" then
		g:GoWorldMap()
	else
		g.selectMap = self.mapId
		g.p1Select, g.p2Select = picks[1], picks[2]
		g:LoadGame()
	end
end

function Select:Update(g)
	self.t = self.t + 1
	self.bg:Step()
	for i = #self.timers, 1, -1 do
		local tm = self.timers[i]
		if self.t >= tm.at then
			table.remove(self.timers, i)
			tm.fn()
		end
	end
	for _, it in ipairs(self.items) do it.t = it.t + 1 end
	for _, m in pairs(self.more) do
		for _, it in ipairs(m.items) do it.t = it.t + 1 end
	end
	if self.closing then
		for i = #self.closing, 1, -1 do
			local c = self.closing[i]
			for _, it in ipairs(c.items) do it.t = it.t + 1 end
			if self.t >= c.at then table.remove(self.closing, i) end
		end
	end
	for _, slt in pairs(self.slts) do
		for _, ui in ipairs(slt.group.uis) do ui.t = ui.t + 1 end
		if slt.selT then
			slt.selT = slt.selT + 1
			-- MC_selectItemMc "select": 9 frames at 30 fps, then the frame script.
			if slt.selT >= 18 then
				slt.selT = nil
				self:SelectDone(slt)
			end
		end
	end
	if self.map then self.map.t = self.map.t + 1 end
	if self.confirm then
		if BVNScreenDialog.UpdateConfirm(self.confirm) then self.confirm = nil end
		return
	end
	if S.Down("back", "menu") then
		self.confirm = BVNScreenDialog.Confirm("BACK TITLE?", "返回到主菜单？", function() g:GoMenu() end, nil)
		return
	end
	if not self.inputOn or self.finished then return end
	-- UI frames run at 30 fps: random cells refresh on every UI frame.
	local uiFrame = self.t % 2 == 0
	for side = 1, 2 do
		local slt = self.slts[side]
		if slt and slt.enabled then
			if uiFrame then self:RenderRandom(slt) end
			local who = slt.who
			if S.Down("up", who) then self:MoveSelecter(slt, 0, -1); S.Snd("snd_menu1") end
			if S.Down("down", who) then self:MoveSelecter(slt, 0, 1); S.Snd("snd_menu1") end
			if S.Down("left", who) then self:MoveSelecter(slt, -1, 0); S.Snd("snd_menu1") end
			if S.Down("right", who) then self:MoveSelecter(slt, 1, 0); S.Snd("snd_menu1") end
			if S.Down("select", who) then self:DoSelect(slt) end
		end
	end
	local mp = self.map
	if mp and mp.enabled then
		local n = #mp.maps
		if S.Down("left", 1) then mp.cur = (mp.cur - 2) % n + 1; S.Snd("snd_menu1") end
		if S.Down("right", 1) then mp.cur = mp.cur % n + 1; S.Snd("snd_menu1") end
		if S.Down("select", 1) then
			S.Snd("snd_menu2")
			local mv = mp.maps[mp.cur]
			while mv.id == "random" do mv = mp.maps[1 + math.floor(BVNRuntime.RAND() * n)] end
			self.mapId = mv.id
			mp.enabled = false
			self:NextStep()
		end
	end
end

local function faceImg(fv, kind)
	local u = fv and fv.urls
	local f = u and u[kind]
	return f and ("bvn/face/" .. f) or nil
end

function Select:DrawItem(it, slotFace)
	local x, y, s = self:ItemPos(it)
	if s <= 0.01 then return end
	local tf = {s, 0, 0, s, x, y}
	local mv = S.Load("select_item")
	local hidden = false
	for _, slt in pairs(self.slts) do
		if slt.showingMore == it then hidden = true end
	end
	S.DrawFrame(mv, 0, tf, 1, ORDER + 3, "world", {
		more_bg = function(m)
			if it.isMore then S.DrawFrame(S.Load("select_more_bg"), 0, m, 1, ORDER + 3, "world") end
		end,
		ct = function(m)
			local f = faceImg(it.fv, "face")
			if f then S.Image(f, m, 1, ORDER + 3, "world") end
		end,
		warning = function(m)
			if it.fv.hasWarning then
				local w = S.Load("select_warning")
				if w then S.DrawFrame(w, math.floor(self.t / 2) % w.n, m, 1, ORDER + 3, "world") end
			end
		end,
	})
	-- "N+" (BitmapText, yellow, bold 16, right-aligned in 50 px, y -3).
	if it.cell and it.cell.more and #it.cell.more > 0 and not hidden and s > 0.9 then
		S.Text(#it.cell.more .. "+", x, y - 3, 16, {255, 255, 0}, "right", 50, 1, ORDER + 4)
	end
end

function Select:DrawGroup(slt)
	local gx, gy = slt.side == 1 and 10 or 535, 600 - 80
	local bar = S.Load(slt.side == 1 and "select_bar_p1" or "select_bar_p2")
	for _, ui in ipairs(slt.group.uis) do
		local k = S.Tw(ui.t, 0, 1, 6, ui.delay or 0, S.Ease.quadOut)
		local y = ui.from[1] + (ui.to[1] - ui.from[1]) * k
		local a = ui.from[2] + (ui.to[2] - ui.from[2]) * k
		local s = ui.from[3] + (ui.to[3] - ui.from[3]) * k
		local tf = {s, 0, 0, s, gx, gy + y}
		S.DrawFrame(bar, 0, tf, a, ORDER + 6, "world", {["ct/ct"] = function(m)
			local f = faceImg(ui.fv, "face_big")
			if f then S.Image(f, m, a, ORDER + 6, "world") end
		end})
		if ui.fv then
			-- The name: white 14 px, right-aligned for 1P, left for 2P, 30 px above the bottom.
			local p = S.Mul(tf, {1, 0, 0, 1, slt.side == 1 and 0 or 10, 70 - 30})
			S.Text(ui.fv.name or "", p[5], p[6], 14 * s, WHITE, slt.side == 1 and "right" or "left", (253 - 10) * s, a, ORDER + 7)
		end
	end
end

function Select:Draw(g)
	self.bg:Draw(nil, 1, ORDER, "world")
	if self.map then
		self:DrawMap()
	else
		for _, it in ipairs(self.items) do self:DrawItem(it) end
		for _, m in pairs(self.more) do
			for _, it in ipairs(m.items) do self:DrawItem(it) end
		end
		for _, c in ipairs(self.closing or {}) do
			for _, it in ipairs(c.items) do self:DrawItem(it) end
		end
		for side = 1, 2 do
			local slt = self.slts[side]
			if slt and not slt.cursorHidden and slt.item then
				local x, y = self:ItemPos(slt.item)
				local cur = S.Load(side == 1 and "select_cursor_p1" or "select_cursor_p2")
				local f = slt.selT and math.min(12, 4 + math.floor(slt.selT / 2)) or 0
				S.DrawFrame(cur, f, S.T(x, y), 1, ORDER + 5, "world")
			end
		end
		for side = 1, 2 do
			local slt = self.slts[side]
			if slt then self:DrawGroup(slt) end
		end
	end
	if self.confirm then BVNScreenDialog.DrawConfirm(self.confirm, 1500, "ui") end
end

function Select:DrawMap()
	local mp = self.map
	local mv = mp.maps[mp.cur]
	local ui = S.Load("select_map")
	-- Scales up from the centre in 0.3 s (Back.easeOut) to x (800 - bg width) / 2, y 150.
	local k = S.Tw(mp.t, 0, 1, 18, 0, S.Ease.backOut)
	local bx, by = (800 - 486) / 2, 600 * 0.25
	local x, y = 400 + (bx - 400) * k, 300 + (by - 300) * k
	S.DrawFrame(ui, 0, {k, 0, 0, k, x, y}, 1, ORDER + 3, "world", {ct = function(m)
		local pic = mv.id == "random" and "bvn/map/random.png" or ("bvn/map/" .. mv.id .. ".png")
		local sz = S.Size(pic)
		S.Image(pic, S.Mul(m, {450 / sz[1], 0, 0, 240 / sz[2], -2, 0}), 1, ORDER + 3, "world")
	end})
	local tx = S.Load("select_map_text")
	if tx and k >= 1 then
		local w = tx.imgs[1][2]
		local h = tx.imgs[1][3]
		local px, py = (800 - w) / 2, 600 - h - 35
		S.DrawFrame(tx, 0, S.T(px, py), 1, ORDER + 3, "world")
		S.Text(mv.name or "", px, py + (h - 14 * 1.3) / 2, 14, WHITE, "center", w, 1, ORDER + 4)
	end
end

BVNMenu = {
	VERSION = "3.9",
	MENU = MENU,

	FighterInfo = function(id)
		for _, d in ipairs(fighterList()) do
			if d.id == id then return d end
		end
		return nil
	end,

	AssistInfo = function(id)
		for _, d in ipairs(assistList()) do
			if d.id == id then return d end
		end
		return nil
	end,

	-- Swf-backed fighters and assists only (the converter may have skipped some).
	Available = function(id, assist)
		local inf = assist and BVNMenu.AssistInfo(id) or BVNMenu.FighterInfo(id)
		if not (inf and inf.urls and inf.urls.file) then return false end
		local file = inf.urls.file:gsub("%.swf$", "")
		return BVNRuntime.HasCharacter((assist and "fz_" or "") .. file)
	end,

	-- Random cells pick an available fighter (of one series for random_bleach / random_naruto).
	Resolve = function(id, assist)
		if not id:find("^random") then return id end
		local list = {}
		for _, d in ipairs(assist and assistList() or fighterList()) do
			local ok = BVNMenu.Available(d.id, assist)
			if ok and id ~= "random" then
				local bleach = (d.comic_type or 0) == 0
				ok = (id == "random_bleach") == bleach
			end
			if ok then list[#list + 1] = d.id end
		end
		if #list == 0 then return nil end
		return list[1 + math.floor(BVNRuntime.RAND() * #list)]
	end,

	NewTitle = function(g)
		local st = setmetatable({name = "title", phase = "title", t = 0, enabled = true, enableAt = 0}, Title)
		-- MenuStage.afterBuild: gotoAndPlay(2).
		st.clip = BVNScreen.Clip("title", 1, true)
		BVNSound.Music("bvn/bgm/op")
		return st
	end,

	NewSelect = function(g)
		local st = setmetatable({name = "select", phase = "select", g = g, t = 0, step = 0, timers = {}, items = {}, cells = {},
			more = {}, slts = {}, picks = {}}, Select)
		st.flow = st:Flow()
		st.bg = BVNScreen.Clip("select_bg", 0, false)
		BVNTrans.Clear()
		BVNSound.Music("bvn/bgm/select")
		st:NextStep()
		return st
	end,
}
