//! Shared by the desktop and Android. Callers serialize a connection for the
//! entire operation, including transactions; SQLite's per-call lock is insufficient.
const std = @import("std");
const sql = @import("oriel").sql;
pub const model = @import("model.zig");
pub const Expense = model.Expense;
const Allocator = std.mem.Allocator;

pub const Ledger = struct {
    db: sql.Db,

    pub fn open(path: [:0]const u8) !Ledger {
        const db = try sql.Db.open(path);
        errdefer db.close();
        // Android opens separate UI and sync-worker connections. Wait for a
        // briefly held lock before the first schema read instead of failing.
        try db.exec("PRAGMA busy_timeout=5000");
        if (try db.scalarInt("PRAGMA user_version") > 5) return error.NewerDatabaseVersion;
        // Android apps cannot write SQLite's default temp directories; large
        // savepoint journals (e.g. a synchronized statement PDF) must stay in memory.
        try db.exec("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL; PRAGMA journal_mode=WAL; PRAGMA temp_store=MEMORY;");
        try migrate(db, 1, @embedFile("schema.sql"));
        try migrate(db, 2, @embedFile("migration2.sql"));
        try migrate(db, 3, @embedFile("migration3.sql"));
        try migrate(db, 4, @embedFile("migration4.sql"));
        try migrate(db, 5, @embedFile("migration5.sql"));
        // Migration 5 rebuilds a table with foreign keys off; on whatever path.
        try db.exec("PRAGMA foreign_keys=ON");
        return .{ .db = db };
    }

    // Each script is one transaction. Another connection may apply the same
    // step concurrently; its committed version then satisfies this one.
    fn migrate(db: sql.Db, target: i64, script: [:0]const u8) !void {
        if (try db.scalarInt("PRAGMA user_version") >= target) return;
        db.exec(script) catch |err| {
            db.exec("ROLLBACK") catch {};
            if (try db.scalarInt("PRAGMA user_version") >= target) return;
            return err;
        };
    }

    pub fn close(self: Ledger) void {
        self.db.close();
    }

    pub fn save(self: Ledger, allocator: Allocator, args: model.Save) !i64 {
        try model.validate(args.expense);
        if (args.expected_revision < 0 or args.expected_revision == std.math.maxInt(i64)) return error.InvalidRevision;
        try self.db.exec("BEGIN IMMEDIATE");
        errdefer self.db.exec("ROLLBACK") catch {};
        const categories = @import("categories.zig");
        const settings = try std.json.parseFromSliceLeaky(@import("legacy.zig").Settings, allocator, try self.setting(allocator, "budget"), .{ .ignore_unknown_fields = true });
        var expense = args.expense;
        expense.category = try categories.canonical(allocator, expense.category, try categories.catalog(allocator, try self.list(allocator), settings));
        const saved_revision = try self.write_expense(expense, args.expected_revision);
        if (args.document) |doc| try self.attach(allocator, args.expense.id, doc);
        try self.record_change(args.expense.id, saved_revision);
        try self.db.exec("COMMIT");
        return saved_revision;
    }

    // Also used by the legacy importer inside its single atomic transaction.
    pub fn write_expense(self: Ledger, e: Expense, expected: i64) !i64 {
        if (e.deleted) return error.ExpenseDeleted;
        const current = try self.revision(e.id);
        if ((current orelse 0) != expected) return error.RevisionConflict;
        try self.upsert(e, expected + 1);
        return expected + 1;
    }

    fn upsert(self: Ledger, e: Expense, next: i64) !void {
        const statement = try self.db.prepare(
            "INSERT INTO expenses VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12) " ++
                "ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,date=excluded.date," ++
                "amount=excluded.amount,currency=excluded.currency,payee=excluded.payee," ++
                "account=excluded.account,category=excluded.category,notes=excluded.notes," ++
                "reference=excluded.reference,location=excluded.location,deleted=excluded.deleted",
        );
        defer statement.finalize();
        try statement.bindText(1, e.id);
        try statement.bindInt(2, next);
        try statement.bindText(3, e.date);
        try statement.bindInt(4, e.amount);
        try statement.bindText(5, e.currency);
        try statement.bindText(6, e.payee);
        try statement.bindText(7, e.account);
        try statement.bindText(8, e.category);
        try statement.bindText(9, e.notes);
        try statement.bindText(10, e.reference);
        try statement.bindText(11, e.location);
        try statement.bindInt(12, if (e.deleted) 1 else 0);
        _ = try statement.step();
    }

    // Called only inside an authenticated sync transaction with echo suppressed.
    pub fn replicate(self: Ledger, allocator: Allocator, e: Expense) !void {
        try model.validate(e);
        const old = try self.get(allocator, e.id);
        if (old != null and old.?.deleted and !e.deleted) return error.CannotRestoreDeleted;
        const revision_value = if (old) |row| row.revision else 0;
        if (revision_value == std.math.maxInt(i64)) return error.InvalidRevision;
        try self.upsert(e, revision_value + 1);
        try self.record_change(e.id, revision_value + 1);
    }

    pub fn revision(self: Ledger, id: []const u8) !?i64 {
        const query = try self.db.prepare("SELECT revision,deleted FROM expenses WHERE id=?1");
        defer query.finalize();
        try query.bindText(1, id);
        if (!try query.step()) return null;
        if (query.int(1) != 0) return error.ExpenseDeleted;
        return query.int(0);
    }

    pub fn contains(self: Ledger, id: []const u8) !bool {
        const query = try self.db.prepare("SELECT 1 FROM expenses WHERE id=?1");
        defer query.finalize();
        try query.bindText(1, id);
        return query.step(); // Includes tombstones: a reimport cannot resurrect one.
    }

    pub fn remove(self: Ledger, id: []const u8, expected: i64) !void {
        if (!model.valid_id(id) or expected < 1 or expected == std.math.maxInt(i64)) return error.InvalidRevision;
        try self.db.exec("BEGIN IMMEDIATE");
        errdefer self.db.exec("ROLLBACK") catch {};
        if ((try self.revision(id) orelse return error.ExpenseNotFound) != expected) return error.RevisionConflict;
        const stmt = try self.db.prepare("UPDATE expenses SET deleted=1,revision=revision+1 WHERE id=?1");
        defer stmt.finalize();
        try stmt.bindText(1, id);
        _ = try stmt.step();
        try self.record_change(id, expected + 1);
        try self.db.exec("COMMIT");
    }

    pub fn record_change(self: Ledger, id: []const u8, rev: i64) !void {
        const stmt = try self.db.prepare("INSERT INTO changes(expense_id,revision) VALUES (?1,?2)");
        defer stmt.finalize();
        try stmt.bindText(1, id);
        try stmt.bindInt(2, rev);
        _ = try stmt.step();
    }

    pub fn list(self: Ledger, allocator: Allocator) ![]Expense {
        const query = try self.db.prepare(
            "SELECT e.*, ((SELECT count(*) FROM evidence WHERE expense_id=e.id)+(SELECT count(*) FROM observations WHERE expense_id=e.id)) FROM expenses e " ++
                "WHERE deleted=0 ORDER BY date DESC,id LIMIT 100001",
        );
        defer query.finalize();
        var items: std.ArrayList(Expense) = .empty;
        // An arena belongs to the request; on any error its owner frees all rows.
        while (try query.step()) {
            if (items.items.len == 100000) return error.TooManyExpenses;
            try items.append(allocator, try read_expense(query, allocator));
        }
        return items.toOwnedSlice(allocator);
    }

    pub fn get(self: Ledger, allocator: Allocator, id: []const u8) !?Expense {
        if (!model.valid_id(id)) return error.InvalidId;
        const query = try self.db.prepare("SELECT e.*, ((SELECT count(*) FROM evidence WHERE expense_id=e.id)+(SELECT count(*) FROM observations WHERE expense_id=e.id)) FROM expenses e WHERE id=?1");
        defer query.finalize();
        try query.bindText(1, id);
        if (!try query.step()) return null;
        return try read_expense(query, allocator);
    }

    fn attach(self: Ledger, allocator: Allocator, id: []const u8, doc: model.Document) !void {
        const bytes = try image_bytes(allocator, doc.data_url);
        const hash = model.digest(bytes);
        if (doc.extraction.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(doc.extraction)) return error.InvalidExtraction;
        const existing = try self.db.prepare("SELECT expense_id FROM evidence WHERE document_hash=?1");
        defer existing.finalize();
        try existing.bindText(1, &hash);
        if (try existing.step()) {
            if (!std.mem.eql(u8, try existing.text(allocator, 0), id)) return error.DocumentAlreadyLinked;
            return;
        }
        const insert = try self.db.prepare("INSERT INTO documents VALUES (?1,?2,?3) ON CONFLICT(hash) DO NOTHING");
        defer insert.finalize();
        try insert.bindText(1, &hash);
        try insert.bindText(2, doc.data_url);
        try insert.bindText(3, doc.extraction);
        _ = try insert.step();
        const link = try self.db.prepare("INSERT INTO evidence VALUES (?1,?2)");
        defer link.finalize();
        try link.bindText(1, &hash);
        try link.bindText(2, id);
        _ = try link.step();
    }

    pub fn documents(self: Ledger, allocator: Allocator, id: []const u8) ![]model.Document {
        if (!model.valid_id(id)) return error.InvalidId;
        const query = try self.db.prepare("SELECT data_url,extraction FROM documents JOIN evidence ON hash=document_hash WHERE expense_id=?1");
        defer query.finalize();
        try query.bindText(1, id);
        var docs: std.ArrayList(model.Document) = .empty;
        while (try query.step()) try docs.append(allocator, .{
            .data_url = try query.text(allocator, 0),
            .extraction = try query.text(allocator, 1),
        });
        return docs.toOwnedSlice(allocator);
    }

    pub fn setting(self: Ledger, allocator: Allocator, key: []const u8) ![]const u8 {
        const query = try self.db.prepare("SELECT value FROM settings WHERE key=?1");
        defer query.finalize();
        try query.bindText(1, key);
        return if (try query.step()) query.text(allocator, 0) else "{}";
    }

    pub fn put_setting(self: Ledger, key: []const u8, value: []const u8) !void {
        const stmt = try self.db.prepare("INSERT INTO settings VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
        defer stmt.finalize();
        try stmt.bindText(1, key);
        try stmt.bindText(2, value);
        _ = try stmt.step();
    }
};

fn read_expense(query: sql.Stmt, allocator: Allocator) !Expense {
    return .{
        .id = try query.text(allocator, 0),
        .revision = query.int(1),
        .date = try query.text(allocator, 2),
        .amount = query.int(3),
        .currency = try query.text(allocator, 4),
        .payee = try query.text(allocator, 5),
        .account = try query.text(allocator, 6),
        .category = try query.text(allocator, 7),
        .notes = try query.text(allocator, 8),
        .reference = try query.text(allocator, 9),
        .location = try query.text(allocator, 10),
        .deleted = query.int(11) != 0,
        .evidence_count = query.int(12),
    };
}

pub fn image_bytes(allocator: Allocator, data_url: []const u8) ![]const u8 {
    const png = "data:image/png;base64,";
    const jpeg = "data:image/jpeg;base64,";
    const is_png = std.mem.startsWith(u8, data_url, png);
    const prefix = if (is_png) png else jpeg;
    if (!std.mem.startsWith(u8, data_url, prefix)) return error.UnsupportedImage;
    const encoded = data_url[prefix.len..];
    const decoder = std.base64.standard.Decoder;
    const length = decoder.calcSizeForSlice(encoded) catch return error.InvalidImage;
    if (length == 0 or length > 8 * 1024 * 1024) return error.ImageTooLarge;
    const bytes = try allocator.alloc(u8, length);
    try decoder.decode(bytes, encoded);
    const signature: []const u8 = if (is_png) "\x89PNG\r\n\x1a\n" else "\xff\xd8\xff";
    if (!std.mem.startsWith(u8, bytes, signature)) return error.InvalidImage;
    return bytes;
}

test "optimistic revisions, atomic document deduplication, deletion tombstones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ledger = try Ledger.open(":memory:");
    defer ledger.close();
    const a: Expense = .{ .id = &model.digest("a"), .date = "2026-10-10", .amount = 40000, .payee = "Gladys" };
    const image: model.Document = .{ .data_url = "data:image/png;base64,iVBORw0KGgo=" };
    try std.testing.expectEqual(@as(i64, 1), try ledger.save(allocator, .{ .expense = a, .document = image }));
    try std.testing.expectError(error.RevisionConflict, ledger.save(allocator, .{ .expense = a }));
    var b = a;
    b.id = &model.digest("b");
    try std.testing.expectError(error.DocumentAlreadyLinked, ledger.save(allocator, .{ .expense = b, .document = image }));
    try std.testing.expect(!try ledger.contains(b.id));
    // Same date, amount and payee is not sufficient evidence of duplication.
    _ = try ledger.save(allocator, .{ .expense = b });
    try std.testing.expectEqual(@as(usize, 2), (try ledger.list(allocator)).len);
    try std.testing.expectEqual(@as(i64, 2), try ledger.save(allocator, .{ .expense = a, .expected_revision = 1 }));
    try std.testing.expectError(error.RevisionConflict, ledger.remove(a.id, 1));
    try ledger.remove(a.id, 2);
    try std.testing.expectError(error.ExpenseDeleted, ledger.save(allocator, .{ .expense = a, .expected_revision = 3 }));
    try std.testing.expect(try ledger.contains(a.id));
    try std.testing.expectEqual(@as(usize, 1), (try ledger.list(allocator)).len);
    try std.testing.expectEqual(@as(i64, 4), try ledger.db.scalarInt("SELECT count(*) FROM changes"));
}

