# Architecture

## One zsh script, on purpose

dehoard is a single `dehoard.sh` file. That is a deliberate choice, not laziness:

- **The install story depends on it.** `curl -fsSL …/dehoard.sh -o dehoard.sh && chmod +x` works
  because there is exactly one file to fetch and audit. A reviewer can read the whole tool top to
  bottom before running it, important for something that deletes files.
- **No runtime dependencies.** Pure zsh plus the standard macOS userland. No package to install, no
  interpreter version to match, nothing to `pip`/`npm` first.
- **Distribution and organization are separate concerns.** "One file to ship" does not mean "one
  undifferentiated blob", the executable logic is organized into named functions with a `main()`
  dispatch (below).

## Code structure: `main()` dispatch

The top of the file is configuration, flag parsing, the safety setup, and the shared helpers
(`_ask`, `_rm`). Each run-mode is then a named function, and `main()` is the entire control flow in
a few lines, you can understand what the program does before reading a single line of deletion code:

```zsh
main() {
  (( ${@[(I)--uninstall]} || ${@[(I)--purge]} )) && _uninstall "$@"   # --purge implies uninstall; handled first
  run_report      # read-only; exits the script if --report/--json
  if ! $PICK; then
    clean_tier1     # always-safe caches
    clean_deep      # Tier 2 (self-guards on $DEEP)
    clean_models    # self-guards on $MODELS
  fi
  run_scan        # self-guards on $SCAN; under --pick this is the sole deleter (one fzf picker per category)
  print_result
}
main "$@"
```

(That block is the actual dispatch from `dehoard.sh`, lightly trimmed of inline comments.)

Each cleanup function self-guards on its flag, so the dispatch reads top-to-bottom in execution
order. `--pick` is interactive-only, so `main()` skips the
batch cleaners and runs only `run_scan`, whose candidates go into one `fzf` picker per category
(biggest first) instead of the automatic Tier 1 sweep. The ~480-line `--help` text lives in a single `usage()` heredoc rather than hundreds of
`echo` statements, so it never buries the logic. Every path dehoard removes itself still routes
through the one `_rm` primitive (below); the function split changes organization, never the deletion
contract. (The sole delegation is `--scan --pick` handing an environment to its native manager,
conda/uv/sdkmanager/cargo, with an `_rm` fallback.)

## The tier model

dehoard's behavior is organized into tiers and modes. Tier 1 always runs; everything else is opt-in
via a flag. The read-only modes (`--report`, `--json`) are a separate branch that never deletes, and
`--pick` is interactive-only: it skips the batch tiers and runs only the scan picker.

```mermaid
flowchart TD
    Start([dehoard invoked]) --> RO{"--report / --json ?"}
    RO -- yes --> Audit[read-only audit / inventory<br/>deletes nothing] --> End([exit])
    RO -- no --> PK{"--pick ?"}
    PK -- yes --> Pick["scan picker only<br/>(interactive · skips Tier 1/2/models)"] --> Res
    PK -- no --> T1["Tier 1, always-safe caches<br/>(runs every time)"]
    T1 --> D{"--deep ?"}
    D -- yes --> T2["Tier 2, aggressive caches<br/>(Library caches, Xcode, Docker prune, git gc)"]
    D -- no --> M
    T2 --> M{"--models ?"}
    M -- yes --> Mdl["interactive LLM/ML weight cleanup"]
    M -- no --> S
    Mdl --> S{"--scan ?"}
    S -- yes --> Scan["project-artifact scan<br/>+ orphaned tools + generic cache sweep"]
    S -- no --> Res
    Scan --> Res[report freed space]
    Res --> End
```

- **Tier 1 (always):** regenerable caches with zero consequences (browser update clones, package
  manager caches, temp files, Trash). Safe to run anytime.
- **Tier 2 (`--deep`):** caches with a real but minor cost (a rebuild, a re-download). Library
  caches, Xcode DerivedData, Docker prune, large-repo `git gc`, etc.
- **`--models`:** interactive removal of LLM/ML weights, **per tool** (lists a tool's models, then one
  confirm before clearing that tool's set). Weights are not cheaply regenerable (slow/gated re-download,
  sometimes irreplaceable), so they are never swept by the other tiers and never enter the `--pick`
  picker, removal always requires this explicit, opt-in confirmation.
- **`--scan`:** crawls your project tree for regenerable artifacts (venvs, `node_modules`, build
  dirs), detects orphaned dev/ML tool data, and size-ranks remaining caches.
- **`--scan --pick`:** the same crawl, but interactive-only. Instead of prompting per item (and
  instead of the Tier 1 sweep), it `_register`s every candidate and presents them in one `fzf` picker
  **per category** (biggest first), deleting only what you mark in each. Needs `--apply`; falls back to
  the per-item prompts when `fzf` is absent.

