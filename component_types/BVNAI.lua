-- CPU opponent (FighterAICtrl / FighterAILogic): once per animate tick it rolls
-- the original rate tables against the target's state and presses the fighter's
-- input. Levels 1..6 (very easy .. hell). Not attached to any actor.
local S = {NORMAL = 0, ATTACK = 10, SKILL = 11, BISHA = 12, BISHA_SUPER = 13, JUMP = 14, HURT_ACT = 16, DEFENSE = 20,
	HURT = 21, HURT_FLY = 22, HURT_DOWN = 23, FREEZE = 40}

local R = {
	R0 = {0, 0, 0, 0, 0, 0}, R_DJ = {0, 0, .2, 1, 3, 5}, R_MV = {3, 5, 7, 8, 9, 10}, R_MV_ATK = {2, 4, 5, 3, 1, 0},
	R_MV_SK = {2, 4, 3, 2, 0, 0}, R_MV_BS = {2, 1, 0, 0, 0, 0}, R_JP_C = {1, 2, 3, 2, 1, 0}, R_JP_CH = {0, 1, 2, 3, 3, 4},
	R_JP_UP = {2, 3, 4, 5, 6, 6}, R_JP_LO = {.01, 0, 0, 0, 0, 0}, R_JP_LB = {.02, 0, 0, 0, 0, 0},
	R_DSH1 = {0, 0, .1, .5, 0, 0}, R_DSH2 = {0, .05, .3, 1, 0, 0}, R_DSH3 = {0, 0, .05, 0, 0, 0}, R_DSH4 = {.5, 1, 2, 5, 7, 9},
	R_DSH5 = {0, 0, .1, 3, 1, 0}, R_DSH6 = {0, 0, .05, 1, 0, 0}, R_DSH7 = {0, 0, .05, .1, 0, 0},
	R_DEF_C = {10, 10, 10, 10, 10, 10}, R_DEF_F = {5, 4, 4, 3, 2, 1}, R_DEF_N = {2, 1, 1, 0, 0, 0}, R_DEF_N2 = {.5, 1, 3, 5, 7, 9},
	R_DEF_F2 = {.5, 1, 3, 2, 1, 0}, R_DEF_SK = {1, 3, 5, 7, 9, 10}, R_DEF_BS = {2, 4, 6, 8, 10, 10},
	R_ATK_C = {1, 2, 3, 6, 9, 10}, R_ATK_D = {.5, 1, 4, 6, 8, 10}, R_ATK_DF = {.5, 1, 3, 2, 2, 1}, R_ATK_HA = {.5, 1, 1, .5, 0, 0},
	R_ATK_A = {.5, 1, 1, 0, 0, 0}, R_SK_B1 = {.1, .2, .5, 3, 6, 10}, R_SK_B2 = {0, .2, .5, 2, 1, 0}, R_SK_B3 = {0, .2, .7, 5, 7, 9},
	R_SK_B4 = {.1, .2, .5, 1, 2, 2}, R_SK_N1 = {0, 0, .1, 1, 5, 10}, R_SK_N2 = {.1, .5, 1, 3, 2, .2}, R_SK_N3 = {0, 0, 1, 1, 0, 0},
	R_SK_HA = {.5, 1, .5, 0, 0, 0}, R_SK_AT = {0, 0, 0, 1, 1, 2}, R_BS_B1 = {0, 0, .3, 2, 5, 10}, R_BS_B2 = {.1, .2, .5, 2, 2, 2},
	R_BS_B3 = {0, 0, .5, 3, 7, 9}, R_BS_B4 = {.1, .2, 1, 6, 8, 10}, R_BS_N1 = {0, 0, .5, 4, 8, 10}, R_BS_N2 = {.2, .5, 1, 2, 2, 0},
	R_BS_H = {.2, .5, 1, 3, 5, 6}, R_BS_J = {.2, .5, 1, 3, 4, 4}, R_BS_D1 = {.2, .5, 1, 3, 2, 1}, R_BS_D2 = {.2, .5, 1, 2, 1, 0},
	R_BS_HA = {.2, .5, 0, 0, 0, 0}, R_BS_AT = {0, .2, .5, 2, 1, 1}, R_BS_SK = {0, 0, .1, 0, 0, 0},
	R_CA_N = {0, .5, 1, 3, 2, 1}, R_CA_D = {1, 2, 4, 5, 7, 10}, R_CA_NF = {0, .5, 1, 0, 0, 0}, R_CA_DF = {1, 2, 3, 4, 3, 2},
	R_BRK = {0, 0, 0, 0, .1, .2}, R_BRK_S = {0, 0, 0, 0, .2, .4},
	R_GS = {0, 0, 0, 0, .1, .2}, R_GS_J = {0, 0, .1, .1, .1, .1},
}

