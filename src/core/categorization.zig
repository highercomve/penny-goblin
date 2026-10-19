//! Reviewed categorization owns eligibility and the atomic ledger/sync write.
const std = @import("std");
const ledger = @import("ledger.zig");
const reports = @import("reporting.zig");
const prefs = @import("preferences.zig");
pub const Target = prefs.Target;
pub const Source = struct { url: []const u8, title: []const u8 = "", quote: []const u8 = "" };
pub const Proposal = struct {
    merchant: []const u8,
    targets: []const Target,
    category: []const u8 = "",
    reason: []const u8 = "",
    sources: []const Source = &.{},
};
pub const Review = struct { expected_settings: []const u8, proposals: []const Proposal, remaining: usize = 0 };
pub const Selection = struct { targets: []const Target, category: []const u8 };
pub const Apply = struct { expected_settings: []const u8, selections: []const Selection };

pub fn eligible(row: ledger.model.Expense, config: reports.Settings) bool {
    return !row.deleted and (row.category.len == 0 or std.mem.eql(u8, row.category, "Other")) and
        reports.fixed_item(row, config) == null and reports.special(row, config) == null;
}
pub fn category_exists(config: reports.Settings, category: []const u8) bool {
    return category.len > 0 and !std.mem.eql(u8, category, "Other") and config.categories == .object and config.categories.object.contains(category);
}

pub fn prepare(a: std.mem.Allocator, rows: []const ledger.model.Expense, settings: []const u8) !Review {
    const config = try std.json.parseFromSliceLeaky(reports.Settings, a, settings, .{ .allocate = .alloc_always });
    var proposals: std.ArrayList(Proposal) = .empty;
    var remaining: usize = 0;
    var targets_by_group: [10]std.ArrayList(Target) = @splat(.empty);
    for (rows) |row| {
        if (!eligible(row, config)) continue;
        const merchant = std.mem.trim(u8, row.payee, " \t\r\n");
        var found: ?usize = null;
        for (proposals.items, 0..) |group, i| if (std.ascii.eqlIgnoreCase(group.merchant, merchant)) {
            found = i;
            break;
        };
        if (found == null) {
            if (proposals.items.len == 10) {
                remaining += 1;
                continue;
            }
            const suggested = try reports.suggest_category(a, merchant, config);
            try proposals.append(a, .{ .merchant = try a.dupe(u8, merchant), .targets = &.{}, .category = if (suggested) |v| if (category_exists(config, v)) v else "" else "", .reason = if (suggested != null) "Matches an existing category rule" else "" });
            found = proposals.items.len - 1;
        }
        try targets_by_group[found.?].append(a, .{ .id = try a.dupe(u8, row.id), .revision = row.revision });
    }
    for (proposals.items, 0..) |*group, i| group.targets = try targets_by_group[i].toOwnedSlice(a);
    return .{ .expected_settings = try a.dupe(u8, settings), .proposals = try proposals.toOwnedSlice(a), .remaining = remaining };
}

pub fn apply(db: ledger.Ledger, a: std.mem.Allocator, edit: Apply) !usize {
    if (edit.selections.len == 0 or edit.selections.len > 10 or edit.expected_settings.len > 256 * 1024) return error.InvalidSelection;
    try db.db.exec("BEGIN IMMEDIATE");
    errdefer db.db.exec("ROLLBACK") catch {};
    const settings = try db.setting(a, "budget");
    if (!std.mem.eql(u8, settings, edit.expected_settings)) return error.SettingsConflict;
    const config = try std.json.parseFromSliceLeaky(reports.Settings, a, settings, .{});
    const rows = try db.list(a);
    var by_id: std.StringHashMapUnmanaged(ledger.model.Expense) = .empty;
    defer by_id.deinit(a);
    for (rows) |row| try by_id.put(a, row.id, row);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    for (edit.selections) |selection| {
        if (!category_exists(config, selection.category) or selection.targets.len == 0 or selection.targets.len > 10000) return error.InvalidCategory;
        for (selection.targets) |target| {
            if (seen.count() >= 10000 or seen.contains(target.id)) return error.InvalidSelection;
            try seen.put(a, target.id, {});
            var row = by_id.get(target.id) orelse return error.ExpenseNotFound;
            if (!eligible(row, config) or row.revision != target.revision) return error.RevisionConflict;
            row.category = selection.category;
            try ledger.model.validate(row);
            const revision = try db.write_expense(row, target.revision);
            try db.record_change(row.id, revision);
        }
    }
    try db.db.exec("COMMIT");
    return seen.count();
}

