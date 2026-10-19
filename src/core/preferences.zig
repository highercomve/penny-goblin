//! Settings edits and reviewed bulk categorization share one atomic boundary.
const std = @import("std");
const ledger_mod = @import("ledger.zig");
const legacy = @import("legacy.zig");
const model = ledger_mod.model;
const categories = @import("categories.zig");
pub const Target = struct { id: []const u8, revision: i64 };
pub const Edit = struct {
    settings: legacy.Settings,
    expected: []const u8,
    targets: []const Target = &.{},
    category: []const u8 = "",
    category_change: ?categories.Change = null,
};

pub fn apply(db: ledger_mod.Ledger, arena: std.mem.Allocator, edit: Edit) !usize {
    try validate(edit.settings);
    if (edit.targets.len > (if (edit.category_change != null) @as(usize, 100000) else 10000)) return error.TooManyExpenses;
    if (edit.targets.len > 0 and edit.category_change == null) try model.text(edit.category, 120, false);
    const json_limit = 256 * 1024;
    if (edit.expected.len > json_limit) return error.SettingsTooLarge;
    try db.db.exec("BEGIN IMMEDIATE");
    errdefer db.db.exec("ROLLBACK") catch {};
    if (!std.mem.eql(u8, edit.expected, try db.setting(arena, "budget"))) return error.SettingsConflict;
    const rows = try db.list(arena);
    var by_id: std.StringHashMapUnmanaged(model.Expense) = .empty;
    defer by_id.deinit(arena);
    for (rows) |row| try by_id.put(arena, row.id, row);
    const update = try prepare_edit(arena, edit, rows, by_id);
    const config = update.settings;
    const category = update.category;
    try validate(config);
    const json = try std.json.Stringify.valueAlloc(arena, config, .{});
    if (json.len > json_limit) return error.SettingsTooLarge;
    for (edit.targets) |target| {
        var row = by_id.get(target.id) orelse return error.ExpenseNotFound;
        if (target.revision < 1 or target.revision == std.math.maxInt(i64)) return error.InvalidRevision;
        row.category = category;
        try model.validate(row);
        const revision = try db.write_expense(row, target.revision);
        try db.record_change(row.id, revision);
    }
    try db.put_setting("budget", json);
    try db.db.exec("COMMIT");
    return edit.targets.len;
}

const Prepared = struct { settings: legacy.Settings, category: []const u8 };
fn prepare_edit(arena: std.mem.Allocator, edit: Edit, rows: []const model.Expense, by_id: std.StringHashMapUnmanaged(model.Expense)) !Prepared {
    var config = edit.settings;
    var category = edit.category;
    if (edit.category_change) |change| {
        const prior = try std.json.parseFromSliceLeaky(legacy.Settings, arena, edit.expected, .{ .ignore_unknown_fields = true });
        config = try categories.changed(arena, prior, try categories.catalog(arena, rows, prior), change);
        category = try categories.clean(arena, change.target);
        var count: usize = 0;
        for (rows) |row| if (std.mem.eql(u8, row.category, change.source)) {
            count += 1;
        };
        if (count != edit.targets.len) return error.RevisionConflict;
        for (edit.targets) |target| {
            const row = by_id.get(target.id) orelse return error.RevisionConflict;
            if (!std.mem.eql(u8, row.category, change.source)) return error.RevisionConflict;
        }
    } else {
        const prior = try std.json.parseFromSliceLeaky(legacy.Settings, arena, edit.expected, .{ .ignore_unknown_fields = true });
        const names = try categories.catalog(arena, rows, prior);
        if (config.categories == .object) {
            for (config.categories.object.keys()) |name| {
                var existed = false;
                for (names) |old| if (std.mem.eql(u8, old, name)) {
                    existed = true;
                    break;
                };
                if (!existed) {
                    const canonical = try categories.canonical(arena, name, names);
                    if (!std.mem.eql(u8, name, canonical)) return error.CategoryExists;
                    for (config.categories.object.keys()) |key| if (!std.mem.eql(u8, key, name) and categories.same(key, name)) return error.CategoryExists;
                }
            }
        }
        if (edit.targets.len > 0) category = try categories.canonical(arena, category, try categories.catalog(arena, rows, config));
    }
    return .{ .settings = config, .category = category };
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

test "reviewed category merge preserves rules and emits normal sync changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const expected = "{\"categories\":{\"Dining\":[\"CAFE\"],\"Dinning\":[\"cafe\",\"RESTAURANT\"]},\"salary\":123}";
    try db.put_setting("budget", expected);
    const row: model.Expense = .{ .id = &model.digest("typo"), .date = "2026-10-19", .amount = 12, .payee = "Lunch", .category = "Dinning" };
    _ = try db.save(a, .{ .expense = row });
    const edit: Edit = .{ .settings = .{}, .expected = expected, .targets = &.{.{ .id = row.id, .revision = 1 }}, .category_change = .{ .source = "Dinning", .target = "Dining" } };
    try std.testing.expectEqual(@as(usize, 1), try apply(db, a, edit));
    const saved = (try db.list(a))[0];
    try std.testing.expectEqualStrings("Dining", saved.category);
    try std.testing.expectEqual(@as(i64, 2), saved.revision);
    try std.testing.expectEqual(@as(i64, 2), try db.db.scalarInt("SELECT count(*) FROM changes"));
    const config = try std.json.parseFromSliceLeaky(legacy.Settings, a, try db.setting(a, "budget"), .{});
    try std.testing.expect(!config.categories.object.contains("Dinning"));
    try std.testing.expectEqual(@as(usize, 2), config.categories.object.get("Dining").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 123), config.salary);
}

