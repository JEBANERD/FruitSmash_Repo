--!strict
-- Thin re-export so callers can require ServerScriptService.Shop.ShopServer
-- while the implementation lives under ServerScriptService.GameServer.Shop.

local ServerScriptService = game:GetService("ServerScriptService")
local gameServerFolder = ServerScriptService:WaitForChild("GameServer")
local shopFolder = gameServerFolder:WaitForChild("Shop")

return require(shopFolder:WaitForChild("ShopServer"))
