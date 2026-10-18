-- The MUSOU world map (WorldMapStage, WorldMapPointUI, BigmapClould /
-- CloudView) and LoadingMusouStage. The dark map shows the bright one through
-- soft circles where areas are open (pre-rendered by tools/convert_musou_ui.py:
-- the original masks view_mc with mask_mc); each open area has its point
-- coloured by progress (building / under 60% / under 100% / done) with its
-- percent, the current one the leader's face and level. Clicking the current
-- area asks for its next mission, another one makes it current; the face opens
-- the team dialog; the map drags and zooms (1..2) with the mouse. The keyboard
-- moves a pointer between open areas (up / down / left / right), selects with
-- attack / confirm, opens the team with skill (U) and leaves with back.
-- Not attached to any actor; BVNGame owns the current stage.
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})
local MD = setmetatable({}, {__index = function(_, k) return BVNMusouDialog[k] end})
local WHITE = {255, 255, 255}
local ORDER = 10

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function RAND() return BVNRuntime.RAND() end

local function cfg() return BVNMusouConfig and BVNMusouConfig.bigmap or {points = {}, reveals = {}, w = 1024, h = 1024} end

local function shadowText(s, x, y, size, color, align, w, alpha, order, mode)
	S.Text(s, x + 1, y + 1, size, {0, 0, 0}, align, w, alpha * 0.8, order)
	S.Text(s, x, y, size, color, align, w, alpha, order)
end

local Map = {}
Map.__index = Map

