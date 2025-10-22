--!strict

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local TokenEffectsServer = {}

type EffectState = { [string]: any }
type PlayerState = { [string]: any }
type EffectPolicy = {
        refreshAllowed: boolean?,
        debounceSeconds: number?,
        stateKey: string?,
        displayName: string?,
        trackState: boolean?,
        isActive: ((EffectState) -> boolean)?,
}

local activeEffects: { [Player]: PlayerState } = setmetatable({}, { __mode = "k" })
local effectCooldowns: { [Player]: { [string]: number } } = setmetatable({}, { __mode = "k" })

local function safeRequire(instance: Instance?): any?
        if not instance then
                return nil
        end

        local ok, result = pcall(require, instance)
        if not ok then
                warn(string.format("[TokenEffects] Failed to require %s: %s", instance:GetFullName(), tostring(result)))
                return nil
        end

        return result
end

local telemetryTrack: ((string, { [string]: any }?) -> ())? = nil
do
        local analyticsFolder = ServerScriptService:FindFirstChild("Analytics")
        local telemetryModule = analyticsFolder and analyticsFolder:FindFirstChild("TelemetryServer")
        local telemetry = safeRequire(telemetryModule)
        if telemetry then
                local trackFn = (telemetry :: any).Track
                if typeof(trackFn) == "function" then
                        telemetryTrack = function(eventName: string, payload: { [string]: any }?)
                                local ok, err = pcall(trackFn, eventName, payload)
                                if not ok then
                                        warn(string.format("[TokenEffects] Telemetry.Track failed: %s", tostring(err)))
                                end
                        end
                end
        end
end

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")

local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = if typeof(GameConfigModule.Get) == "function" then GameConfigModule.Get() else GameConfigModule
local PowerUpsConfig = GameConfig.PowerUps or {}

local ShopConfigModule = require(configFolder:WaitForChild("ShopConfig"))
local ShopItems = if typeof(ShopConfigModule.All) == "function" then ShopConfigModule.All() else ShopConfigModule.Items or {}

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
local Remotes = safeRequire(remotesFolder and remotesFolder:FindFirstChild("RemoteBootstrap"))
local NoticeRemote: RemoteEvent? = if Remotes then Remotes.RE_Notice else nil

local function getCooldownMap(player: Player): { [string]: number }
        local map = effectCooldowns[player]
        if not map then
                map = {}
                effectCooldowns[player] = map
        end
        return map
end

local EFFECT_DISPLAY_NAMES = {
        SpeedBoost = "Speed boost",
        DoubleCoins = "Double coins",
        BurstClear = "Burst clear",
        TargetShield = "Target shield",
        TargetHealthBoost = "Target health boost",
        AutoRepairMelee = "Auto-repair",
}

local function getEffectDisplayName(effectName: string): string
        return EFFECT_DISPLAY_NAMES[effectName] or effectName
end

local function sendNotice(player: Player, message: string, kind: string)
        local remote = NoticeRemote
        if not remote then
                return
        end

        local ok, err = pcall(remote.FireClient, remote, player, {
                msg = message,
                kind = kind,
        })

        if not ok then
                warn(string.format("[TokenEffects] Failed to send notice: %s", tostring(err)))
        end
end

local function isEffectStateActive(effectName: string, effectState: any, policy: EffectPolicy?, now: number): boolean
        if effectState == nil then
                return false
        end

        if policy and policy.isActive then
                local ok, result = pcall(policy.isActive, effectState)
                if ok then
                        return result and true or false
                else
                        warn(string.format("[TokenEffects] isActive check failed for %s", effectName))
                end
        end

        if typeof(effectState) == "table" then
                local expiresAt = effectState.expiresAt
                if typeof(expiresAt) == "number" then
                        return expiresAt > now
                end
        end

        return true
end

local effectPolicies: { [string]: EffectPolicy } = {
        SpeedBoost = { refreshAllowed = true, debounceSeconds = 0.5 },
        DoubleCoins = { refreshAllowed = true, debounceSeconds = 0.5 },
        AutoRepairMelee = { refreshAllowed = true, debounceSeconds = 0.5 },
        TargetShield = { refreshAllowed = false, debounceSeconds = 0.5 },
        BurstClear = { refreshAllowed = false, debounceSeconds = 0.25, trackState = false },
        TargetHealthBoost = { refreshAllowed = false, debounceSeconds = 0.25, trackState = false },
}

