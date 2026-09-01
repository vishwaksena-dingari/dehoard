# Changelog

All notable changes to `dehoard` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions follow [SemVer](https://semver.org/).

## [0.2.8]: 2026-08-31

### Fixed
- **`_run_timeout` never actually bounded anything with a nested process.** It backgrounds the
  command and kills `$pid` on expiry, but when the target is a wrapper script the thing blocking is
  a **grandchild**. Killing the wrapper orphans it, and the orphan keeps the inherited stdout open,
  so every reader of dehoard's output blocks until it exits — the timeout returned 124 on schedule
  while the run still appeared frozen. This is the hang protection used for *every* external tool,
  and the existing test passed only because its stub never nested a process. Descendants are now
  collected with `pgrep -P` **before** the parent is killed (afterwards they reparent and `-P` finds
  nothing) and the whole set is signalled. Measured against a hung stub: 300s before, 6.3s after.
- **`docker info` was called unguarded and could hang forever.** With Docker in a half-dead state —
  `Docker.app` gone, `com.docker.backend` still alive — the socket exists with nothing answering it
  and the CLI blocks rather than failing. Measured past 300s on a real machine in that state, which
  presented as a mid-run freeze with no output. `--deep --dry-run` went from never completing to
  32.9s.
- **A symlinked ancestor could redirect a deletion, and the log would hide it.** With
  `~/Library/Caches` symlinked at `~/Documents`, deleting `~/Library/Caches/thesis.txt` destroyed
  `~/Documents/thesis.txt` while the run log recorded the innocent literal path. The allow-list
  approved it because the string is still under `$HOME`. The safe-root check now runs against the
  physically resolved path (so a symlink escaping the safe roots is refused outright), and a
  redirection that stays inside them is announced, with the **resolved** path recorded in the log.
  Refusing every symlinked ancestor was rejected as a fix: macOS itself symlinks `/tmp` and `/var`.

### Tests
- 153 → 156 assertions. Hermeticity is now asserted as a **property** rather than per call site:
  `_assert_sandbox` was wired into `run()`, but only 2 of ~100 invocations use it and a newly-written
  test would escape anyway. Canaries are planted in the real environment at a path Tier 1 genuinely
  targets and checked at the end, so a regression fails loudly whichever test caused it. Placement
  matters and the first attempt got it wrong — a canary nested inside a `mktemp -d` survives a real
  break, and sabotage proved it passed while the suite was pointed at the real `TMPDIR`.
- Every new assertion was verified to fail against the unfixed code.

### Notes
- Declined after testing: `-ef` inode comparison for `$HOME`, recommended on the grounds that
  `/USERS/...` slips past a string compare. The premise is correct (`/USERS` resolves to the same
  inode) but the conclusion is not: it is a deny-list concern. Under an allow-list the case variant
  fails to match the `$HOME/*` prefix and is refused, so the change would add complexity for no
  security gain.

## [0.2.7]: 2026-08-29

### Security
- **A hostile numeric env var could have turned a preview run into a real deletion.** Caught in
  pre-release review; **no released version was exploitable** (see below). zsh evaluates a
  variable's *value* inside an arithmetic context, recursively, and zsh arithmetic supports
  assignment — so a value like `(DRY_RUN=0)` does not merely produce a wrong number, it assigns to
  `DRY_RUN`, the flag `_rm` branches on to choose preview vs delete. `$DRY_RUN` then holds `0`,
  which is neither `true` nor `false`: `if $DRY_RUN` tries to run a command named `0`, fails, and
  falls through to the delete branch — so a run the user believed was a preview would delete for
  real.

  Scope, verified against the released v0.2.6 rather than assumed:
  - `DEHOARD_HELD_OPEN_MIN_GB` — **introduced and fixed within this unreleased version.** Evaluated
    at top level, so the assignment propagated. Exploitable end-to-end; never shipped.
  - `CACHE_MIN_MB` — shipped since early versions, but **not** exploitable: one use site sits inside
    a `du … | while read` pipeline and the other inside a `$( … )` command substitution, both of
    which zsh runs in a subshell, so the assignment died with the subshell.
  - `DEHOARD_PM_TIMEOUT` — shipped, and its arithmetic (`maxticks=$(( secs * 5 ))`) *is* in plain
    function scope, but `_pm_run` is only called from the `else` branch of `if $DRY_RUN`, i.e. only
    under `--apply`, where deletion is already authorized. Not exploitable.

  Containment in the two shipped cases was incidental — a consequence of where the code happened to
  sit, not a designed guard — so all numeric env vars are now validated as bare non-negative
  integers at their definition sites, before any of them reaches an arithmetic context. A
  non-numeric value is reported on stderr and replaced with the documented default.
- **`_rm` now fails closed on a *corrupted* `$DRY_RUN`, not only an unset one.** The guard previously
  asked whether the flag was empty. But `$DRY_RUN` is used as a boolean *command* (`if $DRY_RUN`), so
  a value like `0` is not false-y — the shell runs a command named `0`, it fails, and control falls
  through to the delete branch. An is-it-empty check passes such a value straight through. `_rm` now
  requires exactly `true` or `false` and refuses anything else. This is defense in depth behind the
  env-var validation above: the first closes the known routes into that state, this closes the state
  itself, including from a route nobody has found yet.

### Fixed
- **`$DRY_RUN` is now read-only once the flag is final (`typeset -r`), which is the ROOT fix.** The
  first pass guarded `_rm`, but `$DRY_RUN` is executed as a boolean command at ~30 sites and most of
  them are not `_rm` — `$DRY_RUN || chmod -R u+w`, the `sudo rm` Apple-cache sweep, `ollama rm`,
  `conda env remove`. All of those take the destructive branch on a corrupted flag, so guarding one
  consumer left every other door open. Freezing the variable makes any later assignment abort the
  run loudly instead of silently deleting.
- **Held-open byte totals were inflated.** `lsof` emits one record per file descriptor *and* per
  mmap, each carrying the file's full size, so a file opened twice (or a deleted dylib mapped by many
  processes) was counted once per record. Measured on the author's machine: 1.66 GB reported vs
  **1.04 GB actual**, a 37% over-count. Records are now deduplicated on device+inode — per process
  for the human warning, and *globally* for `held_open_deleted_bytes`, because one deleted inode
  shared by 40 processes still occupies its blocks exactly once. This matters because the number is
  presented as the explanation for `df` disagreeing; an inflated one makes `df` look wrong when it
  is not.
