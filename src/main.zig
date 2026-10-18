const std = @import("std");
const repo_mod = @import("repo.zig");
const manifest_mod = @import("manifest.zig");

const Io = std.Io;
const Dir = Io.Dir;

const VERSION = "0.0.5";

const USAGE =
    \\dent — leave a dent.
    \\
    \\Find your way in the file multiverse.
    \\Follow an idea. Take a wrong turn. Keep a trail back.
    \\
    \\LEAVE A DENT
    \\  dent                      leave a dent here
    \\  dent "before the refactor" leave a dent with a note
    \\
    \\READ THE TRAIL
    \\  dent list [N]             show all dents, or the last N
    \\  dent diff [id] [path]     compare working files with a dent
    \\  dent edit <id> "note"     update a dent's note
    \\
    \\FIND YOUR WAY BACK
    \\  dent travel [id]          return to a dent (default: latest)
    \\  dent travel <id> <path>   restore one file, without auto-save
    \\
    \\ERASE DENTS
    \\  dent erase <id>           erase one dent
    \\  dent erase --keep <N>     erase all but the last N dents
    \\  dent erase all            erase all dents (asks first)
    \\
    \\  dent version              show version
    \\  dent --help               show this guide
    \\
    \\Use numeric IDs from `dent list`. Paths are relative to this directory.
    \\Uses the nearest .dent-files/ here or above, across that whole tree.
    \\Full travel leaves an <auto> dent of changed files before restoring.
    \\Travel can overwrite files and restore or remove nested dent histories.
    \\Erase deletes dents from your trail, not your working files.
    \\Dents hold local files, not conversations. Keep Git and off-device backups.
    \\
;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    _ = std.c.write(1, slice.ptr, slice.len);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    _ = std.c.write(2, "dent: ", 6);
    _ = std.c.write(2, msg.ptr, msg.len);
    _ = std.c.write(2, "\n", 1);
    std.process.exit(1);
}

var g_io: Io = undefined;
var repo_path: []const u8 = ".";
var invocation_path: [:0]const u8 = ".";

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(.{ .vector = init.minimal.args.vector });
    _ = args.next(); // skip program name

    const cmd = args.next();

    // Informational commands do not need repository discovery.
    const informational = if (cmd) |c| std.mem.eql(u8, c, "version") or std.mem.eql(u8, c, "--version") or
        std.mem.eql(u8, c, "-v") or std.mem.eql(u8, c, "help") or std.mem.eql(u8, c, "--help") or std.mem.eql(u8, c, "-h") else false;
    if (!informational) {
        invocation_path = try Dir.cwd().realPathFileAlloc(io(), ".", allocator);
        repo_path = discoverRoot(invocation_path) catch |e| fatal("repository discovery failed: {}", .{e});
        if (!std.mem.eql(u8, repo_path, invocation_path)) {
            var notice_buf: [4096]u8 = undefined;
            const notice = std.fmt.bufPrint(&notice_buf, "tracking dents from parent · {s}/.dent-files/\n", .{repo_path}) catch "tracking dents from parent\n";
            _ = std.c.write(2, notice.ptr, notice.len);
        }
    }
    defer if (!informational) allocator.free(invocation_path);

    // No args → save (create repo if needed)
    if (cmd == null) {
        return doSave(allocator, null);
    }

    const command = cmd.?;

    if (std.mem.eql(u8, command, "travel")) {
        const id_arg = args.next();
        const id = parseOptionalId(id_arg);
        if (id_arg != null and id == null) fatal("usage: dent travel [id] [path] — id must be a number", .{});
        const path = args.next();
        if (path != null and id == null) fatal("usage: dent travel <id> <path>", .{});
        const relative = resolveFileArgument(allocator, path);
        defer if (relative) |p| allocator.free(p);
        return doTravel(allocator, id, relative);
    }

    if (std.mem.eql(u8, command, "edit")) {
        const id_str = args.next() orelse fatal("usage: dent edit <id> \"text\"", .{});
        const id = std.fmt.parseInt(u32, id_str, 10) catch fatal("usage: dent edit <id> \"text\"", .{});
        const note = args.next() orelse fatal("usage: dent edit <id> \"text\"", .{});
        return doNote(allocator, id, note);
    }

    if (std.mem.eql(u8, command, "erase")) {
        const next = args.next() orelse {
            out("dent erase <id>          erase a dent\n", .{});
            out("dent erase --keep N      erase all but the last N dents\n", .{});
            out("dent erase all           erase all dents (asks first)\n", .{});
            return;
        };
        if (std.mem.eql(u8, next, "all")) {
            return doEraseAll(allocator);
        }
        if (std.mem.eql(u8, next, "--keep")) {
            const val = args.next() orelse fatal("--keep requires a number", .{});
            const keep = std.fmt.parseInt(u32, val, 10) catch fatal("--keep requires a number", .{});
            if (keep == 0) fatal("--keep must be at least 1", .{});
            return doCleanup(allocator, keep);
        }
        const id = std.fmt.parseInt(u32, next, 10) catch fatal("dent erase <id> — id must be a number", .{});
        return doErase(allocator, id);
    }

    if (std.mem.eql(u8, command, "diff")) {
        const next = args.next();
        const id = parseOptionalId(next);
        const path = if (id != null) args.next() else if (next != null and !isNumeric(next.?)) next else args.next();
        const relative = resolveFileArgument(allocator, path);
        defer if (relative) |p| allocator.free(p);
        return doDiff(allocator, id, relative);
    }

    if (std.mem.eql(u8, command, "list")) {
        const next = args.next();
        var recent: ?u32 = null;
        if (next) |n| {
            recent = std.fmt.parseInt(u32, n, 10) catch fatal("usage: dent list <N>", .{});
        }
        return doList(allocator, recent);
    }


    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        out("v{s}\n", .{VERSION});
        return;
    }

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        out("{s}", .{USAGE});
        return;
    }

    // Not a known subcommand — treat as note for save
    return doSave(allocator, command);
}

