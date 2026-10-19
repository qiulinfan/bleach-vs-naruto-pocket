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
	-- A detached sprite's root clip is placed at the sprite's world position (x / y in scripts).
	if (k == "x" or k == "y") and clip.owner and clip.owner.clip == clip and clip.owner.kind ~= "fighter" then return clip.owner[k] end
	-- DisplayObject defaults; scripts that change alpha / visible on `this` affect drawing.
	if k == "alpha" or k == "scaleX" or k == "scaleY" then return 1 end
	if k == "visible" then return true end
	if k == "rotation" or k == "x" or k == "y" then return 0 end
	-- Getters the scripts define in AS3 ($self_main, $key) resolve to the runtime objects.
	if k == "S_self_main" then return clip.owner and BVNClip.Facade(clip.owner) end
	if k == "S_key" then
		local o = clip.owner
		local f = o and (o.input and o or (o.owner and (o.owner.input and o.owner or o.owner.owner)))
		return f and f.input
	end
	local methods = clip.methods
	local m = methods and methods[k]
	if m ~= nil then
		-- AS3 methods are bound closures (scripts pass this.method as a callback).
		local bound = clip.bound
		if not bound then bound = {}; clip.bound = bound end
		local b = bound[k]
		if not b then
			b = function(a, ...)
				if a == t then return m(t, ...) end
				return m(t, a, ...)
			end
			bound[k] = b
		end
		return b
	end
	m = ClipAPI[k]
	if m == nil then
		-- A named data child of the current frame (hit checkers such as sh10): a display
		-- object that can hitTest another.
		local f = clip.data.frames[clip.frame]
		local r = f and f.hits and (f.hits[k] or f.hits["#" .. k])
		local o = clip.owner
		if r and #r == 4 and o and o.clip == clip and o.WorldRect then
			local wr = o:WorldRect(r)
			return {hitTestObject = function(_, other)
				local b = BVNClip.BoundsOf(other)
				return b ~= nil and BVNClip.Hit(wr, b)
			end, x = r[1], y = r[2], width = r[3], height = r[4]}
		end
	end
	if m ~= nil then return m end
	-- Plain-table controllers (fighters, bullets) answer unknown calls with a no-op.
	return nil
end

-- The AS3 view of a game sprite (FighterMain, FighterAttacker, Bullet) for scripts that reach
-- it directly: property names map to the runtime's fields.
local FIELD = {isAllowBeHit = "allowBeHit", isAlive = "alive", isSteelBody = "steel", isSuperSteelBody = "steelSuper",
	actionState = "state", direct = "dir", isApplyG = "applyG", isCross = "isCross", hp = "hp", hpMax = "hpMax",
	qi = "qi", energy = "energy", fzqi = "fzqi", x = "x", y = "y", isInAir = "inAir", isTouchBottom = "touchBottom"}
local facadeMT = {
	__index = function(t, k)
		local sp = rawget(t, "_sp")
		local f = FIELD[k]
		if f then return sp[f] end
		if k == "owner" then return sp.owner and BVNClip.Facade(sp.owner) end
		-- FighterMain's controller getters ($fighter_ctrler ...), for scripts that reach another fighter.
		if k == "S_fighter_ctrler" then return sp.fCtrl end
		if k == "S_mc_ctrler" then return sp.mcCtrl end
		if k == "S_effect_ctrler" then return sp.effCtrl end
		if k == "mc" then return sp.clip and sp.clip.inst end
		if k == "team" then return {id = sp.team, name = "p" .. tostring(sp.team or 1)} end
		if k == "useEnergy" then return function(_, v) if sp.UseEnergy then sp:UseEnergy(v or 0) end end end
		if k == "hasEnergy" then return function(_, v, o) return sp.HasEnergy and sp:HasEnergy(v or 0, BVNRuntime.T(o)) or false end end
		if k == "delayCall" then return function(_, fn, n) if sp.DelayCall then sp:DelayCall(fn, n or 1) end end end
		if k == "setAnimateFrameOut" then return function(_, fn, n) if sp.FrameOut then sp:FrameOut(fn, n or 1) end end end
		if k == "setVecX" then return function(_, v) sp.vx = v or 0 end end
		if k == "setVecY" then return function(_, v) sp.vy = v or 0 end end
		if k == "setVelocity" then return function(_, x, y) if sp.SetVelocity then sp:SetVelocity(x, y) end end end
		if k == "getVecX" then return function() return sp.vx or 0 end end
		if k == "getVecY" then return function() return sp.vy or 0 end end
		if k == "getIsTouchSide" then return function() return sp.touchSide or false end end
		if k == "getOwner" then return function() return sp.owner and BVNClip.Facade(sp.owner) end end
		if k == "getCtrler" then return function() return sp.fCtrl or (sp.ctrl) end end
		if k == "getBuffCtrl" then return function() return sp.fCtrl and sp.fCtrl:getBuffCtrl() end end
		if k == "getCurrentTarget" then return function() return sp.Target and BVNClip.Facade(sp:Target()) end end
		if k == "getDisplay" then return function() return t end end
		if k == "onRemove" then return function() sp.dead = true end end
		if k == "hitTestObject" then
			return function(_, other)
				local a = sp.RawBody and sp:RawBody() or (sp.Area and sp:Area())
				local b = BVNClip.BoundsOf(other)
				return a ~= nil and b ~= nil and BVNClip.Hit(a, b)
			end
		end
		if k == "addQi" then return function(_, v) if sp.AddQi then sp:AddQi(v or 0) end end end
		if k == "loseHp" then return function(_, v) if sp.LoseHp then sp:LoseHp(v or 0) end end end
		if k == "idle" then return function() if sp.Idle then sp:Idle() end end end
		local v = sp[k]
		if type(v) == "function" then return function(_, ...) return v(sp, ...) end end
		return v
	end,
	__newindex = function(t, k, v)
		local sp = rawget(t, "_sp")
		sp[FIELD[k] or k] = v
	end,
}
local facades = setmetatable({}, {__mode = "k"})

