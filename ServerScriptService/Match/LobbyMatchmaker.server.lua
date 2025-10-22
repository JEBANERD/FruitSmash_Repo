--!strict
-- LobbyMatchmaker.server.lua
-- Coordinates lobby matchmaking by forming parties, queueing, and teleporting to reserved servers.

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)

local matchConfig = GameConfig.Get().Match or {}
local TELEPORT_ENABLED = matchConfig.UseTeleport ~= false
local MATCH_PLACE_ID = matchConfig.MatchPlaceId
local DEBUG_PRINT = matchConfig.DebugPrint ~= false

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
}

local partiesById: { [string]: Party } = {}
local partyByPlayer: { [Player]: Party } = {}
local partyQueue: { Party } = {}
local processingQueue = false

local function debugPrint(message: string, ...)
        if DEBUG_PRINT then
                print(string.format("[LobbyMatchmaker] " .. message, ...))
        end
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

local function sendPartyUpdate(party: Party, status: string)
        if not partyUpdateRemote then
                return
        end

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
                sendPartyUpdate(party, "update")
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
                else
                        local playersToTeleport = {}
                        for _, member in ipairs(party.members) do
                                if member.Parent == Players then
                                        table.insert(playersToTeleport, member)
                                end
                        end

                        if #playersToTeleport == 0 then
                                debugPrint("Party %s removed from queue (no active members)", party.id)
                                disbandParty(party)
                                table.remove(partyQueue, 1)
                        elseif not TELEPORT_ENABLED then
                                warn("[LobbyMatchmaker] Teleport requested while disabled")
                                break
                        elseif typeof(MATCH_PLACE_ID) ~= "number" or MATCH_PLACE_ID <= 0 then
                                warn("[LobbyMatchmaker] Invalid MatchPlaceId; cannot teleport")
                                sendNoticeToParty(party, "Match place is not configured. Please try again later.", "error")
                                disbandParty(party)
                                table.remove(partyQueue, 1)
                        else
                                local reserveOk, accessCodeOrErr = pcall(TeleportService.ReserveServer, TeleportService, MATCH_PLACE_ID)
                                if not reserveOk then
                                        warn(string.format("[LobbyMatchmaker] ReserveServer failed: %s", tostring(accessCodeOrErr)))
                                        sendNoticeToParty(party, "Unable to reserve a match server. Retrying shortly...", "warning")
                                        task.wait(2)
                                else
                                        local accessCode: string = accessCodeOrErr
                                        party.teleporting = true
                                        party.queued = false
                                        table.remove(partyQueue, 1)

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
                                                table.insert(partyQueue, 1, party)
                                                sendPartyUpdate(party, "queued")
                                                sendNoticeToParty(party, "Teleport failed. Re-queueing...", "warning")
                                                task.wait(2)
                                        else
                                                debugPrint("Teleport initiated for party %s (code %s)", party.id, accessCode)
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
        if not TELEPORT_ENABLED then
                return {
                        ok = false,
                        error = "TeleportDisabled",
                }
        end

        if typeof(MATCH_PLACE_ID) ~= "number" or MATCH_PLACE_ID <= 0 then
                return {
                        ok = false,
                        error = "MatchPlaceUnavailable",
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
