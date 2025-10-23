--!strict
-- LobbyMatchmaker.server.lua
-- Coordinates lobby matchmaking by forming parties, queueing, and teleporting to reserved servers.

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)

local matchConfig = GameConfig.Get().Match or {}
local TELEPORT_ENABLED = matchConfig.UseTeleport ~= false
local MATCH_PLACE_ID = matchConfig.MatchPlaceId
local DEBUG_PRINT = matchConfig.DebugPrint ~= false

local RETRY_MIN_SECONDS = math.max(1, matchConfig.TeleportRetryMinSeconds or 10)
local RETRY_MAX_SECONDS = math.max(RETRY_MIN_SECONDS, matchConfig.TeleportRetryMaxSeconds or 20)
local RETRY_JITTER_SECONDS = math.max(0, matchConfig.TeleportRetryJitterSeconds or 4)

local LOCAL_FALLBACK_ENABLED = (matchConfig.LocalFallback == true) or (not TELEPORT_ENABLED)
local LOCAL_FALLBACK_ON_FAILURE = matchConfig.LocalFallbackOnFailure
if LOCAL_FALLBACK_ON_FAILURE == nil then
        LOCAL_FALLBACK_ON_FAILURE = LOCAL_FALLBACK_ENABLED
else
        LOCAL_FALLBACK_ON_FAILURE = LOCAL_FALLBACK_ON_FAILURE == true
end

local retryRandom = Random.new()

local MAX_PARTY_SIZE = 4

local joinQueueRemote = Remotes and Remotes.RF_JoinQueue or nil
local leaveQueueRemote = Remotes and Remotes.RF_LeaveQueue or nil
local partyUpdateRemote = Remotes and Remotes.PartyUpdate or nil
local noticeRemote = Remotes and Remotes.RE_Notice or nil

type Party = {
        id: string,
        host: Player?,
        members: { Player },
        memberMap: { [Player]: boolean },
        queued: boolean,
        teleporting: boolean,
        retryCount: number,
        pendingRetry: boolean,
        retryToken: string?,
        lastStatus: string?,
        lastStatusKey: string?,
}

local partiesById: { [string]: Party } = {}
local partyByPlayer: { [Player]: Party } = {}
local partyQueue: { Party } = {}
local processingQueue = false

local localArenaServer: any = nil
local localRoundDirector: any = nil
local LOCAL_SUPPORT_READY = false

if LOCAL_FALLBACK_ENABLED then
        local gameServerFolder = ServerScriptService:FindFirstChild("GameServer")

        local function tryRequire(childName: string)
                if not gameServerFolder then
                        return nil
                end

                local module = gameServerFolder:FindFirstChild(childName)
                if not module or not module:IsA("ModuleScript") then
                        return nil
                end

                local ok, result = pcall(require, module)
                if not ok then
                        warn(string.format("[LobbyMatchmaker] Failed to require %s: %s", childName, tostring(result)))
                        return nil
                end

                return result
        end

        localArenaServer = tryRequire("ArenaServer")
        localRoundDirector = tryRequire("RoundDirectorServer")

        if localArenaServer and typeof(localArenaServer.SpawnArena) == "function" and typeof(localArenaServer.GetArenaState) == "function" then
                LOCAL_SUPPORT_READY = true
        else
                LOCAL_FALLBACK_ENABLED = false
                LOCAL_FALLBACK_ON_FAILURE = false
                localArenaServer = nil
                localRoundDirector = nil
        end
end

local LOCAL_MATCH_READY = LOCAL_SUPPORT_READY

local function debugPrint(message: string, ...)
        if DEBUG_PRINT then
                print(string.format("[LobbyMatchmaker] " .. message, ...))
        end
end

