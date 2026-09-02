# Lessons — defects that recurred, and what stops them now

An incident ledger, not a style guide. Every entry is a bug that **actually shipped or was actually
caught here**, written so the same mistake is harder to make twice. Where a test locks the fix, the
entry names it: if the rule and the suite ever disagree, the suite wins and this page is wrong.

Read this before adding a cleanup rule, a size calculation, or a test.

---

## 1. Integer division silently prints `0`

**Recurred three times**: the freed-space desktop notification, the held-open-files warning, and the
`--trash` tally.

`$(( 4 / 1024 ))` is `0`. Every size the user sees passes through a division, so any hardcoded unit
eventually reports a real quantity as nothing — the most alarming possible output for a tool whose
entire job is reporting reclaimed bytes. `--trash` printed `Moved to Trash: 0 MB` after moving a
real file.

**Rule.** Never hardcode a unit. Pick it with the same GB/MB/KB ladder used by `print_result`, or
format with one decimal via float division (`$(( bytes / 1073741824.0 ))`).
**Locked by:** `test/run.zsh` — "no notification when nothing was freed", and the held-open
size assertions.

## 2. A test that asserts nothing still passes

**Recurred twice.** Both looked green for weeks.

- The "valid numeric override is accepted" test invoked `--version`, which exits ~440 lines *before*
  the validation it claimed to exercise. It would have passed against a guard that rejected every
  legal integer.
- The first empty-`du` regression test passed with **both** patched sites reverted, because each
  site sits behind a `[[ -d … ]] || continue` guard that an empty fixture never satisfies, *and*
  because that sweep only runs under `--scan`, not a bare run.

**Rule.** A new test is not evidence until it has been **observed to fail**. Revert the fix, watch
it go red, restore. If it cannot be made to fail, it is asserting nothing — delete it or fix the
fixture. Check two things specifically: that the code path is actually *reached* (not short-circuited
by an early `exit` or a `|| continue`), and that the invocation *mode* reaches it (`--scan` vs a
bare run).

## 3. The test suite deleted real files

Tests set `$HOME` but not `$TMPDIR`. Tier 1 removes `${TMPDIR}node-compile-cache`,
`hsperfdata_*`, `${BASE}/C/*.helper` — paths derived from the **inherited** environment and inside
the safe-root whitelist, so the deletions were legitimate for the paths handed over. Nothing failed.
Every `--apply` test was eating the developer's (and CI's) real temp caches.

It also produced a **self-healing flake**: a run deleted a real `node-compile-cache`, `_FREED_KB`
went non-zero, the "nothing was freed" assertion failed — and the next four runs passed because the
file was already gone. A flake that repairs itself is nearly impossible to reproduce by re-running,
which is exactly what everyone does first.

**Rule.** A fixture is `$HOME` **and** `$TMPDIR`, always. Sandbox violations must be loud.
**Locked by:** `_assert_sandbox` in `test/run.zsh`, which hard-exits if `$HOME` or `$TMPDIR` is not
a temp path, or if `$HOME` is the real home.

## 4. Proposing a rule the tool already has

**Recurred four times**: `cargo target/`, `.mypy_cache`, an `orca` keep-rule, a Docker image entry.
Each was "found" on a real machine and nearly re-added, though the tool already handled it — in one
case with 51 existing references.

The `orca` case is the instructive one: the proposed keep-rule was redundant because the generic
Electron sweep whitelists only canonical cache subfolder *names*, so it **cannot** reach an app's
session data by construction. The existing design was stronger than the proposed patch.

**Rule.** `grep scree.sh` before writing a rule. Finding something on one machine is not evidence
that the tool misses it. Prefer strengthening a generic mechanism over adding a named special case.

## 5. `find` / `ls` output word-splits on real paths

**Recurred three times**, always on `~/Library/Application Support` — a path with a space, present
on every Mac.

`for f in $(find …)` splits on whitespace, so one path becomes two non-existent ones.

**Rule.** `find … -print0` piped into `while IFS= read -r -d ''`. Never parse `ls`. Never iterate
unquoted command substitution.

## 6. `$(( x + $(cmd) ))` aborts the whole run

When `du` printed nothing — a path racing away mid-scan, or an unreadable directory — the expansion
became `$(( x + ))` and killed the run with `bad math expression`, from inside a sweep that walks
every directory in `Application Support`. The error named neither the path nor the sweep.

