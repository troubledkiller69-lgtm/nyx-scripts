--[[
	Hypershot — NYX build
	Game: "Hypershot!" by Frosted Studio
	Places: Main 17516596118 | Mobile 131008473296170 | GunGame 122181485177067
	        MainForNewPlayers 100040622766961

	Everything here is readable on purpose. No key, no loadstring chain, no obfuscation.
	Toggle panel with RIGHT SHIFT. Panic with DELETE.

	Notes that matter:
	  - Hypershot fills lobbies with bots that carry real-looking names. Anything that is not
	    in Players:GetPlayers() is tagged [BOT]; real players are tagged [P].
	  - Health is 200 by default, so the health bar is normalised against Humanoid.MaxHealth.
	  - Spawn protection is detected from attributes/tags whose name mentions spawn/immune/
	    protect, plus the game's own "SpawnProtection" style tags when they exist.
	  - Hitbox expander is client-side. Hypershot validates hits on the server for most
	    weapons, so treat it as an aid, not a guarantee.
]]

if getgenv().NYX_HYPERSHOT then
	pcall(function()
		getgenv().NYX_HYPERSHOT.panic()
	end)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

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
		weapon = false,
		tracer = false,
		headDot = false,
		chams = false,
		bots = true,
		teamCheck = true,
		maxDistance = 3000,
	},

	aim = {
		enabled = false,
		key = Enum.UserInputType.MouseButton2,
		fov = 90,
		smoothing = 0.35, -- 0 = instant snap, 1 = sluggish
		part = "Head",    -- "Head" | "Torso" | "Nearest"
		visibleOnly = true,
		sticky = true,
		mode = "Camera",  -- "Camera" | "Mouse"
	},

	trigger = {
		enabled = false,
		fovPixels = 14,
		delay = 0.05,
		visibleOnly = true,
	},

	hitbox = {
		enabled = false,
		scale = 1.8,
	},

	walkSpeed = 32,
	exitWalkSpeed = 16,
}

local COL = {
	box = Color3.fromRGB(255, 255, 255),
	bot = Color3.fromRGB(255, 128, 64),
	team = Color3.fromRGB(80, 200, 255),
	name = Color3.fromRGB(235, 235, 235),
	health = Color3.fromRGB(90, 220, 120),
	distance = Color3.fromRGB(200, 200, 200),
	chams = Color3.fromRGB(255, 60, 90),
	fov = Color3.fromRGB(255, 255, 255),
}

-- ============================================================================
-- state
-- ============================================================================

local STATE = {
	targets = {},       -- server-side actor models
	targetSet = {},     -- same actors, keyed for O(1) lookups
	drawing = {},       -- [actor] = { Square, Text, Line, Circle }
	chams = {},         -- [actor] = Highlight
	hitboxSizes = {},   -- [part] = original Size
	held = false,
	stickActor = nil,
	stickUntil = 0,
	lastTrigger = 0,
	lastHitboxSweep = 0,
	serial = 0,         -- re-entrancy guard for the refresh loop
}

local function note(text)
	pcall(function()
		print("[nyx-hypershot] " .. text)
	end)
end

local function alive(actor)
	local hum = actor and actor:FindFirstChildOfClass("Humanoid")
	if not hum then
		return false
	end
	if hum.Health <= 0 then
		return false
	end
	if actor.Parent == nil then
		return false
	end
	return true
end

local function root(actor)
	return actor and (actor:FindFirstChild("HumanoidRootPart") or actor:FindFirstChild("UpperTorso") or actor:FindFirstChild("Head"))
end

local function isBot(actor)
	if actor:IsA("Player") then
		return false
	end
	local plr = Players:GetPlayerFromCharacter(actor)
	return plr == nil
end

local function sameTeam(actor)
	if not CFG.esp.teamCheck then
		return false
	end
	local mine = LocalPlayer.Team
	if not mine or mine == "" then
		return false
	end
	local theirs = nil
	local plr = Players:GetPlayerFromCharacter(actor)
	if plr then
		theirs = plr.Team
	elseif actor:IsA("Model") then
		local tag = actor:GetAttribute("Team") or actor:GetAttribute("team")
		theirs = tag
	end
	return theirs ~= nil and theirs == mine