local function findLocalSpawnTarget(instance: Instance): Instance?
        local patterns = { "spawn", "start", "entry", "platform" }

        for _, descendant in ipairs(instance:GetDescendants()) do
                if descendant:IsA("BasePart") then
                        local lowerName = string.lower(descendant.Name)
                        for _, pattern in ipairs(patterns) do
                                if string.find(lowerName, pattern, 1, true) then
                                        return descendant
                                end
                        end

                        if descendant:GetAttribute("Spawn") or descendant:GetAttribute("PlayerSpawn") then
                                return descendant
                        end
                elseif descendant:IsA("Attachment") then
                        local lowerName = string.lower(descendant.Name)
                        for _, pattern in ipairs(patterns) do
                                if string.find(lowerName, pattern, 1, true) then
                                        return descendant
                                end
                        end
                end
        end

        local primary = instance:FindFirstChildWhichIsA("BasePart")
        if primary then
                return primary
        end

        return instance
end

local function computeLocalSpawnCFrame(arenaState: any): CFrame?
        if typeof(arenaState) ~= "table" then
                return nil
        end

        local instance = arenaState.instance
        if typeof(instance) ~= "Instance" then
                return nil
        end

        local target = findLocalSpawnTarget(instance)
        if not target then
                        return nil
        end

        if target:IsA("BasePart") then
                return target.CFrame
        elseif target:IsA("Attachment") then
                return target.WorldCFrame
        elseif typeof((target :: any).GetPivot) == "function" then
                local ok, pivot = pcall((target :: any).GetPivot, target)
                if ok then
                        return pivot
                end
        end

        if typeof((instance :: any).GetPivot) == "function" then
                local ok, pivot = pcall((instance :: any).GetPivot, instance)
                if ok then
                        return pivot
                end
        end

        return nil
end

local function registerArenaPlayerLocal(arenaState: any, player: Player)
        if typeof(arenaState) ~= "table" then
                return
        end

        local playersList = arenaState.players
        if typeof(playersList) ~= "table" then
                playersList = {}
                arenaState.players = playersList
        end

        for _, entry in ipairs(playersList) do
                local candidate = entry
                if typeof(entry) == "table" then
                        candidate = entry.player or entry.Player or entry.owner
                end

                if candidate == player then
                        return
                end
        end

        table.insert(playersList, player)
end

local function movePlayerToLocalArena(player: Player, spawnCFrame: CFrame?, slotIndex: number)
        if not spawnCFrame then
                return
        end

        local offsetRow = math.floor((slotIndex - 1) / 2)
        local offsetColumn = (slotIndex - 1) % 2
        local offset = CFrame.new((offsetColumn * 6) - 3, 3, offsetRow * 6)
        local targetCFrame = spawnCFrame * offset

        local function apply(character: Model)
                if typeof((character :: any).PivotTo) == "function" then
                        (character :: any):PivotTo(targetCFrame)
                        return
                end

                local root = character:FindFirstChild("HumanoidRootPart")
                if root and root:IsA("BasePart") then
                        root.CFrame = targetCFrame
                end
        end

        local character = player.Character
        if character and character:IsA("Model") then
                apply(character)
        end

        local connection: RBXScriptConnection? = nil
        connection = player.CharacterAdded:Connect(function(newCharacter)
                if newCharacter and newCharacter:IsA("Model") then
                        apply(newCharacter)
                end
                if connection then
                        connection:Disconnect()
                        connection = nil
                end
        end)

        task.delay(5, function()
                if connection then
                        connection:Disconnect()
                        connection = nil
                end
        end)
end

