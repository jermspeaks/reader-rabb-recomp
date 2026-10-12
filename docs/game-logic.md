# Reader Rabbit Preschool game logic

Static analysis of `RRPW32.EXE` (2026-10-12). No game binary was run. Function addresses refer to the Ghidra 12.1.4 export, and each claim is tagged **Observed** (read from code or data) or **Inferred**. For data formats, see [formats.md](formats.md). The full working notes are kept locally in `analysis/notes_engine.md` and `analysis/notes_activities.md`.

Gameplay rules for Counting Club, Shape Shack and Pattern Parade were mapped in one pass, and only their entry points and scene IDs were cross-checked. ABC Diner was traced in depth, and its key steps were re-checked against the code.

## 1. Engine core

### 1.1 Main loop and timing (Observed)

- **Window:** `WinMain` (`0x4170db`) enforces a single instance and creates a full-desktop `WS_POPUP` window. The 640×480 game area is centred at offset `DAT_004471bc/be`.
- **Loop:** `while (DAT_00447196 != -1) { FUN_00433a00 /* wait + input */; FUN_00433aa3 /* tick */ }`. The app state `DAT_00447196` is 0 = running, 1 = quit requested, −1 = exit.
- **Clock:** `timeGetTime` (`FUN_004170ac`) is the only clock. Each tick busy-waits until a deadline, pumping messages and the audio mixer while it waits.
  - The default rate is 8 fps (`FUN_004339a4(8)`), giving a 116 ms tick.
  - Some scenes switch to 60 fps (15 ms).
  - One ASEQ step or LIPS record is consumed per tick.
- **Graphics:** `FUN_0043807e` sets up the back end, trying WinG first, then a GDI bitmap, then a `GlobalAlloc` DIB. All three use one 640×960 8-bit buffer: rows 0–479 are the composited frame and rows 480–959 hold the clean background. `FUN_00438476` invalidates and updates the window, and WM_PAINT (`FUN_00417319`) blits the buffer to the screen.

### 1.2 Scenes (Observed)

A scene is a set of four handlers registered by `FUN_004336e7(key, mouse, exit, tick)`, which stores them in `DAT_004483c8/cc/bc/c4`.

To change scene, code writes three globals:

| Global | Holds |
|---|---|
| `DAT_004483c0` | The next scene's enter function |
| `DAT_004483e8` | The WAVE ID played at the cut |
| `DAT_004483ea` | The transition code |

Transition codes 0x14–0x1e show the "loading" pictures ASEQ 30510+n (`FUN_004335e7`). There are also dissolve (`0x435eb6`) and iris (`0x435f68`/`0x4361f8`) effects.

`FUN_00433763` is the dispatcher. Each tick it runs the first of these that applies:

1. The quit-dialog overlay (`FUN_0041d403`, opened with ESC).
2. The parent-menu overlay (`FUN_0041ce84`, opened with Ctrl+P).
3. A pending scene change: old exit handler, then transition, then sound, then the new enter function.
4. The current scene's tick handler.

### 1.3 Actors and drawing (Observed)

- **ASEQ cache:** `DAT_00449888` is a reference-counted ASEQ cache (up to 150 entries of 30 bytes), not the on-screen object list.
- **Actors:** on-screen sprites are actors in `DAT_004483f6` (100 slots × 44 bytes). Each holds a displayed state and a pending state (step, frame where −1 means hidden, and a rect), plus flags, the ASEQ pointer and x/y.
- **Drawing:** `FUN_00433eda` walks the back-to-front draw list `DAT_004496c0`. It restores changed areas from the background page, redraws any overlapping actors in painter's order, then presents the dirty rectangles.
- **Hit testing:** bounding box only, topmost actor first; no per-pixel test.

### 1.4 Audio (Observed)

- **Mixer:** a polled software mixer feeds a single waveOut stream (8-bit mono), opened once at the first WAV's sample rate.
- **Channel 0** streams speech and sound effects. `FUN_004351c2` plays a WAVE by ID and has 107 call sites.
- **Channel 1** holds memory-resident music, which scene code restarts to loop it.
- **Lip sync:** `LIPS` playback (`FUN_00434f25`/`FUN_00435051`) starts the matching WAVE and drives the talking actor's mouth frames.

### 1.5 Input (Observed)

- Any mouse button counts as a click (code 0x8000).
- Keys come from WM_CHAR, plus polling of the arrow keys and F1–F9.
- ESC opens the quit dialog, Ctrl+P the parent menu, and Ctrl+S toggles sound.
- The software cursor is ASEQ 22009; otherwise the cursor resource `0x3e9` is used.

