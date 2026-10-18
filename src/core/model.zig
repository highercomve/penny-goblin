const std = @import("std");

pub const Expense = struct {
    id: []const u8,
    revision: i64 = 0,
    date: []const u8,
    amount: i64,
    currency: []const u8 = "CLP",
    payee: []const u8,
    account: []const u8 = "Debit",
    category: []const u8 = "Other",
    notes: []const u8 = "",
    reference: []const u8 = "",
    location: []const u8 = "",
    deleted: bool = false,
    evidence_count: i64 = 0,
};

pub const Save = struct {
    expense: Expense,
    expected_revision: i64 = 0,
    document: ?Document = null,
};

pub const Document = struct {
    data_url: []const u8,
    extraction: []const u8 = "",
};

/// The currencies a payment may be in; `decimals`: its amount is stored in
/// that many minor units (USD in cents, CLP in whole pesos). Each currency's
/// totals stay apart: budgets are in CLP.
pub const Currency = struct { code: []const u8, decimals: u8 };
pub const currencies = [_]Currency{ .{ .code = "CLP", .decimals = 0 }, .{ .code = "USD", .decimals = 2 } };

pub fn currency(code: []const u8) ?Currency {
    for (currencies) |c| if (std.mem.eql(u8, c.code, code)) return c;
    return null;
}

/// An amount as typed, in the currency's minor units: CLP in whole pesos
/// ("53970"), USD in dollars with up to two decimals ("46.63" → 4663).
pub fn parse_amount(typed: []const u8, code: []const u8) !i64 {
    const c = currency(code) orelse return error.UnsupportedCurrency;
    const t = std.mem.trim(u8, typed, " ");
    const dot = std.mem.indexOfScalar(u8, t, '.');
    const whole = t[0 .. dot orelse t.len];
    const fraction = if (dot) |d| t[d + 1 ..] else "";
    if (whole.len == 0 or fraction.len > c.decimals or (dot != null and fraction.len == 0)) return error.InvalidAmount;
    for (t) |ch| if (!std.ascii.isDigit(ch) and ch != '.') return error.InvalidAmount;
    var amount = std.fmt.parseInt(i64, whole, 10) catch return error.InvalidAmount;
    for (0..c.decimals) |i| {
        amount = std.math.mul(i64, amount, 10) catch return error.InvalidAmount;
        if (i < fraction.len) amount += fraction[i] - '0';
    }
    return amount;
}

/// An amount as the editor shows it: "53970", or "46.63" in USD.
pub fn amount_input(buf: []u8, amount: i64, code: []const u8) ![]const u8 {
    const decimals = (currency(code) orelse return error.UnsupportedCurrency).decimals;
    if (decimals == 0) return std.fmt.bufPrint(buf, "{d}", .{amount});
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}", .{ @divTrunc(amount, 100), @as(u64, @intCast(@mod(amount, 100))) });
}

test parse_amount {
    try std.testing.expectEqual(@as(i64, 53970), try parse_amount("53970", "CLP"));
    try std.testing.expectEqual(@as(i64, 4663), try parse_amount("46.63", "USD"));
    try std.testing.expectEqual(@as(i64, 4660), try parse_amount("46.6", "USD"));
    try std.testing.expectEqual(@as(i64, 1000), try parse_amount("10", "USD"));
    try std.testing.expectError(error.InvalidAmount, parse_amount("53.970", "CLP"));
    try std.testing.expectError(error.InvalidAmount, parse_amount("1.234", "USD"));
    try std.testing.expectError(error.InvalidAmount, parse_amount("12.", "USD"));
    try std.testing.expectError(error.UnsupportedCurrency, parse_amount("1", "EUR"));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("46.63", try amount_input(&buf, 4663, "USD"));
    try std.testing.expectEqualStrings("53970", try amount_input(&buf, 53970, "CLP"));
}

pub fn valid_id(id: []const u8) bool {
    if (id.len != 64) return false;
    for (id) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

pub fn validate(expense: Expense) !void {
    if (!valid_id(expense.id)) return error.InvalidId;
    if (expense.amount <= 0 or expense.amount > 1_000_000_000_000) return error.InvalidAmount;
    if (currency(expense.currency) == null) return error.UnsupportedCurrency;
    if (!valid_date(expense.date)) return error.InvalidDate;
    try text(expense.payee, 240, false);
    try text(expense.account, 120, false);
    try text(expense.category, 120, false);
    try text(expense.notes, 4000, true);
    try text(expense.reference, 240, true);
    try text(expense.location, 500, true);
}

pub fn text(value: []const u8, max: usize, empty: bool) !void {
    if (value.len > max or (!empty and std.mem.trim(u8, value, " \t\r\n").len == 0)) return error.InvalidText;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
    for (value) |ch| if (ch == 0) return error.InvalidText;
}

pub fn valid_date(date: []const u8) bool {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return false;
    for (date, 0..) |ch, i| if (i != 4 and i != 7 and !std.ascii.isDigit(ch)) return false;
    const year = std.fmt.parseInt(u16, date[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, date[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, date[8..10], 10) catch return false;
    if (year < 1900 or year > 2199 or month < 1 or month > 12) return false;
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const days = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return day >= 1 and day <= days[month - 1];
}

pub fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

test "money and calendar validation" {
    try std.testing.expect(valid_date("2026-10-14"));
    try std.testing.expect(valid_date("2024-02-29"));
    try std.testing.expect(!valid_date("2026-02-29"));
    try std.testing.expect(!valid_date("2026-10-00"));
    try std.testing.expect(!valid_date("2026-1a-01"));
    const e: Expense = .{ .id = &digest("test"), .date = "2026-10-14", .amount = 40000, .payee = "Johana" };
    try validate(e);
    var invalid = e;
    invalid.amount = -1;
    try std.testing.expectError(error.InvalidAmount, validate(invalid));
}
