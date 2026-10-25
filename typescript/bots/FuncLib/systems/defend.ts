// let TS accept these Lua globals
declare function GetScriptDirectory(): string;

import * as Fu from "bots/FuncLib/func_utils";
// Avoid static resolution; mirror Lua's pcall(require(...))
let [okLoc, Localization] = pcall(require, GetScriptDirectory() + "/FuncLib/systems/localization");
if (!okLoc) Localization = { Get: (_: string) => "Defend here!" };

// eslint-disable-next-line @typescript-eslint/no-var-requires
import Customize = require("bots/FuncLib/systems/custom_loader");

import { Barracks, BotMode, BotModeDesire, Lane, Team, Tower, Unit, UnitType, Vector } from "bots/ts_libs/dota";
import { add } from "bots/ts_libs/utils/native-operators";
import { GetLocationToLocationDistance, ConsiderTPToTarget, RadiantFountainTpPoint, DireFountainTpPoint } from "./utils";
import * as CK from "bots/FuncLib/systems/cache_keys";

Customize.ThinkLess = Customize.Enable ? Customize.ThinkLess : 1;

// == Tunables ==
const PING_DELTA = 5.0;
const SEARCH_RANGE_DEFAULT = 1600;
// const CLOSE_RANGE = 1200;
const MAX_DESIRE_CAP = 0.6; // VERYHIGH —  beats Valve's farm (~0.55)

// Base threat (Ancient defense)
const BASE_THREAT_RADIUS = 2600;
// const BASE_LEASH_OUTBOUND = 1200; // Removed — no longer leash to ancient
const BASE_THREAT_HOLD = 4.0;

// Perf: cache intervals (seconds)
const CACHE_ENEMY_AROUND_LOC_HZ = 0.35; // cache for weighted enemy scans around a location
const CACHE_LASTSEEN_WINDOW = 5.0; // seconds for hero last-seen proximity checks

// == State ==
const nTeam = GetTeam();
// Per-bot state stored on bot object to avoid cross-bot data races.
// Access via (bot as any)._defend.X — initialized in GetDefendDesireHelper.
interface DefendBotState {
    defendLoc: Vector;
    weAreStronger: boolean;
    nInRangeAlly: Unit[];
    nInRangeEnemy: Unit[];
    distanceToLane: Record<Lane, number>;
}
function getDefendState(bot: Unit): DefendBotState {
    if (!(bot as any)._defend) {
        (bot as any)._defend = {
            defendLoc: GetLaneFrontLocation(nTeam, Lane.Mid, 0),
            weAreStronger: false,
            nInRangeAlly: [],
            nInRangeEnemy: [],
            distanceToLane: { [Lane.Top]: 0, [Lane.Mid]: 0, [Lane.Bot]: 0 },
        };
    }
    return (bot as any)._defend;
}
let _threatLaneSticky: { lane: Lane; until: number } = { lane: Lane.Mid, until: -1 };

// sticky base-threat window
let baseThreatUntil = -1;

// Travel Boots defender coordination
let fTraveBootsDefendTime = 0;

// == Perf caches ==
type EnemyAroundLocCache = { t: number; count: number };
const _cacheEnemyAroundLoc: Record<string, EnemyAroundLocCache> = {};

/** Performance cache - avoid redundant calculations between GetDefendDesire (300ms) and Think (every frame) */
type CachedDefendGameState = {
    lastUpdate: number;
    currentTime: number;
    gameMode: number;
    team: Team;
    enemyTeam: Team;
    ourAncient: Unit | null;
    enemyAncient: Unit | null;
    aliveAllyCount: number;
    aliveEnemyCount: number;
    isLaningPhase: boolean;
    isEarlyGame: boolean;
    isMidGame: boolean;
    isLateGame: boolean;
    teamFountain: Vector;
    teamFountainTpPoint: Vector;
    // Per-tick cached expensive computations
    enemiesOnHG: number;
    enemiesAtAncient: number;
    ancientHP: number;
    defendersAtAncient: number;
};

type CachedDefendLocationState = {
    lastUpdate: number;
    laneFronts: Record<Lane, Vector>;
    enemyLaneFronts: Record<Lane, Vector>;
    highGroundEdgeWaitPoints: Record<Lane, Vector>;
};

type CachedDefendUnitState = {
    lastUpdate: number;
    enemyBuildings: Unit[];
    alliedHeroes: Unit[];
    enemyHeroes: Unit[];
    alliedCreeps: Unit[];
    enemyCreeps: Unit[];
    teamMembers: Unit[];
};

const DEFEND_CACHE_TTL = 0.5; // 500ms cache TTL - increased for better performance
// Frame rate limiter removed — caused stale action replay and shared state bugs
let defendGameStateCache: CachedDefendGameState | null = null;
let defendLocationStateCache: CachedDefendLocationState | null = null;
let defendUnitStateCache: CachedDefendUnitState | null = null;

/** Update defend game state cache if needed */
function updateDefendGameStateCache(): CachedDefendGameState {
    const now = DotaTime();
    if (defendGameStateCache && now - defendGameStateCache.lastUpdate < DEFEND_CACHE_TTL) {
        return defendGameStateCache;
    }

    const team = GetTeam();
    const enemyTeam = GetOpposingTeam();
    const currentTime = DotaTime();
    const gameMode = GetGameMode();

    // Adjust time for turbo mode
    const adjustedTime = gameMode === 23 ? currentTime * 1.65 : currentTime;

    const ancient = GetAncient(team);
    const ancientLoc = ancient !== null ? ancient.GetLocation() : null;

    // Compute expensive values once per cache refresh
    let defendersCount = 0;
    if (ancientLoc !== null) {
        const defs = Fu.GetAlliesNearLoc(ancientLoc, 2500);
        for (const d of defs) {
            if (Fu.IsValidHero(d)) defendersCount++;
        }
    }

    defendGameStateCache = {
        lastUpdate: now,
        currentTime: adjustedTime,
        gameMode,
        team,
        enemyTeam,
        ourAncient: ancient,
        enemyAncient: GetAncient(enemyTeam),
        aliveAllyCount: Fu.GetNumOfAliveHeroes(false),
        aliveEnemyCount: Fu.GetNumOfAliveHeroes(true),
        isLaningPhase: Fu.IsInLaningPhase(),
        isEarlyGame: Fu.IsEarlyGame(),
        isMidGame: Fu.IsMidGame(),
        isLateGame: Fu.IsLateGame(),
        teamFountain: Fu.GetTeamFountain(),
        teamFountainTpPoint: Fu.Utils.GetTeamFountainTpPoint(),
        enemiesOnHG: Fu.Utils.CountEnemyHeroesOnHighGround(team),
        enemiesAtAncient: ancientLoc !== null ? Fu.Utils.CountEnemyHeroesNear(ancientLoc, 2200) : 0,
        ancientHP: ancient !== null && ancient.IsAlive() ? Fu.GetHP(ancient) : 1,
        defendersAtAncient: defendersCount,
    };

    return defendGameStateCache;
}

/** Update defend location state cache if needed */
function updateDefendLocationStateCache(): CachedDefendLocationState {
    const now = DotaTime();
    if (defendLocationStateCache && now - defendLocationStateCache.lastUpdate < DEFEND_CACHE_TTL) {
        return defendLocationStateCache;
    }

    const team = GetTeam();
    const enemyTeam = GetOpposingTeam();

    defendLocationStateCache = {
        lastUpdate: now,
        laneFronts: {
            [Lane.Top]: GetLaneFrontLocation(team, Lane.Top, 0),
            [Lane.Mid]: GetLaneFrontLocation(team, Lane.Mid, 0),
            [Lane.Bot]: GetLaneFrontLocation(team, Lane.Bot, 0),
        },
        enemyLaneFronts: {
            [Lane.Top]: GetLaneFrontLocation(enemyTeam, Lane.Top, 0),
            [Lane.Mid]: GetLaneFrontLocation(enemyTeam, Lane.Mid, 0),
            [Lane.Bot]: GetLaneFrontLocation(enemyTeam, Lane.Bot, 0),
        },
        highGroundEdgeWaitPoints: {
            [Lane.Top]: GetHighGroundEdgeWaitPoint(team, Lane.Top),
            [Lane.Mid]: GetHighGroundEdgeWaitPoint(team, Lane.Mid),
            [Lane.Bot]: GetHighGroundEdgeWaitPoint(team, Lane.Bot),
        },
    };

    return defendLocationStateCache;
}

