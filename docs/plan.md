# Reader Rabbit Preschool: plan

## Goal

Port Reader Rabbit Preschool to macOS. First, build an evidence-backed map of how the original game works: its runtime, data formats, scenes and activity rules. Then use that map to choose and build a macOS implementation that reads the user's own copy of the game data.

Detailed format findings are in [`formats.md`](formats.md). Game-logic findings are in [`game-logic.md`](game-logic.md).

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
- [~] Per-activity map: all four activities' handlers, scenes and ID ranges are mapped (game-logic.md §2–4). Counting Club, Shape Shack and Pattern Parade rules come from a single pass and need the same depth of checking ABC Diner got.
- [x] Progress, keys, levels, the parent menu, and the `RRP.INI`/`RRP.DAT` save formats (game-logic.md §1.6, §3). A few record fields are still unknown.

- [ ] Map the remaining scenes: the bonus areas (gallery, waterfall, stage, Crazy Costumes), sign-in, intro and finale.
- [ ] Decide whether `RRPW16.EXE` needs any analysis. It may not, since the 32-bit build covers the same game.

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
- [ ] Counting Club.
- [ ] Shape Shack.
- [ ] Pattern Parade.
- [ ] Remaining scenes: intro and title, sign-in (multiple players), parent menu (LEVELS and info pages), bonus areas, finale and credits, scene transition pictures and effects.
- [ ] ABC Diner polish: chef/customer gesture animations, food flying to the bowl, the halfway bonus show and the reward show.
- [ ] App polish: icon, a "choose your game folder" first-run screen, and a signed/notarized build for sharing.

## Working rules

- Static analysis only, unless Stage 5 is explicitly agreed. Never run the original game, installers or registration utilities on the host. (Our own macOS app is fine to run.)
- Leave `game/` untouched. It is git-ignored. Derived material (the Ghidra project, pseudocode, renders and REA snapshots) goes in the git-ignored `analysis/` directory. Commit only original notes, tools and implementation code.
- For every claim, record its evidence (function address, resource ID, or tool output) and label it **Observed**, **Validated** or **Inferred**. Keep unknowns explicit.
- Pseudocode is analysis output, not original source. Re-implement behaviour rather than copying decompiled code verbatim.

## Tooling

- Host: macOS ARM64. REA 6.4.0 MCP runs through `npx`, using the npm cache at `~/.cache/rea-npm-cache`. Ghidra 12.1.4, Temurin JDK 21.0.12.1 and a locally built ARM64 native decompiler are installed under `~/.local/opt/rea/`.
- Full decompile export (writes to `analysis/`):

  ```sh
  JAVA_HOME=~/.local/opt/rea/jdk-21.0.12.1+1/Contents/Home \
  ~/.local/opt/rea/ghidra_12.1.4_PUBLIC/support/analyzeHeadless analysis/ghidra_proj RRPW32 \
    -import game/RRPW32.EXE -scriptPath tools/ghidra \
    -postScript ExportDecomp.java "$PWD/analysis/RRPW32.decomp.c" -overwrite
  ```

- The installed `reverse-engineer-anything` skill is v40, but REA 6.4.0 expects v37. Don't run the broad REA setup, because it would replace the newer skill.
- The Zed settings were backed up to `~/.config/zed/settings.json.rea.backup` before the `rea` MCP server was added.
