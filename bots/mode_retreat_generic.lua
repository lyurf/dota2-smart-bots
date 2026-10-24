local X = {}

local Fu = require(GetScriptDirectory()..'/FuncLib/func_utils')
local MatchReport = require(GetScriptDirectory()..'/FuncLib/systems/match_report')

local bot = GetBot()

local botHP, botMP, botName, botHealth, botHealthRegen, botManaRegen, botLocation, botTarget
local botLevel, botActiveMode
local nAllyHeroes, nEnemyHeroes

local fRetreatFromTormentorTime = 0
local fRetreatFromRoshanTime   = 0

local fCurrentRunTime = 0
local fShouldRunTime  = 0

local hTeamAncient, hEnemyAncient

--------------------------------------------------------------------
-- Context: single-pass unit scan, built once per GetDesireHelper()
--------------------------------------------------------------------
local C = {
    allyHeroes = {},
    enemyHeroes = {},
    enemyNearbyExtra = 0,
    allyNearbyExtra  = 0,
    allyTowers1200   = nil,
    enemyTowers1200  = nil,
    enemyLaneCreeps1200 = nil,
    aegisNearby1200  = false,
}

local function scanDroppedForAegis(radius)
    for _, dropped in pairs(GetDroppedItemList()) do
        if dropped and dropped.item:GetName() == 'item_aegis'
           and GetUnitToLocationDistance(bot, dropped.location) < radius
        then
            return true
        end
    end
    return false
end

local function buildContext()
    C.allyHeroes, C.enemyHeroes = {}, {}
    C.enemyNearbyExtra, C.allyNearbyExtra = 0, 0

    C.allyTowers1200      = bot:GetNearbyTowers(1200, false)
    C.enemyTowers1200     = bot:GetNearbyTowers(1200, true)
    C.enemyLaneCreeps1200 = bot:GetNearbyLaneCreeps(1200, true)

    local unitList = GetUnitList(UNIT_LIST_ALL)
    for _, u in pairs(unitList) do
        if Fu.IsValid(u)
           and u:GetTeam() ~= TEAM_NEUTRAL
           and u:GetTeam() ~= TEAM_NONE
           and not string.find(botName, 'lone_druid_bear')
           and not u:HasModifier('modifier_necrolyte_reapers_scythe')
           and not u:HasModifier('modifier_dazzle_nothl_projection_physical_body_debuff')
           and not u:HasModifier('modifier_skeleton_king_reincarnation_scepter_active')
           and not u:HasModifier('modifier_item_helm_of_the_undying_active')
           and not u:HasModifier('modifier_teleporting')
        then
            if Fu.IsValidHero(u)
               and GetUnitToUnitDistance(bot, u) <= 1600
               and ((Fu.IsSuspiciousIllusion(u) and u:HasModifier('modifier_arc_warden_tempest_double')) or not Fu.IsSuspiciousIllusion(u))
               and not Fu.IsMeepoClone(u)
            then
                if GetTeam() == u:GetTeam() then
                    table.insert(C.allyHeroes, u)
                else
                    table.insert(C.enemyHeroes, u)
                end
            end

            -- Special units within 1200 (golem/tombstone/sun/tower damage)
            if Fu.IsInRange(bot, u, 1200) then
                local name = u:GetUnitName()
                if bot:GetTeam() ~= u:GetTeam() then
                    if string.find(name, 'warlock_golem')
                        or string.find(name, 'tombstone')
                        or string.find(name, 'npc_dota_phoenix_sun')
                    then
                        C.enemyNearbyExtra = C.enemyNearbyExtra + 1
                    end
                    -- Tower damage as extra enemy count
                    if string.find(name, 'tower') then
                        local towerDamage = bot:GetActualIncomingDamage(u:GetAttackDamage() * u:GetAttackSpeed() * 5.0, DAMAGE_TYPE_PHYSICAL) - botHealthRegen * 5.0
                        if towerDamage / botHealth >= 0.5 then
                            C.enemyNearbyExtra = C.enemyNearbyExtra + 1
                        end
                    end
                else
                    if string.find(name, 'npc_dota_phoenix_sun') then
                        C.allyNearbyExtra = C.allyNearbyExtra + 1
                    end
                end
            end
        end
    end

    C.aegisNearby1200 = scanDroppedForAegis(1200)
    return C
end

--------------------------------------------------------------------
-- GetDesire
--------------------------------------------------------------------
function GetDesire()
    -- Smart Bots: [DEATH] and [GAME mm:00] console reports (runs while dead too)
    MatchReport.Update(bot, Fu.GetPosition(bot))
    if ShouldSkipBotThink(GetBot()) then return 0 end
    return GetDesireHelper()
end

