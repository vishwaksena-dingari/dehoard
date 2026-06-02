# Changelog

All notable changes to `dehoard` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow [SemVer](https://semver.org/).

## [0.1.1]: 2026-06-02

### Fixed
- **A hung package manager no longer freezes a run.** Each external package-manager cleanup
  (brew/npm/pnpm/yarn/pip/uv/bun/trunk) now runs under a wall-clock timeout; if one blocks, dehoard
  prints `skipped <tool>: timed out` and continues. The timeout is `DEHOARD_PM_TIMEOUT` seconds
  (default 120, env-overridable). Found by real-machine testing, where a package-manager command
  blocked indefinitely.
- **`_rm` no longer claims a deletion it did not make.** It now deletes each path first and prints
  `removed:` only on success; on failure it prints one concise warning (with a sudo hint for
  root-owned paths) and routes `rm`'s own errors to the deletion log instead of flooding the terminal
  (e.g. root-owned CPAN build dirs no longer dump hundreds of lines).
- **The ignore list is now honored in every tier.** Previously "always skip" only applied at the
  interactive prompts; batch Tier 1 / `--deep` sweeps bypassed it. The check now lives in the single
  `_rm` delete primitive (after the safe-root guard, so it can only ever skip more), and entries may
  be globs.
- **Time Machine snapshot parsing** now keeps only date-formatted rows, so the
  `tmutil listlocalsnapshotdates` header line can never be mistaken for a snapshot to delete.

### Documentation
- Clarified that `--json` `models[]` is the cross-tool inventory it dedups across (HuggingFace,
  Ollama, LM Studio, PyTorch hub); framework caches like Keras or Whisper appear as a size footprint
  in `--report`, not as individual `models[]` entries.

All fixes covered by the fixture-`$HOME` test suite (56 assertions).

## [0.1.0]: 2026-06-01

First public release: a single auditable zsh script that reclaims disk on ML/dev Macs and refuses
to touch your data.

### Cleanup modes
- **`--report`**: read-only audit: biggest directories, reclaimable caches (labelled with the flag
  that clears each), a cross-tool model inventory, and the cross-tool duplicate analysis. Deletes nothing.
- **Tier 1** (bare run / `--apply`), always-safe regenerable caches: package-manager download caches
  (brew/npm/pnpm/yarn/pip/uv/bun/trunk), browser update clones, language tool caches (node-gyp, CPAN,
  Selenium, Go, Cargo, Gradle, Maven, NuGet…), Jupyter checkpoints, Trash, old installer DMGs,
  Time Machine local snapshots.
- **`--deep`**: Tier 2 aggressive caches: Library caches, Clang/Metal/Python caches, Xcode
  DerivedData, Docker `system`/`builder` prune (+ disk-image reporting), HuggingFace cache,
  Playwright/Puppeteer, iOS simulators, large-repo `git gc`.
- **`--models`**: interactive LLM/ML weight cleanup (Ollama, LM Studio, HuggingFace, NLTK, PyTorch).
- **`--scan`**: interactive project-artifact scan: venvs (by `pyvenv.cfg` content, any folder name),
  conda/uv, `node_modules`, build/coverage/test artifacts, Rust `target/`, R/LaTeX/IPython artifacts,
  editor cruft, AI-tool caches (incl. MATLAB logs/crash-dumps/caches; the MATLAB runtime, prefs,
  history, and code are kept), orphaned dev/ML tool data, and a generic size-ranked cache sweep.

### Headline feature: cross-tool duplicate-model detection
- Enumerates local models across HuggingFace / Ollama / LM Studio / PyTorch, normalizes each to a
  family + size + quant + variant key, and splits **true duplicates** (identical build → safe reclaim
  estimate) from **related variants** (a `Q4≠Q8` or `base≠instruct`, listed, never counted).
  Report-only; weights are never auto-deleted.
- **`--json`**: machine-readable model-inventory manifest on stdout (`schema_version` 1; `size_bytes`
  integers; pipes cleanly into `jq`).

### Safety
- **Preview by default**: nothing is deleted without `--apply`; `--dry-run` always forces preview.
- **Refuses to run as root.**
- **One delete primitive (`_rm`)** with a safe-root whitelist (`$HOME` / `var-folders` / `tmp` only)
  and a **fail-closed precondition** that refuses if the dry-run safety flag is somehow unset.
- **Never deletes your data**: model weights, outputs, session/chat history, source, git, configs
  are detected and kept.
- **Ignore list**: opt-in "always skip" for paths you decline (`--list-ignored` / `--unignore` /
  `--reset-ignore`); every skip is announced; disable entirely with `DEHOARD_IGNORE_ENABLED=false`.
- **Deletion logging** to `~/.cache/dehoard/run-<timestamp>.log` under `--apply`; NULL_GLOB; SIGINT trap.
- **Live deletion record**: under `--apply`, each removed path and its size is echoed as it happens
  (`removed: ~/… (size)`), so deletions are visible in real time, not just summarized.

### Output
- **Semantic terminal color**: APPLY banner (red), warnings/refusals/destructive prompts (yellow),
  kept user-data & freed space (green), section headers (cyan), and cleanup-step labels that are dim
  while previewing but **bold once applying** (per-file deletes are silent, so the label is the only
  live evidence). The would-delete file list and `[dry-run]` lines stay **plain** for readability.
  Routed through one set of helpers gated by a single flag; **never emitted to a machine channel**,
  `--json` and the deletion log are always escape-free, and color auto-disables when stdout is not a
  TTY. Honors `NO_COLOR`; `CLICOLOR_FORCE=1` forces it on. `--help` is intentionally left plain.

### Configuration
- Env vars: `DEHOARD_APPLY_DEFAULT`, `DEHOARD_IGNORE_ENABLED`, `CACHE_MIN_MB`, `NO_COLOR`,
  `CLICOLOR_FORCE`; `GIT_GC_ROOTS` / `EXTRA_SCAN_DIRS` in the USER CONFIG block.

### Documentation
- **`docs/RULES.md`**: a public, invariants-only safety constitution: the scope, the hard rules, the
  `_rm` safe-root contract, and the `_ai_clean` keep/clean pattern, in one place. A test pins its
  documented safe-root list to `_rm`'s actual whitelist so the document cannot drift from the code.

### Quality
- `--version` / `-V`, print the version and exit.
- 52-assertion fixture-`$HOME` test suite in CI (proves `--apply` spares user data, destructive
  external commands run only under `--apply`, dry-run runs zero of them, dedup never miscounts
  variants, `--json` stays valid, ignore-list/read-only invariants hold, `_rm` fails closed,
  the MATLAB cleaner keeps the active runtime, `docs/RULES.md` stays in sync with `_rm`, and
  **color never leaks into `--json`, the log, or a pipe, even forced on**).
- Single file, function-structured internally (`main()` dispatch) with the help text in a `usage()`
  heredoc. No runtime dependencies beyond zsh + the macOS userland.
