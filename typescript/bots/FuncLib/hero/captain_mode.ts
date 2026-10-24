import { GameState, HeroPickState, Lane, Team } from "bots/ts_libs/dota";
import { CanBeOfflaner, CanBeMidlaner, CanBeSupport, CanBeSafeLaneCarry } from "bots/FuncLib/systems/role";
import { HeroName } from "bots/ts_libs/dota/heroes";
import { GetHeroPositions } from "bots/FuncLib/data/hero_pos_weights";
// eslint-disable-next-line @typescript-eslint/no-var-requires
import Matchups = require("bots/FuncLib/data/matchups_data");

const UnImplementedHeroes: string[] = [];

interface PairsHeroMap {
    [heroName: string]: string;
}

interface TeamHeroRoleMap {
    [team: string]: PairsHeroMap;
}

let ListPickedHeroes: string[] = [];
let AllHeroesSelected = false;
let BanCycle = 1;
let PickCycle = 1;
let NeededTime = 28;
const Min = 15;
const Max = 20;
const CMdebugMode = true;

const UnavailableHeroes: string[] = ["npc_dota_hero_techies"];

// Heroes the bots play poorly (same list as hero_selection.lua). The bot captain does not draft them.
const WeakHeroes: string[] = [
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
    "npc_dota_hero_wisp",
];

const HeroLanes: { [team: string]: { [i: number]: number } } = {
    TEAM_RADIANT: {
        1: Lane.Bot,
        2: Lane.Mid,
        3: Lane.Top,
        4: Lane.Top,
        5: Lane.Bot,
    },
    TEAM_DIRE: {
        1: Lane.Top,
        2: Lane.Mid,
        3: Lane.Bot,
        4: Lane.Bot,
        5: Lane.Top,
    },
};

let allBotHeroes: HeroName[] = [];

export const PairsHeroNameNRole: TeamHeroRoleMap = {
    TEAM_RADIANT: {},
    TEAM_DIRE: {},
};

let humanPick: HeroName[] = [];

// Picking logic for Captain's Mode Game Mode
export function CaptainModeLogic(SupportedHeroes: HeroName[]) {
    allBotHeroes = SupportedHeroes;

    if (GetGameState() !== GameState.HeroSelection) {
        return;
    }

    if (!CMdebugMode) {
        NeededTime = RandomInt(Min, Max);
    } else if (CMdebugMode) {
        NeededTime = 25;
    }

    const state = GetHeroPickState();
    if (state === HeroPickState.CmCaptainPick) {
        PickCaptain();
    } else if (state >= HeroPickState.CmBan1 && state <= 20 && GetCMPhaseTimeRemaining() <= NeededTime) {
        BansHero();
        NeededTime = 0;
    } else if (state >= HeroPickState.CmSelect1 && state <= HeroPickState.CmSelect10 && GetCMPhaseTimeRemaining() <= NeededTime) {
        PicksHero();
        NeededTime = 0;
    } else if (state === HeroPickState.CmPick) {
        SelectsHero();
    }
}

// Pick the captain
export function PickCaptain() {
    if (!IsHumanPlayerExist() || DotaTime() > -1) {
        if (GetCMCaptain() === -1) {
            const CaptBot = GetFirstBot();
            if (CaptBot !== null && CaptBot !== undefined) {
                log("CAPTAIN PID : %s", CaptBot);
                SetCMCaptain(CaptBot);
            }
        }
    }
}

// Check if human player exist in team
export function IsHumanPlayerExist(): boolean {
    const Players = GetTeamPlayers(GetTeam());
    for (const id of Players) {
        if (!IsPlayerBot(id)) {
            return true;
        }
    }
    return false;
}

// Get the first bot to be the captain
export function GetFirstBot(): number | null {
    let BotId: number | null = null;
    const Players = GetTeamPlayers(GetTeam());
    for (const id of Players) {
        if (IsPlayerBot(id)) {
            BotId = id;
            return BotId;
        }
    }
    return BotId;
}

