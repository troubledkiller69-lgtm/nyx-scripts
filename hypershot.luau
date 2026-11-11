--[[
	Hypershot — NYX build v2 (Rayfield)
	Game: "Hypershot!" by Frosted Studio
	Places: Main 17516596118 | Mobile 131008473296170 | GunGame 122181485177067
	        MainForNewPlayers 100040622766961

	v2 changes
	  - Rayfield interface (Gen2 source first, official Rayfield as fallback)
	  - aim core rewritten: mouse-delta feedback loop instead of raw CFrame writes,
	    so the game drives the camera and there is nothing to fight. sticky target
	    selection uses hysteresis + a keep-window + a LOS grace, not a 0.35s timer.
	  - every slider is live, nothing needs a restart.

	Panic: DELETE. Rayfield hides with its own key (K by default).
]]

if getgenv().NYX_HYPERSHOT then
	pcall(function()
		getgenv().NYX_HYPERSHOT.panic()
	end)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	return
end

local camera = workspace.CurrentCamera
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if workspace.CurrentCamera then
		camera = workspace.CurrentCamera
	end
end)

-- ============================================================================
-- config
-- ============================================================================

local CFG = {
	esp = {
		enabled = true,
		box = true,
		name = true,
		health = true,
		distance = true,
		tracer = false,
		chams = false,
		bots = true,
		teamCheck = true,
		maxDistance = 2500,
	},
	aim = {
		enabled = true,
		mode = "Hold",          -- Hold | Toggle
		method = "Mouse",       -- Mouse (mouse deltas) | Camera (raw CFrame)
		key = "Right Mouse",
		fov = 110,
		smoothness = 55,        -- 0 = raw, 100 = very soft
		maxStep = 26,           -- pixels per tick ceiling, mouse mode
		stick = 0.7,            -- keep-window multiplier on top of the fov
		switchMargin = 0.22,    -- a new target must be this much closer to steal the lock
		grace = 0.55,           -- seconds the lock survives a lost target
		part = "Head",
		visibleOnly = true,
		predict = 0.035,
		circle = true,
	},
	trigger = {
		enabled = false,
		fovPixels = 12,
		delay = 0.06,
		visibleOnly = true,
	},
	hitbox = {
		enabled = false,
		scale = 1.8,
	},
	speed = {
		enabled = false,
		value = 32,
	},
}

local COL = {
	box = Color3.fromRGB(255, 255, 255),
	bot = Color3.fromRGB(255, 132, 66),
	name = Color3.fromRGB(238, 238, 242),
	health = Color3.fromRGB(96, 222, 128),
	distance = Color3.fromRGB(196, 196, 204),
	chams = Color3.fromRGB(255, 62, 96),
	fov = Color3.fromRGB(255, 255, 255),
}

-- ============================================================================
-- state
-- ============================================================================

local STATE = {
	targets = {},
	targetSet = {},
	target = nil,
	point = nil,
	lastSeen = 0,
	lastLos = {},          -- [actor] = { t = number, ok = boolean }
	drawing = {},          -- [actor] = { box, name, distance, health, tracer, dot }
	chams = {},            -- [actor] = Highlight
	hitboxSizes = {},
	held = false,
	toggled = false,
	lastTrigger = 0,
	lastSweep = 0,
	firing = false,
	fovCircle = nil,
	alive = true,
}

local function note(text)
	pcall(function()
		print("[nyx-hypershot] " .. tostring(text))
	end)
end

local function alive(actor)
	if not actor or not actor.Parent then
		return false
	end
	local hum = actor:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

local function bodyOf(actor)
	return actor and (actor:FindFirstChild("HumanoidRootPart")
		or actor:FindFirstChild("UpperTorso")
		or actor:FindFirstChild("Head"))
end

local function isBot(actor)
	return Players:GetPlayerFromCharacter(actor) == nil
end

local function sameTeam(actor)
	local mine = LocalPlayer.Team
	if not CFG.esp.teamCheck or not mine or mine == "" then
		return false
	end
	local plr = Players:GetPlayerFromCharacter(actor)
	if plr then
		return plr.Team == mine
	end
	local tag = actor:GetAttribute("Team") or actor:GetAttribute("team")
	return tag ~= nil and tag == mine
end

