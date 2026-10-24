--[[ Generated with https://github.com/TypeScriptToLua/TypeScriptToLua ]]
-- Lua Library inline imports
local function __TS__ArraySort(self, compareFn)
    if compareFn ~= nil then
        table.sort(
            self,
            function(a, b) return compareFn(nil, a, b) < 0 end
        )
    else
        table.sort(self)
    end
    return self
end

local function __TS__CountVarargs(...)
    return select("#", ...)
end

local function __TS__ArraySplice(self, ...)
    local args = {...}
    local len = #self
    local actualArgumentCount = __TS__CountVarargs(...)
    local start = args[1]
    local deleteCount = args[2]
    if start < 0 then
        start = len + start
        if start < 0 then
            start = 0
        end
    elseif start > len then
        start = len
    end
    local itemCount = actualArgumentCount - 2
    if itemCount < 0 then
        itemCount = 0
    end
    local actualDeleteCount
    if actualArgumentCount == 0 then
        actualDeleteCount = 0
    elseif actualArgumentCount == 1 then
        actualDeleteCount = len - start
    else
        actualDeleteCount = deleteCount or 0
        if actualDeleteCount < 0 then
            actualDeleteCount = 0
        end
        if actualDeleteCount > len - start then
            actualDeleteCount = len - start
        end
    end
    local out = {}
    for k = 1, actualDeleteCount do
        local from = start + k
        if self[from] ~= nil then
            out[k] = self[from]
        end
    end
    if itemCount < actualDeleteCount then
        for k = start + 1, len - actualDeleteCount do
            local from = k + actualDeleteCount
            local to = k + itemCount
            if self[from] then
                self[to] = self[from]
            else
                self[to] = nil
            end
        end
        for k = len - actualDeleteCount + itemCount + 1, len do
            self[k] = nil
        end
    elseif itemCount > actualDeleteCount then
        for k = len - actualDeleteCount, start + 1, -1 do
            local from = k + actualDeleteCount
            local to = k + itemCount
            if self[from] then
                self[to] = self[from]
            else
                self[to] = nil
            end
        end
    end
    local j = start + 1
    for i = 3, actualArgumentCount do
        self[j] = args[i]
        j = j + 1
    end
    for k = #self, len - actualDeleteCount + itemCount + 1, -1 do
        self[k] = nil
    end
    return out
end
-- End of Lua Library inline imports
local ____exports = {}
local BansHero, PicksHero, AlreadyInTable, IsUnavailableHero, RandomHero, IsTaken, IsWeakHero, PickedHeroesOf, SignedSqrt, RoleWeight, GeneralStrength, PickFromTop, BestHeroForRole, BestBan, WasHumansDonePicking, SelectsHero, GetTeamSelectedHeroes, UpdateSelectedHeroes, FillLaneAssignmentTable, Matchups, UnImplementedHeroes, ListPickedHeroes, AllHeroesSelected, BanCycle, PickCycle, UnavailableHeroes, WeakHeroes, HeroLanes, allBotHeroes, humanPick, generalStrength, PICK_FUZZ, BAN_FUZZ, MIN_ROLE_WEIGHT, RoleAssignment
local ____dota = require(GetScriptDirectory().."/ts_libs/dota/index")
local GameState = ____dota.GameState
local HeroPickState = ____dota.HeroPickState
local Lane = ____dota.Lane
local Team = ____dota.Team
local ____role = require(GetScriptDirectory().."/FuncLib/systems/role")
local CanBeOfflaner = ____role.CanBeOfflaner
local CanBeMidlaner = ____role.CanBeMidlaner
local CanBeSupport = ____role.CanBeSupport
local CanBeSafeLaneCarry = ____role.CanBeSafeLaneCarry
local ____hero_pos_weights = require(GetScriptDirectory().."/FuncLib/data/hero_pos_weights")
local GetHeroPositions = ____hero_pos_weights.GetHeroPositions
function ____exports.PickCaptain()
    if not ____exports.IsHumanPlayerExist() or DotaTime() > -1 then
        if GetCMCaptain() == -1 then
            local CaptBot = ____exports.GetFirstBot()
            if CaptBot ~= nil and CaptBot ~= nil then
                log("CAPTAIN PID : %s", CaptBot)
                SetCMCaptain(CaptBot)
            end
        end
    end
end
function ____exports.IsHumanPlayerExist()
    local Players = GetTeamPlayers(GetTeam())
    for ____, id in ipairs(Players) do
        if not IsPlayerBot(id) then
            return true
        end
    end
    return false
end
function ____exports.GetFirstBot()
    local BotId = nil
    local Players = GetTeamPlayers(GetTeam())
    for ____, id in ipairs(Players) do
        if IsPlayerBot(id) then
            BotId = id
            return BotId
        end
    end
    return BotId
end
function BansHero()
    if not IsPlayerBot(GetCMCaptain()) or not IsPlayerInHeroSelectionControl(GetCMCaptain()) then
        return
    end
    local BannedHero = BestBan()
    log("%s is banned", BannedHero)
    CMBanHero(BannedHero)
    BanCycle = BanCycle + 1
end
function PicksHero()
    if not IsPlayerBot(GetCMCaptain()) or not IsPlayerInHeroSelectionControl(GetCMCaptain()) then
        return
    end
    local sTeamName = GetTeam() == Team.Radiant and "TEAM_RADIANT" or "TEAM_DIRE"
    local PickedHero
    if PickCycle == 1 then
        PickedHero = BestHeroForRole({3}, CanBeOfflaner)
        ____exports.PairsHeroNameNRole[sTeamName][PickedHero] = "offlaner"
    elseif PickCycle == 2 or PickCycle == 4 then
        PickedHero = BestHeroForRole({4, 5}, CanBeSupport)
        ____exports.PairsHeroNameNRole[sTeamName][PickedHero] = "support"
    elseif PickCycle == 3 then
        PickedHero = BestHeroForRole({2}, CanBeMidlaner)
        ____exports.PairsHeroNameNRole[sTeamName][PickedHero] = "midlaner"
    else
        PickedHero = BestHeroForRole({1}, CanBeSafeLaneCarry)
        ____exports.PairsHeroNameNRole[sTeamName][PickedHero] = "carry"
    end
    log("%s is picked", PickedHero)
    CMPickHero(PickedHero)
    PickCycle = PickCycle + 1
end
function AlreadyInTable(hero_name)
    for ____, h in ipairs(humanPick) do
        if hero_name == h then
            return true
        end
    end
    return false
end
function IsUnavailableHero(name)
    for ____, uh in ipairs(UnavailableHeroes) do
        if name == uh then
            return true
        end
    end
    return false
end
function RandomHero()
    local hero = allBotHeroes[RandomInt(1, #allBotHeroes)]
    do
        local i = 0
        while i < 1000 and IsTaken(hero) do
            hero = allBotHeroes[RandomInt(1, #allBotHeroes)]
            i = i + 1
        end
    end
    return hero
end
function IsTaken(hero)
    return IsUnavailableHero(hero) or IsCMPickedHero(
        GetTeam(),
        hero
    ) or IsCMPickedHero(
        GetOpposingTeam(),
        hero
    ) or IsCMBannedHero(hero)
end
function IsWeakHero(hero)
    for ____, h in ipairs(WeakHeroes) do
        if h == hero then
            return true
        end
    end
    return false
end
function PickedHeroesOf(team)
    local result = {}
    for ____, h in ipairs(allBotHeroes) do
        if IsCMPickedHero(team, h) then
            result[#result + 1] = h
        end
    end
    return result
end
function SignedSqrt(x)
    return x >= 0 and math.sqrt(x) or -math.sqrt(-x)
end
function RoleWeight(hero, positions)
    local weights = GetHeroPositions()[hero]
    if weights == nil then
        return 0
    end
    local best = 0
    for ____, pos in ipairs(positions) do
        local w = weights[pos]
        if w ~= nil and w > best then
            best = w
        end
    end
    return best
end
function GeneralStrength(hero)
    local cached = generalStrength[hero]
    if cached ~= nil then
        return cached
    end
    local sum = 0
    local count = 0
    for ____, other in ipairs(allBotHeroes) do
        if other ~= hero then
            local adv = Matchups.GetAdvantage(hero, other)
            if adv ~= 0 then
                sum = sum + adv
                count = count + 1
            end
        end
    end
    local value = count > 0 and sum / count or 0
    generalStrength[hero] = value
    return value
end
function PickFromTop(scored, weights)
    if #scored == 0 then
        return nil
    end
    __TS__ArraySort(
        scored,
        function(____, a, b) return b.score - a.score end
    )
    local roll = RandomInt(1, 100)
    do
        local i = 0
        while i < #weights and i < #scored do
            roll = roll - weights[i + 1]
            if roll <= 0 then
                return scored[i + 1].name
            end
            i = i + 1
        end
    end
    return scored[1].name
end
function BestHeroForRole(positions, canPlay)
    local enemies = PickedHeroesOf(GetOpposingTeam())
    local allies = PickedHeroesOf(GetTeam())
    local scored = {}
    local scoredLooseFit = {}
    for ____, hero in ipairs(allBotHeroes) do
        if not IsTaken(hero) and not IsWeakHero(hero) and canPlay(hero) then
            local roleWeight = RoleWeight(hero, positions)
            local score = (roleWeight - 50) / 5
            for ____, e in ipairs(enemies) do
                score = score + SignedSqrt(Matchups.GetAdvantage(hero, e))
            end
            for ____, a in ipairs(allies) do
                if Matchups.IsSynergy(hero, a) then
                    score = score + 1.5
                end
            end
            score = score + GeneralStrength(hero) / 2
            if roleWeight >= MIN_ROLE_WEIGHT then
                scored[#scored + 1] = {name = hero, score = score}
            else
                scoredLooseFit[#scoredLooseFit + 1] = {name = hero, score = score}
            end
        end
    end
    local best = PickFromTop(scored, PICK_FUZZ) or PickFromTop(scoredLooseFit, PICK_FUZZ)
    if best ~= nil then
        log(
            "CM pick for positions %s: %s",
            table.concat(positions, "/"),
            best
        )
        return best
    end
    do
        local i = 0
        while i < 300 do
            local hero = RandomHero()
            if canPlay(hero) then
                return hero
            end
            i = i + 1
        end
    end
    return RandomHero()
end
function BestBan()
    local enemies = PickedHeroesOf(GetOpposingTeam())
    local allies = PickedHeroesOf(GetTeam())
    local scored = {}
    for ____, hero in ipairs(allBotHeroes) do
        if not IsTaken(hero) then
            local score = GeneralStrength(hero)
            for ____, a in ipairs(allies) do
                score = score + SignedSqrt(Matchups.GetAdvantage(hero, a))
            end
            for ____, e in ipairs(enemies) do
                if Matchups.IsSynergy(hero, e) then
                    score = score + 1.5
                end
            end
            scored[#scored + 1] = {name = hero, score = score}
        end
    end
    return PickFromTop(scored, BAN_FUZZ) or RandomHero()
end
function WasHumansDonePicking()
    local Players = GetTeamPlayers(GetTeam())
    for ____, id in ipairs(Players) do
        if not IsPlayerBot(id) then
            local selected = GetSelectedHeroName(id)
            if selected == nil or selected == "" then
                return false
            end
        end
    end
    return true
end
function SelectsHero()
    if not AllHeroesSelected and (WasHumansDonePicking() or GetCMPhaseTimeRemaining() < 1) then
        local Players = GetTeamPlayers(GetTeam())
        local RestBotPlayers = {}
        GetTeamSelectedHeroes()
        for ____, id in ipairs(Players) do
            local hero_name = GetSelectedHeroName(id)
            if hero_name ~= nil and hero_name ~= "" then
                UpdateSelectedHeroes(hero_name)
                log("%s Removed", hero_name)
            else
                RestBotPlayers[#RestBotPlayers + 1] = id
            end
        end
        do
            local i = 0
            while i < #RestBotPlayers do
                SelectHero(RestBotPlayers[i + 1], ListPickedHeroes[i + 1])
                i = i + 1
            end
        end
        AllHeroesSelected = true
    end
end
function GetTeamSelectedHeroes()
    for ____, sName in ipairs(allBotHeroes) do
        if IsCMPickedHero(
            GetTeam(),
            sName
        ) then
            ListPickedHeroes[#ListPickedHeroes + 1] = sName
        end
    end
    for ____, sName in ipairs(UnImplementedHeroes) do
        if IsCMPickedHero(
            GetTeam(),
            sName
        ) then
            ListPickedHeroes[#ListPickedHeroes + 1] = sName
        end
    end
end
function UpdateSelectedHeroes(selected)
    do
        local i = 0
        while i < #ListPickedHeroes do
            if ListPickedHeroes[i + 1] == selected then
                __TS__ArraySplice(ListPickedHeroes, i, 1)
                break
            end
            i = i + 1
        end
    end
end
function FillLaneAssignmentTable()
    local TeamMember = GetTeamPlayers(GetTeam())
    local sTeamName = GetTeam() == Team.Radiant and "TEAM_RADIANT" or "TEAM_DIRE"
    local supportAlreadyAssigned = {TEAM_RADIANT = false, TEAM_DIRE = false}
    do
        local i = 0
        while i < #TeamMember do
            local unit = GetTeamMember(i + 1)
            if unit ~= nil and unit:IsHero() then
                local unit_name = unit:GetUnitName()
                local roleName = ____exports.PairsHeroNameNRole[sTeamName][unit_name]
                if roleName == "support" then
                    if GetTeam() == Team.Radiant then
                        if not supportAlreadyAssigned.TEAM_RADIANT then
                            HeroLanes[sTeamName][i + 1] = Lane.Bot
                            supportAlreadyAssigned.TEAM_RADIANT = true
                            RoleAssignment[sTeamName][i + 1] = 5
                        else
                            HeroLanes[sTeamName][i + 1] = Lane.Top
                            RoleAssignment[sTeamName][i + 1] = 4
                        end
                    else
                        if not supportAlreadyAssigned.TEAM_DIRE then
                            HeroLanes[sTeamName][i + 1] = Lane.Top
                            supportAlreadyAssigned.TEAM_DIRE = true
                            RoleAssignment[sTeamName][i + 1] = 5
                        else
                            HeroLanes[sTeamName][i + 1] = Lane.Bot
                            RoleAssignment[sTeamName][i + 1] = 4
                        end
                    end
                elseif roleName == "midlaner" then
                    HeroLanes[sTeamName][i + 1] = Lane.Mid
                    RoleAssignment[sTeamName][i + 1] = 2
                elseif roleName == "offlaner" then
                    if GetTeam() == Team.Radiant then
                        HeroLanes[sTeamName][i + 1] = Lane.Top
                    else
                        HeroLanes[sTeamName][i + 1] = Lane.Bot
                    end
                    RoleAssignment[sTeamName][i + 1] = 3
                elseif roleName == "carry" then
                    if GetTeam() == Team.Radiant then
                        HeroLanes[sTeamName][i + 1] = Lane.Bot
                    else
                        HeroLanes[sTeamName][i + 1] = Lane.Top
                    end
                    RoleAssignment[sTeamName][i + 1] = 1
                end
            end
            i = i + 1
        end
    end
end
Matchups = require(GetScriptDirectory().."/FuncLib/data/matchups_data")
UnImplementedHeroes = {}
ListPickedHeroes = {}
AllHeroesSelected = false
BanCycle = 1
PickCycle = 1
local NeededTime = 28
local Min = 15
local Max = 20
local CMdebugMode = true
UnavailableHeroes = {"npc_dota_hero_techies"}
WeakHeroes = {
    "npc_dota_hero_chen",
    "npc_dota_hero_ancient_apparition",
    "npc_dota_hero_tinker",
    "npc_dota_hero_pangolier",
    "npc_dota_hero_tusk",
    "npc_dota_hero_morphling",
    "npc_dota_hero_visage",
    "npc_dota_hero_void_spirit",
    "npc_dota_hero_ember_spirit",
    "npc_dota_hero_rubick",
    "npc_dota_hero_brewmaster",
    "npc_dota_hero_puck",
    "npc_dota_hero_marci",
    "npc_dota_hero_lone_druid",
    "npc_dota_hero_primal_beast",
    "npc_dota_hero_dark_willow",
    "npc_dota_hero_hoodwink",
    "npc_dota_hero_wisp"
}
HeroLanes = {TEAM_RADIANT = {
    [1] = Lane.Bot,
    [2] = Lane.Mid,
    [3] = Lane.Top,
    [4] = Lane.Top,
    [5] = Lane.Bot
}, TEAM_DIRE = {
    [1] = Lane.Top,
    [2] = Lane.Mid,
    [3] = Lane.Bot,
    [4] = Lane.Bot,
    [5] = Lane.Top
}}
allBotHeroes = {}
____exports.PairsHeroNameNRole = {TEAM_RADIANT = {}, TEAM_DIRE = {}}
humanPick = {}
function ____exports.CaptainModeLogic(SupportedHeroes)
    allBotHeroes = SupportedHeroes
    if GetGameState() ~= GameState.HeroSelection then
        return
    end
    if not CMdebugMode then
        NeededTime = RandomInt(Min, Max)
    elseif CMdebugMode then
        NeededTime = 25
    end
    local state = GetHeroPickState()
    if state == HeroPickState.CmCaptainPick then
        ____exports.PickCaptain()
    elseif state >= HeroPickState.CmBan1 and state <= 20 and GetCMPhaseTimeRemaining() <= NeededTime then
        BansHero()
        NeededTime = 0
    elseif state >= HeroPickState.CmSelect1 and state <= HeroPickState.CmSelect10 and GetCMPhaseTimeRemaining() <= NeededTime then
        PicksHero()
        NeededTime = 0
    elseif state == HeroPickState.CmPick then
        SelectsHero()
    end
end
function ____exports.AddToList()
    if not IsPlayerBot(GetCMCaptain()) then
        for ____, h in ipairs(allBotHeroes) do
            if IsCMPickedHero(
                GetTeam(),
                h
            ) and not AlreadyInTable(h) then
                humanPick[#humanPick + 1] = h
            end
        end
    end
end
generalStrength = {}
PICK_FUZZ = {50, 30, 20}
BAN_FUZZ = {
    35,
    25,
    20,
    12,
    8
}
MIN_ROLE_WEIGHT = 40
RoleAssignment = {TEAM_RADIANT = {}, TEAM_DIRE = {}}
function ____exports.CMLaneAssignment(roleAssign)
    local sTeamName = GetTeam() == Team.Radiant and "TEAM_RADIANT" or "TEAM_DIRE"
    RoleAssignment = roleAssign
    if IsPlayerBot(GetCMCaptain()) then
        FillLaneAssignmentTable()
    else
    end
    return HeroLanes[sTeamName]
end
return ____exports
