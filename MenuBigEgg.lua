--[[=================================================================
	MenuBigEgg  |  Big Egg Radar   ·   para Steal an Egg
	Delta Executor (movil)  —  pega todo y dale EXECUTE
	-----------------------------------------------------------------
	Lee del juego: personaje del huevo, peso (kg), rareza y $/s.
	MODO BOT  : rastrea tu server y sube los huevos gordos a un tablero.
	MODO MAIN : lee el tablero y te manda directo al server del huevo.
	El panel muestra:   Personaje  -  xx kg  -  x/s
==================================================================]]

--========================== CONFIG ==========================
local CONFIG = {
	MODE       = "MAIN",   -- "MAIN" (te teletransporta) o "BOT" (rastrea)
	BIN        = "",       -- id del tablero. MAIN lo crea solo; en el BOT pegas el mismo id.
	MIN_SCALE  = 1.30,     -- escala minima para contar como "huevo grande"
	MIN_RANK   = 1,        -- rareza minima (1 Common ... 12 Light&Dark)
	BOT_EVERY  = 6,        -- segundos entre escaneos (modo BOT)
	POLL_EVERY = 8,        -- segundos entre lecturas del tablero
	STALE      = 180,      -- segundos para descartar un server sin reportar
	MAX_ROWS   = 25,
}

--========================= SERVICIOS ========================
local Players         = game:GetService("Players")
local UIS             = game:GetService("UserInputService")
local TweenService    = game:GetService("TweenService")
local Lighting        = game:GetService("Lighting")
local RS              = game:GetService("ReplicatedStorage")
local HttpService     = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local VirtualUser     = game:GetService("VirtualUser")

local plr = Players.LocalPlayer
local pg  = plr:WaitForChild("PlayerGui")

local OLD = pg:FindFirstChild("MenuBigEgg")
if OLD then OLD:Destroy() end

--==================== UTILIDADES BASICAS ====================
local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end

local function fmt(n)
	n = tonumber(n) or 0
	if n >= 1e12 then return string.format("%.2fT", n/1e12) end
	if n >= 1e9  then return string.format("%.2fB", n/1e9)  end
	if n >= 1e6  then return string.format("%.2fM", n/1e6)  end
	if n >= 1e3  then return string.format("%.1fk", n/1e3)  end
	return tostring(math.floor(n))
end

--==================== RAREZA ================================
local RANK = {
	["Basic"]=1, ["Common"]=1,
	["Uncommon"]=2, ["Celestial"]=2, ["SuperRare"]=2,
	["Rare"]=3, ["Epic"]=4, ["Legendary"]=5,
	["Mythic"]=6, ["Mythical"]=6, ["Prismatic"]=6, ["Rainbow"]=6,
	["Squishy God"]=6, ["Brainrot God"]=6,
	["Cosmic"]=7, ["Exclusive"]=7, ["Admin"]=7,
	["Secret"]=8, ["Exotic"]=8,
	["Eternal"]=9, ["Limited"]=9,
	["Divine"]=10, ["Transcendent"]=10, ["Superior"]=10,
	["Titan"]=11,
	["Light & Dark"]=12, ["LightDark"]=12,
}
local RANK_NAMES = {}
for k, v in pairs(RANK) do RANK_NAMES[v] = RANK_NAMES[v] or k end

local function rankName(n) return RANK_NAMES[n] or "Common" end

--==================== MODULOS DEL JUEGO =====================
local function findModule(...)
	local node = RS
	for i = 1, select("#", ...) do
		if not node then return nil end
		node = node:FindFirstChild((select(i, ...)))
	end
	return node
end

local _cache = {}
local function mod(...)
	local key = table.concat({...}, ".")
	if _cache[key] ~= nil then return _cache[key] end
	local m = findModule(...)
	local ok, res = pcall(function() return require(m) end)
	_cache[key] = ok and res or false
	return _cache[key] or nil
end

local function getAssets()
	local a = mod("Data", "Assets")
	if not a then return nil end
	return a.Directory or a
end

local function getAreas()
	local a = mod("Data", "Areas")
	if not a then return nil end
	return a.Directory or a
end

