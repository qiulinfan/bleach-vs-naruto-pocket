-- The original fight HUD, 5DPLAY's FightUI ($fight$MC_fightUI): FightBar (HP bars
-- with HpBarLerp, energy bars, faces, time, wins, score), QiBar x2, HitsUI x2, the
-- 1P / 2P markers, TrainingInputHistoryUI and the start / KO / winner banners.
-- Parts come from BVNUIData (tools/convert_ui.py); BVNHudParts draws them.
-- The battle calls Draw every frame and StepBanner every game tick (FightUI.render,
-- and renderAnimate on every second tick). State lives in battle.hud, which lasts
-- the whole match like the original's FightUI (bars ease between rounds).
-- The 800x600 stage maps to the window at 1.2x, centred. Not attached to any actor.
local SCALE, OX = 1.2, 160
local P = setmetatable({}, {__index = function(_, k) return BVNHudParts[k] end})

local ORDER_LOW, ORDER_BANNER, ORDER_BAR, ORDER_TOP, ORDER_MARK = 12, 13, 16, 17, 18

local function findNode(parts, name)
	for _, p in ipairs(parts) do
		if p.name == name then return p end
	end
	return nil
end

local function trackOf(cls) return BVNUIData.tracks and BVNUIData.tracks[cls] end

-- AS3 Number.toString for the HP text.
local function numText(v)
	if v == math.floor(v) then return string.format("%d", v) end
	return string.format("%.15g", v)
end

-- GameMode.isSingleMode / isArcade from the battle's mode.
local function isSingle(b)
	local m = b.mode
	return not b.teamMode and (m == "arcade" or m == "cpu" or m == "pvp" or m == "watch")
end

local function isArcade(b) return b.mode == "arcade" or b.mode == "survivor" or b.arcade == true end

local function newHud(b)
	local h = {tick = 0, barIn = false, barF = 1, barAnim = false, qi = {}, hp = {}, en = {}, hits = {}, wins = {{}, {}}}
	for side = 1, 2 do
		h.qi[side] = {fadIn = false, f = 1, anim = false, proc = 0, fz = 0, ready = true, readyT = 0,
			moveType = 0, moveFin = true}
		h.hp[side] = {bar = 1, red = 1, rate = 1, redMoving = false, delay = 0, justFly = false}
		h.en[side] = {sx = 1, barF = 1, txtF = 1, overload = false, flash = false, int = 0, flashF = 2,
			tint = 0, tflash = 2}
		h.hits[side] = {f = 1, show = false, num = 0, last = 0}
	end
	if BVNHud.BITMAP_UI then
		h.barF = trackOf("$fight$MC_hpBar") and trackOf("$fight$MC_hpBar").labels.fadin_fin or 1
	end
	if b.mode == "training" then
		local H = BVNHudParts.History
		h.history = {H.New(1, false), H.New(2, true)}
	end
	return h
end

local function hudOf(b)
	local h = b.hud
	if not h then
		h = newHud(b)
		b.hud = h
	end
	return h
end

-- FighterHpBar / HpBarLerp.render.
local function renderHp(s, f)
	local rate = f.hp / f.hpMax
	if s.redMoving and rate ~= s.rate then
		s.red = s.rate
		s.redMoving = false
	end
	s.rate = rate
	local diff = rate - s.bar
	if math.abs(diff) < 0.01 then s.bar = rate else s.bar = s.bar + diff * (diff < 0 and 0.4 or 0.04) end
	local st = f.state
	if st == 21 then
		s.delay = 100
	elseif st == 22 or st == 23 then
		if s.delay > 0 then
			if not s.justFly then
				s.delay = 90
				s.justFly = true
			elseif s.delay > 0 then
				s.delay = s.delay - 1
			end
		end
	else
		s.delay = 0
		s.justFly = false
	end
	if s.delay <= 0 then
		local d2 = rate - s.red
		if math.abs(d2) < 0.01 then
			s.red = rate
			s.redMoving = false
		else
			s.red = s.red + d2 * (d2 < 0 and 0.1 or 0.02)
			s.redMoving = true
		end
	end
