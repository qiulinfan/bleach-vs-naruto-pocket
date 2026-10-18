-- Runtime for the original out-of-battle screens: movies exported by
-- tools/convert_ui.py (data/bvn/ui/<name>.lua, loaded on demand), the font1
-- bitmap font, menu input in the original's terms (GameInputer MENU / P1 / P2),
-- and the tween curves the stages use. Screens are laid out on the original
-- 800x600 stage, shown 1.2x and centred in the 1280x720 window.
-- Not attached to any actor.
local SCALE, OX = 1.2, 160
local WORLD = 100 -- world units per screen pixel at the menu camera

local cache = {}
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

local function mul(m, n)
	return {m[1] * n[1] + m[3] * n[2], m[2] * n[1] + m[4] * n[2], m[1] * n[3] + m[3] * n[4], m[2] * n[3] + m[4] * n[4],
		m[1] * n[5] + m[3] * n[6] + m[5], m[2] * n[5] + m[4] * n[6] + m[6]}
end

local Clip = {}
Clip.__index = Clip

BVNScreen = {
	SCALE = SCALE,
	OX = OX,
	ID = {1, 0, 0, 1, 0, 0},
	Mul = mul,
	Size = size,

	-- Matrix helpers on {a, b, c, d, tx, ty}.
	T = function(x, y) return {1, 0, 0, 1, x, y} end,
	TS = function(x, y, sx, sy) return {sx, 0, 0, sy or sx, x, y} end,

	-- Movie data, loaded once from data/bvn/ui.
	Load = function(name)
		local m = cache[name]
		if m ~= nil then return m or nil end
		local path = Application.GetProjectDirectory() .. "/data/bvn/ui/" .. name .. ".lua"
		local f = io.open(path, "rb")
		if not f then
			cache[name] = false
			return nil
		end
		local src = f:read("a")
		f:close()
		local chunk = load(src, "@" .. name .. ".lua", "t")
		m = chunk and chunk() or false
		if m then Net.Static(m) end -- movie data never changes (netplay rollback)
		cache[name] = m
		return m or nil
	end,

	-- Drops movies not named in `keep` (a set), e.g. after leaving a stage.
	Release = function(keep)
		for k in pairs(cache) do
			if not (keep and keep[k]) then cache[k] = nil end
		end
	end,

	-- A playing movie. Frames advance at the original UI rate (30 fps: every 2nd tick).
	Clip = function(name, frame, playing)
		local c = setmetatable({name = name, m = BVNScreen.Load(name), f = frame or 0, playing = playing ~= false, tick = 0,
			done = false}, Clip)
		c:Enter()
		return c
	end,

	-- Draws one image under matrix m (800x600 stage coordinates).
	-- mode "world" draws in world space (rotation supported); "ui" in screen space.
	Image = function(img, m, alpha, order, mode, tint)
		if alpha <= 0 then return end
		local w, h = size(img)[1], size(img)[2]
		local a, b, c, d = m[1] * SCALE, m[2] * SCALE, m[3] * SCALE, m[4] * SCALE
		local tx, ty = OX + m[5] * SCALE, m[6] * SCALE
		local r, g, bl = 255, 255, 255
		if tint then r, g, bl = tint[1], tint[2], tint[3] end
		local al = math.max(0, math.min(255, alpha * 255))
		if math.abs(b) < 1e-3 and math.abs(c) < 1e-3 then
			local x = tx + math.min(0, a * w)
			local y = ty + math.min(0, d * h)
			if mode == "ui" then
				Image.DrawUIScaled(img, x, y, a, d, r, g, bl, al, order)
			else
				Image.DrawEx(img, x / WORLD, y / WORLD, 0, a, d, 0, 0, r, g, bl, al, order)
			end
			return
		end
		local sx = math.sqrt(a * a + b * b)
		local rot = math.deg(math.atan(b, a))
		local sy = (a * d - b * c) / sx
		if mode == "ui" then
			Image.DrawUIScaled(img, tx, ty, sx, sy, r, g, bl, al, order)
		else
			Image.DrawEx(img, tx / WORLD, ty / WORLD, rot, sx, sy, 0, sy < 0 and 1 or 0, r, g, bl, al, order)
		end
	end,

	-- Static or slot text from a movie entry, or free text: stage coordinates.
	-- Text is drawn by the engine after every image, so text under an overlay
	-- (dialog, transition) is skipped: BVNScreen.textFloor is the lowest order shown.
	textFloor = -math.huge,

	Text = function(s, x, y, size, color, align, w, alpha, order)
		if not s or s == "" then return end
		if (order or 0) < BVNScreen.textFloor then return end
		local px = math.max(6, math.floor(size * SCALE + 0.5))
		local lines = {}
		for line in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
		for i, line in ipairs(lines) do
			local lw = BVNDraw.TextWidth(line, px) / SCALE
			local lx = x
			if align == "center" then lx = x + ((w or 0) - lw) / 2
			elseif align == "right" then lx = x + (w or 0) - lw end
			Text.Draw(line, math.floor(OX + lx * SCALE), math.floor((y + (i - 1) * size * 1.3) * SCALE), BVNDraw.FONT, px,
				color[1], color[2], color[3], math.max(0, math.min(255, (alpha or 1) * 255)))
		end
	end,

	-- font1 (BitmapFontText) ------------------------------------------------------------
	FontWidth = function(s, scale)
		local f = BVNUIData and BVNUIData.font1
		if not f then return 0 end
		local w = 0
		for _, code in utf8.codes(s) do
			local ch = f.chars[code]
			w = w + (ch and ch.adv or 14)
		end
		return w * (scale or 1)
	end,

	FontHeight = function(scale)
		local f = BVNUIData and BVNUIData.font1
		return (f and f.lineHeight or 35) * (scale or 1)
	end,

	-- Bitmap-font text with its top-left at (x, y) under matrix tf.
	Font = function(s, x, y, scale, alpha, order, mode, tint, tf)
		local f = BVNUIData and BVNUIData.font1
		if not f then
			BVNScreen.Text(s, x, y + 8, 22 * (scale or 1), tint or {255, 230, 120}, "left", nil, alpha, order)
			return
		end
		scale = scale or 1
		local cx = x
		for _, code in utf8.codes(s) do
			local ch = f.chars[code]
			if ch and ch.img then
				local m = {scale, 0, 0, scale, cx + ch.xo * scale, y + ch.yo * scale}
				if tf then m = mul(tf, m) end
				BVNScreen.Image(ch.img, m, alpha or 1, order, mode, tint)
			end
			cx = cx + (ch and ch.adv or 14) * scale
		end
	end,

	-- Letterbox: the original stage is 800x600; hide whatever lies outside it.
	Bars = function(order)
		BVNDraw.UI(0, 0, OX, 720, {0, 0, 0}, 255, order or 900)
		BVNDraw.UI(OX + 800 * SCALE, 0, 1280 - OX - 800 * SCALE, 720, {0, 0, 0}, 255, order or 900)
	end,

	Fill = function(c, a, order, mode)
		if mode == "world" then
			BVNDraw.Rect(OX, 0, 800 * SCALE, 720, c, a, order)
		else
			BVNDraw.UI(OX, 0, 800 * SCALE, 720, c, a, order)
		end
	end,

	-- Rectangle in stage coordinates.
	Rect = function(x, y, w, h, c, a, order, mode)
		if mode == "world" then
			BVNDraw.Rect(OX + x * SCALE, y * SCALE, w * SCALE, h * SCALE, c, a, order)
		else
			BVNDraw.UI(OX + x * SCALE, y * SCALE, w * SCALE, h * SCALE, c, a, order)
		end
	end,

	-- Input -------------------------------------------------------------------------------
	-- Called once per tick before any stage reads input.
	Poll = function()
		local s = BVNScreen.inp or {prev = {0, 0}, edge = {0, 0}}
		BVNScreen.inp = s
		for side = 1, 2 do
			local v = Input.GetActionValue("p" .. side .. "_move")
			local p = s.prev[side]
			s.edge[side] = (v > 0.5 and p <= 0.5) and 1 or ((v < -0.5 and p >= -0.5) and -1 or 0)
			s.prev[side] = v
		end
	end,

	-- GameInputer.<kind>(type, 1): kind up/down/left/right/select/back, who "menu", 1 or 2.
	-- In a net session (BVNScreen.net) "menu" is either player and the shared
	-- confirm does not pick for a side: each side picks with its own attack.
	Down = function(kind, who)
		if BVNScreen.net then
			if who == "menu" and kind ~= "back" then
				if kind == "select" and Input.GetActionDown("confirm") then return true end
				return BVNScreen.Down(kind, 1) or BVNScreen.Down(kind, 2)
			end
			if kind == "select" then return Input.GetActionDown(who == 2 and "p2_attack" or "p1_attack") end
		end
		local s = BVNScreen.inp or {edge = {0, 0}}
		local A = Input.GetActionDown
		local side = who == 2 and 2 or 1
		local p = "p" .. side .. "_"
		if kind == "up" then return A(p .. "up") end
		if kind == "down" then return A(p .. "down") end
		if kind == "left" then return s.edge[side] < 0 end
		if kind == "right" then return s.edge[side] > 0 end
		if kind == "back" then return A("back") end
		if kind == "select" then
			if who == "menu" then
				return A("confirm") or A("p1_attack") or A("p1_jump") or A("p1_dash") or A("p1_skill") or A("p1_super")
					or A("p1_assist")
			end
			if side == 1 then return A("p1_attack") or A("confirm") end
			return A("p2_attack")
		end
		return false
	end,

	AnyKey = function()
		-- Raw keys are local to one machine: never in a net session.
		if not BVNScreen.net and Input.GetAnyKeyDown() then return true end
		local A = Input.GetActionDown
		for _, n in ipairs({"confirm", "back", "p1_up", "p1_down", "p1_attack", "p1_jump", "p1_dash", "p1_skill", "p1_super",
			"p1_assist"}) do
			if A(n) then return true end
		end
		local s = BVNScreen.inp
		return s and s.edge[1] ~= 0 or false
	end,

	-- Tween curves (TweenLite easings), t in [0, 1].
	Ease = {
		linear = function(t) return t end,
		backOut = function(t)
			local s = 1.70158
			t = t - 1
			return t * t * ((s + 1) * t + s) + 1
		end,
		elasticOut = function(t)
			if t <= 0 then return 0 end
			if t >= 1 then return 1 end
			local p = 0.3
			return 2 ^ (-10 * t) * math.sin((t - p / 4) * (2 * math.pi) / p) + 1
		end,
		quadOut = function(t) return 1 - (1 - t) * (1 - t) end,
	},

	-- Value of a tween from a to b over dur ticks after delay ticks, at tick t.
	Tw = function(t, a, b, dur, delay, ease)
		local k = (t - (delay or 0)) / math.max(1, dur)
		if k <= 0 then return a end
		if k >= 1 then return b end
		return a + (b - a) * (ease or BVNScreen.Ease.linear)(k)
	end,

	-- Original UI sounds (SoundCtrl.sndSelect / sndConfrim, snd_menu5, ...).
	Snd = function(name)
		local s = BVNFxData and BVNFxData.sounds and BVNFxData.sounds[name]
		if s then BVNSound.Play(s, 128) end
	end,
}

