//! NDJSON job worker. Its process group owns the browser and model lifetime.
const std = @import("std");
const runtime = @import("research_runtime.zig");
var process_io: std.Io = undefined;
fn emit(event: runtime.Event) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    send(arena.allocator(), .{ .kind = "progress", .value = event }) catch {};
}
fn send(a: std.mem.Allocator, value: anytype) !void {
    const line = try std.fmt.allocPrint(a, "{s}\n", .{try std.json.Stringify.valueAlloc(a, value, .{})});
    try std.Io.File.stdout().writeStreamingAll(process_io, line);
}
fn run(init: std.process.Init, path: []const u8) !void {
    const a = init.arena.allocator();
    var buffer: [8192]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(init.io, &buffer);
    const input = try reader.interface.allocRemaining(a, .limited(2 * 1024 * 1024));
    const args = try std.json.parseFromSliceLeaky(struct { action: enum { status, start }, ids: []const []const u8 = &.{} }, a, input, .{});
    if (args.action == .status) return send(a, .{ .kind = "status", .value = try @import("research_model.zig").status(init.io, a) });
    const db = try @import("core/ledger.zig").Ledger.open(try a.dupeZ(u8, path));
    const preview = @import("research_service.zig").prepare(db, a, args.ids) catch |err| { db.close(); return err; };
    db.close();
    const review = try runtime.run(init.io, a, preview, emit);
    try send(a, .{ .kind = "review", .value = review });
}
pub fn worker(init: std.process.Init, path: []const u8) !u8 {
    if (comptime @import("oriel").target.os == .linux and !@import("oriel").target.is_android) {
        const parent = std.c.getppid();
        if (std.c.prctl(@intFromEnum(std.os.linux.PR.SET_PDEATHSIG), @as(c_ulong, @intFromEnum(std.os.linux.SIG.TERM)), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.ParentWatchFailed;
        if (parent == 1 or std.c.getppid() != parent) return 0;
    }
    process_io = init.io;
    run(init, path) catch |err| try send(init.arena.allocator(), .{ .kind = "error", .@"error" = @errorName(err) });
    return 0;
}
