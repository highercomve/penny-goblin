const std = @import("std");
const ledger_mod = @import("ledger.zig");
const records = @import("sync_records.zig");
pub const types = @import("sync_types.zig");
const sql = @import("oriel").sql;
pub const Table = enum { base, authority };
pub const max_operations = 128;
pub const max_bytes = 60 * 1024 * 1024;

pub fn identity(db: ledger_mod.Ledger, arena: std.mem.Allocator) ![]const u8 {
    const query = try db.db.prepare("SELECT device_id FROM sync_identity WHERE id=1");
    defer query.finalize();
    if (!try query.step()) return error.MissingSyncIdentity;
    return query.text(arena, 0);
}

pub fn read(db: ledger_mod.Ledger, arena: std.mem.Allocator, table: Table, key: types.Key) !?types.Entry {
    const query = try db.db.prepare(switch (table) {
        .base => "SELECT revision,payload FROM sync_base WHERE kind=?1 AND id=?2",
        .authority => "SELECT revision,payload FROM sync_authority WHERE kind=?1 AND id=?2",
    });
    defer query.finalize();
    try bind_key(query, key);
    if (!try query.step()) return null;
    return .{ .revision = query.int(0), .payload = try query.text(arena, 1) };
}

pub fn put(db: ledger_mod.Ledger, table: Table, key: types.Key, entry: types.Entry) !void {
    const query = try db.db.prepare(switch (table) {
        .base => "INSERT INTO sync_base VALUES(?1,?2,?3,?4) ON CONFLICT(kind,id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload",
        .authority => "INSERT INTO sync_authority VALUES(?1,?2,?3,?4) ON CONFLICT(kind,id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload",
    });
    defer query.finalize();
    try bind_key(query, key);
    try query.bindInt(3, entry.revision);
    try query.bindText(4, entry.payload);
    _ = try query.step();
}

pub fn bind_key(query: sql.Stmt, key: types.Key) !void {
    try records.validate_key(key);
    try query.bindText(1, @tagName(key.kind));
    try query.bindText(2, key.id);
}

pub fn key_exec(db: ledger_mod.Ledger, query_text: [:0]const u8, key: types.Key) !void {
    const query = try db.db.prepare(query_text);
    defer query.finalize();
    try bind_key(query, key);
    _ = try query.step();
}

pub fn has(db: ledger_mod.Ledger, query_text: [:0]const u8, key: types.Key) !bool {
    const query = try db.db.prepare(query_text);
    defer query.finalize();
    try bind_key(query, key);
    return query.step();
}

pub fn cursor(db: ledger_mod.Ledger) !i64 {
    return db.db.scalarInt("SELECT cursor FROM sync_client WHERE id=1");
}

pub fn peer(db: ledger_mod.Ledger, arena: std.mem.Allocator) ![]const u8 {
    const query = try db.db.prepare("SELECT server_id FROM sync_client WHERE id=1");
    defer query.finalize();
    _ = try query.step();
    return query.text(arena, 0);
}

pub fn pair(db: ledger_mod.Ledger, arena: std.mem.Allocator, server_id: []const u8) !void {
    if (!ledger_mod.model.valid_id(server_id)) return error.InvalidId;
    try db.db.exec("BEGIN IMMEDIATE");
    errdefer db.db.exec("ROLLBACK") catch {};
    const old = try peer(db, arena);
    if (old.len > 0 and !std.mem.eql(u8, old, server_id)) return error.DifferentPairedDesktop;
    const update = try db.db.prepare("UPDATE sync_client SET server_id=?1 WHERE id=1");
    defer update.finalize();
    try update.bindText(1, server_id);
    _ = try update.step();
    try db.db.exec("COMMIT");
}

pub fn prepare(db: ledger_mod.Ledger, arena: std.mem.Allocator) !types.Request {
    try db.db.exec("BEGIN IMMEDIATE");
    errdefer db.db.exec("ROLLBACK") catch {};
    const request = try prepare_inner(db, arena);
    try db.db.exec("COMMIT");
    return request;
}

