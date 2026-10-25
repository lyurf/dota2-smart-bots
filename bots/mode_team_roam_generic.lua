local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

local Utils = require(GetScriptDirectory()..'/FuncLib/systems/utils')
local EnemyRoles = require(GetScriptDirectory()..'/FuncLib/hero/enemy_role_estimation')
local Localization = require(GetScriptDirectory()..'/FuncLib/systems/localization')
local Customize = require(GetScriptDirectory()..'/FuncLib/systems/custom_loader')
Customize.ThinkLess = Customize.Enable and Customize.ThinkLess or 1
local Fu = require(GetScriptDirectory()..'/FuncLib/func_utils')
local Item = require(GetScriptDirectory()..'/FuncLib/systems/item')
local Roles = require(GetScriptDirectory()..'/FuncLib/systems/role')
local AttackSpecialUnit = require(GetScriptDirectory()..'/FuncLib/hero/special_units')
local Hunt = require(GetScriptDirectory()..'/FuncLib/systems/hunt')
local Escort = require(GetScriptDirectory()..'/FuncLib/systems/escort')

local X = {}
local team = GetTeam()

-- ==============================
-- Runtime state
-- ==============================
local targetUnit = nil
local towerCreepMode, towerCreep = false, nil
local towerTime, towerCreepTime = 0, 0
local nTpSolt = 15

local beInitDone, IsSupport, IsHeroCore, bePvNMode = false, false, false, false
local ShouldAttackSpecialUnit = false
local lastIdleStateCheck, isInIdleState = -1, false
local ShouldHelpAlly, ShouldHelpWhenCoreIsTargeted = false, false
local ShouldFollowAlly = false
local followAllyTarget = nil
local nearbyAllies, nearbyEnemies
local ShouldPullBackFromTower = false
local pullBackLocation = nil
local pullBackUntil = 0
local PULL_BACK_HOLD = 3 -- seconds to keep pulling back after trigger

-- Pickup / swap timers
local PickedItem = nil
local minPickItemCost = 200
local ignorePickupList, tryPickCount = {}, 0
local ConsiderDroppedTime = -90
local SwappedCheeseTime   = -90
local SwappedClarityTime  = -90
local SwappedFlaskTime    = -90
local SwappedSmokeTime    = -90
local SwappedRefresherShardTime = -90
local SwappedMoonshardTime = -90
local lastCheckBotToDropTime = 0

local IsAvoidingAbilityZone = false
local bTowerDanger = false -- set in GetDesire, used in Think
local fTowerDangerUntil = 0 -- sticky timer to prevent oscillation
local TOWER_DANGER_HOLD = 2 -- seconds to keep pulling back after trigger
local vTowerDangerAwayLoc = nil

local hTargetCreep = nil

-- Target stickiness + desire clamp
local TARGET_LOCK_SEC = 1.2
local targetLockUntil = -90

local function SetStickyTarget(t)
    if t == nil then return end
    -- Don't switch targets too fast
    if targetUnit ~= nil and targetUnit ~= t and DotaTime() < targetLockUntil then
        return
    end
    targetUnit = t
    bot:SetTarget(t)
    targetLockUntil = DotaTime() + TARGET_LOCK_SEC
end

local function CapForLanePush(desire)
    -- Keep team roam from overpowering pushing — pushing with team is often more important
    -- than roaming to help one ally
    if Fu.IsPushing(bot) then
        if desire > 0.6 then return 0.5 end
    end
    if Fu.IsInLaningPhase() then
        if desire > 0.9 then return 0.72 end
    end
    return desire
end

function GetDesire()
    -- Unstuck: if bot is in a Valve-only mode for too long, take over.
    -- This MUST be before ShouldSkipBotThink — critical recovery logic.
    -- Returns RAW desire (not adjusted) to outbid Valve's mode (e.g. wisdom shrine 0.75).
    local activeMode = bot:GetActiveMode()
    -- Pre-horn shopping is normal — never preempt it. This unstuck mechanism
    -- must not fire before DotaTime > 0 or it will yank bots out of the shop.
    if DotaTime() > 0 and (
       activeMode == BOT_MODE_ITEM
    or (BOT_MODE_WISDOM_SHRINE and activeMode == BOT_MODE_WISDOM_SHRINE)
    or (BOT_MODE_LOTUS_POOL and activeMode == BOT_MODE_LOTUS_POOL))
    then
        if bot._stuckModeTime == nil then bot._stuckModeTime = DotaTime() end
        if DotaTime() - bot._stuckModeTime > 5 then
            bot._stuckUnsticking = true
            local enemies = bot:GetNearbyHeroes(1200, true, BOT_MODE_NONE) or {}
            if #enemies > 0 then
                return 0.85 -- Raw, outbids wisdom shrine 0.75
            end
            return 0.8
        end
    else
        bot._stuckModeTime = nil
        bot._stuckUnsticking = false
    end

	if ShouldSkipBotThink(GetBot()) then return 0 end

    -- Suppress team_roam when our ancient is under threat — defend takes priority
    if Fu.GetEnemiesAroundAncient(bot, 3200) > 0 then return BOT_MODE_DESIRE_NONE end

    -- Yield to retreat when on enemy HG taking tower damage
    -- Prevents 0.7 team_roam vs 0.7 retreat oscillation that kills bots
    if bot:WasRecentlyDamagedByTower(3.0) then
        local hEnemyAnc = GetAncient(GetOpposingTeam())
        if hEnemyAnc ~= nil and GetUnitToUnitDistance(bot, hEnemyAnc) < 3000 then
            return BOT_MODE_DESIRE_NONE
        end
    end

    local res = GetDesireHelper()
    res = CapForLanePush(res)

    -- Fu.Utils.SetCachedVars(cacheKey, res)
    return res