function GetDesireHelper()
    botActiveMode = bot:GetActiveMode()

    if not bot:IsAlive()
    or bot:HasModifier('modifier_dazzle_nothl_projection_soul_clone')
    or bot:HasModifier('modifier_skeleton_king_reincarnation_scepter_active')
    or bot:HasModifier('modifier_item_helm_of_the_undying_active')
    or (botActiveMode == BOT_MODE_EVASIVE_MANEUVERS)
    or (bot:GetUnitName() == 'npc_dota_hero_lone_druid' and bot:HasModifier('modifier_fountain_aura_buff') and DotaTime() < 0)
    or bot:HasModifier('modifier_item_satanic_unholy')
    or Fu.GetModifierTime(bot, "modifier_abaddon_borrowed_time") > 2
    or Fu.GetModifierTime(bot, "modifier_muerta_pierce_the_veil_buff") > 2
    or Fu.GetModifierTime(bot, 'modifier_dazzle_shallow_grave') > 3
    or Fu.GetModifierTime(bot, 'modifier_oracle_false_promise_timer') > 3
    then
        return BOT_MODE_DESIRE_NONE
    end

    -- Cache bot state
    botHP          = Fu.GetHP(bot)
    botMP          = Fu.GetMP(bot)
    botName        = bot:GetUnitName()
    botHealth      = bot:GetHealth()
    botHealthRegen = bot:GetHealthRegen()
    botManaRegen   = bot:GetManaRegen()
    botLocation    = bot:GetLocation()
    botTarget      = Fu.GetProperTarget(bot)
    botLevel       = bot:GetLevel()
    hTeamAncient   = GetAncient(GetTeam())
    hEnemyAncient  = GetAncient(GetOpposingTeam())

    -- Build world context once
    buildContext()
    nAllyHeroes  = C.allyHeroes
    nEnemyHeroes = C.enemyHeroes

    local nAllyTowers      = C.allyTowers1200
    local nEnemyTowers     = C.enemyTowers1200
    local nEnemyLaneCreeps = C.enemyLaneCreeps1200

    local bWeAreStronger = Fu.WeAreStronger(bot, 1600)
    local bTeamFight     = Fu.IsInTeamFight(bot, 1200)

    -------------------------
    -- Early exits (not part of desire formula)
    -------------------------

    -- Roshan mode stuck fix
    if botActiveMode == BOT_MODE_ROSHAN
        and not Fu.IsRoshanAlive()
        and GetUnitToLocationDistance(bot, Fu.GetCurrentRoshanLocation())
        and IsLocationVisible(Fu.GetCurrentRoshanLocation())
    then
        if not C.aegisNearby1200 then
            return BOT_MODE_DESIRE_MODERATE
        end
    end

    -- Doing Roshan/Tormentor: don't retreat unless very low HP
    if (Fu.IsDoingRoshan(bot) or Fu.IsDoingTormentor(bot)) and botHP > 0.2 then
        return BOT_MODE_DESIRE_NONE
    end

    -- Ancient under threat: reduce retreat desire so bots stay and defend.
    -- But allow retreat when severely outnumbered — feeding doesn't save the ancient.
    local nEnemiesAtAncient = Fu.GetEnemiesAroundAncient(bot, 3200)
    if nEnemiesAtAncient > 0 then
        local ancientLoc = GetAncient(bot:GetTeam()):GetLocation()
        local distToAncient = GetUnitToLocationDistance(bot, ancientLoc)
        if distToAncient < 4000 then
            local aliveAllyCount = Fu.GetNumOfAliveHeroes(false)
            local aliveEnemyCount = Fu.GetNumOfAliveHeroes(true)
            -- Severely outnumbered (e.g. 2v4+): don't force stay, let desire formula decide
            if aliveEnemyCount <= aliveAllyCount + 1 then
                -- With 2+ allies alive and not heavily outnumbered, only retreat if HP is critically low
                if aliveAllyCount >= 2 and botHP > 0.15 then
                    return BOT_MODE_DESIRE_NONE
                end
                -- Solo defender: still reduce retreat so defend mode can compete
                if aliveAllyCount >= 1 and botHP > 0.25 then
                    return BOT_MODE_DESIRE_LOW
                end
            end
        end
    end

    -- Team pushing high ground: don't retreat at healthy HP with allies
    if Fu.Utils.IsTeamPushingSecondTierOrHighGround(bot) and botHP > 0.5 then
        local pushAllies = bot:GetNearbyHeroes(1600, false, BOT_MODE_NONE) or {}
        if #pushAllies >= 2 then
            return BOT_MODE_DESIRE_NONE
        end
    end

    -- Bear is expendable after early game
    if (bot.isBear or botName == 'npc_dota_hero_lone_druid_bear')
    and not Fu.IsEarlyGame() then
        if botHP >= 0.3 then
            local allies = bot:GetNearbyHeroes(1200, false, BOT_MODE_NONE) or {}
            if #allies >= 2 then
                return BOT_MODE_DESIRE_NONE
            end
        end
    end

    -- Safe with allies: HP > 30%, 3+ allies, no enemies, no recent damage
    if botHP > 0.3
    and #nAllyHeroes >= 3
    and #nEnemyHeroes == 0
    and not bot:WasRecentlyDamagedByAnyHero(1.0)
    and not bot:WasRecentlyDamagedByTower(1.0)
    then
        return BOT_MODE_DESIRE_NONE
    end

    -- WK reincarnation ready in teamfight
    if bTeamFight and botName == "npc_dota_hero_skeleton_king" and botLevel >= 6 then
        local abilityR = bot:GetAbilityByName("skeleton_king_reincarnation")
        if abilityR:GetCooldownTimeRemaining() <= 1.0 and bot:GetMana() >= 160 then
            return BOT_MODE_DESIRE_NONE
        end
    end

    -- Pre-horn: retreat from human enemies
    if DotaTime() < 0 and botHP < 1 then
        for _, enemy in pairs(nEnemyHeroes) do
            if Fu.IsValidHero(enemy) and not enemy:IsBot() then
                return RemapValClamped(botHP, 1, 0.1, BOT_MODE_DESIRE_HIGH, BOT_MODE_DESIRE_ABSOLUTE)
            end
        end
    end

    -- Lone Druid aegis retrieval (not actual retreat)
    if (botName == 'npc_dota_hero_lone_druid' and DotaTime() > 25 and DotaTime() < fRetreatFromRoshanTime + 6.5) then
        return 3.33
    end
    local vRoshanLocation = Fu.GetCurrentRoshanLocation()
    if botName == 'npc_dota_hero_lone_druid'
        and botActiveMode == BOT_MODE_ITEM
        and GetUnitToLocationDistance(bot, vRoshanLocation)
        and IsLocationVisible(vRoshanLocation)
    then
        if C.aegisNearby1200 then
            fRetreatFromRoshanTime = DotaTime()
            return 3.33
        end
    end

    -------------------------
    -- Modifier-based retreat
    -------------------------
    if bot:HasModifier('modifier_fountain_fury_swipes_damage_increase')
        or (not bTeamFight and Fu.IsTargetedByEnemyWithModifier(nEnemyHeroes, 'modifier_skeleton_king_reincarnation_scepter_active'))
        or (not bTeamFight and Fu.IsTargetedByEnemyWithModifier(nEnemyHeroes, 'modifier_item_helm_of_the_undying_active'))
    then
        return BOT_MODE_DESIRE_ABSOLUTE
    end

    if (bot:HasModifier('modifier_doom_bringer_doom_aura_enemy') and (#nEnemyHeroes > 0 or #nEnemyHeroes > #nAllyHeroes + 1))
        or (bot:HasModifier('modifier_razor_static_link_debuff') and Fu.IsUnitNearby(bot, nEnemyHeroes, 700, 'npc_dota_hero_razor', true) and #nEnemyHeroes >= #nAllyHeroes)
        or (bot:HasModifier('modifier_ursa_fury_swipes_damage_increase') and not bTeamFight and Fu.IsUnitNearby(bot, nEnemyHeroes, 700, 'npc_dota_hero_ursa', true))
        or (bot:HasModifier('modifier_ice_blast') and not bTeamFight and #nEnemyHeroes > #nAllyHeroes)
    then
        return BOT_MODE_DESIRE_ABSOLUTE
    end

    -- Huskar: ignore low HP if berserker's blood is active
    if botName == 'npc_dota_hero_huskar' and not bot:HasModifier('modifier_item_spirit_vessel_damage') then
        local hAbility = bot:GetAbilityByName('huskar_berserkers_blood')
        if hAbility and hAbility:IsTrained() and hAbility:GetLevel() >= 3 then
            if botHP > 0.2 and botHealthRegen > 30 then botHP = 1 end
            if botHP < 0.3 and (#nEnemyHeroes == 0 and Fu.HasItem(bot, 'item_armlet')) then botHP = 1 end
        end
    end

    -- Near fountain with recent damage: gradual retreat
    if bot:DistanceFromFountain() <= 4000 and not bTeamFight then
        if (botHP <= 0.6 or botMP < 0.4) then
            return BOT_MODE_DESIRE_VERYHIGH
        end
    end

    -- Fountain aura: stay until healed (but leave earlier if ancient is under threat)
    if bot:HasModifier('modifier_fountain_aura_buff') then
        local bAncientThreat = nEnemiesAtAncient and nEnemiesAtAncient > 0
        if bAncientThreat then
            -- Ancient under threat: leave fountain at 50% HP to defend, don't wait for 90%
            if botHP <= 0.5 then
                return BOT_MODE_DESIRE_ABSOLUTE
            end
            -- Above 50% HP, let defend mode take over
        elseif botHP <= 0.9 or (botMP <= 0.8 and botName ~= 'npc_dota_hero_huskar') then
            return BOT_MODE_DESIRE_ABSOLUTE
        end

        if (#nEnemyHeroes > #nAllyHeroes) and not bWeAreStronger and not Fu.CanBeAttacked(hTeamAncient) then
            return BOT_MODE_DESIRE_HIGH
        end
    end

    -- Creep damage during laning
    if Fu.IsInLaningPhase() or (Fu.IsEarlyGame() and botHP < 0.35) then
        local nEnemyCreeps = bot:GetNearbyCreeps(600, true)
        if Fu.IsGoingOnSomeone(bot) and #nEnemyCreeps >= 4 and bot:WasRecentlyDamagedByCreep(3.0) then
            return BOT_MODE_DESIRE_VERYHIGH
        end
    end

    -------------------------
    -- ShouldRun (hard override, rare triggers only)
    -------------------------
    if bot:IsAlive() and not bot:HasModifier('modifier_fountain_aura_buff') then
        if fCurrentRunTime ~= 0 and DotaTime() < fCurrentRunTime + fShouldRunTime then
            return BOT_DESIRE_OVERRIDE * 1.1
        else
            fCurrentRunTime = 0
        end

        fShouldRunTime = X.ShouldRun()
        if fShouldRunTime ~= 0 then
            if fCurrentRunTime == 0 then
                fCurrentRunTime = DotaTime()
            end
            return BOT_DESIRE_OVERRIDE * 1.1
        end
    end

    -------------------------
    -- Try complete items near fountain
    -------------------------
    local nCompletItemDesire = X.ConsiderCompleteItem()
    if nCompletItemDesire > 0 then
        return nCompletItemDesire
    end

    -------------------------
    -- HP-based desire formula
    -------------------------
    local nEnemyNearbyCount = #nEnemyHeroes
    local nAllyNearbyCount  = #nAllyHeroes

    -- Fog awareness: count recently-seen enemies
    local unseenCount = 0
    for _, id in pairs(GetTeamPlayers(GetOpposingTeam())) do
        if IsHeroAlive(id) then
            local info = GetHeroLastSeenInfo(id)
            if info ~= nil then
                local dInfo = info[1]
                if dInfo ~= nil and GetUnitToLocationDistance(bot, dInfo.location) <= 3200 and dInfo.time_since_seen <= 5.0 then
                    unseenCount = unseenCount + 1
                end
            end
        end
    end
    nEnemyNearbyCount = Max(nEnemyNearbyCount, unseenCount)

    -- Apply special unit extras (golem/tombstone/sun/tower)
    nEnemyNearbyCount = nEnemyNearbyCount + C.enemyNearbyExtra
    nAllyNearbyCount  = nAllyNearbyCount  + C.allyNearbyExtra

    -- Laning near ally tower bonus
    if Fu.IsInLaningPhase()
        and Fu.IsValidBuilding(nAllyTowers[1])
        and bot:HasModifier('modifier_tower_aura_bonus')
        and #nEnemyLaneCreeps <= 1
    then
        nAllyNearbyCount = nAllyNearbyCount + 1
    end

    -- Ally WK reincarnation / Aegis count as extra ally
    for _, ally in pairs(nAllyHeroes) do
        if Fu.IsValidHero(ally) and not ally:IsIllusion()
            and (GetUnitToUnitDistance(bot, ally) / ally:GetCurrentMovementSpeed()) <= 6.0
        then
            if Fu.IsHaveAegis(ally) then
                nAllyNearbyCount = nAllyNearbyCount + 1
            end
            if ally:GetUnitName() == 'npc_dota_hero_skeleton_king' then
                local hAbility = ally:GetAbilityByName('skeleton_king_reincarnation')
                if hAbility and hAbility:IsTrained() and hAbility:GetCooldownTimeRemaining() == 0 and ally:GetMana() > hAbility:GetManaCost() * 1.5 then
                    nAllyNearbyCount = nAllyNearbyCount + 1
                end
            end
        end
    end

    -- Regen projection: 5s lookahead
    botHP = Clamp(botHP + (botHealthRegen * 5.0 / bot:GetMaxHealth()), 0, 1)
    botMP = Clamp(botMP + (botManaRegen * 5.0 / bot:GetMaxMana()), 0, 1)

    local nHealth = 0
    if botName == 'npc_dota_hero_medusa' then
        local unitHealth    = botHealth - (bot:GetMana() * 0.98 * (2 + 0.1 * botLevel))
        local unitMaxHealth = bot:GetMaxHealth() - (bot:GetMaxMana() * 0.98 * (2 + 0.1 * botLevel))
        nHealth = (unitHealth / unitMaxHealth) * 0.2 + botMP * 0.8
    elseif botName == 'npc_dota_hero_huskar' then
        nHealth = botHP
    else
        nHealth = botHP * 0.8 + botMP * 0.2
    end

    local one = GetAdjustedDesireValue(1)
    nHealth = RemapValClamped(nHealth, 0, 1, 0, one)
    local nDesire = one - ((nHealth + one - one * ((1 - (nHealth ^ 2) / one) ^ 4)) / 2)

    if nEnemyNearbyCount > 0 then
        if nEnemyNearbyCount - nAllyNearbyCount > 0 then
            nDesire = nDesire + (nEnemyNearbyCount - nAllyNearbyCount) * (GetAdjustedDesireValue(BOT_MODE_DESIRE_HIGH) / 4)
        end

        if not bWeAreStronger and nEnemyNearbyCount >= nAllyNearbyCount then nDesire = nDesire + GetAdjustedDesireValue(0.25) end
        if nAllyNearbyCount >= nEnemyNearbyCount or bWeAreStronger then
            if bot:HasModifier('modifier_oracle_false_promise_timer') and Fu.GetModifierTime(bot, 'modifier_oracle_false_promise_timer') > 2.0 and Fu.IsUnitNearby(bot, nAllyHeroes, 1200, 'npc_dota_hero_oracle', true) then
                nDesire = nDesire - GetAdjustedDesireValue(0.25)
            end
            if bot:HasModifier('modifier_dazzle_shallow_grave') and Fu.GetModifierTime(bot, 'modifier_dazzle_shallow_grave') >= 2.0 and Fu.IsUnitNearby(bot, nAllyHeroes, 1200, 'npc_dota_hero_dazzle', true) then
                nDesire = nDesire - GetAdjustedDesireValue(0.2)
            end
            if bot:HasModifier('modifier_item_satanic_unholy') then
                nDesire = nDesire - GetAdjustedDesireValue(0.3)
            end

            local hAbility = bot:GetAbilityByName('slark_shadow_dance')
            if Fu.CanCastAbility(hAbility)
                or (hAbility ~= nil and hAbility:IsTrained() and hAbility:GetCooldownTimeRemaining() <= 3 and bot:GetMana() >= 150)
                or (bot:HasModifier('modifier_slark_shadow_dance') and Fu.GetModifierTime(bot, 'modifier_slark_shadow_dance') > 1.5)
            then
                nDesire = nDesire - GetAdjustedDesireValue(0.3)
            end
        end
    end

    -- Enemies on/near friendly high ground: boost retreat when outnumbered or weaker
    -- Skip if all 5 allies are nearby and ready to fight
    local nEnemiesOnHG = Fu.Utils.CountEnemyHeroesOnHighGround(GetTeam())
    if nEnemiesOnHG > 0 and nAllyNearbyCount < 5 then
        local distToAncient = GetUnitToUnitDistance(bot, hTeamAncient)
        -- Bot is in/near base area (within 5000 of ancient)
        if distToAncient < 5000 then
            local aliveAllies = Fu.GetNumOfAliveHeroes(false)
            local aliveEnemies = Fu.GetNumOfAliveHeroes(true)
            -- Outnumbered globally or locally not stronger
            if aliveEnemies > aliveAllies or not bWeAreStronger then
                -- Scale boost by how badly outnumbered: +0.15 base, +0.05 per extra enemy
                local nHGBoost = 0.15 + Max(0, nEnemiesOnHG - aliveAllies) * 0.05
                nDesire = nDesire + GetAdjustedDesireValue(nHGBoost)
            end
        end
    end

    if bot:DistanceFromFountain() > 4000 then
        if (nEnemyNearbyCount == 0 and unseenCount == 0) and #nEnemyTowers == 0 then
            nDesire = nDesire - GetAdjustedDesireValue(0.25)
        end
    end

    if Fu.IsInLaningPhase() then
        if not bot:WasRecentlyDamagedByAnyHero(3.0)
            and (not bot:WasRecentlyDamagedByCreep(2.0) and botHP > 0.2)
            and (not bot:WasRecentlyDamagedByTower(2.0) and botHP > 0.2)
            and bot:DistanceFromFountain() > 4000
            and (#Fu.GetHeroesTargetingUnit(nEnemyHeroes, bot) == 0)
        then
            if botHP > 0.25
                or botHealthRegen > 20
                or bot:HasModifier('modifier_tango_heal')
                or bot:HasModifier('modifier_flask_healing')
                or bot:HasModifier('modifier_juggernaut_healing_ward_heal')
                or bot:HasModifier('modifier_item_urn_heal')
                or bot:HasModifier('modifier_item_spirit_vessel_heal')
            then
                nDesire = nDesire - GetAdjustedDesireValue(0.25)
            end
        end
    end

    -- Post-laning: reduce retreat desire when not in immediate danger
    -- Prevents bots from retreating at 50-70% HP when they should be farming
    if not Fu.IsInLaningPhase()
        and not bot:WasRecentlyDamagedByAnyHero(3.0)
        and not bot:WasRecentlyDamagedByTower(2.0)
        and botHP > 0.4
        and nEnemyNearbyCount == 0
    then
        nDesire = nDesire - GetAdjustedDesireValue(0.2)
    end

    if bot:HasModifier('modifier_slark_shadow_dance_passive_regen') then
        nDesire = nDesire - GetAdjustedDesireValue(0.25)
    end

    -- Tower targeted desire: adds up to 0.9 through normal desire competition (not ShouldRun)
    -- nDesire = nDesire + X.GetUnitDesire(1200)
    -- nDesire = nDesire + X.RetreatWhenTowerTargetedDesire()

    return Clamp(nDesire, 0.0, BOT_MODE_DESIRE_ABSOLUTE)
end

--------------------------------------------------------------------
-- ShouldRun: only truly dangerous situations
-- Returns duration in seconds. 0 = don't run.
--------------------------------------------------------------------
function X.ShouldRun()
    if bot:IsChanneling() or not bot:IsAlive() then
        return 0
    end

    -- Medusa stone gaze
    if bot:HasModifier('modifier_medusa_stone_gaze_facing') then
        local AttackTarget = bot:GetAttackTarget()
        if AttackTarget ~= nil and AttackTarget:GetUnitName() == "npc_dota_hero_medusa"
            and Fu.IsOtherAllyCanKillTarget(bot, AttackTarget)
        then
            -- ally can finish, don't run
        else
            return 3.33
        end
    end

    -- Low HP walk-to-fountain ETA
    if ((bot:GetCurrentMovementSpeed() > 330 and bot:DistanceFromFountain() < 10000) or bot:DistanceFromFountain() < 5000) and not bot:WasRecentlyDamagedByAnyHero(5.0) then
        if botName == 'npc_dota_hero_medusa' then
            local eta = bot:DistanceFromFountain() / bot:GetCurrentMovementSpeed()
            if botMP < 0.2 and botMP + ((botManaRegen * eta) / bot:GetMaxMana()) < 0.4 then
                return eta
            end
        else
            local eta = bot:DistanceFromFountain() / bot:GetCurrentMovementSpeed()
            if botHP < 0.2 and botHP + ((botHealthRegen * eta) / bot:GetMaxHealth()) < 0.4 then
                return eta
            end
        end
    end

    -- Enemy-specific dangers
    for _, enemyHero in pairs(nEnemyHeroes) do
        if Fu.IsValidHero(enemyHero)
            and not Fu.IsSuspiciousIllusion(enemyHero)
            and not enemyHero:HasModifier('modifier_necrolyte_reapers_scythe')
        then
            local enemyHeroAttackRange = enemyHero:GetAttackRange()
            if enemyHero:HasModifier('modifier_muerta_pierce_the_veil_buff') and Fu.IsInRange(bot, enemyHero, enemyHeroAttackRange) and botHP < 0.5 then
                local fModifierTime = Fu.GetModifierTime(enemyHero, 'modifier_muerta_pierce_the_veil_buff')
                if enemyHero:GetEstimatedDamageToTarget(false, bot, fModifierTime, DAMAGE_TYPE_MAGICAL) >= (botHealth + botHealthRegen * fModifierTime) then
                    return fModifierTime
                end
            elseif enemyHero:HasModifier('modifier_bristleback_active_conical_quill_spray') and Fu.IsInRange(bot, enemyHero, 400) and not enemyHero:IsFacingLocation(botLocation, 70) then
                return 3
            end
        end
    end

	-- Wisdom shrine near enemy T1: boost retreat only if alone or in laning phase
	if BOT_MODE_WISDOM_SHRINE
		and bot:GetActiveMode() == BOT_MODE_WISDOM_SHRINE
		and bot:GetActiveModeDesire() >= BOT_MODE_DESIRE_HIGH then
		local enemyT1 = nil
		if GetTeam() == TEAM_RADIANT then
			enemyT1 = GetTower(TEAM_DIRE, TOWER_BOT_1)
		else
			enemyT1 = GetTower(TEAM_RADIANT, TOWER_TOP_1)
		end
		if enemyT1 ~= nil and enemyT1:IsAlive() and GetUnitToUnitDistance(bot, enemyT1) < 1600 then
			local nAllies = Fu.GetAllyCount(bot, 1600)
			if Fu.IsInLaningPhase() or nAllies < 3 then
				return 2
			end
		end
	end

    -- Enemy fountain proximity
    local enemyFountainDistance = Fu.GetDistanceFromEnemyFountain(bot)
    if enemyFountainDistance < 1560 then
        return 2
    end

    -- Early game: don't chase unkillable targets deep in enemy territory
    if DotaTime() > 30 and Fu.IsEarlyGame() then
        local botLane = bot:GetAssignedLane()
        local nTeamId = GetTeam()
        local bDeepInEnemy = (botLane == LANE_TOP and enemyFountainDistance < (nTeamId == TEAM_RADIANT and 12000 or 9000))
            or (botLane == LANE_MID and enemyFountainDistance < (nTeamId == TEAM_RADIANT and 9000 or 8000))
            or (botLane == LANE_BOT and enemyFountainDistance < (nTeamId == TEAM_RADIANT and 8700 or 11500))
        if bDeepInEnemy
            and Fu.IsValidHero(botTarget) and Fu.CanBeAttacked(botTarget)
            and not Fu.IsSuspiciousIllusion(botTarget)
            and not Fu.CanKillTarget(botTarget, bot:GetAttackDamage() * 2.33, DAMAGE_TYPE_PHYSICAL)
        then
            return 2.88
        end
    end

    -- High ground with barracks + enemies alive
    local nEnemyTowersSR = bot:GetNearbyTowers(900, true)
    local nEnemyBarracks = bot:GetNearbyBarracks(900, true)
    local aliveEnemyCount = Fu.GetNumOfAliveHeroes(true)
    local enemyAncientDistance = GetUnitToUnitDistance(bot, hEnemyAncient)

    if #nEnemyBarracks >= 1 and aliveEnemyCount >= 2 then
        if #nEnemyTowersSR >= 2
            or enemyAncientDistance <= 1314
            or enemyFountainDistance <= 2828
        then
            return 2
        end
    end

    -- Enemy base: retreat if near ancient/fountain, taking tower damage with no creep cover,
    -- or HP < 90%. Only stay if actively about to kill a target within attack range.
    if enemyAncientDistance <= 2000 or enemyFountainDistance <= 3000 then
        local nAllyCreepsSR = bot:GetNearbyLaneCreeps(900, false)
        local bTowerDanger = bot:WasRecentlyDamagedByTower(3.0) and #nAllyCreepsSR < 2
        if bTowerDanger or botHP < 0.9 then
            local bCanFinishTarget = false
            if Fu.IsValidHero(botTarget) and Fu.CanBeAttacked(botTarget)
                and Fu.IsInRange(bot, botTarget, bot:GetAttackRange() + 150)
                and Fu.CanKillTarget(botTarget, bot:GetAttackDamage(), DAMAGE_TYPE_PHYSICAL)
            then
                bCanFinishTarget = true
            end
            if not bCanFinishTarget then
                return 4
            end
        end
    end

    return 0
end

--------------------------------------------------------------------
-- GetUnitDesire: retreat from dangerous summons (kept for future use)
--------------------------------------------------------------------
function X.GetUnitDesire(nRadius)
    local unitList = GetUnitList(UNIT_LIST_ENEMIES)
    for _, unit in pairs(unitList) do
        if Fu.IsValid(unit)
            and not unit:IsBuilding()
            and Fu.IsInRange(bot, unit, nRadius)
        then
            local sUnitName = unit:GetUnitName()
            local unitDamage = 0
            local bIsTargetingThisBot = Fu.IsChasingTarget(unit, bot) or unit:GetAttackTarget() == bot

            if not unit:HasModifier('modifier_arc_warden_tempest_double') and Fu.IsSuspiciousIllusion(unit) then
                local tIllusions = Fu.GetSameUnitType(bot, 1600, sUnitName, false)
                unitDamage = Fu.GetUnitListTotalAttackDamage(bot, tIllusions, 5.0)
                local illusionDamage = bot:GetActualIncomingDamage(unitDamage, DAMAGE_TYPE_PHYSICAL) - botHealthRegen * 5.0
                if illusionDamage / botHealth > 0.5 then
                    if illusionDamage / botHealth > 0.65 then return 0.9 else return 0.75 end
                end
            elseif string.find(sUnitName, 'warlock_golem') and bIsTargetingThisBot then
                local tWarlockGolems = Fu.GetSameUnitType(bot, 1600, sUnitName, false)
                unitDamage = Fu.GetUnitListTotalAttackDamage(bot, tWarlockGolems, 5.0)
                local golemsDamage = bot:GetActualIncomingDamage(unitDamage, DAMAGE_TYPE_PHYSICAL) - botHealthRegen * 5.0
                if golemsDamage / botHealth > 0.45 then return 0.9 end
            elseif string.find(sUnitName, 'spiderlings') and bIsTargetingThisBot and not Fu.IsInTeamFight(bot, 1600) then
                local tSpiderlings = Fu.GetSameUnitType(bot, 1600, sUnitName, true)
                unitDamage = Fu.GetUnitListTotalAttackDamage(bot, tSpiderlings, 5.0)
                local spiderlingsDamage = bot:GetActualIncomingDamage(unitDamage, DAMAGE_TYPE_PHYSICAL) - botHealthRegen * 5.0
                if spiderlingsDamage / botHealth > 0.25 then return 0.75 end
            elseif string.find(sUnitName, 'eidolon') and bIsTargetingThisBot and not Fu.IsInTeamFight(bot, 1600) then
                local tEidolons = Fu.GetSameUnitType(bot, 1600, sUnitName, true)
                unitDamage = Fu.GetUnitListTotalAttackDamage(bot, tEidolons, 5.0)
                local eidolonDamage = bot:GetActualIncomingDamage(unitDamage, DAMAGE_TYPE_PHYSICAL) - botHealthRegen * 5.0
                if eidolonDamage / botHealth > 0.25 then return 0.9 end
            end
        end
    end
    return 0
end

--------------------------------------------------------------------
-- RetreatWhenTowerTargetedDesire: desire-based tower safety (kept for future use)
--------------------------------------------------------------------
function X.RetreatWhenTowerTargetedDesire()
    if DotaTime() > 10 * 60 or Fu.IsInTeamFight(bot, 1600) then
        return 0
    end

    local nEnemyTowers = bot:GetNearbyTowers(800, true)

    if Fu.IsValidBuilding(nEnemyTowers[1]) and not Fu.IsPushing(bot) then
        if Fu.IsGoingOnSomeone(bot) then
            if Fu.IsValidHero(botTarget)
                and not Fu.IsSuspiciousIllusion(botTarget)
                and not botTarget:HasModifier('modifier_dazzle_shallow_grave')
                and not botTarget:HasModifier('modifier_necrolyte_reapers_scythe')
            then
                local nDamage = bot:GetEstimatedDamageToTarget(true, botTarget, 5.0, DAMAGE_TYPE_ALL) * 1.2
                nDamage = botTarget:GetActualIncomingDamage(nDamage, DAMAGE_TYPE_ALL)
                if nDamage / botTarget:GetHealth() < 0.88 then
                    return 0.9
                end
            end
        end

        if nEnemyTowers[1]:GetAttackTarget() == bot then
            return 0.9
        end
    end

    return 0
end

--------------------------------------------------------------------
-- ConsiderCompleteItem: recipe completion near fountain
--------------------------------------------------------------------
function X.ConsiderCompleteItem()
    local nTeamFightLocation = Fu.GetTeamFightLocation(bot)
    if nTeamFightLocation == nil and #nEnemyHeroes == 0 and bot:DistanceFromFountain() < 4400 and not bot:HasModifier('modifier_fountain_aura_buff') then
        if Fu.Item.GetEmptyInventoryAmount(bot) == 0 then
            local bRecipeInStash = false
            local sItemRecipe = ''
            for i = 9, 14 do
                local hStashItem = bot:GetItemInSlot(i)
                if hStashItem then
                    if string.find(hStashItem:GetName(), 'item_recipe') then
                        sItemRecipe = hStashItem:GetName()
                        bRecipeInStash = true
                        break
                    end
                end
            end

            if bRecipeInStash then
                local sItemName = string.gsub(sItemRecipe, '_recipe', '')
                local tItemComponents = GetItemComponents(sItemName)[1]
                local count = 0
                for i = 0, 14 do
                    local hItem = bot:GetItemInSlot(i)
                    if hItem and not hItem:IsCombineLocked() then
                        local sItemName_ = hItem:GetName()
                        if i <= 8 and string.find(sItemName_, 'recipe') then
                            return 0
                        end
                        for j = 1, #tItemComponents do
                            if sItemName_ == tItemComponents[j] then
                                count = count + 1
                            end
                        end
                    end
                end

                if count > 0 and count == #tItemComponents then
                    return BOT_DESIRE_OVERRIDE * 1.5
                end
            end
        end
    end
    return 0
end

-- No Think function: Valve's built-in retreat handles movement, items, TP.

if SafeCall then
    local _origGetDesire = GetDesire
    if _origGetDesire then GetDesire = SafeCall(_origGetDesire, 0, 'RETREAT_GetDesire') end
end

return X