local function notifyEffectError(player: Player, effectName: string, err: string)
        local displayName = getEffectDisplayName(effectName)

        if err == "Active" then
                sendNotice(player, string.format("%s already active.", displayName), "info")
        elseif err == "Cooldown" then
                sendNotice(player, string.format("%s is cooling down.", displayName), "info")
        elseif err == "Disabled" then
                sendNotice(player, string.format("%s is unavailable right now.", displayName), "warn")
        elseif err == "NoArena" then
                sendNotice(player, string.format("%s requires an active arena.", displayName), "warn")
        elseif err == "NoCharges" or err == "OutOfToken" then
                sendNotice(player, string.format("No charges left for %s.", displayName), "warn")
        else
                sendNotice(player, string.format("Cannot use %s (%s).", displayName, err), "warn")
        end
end

local function notifyEffectRefresh(player: Player, effectName: string)
        local displayName = getEffectDisplayName(effectName)
        sendNotice(player, string.format("%s refreshed.", displayName), "info")
end

local tokenEffectById: { [string]: string } = {}
for id, item in pairs(ShopItems) do
        if typeof(id) == "string" and typeof(item) == "table" then
                local kind = string.lower(item.Kind or "")
                if kind == "token" or kind == "utility" then
                        local effectName = item.Effect
                        if typeof(effectName) == "string" and effectName ~= "" then
                                tokenEffectById[id] = effectName
                        end
                end
        end
end

tokenEffectById["Token_TargetShield"] = tokenEffectById["Token_TargetShield"] or "TargetShield"
tokenEffectById["Token_SpeedBoost"] = tokenEffectById["Token_SpeedBoost"] or "SpeedBoost"
tokenEffectById["Token_DoubleCoins"] = tokenEffectById["Token_DoubleCoins"] or "DoubleCoins"
tokenEffectById["Token_BurstClear"] = tokenEffectById["Token_BurstClear"] or "BurstClear"
tokenEffectById["AutoRepairModule"] = tokenEffectById["AutoRepairModule"] or "AutoRepairMelee"

local gameServerFolder = ServerScriptService:WaitForChild("GameServer")

local shopModule = gameServerFolder:FindFirstChild("Shop")
local ShopServer = safeRequire(shopModule and shopModule:FindFirstChild("ShopServer"))

local economyFolder = gameServerFolder:FindFirstChild("Economy")
local EconomyServer = safeRequire(economyFolder and economyFolder:FindFirstChild("EconomyServer"))

local ProjectileServer = safeRequire(gameServerFolder:FindFirstChild("ProjectileServer"))
local ArenaAdapter = safeRequire(gameServerFolder:FindFirstChild("ArenaAdapter"))
local TargetHealthServer = safeRequire(gameServerFolder:FindFirstChild("TargetHealthServer"))

local function ensureState(player: Player): PlayerState
        local state = activeEffects[player]
        if not state then
                state = {}
                activeEffects[player] = state
        end
        return state
end

local function cleanupState(player: Player)
        local state = activeEffects[player]
        if not state then
                return
        end

        for _ in pairs(state) do
                return
        end

        activeEffects[player] = nil
end

local function setPlayerAttribute(player: Player, attribute: string, value: any)
        local ok, err = pcall(player.SetAttribute, player, attribute, value)
        if not ok then
                warn(string.format("[TokenEffects] Failed to set %s.%s: %s", player.Name, attribute, tostring(err)))
        end
end

local function destroyFruitInstance(part: BasePart)
        if not part or not part:IsDescendantOf(Workspace) then
                return
        end

        local parentModel = part.Parent

        if ProjectileServer and typeof(ProjectileServer.Untrack) == "function" then
                pcall(ProjectileServer.Untrack, part)
        end

        part:Destroy()

        if parentModel and parentModel:IsA("Model") and parentModel.Parent ~= nil then
                if #parentModel:GetChildren() == 0 then
                        parentModel:Destroy()
                end
        end
end

local function incrementDurability(player: Player, amount: number)
        if amount <= 0 then
                return
        end

        local currentAttr = player:GetAttribute("MeleeDurability")
        if typeof(currentAttr) ~= "number" then
                return
        end

        local maxAttr = player:GetAttribute("MeleeMaxDurability")
        local maxValue = if typeof(maxAttr) == "number" then maxAttr else currentAttr
        if maxValue <= 0 then
                return
        end

        local nextValue = math.clamp(currentAttr + amount, 0, maxValue)
        if math.abs(nextValue - currentAttr) < 1e-3 then
                return
        end

        setPlayerAttribute(player, "MeleeDurability", nextValue)
