--[[ Generated with https://github.com/TypeScriptToLua/TypeScriptToLua ]]
-- Lua Library inline imports
local function __TS__ArrayFilter(self, callbackfn, thisArg)
    local result = {}
    local len = 0
    for i = 1, #self do
        if callbackfn(thisArg, self[i], i - 1, self) then
            len = len + 1
            result[len] = self[i]
        end
    end
    return result
end

local function __TS__StringIncludes(self, searchString, position)
    if not position then
        position = 1
    else
        position = position + 1
    end
    local index = string.find(self, searchString, position, true)
    return index ~= nil
end

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

local function __TS__ArrayFind(self, predicate, thisArg)
    for i = 1, #self do
        local elem = self[i]
        if predicate(thisArg, elem, i - 1, self) then
            return elem
        end
    end
    return nil
end
-- End of Lua Library inline imports
local ____exports = {}
local getDefendState, updateDefendGameStateCache, updateDefendLocationStateCache, updateDefendUnitStateCache, _q, _keyLoc, _recentHeroCountNear, IsValidBuildingTarget, IsBaseThreatActive, IsDefendingOtherLane, WeightedEnemiesAroundLocation, GetThreatenedLane, GetClosestAllyPos, IsThereNoTeammateTravelBootsDefender, GetHighGroundEdgeWaitPoint, ConsiderPingedDefend, okLoc, Localization, PING_DELTA, MAX_DESIRE_CAP, BASE_THREAT_RADIUS, BASE_THREAT_HOLD, CACHE_ENEMY_AROUND_LOC_HZ, CACHE_LASTSEEN_WINDOW, nTeam, _threatLaneSticky, baseThreatUntil, fTraveBootsDefendTime, _cacheEnemyAroundLoc, DEFEND_CACHE_TTL, defendGameStateCache, defendLocationStateCache, defendUnitStateCache
local Fu = require(GetScriptDirectory().."/FuncLib/func_utils")
local ____dota = require(GetScriptDirectory().."/ts_libs/dota/index")
local Barracks = ____dota.Barracks
local BotMode = ____dota.BotMode
local BotModeDesire = ____dota.BotModeDesire
local Lane = ____dota.Lane
local Team = ____dota.Team
local Tower = ____dota.Tower
local UnitType = ____dota.UnitType
local ____native_2Doperators = require(GetScriptDirectory().."/ts_libs/utils/native-operators")
local add = ____native_2Doperators.add
local ____utils = require(GetScriptDirectory().."/FuncLib/systems/utils")
local GetLocationToLocationDistance = ____utils.GetLocationToLocationDistance
local ConsiderTPToTarget = ____utils.ConsiderTPToTarget
local RadiantFountainTpPoint = ____utils.RadiantFountainTpPoint
local DireFountainTpPoint = ____utils.DireFountainTpPoint
local CK = require(GetScriptDirectory().."/FuncLib/systems/cache_keys")
function getDefendState(bot)
    if not bot._defend then
        bot._defend = {
            defendLoc = GetLaneFrontLocation(nTeam, Lane.Mid, 0),
            weAreStronger = false,
            nInRangeAlly = {},
            nInRangeEnemy = {},
            distanceToLane = {[Lane.Top] = 0, [Lane.Mid] = 0, [Lane.Bot] = 0}
        }
    end
    return bot._defend
end
function updateDefendGameStateCache()
    local now = DotaTime()
    if defendGameStateCache and now - defendGameStateCache.lastUpdate < DEFEND_CACHE_TTL then
        return defendGameStateCache
    end
    local team = GetTeam()
    local enemyTeam = GetOpposingTeam()
    local currentTime = DotaTime()
    local gameMode = GetGameMode()
    local adjustedTime = gameMode == 23 and currentTime * 1.65 or currentTime
    local ancient = GetAncient(team)
    local ancientLoc = ancient ~= nil and ancient:GetLocation() or nil
    local defendersCount = 0
    if ancientLoc ~= nil then
        local defs = Fu.GetAlliesNearLoc(ancientLoc, 2500)
        for ____, d in ipairs(defs) do
            if Fu.IsValidHero(d) then
                defendersCount = defendersCount + 1
            end
        end
    end
    defendGameStateCache = {
        lastUpdate = now,
        currentTime = adjustedTime,
        gameMode = gameMode,
        team = team,
        enemyTeam = enemyTeam,
        ourAncient = ancient,
        enemyAncient = GetAncient(enemyTeam),
        aliveAllyCount = Fu.GetNumOfAliveHeroes(false),
        aliveEnemyCount = Fu.GetNumOfAliveHeroes(true),
        isLaningPhase = Fu.IsInLaningPhase(),
        isEarlyGame = Fu.IsEarlyGame(),
        isMidGame = Fu.IsMidGame(),
        isLateGame = Fu.IsLateGame(),
        teamFountain = Fu.GetTeamFountain(),
        teamFountainTpPoint = Fu.Utils.GetTeamFountainTpPoint(),
        enemiesOnHG = Fu.Utils.CountEnemyHeroesOnHighGround(team),
        enemiesAtAncient = ancientLoc ~= nil and Fu.Utils.CountEnemyHeroesNear(ancientLoc, 2200) or 0,
        ancientHP = ancient ~= nil and ancient:IsAlive() and Fu.GetHP(ancient) or 1,
        defendersAtAncient = defendersCount
    }
    return defendGameStateCache
end
function updateDefendLocationStateCache()
    local now = DotaTime()
    if defendLocationStateCache and now - defendLocationStateCache.lastUpdate < DEFEND_CACHE_TTL then
        return defendLocationStateCache
    end
    local team = GetTeam()
    local enemyTeam = GetOpposingTeam()
    defendLocationStateCache = {
        lastUpdate = now,
        laneFronts = {
            [Lane.Top] = GetLaneFrontLocation(team, Lane.Top, 0),
            [Lane.Mid] = GetLaneFrontLocation(team, Lane.Mid, 0),
            [Lane.Bot] = GetLaneFrontLocation(team, Lane.Bot, 0)
        },
        enemyLaneFronts = {
            [Lane.Top] = GetLaneFrontLocation(enemyTeam, Lane.Top, 0),
            [Lane.Mid] = GetLaneFrontLocation(enemyTeam, Lane.Mid, 0),
            [Lane.Bot] = GetLaneFrontLocation(enemyTeam, Lane.Bot, 0)
        },
        highGroundEdgeWaitPoints = {
            [Lane.Top] = GetHighGroundEdgeWaitPoint(team, Lane.Top),
            [Lane.Mid] = GetHighGroundEdgeWaitPoint(team, Lane.Mid),
            [Lane.Bot] = GetHighGroundEdgeWaitPoint(team, Lane.Bot)
        }
    }
    return defendLocationStateCache
end
function updateDefendUnitStateCache()
    local now = DotaTime()
    if defendUnitStateCache and now - defendUnitStateCache.lastUpdate < DEFEND_CACHE_TTL then
        return defendUnitStateCache
    end
    local teamMembers = {}
    for ____, member in ipairs(GetUnitList(UnitType.AlliedHeroes)) do
        if member ~= nil and not member:IsIllusion() then
            teamMembers[#teamMembers + 1] = member
        end
    end
    defendUnitStateCache = {
        lastUpdate = now,
        enemyBuildings = GetUnitList(UnitType.EnemyBuildings),
        alliedHeroes = GetUnitList(UnitType.AlliedHeroes),
        enemyHeroes = __TS__ArrayFilter(
            GetUnitList(UnitType.Enemies),
            function(____, u) return Fu.IsValidHero(u) end
        ),
        alliedCreeps = GetUnitList(UnitType.AlliedCreeps),
        enemyCreeps = __TS__ArrayFilter(
            GetUnitList(UnitType.Enemies),
            function(____, u) return u:IsCreep() or u:IsAncientCreep() end
        ),
        teamMembers = teamMembers
    }
    return defendUnitStateCache
end
function _q(v)
    return v and (tostring(math.floor(v.x / 200) * 200) .. ":") .. tostring(math.floor(v.y / 200) * 200) or "0:0"
end
function _keyLoc(v, r)
    return (_q(v) .. "|") .. tostring(math.floor(r or 0))
end
function _recentHeroCountNear(loc, r, window)
    if window == nil then
        window = CACHE_LASTSEEN_WINDOW
    end
    local gameState = updateDefendGameStateCache()
    local cnt = 0
    for ____, id in ipairs(GetTeamPlayers(gameState.enemyTeam)) do
        do
            local __continue24
            repeat
                if not IsHeroAlive(id) then
                    __continue24 = true
                    break
                end
                local info = GetHeroLastSeenInfo(id)
                if info and info[1] and info[1].time_since_seen <= window and GetLocationToLocationDistance(info[1].location, loc) <= r then
                    cnt = cnt + 1
                end
                __continue24 = true
            until true
            if not __continue24 then
                break
            end
        end
    end
    return cnt
end
function IsValidBuildingTarget(unit)
    return unit ~= nil and unit:IsAlive() and unit:IsBuilding()
end
function IsBaseThreatActive()
    return DotaTime() < (baseThreatUntil or -1)
end
function IsDefendingOtherLane(bot, lane)
    local mode = bot:GetActiveMode()
    if lane == Lane.Top then
        return mode == BotMode.DefendTowerMid or mode == BotMode.DefendTowerBot
    end
    if lane == Lane.Mid then
        return mode == BotMode.DefendTowerTop or mode == BotMode.DefendTowerBot
    end
    if lane == Lane.Bot then
        return mode == BotMode.DefendTowerTop or mode == BotMode.DefendTowerMid
    end
    return false
end
function WeightedEnemiesAroundLocation(vLoc, nRadius)
    local now = DotaTime()
    local key = _keyLoc(vLoc, nRadius)
    local c = _cacheEnemyAroundLoc[key]
    if c and now - c.t <= CACHE_ENEMY_AROUND_LOC_HZ then
        return c.count
    end
    local unitState = updateDefendUnitStateCache()
    local count = 0
    for ____, unit in ipairs(unitState.enemyHeroes) do
        if Fu.IsValid(unit) and GetUnitToLocationDistance(unit, vLoc) <= nRadius then
            local name = unit:GetUnitName()
            if Fu.IsValidHero(unit) and not Fu.IsSuspiciousIllusion(unit) then
                count = count + (Fu.IsCore(unit) and 1 or 0.5)
            elseif ({string.find(name, "upgraded_mega")}) ~= nil then
                count = count + 0.6
            elseif ({string.find(name, "upgraded")}) ~= nil then
                count = count + 0.4
            elseif ({string.find(name, "siege")}) ~= nil and ({string.find(name, "upgraded")}) == nil then
                count = count + 0.5
            elseif ({string.find(name, "warlock_golem")}) ~= nil or ({string.find(name, "lone_druid_bear")}) ~= nil then
                count = count + 1
            elseif unit:IsCreep() or unit:IsAncientCreep() or unit:IsDominated() or unit:HasModifier("modifier_chen_holy_persuasion") or unit:HasModifier("modifier_dominated") then
                count = count + 0.2
            end
        end
    end
    count = math.floor(count)
    _cacheEnemyAroundLoc[key] = {t = now, count = count}
    return count
end
function GetThreatenedLane()
    local lanes = {Lane.Top, Lane.Mid, Lane.Bot}
    local bestLane = lanes[1]
    local bestScore = -1
    for ____, ln in ipairs(lanes) do
        local bld, _urgent, tier = unpack(____exports.GetFurthestBuildingOnLane(ln))
        local anchor = IsValidBuildingTarget(bld) and tier < 3 and bld:GetLocation() or GetHighGroundEdgeWaitPoint(nTeam, ln)
        local enemyHeroCnt = _recentHeroCountNear(anchor, 1800)
        local score = enemyHeroCnt * 10
        if enemyHeroCnt == 0 then
            local creepEq = math.min(
                WeightedEnemiesAroundLocation(anchor, 1200) * 0.4,
                0.9
            )
            score = score + creepEq
        end
        if score > bestScore then
            bestScore = score
            bestLane = ln
        end
    end
    if DotaTime() <= _threatLaneSticky["until"] and _threatLaneSticky.lane ~= bestLane then
        if bestScore >= 10 then
            _threatLaneSticky = {
                lane = bestLane,
                ["until"] = DotaTime() + 3
            }
            return bestLane
        end
        return _threatLaneSticky.lane
    end
    _threatLaneSticky = {
        lane = bestLane,
        ["until"] = DotaTime() + 3
    }
    return bestLane
end
function GetClosestAllyPos(tPosList, vLocation)
    local bestPos = nil
    local bestDist = math.huge
    for ____, m in ipairs(GetUnitList(UnitType.AlliedHeroes)) do
        if Fu.IsValidHero(m) and not m:IsIllusion() then
            local p = Fu.GetPosition(m)
            do
                local j = 1
                while j <= #tPosList do
                    if p == tPosList[j + 1] then
                        local d = GetUnitToLocationDistance(m, vLocation)
                        if d < bestDist then
                            bestDist = d
                            bestPos = p
                        end
                    end
                    j = j + 1
                end
            end
        end
    end
    return bestPos or tPosList[1]
end
function ____exports.GetFurthestBuildingOnLane(lane)
    local cacheKey = CK.FURTHEST_BUILDING + nTeam * 10 + (lane or 0)
    local cachedVar = Fu.Utils.GetCachedVars(cacheKey, 1)
    if cachedVar ~= nil then
        return cachedVar
    end
    local res = ____exports.GetFurthestBuildingOnLaneHelper(lane)
    Fu.Utils.SetCachedVars(cacheKey, res)
    return res
end
function ____exports.GetFurthestBuildingOnLaneHelper(lane)
    local team = nTeam
    local b
    local function hpMul(u, lo, hi, mlo, mhi)
        local nHealth = u:GetHealth() / u:GetMaxHealth()
        return RemapValClamped(
            nHealth,
            lo,
            hi,
            mlo,
            mhi
        )
    end
    if lane == Lane.Top then
        b = GetTower(team, Tower.Top1)
        if IsValidBuildingTarget(b) then
            return {
                b,
                hpMul(
                    b,
                    0.25,
                    1,
                    0.5,
                    1
                ),
                1
            }
        end
        b = GetTower(team, Tower.Top2)
        if IsValidBuildingTarget(b) then
            return {
                b,
                hpMul(
                    b,
                    0.25,
                    1,
                    1,
                    2
                ),
                2
            }
        end
        b = GetTower(team, Tower.Top3)
        if IsValidBuildingTarget(b) then
            return {
                b,
                hpMul(
                    b,
                    0.25,
                    1,
                    1.5,
                    2
                ),
                3
            }
        end
        b = GetBarracks(team, Barracks.TopMelee)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 3}
        end
        b = GetBarracks(team, Barracks.TopRanged)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 3}
        end
        b = GetTower(team, Tower.Base1)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 4}
        end
        b = GetTower(team, Tower.Base2)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 4}
        end
        b = GetAncient(team)
        if IsValidBuildingTarget(b) then
            return {b, 3, 5}
        end
    elseif lane == Lane.Mid then
        b = GetTower(team, Tower.Mid1)
        if IsValidBuildingTarget(b) then
            return {
                b,
                hpMul(
                    b,
                    0.25,
                    1,
                    0.5,
                    1
                ),
                1
            }
        end
        b = GetTower(team, Tower.Mid2)
        if IsValidBuildingTarget(b) then
            return {
                b,
                hpMul(
                    b,
                    0.25,
                    1,
                    1,
                    2
                ),
                2
            }
        end
        b = GetTower(team, Tower.Mid3)
        if IsValidBuildingTarget(b) then
            return {
                b,
                hpMul(
                    b,
                    0.25,
                    1,
                    1.5,
                    2
                ),
                3
            }
        end
        b = GetBarracks(team, Barracks.MidMelee)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 3}
        end
        b = GetBarracks(team, Barracks.MidRanged)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 3}
        end
        b = GetTower(team, Tower.Base1)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 4}
        end
        b = GetTower(team, Tower.Base2)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 4}
        end
        b = GetAncient(team)
        if IsValidBuildingTarget(b) then
            return {b, 3, 5}
        end
    else
        b = GetTower(team, Tower.Bot1)
        if IsValidBuildingTarget(b) then
            return {
                b,
                hpMul(
                    b,
                    0.25,
                    1,
                    0.5,
                    1
                ),
                1
            }
        end
        b = GetTower(team, Tower.Bot2)
        if IsValidBuildingTarget(b) then
            return {
                b,
                hpMul(
                    b,
                    0.25,
                    1,
                    1,
                    2
                ),
                2
            }
        end
        b = GetTower(team, Tower.Bot3)
        if IsValidBuildingTarget(b) then
            return {
                b,
                hpMul(
                    b,
                    0.25,
                    1,
                    1.5,
                    2
                ),
                3
            }
        end
        b = GetBarracks(team, Barracks.BotMelee)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 3}
        end
        b = GetBarracks(team, Barracks.BotRanged)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 3}
        end
        b = GetTower(team, Tower.Base1)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 4}
        end
        b = GetTower(team, Tower.Base2)
        if IsValidBuildingTarget(b) then
            return {b, 2.5, 4}
        end
        b = GetAncient(team)
        if IsValidBuildingTarget(b) then
            return {b, 3, 5}
        end
    end
    return {nil, 1, 0}
