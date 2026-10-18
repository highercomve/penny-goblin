//! Compare compiled reporting against the unmodified JavaScript frontend.
const std = @import("std");
const reports = @import("core/reporting.zig");
const legacy = @import("core/legacy.zig");
const model = @import("core/model.zig");
const Monthly = struct { month: []const u8, actual: []const u8, variable: []const u8, fixed: []const u8, special: []const u8, forecast: []const u8, remaining: []const u8 };
const Merchant = struct { payee: []const u8, brand: []const u8, exact: []const u8 };
const Oracle = struct { months: []Monthly, merchants: []Merchant };
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ExpectedExportAndOraclePaths;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(24 * 1024 * 1024));
    const expected = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], a, .limited(24 * 1024 * 1024));
    const bundle = try std.json.parseFromSliceLeaky(legacy.Bundle, a, data, .{ .ignore_unknown_fields = true });
    const settings = try std.json.parseFromSliceLeaky(reports.Settings, a, data, .{ .ignore_unknown_fields = true });
    const oracle = try std.json.parseFromSliceLeaky(Oracle, a, expected, .{});
    const rows = try a.alloc(model.Expense, bundle.transactions.len);
    for (bundle.transactions, rows) |r, *row| {
        const date = if (r.date.len == 8 and r.date[2] == '/') blk: {
            const year = try std.fmt.parseInt(u8, r.date[6..8], 10);
            break :blk try std.fmt.allocPrint(a, "{d}-{s}-{s}", .{ @as(u16, if (year <= 68) 2000 else 1900) + year, r.date[3..5], r.date[0..2] });
        } else r.date;
        row.* = .{ .id = "", .date = date, .payee = r.desc, .amount = r.amount, .category = r.category, .account = r.card };
    }
    for (oracle.months) |month| {
        var selected: std.ArrayList(model.Expense) = .empty;
        for (rows) |row| if (std.mem.startsWith(u8, row.date, month.month)) try selected.append(a, row);
        const total = reports.totals(selected.items, settings);
        inline for (.{ .{ "actual", "actual" }, .{ "variable", "variable" }, .{ "fixed", "fixed" }, .{ "special", "special" }, .{ "forecast", "forecast" }, .{ "remaining", "actual_remaining" } }) |pair| {
            if (try std.fmt.parseInt(i64, @field(month, pair[0]), 10) != @field(total, pair[1])) return error.MonthlyReportMismatch;
        }
    }
    var merchant_failures: usize = 0;
    for (oracle.merchants, 0..) |m, index| {
        if (!std.mem.eql(u8, m.brand, try reports.merchant(a, m.payee, settings, true))) {
            merchant_failures += 1;
            std.debug.print("Merchant mismatch at row {d}; non-ASCII: {any} (values withheld).\n", .{ index, for (m.payee) |ch| {
                if (ch >= 128) break true;
            } else false });
        }
        if (!std.mem.eql(u8, m.exact, try reports.merchant(a, m.payee, settings, false))) return error.ExactMerchantMismatch;
    }
    if (merchant_failures > 0) {
        std.debug.print("Merchant naming mismatches: {d} (values withheld).\n", .{merchant_failures});
        return error.MerchantReportMismatch;
    }
    std.debug.print("Reporting parity verified: {d} months and {d} merchant rows. Values withheld.\n", .{ oracle.months.len, oracle.merchants.len });
}
