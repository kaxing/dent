#!/usr/bin/env bash
# Integration tests for dent's command and output contract.
# Usage: bash test-coverage/integration.sh [path-to-dent-binary]
set -euo pipefail
DENT="$(cd "$(dirname "${1:-./zig-out/bin/dent}")" && pwd)/$(basename "${1:-./zig-out/bin/dent}")"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dent.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
PASS=0
new_dir() { cd "$(mktemp -d "$ROOT/case.XXXXXX")"; }
contains() {
    if ! grep -qF -- "$2" <<< "$1"; then
        printf 'FAIL: expected %s in:\n%s\n' "$2" "$1" >&2
        exit 1
    fi
    PASS=$((PASS + 1))
}
equals() {
    if [ "$1" != "$2" ]; then
        printf 'FAIL: expected <%s>, got <%s>\n' "$2" "$1" >&2
        exit 1
    fi
    PASS=$((PASS + 1))
}
fails() {
    if "$@" >"$ROOT/error" 2>&1; then
        echo "FAIL: expected failure: $*" >&2
        exit 1
    fi
    contains "$(<"$ROOT/error")" 'dent: '
}

new_dir
contains "$("$DENT" --help)" 'leave a dent. Find your way back.'
contains "$("$DENT" --help)" 'READ THE TRAIL'
contains "$("$DENT" --help)" 'without auto-save'
equals "$("$DENT" version)" 'v0.0.5'
equals "$("$DENT" --version)" 'v0.0.5'
# Informational commands must not create storage.
[ ! -d .checkpoint-files ]
for command in rollback diff list; do fails "$DENT" "$command"; done
fails "$DENT" remove 1

# Save, notes, duplicate detection and the legacy storage location.
echo one > file.txt
contains "$("$DENT" 'before the refactor')" 'dent #1 · before the refactor'
[ -d .checkpoint-files ]
contains "$("$DENT")" 'unchanged · already on your trail'
contains "$("$DENT" list)" '1 of 1 dents'
contains "$("$DENT" list)" '.checkpoint-files/'
contains "$("$DENT" edit 1 'known good')" 'noted #1 · known good'
contains "$("$DENT" list)" '#1 · known good'
fails "$DENT" edit 99 nope
fails "$DENT" remove 99
contains "$("$DENT" remove)" 'dent remove'

# Diff and rollback, including recovery of unsaved work.
echo two > file.txt
echo added > added.txt
OUT=$("$DENT" diff)
contains "$OUT" 'since #1 · working changes'
contains "$OUT" '~ file.txt'
contains "$OUT" '+ added.txt'
OUT=$("$DENT" diff 1 file.txt)
contains "$OUT" '--- #1 file.txt'
contains "$OUT" '+++ current file.txt'
contains "$OUT" '-one'
contains "$OUT" '+two'
contains "$("$DENT" diff 1 added.txt)" '+added'
OUT=$("$DENT" rollback 1)
contains "$OUT" 'dent #2 · <auto> · saved before rollback'
contains "$OUT" 'back to #1 · restored'
equals "$(<file.txt)" one
[ ! -f added.txt ]
contains "$("$DENT" list)" '#2 · <auto>'
"$DENT" rollback 2 >/dev/null
equals "$(<file.txt)" two
equals "$(<added.txt)" added
contains "$("$DENT" diff 2 file.txt)" 'no changes'
rm added.txt
contains "$("$DENT" diff 2)" '- added.txt'

# A single-file rollback changes only that file, without auto-saving.
new_dir
echo original > a.txt
echo original > b.txt
"$DENT" >/dev/null
echo changed > a.txt
echo changed > b.txt
contains "$("$DENT" rollback 1 a.txt)" 'back to #1 · a.txt'
equals "$(<a.txt)" original
equals "$(<b.txt)" changed
contains "$("$DENT" list)" '1 of 1 dents'

# Smart auto-save skips duplicates and retains at most one <auto>.
new_dir
echo one > f
"$DENT" one >/dev/null
echo two > f
"$DENT" two >/dev/null
"$DENT" rollback 1 >/dev/null
equals "$("$DENT" list | grep -c '<auto>' || true)" 0
echo dirty > f
"$DENT" rollback 2 >/dev/null
echo dirtier > f
"$DENT" rollback 1 >/dev/null
equals "$("$DENT" list | grep -c '<auto>')" 1

# Latest rollback names its actual target; list limits and pruning.
new_dir
for i in 1 2 3 4 5; do
    echo "v$i" > f
    "$DENT" "step $i" >/dev/null
done
echo unsaved > f
contains "$("$DENT" rollback)" 'back to #5 · restored'
equals "$(<f)" v5
contains "$("$DENT" remove 6)" 'removed #6 · working files unchanged'
OUT=$("$DENT" list 2)
contains "$OUT" '2 of 5 dents'
contains "$OUT" '#5 · step 5'
contains "$OUT" '#4 · step 4'
if grep -qF 'step 3' <<< "$OUT"; then exit 1; fi
contains "$("$DENT" remove --keep 2)" 'trimmed 3 dents · kept last 2'
contains "$("$DENT" list)" '2 of 2 dents'
fails "$DENT" remove --keep 0
contains "$("$DENT" remove --keep 10)" 'trail unchanged · nothing to remove'
contains "$(printf 'n\n' | "$DENT" remove all)" 'cancelled · trail unchanged'
contains "$("$DENT" list)" '2 of 2 dents'
OUT=$(printf 'y\n' | "$DENT" remove all)
contains "$OUT" 'This erases your recovery trail, not working files.'
contains "$OUT" 'removed all 2 dents · working files unchanged'
equals "$(<f)" v5
contains "$("$DENT" list)" 'no dents yet · leave one with `dent`'
contains "$("$DENT" remove all)" 'trail empty · nothing to remove'

# Empty, binary and deeply nested files survive rollback.
new_dir
touch empty
mkdir -p a/b/c
echo nested > a/b/c/file
dd if=/dev/urandom of=binary bs=1024 count=100 2>/dev/null
cp binary "$ROOT/original-binary"
"$DENT" >/dev/null
echo filled > empty
rm -r a
echo changed > binary
"$DENT" rollback 1 >/dev/null
[ ! -s empty ]
equals "$(<a/b/c/file)" nested
cmp binary "$ROOT/original-binary"

# Multiple saved states remain reachable after successive rollbacks.
new_dir
for i in 1 2 3; do echo "$i" > f; "$DENT" >/dev/null; done
for i in 1 2 3; do "$DENT" rollback "$i" >/dev/null; equals "$(<f)" "$i"; done
printf 'All %d output assertions and file recovery checks passed.\n' "$PASS"