/** Update defend unit state cache if needed */
function updateDefendUnitStateCache(): CachedDefendUnitState {
    const now = DotaTime();
    if (defendUnitStateCache && now - defendUnitStateCache.lastUpdate < DEFEND_CACHE_TTL) {
        return defendUnitStateCache;
    }

    // Smart Bots: GetTeamMember() only returns the bot itself in per-bot sandboxes; use the unit list.
    const teamMembers: Unit[] = [];
    for (const member of GetUnitList(UnitType.AlliedHeroes)) {
        if (member !== null && !member.IsIllusion()) {
            teamMembers.push(member);
        }
    }

    defendUnitStateCache = {
        lastUpdate: now,
        enemyBuildings: GetUnitList(UnitType.EnemyBuildings),
        alliedHeroes: GetUnitList(UnitType.AlliedHeroes),
        enemyHeroes: GetUnitList(UnitType.Enemies).filter(u => Fu.IsValidHero(u)),
        alliedCreeps: GetUnitList(UnitType.AlliedCreeps),
        enemyCreeps: GetUnitList(UnitType.Enemies).filter(u => u.IsCreep() || u.IsAncientCreep()),
        teamMembers,
    };

    return defendUnitStateCache;
}

// small utils (keep GC low)
function _q(v: Vector | null | undefined): string {
    return v ? `${math.floor(v.x / 200) * 200}:${math.floor(v.y / 200) * 200}` : "0:0";
}
function _keyLoc(v: Vector, r?: number) {
    return `${_q(v)}|${tostring(math.floor(r || 0))}`;
}

function _recentHeroCountNear(loc: Vector, r: number, window = CACHE_LASTSEEN_WINDOW): number {
    const gameState = updateDefendGameStateCache();
    let cnt = 0;
    for (const id of GetTeamPlayers(gameState.enemyTeam)) {
        if (!IsHeroAlive(id)) continue;
        const info = GetHeroLastSeenInfo(id);
        // NOTE: TS index 0 → Lua index 1
        if (info && info[0] && info[0].time_since_seen <= window && GetLocationToLocationDistance(info[0].location, loc) <= r) {
            cnt += 1;
        }
    }
    return cnt;
}

// == Small helpers ==
function IsValidBuildingTarget(unit: Unit | null): unit is Unit {
    return unit !== null && unit.IsAlive() && unit.IsBuilding();
}
function IsBaseThreatActive(): boolean {
    return DotaTime() < (baseThreatUntil || -1);
}
/** check if bot is actively defending a different lane (suppress T1/T2 conflicts) */
function IsDefendingOtherLane(bot: Unit, lane: Lane): boolean {
    const mode = bot.GetActiveMode();
    if (lane === Lane.Top) return mode === BotMode.DefendTowerMid || mode === BotMode.DefendTowerBot;
    if (lane === Lane.Mid) return mode === BotMode.DefendTowerTop || mode === BotMode.DefendTowerBot;
    if (lane === Lane.Bot) return mode === BotMode.DefendTowerTop || mode === BotMode.DefendTowerMid;
    return false;
}

// If any enemy units (weighted) are around location; cached
function WeightedEnemiesAroundLocation(vLoc: Vector, nRadius: number): number {
    const now = DotaTime();
    const key = _keyLoc(vLoc, nRadius);
    const c = _cacheEnemyAroundLoc[key];
    if (c && now - c.t <= CACHE_ENEMY_AROUND_LOC_HZ) return c.count;

    const unitState = updateDefendUnitStateCache();
    let count = 0;
    for (const unit of unitState.enemyHeroes) {
        if (Fu.IsValid(unit) && GetUnitToLocationDistance(unit, vLoc) <= nRadius) {
            const name = unit.GetUnitName();
            if (Fu.IsValidHero(unit) && !Fu.IsSuspiciousIllusion(unit)) {
                count += Fu.IsCore(unit) ? 1 : 0.5;
            } else if (string.find(name, "upgraded_mega") !== null) {
                count += 0.6;
            } else if (string.find(name, "upgraded") !== null) {
                count += 0.4;
            } else if (string.find(name, "siege") !== null && string.find(name, "upgraded") === null) {
                count += 0.5;
            } else if (string.find(name, "warlock_golem") !== null || string.find(name, "lone_druid_bear") !== null) {
                count += 1;
            } else if (
                unit.IsCreep() ||
                unit.IsAncientCreep() ||
                unit.IsDominated() ||
                unit.HasModifier("modifier_chen_holy_persuasion") ||
                unit.HasModifier("modifier_dominated")
            ) {
                count += 0.2;
            }
        }
    }

    count = math.floor(count);
    _cacheEnemyAroundLoc[key] = { t: now, count };
    return count;
}

function GetThreatenedLane(): Lane {
    const lanes: Lane[] = [Lane.Top, Lane.Mid, Lane.Bot];
    let bestLane = lanes[0];
    let bestScore = -1;

    for (const ln of lanes) {
        const [bld, _urgent, tier] = GetFurthestBuildingOnLane(ln);
        // for tier >=3, use lane HG edge; for t1/2, use the building
        const anchor = IsValidBuildingTarget(bld) && tier < 3 ? bld.GetLocation() : GetHighGroundEdgeWaitPoint(nTeam, ln);

        // Hero-first scoring
        const enemyHeroCnt = _recentHeroCountNear(anchor, 1800);
        let score = enemyHeroCnt * 10; // heroes dominate the score

        if (enemyHeroCnt === 0) {
            // don’t let creeps fully tie heroes; smaller radius + cap
            const creepEq = math.min(WeightedEnemiesAroundLocation(anchor, 1200) * 0.4, 0.9);
            score += creepEq;
        }

        if (score > bestScore) {
            bestScore = score;
            bestLane = ln;
        }
    }

    // Stickiness to avoid oscillation, but override immediately if the new
    // lane has a much higher threat score (e.g. enemies switched to mid barracks).
    if (DotaTime() <= _threatLaneSticky.until && _threatLaneSticky.lane !== bestLane) {
        // If new lane has heroes (score >= 10) and old lane has none, override immediately
        if (bestScore >= 10) {
            _threatLaneSticky = { lane: bestLane, until: DotaTime() + 3.0 };
            return bestLane;
        }
        // Otherwise respect stickiness
        return _threatLaneSticky.lane;
    }
    _threatLaneSticky = { lane: bestLane, until: DotaTime() + 3.0 };
    return bestLane;
}

// Closest ally role among a list to given location
function GetClosestAllyPos(tPosList: number[], vLocation: Vector): number {
    let bestPos: number | null = null;
    let bestDist = math.huge;
    for (const m of GetUnitList(UnitType.AlliedHeroes)) {
        if (Fu.IsValidHero(m) && !m.IsIllusion()) {
            const p = Fu.GetPosition(m);
            for (let j = 1; j <= tPosList.length; j++) {
                if (p === tPosList[j]) {
                    const d = GetUnitToLocationDistance(m, vLocation);
                    if (d < bestDist) {
                        bestDist = d;
                        bestPos = p;
                    }
                }
            }
        }
    }
    return bestPos ?? tPosList[0];
}

// == Core building selection ==
// Returns: furthestBuilding, urgencyMultiplier, tier (1..4)
export function GetFurthestBuildingOnLane(lane: Lane): [Unit | any, number, number] {
    const cacheKey = CK.FURTHEST_BUILDING + nTeam * 10 + (lane ?? 0);
    const cachedVar = Fu.Utils.GetCachedVars(cacheKey, 1);
    if (cachedVar != null) {
        return cachedVar;
    }

    const res = GetFurthestBuildingOnLaneHelper(lane);
    Fu.Utils.SetCachedVars(cacheKey, res);
    return res;
}

// Returns: furthestBuilding, urgencyMultiplier, tier (1..4)
export function GetFurthestBuildingOnLaneHelper(lane: Lane): [Unit | any, number, number] {
    const team = nTeam;
    let b: Unit | null;

    function hpMul(u: Unit, lo: number, hi: number, mlo: number, mhi: number) {
        const nHealth = u.GetHealth() / u.GetMaxHealth();
        return RemapValClamped(nHealth, lo, hi, mlo, mhi);
    }

    if (lane === Lane.Top) {
        b = GetTower(team, Tower.Top1);
        if (IsValidBuildingTarget(b)) return [b, hpMul(b, 0.25, 1, 0.5, 1), 1];
        b = GetTower(team, Tower.Top2);
        if (IsValidBuildingTarget(b)) return [b, hpMul(b, 0.25, 1, 1.0, 2), 2];
        b = GetTower(team, Tower.Top3);
        if (IsValidBuildingTarget(b)) return [b, hpMul(b, 0.25, 1, 1.5, 2), 3];
        b = GetBarracks(team, Barracks.TopMelee);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 3];
        b = GetBarracks(team, Barracks.TopRanged);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 3];
        b = GetTower(team, Tower.Base1);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 4];
        b = GetTower(team, Tower.Base2);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 4];
        b = GetAncient(team);
        if (IsValidBuildingTarget(b)) return [b, 3.0, 5];
    } else if (lane === Lane.Mid) {
        b = GetTower(team, Tower.Mid1);
        if (IsValidBuildingTarget(b)) return [b, hpMul(b, 0.25, 1, 0.5, 1), 1];
        b = GetTower(team, Tower.Mid2);
        if (IsValidBuildingTarget(b)) return [b, hpMul(b, 0.25, 1, 1.0, 2), 2];
        b = GetTower(team, Tower.Mid3);
        if (IsValidBuildingTarget(b)) return [b, hpMul(b, 0.25, 1, 1.5, 2), 3];
        b = GetBarracks(team, Barracks.MidMelee);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 3];
        b = GetBarracks(team, Barracks.MidRanged);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 3];
        b = GetTower(team, Tower.Base1);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 4];
        b = GetTower(team, Tower.Base2);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 4];
        b = GetAncient(team);
        if (IsValidBuildingTarget(b)) return [b, 3.0, 5];
    } else {
        b = GetTower(team, Tower.Bot1);
        if (IsValidBuildingTarget(b)) return [b, hpMul(b, 0.25, 1, 0.5, 1), 1];
        b = GetTower(team, Tower.Bot2);
        if (IsValidBuildingTarget(b)) return [b, hpMul(b, 0.25, 1, 1.0, 2), 2];
        b = GetTower(team, Tower.Bot3);
        if (IsValidBuildingTarget(b)) return [b, hpMul(b, 0.25, 1, 1.5, 2), 3];
        b = GetBarracks(team, Barracks.BotMelee);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 3];
        b = GetBarracks(team, Barracks.BotRanged);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 3];
        b = GetTower(team, Tower.Base1);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 4];
        b = GetTower(team, Tower.Base2);
        if (IsValidBuildingTarget(b)) return [b, 2.5, 4];
        b = GetAncient(team);
        if (IsValidBuildingTarget(b)) return [b, 3.0, 5];
    }

    return [null as any, 1.0, 0];
}

