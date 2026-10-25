import * as Fu from "bots/FuncLib/func_utils";
// eslint-disable-next-line @typescript-eslint/no-var-requires
import Customize = require("bots/FuncLib/systems/custom_loader");
import { Barracks, BotMode, BotModeDesire, DamageType, Lane, Team, Tower, Unit, UnitType, Vector } from "bots/ts_libs/dota";
import { IsValidUnit, GetLocationToLocationDistance, RadiantFountainTpPoint, DireFountainTpPoint } from "./utils";
import { getGlobalGameState, getGlobalLocationState, getCachedAlliesNearLoc, getCachedEnemiesNearLoc, autoCleanupCache } from "./cache";
import { add } from "bots/ts_libs/utils/native-operators";
import * as CK from "bots/FuncLib/systems/cache_keys";

Customize.ThinkLess = Customize.Enable ? Customize.ThinkLess : 1;

/**
 * Tunables / thresholds
 * (kept from Lua; comments preserved)
 */
const pingTimeDelta = 5;
// const BOT_MODE_DESIRE_EXTRA_LOW = 0.02; // No longer used — push returns 0 or meaningful desire

/** Module-scoped state (cache-ish). Keep small and intentional. */
let hEnemyAncient: Unit | null = null;

/** Per-tick push cache — expensive computations shared across all 15 GetPushDesire calls per tick */
let _pushCacheTick = -1;
let _pushCacheBestLane: Lane | null = null;
let _pushCacheEnemiesAtAncient = 0;
let _pushCacheEnemiesOnHG = 0;
let _pushCacheLaneBlocked: Record<number, boolean> = {};
let _pushCacheDefendPingSuppressed = false;
let _pushCacheRecentDefendTime = 0;
let nMaxDesire = 0.525;

/** 5-man push: in bot-only games, when 3+ allies push a lane, all bots join */
let _fiveManPushLane: Lane | null = null;
let _fiveManPushUntil = 0;
let _isAllBotsGame: boolean | null = null; // cached once

/** Post-defend push boost: after defend desire drops for a lane, boost push for 10s */
const _postDefendBoost: Record<number, number> = {}; // lane → time when boost expires
const _prevDefendDesire: Record<number, number> = {}; // lane → previous frame's defend desire
const POST_DEFEND_PUSH_DURATION = 10;

function refreshPushCache(team: Team): void {
    const now = GameTime();
    if (math.floor(now * 10) === _pushCacheTick) return; // same tick
    _pushCacheTick = math.floor(now * 10);

    const gameState = getGlobalGameState();
    const ourAncient = gameState.ourAncient;

    // Ancient threat
    _pushCacheEnemiesAtAncient = ourAncient !== null ? Fu.Utils.CountEnemyHeroesNear(ourAncient.GetLocation(), BASE_ANC_RADIUS) : 0;

    // Enemies on high ground
    _pushCacheEnemiesOnHG = Fu.Utils.CountEnemyHeroesOnHighGround(team);

    // Lane blocked by 2+ enemies
    _pushCacheLaneBlocked = {};
    for (const dl of [Lane.Top, Lane.Mid, Lane.Bot] as Lane[]) {
        const dlFront = GetLaneFrontLocation(team, dl, 0);
        _pushCacheLaneBlocked[dl] = Fu.Utils.CountEnemyHeroesNear(dlFront, 2200) >= 2;
    }

    // Defend ping
    const gs = (Fu.Utils as any)["GameStates"];
    _pushCacheDefendPingSuppressed = gs !== undefined && gs["defendPings"] !== undefined && now - gs["defendPings"].pingedTime <= 5.0;

    // Recent defend time
    _pushCacheRecentDefendTime = (gs || {})["recentDefendTime"] || 0;

    // Best lane (same for all bots)
    _pushCacheBestLane = null; // reset, computed lazily per-lane
}

/** Performance cache - avoid redundant calculations between GetPushDesire (300ms) and Think (every frame) */
type CachedGameState = {
    lastUpdate: number;
    currentTime: number;
    gameMode: number;
    team: Team;
    enemyTeam: Team;
    ourAncient: Unit | null;
    enemyAncient: Unit | null;
    aliveAllyCount: number;
    aliveEnemyCount: number;
    aliveAllyCoreCount: number;
    aliveEnemyCoreCount: number;
    teamNetworth: number;
    enemyNetworth: number;
    averageLevel: number;
    hasAegis: boolean;
    isEarlyGame: boolean;
    isMidGame: boolean;
    isLateGame: boolean;
    isLaningPhase: boolean;
};

type CachedLocationState = {
    lastUpdate: number;
    laneFronts: Record<Lane, Vector>;
    teamFountain: Vector;
    enemyFountain: Vector;
    roshanLocation: Vector;
    tormentorLocation: Vector;
    tormentorWaitingLocation: Vector;
};

type CachedUnitState = {
    lastUpdate: number;
    enemyBuildings: Unit[];
    alliedHeroes: Unit[];
    enemyHeroes: Unit[];
    alliedCreeps: Unit[];
    enemyCreeps: Unit[];
};

type CachedBotState = {
    lastUpdate: number;
    botId: number;
    attackRange: number;
    location: Vector;
    hp: number;
    mp: number;
    nearbyTowers: Unit[];
    nearbyLaneCreeps: Unit[];
    nearbyCreeps: Unit[];
    attackTarget: Unit | null;
    distanceToAncient: number;
    distanceToTargetLoc: number;
};

const PUSH_CACHE_TTL = 0.5; // 500ms cache TTL - increased for better performance
const BOT_CACHE_TTL = 0.2; // 200ms cache TTL for bot-specific data - increased for better performance
// Frame rate limiter removed — caused stale action replay and shared state bugs
let gameStateCache: CachedGameState | null = null;
let locationStateCache: CachedLocationState | null = null;
let unitStateCache: CachedUnitState | null = null;
let botStateCache: Record<number, CachedBotState> = {};

/** Update game state cache if needed */
function updateGameStateCache(): CachedGameState {
    const now = DotaTime();
    if (gameStateCache && now - gameStateCache.lastUpdate < PUSH_CACHE_TTL) {
        return gameStateCache;
    }

    const team = GetTeam();
    const enemyTeam = GetOpposingTeam();
    const currentTime = DotaTime();
    const gameMode = GetGameMode();

    // Adjust time for turbo mode
    const adjustedTime = gameMode === 23 ? currentTime * 2 : currentTime;

    gameStateCache = {
        lastUpdate: now,
        currentTime: adjustedTime,
        gameMode,
        team,
        enemyTeam,
        ourAncient: GetAncient(team),
        enemyAncient: GetAncient(enemyTeam),
        aliveAllyCount: Fu.GetNumOfAliveHeroes(false),
        aliveEnemyCount: Fu.GetNumOfAliveHeroes(true),
        aliveAllyCoreCount: Fu.GetAliveCoreCount(false),
        aliveEnemyCoreCount: Fu.GetAliveCoreCount(true),
        teamNetworth: Fu.GetInventoryNetworth()[0],
        enemyNetworth: Fu.GetInventoryNetworth()[1],
        averageLevel: Fu.GetAverageLevel(false),
        hasAegis: Fu.DoesTeamHaveAegis(),
        isEarlyGame: Fu.IsEarlyGame(),
        isMidGame: Fu.IsMidGame(),
        isLateGame: Fu.IsLateGame(),
        isLaningPhase: Fu.IsInLaningPhase(),
    };

    return gameStateCache;
}

/** Update location state cache if needed */
function updateLocationStateCache(): CachedLocationState {
    const now = DotaTime();
    if (locationStateCache && now - locationStateCache.lastUpdate < PUSH_CACHE_TTL) {
        return locationStateCache;
    }

    const team = GetTeam();
    locationStateCache = {
        lastUpdate: now,
        laneFronts: {
            [Lane.Top]: GetLaneFrontLocation(team, Lane.Top, 0),
            [Lane.Mid]: GetLaneFrontLocation(team, Lane.Mid, 0),
            [Lane.Bot]: GetLaneFrontLocation(team, Lane.Bot, 0),
        },
        teamFountain: Fu.GetTeamFountain(),
        enemyFountain: Fu.GetTeamFountain(), // Note: GetEnemyFountain doesn't exist, using GetTeamFountain as fallback
        roshanLocation: Fu.GetCurrentRoshanLocation(),
        tormentorLocation: Fu.GetTormentorLocation(team),
        tormentorWaitingLocation: Fu.GetTormentorWaitingLocation(team),
    };

    return locationStateCache;
}

/** Update unit state cache if needed */
function updateUnitStateCache(): CachedUnitState {
    const now = DotaTime();
    if (unitStateCache && now - unitStateCache.lastUpdate < PUSH_CACHE_TTL) {
        return unitStateCache;
    }

    unitStateCache = {
        lastUpdate: now,
        enemyBuildings: GetUnitList(UnitType.EnemyBuildings),
        alliedHeroes: GetUnitList(UnitType.AlliedHeroes),
        enemyHeroes: GetUnitList(UnitType.Enemies).filter(u => Fu.IsValidHero(u)),
        alliedCreeps: GetUnitList(UnitType.AlliedCreeps),
        enemyCreeps: GetUnitList(UnitType.Enemies).filter(u => u.IsCreep() || u.IsAncientCreep()),
    };

    return unitStateCache;
}

