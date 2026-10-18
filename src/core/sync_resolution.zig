const std = @import("std");
const ledger_mod = @import("ledger.zig");
const records = @import("sync_records.zig");
const state = @import("sync_state.zig");
const types = state.types;
pub const Summary = struct { kind: types.Kind, id: []const u8, reason: []const u8 };
/// `changes` is the newest authoritative change; the desktop UI polls it to
/// notice records that phones synchronized while its window was open.
pub const Status = struct { device_id: []const u8, server_id: []const u8, pending: i64, conflicts: []const Summary, last_success: i64, changes: i64 };

pub fn status(db: ledger_mod.Ledger, arena: std.mem.Allocator) !Status {
    const query = try db.db.prepare("SELECT kind,id,reason FROM sync_conflicts ORDER BY kind,id LIMIT 1001");
    defer query.finalize();
    var rows: std.ArrayList(Summary) = .empty;
    while (try query.step()) {
        if (rows.items.len == 1000) return error.TooManyConflicts;
        try rows.append(arena, .{ .kind = try state.kind(try query.text(arena, 0)), .id = try query.text(arena, 1), .reason = try query.text(arena, 2) });
    }
    return .{ .device_id = try state.identity(db, arena), .server_id = try state.peer(db, arena), .pending = try db.db.scalarInt("SELECT count(*) FROM (SELECT kind,id FROM sync_pending UNION SELECT kind,id FROM sync_outbox)"), .conflicts = try rows.toOwnedSlice(arena), .last_success = try db.db.scalarInt("SELECT last_success FROM sync_client WHERE id=1"), .changes = try db.db.scalarInt("SELECT coalesce(max(sequence),0) FROM sync_log") };
}

pub fn detail(db: ledger_mod.Ledger, arena: std.mem.Allocator, key: types.Key) !types.Conflict {
    const query = try db.db.prepare("SELECT local_payload,remote_payload,remote_revision,reason FROM sync_conflicts WHERE kind=?1 AND id=?2");
    defer query.finalize();
    try state.bind_key(query, key);
    if (!try query.step()) return error.ConflictNotFound;
    return .{ .kind = key.kind, .id = key.id, .local_payload = try query.text(arena, 0), .remote_payload = try query.text(arena, 1), .remote_revision = query.int(2), .reason = try query.text(arena, 3) };
}

pub fn preview(db: ledger_mod.Ledger, arena: std.mem.Allocator, key: types.Key) !types.Conflict {
    var result = try detail(db, arena, key);
    result.local_payload = try redact(arena, result.local_payload);
    result.remote_payload = try redact(arena, result.remote_payload);
    return result;
}
fn redact(arena: std.mem.Allocator, payload: []const u8) ![]const u8 {
    var value = try records.decode(std.json.Value, arena, payload);
    if (value == .object and value.object.contains("data_url")) try value.object.put(arena, "data_url", .{ .string = "Original attachment retained by content hash" });
    return records.encode(arena, value);
}

pub fn recover(db: ledger_mod.Ledger, server_id: []const u8) !void {
    if (!ledger_mod.model.valid_id(server_id)) return error.InvalidId;
    try db.db.exec("BEGIN IMMEDIATE");
    errdefer db.db.exec("ROLLBACK") catch {};
    // Retain the frozen intents and conflict versions before rebuilding a full
    // resync from current local records. Newest local edits stay in those rows.
    try db.db.exec("INSERT INTO sync_resolutions(kind,id,local_payload,remote_payload,choice) SELECT kind,id,payload,'null','recovery-outbox' FROM sync_outbox;");
    try db.db.exec("INSERT INTO sync_resolutions(kind,id,local_payload,remote_payload,choice) SELECT kind,id,local_payload,remote_payload,'recovery-conflict' FROM sync_conflicts;");
    try db.db.exec("DELETE FROM sync_base; DELETE FROM sync_outbox; DELETE FROM sync_conflicts; DELETE FROM sync_pending;");
    try db.db.exec("INSERT INTO sync_pending SELECT 'document',hash FROM documents; INSERT INTO sync_pending SELECT 'statement',hash FROM statements; INSERT INTO sync_pending SELECT 'observation',id FROM observations; INSERT INTO sync_pending SELECT 'expense',id FROM expenses; INSERT INTO sync_pending SELECT 'budget','budget' FROM settings WHERE key='budget';");
    const query = try db.db.prepare("UPDATE sync_client SET server_id=?1,cursor=0,last_success=0 WHERE id=1");
    defer query.finalize();
    try query.bindText(1, server_id);
    _ = try query.step();
    try db.db.exec("COMMIT");
}