// Travel Boots defender dedupe
function IsThereNoTeammateTravelBootsDefender(bot: Unit): boolean {
    const unitState = updateDefendUnitStateCache();
    for (const m of unitState.teamMembers) {
        if (bot !== m && Fu.IsValidHero(m) && (m as any).travel_boots_defender === true) {
            return false;
        }
    }
    return true;
}

// Compute a “high-ground edge” wait point a bit outside the T3 toward lane
function GetHighGroundEdgeWaitPoint(team: Team, lane: Lane): Vector {
    const t3 = lane === Lane.Top ? GetTower(team, Tower.Top3) : lane === Lane.Mid ? GetTower(team, Tower.Mid3) : GetTower(team, Tower.Bot3);

    // try lane rax if T3 is gone
    const raxM =
        lane === Lane.Top ? GetBarracks(team, Barracks.TopMelee) : lane === Lane.Mid ? GetBarracks(team, Barracks.MidMelee) : GetBarracks(team, Barracks.BotMelee);
    const raxR =
        lane === Lane.Top ? GetBarracks(team, Barracks.TopRanged) : lane === Lane.Mid ? GetBarracks(team, Barracks.MidRanged) : GetBarracks(team, Barracks.BotRanged);

    const anc = GetAncient(team);

    // choose a lane HG anchor: T3 > any rax > last-resort fallback
    const anchorBuilding = (Fu.IsValidBuilding(t3) ? t3 : Fu.IsValidBuilding(raxM) ? raxM : Fu.IsValidBuilding(raxR) ? raxR : undefined) as Unit | undefined;

    if (anchorBuilding && Fu.IsValidBuilding(anc)) {
        const t = anchorBuilding.GetLocation();
        const a = (anc as Unit).GetLocation();
        const dir = Vector(a.x - t.x, a.y - t.y, 0);
        const len = math.max(1, math.sqrt(dir.x * dir.x + dir.y * dir.y));
        return Vector(t.x + (dir.x / len) * 250, t.y + (dir.y / len) * 250, 0);
    }

    // safer fallback: deeper inside base so HG hero clumps get counted
    return Fu.AdjustLocationWithOffsetTowardsFountain(GetLaneFrontLocation(team, lane, 0), 600);
}

// Role-aware defend decision (cached)
export function ShouldDefend(bot: Unit, hBuilding: Unit | null, nRadius: number): boolean {
    if (!IsValidBuildingTarget(hBuilding)) return false;
    // const cacheKey = `ShouldDefend:${bot.GetPlayerID()}:${hBuilding.GetLocation() ?? -1}:${nRadius}`;
    // const cachedVar = Fu.Utils.GetCachedVars(cacheKey, 0.6);
    // if (cachedVar != null) {
    //     return cachedVar;
    // }

    // Count enemies near building (recent seen heroes + weighted creeps)
    const gameState = updateDefendGameStateCache();
    let enemyHeroNearby = 0;
    for (const id of GetTeamPlayers(gameState.enemyTeam)) {
        if (IsHeroAlive(id)) {
            const info = GetHeroLastSeenInfo(id);
            if (info != null) {
                const d = info[0]; // TS 0-index
                if (d != null && d.time_since_seen <= CACHE_LASTSEEN_WINDOW && GetUnitToLocationDistance(hBuilding, d.location) <= 1600) {
                    enemyHeroNearby = enemyHeroNearby + 1;
                }
            }
        }
    }

    const unitState = updateDefendUnitStateCache();
    let creepWeights = 0;
    for (const unit of unitState.enemyCreeps) {
        if (Fu.IsValid(unit) && GetUnitToUnitDistance(hBuilding, unit) <= nRadius) {
            const name = unit.GetUnitName();
            if (string.find(name, "siege") !== null && string.find(name, "upgraded") === null) {
                creepWeights += 0.5;
            } else if (string.find(name, "upgraded_mega") !== null) {
                creepWeights += 0.6;
            } else if (string.find(name, "upgraded") !== null) {
                creepWeights += 0.4;
            } else if (string.find(name, "warlock_golem") !== null || string.find(name, "shadow_shaman_ward") !== null) {
                creepWeights += 1.0;
            } else if (string.find(name, "lone_druid_bear") !== null) {
                enemyHeroNearby = enemyHeroNearby + 1;
            } else if (
                unit.IsCreep() ||
                unit.IsAncientCreep() ||
                unit.IsDominated() ||
                unit.HasModifier("modifier_chen_holy_persuasion") ||
                unit.HasModifier("modifier_dominated")
            ) {
                creepWeights += 0.2;
            }
        }
    }

    const nNearby = enemyHeroNearby + math.floor(creepWeights);
    const pos = Fu.GetPosition(bot);

    let result = false;
    if (nNearby === 1) {
        if (pos === 2 || pos === 3 || pos === GetClosestAllyPos([4, 5], hBuilding.GetLocation())) {
            result = true;
        }
    } else if (nNearby === 2) {
        if (pos === 2 || pos === 3 || pos === GetClosestAllyPos([4, 5], hBuilding.GetLocation()) || (pos === 1 && GetUnitToUnitDistance(bot, hBuilding) <= 3200)) {
            result = true;
        }
    } else if (nNearby === 3) {
        if (pos === 2 || pos === 3 || pos === 4 || pos === 5 || (pos === 1 && GetUnitToUnitDistance(bot, hBuilding) <= 3200)) {
            result = true;
        }
    } else if (nNearby >= 4) {
        result = true;
    }

    // Travel Boots/Tinker escalation (one defender at a time)
    if (!result) {
        if (DotaTime() - fTraveBootsDefendTime >= 20.0) {
            (bot as any).travel_boots_defender = false;
        }
        if (
            bot.GetUnitName() === "npc_dota_hero_tinker" &&
            bot.GetLevel() >= 6 &&
            Fu.CanCastAbility(bot.GetAbilityByName("tinker_keen_teleport")) &&
            IsThereNoTeammateTravelBootsDefender(bot)
        ) {
            (bot as any).travel_boots_defender = true;
            fTraveBootsDefendTime = DotaTime();
            result = true;
        } else {
            const boots = Fu.GetItem2(bot, "item_travel_boots") || Fu.GetItem2(bot, "item_travel_boots_2");
            if (Fu.CanCastAbility(boots) && IsThereNoTeammateTravelBootsDefender(bot)) {
                (bot as any).travel_boots_defender = true;
                fTraveBootsDefendTime = DotaTime();
                result = true;
            }
        }

        if (!result && pos === GetClosestAllyPos([2, 3], hBuilding.GetLocation())) {
            result = true;
        }
    }

    const underFire = bot.WasRecentlyDamagedByAnyHero(5);
    if (underFire && result) {
        // Only the closest appropriate role should commit while under fire
        const closestPos = GetClosestAllyPos([2, 3, 4, 5], hBuilding.GetLocation());
        if (Fu.GetPosition(bot) !== closestPos) {
            return false;
        }
    }

    // Fu.Utils.SetCachedVars(cacheKey, result);
    return result;
}

