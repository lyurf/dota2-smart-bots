if GetScriptDirectory == nil then GetScriptDirectory = function () return "bots" end end
local Customize = require( GetScriptDirectory()..'/FuncLib/systems/custom_loader' )

-- ============================================================================
-- Smart Bots (HATS) bot names.
--
-- Every bot gets a name from the list below plus the ".HATS" tag, e.g. "Nil.HATS".
-- Names are drawn in random order, and names higher in the list are drawn more often
-- (weight = how far from the bottom the name is). Teams are not tied to a half of the list.
--
-- Each team's bots run in a separate script, so both teams build the same draw from a
-- shared seed (the current real-time second) and deal it in turns to Radiant and Dire,
-- so names do not repeat across teams. In the rare case the two
-- scripts start in different seconds, a name can appear on both teams.
-- Custom names from Customize/general.lua (Radiant_Names / Dire_Names) still win.
-- ============================================================================

local Dota2Teams = { }

Dota2Teams.defaultPostfix = 'HATS'
Dota2Teams.maxTeamSize = 12 -- e.g. for 12 v 12

-- Higher in the list = picked more often.
local BotNames = {
    "TyMaH",
    "Sah1b",
    "Nil",
    "Lexicon",
    "MishaART",
    "Kamysh",
    "yaSmiroff",
    "Gubinsky",
    "vox",
    "SlowDown",
}

-- Small deterministic random generator (same seed -> same numbers in both team scripts).
local function NewRng(seed)
    local state = (math.floor(seed) % 2147483646) + 1
    return function()
        state = (state * 16807) % 2147483647
        return state / 2147483647
    end
end

local function SharedSeed()
    local ok, t = pcall(RealTime)
    if ok and t then return math.floor(t) end
    return RandomInt(1, 1000000)
end

-- Weighted draw without repeats: the whole list in a random, top-heavy order.
local function WeightedOrder(names, rng)
    local remaining = { }
    for i, name in ipairs(names) do
        table.insert(remaining, { name = name, weight = #names - i + 1 })
    end
    local order = { }
    while #remaining > 0 do
        local total = 0
        for _, item in ipairs(remaining) do total = total + item.weight end
        local roll = rng() * total
        local pickIndex = #remaining
        for idx, item in ipairs(remaining) do
            roll = roll - item.weight
            if roll <= 0 then pickIndex = idx break end
        end
        table.insert(order, remaining[pickIndex].name)
        table.remove(remaining, pickIndex)
    end
    return order
end

local function WithTag(name)
    if string.sub(name, -(#Dota2Teams.defaultPostfix + 1)) == '.'..Dota2Teams.defaultPostfix then
        return name
    end
    return name..'.'..Dota2Teams.defaultPostfix
end

local function generateTeam(takesOdd, order, overrides, customTeamName)
    -- The shared order is dealt like cards: one team gets the 1st, 3rd, 5th... names, the other
    -- the 2nd, 4th... (which team starts is random), so popular names are not tied to one team.
    local pool = { }
    for i = takesOdd and 1 or 2, #order, 2 do table.insert(pool, order[i]) end

    local showTeamTag = Customize.Enable and Customize.Show_Team_Names and customTeamName and customTeamName ~= ''

    local team = { }
    local drawn = 0
    for i = 1, Dota2Teams.maxTeamSize do
        local name
        if overrides and overrides[i] and overrides[i] ~= '' and overrides[i] ~= 'Random' then
            name = overrides[i]
        else
            local base = pool[(drawn % #pool) + 1]
            local round = math.floor(drawn / #pool)
            name = round == 0 and base or (base..tostring(round + 1)) -- only for teams larger than 5
            drawn = drawn + 1
        end
        if showTeamTag then name = customTeamName..'.'..name end
        table.insert(team, WithTag(name))
    end
    return team
end

function Dota2Teams.generateTeams(overrides)
    local radiantOverrides = overrides and overrides.Radiant or {}
    local direOverrides = overrides and overrides.Dire or {}

    local radiantCustomName = Customize.Enable and Customize.Radiant_Team_Name or nil
    local direCustomName = Customize.Enable and Customize.Dire_Team_Name or nil

    local rng = NewRng(SharedSeed())
    local order = WeightedOrder(BotNames, rng)
    local radiantFirst = rng() < 0.5 -- who gets the first (most likely top) name
    return {
        Radiant = generateTeam(radiantFirst, order, radiantOverrides, radiantCustomName),
        Dire = generateTeam(not radiantFirst, order, direOverrides, direCustomName),
    }
end

return Dota2Teams
