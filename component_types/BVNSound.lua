-- Sound effects on rotating mixer channels, and stage / character music.
BVNSound = {
	channel = 0,
	ALIASES = {ui_select = "select", ui_confirm = "confirm"},

	Play = function(name, volume)
		if not name then return end
		name = BVNSound.ALIASES[name] or name
		BVNSound.channel = BVNSound.channel % 48 + 1
		if Audio.HasClip(name) then
			Audio.SetVolume(BVNSound.channel, volume or 96)
			Audio.Play(BVNSound.channel, name, false)
		end
	end,

	Music = function(name)
		if BVNSound.music == name then return end
		BVNSound.music = name
		if name and Audio.HasClip(name) then Music.Play(name, true) else Music.Halt() end
	end,
}