// Ping teammates to defend (rate-limited; role-aware)
function ConsiderPingedDefend(bot: Unit, lane: Lane, desire: number, building: Unit | null, tier: number, nEffAllies: number, nEnemies: number) {
    const gameState = updateDefendGameStateCache();
    if (gameState.isLaningPhase || gameState.aliveAllyCount === 0) return;
    if (!IsValidBuildingTarget(building)) return;
    if (tier < 2 || desire <= 0.5) return;
    if (!ShouldDefend(bot, building, 1600)) return;

    (Fu.Utils as any)["GameStates"] = (Fu.Utils as any)["GameStates"] || {};
    (Fu.Utils as any)["GameStates"]["defendPings"] = (Fu.Utils as any)["GameStates"]["defendPings"] || { pingedTime: GameTime() };
    const defendPings = (Fu.Utils as any)["GameStates"]["defendPings"];

    if (nEffAllies >= 1 && nEffAllies >= nEnemies) return;
    if (GameTime() - defendPings.pingedTime <= 6.0) return;

    const saferLoc = add(Fu.AdjustLocationWithOffsetTowardsFountain(building.GetLocation(), 850), RandomVector(50));

    const retreaters = Fu.GetRetreatingAlliesNearLoc(saferLoc, 1600);
    if (retreaters.length === 0) {
        bot.ActionImmediate_Chat(Localization.Get("say_come_def"), false);
        bot.ActionImmediate_Ping(saferLoc.x, saferLoc.y, false);
        defendPings.pingedTime = GameTime();
        defendPings.lane = lane;
    }
}

// --- Panic hint: lane-gated floor without early returns ---
type PanicHint = { active: boolean; floor: number; forceLoc?: Vector };

export function GetDefendDesire(bot: Unit, lane: Lane): BotModeDesire {
    // 0) quick invalid checks
    if (bot.IsInvulnerable() || !bot.IsHero() || !bot.IsAlive() || !bot.GetUnitName().includes("hero") || bot.IsIllusion()) {
        return BotModeDesire.None;
    }

    // (pre) compute dynamic TTL and include threatened lane in key when base/HG pressure is present
    // const baseThreatNow = IsBaseThreatActive();
    // const enemiesOnHGNow = Fu.Utils.CountEnemyHeroesOnHighGround(nTeam);
    // const threatenedLaneNow = baseThreatNow || enemiesOnHGNow >= 1 ? GetThreatenedLane() : lane;

    // const cacheTTL = baseThreatNow || enemiesOnHGNow >= 1 ? 0.2 : 0.6;
    // const cacheKey = `DefendDesire:${bot.GetPlayerID()}:${lane ?? -1}:${threatenedLaneNow}`;

    // const cachedVar = Fu.Utils.GetCachedVars(cacheKey, cacheTTL);
    // if (cachedVar != null) {
    //     (bot as any).defendDesire = cachedVar;
    //     return cachedVar;
    // }

    let res = math.min(GetDefendDesireHelper(bot, lane), 1.0) as BotModeDesire;

    // Check if team is stronger at defend point (for attack transition)
    const defendLoc = getDefendState(bot).defendLoc || GetLaneFrontLocation(nTeam, lane, 0);
    const alliesHere = Fu.GetAlliesNearLoc(defendLoc, 2000);
    const enemiesHere = Fu.GetEnemiesNearLoc(defendLoc, 2000);
    const teamStronger = alliesHere.length >= 3 && enemiesHere.length >= 1 && alliesHere.length > enemiesHere.length && Fu.WeAreStronger(bot, 2500);

    // Cap: team is stronger at defend point, lower defend so Valve's attack mode (0.6) takes over.
    // Cap at 0.55 — high enough to beat farm/push/other modes, low enough for attack to win.
    if (teamStronger && res < 0.9) {
        res = math.min(res, 0.55) as BotModeDesire;
    }

    // Enemy in fight range → cut defend by 90% so attack mode can win.
    // "Nearby" = within 1200, within our attack range, or within 1600 and able to attack us.
    // Skip during base siege — ancient defense must not yield to attack mode when the
    // building itself is taking hits.
    const gsForNear = updateDefendGameStateCache();
    const baseUnderSiege = gsForNear.enemiesAtAncient >= 1 || gsForNear.enemiesOnHG >= 2;
    if (!baseUnderSiege) {
        const botLocForNear = bot.GetLocation();
        const botAtkRangeForNear = bot.GetAttackRange();
        const scanRange = math.max(1600, botAtkRangeForNear);
        for (const e of Fu.GetLastSeenEnemiesNearLoc(botLocForNear, scanRange)) {
            if (!Fu.IsValidHero(e)) continue;
            const dist = GetUnitToUnitDistance(bot, e);
            if (dist <= 1200 || dist <= botAtkRangeForNear || (dist <= 1600 && dist <= e.GetAttackRange())) {
                res = (res * 0.1) as BotModeDesire;
                break;
            }
        }
    }

    (bot as any).defendDesire = res;
    return res;
}

