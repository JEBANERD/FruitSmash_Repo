local ShieldState = {}

local DEBUG_SHIELD = false

local function debugPrint(...)
    if DEBUG_SHIELD then
        print("[ShieldState]", ...)
    end
end

function ShieldState.Set(player: Instance?, on: boolean?)
    if not player then
        debugPrint("Set skipped: missing player instance")
        return
    end

    local success, err = pcall(function()
        player:SetAttribute("ShieldActive", on and true or false)
    end)

    if not success then
        warn("[ShieldState] Failed to set attribute for", player, err)
        return
    end

    debugPrint(string.format("Set %s → %s", player.Name, tostring(player:GetAttribute("ShieldActive"))))
end

function ShieldState.Get(player: Instance?)
    if not player then
        return false
    end
    return player:GetAttribute("ShieldActive") == true
end

return ShieldState
