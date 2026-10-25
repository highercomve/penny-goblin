//! Read-only migration of the web application's /api/data shape. Reimports add
//! new rows; they never replace the ledger, overwrite corrections or resurrect deletions.
const std = @import("std");
const ledger_mod = @import("ledger.zig");
const model = ledger_mod.model;

const Row = struct {
    date: []const u8,
    card: []const u8,
    desc: []const u8,
    amount: i64,
    category: []const u8 = "Other",
};

pub const Bundle = struct {
    account_owners: []const []const u8 = &.{},
    transactions: []const Row,
    salary: i64 = 0,
    fixed_expenses: i64 = 0,
    fixed_expenses_items: []const Fixed = &.{},
    cards_config: std.json.Value = .null,
    vendors_config: std.json.Value = .null,
    categories: std.json.Value = .null,
    special_cases: std.json.Value = .null,
};

pub const Fixed = struct { name: []const u8, amount: i64, keywords: []const []const u8 = &.{} };
pub const Result = struct { imported: usize = 0, skipped: usize = 0, settings_imported: bool = false };
pub const Settings = struct {
    account_owners: []const []const u8 = &.{},
    salary: i64 = 0,
    fixed_expenses_items: []const Fixed = &.{},
    cards_config: std.json.Value = .null,
    vendors_config: std.json.Value = .null,
    categories: std.json.Value = .null,
    special_cases: std.json.Value = .null,
    /// Monthly CLP budget per variable category, such as a category's median month.
    category_budgets: std.json.Value = .null,
};

pub fn import(ledger: ledger_mod.Ledger, arena: std.mem.Allocator, json: []const u8) !Result {
    if (json.len > 24 * 1024 * 1024) return error.ImportTooLarge;
    const bundle = try std.json.parseFromSliceLeaky(Bundle, arena, json, .{ .ignore_unknown_fields = true });
    if (bundle.transactions.len > 100000) return error.TooManyExpenses;
    if (bundle.fixed_expenses < 0 or bundle.fixed_expenses > 1_000_000_000_000) return error.InvalidBudget;
    const fallback = [_]Fixed{.{ .name = "Fixed expenses", .amount = bundle.fixed_expenses }};
    const settings: Settings = .{
        .account_owners = bundle.account_owners,
        .salary = bundle.salary,
        .fixed_expenses_items = if (bundle.fixed_expenses_items.len > 0) bundle.fixed_expenses_items else if (bundle.fixed_expenses > 0) &fallback else &.{},
        .cards_config = bundle.cards_config,
        .vendors_config = bundle.vendors_config,
        .categories = bundle.categories,
        .special_cases = bundle.special_cases,
    };
    try validate_settings(settings);
    try ledger.db.exec("BEGIN IMMEDIATE");
    errdefer ledger.db.exec("ROLLBACK") catch {};
    var result: Result = .{};
    var occurrences: std.StringHashMapUnmanaged(usize) = .empty;
    defer occurrences.deinit(arena);
    for (bundle.transactions) |row| {
        const fingerprint = try row_fingerprint(arena, row);
        const entry = try occurrences.getOrPut(arena, fingerprint);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        const occurrence = entry.value_ptr.*;
        entry.value_ptr.* += 1;
        const identity = try std.fmt.allocPrint(arena, "legacy-v1:{s}:{d}", .{ fingerprint, occurrence });
        const id = model.digest(identity);
        if (try ledger.contains(&id)) {
            result.skipped += 1;
            continue;
        }
        const expense: model.Expense = .{
            .id = &id,
            .date = try iso_date(arena, row.date),
            .amount = row.amount,
            .payee = row.desc,
            .account = row.card,
            .category = row.category,
        };
        try model.validate(expense);
        _ = try ledger.write_expense(expense, 0);
        try ledger.record_change(&id, 1);
        result.imported += 1;
    }
    // Settings are initialized once. Reimport must not undo edits made in native.
    const previous = try ledger.setting(arena, "budget");
    if (std.mem.eql(u8, previous, "{}")) {
        const encoded = try std.json.Stringify.valueAlloc(arena, settings, .{});
        try ledger.put_setting("budget", encoded);
        result.settings_imported = true;
    } else if (bundle.account_owners.len > 0) {
        // Older exports omitted owners. Add this newly supported field once,
        // preserving every existing setting and any explicit owner edits.
        var value = try std.json.parseFromSliceLeaky(std.json.Value, arena, previous, .{});
        if (value == .object and !value.object.contains("account_owners")) {
            const encoded = try std.json.Stringify.valueAlloc(arena, bundle.account_owners, .{});
            const owners = try std.json.parseFromSliceLeaky(std.json.Value, arena, encoded, .{});
            try value.object.put(arena, "account_owners", owners);
            try ledger.put_setting("budget", try std.json.Stringify.valueAlloc(arena, value, .{}));
        }
    }
    try ledger.db.exec("COMMIT");
    return result;
}

