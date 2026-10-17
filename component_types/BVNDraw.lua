-- Drawing helpers for BleachVsNaruto. Not attached to any actor.
-- The camera sits at (6.4, 3.6) with zoom 1, so world units are screen pixels / 100:
-- every function here takes screen pixels. World draws scale the 1x1 pixel.png.
BVNDraw = {
	FONT = "bvn",

	-- Filled rectangle with its top-left corner at (x, y).
	Rect = function(x, y, w, h, c, a, order)
		Image.DrawEx("pixel.png", x / 100, y / 100, 0, w, h, 0, 0, c[1], c[2], c[3], a or 255, order or 0)
	end,

	-- A w-wide bar starting at (x, y) and running len pixels along angle `ang`
	-- (degrees from straight down, positive toward `facing`). Returns its far end.
	Seg = function(x, y, ang, len, w, c, a, order, facing)
		local r = math.rad(ang)
		Image.DrawEx("pixel.png", x / 100, y / 100, -ang * facing, w, len, 0.5, 0, c[1], c[2], c[3], a or 255, order or 0)
		return x + math.sin(r) * len * facing, y + math.cos(r) * len
	end,

	-- Square of side s centered on (x, y), rotated by deg.
	Square = function(x, y, s, deg, c, a, order)
		Image.DrawEx("pixel.png", x / 100, y / 100, deg or 0, s, s, 0.5, 0.5, c[1], c[2], c[3], a or 255, order or 0)
	end,

	-- Disc from horizontal strips.
	Circle = function(cx, cy, r, c, a, order)
		local step = math.max(2, r / 6)
		local y = -r
		while y < r do
			local mid = y + step * 0.5
			local half = math.sqrt(math.max(0, r * r - mid * mid))
			Image.DrawEx("pixel.png", (cx - half) / 100, (cy + y) / 100, 0, half * 2, step + 0.5, 0, 0, c[1], c[2], c[3], a or 255, order or 0)
			y = y + step
		end
	end,

	-- Screen-space (UI) rectangle.
	UI = function(x, y, w, h, c, a, order)
		Image.DrawUIScaled("pixel.png", x, y, w, h, c[1], c[2], c[3], a or 255, order or 0)
	end,

	TextWidth = function(s, size)
		local w = 0
		for _, code in utf8.codes(s) do
			w = w + (code > 0x2E80 and size or size * 0.56)
		end
		return w
	end,

	Text = function(s, x, y, size, c, a)
		Text.Draw(s, math.floor(x), math.floor(y), BVNDraw.FONT, size, c[1], c[2], c[3], a or 255)
	end,

	-- Text centered on x, with a one-pixel dark shadow.
	TextC = function(s, x, y, size, c, a, shadow)
		local w = BVNDraw.TextWidth(s, size)
		if shadow ~= false then
			BVNDraw.Text(s, x - w / 2 + 2, y + 2, size, {0, 0, 0}, (a or 255) * 0.8)
		end
		BVNDraw.Text(s, x - w / 2, y, size, c, a)
	end,

	Lerp = function(a, b, t) return a + (b - a) * t end,

	Mix = function(c, d, t)
		return {c[1] + (d[1] - c[1]) * t, c[2] + (d[2] - c[2]) * t, c[3] + (d[3] - c[3]) * t}
	end,
}