--==================== LEER HUEVOS DEL CAMPO =================
local function readFieldEggs()
	-- 1) via EggState
	local ok, recs = pcall(function()
		local E = mod("Client", "EggState")
		local snap = E and E.ReadFieldEggs and E.ReadFieldEggs()
		return snap and (snap.Records or snap)
	end)
	if ok and type(recs) == "table" then return recs end

	-- 2) via remoto snapshot
	local ok2, recs2 = pcall(function()
		local r = findModule("Shared", "Remotes")
		local ew = r and r:FindFirstChild("EggWorld")
		local f = ew and ew:FindFirstChild("AskFieldEggSnapshot")
		local snap = f and f:InvokeServer()
		return snap and (snap.Records or snap)
	end)
	if ok2 and type(recs2) == "table" then return recs2 end

	return {}
end

local function resolveRarity(rec, a)
	local r = rec.Rarity or (a and a.Rarity)
	local name
	if type(r) == "table" then
		name = r.DisplayName or r._id or r.Name
	elseif type(r) == "string" then
		name = r
	end
	if not name and rec.AreaId then
		local areas = getAreas()
		local area = areas and areas[rec.AreaId]
		local rr = area and area.Rarity
		name = type(rr) == "table" and (rr.DisplayName or rr._id) or (type(rr) == "string" and rr)
	end
	name = name or "?"
	local rank = RANK[name] or (type(r) == "table" and tonumber(r.RarityNumber)) or 1
	return name, math.floor(rank)
end

local function eggToInfo(rec)
	local cat = rec.AssetCategory or rec.Category or rec.Name
	local a = cat and getAssets() and getAssets()[cat]
	local scale = tonumber(rec.AssetScale or rec.Scale) or 1

	local petName = (a and (a.DisplayName or a.Name)) or (type(cat) == "string" and cat) or "?"
	local weight  = (a and tonumber(a.ModelWeight or a.Weight) or 0) * (scale ^ 3)
	local rate    = (a and tonumber(a.EarningRate or a.Income) or 0)
	local factor  = (scale <= 5) and (scale ^ 1.85) or (((scale / 5) ^ 1.2) * 19.637875755794113)
	local income  = rate * factor

	local rName, rRank = resolveRarity(rec, a)

	local muts = {}
	if type(rec.Mutations) == "table" then
		for _, m in ipairs(rec.Mutations) do
			if type(m) == "string" then table.insert(muts, m) end
		end
	end
	if rec.HasParasite or rec.BaseMutation == "Parasite" then table.insert(muts, "Parasite") end

	return {
		name   = petName,
		weight = weight,
		income = income,
		rarity = rName,
		rank   = rRank,
		scale  = scale,
		area   = tostring(rec.AreaId or ""),
		muts   = table.concat(muts, " · "),
	}
end

local function scanOwn()
	local out = {}
	for _, rec in ipairs(readFieldEggs()) do
		if (rec.State == nil or rec.State == "Slot") then
			local info = eggToInfo(rec)
			local big = info.scale >= CONFIG.MIN_SCALE or info.weight >= 100000
			if big and info.rank >= CONFIG.MIN_RANK then
				table.insert(out, info)
			end
		end
	end
	table.sort(out, function(x, y) return x.weight > y.weight end)
	return out
end

--==================== HTTP (tablero compartido) =============
local function httpRequest(opts)
	if typeof(request) == "function" then
		local ok, res = pcall(request, opts)
		if ok and res then return res end
	end
	if typeof(http_request) == "function" then
		local ok, res = pcall(http_request, opts)
		if ok and res then return res end
	end
	return nil
end

local BIN_URL = "https://jsonblob.com/api/jsonBlob/"

local function createBin()
	local res = httpRequest({
		Url = "https://jsonblob.com/api/jsonBlob",
		Method = "POST",
		Body = '{"servers":{}}',
		Headers = { ["Content-Type"] = "application/json" },
	})
	if not res then return nil end
	local id
	local h = res.Headers or {}
	for k, v in pairs(h) do
		local lk = tostring(k):lower()
		if lk == "x-jsonblob" then id = tostring(v) end
		if lk == "location" and not id then id = tostring(v):match("([%w%-_]+)$") end
	end
	if not id and type(res.Body) == "string" then
		id = res.Body:match("([%w%-_]+)%s*$")
	end
	return id
