-- The MUSOU dialogs: DialogManager (a stack over a 70% black layer, fading in
-- 0.3 s and out 0.2 s), MusouConfrimUI / AlertUI, MusouStateDialog (the team:
-- three big faces, leader, level, exp, HP / MP / EN / ATK, CHANGE and LEADER),
-- MusouSelectDialog (owned and buyable fighters in pages of 25 with page dots,
-- the coin count, CHANGE / BUY) and MusouPauseDialog (BACK MAP / MOVE LIST /
-- CONTINUE). The original is mouse driven; the mouse works here too, and the
-- keyboard moves a pointer ($common$MC_sltArrow) over the buttons. Not
-- attached to any actor.
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})
local SD = setmetatable({}, {__index = function(_, k) return BVNScreenDialog[k] end})
local WHITE, YELLOW, GREY = {255, 255, 255}, {255, 255, 0}, {204, 204, 204}
local BASE = 1500
local FADE_IN, FADE_OUT = 18, 12

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

-- Mouse in stage coordinates (the menu camera: 800x600 at 1.2x, centred).
local function mouse()
	local p = Input.GetMousePosition()
	local w = Camera.ScreenToWorld(p.x, p.y)
	return (w.x * 100 - S.OX) / S.SCALE, w.y * 100 / S.SCALE
end
local function clicked() return Input.GetMouseButtonDown(1) end

-- Bounds of the images inside a named instance of a movie frame (movie coordinates).
local boundsCache = {}
local function slotBounds(name, path, f)
	local key = name .. "|" .. path .. "|" .. (f or 0)
	local c = boundsCache[key]
	if c ~= nil then return c or nil end
	local m = S.Load(name)
	local fr = m and m.frames[m.seq[(f or 0) + 1] or 1]
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	local inside = false
	local i = 1
	while fr and i <= #fr do
		local e = fr[i]
		if type(e) == "number" then
			if inside then
				local img = m.imgs[e]
				local a, b, cc, d, tx, ty = fr[i + 1], fr[i + 2], fr[i + 3], fr[i + 4], fr[i + 5], fr[i + 6]
				for _, p in ipairs({{0, 0}, {img[2], 0}, {0, img[3]}, {img[2], img[3]}}) do
					local x, y = a * p[1] + cc * p[2] + tx, b * p[1] + d * p[2] + ty
					x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
				end
			end
			i = i + 8
		else
			if e.slot == path then inside = true elseif e.slotEnd == path then inside = false end
			i = i + 1
		end
	end
	local r = x1 > x0 and {x0, y0, x1 - x0, y1 - y0} or false
	boundsCache[key] = r
	return r or nil
end

local function inRect(r, x, y, ox, oy, s)
	s = s or 1
	return r and x >= ox + r[1] * s and x <= ox + (r[1] + r[3]) * s and y >= oy + r[2] * s and y <= oy + (r[2] + r[4]) * s
end

-- The keyboard pointer beside a button.
local function pointer(x, y, t, alpha, order)
	local arrow = S.Load("slt_arrow")
	if arrow then S.DrawFrame(arrow, math.floor(t / 2) % arrow.n, S.T(x - 10, y), alpha, order, "ui") end
end

-- Text with the original Text's drop shadow.
local function shadowText(s, x, y, size, color, align, w, alpha, order)
	S.Text(s, x + 1, y + 1, size, {0, 0, 0}, align, w, alpha * 0.8, order)
	S.Text(s, x, y, size, color, align, w, alpha, order)
end

local function faceImg(id, kind)
	local inf = BVNMenu.FighterInfo(id)
	local f = inf and inf.urls and inf.urls[kind]
	return f and ("bvn/face/" .. f) or nil
end

local function fighterName(id)
	local inf = BVNMenu.FighterInfo(id)
	return inf and inf.name or id
end

-- DialogManager ---------------------------------------------------------------------------------

local DM = {stack = {}, fading = {}}