/** Update bot state cache if needed */
function updateBotStateCache(bot: Unit, targetLoc?: Vector): CachedBotState {
    const now = DotaTime();
    const botId = bot.GetPlayerID();
    const cached = botStateCache[botId];

    if (cached && now - cached.lastUpdate < BOT_CACHE_TTL) {
        return cached;
    }

    const location = bot.GetLocation();
    const attackRange = bot.GetAttackRange();
    const gameState = updateGameStateCache();

    botStateCache[botId] = {
        lastUpdate: now,
        botId,
        attackRange,
        location,
        hp: Fu.GetHP(bot),
        mp: Fu.GetMP(bot),
        nearbyTowers: bot.GetNearbyTowers(1200, true),
        nearbyLaneCreeps: bot.GetNearbyLaneCreeps(1200, false),
        nearbyCreeps: bot.GetNearbyCreeps(1600, true),
        attackTarget: bot.GetAttackTarget(),
        distanceToAncient: gameState.enemyAncient ? GetUnitToUnitDistance(bot, gameState.enemyAncient) : Number.POSITIVE_INFINITY,
        distanceToTargetLoc: targetLoc ? GetUnitToLocationDistance(bot, targetLoc) : 0,
    };

    return botStateCache[botId];
}

/**
 * === Objective selection stability (anti-thrash) ===
 * (kept from Lua; comments preserved)
 */
const OBJECTIVE_STICKY_TIME = 1.2; // seconds to keep current target before reconsidering
const SWITCH_SCORE_MARGIN = 0.25; // how much better (lower) the new score must be to switch
const OBJECTIVE_LEASH_RANGE = 2600; // max distance from bot to consider high-ground objectives

// Barracks ≈ 200 from T3, T4 ≈ 800 from barracks; favor inner-ring first
// Lower score is better. Priority: Barracks (melee>ranged) < T3 < T4 < Fillers
const SCORE_BARRACKS_RANGED = 0; // Ranged rax first
const SCORE_BARRACKS_MELEE = 0.1;
const SCORE_T3 = 0.5;
const SCORE_T4 = 1.8;
// const SCORE_FILLER = 1.9;

const BASE_ANC_RADIUS = 2200;

/**
 * Add per-bot, per-lane objective memory
 * Example: ObjectiveState[playerID][lane] = { target=hUnit, lockUntil=GameTime() }
 */
type LaneState = { target?: Unit | null; lockUntil?: number };
const ObjectiveState: Record<number, Partial<Record<Lane, LaneState>>> = {};

/* -----------------------------------------------------------------------------
 * Desire front-door
 * ---------------------------------------------------------------------------*/
/**
 * Smart Bots: does the team have an advantage big enough to push into defenders?
 * - at least 2 more heroes alive, or
 * - Aegis with 4+ heroes alive, or
 * - not fewer heroes alive and 8000+ net worth lead after the early game.
 */
// Smart Bots: allied heroes from the unit list. GetTeamMember() only returns the bot itself in
// per-bot sandboxes (LAN lobbies), so loops over it never saw the rest of the team.
function GetAllyHeroes(): Unit[] {
    const result: Unit[] = [];
    for (const u of GetUnitList(UnitType.AlliedHeroes)) {
        if (u !== null && Fu.IsValidHero(u) && !u.IsIllusion()) result.push(u);
    }
    return result;
}

function HasPushAdvantage(gameState: ReturnType<typeof getGlobalGameState>): boolean {
    const aAlive = gameState.aliveAllyCount;
    const eAlive = gameState.aliveEnemyCount;
    if (aAlive < 3) return false;
    if (aAlive >= eAlive + 2) return true;
    if (gameState.hasAegis && aAlive >= 4) return true;
    if (!gameState.isEarlyGame && aAlive >= eAlive && gameState.teamNetworth - gameState.enemyNetworth >= 8000) return true;
    return false;
}

export function GetPushDesire(bot: Unit, lane: Lane): BotModeDesire {
    // 0) quick invalid checks
    if (bot.IsInvulnerable() || !bot.IsHero() || !bot.IsAlive() || !bot.GetUnitName().includes("hero") || bot.IsIllusion()) {
        return BotModeDesire.None;
    }

    if (bot.GetLevel() < 6) {
        return BotModeDesire.None;
    }

    // 1) very small cache by bot+lane for stability
    // const cacheKey = `PushDesire:${bot.GetPlayerID()}:${lane ?? -1}`;
    // const cachedVar = Fu.Utils.GetCachedVars(cacheKey, 0.6);
    // if (cachedVar != null) {
    //     (bot as any).pushDesire = cachedVar;
    //     return cachedVar;
    // }

    const res = math.min(GetPushDesireHelper(bot, lane), 1.0);
    (bot as any).pushDesire = res;
    return res as BotModeDesire;
}

/* -----------------------------------------------------------------------------
 * Desire core
 * ---------------------------------------------------------------------------*/
