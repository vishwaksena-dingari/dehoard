# Contributing to dehoard

Thanks for your interest! `dehoard` is a single auditable zsh script, small, safe, and focused.

## Principles (please respect these in PRs)

1. **Preview by default.** Nothing deletes without `--apply`. Every new cleanup path must go
   through the `_rm` helper (which is preview-aware and guards `$HOME` / `/`).
2. **Only regenerable data.** We delete caches, build artifacts, downloadable model weights, and
   editor-flagged stale versions, never user source, git history, documents, or media.
3. **Machine-agnostic.** No hardcoded usernames, personal paths, or personal app bundle IDs.
   Drive everything off existence checks. CI rejects `/Users/<name>` paths.
4. **Stay in the niche.** `dehoard` is for ML/dev Macs. We are *not* adding Photos/Mail/iOS-backup
   cleanup, that's CleanMyMac's lane and a different trust model.
5. **Explain why it's safe.** Every item in `--help` says what it is, why it's safe to remove, and
   how it regenerates. New features must document this.

## Adding a cleanup target

- Detect by **content/manifest** where possible (e.g. venvs via `pyvenv.cfg`, editors via
  `.obsolete`), not by hardcoded names.
- Add it to the right tier: Tier 1 (always safe), `--deep` (real but recoverable cost),
  `--models` (ML weights), or `--scan` (per-project, interactive).
- Add a `--help` entry and a `--report` line if it's sizable.

## Testing

```sh
zsh -n dehoard.sh                 # syntax
zsh dehoard.sh --report           # read-only audit
zsh dehoard.sh --scan             # preview (deletes nothing without --apply)
grep -nE '/Users/[a-z]' dehoard.sh   # must be empty
```

Open an issue first for anything large. Thanks!

## License of contributions

By submitting a contribution you agree it is licensed under the project's [MIT License](LICENSE),
and you grant the maintainer the right to relicense it as part of the project in the future.
