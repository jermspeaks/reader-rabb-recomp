# Reader Rabbit Preschool data formats

Findings from static analysis (2026-10-12). All seven resource types are now decoded. Every claim below is tagged:

- **Observed**: read directly from the shipped files or from Ghidra 12.1.4 decompilation of `RRPW32.EXE`.
- **Validated**: a parser built from the observed layout was run over every relevant resource without errors.
- **Inferred**: a reasonable reading that hasn't been confirmed in code yet.

Function addresses refer to `RRPW32.EXE` (SHA-256 `23d98405…62d6e7`, PE32 i386, image base `0x400000`, Borland C++ 1994 runtime). Pseudocode is analysis output, not original source.

## 1. What is (and isn't) the game

| Component | Role | Basis |
|---|---|---|
| `RRPW32.EXE` | Win32 game runtime | Observed: opens `RRPDATA\*.DAT`, contains activity names (Counting Club, ABC Diner, Shape Shack, Pattern Parade), uses WinG for blitting |
| `RRPW16.EXE` | Win16 build of the same game | Inferred from NE format and shared strings; not analyzed yet |
| `RRPDATA/{GRAPHIC,SPEECH,SOUNDS,MUSIC}.DAT` | All game media | Observed and validated (§2) |
| `WING.Z`, `TLC.Z` | Compressed WinG runtime / TLC libraries for the installer | Inferred from names; not analyzed |
| `INST_32/*.MPS`, `*.RSC`, `PREVIEWS.EXE`, `ASSETS/*.GRP`, `MOVIES/MV107A.SMK` | **Autorun "previews" demo player for other TLC titles** (Reader Rabbit 1/2, Labyrinth of Words, Oregon Trail 3) | Observed: `AUTORUN.MPS` buttons launch `rr1`/`lab`/`ot3` demos; the `.GRP`/`.SMK` names appear only in `LAB*.MPS`/`OT3.MPS`; neither game executable contains `.grp`, `.smk`, `movies`, or `smack` strings |
| `EREG/`, `AOL/`, `CPATROL/`, `MANUAL/` | Registration, AOL trial, parental control, Acrobat Reader and PDF manuals | `GENESIS.INI` launch table and file names |

**Port implication:** the `.MPS` scripting language is *not* this game's content model. The game's activity logic appears to be compiled into `RRPW32.EXE`, and its media lives entirely in the four DAT files.

## 2. `RRPDATA/*.DAT`: NE resource containers

Each DAT file is a valid Win16 NE module (an `MZ` stub plus an `NE` header) that contains only resources. (Observed.)

### 2.1 How the engine opens them (Observed)

- `FUN_00438745` iterates over the table `GRAPHIC`, `SPEECH`, `SOUNDS`, `MUSIC` (`0x445d60`). For each name it tries `<install dir>RRPDATA\NAME.DAT`, then `.DLL`, then the same two paths relative to the CD. It then calls the opener; if a file can't be opened it prompts with string resource `0xc1b` and retries.
- `FUN_0041606b` is the opener. It does **not** use `LoadLibrary`. It calls `CreateFileA`, reads the NE header, and loads the resource table into a `GlobalAlloc` block. For each resource type it reads that type's 4-byte tag from the name table (§2.2). Up to 15 files can be open; the handle is `slot | 0x80`.
- `FUN_004162ab(handle, id, &fourcc)` matches the type by FourCC tag, then binary-searches the resource IDs. `FUN_00416457` reads `length << align_shift` bytes from `offset << align_shift` in 10 KiB chunks.
- `FUN_0043895b(&fourcc, id, …)` searches all four open files in order. Resources are therefore addressed globally by **(FourCC, numeric ID)**, and the file a resource lives in doesn't matter to callers.
- `FUN_004352e7`/`FUN_004353ef` wrap that lookup in a reference-counted cache of up to 200 entries.

### 2.2 Resource types (Observed)

Each file has one `RT_NAMETABLE` resource (type 15). Its 12-byte entries are `u16 len, u16 type_id(0xFFxx), u16 res_id, "TAG\0", "\0"`, and they map custom type IDs to the FourCC tags.

