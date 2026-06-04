#!/usr/bin/env zsh
# dehoard: disk reclaimer for ML/dev Macs (zsh, macOS). https://github.com/vishwaksena-dingari/dehoard
# Run under zsh defaults regardless of the user's ~/.zshenv (which IS sourced for `zsh dehoard.sh`).
# This neutralizes options a user may have set globally (KSH_ARRAYS, SH_WORD_SPLIT, ...) that would
# otherwise corrupt array indexing / globbing and silently produce invalid --json or skip space-paths.
emulate zsh
# Unmatched globs expand to nothing instead of erroring (e.g. empty Trash, no screenshots).
# The one non-default option dehoard relies on, re-applied after `emulate` resets options.
setopt NULL_GLOB

# Version, keep in sync with the CHANGELOG release heading and the git tag.
DEHOARD_VERSION="0.2.6"

# ─── USER CONFIG ────────────────────────────────────────────────────────────
# Extra directories to include when scanning for projects (git gc, etc.).
# Add your own workspace roots here, e.g. EXTRA_SCAN_DIRS=(~/work ~/code).
EXTRA_SCAN_DIRS=()
# Standard project roots scanned for large-repo git gc (override freely):
GIT_GC_ROOTS=(~/Documents ~/src ~/Desktop ~/Developer "${EXTRA_SCAN_DIRS[@]}")
# Generic cache sweep (report + --scan): ignore cache dirs smaller than this many MB.
# Env-overridable, e.g.  CACHE_MIN_MB=250 dehoard --scan
: ${CACHE_MIN_MB:=100}
# Wall-clock timeout (seconds) for each external package-manager cleanup (brew/npm/yarn/
# trunk/...). Guards against a single tool hanging the whole run. Env-overridable:
#   DEHOARD_PM_TIMEOUT=300 dehoard --apply
: ${DEHOARD_PM_TIMEOUT:=120}
# Set to 'true' to make --apply the default so you don't have to type it every run.
# Add  export DEHOARD_APPLY_DEFAULT=true  to your ~/.zshrc to make it permanent.
# Override back to safe preview for a single run:  DEHOARD_APPLY_DEFAULT=false dehoard
: ${DEHOARD_APPLY_DEFAULT:=false}
# Set to 'false' to disable the ignore list entirely, no "Always skip?" prompts will
# appear, the ignore file will never be written, and any existing file is ignored.
# Useful if you want a fully stateless tool or manage exclusions another way.
: ${DEHOARD_IGNORE_ENABLED:=true}
# ─────────────────────────────────────────────────────────────────────────────

# Safety: must not run as root, breaks Homebrew, npm, pip
if [[ $EUID -eq 0 ]]; then
  echo "❌ Do not run this script as root (sudo zsh dehoard.sh)."
  echo "   It breaks Homebrew, npm, and pip. Run as your normal user."
  exit 1
fi

# Usage (preview-by-default, nothing deleted without --apply):
#   dehoard                        → Tier 1 preview (always safe)
#   dehoard --apply                → Tier 1, actually reclaim
#   dehoard --deep                 → + Tier 2 (urgent space needed)
#   dehoard --models               → + interactive LLM model cleanup
#   dehoard --scan                 → + interactive environment/artifact scan
#   dehoard --report               → read-only disk audit
#   dehoard --deep --models --scan --apply → everything, for real