pub fn resolve(db: ledger_mod.Ledger, arena: std.mem.Allocator, key: types.Key, keep_local: bool) !void {
    try db.db.exec("BEGIN IMMEDIATE; UPDATE sync_context SET suppress=1 WHERE id=1;");
    errdefer db.db.exec("ROLLBACK") catch {};
    const conflict = try detail(db, arena, key);
    try archive(db, conflict, if (keep_local) "local" else "desktop");
    if (keep_local) {
        if (key.kind == .document or std.mem.eql(u8, conflict.reason, "EvidenceConflict") or std.mem.eql(u8, conflict.reason, "ImmutableSourceConflict")) return error.EvidenceReviewRequired;
        if (key.kind == .expense and !std.mem.eql(u8, conflict.remote_payload, "null")) {
            const remote = try records.decode(records.Payment, arena, conflict.remote_payload);
            const local = try records.decode(records.Payment, arena, try records.snapshot(db, arena, key));
            if (remote.expense.deleted and !local.expense.deleted) return error.CannotRestoreDeleted;
        }
        try clear(db, key);
        try queue(db, key);
    } else {
        if (std.mem.eql(u8, conflict.remote_payload, "null")) {
            if (key.kind != .expense) return error.NoDesktopVersion;
            try discard_unaccepted(db, arena, key.id);
        } else {
            if (key.kind == .expense) try release_local_collisions(db, arena, try records.decode(records.Payment, arena, conflict.remote_payload));
            // Immutable document conflicts retain the losing original in history.
            if (key.kind == .document) {
                const update = try db.db.prepare("UPDATE documents SET extraction=?2 WHERE hash=?1");
                defer update.finalize();
                const remote = try records.decode(struct { data_url: []const u8, extraction: []const u8 }, arena, conflict.remote_payload);
                try update.bindText(1, key.id);
                try update.bindText(2, remote.extraction);
                _ = try update.step();
            }
            try records.materialize(db, arena, key, conflict.remote_payload);
            try clear(db, key);
        }
    }
    try db.db.exec("UPDATE sync_context SET suppress=0 WHERE id=1; COMMIT;");
}

fn clear(db: ledger_mod.Ledger, key: types.Key) !void {
    try state.key_exec(db, "DELETE FROM sync_pending WHERE kind=?1 AND id=?2", key);
    try state.key_exec(db, "DELETE FROM sync_outbox WHERE kind=?1 AND id=?2", key);
    try state.key_exec(db, "DELETE FROM sync_conflicts WHERE kind=?1 AND id=?2", key);
}
fn queue(db: ledger_mod.Ledger, key: types.Key) !void {
    try state.key_exec(db, "INSERT INTO sync_pending VALUES(?1,?2) ON CONFLICT(kind,id) DO NOTHING", key);
}
fn archive(db: ledger_mod.Ledger, conflict: types.Conflict, choice: []const u8) !void {
    const insert = try db.db.prepare("INSERT INTO sync_resolutions(kind,id,local_payload,remote_payload,choice) VALUES(?1,?2,?3,?4,?5)");
    defer insert.finalize();
    try state.bind_key(insert, .{ .kind = conflict.kind, .id = conflict.id });
    try insert.bindText(3, conflict.local_payload);
    try insert.bindText(4, conflict.remote_payload);
    try insert.bindText(5, choice);
    _ = try insert.step();
}

fn discard_unaccepted(db: ledger_mod.Ledger, arena: std.mem.Allocator, id: []const u8) !void {
    const key: types.Key = .{ .kind = .expense, .id = id };
    const base = try state.read(db, arena, .base, key);
    if (base != null and base.?.revision > 0) return error.EvidenceReviewRequired;
    var row = (try db.get(arena, id)) orelse return error.ExpenseNotFound;
    row.deleted = true;
    const images = try db.db.prepare("DELETE FROM evidence WHERE expense_id=?1");
    defer images.finalize();
    try images.bindText(1, id);
    _ = try images.step();
    const observations = try db.db.prepare("UPDATE observations SET expense_id=NULL WHERE expense_id=?1");
    defer observations.finalize();
    try observations.bindText(1, id);
    _ = try observations.step();
    try db.replicate(arena, row);
    try clear(db, key);
    try queue(db, key); // Keep a tombstone even for a rejected offline creation.
}

fn release_local_collisions(db: ledger_mod.Ledger, arena: std.mem.Allocator, remote: records.Payment) !void {
    for (remote.documents) |hash| {
        const query = try db.db.prepare("SELECT expense_id FROM evidence WHERE document_hash=?1");
        defer query.finalize();
        try query.bindText(1, hash);
        if (!try query.step()) continue;
        const owner = try query.text(arena, 0);
        if (std.mem.eql(u8, owner, remote.expense.id)) continue;
        const key: types.Key = .{ .kind = .expense, .id = owner };
        const other = try detail(db, arena, key);
        if (!std.mem.eql(u8, other.remote_payload, "null") or !std.mem.eql(u8, other.reason, "EvidenceConflict")) return error.EvidenceReviewRequired;
        try archive(db, other, "merged-into-desktop-payment");
        try discard_unaccepted(db, arena, owner);
    }
}