fn io() Io {
    return g_io;
}

const native = @import("builtin").target.os.tag;
const fsblkcnt_t = if (native == .macos) u32 else c_ulong;
const Statvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: fsblkcnt_t,
    f_bfree: fsblkcnt_t,
    f_bavail: fsblkcnt_t,
    f_files: fsblkcnt_t,
    f_ffree: fsblkcnt_t,
    f_favail: fsblkcnt_t,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
};
extern fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

fn checkDiskSpace() void {
    var buf: Statvfs = undefined;
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}", .{repo_path}) catch return;
    if (statvfs(path, &buf) != 0) return;
    if (buf.f_blocks > 0 and buf.f_bavail < buf.f_blocks >> 4) {
        fatal("disk almost full; denting paused", .{});
    }
}

fn isDuplicateDent(allocator: std.mem.Allocator, r: *repo_mod.Repo, id: u32) bool {
    const m = manifest_mod.read(allocator, r.manifests_dir, io(), id) catch return false;
    defer if (m.name.len > 0) allocator.free(m.name);
    const manifests = r.list() catch return false;
    defer {
        for (manifests) |em| if (em.name.len > 0) allocator.free(em.name);
        allocator.free(manifests);
    }
    for (manifests) |em| {
        if (em.id == id) continue;
        if (std.mem.eql(u8, &em.tree_hash, &m.tree_hash)) return true;
    }
    return false;
}

fn removeDuplicateDent(r: *repo_mod.Repo, id: u32) void {
    var name_buf: [32]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{id}) catch unreachable;
    r.manifests_dir.deleteFile(io(), filename) catch {};
    if (id > 1) manifest_mod.writeHead(r.cp_dir, io(), id - 1) catch {};
}

fn discoverRoot(start: []const u8) ![]const u8 {
    var candidate = start;
    while (true) {
        const dir = try Dir.cwd().openDir(io(), candidate, .{});
        defer dir.close(io());
        if (try @import("walker.zig").hasDent(dir, io())) return candidate;
        candidate = std.fs.path.dirname(candidate) orelse return start;
    }
}

fn resolveFileArgument(allocator: std.mem.Allocator, path: ?[]const u8) ?[]const u8 {
    const p = path orelse return null;
    const absolute = std.fs.path.resolve(allocator, &.{ invocation_path, p }) catch fatal("out of memory", .{});
    defer allocator.free(absolute);
    const relative = std.fs.path.relative(allocator, invocation_path, null, repo_path, absolute) catch fatal("out of memory", .{});
    if (std.mem.eql(u8, relative, "..") or std.mem.startsWith(u8, relative, "../"))
        fatal("path is outside the repository", .{});
    if (@import("walker.zig").isProtected(relative))
        fatal("path belongs to active dent or Git metadata", .{});
    return relative;
}