export function GetPushDesireHelper(bot: Unit, lane: Lane): BotModeDesire {
    if ((bot as any).laneToPush == null) (bot as any).laneToPush = lane;

    nMaxDesire = 0.525; // reset per call — was only ever lowered, never restored

    autoCleanupCache();
    const gameState = getGlobalGameState();
    const locationState = getGlobalLocationState();
    const team = gameState.team;

    // Refresh per-tick cache (shared across all 15 calls)
    refreshPushCache(team);

    const botActiveMode = bot.GetActiveMode();
    const bMyLane = bot.GetAssignedLane() === lane;
    hEnemyAncient = gameState.enemyAncient;

    // --- Cheap early exits (no expensive calls) ---

    if (gameState.isLaningPhase && !bMyLane && Fu.IsCore(bot)) return BotModeDesire.None;
    if (gameState.aliveAllyCount <= gameState.aliveEnemyCount - 2) return BotModeDesire.None;
    if (_pushCacheDefendPingSuppressed) return BotModeDesire.None;
    if (_pushCacheEnemiesAtAncient >= 1) return BotModeDesire.None;
    // Smart Bots: a team with a clear advantage (more heroes alive, Aegis or a big net worth lead)
    // pushes through defenders like a pro team instead of waiting until the enemy dies.
    const bTeamAdvantage = HasPushAdvantage(gameState);

    // Smart Bots: Aegis window. After Roshan the whole team groups on one lane (the same lane in
    // every bot's script) and pushes while the Aegis lasts, forcing the enemy to fight under
    // their tower at a disadvantage - instead of going back to farming.
    if (gameState.hasAegis && gameState.aliveAllyCount >= 4 && !gameState.isLaningPhase && bot.GetLevel() >= 6) {
        if (_pushCacheBestLane === null) {
            _pushCacheBestLane = WhichLaneToPush(bot, lane);
        }
        if (lane !== _pushCacheBestLane) return BotModeDesire.None;
        const nextBuilding = GetNextEnemyBuildingOnLane(lane);
        if (nextBuilding !== null && Fu.GetHP(bot) > 0.4) {
            return 0.6 as BotModeDesire;
        }
    }

    if (_pushCacheLaneBlocked[lane] && !bTeamAdvantage) return BotModeDesire.None;

    // During laning phase, all team members must be level 6+ to push.
    // After laning, only require the pushing bot itself to be 6+ (checked above).
    if (gameState.isLaningPhase) {
        for (const member of GetAllyHeroes()) {
            if (member.GetLevel() < 6) return BotModeDesire.None;
        }
    }

    // Don't push alone into enemies
    const nInRangeAlly = Fu.GetAlliesNearLoc(bot.GetLocation(), 1600);
    const nInRangeEnemy = Fu.GetEnemiesNearLoc(bot.GetLocation(), 1600);
    let nInRangeAllyCore = 0;
    let nInRangeEnemyCore = 0;
    for (const ally of nInRangeAlly) {
        if (Fu.IsValidHero(ally) && Fu.IsCore(ally)) nInRangeAllyCore++;
    }
    for (const enemy of nInRangeEnemy) {
        if (Fu.IsValidHero(enemy) && Fu.IsCore(enemy)) nInRangeEnemyCore++;
    }
    if ((nInRangeAlly.length < nInRangeEnemy.length && nInRangeAllyCore < nInRangeEnemyCore) || (nInRangeAlly.length <= 1 && nInRangeEnemy.length > 0)) {
        return BotModeDesire.None;
    }

    // Sync lane selection with hard bot modes
    if (botActiveMode === BotMode.PushTowerTop) (bot as any).laneToPush = Lane.Top;
    else if (botActiveMode === BotMode.PushTowerMid) (bot as any).laneToPush = Lane.Mid;
    else if (botActiveMode === BotMode.PushTowerBot) (bot as any).laneToPush = Lane.Bot;

    // --- Per-bot checks (can't cache, depends on bot position) ---

    const alliesHere = getCachedAlliesNearLoc(bot.GetLocation(), 1600);
    const enemiesHere = getCachedEnemiesNearLoc(bot.GetLocation(), 1600);
    const enemyFountain = team === Team.Radiant ? DireFountainTpPoint : RadiantFountainTpPoint;
    const laneFront = GetLaneFrontLocation(team, lane, 0);

    if (alliesHere.length <= 1 && gameState.aliveEnemyCount >= 3) return BotModeDesire.None;

    // --- nMaxDesire caps ---
    const isDeepPush = GetLocationToLocationDistance(laneFront, enemyFountain) < 5000;

    if (isDeepPush && (alliesHere.length < 3 || gameState.aliveAllyCount < gameState.aliveEnemyCount)) {
        nMaxDesire = math.min(nMaxDesire, 0.15);
    }
    if (Fu.GetHP(bot) < 0.5) {
        nMaxDesire = math.min(nMaxDesire, 0.25);
    }
    if (gameState.aliveEnemyCount >= 5 && gameState.aliveAllyCount <= gameState.aliveEnemyCount) {
        nMaxDesire = math.min(nMaxDesire, 0.41);
    }

    // Doing Roshan with team → don't push
    if (Fu.IsDoingRoshan(bot) && Fu.GetAlliesNearLoc(locationState.roshanLocation, 2800).length >= 3) {
        return BotModeDesire.None;
    }

    // Respect allied "attack here" human ping on a tower
    const [human, humanPing] = Fu.GetHumanPing();
    if (human !== null && humanPing !== null && !humanPing.normal_ping && DotaTime() > 0) {
        const [isPinged, pingedLane] = Fu.IsPingCloseToValidTower(GetOpposingTeam(), humanPing, 700, 5.0);
        if (isPinged && lane === pingedLane && GameTime() < humanPing.time + pingTimeDelta) {
            return 0.6 as BotModeDesire; // human pinged, push this lane
        }
    }

    // Fountain rally floor bot healthy in fountain AND team
    // has enough bodies+cores to sally → force VERYHIGH to commit to the push-out.
    const ourAncient = gameState.ourAncient;
    if (Fu.IsValidBuilding(ourAncient) && IsHealthyInsideFountain(bot)) {
        const enemiesAroundAncient = Fu.GetEnemiesNearLoc(ourAncient!.GetLocation(), 1000);
        if (gameState.aliveAllyCount >= enemiesAroundAncient.length && gameState.aliveAllyCoreCount >= gameState.aliveEnemyCoreCount) {
            return 0.6 as BotModeDesire;
        }
    }

    // If close to enemy Ancient and it is hittable → all in
    if (
        hEnemyAncient &&
        GetUnitToUnitDistance(bot, hEnemyAncient) < 1000 &&
        Fu.CanBeAttacked(hEnemyAncient) &&
        Fu.GetHP(bot) > 0.4 &&
        !HasBackdoorProtect(hEnemyAncient)
    ) {
        bot.SetTarget(hEnemyAncient);
        bot.Action_AttackUnit(hEnemyAncient, true);
        return 0.6 as BotModeDesire; // ancient hittable, go all in
    }

    // If already targeting a backdoored building, stop
    const botTarget = bot.GetAttackTarget();
    if (Fu.IsValidBuilding(botTarget) && HasBackdoorProtect(botTarget!)) {
        return BotModeDesire.None;
    }

    // After taking barracks on ANY lane, push desire should stay high
    // to continue toward T4/ancient or switch to next lane
    const anyBarracksDown =
        !Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Top) || !Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Mid) || !Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Bot);
    // After barracks fall, boost push desire toward ancient (safety caps below still apply)
    let barracksDownBoost = false;
    if (anyBarracksDown && hEnemyAncient) {
        const ancientDist = GetUnitToUnitDistance(bot, hEnemyAncient);
        const alliesNearAncient = Fu.GetAlliesNearLoc(hEnemyAncient.GetLocation(), 3000);
        if (ancientDist < 3000 && alliesNearAncient.length >= 2) {
            barracksDownBoost = true;
        }
    }

    // --- Simplified push desire calculation ---
    const aAliveCount = gameState.aliveAllyCount;
    const eAliveCount = gameState.aliveEnemyCount;
    // Cache best lane per tick (WhichLaneToPush is expensive but result is global)
    if (_pushCacheBestLane === null) {
        _pushCacheBestLane = WhichLaneToPush(bot, lane);
    }
    const isCurrentLanePushLane = _pushCacheBestLane === lane;

    // Vs humans: let bots spread across lanes instead of all converging on one.
    // Each bot pushes whichever lane it's closest to, rather than the global "best" lane.
    // All-bots games keep the single-lane convergence for coordinated pressure.
    const hasEnemyHuman = Fu.Utils.IsHumanPlayerInTeam(GetOpposingTeam());
    if (hasEnemyHuman && !bTeamAdvantage) {
        // Allow pushing any lane — don't force all bots to one lane
        // Still skip if this lane has no buildings left to push
        const nextBuilding = GetNextEnemyBuildingOnLane(lane);
        if (nextBuilding === null || !Fu.IsValidBuilding(nextBuilding)) {
            return BotModeDesire.None;
        }
    } else {
        // All-bots: converge on best lane for coordinated pressure
        const distToEnemyFountain = GetLocationToLocationDistance(bot.GetLocation(), enemyFountain);
        const isDeepInEnemyTerritory = distToEnemyFountain < 5000;
        const botCurrentPushLane = (bot as any).laneToPush;
        const laneHasBarracks = Fu.Utils.IsAnyBarracksOnLaneAlive(false, lane);
        if (isDeepInEnemyTerritory && lane === botCurrentPushLane && laneHasBarracks) {
            // Committed to this lane deep in enemy base with barracks to hit — keep pushing
        } else if (!isCurrentLanePushLane) {
            return BotModeDesire.None;
        }
    }

    // Count allies pushing or near the push lane front
    let alliesPushing = 0;
    for (const member of GetAllyHeroes()) {
        if (member.IsAlive() && member !== bot) {
            const memberMode = member.GetActiveMode();
            const isPushMode = memberMode === BotMode.PushTowerTop || memberMode === BotMode.PushTowerMid || memberMode === BotMode.PushTowerBot;
            const nearLaneFront = GetUnitToLocationDistance(member, laneFront) < 2500;
            if (isPushMode || nearLaneFront) {
                alliesPushing++;
            }
        }
    }

    // --- 5-man push grouping (bot-only games) ---
    // When 3+ allies are pushing a lane past the river (closer to enemy base than ours),
    // all bots join that lane. Only enforced when deep enough to matter — otherwise
    // bots should split push different lanes for map pressure.
    if (_isAllBotsGame === null) {
        // Smart Bots: enable coordinated team pushing for any team without human players
        // (originally only in all-bot games), so enemy bots push like a team against humans.
        _isAllBotsGame = !Fu.Utils.IsHumanPlayerInTeam(GetTeam());
    }
    if (_isAllBotsGame && !gameState.isLaningPhase && !gameState.isEarlyGame) {
        // Detect: which lane has 3+ allies pushing past river?
        if (alliesPushing >= 2 && lane === _pushCacheBestLane) {
            const pushLaneFront = GetLaneFrontLocation(team, lane, 0);
            const teamFountain = team === Team.Radiant ? RadiantFountainTpPoint : DireFountainTpPoint;
            const distFrontToUs = GetLocationToLocationDistance(pushLaneFront, teamFountain);
            const distFrontToEnemy = GetLocationToLocationDistance(pushLaneFront, enemyFountain);
            // Only group up when lane front is past river (closer to enemy base)
            if (distFrontToEnemy < distFrontToUs) {
                _fiveManPushLane = lane;
                _fiveManPushUntil = DotaTime() + 8;
            }
        }
        // If a 5-man push is active, boost desire for that lane, suppress others
        if (_fiveManPushLane !== null && DotaTime() < _fiveManPushUntil) {
            if (lane === _fiveManPushLane) {
                return math.max(0.55, RemapValClamped(GetPushLaneDesire(lane), 0, 1, 0, nMaxDesire)) as BotModeDesire;
            } else {
                return BotModeDesire.None;
            }
        } else {
            _fiveManPushLane = null;
        }
    }

    // Base desire from Valve's lane push evaluation (0-1), remapped to (0-nMaxDesire)
    let nPushDesire = RemapValClamped(GetPushLaneDesire(lane), 0, 1, 0, nMaxDesire);
    // --- Precompute conditions ---
    const botLevel = bot.GetLevel();
    const botHP = Fu.GetHP(bot);
    const aAliveCoreCount = gameState.aliveAllyCoreCount;
    const eAliveCoreCount = gameState.aliveEnemyCoreCount;

    const bFavorableConditions =
        eAliveCount === 0 ||
        aAliveCoreCount >= eAliveCoreCount ||
        (aAliveCoreCount >= 1 && aAliveCount >= eAliveCount + 2) ||
        (hEnemyAncient && GetUnitToUnitDistance(bot, hEnemyAncient) < 3500 && alliesHere.length >= enemiesHere.length);
    if (!bFavorableConditions) {
        return BotModeDesire.None;
    }

    // Bonuses only after early game
    if (!gameState.isEarlyGame) {
        if (gameState.hasAegis && aAliveCount >= 4) {
            nPushDesire += 0.25;
            nMaxDesire = math.max(nMaxDesire, 0.6);
        }
        if (aAliveCount >= eAliveCount && gameState.averageLevel >= 12) {
            const networthAdvantage = gameState.teamNetworth - gameState.enemyNetworth;
            nPushDesire += RemapValClamped(networthAdvantage, 5000, 10000, 0.0, 0.5);
        }
    }

    const readyToPush = botLevel >= 6 && (!gameState.isLaningPhase || aAliveCount >= eAliveCount + 2 || (eAliveCount <= 2 && aAliveCount >= 4));

    // Early exit: HG defense active (uses cached values)
    if (_pushCacheEnemiesOnHG >= 2 && DotaTime() - _pushCacheRecentDefendTime < 10) {
        return BotModeDesire.None;
    }

    // Deep in enemy territory pushing T2/HG: back off if outnumbered and not full HP
    if (hEnemyAncient && GetLaneBuildingTier(lane) >= 2) {
        const distToEnemyAncient = GetUnitToUnitDistance(bot, hEnemyAncient);
        if (distToEnemyAncient < 6000 && alliesHere.length < eAliveCount && botHP < 0.8) {
            return BotModeDesire.None;
        }
    }

    // --- Compute result: base desire, capped by nMaxDesire ---
    let result = math.min(math.max(nPushDesire, 0), nMaxDesire);

    // === CAPS (suppress desire) ===

    // Early game: don't keep pushing a lane past T2 when other lanes still have T2 standing,
    // unless 2+ enemies are dead (safe to push deep). Encourages spreading pressure.
    const earlyPushCutoff = gameState.gameMode === 23 ? 12 * 60 : 15 * 60;
    if (DotaTime() < earlyPushCutoff) {
        const thisLaneTier = GetLaneBuildingTier(lane);
        if (thisLaneTier >= 3) {
            // T2 dead on this lane
            const deadEnemies = 5 - eAliveCount;
            if (deadEnemies < 2) {
                // Check if any other lane still has T2
                const otherLanes = lane === Lane.Top ? [Lane.Mid, Lane.Bot] : lane === Lane.Mid ? [Lane.Top, Lane.Bot] : [Lane.Top, Lane.Mid];
                const otherT2Alive = otherLanes.some(l => GetLaneBuildingTier(l) <= 2);
                if (otherT2Alive) {
                    result = math.min(result, 0.1);
                }
            }
        }
    }

    if (alliesHere.length <= 1 && enemiesHere.length >= 2) result = math.min(result, 0.2);

    // Deep push risk: team weakened → back off
    if (isDeepPush && alliesHere.length >= 2) {
        let lowHPCount = 0;
        let totalHP = 0;
        for (const ally of alliesHere) {
            if (Fu.IsValidHero(ally)) {
                const hp = Fu.GetHP(ally);
                totalHP += hp;
                if (hp < 0.4) lowHPCount++;
            }
        }
        const avgHP = alliesHere.length > 0 ? totalHP / alliesHere.length : 1;
        if (lowHPCount >= 2 && avgHP < 0.6 && eAliveCount >= alliesHere.length - 2) {
            result = math.min(result, 0.15);
        }
    }

    // === FLOORS (boost desire) — only for all-bots games to create pressure ===
    // In vs-human games, push desire stays within nMaxDesire so farm (0.7) can win.
    if (_isAllBotsGame) {
        if (!gameState.isLaningPhase) {
            result = math.max(result, 0.02);
        }
        if (readyToPush && botHP > 0.4 && !gameState.isEarlyGame) {
            if (eAliveCount <= 2 && aAliveCount >= 4) {
                result = math.max(result, eAliveCount === 0 ? 0.525 : 0.45);
            }
            if (barracksDownBoost) {
                result = math.max(result, 0.5);
            }
            // Smart Bots: with a clear advantage, group up and take objectives instead of farming
            if (bTeamAdvantage && botHP > 0.5) {
                result = math.max(result, 0.5);
            }
        }
        // Group push: if 3+ allies pushing THIS lane, supports should join
        if (isCurrentLanePushLane && Fu.GetPosition(bot) >= 4) {
            const pushModeForLane = lane === Lane.Top ? BotMode.PushTowerTop : lane === Lane.Mid ? BotMode.PushTowerMid : BotMode.PushTowerBot;
            let alliesPushingThisLane = 0;
            for (const member of GetAllyHeroes()) {
                if (member !== bot && member.IsAlive() && member.GetActiveMode() === pushModeForLane) {
                    alliesPushingThisLane++;
                }
            }
            if (alliesPushingThisLane >= 3) {
                result = math.max(result, nMaxDesire);
            }
        }
    }

    // Post-defend push momentum: only in all-bots games
    if (_isAllBotsGame) {
        const currentDefend = GetDefendLaneDesire(lane);
        const prevDefend = _prevDefendDesire[lane] || 0;
        _prevDefendDesire[lane] = currentDefend;
        if (prevDefend > 0.3 && currentDefend < 0.15) {
            _postDefendBoost[lane] = DotaTime() + POST_DEFEND_PUSH_DURATION;
        }
        if (_postDefendBoost[lane] && DotaTime() < _postDefendBoost[lane]) {
            result = math.max(result, 0.45);
        }
    }

    return result as BotModeDesire;
}