fn row_fingerprint(arena: std.mem.Allocator, row: Row) ![]const u8 {
    // JSON framing prevents ambiguous concatenations. Category deliberately
    // excluded: reclassification doesn't create a new payment on reimport.
    const value = try std.json.Stringify.valueAlloc(arena, .{
        .date = try iso_date(arena, row.date),
        .card = row.card,
        .desc = row.desc,
        .amount = row.amount,
    }, .{});
    return arena.dupe(u8, &model.digest(value));
}

fn iso_date(arena: std.mem.Allocator, date: []const u8) ![]const u8 {
    if (model.valid_date(date)) return date;
    if (date.len != 8 or date[2] != '/' or date[5] != '/') return error.InvalidDate;
    // Match Python's %y pivot, used by the current web app.
    const year = try std.fmt.parseInt(u8, date[6..8], 10);
    const iso = try std.fmt.allocPrint(arena, "{d}-{s}-{s}", .{
        @as(u16, if (year <= 68) 2000 else 1900) + year, date[3..5], date[0..2],
    });
    if (!model.valid_date(iso)) return error.InvalidDate;
    return iso;
}

pub fn validate_settings(settings: Settings) !void {
    if (settings.account_owners.len > 20) return error.InvalidBudget;
    for (settings.account_owners) |owner| try model.text(owner, 120, false);
    if (settings.salary < 0 or settings.salary > 1_000_000_000_000 or settings.fixed_expenses_items.len > 100) return error.InvalidBudget;
    for (settings.fixed_expenses_items) |item| {
        if (item.name.len == 0 or item.name.len > 120 or item.amount < 0 or item.amount > 1_000_000_000_000) return error.InvalidBudget;
        if (item.keywords.len > 100 or !std.unicode.utf8ValidateSlice(item.name)) return error.InvalidBudget;
        for (item.keywords) |keyword| if (keyword.len == 0 or keyword.len > 240 or !std.unicode.utf8ValidateSlice(keyword)) return error.InvalidBudget;
    }
}

test "reimport retains identical legitimate payments and user edits without resurrection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ledger = try ledger_mod.Ledger.open(":memory:");
    defer ledger.close();
    const bundle =
        \\{"transactions":[{"date":"10/10/26","card":"Debit","desc":"Gladys","amount":40000,"category":"Other"},{"date":"10/10/26","card":"Debit","desc":"Gladys","amount":40000,"category":"Other"}],"salary":3000000}
    ;
    try std.testing.expectEqual(@as(usize, 2), (try import(ledger, a, bundle)).imported);
    const rows = try ledger.list(a);
    var corrected = rows[0];
    corrected.category = "Fixed: Cleaning";
    _ = try ledger.save(a, .{ .expense = corrected, .expected_revision = corrected.revision });
    try ledger.remove(rows[1].id, rows[1].revision);
    const again = try import(ledger, a, bundle);
    try std.testing.expectEqual(@as(usize, 0), again.imported);
    try std.testing.expectEqual(@as(usize, 2), again.skipped);
    const remaining = try ledger.list(a);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqualStrings("Fixed: Cleaning", remaining[0].category);
}

