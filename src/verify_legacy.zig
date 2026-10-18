//! Read-only acceptance check: imports an export into a disposable in-memory DB.
const std = @import("std");
const ledger_mod = @import("core/ledger.zig");
const legacy = @import("core/legacy.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return error.ExpectedExportPath;
    const json = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(24 * 1024 * 1024));
    try verify(arena, json);
    std.debug.print("Migration verified: counts, totals, settings and repeat import match. No source files changed.\n", .{});
}

fn verify(arena: std.mem.Allocator, json: []const u8) !void {
    const bundle = try std.json.parseFromSliceLeaky(legacy.Bundle, arena, json, .{ .ignore_unknown_fields = true });
    const ledger = try ledger_mod.Ledger.open(":memory:");
    defer ledger.close();
    const result = try legacy.import(ledger, arena, json);
    const rows = try ledger.list(arena);
    if (result.imported != bundle.transactions.len or rows.len != bundle.transactions.len or
        result.skipped != 0 or !result.settings_imported) return error.MigrationCountMismatch;
    var expected_total: i128 = 0;
    for (bundle.transactions) |row| expected_total += row.amount;
    var actual_total: i128 = 0;
    for (rows) |row| actual_total += row.amount;
    if (actual_total != expected_total) return error.MigrationTotalMismatch;

    const fallback = [_]legacy.Fixed{.{ .name = "Fixed expenses", .amount = bundle.fixed_expenses }};
    const expected: legacy.Settings = .{
        .account_owners = bundle.account_owners,
        .salary = bundle.salary,
        .fixed_expenses_items = if (bundle.fixed_expenses_items.len > 0) bundle.fixed_expenses_items else if (bundle.fixed_expenses > 0) &fallback else &.{},
        .cards_config = bundle.cards_config,
        .vendors_config = bundle.vendors_config,
        .categories = bundle.categories,
        .special_cases = bundle.special_cases,
    };
    const expected_json = try std.json.Stringify.valueAlloc(arena, expected, .{});
    const actual_json = try ledger.setting(arena, "budget");
    if (!std.mem.eql(u8, expected_json, actual_json)) return error.MigrationSettingsMismatch;
    const again = try legacy.import(ledger, arena, json);
    if (again.imported != 0 or again.skipped != rows.len or again.settings_imported or
        (try ledger.list(arena)).len != rows.len) return error.MigrationRepeatMismatch;
    if (!std.mem.eql(u8, actual_json, try ledger.setting(arena, "budget"))) return error.MigrationSettingsMismatch;
}