### 1.6 Saved data (Observed)

- **`RRP.INI`:** holds `CDDrive`, `CheckDisplay` and `CheckSound`. It is read from the current directory, falling back to `%WINDIR%\..\TLCWIN\RRP\`. No registry access was found.
- **`RRP.DAT`:** a 2006-byte roster followed by up to 99 player records of 166 bytes each.
  - The roster header is version `0x0128`, count, and last-selected player. Each roster entry is a 16-character name, a state value and a record slot.
  - A player record holds:
    - sound on/off and the upper/lower-case setting;
    - per activity: a level (0–3), a progress counter (0–8), and a 128-bit "already asked" bitset;
    - `keys[4 activities][4 levels]` at `+0x68`;
    - a total key count at `+0x88` (16 = all keys, 17 = ending seen).
- **Index trap:** the save file orders activities Shape Shack 0, Counting Club 1, ABC Diner 2, Pattern Parade 3. That differs from the menu order (table at `0x441a96`).

## 2. Scene flow (Observed)

```
Intro 30500 → Title 30600 (music 2092) → story carousel 30110–30130
  → Sign-in 30200 (FUN_004329da; reads RRP.DAT)
  → Main menu 2000 (FUN_00419983, COMB 8810)
       ├─ hotspot −10/−12/−14/−16 or arrow key → FUN_00418f81 → activity exterior (FUN_0041f462)
       │     ├─ door → FUN_0041dad0(−1) → activity game (table below)
       │     ├─ signpost → bonus area (gallery 2100, waterfall 2900, stage 2300, Crazy Costumes 2500)
       │     └─ arrows → neighbouring activity's exterior
       ├─ ESC → back to sign-in
       └─ all 16 keys → finale 30410 → 30420 → 30430 → credits 31440 (music 30999) → main menu
