# dent — leave a dent.

Find your way in the file multiverse.

Every edit takes your files somewhere new. Before you or your agent changes course, **leave a dent**. Try the refactor, follow an idea, take a wrong turn. Your trail gives you a way back.

A dent holds your local files as they were, with a note about where you were headed. No staging, branches, or ceremony. Just `dent "before trying this"`.

This is a multiverse of file changes—not parallel running environments. Travel changes your working files. Keep Git for commits and collaboration, and off-device backups for durable protection.

## Install

```sh
brew install kaxing/toolbox/dent
```

Stay current, then ask the installed CLI for its usage:

```sh
brew update && brew upgrade dent
dent --version
dent --help
```

Manual binaries: [latest release](https://github.com/kaxing/dent/releases/latest).

### From source

```sh
git clone https://github.com/kaxing/dent
cd dent
make install    # installs to /usr/local/bin/dent
```

Requires Zig 0.17.0 and Python 3 for the regression tests. Run `make test` to verify your build.

## Leave a dent. Explore. Find your way.

```sh
dent "before refactoring auth"
# Follow the idea. Let your agent explore. Run your tests.
dent diff
dent list
# Wrong turn? Travel to a dent you recognize.
dent travel 1
```

For your agent instructions:

> Before a risky edit, leave a dent with `dent "what you are about to change"`. Use `dent list` to read your trail and `dent diff` to see where your files have gone. Ask before travel or erasing dents. Run `dent --help` for current usage.

A dent holds files, not an agent's conversation or reasoning. See [skill.md](skill.md) for the minimal agent skill.

## Read your trail

Every dent has a numeric ID. Output is plain text: no animation, no color dependency, and IDs you can pass straight to a command.

```text
$ dent "before refactoring auth"
dent #1 · before refactoring auth

$ dent list
trail · /your/project/.dent-history/
1 of 1 dents · newest first

#1 · before refactoring auth
  2026-05-12 14:30 UTC · 12 files · 24KB

$ dent diff
since #1 · working changes
  ~ src/auth.ts

$ dent travel 1
dent #2 · <auto> · left before travel
back to #1 · restored
```

Your trail runs newest first. Travel always reports the dent it returned to, including when you omit the ID. Errors go to stderr with a `dent:` prefix and a nonzero exit code.

## Choose your direction

```text
dent                      leave a dent
dent "message"            leave a dent with a note
dent travel               return to the latest dent
dent travel <id>          return to a specific dent
dent travel <id> <path>   restore a single file
dent diff                 compare current files with the latest dent
dent diff <id>            compare current files with a dent
dent diff <id> <path>     show content diff for one file
dent list                 read your trail of dents
dent list <N>             show the last N dents
dent edit <id> "message"  update a dent's note
dent erase <id>           erase a dent
dent erase --keep <N>     erase all but the last N dents
dent erase all            erase all dents (asks for confirmation)
dent version              show version
dent --help               show current usage
```

**Travel can overwrite or remove working files.** Full travel first leaves an `<auto>` dent of changed current files, unless they are already on the trail. Older `<auto>` dents are erased only after successful travel, except when one is the destination. Single-file travel does **not** leave an automatic dent. Read your trail before returning to one. Travel reads the full destination before changing working files, but it is not an all-or-nothing filesystem transaction: a later I/O failure can leave partial changes and is reported as an error.

**Erase changes your trail, not your working files.** `dent erase <id>` erases one dent; `dent erase --keep <N>` trims older dents; `dent erase all` asks before erasing the whole trail. Erased dents are no longer available as travel destinations.

## One trail from wherever you stand

Dent checks the current directory, then its ancestors, and uses the nearest `.dent-history/`. From a subdirectory, you still work with that whole repository's trail—not just the files beneath your feet. File arguments remain relative to the directory where you run dent.

When the trail belongs to a parent, dent tells you on stderr:

```text
tracking dents from parent · /your/project/.dent-history/
```

If no trail exists above you, leaving your first dent creates `.dent-history/` in the current directory. Other commands report that there are no dents yet. Keep `.dent-history/` to retain your way back, and exclude it from Git.

### Nested trails travel with their files

Only the active root `.dent-history/` is excluded from its own dents. Nested folders—including any existing nested `.dent-history/` histories—travel with the files in a parent dent. **Travel from the parent can restore or remove those nested histories too.**

Upward discovery avoids accidentally starting another trail inside an existing one. If a nested trail already exists, such as in a copied project, commands inside it use that nearest trail. Trails are not merged or migrated. A broken nearest `.dent-history/` produces an error rather than silently choosing a different trail.

Git metadata and ordinary-file ignore rules still apply. Nested history contents are not filtered by `.gitignore` patterns. Dents contain regular files, not empty directories or symlinks.

## Limits, plainly

- A dent fails if a file cannot be read; it does not substitute an empty file. The current per-file limit is 256 MiB, including nested history files.
- Notes can contain up to 446 UTF-8 bytes.
- The trail normally keeps the latest 50 dents. Trimming happens after successful denting or travel; the travel destination is retained during that trim.
- Travel refuses destination paths that pass through symlinks. It does not follow them into other files or directories.

## Under the trail

Dent splits file contents with FastCDC, identifies chunks with BLAKE3, and compresses them with zstd. Shared chunks avoid storing the same content repeatedly. Unchanged files are skipped via mtime and size; changed files are chunked and compressed, with sequential pack writes.

Run `make bench` to measure performance on your machine.

## Uninstall

```sh
brew uninstall dent
# From-source install:
make uninstall
```
