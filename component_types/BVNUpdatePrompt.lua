-- The update prompt on the title screen: once the start-up check (packaged builds,
-- BVNGame.Init) finds a newer release, a ConfrimUI box asks whether to update. YES
-- downloads it with a progress bar, installs it and quits; the engine's helper swaps the
-- package in and starts the game again. Saves are outside the package (BVNSaveSlot).
-- NO hides it until the next start; OPTION ▸ UPDATE still offers it. Not attached to
-- any actor.
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})
local ORDER = 1500
local YELLOW = {253, 237, 101}
local WHITE = {255, 255, 255}

local P = {dismissed = false, dialog = nil, busy = false, failed = nil}

local function ask(u)
	P.dialog = BVNScreenDialog.Confirm("UPDATE?", "发现新版本 " .. u.latest .. " (当前 " .. u.current .. ")，现在更新？存档会保留。",
		function()
			P.busy = true
			BVNSettings.Save()
			Update.Download()
		end,
		function() P.dismissed = true end)
end

BVNUpdatePrompt = {
	-- Every title frame; true while the prompt holds the input.
	Update = function()
		if P.dismissed then return false end
		local u = Update.Status()
		if P.busy then
			if u.state == "ready" then Update.Install()
			elseif u.state == "restart" then Application.Quit()
			elseif u.state == "error" then
				P.busy, P.failed = false, u.error
			end
			return true
		end
		if P.failed then
			if S.Down("select", "menu") or S.Down("back", "menu") then P.failed, P.dismissed = nil, true end
			return true
		end
		if P.dialog then
			if BVNScreenDialog.UpdateConfirm(P.dialog) then P.dialog = nil end
			return true
		end
		if u.state == "available" and u.installable then
			ask(u)
			return true
		end
		return false
	end,

	Draw = function()
		if P.dialog then
			BVNScreenDialog.DrawConfirm(P.dialog, ORDER, "ui")
			return
		end
		if not (P.busy or P.failed) then return end
		local u = Update.Status()
		S.Rect(0, 150, 800, 300, {0, 0, 0}, 204, ORDER, "ui")
		local text
		if P.failed then
			text = "更新失败：" .. tostring(P.failed) .. "\n按确认键返回"
		elseif u.state == "downloading" then
			text = string.format("正在下载新版本 %s   %d%%", u.latest, math.floor(u.progress * 100))
			S.Rect(200, 330, 400, 6, {80, 80, 80}, 255, ORDER + 1, "ui")
			S.Rect(200, 330, 400 * u.progress, 6, YELLOW, 255, ORDER + 2, "ui")
		else
			text = "正在安装新版本，游戏会自动重启…"
		end
		S.Text(text, 0, 260, 20, WHITE, "center", 800, 1, ORDER + 1)
	end,
}