-- Clip methods -----------------------------------------------------------------------------

-- Frame-entry effects: the frame's sound, and its stop() / COMPLETE scripts.
function Clip:Enter()
	local m = self.m
	if not m then return end
	local snd = m.sounds and m.sounds[self.f]
	if snd then BVNSound.Play(snd, 128) end
	if m.stops and m.stops[self.f] then self.playing = false end
	if m.complete and m.complete[self.f] then self.done = true end
end

function Clip:Label(name)
	return self.m and self.m.labels and self.m.labels[name]
end

-- gotoAndPlay / gotoAndStop by label or 0-based frame.
function Clip:Goto(at, play)
	if type(at) == "string" then at = self:Label(at) or 0 end
	self.f = math.max(0, math.min((self.m and self.m.n or 1) - 1, at))
	self.playing = play ~= false
	self.done = false
	self.tick = 0
	self.ht = 0
	self:Enter()
end

function Clip:NextFrame()
	local n = self.m and self.m.n or 1
	self.f = (self.f + 1) % n
	self:Enter()
end

-- One logic tick: the movie advances on every 2nd tick while playing.
function Clip:Step()
	if not self.m then return end
	if not self.playing then
		self.ht = (self.ht or 0) + 1
		return
	end
	self.tick = self.tick + 1
	if self.tick % 2 == 0 then self:NextFrame() end
