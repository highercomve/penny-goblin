//! Immutable statement observations; reconciliation is an explicit atomic edit.
const std = @import("std");
const ledger_mod = @import("ledger.zig");
const model = ledger_mod.model;
/// `amount` in the currency's minor units (model.currencies): USD in cents.
pub const Row = struct { date: []const u8, amount: i64, payee: []const u8, account: []const u8, category: []const u8, currency: []const u8 = "CLP" };
/// The statement parsers whose rows are accepted (statement_helper.py).
const parsers = [_][]const u8{ "santander-web-v1", "bci-card-v1", "bci-cartola-v1" };
pub fn supported_parser(parser: []const u8) bool {
    for (parsers) |name| if (std.mem.eql(u8, name, parser)) return true;
    return false;
}
pub const Parsed = struct { parser: []const u8, rows: []const Row };
pub const Source = struct { hash: []const u8, name: []const u8, status: []const u8 };
pub const Observation = struct { id: []const u8, source: Row, expense_id: ?[]const u8, ignored: bool };
pub const PaymentSource = struct { id: []const u8, statement_hash: []const u8, name: []const u8, source_json: []const u8 };
pub const Decision = struct {
    observation_id: []const u8,
    action: enum { create, link, ignore },
    expense_id: []const u8 = "",
    expected_revision: i64 = 0,
};

/// Offer only nearby, same-amount payments from this account, matching the web UI.
pub fn candidate(source: Row, payment: model.Expense) bool {
    if (payment.amount != source.amount or !std.mem.eql(u8, payment.currency, source.currency)) return false;
    if (!std.mem.eql(u8, payment.account, source.account) and !std.mem.eql(u8, payment.account, "Unspecified")) return false;
    const source_day = calendar_day(source.date) orelse return false;
    const payment_day = calendar_day(payment.date) orelse return false;
    return @abs(source_day - payment_day) <= 3;
}

fn calendar_day(date: []const u8) ?i32 {
    if (!model.valid_date(date)) return null;
    const year = std.fmt.parseInt(u16, date[0..4], 10) catch unreachable;
    const month = std.fmt.parseInt(u8, date[5..7], 10) catch unreachable;
    const day = std.fmt.parseInt(u8, date[8..10], 10) catch unreachable;
    const prior: i32 = @as(i32, year) - 1;
    var ordinal = prior * 365 + @divTrunc(prior, 4) - @divTrunc(prior, 100) + @divTrunc(prior, 400) + day;
    for (1..month) |m| ordinal += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    return ordinal;
}

test "statement candidates respect account and three calendar days across boundaries" {
    const source: Row = .{ .date = "2024-03-01", .amount = 100, .payee = "Market", .account = "1234", .category = "" };
    var payment: model.Expense = .{ .id = "", .date = "2024-02-27", .amount = 100, .payee = "Market", .account = "1234" };
    try std.testing.expect(candidate(source, payment));
    payment.date = "2024-02-26";
    try std.testing.expect(!candidate(source, payment));
    payment.date = "2024-03-04";
    payment.account = "Unspecified";
    try std.testing.expect(candidate(source, payment));
    payment.account = "5678";
    try std.testing.expect(!candidate(source, payment));
    payment.account = "1234";
    payment.amount = 99;
    try std.testing.expect(!candidate(source, payment));
    payment.amount = 100;
    payment.date = "invalid";
    try std.testing.expect(!candidate(source, payment));
}

pub fn pdf_bytes(arena: std.mem.Allocator, data_url: []const u8) ![]u8 {
    const prefix = "data:application/pdf;base64,";
    if (!std.mem.startsWith(u8, data_url, prefix) or data_url.len > 44 * 1024 * 1024) return error.InvalidPdf;
    const encoded = data_url[prefix.len..];
    const decoder = std.base64.standard.Decoder;
    const bytes = try arena.alloc(u8, try decoder.calcSizeForSlice(encoded));
    errdefer arena.free(bytes);
    if (bytes.len > 32 * 1024 * 1024) return error.InvalidPdf;
    try decoder.decode(bytes, encoded);
    if (!std.mem.startsWith(u8, bytes, "%PDF-")) return error.InvalidPdf;
    return bytes;
}

