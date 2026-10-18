-- SettingStage (OPTION): the original option list on $setting$MC_stgSetUI.
-- Changes apply at once (volumes, key mode); APPLY saves and returns to the
-- menu, CANCEL restores the previous options. The original's key and joystick
-- set pages, QUALITY and DISPLAY MODE are left out: Pocket2D has no runtime key
-- rebinding, gamepad mapping, Flash quality levels or fullscreen switch for games.
-- Not attached to any actor.
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})
local ORDER = 10

local ITEMS = {
	{label = "COM LEVEL", cn = "电脑等级", key = "aiLevel"},
	{label = "OPERATE MODE", cn = "按键操作模式", key = "keyMode"},
	{label = "LIFE", cn = "生命值", key = "fighterHP"},
	{label = "TIME", cn = "对战时间", key = "gameTime"},
	{label = "SOUND", cn = "游戏音效", key = "soundVolume"},
	{label = "BGM", cn = "背景音乐", key = "bgmVolume"},
	{label = "SHOW HP", cn = "显示血量", key = "showHp"},
	{label = "CANCEL", cn = "取消"},
	{label = "APPLY", cn = "应用"},
}

BVNScreenSetting = {
	New = function(g)
		local st = {name = "option", phase = "option", t = 0, old = BVNSettings.Snapshot(), bg = S.Clip("setting", 0, false)}
		BVNSound.Music("bvn/bgm/back")
		local items = {}
		for i, it in ipairs(ITEMS) do
			items[i] = {label = it.label, cn = it.cn, key = it.key, options = it.key and BVNSettings.OPTIONS[it.key],
				value = it.key and BVNSettings[it.key]}
		end
		st.group = BVNScreenDialog.Group(items, {startY = 30, endY = 550, gap = 70})

		function st:Update()
			self.t = self.t + 1
			self.bg:Step()
			local ev = self.group:Update()
			if not ev then return end
			if ev.change then
				-- ConfigVO.setValueByKey: volumes follow at once.
				BVNSettings[ev.change] = ev.value
				BVNSettings.Apply()
			elseif ev.select == "CANCEL" then
				BVNSettings.Restore(self.old)
				g:GoMenu()
			elseif ev.select == "APPLY" then
				BVNSettings.Save()
				BVNSettings.Apply()
				g:GoMenu()
			end
		end

		function st:Draw()
			self.bg:Draw(nil, 1, ORDER, "world")
			self.group:Draw(0, 0, ORDER + 1, "world")
		end
		return st
	end,
}
