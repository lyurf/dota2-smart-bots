# Smart Bots (HATS) — Dota 2 Bot Scripts

**Bots that win by playing smarter.** Smart Bots is a fork of
[Open Hyper AI](https://github.com/forest0xia/dota2bot-OpenHyperAI) focused on team strategy:
bots group up, push after won fights, stop over-farming and react like humans instead of instantly.

The goal is bots that play like smart Dota 2 players: no difficulty voting, no online requests.
Install, start a lobby and play.

> Bots installed correctly have names ending with **`.HATS`**.
>
> 🇷🇺 **Подробная инструкция по установке и запуску на русском: [docs/INSTALL_RU.md](docs/INSTALL_RU.md)**

---

## What's different from Open Hyper AI

- **Team pushing against humans.** Bot teams coordinate pushes, siege after a won fight, finish lanes
  after barracks fall and counter-push after a successful defense. In the original this only worked
  in all-bot games.
- **Smarter laning.** Every hero uses Smart Bots laning instead of Valve's built-in one: the bot stands
  ready next to an enemy creep that is about to die, denies, and supports leave last hits to their core
  (in the original, supports took the core's farm). Supports stand forward and trade hits with the
  enemy laners, everyone steps back when creeps pull aggro. `Smart_Laning = false` switches back.
- **Vision.** Supports actually buy observer wards (pos 5 every ward in stock, pos 4 one when 2+ are in stock).
- **Less over-farming.** Bots leave the jungle and push when 2 or fewer enemies are alive.
- **Human-like reaction time.** Configurable delay before casting spells and items when an enemy
  appears, and between casts (`Reaction_Delay` in `Customize/general.lua`).
- **Smarter drafting.** Fixed the inverted counter-pick math (bots used to pick heroes the enemy
  counters). In Captains Mode a bot captain bans and picks by role fit, counters and synergy
  instead of random heroes.
- **Hunting the enemy carry.** After the laning phase, when the enemy's most farmed hero is seen
  alone away from his towers, the 3–4 closest healthy bots go and kill him together. In lane,
  bots harass the enemy carry/mid first.
- **Bots help their human teammates.** When you start a fight or walk into the enemy half next to
  enemy heroes, allied support bots (up to 4500 away) and nearby bots come and hit your target.
  Ping the map (Alt + click) and supports come to the ping.
- **Cores farm.** The carry and mid keep farming between fights whatever `Push_Frequency` is set to;
  everyone farms less and takes objectives when the team is 2+ heroes up.
- **Smarter defaults.** Balanced push/farm (`Push_Frequency = 2`) and full thinking (`ThinkLess = 0`).
- **Console reports for testing.** Lane stats at 5 and 10 min, game stats with time spent per mode
  at 15–50 min, and a line for every bot death (mode, HP before, enemies and allies near).
- **One settings file.** All modes read settings through the same loader, so a single
  `vscripts/game/Customize/general.lua` overrides everything.
- **No bonus modes.** FretBots and Buff mode (bonus gold/XP/stats, voting) are removed, together with
  GPT chat and every network request. Bot chat is local.
- **Neutral items on time.** Optional script that gives every bot its neutral item when each tier
  unlocks, with a 3-of-each choice like a player, instead of FretBots' bonus packages.

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

### Server scripts (recommended)

Valve does not let bots craft neutral items. Smart Bots includes server scripts that, among other things,
give every bot a neutral item as soon as each tier unlocks (5 / 15 / 25 / 35 / 60 min, with a random delay
of up to 45 seconds). Like a player, the bot picks from 3 random artifacts and 3 random enchantments of
that tier. This is the setup the bots are tested and tuned with.

Check **Enable Cheats** in the lobby (it only allows the command), then during hero selection open the
console and run one command:
```
sv_cheats 1; script_reload_code bots/SmartBots
```
To start it with one key, add this line to `dota 2 beta\game\dota\cfg\autoexec.cfg` (create the file if
it does not exist) and press **F11** during hero selection:
```
bind "F11" "sv_cheats 1; script_reload_code bots/SmartBots"
```

To save the whole console to a file for bug reports, add `-condebug` to the Dota 2 launch options:
the log is written to `dota 2 beta\game\dota\console.log`.

### In-game commands

- Chat language of the bots: type `en`, `ru`, `zh` or `ja` in chat during hero selection,
  or `!sp ru` at any time.
- `!pos 2` — swap your role with the bot playing position 2. `!3pos 5` — move the 3rd bot to position 5.
- `!pick sniper` / `!ban zuus` during hero selection (not in Captains Mode).

---

## Development

Source layout, systems and rules are described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Some Lua files are generated from TypeScript in `typescript/bots/` — edit both (see Section 13 of the architecture doc).

---

## Credits and license

Smart Bots is based on **Open Hyper AI** by forest0xia
([GitHub](https://github.com/forest0xia/dota2bot-OpenHyperAI),
[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3246316298)), which itself builds on
Valve's default bots, New Beginner AI, Tinkering ABout (ryndrb), Ranked Matchmaking AI (adamqqq),
FretBots (fretmute), BOT Experiment (Furiospuppy) and ExtremePush (insraq).
The original README is kept in [docs/UPSTREAM_README.md](docs/UPSTREAM_README.md).

Released under the [MIT License](LICENSE).