end

local function autoRepairLoop(player: Player, effectState: EffectState)
        local lastUpdate = os.clock()

        while true do
                if not player or player.Parent == nil then
                        break
                end

                local state = activeEffects[player]
                if state == nil or state.AutoRepairMelee ~= effectState then
                        break
                end

                local expiresAt = effectState.expiresAt
                if typeof(expiresAt) ~= "number" or os.clock() >= expiresAt then
                        break
                end

                local now = os.clock()
                local dt = math.max(0, now - lastUpdate)
                lastUpdate = now

                local rate = effectState.rate
                if typeof(rate) == "number" and rate > 0 and dt > 0 then
                        incrementDurability(player, rate * dt)
                end

                task.wait(0.25)
        end

        local state = activeEffects[player]
        if state and state.AutoRepairMelee == effectState then
                state.AutoRepairMelee = nil
                cleanupState(player)
        end
end

local function arenaExists(arenaId: any): boolean
        if arenaId == nil then
                return false
        end

        if ArenaAdapter and typeof(ArenaAdapter.GetState) == "function" then
                local ok, state = pcall(ArenaAdapter.GetState, arenaId)
                if ok and state ~= nil then
                        return true
                end
        end

        return true
end

local function applySpeedBoost(player: Player): (boolean, string?)
        local config = PowerUpsConfig.SpeedBoost or {}
        local duration = tonumber(config.DurationSeconds) or 0
        local multiplier = tonumber(config.SpeedMultiplier) or 1

        if duration <= 0 or multiplier <= 0 then
                return false, "Disabled"
        end

        local state = ensureState(player)
        local effectState = state.SpeedBoost

        if not effectState then
                effectState = {
                        previous = nil,
                        value = multiplier,
                }
                state.SpeedBoost = effectState
        end

        if effectState.previous == nil then
                local current = player:GetAttribute("SpeedBoostMultiplier")
                if typeof(current) == "number" then
                        effectState.previous = current
                end
        end

        effectState.value = multiplier
        effectState.expiresAt = os.clock() + duration

        local token = {}
        effectState.token = token

        setPlayerAttribute(player, "SpeedBoostMultiplier", multiplier)

        task.delay(duration, function()
                local currentState = activeEffects[player]
                local currentEffect = currentState and currentState.SpeedBoost
                if currentEffect ~= effectState or currentEffect.token ~= token then
                        return
                end

                local attr = player:GetAttribute("SpeedBoostMultiplier")
                if typeof(attr) == "number" and math.abs(attr - multiplier) < 1e-3 then
                        local restore = currentEffect.previous
                        if restore == nil then
                                setPlayerAttribute(player, "SpeedBoostMultiplier", nil)
                        else
                                setPlayerAttribute(player, "SpeedBoostMultiplier", restore)
                        end
                end

                currentState.SpeedBoost = nil
                cleanupState(player)
        end)

        return true, nil
end

local function applyDoubleCoins(player: Player): (boolean, string?)
        local config = PowerUpsConfig.DoubleCoins or {}
        local duration = tonumber(config.DurationSeconds) or 0
        local multiplier = 2

        if typeof(config.Multiplier) == "number" and config.Multiplier > 0 then
                multiplier = config.Multiplier
        end

        if duration <= 0 or multiplier <= 0 then
                return false, "Disabled"
        end

        local state = ensureState(player)
        local effectState = state.DoubleCoins

        if not effectState then
                effectState = {
                        previous = nil,
                        value = multiplier,
                }
                state.DoubleCoins = effectState
        end

        if effectState.previous == nil then
                local current = player:GetAttribute("CoinRewardMultiplier")
                if typeof(current) == "number" then
                        effectState.previous = current
                end
        end

        effectState.value = multiplier
        effectState.expiresAt = os.clock() + duration

        local token = {}
        effectState.token = token

        setPlayerAttribute(player, "CoinRewardMultiplier", multiplier)

        task.delay(duration, function()
                local currentState = activeEffects[player]
                local currentEffect = currentState and currentState.DoubleCoins
                if currentEffect ~= effectState or currentEffect.token ~= token then
                        return
                end

                local attr = player:GetAttribute("CoinRewardMultiplier")
                if typeof(attr) == "number" and math.abs(attr - multiplier) < 1e-3 then
                        local restore = currentEffect.previous
                        if restore == nil then
                                setPlayerAttribute(player, "CoinRewardMultiplier", nil)
                        else
                                setPlayerAttribute(player, "CoinRewardMultiplier", restore)
                        end
                end

                currentState.DoubleCoins = nil
                cleanupState(player)
        end)

        return true, nil