/* -----------------------------------------------------------------------------
 * Lane selection helpers
 * ---------------------------------------------------------------------------*/

/** Ally presence should make a lane cheaper (more attractive) */
function presence_adjust(score: number, loc: Vector): number {
    const allies = Fu.GetAlliesNearLoc(loc, 1600).length;
    // pull toward lanes with allies; 0.25 is mild and safe
    return score / (1 + 0.25 * allies);
}

function UnitIsValidObjective(u: Unit | null): u is Unit {
    return !!u && Fu.IsValidBuilding(u) && Fu.CanBeAttacked(u);
}

function UnitIsBarracks(u: Unit): boolean {
    const n = u != null ? u.GetUnitName() : "";
    return n.includes("rax");
}
function UnitIsMeleeBarracks(u: Unit): boolean {
    return UnitIsBarracks(u) && !!u && u.GetUnitName().includes("melee");
}
function UnitIsRangedBarracks(u: Unit): boolean {
    return UnitIsBarracks(u) && !!u && u.GetUnitName().includes("ranged");
}
/** True when the ranged barracks partner on the same lane is already destroyed. */
function IsRangedPartnerDead(u: Unit): boolean {
    if (!UnitIsMeleeBarracks(u)) return false;
    const enemy = GetOpposingTeam();
    const n = u.GetUnitName();
    let rangedPartner: Unit | null = null;
    if (n.includes("top")) rangedPartner = GetBarracks(enemy, Barracks.TopRanged);
    else if (n.includes("mid")) rangedPartner = GetBarracks(enemy, Barracks.MidRanged);
    else rangedPartner = GetBarracks(enemy, Barracks.BotRanged);
    return rangedPartner === null || !rangedPartner.IsAlive();
}
function UnitIsT3(u: Unit): boolean {
    return u === GetTower(GetOpposingTeam(), Tower.Top3) || u === GetTower(GetOpposingTeam(), Tower.Mid3) || u === GetTower(GetOpposingTeam(), Tower.Bot3);
}
function UnitIsT4(u: Unit): boolean {
    return (
        u === GetTower(GetOpposingTeam(), Tower.Base1) || u === GetTower(GetOpposingTeam(), Tower.Base2) || GetUnitToUnitDistance(u, GetAncient(GetOpposingTeam())) < 500
    );
}
// function UnitIsFiller(u: Unit): boolean {
//     // Fillers/other inner-base buildings, exclude barracks/towers
//     return Fu.IsValidBuilding(u) && !UnitIsBarracks(u) && !UnitIsT3(u) && !UnitIsT4(u);
// }

/**
 * Compute a score for an objective; lower is better.
 * Base priority + mild distance terms; prefer closer to the bot and to approach targetLoc.
 */
function UnitIsT1orT2(u: Unit): boolean {
    const enemy = GetOpposingTeam();
    return (
        u === GetTower(enemy, Tower.Top1) ||
        u === GetTower(enemy, Tower.Mid1) ||
        u === GetTower(enemy, Tower.Bot1) ||
        u === GetTower(enemy, Tower.Top2) ||
        u === GetTower(enemy, Tower.Mid2) ||
        u === GetTower(enemy, Tower.Bot2)
    );
}

const SCORE_T1T2 = 0.2;

function ObjectiveScore(bot: Unit, u: Unit | null, targetLoc?: Vector | null): number {
    if (!UnitIsValidObjective(u)) return Number.POSITIVE_INFINITY;

    let base = 2.0;
    if (UnitIsRangedBarracks(u)) base = SCORE_BARRACKS_RANGED;
    // Melee rax gets ranged priority when its ranged partner is already dead (finish the lane)
    else if (UnitIsMeleeBarracks(u)) base = IsRangedPartnerDead(u) ? SCORE_BARRACKS_RANGED : SCORE_BARRACKS_MELEE;
    else if (UnitIsT1orT2(u)) base = SCORE_T1T2;
    else if (UnitIsT3(u)) base = SCORE_T3;
    else if (UnitIsT4(u)) base = SCORE_T4;

    const dBot = GetUnitToUnitDistance(bot, u);
    if (dBot > OBJECTIVE_LEASH_RANGE) return Number.POSITIVE_INFINITY;

    const d1 = dBot / 2000.0;
    const d2 = targetLoc ? GetUnitToLocationDistance(u, targetLoc) / 2500.0 : 0;

    return base + 0.35 * d1 + 0.2 * d2;
}

/** Decide whether to keep current target or switch to a better one */
function SelectOrStickHGTarget(bot: Unit, lane: Lane, targetLoc?: Vector | null): Unit | null {
    const pid = bot.GetPlayerID();
    ObjectiveState[pid] = ObjectiveState[pid] || {};
    ObjectiveState[pid][lane] = ObjectiveState[pid][lane] || {};

    const state = ObjectiveState[pid][lane] as LaneState;
    const now = GameTime();
    const current = state.target || null;

    // Respect stickiness if current is still a valid objective
    if (current && UnitIsValidObjective(current) && now < (state.lockUntil ?? 0)) {
        return current;
    }

    const currentScore = current ? ObjectiveScore(bot, current, targetLoc) : Number.POSITIVE_INFINITY;

    // Scan candidates
    const unitState = updateUnitStateCache();
    let best: Unit | null = null;
    let bestScore = Number.POSITIVE_INFINITY;
    for (const b of unitState.enemyBuildings) {
        const sc = ObjectiveScore(bot, b, targetLoc);
        if (sc < bestScore) {
            best = b;
            bestScore = sc;
        }
    }

    // Only switch if clearly better
    if (current && UnitIsValidObjective(current)) {
        if (best && bestScore + SWITCH_SCORE_MARGIN < currentScore) {
            state.target = best;
            state.lockUntil = now + OBJECTIVE_STICKY_TIME;
            return best;
        } else {
            state.lockUntil = now + 0.6;
            return current;
        }
    }

    // Adopt best if nothing valid
    if (best) {
        state.target = best;
        state.lockUntil = now + OBJECTIVE_STICKY_TIME;
        return best;
    }

    state.target = null;
    state.lockUntil = undefined;
    return null;
}

