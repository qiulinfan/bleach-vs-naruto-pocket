-- The original option buttons and dialogs: SetBtnGroup / SetBtn / SetBtnLine
-- (bitmap-font labels, < option > arrows, the yellow underline with the
-- Chinese caption, the $common$MC_sltArrow pointer), ConfrimUI (YES / NO
-- box) and PauseDialog with MoveListSp. Not attached to any actor.
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})
local LINE = {253, 237, 101} -- 0xfded65
local LABEL_H = 38

local Group = {}
Group.__index = Group

-- items: {label, cn, options = {{label, cn, value}, ...}, key, value}
-- o: {x, y, startX, startY, gap, direct (0 across, 1 down), default, endY, who}
local function newGroup(items, o)
	o = o or {}
	local g = setmetatable({items = {}, x = o.x or 0, y = o.y or 0, startX = o.startX or 100, startY = o.startY or 50,
		gap = o.gap or 75, direct = o.direct or 1, endY = o.endY or 0, who = o.who or "menu", keyEnable = true, t = 0,
		scrollY = 0, scrollFrom = 0, scrollTo = 0, scrollT = 99, index = -1}, Group)
	for i, it in ipairs(items) do
		local b = {label = it.label, cn = it.cn or "", options = it.options, key = it.key, opt = 1}
		if b.options and it.value ~= nil then
			for k, op in ipairs(b.options) do
				if op[3] == it.value then b.opt = k end
			end
		end
		if g.direct == 0 then
			b.x, b.y = g.startX + g.gap * (i - 1), g.startY
		else
			b.x, b.y = g.startX, g.startY + g.gap * (i - 1)
		end
		g.items[i] = b
	end
	g:SetIndex(o.default or 0, false)
	return g
end

-- Width of a button as the Sprite reports it (label, arrows and option text).
local function layout(b)
	local lw = S.FontWidth(b.label)
	b.labelW = lw
	if b.options then
		local op = b.options[b.opt]
		b.prevX = lw + 50
		b.optX = b.prevX + 10
		b.nextX = b.optX + S.FontWidth(op[1]) + 10
		b.w = b.nextX + 29
	else
		b.w = lw
	end
	return b.w
end

function Group:SetIndex(i, sound)
	local n = #self.items
	if i < 0 then i = n - 1 end
	if i > n - 1 then i = 0 end
	if i == self.index then return end
	self.index = i
	local b = self.items[i + 1]
	b.lineT = 0
	if sound ~= false then S.Snd("snd_menu1") end
	-- moveScroll: long vertical lists slide so the pointer stays in view.
	if self.direct == 1 and self.endY ~= 0 and n >= 8 then
		local step = (self.endY - self.startY) / n
		self.scrollFrom, self.scrollTo, self.scrollT = self.scrollY, i * (step - self.gap), 0
	end
end

function Group:Current() return self.items[self.index + 1] end

function Group:Option(b)
	b = b or self:Current()
	return b.options and b.options[b.opt]
end

-- Reads input; returns {select = label} or {change = key, value = v}.
function Group:Update()
	self.t = self.t + 1
	for _, b in ipairs(self.items) do b.lineT = (b.lineT or 0) + 1 end
	if self.scrollT < 12 then
		self.scrollT = self.scrollT + 1
		self.scrollY = S.Tw(self.scrollT, self.scrollFrom, self.scrollTo, 12)
	end
	if not self.keyEnable then return nil end
	local who = self.who
	local b = self:Current()
	if S.Down("up", who) and self.direct == 1 then self:SetIndex(self.index - 1) end
	if S.Down("down", who) and self.direct == 1 then self:SetIndex(self.index + 1) end
	b = self:Current()
	local d = 0
	if S.Down("left", who) then
		if self.direct == 0 then self:SetIndex(self.index - 1) else d = -1 end
	end
	if S.Down("right", who) then
		if self.direct == 0 then self:SetIndex(self.index + 1) else d = 1 end
	end
	if d ~= 0 and b.options then
		b.opt = (b.opt - 1 + d) % #b.options + 1
		b.lineT = 0
		S.Snd("snd_menu1")
		return {change = b.key, value = b.options[b.opt][3]}
	end
	if S.Down("select", who) then
		S.Snd("snd_menu2")
		return {select = self:Current().label}
	end
	return nil
end

function Group:Width()
	local w = 0
	for _, b in ipairs(self.items) do w = math.max(w, b.x + layout(b)) end
	return w + 10
end

