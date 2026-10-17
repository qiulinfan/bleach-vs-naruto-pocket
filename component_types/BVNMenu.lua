-- Title, mode menu and the fighter / assist / map select screens, laid out on
-- the original 800x600 canvas (BVNMenu.X/Y map it to the 1280x720 window).
-- Not attached to any actor; BVNGame calls BVNMenu.Update/Draw with itself.
local D = setmetatable({}, {__index = function(_, k) return BVNDraw[k] end})
local WHITE, BLACK = {255, 255, 255}, {0, 0, 0}
local SCALE, OX = 1.2, 160

local MODES = {
	{text = "闯关模式", mode = "arcade", desc = "单人挑战连续的电脑对手"},
	{text = "对战模式", mode = "pvp", desc = "两名玩家同屏对战"},
	{text = "单人对战", mode = "cpu", desc = "自选对手与电脑一对一"},
	{text = "观战模式", mode = "watch", desc = "电脑之间的对战"},
	{text = "训练模式", mode = "training", desc = "对手不动，体力与气无限"},
}

local function X(x) return OX + x * SCALE end
local function Y(y) return y * SCALE end

local function img(name, x, y, s, a, order)
	s = (s or 1) * SCALE
	Image.DrawUIScaled(name, X(x), Y(y), s, s, 255, 255, 255, a or 255, order or 1)
end

local function rect(x, y, w, h, c, a, order) D.UI(X(x), Y(y), w * SCALE, h * SCALE, c, a, order or 0) end
local function text(s, x, y, size, c, a) D.TextC(s, X(x), Y(y), math.floor(size * SCALE), c or WHITE, a) end

local function faceFile(name)
	return "bvn/face/" .. name
end

