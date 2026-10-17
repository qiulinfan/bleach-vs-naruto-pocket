-- Stick-rig characters drawn from rotated bars. A pose gives absolute angles
-- in degrees from straight down, positive toward the facing side:
-- lean (torso), ua1/fa1 (front arm), ua2/fa2 (back arm), th1/sh1, th2/sh2 (legs)
-- and w (weapon in the front hand). Draw puts the rig's lowest point on y.
BVNRig = {
	KEYS = {"lean", "ua1", "fa1", "ua2", "fa2", "th1", "sh1", "th2", "sh2", "w"},

	LerpPose = function(a, b, t)
		local p = {}
		for _, k in ipairs(BVNRig.KEYS) do p[k] = a[k] + (b[k] - a[k]) * t end
		return p
	end,

	Draw = function(ch, x, y, facing, pose, o)
		o = o or {}
		local D = BVNDraw
		local f = facing
		local s = ch.scale
		local TH, SH, TO, UA, FA, HEAD = 30 * s, 30 * s, 44 * s, 24 * s, 23 * s, 24 * s
		local function dir(a)
			local r = math.rad(a)
			return math.sin(r) * f, math.cos(r)
		end
		-- Forward kinematics around the hip at (0, 0).
		local kx1, ky1 = dir(pose.th1); kx1, ky1 = kx1 * TH, ky1 * TH
		local fx1, fy1 = dir(pose.sh1); fx1, fy1 = kx1 + fx1 * SH, ky1 + fy1 * SH
		local kx2, ky2 = dir(pose.th2); kx2, ky2 = kx2 * TH, ky2 * TH
		local fx2, fy2 = dir(pose.sh2); fx2, fy2 = kx2 + fx2 * SH, ky2 + fy2 * SH
		local L = math.rad(pose.lean)
		local ux, uy = math.sin(L) * f, -math.cos(L)
		local vx, vy = math.cos(L) * f, math.sin(L)
		local sx, sy = ux * TO, uy * TO
		local hx, hy = sx + ux * (5 + HEAD / 2), sy + uy * (5 + HEAD / 2)
		local lowest = math.max(fy1, fy2, ky1, ky2, 0, sy, hy + HEAD / 2)
		local ox, oy = x, y - lowest - 2 * s

		local tint, flash = o.tint, o.flash or 0
		local alpha = o.alpha or 255
		local base = o.order or 20
		local function C(c, dark)
			local r, g, b = c[1], c[2], c[3]
			if dark then r, g, b = r * 0.72, g * 0.72, b * 0.72 end
			if tint then
				local t = o.tint_amount or 0.5
				r, g, b = r + (tint[1] - r) * t, g + (tint[2] - g) * t, b + (tint[3] - b) * t
			end
			if flash > 0 then
				r, g, b = r + (255 - r) * flash, g + (255 - g) * flash, b + (255 - b) * flash
			end
			return {r, g, b}
		end
		local function seg(px, py, ang, len, w, c, order, dark)
			return D.Seg(ox + px, oy + py, ang, len, w, C(c, dark), alpha, order, f)
		end
		local function sq(px, py, size, c, order, dark)
			D.Square(ox + px, oy + py, size, pose.lean * f, C(c, dark), alpha, order)
		end
		-- Point in the head frame: a forward, b up from the head center.
		local function P(a, b)
			return hx + vx * a * s + ux * b * s, hy + vy * a * s + uy * b * s
		end
		local up = 180 - pose.lean
		local fwd = 90 - pose.lean

		-- Back arm.
		local ex2, ey2 = seg(sx, sy, pose.ua2, UA, 12 * s, ch.sleeve, base, true)
		local hx2, hy2 = seg(ex2 - ox, ey2 - oy, pose.fa2, FA, 10 * s, ch.forearm, base, true)
		sq(hx2 - ox, hy2 - oy, 9 * s, ch.skin, base, true)
		-- Legs.
		for i = 1, 2 do
			local th, sh = i == 1 and pose.th1 or pose.th2, i == 1 and pose.sh1 or pose.sh2
			local dark = i == 2
			local order = base + (i == 1 and 2 or 1)
			local kx, ky = seg(0, 0, th, TH, ch.thigh_w * s, ch.pants, order, dark)
			local ax, ay = seg(kx - ox, ky - oy, sh, SH, ch.shin_w * s, ch.shin, order, dark)
			sq((kx + ax) / 2 - ox, (ky + ay) / 2 - oy, ch.shin_w * s * 0.9, ch.shin, order, dark)
			seg(ax - ox, ay - oy, sh - 90, 13 * s, 7 * s, ch.foot, order, dark)
		end
		-- Torso.
		seg(0, 4 * s, up, TO + 6 * s, 30 * s, ch.top, base + 3)
		if ch.collar then seg(sx - ux * 2 * s, sy - uy * 2 * s, 180 + up + 25, 18 * s, 6 * s, ch.collar, base + 3) end
		if ch.chest then seg(sx, sy, -pose.lean, 12 * s, 31 * s, ch.chest, base + 3) end
		if ch.belt then seg(0, 6 * s, up, ch.belt_h * s, 33 * s, ch.belt, base + 3) end
		-- Head.
		local nx, ny = P(0, -HEAD / 2 / s)
		seg(nx, ny, up, 6 * s, 10 * s, ch.skin, base + 4)
		sq(hx, hy, HEAD, ch.skin, base + 4)
		local ex, ey = P(6, 1)
		D.Square(ox + ex, oy + ey, 4 * s, 0, C(o.eye or ch.eye), alpha, base + 4)
		BVNRig.HAIR[ch.hair](seg, P, up, fwd, ch, base + 4, ox, oy, s)
		-- Front arm and weapon.
		local ex1, ey1 = seg(sx, sy, pose.ua1, UA, 12 * s, ch.sleeve, base + 6)
		local hx1, hy1 = seg(ex1 - ox, ey1 - oy, pose.fa1, FA, 10 * s, ch.forearm, base + 6)
		sq(hx1 - ox, hy1 - oy, 9 * s, ch.skin, base + 6)
		if ch.weapon then BVNRig.WEAPON[ch.weapon](seg, hx1 - ox, hy1 - oy, pose.w, base + 5, s, o) end
		return {hand_x = hx1, hand_y = hy1, head_x = ox + hx, head_y = oy + hy, hip_x = ox, hip_y = oy}
	end,

	HAIR = {
		ichigo = function(seg, P, up, fwd, ch, order)
			local c = ch.hair_color
			local x, y = P(-2, 2)
			seg(x, y, up, 12, 27, c, order)
			local spikes = {{-60, 15}, {-30, 20}, {0, 22}, {28, 22}, {55, 20}, {85, 18}, {115, 14}}
			for _, sp in ipairs(spikes) do
				local px, py = P(-2, 7)
				seg(px, py, up + sp[1], sp[2], 9, c, order)
			end
			local bx, by = P(7, 10)
			seg(bx, by, up - 130, 12, 6, c, order)
		end,
		rukia = function(seg, P, up, fwd, ch, order)
			local c = ch.hair_color
			local x, y = P(-2, 2)
			seg(x, y, up, 13, 28, c, order)
			local bx, by = P(-8, 8)
			seg(bx, by, up + 180, 26, 11, c, order)
			local sx, sy = P(6, 12)
			seg(sx, sy, up + 172, 19, 3, c, order)
		end,
		naruto = function(seg, P, up, fwd, ch, order)
			local c = ch.hair_color
			local x, y = P(-2, 3)
			seg(x, y, up, 11, 27, c, order)
			local spikes = {{-75, 16}, {-48, 21}, {-22, 24}, {4, 25}, {30, 24}, {56, 22}, {82, 20}, {108, 16}}
			for _, sp in ipairs(spikes) do
				local px, py = P(-2, 7)
				seg(px, py, up + sp[1], sp[2], 9, c, order)
			end
			local hx, hy = P(-13, 5)
			seg(hx, hy, fwd, 27, 6, {40, 50, 90}, order)
			local tx, ty = P(-13, 5)
			seg(tx, ty, up + 115, 15, 3, {40, 50, 90}, order)
			local ax, ay = P(4, 5)
			seg(ax, ay, fwd, 9, 7, {200, 205, 215}, order)
			for i = -1, 1 do
				local wx, wy = P(5, -5 + i * 2)
				seg(wx, wy, fwd, 6, 1, {120, 70, 40}, order)
			end
		end,
		sasuke = function(seg, P, up, fwd, ch, order)
			local c = ch.hair_color
			local x, y = P(-2, 2)
			seg(x, y, up, 12, 28, c, order)
			local spikes = {{35, 20}, {60, 24}, {85, 25}, {110, 22}, {135, 18}}
			for _, sp in ipairs(spikes) do
				local px, py = P(-4, 7)
				seg(px, py, up + sp[1], sp[2], 10, c, order)
			end
			local ax, ay = P(8, 10)
			seg(ax, ay, up - 160, 17, 6, c, order)
			local bx, by = P(1, 11)
			seg(bx, by, up - 172, 13, 5, c, order)
		end,
	},

	WEAPON = {
		zangetsu = function(seg, x, y, w, order, s, o)
			if o.bankai then
				seg(x, y, w + 180, 14 * s, 5 * s, {200, 30, 30}, order)
				seg(x, y, w, 84 * s, 7 * s, {20, 20, 24}, order)
				seg(x, y, w, 84 * s, 2 * s, {190, 40, 50}, order)
				return
			end
			seg(x, y, w + 180, 16 * s, 6 * s, {235, 235, 235}, order)
			seg(x, y, w, 6 * s, 14 * s, {30, 30, 30}, order)
			seg(x, y, w, 100 * s, 18 * s, {150, 158, 170}, order)
			seg(x, y, w, 100 * s, 8 * s, {222, 228, 236}, order)
		end,
		shirayuki = function(seg, x, y, w, order, s)
			seg(x, y, w + 180, 13 * s, 5 * s, {240, 240, 255}, order)
			seg(x, y, w + 160, 32 * s, 3 * s, {245, 248, 255}, order)
			seg(x, y, w, 4 * s, 12 * s, {235, 240, 255}, order)
			seg(x, y, w, 76 * s, 5 * s, {248, 250, 255}, order)
		end,
		kusanagi = function(seg, x, y, w, order, s)
			seg(x, y, w + 180, 15 * s, 5 * s, {50, 45, 60}, order)
			seg(x, y, w, 80 * s, 4 * s, {200, 206, 220}, order)
		end,
	},
}