fn openCwd() Dir {
    return Dir.cwd().openDir(io(), repo_path, .{ .iterate = true }) catch
        fatal("failed to open current directory", .{});
}

fn doSave(allocator: std.mem.Allocator, name: ?[]const u8) void {
    checkDiskSpace();
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.openOrCreate(allocator, cwd, io()) catch |e| fatal("failed to open repo: {}", .{e});
    defer r.deinit();
    const id = r.save(name) catch |e| fatal("could not leave a dent: {} (errno={})", .{ e, std.c._errno().* });
    if (isDuplicateDent(allocator, &r, id)) {
        removeDuplicateDent(&r, id);
        out("unchanged · already on your trail\n", .{});
        return;
    }
    if (name) |n| {
        out("dent #{d} · {s}\n", .{ id, n });
    } else {
        out("dent #{d} · left here\n", .{id});
    }
}

fn doTravel(allocator: std.mem.Allocator, id: ?u32, path: ?[]const u8) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no dents yet; leave one with `dent`", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    // Resolve target before auto-saving
    const target_id = id orelse blk: {
        const head = manifest_mod.readHead(r.cp_dir, io()) catch fatal("failed to read latest", .{});
        break :blk head orelse fatal("no dents yet; leave one with `dent`", .{});
    };

    // Single-file travel: no auto-save, just restore the one file
    if (path) |file_path| {
        r.restoreFile(target_id, file_path) catch |e| {
            if (e == error.FileNotFound) fatal("file not in dent #{d}: {s}", .{ target_id, file_path });
            fatal("travel failed: {}", .{e});
        };
        out("back to #{d} · {s}\n", .{ target_id, file_path });
        return;
    }

    // Remove any existing <auto> dent (unless it's our target)
    removeAutoDent(allocator, &r, target_id);

    // Auto-save current state
    const auto_id = r.save("<auto>") catch |e| fatal("could not leave a dent before travel: {}", .{e});

    if (isDuplicateDent(allocator, &r, auto_id)) {
        removeDuplicateDent(&r, auto_id);
    } else {
        out("dent #{d} · <auto> · left before travel\n", .{auto_id});
    }

    r.restore(target_id) catch |e| fatal("travel failed: {}", .{e});
    out("back to #{d} · restored\n", .{target_id});
}

fn removeAutoDent(allocator: std.mem.Allocator, r: *repo_mod.Repo, skip_id: u32) void {
    const manifests = r.list() catch return;
    defer {
        for (manifests) |m| if (m.name.len > 0) allocator.free(m.name);
        allocator.free(manifests);
    }
    for (manifests) |m| {
        if (m.id == skip_id) continue;
        if (std.mem.eql(u8, m.name, "<auto>")) {
            var name_buf: [32]u8 = undefined;
            const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{m.id}) catch continue;
            r.manifests_dir.deleteFile(io(), filename) catch {};
            // Update latest if this was the top
            const head = manifest_mod.readHead(r.cp_dir, io()) catch continue;
            if (head) |h| {
                if (h == m.id and m.id > 1)
                    manifest_mod.writeHead(r.cp_dir, io(), m.id - 1) catch {};
            }
        }
    }
}

fn doNote(allocator: std.mem.Allocator, id: u32, note: []const u8) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no dents yet; leave one with `dent`", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    const m = manifest_mod.read(allocator, r.manifests_dir, io(), id) catch |err| {
        if (err == error.FileNotFound) fatal("dent #{d} not found", .{id});
        fatal("failed to read dent #{d}: {}", .{ id, err });
    };
    defer if (m.name.len > 0) allocator.free(m.name);

    manifest_mod.write(r.manifests_dir, io(), .{
        .id = m.id,
        .timestamp = m.timestamp,
        .file_count = m.file_count,
        .total_size = m.total_size,
        .name = note,
        .tree_hash = m.tree_hash,
    }) catch |e| fatal("failed to update note: {}", .{e});

    out("noted #{d} · {s}\n", .{ id, note });
}

