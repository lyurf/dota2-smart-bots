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

local function __TS__ArraySome(self, callbackfn, thisArg)
    for i = 1, #self do
        if callbackfn(thisArg, self[i], i - 1, self) then
            return true
        end
    end
    return false
end
-- End of Lua Library inline imports
local ____exports = {}
local refreshPushCache, updateGameStateCache, updateLocationStateCache, updateUnitStateCache, HasPushAdvantage, presence_adjust, GetNextEnemyBuildingOnLane, pingTimeDelta, hEnemyAncient, _pushCacheTick, _pushCacheBestLane, _pushCacheEnemiesAtAncient, _pushCacheEnemiesOnHG, _pushCacheLaneBlocked, _pushCacheDefendPingSuppressed, _pushCacheRecentDefendTime, nMaxDesire, _fiveManPushLane, _fiveManPushUntil, _isAllBotsGame, _postDefendBoost, _prevDefendDesire, POST_DEFEND_PUSH_DURATION, PUSH_CACHE_TTL, gameStateCache, locationStateCache, unitStateCache, BASE_ANC_RADIUS, _nextBuildingCache
local Fu = require(GetScriptDirectory().."/FuncLib/func_utils")
local ____dota = require(GetScriptDirectory().."/ts_libs/dota/index")
local Barracks = ____dota.Barracks
local BotMode = ____dota.BotMode
local BotModeDesire = ____dota.BotModeDesire
local DamageType = ____dota.DamageType
local Lane = ____dota.Lane
local Team = ____dota.Team
local Tower = ____dota.Tower
local UnitType = ____dota.UnitType
local ____utils = require(GetScriptDirectory().."/FuncLib/systems/utils")
local IsValidUnit = ____utils.IsValidUnit
local GetLocationToLocationDistance = ____utils.GetLocationToLocationDistance
local RadiantFountainTpPoint = ____utils.RadiantFountainTpPoint
local DireFountainTpPoint = ____utils.DireFountainTpPoint
local ____cache = require(GetScriptDirectory().."/FuncLib/systems/cache")
local getGlobalGameState = ____cache.getGlobalGameState
local getGlobalLocationState = ____cache.getGlobalLocationState
local getCachedAlliesNearLoc = ____cache.getCachedAlliesNearLoc
local getCachedEnemiesNearLoc = ____cache.getCachedEnemiesNearLoc
local autoCleanupCache = ____cache.autoCleanupCache
local ____native_2Doperators = require(GetScriptDirectory().."/ts_libs/utils/native-operators")
local add = ____native_2Doperators.add
local CK = require(GetScriptDirectory().."/FuncLib/systems/cache_keys")
function refreshPushCache(team)
    local now = GameTime()
    if math.floor(now * 10) == _pushCacheTick then
        return
    end
    _pushCacheTick = math.floor(now * 10)
    local gameState = getGlobalGameState()
    local ourAncient = gameState.ourAncient
    _pushCacheEnemiesAtAncient = ourAncient ~= nil and Fu.Utils.CountEnemyHeroesNear(
        ourAncient:GetLocation(),
        BASE_ANC_RADIUS
    ) or 0
    _pushCacheEnemiesOnHG = Fu.Utils.CountEnemyHeroesOnHighGround(team)
    _pushCacheLaneBlocked = {}
    for ____, dl in ipairs({Lane.Top, Lane.Mid, Lane.Bot}) do
        local dlFront = GetLaneFrontLocation(team, dl, 0)
        _pushCacheLaneBlocked[dl] = Fu.Utils.CountEnemyHeroesNear(dlFront, 2200) >= 2
    end
    local gs = Fu.Utils.GameStates
    _pushCacheDefendPingSuppressed = gs ~= nil and gs.defendPings ~= nil and now - gs.defendPings.pingedTime <= 5
    _pushCacheRecentDefendTime = (gs or ({})).recentDefendTime or 0
    _pushCacheBestLane = nil
end
function updateGameStateCache()
    local now = DotaTime()
    if gameStateCache and now - gameStateCache.lastUpdate < PUSH_CACHE_TTL then
        return gameStateCache
    end
    local team = GetTeam()
    local enemyTeam = GetOpposingTeam()
    local currentTime = DotaTime()
    local gameMode = GetGameMode()
    local adjustedTime = gameMode == 23 and currentTime * 2 or currentTime
    gameStateCache = {
        lastUpdate = now,
        currentTime = adjustedTime,
        gameMode = gameMode,
        team = team,
        enemyTeam = enemyTeam,
        ourAncient = GetAncient(team),
        enemyAncient = GetAncient(enemyTeam),
        aliveAllyCount = Fu.GetNumOfAliveHeroes(false),
        aliveEnemyCount = Fu.GetNumOfAliveHeroes(true),
        aliveAllyCoreCount = Fu.GetAliveCoreCount(false),
        aliveEnemyCoreCount = Fu.GetAliveCoreCount(true),
        teamNetworth = (Fu.GetInventoryNetworth()),
        enemyNetworth = select(
            2,
            Fu.GetInventoryNetworth()
        ),
        averageLevel = Fu.GetAverageLevel(false),
        hasAegis = Fu.DoesTeamHaveAegis(),
        isEarlyGame = Fu.IsEarlyGame(),
        isMidGame = Fu.IsMidGame(),
        isLateGame = Fu.IsLateGame(),
        isLaningPhase = Fu.IsInLaningPhase()
    }
    return gameStateCache
end
function updateLocationStateCache()
    local now = DotaTime()
    if locationStateCache and now - locationStateCache.lastUpdate < PUSH_CACHE_TTL then
        return locationStateCache
    end
    local team = GetTeam()
    locationStateCache = {
        lastUpdate = now,
        laneFronts = {
            [Lane.Top] = GetLaneFrontLocation(team, Lane.Top, 0),
            [Lane.Mid] = GetLaneFrontLocation(team, Lane.Mid, 0),
            [Lane.Bot] = GetLaneFrontLocation(team, Lane.Bot, 0)
        },
        teamFountain = Fu.GetTeamFountain(),
        enemyFountain = Fu.GetTeamFountain(),
        roshanLocation = Fu.GetCurrentRoshanLocation(),
        tormentorLocation = Fu.GetTormentorLocation(team),
        tormentorWaitingLocation = Fu.GetTormentorWaitingLocation(team)
    }
    return locationStateCache
end
function updateUnitStateCache()
    local now = DotaTime()
    if unitStateCache and now - unitStateCache.lastUpdate < PUSH_CACHE_TTL then
        return unitStateCache
    end
    unitStateCache = {
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
        )
    }
    return unitStateCache
end
function HasPushAdvantage(gameState)
    local aAlive = gameState.aliveAllyCount
    local eAlive = gameState.aliveEnemyCount
    if aAlive < 3 then
        return false
    end
    if aAlive >= eAlive + 2 then
        return true
    end
    if gameState.hasAegis and aAlive >= 4 then
        return true
    end
    if not gameState.isEarlyGame and aAlive >= eAlive and gameState.teamNetworth - gameState.enemyNetworth >= 8000 then
        return true
    end
    return false