end

local function protected(actor)
	local hum = actor:FindFirstChildOfClass("Humanoid")
	for _, container in ipairs({ actor, hum }) do
		if container then
			for name, value in pairs(container:GetAttributes()) do
				local key = string.lower(name)
				if (string.find(key, "spawn") or string.find(key, "immune") or string.find(key, "protect"))
					and value then
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
	local out, seen = {}, {}
	STATE.targets = out

	local function push(actor)
		if seen[actor] or actor == LocalPlayer.Character then
			return
		end
		if not alive(actor) or sameTeam(actor) then
			return
		end
		seen[actor] = true
		out[#out + 1] = actor
	end

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer and plr.Character then
			push(plr.Character)
		end
	end

	-- Bots live outside Players. Characters are parented to workspace or a folder in it.
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

	STATE.targetSet = seen
end

-- ============================================================================
-- drawing helpers
-- ============================================================================

local function drawable(class, props)
	local ok, obj = pcall(function()
		local d = Drawing.new(class)
		for key, value in pairs(props) do
			d[key] = value
		end
		return d
	end)
	if ok then
		return obj
	end
	return nil
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
		dot = drawable("Circle", { Thickness = 1.4, NumSides = 14, Radius = 3, Filled = false, Visible = false }),
	}
	STATE.drawing[actor] = entry
	return entry
end

local function hide(entry)
	for _, object in pairs(entry) do
		if object and object.Destroy then
			pcall(function()
				object.Visible = false
			end)
		end
	end
end

local function destroy(entry)
	for _, object in pairs(entry) do
		if object and object.Destroy then
			pcall(function()
				object:Destroy()
			end)
		end
	end
end

-- ============================================================================
-- projection
-- ============================================================================

local function project(position)
	if not camera then
		return nil
	end
	local point, onScreen = camera:WorldToViewportPoint(position)
	if not onScreen or point.Z <= 0 then
		return nil
	end
	return Vector2.new(point.X, point.Y), point.Z
end

