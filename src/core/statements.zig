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
pub const Source = struct { hash: []const u8, name: []const u8, status: []const u8, format: enum { pdf, json } = .pdf };
pub const Match = struct { id: []const u8, revision: i64 };
pub const Observation = struct { id: []const u8, source: Row, expense_id: ?[]const u8, ignored: bool, match: ?Match = null };
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

test "bank review matches formatting variants once and only creates missing charges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const saved: model.Expense = .{ .id = &model.digest("manual-prime"), .date = "2026-10-18", .amount = 6490, .payee = "Amazon Prime", .account = "9526", .category = "Subscriptions", .notes = "Keep my review" };
    _ = try db.save(a, .{ .expense = saved });
    const row: Row = .{ .date = saved.date, .amount = saved.amount, .payee = "AMAZON*PRIME", .account = saved.account, .category = "Other" };
    const first = try stage_bank(db, a, "2026-10", &.{row});
    const planned = try review(db, a, first.hash.?);
    try std.testing.expectEqualStrings(saved.id, planned[0].match.?.id);
    try std.testing.expectError(error.DuplicateStatementPayment, reconcile(db, a, first.hash.?, &.{.{ .observation_id = planned[0].id, .action = .create }}));
    _ = try reconcile(db, a, first.hash.?, &.{.{ .observation_id = planned[0].id, .action = .link, .expense_id = saved.id, .expected_revision = planned[0].match.?.revision }});
    const linked = (try db.get(a, saved.id)).?;
    try std.testing.expectEqualStrings(saved.notes, linked.notes);
    try std.testing.expectEqualStrings(saved.category, linked.category);
    try std.testing.expectEqualStrings(saved.payee, linked.payee);
    const second = try stage_bank(db, a, "2026-10", &.{ row, row });
    const extra = try review(db, a, second.hash.?);
    try std.testing.expectEqual(@as(usize, 1), extra.len);
    try std.testing.expect(extra[0].match == null);
    _ = try reconcile(db, a, second.hash.?, &.{.{ .observation_id = extra[0].id, .action = .create }});
    try std.testing.expectEqual(@as(usize, 2), (try db.list(a)).len);
    try std.testing.expectEqual(@as(usize, 0), (try stage_bank(db, a, "2026-10", &.{ row, row })).added);
}

test "save rechecks bank duplicates against concurrent imports without broad merchant guesses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const row: Row = .{ .date = "2026-10-18", .amount = 1000, .payee = "Shop A", .account = "9526", .category = "Other" };
    const batch = try stage_bank(db, a, "2026-10", &.{row});
    const initial = try review(db, a, batch.hash.?);
    try std.testing.expect(initial[0].match == null);
    var payment = expense(row, &model.digest("concurrent"));
    payment.payee = "SHOP-A";
    _ = try db.save(a, .{ .expense = payment });
    try std.testing.expectError(error.DuplicateStatementPayment, reconcile(db, a, batch.hash.?, &.{.{ .observation_id = initial[0].id, .action = .create }}));
    try std.testing.expectEqual(@as(usize, 1), (try db.list(a)).len);
    var different = row;
    different.date = "2026-10-19";
    try std.testing.expect(!std.mem.eql(u8, (try match_key(a, row)).?, (try match_key(a, different)).?));
    different = row;
    different.account = "1914";
    try std.testing.expect(!std.mem.eql(u8, (try match_key(a, row)).?, (try match_key(a, different)).?));
    different = row;
    different.payee = "Shop B";
    try std.testing.expect(!std.mem.eql(u8, (try match_key(a, row)).?, (try match_key(a, different)).?));
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
    const hash = try arena.dupe(u8, &model.digest(try source_bytes(arena, data_url)));
    const stmt = try db.db.prepare("INSERT INTO statements(hash,name,data_url) VALUES (?1,?2,?3) ON CONFLICT(hash) DO NOTHING");
    defer stmt.finalize();
    try stmt.bindText(1, hash);
    try stmt.bindText(2, name);
    try stmt.bindText(3, data_url);
    _ = try stmt.step();
    return hash;
}