fn doErase(allocator: std.mem.Allocator, id: u32) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no dents yet; leave one with `dent`", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    // Check manifest exists
    _ = manifest_mod.read(allocator, r.manifests_dir, io(), id) catch |err| {
        if (err == error.FileNotFound) fatal("dent #{d} not found", .{id});
        fatal("failed to read dent #{d}: {}", .{ id, err });
    };

    // Delete the manifest file
    var name_buf: [32]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{id}) catch unreachable;
    r.manifests_dir.deleteFile(io(), filename) catch |e| fatal("failed to erase dent #{d}: {}", .{ id, e });

    // If this was latest, update to previous existing manifest
    const head = manifest_mod.readHead(r.cp_dir, io()) catch null;
    if (head) |h| {
        if (h == id) {
            var prev = id;
            while (prev > 1) {
                prev -= 1;
                var check_buf: [32]u8 = undefined;
                const check_name = std.fmt.bufPrint(&check_buf, "{d}.manifest", .{prev}) catch continue;
                if (r.manifests_dir.statFile(io(), check_name, .{})) |_| {
                    manifest_mod.writeHead(r.cp_dir, io(), prev) catch {};
                    break;
                } else |_| continue;
            }
        }
    }

    out("erased #{d} · working files unchanged\n", .{id});
}

fn doDiff(allocator: std.mem.Allocator, id: ?u32, path: ?[]const u8) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no dents yet; leave one with `dent`", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    // Resolve which dent we're comparing against
    const resolved_id = if (id) |i| i else blk: {
        const head = manifest_mod.readHead(r.cp_dir, io()) catch fatal("failed to read latest", .{});
        break :blk head orelse fatal("no dents yet; leave one with `dent`", .{});
    };

    var result = r.diff(resolved_id) catch |e| fatal("diff failed: {}", .{e});
    defer result.deinit();

    if (path) |p| {
        // Read the file as it was in this dent
        const old_content = r.readSnapshotFile(resolved_id, p) catch |e| fatal("failed to read file from dent: {}", .{e});
        defer if (old_content) |c| allocator.free(c);

        // Read current working tree version
        const current: ?[]u8 = blk: {
            break :blk cwd.readFileAlloc(io(), p, allocator, .limited(256 * 1024 * 1024)) catch null;
        };
        defer if (current) |c| allocator.free(c);

        if (old_content == null and current == null) {
            out("{s}: not found in dent or working files\n", .{p});
            return;
        }

        const old_text: []const u8 = old_content orelse "";
        const new_text: []const u8 = current orelse "";

        if (std.mem.eql(u8, old_text, new_text)) {
            out("{s}: no changes\n", .{p});
            return;
        }

        out("--- #{d} {s}\n", .{ resolved_id, p });
        out("+++ current {s}\n", .{p});
        printSimpleDiff(allocator, old_text, new_text);
        return;
    }

    // Header: which dent
    out("since #{d} · working changes\n", .{resolved_id});

    if (result.added.len == 0 and result.removed.len == 0 and result.modified.len == 0) {
        out("no changes\n", .{});
        return;
    }

    for (result.added) |p| out("  + {s}\n", .{p});
    for (result.removed) |p| out("  - {s}\n", .{p});
    for (result.modified) |p| out("  ~ {s}\n", .{p});
}

fn doList(allocator: std.mem.Allocator, recent: ?u32) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no dents yet; leave one with `dent`", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    const manifests = r.list() catch |e| fatal("list failed: {}", .{e});
    defer {
        for (manifests) |m| {
            if (m.name.len > 0) allocator.free(m.name);
        }
        allocator.free(manifests);
    }

    if (manifests.len == 0) {
        out("no dents yet · leave one with `dent`\n", .{});
        return;
    }

    // Print full path of dent storage
    out("trail · {s}/.dent-files/\n", .{repo_path});

    // Print newest first, limited by recent
    const show_count = if (recent) |n| @min(n, manifests.len) else manifests.len;
    out("{d} of {d} dents · newest first\n\n", .{ show_count, manifests.len });
    var i = manifests.len;
    var shown: usize = 0;
    while (i > 0 and shown < show_count) {
        i -= 1;
        shown += 1;
        const m = manifests[i];
        const name_display: []const u8 = if (m.name.len > 0) m.name else "(no note)";
        const ts = formatTimestamp(m.timestamp);
        const size = formatSize(m.total_size);
        out("#{d} · {s}\n", .{ m.id, name_display });
        out("  {s} UTC · {d} files · {s}\n", .{
            @as([]const u8, &ts),
            m.file_count,
            std.mem.trim(u8, &size, " "),
        });
    }
}

