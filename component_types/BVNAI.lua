-- CPU opponent: FighterAICtrl + FighterAILogic. Once per animate tick the logic rolls the
-- original rate tables against the target's state and sets its flags; the fighter reads
-- them through the same predicates as a player's keys (the CPU is its input). Levels
-- 1..6 (very easy .. hell). Not attached to any actor.
local S = {NORMAL = 0, ATTACK = 10, SKILL = 11, BISHA = 12, BISHA_SUPER = 13, JUMP = 14, HURT_ACT = 16, DEFENSE = 20,
	HURT = 21, HURT_FLY = 22, HURT_DOWN = 23, FREEZE = 40}

local R = {
	R0 = {0, 0, 0, 0, 0, 0},
	R_DJ = {0, 0, .2, 1, 3, 5}, R_MV = {3, 5, 7, 8, 9, 10}, R_MV_ATK = {2, 4, 5, 3, 1, 0}, R_MV_SK = {2, 4, 3, 2, 0, 0},
	R_MV_BS = {2, 1, 0, 0, 0, 0}, R_JP_C = {1, 2, 3, 2, 1, 0}, R_JP_CH = {0, 1, 2, 3, 3, 4}, R_JP_UP = {2, 3, 4, 5, 6, 6},
	R_JP_LO = {.01, 0, 0, 0, 0, 0}, R_JP_LB = {.02, 0, 0, 0, 0, 0},
	R_DSH1 = {0, 0, .1, .5, 0, 0}, R_DSH2 = {0, .05, .3, 1, 0, 0}, R_DSH3 = {0, 0, .05, 0, 0, 0}, R_DSH4 = {.5, 1, 2, 5, 7, 9},
	R_DSH5 = {0, 0, .1, 3, 1, 0}, R_DSH6 = {0, 0, .05, 1, 0, 0}, R_DSH7 = {0, 0, .05, .1, 0, 0},
	R_DEF_C = {10, 10, 10, 10, 10, 10}, R_DEF_F = {5, 4, 4, 3, 2, 1}, R_DEF_N = {2, 1, 1, 0, 0, 0}, R_DEF_N2 = {.5, 1, 3, 5, 7, 9},
	R_DEF_F2 = {.5, 1, 3, 2, 1, 0}, R_DEF_SK = {1, 3, 5, 7, 9, 10}, R_DEF_BS = {2, 4, 6, 8, 10, 10},
	R_ATK_C = {1, 2, 3, 6, 9, 10}, R_ATK_D = {.5, 1, 4, 6, 8, 10}, R_ATK_DF = {.5, 1, 3, 2, 2, 1}, R_ATK_HA = {.5, 1, 1, .5, 0, 0},
	R_ATK_A = {.5, 1, 1, 0, 0, 0},
	R_SK_B1 = {.1, .2, .5, 3, 6, 10}, R_SK_B2 = {0, .2, .5, 2, 1, 0}, R_SK_B3 = {0, .2, .7, 5, 7, 9}, R_SK_B4 = {.1, .2, .5, 1, 2, 2},
	R_SK_N1 = {0, 0, .1, 1, 5, 10}, R_SK_N2 = {.1, .5, 1, 3, 2, .2}, R_SK_N3 = {0, 0, 1, 1, 0, 0}, R_SK_HA = {.5, 1, .5, 0, 0, 0},
	R_SK_AT = {0, 0, 0, 1, 1, 2},
	R_BS_B1 = {0, 0, .3, 2, 5, 10}, R_BS_B2 = {.1, .2, .5, 2, 2, 2}, R_BS_B3 = {0, 0, .5, 3, 7, 9}, R_BS_B4 = {.1, .2, 1, 6, 8, 10},
	R_BS_N1 = {0, 0, .5, 4, 8, 10}, R_BS_N2 = {.2, .5, 1, 2, 2, 0}, R_BS_H = {.2, .5, 1, 3, 5, 6}, R_BS_J = {.2, .5, 1, 3, 4, 4},
	R_BS_D1 = {.2, .5, 1, 3, 2, 1}, R_BS_D2 = {.2, .5, 1, 2, 1, 0}, R_BS_HA = {.2, .5, 0, 0, 0, 0}, R_BS_AT = {0, .2, .5, 2, 1, 1},
	R_BS_SK = {0, 0, .1, 0, 0, 0},
	R_CA_N = {0, .5, 1, 3, 2, 1}, R_CA_D = {1, 2, 4, 5, 7, 10}, R_CA_NF = {0, .5, 1, 0, 0, 0}, R_CA_DF = {1, 2, 3, 4, 3, 2},
	R_BRK = {0, 0, 0, 0, .1, .2}, R_BRK_S = {0, 0, 0, 0, .2, .4},
	R_CALL = {0, .02, .05, .05, 0, 0}, R_CALL_D = {0, .02, .05, .1, .3, .5},
	R_GS = {0, 0, 0, 0, .1, .2}, R_GS_J = {0, 0, .1, .1, .1, .1}, R_GS_D = {0, 0, 0, .1, .1, .1},
}