pub fn sources(db: ledger_mod.Ledger, arena: std.mem.Allocator) ![]Source {
    const query = try db.db.prepare("SELECT hash,name,status,parser FROM statements ORDER BY rowid DESC LIMIT 1001");
    defer query.finalize();
    var rows: std.ArrayList(Source) = .empty;
    while (try query.step()) {
        if (rows.items.len == 1000) return error.TooManyStatements;
        try rows.append(arena, .{ .hash = try query.text(arena, 0), .name = try query.text(arena, 1), .status = try query.text(arena, 2), .format = if (is_bank_parser(try query.text(arena, 3))) .json else .pdf });
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

// Identity deliberately keeps the exact date, amount, currency and account.
// Merchant case/punctuation are formatting; broad brand aliases and nearby
// dates remain possible matches requiring a decision, never automatic matches.
fn match_key(a: std.mem.Allocator, row: Row) !?[]const u8 {
    var name: std.ArrayList(u8) = .empty;
    for (row.payee) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte >= 128) try name.append(a, std.ascii.toUpper(byte));
    }
    if (name.items.len == 0) return null;
    const json = try std.json.Stringify.valueAlloc(a, .{ row.date, row.amount, row.currency, row.account, name.items }, .{});
    return try a.dupe(u8, &model.digest(json));
}

pub fn review(db: ledger_mod.Ledger, a: std.mem.Allocator, hash: []const u8) ![]Observation {
    const rows = try observations(db, a, hash);
    var used: std.StringHashMapUnmanaged(void) = .empty;
    defer used.deinit(a);
    for (rows) |row| if (row.expense_id) |id| try used.put(a, id, {});
    // A payment already claimed by a bank occurrence cannot satisfy a second
    // identical purchase in a later capture. PDF evidence may still share it.
    const claimed = try db.db.prepare("SELECT o.expense_id FROM observations o JOIN statements s ON s.hash=o.statement_hash WHERE s.parser IN (?1,?3,?4) AND o.expense_id IS NOT NULL AND s.parser=(SELECT parser FROM statements WHERE hash=?2)");
    defer claimed.finalize();
    try claimed.bindText(1, bank_parser);
    try claimed.bindText(2, hash);
    try claimed.bindText(3, bci_bank_parser);
    try claimed.bindText(4, boa_bank_parser);
    while (try claimed.step()) try used.put(a, try claimed.text(a, 0), {});
    var buckets: std.StringHashMapUnmanaged(std.ArrayList(model.Expense)) = .empty;
    defer buckets.deinit(a);
    for (try db.list(a)) |payment| {
        if (used.contains(payment.id)) continue;
        const key = try match_key(a, .{ .date = payment.date, .amount = payment.amount, .currency = payment.currency, .payee = payment.payee, .account = payment.account, .category = payment.category }) orelse continue;
        const slot = try buckets.getOrPut(a, key);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(a, payment);
    }
    for (rows) |*row| {
        if (row.expense_id != null or row.ignored) continue;
        const key = try match_key(a, row.source) orelse continue;
        const bucket = buckets.getPtr(key) orelse continue;
        if (bucket.items.len == 0) continue;
        const payment = bucket.items[bucket.items.len - 1];
        bucket.items.len -= 1;
        row.match = .{ .id = payment.id, .revision = payment.revision };
    }
    return rows;
}

