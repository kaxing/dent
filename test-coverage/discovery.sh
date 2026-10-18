#!/usr/bin/env bash
# Native design test: nearest history selects the root; nested history is content.
set -euo pipefail
DENT="$(cd "$(dirname "${1:-./zig-out/bin/dent}")" && pwd)/$(basename "${1:-./zig-out/bin/dent}")"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dent-discovery.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
contains() { grep -qF -- "$2" <<< "$1" || { echo "FAIL: missing $2 in $1" >&2; exit 1; }; }
fails() { if "$@" >"$ROOT/error" 2>&1; then echo "FAIL: expected failure: $*" >&2; exit 1; fi; }

# No ancestor history: create at the invocation directory, never search down.
mkdir -p "$ROOT/project/app/src" "$ROOT/project/ordinary/deep"
cd "$ROOT/project/app"
echo child-original > code
"$DENT" child-one >/dev/null
[ ! -e ../.dent-files ]
CHILD=$(pwd -P)
# Root ignore patterns must not partially capture a nested history.
echo opaque-data > .dent-files/example.idx
cp -R .dent-files "$ROOT/child-history"
cd ..
echo parent-original > file
printf '.dent-files/\n*.idx\nignored/\n' > .gitignore
mkdir ignored .git
echo untracked > ignored/file
echo git-metadata > .git/config
fails "$DENT" list
"$DENT" parent-one >"$ROOT/out" 2>"$ROOT/notice"
[ ! -s "$ROOT/notice" ]
PARENT=$(pwd -P)

# Deep invocation finds parent and prints a notice; file paths remain CWD-relative.
cd ordinary/deep
contains "$("$DENT" list 2>"$ROOT/notice")" "$PARENT/.dent-files/"
contains "$(<"$ROOT/notice")" "tracking dents from parent · $PARENT/.dent-files/"
echo parent-changed > ../../file
contains "$("$DENT" diff 1 ../../file)" '+parent-changed'
"$DENT" travel 1 ../../file >/dev/null
[ "$(<../../file)" = parent-original ]
echo saved-from-deep > local
"$DENT" parent-two >/dev/null
[ ! -e .dent-files ]
[ ! -e ../.dent-files ]
contains "$("$DENT" list)" 'parent-two'
fails "$DENT" travel 1 ../../../outside

# An existing nearer child still selects its own trail.
cd "$CHILD/src"
contains "$("$DENT" list)" "$CHILD/.dent-files/"
contains "$("$DENT" list)" 'child-one'
echo child-changed > ../code
"$DENT" child-two >/dev/null
cd "$PARENT"
contains "$("$DENT" diff)" 'app/code'
contains "$("$DENT" diff)" 'app/.dent-files/'
contains "$("$DENT" diff 1 app/code)" '+child-changed'
# Nested metadata can be explicitly restored; active metadata cannot.
echo changed-data > app/.dent-files/example.idx
"$DENT" travel 1 app/.dent-files/example.idx >/dev/null
[ "$(<app/.dent-files/example.idx)" = opaque-data ]
fails "$DENT" travel 1 .dent-files/HEAD
fails "$DENT" diff 1 .dent-files/HEAD

# Travel from the parent restores child work and child history byte-for-byte.
"$DENT" travel 1 >/dev/null
[ "$(<app/code)" = child-original ]
diff -r "$ROOT/child-history" app/.dent-files
[ "$(<ignored/file)" = untracked ]
[ "$(<.git/config)" = git-metadata ]
contains "$("$DENT" list)" 'parent-one'
contains "$("$DENT" diff 1)" 'no changes'
# Delete nested history entirely, then recover it from the parent dent.
mv app/.dent-files "$ROOT/removed-history"
contains "$("$DENT" diff 1)" 'app/.dent-files/'
"$DENT" travel 1 >/dev/null
diff -r "$ROOT/child-history" app/.dent-files

# A nested history created after the dent is removed by travel from the parent.
mkdir later
cp -R "$ROOT/child-history" later/.dent-files
echo new-file > later/code
"$DENT" travel 1 >/dev/null
[ ! -e later ]

# Broken nearest history is an error, not fallback or implicit initialization.
mkdir -p broken/.dent-files broken/deep
cd broken/deep
fails "$DENT" list
fails "$DENT" should-not-initialize
[ ! -e .dent-files ]
[ ! -e ../.dent-files/manifests ]

printf 'Discovery design test passed: upward lookup, parent notice, relative paths, nested history capture/restore/removal, active history protection.\n'
