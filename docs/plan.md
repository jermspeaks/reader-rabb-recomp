# Reader Rabbit Preschool: plan

## Goal

Port Reader Rabbit Preschool to macOS. First, build an evidence-backed map of how the original game works: its runtime, data formats, scenes and activity rules. Then use that map to choose and build a macOS implementation that reads the user's own copy of the game data.

Detailed format findings are in [`formats.md`](formats.md). Game-logic findings are in [`game-logic.md`](game-logic.md).

## Current status

The native Swift/AppKit app is playable through the full scene set: intro/title, carousel, player sign-in, main menu, all four activities, exteriors, bonus areas, parent options, and the finale. The last handoff reports that scripted headless sessions checked the scene flow, each activity's level-up path, a correct and incorrect ABC Diner answer, and the 16-key finale. It also reports that the built app launched and quit cleanly. These are prior-session checks, not a fresh validation in every workspace.

The port is not feature-complete or fully verified against the original. In particular, audio has not been confirmed by listening, Crazy Costumes pointer dragging still needs real-window confirmation, and some scenes/features remain approximations. The player picker and roster are port-owned compatibility features; the original sign-in layout and behavior remain unmapped. The remaining implementation and investigation tasks are listed below; `docs/game-logic.md` distinguishes original-game questions from port gaps.

## Task checklist

Status: `[x]` done · `[~]` partly done · `[ ]` not started. Each finished task points to the doc section that holds its evidence.

### Stage 1: Identity and boundaries

- [x] Inventory the disc and record SHA-256 hashes for the game executables and data files (formats.md §1).
- [x] Separate the game (`RRPW32.EXE` and `RRPDATA/*.DAT`) from the installer, autorun previews, registration, AOL and parental-control utilities (formats.md §1).
- [x] Correct the earlier assumption: the `.MPS`/`.RSC`/`.GRP`/`.SMK` files belong to the previews player for other titles, not to this game (formats.md §1).
- [x] Remove the superseded `scan_graphic_signatures.py`.

### Stage 2: Data formats

- [x] DAT container: NE resource-only modules, looked up by (FourCC, ID) (formats.md §2).
- [x] `WAVE` audio in SPEECH, SOUNDS and MUSIC: plain PCM WAV (formats.md §2.2).
- [x] `ASEQ` frame bitmaps (RLE) (formats.md §3).
- [x] `RRGB` palettes (formats.md §4).
- [x] `ASEQ` step scripts: x/y offset, frame, and control codes; one step per 116 ms tick (formats.md §3). A few constant fields remain unexplained.
- [x] `LIPS`: mouth-frame tracks paired with the WAVE of the same ID (formats.md §5).
- [x] `COMB`: scene layouts of actors, hotspots and speech cues (formats.md §6).
- [x] `NFNT` bitmap fonts and `TEXT` layout directives (formats.md §7–8).

### Stage 3: Game logic in `RRPW32.EXE`

- [x] Startup, main loop, tick timing, and the graphics back ends (game-logic.md §1.1).
- [x] Scene system and full scene flow (game-logic.md §1.2, §2).
- [x] Actors, drawing and hit testing (game-logic.md §1.3).
- [x] Audio mixer, music and lip sync (game-logic.md §1.4).
- [x] Per-activity map: all four activities were re-derived in depth while porting them (game-logic.md §4, §8).
- [x] Progress, keys, levels, the parent menu, and the `RRP.INI`/`RRP.DAT` save formats (game-logic.md §1.6, §3). A few record fields are still unknown.

- [~] Scenes outside the four activities are implemented in the port: intro, title, story carousel, player sign-in, finale, credits, four bonus areas, and parent menu. The player sign-in scene is a new port-owned roster picker; original scene 30200 remains unmapped, so visual and behavioral parity is unknown.
- [x] `RRPW16.EXE` needs no analysis. The 32-bit build covers the whole game, and the port only uses its tables.

### Stage 4: End-to-end trace

- [x] ABC Diner traced end to end, from the main-menu click to the return to the menu (game-logic.md §5).
- [ ] Listen to the key speech clips (for example the SOUNDS 6800–6851 letter clips) to confirm what each one says; no transcripts exist.

### Stage 5: Runtime evidence (only if needed)

- [ ] Decide whether any behaviour can't be settled statically. If so, run a disposable copy in an isolated Windows VM with networking disabled, taking a snapshot before running anything.

### Stage 6: Port

