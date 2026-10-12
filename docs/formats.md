# Reader Rabbit Preschool data formats

Findings from the first static-analysis pass (2026-10-12). Every claim below is tagged:

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
| GRAPHIC | 0xFF02 | `COMB` | 6 | Inferred: lists of rectangles or hit regions (`u16 1, u16 base_id, u16 count`, then `id, x1, y1, x2, y2` records). Unverified |
| GRAPHIC | 0xFF03 | `LIPS` | 1437 | Inferred: lip-sync tracks for speech (`01 01`, an ID, a count, then timed mouth-frame entries). Unverified |
| GRAPHIC | 0xFF04 | `NFNT` | 5 | Classic Macintosh `NFNT` bitmap font, with header fields stored little-endian (`fontType 0x9000`) |
| GRAPHIC | 0xFF05 | `RRGB` | 39 | 256-colour palettes (§4); validated |
| GRAPHIC | 0xFF06 | `TEXT` | 2 | Mac Roman text with layout directives (`&0,…`, `&T,x1,y1,x2,y2,?,size,align`), used for parent info pages. The same format strings appear in the EXE |
| SPEECH / SOUNDS / MUSIC | 0xFF01 | `WAVE` | 1076 / 1084 / 79 | Complete RIFF WAVE files: PCM, mono, 8-bit, mostly 22050 Hz (21 SOUNDS entries use 22000, 22255, 11127, or 11000 Hz). Can be used as-is |

The Mac-style resource tags, the `NFNT` fonts, and the Mac Roman text all point to an engine that originated on the Macintosh. The `ASEQ` byte-swap path (§3) supports this. (Inferred.)

## 3. `ASEQ`: sprites and animations (Observed; validated over 1572 resources / 11 815 frames)

The loader is `FUN_0043462a`, and the per-frame pass is `FUN_004379c3`. Everything is little-endian.

```
header      s16 seq_count, s16 frame_count, s16 version, s16 unk3, s16 unk4
            version > 0xFE ⇒ big-endian data; the loader byte-swaps it (FUN_00434528/34551)
u32[frame_count]   frame offsets, relative to frame base
u32[seq_count]     pointer slots (filled at load time; no data on disk)
seq_count × { s16 n; n × (4 × s16) }   sequence steps, semantics TBD
frame base:
  frame     s16 unk0, s16 width, s16 height, then `height` RLE rows
row RLE (repeat until `width` pixels are produced):
  00 n      n transparent pixels
  FF c n    n pixels of palette index c
  k         (1–254) k literal palette indices follow
```

When a frame is loaded, `FUN_004379c3` remaps each colour byte through the 256-entry table `DAT_0044ad28`. That table is built from the active palette and the Windows system colours (§4). A port can use the raw indices with the matching `RRGB` palette.

640×480 single-frame `ASEQ`s are scene backgrounds. Their IDs match palette IDs (for example, `ASEQ 2000` is the main-menu carousel and `ASEQ 2200` is the ABC Diner exterior, each paired with `RRGB` of the same ID). Rendering both with their palettes produced correct images. Small multi-frame `ASEQ`s are character sprites (for example, `ASEQ 201`, a 9-frame mouse).

Still unknown: the four `s16` fields of a sequence step (inferred to be frame index, timing, and x/y offset), the frame `unk0`, header `unk3`/`unk4`, and how sprites are matched to palettes other than by sharing a scene's ID.

## 4. `RRGB`: palettes (Observed)

There are 256 entries of 6 bytes each, in the Macintosh `RGBColor` style (three 16-bit channels). The engine (`FUN_00437c07`) uses the first byte of each channel: `r = b[6i]`, `g = b[6i+2]`, `b = b[6i+4]`. Each resource occupies 1536 bytes, padded to 2048.

In 8-bit display mode, entries 10–245 are loaded into the system palette. Entries 0–9 and 246–255 are reserved for Windows system colours, and the remap table `DAT_0044ad28` handles any collisions. Palette ID `0x7788` is handled specially (not yet examined).

## 5. Tools in this repository

- `tools/ne_resources.py FILE [--entries]`: lists an NE resource table.
- `tools/aseq.py GRAPHIC.DAT`: parses and validates every `ASEQ`.
- `tools/render_aseq.py GRAPHIC.DAT OUT PALETTE_ID ASEQ_ID…`: renders frames to RGBA PNG for local checking. Write the output under the git-ignored `analysis/` directory, and never commit rendered output.
- `tools/ghidra/ExportDecomp.java`: a Ghidra headless post-script that exports all pseudocode. Write the output to `analysis/`, which is git-ignored.

## 6. Evidence ledger

| Claim | Evidence | Confidence |
|---|---|---|
| The DATs are opened and parsed by the EXE itself | REA `procedure_callers` ev_1e60a99d… (CreateFileA ← `FUN_0041606b`), `batch_decompile` ev_f23860d6… | Observed |
| The DAT search order and file-name fallbacks | `FUN_00438745` pseudocode; bytes at `0x445d54–0x445d9f` | Observed |
| Lookup by FourCC tag plus ID | `FUN_004162ab`, `FUN_0043895b` pseudocode; name-table bytes | Observed |
| `ASEQ` layout and RLE | `FUN_0043462a`, `FUN_004379c3`; `tools/aseq.py` passes on all 1572 resources | Validated |
| `RRGB` layout | `FUN_00437c07`; renders of 2000/2200 are visually correct | Validated (2 scenes) |
| Audio is plain WAV | RIFF/fmt headers checked on all 2239 SPEECH/SOUNDS/MUSIC entries | Validated (headers) |
| MPS/GRP/SMK belong to the previews player | MPS contents; the strings are absent from both game EXEs | Observed (string-level, bounded) |
| Mac origin of the engine | NFNT, Mac Roman text, byte-swap path | Inferred |

REA session snapshot: `analysis/RRPW32.rea-snapshot` (local only).
