local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

local RemotesModule = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap")
local Remotes = require(RemotesModule)

local FruitConfigModule = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("FruitConfig")
local FruitConfig = require(FruitConfigModule)

local GameConfigModule = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig")
local GameConfig = typeof(GameConfigModule.Get) == "function" and GameConfigModule.Get() or GameConfigModule
local MeleeConfig = GameConfig.Melee or {}

local MAX_REACH = 10
local PLAYER_COOLDOWN = 0.12
local DEFAULT_MAX_DURABILITY = 100
local DEFAULT_BREAK_SECONDS = MeleeConfig.BreakDisableSeconds or 8
local RETURN_DURABILITY_PCT = math.clamp(MeleeConfig.ReturnDurabilityPct or 0.5, 0, 1)

local ECONOMY_RETRY_INTERVAL = 5

local HitValidationServer = {}

local playerStates = setmetatable({}, { __mode = "k" })
local meleeRemote = Remotes and Remotes.RE_MeleeHitAttempt or nil
local coinDeltaRemote = Remotes and Remotes.RE_CoinPointDelta or nil
local EconomyServer = nil
local lastEconomyAttempt = 0

local function currentTime()
        return os.clock()
end

do
        local initialEconomy = resolveEconomyModule()
        if initialEconomy then
                EconomyServer = initialEconomy
                lastEconomyAttempt = currentTime()
        end
end

local function safeSetAttribute(instance, attribute, value)
        if not instance or instance.Parent == nil then
                return
        end

        local ok, err = pcall(function()
                instance:SetAttribute(attribute, value)
        end)

        if not ok then
                warn(string.format("[HitValidationServer] Failed to set %s on %s: %s", tostring(attribute), tostring(instance), tostring(err)))
        end
end

local function getPlayerState(player)
        local state = playerStates[player]
        if not state then
                state = {
                        lastAttempt = -math.huge,
                        disabledUntil = nil,
                        breakToken = 0,
                }
                playerStates[player] = state
        end
        return state
end

local function resolveEconomyModule()
        local candidates = {
                { "Economy", "EconomyServer" },
                { "GameServer", "Economy", "EconomyServer" },
        }

        for _, pathParts in ipairs(candidates) do
                local current = ServerScriptService
                local found = true
                for _, name in ipairs(pathParts) do
                        if not current then
                                found = false
                                break
                        end
                        current = current:FindFirstChild(name)
                end

                if found and current and current:IsA("ModuleScript") then
                        local ok, result = pcall(require, current)
                        if ok and result then
                                return result
                        elseif not ok then
                                warn(string.format("[HitValidationServer] Failed to require %s: %s", current:GetFullName(), tostring(result)))
                        end
                end
        end

        return nil
end

local function getAttributeFromAncestors(instance, attribute, maxHops)
        maxHops = maxHops or 4
        local current = instance
        for _ = 1, maxHops do
                if not current then
                        break
                end
                local value = current:GetAttribute(attribute)
                if value ~= nil then
                        return value
                end
                current = current.Parent
        end
        return nil
end

local function valuesRoughlyEqual(a, b)
        if a == nil or b == nil then
                return true
        end
        if a == b then
                return true
        end

        local aNum = tonumber(a)
        local bNum = tonumber(b)
        if aNum and bNum then
                return aNum == bNum
        end

        return false
end

local function matchesPlayerArena(player, fruitPart)
        local fruitArena = getAttributeFromAncestors(fruitPart, "ArenaId")
        local playerArena = player:GetAttribute("ArenaId")
        if not valuesRoughlyEqual(fruitArena, playerArena) then
                return false
        end

        local fruitParty = getAttributeFromAncestors(fruitPart, "PartyId")
        local playerParty = player:GetAttribute("PartyId")
        if fruitParty ~= nil and playerParty ~= nil and fruitParty ~= playerParty then
                return false
        end

        return true
end

