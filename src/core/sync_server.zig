//! Authenticated transport calls this shared domain; it never handles secrets.
const std = @import("std");
const ledger_mod = @import("ledger.zig");
const records = @import("sync_records.zig");
const state = @import("sync_state.zig");
const types = state.types;

pub fn exchange(db: ledger_mod.Ledger, arena: std.mem.Allocator, request: types.Request) !types.Reply {
    if (request.version != 1 or request.cursor < 0 or request.operations.len > state.max_operations or !ledger_mod.model.valid_id(request.device_id)) return error.InvalidSyncRequest;
    try db.db.exec("BEGIN IMMEDIATE; UPDATE sync_context SET suppress=1 WHERE id=1;");
    errdefer db.db.exec("ROLLBACK") catch {};
    try flush_local(db, arena);
    if (request.cursor > try db.db.scalarInt("SELECT coalesce(max(sequence),0) FROM sync_log")) return error.SyncRecoveryRequired;
    var acknowledgements: std.ArrayList(types.Ack) = .empty;
    var bytes: usize = 0;
    for (request.operations) |operation| {
        bytes += operation.payload.len;
        if (bytes > state.max_bytes) return error.SyncPayloadTooLarge;
        try acknowledgements.append(arena, try apply_operation(db, arena, request.device_id, operation, false));
    }
    var changes: std.ArrayList(types.Change) = .empty;
    const query = try db.db.prepare("SELECT sequence,kind,id,revision,payload FROM sync_log WHERE sequence>?1 ORDER BY sequence LIMIT 128");
    defer query.finalize();
    try query.bindInt(1, request.cursor);
    var cursor = request.cursor;
    bytes = 0;
    for (acknowledgements.items) |ack| bytes += ack.payload.len;
    while (try query.step()) {
        const change_kind = try state.kind(try query.text(arena, 1));
        const change_id = try query.text(arena, 2);
        const revision = query.int(3);
        var acknowledged = false;
        for (acknowledgements.items) |ack| {
            if (ack.accepted and ack.kind == change_kind and ack.revision == revision and std.mem.eql(u8, ack.id, change_id)) {
                acknowledged = true;
                break;
            }
        }
        if (acknowledged) {
            cursor = query.int(0);
            continue;
        }
        const payload = try query.text(arena, 4);
        if (bytes + payload.len > state.max_bytes) break;
        bytes += payload.len;
        cursor = query.int(0);
        try changes.append(arena, .{ .sequence = cursor, .kind = change_kind, .id = change_id, .revision = revision, .payload = payload });
    }
    const reply: types.Reply = .{ .server_id = try state.identity(db, arena), .from_cursor = request.cursor, .cursor = cursor, .more = cursor < try db.db.scalarInt("SELECT coalesce(max(sequence),0) FROM sync_log"), .acknowledgements = try acknowledgements.toOwnedSlice(arena), .changes = try changes.toOwnedSlice(arena) };
    try db.db.exec("UPDATE sync_context SET suppress=0 WHERE id=1; COMMIT;");
    return reply;
}

fn flush_local(db: ledger_mod.Ledger, arena: std.mem.Allocator) !void {
    for (0..1000) |_| {
        const request = try state.prepare_inner(db, arena);
        if (request.operations.len == 0) return;
        for (request.operations) |operation| {
            const ack = try apply_operation(db, arena, request.device_id, operation, true);
            const key: types.Key = .{ .kind = operation.kind, .id = operation.id };
            if (ack.accepted) {
                try state.put(db, .base, key, .{ .revision = ack.revision, .payload = ack.payload });
            } else {
                try state.conflict(db, key, try records.snapshot(db, arena, key), .{ .revision = ack.revision, .payload = ack.payload }, ack.reason);
                try state.key_exec(db, "INSERT INTO sync_pending VALUES(?1,?2) ON CONFLICT(kind,id) DO NOTHING", key);
            }
            try state.delete_operation(db, operation.operation_id);
        }
    }
    return error.TooManySyncOperations;
}