test "USD payments save beside CLP ones; other currencies are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ledger = try Ledger.open(":memory:");
    defer ledger.close();
    const usd: Expense = .{ .id = &model.digest("usd"), .date = "2026-09-14", .amount = 4663, .currency = "USD", .payee = "Travel Rewards Visa" };
    _ = try ledger.save(allocator, .{ .expense = usd });
    const rows = try ledger.list(allocator);
    try std.testing.expectEqualStrings("USD", rows[0].currency);
    try std.testing.expectEqual(@as(i64, 4663), rows[0].amount);
    var eur = usd;
    eur.id = &model.digest("eur");
    eur.currency = "EUR";
    try std.testing.expectError(error.UnsupportedCurrency, ledger.save(allocator, .{ .expense = eur }));
    // The table refuses it too, past the model's check.
    try std.testing.expectError(error.SqliteExec, ledger.db.exec("UPDATE expenses SET currency='EUR'"));
}

test "file ledger retains expenses evidence settings and tombstones after reopen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &directory);
    const path = try std.fs.path.joinZ(a, &.{ directory[0..length], "ledger.sqlite3" });
    const expense: Expense = .{ .id = &model.digest("persisted"), .date = "2026-10-14", .amount = 40000, .payee = "Johana" };
    const deleted: Expense = .{ .id = &model.digest("deleted"), .date = "2026-10-14", .amount = 40000, .payee = "Johana" };
    const image: model.Document = .{ .data_url = "data:image/png;base64,iVBORw0KGgo=", .extraction = "original observation" };
    {
        const db = try Ledger.open(path);
        defer db.close();
        _ = try db.save(a, .{ .expense = expense, .document = image });
        _ = try db.save(a, .{ .expense = deleted });
        try db.remove(deleted.id, 1);
        try db.put_setting("budget", "{\"salary\":3000000}");
    }
    const reopened = try Ledger.open(path);
    defer reopened.close();
    const rows = try reopened.list(a);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings(expense.id, rows[0].id);
    try std.testing.expectEqual(@as(i64, 1), rows[0].evidence_count);
    const docs = try reopened.documents(a, expense.id);
    try std.testing.expectEqual(@as(usize, 1), docs.len);
    try std.testing.expectEqualStrings(image.data_url, docs[0].data_url);
    try std.testing.expectEqualStrings(image.extraction, docs[0].extraction);
    try std.testing.expectEqualStrings("{\"salary\":3000000}", try reopened.setting(a, "budget"));
    try std.testing.expectError(error.ExpenseDeleted, reopened.save(a, .{ .expense = deleted, .expected_revision = 2 }));
    try std.testing.expectEqual(@as(i64, 3), try reopened.db.scalarInt("SELECT count(*) FROM changes"));
}

