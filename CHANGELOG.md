# Changelog

All notable changes to `dehoard` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow [SemVer](https://semver.org/).

## [0.2.5]: 2026-06-04

### Security
- **The one `sudo rm` (the `--deep` system-cache sweep) now canonicalizes its base path before the
  `/var/folders` guard.** Previously the guard was a plain string-prefix check, so a hostile
  `TMPDIR` like `/var/folders/../../etc/T/` could pass it yet resolve elsewhere. `$BASE` is now
  resolved with `:A` first, so a `..`-laced or symlinked `TMPDIR` that points outside a per-user temp
  root is refused. (Needs attacker-controlled environment plus `--deep --apply`; defensive hardening.)
- **`_rm` refuses any target containing a `..` traversal segment.** Defense-in-depth: the safe-root
  whitelist is a prefix match, so this closes a theoretical walk-out (not reachable by normal scans,
  which produce already-canonical paths). Purely subtractive: it can only ever delete less.
- **The env-manager uninstallers reject a discovered name that begins with `-`.** A directory named
  like `--foo` is removed via the safe path delete instead of being passed to `conda`/`uv` as a flag
  (no shell injection was possible; this prevents argument confusion).
- **`--json` escapes control characters.** Names containing bytes U+0000-U+001F are now emitted as
  `\u00XX`, so a model or directory name with a control character stays valid JSON.

### Fixed
- The `--scan` help line listed `~/Documents, ~/src, ~/Desktop, and ~`; the scan actually crawls `~`
  (the whole home). Reworded to say so.

### Notes
- Hardening only, from a security-focused audit pass; no behavior change on the normal path, no new
  flags. 102 assertions (was 98; added the sudo-guard escape, the dash-name uninstaller guard, the
  control-character JSON case, and the `_rm` traversal refusal).

## [0.2.4]: 2026-06-04

### Fixed
- **`--uninstall` preview now matches what it deletes in the rare XDG-overlap case.** When
  `XDG_CACHE_HOME` and `XDG_CONFIG_HOME` point at the same directory, a plain `--uninstall` keeps the
  ignore list and removes only the logs; the "Will remove:" line wrongly named the whole directory.
  It now names the narrowed `run-*.log` target, so the preview always matches the action.
- **Cross-tool duplicate detection groups the Command R family correctly.** The model-name normalizer
  turned hyphens into spaces before matching, so `command-r` / `command-r-plus` fell through to a
  generic key. They now normalize to a shared `commandr` key (read-only; affects `--report`/`--json`
  grouping only).

### Changed
- The five governance docs (RULES, SAFETY, ARCHITECTURE, CONTRIBUTING, README) now list
  `--uninstall`/`--purge`'s `rm -rf` among the audited deletions that run outside `_rm`, framed as the
  one sanctioned exception that removes dehoard's own fixed footprint rather than a user cleanup
  candidate. The "new code must not add more" wording is reconciled accordingly: the rule bars new
  deleters of user cleanup paths outside `_rm`, and the listed exceptions are exhaustive.

### Notes
- Follow-ups from a deeper 4-agent audit (whole-script bug hunt, code-doc alignment, test quality,
  prose); no behavior change to the normal path, no new flags. Added test coverage for the uninstall
  edge branches a fresh `curl | zsh` user hits (empty footprint, `$0` not a real file, no ignore file
  present, `--report` honoring `XDG_CACHE_HOME`) and widened the package-manager-timeout test's margin.
  98 assertions (was 92).

## [0.2.3]: 2026-06-04

### Added
- **`--uninstall` and `--purge`: remove dehoard, following the `apt remove` vs `apt purge`
  convention.** `--uninstall` removes the regenerable deletion logs (`~/.cache/dehoard/`) and, when
  the running copy is the standard `~/.local/bin/dehoard` install, the script itself; it **keeps your
  ignore list** and tells you where it is. `--purge` also removes the ignore list, printing its
  contents first so the one irreplaceable file is never lost silently. Both are preview-first (list
  exactly what they will remove and keep, then confirm); `--dry-run` shows the plan and deletes
  nothing, `--yes` skips the prompt. A copy run from a cloned repo, a custom path, or a symlink is
  never deleted; dehoard prints the manual `rm` for it instead (a symlinked or relocated install could
  otherwise point at a file you want to keep). Removal targets are fixed paths under `$HOME`, never
  user-derived.

### Changed
- **The ignore list moved from `~/.cache/dehoard/ignore` to `~/.config/dehoard/ignore`** (honoring
  `XDG_CONFIG_HOME`), because it is user-authored config, not regenerable cache. An existing file at
  the old location is migrated automatically on the next run. Logs stay in `~/.cache/dehoard/`
  (honoring `XDG_CACHE_HOME`). This is why `--uninstall` can clear the cache freely while preserving
  config by default.

### Notes
- The complete on-disk footprint is documented in README "Footprint and uninstall": the script at
  `~/.local/bin/dehoard`, logs at `~/.cache/dehoard/`, and the ignore list at `~/.config/dehoard/`.
  92 assertions (was 83; added: ignore-list migration, `--uninstall` keeps config, `--purge` removes
  it after echoing, standard-install removal, non-standard/symlink-copy preservation, the XDG
  cache==config collision guard, dry-run/decline safety).

## [0.2.2]: 2026-06-03

### Fixed
- **The ignore list now covers a directory's contents, not just the exact path.** An "always skip"
  entry on a folder previously matched only that exact path, so the `--pick` picker could still offer
  a file or subfolder inside it (found on a real machine: an ignored app dir whose `Cache` subfolder
  was still listed). `_is_ignored` now also matches descendants (`<entry>/*`), so ignoring a directory
  reliably skips everything under it.
- **A path found by two scanners is now registered once.** A large cache could be picked up by both a
  specific tool rule and the generic >100MB sweep (e.g. `~/.cache/codex-runtimes` appeared under both
  `ai-cache` and `cache`), so it was shown and confirmed twice and inflated the per-category summary.
  The picker registry now dedups on the normalized absolute path, so each item appears under one
  category only.

### Notes
- Hardening only: no new flags, no behavior change on the normal (non-`--pick`) path. Both fixes are
  fail-safe (no data was at risk; the duplicate delete was already a no-op). 83 assertions (was 81;
  added regression tests for descendant-ignore coverage and cross-category dedup). Surfaced by real
  dogfooding of the per-category picker.

## [0.2.1]: 2026-06-03

### Fixed
- **LM Studio `.gguf` deletion now routes through `_rm`.** It previously used `find -delete`, which
  bypassed the safe-root guard, the ignore list, and the deletion log. It now deletes each file
  through `_rm` (NUL-safe, via process substitution so the freed-space tally is not lost to a
  subshell), so weight deletion is guarded, ignore-aware, and logged like everything else. This
  removes one entry from the short list of audited `_rm` exceptions.
- **`DEHOARD_APPLY_DEFAULT` is now compared, not executed.** The opt-in was written
  `${DEHOARD_APPLY_DEFAULT:-false} && APPLY=true`, which ran the variable's value as a command. It is
  now a string comparison (`[[ ... == true ]]`), so a stray value can never execute. `=true` still
  enables apply; `--dry-run` still overrides.
- **Backgrounded child is reaped on Ctrl-C in the timeout fallback.** When no `timeout`/`gtimeout`
  binary is present, `_run_timeout` polls a backgrounded child; a SIGINT/SIGTERM during that wait now
  kills the child before exiting instead of orphaning it (scoped trap, reverted on return).
- **Model-weight total is rounded correctly.** The human `--report` "TOTAL local model weights" line
  used truncating integer math for its one decimal; it now formats with `awk` (the `--json` figure
  was always exact).

### Changed
- CI uses `actions/checkout@v5` (Node 24) instead of the deprecated `@v4` (Node 20).
- README documents the exhaustive read-only preview recipe (`--deep --models --scan --dry-run`), that
  `--report` is a standalone mode that does not stack with the action-flag preview, and that the
  `--pick` picker covers `--scan` artifacts only (Tier 1 is a batch; weights go through `--models`).
  Added docs/PHILOSOPHY.md (design stance) and linked it from the README and docs index.

### Notes
- Hardening only: no new flags, no behavior change on the normal path. 81 assertions (was 77; added
  regression tests for the `DEHOARD_APPLY_DEFAULT` comparison and the LM Studio `_rm` routing,
  including ignore-list coverage).

## [0.2.0]: 2026-06-03

### Added
- **`--pick`: an interactive `fzf` picker per `--scan` category (biggest first).** Instead of a prompt
  per item, dehoard collects all reclaimable candidates (Python venvs, conda/uv/Android/Rust toolchains,
  `node_modules`, dist/build, `__pycache__`/egg-info/coverage, JVM heap dumps, ROS2 colcon artifacts,
  R session files, editor swap/backup, project logs, AI-tool caches, orphaned tool data, and the
  generic cache sweep) and opens **one picker per category**, biggest category first, prefaced by a
  **per-category summary** (count + size) as a contents page. In each: **TAB** marks, **Ctrl-A** all,
  **Ctrl-D** none, Enter confirms, **Esc skips that category**. dehoard reprints the marked set and
  asks once, then deletes just that category before moving on (so you can stop after the big ones).
  - **Typed deletion.** Env-managers are removed with their native uninstaller, not raw `rm`
    (`conda env remove`, `uv python uninstall`, `sdkmanager --uninstall`, `cargo clean`), so they
    don't leave ghost metadata; everything else goes through `_rm` (safe-root guarded). Ignored paths
    are dropped at registration, so an "always skip" entry never enters the picker for any type.
  - **Interactive-only + delete-time only.** `--pick` runs JUST the picker, not the Tier 1 auto-sweep
    (so it never batch-deletes caches or prompts for sudo behind your back). It needs `--apply`; under
    `--dry-run` (or without `--apply`) it prints the normal preview list plus a one-line note and never
    opens the selector. Esc or an empty selection deletes nothing.
  - `fzf` is optional: without it, `--pick` falls back to the per-item prompts. `--pick` runs ONLY the
    picker: the non-pickable "noise" categories (`.DS_Store`, stray `.pyc`, LaTeX aux, IPython history)
    and model weights are skipped under `--pick` with a note pointing to plain `--scan`; they are never
    deleted inline behind the picker.

### Fixed
- **`--report` "Last --apply run"** now shows the most recent run; it was sorting the run logs
  oldest-first and reporting the very first run.
- **`--deep` system-cache cleanup** now guards the one `sudo rm` to a `/var/folders` root, so a
  mis-computed `$TMPDIR` can never hand an unexpected path to `sudo rm` (it's skipped with a note).
- **"Storage freed" now reports what dehoard actually deleted**, not a whole-disk `df` delta. The old
  figure was `free-space-after - free-space-before`, which credited dehoard for ambient disk activity
  during the run (it could show a non-zero "freed" even when nothing was deleted). It now sums the
  size of each path dehoard removes, across every deletion path, the `_rm` primitive, the `--scan`
  env-manager native uninstallers (conda/uv/Android/Rust, in both the per-entry and `--pick` flows),
  and `--models` (`ollama rm` via a store-size delta, LM Studio). Deleting nothing reports "Nothing
  deleted." The `df` value is kept only as separate "Free space now" context.

### Documentation
- Documented model-weight handling in depth: *why* weights are treated differently from caches (not
  cheaply regenerable, so never auto-deleted / never in the picker), that duplicate detection is
  strictly **cross-tool** (two copies inside one tool are not flagged), and that `--models` removes
  **per tool**, not per model. Corrected docs that called `--models` "per-item". Fixed a
  `CONTRIBUTING.md` line that wrongly listed model weights among regenerable data dehoard deletes.

Covered by the fixture-`$HOME` test suite (77 assertions), including the picker's abort-safety
(empty/Esc deletes nothing even under `--apply --yes`), interactive-only behavior, typed deletion for
all four env-managers (conda/uv/Android/Rust), the ignore list being honored inside the picker,
safe handling of a TAB-in-path candidate, and the honest freed-space accounting (deleting nothing
reports zero; a real delete reports the size actually removed).

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
