const std = @import("std");
const ledger = @import("ledger.zig");
pub const state = @import("sync_state.zig");
pub const server = @import("sync_server.zig");
pub const client = @import("sync_client.zig");
pub const records = @import("sync_records.zig");
pub const resolution = @import("sync_resolution.zig");

fn round_trip(desktop: ledger.Ledger, phone: ledger.Ledger, a: std.mem.Allocator) !void {
    const request = try state.prepare(phone, a);
    try client.consume(phone, a, try server.exchange(desktop, a, request));
}

test "independent ledgers converge with durable retries and edits during a lost response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const desktop = try ledger.Ledger.open(":memory:");
    defer desktop.close();
    const phone = try ledger.Ledger.open(":memory:");
    defer phone.close();
    try state.pair(phone, a, try state.identity(desktop, a));
    var row: ledger.Expense = .{ .id = &ledger.model.digest("sync-proof"), .date = "2026-10-16", .amount = 40000, .payee = "Original" };
    _ = try phone.save(a, .{ .expense = row });
    const request = try state.prepare(phone, a);
    _ = try server.exchange(desktop, a, request); // Reply is lost.
    row.payee = "Corrected offline";
    _ = try phone.save(a, .{ .expense = row, .expected_revision = 1 });
    try round_trip(desktop, phone, a);
    try round_trip(desktop, phone, a);
    try std.testing.expectEqual(@as(usize, 1), (try desktop.list(a)).len);
    try std.testing.expectEqualStrings(row.payee, (try desktop.list(a))[0].payee);
    try std.testing.expectEqual(@as(i64, 0), try phone.db.scalarInt("SELECT count(*) FROM sync_conflicts"));
    try std.testing.expectEqual(@as(i64, 2), try desktop.db.scalarInt("SELECT count(*) FROM sync_receipts"));
}

test "concurrent offline edits remain visible and deletion is not resurrected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const desktop = try ledger.Ledger.open(":memory:");
    defer desktop.close();
    const phone = try ledger.Ledger.open(":memory:");
    defer phone.close();
    try state.pair(phone, a, try state.identity(desktop, a));
    const row: ledger.Expense = .{ .id = &ledger.model.digest("conflict"), .date = "2026-10-16", .amount = 1000, .payee = "Initial" };
    _ = try desktop.save(a, .{ .expense = row });
    try round_trip(desktop, phone, a);
    var mobile = (try phone.list(a))[0];
    mobile.notes = "Phone correction";
    _ = try phone.save(a, .{ .expense = mobile, .expected_revision = mobile.revision });
    const local = (try desktop.list(a))[0];
    try desktop.remove(local.id, local.revision);
    try round_trip(desktop, phone, a);
    try std.testing.expectEqual(@as(usize, 0), (try desktop.list(a)).len);
    try std.testing.expectEqualStrings(mobile.notes, (try phone.list(a))[0].notes);
    try std.testing.expectEqual(@as(i64, 1), try phone.db.scalarInt("SELECT count(*) FROM sync_conflicts"));
    try std.testing.expectError(error.CannotRestoreDeleted, resolution.resolve(phone, a, .{ .kind = .expense, .id = row.id }, true));
    try resolution.resolve(phone, a, .{ .kind = .expense, .id = row.id }, false);
    try std.testing.expectEqual(@as(usize, 0), (try phone.list(a)).len);
    try std.testing.expectEqual(@as(i64, 1), try phone.db.scalarInt("SELECT count(*) FROM sync_resolutions"));
}

test "one image captured on two devices cannot duplicate desktop spending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const desktop = try ledger.Ledger.open(":memory:");
    defer desktop.close();
    const phone = try ledger.Ledger.open(":memory:");
    defer phone.close();
    try state.pair(phone, a, try state.identity(desktop, a));
    var row: ledger.Expense = .{ .id = &ledger.model.digest("desktop capture"), .date = "2026-10-16", .amount = 40000, .payee = "Voucher" };
    const document: ledger.model.Document = .{ .data_url = "data:image/png;base64,iVBORw0KGgo=" };
    _ = try desktop.save(a, .{ .expense = row, .document = document });
    row.id = &ledger.model.digest("phone capture");
    _ = try phone.save(a, .{ .expense = row, .document = document });
    try round_trip(desktop, phone, a);
    try std.testing.expectEqual(@as(usize, 1), (try desktop.list(a)).len);
    const remote_id = (try desktop.list(a))[0].id;
    try std.testing.expectEqual(@as(usize, 2), (try resolution.status(phone, a)).conflicts.len);
    try resolution.resolve(phone, a, .{ .kind = .expense, .id = remote_id }, false);
    try round_trip(desktop, phone, a);
    try std.testing.expectEqual(@as(usize, 1), (try desktop.list(a)).len);
    try std.testing.expectEqual(@as(usize, 1), (try phone.list(a)).len);
    try std.testing.expectEqual(remote_id.len, (try phone.list(a))[0].id.len);
    try std.testing.expectEqualStrings(remote_id, (try phone.list(a))[0].id);
}
