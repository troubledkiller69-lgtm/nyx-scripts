-- NYX Re:AOPG: client-side utilities, no guessed game remotes.
-- Target discovery depends on replicated Humanoid models and is not game-verified.
local env = getgenv()
if env.NYX_REAOPG then pcall(env.NYX_REAOPG.unload) end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Input = game:GetService("UserInputService")
local player = Players.LocalPlayer
if not player then error("NYX Re:AOPG requires a local player") end

local state = {
	alive = true, connections = {}, highlights = {}, targets = {},
	selected = nil, follow = false, autoAttack = false, playerESP = false,
	npcESP = false, rainbow = false, followDistance = 8, scanAt = 0,
	attackAt = 0, attackInterval = 0.3, visualAt = 0, moveAt = 0,
}
local ui
local function connect(signal, fn)
	local connection = signal:Connect(fn)
	state.connections[#state.connections + 1] = connection
	return connection
end
local function notify(text)
	if ui then pcall(function() ui:Notify({Title = "NYX Re:AOPG", Content = text, Duration = 4}) end) end
	print("[NYX Re:AOPG] " .. text)
end
local function root(model)
	return model and (model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart)
end
local function living(model)
	local hum = model and model:FindFirstChildOfClass("Humanoid")
	return model and model.Parent and hum and hum.Health > 0 and root(model)
end
local function scan()
	local found = {}
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("Model") and obj ~= player.Character and living(obj)
			and not Players:GetPlayerFromCharacter(obj) then
			found[#found + 1] = obj
		end
	end
	state.targets = found
	if state.selected and (not living(state.selected) or not table.find(found, state.selected)) then
		state.selected = nil
	end
end
local function nearest()
	local own = root(player.Character)
	if not own then return nil end
	local best, distance = nil, math.huge
	for _, model in ipairs(state.targets) do
		local part = living(model)
		if part then
			local d = (part.Position - own.Position).Magnitude
			if d < distance then best, distance = model, d end
		end
	end
	return best
end
local function unload()
	if not state.alive then return end
	state.alive = false
	for _, connection in ipairs(state.connections) do connection:Disconnect() end
	for _, highlight in pairs(state.highlights) do pcall(function() highlight:Destroy() end) end
	if ui then pcall(function() ui:Destroy() end) end
	if env.NYX_REAOPG and env.NYX_REAOPG.state == state then env.NYX_REAOPG = nil end
end
env.NYX_REAOPG = { state = state, unload = unload }

local function updateHighlights(now)
	local wanted = {}
	if state.playerESP then
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= player and other.Character and living(other.Character) then wanted[other.Character] = true end
		end
	end
	if state.npcESP then
		for _, model in ipairs(state.targets) do if living(model) then wanted[model] = true end end
	end
	local color = state.rainbow and Color3.fromHSV((now / 6) % 1, 1, 1) or Color3.fromRGB(205, 90, 255)
	for model in pairs(wanted) do
		local h = state.highlights[model]
		if not h or h.Parent ~= model then
			h = Instance.new("Highlight")
			h.Name = "NYX_ReAOPG_Highlight"
			h.Adornee = model
			h.FillTransparency = 0.65
			h.Parent = model
			state.highlights[model] = h
		end
		h.FillColor = color
		h.OutlineColor = color
	end
	for model, h in pairs(state.highlights) do
		if not wanted[model] then h:Destroy(); state.highlights[model] = nil end
	end
end

local ok, err = pcall(function()
	local source = game:HttpGet("https://raw.githubusercontent.com/SyncOfficialSpec/Rayfield_Gen_2_fanmade/refs/heads/main/source.lua")
	local chunk, compileError = loadstring(source)
	assert(chunk, compileError)
	ui = chunk()
	assert(ui and ui.CreateWindow, "Rayfield failed to load")
	if not state.alive then pcall(function() ui:Destroy() end); return end
	local window = ui:CreateWindow({Name = "NYX | Re:AOPG", Subtitle = "client utilities", KeySystem = false,
		ConfigurationSaving = {Enabled = false}})
	local farm = window:CreateTab("Target")
	local visual = window:CreateTab("Visuals")
	local info = window:CreateTab("Info")
	farm:CreateLabel("NPC discovery is generic; inspect targets before following.")
	farm:CreateButton({Name = "Refresh and select nearest NPC", Callback = function()
		scan(); state.selected = nearest()
		notify(state.selected and ("Selected: " .. state.selected:GetFullName()) or "No living NPC model found")
	end})
	farm:CreateInput({Name = "Select NPC by exact model name", PlaceholderText = "NPC name", RemoveTextAfterFocusLost = false,
		Callback = function(value)
			scan(); local own = root(player.Character); local best, distance = nil, math.huge
			for _, model in ipairs(state.targets) do
				local part = root(model)
				if own and part and string.lower(model.Name) == string.lower(value) then
					local d = (part.Position - own.Position).Magnitude
					if d < distance then best, distance = model, d end
				end
			end
			state.selected = best
			notify(best and ("Selected: " .. best:GetFullName()) or "No exact-name match")
		end})
	farm:CreateToggle({Name = "Follow selected NPC", CurrentValue = false, Flag = "follow", Callback = function(v) state.follow = v end})
	farm:CreateSlider({Name = "Follow distance", Range = {4, 30}, Increment = 1, CurrentValue = 8, Suffix = "studs",
		Flag = "distance", Callback = function(v) state.followDistance = v end})
	farm:CreateToggle({Name = "Activate equipped tool", CurrentValue = false, Flag = "attack", Callback = function(v) state.autoAttack = v end})
	farm:CreateSlider({Name = "Tool activation interval", Range = {1, 20}, Increment = 1, CurrentValue = 3, Suffix = "tenths sec",
		Flag = "interval", Callback = function(v) state.attackInterval = v / 10 end})
	visual:CreateToggle({Name = "Player highlights", CurrentValue = false, Flag = "players", Callback = function(v) state.playerESP = v end})
	visual:CreateToggle({Name = "NPC highlights", CurrentValue = false, Flag = "npcs", Callback = function(v) state.npcESP = v end})
	visual:CreateToggle({Name = "Rainbow highlights", CurrentValue = false, Flag = "rainbow", Callback = function(v) state.rainbow = v end})
	info:CreateLabel("No auto-quest or raid remotes: game interfaces not verified.")
	info:CreateButton({Name = "Unload menu", Callback = unload})
end)
if not ok then unload(); error("NYX Re:AOPG UI error: " .. tostring(err)) end
if not state.alive then return end

connect(Input.InputBegan, function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Delete and not Input:GetFocusedTextBox() then unload() end
end)
connect(RunService.Heartbeat, function()
	if not state.alive then return end
	local now = os.clock()
	if (state.follow or state.npcESP) and now >= state.scanAt then
		state.scanAt = now + 3
		scan()
	end
	if state.follow and state.selected and now >= state.moveAt then
		state.moveAt = now + 0.25
		local target, own = living(state.selected), root(player.Character)
		if target and own then
			local destination = target.Position - target.CFrame.LookVector * state.followDistance
			local hum = player.Character:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then hum:MoveTo(destination) end
		end
	end
	if state.autoAttack and now >= state.attackAt then
		state.attackAt = now + state.attackInterval
		local tool = player.Character and player.Character:FindFirstChildOfClass("Tool")
		if tool then pcall(function() tool:Activate() end) end
	end
	if now >= state.visualAt then state.visualAt = now + 0.1; updateHighlights(now) end
end)
notify("Loaded. Select an NPC first; all automation starts off. Delete unloads.")