end

local function binGet(id)
	if not id or id == "" then return nil end
	local ok, body = pcall(game.HttpGet, game, BIN_URL .. id)
	if not ok then return nil end
	local ok2, t = pcall(function() return HttpService:JSONDecode(body) end)
	return ok2 and t or nil
end

local function binPut(id, tbl)
	if not id or id == "" then return false end
	local res = httpRequest({
		Url = BIN_URL .. id,
		Method = "PUT",
		Body = HttpService:JSONEncode(tbl),
		Headers = { ["Content-Type"] = "application/json" },
	})
	return res ~= nil
end

local function saveBin(id)
	pcall(function() writefile("MenuBigEgg_bin.txt", tostring(id)) end)
end
local function loadBin()
	local ok, v = pcall(function() return readfile("MenuBigEgg_bin.txt") end)
	if ok and type(v) == "string" and #v > 0 then return v end
	return nil
end

--===================== TELEPORT =============================
local function joinServer(jobId)
	if not jobId or jobId == "" then return end
	task.spawn(function()
		local ok, err = pcall(function()
			TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, plr)
		end)
		if not ok then warn("[MenuBigEgg] teleport: " .. tostring(err)) end
	end)
end

--=================================================================
--                            GUI
--=================================================================
local gui = new("ScreenGui", {
	Name = "MenuBigEgg", ResetOnSpawn = false,
	IgnoreGuiInset = true, DisplayOrder = 999,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, pg)

local blur = new("BlurEffect", { Size = 0 }, Lighting)

local BALL, W, H, GAP = 62, 340, 430, 16

-- PELOTITA
local ball = new("TextButton", {
	Parent = gui, Text = "", AutoButtonColor = false,
	Size = UDim2.fromOffset(BALL, BALL),
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -20, 1, -20),
	BackgroundColor3 = Color3.fromRGB(230, 250, 255),
	BackgroundTransparency = 0.22, ZIndex = 6,
})
new("UICorner", { CornerRadius = UDim.new(1, 0) }, ball)
new("UIStroke", { Color = Color3.fromRGB(255,255,255), Thickness = 1.6, Transparency = 0.3 }, ball)
new("UIGradient", {
	Rotation = 140,
	Color = ColorSequence.new(Color3.fromRGB(170,255,225), Color3.fromRGB(150,200,255)),
}, ball)

local egg = new("Frame", {
	Parent = ball, BorderSizePixel = 0,
	AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(.5,.5),
	Size = UDim2.fromOffset(20, 26),
	BackgroundColor3 = Color3.fromRGB(255,255,255),
}, ball)
new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, egg)

-- PANEL
local panel = new("Frame", {
	Parent = gui, Visible = false, ClipsDescendants = true,
	Size = UDim2.fromOffset(W, H),
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -20, 1, -(20 + BALL + GAP)),
	BackgroundColor3 = Color3.fromRGB(22, 24, 38),
	BackgroundTransparency = 0.35, ZIndex = 5,
})
new("UICorner", { CornerRadius = UDim.new(0, 22) }, panel)
new("UIStroke", { Color = Color3.fromRGB(255,255,255), Thickness = 1.5, Transparency = 0.72 }, panel)
new("UIGradient", {
	Rotation = 135,
	Color = ColorSequence.new(Color3.fromRGB(255,255,255), Color3.fromRGB(180,220,255)),
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 0.78),
	}),
}, panel)

local scale = new("UIScale", { Scale = 0.85 }, panel)
new("UIPadding", {
	PaddingTop = UDim.new(0,14), PaddingBottom = UDim.new(0,14),
	PaddingLeft = UDim.new(0,14), PaddingRight = UDim.new(0,14),
}, panel)

-- HEADER
local head = new("Frame", { Parent = panel, BackgroundTransparency = 1, Size = UDim2.new(1,0,0,38) }, panel)
new("TextLabel", {
	Parent = head, BackgroundTransparency = 1,
	Size = UDim2.new(1,-46,1,0), Font = Enum.Font.GothamBold,
	Text = "MenuBigEgg", TextSize = 17, TextColor3 = Color3.fromRGB(245,250,255),
	TextXAlignment = Enum.TextXAlignment.Left,
}, head)

