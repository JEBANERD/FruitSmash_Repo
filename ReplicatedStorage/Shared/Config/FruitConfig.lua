-- FruitConfig.lua
-- Defines fruit roster: size, speed, damage to targets, durability wear, coins/points, pathing.

local Fruit = {}

-- Path tags: "straight", "zig", "arc", "wobble", "bundle"
-- Size tags: "XS","S","M","L","XL"

Fruit.Roster = {
    Apple = {
        Id = "Apple",
        Size = "S",
        Speed = 14,        -- studs/s
        Damage = 8,        -- to lane target on hit
        Wear   = 1,        -- melee durability wear on hit
        Coins  = 2,
        Points = 1,
        Path   = "straight",
        HPClass = "Light", -- for melee breakpoints if needed
    },
    Banana = {
        Id = "Banana",
        Size = "M",
        Speed = 12,
        Damage = 10,
        Wear   = 1,
        Coins  = 2,
        Points = 1,
        Path   = "arc",
        HPClass = "Medium",
    },
    Orange = {
        Id = "Orange",
        Size = "S",
        Speed = 13,
        Damage = 9,
        Wear   = 1,
        Coins  = 2,
        Points = 1,
        Path   = "wobble",
        HPClass = "Light",
    },
    GrapeBundle = {
        Id = "GrapeBundle",
        Size = "XS",
        Speed = 16,
        Damage = 3,   -- per grape
        Wear   = 1,   -- per grape
        Coins  = 3,   -- total across bundle (distribute as needed)
        Points = 1,
        Path   = "zig",
        HPClass = "Light",
        BundleCount = 3, -- 3–4 possible
        BundleCountMax = 4,
    },
    Pineapple = {
        Id = "Pineapple",
        Size = "L",
        Speed = 10,
        Damage = 15,
        Wear   = 2,
        Coins  = 4,
        Points = 2,
        Path   = "arc",
        HPClass = "Heavy",
    },
    Coconut = {
        Id = "Coconut",
        Size = "L",
        Speed = 11,
        Damage = 18,
        Wear   = 3,
        Coins  = 5,
        Points = 3,
        Path   = "straight",
        HPClass = "Heavy",
    },
    Watermelon = {
        Id = "Watermelon",
        Size = "XL",
        Speed = 9,
        Damage = 22,
        Wear   = 4,
        Coins  = 6,
        Points = 4,
        Path   = "wobble",
        HPClass = "XL",
    },
}

-- Optional melee HP buckets (for balancing breakpoints)
Fruit.HPByClass = {
    Light  = 15,
    Medium = 30,
    Heavy  = 50,
    XL     = 70,
}

function Fruit.All()
    return Fruit.Roster
end

function Fruit.Get(id)
    return Fruit.Roster[id]
end

return Fruit




