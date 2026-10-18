-- Sound effects on rotating mixer channels, and stage / character music.
-- Volumes follow the options (SoundCtrl.setSoundVolumn / setBgmVolumn).
BVNSound = {
	channel = 0,
	-- The original menu sounds (SoundCtrl.sndSelect / sndConfrim), with the old stand-ins as fallback.
	ALIASES = {ui_select = {"snd_menu1", "select"}, ui_confirm = {"snd_menu2", "confirm"}},

	Resolve = function(name)
		local alias = BVNSound.ALIASES[name]
		if not alias then return name end
		local fx = BVNFxData and BVNFxData.sounds and BVNFxData.sounds[alias[1]]
		if fx and Audio.HasClip(fx) then return fx end
		return alias[2]
	end,

	Play = function(name, volume)
		if not name then return end
		name = BVNSound.Resolve(name)
		BVNSound.channel = BVNSound.channel % 48 + 1
		if Audio.HasClip(name) then
			local k = BVNSettings and BVNSettings.soundVolume or 1
			Audio.SetVolume(BVNSound.channel, math.floor((volume or 96) * k + 0.5))
			Audio.Play(BVNSound.channel, name, false)
		end
	end,

	Music = function(name)
		if BVNSound.music == name then return end
		BVNSound.music = name
		if name and Audio.HasClip(name) then Music.Play(name, true) else Music.Halt() end
	end,

}