test "research groups eligible merchants and applies reviewed mixed categories atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try ledger.Ledger.open(":memory:");
    defer db.close();
    const settings = "{\"categories\":{\"Food\":[\"MARKET\"],\"Sport\":[]},\"fixed_expenses_items\":[{\"name\":\"Rent\",\"amount\":100,\"keywords\":[\"RENT\"]}]}";
    try db.put_setting("budget", settings);
    const first: ledger.model.Expense = .{ .id = &ledger.model.digest("research-a"), .date = "2026-10-18", .amount = 100, .payee = "MARKET" };
    var second = first;
    second.id = &ledger.model.digest("research-b");
    second.payee = "SPORT SHOP";
    _ = try db.save(a, .{ .expense = first });
    _ = try db.save(a, .{ .expense = second });
    const review = try prepare(a, try db.list(a), settings);
    try std.testing.expectEqual(@as(usize, 2), review.proposals.len);
    var selections: [2]Selection = undefined;
    for (review.proposals, 0..) |group, i| selections[i] = .{ .targets = group.targets, .category = if (std.mem.eql(u8, group.merchant, "MARKET")) "Food" else "Sport" };
    var stale = try a.dupe(Target, selections[1].targets);
    stale[0].revision += 1;
    const valid = selections[1].targets;
    selections[1].targets = stale;
    try std.testing.expectError(error.RevisionConflict, apply(db, a, .{ .expected_settings = settings, .selections = &selections }));
    for (try db.list(a)) |row| try std.testing.expectEqualStrings("Other", row.category);
    selections[1].targets = selections[0].targets;
    try std.testing.expectError(error.InvalidSelection, apply(db, a, .{ .expected_settings = settings, .selections = &selections }));
    selections[1].targets = valid;
    try std.testing.expectError(error.SettingsConflict, apply(db, a, .{ .expected_settings = "{}", .selections = &selections }));
    for (try db.list(a)) |row| try std.testing.expectEqualStrings("Other", row.category);
    try std.testing.expectEqual(@as(usize, 2), try apply(db, a, .{ .expected_settings = settings, .selections = &selections }));
    try std.testing.expectEqual(@as(usize, 0), (try prepare(a, try db.list(a), settings)).proposals.len);
    var fixed = first;
    fixed.payee = "RENT";
    try std.testing.expect(!eligible(fixed, try std.json.parseFromSliceLeaky(reports.Settings, a, settings, .{})));
}

/// Card descriptors read "PROCESSOR*BUSINESS" when a payment provider's
/// terminal or gateway took the card (MERPAGO*HAPETITO is a Mercado Pago POS
/// at Hapetito). Only known processors are split: elsewhere the text before
/// the asterisk is the business itself (UBER *TRIP).
const processors = [_][2][]const u8{
    .{ "MERCADOPAGO", "Mercado Pago" }, .{ "MERPAGO", "Mercado Pago" }, .{ "MP", "Mercado Pago" },
    .{ "TUU", "TUU" },                   .{ "PAYU", "PayU" },              .{ "REDGLOBA", "Redglobal" },
    .{ "DL", "dLocal" },                 .{ "SUMUP", "SumUp" },            .{ "RAPYD", "Rapyd" },
    .{ "PAYSCAN", "Payscan" },           .{ "FUDO", "Fudo" },              .{ "FLOW", "Flow" },
};
pub const Descriptor = struct { business: []const u8, processor: []const u8 = "" };
pub fn descriptor(merchant: []const u8) Descriptor {
    const star = std.mem.indexOfScalar(u8, merchant, '*') orelse return .{ .business = merchant };
    const prefix = std.mem.trim(u8, merchant[0..star], " ");
    const business = std.mem.trim(u8, merchant[star + 1 ..], " ");
    if (business.len == 0) return .{ .business = merchant };
    for (processors) |p| if (std.ascii.eqlIgnoreCase(prefix, p[0])) return .{ .business = business, .processor = p[1] };
    return .{ .business = merchant };
}
test "payment processor prefixes are split from the business" {
    try std.testing.expectEqualDeep(Descriptor{ .business = "HAPETITO", .processor = "Mercado Pago" }, descriptor("MERPAGO*HAPETITO"));
    try std.testing.expectEqualDeep(Descriptor{ .business = "SEPULVEDA Y RIVERA", .processor = "TUU" }, descriptor("TUU*SEPULVEDA Y RIVERA"));
    try std.testing.expectEqualDeep(Descriptor{ .business = "CAFE NUK.", .processor = "SumUp" }, descriptor("SUMUP * CAFE NUK."));
    try std.testing.expectEqualDeep(Descriptor{ .business = "UBER *TRIP" }, descriptor("UBER *TRIP"));
    try std.testing.expectEqualDeep(Descriptor{ .business = "MERPAGO*" }, descriptor("MERPAGO*"));
}

/// Only the business label reaches search, without its payment processor
/// and with numeric identifiers/email tokens removed. The model cannot
/// broaden queries using page instructions.
pub fn search_query(a: std.mem.Allocator, merchant: []const u8) ![]const u8 {
    var words = std.mem.tokenizeAny(u8, descriptor(merchant).business, " \t\r\n");
    var query: std.ArrayList(u8) = .empty;
    while (words.next()) |word| {
        var digits: usize = 0;
        for (word) |ch| if (std.ascii.isDigit(ch)) { digits += 1; };
        if (digits >= 4 or std.mem.indexOfScalar(u8, word, '@') != null) continue;
        if (query.items.len + word.len > 220) break;
        if (query.items.len > 0) try query.append(a, ' ');
        try query.appendSlice(a, word);
    }
    if (query.items.len == 0) return error.NoSearchableMerchant;
    try query.appendSlice(a, " Chile");
    return query.toOwnedSlice(a);
}
test "search never receives embedded bank identifiers or email tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Merchant Chile", try search_query(arena.allocator(), "Merchant 12.345.678-9 hello@example.com"));
    try std.testing.expectError(error.NoSearchableMerchant, search_query(arena.allocator(), "123456789"));
    try std.testing.expectEqualStrings("HAPETITO Chile", try search_query(arena.allocator(), "MERPAGO*HAPETITO"));
}
