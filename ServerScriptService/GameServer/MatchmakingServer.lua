--!strict

local Players = game:GetService("Players")

local ArenaServer = require(game.ServerScriptService.GameServer.ArenaServer)

type Party = {
    Id: string,
    Host: Player?,
    Members: { Player },
    MemberMap: { [Player]: boolean },
}

type MatchmakingResult = (boolean, string?)

type MatchmakingServerModule = {
    CreateParty: (host: Player) -> (string?, string?),
    JoinParty: (player: Player, partyId: string) -> MatchmakingResult,
    StartIfReady: (partyId: string) -> MatchmakingResult,
}

local MatchmakingServer = {} :: MatchmakingServerModule

local MAX_PARTY_SIZE = 4
local nextPartyId = 1

local parties: { [string]: Party } = {}
local playerParties: { [Player]: string } = {}

local function getPartySize(party: Party): number
    return #party.Members
end

local function removeParty(partyId: string)
    local party = parties[partyId]
    if not party then
        return
    end

    for _, member in ipairs(party.Members) do
        playerParties[member] = nil
    end

    parties[partyId] = nil
    print(string.format("[Matchmaking] Party %s disbanded", partyId))
end

local function removePlayerFromParty(player: Player)
    local partyId = playerParties[player]
    if not partyId then
        return
    end

    local party = parties[partyId]
    playerParties[player] = nil

    if not party then
        return
    end

    for index, member in ipairs(party.Members) do
        if member == player then
            table.remove(party.Members, index)
            break
        end
    end

    party.MemberMap[player] = nil

    if party.Host == player then
        party.Host = party.Members[1]
        local newHost = party.Host
        if newHost then
            print(string.format("[Matchmaking] Party %s host is now %s", partyId, newHost.Name))
        end
    end

    if getPartySize(party) == 0 then
        removeParty(partyId)
    end
end

function MatchmakingServer.CreateParty(host: Player): (string?, string?)
    if not host then
        error("CreateParty called without a host")
    end

    if playerParties[host] then
        print(string.format("[Matchmaking] %s is already in a party (%s)", host.Name, playerParties[host]))
        return nil, "AlreadyInParty"
    end

    local partyId = tostring(nextPartyId)
    nextPartyId += 1

    local party: Party = {
        Id = partyId,
        Host = host,
        Members = { host },
        MemberMap = {
            [host] = true,
        },
    }

    parties[partyId] = party
    playerParties[host] = partyId

    print(string.format("[Matchmaking] Party %s created by %s", partyId, host.Name))

    return partyId, nil
end

function MatchmakingServer.JoinParty(player: Player, partyId: string): MatchmakingResult
    local party = parties[partyId]
    if not party then
        print(string.format("[Matchmaking] Party %s does not exist", tostring(partyId)))
        return false, "PartyNotFound"
    end

    local existingPartyId = playerParties[player]
    if existingPartyId then
        if existingPartyId == partyId then
            print(string.format("[Matchmaking] %s is already in party %s", player.Name, partyId))
            return false, "AlreadyInParty"
        end

        removePlayerFromParty(player)
    end

    if getPartySize(party) >= MAX_PARTY_SIZE then
        print(string.format("[Matchmaking] Party %s is full", partyId))
        return false, "PartyFull"
    end

    table.insert(party.Members, player)
    party.MemberMap[player] = true
    playerParties[player] = partyId

    print(string.format("[Matchmaking] %s joined party %s", player.Name, partyId))

    return true, nil
end

function MatchmakingServer.StartIfReady(partyId: string): MatchmakingResult
    local party = parties[partyId]
    if not party then
        print(string.format("[Matchmaking] Party %s does not exist", tostring(partyId)))
        return false, "PartyNotFound"
    end

    if getPartySize(party) == 0 then
        print(string.format("[Matchmaking] Party %s is empty", partyId))
        removeParty(partyId)
        return false, "PartyEmpty"
    end

    print(string.format("[Matchmaking] Party %s starting arena", partyId))
    (ArenaServer :: any).SpawnArena(partyId)

    return true, nil
end

Players.PlayerRemoving:Connect(removePlayerFromParty)

return MatchmakingServer