local xBtn = new("TextButton", {
	Parent = head, Text = "X", Font = Enum.Font.GothamBold, TextSize = 14,
	TextColor3 = Color3.fromRGB(245,250,255), AutoButtonColor = false,
	Size = UDim2.fromOffset(34,34), AnchorPoint = Vector2.new(1,.5),
	Position = UDim2.new(1,0,.5,0),
	BackgroundColor3 = Color3.fromRGB(255,255,255), BackgroundTransparency = 0.78, ZIndex = 7,
}, head)
new("UICorner", { CornerRadius = UDim.new(1,0) }, xBtn)
new("UIStroke", { Color = Color3.fromRGB(255,255,255), Thickness = 1.2, Transparency = 0.45 }, xBtn)

-- ESTADO (toca para copiar el id del tablero)
local status = new("TextButton", {
	Parent = panel, AutoButtonColor = false, TextXAlignment = Enum.TextXAlignment.Left,
	Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 22),
	BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 12,
	TextColor3 = Color3.fromRGB(200, 215, 240), Text = "Iniciando...",
}, panel)

-- TOOLBAR
local bar = new("Frame", {
	Parent = panel, BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 68), Size = UDim2.new(1, 0, 0, 30),
}, panel)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }, bar)

local function makeBtn(text, color, cb)
	local b = new("TextButton", {
		Parent = bar, Text = text, Font = Enum.Font.GothamBold, TextSize = 11,
		TextColor3 = Color3.fromRGB(8, 22, 30), AutoButtonColor = false,
		Size = UDim2.fromOffset(96, 30),
		BackgroundColor3 = color or Color3.fromRGB(140, 240, 205),
	}, bar)
	new("UICorner", { CornerRadius = UDim.new(1,0) }, b)
	new("UIStroke", { Color = Color3.fromRGB(255,255,255), Thickness = 1, Transparency = 0.45 }, b)
	b.MouseButton1Click:Connect(cb)
	return b
end

local modeBtn = makeBtn("MODO: " .. CONFIG.MODE, Color3.fromRGB(150, 200, 255), function()
	CONFIG.MODE = (CONFIG.MODE == "MAIN") and "BOT" or "MAIN"
	modeBtn.Text = "MODO: " .. CONFIG.MODE
	updateStatus()
end)

local minBtn = makeBtn("MIN: " .. rankName(CONFIG.MIN_RANK), Color3.fromRGB(255, 210, 150), function()
	CONFIG.MIN_RANK = CONFIG.MIN_RANK >= 12 and 1 or (CONFIG.MIN_RANK + 1)
	minBtn.Text = "MIN: " .. rankName(CONFIG.MIN_RANK)
end)

local scanBtn = makeBtn("ESCANEAR", Color3.fromRGB(170, 255, 225), function()
	task.spawn(refresh)
end)

-- LISTA
local list = new("ScrollingFrame", {
	Parent = panel, BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 104), Size = UDim2.new(1, 0, 1, -134),
	BorderSizePixel = 0, ScrollBarThickness = 3,
	CanvasSize = UDim2.new(0,0,0,0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarImageColor3 = Color3.fromRGB(200, 225, 255),
	ScrollBarImageTransparency = 0.4,
}, panel)
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, list)

-- FOOTER
new("TextLabel", {
	Parent = panel, BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(.5, 1), Position = UDim2.new(.5, 0, 1, 0),
	Size = UDim2.new(1, 0, 0, 20),
	Text = "Conviertete en un top 1 junto a MenuBigEgg",
	Font = Enum.Font.GothamBold, TextSize = 12,
	TextColor3 = Color3.fromRGB(225, 235, 250),
}, panel)

--==================== RENDER DE FILAS =======================
local rowObjs = {}
local function clearRows()
	for _, r in ipairs(rowObjs) do r:Destroy() end
	rowObjs = {}
end