# ── Help text (heredoc; the --help dispatch is just below) ──
usage() {
cat <<'DEHOARD_HELP'

╔══════════════════════════════════════════════════════════════╗
║                    dehoard  reclaimer                       ║
╚══════════════════════════════════════════════════════════════╝

USAGE   (preview-by-default: NOTHING is deleted without --apply)
  dehoard                          → PREVIEW Tier 1 (always-safe) cleanup
  dehoard --apply                  → actually reclaim Tier 1 space
  dehoard --deep                   → + Tier 2 aggressive caches (preview)
  dehoard --models                 → + interactive LLM/ML model cleanup
  dehoard --scan                   → + interactive project artifact scan
  dehoard --report                 → read-only disk audit (what's eating space)
    ↳ bare 'dehoard' PREVIEWS the cleanup; '--report' AUDITS your disk. Neither deletes.
  dehoard --deep --models --scan --apply → everything, for real

FLAGS
  --apply         actually delete (default is preview-only)
  --dry-run       force preview, overrides --apply and DEHOARD_APPLY_DEFAULT
  --yes / -y      auto-confirm every prompt (combine with --apply; use with care)
  --pick          interactive fzf picker for --scan candidates: ONE picker per category, biggest first
                  (implies --scan; needs fzf + --apply). Interactive-only: runs JUST the pickers, not
                  the Tier 1 auto-sweep. In each category: TAB mark, Ctrl-A all, Ctrl-D none, Enter to
                  confirm, Esc skips that category; the preview shows size/last-modified/recreate/caveat.
                  Falls back to per-item prompts without fzf; under --dry-run it just previews the list.
  --report        read-only audit; never deletes
  --json          machine-readable model inventory (implies --report; pure JSON on stdout)
                  e.g. dehoard --json | jq '.cross_tool_duplicates'
  --list-ignored       show paths you've marked 'always skip'
  --unignore <path>    remove one path from the always-skip list
  --reset-ignore       clear the entire always-skip list and re-prompt everything
  --uninstall          remove dehoard: the deletion logs (~/.cache/dehoard) and the script. Keeps
                       your ignore list (~/.config/dehoard); preview-first, --dry-run to see the plan
  --purge              like --uninstall, but ALSO removes your ignore list (prints it first)
  --version / -V       print version and exit

Flags combine in any order. Without --apply, every run is a safe preview.
Recommended: run once to preview, then add --apply. Tier 1 always runs first.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TIER 1: Runs always. Regenerable caches, safe to run anytime (large package-manager
        caches like Maven/Gradle re-download on the next build).
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. Browser update clones
     Chromium-based browsers (Chrome, Brave, Arc, Edge, Vivaldi, …) silently
     clone themselves to a temp dir during updates for code signing. These
     are supposed to self-delete but often never do, accumulating 5+ GB.
     Script deletes: ${BASE}/X/*.code_sign_clone  (any browser, not hardcoded)
     → Close your browser before running to avoid file-in-use errors.

  2. Screenshot temp dirs (NSIRD_screencaptureui_*)
     Every macOS screenshot session creates a staging folder under
     TMPDIR/TemporaryItems/. These are never cleaned up by the OS.
     Completely safe to delete, they're already closed sessions.

  3. Stale app temp files (TMPDIR)
     Microsoft Edge updater leftovers, VS Code CPU profiler dumps,
     Java perf data (hsperfdata_*), node compile cache, Xcode CLI
     cache, VS Code feedback logs. All are orphaned and never reused.

  4. Browser helper caches in var/folders
     macOS stores per-app render caches under /private/var/folders.
     Cleaned: Chrome / Brave / Edge browser helper caches (universal).
     Every browser rebuilds these on next launch with no slowdown.
     Other per-app caches are handled by --deep / the --scan cache sweep.

  5. Package manager caches
     brew cleanup -s --prune=all → old Homebrew formula versions + download cache
     brew autoremove             → removes Homebrew orphan dependencies
     npm cache clean             → clears npm download cache
     pnpm store prune            → removes unreferenced pnpm packages
     yarn cache clean            → clears Yarn download cache
     pip / pip3.7-3.25 purge     → clears wheel cache for all Python versions
     uv cache clean              → clears uv's package/wheel cache
     bun pm cache rm             → clears Bun's install cache
     trunk cache prune           → clears Trunk linter/tool cache
     In all cases: your installed packages are NOT removed.
     Only cached downloads are cleared; re-installing re-downloads them once.

  6. node-gyp cache (~/Library/Caches/node-gyp)
     node-gyp downloads C header files to compile native Node modules.
     These are permanently cached even after the module is installed.
     Rebuilt automatically on the next native npm install.

  6b. Node.js compile cache (~/.cache/node)
     Node.js caches native addon compilation results. Pure cache.

  6c. fontconfig cache (~/.cache/fontconfig)
     Font rendering lookup database. Rebuilt by apps on next launch.

  6d. npx binary cache (~/.npm/_npx)
     npx caches downloaded executables (e.g. create-react-app, ts-node)
     separately from npm's package cache. npm cache clean does not touch it.
     Re-downloaded transparently on next npx invocation.

  6e. CPAN module cache (~/.cpan/build, ~/.cpan/sources)
     Perl's CPAN caches downloaded module tarballs and build intermediates.
     Pure cache, re-downloaded on next 'cpan install Module::Name'.

  6f. Selenium WebDriver cache (~/.cache/selenium)
     Selenium's manager downloads ChromeDriver and other WebDriver binaries
     here. Pure cache, re-downloaded automatically on next test run.

  7. Go module download cache (~/go/pkg/mod/cache)
     Go caches every downloaded module dependency here. Pure cache,
     equivalent to npm's ~/.npm or pip's wheel cache.
     Re-downloaded automatically on next 'go build' or 'go get'.
     Uses 'go clean -modcache' when Go is available, else rm directly.

  8. Cargo download caches (~/.cargo/registry/cache, /src, /git/checkouts)
     Rust/Cargo caches downloaded .crate files and their unpacked sources.
     registry/cache  → compressed .crate tarballs (re-downloaded on next build)
     registry/src    → unpacked crate sources   (re-extracted on next build)
     git/checkouts   → working copies of git-sourced deps (re-cloned on next build)
     registry/index is preserved to avoid a slow re-index.
     No-op if ~/.cargo does not exist.

  8b. Gradle caches (~/.gradle/caches, ~/.gradle/daemon)
     Gradle build system caches downloaded artifacts and daemon logs.
     ~/.gradle/wrapper/dists (Gradle distributions) is preserved.
     Re-downloaded on next Gradle build.

  8c. Maven local repository (~/.m2/repository)
     Maven caches ALL downloaded JARs here. Pure cache, re-downloaded
     on next 'mvn' invocation. Can be 2-20 GB on active Java projects.

  8d. NuGet package cache (~/.nuget/packages)
     .NET's global package cache. Re-downloaded on next 'dotnet restore'.
     Note: ~/.dotnet (the SDK itself) is deliberately NOT touched.

  9. Jupyter checkpoint dirs (.ipynb_checkpoints)
     Jupyter saves a checkpoint copy of every open notebook every
     few minutes into a hidden .ipynb_checkpoints folder. When you
     close the notebook, the checkpoints are never deleted.
     These are NOT your actual notebooks, your .ipynb files are safe.
     Searched in: ~ (whole home, to depth 10; node_modules/.venv/.git/.cache/Library pruned)

 10. Old installer DMGs in ~/Downloads (>30 days old, >50 MB)
     .dmg files are disk images used to install apps. Once installed,
     the .dmg serves no purpose. Script only removes .dmg files that
     are more than 30 days old AND larger than 50 MB.
     Prints the filename and size before deleting each one.

 11. Trash and iOS crash logs
     Empties ~/.Trash completely.
     Deletes old iPhone/iPad crash reports from:
       ~/Library/Logs/CrashReporter/MobileDevice/

 12. Time Machine local snapshots (all but latest)
     macOS takes hourly local snapshots even without an external
     backup drive connected. They accumulate silently.
     Tier 1 deletes all but the newest snapshot, which is kept as
     a safety net in case you delete something before your next backup.
     Requires sudo (for tmutil). You'll be prompted for your password.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TIER 2: Only with --deep. There is a real cost after deletion.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. All user Library caches (~/Library/Caches/*)
     Wipes everything: browsers, Spotlight, system services, Spotify,
     all apps. Each app has to rebuild its cache from scratch.
     Expect the system to feel sluggish for 10-30 minutes after.
     On subsequent runs, the system feels normal again.

  2. Clang module cache (var/folders/C/clang)
     Clang pre-compiles headers to speed up C/C++/Swift/Objective-C
     builds. Clearing this means the first compile after is noticeably
     slower. Subsequent builds are fast again.

  3. Python bytecode cache (var/folders/C/org.python.python)
     Python compiles .py files to .pyc bytecode the first time they
     run. This is the system-level cache for that. After deletion,
     every module import is slightly slower until Python re-caches.

  4. Metal GPU shader cache (var/folders/C/com.apple.metal)
     macOS pre-compiles GPU programs (shaders) for every app that uses
     Metal (games, video editors, 3D tools). After deletion, shaders
     recompile on next launch, you may see brief stuttering or lag
     in GPU-heavy apps until they warm up.

  5. macOS system Apple caches (own user only)
     Clears com.apple.* cache dirs in your var/folders path only.
     Scoped to your own UID, does not touch other users on the machine.
     Requires sudo.

  6. Xcode DerivedData (~/Library/Developer/Xcode/DerivedData)
     All compiled Xcode build products. If you have any Xcode projects,
     the next build after this will be a full clean compile.
     No data loss, source code is untouched.

  7. Docker system prune + builder prune
     system prune: stopped containers, dangling images, unused networks.
     builder prune -af: ALL build cache (often the biggest hidden win).
     Does NOT remove: named volumes, running containers, or images
     referenced by any container. Can free 10-50+ GB.
     Also reports the Docker/OrbStack/Colima VM disk image size and how
     to compact it (those .raw/.img files never shrink after prune).
     Skipped silently if Docker daemon is not running.

  8. HuggingFace cache (~/.cache/huggingface)
     All downloaded model weights, tokenizers, and datasets.
     Models re-download automatically on next use, no code changes.
     Tip: run 'huggingface-cli delete-cache' before this for a
     picker UI where you can select specific models to keep.

  9. Playwright + Puppeteer browser binaries
     Playwright: ~/Library/Caches/ms-playwright (covered by Caches/* above)
     Puppeteer:  ~/.cache/puppeteer, Chrome + headless-shell binaries
     Both are browser runtimes for automated testing.
     Restore: npx playwright install  /  npx puppeteer browsers install

 10. Unavailable iOS simulators + CoreSimulator cache
     Runs 'xcrun simctl delete unavailable' to remove simulator runtimes
     for iOS versions you no longer have installed. Never deletes active
     simulators. Also clears ~/Library/Developer/CoreSimulator/Caches.
     No-op if Xcode / xcrun is not installed.

 10b. VSCode + Cursor Application Support caches
     CachedExtensionVSIXs/ → downloaded extension packages
     CachedData/           → compiled extension JS
     Cache/                → Chromium renderer cache
     logs/ + Crashpad/     → diagnostic logs and crash reports
     All regenerate on next launch. User/ and WebStorage/ are NOT touched.

 10c. Discord Application Support cache
     ~/Library/Application Support/Discord/Cache, Electron media cache.
     Rebuilds on next Discord launch.

 10d. ccache (C/C++ compiler cache, ~/.ccache)
     Caches compiled object files to speed up C/C++ rebuilds.
     Clearing it means the NEXT build is a full recompile (slow).
     Only cleared if ccache binary is present.

 10e. Android SDK system-images (informational)
     ~/Library/Android/sdk/system-images/, emulator OS images.
     Each API level × ABI is 1-3 GB. Shows installed versions and sizes.
     Removal: sdkmanager --uninstall or Android Studio SDK Manager.
     Use --scan to interactively remove per API level.

 11. Git repository GC (repos with .git > 100 MB)
     Runs 'git gc --prune=2.weeks.ago' inside each large repo.
     Compresses loose objects, optimizes pack files, removes stale
     refs. Unreachable objects (e.g. from recent git reset --hard) are
     preserved for 2 weeks, the same as git's own default.
     No loss of reachable commits. Typically 30s-2 min per repo.
     Roots: $GIT_GC_ROOTS (configurable in USER CONFIG at top of script).

 12. Last Time Machine snapshot
     Removes the final local snapshot that Tier 1 preserved.
     After this, you have zero local recovery until macOS creates
     a new snapshot (happens automatically in ~1 hour).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MODELS (--models): Interactive, per-tool confirmation.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  How it works:
    Per tool (not per model): each section lists its contents
    with sizes, then asks once to clear that tool's set, e.g.
    'Delete all Ollama models? [y/N]'. Type y then Enter to
    delete, or just Enter (or anything else) to skip. Defaults
    to No. If run non-interactively (piped/scripted), skips.

  1. Ollama models (~/.ollama/models)
     Runs 'ollama list' to show installed models and their sizes.
     If you confirm, deletes all models via 'ollama rm <model>'.
     Re-download any model: ollama pull <model-name>

  2. LM Studio .gguf files (~/.lmstudio/models/)
     Scans for all *.gguf model files recursively and lists each
     one with its size (e.g. 6.9G MythoMax, 4.4G Dolphin).
     If confirmed, deletes all .gguf files.
     Re-download: use the LM Studio app's model browser.

  3. HuggingFace cache (~/.cache/huggingface)
     Shows total cache size, then per-model and per-dataset breakdown.
     If confirmed, wipes the entire cache directory.
     Models re-download on next use, no code changes needed.
     Skipped if --deep already cleared it in this same run.

  4. NLTK corpora (~/nltk_data)
     NLTK downloads language corpora here (punkt, movie_reviews, etc.).
     Re-download any corpus: python -c "import nltk; nltk.download('name')"

  5. PyTorch Hub model cache (~/.cache/torch)
     torch.hub.load() caches model weights here, same concept as
     HuggingFace cache. Re-downloads on next torch.hub.load() call.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SCAN (--scan): Crawls your project tree. Per-entry prompts.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  How it works:
    Searches ~ (your whole home) for known artifact
    patterns. IDE directories (Cursor, VSCode, Trae, Antigravity),
    ~/.cache, ~/Library, and venv internals are excluded so you only
    see your own project files.

    For environments (venvs, conda envs, node_modules): shows each
    entry with its size in MB and last-modified date, then prompts
    per entry. Type y then Enter to delete, or just Enter to keep.

    For batch-safe artifacts (caches, temp files, OS junk): counts
    all instances and shows total size, then single prompt to delete
    all, because every single one is auto-regenerated and keeping
    individual ones has no value.

  Items scanned:

  ── Python environments (ANY folder name) ── PER ENTRY
     Detected by content (presence of pyvenv.cfg), not by folder name,
     so it catches .venv, venv, env, deploy-env, client_venv.x, etc.
     App-bundled runtimes (.lmstudio, .ollama) are excluded so the scan
     never offers to delete a Python env that belongs to an installed app.
     Recreate: python -m venv .venv / uv sync / poetry install

  ── Conda environments ── PER ENTRY
     Environments under ~/miniconda3, ~/anaconda3, ~/mambaforge, ~/.conda.
     Each shown with size and last-modified date. Per-entry prompt.
     Uses 'conda env remove' when available (cleans registry too).
     Recreate: conda create -n <name> python=3.x

  ── uv Python installations ── PER ENTRY
     Standalone Python interpreters downloaded by uv (separate from Homebrew).
     Stored in ~/.local/share/uv/python/ by default.
     Removed via 'uv python uninstall cpython-X.Y.Z'.
     Reinstall: uv python install <version>

  ── Android SDK system-images ── PER ENTRY
     Android emulator OS images, shown per API / tag / ABI (1-3 GB each).
     Old API levels you no longer target are safe to remove.
     Uses sdkmanager --uninstall when found (under cmdline-tools/ or
     tools/), else rm directly. Empty API/tag dirs are pruned after.

  ── VS Code-family stale extension versions ── BATCH (per editor)
     Detects ANY VS Code fork generically (by extensions/.obsolete),
     .vscode, .cursor, .windsurf, .trae, future forks. No names hardcoded.
     Deletes ONLY versions the editor itself flagged stale in .obsolete;
     never computes 'newest', never touches the active version or
     extensions.json. Safe even while the editor is running.

  ── JVM heap dumps (*.hprof) ── PER ENTRY
     Created by JVM crashes (OutOfMemoryError). Can be 1-16 GB each.
     Safe to delete, no project data, only a crash snapshot.

  ── ROS2 colcon workspace artifacts ── PER WORKSPACE
     build/ install/ log/ dirs created by 'colcon build'.
     Detected by presence of sibling src/ directory (standard ROS2 layout).
     Recreate: cd <workspace> && colcon build

  ── IPython command history ── PER ENTRY (⚠️  WARNING)
     ~/.ipython/profile_default/history.sqlite, your IPython command history.
     This is NOT cache, it is your personal command history.
     Deleting is permanent. Shown here only so you can decide consciously.

  ── node_modules directories ── PER ENTRY
     Installed JavaScript dependencies. Safe to delete from any project.
     Recreate with: npm install  (or yarn / pnpm install)
     IDE extension node_modules are excluded.

  ── Python build/test caches ── BATCH
     __pycache__   → compiled .pyc bytecode, regenerated on next run
     .pytest_cache → pytest result cache, regenerated on next test run
     .mypy_cache   → mypy type-check cache, regenerated on next mypy run
     .ruff_cache   → ruff lint cache, regenerated on next ruff run
     All are completely safe to batch delete. Single y/N prompt.

  ── Stray .pyc / .pyo files ── BATCH
     Compiled bytecode files that ended up outside a __pycache__ dir.
     Happens with old Python 2 projects or certain build tools.
     Regenerated automatically by Python on next import.

  ── Python packaging artifacts ── BATCH
     *.egg-info  → created by 'pip install -e .' (editable installs)
     Only those outside .venv and site-packages are shown.
     Safe to delete, regenerated on next 'pip install -e .'

  ── Rust build artifacts (target/) ── PER ENTRY
     Cargo stores all compiled output in target/. Debug builds are
     3-15 GB each. Validated by a sibling Cargo.toml, only real
     Rust projects are shown. Prefer 'cargo clean' when available.
     Recreate: cargo build (re-compiles from source automatically).

  ── Python/JS/C++ build outputs ── BATCH
     dist/                  → built wheels, tarballs, bundled JS
     build/                 → CMake, setuptools intermediate files
     cmake-build-debug/     → CLion CMake debug build
     cmake-build-release/   → CLion CMake release build
     cmake-build-relwithdebinfo/ / cmake-build-minsizerel/ → same
     node_modules internals (e.g. three/build, gsap/dist) are excluded.
     WARNING: some projects commit dist/ for releases, review the
     list before confirming. All are regenerated by the build tool.

  ── Python test/coverage artifacts ── BATCH
     .coverage      → raw coverage data from 'pytest --cov'
     .coverage.*    → parallel coverage data files
     coverage.xml   → coverage report for CI/codecov
     htmlcov/       → HTML coverage report directory
     .hypothesis/   → Hypothesis property-testing example database
     .tox/          → tox virtualenvs and build artifacts
     .nox/          → nox session virtualenvs
     All regenerated on next test run.

  ── R session artifacts ── BATCH
     .RData     → R workspace snapshot (saved variables from session)
     .Rhistory  → R command history
     .Rapp.history → R GUI command history
     Rplots.pdf → auto-generated by R when plotting without a device
     WARNING: .RData can contain work you care about. The prompt
     will list files before asking, review before confirming.

  ── LaTeX compilation artifacts ── BATCH
     .aux .toc .lot .lof        → table of contents / cross-ref data
     .bbl .blg                  → BibTeX bibliography files
     .nav .snm                  → Beamer presentation files
     .fls .fdb_latexmk          → latexmk tracking files
     .synctex.gz                → SyncTeX editor sync file
     All are regenerated on next LaTeX compile. Your .tex is untouched.

  ── macOS system junk files ── BATCH
     .DS_Store    → Finder folder view settings, useless outside macOS
     ._*          → AppleDouble resource fork files, useless on non-HFS
     .AppleDouble → legacy resource fork directory
     Thumbs.db    → Windows thumbnail cache (shouldn't be on Mac)
     desktop.ini  → Windows folder config (shouldn't be on Mac)
     Safe to delete unconditionally.

  ── Editor swap and backup files ── BATCH
     *.swp *.swo  → Vim swap files (crash recovery, usually orphaned)
     *~           → Emacs/nano backup files
     *.orig       → conflict resolution originals (from git merge)
     *.bak        → generic backup files left by various tools
     Review before deleting if you have in-progress edits in Vim.

  ── Project log files (>100 KB) ── PER ENTRY
     Application logs, Docker build logs, server logs inside projects.
     Shows each with size and path. Prompts per entry.
     Does NOT touch system logs (~/Library/Logs is excluded).

  ── AI / local-model tool caches ── PER TOOL
     ComfyUI, Automatic1111, Claude Code, Codex, n8n, openclaw, MATLAB, etc.
     Cleans ONLY regenerable temp/cache. Your models, generated outputs,
     chat/session history, and workflow DBs are shown as 'kept (user data)'
     and NEVER deleted. Model weights are handled separately in --models.
     MATLAB: clears logs, crash dumps, and download caches only. The installed
     ServiceHost runtime is left alone (deleting it just forces a re-download on
     next launch), and your prefs, command history, Add-Ons, license, and
     ~/Documents/MATLAB are kept. No re-download or re-login.

  ── Orphaned dev/ML tool data ── PER ENTRY
     Leftover data dirs of dev/ML tools whose binary/app is gone (e.g.
     ~/.ollama after Ollama is removed). Conservative: only flags tools
     reliably detectable as absent. General app-uninstall leftovers are
     out of scope, a dedicated app uninstaller is the right tool; dehoard
     does not scan all of ~/Library.

  ── Tool caches >100 MB (~/.cache, ~/Library/Caches) ── PER ENTRY
     Generic catch-all. Instead of enumerating every language's cache dir
     by name, it size-ranks everything in ~/.cache and ~/Library/Caches
     over 100 MB and prompts per entry. This covers every tool, including
     ones no rule lists and ones that don't exist yet (e.g. trunk,
     codex-runtimes, JetBrains).
     Anything already cleared by Tier 1 / --deep / --models earlier in the
     same run won't reappear here. All regenerate; some re-download slowly.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • Close Chrome and Brave before running (for clone deletion)
  • You will be prompted for sudo password once (for tmutil)
  • Do NOT run as: sudo zsh dehoard.sh, breaks Homebrew/npm/pip
  • Safe to run repeatedly, missing paths are silently skipped
  • Free space is measured before and after; shown at the end
  • --dry-run works with any flag combo, shows what would be
    deleted without touching any files
  • --yes / -y auto-confirms every prompt, run --yes --dry-run
    first to review what will be deleted before committing
  • --report is read-only: ranks your biggest dirs + flags which are
    regenerable caches (and which flag clears each), a per-editor table
    (size + idle time), a local model-weight inventory across HF/Ollama/
    LM Studio/PyTorch, and POTENTIAL cross-tool duplicate models (same
    model in 2+ tools → est. reclaim). Matched by name → verify before
    removing (Q4≠Q8); never auto-deleted. Deletes nothing.

Provided "as is", without warranty (MIT). Deletion is real rm, preview first;
you are responsible for what you delete. See LICENSE.

DEHOARD_HELP
}

if [[ "$1" == "--help" || "$1" == "-h" ]]; then usage; exit 0; fi
if [[ "$1" == "--version" || "$1" == "-V" ]]; then echo "dehoard ${DEHOARD_VERSION}"; exit 0; fi

_SELF="${0:A}"     # absolute, symlink-resolved path of THIS script (captured at top level: inside a
                   # function zsh's $0 is the function name, so --uninstall could not find it later)
# Footprint, split by XDG semantics: logs are regenerable cache, the ignore list is user-authored
# config. Keeping them apart lets --uninstall delete the cache freely while preserving config by
# default (apt remove vs purge). XDG_* vars are usually unset on macOS, so these default to the
# familiar ~/.cache and ~/.config.
_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dehoard"        # run-*.log deletion records (exhaust)
_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dehoard"     # the ignore list (hand-authored intent)
_IGNORE_FILE="$_CONFIG_DIR/ignore"
# One-time migration: the ignore list used to live under ~/.cache; it is config, so move it to the
# config dir. Cheap (two stat checks); transparent; preserves an existing list.
if [[ -f "$_CACHE_DIR/ignore" && ! -f "$_IGNORE_FILE" ]]; then
  mkdir -p "$_CONFIG_DIR" 2>/dev/null && mv "$_CACHE_DIR/ignore" "$_IGNORE_FILE" 2>/dev/null
fi
DEEP=false
MODELS=false
SCAN=false
DRY_RUN=false
ASSUME_YES=false
REPORT=false
APPLY=false
JSON=false
PICK=false
for arg in "$@"; do
  [[ "$arg" == "--deep" ]]             && DEEP=true
  [[ "$arg" == "--models" ]]           && MODELS=true
  [[ "$arg" == "--scan" ]]             && SCAN=true
  [[ "$arg" == "--pick" ]]             && { PICK=true; SCAN=true; }   # interactive multiselect (implies --scan)
  [[ "$arg" == "--dry-run" ]]          && DRY_RUN=true
  [[ "$arg" == "--apply" ]]            && APPLY=true
  [[ "$arg" == "--yes" || "$arg" == "-y" ]] && ASSUME_YES=true
  [[ "$arg" == "--report" ]]           && REPORT=true
  [[ "$arg" == "--json" ]]             && { JSON=true; REPORT=true; }   # --json implies a read-only report
  if [[ "$arg" == "--reset-ignore" ]]; then
    rm -f "$_IGNORE_FILE"
    echo "dehoard: ignore list cleared."; exit 0
  fi
  if [[ "$arg" == "--list-ignored" ]]; then
    local _ign="$_IGNORE_FILE"
    if [[ -f "$_ign" ]]; then
      echo "Paths in dehoard ignore list (${_IGNORE_FILE/#$HOME/~}):"
      sed "s|^${HOME}|~|" "$_ign"
    else
      echo "No ignore list, say 'y' to 'Always skip?' after declining a prompt with --apply."
    fi
    exit 0
  fi
done

# --unignore <path>: remove one specific path from the ignore list.
# Handled after the loop so we can look up argv[i+1] cleanly.
if (( ${@[(I)--unignore]} )); then
  local _ui_idx=$(( ${@[(i)--unignore]} + 1 ))
  local _ui_raw="${@[$_ui_idx]:-}"
  if [[ -z "$_ui_raw" || "$_ui_raw" == --* ]]; then
    echo "dehoard: --unignore requires a path  (e.g. dehoard --unignore ~/.cache/huggingface)"; exit 1
  fi
  # Normalize: expand leading ~, strip trailing slash, matches how ignore list stores paths
  local _ui_path="${_ui_raw/#\~/$HOME}"; _ui_path="${_ui_path%/}"
  local _ign="$_IGNORE_FILE"
  if [[ ! -f "$_ign" ]]; then
    echo "dehoard: no ignore list found (nothing to remove)."; exit 0
  fi
  if ! grep -qxF "$_ui_path" "$_ign" 2>/dev/null; then
    echo "dehoard: '${_ui_path/#$HOME/~}' is not in the ignore list."; exit 1
  fi
  grep -vxF "$_ui_path" "$_ign" > "${_ign}.tmp"; mv "${_ign}.tmp" "$_ign"
  [[ -s "$_ign" ]] || rm -f "$_ign"            # remove file entirely if now empty
  echo "dehoard: removed '${_ui_path/#$HOME/~}' from ignore list."
  exit 0
fi

# SAFETY: preview-by-default. Nothing is deleted unless --apply is given (or
# DEHOARD_APPLY_DEFAULT=true is set). --dry-run always wins and forces preview.
[[ "${DEHOARD_APPLY_DEFAULT:-false}" == true ]] && APPLY=true   # env opt-in (compared, not run); --dry-run below overrides
$APPLY || DRY_RUN=true
$DRY_RUN && APPLY=false                          # --dry-run beats everything, always

# ── Semantic color (human-terminal only; never on a machine channel) ─────────
# Enabled only when stdout is an interactive TTY, NO_COLOR is unset, and we are NOT
# under --json (where stdout is a pure-JSON data contract). CLICOLOR_FORCE=1 forces
# it on regardless of TTY, used by the test suite to PROVE the machine channels
# (--json, the deletion log) stay escape-free even with color forced.
# IMPORTANT: the deletion log is written by a separate raw path (_rm / the run
# header) that never calls these helpers, color cannot reach it by construction.
if [[ -z "${NO_COLOR-}" ]] && ! $JSON && { [[ -t 1 ]] || [[ -n "${CLICOLOR_FORCE-}" ]]; }; then
  _USE_COLOR=true
else
  _USE_COLOR=false
fi
_c() {  # $1=SGR code; rest=text → painted (no newline), or plain when color is off
  local code="$1"; shift
  if $_USE_COLOR; then printf '\033[%sm%s\033[0m' "$code" "$*"; else printf '%s' "$*"; fi
}
c_danger() { _c '1;31' "$@"; }   # bold red , deletions / APPLY mode (stay loud)
c_warn()   { _c '33'   "$@"; }   # yellow   , warnings, refusals, always-skips
c_safe()   { _c '32'   "$@"; }   # green    , kept user data, freed space, success
c_head()   { _c '1;36' "$@"; }   # bold cyan, section headers / banners
c_dim()    { _c '2'    "$@"; }   # dim      , preview lines, secondary detail
c_bold()   { _c '1'    "$@"; }   # bold     , emphasis / prompts
# Mode-aware: a cleanup-step label is secondary while PREVIEWING (dim), but in --apply the
# per-file deletes are silent so the step label is the ONLY live evidence of rm -rf → make it
# bold, never dim, dimming the only live evidence of an active delete would hide it.
c_step()   { if $DRY_RUN; then c_dim "$@"; else c_bold "$@"; fi }

# Warn about unrecognised flags, catches typos like --scann silently running Tier 1 only
_VALID_FLAGS=(--deep --models --scan --pick --dry-run --apply --yes -y --report --json --help -h --version -V --reset-ignore --list-ignored --unignore --uninstall --purge)
for arg in "$@"; do
  # Only warn about --flag tokens; bare paths (e.g. argument to --unignore) are not flags
  [[ "$arg" == --* || "$arg" == -[a-z] ]] || continue
  (( ${_VALID_FLAGS[(Ie)$arg]} )) || echo "⚠️  Unknown flag: '$arg' (ignored, did you mean --scan or --deep?)"
done

$REPORT || echo "$(c_head "🧹 dehoard: disk reclaimer for ML/dev Macs")"
if ! $JSON; then   # --json: stdout must be PURE JSON, no banners
  $DEEP       && echo "$(c_warn "⚠️  Deep mode: aggressive cache wipe enabled")"
  $MODELS     && echo "$(c_bold "🤖 Models mode: interactive LLM/ML model cleanup enabled")"
  $SCAN       && echo "$(c_bold "🔍 Scan mode: interactive project artifact scan enabled")"
fi
if ! $REPORT; then
  if $DRY_RUN; then
    echo "$(c_head "👁  PREVIEW mode (default), NOTHING will be deleted.")"
    echo "$(c_dim "   This previews the Tier 1 CLEANUP it would run; add --apply to reclaim.")"
    echo "$(c_dim "   (Want a full read-only audit of what's eating disk instead? Use --report.)")"
    $ASSUME_YES && echo "$(c_dim "   (--yes shown: this is what --apply --yes would delete.)")"
  else
    echo "$(c_danger "🔥 APPLY mode, files WILL be deleted.")"
    $ASSUME_YES && echo "$(c_warn "⚡ --yes: every prompt auto-confirmed (venvs, node_modules, all). Ctrl+C to abort.")"
  fi
  # Surface the active ignore list upfront when the feature is enabled
  local _ign_startup="$_IGNORE_FILE"
  if ${DEHOARD_IGNORE_ENABLED:-true} && [[ -f "$_ign_startup" ]]; then
    local _ign_n; _ign_n=$(wc -l < "$_ign_startup" | tr -d ' ')
    if (( _ign_n > 0 )); then
      printf "⊘  Ignore list active: %d path(s) will be skipped without prompting.\n" "$_ign_n"
      printf "   Review: dehoard --list-ignored   Remove one: dehoard --unignore <path>   Clear all: dehoard --reset-ignore\n"
    fi
  fi
fi
$JSON || echo ""   # blank separator for humans; never on stdout under --json (must be pure JSON)

BEFORE=$(df -k / | awk 'NR==2 {print $4}')
# Honest reclaim accounting: sum of the sizes of what dehoard ACTUALLY deletes (KB), tallied as it
# deletes. The final "Storage freed" reports THIS, not a whole-disk `df` delta, which would otherwise
# credit dehoard for ambient disk churn (browsers, Spotlight, other processes) during the run.
_FREED_KB=0
# Deletion log (only in --apply mode), a record of what was removed, when.
LOGFILE=""
if $APPLY; then
  LOGDIR="$_CACHE_DIR"
  mkdir -p "$LOGDIR" 2>/dev/null && LOGFILE="$LOGDIR/run-$(date +%Y%m%d-%H%M%S).log"
  [[ -n "$LOGFILE" ]] && echo "# dehoard run $(date), flags: $*" > "$LOGFILE"
fi
TMPDIR="${TMPDIR:-/tmp}"      # default if unset (CI/cron/restored sessions), _rm whitelist still guards
TMPDIR="${TMPDIR%/}/"         # normalize: ensure exactly one trailing slash
BASE="$(dirname "$TMPDIR")"   # parent of T/ → gives C/ and X/ siblings
BASE="${BASE:A}"              # canonicalize: resolve `..`/symlinks so a hostile TMPDIR like
                             # /var/folders/../../etc can't slip the string-prefix guard below and
                             # steer the sudo rm; a real per-user root resolves under /private/var/folders
# Load the ignore list ONCE so _rm honors it in every tier (not just interactive prompts).
# Non-empty lines only; entries are absolute paths and may contain globs.
_IGNORE_PATTERNS=()
if ${DEHOARD_IGNORE_ENABLED:-true} && [[ -f "$_IGNORE_FILE" ]]; then
  _IGNORE_PATTERNS=(${(f)"$(grep -v '^[[:space:]]*$' "$_IGNORE_FILE" 2>/dev/null)"})
fi

# --pick registry: in-scope --scan candidates are appended here during the scan (only under
# --pick + fzf + --apply) and presented in one fzf picker afterwards. See _register/_run_picker.
_PICK_ITEMS=()
typeset -gA _PICK_SEEN     # normalized abs path -> 1, so one path can't appear under two categories
_COLLECT=false

# ── Shared helpers ──────────────────────────────────────
# Prompts y/N only when stdin is a terminal; defaults to N otherwise.
# Priority: --dry-run (show all, delete nothing) → --yes (confirm all) → TTY → skip.
_ask() {  # $1=question, $2=optional path for always-skip check
  local _sp="${${2:-}%/}"                                      # strip trailing slash for consistent matching
  local _ign="$_IGNORE_FILE"
  # Check ignore list, always announce the skip so nothing is hidden from the user.
  # Skipped entirely when DEHOARD_IGNORE_ENABLED=false (stateless mode).
  if ${DEHOARD_IGNORE_ENABLED:-true} && [[ -n "$_sp" && -f "$_ign" ]] \
     && grep -qxF "$_sp" "$_ign" 2>/dev/null; then
    printf "  ⊘ always-skip (%s)\n" "${_sp/#$HOME/~}"
    return 1
  fi
  if $DRY_RUN; then
    echo "$1 [y/N] → y (dry-run: showing all)"
    return 0
  elif $ASSUME_YES; then
    echo "$1 [y/N] → y (--yes)"
    return 0
  elif [[ -t 0 ]]; then
    # This branch is reached ONLY in apply mode (dry-run auto-answers above, --yes auto-confirms),
    # so this is a real authorization-to-delete moment → mark the question yellow. The decision
    # point must not be quieter than --yes; RED stays reserved for the APPLY banner.
    read -q "REPLY?$(c_warn "$1") [y/N] "; echo
    # After a deliberate "no" in apply mode, offer always-skip, unless user disabled it
    if [[ "$REPLY" != "y" && -n "$_sp" ]] && $APPLY && ${DEHOARD_IGNORE_ENABLED:-true}; then
      read -q "SKIP_REPLY?    Always skip ${_sp/#$HOME/~}? [y/N] "; echo
      if [[ "$SKIP_REPLY" == "y" ]]; then
        mkdir -p "$_CONFIG_DIR"
        printf '%s\n' "$_sp" >> "$_ign"
        printf "  ↪ Added to ignore list. Use 'dehoard --reset-ignore' to clear.\n"
      fi
    fi
    [[ "$REPLY" == "y" ]]
  else
    echo "$1 [y/N] → N (non-interactive, skipping)"
    return 1
  fi
}

# Remove dehoard and everything it ever wrote. The ONLY targets are two fixed, hardcoded paths under
# $HOME (never user-derived): the cache dir (regenerable logs), and, when the running copy is the
# standard install, the script itself. Following the apt remove/purge convention, the user-authored
# ignore list (config) is KEPT by default and announced; --purge also removes it (after echoing it, so
# the one irreplaceable file is never destroyed silently). A non-standard script copy (a cloned repo
# or custom path), or a symlinked install, is left alone with a printed manual-removal hint, so we
# never delete someone's working tree (the rustup self-uninstall data-loss lesson). Preview-first:
# --dry-run shows the plan and deletes nothing. Not routed through _rm: we delete the log dir itself,
# so logging into it would be circular, and the targets are fixed strings so the guard adds nothing.
_uninstall() {
  # Self-contained on purpose: the global DRY_RUN is forced true whenever --apply is absent, and _ask
  # auto-confirms under DRY_RUN, so neither can be reused here. Read --dry-run/--purge from our own
  # args; ASSUME_YES (set at parse, never force-overridden) is still reliable.
  local _dry=false _purge=false
  (( ${@[(I)--dry-run]} )) && _dry=true
  (( ${@[(I)--purge]} ))   && _purge=true
  local _std="${HOME}/.local/bin/dehoard"
  local -a _targets=()
  local _keep_self="" _keep_config=""
  echo "$(c_head "dehoard uninstall")"
  echo "  Will remove:"
  if [[ -d "$_CACHE_DIR" ]]; then
    # Normally remove the whole cache dir. But if the user pointed XDG_CACHE_HOME and XDG_CONFIG_HOME
    # at the same place (or nested config under cache), the ignore file lives in here too: when we are
    # keeping config (no --purge), remove only the logs so the kept ignore file is not taken with it.
    # Decide BEFORE the preview line so the "Will remove:" text matches what is actually deleted.
    if ! $_purge && [[ "${_CONFIG_DIR:A}" == "${_CACHE_DIR:A}" || "${_IGNORE_FILE:A}" == "${_CACHE_DIR:A}/"* ]]; then
      echo "    ${_CACHE_DIR/#$HOME/~}/run-*.log  (deletion logs; the ignore list in this dir is kept)"
      _targets+=("$_CACHE_DIR"/run-*.log(N))
    else
      echo "    $(du -sh "$_CACHE_DIR" 2>/dev/null | cut -f1)  ${_CACHE_DIR/#$HOME/~}  (deletion logs)"
      _targets+=("$_CACHE_DIR")
    fi
  else
    echo "    (no logs at ${_CACHE_DIR/#$HOME/~})"
  fi
  # The script: remove only the standard install, and only if it is a real file (not a symlink, which
  # rustup learned can point into a user's own bin and get followed). :A on both sides resolves the
  # macOS /var vs /private/var symlink so the comparison is apples-to-apples.
  if [[ "$_SELF" == "${_std:A}" && -f "$_std" && ! -L "$_std" ]]; then
    echo "    $(du -sh "$_std" 2>/dev/null | cut -f1)  ${_std/#$HOME/~}  (the script)"
    _targets+=("$_std")
  elif [[ -e "$_SELF" ]]; then
    _keep_self="$_SELF"
  fi
  # The ignore list is user-authored config: keep it unless --purge. Under --purge, echo it first so
  # the only irreplaceable thing dehoard owns is never destroyed without the user seeing it.
  if [[ -f "$_IGNORE_FILE" ]]; then
    if $_purge; then
      echo "    $(du -sh "$_CONFIG_DIR" 2>/dev/null | cut -f1)  ${_CONFIG_DIR/#$HOME/~}  (ignore list, --purge)"
      _targets+=("$_CONFIG_DIR")
    else
      _keep_config="$_IGNORE_FILE"
    fi
  fi
  if [[ -n "$_keep_self" ]]; then
    echo "  Will KEEP (not the standard ~/.local/bin install, remove it yourself):"
    echo "    rm '${_keep_self/#$HOME/~}'"
  fi
  if [[ -n "$_keep_config" ]]; then
    echo "  Will KEEP your ignore list (run --purge to remove it too):"
    echo "    ${_keep_config/#$HOME/~}"
  fi
  if (( ! ${#_targets[@]} )); then
    echo "  Nothing to remove."
    exit 0
  fi
  if $_dry; then
    echo "  $(c_dim "[preview] nothing removed; re-run without --dry-run to uninstall.")"
    exit 0
  fi
  local _go=false
  if $ASSUME_YES; then
    _go=true; echo "  Remove the items above? [y/N] → y (--yes)"
  elif [[ -t 0 ]]; then
    read -q "REPLY?$(c_warn "  Remove the items above?") [y/N] "; echo
    [[ "$REPLY" == "y" ]] && _go=true
  else
    echo "  Remove the items above? [y/N] → N (non-interactive; nothing removed; pass --yes to confirm)"
  fi
  if $_go; then
    # Echo the ignore list before purging it: the one irreplaceable file is never lost silently.
    if $_purge && [[ -f "$_IGNORE_FILE" ]]; then
      echo "$(c_dim "  ignore list contents (about to be removed by --purge):")"
      sed 's|^|    |' "$_IGNORE_FILE"
    fi
    # Only ever the fixed, hardcoded paths built above (under $HOME, never user-derived).
    rm -rf "${_targets[@]}"
    echo "$(c_safe "dehoard uninstalled.")"
    [[ -n "$_keep_self" ]]   && echo "  (left ${_keep_self/#$HOME/~}, remove it manually)"
    [[ -n "$_keep_config" ]] && echo "  (kept your ignore list at ${_keep_config/#$HOME/~})"
  else
    echo "  Uninstall cancelled, nothing removed."
  fi
  exit 0
}

# Honored by _rm in EVERY tier, not just the interactive _ask prompts, so a path you mark
# "always skip" is respected even by the batch Tier 1 / --deep sweeps. The `_IGNORE_PATTERNS` array
# is populated once in the preamble (do NOT reset it here, that would run after the load and wipe it).
# Entries are absolute paths and may contain globs.
_is_ignored() {  # $1 = absolute path (trailing slash stripped); true if it matches any ignore entry
  local _p
  for _p in "$_IGNORE_PATTERNS[@]"; do
    # Match the entry itself OR anything inside it: "always skip" on a directory must cover the
    # directory's contents too, otherwise the picker can still offer a child (e.g. an ignored app
    # dir whose Cache subfolder slips through). ${~_p} activates glob metacharacters in the pattern.
    [[ "$1" == ${~_p} || "$1" == ${~_p}/* ]] && return 0
  done
  return 1
}

# Deletes paths, or prints what would be deleted in --dry-run/preview mode.
# Guards against catastrophic targets: empty/unset vars, "/", and "$HOME" itself.
_rm() {
  # Fail-closed precondition: _rm's preview-vs-delete branch reads the global $DRY_RUN.
  # If it's empty/unset (e.g. a refactor accidentally scoped it to a function), the
  # `if $DRY_RUN` test is undefined, so REFUSE rather than risk deleting in what the
  # user believes is preview mode. Normal runs always set DRY_RUN, so this never fires.
  if [[ -z "${DRY_RUN-}" ]]; then
    echo "$(c_warn "  ⚠️  _rm refused: \$DRY_RUN unset, failing closed, nothing deleted.")" >&2
    return 1
  fi
  local target
  local -a _todo=()
  for target in "$@"; do
    # Hard stops: empty/unset, root, or $HOME itself.
    if [[ -z "$target" || "$target" == "/" || "$target" == "$HOME" || "$target" == "$HOME/" ]]; then
      echo "$(c_warn "  ⚠️  refusing to delete unsafe path: '${target:-<empty>}'")" >&2
      return 1
    fi
    # Refuse `..` traversal so the string-prefix whitelist below can't be walked out of a safe root.
    # Purely additive (only ever deletes LESS); dehoard's real targets come from canonical globs.
    if [[ "$target" == */../* || "$target" == */.. ]]; then
      echo "$(c_warn "  ⚠️  refusing path with '..' traversal: '$target'")" >&2
      return 1
    fi
    # Safe-root whitelist (centralized, defends against a mis-computed $BASE/$TMPDIR,
    # e.g. TMPDIR unset → BASE='/' → '//C/...'; such paths are NOT under a safe root).
    # Everything dehoard legitimately deletes lives under $HOME or a per-user temp root.
    case "$target" in
      "$HOME"/*|/var/folders/*|/private/var/folders/*|/tmp/*|/private/tmp/*) ;;
      *) echo "$(c_warn "  ⚠️  refusing path outside safe roots (\$HOME, var/folders, tmp): '$target'")" >&2
         return 1 ;;
    esac
    # Ignore list: skip + announce (never abort), honored in every tier. Subtractive by design
    # (only ever deletes LESS), so it cannot widen what gets removed. Checked AFTER the safe-root
    # guard so an ignore entry can never relax the whitelist.
    if (( ${#_IGNORE_PATTERNS[@]} )) && _is_ignored "${target%/}"; then
      echo "$(c_dim "  ⊘ ignored: ${target/#$HOME/~}")"
      continue
    fi
    _todo+=("$target")
  done
  (( ${#_todo[@]} )) || return 0
  if $DRY_RUN; then
    for target in "$_todo[@]"; do
      [[ -e "$target" ]] && echo "  [preview] would delete: $target ($(du -sh "$target" 2>/dev/null | cut -f1))"
    done
  else
    local _sz="" _szk=0
    for target in "$_todo[@]"; do
      [[ -e "$target" ]] || continue
      _sz=$(du -sh "$target" 2>/dev/null | cut -f1)
      _szk=$(du -sk "$target" 2>/dev/null | cut -f1); [[ -n "$_szk" ]] || _szk=0   # KB, for honest reclaim tally
      # Delete FIRST, report only on success: never print "removed:" for something that did not
      # actually go. rm's own errors are routed to the deletion log, not the terminal, so a
      # permission-denied tree (e.g. root-owned CPAN build dirs) can't flood the screen.
      if rm -rf "$target" 2>>"${LOGFILE:-/dev/null}"; then
        echo "  removed: ${target/#$HOME/~} (${_sz})"                  # human-visible: what was actually deleted
        (( _FREED_KB += _szk ))                                        # count only what actually went
        [[ -n "$LOGFILE" ]] && printf '%s\t%s\n' "$_sz" "$target" >> "$LOGFILE"   # raw record (never colored)
      else
        echo "$(c_warn "  ⚠️  could not remove ${target/#$HOME/~} (permission denied; if root-owned, try: sudo rm -rf '${target/#$HOME/~}')")" >&2
      fi
    done
  fi
}

# Run an external command with a wall-clock timeout, so a hung tool (e.g. a package
# manager waiting on a daemon or the network) cannot freeze the whole run. macOS has no
# `timeout`; prefer it / gtimeout when installed, else poll a backgrounded child. Returns
# the command's own exit code, or 124 if it was killed for exceeding $1 seconds.
_run_timeout() {
  local secs="$1"; shift
  (( $# )) || return 0
  local t
  for t in timeout gtimeout; do
    command -v "$t" &>/dev/null && { "$t" "$secs" "$@"; return $?; }
  done
  "$@" &                       # script runs non-interactively, so no job-control noise
  local pid=$! ticks=0 maxticks=$(( secs * 5 ))   # poll 5x/sec so fast tools return at once
  # On Ctrl-C/TERM, reap the backgrounded child before exiting so it is not orphaned (the
  # global trap only knows the parent). local_traps reverts this on return.
  setopt local_traps
  trap 'kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; _cleanup_exit' INT TERM
  while (( ticks < maxticks )); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return $?; }
    sleep 0.2; (( ticks++ ))
  done
  kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 124
}

# Gate a package-manager cleanup on the tool being installed, then run it under the
# timeout guard. $1 = human label; the rest is the command (gated on its first word).
_pm_run() {
  local label="$1"; shift
  command -v "$1" &>/dev/null || return 0
  local rc; _run_timeout "$DEHOARD_PM_TIMEOUT" "$@" 2>/dev/null; rc=$?
  (( rc == 124 )) && echo "  $(c_warn "skipped ${label}: timed out after ${DEHOARD_PM_TIMEOUT}s (run it manually if needed)")"
  return 0
}

# --- Interactive multiselect (--pick): one fzf picker per scan category, biggest first. --------
# fzf is optional: when absent (or no TTY) we fall back to the per-section per-item prompts.
# DEHOARD_FORCE_PICKER=1 lifts the TTY requirement for the hermetic test suite only.
_have_picker() {
  command -v fzf &>/dev/null || return 1
  [[ -n "${DEHOARD_FORCE_PICKER:-}" ]] && return 0
  [[ -t 0 && -t 1 ]]
}

# Register scan candidates for the picker. Each record is TAB-delimited with 8 fields and
# NO empty fields (sentinel '-'), so zsh field-splitting can't collapse them:
#   type \t category \t size_kb \t mtime \t display \t hint \t note \t abs_path
# 'type' (rm|conda|uv|android|cargo) drives deletion in _pick_delete.
_register() {  # $1=type $2=category $3=hint $4=note ; rest = absolute paths
  local _ty="$1" _cat="$2" _hint="$3" _note="$4"; shift 4
  [[ -n "$_hint" ]] || _hint="-"; [[ -n "$_note" ]] || _note="-"
  local _p _kb _mt _n=0
  for _p in "$@"; do
    [[ -e "$_p" ]] || continue
    # The record (and the fzf line) are TAB/newline-delimited, so a path containing either would
    # desync field-splitting and mis-map the selection. Such paths are near-nonexistent for the
    # artifacts we scan; skip them from the picker (the non-pick per-item flow still handles them)
    # rather than risk a wrong mapping. Fail-safe: a mis-mapped index would hit _rm's guards anyway.
    [[ "$_p" == *$'\t'* || "$_p" == *$'\n'* ]] && continue
    # Honor the ignore list HERE, at registration, so an "always skip" path never even enters the
    # picker. This is the only ignore check for env-manager items: _pick_delete dispatches conda/uv/
    # android/cargo to their native uninstaller (NOT through _rm), so the _rm ignore check would not
    # see them. Filtering here covers every type uniformly. (rm-type items are still re-checked by _rm.)
    if (( ${#_IGNORE_PATTERNS[@]} )) && _is_ignored "${_p%/}"; then
      echo "$(c_dim "  ⊘ ignored: ${_p/#$HOME/~}")"
      continue
    fi
    # Dedup across categories: a path can be found by more than one scanner (e.g. a big AI-tool
    # cache also caught by the generic >100MB sweep). Register it once, keyed on the trailing-slash-
    # normalized abs path, so it is not shown and confirmed twice or double-counted in the summary.
    if [[ -n "${_PICK_SEEN[${_p%/}]:-}" ]]; then continue; fi
    _PICK_SEEN[${_p%/}]=1
    _kb=$(du -sk "$_p" 2>/dev/null | cut -f1); [[ -n "$_kb" ]] || _kb=0
    _mt=$(stat -f '%Sm' -t '%Y-%m-%d' "$_p" 2>/dev/null); [[ -n "$_mt" ]] || _mt="-"
    _PICK_ITEMS+=( "${_ty}"$'\t'"${_cat}"$'\t'"${_kb}"$'\t'"${_mt}"$'\t'"${_p/#$HOME/~}"$'\t'"${_hint}"$'\t'"${_note}"$'\t'"${_p}" )
    (( _n++ ))
  done
  # Tie this verbose scan-section header to the SHORT picker-category slug it feeds, and confirm a
  # count. Without this a registering section is silent under its cyan header in --pick, which reads
  # as "found nothing"; and the header text ("Python/JS build outputs") never visibly matched the
  # picker label ("build/dist"). This line bridges both.
  (( _n )) && echo "$(c_dim "  → ${_n} found; shown in the picker below under category: ${_cat}")"
}

# Delete one selected item by type. Env-managers use their native uninstaller (rm of a conda env
# dir leaves ghost entries in environments.txt + stale metadata) and self-scope to their own files;
# everything else (and the `|| _rm` fallbacks) goes through _rm's safe-root guard. Ignored paths are
# filtered upstream in _register, so nothing reaching here is on the ignore list.
_pick_delete() {  # $1=type $2=abs_path
  local _ty="$1" _p="$2" _name _pkg _sdk _c _sdkroot
  # Honest reclaim tally for native-uninstaller branches (they bypass _rm, which would otherwise do
  # the counting). Sized BEFORE deletion, while the path still exists; the `|| _rm` fallbacks and the
  # default `_rm` branch already count themselves, so only the native success branches add here.
  local _szk; _szk=$(du -sk "$_p" 2>/dev/null | cut -f1); [[ -n "$_szk" ]] || _szk=0
  case "$_ty" in
    conda)
      _name="${${_p%/}:t}"
      # A leading-dash name would be read as a flag by the tool; route it to the safe path delete.
      if [[ "$_name" != -* ]] && command -v conda &>/dev/null && conda env remove -n "$_name" -y 2>>"${LOGFILE:-/dev/null}"; then
        echo "  removed (conda env): $_name"; (( _FREED_KB += _szk ))
      else _rm "$_p"; fi ;;
    uv)
      _name="${${_p%/}:t}"
      if [[ "$_name" != -* ]] && command -v uv &>/dev/null && uv python uninstall "$_name" 2>>"${LOGFILE:-/dev/null}"; then
        echo "  removed (uv python): $_name"; (( _FREED_KB += _szk ))
      else _rm "$_p"; fi ;;
    android)
      _pkg="system-images;${${_p:h:h}:t};${${_p:h}:t};${_p:t}"   # .../<api>/<tag>/<abi>
      _sdkroot="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
      _sdk=""
      if command -v sdkmanager &>/dev/null; then _sdk="sdkmanager"; else
        for _c in "$_sdkroot"/cmdline-tools/latest/bin/sdkmanager \
                  "$_sdkroot"/cmdline-tools/*/bin/sdkmanager "$_sdkroot"/tools/bin/sdkmanager; do
          [[ -x "$_c" ]] && { _sdk="$_c"; break; }
        done
      fi
      if [[ -n "$_sdk" ]] && "$_sdk" --uninstall "$_pkg" 2>>"${LOGFILE:-/dev/null}"; then
        echo "  removed (android): $_pkg"; (( _FREED_KB += _szk ))
      else _rm "$_p"; fi ;;
    cargo)
      if command -v cargo &>/dev/null && cargo clean --manifest-path "${_p:h}/Cargo.toml" 2>>"${LOGFILE:-/dev/null}"; then
        echo "  removed (cargo target): ${_p/#$HOME/~}"; (( _FREED_KB += _szk ))
      else _rm "$_p"; fi ;;
    *) _rm "$_p" ;;
  esac
}

