-- Fighter input predicates (FighterKeyCtrl): directions are held, the five
-- buttons stay pressed for 6 logic ticks after a press. Humans read actions
-- p<n>_*; the CPU sets the same fields from BVNAI. Not attached to any actor.
local BUTTONS = {"attack", "jump", "dash", "skill", "super"}

local Input = {}
Input.__index = Input

BVNInput = {
	New = function(side, cpu)
		local k = setmetatable({side = side, cpu = cpu, buf = {}, held = {}}, Input)
		for _, b in ipairs(BUTTONS) do k.buf[b] = 0 end
		k.up, k.down, k.left, k.right, k.special_held = false, false, false, false, false
		return k
	end,
}

-- Called every logic tick before the fighters render.
function Input:Update(enabled)
	for _, b in ipairs(BUTTONS) do
		if self.buf[b] > 0 then self.buf[b] = self.buf[b] - 1 end
	end
	if self.cpu then return end
	local p = "p" .. self.side .. "_"
	if not enabled then
		self.up, self.down, self.left, self.right, self.special_held = false, false, false, false, false
		for _, b in ipairs(BUTTONS) do self.held[b] = false end
		return
	end
	local mv = _G.Input.GetActionValue(p .. "move")
	self.left, self.right = mv < -0.3, mv > 0.3
	self.up = _G.Input.GetAction(p .. "up")
	self.down = _G.Input.GetAction(p .. "down")
	self.special_held = _G.Input.GetAction(p .. "assist")
	for _, b in ipairs(BUTTONS) do
		if _G.Input.GetActionDown(p .. b) then self.buf[b] = 6 end
		self.held[b] = _G.Input.GetAction(p .. b)
	end
end

-- CPU: press a button (the AI holds flags for one animate tick).
function Input:Press(b) self.buf[b] = math.max(self.buf[b], 2); self.held[b] = true end
function Input:Release()
	for _, b in ipairs(BUTTONS) do self.held[b] = false end
	self.up, self.down, self.left, self.right, self.special_held = false, false, false, false, false
	self.cpuWaiKai = false
end

local function pressed(k, b) return k.buf[b] > 0 end

function Input:moveLEFT() return self.left and not self.right end
function Input:moveRIGHT() return self.right and not self.left end
function Input:defense() return self.down end
function Input:attack() return pressed(self, "attack") and not (self.up or self.down or self.held.jump) end
function Input:skill1() return self.down and pressed(self, "attack") end
function Input:skill2() return self.up and pressed(self, "attack") end
function Input:zhao1() return pressed(self, "skill") and not (self.up or self.down) end
function Input:zhao2() return self.down and pressed(self, "skill") end
function Input:zhao3() return self.up and pressed(self, "skill") end
function Input:bisha() return pressed(self, "super") and not (self.up or self.down) end
function Input:bishaUP() return self.up and pressed(self, "super") end
function Input:bishaSUPER() return self.down and pressed(self, "super") end
function Input:jump() return pressed(self, "jump") and not self.held.attack end
function Input:jumpQuick() return pressed(self, "jump") and not self.held.attack end
function Input:jumpDown() return self.down and pressed(self, "jump") end
function Input:dash() return pressed(self, "dash") and not self.down end
function Input:dashJump() return pressed(self, "dash") end
function Input:catch1() return pressed(self, "attack") and (self.left or self.right) end
function Input:catch2() return pressed(self, "skill") and (self.left or self.right) end
function Input:attackAIR() return pressed(self, "attack") end
function Input:skillAIR() return pressed(self, "skill") end
function Input:bishaAIR() return pressed(self, "super") end
function Input:waiKai()
	if self.cpu then return self.cpuWaiKai end
	return self.held.attack and self.held.jump
end
function Input:special() return self.special_held end
function Input:ghostStep() return pressed(self, "dash") and self.down end
function Input:ghostJump() return pressed(self, "dash") and self.up end