export function GetDefendDesireHelper(bot: Unit, lane: Lane): BotModeDesire {
    if ((bot as any).DefendLaneDesire == null) (bot as any).DefendLaneDesire = {} as Record<number, number>;
    if ((bot as any)._defendCommitLane == null) (bot as any)._defendCommitLane = 0;
    if ((bot as any)._defendCommitUntil == null) (bot as any)._defendCommitUntil = 0;

    // Update caches
    const gameState = updateDefendGameStateCache();
    const locationState = updateDefendLocationStateCache();

    const team = gameState.team;
    const ancient = gameState.ourAncient;

    // --- Multi-lane defend conflict: commit to one lane ---
    // When 2+ lanes need defending, pick the lane with highest building-tier-weighted
    // desire and stick to it for 5s to prevent back-and-forth oscillation.
    // Ancient/T4 always wins over T1/T2 thanks to urgentMul weighting.
    const commitLane = (bot as any)._defendCommitLane as Lane;
    const commitUntil = (bot as any)._defendCommitUntil as number;

    // Re-evaluate commitment: check which lanes actually need defending
    const lanesNeedingDefend: { lane: Lane; desire: number; dist: number; enemies: number; tier: number }[] = [];
    for (const l of [Lane.Top, Lane.Mid, Lane.Bot]) {
        const d = GetDefendLaneDesire(l);
        if (d > 0.1) {
            const front = locationState.laneFronts[l];
            const dist = GetUnitToLocationDistance(bot, front);
            const enemies = Fu.GetLastSeenEnemiesNearLoc(front, 2500).length;
            const [_bld, _urgent, bldTier] = GetFurthestBuildingOnLane(l);
            // Weight desire by building tier: ancient(5)=3.0x, T4(4)=2.5x, T3/rax(3)=2.0x, T2=1.5x, T1=1.0x
            const tierWeight = bldTier >= 5 ? 3.0 : bldTier >= 4 ? 2.5 : bldTier >= 3 ? 2.0 : bldTier >= 2 ? 1.5 : 1.0;
            lanesNeedingDefend.push({ lane: l, desire: d * tierWeight, dist, enemies, tier: bldTier });
        }
    }
    if (lanesNeedingDefend.length >= 2) {
        // Sort: highest tier-weighted desire first, then closer distance as tiebreaker
        lanesNeedingDefend.sort((a, b) => {
            if (a.desire !== b.desire) return b.desire - a.desire;
            return a.dist - b.dist;
        });
        const bestLane = lanesNeedingDefend[0].lane;
        // Override stale commitment if a higher-tier building is now threatened
        if (commitLane !== 0 && DotaTime() < commitUntil && lane !== commitLane) {
            // Allow override: if the current lane has a higher-tier building than the committed lane
            const commitEntry = lanesNeedingDefend.find(e => e.lane === commitLane);
            const thisEntry = lanesNeedingDefend.find(e => e.lane === lane);
            if (thisEntry && commitEntry && thisEntry.tier > commitEntry.tier && thisEntry.enemies >= 1) {
                // Higher priority building under threat — break commitment
                (bot as any)._defendCommitLane = lane;
                (bot as any)._defendCommitUntil = DotaTime() + 5;
            } else {
                // Still committed to a different lane — suppress this one
                return BotModeDesire.None;
            }
        } else if (lane !== bestLane) {
            // Commit to the best lane for 5s
            (bot as any)._defendCommitLane = bestLane;
            (bot as any)._defendCommitUntil = DotaTime() + 5;
            return BotModeDesire.None;
        } else {
            (bot as any)._defendCommitLane = bestLane;
            (bot as any)._defendCommitUntil = DotaTime() + 5;
        }
    } else if (DotaTime() >= commitUntil) {
        // No multi-lane conflict, clear commitment
        (bot as any)._defendCommitLane = 0;
    }

    // Per-bot state — avoids cross-bot data races from module-level vars
    const ds = getDefendState(bot);
    ds.defendLoc = locationState.laneFronts[lane];
    const distanceToDefendLoc = GetUnitToLocationDistance(bot, ds.defendLoc);

    // -- 如果不在当前线上，且等级低，不防守
    const botLevel = bot.GetLevel();
    if (
        bot.GetAssignedLane() !== lane &&
        distanceToDefendLoc > 3000 &&
        ((Fu.GetPosition(bot) === 1 && botLevel < 7) ||
            (Fu.GetPosition(bot) === 2 && botLevel < 7) ||
            (Fu.GetPosition(bot) === 3 && botLevel < 6) ||
            (Fu.GetPosition(bot) === 4 && botLevel < 4) ||
            (Fu.GetPosition(bot) === 5 && botLevel < 4))
    ) {
        return BotModeDesire.None;
    }

    // -- 如果等级低，不防守
    if (botLevel < 3) {
        return BotModeDesire.None;
    }

    // During laning phase, don't defend your OWN lane — laning mode handles it.
    // Only defend cross-lane rotations or when enemies are actually diving (2+ heroes).
    if (gameState.isLaningPhase && bot.GetAssignedLane() === lane) {
        const enemiesNearHub = Fu.GetLastSeenEnemiesNearLoc(ds.defendLoc, 1200);
        if (enemiesNearHub.length <= 1) {
            return BotModeDesire.None;
        }
    }

    // (Removed enemy-nearby cap — defend desire must stay high when
    // enemies are pushing base. Attack mode handles fighting separately.)

    // only suppress defend when THIS bot is pushing near an
    // enemy building with 3+ allies in the same push mode nearby.
    // (Old code was global — any 3 allies pushing anywhere killed ALL defend.)
    let teamIsPushing = false;
    const botMode = bot.GetActiveMode();
    const botIsPushing = botMode === BotMode.PushTowerTop || botMode === BotMode.PushTowerMid || botMode === BotMode.PushTowerBot;
    if (botIsPushing) {
        const nInRangeAlly = Fu.GetAlliesNearLoc(bot.GetLocation(), 1600);
        const nInRangeEnemy = Fu.GetLastSeenEnemiesNearLoc(bot.GetLocation(), 1400);
        if (nInRangeAlly.length >= nInRangeEnemy.length) {
            let pushingNearbyAllies = 0;
            for (const ally of nInRangeAlly) {
                if (Fu.IsValidHero(ally) && ally.GetActiveMode() === botMode) {
                    pushingNearbyAllies++;
                    if (pushingNearbyAllies >= 3) {
                        teamIsPushing = true;
                        break;
                    }
                }
            }
        }
    }
    const recentlyHit = bot.WasRecentlyDamagedByAnyHero(5) || bot.WasRecentlyDamagedByTower(5);

    // --- Base-first policy ---
    const threatenedLane = GetThreatenedLane();

    // Use cached values (computed once per 500ms, not 15x per tick)
    const enemiesOnHG = gameState.enemiesOnHG;
    const enemiesAtAncient = gameState.enemiesAtAncient;

    if (teamIsPushing && enemiesOnHG < 2) {
        return BotModeDesire.None;
    }

    // --- Hopeless defend: team-wide outnumber check ---
    // Computed once, used by all defend paths (panic, T4 early return, etc.)
    // to prevent solo bots from walking into a group of enemies.
    const ancientDyingEarly = ancient && ancient.IsAlive() && gameState.ancientHP < 0.4;
    const hopelessFight = !ancientDyingEarly && gameState.aliveEnemyCount >= 3 && gameState.aliveEnemyCount > gameState.aliveAllyCount + 1;
    const HOPELESS_DESIRE = (MAX_DESIRE_CAP * 0.5) as BotModeDesire; // 0.25: hold position, don't charge

    // Enemies already on our HG, bot is close to them, weaker, and outnumbered:
    // defending would just feed. Drop desire so retreat wins.
    if (enemiesOnHG >= 1) {
        const nearbyEnemies = Fu.GetLastSeenEnemiesNearLoc(bot.GetLocation(), 2000);
        if (nearbyEnemies.length >= 2) {
            let nearbyAllyHeroes = 0;
            for (const a of Fu.GetAlliesNearLoc(bot.GetLocation(), 1600)) {
                if (Fu.IsValidHero(a) && a !== bot) nearbyAllyHeroes++;
            }
            const weAreStronger = Fu.WeAreStronger(bot, 2500);
            if (!weAreStronger && nearbyEnemies.length >= nearbyAllyHeroes) {
                return (lane === threatenedLane ? MAX_DESIRE_CAP * 0.2 : MAX_DESIRE_CAP * 0.1) as BotModeDesire;
            }
        }
    }

    let panic: PanicHint = { active: false, floor: 0 };

    // ANCIENT UNDER DIRECT ATTACK: use cached values.
    // Tiered floor — threatened lane gets MAX_DESIRE_CAP, non-threatened lanes
    // get a smaller floor so they still beat farm/push (bot stays engaged with
    // base defense even if GetThreatenedLane flickers) but lose to the
    // threatened lane. Only threatened lane owns laneToDefend.
    if (ancient && ancient.IsAlive()) {
        const ancientHP = gameState.ancientHP;
        const defenderCount = gameState.defendersAtAncient;
        const panicFloor = lane === threatenedLane ? (hopelessFight ? HOPELESS_DESIRE : MAX_DESIRE_CAP) : hopelessFight ? HOPELESS_DESIRE * 0.7 : MAX_DESIRE_CAP * 0.7;
        const panicFloorCreeps = lane === threatenedLane ? MAX_DESIRE_CAP * 0.9 : MAX_DESIRE_CAP * 0.6;

        if (enemiesAtAncient >= 2 || (enemiesAtAncient >= 1 && ancientHP < 0.95)) {
            const neededDefenders = enemiesAtAncient + 1;
            if (defenderCount < neededDefenders) {
                baseThreatUntil = DotaTime() + BASE_THREAT_HOLD;
                panic = {
                    active: true,
                    floor: panicFloor,
                    forceLoc: Fu.AdjustLocationWithOffsetTowardsFountain(ancient.GetLocation(), 300),
                };
                if (lane === threatenedLane) (bot as any).laneToDefend = lane;
            }
        } else if (ancientHP < 0.95 && enemiesAtAncient === 0 && defenderCount === 0) {
            // Creeps hitting ancient with no defenders: send 1 bot (closest support/offlane)
            const pos = Fu.GetPosition(bot);
            const closestPos = GetClosestAllyPos([4, 5, 3], ancient.GetLocation());
            if (pos === closestPos) {
                panic = {
                    active: true,
                    floor: panicFloorCreeps,
                    forceLoc: Fu.AdjustLocationWithOffsetTowardsFountain(ancient.GetLocation(), 300),
                };
                if (lane === threatenedLane) (bot as any).laneToDefend = lane;
            }
        }
    }

    // Enemies on our HG → everyone defends, but threatened lane gets the higher
    // floor so it wins Valve's mode-selection tie.
    if (enemiesOnHG >= 2 && !recentlyHit) {
        baseThreatUntil = DotaTime() + BASE_THREAT_HOLD;
        const hgFloor = hopelessFight ? HOPELESS_DESIRE : lane === threatenedLane ? MAX_DESIRE_CAP : MAX_DESIRE_CAP * 0.7;
        const forceLoc = ancient ? Fu.AdjustLocationWithOffsetTowardsFountain(ancient.GetLocation(), 300) : ds.defendLoc;
        if (!panic.active) {
            panic = { active: true, floor: hgFloor, forceLoc };
        } else {
            panic.floor = math.max(panic.floor, hgFloor);
        }
        if (lane === threatenedLane) (bot as any).laneToDefend = lane;
    }

    // Base threat detection (sticky): heroes start, creeps can only extend
    const isBaseThreatActive = IsBaseThreatActive();
    if (ancient) {
        if (enemiesAtAncient >= 1) {
            baseThreatUntil = DotaTime() + BASE_THREAT_HOLD;
        } else if (isBaseThreatActive) {
            const creepWeight = WeightedEnemiesAroundLocation(ancient.GetLocation(), BASE_THREAT_RADIUS);
            if (creepWeight >= 2) {
                baseThreatUntil = DotaTime() + 1.5; // small top-up only
            }
        }
    }

    // If panic wants to force a safer anchor, do it before distance-dependent math.
    // Only redirect to ancient for the threatened lane — non-threatened lanes keep
    // their natural lane front so bots don't TP home while safely pushing another lane.
    if (panic.active && panic.forceLoc) {
        ds.defendLoc = panic.forceLoc;
    } else if (isBaseThreatActive && ancient && lane === threatenedLane) {
        ds.defendLoc = Fu.AdjustLocationWithOffsetTowardsFountain(ancient.GetLocation(), 300);
    }

    if (isBaseThreatActive) {
        // Non-threatened lanes: halve desire so threatened lane dominates,
        // but bot still has some defend awareness instead of ignoring base entirely.
        // Threatened lane: fall through with ancient-anchored defendLoc.
        if (lane !== threatenedLane) {
            (bot as any)._defendDesireHalved = true;
        }
    } else {
        // Opportunistically use enemy lanefront ONLY if not in base threat
        if (Fu.Utils.GetLocationToLocationDistance(gameState.teamFountainTpPoint, ds.defendLoc) < 3000) {
            const enemyLaneFront = locationState.enemyLaneFronts[lane];
            const eNear = Fu.GetLastSeenEnemiesNearLoc(enemyLaneFront, 1600);
            const aNear = Fu.GetAlliesNearLoc(enemyLaneFront, 1600);
            if (GetUnitToLocationDistance(bot, enemyLaneFront) > bot.GetAttackRange() && eNear.length <= aNear.length + 1) {
                ds.defendLoc = enemyLaneFront;
                // Removed: Action_AttackMove was a side-effect in desire function
            }
        }
    }

    ds.distanceToLane[lane] = GetUnitToLocationDistance(bot, ds.defendLoc);
    ds.nInRangeAlly = Fu.GetNearbyHeroes(bot, 1600, false, BotMode.None);
    ds.nInRangeEnemy = Fu.GetLastSeenEnemiesNearLoc(bot.GetLocation(), 1600);

    ds.weAreStronger = Fu.WeAreStronger(bot, 2500);
    // aliveAllyHeroes = gameState.aliveAllyCount; // Using cached value directly

    // Bail-outs to avoid feed / conflicts
    // NOTE: removed `ds.nInRangeEnemy.length > 0` — enemies near the bot
    // should NOT suppress defend. That's exactly when defending matters most.
    const pos = Fu.GetPosition(bot);
    const bMyLane = bot.GetAssignedLane() === lane;
    if (
        (!bMyLane && pos === 1 && gameState.isLaningPhase) || // keep carry safe early
        (Fu.IsDoingRoshan(bot) && Fu.GetAlliesNearLoc(Fu.GetCurrentRoshanLocation(), 2800).length >= 3) ||
        (Fu.IsDoingTormentor(bot) &&
            (Fu.GetAlliesNearLoc(Fu.GetTormentorLocation(team), 1600).length >= 2 || Fu.GetAlliesNearLoc(Fu.GetTormentorWaitingLocation(team), 2500).length >= 2) &&
            enemiesAtAncient === 0)
    ) {
        return BotModeDesire.None;
    }

    // Human priority ping (use a hint floor instead of early-return)
    let pingFloor = 0;
    const [human, humanPing] = Fu.GetHumanPing();
    if (human && humanPing && !humanPing.normal_ping && DotaTime() > 0) {
        const [isPinged, pingedLane] = Fu.IsPingCloseToValidTower(gameState.team, humanPing, 800, 5.0);
        if (isPinged && lane === pingedLane && GameTime() < humanPing.time + PING_DELTA) {
            (bot as any).laneToDefend = lane;
            pingFloor = MAX_DESIRE_CAP;
        }
    }

    // Compute desire anchored on furthest building
    const [furthestBuilding, _urgentMul, buildingTier] = GetFurthestBuildingOnLane(lane);
    if (!IsValidBuildingTarget(furthestBuilding)) {
        return BotModeDesire.None;
    }

    // immediate high desire when enemies at base buildings (T4/ancient).
    // Tiered: threatened lane = MAX_DESIRE_CAP, non-threatened = MAX_DESIRE_CAP*0.7
    // so the threatened lane wins mode-selection while others still beat farm/push.
    // When hopeless (outnumbered team-wide), use low desire to hold position not charge.
    if (buildingTier >= 4 && ancient && ancient.IsAlive() && enemiesAtAncient >= 2) {
        if (hopelessFight) {
            return HOPELESS_DESIRE;
        }
        return (lane === threatenedLane ? MAX_DESIRE_CAP : MAX_DESIRE_CAP * 0.7) as BotModeDesire;
    }

    // Can we get there fast enough?
    const distToBuilding = GetUnitToUnitDistance(bot, furthestBuilding);
    const walkTime = distToBuilding / math.max(1, bot.GetCurrentMovementSpeed());
    const tp = Fu.Utils.GetItemFromFullInventory(bot, "item_tpscroll");
    const hasTp = Fu.CanCastAbility(tp);
    const hasNPTeleport = Fu.CanCastAbility(bot.GetAbilityByName("furion_teleportation"));
    const hasTinkerTP = Fu.CanCastAbility(bot.GetAbilityByName("tinker_keen_teleport"));
    const canGetThereFast = hasTp || hasNPTeleport || hasTinkerTP || walkTime <= 11;

    // Use ShouldDefend to gate/dampen
    const shouldDef = ShouldDefend(bot, furthestBuilding, 1600);
    if (!shouldDef) {
        const nearEnemiesAtBuilding = Fu.GetLastSeenEnemiesNearLoc(furthestBuilding.GetLocation(), 1200);
        if (
            (!canGetThereFast && nearEnemiesAtBuilding.length === 0) ||
            (nearEnemiesAtBuilding.length === 0 && Fu.GetAlliesNearLoc(furthestBuilding.GetLocation(), 1600).length >= 1)
        ) {
            return BotModeDesire.None;
        }
    }

    // Check for actual enemy presence near the defend hub
    const hub = IsValidBuildingTarget(furthestBuilding) ? furthestBuilding.GetLocation() : GetLaneFrontLocation(nTeam, lane, 0);
    const lEnemies = Fu.GetLastSeenEnemiesNearLoc(hub, 2500);
    const nDefendAllies = Fu.GetAlliesNearLoc(hub, 2500);
    const nEffAllies = nDefendAllies.length + Fu.Utils.GetAllyIdsInTpToLocation(hub, 2500).length;

    const botPos = Fu.GetPosition(bot);
    const distToHub = GetUnitToLocationDistance(bot, hub);
    const hasTpScroll = Fu.CanCastAbility(Fu.Utils.GetItemFromFullInventory(bot, "item_tpscroll"));
    const isHighTier = buildingTier >= 3;

    // No enemy heroes near hub
    if (lEnemies.length === 0 && !panic.active) {
        // High-tier: creep waves can destroy T3/barracks — send 1 closest support
        if (isHighTier && shouldDef && nEffAllies === 0) {
            const creepWeight = WeightedEnemiesAroundLocation(hub, 1600);
            if (creepWeight >= 2) {
                const closestDefPos = GetClosestAllyPos([4, 5, 3], hub);
                if (botPos === closestDefPos) {
                    return 0.4 as BotModeDesire;
                }
            }
        }
        return BotModeDesire.None;
    }

    // --- Determine how many ADDITIONAL defenders are needed ---
    // T1: send +1 extra (enemies usually push T1 with few heroes, easy to contest)
    // T2: match enemy count +1
    // T3+: match enemy count +2 (must hold)
    const neededTotal = lEnemies.length + 2;
    const stillNeeded = neededTotal - nEffAllies;

    // Hopeless fight guard: don't trickle into a lost fight at T3+.
    // When enemy heroes at hub clearly outnumber our realistic force, keep a low
    // desire so bots hold position near base (Think positions them safely) rather
    // than wandering off to farm. High enough to beat farm/push, low enough that
    // retreat wins if the bot is actually in danger.
    if (isHighTier && lEnemies.length >= 3 && !panic.active) {
        const thisBotsContribution = distToHub < 3000 || hasTpScroll ? 1 : 0;
        const realisticForce = nEffAllies + thisBotsContribution;
        if (lEnemies.length > realisticForce + 1) {
            const ancientDying = ancient && ancient.IsAlive() && gameState.ancientHP < 0.4;
            if (!ancientDying) {
                return (MAX_DESIRE_CAP * 0.3) as BotModeDesire;
            }
        }
    }

    // Already enough defenders (including TPing allies) → only nearby bots stay
    if (stillNeeded <= 0 && !panic.active) {
        if (distToHub > 2000) return BotModeDesire.None;
    }

    // --- Priority gate: am I one of the closest N bots that should respond? ---
    // If 3+ allies are already defending this lane, it's serious — everyone should join.
    // Don't filter out bots when the team is already committing.
    const alliesAlreadyDefending = nDefendAllies.length;
    if (alliesAlreadyDefending < 3) {
        // Count allies that are EN ROUTE (closer than this bot, but NOT already at hub).
        if (stillNeeded > 0 && stillNeeded < 5) {
            let enRouteCloser = 0;
            for (const member of GetUnitList(UnitType.AlliedHeroes)) {
                if (member !== null && member.IsAlive() && member !== bot && !member.IsIllusion()) {
                    const memberDist = GetUnitToLocationDistance(member, hub);
                    if (memberDist > 2500 && memberDist < distToHub - 500) {
                        enRouteCloser++;
                    }
                }
            }
            if (enRouteCloser >= stillNeeded) {
                return BotModeDesire.None;
            }
        }
    }

    // --- Role/distance gates ---
    // uses ONLY canGetThereFast + ShouldDefend for gating.
    // Hard distance cutoffs previously here caused carries/mids to ignore T2 pushes
    // even with Travel Boots
    if (lEnemies.length >= 4 || alliesAlreadyDefending >= 3) {
        // Everyone comes
    } else if (!isHighTier) {
        // Prefer closest threatened lane — don't walk cross-map for T1/T2
        if (distToHub > 4000) {
            for (const otherLane of [Lane.Top, Lane.Mid, Lane.Bot] as Lane[]) {
                if (otherLane === lane) continue;
                const otherHub = GetLaneFrontLocation(nTeam, otherLane, 0);
                const otherDist = GetUnitToLocationDistance(bot, otherHub);
                const otherEnemies = Fu.GetLastSeenEnemiesNearLoc(otherHub, 2500);
                if (otherEnemies.length >= 1 && otherDist < distToHub - 1500) {
                    return BotModeDesire.None;
                }
            }
        }
    }

    // Normal laning: 1 enemy near our T2, everyone healthy — don’t defend, let laning handle it
    if (gameState.isLaningPhase && buildingTier === 2 && lEnemies.length <= 1 && !panic.active) {
        let allHealthy = true;
        for (const enemy of lEnemies) {
            if (Fu.IsValidHero(enemy) && Fu.GetHP(enemy) < 0.8) {
                allHealthy = false;
                break;
            }
        }
        if (allHealthy && Fu.GetHP(bot) > 0.8) {
            return BotModeDesire.None;
        }
    }

    // remap Valve’s GetDefendLaneDesire into [0, ABSOLUTE], multiply by tier.
    let nDefendDesire = RemapValClamped(GetDefendLaneDesire(lane), 0, 1, 0, 0.7) as number; // 0.7 = ABSOLUTE, don’t use enum (can resolve to 1.0)

    // suppress T1/T2 desire if bot is already defending another lane.
    // T3+ never suppressed — inner buildings always take priority.
    const bDefendingOtherLane = IsDefendingOtherLane(bot, lane);

    // multipliers + gating by building tier:
    // T1: *1, give up if HP < 0.25 with heroes or can’t reach
    // T2: *3, give up if HP < 0.25 with heroes or can’t reach
    // T3+: *5, always defend (heroes or not)
    if (buildingTier <= 1) {
        if (bDefendingOtherLane) return BotModeDesire.None;
        const hp = IsValidBuildingTarget(furthestBuilding) ? Fu.GetHP(furthestBuilding) : 1;
        if ((hp < 0.25 && lEnemies.length > 0) || !canGetThereFast) {
            return BotModeDesire.None;
        }
        // T1: nDesire * 1 (no multiplier)
    } else if (buildingTier === 2) {
        if (bDefendingOtherLane) return BotModeDesire.None;
        const hp = IsValidBuildingTarget(furthestBuilding) ? Fu.GetHP(furthestBuilding) : 1;
        if ((hp < 0.25 && lEnemies.length > 0) || !canGetThereFast) {
            return BotModeDesire.None;
        }
        nDefendDesire = nDefendDesire * 3;
    } else {
        // T3+ / rax / T4 / ancient — always prioritize, never suppress
        nDefendDesire = nDefendDesire * 5;
    }

    // Apply panic/ping floors
    if (panic.active) nDefendDesire = math.max(nDefendDesire, panic.floor);
    if (pingFloor > 0) nDefendDesire = math.max(nDefendDesire, pingFloor);

    // Serious fight: 4+ enemies or 3+ allies already defending → floor desire to beat farm
    // But not when hopeless — don't force bots into a fight they can't win.
    if ((lEnemies.length >= 4 || alliesAlreadyDefending >= 3) && !hopelessFight) {
        nDefendDesire = math.max(nDefendDesire, MAX_DESIRE_CAP);
    }

    // Ask for help if needed
    ConsiderPingedDefend(bot, lane, nDefendDesire, furthestBuilding, buildingTier, nEffAllies, lEnemies.length);

    // Track defend state for other systems
    if (nDefendDesire > MAX_DESIRE_CAP * 0.8) {
        (Fu.Utils as any).GameStates = (Fu.Utils as any).GameStates || {};
        (Fu.Utils as any).GameStates["recentDefendTime"] = DotaTime();
    }

    // Update laneToDefend: track which lane has highest desire, clear when none need defending.
    // Use lane enum values (Top=1, Mid=2, Bot=3) as keys directly to avoid TSTL array offset issues.
    const dld = (bot as any).DefendLaneDesire as Record<number, number>;
    dld[lane] = nDefendDesire;
    const dTop = dld[Lane.Top] || 0;
    const dMid = dld[Lane.Mid] || 0;
    const dBot = dld[Lane.Bot] || 0;
    const maxDesire = math.max(dTop, dMid, dBot);
    if (maxDesire < 0.1) {
        (bot as any).laneToDefend = null;
    } else {
        (bot as any).laneToDefend = dTop >= dMid && dTop >= dBot ? Lane.Top : dMid >= dBot ? Lane.Mid : Lane.Bot;
    }

    // Drop desire once bot is near the defend location — let Valve's attack mode (0.6) take over.
    // Cap at 0.55: high enough to beat farm/push/other defend lanes, low enough for attack to win.
    if (distToHub < 1200 && !panic.active) {
        nDefendDesire = math.min(nDefendDesire, 0.55);
    }

    // Bot already on-site with enemies in fight range — halve defend so attack mode (0.6) wins.
    if (distToHub < 900 && !panic.active) {
        const nearbyEnemies = Fu.GetLastSeenEnemiesNearLoc(bot.GetLocation(), 1200);
        if (nearbyEnemies.length > 0) {
            nDefendDesire = nDefendDesire * 0.5;
        }
    }

    // Non-threatened lane during base threat: halve desire so threatened lane wins
    if ((bot as any)._defendDesireHalved) {
        nDefendDesire = nDefendDesire * 0.5;
        (bot as any)._defendDesireHalved = false;
    }

    // if this bot is the closest
    // to this lane, ensure SOME defend desire so a responder always exists.
    // Only lifts very-low desires up to VERYLOW (0.05) — not an override, a nudge.
    {
        const dTop = GetUnitToLocationDistance(bot, locationState.laneFronts[Lane.Top]);
        const dMid = GetUnitToLocationDistance(bot, locationState.laneFronts[Lane.Mid]);
        const dBot2 = GetUnitToLocationDistance(bot, locationState.laneFronts[Lane.Bot]);
        let closestLane: Lane = Lane.Mid;
        if (dTop < dMid && dTop < dBot2) closestLane = Lane.Top;
        else if (dBot2 < dMid && dBot2 < dTop) closestLane = Lane.Bot;
        if (closestLane === lane && nDefendDesire > 0 && nDefendDesire < 0.35) {
            nDefendDesire = math.max(0.05, nDefendDesire);
        }
    }

    // Final clamp: defend must never exceed MAX_DESIRE_CAP
    return math.min(math.max(nDefendDesire, 0), MAX_DESIRE_CAP) as BotModeDesire;
}