local function startLocalMatch(partyId: string, players: { Player }): boolean
        if not LOCAL_MATCH_READY or not localArenaServer then
                return false
        end

        local spawnArena = localArenaServer.SpawnArena
        local getArenaState = localArenaServer.GetArenaState

        if typeof(spawnArena) ~= "function" or typeof(getArenaState) ~= "function" then
                return false
        end

        local okReserve, arenaIdOrErr = pcall(spawnArena, partyId)
        if not okReserve then
                warn(string.format("[LobbyMatchmaker] Local fallback failed to spawn arena: %s", tostring(arenaIdOrErr)))
                return false
        end

        local arenaId = arenaIdOrErr
        if typeof(arenaId) ~= "string" then
                arenaId = tostring(arenaId)
        end

        if not arenaId or arenaId == "" then
                warn("[LobbyMatchmaker] Local fallback returned empty arena id")
                return false
        end

        local arenaState: any = nil
        local okState, stateResult = pcall(getArenaState, arenaId)
        if okState and typeof(stateResult) == "table" then
                arenaState = stateResult
        end

        local spawnCFrame = computeLocalSpawnCFrame(arenaState)

        for index, member in ipairs(players) do
                if member.Parent == Players then
                        registerArenaPlayerLocal(arenaState, member)
                        member:SetAttribute("PartyId", partyId)
                        member:SetAttribute("ArenaId", arenaId)
                        movePlayerToLocalArena(member, spawnCFrame, index)
                end
        end

        if localRoundDirector and typeof(localRoundDirector.Start) == "function" then
                        task.defer(function()
                                local okStart, startErr = pcall(localRoundDirector.Start, arenaId, nil)
                                if not okStart then
                                        warn(string.format("[LobbyMatchmaker] Local fallback RoundDirector.Start failed: %s", tostring(startErr)))
                                end
                        end)
        end

        return true
end

local function resetPartyRetry(party: Party)
        party.retryCount = 0
        party.pendingRetry = false
        party.retryToken = nil
end

local function cancelPartyRetry(party: Party)
        party.pendingRetry = false
        party.retryToken = nil
end

local function computeRetryDelay(attempt: number): number
        local base = RETRY_MIN_SECONDS * (2 ^ math.max(0, attempt - 1))
        local clamped = math.clamp(base, RETRY_MIN_SECONDS, RETRY_MAX_SECONDS)

        if RETRY_JITTER_SECONDS <= 0 then
                return clamped
        end

        local halfJitter = RETRY_JITTER_SECONDS * 0.5
        local low = math.max(RETRY_MIN_SECONDS, clamped - halfJitter)
        local high = math.min(RETRY_MAX_SECONDS, clamped + halfJitter)
        if high <= low then
                return low
        end

        local offset = retryRandom:NextNumber(0, high - low)
        return low + offset
end

local function sanitizeRetryReason(reason: string?): string
        if typeof(reason) ~= "string" then
                return "teleport error"
        end

        local trimmed = string.gsub(reason, "^%s+", "")
        trimmed = string.gsub(trimmed, "%s+$", "")
        if trimmed == "" then
                return "teleport error"
        end

        local lower = string.lower(trimmed)
        if string.find(lower, "teleportservice", 1, true) then
                return "teleport error"
        end
        if string.find(lower, "http", 1, true) then
                return "teleport error"
        end
        if string.find(lower, "error code", 1, true) then
                return "teleport error"
        end

        return trimmed
end

local function schedulePartyRetry(party: Party, reason: string, options: any?)
        local attempt = (party.retryCount or 0) + 1
        local delaySeconds = computeRetryDelay(attempt)
        party.retryCount = attempt
        party.pendingRetry = true
        party.retryToken = HttpService:GenerateGUID(false)
        party.queued = true

        local flooredDelay = math.max(1, math.floor(delaySeconds + 0.5))

        local friendlyReason = sanitizeRetryReason(reason)
        if typeof(options) == "table" then
                local customReason = options.reasonText
                if typeof(customReason) == "string" and customReason ~= "" then
                        friendlyReason = customReason
                end
        end

        local retryExtra = {
                attempt = attempt,
                retryDelaySeconds = delaySeconds,
                retryDelayRounded = flooredDelay,
                reason = friendlyReason,
        }
        sendPartyUpdate(party, "retrying", retryExtra)

        local sendNotice = true
        local noticeKind = "warning"
        local noticeMessage: string? = nil

        if typeof(options) == "table" then
                if options.sendNotice == false then
                        sendNotice = false
                end
                local customKind = options.noticeKind
                if typeof(customKind) == "string" and customKind ~= "" then
                        noticeKind = customKind
                end
                local rawMessage = options.noticeMessage
                if typeof(rawMessage) == "function" then
                        local ok, result = pcall(rawMessage, delaySeconds, attempt, friendlyReason)
                        if ok and typeof(result) == "string" then
                                noticeMessage = result
                        end
                elseif typeof(rawMessage) == "string" then
                        noticeMessage = rawMessage
                end
        end

        if sendNotice then
                if not noticeMessage or noticeMessage == "" then
                        noticeMessage = string.format("Matchmaking retry in %d seconds (%s).", flooredDelay, friendlyReason)
                end
                sendNoticeToParty(party, noticeMessage, noticeKind)
        end

        debugPrint("Party %s retrying in %.1f seconds (%s, attempt %d)", party.id, delaySeconds, friendlyReason, attempt)

        local retryToken = party.retryToken

        task.delay(delaySeconds, function()
                if partiesById[party.id] ~= party then
                        return
                end

                if party.retryToken ~= retryToken then
                        return
                end

                party.pendingRetry = false

                if party.teleporting then
                        return
                end

                local alreadyQueued = false
                for _, queuedParty in ipairs(partyQueue) do
                        if queuedParty == party then
                                alreadyQueued = true
                                break
                        end
                end

                if alreadyQueued then
                        return
                end

                table.insert(partyQueue, party)
                sendPartyUpdate(party, "queued")
                scheduleQueueProcessing()
        end)