/** Get the next enemy building to destroy on a lane (T1→T2→T3→rax→T4 order). Cached per tick. */
const _nextBuildingCache: Record<number, { tick: number; result: Unit | null }> = {};
function GetNextEnemyBuildingOnLane(lane: Lane): Unit | null {
    const tick = math.floor(GameTime() * 10);
    const cached = _nextBuildingCache[lane];
    if (cached && cached.tick === tick) return cached.result;

    const enemy = GetOpposingTeam();
    let result: Unit | null = null;

    const towerOrder =
        lane === Lane.Top ? [Tower.Top1, Tower.Top2, Tower.Top3] : lane === Lane.Mid ? [Tower.Mid1, Tower.Mid2, Tower.Mid3] : [Tower.Bot1, Tower.Bot2, Tower.Bot3];
    for (const tid of towerOrder) {
        const t = GetTower(enemy, tid);
        if (t !== null && t.IsAlive()) {
            result = t;
            break;
        }
    }
    if (!result) {
        const raxOrder =
            lane === Lane.Top
                ? [Barracks.TopRanged, Barracks.TopMelee]
                : lane === Lane.Mid
                  ? [Barracks.MidRanged, Barracks.MidMelee]
                  : [Barracks.BotRanged, Barracks.BotMelee];
        for (const rid of raxOrder) {
            const r = GetBarracks(enemy, rid);
            if (r !== null && r.IsAlive()) {
                result = r;
                break;
            }
        }
    }
    if (!result) {
        const t4a = GetTower(enemy, Tower.Base1);
        const t4b = GetTower(enemy, Tower.Base2);
        if (t4a !== null && t4a.IsAlive()) result = t4a;
        else if (t4b !== null && t4b.IsAlive()) result = t4b;
    }
    if (!result) {
        const ancient = GetAncient(enemy);
        if (ancient !== null && ancient.IsAlive()) result = ancient;
    }

    _nextBuildingCache[lane] = { tick, result };
    return result;
}

/** Get the nearest alive friendly tower on a lane (T1→T2→T3 order) */
function _getNearestFriendlyTowerForPush(team: Team, lane: Lane): Unit | null {
    const towerIds = lane === Lane.Top ? [0, 3, 6] : lane === Lane.Mid ? [1, 4, 7] : [2, 5, 8];
    for (const tid of towerIds) {
        const t = GetTower(team, tid);
        if (t && t.IsAlive()) return t;
    }
    return null;
}

export function WhichLaneToPush(_bot: Unit, _lane: Lane): Lane {
    //   log("WhichLaneToPush for: ", bot.GetUnitName(), lane);

    // Update location cache
    const locationState = updateLocationStateCache();
    const gameState = updateGameStateCache();

    // Score smaller = better
    let topLaneScore = 0;
    let midLaneScore = 0;
    let botLaneScore = 0;

    const vTop = locationState.laneFronts[Lane.Top];
    const vMid = locationState.laneFronts[Lane.Mid];
    const vBot = locationState.laneFronts[Lane.Bot];

    // Furthest alive enemy building on each lane — drives commitment geometry.
    // After we take enemy T3, this switches to rax → T4 → ancient (all tightly
    // clustered), keeping the lane "close" to bots who just broke HG so they
    // stay committed instead of walking to another lane's outer tower.
    const topBuilding = GetNextEnemyBuildingOnLane(Lane.Top);
    const midBuilding = GetNextEnemyBuildingOnLane(Lane.Mid);
    const botBuilding = GetNextEnemyBuildingOnLane(Lane.Bot);

    // Prefer lanes closer to humans/cores; de-prioritize supports' solo pushes.
    // Dual-distance 60% lane-front + 40%
    // furthest-building. Side lanes get a 0.9 nudge to avoid mid-lane overuse.
    const teamMembers = GetUnitList(UnitType.AlliedHeroes);
    for (const member of teamMembers) {
        if (Fu.IsValidHero(member)) {
            let topDist = GetUnitToLocationDistance(member, vTop) * 0.9 * 0.6;
            let midDist = GetUnitToLocationDistance(member, vMid) * 0.6;
            let botDist = GetUnitToLocationDistance(member, vBot) * 0.9 * 0.6;

            if (topBuilding !== null) topDist += GetUnitToUnitDistance(member, topBuilding) * 0.9 * 0.4;
            if (midBuilding !== null) midDist += GetUnitToUnitDistance(member, midBuilding) * 0.4;
            if (botBuilding !== null) botDist += GetUnitToUnitDistance(member, botBuilding) * 0.9 * 0.4;

            if (Fu.IsCore(member) && member && !member.IsBot()) {
                topDist *= 0.2;
                midDist *= 0.2;
                botDist *= 0.2;
            } else if (!Fu.IsCore(member)) {
                topDist *= 1.5;
                midDist *= 1.5;
                botDist *= 1.5;
            }

            topLaneScore += topDist;
            midLaneScore += midDist;
            botLaneScore += botDist;
        }
    }

    // Enemy last seen / incoming TPs near their lane fronts → inflate that lane score
    let countTop = 0,
        countMid = 0,
        countBot = 0;

    for (const id of GetTeamPlayers(gameState.enemyTeam)) {
        if (IsHeroAlive(id)) {
            const info = GetHeroLastSeenInfo(id);
            if (info && info !== null) {
                const dInfo = info[0];
                if (dInfo && dInfo !== null) {
                    if (Fu.GetDistance(vTop, dInfo.location) <= 1600) countTop++;
                    else if (Fu.GetDistance(vMid, dInfo.location) <= 1600) countMid++;
                    else if (Fu.GetDistance(vBot, dInfo.location) <= 1600) countBot++;
                }
            }
        }
    }

    const hTeleports = GetIncomingTeleports();
    for (const tp of hTeleports) {
        if (tp && IsEnemyTP(tp.playerid)) {
            if (Fu.GetDistance(vTop, tp.location) <= 1600) countTop++;
            else if (Fu.GetDistance(vMid, tp.location) <= 1600) countMid++;
            else if (Fu.GetDistance(vBot, tp.location) <= 1600) countBot++;
        }
    }

    topLaneScore *= 0.05 * countTop + 1;
    midLaneScore *= 0.05 * countMid + 1;
    botLaneScore *= 0.05 * countBot + 1;

    // Prefer lanes with lower-tier outer buildings first
    const topTier = GetLaneBuildingTier(Lane.Top);
    const midTier = GetLaneBuildingTier(Lane.Mid);
    const botTier = GetLaneBuildingTier(Lane.Bot);

    topLaneScore *= RemapValClamped(topTier, 1, 3, 0.25, 1);
    midLaneScore *= RemapValClamped(midTier, 1, 3, 0.25, 1);
    botLaneScore *= RemapValClamped(botTier, 1, 3, 0.25, 1);

    // Prioritize lanes where OUR barracks are down but ENEMY barracks are still up
    // (enemy mega creeps push hard, need to push back and take their barracks too)
    const ourTopRaxDown = !Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Top);
    const ourMidRaxDown = !Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Mid);
    const ourBotRaxDown = !Fu.Utils.IsAnyBarracksOnLaneAlive(false, Lane.Bot);
    if (ourTopRaxDown && Fu.Utils.IsAnyBarracksOnLaneAlive(true, Lane.Top)) topLaneScore *= 0.15;
    if (ourMidRaxDown && Fu.Utils.IsAnyBarracksOnLaneAlive(true, Lane.Mid)) midLaneScore *= 0.15;
    if (ourBotRaxDown && Fu.Utils.IsAnyBarracksOnLaneAlive(true, Lane.Bot)) botLaneScore *= 0.15;

    // Pull toward lanes where allies already are
    topLaneScore = presence_adjust(topLaneScore, vTop);
    midLaneScore = presence_adjust(midLaneScore, vMid);
    botLaneScore = presence_adjust(botLaneScore, vBot);

    if (topLaneScore < midLaneScore && topLaneScore < botLaneScore) return Lane.Top;
    if (midLaneScore < topLaneScore && midLaneScore < botLaneScore) return Lane.Mid;
    if (botLaneScore < topLaneScore && botLaneScore < midLaneScore) return Lane.Bot;

    return Lane.Mid;
}

/* -----------------------------------------------------------------------------
 * Think loop
 * ---------------------------------------------------------------------------*/
// let fNextMovementTime = 0; // Removed — simplified movement fallback