// Ban hero function
function BansHero() {
    if (!IsPlayerBot(GetCMCaptain()) || !IsPlayerInHeroSelectionControl(GetCMCaptain())) {
        return;
    }
    const BannedHero = BestBan();
    log("%s is banned", BannedHero);
    CMBanHero(BannedHero);
    BanCycle = BanCycle + 1;
}

// Pick hero function
function PicksHero() {
    if (!IsPlayerBot(GetCMCaptain()) || !IsPlayerInHeroSelectionControl(GetCMCaptain())) {
        return;
    }

    const sTeamName = GetTeam() === Team.Radiant ? "TEAM_RADIANT" : "TEAM_DIRE";
    // Order: offlaner, support, mid, support, carry. The carry and mid go late so they
    // can counter the enemy lineup, like captains usually do.
    let PickedHero: HeroName;
    if (PickCycle === 1) {
        PickedHero = BestHeroForRole([3], CanBeOfflaner);
        PairsHeroNameNRole[sTeamName][PickedHero] = "offlaner";
    } else if (PickCycle === 2 || PickCycle === 4) {
        PickedHero = BestHeroForRole([4, 5], CanBeSupport);
        PairsHeroNameNRole[sTeamName][PickedHero] = "support";
    } else if (PickCycle === 3) {
        PickedHero = BestHeroForRole([2], CanBeMidlaner);
        PairsHeroNameNRole[sTeamName][PickedHero] = "midlaner";
    } else {
        PickedHero = BestHeroForRole([1], CanBeSafeLaneCarry);
        PairsHeroNameNRole[sTeamName][PickedHero] = "carry";
    }

    log("%s is picked", PickedHero);
    CMPickHero(PickedHero);
    PickCycle = PickCycle + 1;
}

// Add to list human picked heroes
export function AddToList() {
    if (!IsPlayerBot(GetCMCaptain())) {
        for (const h of allBotHeroes) {
            if (IsCMPickedHero(GetTeam(), h) && !AlreadyInTable(h)) {
                humanPick.push(h);
            }
        }
    }
}

// Check if selected hero already picked by human
function AlreadyInTable(hero_name: string): boolean {
    for (const h of humanPick) {
        if (hero_name === h) {
            return true;
        }
    }
    return false;
}

// Check if the randomed hero doesn't available for captain's mode
function IsUnavailableHero(name: string): boolean {
    for (const uh of UnavailableHeroes) {
        if (name === uh) {
            return true;
        }
    }
    return false;
}

// Random hero which is non picked, non banned, or non human picked heroes if the human is the captain
function RandomHero(): HeroName {
    let hero = allBotHeroes[RandomInt(1, allBotHeroes.length) - 1];
    for (let i = 0; i < 1000 && IsTaken(hero); i++) {
        hero = allBotHeroes[RandomInt(1, allBotHeroes.length) - 1];
    }
    return hero;
}

// ----------------------------------------- CAPTAIN'S MODE DRAFT SCORING -----------------------------------------
// Smart Bots: the bot captain drafts with the same matchup data as All Pick instead of random heroes.

function IsTaken(hero: string): boolean {
    return IsUnavailableHero(hero) || IsCMPickedHero(GetTeam(), hero) || IsCMPickedHero(GetOpposingTeam(), hero) || IsCMBannedHero(hero);
}

function IsWeakHero(hero: string): boolean {
    for (const h of WeakHeroes) {
        if (h === hero) {
            return true;
        }
    }
    return false;
}

function PickedHeroesOf(team: Team): string[] {
    const result: string[] = [];
    for (const h of allBotHeroes) {
        if (IsCMPickedHero(team, h)) {
            result.push(h);
        }
    }
    return result;
}

function SignedSqrt(x: number): number {
    return x >= 0 ? Math.sqrt(x) : -Math.sqrt(-x);
}