end
function GetDesireHelper()
	local nBotHP = Fu.GetHP(bot)
    ShouldFollowAlly = false
    followAllyTarget = nil
    ShouldPullBackFromTower = false
    ShouldAttackSpecialUnit = false

    if bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then
        return BOT_MODE_DESIRE_NONE
    end

    -- Pull back from enemy tower during laning: don't let bot walk past T1 into watcher mode
    -- Uses a sticky timer so bot stays back for PULL_BACK_HOLD seconds
    if Fu.IsInLaningPhase() then
        -- Check if still within hold period
        if DotaTime() < pullBackUntil and pullBackLocation ~= nil then
            ShouldPullBackFromTower = true
            return bot:GetActiveModeDesire() + 0.05
        end

        if bot:GetActiveMode() == BOT_MODE_WATCHER then
            local enemyTowers = bot:GetNearbyTowers(1000, true)
            if Fu.IsValidBuilding(enemyTowers[1]) then
                local distToTower = GetUnitToUnitDistance(bot, enemyTowers[1])
                if distToTower < 1200 then
                    ShouldPullBackFromTower = true
                    pullBackLocation = Fu.AdjustLocationWithOffsetTowardsFountain(enemyTowers[1]:GetLocation(), 1200)
                    pullBackUntil = DotaTime() + PULL_BACK_HOLD
                    return bot:GetActiveModeDesire() + 0.05
                end
            end
        end
    end

    Utils.SetFrameProcessTime(bot)
    EnemyRoles.UpdateEnemyHeroPositions()

    IsAvoidingAbilityZone = false

    bot.laneToPush   = Fu.GetMostPushLaneDesire()
    bot.laneToDefend = Fu.GetMostDefendLaneDesire()

    if DotaTime() - lastIdleStateCheck >= 1 or isInIdleState then
        isInIdleState = Fu.CheckBotIdleState()
        lastIdleStateCheck = DotaTime()
    end

    if not beInitDone then
        beInitDone = true
        bePvNMode = Fu.Role.IsPvNMode()
        IsHeroCore = Fu.IsCore(bot)
        IsSupport  = not IsHeroCore
    end

    ItemOpsDesire()

    -- Help ally: disabled during laning phase (causes bots to
    -- chase enemies and miss last hits). Only active post-laning.
    local target
    if not Fu.IsInLaningPhase() then
        target, ShouldHelpWhenCoreIsTargeted = X.ConsiderHelpWhenCoreIsTargeted()
        if ShouldHelpWhenCoreIsTargeted and Fu.IsValidHero(target) then
            local distToTarget = GetUnitToUnitDistance(bot, target)
            if distToTarget < 3000 or Fu.GetHP(target) < 0.3 then
                SetStickyTarget(target)
                targetUnit = target
                local helpDesire = RemapValClamped(distToTarget, 1000, 4000, 0.85, 0.4)
                -- Scale by bot HP: heavily suppress below 50%, zero below 25%
                return RemapValClamped(nBotHP, 0.25, 0.7, BOT_MODE_DESIRE_NONE, helpDesire)
            end
        end
    end

    nearbyAllies = Fu.GetAlliesNearLoc(bot:GetLocation(), 2200)
    nearbyEnemies = Fu.GetEnemiesNearLoc(bot:GetLocation(), 2000)

    if not Fu.IsInLaningPhase() then
        target, ShouldHelpAlly = ConsiderHelpAlly()
        if ShouldHelpAlly then
            SetStickyTarget(target)
            targetUnit = target
            -- Scale by bot HP: suppress below 50%, zero below 30%
            return RemapValClamped(nBotHP, 0.3, 0.7, BOT_MODE_DESIRE_NONE, 0.4)
        end
    end

    -- Smart Bots: help human teammates who start a fight or ping the map (FuncLib/systems/escort.lua)
    local nEscortDesire = Escort.GetDesire(bot)
    if nEscortDesire > 0 then
        hTargetCreep = nil
        return nEscortDesire
    end

    -- Smart Bots: hunt the enemy carry together when he is seen alone (see FuncLib/systems/hunt.lua)
    local nHuntDesire = Hunt.GetDesire(bot)
    if nHuntDesire > 0 then
        hTargetCreep = nil
        return nHuntDesire
    end

	-- Tower danger: boost desire above Valve's attack (0.65) so our Think can pull bot back
	-- at 1200 units from tower where it still dies
	bTowerDanger = false
	if Fu.IsLaning(bot) then
		if DotaTime() < fTowerDangerUntil and vTowerDangerAwayLoc ~= nil then
			bTowerDanger = true
			return 0.7
		end
		local eTowersDesire = bot:GetNearbyTowers(900, true)
		if Fu.IsValidBuilding(eTowersDesire[1]) then
			local towerTarget = eTowersDesire[1]:GetAttackTarget()
			local allyCreeps = bot:GetNearbyLaneCreeps(900, false)
			local btTarget = Fu.GetProperTarget(bot)
			if towerTarget == bot
			or (#allyCreeps == 0 and (bot:WasRecentlyDamagedByTower(2.0) or (Fu.IsValidHero(btTarget) and Fu.IsRecklesslyDivingTower(bot, btTarget))))
			then
				bTowerDanger = true
				vTowerDangerAwayLoc = Fu.AdjustLocationWithOffsetTowardsFountain(eTowersDesire[1]:GetLocation(), 1200)
				fTowerDangerUntil = DotaTime() + TOWER_DANGER_HOLD
				return 0.7 -- beats Valve attack (0.65), Think will move bot away
			end
		end
	end

	-- Last-hit nearby creep at absolute priority, but not when low HP (let retreat win)
	if nBotHP > 0.3 then
		hTargetCreep = X.GetLastHitCreep()
		if Fu.IsValid(hTargetCreep) and Fu.CanBeAttacked(hTargetCreep) then
			return BOT_DESIRE_OVERRIDE * 1.5
		end
	end

    if not bot:IsAlive() or bot:GetCurrentActionType() == BOT_ACTION_TYPE_DELAY then
        return BOT_MODE_DESIRE_NONE
    end

    -- Lone Druid item transfer desire (hero or bear)
    -- Peaceful time: no enemies nearby, not in fountain, not fighting
    if (botName == 'npc_dota_hero_lone_druid' or (bot.isBear and botName == 'npc_dota_hero_lone_druid_bear')) then
        local ld = Utils.GetLoneDruid(bot)
        local bearItemsMap = ld and ld.bearItemsMap
        if bearItemsMap and ld.hero and ld.bear
        and Fu.IsValidHero(ld.hero) and ld.hero:IsAlive()
        and Fu.IsValidHero(ld.bear) and ld.bear:IsAlive()
        and bot:DistanceFromFountain() > 3000
        then
            local enemies = Fu.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE) or {}
            if #enemies == 0 and not Fu.IsInTeamFight(bot, 1200) then
                -- Check if hero has items for bear
                local needsTransfer = false
                for i = 0, 8 do
                    local item = ld.hero:GetItemInSlot(i)
                    if item ~= nil and bearItemsMap[item:GetName()]
                    and ld.bear:FindItemSlot(item:GetName()) < 0 then
                        needsTransfer = true
                        break
                    end
                end
                -- Also check for dropped items from hero
                if not needsTransfer then
                    for _, d in pairs(GetDroppedItemList()) do
                        if d and d.item and d.owner == ld.hero
                        and not string.find(d.item:GetName(), 'token') then
                            needsTransfer = true
                            break
                        end
                    end
                end
                if needsTransfer then
                    bot._ldItemTransfer = true
                    return 0.6  -- moderate desire, beats laning/farm but not fight/defend
                end
            end
        end
        bot._ldItemTransfer = false
    end

    -- Lone Druid BEAR: leash enforcement and hero following.
    if bot.isBear or botName == 'npc_dota_hero_lone_druid_bear' then
        bot._bearFollowHero = false -- reset every tick
        local ld = Utils.GetLoneDruid(bot)
        local hasScepter = bot:HasModifier('modifier_item_ultimate_scepter_consumed')
            or bot:FindItemSlot('item_ultimate_scepter') >= 0

        -- Hero dead: bear is free (especially with scepter)
        if not ld or not ld.hero or not Fu.IsValidHero(ld.hero) or not ld.hero:IsAlive() then
            -- No hero to follow. Bear acts independently.
        -- Has scepter: check if hero has items to transfer, otherwise fully free
        elseif hasScepter then
            local bearItemsMap = ld.bearItemsMap
            local hasItemForBear = false
            if bearItemsMap then
                for i = 0, 8 do
                    local item = ld.hero:GetItemInSlot(i)
                    if item ~= nil and bearItemsMap[item:GetName()]
                    and bot:FindItemSlot(item:GetName()) < 0 then
                        hasItemForBear = true
                        break
                    end
                end
            end
            -- Only follow for item transfer, otherwise independent
            if hasItemForBear then
                local heroDist = GetUnitToUnitDistance(bot, ld.hero)
                if heroDist > 700 then
                    bot._bearFollowHero = true
                    return 0.5
                end
            end
        -- No scepter: enforce leash (but not when bear needs to retreat to heal)
        else
            local heroDist = GetUnitToUnitDistance(bot, ld.hero)
            local bearHP = Fu.GetHP(bot)
            -- Don't enforce leash when bear is low HP — let retreat win
            if bearHP < 0.3 then
                bot._bearFollowHero = false
            -- Emergency: at leash limit
            elseif heroDist > 990 then
                bot._bearFollowHero = true
                return 0.6
            end
            -- Hero farming/rosh: bear can't go there alone
            local heroMode = ld.hero:GetActiveMode()
            if (heroMode == BOT_MODE_FARM or heroMode == BOT_MODE_ROSHAN or heroMode == BOT_MODE_SIDE_SHOP or heroMode == BOT_MODE_WATCHER)
            and heroDist > 700 then
                bot._bearFollowHero = true
                return 0.5
            end
        end
    end

    local nDesire = AttackSpecialUnit.GetDesire(bot)
    if nDesire > 0 then
        ShouldAttackSpecialUnit = true
        return RemapValClamped(nBotHP, 0.1, 0.8, BOT_MODE_DESIRE_NONE, nDesire)
    end

    if Fu.IsInLaningPhase() and bot:HasModifier('modifier_warlock_upheaval') then
        IsAvoidingAbilityZone = true
        return BOT_ACTION_DESIRE_VERYHIGH + 0.1
    end

    if HasModifierThatNeedToAvoidEffects() then
        IsAvoidingAbilityZone = true
        return RemapValClamped(nBotHP, 0.3, 1, BOT_ACTION_DESIRE_VERYHIGH, BOT_ACTION_DESIRE_NONE)
    end

    -- BOT_MODE_LANING is intentionally excluded from this allow-list — laning mode
    -- owns last-hit/deny, team_roam shouldn't compete during the laning phase.
    if not Fu.IsFarming(bot) and not Fu.IsPushing(bot) and not Fu.IsDefending(bot)
    and not Fu.IsDoingRoshan(bot) and not Fu.IsDoingTormentor(bot)
    and bot:GetActiveMode() ~= BOT_MODE_RUNE
    and bot:GetActiveMode() ~= BOT_MODE_SECRET_SHOP
    and bot:GetActiveMode() ~= BOT_MODE_OUTPOST
    and bot:GetActiveMode() ~= BOT_MODE_WARD
    and bot:GetActiveMode() ~= BOT_MODE_ATTACK
    and bot:GetActiveMode() ~= BOT_MODE_DEFEND_ALLY
    and bot:GetActiveMode() ~= BOT_MODE_ROAM then
        return BOT_ACTION_DESIRE_NONE
    elseif #nearbyAllies >= #nearbyEnemies then
        -- Clamp Carry/Support find-target returns to VERYHIGH+0.04 (=0.64) so
        -- override values like BOT_DESIRE_OVERRIDE * 1.5 don't escape this branch.
        local kFindTargetCap = BOT_MODE_DESIRE_VERYHIGH + 0.04
        if IsHeroCore then
            local botTarget, targetDesire = X.CarryFindTarget()
            if botTarget ~= nil then
                targetUnit = botTarget
                bot:SetTarget(botTarget)
                local d = RemapValClamped(nBotHP, 0, 0.4, BOT_MODE_DESIRE_NONE, targetDesire)
                return Clamp(d, 0, kFindTargetCap)
            end
        end
        if IsSupport then
            local botTarget, targetDesire = X.SupportFindTarget()
            if botTarget ~= nil then
                targetUnit = botTarget
                bot:SetTarget(botTarget)
                local d = RemapValClamped(nBotHP, 0, 0.4, BOT_MODE_DESIRE_NONE, targetDesire)
                return Clamp(d, 0, kFindTargetCap)
            end
        end

        if bot:IsAlive() and bot:DistanceFromFountain() > 4600 then
            if towerTime ~= 0 and X.IsValid(towerCreep) and DotaTime() < towerTime + towerCreepTime then
                return BOT_MODE_DESIRE_VERYHIGH
            else
                towerTime, towerCreepMode = 0, false
            end

            towerCreepTime, towerCreep = X.ShouldAttackTowerCreep(bot)
            if towerCreepTime ~= 0 and towerCreep ~= nil then
                if towerTime == 0 then
                    towerTime = DotaTime()
                    towerCreepMode = true
                end
                bot:SetTarget(towerCreep)
                return BOT_MODE_DESIRE_VERYHIGH
            end
        end
    end

    -- Fallback: if bot has nothing to do, find the nearest ally that IS busy
    -- and follow them. This is the universal catch-all for low-desire states.
    -- if bot:IsAlive() and DotaTime() > 0 then
    --     local bestAlly = nil
    --     local bestDist = 99999
    --     for i = 1, 5 do
    --         local ally = GetTeamMember(i)
    --         if ally ~= nil and ally ~= bot
    --         and Fu.IsValidHero(ally) and ally:IsAlive()
    --         and not ally:IsIllusion()
    --         then
    --             local allyDesire = ally:GetActiveModeDesire()
    --             local allyMode = ally:GetActiveMode()
    --             -- Follow any ally with meaningful desire (> 0.1)
    --             -- Skip allies that are retreating/shopping/idle
    --             if allyDesire > 0.1
    --             and allyMode ~= BOT_MODE_RETREAT
    --             and allyMode ~= BOT_MODE_SECRET_SHOP
    --             and allyMode ~= BOT_MODE_SIDE_SHOP
    --             and allyMode ~= BOT_MODE_WATCHER
    --             then
    --                 local dist = GetUnitToUnitDistance(bot, ally)
    --                 if dist < bestDist then
    --                     bestDist = dist
    --                     bestAlly = ally
    --                 end
    --             end
    --         end
    --     end
    --     if bestAlly ~= nil then
    --         ShouldFollowAlly = true
    --         followAllyTarget = bestAlly
    --         -- Higher desire than any garbage mode (0.3 pre-adjust = 0.21 post)
    --         -- This must beat push minimum floor (0.15 * 0.7 = 0.105)
    --         return IsSupport and 0.35 or 0.3
    --     end

    --     -- No ally doing anything useful — go to the best push lane front
    --     ShouldFollowAlly = true
    --     followAllyTarget = nil
    --     return IsSupport and 0.3 or 0.25
    -- end

    return 0.0
end