end

local function releasePartyForMatch(party: Party)
        cancelPartyRetry(party)
        partiesById[party.id] = nil

        for _, member in ipairs(party.members) do
                if partyByPlayer[member] == party then
                        partyByPlayer[member] = nil
                end
        end

        table.clear(party.members)
        table.clear(party.memberMap)
        party.host = nil
        party.queued = false
        party.teleporting = true
        party.lastStatus = nil
        party.lastStatusKey = nil
end

local function getPlayerSummary(player: Player)
        return {
                userId = player.UserId,
                name = player.Name,
        }
end

local function sendNoticeToParty(party: Party, message: string, kind: string?)
        if not noticeRemote then
                return
        end
        for _, member in ipairs(party.members) do
                if member.Parent == Players then
                        noticeRemote:FireClient(member, {
                                msg = message,
                                kind = kind or "info",
                        })
                end
        end
end

local function computeStatusKey(status: string, extra: any?): string
        local parts = {}

        if typeof(status) == "string" then
                table.insert(parts, status)
        else
                table.insert(parts, tostring(status))
        end

        if typeof(extra) == "table" then
                local keys = {}
                for key in pairs(extra) do
                        table.insert(keys, key)
                end
                table.sort(keys, function(a, b)
                        return tostring(a) < tostring(b)
                end)

                for _, key in ipairs(keys) do
                        local value = extra[key]
                        local valueText
                        if typeof(value) == "table" then
                                local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
                                if ok then
                                        valueText = encoded
                                else
                                        valueText = tostring(value)
                                end
                        else
                                valueText = tostring(value)
                        end
                        table.insert(parts, string.format("%s=%s", tostring(key), valueText))
                end
        elseif extra ~= nil then
                table.insert(parts, tostring(extra))
        end

        return table.concat(parts, "|")
end

local function sendPartyUpdate(party: Party, status: string, extra: any?, force: boolean?)
        if not partyUpdateRemote then
                return
        end

        local statusKey = computeStatusKey(status, extra)
        if not force and party.lastStatusKey == statusKey then
                return
        end

        party.lastStatus = status
        party.lastStatusKey = statusKey

        local membersPayload = {}
        for _, member in ipairs(party.members) do
                table.insert(membersPayload, getPlayerSummary(member))
        end

        local payload = {
                partyId = party.id,
                hostUserId = party.host and party.host.UserId or nil,
                status = status,
                members = membersPayload,
        }

        if extra ~= nil then
                payload.extra = extra
        end

        for _, member in ipairs(party.members) do
                if member.Parent == Players then
                        partyUpdateRemote:FireClient(member, payload)
                end
        end
end

local function removePartyFromQueue(party: Party)
        for index = #partyQueue, 1, -1 do
                if partyQueue[index] == party then
                        table.remove(partyQueue, index)
                end
        end
        party.queued = false
end

