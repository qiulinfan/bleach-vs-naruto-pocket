-- Key settings (the original's KEY SET page): both players' fight keys,
-- rebound at run time with Input.SetBindings and saved in slot "keys".
-- confirm (return, space) and back (escape, backspace) stay fixed, so the
-- menus can always be left. Netplay reads the local player's 1P keys.
-- Not attached to any actor.
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})
local ORDER = 10
local SCHEMA = 1
local WHITE = {255, 255, 255}
local YELLOW = {253, 237, 101}
local GREY = {170, 170, 170}

-- {label, action, binding field}; the action's p1_ / p2_ prefix is the column.
local ROWS = {
	{"上", "up", "keys"}, {"下", "down", "keys"}, {"左", "move", "negative"}, {"右", "move", "positive"},
	{"攻击", "attack", "keys"}, {"跳跃", "jump", "keys"}, {"冲刺", "dash", "keys"}, {"技能", "skill", "keys"},
	{"必杀", "super", "keys"}, {"援助", "assist", "keys"},
}
local SIDES = {"p1_", "p2_"}

local function id(side, row) return SIDES[side] .. row[2] .. "." .. row[3] end

local defaults -- the bindings actions.json gave, read before any saved ones apply

local function current()
	local t = {}
	for side = 1, 2 do
		for _, row in ipairs(ROWS) do t[id(side, row)] = Input.GetBindings(SIDES[side] .. row[2], row[3]) end
	end
	return t
end

local function apply(t)
	for side = 1, 2 do
		for _, row in ipairs(ROWS) do
			local keys = t[id(side, row)]
			if type(keys) == "table" then
				-- A saved name the engine no longer knows keeps the default.
				pcall(Input.SetBindings, SIDES[side] .. row[2], row[3], keys)
			end
		end
	end
end

local function keyText(keys)
	if not keys or #keys == 0 then return "--" end
	return table.concat(keys, " / "):upper()
end

BVNKeys = {
	-- At start, after the options: the saved bindings over the defaults.
	Load = function()
		defaults = defaults or current()
		local r = Save and Save.Read("keys", {fallback = true})
		if r and r.ok and r.schema_version == SCHEMA and type(r.data) == "table" then apply(r.data) end
	end,

	Save = function()
		if not Save then return false end
		local r = Save.Write("keys", SCHEMA, current())
		if not r.ok then Debug.Log("BVN: cannot save keys: " .. tostring(r.code) .. " " .. tostring(r.error)) end
		return r.ok
	end,

	Reset = function() if defaults then apply(defaults) end end,

	-- Binds `key` to one row of one side alone; a row of the same side that had it takes
	-- this row's old key instead (a swap), so no key drives two of a player's actions.
	Bind = function(side, r, key)
		local row = ROWS[r]
		local action = SIDES[side] .. row[2]
		local old = Input.GetBindings(action, row[3])
		for side2 = 1, 2 do
			for r2, other in ipairs(ROWS) do
				if side2 ~= side or r2 ~= r then
					local keys = Input.GetBindings(SIDES[side2] .. other[2], other[3])
					local kept, had = {}, false
					for _, k in ipairs(keys) do
						if k == key then had = true else kept[#kept + 1] = k end
					end
					if had then
						if side2 == side and old[1] and #kept == 0 then kept[1] = old[1] end
						Input.SetBindings(SIDES[side2] .. other[2], other[3], kept)
					end
				end
			end
		end
		Input.SetBindings(action, row[3], {key})
	end,

	-- The KEY SET page: up / down pick a row, left / right the player, select waits for a
	-- key (escape cancels), RESET restores actions.json's keys, BACK saves.
	New = function(g)
		local st = {name = "keys", phase = "option", t = 0, row = 1, side = 1, waiting = false, hold = 0,
			bg = S.Clip("setting", 0, false), before = current()}
		local count = #ROWS + 2 -- RESET, BACK

		function st:Update()
			self.t = self.t + 1
			self.bg:Step()
			if self.hold > 0 then self.hold = self.hold - 1 return end
			if self.waiting then
				if Input.GetKeyDown("escape") then
					self.waiting = false
				else
					local key = Input.GetKeyDownName()
					if key ~= "" and key ~= "escape" then
						BVNKeys.Bind(self.side, self.row, key)
						S.Snd("snd_menu2")
						self.waiting = false
						self.hold = 2 -- the key just bound must not also move the menu
					end
				end
				return
			end
			if S.Down("back", "menu") then
				apply(self.before)
				g:GoOption()
				return
			end
			if S.Down("up", "menu") then self.row = (self.row - 2) % count + 1 S.Snd("snd_menu1") end
			if S.Down("down", "menu") then self.row = self.row % count + 1 S.Snd("snd_menu1") end
			if self.row <= #ROWS and (S.Down("left", "menu") or S.Down("right", "menu")) then
				self.side = 3 - self.side
				S.Snd("snd_menu1")
			end
			if S.Down("select", "menu") then
				S.Snd("snd_menu2")
				if self.row <= #ROWS then
					self.waiting = true
				elseif self.row == #ROWS + 1 then
					BVNKeys.Reset()
				else
					BVNKeys.Save()
					g:GoOption()
				end
			end
		end

		function st:Draw()
			self.bg:Draw(nil, 1, ORDER, "world")
			S.Text("按键设置", 400, 28, 26, YELLOW, "center", nil, 1, ORDER + 1)
			S.Text("1P", 400, 72, 18, self.side == 1 and YELLOW or WHITE, "center", nil, 1, ORDER + 1)
			S.Text("2P", 600, 72, 18, self.side == 2 and YELLOW or WHITE, "center", nil, 1, ORDER + 1)
			for r, row in ipairs(ROWS) do
				local y = 100 + (r - 1) * 36
				local on = r == self.row
				S.Text(row[1], 180, y, 18, on and YELLOW or WHITE, "left", nil, 1, ORDER + 1)
				for side = 1, 2 do
					local text = keyText(Input.GetBindings(SIDES[side] .. row[2], row[3]))
					local picked = on and side == self.side
					if picked and self.waiting then text = (self.t // 15) % 2 == 0 and "请按键..." or "" end
					S.Text(text, side == 1 and 400 or 600, y, 18, picked and YELLOW or (on and WHITE or GREY), "center", nil, 1,
						ORDER + 1)
				end
				if on then S.Rect(160, y + 26, 520, 1.2, YELLOW, 255, ORDER + 1, "world") end
			end
			local y = 100 + #ROWS * 36 + 12
			for k, label in ipairs({"恢复默认", "保存并返回"}) do
				local on = self.row == #ROWS + k
				S.Text(label, 400, y + (k - 1) * 36, 18, on and YELLOW or WHITE, "center", nil, 1, ORDER + 1)
			end
			S.Text(self.waiting and "按下新按键 (Esc 取消)" or "上下选择, 左右切换 1P / 2P, 确认后按新键; 返回键放弃修改",
				400, 572, 14, GREY, "center", nil, 1, ORDER + 1)
		end
		return st
	end,
}