fn doCleanup(allocator: std.mem.Allocator, keep: u32) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no dents yet; leave one with `dent`", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();
    const deleted = r.pruneKeepLast(keep) catch |e| fatal("cleanup failed: {}", .{e});
    if (deleted == 0) {
        out("trail unchanged · nothing to erase\n", .{});
    } else {
        out("erased {d} dents · kept last {d}\n", .{ deleted, keep });
    }
}

fn doEraseAll(allocator: std.mem.Allocator) void {
    const cwd = openCwd();
    defer cwd.close(io());
    var r = repo_mod.Repo.open(allocator, cwd, io()) catch |err| {
        if (err == error.NotInitialized) fatal("no dents yet; leave one with `dent`", .{});
        fatal("failed to open repo: {}", .{err});
    };
    defer r.deinit();

    const manifests = r.list() catch |e| fatal("list failed: {}", .{e});
    defer {
        for (manifests) |m| if (m.name.len > 0) allocator.free(m.name);
        allocator.free(manifests);
    }

    if (manifests.len == 0) {
        out("trail empty · nothing to erase\n", .{});
        return;
    }

    out("erase all {d} dents? This erases your dent trail, not working files. [y/N] ", .{manifests.len});

    var buf: [16]u8 = undefined;
    const n = std.c.read(0, &buf, buf.len);
    if (n <= 0) fatal("aborted", .{});
    const answer = std.mem.trimEnd(u8, buf[0..@intCast(n)], "\n\r \t");
    if (!std.mem.eql(u8, answer, "y") and !std.mem.eql(u8, answer, "Y")) {
        out("cancelled · trail unchanged\n", .{});
        return;
    }

    for (manifests) |m| {
        var name_buf: [32]u8 = undefined;
        const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{m.id}) catch continue;
        r.manifests_dir.deleteFile(io(), filename) catch {};
    }

    // Remove pack and latest
    r.cp_dir.deleteFile(io(), "latest") catch {};
    r.cp_dir.deleteFile(io(), "pack.dat") catch {};
    r.cp_dir.deleteFile(io(), "pack.idx") catch {};

    out("erased all {d} dents · working files unchanged\n", .{manifests.len});
}

fn formatSize(bytes: u64) [8]u8 {
    var buf: [8]u8 = .{' '} ** 8;
    if (bytes == 0) {
        _ = std.fmt.bufPrint(&buf, "   0B   ", .{}) catch {};
    } else if (bytes < 1024) {
        _ = std.fmt.bufPrint(&buf, "{d:>4}B   ", .{bytes}) catch {};
    } else if (bytes < 1024 * 1024) {
        _ = std.fmt.bufPrint(&buf, "{d:>4}KB  ", .{bytes / 1024}) catch {};
    } else if (bytes < 1024 * 1024 * 1024) {
        _ = std.fmt.bufPrint(&buf, "{d:>4}MB  ", .{bytes / (1024 * 1024)}) catch {};
    } else {
        _ = std.fmt.bufPrint(&buf, "{d:>4}GB  ", .{bytes / (1024 * 1024 * 1024)}) catch {};
    }
    return buf;
}

fn formatTimestamp(unix: u64) [16]u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = unix };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    const hour = ds.getHoursIntoDay();
    const minute = ds.getMinutesIntoHour();

    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        yd.year,
        @as(u32, md.month.numeric()),
        @as(u32, md.day_index + 1),
        hour,
        minute,
    }) catch unreachable;
    return buf;
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) []const []const u8 {
    if (text.len == 0) return &.{};

    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    if (text[text.len - 1] != '\n') count += 1;

    const lines = allocator.alloc([]const u8, count) catch return &.{};

    var idx: usize = 0;
    var start: usize = 0;
    for (text, 0..) |c, j| {
        if (c == '\n') {
            lines[idx] = text[start..j];
            idx += 1;
            start = j + 1;
        }
    }
    if (start < text.len) {
        lines[idx] = text[start..];
    }
    return lines;
}

