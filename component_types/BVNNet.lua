-- NET PLAY: two players on two computers through the engine's lockstep
-- netplay (Net, engine net/Netplay). The host opens a room on the room server
-- (or listens on the LAN), the guest enters the room code (or the host's IP).
-- From the first lockstep tick both machines run the same session: VS PEOPLE
-- from the fighter select on, the host as player 1 and the guest as player 2,
-- each playing with their own player 1 keys. Back and confirm are shared.
--
-- The room server address: POCKET_NET_SERVER, else "server" in netplay.json in
-- the project directory ({"server": "host:27777"}).
-- Not attached to any actor; BVNGame calls BVNNet.Update(g) every tick.
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})
local ORDER = 10
local WHITE = {255, 255, 255}
local YELLOW = {253, 237, 101}
local RED = {255, 110, 90}
local VERSION = "bvn-net-1"
local CHECK_EVERY = 60

local MODES = {{"SINGLE", "单人对战", false}, {"TEAM", "组队对战", true}}

local function serverAddress()
	local env = os.getenv and os.getenv("POCKET_NET_SERVER")
	if env and env ~= "" then return env end
	local f = io.open(Application.GetProjectDirectory() .. "/netplay.json", "rb")
	if not f then return nil end
	local src = f:read("a")
	f:close()
	return src:match('"server"%s*:%s*"([^"]+)"')
end

