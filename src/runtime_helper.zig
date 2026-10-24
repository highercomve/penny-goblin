//! Content-versioned, atomic extraction of the bundled desktop helper.
const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");
const bytes = @import("penny_helper").bytes;

pub fn path(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    return extract(io, arena, bytes);
}

pub fn browser_path(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    return extract(io, arena, @import("penny_helper").browser_bytes);
}

fn extract(io: std.Io, arena: std.mem.Allocator, executable: []const u8) ![]const u8 {
    if (executable.len == 0) return error.DesktopOnly;
    const root = try oriel.paths.appData(arena, .{ .name = app.build.id });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(executable, &digest, .{});
    const name = try std.fmt.allocPrint(arena, "runtime-{s}{s}", .{ std.fmt.bytesToHex(digest, .lower), if (oriel.target.os == .windows) ".exe" else "" });
    const destination = try std.fs.path.join(arena, &.{ root, name });
    std.Io.Dir.cwd().access(io, destination, .{}) catch {
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const temporary = try std.fmt.allocPrint(arena, "{s}-{s}.tmp", .{ destination, std.fmt.bytesToHex(random, .lower) });
        defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        {
            const file = try std.Io.Dir.cwd().createFile(io, temporary, .{ .exclusive = true, .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o700) });
            defer file.close(io);
            try file.writeStreamingAll(io, executable);
            try file.sync(io);
        }
        try std.Io.Dir.cwd().rename(temporary, .cwd(), destination, io);
    };
    return destination;
}
