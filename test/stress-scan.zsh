#!/usr/bin/env zsh
# --scan stress test. --scan removes PROJECT artifacts (venvs, node_modules, build dirs), which is
# higher-stakes than Tier 1: a wrong deletion here costs someone's working tree, not a cache. Only
# Tier 1 had a stress test, so this covers the other real deletion path.
emulate zsh; setopt NULL_GLOB
SCRIPT="${1:?script path}"
P=0; F=0
ok(){ print -P "  %F{green}✓%f $1"; (( P++ )); return 0 }
bad(){ print -P "  %F{red}✗%f $1"; (( F++ )); return 0 }
# Clean up on ANY exit, not just the happy path. Without this an interrupted or failed run leaks
# its fixture directory -
# thirteen orphaned fixtures were found on this machine after a session of interrupted runs.
# Stub the tools that reach OUTSIDE the fixture. osascript is the one that matters: scree posts a
# desktop notification whenever it frees anything, and with the real PATH these tests fired a
# genuine macOS notification on every run - the user watched "scree: Freed 16 KB" pop up repeatedly
# while the suite ran. A test must not be observable outside its fixture. pip/gem are stubbed for
# the same reason the main suite stubs them: they mutate the developer's real Python and Ruby state.
_STUBS=$(mktemp -d)
for _t in osascript pip pip3 gem; do
  print -r -- $'#!/bin/sh\nexit 0' > "$_STUBS/$_t"; chmod +x "$_STUBS/$_t"
done
_TESTPATH="$_STUBS:/usr/bin:/bin:/usr/sbin:/sbin"
FIX=$(mktemp -d)
trap 'rm -rf "$FIX" "$_STUBS" 2>/dev/null; exit 130' INT TERM
trap 'rm -rf "$FIX" "$_STUBS" 2>/dev/null;' EXIT; export TMPDIR="$FIX/tmp/"; mkdir -p "$FIX/tmp"

# A realistic project: real source beside regenerable artifacts.
mkdir -p "$FIX/proj/src" "$FIX/proj/node_modules/pkg" "$FIX/proj/.venv/lib" "$FIX/proj/__pycache__"
echo 'fn main(){}'      > "$FIX/proj/src/main.rs"
echo '{"name":"x"}'     > "$FIX/proj/package.json"
echo 'source'          > "$FIX/proj/node_modules/pkg/index.js"
echo 'cfg'             > "$FIX/proj/.venv/pyvenv.cfg"
echo 'pyc'             > "$FIX/proj/__pycache__/m.pyc"
# Cargo target must only go when a sibling Cargo.toml proves it is a build dir.
mkdir -p "$FIX/rust/target/debug"; echo 'bin' > "$FIX/rust/target/debug/app"
echo '[package]'       > "$FIX/rust/Cargo.toml"
# ...and a directory NAMED target that is not a build dir at all.
mkdir -p "$FIX/notrust/target"; echo 'precious data' > "$FIX/notrust/target/data.csv"

HOME="$FIX" PATH="$_TESTPATH" zsh "$SCRIPT" --scan --apply --yes > "$FIX/out" 2>&1
rc=$?

(( rc == 0 )) && ok "exit 0" || bad "exit $rc"
[[ -f "$FIX/proj/src/main.rs" ]]   && ok "source survives"        || bad "SOURCE DELETED"
[[ -f "$FIX/proj/package.json" ]]  && ok "manifest survives"      || bad "MANIFEST DELETED"
[[ ! -d "$FIX/proj/node_modules" ]] && ok "node_modules removed"  || bad "node_modules survived"
[[ ! -d "$FIX/proj/.venv" ]]        && ok "venv removed"          || bad "venv survived"
[[ ! -d "$FIX/proj/__pycache__" ]]  && ok "__pycache__ removed"   || bad "__pycache__ survived"
[[ ! -d "$FIX/rust/target" ]]       && ok "cargo target removed (Cargo.toml sibling present)" \
                                    || bad "cargo target survived"
[[ -f "$FIX/notrust/target/data.csv" ]] && ok "a 'target' dir with no Cargo.toml is NOT touched" \
                                        || bad "DELETED A NON-BUILD 'target' DIRECTORY"
rm -rf "$FIX"
print -P "%F{cyan}scan stress: $P passed, $F failed%f"
(( F == 0 ))
