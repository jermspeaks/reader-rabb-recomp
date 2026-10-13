# Reader Rabbit Preschool for macOS

This repository contains a native Swift/AppKit macOS port of Reader Rabbit Preschool, alongside static-analysis notes and read-only tools for understanding the original game. The playable port is complete across the intro, menu, four activities, bonus areas, parent menu, and finale; follow-up work and investigation gaps are tracked in the [plan](docs/plan.md).

> **Bring your own game copy.** This repository does not include Reader Rabbit Preschool or its proprietary game files. You must provide your own legally obtained copy of the game. The local `game/` directory is intentionally excluded from Git; do not commit the game, extracted proprietary assets, or other copyrighted payloads.

## Project status

A native macOS app (`app/`) runs the intro and title, main menu, all four activities, their exteriors and bonus areas, the parent menu, and the finale using the user's own game files. Format and original-game findings are documented in [`docs/formats.md`](docs/formats.md) and [`docs/game-logic.md`](docs/game-logic.md); remaining work and validation limits are tracked in [`docs/plan.md`](docs/plan.md). The original Windows executable has not been run.

The current workspace contains a locally supplied disc copy under `game/`, including Windows executables and the `RRPDATA/*.DAT` media files. The `.MPS`, `.RSC`, `.GRP` and Smacker files belong to the autorun previews player for other titles, not to this game. The directory is ignored by Git and is not part of the repository history. Treat those file-format observations as preliminary until verified with recorded analysis evidence.

## Running the macOS app

Requires macOS 13+ and Xcode (Swift 5.10 or later).

```sh
./scripts/build-app.sh --game ./game          # embeds your own game's runtime files in this local app
open "dist/Reader Rabbit's Preschool.app"
```

Without `--game`, choose the folder that contains `RRPDATA` on first launch; the choice is remembered. With `--game DIR`, the build checks for and embeds `GRAPHIC`, `SPEECH`, `SOUNDS`, and `MUSIC` DAT/DLL files plus `RRPW32.EXE` in the generated app. The EXE is read only as data for game tables; it is not run. **Game → Choose Game Folder…** can still switch to another copy. `--output-name NAME.app` selects a different output name, still inside git-ignored `dist/`. Generated apps containing game-derived content are for your personal use and must not be committed or distributed. Progress is saved to `~/Library/Application Support/ReaderRabbitPreschool/player.json`.

For development, `swift run --package-path app ReaderRabbit --game game` runs from source. A headless mode renders scripted sessions to PNG for checking (write output under `analysis/`):

```sh
app/.build/debug/ReaderRabbit --snapshot --game game --out analysis/snap \
  "t 3" "click 540 100" "t 3" "shot exterior" "start game 1" "t 30" "solve" "shot diner"
```

Current state: the complete scene set is playable, but several features are approximations or still need polish. Direct mouse dragging is implemented in Shape Shack and Crazy Costumes but still needs real-window testing. ABC Diner now includes food-flight, chef/customer reaction, halfway-show, and reward-show sequences; their timing and placement still need comparison against the supplied game assets. Other gaps include multiple-player sign-in, scene transitions, speech verification by listening, and release packaging. Shape Shack awards credit for every completed round, matching the original code; the other activities require mistake-free rounds. See the [plan](docs/plan.md) for tracked details.

## Repository layout

- `app/` — the macOS app (Swift package): `Data/` decoders, `Engine/` game loop, actors, audio and framebuffer, `Scenes/` menu, exteriors and activities, `App/` window and headless snapshot mode.
- `scripts/build-app.sh` — builds the `.app` bundle into `dist/` (git-ignored).
- `docs/plan.md` — implementation status, open tasks, validation notes, setup and safety constraints.
- `AGENTS.md` — repository navigation, coding workflow, data-safety rules and validation commands.
- `LICENSE` and [`RIGHTS_AND_LICENSES.md`](RIGHTS_AND_LICENSES.md) — the source license and the boundary between project code and game content.
- `docs/formats.md` — decoded data formats, loader functions and evidence ledger.
- `docs/game-logic.md` — engine, scene flow, activities and the ABC Diner trace.
- `tools/` — read-only parsers and validators (`ne_resources.py`, `aseq.py`, `lips.py`, `comb.py`, `nfnt.py`), a PNG renderer for local checks (`render_aseq.py`) and a Ghidra export script.
- `analysis/` — local Ghidra project, pseudocode and renders; git-ignored because it derives from proprietary files.
- `game/` — local user-supplied game files, excluded from version control.

## License and game rights

The independently authored source code and tools in this repository are licensed under the **GNU General Public License, version 3 only** (GPL-3.0-only); see [`LICENSE`](LICENSE). This license does not cover Reader Rabbit Preschool or grant rights to its code, data, artwork, audio, text, or other game-derived material. The project is independent and is not affiliated with or endorsed by the game's rights holders. See [`RIGHTS_AND_LICENSES.md`](RIGHTS_AND_LICENSES.md) for the boundary and handling guidance.

The app can read data from a game folder at runtime or be built locally with `./scripts/build-app.sh --game DIR` to embed the runtime files from that user-supplied copy. The generated app includes proprietary game-derived content and is not a distributable project artifact: keep it in ignored `dist/`, do not commit or publish it, and ensure your use complies with applicable law and the rights holder's terms. This project does not determine whether a particular user's copy or use is licensed.

## Contributing and handling game data

Only contribute original analysis notes, independently authored tools, and implementation code. Before staging or committing changes, verify that `game/`, extracted assets, and generated app/output directories are ignored and absent from `git ls-files`. Respect applicable copyright and license restrictions when handling or distributing any game content.