local function resolveFruitPart(candidate)
        if typeof(candidate) ~= "Instance" then
                return nil
        end

        if candidate:IsA("BasePart") then
                return candidate
        end

        if candidate:IsA("Model") then
                local primary = candidate.PrimaryPart
                if primary then
                        return primary
                end
                return candidate:FindFirstChildWhichIsA("BasePart")
        end

        if candidate:IsA("Attachment") then
                local parent = candidate.Parent
                while parent do
                        if parent:IsA("BasePart") then
                                return parent
                        end
                        parent = parent.Parent
                end
        end

        return nil
end

local function isFruitPart(part)
        if not part or not part:IsA("BasePart") then
                return false
        end
        if not part:IsDescendantOf(Workspace) then
                return false
        end

        if CollectionService:HasTag(part, "Fruit") then
                return true
        end

        local parent = part.Parent
        if parent and CollectionService:HasTag(parent, "Fruit") then
                return true
        end

        if part:GetAttribute("FruitId") ~= nil then
                return true
        end

        if parent and parent:GetAttribute("FruitId") ~= nil then
                return true
        end

        if part:GetAttribute("Damage") ~= nil or part:GetAttribute("Wear") ~= nil then
                return true
        end

        return false
end

local function hasLineOfSight(rootPart, fruitPart)
        if not rootPart or not fruitPart then
                return false
        end

        local origin = rootPart.Position
        local target = fruitPart.Position
        local direction = target - origin
        local magnitude = direction.Magnitude
        if magnitude <= 1e-3 then
                return true
        end

        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { rootPart.Parent }
        params.IgnoreWater = true

        local result = Workspace:Raycast(origin, direction, params)
        if not result then
                return true
        end

        local hitInstance = result.Instance
        if not hitInstance then
                return false
        end

        if hitInstance == fruitPart then
                return true
        end

        local fruitParent = fruitPart.Parent
        if fruitParent and hitInstance:IsDescendantOf(fruitParent) then
                return true
        end

        return false
end

local function resolveFruitStats(fruitPart, reportedId)
        local fruitId = getAttributeFromAncestors(fruitPart, "FruitId")
        if typeof(fruitId) ~= "string" or fruitId == "" then
                if typeof(reportedId) == "string" and reportedId ~= "" then
                        fruitId = reportedId
                else
                        fruitId = fruitPart.Name
                end
        end

        local stats = nil
        if fruitId and FruitConfig and typeof(FruitConfig.Get) == "function" then
                local ok, result = pcall(FruitConfig.Get, fruitId)
                if ok then
                        stats = result
                end
        end

        if not stats and FruitConfig and typeof(FruitConfig.All) == "function" then
                local ok, roster = pcall(FruitConfig.All)
                if ok and type(roster) == "table" then
                        stats = roster[fruitId]
                end
        end

        return stats, fruitId
end

local function resolveWearAmount(fruitPart, stats)
        local wear = getAttributeFromAncestors(fruitPart, "Wear")
        if typeof(wear) ~= "number" then
                wear = stats and stats.Wear or 0
        end
        if typeof(wear) ~= "number" then
                wear = 0
        end
        if wear < 0 then
                wear = 0
        end
        return wear
end

local function resolveRewardValues(fruitPart, stats)
        local coins = getAttributeFromAncestors(fruitPart, "Coins")
        if typeof(coins) ~= "number" then
                coins = stats and stats.Coins or 0
        end
        if typeof(coins) ~= "number" then
                coins = 0
        end

        local points = getAttributeFromAncestors(fruitPart, "Points")
        if typeof(points) ~= "number" then
                points = stats and stats.Points or 0
        end
        if typeof(points) ~= "number" then
                points = 0
        end

        return coins, points
end

local function markFruitConsumed(fruitPart)
        local consumed = fruitPart:GetAttribute("Consumed")
        if consumed == true then
                return false
        end

        local ok, err = pcall(function()
                fruitPart:SetAttribute("Consumed", true)
        end)

        if not ok then
                warn(string.format("[HitValidationServer] Failed to mark fruit consumed: %s", tostring(err)))
                return false
        end

        return true