function Group:Draw(ox, oy, order, mode, alpha)
	ox, oy = (ox or 0) + self.x, (oy or 0) + self.y + self.scrollY
	alpha = alpha or 1
	order = order or 20
	for i, b in ipairs(self.items) do
		layout(b)
		local x, y = ox + b.x, oy + b.y
		local on = i - 1 == self.index
		if on then
			-- SetBtnLine: a 1 px line growing from 10% over 0.3 s, caption right-aligned under it.
			local k = S.Tw(b.lineT or 99, 0.1, 1, 18)
			S.Rect(x, y + LABEL_H, b.w * k, 1.2, LINE, 255 * alpha, order, mode)
			local op = self:Option(b)
			local cap = op and (b.cn .. " - " .. op[2]) or b.cn
			S.Text(cap, x, y + LABEL_H + 4, 16, LINE, "right", b.w, alpha, order)
		end
		S.Font(b.label, x, y, 1, alpha, order, mode)
		if b.options then
			local arrow = S.Load("text_arrow")
			if arrow then
				S.DrawFrame(arrow, 0, S.T(x + b.prevX, y + 17), alpha, order, mode)
				S.DrawFrame(arrow, 0, S.TS(x + b.nextX, y + 17, -1, 1), alpha, order, mode)
			end
			S.Font(b.options[b.opt][1], x + b.optX, y, 1, alpha, order, mode)
		end
	end
	-- The pointer ($common$MC_sltArrow) loops beside the current button.
	local b = self:Current()
	local arrow = S.Load("slt_arrow")
	if b and arrow then
		local f = math.floor(self.t / 2) % arrow.n
		S.DrawFrame(arrow, f, S.T(ox + b.x - 10, oy + b.y + 15), alpha, order, mode)
	end
end

BVNScreenDialog = {
	Group = newGroup,

	-- ConfrimUI: a black box sliding up, title in font1, caption, YES / NO (NO first).
	Confirm = function(title, cn, yes, no)
		local d = {title = title, cn = cn, yes = yes, no = no, t = 0}
		d.group = newGroup({{label = "YES", cn = "是"}, {label = "NO", cn = "否"}},
			{startX = 0, startY = 0, direct = 0, gap = 200, default = 1})
		d.group.x = (800 - d.group:Width()) / 2 + 30
		d.group.y = 300 - 80
		return d
	end,

	-- Returns true when the dialog closed.
	UpdateConfirm = function(d)
		d.t = d.t + 1
		if S.Down("back", "menu") then
			if d.no then d.no() end
			return true
		end
		local ev = d.group:Update()
		if ev and ev.select == "YES" then
			if d.yes then d.yes() end
			return true
		elseif ev and ev.select == "NO" then
			if d.no then d.no() end
			return true
		end
		return false
	end,

	DrawConfirm = function(d, order, mode)
		order = order or 1500
		local by = S.Tw(d.t, 600, 150, 12)
		S.Rect(0, by, 800, 300, {0, 0, 0}, 204, order, mode)
		local tw = S.FontWidth(d.title or "")
		S.Font(d.title or "", (800 - tw) / 2, by + 18, 1, 1, order, mode)
		S.Text(d.cn or "", 0, by + 18 + LABEL_H + 80, 20, {255, 255, 255}, "center", 800, 1, order)
		d.group:Draw(0, by, order, mode)
	end,

	-- PauseDialog (BasePauseDialog): GAME TITLE / MOVE LIST / CONTINUE over a 50% black screen.
	Pause = function(onTitle, onContinue)
		local p = {onTitle = onTitle, onContinue = onContinue, t = 0}
		p.group = newGroup({{label = "GAME TITLE", cn = "返回标题"}, {label = "MOVE LIST", cn = "出招表"},
			{label = "CONTINUE", cn = "继续游戏"}}, {default = 2})
		return p
	end,

	-- Returns "continue" when the game resumes.
	UpdatePause = function(p)
		p.t = p.t + 1
		local D = BVNScreenDialog
		if p.confirm then
			if D.UpdateConfirm(p.confirm) then p.confirm = nil end
			return nil
		end
		if p.moves then
			p.moves.t = p.moves.t + 1
			local ev = p.moves.t > 6 and p.moves.group:Update()
			if (ev and ev.select == "BACK") or S.Down("back", "menu") then p.moves = nil end
			return nil
		end
		if S.Down("back", "menu") then
			if p.onContinue then p.onContinue() end
			return "continue"
		end
		local ev = p.group:Update()
		if not ev then return nil end
		if ev.select == "CONTINUE" then
			if p.onContinue then p.onContinue() end
			return "continue"
		elseif ev.select == "MOVE LIST" then
			p.moves = {t = 0, group = newGroup({{label = "BACK", cn = "返回"}}, {x = 250, y = 600 - 130})}
		elseif ev.select == "GAME TITLE" then
			p.confirm = D.Confirm("BACK TITLE?", "返回到主菜单？", p.onTitle, nil)
		end
		return nil
	end,

	DrawPause = function(p)
		local order = 1400
		-- The 50% black layer covers the whole window (a fight's view is wider than 800 px).
		BVNDraw.UI(0, 0, 1280, 720, {0, 0, 0}, 128, order)
		if p.moves then
			Image.DrawUIScaled("bvn/ui/misc/movelist.jpg", S.OX, 0, 960 / S.Size("bvn/ui/misc/movelist.jpg")[1],
				720 / S.Size("bvn/ui/misc/movelist.jpg")[2], 255, 255, 255, 255, order + 1)
			p.moves.group:Draw(0, 0, order + 2, "ui")
		else
			p.group:Draw(0, 0, order + 1, "ui")
		end
		if p.confirm then BVNScreenDialog.DrawConfirm(p.confirm, order + 10, "ui") end
	end,
}