end

local function applyBurstClear(player: Player): (boolean, string?)
        local arenaId = player:GetAttribute("ArenaId")
        if arenaId == nil then
                return false, "NoArena"
        end

        if not arenaExists(arenaId) then
                return false, "NoArena"
        end

        local config = PowerUpsConfig.BurstClear or {}
        local grantWindow = tonumber(config.GrantCoinsForRecentlyHitWindow) or 0.3
        if grantWindow < 0 then
                grantWindow = 0
        end

        local now = os.clock()
        local fruits = CollectionService:GetTagged("Fruit")
        local cleared = 0

        for _, instance in ipairs(fruits) do
                if instance and instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) then
                        local fruitArena = instance:GetAttribute("ArenaId")
                        if fruitArena == arenaId then
                                local shouldGrant = false
                                local lastHit = instance:GetAttribute("LastHitTime")
                                if typeof(lastHit) == "number" and grantWindow > 0 then
                                        shouldGrant = (now - lastHit) <= grantWindow
                                end

                                if shouldGrant and EconomyServer and typeof(EconomyServer.AwardFruit) == "function" then
                                        local fruitId = instance:GetAttribute("FruitId")
                                        if typeof(fruitId) == "string" and fruitId ~= "" then
                                                pcall(EconomyServer.AwardFruit, player, fruitId)
                                        end
                                end

                                destroyFruitInstance(instance)
                                cleared += 1
                        end
                end
        end

        if cleared == 0 then
                return true, nil
        end

        return true, nil
end

local function applyTargetShield(player: Player): (boolean, string?)
        if not TargetHealthServer or typeof(TargetHealthServer.SetShield) ~= "function" then
                return false, "Unavailable"
        end

        local arenaId = player:GetAttribute("ArenaId")
        if arenaId == nil then
                return false, "NoArena"
        end

        if not arenaExists(arenaId) then
                return false, "NoArena"
        end

        local config = PowerUpsConfig.TargetShield or {}
        local duration = tonumber(config.DurationSeconds) or 0

        TargetHealthServer.SetShield(arenaId, true, duration > 0 and duration or nil)

        if duration > 0 then
                local state = ensureState(player)
                local effectState = {
                        arenaId = arenaId,
                        expiresAt = os.clock() + duration,
                        token = {},
                }
                state.TargetShield = effectState

                local token = effectState.token
                task.delay(duration, function()
                        local playerState = activeEffects[player]
                        local current = playerState and playerState.TargetShield
                        if current ~= effectState then
                                return
                        end

                        if current.token ~= token then
                                return
                        end

                        playerState.TargetShield = nil
                        cleanupState(player)
                end)
        end

        return true, nil
end

local function applyTargetHealthBoost(player: Player): (boolean, string?)
        if not TargetHealthServer or typeof(TargetHealthServer.ApplyHealthBoost) ~= "function" then
                return false, "Unavailable"
        end

        local arenaId = player:GetAttribute("ArenaId")
        if arenaId == nil then
                return false, "NoArena"
        end

        if not arenaExists(arenaId) then
                return false, "NoArena"
        end

        local config = PowerUpsConfig.TargetHealthBoost or {}
        local bonusPct = tonumber(config.MaxHPBonusPct) or 0
        local healPct = tonumber(config.HealCurrentPct) or 0

        if bonusPct <= 0 and healPct <= 0 then
                return false, "Disabled"
        end

        local ok, err = pcall(TargetHealthServer.ApplyHealthBoost, arenaId, bonusPct, healPct)
        if not ok then
                warn(string.format("[TokenEffects] TargetHealthBoost failed: %s", tostring(err)))
                return false, "ApplyFailed"
        end

        return true, nil
end

local function applyAutoRepair(player: Player): (boolean, string?)
        local config = PowerUpsConfig.AutoRepairMelee or {}
        local duration = tonumber(config.DurationSeconds) or 0
        local rate = tonumber(config.RepairPerSecond) or 0

        if duration <= 0 or rate <= 0 then
                return false, "Disabled"
        end

        local state = ensureState(player)
        local effectState = state.AutoRepairMelee

        if effectState then
                effectState.expiresAt = os.clock() + duration
                effectState.rate = rate
        else
                effectState = {
                        expiresAt = os.clock() + duration,
                        rate = rate,
                }
                state.AutoRepairMelee = effectState

                task.spawn(function()
                        autoRepairLoop(player, effectState)
                end)
        end

        return true, nil