pub fn prepare_inner(db: ledger_mod.Ledger, arena: std.mem.Allocator) !types.Request {
    var operations: std.ArrayList(types.Operation) = .empty;
    var byte_count: usize = 0;
    const existing = try db.db.prepare("SELECT operation_id,kind,id,base_revision,payload FROM sync_outbox ORDER BY CASE kind WHEN 'document' THEN 0 WHEN 'statement' THEN 1 WHEN 'observation' THEN 2 WHEN 'expense' THEN 3 ELSE 4 END,id LIMIT 128");
    defer existing.finalize();
    while (try existing.step()) {
        const payload = try existing.text(arena, 4);
        if (byte_count + payload.len > max_bytes and operations.items.len > 0) break;
        byte_count += payload.len;
        try operations.append(arena, .{ .operation_id = try existing.text(arena, 0), .kind = try kind(try existing.text(arena, 1)), .id = try existing.text(arena, 2), .base_revision = existing.int(3), .payload = payload });
    }
    const pending = try db.db.prepare("SELECT p.kind,p.id FROM sync_pending p WHERE NOT EXISTS(SELECT 1 FROM sync_outbox o WHERE o.kind=p.kind AND o.id=p.id) AND NOT EXISTS(SELECT 1 FROM sync_conflicts c WHERE c.kind=p.kind AND c.id=p.id) ORDER BY CASE p.kind WHEN 'document' THEN 0 WHEN 'statement' THEN 1 WHEN 'observation' THEN 2 WHEN 'expense' THEN 3 ELSE 4 END,p.id LIMIT 128");
    defer pending.finalize();
    var keys: std.ArrayList(types.Key) = .empty;
    while (try pending.step()) try keys.append(arena, .{ .kind = try kind(try pending.text(arena, 0)), .id = try pending.text(arena, 1) });
    for (keys.items) |key| {
        if (operations.items.len == max_operations) break;
        const payload = try records.snapshot(db, arena, key);
        if (payload.len > max_bytes) return error.SyncPayloadTooLarge;
        if (byte_count + payload.len > max_bytes) break;
        byte_count += payload.len;
        const base = try read(db, arena, .base, key);
        const op_id = blk: {
            const query = try db.db.prepare("SELECT lower(hex(randomblob(32)))");
            defer query.finalize();
            _ = try query.step();
            break :blk try query.text(arena, 0);
        };
        const operation: types.Operation = .{ .operation_id = op_id, .kind = key.kind, .id = key.id, .base_revision = if (base) |entry| entry.revision else 0, .payload = payload };
        try store_operation(db, operation);
        try key_exec(db, "DELETE FROM sync_pending WHERE kind=?1 AND id=?2", key);
        try operations.append(arena, operation);
    }
    return .{ .device_id = try identity(db, arena), .cursor = try cursor(db), .operations = try operations.toOwnedSlice(arena) };
}

fn store_operation(db: ledger_mod.Ledger, operation: types.Operation) !void {
    const query = try db.db.prepare("INSERT INTO sync_outbox VALUES(?1,?2,?3,?4,?5)");
    defer query.finalize();
    try query.bindText(1, operation.operation_id);
    try query.bindText(2, @tagName(operation.kind));
    try query.bindText(3, operation.id);
    try query.bindInt(4, operation.base_revision);
    try query.bindText(5, operation.payload);
    _ = try query.step();
}

pub fn kind(text: []const u8) !types.Kind {
    return std.meta.stringToEnum(types.Kind, text) orelse error.InvalidSyncEntity;
}

pub fn conflict(db: ledger_mod.Ledger, key: types.Key, local: []const u8, remote: types.Entry, reason: []const u8) !void {
    const query = try db.db.prepare("INSERT INTO sync_conflicts VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(kind,id) DO UPDATE SET local_payload=excluded.local_payload,remote_payload=excluded.remote_payload,remote_revision=excluded.remote_revision,reason=excluded.reason");
    defer query.finalize();
    try bind_key(query, key);
    try query.bindText(3, local);
    try query.bindText(4, remote.payload);
    try query.bindInt(5, remote.revision);
    try query.bindText(6, reason);
    _ = try query.step();
}

pub fn delete_operation(db: ledger_mod.Ledger, operation_id: []const u8) !void {
    const query = try db.db.prepare("DELETE FROM sync_outbox WHERE operation_id=?1");
    defer query.finalize();
    try query.bindText(1, operation_id);
    _ = try query.step();
}

test "outgoing operation remains frozen while a newer local edit stays pending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    var row: ledger_mod.Expense = .{ .id = &ledger_mod.model.digest("offline"), .date = "2026-10-16", .amount = 1000, .payee = "Original" };
    _ = try db.save(a, .{ .expense = row });
    const first = try prepare(db, a);
    try std.testing.expectEqual(@as(usize, 1), first.operations.len);
    row.payee = "Corrected";
    _ = try db.save(a, .{ .expense = row, .expected_revision = 1 });
    const retry = try prepare(db, a);
    try std.testing.expectEqualStrings(first.operations[0].operation_id, retry.operations[0].operation_id);
    try std.testing.expectEqualStrings(first.operations[0].payload, retry.operations[0].payload);
    try std.testing.expectEqual(@as(i64, 1), try db.db.scalarInt("SELECT count(*) FROM sync_pending"));
}