local function protected(actor)
	local hum = actor:FindFirstChildOfClass("Humanoid")
	for _, container in ipairs({ actor, hum }) do
		if container then
			for name, value in pairs(container:GetAttributes()) do
				local key = string.lower(name)
				if value and (string.find(key, "spawn") or string.find(key, "immune") or string.find(key, "protect")) then
					return true
				end
			end
			for _, tag in ipairs(container:GetTags()) do
				local key = string.lower(tag)
				if string.find(key, "spawn") or string.find(key, "immune") or string.find(key, "protect") then
					return true
				end
			end
		end
	end
	return false
end

-- ============================================================================
-- target collection
-- ============================================================================

local function collect()
	local out, set = {}, {}
	STATE.targets, STATE.targetSet = out, set

	local function push(actor)
		if set[actor] or actor == LocalPlayer.Character then
			return
		end
		if not alive(actor) or sameTeam(actor) then
			return
		end
		set[actor] = true
		out[#out + 1] = actor
	end

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer and plr.Character then
			push(plr.Character)
		end
	end

	for _, obj in ipairs(workspace:GetChildren()) do
		if obj:IsA("Model") and obj:FindFirstChildOfClass("Humanoid") then
			push(obj)
		elseif obj:IsA("Folder") then
			for _, child in ipairs(obj:GetChildren()) do
				if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") then
					push(child)
				end
			end
		end
	end
end

-- ============================================================================
-- projection and visibility
-- ============================================================================

local function project(position)
	if not camera then
		return nil
	end
	local point, onScreen = camera:WorldToViewportPoint(position)
	if not onScreen or point.Z <= 0 then
		return nil
	end
	return Vector2.new(point.X, point.Y)
end

local function rayClear(actor, worldPos)
	local origin = camera.CFrame.Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character, actor, camera }
	params.IgnoreWater = true
	return workspace:Raycast(origin, worldPos - origin, params) == nil
end

-- cached for a few frames so a railing does not make the lock strobe
local function losOk(actor, point, now)
	local cached = STATE.lastLos[actor]
	if cached and now - cached.t < 0.1 then
		return cached.ok
	end
	local ok = (not CFG.aim.visibleOnly) or rayClear(actor, point)
	STATE.lastLos[actor] = { t = now, ok = ok }
	return ok
end

-- ============================================================================
-- aim core
-- ============================================================================

local function aimPoint(actor)
	local head = actor:FindFirstChild("Head")
	local body = actor:FindFirstChild("HumanoidRootPart")
	local base

	if CFG.aim.part == "Head" then
		base = head and head.Position
	elseif CFG.aim.part == "Torso" then
		base = body and body.Position
	else
		if head and body then
			local origin = camera.CFrame.Position
			base = ((head.Position - origin).Magnitude <= (body.Position - origin).Magnitude)
				and head.Position or body.Position
		else
			base = (head and head.Position) or (body and body.Position)
		end
	end

	if not base then
		return nil
	end

	if CFG.aim.predict > 0 and body then
		base = base + body.AssemblyLinearVelocity * CFG.aim.predict
	end
	return base
end

local function screenOffset(point)
	local sp = project(point)
	if not sp or not camera then
		return nil
	end
	return (sp - camera.ViewportSize / 2).Magnitude, sp
end

-- keeps the current body unless something is clearly better
local function updateTarget(now)
	local fov = CFG.aim.fov
	local current = STATE.target

	local bestActor, bestPoint, bestOffset = nil, nil, math.huge
	for _, actor in ipairs(STATE.targets) do
		if not protected(actor) then
			local point = aimPoint(actor)
			local offset = point and screenOffset(point)
			if offset and offset <= fov and losOk(actor, point, now) then
				if offset < bestOffset then
					bestActor, bestPoint, bestOffset = actor, point, offset
				end
			end
		end
	end

	if current and STATE.targetSet[current] and alive(current) and not protected(current) then
		local point = aimPoint(current)
		local offset = point and screenOffset(point)
		local keep = fov * (1 + CFG.aim.stick)

		if offset and offset <= keep then
			local visible = losOk(current, point, now)
			if visible then
				STATE.lastSeen = now
			end

			local stale = (now - STATE.lastSeen) > CFG.aim.grace
			local better = bestActor and bestActor ~= current and bestOffset < offset * (1 - CFG.aim.switchMargin)

			if better or (stale and bestActor) then
				STATE.target, STATE.point = bestActor, bestPoint
				STATE.lastSeen = now
				return
			end

			-- hold the lock; only feed a point the aim may actually pull toward
			STATE.target = current
			STATE.point = visible and point or nil
			return
		end
	end

	if bestActor then
		STATE.target, STATE.point = bestActor, bestPoint
		STATE.lastSeen = now
	else
		STATE.target, STATE.point = nil, nil
	end