end

-- EnergyBar.render (EnergyBarFill + EnergyBarLabel).
local function renderEnergy(s, f)
	local rate = f.energy / f.energyMax
	if f.overload then
		if not s.overload then
			s.overload, s.flash = true, false
			s.barF, s.txtF = 2, 2
		end
	elseif rate < 0.3 then
		if not s.flash then
			s.flash, s.int, s.flashF, s.tint, s.tflash = true, 0, 2, 0, 2
		end
	elseif s.overload or s.flash then
		s.overload, s.flash = false, false
		s.barF, s.txtF = 1, 1
	end
	local diff = rate - s.sx
	if math.abs(diff) < 0.01 then s.sx = rate else s.sx = s.sx + diff * 0.4 end
	if s.flash then
		s.int = s.int + 1
		if s.int > 2 then
			s.int = 0
			s.barF = s.flashF
			s.flashF = s.flashF == 1 and 2 or 1
		end
		s.tint = s.tint + 1
		if s.tint > 2 then
			s.tint = 0
			s.txtF = s.tflash
			s.tflash = s.tflash == 1 and 2 or 1
		end
	end
end

-- QiBar.render.
local function renderQi(s, f)
	local rate = math.min(3, f.qi / 100)
	local diff = rate - s.proc
	if math.abs(diff) < 0.01 then s.proc = rate else s.proc = s.proc + diff * 0.4 end
	s.fz = f.fzqi / f.fzqiMax
	local vis = s.fz >= 1
	if s.ready ~= vis then
		s.ready = vis
		s.readyT = 0 -- mc.play() / mc.gotoAndStop(1)
	end
end

-- QiBar.moving: eases toward (x, y, scale) at 0.5 per tick.
local function moveQi(s, x, y, scale)
	if math.abs(x - s.x) < 2 and math.abs(y - s.y) < 2 and math.abs(scale - s.scale) < 0.2 then
		s.x, s.y, s.scale = x, y, scale
		s.moveFin = true
	end
	s.x = s.x + (x - s.x) * 0.5
	s.y = s.y + (y - s.y) * 0.5
	s.scale = s.scale + (scale - s.scale) * 0.5
end

local function qiOrigin(side)
	local n = findNode(BVNUIData["$fight$MC_fightUI"].parts, "fzqi" .. side)
	return n.m[5], n.m[6]
end

-- HitsUI.show / hide.
local function showHits(s, num)
	s.num = num
	local tr = trackOf("$fight$MC_hits")
	if not tr then return end
	s.f = s.show and tr.labels.update or tr.labels.fadin
	s.show = true
end

local function hideHits(s)
	if not s.show then return end
	s.show = false
	local tr = trackOf("$fight$MC_hits")
	if tr then s.f = tr.labels.fadout end
end

-- FightBar.fadIn / fadOut and QiBar.fadIn / fadOut.
local function fadeTo(h, b, inn, qiOnly)
	local hb = trackOf("$fight$MC_hpBar")
	local qb = trackOf("$fight$MC_qiBar")
	if not qiOnly and h.barIn ~= inn then
		h.barIn = inn
		if not BVNHud.BITMAP_UI and hb then
			h.barF, h.barAnim = hb.labels[inn and "fadin" or "fadout"], true
		end
	end
	for side = 1, 2 do
		local q = h.qi[side]
		if q.fadIn ~= inn then
			q.fadIn = inn
			local top = inn and BVNHud.QI_BAR_MODE == 1
			if top then
				-- FightUI.fadIn in FightQiBarMode.TOP: no animation, moved up and scaled.
				q.x, q.y, q.scale = side == 1 and 120 or 675, 60, 0.8
			end
			if not BVNHud.BITMAP_UI and qb then
				if top then
					q.f, q.anim = qb.labels.fadin_fin, false
				else
					q.f, q.anim = qb.labels[inn and "fadin" or "fadout"], true
				end
			end
		end
	end
end

