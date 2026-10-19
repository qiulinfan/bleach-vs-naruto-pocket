-- NET PLAY: two players on two computers through the engine's netplay (Net,
-- engine net/Netplay). Ways to meet:
--   ROOM: a room code from the room server (netplay.json / POCKET_NET_SERVER);
--   LAN: a direct host found by LAN discovery, or its address typed in - also
--        the way over a virtual LAN (Tailscale, ZeroTier, Radmin VPN), whose
--        addresses the host screen lists;
--   CODE: connection codes the players exchange (public STUN, no server of ours).
-- From the first session tick both machines run the same game: VS PEOPLE from
-- the fighter select on, the host as player 1 and the guest as player 2, each
-- playing with their own player 1 keys; confirm and back are shared. NETCODE
-- picks rollback (inputs act at once; mispredicted ticks are simulated again
-- from a snapshot of the Lua state) or delay (lockstep).
-- Not attached to any actor; BVNGame calls BVNNet.Update(g) every tick.
local S = setmetatable({}, {__index = function(_, k) return BVNScreen[k] end})
local ORDER = 10
local WHITE = {255, 255, 255}
local YELLOW = {253, 237, 101}
local RED = {255, 110, 90}
local GREY = {170, 170, 170}
local VERSION = "bvn-net-4"
local CHECK_EVERY = 60
local GAME_ID = "bleach_vs_naruto"