local function topDialog() return DM.stack[#DM.stack] end

local function show(d, hideOthers)
	if hideOthers == nil then hideOthers = true end
	if hideOthers then
		for _, o in ipairs(DM.stack) do o.hidden = true end
	end
	d.t, d.ready, d.hidden = 0, false, false
	d.x = d.w > 0 and (800 - d.w) / 2 or 0
	d.y = d.h > 0 and (600 - d.h) / 2 or 0
	d.x, d.y = d.x + (d.offX or 0), d.y + (d.offY or 0)
	DM.stack[#DM.stack + 1] = d
	if d.OnShow then d:OnShow() end
end

local function close(d)
	for i, o in ipairs(DM.stack) do
		if o == d then table.remove(DM.stack, i) break end
	end
	d.out = 0
	DM.fading[#DM.fading + 1] = d
	if d.OnClose then d:OnClose() end
	local last = topDialog()
	if last and last.hidden then
		last.hidden = false
		last.t, last.ready = 0, false
		if last.OnResume then last:OnResume() end
	end
end

-- Button helper: buttons = {{name, path (slot in movie), fn}}; the dialog's movie and origin.
local function updateButtons(d, movie, buttons)
	local mx, my = mouse()
	if clicked() then
		for i, b in ipairs(buttons) do
			if b.visible ~= false and inRect(slotBounds(movie, b.path), mx, my, d.x + (b.dx or 0), d.y) then
				d.focus = i
				S.Snd("snd_menu2")
				b.fn()
				return true
			end
		end
	end
	return false
end

-- The alert's movie draws everything except the buttons, so OK is drawn alone.
local function drawAlertOk(x, y, a, order)
	local mv = S.Load("musou_confirm")
	if not mv then return end
	local fr = mv.frames[mv.seq[1]]
	local inside = false
	local i = 1
	while i <= #fr do
		local e = fr[i]
		if type(e) == "number" then
			if inside then
				local img = mv.imgs[e]
				S.Image(img[1], {fr[i + 1], fr[i + 2], fr[i + 3], fr[i + 4], fr[i + 5] + x + 253 - 343, fr[i + 6] + y}, a * fr[i + 7], order, "ui")
			end
			i = i + 8
		else
			if e.slot == "yes" then inside = true elseif e.slotEnd == "yes" then inside = false end
			i = i + 1
		end
	end
end

-- MusouConfrimUI / AlertUI ------------------------------------------------------------------------

local function newConfirm(title, cn, yes, no, alert)
	local d = {kind = "confirm", w = 495, h = 240, title = title, cn = cn, yes = yes, no = no, alert = alert, focus = 1}
	function d:Update()
		local function yesFn() close(self) if self.yes then self.yes() end end
		local function noFn() close(self) if self.no then self.no() end end
		local buttons = {{path = "yes", fn = yesFn, dx = self.alert and (253 - 343) or 0}, {path = "no", fn = noFn, visible = not self.alert}}
		if updateButtons(self, "musou_confirm", buttons) then return end
		if S.Down("back", "menu") then noFn() return end
		if not self.alert and (S.Down("left", "menu") or S.Down("right", "menu")) then
			self.focus = 3 - self.focus
			S.Snd("snd_menu1")
		end
		if S.Down("select", "menu") then
			S.Snd("snd_menu2")
			if self.focus == 1 or self.alert then yesFn() else noFn() end
		end
	end
	function d:Draw(x, y, a, order)
		local mv = S.Load("musou_confirm")
		if self.alert then
			local hide = function() return "hide" end
			S.DrawFrame(mv, 0, S.T(x, y), a, order, "ui", {no = hide, yes = hide})
			drawAlertOk(x, y, a, order)
		else
			S.DrawFrame(mv, 0, S.T(x, y), a, order, "ui")
		end
		local tw = S.FontWidth(self.title or "")
		S.Font(self.title or "", x + (self.w - tw) / 2, y - 10, 1, a, order + 1, "ui")
		shadowText(self.cn or "", x + 15, y + 37, 20, WHITE, "center", 460, a, order + 1)
		if self.ready then
			local path = (self.focus == 1 or self.alert) and "yes" or "no"
			local r = slotBounds("musou_confirm", path)
			if r then
				local dx = (self.alert and path == "yes") and (253 - 343) or 0
				pointer(x + r[1] + dx, y + r[2] + r[4] / 2 - 15, self.t, a, order + 2)
			end
		end
	end
	return d
end

-- MusouStateDialog ------------------------------------------------------------------------------

-- BigFaceUI.updatePos: front (230, 33) at full size, the others behind at 0.74.
local FACE_POS = {{230, 33, 1}, {70, -24, 0.74}, {458, -4, 0.74}}

local function newState(onClose)
	local d = {kind = "state", w = 741, h = 478, offY = 20, focus = 1, faces = {}, changeIndex = 1, onCloseCb = onClose}
	-- The three big faces in slot order (p0 front).
	local function placeFaces(tween)
		for i, bf in ipairs(d.faces) do
			local p = FACE_POS[i]
			bf.from = {bf.x or p[1], bf.y or p[2], bf.s or p[3]}
			bf.to = p
			bf.tt = tween and 0 or 999
			bf.z = i == 1 and 3 or (i == 2 and 1 or 2)
		end
	end
	function d:InitFaces()
		local team = BVNMusouData.Team()
		self.faces = {}
		for i = 1, 3 do self.faces[i] = {data = team[i]} end
		placeFaces(false)
		for _, bf in ipairs(self.faces) do bf.x, bf.y, bf.s = bf.to[1], bf.to[2], bf.to[3] end
	end
	function d:Current() return self.faces[1] and self.faces[1].data end
	-- focusFighter: rotate so face `index` comes to the front.
	function d:FocusFighter(index, tween)
		local t = {self.faces[1], self.faces[2], self.faces[3]}
		if index == 3 then self.faces[3], self.faces[2], self.faces[1] = t[2], t[1], t[3]
		elseif index == 2 then self.faces[2], self.faces[3], self.faces[1] = t[3], t[1], t[2] end
		placeFaces(tween)
	end
	function d:OnShow() self:InitFaces() end
	function d:OnResume()
		-- updateBigFaces: the faces show the team in order again, then the changed one comes forward.
		local team = BVNMusouData.Team()
		for i = 1, 3 do self.faces[i].data = team[i] end
		self:FocusFighter(self.changeIndex, false)
		for _, bf in ipairs(self.faces) do bf.x, bf.y, bf.s = bf.to[1], bf.to[2], bf.to[3] end
	end
	function d:OnClose() if self.onCloseCb then self.onCloseCb() end end
	local function leader()
		BVNMusouData.SetLeader(d:Current())
		BVNMusouData.Save()
	end
	local function change()
		local cur = d:Current()
		local idx = 1
		for i, f in ipairs(BVNMusouData.Team()) do if f == cur then idx = i end end
		d.changeIndex = idx
		show(BVNMusouDialog.NewSelect(idx))
	end
	function d:Update()
		for _, bf in ipairs(self.faces) do bf.tt = bf.tt + 1 end
		local buttons = {{path = "change", fn = change}, {path = "leader", fn = leader}, {path = "back", fn = function() close(self) end}}
		if updateButtons(self, "musou_team_panel", buttons) then return end
		if clicked() then
			-- A face behind comes to the front.
			local mx, my = mouse()
			for i = 2, 3 do
				local bf = self.faces[i]
				local r = {0, 0, 270 * bf.s, 260 * bf.s}
				if inRect(r, mx, my, self.x + bf.x, self.y + bf.y) then self:FocusFighter(i, true) return end
			end
		end
		if S.Down("back", "menu") then close(self) return end
		if S.Down("left", "menu") then self:FocusFighter(2, true); S.Snd("snd_menu1") end
		if S.Down("right", "menu") then self:FocusFighter(3, true); S.Snd("snd_menu1") end
		if S.Down("up", "menu") or S.Down("down", "menu") then self.focus = 3 - self.focus; S.Snd("snd_menu1") end
		if S.Down("select", "menu") then
			S.Snd("snd_menu2")
			if self.focus == 1 then change() else leader() end
		end
	end
	function d:DrawFace(bf, x, y, a, order)
		local k = clamp(bf.tt / 12, 0, 1)
		bf.x = bf.from[1] + (bf.to[1] - bf.from[1]) * k
		bf.y = bf.from[2] + (bf.to[2] - bf.from[2]) * k
		bf.s = bf.from[3] + (bf.to[3] - bf.from[3]) * k
		local tf = {bf.s, 0, 0, bf.s, x + bf.x, y + bf.y}
		local fv = bf.data
		S.DrawFrame(S.Load("musou_bigface"), 0, tf, a, order, "ui", {
			ct = function(m, al) if fv then BVNMusouHud.Face("big", fv.id, m, al, order, "ui") end end,
			isLeaderMc = function(m, al)
				if fv and fv == BVNMusouData.Leader() then
					local lm = S.Load("musou_leader_mark")
					if lm then S.DrawFrame(lm, math.floor(self.t / 2) % lm.n, m, al, order, "ui") end
				end
			end,
		})
		if fv then
			shadowText(fighterName(fv.id), tf[5], tf[6] + 197 * bf.s, 24 * bf.s, YELLOW, "center", 270 * bf.s, a, order)
			shadowText("Lv." .. fv.level, tf[5], tf[6] + 230 * bf.s, 20 * bf.s, WHITE, "center", 270 * bf.s, a, order)
		end
	end
	function d:Draw(x, y, a, order)
		local cur = self:Current()
		local mv = S.Load("musou_team_panel")
		S.DrawFrame(mv, 0, S.T(x, y), a, order, "ui", {
			coinmc = function(m, al)
				shadowText(tostring(BVNMusouData.Money()), m[5] + 45, m[6] + 12, 16, WHITE, "center", 70, al, order)
			end,
			["expmc/bar"] = function(m, al)
				if not cur then return "hide" end
				local expMax = BVNMusouData.LevelUpExp(cur.level)
				S.DrawFrame(S.Load("musou_exp_fill"), 0, S.Mul(m, {clamp(cur.exp / math.max(1, expMax), 0, 1), 0, 0, 1, 0, 0}), al, order, "ui")
				return "hide"
			end,
			ct_fighter = function(m, al)
				if not cur then return end
				local ox, oy = m[5], m[6]
				-- SP_faceUI at (16, 15) with the face at x 1.
				local fm = {1, 0, 0, 1, ox + 16, oy + 15}
				local img = faceImg(cur.id, "face")
				if img then S.Image(img, S.Mul(fm, {50 / S.Size(img)[1], 0, 0, 50 / S.Size(img)[2], 1, 0}), al, order, "ui") end
				S.DrawFrame(S.Load("musou_faceui"), 0, fm, al, order, "ui")
				local expMax = BVNMusouData.LevelUpExp(cur.level)
				shadowText(fighterName(cur.id), ox + 75, oy + 30, 20, WHITE, "left", nil, al, order)
				shadowText("Lv." .. cur.level, ox + 220, oy + 55, 14, WHITE, "left", nil, al, order)
				shadowText("Exp." .. cur.exp .. "/" .. expMax, ox + 10, oy + 90, 14, GREY, "left", nil, al, order)
				shadowText("HP " .. cur.hp .. "\nMP " .. cur.qi .. "\nEN " .. cur.energy, ox + 10, oy + 130, 16, WHITE, "left", nil, al, order)
				shadowText("ATK " .. cur.atk * 10, ox + 180, oy + 130, 16, WHITE, "left", nil, al, order)
			end,
		})
		-- Faces back to front (the front one is re-added on top).
		local order2 = {}
		for _, bf in ipairs(self.faces) do order2[#order2 + 1] = bf end
		table.sort(order2, function(p, q) return (p.z or 0) < (q.z or 0) end)
		for _, bf in ipairs(order2) do self:DrawFace(bf, x, y, a, order) end
		if self.ready then
			local r = slotBounds("musou_team_panel", self.focus == 1 and "change" or "leader")
			if r then pointer(x + r[1], y + r[2] + r[4] / 2 - 15, self.t, a, order + 1) end
		end
	end
	return d
end

-- MusouSelectDialog ------------------------------------------------------------------------------

local PAGE = 25

local function newSelect(fighterIndex)
	local d = {kind = "select", w = 741, h = 478, offY = 20, index = fighterIndex, sel = nil, page = 1}
	-- SelectFighterList.build: the sold fighters not in the team, owned first, 5 x 5 a page.
	function d:Build()
		local inTeam = {}
		for _, id in ipairs(BVNMusouData.TeamIds()) do inTeam[id] = true end
		local owned, rest = {}, {}
		for _, p in ipairs(BVNMusouData.PRICES) do
			if not inTeam[p[1]] and BVNMenu.FighterInfo(p[1]) then
				local it = {id = p[1], price = p[2], t = 99}
				if BVNMusouData.FighterData(p[1]) then owned[#owned + 1] = it else rest[#rest + 1] = it end
			end
		end
		self.items = {}
		for _, it in ipairs(owned) do self.items[#self.items + 1] = it end
		for _, it in ipairs(rest) do self.items[#self.items + 1] = it end
		for i, it in ipairs(self.items) do
			local k = (i - 1) % PAGE
			it.page = (i - 1) // PAGE + 1
			it.x, it.y = 10 + (k % 5) * 80, 10 + (k // 5) * 80
		end
		self.pages = math.max(1, (#self.items + PAGE - 1) // PAGE)
	end
	function d:OnShow() self:Build() end
	function d:Bought(it) return BVNMusouData.FighterData(it.id) ~= nil end
	function d:Select(i)
		if not self.items[i] then return end
		if self.sel and self.items[self.sel] then self.items[self.sel].out = 0 end
		self.sel = i
		self.items[i].inT = 0
		self.page = self.items[i].page
	end
	local function choose()
		local it = d.sel and d.items[d.sel]
		if not it then return end
		if d:Bought(it) then
			BVNMusouData.SetTeam(d.index, it.id)
			BVNMusouData.Save()
			close(d)
		else
			BVNMusouDialog.BuyFighter(it.id, it.price, function() end)
		end
	end
	function d:Update()
		local it = self.sel and self.items[self.sel]
		local bought = it and self:Bought(it)
		local buttons = {{path = "change", fn = choose, visible = bought == true}, {path = "buy", fn = choose, visible = it ~= nil and not bought},
			{path = "back", fn = function() close(self) end}}
		if updateButtons(self, "musou_select_panel", buttons) then return end
		local mx, my = mouse()
		if clicked() then
			for i, x in ipairs(self.items) do
				if x.page == self.page then
					local ox, oy = self.x + 14 - 5 + x.x, self.y + 61.95 - 10 + x.y
					if mx >= ox - 3 and mx <= ox + 57 and my >= oy - 3 and my <= oy + 57 then self:Select(i) S.Snd("snd_menu1") return end
				end
			end
			for p = 1, self.pages do
				local ox, oy = self.x + 15 + 10 + (p - 1) * 40, self.y + 445.7 + 10
				if math.abs(mx - ox) < 14 and math.abs(my - oy) < 14 then self.page = p return end
			end
		end
		local wheel = Input.GetMouseScrollDelta and Input.GetMouseScrollDelta() or 0
		if type(wheel) == "table" or type(wheel) == "userdata" then wheel = wheel.y or 0 end
		if wheel < 0 and self.page < self.pages then self.page = self.page + 1 end
		if wheel > 0 and self.page > 1 then self.page = self.page - 1 end
		if S.Down("back", "menu") then close(self) return end
		local n = #self.items
		if n == 0 then return end
		local cur = self.sel or 0
		local function move(dx)
			local i = cur == 0 and 1 or clamp(cur + dx, 1, n)
			if i ~= cur then self:Select(i) S.Snd("snd_menu1") end
		end
		if S.Down("left", "menu") then move(-1) end
		if S.Down("right", "menu") then move(1) end
		if S.Down("up", "menu") then move(-5) end
		if S.Down("down", "menu") then move(5) end
		if S.Down("select", "menu") and self.sel then S.Snd("snd_menu2") choose() end
	end
	function d:Draw(x, y, a, order)
		local it = self.sel and self.items[self.sel]
		local bought = it and self:Bought(it)
		local mv = S.Load("musou_select_panel")
		S.DrawFrame(mv, 0, S.T(x, y), a, order, "ui", {
			coinmc = function(m, al) shadowText(tostring(BVNMusouData.Money()), m[5] + 45, m[6] + 12, 16, WHITE, "center", 70, al, order) end,
			change = function() if not bought then return "hide" end end,
			buy = function() if not (it and not bought) then return "hide" end end,
			ct_face = function(m, al)
				if not it then return end
				local img = faceImg(it.id, "face_win")
				if img then S.Image(img, S.Mul(m, {300 / S.Size(img)[1], 0, 0, 250 / S.Size(img)[2], 0, 0}), al, order, "ui") end
			end,
			ct_name = function(m, al) if it then shadowText(fighterName(it.id), m[5], m[6], 20, WHITE, "center", 299, al, order) end end,
			ct_money = function(m, al)
				if not it then return end
				if bought then
					local fv = BVNMusouData.FighterData(it.id)
					shadowText("Lv." .. fv.level, m[5], m[6], 20, WHITE, "left", nil, al, order)
				else
					local ico = S.Load("musou_coin_ico")
					local w = 0
					if ico then
						S.DrawFrame(ico, 0, m, al, order, "ui")
						w = ico.imgs[1] and ico.imgs[1][2] or 0
					end
					shadowText(tostring(it.price), m[5] + w, m[6], 20, WHITE, "left", nil, al, order)
				end
			end,
			ct_list = function(m, al)
				local ui = S.Load("musou_faceui")
				local sel = S.Load("musou_faceui_sel")
				for i, x2 in ipairs(self.items) do
					if x2.page == self.page then
						local fm = S.Mul(m, {1, 0, 0, 1, -5 + x2.x, -10 + x2.y})
						local alpha = self:Bought(x2) and al or al * 0.5
						local img = faceImg(x2.id, "face")
						if img then S.Image(img, S.Mul(fm, {50 / S.Size(img)[1], 0, 0, 50 / S.Size(img)[2], 1, 0}), alpha, order, "ui") end
						S.DrawFrame(ui, 0, fm, alpha, order, "ui", {seltmc = function(sm, sa)
							if sel and i == self.sel then
								local f0 = sel.labels and sel.labels["in"] or 1
								local k = math.min(f0 + math.floor((x2.inT or 99) / 2), (sel.labels and sel.labels["out"] or sel.n) - 1)
								S.DrawFrame(sel, k, sm, sa, order, "ui")
							end
						end})
						local fv = BVNMusouData.FighterData(x2.id)
						if fv then shadowText("Lv." .. fv.level, fm[5], fm[6] + 32, 14, WHITE, "left", nil, alpha, order) end
						x2.inT = (x2.inT or 99) + 1
					end
				end
			end,
			ct_dots = function(m, al)
				local dot = S.Load("musou_dot")
				if not dot then return end
				for p = 1, self.pages do
					S.DrawFrame(dot, p == self.page and 0 or 1, S.Mul(m, {1, 0, 0, 1, 10 + (p - 1) * 40, 10}), al, order, "ui")
				end
			end,
		})
	end
	return d
end

-- Pause (MusouPauseDialog) -------------------------------------------------------------------------

BVNMusouDialog = {
	Mouse = mouse,
	Show = show,
	Close = close,
	Showing = function() return #DM.stack > 0 end,
	-- Engine text is drawn above every image: text under the top dialog is skipped.
	TextFloor = function() return #DM.stack > 0 and BASE + #DM.stack * 20 - 1 or -math.huge end,
	Top = topDialog,
	Clear = function() DM.stack, DM.fading = {}, {} end,

	Confirm = function(title, cn, yes, no) local d = newConfirm(title, cn, yes, no, false) show(d, false) return d end,
	Alert = function(title, cn, closeFn) local d = newConfirm(title, cn, closeFn, closeFn, true) show(d, false) return d end,
	NewState = newState,
	NewSelect = newSelect,

	-- MusouLogic.buyFighter: an alert without the coins, else a confirm, then the fighter is owned and saved.
	BuyFighter = function(id, price, done)
		if BVNMusouData.Money() < price then
			BVNMusouDialog.Alert("NEED MORE MONEY", "当前金币不足，还需要 " .. price .. " 枚金币！")
			return
		end
		BVNMusouDialog.Confirm("CONFIRM", "确定使用 " .. price .. " 枚金币解锁人物？", function()
			BVNMusouData.LoseMoney(price)
			BVNMusouData.AddFighter(id)
			BVNMusouData.Save()
			if done then done() end
		end)
	end,

	-- One tick of the top dialog (input once it has faded in) and the fades.
	Update = function()
		for i = #DM.fading, 1, -1 do
			local d = DM.fading[i]
			d.out = d.out + 1
			if d.out >= FADE_OUT then table.remove(DM.fading, i) end
		end
		for _, d in ipairs(DM.stack) do d.t = (d.t or 0) + 1 end
		local d = topDialog()
		if not d then return false end
		if d.t >= FADE_IN then d.ready = true end
		if d.ready then d:Update() end
		return true
	end,

	-- Draws the visible dialogs: the 70% black layer under the top one.
	Draw = function()
		local n = #DM.stack
		if n == 0 and #DM.fading == 0 then return end
		local top = DM.stack[n]
		for i, d in ipairs(DM.stack) do
			local order = BASE + i * 20
			if d == top then BVNDraw.UI(0, 0, 1280, 720, {0, 0, 0}, 178, order - 1) end
			if not d.hidden then
				local k = clamp(d.t / FADE_IN, 0, 1)
				d:Draw(d.x, d.y - 10 * (1 - k), k, order)
			end
		end
		for _, d in ipairs(DM.fading) do
			local k = 1 - clamp(d.out / FADE_OUT, 0, 1)
			local order = BASE + (n + 1) * 20
			d:Draw(d.x, d.y - 10 * (1 - k), k, order)
		end
		if top then BVNScreen.textFloor = BASE + n * 20 - 1 end
	end,

	-- MusouPauseDialog: BACK MAP / MOVE LIST / CONTINUE over a 50% black screen.
	Pause = function(onBackMap)
		local p = {onBackMap = onBackMap, t = 0}
		p.group = SD.Group({{label = "BACK MAP", cn = "回大地图"}, {label = "MOVE LIST", cn = "出招表"},
			{label = "CONTINUE", cn = "继续游戏"}}, {default = 2})
		return p
	end,

	-- Returns "continue" when the game resumes, "map" for BACK MAP.
	UpdatePause = function(p)
		p.t = p.t + 1
		if BVNMusouDialog.Update() then return nil end
		if p.moves then
			p.moves.t = p.moves.t + 1
			local ev = p.moves.t > 6 and p.moves.group:Update()
			if (ev and ev.select == "BACK") or S.Down("back", "menu") then p.moves = nil end
			return nil
		end
		if p.result then return p.result end
		if S.Down("back", "menu") then return "continue" end
		local ev = p.group:Update()
		if not ev then return nil end
		if ev.select == "CONTINUE" then return "continue" end
		if ev.select == "MOVE LIST" then
			p.moves = {t = 0, group = SD.Group({{label = "BACK", cn = "返回"}}, {x = 250, y = 600 - 130})}
		elseif ev.select == "BACK MAP" then
			p.group.keyEnable = false
			BVNMusouDialog.Confirm("BACK MAP?", "返回到大地图？", function() p.result = "map" end, function() p.group.keyEnable = true end)
		end
		return nil
	end,

	DrawPause = function(p)
		if #DM.stack > 0 then BVNScreen.textFloor = BVNMusouDialog.TextFloor() end
		SD.DrawPause({group = p.group, moves = p.moves})
		BVNMusouDialog.Draw()
	end,
}