test "invalid decoded PDF releases its allocation" {
    try std.testing.expectError(error.InvalidPdf, pdf_bytes(std.testing.allocator, "data:application/pdf;base64,bm90cGRm"));
}

pub fn stage(db: ledger_mod.Ledger, arena: std.mem.Allocator, name: []const u8, data_url: []const u8) ![]const u8 {
    try model.text(name, 255, false);
    const hash = try arena.dupe(u8, &model.digest(try pdf_bytes(arena, data_url)));
    const stmt = try db.db.prepare("INSERT INTO statements(hash,name,data_url) VALUES (?1,?2,?3) ON CONFLICT(hash) DO NOTHING");
    defer stmt.finalize();
    try stmt.bindText(1, hash);
    try stmt.bindText(2, name);
    try stmt.bindText(3, data_url);
    _ = try stmt.step();
    return hash;
}

pub fn sources(db: ledger_mod.Ledger, arena: std.mem.Allocator) ![]Source {
    const query = try db.db.prepare("SELECT hash,name,status FROM statements ORDER BY rowid DESC LIMIT 1001");
    defer query.finalize();
    var rows: std.ArrayList(Source) = .empty;
    while (try query.step()) {
        if (rows.items.len == 1000) return error.TooManyStatements;
        try rows.append(arena, .{ .hash = try query.text(arena, 0), .name = try query.text(arena, 1), .status = try query.text(arena, 2) });
    }
    return rows.toOwnedSlice(arena);
}

pub fn payment_sources(db: ledger_mod.Ledger, arena: std.mem.Allocator, expense_id: []const u8) ![]PaymentSource {
    if (!model.valid_id(expense_id)) return error.InvalidId;
    const query = try db.db.prepare("SELECT o.id,s.hash,s.name,o.source_json FROM observations o JOIN statements s ON s.hash=o.statement_hash WHERE o.expense_id=?1 LIMIT 1001");
    defer query.finalize();
    try query.bindText(1, expense_id);
    var rows: std.ArrayList(PaymentSource) = .empty;
    while (try query.step()) {
        if (rows.items.len == 1000) return error.TooManyStatements;
        try rows.append(arena, .{ .id = try query.text(arena, 0), .statement_hash = try query.text(arena, 1), .name = try query.text(arena, 2), .source_json = try query.text(arena, 3) });
    }
    return rows.toOwnedSlice(arena);
}

pub fn content(db: ledger_mod.Ledger, arena: std.mem.Allocator, hash: []const u8) ![]const u8 {
    if (!model.valid_id(hash)) return error.InvalidId;
    const query = try db.db.prepare("SELECT data_url FROM statements WHERE hash=?1");
    defer query.finalize();
    try query.bindText(1, hash);
    if (!try query.step()) return error.StatementNotFound;
    return query.text(arena, 0);
}

pub fn accept_parse(db: ledger_mod.Ledger, arena: std.mem.Allocator, hash: []const u8, parsed: Parsed) !void {
    const known = supported_parser(parsed.parser);
    if (!model.valid_id(hash) or parsed.rows.len == 0 or parsed.rows.len > 10000 or !known) return error.InvalidStatement;
    try db.db.exec("BEGIN IMMEDIATE");
    errdefer db.db.exec("ROLLBACK") catch {};
    // Once observed, the original parse is immutable even after rule changes.
    const existing = try observations(db, arena, hash);
    if (existing.len == 0) for (parsed.rows, 0..) |row, index| {
        const identity = try std.fmt.allocPrint(arena, "statement-v1:{s}:{d}", .{ hash, index });
        const id = model.digest(identity);
        try model.validate(expense(row, &id));
        const insert = try db.db.prepare("INSERT INTO observations(id,statement_hash,position,source_json) VALUES (?1,?2,?3,?4)");
        defer insert.finalize();
        try insert.bindText(1, &id);
        try insert.bindText(2, hash);
        try insert.bindInt(3, @intCast(index));
        try insert.bindText(4, try std.json.Stringify.valueAlloc(arena, row, .{}));
        _ = try insert.step();
    };
    const update = try db.db.prepare("UPDATE statements SET status='review',parser=?2 WHERE hash=?1");
    defer update.finalize();
    try update.bindText(1, hash);
    try update.bindText(2, parsed.parser);
    _ = try update.step();
    try db.db.exec("COMMIT");
}