pub fn reconcile(db: ledger_mod.Ledger, arena: std.mem.Allocator, hash: []const u8, decisions: []const Decision) !usize {
    if (decisions.len > 10000) return error.TooManyExpenses;
    try db.db.exec("BEGIN IMMEDIATE");
    errdefer db.db.exec("ROLLBACK") catch {};
    const observed = try review(db, arena, hash);
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
            // Recheck inside the write transaction: another device/import may
            // have saved this charge after the review screen was opened.
            if (row.match != null) return error.DuplicateStatementPayment;
            const rev = try db.write_expense(expense(row.source, target), 0);
            try db.record_change(target, rev);
        } else if (decision.action == .link) {
            const payment = payments.get(target) orelse return error.ExpenseNotFound;
            if (payment.amount != row.source.amount or !std.mem.eql(u8, payment.currency, row.source.currency)) return error.ReconciliationAmountMismatch;
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

/// Bank snapshots contain normalized observations only; never a login/session.
pub const bank_parser = "santander-live-v1";
pub const bci_bank_parser = "bci-live-v1";
pub const boa_bank_parser = "boa-live-v1";
pub const bank_prefix = "data:application/vnd.penny-goblin.santander+json;base64,";
pub const bank_prefix_generic = "data:application/vnd.penny-goblin.bank+json;base64,";
pub const Bank = enum {
    santander,
    bci,
    boa,

    pub fn name(bank: Bank) []const u8 {
        return switch (bank) {
            .santander => "Santander",
            .bci => "BCI",
            .boa => "Bank of America",
        };
    }

    pub fn currency(bank: Bank) []const u8 {
        return if (bank == .boa) "USD" else "CLP";
    }

    pub fn command(bank: Bank) []const u8 {
        return switch (bank) {
            .santander => "import_santander",
            .bci => "import_bci",
            .boa => "import_boa",
        };
    }
};
pub const BankSource = struct { schema: u8 = 1, bank: Bank = .santander, month: []const u8, rows: []const Row };
pub const BankImport = struct { hash: ?[]const u8 = null, added: usize = 0 };

pub fn parser_for(bank: Bank) []const u8 {
    return switch (bank) {
        .santander => bank_parser,
        .bci => bci_bank_parser,
        .boa => boa_bank_parser,
    };
}

pub fn is_bank_parser(parser: []const u8) bool {
    for (std.meta.tags(Bank)) |bank| if (std.mem.eql(u8, parser, parser_for(bank))) return true;
    return false;
}

pub fn bank_data(data_url: []const u8) ?[]const u8 {
    for ([_][]const u8{ bank_prefix, bank_prefix_generic }) |prefix| {
        if (std.mem.startsWith(u8, data_url, prefix)) return data_url[prefix.len..];
    }
    return null;
}

pub fn known_parser(parser: []const u8) bool {
    return supported_parser(parser) or is_bank_parser(parser);
}

pub fn source_bytes(a: std.mem.Allocator, data_url: []const u8) ![]const u8 {
    const encoded = bank_data(data_url) orelse return pdf_bytes(a, data_url);
    if (encoded.len > 4 * 1024 * 1024) return error.InvalidStatement;
    const decoder = std.base64.standard.Decoder;
    const bytes = try a.alloc(u8, try decoder.calcSizeForSlice(encoded));
    try decoder.decode(bytes, encoded);
    const source = try bank_source(a, bytes);
    if (std.mem.startsWith(u8, data_url, bank_prefix) and source.bank != .santander) return error.InvalidStatement;
    return bytes;
}

pub fn bank_source(a: std.mem.Allocator, json: []const u8) !BankSource {
    if (json.len > 3 * 1024 * 1024) return error.InvalidStatement;
    // Unknown fields are rejected: no tokens, headers or raw bank payloads.
    const value = try std.json.parseFromSliceLeaky(BankSource, a, json, .{});
    if (value.schema != 1 or value.month.len != 7 or value.rows.len == 0 or value.rows.len > 10000) return error.InvalidStatement;
    const first = try std.fmt.allocPrint(a, "{s}-01", .{value.month});
    if (!model.valid_date(first)) return error.InvalidStatement;
    for (value.rows) |row| {
        try model.validate(expense(row, &model.digest("validation")));
        if (!std.mem.eql(u8, row.date[0..7], value.month) or !std.mem.eql(u8, row.currency, value.bank.currency())) return error.InvalidStatement;
    }
    return value;
}

/// No upstream movement ID exists. Fingerprint date/amount/merchant/account
/// and its occurrence in the snapshot, preserving two genuine equal purchases.
/// Categories and reviewed payment corrections are not movement identity.
pub fn bank_ids(a: std.mem.Allocator, rows: []const Row) ![][64]u8 {
    return bank_ids_for(a, .santander, rows);
}

pub fn bank_ids_for(a: std.mem.Allocator, bank: Bank, rows: []const Row) ![][64]u8 {
    const ids = try a.alloc([64]u8, rows.len);
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    defer counts.deinit(a);
    for (rows, 0..) |row, i| {
        const key = try std.json.Stringify.valueAlloc(a, .{ .date = row.date, .amount = row.amount, .payee = row.payee, .account = row.account, .currency = row.currency }, .{});
        const slot = try counts.getOrPut(a, key);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += 1;
        ids[i] = model.digest(try std.fmt.allocPrint(a, "{s}-movements-v1:{s}:{d}", .{ @tagName(bank), key, slot.value_ptr.* }));
    }
    return ids;
}

// Reuse legacy IDs when Santander changes only merchant case or punctuation.
// Consume each saved occurrence once, including ignored and linked rows.
fn known_bank_rows(db: ledger_mod.Ledger, a: std.mem.Allocator, bank: Bank, rows: []const Row, ids: []const [64]u8) ![]bool {
    const known = try a.alloc(bool, rows.len);
    @memset(known, false);
    var exact: std.StringHashMapUnmanaged(void) = .empty;
    defer exact.deinit(a);
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    defer counts.deinit(a);
    const query = try db.db.prepare("SELECT o.id,o.source_json FROM observations o JOIN statements s ON s.hash=o.statement_hash WHERE s.parser=?1 LIMIT 100001");
    defer query.finalize();
    try query.bindText(1, parser_for(bank));
    var count: usize = 0;
    while (try query.step()) {
        count += 1;
        if (count > 100000) return error.TooManyExpenses;
        try exact.put(a, try query.text(a, 0), {});
        const row = try std.json.parseFromSliceLeaky(Row, a, try query.text(a, 1), .{ .ignore_unknown_fields = true });
        const key = try match_key(a, row) orelse continue;
        const slot = try counts.getOrPut(a, key);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += 1;
    }
    // Reserve exact identities first so formatting variants cannot consume them.
    for (rows, ids, 0..) |row, id, i| {
        if (!exact.contains(&id)) continue;
        known[i] = true;
        const key = try match_key(a, row) orelse continue;
        if (counts.getPtr(key)) |remaining| if (remaining.* > 0) {
            remaining.* -= 1;
        };
    }
    for (rows, 0..) |row, i| {
        if (known[i]) continue;
        const key = try match_key(a, row) orelse continue;
        const remaining = counts.getPtr(key) orelse continue;
        if (remaining.* == 0) continue;
        remaining.* -= 1;
        known[i] = true;
    }
    return known;
}

/// Stage only new observations. Overlapping snapshots, ignored observations,
/// edited payments and deleted payments never turn into another new charge.
pub fn stage_bank(db: ledger_mod.Ledger, a: std.mem.Allocator, month: []const u8, rows: []const Row) !BankImport {
    return stage_bank_for(db, a, .santander, month, rows);
}

pub fn stage_bank_for(db: ledger_mod.Ledger, a: std.mem.Allocator, bank: Bank, month: []const u8, rows: []const Row) !BankImport {
    if (rows.len == 0) return .{};
    // Keep Santander's existing wire representation and source hashes intact.
    const json = if (bank == .santander)
        try std.json.Stringify.valueAlloc(a, .{ .schema = @as(u8, 1), .month = month, .rows = rows }, .{})
    else
        try std.json.Stringify.valueAlloc(a, BankSource{ .bank = bank, .month = month, .rows = rows }, .{});
    _ = try bank_source(a, json);
    const ids = try bank_ids_for(a, bank, rows);
    try db.db.exec("BEGIN IMMEDIATE");
    errdefer db.db.exec("ROLLBACK") catch {};
    var added: usize = 0;
    const known = try known_bank_rows(db, a, bank, rows, ids);
    for (known) |exists| if (!exists) {
        added += 1;
    };
    if (added == 0) {
        try db.db.exec("COMMIT");
        return .{};
    }
    const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
    const data_url = try std.fmt.allocPrint(a, "{s}{s}", .{ if (bank == .santander) bank_prefix else bank_prefix_generic, std.base64.standard.Encoder.encode(encoded, json) });
    const hash = try stage(db, a, try std.fmt.allocPrint(a, "{s} {s} · {s}", .{ bank.name(), bank.currency(), month }), data_url);
    for (rows, ids, 0..) |row, id, i| {
        if (known[i]) continue;
        const insert = try db.db.prepare("INSERT INTO observations(id,statement_hash,position,source_json) VALUES (?1,?2,?3,?4)");
        defer insert.finalize();
        try insert.bindText(1, &id);
        try insert.bindText(2, hash);
        try insert.bindInt(3, @intCast(i));
        try insert.bindText(4, try std.json.Stringify.valueAlloc(a, row, .{}));
        _ = try insert.step();
    }
    const update = try db.db.prepare("UPDATE statements SET status='review',parser=?2 WHERE hash=?1");
    defer update.finalize();
    try update.bindText(1, hash);
    try update.bindText(2, parser_for(bank));
    _ = try update.step();
    try db.db.exec("COMMIT");
    return .{ .hash = hash, .added = added };
}

test "banks have separate capture identities and retain Santander fingerprint compatibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const row: Row = .{ .date = "2026-10-18", .amount = 1200, .payee = "TEST SHOP", .account = "1234", .category = "Other" };
    const santander = try bank_ids(a, &.{row});
    const bci = try bank_ids_for(a, .bci, &.{row});
    try std.testing.expect(!std.mem.eql(u8, &santander[0], &bci[0]));
    const key = try std.json.Stringify.valueAlloc(a, .{ .date = row.date, .amount = row.amount, .payee = row.payee, .account = row.account, .currency = row.currency }, .{});
    const old_id = model.digest(try std.fmt.allocPrint(a, "santander-movements-v1:{s}:1", .{key}));
    try std.testing.expectEqualSlices(u8, &old_id, &santander[0]);
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const captured = try stage_bank_for(db, a, .bci, "2026-10", &.{row});
    const captured_sources = try sources(db, a);
    try std.testing.expectEqual(@as(usize, 1), captured_sources.len);
    try std.testing.expect(captured_sources[0].format == .json);
    try std.testing.expectEqual(@as(usize, 0), (try stage_bank_for(db, a, .bci, "2026-10", &.{row})).added);
    const observed = try review(db, a, captured.hash.?);
    try std.testing.expectEqualSlices(u8, &bci[0], observed[0].id);
}

