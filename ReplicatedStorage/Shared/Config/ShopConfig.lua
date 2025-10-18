-- ShopConfig.lua
-- Day-one shop inventory: melee, consumable tokens, utility, cosmetics, economy/meta.

local Shop = {}

Shop.Items = {
    -- == Melee Weapons ==
    WoodenBat = {
        Id = "WoodenBat",
        Kind = "Melee",
        Name = "Wooden Bat",
        PriceCoins = 0,
        DamageBonus = 0,
        MaxDurability = 100,
        SwingRate = 1.0,
        Notes = "Starter weapon",
    },
    MetalBat = {
        Id = "MetalBat",
        Kind = "Melee",
        Name = "Metal Bat",
        PriceCoins = 450,
        DamageBonus = 15,
        MaxDurability = 150,
        SwingRate = 1.0,
    },
    Wrench = {
        Id = "Wrench",
        Kind = "Melee",
        Name = "Wrench",
        PriceCoins = 600,
        DamageBonus = 10,
        MaxDurability = 160,
        SwingRate = 0.9,
        PassiveAutoRepairPerSecond = 1, -- passive trickle repair
    },
    Katana = {
        Id = "Katana",
        Kind = "Melee",
        Name = "Katana",
        PriceCoins = 900,
        DamageBonus = 30,
        MaxDurability = 80,
        SwingRate = 1.3,
    },
    Hammer = {
        Id = "Hammer",
        Kind = "Melee",
        Name = "Hammer",
        PriceCoins = 1000,
        DamageBonus = 50,
        MaxDurability = 120,
        SwingRate = 0.8,
    },

    -- == Consumables (Tokens) ==
    Token_SpeedBoost = {
        Id = "Token_SpeedBoost",
        Kind = "Token",
        Name = "Speed Boost Token",
        PriceCoins = 150,
        Effect = "SpeedBoost",
        StackLimit = 3,
    },
    Token_DoubleCoins = {
        Id = "Token_DoubleCoins",
        Kind = "Token",
        Name = "Double Coins Token",
        PriceCoins = 175,
        Effect = "DoubleCoins",
        StackLimit = 2,
    },
    Token_Shield = {
        Id = "Token_Shield",
        Kind = "Token",
        Name = "Shield Token",
        PriceCoins = 200,
        Effect = "TargetShield",
        StackLimit = 2,
    },
    Token_BurstClear = {
        Id = "Token_BurstClear",
        Kind = "Token",
        Name = "Burst Clear Token",
        PriceCoins = 250,
        Effect = "BurstClear",
        StackLimit = 1,
    },

    -- == Utility ==
    RepairKit = {
        Id = "RepairKit",
        Kind = "Utility",
        Name = "Melee Repair Kit",
        PriceCoins = 100,
        RepairAmount = 100,
    },
    AutoRepairModule = {
        Id = "AutoRepairModule",
        Kind = "Utility",
        Name = "Auto-Repair Module",
        PriceCoins = 250,
        Effect = "AutoRepairMelee",
    },

    -- == Cosmetics (lobby-only) ==
    TrailColor = {
        Id = "TrailColor",
        Kind = "Cosmetic",
        Name = "Colored Trail",
        PriceCoins = 300,
    },
    EmotePack1 = {
        Id = "EmotePack1",
        Kind = "Cosmetic",
        Name = "Emote Pack 1",
        PriceCoins = 400,
    },

    -- == Economy / Meta ==
    RerollToken = {
        Id = "RerollToken",
        Kind = "Meta",
        Name = "Reroll Token",
        PriceCoins = 100,
    },
    ContinueToken = {
        Id = "ContinueToken",
        Kind = "Meta",
        Name = "Continue Token",
        PriceCoins = 200,
    },
}

-- Melee Gacha (per-level: max 3 spins, can whiff)
Shop.Gacha = {
    SpinsPerLevelCap = 3,
    Table = {
        -- weight-based outcomes
        { ItemId = "MetalBat",  Weight = 10 },
        { ItemId = "Wrench",    Weight = 8  },
        { ItemId = "Katana",    Weight = 6  },
        { ItemId = "Hammer",    Weight = 5  },
        { ItemId = "Nothing",   Weight = 20 }, -- whiff
    }
}

function Shop.All()
    return Shop.Items
end

function Shop.Get(id)
    return Shop.Items[id]
end

return Shop