pub fn observations(db: ledger_mod.Ledger, arena: std.mem.Allocator, hash: []const u8) ![]Observation {
    if (!model.valid_id(hash)) return error.InvalidId;
    const query = try db.db.prepare("SELECT id,source_json,expense_id,ignored FROM observations WHERE statement_hash=?1 ORDER BY position LIMIT 10001");
    defer query.finalize();
    try query.bindText(1, hash);
    var rows: std.ArrayList(Observation) = .empty;
    while (try query.step()) {
        if (rows.items.len == 10000) return error.TooManyExpenses;
        const linked = try query.text(arena, 2);
        try rows.append(arena, .{
            .id = try query.text(arena, 0),
            .source = try std.json.parseFromSliceLeaky(Row, arena, try query.text(arena, 1), .{ .ignore_unknown_fields = true }),
            .expense_id = if (linked.len == 0) null else linked,
            .ignored = query.int(3) != 0,
        });
    }
    return rows.toOwnedSlice(arena);
}

fn expense(row: Row, id: []const u8) model.Expense {
    return .{ .id = id, .date = row.date, .amount = row.amount, .currency = row.currency, .payee = row.payee, .account = row.account, .category = row.category };
}

pub fn reconcile(db: ledger_mod.Ledger, arena: std.mem.Allocator, hash: []const u8, decisions: []const Decision) !usize {
    if (decisions.len > 10000) return error.TooManyExpenses;
    try db.db.exec("BEGIN IMMEDIATE");
    errdefer db.db.exec("ROLLBACK") catch {};
    const observed = try observations(db, arena, hash);
    var by_id: std.StringHashMapUnmanaged(Observation) = .empty;
    defer by_id.deinit(arena);
    for (observed) |row| try by_id.put(arena, row.id, row);
    const expenses = try db.list(arena);
    var payments: std.StringHashMapUnmanaged(model.Expense) = .empty;
    defer payments.deinit(arena);
    for (expenses) |row| try payments.put(arena, row.id, row);
    var changed: usize = 0;
    for (decisions) |decision| {
        const row = by_id.get(decision.observation_id) orelse return error.ObservationNotFound;
        if (row.expense_id != null or row.ignored) {
            if ((row.ignored and decision.action == .ignore) or (row.expense_id != null and std.mem.eql(u8, row.expense_id.?, if (decision.action == .create) row.id else decision.expense_id))) continue;
            return error.ObservationConflict;
        }
        const target = if (decision.action == .create) row.id else decision.expense_id;
        if (decision.action == .create) {
            const rev = try db.write_expense(expense(row.source, target), 0);
            try db.record_change(target, rev);
        } else if (decision.action == .link) {
            const payment = payments.get(target) orelse return error.ExpenseNotFound;
            if (payment.amount != row.source.amount or !std.mem.eql(u8, payment.currency, "CLP")) return error.ReconciliationAmountMismatch;
            if (decision.expected_revision < 1 or decision.expected_revision == std.math.maxInt(i64)) return error.InvalidRevision;
            const rev = try db.write_expense(payment, decision.expected_revision);
            try db.record_change(target, rev);
        }
        const update = try db.db.prepare("UPDATE observations SET expense_id=?2,ignored=?3 WHERE id=?1 AND expense_id IS NULL AND ignored=0");
        defer update.finalize();
        try update.bindText(1, row.id);
        // Unbound parameters are SQL NULL for an ignored observation.
        if (decision.action != .ignore) try update.bindText(2, target);
        try update.bindInt(3, if (decision.action == .ignore) 1 else 0);
        _ = try update.step();
        _ = by_id.remove(row.id); // Duplicate decisions are rejected atomically.
        changed += 1;
    }
    try db.db.exec("COMMIT");
    return changed;
}