export function PushThink(bot: Unit, lane: Lane): void {
    if (Fu.CanNotUseAction(bot)) return;

    // Deaggro tower, deny tower/hero
    if (Fu.TryDropTowerAggro(bot)) return;
    if (Fu.TryDenyTower(bot)) return;
    if (Fu.TryDenyAllyHero(bot)) return;

    // Near enemy fountain: fall back behind ally creeps
    const enemyFountainLoc = GetTeam() === Team.Radiant ? DireFountainTpPoint : RadiantFountainTpPoint;
    const botData = bot as any;
    if (GetLocationToLocationDistance(bot.GetLocation(), enemyFountainLoc) < 1500) {
        botData._fountainRetreatUntil = DotaTime() + 4.0;
        // Calculate retreat target
        const allyCreeps = bot.GetNearbyLaneCreeps(1600, false);
        if (allyCreeps && allyCreeps.length >= 1) {
            const creepLoc = allyCreeps[allyCreeps.length - 1].GetLocation();
            botData._fountainRetreatLoc = Fu.AdjustLocationWithOffsetTowardsFountain(creepLoc, 200);
        } else {
            botData._fountainRetreatLoc = GetLaneFrontLocation(GetTeam(), lane, -500);
        }
    }
    if (botData._fountainRetreatUntil && DotaTime() <= botData._fountainRetreatUntil) {
        // If taking hero damage, skip the override — let normal push/attack logic handle it
        if (bot.WasRecentlyDamagedByAnyHero(1.0)) {
            // don't override, fall through to push logic
        } else if (botData._fountainRetreatLoc && GetUnitToLocationDistance(bot, botData._fountainRetreatLoc) > 300) {
            // Not yet at safe spot — keep moving there
            bot.Action_MoveToLocation(botData._fountainRetreatLoc);
            return;
        } else {
            // Arrived at safe spot — clear timer, resume push
            botData._fountainRetreatUntil = 0;
        }
    }
    // if (Fu.Utils.IsBotThinkingMeaningfulAction(bot, Customize.ThinkLess, ThinkActionType.Push)) return;

    // Lane redirect: if bot is far from the desired push lane, move there first
    // Skip if bot was recently hit by an enemy hero (stay and fight / retreat instead)
    {
        const laneFront = GetLaneFrontLocation(GetTeam(), lane, 0);
        const distToLaneFront = GetUnitToLocationDistance(bot, laneFront);
        if (distToLaneFront > 2000 && !bot.WasRecentlyDamagedByAnyHero(3.0)) {
            bot.Action_MoveToLocation(add(laneFront, RandomVector(100)));
            return;
        }
    }

    // Update global caches
    autoCleanupCache();
    const gameState = getGlobalGameState();
    const locationState = getGlobalLocationState();

    // 2) Use cached bot state instead of fresh calculations
    const botState = updateBotStateCache(bot);
    const botLocation = botState.location;

    // Use global cached threat picture
    const alliesHere = getCachedAlliesNearLoc(botLocation, 1600);
    const enemiesHere = getCachedEnemiesNearLoc(botLocation, 1600);

    // 3) Build a lane-front offset depending on our HP and attack range
    const botAttackRange = botState.attackRange;
    const botHp = botState.hp;
    let fDeltaFromFront =
        Math.min(botHp, 0.7) * 1000 -
        700 + // healthier → stand a bit closer (match ref: 0.7*1000-700 = 0 at 70% HP, -700 at 0% HP)
        RemapValClamped(botAttackRange, 300, 700, 0, -600); // longer range → stand further back (match ref)
    // No aggressive clamping — let low-HP bots retreat far enough to escape tower range

    // 4) Use cached tower & creep context
    const nEnemyTowers = botState.nearbyTowers;
    const nAllyCreeps = botState.nearbyLaneCreeps;

    // 4) Outnumbered or backdoor: fall back well behind lane front (match ref: -1000 - longestRange)
    if (alliesHere.length < enemiesHere.length || IsAnyTargetBackdooredAt(bot, lane)) {
        let longestRange = 0;
        for (const enemyHero of enemiesHere) {
            if (Fu.IsValidHero(enemyHero) && !Fu.IsSuspiciousIllusion(enemyHero)) {
                const r = enemyHero.GetAttackRange();
                if (r > longestRange) longestRange = r;
            }
        }

        fDeltaFromFront = -1000 - longestRange;
    }

    // 5) Compute our approach waypoint for this lane
    // If lane front collapsed near fountain (creeps all dead), use nearest tower instead
    let targetLoc = GetLaneFrontLocation(gameState.team, lane, fDeltaFromFront);
    const teamFountain = gameState.team === Team.Radiant ? RadiantFountainTpPoint : DireFountainTpPoint;
    if (GetLocationToLocationDistance(targetLoc, teamFountain) < 3000) {
        // Use nearest alive tower on the lane, or the raw lane front with 0 offset
        const pushTower = _getNearestFriendlyTowerForPush(gameState.team, lane);
        if (pushTower) {
            targetLoc = pushTower.GetLocation();
        } else {
            targetLoc = GetLaneFrontLocation(gameState.team, lane, 0);
        }
    }

    // Only hold forward position if ally creeps are nearby to tank.
    // Otherwise fall back to lane front — standing alone ahead of creeps is dangerous.
    const botDistToFountain = GetLocationToLocationDistance(botLocation, teamFountain);
    const targetDistToFountain = GetLocationToLocationDistance(targetLoc, teamFountain);
    if (botDistToFountain > targetDistToFountain + 500) {
        if (nAllyCreeps.length >= 2 || alliesHere.length >= 3) {
            targetLoc = botLocation;
        }
        // else: fall back to targetLoc (lane front) — no creep cover
    }

    // Update bot cache with target location for distance calculations (only if needed)
    if (!botState.distanceToTargetLoc || Math.abs(botState.distanceToTargetLoc - GetUnitToLocationDistance(bot, targetLoc)) > 50) {
        updateBotStateCache(bot, targetLoc);
    }

    // 6) If the tower is targeting US or recently hit us → back off (match ref: attack target OR WasRecentlyDamagedByTower)
    // Move toward base by enough distance to exit tower attack range (not toward lane front which may be behind us)
    if (Fu.IsValidBuilding(nEnemyTowers[0]) && (nEnemyTowers[0].GetAttackTarget() === bot || bot.WasRecentlyDamagedByTower(nAllyCreeps.length <= 2 ? 4.0 : 2.0))) {
        const towerRange = nEnemyTowers[0].GetAttackRange() + 200; // tower range + safety margin
        let shouldRetreat = false;

        // Low HP: always retreat from tower aggro
        if (botHp < 0.6) {
            shouldRetreat = true;
        } else {
            // Higher HP: retreat only if projected damage is dangerous
            const nDamage = nEnemyTowers[0].GetAttackDamage() * nEnemyTowers[0].GetAttackSpeed() * 5.0 - bot.GetHealthRegen() * 5.0;
            if (bot.GetActualIncomingDamage(nDamage, DamageType.Physical) / bot.GetHealth() > 0.4) {
                shouldRetreat = true;
            }
        }

        if (shouldRetreat) {
            // Move away from tower toward our base, just outside tower attack range
            const retreatLoc = Fu.AdjustLocationWithOffsetTowardsFountain(nEnemyTowers[0].GetLocation(), towerRange);
            bot.Action_MoveToLocation(add(retreatLoc, RandomVector(80)));
            return;
        }
    }

    // 6a) Removed: no-creep tower retreat. Tower aggro retreat in section 6 handles
    // the dangerous case (tower targeting bot + damage too high). Otherwise bots
    // should attack the tower — not idle or retreat when they can tank it.

    // 6b) Glyph/backdoor active: fall back behind lane front
    // Uses GetLaneFrontLocation with negative delta — always returns a walkable point along the lane path,
    // avoids cliff edges on HG pushes, and bots naturally spread due to individual movement timing.
    {
        const glyphBuilding = nEnemyTowers[0] || GetNextEnemyBuildingOnLane(lane);
        if (glyphBuilding !== null && Fu.Utils.IsValidTower(glyphBuilding) && glyphBuilding.HasModifier("modifier_fountain_glyph")) {
            let nEnemyHeroLongestAttackRange = 0;
            const nearbyEnemies = Fu.GetEnemiesNearLoc(bot.GetLocation(), 1600);
            for (const enemyHero of nearbyEnemies) {
                if (Fu.IsValidHero(enemyHero) && !Fu.IsSuspiciousIllusion(enemyHero)) {
                    const range = enemyHero.GetAttackRange();
                    if (range > nEnemyHeroLongestAttackRange) nEnemyHeroLongestAttackRange = range;
                }
            }
            const retreatDelta = -1000 - nEnemyHeroLongestAttackRange;
            const retreatLoc = GetLaneFrontLocation(GetTeam(), lane, retreatDelta);
            // Attack non-glyphed enemy creeps on the way back
            const enemyCreeps = (bot.GetNearbyCreeps(botAttackRange + 200, true) || []) as Unit[];
            if (enemyCreeps.length > 0 && Fu.CanBeAttacked(enemyCreeps[0]) && !enemyCreeps[0].HasModifier("modifier_fountain_glyph")) {
                bot.Action_AttackUnit(enemyCreeps[0], true);
            } else {
                bot.Action_MoveToLocation(add(retreatLoc, RandomVector(200)));
            }
            return;
        }
    }

    // 6c) Creep aggro retreat: if lane creeps are targeting us, fall back
    {
        const nearbyEnemyCreeps = bot.GetNearbyLaneCreeps(1200, true);
        if (nearbyEnemyCreeps) {
            for (const creep of nearbyEnemyCreeps) {
                if (Fu.IsValid(creep) && creep.GetAttackTarget() === bot) {
                    bot.Action_MoveToLocation(targetLoc);
                    return;
                }
            }
        }
    }

    // Safety gate: only attack targets when we have creep wave support and are stronger
    const shouldPlayInWave = nAllyCreeps.length >= 1 || alliesHere.length > enemiesHere.length;

    // Enemy base danger: if near enemy ancient/fountain taking tower damage with no creep cover, retreat
    // This prevents bots from chasing enemies deep into the base and getting stuck/killed by T4s
    const enemyFountainLoc2 = gameState.team === Team.Radiant ? DireFountainTpPoint : RadiantFountainTpPoint;
    const distToEnemyFountain = GetLocationToLocationDistance(botLocation, enemyFountainLoc2);
    if (distToEnemyFountain < 3000 || botState.distanceToAncient < 1500) {
        const isBeingTowerShot = bot.WasRecentlyDamagedByTower(3.0);
        const hasNoCover = nAllyCreeps.length < 2 && alliesHere.length < 3;
        if (isBeingTowerShot && hasNoCover) {
            // Fall back to lane front, away from danger
            const retreatLoc = GetLaneFrontLocation(GetTeam(), lane, -500);
            bot.Action_MoveToLocation(add(retreatLoc, RandomVector(100)));
            return;
        }
        // Don't chase enemy heroes near their fountain — only hit buildings or retreat
        if (distToEnemyFountain < 2000 && !bot.WasRecentlyDamagedByAnyHero(1.0)) {
            // Only allow attacking ancient or buildings, skip hero chasing
            hEnemyAncient = gameState.enemyAncient;
            if (hEnemyAncient && Fu.CanBeAttacked(hEnemyAncient) && !HasBackdoorProtect(hEnemyAncient) && botState.distanceToAncient < 1000) {
                bot.Action_AttackUnit(hEnemyAncient, true);
                return;
            }
            const retreatLoc = GetLaneFrontLocation(GetTeam(), lane, -500);
            bot.Action_MoveToLocation(add(retreatLoc, RandomVector(100)));
            return;
        }
    }

    // 7) Ancient-endgame logic: if we're in range and it's hittable, do it
    hEnemyAncient = gameState.enemyAncient;
    const alliesNearAncient = hEnemyAncient && Fu.GetAlliesNearLoc(hEnemyAncient.GetLocation(), 1600);
    if (
        hEnemyAncient &&
        botState.distanceToAncient < 1000 &&
        Fu.CanBeAttacked(hEnemyAncient) &&
        !HasBackdoorProtect(hEnemyAncient) &&
        (GetAllyHeroesAttackingUnit(hEnemyAncient).length >= 3 ||
            GetAllyCreepsAttackingUnit(hEnemyAncient).length >= 4 ||
            hEnemyAncient.GetHealthRegen() < 20 ||
            (alliesNearAncient?.length ?? 0) >= 4)
    ) {
        bot.Action_AttackUnit(hEnemyAncient, true);
        return;
    }

    // 8) Find attackable creeps/heroes/buildings
    // When not safe to play in wave, move to target position but don't idle
    if (!shouldPlayInWave) {
        const distToTarget = GetUnitToLocationDistance(bot, targetLoc);
        if (distToTarget > 300) {
            bot.Action_MoveToLocation(targetLoc);
            return;
        }
        // At target but no creep wave: attack-move toward lane front instead of idling
        const laneFront = GetLaneFrontLocation(GetTeam(), lane, -300);
        bot.Action_AttackMove(laneFront);
        return;
    }

    // 8a) Find attackable creeps to thin out while we approach (prefer those not under tower)
    let nRange = Math.min(700 + botAttackRange, 1600);
    if (hEnemyAncient && botState.distanceToAncient < 2600) {
        // bump the search radius when we're near high ground / base
        nRange = 1600;
    }

    // Use cached creeps with numeric key
    let nCreeps = botState.nearbyCreeps;
    const creepCacheKey = CK.PUSH_SPECIAL_CREEPS + bot.GetPlayerID();
    const cachedCreeps = Fu.Utils.GetCachedVars(creepCacheKey, 0.2);
    if (cachedCreeps) {
        nCreeps = cachedCreeps;
    } else {
        nCreeps = GetSpecialUnitsNearby(bot, nCreeps, nRange);
        Fu.Utils.SetCachedVars(creepCacheKey, nCreeps);
    }

    const vTeamFountain = locationState.teamFountain;
    const bTowerNearby = Fu.IsValidBuilding(nEnemyTowers[0]); // only consider creeps "in front" of tower
    const towerDistanceToFountain = bTowerNearby ? GetUnitToLocationDistance(nEnemyTowers[0], vTeamFountain) : 0;

    // Attack enemy heroes first if in range and we're stronger
    {
        const nearbyEnemies = bot.GetNearbyHeroes(1200, true, BotMode.None) || [];
        if (nearbyEnemies.length > 0 && alliesHere.length >= nearbyEnemies.length) {
            let weakestEnemy: Unit | null = null;
            let weakestHP = 999999;
            for (const enemy of nearbyEnemies) {
                if (Fu.IsValidHero(enemy) && Fu.CanBeAttacked(enemy) && !Fu.IsSuspiciousIllusion(enemy)) {
                    const hp = enemy.GetHealth();
                    if (hp < weakestHP) {
                        weakestHP = hp;
                        weakestEnemy = enemy;
                    }
                }
            }
            if (weakestEnemy) {
                bot.Action_AttackUnit(weakestEnemy, true);
                return;
            }
        }
    }

    for (const creep of nCreeps) {
        if (!Fu.IsValid(creep) || !Fu.CanBeAttacked(creep)) continue;
        if (Fu.IsTormentor(creep) || Fu.IsRoshan(creep)) continue;

        // Skip creeps that are deep past the tower — but allow creeps near/under tower
        if (bTowerNearby && GetUnitToLocationDistance(creep, vTeamFountain) >= towerDistanceToFountain + 500) continue;

        bot.Action_AttackUnit(creep, true);
        return;
    }

    // 9) High-ground building priorities: barracks → towers → fillers
    // If in range, attack. If not in range, approach.
    // Tower danger is already handled by section 6 (retreat if tower damage too high).
    const hgTarget = SelectOrStickHGTarget(bot, lane, targetLoc);
    if (hgTarget && Fu.IsValidBuilding(hgTarget) && Fu.CanBeAttacked(hgTarget) && !HasBackdoorProtect(hgTarget)) {
        if (Fu.IsInRange(bot, hgTarget, botAttackRange + 150)) {
            bot.Action_AttackUnit(hgTarget, true);
        } else {
            const approachLoc = Fu.AdjustLocationWithOffsetTowardsFountain(hgTarget.GetLocation(), botAttackRange);
            bot.Action_MoveToLocation(add(approachLoc, RandomVector(50)));
        }
        return;
    }

    // 10) Next building on lane: approach and attack
    const nextBuilding = GetNextEnemyBuildingOnLane(lane);
    if (nextBuilding !== null && Fu.IsValidBuilding(nextBuilding) && Fu.CanBeAttacked(nextBuilding) && !HasBackdoorProtect(nextBuilding)) {
        const distToBuilding = GetUnitToUnitDistance(bot, nextBuilding);
        if (distToBuilding <= botAttackRange + 150) {
            bot.Action_AttackUnit(nextBuilding, true);
            return;
        } else {
            const approachLoc = Fu.AdjustLocationWithOffsetTowardsFountain(nextBuilding.GetLocation(), botAttackRange);
            bot.Action_MoveToLocation(approachLoc);
            return;
        }
    }

    // No building in range or waiting for creeps: try attacking enemy heroes
    // But don't chase heroes deep into enemy base — that's how bots die to T4s
    if (distToEnemyFountain > 2500) {
        const nearbyEnemyHeroes = bot.GetNearbyHeroes(botAttackRange + 300, true, BotMode.None) || [];
        for (const enemy of nearbyEnemyHeroes) {
            if (Fu.IsValidHero(enemy) && Fu.CanBeAttacked(enemy) && !Fu.IsSuspiciousIllusion(enemy)) {
                bot.Action_AttackUnit(enemy, true);
                return;
            }
        }
    }

    // Nothing to attack: walk toward lane front (not current position)
    // If deep in enemy base, always retreat to lane front
    if (distToEnemyFountain < 2500 && nAllyCreeps.length < 2) {
        const retreatLoc = GetLaneFrontLocation(GetTeam(), lane, -500);
        bot.Action_MoveToLocation(add(retreatLoc, RandomVector(100)));
    } else {
        const distToTarget = GetUnitToLocationDistance(bot, targetLoc);
        if (distToTarget > 300) {
            bot.Action_MoveToLocation(targetLoc);
        } else {
            // Already at target: attack-move toward enemy side of the lane
            const laneFront = GetLaneFrontLocation(gameState.team, lane, 200);
            bot.Action_AttackMove(laneFront);
        }
    }
}