| File | Type id | Tag | Count | Format |
|---|---|---|---|---|
| GRAPHIC | 0xFF01 | `ASEQ` | 1572 | Sprite/animation sequences (§3); validated |
| GRAPHIC | 0xFF02 | `COMB` | 6 | Scene layouts: actors, hotspots and speech cues (§6); validated |
| GRAPHIC | 0xFF03 | `LIPS` | 1437 | Lip-sync tracks keyed to the WAVE with the same ID (§5); validated |
| GRAPHIC | 0xFF04 | `NFNT` | 5 | Classic Macintosh `NFNT` bitmap fonts with a little-endian header (§7); validated |
| GRAPHIC | 0xFF05 | `RRGB` | 39 | 256-colour palettes (§4); validated |
| GRAPHIC | 0xFF06 | `TEXT` | 2 | Mac Roman parent-info pages with `&` layout directives (§8) |
| SPEECH / SOUNDS / MUSIC | 0xFF01 | `WAVE` | 1076 / 1084 / 79 | Complete RIFF WAVE files: PCM, mono, 8-bit, mostly 22050 Hz (21 SOUNDS entries use 22000, 22255, 11127, or 11000 Hz). Can be used as-is |

The Mac-style resource tags, the `NFNT` fonts, and the Mac Roman text all point to an engine that originated on the Macintosh. The `ASEQ` byte-swap path (§3) supports this. (Inferred.)

## 3. `ASEQ`: sprites and animations (Validated over 1572 resources / 11 815 frames)

The loader is `FUN_0043462a`, and the per-frame pass is `FUN_004379c3`. The generic step player is `FUN_00433c49`/`FUN_00433d23`. Everything is little-endian.

```
header      s16 seq_count (always 1), s16 frame_count, s16 version (8 or 30),
            s16 unk3 (always 15), s16 unk4 (always 1)
            version > 0xFE ⇒ big-endian data; the loader byte-swaps it (FUN_00434528/34551)
u32[frame_count]   frame offsets, relative to frame base
u32[seq_count]     pointer slots (filled at load time; no data on disk)
seq_count × { s16 n; n × step }
step        s16 x, s16 y, s16 frame, s16 tag
frame base:
  frame     s16 unk0 (always 4), s16 width, s16 height, then `height` RLE rows
row RLE (repeat until `width` pixels are produced):
  00 n      n transparent pixels
  FF c n    n pixels of palette index c
  k         (1–254) k literal palette indices follow
```

**Steps.** The engine advances one step per engine tick. A tick is 116 ms in the default 8 fps mode (`FUN_004339a4(8)` sets it to `1000/8 − 9` ms), and three activities switch to 60 fps. No per-step delay is stored, so holding a frame longer means repeating the step. If `frame ≥ 0`, that frame is drawn at actor origin + (x, y). `tag` is never read, and is identical for a given frame everywhere it appears (0 conflicts across 7687 uses); it is probably an authoring-tool artifact. Negative `frame` values are control codes:

| frame | Name | Meaning | Count |
|---|---|---|---|
| −1 | END | Last step of every script | 1572 |
| −2 | LOOP | Jump back to step 0, or to step 1 if step 0 is a REST marker | 1531 |
| −4 | REST | Idle point. A script that starts with REST leaves the actor idle until it is triggered | 1160 |
| −5 | BRANCH | Go to step x, or to step y in the alternate state. The player shifts the origin so walk cycles stay continuous | 23 |
| −7 | IFSPEECH | Go to step x if this actor's speech is still playing, otherwise to step y | 9 |
| −500 | TRIGGER | Start the actor whose ASEQ ID is y (`FUN_0041848b`/`FUN_0041de54`) | 36 |

Only sequence 0 is ever used. Negative ASEQ IDs would be looked up under the tag `AFRM` (`0x445bb1`), but no DAT contains `AFRM` and no caller passes a negative ID, so it is unused.