local function rayClear(actor, worldPos)
	local origin = camera.CFrame.Position
	local direction = worldPos - origin
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { LocalPlayer.Character, actor }
	if camera then
		ignore[#ignore + 1] = camera
	end
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	local result = workspace:Raycast(origin, direction * 1.02, params)
	return result == nil
end

-- ============================================================================
-- esp
-- ============================================================================

local function renderESP()
	if not CFG.esp.enabled then
		for actor, entry in pairs(STATE.drawing) do
			hide(entry)
		end
		return
	end

	local aliveSet = {}
	local screenCenter = camera and camera.ViewportSize / 2 or Vector2.zero

	for _, actor in ipairs(STATE.targets) do
		local entry = layerFor(actor)
		aliveSet[actor] = true

		local head = actor:FindFirstChild("Head")
		local body = root(actor)
		local hum = actor:FindFirstChildOfClass("Humanoid")
		if not (head and body and hum) then
			hide(entry)
			continue
		end

		local origin = camera.CFrame.Position
		local distance = (body.Position - origin).Magnitude
		if distance > CFG.esp.maxDistance then
			hide(entry)
			continue
		end

		local top = head.Position + Vector3.new(0, 0.55, 0)
		local bottom = body.Position - Vector3.new(0, 2.5, 0)
		local side = body.Position + camera.CFrame.RightVector * 1.2

		local topScreen = project(top)
		local bottomScreen = project(bottom)
		local sideScreen = project(side)
		local middleScreen = project(body.Position)

		if not (topScreen and bottomScreen and sideScreen and middleScreen) then
			hide(entry)
			continue
		end

		local width = math.max(math.abs(sideScreen.X - middleScreen.X) * 2, 6)
		local height = math.abs(bottomScreen.Y - topScreen.Y)
		if height < 4 then
			hide(entry)
			continue
		end

		local actorIsBot = isBot(actor)
		if actorIsBot and not CFG.esp.bots then
			hide(entry)
			continue
		end

		local left = bottomScreen.X - width / 2
		local y = math.min(topScreen.Y, bottomScreen.Y)
		local color = actorIsBot and COL.bot or COL.box

		if CFG.esp.box and entry.box then
			entry.box.Visible = true
			entry.box.Color = color
			entry.box.Position = Vector2.new(left, y)
			entry.box.Size = Vector2.new(width, height)
		elseif entry.box then
			entry.box.Visible = false
		end

		if CFG.esp.health and entry.health then
			local ratio = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
			entry.health.Visible = true
			entry.health.Color = COL.health
			entry.health.Size = Vector2.new(2, height * ratio)
			entry.health.Position = Vector2.new(left - 6, y + (height - height * ratio))
		elseif entry.health then
			entry.health.Visible = false
		end

		if CFG.esp.name and entry.name then
			local label = actorIsBot and (actor.Name .. " [BOT]") or (actor.Name .. " [P]")
			local plr = Players:GetPlayerFromCharacter(actor)
			if plr then
				label = plr.DisplayName .. " [P]"
			end
			if protected(actor) then
				label = label .. "  (spawn)"
			end
			entry.name.Visible = true
			entry.name.Color = actorIsBot and COL.bot or COL.name
			entry.name.Text = label
			entry.name.Position = Vector2.new(bottomScreen.X, y - 17)
		elseif entry.name then
			entry.name.Visible = false
		end

		if CFG.esp.distance and entry.distance then
			local weapon = ""
			if CFG.esp.weapon then
				local tool = actor:FindFirstChildOfClass("Tool")
				if tool then
					weapon = " | " .. tool.Name
				end
			end
			entry.distance.Visible = true
			entry.distance.Color = COL.distance
			entry.distance.Text = string.format("%d studs%s", math.floor(distance), weapon)
			entry.distance.Position = Vector2.new(bottomScreen.X, y + height + 3)
		elseif entry.distance then
			entry.distance.Visible = false
		end

		if CFG.esp.tracer and entry.tracer then
			entry.tracer.Visible = true
			entry.tracer.Color = color
			entry.tracer.From = Vector2.new(screenCenter.X, camera.ViewportSize.Y)
			entry.tracer.To = Vector2.new(bottomScreen.X, y + height)
		elseif entry.tracer then
			entry.tracer.Visible = false
		end

		if CFG.esp.headDot and entry.dot then
			entry.dot.Visible = true
			entry.dot.Color = color
			entry.dot.Position = topScreen
		elseif entry.dot then
			entry.dot.Visible = false
		end
	end

	for actor, entry in pairs(STATE.drawing) do
		if not aliveSet[actor] then
			hide(entry)
		end
	end
end

-- ============================================================================
-- chams
-- ============================================================================

local function renderChams()
	local keep = {}
	for _, actor in ipairs(STATE.targets) do
		if CFG.esp.chams then
			keep[actor] = true
			local highlight = STATE.chams[actor]
			if not highlight or highlight.Parent ~= actor then
				local existing = actor:FindFirstChild("NYX_Chams")
				if existing then
					highlight = existing
				else
					highlight = Instance.new("Highlight")
					highlight.Name = "NYX_Chams"
					highlight.Parent = actor
				end
				highlight.FillColor = COL.chams
				highlight.FillTransparency = 0.55
				highlight.OutlineColor = COL.chams
				highlight.OutlineTransparency = 0
				highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
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
-- hitbox expander
-- ============================================================================

local function restoreHitboxes()
	for part, size in pairs(STATE.hitboxSizes) do
		pcall(function()
			part.Size = size
		end)
	end
	STATE.hitboxSizes = {}
end

local function renderHitboxes()
	if not CFG.hitbox.enabled then
		if next(STATE.hitboxSizes) then
			restoreHitboxes()
		end
		return
	end

	local now = os.clock()
	if now - STATE.lastHitboxSweep < 0.5 then
		return
	end
	STATE.lastHitboxSweep = now

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
-- aim
-- ============================================================================

local function aimPoint(actor)
	local head = actor:FindFirstChild("Head")
	local body = actor:FindFirstChild("HumanoidRootPart")

	if CFG.aim.part == "Head" and head then
		return head.Position
	end
	if CFG.aim.part == "Torso" and body then
		return body.Position
	end
	if head and body then
		local origin = camera.CFrame.Position
		return ((head.Position - origin).Magnitude < (body.Position - origin).Magnitude) and head.Position or body.Position
	end
	return head and head.Position or (body and body.Position)
end

local function pickTarget()
	if not camera then
		return nil
	end
	local viewport = camera.ViewportSize
	local center = viewport / 2
	local best, bestScore = nil, math.huge
	local fov = CFG.aim.fov

	-- sticky: hold the last target for a beat so the crosshair does not jitter between two bodies
	if CFG.aim.sticky and STATE.stickActor and os.clock() < STATE.stickUntil then
		local actor = STATE.stickActor
		if STATE.targetSet[actor] and not protected(actor) then
			local point = aimPoint(actor)
			local screen = point and project(point)
			if screen and (screen - center).Magnitude <= fov * 1.4 then
				if not CFG.aim.visibleOnly or rayClear(actor, point) then
					return point
				end
			end
		end
		STATE.stickActor = nil
	end

	for _, actor in ipairs(STATE.targets) do
		if not protected(actor) then
			local point = aimPoint(actor)
			if point then
				local screen = project(point)
				if screen then
					local offset = (screen - center).Magnitude
					if offset <= fov then
						if CFG.aim.visibleOnly and not rayClear(actor, point) then
							continue
						end
						if offset < bestScore then
							bestScore = offset
							best = point
							STATE.stickActor = actor
							STATE.stickUntil = os.clock() + 0.35
						end
					end
				end
			end
		end
	end
	return best
end

local function driveAim()
	if not CFG.aim.enabled or not STATE.held then
		return
	end
	local point = pickTarget()
	if not point then
		return
	end

	if CFG.aim.mode == "Mouse" then
		local screen = project(point)
		if not screen then
			return
		end
		local delta = screen - camera.ViewportSize / 2
		local factor = 1 - math.clamp(CFG.aim.smoothing, 0, 0.95)
		pcall(function()
			mousemoverel(delta.X * factor * 0.35, delta.Y * factor * 0.35)
		end)
		return
	end

	local goal = CFrame.lookAt(camera.CFrame.Position, point)
	local alpha = 1 - math.clamp(CFG.aim.smoothing, 0, 0.98)
	camera.CFrame = camera.CFrame:Lerp(goal, math.clamp(alpha, 0.02, 1))
end

-- camera priority so the game does not overwrite our rotation on the same frame
pcall(function()
	RunService:UnbindFromRenderStep("NYX_Aim")
end)
RunService:BindToRenderStep("NYX_Aim", Enum.RenderPriority.Camera.Value + 1, driveAim)

-- ============================================================================
-- triggerbot
-- ============================================================================

local function crosshairTarget()
	if not camera then
		return nil
	end
	local center = camera.ViewportSize / 2
	local best, bestScore = nil, CFG.trigger.fovPixels

	for _, actor in ipairs(STATE.targets) do
		if not protected(actor) then
			local point = aimPoint(actor)
			local screen = point and project(point)
			if screen then
				local offset = (screen - center).Magnitude
				if offset < bestScore then
					if not CFG.trigger.visibleOnly or rayClear(actor, point) then
						bestScore = offset
						best = point
					end
				end
			end
		end
	end
	return best
end

local function fire()
	local ok = pcall(function()
		mouse1press()
		task.wait(0.03)
		mouse1release()
	end)
	if not ok then
		local vim = game:GetService("VirtualInputManager")
		pcall(function()
			vim:SendMouseButtonEvent(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2, 0, true, game, 1)
			task.wait(0.03)
			vim:SendMouseButtonEvent(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2, 0, false, game, 1)
		end)
	end
end

local function pollTrigger()
	if not CFG.trigger.enabled then
		return
	end
	local now = os.clock()
	if now - STATE.lastTrigger < CFG.trigger.delay then
		return
	end
	if crosshairTarget() then
		STATE.lastTrigger = now
		fire()
	end
end

-- ============================================================================
-- movement
-- ============================================================================

local function applySpeed(value)
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = value
	end
end

-- ============================================================================
-- loop
-- ============================================================================

RunService.RenderStepped:Connect(function()
	local serial = STATE.serial + 1
	STATE.serial = serial
	if not camera then
		return
	end
	if serial % 2 == 0 then
		collect()
	end
	renderESP()
	renderChams()
	renderHitboxes()
end)

task.spawn(function()
	while true do
		local ok, err = pcall(pollTrigger)
		if not ok then
			note("trigger: " .. tostring(err))
		end
		task.wait(0.02)
	end
end)

-- ============================================================================
-- fov circle
-- ============================================================================

local fovCircle = drawable("Circle", { Thickness = 1.3, NumSides = 48, Filled = false, Visible = false })

RunService.RenderStepped:Connect(function()
	if not fovCircle then
		return
	end
	if CFG.aim.enabled and camera then
		fovCircle.Visible = true
		fovCircle.Position = camera.ViewportSize / 2
		fovCircle.Radius = CFG.aim.fov
		fovCircle.Color = COL.fov
	else
		fovCircle.Visible = false
	end
end)

-- ============================================================================
-- input
-- ============================================================================

UserInputService.InputBegan:Connect(function(input, processed)
	if input.UserInputType == CFG.aim.key then
		STATE.held = true
	elseif input.KeyCode == Enum.KeyCode.Delete then
		if getgenv().NYX_HYPERSHOT then
			getgenv().NYX_HYPERSHOT.panic()
		end
	elseif input.KeyCode == Enum.KeyCode.RightShift then
		if getgenv().NYX_HYPERSHOT and getgenv().NYX_HYPERSHOT.togglePanel then
			getgenv().NYX_HYPERSHOT.togglePanel()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == CFG.aim.key then
		STATE.held = false
	end
end)

-- ============================================================================
-- panel
-- ============================================================================

local function buildPanel()
	local gui = Instance.new("ScreenGui")
	gui.Name = "NYX_Hypershot"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 999
	gui.Parent = (function()
		local ok, core = pcall(function()
			return game:GetService("CoreGui")
		end)
		return ok and core or LocalPlayer:WaitForChild("PlayerGui")
	end)()

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(232, 396)
	frame.Position = UDim2.fromOffset(40, 120)
	frame.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 70, 84)
	stroke.Thickness = 1
	stroke.Parent = frame

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamMedium
	title.Text = "hypershot"
	title.TextColor3 = Color3.fromRGB(240, 240, 245)
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Position = UDim2.fromOffset(12, 0)
	title.Active = true
	title.Parent = frame

	local hint = Instance.new("TextLabel")
	hint.Size = UDim2.new(1, -24, 0, 14)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.Text = "rshift hide  ·  del panic"
	hint.TextColor3 = Color3.fromRGB(110, 110, 126)
	hint.TextSize = 11
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.Position = UDim2.fromOffset(12, 26)
	hint.Parent = frame

	local list = Instance.new("Frame")
	list.Size = UDim2.new(1, -20, 1, -60)
	list.Position = UDim2.fromOffset(10, 44)
	list.BackgroundTransparency = 1
	list.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 3)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	local function row(text, getter, setter)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(1, 0, 0, 22)
		button.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
		button.BackgroundTransparency = 0
		button.AutoButtonColor = true
		button.BorderSizePixel = 0
		button.Font = Enum.Font.Gotham
		button.TextSize = 12
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.Parent = list

		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 8)
		pad.Parent = button

		local function refresh()
			local on = getter()
			button.Text = (on and "● " or "○ ") .. text
			button.TextColor3 = on and Color3.fromRGB(120, 220, 160) or Color3.fromRGB(150, 150, 165)
		end

		button.MouseButton1Click:Connect(function()
			setter(not getter())
			refresh()
		end)
		refresh()
		return button
	end

	row("esp", function()
		return CFG.esp.enabled
	end, function(value)
		CFG.esp.enabled = value
	end)
	row("boxes", function()
		return CFG.esp.box
	end, function(value)
		CFG.esp.box = value
	end)
	row("names + bot tags", function()
		return CFG.esp.name
	end, function(value)
		CFG.esp.name = value
	end)
	row("health bars", function()
		return CFG.esp.health
	end, function(value)
		CFG.esp.health = value
	end)
	row("tracers", function()
		return CFG.esp.tracer
	end, function(value)
		CFG.esp.tracer = value
	end)
	row("chams", function()
		return CFG.esp.chams
	end, function(value)
		CFG.esp.chams = value
	end)
	row("aim assist (rmb)", function()
		return CFG.aim.enabled
	end, function(value)
		CFG.aim.enabled = value
	end)
	row("visible only", function()
		return CFG.aim.visibleOnly
	end, function(value)
		CFG.aim.visibleOnly = value
	end)
	row("triggerbot", function()
		return CFG.trigger.enabled
	end, function(value)
		CFG.trigger.enabled = value
	end)
	row("hitbox expander", function()
		return CFG.hitbox.enabled
	end, function(value)
		CFG.hitbox.enabled = value
	end)

	local fovRow = Instance.new("Frame")
	fovRow.Size = UDim2.new(1, 0, 0, 22)
	fovRow.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
	fovRow.BorderSizePixel = 0
	fovRow.Parent = list

	local fovLabel = Instance.new("TextLabel")
	fovLabel.Size = UDim2.new(1, -70, 1, 0)
	fovLabel.Position = UDim2.fromOffset(8, 0)
	fovLabel.BackgroundTransparency = 1
	fovLabel.Font = Enum.Font.Gotham
	fovLabel.TextSize = 12
	fovLabel.TextXAlignment = Enum.TextXAlignment.Left
	fovLabel.TextColor3 = Color3.fromRGB(150, 150, 165)
	fovLabel.Parent = fovRow

	local function fovText()
		fovLabel.Text = "fov  " .. math.floor(CFG.aim.fov)
	end
	fovText()

	local function stepper(label, offsetX, delta)
		local button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(22, 18)
		button.Position = UDim2.new(1, offsetX, 0.5, -9)
		button.BackgroundColor3 = Color3.fromRGB(38, 38, 48)
		button.BorderSizePixel = 0
		button.Font = Enum.Font.Gotham
		button.TextSize = 12
		button.TextColor3 = Color3.fromRGB(210, 210, 220)
		button.Text = label
		button.Parent = fovRow
		button.MouseButton1Click:Connect(function()
			CFG.aim.fov = math.clamp(CFG.aim.fov + delta, 10, 400)
			fovText()
		end)
	end

	stepper("-", -56, -10)
	stepper("+", -30, 10)

	-- drag
	local dragging, startPos, startInput = false, nil, nil
	title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			startPos = frame.Position
			startInput = input.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local delta = input.Position - startInput
			frame.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end)

	return gui, frame