local MODES = {{"SINGLE", "单人对战", false}, {"TEAM", "组队对战", true}}
local NETCODES = {{"ROLLBACK", "回滚 (推荐)", "rollback"}, {"DELAY", "延迟锁步", "lockstep"}}
-- Rollback input delay in ticks (the host's applies): AUTO follows the ping (1 or 2).
local DELAYS = {{"AUTO", "按网络自动", 0}, {"1F", "1 帧 (约 17 ms)", 1}, {"2F", "2 帧 (约 33 ms)", 2},
	{"3F", "3 帧 (约 50 ms)", 3}, {"4F", "4 帧 (约 67 ms)", 4}}
local KINDS = {lan = "局域网", tailscale = "Tailscale", zerotier = "ZeroTier", radmin = "Radmin VPN"}

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

-- The engine's messages (net/Netplay.cpp, Link.cpp) in the game's language.
local MESSAGES = {
	{"the other player left", "对方已离开"},
	{"connection lost", "连接中断"},
	{"no answer from the room server", "房间服务器没有响应"},
	{"could not connect directly", "无法直连：双方网络都比较严格，请改用房间码或虚拟局域网"},
	{"no answer from", "连接不上对方"},
	{"room server: no such room", "房间不存在"},
	{"room server: room is full", "房间已满"},
	{"cannot resolve the room server", "找不到房间服务器"},
	{"invalid connection code", "连接码不对"},
	{"cannot resolve", "地址无效"},
	{"different game version", "对方的游戏版本不同"},
	{"cannot open a UDP socket", "无法打开网络端口"},
	{"rollback needs state snapshots", "回滚需要状态快照"},
}

-- The connection's quality as the engine measures it: round trip, lost
-- probes and the path (a room server relays when that is faster), with a
-- colour: green is fine for rollback, yellow playable, red poor.
local GREEN = {120, 230, 120}
local function quality(s)
	if not s or s.ping < 0 then return nil end
	local parts = {"网络 " .. s.ping .. " ms"}
	if s.loss and s.loss >= 0 then parts[#parts + 1] = string.format("丢失 %d%%", math.floor(s.loss * 100 + 0.5)) end
	if s.link == "server" then parts[#parts + 1] = s.relay and "中继" or "直连" end
	local loss = math.max(s.loss or 0, 0)
	local color = (s.ping <= 100 and loss < 0.03) and GREEN or ((s.ping <= 200 and loss < 0.1) and YELLOW or RED)
	return table.concat(parts, "  "), color
end

local function say(err)
	if not err or err == "" then return nil end
	for _, m in ipairs(MESSAGES) do
		if err:find(m[1], 1, true) then return m[2] end
	end
	return err
end

local function configure()
	Net.Configure({local_prefix = "p1_", sides = {"p1_", "p2_"}, shared = {"confirm", "back"},
		mode = BVNNet.netcode, max_rollback = 8, delay = BVNNet.netcode == "rollback" and BVNNet.delay or 0,
		game = GAME_ID, force_relay = BVNNet.relay == true,
		stun = BVNNet.stun, discovery_port = BVNNet.discoveryPort})
	-- Rollback state: everything reachable from the globals (converted data is static).
	Net.Track(_G)
end

local function payload()
	return encode({v = VERSION, team = BVNNet.team and 1 or 0, time = BVNSettings.gameTime,
		hp = BVNSettings.fighterHP, key = BVNSettings.keyMode})
end

-- Text entry before the session starts (raw keys and the clipboard: nothing
-- is in step yet).
local KEYS = {}
for c in ("abcdefghijklmnopqrstuvwxyz0123456789"):gmatch(".") do KEYS[#KEYS + 1] = {c, c:upper()} end
for d = 0, 9 do KEYS[#KEYS + 1] = {"keypad " .. d, tostring(d)} end
KEYS[#KEYS + 1] = {".", "."}
KEYS[#KEYS + 1] = {"keypad .", "."}
KEYS[#KEYS + 1] = {"-", "-"}
KEYS[#KEYS + 1] = {";", ":"}

local function modifier()
	return Input.GetKey("left ctrl") or Input.GetKey("right ctrl") or Input.GetKey("left gui") or Input.GetKey("right gui")
end

local function typed(allowed, max, text)
	if Input.GetKeyDown("backspace") then return text:sub(1, -2) end
	if modifier() then
		if Input.GetKeyDown("v") then
			local pasted = ""
			for c in Application.GetClipboardText():upper():gmatch(".") do
				if allowed:find(c, 1, true) then pasted = pasted .. c end
			end
			return (text .. pasted):sub(1, max)
		end
		return text
	end
	for _, k in ipairs(KEYS) do
		if #text < max and allowed:find(k[2], 1, true) and Input.GetKeyDown(k[1]) then text = text .. k[2] end
	end
	return text
end

local function entered() return Input.GetKeyDown("return") or Input.GetKeyDown("keypad enter") end

local ROOM_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
local CODE_CHARS = "0123456789ABCDEFGHJKMNPQRSTVWXYZOIL-"
local IP_CHARS = "0123456789.:"

local function codeReady(text)
	return #text:gsub("-", "") == 21
end

-- The NET PLAY screen ----------------------------------------------------------------------

local function newScreen(g, message)
	local st = {name = "netplay", phase = "netplay", t = 0, bg = S.Clip("setting", 0, false), view = "menu",
		message = message, text = "", pick = 1}
	BVNSound.Music("bvn/bgm/back")
	st.group = BVNScreenDialog.Group({
		{label = "CREATE ROOM", cn = "房间码建房 (需要服务器)"},
		{label = "JOIN ROOM", cn = "输入房间码加入"},
		{label = "LAN HOST", cn = "局域网 / 虚拟局域网建房"},
		{label = "LAN JOIN", cn = "局域网 / 虚拟局域网加入"},
		{label = "CODE HOST", cn = "连接码建房 (不需要服务器)"},
		{label = "CODE JOIN", cn = "输入连接码加入"},
		{label = "MODE", cn = "对战模式", key = "team", options = MODES, value = BVNNet.team},
		{label = "NETCODE", cn = "联机方式", key = "netcode", options = NETCODES, value = BVNNet.netcode},
		{label = "DELAY", cn = "回滚输入延迟 (越小越跟手, 画面修正越多)", key = "delay", options = DELAYS, value = BVNNet.delay},
		{label = "BACK", cn = "返回"},
	}, {startY = 22, endY = 560, gap = 52})

	local function fail(text)
		st.message = text
		st.view = "menu"
		BVNNet.session = nil
		Net.Discover(false)
	end

	-- Starts hosting or joining; `how` is room, lan, code; `arg` the room code,
	-- address or host code when joining.
	function st.Start(host, how, arg)
		configure()
		local ok
		if how == "room" then
			local server = serverAddress()
			if not server then return fail("没有配置房间服务器 (netplay.json)") end
			ok = host and Net.Host(server, payload()) or Net.Join(server, arg)
		elseif how == "lan" then
			ok = host and Net.HostDirect(BVNNet.lanPort or 0, payload()) or Net.JoinDirect(arg)
		else
			ok = host and Net.CodeHost(payload()) or Net.CodeJoin(arg)
		end
		if not ok then return fail(say(Net.Status().error) or "连接失败") end
		Net.Discover(false)
		BVNNet.session = {host = host, how = how}
		st.view, st.message, st.text = "wait", nil, ""
	end

	local function back()
		if st.view == "wait" then Net.Leave() end
		Net.Discover(false)
		BVNNet.session = nil
		st.view, st.text = "menu", ""
	end

	function st:Update()
		self.t = self.t + 1
		self.bg:Step()
		local v = self.view
		if v == "menu" then
			local ev = self.group:Update()
			if S.Down("back", "menu") then
				g:GoMenu()
				return
			end
			if not ev then return end
			self.message = nil
			if ev.change == "team" then BVNNet.team = ev.value
			elseif ev.change == "netcode" then BVNNet.netcode = ev.value
			elseif ev.change == "delay" then BVNNet.delay = ev.value
			elseif ev.select == "CREATE ROOM" then st.Start(true, "room")
			elseif ev.select == "LAN HOST" then st.Start(true, "lan")
			elseif ev.select == "CODE HOST" then st.Start(true, "code")
			elseif ev.select == "JOIN ROOM" then self.view, self.text = "room", ""
			elseif ev.select == "CODE JOIN" then self.view, self.text = "code", ""
			elseif ev.select == "LAN JOIN" then
				configure()
				Net.Discover(true)
				self.view, self.pick = "lan", 1
			elseif ev.select == "BACK" then g:GoMenu() end
			return
		end
		if Input.GetKeyDown("escape") then return back() end
		if v == "room" then
			self.text = typed(ROOM_CHARS, 4, self.text)
			if #self.text == 4 and entered() then st.Start(false, "room", self.text) end
		elseif v == "code" then
			self.text = typed(CODE_CHARS, 23, self.text)
			if codeReady(self.text) and entered() then st.Start(false, "code", self.text) end
		elseif v == "ip" then
			self.text = typed(IP_CHARS, 21, self.text)
			if #self.text >= 7 and entered() then st.Start(false, "lan", self.text) end
		elseif v == "lan" then
			-- Found hosts, then "type an address".
			self.hosts = Net.Hosts()
			local n = #self.hosts + 1
			if Input.GetKeyDown("up") or Input.GetKeyDown("w") then self.pick = (self.pick - 2) % n + 1 end
			if Input.GetKeyDown("down") or Input.GetKeyDown("s") then self.pick = self.pick % n + 1 end
			self.pick = math.min(self.pick, n)
			if entered() or Input.GetKeyDown("j") then
				local h = self.hosts[self.pick]
				if h then st.Start(false, "lan", h.address) else self.view, self.text = "ip", "" end
			end
		elseif v == "wait" then
			local s = Net.Status()
			self.status = s
			if s.state == "error" or s.state == "disconnected" then
				Net.Leave()
				return fail(say(s.error) or "连接失败")
			end
			local ses = BVNNet.session or {}
			if s.code ~= "" and modifier() and Input.GetKeyDown("c") then
				Application.SetClipboardText(s.code)
				self.copied = self.t
			end
			-- The code host can take the guest's code (needed when its own network
			-- drops the guest's first packets).
			if ses.how == "code" and ses.host and s.state ~= "running" then
				self.text = typed(CODE_CHARS, 23, self.text)
				if codeReady(self.text) and entered() then
					if Net.CodeConnect(self.text) then self.connecting = true
					else self.message = "连接码不对" end
				end
			end
		end
	end

	local function box(title)
		S.Rect(110, 120, 580, 380, {0, 0, 0}, 210, ORDER + 1, "world")
		S.Text(title, 110, 140, 22, YELLOW, "center", 580, 1, ORDER + 2)
	end

	local function line(text, y, size, color)
		S.Text(text, 110, y, size or 18, color or WHITE, "center", 580, 1, ORDER + 2)
	end

	local function entry(y)
		local caret = (st.t // 30) % 2 == 0 and "_" or " "
		line(st.text .. caret, y, 30)
	end

	function st:Draw()
		-- The option screen's backdrop, its OPTION heading replaced.
		self.bg:Draw(nil, 1, ORDER, "world")
		S.Rect(596, 0, 204, 96, {22, 22, 22}, 255, ORDER, "world")
		local hw = S.FontWidth("NET PLAY")
		S.Font("NET PLAY", 790 - hw, 10, 1, 1, ORDER + 1, "world")
		S.Text("· 联机对战", 600, 52, 16, WHITE, "right", 190, 0.8, ORDER + 1)
		local v = self.view
		if v == "menu" then
			self.group:Draw(0, 0, ORDER + 1, "world")
			S.Text("主机为 1P，加入者为 2P，双方都用 1P 键位 (WASD + JKLUIO)", 60, 548, 14, WHITE, "left", nil, 1, ORDER + 2)
		elseif v == "room" then
			box("输入房间码 (4 位)")
			entry(250)
			line("回车确认    Esc 返回", 440, 16)
		elseif v == "code" then
			box("输入朋友的连接码")
			entry(250)
			line("可以 Ctrl+V / ⌘V 粘贴    回车确认    Esc 返回", 440, 16)
		elseif v == "ip" then
			box("输入主机地址")
			entry(250)
			line("局域网 IP，或 Tailscale / ZeroTier / Radmin 的虚拟 IP", 330, 16, GREY)
			line("回车确认    Esc 返回", 440, 16)
		elseif v == "lan" then
			box("局域网里的房间")
			local hosts = self.hosts or {}
			local y = 190
			for i, h in ipairs(hosts) do
				local p = decode(h.payload)
				local text = h.name .. "   " .. h.address .. "   " .. (p.team == "1" and "组队" or "单人")
				line((i == self.pick and "> " or "  ") .. text, y, 18, i == self.pick and YELLOW or WHITE)
				y = y + 30
			end
			if #hosts == 0 then line("正在寻找...（Tailscale 不支持自动发现，请手动输入）", y, 16, GREY); y = y + 30 end
			line((self.pick == #hosts + 1 and "> " or "  ") .. "手动输入地址", y + 10, 18, self.pick == #hosts + 1 and YELLOW or WHITE)
			line("W/S 选择    J 或回车加入    Esc 返回", 440, 16)
		else
			local s = self.status or Net.Status()
			local ses = BVNNet.session or {}
			local status = s.state == "connecting" and "正在建立连接..." or "等待对方加入..."
			if ses.how == "room" and ses.host then
				box("房间码")
				line(s.room ~= "" and s.room or "...", 190, 56)
				status = s.state == "server" and "正在连接房间服务器..." or (s.state == "waiting" and "把房间码告诉朋友" or status)
			elseif ses.how == "lan" and ses.host then
				box("等待加入：让朋友选 LAN JOIN")
				local y = 190
				local port = (s.lan or ""):match(":(%d+)$") or "27778"
				for _, a in ipairs(Net.LocalAddresses()) do
					line((KINDS[a.kind] or a.kind) .. "   " .. a.ip .. ":" .. port, y, a.kind == "lan" and 20 or 22,
						a.kind == "lan" and WHITE or YELLOW)
					y = y + 32
				end
				line("同一个网络会自动出现；虚拟局域网请让朋友手动输入上面的地址", 380, 14, GREY)
			elseif ses.how == "code" then
				box(ses.host and "把你的连接码发给朋友" or "把你的连接码发回给主机")
				if s.code ~= "" then
					line(s.code, 185, 30)
					local copied = self.copied and self.t - self.copied < 90
					line(copied and "已复制" or "Ctrl+C / ⌘C 复制", 228, 15, copied and YELLOW or GREY)
					if s.nat == "symmetric" then line("你的网络可能无法直连（对称 NAT）", 252, 15, RED) end
				else
					line("正在获取公网地址...", 195, 20)
				end
				if ses.host and s.state ~= "running" then
					line("朋友的连接码（朋友连不上时再输入）：", 285, 16, GREY)
					entry(310)
				end
			else
				box("正在加入")
			end
			local q, qc = quality(s)
			if q and s.state == "connecting" then line(q, 372, 16, qc) end
			line(status, 400, 18)
			line("Esc 取消", 440, 16)
		end
		if self.message then S.Text(self.message, 0, 512, 18, RED, "center", 800, 1, ORDER + 3) end
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
	netcode = "rollback",
	delay = 0,             -- rollback input delay in ticks, 0 automatic
	relay = false,         -- always relay through the room server (tests)
	lanPort = nil,         -- LAN host port (default 27778)
	stun = nil,            -- STUN servers for connection codes (tests; default the engine's)
	discoveryPort = nil,   -- LAN discovery port (tests; default 27779)
	session = nil,         -- {host, how, started, frame}
	New = newScreen,

	Active = function()
		return BVNNet.session ~= nil and BVNNet.session.started == true
	end,

	-- The first session tick on both machines: the same settings, seed and screen.
	Start = function(g, s)
		local ses = BVNNet.session or {host = s.side == 1}
		BVNNet.session = ses
		ses.started, ses.frame = true, 0
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
		if ses.frame % CHECK_EVERY == 0 then Net.Checksum(Net.Status().frame, hashState(g)) end
	end,

	-- After the screens: the desync warning, the ping and the netcode.
	Draw = function(g)
		local ses = BVNNet.session
		if not (ses and ses.started) or Net.IsResimulating() then return end
		local s = Net.Status()
		if s.desync then
			S.Text("画面不同步 (帧 " .. tostring(s.desync_frame) .. ")：双方的游戏状态已不一致", 0, 4, 16, RED, "center", 800, 1, 5000)
		end
		local q, qc = quality(s)
		if q then
			-- The ping is the round trip; what a player feels is the input delay.
			local tag = "输入延迟 " .. s.delay .. " 帧" .. (s.mode == "rollback" and ("  回滚 " .. s.max_rollback_seen) or "")
			-- One line between the select screen's name panels (and the HUD's bars).
			S.Text(q .. "    " .. tag, 0, 582, 12, qc, "center", 800, 0.8, 5000)
		end
	end,

	Hash = hashState,
}
