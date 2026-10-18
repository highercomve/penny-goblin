//! Settings edits and reviewed bulk categorization share one atomic boundary.
const std = @import("std");
const ledger_mod = @import("ledger.zig");
const legacy = @import("legacy.zig");
const model = ledger_mod.model;
pub const Target = struct { id: []const u8, revision: i64 };
pub const Edit = struct {
    settings: legacy.Settings,
    expected: []const u8,
    targets: []const Target = &.{},
    category: []const u8 = "",
};

pub fn apply(db: ledger_mod.Ledger, arena: std.mem.Allocator, edit: Edit) !usize {
    try validate(edit.settings);
    if (edit.targets.len > 10000) return error.TooManyExpenses;
    if (edit.targets.len > 0) try model.text(edit.category, 120, false);
    const json = try std.json.Stringify.valueAlloc(arena, edit.settings, .{});
    if (json.len > 256 * 1024 or edit.expected.len > 256 * 1024) return error.SettingsTooLarge;
    try db.db.exec("BEGIN IMMEDIATE");
    errdefer db.db.exec("ROLLBACK") catch {};
    if (!std.mem.eql(u8, edit.expected, try db.setting(arena, "budget"))) return error.SettingsConflict;
    const rows = try db.list(arena);
    var by_id: std.StringHashMapUnmanaged(model.Expense) = .empty;
    defer by_id.deinit(arena);
    for (rows) |row| try by_id.put(arena, row.id, row);
    for (edit.targets) |target| {
        var row = by_id.get(target.id) orelse return error.ExpenseNotFound;
        if (target.revision < 1 or target.revision == std.math.maxInt(i64)) return error.InvalidRevision;
        row.category = edit.category;
        try model.validate(row);
        const revision = try db.write_expense(row, target.revision);
        try db.record_change(row.id, revision);
    }
    try db.put_setting("budget", json);
    try db.db.exec("COMMIT");
    return edit.targets.len;
}

pub fn validate(settings: legacy.Settings) !void {
    try legacy.validate_settings(settings);
    try validate_map(settings.cards_config, .account);
    try validate_map(settings.categories, .keywords);
    try validate_map(settings.vendors_config, .label);
    try validate_map(settings.special_cases, .label);
}

const MapKind = enum { account, keywords, label };
const max_keywords = 1000;
fn validate_map(value: std.json.Value, kind: MapKind) !void {
    if (value == .null) return;
    if (value != .object or value.object.count() > 1000) return error.InvalidRules;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        try model.text(entry.key_ptr.*, if (kind == .keywords or kind == .account) 120 else 240, false);
        const item = entry.value_ptr.*;
        switch (kind) {
            .label => {
                if (item != .string) return error.InvalidRules;
                try model.text(item.string, 120, false);
            },
            .account => {
                if (item == .string) try model.text(item.string, 120, false) else {
                    if (item != .object) return error.InvalidRules;
                    const holder = item.object.get("holder") orelse return error.InvalidRules;
                    if (holder != .string) return error.InvalidRules;
                    try model.text(holder.string, 120, false);
                }
            },
            .keywords => {
                // Imported web rules already exceed 100 keywords for one category.
                if (item != .array or item.array.items.len > max_keywords) return error.InvalidRules;
                for (item.array.items) |keyword| {
                    if (keyword != .string) return error.InvalidRules;
                    try model.text(keyword.string, 240, false);
                }
            },
        }
    }
}

test "settings conflict and stale bulk edit roll back rules and all payments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const e: model.Expense = .{ .id = &model.digest("bulk"), .date = "2026-10-16", .amount = 1, .payee = "Market" };
    _ = try db.save(a, .{ .expense = e });
    try std.testing.expectError(error.RevisionConflict, apply(db, a, .{
        .settings = .{ .salary = 42 },
        .expected = "{}",
        .category = "Food",
        .targets = &.{ .{ .id = e.id, .revision = 1 }, .{ .id = e.id, .revision = 1 } },
    }));
    try std.testing.expectEqualStrings("{}", try db.setting(a, "budget"));
    try std.testing.expectEqualStrings("Other", (try db.list(a))[0].category);
    _ = try apply(db, a, .{ .settings = .{ .salary = 42 }, .expected = "{}" });
    try std.testing.expectError(error.SettingsConflict, apply(db, a, .{ .settings = .{}, .expected = "{}" }));
}

test "malformed rules cannot replace valid settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const bad = try std.json.parseFromSliceLeaky(legacy.Settings, a, "{\"categories\":{\"Food\":\"market\"}}", .{});
    try std.testing.expectError(error.InvalidRules, apply(db, a, .{ .settings = bad, .expected = "{}" }));
    try std.testing.expectEqualStrings("{}", try db.setting(a, "budget"));
}

test "large imported category keyword lists remain valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { count: usize, valid: bool }{ .{ .count = 108, .valid = true }, .{ .count = max_keywords + 1, .valid = false } }) |case| {
        var json: std.ArrayList(u8) = .empty;
        try json.appendSlice(a, "{\"categories\":{\"Grocery\":[");
        for (0..case.count) |index| try json.appendSlice(a, if (index == 0) "\"MARKET\"" else ",\"MARKET\"");
        try json.appendSlice(a, "]}}");
        const settings = try std.json.parseFromSliceLeaky(legacy.Settings, a, json.items, .{});
        if (case.valid) try validate(settings) else try std.testing.expectError(error.InvalidRules, validate(settings));
    }
}