**Rule.** Read into a variable first, then add with a default: `v=$(cmd); x=$(( x + ${v:-0} ))`. An
empty *variable* is `0` in zsh arithmetic; an empty *token* is a syntax error.
**Locked by:** "an empty du does not abort the --scan sweep".

## 7. An environment variable in arithmetic can flip preview into deletion

zsh evaluates a variable's **value** inside an arithmetic context, recursively, and zsh arithmetic
supports **assignment**. So `CACHE_MIN_MB='(DRY_RUN=0)'` does not produce a wrong number — it assigns
to the flag `_rm` branches on.

And `$DRY_RUN` is used as a boolean **command** (`if $DRY_RUN`), so `0` is not false-y: the shell
runs a command named `0`, fails, and falls through to the **delete** branch. A corrupted flag that
merely *looks* false deletes.

**Rule.** Validate numeric env vars as bare integers (`<->`) before any arithmetic context; freeze
`$DRY_RUN` with `typeset -r` once resolved; `_rm` demands exactly `true`/`false`.
**Locked by:** the injection loop over all three numeric vars (preview *and* `--apply` paths), and
`_rm` fail-closed on `0`, `1`, `""`, `TRUE`, `yes`.

**Corollary — guard the state, not one consumer.** The first fix guarded `_rm` only. But `$DRY_RUN`
is executed at ~30 sites and most are not `_rm` (`$DRY_RUN || chmod -R u+w`, the `sudo` sweep,
`ollama rm`, `conda env remove`). Guarding one door left the rest open.

## 8. Warnings on stdout corrupt a data contract

The unknown-flag warning went to stdout, so `scree --json --typo` emitted an unparseable document.

**Rule.** Anything that is not the data itself goes to stderr. `--json`/`--snapshot` stdout is a
contract.
**Locked by:** "unknown-flag warning goes to stderr, --json stays parseable".

## 9. `lsof` over-counts, and its flags do not mean what they look like

Two separate traps in one feature:

- `lsof` emits one record per **file descriptor** *and* per **mmap**, each carrying the file's full
  size. Summing records over-counted held bytes by **37%** on a real machine (1.66 GB vs 1.04 GB).
  Dedup on device+inode — per process for a per-process figure, **globally** for a global total,
  since one deleted inode shared by 40 processes occupies its blocks once.
- `lsof -u $USER +L1` is **26× wider** than `lsof +L1` (17,867 rows vs 676), because lsof **ORs**
  selection flags unless `-a` is given. The "narrower" query is broader and slower.
- Column position is not stable across the two output shapes: in the plain table `$7` is `SIZE/OFF`
  and `$8` is `NLINK`. A diagnostic here filtered on `$8 > 500000000` — always `0` — **matched
  nothing and still produced a plausible answer.** Use `-F` field mode and read by tag.

**Locked by:** the two dedup assertions (same inode on two descriptors; one inode across two
processes).

## 10. `du` and `ls` disagree wildly on sparse files

`Docker.raw` reads **1.0 TB** apparent (`ls`) and **8.4 GB** real (`du`). VM images, disk images and
database files are routinely sparse.

**Rule.** Always `du` for anything the user will act on. Reporting apparent size destroys trust the
first time someone checks.

## 11. Trashing is not reclaiming

`--trash` initially (a) moved `~/.Trash/x` back into `~/.Trash`, renaming instead of deleting so the
Trash could never be emptied, and (b) trashed files that the same run's empty-Trash step then
deleted — providing no undo at all.

**Rule.** A file in the Trash still occupies its blocks. Trashed bytes are counted separately from
freed bytes and never folded into the headline number. Under `--trash`, emptying the Trash is
skipped, and anything already inside it is deleted for real.

---

## Meta-lessons about the process

- **Verify before claiming.** "zsh runs the last pipeline element in a subshell" was assumed and is
  **false** in zsh (true in bash) — a five-second test prevented a wrong "fix" to working code.
- **A finding on one machine is n=1.** A 1 GB gap between the reclaim tally and `df` is *normal*; it
  was nearly "fixed" into a `df` delta, which would have made the number worse.
- **Measure before designing.** `~/Library/Application Support` at depth 4 costs ~0.4s;
  `~/Library/Containers` at depth 6 costs ~52s. That one measurement decided a generic-vs-hardcoded
  design question that argument alone could not.