# The picker: open one fzf per category (biggest category first), prefaced by a per-category summary
# as a contents page. Each picker shows only that category's candidates (TAB mark, Ctrl-A select-all,
# Ctrl-D deselect-all, Esc skips the category), then reprints the chosen set, asks once, and dispatches
# deletion by type before moving to the next category. Esc / empty selection deletes NOTHING (never
# "empty = all"). Each fzf input line carries hidden fields for the preview pane and an index back into
# _PICK_ITEMS.
_run_picker() {
  (( ${#_PICK_ITEMS[@]} )) || { echo "$(c_dim "  Nothing reclaimable found to pick from.")"; return 0; }
  echo ""
  echo "$(c_head "── Select what to delete (one picker per category, biggest first) ──")"
  # NOTE: the {1..N} loop must never run with an empty registry: zsh `{1..0}` expands DESCENDING to
  # `1 0` (invalid index 0). The early-return above guards it.
  local _i _rec _mb _k; local -a _f; local -A _cat_n _cat_kb _cat_idx
  for _i in {1..${#_PICK_ITEMS[@]}}; do
    _rec="${_PICK_ITEMS[$_i]}"; _f=("${(@ps:\t:)_rec}")
    _cat_n[${_f[2]}]=$(( ${_cat_n[${_f[2]}]:-0} + 1 ))
    _cat_kb[${_f[2]}]=$(( ${_cat_kb[${_f[2]}]:-0} + ${_f[3]} ))
    _cat_idx[${_f[2]}]="${_cat_idx[${_f[2]}]} $_i"   # space-joined registry indices for this category
  done
  # Table of contents: per-category totals, biggest first. One picker opens per category below.
  echo "$(c_dim "  Reclaimable by category (a picker opens per category, biggest first; Esc skips one):")"
  for _k in "${(@k)_cat_kb}"; do printf '%s\t%s\n' "${_cat_kb[$_k]}" "$_k"; done | sort -rn | while IFS=$'\t' read -r _ckb _c; do
    printf "    %-14s %4d   %6d MB\n" "$_c" "${_cat_n[$_c]}" "$(( _ckb / 1024 ))"
  done
  # Categories in size-descending order.
  local -a _cats_sorted
  _cats_sorted=("${(@f)$(for _k in "${(@k)_cat_kb}"; do printf '%s\t%s\n' "${_cat_kb[$_k]}" "$_k"; done | sort -rn | cut -f2)}")
  # One fzf per category. Esc / empty selection skips that category (deletes nothing); a scoped
  # confirm precedes deletion, so each category is a self-contained unit (Ctrl-C keeps earlier ones).
  local _c _ckb _idx _line _tot; local -a _clines _csel
  for _c in "${_cats_sorted[@]}"; do
    [[ -n "$_c" ]] || continue
    echo ""
    echo "$(c_step "▸ ${_c}  (${_cat_n[$_c]} item(s), $(( ${_cat_kb[$_c]} / 1024 )) MB)")"
    _clines=()
    for _idx in ${=_cat_idx[$_c]}; do
      _rec="${_PICK_ITEMS[$_idx]}"; _f=("${(@ps:\t:)_rec}")
      _mb=$(( ${_f[3]} / 1024 ))
      # visible(1: size+path) \t idx(2) \t display(3) \t hint(4) \t note(5) \t mtime(6)
      _clines+=( "$(printf '%6dM  %s\t%d\t%s\t%s\t%s\t%s' "$_mb" "${_f[5]}" "$_idx" "${_f[5]}" "${_f[6]}" "${_f[7]}" "${_f[4]}")" )
    done
    _csel=()
    # --height=~80% keeps fzf INLINE (it would otherwise take the full alternate screen and blank the
    # scan output above); '~' sizes the box to this category's item count, so a 1-item category shows a
    # small box instead of an empty full screen. --layout=reverse puts the prompt/header at the top.
    while IFS= read -r -d '' _line; do
      [[ -n "$_line" ]] && _csel+=( "${${(@ps:\t:)_line}[2]}" )
    done < <(
      printf '%s\0' "${_clines[@]}" | fzf --multi --read0 --print0 \
        --height=~80% --layout=reverse --border=rounded \
        --delimiter=$'\t' --with-nth=1 --prompt="delete ${_c}> " \
        --bind 'ctrl-a:select-all,ctrl-d:deselect-all' \
        --header="${_c}: TAB mark   Ctrl-A all   Ctrl-D none   Enter confirm   Esc skip this category" \
        --preview='printf "%s\n\nLast modified: %s\nRecreate: %s\nNote: %s" {3} {6} {4} {5}' \
        --preview-window=down,6,wrap 2>/dev/null
    )
    if (( ${#_csel[@]} == 0 )); then echo "$(c_dim "  (skipped ${_c}, nothing selected)")"; continue; fi
    echo "$(c_head "  Selected from ${_c}:")"
    _tot=0
    for _i in "${_csel[@]}"; do
      _rec="${_PICK_ITEMS[$_i]}"; _f=("${(@ps:\t:)_rec}")
      printf "    %6dM  %s\n" "$(( ${_f[3]} / 1024 ))" "${_f[5]}"
      _tot=$(( _tot + ${_f[3]} ))
    done
    if _ask "  Delete these ${#_csel[@]} ${_c} item(s) (~$(( _tot / 1024 )) MB)?"; then
      for _i in "${_csel[@]}"; do
        _rec="${_PICK_ITEMS[$_i]}"; _f=("${(@ps:\t:)_rec}")
        _pick_delete "${_f[1]}" "${_f[8]}"
      done
    else
      echo "  kept ${_c}."
    fi
  done
}

# Graceful exit on Ctrl+C or SIGTERM: report freed space so far (from dehoard's own deletion tally,
# not a df delta, same honesty rule as print_result).
_cleanup_exit() {
  echo ""
  echo "$(c_warn "⚠️  Interrupted.")"
  (( _FREED_KB > 0 )) && echo "$(c_safe "🗑️  Freed so far: $(( _FREED_KB / 1024 )) MB")"
  exit 130
}
trap _cleanup_exit INT TERM

run_report() {
# ══════════════════════════════════════════════════════
# REPORT, Only with --report. Read-only disk audit, deletes nothing.
# ══════════════════════════════════════════════════════
if $REPORT; then
 if ! $JSON; then   # ── human-only report preamble (skipped entirely when --json) ──
  echo "📊 Disk usage report (read-only, nothing will be deleted)"
  # Surface last --apply run from existing deletion logs (zero new state, reads only).
  # Use zsh array glob (not ls glob) so NULL_GLOB expands to empty when no logs exist.
  local _last_log _last_date _last_freed
  local -a _logs; _logs=("$_CACHE_DIR"/run-*.log(N.om))   # N=nullglob, om=mtime newest-first → [1] is newest
  if (( ${#_logs} > 0 )); then
    _last_log="${_logs[1]}"
    _last_date=$(basename "$_last_log" .log | sed 's/run-//')
    _last_freed=$(awk '{sum+=$1} END{if(sum>0) printf "~%d MB freed", sum/1024; else print "nothing logged"}' "$_last_log" 2>/dev/null)
    echo "   Last --apply run: ${_last_date}  (${_last_freed})"
  fi
  echo "   Scanning home directory (may take a minute)…"
  echo ""
  echo "$(c_head "━━ Top 30 biggest directories under ~ ━━")"
  du -h -d 2 ~ 2>/dev/null | sort -rh | head -30

  echo ""
  echo "$(c_head "━━ Regenerable caches present (SAFE to clean) ━━")"
  echo "   These are reclaimed by the flag shown; everything else above is your data."
  _report_cache() {  # $1=size-label path, $2=description, $3=flag that clears it
    [[ -e "$1" ]] || return
    printf "  %-7s %-30s %s\n" "$(du -sh "$1" 2>/dev/null | cut -f1)" "$2" "$3"
  }
  _report_cache ~/Library/Caches                                                        "~/Library/Caches/*"   "--deep"
  _report_cache ~/Library/Application\ Support/Code/CachedExtensionVSIXs                 "VSCode ext cache"     "--deep"
  _report_cache ~/.cache/puppeteer                                                       "Puppeteer browsers"   "--deep"
  _report_cache ~/.cache/huggingface                                                     "HuggingFace models"   "--models"
  _report_cache ~/.cache/torch                                                           "PyTorch hub"          "--models"
  _report_cache ~/nltk_data                                                              "NLTK corpora"         "--models"
  _report_cache ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw       "Docker disk image"    "manual (see --deep)"
  # Generic sweep: biggest entries in the XDG + macOS cache roots over 100 MB.
  # NOTE: loop var must NOT be named 'path', in zsh that is tied to $PATH and
  # reading into it clobbers the command search path.
  for cache_root in ~/.cache ~/Library/Caches; do
    [[ -d "$cache_root" ]] || continue
    du -sk "$cache_root"/*/ 2>/dev/null | sort -rn | head -8 | while read kb cdir; do
      (( kb >= CACHE_MIN_MB * 1024 )) && printf "  %-7s %-30s %s\n" \
        "$(du -sh "$cdir" 2>/dev/null | cut -f1)" "${cdir/#$HOME/~}" "--scan (generic)"
    done
  done

  echo ""
  echo "$(c_head "━━ Code editors (extension dirs), size + last change ━━")"
  echo "   Idle for many months + large = candidate to remove (your call; not auto-deleted)."
  _ed_found=false
  for ext_dir in ~/.*/extensions(N/); do
    [[ -f "$ext_dir/.obsolete" || -f "$ext_dir/extensions.json" ]] || continue
    _ed_found=true
    printf "  %-16s %6s  last changed %s\n" "${${ext_dir:h}:t}" \
      "$(du -sh "$ext_dir" 2>/dev/null | cut -f1)" \
      "$(stat -f '%Sm' -t '%Y-%m-%d' "$ext_dir" 2>/dev/null)"
  done
  $_ed_found || echo "  (no VS Code-family editors found)"

  # ── Local model weights across ALL tools (the headline number) ──
  # The thing generic cleaners can't see: how many GB of LLM/ML weights are spread
  # across HuggingFace, Ollama, LM Studio, PyTorch hub, llama.cpp, etc.
  echo ""
  echo "$(c_head "━━ Local model weights across all tools ━━")"
  echo "   Clear via --models (interactive); each re-downloads on next use."
  _mw_total_kb=0
  # NOTE: all model sizing uses `du`, which counts a shared inode ONCE, so hardlinked /
  # content-addressed blobs (Ollama, HF) are not double-counted. Do NOT refactor to naive
  # per-file summing: it would inflate these GB figures and the cross-tool "reclaim" estimate,
  # turning a read-only number into a deletion mistake. (Pinned by the hardlink test in test/run.zsh.)
  _mw_row() {  # $1 = path, $2 = label
    [[ -d "$1" ]] || return
    local kb; kb=$(du -sk "$1" 2>/dev/null | cut -f1)
    (( kb > 0 )) || return
    _mw_total_kb=$(( _mw_total_kb + kb ))
    printf "  %8s  %-18s %s\n" "$(du -sh "$1" 2>/dev/null | cut -f1)" "$2" "${1/#$HOME/~}"
  }
  _mw_row ~/.cache/huggingface/hub   "HuggingFace"
  _mw_row ~/.ollama/models           "Ollama"
  _mw_row ~/.lmstudio/models         "LM Studio"
  _mw_row ~/.cache/torch/hub         "PyTorch hub"
  _mw_row ~/.cache/llama.cpp         "llama.cpp"
  _mw_row ~/.cache/gpt4all           "GPT4All"
  _mw_row ~/.cache/whisper           "Whisper"
  _mw_row ~/.keras                   "Keras"
  if (( _mw_total_kb > 0 )); then
    echo "  ────────"
    printf "  %8s  TOTAL local model weights across all tools\n" \
      "$(awk -v k="$_mw_total_kb" 'BEGIN{printf "%.1fG", k/1048576}')"
  else
    echo "  (no local model weights found)"
  fi
 fi   # ── end human-only report preamble ──

  # ── Cross-tool duplicate models (the headline reclaim number) ──
  # The same model family+size living in MULTIPLE tools (HF + Ollama + LM Studio …).
  # Matched by NORMALIZED NAME (family + param count), NOT by bytes, formats differ
  # (safetensors vs GGUF vs blobs). So this is a *potential-duplicate* flag, never an
  # auto-delete: a Q4≠Q8 and base≠instruct. Remove via --models only, after you verify.
  _hkb() {  # kb → human
    local kb=$1
    if   (( kb >= 1048576 )); then printf "%.1fG" "$(( kb/1048576.0 ))"
    elif (( kb >= 1024 ));    then printf "%dM" "$(( kb/1024 ))"
    else printf "%dK" "$kb"; fi
  }
  # ── JSON emit helpers (no jq dependency; hand-rolled, escaping-safe) ──
  _json_str() {  # $1 → a JSON-escaped, double-quoted string
    local s="${1:-}"
    s=${s//\\/\\\\}; s=${s//\"/\\\"}            # backslash FIRST, then quote
    s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
    # Escape any remaining control char (U+0000-U+001F) to \u00XX so a hostile name stays valid JSON.
    local c rest="$s"; s=""
    while [[ -n "$rest" ]]; do
      c="${rest[1]}"; rest="${rest[2,-1]}"
      if [[ "$c" == [$'\x01'-$'\x1f'] ]]; then
        s+=$(printf '\\u%04x' "$(( #c ))")
      else
        s+="$c"
      fi
    done
    printf '"%s"' "$s"
  }
  _json_str_or_null() {  # $1 → JSON string, but empty or "?" → null (queryable unknown)
    [[ -z "${1:-}" || "$1" == "?" ]] && { printf 'null'; return; }
    _json_str "$1"
  }
  _json_tools() {  # $1 = a "|HF||Ollama|" tool-set → JSON array ["HF","Ollama"]
    local t; local -a a
    for t in ${(s:|:)1}; do [[ -n "$t" ]] && a+=( "$(_json_str "$t")" ); done
    printf '[%s]' "${(j:,:)a}"
  }
  _norm_model() {  # name → "family-NNb" (best-effort canonical key; "-x" = no size found)
    local s="${1:l}" k fam="" params
    s="${s//[^a-z0-9.]/ }"
    for k in tinyllama codellama llama mixtral mistral qwen3 qwq qwen gemma phi4 phi3 phi deepseek \
             granite olmo smollm nemotron exaone minicpm internlm glm kimi mpt \
             vicuna falcon gptoss gpt2 yi "command r" stablelm starcoder whisper clip sdxl stable bert; do
      [[ " $s " == *" $k"* || " $s " == *"$k"* ]] && { fam="${k// /}"; break; }   # strip the space in multi-word tokens (e.g. "command r" → key "commandr")
    done
    params=$(print -r -- "$s" | grep -oiE '[0-9]+(\.[0-9]+)?b' | head -1)
    print -r -- "${fam:-${s%% *}}-${params:-x}"
  }
  _model_tags() {  # name → "<quant>|<variant>"  (quant '?' = unknown; variant defaults to base)
    local raw="${1:l}" w="${1:l}" q v="base"
    w="${w//[^a-z0-9]/ }"                                    # word-boundary form for variant match
    [[ " $w " == *" instruct "* || " $w " == *" chat "* || " $w " == *" it "* ]] && v="instruct"
    q=$(print -r -- "$raw" | grep -oiE 'q[0-9]+(_[0-9kms]+)?|bf16|fp?16|fp?32|int4|int8|4bit|8bit' | head -1)
    case "$q" in
      q[0-9]*)       q="${q%%_*}" ;;                         # q4_k_m → q4
      bf16|f16|fp16) q="f16" ;;
      f32|fp32)      q="f32" ;;
      int4|4bit)     q="q4" ;;
      int8|8bit)     q="q8" ;;
      *)             q="?" ;;
    esac
    print -r -- "$q|$v"
  }
  typeset -A _mdl_list _mdl_tools
  _mdl_add() {  # $1=tool $2=display $3=kb [$4=abs path] → entry: tool\tdisplay\tkb\tquant\tvariant\tpath
    (( $3 > 0 )) || return
    local key tags; key=$(_norm_model "$2"); tags=$(_model_tags "$2")
    _mdl_list[$key]+="$1	$2	$3	${tags%|*}	${tags#*|}	${4:-}"$'\n'
    [[ "${_mdl_tools[$key]}" == *"|$1|"* ]] || _mdl_tools[$key]+="|$1|"
  }
  for d in ~/.cache/huggingface/hub/models--*(N/); do
    nm="${${d:t}#models--}"; nm="${nm//--//}"
    _mdl_add HF "$nm" "$(du -sk "$d" 2>/dev/null | cut -f1)" "$d"
  done
  for f in ~/.lmstudio/models/**/*.gguf(N.); do
    _mdl_add LMStudio "${f:t:r}" "$(du -sk "$f" 2>/dev/null | cut -f1)" "$f"
  done
  for f in ~/.cache/torch/hub/checkpoints/*(N.); do
    _mdl_add PyTorch "${f:t:r}" "$(du -sk "$f" 2>/dev/null | cut -f1)" "$f"
  done
  if command -v ollama &>/dev/null; then
    # NOTE: declare these ONCE before the loop. A bare `local onm…` re-run each
    # iteration re-prints the already-set values to stdout in zsh (same class of
    # bug as the `local ln` leak), which would corrupt --report and --json.
    local _ollama_found=false onm="" osz="" ou="" okb=""
    while IFS= read -r line; do
      onm=${line%% *}; [[ -z "$onm" || "$onm" == "NAME" ]] && continue
      osz=$(print -r -- "$line" | awk '{print $3}'); ou=$(print -r -- "$line" | awk '{print $4}')
      okb=$(awk -v s="$osz" -v u="$ou" 'BEGIN{m=(u=="GB")?1048576:(u=="MB")?1024:(u=="TB")?1073741824:0; printf "%d", s*m}')
      _mdl_add Ollama "$onm" "$okb"; _ollama_found=true
    done < <(ollama list 2>/dev/null)
    $_ollama_found || $JSON || echo "  (ollama installed but no models found, is the daemon running? try: ollama serve)"
  fi

  # Split every cross-tool group into TRUE duplicates (same build → safe reclaim) vs
  # RELATED variants (a known Q4≠Q8 or base≠instruct conflict → listed, never counted).
  _dup_reclaim_kb=0 _dup_found=false _rel_found=false
  local _dup_buf="" _rel_buf=""
  local -a _json_dups _json_rels                            # JSON group accumulators (built only under --json)
  for key in ${(k)_mdl_list}; do
    [[ "$key" == *-x ]] && continue                          # no size token → don't risk a false dup
    local entries=("${(@f)${_mdl_list[$key]%$'\n'}}")
    local ntools=$(( ${#${(s:|:)_mdl_tools[$key]}} ))         # distinct tools
    (( ${#entries[@]} >= 2 && ntools >= 2 )) || continue     # real cross-tool group only
    local ln="" total=0 max=0; typeset -A _qseen _vseen; _qseen=() _vseen=()   # ln="" (not bare), bare `local ln` re-prints an already-set value to stdout in zsh
    local -a _grp_ent=()                                      # JSON per-copy entries for this group (=() avoids the same re-print leak)
    for ln in $entries; do
      local -a f=("${(@s:	:)ln}")                          # tool display kb quant variant path
      (( total += f[3] )); (( f[3] > max )) && max=$f[3]
      [[ "$f[4]" != "?" ]] && _qseen[$f[4]]=1
      _vseen[$f[5]]=1
      $JSON && _grp_ent+=( "{\"tool\":$(_json_str "$f[1]"),\"name\":$(_json_str "$f[2]"),\"size_bytes\":$(( f[3] * 1024 )),\"quant\":$(_json_str_or_null "$f[4]"),\"variant\":$(_json_str "$f[5]"),\"path\":$(_json_str_or_null "${f[6]:-}")}" )
    done
    local _tools_json=""; $JSON && _tools_json=$(_json_tools "${_mdl_tools[$key]}")
    if (( ${#_qseen} >= 2 || ${#_vseen} >= 2 )); then        # known conflict → related, not redundant
      _rel_found=true
      _rel_buf+=$(printf "  ● %-14s %d builds, ~%s total, DIFFERENT builds, not redundant" "$key" "${#entries[@]}" "$(_hkb $total)")$'\n'
      for ln in $entries; do local -a f=("${(@s:	:)ln}")
        _rel_buf+=$(printf "       %-9s %7s  %s  [%s/%s]" "$f[1]" "$(_hkb $f[3])" "$f[2]" "$f[4]" "$f[5]")$'\n'
      done
      $JSON && _json_rels+=( "{\"family\":$(_json_str "$key"),\"builds\":${#entries[@]},\"tools\":$_tools_json,\"total_bytes\":$(( total * 1024 )),\"entries\":[${(j:,:)_grp_ent}]}" )
    else                                                     # same build across tools → true duplicate
      _dup_found=true
      local reclaim=$(( total - max )); (( _dup_reclaim_kb += reclaim ))
      _dup_buf+=$(printf "  ● %-14s %d copies, ~%s total (keep 1 → reclaim ~%s)" "$key" "${#entries[@]}" "$(_hkb $total)" "$(_hkb $reclaim)")$'\n'
      for ln in $entries; do local -a f=("${(@s:	:)ln}")
        _dup_buf+=$(printf "       %-9s %7s  %s" "$f[1]" "$(_hkb $f[3])" "$f[2]")$'\n'
      done
      $JSON && _json_dups+=( "{\"family\":$(_json_str "$key"),\"copies\":${#entries[@]},\"tools\":$_tools_json,\"total_bytes\":$(( total * 1024 )),\"reclaim_bytes\":$(( reclaim * 1024 )),\"entries\":[${(j:,:)_grp_ent}]}" )
    fi
  done
  if $JSON; then
    # Full physical inventory: every model instance across all tools (not just duplicates).
    local -a _json_models; local _k _ln
    for _k in ${(k)_mdl_list}; do
      for _ln in "${(@f)${_mdl_list[$_k]%$'\n'}}"; do
        local -a _ff=("${(@s:	:)_ln}")        # tool display kb quant variant path
        _json_models+=( "{\"tool\":$(_json_str "$_ff[1]"),\"name\":$(_json_str "$_ff[2]"),\"family\":$(_json_str "$_k"),\"quant\":$(_json_str_or_null "$_ff[4]"),\"variant\":$(_json_str "$_ff[5]"),\"size_bytes\":$(( _ff[3] * 1024 )),\"path\":$(_json_str_or_null "${_ff[6]:-}")}" )
      done
    done
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "generated_by": "dehoard",\n'
    printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "models": [%s],\n' "${(j:,:)_json_models}"
    printf '  "cross_tool_duplicates": [%s],\n' "${(j:,:)_json_dups}"
    printf '  "related_variants": [%s],\n' "${(j:,:)_json_rels}"
    printf '  "total_reclaim_bytes": %d\n' "$(( _dup_reclaim_kb * 1024 ))"
    printf '}\n'
    exit 0
  fi
  if $_dup_found; then
    echo ""
    echo "$(c_head "━━ True cross-tool duplicate models (same build in 2+ tools) ━━")"
    echo "   Same family, size, quant & variant, safe to keep one. VERIFY, then remove the"
    echo "   redundant copy via --models; dehoard never auto-deletes weights."
    printf "%s" "$_dup_buf"
    echo "  ────────"
    printf "  ⭐ Potential reclaim from cross-tool duplicates: ~%s\n" "$(_hkb $_dup_reclaim_kb)"
  fi
  if $_rel_found; then
    echo ""
    echo "$(c_head "── Related cross-tool variants (same model, DIFFERENT build, NOT counted) ──")"
    echo "   Same family+size but a differing quant (Q4≠Q8) or variant (base≠instruct);"
    echo "   these are not interchangeable, so no reclaim is claimed."
    printf "%s" "$_rel_buf"
  fi

  # ── Orphaned app caches (read-only count), apps removed, caches left behind ──
  # Map every installed .app to its CFBundleIdentifier, then flag ~/Library/Caches
  # folders named like a bundle id with no matching app. Report-only & count-only:
  # dehoard stays dev/ML-scoped; removing general app leftovers is out of scope (a job for a
  # dedicated app uninstaller).
  typeset -A _inst_bid
  for _app in /Applications/*.app(N) ~/Applications/*.app(N) /System/Applications/*.app(N); do
    _bid=$(defaults read "$_app/Contents/Info" CFBundleIdentifier 2>/dev/null) || continue
    [[ -n "$_bid" ]] && _inst_bid[${_bid:l}]=1
  done
  _orphan_cache_kb=0 _orphan_cache_n=0
  for _c in ~/Library/Caches/*(N/); do
    _name="${_c:t}"
    [[ "$_name" == *.*.* ]] || continue                       # looks like a bundle id (a.b.c)
    [[ "${_name:l}" == com.apple.* ]] && continue             # macOS system caches, not a removed app
    [[ -n "${_inst_bid[${_name:l}]}" ]] && continue           # app still installed → not orphaned
    _ckb=$(du -sk "$_c" 2>/dev/null | cut -f1); (( _ckb >= 10240 )) || continue   # ignore <10MB noise
    (( _orphan_cache_kb += _ckb, _orphan_cache_n++ ))
  done
  if (( _orphan_cache_n > 0 )); then
    echo ""
    echo "$(c_head "── Orphaned app caches (app no longer installed) ──")"
    printf "  %d cache folder(s), ~%s total in ~/Library/Caches with no matching app.\n" \
      "$_orphan_cache_n" "$(_hkb $_orphan_cache_kb)"
    echo "  Read-only, dehoard stays dev/ML-scoped; general app leftovers are a job for a dedicated app uninstaller."
  fi

  # Ignore list summary
  local _ign="$_IGNORE_FILE"
  if [[ -f "$_ign" ]]; then
    local _ign_n; _ign_n=$(wc -l < "$_ign" | tr -d ' ')
    echo ""
    printf "  ℹ️  Ignore list: %d path(s) always-skipped  (dehoard --list-ignored to review, --reset-ignore to clear)\n" "$_ign_n"
  fi

  echo ""
  echo "💾 Free space: $(df -h / | awk 'NR==2 {print $4}') of $(df -h / | awk 'NR==2 {print $2}')"
  echo "   (run with --deep / --models / --scan to reclaim; default is preview, add --apply)"
  exit 0
fi
}

clean_tier1() {

# ══════════════════════════════════════════════════════
# TIER 1, Always safe. Zero consequences. Run anytime.
# ══════════════════════════════════════════════════════

echo "$(c_step "Clearing browser update clones...")"
# Generic: ANY app's code-sign clone (Chrome/Brave/Edge/Arc/Vivaldi/Opera/…). These
# are update artifacts that are supposed to self-delete but often don't. No app list.
_rm "${BASE}/X/"*.code_sign_clone

echo "$(c_step "Clearing screenshot temp dirs...")"
_rm "${TMPDIR}TemporaryItems/NSIRD_screencaptureui_"*

echo "$(c_step "Clearing stale temp files...")"
_rm "${TMPDIR}com.microsoft.EdgeUpdater."*
_rm "${TMPDIR}node-compile-cache"
_rm "${TMPDIR}agent-browser-chrome-"*
_rm "${TMPDIR}exthost-"*.cpuprofile
_rm "${TMPDIR}hsperfdata_"*
_rm "${TMPDIR}xcrun_db"
_rm "${TMPDIR}VSFeedbackVSRTCLogs"

echo "$(c_step "Clearing var/folders browser helper caches...")"
# Generic: helper render caches for ANY browser (regenerated on next launch). ${BASE}/C
# is the per-user DARWIN cache dir, everything under it is regenerable by definition,
# so a *.helper glob is safe and covers every Chromium browser, not a hardcoded three.
_rm "${BASE}/C/"*.helper "${BASE}/C/"*.helper.plugin

echo "$(c_step "Cleaning package managers...")"
if $DRY_RUN; then
  command -v brew &>/dev/null && echo "  [dry-run] would run: brew cleanup -s --prune=all, brew autoremove"
  command -v npm  &>/dev/null && echo "  [dry-run] would run: npm cache clean --force"
  command -v pnpm &>/dev/null && echo "  [dry-run] would run: pnpm store prune"
  command -v yarn &>/dev/null && echo "  [dry-run] would run: yarn cache clean"
  echo "  [dry-run] would run: pip cache purge (pip3.7-3.25), uv cache clean, bun pm cache rm"
else
  # Each external tool runs under a timeout so one hung command can't freeze the run.
  _pm_run "brew cleanup"   brew cleanup -s --prune=all   # -s also scrubs the download cache (~/Library/Caches/Homebrew)
  _pm_run "brew autoremove" brew autoremove
  _pm_run "npm cache"      npm cache clean --force
  _pm_run "pnpm store"     pnpm store prune
  _pm_run "yarn cache"     yarn cache clean
  for pip_cmd in pip pip3 $(seq 7 25 | xargs -I{} echo pip3.{}); do
    _pm_run "$pip_cmd cache" "$pip_cmd" cache purge
  done
  _pm_run "uv cache"       uv cache clean
  _pm_run "bun cache"      bun pm cache rm
  _pm_run "trunk cache"    trunk cache prune
fi

echo "$(c_step "Clearing node-gyp cache...")"
_rm ~/Library/Caches/node-gyp

echo "$(c_step "Clearing Node.js compile cache...")"
_rm ~/.cache/node

echo "$(c_step "Clearing fontconfig cache...")"
_rm ~/.cache/fontconfig

echo "$(c_step "Clearing npx binary cache...")"
_rm ~/.npm/_npx

echo "$(c_step "Clearing CPAN cache...")"
if [[ -d ~/.cpan ]]; then
  # CPAN unpacks build dirs as mode 0555 (read-only); rm can't traverse them
  # until they're writable. Make writable first, then remove.
  $DRY_RUN || chmod -R u+w ~/.cpan/build ~/.cpan/sources 2>/dev/null
  _rm ~/.cpan/build
  _rm ~/.cpan/sources
fi

echo "$(c_step "Clearing Selenium WebDriver cache...")"
_rm ~/.cache/selenium

echo "$(c_step "Clearing Go module download cache...")"
if command -v go &>/dev/null; then
  if $DRY_RUN; then
    GO_CACHE=$(go env GOPATH 2>/dev/null)/pkg/mod/cache
    [[ -d "$GO_CACHE" ]] && echo "  [dry-run] would run: go clean -modcache ($(du -sh "$GO_CACHE" 2>/dev/null | cut -f1))"
  else
    go clean -modcache 2>/dev/null
  fi
elif [[ -d ~/go/pkg/mod/cache ]]; then
  _rm ~/go/pkg/mod/cache
fi

echo "$(c_step "Clearing Cargo download caches...")"
_CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
if [[ -d "$_CARGO_HOME/registry" || -d "$_CARGO_HOME/git" ]]; then
  _rm "$_CARGO_HOME/registry/cache"    # compressed .crate tarballs
  _rm "$_CARGO_HOME/registry/src"      # unpacked crate sources
  _rm "$_CARGO_HOME/git/checkouts"     # working copies of git-sourced deps
fi

echo "$(c_step "Clearing Gradle caches...")"
if [[ -d ~/.gradle ]]; then
  _rm ~/.gradle/caches
  _rm ~/.gradle/daemon
fi

echo "$(c_step "Clearing Maven local repository...")"
[[ -d ~/.m2/repository ]] && _rm ~/.m2/repository

echo "$(c_step "Clearing NuGet package cache...")"
# .NET global package cache, re-downloaded on next 'dotnet restore'. Do NOT touch
# ~/.dotnet (contains the SDK itself, not cache).
[[ -d ~/.nuget/packages ]] && _rm ~/.nuget/packages

echo "$(c_step "Clearing Jupyter checkpoint dirs...")"
find ~ -maxdepth 10 \
  \( -name node_modules -o -name .venv -o -name venv -o -name .git \
     -o -name .cache -o -name Library -o -name .nvm -o -name .cursor \
     -o -name .vscode -o -name site-packages \) -prune -o \
  -name ".ipynb_checkpoints" -type d -print \
  2>/dev/null | while IFS= read -r d; do _rm "$d"; done

echo "$(c_step "Removing old installer DMGs from ~/Downloads (>30 days, >50 MB)...")"
find ~/Downloads -maxdepth 1 -name "*.dmg" -mtime +30 -size +50M 2>/dev/null \
  | while IFS= read -r f; do
    echo "  Removing: $(basename "$f") ($(du -sh "$f" 2>/dev/null | cut -f1))"
    _rm "$f"
  done

echo "$(c_step "Emptying trash and old logs...")"
_rm ~/.Trash/*
_rm ~/Library/Logs/CrashReporter/MobileDevice/*

echo "$(c_step "Pruning old Time Machine snapshots (keeping latest)...")"
# Keep only date-formatted rows (e.g. 2026-05-31-081452); drops the "Snapshot dates for disk /:"
# header line that `tmutil` prints, which must never be mistaken for a snapshot to delete.
SNAP_DATES=(${(f)"$(sudo tmutil listlocalsnapshotdates / 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort)"})
if (( ${#SNAP_DATES[@]} > 1 )); then
  for date in ${SNAP_DATES[1,-2]}; do
    if $DRY_RUN; then
      echo "  [dry-run] would delete snapshot: $date"
    else
      sudo tmutil deletelocalsnapshots "$date" 2>/dev/null
    fi
  done
  echo "  Kept: ${SNAP_DATES[-1]}"
elif (( ${#SNAP_DATES[@]} == 1 )); then
  echo "  Only one snapshot exists, keeping it"
else
  echo "  No snapshots found"
fi

}

clean_deep() {
# ══════════════════════════════════════════════════════
# TIER 2, Only with --deep.
# ══════════════════════════════════════════════════════

if $DEEP; then
  echo ""
  echo "$(c_warn "⚠️  Deep cleanup starting...")"

  echo "$(c_step "Clearing all user Library caches...")"
  _rm ~/Library/Caches/*

  echo "$(c_step "Clearing compiler cache...")"
  _rm "${BASE}/C/clang"

  echo "$(c_step "Clearing Python bytecode cache...")"
  _rm "${BASE}/C/org.python.python"

  echo "$(c_step "Clearing Metal shader cache...")"
  _rm "${BASE}/C/com.apple.metal"

  echo "$(c_step "Clearing system Apple caches (own user only)...")"
  # This is the one delete that bypasses _rm (it needs sudo), so guard $BASE explicitly here rather
  # than relying on NULL_GLOB: only proceed when $BASE is a real per-user temp root. A mis-computed
  # BASE (e.g. unset $TMPDIR → "/") is refused, not handed to `sudo rm -rf`.
  if [[ "$BASE" != /var/folders/* && "$BASE" != /private/var/folders/* ]]; then
    echo "  $(c_dim "skipped system Apple caches: \$TMPDIR is not under /var/folders (BASE='${BASE}')")"
  elif $DRY_RUN; then
    echo "  [dry-run] would delete: ${BASE}/C/com.apple.* (requires sudo)"
  else
    # Intentionally NOT added to the _FREED_KB "Storage freed" tally: these are root-owned, so an
    # accurate size needs `sudo du`, and the caches are small. Accepted under-count (never an over-count).
    sudo rm -rf "${BASE}/C/com.apple."* 2>/dev/null
  fi

  echo "$(c_step "Clearing Xcode derived data...")"
  _rm ~/Library/Developer/Xcode/DerivedData

  echo "$(c_step "Clearing VSCode Application Support caches...")"
  for _vscode_cache_dir in CachedExtensionVSIXs CachedData Cache logs Crashpad; do
    _rm ~/Library/Application\ Support/Code/$_vscode_cache_dir
    _rm ~/Library/Application\ Support/Cursor/$_vscode_cache_dir
  done

  if [[ -d ~/Library/Application\ Support/Discord/Cache ]]; then
    echo "$(c_step "Clearing Discord cache...")"
    _rm ~/Library/Application\ Support/Discord/Cache
    _rm ~/Library/Application\ Support/Discord/Code\ Cache
  fi

  if command -v xcrun &>/dev/null; then
    echo "Removing unavailable iOS simulators..."
    if $DRY_RUN; then
      echo "  [dry-run] would run: xcrun simctl delete unavailable"
    else
      xcrun simctl delete unavailable 2>/dev/null
    fi
    _rm ~/Library/Developer/CoreSimulator/Caches
  fi

  if command -v ccache &>/dev/null && [[ -d ~/.ccache ]]; then
    CCACHE_SIZE=$(du -sh ~/.ccache 2>/dev/null | cut -f1)
    echo "$(c_step "Clearing ccache (${CCACHE_SIZE}), next C/C++ build will be a full recompile...")"
    if $DRY_RUN; then
      echo "  [dry-run] would run: ccache --clear"
    else
      ccache --clear 2>/dev/null || _rm ~/.ccache
    fi
  fi

  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    echo "$(c_step "Pruning Docker (stopped containers, dangling images, unused networks, build cache)...")"
    if $DRY_RUN; then
      echo "  [dry-run] would run: docker system prune -f"
      echo "  [dry-run] would run: docker builder prune -af"
    else
      docker system prune -f 2>/dev/null          # containers, dangling images, networks
      docker builder prune -af 2>/dev/null         # ALL build cache, often the biggest hidden win
    fi
  else
    echo "$(c_dim "Skipping Docker prune (daemon not running)")"
  fi

  # Docker/OrbStack/Colima disk images never auto-shrink after prune, report + how to reclaim.
  # (Informational only; safe compaction requires stopping the VM and is not automated here.)
  for _vm_img in \
    ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw \
    ~/Library/Containers/com.docker.docker/Data/vms/0/Docker.raw \
    ~/.docker/desktop/vms/0/data/Docker.raw \
    ~/.colima/_lima/colima/diffdisk \
    ~/.orbstack/data/drive.img; do
    if [[ -f "$_vm_img" ]]; then
      echo "Container VM disk image: $(du -sh "$_vm_img" 2>/dev/null | cut -f1)  ${_vm_img/#$HOME/~}"
      echo "  This file does NOT shrink after prune. To reclaim the freed space:"
      echo "    Docker Desktop → Settings → Resources → 'Clean / Purge data', or"
      echo "    colima: 'colima stop && colima delete && colima start' (rebuilds), or"
      echo "    OrbStack auto-compacts, no action needed."
    fi
  done

  if [[ -d ~/.cache/huggingface ]]; then
    HF_SIZE=$(du -sh ~/.cache/huggingface 2>/dev/null | cut -f1)
    echo "$(c_step "Clearing HuggingFace cache (${HF_SIZE})...")"
    echo "  (Use --models instead of --deep to pick specific entries to keep.)"
    _rm ~/.cache/huggingface
  fi

  if [[ -d ~/Library/Caches/ms-playwright ]]; then
    PW_SIZE=$(du -sh ~/Library/Caches/ms-playwright 2>/dev/null | cut -f1)
    echo "Playwright browser binaries: ${PW_SIZE} (covered by Library/Caches/* wipe above)"
  fi

  if [[ -d ~/.cache/puppeteer ]]; then
    PUP_SIZE=$(du -sh ~/.cache/puppeteer 2>/dev/null | cut -f1)
    echo "$(c_step "Clearing Puppeteer browser cache (${PUP_SIZE})...")"
    _rm ~/.cache/puppeteer
  fi

  echo "$(c_step "Running git gc on large repositories (>100 MB .git)...")"
  echo "  (may take 30s-2 min per repo)"
  for search_dir in $GIT_GC_ROOTS; do
    [[ -d "$search_dir" ]] || continue
    find "$search_dir" -maxdepth 5 -name ".git" -type d \
      -not -path "*/.venv/*" -not -path "*/node_modules/*" 2>/dev/null \
      | while IFS= read -r gitdir; do
          repo="${gitdir%/.git}"
          size_kb=$(du -sk "$gitdir" 2>/dev/null | cut -f1)
          if (( size_kb > 102400 )); then
            echo "  gc: $repo ($(( size_kb / 1024 )) MB)"
            if $DRY_RUN; then
              echo "  [dry-run] would run: git gc --prune=2.weeks.ago in $repo"
            else
              git -C "$repo" gc --prune=2.weeks.ago 2>/dev/null
            fi
          fi
        done
  done

  _ANDROID_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  if [[ -d "$_ANDROID_SDK/system-images" ]]; then
    ANDROID_IMG_SIZE=$(du -sh "$_ANDROID_SDK/system-images" 2>/dev/null | cut -f1)
    echo "Android SDK system-images: ${ANDROID_IMG_SIZE} (API levels installed:)"
    ls "$_ANDROID_SDK/system-images/" 2>/dev/null | while IFS= read -r api; do
      du -sh "$_ANDROID_SDK/system-images/$api/" 2>/dev/null | awk '{printf "  %s  %s\n", $1, $2}'
    done
    echo "  Remove old APIs: sdkmanager --uninstall \"system-images;android-XX;google_apis;x86_64\""
    echo "  Or: Android Studio → SDK Manager → SDK Platforms → uncheck old versions"
  fi

  echo "$(c_step "Deleting remaining Time Machine snapshots...")"
  if (( ${#SNAP_DATES[@]} > 0 )); then
    if $DRY_RUN; then
      echo "  [dry-run] would delete snapshot: ${SNAP_DATES[-1]}"
    else
      sudo tmutil deletelocalsnapshots "${SNAP_DATES[-1]}" 2>/dev/null
    fi
  fi
fi
}

clean_models() {

# ══════════════════════════════════════════════════════
# MODELS, Only with --models.
# ══════════════════════════════════════════════════════

if $MODELS; then
  echo ""
  echo "$(c_bold "🤖 LLM model cleanup (interactive)...")"

  if command -v ollama &>/dev/null; then
    echo ""
    OLLAMA_SIZE=$(du -sh ~/.ollama/models 2>/dev/null | cut -f1)
    echo "$(c_head "── Ollama models (${OLLAMA_SIZE:-unknown}) ──")"
    OLLAMA_MODELS=(${(f)"$(ollama list 2>/dev/null | awk 'NR>1 {print $1}')"})
    if (( ${#OLLAMA_MODELS[@]} == 0 )); then
      echo "  No models installed."
    else
      ollama list 2>/dev/null
      if _ask "Delete all Ollama models?"; then
        # ollama rm bypasses _rm; Ollama is content-addressed (per-model du is wrong), so measure the
        # store size before/after and credit the delta to the honest "Storage freed" tally.
        local _oll_before=0 _oll_after=0 _oll_d=0
        $DRY_RUN || { _oll_before=$(du -sk ~/.ollama/models 2>/dev/null | cut -f1); [[ -n "$_oll_before" ]] || _oll_before=0; }
        for model in $OLLAMA_MODELS; do
          if $DRY_RUN; then
            echo "  [dry-run] would remove: $model"
          else
            echo "  Removing: $model"
            if ! ollama rm "$model" 2>&1; then
              echo "$(c_warn "  ⚠️  Failed to remove: $model")"
            fi
          fi
        done
        if ! $DRY_RUN; then
          _oll_after=$(du -sk ~/.ollama/models 2>/dev/null | cut -f1); [[ -n "$_oll_after" ]] || _oll_after=0
          _oll_d=$(( _oll_before - _oll_after )); (( _oll_d > 0 )) && (( _FREED_KB += _oll_d ))
        fi
      fi
    fi
  fi

  if [[ -d ~/.lmstudio/models ]]; then
    echo ""
    LMS_SIZE=$(du -sh ~/.lmstudio/models 2>/dev/null | cut -f1)
    echo "$(c_head "── LM Studio models (${LMS_SIZE}) ──")"
    find ~/.lmstudio/models -name "*.gguf" 2>/dev/null | while IFS= read -r f; do
      printf "  %-8s %s\n" "$(du -sh "$f" 2>/dev/null | cut -f1)" "${f/#$HOME\/.lmstudio\/models\//}"
    done
    if _ask "Delete all LM Studio .gguf files?"; then
      if $DRY_RUN; then
        find ~/.lmstudio/models -name "*.gguf" 2>/dev/null | while IFS= read -r f; do
          echo "  [dry-run] would delete: $f"
        done
      else
        # Route each .gguf through _rm so deletion is logged, safe-root-guarded, ignore-aware,
        # and tallied. Process substitution (not a pipe) keeps the loop in the main shell, so
        # _rm's _FREED_KB increment is not lost to a subshell. NUL-safe for spaced paths.
        local f
        while IFS= read -r -d '' f; do
          _rm "$f"
        done < <(find ~/.lmstudio/models -name "*.gguf" -print0 2>/dev/null)
        echo "  Done. Re-download models from the LM Studio app."
      fi
    fi
  fi

  if [[ -d ~/.cache/huggingface ]] && ! $DEEP; then
    echo ""
    HF_SIZE=$(du -sh ~/.cache/huggingface 2>/dev/null | cut -f1)
    echo "$(c_head "── HuggingFace cache (${HF_SIZE}) ──")"
    du -sh ~/.cache/huggingface/hub/models--* 2>/dev/null | sort -rh | head -10
    du -sh ~/.cache/huggingface/hub/datasets--* 2>/dev/null | sort -rh | head -5
    echo "  Tip: 'huggingface-cli delete-cache' lets you pick specific entries."
    if _ask "Clear entire HuggingFace cache?"; then
      _rm ~/.cache/huggingface
      $DRY_RUN || echo "  Done. Models re-download on next use."
    fi
  fi

  if [[ -d ~/nltk_data ]]; then
    echo ""
    NLTK_SIZE=$(du -sh ~/nltk_data 2>/dev/null | cut -f1)
    echo "$(c_head "── NLTK corpora (${NLTK_SIZE}) ──")"
    du -sh ~/nltk_data/*/ 2>/dev/null | sort -rh | head -10
    echo "  Reinstall any corpus: python -c \"import nltk; nltk.download('corpus_name')\""
    if _ask "Clear entire NLTK data directory?"; then
      _rm ~/nltk_data
      $DRY_RUN || echo "  Done. Re-download with nltk.download()."
    fi
  fi

  if [[ -d ~/.cache/torch ]]; then
    echo ""
    TORCH_SIZE=$(du -sh ~/.cache/torch 2>/dev/null | cut -f1)
    echo "$(c_head "── PyTorch Hub model cache (${TORCH_SIZE}) ──")"
    du -sh ~/.cache/torch/hub/*/ 2>/dev/null | sort -rh | head -10
    echo "  Models re-download on next torch.hub.load()."
    if _ask "Clear entire PyTorch Hub cache?"; then
      _rm ~/.cache/torch
      $DRY_RUN || echo "  Done. Models re-download on next use."
    fi
  fi
fi

}

run_scan() {
# ══════════════════════════════════════════════════════
# SCAN, Only with --scan. Full project tree crawl.
# ══════════════════════════════════════════════════════

if $SCAN; then
  echo ""
  echo "$(c_bold "🔍 Scanning project tree for artifacts...")"

  # --pick collection mode: only when --pick is set, fzf is usable, AND we're actually deleting
  # (--apply, i.e. ! $DRY_RUN). In this mode in-scope sections REGISTER candidates instead of
  # prompting, and the picker (_run_picker, one fzf per category) runs after the scan. Otherwise sections behave
  # exactly as before (preview, or the per-item prompts when fzf is absent).
  _COLLECT=false
  $PICK && _have_picker && ! $DRY_RUN && _COLLECT=true
  if $PICK && ! $_COLLECT && $DRY_RUN; then
    echo "$(c_dim "  (--pick selects what to delete; it takes effect with --apply.)")"
  fi

  # ── find -prune skip lists ─────────────────────────────────────────
  # These stop find from DESCENDING into dirs, so their contents are never seen.
  # Three variants: _SKIP (for artifact finds), _SKIP_ENV (keeps .venv/venv visible),
  # _SKIP_NM (keeps node_modules visible). Each expands to tokens for: \( ... \) -prune

  # For artifact scans, prune everything that contains regenerable build output
  _SKIP=(
    -name node_modules  -o -name .venv        -o -name venv
    -o -name .git       -o -name .cache       -o -name Library
    -o -name .cursor    -o -name .vscode      -o -name .trae
    -o -name .antigravity -o -name .lmstudio  -o -name .ollama
    -o -name .bun       -o -name .nvm         -o -name site-packages
    -o -name .cargo     -o -name .rustup
  )

  # For venv/Cargo.toml discovery, same but KEEP .venv and venv visible
  _SKIP_ENV=(
    -name node_modules  -o -name .git         -o -name .cache
    -o -name Library    -o -name .cursor      -o -name .vscode
    -o -name .trae      -o -name .antigravity -o -name .lmstudio
    -o -name .ollama    -o -name .bun         -o -name .nvm
    -o -name site-packages -o -name .cargo    -o -name .rustup
  )

  # For node_modules discovery, same but KEEP node_modules visible
  _SKIP_NM=(
    -name .venv         -o -name venv         -o -name .git
    -o -name .cache     -o -name Library      -o -name .cursor
    -o -name .vscode    -o -name .trae        -o -name .antigravity
    -o -name .lmstudio  -o -name .ollama      -o -name .bun
    -o -name .nvm       -o -name site-packages -o -name .cargo
    -o -name .rustup
  )

  # ── Python virtual environments ────────────────────
  echo ""
  echo "$(c_head "── Python virtual environments (detected by content, any folder name) ──")"
  # Detect venvs by their canonical marker, pyvenv.cfg, NOT by folder name.
  # This catches .venv, venv, env, deploy-env, client_venv.x, my-project-env, etc.
  # _SKIP_ENV prunes app-bundled runtimes (.lmstudio, .ollama, .cache, Library…)
  # so we never offer to delete a Python env that belongs to an installed app.
  VENV_CFGS=(${(f)"$(
    find ~ -maxdepth 9 \( "${_SKIP_ENV[@]}" \) -prune -o \
      -name "pyvenv.cfg" -type f -print 2>/dev/null | sort -u
  )"})
  VENV_TOTAL_KB=0
  FOUND_VENV=false
  if $_COLLECT; then
    local -a _vd=(); for cfg in $VENV_CFGS; do [[ -d "${cfg:h}" ]] && _vd+=("${cfg:h}"); done
    (( ${#_vd[@]} )) && { FOUND_VENV=true; _register rm "venv" "python -m venv <dir> / uv sync / poetry install" "-" "${_vd[@]}"; }
  else
  for cfg in $VENV_CFGS; do
    d="${cfg:h}"                 # venv dir = parent of pyvenv.cfg
    [[ -d "$d" ]] || continue
    FOUND_VENV=true
    size_kb=$(du -sk "$d" 2>/dev/null | cut -f1)
    size_mb=$(( size_kb / 1024 ))
    modified=$(stat -f "%Sm" -t "%Y-%m-%d" "$d" 2>/dev/null)
    printf "  %5dM  %s  %s\n" "$size_mb" "$modified" "${d/#$HOME/~}"
    if _ask "         Delete?"; then
      _rm "$d"
      if ! $DRY_RUN; then
        parent=$(dirname "$d")
        if [[ -f "$parent/pyproject.toml" ]]; then
          echo "         Deleted. Recreate: uv sync  or  poetry install  or  pip install -e ."
        elif [[ -f "$parent/requirements.txt" ]]; then
          echo "         Deleted. Recreate: python -m venv $d && pip install -r $parent/requirements.txt"
        else
          echo "         Deleted."
        fi
      fi
      VENV_TOTAL_KB=$(( VENV_TOTAL_KB + size_kb ))
    fi
  done
  fi
  $FOUND_VENV || echo "  None found."
  (( VENV_TOTAL_KB > 0 )) && ! $DRY_RUN && echo "  Freed from venvs: $(( VENV_TOTAL_KB / 1024 )) MB"

  # ── Conda environments ─────────────────────────────
  echo ""
  echo "$(c_head "── Conda environments ──")"
  FOUND_CONDA=false
  CONDA_TOTAL_KB=0
  for conda_base in ~/miniconda3 ~/anaconda3 ~/mambaforge ~/.conda; do
    [[ -d "$conda_base/envs" ]] || continue
    for d in "$conda_base/envs"/*/; do
      [[ -d "$d" ]] || continue
      if $_COLLECT; then FOUND_CONDA=true; _register conda "conda env" "conda create -n <name> python=3.x" "removed via 'conda env remove' to avoid stale environments.txt metadata" "$d"; continue; fi
      FOUND_CONDA=true
      size_kb=$(du -sk "$d" 2>/dev/null | cut -f1)
      size_mb=$(( size_kb / 1024 ))
      modified=$(stat -f "%Sm" -t "%Y-%m-%d" "$d" 2>/dev/null)
      printf "  %5dM  %s  %s\n" "$size_mb" "$modified" "${d/#$HOME/~}"
      if _ask "         Delete?"; then
        env_name=$(basename "${d%/}")
        if $DRY_RUN; then
          echo "  [dry-run] would remove conda env: $env_name"
        else
          # Count toward the honest "Storage freed" tally only on a real native removal; the _rm
          # fallback counts itself, so guard to the success branch to avoid double-counting.
          if [[ "$env_name" != -* ]] && conda env remove -n "$env_name" -y 2>/dev/null; then (( _FREED_KB += size_kb )); else _rm "$d"; fi   # dash-leading name → safe path delete
          echo "         Deleted. Recreate: conda create -n $env_name python=3.x"
        fi
        CONDA_TOTAL_KB=$(( CONDA_TOTAL_KB + size_kb ))
      fi
    done
  done
  $FOUND_CONDA || echo "  None found."
  (( CONDA_TOTAL_KB > 0 )) && ! $DRY_RUN && echo "  Freed from conda envs: $(( CONDA_TOTAL_KB / 1024 )) MB"

  # ── uv Python installations ─────────────────────────
  echo ""
  echo "$(c_head "── uv Python installations ──")"
  _UV_PY_DIR="${UV_PYTHON_INSTALL_DIR:-$HOME/.local/share/uv/python}"
  FOUND_UV_PY=false
  if [[ -d "$_UV_PY_DIR" ]]; then
    for d in "$_UV_PY_DIR"/*/; do
      [[ -d "$d" ]] || continue
      if $_COLLECT; then FOUND_UV_PY=true; _register uv "uv python" "uv python install <name>" "removed via 'uv python uninstall'" "$d"; continue; fi
      FOUND_UV_PY=true
      py_name=$(basename "$d")
      size_kb=$(du -sk "$d" 2>/dev/null | cut -f1); size_mb=$(( size_kb / 1024 ))
      modified=$(stat -f "%Sm" -t "%Y-%m-%d" "$d" 2>/dev/null)
      printf "  %5dM  %s  %s\n" "$size_mb" "$modified" "$py_name"
      if _ask "         Uninstall?"; then
        if $DRY_RUN; then
          echo "  [dry-run] would run: uv python uninstall $py_name"
        elif command -v uv &>/dev/null; then
          # Count freed space only on a real native uninstall; _rm fallback counts itself.
          if [[ "$py_name" != -* ]] && uv python uninstall "$py_name" 2>/dev/null; then (( _FREED_KB += size_kb )); else _rm "$d"; fi   # dash-leading name → safe path delete
          echo "         Uninstalled. Reinstall: uv python install $py_name"
        else
          _rm "$d"
        fi
      fi
    done
  fi
  $FOUND_UV_PY || echo "  None found."

  # ── Android SDK system-images ───────────────────────
  echo ""
  echo "$(c_head "── Android SDK system-images ── PER ENTRY")"
  _ANDROID_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  # Resolve sdkmanager, usually NOT on PATH; lives under cmdline-tools/ or tools/
  _SDKMANAGER=""
  if command -v sdkmanager &>/dev/null; then
    _SDKMANAGER="sdkmanager"
  else
    for _c in "$_ANDROID_SDK"/cmdline-tools/latest/bin/sdkmanager \
              "$_ANDROID_SDK"/cmdline-tools/*/bin/sdkmanager \
              "$_ANDROID_SDK"/tools/bin/sdkmanager; do
      [[ -x "$_c" ]] && { _SDKMANAGER="$_c"; break; }
    done
  fi
  FOUND_ANDROID=false
  if [[ -d "$_ANDROID_SDK/system-images" ]]; then
    # Structure is system-images/<api>/<tag>/<abi>/, descend all three levels
    for api_dir in "$_ANDROID_SDK/system-images"/*/; do
      [[ -d "$api_dir" ]] || continue
      api=$(basename "$api_dir")                  # e.g. android-34
      for tag_dir in "$api_dir"*/; do
        [[ -d "$tag_dir" ]] || continue
        tag=$(basename "$tag_dir")                # e.g. google_apis_playstore
        for abi_dir in "$tag_dir"*/; do
          [[ -d "$abi_dir" ]] || continue
          abi=$(basename "$abi_dir")              # e.g. arm64-v8a
          if $_COLLECT; then FOUND_ANDROID=true; _register android "android sysimg" "sdkmanager --install <pkg>" "removed via 'sdkmanager --uninstall'" "$abi_dir"; continue; fi
          FOUND_ANDROID=true
          size_kb=$(du -sk "$abi_dir" 2>/dev/null | cut -f1); size_mb=$(( size_kb / 1024 ))
          printf "  %5dM  %s / %s / %s\n" "$size_mb" "$api" "$tag" "$abi"
          if _ask "         Remove?"; then
            pkg="system-images;$api;$tag;$abi"    # valid 4-segment sdkmanager path
            if $DRY_RUN; then
              echo "  [dry-run] would run: sdkmanager --uninstall \"$pkg\""
            elif [[ -n "$_SDKMANAGER" ]]; then
              # Count freed space only on a real native uninstall; _rm fallback counts itself.
              if "$_SDKMANAGER" --uninstall "$pkg" 2>/dev/null; then (( _FREED_KB += size_kb )); else _rm "$abi_dir"; fi
            else
              _rm "$abi_dir"
            fi
          fi
        done
        $DRY_RUN || rmdir "$tag_dir" 2>/dev/null  # drop tag dir if now empty
      done
      $DRY_RUN || rmdir "$api_dir" 2>/dev/null    # drop API dir if now empty
    done
  fi
  $FOUND_ANDROID || echo "  None found."

  # ── VS Code-family stale extension versions (editor-flagged) ──
  # Generic across ALL VS Code forks: detect by extensions/.obsolete, which the editor
  # maintains as the list of superseded versions it will GC. We delete ONLY those, never
  # compute "newest" (avoids sort -V pre-release mis-rank + platform-suffix parsing traps,
  # and is safe even while the editor is running). No editor names hardcoded.
  echo ""
  echo "$(c_head "── VS Code-family stale extension versions (editor-flagged in .obsolete) ──")"
  EXT_FOUND=false
  for ext_dir in ~/.*/extensions(N/); do          # any ~/.<editor>/extensions/ (nullglob, dirs)
    [[ -f "$ext_dir/.obsolete" ]] || continue       # gate → only real VS Code forks
    stale=(${(f)"$(tr ',{}' '\n' < "$ext_dir/.obsolete" | sed -nE 's/^[[:space:]]*"([^"]+)":true.*/\1/p')"})
    (( ${#stale[@]} )) || continue
    ed="${${ext_dir:h}:t}"                          # e.g. .vscode
    # Count/size only folders still ON DISK, .obsolete keeps historical entries the
    # editor already GC'd, so ${#stale[@]} would over-report. Build the real worklist.
    on_disk=(); ext_kb=0
    for s in $stale; do
      [[ -d "$ext_dir/$s" ]] || continue
      on_disk+=("$s")
      ext_kb=$(( ext_kb + $(du -sk "$ext_dir/$s" 2>/dev/null | cut -f1) ))
    done
    (( ${#on_disk[@]} )) || continue
    if $_COLLECT; then
      EXT_FOUND=true; local -a _ep=(); for s in $on_disk; do _ep+=("$ext_dir/$s"); done
      _register rm "vscode-ext" "editor re-downloads on demand" "editor-flagged stale versions; active versions untouched" "${_ep[@]}"
      continue
    fi
    EXT_FOUND=true
    printf "  %-16s %d stale version folders on disk, %d MB\n" "$ed" "${#on_disk[@]}" "$(( ext_kb / 1024 ))"
    if _ask "         Delete ${ed}'s editor-flagged stale versions?"; then
      for s in $on_disk; do _rm "$ext_dir/$s"; done
      $DRY_RUN || echo "         Done (active versions untouched; editor self-heals .obsolete)."
    fi
  done
  $EXT_FOUND || echo "  None found."

  # ── node_modules ───────────────────────────────────
  echo ""
  echo "$(c_head "── node_modules directories ──")"
  NM_DIRS=(${(f)"$(
    find ~ -maxdepth 8 \( "${_SKIP_NM[@]}" \) -prune -o \
      -name "node_modules" -type d -prune -print 2>/dev/null | sort -u
  )"})
  NM_TOTAL_KB=0
  FOUND_NM=false
  if $_COLLECT; then
    (( ${#NM_DIRS[@]} )) && { FOUND_NM=true; _register rm "node_modules" "npm install (or yarn / pnpm install)" "-" "${NM_DIRS[@]}"; }
  else
  for d in $NM_DIRS; do
    FOUND_NM=true
    size_kb=$(du -sk "$d" 2>/dev/null | cut -f1)
    size_mb=$(( size_kb / 1024 ))
    modified=$(stat -f "%Sm" -t "%Y-%m-%d" "$d" 2>/dev/null)
    printf "  %5dM  %s  %s\n" "$size_mb" "$modified" "${d/#$HOME/~}"
    if _ask "         Delete?"; then
      _rm "$d"
      $DRY_RUN || echo "         Deleted. Recreate: npm install"
      NM_TOTAL_KB=$(( NM_TOTAL_KB + size_kb ))
    fi
  done
  fi
  $FOUND_NM || echo "  None found."
  (( NM_TOTAL_KB > 0 )) && ! $DRY_RUN && echo "  Freed from node_modules: $(( NM_TOTAL_KB / 1024 )) MB"

  # ── Python build/test caches (batch) ───────────────
  echo ""
  echo "$(c_head "── Python build/test caches (__pycache__, .pytest_cache, .mypy_cache, .ruff_cache) ──")"
  PY_CACHE_DIRS=(${(f)"$(
    find ~ -maxdepth 10 \
      \( "${_SKIP[@]}" \) -prune -o \
      \( -name "__pycache__" -o -name ".pytest_cache" \
         -o -name ".mypy_cache" -o -name ".ruff_cache" \) -type d -print \
      2>/dev/null | sort -u
  )"})
  if (( ${#PY_CACHE_DIRS[@]} == 0 )); then
    echo "$(c_dim "  None found.")"
  elif $_COLLECT; then
    _register rm "py-cache" "auto-regenerated on next run" "-" "${PY_CACHE_DIRS[@]}"
  else
    PC_KB=0
    for d in $PY_CACHE_DIRS; do
      kb=$(du -sk "$d" 2>/dev/null | cut -f1); PC_KB=$(( PC_KB + kb ))
    done
    echo "  Found ${#PY_CACHE_DIRS[@]} dirs, $(( PC_KB / 1024 )) MB total"
    echo "  All are auto-regenerated on next run."
    if _ask "  Delete all?"; then
      for d in $PY_CACHE_DIRS; do _rm "$d"; done
      $DRY_RUN || echo "  Deleted ${#PY_CACHE_DIRS[@]} dirs."
    fi
  fi

  # ── Stray .pyc / .pyo files (batch) ────────────────
  echo ""
  echo "$(c_head "── Stray .pyc / .pyo files (outside __pycache__) ──")"
  PYC_FILES=(${(f)"$(
    find ~ -maxdepth 10 \
      \( "${_SKIP[@]}" -o -name "__pycache__" \) -prune -o \
      \( -name "*.pyc" -o -name "*.pyo" \) -print \
      2>/dev/null | sort -u
  )"})
  if $_COLLECT; then
    echo "$(c_dim "  Skipped in --pick (not a picker category); run plain 'dehoard --scan' to clean these.")"
  elif (( ${#PYC_FILES[@]} == 0 )); then
    echo "$(c_dim "  None found.")"
  else
    PYC_KB=0
    for f in $PYC_FILES; do kb=$(du -sk "$f" 2>/dev/null | cut -f1); PYC_KB=$(( PYC_KB + kb )); done
    echo "  Found ${#PYC_FILES[@]} files, $(( PYC_KB / 1024 )) MB total"
    echo "  Auto-regenerated by Python on next import."
    if _ask "  Delete all?"; then
      for f in $PYC_FILES; do _rm "$f"; done
      $DRY_RUN || echo "  Deleted ${#PYC_FILES[@]} files."
    fi
  fi

  # ── Python packaging artifacts (batch) ─────────────
  echo ""
  echo "$(c_head "── Python packaging artifacts (*.egg-info) ──")"
  EGG_DIRS=(${(f)"$(
    find ~ -maxdepth 10 \
      \( "${_SKIP[@]}" \) -prune -o \
      -name "*.egg-info" -type d -print \
      2>/dev/null | sort -u
  )"})
  if (( ${#EGG_DIRS[@]} == 0 )); then
    echo "$(c_dim "  None found.")"
  elif $_COLLECT; then
    _register rm "egg-info" "pip install -e ." "-" "${EGG_DIRS[@]}"
  else
    EGG_KB=0
    for d in $EGG_DIRS; do
      kb=$(du -sk "$d" 2>/dev/null | cut -f1); EGG_KB=$(( EGG_KB + kb ))
      echo "  $(du -sh "$d" 2>/dev/null | cut -f1)  ${d/#$HOME/~}"
    done
    echo "  Regenerated by: pip install -e ."
    if _ask "  Delete all?"; then
      for d in $EGG_DIRS; do _rm "$d"; done
      $DRY_RUN || echo "  Deleted ${#EGG_DIRS[@]} dirs."
    fi
  fi

  # ── Python/JS build outputs (batch) ────────────────
  echo ""
  echo "$(c_head "── Python/JS build outputs (dist/, build/) ──")"
  BUILD_DIRS=(${(f)"$(
    find ~ -maxdepth 8 \
      \( "${_SKIP[@]}" \) -prune -o \
      \( -name "dist" -o -name "build" \
         -o -name "cmake-build-debug" -o -name "cmake-build-release" \
         -o -name "cmake-build-relwithdebinfo" -o -name "cmake-build-minsizerel" \) -type d -print \
      2>/dev/null | sort -u
  )"})
  if (( ${#BUILD_DIRS[@]} == 0 )); then
    echo "$(c_dim "  None found.")"
  elif $_COLLECT; then
    _register rm "build/dist" "python -m build / npm run build / cmake" "some projects commit dist/ for releases; review before deleting" "${BUILD_DIRS[@]}"
  else
    BUILD_KB=0
    for d in $BUILD_DIRS; do
      kb=$(du -sk "$d" 2>/dev/null | cut -f1); BUILD_KB=$(( BUILD_KB + kb ))
      printf "  %-8s %s\n" "$(du -sh "$d" 2>/dev/null | cut -f1)" "${d/#$HOME/~}"
    done
    echo "  $(( BUILD_KB / 1024 )) MB total"
    echo "  WARNING: review list, some projects commit dist/ for releases."
    echo "  Regenerated by: python -m build / npm run build / cmake / etc."
    if _ask "  Delete all?"; then
      for d in $BUILD_DIRS; do _rm "$d"; done
      $DRY_RUN || echo "  Deleted ${#BUILD_DIRS[@]} dirs."
    fi
  fi

  # ── Rust build artifacts (per entry) ───────────────
  echo ""
  echo "$(c_head "── Rust build artifacts (target/, validated by Cargo.toml) ──")"
  RUST_FOUND=false
  # Collect into an array first (a `find | while` pipe runs in a subshell in zsh, so the --pick
  # registry appends inside it would be lost).
  RUST_CARGOS=(${(f)"$(
    find ~ -maxdepth 6 \( "${_SKIP_ENV[@]}" \) -prune -o -name "Cargo.toml" -type f -print 2>/dev/null | sort -u
  )"})
  if $_COLLECT; then
    for ct in $RUST_CARGOS; do
      [[ -d "${ct:h}/target" ]] || continue
      RUST_FOUND=true
      _register cargo "rust target" "cargo build" "removed via 'cargo clean'" "${ct:h}/target"
    done
  else
  for ct in $RUST_CARGOS; do
    d=$(dirname "$ct")
    [[ -d "$d/target" ]] || continue
    RUST_FOUND=true
    size_kb=$(du -sk "$d/target" 2>/dev/null | cut -f1)
    size_mb=$(( size_kb / 1024 ))
    modified=$(stat -f "%Sm" -t "%Y-%m-%d" "$d/target" 2>/dev/null)
    printf "  %5dM  %s  %s\n" "$size_mb" "$modified" "${d/#$HOME/~}/target"
    if _ask "         Delete?"; then
      if $DRY_RUN; then
        echo "  [dry-run] would run: cargo clean in ${d/#$HOME/~}"
      elif command -v cargo &>/dev/null; then
        # Count freed space only on a real native clean; _rm fallback counts itself.
        if cargo clean --manifest-path "$ct" 2>/dev/null; then (( _FREED_KB += size_kb )); else _rm "$d/target"; fi
      else
        _rm "$d/target"
      fi
    fi
  done
  fi
  $RUST_FOUND || echo "  None found."

  # ── Python test/coverage artifacts (batch) ─────────
  echo ""
  echo "$(c_head "── Python test/coverage artifacts (.coverage, htmlcov, .tox, .nox, .hypothesis) ──")"
  COV_ITEMS=(${(f)"$(
    find ~ -maxdepth 10 \
      \( "${_SKIP[@]}" \) -prune -o \
      \( -name ".coverage" -o -name ".coverage.*" -o -name "coverage.xml" \
         -o -name "htmlcov"    -o -name ".tox"    -o -name ".nox" \
         -o -name ".hypothesis" \) -print \
      2>/dev/null | sort -u
  )"})
  if (( ${#COV_ITEMS[@]} == 0 )); then
    echo "$(c_dim "  None found.")"
  elif $_COLLECT; then
    _register rm "coverage" "regenerated on next test run" "-" "${COV_ITEMS[@]}"
  else
    COV_KB=0
    for item in $COV_ITEMS; do kb=$(du -sk "$item" 2>/dev/null | cut -f1); COV_KB=$(( COV_KB + kb )); done
    echo "  Found ${#COV_ITEMS[@]} items, $(( COV_KB / 1024 )) MB total"
    echo "  All regenerated on next test run."
    if _ask "  Delete all?"; then
      for item in $COV_ITEMS; do _rm "$item"; done
      $DRY_RUN || echo "  Deleted ${#COV_ITEMS[@]} items."
    fi
  fi

  # ── JVM heap dumps (per entry) ─────────────────────
  echo ""
  echo "$(c_head "── JVM heap dumps (*.hprof) ── PER ENTRY")"
  HPROF_FILES=(${(f)"$(
    find ~ -maxdepth 8 \( "${_SKIP[@]}" \) -prune -o -name "*.hprof" -print 2>/dev/null | sort -u
  )"})
  if (( ${#HPROF_FILES[@]} == 0 )); then
    echo "$(c_dim "  None found.")"
  elif $_COLLECT; then
    _register rm "jvm-hprof" "regenerated on next heap dump" "-" "${HPROF_FILES[@]}"
  else
    for f in $HPROF_FILES; do
      [[ -f "$f" ]] || continue
      printf "  %-8s %s\n" "$(du -sh "$f" 2>/dev/null | cut -f1)" "${f/#$HOME/~}"
      if _ask "         Delete?"; then _rm "$f"; fi
    done
  fi

  # ── ROS2 colcon workspace artifacts (batch) ─────────
  echo ""
  echo "$(c_head "── ROS2 colcon workspace artifacts (build/, install/, log/) ──")"
  # Collect src dirs into an array first (a `find | while` pipe is a subshell in zsh → registry
  # appends inside it would be lost).
  ROS2_SRCS=(${(f)"$(
    find ~ -maxdepth 5 \( "${_SKIP[@]}" \) -prune -o -name "src" -type d -print 2>/dev/null | sort -u
  )"})
  if $_COLLECT; then
    local _ws _rsub   # NOT _sub: re-declaring an already-set local elsewhere makes zsh echo it
    for src_dir in $ROS2_SRCS; do
      _ws="${src_dir:h}"
      for _rsub in build install log; do
        [[ -d "$_ws/$_rsub" ]] && _register rm "ros2" "cd <ws> && colcon build" "-" "$_ws/$_rsub"
      done
    done
  else
  for src_dir in $ROS2_SRCS; do
    ws=$(dirname "$src_dir")
    any_found=false
    for subdir in build install log; do
      [[ -d "$ws/$subdir" ]] || continue
      any_found=true
      printf "  %-8s %s\n" "$(du -sh "$ws/$subdir" 2>/dev/null | cut -f1)" "${ws/#$HOME/~}/$subdir"
    done
    if $any_found; then
      if _ask "  Delete build/install/log in $(basename $ws)?"; then
        for subdir in build install log; do
          [[ -d "$ws/$subdir" ]] && _rm "$ws/$subdir"
        done
        $DRY_RUN || echo "  Deleted. Rebuild: cd $ws && colcon build"
      fi
    fi
  done
  fi

  # ── IPython command history (per entry, WARNING) ────
  echo ""
  echo "$(c_head "── IPython command history ──")"
  if $_COLLECT; then
    echo "$(c_dim "  Skipped in --pick (not a picker category); run plain 'dehoard --scan' to clean this.")"
  elif [[ -f ~/.ipython/profile_default/history.sqlite ]]; then
    IPYTHON_SIZE=$(du -sh ~/.ipython/profile_default/history.sqlite 2>/dev/null | cut -f1)
    echo "  ~/.ipython/profile_default/history.sqlite (${IPYTHON_SIZE})"
    echo "$(c_warn "  ⚠️  WARNING: this is your IPython command history, all past commands.")"
    echo "$(c_warn "     Deleting loses all history permanently. IPython works fine without it.")"
    if _ask "  Delete IPython history?"; then
      _rm ~/.ipython/profile_default/history.sqlite
      $DRY_RUN || echo "  Deleted. New history.sqlite created on next IPython session."
    fi
  else
    echo "$(c_dim "  None found.")"
  fi

  # ── R session artifacts (batch, with file listing) ──
  echo ""
  echo "$(c_head "── R session artifacts (.RData, .Rhistory, Rplots.pdf) ──")"
  R_FILES=(${(f)"$(
    find ~ -maxdepth 10 \
      \( "${_SKIP[@]}" \) -prune -o \
      \( -name ".RData" -o -name ".Rhistory" -o -name ".Rapp.history" \
         -o -name "Rplots.pdf" \) -print \
      2>/dev/null | sort -u
  )"})
  if (( ${#R_FILES[@]} == 0 )); then
    echo "$(c_dim "  None found.")"
  elif $_COLLECT; then
    _register rm "r-artifacts" "regenerated on next R session" ".RData holds your saved R workspace variables; review before deleting" "${R_FILES[@]}"
  else
    R_KB=0
    for f in $R_FILES; do
      kb=$(du -sk "$f" 2>/dev/null | cut -f1); R_KB=$(( R_KB + kb ))
      printf "  %-8s %s\n" "$(du -sh "$f" 2>/dev/null | cut -f1)" "${f/#$HOME/~}"
    done
    echo "  NOTE: .RData contains saved R workspace variables, review list above."
    if _ask "  Delete all?"; then
      for f in $R_FILES; do _rm "$f"; done
      $DRY_RUN || echo "  Deleted ${#R_FILES[@]} files."
    fi
  fi

  # ── LaTeX compilation artifacts (batch) ────────────
  echo ""
  echo "$(c_head "── LaTeX compilation artifacts (.aux, .synctex.gz, .bbl, etc.) ──")"
  TEX_FILES=(${(f)"$(
    find ~ -maxdepth 10 \
      \( "${_SKIP[@]}" \) -prune -o \
      \( -name "*.aux"  -o -name "*.fls"  -o -name "*.fdb_latexmk" \
         -o -name "*.synctex.gz" -o -name "*.bbl" -o -name "*.blg" \
         -o -name "*.toc" -o -name "*.lot" -o -name "*.lof" \
         -o -name "*.nav" -o -name "*.snm" \) -print \
      2>/dev/null | sort -u
  )"})
  if $_COLLECT; then
    echo "$(c_dim "  Skipped in --pick (not a picker category); run plain 'dehoard --scan' to clean these.")"
  elif (( ${#TEX_FILES[@]} == 0 )); then
    echo "$(c_dim "  None found.")"
  else
    TEX_KB=0
    for f in $TEX_FILES; do kb=$(du -sk "$f" 2>/dev/null | cut -f1); TEX_KB=$(( TEX_KB + kb )); done
    echo "  Found ${#TEX_FILES[@]} files, $(( TEX_KB / 1024 )) MB total"
    echo "  Regenerated on next LaTeX compile. Your .tex source is untouched."
    if _ask "  Delete all?"; then
      for f in $TEX_FILES; do _rm "$f"; done
      $DRY_RUN || echo "  Deleted ${#TEX_FILES[@]} files."
    fi
  fi

  # ── macOS system junk files (batch) ────────────────
  echo ""
  echo "$(c_head "── macOS system junk (.DS_Store, ._*, Thumbs.db, desktop.ini) ──")"
  MACOS_JUNK=(${(f)"$(
    find ~ -maxdepth 10 \
      \( "${_SKIP[@]}" \) -prune -o \
      \( -name ".DS_Store" -o -name "Thumbs.db" -o -name "desktop.ini" \
         -o -name ".AppleDouble" -o -name "._*" \) -print \
      2>/dev/null | sort -u
  )"})
  if $_COLLECT; then
    echo "$(c_dim "  Skipped in --pick (not a picker category); run plain 'dehoard --scan' to clean these.")"
  elif (( ${#MACOS_JUNK[@]} == 0 )); then
    echo "$(c_dim "  None found.")"
  else
    echo "  Found ${#MACOS_JUNK[@]} files, always safe to delete."
    if _ask "  Delete all?"; then
      for f in $MACOS_JUNK; do _rm "$f"; done
      $DRY_RUN || echo "  Deleted ${#MACOS_JUNK[@]} files."
    fi
  fi

  # ── Editor swap and backup files (batch) ───────────
  echo ""
  echo "$(c_head "── Editor swap and backup files (*.swp, *~, *.orig, *.bak) ──")"
  SWAP_FILES=(${(f)"$(
    find ~ -maxdepth 10 \
      \( "${_SKIP[@]}" \) -prune -o \
      \( -name "*.swp" -o -name "*.swo" -o -name "*~" \
         -o -name "*.orig" -o -name "*.bak" \) -print \
      2>/dev/null | sort -u
  )"})
  if (( ${#SWAP_FILES[@]} == 0 )); then
    echo "$(c_dim "  None found.")"
  elif $_COLLECT; then
    _register rm "swap/backup" "regenerated by editor/compile" "*.swp can mean Vim had unsaved changes; review if Vim is open" "${SWAP_FILES[@]}"
  else
    for f in $SWAP_FILES; do
      printf "  %-8s %s\n" "$(du -sh "$f" 2>/dev/null | cut -f1)" "${f/#$HOME/~}"
    done
    echo "  NOTE: *.swp files mean Vim had unsaved changes, review if Vim is open."
    if _ask "  Delete all?"; then
      for f in $SWAP_FILES; do _rm "$f"; done
      $DRY_RUN || echo "  Deleted ${#SWAP_FILES[@]} files."
    fi
  fi

  # ── Project log files >100 KB (per entry) ──────────
  echo ""
  echo "$(c_head "── Project log files (>100 KB, inside project dirs) ──")"
  LOG_FILES=(${(f)"$(
    find ~ -maxdepth 10 \
      \( "${_SKIP[@]}" \) -prune -o \
      \( -name "*.log" -o -name "npm-debug.log*" \
         -o -name "yarn-debug.log*" -o -name "yarn-error.log*" \) \
      -size +100k -print \
      2>/dev/null | sort -u
  )"})
  FOUND_LOG=false
  LOG_TOTAL_KB=0
  if $_COLLECT; then
    (( ${#LOG_FILES[@]} )) && { FOUND_LOG=true; _register rm "logs" "regenerated at runtime" "-" "${LOG_FILES[@]}"; }
  else
  for f in $LOG_FILES; do
    FOUND_LOG=true
    size_kb=$(du -sk "$f" 2>/dev/null | cut -f1)
    printf "  %-8s %s\n" "$(du -sh "$f" 2>/dev/null | cut -f1)" "${f/#$HOME/~}"
    if _ask "         Delete?"; then
      _rm "$f"
      LOG_TOTAL_KB=$(( LOG_TOTAL_KB + size_kb ))
    fi
  done
  fi
  $FOUND_LOG || echo "  None found."
  (( LOG_TOTAL_KB > 0 )) && ! $DRY_RUN && echo "  Freed from logs: $(( LOG_TOTAL_KB / 1024 )) MB"

  # ── AI / local-model tooling (regenerable caches only; models & outputs KEPT) ──
  # For each tool: clean only temp/cache; print models/outputs/session dirs as
  # "user data, kept" and never delete them. Weights live in --models; venvs in
  # the venv section above. Nothing here is hardcoded to one machine.
  echo ""
  echo "$(c_head "── AI / local-model tool caches (models, outputs & sessions are KEPT) ──")"
  AITOOL_FOUND=false
  _ai_clean() {  # $1=label; CLEAN paths… ; '--' ; KEEP (report-only) paths…
    local label="$1"; shift
    local clean=() keep=() sep=false a
    for a in "$@"; do
      [[ "$a" == "--" ]] && { sep=true; continue; }
      $sep && keep+=("$a") || clean+=("$a")
    done
    local existing=() kept=() p
    for p in $clean; do [[ -e "$p" ]] && existing+=("$p"); done
    for p in $keep;  do [[ -e "$p" ]] && kept+=("$p"); done
    (( ${#existing[@]} + ${#kept[@]} )) || return
    if $_COLLECT; then
      (( ${#existing[@]} )) && { AITOOL_FOUND=true; _register rm "ai-cache" "regenerated on next launch" "${label}: models/outputs/sessions are kept" "${existing[@]}"; }
      return
    fi
    AITOOL_FOUND=true
    echo "$(c_bold "  ▸ $label")"
    for p in $kept; do
      echo "$(c_safe "$(printf '      keep   %-7s %s  (user data)' "$(du -sh "$p" 2>/dev/null | cut -f1)" "${p/#$HOME/~}")")"
    done
    (( ${#existing[@]} )) || return
    for p in $existing; do
      printf "      cache  %-7s %s\n" "$(du -sh "$p" 2>/dev/null | cut -f1)" "${p/#$HOME/~}"
    done
    if _ask "        Delete ${label} regenerable caches?" "${existing[1]}"; then
      for p in $existing; do _rm "$p"; done
    fi
  }
  _ai_clean "ComfyUI"        ~/ComfyUI/temp ~/comfyui/temp -- ~/ComfyUI/models ~/ComfyUI/output ~/comfyui/models ~/comfyui/output
  _ai_clean "Automatic1111"  ~/stable-diffusion-webui/tmp -- ~/stable-diffusion-webui/models ~/stable-diffusion-webui/outputs
  _ai_clean "Claude Code"    ~/.cache/claude-cli-nodejs -- ~/.claude
  _ai_clean "Codex"          ~/.cache/codex-runtimes -- ~/.codex
  _ai_clean "n8n"            ~/.cache/n8n ~/.n8n/cache -- ~/.n8n/database.sqlite
  _ai_clean "openclaw"       ~/.cache/openclaw -- ~/.openclaw
  # MATLAB: clean only the stale residue (logs, crash dumps, download caches). The ServiceHost
  # connector RUNTIME is left alone on purpose: deleting it just forces a re-download (and maybe a
  # re-login) on the next launch, so it is not durably reclaimable for anyone who still uses MATLAB.
  # The MATLAB support dir (prefs, command history, local cluster jobs), Add-Ons, license, and your
  # code are kept and reported, never cleaned.
  _ai_clean "MATLAB"  ~/Library/Caches/MathWorks  ~/Library/Logs/MathWorks \
    ~/"Library/Application Support/MathWorks/ServiceHost/logs"  ~/matlab_crash_dump.* \
    --  ~/"Library/Application Support/MathWorks/MATLAB" \
        ~/"Library/Application Support/MathWorks/MATLAB Add-Ons" \
        ~/"Library/Application Support/MathWorks/licensing"  ~/.matlab  ~/Documents/MATLAB
  # ── AI editors & Electron desktop apps: GENERIC cache sweep (NO app list) ──
  # Every Chromium/Electron app (VS Code, Cursor, Windsurf, Antigravity, Slack,
  # Obsidian, …) writes regenerable caches into canonically-named subfolders.
  # Whitelist ONLY those names, never the app's Local Storage / IndexedDB /
  # databases (user data). Self-covers tools no rule lists, and ones not built yet.
  # Chromium recreates all of these on next launch (quit the app first).
  local _chrome_caches=(Cache "Code Cache" GPUCache DawnCache DawnGraphiteCache \
    DawnWebGPUCache ShaderCache GrShaderCache CachedData CachedProfilesData \
    CachedExtensionVSIXs "Service Worker/CacheStorage" "Service Worker/ScriptCache")
  local _appsup=~/"Library/Application Support"
  if [[ -d "$_appsup" ]]; then
    local _app _sub _name _t; local -a _targets
    for _app in "$_appsup"/*(N/); do
      _targets=(); local _akb=0
      for _sub in $_chrome_caches; do
        [[ -d "$_app/$_sub" ]] || continue
        _targets+=("$_app/$_sub"); _akb=$(( _akb + $(du -sk "$_app/$_sub" 2>/dev/null | cut -f1) ))
      done
      (( ${#_targets[@]} && _akb >= 5120 )) || continue        # skip apps with <5 MB cache
      AITOOL_FOUND=true
      _name="${${_app%/}:t}"
      if $_COLLECT; then
        _register rm "app-cache" "regenerates on app launch" "${_name} Electron cache (quit the app first)" "${_targets[@]}"
        continue
      fi
      printf "  ▸ %-26s %6dM  (Electron app cache, regenerates on launch)\n" "$_name" "$(( _akb / 1024 ))"
      _ask "        Delete ${_name} app cache?" "${_app}" && { for _t in $_targets; do _rm "$_t"; done; }
    done
  fi
  # Saved window state, app-agnostic, regenerated on next launch
  local _ss _sskb
  for _ss in ~/"Library/Saved Application State"/*.savedState(N/); do
    _sskb=$(du -sk "$_ss" 2>/dev/null | cut -f1); (( _sskb >= 5120 )) || continue
    AITOOL_FOUND=true
    if $_COLLECT; then
      _register rm "saved-state" "regenerated on next launch" "macOS saved window state" "$_ss"
      continue
    fi
    printf "  ▸ %-26s %6dM  (saved window state)\n" "${${_ss%/}:t}" "$(( _sskb / 1024 ))"
    _ask "        Delete saved state for ${${_ss%/}:t}?" "$_ss" && _rm "$_ss"
  done
  _ai_clean "Ollama logs"    ~/.ollama/logs -- ~/.ollama/models
  $AITOOL_FOUND || echo "  No AI/local-model tooling found."

  # ── Orphaned dev/ML tool data (tool gone, data dir left behind) ──
  # NARROW + conservative: only tools whose absence is reliably detectable (binary
  # NOT on PATH *and* no matching .app). General app-uninstall leftovers are out of
  # scope (a dedicated app uninstaller's job); dehoard intentionally does NOT scan all of ~/Library.
  echo ""
  echo "$(c_head "── Orphaned dev/ML tool data (binary/app missing, data remains) ──")"
  echo "  General app leftovers are out of scope (use a dedicated app uninstaller); this is dev/ML tools only."
  ORPHAN_FOUND=false
  _orphan() {  # $1=binary $2=app(.app name or '') ; rest = data dirs
    local bin="$1" app="$2"; shift 2
    command -v "$bin" &>/dev/null && return                      # tool installed → skip
    [[ -n "$app" && -d "/Applications/$app" ]] && return         # GUI installed → skip
    local p kb
    for p in "$@"; do
      [[ -d "$p" ]] || continue
      kb=$(du -sk "$p" 2>/dev/null | cut -f1); (( kb >= 1024 )) || continue   # skip <1MB
      ORPHAN_FOUND=true
      if $_COLLECT; then _register rm "orphaned" "data for an uninstalled tool" "'$bin' not on PATH and no matching .app; leftover data" "$p"; continue; fi
      printf "  %-7s %s  (last used %s)\n" "$(du -sh "$p" 2>/dev/null | cut -f1)" \
        "${p/#$HOME/~}" "$(stat -f '%Sm' -t '%Y-%m-%d' "$p" 2>/dev/null)"
      _ask "         '$bin' not installed, delete leftover data?" "$p" && _rm "$p"
    done
  }
  _orphan ollama "Ollama.app"             ~/.ollama
  _orphan lms    "LM Studio.app"          ~/.lmstudio
  _orphan code   "Visual Studio Code.app" ~/.vscode
  _orphan cursor      "Cursor.app"        ~/.cursor
  _orphan zed         "Zed.app"           ~/.config/zed
  _orphan antigravity "Antigravity.app"   ~/.antigravity
  $ORPHAN_FOUND || echo "  None, all known tools' data belongs to installed tools."

  # ── Generic tool-cache scan (catch-all) ────────────
  # The single most important section: instead of enumerating every language's
  # cache dir, size-rank everything in ~/.cache and ~/Library/Caches over a
  # threshold and prompt per entry. This self-covers every tool, including ones
  # no rule lists, and ones that don't exist yet. Anything already cleared by
  # Tier 1 / --deep / --models earlier in this run simply won't appear.
  echo ""
  echo "$(c_head "── Tool caches >${CACHE_MIN_MB} MB (~/.cache, ~/Library/Caches) ── PER ENTRY")"
  echo "  Catch-all for any cache dir over the threshold, whatever tool created it."
  echo "  All regenerate; model/build caches re-download slowly, decide per entry."
  CACHE_ENTRIES=(${(f)"$(
    for cache_root in ~/.cache ~/Library/Caches; do
      [[ -d "$cache_root" ]] || continue
      for d in "$cache_root"/*/; do
        [[ -d "$d" ]] || continue
        kb=$(du -sk "$d" 2>/dev/null | cut -f1)
        (( kb >= CACHE_MIN_MB * 1024 )) && printf '%s\t%s\n' "$kb" "$d"
      done
    done | sort -rn
  )"})
  if (( ${#CACHE_ENTRIES[@]} == 0 )); then
    echo "$(c_dim "  None over ${CACHE_MIN_MB} MB.")"
  elif $_COLLECT; then
    local _ce
    for _ce in $CACHE_ENTRIES; do _register rm "cache" "regenerates (model/build caches re-download slowly)" "-" "${_ce#*$'\t'}"; done
  else
    CACHE_TOTAL_KB=0
    for entry in $CACHE_ENTRIES; do
      kb="${entry%%$'\t'*}"          # field before the tab
      d="${entry#*$'\t'}"            # field after the tab
      mb=$(( kb / 1024 ))
      printf "  %6dM  %s\n" "$mb" "${d/#$HOME/~}"
      if _ask "         Delete?" "$d"; then
        _rm "$d"
        CACHE_TOTAL_KB=$(( CACHE_TOTAL_KB + kb ))
      fi
    done
    (( CACHE_TOTAL_KB > 0 )) && ! $DRY_RUN && echo "  Freed from caches: $(( CACHE_TOTAL_KB / 1024 )) MB"
  fi

  # --pick: every in-scope section above registered (not deleted) its candidates; now run the
  # picker (one fzf per category) that does the actual, type-aware deletion.
  $_COLLECT && _run_picker
fi

}

print_result() {
# ══════════════════════════════════════════════════════
# Result
# ══════════════════════════════════════════════════════

# "Storage freed" reflects what dehoard ACTUALLY deleted (the $_FREED_KB tally, summed in _rm and the
# native-uninstaller branches), NOT a whole-disk df delta, which would credit dehoard for ambient disk
# churn during the run (the user once saw "freed 860 KB" after deleting nothing). The df figure is kept
# only as ambient "Free space now" context, clearly separated from the reclaim number.
FREED_MB=$(( _FREED_KB / 1024 ))
FREED_GB=$(echo "scale=2; $FREED_MB / 1024" | bc)

echo ""
if $DRY_RUN; then
  echo "$(c_head "👁  Preview complete, NOTHING was deleted.")"
  echo "$(c_dim "━━━━━━━━━━━━━━━━━━━━━━━━")"
  echo "$(c_safe "💾 Current free space: $(df -h / | awk 'NR==2 {print $4}')")"
  echo "$(c_bold "👉 Re-run with --apply to reclaim the space shown above.")"
  echo "$(c_dim "━━━━━━━━━━━━━━━━━━━━━━━━")"
else
  echo "$(c_safe "✅ Reclaim complete!")"
  echo "$(c_dim "━━━━━━━━━━━━━━━━━━━━━━━━")"
  if (( FREED_MB >= 1024 )); then
    echo "$(c_safe "🗑️  Storage freed: ${FREED_GB} GB")"
  elif (( FREED_MB > 0 )); then
    echo "$(c_safe "🗑️  Storage freed: ${FREED_MB} MB")"
  elif (( _FREED_KB > 0 )); then
    echo "$(c_safe "🗑️  Storage freed: ${_FREED_KB} KB")"
  else
    echo "$(c_dim "🗑️  Nothing deleted.")"
  fi
  echo "$(c_dim "💾 Free space now: $(df -h / | awk 'NR==2 {print $4}') (whole disk; varies with other activity)")"
  echo "$(c_dim "━━━━━━━━━━━━━━━━━━━━━━━━")"
  command -v osascript &>/dev/null && \
    osascript -e "display notification \"Freed ${FREED_MB} MB, $(df -h / | awk 'NR==2 {print $4}') free\" with title \"dehoard ✅\"" 2>/dev/null
fi
}

# ── Dispatch: run-mode selection (each cleanup function self-guards on its flag) ──
main() {
  (( ${@[(I)--uninstall]} || ${@[(I)--purge]} )) && _uninstall "$@"   # --purge implies uninstall; handled first
  run_report      # read-only; exits the script if --report/--json
  # --pick is an INTERACTIVE-ONLY mode: it must not trigger the automatic batch sweeps (Tier 1
  # caches, --deep, --models) or their sudo prompts. The only thing it deletes is what you mark in
  # the one scan picker. Without --pick, behavior is unchanged (bare run = Tier 1; flags add).
  if ! $PICK; then
    clean_tier1     # always-safe caches
    clean_deep      # Tier 2 (self-guards on $DEEP)
    clean_models    # self-guards on $MODELS
  fi
  run_scan        # self-guards on $SCAN; under --pick this is the sole deleter (one fzf picker per category)
  print_result
}
main "$@"