BVNClip = {
	-- The game layer a detached sprite's clip sits in (`parent` of its root clip).
	Layer = {
		setChildIndex = function(_, child, i)
			local o = child and rawget(child, "_clip") and rawget(child, "_clip").owner
			if o and type(i) == "number" then o.drawUnder = (i == 0) end
		end,
		-- swapChildren(this, target): aizen's black coffin takes its target's place, over it.
		swapChildren = function(_, child)
			local o = child and rawget(child, "_clip") and rawget(child, "_clip").owner
			if o then o.drawUnder = false end
		end,
		getChildIndex = function() return 0 end,
		addChild = function() end,
		removeChild = function() end,
		numChildren = 0,
	},

	Hit = function(a, b)
		return a[1] < b[1] + b[3] and b[1] < a[1] + a[3] and a[2] < b[2] + b[4] and b[2] < a[2] + a[4]
	end,

	-- World bounds of a display-like value: a facade, a sprite, or a {hitTestObject} child.
	BoundsOf = function(v)
		if type(v) ~= "table" then return nil end
		local sp = rawget(v, "_sp") or v
		if sp.RawBody then return sp:RawBody() end
		if sp.Area then return sp:Area() end
		return nil
	end,

	-- `parent` of a detached sprite's clip: the game layer, plus the owning fighter's
	-- controllers (frame scripts written for the fighter's timeline still reach them).
	LayerFor = function(owner)
		local f = owner
		while f and not f.fCtrl and f.owner do f = f.owner end
		return setmetatable({S_mc_ctrler = f and f.mcCtrl, S_fighter_ctrler = f and f.fCtrl, S_effect_ctrler = f and f.effCtrl},
			{__index = BVNClip.Layer})
	end,

	Facade = function(sp)
		if not sp then return nil end
		local f = facades[sp]
		if not f then
			f = setmetatable({_sp = sp}, facadeMT)
			facades[sp] = f
		end
		return f
	end,

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
		local inst = clip.inst
		if rawget(inst, "visible") == false then return end
		local ia = rawget(inst, "alpha")
		if ia and ia < 1 and not opt.capture then
			local o = {}
			for k2, v2 in pairs(opt) do o[k2] = v2 end
			o.alpha = math.floor((opt.alpha or 255) * math.max(0, ia))
			opt = o
		end
		-- Effects the Flash player blended with screen / lighten / add (drawn on black) draw
		-- additively, with their whole subtree.
		if clip.data.blend == "add" and opt.blend ~= "add" then opt = BVNClip.WithBlend(opt) end
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
					BVNClip.Draw(kid, x, y, dir, (k[9] == "add" and opt.blend ~= "add") and BVNClip.WithBlend(opt) or opt, nm)
				end
			end
		end
	end,

	-- A copy of draw options that blends additively.
	WithBlend = function(opt)
		local o = {}
		for k2, v2 in pairs(opt) do o[k2] = v2 end
		o.blend = "add"
		return o
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
		-- The engine flips a negatively scaled image in place, so a mirror about the
		-- image's top-left corner needs the pivot on the flipped side.
		local fx, fy = sx * s * dir, sy * s
		local pvx, pvy = fx < 0 and 1 or 0, fy < 0 and 1 or 0
		if opt.capture then
			opt.capture[#opt.capture + 1] = {img, wx / 100, wy / 100, rot * dir, fx, fy, pvx, pvy}
			return
		end
		local r, g, bl = 255, 255, 255
		if opt.tint then r, g, bl = opt.tint[1], opt.tint[2], opt.tint[3] end
		local a = opt.alpha or 255
		local c = opt.color
		if c then
			-- Flash colour offsets: negative ones darken (approximated by the multiplier),
			-- positive ones add light in a second additive pass.
			r = r * math.max(0, 255 + math.min(0, c[1])) / 255
			g = g * math.max(0, 255 + math.min(0, c[2])) / 255
			bl = bl * math.max(0, 255 + math.min(0, c[3])) / 255
		end
		Image.DrawEx(img, wx / 100, wy / 100, rot * dir, fx, fy, pvx, pvy, r, g, bl, a, order, nil, opt.blend)
		if c and (c[1] > 0 or c[2] > 0 or c[3] > 0) then
			Image.DrawEx(img, wx / 100, wy / 100, rot * dir, fx, fy, pvx, pvy, math.max(0, c[1]), math.max(0, c[2]), math.max(0, c[3]),
				a, order, nil, "add")
		end
	end,
}
