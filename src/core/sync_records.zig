//! Canonical records and replica materialization, shared by server and phone.
const std = @import("std");
const ledger_mod = @import("ledger.zig");
const statements = @import("statements.zig");
const legacy = @import("legacy.zig");
const preferences = @import("preferences.zig");
const model = ledger_mod.model;
pub const Kind = enum { document, statement, observation, expense, budget };
pub const Key = struct { kind: Kind, id: []const u8 };
pub const Payment = struct { expense: model.Expense, documents: []const []const u8, observations: []const []const u8 };
const Document = struct { data_url: []const u8, extraction: []const u8 };
const Statement = struct { name: []const u8, data_url: []const u8, parser: []const u8, status: []const u8 };
const Observation = struct { statement_hash: []const u8, position: i64, source: statements.Row, ignored: bool };

pub fn validate_key(key: Key) !void {
    if (key.kind == .budget) {
        if (!std.mem.eql(u8, key.id, "budget")) return error.InvalidId;
    } else if (!model.valid_id(key.id)) return error.InvalidId;
}

pub fn snapshot(db: ledger_mod.Ledger, arena: std.mem.Allocator, key: Key) ![]const u8 {
    try validate_key(key);
    switch (key.kind) {
        .expense => {
            var row = (try db.get(arena, key.id)) orelse return error.ExpenseNotFound;
            row.revision = 0;
            row.evidence_count = 0;
            return encode(arena, Payment{ .expense = row, .documents = try links(db, arena, "SELECT document_hash FROM evidence WHERE expense_id=?1 ORDER BY document_hash", key.id), .observations = try links(db, arena, "SELECT id FROM observations WHERE expense_id=?1 ORDER BY id", key.id) });
        },
        .document => {
            const query = try db.db.prepare("SELECT data_url,extraction FROM documents WHERE hash=?1");
            defer query.finalize();
            try query.bindText(1, key.id);
            if (!try query.step()) return error.MissingDependency;
            return encode(arena, Document{ .data_url = try query.text(arena, 0), .extraction = try query.text(arena, 1) });
        },
        .statement => {
            const query = try db.db.prepare("SELECT name,data_url,parser,status FROM statements WHERE hash=?1");
            defer query.finalize();
            try query.bindText(1, key.id);
            if (!try query.step()) return error.MissingDependency;
            return encode(arena, Statement{ .name = try query.text(arena, 0), .data_url = try query.text(arena, 1), .parser = try query.text(arena, 2), .status = try query.text(arena, 3) });
        },
        .observation => {
            const query = try db.db.prepare("SELECT statement_hash,position,source_json,ignored FROM observations WHERE id=?1");
            defer query.finalize();
            try query.bindText(1, key.id);
            if (!try query.step()) return error.MissingDependency;
            return encode(arena, Observation{ .statement_hash = try query.text(arena, 0), .position = query.int(1), .source = try decode(statements.Row, arena, try query.text(arena, 2)), .ignored = query.int(3) != 0 });
        },
        .budget => return encode(arena, try decode(legacy.Settings, arena, try db.setting(arena, "budget"))),
    }
}

fn links(db: ledger_mod.Ledger, arena: std.mem.Allocator, query_text: [:0]const u8, id: []const u8) ![]const []const u8 {
    const query = try db.db.prepare(query_text);
    defer query.finalize();
    try query.bindText(1, id);
    var result: std.ArrayList([]const u8) = .empty;
    while (try query.step()) {
        if (result.items.len == 1000) return error.TooManyAttachments;
        try result.append(arena, try query.text(arena, 0));
    }
    return result.toOwnedSlice(arena);
}

pub fn encode(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{});
}
pub fn decode(comptime T: type, arena: std.mem.Allocator, json: []const u8) !T {
    if (json.len > 64 * 1024 * 1024) return error.SyncPayloadTooLarge;
    try @import("json_limits.zig").check(json);
    return std.json.parseFromSliceLeaky(T, arena, json, .{ .max_value_len = 48 * 1024 * 1024 });
}

