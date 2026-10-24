//! Isolated Linux WebKit browser; the banking page never receives app IPC.
const std = @import("std");
const oriel = @import("oriel");
var mutex: std.Io.Mutex = .init;

pub fn capture(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    if (comptime oriel.target.os != .linux or oriel.target.is_android) return error.SantanderDesktopOnly;
    if (!mutex.tryLock()) return error.SantanderBrowserBusy;
    defer mutex.unlock(io);
    const result = std.process.run(a, io, .{
        .argv = &.{ try @import("runtime_helper.zig").browser_path(io, a), "--santander" },
        .stdout_limit = .limited(2 * 1024 * 1024 + 1024),
        .stderr_limit = .limited(128 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(15 * 60 + 10), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            std.log.err("Santander browser launch: {s}", .{@errorName(err)});
            return error.SantanderBrowserUnavailable;
        },
    };
    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("Santander browser terminated: {any}; stdout={d}, stderr={d} bytes", .{ result.term, result.stdout.len, result.stderr.len });
        return error.SantanderBrowserUnavailable;
    }
    const reply = try std.json.parseFromSliceLeaky(struct {
        response: ?std.json.Value = null,
        @"error": []const u8 = "",
    }, a, result.stdout, .{});
    if (std.mem.eql(u8, reply.@"error", "Cancelled")) return error.SantanderCancelled;
    if (std.mem.eql(u8, reply.@"error", "SantanderLoginTimedOut")) return error.SantanderLoginTimedOut;
    if (reply.response == null) return error.SantanderBrowserUnavailable;
    return std.json.Stringify.valueAlloc(a, reply.response.?, .{});
}
