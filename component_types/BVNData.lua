-- Characters, poses and moves. Not attached to any actor.
-- Frame counts are 60 Hz ticks; distances are screen pixels.
local function P(lean, ua1, fa1, ua2, fa2, th1, sh1, th2, sh2, w)
	return {lean = lean, ua1 = ua1, fa1 = fa1, ua2 = ua2, fa2 = fa2, th1 = th1, sh1 = sh1, th2 = th2, sh2 = sh2, w = w}
end

local LUNGE = {40, -5, -35, -40}

local function legs(p, l)
	p.th1, p.sh1, p.th2, p.sh2 = l[1], l[2], l[3], l[4]
	return p
end

BVNData = {
	POSES = {
		sword = {
			idle = P(6, 30, 85, -15, 20, 18, -2, -14, -18, 118),
			jump = P(5, 70, 120, -40, -10, 70, 0, 10, -50, 135),
			fall = P(2, 55, 100, -30, 0, 30, -20, -10, -30, 120),
			block = P(-6, 60, 170, 45, 150, 45, -20, 20, -50, 185),
			hurt = P(-22, -40, -20, -60, -40, 20, 0, -25, -25, 60),
			down = P(-88, -100, -110, -80, -90, 92, 88, 85, 92, 90),
			dash = P(35, -50, -30, -70, -50, 50, -10, -40, -60, -100),
			win = P(0, 160, 175, -10, 10, 10, 0, -10, 0, 180),
			cast = P(12, 90, 90, -30, 0, 40, -5, -30, -35, 100),
			charge = P(-4, 150, 170, 120, 160, 30, -10, -25, -30, 190),
		},
		fist = {
			idle = P(10, 50, 150, 30, 140, 18, -2, -14, -18, 0),
			jump = P(5, 80, 150, -40, -10, 70, 0, 10, -50, 0),
			fall = P(2, 60, 120, -30, 0, 30, -20, -10, -30, 0),
			block = P(-6, 70, 165, 60, 160, 45, -20, 20, -50, 0),
			hurt = P(-22, -40, -20, -60, -40, 20, 0, -25, -25, 0),
			down = P(-88, -100, -110, -80, -90, 92, 88, 85, 92, 0),
			dash = P(40, -60, -40, -80, -60, 55, -10, -40, -60, 0),
			win = P(0, 165, 175, 20, 140, 10, 0, -10, 0, 0),
			cast = P(14, 90, 90, 80, 95, 40, -5, -30, -35, 0),
			charge = P(-4, 140, 170, 130, 165, 30, -10, -25, -30, 0),
		},
	},

	-- Attack poses: wind-up during startup, strike from the first active frame.
	ATTACKS = {
		sword = {
			light1 = {P(-4, 140, 170, -20, 10, 20, -2, -15, -20, 200), legs(P(16, 75, 85, -30, -10, 0, 0, 0, 0, 50), LUNGE)},
			light2 = {P(4, 30, 20, -20, 10, 25, -5, -20, -25, -40), legs(P(10, 100, 110, -40, -20, 0, 0, 0, 0, 130), LUNGE)},
			light3 = {P(-2, 60, 60, -20, 0, 25, -5, -20, -25, 80), legs(P(28, 90, 90, -60, -40, 0, 0, 0, 0, 90), {60, 0, -50, -55})},
			heavy = {P(-12, 172, 190, 150, 170, 25, -5, -20, -25, 215), legs(P(32, 60, 45, 40, 30, 0, 0, 0, 0, 15), {55, -5, -45, -50})},
			air = {P(-6, 150, 175, -20, 10, 60, 0, 10, -50, 205), P(20, 65, 60, -40, -20, 50, 10, 0, -40, 35)},
		},
		fist = {
			light1 = {P(8, 50, 150, 30, 140, 20, -2, -15, -20, 0), legs(P(18, 92, 90, 30, 140, 0, 0, 0, 0, 0), LUNGE)},
			light2 = {P(8, 30, 140, 20, 120, 20, -2, -15, -20, 0), legs(P(20, 30, 140, 92, 90, 0, 0, 0, 0, 0), LUNGE)},
			light3 = {P(-4, 40, 140, 40, 140, 40, 20, -15, -20, 0), P(-18, 30, 120, -40, -10, 100, 96, -15, -10, 0)},
			heavy = {P(10, 20, 60, 40, 140, 60, -20, -20, -60, 0), P(-6, 168, 175, -40, -10, 40, 10, -20, -30, 0)},
			air = {P(0, 60, 140, -30, 0, 70, 40, 10, -50, 0), P(10, 50, 140, -40, -10, 120, 125, 20, -20, 0)},
		},
	},

	-- Shared basic attacks; each character scales reach and damage.
	BASIC = {
		light1 = {startup = 5, active = 3, recovery = 10, dmg = 4, hitstun = 17, kb = 3, hitstop = 4, next = "light2"},
		light2 = {startup = 5, active = 3, recovery = 11, dmg = 4, hitstun = 17, kb = 3, hitstop = 4, next = "light3"},
		light3 = {startup = 7, active = 4, recovery = 16, dmg = 6, hitstun = 22, kb = 10, hitstop = 6, lunge = 5},
		heavy = {startup = 12, active = 4, recovery = 20, dmg = 9, hitstun = 26, kb = 6, launch = -12, knockdown = true, hitstop = 8, lunge = 3},
		air = {startup = 5, active = 7, recovery = 8, dmg = 6, hitstun = 18, kb = 4, hitstop = 5},
	},

	CHARACTERS = {
		{
			id = "ichigo", name = "黑崎一护", series = "死神", style = "sword", scale = 1.12,
			skin = {245, 205, 170}, hair = "ichigo", hair_color = {255, 135, 30}, eye = {90, 50, 30},
			top = {28, 28, 34}, sleeve = {28, 28, 34}, forearm = {32, 32, 38}, pants = {24, 24, 30}, shin = {30, 30, 36},
			foot = {235, 235, 235}, collar = {240, 240, 240}, belt = {235, 235, 235}, belt_h = 5,
			thigh_w = 20, shin_w = 16, weapon = "zangetsu", reach = 112, speed = 4.6, power = 1.05,
			special = {name = "月牙天冲", kind = "getsuga"},
			ult = {name = "卍解 · 天锁斩月", kind = "getsuga_black"},
			theme = {255, 135, 30},
		},
		{
			id = "rukia", name = "朽木露琪亚", series = "死神", style = "sword", scale = 1.0,
			skin = {250, 222, 200}, hair = "rukia", hair_color = {22, 20, 30}, eye = {80, 70, 160},
			top = {28, 28, 34}, sleeve = {28, 28, 34}, forearm = {32, 32, 38}, pants = {24, 24, 30}, shin = {30, 30, 36},
			foot = {235, 235, 235}, collar = {240, 240, 240}, belt = {235, 235, 235}, belt_h = 5,
			thigh_w = 19, shin_w = 15, weapon = "shirayuki", reach = 96, speed = 5.0, power = 0.92,
			special = {name = "次之舞 · 白涟", kind = "hakuren"},
			ult = {name = "初之舞 · 月白", kind = "tsukishiro"},
			theme = {170, 225, 255},
		},
		{
			id = "naruto", name = "漩涡鸣人", series = "火影", style = "fist", scale = 1.12,
			skin = {250, 210, 165}, hair = "naruto", hair_color = {255, 215, 40}, eye = {40, 110, 220},
			top = {255, 130, 20}, sleeve = {255, 130, 20}, forearm = {255, 140, 30}, pants = {255, 125, 15}, shin = {250, 120, 15},
			foot = {40, 50, 90}, chest = {30, 30, 36}, belt = nil,
			thigh_w = 17, shin_w = 15, weapon = nil, reach = 78, speed = 5.0, power = 1.0,
			special = {name = "螺旋丸", kind = "rasengan"},
			ult = {name = "多重影分身之术", kind = "clones"},
			theme = {255, 150, 30},
		},
		{
			id = "sasuke", name = "宇智波佐助", series = "火影", style = "sword", scale = 1.12,
			skin = {245, 215, 190}, hair = "sasuke", hair_color = {26, 26, 44}, eye = {30, 30, 40},
			top = {232, 232, 240}, sleeve = {232, 232, 240}, forearm = {50, 50, 80}, pants = {44, 46, 78}, shin = {50, 52, 86},
			foot = {40, 40, 50}, collar = {245, 215, 190}, belt = {120, 70, 170}, belt_h = 9,
			thigh_w = 17, shin_w = 14, weapon = "kusanagi", reach = 100, speed = 4.9, power = 1.0,
			special = {name = "火遁 · 豪火球之术", kind = "fireball"},
			ult = {name = "麒麟", kind = "kirin"},
			theme = {150, 90, 220},
		},
	},

	STAGES = {
		{name = "空座町 · 夜"},
		{name = "木叶隐村"},
	},

	-- Special and ultimate timing. `spawn` lists frames that call BVNGame.Spawn.
	SPECIALS = {
		getsuga = {frames = 32, cost = 30, pose = "cast", spawn = {12}},
		getsuga_black = {frames = 56, cost = 100, pose = "cast", spawn = {18}},
		hakuren = {frames = 36, cost = 30, pose = "cast", spawn = {14}},
		tsukishiro = {frames = 48, cost = 100, pose = "charge", spawn = {10}},
		rasengan = {frames = 36, cost = 30, pose = "cast", dash = {8, 24, 12}},
		clones = {frames = 72, cost = 100, pose = "charge", spawn = {12, 20, 28, 36, 46}},
		fireball = {frames = 40, cost = 30, pose = "cast", spawn = {16}},
		kirin = {frames = 56, cost = 100, pose = "charge", spawn = {8}},
	},
}
