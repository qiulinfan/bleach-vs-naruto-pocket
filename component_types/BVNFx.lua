-- Projectile, particle and chakra/reiatsu effect drawing (sorting orders 60-80).
local D = BVNDraw

local function jitter(i, frame)
	local v = math.sin(i * 91.7 + frame * 0.9) * 43758.5453
	return v - math.floor(v)
end

BVNFx = {
	Projectile = function(p, frame)
		local k = p.kind
		local f = p.face
		if k == "getsuga" or k == "getsuga_black" then
			local R = p.h / 2
			local black = k == "getsuga_black"
			local outer = black and {220, 30, 40} or {80, 160, 255}
			local core = black and {15, 10, 15} or {230, 248, 255}
			for pass = 1, 2 do
				for i = -6, 6 do
					local th = math.rad(i * 13)
					local px = p.x + f * (math.cos(th) * R * 0.55 - R * 0.25)
					local py = p.y + math.sin(th) * R
					local size = (pass == 1 and 26 or 16) * (1 - math.abs(i) / 8)
					D.Square(px, py, size, i * 13 * f, pass == 1 and outer or core, pass == 1 and 150 or 255, 60 + pass)
				end
			end
			for i = 1, 4 do
				D.Rect(p.x - f * (20 + i * 22), p.y - R * 0.5 + jitter(i, frame) * R, 22, 3, outer, 120, 60)
			end
		elseif k == "hakuren" then
			for i = 0, 6 do
				local h = 40 + jitter(i, 0) * 60
				local x = p.x - f * i * 14
				D.Seg(x, p.y + 50, 180 + (jitter(i, 1) - 0.5) * 50, h, 14, {200, 240, 255}, 220, 61, 1)
				D.Seg(x, p.y + 50, 180 + (jitter(i, 1) - 0.5) * 50, h * 0.7, 5, {255, 255, 255}, 255, 62, 1)
			end
			for i = 1, 6 do
				D.Square(p.x + (jitter(i, frame) - 0.5) * 120, p.y + (jitter(i + 9, frame) - 0.5) * 100, 5, 45, {255, 255, 255}, 220, 63)
			end
		elseif k == "tsukishiro" then
			local gx, gy = p.x, p.y + p.h / 2
			if p.delay > 0 then
				local pulse = 0.5 + 0.5 * math.sin(frame * 0.5)
				D.Rect(gx - p.w / 2, gy - 8, p.w, 10, {200, 240, 255}, 120 + 100 * pulse, 61)
				D.Rect(gx - 3, gy - 300, 6, 300, {200, 240, 255}, 40 * pulse, 61)
			else
				local a = math.min(1, p.life / 8)
				D.Rect(gx - p.w / 2, gy - p.h, p.w, p.h, {200, 240, 255}, 170 * a, 61)
				D.Rect(gx - p.w / 4, gy - p.h, p.w / 2, p.h, {255, 255, 255}, 230 * a, 62)
				for i = 0, 7 do
					D.Seg(gx + (jitter(i, 0) - 0.5) * p.w * 1.4, gy, 180 + (jitter(i, 2) - 0.5) * 60, 50 + jitter(i, 3) * 70, 12, {220, 245, 255}, 230 * a, 63, 1)
				end
			end
		elseif k == "clones" then
			local ch = BVNData.CHARACTERS[3]
			local pts = BVNRig.Draw(ch, p.x, p.y + p.h / 2, f, BVNData.POSES.fist.dash, {order = 62, alpha = 235})
			if p.rasengan then BVNFx.Orb(pts.hand_x + f * 16, pts.hand_y, 20, frame, 72) end
		elseif k == "fireball" then
			local r = p.w / 2 + math.sin(frame * 0.6) * 4
			D.Circle(p.x, p.y, r * 1.25, {255, 80, 20}, 120, 60)
			D.Circle(p.x, p.y, r, {255, 140, 30}, 230, 61)
			D.Circle(p.x, p.y, r * 0.62, {255, 210, 80}, 255, 62)
			D.Circle(p.x + f * r * 0.15, p.y, r * 0.32, {255, 250, 200}, 255, 63)
			for i = 1, 5 do
				D.Square(p.x - f * (r + jitter(i, frame) * 40), p.y + (jitter(i + 5, frame) - 0.5) * r * 1.4, 10, 45, {255, 120, 30}, 200, 60)
			end
		elseif k == "kirin" then
			local gx = p.x
			D.Rect(-60, -40, 1400, 120, {30, 30, 50}, 200, 59)
			if p.delay > 0 then
				local pulse = 0.5 + 0.5 * math.sin(frame * 0.7)
				D.Rect(gx - 2, 60, 4, 550, {200, 210, 255}, 60 + 80 * pulse, 61)
				D.Rect(gx - p.w / 2, 600, p.w, 8, {200, 210, 255}, 150 * pulse, 61)
			else
				local a = math.min(1, p.life / 6)
				local x, y = gx, 60
				local step = 0
				while y < 610 do
					step = step + 1
					local nx = gx + (jitter(step, frame) - 0.5) * 70
					local ny = math.min(610, y + 45)
					local ang = math.deg(math.atan(nx - x, ny - y))
					local len = math.sqrt((nx - x) ^ 2 + (ny - y) ^ 2)
					D.Seg(x, y, ang, len, 34, {120, 140, 255}, 120 * a, 61, 1)
					D.Seg(x, y, ang, len, 10, {245, 248, 255}, 255 * a, 62, 1)
					x, y = nx, ny
				end
				D.Circle(gx, 600, 80, {200, 210, 255}, 120 * a, 61)
			end
		end
	end,

	Particle = function(e)
		local a = 255 * e.life / e.max
		if e.ring then
			local s = e.size * (1 + (e.max - e.life) * 0.3)
			D.Square(e.x, e.y, s, 45, e.c, a * 0.5, 70)
		elseif e.puff then
			D.Circle(e.x, e.y, e.size * (1.3 - e.life / e.max * 0.5), e.c, a * 0.8, 71)
		else
			D.Square(e.x, e.y, e.size, 45, e.c, a, 72)
		end
	end,

	Orb = function(x, y, r, frame, order)
		D.Circle(x, y, r * 1.35, {80, 150, 255}, 110, order)
		D.Circle(x, y, r, {120, 190, 255}, 220, order + 1)
		D.Circle(x, y, r * 0.55, {235, 248, 255}, 255, order + 2)
		for i = 0, 3 do
			local th = frame * 0.5 + i * math.pi / 2
			D.Square(x + math.cos(th) * r * 0.8, y + math.sin(th) * r * 0.8, 5, 0, {255, 255, 255}, 230, order + 3)
		end
	end,

	Chidori = function(x, y, frame, order)
		D.Circle(x, y, 18, {140, 160, 255}, 140, order)
		for i = 0, 5 do
			local ang = jitter(i, frame) * 360
			D.Seg(x, y, ang, 18 + jitter(i + 3, frame) * 20, 3, {235, 240, 255}, 255, order + 1, 1)
		end
	end,

	Snow = function(x, y, frame, order)
		for i = 0, 4 do
			D.Square(x + (jitter(i, frame) - 0.5) * 50, y + (jitter(i + 7, frame) - 0.5) * 50, 5, 45, {230, 248, 255}, 230, order)
		end
	end,
}
