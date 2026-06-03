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

PASS=0 FAIL=0
ok()  { print -P "  %F{green}✓%f $1"; (( ++PASS )); return 0; }
bad() { print -P "  %F{red}✗ $1%f";   (( ++FAIL )); return 0; }

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
run() { HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" "$@" >/dev/null 2>&1; }

# Stub harness: fake every external tool dehoard shells out to. Each stub logs
# "<name> <args>" to $STUB_LOG and exits 0 (so e.g. `docker info` "succeeds").
# Tests run dehoard with PATH="$STUBDIR:$SAFE_PATH" so these intercept the real
# tools, letting us assert the DESTRUCTIVE paths (brew/npm/docker/sudo-tmutil)
# without touching the real machine. sudo is stubbed too, so --deep can't mutate
# the system or hang on a password prompt.
make_stubs() {  # $1 = dir
  local d="$1" c; mkdir -p "$d"
  for c in brew npm pnpm yarn bun uv trunk pip pip3 docker ollama git xcrun sudo tmutil conda sdkmanager cargo gradle mvn; do
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
[[ "$out" == *"refusing path outside safe roots"* && "$out" == *"rc=1"* ]] \
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
mkdir -p "$FIX/.cache/huggingface" "$FIX/.cache/dehoard"
dd if=/dev/zero of="$FIX/.cache/huggingface/x" bs=1024 count=200000 2>/dev/null  # 200 MB
# Pre-populate ignore list, no trailing slash (matches _ask normalization)
printf '%s\n' "$FIX/.cache/huggingface" > "$FIX/.cache/dehoard/ignore"
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
[[ ! -f "$FIX/.cache/dehoard/ignore" ]] && ok "--reset-ignore cleared the ignore file" \
                                         || bad "--reset-ignore did not clear ignore file"
rm -rf "$FIX"

# 5g, --report and bare preview (no --apply) never write to the ignore list
FIX=$(mktemp -d)
mkdir -p "$FIX/.cache/test"
dd if=/dev/zero of="$FIX/.cache/test/x" bs=1024 count=200000 2>/dev/null  # 200 MB
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --report >/dev/null 2>&1
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" >/dev/null 2>&1  # bare preview
[[ ! -f "$FIX/.cache/dehoard/ignore" ]] \
  && ok "--report and bare preview never create ignore file" \
  || bad "--report or bare preview wrote to ignore file (should not)"
rm -rf "$FIX"

# 5h, --unignore removes one path, leaves others intact; empty file is deleted
FIX=$(mktemp -d)
mkdir -p "$FIX/.cache/dehoard"
printf '%s\n%s\n' "$FIX/.cache/huggingface" "$FIX/.cache/torch" \
  > "$FIX/.cache/dehoard/ignore"                                           # two entries
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --unignore "$FIX/.cache/huggingface" >/dev/null 2>&1
[[ -f "$FIX/.cache/dehoard/ignore" ]] && \
  ! grep -qxF "$FIX/.cache/huggingface" "$FIX/.cache/dehoard/ignore" && \
    grep -qxF "$FIX/.cache/torch" "$FIX/.cache/dehoard/ignore" \
  && ok "--unignore removes one path, keeps the other" \
  || bad "--unignore failed: wrong file state"
# removing the last entry cleans up the file
HOME="$FIX" PATH="$SAFE_PATH" zsh "$SCRIPT" --unignore "$FIX/.cache/torch" >/dev/null 2>&1
[[ ! -f "$FIX/.cache/dehoard/ignore" ]] \
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
  rm -rf "$FIX"
else
  ok "(skipped --json test: python3 not available to validate)"
fi

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
( sleep 40; kill -9 $run_pid 2>/dev/null ) &     # safety net: a broken guard must not hang CI
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
mkdir -p "$FIX/.cache/dehoard"
print -r -- "$FIX/Library/Caches/node-*" > "$FIX/.cache/dehoard/ignore"   # a GLOB ignore entry
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
mkdir -p "$FIX/.cache/dehoard"; print -r -- "$FIX/miniconda3/envs/keepme" > "$FIX/.cache/dehoard/ignore"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" DEHOARD_FORCE_PICKER=1 \
  zsh "$SCRIPT" --scan --pick --apply --yes >/dev/null 2>&1
{ ! grep -qF -- "conda env remove -n keepme" "$STUB_LOG" 2>/dev/null } && [[ -d "$FIX/miniconda3/envs/keepme" ]] \
  && ok "--pick honors the ignore list: an ignored env is dropped pre-picker (native bypass closed)" \
  || bad "--pick BYPASSED the ignore list: an ignored env was uninstalled!"
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
mkdir -p "$FIX/.lmstudio/models/keep" "$FIX/.lmstudio/models/go" "$FIX/.cache/dehoard"
: > "$FIX/.lmstudio/models/keep/keep.gguf"; : > "$FIX/.lmstudio/models/go/go.gguf"
print -r -- "$FIX/.lmstudio/models/keep/*" > "$FIX/.cache/dehoard/ignore"
HOME="$FIX" PATH="$STUBDIR:$SAFE_PATH" STUB_LOG="$STUB_LOG" zsh "$SCRIPT" --models --apply --yes >/dev/null 2>&1
[[ -e "$FIX/.lmstudio/models/keep/keep.gguf" && ! -e "$FIX/.lmstudio/models/go/go.gguf" ]] \
  && ok "LM Studio .gguf on the ignore list survives (route is ignore-aware now)" \
  || bad "ignore list NOT honored for LM Studio .gguf (route still bypasses _rm's ignore check)"
rm -rf "$FIX"

# 6, syntax
zsh -n "$SCRIPT" && ok "zsh -n syntax clean" || bad "syntax error"

echo ""
print -P "%F{cyan}dehoard tests: ${PASS} passed, ${FAIL} failed%f"
(( FAIL == 0 ))
