--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LOCAL_PLAYER = Players.LocalPlayer
if not LOCAL_PLAYER then
        return
end

local function waitForChildOfClass(parent: Instance, childName: string, className: string?, timeout: number?)
        local child = parent:FindFirstChild(childName)
        if not child then
                local ok, result = pcall(parent.WaitForChild, parent, childName, timeout)
                if ok then
                        child = result
                end
        end
        if child and className and not child:IsA(className) then
                return nil
        end
        return child
end

local remotesFolder = waitForChildOfClass(ReplicatedStorage, "Remotes", "Folder", 5)
if not remotesFolder then
        return
end

local remote = waitForChildOfClass(remotesFolder, "RF_QAAdminCommand", "RemoteFunction", 5)
if not remote then
        return
end

local remoteFunction = remote :: RemoteFunction

local function invokeRemote(action: string, payload: {[string]: any}?)
        local body = payload and table.clone(payload) or {}
        body.action = action
        local ok, result = pcall(remoteFunction.InvokeServer, remoteFunction, body)
        if not ok then
                warn(string.format("[AdminPanel] Remote call failed (%s): %s", action, tostring(result)))
                return { ok = false, err = "RemoteError", message = tostring(result) }
        end
        return result
end

local initialResponse = invokeRemote("getstate")
if not initialResponse then
        return
end

if initialResponse.err == "NotAuthorized" and not RunService:IsStudio() then
        return
end

local currentState: {[string]: any} = {}
local currentArenaId: string? = nil

local function applyState(state: {[string]: any}?)
        if typeof(state) ~= "table" then
                return
        end
        currentState = state
        if typeof(state.arenaId) == "string" then
                currentArenaId = state.arenaId
        elseif typeof(state.arenaId) == "number" then
                currentArenaId = tostring(state.arenaId)
        end
end

if initialResponse.ok and typeof(initialResponse.state) == "table" then
        applyState(initialResponse.state)
end

local PlayerGui = LOCAL_PLAYER:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "QAAdminPanel"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Enabled = true
screenGui.Parent = PlayerGui

local panelFrame = Instance.new("Frame")
panelFrame.Name = "Panel"
panelFrame.Size = UDim2.fromOffset(280, 0)
panelFrame.AutomaticSize = Enum.AutomaticSize.Y
panelFrame.Position = UDim2.new(0, 20, 0, 60)
panelFrame.BackgroundTransparency = 0.1
panelFrame.BackgroundColor3 = Color3.fromRGB(22, 24, 32)
panelFrame.BorderSizePixel = 0
panelFrame.Visible = false
panelFrame.Parent = screenGui

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 10)
padding.PaddingBottom = UDim.new(0, 10)
padding.PaddingLeft = UDim.new(0, 12)
padding.PaddingRight = UDim.new(0, 12)
padding.Parent = panelFrame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
layout.VerticalAlignment = Enum.VerticalAlignment.Top
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = panelFrame

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = panelFrame

local stroke = Instance.new("UIStroke")
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.Thickness = 1
stroke.Color = Color3.fromRGB(90, 95, 120)
stroke.Parent = panelFrame

local function createLabel(text: string, textSize: number?, bold: boolean?): TextLabel
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.new(1, 0, 0, 0)
        label.AutomaticSize = Enum.AutomaticSize.Y
        label.Font = if bold then Enum.Font.GothamSemibold else Enum.Font.Gotham
        label.TextColor3 = Color3.fromRGB(235, 240, 255)
        label.TextSize = textSize or 16
        label.TextWrapped = true
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextYAlignment = Enum.TextYAlignment.Top
        label.Text = text
        label.LayoutOrder = 1
        label.Parent = panelFrame
        return label
end

local headerLabel = createLabel("QA Admin Panel", 20, true)
headerLabel.TextSize = 20

local statusLabel = createLabel("", nil, false)
statusLabel.TextColor3 = Color3.fromRGB(200, 210, 255)

local arenaLabel = createLabel("", nil, false)
arenaLabel.TextColor3 = Color3.fromRGB(160, 170, 220)

local messageLabel = createLabel("", nil, false)
messageLabel.TextColor3 = Color3.fromRGB(180, 255, 180)

local function createRow(): Frame
        local frame = Instance.new("Frame")
        frame.BackgroundTransparency = 1
        frame.Size = UDim2.new(1, 0, 0, 0)
        frame.AutomaticSize = Enum.AutomaticSize.Y
        frame.LayoutOrder = 10
        frame.Parent = panelFrame
        local rowLayout = Instance.new("UIListLayout")
        rowLayout.Padding = UDim.new(0, 6)
        rowLayout.FillDirection = Enum.FillDirection.Horizontal
        rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
        rowLayout.VerticalAlignment = Enum.VerticalAlignment.Top
        rowLayout.Parent = frame
        return frame