// Ensure no idle: if PushThink somehow exits without action, this is called externally
// (not needed — all paths above issue actions, but kept as documentation)

/* -----------------------------------------------------------------------------
 * High-ground cross-lane clearing
 * ---------------------------------------------------------------------------*/
export function TryClearingOtherLaneHighGround(_bot: Unit, vLocation: Vector): Unit | null {
    //   log("TryClearingOtherLaneHighGround for: ", bot.GetUnitName(), vLocation);

    const gameState = updateGameStateCache();
    const unitState = updateUnitStateCache();
    const unitList = unitState.enemyBuildings;

    function IsValid(building: Unit | null): building is Unit {
        return Fu.IsValidBuilding(building) && Fu.CanBeAttacked(building!) && !HasBackdoorProtect(building!);
    }

    // Prefer closest barracks first
    let hBarrackTarget: Unit | null = null;
    let best = Number.POSITIVE_INFINITY;
    for (const barrack of unitList) {
        if (
            IsValid(barrack) &&
            (barrack === GetBarracks(gameState.enemyTeam, Barracks.TopMelee) ||
                barrack === GetBarracks(gameState.enemyTeam, Barracks.TopRanged) ||
                barrack === GetBarracks(gameState.enemyTeam, Barracks.MidMelee) ||
                barrack === GetBarracks(gameState.enemyTeam, Barracks.MidRanged) ||
                barrack === GetBarracks(gameState.enemyTeam, Barracks.BotMelee) ||
                barrack === GetBarracks(gameState.enemyTeam, Barracks.BotRanged))
        ) {
            const d = GetUnitToLocationDistance(barrack, vLocation);
            if (d < best) {
                hBarrackTarget = barrack;
                best = d;
            }
        }
    }
    if (hBarrackTarget) return hBarrackTarget;

    // Then closest T3 tower
    let hTowerTarget: Unit | null = null;
    best = Number.POSITIVE_INFINITY;
    for (const tower of unitList) {
        if (
            IsValid(tower) &&
            (tower === GetTower(gameState.enemyTeam, Tower.Top3) ||
                tower === GetTower(gameState.enemyTeam, Tower.Mid3) ||
                tower === GetTower(gameState.enemyTeam, Tower.Bot3))
        ) {
            const d = GetUnitToLocationDistance(tower, vLocation);
            if (d < best) {
                hTowerTarget = tower;
                best = d;
            }
        }
    }
    if (hTowerTarget) return hTowerTarget;

    return null;
}

/* -----------------------------------------------------------------------------
 * Utility helpers (validation, backdoor checks, etc.)
 * ---------------------------------------------------------------------------*/

export function CanBeAttacked(building: Unit | null): boolean {
    return !!building && building.CanBeSeen() && !building.IsInvulnerable();
}