BVNMenu = {
	X = X, Y = Y, Img = img, Rect = rect, Text = text,

	FighterInfo = function(id)
		for _, d in ipairs(BVNConfig.fighter.fighter.data) do
			if d.id == id then return d end
		end
		return nil
	end,

	AssistInfo = function(id)
		for _, d in ipairs(BVNConfig.assist.fighter.data) do
			if d.id == id then return d end
		end
		return nil
	end,

	-- Swf-backed fighters and assists only (the converter may have skipped some).
	Available = function(id, assist)
		local info = assist and BVNMenu.AssistInfo(id) or BVNMenu.FighterInfo(id)
		if not info then return false end
		local file = info.urls.file:gsub("%.swf$", "")
		return BVNRuntime.Character((assist and "fz_" or "") .. file) ~= nil
	end,

	Enter = function(g, phase)
		g.menu = g.menu or {mode = 1}
		g.menu.phase = phase
		g.menu.t = 0
		if phase == "select" then
			g.menu.step = "fighter"
			g.menu.slots = {
				{grid = BVNConfig.select.grid, r = 1, c = 10, form = 0, done = false},
				{grid = BVNConfig.select.grid, r = 1, c = 1, form = 0, done = false},
			}
			g.menu.slots[1].c = 1
			g.menu.slots[2].c = #BVNConfig.select.grid[1]
			g.menu.picks = {}
			g.menu.map = 2
		end
	end,

	Update = function(g)
		local m = g.menu
		m.t = m.t + 1
		if m.phase == "title" then
			if m.t > 20 and (Input.GetActionDown("confirm") or Input.GetActionDown("p1_attack")) then
				BVNSound.Play("ui_confirm")
				m.phase = "modes"
				m.t = 0
			end
		elseif m.phase == "modes" then
			local d = (Input.GetActionDown("p1_down") or Input.GetActionDown("p2_down")) and 1 or 0
			if Input.GetActionDown("p1_up") or Input.GetActionDown("p2_up") then d = -1 end
			if d ~= 0 then
				m.mode = (m.mode - 1 + d) % #MODES + 1
				BVNSound.Play("ui_select")
			end
			if m.t > 8 and (Input.GetActionDown("confirm") or Input.GetActionDown("p1_attack")) then
				g.mode = MODES[m.mode].mode
				BVNSound.Play("ui_confirm")
				BVNMenu.Enter(g, "select")
			elseif Input.GetActionDown("back") or Input.GetActionDown("p1_jump") then
				m.phase, m.t = "title", 0
			end
		elseif m.phase == "select" then
			BVNMenu.UpdateSelect(g)
		end
	end,

	-- Which human controls slot `s` right now, or nil if nobody does.
	Controller = function(g, s)
		local m = g.menu
		if g.mode == "pvp" then return s end
		if s == 1 then return 1 end
		-- Player 1 also picks the opponent in single and watch modes.
		if g.mode == "cpu" or g.mode == "watch" or g.mode == "training" then
			return m.slots[1].done and m.picks[1] and m.picks[1].assist and 1 or nil
		end
		return nil
	end,

	UpdateSelect = function(g)
		local m = g.menu
		if m.step == "map" then
			local d = 0
			if Input.GetActionDown("p1_down") or Input.GetActionDown("p1_up") then d = Input.GetActionDown("p1_down") and 5 or -5 end
			if g.Tap then d = d + g:Tap(1) end
			local n = #BVNConfig.map.map.data
			if d ~= 0 then m.map = (m.map - 1 + d) % n + 1; BVNSound.Play("ui_select") end
			if Input.GetActionDown("p1_attack") or Input.GetActionDown("confirm") then
				BVNSound.Play("ui_confirm")
				local id = BVNConfig.map.map.data[m.map].id
				if id == "random" then
					id = BVNConfig.map.map.data[2 + math.floor(BVNRuntime.RAND() * (n - 1))].id
				end
				BVNGame.StartBattle(g, m.picks, id)
			elseif Input.GetActionDown("p1_jump") or Input.GetActionDown("back") then
				m.step = "fighter"
				m.slots[2].done = false
				m.picks[2] = nil
			end
			return
		end
		for s = 1, 2 do
			local who = BVNMenu.Controller(g, s)
			local slot = m.slots[s]
			if who and not slot.done then
				local p = "p" .. who .. "_"
				local dx = g:Tap(who)
				local dy = (Input.GetActionDown(p .. "down") and 1 or 0) - (Input.GetActionDown(p .. "up") and 1 or 0)
				if dx ~= 0 or dy ~= 0 then
					local grid = slot.grid
					slot.r = (slot.r - 1 + dy) % #grid + 1
					slot.c = math.max(1, math.min(#grid[slot.r], slot.c + dx))
					slot.form = 0
					BVNSound.Play("ui_select")
				end
				local cell = slot.grid[slot.r][slot.c]
				if Input.GetActionDown(p .. "super") and #cell.more > 0 then
					slot.form = (slot.form + 1) % (#cell.more + 1)
					BVNSound.Play("ui_select")
				end
				if Input.GetActionDown(p .. "attack") or (who == 1 and Input.GetActionDown("confirm")) then
					local id = slot.form > 0 and cell.more[slot.form] or cell.id
					local isAssist = slot.grid == BVNConfig.select.assists
					id = BVNMenu.Resolve(id, isAssist)
					if id and BVNMenu.Available(id, isAssist) then
						BVNSound.Play("ui_confirm")
						m.picks[s] = m.picks[s] or {}
						if not isAssist then
							m.picks[s].fighter = id
							slot.grid, slot.r, slot.c, slot.form = BVNConfig.select.assists, 1, s == 1 and 1 or #BVNConfig.select.assists[1], 0
						else
							m.picks[s].assist = id
							slot.done = true
						end
					else
						BVNSound.Play("ui_select")
					end
				elseif Input.GetActionDown(p .. "jump") or (who == 1 and Input.GetActionDown("back")) then
					if slot.grid == BVNConfig.select.assists then
						slot.grid, slot.r, slot.c = BVNConfig.select.grid, 1, s == 1 and 1 or 10
						m.picks[s].fighter = nil
					elseif s == 2 and g.mode ~= "pvp" then
						m.slots[1].done = false
						m.slots[1].grid = BVNConfig.select.assists
						m.picks[1].assist = nil
					else
						BVNMenu.Enter(g, "modes")
						g.menu.phase = "modes"
					end
					BVNSound.Play("ui_select")
				end
			end
		end
		-- Arcade: the opponents come from the ladder, not the select screen.
		if g.mode == "arcade" and m.slots[1].done and not m.slots[2].done then
			m.slots[2].done = true
			m.picks[2] = {arcade = true}
		end
		if m.slots[1].done and m.slots[2].done and m.step == "fighter" then
			if g.mode == "arcade" then
				BVNGame.StartArcade(g, m.picks[1])
			else
				m.step = "map"
			end
		end
	end,

	-- Random cells pick an available fighter (of one series for random_bleach / random_naruto).
	Resolve = function(id, assist)
		if not id:find("^random") then return id end
		local list = {}
		local data = assist and BVNConfig.assist.fighter.data or BVNConfig.fighter.fighter.data
		for _, d in ipairs(data) do
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

	Draw = function(g)
		local m = g.menu
		rect(-200, 0, 1200, 600, {12, 10, 22}, 255, 0)
		if m.phase == "title" or m.phase == "modes" then
			BVNMenu.DrawTitle(g)
		elseif m.phase == "select" then
			if m.step == "map" then BVNMenu.DrawMaps(g) else BVNMenu.DrawSelect(g) end
		end
	end,

	DrawTitle = function(g)
		local m = g.menu
		img("bvn/map/xianshi/bg.png", 0, 0, 1, 255, 0)
		img("bvn/ui/title.png", 400 - 240, 70, 0.75, 255, 2)
		if m.phase == "title" then
			if (m.t // 30) % 2 == 0 then text("按 J 或 Enter 开始", 400, 470, 26, WHITE) end
		else
			for i, it in ipairs(MODES) do
				local y = 320 + (i - 1) * 46
				local on = i == m.mode
				rect(260, y - 4, 280, 38, on and {230, 110, 20} or BLACK, on and 230 or 150, 2)
				text(it.text, 400, y, 24, on and WHITE or {200, 200, 210})
			end
			text(MODES[m.mode].desc, 400, 560, 16, {230, 230, 230})
		end
		text("素材 © 5DPLAY Game Studio《死神vs火影》 · Pocket2D 移植", 400, 580, 12, {180, 180, 190})
	end,

	DrawSelect = function(g)
		local m = g.menu
		img("bvn/map/neixin/bg.png", 0, 0, 1, 120, 0)
		local assists = m.slots[1].grid == BVNConfig.select.assists or m.slots[2].grid == BVNConfig.select.assists
		local grid = m.slots[1].done and m.slots[2].grid or m.slots[1].grid
		text(grid == BVNConfig.select.assists and "选择援助" or "选择角色", 400, 18, 30, WHITE)
		local x0, y0 = 400 - 10 * 52 / 2, 80
		for r, row in ipairs(grid) do
			for c, cell in ipairs(row) do
				local x, y = x0 + (c - 1) * 52 + (10 - #row) * 26, y0 + (r - 1) * 52
				local info = grid == BVNConfig.select.assists and BVNMenu.AssistInfo(cell.id) or BVNMenu.FighterInfo(cell.id)
				rect(x, y, 50, 48, {40, 40, 60}, 255, 1)
				if info and info.urls and info.urls.face then img(faceFile(info.urls.face), x, y, 1, 255, 2)
				elseif cell.id:find("^random") then text("?", x + 25, y + 8, 30, {255, 220, 80}) end
				cell._x, cell._y = x, y
			end
		end
		for s = 1, 2 do
			local slot = m.slots[s]
			local cell = slot.grid[slot.r] and slot.grid[slot.r][slot.c]
			if cell and cell._x and slot.grid == grid then
				local c = s == 1 and {255, 60, 50} or {60, 130, 255}
				local a = slot.done and 255 or 170 + 85 * math.sin(m.t * 0.25)
				rect(cell._x - 2, cell._y - 2, 54, 3, c, a, 3)
				rect(cell._x - 2, cell._y + 47, 54, 3, c, a, 3)
				rect(cell._x - 2, cell._y - 2, 3, 52, c, a, 3)
				rect(cell._x + 49, cell._y - 2, 3, 52, c, a, 3)
			end
			-- Big face and name of the hovered or picked fighter.
			local pick = m.picks[s]
			local id = pick and pick.fighter
			if not id and cell and slot.grid == BVNConfig.select.grid then
				id = slot.form > 0 and cell.more[slot.form] or cell.id
			end
			local info = id and BVNMenu.FighterInfo(id)
			local px = s == 1 and 20 or 535
			if info then
				img(faceFile(info.urls.face_big), px, 470, 1, 255, 2)
				text(info.name, px + 122, 540, 20, WHITE)
			end
			if pick and pick.assist then
				local a = BVNMenu.AssistInfo(pick.assist)
				if a then text("援助: " .. a.name, px + 122, 566, 16, {200, 220, 255}) end
			end
			local label = s == 1 and "1P" or (g.mode == "pvp" and "2P" or "CPU")
			text(label, px + 122, 446, 20, s == 1 and {255, 90, 80} or {90, 150, 255})
		end
		text("WASD 移动 · J 确认 · K 返回 · I 切换形态", 400, 596 - 14, 13, {220, 220, 220})
	end,

	DrawMaps = function(g)
		local m = g.menu
		local data = BVNConfig.map.map.data
		local sel = data[m.map]
		if sel.id ~= "random" then img("bvn/map/" .. sel.id .. "/bg.png", 0, 0, 1, 200, 0) end
		text("选择场景", 400, 18, 30, WHITE)
		for i, d in ipairs(data) do
			local c, r = (i - 1) % 5, (i - 1) // 5
			local x, y = 70 + c * 134, 80 + r * 92
			local on = i == m.map
			rect(x - 3, y - 3, 126, 74, on and {255, 140, 30} or BLACK, 220, 1)
			if d.id ~= "random" then img("bvn/map/" .. d.id .. ".png", x, y, 120 / 450, 255, 2)
			else text("随机", x + 60, y + 20, 24, WHITE) end
			text(d.name, x + 60, y + 72, 14, on and {255, 220, 120} or WHITE)
		end
		text("A/D/W/S 选择 · J 开始 · K 返回", 400, 580, 14, {220, 220, 220})
	end,
}
