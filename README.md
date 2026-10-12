# Reader Rabbit Preschool for macOS

This project aims to reverse-engineer Reader Rabbit Preschool and ultimately port the game to macOS. The work is staged: first establish how the original program and its data work, then design and build a compatible macOS implementation. The investigation plan and evidence requirements are in the [reverse-engineering plan](docs/reverse-engineering-plan.md).

> **Bring your own game copy.** This repository does not include Reader Rabbit Preschool or its proprietary game files. You must provide your own legally obtained copy of the game. The local `game/` directory is intentionally excluded from Git; do not commit the game, extracted proprietary assets, or other copyrighted payloads.

## Project status

The first static-analysis pass is complete; see [`docs/formats.md`](docs/formats.md). The game's media containers, audio, sprite/animation images, and palettes are decoded. The next step is mapping the game's scene and activity logic in `RRPW32.EXE`. No original executable has been run, and port implementation has not started.

The current workspace contains a locally supplied disc copy under `game/`, including Windows executables and the `RRPDATA/*.DAT` media files. The `.MPS`, `.RSC`, `.GRP` and Smacker files belong to the autorun previews player for other titles, not to this game. The directory is ignored by Git and is not part of the repository history. Treat those file-format observations as preliminary until verified with recorded analysis evidence.

## Repository layout

- `docs/reverse-engineering-plan.md` — investigation stages, current setup, safety constraints, and next actions.
- `docs/formats.md` — decoded data formats, loader functions and evidence ledger.
- `tools/` — read-only parsers (`ne_resources.py`, `aseq.py`), a PNG renderer for local checks (`render_aseq.py`) and a Ghidra export script.
- `scan_graphic_signatures.py` — early signature scanner, superseded by `tools/`.
- `analysis/` — local Ghidra project, pseudocode and renders; git-ignored because it derives from proprietary files.
- `game/` — local user-supplied game files, excluded from version control.

## Current analysis setup

The active analysis setup is on macOS ARM64:

- REA MCP 6.4.0 is available in the Zed session.
- Ghidra 12.1.4, Temurin JDK 21, and its macOS ARM64 native decompiler are installed locally.
- REA reports its Ghidra provider as healthy. This is a static-analysis setup, not a configured Windows runtime.
- The installed global `reverse-engineer-anything` skill is v40, while this REA package reports expecting v37. Do not run broad REA setup that would replace the newer skill. See the plan for details.

These tool installations are machine-local and are not vendored in this repository. Recheck availability in the active agent session rather than assuming the same paths or tools on another machine.

## Handoff for the next agent

1. Read this README and [`docs/reverse-engineering-plan.md`](docs/reverse-engineering-plan.md) before changing files or analyzing binaries.
2. Confirm the active REA tool/provider status. Use the existing Ghidra route for static analysis; do not run the game or installers. The supplied Windows executable is not known to run natively on macOS.
3. Begin with a read-only inventory of the user's files in `game/`, recording file identity, size, detected format, hashes, coverage, and limitations as analysis Evidence. Keep Evidence-backed observations distinct from preliminary inventory guesses.
4. Focus first on `RRPW32.EXE`: establish its role and trace how it locates/loads scripts and resources. Follow the plan's staged approach before attempting extraction or implementation.
5. Preserve the game copy unchanged. Keep notes, analysis tooling, and independently authored implementation code outside `game/`; never commit game files or extracted copyrighted assets.
6. Keep the destination in view: a macOS port of the game. Do not choose a compatibility-layer, rewrite, or asset-pipeline architecture until the executable, data formats, and behavior have been investigated enough to support that decision.

## Contributing and handling game data

Only contribute original analysis notes, independently authored tools, and implementation code. Before staging or committing changes, verify that `game/` and any generated asset/output directories are ignored and absent from `git ls-files`. Respect applicable copyright and license restrictions when handling or distributing any game content.