end

local effectHandlers: { [string]: (player: Player) -> (boolean, string?) } = {
        SpeedBoost = applySpeedBoost,
        DoubleCoins = applyDoubleCoins,
        BurstClear = applyBurstClear,
        TargetShield = applyTargetShield,
        TargetHealthBoost = applyTargetHealthBoost,
        AutoRepairMelee = applyAutoRepair,
}

local function resolveEffectFromTokenId(tokenId: any): string?
        if typeof(tokenId) ~= "string" then
                return nil
        end

        return tokenEffectById[tokenId]
end

local function executeEffect(player: Player, effectName: string): (boolean, string?, boolean?)
        local handler = effectHandlers[effectName]
        if not handler then
                return false, "UnsupportedEffect", nil
        end

        local policy = effectPolicies[effectName]
        local trackState = not (policy and policy.trackState == false)
        local stateKey = if trackState then ((policy and policy.stateKey) or effectName) else nil

        local now = os.clock()
        local wasActive = false

        if stateKey ~= nil then
                local playerState = activeEffects[player]
                local effectState = playerState and playerState[stateKey]
                if effectState ~= nil then
                        wasActive = isEffectStateActive(effectName, effectState, policy, now)
                        if wasActive and not (policy and policy.refreshAllowed) then
                                return false, "Active", nil
                        end
                end
        end

        local debounceSeconds = if policy and typeof(policy.debounceSeconds) == "number" then math.max(0, policy.debounceSeconds) else 0
        local cooldownMap
        if debounceSeconds > 0 then
                cooldownMap = getCooldownMap(player)
                local readyAt = cooldownMap[effectName]
                if readyAt and readyAt > now and not wasActive then
                        return false, "Cooldown", nil
                end
                cooldownMap[effectName] = now + debounceSeconds
        end

        local ok, result, err = pcall(handler, player)
        if not ok then
                warn(string.format("[TokenEffects] Handler '%s' errored: %s", effectName, tostring(result)))
                if debounceSeconds > 0 and cooldownMap then
                        cooldownMap[effectName] = nil
                end
                return false, "HandlerError", nil
        end

        if result then
                if debounceSeconds > 0 and cooldownMap then
                        cooldownMap[effectName] = os.clock() + debounceSeconds
                end
                return true, nil, wasActive
        end

        if debounceSeconds > 0 and cooldownMap then
                cooldownMap[effectName] = nil
        end

        return false, err or "ApplyFailed", nil
end

