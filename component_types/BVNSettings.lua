-- Game options (ConfigVO), persisted with the engine's Save API in slot
-- "config". Defaults are the PC build's (SHELL_Pc launch.as / ConfigVO):
-- CPU level 1, classic key mode, 100% life, 60 s, sound and BGM at 70%,
-- HP numbers hidden; quality HIGH here (the PC build's LOW). Not attached to any actor.
local SCHEMA = 1

BVNSettings = {
	aiLevel = 1,        -- AI_level 1..6
	keyMode = 1,        -- keyInputMode: 0 standard, 1 classic (a held button repeats)
	fighterHP = 1,      -- fighterHP: life multiplier
	gameTime = 60,      -- fightTime: seconds, -1 for no limit
	soundVolume = 0.7,  -- soundVolume 0..1
	bgmVolume = 0.7,    -- bgmVolume 0..1
	quality = "high",   -- quality: only BEST smooths the fight's scaled bitmaps (ConfigVO.applyConfig)
	showHp = false,     -- isShowHp: HP numbers on the fight bars
	loaded = false,

	FIELDS = {"aiLevel", "keyMode", "fighterHP", "gameTime", "soundVolume", "bgmVolume", "quality", "showHp"},

	-- Option lists as the original setting menu shows them (GameInterfaceManager.getSettingMenu).
	OPTIONS = {
		aiLevel = {{"VERY EASY", "非常简单", 1}, {"EASY", "简单", 2}, {"NORMAL", "正常", 3}, {"HARD", "困难", 4},
			{"VERY HARD", "非常困难", 5}, {"HELL", "地狱", 6}},
		keyMode = {{"NORMAL", "正常模式", 0}, {"CLASSIC", "经典模式", 1}},
		fighterHP = {{"50%", "50%", 0.5}, {"100%", "100%", 1}, {"200%", "200%", 2}, {"300%", "300%", 3}, {"500%", "500%", 5}},
		gameTime = {{"30s", "30秒", 30}, {"60s", "60秒", 60}, {"90s", "90秒", 90}, {"∞", "无限制", -1}},
		soundVolume = {{"0%", "0%", 0}, {"10%", "10%", 0.1}, {"30%", "30%", 0.3}, {"50%", "50%", 0.5}, {"70%", "70%", 0.7},
			{"100%", "100%", 1}},
		bgmVolume = {{"0%", "0%", 0}, {"10%", "10%", 0.1}, {"30%", "30%", 0.3}, {"50%", "50%", 0.5}, {"70%", "70%", 0.7},
			{"100%", "100%", 1}},
		-- LOW / MEDIUM: StageQuality.LOW, HIGH: MEDIUM (bitmaps not smoothed either), BEST: HIGH.
		quality = {{"LOW", "低", "low"}, {"MEDIUM", "中", "medium"}, {"HIGH", "高", "high"}, {"BEST", "最高", "best"}},
		showHp = {{"SHOW", "显示", true}, {"HIDE", "隐藏", false}},
	},

	Valid = function(key, v)
		for _, o in ipairs(BVNSettings.OPTIONS[key] or {}) do
			if o[3] == v then return true end
		end
		return false
	end,

	-- A saved value this build does not offer (a newer build's) is left out of the
	-- snapshot while the option still shows its default, so the save keeps it.
	foreign = {},

	Snapshot = function()
		local t = {}
		for _, k in ipairs(BVNSettings.FIELDS) do
			if BVNSettings.foreign[k] == nil or BVNSettings[k] ~= BVNSettings.foreign[k] then t[k] = BVNSettings[k] end
		end
		return t
	end,

	Restore = function(t)
		for _, k in ipairs(BVNSettings.FIELDS) do
			if t[k] ~= nil and BVNSettings.Valid(k, t[k]) then BVNSettings[k] = t[k] end
		end
		BVNSettings.Apply()
	end,

	-- Reads the saved options (BVNSaveSlot); unknown or invalid values keep their defaults.
	Load = function()
		BVNSettings.loaded = true
		BVNSettings.foreign = {}
		local data = BVNSaveSlot.Read("config", SCHEMA)
		if data then
			for _, k in ipairs(BVNSettings.FIELDS) do
				if data[k] ~= nil and not BVNSettings.Valid(k, data[k]) then BVNSettings.foreign[k] = BVNSettings[k] end
			end
			BVNSettings.Restore(data)
		else
			BVNSettings.Apply()
		end
	end,

	Save = function() return BVNSaveSlot.Write("config", SCHEMA, BVNSettings.Snapshot()) end,

	-- The fight's quality (GameConfig.QUALITY_GAME): at BEST scaled bitmaps are smoothed;
	-- menus keep QUALITY_UI (LOW).
	Smoothing = function(inFight)
		if Image.SetSmoothing then Image.SetSmoothing(inFight and BVNSettings.quality == "best") end
	end,

	-- ConfigVO.applyConfig: volumes and the key mode.
	Apply = function()
		BVNInput.classic = BVNSettings.keyMode == 1
		Music.SetVolume(math.floor(128 * BVNSettings.bgmVolume + 0.5))
	end,
}