test "statement replay retains legitimate identical rows, corrections and tombstones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const hash = try stage(db, a, "fixture.pdf", "data:application/pdf;base64,JVBERi0x");
    const row: Row = .{ .date = "2026-10-16", .amount = 40000, .payee = "Fixture", .account = "Debit", .category = "Other" };
    try accept_parse(db, a, hash, .{ .parser = "santander-web-v1", .rows = &.{ row, row } });
    const obs = try observations(db, a, hash);
    const decisions = [_]Decision{ .{ .observation_id = obs[0].id, .action = .create }, .{ .observation_id = obs[1].id, .action = .create } };
    try std.testing.expectEqual(@as(usize, 2), try reconcile(db, a, hash, &decisions));
    try std.testing.expectEqual(@as(usize, 0), try reconcile(db, a, hash, &decisions));
    var rows = try db.list(a);
    rows[0].notes = "User correction";
    _ = try db.save(a, .{ .expense = rows[0], .expected_revision = rows[0].revision });
    try db.remove(rows[1].id, rows[1].revision);
    try accept_parse(db, a, hash, .{ .parser = "santander-web-v1", .rows = &.{row} });
    _ = try reconcile(db, a, hash, &decisions);
    rows = try db.list(a);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("User correction", rows[0].notes);
    try std.testing.expectEqual(@as(usize, 2), (try observations(db, a, hash)).len);
}

test "statement link retains reviewed fields and undo does not delete payment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const e: model.Expense = .{ .id = &model.digest("captured"), .date = "2026-10-16", .amount = 40000, .payee = "Corrected", .notes = "Keep" };
    _ = try db.save(a, .{ .expense = e });
    const hash = try stage(db, a, "fixture.pdf", "data:application/pdf;base64,JVBERi0x");
    try accept_parse(db, a, hash, .{ .parser = "santander-web-v1", .rows = &.{.{ .date = e.date, .amount = e.amount, .payee = "Raw bank text", .account = "Debit", .category = "Other" }} });
    const obs = (try observations(db, a, hash))[0];
    const link: Decision = .{ .observation_id = obs.id, .action = .link, .expense_id = e.id, .expected_revision = 1 };
    _ = try reconcile(db, a, hash, &.{link});
    const saved = (try db.list(a))[0];
    try std.testing.expectEqualStrings(e.payee, saved.payee);
    try std.testing.expectEqualStrings(e.notes, saved.notes);
    try std.testing.expectEqual(@as(i64, 1), saved.evidence_count);
    try unlink(db, a, obs.id, e.id);
    try std.testing.expectEqual(@as(usize, 1), (try db.list(a)).len);
    try std.testing.expect((try observations(db, a, hash))[0].expense_id == null);
}

pub fn unlink(db: ledger_mod.Ledger, arena: std.mem.Allocator, id: []const u8, expected_expense: ?[]const u8) !void {
    if (!model.valid_id(id)) return error.InvalidId;
    try db.db.exec("BEGIN IMMEDIATE");
    errdefer db.db.exec("ROLLBACK") catch {};
    const query = try db.db.prepare("SELECT expense_id FROM observations WHERE id=?1");
    defer query.finalize();
    try query.bindText(1, id);
    if (!try query.step()) return error.ObservationNotFound;
    const current = try query.text(arena, 0);
    if (!std.mem.eql(u8, current, expected_expense orelse "")) return error.ObservationConflict;
    // Unlinking evidence never deletes or changes reviewed payment details.
    if (current.len > 0) {
        for (try db.list(arena)) |row| {
            if (std.mem.eql(u8, row.id, current)) {
                const rev = try db.write_expense(row, row.revision);
                try db.record_change(row.id, rev);
                break;
            }
        }
    }
    const update = try db.db.prepare("UPDATE observations SET expense_id=NULL,ignored=0 WHERE id=?1");
    defer update.finalize();
    try update.bindText(1, id);
    _ = try update.step();
    try db.db.exec("COMMIT");
}