local function render(items)
	clearRows()
	if #items == 0 then
		local r = new("Frame", {
			Parent = list, LayoutOrder = 1, Size = UDim2.new(1,0,0,48),
			BackgroundColor3 = Color3.fromRGB(255,255,255), BackgroundTransparency = 0.88,
			BorderSizePixel = 0,
		})
		new("UICorner", { CornerRadius = UDim.new(0,14) }, r)
		new("TextLabel", {
			Parent = r, BackgroundTransparency = 1, Size = UDim2.fromScale(1,1),
			Text = "Buscando huevos gordos...", Font = Enum.Font.GothamMedium,
			TextSize = 13, TextColor3 = Color3.fromRGB(210, 222, 240),
		}, r)
		table.insert(rowObjs, r)
		return
	end

	for i, d in ipairs(items) do
		if i > CONFIG.MAX_ROWS then break end

		local row = new("Frame", {
			Parent = list, LayoutOrder = i, BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 48),
			BackgroundColor3 = Color3.fromRGB(255,255,255), BackgroundTransparency = 0.86,
		})
		new("UICorner", { CornerRadius = UDim.new(0, 14) }, row)
		new("UIStroke", { Color = Color3.fromRGB(255,255,255), Thickness = 1, Transparency = 0.78 }, row)

		local av = new("Frame", {
			Parent = row, BorderSizePixel = 0,
			Position = UDim2.fromOffset(8, 7), Size = UDim2.fromOffset(34,34),
			BackgroundColor3 = Color3.fromRGB(215, 250, 240),
		}, row)
		new("UICorner", { CornerRadius = UDim.new(1,0) }, av)
		new("TextLabel", {
			Parent = av, BackgroundTransparency = 1, Size = UDim2.fromScale(1,1),
			Text = string.sub(d.name, 1, 1):upper(), Font = Enum.Font.GothamBlack,
			TextSize = 15, TextColor3 = Color3.fromRGB(10, 25, 35),
		}, av)

		new("TextLabel", {
			Parent = row, BackgroundTransparency = 1,
			Position = UDim2.fromOffset(50, 6), Size = UDim2.new(0, 170, 0, 16),
			Text = d.name, Font = Enum.Font.GothamBold, TextSize = 14,
			TextColor3 = Color3.fromRGB(248, 251, 255),
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		}, row)

		local sub = fmt(d.weight) .. " kg  -  " .. fmt(d.income) .. "/s"
		if d.muts and #d.muts > 0 then sub = sub .. "  -  " .. d.muts end

		new("TextLabel", {
			Parent = row, BackgroundTransparency = 1,
			Position = UDim2.fromOffset(50, 25), Size = UDim2.new(0, 175, 0, 14),
			Text = sub, Font = Enum.Font.GothamMedium, TextSize = 12,
			TextColor3 = Color3.fromRGB(190, 205, 230),
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		}, row)

		local join = new("TextButton", {
			Parent = row, Font = Enum.Font.GothamBlack, TextSize = 12,
			TextColor3 = Color3.fromRGB(6, 20, 28), AutoButtonColor = false,
			Size = UDim2.fromOffset(70, 28), AnchorPoint = Vector2.new(1,.5),
			Position = UDim2.new(1, -9, .5, 0),
			Text = d.here and "AQUI" or "JOIN",
			BackgroundColor3 = d.here and Color3.fromRGB(255, 220, 160) or Color3.fromRGB(130, 240, 205),
		}, row)
		new("UICorner", { CornerRadius = UDim.new(1,0) }, join)
		new("UIStroke", { Color = Color3.fromRGB(255,255,255), Thickness = 1, Transparency = 0.4 }, join)

		if not d.here then
			join.MouseButton1Click:Connect(function()
				joinServer(d.jobId)
			end)
		end

		table.insert(rowObjs, row)
	end
end

--==================== REFRESH (MAIN) ========================
local lastBoardInfo = ""
function updateStatus()
	local txt
	if CONFIG.BIN == "" then
		txt = "Tablero: creando..."
	else
		txt = "Tablero: " .. string.sub(CONFIG.BIN, 1, 10) .. "...  ·  " .. lastBoardInfo
	end
	status.Text = "[" .. CONFIG.MODE .. "]  " .. txt
end

