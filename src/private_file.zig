//! Exclusive private temporary files, with atomic publication when needed.
const std = @import("std");

pub fn create(io: std.Io, a: std.mem.Allocator, prefix: []const u8, data: []const u8, executable: bool) ![]const u8 {
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const path = try std.fmt.allocPrint(a, "{s}-{s}.tmp", .{ prefix, std.fmt.bytesToHex(random, .lower) });
    errdefer a.free(path);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(if (executable) 0o700 else 0o600) });
    defer file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try file.writeStreamingAll(io, data);
    try file.sync(io);
    return path;
}

pub fn publish(io: std.Io, a: std.mem.Allocator, destination: []const u8, data: []const u8, executable: bool) !void {
    const temporary = try create(io, a, destination, data, executable);
    defer a.free(temporary);
    defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try std.Io.Dir.cwd().rename(temporary, .cwd(), destination, io);
}

test "private temporary files have distinct names and owner-only permissions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const prefix = try std.fs.path.join(a, &.{ directory, "input.pdf" });
    defer a.free(prefix);
    const first = try create(io, a, prefix, "%PDF-synthetic", false);
    defer a.free(first);
    const second = try create(io, a, prefix, "settings", false);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const stat = try std.Io.Dir.cwd().statFile(io, first, .{});
    if (@import("builtin").os.tag != .windows) try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}
