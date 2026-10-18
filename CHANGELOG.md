# Changelog

## v0.0.6

- Require Zig 0.17.0; update build argument forwarding, optimization names, tests, and the algorithm benchmark. Generate zstd bindings with pinned `translate_c` 2.0.2 and check allocations with Zig's `SafeAllocator`.
- Fail dent creation and diff on unreadable or oversized files instead of treating them as empty.
- Read the full travel destination before changing working files, handle file/directory transitions, reject symlink destinations, and report filesystem failures.
- Trim history only after success, retain the travel destination, and count existing dents rather than ID ranges.
- Keep `latest` correct when erasing dents; report erase failures rather than success.
- Validate note lengths before writing and publish complete manifests with filesystem rename.
- Add focused native regression tests for capture, travel, erase, and note failures.
- Use `dent travel` to return to a dent and `dent erase` to erase dents from the trail; no legacy command aliases are provided.
- Leave a dent. Find your way in the file multiverse: a shared narrative across help, output, docs, the agent skill, and benchmarks.
- Keep the trail in `.dent-history/`; no automatic migration is included.
- Find the nearest trail upward and announce when tracking dents from a parent directory.
- Include nested files and nested dent histories in the parent trail; travel from the parent can restore or remove both.
- Keep the metaphor grounded: dents hold local files, not conversations or parallel environments. Keep Git and off-device backups.

## v0.0.5

- Renamed the CLI from `check` to `dent`.
- Leave a dent before an agent changes course, so it can find its way back.
- Redesigned help into leave/read/return/trim sections and the trail into compact two-line entries.
- Consistent `dent #id`, `since #id`, and `back to #id` output; errors use a `dent:` prefix.
- Rollback reports its resolved ID; removal prompts explain what will be deleted.
- Updated documentation, release archives, and Homebrew packaging.
- Preserved the previous storage directory and format for this release.
- Updated integration tests and benchmarks to the current positional-note, `edit`, and `list <N>` syntax.

## Earlier releases

The CLI was named `check` in these releases. Commands below describe their historical syntax.

### v0.0.3

- Renamed the storage pointer from `HEAD` to `latest`.
- Added `check note <id> "message"` to annotate a saved state.
- Skipped saves when the current state already existed in the trail.
- Refused saves when disk space was more than 93.75% full.

### v0.0.2

- Renamed `check restore` to `check rollback` and removed `check undo`.
- Moved `check cleanup --keep N` to `check remove --keep N`.
- Changed version output to `v0.0.2`.
- Added `<auto>` recovery before full rollback, skipping duplicate states.
- Added removal by ID, retention count, or the entire trail with confirmation.

### v0.0.1

Initial release.
