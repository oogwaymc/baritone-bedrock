# Baritone for Bedrock (DLL)

A Baritone-style bot for **Minecraft: Bedrock Edition on Windows**, built as a single injectable DLL (`Baritone.dll`) for **26.50 / 26.52**.

```
#goto 100 64 -200     #mine diamond_ore 16     #follow Steve
#build house          #farm                    #elytra 5000 2000      #stop
```

It's built on [Latite Client](https://github.com/LatiteClient/Latite) (26.50 branch), which supplies the game hooks for this version, so the DLL also includes Latite's menu and mods. The bot is the **Baritone** module inside it.

## How it works

- **Movement** goes through the game's own input state (the same fields the keyboard writes: forward/back/left/right, jump, sneak, sprint), so it moves like a real player.
- **Looking** writes the player's rotation, turned smoothly at `rotationSpeed`. If a game version ignores that, it switches automatically to the game's mouse-look path and calibrates it.
- **Breaking, placing and using items** are real mouse clicks. **Hotbar switching** uses real number-key presses. Both are only sent while Minecraft is focused and no menu is open.
- **World, player, inventory and entities** are read directly from the game, so `#follow` knows exactly where people are and the hotbar is always known.
- **Path, goal, mining targets and schematic ghost blocks** are drawn as 3D lines with the game's own renderer.
- **`#` commands** are caught by the chat hook and never sent to the server.

The bot logic (A* pathfinder, mining, building, farming, elytra, settings) is Lua running in an embedded Lua 5.4 interpreter (`baritone/lua/parts`). It's tested in an offline simulator (`baritone/test`, 34 end-to-end tests).

## Install

1. Download `Baritone.dll` from the [latest release](https://github.com/oogwaymc/baritone-bedrock/releases/tag/latest).
2. Start Minecraft (26.50 / 26.52).
3. Inject `Baritone.dll` with any DLL injector, for example the one in [Latite's launcher](https://github.com/LatiteClient/Launcher) ("custom DLL"), Fate/Jiayi launcher, or Process Hacker.
   **Don't inject the official Latite at the same time.** This DLL is Latite plus the bot.
4. In a world, type `#help`.

The Baritone module is on by default. Press **M** to open the menu, where you can move its status text, change the stop key or turn path rendering off. Latite's own eject key is **End**.

**Stop the bot:** `#stop`, or the module's **stop key (X by default)**. Opening chat or a menu, or alt-tabbing, releases every key immediately.

## Commands

| Command | |
|---|---|
| `#goto x y z` · `#goto x z` · `#goto y` · `#goto <block>` | path there (`~` relative coordinates work) |
| `#goal …` then `#path` · `#thisway 500` | |
| `#mine diamond_ore 16` | find and mine. `x_ore` includes `deepslate_x_ore`. If none are nearby it goes to a good Y level and tunnels |
| `#follow <name>` · `#follow players` · `#follow entity zombie` | |
| `#farm [range] [now]` | harvest + replant |
| `#build <file> [x y z]` · `#lm …` | schematics, see below |
| `#elytra x z` | fly with an elytra + fireworks, auto-land |
| `#tunnel [length]` | 1x2 tunnel straight ahead |
| `#wp save/goto/list/delete <name>` · `#sethome` · `#home` | waypoints |
| `#stop` · `#pause` · `#resume` · `#status` · `#hotbar` | |
| `#set <name> <value>` · `#set reset` · `#settings [page/search]` · `#modified` | settings (saved automatically) |
| `#reload` | restart the bot script (picks up a `Baritone.lua` override) |

### Litematica-style schematics

Put `.litematic`, `.mcstructure`, `.schem` (Sponge v2/v3) or Java structure `.nbt` files in **`%LOCALAPPDATA%\Latite\Baritone\schematics\`**.

```
#lm list · #lm load house [x y z] · #lm here · #lm origin x y z · #lm move dx dy dz
#lm rotate 90 · #lm mirror x|z|none · #lm layer 3 | all · #lm materials · #lm verify
#lm render · #lm build (or #build house)
```

Ghost blocks: blue = missing, red = wrong. The builder places from your hotbar and pauses with a list when something's missing.

## Files

`%LOCALAPPDATA%\Latite\Baritone\`: `settings.txt`, `waypoints.txt`, `farm_*.txt`, `schematics\`.
Drop a `Baritone.lua` there to override the built-in bot script (then `#reload`). That lets you update the bot without rebuilding the DLL.

## Limits

- Hotbar only: the bot doesn't open your inventory.
- Crop growth isn't readable, so crops count as grown after `farmGrowMinutes` (or use `#farm now`).
- Block orientation (stairs, logs) isn't controlled when building.
- No parkour, ladder climbing or auto-eat.
- Automation breaks most servers' rules and anti-cheat can ban you. Use it in your own worlds.

## Building

GitHub Actions builds `Baritone.dll` on every push to `main` and attaches it to the `latest` release (`.github/workflows/build.yml`, MSVC + CMake + Ninja).
Locally you need Visual Studio 2022/2026 with "Desktop development with C++", CMake and Ninja:

```
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl
cmake --build build
```

After editing the Lua: `cd baritone && sh build.sh && cd .. && python tools/baritone/embed_script.py`.
Tests: `lua5.4 baritone/test/run_tests.lua` (helper mode) or with `NATIVE=1` (DLL mode), run from `baritone/`.

The module lives in `src/client/feature/module/modules/game/baritone/`.

## Licence

GPL-3.0, same as Latite Client (see `LICENSE` and `README-Latite.md`). Lua is MIT-licensed (`deps/lua/LICENSE.txt`).