local AI = {}
AI.__index = AI

BVNAI = {
	New = function(fighter, level)
		return setmetatable({f = fighter, level = level or 1, moveFrame = 0, orders = {}, breakCache = {}, cpu = true,
			buf = {attack = 0, jump = 0, dash = 0, skill = 0, super = 0}, held = {}}, AI)
	end,
}

-- The input interface (FighterAICtrl). -----------------------------------------------------

function AI:Update() end
function AI:moveLEFT() return self.moveLeft == true end
function AI:moveRIGHT() return self.moveRight == true end
function AI:defense() return self.defenseF == true end
function AI:attack() return self.attackF == true end
function AI:jump() return self.jumpF == true end
function AI:jumpQuick() return false end
function AI:jumpDown() return self.jumpDownF == true end
function AI:dash() return self.dashF == true end
function AI:dashJump() return self.downJump == true end
function AI:skill1() return self.skill1F == true end
function AI:skill2() return self.skill2F == true end
function AI:zhao1() return self.zhao1F == true end
function AI:zhao2() return self.zhao2F == true end
function AI:zhao3() return self.zhao3F == true end
function AI:catch1() return self.catch1F == true end
function AI:catch2() return self.catch2F == true end
function AI:bisha() return self.bishaF == true end
function AI:bishaUP() return self.bishaUPF == true end
function AI:bishaSUPER() return self.bishaSUPERF == true end
function AI:special() return self.specialSkill == true end
function AI:attackAIR() return self.attackAIRF == true end
function AI:skillAIR() return self.skillAIRF == true end
function AI:bishaAIR() return self.bishaAIRF == true end
function AI:waiKai() return false end
function AI:waiKaiW() return false end
function AI:waiKaiS() return false end
function AI:ghostStep() return self.ghostStepF == true end
function AI:ghostJump() return self.ghostJumpF == true end
function AI:ghostJumpDown() return false end

-- FighterAILogicBase --------------------------------------------------------------------

function AI:Result(row)
	local lv = self.level
	local a = lv <= 1 and row[1] or (lv >= 6 and row[6] or row[lv])
	return BVNRuntime.RAND() * 10 < a
end

-- getAIByFighterState: the row for the target fighter's state, else the default.
function AI:ByState(rows)
	local t = self.targetFighter
	local st = t and t.state or -1
	return self:Result(rows[st] or rows.default)
end

function AI:Distance(sp) return math.abs(sp.x - self.f.x), math.abs(sp.y - self.f.y) end

function AI:InRange(id)
	local body = self.target and self.target:BodyArea()
	local r = self.f:Range(id)
	return body ~= nil and r ~= nil and BVNBattle.Intersects(body, r)
end

function AI:CanBeHit()
	local t = self.target
	if not t then return false end
	if self.targetFighter then return t.allowBeHit end
	return t:BodyArea() ~= nil
end