- **The test suite was deleting real files from the developer's `TMPDIR`.** Tests set `$HOME` but not
  `$TMPDIR`, and Tier 1 removes `${TMPDIR}node-compile-cache`, `hsperfdata_*`, `${BASE}/C/*.helper`
  and similar — paths derived from the *inherited* environment and inside the safe-root whitelist, so
  they were genuinely removed on every `--apply` test. This also produced a self-healing flake: a run
  deleted a real `node-compile-cache`, making `_FREED_KB` non-zero, which failed the "no notification
  when nothing was freed" assertion — and the next four runs passed because the file was gone. The
  suite now exports a fixture `TMPDIR`; tests that deliberately exercise a hostile or unset `TMPDIR`
  still override it.
- **A process name can no longer inject terminal escapes.** The held-open warning interpolates
  another process's command name, which that process chooses via `argv[0]`, into output. zsh's `echo`
  expands backslash sequences, so a process named `x\e[2J` could clear the user's terminal mid-report.
  Now emitted with `print -r --`.
- **`--snapshot` no longer silently overwrites or lies about success.** Timestamps are whole seconds,
  so two runs in the same second wrote the same file; colliding names now get a numeric suffix. And
  `tee`'s exit status was ignored, so "snapshot saved" printed even when the write failed on a full
  or read-only volume; the failure is now reported instead.