end
function ____exports.GetPushDesireHelper(bot, lane)
    if bot.laneToPush == nil then
        bot.laneToPush = lane
    end
    nMaxDesire = 0.525
    autoCleanupCache()
    local gameState = getGlobalGameState()
    local locationState = getGlobalLocationState()
    local team = gameState.team
    refreshPushCache(team)
    local botActiveMode = bot:GetActiveMode()
    local bMyLane = bot:GetAssignedLane() == lane
    hEnemyAncient = gameState.enemyAncient
    if gameState.isLaningPhase and not bMyLane and Fu.IsCore(bot) then
        return BotModeDesire.None
    end
    if gameState.aliveAllyCount <= gameState.aliveEnemyCount - 2 then
        return BotModeDesire.None
    end
    if _pushCacheDefendPingSuppressed then
        return BotModeDesire.None
    end
    if _pushCacheEnemiesAtAncient >= 1 then
        return BotModeDesire.None
    end
    local bTeamAdvantage = HasPushAdvantage(gameState)
    if _pushCacheLaneBlocked[lane] and not bTeamAdvantage then
        return BotModeDesire.None
    end
    if gameState.isLaningPhase then
        do
            local i = 1
            while i <= 5 do
                local member = GetTeamMember(i)
                if member ~= nil and member:GetLevel() < 6 then
                    return BotModeDesire.None
                end
                i = i + 1
            end
        end
    end
    local nInRangeAlly = Fu.GetAlliesNearLoc(
        bot:GetLocation(),
        1600
    )
    local nInRangeEnemy = Fu.GetEnemiesNearLoc(
        bot:GetLocation(),
        1600
    )
    local nInRangeAllyCore = 0
    local nInRangeEnemyCore = 0
    for ____, ally in ipairs(nInRangeAlly) do
        if Fu.IsValidHero(ally) and Fu.IsCore(ally) then
            nInRangeAllyCore = nInRangeAllyCore + 1
        end
    end
    for ____, enemy in ipairs(nInRangeEnemy) do
        if Fu.IsValidHero(enemy) and Fu.IsCore(enemy) then
            nInRangeEnemyCore = nInRangeEnemyCore + 1
        end
    end
    if #nInRangeAlly < #nInRangeEnemy and nInRangeAllyCore < nInRangeEnemyCore or #nInRangeAlly <= 1 and #nInRangeEnemy > 0 then
        return BotModeDesire.None
    end
    if botActiveMode == BotMode.PushTowerTop then
        bot.laneToPush = Lane.Top
    elseif botActiveMode == BotMode.PushTowerMid then
        bot.laneToPush = Lane.Mid
    elseif botActiveMode == BotMode.PushTowerBot then
        bot.laneToPush = Lane.Bot
    end
    local alliesHere = getCachedAlliesNearLoc(
        bot:GetLocation(),
        1600
    )
    local enemiesHere = getCachedEnemiesNearLoc(
        bot:GetLocation(),
        1600
    )
    local enemyFountain = team == Team.Radiant and DireFountainTpPoint or RadiantFountainTpPoint
    local laneFront = GetLaneFrontLocation(team, lane, 0)
    if #alliesHere <= 1 and gameState.aliveEnemyCount >= 3 then
        return BotModeDesire.None
    end
    local isDeepPush = GetLocationToLocationDistance(laneFront, enemyFountain) < 5000
    if isDeepPush and (#alliesHere < 3 or gameState.aliveAllyCount < gameState.aliveEnemyCount) then
        nMaxDesire = math.min(nMaxDesire, 0.15)
    end
    if Fu.GetHP(bot) < 0.5 then
        nMaxDesire = math.min(nMaxDesire, 0.25)
    end
    if gameState.aliveEnemyCount >= 5 and gameState.aliveAllyCount <= gameState.aliveEnemyCount then
        nMaxDesire = math.min(nMaxDesire, 0.41)
    end
    if Fu.IsDoingRoshan(bot) and #Fu.GetAlliesNearLoc(locationState.roshanLocation, 2800) >= 3 then
        return BotModeDesire.None
    end
    local human, humanPing = Fu.GetHumanPing()
    if human ~= nil and humanPing ~= nil and not humanPing.normal_ping and DotaTime() > 0 then
        local isPinged, pingedLane = Fu.IsPingCloseToValidTower(
            GetOpposingTeam(),
            humanPing,
            700,
            5
        )
        if isPinged and lane == pingedLane and GameTime() < humanPing.time + pingTimeDelta then
            return 0.6
        end
    end
    local ourAncient = gameState.ourAncient
    if Fu.IsValidBuilding(ourAncient) and ____exports.IsHealthyInsideFountain(bot) then
        local enemiesAroundAncient = Fu.GetEnemiesNearLoc(
            ourAncient:GetLocation(),
            1000
        )
        if gameState.aliveAllyCount >= #enemiesAroundAncient and gameState.aliveAllyCoreCount >= gameState.aliveEnemyCoreCount then
            return 0.6
        end
    end
    if hEnemyAncient and GetUnitToUnitDistance(bot, hEnemyAncient) < 1000 and Fu.CanBeAttacked(hEnemyAncient) and Fu.GetHP(bot) > 0.4 and not ____exports.HasBackdoorProtect(hEnemyAncient) then
        bot:SetTarget(hEnemyAncient)
        bot:Action_AttackUnit(hEnemyAncient, true)
        return 0.6
    end
    local botTarget = bot:GetAttackTarget()
    if Fu.IsValidBuilding(botTarget) and ____exports.HasBackdoorProtect(botTarget) then
        return BotModeDesire.None
    end
    local anyBarracksDown = not Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Top) or not Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Mid) or not Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Bot)
    local barracksDownBoost = false
    if anyBarracksDown and hEnemyAncient then
        local ancientDist = GetUnitToUnitDistance(bot, hEnemyAncient)
        local alliesNearAncient = Fu.GetAlliesNearLoc(
            hEnemyAncient:GetLocation(),
            3000
        )
        if ancientDist < 3000 and #alliesNearAncient >= 2 then
            barracksDownBoost = true
        end
    end
    local aAliveCount = gameState.aliveAllyCount
    local eAliveCount = gameState.aliveEnemyCount
    if _pushCacheBestLane == nil then
        _pushCacheBestLane = ____exports.WhichLaneToPush(bot, lane)
    end
    local isCurrentLanePushLane = _pushCacheBestLane == lane
    local hasEnemyHuman = Fu.Utils.IsHumanPlayerInTeam(GetOpposingTeam())
    if hasEnemyHuman and not bTeamAdvantage then
        local nextBuilding = GetNextEnemyBuildingOnLane(lane)
        if nextBuilding == nil or not Fu.IsValidBuilding(nextBuilding) then
            return BotModeDesire.None
        end
    else
        local distToEnemyFountain = GetLocationToLocationDistance(
            bot:GetLocation(),
            enemyFountain
        )
        local isDeepInEnemyTerritory = distToEnemyFountain < 5000
        local botCurrentPushLane = bot.laneToPush
        local laneHasBarracks = Fu.Utils.IsAnyBarracksOnLaneAlive(false, lane)
        if isDeepInEnemyTerritory and lane == botCurrentPushLane and laneHasBarracks then
        elseif not isCurrentLanePushLane then
            return BotModeDesire.None
        end
    end
    local alliesPushing = 0
    local teamPlayers = GetTeamPlayers(gameState.team)
    do
        local i = 1
        while i <= #teamPlayers do
            local member = GetTeamMember(i)
            if member ~= nil and member:IsAlive() and member ~= bot then
                local memberMode = member:GetActiveMode()
                local isPushMode = memberMode == BotMode.PushTowerTop or memberMode == BotMode.PushTowerMid or memberMode == BotMode.PushTowerBot
                local nearLaneFront = GetUnitToLocationDistance(member, laneFront) < 2500
                if isPushMode or nearLaneFront then
                    alliesPushing = alliesPushing + 1
                end
            end
            i = i + 1
        end
    end
    if _isAllBotsGame == nil then
        _isAllBotsGame = not Fu.Utils.IsHumanPlayerInTeam(GetTeam())
    end
    if _isAllBotsGame and not gameState.isLaningPhase and not gameState.isEarlyGame then
        if alliesPushing >= 2 and lane == _pushCacheBestLane then
            local pushLaneFront = GetLaneFrontLocation(team, lane, 0)
            local teamFountain = team == Team.Radiant and RadiantFountainTpPoint or DireFountainTpPoint
            local distFrontToUs = GetLocationToLocationDistance(pushLaneFront, teamFountain)
            local distFrontToEnemy = GetLocationToLocationDistance(pushLaneFront, enemyFountain)
            if distFrontToEnemy < distFrontToUs then
                _fiveManPushLane = lane
                _fiveManPushUntil = DotaTime() + 8
            end
        end
        if _fiveManPushLane ~= nil and DotaTime() < _fiveManPushUntil then
            if lane == _fiveManPushLane then
                return math.max(
                    0.55,
                    RemapValClamped(
                        GetPushLaneDesire(lane),
                        0,
                        1,
                        0,
                        nMaxDesire
                    )
                )
            else
                return BotModeDesire.None
            end
        else
            _fiveManPushLane = nil
        end
    end
    local nPushDesire = RemapValClamped(
        GetPushLaneDesire(lane),
        0,
        1,
        0,
        nMaxDesire
    )
    local botLevel = bot:GetLevel()
    local botHP = Fu.GetHP(bot)
    local aAliveCoreCount = gameState.aliveAllyCoreCount
    local eAliveCoreCount = gameState.aliveEnemyCoreCount
    local bFavorableConditions = eAliveCount == 0 or aAliveCoreCount >= eAliveCoreCount or aAliveCoreCount >= 1 and aAliveCount >= eAliveCount + 2 or hEnemyAncient and GetUnitToUnitDistance(bot, hEnemyAncient) < 3500 and #alliesHere >= #enemiesHere
    if not bFavorableConditions then
        return BotModeDesire.None
    end
    if not gameState.isEarlyGame then
        if gameState.hasAegis and aAliveCount >= 4 then
            nPushDesire = nPushDesire + 0.25
            nMaxDesire = math.max(nMaxDesire, 0.6)
        end
        if aAliveCount >= eAliveCount and gameState.averageLevel >= 12 then
            local networthAdvantage = gameState.teamNetworth - gameState.enemyNetworth
            nPushDesire = nPushDesire + RemapValClamped(
                networthAdvantage,
                5000,
                10000,
                0,
                0.5
            )
        end
    end
    local readyToPush = botLevel >= 6 and (not gameState.isLaningPhase or aAliveCount >= eAliveCount + 2 or eAliveCount <= 2 and aAliveCount >= 4)
    if _pushCacheEnemiesOnHG >= 2 and DotaTime() - _pushCacheRecentDefendTime < 10 then
        return BotModeDesire.None
    end
    if hEnemyAncient and ____exports.GetLaneBuildingTier(lane) >= 2 then
        local distToEnemyAncient = GetUnitToUnitDistance(bot, hEnemyAncient)
        if distToEnemyAncient < 6000 and #alliesHere < eAliveCount and botHP < 0.8 then
            return BotModeDesire.None
        end
    end
    local result = math.min(
        math.max(nPushDesire, 0),
        nMaxDesire
    )
    local earlyPushCutoff = gameState.gameMode == 23 and 12 * 60 or 15 * 60
    if DotaTime() < earlyPushCutoff then
        local thisLaneTier = ____exports.GetLaneBuildingTier(lane)
        if thisLaneTier >= 3 then
            local deadEnemies = 5 - eAliveCount
            if deadEnemies < 2 then
                local otherLanes = lane == Lane.Top and ({Lane.Mid, Lane.Bot}) or (lane == Lane.Mid and ({Lane.Top, Lane.Bot}) or ({Lane.Top, Lane.Mid}))
                local otherT2Alive = __TS__ArraySome(
                    otherLanes,
                    function(____, l) return ____exports.GetLaneBuildingTier(l) <= 2 end
                )
                if otherT2Alive then
                    result = math.min(result, 0.1)
                end
            end
        end
    end
    if #alliesHere <= 1 and #enemiesHere >= 2 then
        result = math.min(result, 0.2)
    end
    if isDeepPush and #alliesHere >= 2 then
        local lowHPCount = 0
        local totalHP = 0
        for ____, ally in ipairs(alliesHere) do
            if Fu.IsValidHero(ally) then
                local hp = Fu.GetHP(ally)
                totalHP = totalHP + hp
                if hp < 0.4 then
                    lowHPCount = lowHPCount + 1
                end
            end
        end
        local avgHP = #alliesHere > 0 and totalHP / #alliesHere or 1
        if lowHPCount >= 2 and avgHP < 0.6 and eAliveCount >= #alliesHere - 2 then
            result = math.min(result, 0.15)
        end
    end
    if _isAllBotsGame then
        if not gameState.isLaningPhase then
            result = math.max(result, 0.02)
        end
        if readyToPush and botHP > 0.4 and not gameState.isEarlyGame then
            if eAliveCount <= 2 and aAliveCount >= 4 then
                result = math.max(result, eAliveCount == 0 and 0.525 or 0.45)
            end
            if barracksDownBoost then
                result = math.max(result, 0.5)
            end
            if bTeamAdvantage and botHP > 0.5 then
                result = math.max(result, 0.5)
            end
        end
        if isCurrentLanePushLane and Fu.GetPosition(bot) >= 4 then
            local pushModeForLane = lane == Lane.Top and BotMode.PushTowerTop or (lane == Lane.Mid and BotMode.PushTowerMid or BotMode.PushTowerBot)
            local alliesPushingThisLane = 0
            do
                local i = 1
                while i <= #GetTeamPlayers(GetTeam()) do
                    local member = GetTeamMember(i)
                    if member and member ~= bot and member:IsAlive() and member:GetActiveMode() == pushModeForLane then
                        alliesPushingThisLane = alliesPushingThisLane + 1
                    end
                    i = i + 1
                end
            end
            if alliesPushingThisLane >= 3 then
                result = math.max(result, nMaxDesire)
            end
        end
    end
    if _isAllBotsGame then
        local currentDefend = GetDefendLaneDesire(lane)
        local prevDefend = _prevDefendDesire[lane] or 0
        _prevDefendDesire[lane] = currentDefend
        if prevDefend > 0.3 and currentDefend < 0.15 then
            _postDefendBoost[lane] = DotaTime() + POST_DEFEND_PUSH_DURATION
        end
        if _postDefendBoost[lane] and DotaTime() < _postDefendBoost[lane] then
            result = math.max(result, 0.45)
        end
    end
    return result
