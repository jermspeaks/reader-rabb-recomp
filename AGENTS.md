# Agent guide

## Start here

- Check `git status` first; branches, staged changes, and local files can differ between sessions. Do not rely on a commit hash from an earlier handoff.
- Read [`README.md`](README.md) for the app workflow and repository boundaries.
- Read [`docs/plan.md`](docs/plan.md) for current status, remaining work, validation notes, and reverse-engineering constraints.
- Read [`docs/formats.md`](docs/formats.md) for file-format findings and [`docs/game-logic.md`](docs/game-logic.md) for original behavior and the port's mappings.
- The app is under `app/Sources/ReaderRabbit/`: `Data/` decodes user-provided resources, `Engine/` contains runtime systems, `Scenes/` contains game scenes, and `App/` contains the AppKit shell and snapshot driver.

## Build and exercise the app

- Build the Swift package: `swift build --package-path app`.
- Build the app bundle: `./scripts/build-app.sh`. This writes `dist/Reader Rabbit's Preschool.app` (ignored by Git).
- Run from source with a local game copy: `swift run --package-path app ReaderRabbit --game game`.
- Scripted headless checks require a valid local game folder and write PNGs into an output directory; keep outputs under ignored `analysis/`. For example:

  ```sh
  app/.build/debug/ReaderRabbit --snapshot --game game --out analysis/snap \
    "start game 1" "t 30" "solve" "shot diner"
  ```

- Snapshot commands include `t N`, `click X Y`, `key NAME`, `shot NAME`, `level A L`, `keys all|none`, and `start menu|intro|finale|parent|ext N|game N|bonus N`. ABC Diner also accepts `solve` and `miss`. Activity indices use the app's menu order. Inspect `app/Sources/ReaderRabbit/App/Snapshot.swift` for exact command behavior before scripting more complex flows.
- Snapshot mode disables save persistence and starts with a fresh in-memory profile. Do not remove or reset `~/Library/Application Support/ReaderRabbitPreschool/player.json` unless the user explicitly requests it.

## Safety and repository boundaries

- The original game is bring-your-own. Do not commit game files, extracted proprietary assets, local Ghidra projects, screenshots/renders from copyrighted assets, or other generated material derived from the game. `game/` and `analysis/` are intentionally ignored.
- Do not modify the user's files under `game/`. Do not run the original Windows executable, installer, or registration utilities on the host. Original-game runtime testing is permitted only through the isolated, disposable Windows VM process described in `docs/plan.md` and after that work is explicitly agreed.
- The macOS port may be built and run for development. Avoid changing real save data during tests; headless snapshot mode is the safe path for scripted checks.
- A prior session reported test progression in `~/Library/Application Support/ReaderRabbitPreschool/player.json`; this was not rechecked in the current handoff. Never reset or delete it automatically; only use **Game → Reset Progress…** if the user wants a fresh profile.
- Keep implementation behavior, observations from the original, and inferred compatibility decisions clearly distinguished in code/docs. Add original code addresses/resource IDs or test commands where useful; preserve unresolved questions rather than presenting guesses as fact.

## Change and validation practices

- Keep changes focused and follow the existing Swift style and architecture; prefer existing dependencies and patterns.
- When changing a scene, preserve its scene-specific behavior and check any `DebugDrivable` hooks used by snapshots. Update `docs/plan.md` when task status changes and the relevant format/game-logic notes when findings change.
- Run the narrowest relevant validation first, then `swift build --package-path app` when Swift sources changed. Use scripted snapshots only when a local game copy is available and the scenario is safe. Report checks that were not run rather than implying they passed.
- Before staging changes, check that proprietary or generated files are not tracked. Do not commit unless asked.