test "Bank of America USD review matches once, saves cents and does not replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const row: Row = .{ .date = "2026-10-18", .amount = 1234, .currency = "USD", .payee = "TEST SHOP", .account = "BofA checking", .category = "Other" };
    var saved = expense(row, &model.digest("existing-bofa"));
    saved.category = "Reviewed category";
    _ = try db.save(a, .{ .expense = saved });
    const captured = try stage_bank_for(db, a, .boa, "2026-10", &.{ row, row });
    var obs = try review(db, a, captured.hash.?);
    try std.testing.expect(obs[0].match != null and obs[1].match == null);
    _ = try reconcile(db, a, captured.hash.?, &.{.{ .observation_id = obs[0].id, .action = .link, .expense_id = obs[0].match.?.id, .expected_revision = obs[0].match.?.revision }});
    _ = try reconcile(db, a, captured.hash.?, &.{.{ .observation_id = obs[1].id, .action = .create }});
    const payments = try db.list(a);
    try std.testing.expectEqual(@as(usize, 2), payments.len);
    for (payments) |payment| {
        try std.testing.expectEqualStrings("USD", payment.currency);
        try std.testing.expectEqual(@as(i64, 1234), payment.amount);
    }
    try std.testing.expectEqual(@as(usize, 0), (try stage_bank_for(db, a, .boa, "2026-10", &.{ row, row })).added);
    obs = try review(db, a, captured.hash.?);
    try std.testing.expect(obs[0].expense_id != null and obs[1].expense_id != null);
    var clp = row;
    clp.currency = "CLP";
    try std.testing.expectError(error.InvalidStatement, stage_bank_for(db, a, .boa, "2026-10", &.{clp}));
}