-- The host's session settings, which the guest adopts: "key=value;...".
local function encode(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. tostring(t[k]) end
	return table.concat(out, ";")
end

local function decode(s)
	local t = {}
	for k, v in (s or ""):gmatch("([%w_]+)=([^;]*)") do t[k] = v end
	return t
end

-- The engine's messages (net/Netplay.cpp) in the game's language.
local MESSAGES = {
	{"the other player left", "对方已离开"},
	{"connection lost", "连接中断"},
	{"no answer from the room server", "房间服务器没有响应"},
	{"no answer from", "连接不上对方"},
	{"room server: no such room", "房间不存在"},
	{"room server: room is full", "房间已满"},
	{"cannot resolve the room server", "找不到房间服务器"},
	{"cannot resolve", "地址无效"},
	{"different game version", "对方的游戏版本不同"},
	{"cannot open a UDP socket", "无法打开网络端口"},
}

local function say(err)
	if not err or err == "" then return nil end
	for _, m in ipairs(MESSAGES) do
		if err:find(m[1], 1, true) then return m[2] end
	end
	return err
end

local function configure()
	Net.Configure({local_prefix = "p1_", sides = {"p1_", "p2_"}, shared = {"confirm", "back"}, delay = 0,
		force_relay = BVNNet.relay == true})
end

-- Text entry before the session starts (raw keys: nothing is in lockstep yet).
local KEYS = {}
for c in ("abcdefghijklmnopqrstuvwxyz0123456789"):gmatch(".") do KEYS[#KEYS + 1] = {c, c:upper()} end
for d = 0, 9 do KEYS[#KEYS + 1] = {"keypad " .. d, tostring(d)} end
KEYS[#KEYS + 1] = {".", "."}
KEYS[#KEYS + 1] = {"keypad .", "."}

local function typed(allowed, max, text)
	if Input.GetKeyDown("backspace") then return text:sub(1, -2) end
	for _, k in ipairs(KEYS) do
		if #text < max and allowed:find(k[2], 1, true) and Input.GetKeyDown(k[1]) then text = text .. k[2] end
	end
	return text
end

local CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
local IP_CHARS = "0123456789."

-- The NET PLAY screen ----------------------------------------------------------------------

local function newScreen(g, message)
	local st = {name = "netplay", phase = "netplay", t = 0, bg = S.Clip("setting", 0, false), view = "menu",
		message = message, text = ""}
	BVNSound.Music("bvn/bgm/back")
	st.group = BVNScreenDialog.Group({
		{label = "CREATE ROOM", cn = "创建房间"},
		{label = "JOIN ROOM", cn = "加入房间"},
		{label = "LAN HOST", cn = "局域网建房"},
		{label = "LAN JOIN", cn = "局域网加入"},
		{label = "MODE", cn = "对战模式", key = "team", options = MODES, value = BVNNet.team},
		{label = "BACK", cn = "返回"},
	}, {startY = 40, endY = 550, gap = 70})

	function st.Host(lan)
		configure()
		local payload = encode({v = VERSION, team = BVNNet.team and 1 or 0, time = BVNSettings.gameTime,
			hp = BVNSettings.fighterHP, key = BVNSettings.keyMode})
		local ok
		if lan then
			ok = Net.HostDirect(BVNNet.lanPort or 0, payload)
		else
			local server = serverAddress()
			if not server then
				st.message = "没有配置房间服务器 (netplay.json)"
				return
			end
			ok = Net.Host(server, payload)
		end
		if not ok then
			st.message = say(Net.Status().error)
			return
		end
		BVNNet.session = {host = true, lan = lan}
		st.view, st.message = "wait", nil
	end

	function st.Join(text)
		configure()
		local ok
		if st.view == "lan" then
			ok = Net.JoinDirect(text)
		else
			local server = serverAddress()
			if not server then
				st.message = "没有配置房间服务器 (netplay.json)"
				st.view = "menu"
				return
			end
			ok = Net.Join(server, text)
		end
		if not ok then
			st.message = say(Net.Status().error)
			st.view = "menu"
			return
		end
		BVNNet.session = {host = false, lan = st.view == "lan"}
		st.view, st.message = "wait", nil
	end

	function st:Update()
		self.t = self.t + 1
		self.bg:Step()
		if self.view == "menu" then
			local ev = self.group:Update()
			if S.Down("back", "menu") then
				g:GoMenu()
				return
			end
			if not ev then return end
			if ev.change == "team" then
				BVNNet.team = ev.value
			elseif ev.select == "CREATE ROOM" then
				st.Host(false)
			elseif ev.select == "LAN HOST" then
				st.Host(true)
			elseif ev.select == "JOIN ROOM" or ev.select == "LAN JOIN" then
				self.view = ev.select == "JOIN ROOM" and "code" or "lan"
				self.text, self.message = "", nil
			elseif ev.select == "BACK" then
				g:GoMenu()
			end
		elseif self.view == "code" or self.view == "lan" then
			if Input.GetKeyDown("escape") then
				self.view = "menu"
				return
			end
			if self.view == "code" then
				self.text = typed(CODE_CHARS, 4, self.text)
				if #self.text == 4 and (Input.GetKeyDown("return") or Input.GetKeyDown("keypad enter")) then st.Join(self.text) end
			else
				self.text = typed(IP_CHARS, 15, self.text)
				if #self.text > 6 and (Input.GetKeyDown("return") or Input.GetKeyDown("keypad enter")) then st.Join(self.text) end
			end
		elseif self.view == "wait" then
			local s = Net.Status()
			self.status = s
			if s.state == "error" or s.state == "disconnected" then
				Net.Leave()
				BVNNet.session = nil
				self.view, self.message = "menu", say(s.error) or "连接失败"
			elseif Input.GetKeyDown("escape") or Input.GetKeyDown("backspace") then
				Net.Leave()
				BVNNet.session = nil
				self.view = "menu"
			end
		end
	end

	function st:Draw()
		-- The option screen's backdrop, its OPTION heading replaced.
		self.bg:Draw(nil, 1, ORDER, "world")
		S.Rect(596, 0, 204, 96, {22, 22, 22}, 255, ORDER, "world")
		local hw = S.FontWidth("NET PLAY")
		S.Font("NET PLAY", 790 - hw, 10, 1, 1, ORDER + 1, "world")
		S.Text("· 联机对战", 600, 52, 16, WHITE, "right", 190, 0.8, ORDER + 1)
		if self.view == "menu" then
			self.group:Draw(0, 0, ORDER + 1, "world")
			S.Text("联机对战：主机为 1P，加入者为 2P，双方都用 1P 键位 (WASD + JKLUIO)", 60, 520, 15, WHITE, "left", nil, 1,
				ORDER + 2)
		else
			S.Rect(150, 170, 500, 260, {0, 0, 0}, 200, ORDER + 1, "world")
			if self.view == "code" or self.view == "lan" then
				local title = self.view == "code" and "输入房间码 (4 位)" or "输入主机的局域网 IP"
				S.Text(title, 150, 200, 22, YELLOW, "center", 500, 1, ORDER + 2)
				local caret = (self.t // 30) % 2 == 0 and "_" or " "
				S.Text(self.text .. caret, 150, 260, 40, WHITE, "center", 500, 1, ORDER + 2)
				S.Text("回车确认    Esc 返回", 150, 370, 16, WHITE, "center", 500, 1, ORDER + 2)
			else
				local s = self.status or Net.Status()
				local ses = BVNNet.session or {}
				local line
				if ses.host and not ses.lan then
					S.Text("房间码", 150, 195, 20, YELLOW, "center", 500, 1, ORDER + 2)
					S.Text(s.room ~= "" and s.room or "...", 150, 230, 56, WHITE, "center", 500, 1, ORDER + 2)
					line = s.state == "server" and "正在连接房间服务器..." or "把房间码告诉朋友，等待对方加入..."
				elseif ses.host then
					S.Text("局域网主机", 150, 195, 20, YELLOW, "center", 500, 1, ORDER + 2)
					S.Text(BVNNet.LocalAddress(), 150, 240, 32, WHITE, "center", 500, 1, ORDER + 2)
					line = "等待对方加入..."
				else
					S.Text("正在加入", 150, 195, 20, YELLOW, "center", 500, 1, ORDER + 2)
					line = s.state == "connecting" and "正在建立连接..." or "正在连接..."
				end
				if s.state == "connecting" then line = "正在建立连接..." end
				S.Text(line, 150, 320, 18, WHITE, "center", 500, 1, ORDER + 2)
				S.Text("Esc 取消", 150, 380, 16, WHITE, "center", 500, 1, ORDER + 2)
			end
		end
		if self.message then S.Text(self.message, 0, 470, 18, RED, "center", 800, 1, ORDER + 3) end
	end
	return st
end

-- Session --------------------------------------------------------------------------------

local function hashState(g)
	local h = 2166136261
	local function mix(v)
		h = ((h ~ (v & 0xffffffff)) * 16777619) & 0xffffffff
	end
	local function num(x) mix(math.floor((tonumber(x) or 0) * 256 + 0.5)) end
	num(BVNRuntime.seed)
	local b = g.battle
	if b and not b.musou then
		num(b.round)
		num(b.time)
		for _, f in ipairs(b.fighters) do
			num(f.x); num(f.y); num(f.hp); num(f.qi); num(f.energy); num(f.state); num(f.dir)
		end
		num(#b.sprites)
	else
		local name = g.phase_name or ""
		for i = 1, #name do mix(name:byte(i)) end
	end
	return h
end

BVNNet = {
	team = false,
	relay = false,  -- always relay through the room server (tests)
	lanPort = nil,  -- LAN host port (default 27778)
	session = nil,  -- {host, lan, started, frame, desync}
	New = newScreen,

	LocalAddress = function()
		local s = Net.Status()
		return s.lan ~= "" and s.lan or "本机 IP (端口 27778)"
	end,

	Active = function()
		return BVNNet.session ~= nil and BVNNet.session.started == true
	end,

	-- The first lockstep tick on both machines: the same settings, seed and screen.
	Start = function(g, s)
		local ses = BVNNet.session or {host = s.side == 1}
		BVNNet.session = ses
		ses.started, ses.frame, ses.desync = true, 0, false
		local p = decode(s.payload)
		if p.v ~= VERSION then
			BVNNet.Stop(g, "对方的游戏版本不同")
			return
		end
		BVNRuntime.seed = s.seed
		BVNSettings.gameTime = tonumber(p.time) or BVNSettings.gameTime
		BVNSettings.fighterHP = tonumber(p.hp) or BVNSettings.fighterHP
		BVNSettings.keyMode = tonumber(p.key) or BVNSettings.keyMode
		BVNSettings.Apply()
		BVNScreen.inp = nil
		BVNScreen.net = true
		BVNTrans.Clear()
		BVNScreen.Release()
		g.mode, g.team = "pvp", p.team == "1"
		g.p1Select, g.p2Select, g.lastPicks, g.lastMap, g.selectMap, g.lastP1 = nil, nil, nil, nil, nil, nil
		g.paused, g.pauseQueued, g.ending = nil, nil, nil
		g.score = 0
		g:GoSelect()
	end,

	-- Leaves the session (or the room) and returns to the NET PLAY screen.
	Stop = function(g, message)
		Net.Leave()
		BVNNet.session = nil
		BVNScreen.net = nil
		BVNScreen.inp = nil
		BVNSettings.Load()
		BVNTrans.Clear()
		BVNScreen.Release()
		g:Go(newScreen(g, message))
	end,

	-- Every tick, before the screens.
	Update = function(g)
		local ses = BVNNet.session
		if not ses then return end
		if not ses.started then
			if Net.Running() then BVNNet.Start(g, Net.Status()) end
			return
		end
		if not Net.Running() then
			local s = Net.Status()
			BVNNet.Stop(g, say(s.error) or "对方已断开连接")
			return
		end
		ses.frame = ses.frame + 1
		if ses.frame % CHECK_EVERY == 0 then
			local s = Net.Status()
			Net.Checksum(s.frame, hashState(g))
			if s.desync and not ses.desync then ses.desync = s.desync_frame end
			ses.ping = s.ping
		end
	end,

	-- After the screens: the desync warning and the ping.
	Draw = function(g)
		local ses = BVNNet.session
		if not (ses and ses.started) then return end
		if ses.desync then
			S.Text("画面不同步 (帧 " .. tostring(ses.desync) .. ")：双方的游戏状态已不一致", 0, 4, 16, RED, "center", 800, 1, 5000)
		end
		if ses.ping and ses.ping >= 0 then
			S.Text(ses.ping .. " ms", 740, 580, 12, WHITE, "left", nil, 0.7, 5000)
		end
	end,

	Hash = hashState,
}