function TokenEffectsServer.Use(player: Player, effectName: string?, slotIndex: number?)
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return { ok = false, err = "InvalidPlayer" }
        end

        if not ShopServer or typeof(ShopServer.GetProfileAndInventory) ~= "function" then
                return { ok = false, err = "ShopUnavailable" }
        end

        local profile, data, inventory = ShopServer.GetProfileAndInventory(player)
        if not profile or not data or not inventory then
                return { ok = false, err = "InventoryUnavailable" }
        end

        if slotIndex ~= nil then
                local numericSlot = math.floor(slotIndex)
                if numericSlot < 1 then
                        return { ok = false, err = "BadSlot" }
                end

                local buildQuickbar = ShopServer.BuildQuickbarState
                if typeof(buildQuickbar) ~= "function" then
                        return { ok = false, err = "QuickbarUnavailable" }
                end

                local quickbarState = buildQuickbar(data, inventory)
                local tokens = quickbarState and quickbarState.tokens

                if typeof(tokens) ~= "table" then
                        return { ok = false, err = "NoTokens" }
                end

                local entry = tokens[numericSlot]
                if typeof(entry) ~= "table" then
                        return { ok = false, err = "EmptySlot" }
                end

                local tokenId = entry.Id
                if typeof(tokenId) ~= "string" then
                        return { ok = false, err = "InvalidToken" }
                end

                local resolvedEffect = effectName
                if resolvedEffect == nil or resolvedEffect == "" then
                        resolvedEffect = resolveEffectFromTokenId(tokenId)
                end

                if typeof(resolvedEffect) ~= "string" or resolvedEffect == "" then
                        return { ok = false, err = "UnknownEffect" }
                end

                local countValue = entry.Count
                if typeof(countValue) ~= "number" or countValue <= 0 then
                        notifyEffectError(player, resolvedEffect, "NoCharges")
                        return { ok = false, err = "NoCharges" }
                end

                if typeof(effectName) == "string" and effectName ~= "" and effectName ~= resolvedEffect then
                        return { ok = false, err = "EffectMismatch" }
                end

                local ok, applyErr, refreshed = executeEffect(player, resolvedEffect)
                if not ok then
                        notifyEffectError(player, resolvedEffect, applyErr or "ApplyFailed")
                        return { ok = false, err = applyErr }
                end

                local counts = inventory.TokenCounts
                if typeof(counts) ~= "table" then
                        counts = {}
                        inventory.TokenCounts = counts
                end

                local currentCount = counts[tokenId]
                if typeof(currentCount) ~= "number" then
                        currentCount = countValue
                end

                local nextCount = math.max(0, math.floor(currentCount) - 1)
                counts[tokenId] = nextCount

                if typeof(ShopServer.MarkProfileDirty) == "function" then
                        ShopServer.MarkProfileDirty(player, profile)
                end

                if typeof(ShopServer.UpdateQuickbarForPlayer) == "function" then
                        ShopServer.UpdateQuickbarForPlayer(player, data, inventory)
                end

                if telemetryTrack then
                        local payload = {
                                player = player.Name,
                                userId = typeof(player.UserId) == "number" and player.UserId or nil,
                                tokenId = tokenId,
                                effect = resolvedEffect,
                                remaining = nextCount,
                                slot = numericSlot,
                        }

                        local arenaIdAttr = player:GetAttribute("ArenaId")
                        if arenaIdAttr ~= nil then
                                payload.arenaId = arenaIdAttr
                        end

                        local partyIdAttr = player:GetAttribute("PartyId")
                        if partyIdAttr ~= nil then
                                payload.partyId = partyIdAttr
                        end

                        if refreshed then
                                payload.refreshed = true
                        end

                        telemetryTrack("token_used", payload)
                end

                if refreshed then
                        notifyEffectRefresh(player, resolvedEffect)
                end

                return {
                        ok = true,
                        effect = resolvedEffect,
                        remaining = nextCount,
                        refreshed = if refreshed then true else nil,
                }
        end

        if typeof(effectName) ~= "string" or effectName == "" then
                return { ok = false, err = "NoEffect" }
        end

        local ok, applyErr, refreshed = executeEffect(player, effectName)
        if not ok then
                notifyEffectError(player, effectName, applyErr or "ApplyFailed")
                return { ok = false, err = applyErr }
        end

        if refreshed then
                notifyEffectRefresh(player, effectName)
        end

        return { ok = true, effect = effectName, refreshed = if refreshed then true else nil }
end

function TokenEffectsServer.ExpireAll(player: Player)
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return
        end

        local state = activeEffects[player]
        if not state then
                return
        end

        local speed = state.SpeedBoost
        if speed then
                local attr = player:GetAttribute("SpeedBoostMultiplier")
                if typeof(attr) == "number" and math.abs(attr - (speed.value or attr)) < 1e-3 then
                        local restore = speed.previous
                        if restore == nil then
                                setPlayerAttribute(player, "SpeedBoostMultiplier", nil)
                        else
                                setPlayerAttribute(player, "SpeedBoostMultiplier", restore)
                        end
                end
                state.SpeedBoost = nil
        end

        local coins = state.DoubleCoins
        if coins then
                local attr = player:GetAttribute("CoinRewardMultiplier")
                if typeof(attr) == "number" and math.abs(attr - (coins.value or attr)) < 1e-3 then
                        local restore = coins.previous
                        if restore == nil then
                                setPlayerAttribute(player, "CoinRewardMultiplier", nil)
                        else
                                setPlayerAttribute(player, "CoinRewardMultiplier", restore)
                        end
                end
                state.DoubleCoins = nil
        end

        if state.AutoRepairMelee then
                state.AutoRepairMelee = nil
        end

        if state.TargetShield then
                local shieldState = state.TargetShield
                local arenaId = shieldState and shieldState.arenaId
                if arenaId ~= nil and TargetHealthServer and typeof(TargetHealthServer.SetShield) == "function" then
                        pcall(TargetHealthServer.SetShield, arenaId, false)
                end
                state.TargetShield = nil
        end

        cleanupState(player)

        effectCooldowns[player] = nil
end

Players.PlayerRemoving:Connect(function(player: Player)
        TokenEffectsServer.ExpireAll(player)
end)

return TokenEffectsServer