end

local function destroyFruit(fruitPart)
        if not fruitPart then
                return
        end

        local parentModel = fruitPart.Parent
        fruitPart:Destroy()

        if parentModel and parentModel:IsA("Model") then
                if #parentModel:GetChildren() == 0 then
                        parentModel:Destroy()
                end
        end
end

local function manualAward(player, coins, points, metadata)
        if coins == 0 and points == 0 then
                return
        end

        if not player or not player.Parent then
                return
        end

        local currentCoins = tonumber(player:GetAttribute("Coins")) or 0
        local currentPoints = tonumber(player:GetAttribute("Points")) or 0

        local newCoins = currentCoins + coins
        local newPoints = currentPoints + points

        safeSetAttribute(player, "Coins", newCoins)
        safeSetAttribute(player, "Points", newPoints)

        if coinDeltaRemote then
                local payload = {
                        coins = coins,
                        points = points,
                        totalCoins = newCoins,
                        totalPoints = newPoints,
                        metadata = metadata or { reason = "Fruit" },
                }
                coinDeltaRemote:FireClient(player, payload)
        end
end

local function awardFruit(player, fruitPart, stats, fruitId)
        local coinsAwarded, pointsAwarded = 0, 0
        local metadata = { reason = "Fruit", fruitId = fruitId }

        if not EconomyServer then
                local now = currentTime()
                if now - lastEconomyAttempt >= ECONOMY_RETRY_INTERVAL then
                        lastEconomyAttempt = now
                        local module = resolveEconomyModule()
                        if module then
                                EconomyServer = module
                        end
                end
        end

        if EconomyServer and typeof(EconomyServer.AwardFruit) == "function" then
                local ok, coinsDelta, pointsDelta = pcall(EconomyServer.AwardFruit, player, fruitId)
                if ok then
                        coinsAwarded = tonumber(coinsDelta) or 0
                        pointsAwarded = tonumber(pointsDelta) or 0
                else
                        warn(string.format("[HitValidationServer] EconomyServer.AwardFruit failed: %s", tostring(coinsDelta)))
                        coinsAwarded, pointsAwarded = resolveRewardValues(fruitPart, stats)
                        manualAward(player, coinsAwarded, pointsAwarded, metadata)
                end
        else
                        coinsAwarded, pointsAwarded = resolveRewardValues(fruitPart, stats)
                        manualAward(player, coinsAwarded, pointsAwarded, metadata)
        end

        if (coinsAwarded ~= 0 or pointsAwarded ~= 0) and player and player.Parent then
                print(string.format("[HitValidationServer] %s awarded %+d coins / %+d points", player.Name, coinsAwarded, pointsAwarded))
        end

        return coinsAwarded, pointsAwarded
end

local function scheduleRestore(player, state, maxDurability)
        local disableSeconds = DEFAULT_BREAK_SECONDS
        if disableSeconds <= 0 then
                local restoreAmount = math.max(0, math.floor(maxDurability * RETURN_DURABILITY_PCT + 0.5))
                safeSetAttribute(player, "MeleeDurability", restoreAmount)
                safeSetAttribute(player, "MeleeDisabled", false)
                safeSetAttribute(player, "MeleeDisabledUntil", nil)
                state.disabledUntil = nil
                return
        end

        local resumeTime = currentTime() + disableSeconds
        state.disabledUntil = resumeTime
        state.breakToken = (state.breakToken or 0) + 1
        local token = state.breakToken

        safeSetAttribute(player, "MeleeDisabled", true)
        safeSetAttribute(player, "MeleeDisabledUntil", resumeTime)

        task.delay(disableSeconds, function()
                if not player or not player.Parent then
                        return
                end
                local latestState = getPlayerState(player)
                if latestState.breakToken ~= token then
                        return
                end

                local restoreAmount = math.max(0, math.floor(maxDurability * RETURN_DURABILITY_PCT + 0.5))
                safeSetAttribute(player, "MeleeDurability", restoreAmount)
                safeSetAttribute(player, "MeleeDisabled", false)
                safeSetAttribute(player, "MeleeDisabledUntil", nil)
                latestState.disabledUntil = nil
        end)