- **A vacuous test.** The "valid numeric override is accepted" assertion invoked `--version`, which
  exits hundreds of lines before the validation it claimed to exercise, so it passed unconditionally
  — including against a guard that rejected every legal integer. It now asserts on the guard's own
  stderr, in both the accept and reject directions.
- **A run no longer aborts when `du` returns nothing.** Two sites summed sizes with a command
  substitution *inside* an arithmetic expansion (`$(( kb + $(du -sk …) ))`). When `du` printed
  nothing — a path racing away mid-scan, or an unreadable directory — this expanded to `$(( kb + ))`
  and killed the whole run with `bad math expression`. One of the two sites was inside the generic
  Electron cache sweep, which walks every directory in `Application Support`, so a running app
  rotating its own cache dirs could abort the run, with an error pointing nowhere near the cause.
  Both now read into a variable first, where an empty result is a plain `0`.
- **The unknown-flag warning went to stdout, corrupting `--json`.** `dehoard --json --typo` emitted a
  warning line ahead of the document, so it failed to parse. Warnings now go to stderr, keeping the
  stdout data contract pure.
- **No more "Freed 0 MB" notifications.** The macOS notification fired at the end of every completed
  run, including runs that deleted nothing, and it hardcoded MB — so a KB-sized delete was also
  announced as `0 MB`. It now fires only when something was actually freed, and reports the same
  unit shown in the terminal.
- **The test suite no longer posts real macOS notifications.** `osascript` was the one external tool
  the harness never stubbed, so a single `zsh test/run.zsh` flooded the developer's Notification
  Center with ~100 banners full of throwaway fixture figures.
- **Corrected a false claim in `--help`.** Item 10 said `xcrun simctl delete unavailable` "remove[s]
  simulator runtimes". It does not — it removes *devices*. Runtimes are the ones worth tens of GB and
  Xcode silently reinstalls them on update. dehoard deliberately does not touch them (`simctl runtime
  delete all` can be neither scoped to unused runtimes nor previewed per-item, which its
  preview-first contract requires), and now says so, with the manual command.

### Added
- **`--snapshot`**: behaves exactly like `--json` and additionally archives the document to
  `~/.cache/dehoard/snapshots/<UTC-timestamp>.json`. stdout stays pure JSON, so pipelines are
  unaffected, and `--json` alone never writes anything. Reclaimed space has a half-life; this makes
  regrowth measurable after the fact. Diffing two snapshots is left to `jq` on purpose — no new
  schema contract is introduced. README documents a weekly `launchd` plist.
- **VM / container disk images under `Application Support` are reported** (`.img`, `.img.zst`,
  `.raw`, `.qcow2`, `.vmdk`, `.vdi` over 500 MB), report-only and never deleted. App-agnostic, so it
  covers tools no rule lists — Claude Desktop's `claudevm.bundle` alone can hold ~21 GB. Sizes use
  `du`, not `ls`, because these files are sparse (Docker's image reads 1.0 TB apparent vs 8.4 GB
  real). Scanned at depth 4 (~0.4s); `~/Library/Containers` is deliberately not crawled (≈800
  sandboxed containers, ~52s), so Docker keeps its individual entry.
