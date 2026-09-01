#!/usr/bin/env zsh
# dehoard test harness, proves the deleter is safe.
#
# Runs dehoard against a THROWAWAY $HOME fixture and asserts:
#   - preview (no --apply) deletes nothing
#   - --apply removes a regenerable Tier-1 cache (~/.npm/_npx)
#   - user data (model weights, session files, $HOME itself) ALWAYS survives
#   - an unset TMPDIR (mis-computed $BASE) never causes a delete outside safe roots
#
# Hermetic: runs with a restricted PATH so external package managers (brew/npm/go/uv)
# are NOT found (command -v guards skip them), the test exercises only dehoard's own
# file-deletion logic and never touches the real machine's caches.
#
# Usage:  zsh test/run.zsh
set -u
SCRIPT="${0:A:h}/../dehoard.sh"
[[ -f "$SCRIPT" ]] || { echo "cannot find dehoard.sh next to test/"; exit 2; }
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"   # excludes brew/npm/go/uv/cargo → guards skip them
# Neutralise osascript for EVERY test, not just the stub-harness ones. It lives in /usr/bin,
# which SAFE_PATH includes, so without this each run reaching print_result posts a real macOS
# notification and one suite floods the developer's Notification Center with fixture figures.
# Captured BEFORE anything reassigns HOME/TMPDIR: the canary checks and _assert_sandbox both
# compare against the developer's real environment, so these must be the untouched originals.
_REAL_HOME="$HOME"
_REAL_TMPDIR_ORIG="${TMPDIR:-/tmp}"
_NOTIFY_STUB=$(mktemp -d)
{ echo '#!/bin/sh'; echo 'exit 0'; } > "$_NOTIFY_STUB/osascript"
chmod +x "$_NOTIFY_STUB/osascript"
SAFE_PATH="$_NOTIFY_STUB:$SAFE_PATH"

# Fixture TMPDIR for the WHOLE suite. Setting only $HOME is not enough to make a run hermetic:
# Tier 1 deletes `${TMPDIR}node-compile-cache`, `${TMPDIR}hsperfdata_*`, `${BASE}/C/*.helper`, etc,
# and $TMPDIR/$BASE are derived from the INHERITED environment, not from $HOME. Those paths are
# inside the safe-root whitelist, so they were really deleted — every `--apply` test was eating the
# developer's (and CI's) actual temp caches. That also produced a self-healing flake: a run deleted
# a real `node-compile-cache`, `_FREED_KB` became non-zero, the "no notification when nothing was
# freed" assertion failed, and the next four runs passed because the file was already gone.
# Tests that deliberately exercise a hostile or unset TMPDIR override this per-invocation.
_FIXTURE_TMPDIR=$(mktemp -d)
export TMPDIR="${_FIXTURE_TMPDIR%/}/"
trap 'rm -rf "$_NOTIFY_STUB" "$_FIXTURE_TMPDIR"' EXIT INT TERM

# Canaries in the REAL environment. _assert_sandbox is wired into run(), but only 2 of ~100
# invocations use run() — wrapping the other 98 would be fragile and a newly-written test would
# silently escape anyway. So instead of guarding each call site, assert the PROPERTY at the end:
# nothing the suite ran deleted a real file. These live at paths dehoard's Tier 1 genuinely
# targets, so a hermeticity regression destroys them and the final check fails loudly, whichever
# invocation caused it — including ones that do not exist yet.
# The canary must sit at a path Tier 1 ACTUALLY targets, not merely inside the real TMPDIR:
# dehoard removes `${TMPDIR}hsperfdata_*` by glob, so a uniquely-suffixed name matches that glob
# while never colliding with a real JVM perf dir. A canary nested one level deeper would survive a
# genuine hermeticity break and prove nothing (the first version of this check made that mistake).
_REAL_TMPDIR="${_REAL_TMPDIR_ORIG%/}/"
_CANARY_TMP="${_REAL_TMPDIR}hsperfdata_dehoardsuitecanary"
mkdir -p "$_CANARY_TMP" 2>/dev/null && : > "$_CANARY_TMP/probe"
_CANARY_REAL_HOME_MARK="$_REAL_HOME/.dehoard-suite-canary"
: > "$_CANARY_REAL_HOME_MARK" 2>/dev/null

PASS=0 FAIL=0
ok()  { print -P "  %F{green}✓%f $1"; (( ++PASS )); return 0; }
bad() { print -P "  %F{red}✗ $1%f";   (( ++FAIL )); return 0; }

