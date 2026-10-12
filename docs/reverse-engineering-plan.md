# Reader Rabbit reverse-engineering plan

## Goal

Build an evidence-backed technical map of this Reader Rabbit Preschool disc: identify its launch/runtime path, document how the game loads levels and media, and characterize the proprietary data formats. Treat an asset extractor or playable reconstruction as follow-on work after the format and behavior are understood.

## Initial inventory observations

These are filesystem observations, not REA analysis Evidence:

- `RRPW32.EXE` is identified as a PE32 Windows executable; `RRPW16.EXE` is identified as a Windows 3.x NE executable. Their precise roles and which one is the primary game runtime still need verification.
- The disc includes other executables, including `GENESISB.EXE`, `START.EXE`, and installer/registration utilities. Do not assume every executable is part of the game runtime.
- `RRPDATA/` contains four large `.DAT` files; `ASSETS/` contains six `.GRP` files; `MOVIES/MV107A.SMK` is recognized as Smacker video.
- Several installer `.MPS` files contain readable puzzle instructions and numeric resource IDs, suggesting a data-driven content model. The mapping from those IDs to actual resources has not yet been established.
- `scan_graphic_signatures.py` scans only an initial byte range of `GRAPHIC.DAT` for a small set of common signatures. It is useful as a preliminary probe, not as a complete container parser.

## Staged investigation

1. **Establish identity and boundaries.** Build a read-only inventory of files, sizes, hashes, and detected formats. Trace the launch configuration and separate game/runtime components from setup, registration, promotional, and parental-control utilities.
2. **Map executable responsibilities.** Analyze the verified game entry point and related engine binaries. Inspect imports, strings, resources, function references, and data-loading paths. Compare the 32-bit and 16-bit builds where that answers a concrete question. Treat recovered pseudocode as analysis, not original source.
3. **Characterize content formats.** Inspect headers and record layouts in `.DAT` and `.GRP`; analyze `.MPS` scripts; and trace resource IDs into graphics, sound, speech, music, and movie data. Reuse format-aware tooling for recognized formats and validate any inferred custom structure against multiple files.
4. **Correlate one feature end to end.** Follow a single puzzle/level from its script and identifiers, through the loader and lookup logic, to the referenced assets and resulting behavior. Expand to other levels only to test or refine that model.
5. **Use runtime evidence only for unresolved behavior.** If static evidence is insufficient and an appropriate environment is available, run a disposable copy in an isolated Windows VM/emulator. Keep networking disabled, snapshot before execution, and capture only the agreed launch and interactions. Do not run registration or promotional installers as substitutes for the game.
6. **Maintain an evidence ledger and deliverables.** For each conclusion, record source/evidence reference, evidence type, confidence, coverage boundary, and remaining unknowns. Produce a concise format/loader report first; implement an extractor or reconstruction only once the desired outcome is selected.

## Tooling and safety constraints

- Use the `reverse-engineer-anything` skill's REA workflows for binary and artifact claims. Check the connected tool inventory/provider availability before analysis; use a supported CLI route if MCP is unavailable.
- The host is macOS on ARM64. REA 6.4.0 is installed through `npx` using Node.js 22.22.1 and a dedicated npm cache at `/Users/jeremywong/.cache/rea-npm-cache`; the active Zed session advertises its MCP tools. Ghidra 12.1.4, Temurin JDK 21.0.12.1, and a built macOS ARM64 native decompiler are installed under `/Users/jeremywong/.local/opt/rea/`. REA reports Ghidra as available and all its setup checks pass. This establishes a static-analysis route, not a Windows runtime; the original Windows executables must not be assumed to run natively.
- Preserve the supplied disc files unchanged. They are isolated under `game/`, which is excluded from Git. Keep analysis scripts, documentation, and any independently authored tools outside that ignored directory.
- The user authorized REA/Ghidra setup and Zed MCP registration. The Zed settings were backed up to `/Users/jeremywong/.config/zed/settings.json.rea.backup` before adding the `rea` server; the settings JSONC parses successfully and the entry uses the pinned REA 6.4.0 package and dedicated npm cache. No unrelated dependencies were installed. REA's session reports the installed `reverse-engineer-anything` skill at version 40 while this REA package expects version 37. A broad setup command would replace the newer skill with an older copy, so that was deliberately not run; the active server still provides the current tool inventory.

## Preparation status (2026-10-12)

- The repository is initialized on `main` and has an initial commit. The current update to this plan is uncommitted. `game/` is excluded by `/game/` in `.gitignore`, and `git ls-files game` is empty; the game payload is not tracked. `scan_graphic_signatures.py` remains at the repository root.
- REA 6.4.0 MCP is available in the active Zed session (170 tools, 6 prompts). The installed CLI doctor passed in the setup session. Zed settings JSONC validation passed, and the REA entry and backup were verified without exposing existing settings secrets.
- Ghidra 12.1.4 and Temurin JDK 21.0.12.1 are installed. Ghidra's macOS ARM64 native decompiler was built locally because it was absent from the official archive. REA's live provider check confirms the installation, platform, architecture, version, headless launcher, JDK, and native decompiler are healthy.
- The REA package expects skill version 37, but the installed global skill is version 40. This mismatch is recorded and intentionally left unchanged to avoid replacing the newer skill; it has not prevented the MCP tools from appearing in the active session.
- **Game analysis has not begun.** No game binary has been executed or opened in an analysis provider, and no proprietary media has been extracted or modified.

## Next actions

1. Use REA's read-only artifact inventory on the selected files under `game/`; record digests, sizes, formats, and coverage in Evidence. Do not commit game payloads or generated proprietary media.
2. Start with `RRPW32.EXE` using Ghidra, then establish executable responsibilities and launch/configuration paths from static evidence before inspecting custom data formats.
3. Keep all analysis claims linked to Evidence and explicitly label inferred format details. Runtime execution remains a separate decision; the current setup supplies static analysis only and does not establish a safe or functioning Windows execution environment.