local function disbandParty(party: Party, noticeMessage: string?)
        removePartyFromQueue(party)
        resetPartyRetry(party)
        partiesById[party.id] = nil

        if noticeMessage then
                sendNoticeToParty(party, noticeMessage, "info")
        end

        sendPartyUpdate(party, "disbanded")

        local members = table.clone(party.members)

        for _, member in ipairs(members) do
                if partyByPlayer[member] == party then
                        partyByPlayer[member] = nil
                end
                if member.Parent == Players then
                        member:SetAttribute("PartyId", nil)
                end
        end

        table.clear(party.members)
        table.clear(party.memberMap)
        party.host = nil
        party.teleporting = false
        party.lastStatus = nil
        party.lastStatusKey = nil
end

local function gatherMembers(host: Player, options: any?): { Player }
        local members: { Player } = { host }
        local seen: { [Player]: boolean } = {
                [host] = true,
        }

        if typeof(options) == "table" then
                local candidateLists = {}
                if typeof(options.members) == "table" then
                        table.insert(candidateLists, options.members)
                end
                if typeof(options.partyMembers) == "table" then
                        table.insert(candidateLists, options.partyMembers)
                end
                if typeof(options.memberUserIds) == "table" then
                        table.insert(candidateLists, options.memberUserIds)
                end

                for _, list in ipairs(candidateLists) do
                        for _, candidate in ipairs(list) do
                                if #members >= MAX_PARTY_SIZE then
                                        break
                                end
                                local candidatePlayer: Player? = nil
                                local kind = typeof(candidate)
                                if kind == "Instance" and candidate:IsA("Player") then
                                        candidatePlayer = candidate
                                elseif kind == "number" then
                                        candidatePlayer = Players:GetPlayerByUserId(candidate)
                                elseif kind == "string" then
                                        local numeric = tonumber(candidate)
                                        if numeric then
                                                candidatePlayer = Players:GetPlayerByUserId(numeric)
                                        end
                                end

                                if candidatePlayer and candidatePlayer.Parent == Players and not seen[candidatePlayer] then
                                        table.insert(members, candidatePlayer)
                                        seen[candidatePlayer] = true
                                end
                        end
                end
        end

        return members
end

local function createParty(host: Player, members: { Player }): Party
        local partyId = HttpService:GenerateGUID(false)
        local party: Party = {
                id = partyId,
                host = host,
                members = {},
                memberMap = {},
                queued = false,
                teleporting = false,
                retryCount = 0,
                pendingRetry = false,
                retryToken = nil,
                lastStatus = nil,
                lastStatusKey = nil,
        }

        partiesById[partyId] = party

        for _, member in ipairs(members) do
                table.insert(party.members, member)
                party.memberMap[member] = true
                partyByPlayer[member] = party
                member:SetAttribute("PartyId", partyId)
        end

        return party
end

local function buildMemberSummaries(party: Party)
        local summaries = {}
        for _, member in ipairs(party.members) do
                table.insert(summaries, getPlayerSummary(member))
        end
        return summaries
end

local function removePlayerFromParty(party: Party, player: Player, shouldDisbandIfEmpty: boolean, noticeMessage: string?)
        if not party.memberMap[player] then
                return
        end

        party.memberMap[player] = nil
        for index, member in ipairs(party.members) do
                if member == player then
                        table.remove(party.members, index)
                        break
                end
        end

        if partyByPlayer[player] == party then
                partyByPlayer[player] = nil
        end

        player:SetAttribute("PartyId", nil)

        if party.host == player then
                party.host = party.members[1]
        end

        if #party.members == 0 then
                disbandParty(party, noticeMessage)
                return
        end

        if shouldDisbandIfEmpty then
                sendPartyUpdate(party, "update", nil, true)
                if noticeMessage then
                        sendNoticeToParty(party, noticeMessage, "info")
                end
        end
end

