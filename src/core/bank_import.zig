//! Normalize supported bank exports into current-month expense snapshots.
const std = @import("std");
const statements = @import("statements.zig");
const model = @import("model.zig");

pub fn current_rows(a: std.mem.Allocator, bank: statements.Bank, parsed: statements.Parsed, account: []const u8, today: []const u8) ![]statements.Row {
    if (!model.valid_date(today) or parsed.rows.len > 10000) return error.InvalidBankExport;
    const supported = switch (bank) {
        .bci => std.mem.eql(u8, parsed.parser, "bci-card-v1") or std.mem.eql(u8, parsed.parser, "bci-cartola-v1"),
        .boa => std.mem.eql(u8, parsed.parser, "boa-csv-v1"),
        .santander => false,
    };
    if (!supported) return error.InvalidBankExport;
    const card = std.mem.trim(u8, account, " \t\r\n");
    try model.text(card, 120, false);
    var rows: std.ArrayList(statements.Row) = .empty;
    for (parsed.rows) |source| {
        try model.validate(.{ .id = &model.digest("validation"), .date = source.date, .amount = source.amount, .currency = source.currency, .payee = source.payee, .account = source.account, .category = source.category });
        if (!std.mem.eql(u8, source.currency, bank.currency())) return error.InvalidBankExport;
        if (!std.mem.eql(u8, source.date[0..7], today[0..7]) or std.mem.order(u8, source.date, today) == .gt) continue;
        var row = source;
        row.account = try a.dupe(u8, card);
        try rows.append(a, row);
    }
    std.mem.sort(statements.Row, rows.items, {}, struct {
        fn less(_: void, left: statements.Row, right: statements.Row) bool {
            const date = std.mem.order(u8, left.date, right.date);
            if (date != .eq) return date == .gt;
            const payee = std.mem.order(u8, left.payee, right.payee);
            if (payee != .eq) return payee == .lt;
            return left.amount < right.amount;
        }
    }.less);
    return rows.toOwnedSlice(a);
}

test "BCI current-month imports retain genuine repeated expenses and reject other bank parsers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const row: statements.Row = .{ .date = "2026-10-18", .amount = 1200, .payee = "TEST BCI SHOP", .account = "1234", .category = "Other" };
    var old = row;
    old.date = "2026-09-30";
    var future = row;
    future.date = "2026-10-20";
    const rows = try current_rows(a, .bci, .{ .parser = "bci-card-v1", .rows = &.{ old, row, future, row } }, "BCI card", "2026-10-19");
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("BCI card", rows[0].account);
    try std.testing.expectError(error.InvalidBankExport, current_rows(a, .bci, .{ .parser = "santander-web-v1", .rows = &.{row} }, "BCI", "2026-10-19"));
    const cartola = try current_rows(a, .bci, .{ .parser = "bci-cartola-v1", .rows = &.{row} }, "BCI checking", "2026-10-19");
    try std.testing.expectEqualStrings("BCI checking", cartola[0].account);
}

test "Bank of America imports current-month USD cents and requires its own parser" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const row: statements.Row = .{ .date = "2026-10-18", .amount = 1234, .currency = "USD", .payee = "TEST SHOP", .account = "Bank of America", .category = "Other" };
    var old = row;
    old.date = "2026-09-30";
    var future = row;
    future.date = "2026-10-20";
    const rows = try current_rows(a, .boa, .{ .parser = "boa-csv-v1", .rows = &.{ old, row, future, row } }, "BofA checking", "2026-10-19");
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("BofA checking", rows[0].account);
    try std.testing.expectEqualStrings("USD", rows[0].currency);
    try std.testing.expectEqual(@as(i64, 1234), rows[0].amount);
    try std.testing.expectError(error.InvalidBankExport, current_rows(a, .boa, .{ .parser = "bci-card-v1", .rows = &.{row} }, "BofA", "2026-10-19"));
    var clp = row;
    clp.currency = "CLP";
    try std.testing.expectError(error.InvalidBankExport, current_rows(a, .boa, .{ .parser = "boa-csv-v1", .rows = &.{clp} }, "BofA", "2026-10-19"));
}
