-- SettingStage (OPTION): the original option list on $setting$MC_stgSetUI.
-- Changes apply at once (volumes, key mode); APPLY saves and returns to the
-- menu, CANCEL restores the previous options. KEY SET opens the key page
-- (BVNKeys). The original's joystick page, QUALITY and DISPLAY MODE are left
-- out: Pocket2D has no gamepad mapping, Flash quality levels or fullscreen
-- switch for games.
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
	{label = "KEY SET", cn = "按键设置"},
	{label = "UPDATE", cn = "检查更新", update = true},
	{label = "CANCEL", cn = "取消"},
	{label = "APPLY", cn = "应用"},
}

BVNScreenSetting = {
	New = function(g)
		local st = {name = "option", phase = "option", t = 0, old = BVNSettings.Snapshot(), bg = S.Clip("setting", 0, false)}
		BVNSound.Music("bvn/bgm/back")
		local items = {}
		for _, it in ipairs(ITEMS) do
			-- UPDATE only where the game has a release channel (game.config "update").
			if not it.update or Update.Status().state ~= "off" then
				items[#items + 1] = {label = it.label, cn = it.cn, key = it.key, options = it.key and BVNSettings.OPTIONS[it.key],
					value = it.key and BVNSettings[it.key]}
			end
		end
		st.group = BVNScreenDialog.Group(items, {startY = 30, endY = 550, gap = 70})

		-- The UPDATE caption follows the update's state.
		local function updateCaption()
			local u = Update.Status()
			if u.state == "checking" then return "正在检查更新..." end
			if u.state == "current" then return "已是最新版本 " .. u.current end
			if u.state == "available" then return "新版本 " .. u.latest .. "：确认后下载" end
			if u.state == "downloading" then return string.format("正在下载 %d%%", math.floor(u.progress * 100)) end
			if u.state == "ready" then
				return u.installable and "下载完成：确认后安装并重启" or "下载完成 (开发版不能自我替换)"
			end
			if u.state == "installing" then return "正在安装..." end
			if u.state == "restart" then return "即将重启" end
			if u.state == "error" then return "更新失败：" .. u.error end
			return "检查更新 (当前 " .. u.current .. ")"
		end

		function st:Update()
			self.t = self.t + 1
			self.bg:Step()
			for _, b in ipairs(self.group.items) do
				if b.label == "UPDATE" then b.cn = updateCaption() end
			end
			-- The helper swaps the package in once the game has quit, then starts it again.
			if Update.Status().state == "restart" then
				Application.Quit()
				return
			end
			local ev = self.group:Update()
			if not ev then return end
			if ev.change then
				-- ConfigVO.setValueByKey: volumes follow at once.
				BVNSettings[ev.change] = ev.value
				BVNSettings.Apply()
			elseif ev.select == "KEY SET" then
				g:Go(BVNKeys.New(g))
			elseif ev.select == "UPDATE" then
				local u = Update.Status()
				if u.state == "available" then Update.Download()
				elseif u.state == "ready" then
					BVNSettings.Save()
					Update.Install()
				elseif u.state == "idle" or u.state == "current" or u.state == "error" then Update.Check() end
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