- **Held-open deleted files are now reported.** When a process holds a file that has been deleted,
  its blocks stay allocated and `df` under-reports free space until that process exits — so
  dehoard's figure can look wrong for a reason dehoard did not cause. A process sitting on ≥5 GB is
  named in `--report` and after `--apply`. It states the fact and stops: it never suggests killing
  anything, because deciding to end a process is the user's call, not a cleaner's. The threshold is
  per-process, not total, because ~1.5 GB of ambient held inodes (plist caches, Spotlight, widgets)
  is normal on an idle Mac; measured noisiest ordinary process was 0.43 GB, giving ~11x headroom.
  `lsof` is invoked as `lsof -bnP -Fpcsn +L1`: `-b` so a stale NFS/SMB mount cannot hang the run,
  and `-F` field mode so sizes are read by tag rather than column position (in the plain table `$7`
  is SIZE/OFF and `$8` is NLINK, and filtering the wrong one silently matches nothing while looking
  correct). Note there is no `-u $USER`: lsof ORs selection flags unless `-a` is given, so
  `-u $USER +L1` would mean "this user's files OR deleted-open files" — 26x more rows.
  This does **not** change the reclaim tally into a `df` delta; a modest tally-vs-`df` gap remains
  normal and expected. The threshold is tunable via `DEHOARD_HELD_OPEN_MIN_GB` (default `5`),
  alongside the existing knobs, because it was calibrated on an idle developer Mac and a machine
  running Docker, a database, or a long-lived browser can legitimately hold far more.
- **`held_open_deleted_bytes` in `--json`** (additive; `schema_version` unchanged, existing
  consumers unaffected). Unthresholded, unlike the human warning: a machine consumer wants the raw
  figure to reconcile against `df` itself. `0` when nothing is held or `lsof` is unavailable.
- **README: "Using dehoard from an agent."** `dehoard --json` already gives any shell-capable agent
  the full inventory with no install, no daemon, and no tool schema in the context window, so there
  is no MCP server. Documents the three rules: `--json` is read-only, stdout is pure JSON, and an
  agent must never call `--apply` — the `_rm` whitelist stops path bugs, not a correctly-executed
  deletion that should not have been chosen.

### Tests
- 127 assertions (was 104). New coverage: a typo'd flag cannot corrupt `--json`; `--snapshot` keeps
  stdout pipeable and archives exactly one valid document; `--json` alone never archives; a run that
  frees nothing posts no notification; and `lsof` is stubbed in `-F` field mode to fake a 26 GB
  holder — asserting it is named with its size, that the wording never suggests killing it, that a
  0.43 GB holder stays silent, that the warning never leaks into `--json` stdout, and that
  `held_open_deleted_bytes` is reported exactly both above and below the human threshold. Plus the
  arithmetic-injection regression: each of the three numeric env vars, set to `(DRY_RUN=0)`, must
  leave the victim file intact and still report a preview — and a valid numeric override must still
  be accepted. Honest scope on that last point: only the `DEHOARD_HELD_OPEN_MIN_GB` strand actually
  fails against the unfixed code. The other two are defense-in-depth assertions, because (as
  analysed above) `CACHE_MIN_MB` was subshell-contained and `DEHOARD_PM_TIMEOUT` is only reachable
  under `--apply`; they would have passed before the fix. Every other new assertion in this release
  was individually verified to fail against the unfixed code.

## [0.2.6]: 2026-06-04

### Fixed
- **Runs under zsh defaults regardless of your `~/.zshenv`.** `~/.zshenv` is sourced for every `zsh`
  invocation, so a global `setopt KSH_ARRAYS` or `SH_WORD_SPLIT` previously leaked in and could make
  `--json` emit invalid output (with exit 0) or silently skip a project whose path contains a space.
  dehoard now calls `emulate zsh` at startup (then re-applies its one required option, `NULL_GLOB`),
  so output and globbing are deterministic no matter how your shell is configured. No change to normal
  runs; the safe-root guard already prevented any wrong deletion in these cases.

### Docs
- `docs/ARCHITECTURE.md` showed the `main()` dispatch and called it "verbatim" while omitting the
  first line (the `--uninstall`/`--purge` dispatch); the shown block now includes it.

### Notes
- Hardening + doc accuracy; no behavior change on a normally-configured shell, no new flags. 104
  assertions (was 102; added a hostile-`.zshenv` regression: `--json` stays valid and a space-path
  project is still detected under `KSH_ARRAYS`/`SH_WORD_SPLIT`).

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