end

local function gainFromSmoothness()
	-- 100 -> 0.06, 0 -> 0.85, exponential so the ends feel different
	return 0.85 * (0.0706 ^ (math.clamp(CFG.aim.smoothness, 0, 100) / 100))
end

local function mouseAim(point, dt)
	local sp = project(point)
	if not sp or not camera then
		return
	end
	-- with an unlocked cursor, mousemoverel would drag the pointer around the screen instead of turning
	if UserInputService.MouseBehavior == Enum.MouseBehavior.Default then
		return
	end
	local errorVector = sp - camera.ViewportSize / 2
	local distance = errorVector.Magnitude
	if distance < 1.2 then
		return
	end

	local gain = gainFromSmoothness() * math.clamp(dt * 60, 0.35, 2)
	local step = errorVector * math.clamp(gain, 0.01, 0.9)
	local cap = CFG.aim.maxStep * math.clamp(dt * 60, 0.35, 2)
	if step.Magnitude > cap then
		step = step.Unit * cap
	end

	pcall(function()
		mousemoverel(step.X, step.Y)
	end)
end

local function cameraAim(point, dt)
	local origin = camera.CFrame.Position
	local delta = point - origin
	if delta.Magnitude < 0.5 then
		return
	end
	local dir = delta.Unit
	local pitch = math.asin(math.clamp(dir.Y, -1, 1))
	local yaw = math.atan2(-dir.X, -dir.Z)
	local currentPitch, currentYaw = camera.CFrame:ToEulerAnglesYXZ()

	local function wrap(a)
		return (a + math.pi) % (2 * math.pi) - math.pi
	end

	local gain = math.clamp(gainFromSmoothness() * math.clamp(dt * 60, 0.35, 2), 0.01, 0.9)
	local stepYaw = wrap(yaw - currentYaw) * gain
	local stepPitch = wrap(pitch - currentPitch) * gain

	-- never rotate more than ~22 degrees in one frame, keeps a reacquire from snapping
	local limit = math.rad(22)
	stepYaw = math.clamp(stepYaw, -limit, limit)
	stepPitch = math.clamp(stepPitch, -limit, limit)

	camera.CFrame = CFrame.new(origin) * CFrame.fromEulerAnglesYXZ(currentPitch + stepPitch, currentYaw + stepYaw, 0)
end

local function aiming()
	if not CFG.aim.enabled then
		return false
	end
	if CFG.aim.mode == "Toggle" then
		return STATE.toggled
	end
	return STATE.held
end

local lastTick = os.clock()

local function aimStep()
	if not camera then
		return
	end
	local now = os.clock()
	local dt = math.clamp(now - lastTick, 0.001, 0.1)
	lastTick = now

	if not aiming() then
		return
	end

	updateTarget(now)
	if STATE.point then
		if CFG.aim.method == "Camera" then
			cameraAim(STATE.point, dt)
		else
			mouseAim(STATE.point, dt)
		end
	end
end

-- ============================================================================
-- triggerbot
-- ============================================================================

local function crosshairPoint()
	local center = camera.ViewportSize / 2
	local best, bestOffset = nil, CFG.trigger.fovPixels

	for _, actor in ipairs(STATE.targets) do
		if not protected(actor) then
			local point = aimPoint(actor)
			local offset = point and screenOffset(point)
			if offset and offset < bestOffset then
				if not CFG.trigger.visibleOnly or losOk(actor, point, os.clock()) then
					bestOffset = offset
					best = point
				end
			end
		end
	end
	return best, center
end

