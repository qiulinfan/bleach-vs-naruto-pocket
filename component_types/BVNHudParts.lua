-- Drawing helpers for the fight HUD (BVNHud): part trees exported by
-- tools/convert_ui.py (BVNUIData), timeline tracks, MCNumber digits, font1 text,
-- and TrainingInputHistoryUI. Everything here works in the 800x600 stage under a
-- scale + translate transform (a, d, tx, ty) to UI pixels. Not attached to any actor.
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

local function image(img, a, d, tx, ty, x, y, alpha, order, tint)
	local w, h = size(img)[1], size(img)[2]
	local x0, x1 = tx + a * x, tx + a * (x + w)
	local y0, y1 = ty + d * y, ty + d * (y + h)
	local r, g, b = 255, 255, 255
	if tint then r, g, b = tint[1], tint[2], tint[3] end
	Image.DrawUIScaled(img, math.min(x0, x1), math.min(y0, y1), a, d, r, g, b, math.floor(alpha + 0.5), order)
end

-- Merged track frames: the track's top-level named nodes take the settled tree's content.
local merged = setmetatable({}, {__mode = "k"})

BVNHudParts = {
	Size = size,
	Image = image,

	-- Draws a part tree. ov maps node paths ("hpbarmc/bar1/bar") to overrides:
	-- hide, sx / sy (scale about the node's origin), frame, m (replacement
	-- matrix), dx / dy (offset in the parent's units), alpha (multiplier),
	-- draw / after (callbacks (a, d, tx, ty, alpha, order) before / after the
	-- node's content), only (callbacks without content). pick limits the top
	-- level to the named nodes in it.
	Draw = function(parts, a, d, tx, ty, ov, path, alpha, order, pick)
		local P = BVNHudParts
		for _, p in ipairs(parts) do
			if p.img then
				if not pick then image(p.img, a, d, tx, ty, p.x, p.y, alpha, order) end
			elseif not pick or pick[p.name] then
				local key = path .. p.name
				local o = ov[key]
				if not (o and o.hide) then
					local m = (o and o.m) or p.m
					local ca, cd = a * m[1], d * m[4]
					local ctx, cty = tx + a * (m[5] + (o and o.dx or 0)), ty + d * (m[6] + (o and o.dy or 0))
					if o and o.sx then ca = ca * o.sx end
					if o and o.sy then cd = cd * o.sy end
					local al = alpha * (p.alpha or 1) * (o and o.alpha or 1)
					if al > 0.5 then
						if o and o.draw then o.draw(ca, cd, ctx, cty, al, order) end
						local sub = p.parts
						if p.frames then sub = p.frames[math.max(1, math.min(#p.frames, (o and o.frame) or 1))] end
						if sub and not (o and o.only) then P.Draw(sub, ca, cd, ctx, cty, ov, key .. "/", al, order) end
						if o and o.after then o.after(ca, cd, ctx, cty, al, order) end
					end
				end
			end
		end
	end,

	-- Frame f (1-based) of a track, its named nodes filled from the settled tree `settled`.
	TrackFrame = function(track, f, settled)
		local cache = merged[track]
		if not cache then
			cache = {}
			merged[track] = cache
		end
		f = math.max(1, math.min(#track.frames, f))
		local out = cache[f]
		if out then return out end
		local byName = {}
		for _, p in ipairs(settled) do
			if p.name then byName[p.name] = p end
		end
		out = {}
		for _, p in ipairs(track.frames[f]) do
			if p.img then
				out[#out + 1] = p
			else
				local s = byName[p.name]
				if s then out[#out + 1] = {name = p.name, m = p.m, alpha = p.alpha, parts = s.parts, frames = s.frames} end
			end
		end
		cache[f] = out
		return out
	end,

	-- One step of a self-playing clip on a track: stop() frames hold, gotoAndStop(n) jumps.
	StepClip = function(track, f)
		for _, s in ipairs(track.stops) do
			if s == f then return f end
		end
		f = f + 1
		if track.gotos[f] then return track.gotos[f] end
		if f > #track.frames then return 1 end
		return f
	end,

	IsStop = function(track, f)
		for _, s in ipairs(track.stops) do
			if s == f then return true end
		end
		return false
	end,

	-- MCNumber(cls, 0, 1, gap, len): digit d on frame d + 1, `gap` apart, zero-padded to len.
	NumberText = function(n, len)
		n = math.max(0, math.floor(n))
		if len and len > 0 then return string.format("%0" .. len .. "d", n) end
		return tostring(n)
	end,

	-- Bounds of the digits as MCNumber lays them out (DisplayObject.width / x).
	NumberBounds = function(sym, s, gap)
		local frames = BVNUIData[sym] and BVNUIData[sym].frames
		local x0, x1 = math.huge, -math.huge
		if not frames then return 0, 0 end
		for i = 1, #s do
			for _, p in ipairs(frames[tonumber(s:sub(i, i)) + 1] or {}) do
				if p.img then
					local x = (i - 1) * gap + p.x
					x0, x1 = math.min(x0, x), math.max(x1, x + size(p.img)[1])
				end
			end
		end
		if x0 > x1 then return 0, 0 end
		return x0, x1
	end,

	Digits = function(sym, s, gap, a, d, tx, ty, alpha, order)
		local frames = BVNUIData[sym] and BVNUIData[sym].frames
		if not frames then return end
		for i = 1, #s do
			local fr = frames[tonumber(s:sub(i, i)) + 1]
			if fr then BVNHudParts.Draw(fr, a, d, tx + a * (i - 1) * gap, ty, {}, "", alpha, order) end
		end
	end,

	-- font1 (BitmapFontText) ---------------------------------------------------------
	FontWidth = function(s)
		local f = BVNUIData and BVNUIData.font1
		if not f then return #s * 14 end
		local w = 0
		for _, code in utf8.codes(s) do
			local ch = f.chars[code]
			w = w + (ch and ch.adv or 14)
		end
		return w
	end,

	-- Text with its top-left at stage (x, y), scaled by k, under (a, d, tx, ty).
	-- highlight: ColorTransform(1, 1, 1, 1, 50, -30, -30) as a multiply plus an additive pass.
	Font = function(s, x, y, k, a, d, tx, ty, alpha, order, highlight)
		local f = BVNUIData and BVNUIData.font1
		if not f then return end
		local cx = x
		for _, code in utf8.codes(s) do
			local ch = f.chars[code]
			if ch and ch.img then
				local px, py = tx + a * (cx + ch.xo * k), ty + d * (y + ch.yo * k)
				local al = math.floor(alpha + 0.5)
				if highlight then
					Image.DrawUIScaled(ch.img, px, py, a * k, d * k, 255, 225, 225, al, order)
					Image.DrawUIScaled(ch.img, px, py, a * k, d * k, 50, 0, 0, al, order, "add")
				else
					Image.DrawUIScaled(ch.img, px, py, a * k, d * k, 255, 255, 255, al, order)
				end
			end
			cx = cx + (ch and ch.adv or 14) * k
		end
	end,

	-- TrainingInputHistoryUI -----------------------------------------------------------
	-- The original listens to FighterEvent.DO_ACTION, whose params carry the command
	-- text (FighterInputCmd). A fighter that queues those events in
	-- `trainingInputs` ({input = "SJ", action = label, highlight = bool}) is read
	-- exactly; otherwise the commands are inferred from its action labels, jumps,
	-- ghost steps and assist calls.
	History = {
		BASE_Y = 490, TOP_Y = 150, LINE_GAP = 34, TEXT_SCALE = 0.7,
		MOVE_TICKS = 0.12 * 60, FADE_TICKS = 0.5 * 60, IDLE_HOLD = 60,
		ACTION_TEXT = {
			["砍技1"] = "SJ", ["砍技2"] = "WJ", ["招1"] = "U", ["招2"] = "SU", ["招3"] = "WU",
			["必杀"] = "I", ["上必杀"] = "WI", ["超必杀"] = "SI", ["空中必杀"] = "KI", ["跳砍"] = "KJ",
			["跳招"] = "KU", ["跳招-上"] = "WKU", ["跳招-下"] = "SKU", ["瞬步"] = "L", ["跳"] = "K",
			["落"] = "SK", ["万解"] = "JK", ["万解W"] = "WJK", ["万解S"] = "SJK",
		},

		New = function(side, alignRight)
			local H = BVNHudParts.History
			local maxItems = math.floor((H.BASE_Y - H.TOP_Y) / H.LINE_GAP) - 1 + 1
			return {side = side, right = alignRight, items = {}, fading = {}, maxItems = maxItems,
				idle = 0, prevLeft = false, prevRight = false, prevState = -1, comboOpen = false}
		end,

		IsMoveOrGuard = function(s) return s == "A" or s == "D" or s == "S" end,

		Layout = function(h, animate)
			local H = BVNHudParts.History
			local n = #h.items
			for i, it in ipairs(h.items) do
				local ty = H.BASE_Y - (n - 1 - i) * H.LINE_GAP
				if animate then
					it.y0, it.y1, it.t = it.y, ty, 0
				else
					it.y, it.y1, it.t = ty, ty, nil
				end
			end
		end,

		Fade = function(h, it)
			it.fade = 0
			it.t = nil
			h.fading[#h.fading + 1] = it
		end,

		Push = function(h, text, highlight)
			local H = BVNHudParts.History
			if not text then return end
			if text == "SL" then
				local last = h.items[#h.items]
				if last and last.text == "S" then
					table.remove(h.items)
					H.Layout(h, false)
				end
			end
			local moveOrGuard = H.IsMoveOrGuard(text)
			if moveOrGuard or highlight then
				h.comboOpen = false
			elseif h.comboOpen then
				local last = h.items[#h.items]
				if last and not H.IsMoveOrGuard(last.text) then
					last.text = last.text .. "-" .. text
					h.idle, h.pushed = 0, true
					return
				end
			end
			while #h.items >= h.maxItems do H.Fade(h, table.remove(h.items, 1)) end
			h.items[#h.items + 1] = {text = text, highlight = highlight, y = H.BASE_Y}
			h.idle, h.pushed = 0, true
			h.comboOpen = not moveOrGuard and not highlight
			H.Layout(h, true)
		end,

		ClearAll = function(h)
			for _, it in ipairs(h.items) do BVNHudParts.History.Fade(h, it) end
			h.items = {}
			h.comboOpen = false
		end,

		-- The command a new action label stands for (actionToText).
		ActionText = function(f, label)
			local H = BVNHudParts.History
			if not label then return nil end
			local inp = f.input
			local function side()
				if inp and inp.right then return "D" end
				if inp and inp.left then return "A" end
				return (f.direct or f.dir or 1) > 0 and "D" or "A"
			end
			if label == "摔1" then return side() .. "J" end
			if label == "摔2" then return side() .. "U" end
			if H.ACTION_TEXT[label] then return H.ACTION_TEXT[label] end
			if label:sub(1, #"砍") == "砍" and label:sub(1, #"砍技") ~= "砍技" then return "J" end
			return nil
		end,

		-- Commands this tick when the fighter does not queue DO_ACTION events.
		Infer = function(h, f, out)
			local H = BVNHudParts.History
			local label, frame = f.doingAction, f.doActionFrame or 0
			if label and (label ~= h.lastAction or frame < (h.lastFrame or 0)) then
				if label == "起身" then
					out[#out + 1] = {"L", true}
				else
					local t = H.ActionText(f, label)
					if t then out[#out + 1] = {t, false} end
				end
			end
			h.lastAction, h.lastFrame = label, frame
			local jd = f.jumpDelay or 0
			if jd > (h.lastJump or 0) and f.isJumping then out[#out + 1] = {"K", false} end
			h.lastJump = jd
			if f.ghost and f.ghost ~= h.lastGhost then out[#out + 1] = {f.ghost.kind == 1 and "WL" or "SL", false} end
			h.lastGhost = f.ghost
			local fz = f.fzqi or 0
			if (h.lastFz or 0) >= (f.fzqiMax or 100) and fz <= 0 then
				out[#out + 1] = {"O", f.state ~= nil and f.state >= 21 and f.state <= 24}
			end
			h.lastFz = fz
		end,

		-- TrainingInputHistoryUI.render, once per game tick.
		Render = function(h, b, f)
			local H = BVNHudParts.History
			h.pushed = false
			for i = #h.fading, 1, -1 do
				local it = h.fading[i]
				it.fade = it.fade + 1
				if it.fade >= H.FADE_TICKS then table.remove(h.fading, i) end
			end
			for _, it in ipairs(h.items) do
				if it.t then
					it.t = it.t + 1
					local u = math.min(1, it.t / H.MOVE_TICKS)
					it.y = it.y0 + (it.y1 - it.y0) * (1 - (1 - u) * (1 - u))
					if u >= 1 then it.t = nil end
				end
			end
			local inp = f and f.input
			if not b.actionEnable or not f then
				h.prevLeft, h.prevRight = inp and inp.left or false, inp and inp.right or false
				h.prevState = f and f.state or -1
				h.lastAction, h.lastFrame, h.lastJump, h.lastGhost, h.lastFz = f and f.doingAction, f and f.doActionFrame,
					f and f.jumpDelay, f and f.ghost, f and f.fzqi
				return
			end
			-- DO_ACTION (onDoAction).
			local events = {}
			if f.trainingInputs then
				for _, e in ipairs(f.trainingInputs) do
					local text = e.input or H.ActionText(f, e.action)
					if text then events[#events + 1] = {text, e.highlight and true or false} end
				end
				f.trainingInputs = {}
			else
				H.Infer(h, f, events)
			end
			for _, e in ipairs(events) do H.Push(h, e[1], e[2]) end
			-- FighterEvent.IDLE: the combo closes and the move edges reset.
			local state = f.state
			if state == 0 and h.prevState ~= 0 and h.prevState ~= -1 then
				h.comboOpen = false
				h.prevLeft, h.prevRight = false, false
			end
			-- sampleMoveAndGuard.
			local left, right = inp and inp.left or false, inp and inp.right or false
			if state == 0 and left and not h.prevLeft then H.Push(h, "A") end
			if state == 0 and right and not h.prevRight then H.Push(h, "D") end
			h.prevLeft, h.prevRight = left, right
			if state == 20 and h.prevState ~= 20 then
				local dash = inp and inp.held and inp.held.dash
				local last = h.items[#h.items]
				if not dash and not (last and last.text == "SL" and inp and inp.down) then H.Push(h, "S") end
			end
			h.prevState = state
			-- updateIdleClear.
			local standIdle = state == 0 and f.CurLabel and f:CurLabel() == "站立"
			if not h.pushed and standIdle then
				if h.idle < H.IDLE_HOLD then h.idle = h.idle + 1 end
				if h.idle >= H.IDLE_HOLD then
					H.ClearAll(h)
					h.idle = 0
				end
			else
				h.idle = 0
			end
		end,

		Draw = function(h, x, a, d, tx, ty, order)
			local H = BVNHudParts.History
			local k = H.TEXT_SCALE
			local function one(it, alpha)
				local w = BVNHudParts.FontWidth(it.text) * k
				local ix = h.right and (x - w) or x
				BVNHudParts.Font(it.text, ix, it.y, k, a, d, tx, ty, alpha, order, it.highlight)
			end
			for _, it in ipairs(h.fading) do one(it, 255 * (1 - it.fade / H.FADE_TICKS)) end
			for _, it in ipairs(h.items) do one(it, 255) end
		end,
	},
}
