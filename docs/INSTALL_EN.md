# Smart Bots (HATS): install and run

🇬🇧 **English** | 🇷🇺 [Русский](INSTALL_RU.md)

Step-by-step guide for Windows. If something does not work, see
[If something goes wrong](#if-something-goes-wrong) at the end.

---

## Contents

1. [What you need](#1-what-you-need)
2. [Find the Dota 2 folder](#2-find-the-dota-2-folder)
3. [Remove an old Open Hyper AI install](#3-remove-an-old-open-hyper-ai-install)
4. [Download Smart Bots](#4-download-smart-bots)
5. [Copy the bots into the game](#5-copy-the-bots-into-the-game)
6. [Settings (optional)](#6-settings-optional)
7. [Enable the Dota 2 console](#7-enable-the-dota-2-console)
8. [Create a lobby and start the game](#8-create-a-lobby-and-start-the-game)
9. [Start the Smart Bots server scripts](#9-start-the-smart-bots-server-scripts)
10. [How to tell everything works](#10-how-to-tell-everything-works)
11. [Chat commands](#11-chat-commands)
12. [Update the bots](#12-update-the-bots)
13. [Go back to Open Hyper AI or remove the bots](#13-go-back-to-open-hyper-ai-or-remove-the-bots)
14. [If something goes wrong](#if-something-goes-wrong)

---

## 1. What you need

- Dota 2 installed through Steam.
- About 10 MB of free space.
- No archiver needed: Windows opens ZIP files itself.
- **No** GitHub account needed: the project is public.

## 2. Find the Dota 2 folder

This guide calls it **the Dota 2 folder**.

1. Open Steam → **Library**.
2. Right-click **Dota 2** → **Manage** → **Browse local files**.
3. A folder like `...\steamapps\common\dota 2 beta` opens. This is the Dota 2 folder.

Example of a full path: `D:\SteamLibrary\steamapps\common\dota 2 beta`.
The bot scripts go into this subfolder:
```
dota 2 beta\game\dota\scripts\vscripts\
```

## 3. Remove an old Open Hyper AI install

**Skip this step if you never installed Open Hyper AI.**

The Open Hyper AI installer (`quick-install-oha.bat`) created a `bots` link in `vscripts` that points to
the Workshop folder. Remove it, otherwise the game loads Open Hyper AI instead of Smart Bots.
Open Hyper AI itself is **not** deleted and stays available from the Workshop.

1. Open `dota 2 beta\game\dota\scripts\vscripts\`.
2. Look at the `bots` folder:
   - **The folder icon has a shortcut arrow**: it is a link. Remove it:
     press `Win + R`, type `cmd`, press Enter and run (use your own path):
     ```
     rmdir "D:\SteamLibrary\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\bots"
     ```
     This removes only the link, not the Workshop files.
   - **A normal folder without an arrow**: rename it to `bots_old` (in case something of yours is inside).
3. There must be no `bots` folder in `vscripts` now.

## 4. Download Smart Bots

1. Open the project page: https://github.com/lyurf/dota2-smart-bots
2. Click the green **Code** button → **Download ZIP**.
3. Open the downloaded `dota2-smart-bots-main.zip` and unpack it (right-click → **Extract All**).
4. Inside is a `dota2-smart-bots-main` folder with the **`bots`** folder in it. That is the one you need.

## 5. Copy the bots into the game

1. Copy the **`bots`** folder from the unpacked archive.
2. Paste it into `dota 2 beta\game\dota\scripts\vscripts\`.
3. Check that the path is right, without an extra nested folder:
   ```
   ...\vscripts\bots\hero_selection.lua      ← correct
   ...\vscripts\bots\bots\hero_selection.lua ← wrong, the folder is nested twice
   ```

## 6. Settings (optional)

Everything works with the defaults. To change the chat language, the bot names or heroes, make your own
copy of the settings. It survives bot updates.

1. Open `dota 2 beta\game\dota\scripts\vscripts\`.
2. If there is a `game\Customize` folder from an older version, delete it.
3. Copy `bots\Customize` into `vscripts\game\` (create the `game` folder if it does not exist).
   You should get `vscripts\game\Customize\general.lua`.
4. Open `vscripts\game\Customize\general.lua` in Notepad and change what you need:

| Setting | What it does | Example |
|---|---|---|
| `Customize.Localization` | Bot chat language: `"ru"` (default), `"en"`, `"zh"`, `"ja"` | `Customize.Localization = "en"` |
| `Customize.Radiant_Names` / `Dire_Names` | Your own bot names; `'Random'` = from the Smart Bots list | `'Nil'` |
| `Customize.Radiant_Heros` / `Dire_Heros` | Bot heroes for positions 1–5 (internal names) | `'npc_dota_hero_lion'` |
| `Customize.Ban` | Heroes the bots never pick | `'npc_dota_hero_pudge'` |
| `Customize.Allow_Trash_Talk` | Bot banter in chat after kills | `false` = no banter |
| `Customize.Smart_Laning` | Smart Bots laning; `false` = Valve's laning | `true` |
| `Customize.Reaction_Delay` | Bot reaction delay before spells | `Enable = true` |
| `Customize.Push_Frequency` | 1 = more farming, 2 = balanced, 3 = pushing almost all the time (carry and mid always farm) | `2` |

Watch the quotes and commas: one typo disables all settings, and the bots get random names and heroes.
If that happens, just copy the file again.

## 7. Enable the Dota 2 console

The console is needed for the server scripts (step 9) and for the bot reports. You enable it once.

1. Steam → **Library** → right-click **Dota 2** → **Properties**.
2. On the **General** tab, in **Launch Options**, enter:
   ```
   -console -condebug
   ```
   `-condebug` saves the whole console to `dota 2 beta\game\dota\console.log`. The file is overwritten every
   time Dota 2 starts, so after a game just send the whole file instead of copying the console by hand.
3. Close the window and start Dota 2.
4. The console opens with the `\` key (backslash). If it does not, check the key in
   Dota 2 **Settings** → **Hotkeys** → console.

## 8. Create a lobby and start the game

1. In Dota 2 click **Play Dota** → **Custom Lobbies** → **Create**.
2. Open the lobby settings (**Edit**) and set:

| Setting | Value |
|---|---|
| Game Mode | any, e.g. All Pick or Turbo |
| Server Location | **Local Host** (required) |
| Bot Difficulty | **Unfair** |
| Radiant Bots | **Local Dev Script** |
| Dire Bots | **Local Dev Script** |
| Enable Cheats | ✔ checked (needed for step 9) |

3. Take a slot in your team. **The position is set by the slot from top to bottom:**
   slot 1 = carry, 2 = mid, 3 = offlane, 4 and 5 = supports.
4. Click **Fill Empty Slots With Bots** and **Start Game**.

To play with friends, invite them to the lobby before filling the slots with bots and seat them
on their positions.

## 9. Start the Smart Bots server scripts

The bots are tuned and tested with these scripts, so start them in every game.
Among other things they give every bot a neutral item as soon as each tier unlocks
(5, 15, 25, 35 and 60 min; twice as fast in Turbo): Valve does not let bots choose them themselves.
Like a player, the bot picks 1 of 3 artifacts and 1 of 3 enchantments.

The **Enable Cheats** checkbox only *allows* the scripts, it does not start them.
So the command is needed in any case.

1. **Enable Cheats** must be checked in the lobby.
2. When **hero selection** starts, open the console (`\`) and enter one command:
   ```
   sv_cheats 1; script_reload_code bots/SmartBots
   ```
3. The chat shows *"Smart Bots: neutral items enabled"* and the console shows
   `[SmartBots] Server scripts started.`

Enter the command **every game**.

**One-key start (easier).** Once, create the file `dota 2 beta\game\dota\cfg\autoexec.cfg`
(in Notepad; if the file already exists, add the line at the end):
```
bind "F11" "sv_cheats 1; script_reload_code bots/SmartBots"
```
After restarting Dota 2, just press **F11** during hero selection; no need to open the console.

## 10. How to tell everything works

- **Bot names end with `.HATS`**, e.g. `TyMaH.HATS`, `Nil.HATS`.
  Names ending with `.OHA` mean Open Hyper AI is loaded (see step 3). Random names without a tag mean an
  error in the settings file (see step 6) or the bots did not load (see the section below).
- Before the horn a bot on your team writes the welcome line **"Welcome to Smart Bots (HATS) 3.0"**
  (in the chat language you chose).
- With the server scripts running: console lines `[FairNeutrals] ... got tier 1 ...` around minute 5.
- At 5:00 and 10:00 every bot writes a lane report to the console:
  ```
  [LANE 10:00] npc_dota_hero_zuus pos 2: LH 45 / DN 12, level 8, nw 3600, team observers on map 2
  ```
  LH = last hits, DN = denies, nw = net worth, observers = your team's wards on the map.
- At 15, 20, 25, 30, 40 and 50 min every bot writes a summary: last hits, K/D/A, net worth and what it
  spent its time on (farming, pushing, fighting, retreating):
  ```
  [GAME 20:00] nevermore pos 2: LH 160 / DN 14, K/D/A 4/3/6, nw 11200, level 16, time: farm 48%, push 22%, attack 15%
  ```
- Every bot death goes to the console too: the mode it was in, its HP 8 seconds before, enemies and allies
  near and where it died:
  ```
  [DEATH 18:42] lion pos 5 (level 11): modes before death retreat <- ward, HP 64% 8s before, enemies near 3, allies near 0, enemy half (1200, 3400)
  ```
- When the bots go to kill your carry (your most farmed hero):
  ```
  [HUNT 18:05] ogre_magi, warlock, kunkka go after sniper (pos 1, 0 enemies near him)
  [HUNT 18:21] stop hunting sniper: target dead
  ```
- When an allied bot comes to help you:
  ```
  [ESCORT 18:40] lion goes to help ember_spirit (2 enemies)
  [ESCORT 18:52] lion stops helping ember_spirit: fight is over
  ```
- These lines help compare games and improve the bots: send them with your feedback.

## 11. Chat commands

Typed in the normal game chat, not in the console.

| Command | When | What it does |
|---|---|---|
| `ru`, `en`, `zh`, `ja` | hero selection | bot chat language |
| `!sp en` | any time | the same |
| `!pos 2` | before the horn | swap roles with the bot on position 2 |
| `!3pos 5` | before the horn | move the 3rd bot to position 5 |
| `!pick lion` | hero selection | pick a hero for a bot on your team |
| `/all !pick lion` | hero selection | pick a hero for a bot on the enemy team |
| `!ban zuus` | hero selection | ban a hero for the bots |
| `!pick lion; !ban zuus` | hero selection | several commands at once, separated by `;` |

**Call your allied bots:** place a normal ping (Alt + click, not "danger") **next to yourself**:
support bots within about half the map and nearby bots come to you. A ping far from you is treated as a
warning for another player and the bots do not go there. When you start a fight or go to gank in the enemy
half, supports come on their own. The bots judge hero strength (damage and health), not headcount: they
will come to two farmed cores fighting four weak enemies.

`!pick` does not work in Captains Mode. If the team captain is a bot, it bans and picks itself:
it bans strong heroes and heroes good against the ones already picked, and picks by role, counters and synergy.

## 12. Update the bots

1. Download the ZIP again (step 4).
2. Delete the old `vscripts\bots` folder and copy the new one (step 5).
3. Your settings in `vscripts\game\Customize` are kept. New settings in a new version are described in
   `bots\Customize\general.lua`; copy them into your file if you want.

## 13. Go back to Open Hyper AI or remove the bots

- **Play Open Hyper AI without removing Smart Bots:** in the lobby choose the **Open Hyper AI** bot script
  (from the Workshop) instead of Local Dev Script. You can even put Smart Bots on one side and Open Hyper AI
  on the other and compare.
- **Remove Smart Bots:** delete the `vscripts\bots` folder (and `vscripts\game\Customize` if you want).

---

## If something goes wrong

**Bot names end with `.OHA`.**
Open Hyper AI is loaded. Check step 3 (there must be no `bots` link to the Workshop) and that
**Local Dev Script** is selected in the lobby.

**The bots stand still, have random names without a tag, or the lobby has normal Valve bots.**
- The lobby server must be **Local Host**.
- Check the path: the file `vscripts\bots\hero_selection.lua` must exist (step 5).
- If you edited `general.lua`, restore the original file (copy it again from the archive) and try again.

**The console does not open.**
Check the `-console` launch option (step 7) and the console key in the Dota 2 hotkey settings.

**`[VScript] Script not found (scripts/vscripts/bots/SmartBots)` in the console.**
`vscripts\bots\SmartBots.lua` is missing: download the ZIP again and check step 5. Enter the command after
hero selection has started.

**The bots have no neutral items.**
- **Enable Cheats** must be checked in the lobby.
- The command from step 9 must be entered every game, in the console, during hero selection.
- Bots get their first item only after minute 5 (after 2:30 in Turbo).

**`Script Runtime Error: error in error handling` in the console at the start of the game.**
A known message; it does not affect the game.

**Something else.**
Open the console, copy its contents (or send `console.log`) and send it to the project author with a
description of what happened.