The exact items in each tier are inventoried in [CLEANS.md](CLEANS.md), and the canonical source is
`dehoard --help`, which explains every item and why it's safe.

## How a deletion flows

Whatever requests a delete, it always passes the same gates: the **ignore list** check, the
**preview→apply** gate, an optional **confirmation** (interactive modes), and the central **`_rm`
safe-root guard**. That guard and the full run flow are diagrammed in
[SAFETY.md](SAFETY.md#the-_rm-safe-root-guard) and the [main README](../README.md#how-a-run-works).
Routing every path deletion through one guarded primitive is what lets dozens of independent cleanup
rules stay safe without each re-implementing the safety checks. (The `--scan --pick` picker may hand
an environment to its native uninstaller instead, which manages its own files and falls back to `_rm`.)

## Design principles

- **Preview-by-default.** Safe is the default; deletion is opt-in. (See [SAFETY.md](SAFETY.md).)
- **Generic structural rules over hardcoded lists.** Where a pattern exists, dehoard matches on it
  instead of enumerating names, e.g. Python environments are detected by the presence of
  `pyvenv.cfg` (any folder name), and Electron app caches are matched by their canonical Chromium
  cache subfolder names rather than a fixed app list. This covers tools no rule names yet, and tools
  that don't exist yet.
- **Report, never auto-delete user data.** Anything that might be data a user cares about (model
  weights, the Docker disk image, orphaned tool data) is reported, not silently removed.
- **One central delete primitive.** Nearly all path removals go through `_rm` with its safe-root
  whitelist. A few audited, `--apply`-gated exceptions delete outside it: `--deep`'s root-owned
  system-cache `sudo rm`, `--models`' `ollama rm`, the `--scan --pick` env-manager native uninstallers
  (with an `_rm` fallback), and `--uninstall`/`--purge` removing dehoard's own footprint (fixed
  `$HOME`-relative paths). New code must not add a deleter of user cleanup paths outside `_rm`; these
  are the exhaustive set.

## Anatomy of a scanner

Adding support for a new tool means adding a *scanner*: a small block that finds regenerable paths
and offers them for deletion. The shape is consistent:

```mermaid
flowchart LR
    A[detect: does the tool exist?<br/>existence check, never assume] --> B[enumerate candidate paths<br/>regenerable cache/artifacts only]
    B --> C{is it user data?<br/>weights / outputs / history}
    C -- yes --> K[KEEP · report only]
    C -- no --> P[preview line]
    P --> R["delete via _rm (never raw rm)"]
```

Checklist for a new scanner:

1. **Drive off existence checks.** Use `command -v <tool>` or a path test; never assume a tool is
   installed. (CI also rejects any hardcoded `/Users/<name>` path.)
2. **Only target regenerable data.** If a path holds weights, outputs, or session/chat history,
   *keep* it and at most report it, never delete it.
3. **Delete only through `_rm`.** Never call `rm` directly; `_rm` enforces the safe-root whitelist
   and the dry-run/preview behavior for free.
4. **Prefer a structural rule** (a marker file, a canonical subfolder name) over hardcoding an app
   name, so the scanner generalizes.
5. **Add a fixture test** in `test/run.zsh` proving it deletes the cache but keeps adjacent user
   data. The suite is the safety contract; a scanner isn't done until it's covered.
6. **Support `--pick` if the section deletes per-path.** Guard the per-item loop with
   `if $_COLLECT; then _register <type> <category> <hint> <note> <paths…>; else <existing loop>; fi`.
   `_COLLECT` is true only under `--pick` + `fzf` + `--apply`; the registered items surface in the
   one `_run_picker`. Use `type` `rm` for a plain delete, or `conda`/`uv`/`android`/`cargo` to route
   through the native uninstaller. Tiny-file noise and user data stay out of the picker.

## Roadmap

Direction for future versions (not yet built):

- **Report-driven, per-model removal.** Today `--models` removes weights *per tool* (clear all of
  Ollama, wipe the whole HuggingFace cache). The cross-tool duplicate report (see
  [MODELS.md](MODELS.md)) identifies *individual* redundant copies but has no removal path that acts
  on them. The planned design: a safe, dedup-guided selector that offers only the provably-redundant
  copies and **never the last copy of a model**, plus per-model selection for the curated libraries
  (Ollama, LM Studio). The framework caches (HuggingFace, NLTK, PyTorch hub) stay whole-cache wipes,
  they regenerate. This would also surface a `last_used` signal so old models are easy to spot.
- **Recoverability** (`--restore` / opt-in `--quarantine`): every deletion answers "how do I get it
  back?", by re-creation recipe where possible, by quarantine for the expensive tier.

These carry real deletion risk and earn their own test surface, so they ship after the current
preview-first foundation, not bundled into it.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the contribution workflow.
