if GetScriptDirectory == nil then GetScriptDirectory = function () return "bots" end end
local Customize = require( GetScriptDirectory()..'/FuncLib/systems/custom_loader' )

-- ============================================================================
-- Smart Bots (HATS) bot names.
--
-- Every bot gets a name from the list below plus the ".HATS" tag, e.g. "Nil.HATS".
-- Each team's bots run in a separate script, so the two teams cannot share one
-- random draw. To keep names unique across both teams, Radiant uses the first half
-- of the list and Dire the second half, each in random order.
-- Custom names from Customize/general.lua (Radiant_Names / Dire_Names) still win.
-- ============================================================================

local Dota2Teams = { }

Dota2Teams.defaultPostfix = 'HATS'
Dota2Teams.maxTeamSize = 12 -- e.g. for 12 v 12

local BotNames = {
    -- Radiant
    "TyMaH", "sah1b", "Nil", "Lexicon", "MishaART",
    -- Dire
    "Kamysh", "yaSmiroff", "Gubinsky", "vox", "SlowDown",
}

local function Shuffle(list)
    for i = #list, 2, -1 do
        local j = RandomInt(1, i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local function WithTag(name)
    if string.sub(name, -(#Dota2Teams.defaultPostfix + 1)) == '.'..Dota2Teams.defaultPostfix then
        return name
    end
    return name..'.'..Dota2Teams.defaultPostfix
end

local function generateTeam(isRadiant, overrides, customTeamName)
    local half = math.floor(#BotNames / 2)
    local first = isRadiant and 1 or half + 1
    local last = isRadiant and half or #BotNames

    local pool = { }
    for i = first, last do table.insert(pool, BotNames[i]) end
    Shuffle(pool)

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

    return {
        Radiant = generateTeam(true, radiantOverrides, radiantCustomName),
        Dire = generateTeam(false, direOverrides, direCustomName),
    }
end

return Dota2Teams
