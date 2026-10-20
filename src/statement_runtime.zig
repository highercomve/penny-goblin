const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");
const statements = @import("core/statements.zig");
var mutex: std.Io.Mutex = .init;

pub fn parse(io: std.Io, arena: std.mem.Allocator, data_url: []const u8, settings: []const u8) !statements.Parsed {
    if (comptime oriel.target.is_android or oriel.target.is_ios) return error.StatementQueuedForDesktop;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const root = try oriel.paths.appData(arena, .{ .name = app.build.id });
    const directory = try std.fs.path.join(arena, &.{ root, "statement-helper" });
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const helper = try @import("runtime_helper.zig").path(io, arena);
    const pdf = try @import("private_file.zig").create(io, arena, try std.fs.path.join(arena, &.{ directory, "input.pdf" }), try statements.pdf_bytes(arena, data_url), false);
    defer std.Io.Dir.cwd().deleteFile(io, pdf) catch {};
    const config = try @import("private_file.zig").create(io, arena, try std.fs.path.join(arena, &.{ directory, "settings.json" }), settings, false);
    defer std.Io.Dir.cwd().deleteFile(io, config) catch {};
    const result = try std.process.run(arena, io, .{
        .argv = &.{ helper, pdf, config },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(90), .clock = .awake } },
    });
    if (result.term != .exited or result.term.exited != 0) return error.StatementParseFailed;
    return std.json.parseFromSliceLeaky(statements.Parsed, arena, result.stdout, .{});
}
