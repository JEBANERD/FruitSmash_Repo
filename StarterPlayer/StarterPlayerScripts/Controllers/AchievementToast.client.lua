--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
if not localPlayer then
    return
end

local playerGui: PlayerGui? = localPlayer:FindFirstChildOfClass("PlayerGui")
if not playerGui then
    local ok, result = pcall(function()
        return localPlayer:WaitForChild("PlayerGui", 5)
    end)
    if ok and result and result:IsA("PlayerGui") then
        playerGui = result
    end
end

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local remotesModule = remotesFolder:WaitForChild("RemoteBootstrap")
local Remotes = require(remotesModule)
local toastRemote: RemoteEvent? = Remotes and Remotes.RE_AchievementToast or nil

if not toastRemote then
    warn("[AchievementToastClient] RE_AchievementToast remote is unavailable; achievement toasts disabled")
    return
end

local DISPLAY_SECONDS = 3.5
local FADE_TIME = 0.25
local OFFSET_HIDDEN = 0.12
local OFFSET_VISIBLE = 0.16
local OFFSET_HIDE = 0.20

local screenGui: ScreenGui? = nil
local toastFrame: Frame? = nil
local titleLabel: TextLabel? = nil
local messageLabel: TextLabel? = nil
local borderStroke: UIStroke? = nil

local toastQueue: { { id: string, key: string, title: string, message: string } } = {}
local seenThisSession: { [string]: boolean } = {}
local showingToast = false

local function syncPlayerGui(newGui: PlayerGui?)
    playerGui = newGui
    if screenGui then
        screenGui.Parent = newGui
    end
end

local function ensureGui(): boolean
    local parent = playerGui or localPlayer:FindFirstChildOfClass("PlayerGui")
    if not parent then
        return false
    end

    if screenGui and screenGui.Parent ~= parent then
        screenGui.Parent = parent
    end

    if screenGui and toastFrame and titleLabel and messageLabel then
        return true
    end

    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "AchievementToasts"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.DisplayOrder = 10
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = parent

    toastFrame = Instance.new("Frame")
    toastFrame.Name = "Toast"
    toastFrame.AnchorPoint = Vector2.new(0.5, 0)
    toastFrame.Position = UDim2.new(0.5, 0, OFFSET_HIDDEN, 0)
    toastFrame.Size = UDim2.new(0, 360, 0, 96)
    toastFrame.BackgroundColor3 = Color3.fromRGB(28, 36, 62)
    toastFrame.BackgroundTransparency = 1
    toastFrame.Visible = false
    toastFrame.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = toastFrame

    borderStroke = Instance.new("UIStroke")
    borderStroke.Name = "Border"
    borderStroke.Thickness = 2
    borderStroke.Color = Color3.fromRGB(116, 140, 255)
    borderStroke.Transparency = 1
    borderStroke.Parent = toastFrame

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 18)
    padding.PaddingBottom = UDim.new(0, 18)
    padding.PaddingLeft = UDim.new(0, 20)
    padding.PaddingRight = UDim.new(0, 20)
    padding.Parent = toastFrame

    titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "Title"
    titleLabel.BackgroundTransparency = 1
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextColor3 = Color3.fromRGB(246, 246, 255)
    titleLabel.TextSize = 24
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Text = ""
    titleLabel.TextTransparency = 1
    titleLabel.Size = UDim2.new(1, 0, 0, 30)
    titleLabel.Parent = toastFrame

    messageLabel = Instance.new("TextLabel")
    messageLabel.Name = "Message"
    messageLabel.BackgroundTransparency = 1
    messageLabel.Font = Enum.Font.GothamSemibold
    messageLabel.TextColor3 = Color3.fromRGB(210, 214, 228)
    messageLabel.TextSize = 18
    messageLabel.TextWrapped = true
    messageLabel.TextXAlignment = Enum.TextXAlignment.Left
    messageLabel.TextYAlignment = Enum.TextYAlignment.Top
    messageLabel.Text = ""
    messageLabel.TextTransparency = 1
    messageLabel.Position = UDim2.new(0, 0, 0, 38)
    messageLabel.Size = UDim2.new(1, 0, 1, -42)
    messageLabel.Parent = toastFrame

    return true
end