end
function IsThereNoTeammateTravelBootsDefender(bot)
    local unitState = updateDefendUnitStateCache()
    for ____, m in ipairs(unitState.teamMembers) do
        if bot ~= m and Fu.IsValidHero(m) and m.travel_boots_defender == true then
            return false
        end
    end
    return true
end
function GetHighGroundEdgeWaitPoint(team, lane)
    local ____temp_1
    if lane == Lane.Top then
        ____temp_1 = GetTower(team, Tower.Top3)
    else
        local ____temp_0
        if lane == Lane.Mid then
            ____temp_0 = GetTower(team, Tower.Mid3)
        else
            ____temp_0 = GetTower(team, Tower.Bot3)
        end
        ____temp_1 = ____temp_0
    end
    local t3 = ____temp_1
    local ____temp_3
    if lane == Lane.Top then
        ____temp_3 = GetBarracks(team, Barracks.TopMelee)
    else
        local ____temp_2
        if lane == Lane.Mid then
            ____temp_2 = GetBarracks(team, Barracks.MidMelee)
        else
            ____temp_2 = GetBarracks(team, Barracks.BotMelee)
        end
        ____temp_3 = ____temp_2
    end
    local raxM = ____temp_3
    local ____temp_5
    if lane == Lane.Top then
        ____temp_5 = GetBarracks(team, Barracks.TopRanged)
    else
        local ____temp_4
        if lane == Lane.Mid then
            ____temp_4 = GetBarracks(team, Barracks.MidRanged)
        else
            ____temp_4 = GetBarracks(team, Barracks.BotRanged)
        end
        ____temp_5 = ____temp_4
    end
    local raxR = ____temp_5
    local anc = GetAncient(team)
    local ____Fu_IsValidBuilding_result_8
    if Fu.IsValidBuilding(t3) then
        ____Fu_IsValidBuilding_result_8 = t3
    else
        local ____Fu_IsValidBuilding_result_7
        if Fu.IsValidBuilding(raxM) then
            ____Fu_IsValidBuilding_result_7 = raxM
        else
            local ____Fu_IsValidBuilding_result_6
            if Fu.IsValidBuilding(raxR) then
                ____Fu_IsValidBuilding_result_6 = raxR
            else
                ____Fu_IsValidBuilding_result_6 = nil
            end
            ____Fu_IsValidBuilding_result_7 = ____Fu_IsValidBuilding_result_6
        end
        ____Fu_IsValidBuilding_result_8 = ____Fu_IsValidBuilding_result_7
    end
    local anchorBuilding = ____Fu_IsValidBuilding_result_8
    if anchorBuilding and Fu.IsValidBuilding(anc) then
        local t = anchorBuilding:GetLocation()
        local a = anc:GetLocation()
        local dir = Vector(a.x - t.x, a.y - t.y, 0)
        local len = math.max(
            1,
            math.sqrt(dir.x * dir.x + dir.y * dir.y)
        )
        return Vector(t.x + dir.x / len * 250, t.y + dir.y / len * 250, 0)
    end
    return Fu.AdjustLocationWithOffsetTowardsFountain(
        GetLaneFrontLocation(team, lane, 0),
        600
    )
