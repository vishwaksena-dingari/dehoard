#!/usr/bin/env zsh
# --scan stress test. --scan removes PROJECT artifacts (venvs, node_modules, build dirs), which is
# higher-stakes than Tier 1: a wrong deletion here costs someone's working tree, not a cache. Only
# Tier 1 had a stress test, so this covers the other real deletion path.
emulate zsh; setopt NULL_GLOB
SCRIPT="${1:?script path}"
P=0; F=0
ok(){ print -P "  %F{green}✓%f $1"; (( P++ )); return 0 }
bad(){ print -P "  %F{red}✗%f $1"; (( F++ )); return 0 }
FIX=$(mktemp -d); export TMPDIR="$FIX/tmp/"; mkdir -p "$FIX/tmp"

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

HOME="$FIX" PATH="/usr/bin:/bin:/usr/sbin:/sbin" zsh "$SCRIPT" --scan --apply --yes > "$FIX/out" 2>&1
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
