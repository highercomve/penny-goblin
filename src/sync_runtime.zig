//! Own the desktop transport for precisely the lifetime of the tray app.
const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");
pub const Action = enum { status, start, stop, restart, pairing, revoke };
var mutex: std.Io.Mutex = .init;
var child: ?std.process.Child = null;

pub fn stop(io: std.Io) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    stop_locked(io);
}
fn stop_locked(io: std.Io) void {
    if (child) |*process| process.kill(io);
    child = null;
}

pub fn control(io: std.Io, arena: std.mem.Allocator, action: Action, device: []const u8) ![]const u8 {
    if (comptime oriel.target.is_android or oriel.target.is_ios) return error.DesktopOnly;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (action == .stop) {
        stop_locked(io);
        return "{\"running\":false}";
    }
    if (action == .restart) stop_locked(io);
    const helper = try @import("runtime_helper.zig").path(io, arena);
    const root = try oriel.paths.appData(arena, .{ .name = app.build.id });
    const directory = try std.fs.path.join(arena, &.{ root, "sync" });
    const database = try std.fs.path.join(arena, &.{ root, "ledger.sqlite3" });
    const executable = try std.process.executablePathAlloc(io, arena);
    // Initialize identity before spawning, avoiding concurrent first-run key creation.
    if (action == .start or action == .restart or action == .pairing) {
        if (child == null) {
            _ = try run(io, arena, &.{ helper, "--sync", "status", directory, executable, database });
            child = try std.process.spawn(io, .{
                .argv = &.{ helper, "--sync", "serve", directory, executable, database },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
        }
        if (action != .pairing) return "{\"starting\":true}";
    }
    if (action == .revoke and !@import("core/model.zig").valid_id(device)) return error.InvalidId;
    const mode = if (action == .pairing) "pair" else if (action == .revoke) "revoke" else "status";
    return run(io, arena, if (action == .revoke)
        &.{ helper, "--sync", mode, directory, executable, database, "--device", device }
    else
        &.{ helper, "--sync", mode, directory, executable, database });
}
fn run(io: std.Io, arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    });
    if (result.term != .exited or result.term.exited != 0) return error.SyncServiceFailed;
    return result.stdout;
}