When a frame is loaded, `FUN_004379c3` remaps each colour byte through the 256-entry table `DAT_0044ad28`, which is built from the active palette and the Windows system colours (§4). A port can use the raw indices with the scene's `RRGB` palette.

640×480 single-frame `ASEQ`s are scene backgrounds, and their IDs match their palette IDs (for example, `ASEQ 2000` is the main-menu carousel and `ASEQ 2200` is the ABC Diner exterior). Rendered with their palettes, these backgrounds come out correct.

## 4. `RRGB`: palettes (Validated)

There are 256 entries of 6 bytes each, in the Macintosh `RGBColor` style (three 16-bit channels). The engine (`FUN_00437c07`) uses the first byte of each channel: `r = b[6i]`, `g = b[6i+2]`, `b = b[6i+4]`. Each resource occupies 1536 bytes, padded to 2048.

In 8-bit display mode, entries 10–245 are loaded into the system palette. Entries 0–9 and 246–255 are reserved for Windows system colours, and the remap table `DAT_0044ad28` handles any collisions. After loading, every palette except `0x7788` (30600, the title scene) has display slots 10–15 overwritten with the colours of entries {10, 246, 247, 251, 252, 253} (tables at `0x445c3e`/`0x445c44`). A port running in true colour can ignore all of this and use the palette directly.

## 5. `LIPS`: lip sync (Validated over 1437 resources)

```
record 0    s16 0x0101, s16 actor_aseq_id, s16 count
records 1..count    s16 mouth, u16 t_hi, u16 t_lo      (6 bytes each)
```

- **Loading:** `FUN_00434f25(id)` loads the `LIPS` and the **`WAVE` with the same ID**. Matching WAVEs: 1043 in SPEECH, 339 in SOUNDS, 5 in MUSIC; 50 tracks have none.
- **Playback:** `FUN_00435051` returns one `mouth` value per engine tick and starts the sound on the first record. The talking actor is drawn at ASEQ step `mouth + 1` (`FUN_0041103a`).
- **Timing check:** the median of WAV duration ÷ (count − 1) is 0.121 s, which matches the 116 ms tick.
- **Unread fields:** `t` and `actor_aseq_id` are never read. `t` is linear in the record index in 1431 tracks.

## 6. `COMB`: scene layouts (Validated over 6 resources)

```
header      s16 1, s16 scene_id, s16 count        scene_id = background ASEQ and RRGB palette ID
count × 12-byte record:  s16 id, s16 x1, s16 y1, s16 x2, s16 y2, s16 cue_off
cue table (at cue_off):  s16 n; n × { s16 sound_id, s16 step }
```

- **Actors:** `id > 0` means an actor using ASEQ `id`, placed at (x1, y1). (x2, y2) is its bounding box, which matches the first frame in 136 of 156 actors. A non-zero `cue_off` points to a cue table: when the actor reaches `step`, WAVE `sound_id` plays (123 cues in total).
- **Hotspots:** `id ≤ 0` means a plain rectangular hotspot; a negative x2 is negated on load. Scene code dispatches clicks by these negative IDs (for example, main menu −10/−12/−14/−16 for the four activities).
- **Users:** the main menu (8810, `FUN_00419983`) and the four activity exteriors (2498, 8321, 21882, 18055, all via `FUN_0041f462`), plus 24692 (scene 30300, apparently unreferenced). Activity games place their sprites from tables in the EXE instead (see [game-logic.md](game-logic.md)).

## 7. `NFNT`: bitmap fonts (Validated over 5 resources)

These are Mac `FontRec` resources with the header converted to little-endian (`fontType 0x9000`, firstChar 0, lastChar 255), followed by the strike bitmap and the location and offset/width tables. They have two data quirks:

- The last `locTable` entry was never byte-swapped.
- The `owTable` is still in Mac byte order: byte 0 is the offset, byte 1 the advance width.

The engine's missing-glyph test compares against `0x00ff` (asm at `0x4358cd`), but the data uses `ff ff`, so the fallback never fires. Fonts 1012, 1014, 1018 and 1036 are used; 2018 is never referenced by the 32-bit EXE.

## 8. `TEXT`: parent information pages

