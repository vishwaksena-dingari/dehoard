# What dehoard cleans

> **Canonical source of truth:** run `dehoard --help` for the complete, current list with the
> "why it's safe / how it comes back" rationale for **every** item, and `dehoard --report` to see
> what's actually on *your* machine. This page is a human-readable map organized by mode; the tool
> itself is authoritative, so when in doubt, trust `--help`.

Everything below is **regenerable**: caches, build outputs, and re-downloadable assets. dehoard
detects and **keeps** your real data (model weights, generated outputs, chat/session history, source,
git, configs). Nothing here is deleted without `--apply`.

## Tier 1: always-safe (runs every time, batch-cleaned; skipped under `--pick`)

Zero-consequence, regenerable junk:

- **Browser update clones**: `*.code_sign_clone` left in temp by Chromium-based browsers during updates.
- **Screenshot staging dirs** and other stale `TMPDIR` leftovers (updater temp, profiler dumps, perf data).
- **Browser helper render caches** under the per-user darwin cache dir.
- **Package-manager download caches**: Homebrew (`cleanup`/`autoremove`), npm, pnpm, yarn, pip (all
  Python versions), uv, bun, trunk. Your installed packages are not removed, only cached downloads.
- **Language tool caches**: node-gyp, npx binary cache, Node compile cache, fontconfig, CPAN,
  Selenium drivers, Gradle, Maven (`~/.m2/repository`), NuGet, Go module cache, Cargo download caches.
- **Jupyter** `.ipynb_checkpoints` (not your notebooks).
- **Old installer DMGs** in `~/Downloads` (only > 30 days old **and** > 50 MB; shown before deleting).
- **Trash** and old iOS device crash logs.
- **Time Machine local snapshots**: all but the newest (kept as a safety net). Requires sudo.

## Tier 2: `--deep` (real but minor cost: a rebuild or re-download)

- **All user Library caches** (`~/Library/Caches/*`).
- **Compiler/GPU caches**: Clang module cache, Python bytecode cache, Metal shader cache, ccache.
- **Apple system caches** scoped to your own UID (requires sudo).
- **Xcode DerivedData** (compiled build products; source untouched).
- **Docker**: `system prune` + `builder prune`; also reports the Docker/OrbStack/Colima disk-image
  size (those `.raw`/`.img` files never shrink on their own, reported, never auto-deleted).
- **HuggingFace cache** (`~/.cache/huggingface`), re-downloads on next use.
- **Playwright / Puppeteer** browser binaries.
- **Unavailable iOS simulators** + CoreSimulator caches.
- **VS Code, Cursor, and Discord caches** in Application Support (specific cache subfolders only;
  `User/` settings and storage are kept). *(The generic, app-agnostic Electron cache sweep lives
  in `--scan`, below.)*
- **Android SDK system-images**: reported with sizes (informational; remove per API level via `--scan`).
- **`git gc`** on large repos (`.git` > 100 MB), same prune policy as git's own default.

## `--models`: interactive LLM/ML weight cleanup

Per-tool prompts: each tool lists its models with sizes, then asks once before clearing that tool's
set (weights are user data, never auto-deleted or swept by Tier 1 / `--scan`):

- **Ollama** models (via `ollama rm`), **LM Studio** `.gguf` files, **HuggingFace** cache,
  **NLTK** corpora, **PyTorch** hub cache.

See [MODELS.md](MODELS.md) for how the cross-tool duplicate inventory (`--report` / `--json`)
identifies which copies are redundant before you decide.

## `--scan`: project artifacts (interactive crawl of your tree)

Per-entry prompts for environments; batch prompts for clearly-safe artifacts:

- **Python environments**: venvs (detected by `pyvenv.cfg`, any folder name), conda envs.
- **uv Python installations**: whole interpreters under `${UV_PYTHON_INSTALL_DIR:-~/.local/share/uv/python}`, removed via `uv python uninstall` (distinct from venvs above).
- **Build caches & artifacts**: `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`,
  `*.egg-info`, stray `.pyc`; Rust `target/` (validated by sibling `Cargo.toml`); `dist/`/`build/`/
  CMake build dirs; test/coverage artifacts (`.coverage`, `htmlcov/`, `.tox/`, `.nox/`).