local function sanitizePayload(rawPayload: any)
    if typeof(rawPayload) ~= "table" then
        return nil
    end

    local idValue = rawPayload.id or rawPayload.achievementId or rawPayload.key or rawPayload.ID
    if typeof(idValue) ~= "string" then
        return nil
    end

    local normalizedId = string.lower(idValue)
    local titleValue = rawPayload.title or rawPayload.name or rawPayload.label or idValue
    if typeof(titleValue) ~= "string" then
        titleValue = tostring(titleValue)
    end

    local messageValue = rawPayload.message or rawPayload.description or rawPayload.text
    if messageValue == nil then
        messageValue = ""
    elseif typeof(messageValue) ~= "string" then
        messageValue = tostring(messageValue)
    end

    return {
        id = idValue,
        key = normalizedId,
        title = titleValue,
        message = messageValue,
    }
end

local function playToast(payload: { id: string, key: string, title: string, message: string })
    if not ensureGui() or not toastFrame or not titleLabel or not messageLabel then
        showingToast = false
        return
    end

    toastFrame.Visible = true
    toastFrame.BackgroundTransparency = 1
    toastFrame.Position = UDim2.new(0.5, 0, OFFSET_HIDDEN, 0)
    titleLabel.TextTransparency = 1
    messageLabel.TextTransparency = 1

    titleLabel.Text = payload.title
    messageLabel.Text = payload.message

    if borderStroke then
        borderStroke.Transparency = 1
    end

    local fadeInInfo = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local fadeOutInfo = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

    local tweensIn = {
        TweenService:Create(toastFrame, fadeInInfo, {
            BackgroundTransparency = 0.08,
            Position = UDim2.new(0.5, 0, OFFSET_VISIBLE, 0),
        }),
        TweenService:Create(titleLabel, fadeInInfo, { TextTransparency = 0 }),
        TweenService:Create(messageLabel, fadeInInfo, { TextTransparency = 0 }),
    }

    if borderStroke then
        table.insert(tweensIn, TweenService:Create(borderStroke, fadeInInfo, { Transparency = 0.25 }))
    end

    for _, tween in ipairs(tweensIn) do
        tween:Play()
    end

    for _, tween in ipairs(tweensIn) do
        tween.Completed:Wait()
    end

    task.wait(DISPLAY_SECONDS)

    local tweensOut = {
        TweenService:Create(toastFrame, fadeOutInfo, {
            BackgroundTransparency = 1,
            Position = UDim2.new(0.5, 0, OFFSET_HIDE, 0),
        }),
        TweenService:Create(titleLabel, fadeOutInfo, { TextTransparency = 1 }),
        TweenService:Create(messageLabel, fadeOutInfo, { TextTransparency = 1 }),
    }

    if borderStroke then
        table.insert(tweensOut, TweenService:Create(borderStroke, fadeOutInfo, { Transparency = 1 }))
    end

    for _, tween in ipairs(tweensOut) do
        tween:Play()
    end

    for _, tween in ipairs(tweensOut) do
        tween.Completed:Wait()
    end

    toastFrame.Visible = false
    showingToast = false
    task.defer(processQueue)
end

local function processQueue()
    if showingToast then
        return
    end

    local nextPayload = table.remove(toastQueue, 1)
    if not nextPayload then
        return
    end

    showingToast = true
    task.spawn(function()
        playToast(nextPayload)
    end)
end

local function queueToast(payload: { id: string, key: string, title: string, message: string })
    table.insert(toastQueue, payload)
    processQueue()
end

local function handleToast(payload: any)
    local sanitized = sanitizePayload(payload)
    if not sanitized then
        return
    end

    if seenThisSession[sanitized.key] then
        return
    end

    seenThisSession[sanitized.key] = true
    queueToast(sanitized)
end

if playerGui then
    ensureGui()
end

localPlayer.ChildAdded:Connect(function(child)
    if child:IsA("PlayerGui") then
        syncPlayerGui(child)
        ensureGui()
    end
end)

localPlayer.ChildRemoved:Connect(function(child)
    if child:IsA("PlayerGui") then
        syncPlayerGui(localPlayer:FindFirstChildOfClass("PlayerGui"))
        ensureGui()
    end
end)

toastRemote.OnClientEvent:Connect(handleToast)