// Caller owns an IMMEDIATE transaction and suppresses local echo triggers.
pub fn materialize(db: ledger_mod.Ledger, arena: std.mem.Allocator, key: Key, json: []const u8) !void {
    try validate_key(key);
    switch (key.kind) {
        .expense => try payment(db, arena, key.id, try decode(Payment, arena, json)),
        .document => try document(db, arena, key.id, try decode(Document, arena, json)),
        .statement => try statement(db, arena, key.id, try decode(Statement, arena, json)),
        .observation => try observation(db, arena, key.id, try decode(Observation, arena, json)),
        .budget => {
            if (json.len > 256 * 1024) return error.SettingsTooLarge;
            const value = try decode(legacy.Settings, arena, json);
            try preferences.validate(value);
            try db.put_setting("budget", try encode(arena, value));
        },
    }
}

fn document(db: ledger_mod.Ledger, arena: std.mem.Allocator, id: []const u8, value: Document) !void {
    const hash = model.digest(try ledger_mod.image_bytes(arena, value.data_url));
    if (!std.mem.eql(u8, id, &hash)) return error.DocumentHashMismatch;
    if (value.extraction.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(value.extraction)) return error.InvalidExtraction;
    const query = try db.db.prepare("SELECT data_url,extraction FROM documents WHERE hash=?1");
    defer query.finalize();
    try query.bindText(1, id);
    if (try query.step()) {
        if (!std.mem.eql(u8, value.data_url, try query.text(arena, 0)) or !std.mem.eql(u8, value.extraction, try query.text(arena, 1))) return error.ImmutableSourceConflict;
        return;
    }
    const insert = try db.db.prepare("INSERT INTO documents VALUES(?1,?2,?3)");
    defer insert.finalize();
    try insert.bindText(1, id);
    try insert.bindText(2, value.data_url);
    try insert.bindText(3, value.extraction);
    _ = try insert.step();
}

fn statement(db: ledger_mod.Ledger, arena: std.mem.Allocator, id: []const u8, value: Statement) !void {
    const hash = try statements.stage(db, arena, value.name, value.data_url);
    if (!std.mem.eql(u8, id, hash)) return error.DocumentHashMismatch;
    if ((!std.mem.eql(u8, value.parser, "") and !statements.supported_parser(value.parser)) or
        (!std.mem.eql(u8, value.status, "queued") and !std.mem.eql(u8, value.status, "review"))) return error.InvalidStatement;
    const update = try db.db.prepare("UPDATE statements SET name=?2,parser=?3,status=?4 WHERE hash=?1");
    defer update.finalize();
    try update.bindText(1, id);
    try update.bindText(2, value.name);
    try update.bindText(3, value.parser);
    try update.bindText(4, value.status);
    _ = try update.step();
}

test "BCI PDF parser identities survive replica materialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "bci-card-v1", "bci-cartola-v1" }) |parser| {
        const db = try ledger_mod.Ledger.open(":memory:");
        defer db.close();
        const data = "data:application/pdf;base64,JVBERi1zeW5j";
        const hash = try a.dupe(u8, &model.digest("%PDF-sync"));
        const json = try encode(a, Statement{ .name = "Synthetic BCI", .data_url = data, .parser = parser, .status = "review" });
        try materialize(db, a, .{ .kind = .statement, .id = hash }, json);
        const copy = try decode(Statement, a, try snapshot(db, a, .{ .kind = .statement, .id = hash }));
        try std.testing.expectEqualStrings(parser, copy.parser);
    }
}