local function processQueue()
	if processingQueue then
		return
	end

	processingQueue = true

	while #partyQueue > 0 do
		local party = partyQueue[1]

		if not party then
			table.remove(partyQueue, 1)
		elseif party.teleporting then
			table.remove(partyQueue, 1)
		elseif party.pendingRetry then
			table.remove(partyQueue, 1)
		else
			local playersToTeleport = {}
			for _, member in ipairs(party.members) do
				if member.Parent == Players then
					table.insert(playersToTeleport, member)
				end
			end

			if #playersToTeleport == 0 then
				table.remove(partyQueue, 1)
				debugPrint("Party %s removed from queue (no active members)", party.id)
				disbandParty(party)
			else
				table.remove(partyQueue, 1)

                                local matchPlaceValid = typeof(MATCH_PLACE_ID) == "number" and MATCH_PLACE_ID > 0
                                local teleportDisabled = not TELEPORT_ENABLED
                                local canTeleport = (not teleportDisabled) and matchPlaceValid
                                local fallbackReason = "teleport unavailable"
                                if teleportDisabled then
                                        fallbackReason = "teleport disabled"
                                elseif not matchPlaceValid then
                                        fallbackReason = "match place unavailable"
                                end

				local function runLocalFallback(reason: string): boolean
					if not LOCAL_MATCH_READY then
						return false
					end

					if reason ~= "" then
						debugPrint("Attempting local fallback for party %s (%s)", party.id, reason)
					else
						debugPrint("Attempting local fallback for party %s", party.id)
					end

					local success = startLocalMatch(party.id, playersToTeleport)
					if success then
						resetPartyRetry(party)
						sendPartyUpdate(party, "local")
						sendNoticeToParty(party, "Match server unavailable; running local arena in this server.", "info")
						debugPrint("Party %s started local fallback arena (%d members)", party.id, #playersToTeleport)
						releasePartyForMatch(party)
						return true
					end

					warn(string.format("[LobbyMatchmaker] Local fallback failed for party %s", party.id))
					return false
				end

				if not canTeleport then
					if runLocalFallback(fallbackReason) then
						-- handled via local fallback
					else
						if teleportDisabled then
							warn("[LobbyMatchmaker] Teleport requested while disabled and no fallback succeeded")
						else
							warn("[LobbyMatchmaker] Invalid MatchPlaceId; cannot teleport")
						end
						sendNoticeToParty(party, "Matchmaking temporarily unavailable. Please try again later.", "error")
						schedulePartyRetry(party, fallbackReason)
					end
				else
					local reserveOk, accessCodeOrErr = pcall(TeleportService.ReserveServer, TeleportService, MATCH_PLACE_ID)
					if not reserveOk then
						warn(string.format("[LobbyMatchmaker] ReserveServer failed: %s", tostring(accessCodeOrErr)))
						if LOCAL_FALLBACK_ON_FAILURE and runLocalFallback("reserve failure") then
							-- handled
						else
							schedulePartyRetry(party, "reserve failure")
						end
					else
						local accessCode: string = accessCodeOrErr
						party.teleporting = true
						party.queued = false
						cancelPartyRetry(party)

						sendPartyUpdate(party, "teleporting")
						debugPrint("Teleporting party %s with %d members", party.id, #playersToTeleport)

						local teleportDataMembers = {}
						for _, member in ipairs(playersToTeleport) do
							table.insert(teleportDataMembers, getPlayerSummary(member))
						end

						local teleportData = {
							partyId = party.id,
							members = teleportDataMembers,
						}

						local teleportOk, teleportErr = pcall(function()
							TeleportService:TeleportToPrivateServer(MATCH_PLACE_ID, accessCode, playersToTeleport, nil, teleportData)
						end)

						if not teleportOk then
                                                        warn(string.format("[LobbyMatchmaker] Teleport failed for party %s: %s", party.id, tostring(teleportErr)))
                                                        party.teleporting = false
                                                        party.queued = true
                                                        if LOCAL_FALLBACK_ON_FAILURE and runLocalFallback("teleport failure") then
                                                                -- handled
                                                        else
                                                                schedulePartyRetry(party, tostring(teleportErr), {
                                                                        noticeKind = "warning",
                                                                        reasonText = "teleport error",
                                                                        noticeMessage = function(delaySeconds)
                                                                                local seconds = math.max(1, math.floor(delaySeconds + 0.5))
                                                                                return string.format("Teleport failed. Retrying in %d seconds.", seconds)
                                                                        end,
                                                                })
                                                        end
                                                else
                                                        debugPrint("Teleport initiated for party %s (code %s)", party.id, accessCode)
                                                        resetPartyRetry(party)
                                                end
                                        end
				end
			end
		end
	end

	processingQueue = false
end

local function scheduleQueueProcessing()
        task.defer(processQueue)
end

local function handleJoinQueue(player: Player, options: any?)
        local canTeleport = TELEPORT_ENABLED and typeof(MATCH_PLACE_ID) == "number" and MATCH_PLACE_ID > 0

        if not canTeleport and not LOCAL_MATCH_READY then
                local errorCode = "MatchPlaceUnavailable"
                if not TELEPORT_ENABLED then
                        errorCode = "TeleportDisabled"
                end
                return {
                        ok = false,
                        error = errorCode,
                }
        end

        local members = gatherMembers(player, options)
        if #members == 0 then
                return {
                        ok = false,
                        error = "NoMembers",
                }
        end

        if #members > MAX_PARTY_SIZE then
                return {
                        ok = false,
                        error = "TooManyMembers",
                        maxSize = MAX_PARTY_SIZE,
                }
        end

        local existingParty = partyByPlayer[player]
        if existingParty then
                if existingParty.teleporting then
                        return {
                                ok = false,
                                error = "TeleportInProgress",
                                partyId = existingParty.id,
                        }
                end
                disbandParty(existingParty)
        end

        for _, member in ipairs(members) do
                local currentParty = partyByPlayer[member]
                if currentParty and currentParty ~= existingParty then
                        if currentParty.teleporting then
                                return {
                                        ok = false,
                                        error = "MemberTeleporting",
                                        userId = member.UserId,
                                }
                        end
                        disbandParty(currentParty, "A member joined a new party.")
                end
        end

        local party = createParty(player, members)
        party.queued = true
        table.insert(partyQueue, party)

        sendPartyUpdate(party, "queued")
        sendNoticeToParty(party, "Joined the matchmaking queue.", "info")
        debugPrint("Party %s queued (%d members)", party.id, #party.members)

        scheduleQueueProcessing()

        return {
                ok = true,
                partyId = party.id,
                members = buildMemberSummaries(party),
        }
end

local function handleLeaveQueue(player: Player)
        local party = partyByPlayer[player]
        if not party then
                return {
                        ok = false,
                        error = "NotInQueue",
                }
        end

        if party.teleporting then
                return {
                        ok = false,
                        error = "TeleportInProgress",
                        partyId = party.id,
                }
        end

        debugPrint("Party %s leaving queue (requested by %s)", party.id, player.Name)
        disbandParty(party, "Left the matchmaking queue.")

        return {
                ok = true,
        }
end

if joinQueueRemote then
        joinQueueRemote.OnServerInvoke = handleJoinQueue
else
        warn("[LobbyMatchmaker] RF_JoinQueue remote missing")
end

if leaveQueueRemote then
        leaveQueueRemote.OnServerInvoke = handleLeaveQueue
else
        warn("[LobbyMatchmaker] RF_LeaveQueue remote missing")
end

Players.PlayerRemoving:Connect(function(player)
        local party = partyByPlayer[player]
        if not party then
                return
        end

        if party.teleporting then
                removePlayerFromParty(party, player, false)
        else
                removePlayerFromParty(party, player, true, "A member left the party.")
        end
end)

if not TELEPORT_ENABLED then
        warn("[LobbyMatchmaker] Teleports are disabled via GameConfig.Match.UseTeleport")
elseif typeof(MATCH_PLACE_ID) ~= "number" or MATCH_PLACE_ID <= 0 then
        warn("[LobbyMatchmaker] GameConfig.Match.MatchPlaceId is invalid; queue will reject join attempts")
end

debugPrint("LobbyMatchmaker initialized")