export function DefendThink(bot: Unit, lane: Lane) {
    if (Fu.CanNotUseAction(bot)) return;
    // if (Fu.Utils.IsBotThinkingMeaningfulAction(bot, Customize.ThinkLess, ThinkActionType.Defend)) return;

    const ds = getDefendState(bot);
    if (!ds.defendLoc) ds.defendLoc = GetLaneFrontLocation(nTeam, lane, 0);
    const botLocation = bot.GetLocation();
    const safeRally = Fu.AdjustLocationWithOffsetTowardsFountain(ds.defendLoc, 300);

    // --- TP to defend location (shared helper handles safety/coordination) ---
    // During laning phase: only TP to defend expected lane, not cross-map.
    // Use Fu.GetExpectedLane (position-based online) because Valve's dynamic
    // balancer can flip bot.GetAssignedLane() mid-game, previously causing
    // e.g. a Dire pos1 top-laner to TP to bot lane on defend_tower_bot.
    const bCanTPDefend = !Fu.IsInLaningPhase() || Fu.GetExpectedLane(bot) === lane;
    if (bCanTPDefend && !(bot as any)._roshDipActive && ConsiderTPToTarget(bot, ds.defendLoc, true)) {
        return;
    }

    // Path safety: if enemies are between bot and defend location, detour around them.
    // Check midpoint between bot and hub for enemy presence.
    const distToDefend = GetUnitToLocationDistance(bot, ds.defendLoc);
    if (distToDefend > 2000) {
        const midpoint = Vector((botLocation.x + ds.defendLoc.x) / 2, (botLocation.y + ds.defendLoc.y) / 2, 0);
        const enemiesOnPath = Fu.GetLastSeenEnemiesNearLoc(midpoint, 1200);
        if (enemiesOnPath.length >= 1) {
            // Detour: move perpendicular to the direct path to avoid enemies
            const dx = ds.defendLoc.x - botLocation.x;
            const dy = ds.defendLoc.y - botLocation.y;
            const len = math.max(1, math.sqrt(dx * dx + dy * dy));
            // Perpendicular direction (rotated 90 degrees)
            const perpX = (-dy / len) * 1200;
            const perpY = (dx / len) * 1200;
            // Pick the side closer to our fountain
            const fountainLoc = nTeam === Team.Radiant ? RadiantFountainTpPoint : DireFountainTpPoint;
            const sideA = Vector(midpoint.x + perpX, midpoint.y + perpY, 0);
            const sideB = Vector(midpoint.x - perpX, midpoint.y - perpY, 0);
            let detour = GetLocationToLocationDistance(sideA, fountainLoc) < GetLocationToLocationDistance(sideB, fountainLoc) ? sideA : sideB;
            // Ensure detour location is passable; shrink offset until it is
            for (let shrink = 1.0; shrink >= 0.2; shrink -= 0.2) {
                const tryLoc = Vector(midpoint.x + (detour.x - midpoint.x) * shrink, midpoint.y + (detour.y - midpoint.y) * shrink, 0);
                if (IsLocationPassable(tryLoc)) {
                    detour = tryLoc;
                    break;
                }
            }
            bot.Action_MoveToLocation(detour);
            return;
        }
    }

    // Walk-through-fire guard: enemies near bot while en route (reactive fallback).
    const pathEnemies = Fu.GetLastSeenEnemiesNearLoc(botLocation, 1600);
    if (bot.WasRecentlyDamagedByAnyHero(5) && pathEnemies.length > ds.nInRangeEnemy.length) {
        bot.Action_MoveToLocation(add(safeRally, Fu.RandomForwardVector(100)));
        return;
    }

    // Base-defense: anchor near the building being attacked (T3/barracks), not ancient.
    // Bots were camping at T4/ancient while enemies destroyed T3.
    if (IsBaseThreatActive()) {
        // Find the actual threatened building on this lane
        const [threatBld] = GetFurthestBuildingOnLane(lane);
        const ancient = GetAncient(nTeam);
        // Anchor to threatened building if alive, otherwise ancient
        const anchorUnit = IsValidBuildingTarget(threatBld) ? threatBld : ancient;
        const anchorLoc = anchorUnit.GetLocation();
        const anchor = Fu.AdjustLocationWithOffsetTowardsFountain(anchorLoc, 200);

        // Check for enemies near the anchor (building being attacked)
        const enemiesNear = Fu.GetEnemiesNearLoc(anchorLoc, 1600);
        if (Fu.IsValidHero(enemiesNear[0]) && Fu.IsInRange(bot, enemiesNear[0], 1600)) {
            bot.Action_AttackUnit(enemiesNear[0], true);
            return;
        }

        // Move toward the anchor if too far
        const distToAnchor = GetUnitToLocationDistance(bot, anchorLoc);
        if (distToAnchor > 1200) {
            bot.Action_MoveToLocation(add(anchor, Fu.RandomForwardVector(200)));
            return;
        }

        // At anchor — attack-move toward enemies
        bot.Action_AttackMove(add(anchorLoc, Fu.RandomForwardVector(300)));
        return;
    }

    // Normal defend movement/targeting
    const attackRange = bot.GetAttackRange();
    const nSearchRange = (attackRange < 900 && 900) || math.min(attackRange, SEARCH_RANGE_DEFAULT);
    if (!ds.defendLoc) ds.defendLoc = GetLaneFrontLocation(nTeam, lane, 0);

    const [bld, _, buildingTier] = GetFurthestBuildingOnLane(lane);
    let hub = ds.defendLoc;
    if (IsValidBuildingTarget(bld)) hub = bld.GetLocation();
    if (!hub) hub = GetLaneFrontLocation(nTeam, lane, 0);

    // If hub is too close to fountain (creeps all dead, lane front collapsed),
    // use the nearest alive tower or HG edge instead of walking back to base.
    const ancient = GetAncient(nTeam);
    const ancientLoc = ancient !== null ? ancient.GetLocation() : hub;
    if (Fu.Utils.GetLocationToLocationDistance(hub, ancientLoc) < 2000) {
        if (IsValidBuildingTarget(bld)) {
            hub = bld.GetLocation();
        } else {
            hub = GetHighGroundEdgeWaitPoint(nTeam, lane);
        }
    }

    // Wave cutting detection: if enemy hero is between our T3/barracks and fountain,
    // they are cutting our creep wave. Move to intercept instead of waiting at lane front.
    {
        const ancientForCut = GetAncient(nTeam);
        if (ancientForCut !== null) {
            const ancientLocForCut = ancientForCut.GetLocation();
            // Check for enemies behind our line (within 2500 of ancient but NOT at the hub)
            const cutters = Fu.GetEnemiesNearLoc(ancientLocForCut, 2500);
            if (cutters.length > 0 && Fu.Utils.GetLocationToLocationDistance(hub, ancientLocForCut) > 2000) {
                // Enemy is behind our line — they're cutting waves
                const cutter = cutters[0];
                if (Fu.IsValidHero(cutter) && Fu.CanBeAttacked(cutter)) {
                    const distToCutter = GetUnitToUnitDistance(bot, cutter);
                    if (distToCutter < 2500) {
                        bot.Action_AttackUnit(cutter, true);
                        return;
                    } else {
                        bot.Action_MoveToLocation(cutter.GetLocation());
                        return;
                    }
                }
            }
        }
    }

    // If we are defending tier ≥3 lane hold the edge of the high ground
    if (buildingTier >= 3) {
        const edgeInside = GetHighGroundEdgeWaitPoint(nTeam, lane);
        const enemyAtHG = updateDefendGameStateCache().enemiesOnHG; // cached
        const nearEdgeEnemies = Fu.GetLastSeenEnemiesNearLoc(edgeInside, 1200);
        const nearEdgeAllies = Fu.GetAlliesNearLoc(edgeInside, 1400);

        // Default: hold just inside HG. Only step out if we have clear numbers.
        if (enemyAtHG === 0 && nearEdgeEnemies.length > 0 && nearEdgeAllies.length >= nearEdgeEnemies.length + 1) {
            const attackMoveLoc = add(edgeInside, Fu.RandomForwardVector(120));
            bot.Action_AttackMove(attackMoveLoc);
        } else {
            // tuck slightly deeper if contested or alone
            const deeper = Fu.AdjustLocationWithOffsetTowardsFountain(edgeInside, 200);
            const attackMoveLoc = add(deeper, Fu.RandomForwardVector(120));
            bot.Action_AttackMove(attackMoveLoc);
        }
        return;
    }

    // --- Engagement logic  ---
    const enemiesAtHub = Fu.GetEnemiesNearLoc(hub, SEARCH_RANGE_DEFAULT);
    const enemyCountHere = enemiesAtHub.length;
    const botDistToHub = GetUnitToLocationDistance(bot, hub);
    const alliesAtHub = Fu.GetAlliesNearLoc(hub, SEARCH_RANGE_DEFAULT);

    if (enemyCountHere >= 1) {
        const ancientUnit = GetAncient(nTeam);
        const ancientDying = ancientUnit && Fu.CanBeAttacked(ancientUnit) && Fu.GetHP(ancientUnit) < 0.5;

        if (alliesAtHub.length >= enemyCountHere || ancientDying || Fu.WeAreStronger(bot, 2500)) {
            // We have numbers (or ancient dying) — engage
            if (Fu.IsValidHero(enemiesAtHub[0]) && Fu.IsInRange(bot, enemiesAtHub[0], nSearchRange)) {
                bot.Action_AttackUnit(enemiesAtHub[0], true);
                return;
            }
            const nEnemyHeroes = bot.GetNearbyHeroes(SEARCH_RANGE_DEFAULT, true, BotMode.None);
            if (Fu.IsValidHero(nEnemyHeroes[0]) && Fu.IsInRange(bot, nEnemyHeroes[0], nSearchRange)) {
                bot.Action_AttackUnit(nEnemyHeroes[0], true);
                return;
            }
            bot.Action_MoveToLocation(add(hub, Fu.RandomForwardVector(200)));
            return;
        } else {
            // Outnumbered — position behind building toward fountain, don't fight
            const saferPos = Fu.AdjustLocationWithOffsetTowardsFountain(hub, 400);
            bot.Action_MoveToLocation(add(saferPos, Fu.RandomForwardVector(100)));
            return;
        }
    }

    // NO ENEMIES: clear creeps or patrol at gather position
    if (enemyCountHere === 0) {
        // Clear enemy creeps if any
        const creeps = bot.GetNearbyCreeps(900, true);
        if (creeps && creeps.length > 0) {
            let best: Unit | null = null;
            let bestScore = -1;
            for (const c of creeps) {
                if (Fu.IsValid(c) && Fu.CanBeAttacked(c)) {
                    const name = c.GetUnitName();
                    let score = c.GetAttackDamage() * c.GetAttackSpeed() * (1 - Fu.GetHP(c));
                    // Priority targets: siege > shaman wards > warlock golem > normal
                    if (name.includes("siege")) score += 10000;
                    else if (name.includes("shadow_shaman_ward")) score += 9000;
                    else if (name.includes("warlock_golem")) score += 8000;
                    if (score > bestScore) {
                        best = c;
                        bestScore = score;
                    }
                }
            }
            if (best) {
                bot.Action_AttackUnit(best, true);
                return;
            }
        }
    }

    // DEFAULT: no enemies, no creeps — move toward hub (the defend point)
    if (botDistToHub > 500) {
        bot.Action_MoveToLocation(add(hub, Fu.RandomForwardVector(200)));
    } else {
        // At hub — attack-move forward to clear incoming waves
        bot.Action_AttackMove(add(hub, Fu.RandomForwardVector(300)));
    }
}

export function OnEnd() {
    // no-op
}