fn observation(db: ledger_mod.Ledger, arena: std.mem.Allocator, id: []const u8, value: Observation) !void {
    if (!model.valid_id(value.statement_hash) or value.position < 0 or value.position >= 10000) return error.InvalidStatement;
    const identity = try std.fmt.allocPrint(arena, "statement-v1:{s}:{d}", .{ value.statement_hash, value.position });
    if (!std.mem.eql(u8, id, &model.digest(identity))) return error.InvalidId;
    try model.validate(.{ .id = id, .date = value.source.date, .amount = value.source.amount, .payee = value.source.payee, .account = value.source.account, .category = value.source.category });
    const raw = try encode(arena, value.source);
    const query = try db.db.prepare("SELECT source_json,expense_id FROM observations WHERE id=?1");
    defer query.finalize();
    try query.bindText(1, id);
    if (try query.step()) {
        if (!std.mem.eql(u8, raw, try query.text(arena, 0))) return error.ImmutableSourceConflict;
        if (value.ignored and (try query.text(arena, 1)).len > 0) return error.EvidenceConflict;
    }
    const upsert = try db.db.prepare("INSERT INTO observations(id,statement_hash,position,source_json,ignored) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(id) DO UPDATE SET ignored=excluded.ignored");
    defer upsert.finalize();
    try upsert.bindText(1, id);
    try upsert.bindText(2, value.statement_hash);
    try upsert.bindInt(3, value.position);
    try upsert.bindText(4, raw);
    try upsert.bindInt(5, if (value.ignored) 1 else 0);
    _ = try upsert.step();
}

fn payment(db: ledger_mod.Ledger, arena: std.mem.Allocator, id: []const u8, value: Payment) !void {
    if (!std.mem.eql(u8, id, value.expense.id) or value.expense.revision != 0 or value.expense.evidence_count != 0) return error.InvalidSyncPayment;
    try model.validate(value.expense);
    try validate_links(db, arena, value.documents, id, "SELECT expense_id FROM evidence WHERE document_hash=?1", "SELECT hash FROM documents WHERE hash=?1");
    try validate_links(db, arena, value.observations, id, "SELECT expense_id FROM observations WHERE id=?1", "SELECT id FROM observations WHERE id=?1");
    try db.replicate(arena, value.expense);
    const clear_images = try db.db.prepare("DELETE FROM evidence WHERE expense_id=?1");
    defer clear_images.finalize();
    try clear_images.bindText(1, id);
    _ = try clear_images.step();
    for (value.documents) |hash| {
        const insert = try db.db.prepare("INSERT INTO evidence VALUES(?1,?2)");
        defer insert.finalize();
        try insert.bindText(1, hash);
        try insert.bindText(2, id);
        _ = try insert.step();
    }
    const clear_rows = try db.db.prepare("UPDATE observations SET expense_id=NULL WHERE expense_id=?1");
    defer clear_rows.finalize();
    try clear_rows.bindText(1, id);
    _ = try clear_rows.step();
    for (value.observations) |hash| {
        const update = try db.db.prepare("UPDATE observations SET expense_id=?2,ignored=0 WHERE id=?1");
        defer update.finalize();
        try update.bindText(1, hash);
        try update.bindText(2, id);
        _ = try update.step();
    }
}

fn validate_links(db: ledger_mod.Ledger, arena: std.mem.Allocator, ids: []const []const u8, owner: []const u8, owner_sql: [:0]const u8, exists_sql: [:0]const u8) !void {
    if (ids.len > 1000) return error.TooManyAttachments;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    for (ids) |id| {
        if (!model.valid_id(id) or seen.contains(id)) return error.InvalidId;
        try seen.put(arena, id, {});
        const exists = try db.db.prepare(exists_sql);
        defer exists.finalize();
        try exists.bindText(1, id);
        if (!try exists.step()) return error.MissingDependency;
        const query = try db.db.prepare(owner_sql);
        defer query.finalize();
        try query.bindText(1, id);
        if (try query.step()) {
            const existing = try query.text(arena, 0);
            if (existing.len > 0 and !std.mem.eql(u8, existing, owner)) return error.EvidenceConflict;
        }
    }
}