end
function ____exports.ShouldDefend(bot, hBuilding, nRadius)
    if not IsValidBuildingTarget(hBuilding) then
        return false
    end
    local gameState = updateDefendGameStateCache()
    local enemyHeroNearby = 0
    for ____, id in ipairs(GetTeamPlayers(gameState.enemyTeam)) do
        if IsHeroAlive(id) then
            local info = GetHeroLastSeenInfo(id)
            if info ~= nil then
                local d = info[1]
                if d ~= nil and d.time_since_seen <= CACHE_LASTSEEN_WINDOW and GetUnitToLocationDistance(hBuilding, d.location) <= 1600 then
                    enemyHeroNearby = enemyHeroNearby + 1
                end
            end
        end
    end
    local unitState = updateDefendUnitStateCache()
    local creepWeights = 0
    for ____, unit in ipairs(unitState.enemyCreeps) do
        if Fu.IsValid(unit) and GetUnitToUnitDistance(hBuilding, unit) <= nRadius then
            local name = unit:GetUnitName()
            if ({string.find(name, "siege")}) ~= nil and ({string.find(name, "upgraded")}) == nil then
                creepWeights = creepWeights + 0.5
            elseif ({string.find(name, "upgraded_mega")}) ~= nil then
                creepWeights = creepWeights + 0.6
            elseif ({string.find(name, "upgraded")}) ~= nil then
                creepWeights = creepWeights + 0.4
            elseif ({string.find(name, "warlock_golem")}) ~= nil or ({string.find(name, "shadow_shaman_ward")}) ~= nil then
                creepWeights = creepWeights + 1
            elseif ({string.find(name, "lone_druid_bear")}) ~= nil then
                enemyHeroNearby = enemyHeroNearby + 1
            elseif unit:IsCreep() or unit:IsAncientCreep() or unit:IsDominated() or unit:HasModifier("modifier_chen_holy_persuasion") or unit:HasModifier("modifier_dominated") then
                creepWeights = creepWeights + 0.2
            end
        end
    end
    local nNearby = enemyHeroNearby + math.floor(creepWeights)
    local pos = Fu.GetPosition(bot)
    local result = false
    if nNearby == 1 then
        if pos == 2 or pos == 3 or pos == GetClosestAllyPos(
            {4, 5},
            hBuilding:GetLocation()
        ) then
            result = true
        end
    elseif nNearby == 2 then
        if pos == 2 or pos == 3 or pos == GetClosestAllyPos(
            {4, 5},
            hBuilding:GetLocation()
        ) or pos == 1 and GetUnitToUnitDistance(bot, hBuilding) <= 3200 then
            result = true
        end
    elseif nNearby == 3 then
        if pos == 2 or pos == 3 or pos == 4 or pos == 5 or pos == 1 and GetUnitToUnitDistance(bot, hBuilding) <= 3200 then
            result = true
        end
    elseif nNearby >= 4 then
        result = true
    end
    if not result then
        if DotaTime() - fTraveBootsDefendTime >= 20 then
            bot.travel_boots_defender = false
        end
        if bot:GetUnitName() == "npc_dota_hero_tinker" and bot:GetLevel() >= 6 and Fu.CanCastAbility(bot:GetAbilityByName("tinker_keen_teleport")) and IsThereNoTeammateTravelBootsDefender(bot) then
            bot.travel_boots_defender = true
            fTraveBootsDefendTime = DotaTime()
            result = true
        else
            local boots = Fu.GetItem2(bot, "item_travel_boots") or Fu.GetItem2(bot, "item_travel_boots_2")
            if Fu.CanCastAbility(boots) and IsThereNoTeammateTravelBootsDefender(bot) then
                bot.travel_boots_defender = true
                fTraveBootsDefendTime = DotaTime()
                result = true
            end
        end
        if not result and pos == GetClosestAllyPos(
            {2, 3},
            hBuilding:GetLocation()
        ) then
            result = true
        end
    end
    local underFire = bot:WasRecentlyDamagedByAnyHero(5)
    if underFire and result then
        local closestPos = GetClosestAllyPos(
            {2, 3, 4, 5},
            hBuilding:GetLocation()
        )
        if Fu.GetPosition(bot) ~= closestPos then
            return false
        end
    end
    return result
