--!strict
-- RemoteBootstrap: ensures shared remotes exist (Events + Functions)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
remotesFolder.Name = "Remotes"
remotesFolder.Parent = ReplicatedStorage

local function getOrCreateEvent(name: string): RemoteEvent
        local r = remotesFolder:FindFirstChild(name)
        if r and not r:IsA("RemoteEvent") then
                warn(string.format("[RemoteBootstrap] Replacing %s '%s' with RemoteEvent", r.ClassName, name))
                r:Destroy()
                r = nil
        end
        if not r then
                r = Instance.new("RemoteEvent")
                r.Name = name
                r.Parent = remotesFolder
        end
        return r :: RemoteEvent
end

local function getOrCreateFunction(name: string): RemoteFunction
        local r = remotesFolder:FindFirstChild(name)
        if r and not r:IsA("RemoteFunction") then
                warn(string.format("[RemoteBootstrap] Replacing %s '%s' with RemoteFunction", r.ClassName, name))
                r:Destroy()
                r = nil
        end
        if not r then
                r = Instance.new("RemoteFunction")
                r.Name = name
                r.Parent = remotesFolder
        end
        return r :: RemoteFunction
end

type RemoteRefs = {
        GameStart: RemoteEvent,
        RE_PrepTimer: RemoteEvent,
        RE_WaveChanged: RemoteEvent,
        PartyUpdate: RemoteEvent,
        RE_RoundSummary: RemoteEvent,
        RE_MeleeHitAttempt: RemoteEvent,
        RE_TargetHP: RemoteEvent,
        RE_CoinPointDelta: RemoteEvent,
        RE_QuickbarUpdate: RemoteEvent,
        ShopOpen: RemoteEvent,
        PurchaseMade: RemoteEvent,
        PlayerKO: RemoteEvent,
        RE_Notice: RemoteEvent,
        WaveComplete: RemoteEvent,
        RE_SettingsPushed: RemoteEvent,
        RF_JoinQueue: RemoteFunction,
        RF_LeaveQueue: RemoteFunction,
        RF_UseToken: RemoteFunction,
        RF_SaveSettings: RemoteFunction,
}

local Remotes: RemoteRefs = {
        -- Match / flow
        GameStart           = getOrCreateEvent("GameStart"),
        RE_PrepTimer        = getOrCreateEvent("RE_PrepTimer"),
        RE_WaveChanged      = getOrCreateEvent("RE_WaveChanged"),
        PartyUpdate         = getOrCreateEvent("PartyUpdate"),
        RE_RoundSummary     = getOrCreateEvent("RE_RoundSummary"),

        -- Combat / state
        RE_MeleeHitAttempt  = getOrCreateEvent("RE_MeleeHitAttempt"),
	RE_TargetHP         = getOrCreateEvent("RE_TargetHP"),

	-- Economy / UI
	RE_CoinPointDelta   = getOrCreateEvent("RE_CoinPointDelta"),
	RE_QuickbarUpdate   = getOrCreateEvent("RE_QuickbarUpdate"),
	ShopOpen            = getOrCreateEvent("ShopOpen"),
	PurchaseMade        = getOrCreateEvent("PurchaseMade"),

        -- Player status / notices
        PlayerKO            = getOrCreateEvent("PlayerKO"),
        RE_Notice           = getOrCreateEvent("RE_Notice"),

        -- Misc progression
        WaveComplete        = getOrCreateEvent("WaveComplete"),

        -- Settings / accessibility
        RE_SettingsPushed   = getOrCreateEvent("RE_SettingsPushed"),

        -- Functions (client -> server request/response)
        RF_Purchase         = getOrCreateFunction("RF_Purchase"),
        RF_JoinQueue        = getOrCreateFunction("RF_JoinQueue"),
        RF_LeaveQueue       = getOrCreateFunction("RF_LeaveQueue"),
        RF_UseToken         = getOrCreateFunction("RF_UseToken"),
        RF_SaveSettings     = getOrCreateFunction("RF_SaveSettings"),
}

table.freeze(Remotes)

print("[RemoteBootstrap] RemoteEvents initialized")
return Remotes