local function click()
	if STATE.firing then
		return
	end
	STATE.firing = true
	task.spawn(function()
		local ok = pcall(function()
			mouse1press()
			task.wait(0.025)
			mouse1release()
		end)
		if not ok then
			pcall(function()
				local vim = game:GetService("VirtualInputManager")
				vim:SendMouseButtonEvent(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2, 0, true, game, 1)
				task.wait(0.025)
				vim:SendMouseButtonEvent(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2, 0, false, game, 1)
			end)
		end
		STATE.firing = false
	end)
end

local function triggerStep()
	if not CFG.trigger.enabled then
		return
	end
	local now = os.clock()
	if now - STATE.lastTrigger < CFG.trigger.delay then
		return
	end
	if crosshairPoint() then
		STATE.lastTrigger = now
		click()
	end
end

-- ============================================================================
-- esp
-- ============================================================================

local function drawable(class, props)
	local ok, obj = pcall(function()
		local d = Drawing.new(class)
		for key, value in pairs(props) do
			d[key] = value
		end
		return d
	end)
	return ok and obj or nil
end

local function layerFor(actor)
	local entry = STATE.drawing[actor]
	if entry then
		return entry
	end
	entry = {
		box = drawable("Square", { Thickness = 1, Filled = false, Visible = false }),
		name = drawable("Text", { Size = 14, Center = true, Outline = true, Visible = false }),
		distance = drawable("Text", { Size = 12, Center = true, Outline = true, Visible = false }),
		health = drawable("Square", { Thickness = 0, Filled = true, Visible = false }),
		tracer = drawable("Line", { Thickness = 1.2, Visible = false }),
	}
	STATE.drawing[actor] = entry
	return entry
end

local function hideLayer(entry)
	for _, object in pairs(entry) do
		if object then
			pcall(function()
				object.Visible = false
			end)
		end
	end
end

local function destroyLayer(entry)
	for _, object in pairs(entry) do
		if object and object.Destroy then
			pcall(function()
				object:Destroy()
			end)
		end
	end
end

local function renderESP()
	if not CFG.esp.enabled then
		for _, entry in pairs(STATE.drawing) do
			hideLayer(entry)
		end
		return
	end

	local seen = {}
	local center = camera.ViewportSize / 2

	for _, actor in ipairs(STATE.targets) do
		local entry = layerFor(actor)
		seen[actor] = true

		local head = actor:FindFirstChild("Head")
		local body = bodyOf(actor)
		local hum = actor:FindFirstChildOfClass("Humanoid")
		if not (head and body and hum) then
			hideLayer(entry)
			continue
		end

		local distance = (body.Position - camera.CFrame.Position).Magnitude
		if distance > CFG.esp.maxDistance then
			hideLayer(entry)
			continue
		end

		local bot = isBot(actor)
		if bot and not CFG.esp.bots then
			hideLayer(entry)
			continue
		end

		local topScreen = project(head.Position + Vector3.new(0, 0.55, 0))
		local bottomScreen = project(body.Position - Vector3.new(0, 2.5, 0))
		local sideScreen = project(body.Position + camera.CFrame.RightVector * 1.2)
		local midScreen = project(body.Position)
		if not (topScreen and bottomScreen and sideScreen and midScreen) then
			hideLayer(entry)
			continue
		end

		local width = math.max(math.abs(sideScreen.X - midScreen.X) * 2, 6)
		local height = math.abs(bottomScreen.Y - topScreen.Y)
		if height < 4 then
			hideLayer(entry)
			continue
		end

		local left = bottomScreen.X - width / 2
		local top = math.min(topScreen.Y, bottomScreen.Y)
		local color = bot and COL.bot or COL.box

		if CFG.esp.box and entry.box then
			entry.box.Visible = true
			entry.box.Color = color
			entry.box.Position = Vector2.new(left, top)
			entry.box.Size = Vector2.new(width, height)
		elseif entry.box then
			entry.box.Visible = false
		end

		if CFG.esp.health and entry.health then
			local ratio = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
			entry.health.Visible = true
			entry.health.Color = COL.health
			entry.health.Size = Vector2.new(2, height * ratio)
			entry.health.Position = Vector2.new(left - 6, top + (height - height * ratio))
		elseif entry.health then
			entry.health.Visible = false
		end

		if CFG.esp.name and entry.name then
			local plr = Players:GetPlayerFromCharacter(actor)
			local label = plr and (plr.DisplayName .. " [P]") or (actor.Name .. " [BOT]")
			if plr and not bot then
				label = plr.DisplayName .. " [P]"
			end
			if protected(actor) then
				label = label .. " (spawn)"
			end
			entry.name.Visible = true
			entry.name.Color = bot and COL.bot or COL.name
			entry.name.Text = label
			entry.name.Position = Vector2.new(bottomScreen.X, top - 17)
		elseif entry.name then
			entry.name.Visible = false
		end

		if CFG.esp.distance and entry.distance then
			entry.distance.Visible = true
			entry.distance.Color = COL.distance
			entry.distance.Text = string.format("%d studs", math.floor(distance))
			entry.distance.Position = Vector2.new(bottomScreen.X, top + height + 3)
		elseif entry.distance then
			entry.distance.Visible = false
		end

		if CFG.esp.tracer and entry.tracer then
			entry.tracer.Visible = true
			entry.tracer.Color = color
			entry.tracer.From = Vector2.new(center.X, camera.ViewportSize.Y)
			entry.tracer.To = Vector2.new(bottomScreen.X, top + height)
		elseif entry.tracer then
			entry.tracer.Visible = false
		end
	end

	for actor, entry in pairs(STATE.drawing) do
		if not seen[actor] then
			hideLayer(entry)
		end
	end
