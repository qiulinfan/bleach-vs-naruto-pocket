-- Stage backgrounds drawn in world space behind the fighters (sorting orders 0-9).
local D = BVNDraw

local function hash(i)
	local v = math.sin(i * 12.9898) * 43758.5453
	return v - math.floor(v)
end

local function sky(top, bottom, y1)
	local bands = 24
	local h = y1 / bands
	for i = 0, bands - 1 do
		D.Rect(-60, i * h - 1, 1400, h + 2, D.Mix(top, bottom, i / (bands - 1)), 255, 0)
	end
end

BVNStage = {
	Draw = function(index, frame)
		if index == 1 then BVNStage.Karakura(frame) else BVNStage.Konoha(frame) end
	end,

	-- Karakura Town at night: moon, skyline with lit windows, street.
	Karakura = function(frame)
		sky({8, 10, 32}, {70, 50, 100}, 610)
		for i = 1, 60 do
			local a = 120 + 120 * math.sin(frame * 0.05 + i)
			D.Rect(hash(i) * 1280, hash(i + 99) * 380, 2, 2, {255, 255, 240}, a, 1)
		end
		D.Circle(1030, 130, 62, {250, 245, 215}, 255, 1)
		D.Circle(1012, 118, 12, {225, 220, 190}, 255, 2)
		D.Circle(1048, 150, 8, {225, 220, 190}, 255, 2)
		for i = 0, 15 do
			local h = 150 + hash(i + 7) * 210
			local w = 70 + hash(i + 31) * 40
			local x = i * 86 - 20
			D.Rect(x, 610 - h, w, h, {26 + i % 3 * 6, 28, 48}, 255, 3)
			for r = 0, math.floor(h / 28) - 2 do
				for c = 0, 2 do
					if hash(i * 37 + r * 7 + c) > 0.55 then
						D.Rect(x + 10 + c * (w - 20) / 3, 610 - h + 14 + r * 28, 12, 14, {255, 214, 120}, 200, 4)
					end
				end
			end
		end
		D.Rect(-60, 596, 1400, 16, {80, 80, 92}, 255, 5)
		D.Rect(-60, 610, 1400, 120, {36, 36, 44}, 255, 5)
		for i = 0, 13 do D.Rect(i * 110 - (frame * 0) % 110, 662, 60, 6, {200, 200, 200}, 180, 6) end
		D.Rect(-60, 610, 1400, 3, {120, 120, 140}, 255, 6)
	end,

	-- Konoha by day: clouds, the Hokage Rock, trees, rooftops, a dirt square.
	Konoha = function(frame)
		sky({90, 160, 230}, {210, 235, 250}, 610)
		for i = 0, 4 do
			local x = (i * 300 + frame * 0.2) % 1600 - 160
			local y = 70 + hash(i) * 120
			D.Circle(x, y, 34, {255, 255, 255}, 230, 1)
			D.Circle(x + 40, y + 6, 28, {255, 255, 255}, 230, 1)
			D.Circle(x - 40, y + 8, 24, {255, 255, 255}, 230, 1)
		end
		-- Hokage Rock with four faces.
		local rock = {150, 115, 85}
		D.Rect(140, 230, 1000, 300, rock, 255, 2)
		D.Rect(200, 190, 880, 60, rock, 255, 2)
		D.Rect(300, 160, 680, 50, {160, 125, 92}, 255, 2)
		for i = 0, 3 do
			local cx = 330 + i * 210
			D.Rect(cx - 50, 215, 100, 120, {175, 140, 105}, 255, 3)
			D.Rect(cx - 32, 255, 22, 8, {90, 70, 50}, 255, 4)
			D.Rect(cx + 10, 255, 22, 8, {90, 70, 50}, 255, 4)
			D.Rect(cx - 6, 270, 12, 26, {150, 115, 85}, 255, 4)
			D.Rect(cx - 22, 308, 44, 6, {90, 70, 50}, 255, 4)
		end
		-- Trees and roofs.
		for i = 0, 18 do
			D.Circle(i * 72 - 10, 480 + hash(i + 3) * 30, 50 + hash(i) * 20, {50 + hash(i) * 30, 120, 60}, 255, 5)
		end
		for i = 0, 7 do
			local x = i * 170 - 20
			D.Rect(x, 500, 140, 100, {235, 220, 190}, 255, 6)
			D.Rect(x - 12, 482, 164, 26, {190, 60, 50}, 255, 7)
			D.Rect(x + 30, 530, 26, 30, {90, 60, 40}, 255, 7)
			D.Rect(x + 86, 530, 30, 22, {110, 150, 190}, 255, 7)
		end
		D.Rect(-60, 600, 1400, 12, {90, 160, 70}, 255, 8)
		D.Rect(-60, 610, 1400, 120, {195, 160, 115}, 255, 8)
		for i = 0, 30 do D.Rect(hash(i + 50) * 1280, 630 + hash(i + 80) * 80, 8, 4, {160, 125, 90}, 255, 9) end
	end,
}