fn apply_operation(db: ledger_mod.Ledger, arena: std.mem.Allocator, device_id: []const u8, operation: types.Operation, local: bool) !types.Ack {
    const key: types.Key = .{ .kind = operation.kind, .id = operation.id };
    try records.validate_key(key);
    if (!ledger_mod.model.valid_id(operation.operation_id) or operation.base_revision < 0 or operation.base_revision == std.math.maxInt(i64)) return error.InvalidSyncRequest;
    const digest = ledger_mod.model.digest(try records.encode(arena, operation));
    if (try receipt(db, arena, operation.operation_id, device_id, &digest)) |previous| return previous;
    const current = try state.read(db, arena, .authority, key);
    const revision = if (current) |entry| entry.revision else 0;
    var ack: types.Ack = .{ .operation_id = operation.operation_id, .kind = key.kind, .id = key.id, .accepted = false, .revision = revision, .payload = if (current) |entry| entry.payload else "null", .reason = "RevisionConflict" };
    if (current != null and std.mem.eql(u8, current.?.payload, operation.payload)) {
        ack.accepted = true;
        ack.reason = "";
    } else if (revision == operation.base_revision) {
        try db.db.exec("SAVEPOINT incoming_operation");
        const materialized = blk: {
            if (!local) records.materialize(db, arena, key, operation.payload) catch |err| {
                try db.db.exec("ROLLBACK TO incoming_operation; RELEASE incoming_operation;");
                switch (err) {
                    error.EvidenceConflict, error.ImmutableSourceConflict, error.CannotRestoreDeleted, error.MissingDependency => {
                        ack.reason = @errorName(err);
                        break :blk false;
                    },
                    else => return err,
                }
            };
            try db.db.exec("RELEASE incoming_operation");
            break :blk true;
        };
        if (materialized) {
            ack.accepted = true;
            ack.reason = "";
            ack.revision = revision + 1;
            ack.payload = if (local) operation.payload else try records.snapshot(db, arena, key);
            try state.put(db, .authority, key, .{ .revision = ack.revision, .payload = ack.payload });
            try append_change(db, key, ack.revision, ack.payload);
            try state.put(db, .base, key, .{ .revision = ack.revision, .payload = ack.payload });
        }
    }
    try store_receipt(db, operation.operation_id, device_id, &digest, try records.encode(arena, ack));
    return ack;
}

fn receipt(db: ledger_mod.Ledger, arena: std.mem.Allocator, id: []const u8, device: []const u8, digest: []const u8) !?types.Ack {
    const query = try db.db.prepare("SELECT device_id,digest,result FROM sync_receipts WHERE operation_id=?1");
    defer query.finalize();
    try query.bindText(1, id);
    if (!try query.step()) return null;
    if (!std.mem.eql(u8, device, try query.text(arena, 0)) or !std.mem.eql(u8, digest, try query.text(arena, 1))) return error.ReusedOperationId;
    return try records.decode(types.Ack, arena, try query.text(arena, 2));
}

fn store_receipt(db: ledger_mod.Ledger, id: []const u8, device: []const u8, digest: []const u8, result: []const u8) !void {
    const query = try db.db.prepare("INSERT INTO sync_receipts VALUES(?1,?2,?3,?4)");
    defer query.finalize();
    try query.bindText(1, id);
    try query.bindText(2, device);
    try query.bindText(3, digest);
    try query.bindText(4, result);
    _ = try query.step();
}

fn append_change(db: ledger_mod.Ledger, key: types.Key, revision: i64, payload: []const u8) !void {
    const query = try db.db.prepare("INSERT INTO sync_log(kind,id,revision,payload) VALUES(?1,?2,?3,?4)");
    defer query.finalize();
    try state.bind_key(query, key);
    try query.bindInt(3, revision);
    try query.bindText(4, payload);
    _ = try query.step();
}
