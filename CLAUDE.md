# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **dota2bot-OpenHyperAI** project -- Lua bot scripts for Dota 2 that run in custom lobbies. Currently supports Patch 7.41/7.41a with 127 heroes.

This repository is **Smart Bots (HATS)**, a fork of Open Hyper AI (based on upstream branch `pr-140-refactor`). Bot name suffix is `.HATS`. Goal: fair bots that play like smart (ideally pro) Dota 2 players. **No bonuses of any kind**: FretBots, Buff mode, difficulty voting, GPT chat and all network calls were removed. Chat is local only; position/pick/ban commands stay. Do not reintroduce bonuses, cheats or online requests. The only server-side script is `bots/FairNeutrals.lua` (optional, `sv_cheats 1; script_reload_code bots/FairNeutrals`): it crafts neutral items for bots by player rules (Madstone from neutral kills, tier unlock 5/15/25/35/60 min, pick 1 of 3 options) using the pool in `FuncLib/data/neutral_items.lua`. Keep it strictly fair. Recommended lobby difficulty is Valve's **Unfair** (maintainer's choice for a hard game; it gives enemy bots +25% gold/XP on Valve's side) — the scripts themselves must still add no bonuses. The maintainer is a non-programmer who speaks Russian and tests in-game.

Commit messages: do NOT add a `Claude-Session:` link (maintainer's request). A `Co-Authored-By` line is fine.

## Key Documentation

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** -- Complete codebase architecture, file map, naming conventions, all systems explained
- **[docs/PATCH_UPDATE_GUIDE.md](docs/PATCH_UPDATE_GUIDE.md)** -- Step-by-step runbook for updating when a new Dota 2 patch drops

**Read these docs FIRST before making any changes.** They contain everything needed to make targeted updates without scanning the entire repo.

## Build & Development Commands

```bash
npm run build          # Compile TypeScript to Lua (tstl + post-process)
npm run tstl           # Just the TypeScript-to-Lua compilation
npm run dev            # Watch mode for TS compilation
npm run prettier       # Format bots/ and typescript/
npm run obfuscate      # Minify bots/ for workshop publishing (backs up to bots-raw/)
npm run deobfuscate    # Restore bots/ from bots-raw/
npm run release        # Version bump + build + format
npm run release-ob     # release + obfuscate for workshop
```

When editing TS files under `typescript/bots/`, always compile with `npm run tstl` (or `npx tstl -p tsconfig-tstl.json`) and verify the Lua output in `bots/`.

## Reference Bot Code

The reference bot path and key file mappings are stored in `.env` as `DOTA2_REFERENCE_BOT_PATH` (also set as a permanent Windows user env var). Read the path from `.env` or the environment variable -- do not hardcode it.

**Always read the reference file FIRST before changing any mode's desire calculation, Think logic, or suppression conditions.** The reference code is battle-tested. Do not add logic that doesn't exist in the reference without explicit approval.

## Mode Desire System

Desire constants (defined in `bots/FuncLib/systems/global_overrides.lua`):
- `BOT_MODE_DESIRE_NONE` = 0, `VERYLOW` = 0.05, `LOW` = 0.175, `MODERATE` = 0.35
- `HIGH` = 0.525, `VERYHIGH` = 0.6, `ABSOLUTE` = 0.7
- `BOT_DESIRE_OVERRIDE` = 1.0 (only for channels, ShouldRun -- bypasses the 0.7 cap)

Critical rules for mode desires:
- **GetDesire controls mode selection. Think controls actions within the active mode.** They are independent -- returning early in Think does NOT change the mode. If Think returns early without issuing an action, the bot stands idle while staying in the mode.
- **Never return bare `return` in Think** without issuing an action first (Action_MoveToLocation, Action_AttackUnit, etc.) -- this causes stuck bots.
- **Never use `Action_ClearActions` followed by bare `return`** in Think -- same stuck issue.
- Defend max: `MAX_DESIRE_CAP = 0.6`. Push max: `0.525`. These stay below Valve's attack mode (0.65).
- Farm returns `NONE` when enemies are nearby -- relies on Valve's attack mode to fill the gap.

## Basic Dota2 Bot Logic Structure
### Team Level
This is code that determines how much the overall team wants to push each lane, defend each lane, farm each lane, or kill Roshan. These desires exist independent of the state of any of the bots. They are not authoritative; that is, they do not dictate any actions taken by any of the bots. They are instead just desires that the bots can use for decisionmaking.

### Mode Level
Modes are the high-level desires that individual bots are constantly evaluating, with the highest-scoring mode being their currently active mode. Examples of modes are laning, trying to kill a unit, farming, retreating, and pushing a tower.

### Action Level
Actions are the individual things that bots are actively doing on a moment-to-moment basis. These loosely correspond to mouse clicks or button presses -- things like moving to a location, or attacking a unit, or using an ability, or purchasing an item.

### Overall
The overall flow is that the team level is providing top-level guidance on the current strategy of the team. Each bot is then evaluating their desire score for each of its modes, which are taking into account both the team-level desires as well as bot-level desires. The highest scoring mode becomes the active mode, which is solely responsible for issuing actions for the bot to perform.
Reference: https://developer.valvesoftware.com/wiki/Dota_Bot_Scripting

### Mode Override
The list of valid bot modes to override are: laning, attack, roam, retreat, secret_shop, side_shop, rune, push_tower_top, push_tower_mid, push_tower_bot, defend_tower_top, defend_tower_mid, defend_tower_bot, assemble, assemble_with_humans, team_roam, farm, defend_ally, evasive_maneuvers, roshan, item, ward, watcher, lotus_pool, wisdom_shrine.

If you'd like to work within the existing mode architecture but override the logic for mode desire and behavior, for example the Laning mode, you can implement the following functions in a mode_laning_generic.lua file:
GetDesire() - Called every ~300ms, and needs to return a floating-point value between 0 and 1 that indicates how much this mode wants to be the active mode.
OnStart() - Called when a mode takes control as the active mode.
OnEnd() - Called when a mode relinquishes control to another active mode.
Think() - Called every frame while this is the active mode. Responsible for issuing actions for the bot to take.

## Common Tasks

### Check for New Patches

To check if there are patches we haven't updated for:
1. Fetch `https://www.dota2.com/datafeed/patchnoteslist?language=english`
2. Compare latest version against "Last updated for" in `docs/PATCH_UPDATE_GUIDE.md`
3. If newer patch exists, follow the update process below

### Patch Update (most common)

When user says "update for patch X.XX" or provides patch notes:

1. Read `docs/PATCH_UPDATE_GUIDE.md` for the step-by-step process
2. Fetch patch data: `https://www.dota2.com/datafeed/patchnotes?version=X.XX&language=english`
3. Fetch d2vpkr data (shops.txt, neutral_items.txt) for authoritative item/ability names
4. **Categorize changes**: STRUCTURAL (need code) vs NUMBER-ONLY (game API handles) vs TALENT SWAPS
5. **Always verify ability names on Liquipedia** -- patch note summaries can be wrong
6. Follow the checklist in order: items -> hero builds -> abilities -> neutrals -> actives -> map changes
7. **Always update TS sources** for any TS-generated Lua files changed (see ARCHITECTURE.md Section 13)

### Add a New Hero

1. Copy a similar existing hero from `bots/BotsLib/` as template
2. Add to `FuncLib/data/hero_names_locale.lua`, `FuncLib/data/hero_roles_map.lua`, `FuncLib/data/spell_list.lua`
3. See "New Heroes" section in `docs/PATCH_UPDATE_GUIDE.md`

### Fix a Hero's Item Build

1. Read `bots/BotsLib/hero_[name].lua`
2. Edit the `sRoleItemsBuyList['pos_N']` arrays
3. Items use `item_[internal_name]` format -- check `FuncLib/systems/item.lua` for valid names

### Fix a Hero's Ability Logic

1. Read `bots/BotsLib/hero_[name].lua`
2. The `SkillsComplement()` function controls ability casting priority
3. Each ability has a `ConsiderX()` function returning desire + target
4. See "Skill / Ability System" in `docs/ARCHITECTURE.md`

## Important Rules

- **Use `GetItemComponents()` for item recipes** -- don't hardcode component arrays
- **Use `sAbilityList[N]` references** when possible -- resilient to ability renames
- **Verify on Liquipedia** before trusting patch note summaries about ability names
- **Test in-game** after changes -- some things can only be verified at runtime

## TypeScript-to-Lua Files

These Lua files are compiled from TypeScript -- edit the TS source, not the Lua:
- `bots/FuncLib/systems/push.lua` ← `typescript/bots/FuncLib/systems/push.ts`
- `bots/FuncLib/systems/defend.lua` ← `typescript/bots/FuncLib/systems/defend.ts`
- `bots/FuncLib/systems/utils.lua` ← `typescript/bots/FuncLib/systems/utils.ts`
- `bots/FuncLib/systems/cache.lua` ← `typescript/bots/FuncLib/systems/cache.ts`
- `bots/ts_libs/dota/interfaces.lua` ← `typescript/bots/ts_libs/dota/interfaces.ts`

The `Fu` module (`FuncLib/func_utils.lua`) is pure Lua and uses `typescript/bots/FuncLib/func_utils.d.ts` for type declarations. When adding new `Fu.*` functions, update the `.d.ts` file so TS files can call them.

## Customization System

User settings load through `bots/FuncLib/systems/custom_loader.lua` which checks `game/Customize/general.lua` (user override) before falling back to `bots/Customize/general.lua`. Always use `custom_loader` when importing Customize, not direct require.