`FUN_0041ba75` parses these with `sscanf`. They are Mac Roman text with these directives:

| Directive | Meaning |
|---|---|
| `&0,a,b,c,d` | Section boundaries at pages 1, 1+b, +c, +d (`a` is unused) |
| `&N` | Start page N; a bare `&` ends the file |
| `&G,x,y` | Parsed but ignored. The page picture comes from a table at `0x441ec4` (its values equal the `&G` values plus (64, 48)) |
| `&T,x1,y1,x2,y2,skip,lineheight,align` | Word-wrap the following text to width x2−x1 at baseline + (64, 48), after `skip` blank lines. `c` centres the text, anything else aligns left; y2 is unused |
| `\|` | Toggle text colour between palette index 0xff and 6 |

## 9. Tools in this repository

All are read-only and use only the standard library. Run them with `python3 -I`.

- `tools/ne_resources.py FILE [--entries]`: lists an NE resource table.
- `tools/aseq.py GRAPHIC.DAT`: validates every `ASEQ`, including its step scripts.
- `tools/lips.py RRPDATA_DIR`: validates every `LIPS` and checks it against its matching `WAVE`.
- `tools/comb.py GRAPHIC.DAT [--dump]`: validates and dumps the scene layouts.
- `tools/nfnt.py GRAPHIC.DAT`: validates the fonts.
- `tools/render_aseq.py GRAPHIC.DAT OUT PALETTE_ID ASEQ_ID…`: renders frames to RGBA PNG for local checking. Write the output under the git-ignored `analysis/` directory, and never commit rendered output.
- `tools/ghidra/ExportDecomp.java`: a Ghidra headless post-script that exports all pseudocode to `analysis/` (see plan.md).

## 10. Evidence ledger

| Claim | Evidence | Confidence |
|---|---|---|
| The DATs are opened and parsed by the EXE itself | REA `procedure_callers` ev_1e60a99d… (CreateFileA ← `FUN_0041606b`), `batch_decompile` ev_f23860d6… | Observed |
| The DAT search order and file-name fallbacks | `FUN_00438745` pseudocode; bytes at `0x445d54–0x445d9f` | Observed |
| Lookup by FourCC tag plus ID | `FUN_004162ab`, `FUN_0043895b` pseudocode; name-table bytes | Observed |
| `ASEQ` layout and RLE | `FUN_0043462a`, `FUN_004379c3`; `tools/aseq.py` passes on all 1572 | Validated |
| `ASEQ` step semantics and the 116 ms tick | `FUN_00433c49`, `FUN_00433d23`, `FUN_004339a4`; step counts from `tools/aseq.py` | Observed (control codes), Validated (parse) |
| `RRGB` layout | `FUN_00437c07`; renders are visually correct | Validated |
| `LIPS` layout and WAVE pairing | `FUN_00434f25`, `FUN_00435051`, `FUN_0041103a`; `tools/lips.py` passes on all 1437 | Validated |
| `COMB` layout | `FUN_00419983`, `FUN_0041f462`; `tools/comb.py` passes on all 6 | Validated |
| `NFNT` layout | Mac FontRec; `tools/nfnt.py` passes on all 5; ASCII renders look correct | Validated |
| `TEXT` directives | `FUN_0041ba75` (sscanf arguments recovered from the asm) | Observed |
| Audio is plain WAV | RIFF/fmt headers checked on all 2239 SPEECH/SOUNDS/MUSIC entries | Validated (headers) |
| MPS/GRP/SMK belong to the previews player | MPS contents; the strings are absent from both game EXEs | Observed (string-level, bounded) |
| Mac origin of the engine | NFNT, Mac Roman text, byte-swap path | Inferred |

**Remaining unknowns:**
- Why the constant fields exist: `unk3`, `unk4`, `unk0`, version 8 vs 30, and the step `tag`.
- The meaning of the negative-x2 flag on `COMB` hotspots.
- The `a` field of `&0`.
- Whether the 16-bit build uses NFNT 2018.

Agent notes with full detail: `analysis/notes_formats.md` (local only).
