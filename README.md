# dent — leave a dent.

Before an agent changes course, leave a dent so it can find its way back.

`dent` saves fast, local checkpoints of your codebase. Give each one a note, explore a new direction, and roll back when it leads nowhere. No branches, no staging, no merge conflicts.

## Install

```sh
brew install kaxing/toolbox/dent
```

### From source

```sh
git clone https://github.com/kaxing/dent
cd dent
make install    # installs to /usr/local/bin/dent
```

Requires Zig 0.16.0. Run `make test` to verify your build.

## Leave a trail

```sh
dent "before refactoring auth"
# Let your agent explore. Run your tests.
dent diff
dent list
# Wrong turn? Find your way back.
dent rollback 1
```

For your agent instructions:

> Before a risky edit, leave a dent with `dent "what you are about to change"`. Use `dent list` and `dent diff` to orient yourself. Ask before rolling back work that may belong to someone else.

A dent is a local file checkpoint, not a backup or a record of the agent's conversation. Keep using Git and off-device backups for durable history.

## Read the trail

Output is plain text: no animation, no color dependency. Every saved state has a numeric ID you can pass straight to a command.

```text
$ dent "before refactoring auth"
dent #1 · before refactoring auth

$ dent list
trail · /your/project/.checkpoint-files/
1 of 1 dents · newest first

#1 · before refactoring auth
  2026-05-12 14:30 UTC · 12 files · 24KB

$ dent diff
since #1 · working changes
  ~ src/auth.ts

$ dent rollback 1
dent #2 · <auto> · saved before rollback
back to #1 · restored
```

The trail shows newest dents first. Rollback always reports the ID it restored, including when you omit the ID. Errors go to stderr with a `dent:` prefix and a nonzero exit code.

## Commands

```text
dent                       leave a dent (save a checkpoint)
dent "message"             leave a dent with a note
dent rollback              return to the latest checkpoint
dent rollback <id>         return to a specific checkpoint
dent rollback <id> <path>  restore a single file
dent diff                  compare current files with the latest checkpoint
dent diff <id>             compare current files with a checkpoint
dent diff <id> <path>      show content diff for one file
dent list                  show your trail of checkpoints
dent list <N>              show the last N checkpoints
dent edit <id> "message"   update a checkpoint's note
dent remove <id>           remove a checkpoint
dent remove --keep <N>     keep only the last N checkpoints
dent remove all            remove all checkpoints (asks for confirmation)
dent version               show version
```

Full rollback saves changed current state as `<auto>` before restoring, unless that state is already on the trail. Only one `<auto>` is retained. Single-file rollback does **not** auto-save. Rollback can overwrite or remove working files; inspect your trail before using it.

## Previously checkpoint / check

The project is now `kaxing/dent` and the command is `dent`. Existing `.checkpoint-files/` directories remain readable in place; the storage format and directory name are unchanged. No data migration is needed. Update scripts from `check` to `dent`.

## How it works

FastCDC content-defined chunking, BLAKE3 hashing, and zstd compression. Unchanged files are skipped via mtime and size; changed files are processed in parallel, with sequential pack writes.

Run `make bench` to measure performance on your machine.

## Uninstall

```sh
brew uninstall dent
# From-source install:
make uninstall
```