end
function ConsiderPingedDefend(bot, lane, desire, building, tier, nEffAllies, nEnemies)
    local gameState = updateDefendGameStateCache()
    if gameState.isLaningPhase or gameState.aliveAllyCount == 0 then
        return
    end
    if not IsValidBuildingTarget(building) then
        return
    end
    if tier < 2 or desire <= 0.5 then
        return
    end
    if not ____exports.ShouldDefend(bot, building, 1600) then
        return
    end
    Fu.Utils.GameStates = Fu.Utils.GameStates or ({})
    Fu.Utils.GameStates.defendPings = Fu.Utils.GameStates.defendPings or ({pingedTime = GameTime()})
    local defendPings = Fu.Utils.GameStates.defendPings
    if nEffAllies >= 1 and nEffAllies >= nEnemies then
        return
    end
    if GameTime() - defendPings.pingedTime <= 6 then
        return
    end
    local saferLoc = add(
        Fu.AdjustLocationWithOffsetTowardsFountain(
            building:GetLocation(),
            850
        ),
        RandomVector(50)
    )
    local retreaters = Fu.GetRetreatingAlliesNearLoc(saferLoc, 1600)
    if #retreaters == 0 then
        bot:ActionImmediate_Chat(
            Localization.Get("say_come_def"),
            false
        )
        bot:ActionImmediate_Ping(saferLoc.x, saferLoc.y, false)
        defendPings.pingedTime = GameTime()
        defendPings.lane = lane
    end
