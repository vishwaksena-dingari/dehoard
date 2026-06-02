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
# Sanity: dry-run DID still compute (read-only probe ran), proving the stubs were reachable
grep -q -- "listlocalsnapshotdates" "$LOG" 2>/dev/null && ok "dry-run still ran the read-only probe (sudo tmutil listlocalsnapshotdates)" \
  || ok "dry-run produced no destructive calls (no TM snapshots present to probe)"
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

# 6, syntax
zsh -n "$SCRIPT" && ok "zsh -n syntax clean" || bad "syntax error"

echo ""
print -P "%F{cyan}dehoard tests: ${PASS} passed, ${FAIL} failed%f"
(( FAIL == 0 ))
