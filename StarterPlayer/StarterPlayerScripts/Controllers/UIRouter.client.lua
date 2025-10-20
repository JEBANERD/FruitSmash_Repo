--!strict

--[[
    UIRouter
    --------
    Simple client-side state tracker for high level UI flows. The router listens to
    gameplay remotes and exposes a tiny API for other scripts to react to state
    transitions. This keeps UI modules loosely coupled while still sharing a
    canonical state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local ALLOWED_STATES: {[string]: boolean} = {
    Lobby = true,
    Prep = true,
    InWave = true,
    Intermission = true,
    GameOver = true,
}

local STATE_VISIBILITY: {[string]: boolean} = {
    Lobby = false,
    Prep = true,
    InWave = true,
    Intermission = true,
    GameOver = false,
}

local router = {}

local currentState = "Lobby"
local changedEvent = Instance.new("BindableEvent")
local localPlayer = Players.LocalPlayer
local playerGui: PlayerGui? = localPlayer:FindFirstChildOfClass("PlayerGui")
local guiConnections: {RBXScriptConnection} = {}

local HUD_NAME = "HUD"
local HUD_SECTION_NAME = "HUD_CoinsPoints"

local function disconnectGuiConnections()
    for _, connection in ipairs(guiConnections) do
        connection:Disconnect()
    end
    table.clear(guiConnections)
end

local function applyCoinsPointsVisibility(visible: boolean)
    local function applyTo(container: Instance?)
        if container == nil then
            return
        end

        local hud = container:FindFirstChild(HUD_NAME)
        if hud then
            local coinsPoints = hud:FindFirstChild(HUD_SECTION_NAME)
            if coinsPoints and coinsPoints:IsA("GuiObject") then
                coinsPoints.Visible = visible
            end
        end
    end

    applyTo(StarterGui)
    applyTo(playerGui)
end

local function refreshGuiObservers()
    disconnectGuiConnections()

    local function observe(container: Instance?)
        if container == nil then
            return
        end

        local connection = container.DescendantAdded:Connect(function(descendant)
            if descendant.Name == HUD_SECTION_NAME then
                task.defer(function()
                    applyCoinsPointsVisibility(STATE_VISIBILITY[currentState] ~= false)
                end)
            end
        end)
        table.insert(guiConnections, connection)
    end

    observe(StarterGui)
    observe(playerGui)
end

local function syncPlayerGui(newGui: PlayerGui?)
    playerGui = newGui
    refreshGuiObservers()
    task.defer(function()
        applyCoinsPointsVisibility(STATE_VISIBILITY[currentState] ~= false)
    end)
end

syncPlayerGui(playerGui)

localPlayer.ChildAdded:Connect(function(child)
    if child:IsA("PlayerGui") then
        syncPlayerGui(child)
    end
end)

localPlayer.ChildRemoved:Connect(function(child)
    if child:IsA("PlayerGui") then
        task.defer(function()
            syncPlayerGui(localPlayer:FindFirstChildOfClass("PlayerGui"))
        end)
    end
end)

local function applyStateSideEffects()
    local shouldShow = STATE_VISIBILITY[currentState] == true
    applyCoinsPointsVisibility(shouldShow)
    -- TODO: Bridge this state to world-space screens once WorldScreens are online.
end

function router.SetState(newState: string)
    if type(newState) ~= "string" then
        return
    end

    if not ALLOWED_STATES[newState] then
        warn(string.format("[UIRouter] Ignoring unknown state '%s'", newState))
        return
    end

    if currentState == newState then
        return
    end

    local previousState = currentState
    currentState = newState

    applyStateSideEffects()
    changedEvent:Fire(currentState, previousState)
end

function router.GetState(): string
    return currentState
end

function router.OnChanged(callback: (string, string) -> ()): RBXScriptConnection?
    if typeof(callback) ~= "function" then
        warn("[UIRouter] OnChanged expects a callback function")
        return nil
    end

    return changedEvent.Event:Connect(callback)
end

applyStateSideEffects()

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if remotesFolder then
    local prepRemote = remotesFolder:FindFirstChild("RE_PrepTimer")
    if prepRemote and prepRemote:IsA("RemoteEvent") then
        prepRemote.OnClientEvent:Connect(function(seconds)
            if typeof(seconds) == "number" then
                if seconds > 0 then
                    router.SetState("Prep")
                else
                    router.SetState("InWave")
                end
            else
                router.SetState("Prep")
            end
        end)
    end

    local waveRemote = remotesFolder:FindFirstChild("RE_WaveChanged")
    if waveRemote and waveRemote:IsA("RemoteEvent") then
        waveRemote.OnClientEvent:Connect(function(wave)
            if typeof(wave) == "number" and wave <= 0 then
                router.SetState("Intermission")
            else
                router.SetState("InWave")
            end
        end)
    end

    local noticeRemote = remotesFolder:FindFirstChild("RE_Notice")
    if noticeRemote and noticeRemote:IsA("RemoteEvent") then
        noticeRemote.OnClientEvent:Connect(function(payload)
            if typeof(payload) ~= "table" then
                return
            end

            local message = payload.msg
            local kind = payload.kind

            if typeof(kind) == "string" and string.lower(kind) == "error" then
                router.SetState("GameOver")
                return
            end

            if typeof(message) == "string" then
                local lowerMessage = string.lower(message)
                if string.find(lowerMessage, "game over", 1, true) then
                    router.SetState("GameOver")
                elseif string.find(lowerMessage, "intermission", 1, true) then
                    router.SetState("Intermission")
                elseif string.find(lowerMessage, "prep", 1, true) then
                    router.SetState("Prep")
                elseif string.find(lowerMessage, "lobby", 1, true) then
                    router.SetState("Lobby")
                end
            end
        end)
    end
end

return router
