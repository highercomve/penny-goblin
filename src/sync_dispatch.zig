//! The same bounded domain entry point for local pipes and Android workers.
const std = @import("std");
const ledger_mod = @import("core/ledger.zig");
const sync = @import("core/sync.zig");
const types = @import("core/sync_types.zig");
const sql = @import("oriel").sql;
const Request = struct {
    action: enum { identity, prepare, consume, exchange, pair, status, conflict, resolve, recover, research_apply },
    edit: ?@import("core/categorization.zig").Apply = null,
    request: ?types.Request = null,
    reply: ?types.Reply = null,
    server_id: []const u8 = "",
    kind: ?types.Kind = null,
    id: []const u8 = "",
    keep_local: bool = false,
};

pub fn handle(arena: std.mem.Allocator, path: []const u8, input: []const u8) ![]const u8 {
    var detail: []const u8 = "";
    const value = dispatch(arena, path, input, &detail) catch |err| return sync.records.encode(arena, .{ .ok = false, .err = @errorName(err), .detail = detail });
    // The value is JSON, not an escaped string; both transports decode it once.
    return std.fmt.allocPrint(arena, "{{\"ok\":true,\"value\":{s}}}", .{value});
}

fn dispatch(arena: std.mem.Allocator, path: []const u8, input: []const u8, detail: *[]const u8) ![]const u8 {
    if (input.len > 64 * 1024 * 1024) return error.SyncPayloadTooLarge;
    const args = try sync.records.decode(Request, arena, input);
    const db = try ledger_mod.Ledger.open(try arena.dupeZ(u8, path));
    defer db.close();
    return run(db, arena, args) catch |err| {
        // SQLite's message names the failing condition (e.g. busy, disk I/O), never record values.
        detail.* = arena.dupe(u8, std.mem.span(sql.c.sqlite3_errmsg(db.db.handle))) catch "";
        return err;
    };
}

fn run(db: ledger_mod.Ledger, arena: std.mem.Allocator, args: Request) ![]const u8 {
    switch (args.action) {
        .research_apply => return sync.records.encode(arena, try @import("core/categorization.zig").apply(db, arena, args.edit orelse return error.MissingRequest)),
        .identity => return sync.records.encode(arena, .{ .device_id = try sync.state.identity(db, arena) }),
        .prepare => return sync.records.encode(arena, try sync.state.prepare(db, arena)),
        .exchange => return sync.records.encode(arena, try sync.server.exchange(db, arena, args.request orelse return error.MissingRequest)),
        .consume => try sync.client.consume(db, arena, args.reply orelse return error.MissingReply),
        .pair => try sync.state.pair(db, arena, args.server_id),
        .status => return sync.records.encode(arena, try sync.resolution.status(db, arena)),
        .conflict => return sync.records.encode(arena, try sync.resolution.preview(db, arena, .{ .kind = args.kind orelse return error.MissingEntity, .id = args.id })),
        .resolve => try sync.resolution.resolve(db, arena, .{ .kind = args.kind orelse return error.MissingEntity, .id = args.id }, args.keep_local),
        .recover => try sync.resolution.recover(db, args.server_id),
    }
    return "{}";
}

pub fn worker(init: std.process.Init, path: []const u8) !u8 {
    var buffer: [8192]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(init.io, &buffer);
    const arena = init.arena.allocator();
    const input = try reader.interface.allocRemaining(arena, .limited(64 * 1024 * 1024));
    const response = try handle(arena, path, input);
    try std.Io.File.stdout().writeStreamingAll(init.io, response);
    return 0;
}