end

local function applyDurabilityWear(player, state, wearAmount)
        if wearAmount <= 0 then
                return
        end

        local maxDurability = tonumber(player:GetAttribute("MeleeMaxDurability"))
        if not maxDurability or maxDurability <= 0 then
                maxDurability = DEFAULT_MAX_DURABILITY
                safeSetAttribute(player, "MeleeMaxDurability", maxDurability)
        end

        local currentDurability = tonumber(player:GetAttribute("MeleeDurability"))
        if currentDurability == nil then
                currentDurability = maxDurability
                safeSetAttribute(player, "MeleeDurability", currentDurability)
        end

        local nextDurability = math.max(0, currentDurability - wearAmount)
        safeSetAttribute(player, "MeleeDurability", nextDurability)

        if nextDurability <= 0 then
                scheduleRestore(player, state, maxDurability)
        end
end

local function processValidHit(player, state, fruitPart, fruitId)
        if not markFruitConsumed(fruitPart) then
                return
        end

        local stats, resolvedId = resolveFruitStats(fruitPart, fruitId)
        local wearAmount = resolveWearAmount(fruitPart, stats)

        awardFruit(player, fruitPart, stats, resolvedId)
        destroyFruit(fruitPart)
        applyDurabilityWear(player, state, wearAmount)
end

local function onHitAttempt(player, payload)
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return
        end

        if typeof(payload) ~= "table" then
                return
        end

        if not player.Parent then
                return
        end

        local state = getPlayerState(player)
        local now = currentTime()

        if state.disabledUntil and now < state.disabledUntil then
                return
        end

        if now - state.lastAttempt < PLAYER_COOLDOWN then
                return
        end

        local disabledAttr = player:GetAttribute("MeleeDisabled")
        if disabledAttr == true then
                local untilAttr = player:GetAttribute("MeleeDisabledUntil")
                if typeof(untilAttr) == "number" and now < untilAttr then
                        state.disabledUntil = untilAttr
                        return
                elseif untilAttr == nil then
                        return
                end
        end

        local character = player.Character
        if not character then
                return
        end

        local rootPart = character:FindFirstChild("HumanoidRootPart")
        if not rootPart or not rootPart:IsA("BasePart") then
                return
        end

        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.Health <= 0 then
                return
        end

        local fruitCandidate = payload.fruit or payload[1]
        local fruitPart = resolveFruitPart(fruitCandidate)
        if not fruitPart or not isFruitPart(fruitPart) then
                return
        end

        if fruitPart:GetAttribute("Consumed") == true then
                return
        end

        if not matchesPlayerArena(player, fruitPart) then
                return
        end

        if not fruitPart:IsDescendantOf(Workspace) then
                return
        end

        local fruitPosition = fruitPart.Position
        local distance = (rootPart.Position - fruitPosition).Magnitude
        if distance > MAX_REACH then
                return
        end

        if not hasLineOfSight(rootPart, fruitPart) then
                return
        end

        state.lastAttempt = now

        local fruitId = payload.fruitId or payload.id
        processValidHit(player, state, fruitPart, fruitId)
end

function HitValidationServer.Init()
        if HitValidationServer._initialized then
                return true
        end

        if not meleeRemote then
                meleeRemote = Remotes and Remotes.RE_MeleeHitAttempt or nil
        end

        if not meleeRemote then
                warn("[HitValidationServer] RE_MeleeHitAttempt remote missing")
                return false
        end

        meleeRemote.OnServerEvent:Connect(onHitAttempt)
        HitValidationServer._initialized = true
        print("[HitValidationServer] Ready (reach=10, cooldown=0.12s)")
        return true
end

Players.PlayerRemoving:Connect(function(player)
        playerStates[player] = nil
end)

return HitValidationServer