function AI:Order(id, order)
	for _, o in ipairs(self.orders) do
		if o[1] == id then o[2] = order return end
	end
	self.orders[#self.orders + 1] = {id, order}
end

local function hitLike(f, id, pred)
	for hid, h in pairs(f.hitModel) do
		if hid:find(id, 1, true) and pred(h) then return true end
	end
	return false
end

function AI:IsBreakAct(id)
	local c = self.breakCache[id]
	if c ~= nil then return c end
	c = hitLike(self.f, id, function(h) return h.isBreakDef end)
	self.breakCache[id] = c
	return c
end

-- isHitDownAct writes its answer into the break cache (an original quirk).
function AI:IsHitDownAct(id)
	local c = hitLike(self.f, id, function(h) return h.hurtType == 1 end)
	self.breakCache[id] = c
	return c
end

-- FighterAILogic.render ------------------------------------------------------------------

function AI:Think()
	local f = self.f
	local t = f:Target()
	self.target = t
	self.targetFighter = t and t.kind == "fighter" and t or nil
	local s = f.state
	self.conting = s == S.ATTACK or s == S.SKILL or s == S.BISHA or s == S.BISHA_SUPER
	if t then
		self:UpdateDash()
		self:UpdateAttack()
		self:UpdateSkill()
		self:UpdateBisha()
		self:UpdateCatch()
		self:UpdateAssist()
	end
	if #self.orders > 0 then
		table.sort(self.orders, function(a, b) return a[2] > b[2] end)
		for i = 2, #self.orders do self[self.orders[i][1] .. "F"] = false end
		self.orders = {}
	end
	if not t then return end
	self:UpdateMove()
	self:UpdateJump()
	self:UpdateJumpDown()
	self:UpdateHurt()
	self:UpdateDefense()
	self:UpdateSpecial()
	self:UpdateGhost()
end

function AI:UpdateDash()
	local f, t = self.f, self.target
	local dis = math.abs(t.x - f.x)
	local direct = t.x > f.x and 1 or -1
	local rows
	if f.energy < 40 then
		if dis > 200 and f.dir == direct then
			rows = {default = R.R_DSH1, [S.ATTACK] = R.R_DSH2, [S.SKILL] = R.R_DSH2, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0}
		else
			rows = {default = R.R_DSH3, [S.ATTACK] = R.R0, [S.SKILL] = R.R0, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0}
		end
	else
		if dis > 200 and f.dir ~= t.dir then
			rows = {default = R.R_DSH4, [S.ATTACK] = R.R_DSH5, [S.SKILL] = R.R_DSH6, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0}
		else
			rows = {default = R.R_DSH7, [S.ATTACK] = R.R0, [S.SKILL] = R.R0, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0}
		end
	end
	self.dashF = self:ByState(rows)
end

function AI:UpdateAttack()
	local f, a = self.f, self.f.act
	self.attackF, self.attackAIRF = false, false
	if not a.attack and not a.attackAIR then return end
	if not self:CanBeHit() then return end
	local rows = {default = self.conting and R.R_ATK_C or R.R_ATK_D, [S.DEFENSE] = R.R_ATK_DF, [S.HURT_ACT] = R.R_ATK_HA,
		[S.ATTACK] = R.R_ATK_A, [S.SKILL] = R.R0, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0}
	if not self:ByState(rows) then return end
	local order = 10
	if self.conting then
		self.attackF = true
		self.attackAIRF = f.y < self.target.y
		if f.doingAction == "砍1" then order = 200 end
	else
		self.attackF = self:InRange("kanmian")
		self.attackAIRF = self:InRange("tkanmian") and f.y < self.target.y
		order = 300
	end
	if self.attackF then self:Order("attack", order) end
	if self.attackAIRF then self:Order("attackAIR", order) end
end

function AI:SkillAI(id, hitId, range, order)
	local rows
	if self:IsBreakAct(hitId) then
		rows = {default = self.conting and R.R_SK_B1 or R.R_SK_B2, [S.DEFENSE] = self.conting and R.R_SK_B3 or R.R_SK_B4}
	else
		rows = {default = self.conting and R.R_SK_N1 or R.R_SK_N2, [S.DEFENSE] = R.R_SK_N3}
	end
	rows[S.HURT_ACT], rows[S.ATTACK] = R.R_SK_HA, R.R_SK_AT
	rows[S.SKILL], rows[S.BISHA], rows[S.BISHA_SUPER] = R.R0, R.R0, R.R0
	local result = self:ByState(rows) and self:CanBeHit() and self:InRange(range)
	if result and self.conting then self:Order(id, self:IsHitDownAct(hitId) and order or order + 100) end
	return result
end

function AI:UpdateSkill()
	local a = self.f.act
	self.skill1F = a.skill1 and self:SkillAI("skill1", "kj1", "kj1mian", 10) or false
	self.skill2F = a.skill2 and self:SkillAI("skill2", "kj2", "kj2mian", 10) or false
	self.zhao1F = a.zhao1 and self:SkillAI("zhao1", "zh1", "zh1mian", 10) or false
	self.zhao2F = a.zhao2 and self:SkillAI("zhao2", "zh2", "zh2mian", 10) or false
	self.zhao3F = a.zhao3 and self:SkillAI("zhao3", "zh3", "zh3mian", 10) or false
	self.skillAIRF = a.skillAIR and self:SkillAI("skillAIR", "tz", "tzmian", 10) or false
end

function AI:BishaAI(id, hitId, range, qi, order)
	local result = false
	if self.f.qi >= qi then
		local rows
		if self:IsBreakAct(hitId) then
			rows = {default = self.conting and R.R_BS_B1 or R.R_BS_B2, [S.DEFENSE] = self.conting and R.R_BS_B3 or R.R_BS_B4}
		else
			rows = {default = self.conting and R.R_BS_N1 or R.R_BS_N2, [S.HURT] = R.R_BS_H, [S.JUMP] = R.R_BS_J,
				[S.DEFENSE] = self.conting and R.R_BS_D1 or R.R_BS_D2}
		end
		rows[S.HURT_ACT], rows[S.ATTACK] = R.R_BS_HA, R.R_BS_AT
		rows[S.SKILL], rows[S.BISHA], rows[S.BISHA_SUPER] = R.R_BS_SK, R.R_BS_SK, R.R_BS_SK
		result = self:ByState(rows) and self:CanBeHit() and self:InRange(range)
	end
	if result and self.conting then self:Order(id, order) end
	return result
end

function AI:UpdateBisha()
	local a = self.f.act
	self.bishaF = a.bisha and self:BishaAI("bisha", "bs", "bsmian", 100, 100) or false
	self.bishaUPF = a.bishaUP and self:BishaAI("bishaUP", "sbs", "sbsmian", 100, 100) or false
	self.bishaSUPERF = a.bishaSUPER and self:BishaAI("bishaSUPER", "cbs", "cbsmian", 300, 200) or false
	self.bishaAIRF = a.bishaAIR and self:BishaAI("bishaAIR", "kbs", "kbsmian", 100, 210) or false
end

function AI:UpdateCatch()
	self.catch1F, self.catch2F = false, false
	local tf = self.targetFighter
	if tf and (tf.state == S.HURT or tf.state == S.HURT_FLY or tf.state == S.HURT_DOWN) then return end
	local dx = self:Distance(self.target)
	local rows = dx < 50 and {default = R.R_CA_N, [S.DEFENSE] = R.R_CA_D} or {default = R.R_CA_NF, [S.DEFENSE] = R.R_CA_DF}
	self.catch1F = self:ByState(rows) and self:CanBeHit()
	self.catch2F = self:ByState(rows) and self:CanBeHit()
	if self.catch1F then self:Order("catch1", 150) end
	if self.catch2F then self:Order("catch2", 110) end
end

-- The kernel never reads this flag; assists come from specialSkill (the burst roll).
function AI:UpdateAssist()
	self.assist = self:ByState({default = R.R_CALL, [S.DEFENSE] = R.R_CALL_D, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0})
end

function AI:UpdateMove()
	local f, t = self.f, self.target
	self.moveLeft, self.moveRight = false, false
	if f.state == S.DEFENSE then
		if self:Result({1, 2, 4, 5, 6, 8}) then
			if f.x > t.x + 20 then self.moveLeft = true end
			if f.x < t.x - 20 then self.moveRight = true end
		end
		return
	end
	local moving
	if self.moveFrame < 60 then
		self.moveFrame = self.moveFrame + 1
		moving = true
	else
		moving = self:ByState({default = R.R_MV, [S.ATTACK] = R.R_MV_ATK, [S.SKILL] = R.R_MV_SK, [S.BISHA] = R.R_MV_BS,
			[S.BISHA_SUPER] = R.R_MV_BS})
		if moving then self.moveFrame = 0 end
	end
	if moving then
		local keep = ((self.catch1F or self.catch2F) and math.abs(f.y - t.y) < 2) and 15 or 40
		if f.x > t.x + keep then self.moveLeft = true end
		if f.x < t.x - keep then self.moveRight = true end
	end
	if not self.moveLeft and not self.moveRight then self.moveFrame = 60 end
end

function AI:UpdateJump()
	local f, t = self.f, self.target
	local rows
	if self.conting then
		rows = {default = R.R_JP_C, [S.HURT] = R.R_JP_CH}
	elseif f.y > t.y + 50 then
		rows = {default = R.R_JP_UP, [S.BISHA] = R.R_MV_BS, [S.BISHA_SUPER] = R.R_MV_BS}
	else
		rows = {default = R.R_JP_LO, [S.BISHA] = R.R_JP_LB, [S.BISHA_SUPER] = R.R_JP_LB}
	end
	self.jumpF = self:ByState(rows)
	-- Added after the orders were resolved, so it competes in the next round of orders.
	if self.conting and self.jumpF then self:Order("jump", 10) end
end

function AI:UpdateJumpDown()
	local f, t = self.f, self.target
	local rows
	if f.y < t.y - 50 then
		rows = {default = R.R_JP_UP, [S.BISHA] = R.R_MV_BS, [S.BISHA_SUPER] = R.R_MV_BS}
	else
		rows = {default = R.R_JP_LO, [S.BISHA] = R.R_JP_LB, [S.BISHA_SUPER] = R.R_JP_LB}
	end
	self.jumpDownF = self:ByState(rows)
end

function AI:UpdateHurt()
	self.downJump = self:ByState({default = R.R_DJ, [S.SKILL] = R.R0, [S.BISHA] = R.R0, [S.BISHA_SUPER] = R.R0})
end

function AI:UpdateDefense()
	if self.defenseF then
		self.defenseF = self:ByState({default = R.R_DEF_C, [S.FREEZE] = R.R_DEF_F, [S.NORMAL] = R.R_DEF_N, [S.HURT] = R.R0,
			[S.HURT_FLY] = R.R0, [S.HURT_DOWN] = R.R0})
		if self.defenseF then return end
	end
	local dx, dy = self:Distance(self.target)
	local near = dx < 100 and dy < 100
	self.defenseF = self:ByState({default = R.R0, [S.ATTACK] = near and R.R_DEF_N2 or R.R_DEF_F2, [S.SKILL] = R.R_DEF_SK,
		[S.BISHA] = R.R_DEF_BS, [S.BISHA_SUPER] = R.R_DEF_BS})
	if self.defenseF then return end
	local f = self.f
	for _, sp in ipairs(f.battle.sprites) do
		if sp ~= self.target and sp.team ~= f.team and not sp.dead then
			if sp.kind == "bullet" and not sp.hitOver and not sp.stopped then
				local bx, by = self:Distance(sp)
				if bx < 200 and by < 150 then self.defenseF = self:Result({2, 4, 5, 7, 9, 10})
				else self.defenseF = self:Result({2, 4, 5, 5, 2, 1}) end
				if self.defenseF then return end
			elseif sp.kind == "attacker" and sp.isAttacking then
				self.defenseF = self:Result({2, 4, 5, 7, 9, 10})
				if self.defenseF then return end
			elseif sp.kind == "assist" and sp.isAttacking then
				self.defenseF = self:Result({2, 4, 6, 8, 10, 10})
				if self.defenseF then return end
			end
		end
	end
end

-- updateSpecialSkill: the burst flag, rolled while staggered and never cleared.
function AI:UpdateSpecial()
	local f = self.f
	if f.state ~= S.HURT then return end
	if f.hp > f.hpMax * 0.6 or f.qi < 150 then return end
	self.specialSkill = self:ByState({default = R.R_BRK, [S.SKILL] = R.R_BRK_S})
end

-- updateGhostStep: the flags keep their last value when the conditions fail.
function AI:UpdateGhost()
	local f, t = self.f, self.target
	local dx, dy = self:Distance(t)
	if dx > 80 or dy > 80 then return end
	if f.qi < 200 then return end
	if f.state ~= S.ATTACK and f.state ~= S.SKILL then return end
	self.ghostStepF = self:ByState({default = R.R0, [S.HURT] = R.R_GS})
	local up = t.y - f.y
	if up < -80 and up > -100 then
		self.ghostJumpF = self:ByState({default = R.R0, [S.HURT] = R.R_GS_J})
	else
		self.ghostJumpF = false
	end
end
