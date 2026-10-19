//! Category names stay compatible with imported ledgers; explicit edits consolidate them.
const std = @import("std");
const model = @import("model.zig");
const legacy = @import("legacy.zig");
pub const Change = struct { source: []const u8 = "", target: []const u8 };

pub fn clean(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    try model.text(name, 120, false);
    var result: std.ArrayList(u8) = .empty;
    var space = false;
    for (name) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = result.items.len > 0;
            continue;
        }
        if (space) try result.append(a, ' ');
        space = false;
        try result.append(a, c);
    }
    if (result.items.len == 0) return error.InvalidCategory;
    return result.toOwnedSlice(a);
}
pub fn same(x: []const u8, y: []const u8) bool {
    var xb: [120]u8 = undefined;
    var yb: [120]u8 = undefined;
    return std.ascii.eqlIgnoreCase(key(&xb, x), key(&yb, y));
}
fn key(buf: *[120]u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var space = false;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = n > 0;
            continue;
        }
        if (space and n < buf.len) {
            buf[n] = ' ';
            n += 1;
        }
        space = false;
        if (n == buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}
// One changed, missing or extra character: surface a likely typo without merging it.
pub fn similar(x: []const u8, y: []const u8) bool {
    var xb: [120]u8 = undefined;
    var yb: [120]u8 = undefined;
    const a = key(&xb, x);
    const b = key(&yb, y);
    if (@min(a.len, b.len) < 4 or @max(a.len, b.len) - @min(a.len, b.len) > 1) return false;
    var i: usize = 0;
    var j: usize = 0;
    var edits: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.toLower(a[i]) == std.ascii.toLower(b[j])) {
            i += 1;
            j += 1;
            continue;
        }
        edits += 1;
        if (edits > 1) return false;
        if (a.len >= b.len) i += 1;
        if (b.len >= a.len) j += 1;
    }
    return edits + (a.len - i) + (b.len - j) <= 1;
}
pub fn protected(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    return same(trimmed, "Other") or (trimmed.len >= 6 and std.ascii.eqlIgnoreCase(trimmed[0..6], "Fixed:"));
}
pub fn catalog(a: std.mem.Allocator, rows: []const model.Expense, settings: legacy.Settings) ![][]const u8 {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    try names.put(a, "Other", {});
    for (rows) |row| try names.put(a, row.category, {});
    if (settings.categories == .object) {
        var it = settings.categories.object.iterator();
        while (it.next()) |entry| try names.put(a, entry.key_ptr.*, {});
    }
    for (settings.fixed_expenses_items) |item| {
        const name = try std.fmt.allocPrint(a, "Fixed: {s}", .{item.name});
        if (name.len <= 120) try names.put(a, name, {});
    }
    const result = try a.alloc([]const u8, names.count());
    var it = names.keyIterator();
    var i: usize = 0;
    while (it.next()) |name| {
        result[i] = name.*;
        i += 1;
    }
    std.mem.sort([]const u8, result, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return result;
}
pub fn canonical(a: std.mem.Allocator, name: []const u8, names: []const []const u8) ![]const u8 {
    const value = try clean(a, name);
    for (names) |existing| if (std.mem.eql(u8, existing, value)) return existing;
    for (names) |existing| if (same(existing, value)) return existing;
    return value;
}
// Rename carries keyword rules with it. Merge unions rules without dropping either list.
pub fn changed(a: std.mem.Allocator, settings: legacy.Settings, names: []const []const u8, change: Change) !legacy.Settings {
    const target = try clean(a, change.target);
    if (protected(target) or (change.source.len > 0 and protected(change.source))) return error.ReservedCategory;
    if (change.source.len > 0) {
        var found = false;
        for (names) |name| if (std.mem.eql(u8, name, change.source)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidCategory;
        if (std.mem.eql(u8, target, change.source)) return error.InvalidCategory;
    }
    for (names) |name| if (!std.mem.eql(u8, name, change.source) and same(name, target) and !std.mem.eql(u8, name, target)) return error.CategoryExists;
    if (change.source.len == 0) for (names) |name| {
        if (same(name, target)) return error.CategoryExists;
    };
    var result = settings;
    if (result.categories == .null) result.categories = .{ .object = .empty };
    if (result.categories != .object) return error.InvalidRules;
    var keywords: std.json.Array = .init(a);
    for ([_][]const u8{ target, change.source }) |name| {
        if (result.categories.object.get(name)) |list| {
            if (list != .array) return error.InvalidRules;
            for (list.array.items) |word| {
                if (word != .string) return error.InvalidRules;
                var found = false;
                for (keywords.items) |old| if (std.ascii.eqlIgnoreCase(old.string, word.string)) {
                    found = true;
                    break;
                };
                if (!found) try keywords.append(word);
            }
        }
    }
    if (change.source.len > 0) _ = result.categories.object.swapRemove(change.source);
    try result.categories.object.put(a, target, .{ .array = keywords });
    return result;
}

test "likely category typos are suggestions, never automatic aliases" {
    try std.testing.expect(similar("Dining", "Dinning"));
    try std.testing.expect(similar("Dining", "Dinin"));
    try std.testing.expect(!same("Dining", "Dinning"));
    try std.testing.expect(!similar("Dining", "Delivery"));
}
