# scree documentation

`scree` is a single, auditable zsh script that reclaims disk space on ML/dev Macs while refusing
to touch your real data. These pages explain how it works and why it's safe to run.

Start with the [main README](../README.md) for install and quickstart, then dig into:

| Page | What's in it |
|---|---|
| **[SAFETY.md](SAFETY.md)** | The deletion contract, the `_rm` safe-root guard, the ignore list, and the test suite that enforces it all. Read this before you `--apply`. |
| **[ARCHITECTURE.md](ARCHITECTURE.md)** | Why it's one zsh file, the tier model and run flow, and **Anatomy of a scanner**, how to add support for a new tool. |
| **[MODELS.md](MODELS.md)** | Where local LLMs actually live on a Mac, how cross-tool duplicate detection works, and the `--json` inventory schema. |
| **[LESSONS.md](LESSONS.md)** | An incident ledger: defects that actually shipped or were actually caught here, each with the rule that prevents a repeat and the test that locks it. Read before adding a cleanup rule, a size calculation, or a test. |
| **[RULES.md](RULES.md)** | The rules by which scree decides something is safe to delete, and the rules any future cleanup addition must obey. The safe-root list here is kept in sync with `_rm` by a test. |
| **[CLEANS.md](CLEANS.md)** | The exhaustive inventory of every item each mode cleans (the long tables kept out of the README). |
| **[PHILOSOPHY.md](PHILOSOPHY.md)** | The stance behind the tool: why trust is the only feature that matters, why it stays small on purpose, and why it grows by demand. |

> Canonical source of truth for *what gets deleted* is the tool itself: `scree --help` (every item
> with its rationale) and `scree --report` (what's actually on your machine). These docs describe
> **invariants and design**, not a hand-maintained copy of those lists.