end
function presence_adjust(score, loc)
    local allies = #Fu.GetAlliesNearLoc(loc, 1600)
    return score / (1 + 0.25 * allies)
end
function GetNextEnemyBuildingOnLane(lane)
    local tick = math.floor(GameTime() * 10)
    local cached = _nextBuildingCache[lane]
    if cached and cached.tick == tick then
        return cached.result
    end
    local enemy = GetOpposingTeam()
    local result = nil
    local towerOrder = lane == Lane.Top and ({Tower.Top1, Tower.Top2, Tower.Top3}) or (lane == Lane.Mid and ({Tower.Mid1, Tower.Mid2, Tower.Mid3}) or ({Tower.Bot1, Tower.Bot2, Tower.Bot3}))
    for ____, tid in ipairs(towerOrder) do
        local t = GetTower(enemy, tid)
        if t ~= nil and t:IsAlive() then
            result = t
            break
        end
    end
    if not result then
        local raxOrder = lane == Lane.Top and ({Barracks.TopRanged, Barracks.TopMelee}) or (lane == Lane.Mid and ({Barracks.MidRanged, Barracks.MidMelee}) or ({Barracks.BotRanged, Barracks.BotMelee}))
        for ____, rid in ipairs(raxOrder) do
            local r = GetBarracks(enemy, rid)
            if r ~= nil and r:IsAlive() then
                result = r
                break
            end
        end
    end
    if not result then
        local t4a = GetTower(enemy, Tower.Base1)
        local t4b = GetTower(enemy, Tower.Base2)
        if t4a ~= nil and t4a:IsAlive() then
            result = t4a
        elseif t4b ~= nil and t4b:IsAlive() then
            result = t4b
        end
    end
    if not result then
        local ancient = GetAncient(enemy)
        if ancient ~= nil and ancient:IsAlive() then
            result = ancient
        end
    end
    _nextBuildingCache[lane] = {tick = tick, result = result}
    return result