end

local guiRoot, guiFrame = buildPanel()

local function panic()
	CFG.esp.enabled = false
	CFG.aim.enabled = false
	CFG.trigger.enabled = false
	CFG.hitbox.enabled = false
	restoreHitboxes()
	applySpeed(CFG.exitWalkSpeed)

	for actor, entry in pairs(STATE.drawing) do
		destroy(entry)
		STATE.drawing[actor] = nil
	end
	for actor, highlight in pairs(STATE.chams) do
		pcall(function()
			highlight:Destroy()
		end)
		STATE.chams[actor] = nil
	end
	pcall(function()
		if fovCircle then
			fovCircle:Destroy()
			fovCircle = nil
		end
	end)
	pcall(function()
		RunService:UnbindFromRenderStep("NYX_Aim")
	end)
	pcall(function()
		if guiRoot then
			guiRoot:Destroy()
		end
	end)
	getgenv().NYX_HYPERSHOT = nil
	note("panic — everything removed")
end

getgenv().NYX_HYPERSHOT = {
	config = CFG,
	panic = panic,
	togglePanel = function()
		if guiFrame then
			guiFrame.Visible = not guiFrame.Visible
		end
	end,
}

-- default speed nudge, off unless you ask for it
-- applySpeed(CFG.walkSpeed)

note("loaded — rshift panel, del panic")
