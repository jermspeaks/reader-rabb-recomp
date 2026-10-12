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
- The initial shell check found Node.js and npm but did not find `rea` or `wine`. The host is macOS on ARM64. Runtime analysis may therefore need separate environment setup; do not assume the original Windows binaries can run natively.
- Preserve the supplied disc files unchanged. They are isolated under `game/`, which is excluded from Git. Keep analysis scripts, documentation, and any independently authored tools outside that ignored directory.
- Do not install unrelated system dependencies or modify global tool configuration without first presenting the exact setup scope and backup/rollback plan.

## Current status

Plan only. No game binary has been executed, no REA analysis has been run, and no proprietary media has been extracted or modified. The first analysis step is to establish REA CLI/MCP availability and capture the read-only artifact inventory.