test "bank capture replay, overlapping snapshots and identical purchases remain reviewable and idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const row: Row = .{ .date = "2026-10-18", .amount = 1200, .payee = "TEST SHOP", .account = "1234", .category = "Other" };
    const first = try stage_bank(db, a, "2026-10", &.{ row, row });
    try std.testing.expectEqual(@as(usize, 2), first.added);
    try std.testing.expectEqual(@as(usize, 0), (try db.list(a)).len); // Staging never spends.
    const obs = try observations(db, a, first.hash.?);
    _ = try reconcile(db, a, first.hash.?, &.{ .{ .observation_id = obs[0].id, .action = .create }, .{ .observation_id = obs[1].id, .action = .ignore } });
    var payment = (try db.list(a))[0];
    payment.payee = "Reviewed shop";
    _ = try db.save(a, .{ .expense = payment, .expected_revision = payment.revision });
    try std.testing.expectEqual(@as(usize, 0), (try stage_bank(db, a, "2026-10", &.{ row, row })).added);
    var newer = row;
    newer.date = "2026-10-19";
    const second = try stage_bank(db, a, "2026-10", &.{ newer, row, row });
    try std.testing.expectEqual(@as(usize, 1), second.added);
    try std.testing.expectEqual(@as(usize, 1), (try observations(db, a, second.hash.?)).len);
    // The extra occurrence is a real third equal purchase, not a duplicate.
    try std.testing.expectEqual(@as(usize, 1), (try stage_bank(db, a, "2026-10", &.{ row, row, row })).added);
    const saved = (try db.list(a))[0];
    try std.testing.expectEqualStrings("Reviewed shop", saved.payee);
    try db.remove(saved.id, saved.revision);
    try std.testing.expectEqual(@as(usize, 0), (try stage_bank(db, a, "2026-10", &.{ row, row, row })).added);
}