test "category merge rejects stale and incomplete reviews atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    const expected = "{\"categories\":{\"Dinning\":[\"CAFE\"]}}";
    try db.put_setting("budget", expected);
    const first: model.Expense = .{ .id = &model.digest("first"), .date = "2026-10-19", .amount = 1, .payee = "Lunch", .category = "Dinning" };
    var second = first;
    second.id = &model.digest("second");
    _ = try db.save(a, .{ .expense = first });
    _ = try db.save(a, .{ .expense = second });
    const targets = [_]Target{ .{ .id = first.id, .revision = 1 }, .{ .id = second.id, .revision = 1 } };
    var edit: Edit = .{ .settings = .{}, .expected = expected, .targets = targets[0..1], .category_change = .{ .source = "Dinning", .target = "Dining" } };
    try std.testing.expectError(error.RevisionConflict, apply(db, a, edit));
    _ = try db.save(a, .{ .expense = second, .expected_revision = 1 });
    edit.targets = &targets;
    try std.testing.expectError(error.RevisionConflict, apply(db, a, edit));
    try std.testing.expectEqualStrings(expected, try db.setting(a, "budget"));
    try std.testing.expectEqualStrings("Dinning", (try db.get(a, first.id)).?.category);
    try std.testing.expectEqual(@as(i64, 1), (try db.get(a, first.id)).?.revision);
    try std.testing.expectEqual(@as(i64, 3), try db.db.scalarInt("SELECT count(*) FROM changes"));
}

test "new categories and payment saves reuse case and spacing and protect reserved categories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger_mod.Ledger.open(":memory:");
    defer db.close();
    _ = try apply(db, a, .{ .settings = .{}, .expected = "{}", .category_change = .{ .target = "Pet care" } });
    const expected = try db.setting(a, "budget");
    try std.testing.expectError(error.CategoryExists, apply(db, a, .{ .settings = .{}, .expected = expected, .category_change = .{ .target = "  pet   CARE " } }));
    try std.testing.expectError(error.ReservedCategory, apply(db, a, .{ .settings = .{}, .expected = expected, .category_change = .{ .target = "Other" } }));
    const row: model.Expense = .{ .id = &model.digest("pet"), .date = "2026-10-19", .amount = 1, .payee = "Vet", .category = " pet   CARE " };
    _ = try db.save(a, .{ .expense = row });
    try std.testing.expectEqualStrings("Pet care", (try db.list(a))[0].category);
    const bad = try std.json.parseFromSliceLeaky(legacy.Settings, a, "{\"categories\":{\"Pet care\":[],\"pet CARE\":[]}}", .{});
    try std.testing.expectError(error.CategoryExists, apply(db, a, .{ .settings = bad, .expected = expected }));
    _ = try apply(db, a, .{ .settings = .{}, .expected = expected, .targets = &.{.{ .id = row.id, .revision = 1 }}, .category_change = .{ .source = "Pet care", .target = "Pets" } });
    try std.testing.expectEqualStrings("Pets", (try db.list(a))[0].category);
}