end

local function createTextButton(parent: Instance, text: string): TextButton
        local button = Instance.new("TextButton")
        button.AutoButtonColor = true
        button.BackgroundColor3 = Color3.fromRGB(52, 62, 92)
        button.Size = UDim2.new(0, 0, 0, 32)
        button.AutomaticSize = Enum.AutomaticSize.XY
        button.Font = Enum.Font.GothamSemibold
        button.TextSize = 15
        button.TextColor3 = Color3.fromRGB(240, 244, 255)
        button.Text = text
        button.Parent = parent
        local bCorner = Instance.new("UICorner")
        bCorner.CornerRadius = UDim.new(0, 6)
        bCorner.Parent = button
        return button
end

local function createTextBox(parent: Instance, placeholder: string, defaultText: string?): TextBox
        local box = Instance.new("TextBox")
        box.BackgroundColor3 = Color3.fromRGB(36, 42, 60)
        box.Size = UDim2.new(0, 90, 0, 32)
        box.Font = Enum.Font.Gotham
        box.TextSize = 15
        box.TextColor3 = Color3.fromRGB(235, 240, 255)
        box.PlaceholderColor3 = Color3.fromRGB(150, 160, 190)
        box.Text = defaultText or ""
        box.PlaceholderText = placeholder
        box.ClearTextOnFocus = false
        box.AutomaticSize = Enum.AutomaticSize.None
        box.Parent = parent
        local bCorner = Instance.new("UICorner")
        bCorner.CornerRadius = UDim.new(0, 6)
        bCorner.Parent = box
        return box
end

local function setMessage(text: string?, isError: boolean?)
        if not text or text == "" then
                messageLabel.Text = ""
                return
        end
        messageLabel.Text = text
        if isError then
                messageLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
        else
                messageLabel.TextColor3 = Color3.fromRGB(180, 255, 180)
        end
end

local function formatStateSummary(): string
        local pieces = {}
        local level = currentState.level
        if typeof(level) == "number" then
                table.insert(pieces, string.format("Level %d", level))
        end
        local wave = currentState.wave
        if typeof(wave) == "number" and wave > 0 then
                table.insert(pieces, string.format("Wave %d", wave))
        end
        local phase = currentState.phase
        if typeof(phase) == "string" and phase ~= "" then
                table.insert(pieces, phase)
        end
        local laneCount = currentState.laneCount
        if typeof(laneCount) == "number" and laneCount > 0 then
                table.insert(pieces, string.format("%d lanes", laneCount))
        end
        local prepRemaining = currentState.prepRemaining
        if typeof(prepRemaining) == "number" then
                table.insert(pieces, string.format("Prep %ds", prepRemaining))
        end
        if #pieces == 0 then
                return "No active arena"
        end
        return table.concat(pieces, " · ")
end

local function updateStatus()
        statusLabel.Text = formatStateSummary()
        if currentArenaId then
                arenaLabel.Text = string.format("Arena: %s", currentArenaId)
        else
                arenaLabel.Text = "Arena: (none)"
        end
end

updateStatus()

local function handleResponse(response: {[string]: any}?, opts: { silent: boolean }?)
        if typeof(response) ~= "table" then
                setMessage("No response", true)
                return
        end
        if response.ok and typeof(response.state) == "table" then
                applyState(response.state)
                updateStatus()
                updateButtonStates()
        end
        if opts and opts.silent then
                return
        end
        if response.ok then
                local msg = response.message
                if typeof(msg) ~= "string" or msg == "" then
                        msg = "Success"
                end
                setMessage(msg, false)
        else
                local err = response.message or response.err or "Request failed"
                if typeof(err) ~= "string" then
                        err = tostring(err)
                end
                setMessage(err, true)
        end
end

local skipRow = createRow()
local skipButton = createTextButton(skipRow, "Skip Prep")

local levelRow = createRow()
local levelBox = createTextBox(levelRow, "Level", if typeof(currentState.level) == "number" then tostring(currentState.level) else "")
local levelButton = createTextButton(levelRow, "Set Level")

local tokenRow = createRow()
local tokenBox = createTextBox(tokenRow, "Token ID", "Token_SpeedBoost")
local tokenButton = createTextButton(tokenRow, "Grant Token")

local obstacleRow = createRow()
local obstacleButton = createTextButton(obstacleRow, "Toggle Obstacles")

local turretRow = createRow()
local turretBox = createTextBox(turretRow, "Rate", if typeof(currentState.turretRate) == "number" then string.format("%.2f", currentState.turretRate) else "1.00")
local turretButton = createTextButton(turretRow, "Apply Rate")

local macrosLabel = createLabel("Regression Macros", 18, true)
macrosLabel.LayoutOrder = 30