function refresh()
	local items = {}

	-- huevos de tu propio server
	for _, e in ipairs(scanOwn()) do
		e.jobId = game.JobId
		e.here = true
		table.insert(items, e)
	end

	-- huevos reportados por los bots
	if CONFIG.BIN ~= "" then
		local board = binGet(CONFIG.BIN)
		if board and type(board.servers) == "table" then
			local now = os.time()
			local n = 0
			for jobId, srv in pairs(board.servers) do
				if jobId ~= game.JobId and type(srv.eggs) == "table"
					and (now - (tonumber(srv.updated) or 0) <= CONFIG.STALE) then
					n = n + 1
					for _, e in ipairs(srv.eggs) do
						e.jobId = jobId
						e.here = false
						table.insert(items, e)
					end
				end
			end
			lastBoardInfo = n .. " servers con huevos"
		else
			lastBoardInfo = "sin conexion"
		end
	end

	table.sort(items, function(a, b) return (a.weight or 0) > (b.weight or 0) end)
	render(items)
	updateStatus()
end

--==================== BUCLE BOT =============================
task.spawn(function()
	while true do
		task.wait(CONFIG.BOT_EVERY)
		if CONFIG.MODE == "BOT" and CONFIG.BIN ~= "" then
			local ok = pcall(function()
				local board = binGet(CONFIG.BIN) or { servers = {} }
				board.servers = board.servers or {}
				board.servers[game.JobId] = {
					placeId = game.PlaceId,
					bot = plr.Name,
					players = #Players:GetPlayers(),
					updated = os.time(),
					eggs = scanOwn(),
				}
				local now = os.time()
				for jid, srv in pairs(board.servers) do
					if now - (tonumber(srv.updated) or 0) > CONFIG.STALE then
						board.servers[jid] = nil
					end
				end
				binPut(CONFIG.BIN, board)
			end)
			if not ok then lastBoardInfo = "sin conexion" end
		end
	end
end)

--==================== BUCLE MAIN ============================
task.spawn(function()
	while true do
		task.wait(CONFIG.POLL_EVERY)
		if CONFIG.MODE == "MAIN" then
			pcall(refresh)
		end
	end
end)

--==================== ANTI-AFK ==============================
plr.Idled:Connect(function()
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end)

--==================== ABRIR / CERRAR ========================
local open = false

local function setOpen(v)
	open = v
	if v then
		panel.Visible = true
		scale.Scale = 0.85
		TweenService:Create(scale, TweenInfo.new(.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		TweenService:Create(blur, TweenInfo.new(.3), { Size = 14 }):Play()
	else
		TweenService:Create(scale, TweenInfo.new(.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.85 }):Play()
		TweenService:Create(blur, TweenInfo.new(.25), { Size = 0 }):Play()
		task.delay(0.2, function() if not open then panel.Visible = false end end)
	end
end

xBtn.MouseButton1Click:Connect(function() setOpen(false) end)

--==================== ARRASTRAR PELOTITA ====================
local dragging, dragStart, startPos, moved = false, nil, nil, false

ball.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch
	or input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragging, moved = true, false
		dragStart, startPos = input.Position, ball.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
				if not moved then setOpen(not open) end
			end
		end)
	end
end)

UIS.InputChanged:Connect(function(input)
	if not dragging then return end
	if input.UserInputType == Enum.UserInputType.Touch
	or input.UserInputType == Enum.UserInputType.MouseMovement then
		local d = input.Position - dragStart
		if d.Magnitude > 8 then moved = true end
		local nx = startPos.X.Offset + d.X
		local ny = startPos.Y.Offset + d.Y
		ball.Position  = UDim2.new(1, nx, 1, ny)
		panel.Position = UDim2.new(1, nx, 1, ny - (BALL + GAP))
	end
end)

--==================== ARRANQUE ==============================
-- Crea o carga el tablero compartido
task.spawn(function()
	if CONFIG.BIN == "" then
		local saved = loadBin()
		if saved then
			CONFIG.BIN = saved
		else
			local id = createBin()
			if id then
				CONFIG.BIN = id
				saveBin(id)
				print("[MenuBigEgg] Tablero creado. Pega este id en los BOT: " .. id)
			end
		end
	end
	status.MouseButton1Click:Connect(function()
		if CONFIG.BIN ~= "" then
			pcall(function() setclipboard(CONFIG.BIN) end)
			lastBoardInfo = "id copiado"
			updateStatus()
		end
	end)
	updateStatus()
	pcall(refresh)
end)

setOpen(true)
print("[MenuBigEgg] cargado  ·  modo " .. CONFIG.MODE)