end
function ____exports.WhichLaneToPush(_bot, _lane)
    local locationState = updateLocationStateCache()
    local gameState = updateGameStateCache()
    local topLaneScore = 0
    local midLaneScore = 0
    local botLaneScore = 0
    local vTop = locationState.laneFronts[Lane.Top]
    local vMid = locationState.laneFronts[Lane.Mid]
    local vBot = locationState.laneFronts[Lane.Bot]
    local topBuilding = GetNextEnemyBuildingOnLane(Lane.Top)
    local midBuilding = GetNextEnemyBuildingOnLane(Lane.Mid)
    local botBuilding = GetNextEnemyBuildingOnLane(Lane.Bot)
    local teamMembers = GetUnitList(UnitType.AlliedHeroes)
    for ____, member in ipairs(teamMembers) do
        if Fu.IsValidHero(member) then
            local topDist = GetUnitToLocationDistance(member, vTop) * 0.9 * 0.6
            local midDist = GetUnitToLocationDistance(member, vMid) * 0.6
            local botDist = GetUnitToLocationDistance(member, vBot) * 0.9 * 0.6
            if topBuilding ~= nil then
                topDist = topDist + GetUnitToUnitDistance(member, topBuilding) * 0.9 * 0.4
            end
            if midBuilding ~= nil then
                midDist = midDist + GetUnitToUnitDistance(member, midBuilding) * 0.4
            end
            if botBuilding ~= nil then
                botDist = botDist + GetUnitToUnitDistance(member, botBuilding) * 0.9 * 0.4
            end
            if Fu.IsCore(member) and member and not member:IsBot() then
                topDist = topDist * 0.2
                midDist = midDist * 0.2
                botDist = botDist * 0.2
            elseif not Fu.IsCore(member) then
                topDist = topDist * 1.5
                midDist = midDist * 1.5
                botDist = botDist * 1.5
            end
            topLaneScore = topLaneScore + topDist
            midLaneScore = midLaneScore + midDist
            botLaneScore = botLaneScore + botDist
        end
    end
    local countTop = 0
    local countMid = 0
    local countBot = 0
    for ____, id in ipairs(GetTeamPlayers(gameState.enemyTeam)) do
        if IsHeroAlive(id) then
            local info = GetHeroLastSeenInfo(id)
            if info and info ~= nil then
                local dInfo = info[1]
                if dInfo and dInfo ~= nil then
                    if Fu.GetDistance(vTop, dInfo.location) <= 1600 then
                        countTop = countTop + 1
                    elseif Fu.GetDistance(vMid, dInfo.location) <= 1600 then
                        countMid = countMid + 1
                    elseif Fu.GetDistance(vBot, dInfo.location) <= 1600 then
                        countBot = countBot + 1
                    end
                end
            end
        end
    end
    local hTeleports = GetIncomingTeleports()
    for ____, tp in ipairs(hTeleports) do
        if tp and ____exports.IsEnemyTP(tp.playerid) then
            if Fu.GetDistance(vTop, tp.location) <= 1600 then
                countTop = countTop + 1
            elseif Fu.GetDistance(vMid, tp.location) <= 1600 then
                countMid = countMid + 1
            elseif Fu.GetDistance(vBot, tp.location) <= 1600 then
                countBot = countBot + 1
            end
        end
    end
    topLaneScore = topLaneScore * (0.05 * countTop + 1)
    midLaneScore = midLaneScore * (0.05 * countMid + 1)
    botLaneScore = botLaneScore * (0.05 * countBot + 1)
    local topTier = ____exports.GetLaneBuildingTier(Lane.Top)
    local midTier = ____exports.GetLaneBuildingTier(Lane.Mid)
    local botTier = ____exports.GetLaneBuildingTier(Lane.Bot)
    topLaneScore = topLaneScore * RemapValClamped(
        topTier,
        1,
        3,
        0.25,
        1
    )
    midLaneScore = midLaneScore * RemapValClamped(
        midTier,
        1,
        3,
        0.25,
        1
    )
    botLaneScore = botLaneScore * RemapValClamped(
        botTier,
        1,
        3,
        0.25,
        1
    )
    local ourTopRaxDown = not Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Top)
    local ourMidRaxDown = not Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Mid)
    local ourBotRaxDown = not Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Bot)
    if ourTopRaxDown and Fu.Utils.IsAnyBarracksOnLaneAlive(true, Lane.Top) then
        topLaneScore = topLaneScore * 0.15
    end
    if ourMidRaxDown and Fu.Utils.IsAnyBarracksOnLaneAlive(true, Lane.Mid) then
        midLaneScore = midLaneScore * 0.15
    end
    if ourBotRaxDown and Fu.Utils.IsAnyBarracksOnLaneAlive(true, Lane.Bot) then
        botLaneScore = botLaneScore * 0.15
    end
    topLaneScore = presence_adjust(topLaneScore, vTop)
    midLaneScore = presence_adjust(midLaneScore, vMid)
    botLaneScore = presence_adjust(botLaneScore, vBot)
    if topLaneScore < midLaneScore and topLaneScore < botLaneScore then
        return Lane.Top
    end
    if midLaneScore < topLaneScore and midLaneScore < botLaneScore then
        return Lane.Mid
    end
    if botLaneScore < topLaneScore and botLaneScore < midLaneScore then
        return Lane.Bot
    end
    return Lane.Mid
end
function ____exports.IsEnemyTP(nID)
    local gameState = updateGameStateCache()
    for ____, id in ipairs(GetTeamPlayers(gameState.enemyTeam)) do
        if id == nID then
            return true
        end
    end
    return false