function X.GetLastHitCreep()
	-- Smart Bots: supports leave last hits to an allied core in the same lane. The old check
	-- used GetTeamMember(), which only sees the bot itself in per-bot sandboxes, so supports
	-- never noticed their core and took its farm (pos 4 with 33 last hits vs pos 3 with 9).
	local nCoreShareRadius = DotaTime() < 12 * 60 and 1300 or 800
	if Fu.IsRetreating(bot)
	or (not Fu.IsCore(bot) and Fu.IsThereNonSelfCoreNearby(nCoreShareRadius))
	or Fu.IsInTeamFight(bot, 1200)
	then
		return nil
	end

	-- Smart Bots: count Quelling Blade / Battle Fury bonus damage against creeps
	local nLastHitDamage = bot:GetAttackDamage() - 1
	if bot:GetItemSlotType(bot:FindItemSlot("item_quelling_blade")) == ITEM_SLOT_TYPE_MAIN then
		nLastHitDamage = nLastHitDamage + ((bot:GetAttackRange() > 310) and 4 or 8)
	elseif bot:FindItemSlot("item_bfury") >= 0 then
		nLastHitDamage = nLastHitDamage + 15
	end

	local nEnemyTowers = bot:GetNearbyTowers(1000, true)
	local nEnemyCreeps = bot:GetNearbyCreeps(1200, true)
	for _, creep in pairs(nEnemyCreeps) do
		if Fu.IsValid(creep)
		and Fu.CanBeAttacked(creep)
		and Fu.IsInRange(bot, creep, bot:GetAttackRange() + 300)
		and not Fu.IsRoshan(creep)
		and not Fu.IsTormentor(creep)
		then
			local nDelay = Fu.GetAttackProDelayTime(bot, creep)
			if Fu.WillKillTarget(creep, nLastHitDamage, DAMAGE_TYPE_PHYSICAL, nDelay)
			and (#nEnemyTowers == 0 or (Fu.IsValidBuilding(nEnemyTowers[1]) and not Fu.IsInRange(creep, nEnemyTowers[1], 750)))
			then
				local nInRangeAlly = Fu.GetAlliesNearLoc(creep:GetLocation(), 1000)
				local nInRangeEnemy = Fu.GetEnemiesNearLoc(creep:GetLocation(), 1000)
				if #nInRangeAlly >= #nInRangeEnemy then
					return creep
				end
			end
		end
	end

	return nil
end

-- ==============================
-- Avoid zones
-- ==============================
function HasModifierThatNeedToAvoidEffects()
    return bot:HasModifier('modifier_jakiro_macropyre_burn')
        or bot:HasModifier('modifier_dark_seer_wall_slow')
        or ((bot:HasModifier('modifier_sandking_sand_storm_slow') or bot:HasModifier('modifier_sand_king_epicenter_slow'))
            and (not bot:HasModifier("modifier_black_king_bar_immune")
                or not bot:HasModifier("modifier_magic_immune")
                or not bot:HasModifier("modifier_omniknight_repel")))
end

-- ==============================
-- Desire Helpers
-- ==============================
function ConsiderHelpAlly()
    -- Don't help if we're too low — we'll just feed
    if Fu.GetHP(bot) < 0.5 then return nil, false end
    if bot:WasRecentlyDamagedByAnyHero(2.0) and Fu.GetHP(bot) < 0.6 then return nil, false end

    local nRadius = 3500
    local nModeDesire = bot:GetActiveModeDesire()
    local nClosestAlly = Fu.GetClosestAlly(bot, nRadius)

    if  nClosestAlly ~= nil
    and Fu.GetHP(bot) >= Fu.GetHP(nClosestAlly)
    and (not Fu.IsCore(bot) or (Fu.IsCore(bot) and (not Fu.IsInLaningPhase() or Fu.IsInRange(bot, nClosestAlly, 1600))))
    and not Fu.IsGoingOnSomeone(bot)
    and not (Fu.IsRetreating(bot) and nModeDesire > 0.8) then
        local nInRangeAlly = Fu.GetAlliesNearLoc(nClosestAlly:GetLocation(), 1200)
        local nInRangeEnemy = Fu.GetEnemiesNearLoc(nClosestAlly:GetLocation(), 1600)

        -- Risk check: don't walk into a fight we'd lose
        if #nInRangeEnemy > #nInRangeAlly + 1 then return nil, false end

        for _, enemyHero in pairs(nInRangeEnemy) do
            if Fu.IsValidHero(enemyHero)
            and GetUnitToUnitDistance(enemyHero, nClosestAlly) <= 1600
            and (#nInRangeAlly + 1 >= #nInRangeEnemy) then
                if (enemyHero:GetAttackTarget() == nClosestAlly or Fu.IsChasingTarget(enemyHero, nClosestAlly))
                or nClosestAlly:WasRecentlyDamagedByHero(enemyHero, 2.5) then
                    return enemyHero, true
                end
            end
        end
    end

    return nil, false
end

-- ==============================
-- Lifecycle
-- ==============================
function OnStart() end

function OnEnd()
    towerTime = 0
    towerCreepMode = false
    PickedItem = nil
    ShouldFollowAlly = false
    followAllyTarget = nil
end

-- ==============================
-- Think
-- ==============================
function Think()
    -- Unstuck action: if we took over from a stuck Valve mode, do something useful
    -- This MUST be before any skip/guard checks since it's critical recovery logic
    if bot._stuckUnsticking then
        local enemies = bot:GetNearbyHeroes(1200, true, BOT_MODE_NONE) or {}
        if #enemies > 0 and Fu.IsValidHero(enemies[1]) and Fu.CanBeAttacked(enemies[1]) then
            bot:Action_AttackUnit(enemies[1], false)
            bot._stuckModeTime = nil
            bot._stuckUnsticking = false
            return
        end
        -- No enemies — move to lane
        local lane = bot:GetAssignedLane() or LANE_MID
        bot:Action_MoveToLocation(GetLaneFrontLocation(GetTeam(), lane, 0))
        bot._stuckModeTime = nil
        bot._stuckUnsticking = false
        return
    end

    if Fu.CanNotUseAction(bot) then return end

    -- Pull back from enemy tower during laning (flag set by GetDesire)
    if ShouldPullBackFromTower and pullBackLocation ~= nil then
        bot:Action_MoveToLocation(pullBackLocation + RandomVector(50))
        return
    end

    -- Bear: follow hero, mirror hero's target
    if bot._bearFollowHero then
        local ld = Utils.GetLoneDruid(bot)
        if ld and ld.hero and Fu.IsValidHero(ld.hero) and ld.hero:IsAlive() then
            -- Mirror hero's target if available and within leash
            local heroTarget = Fu.GetProperTarget(ld.hero)
            if Fu.IsValid(heroTarget) and Fu.CanBeAttacked(heroTarget) then
                local distToTarget = GetUnitToUnitDistance(bot, heroTarget)
                local distToHero = GetUnitToUnitDistance(bot, ld.hero)
                -- Only attack if staying within leash range of hero
                if distToTarget < 1000 and distToHero < 900 then
                    bot:Action_AttackUnit(heroTarget, true)
                    return
                end
            end
            -- No target or too far: walk to hero
            bot:Action_MoveToLocation(ld.hero:GetLocation())
            return
        end
    end

    ItemOpsThink()

    -- Smart Bots: hunting the enemy carry (desire set in GetDesireHelper)
    if Escort.IsEscorting(bot) and Escort.Think(bot) then return end
    if Hunt.IsHunting(bot) and Hunt.Think(bot) then return end

	if Fu.IsValid(hTargetCreep) then
		bot:Action_AttackUnit(hTargetCreep, true)
		return
	end

	-- Validity guard only (no leash check — the desire layer chose this target,
	-- so let Think follow through and attack it).
	if targetUnit ~= nil then
		if (not Fu.Utils.IsValidUnit(targetUnit)) or (not X.CanBeAttacked(targetUnit)) then
			targetUnit = nil
		end
	end

    if IsAvoidingAbilityZone then
        bot:Action_MoveToLocation(Utils.GetOffsetLocationTowardsTargetLocation(bot:GetLocation(), Fu.GetTeamFountain(), 600) + RandomVector(200))
        return
    end

    -- Tower pull-back: flag set by GetDesire, just act on it here
    if bTowerDanger then
        if vTowerDangerAwayLoc ~= nil then
            bot:Action_MoveToLocation(vTowerDangerAwayLoc)
            return
        end
        local eTowersNearby = bot:GetNearbyTowers(900, true)
        if Fu.IsValidBuilding(eTowersNearby[1]) then
            bot:Action_MoveToLocation(Fu.AdjustLocationWithOffsetTowardsFountain(eTowersNearby[1]:GetLocation(), 900))
            return
        end
    end

    -- Lone Druid item transfer (desire was set in GetDesireHelper)
    if bot._ldItemTransfer then
        local ld = Utils.GetLoneDruid(bot)
        local bearItemsMap = ld and ld.bearItemsMap

        if bearItemsMap and ld.hero and ld.bear
        and Fu.IsValidHero(ld.hero) and Fu.IsValidHero(ld.bear) then
            -- BEAR side: pick up dropped items, walk toward hero
            if bot.isBear then
                -- Check for dropped items first
                for _, d in pairs(GetDroppedItemList()) do
                    if d and d.item and d.owner == ld.hero
                    and not string.find(d.item:GetName(), 'token') then
                        local dist = GetUnitToLocationDistance(bot, d.location)
                        if dist <= 100 then
                            bot:Action_PickUpItem(d.item)
                            return
                        elseif dist < 800 then
                            bot:Action_MoveToLocation(d.location)
                            return
                        end
                    end
                end
                -- No dropped items — walk toward hero
                local heroDist = GetUnitToUnitDistance(bot, ld.hero)
                if heroDist > 250 then
                    bot:Action_MoveToLocation(ld.hero:GetLocation())
                    return
                end
            -- HERO side: walk to bear and drop items
            else
                local bearDist = GetUnitToUnitDistance(bot, ld.bear)
                if bearDist > 400 then
                    bot:Action_MoveToLocation(ld.bear:GetLocation())
                    return
                end
                -- Adjacent — drop one item
                for i = 0, 8 do
                    local item = bot:GetItemInSlot(i)
                    if item ~= nil and bearItemsMap[item:GetName()]
                    and ld.bear:FindItemSlot(item:GetName()) < 0 then
                        bot:Action_DropItem(item, ld.bear:GetLocation())
                        return
                    end
                end
            end
        end
    end

    if ShouldAttackSpecialUnit then
        if Fu.IsValid(bot.special_unit_target) then
            bot:Action_AttackUnit(bot.special_unit_target, false)
            return
        end
    end

    if towerCreepMode then
        bot:Action_AttackUnit(towerCreep, false)
        return
    end

    if isInIdleState then
        isInIdleState = Fu.CheckBotIdleState()
    end

    -- Attack target (HP/risk gating handled by GetDesire — ConsiderHelp* functions
    -- reject low-HP and outnumbered scenarios, so Think trusts the desire)
    if Fu.Utils.IsValidUnit(targetUnit) and (ShouldHelpAlly or IsHeroCore or IsSupport) then
        local dist = GetUnitToUnitDistance(bot, targetUnit)
        local attackRange = bot:GetAttackRange()

        -- Ranged hero: maintain attack range distance instead of walking into melee
        if attackRange >= 400 and dist > attackRange + 100 then
            local approachLoc = Fu.VectorTowards(targetUnit:GetLocation(), bot:GetLocation(), attackRange - 50)
            bot:Action_MoveToLocation(approachLoc)
        else
            bot:Action_AttackUnit(targetUnit, false)
        end
        return
    end

    -- Follow-ally fallback: move toward mission rally point or nearest ally
    -- if ShouldFollowAlly then
    --     if followAllyTarget ~= nil and Fu.IsValidHero(followAllyTarget) and followAllyTarget:IsAlive() then
    --         local dist = GetUnitToUnitDistance(bot, followAllyTarget)
    --         if dist > 400 then
    --             bot:Action_MoveToLocation(followAllyTarget:GetLocation())
    --         end
    --     else
    --         local lane = bot:GetAssignedLane() or LANE_MID
    --         bot:Action_MoveToLocation(GetLaneFrontLocation(GetTeam(), lane, 0))
    --     end
    --     return
    -- end
end

-- ==============================
-- Support / Carry target selection
-- (guarded by emergency retreat)
-- ==============================
function X.SupportFindTarget()
	local nBotHP = Fu.GetHP(bot)
    if X.CanNotUseAttack(bot) or DotaTime() < 0 then return nil, 0 end

    -- Tower dive prevention: don't chase heroes under tower if team can't guarantee kill
    local nEnemyTowersNearby = bot:GetNearbyTowers(800, true)
    if Fu.IsValidBuilding(nEnemyTowersNearby[1]) then
        local currentTarget = Fu.GetProperTarget(bot)
        if Fu.IsValidHero(currentTarget) and Fu.IsRecklesslyDivingTower(bot, currentTarget) then
            return nil, 0
        end
    end

    local IsModeSuitHit = X.IsModeSuitToHitCreep(bot)
    local nAttackRange = math.min(bot:GetAttackRange() + 50, 1200)

    local nTarget = Fu.GetProperTarget(bot)
    local botMode = bot:GetActiveMode()
    local botLV   = bot:GetLevel()
    local botAD   = bot:GetAttackDamage()
    local botBAD  = X.GetAttackDamageToCreep(bot) - 1

    if X.CanBeAttacked(nTarget) and nTarget == targetUnit and GetUnitToUnitDistance(bot, nTarget) <= 1600 then
        if nTarget:GetTeam() == bot:GetTeam() then
            if nTarget:GetHealth() > X.GetLastHitHealth(bot, nTarget) then
                return nTarget, BOT_MODE_DESIRE_VERYHIGH * 1.08
            end
            return nTarget, BOT_MODE_DESIRE_VERYHIGH * 1.04
        end
        if nTarget:IsCourier()
        and GetUnitToUnitDistance(bot, nTarget) <= nAttackRange + 300
        and nBotHP > 0.3 and not Fu.IsRetreating(bot) then
            return nTarget, BOT_DESIRE_OVERRIDE * 1.5
        end
        if nTarget:IsHero() and not Fu.IsInLaningPhase() and (bot:GetCurrentMovementSpeed() < 300 or botLV >= 25) then
            return nTarget, BOT_DESIRE_OVERRIDE * 1.2
        end
        if Fu.IsPushing(bot) and not nTarget:IsHero() then return nil, 0 end
        if not nTarget:IsHero() and GetUnitToUnitDistance(bot, nTarget) < nAttackRange + 50 then
            return nTarget, BOT_DESIRE_OVERRIDE * 0.98
        end
        if not nTarget:IsHero() and GetUnitToUnitDistance(bot, nTarget) > nAttackRange + 300 then
            return nTarget, BOT_DESIRE_OVERRIDE * 0.7
        end
        return nTarget, BOT_DESIRE_OVERRIDE * 0.96
    end

	-- Avoid derailing laning/pushing for courier hunts
	if not Fu.IsInLaningPhase() and not Fu.IsPushing(bot) then
		local enemyCourier = X.GetEnemyCourier(bot, nAttackRange + botLV * 2 + 20)  -- or +30 in carry version
		if enemyCourier ~= nil and not enemyCourier:IsAttackImmune() and not enemyCourier:IsInvulnerable()
		and nBotHP > 0.3 and not Fu.IsRetreating(bot) then
			return enemyCourier, BOT_DESIRE_OVERRIDE * 1.2
		end
	end

    if botMode == BOT_MODE_RETREAT and botLV > 9 and not X.CanBeInVisible(bot) and X.ShouldNotRetreat(bot) then
        nTarget = Fu.GetAttackableWeakestUnit(bot, nAttackRange + 50, true, true)
        if nTarget ~= nil then return nTarget, BOT_DESIRE_OVERRIDE * 1.09 end
    end

    local attackDamage = botBAD - 1
    if IsModeSuitHit and not X.HasHumanAlly(bot) and (nBotHP > 0.5 or not bot:WasRecentlyDamagedByAnyHero(2.0)) then
        local nBonusRange = botLV > 20 and 200 or (botLV > 12 and 300 or 400)
        nTarget = X.GetNearbyLastHitCreep(false, true, attackDamage, nAttackRange + nBonusRange, bot)
        if nTarget ~= nil then return nTarget, BOT_MODE_DESIRE_ABSOLUTE end

        local nEnemyTowers = bot:GetNearbyTowers(nAttackRange + 150, true)
        if X.CanBeAttacked(nEnemyTowers[1]) and Fu.IsWithoutTarget(bot) and X.IsLastHitCreep(nEnemyTowers[1], botAD * 2) then
            return nEnemyTowers[1], BOT_MODE_DESIRE_ABSOLUTE
        end

        local nNeutrals = bot:GetNearbyNeutralCreeps(nAttackRange + 150)
        local nAllies = Fu.GetNearbyHeroes(bot, 1300, false, BOT_MODE_NONE)
        if Fu.IsWithoutTarget(bot) and botMode ~= BOT_MODE_FARM and #nNeutrals > 0 and #nAllies <= 1 then
            for i = 1, #nNeutrals do
                if X.CanBeAttacked(nNeutrals[i]) and not X.IsAllysTarget(nNeutrals[i])
                and not Fu.IsTormentor(nNeutrals[i]) and not Fu.IsRoshan(nNeutrals[i])
                and X.IsLastHitCreep(nNeutrals[i], attackDamage) then
                    return nNeutrals[i], BOT_MODE_DESIRE_ABSOLUTE
                end
            end
        end
    end

    local denyDamage = botAD + 3
    local nNearbyEnemyHeroes = Fu.GetNearbyHeroes(bot, 750, true, BOT_MODE_NONE)
    if IsModeSuitHit and bot:GetLevel() <= 8
    and bot:GetNetWorth() < 13998
    and (nBotHP > 0.38 or not bot:WasRecentlyDamagedByAnyHero(3.0))
    and (nNearbyEnemyHeroes[1] == nil or nNearbyEnemyHeroes[1]:GetLevel() < 10)
    and bot:DistanceFromFountain() > 3800
    and Fu.GetDistanceFromEnemyFountain(bot) > 5000 then

        local nWillAttackCreeps = X.GetExceptRangeLastHitCreep(true, attackDamage * 1.1, 0, nAttackRange + 60, bot)
        if nWillAttackCreeps == nil or denyDamage > 130 or not X.IsOthersTarget(nWillAttackCreeps) or not X.IsMostAttackDamage(bot) then
            nTarget = X.GetNearbyLastHitCreep(false, false, denyDamage, nAttackRange + 300, bot)
            if nTarget ~= nil then return nTarget, BOT_DESIRE_OVERRIDE * 0.97 end
        end

        local nAllyTowers = bot:GetNearbyTowers(nAttackRange + 300, false)
        if Fu.IsWithoutTarget(bot) and #nAllyTowers > 0 then
            if X.CanBeAttacked(nAllyTowers[1]) and Fu.GetHP(nAllyTowers[1]) < 0.08 and X.IsLastHitCreep(nAllyTowers[1], denyDamage * 3) then
                return nAllyTowers[1], BOT_MODE_DESIRE_ABSOLUTE
            end
        end
    end

    return nil, 0
end

function X.CarryFindTarget()
	local nBotHP = Fu.GetHP(bot)
    if X.CanNotUseAttack(bot) or DotaTime() < 0 then return nil, 0 end

    -- Tower dive prevention: don't chase heroes under tower if team can't guarantee kill
    local nEnemyTowersNearby = bot:GetNearbyTowers(800, true)
    if Fu.IsValidBuilding(nEnemyTowersNearby[1]) then
        local currentTarget = Fu.GetProperTarget(bot)
        if Fu.IsValidHero(currentTarget) and Fu.IsRecklesslyDivingTower(bot, currentTarget) then
            return nil, 0
        end
    end

    local IsModeSuitHit = X.IsModeSuitToHitCreep(bot)
    local nAttackRange = math.min(bot:GetAttackRange() + 50, 1170)
    if botName == "npc_dota_hero_templar_assassin" then nAttackRange = nAttackRange + 100 end

	local nTarget = Fu.GetProperTarget(bot);	
	local botHP   = bot:GetHealth()/bot:GetMaxHealth();
	local botMode = bot:GetActiveMode();
	local botLV   = bot:GetLevel();
    local botAD   = bot:GetAttackDamage() - 0.8
    local botBAD  = X.GetAttackDamageToCreep(bot) - 1.2

    if X.CanBeAttacked(nTarget) and nTarget == targetUnit and GetUnitToUnitDistance(bot, nTarget) <= 1600 then
        if nTarget:GetTeam() == bot:GetTeam() then
            if nTarget:GetHealth() > X.GetLastHitHealth(bot, nTarget) then
                return nTarget, BOT_MODE_DESIRE_VERYHIGH * 1.08
            end
            return nTarget, BOT_MODE_DESIRE_VERYHIGH * 1.04
        end
        if nTarget:IsCourier()
        and GetUnitToUnitDistance(bot, nTarget) <= nAttackRange + 300
        and nBotHP > 0.3 and not Fu.IsRetreating(bot) then
            return nTarget, BOT_DESIRE_OVERRIDE * 1.5
        end
        if nTarget:IsHero() and not Fu.IsInLaningPhase() and (bot:GetCurrentMovementSpeed() < 300 or botLV >= 25) then
            if botName == "npc_dota_hero_antimage" then
                local bAbility = bot:GetAbilityByName("antimage_blink")
                if bAbility ~= nil and bAbility:IsFullyCastable() then return nil, BOT_MODE_DESIRE_NONE end
            end
            return nTarget, BOT_DESIRE_OVERRIDE * 1.2
        end
        if Fu.IsPushing(bot) and not nTarget:IsHero() then return nil, 0 end
        if not nTarget:IsHero() and GetUnitToUnitDistance(bot, nTarget) < nAttackRange + 50 then
            return nTarget, BOT_DESIRE_OVERRIDE * 0.98
        end
        if not nTarget:IsHero() and GetUnitToUnitDistance(bot, nTarget) > nAttackRange + 300 then
            return nTarget, BOT_DESIRE_OVERRIDE * 0.7
        end
        return nTarget, BOT_DESIRE_OVERRIDE * 0.96
    end

    if bot:HasModifier('modifier_phantom_lancer_phantom_edge_boost') then
        return nil, 0
    end

	-- Avoid derailing laning/pushing for courier hunts
	if not Fu.IsInLaningPhase() and not Fu.IsPushing(bot) then
		local enemyCourier = X.GetEnemyCourier(bot, nAttackRange + botLV * 2 + 20)  -- or +30 in carry version
		if enemyCourier ~= nil and not enemyCourier:IsAttackImmune() and not enemyCourier:IsInvulnerable()
		and nBotHP > 0.3 and not Fu.IsRetreating(bot) then
			return enemyCourier, BOT_DESIRE_OVERRIDE * 1.2
		end
	end

    if botMode == BOT_MODE_RETREAT
    and botName ~= "npc_dota_hero_bristleback"
    and botLV > 9
    and not X.CanBeInVisible(bot)
    and X.ShouldNotRetreat(bot) then
        nTarget = Fu.GetAttackableWeakestUnit(bot, nAttackRange + 50, true, true)
        if nTarget ~= nil then return nTarget, BOT_DESIRE_OVERRIDE * 1.09 end
    end

    local cItem = Fu.IsItemAvailable("item_echo_sabre")
    if  cItem ~= nil and (cItem:IsFullyCastable() or cItem:GetCooldownTimeRemaining() < bot:GetAttackPoint() +0.8)
		and IsModeSuitHit
		and (botHP > 0.35 or not bot:WasRecentlyDamagedByAnyHero(1.0))
	then
		local echoDamage = botBAD *2;
		if (cItem:IsFullyCastable() or cItem:GetCooldownTimeRemaining() <  bot:GetAttackPoint())
		then
			nTarget = X.GetNearbyLastHitCreep(true, true, echoDamage, 350, bot);
			if nTarget ~= nil then return nTarget,BOT_MODE_DESIRE_ABSOLUTE *0.98; end
		end
		local nEnemyTowers = bot:GetNearbyTowers(1000,true);			
		if (cItem:IsFullyCastable() or cItem:GetCooldownTimeRemaining() <  bot:GetAttackPoint() +0.8)
			and #nEnemyTowers == 0
		then
			for i=400, 580, 60 do
				nTarget = X.GetExceptRangeLastHitCreep(true, echoDamage, 350, i, bot);
				if nTarget ~= nil 
				   then return nTarget,BOT_MODE_DESIRE_HIGH; end
			end
		end
	end

	local attackDamage = botBAD;
	if  IsModeSuitHit
		and not X.HasHumanAlly( bot )
		and ( botHP > 0.5 or not bot:WasRecentlyDamagedByAnyHero(2.0))
	then
		local nBonusRange = 430;
		if botLV > 12 then nBonusRange = 380; end
		if botLV > 20 then nBonusRange = 330; end

		nTarget = X.GetNearbyLastHitCreep(true, true, attackDamage, nAttackRange + nBonusRange, bot);
		if nTarget ~= nil
		then
			return nTarget,BOT_MODE_DESIRE_ABSOLUTE;
		end
	end

	local denyDamage = botAD + 3
	local nNearbyEnemyHeroes = bot:GetNearbyHeroes(650,true,BOT_MODE_NONE);
	if  IsModeSuitHit 
		and ( botHP > 0.38 or not bot:WasRecentlyDamagedByAnyHero(3.0))
		and (nNearbyEnemyHeroes[1] == nil or nNearbyEnemyHeroes[1]:GetLevel() < 12)
		and bot:DistanceFromFountain() > 3800
		and Fu.GetDistanceFromEnemyFountain(bot) > 5000
	then
		if bot:GetLevel() <= 8
		then
			local nWillAttackCreeps = X.GetExceptRangeLastHitCreep(true, attackDamage *1.5, 0, nAttackRange +60, bot);
			if nWillAttackCreeps == nil
				or denyDamage > 130
				or not X.IsOthersTarget(nWillAttackCreeps)
				or not X.IsMostAttackDamage(bot)
			then
				nTarget = X.GetNearbyLastHitCreep(false, false, denyDamage, nAttackRange +300, bot);
				if nTarget ~= nil then
					return nTarget,BOT_MODE_DESIRE_ABSOLUTE *0.97;
				end
			end
		end

		local nAllyTowers = bot:GetNearbyTowers(nAttackRange + 300, false);
		if Fu.IsWithoutTarget(bot)
		   and #nAllyTowers > 0
		then
			if X.CanBeAttacked(nAllyTowers[1])
			   and Fu.GetHP(nAllyTowers[1]) < 0.05
			   and X.IsLastHitCreep(nAllyTowers[1],denyDamage * 3)
			then
				return nAllyTowers[1],BOT_MODE_DESIRE_ABSOLUTE;
			end
		end
	end

	if  IsModeSuitHit
		and bot:GetLevel() <= 8
		and X.CanAttackTogether(bot)
		and (nNearbyEnemyHeroes[1] == nil or nNearbyEnemyHeroes[1]:GetLevel() < 12)
		and bot:DistanceFromFountain() > 3800
		and Fu.GetDistanceFromEnemyFountain(bot) > 5000
	 then
	     local nAllies = bot:GetNearbyHeroes(1200,false,BOT_MODE_NONE);
		 local nNum = X.GetCanTogetherCount(nAllies)
		 local centerAlly = X.GetMostDamageUnit(nAllies);
		 if centerAlly ~= nil and nNum >= 2
		 then
			local nTowerCreeps = centerAlly:GetNearbyLaneCreeps(1600,true);
			local nAllyTower = bot:GetNearbyTowers(1400,false);
			if(nAllyTower[1] ~= nil and nAllyTower[1]:GetAttackTarget() ~= nil)
			then
				local nTowerDamage = nAllyTower[1]:GetAttackDamage();
				local nTowerTarget = nAllyTower[1]:GetAttackTarget();
				for _,creep in pairs(nTowerCreeps)
				do
					if  nTowerTarget == creep
						and X.CanBeAttacked(creep)
						and creep:GetHealth() < X.GetLastHitHealth(nAllyTower[1],creep)
						and creep:GetHealth() > X.GetLastHitHealth(bot,creep)
					then
						local togetherDamage = 0;
						local togetherCount = 0;
						for _,ally in pairs(nAllies)
						do
							if X.CanAttackTogether(ally)
								and GetUnitToUnitDistance(ally,creep) <= ally:GetAttackRange() +50
							then
								togetherDamage = ally:GetAttackDamage() + togetherDamage;
								togetherCount =  togetherCount +1;
							end
						end
						if X.IsLastHitCreep(creep,togetherDamage)
						   and togetherCount >= 2
						   and GetUnitToUnitDistance(bot,creep) <= bot:GetAttackRange() +50
						then
							return creep,BOT_MODE_DESIRE_ABSOLUTE;
						end
					end
				end
		    end

			local nWillAttackCreeps = X.GetExceptRangeLastHitCreep(true, centerAlly:GetAttackDamage() *1.2, 0, 800, centerAlly);
			if nWillAttackCreeps == nil 
				or not X.IsOthersTarget(nWillAttackCreeps)
			then
				local nDenyCreeps = centerAlly:GetNearbyCreeps(1600,false);
				for _,creep in pairs(nDenyCreeps)
				do
					if X.CanBeAttacked(creep)
					and creep:GetHealth()/creep:GetMaxHealth() < 0.5
					and not X.IsLastHitCreep(creep,denyDamage)
					and not Fu.IsTormentor(creep)
					and not Fu.IsRoshan(creep)
					then
						local togetherDamage = 0;
						local togetherCount = 0;
						for _,ally in pairs(nAllies)
						do
							if X.CanAttackTogether(ally)
								and GetUnitToUnitDistance(ally,creep) <= ally:GetAttackRange() + 150 
							then
								togetherDamage = ally:GetAttackDamage() + togetherDamage;
								togetherCount = togetherCount +1;
							end
						end
						if X.IsLastHitCreep(creep,togetherDamage)
						   and togetherCount >= 2
						   and GetUnitToUnitDistance(bot,creep) <= bot:GetAttackRange() + 150
						then
							return creep,BOT_MODE_DESIRE_HIGH;
						end
					end
				end
			end
		end

	end

	local nNearbyEnemyHeroes = bot:GetNearbyHeroes(1600,true,BOT_MODE_NONE);
	local nEnemyLaneCreep = bot:GetNearbyLaneCreeps(1200, true);
	local nWillAttackCreeps = X.GetExceptRangeLastHitCreep(true, attackDamage *1.2, 0, nAttackRange + 120, bot);
	if  IsModeSuitHit
		and botLV >= 8
		and nNearbyEnemyHeroes[1] == nil
		and ( attackDamage > 118 or bot:GetSecondsPerAttack() < 0.7 )
		and ( nWillAttackCreeps == nil or not X.IsMostAttackDamage(bot) or not X.IsOthersTarget(nWillAttackCreeps))
	then
		local nEnemyTowers = bot:GetNearbyTowers(900,true);
		if botName ~= "npc_dota_hero_templar_assassin"
		then
			local nTwoHitCreeps = bot:GetNearbyLaneCreeps(nAttackRange +150, true);
			for _,creep in pairs(nTwoHitCreeps)
			do
				if X.CanBeAttacked(creep)
				   and not X.IsLastHitCreep(creep,attackDamage *1.2)
				   and not X.IsOthersTarget(creep)
				then
					local nAllyLaneCreep = bot:GetNearbyLaneCreeps(600, false);
					if X.IsLastHitCreep(creep,attackDamage *2)
					then
						return creep,BOT_MODE_DESIRE_ABSOLUTE;
					elseif X.IsLastHitCreep(creep,attackDamage *3 - 5) 
							and #nAllyLaneCreep == 0 and botLV >= 3						
						then
							return creep,BOT_MODE_DESIRE_ABSOLUTE *0.9;
					end
				end
			end
		end

		if  bot:DistanceFromFountain() > 3800 
			and not bePvNMode and bot:GetLevel() <= 6
			and Fu.GetDistanceFromEnemyFountain(bot) > 5000
			and nEnemyTowers[1] == nil
			and bot:GetNetWorth() < 19800
			and denyDamage > 110
		then
			local nTwoHitDenyCreeps = bot:GetNearbyCreeps(nAttackRange +120, false);
			for _,creep in pairs(nTwoHitDenyCreeps)
			do
				if X.CanBeAttacked(creep)
				and creep:GetHealth()/creep:GetMaxHealth() < 0.5
				and X.IsLastHitCreep(creep,denyDamage *2)
				and ( not X.IsLastHitCreep(creep,denyDamage *1.2) or #nEnemyLaneCreep == 0 )
				and not X.IsOthersTarget(creep)
				and not Fu.IsTormentor(creep)
				and not Fu.IsRoshan(creep)
				then
					return creep,BOT_MODE_DESIRE_ABSOLUTE;
				end
			end
		end

		local nEnemysCreeps = bot:GetNearbyCreeps(1600,true)
		local nAttackAlly = Fu.GetSpecialModeAllies(bot, 2500, BOT_MODE_ATTACK);
		local nTeamFightLocation = Fu.GetTeamFightLocation(bot);
		local nDefendLane,nDefendDesire = Fu.GetMostDefendLaneDesire();
		if  X.CanBeAttacked(nEnemysCreeps[1])
		and bot:GetHealth() > 300
		and not X.IsAllysTarget(nEnemysCreeps[1])
		and not Fu.IsRoshan(nEnemysCreeps[1])
		and (nEnemysCreeps[1]:GetTeam() == TEAM_NEUTRAL or attackDamage > 110)
		and ( not nEnemysCreeps[1]:IsAncientCreep() or attackDamage > 150 )
		and ( not Fu.IsKeyWordUnit("warlock", nEnemysCreeps[1]) or nBotHP > 0.58 )		
		and ( nTeamFightLocation == nil or GetUnitToLocationDistance(bot,nTeamFightLocation) >= 3000 )
		and ( nDefendDesire <= 0.8 )
		and botMode ~= BOT_MODE_FARM
		and botMode ~= BOT_MODE_RUNE
		and botMode ~= BOT_MODE_LANING
		and botMode ~= BOT_MODE_ASSEMBLE
		and botMode ~= BOT_MODE_SECRET_SHOP
		and botMode ~= BOT_MODE_SIDE_SHOP
		and botMode ~= BOT_MODE_WATCHER
		and botMode ~= BOT_MODE_WARD
		and GetRoshanDesire() < BOT_MODE_DESIRE_HIGH	
		and not bot:WasRecentlyDamagedByAnyHero(2.0)
		and bot:GetAttackTarget() == nil
		and botLV >= 10
		and #nAttackAlly == 0
		and #nEnemyTowers == 0
		and not Fu.IsTormentor(nEnemysCreeps[1])
		and not Fu.IsRoshan(nEnemysCreeps[1])
		then
			if nEnemysCreeps[1]:GetTeam() == TEAM_NEUTRAL 
			   and Fu.IsInRange(bot, nEnemysCreeps[1], nAttackRange + 100)
			   and ( #nEnemysCreeps <= 2 
			         or attackDamage > 220 
					 or botName == "npc_dota_hero_antimage" )
			then
				Fu.Role['availableCampTable'] = X.UpdateCommonCamp(nEnemysCreeps[1], Fu.Role['availableCampTable']);
			end
			return nEnemysCreeps[1],BOT_MODE_DESIRE_ABSOLUTE;
		end

		if bot:GetHealth() > 160 
		   and Fu.IsWithoutTarget(bot)
		then
			local nNeutrals = bot:GetNearbyNeutralCreeps(nAttackRange + 150);
			if #nNeutrals > 0
			   and botMode ~= BOT_MODE_FARM
			then
				for i = 1,#nNeutrals
				do
					if X.CanBeAttacked(nNeutrals[i])
						and not X.IsAllysTarget(nNeutrals[i])
						and not Fu.IsTormentor(nNeutrals[i])
						and not Fu.IsRoshan(nNeutrals[i])
						and X.IsLastHitCreep(nNeutrals[i],attackDamage * 2)
					then
						return nNeutrals[i],BOT_MODE_DESIRE_ABSOLUTE; 
					end
				end
			end
		end
	end
    return nil,0;
end

local bHumanAlly = nil
function X.HasHumanAlly( bot )
	if bHumanAlly == false then return false end
	if bHumanAlly == nil
	then
		local teamPlayerIDList = GetTeamPlayers( GetTeam() )
		for i = 1, #teamPlayerIDList
		do
			if not IsPlayerBot( teamPlayerIDList[i] )
			then
				bHumanAlly = true
				break
			end
		end	
		if bHumanAlly ~= true then bHumanAlly = false end
	end
	local allyHeroList = bot:GetNearbyHeroes( 900, false, BOT_MODE_NONE )
	for _, npcAlly in pairs( allyHeroList )
	do
		if not npcAlly:IsBot()
		then
			return true
		end
	end
	return false
end

function X.IsCreepTarget(nUnit)
	local bot = GetBot();
	local nCreeps = bot:GetNearbyCreeps(1200,true);
	for _,creep in pairs(nCreeps)
	do
		if  X.IsValid(creep)
		and creep:GetAttackTarget() == nUnit
		and not Fu.IsTormentor(creep)
		and not Fu.IsRoshan(creep)
		then
			return true;
		end
	end
	
	local nCreeps = bot:GetNearbyCreeps(1200,false);
	for _,creep in pairs(nCreeps)
	do
		if X.IsValid(creep)
		and creep:GetAttackTarget() == nUnit
		and not Fu.IsTormentor(creep)
		and not Fu.IsRoshan(creep)
		then
			return true;
		end
	end

	return false;
end

-- ==============================
-- Generic utils (many of yours kept)
-- ==============================
function X.IsValid(u) return u ~= nil and not u:IsNull() and u:IsAlive() and u:CanBeSeen() end

function X.GetAttackDamageToCreep( bot )
	if bot:GetItemSlotType(bot:FindItemSlot("item_quelling_blade")) == ITEM_SLOT_TYPE_MAIN
	then
		if bot:GetAttackRange() > 310 or bot:GetUnitName() == "npc_dota_hero_templar_assassin"
		then
			return bot:GetAttackDamage() + 4;
		else
			return bot:GetAttackDamage() + 8;
		end
	end
	if bot:FindItemSlot("item_bfury") >= 0
	then
		return bot:GetAttackDamage() + 15;
	end
	return bot:GetAttackDamage();
end

function X.CanNotUseAttack(b)
    return not b:IsAlive() or Fu.HasQueuedAction(b) or b:IsInvulnerable() or b:IsCastingAbility()
        or b:IsUsingAbility() or b:IsChanneling() or b:IsStunned() or b:IsDisarmed()
        or b:IsHexed() or b:IsRooted() or X.WillBreakInvisible(b)
end

function X.WillBreakInvisible(b)
    local invis = {
        ["npc_dota_hero_riki"] = true,
        ["npc_dota_hero_phantom_assassin"] = true,
        ["npc_dota_hero_templar_assassin"] = true,
        ["npc_dota_hero_bounty_hunter"] = true,
    }
    if b:IsInvisible() and not invis[b:GetUnitName()] then return true end
    return false
end

function X.CanBeAttacked(unit)
    return unit ~= nil and unit:IsAlive() and unit:CanBeSeen() and not unit:IsNull()
        and not unit:IsAttackImmune() and not unit:IsInvulnerable()
        and not unit:HasModifier("modifier_fountain_glyph")
        and (unit:GetTeam() == team or not unit:HasModifier("modifier_crystal_maiden_frostbite"))
        and (unit:GetTeam() ~= team or (unit:GetUnitName() ~= "npc_dota_wraith_king_skeleton_warrior"
            and unit:GetHealth()/unit:GetMaxHealth() < 0.5))
end

-- Courier scan (unchanged)
local courierFindCD, lastFindTime = 0.1, -90
function X.GetEnemyCourier(b, nRadius)
    if GetGameMode() == 23 then return nil end
    if Fu.GetDistanceFromEnemyFountain(b) < 1400 then return nil end
    if DotaTime() > lastFindTime + courierFindCD then
        lastFindTime = DotaTime()
        for _,u in pairs(GetUnitList(UNIT_LIST_ENEMIES)) do
            if u and u:IsCourier() and u:IsAlive()
            and GetUnitToUnitDistance(b, u) <= nRadius
            and not u:IsInvulnerable() and not u:IsAttackImmune()
            and not u:HasModifier('modifier_fountain_aura') then
                return u
            end
        end
    end
    return nil
end

function X.WeakestUnitExceptRangeCanBeAttacked(bHero, bEnemy, nRange, nRadius, bot)
	local units = {};
	local weakest = nil;
	local weakestHP = 4999;
	local realHP = 0;
	if nRadius > 1600 then nRadius = 1600 end;
	
	if bHero then
		units = bot:GetNearbyHeroes(nRadius, bEnemy, BOT_MODE_NONE);
	else	
		units = bot:GetNearbyLaneCreeps(nRadius, bEnemy);
	end
	
	for _,u in pairs(units) do
		if  X.IsValid(u)
		and GetUnitToUnitDistance(bot,u) > nRange 
		and X.CanBeAttacked(u)
		and not u:HasModifier("modifier_crystal_maiden_frostbite")
		then
			realHP = u:GetHealth() / 1;
			
			if realHP < weakestHP
			then
				weakest = u;
				weakestHP = realHP;
			end			
		end
	end
	return weakest;
end

function X.GetNearbyLastHitCreep(ignorAlly, bEnemy, nDamage, nRadius, bot)

	if nRadius > 1600 then nRadius = 1600 end;
	local nNearbyCreeps = bot:GetNearbyLaneCreeps(nRadius, bEnemy);
	local nDamageType = DAMAGE_TYPE_PHYSICAL;
	local botName = bot:GetUnitName();


	if  bEnemy 
		and botName == "npc_dota_hero_templar_assassin" --V bug
		and bot:HasModifier("modifier_templar_assassin_refraction_damage")
	then
		local cAbility = bot:GetAbilityByName( "templar_assassin_refraction" );
		local bonusDamage = cAbility:GetSpecialValueInt( 'bonus_damage' );
		nDamage = nDamage + bonusDamage;
	end

	if  bEnemy
		and botName == "npc_dota_hero_kunkka"
	then
		local cAbility = bot:GetAbilityByName( "kunkka_tidebringer" );
		if cAbility:IsFullyCastable() 
		then
			local bonusDamage = cAbility:GetSpecialValueInt( 'damage_bonus' );
			nDamage = nDamage + bonusDamage;
		end
	end


	for _,nCreep in pairs(nNearbyCreeps)
	do
		if X.CanBeAttacked(nCreep) and nCreep:GetHealth() < ( nDamage + 256 )
		and ( ignorAlly or not X.IsAllysTarget(nCreep) )
		then
		
			local nAttackProDelayTime = Fu.GetAttackProDelayTime(bot,nCreep) ;
			
			if bEnemy and botName == "npc_dota_hero_antimage"
				and Fu.IsKeyWordUnit("ranged",nCreep)
			then
				local cAbility = bot:GetAbilityByName( "antimage_mana_break" );
				if cAbility:IsTrained()
				then
					local bonusDamage = 0.5 * cAbility:GetSpecialValueInt( 'mana_per_hit' );
					nDamage = nDamage + bonusDamage;
				end
			end
		
			
			local nRealDamage = nDamage * 1
				
			if Fu.WillKillTarget(nCreep,nRealDamage,nDamageType,nAttackProDelayTime)
			then
				return nCreep;
			end
		
		end
	end
	return nil;
end

function X.GetExceptRangeLastHitCreep(bEnemy,nDamage,nRange,nRadius,bot)
	
	local nCreep = X.WeakestUnitExceptRangeCanBeAttacked(false, bEnemy, nRange, nRadius, bot);
	local nDamageType = DAMAGE_TYPE_PHYSICAL;

	if X.IsValid(nCreep)
	then
		if not bEnemy and nCreep:GetHealth()/nCreep:GetMaxHealth() >= 0.5
		then return nil end	
	
		nDamage = nDamage * 1 ;

		local nAttackProDelayTime = Fu.GetAttackProDelayTime(bot,nCreep);
		
		if Fu.WillKillTarget(nCreep,nDamage,nDamageType,nAttackProDelayTime)
		then		
			return nCreep;
		end

	end

	return nil;
end

function X.IsLastHitCreep(nCreep,nDamage)
	
	if X.CanBeAttacked(nCreep)
	then
		
		nDamage = nDamage * 1;
		
		if nCreep:GetActualIncomingDamage(nDamage, DAMAGE_TYPE_PHYSICAL) + Fu.GetCreepAttackProjectileWillRealDamage(nCreep,0.66) > nCreep:GetHealth() +1
		then 
		    return true;
		end
		
	end
	 
	return false;
	
end


function X.GetLastHitHealth(bot,nCreep)
	
	if X.CanBeAttacked(nCreep)
	then
	   
       local nDamage = X.GetAttackDamageToCreep(bot) * 1
		
	   return nCreep:GetActualIncomingDamage(nDamage, DAMAGE_TYPE_PHYSICAL);
	end
	 
	return bot:GetAttackDamage();

end


function X.IsAllysTarget(unit)
	local bot = GetBot();
	local allies = bot:GetNearbyHeroes(1000,false,BOT_MODE_NONE);
	if #allies < 2 then return false end;
	
	for _,ally in pairs(allies) 
	do
		if  ally ~= bot
			and not ally:IsIllusion()
			and ( ally:GetTarget() == unit or ally:GetAttackTarget() == unit )
		then
			return true;
		end
	end
	return false;
end


function X.IsEnemysTarget(unit)
	local bot = GetBot();
	local enemys = bot:GetNearbyHeroes(1600,true,BOT_MODE_NONE);
	for _,enemy in pairs(enemys) 
	do
		if  X.IsValid(enemy) and Fu.GetProperTarget(enemy) == unit 
		then
			return true;
		end
	end
	return false;
end


function X.CanAttackTogether(bot)
   
   local allies = bot:GetNearbyHeroes(1200,false,BOT_MODE_NONE);
   local nNearbyEnemyHeroes = bot:GetNearbyHeroes(600,true,BOT_MODE_NONE);
   
   return bot ~= nil and bot:IsAlive()
		  and not bot:IsIllusion()
		  and Fu.GetProperTarget(bot) == nil
	      and #allies >= 2
		  and (nNearbyEnemyHeroes[1] == nil or nNearbyEnemyHeroes[1]:GetLevel() < 10)
   
end


function X.GetMostDamageUnit(nUnits)
	
	local mostAttackDamage = 0;
	local mostUnit = nil;
	for _,unit in pairs(nUnits)
	do
		if unit ~= nil and unit:IsAlive()
			and Fu.GetProperTarget(unit) == nil
			and unit:GetAttackDamage() > mostAttackDamage
		then
			mostAttackDamage = unit:GetAttackDamage();
			mostUnit = unit;
		end
	end
	
	return mostUnit;

end


function X.GetCanTogetherCount(nAllies)
	
	local nNum = 0;
	for _,ally in pairs(nAllies)
	do
		if X.IsValid(ally) and X.CanAttackTogether(ally)
		then
			nNum = nNum +1;
		end
	end
	
	return nNum;

end

function X.IsOthersTarget(nUnit)
	local bot = GetBot();

	if X.IsValid(nUnit)
	then
		if X.IsAllysTarget(nUnit)
		then
			return true;
		end
		
		if X.IsEnemysTarget(nUnit)
		then
			return true;
		end
		
		if X.IsCreepTarget(nUnit)
		then
			return true
		end
		
		local nTowers = bot:GetNearbyTowers(1600,true);
		for _,tower in pairs(nTowers)
		do
			if Fu.IsValidBuilding(tower)
			   and tower:GetAttackTarget() == nUnit
			then
				return true;
			end
		end
		
		local nTowers = bot:GetNearbyTowers(1600,false);
		for _,tower in pairs(nTowers)
		do
			if Fu.IsValidBuilding(tower)
			   and tower:GetAttackTarget() == nUnit
			then
				return true;
			end
		end
	end
	
	return false;

end

function X.CanBeInVisible(bot)

	local nEnemyTowers = bot:GetNearbyTowers(800,true);
	if #nEnemyTowers > 0 
	   or bot:HasModifier("modifier_item_dustofappearance")
	then 
		return false;
	end

	if bot:IsInvisible()
	then
		return true;
	end

	local glimer = Fu.IsItemAvailable("item_glimmer_cape");
	if glimer ~= nil and glimer:IsFullyCastable() 
	then
		return true;			
	end
	
	local invissword = Fu.IsItemAvailable("item_invis_sword");
	if invissword ~= nil and invissword:IsFullyCastable() 
	then
		return true;			
	end
	
	local silveredge = Fu.IsItemAvailable("item_silver_edge");
	if silveredge ~= nil and silveredge:IsFullyCastable() 
	then
		return true;			
	end

	return false;
end

local lastUpdateTime = 0
function X.UpdateCommonCamp(creep, AvailableCamp)
	if lastUpdateTime < DotaTime() - 3.0
	then
		lastUpdateTime = DotaTime();
		for i = 1, #AvailableCamp
		do
			if GetUnitToLocationDistance(creep,AvailableCamp[i].cattr.location) < 500 then
				table.remove(AvailableCamp, i);
				return AvailableCamp;
			end
		end
	end
	return AvailableCamp;
end

-- ==============================
-- Help when core targeted (unchanged)
-- ==============================
function X.ConsiderHelpWhenCoreIsTargeted()
    -- Don't help cores if we're low HP ourselves
    if Fu.GetHP(bot) < 0.4 then return nil, false end
    if bot:WasRecentlyDamagedByAnyHero(2.0) and Fu.GetHP(bot) < 0.55 then return nil, false end

    local nRadius = 3500
    local nModeDesire = bot:GetActiveModeDesire()
    local nClosestCore = Fu.GetClosestCore(bot, nRadius)

    if  nClosestCore ~= nil
    and Fu.GetHP(nClosestCore) > 0.2
    and (not Fu.IsCore(bot) or bot.isBear or (Fu.IsCore(bot) and (not Fu.IsInLaningPhase() or Fu.IsInRange(bot, nClosestCore, 1600))))
    and not Fu.IsGoingOnSomeone(bot)
    and not (Fu.IsRetreating(bot) and nModeDesire > 0.8) then
        local nInRangeAlly = Fu.GetAlliesNearLoc(nClosestCore:GetLocation(), 1200)
        local nInRangeEnemy = Fu.GetEnemiesNearLoc(nClosestCore:GetLocation(), 1600)

        -- Risk check: don't walk into outnumbered fights
        if #nInRangeEnemy > #nInRangeAlly + 1 then return nil, false end

        for _, enemyHero in pairs(nInRangeEnemy) do
            if  Fu.IsValidHero(enemyHero)
            and GetUnitToUnitDistance(enemyHero, nClosestCore) <= 1600
            and (#nInRangeAlly + 1 >= #nInRangeEnemy) then
                if (enemyHero:GetAttackTarget() == nClosestCore or Fu.IsChasingTarget(enemyHero, nClosestCore))
                or nClosestCore:WasRecentlyDamagedByHero(enemyHero, 2.5) then
                    return enemyHero, true
                end
            end
        end
    end

    return nil, false
end

function X.IsModeSuitToHitCreep(b)
    local botMode = b:GetActiveMode()
    local nEnemyHeroes = Fu.GetEnemyList(b, 750)
    if #nEnemyHeroes >= 3 or (nEnemyHeroes[1] ~= nil and nEnemyHeroes[1]:GetLevel() >= 8) then
        return false
    end
    if b:HasModifier("modifier_axe_battle_hunger") then
        if #b:GetNearbyLaneCreeps(b:GetAttackRange() + 180, true) > 0 then return true end
    end
    if b:GetLevel() <= 3 and botMode ~= BOT_MODE_EVASIVE_MANEUVERS
    and (botMode ~= BOT_MODE_RETREAT or (botMode == BOT_MODE_RETREAT and b:GetActiveModeDesire() < 0.78)) then
        return true
    end
    return botMode ~= BOT_MODE_ATTACK
        and botMode ~= BOT_MODE_EVASIVE_MANEUVERS
        and (botMode ~= BOT_MODE_RETREAT or (botMode == BOT_MODE_RETREAT and b:GetActiveModeDesire() < 0.68))
end

function X.IsMostAttackDamage(b)
    for _,ally in pairs(Fu.GetNearbyHeroes(b, 800, false, BOT_MODE_NONE)) do
        if ally ~= b and not X.CanNotUseAttack(ally) and ally:GetAttackDamage() > b:GetAttackDamage() then
            return false
        end
    end
    return true
end

-- ==============================
-- Retreat logic hardening
-- ==============================
function X.ShouldNotRetreat(b)
    do
        local a = Fu.GetAlliesNearLoc(b:GetLocation(), 1000)
        local e = Fu.GetEnemiesNearLoc(b:GetLocation(), 1000)
        local losing = (#a < #e) or not Fu.WeAreStronger(b, 1000)
        if (b:WasRecentlyDamagedByAnyHero(1.2) or b:WasRecentlyDamagedByTower(1.2)) and losing then
            return false
        end
    end

    if b:HasModifier("modifier_item_satanic_unholy")
       or b:HasModifier("modifier_abaddon_borrowed_time")
       or (b:GetCurrentMovementSpeed() < 240 and not b:HasModifier("modifier_arc_warden_spark_wraith_purge")) then
        return true
    end

    local nAttackAlly = Fu.GetNearbyHeroes(b, 1000, false, BOT_MODE_ATTACK)
    if (b:HasModifier("modifier_item_mask_of_madness_berserk") or Fu.CanIgnoreLowHp(b))
    and (#nAttackAlly >= 1 or Fu.GetHP(b) > 0.6)
    and (b:WasRecentlyDamagedByAnyHero(1) or b:WasRecentlyDamagedByTower(1)) then
        return true
    end

    local nAllies = Fu.GetAllyList(b, 800)
    if #nAllies <= 1 then return false end

    if (botName == "npc_dota_hero_medusa" or b:FindItemSlot("item_abyssal_blade") >= 0)
       or b:HasModifier('modifier_muerta_pierce_the_veil_buff')
    and (b:WasRecentlyDamagedByAnyHero(1) or Fu.GetHP(b) > 0.2 or b:WasRecentlyDamagedByTower(1))
    and #nAllies >= 3 and #nAttackAlly >= 1 then
        return true
    end

    if botName == "npc_dota_hero_skeleton_king" and b:GetLevel() >= 6 and #nAttackAlly >= 1 then
        local abilityR = b:GetAbilityByName("skeleton_king_reincarnation")
        if abilityR and abilityR:GetCooldownTimeRemaining() <= 1.0 and b:GetMana() >= 160 then
            return true
        end
    end

    for _,ally in pairs(nAllies) do
        if Fu.IsValid(ally) then
            if Fu.GetHP(b) >= 0.3 and (
                (Fu.GetHP(ally) > 0.88 and ally:GetLevel() >= 12 and ally:GetActiveMode() ~= BOT_MODE_RETREAT)
                or ally:HasModifier("modifier_black_king_bar_immune") or ally:IsMagicImmune()
                or (ally:HasModifier("modifier_item_mask_of_madness_berserk") and ally:GetAttackTarget() ~= nil)
                or ally:HasModifier("modifier_abaddon_borrowed_time")
                or ally:HasModifier("modifier_item_satanic_unholy")
                or Fu.CanIgnoreLowHp(ally)
            ) then
                return true
            end
        end
    end

    return false
end

-- ==============================
-- Tower creep targeting (guarded)
-- ==============================
local fLastReturnTime = 0
function X.ShouldAttackTowerCreep(b)
    if X.CanNotUseAttack(b) then return 0 end

    if b:GetLevel() > 2
    and b:GetAnimActivity() == 1502
    and b:GetTarget() == nil and b:GetAttackTarget() == nil
    and X.IsModeSuitToHitCreep(b)
    and Fu.GetHP(b) > 0.38
    and not b:WasRecentlyDamagedByAnyHero(2.0) then
        local nRange = math.min(b:GetAttackRange() + 150, 1250)
        local allyCreeps = b:GetNearbyLaneCreeps(800, false)
        local enemyCreeps = b:GetNearbyLaneCreeps(800, true)
        local attackTime = b:GetSecondsPerAttack() * 0.75
        local attackTarget = nil
        local nEnemyTowers = b:GetNearbyTowers(nRange, true)
        local bMS = b:GetCurrentMovementSpeed()

        if X.CanBeAttacked(nEnemyTowers[1])
        and (nEnemyTowers[1]:GetAttackTarget() ~= b or Fu.GetHP(b) > 0.8)
        and #allyCreeps > 0
        and fLastReturnTime < DotaTime() - 1.0 then
            attackTarget = nEnemyTowers[1]
            local nDist = GetUnitToUnitDistance(b, attackTarget) - b:GetAttackRange()
            if nDist > 0 then attackTime = attackTime + nDist / bMS end
            fLastReturnTime = DotaTime()
            return attackTime, attackTarget
        end

        local nEnemyBarracks = b:GetNearbyBarracks(nRange, true)
        if X.CanBeAttacked(nEnemyBarracks[1]) and #allyCreeps > 0 then
            attackTarget = nEnemyBarracks[1]
            local nDist = GetUnitToUnitDistance(b, attackTarget) - b:GetAttackRange()
            if nDist > 0 then attackTime = attackTime + nDist / bMS end
            return attackTime, attackTarget
        end

        local nEnemyAncient = GetAncient(GetOpposingTeam())
        if Fu.IsInRange(b, nEnemyAncient, nRange + 80)
        and X.CanBeAttacked(nEnemyAncient) and #enemyCreeps == 0 then
            attackTarget = nEnemyAncient
            local nDist = GetUnitToUnitDistance(b, attackTarget) - b:GetAttackRange()
            if nDist > 0 then attackTime = attackTime + nDist / bMS end
            return attackTime, attackTarget
        end
    end

    local nTowers = b:GetNearbyTowers(1600, false)
    if nTowers[1] == nil or not X.IsMostAttackDamage(b) or b:GetLevel() > 12 then
        return 0, nil
    end

    if nTowers[1] ~= nil and nTowers[1]:GetAttackTarget() ~= nil then
        local towerTarget = nTowers[1]:GetAttackTarget()
        local hAllyCreepList = b:GetNearbyLaneCreeps(500, false)
        if not towerTarget:IsHero() and X.CanBeAttacked(towerTarget)
        and #hAllyCreepList == 0 and not X.IsCreepTarget(towerTarget)
        and GetUnitToUnitDistance(b, towerTarget) < b:GetAttackRange() + 100 then
            local towerRealDamage = X.GetLastHitHealth(nTowers[1], towerTarget)
            local botRealDamage   = X.GetLastHitHealth(b, towerTarget)
            local attackTime      = b:GetSecondsPerAttack() - 0.3
            local towerTargetHealth = towerTarget:GetHealth()
            if towerRealDamage > botRealDamage
            and towerTargetHealth > towerRealDamage
            and towerTargetHealth % towerRealDamage > botRealDamage then
                return attackTime, towerTarget
            end
        end
    end

    return 0, nil
end

-- ==============================
-- Items & pick/drops (unchanged logic; minor cleanup)
-- ==============================
function ItemOpsDesire()
    if DotaTime() >= ConsiderDroppedTime + 2.0 then
        for _, droppedItem in pairs(GetDroppedItemList()) do
            if droppedItem ~= nil then
                local itemName = droppedItem.item:GetName()
                if not Fu.Utils.SetContains(itemName) and not Fu.Utils.HasValue(Item['tEarlyConsumableItem'], itemName) then
                    if itemName == 'item_aegis' and Fu.GetPosition(bot) <= 3 and not Fu.HasItem(bot, 'item_aegis') then
                        if Fu.Item.GetEmptyNonBackpackInventoryAmount(bot) == 0 then
                            local lessValItem = Fu.Item.GetMainInvLessValItemSlot(bot)
                            local emptySlot = Fu.Item.GetEmptyBackpackSlot(bot)
                            if lessValItem ~= -1 and emptySlot ~= -1 then
                                bot:ActionImmediate_SwapItems(emptySlot, lessValItem)
                            end
                        end
                        PickedItem = droppedItem
                    end
                    if itemName == 'item_cheese' and Fu.GetPosition(bot) <= 3 and not Fu.HasItem(bot, 'item_aegis') then
                        PickedItem = droppedItem
                    end
                    if itemName == 'item_refresher_shard' then
                        local mostCDHero = Fu.GetMostUltimateCDUnit()
                        if mostCDHero ~= nil and mostCDHero:IsBot() and bot == mostCDHero then
                            PickedItem = droppedItem
                        end
                    end
                    local nDropOwner = droppedItem.owner
                    if nDropOwner ~= nil and nDropOwner == bot and not string.find(itemName, 'token') then
                        PickedItem = droppedItem
                    end
                    if PickedItem ~= nil and GetItemCost(itemName) > minPickItemCost then
                        return RemapValClamped(Fu.Utils.GetLocationToLocationDistance(droppedItem.location, bot:GetLocation()),
                            5000, 0, BOT_ACTION_DESIRE_NONE, BOT_ACTION_DESIRE_VERYHIGH)
                    end
                end
            end
        end
        ConsiderDroppedTime = DotaTime()
    end

    TrySellOrDropItem()
    SwapSmokeSupport()
    TrySwapInvItemForCheese()
    TrySwapInvItemForRefresherShard()
    TrySwapInvItemForClarity()
    TrySwapInvItemForFlask()
    TrySwapInvItemForSmoke()
    TrySwapInvItemForMoonshard()
end

function ItemOpsThink()
    if PickedItem ~= nil then
        if Fu.Item.GetEmptyInventoryAmount(bot) > 0 and not PickedItem.item:IsNull() then
            local itemName = PickedItem.item:GetName()
            if tryPickCount >= 3 and not Utils.SetContains(itemName) then
                tryPickCount = 0
                Utils.AddToSet(ignorePickupList, PickedItem.item)
            end
            if not Utils.SetContains(itemName) and not Utils.HasValue(Item['tEarlyConsumableItem'], itemName) then
                if itemName == 'item_aegis' or itemName == 'item_cheese' then
                    if Fu.GetPosition(bot) <= 3 and not Fu.HasItem(bot, 'item_aegis') then
                        GoPickUpItem(PickedItem)
                    end
                else
                    GoPickUpItem(PickedItem)
                end
            end
        end
    end
end

function GoPickUpItem(goPickItem)
    local distance = GetUnitToLocationDistance(bot, goPickItem.location)
    if distance > 200 and distance < 2000 then
        bot:Action_MoveToLocation(goPickItem.location)
    elseif distance <= 100 then
        tryPickCount = tryPickCount + 1
        bot:Action_PickUpItem(goPickItem.item)
        return
    end
end

-- Swap smoke after killing Roshan
function SwapSmokeSupport()
	if Fu.IsDoingRoshan(bot)
	then
		local botTarget = bot:GetAttackTarget()

		if Fu.IsRoshan(botTarget)
		and Fu.IsAttacking(bot)
		then
			local smokeSlot = bot:FindItemSlot('item_smoke_of_deceit')

			if bot:GetItemSlotType(smokeSlot) == ITEM_SLOT_TYPE_BACKPACK
			then
				local leastCostItem = Fu.FindLeastExpensiveItemSlot()
	
				if leastCostItem ~= -1
				then
					bot:ActionImmediate_SwapItems(smokeSlot, leastCostItem)
				end
			end
		end
	end
end
-- Swap Items for healing
function TrySwapInvItemForClarity()
	if 	DotaTime() >= SwappedClarityTime + 6.3
	and bot:GetActiveMode() ~= BOT_MODE_WARD
	then
		local cSlot = bot:FindItemSlot('item_clarity')
		if cSlot and bot:GetItemSlotType(cSlot) == ITEM_SLOT_TYPE_BACKPACK
		then
			local lessValItem = Fu.Item.GetMainInvLessValItemSlot(bot)

			if lessValItem ~= -1
			then
				bot:ActionImmediate_SwapItems(cSlot, lessValItem)
			end
		end

		SwappedClarityTime = DotaTime()
	end
end
function TrySwapInvItemForFlask()
	if 	DotaTime() >= SwappedFlaskTime + 6.2
	and bot:GetActiveMode() ~= BOT_MODE_WARD
	then
		local cSlot = bot:FindItemSlot('item_flask')
		if cSlot and bot:GetItemSlotType(cSlot) == ITEM_SLOT_TYPE_BACKPACK
		then
			local lessValItem = Fu.Item.GetMainInvLessValItemSlot(bot)

			if lessValItem ~= -1
			then
				bot:ActionImmediate_SwapItems(cSlot, lessValItem)
			end
		end

		SwappedFlaskTime = DotaTime()
	end
end

function TrySwapInvItemForSmoke()
	if 	DotaTime() >= SwappedSmokeTime + 15
	then
		local cSlot = bot:FindItemSlot('item_smoke_of_deceit')
		if cSlot and bot:GetItemSlotType(cSlot) == ITEM_SLOT_TYPE_BACKPACK
		then
			local lessValItem = Fu.Item.GetMainInvLessValItemSlot(bot)

			if lessValItem ~= -1
			then
				bot:ActionImmediate_SwapItems(cSlot, lessValItem)
			end
		end

		SwappedSmokeTime = DotaTime()
	end
end

-- Swap Items for moonshard
function TrySwapInvItemForMoonshard()
	if DotaTime() >= SwappedMoonshardTime + 10.0
	and bot:GetActiveMode() ~= BOT_MODE_WARD
	then
		local cSlot = bot:FindItemSlot('item_moon_shard')
		if cSlot and bot:GetItemSlotType(cSlot) == ITEM_SLOT_TYPE_BACKPACK
		then
			local lessValItem = Fu.Item.GetMainInvLessValItemSlot(bot)

			if lessValItem ~= -1
			then
				bot:ActionImmediate_SwapItems(cSlot, lessValItem)
			end
		end
		SwappedMoonshardTime = DotaTime()
	end
end

-- Swap Items for Cheese
function TrySwapInvItemForCheese()
	if 	DotaTime() >= SwappedCheeseTime + 2.3
	and bot:GetActiveMode() ~= BOT_MODE_WARD
	then
		local cSlot = bot:FindItemSlot('item_cheese')

		if bot:GetItemSlotType(cSlot) == ITEM_SLOT_TYPE_BACKPACK
		then
			local lessValItem = Fu.Item.GetMainInvLessValItemSlot(bot)

			if lessValItem ~= -1
			then
				bot:ActionImmediate_SwapItems(cSlot, lessValItem)
			end
		end

		SwappedCheeseTime = DotaTime()
	end
end

-- Swap Items for Refresher Shard
function TrySwapInvItemForRefresherShard()
	if 	DotaTime() >= SwappedRefresherShardTime + 2.2
	and bot:GetActiveMode() ~= BOT_MODE_WARD
	then
		local rSlot = bot:FindItemSlot('item_refresher_shard')

		if bot:GetItemSlotType(rSlot) == ITEM_SLOT_TYPE_BACKPACK
		then
			local lessValItem = Fu.Item.GetMainInvLessValItemSlot(bot)

			if lessValItem ~= -1
			then
				bot:ActionImmediate_SwapItems(rSlot, lessValItem)
			end
		end

		SwappedRefresherShardTime = DotaTime()
	end
end

function TrySellOrDropItem()
	if DotaTime() > 0 and DotaTime() - lastCheckBotToDropTime > 3
	then
		lastCheckBotToDropTime = DotaTime()

		-- 再尝试丢/卖掉
		if bot:GetLevel() >= 6 and bot:GetNetWorth() >= 14000 and Utils.CountBackpackEmptySpace(bot) <= 1 then
			for i = 1, #Item['tEarlyConsumableItem']
			do
				local itemName = Item['tEarlyConsumableItem'][i]
				local itemSlot = bot:FindItemSlot( itemName )
				if itemSlot >= 6 and itemSlot <= 8
				then
					local distance = bot:DistanceFromFountain()
					if distance <= 300 then
						bot:ActionImmediate_SellItem( bot:GetItemInSlot( itemSlot ))
					elseif distance >= 3000 then
						bot:Action_DropItem( bot:GetItemInSlot( itemSlot ), bot:GetLocation() )
					end
				end
			end
		end
	end
end

function Fu.FindLeastExpensiveItemSlot()
	local minCost = 100000
	local idx = -1

	for i = 0, 5
	do
		if bot:GetItemInSlot(i) ~= nil
		and bot:GetItemInSlot(i):GetName() ~= 'item_aegis'
		and bot:GetItemInSlot(i):GetName() ~= 'item_rapier'
		then
			local item = bot:GetItemInSlot(i):GetName()

			if GetItemCost(item) < minCost
			and not (item == 'item_ward_observer' or item == 'item_ward_sentry')
			then
				minCost = GetItemCost(item)
				idx = i
			end
		end
	end

	return idx
end

if SafeCall then
  local _origGetDesire = GetDesire
  local _origThink = Think
  if _origGetDesire then GetDesire = SafeCall(_origGetDesire, 0, 'TEAM_ROAM_GetDesire') end
  if _origThink then Think = SafeCall(_origThink, nil, 'TEAM_ROAM_Think') end
end

X.GetDesire = GetDesire
X.Think = Think

return X