```

| Menu index (`DAT_004471d6`) | Activity | Exterior BG (COMB) | Game: enter / key / mouse / exit / tick | Game BG | Transition | Host speech |
|---|---|---|---|---|---|---|
| 0 | Counting Club | 2400 (2498) | `0042c38c` / `0042b90c` / `0042b085` / `0042bfd2` / `0042965d` | 11000 | 0x14 | 23100–23315 |
| 1 | ABC Diner | 2200 (8321) | `00430888` / `00430544` / `0042fcd4` / `004307a4` / `0042db8e` | 32687 | 0x15 | 16100–16158 |
| 2 | Shape Shack | 3500 (21882) | `00424613` / `00423cee` / `00423891` / `004243e3` / `00421a6e` | 25000 | 0x16 | 24100–24289 |
| 3 | Pattern Parade | 2800 (18055) | `00427ea7` / `0042769e` / `004272a6` / `0042787d` / `00425908` | 24408 | 0x17 | 18100–18256 |

The dispatch from menu index to game entry and transition code is in `FUN_0041dad0`. The handler order in the table matches the arguments to `FUN_004336e7`.

## 3. Shared rules across activities (Observed)

- Each activity has four levels (0–3), and each level has a progress counter running from 0 to 8.
- A round only counts if the child made no mistakes. Each counted round plays a chime (SOUNDS 25001–25004).
- At progress 4, a short bonus show plays.
- At progress 8, the child earns that level's key and a reward animation plays. The level then rises (to a maximum of 3) and the game returns to the main menu with transition 0x18.
- The level-up functions are `FUN_00428000` (Counting Club), `FUN_0042c4a0` (ABC Diner), `FUN_0041f538` (Shape Shack) and `FUN_00424762` (Pattern Parade).
- 4 activities × 4 levels = 16 keys. Earning all 16 unlocks the keyhole finale (`FUN_004333d8`).
- **Parent menu** (Ctrl+P, `FUN_0041ce84`): shows the TEXT pages 1001/1002 and a LEVELS 4×4 grid (`FUN_0041bf78`, clicks handled by `FUN_0041b9a3`) where a parent can set each activity's level. The "Progress Report for" string has no reference in the 32-bit EXE.

## 4. Activities

### 4.1 Counting Club (single pass)

Animals hide in four tree hollows, and the child counts to a target number. Content comes from the table at `0x4442fc` (a target plus four counts per row).

| Level | Task |
|---|---|
| 0 | Pick the tree with the matching count |
| 1 | Move animals one at a time |
| 2 | Add groups together |
| 3 | Free counting |

### 4.2 Shape Shack (single pass)

The child sorts six items into two crate stacks. Depending on the round, items are sorted by picture, category, shape, colour, number of legs or sound. Content comes from the table at `0x4424c0` (68 rows).

### 4.3 Pattern Parade (single pass)

A marching band has gaps in its line-up, and the child fills them so a colour, animal or instrument pattern continues. Level 3 is free play. Content comes from the table at `0x442fd0` (100 rows of 13 shorts).

### 4.4 ABC Diner: data (Observed)

- **Item codes:** `code = letter × 2 + list`, with `@` = 1 for the junk item "P.U." and A = 2 … Z = 27. The name table at `0x444e14` is indexed by `letter + 27 × list` (`letter = code / 2`):
  - list 0 (entries 1–27) is P.U., Apple, Banana, Corn … Zucchini (Q has no food and is NULL);
  - list 1 (entries 28–54) is P.U., Aaah!, Bread, Carrot … Ziti.
  - ASEQ 8023 holds the 54 food pictures in this same order.
- **Gag items:** P.U., Aaah!, Eek!, I-yi-yi!, Ohhh! and Uh oh! (`0x44547c`) are never the right answer and play SOUNDS 8130–8139.
- **Order tables:** 120 seven-character strings at `0x444ef0`, arranged as 20 sets × 3 variants × 2 level bands. The first character is the target letter and the rest are the six shelf letters. Levels 0–1 use six different letters (for example `bABCMSW`); levels 2–3 use letter pairs (`bBBAAMM`).
- **Scripts:** `FUN_0042d5dd` runs scripted speech sequences. In each entry, a positive value above 4 is a WAVE, a negative value is a delay, 1–4 is a chef animation, and 0 ends the script.

## 5. ABC Diner end to end

1. **Main menu → exterior.** Clicking hotspot −12 (or pressing ↑) calls `FUN_00418f81(12)`. That moves to the ABC Diner exterior (BG 2200, COMB 8321) with transition 0x15 and SPEECH 21047.
2. **Exterior → game.** The COMB 8321 door (rect 278,220–351,330) runs `FUN_0041ee75` → `FUN_0041dad0(−1)`. Because the menu index is 1, this queues `FUN_00430888` with transition 0x15 and sound 0x524e (21070).
3. **Enter (`FUN_00430888`).**
   - Shuffles the 20 order sets.
   - Loads BG/palette 32687 and fonts NFNT 1014/1018.
   - Loads 23 sprites from the table at `0x444da0`: letter cards 8010/8012, foods 8023, shelf 8001/8002, plate 8321, progress meter 502, exit sign 212.
   - `FUN_0042c927` reads the saved level and picks a customer (0–21) and the letters.
   - `FUN_0042d057` places the sprites.
   - Registers the handlers `FUN_00430544` (key), `FUN_0042fcd4` (mouse), `FUN_004307a4` (exit) and `FUN_0042db8e` (tick).
4. **Tick (`FUN_0042db8e`).** A 64-state machine in `DAT_00448178` runs:
   - the intro script at `0x445128` (SPEECH 16122/16121…, or a shorter one at higher levels);
   - the customer's arrival (SOUNDS 11000 + customer offset);
   - the prompt, built in state 9. Level 0 names the exact food (SPEECH 16100 + SOUNDS 17496 + code); levels 1–3 name the letter (SPEECH 16101/16102 + SPEECH 12600 + letter).
5. **Input (`FUN_0042fcd4`).** Clicking a shelf food picks it up (`FUN_0042fb94`); level 0 also speaks a letter clip from SOUNDS 6796+. Clicking the plate while holding a food serves it (state 0x20). On the keyboard, Space cycles the items, Enter serves, and `1` repeats the prompt.
6. **Check (`FUN_0042d7db`).** The served code must equal the ordered code. At levels 2–3 the low bit is masked, so either food starting with the right letter counts.
   - Correct: SOUNDS 8110 (`0x1fae`), the food goes onto the plate, and play moves to the next item.
   - Wrong: SOUNDS 8116 (`0x1fb4`), a try-again line (SPEECH 16104/05/07/12/13), the ticket slot is marked as missed, and play moves on.
7. **Order complete (3 items).** A recap names the served foods (SOUNDS 17110 + code, then 17111, or 17113 for a perfect order). The customer reacts (ASEQ 85xx with SOUNDS 11001/11002 + customer offset). `FUN_0042c602`/`FUN_0042c4e9` advance progress only if there were no mistakes.
8. **Rewards.** Progress 4 plays a bonus show (ASEQ 8600–8606). Progress 8 plays the reward (ASEQ 8520/8521/8531 + level). State 0x3f then calls `FUN_0042c4a0` (key earned, level + 1) and returns to the main menu with transition 0x18 and speech from `0x4450d0` (21116…).
9. **Leaving.** The exit sign or ESC calls `FUN_0042fcaa`, which goes back to the exterior with MUSIC 32027–32032. The exit handler `FUN_004307a4` saves progress and frees resources.

## 6. Open questions

- **Speech content:** what the clips actually say; there are no transcripts. For example, are SOUNDS 6800–6851 alternating letter names (even) and letter sounds (odd)? Answering this needs listening, not more code analysis.
- **ABC Diner attempts:** whether each item really allows only one attempt, as step 6 suggests.
- **Three suspected original-game bugs** (useful for deciding whether a port reproduces them):
  - Counting Club's used-content bitmask mixes index scales.
  - Shape Shack's level-0 order list has 20 entries for 19 rows.
  - Pattern Parade's level-0 rows 36–43 look unreachable.
- **Unmapped scenes:** the bonus-area games, sign-in 30200, scene 30300 (`FUN_0041af24`, unreferenced), the intro and finale, and the uses of SPEECH 20000–20098 and 22000–22259.
- **Unknown fields:** a few player-record fields (`+0xc`, `+0x20`, `+0x8a`, `+0x92–0xa5`) and roster state −2.
- **Unextracted resources:** dialog resources inside the EXE (`0xbc7`, `0xbdb`, `0xbe0`, `0xbea`, `0x3a7`, 2000–2003).

## 7. How the macOS port maps onto this

The port in `app/` re-implements the engine described above. It doesn't emulate the Windows code.

| Original | Port |
|---|---|
| 640×960 offscreen buffer, dirty-rect compositor | `Framebuffer`: background page plus a full redraw each tick, converted to RGBA through the scene palette |
| Actor slots and step scripts (`FUN_004340de`, `FUN_00433d23`) | `Actor` (`advance()` mirrors Actor_Advance) |
| Shared COMB actor engine (`FUN_0041d5ea`, `FUN_0041df18`) | `LayoutScene` (idle, playing, looping, continuous and break-loop states; TRIGGER, IFSPEECH and cue handling) |
| Scene handler quad and `DAT_004483c0` | `Scene` protocol and `Game.change(to:sound:)` |
| Busy-wait tick at `1000/fps − 9` ms | `AppDelegate.pump()` against a deadline, using the same period formula |
| Software mixer, two channels | `AudioSystem` (AVAudioEngine; speech/SFX and music nodes) |
| LIPS polling | `LipSync`: one mouth value per tick, routed to the actor named in the LIPS header |
| `RRP.DAT` player records | `PlayerProfile` JSON, indexed in menu order (the save-file order trap doesn't apply) |
| Tables in `RRPW32.EXE` (food names, orders) | `ExeTables` reads them from the user's EXE at runtime |

## 8. Corrections found while porting

The porting passes re-derived each activity from the decompiled code. These findings correct or extend §3–4:

- **Shape Shack credits every finished round.** The "three or more misses means no credit" test at `0x41f6b8` sits behind an unconditional jump (`eb 0a` at `0x41f6b6`) and never runs; the miss counter `0x447dea` is written but never read. The level-0 order list really does lose its 20th entry (`FUN_0041f7d0`). Shape Shack runs at 60 fps (`FUN_004339a4(0x3c)`), and its logic acts every 7th tick.
- **Counting Club:** at level 0, wrong trees never open. The child confirms the count by clicking the host (or pressing Enter), not a tree. Level 3 accepts any total. The suspected used-content bitmask bug is real: two set bits in a group set all three. The port reproduces it.
- **Pattern Parade:** the group to choose from sits on the bench at the top, and the line is at the bottom. Level-1 type 0x400 alternates instruments (cymbals and drums), not animals. Rows 36–43 are unreachable, and the level-0 queue drops its 8th entry after the first round. On the exterior, the drum major's animation (layout ids 2840/2841) ends by marching into the game.
- **Shared rule (§3) needs this qualification:** "only mistake-free rounds count" holds for ABC Diner, Counting Club and Pattern Parade, but not for Shape Shack.

The detailed per-scene notes are in the scene sources (`app/Sources/ReaderRabbit/Scenes/`). Each function cites the original address it re-implements.