end
--- Include micro-summons & dominated units into "nearby creeps" for push thinning
function ____exports.GetSpecialUnitsNearby(bot, hUnitList, nRadius)
    local unitState = updateUnitStateCache()
    local hCreepList = {unpack(hUnitList)}
    for ____, unit in ipairs(unitState.enemyHeroes) do
        if IsValidUnit(unit) and Fu.IsInRange(bot, unit, nRadius) then
            local s = unit:GetUnitName()
            if __TS__StringIncludes(s, "invoker_forge_spirit") or __TS__StringIncludes(s, "lycan_wolf") or __TS__StringIncludes(s, "eidolon") or __TS__StringIncludes(s, "beastmaster_boar") or __TS__StringIncludes(s, "beastmaster_greater_boar") or __TS__StringIncludes(s, "furion_treant") or __TS__StringIncludes(s, "broodmother_spiderling") or __TS__StringIncludes(s, "skeleton_warrior") or __TS__StringIncludes(s, "warlock_golem") or unit:HasModifier("modifier_dominated") or unit:HasModifier("modifier_chen_holy_persuasion") then
                hCreepList[#hCreepList + 1] = unit
            end
        end
    end
    return hCreepList
end
function ____exports.IsHealthyInsideFountain(hUnit)
    return hUnit:HasModifier("modifier_fountain_aura_buff") and Fu.GetHP(hUnit) > 0.9 and Fu.GetMP(hUnit) > 0.85
end
function ____exports.GetAllyHeroesAttackingUnit(hUnit)
    local unitState = updateUnitStateCache()
    local out = {}
    for ____, ally in ipairs(unitState.alliedHeroes) do
        if Fu.IsValidHero(ally) and not Fu.IsSuspiciousIllusion(ally) and not Fu.IsMeepoClone(ally) and ally:GetAttackTarget() == hUnit then
            out[#out + 1] = ally
        end
    end
    return out
end
function ____exports.GetAllyCreepsAttackingUnit(hUnit)
    local unitState = updateUnitStateCache()
    local out = {}
    for ____, creep in ipairs(unitState.alliedCreeps) do
        if Fu.IsValid(creep) and creep:GetAttackTarget() == hUnit then
            out[#out + 1] = creep
        end
    end
    return out
end
--- Returns 1..4 for the highest structure on that lane that is still alive on the enemy team
function ____exports.GetLaneBuildingTier(nLane)
    local gameState = updateGameStateCache()
    local enemyTeam = gameState.enemyTeam
    if nLane == Lane.Top then
        if GetTower(enemyTeam, Tower.Top1) ~= nil then
            return 1
        elseif GetTower(enemyTeam, Tower.Top2) ~= nil then
            return 2
        elseif GetTower(enemyTeam, Tower.Top3) ~= nil or GetBarracks(enemyTeam, Barracks.TopMelee) ~= nil or GetBarracks(enemyTeam, Barracks.TopRanged) ~= nil then
            return 3
        else
            return 4
        end
    elseif nLane == Lane.Mid then
        if GetTower(enemyTeam, Tower.Mid1) ~= nil then
            return 1
        elseif GetTower(enemyTeam, Tower.Mid2) ~= nil then
            return 2
        elseif GetTower(enemyTeam, Tower.Mid3) ~= nil or GetBarracks(enemyTeam, Barracks.MidMelee) ~= nil or GetBarracks(enemyTeam, Barracks.MidRanged) ~= nil then
            return 3
        else
            return 4
        end
    elseif nLane == Lane.Bot then
        if GetTower(enemyTeam, Tower.Bot1) ~= nil then
            return 1
        elseif GetTower(enemyTeam, Tower.Bot2) ~= nil then
            return 2
        elseif GetTower(enemyTeam, Tower.Bot3) ~= nil or GetBarracks(enemyTeam, Barracks.BotMelee) ~= nil or GetBarracks(enemyTeam, Barracks.BotRanged) ~= nil then
            return 3
        else
            return 4
        end
    end
    return 1
end
function ____exports.HasBackdoorProtect(target)
    return target:HasModifier("modifier_fountain_glyph") or target:HasModifier("modifier_backdoor_protection") or target:HasModifier("modifier_backdoor_protection_in_base") or target:HasModifier("modifier_backdoor_protection_active")
end
--- Returns true if the *nearest* intended target around the enemy lane-front
-- is currently backdoored/glyphed.
function ____exports.IsAnyTargetBackdooredAt(_bot, lane)
    local locationState = updateLocationStateCache()
    local unitState = updateUnitStateCache()
    local lf = locationState.laneFronts[lane]
    local nearest = nil
    local best = math.huge
    for ____, b in ipairs(unitState.enemyBuildings) do
        if Fu.IsValidBuilding(b) then
            local d = GetUnitToLocationDistance(b, lf)
            if d < best then
                nearest = b
                best = d
            end
        end
    end
    return not not (nearest and ____exports.HasBackdoorProtect(nearest))
end
local Customize = require(GetScriptDirectory().."/FuncLib/systems/custom_loader")
Customize.ThinkLess = Customize.Enable and Customize.ThinkLess or 1
pingTimeDelta = 5
hEnemyAncient = nil
_pushCacheTick = -1
_pushCacheBestLane = nil
_pushCacheEnemiesAtAncient = 0
_pushCacheEnemiesOnHG = 0
_pushCacheLaneBlocked = {}
_pushCacheDefendPingSuppressed = false
_pushCacheRecentDefendTime = 0
nMaxDesire = 0.525
_fiveManPushLane = nil
_fiveManPushUntil = 0
_isAllBotsGame = nil
_postDefendBoost = {}
_prevDefendDesire = {}
POST_DEFEND_PUSH_DURATION = 10
PUSH_CACHE_TTL = 0.5
local BOT_CACHE_TTL = 0.2
gameStateCache = nil
locationStateCache = nil
unitStateCache = nil
local botStateCache = {}
--- Update bot state cache if needed
local function updateBotStateCache(bot, targetLoc)
    local now = DotaTime()
    local botId = bot:GetPlayerID()
    local cached = botStateCache[botId]
    if cached and now - cached.lastUpdate < BOT_CACHE_TTL then
        return cached
    end
    local location = bot:GetLocation()
    local attackRange = bot:GetAttackRange()
    local gameState = updateGameStateCache()
    botStateCache[botId] = {
        lastUpdate = now,
        botId = botId,
        attackRange = attackRange,
        location = location,
        hp = Fu.GetHP(bot),
        mp = Fu.GetMP(bot),
        nearbyTowers = bot:GetNearbyTowers(1200, true),
        nearbyLaneCreeps = bot:GetNearbyLaneCreeps(1200, false),
        nearbyCreeps = bot:GetNearbyCreeps(1600, true),
        attackTarget = bot:GetAttackTarget(),
        distanceToAncient = gameState.enemyAncient and GetUnitToUnitDistance(bot, gameState.enemyAncient) or math.huge,
        distanceToTargetLoc = targetLoc and GetUnitToLocationDistance(bot, targetLoc) or 0
    }
    return botStateCache[botId]
end
--- === Objective selection stability (anti-thrash) ===
-- (kept from Lua; comments preserved)
local OBJECTIVE_STICKY_TIME = 1.2
local SWITCH_SCORE_MARGIN = 0.25
local OBJECTIVE_LEASH_RANGE = 2600
local SCORE_BARRACKS_RANGED = 0
local SCORE_BARRACKS_MELEE = 0.1
local SCORE_T3 = 0.5
local SCORE_T4 = 1.8
BASE_ANC_RADIUS = 2200
local ObjectiveState = {}
function ____exports.GetPushDesire(bot, lane)
    if bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not __TS__StringIncludes(
        bot:GetUnitName(),
        "hero"
    ) or bot:IsIllusion() then
        return BotModeDesire.None
    end
    if bot:GetLevel() < 6 then
        return BotModeDesire.None
    end
    local res = math.min(
        ____exports.GetPushDesireHelper(bot, lane),
        1
    )
    bot.pushDesire = res
    return res
end
local function UnitIsValidObjective(u)
    return not not u and Fu.IsValidBuilding(u) and Fu.CanBeAttacked(u)
end
local function UnitIsBarracks(u)
    local n = u ~= nil and u:GetUnitName() or ""
    return __TS__StringIncludes(n, "rax")
end
local function UnitIsMeleeBarracks(u)
    return UnitIsBarracks(u) and not not u and __TS__StringIncludes(
        u:GetUnitName(),
        "melee"
    )
end
local function UnitIsRangedBarracks(u)
    return UnitIsBarracks(u) and not not u and __TS__StringIncludes(
        u:GetUnitName(),
        "ranged"
    )
end
--- True when the ranged barracks partner on the same lane is already destroyed.
local function IsRangedPartnerDead(u)
    if not UnitIsMeleeBarracks(u) then
        return false
    end
    local enemy = GetOpposingTeam()
    local n = u:GetUnitName()
    local rangedPartner = nil
    if __TS__StringIncludes(n, "top") then
        rangedPartner = GetBarracks(enemy, Barracks.TopRanged)
    elseif __TS__StringIncludes(n, "mid") then
        rangedPartner = GetBarracks(enemy, Barracks.MidRanged)
    else
        rangedPartner = GetBarracks(enemy, Barracks.BotRanged)
    end
    return rangedPartner == nil or not rangedPartner:IsAlive()
end
local function UnitIsT3(u)
    return u == GetTower(
        GetOpposingTeam(),
        Tower.Top3
    ) or u == GetTower(
        GetOpposingTeam(),
        Tower.Mid3
    ) or u == GetTower(
        GetOpposingTeam(),
        Tower.Bot3
    )
end
local function UnitIsT4(u)
    return u == GetTower(
        GetOpposingTeam(),
        Tower.Base1
    ) or u == GetTower(
        GetOpposingTeam(),
        Tower.Base2
    ) or GetUnitToUnitDistance(
        u,
        GetAncient(GetOpposingTeam())
    ) < 500
end
--- Compute a score for an objective; lower is better.
-- Base priority + mild distance terms; prefer closer to the bot and to approach targetLoc.
local function UnitIsT1orT2(u)
    local enemy = GetOpposingTeam()
    return u == GetTower(enemy, Tower.Top1) or u == GetTower(enemy, Tower.Mid1) or u == GetTower(enemy, Tower.Bot1) or u == GetTower(enemy, Tower.Top2) or u == GetTower(enemy, Tower.Mid2) or u == GetTower(enemy, Tower.Bot2)
end
local SCORE_T1T2 = 0.2
local function ObjectiveScore(bot, u, targetLoc)
    if not UnitIsValidObjective(u) then
        return math.huge
    end
    local base = 2
    if UnitIsRangedBarracks(u) then
        base = SCORE_BARRACKS_RANGED
    elseif UnitIsMeleeBarracks(u) then
        base = IsRangedPartnerDead(u) and SCORE_BARRACKS_RANGED or SCORE_BARRACKS_MELEE
    elseif UnitIsT1orT2(u) then
        base = SCORE_T1T2
    elseif UnitIsT3(u) then
        base = SCORE_T3
    elseif UnitIsT4(u) then
        base = SCORE_T4
    end
    local dBot = GetUnitToUnitDistance(bot, u)
    if dBot > OBJECTIVE_LEASH_RANGE then
        return math.huge
    end
    local d1 = dBot / 2000
    local d2 = targetLoc and GetUnitToLocationDistance(u, targetLoc) / 2500 or 0
    return base + 0.35 * d1 + 0.2 * d2
end
--- Decide whether to keep current target or switch to a better one
local function SelectOrStickHGTarget(bot, lane, targetLoc)
    local pid = bot:GetPlayerID()
    ObjectiveState[pid] = ObjectiveState[pid] or ({})
    ObjectiveState[pid][lane] = ObjectiveState[pid][lane] or ({})
    local state = ObjectiveState[pid][lane]
    local now = GameTime()
    local current = state.target or nil
    if current and UnitIsValidObjective(current) and now < (state.lockUntil or 0) then
        return current
    end
    local currentScore = current and ObjectiveScore(bot, current, targetLoc) or math.huge
    local unitState = updateUnitStateCache()
    local best = nil
    local bestScore = math.huge
    for ____, b in ipairs(unitState.enemyBuildings) do
        local sc = ObjectiveScore(bot, b, targetLoc)
        if sc < bestScore then
            best = b
            bestScore = sc
        end
    end
    if current and UnitIsValidObjective(current) then
        if best and bestScore + SWITCH_SCORE_MARGIN < currentScore then
            state.target = best
            state.lockUntil = now + OBJECTIVE_STICKY_TIME
            return best
        else
            state.lockUntil = now + 0.6
            return current
        end
    end
    if best then
        state.target = best
        state.lockUntil = now + OBJECTIVE_STICKY_TIME
        return best
    end
    state.target = nil
    state.lockUntil = nil
    return nil
end
_nextBuildingCache = {}
--- Get the nearest alive friendly tower on a lane (T1→T2→T3 order)
local function _getNearestFriendlyTowerForPush(team, lane)
    local towerIds = lane == Lane.Top and ({0, 3, 6}) or (lane == Lane.Mid and ({1, 4, 7}) or ({2, 5, 8}))
    for ____, tid in ipairs(towerIds) do
        local t = GetTower(team, tid)
        if t and t:IsAlive() then
            return t
        end
    end
    return nil
end
function ____exports.PushThink(bot, lane)
    if Fu.CanNotUseAction(bot) then
        return
    end
    if Fu.TryDropTowerAggro(bot) then
        return
    end
    if Fu.TryDenyTower(bot) then
        return
    end
    if Fu.TryDenyAllyHero(bot) then
        return
    end
    local enemyFountainLoc = GetTeam() == Team.Radiant and DireFountainTpPoint or RadiantFountainTpPoint
    local botData = bot
    if GetLocationToLocationDistance(
        bot:GetLocation(),
        enemyFountainLoc
    ) < 1500 then
        botData._fountainRetreatUntil = DotaTime() + 4
        local allyCreeps = bot:GetNearbyLaneCreeps(1600, false)
        if allyCreeps and #allyCreeps >= 1 then
            local creepLoc = allyCreeps[#allyCreeps]:GetLocation()
            botData._fountainRetreatLoc = Fu.AdjustLocationWithOffsetTowardsFountain(creepLoc, 200)
        else
            botData._fountainRetreatLoc = GetLaneFrontLocation(
                GetTeam(),
                lane,
                -500
            )
        end
    end
    if botData._fountainRetreatUntil and DotaTime() <= botData._fountainRetreatUntil then
        if bot:WasRecentlyDamagedByAnyHero(1) then
        elseif botData._fountainRetreatLoc and GetUnitToLocationDistance(bot, botData._fountainRetreatLoc) > 300 then
            bot:Action_MoveToLocation(botData._fountainRetreatLoc)
            return
        else
            botData._fountainRetreatUntil = 0
        end
    end
    do
        local laneFront = GetLaneFrontLocation(
            GetTeam(),
            lane,
            0
        )
        local distToLaneFront = GetUnitToLocationDistance(bot, laneFront)
        if distToLaneFront > 2000 and not bot:WasRecentlyDamagedByAnyHero(3) then
            bot:Action_MoveToLocation(add(
                laneFront,
                RandomVector(100)
            ))
            return
        end
    end
    autoCleanupCache()
    local gameState = getGlobalGameState()
    local locationState = getGlobalLocationState()
    local botState = updateBotStateCache(bot)
    local botLocation = botState.location
    local alliesHere = getCachedAlliesNearLoc(botLocation, 1600)
    local enemiesHere = getCachedEnemiesNearLoc(botLocation, 1600)
    local botAttackRange = botState.attackRange
    local botHp = botState.hp
    local fDeltaFromFront = math.min(botHp, 0.7) * 1000 - 700 + RemapValClamped(
        botAttackRange,
        300,
        700,
        0,
        -600
    )
    local nEnemyTowers = botState.nearbyTowers
    local nAllyCreeps = botState.nearbyLaneCreeps
    if #alliesHere < #enemiesHere or ____exports.IsAnyTargetBackdooredAt(bot, lane) then
        local longestRange = 0
        for ____, enemyHero in ipairs(enemiesHere) do
            if Fu.IsValidHero(enemyHero) and not Fu.IsSuspiciousIllusion(enemyHero) then
                local r = enemyHero:GetAttackRange()
                if r > longestRange then
                    longestRange = r
                end
            end
        end
        fDeltaFromFront = -1000 - longestRange
    end
    local targetLoc = GetLaneFrontLocation(gameState.team, lane, fDeltaFromFront)
    local teamFountain = gameState.team == Team.Radiant and RadiantFountainTpPoint or DireFountainTpPoint
    if GetLocationToLocationDistance(targetLoc, teamFountain) < 3000 then
        local pushTower = _getNearestFriendlyTowerForPush(gameState.team, lane)
        if pushTower then
            targetLoc = pushTower:GetLocation()
        else
            targetLoc = GetLaneFrontLocation(gameState.team, lane, 0)
        end
    end
    local botDistToFountain = GetLocationToLocationDistance(botLocation, teamFountain)
    local targetDistToFountain = GetLocationToLocationDistance(targetLoc, teamFountain)
    if botDistToFountain > targetDistToFountain + 500 then
        if #nAllyCreeps >= 2 or #alliesHere >= 3 then
            targetLoc = botLocation
        end
    end
    if not botState.distanceToTargetLoc or math.abs(botState.distanceToTargetLoc - GetUnitToLocationDistance(bot, targetLoc)) > 50 then
        updateBotStateCache(bot, targetLoc)
    end
    if Fu.IsValidBuilding(nEnemyTowers[1]) and (nEnemyTowers[1]:GetAttackTarget() == bot or bot:WasRecentlyDamagedByTower(#nAllyCreeps <= 2 and 4 or 2)) then
        local towerRange = nEnemyTowers[1]:GetAttackRange() + 200
        local shouldRetreat = false
        if botHp < 0.6 then
            shouldRetreat = true
        else
            local nDamage = nEnemyTowers[1]:GetAttackDamage() * nEnemyTowers[1]:GetAttackSpeed() * 5 - bot:GetHealthRegen() * 5
            if bot:GetActualIncomingDamage(nDamage, DamageType.Physical) / bot:GetHealth() > 0.4 then
                shouldRetreat = true
            end
        end
        if shouldRetreat then
            local retreatLoc = Fu.AdjustLocationWithOffsetTowardsFountain(
                nEnemyTowers[1]:GetLocation(),
                towerRange
            )
            bot:Action_MoveToLocation(add(
                retreatLoc,
                RandomVector(80)
            ))
            return
        end
    end
    do
        local glyphBuilding = nEnemyTowers[1] or GetNextEnemyBuildingOnLane(lane)
        if glyphBuilding ~= nil and Fu.Utils.IsValidTower(glyphBuilding) and glyphBuilding:HasModifier("modifier_fountain_glyph") then
            local nEnemyHeroLongestAttackRange = 0
            local nearbyEnemies = Fu.GetEnemiesNearLoc(
                bot:GetLocation(),
                1600
            )
            for ____, enemyHero in ipairs(nearbyEnemies) do
                if Fu.IsValidHero(enemyHero) and not Fu.IsSuspiciousIllusion(enemyHero) then
                    local range = enemyHero:GetAttackRange()
                    if range > nEnemyHeroLongestAttackRange then
                        nEnemyHeroLongestAttackRange = range
                    end
                end
            end
            local retreatDelta = -1000 - nEnemyHeroLongestAttackRange
            local retreatLoc = GetLaneFrontLocation(
                GetTeam(),
                lane,
                retreatDelta
            )
            local enemyCreeps = bot:GetNearbyCreeps(botAttackRange + 200, true) or ({})
            if #enemyCreeps > 0 and Fu.CanBeAttacked(enemyCreeps[1]) and not enemyCreeps[1]:HasModifier("modifier_fountain_glyph") then
                bot:Action_AttackUnit(enemyCreeps[1], true)
            else
                bot:Action_MoveToLocation(add(
                    retreatLoc,
                    RandomVector(200)
                ))
            end
            return
        end
    end
    do
        local nearbyEnemyCreeps = bot:GetNearbyLaneCreeps(1200, true)
        if nearbyEnemyCreeps then
            for ____, creep in ipairs(nearbyEnemyCreeps) do
                if Fu.IsValid(creep) and creep:GetAttackTarget() == bot then
                    bot:Action_MoveToLocation(targetLoc)
                    return
                end
            end
        end
    end
    local shouldPlayInWave = #nAllyCreeps >= 1 or #alliesHere > #enemiesHere
    local enemyFountainLoc2 = gameState.team == Team.Radiant and DireFountainTpPoint or RadiantFountainTpPoint
    local distToEnemyFountain = GetLocationToLocationDistance(botLocation, enemyFountainLoc2)
    if distToEnemyFountain < 3000 or botState.distanceToAncient < 1500 then
        local isBeingTowerShot = bot:WasRecentlyDamagedByTower(3)
        local hasNoCover = #nAllyCreeps < 2 and #alliesHere < 3
        if isBeingTowerShot and hasNoCover then
            local retreatLoc = GetLaneFrontLocation(
                GetTeam(),
                lane,
                -500
            )
            bot:Action_MoveToLocation(add(
                retreatLoc,
                RandomVector(100)
            ))
            return
        end
        if distToEnemyFountain < 2000 and not bot:WasRecentlyDamagedByAnyHero(1) then
            hEnemyAncient = gameState.enemyAncient
            if hEnemyAncient and Fu.CanBeAttacked(hEnemyAncient) and not ____exports.HasBackdoorProtect(hEnemyAncient) and botState.distanceToAncient < 1000 then
                bot:Action_AttackUnit(hEnemyAncient, true)
                return
            end
            local retreatLoc = GetLaneFrontLocation(
                GetTeam(),
                lane,
                -500
            )
            bot:Action_MoveToLocation(add(
                retreatLoc,
                RandomVector(100)
            ))
            return
        end
    end
    hEnemyAncient = gameState.enemyAncient
    local alliesNearAncient = hEnemyAncient and Fu.GetAlliesNearLoc(
        hEnemyAncient:GetLocation(),
        1600
    )
    if hEnemyAncient and botState.distanceToAncient < 1000 and Fu.CanBeAttacked(hEnemyAncient) and not ____exports.HasBackdoorProtect(hEnemyAncient) and (#____exports.GetAllyHeroesAttackingUnit(hEnemyAncient) >= 3 or #____exports.GetAllyCreepsAttackingUnit(hEnemyAncient) >= 4 or hEnemyAncient:GetHealthRegen() < 20 or (alliesNearAncient and #alliesNearAncient or 0) >= 4) then
        bot:Action_AttackUnit(hEnemyAncient, true)
        return
    end
    if not shouldPlayInWave then
        local distToTarget = GetUnitToLocationDistance(bot, targetLoc)
        if distToTarget > 300 then
            bot:Action_MoveToLocation(targetLoc)
            return
        end
        local laneFront = GetLaneFrontLocation(
            GetTeam(),
            lane,
            -300
        )
        bot:Action_AttackMove(laneFront)
        return
    end
    local nRange = math.min(700 + botAttackRange, 1600)
    if hEnemyAncient and botState.distanceToAncient < 2600 then
        nRange = 1600
    end
    local nCreeps = botState.nearbyCreeps
    local creepCacheKey = CK.PUSH_SPECIAL_CREEPS + bot:GetPlayerID()
    local cachedCreeps = Fu.Utils.GetCachedVars(creepCacheKey, 0.2)
    if cachedCreeps then
        nCreeps = cachedCreeps
    else
        nCreeps = ____exports.GetSpecialUnitsNearby(bot, nCreeps, nRange)
        Fu.Utils.SetCachedVars(creepCacheKey, nCreeps)
    end
    local vTeamFountain = locationState.teamFountain
    local bTowerNearby = Fu.IsValidBuilding(nEnemyTowers[1])
    local towerDistanceToFountain = bTowerNearby and GetUnitToLocationDistance(nEnemyTowers[1], vTeamFountain) or 0
    do
        local nearbyEnemies = bot:GetNearbyHeroes(1200, true, BotMode.None) or ({})
        if #nearbyEnemies > 0 and #alliesHere >= #nearbyEnemies then
            local weakestEnemy = nil
            local weakestHP = 999999
            for ____, enemy in ipairs(nearbyEnemies) do
                if Fu.IsValidHero(enemy) and Fu.CanBeAttacked(enemy) and not Fu.IsSuspiciousIllusion(enemy) then
                    local hp = enemy:GetHealth()
                    if hp < weakestHP then
                        weakestHP = hp
                        weakestEnemy = enemy
                    end
                end
            end
            if weakestEnemy then
                bot:Action_AttackUnit(weakestEnemy, true)
                return
            end
        end
    end
    for ____, creep in ipairs(nCreeps) do
        do
            local __continue243
            repeat
                if not Fu.IsValid(creep) or not Fu.CanBeAttacked(creep) then
                    __continue243 = true
                    break
                end
                if Fu.IsTormentor(creep) or Fu.IsRoshan(creep) then
                    __continue243 = true
                    break
                end
                if bTowerNearby and GetUnitToLocationDistance(creep, vTeamFountain) >= towerDistanceToFountain + 500 then
                    __continue243 = true
                    break
                end
                bot:Action_AttackUnit(creep, true)
                return
            until true
            if not __continue243 then
                break
            end
        end
    end
    local hgTarget = SelectOrStickHGTarget(bot, lane, targetLoc)
    if hgTarget and Fu.IsValidBuilding(hgTarget) and Fu.CanBeAttacked(hgTarget) and not ____exports.HasBackdoorProtect(hgTarget) then
        if Fu.IsInRange(bot, hgTarget, botAttackRange + 150) then
            bot:Action_AttackUnit(hgTarget, true)
        else
            local approachLoc = Fu.AdjustLocationWithOffsetTowardsFountain(
                hgTarget:GetLocation(),
                botAttackRange
            )
            bot:Action_MoveToLocation(add(
                approachLoc,
                RandomVector(50)
            ))
        end
        return
    end
    local nextBuilding = GetNextEnemyBuildingOnLane(lane)
    if nextBuilding ~= nil and Fu.IsValidBuilding(nextBuilding) and Fu.CanBeAttacked(nextBuilding) and not ____exports.HasBackdoorProtect(nextBuilding) then
        local distToBuilding = GetUnitToUnitDistance(bot, nextBuilding)
        if distToBuilding <= botAttackRange + 150 then
            bot:Action_AttackUnit(nextBuilding, true)
            return
        else
            local approachLoc = Fu.AdjustLocationWithOffsetTowardsFountain(
                nextBuilding:GetLocation(),
                botAttackRange
            )
            bot:Action_MoveToLocation(approachLoc)
            return
        end
    end
    if distToEnemyFountain > 2500 then
        local nearbyEnemyHeroes = bot:GetNearbyHeroes(botAttackRange + 300, true, BotMode.None) or ({})
        for ____, enemy in ipairs(nearbyEnemyHeroes) do
            if Fu.IsValidHero(enemy) and Fu.CanBeAttacked(enemy) and not Fu.IsSuspiciousIllusion(enemy) then
                bot:Action_AttackUnit(enemy, true)
                return
            end
        end
    end
    if distToEnemyFountain < 2500 and #nAllyCreeps < 2 then
        local retreatLoc = GetLaneFrontLocation(
            GetTeam(),
            lane,
            -500
        )
        bot:Action_MoveToLocation(add(
            retreatLoc,
            RandomVector(100)
        ))
    else
        local distToTarget = GetUnitToLocationDistance(bot, targetLoc)
        if distToTarget > 300 then
            bot:Action_MoveToLocation(targetLoc)
        else
            local laneFront = GetLaneFrontLocation(gameState.team, lane, 200)
            bot:Action_AttackMove(laneFront)
        end
    end
end
function ____exports.TryClearingOtherLaneHighGround(_bot, vLocation)
    local gameState = updateGameStateCache()
    local unitState = updateUnitStateCache()
    local unitList = unitState.enemyBuildings
    local function IsValid(building)
        return Fu.IsValidBuilding(building) and Fu.CanBeAttacked(building) and not ____exports.HasBackdoorProtect(building)
    end
    local hBarrackTarget = nil
    local best = math.huge
    for ____, barrack in ipairs(unitList) do
        if IsValid(barrack) and (barrack == GetBarracks(gameState.enemyTeam, Barracks.TopMelee) or barrack == GetBarracks(gameState.enemyTeam, Barracks.TopRanged) or barrack == GetBarracks(gameState.enemyTeam, Barracks.MidMelee) or barrack == GetBarracks(gameState.enemyTeam, Barracks.MidRanged) or barrack == GetBarracks(gameState.enemyTeam, Barracks.BotMelee) or barrack == GetBarracks(gameState.enemyTeam, Barracks.BotRanged)) then
            local d = GetUnitToLocationDistance(barrack, vLocation)
            if d < best then
                hBarrackTarget = barrack
                best = d
            end
        end
    end
    if hBarrackTarget then
        return hBarrackTarget
    end
    local hTowerTarget = nil
    best = math.huge
    for ____, tower in ipairs(unitList) do
        if IsValid(tower) and (tower == GetTower(gameState.enemyTeam, Tower.Top3) or tower == GetTower(gameState.enemyTeam, Tower.Mid3) or tower == GetTower(gameState.enemyTeam, Tower.Bot3)) then
            local d = GetUnitToLocationDistance(tower, vLocation)
            if d < best then
                hTowerTarget = tower
                best = d
            end
        end
    end
    if hTowerTarget then
        return hTowerTarget
    end
    return nil
end
function ____exports.CanBeAttacked(building)
    return not not building and building:CanBeSeen() and not building:IsInvulnerable()
end
--- Estimate if staying in a tower's zone is too dangerous over fDuration seconds
function ____exports.IsInDangerWithinTower(hUnit, fThreshold, fDuration)
    local unitState = updateUnitStateCache()
    local totalDamage = 0
    for ____, enemy in ipairs(unitState.enemyHeroes) do
        if Fu.IsValid(enemy) and Fu.IsInRange(hUnit, enemy, 1600) and (enemy:GetAttackTarget() == hUnit or Fu.IsChasingTarget(enemy, hUnit)) then
            totalDamage = totalDamage + hUnit:GetActualIncomingDamage(
                enemy:GetAttackDamage() * enemy:GetAttackSpeed() * fDuration,
                DamageType.Physical
            )
        end
    end
    return totalDamage / hUnit:GetHealth() * 1.2 > fThreshold
end
function ____exports.ShouldWaitForImportantItemsSpells(_vLocation)
    return false
end
--- Picks best high-ground objective with strict priority:
--   1) Barracks: melee > ranged (closest of each class)
--   2) Tier-3 towers (closest)
--   3) Fillers/others (closest)
-- Radius is the max distance from the bot; tie-breaker favors closer to targetLoc.
function ____exports.FindBestHGTarget(bot, radius, targetLoc)
    local gameState = updateGameStateCache()
    local unitState = updateUnitStateCache()
    local function isBarracks(u)
        return __TS__StringIncludes(
            u:GetUnitName(),
            "rax"
        )
    end
    local function isMeleeBarracks(u)
        return __TS__StringIncludes(
            u:GetUnitName(),
            "melee"
        )
    end
    local function isRangedBarracks(u)
        return __TS__StringIncludes(
            u:GetUnitName(),
            "ranged"
        )
    end
    local function isT3Tower(u)
        return u == GetTower(gameState.enemyTeam, Tower.Top3) or u == GetTower(gameState.enemyTeam, Tower.Mid3) or u == GetTower(gameState.enemyTeam, Tower.Bot3)
    end
    local function isT4Tower(u)
        return u == GetTower(gameState.enemyTeam, Tower.Base1) or u == GetTower(gameState.enemyTeam, Tower.Base2)
    end
    local bestMelee = nil
    local bestMeleeD = math.huge
    local bestRanged = nil
    local bestRangedD = math.huge
    local bestT3 = nil
    local bestT3D = math.huge
    local bestT4 = nil
    local bestT4D = math.huge
    local bestOther = nil
    local bestOtherD = math.huge
    for ____, b in ipairs(unitState.enemyBuildings) do
        if Fu.IsValidBuilding(b) and Fu.CanBeAttacked(b) and not ____exports.HasBackdoorProtect(b) then
            local dBot = GetUnitToUnitDistance(bot, b)
            if dBot <= radius then
                local dLoc = targetLoc and GetUnitToLocationDistance(b, targetLoc) or 0
                if isBarracks(b) then
                    if isMeleeBarracks(b) then
                        if dBot < bestMeleeD or dBot == bestMeleeD and dLoc < (bestMelee and GetUnitToLocationDistance(bestMelee, targetLoc) or dLoc) then
                            bestMelee = b
                            bestMeleeD = dBot
                        end
                    elseif isRangedBarracks(b) then
                        if dBot < bestRangedD or dBot == bestRangedD and dLoc < (bestRanged and GetUnitToLocationDistance(bestRanged, targetLoc) or dLoc) then
                            bestRanged = b
                            bestRangedD = dBot
                        end
                    end
                elseif isT3Tower(b) then
                    if dBot < bestT3D or dBot == bestT3D and dLoc < (bestT3 and GetUnitToLocationDistance(bestT3, targetLoc) or dLoc) then
                        bestT3 = b
                        bestT3D = dBot
                    end
                elseif isT4Tower(b) then
                    if dBot < bestT4D or dBot == bestT4D and dLoc < (bestT4 and GetUnitToLocationDistance(bestT4, targetLoc) or dLoc) then
                        bestT4 = b
                        bestT4D = dBot
                    end
                else
                    if dBot < bestOtherD or dBot == bestOtherD and dLoc < (bestOther and GetUnitToLocationDistance(bestOther, targetLoc) or dLoc) then
                        bestOther = b
                        bestOtherD = dBot
                    end
                end
            end
        end
    end
    return bestMelee or bestRanged or bestT3 or bestOther
end
return ____exports