-- Timeline steps of the fade animations (renderAnimate, 30 fps).
local function animateFade(f, anim, tr)
	if not anim or not tr then return f, false end
	local fin = tr.labels.fadin_fin
	local fout = tr.labels.fadout_fin
	if f == fin or f == fout then return f, false end
	return f + 1, true
end

-- FightUI.getPlayerPos: the fighter's stage position 50 px above its feet,
-- clamped to the edges (the visible 16:9 width instead of the 800 px stage).
-- The battle's drawn view (camera clamp and shake included) gives the screen position.
local function playerPos(b, f)
	local v = b.view
	local x, y
	if v then
		x = ((f.x - v.x) * v.zoom - OX) / SCALE
		y = ((f.y - 50 - v.y) * v.zoom) / SCALE
	else
		local c = b.cam
		x, y = (f.x - c.rx) * c.ss, (f.y - 50 - c.ry) * c.ss
	end
	local left, right = -OX / SCALE, (1280 - OX) / SCALE
	if x < left + 20 then x = left + 20 end
	if x > right - 20 then x = right - 20 end
	if y < 60 then y = 60 end
	if y > 600 - 5 then x = 800 - 5 end -- sic: the original sets x here
	return x, y
end

BVNHud = {
	-- GameUI.BITMAP_UI (true in every 5DPLAY shell): FightBar and QiBar show and
	-- hide at once; false plays their fadin / fadout timelines.
	BITMAP_UI = true,
	-- FightUI.QI_BAR_MODE: 0 AUTO (PC), 1 TOP (mobile: the qi bars sit under the HP bars).
	QI_BAR_MODE = 0,

	Available = function()
		return BVNUIData ~= nil and BVNUIData["$fight$MC_fightUI"] ~= nil
	end,

	-- Start / KO banner (game_start_mc): play `label` up to the next label, on animate ticks.
	-- FightUI.showStart fades the interface in; playKO / playTimeOver fade the qi bars out.
	Banner = function(b, label, stopLabel, y)
		local h = hudOf(b)
		if label == "start" or label == "start_final" then
			fadeTo(h, b, true)
		elseif label == "ko" or label == "timeover" then
			fadeTo(h, b, false, true)
		end
		local anim = BVNUIData and BVNUIData.anims and BVNUIData.anims.game_start_mc
		if not anim then return end
		local from = anim.labels[label]
		if not from then return end
		local to = stopLabel and anim.labels[stopLabel] and (anim.labels[stopLabel] - 1) or #anim.frames
		local frames = anim.rounds and anim.rounds[math.min(5, b.round)] or anim.frames
		b.banner = {anim = anim, frames = frames, f = from, to = to, y = y or 0, tick = 0}
	end,

	-- Every game tick: FightUI.render, the banner and renderAnimate on every second tick.
	StepBanner = function(b)
		BVNHud.Render(b)
		local w = b.winnerShow
		if w and w.f < w.last then w.f = w.f + 1 end
		local bn = b.banner
		if not bn then return end
		bn.tick = bn.tick + 1
		if bn.tick % 2 == 0 and bn.f < bn.to then bn.f = bn.f + 1 end
	end,

	BannerAt = function(b, label)
		local bn = b.banner
		return bn and bn.anim.labels[label] and bn.f >= bn.anim.labels[label]
	end,

	-- FightUI.render (+ the clips that play by themselves at the 60 fps stage rate).
	Render = function(b)
		if not BVNHud.Available() then return end
		local h = hudOf(b)
		h.tick = h.tick + 1
		-- GameCtrl: training fades in at once; GameStartCtrl.skip fades in too.
		if not h.barIn and (b.mode == "training" or b.phase ~= "intro") then fadeTo(h, b, true) end
		for side = 1, 2 do
			local f = b.fighters[side]
			if f then
				renderHp(h.hp[side], f)
				renderEnergy(h.en[side], f)
				local q = h.qi[side]
				renderQi(q, f)
				q.readyT = q.readyT + 1
				if q.moveTo then
					moveQi(q, q.moveTo[1], q.moveTo[2], q.moveTo[3])
					if q.moveFin then q.moveTo = nil end
				end
				-- HitsUI: shown from the second hit of a combo, hidden when the target recovers.
				local hs = h.hits[side]
				local tr = trackOf("$fight$MC_hits")
				if tr then hs.f = P.StepClip(tr, hs.f) end
				local combo = f.combo or 0
				if combo < hs.last then hideHits(hs) end
				if combo > hs.last and combo > 1 then showHits(hs, combo) end
				hs.last = combo
				if h.history then BVNHudParts.History.Render(h.history[side], b, f) end
			end
			for _, w in ipairs(h.wins[side]) do
				local tr = w.track
				if not tr.stop[w.f] then w.f = math.min(w.f + 1, tr.n) end
			end
		end
		-- renderAnimate (GameUI: every second game tick).
		if h.tick % 2 == 0 then
			local moving
			h.barF, moving = animateFade(h.barF, h.barAnim, trackOf("$fight$MC_hpBar"))
			h.barAnim = moving
			for side = 1, 2 do
				local q = h.qi[side]
				q.f, moving = animateFade(q.f, q.anim, trackOf("$fight$MC_qiBar"))
				q.anim = moving
			end
		end
	end,

	-- QiBar.moveTo / moveResume (FightUI.renderQibarPos, unused by the original's render).
	QiMoveTo = function(b, side, x, y, scale)
		local q = hudOf(b).qi[side]
		if not q.x then q.x, q.y = qiOrigin(side); q.scale = 1 end
		if q.moveType ~= 1 then q.moveType, q.moveFin = 1, false elseif q.moveFin then return end
		q.moveTo = {x, y, scale}
	end,

	QiMoveResume = function(b, side)
		local q = hudOf(b).qi[side]
		if not q.x then return end
		if q.moveType ~= 0 then q.moveType, q.moveFin = 0, false elseif q.moveFin then return end
		local x, y = qiOrigin(side)
		q.moveTo = {x, y, 1}
	end,

	-- FightUI.showWinner, then (single modes) FightBar.showWin: the round's win mark,
	-- the winner's comic (bleach / naruto) icon flashing in.
	ShowWinner = function(b, winner)
		b.winsShown = {b.wins[1], b.wins[2]}
		local h = hudOf(b)
		if isSingle(b) then
			local side = winner.side
			local wins = b.wins[side]
			if wins >= 1 and wins <= 2 then
				local slot = (side == 1) == (wins == 1) and "w1" or "w2"
				local comic = winner.char and winner.char.comic_type or 0
				local node = findNode(findNode(findNode(BVNUIData["$fight$MC_fightUI"].parts, "hpbarmc").parts,
					"win_p" .. side).parts, slot)
				if node and node.frames then
					-- winmc_bleach: in_bleach at 10, in_naruto at 30, stop() on 20 and 40.
					local tr = {n = #node.frames, stop = {[1] = true, [20] = true, [40] = true}}
					for i = #h.wins[side], 1, -1 do
						if h.wins[side][i].slot == slot then table.remove(h.wins[side], i) end
					end
					h.wins[side][#h.wins[side] + 1] = {slot = slot, f = comic == 1 and 30 or 10, track = tr}
				end
			end
		end
		local anim = BVNUIData and BVNUIData.anims and BVNUIData.anims.winnermc
		if not anim then return end
		local perfect = winner.hp >= winner.hpMax
		local last = perfect and #anim.frames or (anim.stopFrame or #anim.frames)
		b.winnerShow = {anim = anim, f = 1, last = last, x = winner.side == 1 and 30 or 546}
	end,

	ClearWinner = function(b)
		b.winnerShow = nil
		b.banner = nil
	end,

	-- startKOmc: the banner and winnermc at $winnerX / $winnerY (y 30 + 90).
	DrawBanner = function(b)
		local node = findNode(BVNUIData["$fight$MC_fightUI"].parts, "startKOmc")
		local nx = node and node.m[5] or 400
		local ox, oy = OX + (BVNHud.shakeX or 0) * SCALE, (BVNHud.shakeY or 0) * SCALE
		local bn = b.banner
		local fr = bn and bn.frames[bn.f]
		if fr and fr.img then
			Image.DrawUIScaled(fr.img, ox + (nx + fr.x) * SCALE, oy + (bn.y + fr.y) * SCALE, SCALE, SCALE, 255, 255, 255, 255,
				ORDER_BANNER)
		end
		local w = b.winnerShow
		local wfr = w and w.anim.frames[math.floor(w.f)]
		if wfr and wfr.img then
			Image.DrawUIScaled(wfr.img, ox + (nx + w.x + wfr.x) * SCALE, oy + (30 + 90 + wfr.y) * SCALE, SCALE, SCALE,
				255, 255, 255, 255, ORDER_BANNER)
		end
	end,

	Draw = function(b)
		if not BVNHud.Available() then return end
		local h = hudOf(b)
		local root = BVNUIData["$fight$MC_fightUI"].parts
		local tx, ty = OX + (BVNHud.shakeX or 0) * SCALE, (BVNHud.shakeY or 0) * SCALE
		local hbNode = findNode(root, "hpbarmc")
		local ov = {}
		local faceOf = BVNUIData.hudfaces or {}
		local function faceImage(file, w, hh)
			if not file then return nil end
			local masked = faceOf[file]
			return function(a, d, x, y, al, order)
				if masked then
					P.Image(masked, a, d, x, y, 0, 0, al, order)
				else
					local s = P.Size("bvn/face/" .. file)
					P.Image("bvn/face/" .. file, a * w / s[1], d * hh / s[2], x, y, 0, 0, al, order)
				end
			end
		end

		-- QiBar x2 and HitsUI x2 (under the FightBar and the banner).
		local qtr = trackOf("$fight$MC_qiBar")
		local htr = trackOf("$fight$MC_hits")
		for side = 1, 2 do
			local f = b.fighters[side]
			local q = h.qi[side]
			local qi = "fzqi" .. side
			local node = findNode(root, qi)
			if not q.fadIn and (BVNHud.BITMAP_UI or not q.anim) then
				ov[qi] = {hide = true}
			else
				local o = {}
				if q.x then
					local sg = node.m[1] < 0 and -1 or 1
					o.m = {sg * q.scale, 0, 0, q.scale, q.x, q.y}
				end
				ov[qi] = o
				if not BVNHud.BITMAP_UI and qtr then
					-- The fade timeline replaces the settled layout.
					local frame = P.TrackFrame(qtr, q.f, node.parts)
					o.only = true
					o.draw = function(a, d, x, y, al, order)
						P.Draw(frame, a, d, x, y, ov, qi .. "/", al, order)
					end
				end
			end
			-- InsBar.setProcess: bar1..bar3 scale, bar4 (blinking clip) at a full bar, the level digit.
			local v = q.proc
			local g = qi .. "/barmc/bar/"
			ov[g .. "bar1"] = v > 0 and {sx = v > 1 and 1 or v} or {hide = true}
			ov[g .. "bar2"] = v > 1 and {sx = v > 2 and 1 or (v - 1)} or {hide = true}
			ov[g .. "bar3"] = v > 2 and {sx = v - 2} or {hide = true}
			ov[g .. "bar4"] = (v >= 3 and h.tick % 14 < 7) and {} or {hide = true}
			ov[qi .. "/barmc/txtmc"] = {frame = math.floor(v) + 1, sx = side == 2 and -1 or nil}
			-- InsFzBar: the bar seen through a scrollRect growing from the bottom.
			local fz = BVNUIData.fzbar
			ov[qi .. "/fzqibar/barmc"] = {only = true, draw = function(a, d, x, y, al, order)
				if not fz then return end
				local k = math.floor(math.max(0, math.min(1, q.fz)) * fz.h)
				local sl = fz.slices[k]
				-- barmc.y = barmc.height once scrollRect is set: the bar's top sits at y 0, not 0.8.
				if sl then P.Image(sl.img, a, d, x, y - d * 0.8, 0, sl.y, al, order) end
			end}
			local ai = f and f.assistInfo
			ov[qi .. "/facemc/ct"] = {only = true, draw = faceImage(ai and ai.urls and ai.urls.face, 50, 50)}
			-- readymc: shown at a full assist bar; its mc blinks (14 frames on, 6 off).
			if not q.ready then
				ov[qi .. "/readymc"] = {hide = true}
			else
				ov[qi .. "/readymc/mc"] = {sx = side == 2 and -1 or nil, hide = (q.readyT % 20) >= 14}
			end

			-- HitsUI.
			local hs = h.hits[side]
			local hits = "hits" .. side
			local hnode = findNode(root, hits)
			if not htr or hs.f == 1 then
				ov[hits] = {hide = true}
			else
				local s = P.NumberText(hs.num)
				local x0, x1 = P.NumberBounds("$fight$MC_hitsNumer", s, 35)
				local xoff = -(x1 - x0) + 45
				local frame = P.TrackFrame(htr, hs.f, hnode.parts)
				ov[hits] = {only = true, dx = side == 1 and -xoff or 0, draw = function(a, d, x, y, al, order)
					P.Draw(frame, a, d, x, y, ov, hits .. "/", al, order)
				end}
				ov[hits .. "/ct"] = {only = true, draw = function(a, d, x, y, al, order)
					P.Digits("$fight$MC_hitsNumer", s, 35, a, d, x + a * xoff, y, al, order)
				end}
			end
		end
		ov.hpbarmc, ov.startKOmc = {hide = true}, {hide = true}
		P.Draw(root, SCALE, SCALE, tx, ty, ov, "", 255, ORDER_LOW)

		BVNHud.DrawBanner(b)

		-- FightBar.
		local hb = "hpbarmc/"
		local hov = {}
		local hpTexts = {}
		for side = 1, 2 do
			local f = b.fighters[side]
			if f then
				local bar, en, face = "bar" .. side, "energy" .. side, "face" .. side
				local hs = h.hp[side]
				hov[bar .. "/bar"] = {sx = math.max(0, hs.bar)}
				hov[bar .. "/redbar"] = {sx = math.max(0, hs.red)}
				if BVNSettings and BVNSettings.showHp then
					-- FighterHpBar: HP at (120, 2) and the current combo's damage at (10, 2)
					-- (x 40 mirrored on the right bar), white / yellow Arial with a drop shadow.
					hov[bar] = {after = function(a, d, x, y)
						local dmg = f.currentHurtDamage or 0
						if type(dmg) == "function" then dmg = dmg(f) end
						local sg = a < 0 and -1 or 1
						hpTexts[#hpTexts + 1] = {numText(f.hp), x + a * 120, y + d * 2, {255, 255, 255}}
						if dmg > 0 then
							hpTexts[#hpTexts + 1] = {"-" .. numText(dmg), x + a * (sg < 0 and 40 or 10), y + d * 2, {255, 255, 0}}
						end
					end}
				end
				local es = h.en[side]
				hov[en .. "/barmc/bar"] = {sx = math.max(0, es.sx), frame = es.barF}
				hov[en .. "/txtmc"] = {frame = (f.char and f.char.comic_type == 1) and 2 or 1, sx = side == 2 and -1 or nil}
				hov[en .. "/txtmc/mc"] = {frame = es.txtF}
				-- FightFaceGroup: the current fighter, then the team members still to come.
				hov[face .. "/face/ct"] = {only = true, draw = faceImage(f.info.urls.face_bar, 102, 64)}
				local team = b.opts and b.opts["p" .. side] and b.opts["p" .. side].team or {}
				for k = 2, 3 do
					local id = team[(b.teamIndex and b.teamIndex[side] or 1) + k - 1]
					local mi = id and BVNMenu and BVNMenu.FighterInfo and BVNMenu.FighterInfo(id)
					if mi and mi.urls.face_bar then
						hov[face .. "/face" .. k .. "/ct"] = {only = true, draw = faceImage(mi.urls.face_bar, 102, 64)}
					else
						hov[face .. "/face" .. k] = {hide = true}
					end
				end
				-- WinUI.
				local shown = {}
				for _, w in ipairs(h.wins[side]) do shown[w.slot] = w.f end
				for _, slot in ipairs({"w1", "w2"}) do
					hov["win_p" .. side .. "/" .. slot] = {frame = shown[slot] or 1}
				end
			end
		end
		-- FightTimeUI: MCNumber(timeNumber, gap 20, 2 digits) at (-22, -15), or the infinity mark.
		if (b.timeMax or b.time) == -1 or b.time < 0 then
			hov["timemc/wuxian"] = {}
		else
			hov["timemc/wuxian"] = {hide = true}
			local s = P.NumberText(b.time, 2)
			hov.timemc = {after = function(a, d, x, y, al, order)
				P.Digits("$fight$MC_timeNumber", s, 20, a, d, x + a * -22, y + d * -15, al, order)
			end}
		end
		-- FightScoreUI (arcade): MCNumber(scoreNumber, gap 10, 10 digits) in scoremc.ct.
		if isArcade(b) then
			local g = BVNGame and BVNGame.current
			local rate = (BVNSettings and BVNSettings.keyMode == 0) and 1 or 0.8
			local score = math.floor((g and g.score or 0) + (b.score or 0) * rate)
			local s = P.NumberText(score, 10)
			hov["scoremc/ct"] = {only = true, draw = function(a, d, x, y, al, order)
				P.Digits("$fight$MC_scoreNumber", s, 10, a, d, x, y, al, order)
			end}
		end
		local hparts = hbNode.parts
		local visible = h.barIn
		if not BVNHud.BITMAP_UI then
			local tr = trackOf("$fight$MC_hpBar")
			if tr then hparts = P.TrackFrame(tr, h.barF, hbNode.parts) end
			visible = h.barIn or h.barAnim
		end
		if visible then
			local m = hbNode.m
			local a, d = SCALE * m[1], SCALE * m[4]
			local x, y = tx + SCALE * m[5], ty + SCALE * m[6]
			-- BITMAP_UI order: bars and energy, the bar art (faces, frame, time), then wins and score.
			local late = {win_p1 = true, win_p2 = true, scoremc = true}
			local fhov = setmetatable({}, {__index = function(_, k) return hov[k] end})
			for k in pairs(late) do fhov[k] = {hide = true} end
			P.Draw(hparts, a, d, x, y, fhov, "", 255, ORDER_BAR)
			P.Draw(hparts, a, d, x, y, hov, "", 255, ORDER_TOP, late)
		end
		for _, t in ipairs(hpTexts) do
			local size = math.floor(12 * SCALE)
			BVNDraw.Text(t[1], t[2] + 3, t[3] + 3, size, {0, 0, 0}, 180)
			BVNDraw.Text(t[1], t[2], t[3], size, t[4])
		end

		-- renderPlayerPosUI: hidden when the camera zooms past 1.8.
		local c = b.cam
		if c and (c.zoom or 1) <= 1.8 then
			for side = 1, 2 do
				local f = b.fighters[side]
				local pos = BVNUIData["$fight$SP_playerPos" .. side]
				if f and pos then
					local px, py = playerPos(b, f)
					P.Draw(pos.parts, SCALE, SCALE, OX + px * SCALE, py * SCALE, {}, "", 255, ORDER_MARK)
				end
			end
		end

		-- TrainingInputHistoryUI at x 20 (P1, left aligned) and 780 (P2, right aligned).
		if h.history then
			BVNHudParts.History.Draw(h.history[1], 20, SCALE, SCALE, tx, ty, ORDER_MARK)
			BVNHudParts.History.Draw(h.history[2], 800 - 20, SCALE, SCALE, tx, ty, ORDER_MARK)
		end
	end,
}