- **Report-only rules can be generic; deleting rules earn a hardcoded path.** A report false positive
  costs one line of stdout. A delete false positive costs data.

## 12. A guard that is never in harm's way tests nothing

The `--apply` stress test's first version asserted that keychains, ssh keys and open databases
survived a real run. Every assertion passed. Removing the deny overlay, the download skip and the
database guard — one at a time — changed **nothing**: still all green.

The protected files survived because Tier 1 never targets those paths, not because any guard ran.
Moving them *inside* directories that Tier 1 genuinely deletes turned the test real, and it failed
immediately on two counts. Both were live bugs.

**Rule:** a safety test must place the protected thing where the deletion actually goes. If removing
the guard does not turn the test red, the test is decoration.
**Locked by:** `test/stress-apply.zsh` — the live database and the partial download sit inside
`~/.npm/_npx` and `~/.cache/node`, which are real Tier 1 targets.

## 13. Depth guesses are always too shallow

The live-database guard scanned `maxdepth 1`, which protected nothing, because Tier 1 removes whole
directories. Corrected to `maxdepth 3` on the reasoning that a database sits "one or two levels in".

Surveying the machine's actual cache trees: SQLite databases sit at **depth 6 to 10** below a cache
root. Depth 3 still missed the large majority. Depth costs nothing — `maxdepth` 3, 6 and 8 over a
real cache directory returned identical hits in 0.3–0.7s, entirely noise.

**Rule:** measure the real distribution before picking a bound. The fixture that passes is the one
built to match the assumption.
**Locked by:** stress fixtures nest at depth 6 and 4; reverting to `maxdepth 3` fails 3 assertions.

## 14. The run log must never name the wrong file

`_rm` resolved its display path in the **validation** loop, which completes over every target before
deletion begins. So the "removed:" line held the last target's value, and deleting three files
logged the third one three times. Shipped in 0.2.8.

A log that names the wrong file is worse than one that names none: it is the only record of an
irreversible act, and it was confidently wrong. It surfaced only because batched sizes were correct
while the paths were identical — the right sizes are what made the wrong paths visible.

**Rule:** anything printed about a deletion is derived at the point of deletion, never earlier.
**Locked by:** a test asserting three deleted files each appear in their own log line.

## 15. A nested helper is invisible to everything outside its parent

`_hkb` was defined inside `run_report`. Callers outside it — including `_rm`'s deletion line — got an
empty string. So did callers *earlier in `run_report` than the definition*, because a nested function
does not exist until its definition has executed. A blank appeared where a size belonged, silently.

**Rule:** helpers used by more than one caller are defined at top level, before first use.

## Meta-lessons, second set

- **Variance is evidence, not an excuse to stop.** The suite's runtime was written off as "noise
  exceeding signal" after the same command measured 7.8s, 14s, 20s and 44s. The noise *was* the
  finding: `SAFE_PATH` let `pip3` and `gem` through from `/usr/bin`, so every `--apply` ran a real
  `pip3 cache purge` (4.89s) and `gem cleanup` (2.53s) — about twelve minutes per suite, mutating
  real state no test asserted on.
- **Grep finds the bug you already imagined.** Chasing a `--report` hang, eight `du` calls were
  bounded across three attempts and a stubbed hanging `du` still produced 308s every time. The
  greps matched `du -sk` and `du -sh`; the offending call was `du -h -d 2`. Watching *where the
  output stopped* found it in one step.
- **Three wrong diagnoses beat one confident fix.** A stall was blamed on `git gc` (1.7s, measured),
  on `du` of an empty directory (3 ms, measured), and on self-inflicted process contention — before
  timing `docker info` directly, which hung for 300s. Measure the suspect, not the neighbourhood.
- **Revert an optimisation that measures worse, however good the reasoning.** Skipping the app
  sandbox container trees in the home scan was sound in theory: they are slow *and* scree never
  cleans them. It measured 437s against a 139–158s baseline. One `du` traversing once beats N
  invocations each re-walking a child. Complexity has to earn its place with a number.
- **An unexplained change that deletes real files does not ship**, regardless of motivation. C4 was
  reverted on the belief it caused real deletions; the belief was wrong, but reverting on an
  unexplained deletion was still correct. It re-landed once the cause was actually understood.