// Best fit (0..100) of the hero for any of the given positions.
function RoleWeight(hero: string, positions: number[]): number {
    const weights = GetHeroPositions()[hero];
    if (weights === undefined) {
        return 0;
    }
    let best = 0;
    for (const pos of positions) {
        const w = weights[pos - 1];
        if (w !== undefined && w > best) {
            best = w;
        }
    }
    return best;
}

// How strong a hero is in general: average advantage over every other hero.
const generalStrength: { [hero: string]: number } = {};
function GeneralStrength(hero: string): number {
    const cached = generalStrength[hero];
    if (cached !== undefined) {
        return cached;
    }
    let sum = 0;
    let count = 0;
    for (const other of allBotHeroes) {
        if (other !== hero) {
            const adv = Matchups.GetAdvantage(hero, other);
            if (adv !== 0) {
                sum = sum + adv;
                count = count + 1;
            }
        }
    }
    const value = count > 0 ? sum / count : 0;
    generalStrength[hero] = value;
    return value;
}

// Weighted random pick among the best few candidates (for picks 50/30/20, for bans 35/25/20/12/8).
function PickFromTop(scored: { name: HeroName; score: number }[], weights: number[]): HeroName | undefined {
    if (scored.length === 0) {
        return undefined;
    }
    scored.sort((a, b) => b.score - a.score);
    let roll = RandomInt(1, 100);
    for (let i = 0; i < weights.length && i < scored.length; i++) {
        roll = roll - weights[i];
        if (roll <= 0) {
            return scored[i].name;
        }
    }
    return scored[0].name;
}

const PICK_FUZZ = [50, 30, 20];
const BAN_FUZZ = [35, 25, 20, 12, 8];
// A hero must fit the role at least this well (hero_pos_weights, 0..100) to be drafted for it.
const MIN_ROLE_WEIGHT = 40;

function BestHeroForRole(positions: number[], canPlay: (hero: HeroName) => boolean): HeroName {
    const enemies = PickedHeroesOf(GetOpposingTeam());
    const allies = PickedHeroesOf(GetTeam());
    const scored: { name: HeroName; score: number }[] = [];
    const scoredLooseFit: { name: HeroName; score: number }[] = [];
    for (const hero of allBotHeroes) {
        if (!IsTaken(hero) && !IsWeakHero(hero) && canPlay(hero)) {
            const roleWeight = RoleWeight(hero, positions);
            // Role fit counts most: a hero that fits the role well is worth more than a small counter.
            let score = (roleWeight - 50) / 5;
            for (const e of enemies) {
                score = score + SignedSqrt(Matchups.GetAdvantage(hero, e));
            }
            for (const a of allies) {
                if (Matchups.IsSynergy(hero, a)) {
                    score = score + 1.5;
                }
            }
            score = score + GeneralStrength(hero) / 2;
            if (roleWeight >= MIN_ROLE_WEIGHT) {
                scored.push({ name: hero, score: score });
            } else {
                scoredLooseFit.push({ name: hero, score: score });
            }
        }
    }
    const best = PickFromTop(scored, PICK_FUZZ) ?? PickFromTop(scoredLooseFit, PICK_FUZZ);
    if (best !== undefined) {
        log("CM pick for positions %s: %s", positions.join("/"), best);
        return best;
    }
    // Fallback: any free hero that can play the role (bounded, never loops forever).
    for (let i = 0; i < 300; i++) {
        const hero = RandomHero();
        if (canPlay(hero)) {
            return hero;
        }
    }
    return RandomHero();
}

// Ban the hero that would hurt us most: strong in general, good against the heroes we
// already have, and good together with the heroes the enemy already has.
function BestBan(): HeroName {
    const enemies = PickedHeroesOf(GetOpposingTeam());
    const allies = PickedHeroesOf(GetTeam());
    const scored: { name: HeroName; score: number }[] = [];
    for (const hero of allBotHeroes) {
        if (!IsTaken(hero)) {
            let score = GeneralStrength(hero);
            for (const a of allies) {
                score = score + SignedSqrt(Matchups.GetAdvantage(hero, a));
            }
            for (const e of enemies) {
                if (Matchups.IsSynergy(hero, e)) {
                    score = score + 1.5;
                }
            }
            scored.push({ name: hero, score: score });
        }
    }
    return PickFromTop(scored, BAN_FUZZ) ?? RandomHero();
}

