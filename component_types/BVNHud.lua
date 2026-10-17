-- The original fight HUD (5DPLAY's MC_fightUI) drawn from BVNUIData part
-- trees, driven like FightUI / FightBar / QiBar: bar scales, digits, faces.
-- The 800x600 stage maps to the window at 1.2x, centred. Not attached to any actor.
local SCALE, OX = 1.2, 160

local sizes = {}
local function size(img)
	local s = sizes[img]
	if not s then
		local v = Image.GetSize(img)
		s = {v.x, v.y}
		sizes[img] = s
	end
	return s
end

-- Horizontal extent of a part tree in its own coordinates.
local function extent(parts)
	local x0, x1 = math.huge, -math.huge
	for _, p in ipairs(parts) do
		if p.img then
			x0, x1 = math.min(x0, p.x), math.max(x1, p.x + size(p.img)[1])
		else
			local sub = p.parts or (p.frames and p.frames[1])
			if sub then
				local a0, a1 = extent(sub)
				if a0 < a1 then
					local m = p.m
					local u, v = m[5] + m[1] * a0, m[5] + m[1] * a1
					x0, x1 = math.min(x0, u, v), math.max(x1, u, v)
				end
			end
		end
	end
	return x0, x1
end

-- Draws a part tree under a scale+translate transform (a, d, tx, ty).
local function draw(parts, a, d, tx, ty, ov, path, alpha, order)
	for _, p in ipairs(parts) do
		if p.img then
			local w, h = size(p.img)[1], size(p.img)[2]
			local x0, x1 = tx + a * p.x, tx + a * (p.x + w)
			local y0, y1 = ty + d * p.y, ty + d * (p.y + h)
			Image.DrawUIScaled(p.img, math.min(x0, x1), math.min(y0, y1), a, d, 255, 255, 255, alpha, order)
		else
			local key = path .. p.name
			local o = ov[key]
			if not (o and o.hide) then
				local m = p.m
				local ca, cd = a * m[1], d * m[4]
				local ctx, cty = tx + a * m[5], ty + d * m[6]
				if o and o.sx then ca = ca * o.sx end
				local al = alpha * (p.alpha or 1)
				if o and o.draw then o.draw(ca, cd, ctx, cty, al, order) end
				local sub = p.parts
				if p.frames then sub = p.frames[math.max(1, math.min(#p.frames, (o and o.frame) or 1))] end
				if o and o.unflip and sub then
					-- Mirror back around the content's centre (text inside a mirrored bar).
					local x0, x1 = extent(sub)
					ctx, ca = ctx + ca * (x0 + x1), -ca
				end
				if sub and not (o and o.only) then draw(sub, ca, cd, ctx, cty, ov, key .. "/", al, order) end
			end
		end
	end
end

-- Digits from a multi-frame number symbol (frame n+1 shows digit n).
local function digits(sym, n, count, gap)
	local frames = BVNUIData[sym] and BVNUIData[sym].frames
	return function(a, d, tx, ty, al, order)
		if not frames then return end
		local s = string.format("%0" .. count .. "d", math.max(0, n))
		for i = 1, #s do
			local fr = frames[tonumber(s:sub(i, i)) + 1]
			if fr then draw(fr, a, d, tx + a * (i - 1) * gap, ty, {}, "", al, order) end
		end
	end
end

local function image(img, ox, oy, w)
	return function(a, d, tx, ty, al, order)
		if not img then return end
		local s = size(img)
		local k = w and (w / s[1]) or 1
		local x0, x1 = tx + a * ox, tx + a * (ox + s[1] * k)
		Image.DrawUIScaled(img, math.min(x0, x1), ty + d * oy, a * k, d * k, 255, 255, 255, al, order)
	end
end

BVNHud = {
	Available = function()
		return BVNUIData ~= nil and BVNUIData["$fight$MC_fightUI"] ~= nil
	end,

	Draw = function(b)
		local root = BVNUIData["$fight$MC_fightUI"].parts
		local ov = {["hpbarmc/scoremc"] = {hide = true}}
		for side = 1, 2 do
			local f = b.fighters[side]
			local bar, en, face, win, qi = "hpbarmc/bar" .. side, "hpbarmc/energy" .. side, "hpbarmc/face" .. side,
				"hpbarmc/win_p" .. side, "fzqi" .. side
			f.hpShow = f.hpShow or f.hp
			if f.hpShow > f.hp then f.hpShow = math.max(f.hp, f.hpShow - f.hpMax * 0.004) else f.hpShow = f.hp end
			ov[bar .. "/bar"] = {sx = math.max(0, f.hp / f.hpMax)}
			ov[bar .. "/redbar"] = {sx = math.max(0, f.hpShow / f.hpMax)}
			ov[en .. "/barmc/bar"] = {sx = math.max(0, f.energy / f.energyMax)}
			ov[en .. "/txtmc"] = {frame = (f.char.comic_type or 0) + 1, unflip = side == 2}
			local fb = f.info.urls.face_bar and ("bvn/face/" .. f.info.urls.face_bar)
			ov[face .. "/face/ct"] = {draw = image(fb, 0, 0)}
			ov[face .. "/face2"] = {hide = true}
			ov[face .. "/face3"] = {hide = true}
			for i = 1, 2 do
				ov[win .. "/w" .. i] = b.wins[side] >= i and {frame = 999} or {hide = true}
			end
			local bars = math.floor(f.qi / 100)
			ov[qi .. "/barmc/bar"] = {sx = f.qi >= f.qiMax and 1 or (f.qi % 100) / 100}
			ov[qi .. "/barmc/txtmc"] = {frame = bars + 1}
			ov[qi .. "/fzqibar/barmc"] = {sx = f.assist and f.fzqi / f.fzqiMax or 0}
			local af = f.assistInfo and ("bvn/face/" .. f.assistInfo.urls.face)
			ov[qi .. "/facemc/ct"] = {draw = image(af, 0, 0, 34)}
			if not f.assist or f.fzqi < 100 then ov[qi .. "/readymc"] = {hide = true} end
			local hits = "hits" .. side
			if f.combo >= 2 then
				ov[hits .. "/ct"] = {draw = digits("$fight$MC_hitsNumer", f.combo, f.combo >= 10 and 2 or 1, 26)}
			else
				ov[hits] = {hide = true}
			end
		end
		if b.time >= 0 then
			ov["hpbarmc/timemc/wuxian"] = {hide = true}
			ov["hpbarmc/timemc"] = {draw = function(a, d, tx, ty, al, order)
				digits("$fight$MC_timeNumber", b.time, 2, 20)(a, d, tx + a * -22, ty + d * -15, al, order + 1)
			end}
		end
		draw(root, SCALE, SCALE, OX, 0, ov, "", 255, 10)
		-- Names under the bars (the original shows them on the select screen only).
		for side = 1, 2 do
			local f = b.fighters[side]
			local name = f.info.name
			local w = BVNDraw.TextWidth(name, 18)
			local x = side == 1 and (OX + 70 * SCALE) or (OX + (800 - 70) * SCALE - w)
			BVNDraw.Text(name, x, 66 * SCALE, 18, {255, 255, 255})
		end
	end,
}
