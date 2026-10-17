-- A playing instance of a converted SWF sprite: frame, label lookup, the
-- translated frame scripts, animated children and drawing. Not attached to any actor.
--
-- Flash rules kept here: entering a frame (nextFrame / gotoAndStop) runs that
-- frame's script; nextFrame on the last frame stays; a child placement (serial)
-- that persists across frames keeps its own playhead.

local function labelFrames(data)
	if data._labelOf then return end
	local byFrame = {}
	for name, f in pairs(data.labels) do byFrame[f] = name end
	local of, cur = {}, nil
	for i = 1, #data.frames do
		if byFrame[i] then cur = byFrame[i] end
		of[i] = cur
	end
	data._labelOf = of
	data._labelAt = byFrame
end

-- MovieClip methods scripts may call on `this` (self).
local ClipAPI = {}
function ClipAPI.stop(self) self._clip.playing = false end
function ClipAPI.play(self) self._clip.playing = true end
function ClipAPI.gotoAndPlay(self, f) BVNClip.Goto(self._clip, f); self._clip.playing = true end
function ClipAPI.gotoAndStop(self, f) BVNClip.Goto(self._clip, f); self._clip.playing = false end
function ClipAPI.nextFrame(self) BVNClip.Next(self._clip) end
function ClipAPI.prevFrame(self) BVNClip.Goto(self._clip, math.max(1, self._clip.frame - 1)) end
function ClipAPI.getChildByName(self, name) return self[name] end
function ClipAPI.addEventListener() end
function ClipAPI.removeEventListener() end
function ClipAPI.hasEventListener() return false end

local instMT = {}
instMT.__index = function(t, k)
	local clip = rawget(t, "_clip")
	if k == "currentFrame" then return clip.frame end
	if k == "totalFrames" then return #clip.data.frames end
	if k == "currentLabel" or k == "currentFrameLabel" then return BVNClip.Label(clip) end
	local methods = clip.methods
	local m = methods and methods[k]
	if m ~= nil then return m end
	m = ClipAPI[k]
	if m ~= nil then return m end
	-- Plain-table controllers (fighters, bullets) answer unknown calls with a no-op.
	return nil
end

