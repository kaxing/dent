const std = @import("std");
const Hash = @import("hash.zig").Hash;

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const MAGIC = "CKP\x01";
pub const MAX_NOTE_BYTES = 446;

pub const Manifest = struct {
    id: u32,
    timestamp: u64, // unix seconds UTC
    file_count: u32,
    total_size: u64, // total bytes across all files
    name: []const u8, // empty if unnamed
    tree_hash: Hash,
};

pub fn write(dir: Dir, io: Io, m: Manifest) !void {
    if (m.name.len > MAX_NOTE_BYTES) return error.NoteTooLong;
    var name_buf: [32]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{m.id}) catch unreachable;

    var tmp_buf: [40]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{filename});

    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    @memcpy(buf[pos..][0..4], MAGIC);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 2, .little); // version 2
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], m.id, .little);
    pos += 4;
    std.mem.writeInt(u64, buf[pos..][0..8], m.timestamp, .little);
    pos += 8;
    std.mem.writeInt(u32, buf[pos..][0..4], m.file_count, .little);
    pos += 4;
    std.mem.writeInt(u64, buf[pos..][0..8], m.total_size, .little);
    pos += 8;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(m.name.len), .little);
    pos += 2;
    if (m.name.len > 0) {
        @memcpy(buf[pos..][0..m.name.len], m.name);
        pos += m.name.len;
    }
    @memcpy(buf[pos..][0..32], &m.tree_hash);
    pos += 32;

    const file = try dir.createFile(io, tmp_name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, buf[0..pos]);
    try Dir.rename(dir, tmp_name, dir, filename, io);
}

pub fn read(allocator: std.mem.Allocator, dir: Dir, io: Io, id: u32) !Manifest {
    var name_buf: [32]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "{d}.manifest", .{id}) catch unreachable;

    const file = dir.openFile(io, filename, .{}) catch |err| return err;
    defer file.close(io);

    var buf: [512]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    if (n < 58) return error.InvalidManifest;

    var pos: usize = 0;

    if (!std.mem.eql(u8, buf[0..4], MAGIC)) return error.InvalidManifest;
    pos += 4;

    const version = std.mem.readInt(u32, buf[pos..][0..4], .little);
    if (version != 1 and version != 2) return error.UnsupportedVersion;
    if (n < @as(usize, if (version == 2) 66 else 58)) return error.InvalidManifest;
    pos += 4;

    var m: Manifest = undefined;
    m.id = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    m.timestamp = std.mem.readInt(u64, buf[pos..][0..8], .little);
    pos += 8;
    m.file_count = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;

    if (version >= 2) {
        m.total_size = std.mem.readInt(u64, buf[pos..][0..8], .little);
        pos += 8;
    } else {
        m.total_size = 0;
    }

    const name_len = std.mem.readInt(u16, buf[pos..][0..2], .little);
    pos += 2;
    if (name_len > n - pos - 32) return error.InvalidManifest;
    if (name_len > 0) {
        m.name = try allocator.dupe(u8, buf[pos..][0..name_len]);
        pos += name_len;
    } else {
        m.name = "";
    }

    @memcpy(&m.tree_hash, buf[pos..][0..32]);
    return m;
}

pub fn readHead(dir: Dir, io: Io) !?u32 {
    const file = dir.openFile(io, "latest", .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close(io);

    var buf: [32]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    if (n == 0) return null;

    return std.fmt.parseInt(u32, std.mem.trimEnd(u8, buf[0..n], "\n \t"), 10) catch return error.InvalidHead;
}

pub fn writeHead(dir: Dir, io: Io, id: u32) !void {
    var buf: [32]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "{d}\n", .{id}) catch unreachable;

    const tmp = try dir.createFile(io, "latest.tmp", .{});
    defer tmp.close(io);
    try tmp.writeStreamingAll(io, content);

    try Dir.rename(dir, "latest.tmp", dir, "latest", io);
}