// Check if the human already pick the hero in captain's mode
function WasHumansDonePicking(): boolean {
    const Players = GetTeamPlayers(GetTeam());
    for (const id of Players) {
        if (!IsPlayerBot(id)) {
            const selected = GetSelectedHeroName(id);
            if (selected == null || selected === "") {
                return false;
            }
        }
    }
    return true;
}

// Select the rest of the heroes that the human players don't pick in captain's mode
function SelectsHero() {
    if (!AllHeroesSelected && (WasHumansDonePicking() || GetCMPhaseTimeRemaining() < 1)) {
        const Players = GetTeamPlayers(GetTeam());
        const RestBotPlayers: number[] = [];
        GetTeamSelectedHeroes();

        // Remove heroes already selected by humans
        for (const id of Players) {
            const hero_name = GetSelectedHeroName(id);
            if (hero_name !== null && hero_name !== "") {
                UpdateSelectedHeroes(hero_name);
                log("%s Removed", hero_name);
            } else {
                RestBotPlayers.push(id);
            }
        }

        for (let i = 0; i < RestBotPlayers.length; i++) {
            SelectHero(RestBotPlayers[i], ListPickedHeroes[i]);
        }

        AllHeroesSelected = true;
    }
}

// Get the team picked heroes
function GetTeamSelectedHeroes() {
    for (const sName of allBotHeroes) {
        if (IsCMPickedHero(GetTeam(), sName)) {
            ListPickedHeroes.push(sName);
        }
    }
    for (const sName of UnImplementedHeroes) {
        if (IsCMPickedHero(GetTeam(), sName)) {
            ListPickedHeroes.push(sName);
        }
    }
}

// Update team picked heroes after human players select their desired hero
function UpdateSelectedHeroes(selected: string) {
    for (let i = 0; i < ListPickedHeroes.length; i++) {
        if (ListPickedHeroes[i] === selected) {
            ListPickedHeroes.splice(i, 1);
            break;
        }
    }
}

// ----------------------------------------- CAPTAIN'S MODE LANE ASSIGNMENT -----------------------------------------
// let doneLaneAssignementOnce = false;
let RoleAssignment: { [team: string]: { [index: number]: number } } = {
    TEAM_RADIANT: {},
    TEAM_DIRE: {},
};
// let playerSwitchedRoles = false;

export function CMLaneAssignment(roleAssign: { [team: string]: { [i: number]: number } }) {
    //, switchedRoles: boolean) {
    const sTeamName = GetTeam() === Team.Radiant ? "TEAM_RADIANT" : "TEAM_DIRE";

    RoleAssignment = roleAssign;
    // playerSwitchedRoles = switchedRoles; // TODO: role assignment to be improved

    if (IsPlayerBot(GetCMCaptain())) {
        FillLaneAssignmentTable();
    } else {
        // FillLAHumanCaptain(); // TODO if needed
    }
    return HeroLanes[sTeamName];
}