- **`node_modules`** directories (IDE-bundled ones excluded).
- **JVM heap dumps** (`*.hprof`), **ROS2 colcon** `build/install/log`, **Android SDK system-images**.
- **Editor cruft**: VS Code-family stale extension versions (via each editor's own `.obsolete`
  manifest, never the active version), editor swap/backup files.
- **LaTeX compilation artifacts**: `.aux`, `.toc`, `.lot`, `.lof`, `.bbl`, `.blg`, `.nav`, `.snm`,
  `.fls`, `.fdb_latexmk`, `.synctex.gz`. Safe, regenerated on the next compile; your `.tex` is untouched.
- **R session artifacts**: `.RData`, `.Rhistory`, `.Rapp.history`, `Rplots.pdf`. ⚠️ `.RData` can hold
  work you care about; dehoard lists files before asking, review before confirming.
- **IPython command history**: `~/.ipython/profile_default/history.sqlite`. ⚠️ This is your personal
  command history, not a cache; deletion is permanent. Surfaced only so you can decide consciously.
- **AI/local-model tool caches**: regenerable temp/cache only; models, outputs, and session history
  are shown as kept.
- **MATLAB**: clears logs, crash dumps, and download caches only. The installed ServiceHost runtime
  is left alone (deleting it would just force a re-download on the next launch, so it is not durably
  reclaimable). Prefs, command history, Add-Ons, license, and `~/Documents/MATLAB` are reported as
  kept, never deleted. No re-download or re-login.
- **Electron app caches**: a generic, app-agnostic sweep of canonical Chromium cache subfolders
  (`Cache`, `Code Cache`, `GPUCache`, `CachedData`, …) under `~/Library/Application Support/*` and
  stale `Saved Application State`; `Local Storage` / `IndexedDB` / databases (user data) are never
  touched. Covers any Electron app, including ones no rule names.
- **Orphaned dev/ML tool data**: leftover dirs whose tool binary/app is gone (per-entry confirm).
- **macOS junk**: `.DS_Store`, AppleDouble files, stray Windows artifacts.
- **Large project logs** (system logs excluded).
- **Generic cache sweep**: size-ranks everything in `~/.cache` and `~/Library/Caches` over
  `CACHE_MIN_MB` (default 100 MB) and prompts per entry. This catch-all covers tools no rule names,
  including ones that don't exist yet.

> ⚠️ A few `--scan` items can hold things you care about (e.g. `.RData`, IPython history, a `dist/`
> some projects commit). dehoard lists them before asking and flags them with a warning, review the
> list before confirming.

### `--scan --pick`: one picker per category

With `--pick` (plus `--apply` and `fzf` installed), the per-entry and batch prompts above are
replaced by an `fzf` picker **per category**, opened one at a time, **biggest category first**. A
per-category summary (count + size) prints first as a contents page. In each category's picker: TAB
marks items, Ctrl-A all / Ctrl-D none, Enter confirms, and **Esc skips that whole category**; the
preview pane shows the recreate hint and any caveat (so the `.RData` / `dist/` warning above travels
with the item). After you mark a category, dehoard reprints the marked set and asks once, then deletes
just that category before moving to the next, so each category is a self-contained unit (Ctrl-C after
the big ones keeps what you already cleared). It is interactive-only, so it does **not** run the Tier 1
sweep; an empty selection or Esc deletes nothing; environment managers (conda/uv/Android/Rust) are
removed via their native uninstaller. Tiny-file noise (`.DS_Store`, stray `.pyc`, LaTeX aux, IPython
history) and model weights are not picker categories, so under `--pick` they are **skipped** (a note
points you to plain `--scan` to clean them) rather than deleted inline behind the picker. Without
`fzf`, `--pick` falls back to the per-item prompts described above.