end
function ____exports.GetDefendDesireHelper(bot, lane)
    if bot.DefendLaneDesire == nil then
        bot.DefendLaneDesire = {}
    end
    if bot._defendCommitLane == nil then
        bot._defendCommitLane = 0
    end
    if bot._defendCommitUntil == nil then
        bot._defendCommitUntil = 0
    end
    local gameState = updateDefendGameStateCache()
    local locationState = updateDefendLocationStateCache()
    local team = gameState.team
    local ancient = gameState.ourAncient
    local commitLane = bot._defendCommitLane
    local commitUntil = bot._defendCommitUntil
    local lanesNeedingDefend = {}
    for ____, l in ipairs({Lane.Top, Lane.Mid, Lane.Bot}) do
        local d = GetDefendLaneDesire(l)
        if d > 0.1 then
            local front = locationState.laneFronts[l]
            local dist = GetUnitToLocationDistance(bot, front)
            local enemies = #Fu.GetLastSeenEnemiesNearLoc(front, 2500)
            local _bld, _urgent, bldTier = unpack(____exports.GetFurthestBuildingOnLane(l))
            local tierWeight = bldTier >= 5 and 3 or (bldTier >= 4 and 2.5 or (bldTier >= 3 and 2 or (bldTier >= 2 and 1.5 or 1)))
            lanesNeedingDefend[#lanesNeedingDefend + 1] = {
                lane = l,
                desire = d * tierWeight,
                dist = dist,
                enemies = enemies,
                tier = bldTier
            }
        end
    end
    if #lanesNeedingDefend >= 2 then
        __TS__ArraySort(
            lanesNeedingDefend,
            function(____, a, b)
                if a.desire ~= b.desire then
                    return b.desire - a.desire
                end
                return a.dist - b.dist
            end
        )
        local bestLane = lanesNeedingDefend[1].lane
        if commitLane ~= 0 and DotaTime() < commitUntil and lane ~= commitLane then
            local commitEntry = __TS__ArrayFind(
                lanesNeedingDefend,
                function(____, e) return e.lane == commitLane end
            )
            local thisEntry = __TS__ArrayFind(
                lanesNeedingDefend,
                function(____, e) return e.lane == lane end
            )
            if thisEntry and commitEntry and thisEntry.tier > commitEntry.tier and thisEntry.enemies >= 1 then
                bot._defendCommitLane = lane
                bot._defendCommitUntil = DotaTime() + 5
            else
                return BotModeDesire.None
            end
        elseif lane ~= bestLane then
            bot._defendCommitLane = bestLane
            bot._defendCommitUntil = DotaTime() + 5
            return BotModeDesire.None
        else
            bot._defendCommitLane = bestLane
            bot._defendCommitUntil = DotaTime() + 5
        end
    elseif DotaTime() >= commitUntil then
        bot._defendCommitLane = 0
    end
    local ds = getDefendState(bot)
    ds.defendLoc = locationState.laneFronts[lane]
    local distanceToDefendLoc = GetUnitToLocationDistance(bot, ds.defendLoc)
    local botLevel = bot:GetLevel()
    if bot:GetAssignedLane() ~= lane and distanceToDefendLoc > 3000 and (Fu.GetPosition(bot) == 1 and botLevel < 7 or Fu.GetPosition(bot) == 2 and botLevel < 7 or Fu.GetPosition(bot) == 3 and botLevel < 6 or Fu.GetPosition(bot) == 4 and botLevel < 4 or Fu.GetPosition(bot) == 5 and botLevel < 4) then
        return BotModeDesire.None
    end
    if botLevel < 3 then
        return BotModeDesire.None
    end
    if gameState.isLaningPhase and bot:GetAssignedLane() == lane then
        local enemiesNearHub = Fu.GetLastSeenEnemiesNearLoc(ds.defendLoc, 1200)
        if #enemiesNearHub <= 1 then
            return BotModeDesire.None
        end
    end
    local teamIsPushing = false
    local botMode = bot:GetActiveMode()
    local botIsPushing = botMode == BotMode.PushTowerTop or botMode == BotMode.PushTowerMid or botMode == BotMode.PushTowerBot
    if botIsPushing then
        local nInRangeAlly = Fu.GetAlliesNearLoc(
            bot:GetLocation(),
            1600
        )
        local nInRangeEnemy = Fu.GetLastSeenEnemiesNearLoc(
            bot:GetLocation(),
            1400
        )
        if #nInRangeAlly >= #nInRangeEnemy then
            local pushingNearbyAllies = 0
            for ____, ally in ipairs(nInRangeAlly) do
                if Fu.IsValidHero(ally) and ally:GetActiveMode() == botMode then
                    pushingNearbyAllies = pushingNearbyAllies + 1
                    if pushingNearbyAllies >= 3 then
                        teamIsPushing = true
                        break
                    end
                end
            end
        end
    end
    local recentlyHit = bot:WasRecentlyDamagedByAnyHero(5) or bot:WasRecentlyDamagedByTower(5)
    local threatenedLane = GetThreatenedLane()
    local enemiesOnHG = gameState.enemiesOnHG
    local enemiesAtAncient = gameState.enemiesAtAncient
    if teamIsPushing and enemiesOnHG < 2 then
        return BotModeDesire.None
    end
    local ancientDyingEarly = ancient and ancient:IsAlive() and gameState.ancientHP < 0.4
    local hopelessFight = not ancientDyingEarly and gameState.aliveEnemyCount >= 3 and gameState.aliveEnemyCount > gameState.aliveAllyCount + 1
    local HOPELESS_DESIRE = MAX_DESIRE_CAP * 0.5
    if enemiesOnHG >= 1 then
        local nearbyEnemies = Fu.GetLastSeenEnemiesNearLoc(
            bot:GetLocation(),
            2000
        )
        if #nearbyEnemies >= 2 then
            local nearbyAllyHeroes = 0
            for ____, a in ipairs(Fu.GetAlliesNearLoc(
                bot:GetLocation(),
                1600
            )) do
                if Fu.IsValidHero(a) and a ~= bot then
                    nearbyAllyHeroes = nearbyAllyHeroes + 1
                end
            end
            local weAreStronger = Fu.WeAreStronger(bot, 2500)
            if not weAreStronger and #nearbyEnemies >= nearbyAllyHeroes then
                return lane == threatenedLane and MAX_DESIRE_CAP * 0.2 or MAX_DESIRE_CAP * 0.1
            end
        end
    end
    local panic = {active = false, floor = 0}
    if ancient and ancient:IsAlive() then
        local ancientHP = gameState.ancientHP
        local defenderCount = gameState.defendersAtAncient
        local panicFloor = lane == threatenedLane and (hopelessFight and HOPELESS_DESIRE or MAX_DESIRE_CAP) or (hopelessFight and HOPELESS_DESIRE * 0.7 or MAX_DESIRE_CAP * 0.7)
        local panicFloorCreeps = lane == threatenedLane and MAX_DESIRE_CAP * 0.9 or MAX_DESIRE_CAP * 0.6
        if enemiesAtAncient >= 2 or enemiesAtAncient >= 1 and ancientHP < 0.95 then
            local neededDefenders = enemiesAtAncient + 1
            if defenderCount < neededDefenders then
                baseThreatUntil = DotaTime() + BASE_THREAT_HOLD
                panic = {
                    active = true,
                    floor = panicFloor,
                    forceLoc = Fu.AdjustLocationWithOffsetTowardsFountain(
                        ancient:GetLocation(),
                        300
                    )
                }
                if lane == threatenedLane then
                    bot.laneToDefend = lane
                end
            end
        elseif ancientHP < 0.95 and enemiesAtAncient == 0 and defenderCount == 0 then
            local pos = Fu.GetPosition(bot)
            local closestPos = GetClosestAllyPos(
                {4, 5, 3},
                ancient:GetLocation()
            )
            if pos == closestPos then
                panic = {
                    active = true,
                    floor = panicFloorCreeps,
                    forceLoc = Fu.AdjustLocationWithOffsetTowardsFountain(
                        ancient:GetLocation(),
                        300
                    )
                }
                if lane == threatenedLane then
                    bot.laneToDefend = lane
                end
            end
        end
    end
    if enemiesOnHG >= 2 and not recentlyHit then
        baseThreatUntil = DotaTime() + BASE_THREAT_HOLD
        local hgFloor = hopelessFight and HOPELESS_DESIRE or (lane == threatenedLane and MAX_DESIRE_CAP or MAX_DESIRE_CAP * 0.7)
        local forceLoc = ancient and Fu.AdjustLocationWithOffsetTowardsFountain(
            ancient:GetLocation(),
            300
        ) or ds.defendLoc
        if not panic.active then
            panic = {active = true, floor = hgFloor, forceLoc = forceLoc}
        else
            panic.floor = math.max(panic.floor, hgFloor)
        end
        if lane == threatenedLane then
            bot.laneToDefend = lane
        end
    end
    local isBaseThreatActive = IsBaseThreatActive()
    if ancient then
        if enemiesAtAncient >= 1 then
            baseThreatUntil = DotaTime() + BASE_THREAT_HOLD
        elseif isBaseThreatActive then
            local creepWeight = WeightedEnemiesAroundLocation(
                ancient:GetLocation(),
                BASE_THREAT_RADIUS
            )
            if creepWeight >= 2 then
                baseThreatUntil = DotaTime() + 1.5
            end
        end
    end
    if panic.active and panic.forceLoc then
        ds.defendLoc = panic.forceLoc
    elseif isBaseThreatActive and ancient and lane == threatenedLane then
        ds.defendLoc = Fu.AdjustLocationWithOffsetTowardsFountain(
            ancient:GetLocation(),
            300
        )
    end
    if isBaseThreatActive then
        if lane ~= threatenedLane then
            bot._defendDesireHalved = true
        end
    else
        if Fu.Utils.GetLocationToLocationDistance(gameState.teamFountainTpPoint, ds.defendLoc) < 3000 then
            local enemyLaneFront = locationState.enemyLaneFronts[lane]
            local eNear = Fu.GetLastSeenEnemiesNearLoc(enemyLaneFront, 1600)
            local aNear = Fu.GetAlliesNearLoc(enemyLaneFront, 1600)
            if GetUnitToLocationDistance(bot, enemyLaneFront) > bot:GetAttackRange() and #eNear <= #aNear + 1 then
                ds.defendLoc = enemyLaneFront
            end
        end
    end
    ds.distanceToLane[lane] = GetUnitToLocationDistance(bot, ds.defendLoc)
    ds.nInRangeAlly = Fu.GetNearbyHeroes(bot, 1600, false, BotMode.None)
    ds.nInRangeEnemy = Fu.GetLastSeenEnemiesNearLoc(
        bot:GetLocation(),
        1600
    )
    ds.weAreStronger = Fu.WeAreStronger(bot, 2500)
    local pos = Fu.GetPosition(bot)
    local bMyLane = bot:GetAssignedLane() == lane
    if not bMyLane and pos == 1 and gameState.isLaningPhase or Fu.IsDoingRoshan(bot) and #Fu.GetAlliesNearLoc(
        Fu.GetCurrentRoshanLocation(),
        2800
    ) >= 3 or Fu.IsDoingTormentor(bot) and (#Fu.GetAlliesNearLoc(
        Fu.GetTormentorLocation(team),
        1600
    ) >= 2 or #Fu.GetAlliesNearLoc(
        Fu.GetTormentorWaitingLocation(team),
        2500
    ) >= 2) and enemiesAtAncient == 0 then
        return BotModeDesire.None
    end
    local pingFloor = 0
    local human, humanPing = Fu.GetHumanPing()
    if human and humanPing and not humanPing.normal_ping and DotaTime() > 0 then
        local isPinged, pingedLane = Fu.IsPingCloseToValidTower(gameState.team, humanPing, 800, 5)
        if isPinged and lane == pingedLane and GameTime() < humanPing.time + PING_DELTA then
            bot.laneToDefend = lane
            pingFloor = MAX_DESIRE_CAP
        end
    end
    local furthestBuilding, _urgentMul, buildingTier = unpack(____exports.GetFurthestBuildingOnLane(lane))
    if not IsValidBuildingTarget(furthestBuilding) then
        return BotModeDesire.None
    end
    if buildingTier >= 4 and ancient and ancient:IsAlive() and enemiesAtAncient >= 2 then
        if hopelessFight then
            return HOPELESS_DESIRE
        end
        return lane == threatenedLane and MAX_DESIRE_CAP or MAX_DESIRE_CAP * 0.7
    end
    local distToBuilding = GetUnitToUnitDistance(bot, furthestBuilding)
    local walkTime = distToBuilding / math.max(
        1,
        bot:GetCurrentMovementSpeed()
    )
    local tp = Fu.Utils.GetItemFromFullInventory(bot, "item_tpscroll")
    local hasTp = Fu.CanCastAbility(tp)
    local hasNPTeleport = Fu.CanCastAbility(bot:GetAbilityByName("furion_teleportation"))
    local hasTinkerTP = Fu.CanCastAbility(bot:GetAbilityByName("tinker_keen_teleport"))
    local canGetThereFast = hasTp or hasNPTeleport or hasTinkerTP or walkTime <= 11
    local shouldDef = ____exports.ShouldDefend(bot, furthestBuilding, 1600)
    if not shouldDef then
        local nearEnemiesAtBuilding = Fu.GetLastSeenEnemiesNearLoc(
            furthestBuilding:GetLocation(),
            1200
        )
        if not canGetThereFast and #nearEnemiesAtBuilding == 0 or #nearEnemiesAtBuilding == 0 and #Fu.GetAlliesNearLoc(
            furthestBuilding:GetLocation(),
            1600
        ) >= 1 then
            return BotModeDesire.None
        end
    end
    local hub = IsValidBuildingTarget(furthestBuilding) and furthestBuilding:GetLocation() or GetLaneFrontLocation(nTeam, lane, 0)
    local lEnemies = Fu.GetLastSeenEnemiesNearLoc(hub, 2500)
    local nDefendAllies = Fu.GetAlliesNearLoc(hub, 2500)
    local nEffAllies = #nDefendAllies + #Fu.Utils.GetAllyIdsInTpToLocation(hub, 2500)
    local botPos = Fu.GetPosition(bot)
    local distToHub = GetUnitToLocationDistance(bot, hub)
    local hasTpScroll = Fu.CanCastAbility(Fu.Utils.GetItemFromFullInventory(bot, "item_tpscroll"))
    local isHighTier = buildingTier >= 3
    if #lEnemies == 0 and not panic.active then
        if isHighTier and shouldDef and nEffAllies == 0 then
            local creepWeight = WeightedEnemiesAroundLocation(hub, 1600)
            if creepWeight >= 2 then
                local closestDefPos = GetClosestAllyPos({4, 5, 3}, hub)
                if botPos == closestDefPos then
                    return 0.4
                end
            end
        end
        return BotModeDesire.None
    end
    local neededTotal = #lEnemies + 2
    local stillNeeded = neededTotal - nEffAllies
    if isHighTier and #lEnemies >= 3 and not panic.active then
        local thisBotsContribution = (distToHub < 3000 or hasTpScroll) and 1 or 0
        local realisticForce = nEffAllies + thisBotsContribution
        if #lEnemies > realisticForce + 1 then
            local ancientDying = ancient and ancient:IsAlive() and gameState.ancientHP < 0.4
            if not ancientDying then
                return MAX_DESIRE_CAP * 0.3
            end
        end
    end
    if stillNeeded <= 0 and not panic.active then
        if distToHub > 2000 then
            return BotModeDesire.None
        end
    end
    local alliesAlreadyDefending = #nDefendAllies
    if alliesAlreadyDefending < 3 then
        if stillNeeded > 0 and stillNeeded < 5 then
            local enRouteCloser = 0
            for ____, member in ipairs(GetUnitList(UnitType.AlliedHeroes)) do
                if member ~= nil and member:IsAlive() and member ~= bot and not member:IsIllusion() then
                    local memberDist = GetUnitToLocationDistance(member, hub)
                    if memberDist > 2500 and memberDist < distToHub - 500 then
                        enRouteCloser = enRouteCloser + 1
                    end
                end
            end
            if enRouteCloser >= stillNeeded then
                return BotModeDesire.None
            end
        end
    end
    if #lEnemies >= 4 or alliesAlreadyDefending >= 3 then
    elseif not isHighTier then
        if distToHub > 4000 then
            for ____, otherLane in ipairs({Lane.Top, Lane.Mid, Lane.Bot}) do
                do
                    local __continue227
                    repeat
                        if otherLane == lane then
                            __continue227 = true
                            break
                        end
                        local otherHub = GetLaneFrontLocation(nTeam, otherLane, 0)
                        local otherDist = GetUnitToLocationDistance(bot, otherHub)
                        local otherEnemies = Fu.GetLastSeenEnemiesNearLoc(otherHub, 2500)
                        if #otherEnemies >= 1 and otherDist < distToHub - 1500 then
                            return BotModeDesire.None
                        end
                        __continue227 = true
                    until true
                    if not __continue227 then
                        break
                    end
                end
            end
        end
    end
    if gameState.isLaningPhase and buildingTier == 2 and #lEnemies <= 1 and not panic.active then
        local allHealthy = true
        for ____, enemy in ipairs(lEnemies) do
            if Fu.IsValidHero(enemy) and Fu.GetHP(enemy) < 0.8 then
                allHealthy = false
                break
            end
        end
        if allHealthy and Fu.GetHP(bot) > 0.8 then
            return BotModeDesire.None
        end
    end
    local nDefendDesire = RemapValClamped(
        GetDefendLaneDesire(lane),
        0,
        1,
        0,
        0.7
    )
    local bDefendingOtherLane = IsDefendingOtherLane(bot, lane)
    if buildingTier <= 1 then
        if bDefendingOtherLane then
            return BotModeDesire.None
        end
        local hp = IsValidBuildingTarget(furthestBuilding) and Fu.GetHP(furthestBuilding) or 1
        if hp < 0.25 and #lEnemies > 0 or not canGetThereFast then
            return BotModeDesire.None
        end
    elseif buildingTier == 2 then
        if bDefendingOtherLane then
            return BotModeDesire.None
        end
        local hp = IsValidBuildingTarget(furthestBuilding) and Fu.GetHP(furthestBuilding) or 1
        if hp < 0.25 and #lEnemies > 0 or not canGetThereFast then
            return BotModeDesire.None
        end
        nDefendDesire = nDefendDesire * 3
    else
        nDefendDesire = nDefendDesire * 5
    end
    if panic.active then
        nDefendDesire = math.max(nDefendDesire, panic.floor)
    end
    if pingFloor > 0 then
        nDefendDesire = math.max(nDefendDesire, pingFloor)
    end
    if (#lEnemies >= 4 or alliesAlreadyDefending >= 3) and not hopelessFight then
        nDefendDesire = math.max(nDefendDesire, MAX_DESIRE_CAP)
    end
    ConsiderPingedDefend(
        bot,
        lane,
        nDefendDesire,
        furthestBuilding,
        buildingTier,
        nEffAllies,
        #lEnemies
    )
    if nDefendDesire > MAX_DESIRE_CAP * 0.8 then
        Fu.Utils.GameStates = Fu.Utils.GameStates or ({})
        Fu.Utils.GameStates.recentDefendTime = DotaTime()
    end
    local dld = bot.DefendLaneDesire
    dld[lane] = nDefendDesire
    local dTop = dld[Lane.Top] or 0
    local dMid = dld[Lane.Mid] or 0
    local dBot = dld[Lane.Bot] or 0
    local maxDesire = math.max(dTop, dMid, dBot)
    if maxDesire < 0.1 then
        bot.laneToDefend = nil
    else
        bot.laneToDefend = dTop >= dMid and dTop >= dBot and Lane.Top or (dMid >= dBot and Lane.Mid or Lane.Bot)
    end
    if distToHub < 1200 and not panic.active then
        nDefendDesire = math.min(nDefendDesire, 0.55)
    end
    if distToHub < 900 and not panic.active then
        local nearbyEnemies = Fu.GetLastSeenEnemiesNearLoc(
            bot:GetLocation(),
            1200
        )
        if #nearbyEnemies > 0 then
            nDefendDesire = nDefendDesire * 0.5
        end
    end
    if bot._defendDesireHalved then
        nDefendDesire = nDefendDesire * 0.5
        bot._defendDesireHalved = false
    end
    do
        local dTop = GetUnitToLocationDistance(bot, locationState.laneFronts[Lane.Top])
        local dMid = GetUnitToLocationDistance(bot, locationState.laneFronts[Lane.Mid])
        local dBot2 = GetUnitToLocationDistance(bot, locationState.laneFronts[Lane.Bot])
        local closestLane = Lane.Mid
        if dTop < dMid and dTop < dBot2 then
            closestLane = Lane.Top
        elseif dBot2 < dMid and dBot2 < dTop then
            closestLane = Lane.Bot
        end
        if closestLane == lane and nDefendDesire > 0 and nDefendDesire < 0.35 then
            nDefendDesire = math.max(0.05, nDefendDesire)
        end
    end
    return math.min(
        math.max(nDefendDesire, 0),
        MAX_DESIRE_CAP
    )
end
okLoc, Localization = pcall(
    require,
    GetScriptDirectory() .. "/FuncLib/systems/localization"
)
if not okLoc then
    Localization = {Get = function(_) return "Defend here!" end}
end
local Customize = require(GetScriptDirectory().."/FuncLib/systems/custom_loader")
Customize.ThinkLess = Customize.Enable and Customize.ThinkLess or 1
PING_DELTA = 5
local SEARCH_RANGE_DEFAULT = 1600
MAX_DESIRE_CAP = 0.6
BASE_THREAT_RADIUS = 2600
BASE_THREAT_HOLD = 4
CACHE_ENEMY_AROUND_LOC_HZ = 0.35
CACHE_LASTSEEN_WINDOW = 5
nTeam = GetTeam()
_threatLaneSticky = {lane = Lane.Mid, ["until"] = -1}
baseThreatUntil = -1
fTraveBootsDefendTime = 0
_cacheEnemyAroundLoc = {}
DEFEND_CACHE_TTL = 0.5
defendGameStateCache = nil
defendLocationStateCache = nil
defendUnitStateCache = nil
function ____exports.GetDefendDesire(bot, lane)
    if bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not __TS__StringIncludes(
        bot:GetUnitName(),
        "hero"
    ) or bot:IsIllusion() then
        return BotModeDesire.None
    end
    local res = math.min(
        ____exports.GetDefendDesireHelper(bot, lane),
        1
    )
    local defendLoc = getDefendState(bot).defendLoc or GetLaneFrontLocation(nTeam, lane, 0)
    local alliesHere = Fu.GetAlliesNearLoc(defendLoc, 2000)
    local enemiesHere = Fu.GetEnemiesNearLoc(defendLoc, 2000)
    local teamStronger = #alliesHere >= 3 and #enemiesHere >= 1 and #alliesHere > #enemiesHere and Fu.WeAreStronger(bot, 2500)
    if teamStronger and res < 0.9 then
        res = math.min(res, 0.55)
    end
    local gsForNear = updateDefendGameStateCache()
    local baseUnderSiege = gsForNear.enemiesAtAncient >= 1 or gsForNear.enemiesOnHG >= 2
    if not baseUnderSiege then
        local botLocForNear = bot:GetLocation()
        local botAtkRangeForNear = bot:GetAttackRange()
        local scanRange = math.max(1600, botAtkRangeForNear)
        for ____, e in ipairs(Fu.GetLastSeenEnemiesNearLoc(botLocForNear, scanRange)) do
            do
                local __continue139
                repeat
                    if not Fu.IsValidHero(e) then
                        __continue139 = true
                        break
                    end
                    local dist = GetUnitToUnitDistance(bot, e)
                    if dist <= 1200 or dist <= botAtkRangeForNear or dist <= 1600 and dist <= e:GetAttackRange() then
                        res = res * 0.1
                        break
                    end
                    __continue139 = true
                until true
                if not __continue139 then
                    break
                end
            end
        end
    end
    bot.defendDesire = res
    return res
end
function ____exports.DefendThink(bot, lane)
    if Fu.CanNotUseAction(bot) then
        return
    end
    local ds = getDefendState(bot)
    if not ds.defendLoc then
        ds.defendLoc = GetLaneFrontLocation(nTeam, lane, 0)
    end
    local botLocation = bot:GetLocation()
    local safeRally = Fu.AdjustLocationWithOffsetTowardsFountain(ds.defendLoc, 300)
    local bCanTPDefend = not Fu.IsInLaningPhase() or Fu.GetExpectedLane(bot) == lane
    if bCanTPDefend and not bot._roshDipActive and ConsiderTPToTarget(bot, ds.defendLoc, true) then
        return
    end
    local distToDefend = GetUnitToLocationDistance(bot, ds.defendLoc)
    if distToDefend > 2000 then
        local midpoint = Vector((botLocation.x + ds.defendLoc.x) / 2, (botLocation.y + ds.defendLoc.y) / 2, 0)
        local enemiesOnPath = Fu.GetLastSeenEnemiesNearLoc(midpoint, 1200)
        if #enemiesOnPath >= 1 then
            local dx = ds.defendLoc.x - botLocation.x
            local dy = ds.defendLoc.y - botLocation.y
            local len = math.max(
                1,
                math.sqrt(dx * dx + dy * dy)
            )
            local perpX = -dy / len * 1200
            local perpY = dx / len * 1200
            local fountainLoc = nTeam == Team.Radiant and RadiantFountainTpPoint or DireFountainTpPoint
            local sideA = Vector(midpoint.x + perpX, midpoint.y + perpY, 0)
            local sideB = Vector(midpoint.x - perpX, midpoint.y - perpY, 0)
            local detour = GetLocationToLocationDistance(sideA, fountainLoc) < GetLocationToLocationDistance(sideB, fountainLoc) and sideA or sideB
            do
                local shrink = 1
                while shrink >= 0.2 do
                    local tryLoc = Vector(midpoint.x + (detour.x - midpoint.x) * shrink, midpoint.y + (detour.y - midpoint.y) * shrink, 0)
                    if IsLocationPassable(tryLoc) then
                        detour = tryLoc
                        break
                    end
                    shrink = shrink - 0.2
                end
            end
            bot:Action_MoveToLocation(detour)
            return
        end
    end
    local pathEnemies = Fu.GetLastSeenEnemiesNearLoc(botLocation, 1600)
    if bot:WasRecentlyDamagedByAnyHero(5) and #pathEnemies > #ds.nInRangeEnemy then
        bot:Action_MoveToLocation(add(
            safeRally,
            Fu.RandomForwardVector(100)
        ))
        return
    end
    if IsBaseThreatActive() then
        local threatBld = unpack(____exports.GetFurthestBuildingOnLane(lane))
        local ancient = GetAncient(nTeam)
        local anchorUnit = IsValidBuildingTarget(threatBld) and threatBld or ancient
        local anchorLoc = anchorUnit:GetLocation()
        local anchor = Fu.AdjustLocationWithOffsetTowardsFountain(anchorLoc, 200)
        local enemiesNear = Fu.GetEnemiesNearLoc(anchorLoc, 1600)
        if Fu.IsValidHero(enemiesNear[1]) and Fu.IsInRange(bot, enemiesNear[1], 1600) then
            bot:Action_AttackUnit(enemiesNear[1], true)
            return
        end
        local distToAnchor = GetUnitToLocationDistance(bot, anchorLoc)
        if distToAnchor > 1200 then
            bot:Action_MoveToLocation(add(
                anchor,
                Fu.RandomForwardVector(200)
            ))
            return
        end
        bot:Action_AttackMove(add(
            anchorLoc,
            Fu.RandomForwardVector(300)
        ))
        return
    end
    local attackRange = bot:GetAttackRange()
    local nSearchRange = attackRange < 900 and 900 or math.min(attackRange, SEARCH_RANGE_DEFAULT)
    if not ds.defendLoc then
        ds.defendLoc = GetLaneFrontLocation(nTeam, lane, 0)
    end
    local bld, _, buildingTier = unpack(____exports.GetFurthestBuildingOnLane(lane))
    local hub = ds.defendLoc
    if IsValidBuildingTarget(bld) then
        hub = bld:GetLocation()
    end
    if not hub then
        hub = GetLaneFrontLocation(nTeam, lane, 0)
    end
    local ancient = GetAncient(nTeam)
    local ancientLoc = ancient ~= nil and ancient:GetLocation() or hub
    if Fu.Utils.GetLocationToLocationDistance(hub, ancientLoc) < 2000 then
        if IsValidBuildingTarget(bld) then
            hub = bld:GetLocation()
        else
            hub = GetHighGroundEdgeWaitPoint(nTeam, lane)
        end
    end
    do
        local ancientForCut = GetAncient(nTeam)
        if ancientForCut ~= nil then
            local ancientLocForCut = ancientForCut:GetLocation()
            local cutters = Fu.GetEnemiesNearLoc(ancientLocForCut, 2500)
            if #cutters > 0 and Fu.Utils.GetLocationToLocationDistance(hub, ancientLocForCut) > 2000 then
                local cutter = cutters[1]
                if Fu.IsValidHero(cutter) and Fu.CanBeAttacked(cutter) then
                    local distToCutter = GetUnitToUnitDistance(bot, cutter)
                    if distToCutter < 2500 then
                        bot:Action_AttackUnit(cutter, true)
                        return
                    else
                        bot:Action_MoveToLocation(cutter:GetLocation())
                        return
                    end
                end
            end
        end
    end
    if buildingTier >= 3 then
        local edgeInside = GetHighGroundEdgeWaitPoint(nTeam, lane)
        local enemyAtHG = updateDefendGameStateCache().enemiesOnHG
        local nearEdgeEnemies = Fu.GetLastSeenEnemiesNearLoc(edgeInside, 1200)
        local nearEdgeAllies = Fu.GetAlliesNearLoc(edgeInside, 1400)
        if enemyAtHG == 0 and #nearEdgeEnemies > 0 and #nearEdgeAllies >= #nearEdgeEnemies + 1 then
            local attackMoveLoc = add(
                edgeInside,
                Fu.RandomForwardVector(120)
            )
            bot:Action_AttackMove(attackMoveLoc)
        else
            local deeper = Fu.AdjustLocationWithOffsetTowardsFountain(edgeInside, 200)
            local attackMoveLoc = add(
                deeper,
                Fu.RandomForwardVector(120)
            )
            bot:Action_AttackMove(attackMoveLoc)
        end
        return
    end
    local enemiesAtHub = Fu.GetEnemiesNearLoc(hub, SEARCH_RANGE_DEFAULT)
    local enemyCountHere = #enemiesAtHub
    local botDistToHub = GetUnitToLocationDistance(bot, hub)
    local alliesAtHub = Fu.GetAlliesNearLoc(hub, SEARCH_RANGE_DEFAULT)
    if enemyCountHere >= 1 then
        local ancientUnit = GetAncient(nTeam)
        local ancientDying = ancientUnit and Fu.CanBeAttacked(ancientUnit) and Fu.GetHP(ancientUnit) < 0.5
        if #alliesAtHub >= enemyCountHere or ancientDying or Fu.WeAreStronger(bot, 2500) then
            if Fu.IsValidHero(enemiesAtHub[1]) and Fu.IsInRange(bot, enemiesAtHub[1], nSearchRange) then
                bot:Action_AttackUnit(enemiesAtHub[1], true)
                return
            end
            local nEnemyHeroes = bot:GetNearbyHeroes(SEARCH_RANGE_DEFAULT, true, BotMode.None)
            if Fu.IsValidHero(nEnemyHeroes[1]) and Fu.IsInRange(bot, nEnemyHeroes[1], nSearchRange) then
                bot:Action_AttackUnit(nEnemyHeroes[1], true)
                return
            end
            bot:Action_MoveToLocation(add(
                hub,
                Fu.RandomForwardVector(200)
            ))
            return
        else
            local saferPos = Fu.AdjustLocationWithOffsetTowardsFountain(hub, 400)
            bot:Action_MoveToLocation(add(
                saferPos,
                Fu.RandomForwardVector(100)
            ))
            return
        end
    end
    if enemyCountHere == 0 then
        local creeps = bot:GetNearbyCreeps(900, true)
        if creeps and #creeps > 0 then
            local best = nil
            local bestScore = -1
            for ____, c in ipairs(creeps) do
                if Fu.IsValid(c) and Fu.CanBeAttacked(c) then
                    local name = c:GetUnitName()
                    local score = c:GetAttackDamage() * c:GetAttackSpeed() * (1 - Fu.GetHP(c))
                    if __TS__StringIncludes(name, "siege") then
                        score = score + 10000
                    elseif __TS__StringIncludes(name, "shadow_shaman_ward") then
                        score = score + 9000
                    elseif __TS__StringIncludes(name, "warlock_golem") then
                        score = score + 8000
                    end
                    if score > bestScore then
                        best = c
                        bestScore = score
                    end
                end
            end
            if best then
                bot:Action_AttackUnit(best, true)
                return
            end
        end
    end
    if botDistToHub > 500 then
        bot:Action_MoveToLocation(add(
            hub,
            Fu.RandomForwardVector(200)
        ))
    else
        bot:Action_AttackMove(add(
            hub,
            Fu.RandomForwardVector(300)
        ))
    end
end
function ____exports.OnEnd()
end
return ____exports