- [x] Architecture: a native Swift/AppKit app (`app/`) that reads the user's own DAT files and `RRPW32.EXE` tables at runtime. No game data is bundled or committed. See game-logic.md §7.
- [x] Engine: DAT/NE loader, ASEQ/RRGB/NFNT/COMB/LIPS/WAVE decoding, 640×480 indexed framebuffer, actor step scripts, 8 fps tick, two-channel audio with lip sync, scene switching, saved progress.
- [x] Main menu and the four activity exteriors, driven by their COMB layouts (actors, hotspots, speech cues, host introductions, keys and carousel).
- [x] ABC Diner playable: orders, cupboards, serving, right/wrong feedback, ticket, recap, progress meter, key and level-up.
- [x] Counting Club (all four levels, dancer and finale shows).
- [x] Shape Shack (levels 0–1 hand-over sorting, levels 2–3 free grouping; runs at 60 fps like the original).
- [x] Pattern Parade (levels 0–3, band march and celebration shows).
- [x] Intro, title and story carousel; finale and credits (keyhole with 16 keys); parent menu (Ctrl+P / ⌘P: LEVELS, info pages, case and sound); the four bonus areas.
- [x] Build-time user asset packaging: `./scripts/build-app.sh --game DIR` checks for and embeds the four runtime DAT/DLL files and `RRPW32.EXE` (read only for its data tables) in the local app, which uses those embedded files by default. `dist/` stays git-ignored; the generated app contains copyrighted game-derived content and must remain personal, not committed or distributed. Users are responsible for their rights to make and use the build; see README and RIGHTS_AND_LICENSES.md.
- [~] Multiple-player sign-in: the port has a player picker, add-player prompt, and per-player progress roster with legacy single-player save migration. The UI is an inferred replacement; original scene 30200 remains unmapped and real-window interaction needs validation.
- [ ] Scene transition pictures (ASEQ 30510+) and the dissolve effect.
- [~] Engine/input: mouse-move and mouse-up now support direct dragging in Shape Shack and Crazy Costumes; click-to-pick-up/click-to-drop and keyboard alternatives remain. Real-window feel still needs testing.
- [x] Store gallery picture variants and the stage picture index in each `PlayerProfile`; migrate the prior gallery `UserDefaults` value and load legacy single-player JSON.
- [~] ABC Diner polish: food flight, chef gesture commands, customer reactions, and halfway/reward ASEQ sequences are wired. Show positioning and timing are approximations pending visual comparison; see game-logic.md §8.
- [ ] App/release polish: app icon and signed/notarized distribution build. The app already prompts for a game folder on first launch and provides **Game → Choose Game Folder…**.

## Suggested next steps

1. Re-test direct dragging in Shape Shack and Crazy Costumes in the real app, especially Crazy Costumes' release-on-target behavior; refine pointer feel if needed.
2. Implement the remaining scene transition pictures/effects and visually validate the persisted gallery/stage selections.
3. Compare ABC Diner's gestures, food movement, halfway bonus, and reward sequence against the supplied game assets; refine the current approximations.
4. Validate multi-player creation, switching, legacy-save migration, and profile isolation in the real app. Map original scene 30200 only if original parity is required.
5. Listen to the identified speech clips and record what they say. The port's audio and lip sync also need a real listening check.
6. Add release polish (icon and signing/notarization) if distribution is intended.
7. For a self-contained local build, run `./scripts/build-app.sh --game DIR` with a legally obtained game folder; keep the resulting app personal and out of source control and public releases.

These are priorities, not a dependency order. Keep original-game observations, port behavior, and inferred compatibility choices separately labelled.

## Validation notes

- The previous session reports running scripted snapshots for the full ABC Diner order (including one correct and one incorrect answer), eight perfect orders, activity level-ups, key rewards, and the finale after granting all 16 keys. It also reports a final scene-load pass after the merges.
- Shape Shack's eight-round level-up was covered by the worker's test; the merge handoff reports separately checking a round and the toy hand-over behavior.
- Audio was not heard and Crazy Costumes mouse feel in the real window was not tested. Headless sessions are silent and cannot validate either. The current workspace has no `game/` data, so Diner asset positioning, costume pointer drag/drop, and the sign-in screen with game artwork could not be exercised here.
- Snapshot mode disables `PlayerProfile` persistence and starts with a fresh profile. Earlier, pre-fix test runs reportedly altered the user's save; the previous handoff warned it contained test progression. Do not delete or reset user data automatically.
- `swift build --package-path app` and `git diff --check` passed after the current implementation. No gameplay snapshot or real-window interaction was run because the local `game/` directory is empty.
- No original executable or installer has been run. Any original-game runtime investigation remains gated by the isolated-VM procedure below.

## Working rules

- Static analysis only, unless Stage 5 is explicitly agreed. Never run the original game, installers or registration utilities on the host. (Our own macOS app is fine to run.)
- Leave `game/` untouched. It is git-ignored. Derived material (the Ghidra project, pseudocode, renders and REA snapshots) goes in the git-ignored `analysis/` directory. Commit only original notes, tools and implementation code.
- For every claim, record its evidence (function address, resource ID, or tool output) and label it **Observed**, **Validated** or **Inferred**. Keep unknowns explicit.
- Pseudocode is analysis output, not original source. Re-implement behaviour rather than copying decompiled code verbatim.
- The repository's original code is GPL-3.0-only (`LICENSE`). That license does not cover the original game or other third-party material. Keep all game-derived assets and locally generated bundles containing them out of the repository and public releases; see [`RIGHTS_AND_LICENSES.md`](../RIGHTS_AND_LICENSES.md).

## Tooling

- A previous analysis session used macOS ARM64, REA 6.4.0, Ghidra 12.1.4 and Temurin JDK 21.0.12.1 from machine-local paths. These are not project dependencies; verify current availability and paths before relying on them.
- Full decompile export (writes to `analysis/`):

  ```sh
  JAVA_HOME=~/.local/opt/rea/jdk-21.0.12.1+1/Contents/Home \
  ~/.local/opt/rea/ghidra_12.1.4_PUBLIC/support/analyzeHeadless analysis/ghidra_proj RRPW32 \
    -import game/RRPW32.EXE -scriptPath tools/ghidra \
    -postScript ExportDecomp.java "$PWD/analysis/RRPW32.decomp.c" -overwrite
  ```

- A previous session reported a `reverse-engineer-anything` v40 / REA 6.4.0 expected-v37 mismatch. Recheck both versions before setup; avoid broad setup if it would replace a newer installed skill.
- The Zed settings were backed up to `~/.config/zed/settings.json.rea.backup` before the `rea` MCP server was added.
