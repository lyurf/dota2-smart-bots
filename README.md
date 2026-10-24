# Smart Bots (HATS) — Dota 2 Bot Scripts

**Bots that win by playing smarter, not by cheating.** Smart Bots is a fork of
[Open Hyper AI](https://github.com/forest0xia/dota2bot-OpenHyperAI) focused on team strategy:
bots group up, push after won fights, stop over-farming and react like humans instead of instantly.

The goal is bots that play like smart Dota 2 players. **Completely fair:** no bonus gold, experience or
stats from the scripts, no cheats, no difficulty voting, no online requests. Install, start a lobby and play.

> Bots installed correctly have names ending with **`.HATS`**.

---

## What's different from Open Hyper AI

- **Team pushing against humans.** Bot teams coordinate pushes, siege after a won fight, finish lanes
  after barracks fall and counter-push after a successful defense. In the original this only worked
  in all-bot games.
- **Smarter laning.** Every hero uses Smart Bots laning instead of Valve's built-in one: the bot stands
  ready next to an enemy creep that is about to die, denies, and supports leave last hits to their core
  (in the original, supports took the core's farm). `Smart_Laning = false` switches back.
- **Less over-farming.** Bots leave the jungle and push when 2 or fewer enemies are alive.
- **Human-like reaction time.** Configurable delay before casting spells and items when an enemy
  appears, and between casts (`Reaction_Delay` in `Customize/general.lua`).
- **Smarter defaults.** Push-oriented play (`Push_Frequency = 3`) and full thinking (`ThinkLess = 0`).
- **One settings file.** All modes read settings through the same loader, so a single
  `vscripts/game/Customize/general.lua` overrides everything.
- **No bonus modes.** FretBots and Buff mode (bonus gold/XP/stats, voting) are removed, together with
  GPT chat and every network request. Bot chat is local.
- **Fair neutral items.** Optional script that crafts neutrals for bots by the players' rules
  (Madstone from camps, same tier timings), instead of FretBots handing them out as a bonus.

Everything else (127 heroes, item builds, all game modes, `!pos` / `!pick` / `!ban` commands)
comes from Open Hyper AI.

---

## Install (Windows)

1. **Remove the old link** if you used the Open Hyper AI quick installer. Open `cmd` and run
   (fix the path to your Steam library):
   ```cmd
   rmdir "D:\SteamLibrary\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\bots"
   ```
   This removes only the link, not the Workshop files. If the folder is a real folder (not a link),
   rename it to `bots_old` instead.
2. On this page click **Code → Download ZIP** and unpack it.
3. Copy the `bots` folder from the archive into
   `...\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\`.
4. In Dota 2 create a **Custom Lobby**: Server Location **Local Host**, bot script **Local Dev Script**,
   bot difficulty **Unfair**.

### Your settings

Copy `bots\Customize` to `...\vscripts\game\Customize` and edit `general.lua` there.
That copy survives updates of the bots folder.

### Neutral items (recommended)

Valve does not let bots craft neutral items. Smart Bots includes a small server script that crafts them
for bots **by the same rules as for players** and gives nothing else:

- bots earn Madstone only by killing neutral creeps (plus a share when an ally clears a camp), from minute 5;
- a tier is crafted only when it is unlocked by game time (5 / 15 / 25 / 35 / 60 min) and the bot has
  collected enough Madstone;
- like a player, the bot picks from 3 random artifacts and 3 random enchantments of that tier.

To enable it, check **Enable Cheats** in the lobby, then during hero selection open the console and run:
```
sv_cheats 1; script_reload_code bots/FairNeutrals
```
Madstone per camp is approximated from creep kills, so timings are close to, not exactly, a player's.

### In-game commands

- Chat language of the bots: type `en`, `ru`, `zh` or `ja` in chat during hero selection,
  or `!sp ru` at any time.
- `!pos 2` — swap your role with the bot playing position 2. `!3pos 5` — move the 3rd bot to position 5.
- `!pick sniper` / `!ban zuus` during hero selection (not in Captains Mode).

---

## Development

Source layout, systems and rules are described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Some Lua files are generated from TypeScript in `typescript/bots/` — edit both (see `CLAUDE.md`).

---

## Credits and license

Smart Bots is based on **Open Hyper AI** by forest0xia
([GitHub](https://github.com/forest0xia/dota2bot-OpenHyperAI),
[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3246316298)), which itself builds on
Valve's default bots, New Beginner AI, Tinkering ABout (ryndrb), Ranked Matchmaking AI (adamqqq),
FretBots (fretmute), BOT Experiment (Furiospuppy) and ExtremePush (insraq).
The original README is kept in [docs/UPSTREAM_README.md](docs/UPSTREAM_README.md).

Released under the [MIT License](LICENSE).