// Lane Assignment if the captain is not human
function FillLaneAssignmentTable() {
    const TeamMember = GetTeamPlayers(GetTeam());
    const sTeamName = GetTeam() === Team.Radiant ? "TEAM_RADIANT" : "TEAM_DIRE";
    const supportAlreadyAssigned: { [team: string]: boolean } = {
        TEAM_RADIANT: false,
        TEAM_DIRE: false,
    };

    for (let i = 0; i < TeamMember.length; i++) {
        const unit = GetTeamMember(i + 1);
        if (unit !== null && unit.IsHero()) {
            const unit_name = unit.GetUnitName();
            const roleName = PairsHeroNameNRole[sTeamName][unit_name];
            if (roleName === "support") {
                if (GetTeam() === Team.Radiant) {
                    if (!supportAlreadyAssigned.TEAM_RADIANT) {
                        HeroLanes[sTeamName][i + 1] = Lane.Bot;
                        supportAlreadyAssigned.TEAM_RADIANT = true;
                        RoleAssignment[sTeamName][i + 1] = 5;
                    } else {
                        HeroLanes[sTeamName][i + 1] = Lane.Top;
                        RoleAssignment[sTeamName][i + 1] = 4;
                    }
                } else {
                    if (!supportAlreadyAssigned.TEAM_DIRE) {
                        HeroLanes[sTeamName][i + 1] = Lane.Top;
                        supportAlreadyAssigned.TEAM_DIRE = true;
                        RoleAssignment[sTeamName][i + 1] = 5;
                    } else {
                        HeroLanes[sTeamName][i + 1] = Lane.Bot;
                        RoleAssignment[sTeamName][i + 1] = 4;
                    }
                }
            } else if (roleName === "midlaner") {
                HeroLanes[sTeamName][i + 1] = Lane.Mid;
                RoleAssignment[sTeamName][i + 1] = 2;
            } else if (roleName === "offlaner") {
                if (GetTeam() === Team.Radiant) {
                    HeroLanes[sTeamName][i + 1] = Lane.Top;
                } else {
                    HeroLanes[sTeamName][i + 1] = Lane.Bot;
                }
                RoleAssignment[sTeamName][i + 1] = 3;
            } else if (roleName === "carry") {
                if (GetTeam() === Team.Radiant) {
                    HeroLanes[sTeamName][i + 1] = Lane.Bot;
                } else {
                    HeroLanes[sTeamName][i + 1] = Lane.Top;
                }
                RoleAssignment[sTeamName][i + 1] = 1;
            }
            // doneLaneAssignementOnce = true;
        }
    }
}

// Fill the lane assignment if the captain is human
// function FillLAHumanCaptain() {
//     const sTeamName = GetTeam() === Team.Radiant ? 'TEAM_RADIANT' : 'TEAM_DIRE';
//     const TeamMember = GetTeamPlayers(GetTeam());
//     for (let i = 0; i < TeamMember.length; i++) {
//         const unit = GetTeamMember(i + 1);
//         if (unit !== null && unit.IsHero()) {
//             const unit_name = unit.GetUnitName();
//             const key = GetFromHumanPick(unit_name);
//             if (key !== null && key !== undefined) {
//                 if (key === 1) {
//                     if (GetTeam() === Team.Dire) {
//                         HeroLanes[sTeamName][i + 1] = Lane.Bot;
//                     } else {
//                         HeroLanes[sTeamName][i + 1] = Lane.Top;
//                     }
//                 } else if (key === 2) {
//                     if (GetTeam() === Team.Dire) {
//                         HeroLanes[sTeamName][i + 1] = Lane.Bot;
//                     } else {
//                         HeroLanes[sTeamName][i + 1] = Lane.Top;
//                     }
//                 } else if (key === 3) {
//                     HeroLanes[sTeamName][i + 1] = Lane.Mid;
//                     RoleAssignment[sTeamName][i + 1] = 2;
//                 } else if (key === 4) {
//                     if (GetTeam() === Team.Dire) {
//                         HeroLanes[sTeamName][i + 1] = Lane.Top;
//                     } else {
//                         HeroLanes[sTeamName][i + 1] = Lane.Bot;
//                     }
//                 } else if (key === 5) {
//                     if (GetTeam() === Team.Dire) {
//                         HeroLanes[sTeamName][i + 1] = Lane.Top;
//                     } else {
//                         HeroLanes[sTeamName][i + 1] = Lane.Bot;
//                     }
//                 }
//             }
//         }
//     }
// }

// Get human picked heroes if the captain is human player
// function GetFromHumanPick(hero_name: string): number | null {
//     for (let key = 0; key < humanPick.length; key++) {
//         if (hero_name === humanPick[key]) {
//             return key + 1; // +1 to mimic Lua's 1-based indexing if needed
//         }
//     }
//     return null;
// }