local macroRow1 = createRow()
local macroSkipPrepButton = createTextButton(macroRow1, "Macro: Skip Prep")
local macroSetLevelButton = createTextButton(macroRow1, "Macro: Set Level")

local macroRow2 = createRow()
local macroGrantTokensButton = createTextButton(macroRow2, "Macro: Grant Tokens")
local macroAddCoinsButton = createTextButton(macroRow2, "Macro: Add Coins")

local macroRow3 = createRow()
local macroStressSpawnButton = createTextButton(macroRow3, "Macro: Stress Spawn")
local macroClearFruitButton = createTextButton(macroRow3, "Macro: Clear Fruit")

local function refreshState(silent: boolean?)
        local payload = {}
        if currentArenaId then
                payload.arenaId = currentArenaId
        end
        local response = invokeRemote("getstate", payload)
        handleResponse(response, { silent = silent == true })
end

local function toggleObstacles()
        local disabled = currentState.obstaclesDisabled == true
        local response = invokeRemote("toggleobstacles", {
                arenaId = currentArenaId,
                disabled = not disabled,
        })
        handleResponse(response)
end

local function runMacro(macroId: string)
        local payload = { macro = macroId }
        if currentArenaId then
                payload.arenaId = currentArenaId
        end
        local response = invokeRemote("macro", payload)
        handleResponse(response)
end

local function updateButtonStates()
        local disabled = currentState.obstaclesDisabled == true
        obstacleButton.Text = if disabled then "Enable Obstacles" else "Disable Obstacles"
        if typeof(currentState.turretRate) == "number" then
                turretBox.Text = string.format("%.2f", currentState.turretRate)
        end
        if typeof(currentState.level) == "number" then
                levelBox.PlaceholderText = tostring(currentState.level)
        end
end

updateButtonStates()

skipButton.MouseButton1Click:Connect(function()
        local response = invokeRemote("skipprep", { arenaId = currentArenaId })
        handleResponse(response)
end)

levelButton.MouseButton1Click:Connect(function()
        local text = levelBox.Text ~= "" and levelBox.Text or levelBox.PlaceholderText
        local numeric = tonumber(text)
        if not numeric then
                setMessage("Enter a valid level", true)
                return
        end
        local response = invokeRemote("setlevel", {
                arenaId = currentArenaId,
                level = numeric,
        })
        handleResponse(response)
        updateButtonStates()
end)

tokenButton.MouseButton1Click:Connect(function()
        local tokenId = tokenBox.Text ~= "" and tokenBox.Text or tokenBox.PlaceholderText
        if not tokenId or tokenId == "" then
                setMessage("Enter a token id", true)
                return
        end
        local response = invokeRemote("granttoken", {
                tokenId = tokenId,
                arenaId = currentArenaId,
        })
        handleResponse(response)
end)

obstacleButton.MouseButton1Click:Connect(function()
        toggleObstacles()
        updateButtonStates()
end)

turretButton.MouseButton1Click:Connect(function()
        local text = turretBox.Text ~= "" and turretBox.Text or turretBox.PlaceholderText
        local numeric = tonumber(text)
        if not numeric then
                setMessage("Enter a valid rate", true)
                return
        end
        local response = invokeRemote("setturretrate", {
                arenaId = currentArenaId,
                multiplier = numeric,
        })
        handleResponse(response)
        updateButtonStates()
end)

macroSkipPrepButton.MouseButton1Click:Connect(function()
        runMacro("skipprep")
end)

macroSetLevelButton.MouseButton1Click:Connect(function()
        runMacro("setlevel")
end)

macroGrantTokensButton.MouseButton1Click:Connect(function()
        runMacro("granttokens")
end)

macroAddCoinsButton.MouseButton1Click:Connect(function()
        runMacro("addcoins")
end)

macroStressSpawnButton.MouseButton1Click:Connect(function()
        runMacro("stressspawn")
end)

macroClearFruitButton.MouseButton1Click:Connect(function()
        runMacro("clearfruit")
end)

local PANEL_TOGGLE_KEY = Enum.KeyCode.F10
local panelVisible = false

local function setPanelVisible(visible: boolean)
        panelVisible = visible
        panelFrame.Visible = visible
        if visible then
                refreshState(true)
                updateButtonStates()
        end
end

UserInputService.InputBegan:Connect(function(input, processed)
        if processed then
                return
        end
        if input.KeyCode == PANEL_TOGGLE_KEY then
                setPanelVisible(not panelVisible)
        end
end)

if RunService:IsStudio() then
        setPanelVisible(true)
end

local function periodicRefresh()
        while panelFrame.Parent do
                if panelVisible then
                        refreshState(true)
                        updateButtonStates()
                end
                task.wait(5)
        end
end

task.spawn(periodicRefresh)

handleResponse(initialResponse, { silent = true })
updateButtonStates()