fn printSimpleDiff(allocator: std.mem.Allocator, old_text: []const u8, new_text: []const u8) void {
    const old_lines = splitLines(allocator, old_text);
    defer allocator.free(old_lines);
    const new_lines = splitLines(allocator, new_text);
    defer allocator.free(new_lines);

    const old_len = old_lines.len;
    const new_len = new_lines.len;

    // If too large for O(n*m), fall back to simple output
    if (old_len * new_len > 1_000_000) {
        for (old_lines) |line| out("-{s}\n", .{line});
        for (new_lines) |line| out("+{s}\n", .{line});
        return;
    }

    const matrix = allocator.alloc(u32, (old_len + 1) * (new_len + 1)) catch {
        for (old_lines) |line| out("-{s}\n", .{line});
        for (new_lines) |line| out("+{s}\n", .{line});
        return;
    };
    defer allocator.free(matrix);

    // lcs[i][j] = LCS length of old[i..] and new[j..]
    for (0..old_len + 1) |ii| matrix[ii * (new_len + 1) + new_len] = 0;
    for (0..new_len + 1) |jj| matrix[old_len * (new_len + 1) + jj] = 0;

    var oi = old_len;
    while (oi > 0) {
        oi -= 1;
        var ni = new_len;
        while (ni > 0) {
            ni -= 1;
            if (std.mem.eql(u8, old_lines[oi], new_lines[ni])) {
                matrix[oi * (new_len + 1) + ni] = matrix[(oi + 1) * (new_len + 1) + (ni + 1)] + 1;
            } else {
                const a = matrix[(oi + 1) * (new_len + 1) + ni];
                const b = matrix[oi * (new_len + 1) + (ni + 1)];
                matrix[oi * (new_len + 1) + ni] = if (a > b) a else b;
            }
        }
    }

    // Traceback into ops array
    const CONTEXT = 3;
    const DiffOp = enum { keep, remove, add };
    const ops = allocator.alloc(DiffOp, old_len + new_len) catch return;
    defer allocator.free(ops);
    const op_lines = allocator.alloc([]const u8, old_len + new_len) catch return;
    defer allocator.free(op_lines);
    var op_count: usize = 0;

    var oi2: usize = 0;
    var ni2: usize = 0;
    while (oi2 < old_len or ni2 < new_len) {
        if (oi2 < old_len and ni2 < new_len and std.mem.eql(u8, old_lines[oi2], new_lines[ni2])) {
            ops[op_count] = .keep;
            op_lines[op_count] = old_lines[oi2];
            op_count += 1;
            oi2 += 1;
            ni2 += 1;
        } else if (oi2 < old_len and (ni2 >= new_len or matrix[(oi2 + 1) * (new_len + 1) + ni2] >= matrix[oi2 * (new_len + 1) + (ni2 + 1)])) {
            ops[op_count] = .remove;
            op_lines[op_count] = old_lines[oi2];
            op_count += 1;
            oi2 += 1;
        } else {
            ops[op_count] = .add;
            op_lines[op_count] = new_lines[ni2];
            op_count += 1;
            ni2 += 1;
        }
    }

    // Print with context lines (unified diff style)
    var idx: usize = 0;
    while (idx < op_count) {
        if (ops[idx] == .keep) { idx += 1; continue; }

        const hunk_start = if (idx >= CONTEXT) idx - CONTEXT else 0;
        var print_idx = hunk_start;

        var end = idx;
        while (end < op_count) {
            if (ops[end] != .keep) { end += 1; continue; }
            var keep_run: usize = 0;
            var scan = end;
            while (scan < op_count and ops[scan] == .keep) { keep_run += 1; scan += 1; }
            if (keep_run > CONTEXT * 2) { end += CONTEXT; break; }
            end = scan;
        }
        if (end > op_count) end = op_count;

        while (print_idx < end) {
            switch (ops[print_idx]) {
                .keep => out(" {s}\n", .{op_lines[print_idx]}),
                .remove => out("-{s}\n", .{op_lines[print_idx]}),
                .add => out("+{s}\n", .{op_lines[print_idx]}),
            }
            print_idx += 1;
        }
        idx = end;
    }
}

fn parseOptionalId(arg: ?[]const u8) ?u32 {
    const a = arg orelse return null;
    if (!isNumeric(a)) return null;
    return std.fmt.parseInt(u32, a, 10) catch null;
}

fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}