BVNClip = {
	-- char: BVNF_<id>; sid: sprite id; parent: the script instance seen as `parent`.
	New = function(char, sid, parent, owner)
		local data = char.sprites[sid]
		if not data then return nil end
		labelFrames(data)
		local clip = {char = char, sid = sid, data = data, frame = 0, playing = true, kids = {}, owner = owner}
		local script = data.script
		clip.methods = script and script.methods or nil
		local inst = setmetatable({_clip = clip, parent = parent}, instMT)
		if script then
			for k, v in pairs(script.fields) do inst[k] = v end
		end
		clip.inst = inst
		if clip.methods and clip.methods.__init then BVNClip.Call(clip, "__init") end
		return clip
	end,

	Call = function(clip, method, ...)
		local fn = clip.methods and clip.methods[method]
		if not fn then return end
		local ok, err = pcall(fn, clip.inst, ...)
		if not ok then
			clip.errors = (clip.errors or 0) + 1
			if clip.errors <= 3 then Debug.Log("BVN script error " .. clip.char.id .. "/" .. clip.sid .. "." .. method .. ": " .. tostring(err)) end
		end
	end,

	Frame = function(clip) return clip.data.frames[clip.frame] end,

	Label = function(clip) return clip.data._labelOf[clip.frame] end,

	-- The label placed exactly on the current frame (bullets test loop / remove / hit_over).
	LabelHere = function(clip) return clip.data._labelAt[clip.frame] end,

	Find = function(clip, f)
		if type(f) == "number" then return math.max(1, math.min(#clip.data.frames, math.floor(f))) end
		return clip.data.labels[f]
	end,

	HasLabel = function(clip, name) return clip.data.labels[name] ~= nil end,

	Enter = function(clip, n)
		clip.frame = n
		BVNClip.SyncKids(clip)
		-- Timeline sounds (StartSound tags) play when their frame is entered.
		local f = clip.data.frames[n]
		if f and f.snd and not clip.silent then
			for _, snd in ipairs(f.snd) do BVNSound.Play(snd, 110) end
		end
		local script = clip.data.script
		local name = script and script.frames[n]
		if name then BVNClip.Call(clip, name) end
	end,

	Goto = function(clip, f)
		local n = BVNClip.Find(clip, f)
		if not n then return false end
		if n ~= clip.frame then BVNClip.Enter(clip, n) end
		return true
	end,

	-- Flash nextFrame: stays on the last frame.
	Next = function(clip)
		if clip.frame < #clip.data.frames then BVNClip.Enter(clip, clip.frame + 1) return true end
		return false
	end,

	SyncKids = function(clip)
		local f = clip.data.frames[clip.frame]
		local present = {}
		if f and f.kids then
			for _, k in ipairs(f.kids) do
				local serial = k[2]
				present[serial] = true
				if not clip.kids[serial] then
					local kid = BVNClip.New(clip.char, k[1], clip.inst, clip.owner)
					if kid then
						clip.kids[serial] = kid
						BVNClip.Enter(kid, 1)
					end
				end
			end
		end
		for serial in pairs(clip.kids) do
			if not present[serial] then clip.kids[serial] = nil end
		end
	end,

	-- Kernel child advance: one frame, wrapping, holding on a "stop" label.
	AdvanceKids = function(clip)
		for _, kid in pairs(clip.kids) do
			if BVNClip.Label(kid) ~= "stop" then
				if kid.frame >= #kid.data.frames then BVNClip.Enter(kid, 1) else BVNClip.Enter(kid, kid.frame + 1) end
			end
		end
	end,

	-- Draw at world pixel (x, y) facing dir; `px` converts game pixels to screen pixels.
	-- m: optional parent matrix {a,b,c,d,tx,ty} in game pixels.
	Draw = function(clip, x, y, dir, opt, m)
		local f = clip.data.frames[clip.frame]
		if not f then return end
		local a, b, c, d, tx, ty = 1, 0, 0, 1, 0, 0
		if m then a, b, c, d, tx, ty = m[1], m[2], m[3], m[4], m[5], m[6] end
		local order = opt.order or 20
		if f.img then
			BVNClip.Blit(f.img, f.x, f.y, a, b, c, d, tx, ty, x, y, dir, opt, order)
		end
		if f.kids then
			for _, k in ipairs(f.kids) do
				local kid = clip.kids[k[2]]
				if kid then
					-- Compose parent * child matrix.
					local ka, kb, kc, kd, ktx, kty = k[3], k[4], k[5], k[6], k[7], k[8]
					local nm = {a * ka + c * kb, b * ka + d * kb, a * kc + c * kd, b * kc + d * kd, a * ktx + c * kty + tx, b * ktx + d * kty + ty}
					BVNClip.Draw(kid, x, y, dir, opt, nm)
				end
			end
		end
	end,

	-- One frame image whose top-left sits at local (lx, ly) under matrix (a..ty).
	Blit = function(img, lx, ly, a, b, c, d, tx, ty, x, y, dir, opt, order)
		local s = opt.scale or 1
		local px = a * lx + c * ly + tx
		local py = b * lx + d * ly + ty
		local sx = math.sqrt(a * a + b * b)
		local rot = math.deg(math.atan(b, a))
		local det = a * d - b * c
		local sy = det / (sx ~= 0 and sx or 1)
		local wx = x + px * dir * s
		local wy = y + py * s
		local r, g, bl = 255, 255, 255
		if opt.tint then r, g, bl = opt.tint[1], opt.tint[2], opt.tint[3] end
		-- The engine flips a negatively scaled image in place, so a mirror about the
		-- image's top-left corner needs the pivot on the flipped side.
		local fx, fy = sx * s * dir, sy * s
		Image.DrawEx(img, wx / 100, wy / 100, rot * dir, fx, fy, fx < 0 and 1 or 0, fy < 0 and 1 or 0, r, g, bl, opt.alpha or 255, order)
	end,
}