export function IsEnemyTP(nID: number): boolean {
    const gameState = updateGameStateCache();
    for (const id of GetTeamPlayers(gameState.enemyTeam)) {
        if (id === nID) return true;
    }
    return false;
}

/** Estimate if staying in a tower's zone is too dangerous over fDuration seconds */
export function IsInDangerWithinTower(hUnit: Unit, fThreshold: number, fDuration: number): boolean {
    const unitState = updateUnitStateCache();
    let totalDamage = 0;
    for (const enemy of unitState.enemyHeroes) {
        if (Fu.IsValid(enemy) && Fu.IsInRange(hUnit, enemy, 1600) && (enemy.GetAttackTarget() === hUnit || Fu.IsChasingTarget(enemy, hUnit))) {
            totalDamage += hUnit.GetActualIncomingDamage(enemy.GetAttackDamage() * enemy.GetAttackSpeed() * fDuration, DamageType.Physical);
        }
    }
    return (totalDamage / hUnit.GetHealth()) * 1.2 > fThreshold;
}

/** Include micro-summons & dominated units into "nearby creeps" for push thinning */
export function GetSpecialUnitsNearby(bot: Unit, hUnitList: Unit[], nRadius: number): Unit[] {
    const unitState = updateUnitStateCache();
    const hCreepList: Unit[] = [...hUnitList];

    for (const unit of unitState.enemyHeroes) {
        if (IsValidUnit(unit) && Fu.IsInRange(bot, unit, nRadius)) {
            const s = unit.GetUnitName();
            if (
                s.includes("invoker_forge_spirit") ||
                s.includes("lycan_wolf") ||
                s.includes("eidolon") ||
                s.includes("beastmaster_boar") ||
                s.includes("beastmaster_greater_boar") ||
                s.includes("furion_treant") ||
                s.includes("broodmother_spiderling") ||
                s.includes("skeleton_warrior") ||
                s.includes("warlock_golem") ||
                unit.HasModifier("modifier_dominated") ||
                unit.HasModifier("modifier_chen_holy_persuasion")
            ) {
                hCreepList.push(unit);
            }
        }
    }

    return hCreepList;
}

export function IsHealthyInsideFountain(hUnit: Unit): boolean {
    return hUnit.HasModifier("modifier_fountain_aura_buff") && Fu.GetHP(hUnit) > 0.9 && Fu.GetMP(hUnit) > 0.85;
}

export function GetAllyHeroesAttackingUnit(hUnit: Unit): Unit[] {
    const unitState = updateUnitStateCache();
    const out: Unit[] = [];
    for (const ally of unitState.alliedHeroes) {
        if (Fu.IsValidHero(ally) && !Fu.IsSuspiciousIllusion(ally) && !Fu.IsMeepoClone(ally) && ally.GetAttackTarget() === hUnit) {
            out.push(ally);
        }
    }
    return out;
}

export function GetAllyCreepsAttackingUnit(hUnit: Unit): Unit[] {
    const unitState = updateUnitStateCache();
    const out: Unit[] = [];
    for (const creep of unitState.alliedCreeps) {
        if (Fu.IsValid(creep) && creep.GetAttackTarget() === hUnit) {
            out.push(creep);
        }
    }
    return out;
}

/** Returns 1..4 for the highest structure on that lane that is still alive on the enemy team */
export function GetLaneBuildingTier(nLane: Lane): number {
    const gameState = updateGameStateCache();
    const enemyTeam = gameState.enemyTeam;

    if (nLane === Lane.Top) {
        if (GetTower(enemyTeam, Tower.Top1) !== null) return 1;
        else if (GetTower(enemyTeam, Tower.Top2) !== null) return 2;
        else if (GetTower(enemyTeam, Tower.Top3) !== null || GetBarracks(enemyTeam, Barracks.TopMelee) !== null || GetBarracks(enemyTeam, Barracks.TopRanged) !== null)
            return 3;
        else return 4;
    } else if (nLane === Lane.Mid) {
        if (GetTower(enemyTeam, Tower.Mid1) !== null) return 1;
        else if (GetTower(enemyTeam, Tower.Mid2) !== null) return 2;
        else if (GetTower(enemyTeam, Tower.Mid3) !== null || GetBarracks(enemyTeam, Barracks.MidMelee) !== null || GetBarracks(enemyTeam, Barracks.MidRanged) !== null)
            return 3;
        else return 4;
    } else if (nLane === Lane.Bot) {
        if (GetTower(enemyTeam, Tower.Bot1) !== null) return 1;
        else if (GetTower(enemyTeam, Tower.Bot2) !== null) return 2;
        else if (GetTower(enemyTeam, Tower.Bot3) !== null || GetBarracks(enemyTeam, Barracks.BotMelee) !== null || GetBarracks(enemyTeam, Barracks.BotRanged) !== null)
            return 3;
        else return 4;
    }
    return 1;
}

// Unused — available for future use
export function ShouldWaitForImportantItemsSpells(_vLocation: Vector): boolean {
    return false;
}

export function HasBackdoorProtect(target: Unit): boolean {
    return (
        target.HasModifier("modifier_fountain_glyph") ||
        target.HasModifier("modifier_backdoor_protection") ||
        target.HasModifier("modifier_backdoor_protection_in_base") ||
        target.HasModifier("modifier_backdoor_protection_active")
    );
}

/* -----------------------------------------------------------------------------
 * New targeted helpers to reduce thrash/jitter
 * ---------------------------------------------------------------------------*/

/**
 * Returns true if the *nearest* intended target around the enemy lane-front
 * is currently backdoored/glyphed.
 */
export function IsAnyTargetBackdooredAt(_bot: Unit, lane: Lane): boolean {
    const locationState = updateLocationStateCache();
    const unitState = updateUnitStateCache();

    const lf = locationState.laneFronts[lane];
    let nearest: Unit | null = null;
    let best = Number.POSITIVE_INFINITY;
    for (const b of unitState.enemyBuildings) {
        if (Fu.IsValidBuilding(b)) {
            const d = GetUnitToLocationDistance(b, lf);
            if (d < best) {
                nearest = b;
                best = d;
            }
        }
    }
    return !!(nearest && HasBackdoorProtect(nearest));
}

/**
 * Picks best high-ground objective with strict priority:
 *   1) Barracks: melee > ranged (closest of each class)
 *   2) Tier-3 towers (closest)
 *   3) Fillers/others (closest)
 * Radius is the max distance from the bot; tie-breaker favors closer to targetLoc.
 */
export function FindBestHGTarget(bot: Unit, radius: number, targetLoc?: Vector | null): Unit | null {
    const gameState = updateGameStateCache();
    const unitState = updateUnitStateCache();

    const isBarracks = (u: Unit) => u.GetUnitName().includes("rax");
    const isMeleeBarracks = (u: Unit) => u.GetUnitName().includes("melee");
    const isRangedBarracks = (u: Unit) => u.GetUnitName().includes("ranged");
    const isT3Tower = (u: Unit) =>
        u === GetTower(gameState.enemyTeam, Tower.Top3) || u === GetTower(gameState.enemyTeam, Tower.Mid3) || u === GetTower(gameState.enemyTeam, Tower.Bot3);
    const isT4Tower = (u: Unit) => u === GetTower(gameState.enemyTeam, Tower.Base1) || u === GetTower(gameState.enemyTeam, Tower.Base2);

    let bestMelee: Unit | null = null,
        bestMeleeD = Number.POSITIVE_INFINITY;
    let bestRanged: Unit | null = null,
        bestRangedD = Number.POSITIVE_INFINITY;
    let bestT3: Unit | null = null,
        bestT3D = Number.POSITIVE_INFINITY;
    let bestT4: Unit | null = null,
        bestT4D = Number.POSITIVE_INFINITY;
    let bestOther: Unit | null = null,
        bestOtherD = Number.POSITIVE_INFINITY;

    for (const b of unitState.enemyBuildings) {
        if (Fu.IsValidBuilding(b) && Fu.CanBeAttacked(b) && !HasBackdoorProtect(b)) {
            const dBot = GetUnitToUnitDistance(bot, b);
            if (dBot <= radius) {
                // prefer closer to our approach point when bot-distance is similar
                const dLoc = targetLoc ? GetUnitToLocationDistance(b, targetLoc) : 0;

                if (isBarracks(b)) {
                    if (isMeleeBarracks(b)) {
                        if (dBot < bestMeleeD || (dBot === bestMeleeD && dLoc < (bestMelee ? GetUnitToLocationDistance(bestMelee, targetLoc!) : dLoc))) {
                            bestMelee = b;
                            bestMeleeD = dBot;
                        }
                    } else if (isRangedBarracks(b)) {
                        if (dBot < bestRangedD || (dBot === bestRangedD && dLoc < (bestRanged ? GetUnitToLocationDistance(bestRanged, targetLoc!) : dLoc))) {
                            bestRanged = b;
                            bestRangedD = dBot;
                        }
                    }
                } else if (isT3Tower(b)) {
                    if (dBot < bestT3D || (dBot === bestT3D && dLoc < (bestT3 ? GetUnitToLocationDistance(bestT3, targetLoc!) : dLoc))) {
                        bestT3 = b;
                        bestT3D = dBot;
                    }
                } else if (isT4Tower(b)) {
                    if (dBot < bestT4D || (dBot === bestT4D && dLoc < (bestT4 ? GetUnitToLocationDistance(bestT4, targetLoc!) : dLoc))) {
                        bestT4 = b;
                        bestT4D = dBot;
                    }
                } else {
                    if (dBot < bestOtherD || (dBot === bestOtherD && dLoc < (bestOther ? GetUnitToLocationDistance(bestOther, targetLoc!) : dLoc))) {
                        bestOther = b;
                        bestOtherD = dBot;
                    }
                }
            }
        }
    }

    return bestMelee || bestRanged || bestT3 || bestOther;
}