local AI = {}
AI.__index = AI

BVNAI = {
	New = function(fighter, level)
		return setmetatable({f = fighter, level = level or 1, moveFrame = 60, defending = false, orders = {}}, AI)
	end,
}

function AI:Roll(row)
	local lv = math.max(1, math.min(6, self.level))
	return BVNRuntime.RAND() * 10 < row[lv]
end

-- Row by the target's state: rows = {default = R.x, [state] = R.y, ...}.
function AI:ByState(rows)
	local t = self.target
	local st = t and t.state or -1
	local row = rows[st] or rows.default
	return self:Roll(row)
end

function AI:InRange(name)
	local f, t = self.f, self.target
	local r = f:Range(name)
	local body = t and t:RawBody()
	return r ~= nil and body ~= nil and BVNBattle.Intersects(r, body)
end

function AI:CanBeHit() return self.target and self.target.allowBeHit end

-- Whether a HitVO whose id contains `id` satisfies `pred` (isBreakAct / isHitDownAct).
function AI:HitIs(id, pred)
	for hid, h in pairs(self.f.hitModel) do
		if hid:find(id, 1, true) and pred(h) then return true end
	end
	return false
end

function AI:Order(id, order) self.orders[#self.orders + 1] = {id, order} end

function AI:Think()
	local f = self.f
	local k = f.input
	k:Release()
	self.target = f:Target()
	local t = self.target
	if not t or not f.battle.actionEnable then return end
	local dx, dy = t.x - f.x, t.y - f.y
	local D, Dy = math.abs(dx), math.abs(dy)
	local toward = dx >= 0 and 1 or -1
	local s = f.state
	self.conting = s == S.ATTACK or s == S.SKILL or s == S.BISHA or s == S.BISHA_SUPER
	local a = f.act
	local flags = {}

	-- Dash.
	if a.dash then
		local hit
		local zero = {[S.ATTACK] = R.R0, [S.SKILL] = R.R0, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0}
		if f.energy < 40 then
			if D > 200 and f.dir == toward then
				hit = self:ByState({default = R.R_DSH1, [S.ATTACK] = R.R_DSH2, [S.SKILL] = R.R_DSH2, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0})
			else zero.default = R.R_DSH3; hit = self:ByState(zero) end
		else
			if D > 200 and f.dir ~= t.dir then
				hit = self:ByState({default = R.R_DSH4, [S.ATTACK] = R.R_DSH5, [S.SKILL] = R.R_DSH6, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0})
			else zero.default = R.R_DSH7; hit = self:ByState(zero) end
		end
		if hit then flags.dash = true end
	end
	-- Attack.
	if (a.attack or a.attackAIR) and self:CanBeHit() then
		local row = {default = self.conting and R.R_ATK_C or R.R_ATK_D, [S.DEFENSE] = R.R_ATK_DF, [S.HURT_ACT] = R.R_ATK_HA,
			[S.ATTACK] = R.R_ATK_A, [S.SKILL] = R.R0, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0}
		if self:ByState(row) then
			if self.conting then
				flags.attack = true
				self:Order("attack", f:CurLabel() == "砍1" and 200 or 10)
			elseif self:InRange("kanmian") or (f.inAir and self:InRange("tkanmian") and f.y < t.y) then
				flags.attack = true
				self:Order("attack", 300)
			end
		end
	end
	-- Skills (getSkillAI): ordered only inside a combo, 10 for a knock-down move, else 110.
	local skills = {{"skill1", "kj1mian", "kj1"}, {"skill2", "kj2mian", "kj2"}, {"zhao1", "zh1mian", "zh1"},
		{"zhao2", "zh2mian", "zh2"}, {"zhao3", "zh3mian", "zh3"}, {"skillAIR", "tzmian", "tz"}}
	for _, sk in ipairs(skills) do
		if a[sk[1]] then
			local row
			if self:HitIs(sk[3], function(h) return h.isBreakDef end) then
				row = {default = self.conting and R.R_SK_B1 or R.R_SK_B2, [S.DEFENSE] = self.conting and R.R_SK_B3 or R.R_SK_B4}
			else row = {default = self.conting and R.R_SK_N1 or R.R_SK_N2, [S.DEFENSE] = R.R_SK_N3} end
			row[S.HURT_ACT], row[S.ATTACK] = R.R_SK_HA, R.R_SK_AT
			row[S.SKILL], row[S.BISHA], row[S.BISHA_SUPER] = R.R0, R.R0, R.R0
			if self:ByState(row) and self:CanBeHit() and self:InRange(sk[2]) then
				flags[sk[1]] = true
				if self.conting then self:Order(sk[1], self:HitIs(sk[3], function(h) return h.hurtType == 1 end) and 10 or 110) end
			end
		end
	end
	-- Ultimates (getBishaAI): the qi gate is fixed, 300 for the super.
	local bishas = {{"bisha", "bsmian", "bs", 100, 100}, {"bishaUP", "sbsmian", "sbs", 100, 100},
		{"bishaSUPER", "cbsmian", "cbs", 300, 200}, {"bishaAIR", "kbsmian", "kbs", 100, 210}}
	for _, b in ipairs(bishas) do
		if a[b[1]] and f.qi >= b[4] then
			local row
			if self:HitIs(b[3], function(h) return h.isBreakDef end) then
				row = {default = self.conting and R.R_BS_B1 or R.R_BS_B2, [S.DEFENSE] = self.conting and R.R_BS_B3 or R.R_BS_B4}
			else
				row = {default = self.conting and R.R_BS_N1 or R.R_BS_N2, [S.HURT] = R.R_BS_H, [S.JUMP] = R.R_BS_J,
					[S.DEFENSE] = self.conting and R.R_BS_D1 or R.R_BS_D2}
			end
			row[S.HURT_ACT], row[S.ATTACK] = R.R_BS_HA, R.R_BS_AT
			row[S.SKILL], row[S.BISHA], row[S.BISHA_SUPER] = R.R_BS_SK, R.R_BS_SK, R.R_BS_SK
			if self:ByState(row) and self:CanBeHit() and self:InRange(b[2]) then
				flags[b[1]] = true
				if self.conting then self:Order(b[1], b[5]) end
			end
		end
	end
	-- Throws.
	if t.state ~= S.HURT and t.state ~= S.HURT_FLY and t.state ~= S.HURT_DOWN then
		local near = D < 50
		local row = near and {default = R.R_CA_N, [S.DEFENSE] = R.R_CA_D} or {default = R.R_CA_NF, [S.DEFENSE] = R.R_CA_DF}
		if a.catch1 and self:ByState(row) and self:CanBeHit() then flags.catch1 = true; self:Order("catch1", 150) end
		if a.catch2 and self:ByState(row) and self:CanBeHit() then flags.catch2 = true; self:Order("catch2", 110) end
	end
	-- The kernel never reads the CPU's assist roll: assists come only from the burst flag.


	-- Movement (a guarding CPU walks toward the target, which turns its guard).
	if f.state == S.DEFENSE then
		if self:Roll({1, 2, 4, 5, 6, 8}) and D > 20 then flags.move = toward end
	else
		local moving = false
		if self.moveFrame < 60 then
			moving = true
			self.moveFrame = self.moveFrame + 1
		elseif self:ByState({default = R.R_MV, [S.ATTACK] = R.R_MV_ATK, [S.SKILL] = R.R_MV_SK, [S.BISHA] = R.R_MV_BS, [S.BISHA_SUPER] = R.R_MV_BS}) then
			moving = true
			self.moveFrame = 0
		end
		if moving then
			local keep = ((flags.catch1 or flags.catch2) and Dy < 2) and 15 or 40
			if D > keep then flags.move = toward end
		end
		if not flags.move then self.moveFrame = 60 end
	end
	-- Jump.
	if self.conting then
		if self:ByState({default = R.R_JP_C, [S.HURT] = R.R_JP_CH}) then flags.jump = true; self:Order("jump", 10) end
	elseif f.y - t.y > 50 then
		if self:ByState({default = R.R_JP_UP, [S.BISHA] = R.R_MV_BS, [S.BISHA_SUPER] = R.R_MV_BS}) then flags.jump = true end
	elseif self:ByState({default = R.R_JP_LO, [S.BISHA] = R.R_JP_LB, [S.BISHA_SUPER] = R.R_JP_LB}) then
		flags.jump = true
	end
	-- Keep only the highest-order combo action.
	if #self.orders > 0 then
		table.sort(self.orders, function(x, y) return x[2] > y[2] end)
		for i = 2, #self.orders do flags[self.orders[i][1]] = nil end
		self.orders = {}
	end
	-- Drop through a platform (updateJumpDownAI).
	if f.onFloorVO then
		local row = f.y < t.y - 50 and {default = R.R_JP_UP, [S.BISHA] = R.R_MV_BS, [S.BISHA_SUPER] = R.R_MV_BS}
			or {default = R.R_JP_LO, [S.BISHA] = R.R_JP_LB, [S.BISHA_SUPER] = R.R_JP_LB}
		if self:ByState(row) then flags.jumpDown = true end
	end
	-- Ghost step (updateGhostStep): close in on a staggered target mid-combo.
	if D <= 80 and Dy <= 80 and f.qi >= 200 and (s == S.ATTACK or s == S.SKILL) then
		if self:ByState({default = R.R0, [S.HURT] = R.R_GS}) then flags.ghostStep = true end
		local up = t.y - f.y
		if up < -80 and up > -100 and self:ByState({default = R.R0, [S.HURT] = R.R_GS_J}) then flags.ghostJump = true end
	end
	-- Quick get-up.
	if f.isHurtFlying and self:ByState({default = R.R_DJ, [S.SKILL] = R.R0, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0}) then flags.dash = true end
	-- Burst (sticky in the original).
	if s == S.HURT and f.hp <= f.hpMax * 0.6 and f.qi >= 150 and self:ByState({default = R.R_BRK, [S.SKILL] = R.R_BRK_S}) then
		self.burst = true
	end
	if self.burst then flags.special = true end
	-- Guard.
	local guard = false
	if self.defending then
		guard = self:ByState({default = R.R_DEF_C, [S.FREEZE] = R.R_DEF_F, [S.NORMAL] = R.R_DEF_N, [S.HURT] = R.R0, [S.HURT_FLY] = R.R0, [S.HURT_DOWN] = R.R0})
	end
	if not guard then
		local near = D < 100 and Dy < 100
		guard = self:ByState({default = R.R0, [S.ATTACK] = near and R.R_DEF_N2 or R.R_DEF_F2, [S.SKILL] = R.R_DEF_SK,
			[S.BISHA] = R.R_DEF_BS, [S.BISHA_SUPER] = R.R_DEF_BS})
	end
	if not guard then
		for _, sp in ipairs(f.battle.sprites) do
			if sp.team ~= f.team and sp.kind ~= "fighter" and sp.isAttacking and not sp.dead then
				local near = math.abs(sp.x - f.x) < 200 and math.abs(sp.y - f.y) < 150
				local row = sp.kind == "bullet" and (near and {2, 4, 5, 7, 9, 10} or {2, 4, 5, 5, 2, 1}) or
					(sp.kind == "assist" and {2, 4, 6, 8, 10, 10} or {2, 4, 5, 7, 9, 10})
				if self:Roll(row) then guard = true break end
			end
		end
	end
	self.defending = guard

	-- Apply to the input.
	if flags.move then
		if flags.move > 0 then k.right = true else k.left = true end
	end
	if guard and not self.conting then k.down = true end
	if flags.attack then k:Press("attack") end
	if flags.skill1 then k.down = true; k:Press("attack") end
	if flags.skill2 then k.up = true; k:Press("attack") end
	if flags.zhao1 or flags.skillAIR then k:Press("skill") end
	if flags.zhao2 then k.down = true; k:Press("skill") end
	if flags.zhao3 then k.up = true; k:Press("skill") end
	if flags.bisha or flags.bishaAIR then k:Press("super") end
	if flags.bishaUP then k.up = true; k:Press("super") end
	if flags.bishaSUPER then k.down = true; k:Press("super") end
	if flags.catch1 then if toward > 0 then k.right = true else k.left = true end k:Press("attack") end
	if flags.catch2 then if toward > 0 then k.right = true else k.left = true end k:Press("skill") end
	if flags.dash then k:Press("dash") end
	if flags.jump and not flags.attack then k:Press("jump") end
	if flags.jumpDown then k.down = true; k:Press("jump") end
	if flags.ghostStep then k.down = true; k:Press("dash") end
	if flags.ghostJump then k.up = true; k:Press("dash") end
	if flags.special then k.special_held = true end
end