end

-- Draws the current frame. tf: stage matrix; slots[path](m, alpha, entry) draws
-- what the game adds at a named instance (called where it sits in the stack).
function Clip:Draw(tf, alpha, order, mode, slots)
	local m = self.m
	if not m then return end
	local f = self.f
	-- While stopped, clips inside keep playing: the exported hold frames.
	local h = not self.playing and m.holds and m.holds[f]
	if h then
		local k = math.floor((self.ht or 0) / 2)
		f = h.start - 1 + (h.once and math.min(k, h.k - 1) or k % h.k)
	end
	BVNScreen.DrawFrame(m, f, tf, alpha, order, mode, slots)
end

function BVNScreen.DrawFrame(m, f, tf, alpha, order, mode, slots)
	local fr = m.frames[m.seq[f + 1] or 1]
	if not fr then return end
	tf = tf or BVNScreen.ID
	alpha = alpha or 1
	order = order or 10
	local i, n = 1, #fr
	while i <= n do
		local e = fr[i]
		if type(e) == "number" then
			local img = m.imgs[e]
			BVNScreen.Image(img[1], mul(tf, {fr[i + 1], fr[i + 2], fr[i + 3], fr[i + 4], fr[i + 5], fr[i + 6]}), alpha * fr[i + 7],
				order, mode)
			i = i + 8
		else
			if e.slot then
				local fn = slots and slots[e.slot]
				-- A slot function returning "hide" hides the instance's own content too.
				if fn and fn(mul(tf, e.m), alpha * (e.a or 1), e) == "hide" and not e.text then
					local path = e.slot
					repeat
						i = i + 1
						local x = fr[i]
						if type(x) == "number" then i = i + 7 end
					until i > n or (type(x) == "table" and x.slotEnd == path)
				end
			elseif e.text then
				local mm = mul(tf, e.m)
				BVNScreen.Text(e.text, mm[5] + (e.left or 0) * mm[1], mm[6], e.size * mm[4], e.color, e.align, (e.w or 0) * mm[1],
					alpha * (e.a or 1), order)
			end
			i = i + 1
		end
	end
end