test "bad row rolls back the entire import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ledger = try ledger_mod.Ledger.open(":memory:");
    defer ledger.close();
    const bad =
        \\{"transactions":[{"date":"10/10/26","card":"Debit","desc":"Valid","amount":40000},{"date":"31/02/26","card":"Debit","desc":"Invalid","amount":1}]}
    ;
    try std.testing.expectError(error.InvalidDate, import(ledger, arena.allocator(), bad));
    try std.testing.expectEqual(@as(i64, 0), try ledger.db.scalarInt("SELECT count(*) FROM expenses"));
    try std.testing.expectEqual(@as(i64, 0), try ledger.db.scalarInt("SELECT count(*) FROM changes"));
}

test "web export numeric formats and configuration survive migration and repeat import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ledger = try ledger_mod.Ledger.open(":memory:");
    defer ledger.close();
    const bundle =
        \\{"transactions":[{"date":"14/10/26","card":"Debit","desc":"Johana","amount":40000.0}],"salary":3e6,"fixed_expenses":40000.0,"fixed_expenses_items":[{"name":"Cleaning","amount":40000.0,"keywords":["gladys"]}],"cards_config":{"Debit":{"holder":"Household"}},"vendors_config":{"TEST":"Merchant"},"categories":{"Food":["market"]},"special_cases":{"GLADYS":"Fixed: Cleaning"}}
    ;
    const result = try import(ledger, a, bundle);
    try std.testing.expectEqual(@as(usize, 1), result.imported);
    try std.testing.expect(result.settings_imported);
    const settings = try std.json.parseFromSliceLeaky(Settings, a, try ledger.setting(a, "budget"), .{});
    try std.testing.expectEqual(@as(i64, 3000000), settings.salary);
    try std.testing.expectEqual(@as(i64, 40000), settings.fixed_expenses_items[0].amount);
    try std.testing.expectEqualStrings("gladys", settings.fixed_expenses_items[0].keywords[0]);
    try std.testing.expectEqualStrings("Household", settings.cards_config.object.get("Debit").?.object.get("holder").?.string);
    try std.testing.expectEqualStrings("Merchant", settings.vendors_config.object.get("TEST").?.string);
    try std.testing.expectEqualStrings("market", settings.categories.object.get("Food").?.array.items[0].string);
    try std.testing.expectEqualStrings("Fixed: Cleaning", settings.special_cases.object.get("GLADYS").?.string);
    try ledger.put_setting("budget", "{\"salary\":42}");
    try std.testing.expect(!(try import(ledger, a, bundle)).settings_imported);
    try std.testing.expectEqualStrings("{\"salary\":42}", try ledger.setting(a, "budget"));
}

test "legacy aggregate budget is retained and invalid or fractional money is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ledger = try ledger_mod.Ledger.open(":memory:");
    defer ledger.close();
    try std.testing.expectError(error.InvalidBudget, import(ledger, a, "{\"transactions\":[],\"fixed_expenses\":-1}"));
    try std.testing.expectError(error.InvalidNumber, import(ledger, a, "{\"transactions\":[],\"salary\":1.5}"));
    try std.testing.expectEqualStrings("{}", try ledger.setting(a, "budget"));
    _ = try import(ledger, a, "{\"transactions\":[],\"fixed_expenses\":125000.0}");
    const settings = try std.json.parseFromSliceLeaky(Settings, a, try ledger.setting(a, "budget"), .{});
    try std.testing.expectEqual(@as(usize, 1), settings.fixed_expenses_items.len);
    try std.testing.expectEqualStrings("Fixed expenses", settings.fixed_expenses_items[0].name);
    try std.testing.expectEqual(@as(i64, 125000), settings.fixed_expenses_items[0].amount);
}
