-- The original screen transitions (StateCtrl / GameUI.transIn, transOut,
-- quickTrans): TransUI plays $common$MC_transition from its "fadin" or
-- "fadout" label at the UI rate (30 fps) until a "stop" frame, then runs the
-- callback; after transIn the screen stays covered until transOut.
-- QuickTransUI closes two black boxes over the middle in 0.1 s and opens them.
-- BVNGame calls Update and Draw every tick; the overlay is drawn in screen
-- space above the HUD. Not attached to any actor.
local ORDER = 2000

BVNTrans = {
	-- Covers the screen; back runs once it is covered (the cover stays).
	In = function(back)
		local T = BVNTrans
		T.clip = T.clip or BVNScreen.Clip("transition", 0, false)
		if not T.clip.m then
			T.clip = nil
			if back then back() end
			return
		end
		T.clip:Goto("fadin", false)
		T.back, T.remove, T.run = back, false, true
	end,

	-- Uncovers the screen; back runs at the end and the overlay is removed.
	Out = function(back)
		local T = BVNTrans
		T.clip = T.clip or BVNScreen.Clip("transition", 0, false)
		if not T.clip.m then
			T.clip = nil
			if back then back() end
			return
		end
		T.clip:Goto("fadout", false)
		T.back, T.remove, T.run = back, true, true
	end,

	-- quickTrans: boxes close (6 ticks) and open (6 ticks), then back.
	Quick = function(back)
		BVNTrans.quick = {t = 0, back = back}
	end,

	-- Removes the overlay at once (StateCtrl.clearTrans).
	Clear = function()
		local T = BVNTrans
		T.clip, T.run, T.back = nil, false, nil
	end,

	Busy = function()
		local T = BVNTrans
		return (T.run and true or false) or T.quick ~= nil
	end,

	-- Whether the screen is fully covered (after In finished, before Out).
	Covered = function()
		local T = BVNTrans
		return T.clip ~= nil and not T.run and not T.remove
	end,

	Update = function()
		local T = BVNTrans
		local q = T.quick
		if q then
			q.t = q.t + 1
			if q.t >= 12 then
				T.quick = nil
				if q.back then q.back() end
			end
		end
		local c = T.clip
		if not (c and T.run) then return end
		-- TransUI.renderAnimate: on a "stop" frame run the callback, else nextFrame.
		c.tick = c.tick + 1
		if c.tick % 2 ~= 0 then return end
		if c.m.stops[c.f] then
			T.run = false
			local back = T.back
			T.back = nil
			if T.remove then T.clip = nil end
			if back then back() end
			return
		end
		c:NextFrame()
		c.playing = false
	end,

	-- Whether the wipe hides the screen (text under it is skipped).
	Hiding = function()
		local c = BVNTrans.clip
		return c ~= nil and c.f >= 18 and c.f <= 50
	end,

	Draw = function()
		local T = BVNTrans
		-- The 800 px wide wipe is stretched to the whole window, so it also covers
		-- a fight's full-width view.
		if T.clip then T.clip:Draw({1280 / 960, 0, 0, 1, -BVNScreen.OX / BVNScreen.SCALE, 0}, 1, ORDER, "ui") end
		local q = T.quick
		if q then
			local k = q.t < 6 and q.t / 6 or (12 - q.t) / 6
			local h = 300 * k
			BVNDraw.UI(0, 0, 1280, h * BVNScreen.SCALE, {0, 0, 0}, 255, ORDER + 1)
			BVNDraw.UI(0, 720 - h * BVNScreen.SCALE, 1280, h * BVNScreen.SCALE, {0, 0, 0}, 255, ORDER + 1)
		end
	end,
}
