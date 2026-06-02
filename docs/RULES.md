# dehoard rules and scope

The rules by which dehoard decides what is safe to delete. This is the safety contract for an
auditable tool that runs `rm`. It describes how the tool behaves today. The final section states the
rules any future cleanup additions must obey, and is marked as not yet machine-enforced.

This document governs `dehoard.sh` only. It contains no personal paths and no strategy, by design.

## Scope

dehoard reclaims disk on developer and ML machines by removing regenerable junk: package-manager
download caches, build artifacts, virtual environments, compiler and GPU caches, container disk
images, editor leftovers, and similar. It also reports, but never deletes, the local LLM/ML model
weights spread across tools.

Out of scope: general application uninstalling, a whole `~/Library` sweep, and non-developer space
hogs (Photos, iOS backups, Mail). Those need a different trust model and are a different tool's job.

`~/cleanup.sh` is a separate, private tool on its own track. It uses hardcoded personal paths and
deletes by default. It is never a source for dehoard: do not ingest it, merge from it, or model new
rules on it. A rule that came from it could leak a personal path or carry delete-by-default behavior
into the public tool.

## What is safe to delete

A path is safe to delete only when both hold:

1. It is **regenerable**. The system recreates it on next use, it can be re-downloaded, or it can be
   rebuilt from source that dehoard does not touch. Examples: a package download cache, a compiler
   cache, a build directory, a `.ipynb_checkpoints` folder.
2. It is **under a safe root** (see the `_rm` contract below).

An **orphaned** tool directory qualifies as a leftover only when both the tool's binary and its
`.app` are absent. A path that is merely old, or large, or unrecognized does not qualify.

Never deletable. The following are user data. dehoard detects and reports them, and never removes
them automatically: model weights, model outputs, chat and session history, source code, git
history, and configuration files. Anything non-regenerable is reported, not deleted.

## Hard rules

1. **No hardcoded personal paths.** Every path is `$HOME`-relative or configurable. CI rejects
   machine-specific paths.
2. **Preview by default.** A plain run prints what it would delete and removes nothing. Deletion
   happens only under `--apply`. `--dry-run` forces preview even when `--apply` is also passed.
3. **Never auto-delete user data.** Model weights and session data are reported, never removed
   without an explicit, per-item choice.
4. **Refuse to run as root.** The tool exits rather than touch system-owned files.
5. **Everything deletes through `_rm`.** There is one delete primitive. No code path calls `rm`
   directly, and no new delete primitive is added.

## The `_rm` contract

`_rm` is the only function that deletes. It enforces:

- **Fail-closed.** If the dry-run safety flag is unset, `_rm` refuses and deletes nothing, rather
  than risk deleting in what the user believes is preview.
- **Hard stops.** It refuses an empty or unset target, bare `/`, and `$HOME` itself.
- **Safe-root whitelist.** A target is deleted only when it falls under one of these roots.
  Anything outside them is refused, even if a temp variable is mis-set.

<!-- safe-roots:begin (parsed by test/run.zsh against _rm in dehoard.sh; keep this list in sync) -->
- `$HOME`
- `/var/folders`
- `/private/var/folders`
- `/tmp`
- `/private/tmp`
<!-- safe-roots:end -->

Under `--apply`, `_rm` echoes each removed path and its size as it goes, and appends the same record
to a deletion log under `~/.cache/dehoard/`.

## The `_ai_clean` pattern

Per-tool cleanups use one helper with a fixed shape:

```
_ai_clean "LABEL"  <clean-globs>  --  <keep-globs>
```

- Paths before `--` are regenerable caches. They are listed, then deleted through `_rm` after the
  user confirms.
- Paths after `--` are user data. They are reported as kept, and never deleted.
- Globbing runs under `NULL_GLOB`, so a pattern that matches nothing is dropped rather than passed
  through literally.

This keeps the clean set and the keep set explicit and side by side for every tool.

## Tiers

- **Tier 1** (bare run, or `--apply`): always-safe regenerable caches, cleaned as a batch behind the
  preview/apply gate.
- **`--deep`**: Tier 2, more aggressive caches with a real but minor rebuild or re-download cost.
- **`--models`**: interactive, per-item cleanup of LLM/ML weights. Weights are user data, so they
  are never batch-deleted.
- **`--scan`**: interactive crawl of project artifacts (virtual environments, `node_modules`, build
  directories, editor leftovers, orphaned tool data).
- **`--report` / `--json`**: read-only audit and machine-readable inventory. They delete nothing.

## Rules any future cleanup generation must obey (not yet enforced)

This section is forward-looking. There is no script-generating integration today, and nothing below
is enforced in code yet. It is written so that any future addition, whether proposed by a person or
by an assisted tool, stays inside the safety envelope above.

- A proposed cleanup is **data, not code**: a label, a set of clean-globs, and a set of keep-globs,
  in the `_ai_clean` shape. It is not freeform shell, and it never introduces a new delete call.
- Every deletion still routes through `_rm` and inherits the safe-root whitelist. A proposal cannot
  widen that whitelist.
- Output is **preview-first** and merged by a human. The proposing tool does not execute deletions.
- A proposal is **refused** when it would: target non-regenerable user data; reach a path outside
  the safe roots; require a raw `rm` or any delete outside `_rm`; or require a hardcoded personal
  path. The refusal states which rule it violated.

When this becomes real, the safe-root list above is the boundary to validate against, and the
refusal triggers are the first tests to write.

## See also

- [SAFETY.md](SAFETY.md): the safety model, the `_rm` guard, and the test suite.
- [ARCHITECTURE.md](ARCHITECTURE.md): the tier model and how to add a cleanup scanner.