-- BigmapClould: clouds rise slowly over the map; a new one every 5 s.
local function newCloud(st, x, y)
	local b = st.bounds
	if not x or x == 0 then x = b[1] + (b[3] / 20) * (RAND() * 20) - 100 end
	if not y or y == 0 then y = b[2] + b[4] + 100 end
	local mv = S.Load("musou_map_cloud")
	local n = mv and mv.n or 1
	local c = {x = x, y = y, alpha = 0.2 + RAND() * 0.3, frame = math.floor(RAND() * n), speed = 0.02 + RAND() * 0.1}
	local img = mv and mv.imgs[(mv.frames[mv.seq[c.frame + 1]] or {})[1] or 1]
	c.h = img and img[3] or 200
	st.clouds[#st.clouds + 1] = c
end

function Map:RenderClouds()
	for i = #self.clouds, 1, -1 do
		local c = self.clouds[i]
		c.y = c.y - c.speed
		if c.y < -c.h + 30 then table.remove(self.clouds, i) end
	end
	self.cloudFrame = self.cloudFrame - 1
	if self.cloudFrame < 0 then
		newCloud(self)
		self.cloudFrame = 5 * 30
	end
end

-- renderPosAndSize: zoom 1..2, the map always covers the stage.
function Map:Clamp()
	self.scale = clamp(self.scale, 1, 2)
	local c = cfg()
	local l, t = 800 - c.w * self.scale, 600 - c.h * self.scale
	self.px = clamp(self.px, l, 0)
	self.py = clamp(self.py, t, 0)
end

function Map:Focus(id, scale)
	local p = cfg().points[id]
	if not p then return end
	self.scale = scale or self.scale
	self.px = 400 - p[1] * self.scale
	self.py = 300 - p[2] * self.scale
	self:Clamp()
end

-- Areas with a point on the map, in the map's order.
function Map:Areas()
	local mp = BVNMusouData.Map(BVNMusouData.CurrentMapId())
	local out = {}
	for _, a in ipairs(mp and mp.areas or {}) do
		if cfg().points[a.id] then out[#out + 1] = a end
	end
	return out
end

function Map:OpenAreas()
	local out = {}
	for _, a in ipairs(self:Areas()) do
		if BVNMusouData.CheckAreaIsOpen(a.id) then out[#out + 1] = a end
	end
	return out
end

-- WorldMapStage.onSelectPoint.
function Map:SelectPoint(a)
	local g = self.g
	if BVNMusouData.Building(a) then
		MD.Alert("NOT OPEN", "暂未开放")
		return
	end
	if BVNMusouData.CheckCurrentArea(a.id) then
		self:GotoMission(a)
	else
		BVNMusouData.SetCurrentArea(a.id)
		self.faceT = 0
	end
end

-- gotoMission: confirm, then the next mission's loading stage.
function Map:GotoMission(a)
	local allFinish = BVNMusouData.AreaPercent(a.id) >= 1
	MD.Confirm("CONFIRM", allFinish and "已通过全部关卡，是否进入最后一关？" or "进入下一关？", function()
		local mission = BVNMusouData.NextMission(a.id)
		if not mission then return end
		self.leaving = true
		BVNTrans.In(function() self.g:LoadMusou(mission) end)
	end)
end

function Map:Back()
	MD.Confirm("EXIT", "返回到游戏主菜单？", function() self.g:GoMenu() end)
end

-- The pointer moves to the nearest open area in a direction.
function Map:MoveCursor(dx, dy)
	local pts = cfg().points
	local cur = pts[self.cursor]
	if not cur then return end
	local best, bestD
	for _, a in ipairs(self:OpenAreas()) do
		local p = pts[a.id]
		if a.id ~= self.cursor then
			local vx, vy = p[1] - cur[1], p[2] - cur[2]
			local along = vx * dx + vy * dy
			local across = math.abs(vx * dy - vy * dx)
			if along > 0 and across <= along * 1.5 then
				local d = along + across * 2
				if not bestD or d < bestD then best, bestD = a.id, d end
			end
		end
	end
	if best then
		self.cursor = best
		S.Snd("snd_menu1")
		self.glide = {fx = self.px, fy = self.py, t = 0}
		local s = self.scale
		local p = pts[best]
		self.glide.tx = clamp(400 - p[1] * s, 800 - cfg().w * s, 0)
		self.glide.ty = clamp(300 - p[2] * s, 600 - cfg().h * s, 0)
	end
end

function Map:Update(g)
	self.t = self.t + 1
	if self.t == 1 then
		-- build / afterBuild: areas update, transOut, the current point in the middle at 1.5x.
		BVNTrans.Out()
	end
	self:RenderClouds()
	if self.faceT then self.faceT = self.faceT + 1 end
	if self.glide then
		local gl = self.glide
		gl.t = gl.t + 1
		local k = S.Ease.quadOut(clamp(gl.t / 12, 0, 1))
		self.px, self.py = gl.fx + (gl.tx - gl.fx) * k, gl.fy + (gl.ty - gl.fy) * k
		if gl.t >= 12 then self.glide = nil end
	end
	if MD.Update() or self.leaving or BVNTrans.Busy() then return end
	local mx, my = MD.Mouse()
	local c = cfg()
	-- Mouse: the back button, the points and faces, dragging and the wheel.
	if Input.GetMouseButtonDown(1) then
		local back = S.Load("musou_btn_back")
		local bw = back and back.imgs[1] and back.imgs[1][2] or 60
		local bh = back and back.imgs[1] and back.imgs[1][3] or 60
		if mx >= 10 and mx <= 10 + bw and my >= 10 and my <= 10 + bh then
			S.Snd("snd_menu2")
			self:Back()
			return
		end
		for _, a in ipairs(self:OpenAreas()) do
			local p = c.points[a.id]
			local sx, sy = self.px + p[1] * self.scale, self.py + p[2] * self.scale
			-- The point (pmc) lies above the face.
			if mx >= sx - 2 * self.scale and mx <= sx + 38 * self.scale and my >= sy - 2 * self.scale and my <= sy + 42 * self.scale then
				S.Snd("snd_menu2")
				self.cursor = a.id
				self:SelectPoint(a)
				return
			end
		end
		for _, a in ipairs(self:OpenAreas()) do
			local p = c.points[a.id]
			local sx, sy = self.px + p[1] * self.scale, self.py + p[2] * self.scale
			if BVNMusouData.CheckCurrentArea(a.id) and mx >= sx + (14.5 - 26.5) * self.scale and mx <= sx + (14.5 + 32) * self.scale
				and my >= sy + (-1.55 - 65) * self.scale and my <= sy + (-1.55 + 9) * self.scale then
				S.Snd("snd_menu2")
				self.cursor = a.id
				MD.Show(MD.NewState())
				return
			end
		end
		self.drag = {mx = mx, my = my, px = self.px, py = self.py}
	end
	if self.drag then
		if Input.GetMouseButton(1) then
			self.px = mx - self.drag.mx + self.drag.px
			self.py = my - self.drag.my + self.drag.py
			self:Clamp()
		else
			self.drag = nil
		end
	end
	local wheel = Input.GetMouseScrollDelta and Input.GetMouseScrollDelta() or 0
	if type(wheel) ~= "number" then wheel = wheel and wheel.y or 0 end
	if wheel ~= 0 then
		-- Zoom about the current point (setZommInCenter).
		local old = self.scale
		self.scale = clamp(self.scale + (wheel < 0 and -0.1 or 0.1), 1, 2)
		local p = c.points[BVNMusouData.CurrentAreaId()]
		if p then
			self.px = self.px + p[1] * (old - self.scale)
			self.py = self.py + p[2] * (old - self.scale)
		end
		self:Clamp()
	end
	-- Keyboard.
	if S.Down("back", "menu") then S.Snd("snd_menu2"); self:Back() return end
	if S.Down("left", "menu") then self:MoveCursor(-1, 0) end
	if S.Down("right", "menu") then self:MoveCursor(1, 0) end
	if S.Down("up", "menu") then self:MoveCursor(0, -1) end
	if S.Down("down", "menu") then self:MoveCursor(0, 1) end
	if Input.GetActionDown("p1_skill") then
		S.Snd("snd_menu2")
		MD.Show(MD.NewState())
		return
	end
	if Input.GetActionDown("confirm") or Input.GetActionDown("p1_attack") then
		local a = BVNMusouData.Area(BVNMusouData.CurrentMapId(), self.cursor)
		if a and BVNMusouData.CheckAreaIsOpen(a.id) then
			S.Snd("snd_menu2")
			self:SelectPoint(a)
		end
	end
end

-- WorldMapPointUI.updateColor: frame 2 building, 3 under 60%, 4 under 100%, 1 done.
local function pointFrame(a)
	if BVNMusouData.Building(a) then return 1 end
	local per = BVNMusouData.AreaPercent(a.id)
	if per < 0.6 then return 2 end
	if per < 1 then return 3 end
	return 0
end

function Map:Draw(g)
	if MD.Showing() then BVNScreen.textFloor = MD.TextFloor() end
	local c = cfg()
	local s = self.scale
	local tf = {s, 0, 0, s, self.px, self.py}
	S.Fill({0, 0, 0}, 255, ORDER - 1, "world")
	if c.bg then S.Image(c.bg, tf, 1, ORDER, "world") end
	for _, a in ipairs(self:OpenAreas()) do
		local r = c.reveals[a.id]
		if r then S.Image(r.img, S.Mul(tf, {1, 0, 0, 1, r.x, r.y}), 1, ORDER + 1, "world") end
	end
	local pmc = S.Load("musou_map_pmc")
	local faceMv = S.Load("musou_map_face")
	local leader = BVNMusouData.Leader()
	for _, a in ipairs(self:OpenAreas()) do
		local p = c.points[a.id]
		local pm = S.Mul(tf, {1, 0, 0, 1, p[1], p[2]})
		if pmc then S.DrawFrame(pmc, pointFrame(a), pm, 1, ORDER + 2, "world") end
		-- updatePercent: 20 px text 35 below, centred on x 12.
		local per = math.floor(BVNMusouData.AreaPercent(a.id) * 100 + 1e-6)
		local txt = per .. "%"
		local w = BVNDraw.TextWidth(txt, math.floor(20 * s * S.SCALE)) / S.SCALE
		shadowText(txt, pm[5] + 12 * s - w / 2, pm[6] + 35 * s, 20 * s, WHITE, "left", nil, 1, ORDER + 3)
		if BVNMusouData.CheckCurrentArea(a.id) and faceMv and leader then
			-- updateFace: the leader's face pops out (0.1 s back-out after 0.1 s).
			local k = S.Tw(self.faceT or 99, 0.01, 1, 6, 6, S.Ease.backOut)
			local fm = S.Mul(pm, {k, 0, 0, k, 14.5, -1.55})
			S.DrawFrame(faceMv, 0, fm, 1, ORDER + 4, "world", {ct = function(m)
				local inf = BVNMenu.FighterInfo(leader.id)
				local f = inf and inf.urls and inf.urls.face and ("bvn/face/" .. inf.urls.face)
				if f then S.Image(f, S.Mul(m, {50 / S.Size(f)[1], 0, 0, 50 / S.Size(f)[2], 1, 0}), 1, ORDER + 4, "world") end
			end})
			if k > 0.9 then
				local lv = "Lv." .. leader.level
				local lw = BVNDraw.TextWidth(lv, math.floor(12 * s * S.SCALE)) / S.SCALE
				shadowText(lv, fm[5] - 15 * s - lw, fm[6] - 32 * s, 12 * s, WHITE, "left", nil, 1, ORDER + 5)
			end
		end
		if a.id == self.cursor then
			local arrow = S.Load("slt_arrow")
			if arrow then S.DrawFrame(arrow, math.floor(self.t / 2) % arrow.n, S.T(pm[5] - 14, pm[6] + 20 * s), 1, ORDER + 5, "world") end
		end
	end
	local back = S.Load("musou_btn_back")
	if back then S.DrawFrame(back, 0, S.T(10, 10), 1, ORDER + 6, "world") end
	-- Clouds over everything, at 0.8 of the map's scale and offset.
	local cl = S.Load("musou_map_cloud")
	if cl then
		local ctf = {s * 0.8, 0, 0, s * 0.8, self.px * 0.8, self.py * 0.8}
		for _, cd in ipairs(self.clouds) do
			S.DrawFrame(cl, cd.frame, S.Mul(ctf, {1, 0, 0, 1, cd.x, cd.y}), cd.alpha, ORDER + 7, "world")
		end
	end
	MD.Draw()
end

-- LoadingMusouStage --------------------------------------------------------------------------------

local Loading = {}
Loading.__index = Loading

function Loading:Update(g)
	self.t = self.t + 1
	self.bg:Step()
	if self.t == 1 then BVNTrans.Out(function() self.loading = true end) end
	if MD.Update() then return end
	if S.Down("back", "menu") and not self.done then
		MD.Confirm("BACK TITLE?", "返回到主菜单？", function() g:GoMenu() end)
		return
	end
	if self.loading and not self.done then
		-- GameStageLoadCtrl: map, fighters (the team, then every enemy), bgm; one item every few ticks.
		self.wait = (self.wait or 0) - 1
		if self.wait > 0 then return end
		self.wait = 6
		local item = table.remove(self.queue, 1)
		if item then
			if item.kind == "fighter" then
				local inf = BVNMenu.FighterInfo(item.id)
				if inf and inf.urls and inf.urls.file then BVNRuntime.Character(inf.urls.file:gsub("%.swf$", "")) end
			end
			self.msg = string.format("正在加载 [%s] : %s (%d/%d)", item.label, item.name, item.step, 4)
			self.progress = (self.total - #self.queue) / self.total
		else
			self.done = true
			self.progress = 1
			BVNTrans.In(function() g:StartMusou(self.mission) end)
		end
	end
end

function Loading:Draw(g)
	if MD.Showing() then BVNScreen.textFloor = MD.TextFloor() end
	self.bg:Draw(nil, 1, ORDER, "world")
	S.DrawFrame(S.Load("loading_bar"), 0, S.T(17, 555), 1, ORDER + 4, "world", {
		bar = function(m) S.DrawFrame(S.Load("loading_bar_fill"), 0, S.Mul(m, {math.max(0.001, self.progress), 0, 0, 1, 0, 0}), 1,
			ORDER + 4, "world") end,
		txt = function(m, a, e)
			S.Text(self.msg or "", m[5], m[6], (e.size or 12) * m[4], e.color or WHITE, e.align, (e.w or 0) * m[1], a, ORDER + 5)
		end})
	MD.Draw()
end

BVNMusouMap = {
	NewWorldMap = function(g)
		local st = setmetatable({name = "worldmap", phase = "worldmap", g = g, t = 0, scale = 1, px = 0, py = 0, clouds = {},
			cloudFrame = 0}, Map)
		MD.Clear()
		BVNMusouData.Player()
		BVNMusouData.UpdateMapAreas()
		local c = cfg()
		st.bounds = {0, 0, c.w, c.h}
		for y = st.bounds[2] + 100, st.bounds[4] - 1, 50 do newCloud(st, nil, y) end
		st.cursor = BVNMusouData.CurrentAreaId()
		st:Focus(st.cursor, 1.5)
		BVNSound.Music("bvn/bgm/back")
		return st
	end,

	-- LoadingMusouStage: the loading screen, then the mission (transIn, MainGame.goMusouGame).
	NewLoading = function(g, mission)
		local st = setmetatable({name = "musou_loading", phase = "musou_loading", g = g, t = 0, mission = mission, progress = 0,
			queue = {}, bg = S.Clip("loading_fight", 0, false)}, Loading)
		MD.Clear()
		BVNSound.Music("bvn/bgm/loading")
		local mapName = mission.map
		for _, d in ipairs(BVNConfig.map.map.data) do if d.id == mission.map then mapName = d.name or mapName end end
		st.queue[#st.queue + 1] = {kind = "map", label = "地图", name = mapName, step = 1}
		local ids = {}
		for _, f in ipairs(BVNMusouData.Team()) do ids[#ids + 1] = f.id end
		for _, id in ipairs(BVNMusouData.MissionEnemyIds(mission)) do ids[#ids + 1] = id end
		local seen = {}
		for _, id in ipairs(ids) do
			if not seen[id] then
				seen[id] = true
				local inf = BVNMenu.FighterInfo(id)
				st.queue[#st.queue + 1] = {kind = "fighter", id = id, label = "角色", name = inf and inf.name or id, step = 2}
			end
		end
		st.queue[#st.queue + 1] = {kind = "bgm", label = "背景乐", name = mapName, step = 4}
		st.total = #st.queue
		return st
	end,
}
