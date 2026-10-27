# Changelog

All notable changes to Baritone Bedrock. Versions follow [semantic versioning](https://semver.org/).

## 1.2.0

Supports Minecraft Bedrock 26.52 (package 1.26.5203.0), like 1.1.0.

### Added

- **Chest sorting.** Chests, barrels and shulker boxes sort themselves when you open them: partial stacks are merged, then items are grouped (blocks, then tools/weapons/armor, then other items, by name). `#sort` opens and sorts the one you look at, `#sort on|off` (setting `chestSortOnOpen`) turns the automatic sorting on or off. The container is found inside the chest's block actor by matching its vtable with the player's inventory, and items are moved with server-checked ItemStackRequests; anything unexpected stops the sort with a message.

### Changed

- All chat messages, command descriptions and errors are in English.

### Fixed

- **Builder:** between layers the bot could stand still until the player jumped. For blocks that must face a direction (stairs, chests, furnaces...), the spots to stand on included one where the block is at head height with air above it, which the builder never places from: the bot was "in the goal", so no path was made, and nothing was placed. Those spots now follow the same rule as the other blocks, and if the bot ever stands in its goal for 2 seconds without placing or breaking anything, it gives that spot up and moves (usually one block up).

## 1.1.0

Supports Minecraft Bedrock 26.52 (package 1.26.5203.0), like 1.0.0.

### Added

- **Diagonal parkour.** The bot can now jump over a gap along a diagonal: 2 blocks diagonally, 3 when it can sprint, landing at the same height. Before, two blocks that only met diagonally across a gap had no path at all, because Baritone only jumps along the four axes. It never jumps over lava, needs head room and clear corner cells (the body sweeps through them), and follows `allowParkour`.
- **Thick render lines.** `pathRenderLineWidthPixels`, `goalRenderLineWidthPixels` and `selectionLineWidth` are now applied: lines wider than one pixel are drawn as two crossed ribbons, so the path, the goal and the selections are easy to see in game.
- `#quiet [on|off]` developer command: hides the bot's chat messages (they still go to `log.txt`), handy for screenshots and videos.

### Fixed

- **Builder:** when a path has to place a block where the schematic wants one (for example bridging over a gap that is part of the build), the bot now uses the schematic's block, like Baritone's `placeAt`. Before, it only looked for throwaway blocks and could get stuck.
- **Builder:** when the path to the blocks to place keeps failing, the bot now says so once in the chat, with the usual cause: no throwaway blocks to pillar or bridge with. Before, it retried silently forever.

### Changed

- `#proc` shows when a path calculation is in progress.
- With `chatDebug`, each path calculation reports its result (success, segment, failure and why) and the builder lists the goals it is working towards.

### Known issues

- A build whose lowest blocks float above the ground can stay without any goal to walk to before it is finished.
- During some elytra flights the automatic firework clicks are not detected, and the bot asks the player to fire the rockets.
- Thick lines have a width in blocks, so a path segment passing right next to the camera looks very wide.
- When the player's game mode is Bedrock's "Default" (the world's default mode), creative mode is not detected; use `/gamemode creative` explicitly.

## 1.0.0

First release: Baritone ported to Minecraft Bedrock 26.52 for Windows as an injected DLL.

- Pathfinding with Baritone's A*, cost model and movements (walk, sprint, ascend, descend, fall, diagonal, pillar, parkour, ladders, swimming), long trips in segments, long-distance chunk cache.
- Processes: `#goto`, `#mine`, `#follow`, `#explore`, `#farm`, `#build` (`.mcstructure`, `.schem`, `.litematic`, `.schematic`), `#sel`, `#tunnel`, `#elytra`, waypoints, backfill.
- Water bucket falls, elytra flight with automatic fireworks and safe landing, inventory management.
- All of Baritone's commands and settings, rendering of the path, goals and selections, Windows notifications.
- See [docs/PARITY.md](docs/PARITY.md) for the differences with Baritone Java.