test "bank source validation rejects credentials and wrong-month rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const row: Row = .{ .date = "2026-09-18", .amount = 1200, .payee = "TEST SHOP", .account = "1234", .category = "Other" };
    try std.testing.expectError(error.InvalidStatement, stage_bank(db, a, "2026-10", &.{row}));
    try std.testing.expectEqual(@as(usize, 0), (try sources(db, a)).len);
    try std.testing.expectError(error.UnknownField, bank_source(a, "{\"schema\":1,\"month\":\"2026-10\",\"rows\":[],\"cookie\":\"never retained\"}"));
}

test "bank source preparation and transaction clean up on allocation failure" {
    const T = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const db = try ledger_mod.Ledger.open(":memory:");
            defer db.close();
            const row: Row = .{ .date = "2026-10-18", .amount = 1200, .payee = "TEST SHOP", .account = "1234", .category = "Other" };
            _ = try stage_bank(db, arena.allocator(), "2026-10", &.{ row, row });
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, T.run, .{});
}

test "bank formatting changes retain ignored and linked decisions across captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const row: Row = .{ .date = "2026-10-22", .amount = 1200, .payee = "TEST*SHOP", .account = "9526", .category = "Other" };
    const first = try stage_bank(db, a, "2026-10", &.{ row, row });
    const obs = try observations(db, a, first.hash.?);
    _ = try reconcile(db, a, first.hash.?, &.{ .{ .observation_id = obs[0].id, .action = .ignore }, .{ .observation_id = obs[1].id, .action = .create } });
    var formatted = row;
    formatted.payee = "Test Shop";
    formatted.category = "Shopping";
    try std.testing.expectEqual(@as(usize, 0), (try stage_bank(db, a, "2026-10", &.{ formatted, formatted })).added);
    const next = try stage_bank(db, a, "2026-10", &.{ formatted, formatted, formatted });
    try std.testing.expectEqual(@as(usize, 1), next.added);
    const pending = try review(db, a, next.hash.?);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expect(pending[0].match == null);
    const original = try observations(db, a, first.hash.?);
    try std.testing.expect(original[0].ignored);
    try std.testing.expect(original[1].expense_id != null);
}
