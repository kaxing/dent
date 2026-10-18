#!/usr/bin/env python3
"""Regression checks for dent's capture, travel, and erase promises (stdlib only)."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

DENT = str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/dent").resolve())


def run(directory, *args, ok=True, stdin=None):
    result = subprocess.run([DENT, *args], cwd=directory, input=stdin,
                            text=True, capture_output=True)
    assert (result.returncode == 0) == ok, (args, result.returncode, result.stdout, result.stderr)
    assert "error(SafeAllocator)" not in result.stderr, result.stderr
    if not ok:
        assert "back to #" not in result.stdout, result.stdout
        assert "erased " not in result.stdout, result.stdout
    return result.stdout + result.stderr


with tempfile.TemporaryDirectory(prefix="dent-logic.") as temp:
    root = Path(temp)

    def case(name):
        directory = root / name
        directory.mkdir()
        return directory

    def manifests(directory):
        return {p.name: p.read_bytes() for p in (directory / ".dent-history/manifests").glob("*.manifest")}

    # Read failures are errors, never an empty-file dent or a misleading diff.
    p = case("large")
    (p / "small").write_text("original")
    run(p, "original")
    before = manifests(p)
    with (p / "large").open("wb") as file:
        file.truncate(257 * 1024 * 1024)
    run(p, "too-large", ok=False)
    run(p, "diff", ok=False)
    run(p, "travel", "1", ok=False)
    assert manifests(p) == before
    assert (p / "large").stat().st_size == 257 * 1024 * 1024

    # A directory replacing a file and a file replacing a directory both work.
    p = case("shapes")
    (p / "file").write_text("old-file")
    (p / "dir").mkdir()
    (p / "dir/nested").write_text("old-child")
    run(p, "original")
    (p / "file").unlink()
    (p / "file").mkdir()
    (p / "file/new").write_text("new-child")
    shutil.rmtree(p / "dir")
    (p / "dir").write_text("new-file")
    run(p, "travel", "1")
    assert (p / "file").read_text() == "old-file"
    assert (p / "dir/nested").read_text() == "old-child"
    run(p, "travel", "2")  # The automatic dent must restore the other direction too.
    assert (p / "file/new").read_text() == "new-child"
    assert (p / "dir").read_text() == "new-file"

    # Neither full nor single-file travel may follow a leaf or parent symlink.
    for parent in (False, True):
        p = case("symlink-parent" if parent else "symlink-file")
        (p / "dir").mkdir()
        (p / "dir/f").write_text("original")
        run(p, "original")
        outside = root / ("outside-parent" if parent else "outside-file")
        outside.mkdir()
        (outside / "f").write_text("outside")
        if parent:
            shutil.rmtree(p / "dir")
            (p / "dir").symlink_to(outside, target_is_directory=True)
        else:
            (p / "dir/f").unlink()
            (p / "dir/f").symlink_to(outside / "f")
        run(p, "travel", "1", "dir/f", ok=False)
        run(p, "travel", "1", ok=False)
        assert (outside / "f").read_text() == "outside"

    # Corrupt destination content must fail before deleting current files.
    p = case("corrupt")
    (p / "f").write_text("original-content")
    run(p, "original")
    pack = p / ".dent-history/pack.dat"
    with pack.open("r+b") as file:
        file.seek(40)  # First chunk payload, not its index header or tree chunk.
        byte = file.read(1)
        file.seek(40)
        file.write(bytes([byte[0] ^ 255]))
    (p / "f").write_text("changed-content")
    (p / "extra").write_text("keep-me")
    run(p, "travel", "1", ok=False)
    assert (p / "f").read_text() == "changed-content"
    assert (p / "extra").read_text() == "keep-me"

    # An unreplaceable path must fail, not delete ignored files or claim success.
    # A nonempty directory gives the same filesystem error even when run as root.
    p = case("write-failure")
    (p / "f").write_text("original")
    (p / ".gitignore").write_text("keep\n")
    run(p, "original")
    (p / "f").unlink()
    (p / "f").mkdir()
    (p / "f/keep").write_text("do-not-delete")
    run(p, "travel", "1", ok=False)
    assert (p / "f/keep").read_text() == "do-not-delete"

    # Auto-denting at the limit must not prune the chosen destination.
    p = case("retention")
    for number in range(1, 51):
        (p / "f").write_text(str(number))
        run(p, str(number))
    run(p)  # A duplicate must not trim the oldest dent either.
    assert len(manifests(p)) == 50
    (p / "f").write_text("unsaved")
    run(p, "travel", "1")
    assert (p / "f").read_text() == "1"
    assert "1.manifest" in manifests(p)
    assert len(manifests(p)) == 50
    before = manifests(p)
    run(p, "travel", "9999", ok=False)
    assert manifests(p) == before  # Do not erase the existing auto dent on failure.

    # Retention counts actual dents, not ID ranges; erasing the last clears latest.
    p = case("erase")
    for number in range(1, 6):
        (p / "f").write_text(str(number))
        run(p, str(number))
    run(p, "erase", "4")
    assert "erased 2 dents" in run(p, "erase", "--keep", "2")
    assert set(manifests(p)) == {"3.manifest", "5.manifest"}
    assert "nothing to erase" in run(p, "erase", "--keep", "2")
    run(p, "erase", "5")
    assert (p / ".dent-history/latest").read_text().strip() == "3"
    run(p, "erase", "3")
    assert not (p / ".dent-history/latest").exists()
    run(p, "travel", ok=False)
    run(p, "diff", ok=False)
    run(p, "new-start")
    assert set(manifests(p)) == {"1.manifest"}

    # Note limits are checked before publishing or truncating any manifest.
    p = case("notes")
    (p / "f").write_text("original")
    run(p, "x" * 446)
    before = manifests(p)
    run(p, "edit", "1", "x" * 447, ok=False)
    run(p, "x" * 447, ok=False)
    run(p, "edit", "1", "é" * 224, ok=False)  # Byte limit, not character count.
    assert manifests(p) == before
    run(p, "edit", "1", "valid")
    assert "valid" in run(p, "list")
    manifest = p / ".dent-history/manifests/1.manifest"
    original = manifest.read_bytes()
    manifest.write_bytes(original[:60])
    run(p, "list", ok=False)
    malformed = bytearray(original)
    malformed[32:34] = (65535).to_bytes(2, "little")
    manifest.write_bytes(malformed)
    run(p, "list", ok=False)
    manifest.write_bytes(original)

print("Logic regressions passed: capture failures, travel failures/shapes/symlinks, retention, erase, notes.")
