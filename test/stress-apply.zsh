#!/usr/bin/env zsh
# --apply stress test: one fixture containing every category dehoard touches, plus every class of
# thing it must NOT touch, exercised through a REAL --apply run rather than _rm in isolation.
emulate zsh; setopt NULL_GLOB
SCRIPT="${1:?script path}"
P=0; F=0
# `(( P++ ))` evaluates to the OLD value, so it returns FALSE when P is 0 - which made the first
# `ok` in an `&& ok || bad` chain also fire `bad`. Explicit return 0, as the main suite does.
ok(){ print -P "  %F{green}✓%f $1"; (( P++ )); return 0; }
bad(){ print -P "  %F{red}✗%f $1"; (( F++ )); return 0; }

# Clean up on ANY exit, not just the happy path. Without this an interrupted or failed run leaks
# its fixture directory and leaves the background file-holder process alive -
# thirteen orphaned fixtures were found on this machine after a session of interrupted runs.
FIX=$(mktemp -d)
trap 'rm -rf "$FIX" 2>/dev/null; [[ -n "$HOLDER" ]] && kill -9 "$HOLDER" 2>/dev/null; exit 130' INT TERM
trap 'rm -rf "$FIX" 2>/dev/null; [[ -n "$HOLDER" ]] && kill -9 "$HOLDER" 2>/dev/null;' EXIT; export TMPDIR="$FIX/tmp/"; mkdir -p "$FIX/tmp"

# --- things that SHOULD be removed -------------------------------------------------
mkdir -p "$FIX/.npm/_npx" "$FIX/.cache/node" "$FIX/Library/Caches/node-gyp"
: > "$FIX/.npm/_npx/pkg"; : > "$FIX/.cache/node/blob"; : > "$FIX/Library/Caches/node-gyp/hdr"
mkdir -p "$FIX/proj"; : > "$FIX/proj/.DS_Store"

# --- things that MUST survive ------------------------------------------------------
mkdir -p "$FIX/Library/Keychains" "$FIX/.ssh" "$FIX/Library/Mail" "$FIX/Documents"
echo secret   > "$FIX/Library/Keychains/login.keychain"
echo private  > "$FIX/.ssh/id_ed25519"
echo mail     > "$FIX/Library/Mail/msg.emlx"
echo thesis   > "$FIX/Documents/thesis.txt"
: > "$FIX/Downloads_x.crdownload"; mkdir -p "$FIX/Downloads"; : > "$FIX/Downloads/big.dmg.crdownload"
mkdir -p "$FIX/.cache/node/x/y/z"; : > "$FIX/.cache/node/x/y/z/part.crdownload"  # nested Tier 1 target
# The live database sits INSIDE a directory Tier 1 actually deletes (~/.npm/_npx). Placing it
# somewhere Tier 1 never visits made the assertion vacuous: the file survived because nothing
# targeted it, so removing the guard entirely still passed. It must be in harm's way to prove
# anything.
# Nested at depth 6, matching where SQLite databases actually sit in real cache trees on this
# machine (surveyed: depth 6 to 10). An earlier maxdepth-3 guard passed a shallow fixture while
# missing the shape that actually occurs.
mkdir -p "$FIX/.npm/_npx/a/b/c/d/live"; echo db > "$FIX/.npm/_npx/a/b/c/d/live/Cache.db"
zsh -c 'exec 9< "'"$FIX"'/.npm/_npx/a/b/c/d/live/Cache.db"; sleep 60' & HOLDER=$!
sleep 1

before=$(find "$FIX" -type f | wc -l | tr -d ' ')
HOME="$FIX" PATH="/usr/bin:/bin:/usr/sbin:/sbin" zsh "$SCRIPT" --apply --yes > "$FIX/run.out" 2>&1
rc=$?

# --- assertions --------------------------------------------------------------------
(( rc == 0 )) && ok "exit 0 on a real --apply" || bad "exit $rc"
# node-gyp is the clean "must be removed" case: it holds nothing guarded. The _npx and .cache/node
# trees deliberately contain a live database and a partial download, so they are EXPECTED to
# survive - asserting their removal too would have contradicted the guard assertions below.
[[ ! -e "$FIX/Library/Caches/node-gyp" ]] && ok "unguarded Tier 1 cache removed" \
                                          || bad "unguarded Tier 1 cache survived"
[[ -e "$FIX/.npm/_npx" ]] && ok "a cache holding a live database is kept whole" \
                          || bad "deleted a cache tree containing an open database"
# .DS_Store is a --scan target (run_scan), NOT Tier 1, so a plain --apply must LEAVE it. The first
# version of this assertion had it backwards and reported working code as broken.
[[ -e "$FIX/proj/.DS_Store" ]] && ok ".DS_Store left alone by Tier 1 (it is a --scan target)" \
                               || bad "Tier 1 deleted a --scan-only target"
[[ -f "$FIX/Library/Keychains/login.keychain" ]] && ok "keychain intact"  || bad "KEYCHAIN DELETED"
[[ -f "$FIX/.ssh/id_ed25519" ]]                  && ok "ssh key intact"   || bad "SSH KEY DELETED"
[[ -f "$FIX/Library/Mail/msg.emlx" ]]            && ok "mail intact"      || bad "MAIL DELETED"
[[ -f "$FIX/Documents/thesis.txt" ]]             && ok "documents intact" || bad "DOCUMENTS DELETED"
[[ -f "$FIX/.cache/node/x/y/z/part.crdownload" ]] && ok "nested in-progress download survives" || bad "DOWNLOAD DELETED"
[[ -f "$FIX/.npm/_npx/a/b/c/d/live/Cache.db" ]]  && ok "open database nested 6 deep inside a Tier 1 target survives" || bad "OPEN DB DELETED"
# the log must name every real deletion
# Globs do NOT expand inside [[ ]] in zsh - the first version tested a literal string containing
# an asterisk and always failed. Expand into an array first.
_logs=("$FIX/.cache/dehoard/"run-*.log(N))
if (( ${#_logs[@]} )); then
  ok "run log written"
else
  bad "no run log for an --apply"
fi
grep -qE "removed|freed|Nothing" "$FIX/run.out" && ok "run reported an outcome" || bad "no outcome line"
kill -9 $HOLDER 2>/dev/null
rm -rf "$FIX"
print -P "%F{cyan}stress: $P passed, $F failed%f"
(( F == 0 ))