# Paranoia guard. This suite runs a tool that deletes files, so "the fixture leaked" must be a loud
# failure, not a silent one. A real bug shipped because tests set $HOME but not $TMPDIR and Tier 1
# then deleted the developer's actual temp caches; nothing failed, because the deletions were
# legitimate for the paths it was handed. Assert the sandbox itself before running anything.
_assert_sandbox() {   # $1 = label of the about-to-run invocation
  [[ "${HOME}" == /var/folders/* || "${HOME}" == /tmp/* || "${HOME}" == /private/* ]] \
    || { print -P "%F{red}FATAL: \$HOME is not a fixture dir ($HOME) — refusing to run $1%f"; exit 2; }
  [[ "${TMPDIR}" == /var/folders/* || "${TMPDIR}" == /tmp/* || "${TMPDIR}" == /private/* ]] \
    || { print -P "%F{red}FATAL: \$TMPDIR is not a fixture dir ($TMPDIR) — refusing to run $1%f"; exit 2; }
  [[ "${HOME}" != "${_REAL_HOME}" ]] \
    || { print -P "%F{red}FATAL: \$HOME is the REAL home — refusing to run $1%f"; exit 2; }
}

new_fixture() {
  FIX=$(mktemp -d)
  mkdir -p "$FIX"/.cache/huggingface/hub \
           "$FIX"/.npm/_npx \
           "$FIX"/.ollama/models \
           "$FIX"/proj/.venv/bin
  : > "$FIX/.npm/_npx/x"                       # regenerable cache (Tier 1 _rm target)
  echo cfg     > "$FIX/proj/.venv/pyvenv.cfg"  # venv (only --scan, per-entry; kept w/o --yes)
  echo weights > "$FIX/.ollama/models/llama"   # USER DATA, must survive
  echo trans   > "$FIX/.claude_session"        # decoy user data, must survive
}
run() {
  # Guard every invocation, not just the first: this is the seam the hermeticity bug slipped through.
  HOME="$FIX" TMPDIR="$TMPDIR" _assert_sandbox "run $*" || return 2
  HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" "$@" >/dev/null 2>&1
}

# Stub harness: fake every external tool dehoard shells out to. Each stub logs
# "<name> <args>" to $STUB_LOG and exits 0 (so e.g. `docker info` "succeeds").
# Tests run dehoard with PATH="$STUBDIR:$SAFE_PATH" so these intercept the real
# tools, letting us assert the DESTRUCTIVE paths (brew/npm/docker/sudo-tmutil)
# without touching the real machine. sudo is stubbed too, so --deep can't mutate
# the system or hang on a password prompt.
make_stubs() {  # $1 = dir
  local d="$1" c; mkdir -p "$d"
  # osascript is stubbed for the same reason as the rest: without it every run that
  # reaches print_result posts a REAL macOS notification, so one suite spams the
  # developer's Notification Center ~100 times with fixture-sized figures.
  for c in brew npm pnpm yarn bun uv trunk pip pip3 docker ollama git xcrun sudo tmutil conda sdkmanager cargo gradle mvn osascript; do
    { echo '#!/bin/sh'
      echo 'printf "%s %s\n" "$(basename "$0")" "$*" >> "$STUB_LOG"'
      echo 'exit 0'; } > "$d/$c"
    chmod +x "$d/$c"
  done
}

# 1, preview deletes nothing
new_fixture
before=$(find "$FIX" -type f | wc -l | tr -d ' ')
run                                   # no --apply
after=$(find "$FIX" -type f | wc -l | tr -d ' ')
[[ "$before" == "$after" ]] && ok "preview (no --apply) deletes nothing ($before files intact)" \
                            || bad "preview deleted files! $before -> $after"
rm -rf "$FIX"

# 2, --apply clears a regenerable cache, keeps all user data
new_fixture
run --apply
[[ ! -e "$FIX/.npm/_npx" ]]          && ok "--apply removed ~/.npm/_npx (regenerable)" \
                                     || bad "~/.npm/_npx survived (Tier 1 should clear it)"
[[ -f "$FIX/.ollama/models/llama" ]] && ok "model weights survived --apply" \
                                     || bad "DELETED model weights (must never happen)"
[[ -f "$FIX/.claude_session" ]]      && ok "user session data survived" \
                                     || bad "DELETED user session data"
[[ -f "$FIX/proj/.venv/pyvenv.cfg" ]]&& ok "venv survived bare --apply (only --scan touches it)" \
                                     || bad "venv deleted without --scan"
[[ -d "$FIX" ]]                      && ok "\$HOME fixture survived" || bad "DELETED \$HOME (catastrophic)"
rm -rf "$FIX"

# 3, unset TMPDIR (mis-computed $BASE) stays safe
new_fixture
HOME="$FIX" PATH="$SAFE_PATH" zsh -c 'unset TMPDIR; zsh "'"$SCRIPT"'" --apply' >/dev/null 2>&1
[[ -d "$FIX" && -f "$FIX/.ollama/models/llama" ]] \
  && ok "unset TMPDIR run stayed safe (safe-root whitelist held)" \
  || bad "unset TMPDIR run damaged the fixture"
rm -rf "$FIX"

# 4, _rm refuses a path outside safe roots (direct guard unit check)
out=$(HOME=/tmp/dh-fake PATH="$SAFE_PATH" zsh -c '
  DRY_RUN=false; LOGFILE=""
  c_warn(){ printf "%s" "$*"; }; c_dim(){ printf "%s" "$*"; }   # color helpers live outside the extracted _rm
  '"$(sed -n "/^_rm() {/,/^}/p" "$SCRIPT")"'
  _rm /etc/hosts 2>&1; echo "rc=$?"
')
# Assert the BEHAVIOUR (refused, rc=1), not one exact sentence. There are two legitimate refusal
# reasons for /etc/hosts and which one fires is an implementation detail: macOS symlinks /etc to
# /private/etc, so the symlink-resolution guard can reject it before the plain prefix check does.
# Pinning the wording made a correct, stricter refusal look like a regression.
[[ "$out" == *"rc=1"* && ( "$out" == *"refusing path outside safe roots"* || "$out" == *"outside the safe roots"* ) ]] \
  && ok "_rm refuses out-of-root path (/etc/hosts)" \
  || bad "_rm did NOT refuse /etc/hosts: $out"

# 5a, TRUE duplicate: same build (instruct/Q8) in 2 tools → flagged + reclaim, read-only
FIX=$(mktemp -d)
mkdir -p "$FIX/.cache/huggingface/hub/models--meta-llama--Meta-Llama-3-8B-Instruct-Q8/blobs" \
         "$FIX/.lmstudio/models/x/Meta-Llama-3-8B-Instruct-Q8-GGUF"
dd if=/dev/zero of="$FIX/.cache/huggingface/hub/models--meta-llama--Meta-Llama-3-8B-Instruct-Q8/blobs/m.gguf" bs=1024 count=3000 2>/dev/null
dd if=/dev/zero of="$FIX/.lmstudio/models/x/Meta-Llama-3-8B-Instruct-Q8-GGUF/llama-3-8b-instruct-q8.gguf" bs=1024 count=2000 2>/dev/null
before=$(find "$FIX" -type f | wc -l | tr -d ' ')
rep=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --report 2>/dev/null)
after=$(find "$FIX" -type f | wc -l | tr -d ' ')
[[ "$rep" == *"True cross-tool duplicate"* && "$rep" == *"llama-8b"* && "$rep" == *reclaim* ]] \
  && ok "dedup flags TRUE duplicate (instruct/Q8 in HF+LMStudio) with reclaim" || bad "dedup missed the true duplicate"
[[ "$before" == "$after" ]] && ok "--report deletes nothing (read-only)" || bad "--report deleted files!"
rm -rf "$FIX"

# 5b, base vs instruct: same family+size, different VARIANT → related, NOT counted
FIX=$(mktemp -d)
mkdir -p "$FIX/.cache/huggingface/hub/models--meta-llama--Meta-Llama-3-8B/blobs" \
         "$FIX/.lmstudio/models/x/Meta-Llama-3-8B-Instruct-GGUF"
dd if=/dev/zero of="$FIX/.cache/huggingface/hub/models--meta-llama--Meta-Llama-3-8B/blobs/m.safetensors" bs=1024 count=3000 2>/dev/null
dd if=/dev/zero of="$FIX/.lmstudio/models/x/Meta-Llama-3-8B-Instruct-GGUF/llama-3-8b-instruct.gguf" bs=1024 count=2000 2>/dev/null
rep=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --report 2>/dev/null)
[[ "$rep" == *"Related cross-tool variants"* && "$rep" == *"llama-8b"* ]] \
  && ok "base-vs-instruct listed as RELATED variant" || bad "base/instruct not classified as related"
[[ "$rep" != *"True cross-tool duplicate"* ]] \
  && ok "base-vs-instruct NOT counted as a true duplicate" || bad "base/instruct wrongly counted as true dup"
rm -rf "$FIX"

# 5c, Q4 vs Q8: same family+size+variant, different QUANT → related, NOT counted
FIX=$(mktemp -d)
mkdir -p "$FIX/.cache/huggingface/hub/models--x--Meta-Llama-3-8B-Instruct-Q4/blobs" \
         "$FIX/.lmstudio/models/x/Meta-Llama-3-8B-Instruct-Q8-GGUF"
dd if=/dev/zero of="$FIX/.cache/huggingface/hub/models--x--Meta-Llama-3-8B-Instruct-Q4/blobs/m.gguf" bs=1024 count=3000 2>/dev/null
dd if=/dev/zero of="$FIX/.lmstudio/models/x/Meta-Llama-3-8B-Instruct-Q8-GGUF/llama-3-8b-instruct-q8.gguf" bs=1024 count=2000 2>/dev/null
rep=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --report 2>/dev/null)
[[ "$rep" == *"Related cross-tool variants"* ]] \
  && ok "Q4-vs-Q8 listed as RELATED variant" || bad "Q4/Q8 not classified as related"
[[ "$rep" != *"True cross-tool duplicate"* ]] \
  && ok "Q4-vs-Q8 NOT counted as a true duplicate" || bad "Q4/Q8 wrongly counted as true dup"
rm -rf "$FIX"

# 5d, different families: no cross-tool duplicate at all (no false positive)
FIX=$(mktemp -d)
mkdir -p "$FIX/.cache/huggingface/hub/models--mistralai--Mistral-7B/blobs" \
         "$FIX/.lmstudio/models/x/Qwen2-7B-Instruct-GGUF"
dd if=/dev/zero of="$FIX/.cache/huggingface/hub/models--mistralai--Mistral-7B/blobs/s" bs=1024 count=1500 2>/dev/null
dd if=/dev/zero of="$FIX/.lmstudio/models/x/Qwen2-7B-Instruct-GGUF/qwen2-7b.gguf" bs=1024 count=1500 2>/dev/null
rep=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --report 2>/dev/null)
[[ "$rep" != *"True cross-tool duplicate"* && "$rep" != *"Related cross-tool variants"* ]] \
  && ok "no false positive across different families (mistral vs qwen)" || bad "dedup false-positive across families"
rm -rf "$FIX"

# 5e, generic Electron cache sweep: deletes whitelisted cache subfolders, keeps user data
FIX=$(mktemp -d)
AS="$FIX/Library/Application Support/TestApp"
mkdir -p "$AS/Cache" "$AS/Code Cache" "$AS/Local Storage" "$AS/IndexedDB"
dd if=/dev/zero of="$AS/Cache/c" bs=1024 count=6000 2>/dev/null          # 6 MB → over the 5 MB floor
dd if=/dev/zero of="$AS/Local Storage/u" bs=1024 count=6000 2>/dev/null  # user data, must survive
echo userdata > "$AS/IndexedDB/data.sqlite"
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --scan --apply --yes >/dev/null 2>&1
[[ ! -d "$AS/Cache" ]] && ok "Electron sweep removed whitelisted Cache/ (no app list)" \
                       || bad "Electron Cache/ survived (should delete)"
[[ -d "$AS/Local Storage" && -f "$AS/IndexedDB/data.sqlite" ]] \
  && ok "Electron sweep KEPT Local Storage + IndexedDB (user data)" \
  || bad "DELETED Electron user data (Local Storage / IndexedDB)!"
rm -rf "$FIX"

# 5f, ignore list: path in ignore file is silently skipped; --reset-ignore clears it
FIX=$(mktemp -d)
mkdir -p "$FIX/.cache/huggingface" "$FIX/.config/dehoard"
dd if=/dev/zero of="$FIX/.cache/huggingface/x" bs=1024 count=200000 2>/dev/null  # 200 MB
# Pre-populate ignore list, no trailing slash (matches _ask normalization)
printf '%s\n' "$FIX/.cache/huggingface" > "$FIX/.config/dehoard/ignore"
# Dry-run should show ⊘ marker and NOT delete
dry_out=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --scan --dry-run 2>/dev/null)
[[ "$dry_out" == *"always-skip"* ]] && ok "ignored path shows ⊘ always-skip in dry-run" \
                                    || bad "ignored path not shown as always-skip in dry-run"
before=$(find "$FIX/.cache/huggingface" -type f 2>/dev/null | wc -l | tr -d ' ')
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --scan --apply --yes >/dev/null 2>&1
after=$(find "$FIX/.cache/huggingface" -type f 2>/dev/null | wc -l | tr -d ' ')
[[ "$before" == "$after" ]] && ok "ignored path NOT deleted on --apply (always-skip honored)" \
                             || bad "DELETED an always-skipped path!"
# --reset-ignore clears the file
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --reset-ignore >/dev/null 2>&1
[[ ! -f "$FIX/.config/dehoard/ignore" ]] && ok "--reset-ignore cleared the ignore file" \
                                         || bad "--reset-ignore did not clear ignore file"
rm -rf "$FIX"

# 5g, --report and bare preview (no --apply) never write to the ignore list
FIX=$(mktemp -d)
mkdir -p "$FIX/.cache/test"
dd if=/dev/zero of="$FIX/.cache/test/x" bs=1024 count=200000 2>/dev/null  # 200 MB
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --report >/dev/null 2>&1
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" >/dev/null 2>&1  # bare preview
[[ ! -f "$FIX/.config/dehoard/ignore" ]] \
  && ok "--report and bare preview never create ignore file" \
  || bad "--report or bare preview wrote to ignore file (should not)"
rm -rf "$FIX"

# 5h, --unignore removes one path, leaves others intact; empty file is deleted
FIX=$(mktemp -d)
mkdir -p "$FIX/.config/dehoard"
printf '%s\n%s\n' "$FIX/.cache/huggingface" "$FIX/.cache/torch" \
  > "$FIX/.config/dehoard/ignore"                                           # two entries
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --unignore "$FIX/.cache/huggingface" >/dev/null 2>&1
[[ -f "$FIX/.config/dehoard/ignore" ]] && \
  ! grep -qxF "$FIX/.cache/huggingface" "$FIX/.config/dehoard/ignore" && \
    grep -qxF "$FIX/.cache/torch" "$FIX/.config/dehoard/ignore" \
  && ok "--unignore removes one path, keeps the other" \
  || bad "--unignore failed: wrong file state"
# removing the last entry cleans up the file
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --unignore "$FIX/.cache/torch" >/dev/null 2>&1
[[ ! -f "$FIX/.config/dehoard/ignore" ]] \
  && ok "--unignore deletes ignore file when last entry removed" \
  || bad "--unignore left empty ignore file behind"
rm -rf "$FIX"

# 5i, DESTRUCTIVE external commands: --apply runs them with the exact documented args
#       (previously UNtested, the package-manager + Docker paths shipped on faith)
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; LOG="$FIX/stub.log"
make_stubs "$STUBDIR"
HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --deep --apply --yes >/dev/null 2>&1
[[ -f "$LOG" ]] || : > "$LOG"
grep -q -- "brew cleanup -s --prune=all" "$LOG" && ok "--apply runs 'brew cleanup -s --prune=all'" || bad "--apply did NOT run brew cleanup"
grep -q -- "brew autoremove"             "$LOG" && ok "--apply runs 'brew autoremove'"             || bad "--apply did NOT run brew autoremove"
grep -q -- "npm cache clean --force"     "$LOG" && ok "--apply runs 'npm cache clean --force'"     || bad "--apply did NOT run npm cache clean"
grep -q -- "docker system prune -f"      "$LOG" && ok "--deep --apply runs 'docker system prune -f'"  || bad "--apply did NOT run docker system prune"
grep -q -- "docker builder prune -af"    "$LOG" && ok "--deep --apply runs 'docker builder prune -af'" || bad "--apply did NOT run docker builder prune"
rm -rf "$FIX"

# 5j, THE SAFETY INVARIANT: dry-run / preview COMPUTES the preview but NEVER executes
#       a destructive command, even sudo-level ones (tmutil snapshot deletion).
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; LOG="$FIX/stub.log"
make_stubs "$STUBDIR"
HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --deep >/dev/null 2>&1   # dry-run (no --apply)
if grep -qiE -- "cleanup|autoremove|cache clean|cache purge|store prune|system prune|builder prune|deletelocalsnapshots|simctl delete|cache rm|gc --prune" "$LOG" 2>/dev/null; then
  bad "dry-run EXECUTED a destructive command: $(grep -iE -- 'cleanup|prune|delete|cache clean|cache purge|cache rm' "$LOG" | head -1)"
else
  ok "dry-run/preview ran ZERO destructive commands (core safety invariant, even under --deep)"
fi
# Sanity (real assertion, not tautological): dry-run DID still run the read-only TM probe, proving
# the stubs were actually reachable (so the "zero destructive" result above means something).
grep -q -- "listlocalsnapshotdates" "$LOG" 2>/dev/null \
  && ok "dry-run still ran the read-only probe (sudo tmutil listlocalsnapshotdates)" \
  || bad "dry-run did not run the read-only TM probe (stubs unreachable? the safety check above is moot)"
rm -rf "$FIX"

# 5k, --report --json: pure, valid, machine-readable model inventory (the product-foundation primitive)
if command -v python3 >/dev/null 2>&1; then
  FIX=$(mktemp -d)
  mkdir -p "$FIX/.cache/huggingface/hub/models--meta-llama--Meta-Llama-3-8B-Instruct-Q8/blobs" \
           "$FIX/.lmstudio/models/x/Meta-Llama-3-8B-Instruct-Q8-GGUF"
  dd if=/dev/zero of="$FIX/.cache/huggingface/hub/models--meta-llama--Meta-Llama-3-8B-Instruct-Q8/blobs/m" bs=1024 count=3000 2>/dev/null
  dd if=/dev/zero of="$FIX/.lmstudio/models/x/Meta-Llama-3-8B-Instruct-Q8-GGUF/Meta-Llama-3-8B-Instruct-Q8_0.gguf" bs=1024 count=2000 2>/dev/null
  js=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --json 2>/dev/null)
  # stdout must be PURE valid JSON, any leaked banner/stray line makes json.tool fail
  print -r -- "$js" | python3 -m json.tool >/dev/null 2>&1 \
    && ok "--json emits pure, valid JSON (parses via json.tool, no stdout leak)" \
    || bad "--json output is not valid JSON (stdout polluted?)"
  # schema contract: version + populated inventory + computed reclaim
  print -r -- "$js" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schema_version"]==1; assert len(d["models"])>=2; assert d["total_reclaim_bytes"]>0; assert d["models"][0]["size_bytes"]>0' 2>/dev/null \
    && ok "--json schema_version=1, models[] populated, size_bytes + total_reclaim_bytes computed" \
    || bad "--json schema/contents wrong"
  # read-only: --json must delete nothing
  before=$(find "$FIX" -type f | wc -l | tr -d ' ')
  HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --json >/dev/null 2>&1
  after=$(find "$FIX" -type f | wc -l | tr -d ' ')
  [[ "$before" == "$after" ]] && ok "--json is read-only (deletes nothing)" || bad "--json deleted files!"

  # A typo'd flag must not corrupt the --json data contract. The unknown-flag warning used to
  # go to stdout, so `dehoard --json --typo` emitted a warning line + JSON and failed to parse.
  HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --json --nosuchflag 2>/dev/null | python3 -m json.tool >/dev/null 2>&1 \
    && ok "unknown-flag warning goes to stderr, --json stays parseable" \
    || bad "unknown flag polluted --json stdout"

  # --snapshot: archives the document AND leaves stdout pure JSON (so piping still works).
  snapout=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --snapshot 2>/dev/null)
  print -r -- "$snapout" | python3 -m json.tool >/dev/null 2>&1 \
    && ok "--snapshot keeps stdout pure JSON (still pipeable)" \
    || bad "--snapshot polluted stdout"
  snapfiles=("$FIX"/.cache/dehoard/snapshots/*.json(N))
  (( ${#snapfiles[@]} == 1 )) && python3 -m json.tool < "${snapfiles[1]}" >/dev/null 2>&1 \
    && ok "--snapshot archives one valid JSON document under \$XDG_CACHE_HOME" \
    || bad "--snapshot did not archive a valid document"

  # --json alone must NOT archive anything (snapshotting is opt-in).
  rm -rf "$FIX"/.cache/dehoard/snapshots
  HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --json >/dev/null 2>&1
  [[ ! -d "$FIX/.cache/dehoard/snapshots" ]] \
    && ok "--json does not archive (snapshot is opt-in)" \
    || bad "--json wrote a snapshot without being asked"
  rm -rf "$FIX"
else
  ok "(skipped --json test: python3 not available to validate)"
fi

# Notification hygiene: a run that frees nothing must not post a macOS banner. "Freed 0 MB"
# is pure noise, and the notify line used to sit outside the freed/not-freed branch.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; LOG="$FIX/stub.log"
make_stubs "$STUBDIR"
mkdir -p "$FIX"/.ollama/models; echo weights > "$FIX/.ollama/models/llama"   # user data only, nothing to free
HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --apply --yes >/dev/null 2>&1
grep -q '^osascript ' "$LOG" 2>/dev/null \
  && bad "notified despite freeing nothing (Freed 0 MB banner)" \
  || ok "no notification when nothing was freed"
rm -rf "$FIX"

# A hung external tool must not hang the run. Docker is the real-world case: when Docker.app is
# gone but com.docker.backend survives, the socket exists with nothing answering, and `docker info`
# blocks forever rather than failing. Measured at >300s on a real machine in that state, which
# presented as a mid-run freeze with no output. Stub docker to hang and assert the run still
# finishes, proving the call is bounded by _run_timeout rather than trusting the tool to return.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; LOG="$FIX/stub.log"
make_stubs "$STUBDIR"
{ echo '#!/bin/sh'; echo 'sleep 300'; } > "$STUBDIR/docker"   # never returns
chmod +x "$STUBDIR/docker"
_t0=$SECONDS
HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --deep --dry-run >/dev/null 2>&1
_elapsed=$(( SECONDS - _t0 ))
(( _elapsed < 120 )) \
  && ok "a hung \`docker info\` cannot stall the run (finished in ${_elapsed}s, bounded)" \
  || bad "hung docker stalled the run for ${_elapsed}s - the timeout guard is missing"
rm -rf "$FIX"

# Symlinked ancestors. A redirected ~/Library/Caches makes a cache sweep delete whatever it points
# at, while the literal path still satisfies the allow-list. Two properties are pinned: a resolution
# that ESCAPES the safe roots is refused outright, and one that stays inside them is permitted but
# logged under its RESOLVED name so the audit trail cannot claim an innocent path.
# Extracts _rm AND every helper it calls. When _rm gained the live-database guard, omitting those
# helpers made the guard undefined inside this shell, so _rm fell through and deleted an open
# database while the test reported a failure that looked like a code bug. Any new _rm dependency
# must be added here too.
# Every function _rm calls, in definition order. _rm has gained dependencies three times and each
# time an inline extraction elsewhere silently omitted the new one, making the guard undefined and
# the test fail as though the CODE were broken. One list, one place to update.
_RM_DEPS=(_is_cancelled _run_timeout _load_open_files _db_family_in_use _holds_live_db _mv_to_trash _rm)
_rm_deps_src() { local f; for f in $_RM_DEPS; do sed -n "/^$f() {/,/^}/p" "$SCRIPT"; done }

_rm_iso() {   # $1 = fixture HOME, $2 = path; echoes _rm's output
  HOME="$1" PATH="$SAFE_PATH" zsh -c '
    DRY_RUN=false; TRASH_MODE=false; LOGFILE=""; _FREED_KB=0; _TRASHED_KB=0; _CANCELLED=false
    _OPEN_FILES_SNAPSHOT_FILE=""; _OPEN_FILES_LOADED=false
    c_warn(){ printf "%s" "$*"; }; c_dim(){ printf "%s" "$*"; }
    '"$(_rm_deps_src)"'
    _rm "$1" 2>&1' _ "$2"
}
FIX=$(mktemp -d); mkdir -p "$FIX/Documents" "$FIX/Library"
echo precious > "$FIX/Documents/thesis.txt"
ln -s "$FIX/Documents" "$FIX/Library/Caches"
out=$(_rm_iso "$FIX" "$FIX/Library/Caches/thesis.txt")
[[ "$out" == *"resolves through a symlink"* ]] \
  && ok "symlinked ancestor is announced before deleting" \
  || bad "symlinked ancestor deleted silently: [$out]"
[[ "$out" == *"Documents/thesis.txt"* && "$out" != *"removed: ~/Library/Caches/thesis.txt"* ]] \
  && ok "run log names the RESOLVED path, not the innocent literal" \
  || bad "run log claimed the literal path, hiding what was really deleted"
rm -rf "$FIX"

# B1: a path containing a control character cannot be logged faithfully, so it is not deleted.
# A newline in a filename splits one log record into two; ESC can rewrite the terminal mid-run.
FIX=$(mktemp -d); printf 'data' > "$FIX/plain.txt"
out=$(_rm_iso "$FIX" "$FIX/$(printf 'ev\x1bil')")
[[ "$out" == *"control character"* ]] \
  && ok "_rm refuses a path containing a control character" \
  || bad "_rm accepted a control-character path: [$out]"
rm -rf "$FIX"

# B4: in-progress downloads are skipped, not deleted - the transfer cannot be resumed once gone.
FIX=$(mktemp -d); : > "$FIX/big.dmg.crdownload"; : > "$FIX/other.part"
out=$(_rm_iso "$FIX" "$FIX/big.dmg.crdownload")
[[ -f "$FIX/big.dmg.crdownload" && "$out" == *"in-progress download"* ]] \
  && ok "_rm skips an in-progress download (.crdownload survives)" \
  || bad "_rm deleted an in-progress download: [$out]"
out=$(_rm_iso "$FIX" "$FIX/other.part")
[[ -f "$FIX/other.part" ]] \
  && ok "_rm skips a .part file too" \
  || bad "_rm deleted a .part file"
rm -rf "$FIX"

# B6: MV3 extension bytecode must NOT be in the Electron cache whitelist. Deleting ScriptCache
# breaks extension service workers even with the app closed; CacheStorage stays, it repopulates.
# Check the ARRAY line, not any mention: the exclusion is explained in a comment that names the
# path, and a naive grep matches that comment and reports the hazard as still present.
grep -E '^\s*CachedExtensionVSIXs .*ScriptCache' "$SCRIPT" >/dev/null \
  && bad "Service Worker/ScriptCache is still in the sweep array - breaks MV3 service workers" \
  || ok "Service Worker/ScriptCache excluded from the Electron sweep (MV3 bytecode)"
grep -q '"Service Worker/CacheStorage"' "$SCRIPT" \
  && ok "Service Worker/CacheStorage still swept (regenerable response cache)" \
  || bad "CacheStorage was dropped too - over-corrected"

# OS guard: the script itself refuses non-Darwin, matching what install.sh already promises.
grep -qE 'uname.*!=.*Darwin' "$SCRIPT" \
  && ok "script refuses non-Darwin (not only install.sh)" \
  || bad "no OS guard in the script itself"

# B3: never unlink a database another process still has open. Unlinking a live Cache.db does not
# merely lose a cache - the owner keeps writing to the unlinked inode, so the blocks are never
# freed and the "cleanup" can make free space go DOWN.
# Both directions are pinned. The open case caught a real bug: the probe originally passed `-b` to
# lsof, which stops it stat'ing its path arguments, so it matched nothing and reported every open
# database as idle - a guard that looked present and protected nothing.
FIX=$(mktemp -d); mkdir -p "$FIX/Cache"; echo dbdata > "$FIX/Cache/Cache.db"
zsh -c 'exec 9< "'"$FIX"'/Cache/Cache.db"; sleep 30' & _HOLDER=$!
sleep 1
_rm_iso "$FIX" "$FIX/Cache" >/dev/null 2>&1
[[ -f "$FIX/Cache/Cache.db" ]] \
  && ok "an OPEN database is kept, not unlinked (avoids the unbounded-write-loop failure)" \
  || bad "deleted a database while a process still had it open"
kill -9 $_HOLDER 2>/dev/null; wait $_HOLDER 2>/dev/null
rm -rf "$FIX"

# ...and the inverse, or the guard would simply stop dehoard cleaning anything.
FIX=$(mktemp -d); mkdir -p "$FIX/Cache"; echo dbdata > "$FIX/Cache/Cache.db"
_rm_iso "$FIX" "$FIX/Cache" >/dev/null 2>&1
[[ ! -e "$FIX/Cache" ]] \
  && ok "a CLOSED database is still deleted (guard is not blanket-refusing)" \
  || bad "guard refused a closed database - it would clean nothing"
rm -rf "$FIX"

# The -b regression itself: the path-argument query must not carry -b.
# One cached scan, not a per-file probe: lsof walks every process descriptor table to prove a file
# is NOT open, so per-candidate probing measured ~6.5s each and made the guard far costlier than the
# deletion it protects.
grep -qE '_load_open_files' "$SCRIPT" \
  && ok "db probe uses one cached lsof snapshot, not a per-file scan" \
  || bad "db probe scans per file - far too slow"

# B5: paths that are never a cache are refused even though the allow-list would permit them.
# The allow-list says "anything under $HOME", which is right for cache sweeps but means one bad
# glob could reach credentials or mail. These entries bound the blast radius of a future mistake.
FIX=$(mktemp -d)
for _prot in "Library/Keychains" "Library/Mail" "Library/Mobile Documents" ".ssh"; do
  mkdir -p "$FIX/$_prot"; : > "$FIX/$_prot/x"
  out=$(_rm_iso "$FIX" "$FIX/$_prot/x")
  [[ -f "$FIX/$_prot/x" && "$out" == *"protected path"* ]] \
    && ok "refuses protected path: ~/$_prot" \
    || bad "deleted inside ~/$_prot, which is never a cache: [$out]"
done
rm -rf "$FIX"

# B7: an unmeasurable size must read "unknown", never 0. A multi-GB delete logged as 0KB makes the
# run log lie about the one thing it exists to record.
FIX=$(mktemp -d); : > "$FIX/f"
# Stub BOTH du and stat: plain files are now sized with `stat -f%z` and only directories fall back
# to du, so stubbing du alone left the real stat running and the size was measurable after all.
STUBD=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$STUBD/du";   chmod +x "$STUBD/du"
printf '#!/bin/sh\nexit 1\n' > "$STUBD/stat"; chmod +x "$STUBD/stat"
out=$(HOME="$FIX" PATH="$STUBD:$SAFE_PATH" zsh -c '
  DRY_RUN=false; TRASH_MODE=false; LOGFILE=""; _FREED_KB=0; _TRASHED_KB=0
  c_warn(){ printf "%s" "$*"; }; c_dim(){ printf "%s" "$*"; }
  '"$(sed -n "/^_is_cancelled() {/,/^}/p" "$SCRIPT")"'
  '"$(sed -n "/^_run_timeout() {/,/^}/p" "$SCRIPT")"'
  '"$(sed -n "/^_db_family_in_use() {/,/^}/p" "$SCRIPT")"'
  '"$(sed -n "/^_holds_live_db() {/,/^}/p" "$SCRIPT")"'
  '"$(sed -n "/^_mv_to_trash() {/,/^}/p" "$SCRIPT")"'
  '"$(sed -n "/^_rm() {/,/^}/p" "$SCRIPT")"'
  _rm "'"$FIX"'/f" 2>&1')
[[ "$out" == *"(unknown)"* && "$out" != *"(0B)"* ]] \
  && ok "an unmeasurable size logs as 'unknown', never as 0" \
  || bad "unmeasurable size logged misleadingly: [$out]"
rm -rf "$FIX" "$STUBD"

# B2: //, /./ and a trailing / all name one file; policy is string-based, so normalize first.
FIX=$(mktemp -d); mkdir -p "$FIX/d"; : > "$FIX/d/f"
_rm_iso "$FIX" "$FIX//d/./f" >/dev/null 2>&1
[[ ! -e "$FIX/d/f" ]] \
  && ok "a path with // and /./ is normalized and handled" \
  || bad "non-normalized path was not handled"
rm -rf "$FIX"

# B8: once an interrupt has been seen, _rm stops working through its argument list. Without a
# sticky flag a signal delivered to a child can be absorbed by a `|| true` wrapper and the sweep
# carries on after the user asked it to stop.
FIX=$(mktemp -d); : > "$FIX/a"; : > "$FIX/b"
out=$(HOME="$FIX" PATH="$SAFE_PATH" zsh -c '
  DRY_RUN=false; TRASH_MODE=false; LOGFILE=""; _FREED_KB=0; _TRASHED_KB=0; _CANCELLED=true
  c_warn(){ printf "%s" "$*"; }; c_dim(){ printf "%s" "$*"; }
  '"$(sed -n "/^_is_cancelled() {/,/^}/p" "$SCRIPT")"'
  '"$(sed -n "/^_run_timeout() {/,/^}/p" "$SCRIPT")"'
  '"$(sed -n "/^_db_family_in_use() {/,/^}/p" "$SCRIPT")"'
  '"$(sed -n "/^_holds_live_db() {/,/^}/p" "$SCRIPT")"'
  '"$(sed -n "/^_mv_to_trash() {/,/^}/p" "$SCRIPT")"'
  '"$(sed -n "/^_rm() {/,/^}/p" "$SCRIPT")"'
  _rm "'"$FIX"'/a" "'"$FIX"'/b" 2>&1; echo "rc=$?"')
[[ -f "$FIX/a" && -f "$FIX/b" && "$out" == *"rc=130"* ]] \
  && ok "B8: after an interrupt _rm deletes nothing further (rc=130)" \
  || bad "B8: _rm kept deleting after cancellation: [$out]"
rm -rf "$FIX"

# Xcode device-support symbols: keep the newest N, drop the rest. Ordered by MTIME, not by version
# string, because version sorting mis-ranks betas - the same trap avoided for CLI versions.
FIX=$(mktemp -d); DS="$FIX/Library/Developer/Xcode/iOS DeviceSupport"; mkdir -p "$DS"
for v in 16.0 17.0 18.0 19.0; do mkdir -p "$DS/$v"; sleep 0.05; touch "$DS/$v"; done
out=$(zsh -c 'emulate zsh; setopt NULL_GLOB
  DEHOARD_XCODE_DEVICESUPPORT_KEEP=2
  _rm(){ print -r -- "DEL:${1:t}"; }
  for _dsroot in '"$FIX"'/Library/Developer/Xcode/*\ DeviceSupport(N/); do
    _vers=("${_dsroot%/}"/*(N/om))
    (( ${#_vers[@]} > DEHOARD_XCODE_DEVICESUPPORT_KEEP )) || continue
    for (( _i = DEHOARD_XCODE_DEVICESUPPORT_KEEP + 1; _i <= ${#_vers[@]}; _i++ )); do _rm "${_vers[_i]}"; done
  done')
[[ "$out" == *"DEL:16.0"* && "$out" == *"DEL:17.0"* && "$out" != *"DEL:19.0"* && "$out" != *"DEL:18.0"* ]] \
  && ok "Xcode DeviceSupport keeps the newest 2, removes older ones" \
  || bad "Xcode DeviceSupport pruning wrong: [$out]"
rm -rf "$FIX"

# Poetry virtualenvs must never be swept, even though sibling Poetry caches are.
grep -qE 'pypoetry/artifacts' "$SCRIPT" \
  && ok "Poetry artifacts/cache are swept" \
  || bad "Poetry cache rule missing"
grep -E '_rm .*pypoetry/virtualenvs' "$SCRIPT" >/dev/null \
  && bad "Poetry virtualenvs are being deleted - those are live interpreters" \
  || ok "Poetry virtualenvs are never deleted (live interpreters)"

# Escape case: resolution landing outside the safe roots must be refused, not merely announced.
FIX=$(mktemp -d); mkdir -p "$FIX/Library"
ln -s /usr/local "$FIX/Library/Caches"
out=$(_rm_iso "$FIX" "$FIX/Library/Caches/anything")
[[ "$out" == *"outside the safe roots"* && "$out" != *"removed:"* ]] \
  && ok "symlink resolving outside the safe roots is refused" \
  || bad "symlink escaped the allow-list: [$out]"
rm -rf "$FIX"

# Arithmetic-injection guard. zsh evaluates a variable's VALUE inside $(( )) recursively, and
# arithmetic supports assignment — so a numeric env var set to `(DRY_RUN=0)` clobbers the flag
# _rm branches on and silently turns a PREVIEW run into a real deletion. Regression: the victim
# must survive, and dehoard must say it previewed.
for _bad_var in DEHOARD_HELD_OPEN_MIN_GB CACHE_MIN_MB DEHOARD_PM_TIMEOUT; do
  new_fixture
  out=$(env "$_bad_var=(DRY_RUN=0)" HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" 2>&1)
  if [[ -f "$FIX/.npm/_npx/x" && "$out" == *"Preview complete"* ]]; then
    ok "arithmetic injection via \$$_bad_var cannot flip preview into delete"
  else
    bad "arithmetic injection via \$$_bad_var DELETED in preview mode"
  fi
  rm -rf "$FIX"
done
# ...and under --dry-run WITH --apply present, which is the path that actually reaches _pm_run.
# DEHOARD_PM_TIMEOUT's arithmetic (`maxticks=$(( secs * 5 ))`) lives in plain function scope, not a
# subshell, so this is the one variable whose clobber would propagate. The preview loop above never
# reaches it: _pm_run is only called from the else-branch of `if $DRY_RUN`.
for _bad_var in DEHOARD_PM_TIMEOUT CACHE_MIN_MB DEHOARD_HELD_OPEN_MIN_GB; do
  new_fixture
  out=$(env "$_bad_var=(DRY_RUN=0)" HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --apply --dry-run 2>&1)
  if [[ -f "$FIX/.npm/_npx/x" && "$out" == *"Preview complete"* ]]; then
    ok "arithmetic injection via \$$_bad_var cannot defeat --dry-run on the --apply path"
  else
    bad "arithmetic injection via \$$_bad_var DELETED despite --dry-run"
  fi
  rm -rf "$FIX"
done

# An empty `du` (path raced away mid-scan, or unreadable) must not abort the run. Stub `du` to
# print nothing: before the two-step-read fix this expanded to `$(( kb + ))` and killed the run
# with "bad math expression", leaving a partial clean and no tally.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; LOG="$FIX/stub.log"
make_stubs "$STUBDIR"
mkdir -p "$FIX"/.npm/_npx; : > "$FIX/.npm/_npx/x"
# The fixture MUST contain a directory the accumulate loop actually walks, or the test is vacuous:
# both patched sites sit inside `[[ -d … ]] || continue` guards, so with an empty fixture the buggy
# inline form is never evaluated and a reverted fix still "passes". This is an Electron-style cache
# dir, which the generic Application Support sweep enumerates.
mkdir -p "$FIX/Library/Application Support/FakeElectronApp/Cache"
: > "$FIX/Library/Application Support/FakeElectronApp/Cache/blob"
{ echo '#!/bin/sh'; echo 'exit 0'; } > "$STUBDIR/du"        # succeeds, prints nothing
chmod +x "$STUBDIR/du"
# --scan, not a bare run: the generic Electron cache sweep that contains the patched accumulate
# only executes under --scan. Verified by reverting the fix and confirming this exact invocation
# emits "bad math expression" while a bare run does not.
out=$(HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --scan 2>&1)
[[ "$out" != *"bad math expression"* ]] \
  && ok "an empty du does not abort the --scan sweep (no 'bad math expression')" \
  || bad "empty du aborted the run: [$(print -r -- "$out" | grep -m1 'bad math')]"
rm -rf "$FIX"
# A legitimate numeric override must still be honored (the guard must not reject valid input).
# NOTE: this must NOT use --version. --version exits early, hundreds of lines before
# _num_or_default runs, so such a test passes even against a guard that rejects every legal
# integer. Assert on the guard's own stderr warning instead: it must fire for a bad value and
# stay silent for a good one.
new_fixture
out=$(DEHOARD_HELD_OPEN_MIN_GB=20 HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" 2>&1 >/dev/null)
[[ "$out" != *"ignoring non-numeric"* ]] \
  && ok "numeric env-var override (20) is accepted, no spurious warning" \
  || bad "injection guard rejected a valid numeric override: [$out]"
out=$(DEHOARD_HELD_OPEN_MIN_GB="5.5" HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" 2>&1 >/dev/null)
[[ "$out" == *"ignoring non-numeric DEHOARD_HELD_OPEN_MIN_GB='5.5'"* ]] \
  && ok "non-integer env var is rejected by name and value on stderr" \
  || bad "guard did not report a rejected non-integer: [$out]"
rm -rf "$FIX"

# ─────────────────────────────────────────────────────────────────────────────
# --trash mode. This is a DELETION path, so it is covered in three layers:
# broad end-to-end first, then the behavioural contracts that make the mode
# safe, then atomic unit tests on _mv_to_trash extracted from the script.
# Two real bugs were found here by hand before any test existed (trashing the
# Trash, and the same run emptying it again), which is why the contracts below
# are pinned individually rather than by one happy-path assertion.
# ─────────────────────────────────────────────────────────────────────────────

# ── Layer 1: broad — does the feature work at all, end to end ────────────────
new_fixture
echo payload > "$FIX/.npm/_npx/x"
out=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --apply --yes --trash 2>&1)
if [[ ! -e "$FIX/.npm/_npx" && -e "$FIX/.Trash/_npx" ]]; then
  ok "--trash: cache is moved out of place and into ~/.Trash"
else
  bad "--trash: cache was not moved into ~/.Trash (src-gone=$([[ -e $FIX/.npm/_npx ]] && echo no || echo yes))"
fi
[[ "$(cat "$FIX/.Trash/_npx/x" 2>/dev/null)" == payload ]] \
  && ok "--trash: trashed content is intact and recoverable" \
  || bad "--trash: trashed content lost or unreadable"
[[ "$out" == *"trashed:"* && "$out" == *"Moved to Trash"* ]] \
  && ok "--trash: reports 'trashed:' per path and a 'Moved to Trash' summary" \
  || bad "--trash: missing trashed/summary output"
rm -rf "$FIX"

# ── Layer 2: behavioural contracts ───────────────────────────────────────────

# The headline number must never count trashed bytes as reclaimed: the blocks are
# still allocated. A trash-only run therefore still reports "Nothing deleted."
new_fixture
echo payload > "$FIX/.npm/_npx/x"
out=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --apply --yes --trash 2>&1)
[[ "$out" == *"Nothing deleted."* && "$out" != *"Storage freed"* ]] \
  && ok "--trash: trashed bytes are NOT counted as freed (no 'Storage freed')" \
  || bad "--trash: trashed bytes leaked into the freed tally"
[[ "$out" == *"NOT reclaimed until you empty it"* ]] \
  && ok "--trash: states plainly that nothing is reclaimed until the Trash is emptied" \
  || bad "--trash: missing the not-reclaimed caveat"
rm -rf "$FIX"

# The guard inside _rm: a path already under ~/.Trash must be DELETED, never moved,
# even when TRASH_MODE is on. Moving ~/.Trash/x into ~/.Trash only renames it, so the
# Trash could never drain. This must run WITH --trash or TRASH_MODE is false and the
# guard is never evaluated (an earlier version of this test made exactly that mistake
# and passed against a deliberately broken guard).
FIX=$(mktemp -d)
mkdir -p "$FIX/.Trash/oldjunk"; echo old > "$FIX/.Trash/oldjunk/f"
out=$(HOME="$FIX" PATH="$SAFE_PATH" zsh -c '
  DRY_RUN=false; TRASH_MODE=true; LOGFILE=""; _FREED_KB=0; _TRASHED_KB=0
  c_warn(){ printf "%s" "$*"; }; c_dim(){ printf "%s" "$*"; }
  '"$(sed -n "/^_mv_to_trash() {/,/^}/p" "$SCRIPT")"'
  '"$(sed -n "/^_rm() {/,/^}/p" "$SCRIPT")"'
  _rm "'"$FIX"'/.Trash/oldjunk" 2>&1
')
if [[ ! -e "$FIX/.Trash/oldjunk" && "$out" == *"removed:"* && "$out" != *"trashed:"* ]]; then
  ok "--trash guard: a path already in ~/.Trash is DELETED, not re-trashed"
else
  bad "--trash guard: Trash content was moved instead of deleted (Trash can never drain) [$out]"
fi
rm -rf "$FIX"

# ...and under --trash the empty-Trash step is skipped entirely, so the run does
# not delete what it just moved there. Without this, --trash provides no undo.
new_fixture
echo payload > "$FIX/.npm/_npx/x"
out=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --apply --yes --trash 2>&1)
[[ -e "$FIX/.Trash/_npx" && "$out" == *"Skipping empty-Trash"* ]] \
  && ok "--trash: skips emptying the Trash, so the undo survives the same run" \
  || bad "--trash: the run emptied the Trash and destroyed its own undo"
rm -rf "$FIX"

# A trash-only run freed nothing, so it must post no desktop notification.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; LOG="$FIX/stub.log"
make_stubs "$STUBDIR"; mkdir -p "$FIX"/.npm/_npx; echo p > "$FIX/.npm/_npx/x"
HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --apply --yes --trash >/dev/null 2>&1
grep -q '^osascript ' "$LOG" 2>/dev/null \
  && bad "--trash: notified even though nothing was actually freed" \
  || ok "--trash: posts no notification (nothing was freed, only moved)"
rm -rf "$FIX"

# --trash is not a deletion authorisation. Without --apply it must move nothing.
new_fixture
echo payload > "$FIX/.npm/_npx/x"
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --trash >/dev/null 2>&1
[[ -f "$FIX/.npm/_npx/x" && ! -e "$FIX/.Trash/_npx" ]] \
  && ok "--trash without --apply moves nothing (preview still wins)" \
  || bad "--trash moved a file without --apply"
rm -rf "$FIX"

# The ignore list is checked BEFORE the trash branch, so an ignored path is
# skipped rather than quietly relocated.
new_fixture
mkdir -p "$FIX/.config/dehoard"; echo "$FIX/.npm/_npx" > "$FIX/.config/dehoard/ignore"
echo payload > "$FIX/.npm/_npx/x"
out=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --apply --yes --trash 2>&1)
[[ -f "$FIX/.npm/_npx/x" && ! -e "$FIX/.Trash/_npx" ]] \
  && ok "--trash honours the ignore list (ignored path is not trashed)" \
  || bad "--trash trashed a path on the ignore list"
rm -rf "$FIX"

# TRASH_MODE is executed as a boolean command, so it is frozen like DRY_RUN.
grep -q '^typeset -r TRASH_MODE' "$SCRIPT" \
  && ok "--trash: TRASH_MODE is typeset -r (cannot be reassigned mid-run)" \
  || bad "--trash: TRASH_MODE is not frozen"

# ── Layer 3: atomic — _mv_to_trash in isolation ──────────────────────────────
# Extracted from the script the same way _rm is, so these pin the helper itself
# rather than observing it through a full run.
_mvt() {   # $1 = fixture HOME, rest = args to _mv_to_trash; echoes "rc=<n>"
  local _h="$1"; shift
  HOME="$_h" PATH="$SAFE_PATH" zsh -c '
    LOGFILE=""
    '"$(sed -n "/^_mv_to_trash() {/,/^}/p" "$SCRIPT")"'
    _mv_to_trash "$1"; echo "rc=$?"
  ' _ "$@"
}

FIX=$(mktemp -d); echo one > "$FIX/a.txt"
r=$(_mvt "$FIX" "$FIX/a.txt")
[[ "$r" == *rc=0* && -f "$FIX/.Trash/a.txt" && ! -e "$FIX/a.txt" ]] \
  && ok "_mv_to_trash: no collision → lands at the base name, source removed" \
  || bad "_mv_to_trash: simple move failed [$r]"
[[ "$(cat "$FIX/.Trash/a.txt")" == one ]] \
  && ok "_mv_to_trash: content preserved byte-for-byte" \
  || bad "_mv_to_trash: content changed"
rm -rf "$FIX"

FIX=$(mktemp -d); mkdir -p "$FIX/.Trash"; echo existing > "$FIX/.Trash/a.txt"; echo new > "$FIX/a.txt"
_mvt "$FIX" "$FIX/a.txt" >/dev/null
[[ -f "$FIX/.Trash/a.txt-1" && "$(cat "$FIX/.Trash/a.txt")" == existing ]] \
  && ok "_mv_to_trash: 1 collision → suffixed -1, the existing file is NOT clobbered" \
  || bad "_mv_to_trash: collision clobbered an existing trashed file (data loss)"
rm -rf "$FIX"

FIX=$(mktemp -d); mkdir -p "$FIX/.Trash"
echo e0 > "$FIX/.Trash/a.txt"; echo e1 > "$FIX/.Trash/a.txt-1"; echo e2 > "$FIX/.Trash/a.txt-2"
echo new > "$FIX/a.txt"
_mvt "$FIX" "$FIX/a.txt" >/dev/null
if [[ -f "$FIX/.Trash/a.txt-3" && "$(cat "$FIX/.Trash/a.txt-3")" == new \
      && "$(cat "$FIX/.Trash/a.txt")" == e0 && "$(cat "$FIX/.Trash/a.txt-2")" == e2 ]]; then
  ok "_mv_to_trash: N collisions → next free suffix, no earlier entry disturbed"
else
  bad "_mv_to_trash: multi-collision suffixing wrong or clobbered an earlier entry"
fi
rm -rf "$FIX"

FIX=$(mktemp -d); echo spaced > "$FIX/a file with spaces.txt"
_mvt "$FIX" "$FIX/a file with spaces.txt" >/dev/null
[[ -f "$FIX/.Trash/a file with spaces.txt" ]] \
  && ok "_mv_to_trash: a filename containing spaces survives intact" \
  || bad "_mv_to_trash: split or mangled a spaced filename"
rm -rf "$FIX"

# Failure path: ~/.Trash exists as a FILE, so mkdir -p cannot create the dir.
# The helper must report failure AND leave the source untouched, so the caller
# can warn and skip without crediting anything to the trashed tally.
FIX=$(mktemp -d); : > "$FIX/.Trash"; echo keepme > "$FIX/a.txt"
r=$(_mvt "$FIX" "$FIX/a.txt")
# rc is asserted EXACTLY, not just "file survived": a helper that succeeds while moving
# nothing also leaves the file in place, and the caller would then credit bytes to the
# trashed tally and print "trashed:" for a file that never moved. Only the return code
# distinguishes those two, so pin it.
[[ "$r" == *rc=1* ]] \
  && ok "_mv_to_trash: unusable ~/.Trash → returns 1 (failure is reported, not swallowed)" \
  || bad "_mv_to_trash: reported success for a move that did not happen [$r]"
[[ -f "$FIX/a.txt" && "$(cat "$FIX/a.txt")" == keepme ]] \
  && ok "_mv_to_trash: a failed move leaves the source byte-intact" \
  || bad "_mv_to_trash: lost the source on a failed move"
rm -rf "$FIX"

# ...and the caller must honour that failure: nothing trashed, nothing tallied.
new_fixture
: > "$FIX/.Trash"                      # a file, so the Trash cannot be created
echo payload > "$FIX/.npm/_npx/x"
out=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --apply --yes --trash 2>&1)
[[ -f "$FIX/.npm/_npx/x" && "$out" == *"could not trash"* && "$out" != *"Moved to Trash"* ]] \
  && ok "--trash: a failed move leaves the file alone and credits nothing" \
  || bad "--trash: failed move lost the file or credited a bogus tally"
rm -rf "$FIX"

# Held-open deleted inodes: a process sitting on deleted files keeps their blocks, so df
# under-reports and dehoard's figure looks wrong for reasons dehoard did not cause. Stub lsof
# in -F field mode (what the code parses) to fake one 26 GB holder, then one 0.43 GB holder.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; LOG="$FIX/stub.log"
make_stubs "$STUBDIR"
_fake_lsof() {   # $1 = bytes held by the single fake process
  # Must emit D (device) and i (inode): the parser accumulates on the inode record so it can
  # dedup a file that lsof reports once per descriptor and once per mmap.
  { echo '#!/bin/sh'
    echo 'printf "p4242\ncbloatd\nftxt\nD0x99\ns'"$1"'\ni4242001\n"'
    echo 'exit 0'; } > "$STUBDIR/lsof"
  chmod +x "$STUBDIR/lsof"
}
# Dedup: lsof emits one record per descriptor AND per mmap, each with the file's FULL size, so the
# same deleted inode opened twice must be counted ONCE. Two descriptors (f3/f4), same device+inode.
{ echo '#!/bin/sh'
  echo 'printf "p777\ncdoubled\nf3\nD0xAA\ns1073741824\ni999\nf4\nD0xAA\ns1073741824\ni999\n"'
  echo 'exit 0'; } > "$STUBDIR/lsof"
chmod +x "$STUBDIR/lsof"
HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --json 2>/dev/null \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["held_open_deleted_bytes"]==1073741824' 2>/dev/null \
  && ok "held-open: same inode on two descriptors counted once, not doubled" \
  || bad "held-open: double-counted a single inode held on two descriptors"
# And globally: one deleted inode shared by TWO processes still occupies its blocks only once.
{ echo '#!/bin/sh'
  echo 'printf "p101\ncalpha\nf3\nD0xBB\ns2147483648\ni555\np102\ncbeta\nf3\nD0xBB\ns2147483648\ni555\n"'
  echo 'exit 0'; } > "$STUBDIR/lsof"
chmod +x "$STUBDIR/lsof"
HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --json 2>/dev/null \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["held_open_deleted_bytes"]==2147483648' 2>/dev/null \
  && ok "held-open: one inode shared by two processes counted once in the global total" \
  || bad "held-open: global total inflated by the sharing factor"

_fake_lsof 27917287424        # 26 GB, well over the 5 GB per-process threshold
out=$(HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --report 2>/dev/null)
[[ "$out" == *"26.0 GB is held by deleted files"* && "$out" == *"bloatd (pid 4242)"* ]] \
  && ok "held-open: 26 GB holder is reported with size and process" \
  || bad "held-open warning missing or malformed"
# ...and it must never tell the user to kill anything; naming the process is where dehoard stops.
[[ "$out" != *"kill"* ]] \
  && ok "held-open: warns and names the process, never suggests killing it" \
  || bad "held-open warning suggests killing a process"
_fake_lsof 461373440          # 0.43 GB, ordinary macOS churn, must stay silent
out=$(HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --report 2>/dev/null)
[[ "$out" != *"held by deleted files"* ]] \
  && ok "held-open: sub-threshold holder (0.43 GB) stays silent (no false alarm)" \
  || bad "held-open fired below threshold"
# --json must stay pure even when the warning is active (the warning is human-output only).
_fake_lsof 27917287424
HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --json 2>/dev/null \
  | python3 -m json.tool >/dev/null 2>&1 \
  && ok "held-open warning never leaks into --json stdout" \
  || bad "held-open warning polluted --json"
# --json carries the figure as DATA, unthresholded: a machine consumer reconciles df itself.
HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --json 2>/dev/null \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["held_open_deleted_bytes"]==27917287424' 2>/dev/null \
  && ok "--json reports held_open_deleted_bytes exactly" \
  || bad "--json held_open_deleted_bytes wrong or missing"
# Sub-threshold: silent for humans, but still reported as data for machines.
_fake_lsof 461373440
HOME="$FIX" STUB_LOG="$LOG" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --json 2>/dev/null \
  | python3 -c 'import json,sys; assert json.load(sys.stdin)["held_open_deleted_bytes"]==461373440' 2>/dev/null \
  && ok "--json reports held-open bytes even below the human warning threshold" \
  || bad "--json suppressed sub-threshold held-open bytes"
rm -rf "$FIX"

# 5l, Ollama enumeration: 2+ models must NOT leak `onm=…` into stdout (regression: bare local-in-loop)
if command -v python3 >/dev/null 2>&1; then
  FIX=$(mktemp -d); OSTUB="$FIX/.ostub"; mkdir -p "$OSTUB"
  { echo '#!/bin/sh'
    echo '[ "$1" = "list" ] || exit 0'
    printf '%s\n' 'printf "NAME\tID\tSIZE\tMODIFIED\n"'
    printf '%s\n' 'printf "llama3:8b\tabc\t4.7 GB\t1 day ago\n"'
    printf '%s\n' 'printf "mistral:7b\tdef\t4.1 GB\t2 days ago\n"'; } > "$OSTUB/ollama"
  chmod +x "$OSTUB/ollama"
  # an HF llama too → cross-tool dup with the ollama llama3:8b
  mkdir -p "$FIX/.cache/huggingface/hub/models--meta-llama--Meta-Llama-3-8B/blobs"
  dd if=/dev/zero of="$FIX/.cache/huggingface/hub/models--meta-llama--Meta-Llama-3-8B/blobs/m" bs=1024 count=3000 2>/dev/null
  oj=$(HOME="$FIX" PATH="$OSTUB:$SAFE_PATH" zsh "$SCRIPT" --json 2>/dev/null)
  print -r -- "$oj" | python3 -m json.tool >/dev/null 2>&1 \
    && ok "--json stays valid with 2+ Ollama models (no bare-local stdout leak)" \
    || bad "--json corrupted by Ollama enumeration (local-in-loop leak regressed)"
  print -r -- "$oj" | grep -qiE '"tool": ?"Ollama"' && ok "Ollama models appear in --json inventory" \
    || bad "Ollama models missing from --json inventory"
  rm -rf "$FIX"
else
  ok "(skipped Ollama --json test: python3 unavailable)"
fi

# 5m, _rm FAILS CLOSED when $DRY_RUN is unset (defends the refactor: never delete on lost safety state)
FIX=$(mktemp -d); echo data > "$FIX/victim"
out=$(HOME="$FIX" PATH="$SAFE_PATH" zsh -c '
  unset DRY_RUN; LOGFILE=""
  c_warn(){ printf "%s" "$*"; }; c_dim(){ printf "%s" "$*"; }   # color helpers live outside the extracted _rm
  '"$(sed -n "/^_rm() {/,/^}/p" "$SCRIPT")"'
  _rm "'"$FIX"'/victim" 2>&1; echo "rc=$?"
')
[[ "$out" == *"failing closed"* && "$out" == *"rc=1"* && -f "$FIX/victim" ]] \
  && ok "_rm fails closed on unset \$DRY_RUN (refuses; whitelisted victim survives)" \
  || bad "_rm did NOT fail closed on unset DRY_RUN: [$out] victim-exists=$([[ -f $FIX/victim ]] && echo yes || echo NO)"
rm -rf "$FIX"

# 5m-bis, _rm fails closed on a CORRUPTED $DRY_RUN, not merely an unset one. $DRY_RUN is used as a
# boolean COMMAND (`if $DRY_RUN`), so a value like `0` is not a false-y flag: it runs a bogus
# command, fails, and falls through to the DELETE branch. An is-it-empty check passes such a value
# straight through, so the guard demands one of the two legal values.
for _bad_flag in 0 1 "" "TRUE" "yes"; do
  FIX=$(mktemp -d); echo data > "$FIX/victim"
  out=$(HOME="$FIX" PATH="$SAFE_PATH" DRY_RUN="$_bad_flag" zsh -c '
    LOGFILE=""
    c_warn(){ printf "%s" "$*"; }; c_dim(){ printf "%s" "$*"; }
    '"$(sed -n "/^_rm() {/,/^}/p" "$SCRIPT")"'
    _rm "'"$FIX"'/victim" 2>&1; echo "rc=$?"
  ')
  [[ "$out" == *"failing closed"* && "$out" == *"rc=1"* && -f "$FIX/victim" ]] \
    && ok "_rm fails closed on corrupted \$DRY_RUN='$_bad_flag' (victim survives)" \
    || bad "_rm did NOT fail closed on \$DRY_RUN='$_bad_flag': [$out]"
  rm -rf "$FIX"
done

# 5n, --help frozen against golden snapshot (catches help drift / heredoc breakage post-refactor)
if [[ -f "${0:A:h}/snapshots/help.txt" ]]; then
  diff <(zsh "$SCRIPT" --help) "${0:A:h}/snapshots/help.txt" >/dev/null \
    && ok "--help byte-identical to golden snapshot" \
    || bad "--help drifted from test/snapshots/help.txt"
else
  ok "(no --help golden snapshot to compare)"
fi

# 5o, help top-level numbering is structurally sequential per section.
#       A byte-snapshot (5n) freezes whatever it's given, it can't tell a *correct* help from a
#       help with a duplicate or missing item number. This asserts the invariant directly: within
#       TIER 1 / TIER 2 / MODELS, the bare-integer items (sub-items like "6b." are ignored) must be
#       1,2,3,…,N in order, catching the exact class of bug (two "12.", missing "11.") that shipped.
numbering=$(zsh "$SCRIPT" --help | awk '
  /^TIER 1 /             { sec="TIER1"; next }
  /^TIER 2 /             { sec="TIER2"; next }
  /^MODELS \(--models\)/ { sec="MODELS"; next }
  /^SCAN \(--scan\)/     { sec="SCAN";  next }
  sec!="" && sec!="SCAN" && $1 ~ /^[0-9]+\.$/ {
    expected = ++cnt[sec]; got = $1 + 0
    if (got != expected) printf "%s: expected %d, got %d\n", sec, expected, got
  }
')
[[ -z "$numbering" ]] && ok "help top-level numbering is sequential per section (no gaps/dupes)" \
                      || bad "help numbering broken → ${numbering//$'\n'/ ; }"

# 5p, COLOR must never leak into a machine channel, even forced on (CLICOLOR_FORCE=1).
#       Assert the NEGATIVE: --json stdout and the --apply
#       deletion log must be byte-free of ANSI escapes; piped --report (non-TTY) too. And the
#       color branch must actually fire when forced (else it's dead code shipping untested).
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"
make_stubs "$STUBDIR"
mkdir -p "$FIX/.cache/huggingface/hub/models--meta-llama--Meta-Llama-3-8B-Instruct-Q8/blobs"
dd if=/dev/zero of="$FIX/.cache/huggingface/hub/models--meta-llama--Meta-Llama-3-8B-Instruct-Q8/blobs/m" bs=1024 count=2000 2>/dev/null
esc=$'\033'
# (a) --json stays pure JSON with color FORCED on
jf=$(HOME="$FIX" CLICOLOR_FORCE=1 PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --json 2>/dev/null)
[[ "$jf" != *"$esc"* ]] && ok "--json has zero ANSI escapes even under CLICOLOR_FORCE=1" \
                        || bad "--json leaked ANSI escapes under CLICOLOR_FORCE"
# (b) the --apply deletion log is raw text with color FORCED on
HOME="$FIX" CLICOLOR_FORCE=1 PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --apply --yes >/dev/null 2>&1
logf=("$FIX"/.cache/dehoard/run-*.log(N))
if (( ${#logf} )); then
  grep -q "$esc" "${logf[1]}" && bad "deletion log leaked ANSI escapes (must be raw text)" \
                              || ok "deletion log is escape-free even under CLICOLOR_FORCE=1"
else
  ok "(no deletion log written, nothing applied)"
fi
# (c) piped --report (non-TTY) carries no escapes
rf=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --report 2>/dev/null)
[[ "$rf" != *"$esc"* ]] && ok "piped --report (non-TTY) is escape-free" \
                        || bad "piped --report leaked ANSI escapes"
# (d) the color branch actually fires when forced (guards against dead/un-wired helpers)
pf=$(HOME="$FIX" CLICOLOR_FORCE=1 PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" 2>/dev/null)
[[ "$pf" == *"$esc"* ]] && ok "color path emits ANSI on the human cleanup path when forced" \
                        || bad "color path produced NO ANSI under CLICOLOR_FORCE (dead branch?)"
rm -rf "$FIX"

# 5q, mode-aware step labels: a cleanup-step label is DIM while previewing but BOLD under --apply,
#       where per-file deletion is silent so the label is the ONLY live evidence of rm -rf.
#       (Dimming the only live evidence of an active delete would hide it. This pins the fix.)
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; make_stubs "$STUBDIR"
dimseq=$'\033[2m'; boldseq=$'\033[1m'
prev=$(HOME="$FIX" CLICOLOR_FORCE=1 PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" 2>/dev/null)
appl=$(HOME="$FIX" CLICOLOR_FORCE=1 PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --apply --yes 2>/dev/null)
[[ "$prev" == *"${dimseq}Clearing browser update clones"* ]] \
  && ok "preview renders cleanup-step labels DIM" || bad "preview step label not dim"
[[ "$appl" == *"${boldseq}Clearing browser update clones"* ]] \
  && ok "--apply renders cleanup-step labels BOLD (the only live evidence of silent deletes)" \
  || bad "--apply step label not bold (dim-on-only-feedback regressed)"
rm -rf "$FIX"

# 5r, --version prints a clean version line and exits 0 (release hygiene for an rm -rf tool:
#       a user must be able to report which build they ran). Output is pure (no banner/color).
ver=$(PATH="$SAFE_PATH" zsh "$SCRIPT" --version 2>/dev/null); vrc=$?   # --version exits before touching $HOME
[[ "$ver" == "dehoard "[0-9]*.[0-9]*.[0-9]* && $vrc -eq 0 ]] \
  && ok "--version prints 'dehoard X.Y.Z' and exits 0 (got: $ver)" \
  || bad "--version wrong (out='$ver' rc=$vrc)"

# 5s, inventory sizing is HARDLINK-AWARE (a wrong reclaim number is a deletion bug in a safe
#       costume). dehoard sizes via `du`, which counts a shared inode ONCE. This pins that: a
#       model dir whose blob is hardlinked twice must report ~1x its size, not 2x. Guards against a
#       future refactor to naive per-file summing (which would double-count and inflate "reclaim").
if command -v python3 >/dev/null 2>&1; then
  FIX=$(mktemp -d)
  md="$FIX/.cache/huggingface/hub/models--x--HardlinkModel/blobs"; mkdir -p "$md"
  dd if=/dev/zero of="$md/real" bs=1024 count=4096 2>/dev/null   # 4 MB real blob
  ln "$md/real" "$md/hardlink"                                   # hardlink → SAME inode (not a copy)
  js=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --json 2>/dev/null)
  # size_bytes must reflect ~4 MB (inode counted once), NOT ~8 MB (naive real+hardlink sum).
  print -r -- "$js" | python3 -c '
import json,sys
d=json.load(sys.stdin)
m=[x for x in d["models"] if x["family"].startswith("x") or "hardlink" in x["name"].lower()]
sz=m[0]["size_bytes"] if m else (d["models"][0]["size_bytes"] if d["models"] else 0)
sys.exit(0 if 3_000_000 <= sz <= 5_500_000 else 1)   # ~4MB ok; ~8MB (double-count) fails
' 2>/dev/null \
    && ok "inventory size counts a hardlinked blob ONCE (du-based, not naive summing)" \
    || bad "inventory size double-counted a hardlink (reclaim numbers would be inflated)"
  rm -rf "$FIX"
else
  ok "(skipped hardlink-sizing test: python3 unavailable)"
fi

# 5t, --apply echoes each deleted path live (deletions are no longer silent; the user sees what
#       was removed in real time, not just a section label + a log file they have to go read).
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; make_stubs "$STUBDIR"
mkdir -p "$FIX/.npm/_npx"; : > "$FIX/.npm/_npx/x"          # a Tier-1 cache dehoard deletes
ao=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --apply --yes 2>/dev/null)
[[ "$ao" == *"removed:"*"_npx"* ]] \
  && ok "--apply echoes each removed path live (deletions are visible, not silent)" \
  || bad "--apply did not echo the removed path"
rm -rf "$FIX"

# 5u, MATLAB: --scan clears stale logs but KEEPS the active ServiceHost runtime (deleting it would
#       just force a re-download, so dehoard leaves it alone) and keeps prefs, history, and user code.
#       Also proves the space-containing MathWorks paths are handled.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; make_stubs "$STUBDIR"
AS="$FIX/Library/Application Support/MathWorks"
mkdir -p "$AS/ServiceHost/v1" "$AS/ServiceHost/logs" "$AS/MATLAB/R2024b" "$FIX/Documents/MATLAB"
dd if=/dev/zero of="$AS/ServiceHost/v1/runtime" bs=1024 count=6000 2>/dev/null   # active runtime, must SURVIVE
dd if=/dev/zero of="$AS/ServiceHost/logs/log1"  bs=1024 count=2000 2>/dev/null   # stale logs, should clear
echo prefs   > "$AS/MATLAB/R2024b/matlab.prf"      # user prefs, must survive
echo history > "$AS/MATLAB/R2024b/history.m"       # command history, must survive
echo mycode  > "$FIX/Documents/MATLAB/script.m"    # user code, must survive
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --scan --apply --yes >/dev/null 2>&1
[[ ! -d "$AS/ServiceHost/logs" ]] && ok "MATLAB: stale ServiceHost logs cleared" \
                                  || bad "MATLAB logs survived (should clear)"
[[ -f "$AS/ServiceHost/v1/runtime" ]] && ok "MATLAB: active ServiceHost runtime KEPT (no forced re-download)" \
                                      || bad "DELETED the active MATLAB runtime (would force a re-download)!"
[[ -f "$AS/MATLAB/R2024b/history.m" && -f "$AS/MATLAB/R2024b/matlab.prf" && -f "$FIX/Documents/MATLAB/script.m" ]] \
  && ok "MATLAB: prefs, command history, and user code KEPT" \
  || bad "DELETED MATLAB user data (prefs/history/code)!"
rm -rf "$FIX"

# 5v, docs/RULES.md safe-root list must match _rm's actual whitelist (a constitution that
#       drifts from the code becomes a lie a future generator would trust; pin them together).
RULES="${0:A:h}/../docs/RULES.md"
if [[ -f "$RULES" ]]; then
  # Code side: pull the _rm whitelist case-pattern, split on '|', strip the trailing /* and quotes.
  code_roots=$(grep -oE '"\$HOME"/[^)]*' "$SCRIPT" | head -1 \
    | tr '|' '\n' | sed -e 's@/\*$@@' -e 's@"@@g' | sort)
  # Doc side: the backtick tokens between the safe-roots:begin/end markers.
  doc_roots=$(awk '/safe-roots:begin/{f=1;next} /safe-roots:end/{f=0} f' "$RULES" \
    | grep -oE '`[^`]+`' | tr -d '`' | sort)
  if [[ -n "$code_roots" && "$code_roots" == "$doc_roots" ]]; then
    ok "docs/RULES.md safe-root list matches _rm's whitelist (constitution in sync with code)"
  else
    bad "docs/RULES.md safe-roots drifted from _rm (code: $(echo $code_roots) | doc: $(echo $doc_roots))"
  fi
else
  bad "docs/RULES.md not found (the safety constitution must ship with the tool)"
fi

# 5w, a hung package-manager tool must NOT freeze the run: the timeout guard kills it and
#       continues (real-machine bug #17: a PM command blocked >10 min, no timeout).
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\nsleep 30' > "$STUBDIR/brew"; chmod +x "$STUBDIR/brew"   # brew now HANGS
mkdir -p "$FIX/.npm/_npx"; : > "$FIX/.npm/_npx/x"
( HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_PM_TIMEOUT=2 \
    zsh "$SCRIPT" --apply --yes >"$FIX/out" 2>&1 ) &
run_pid=$!
( sleep 90; kill -9 $run_pid 2>/dev/null ) &     # safety net (wide margin: the guarded run finishes in ~2s, so 137 means a truly hung guard, not a slow box)
wd_pid=$!
wait $run_pid 2>/dev/null; run_rc=$?
kill $wd_pid 2>/dev/null; wait $wd_pid 2>/dev/null
if (( run_rc == 137 )); then
  bad "PM timeout guard FAILED: run had to be force-killed (a hung tool still freezes it)"
elif grep -q "timed out" "$FIX/out"; then
  ok "hung package-manager tool times out and the run continues (PM guard works)"
else
  bad "PM guard: run finished but emitted no 'timed out' notice"
fi
rm -rf "$FIX"

# 5x, Time Machine snapshot parse: the `tmutil listlocalsnapshotdates` HEADER line must never be
#       treated as a snapshot date (real-machine bug: it showed "would delete: Snapshot dates for disk /:").
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\nexec "$@"' > "$STUBDIR/sudo"; chmod +x "$STUBDIR/sudo"   # sudo runs its args
cat > "$STUBDIR/tmutil" <<'TMEOF'
#!/bin/sh
case "$1" in
  listlocalsnapshotdates) printf 'Snapshot dates for disk /:\n2026-05-30-010101\n2026-05-31-020202\n' ;;
esac
exit 0
TMEOF
chmod +x "$STUBDIR/tmutil"
tmout=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" zsh "$SCRIPT" --dry-run 2>&1)
if echo "$tmout" | grep -q "delete snapshot:.*Snapshot dates for disk"; then
  bad "TM snapshot: header line mis-parsed as a snapshot date"
elif echo "$tmout" | grep -q "would delete snapshot: 2026-05-30-010101"; then
  ok "TM snapshot parse: header dropped, real date kept, latest preserved"
else
  bad "TM snapshot parse: expected a real date in the would-delete output"
fi
rm -rf "$FIX"

# 5y, _rm honesty: on a delete that FAILS (unremovable dir), do NOT print "removed:", warn ONCE,
#       keep rm's error flood off the terminal (routed to the log), and still delete good siblings.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
mkdir -p "$FIX/Library/Caches/node-gyp/sub"; : > "$FIX/Library/Caches/node-gyp/sub/f"
chmod 000 "$FIX/Library/Caches/node-gyp"          # rm -rf can't recurse → fails (approximates root-owned)
mkdir -p "$FIX/.cache/node"; : > "$FIX/.cache/node/x"   # a deletable sibling cache
ho=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" zsh "$SCRIPT" --apply --yes 2>&1)
chmod -R u+rwx "$FIX/Library/Caches/node-gyp" 2>/dev/null   # restore so cleanup can remove it
if echo "$ho" | grep -q "removed:.*node-gyp"; then
  bad "_rm claimed 'removed:' for a path rm failed on (the lie is back)"
elif ! echo "$ho" | grep -q "could not remove.*node-gyp"; then
  bad "_rm did not warn on a failed delete"
elif echo "$ho" | grep -q "rm: "; then
  bad "_rm let rm's error flood hit the terminal (should route to the log)"
elif ! echo "$ho" | grep -q "removed:.*\.cache/node"; then
  bad "_rm did not delete/echo a removable sibling after a failure"
else
  ok "_rm: failed delete warns once, no flood, no false 'removed:', good deletes still echo"
fi
rm -rf "$FIX"

# 5z, universal ignore list: a path matching an ignore entry (incl. a glob) must survive even in the
#       batch Tier-1 sweep (not just interactive prompts), and the skip is announced.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
mkdir -p "$FIX/.config/dehoard"
print -r -- "$FIX/Library/Caches/node-*" > "$FIX/.config/dehoard/ignore"   # a GLOB ignore entry
mkdir -p "$FIX/Library/Caches/node-gyp"; : > "$FIX/Library/Caches/node-gyp/f"   # ignored → must survive
mkdir -p "$FIX/.cache/node"; : > "$FIX/.cache/node/x"                            # not ignored → deleted
io=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" zsh "$SCRIPT" --apply --yes 2>&1)
if [[ -d "$FIX/Library/Caches/node-gyp" ]] && [[ ! -d "$FIX/.cache/node" ]] && echo "$io" | grep -q "ignored:.*node-gyp"; then
  ok "ignore list honored by _rm in batch Tier 1: globbed path survives + announced, others deleted"
else
  bad "ignore list NOT honored by _rm/batch tiers (globbed node-gyp should survive + be announced)"
fi
rm -rf "$FIX"

# 5A, --pick = ONE unified fzf picker across all in-scope --scan categories. fzf is stubbed;
#      DEHOARD_FORCE_PICKER=1 lifts the TTY gate. The stub stands in for the user's marking:
#      `cat` = every record selected (≈ Ctrl-A select-all); `exit 0` = nothing marked (Esc/abort);
#      a perl filter = mark only one category. The picker is delete-time only (needs --apply).
_mk_mixed() {  # $1 = HOME fixture: a venv + a node_modules + a >100KB log + a .bak (4 categories)
  mkdir -p "$1/p1/.venv/bin"; echo "home = /x" > "$1/p1/.venv/pyvenv.cfg"; : > "$1/p1/.venv/bin/python"
  mkdir -p "$1/proj/node_modules/x"; : > "$1/proj/node_modules/x/f"
  dd if=/dev/zero of="$1/proj/big.log" bs=1024 count=200 2>/dev/null   # >100K so it's scanned
  : > "$1/proj/notes.bak"
}
# (a) select-all (stub fzf = cat → all records back): every category deleted
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
_mk_mixed "$FIX"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
[[ ! -d "$FIX/p1/.venv" && ! -d "$FIX/proj/node_modules" && ! -f "$FIX/proj/big.log" && ! -f "$FIX/proj/notes.bak" ]] \
  && ok "--pick select-all deletes across every category (venv+node_modules+log+bak)" \
  || bad "--pick select-all did not delete every category"
rm -rf "$FIX"
# (b) ABORT (the critical one): stub fzf emits nothing → NOTHING deleted, even under --apply --yes
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\nexit 0' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
_mk_mixed "$FIX"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
[[ -d "$FIX/p1/.venv" && -d "$FIX/proj/node_modules" && -f "$FIX/proj/big.log" && -f "$FIX/proj/notes.bak" ]] \
  && ok "--pick abort/empty selection deletes NOTHING (safety contract holds)" \
  || bad "--pick abort DELETED something (safety contract broken!)"
rm -rf "$FIX"
# (c) PARTIAL cross-category: mark only node_modules → it goes, the other 3 categories survive
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\nexec perl -0 -ne \'print if /node_modules/\'' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
_mk_mixed "$FIX"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
[[ ! -d "$FIX/proj/node_modules" && -d "$FIX/p1/.venv" && -f "$FIX/proj/big.log" && -f "$FIX/proj/notes.bak" ]] \
  && ok "--pick partial selection deletes only marked category, keeps the rest" \
  || bad "--pick partial selection deleted the wrong set"
rm -rf "$FIX"
# (d) no fzf → falls back to the per-item _ask prompts (still deletes under --yes)
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
rm -f "$STUBDIR/fzf" 2>/dev/null              # ensure fzf is absent
_mk_mixed "$FIX"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
[[ ! -d "$FIX/proj/node_modules" && ! -f "$FIX/proj/big.log" ]] \
  && ok "--pick with no fzf falls back to per-item prompts (deleted under --yes)" \
  || bad "--pick no-fzf fallback did not delete via _ask"
rm -rf "$FIX"
# (e) preview/dry-run: --pick WITHOUT --apply must NOT invoke fzf, must print the note, delete nothing
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\necho "fzf $*" >> "$STUB_LOG"\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
_mk_mixed "$FIX"
pno=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick 2>&1)
[[ -d "$FIX/proj/node_modules" ]] && ! grep -q "^fzf" "$STUB_LOG" 2>/dev/null && grep -q "takes effect with --apply" <<< "$pno" \
  && ok "--pick without --apply: no fzf invoked, prints the note, deletes nothing (preview)" \
  || bad "--pick without --apply opened the picker or deleted/omitted the note"
rm -rf "$FIX"
# (f) typed deletion: a conda env is removed via 'conda env remove' (native), NOT raw rm of the dir
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/miniconda3/envs/foo/lib"; : > "$FIX/miniconda3/envs/foo/lib/x"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
grep -q "conda env remove -n foo" "$STUB_LOG" && [[ -d "$FIX/miniconda3/envs/foo" ]] \
  && ok "--pick typed deletion: conda env uses 'conda env remove' (not raw rm)" \
  || bad "--pick conda env was raw-rm'd instead of using the native uninstaller"
rm -rf "$FIX"
# (g) a path containing a space round-trips through the NUL-delimited picker
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/my proj/node_modules/x"; : > "$FIX/my proj/node_modules/x/f"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
[[ ! -d "$FIX/my proj/node_modules" ]] \
  && ok "--pick handles a path with a space (NUL round-trip)" \
  || bad "--pick failed on a path containing a space"
rm -rf "$FIX"
# (h) --pick is interactive-only: it must NOT run the Tier 1 auto-sweep (no brew/npm/yarn cleanup,
#     no sudo TM-snapshot prompt) before the picker. Abort the picker (fzf=exit 0) and assert no
#     package-manager stub was ever invoked.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\nexit 0' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
_mk_mixed "$FIX"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
! grep -qiE 'brew|npm|yarn|bun|tmutil|docker' "$STUB_LOG" 2>/dev/null \
  && ok "--pick is interactive-only: Tier 1 auto-sweep is skipped (no batch tool invoked)" \
  || bad "--pick ran the Tier 1 batch sweep (should run only the picker)"
rm -rf "$FIX"
# (i) a path containing a literal TAB is skipped from the picker (the TAB/newline-delimited record
#     would otherwise desync field-splitting). select-all must delete the normal item and leave the
#     tab-path item untouched, with no wrong deletion.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
_tab=$'\t'
mkdir -p "$FIX/normal/node_modules/y"; : > "$FIX/normal/node_modules/y/f"
mkdir -p "$FIX/tab${_tab}dir/node_modules/x"; : > "$FIX/tab${_tab}dir/node_modules/x/f"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
[[ ! -d "$FIX/normal/node_modules" && -d "$FIX/tab${_tab}dir/node_modules" ]] \
  && ok "--pick skips a TAB-in-path item safely (normal deleted, tab-path kept, no mis-map)" \
  || bad "--pick mishandled a TAB-in-path item"
rm -rf "$FIX"
# (j) typed deletion: uv python uses 'uv python uninstall <name>' (native), not raw rm. Stub uv
#     exits 0 without deleting → dir survives → proves the native branch (not _rm) ran.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/.local/share/uv/python/cpython-3.12.1-macos/bin"; : > "$FIX/.local/share/uv/python/cpython-3.12.1-macos/bin/python"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
grep -qF -- "uv python uninstall cpython-3.12.1-macos" "$STUB_LOG" && [[ -d "$FIX/.local/share/uv/python/cpython-3.12.1-macos" ]] \
  && ok "--pick typed deletion: uv python uses 'uv python uninstall' (native, not rm)" \
  || bad "--pick uv dispatch wrong (name derivation or not native)"
rm -rf "$FIX"
# (k) typed deletion: android system-image uses 'sdkmanager --uninstall system-images;api;tag;abi'.
#     This package string is built from 3 levels of path ancestry, the most fragile derivation.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a"; : > "$FIX/Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a/x"
HOME="$FIX" ANDROID_SDK_ROOT="$FIX/Library/Android/sdk" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
grep -qF -- "sdkmanager --uninstall system-images;android-34;google_apis;arm64-v8a" "$STUB_LOG" \
  && ok "--pick typed deletion: android builds the correct 'sdkmanager --uninstall' pkg string" \
  || bad "--pick android pkg derivation wrong (the 3-level :h/:t ancestry)"
rm -rf "$FIX"
# (l) typed deletion: rust uses 'cargo clean --manifest-path <proj>/Cargo.toml' (registered path is
#     <proj>/target, so the manifest must be one level up).
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/proj/target/debug"; : > "$FIX/proj/Cargo.toml"; : > "$FIX/proj/target/debug/x"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
grep -qF -- "cargo clean --manifest-path $FIX/proj/Cargo.toml" "$STUB_LOG" && [[ -d "$FIX/proj/target" ]] \
  && ok "--pick typed deletion: cargo uses 'cargo clean --manifest-path' (native, not rm)" \
  || bad "--pick cargo manifest derivation wrong"
rm -rf "$FIX"
# (m) THE IGNORE-LIST INVARIANT IN THE PICKER: an ignored env must be dropped at registration so it
#     never enters the picker and is never uninstalled, even when select-all marks everything. (This
#     is the regression test for the native-uninstaller ignore-bypass found in the 5th audit.)
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/miniconda3/envs/keepme/lib"; : > "$FIX/miniconda3/envs/keepme/lib/x"
mkdir -p "$FIX/.config/dehoard"; print -r -- "$FIX/miniconda3/envs/keepme" > "$FIX/.config/dehoard/ignore"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
{ ! grep -qF -- "conda env remove -n keepme" "$STUB_LOG" 2>/dev/null } && [[ -d "$FIX/miniconda3/envs/keepme" ]] \
  && ok "--pick honors the ignore list: an ignored env is dropped pre-picker (native bypass closed)" \
  || bad "--pick BYPASSED the ignore list: an ignored env was uninstalled!"
rm -rf "$FIX"
# (k) ignore covers DESCENDANTS: an always-skip on a directory must also drop paths inside it, so the
#     picker can never offer a child of an ignored dir. Regression for the real-machine find where an
#     ignored app dir's Cache subfolder was still offered.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/keepme/proj/node_modules/x"; : > "$FIX/keepme/proj/node_modules/x/f"   # INSIDE ignored dir
mkdir -p "$FIX/other/node_modules/x";       : > "$FIX/other/node_modules/x/f"          # not ignored
mkdir -p "$FIX/.config/dehoard"; print -r -- "$FIX/keepme" > "$FIX/.config/dehoard/ignore"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
[[ -d "$FIX/keepme/proj/node_modules" && ! -d "$FIX/other/node_modules" ]] \
  && ok "--pick: ignore covers a descendant of an ignored dir (child kept, non-ignored sibling deleted)" \
  || bad "--pick offered/deleted a path INSIDE an ignored directory (ignore must cover descendants)"
rm -rf "$FIX"
# (l) dedup across categories: a path found by two scanners (the Codex AI-cache rule AND the generic
#     >100MB sweep both see ~/.cache/codex-runtimes) is registered ONCE, so it is not shown/confirmed
#     under a second category. Regression for codex-runtimes appearing in both ai-cache and cache.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/.cache/codex-runtimes"
dd if=/dev/zero of="$FIX/.cache/codex-runtimes/blob" bs=1024 count=120000 2>/dev/null   # >100MB so the generic sweep also catches it
dd=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes 2>&1)
{ [[ ! -d "$FIX/.cache/codex-runtimes" ]] && ! grep -q "▸ cache " <<< "$dd" } \
  && ok "--pick dedups across categories: a twice-found path is registered once (no duplicate 'cache' category)" \
  || bad "--pick registered one path under two categories (codex-runtimes in both ai-cache and cache)"
rm -rf "$FIX"

# 5C, --report "Last --apply run" must show the NEWEST log, not the oldest (regression: the glob was
#      (N.Om) = oldest-first, so [1] was the oldest; fixed to (N.om) = newest-first).
FIX=$(mktemp -d); mkdir -p "$FIX/.cache/dehoard"
print -r -- $'4\t/x' > "$FIX/.cache/dehoard/run-20260101-000000.log"
print -r -- $'9\t/y' > "$FIX/.cache/dehoard/run-20260601-000000.log"
touch -t 202601010000 "$FIX/.cache/dehoard/run-20260101-000000.log"
touch -t 202606010000 "$FIX/.cache/dehoard/run-20260601-000000.log"   # newer mtime → should be reported
rep=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --report 2>/dev/null)
echo "$rep" | grep -q "Last --apply run: 20260601-000000" \
  && ok "--report 'Last --apply run' shows the newest log (om glob), not the oldest" \
  || bad "--report 'Last --apply run' reported the wrong (oldest) log"
rm -rf "$FIX"
# 5D, the one sudo Apple-cache rm (bypasses _rm) is SKIPPED when \$BASE is not a /var/folders root.
#      With TMPDIR=/ → BASE=/ the explicit guard must fire instead of handing "//C/..." to sudo rm.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
gout=$(HOME="$FIX" TMPDIR=/ PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" zsh "$SCRIPT" --deep --apply --yes 2>&1)
echo "$gout" | grep -q "skipped system Apple caches" \
  && ok "--deep: sudo Apple-cache rm is guarded off when \$BASE is not under /var/folders" \
  || bad "--deep: the sudo Apple-cache \$BASE guard did not fire"
rm -rf "$FIX"

# 5E, --pick must run ONLY the picker: the excluded sections (macOS junk, IPython, stray .pyc, LaTeX)
#      must NOT delete inline during the scan, and no internal var may leak to stdout (the _sub=log bug).
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/proj/node_modules/x"; : > "$FIX/proj/node_modules/x/f"          # registered → picker → deleted
: > "$FIX/.DS_Store"                                                            # excluded → must SURVIVE
mkdir -p "$FIX/.ipython/profile_default"; : > "$FIX/.ipython/profile_default/history.sqlite"  # excluded → SURVIVE
eout=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes 2>&1)
[[ ! -d "$FIX/proj/node_modules" && -f "$FIX/.DS_Store" && -f "$FIX/.ipython/profile_default/history.sqlite" ]] \
  && { ! grep -q '_sub=' <<< "$eout" } \
  && ok "--pick runs only the picker: excluded sections skip inline deletion + no variable leak" \
  || bad "--pick deleted an excluded section inline, or leaked a variable to stdout"
rm -rf "$FIX"

# 5F, the per-category summary: --pick prints a category tally (count + size) before the picker so
#      users can reason in groups (then type a category + Ctrl-A to take it). fzf=exit 0 → abort.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\nexit 0' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/a/node_modules/x" "$FIX/b/node_modules/y"; : > "$FIX/a/node_modules/x/f"; : > "$FIX/b/node_modules/y/f"
mkdir -p "$FIX/p1/.venv/bin"; echo "home=/x" > "$FIX/p1/.venv/pyvenv.cfg"
so=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes 2>&1)
{ echo "$so" | grep -q "Reclaimable by category" } && { echo "$so" | grep -qE 'node_modules +2' } \
  && { echo "$so" | grep -qE 'venv +1' } && [[ -d "$FIX/a/node_modules" && -d "$FIX/p1/.venv" ]] \
  && ok "--pick prints a per-category summary (counts per category) before the picker" \
  || bad "--pick category summary missing or has wrong counts"
rm -rf "$FIX"

# 5G, per-category pickers: --pick opens ONE picker per category (biggest first), not a single combined
#      list. Assert the per-category headers (▸ <category>) appear and each category deletes its own.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/a/node_modules/x"; : > "$FIX/a/node_modules/x/f"
mkdir -p "$FIX/p1/.venv/bin"; echo "home=/x" > "$FIX/p1/.venv/pyvenv.cfg"
go=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes 2>&1)
{ echo "$go" | grep -q '▸ node_modules' } && { echo "$go" | grep -q '▸ venv' } \
  && [[ ! -d "$FIX/a/node_modules" && ! -d "$FIX/p1/.venv" ]] \
  && ok "--pick opens one picker per category (▸ header per category; each deletes its own)" \
  || bad "--pick did not open per-category pickers / did not delete per category"
rm -rf "$FIX"

# 5H, freed-space honesty: "Storage freed" must come from dehoard's own deletion tally, not a df delta.
#      (a) Esc-all (fzf=exit 0) deletes nothing → "Nothing deleted.", never a positive freed figure
#          (the old df-diff bug reported ambient disk churn even when nothing was removed).
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\nexit 0' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/a/node_modules/x"; : > "$FIX/a/node_modules/x/f"
fh=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes 2>&1)
{ echo "$fh" | grep -q 'Nothing deleted' } && { echo "$fh" | grep -qvE 'Storage freed: [1-9]' } \
  && [[ -d "$FIX/a/node_modules" ]] \
  && ok "--pick freed-space: deleting nothing reports 'Nothing deleted' (no phantom df reclaim)" \
  || bad "--pick freed-space reported reclaim despite deleting nothing"
rm -rf "$FIX"
#      (b) a real delete reports a freed figure derived from the actual size removed.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/a/node_modules/x"; dd if=/dev/zero of="$FIX/a/node_modules/x/blob" bs=1024 count=2048 2>/dev/null
fr=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes 2>&1)
{ echo "$fr" | grep -qE 'Storage freed: [1-9]' } && [[ ! -d "$FIX/a/node_modules" ]] \
  && ok "--pick freed-space: a real delete reports a freed figure from the actual size removed" \
  || bad "--pick freed-space did not report the reclaimed size after a real delete"
rm -rf "$FIX"

# 5I, freed-space honesty in the NON-pick --scan path: native uninstallers (conda/uv/android/cargo)
#      and ollama bypass _rm, so they must feed the same _FREED_KB tally. A no-fzf `--scan --apply`
#      that removes a conda env must report the real size, not "Nothing deleted". Regression guard:
#      the --pick path was fixed first and this twin path was initially missed.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
mkdir -p "$FIX/miniconda3/envs/bigenv/lib"; dd if=/dev/zero of="$FIX/miniconda3/envs/bigenv/lib/blob" bs=1024 count=2048 2>/dev/null
fn=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" \
  zsh "$SCRIPT" --scan --apply --yes 2>&1)
{ echo "$fn" | grep -qE 'Storage freed: [1-9]' } && grep -q 'conda env remove -n bigenv' "$STUB_LOG" \
  && ok "freed-space: non-pick --scan native uninstall (conda) feeds the freed tally" \
  || bad "freed-space: a conda env removed via native uninstaller in non-pick --scan was not counted"
rm -rf "$FIX"

# 5J, DEHOARD_APPLY_DEFAULT is COMPARED, never executed. A non-"true" value must neither run as a
#      command nor flip APPLY on. (zsh does not word-split, but a bare command name would still run
#      under the old `${VAR} && APPLY=true`.) A stub named `pwn` touches a sentinel if executed.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ntouch "$PWN_SENTINEL"' > "$STUBDIR/pwn"; chmod +x "$STUBDIR/pwn"
sent="$FIX/PWNED"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" PWN_SENTINEL="$sent" DEHOARD_APPLY_DEFAULT=pwn \
  zsh "$SCRIPT" >/dev/null 2>&1
[[ ! -e "$sent" ]] \
  && ok "DEHOARD_APPLY_DEFAULT is compared, not executed (a command-name value never runs)" \
  || bad "DEHOARD_APPLY_DEFAULT was executed as a command (string-compare regression)"
rm -rf "$FIX"
# (b) the legit opt-in still works: =true (no --apply) must enable apply and delete a Tier-1 cache
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
mkdir -p "$FIX/.npm/_npx"; : > "$FIX/.npm/_npx/x"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_APPLY_DEFAULT=true \
  zsh "$SCRIPT" --yes >/dev/null 2>&1
[[ ! -e "$FIX/.npm/_npx/x" ]] \
  && ok "DEHOARD_APPLY_DEFAULT=true still enables apply (opt-in preserved, not over-corrected)" \
  || bad "DEHOARD_APPLY_DEFAULT=true no longer enables apply"
rm -rf "$FIX"

# 5K, LM Studio .gguf deletion now ROUTES THROUGH _rm (was a `find -delete` bypass): it must be
#      logged to the run log and honor the ignore list. (a) deleted + recorded; (b) ignored survives.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
mkdir -p "$FIX/.lmstudio/models/pub"; dd if=/dev/zero of="$FIX/.lmstudio/models/pub/m.gguf" bs=1024 count=64 2>/dev/null
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" zsh "$SCRIPT" --models --apply --yes >/dev/null 2>&1
logf=("$FIX"/.cache/dehoard/run-*.log(N))
if [[ ! -e "$FIX/.lmstudio/models/pub/m.gguf" ]] && (( ${#logf} )) && grep -q "m.gguf" "${logf[1]}"; then
  ok "LM Studio .gguf deleted via _rm and recorded in the run log (no longer a bypass)"
else
  bad "LM Studio .gguf not routed through _rm (absent from run log) or not deleted"
fi
rm -rf "$FIX"
# (b) an ignore-listed .gguf survives, proving the route is now ignore-aware
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
mkdir -p "$FIX/.lmstudio/models/keep" "$FIX/.lmstudio/models/go" "$FIX/.config/dehoard"
: > "$FIX/.lmstudio/models/keep/keep.gguf"; : > "$FIX/.lmstudio/models/go/go.gguf"
print -r -- "$FIX/.lmstudio/models/keep/*" > "$FIX/.config/dehoard/ignore"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" zsh "$SCRIPT" --models --apply --yes >/dev/null 2>&1
[[ -e "$FIX/.lmstudio/models/keep/keep.gguf" && ! -e "$FIX/.lmstudio/models/go/go.gguf" ]] \
  && ok "LM Studio .gguf on the ignore list survives (route is ignore-aware now)" \
  || bad "ignore list NOT honored for LM Studio .gguf (route still bypasses _rm's ignore check)"
rm -rf "$FIX"

# 5L, ignore list migrates from the old ~/.cache location to ~/.config (it is config, not cache).
FIX=$(mktemp -d); mkdir -p "$FIX/.cache/dehoard"; print -r -- "$FIX/keepsafe" > "$FIX/.cache/dehoard/ignore"
HOME="$FIX" zsh "$SCRIPT" --list-ignored >/dev/null 2>&1
[[ -f "$FIX/.config/dehoard/ignore" && ! -f "$FIX/.cache/dehoard/ignore" ]] \
  && grep -qxF "$FIX/keepsafe" "$FIX/.config/dehoard/ignore" \
  && ok "ignore list migrates from ~/.cache to ~/.config on next run (config, not cache)" \
  || bad "ignore-list migration to ~/.config failed"
rm -rf "$FIX"

# 5M, --uninstall (apt-remove semantics): removes logs + script, but KEEPS the user-authored ignore
# list; --purge also removes it; a non-standard / symlinked script copy is never deleted.
# (a) non-standard copy KEPT (hint) + logs removed + ignore list KEPT and announced
FIX=$(mktemp -d)
mkdir -p "$FIX/.cache/dehoard" "$FIX/.config/dehoard"; : > "$FIX/.cache/dehoard/run-x.log"
print -r -- "$FIX/keepsafe" > "$FIX/.config/dehoard/ignore"
uo=$(HOME="$FIX" zsh "$SCRIPT" --uninstall --yes 2>&1)
{ [[ ! -d "$FIX/.cache/dehoard" && -f "$FIX/.config/dehoard/ignore" && -f "$SCRIPT" ]] \
  && grep -q "kept your ignore list" <<< "$uo" && grep -q "remove it yourself\|remove it manually" <<< "$uo" } \
  && ok "--uninstall: logs removed, ignore list KEPT + announced, non-standard script copy kept" \
  || bad "--uninstall: wrong removal set (should keep ignore list + non-standard script copy)"
rm -rf "$FIX"
# (b) --purge ALSO removes the ignore list, echoing its contents first
FIX=$(mktemp -d)
mkdir -p "$FIX/.cache/dehoard" "$FIX/.config/dehoard"; : > "$FIX/.cache/dehoard/run-x.log"
print -r -- "$FIX/keepsafe" > "$FIX/.config/dehoard/ignore"
po=$(HOME="$FIX" zsh "$SCRIPT" --purge --yes 2>&1)
{ [[ ! -d "$FIX/.cache/dehoard" && ! -d "$FIX/.config/dehoard" ]] && grep -q "keepsafe" <<< "$po" } \
  && ok "--purge: removes the ignore list too, after echoing its contents" \
  || bad "--purge: did not remove the ignore list or did not echo it first"
rm -rf "$FIX"
# (c) standard ~/.local/bin install: removes the script + logs, keeps ignore list
FIX=$(mktemp -d)
mkdir -p "$FIX/.local/bin" "$FIX/.cache/dehoard" "$FIX/.config/dehoard"; : > "$FIX/.cache/dehoard/run-x.log"
print -r -- "$FIX/keepsafe" > "$FIX/.config/dehoard/ignore"
cp "$SCRIPT" "$FIX/.local/bin/dehoard"; chmod +x "$FIX/.local/bin/dehoard"
HOME="$FIX" zsh "$FIX/.local/bin/dehoard" --uninstall --yes >/dev/null 2>&1
[[ ! -e "$FIX/.local/bin/dehoard" && ! -d "$FIX/.cache/dehoard" && -f "$FIX/.config/dehoard/ignore" ]] \
  && ok "--uninstall: standard install removes script + logs, keeps the ignore list" \
  || bad "--uninstall: standard install removal set wrong"
rm -rf "$FIX"
# (d) symlinked install is NOT deleted (rustup lesson): refuse + print manual hint
FIX=$(mktemp -d)
mkdir -p "$FIX/.local/bin" "$FIX/realdir" "$FIX/.cache/dehoard"; : > "$FIX/.cache/dehoard/run-x.log"
cp "$SCRIPT" "$FIX/realdir/dehoard"; chmod +x "$FIX/realdir/dehoard"
ln -s "$FIX/realdir/dehoard" "$FIX/.local/bin/dehoard"
so=$(HOME="$FIX" zsh "$FIX/.local/bin/dehoard" --uninstall --yes 2>&1)
{ [[ -e "$FIX/.local/bin/dehoard" && -f "$FIX/realdir/dehoard" ]] && grep -q "remove it yourself\|remove it manually" <<< "$so" } \
  && ok "--uninstall: a symlinked install is refused (kept) with a manual hint (rustup lesson)" \
  || bad "--uninstall: deleted a symlinked install (must refuse and only hint)"
rm -rf "$FIX"
# (e) abort (no --yes, no tty) removes NOTHING
FIX=$(mktemp -d); mkdir -p "$FIX/.cache/dehoard"; : > "$FIX/.cache/dehoard/run-x.log"
HOME="$FIX" zsh "$SCRIPT" --uninstall >/dev/null 2>&1 < /dev/null
[[ -d "$FIX/.cache/dehoard" ]] \
  && ok "--uninstall: declined/non-interactive confirm removes nothing" \
  || bad "--uninstall: removed data without a yes (must default to keep)"
rm -rf "$FIX"
# (f) --uninstall --dry-run previews and deletes nothing
FIX=$(mktemp -d); mkdir -p "$FIX/.cache/dehoard"; : > "$FIX/.cache/dehoard/run-x.log"
do=$(HOME="$FIX" zsh "$SCRIPT" --uninstall --dry-run 2>&1)
{ [[ -d "$FIX/.cache/dehoard" ]] && grep -q "preview" <<< "$do" } \
  && ok "--uninstall --dry-run previews what it would remove and deletes nothing" \
  || bad "--uninstall --dry-run deleted something or printed no preview"
rm -rf "$FIX"

# 5N, XDG edge: if XDG_CACHE_HOME == XDG_CONFIG_HOME the logs and the ignore list share one dir.
# --uninstall must still KEEP the ignore file (remove only the logs); --purge removes it.
FIX=$(mktemp -d); SH="$FIX/shared/dehoard"; mkdir -p "$SH"
: > "$SH/run-x.log"; print -r -- "$FIX/keepsafe" > "$SH/ignore"
uoc=$(HOME="$FIX" XDG_CACHE_HOME="$FIX/shared" XDG_CONFIG_HOME="$FIX/shared" zsh "$SCRIPT" --uninstall --yes 2>&1)
[[ -f "$SH/ignore" && ! -e "$SH/run-x.log" ]] \
  && ok "--uninstall (XDG cache==config): keeps the ignore list, removes only the logs" \
  || bad "--uninstall (XDG cache==config): deleted the ignore list or kept the logs"
# Preview honesty: the "Will remove:" line must show the narrowed run-*.log target, not the whole dir.
grep -q "run-\*.log" <<< "$uoc" \
  && ok "--uninstall (XDG cache==config): preview names the narrowed run-*.log target, not the whole dir" \
  || bad "--uninstall (XDG cache==config): preview over-claims the whole dir while keeping the ignore list"
HOME="$FIX" XDG_CACHE_HOME="$FIX/shared" XDG_CONFIG_HOME="$FIX/shared" zsh "$SCRIPT" --purge --yes >/dev/null 2>&1
[[ ! -f "$SH/ignore" ]] \
  && ok "--purge (XDG cache==config): removes the shared ignore list too" \
  || bad "--purge (XDG cache==config): left the ignore list behind"
rm -rf "$FIX"

# 5O, uninstall edge branches the earlier tests skipped (all reachable for a fresh curl|zsh user).
# (a) "Nothing to remove": no cache dir, no ignore, non-standard script copy -> prints it, removes nothing
FIX=$(mktemp -d)
no=$(HOME="$FIX" zsh "$SCRIPT" --uninstall --yes 2>&1)
{ grep -q "Nothing to remove" <<< "$no" && [[ ! -d "$FIX/.cache/dehoard" && ! -d "$FIX/.config/dehoard" ]] } \
  && ok "--uninstall: 'Nothing to remove' when there is no footprint (fresh user), creates/deletes nothing" \
  || bad "--uninstall: empty-footprint case did not report 'Nothing to remove' cleanly"
rm -rf "$FIX"
# (b) curl|zsh: $0 is not a real file -> only the cache dir goes, NO spurious "remove it yourself" warning
FIX=$(mktemp -d); mkdir -p "$FIX/.cache/dehoard"; : > "$FIX/.cache/dehoard/run-x.log"
co=$(HOME="$FIX" zsh -c "$(cat "$SCRIPT")" dehoard --uninstall --yes 2>&1)
{ [[ ! -d "$FIX/.cache/dehoard" ]] && ! grep -qi "remove it yourself\|remove it manually" <<< "$co" } \
  && ok "--uninstall via curl|zsh (\$0 not a file): removes logs, no spurious script-removal hint" \
  || bad "--uninstall via curl|zsh: kept the logs or printed a spurious script hint"
rm -rf "$FIX"
# (c) no ignore file present: no "kept your ignore list" line on --uninstall, no "contents" echo on --purge
FIX=$(mktemp -d); mkdir -p "$FIX/.cache/dehoard"; : > "$FIX/.cache/dehoard/run-x.log"
io=$(HOME="$FIX" zsh "$SCRIPT" --uninstall --yes 2>&1)
! grep -qi "kept your ignore list" <<< "$io" \
  && ok "--uninstall with no ignore file: no spurious 'kept your ignore list' line" \
  || bad "--uninstall claimed to keep an ignore list that does not exist"
FIX2=$(mktemp -d); mkdir -p "$FIX2/.cache/dehoard"; : > "$FIX2/.cache/dehoard/run-x.log"
po=$(HOME="$FIX2" zsh "$SCRIPT" --purge --yes 2>&1)
{ grep -q "dehoard uninstalled" <<< "$po" && ! grep -qi "ignore list contents" <<< "$po" } \
  && ok "--purge with no ignore file: succeeds, no 'ignore list contents' echo" \
  || bad "--purge with no ignore file: errored or echoed nonexistent contents"
rm -rf "$FIX" "$FIX2"
# (d) --report log glob honors XDG_CACHE_HOME (not a literal ~/.cache): the 'Last --apply run' line finds it
FIX=$(mktemp -d); XC="$FIX/xc/dehoard"; mkdir -p "$XC"
print -r -- $'4\t/x' > "$XC/run-20260101-000000.log"; touch -t 202601010000 "$XC/run-20260101-000000.log"
ro=$(HOME="$FIX" XDG_CACHE_HOME="$FIX/xc" zsh "$SCRIPT" --report 2>/dev/null)
grep -q "Last --apply run" <<< "$ro" \
  && ok "--report log glob honors XDG_CACHE_HOME (finds logs outside ~/.cache)" \
  || bad "--report missed logs under XDG_CACHE_HOME (glob still hardcoded ~/.cache)"
rm -rf "$FIX"

# 5P, security hardening (v0.2.5).
# (a) #1 the sudo Apple-cache rm must refuse a `..`-laced TMPDIR that resolves OUTSIDE /var/folders
#     (canonicalized BASE). The guard must fire on the resolved path, not the literal prefix.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
ev=$(HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" TMPDIR="/var/folders/../../etc/T/" \
  zsh "$SCRIPT" --deep --apply --yes 2>&1)
{ ! grep -qE 'rm .*-rf .*/etc/' "$STUB_LOG" 2>/dev/null && ! grep -qE 'sudo .*etc' "$STUB_LOG" 2>/dev/null } \
  && ok "#1 sudo guard: a '..'-laced TMPDIR resolving outside /var/folders is refused (no sudo rm of /etc)" \
  || bad "#1 sudo guard: a '..' TMPDIR escaped the guard and reached sudo rm outside /var/folders"
rm -rf "$FIX"
# (b) #2 a discovered conda env named with a leading dash is NOT passed to the native uninstaller as a
#     flag; it is removed via the safe path delete instead. A normal sibling still goes native.
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; STUB_LOG="$FIX/stub.log"; make_stubs "$STUBDIR"
print -r -- $'#!/bin/sh\ncat' > "$STUBDIR/fzf"; chmod +x "$STUBDIR/fzf"
mkdir -p "$FIX/miniconda3/envs/--evil/lib"; : > "$FIX/miniconda3/envs/--evil/lib/x"
mkdir -p "$FIX/miniconda3/envs/good/lib";   : > "$FIX/miniconda3/envs/good/lib/x"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
{ ! grep -qF -- "conda env remove -n --evil" "$STUB_LOG" 2>/dev/null && [[ ! -d "$FIX/miniconda3/envs/--evil" ]] \
  && grep -qF -- "conda env remove -n good" "$STUB_LOG" 2>/dev/null } \
  && ok "#2 dash-leading env name is path-deleted, never passed as a flag; normal sibling goes native" \
  || bad "#2 a dash-leading conda env name reached the native uninstaller (argument-injection guard missing)"
rm -rf "$FIX"
# (c) #3 a model/dir name with a control char still yields valid JSON
if command -v python3 >/dev/null 2>&1; then
  FIX=$(mktemp -d); bell=$(printf 'm\ax')          # BEL inside the name
  mkdir -p "$FIX/.ollama/models/manifests/registry.ollama.ai/library/$bell/7b" 2>/dev/null
  : > "$FIX/.ollama/models/manifests/registry.ollama.ai/library/$bell/7b/x" 2>/dev/null
  oj=$(HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --json 2>/dev/null)
  print -r -- "$oj" | python3 -m json.tool >/dev/null 2>&1 \
    && ok "#3 --json stays valid JSON when a model name contains a control character" \
    || bad "#3 --json broke (invalid JSON) on a control character in a name"
  rm -rf "$FIX"
else
  ok "(skipped #3 control-char JSON test: python3 unavailable)"
fi
# (d) #4 _rm refuses a target containing '..' traversal (defense-in-depth; extraction unit test)
FIX=$(mktemp -d); mkdir -p "$FIX/sub"; echo data > "$FIX/sub/victim"
out=$(HOME="$FIX" PATH="$SAFE_PATH" zsh -c '
  DRY_RUN=false; LOGFILE=""
  c_warn(){ printf "%s" "$*"; }; c_dim(){ printf "%s" "$*"; }
  '"$(sed -n "/^_rm() {/,/^}/p" "$SCRIPT")"'
  _rm "'"$FIX"'/sub/../sub/victim" 2>&1; echo "rc=$?"
')
[[ "$out" == *"traversal"* && "$out" == *"rc=1"* && -f "$FIX/sub/victim" ]] \
  && ok "#4 _rm refuses a '..'-traversal target (victim survives)" \
  || bad "#4 _rm did NOT refuse a '..' target: [$out]"
rm -rf "$FIX"

# 5Q, shell-env hardening (v0.2.6): a hostile ~/.zshenv (KSH_ARRAYS / SH_WORD_SPLIT) must NOT corrupt
# output or silently skip paths, because dehoard runs `emulate zsh`. ZDOTDIR points zsh at a fixture
# .zshenv so we never touch the real one.
# (a) KSH_ARRAYS in .zshenv: --json must stay valid JSON (array indexing in the emit can't break).
if command -v python3 >/dev/null 2>&1; then
  FIX=$(mktemp -d); mkdir -p "$FIX/zdot"
  print -r -- 'setopt ksh_arrays sh_word_split' > "$FIX/zdot/.zshenv"
  mkdir -p "$FIX/.ollama/models/manifests/registry.ollama.ai/library/llama3/8b"
  : > "$FIX/.ollama/models/manifests/registry.ollama.ai/library/llama3/8b/x"
  zj=$(HOME="$FIX" ZDOTDIR="$FIX/zdot" PATH="$SAFE_PATH" zsh "$SCRIPT" --json 2>/dev/null)
  print -r -- "$zj" | python3 -m json.tool >/dev/null 2>&1 \
    && ok "shell-env: --json stays valid JSON even with KSH_ARRAYS/SH_WORD_SPLIT set in .zshenv" \
    || bad "shell-env: a hostile .zshenv corrupted --json (emulate guard missing/ineffective)"
  rm -rf "$FIX"
else
  ok "(skipped shell-env JSON test: python3 unavailable)"
fi
# (b) SH_WORD_SPLIT in .zshenv: a space-in-path project is still detected (not word-split + skipped).
FIX=$(mktemp -d); STUBDIR="$FIX/.stubs"; make_stubs "$STUBDIR"; mkdir -p "$FIX/zdot"
print -r -- 'setopt ksh_arrays sh_word_split' > "$FIX/zdot/.zshenv"
mkdir -p "$FIX/my proj/node_modules/x"; : > "$FIX/my proj/node_modules/x/f"
so=$(HOME="$FIX" ZDOTDIR="$FIX/zdot" PATH="$STUBDIR:$SAFE_PATH" zsh "$SCRIPT" --scan --dry-run 2>&1)
grep -qF "my proj/node_modules" <<< "$so" \
  && ok "shell-env: a space-in-path project is still detected under SH_WORD_SPLIT (emulate guard holds)" \
  || bad "shell-env: SH_WORD_SPLIT caused a space-path project to be silently skipped"
rm -rf "$FIX"

# 6, syntax
zsh -n "$SCRIPT" && ok "zsh -n syntax clean" || bad "syntax error"

# Hermeticity, asserted as a property rather than per call site: after the whole suite has run,
# every canary planted in the REAL environment must still exist. A suite that deletes the
# developer's or CI's actual files fails here regardless of which test did it.
if [[ -f "$_CANARY_TMP/probe" ]]; then
  ok "hermetic: the suite deleted nothing from the real TMPDIR (canaries intact)"
else
  bad "hermetic: the suite DELETED real files from $_REAL_TMPDIR — a test escaped its fixture"
fi
[[ -f "$_CANARY_REAL_HOME_MARK" ]] \
  && ok "hermetic: the suite deleted nothing from the real \$HOME (canary intact)" \
  || bad "hermetic: the suite DELETED a file in the real \$HOME"
rm -rf "$_CANARY_TMP" "$_CANARY_REAL_HOME_MARK"

echo ""
# The --apply stress test runs a REAL deletion against a fixture holding every category at once,
# including guarded items placed inside directories Tier 1 actually removes. It found two holes the
# isolated unit tests could not: both guards checked only the target path, so a live database or a
# partial download NESTED inside a deleted directory was invisible.
if zsh "${0:A:h}/stress-apply.zsh" "$SCRIPT" > /tmp/dehoard-stress.$$ 2>&1; then
  ok "--apply stress test: real deletion, every category, guards in harm's way"
else
  bad "--apply stress test failed: $(grep -c '✗' /tmp/dehoard-stress.$$) assertion(s)"
  grep '✗' /tmp/dehoard-stress.$$ | head -3
fi
rm -f /tmp/dehoard-stress.$$

print -P "%F{cyan}dehoard tests: ${PASS} passed, ${FAIL} failed%f"
(( FAIL == 0 ))