test "independent connections reject stale edits and preserve atomic change records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &directory);
    const path = try std.fs.path.joinZ(a, &.{ directory[0..length], "ledger.sqlite3" });
    const first = try Ledger.open(path);
    defer first.close();
    const second = try Ledger.open(path);
    defer second.close();
    const expense: Expense = .{ .id = &model.digest("concurrent"), .date = "2026-10-14", .amount = 40000, .payee = "Johana" };
    _ = try first.save(a, .{ .expense = expense });
    var stale = (try second.list(a))[0];
    var updated = stale;
    updated.notes = "first edit";
    _ = try first.save(a, .{ .expense = updated, .expected_revision = 1 });
    stale.notes = "stale edit";
    try std.testing.expectError(error.RevisionConflict, second.save(a, .{ .expense = stale, .expected_revision = 1 }));
    try std.testing.expectEqualStrings("first edit", (try second.list(a))[0].notes);
    try std.testing.expectEqual(@as(i64, 2), try second.db.scalarInt("SELECT count(*) FROM changes"));
    // A bookkeeping failure must also undo the domain write.
    try first.db.exec("CREATE TRIGGER fail_change BEFORE INSERT ON changes BEGIN SELECT RAISE(ABORT,'test'); END");
    try std.testing.expectError(error.SqliteStep, first.save(a, .{ .expense = updated, .expected_revision = 2 }));
    try std.testing.expectEqual(@as(?i64, 2), try second.revision(expense.id));
    try std.testing.expectError(error.SqliteStep, first.remove(expense.id, 2));
    try std.testing.expectEqual(@as(?i64, 2), try second.revision(expense.id));
}

fn release_lock(locker: sql.Db) void {
    std.Io.sleep(std.testing.io, .fromMilliseconds(300), .awake) catch {};
    locker.exec("COMMIT") catch {};
}

test "opening waits for a lock held by another connection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &directory);
    const path = try std.fs.path.joinZ(a, &.{ directory[0..length], "ledger.sqlite3" });
    // A rollback-journal exclusive lock blocks even schema reads, like the
    // last connection closing and checkpointing a WAL database.
    const locker = try sql.Db.open(path);
    defer locker.close();
    try locker.exec("CREATE TABLE warmup(x); BEGIN EXCLUSIVE; INSERT INTO warmup VALUES(1);");
    const thread = try std.Thread.spawn(.{}, release_lock, .{locker});
    const db = try Ledger.open(path);
    defer db.close();
    thread.join();
    try std.testing.expectEqual(@as(i64, 5), try db.db.scalarInt("PRAGMA user_version"));
    // 2 = MEMORY: Android has no writable temp directory for spilled journals.
    try std.testing.expectEqual(@as(i64, 2), try db.db.scalarInt("PRAGMA temp_store"));
    // A second connection racing on an already migrated file is a no-op.
    const again = try Ledger.open(path);
    again.close();
}