end

local function renderChams()
	local keep = {}
	for _, actor in ipairs(STATE.targets) do
		if CFG.esp.chams then
			keep[actor] = true
			local highlight = STATE.chams[actor]
			if not highlight or highlight.Parent ~= actor then
				highlight = actor:FindFirstChild("NYX_Chams") or Instance.new("Highlight")
				highlight.Name = "NYX_Chams"
				highlight.FillColor = COL.chams
				highlight.FillTransparency = 0.55
				highlight.OutlineColor = COL.chams
				highlight.OutlineTransparency = 0
				highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				highlight.Parent = actor
				STATE.chams[actor] = highlight
			end
		end
	end
	for actor, highlight in pairs(STATE.chams) do
		if not keep[actor] then
			pcall(function()
				highlight:Destroy()
			end)
			STATE.chams[actor] = nil
		end
	end
end

-- ============================================================================
-- hitbox
-- ============================================================================

local function restoreHitboxes()
	for part, size in pairs(STATE.hitboxSizes) do
		pcall(function()
			part.Size = size
		end)
	end
	STATE.hitboxSizes = {}
end

local function renderHitboxes(now)
	if not CFG.hitbox.enabled then
		if next(STATE.hitboxSizes) then
			restoreHitboxes()
		end
		return
	end
	if now - STATE.lastSweep < 0.5 then
		return
	end
	STATE.lastSweep = now

	local wanted = {}
	for _, actor in ipairs(STATE.targets) do
		for _, part in ipairs(actor:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
				wanted[part] = true
				if not STATE.hitboxSizes[part] then
					STATE.hitboxSizes[part] = part.Size
					part.Size = part.Size * CFG.hitbox.scale
				end
			end
		end
	end

	for part, size in pairs(STATE.hitboxSizes) do
		if not wanted[part] then
			pcall(function()
				part.Size = size
			end)
			STATE.hitboxSizes[part] = nil
		end
	end
end

-- ============================================================================
-- loops
-- ============================================================================

RunService.RenderStepped:Connect(function()
	if not STATE.alive or not camera then
		return
	end
	collect()
	renderESP()
	renderChams()
	renderHitboxes(os.clock())
	triggerStep()

	if STATE.fovCircle then
		if CFG.aim.circle and CFG.aim.enabled then
			STATE.fovCircle.Visible = true
			STATE.fovCircle.Position = camera.ViewportSize / 2
			STATE.fovCircle.Radius = CFG.aim.fov
			STATE.fovCircle.Color = COL.fov
		else
			STATE.fovCircle.Visible = false
		end
	end
end)

pcall(function()
	RunService:UnbindFromRenderStep("NYX_Aim")
end)
RunService:BindToRenderStep("NYX_Aim", Enum.RenderPriority.Camera.Value + 1, aimStep)

-- ============================================================================
-- input
-- ============================================================================

local KEY_MAP = {
	["Right Mouse"] = Enum.UserInputType.MouseButton2,
	["Left Mouse"] = Enum.UserInputType.MouseButton1,
	["Middle Mouse"] = Enum.UserInputType.MouseButton3,
	["Left Shift"] = Enum.KeyCode.LeftShift,
	["Q"] = Enum.KeyCode.Q,
	["E"] = Enum.KeyCode.E,
	["C"] = Enum.KeyCode.C,
}

local function matches(input, target)
	if typeof(target) == "EnumItem" then
		return input.UserInputType == target or input.KeyCode == target
	end
	return false
end

UserInputService.InputBegan:Connect(function(input)
	local key = KEY_MAP[CFG.aim.key]
	if key and matches(input, key) then
		if CFG.aim.mode == "Toggle" then
			STATE.toggled = not STATE.toggled
		else
			STATE.held = true
		end
	end
	if input.KeyCode == Enum.KeyCode.Delete then
		if getgenv().NYX_HYPERSHOT then
			getgenv().NYX_HYPERSHOT.panic()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	local key = KEY_MAP[CFG.aim.key]
	if key and matches(input, key) and CFG.aim.mode ~= "Toggle" then
		STATE.held = false
	end
end)

-- ============================================================================
-- interface
-- ============================================================================

local SOURCES = {
	"https://raw.githubusercontent.com/SyncOfficialSpec/Rayfield_Gen_2_fanmade/refs/heads/main/source.lua",
	"https://sirius.menu/rayfield",
	"https://raw.githubusercontent.com/sirius-menu/rayfield/refs/heads/main/source.lua",
}

local function loadRayfield()
	for _, url in ipairs(SOURCES) do
		local ok, library = pcall(function()
			local body = game:HttpGet(url)
			local chunk = loadstring(body)
			if not chunk then
				error("compile failed")
			end
			local value = chunk()
			if type(value) ~= "table" and type(value) ~= "userdata" then
				error("bad return")
			end
			return value
		end)
		if ok and library then
			note("interface: " .. url)
			return library
		end
		note("interface failed: " .. url)
	end
	return nil
end

local Rayfield = loadRayfield()

local function buildFallback()
	-- no library at all: keep the cheat running, just expose the config through getgenv
	note("no Rayfield available, running headless")
	return nil
end

if Rayfield and Rayfield.CreateWindow then
	local Window = Rayfield:CreateWindow({
		Name = "hypershot",
		Subtitle = "nyx",
		Icon = 0,
		LoadingTitle = "hypershot",
		LoadingSubtitle = "nyx build v2",
		Theme = "Default",
		ConfigurationSaving = {
			Enabled = true,
			FolderName = "NYX",
			FileName = "hypershot",
		},
		KeySystem = false,
	})

	local AimTab = Window:CreateTab("Aim")
	local VisualTab = Window:CreateTab("Visuals")
	local MiscTab = Window:CreateTab("Misc")

	AimTab:CreateSection("Targeting")

	AimTab:CreateToggle({
		Name = "Aim assist",
		CurrentValue = CFG.aim.enabled,
		Flag = "aim_enabled",
		Callback = function(value)
			CFG.aim.enabled = value
		end,
	})

	AimTab:CreateDropdown({
		Name = "Activation",
		Options = { "Hold", "Toggle" },
		CurrentOption = { CFG.aim.mode },
		Flag = "aim_mode",
		Callback = function(option)
			CFG.aim.mode = type(option) == "table" and option[1] or option
			STATE.held = false
			STATE.toggled = false
		end,
	})

	AimTab:CreateDropdown({
		Name = "Key",
		Options = { "Right Mouse", "Left Mouse", "Middle Mouse", "Left Shift", "Q", "E", "C" },
		CurrentOption = { CFG.aim.key },
		Flag = "aim_key",
		Callback = function(option)
			CFG.aim.key = type(option) == "table" and option[1] or option
			STATE.held = false
			STATE.toggled = false
		end,
	})

	AimTab:CreateDropdown({
		Name = "Hit part",
		Options = { "Head", "Torso", "Nearest" },
		CurrentOption = { CFG.aim.part },
		Flag = "aim_part",
		Callback = function(option)
			CFG.aim.part = type(option) == "table" and option[1] or option
		end,
	})

	AimTab:CreateSection("Behaviour")

	AimTab:CreateSlider({
		Name = "FOV",
		Range = { 10, 400 },
		Increment = 5,
		CurrentValue = CFG.aim.fov,
		Suffix = "px",
		Flag = "aim_fov",
		Callback = function(value)
			CFG.aim.fov = value
		end,
	})

	AimTab:CreateSlider({
		Name = "Smoothness",
		Range = { 0, 100 },
		Increment = 1,
		CurrentValue = CFG.aim.smoothness,
		Flag = "aim_smooth",
		Callback = function(value)
			CFG.aim.smoothness = value
		end,
	})

	AimTab:CreateSlider({
		Name = "Max step",
		Range = { 2, 80 },
		Increment = 1,
		CurrentValue = CFG.aim.maxStep,
		Suffix = "px",
		Flag = "aim_step",
		Callback = function(value)
			CFG.aim.maxStep = value
		end,
	})

	AimTab:CreateSlider({
		Name = "Stickiness",
		Range = { 0, 250 },
		Increment = 5,
		CurrentValue = math.floor(CFG.aim.stick * 100),
		Suffix = "%",
		Flag = "aim_stick",
		Callback = function(value)
			CFG.aim.stick = value / 100
		end,
	})

	AimTab:CreateToggle({
		Name = "Visible only",
		CurrentValue = CFG.aim.visibleOnly,
		Flag = "aim_visible",
		Callback = function(value)
			CFG.aim.visibleOnly = value
			STATE.lastLos = {}
		end,
	})

	AimTab:CreateToggle({
		Name = "FOV circle",
		CurrentValue = CFG.aim.circle,
		Flag = "aim_circle",
		Callback = function(value)
			CFG.aim.circle = value
		end,
	})

	AimTab:CreateToggle({
		Name = "Use camera instead of mouse",
		CurrentValue = CFG.aim.method == "Camera",
		Flag = "aim_camera",
		Callback = function(value)
			CFG.aim.method = value and "Camera" or "Mouse"
		end,
	})

	AimTab:CreateSlider({
		Name = "Prediction",
		Range = { 0, 200 },
		Increment = 5,
		CurrentValue = math.floor(CFG.aim.predict * 1000),
		Suffix = "ms",
		Flag = "aim_predict",
		Callback = function(value)
			CFG.aim.predict = value / 1000
		end,
	})

	VisualTab:CreateSection("Players")

	VisualTab:CreateToggle({
		Name = "ESP",
		CurrentValue = CFG.esp.enabled,
		Flag = "esp_enabled",
		Callback = function(value)
			CFG.esp.enabled = value
		end,
	})

	VisualTab:CreateToggle({
		Name = "Boxes",
		CurrentValue = CFG.esp.box,
		Flag = "esp_box",
		Callback = function(value)
			CFG.esp.box = value
		end,
	})

	VisualTab:CreateToggle({
		Name = "Names + tags",
		CurrentValue = CFG.esp.name,
		Flag = "esp_name",
		Callback = function(value)
			CFG.esp.name = value
		end,
	})

	VisualTab:CreateToggle({
		Name = "Health",
		CurrentValue = CFG.esp.health,
		Flag = "esp_health",
		Callback = function(value)
			CFG.esp.health = value
		end,
	})

	VisualTab:CreateToggle({
		Name = "Distance",
		CurrentValue = CFG.esp.distance,
		Flag = "esp_distance",
		Callback = function(value)
			CFG.esp.distance = value
		end,
	})

	VisualTab:CreateToggle({
		Name = "Tracers",
		CurrentValue = CFG.esp.tracer,
		Flag = "esp_tracer",
		Callback = function(value)
			CFG.esp.tracer = value
		end,
	})

	VisualTab:CreateToggle({
		Name = "Chams",
		CurrentValue = CFG.esp.chams,
		Flag = "esp_chams",
		Callback = function(value)
			CFG.esp.chams = value
		end,
	})

	VisualTab:CreateToggle({
		Name = "Show bots",
		CurrentValue = CFG.esp.bots,
		Flag = "esp_bots",
		Callback = function(value)
			CFG.esp.bots = value
		end,
	})

	VisualTab:CreateSlider({
		Name = "Max distance",
		Range = { 100, 5000 },
		Increment = 100,
		CurrentValue = CFG.esp.maxDistance,
		Suffix = "studs",
		Flag = "esp_range",
		Callback = function(value)
			CFG.esp.maxDistance = value
		end,
	})

	MiscTab:CreateSection("Combat")

	MiscTab:CreateToggle({
		Name = "Triggerbot",
		CurrentValue = CFG.trigger.enabled,
		Flag = "trigger_enabled",
		Callback = function(value)
			CFG.trigger.enabled = value
		end,
	})

	MiscTab:CreateSlider({
		Name = "Trigger window",
		Range = { 2, 60 },
		Increment = 1,
		CurrentValue = CFG.trigger.fovPixels,
		Suffix = "px",
		Flag = "trigger_window",
		Callback = function(value)
			CFG.trigger.fovPixels = value
		end,
	})

	MiscTab:CreateSlider({
		Name = "Trigger delay",
		Range = { 0, 500 },
		Increment = 5,
		CurrentValue = math.floor(CFG.trigger.delay * 1000),
		Suffix = "ms",
		Flag = "trigger_delay",
		Callback = function(value)
			CFG.trigger.delay = value / 1000
		end,
	})

	MiscTab:CreateSection("Player")

	MiscTab:CreateToggle({
		Name = "Hitbox expander",
		CurrentValue = CFG.hitbox.enabled,
		Flag = "hitbox_enabled",
		Callback = function(value)
			CFG.hitbox.enabled = value
			if not value then
				restoreHitboxes()
			end
		end,
	})

	MiscTab:CreateSlider({
		Name = "Hitbox scale",
		Range = { 10, 40 },
		Increment = 1,
		CurrentValue = math.floor(CFG.hitbox.scale * 10),
		Suffix = "x",
		Flag = "hitbox_scale",
		Callback = function(value)
			CFG.hitbox.scale = value / 10
			restoreHitboxes()
		end,
	})

	MiscTab:CreateToggle({
		Name = "Walk speed",
		CurrentValue = CFG.speed.enabled,
		Flag = "speed_enabled",
		Callback = function(value)
			CFG.speed.enabled = value
			local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.WalkSpeed = value and CFG.speed.value or 16
			end
		end,
	})

	MiscTab:CreateSlider({
		Name = "Speed value",
		Range = { 16, 120 },
		Increment = 2,
		CurrentValue = CFG.speed.value,
		Flag = "speed_value",
		Callback = function(value)
			CFG.speed.value = value
			if CFG.speed.enabled then
				local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
				if hum then
					hum.WalkSpeed = value
				end
			end
		end,
	})

	MiscTab:CreateSection("Panic")

	MiscTab:CreateButton({
		Name = "Remove everything",
		Callback = function()
			if getgenv().NYX_HYPERSHOT then
				getgenv().NYX_HYPERSHOT.panic()
			end
		end,
	})

	MiscTab:CreateLabel("DELETE also works as a panic key")

	pcall(function()
		Rayfield:LoadConfiguration()
	end)
else
	buildFallback()
end

STATE.fovCircle = drawable("Circle", { Thickness = 1.3, NumSides = 48, Filled = false, Visible = false })

-- ============================================================================
-- panic
-- ============================================================================

local function panic()
	STATE.alive = false
	CFG.esp.enabled = false
	CFG.aim.enabled = false
	CFG.trigger.enabled = false
	CFG.hitbox.enabled = false

	restoreHitboxes()

	local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = 16
	end

	for actor, entry in pairs(STATE.drawing) do
		destroyLayer(entry)
		STATE.drawing[actor] = nil
	end
	for actor, highlight in pairs(STATE.chams) do
		pcall(function()
			highlight:Destroy()
		end)
		STATE.chams[actor] = nil
	end
	if STATE.fovCircle then
		pcall(function()
			STATE.fovCircle:Destroy()
		end)
		STATE.fovCircle = nil
	end
	pcall(function()
		RunService:UnbindFromRenderStep("NYX_Aim")
	end)
	pcall(function()
		if Rayfield and Rayfield.Destroy then
			Rayfield:Destroy()
		end
	end)

	getgenv().NYX_HYPERSHOT = nil
	note("panic")
end

getgenv().NYX_HYPERSHOT = {
	config = CFG,
	state = STATE,
	panic = panic,
}

note("v2 loaded — aim is Hold + Right Mouse by default")
