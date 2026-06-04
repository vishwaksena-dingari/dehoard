# Design philosophy

`dehoard` deletes files, so its design is built around one priority: not deleting the wrong thing.
This page explains the stance behind the tool, and why it stays small on purpose.

## Trust is the only feature that matters

A disk cleaner is worthless if you do not trust it, because the cost of a mistake is your data, not
a stack trace. So the whole tool is built to be trusted by a stranger reading it for the first time,
not just by its author:

- **Preview by default.** A bare `dehoard` run, and any run without `--apply`, deletes nothing. You
  see the exact list first. Deletion is something you opt into, never something that happens because
  you forgot a flag.
- **One guarded delete primitive.** Nearly every path removal flows through a single function, `_rm`,
  which fails closed, refuses `/` and `$HOME`, and enforces a small safe-root whitelist. A cleanup
  rule cannot widen what is deletable; it can only feed candidates into the guard. The short list of
  audited exceptions is documented in [SAFETY.md](SAFETY.md), and the rule is: new code adds none.
- **Only regenerable data.** dehoard targets caches, build artifacts, and re-downloadable assets, the
  things that come back on their own or with one command. Source code, configuration, and model
  weights are detected and kept, reported but never removed automatically.
- **It is readable.** It is one zsh file you can read end to end before you run it. The safety claims
  are not a promise in a README; they are pinned by a test suite that runs against a throwaway `$HOME`
  and proves that `--apply` leaves your data intact.

## Small on purpose

The easy way to make a tool look impressive is to add features. For a deleter, that instinct is
backwards. Every new feature is new code that can have a bug, in a tool whose job is destruction.
More surface area is less trust, not more.

So dehoard grows by demand, not by ambition:

- A feature ships when a real need pulls it in, not because it would be neat to have.
- The default path is the safe, boring one that most people actually want (regenerable caches, shown
  first). Power-user surface like the interactive picker is opt-in, never the default.
- Recoverability, broader platform support, and richer model management are real ideas, but each is a
  new way to lose or mishandle data, so each waits until it is genuinely needed and arrives with its
  own tests and a real-machine trial. Restraint is the responsible default for an `rm` tool.

## Transparency over authority

dehoard does not ask you to trust it because it is clever. It earns trust by showing its work: what
it will delete, what it is keeping and why, how much space each item frees, and a log of everything
it actually removed. The read-only modes (`--report`, `--json`) let you inspect your own machine
without any risk of deletion at all.

The goal is a tool you can hand to someone who has never seen it, who can read it, run it in preview,
and understand exactly what it will do before a single byte is gone.

See [SAFETY.md](SAFETY.md) for the enforced contract and [ARCHITECTURE.md](ARCHITECTURE.md) for how
the pieces fit together.
