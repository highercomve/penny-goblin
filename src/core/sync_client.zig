const std = @import("std");
const ledger_mod = @import("ledger.zig");
const records = @import("sync_records.zig");
const state = @import("sync_state.zig");
const types = state.types;

pub fn consume(db: ledger_mod.Ledger, arena: std.mem.Allocator, reply: types.Reply) !void {
    if (reply.version != 1 or reply.changes.len > state.max_operations or reply.acknowledgements.len > state.max_operations or reply.cursor < reply.from_cursor) return error.InvalidSyncReply;
    try db.db.exec("BEGIN IMMEDIATE; UPDATE sync_context SET suppress=1 WHERE id=1;");
    errdefer db.db.exec("ROLLBACK") catch {};
    if (!std.mem.eql(u8, reply.server_id, try state.peer(db, arena))) return error.WrongDesktopIdentity;
    const cursor = try state.cursor(db);
    if (reply.from_cursor != cursor) {
        if (reply.cursor <= cursor) {
            try db.db.exec("UPDATE sync_context SET suppress=0 WHERE id=1; COMMIT;");
            return;
        }
        return error.SyncCursorMismatch;
    }
    var bytes: usize = 0;
    for (reply.acknowledgements) |ack| {
        bytes += ack.payload.len;
        if (bytes > state.max_bytes) return error.SyncPayloadTooLarge;
        try acknowledge(db, arena, ack);
    }
    var previous = cursor;
    for (reply.changes) |change| {
        if (change.sequence <= previous or change.sequence > reply.cursor or change.revision < 1) return error.InvalidSyncReply;
        previous = change.sequence;
        bytes += change.payload.len;
        if (bytes > state.max_bytes) return error.SyncPayloadTooLarge;
        try receive(db, arena, change);
    }
    const update = try db.db.prepare("UPDATE sync_client SET cursor=?1,last_success=unixepoch() WHERE id=1");
    defer update.finalize();
    try update.bindInt(1, reply.cursor);
    _ = try update.step();
    try db.db.exec("UPDATE sync_context SET suppress=0 WHERE id=1; COMMIT;");
}

fn acknowledge(db: ledger_mod.Ledger, arena: std.mem.Allocator, ack: types.Ack) !void {
    const key: types.Key = .{ .kind = ack.kind, .id = ack.id };
    try records.validate_key(key);
    if (ack.revision < 0 or (ack.accepted and ack.revision == 0)) return error.InvalidSyncReply;
    const query = try db.db.prepare("SELECT kind,id FROM sync_outbox WHERE operation_id=?1");
    defer query.finalize();
    try query.bindText(1, ack.operation_id);
    if (!try query.step()) return;
    if (try state.kind(try query.text(arena, 0)) != key.kind or !std.mem.eql(u8, try query.text(arena, 1), key.id)) return error.InvalidSyncReply;
    const current = try records.snapshot(db, arena, key);
    const pending = try state.has(db, "SELECT 1 FROM sync_pending WHERE kind=?1 AND id=?2", key);
    if (!ack.accepted) {
        try state.conflict(db, key, current, .{ .revision = ack.revision, .payload = ack.payload }, ack.reason);
        try state.key_exec(db, "INSERT INTO sync_pending VALUES(?1,?2) ON CONFLICT(kind,id) DO NOTHING", key);
    } else if (!pending and !std.mem.eql(u8, current, ack.payload)) {
        try records.materialize(db, arena, key, ack.payload);
    }
    try state.put(db, .base, key, .{ .revision = ack.revision, .payload = ack.payload });
    try state.delete_operation(db, ack.operation_id);
}

fn receive(db: ledger_mod.Ledger, arena: std.mem.Allocator, change: types.Change) !void {
    const key: types.Key = .{ .kind = change.kind, .id = change.id };
    try records.validate_key(key);
    const base = try state.read(db, arena, .base, key);
    if (base != null and change.revision <= base.?.revision) return;
    const dirty = try state.has(db, "SELECT 1 FROM sync_pending WHERE kind=?1 AND id=?2 UNION ALL SELECT 1 FROM sync_outbox WHERE kind=?1 AND id=?2 UNION ALL SELECT 1 FROM sync_conflicts WHERE kind=?1 AND id=?2", key);
    const current = records.snapshot(db, arena, key) catch |err| switch (err) {
        error.ExpenseNotFound, error.MissingDependency => "null",
        else => return err,
    };
    const remote: types.Entry = .{ .revision = change.revision, .payload = change.payload };
    if (dirty and !std.mem.eql(u8, current, change.payload)) {
        try state.conflict(db, key, current, remote, "ConcurrentEdit");
    } else if (!std.mem.eql(u8, current, change.payload)) {
        try db.db.exec("SAVEPOINT incoming_change");
        records.materialize(db, arena, key, change.payload) catch |err| {
            try db.db.exec("ROLLBACK TO incoming_change; RELEASE incoming_change;");
            switch (err) {
                error.EvidenceConflict, error.ImmutableSourceConflict, error.CannotRestoreDeleted, error.MissingDependency => {
                    try state.conflict(db, key, current, remote, @errorName(err));
                    try state.put(db, .base, key, remote);
                    return;
                },
                else => return err,
            }
        };
        try db.db.exec("RELEASE incoming_change");
    } else if (dirty) {
        try state.key_exec(db, "DELETE FROM sync_pending WHERE kind=?1 AND id=?2", key);
    }
    try state.put(db, .base, key, remote);
}
