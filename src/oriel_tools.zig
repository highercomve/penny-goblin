//! Secondary pages for the compiled renderer; backend validation remains authoritative.
const std = @import("std");
const oriel = @import("oriel");
const f = @import("oriel_frontend.zig");
const ui = f.ui;
const progress = @import("oriel_progress.zig");
const legacy = @import("core/legacy.zig");
const statements = @import("core/statements.zig");
const prefs = @import("core/preferences.zig");
const sync_resolution = @import("core/sync_resolution.zig");
const sync_types = @import("core/sync_types.zig");
const Scanner = @import("scanner.zig");
const Preferences = ui.View(@embedFile("preferences-dialog.oriel"));
const SyncDevice = ui.View(@embedFile("sync-device.oriel"));
const SyncConflict = ui.View(@embedFile("sync-conflict.oriel"));
const Fixed = ui.View(@embedFile("fixed-page.oriel"));
const Statements = ui.View(@embedFile("statements-page.oriel"));
const Statement = ui.View(@embedFile("statement-dialog.oriel"));
const Scan = ui.View(@embedFile("scanner-page.oriel"));
const Sync = ui.View(@embedFile("sync-dialog.oriel"));
const Mapping = ui.View(@embedFile("mapping.oriel"));
const ScanRow = ui.View(@embedFile("scanner-row.oriel"));
const mapping_base: i64 = 20000000;
const mapping_stride: i64 = 32;
const Review = ui.View(@embedFile("review-row.oriel"));
const StatementSource = ui.View(@embedFile("statement-source.oriel"));
const review_base: i64 = 22000000;
const review_stride: i64 = 32;
var bulk_only_other = true;
var bulk_remember = true;
var bulk_edit: ?prefs.Edit = null;
var bulk_arena: std.heap.ArenaAllocator = undefined;
var bulk_saving = false;
const GroupKind = enum { category, account, merchant, fixed, month, special, variable_account, variable_category, planned_category, comparison };
const Group = struct { name: []const u8, amount: i64 = 0, total: i64 = 0, median: i64 = 0, count: usize = 0, kind: GroupKind, detail: []const u8 = "", account: []const u8 = "", category: []const u8 = "" };
pub const Section = enum { budget, fixed, accounts, categories, vendors, special };
var report_arena: std.heap.ArenaAllocator = undefined;
var modal_arena: std.heap.ArenaAllocator = undefined;
var scanner_arena: std.heap.ArenaAllocator = undefined;
var core_arena: std.heap.ArenaAllocator = undefined;
var transport_arena: std.heap.ArenaAllocator = undefined;
var include_planned = false;
var program: ui.Program = undefined;
const ChartRow = ui.View(@embedFile("category-row.oriel"));
const Report = ui.View(@embedFile("report-row.oriel"));
const chart_colors = [_]u24{ 0x2d6a4f, 0x8bbf5f, 0xd29a3c, 0x4f8a8b, 0xc26b4f, 0x7d6b9e, 0x6b737f, 0xb5a980 };
const Comparison = ui.View(@embedFile("comparison.oriel"));
const Donut = ui.View(@embedFile("donut.oriel"));
var groups: std.ArrayList(Group) = .empty;
var group_actions: std.AutoHashMapUnmanaged(i64, usize) = .empty;
var special_rows: []f.model.Expense = &.{};
/// The Insights range's CLP payments and calendar months, for the render in progress.
var insight_rows: []const f.model.Expense = &.{};
var range_months: usize = 1;
/// Category rows that offer their median to the budget, and Home's budget rows: node id -> group index or budget name.
var budget_offers: std.AutoHashMapUnmanaged(i64, usize) = .empty;
var budget_rows: std.AutoHashMapUnmanaged(i64, []const u8) = .empty;
/// The category budget awaiting confirmation; a null amount removes it.
var pending_budget: struct { name: [120]u8 = undefined, len: usize = 0, amount: ?i64 = null } = .{};
const budget_base: i64 = 21000000;
var mapping_count: usize = 0;
var section: Section = .budget;
var expected: []const u8 = "";
var original: legacy.Settings = .{};
var current_hash: []const u8 = "";
var observations: []statements.Observation = &.{};
var show_reviewed_observations = false;
var statement_bank: statements.Bank = .santander;
var scanner: ?Scanner.Status = null;
var delete_model_buf: [32]u8 = undefined;
var delete_model_len: usize = 0;
var download_id_buf: [32]u8 = undefined;
var download_id_len: usize = 0;
var download_done: u32 = 0;
var download_total: u32 = 0;
var auto_select_download = false;
var core: ?sync_resolution.Status = null;
var conflict: ?sync_types.Conflict = null;
var devices: []Device = &.{};
var replace_desktop = false;
var connection_state: []const u8 = "Checking connection";
var pair_expires: i64 = 0;
const Device = struct { id: []const u8, label: []const u8, revoked: bool = false };
var attempted: std.StringHashMapUnmanaged(void) = .empty;
var parser_busy = false;
var ready = false;
pub fn prepare(e: *ui.Engine) !void {
    shutdown();
    try SyncDevice.prepare(&e.tree, 79900);
    try SyncConflict.prepare(&e.tree, 79910);
    // Android can open another main window within the same process.
    // Never retain slices into the previous window's freed arenas.
    groups = .empty;
    group_actions = .empty;
    budget_offers = .empty;
    budget_rows = .empty;
    special_rows = &.{};
    observations = &.{};
    show_reviewed_observations = false;
    statement_bank = .santander;
    scanner = null;
    delete_model_len = 0;
    download_id_len = 0;
    download_done = 0;
    download_total = 0;
    auto_select_download = false;
    core = null;
    conflict = null;
    devices = &.{};
    bulk_edit = null;
    bulk_saving = false;
    original = .{};
    expected = "";
    current_hash = "";
    connection_state = "Checking connection";
    pair_expires = 0;
    mapping_count = 0;
    include_planned = false;
    replace_desktop = false;
    bulk_arena = .init(e.gpa);
    report_arena = .init(e.gpa);
    modal_arena = .init(e.gpa);
    scanner_arena = .init(e.gpa);
    core_arena = .init(e.gpa);
    transport_arena = .init(e.gpa);
    program = .init(e.gpa);
    ready = true;
    inline for (.{ .{ Preferences, 61000 }, .{ Fixed, 62000 }, .{ Statements, 63000 }, .{ Statement, 64000 }, .{ Scan, 65000 }, .{ Sync, 66000 }, .{ Mapping, 72000 }, .{ ScanRow, 72100 }, .{ Review, 73000 }, .{ StatementSource, 73100 }, .{ Donut, 75500 }, .{ ChartRow, 75600 }, .{ Comparison, 75700 }, .{ Report, 75800 } }) |v| try v[0].prepare(&e.tree, v[1]);
}
pub fn shutdown() void {
    if (ready) {
        var keys = attempted.keyIterator();
        while (keys.next()) |key| report_arena.child_allocator.free(key.*);
        attempted.deinit(report_arena.child_allocator);
        attempted = .empty;
        parser_busy = false;
        program.deinit();
        bulk_arena.deinit();
        report_arena.deinit();
        modal_arena.deinit();
        scanner_arena.deinit();
        core_arena.deinit();
        transport_arena.deinit();
        ready = false;
    }
}
pub fn modal_id(modal: f.Modal) ?i64 {
    return switch (modal) {
        .research => 20000,
        .preferences => 11000,
        .fixed => 12000,
        .statements => 13000,
        .statement => 14000,
        .scanner => 15000,
        .sync => 16000,
        else => null,
    };
}
fn pid(comptime name: []const u8) i64 {
    return Preferences.id(name, 11000);
}
fn sid(comptime name: []const u8) i64 {
    return Sync.id(name, 16000);
}
fn scid(comptime name: []const u8) i64 {
    return Scan.id(name, 15000);
}
pub fn resize(e: *ui.Engine) !void {
    if (modal_id(f.s.modal)) |id| try f.resize_modal(e, id);
}
pub fn open(e: *ui.Engine, modal: f.Modal) !void {
    if (f.s.busy or f.s.modal != .none or f.s.snapshot == null) return;
    switch (modal) {
        .preferences => {
            _ = try Preferences.mount(&e.tree, 11000, 61000, &.{});
        },
        .fixed => {
            _ = try Fixed.mount(&e.tree, 12000, 62000, &.{});
        },
        .statements => {
            _ = try Statements.mount(&e.tree, 13000, 63000, &.{});
        },
        .statement => {
            _ = try Statement.mount(&e.tree, 14000, 64000, &.{});
        },
        .scanner => {
            _ = try Scan.mount(&e.tree, 15000, 65000, &.{});
        },
        .sync => {
            _ = try Sync.mount(&e.tree, 16000, 66000, &.{});
        },
        else => return,
    }
    switch (modal) {
        .preferences => try f.mark_actions(e, Preferences, 11000, .{ "close-preferences", "save-preferences", "add-fixed", "add-account", "add-category", "add-vendor", "add-special" }),
        .fixed => try f.mark_actions(e, Fixed, 12000, .{ "close-fixed", "edit-fixed" }),
        .statements => try f.mark_actions(e, Statements, 13000, .{ "close-statements", "statement-file", "santander-connect", "bank-add-account", "bank-santander", "bank-bci", "bank-boa" }),
        .statement => try f.mark_actions(e, Statement, 14000, .{ "close-statement", "confirm-statement" }),
        .scanner => try f.mark_actions(e, Scan, 15000, .{ "close-scanner", "model", "projector", "scanner-fast", "scanner-gpu" }),
        .sync => try f.mark_actions(e, Sync, 16000, .{ "close-sync", "sync-start", "sync-stop", "sync-restart", "sync-pairing", "sync-now", "sync-unpair", "sync-scan", "sync-connect", "sync-replace", "sync-use-local", "sync-use-remote", "sync-service-toggle", "sync-paste-toggle", "sync-link-details-toggle" }),
        else => {},
    }
    f.s.modal = modal;
    f.s.dirty = false;
    try ui.setVisible(&e.tree, modal_id(modal).?, true);
    try resize(e);
    try f.overlay(e);
    switch (modal) {
        .fixed => try fixed_report(e),
        .statements => {
            try f.set_text(e, Statements.id("statement-status", 13000), "");
            try render_statements(e);
        },
        .scanner => {
            try f.set_text(e, scid("model-status"), "");
            try f.invoke(e, .scanner_status, "scanner_status", .{});
        },
        .sync => {
            try f.set_text(e, sid("sync-message"), "");
            try f.show(e, sid("sync-code"), false);
            try f.show(e, sid("sync-review"), false);
            try f.show(e, sid("sync-service-body"), false);
            try f.show(e, sid("sync-paste-body"), false);
            try f.show(e, sid("sync-link-details-body"), false);
            try f.set_text(e, sid("sync-link-details-toggle"), "Pairing link ▾");
            try f.set_text(e, sid("sync-service-toggle"), "Service ▾");
            try f.set_text(e, sid("sync-paste-toggle"), "Paste link instead ▾");
            try f.show(e, sid("sync-mobile"), oriel.target.is_android);
            try f.show(e, sid("sync-desktop"), !oriel.target.is_android);
            try refresh_sync(e);
        },
        else => {},
    }
    f.redraw(e);
}
fn item(e: *ui.Engine, base: i64, title: []const u8, detail: []const u8, amount: []const u8, action: []const u8) !void {
    _ = try f.Item.mount(&e.tree, base, f.item_style, &.{ .{ .name = "title", .value = title }, .{ .name = "detail", .value = detail }, .{ .name = "amount", .value = amount } });
    try f.set_text(e, f.Item.id("action", base), action);
    try f.show(e, f.Item.id("action", base), action.len > 0);
    try f.show(e, f.Item.id("secondary", base), false);
}
fn report_row(e: *ui.Engine, base: i64, title: []const u8, detail: []const u8, amount: i64, actionable: bool) !void {
    var buf: [48]u8 = undefined;
    _ = try Report.mount(&e.tree, base, 75800, &.{ .{ .name = "title", .value = title }, .{ .name = "detail", .value = detail }, .{ .name = "amount", .value = try f.reports.money(&buf, amount) } });
    try f.show(e, Report.id("legend", base), false);
    if (actionable) try f.mark_action(e, base, title);
}
fn percentage(a: std.mem.Allocator, amount: i64, total: i64) ![]const u8 {
    const tenths = if (total > 0) @divTrunc(@as(i128, amount) * 1000, total) else 0;
    return if (@mod(tenths, 10) == 0) std.fmt.allocPrint(a, "{d}%", .{@divTrunc(tenths, 10)}) else std.fmt.allocPrint(a, "{d}.{d}%", .{ @divTrunc(tenths, 10), @mod(tenths, 10) });
}
fn add_group(kind: GroupKind, name: []const u8, amount: i64) !void {
    for (groups.items) |*g| if (g.kind == kind and std.mem.eql(u8, g.name, name)) {
        g.amount += amount;
        g.count += 1;
        return;
    };
    try groups.append(report_arena.allocator(), .{ .name = try report_arena.allocator().dupe(u8, name), .kind = kind, .amount = amount, .count = 1 });
}
fn group_rows(e: *ui.Engine, parent: i64, kind: GroupKind, base: i64) !void {
    var ids: std.ArrayList(i64) = .empty;
    const a = report_arena.allocator();
    var total: i64 = 0;
    for (groups.items) |g| if (g.kind == kind) {
        total += g.amount;
    };
    for (groups.items, 0..) |g, i| if (g.kind == kind) {
        const id = base + @as(i64, @intCast(ids.items.len)) * 16;
        try group_actions.put(a, id, i);
        var average: [48]u8 = undefined;
        const detail = if (kind == .variable_account) try percentage(a, g.amount, total) else if (kind == .merchant)
            try std.fmt.allocPrint(a, "{d} · avg {s}", .{ g.count, try f.reports.money(&average, @divTrunc(g.amount, @as(i64, @intCast(g.count)))) })
        else if (kind == .category or kind == .account)
            try std.fmt.allocPrint(a, "{d} · {s}", .{ g.count, try percentage(a, g.amount, total) })
        else
            try std.fmt.allocPrint(a, "{d} payments", .{g.count});
        try report_row(e, id, if (kind == .month) try @import("ui_dates.zig").month_label(a, g.name) else g.name, detail, g.amount, true);
        if (kind == .variable_account) {
            try f.show(e, Report.id("legend", id), true);
            var props = e.tree.get(Report.id("legend", id)).?.props;
            props.bg = .{ .color = oriel.canvas.rgb(chart_colors[ids.items.len % chart_colors.len]) };
            try e.tree.updateUiProps(Report.id("legend", id), props);
        }
        try ids.append(a, id);
    };
    if (!try e.tree.stampKids(parent, ids.items)) return error.InvalidTemplate;
}

fn add_comparison(account: []const u8, category: []const u8, amount: i64) !void {
    for (groups.items) |*g| if (g.kind == .comparison and std.mem.eql(u8, g.account, account) and std.mem.eql(u8, g.category, category)) {
        g.amount += amount;
        g.count += 1;
        return;
    };
    const a = report_arena.allocator();
    try groups.append(a, .{ .kind = .comparison, .name = try std.fmt.allocPrint(a, "{s} · {s}", .{ account, category }), .account = try a.dupe(u8, account), .category = try a.dupe(u8, category), .amount = amount, .count = 1 });
}
fn is_variable(row: f.model.Expense) bool {
    return f.reports.special(row, f.settings()) == null and !std.mem.startsWith(u8, row.category, "Fixed:") and f.reports.fixed_item(row, f.settings()) == null;
}
fn category_chart(e: *ui.Engine) !void {
    const a = report_arena.allocator();
    // Medians use the range's months with any recorded payment, so months before
    // the ledger begins do not pull a category's typical month towards zero.
    var months: std.ArrayList([]const u8) = .empty;
    for (insight_rows) |row| {
        for (months.items) |month| {
            if (std.mem.eql(u8, month, row.date[0..7])) break;
        } else try months.append(a, row.date[0..7]);
    }
    const by_median = std.mem.eql(u8, f.value(e, f.aid("category-measure")), "median");
    const totals = try a.alloc(i64, months.items.len);
    for (groups.items) |*g| switch (g.kind) {
        .variable_category => {
            @memset(totals, 0);
            for (insight_rows) |row| if (is_variable(row) and std.mem.eql(u8, row.category, g.name)) {
                for (months.items, 0..) |month, m| if (std.mem.eql(u8, month, row.date[0..7])) {
                    totals[m] += row.amount;
                };
            };
            g.total = g.amount;
            g.median = f.reports.median(totals);
            g.amount = if (by_median) g.median else g.total;
        },
        .planned_category => {
            g.median = g.amount;
            g.total = g.amount * @as(i64, @intCast(range_months));
            g.amount = if (by_median) g.median else g.total;
        },
        else => {},
    };
    var indexes: std.ArrayList(usize) = .empty;
    for (groups.items, 0..) |g, i| if (g.kind == .variable_category or g.kind == .planned_category) try indexes.append(a, i);
    var has_category = false;
    for (indexes.items) |i| has_category = has_category or groups.items[i].kind == .variable_category;
    try f.show(e, f.aid("category-hint"), by_median and has_category);
    std.mem.sort(usize, indexes.items, groups.items, struct {
        fn less(all: []Group, x: usize, y: usize) bool {
            return all[x].amount > all[y].amount;
        }
    }.less);
    var ids: std.ArrayList(i64) = .empty;
    const maximum = if (indexes.items.len > 0) groups.items[indexes.items[0]].amount else 0;
    for (indexes.items, 0..) |i, index| {
        const g = groups.items[i];
        const id = 8000000 + @as(i64, @intCast(index)) * 16;
        var amount: [48]u8 = undefined;
        var other: [48]u8 = undefined;
        const detail = if (g.kind == .planned_category) (if (by_median) "Planned a month" else "Planned") else if (by_median)
            try std.fmt.allocPrint(a, "{d} payments · total {s}", .{ g.count, try f.reports.money(&other, g.total) })
        else if (months.items.len > 1)
            try std.fmt.allocPrint(a, "{d} payments · median {s} a month", .{ g.count, try f.reports.money(&other, g.median) })
        else
            try std.fmt.allocPrint(a, "{d} payments", .{g.count});
        const budgeted = budget_of(g.name);
        var budget_money: [48]u8 = undefined;
        const full_detail = if (g.kind == .variable_category and budgeted != null) try std.fmt.allocPrint(a, "{s} · budget {s}", .{ detail, try f.reports.money(&budget_money, budgeted.?) }) else detail;
        _ = try ChartRow.mount(&e.tree, id, 75600, &.{ .{ .name = "title", .value = g.name }, .{ .name = "detail", .value = full_detail }, .{ .name = "amount", .value = try f.reports.money(&amount, g.amount) } });
        var props = e.tree.get(ChartRow.id("bar", id)).?.props;
        props.w = .{ .pct = if (maximum > 0) @as(f32, @floatFromInt(g.amount)) / @as(f32, @floatFromInt(maximum)) * 100 else 0 };
        if (g.kind == .planned_category) props.bg = .{ .color = oriel.canvas.rgb(if (e.tree.dark) 0xe6c07b else 0xb88736) };
        try e.tree.updateUiProps(ChartRow.id("bar", id), props);
        // A tap opens the category's payments; a long press offers its median month to the budget.
        if (g.kind == .variable_category) {
            try group_actions.put(a, id, i);
            try budget_offers.put(a, id, i);
            try f.mark_action(e, id, g.name);
        }
        try ids.append(a, id);
    }
    if (!try e.tree.stampKids(f.aid("category-chart"), ids.items)) return error.InvalidTemplate;
}
fn comparison_panels(e: *ui.Engine) !void {
    const a = report_arena.allocator();
    var accounts: std.StringHashMapUnmanaged(void) = .empty;
    var panels: std.ArrayList(i64) = .empty;
    for (groups.items) |account_group| {
        if (account_group.kind != .comparison or accounts.contains(account_group.account)) continue;
        try accounts.put(a, account_group.account, {});
        var total: i64 = 0;
        var count: usize = 0;
        for (groups.items) |g| if (g.kind == .comparison and std.mem.eql(u8, g.account, account_group.account)) {
            total += g.amount;
            count += g.count;
        };
        const panel = 18000000 + @as(i64, @intCast(panels.items.len)) * 16;
        var amount: [48]u8 = undefined;
        const detail = try std.fmt.allocPrint(a, "{d} payments · {s}", .{ count, try f.reports.money(&amount, total) });
        _ = try Comparison.mount(&e.tree, panel, 75700, &.{ .{ .name = "title", .value = account_group.account }, .{ .name = "detail", .value = detail } });
        var ids: std.ArrayList(i64) = .empty;
        for (groups.items, 0..) |g, i| if (g.kind == .comparison and std.mem.eql(u8, g.account, account_group.account)) {
            const id = 10000000 + @as(i64, @intCast(i)) * 16;
            try report_row(e, id, g.category, try percentage(a, g.amount, total), g.amount, true);
            try group_actions.put(a, id, i);
            try ids.append(a, id);
        };
        if (!try e.tree.stampKids(Comparison.id("rows", panel), ids.items)) return error.InvalidTemplate;
        try panels.append(a, panel);
    }
    if (!try e.tree.stampKids(f.aid("account-comparison"), panels.items)) return error.InvalidTemplate;
}
/// Home's period feeds its category and account lists; Insights uses its own month range.
pub fn render_reports(e: *ui.Engine, rows: []const f.model.Expense, insight: []const f.model.Expense, months: usize) !void {
    insight_rows = insight;
    range_months = @max(months, 1);
    defer insight_rows = &.{};
    try collect_groups(e, rows, insight);
    try group_rows(e, f.aid("category-report"), .category, 2000000);
    try group_rows(e, f.aid("account-report"), .account, 4000000);
    try group_rows(e, f.aid("account-chart"), .variable_account, 6000000);
    try account_donut(e);
    try category_chart(e);
    try comparison_panels(e);
    try group_rows(e, f.aid("merchant-report"), .merchant, 12000000);
    try special_payments(e, insight);
    try group_rows(e, f.aid("month-report"), .month, 16000000);
    try fixed_summary(e, insight);
    if (f.s.modal == .fixed) try fixed_report(e);
}
fn collect_groups(e: *ui.Engine, rows: []const f.model.Expense, insight: []const f.model.Expense) !void {
    _ = report_arena.reset(.retain_capacity);
    groups = .empty;
    group_actions = .empty;
    budget_offers = .empty;
    budget_rows = .empty;
    for (rows) |row| {
        try add_group(.category, try f.reports.category_name(report_arena.allocator(), row, f.settings()), row.amount);
        try add_group(.account, try f.reports.account_label(report_arena.allocator(), row.account, f.settings()), row.amount);
    }
    for (insight) |row| {
        if (is_variable(row)) {
            try add_group(.variable_account, try f.reports.account_label(report_arena.allocator(), row.account, f.settings()), row.amount);
            try add_group(.variable_category, row.category, row.amount);
            const group = if (std.mem.eql(u8, f.value(e, f.aid("comparison-mode")), "combined")) "All accounts" else try f.reports.account_label(report_arena.allocator(), row.account, f.settings());
            try add_comparison(group, row.category, row.amount);
        }
        const merchant = try f.reports.merchant(report_arena.allocator(), row.payee, f.settings(), !std.mem.eql(u8, f.value(e, f.aid("merchant-grouping")), "exact"));
        const search = f.value(e, f.aid("merchant-search"));
        const category = f.value(e, f.aid("merchant-category"));
        if (f.reports.contains(merchant, search) and (category.len == 0 or f.reports.category_matches(category, row, f.settings()))) try add_group(.merchant, merchant, row.amount);
        if (f.reports.special(row, f.settings())) |label| try add_group(.special, label, row.amount);
    }
    if (f.s.snapshot) |snapshot| for (snapshot.value.expenses) |row| if (f.value(e, f.aid("account-filter")).len == 0 or std.mem.eql(u8, f.value(e, f.aid("account-filter")), row.account)) {
        try add_group(.month, row.date[0..7], row.amount);
    };
    if (include_planned) for (f.settings().fixed_expenses_items) |commitment| try add_group(.planned_category, commitment.name, commitment.amount);
    const merchant_sort = f.value(e, f.aid("merchant-sort"));
    std.mem.sort(Group, groups.items, merchant_sort, struct {
        fn less(order: []const u8, x: Group, y: Group) bool {
            if (x.kind != y.kind) return @intFromEnum(x.kind) < @intFromEnum(y.kind);
            if (x.kind == .merchant) {
                if (std.mem.eql(u8, order, "name")) return std.ascii.lessThanIgnoreCase(x.name, y.name);
                if (std.mem.eql(u8, order, "purchases")) return x.count > y.count;
                if (std.mem.eql(u8, order, "low")) return x.amount < y.amount;
            }
            if (x.kind == .month) return std.mem.order(u8, x.name, y.name) == .gt;
            return x.amount > y.amount;
        }
    }.less);
}
fn account_donut(e: *ui.Engine) !void {
    _ = try Donut.mount(&e.tree, 580000, 75500, &.{});
    const parent = e.tree.get(f.aid("account-chart")).?;
    var chart_ids: std.ArrayList(i64) = .empty;
    try chart_ids.append(report_arena.allocator(), 580000);
    for (parent.kids.items) |child| try chart_ids.append(report_arena.allocator(), child.id);
    if (!try e.tree.stampKids(parent.id, chart_ids.items)) return error.InvalidTemplate;
    program.begin();
    var sum: i64 = 0;
    for (groups.items) |g| if (g.kind == .variable_account) {
        sum += g.amount;
    };
    var money_buf: [48]u8 = undefined;
    try f.set_text(e, Donut.id("total", 580000), try f.reports.money(&money_buf, sum));
    var position: f32 = -std.math.pi / 2.0;
    var index: usize = 0;
    for (groups.items) |g| if (g.kind == .variable_account and sum > 0) {
        const end = position + @as(f32, @floatFromInt(g.amount)) / @as(f32, @floatFromInt(sum)) * std.math.pi * 2;
        program.beginPath();
        program.moveTo(84, 84);
        program.arc(84, 84, 84, position, end, false);
        program.closePath();
        program.fillStyle(oriel.canvas.rgb(chart_colors[index % chart_colors.len]));
        program.fill();
        position = end;
        index += 1;
    };
    program.beginPath();
    program.circle(84, 84, 60);
    program.fillStyle(oriel.canvas.rgb(if (e.tree.dark) 0x191d19 else 0xf0f3eb));
    program.fill();
    program.last_len = program.cmds.items.len;
    if (!e.tree.commitCanvas(Donut.id("chart", 580000), program.cmds.items, &program.arena)) return error.MissingCanvas;
}
fn special_payments(e: *ui.Engine, rows: []const f.model.Expense) !void {
    const a = report_arena.allocator();
    var ids: std.ArrayList(i64) = .empty;
    var selected: std.ArrayList(f.model.Expense) = .empty;
    for (rows) |row| if (f.reports.special(row, f.settings())) |label| {
        const id = 14000000 + @as(i64, @intCast(ids.items.len)) * 16;
        try report_row(e, id, try std.fmt.allocPrint(a, "{s} · {s}", .{ row.date, row.payee }), label, row.amount, true);
        try ids.append(a, id);
        try selected.append(a, row);
    };
    special_rows = selected.items;
    if (!try e.tree.stampKids(f.aid("special-payments"), ids.items)) return error.InvalidTemplate;
}
fn fixed_summary(e: *ui.Engine, rows: []const f.model.Expense) !void {
    var ids: std.ArrayList(i64) = .empty;
    for (f.settings().fixed_expenses_items, 0..) |commitment, i| {
        var paid: i64 = 0;
        for (rows) |row| if (f.reports.special(row, f.settings()) == null and f.reports.fixed_item(row, f.settings()) == i) {
            paid += row.amount;
        };
        var plan: [48]u8 = undefined;
        var detail: [128]u8 = undefined;
        const base = 360000 + @as(i64, @intCast(i)) * 16;
        // A range plans each fixed commitment once per calendar month.
        try report_row(e, base, commitment.name, try std.fmt.bufPrint(&detail, "Planned {s}", .{try f.reports.money(&plan, commitment.amount * @as(i64, @intCast(range_months)))}), paid, true);
        try ids.append(report_arena.allocator(), base);
    }
    if (ids.items.len == 0) {
        try f.supporting(e, 359000, "None configured.");
        try ids.append(report_arena.allocator(), 359000);
    }
    if (!try e.tree.stampKids(f.aid("fixed-report"), ids.items)) return error.InvalidTemplate;
}

fn fixed_report(e: *ui.Engine) !void {
    const a = report_arena.allocator();
    var ids: std.ArrayList(i64) = .empty;
    var planned: i64 = 0;
    var total_paid: i64 = 0;
    for (f.settings().fixed_expenses_items, 0..) |commitment, i| {
        var paid: i64 = 0;
        var count: usize = 0;
        for (f.s.snapshot.?.value.expenses) |row| if (f.period(e).matches(row, f.settings()) and f.reports.special(row, f.settings()) == null and f.reports.fixed_item(row, f.settings()) == i) {
            paid += row.amount;
            count += 1;
        };
        planned += commitment.amount;
        total_paid += paid;
        var amount: [48]u8 = undefined;
        const base = 610000 + @as(i64, @intCast(i)) * 16;
        const detail = if (count == 0) "Monthly plan" else try std.fmt.allocPrint(a, "{s} paid · {d} payment{s}", .{ try f.reports.money(&amount, paid), count, if (count > 1) "s" else "" });
        try report_row(e, base, commitment.name, detail, commitment.amount, count > 0);
        try ids.append(a, base);
    }
    if (ids.items.len == 0) {
        try f.supporting(e, 609000, "None configured.");
        try ids.append(a, 609000);
    }
    var plan: [48]u8 = undefined;
    var paid: [48]u8 = undefined;
    const month = f.value(e, f.aid("month"));
    try f.set_text(e, Fixed.id("fixed-summary", 12000), try std.fmt.allocPrint(a, "{s} a month · {s} paid{s}{s}", .{ try f.reports.money(&plan, planned), try f.reports.money(&paid, total_paid), if (month.len > 0) " in " else "", if (month.len > 0) try @import("ui_dates.zig").month_label(a, month) else "" }));
    if (!try e.tree.stampKids(Fixed.id("fixed-list", 12000), ids.items)) return error.InvalidTemplate;
}
fn budget_of(name: []const u8) ?i64 {
    const budgets = f.settings().category_budgets;
    if (budgets != .object) return null;
    const amount = budgets.object.get(name) orelse return null;
    return if (amount == .integer) amount.integer else null;
}
/// Home's budget card: each budgeted category's spending this month against its budget.
pub fn render_budgets(e: *ui.Engine, rows: []const f.model.Expense) !void {
    const a = report_arena.allocator();
    var ids: std.ArrayList(i64) = .empty;
    const budgets = f.settings().category_budgets;
    if (budgets == .object) for (budgets.object.keys(), budgets.object.values()) |name, value| {
        if (value != .integer) continue;
        const budget = value.integer;
        const spent = f.reports.budget_spent(rows, f.settings(), name);
        const id = budget_base + @as(i64, @intCast(ids.items.len)) * 16;
        var spent_text: [48]u8 = undefined;
        var budget_text: [48]u8 = undefined;
        var left_text: [48]u8 = undefined;
        const detail = if (spent > budget)
            try std.fmt.allocPrint(a, "{s} over {s}", .{ try f.reports.money(&left_text, spent - budget), try f.reports.money(&budget_text, budget) })
        else
            try std.fmt.allocPrint(a, "of {s} · {s} left", .{ try f.reports.money(&budget_text, budget), try f.reports.money(&left_text, budget - spent) });
        _ = try ChartRow.mount(&e.tree, id, 75600, &.{ .{ .name = "title", .value = name }, .{ .name = "detail", .value = detail }, .{ .name = "amount", .value = try f.reports.money(&spent_text, spent) } });
        var props = e.tree.get(ChartRow.id("bar", id)).?.props;
        props.w = .{ .pct = if (budget > 0) @min(100, @as(f32, @floatFromInt(spent)) / @as(f32, @floatFromInt(budget)) * 100) else 100 };
        if (spent > budget) props.bg = .{ .color = oriel.canvas.rgb(if (e.tree.dark) 0xffb4ab else 0xba1a1a) };
        try e.tree.updateUiProps(ChartRow.id("bar", id), props);
        try budget_rows.put(a, id, name);
        try f.mark_action(e, id, name);
        try ids.append(a, id);
    };
    if (!try e.tree.stampKids(f.aid("category-budgets"), ids.items)) return error.InvalidTemplate;
}
/// A long press (right click on desktop): Insights categories offer their median month
/// to the budget, and Home's budgets offer their removal.
pub fn context(e: *ui.Engine, id: i64) !bool {
    if (id != id - @mod(id, 16)) return false;
    if (budget_offers.get(id)) |i| {
        try offer_budget(e, groups.items[i].name, groups.items[i].median);
        return true;
    }
    if (budget_rows.get(id)) |name| {
        try offer_budget(e, name, null);
        return true;
    }
    return false;
}
fn offer_budget(e: *ui.Engine, name: []const u8, amount: ?i64) !void {
    var buf: [400]u8 = undefined;
    var current_text: [48]u8 = undefined;
    var amount_text: [48]u8 = undefined;
    if (amount) |value| if (value <= 0) {
        try f.status(e, try std.fmt.bufPrint(&buf, "{s}'s median month is $0; there is nothing to budget.", .{name}));
        return;
    };
    const len = @min(name.len, pending_budget.name.len);
    @memcpy(pending_budget.name[0..len], name[0..len]);
    pending_budget.len = len;
    pending_budget.amount = amount;
    const current = budget_of(name);
    if (amount) |value| {
        const message = if (current) |old|
            try std.fmt.bufPrint(&buf, "Change the {s} budget from {s} to its median, {s} a month?", .{ name, try f.reports.money(&current_text, old), try f.reports.money(&amount_text, value) })
        else
            try std.fmt.bufPrint(&buf, "Add {s} to the monthly budget at its median, {s} a month?", .{ name, try f.reports.money(&amount_text, value) });
        try f.confirm_editor(e, .category_budget, message, if (current != null) "Update budget" else "Add to budget");
    } else try f.confirm_editor(e, .category_budget, try std.fmt.bufPrint(&buf, "Remove the {s} budget of {s} a month?", .{ name, try f.reports.money(&current_text, current orelse 0) }), "Remove budget");
}
/// Saves the confirmed category budget with the usual settings conflict check.
pub fn save_category_budget(e: *ui.Engine) !void {
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const current = f.s.snapshot.?.value.settings;
    var config = try std.json.parseFromSliceLeaky(legacy.Settings, a, current, .{ .ignore_unknown_fields = true });
    var budgets: std.json.ObjectMap = if (config.category_budgets == .object) try config.category_budgets.object.clone(a) else .empty;
    const name = pending_budget.name[0..pending_budget.len];
    if (pending_budget.amount) |amount| try budgets.put(a, name, .{ .integer = amount }) else _ = budgets.orderedRemove(name);
    config.category_budgets = .{ .object = budgets };
    try prefs.validate(config);
    f.s.busy = true;
    errdefer f.s.busy = false;
    try f.invoke(e, .settings, "save_budget", prefs.Edit{ .settings = config, .expected = current });
}
pub fn parse_queued(e: *ui.Engine) !void {
    if (oriel.target.is_android or parser_busy or f.s.busy or f.s.snapshot == null) return;
    for (f.s.snapshot.?.value.statements) |source| if (std.mem.eql(u8, source.status, "queued") and !attempted.contains(source.hash)) {
        const key = try e.gpa.dupe(u8, source.hash);
        errdefer e.gpa.free(key);
        try attempted.put(e.gpa, key, {});
        errdefer _ = attempted.remove(key);
        parser_busy = true;
        errdefer parser_busy = false;
        try f.invoke(e, .background_parse, "parse_statement", .{ .hash = source.hash });
        return;
    };
}
pub fn render_statements(e: *ui.Engine) !void {
    if (f.s.modal != .statements or f.s.snapshot == null) return;
    try f.show(e, Statements.id("santander-import", 13000), f.s.snapshot.?.value.santander_available);
    try render_bank_choice(e);
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(e.gpa);
    for (f.s.snapshot.?.value.statements, 0..) |source, i| {
        const base = 420000 + @as(i64, @intCast(i)) * 16;
        const queued = std.mem.eql(u8, source.status, "queued");
        _ = try StatementSource.mount(&e.tree, base, 73100, &.{ .{ .name = "title", .value = source.name }, .{ .name = "detail", .value = if (queued) "Queued for desktop" else "Parsed" } });
        try f.set_text(e, StatementSource.id("action", base), if (queued) "Parse" else "Review");
        var props = e.tree.get(StatementSource.id("action", base)).?.props;
        props.dis = queued and (std.mem.eql(u8, f.s.snapshot.?.value.platform, "android") or std.mem.eql(u8, f.s.snapshot.?.value.platform, "ios"));
        props.op = if (props.dis) 0.38 else 1;
        try e.tree.updateUiProps(StatementSource.id("action", base), props);
        try f.set_text(e, StatementSource.id("secondary", base), if (source.format == .json) "Save JSON" else "Save PDF");
        try f.mark_actions(e, StatementSource, base, .{ "action", "secondary" });
        try ids.append(e.gpa, base);
    }
    if (!try e.tree.stampKids(Statements.id("statement-list", 13000), ids.items)) return error.InvalidTemplate;
}
pub fn render_bulk(e: *ui.Engine) !void {
    try f.show(e, f.aid("bulk-preview"), bulk_edit != null);
    try f.show(e, f.aid("bulk-form"), bulk_edit == null);
}

fn bulk_preview(e: *ui.Engine) !void {
    bulk_edit = null;
    _ = bulk_arena.reset(.retain_capacity);
    const a = bulk_arena.allocator();
    const pattern = std.mem.trim(u8, f.value(e, f.aid("bulk-pattern")), " ");
    const categories = @import("core/categories.zig");
    const category = try categories.canonical(a, f.value(e, f.aid("bulk-category")), try categories.catalog(a, f.s.snapshot.?.value.expenses, f.settings()));
    try f.model.text(pattern, 240, false);
    try f.model.text(category, 120, false);
    const prior = try a.dupe(u8, f.s.snapshot.?.value.settings);
    var config = try std.json.parseFromSliceLeaky(legacy.Settings, a, prior, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    var targets: std.ArrayList(prefs.Target) = .empty;
    var ids: std.ArrayList(i64) = .empty;
    for (f.s.snapshot.?.value.expenses) |row| if ((!@import("oriel_desktop.zig").has_selection() or @import("oriel_desktop.zig").selected(row.id)) and f.period(e).matches(row, f.settings()) and f.reports.contains(row.payee, pattern) and (!bulk_only_other or f.reports.uncategorized(row, f.settings()))) {
        const base = 560000 + @as(i64, @intCast(targets.items.len)) * 16;
        var amount: [48]u8 = undefined;
        try f.supporting(e, base, try std.fmt.allocPrint(a, "{s} · {s} · {s}", .{ row.date, row.payee, try f.reports.money(&amount, row.amount) }));
        try ids.append(a, base);
        try targets.append(a, .{ .id = try a.dupe(u8, row.id), .revision = row.revision });
    };
    if (bulk_remember) {
        if (config.categories != .object) config.categories = .{ .object = .empty };
        var words: std.json.Array = if (config.categories.object.get(category)) |v| v.array else .init(a);
        var found = false;
        for (words.items) |word| if (std.mem.eql(u8, word.string, pattern)) {
            found = true;
            break;
        };
        if (!found) try words.append(.{ .string = try a.dupe(u8, pattern) });
        try config.categories.object.put(a, try a.dupe(u8, category), .{ .array = words });
    }
    bulk_edit = .{ .settings = config, .expected = prior, .targets = targets.items, .category = try a.dupe(u8, category) };
    const summary = try std.fmt.allocPrint(a, "{d} → “{s}”", .{ targets.items.len, category });
    try f.set_text(e, f.aid("bulk-summary"), summary);
    if (!try e.tree.stampKids(f.aid("bulk-matches"), ids.items)) return error.InvalidTemplate;
    try render_bulk(e);
    f.redraw(e);
}
fn keywords(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        const word = std.mem.trim(u8, part, " \t\r\n");
        if (word.len > 0) try list.append(a, try a.dupe(u8, word));
    }
    return list.toOwnedSlice(a);
}
fn mapping(e: *ui.Engine, key: []const u8, v: []const u8, amount: i64) !void {
    if (mapping_count >= 1000) return error.TooManyRules;
    const base = mapping_base + @as(i64, @intCast(mapping_count)) * mapping_stride;
    _ = try Mapping.mount(&e.tree, base, 72000, &.{
        .{ .name = "key_label", .value = switch (section) {
            .fixed => "Name",
            .accounts => "Account or card",
            .categories => "Category",
            else => "Description contains",
        } },
        .{ .name = "value_label", .value = switch (section) {
            .fixed, .categories => "Keywords (comma separated)",
            .accounts => "Cardholder",
            .vendors => "Show as",
            else => "Label",
        } },
    });
    try f.set_value(e, Mapping.id("key", base), key);
    if (section == .categories) {
        var props = e.tree.get(Mapping.id("key", base)).?.props;
        props.ro = true;
        try e.tree.updateUiProps(Mapping.id("key", base), props);
    }
    try f.set_value(e, Mapping.id("value", base), v);
    var buf: [32]u8 = undefined;
    try f.set_value(e, Mapping.id("amount", base), try std.fmt.bufPrint(&buf, "{d}", .{amount}));
    try f.show(e, Mapping.id("amount-field", base), section == .fixed);
    mapping_count += 1;
}
fn mapping_parent() i64 {
    return switch (section) {
        .fixed => pid("preferences-fixed"),
        .accounts => pid("preferences-accounts"),
        .categories => pid("preferences-categories"),
        .vendors => pid("preferences-vendors"),
        .special => pid("preferences-special"),
        else => pid("preferences-fields"),
    };
}
fn mapping_kids(e: *ui.Engine) !void {
    var ids: [1000]i64 = undefined;
    for (0..mapping_count) |i| ids[i] = mapping_base + @as(i64, @intCast(i)) * mapping_stride;
    if (!try e.tree.stampKids(mapping_parent(), ids[0..mapping_count])) return error.InvalidTemplate;
}
pub fn open_category_rules(e: *ui.Engine) !void {
    try open_preferences(e, .categories);
}
fn reset_modal() void {
    expected = "";
    original = .{};
    current_hash = "";
    observations = &.{};
    show_reviewed_observations = false;
    conflict = null;
    _ = modal_arena.reset(.free_all);
}
fn open_preferences(e: *ui.Engine, chosen: Section) !void {
    try open_preferences_from(e, chosen, f.s.snapshot.?.value.settings);
}
fn open_preferences_from(e: *ui.Engine, chosen: Section, base_settings: []const u8) !void {
    reset_modal();
    mapping_count = 0;
    section = chosen;
    const a = modal_arena.allocator();
    expected = try a.dupe(u8, base_settings);
    try @import("core/json_limits.zig").check(expected);
    original = try std.json.parseFromSliceLeaky(legacy.Settings, a, expected, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    try open(e, .preferences);
    inline for (.{ "budget", "fixed", "accounts", "categories", "vendors", "special" }) |name| try f.show(e, pid("pref-section-" ++ name), std.mem.eql(u8, name, @tagName(section)));
    try f.set_text(e, pid("preferences-title"), switch (section) {
        .budget => "Salary & owners",
        .fixed => "Fixed commitments",
        .accounts => "Accounts",
        .categories => "Category rules",
        .vendors => "Merchant names",
        .special => "Special payments",
    });
    try f.set_text(e, pid("preferences-status"), if (section == .categories) "Manage names in Settings → Categories. Edit matching keywords here." else "");
    try f.show(e, pid("add-category"), section != .categories);
    if (section == .budget) {
        var buf: [32]u8 = undefined;
        try f.set_value(e, pid("preferences-salary"), try std.fmt.bufPrint(&buf, "{d}", .{original.salary}));
        try f.set_value(e, pid("preferences-owners"), try std.mem.join(a, ", ", original.account_owners));
        return;
    }
    if (section == .fixed) {
        for (original.fixed_expenses_items) |v| try mapping(e, v.name, try std.mem.join(a, ", ", v.keywords), v.amount);
    } else {
        const values = switch (section) {
            .accounts => original.cards_config,
            .categories => original.categories,
            .vendors => original.vendors_config,
            .special => original.special_cases,
            else => unreachable,
        };
        if (values == .object) {
            var it = values.object.iterator();
            while (it.next()) |entry| {
                const v = entry.value_ptr.*;
                const text = if (v == .string) v.string else if (section == .accounts) f.reports.holder(entry.key_ptr.*, original) else blk: {
                    var words: std.ArrayList([]const u8) = .empty;
                    for (v.array.items) |word| try words.append(a, word.string);
                    break :blk try std.mem.join(a, ", ", words.items);
                };
                try mapping(e, entry.key_ptr.*, text, 0);
            }
        }
    }
    if (section == .categories) {
        const categories = @import("core/categories.zig");
        for (try categories.catalog(a, f.s.snapshot.?.value.expenses, original)) |name| {
            if (!categories.protected(name) and (original.categories != .object or !original.categories.object.contains(name))) try mapping(e, name, "", 0);
        }
    }
    try mapping_kids(e);
}
pub const PreferencesDraft = struct { section: Section, expected: []const u8, rows: usize };
pub fn preferences_draft() ?PreferencesDraft {
    if (f.s.modal != .preferences) return null;
    return .{ .section = section, .expected = expected, .rows = mapping_count };
}
pub fn restore_preferences(e: *ui.Engine, draft: PreferencesDraft) !void {
    if (draft.rows > 1000) return error.TooManyRules;
    try open_preferences_from(e, draft.section, draft.expected);
    while (mapping_count < draft.rows) try mapping(e, "", "", 0);
    if (draft.section != .budget) try mapping_kids(e);
}

fn save_preferences(e: *ui.Engine) !void {
    if (f.s.busy) return;
    const a = modal_arena.allocator();
    var config = original;
    if (section == .budget) {
        config.salary = try std.fmt.parseInt(i64, f.value(e, pid("preferences-salary")), 10);
        config.account_owners = try keywords(a, f.value(e, pid("preferences-owners")));
    } else if (section == .fixed) {
        var list: std.ArrayList(legacy.Fixed) = .empty;
        for (0..mapping_count) |i| {
            const base = mapping_base + @as(i64, @intCast(i)) * mapping_stride;
            if (e.tree.get(base).?.props.none) continue;
            const name = f.value(e, Mapping.id("key", base));
            const text = f.value(e, Mapping.id("value", base));
            var words = try keywords(a, text);
            for (original.fixed_expenses_items) |fixed| if (std.mem.eql(u8, name, fixed.name) and std.mem.eql(u8, text, try std.mem.join(a, ", ", fixed.keywords))) {
                words = fixed.keywords;
                break;
            };
            try list.append(a, .{ .name = name, .amount = try std.fmt.parseInt(i64, f.value(e, Mapping.id("amount", base)), 10), .keywords = words });
        }
        config.fixed_expenses_items = try list.toOwnedSlice(a);
    } else {
        var obj: std.json.ObjectMap = .empty;
        for (0..mapping_count) |i| {
            const base = mapping_base + @as(i64, @intCast(i)) * mapping_stride;
            if (e.tree.get(base).?.props.none) continue;
            const key = f.value(e, Mapping.id("key", base));
            const v = f.value(e, Mapping.id("value", base));
            if (section == .special) {
                try prefs.put_special_rule(a, &obj, key, v);
                continue;
            }
            if (obj.contains(key)) return error.DuplicateRule;
            var out: std.json.Value = .{ .string = v };
            if (section == .categories) {
                var words: std.json.Array = .init(a);
                for (try keywords(a, v)) |word| try words.append(.{ .string = word });
                out = .{ .array = words };
                // A no-op save preserves original keyword strings exactly,
                // including a comma inside one imported keyword.
                if (original.categories == .object) if (original.categories.object.get(key)) |old| if (old == .array) {
                    var original_words: std.ArrayList([]const u8) = .empty;
                    for (old.array.items) |word| try original_words.append(a, word.string);
                    if (std.mem.eql(u8, v, try std.mem.join(a, ", ", original_words.items))) out = old;
                };
            }
            if (section == .accounts and original.cards_config == .object) if (original.cards_config.object.get(key)) |old| if (old == .object) {
                out = old;
                try out.object.put(a, "holder", .{ .string = v });
            };
            try obj.put(a, key, out);
        }
        const v: std.json.Value = .{ .object = obj };
        switch (section) {
            .accounts => config.cards_config = v,
            .categories => config.categories = v,
            .vendors => config.vendors_config = v,
            .special => config.special_cases = v,
            else => unreachable,
        }
    }
    try prefs.validate(config);
    f.s.busy = true;
    errdefer f.s.busy = false;
    try f.invoke(e, .settings, "save_budget", prefs.Edit{ .settings = config, .expected = expected });
}
fn sync_summary(e: *ui.Engine) !void {
    const state = core orelse return;
    var last: [64]u8 = undefined;
    var buf: [220]u8 = undefined;
    const when = if (state.last_success <= 0) "never" else try @import("ui_dates.zig").local_time(&last, state.last_success);
    var extras: [80]u8 = undefined;
    var conflicts_text: [40]u8 = undefined;
    const pending = if (state.pending > 0) try std.fmt.bufPrint(&extras, " · {d} to send", .{state.pending}) else "";
    const conflicts_label = if (state.conflicts.len > 0) try std.fmt.bufPrint(&conflicts_text, " · {d} conflicts", .{state.conflicts.len}) else "";
    try f.set_text(e, sid("sync-summary"), try std.fmt.bufPrint(&buf, "{s}\nLast sync {s}{s}{s}", .{ connection_state, when, pending, conflicts_label }));
    if (pair_expires > 0) {
        const seconds = @max(0, pair_expires - std.Io.Clock.real.now(f.s.io).toSeconds());
        try f.set_text(e, sid("sync-expiry"), try std.fmt.bufPrint(&buf, "Scan with your phone · {d}s", .{seconds}));
        if (seconds == 0) {
            pair_expires = 0;
            try f.set_text(e, sid("sync-expiry"), "Expired");
            try e.tree.setImageData(sid("sync-qr"), null);
            try f.set_value(e, sid("sync-link"), "");
        }
    }
}
pub fn refresh_sync(e: *ui.Engine) !void {
    try f.invoke(e, .sync_status, "sync_status", .{});
    try f.invoke(e, .sync_transport, "sync_control", .{ .action = "status" });
}
fn sync_action(e: *ui.Engine, action: []const u8, device: []const u8) !void {
    if (f.s.busy) return;
    f.s.busy = true;
    errdefer f.s.busy = false;
    const pasted = f.value(e, sid("sync-paste"));
    if (pasted.len > 8192) return error.InvalidPairingCode;
    var link: [8192]u8 = undefined;
    var len: usize = 0;
    for (pasted) |ch| if (!std.ascii.isWhitespace(ch)) {
        link[len] = ch;
        len += 1;
    };
    const message = if (std.mem.eql(u8, action, "pairing")) "Creating pairing code" else if (std.mem.eql(u8, action, "scan_pair") or std.mem.eql(u8, action, "pair_link")) "Pairing with the desktop" else if (std.mem.eql(u8, action, "sync_now")) "Syncing" else if (std.mem.eql(u8, action, "start")) "Starting sync service" else if (std.mem.eql(u8, action, "restart")) "Restarting sync service" else if (std.mem.eql(u8, action, "stop")) "Stopping sync service" else "Disconnecting";
    try progress.task(e, .sync, message, null);
    try f.invoke(e, .sync_action, "sync_control", .{ .action = action, .device = device, .link = link[0..len], .replace = replace_desktop });
}
fn open_statement(e: *ui.Engine, hash: []const u8, queued: bool) !void {
    reset_modal();
    current_hash = try modal_arena.allocator().dupe(u8, hash);
    if (queued) {
        f.s.busy = true;
        try f.invoke(e, .parse_pdf, "parse_statement", .{ .hash = current_hash });
    } else try f.invoke(e, .observations, "statement_observations", .{ .hash = current_hash });
}
fn render_observations(e: *ui.Engine) !void {
    try f.close_modal(e);
    try open(e, .statement);
    var ids: std.ArrayList(i64) = .empty;
    const a = modal_arena.allocator();
    var suggestion_count: usize = 0;
    var open_count: usize = 0;
    for (f.s.snapshot.?.value.statements) |source| if (std.mem.eql(u8, source.hash, current_hash)) {
        try f.set_text(e, Statement.id("statement-title", 14000), source.name);
        break;
    };
    for (observations, 0..) |obs, i| {
        const base = review_base + @as(i64, @intCast(i)) * review_stride;
        var buf: [48]u8 = undefined;
        const title = try std.fmt.allocPrint(a, "{s} · {s}", .{ obs.source.date, obs.source.payee });
        const detail = try std.fmt.allocPrint(a, "{s} · {s} · {s}", .{ try f.reports.amount_text(&buf, obs.source.amount, obs.source.currency), try f.reports.account_label(a, obs.source.account, f.settings()), obs.source.category });
        _ = try Review.mount(&e.tree, base, 73000, &.{ .{ .name = "title", .value = title }, .{ .name = "detail", .value = detail } });
        var values: std.ArrayList([]const u8) = .empty;
        var labels: std.ArrayList([]const u8) = .empty;
        try values.appendSlice(a, &.{ "", "create", "ignore" });
        try labels.appendSlice(a, &.{ "Choose…", "Add as new payment", "Ignore" });
        for (f.s.snapshot.?.value.expenses) |row| if (statements.candidate(obs.source, row)) {
            try values.append(a, row.id);
            try labels.append(a, try std.fmt.allocPrint(a, "Same as {s} · {s}", .{ row.date, row.payee }));
        };
        var choice: []const u8 = if (obs.expense_id) |id| id else if (obs.ignored) "ignore" else if (values.items.len > 3) "" else "create";
        if (obs.expense_id == null and !obs.ignored) open_count += 1;
        if (obs.expense_id == null and !obs.ignored) if (obs.match) |match| {
            choice = match.id;
            try values.append(a, match.id);
            try labels.append(a, "Already recorded in your ledger");
            suggestion_count += 1;
        };
        if (obs.expense_id) |id| {
            try values.append(a, id);
            try labels.append(a, "Linked payment");
        }
        try f.options(e, Review.id("choice", base), values.items, labels.items, choice);
        var p = e.tree.get(Review.id("choice", base)).?.props;
        p.dis = obs.expense_id != null or obs.ignored;
        try e.tree.updateUiProps(Review.id("choice", base), p);
        const linked = obs.expense_id != null or obs.ignored;
        try f.show(e, Review.id("choice-field", base), !linked);
        try f.show(e, Review.id("state", base), linked);
        try f.set_text(e, Review.id("state", base), if (obs.ignored) "Ignored" else "Linked");
        try f.show(e, Review.id("undo", base), linked);
        const candidates = values.items.len - (if (obs.expense_id != null) @as(usize, 4) else 3);
        try f.show(e, Review.id("matches", base), !linked and candidates > 0);
        try f.set_text(e, Review.id("matches", base), try std.fmt.allocPrint(a, "{d} possible match{s}", .{ candidates, if (candidates == 1) "" else "es" }));
        try f.mark_action(e, Review.id("undo", base), "Undo");
        try f.show(e, Review.id("review-row", base), show_reviewed_observations or (!linked and obs.match == null));
        try ids.append(a, base);
    }
    if (!try e.tree.stampKids(Statement.id("statement-rows", 14000), ids.items)) return error.InvalidTemplate;
    const summary = if (open_count == 0) try std.fmt.allocPrint(a, "All {d} already handled · nothing to review", .{observations.len}) else if (suggestion_count == open_count) try std.fmt.allocPrint(a, "All {d} already recorded · Confirm to remember matches", .{open_count}) else if (suggestion_count > 0) try std.fmt.allocPrint(a, "{d} of {d} already recorded · choose the rest", .{ suggestion_count, open_count }) else try std.fmt.allocPrint(a, "{d} to review · {d} already handled", .{ open_count, observations.len - open_count });
    try f.set_text(e, Statement.id("statement-review-status", 14000), summary);
    try f.set_text(e, Statement.id("toggle-reviewed", 14000), if (show_reviewed_observations) "Hide handled payments" else "Show handled payments");
}
fn reconcile(e: *ui.Engine) !void {
    const a = modal_arena.allocator();
    var decisions: std.ArrayList(statements.Decision) = .empty;
    for (observations, 0..) |obs, i| {
        if (obs.expense_id != null or obs.ignored) continue;
        const choice = f.value(e, Review.id("choice", review_base + @as(i64, @intCast(i)) * review_stride));
        if (choice.len == 0) return error.DecisionRequired;
        var d: statements.Decision = .{ .observation_id = obs.id, .action = .create };
        if (std.mem.eql(u8, choice, "ignore")) d.action = .ignore else if (!std.mem.eql(u8, choice, "create")) {
            d.action = .link;
            d.expense_id = choice;
            if (obs.match != null and std.mem.eql(u8, obs.match.?.id, choice)) {
                d.expected_revision = obs.match.?.revision;
            } else for (f.s.snapshot.?.value.expenses) |row| if (std.mem.eql(u8, row.id, choice)) {
                d.expected_revision = row.revision;
                break;
            };
        }
        try decisions.append(a, d);
    }
    f.s.busy = true;
    try f.invoke(e, .reconcile, "reconcile_statement", .{ .hash = current_hash, .decisions = decisions.items });
}
fn megabytes(a: std.mem.Allocator, mb: u32) ![]const u8 {
    return if (mb >= 1024) std.fmt.allocPrint(a, "{d:.1} GB", .{@as(f64, @floatFromInt(mb)) / 1024}) else std.fmt.allocPrint(a, "{d} MB", .{mb});
}
fn scanner_row(e: *ui.Engine, base: i64, title: []const u8, detail: []const u8, in_use: bool, action: []const u8, delete: bool) !void {
    _ = try ScanRow.mount(&e.tree, base, 72100, &.{ .{ .name = "title", .value = title }, .{ .name = "detail", .value = detail } });
    try f.set_text(e, ScanRow.id("action", base), action);
    try f.show(e, ScanRow.id("action", base), action.len > 0);
    try f.show(e, ScanRow.id("secondary", base), delete);
    try f.show(e, ScanRow.id("badge", base), in_use);
    try f.show(e, ScanRow.id("progress", base), false);
    try f.mark_actions(e, ScanRow, base, .{ "action", "secondary" });
}
fn scanner_render(e: *ui.Engine) !void {
    const state = scanner orelse return;
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try f.switch_state(e, scid("scanner-fast"), state.fast);
    try f.switch_state(e, scid("scanner-gpu"), state.use_gpu);
    var label: []const u8 = if (std.mem.eql(u8, state.active, "custom")) "your imported model" else if (std.mem.eql(u8, state.active, "system")) "the phone's model" else "";
    var active_mb: u32 = 0;
    for (state.models) |m| if (std.mem.eql(u8, m.id, state.active)) {
        label = m.label;
        active_mb = m.mb;
    };
    const tight = state.free_mb > 0 and @as(f64, @floatFromInt(state.free_mb)) < @as(f64, @floatFromInt(active_mb)) * 1.25;
    try f.set_text(e, scid("scanner-summary"), if (state.active.len == 0) "Choose how vouchers are read." else if (tight) try std.fmt.allocPrint(a, "Scanning with {s} · only {s} free: close other apps for faster scans", .{ label, try megabytes(a, state.free_mb) }) else try std.fmt.allocPrint(a, "Scanning with {s}", .{label}));
    try f.set_text(e, f.aid("settings-model-summary"), if (state.active.len == 0) "Choose how vouchers are read" else try std.fmt.allocPrint(a, "Using {s}", .{label}));
    try f.show(e, scid("scanner-system"), state.system.supported);
    try f.show(e, scid("scanner-fast-row"), state.fast_available);
    try f.show(e, scid("scanner-gpu-row"), state.gpu.len > 0 and state.vision_built);
    try f.set_text(e, scid("scanner-gpu-label"), try std.fmt.allocPrint(a, "Use GPU ({s})", .{state.gpu}));
    var installed: std.ArrayList(i64) = .empty;
    var available: std.ArrayList(i64) = .empty;
    for (state.models, 0..) |m, i| {
        const base = 480000 + @as(i64, @intCast(i)) * 16;
        const in_use = std.mem.eql(u8, state.active, m.id);
        const downloading = std.mem.eql(u8, state.downloading, m.id);
        const detail = if (downloading and download_total > 0 and std.mem.eql(u8, download_id_buf[0..download_id_len], m.id)) try std.fmt.allocPrint(a, "Downloading {s} of {s}", .{ try megabytes(a, download_done), try megabytes(a, download_total) }) else if (downloading) "Starting download…" else if (m.partial_mb > 0 and !m.installed) try std.fmt.allocPrint(a, "{s} · {s} of {s} downloaded", .{ m.note, try megabytes(a, m.partial_mb), try megabytes(a, m.mb) }) else try std.fmt.allocPrint(a, "{s} · {s}", .{ m.note, try megabytes(a, m.mb) });
        try scanner_row(e, base, m.label, detail, in_use, if (downloading) "Cancel" else if (m.installed) (if (in_use) "" else "Use") else if (m.partial_mb > 0) "Resume" else "Download", m.installed and !downloading);
        if (downloading and download_total > 0 and std.mem.eql(u8, download_id_buf[0..download_id_len], m.id)) {
            var bar = e.tree.get(ScanRow.id("progress", base)).?.props;
            bar.none = false;
            bar.w = .{ .pct = @min(100, @as(f32, @floatFromInt(download_done)) / @as(f32, @floatFromInt(download_total)) * 100) };
            try e.tree.updateUiProps(ScanRow.id("progress", base), bar);
        }
        var props = e.tree.get(ScanRow.id("action", base)).?.props;
        props.dis = !downloading and !m.installed and (state.downloading.len > 0 or !state.vision_built);
        props.op = if (props.dis) 0.38 else 1;
        try e.tree.updateUiProps(ScanRow.id("action", base), props);
        if (m.installed or downloading) try installed.append(a, base) else try available.append(a, base);
    }
    try f.show(e, scid("scanner-installed-section"), installed.items.len > 0);
    try f.show(e, scid("scanner-available-section"), available.items.len > 0);
    if (state.custom) {
        const in_use = std.mem.eql(u8, state.active, "custom");
        try scanner_row(e, 492000, "Your model", "Loaded from a GGUF file", in_use, if (in_use) "" else "Use", true);
        if (!try e.tree.stampKids(scid("scanner-custom-row"), &.{492000})) return error.InvalidTemplate;
    } else if (!try e.tree.stampKids(scid("scanner-custom-row"), &.{})) return error.InvalidTemplate;
    if (state.system.supported) {
        const ready_system = std.mem.eql(u8, state.system.state, "available");
        const in_use = std.mem.eql(u8, state.active, "system");
        const downloadable = std.mem.eql(u8, state.system.state, "downloadable");
        const detail = if (ready_system) "Ready · no download needed" else if (downloadable) "Supported · needs a system download" else if (std.mem.eql(u8, state.system.state, "downloading")) "The system is downloading it" else if (state.system.reason.len > 0) state.system.reason else "Not available on this phone";
        try scanner_row(e, 494000, "Gemini Nano", detail, in_use, if (ready_system and !in_use) "Use" else if (downloadable) "Download" else "", false);
        if (!try e.tree.stampKids(scid("scanner-system-row"), &.{494000})) return error.InvalidTemplate;
    }
    inline for (.{ "model", "projector" }) |name| {
        var p = e.tree.get(scid(name)).?.props;
        p.dis = !state.vision_built;
        p.op = if (state.vision_built) 1 else 0.38;
        try e.tree.updateUiProps(scid(name), p);
    }
    if (!try e.tree.stampKids(scid("scanner-installed"), installed.items)) return error.InvalidTemplate;
    if (!try e.tree.stampKids(scid("scanner-models"), available.items)) return error.InvalidTemplate;
}
pub fn click(e: *ui.Engine, id: i64) !bool {
    return switch (f.s.modal) {
        .none => click_none(e, id),
        .preferences => click_preferences(e, id),
        .fixed => click_fixed(e, id),
        .statements => click_statements(e, id),
        .statement => click_statement(e, id),
        .scanner => click_scanner(e, id),
        .sync => click_sync(e, id),
        else => false,
    };
}
fn click_none(e: *ui.Engine, id: i64) !bool {
    inline for (.{ "budget", "fixed", "accounts", "categories", "vendors", "special" }) |name| if (id == f.aid("pref-" ++ name)) {
        try open_preferences(e, @field(Section, name));
        return true;
    };
    if (id == f.aid("chart-fixed")) {
        include_planned = !include_planned;
        try f.switch_state(e, id, include_planned);
        try f.render(e);
        return true;
    }
    if (id == f.aid("bulk-apply") or id == f.aid("bulk-cancel")) return click_bulk(e, id);
    if (id == f.aid("bulk-preview-button")) {
        try bulk_preview(e);
        return true;
    }
    if (id == f.aid("bulk-only-other")) {
        bulk_only_other = !bulk_only_other;
        try f.switch_state(e, f.aid("bulk-only-other"), bulk_only_other);
        try f.status(e, if (bulk_only_other) "Only uncategorized" else "All matching categories");
        return true;
    }
    if (id == f.aid("bulk-remember")) {
        bulk_remember = !bulk_remember;
        try f.switch_state(e, f.aid("bulk-remember"), bulk_remember);
        try f.status(e, if (bulk_remember) "Keyword will be saved" else "Payments only");
        return true;
    }
    if (id == f.aid("export-report")) {
        var arena = std.heap.ArenaAllocator.init(e.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var rows: std.ArrayList(f.model.Expense) = .empty;
        for (f.s.snapshot.?.value.expenses) |row| if (f.insights_matches(e, row)) try rows.append(a, row);
        try f.invoke(e, .report, "export_report", .{ .html = try f.reports.html_report(a, rows.items, f.settings()) });
        return true;
    }
    if (id == f.aid("open-sync")) {
        try open(e, .sync);
        return true;
    }
    if (id == f.aid("open-scanner")) {
        try open(e, .scanner);
        return true;
    }
    if (id == f.aid("open-statements")) {
        try open(e, .statements);
        return true;
    }
    if (id == f.aid("open-fixed")) {
        try open(e, .fixed);
        return true;
    }
    if (id >= 14000000 and id < 14000000 + @as(i64, @intCast(special_rows.len)) * 16) {
        try f.open_editor(e, special_rows[@intCast(@divTrunc(id - 14000000, 16))]);
        return true;
    }
    if (id >= 360000 and id < 360000 + @as(i64, @intCast(f.settings().fixed_expenses_items.len)) * 16) {
        const index: usize = @intCast(@divTrunc(id - 360000, 16));
        var arena = std.heap.ArenaAllocator.init(e.gpa);
        defer arena.deinit();
        var ids: std.ArrayList([]const u8) = .empty;
        for (f.s.snapshot.?.value.expenses) |row| if (f.period(e).matches(row, f.settings()) and f.reports.special(row, f.settings()) == null and f.reports.fixed_item(row, f.settings()) == index) try ids.append(arena.allocator(), row.id);
        try f.drilldown(e, ids.items, try std.fmt.allocPrint(arena.allocator(), "Fixed: {s}", .{f.settings().fixed_expenses_items[index].name}));
        return true;
    }
    if (budget_rows.get(id - @mod(id, 16))) |name| {
        var arena = std.heap.ArenaAllocator.init(e.gpa);
        defer arena.deinit();
        var ids: std.ArrayList([]const u8) = .empty;
        for (f.s.snapshot.?.value.expenses) |row| if (f.period(e).matches(row, f.settings()) and is_variable(row) and std.mem.eql(u8, row.category, name)) try ids.append(arena.allocator(), row.id);
        try f.drilldown(e, ids.items, name);
        return true;
    }
    if (group_actions.get(id - @mod(id, 16))) |i| {
        const g = groups.items[i];
        var arena = std.heap.ArenaAllocator.init(e.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var ids: std.ArrayList([]const u8) = .empty;
        // Home's lists use its period; Insights rows use the Insights month range.
        const insight = switch (g.kind) {
            .variable_category, .variable_account, .merchant, .special, .comparison => true,
            else => false,
        };
        for (f.s.snapshot.?.value.expenses) |row| {
            var filter = f.period(e);
            if (g.kind == .month) filter.month = "";
            if (if (insight) !(f.insights_matches(e, row) and std.mem.eql(u8, row.currency, "CLP")) else !filter.matches(row, f.settings())) continue;
            const variable = f.reports.special(row, f.settings()) == null and f.reports.fixed_item(row, f.settings()) == null and !std.mem.startsWith(u8, row.category, "Fixed:");
            const matches = switch (g.kind) {
                .category => f.reports.category_matches(g.name, row, f.settings()),
                .variable_category => variable and std.mem.eql(u8, row.category, g.name),
                .account => std.mem.eql(u8, try f.reports.account_label(a, row.account, f.settings()), g.name),
                .variable_account => variable and std.mem.eql(u8, try f.reports.account_label(a, row.account, f.settings()), g.name),
                .merchant => std.mem.eql(u8, try f.reports.merchant(a, row.payee, f.settings(), !std.mem.eql(u8, f.value(e, f.aid("merchant-grouping")), "exact")), g.name),
                .month => std.mem.startsWith(u8, row.date, g.name),
                .special => if (f.reports.special(row, f.settings())) |label| std.mem.eql(u8, label, g.name) else false,
                .comparison => variable and std.mem.eql(u8, g.category, row.category) and (std.mem.eql(u8, g.account, "All accounts") or std.mem.eql(u8, g.account, try f.reports.account_label(a, row.account, f.settings()))),
                else => false,
            };
            if (matches) try ids.append(a, row.id);
        }
        if (g.kind == .month) try f.set_value(e, f.aid("month"), g.name);
        try f.drilldown(e, ids.items, g.name);
        return true;
    }
    return false;
}
fn click_bulk(e: *ui.Engine, id: i64) !bool {
    if (id == f.aid("bulk-cancel")) {
        bulk_edit = null;
        try render_bulk(e);
        return true;
    }
    if (id == f.aid("bulk-apply") and !f.s.busy) {
        f.s.busy = true;
        bulk_saving = true;
        errdefer bulk_saving = false;
        try f.invoke(e, .settings, "save_budget", bulk_edit orelse return error.NoBulkPreview);
        return true;
    }

    return false;
}
fn click_preferences(e: *ui.Engine, id: i64) !bool {
    if (id == pid("close-preferences")) {
        try f.request_close(e);
        return true;
    }
    if (id == pid("save-preferences")) {
        try save_preferences(e);
        return true;
    }
    inline for (.{ "add-fixed", "add-account", "add-category", "add-vendor", "add-special" }) |name| if (id == pid(name)) {
        try mapping(e, "", "", 0);
        try mapping_kids(e);
        f.s.dirty = true;
        return true;
    };
    if (id >= mapping_base and id < mapping_base + 1000 * mapping_stride and @mod(id - mapping_base, mapping_stride) == Mapping.id("remove", 0)) {
        try f.show(e, id - @mod(id - mapping_base, mapping_stride), false);
        f.s.dirty = true;
        return true;
    }

    return false;
}
fn click_fixed(e: *ui.Engine, id: i64) !bool {
    if (id >= 610000 and id < 610000 + @as(i64, @intCast(f.settings().fixed_expenses_items.len)) * 16) {
        const index: usize = @intCast(@divTrunc(id - 610000, 16));
        var arena = std.heap.ArenaAllocator.init(e.gpa);
        defer arena.deinit();
        var ids: std.ArrayList([]const u8) = .empty;
        for (f.s.snapshot.?.value.expenses) |row| if (f.period(e).matches(row, f.settings()) and f.reports.special(row, f.settings()) == null and f.reports.fixed_item(row, f.settings()) == index) try ids.append(arena.allocator(), row.id);
        if (ids.items.len > 0) {
            try f.close_modal(e);
            try f.drilldown(e, ids.items, try std.fmt.allocPrint(arena.allocator(), "Fixed: {s}", .{f.settings().fixed_expenses_items[index].name}));
        }
        return true;
    }
    if (id == Fixed.id("close-fixed", 12000)) {
        try f.close_modal(e);
        return true;
    }
    if (id == Fixed.id("edit-fixed", 12000)) {
        try f.close_modal(e);
        try open_preferences(e, .fixed);
        return true;
    }

    return false;
}
fn render_bank_choice(e: *ui.Engine) !void {
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const bank = statement_bank;
    try f.set_text(e, Statements.id("bank-import-title", 13000), bank.name());
    try f.set_text(e, Statements.id("bank-import-description", 13000), if (bank == .santander) "Import this month’s card charges" else if (bank == .boa) "Import this month’s card or account charges in USD" else "Import this month’s card or account charges");
    try f.set_text(e, Statements.id("bank-import-help", 13000), try std.fmt.allocPrint(arena.allocator(), "Choose the same card or account you’ll open at {s}.", .{bank.name()}));
    try f.set_text(e, Statements.id("bank-import-steps", 13000), switch (bank) {
        .bci => "1  Sign in    ·    2  Download PDF    ·    3  Review new charges",
        .boa => "1  Sign in    ·    2  Download CSV    ·    3  Review new charges",
        .santander => "1  Sign in    ·    2  Choose card    ·    3  Review new charges",
    });
    try f.set_text(e, Statements.id("bank-connect-label", 13000), try std.fmt.allocPrint(arena.allocator(), "Open {s}", .{bank.name()}));
    try f.set_text(e, Statements.id("bank-santander-label", 13000), if (bank == .santander) "✓ Santander" else "Santander");
    try f.set_text(e, Statements.id("bank-bci-label", 13000), if (bank == .bci) "✓ BCI" else "BCI");
    try f.set_text(e, Statements.id("bank-boa-label", 13000), if (bank == .boa) "✓ Bank of America" else "Bank of America");
}

fn click_statements(e: *ui.Engine, id: i64) !bool {
    if (id == Statements.id("bank-add-account", 13000)) {
        if (f.s.busy) return true;
        var name: [120]u8 = undefined;
        const account = f.value(e, Statements.id("santander-account", 13000));
        try f.model.text(account, name.len, true);
        @memcpy(name[0..account.len], account);
        // Preserve the bank sheet while the account editor owns the overlay,
        // just as the receipt scanner preserves the payment editor.
        e.tree.get(13000).?.stamp_owned = false;
        try f.close_modal(e);
        try open_preferences(e, .accounts);
        f.s.return_to_statements = true;
        const already_configured = original.cards_config == .object and original.cards_config.object.contains(name[0..account.len]);
        try mapping(e, if (already_configured) "" else name[0..account.len], "", 0);
        try mapping_kids(e);
        f.s.dirty = true;
        return true;
    }
    if (id == Statements.id("bank-santander", 13000) or id == Statements.id("bank-bci", 13000) or id == Statements.id("bank-boa", 13000)) {
        if (f.s.busy) return true;
        const bank: statements.Bank = if (id == Statements.id("bank-bci", 13000)) .bci else if (id == Statements.id("bank-boa", 13000)) .boa else .santander;
        if (bank != statement_bank) {
            statement_bank = bank;
            try f.set_value(e, Statements.id("santander-account", 13000), "");
            try f.set_text(e, Statements.id("statement-status", 13000), "");
            try render_bank_choice(e);
        }
        return true;
    }
    if (id == Statements.id("santander-connect", 13000)) {
        if (f.s.busy or !f.s.snapshot.?.value.santander_available) return true;
        const account = std.mem.trim(u8, f.value(e, Statements.id("santander-account", 13000)), " \\t\\r\\n");
        if (account.len == 0) {
            try f.set_text(e, Statements.id("statement-status", 13000), "Choose the bank card or account first.");
            return true;
        }
        f.s.busy = true;
        try f.set_text(e, Statements.id("statement-status", 13000), switch (statement_bank) {
            .bci => "Sign in to BCI, then download the card or account’s movements PDF in the bank window.",
            .boa => "Sign in to Bank of America, then download the card or account’s activity CSV in the bank window.",
            .santander => "Sign in in the Santander window, then open card movements. Close it to cancel.",
        });
        try f.invoke(e, .bank_import, statement_bank.command(), .{ .account = account });
        return true;
    }
    if (id == Statements.id("close-statements", 13000)) {
        try f.close_modal(e);
        return true;
    }
    if (id == Statements.id("statement-file", 13000) and !f.s.busy) {
        f.s.busy = true;
        try f.invoke(e, .pick_pdf, "ui_pick_file", .{ .kind = "pdf" });
        return true;
    }
    if (id >= 420000 and id < 436000) {
        const i: usize = @intCast(@divTrunc(id - 420000, 16));
        if (i < f.s.snapshot.?.value.statements.len) {
            const source = f.s.snapshot.?.value.statements[i];
            if (id == StatementSource.id("secondary", 420000 + @as(i64, @intCast(i)) * 16)) {
                try f.invoke(e, .export_pdf, "export_statement", .{ .hash = source.hash });
                return true;
            }
            if (id != StatementSource.id("action", 420000 + @as(i64, @intCast(i)) * 16)) return false;
            if (e.tree.get(id).?.props.dis) return true;
            try open_statement(e, source.hash, std.mem.eql(u8, source.status, "queued"));
        }
        return true;
    }

    return false;
}
fn apply_reviewed_through(e: *ui.Engine) !void {
    const through = f.value(e, Statement.id("reviewed-through", 14000));
    if (!f.model.valid_date(through)) return error.InvalidDate;
    var count: usize = 0;
    for (observations, 0..) |obs, i| {
        if (obs.expense_id != null or obs.ignored or std.mem.order(u8, obs.source.date, through) == .gt) continue;
        const base = review_base + @as(i64, @intCast(i)) * review_stride;
        try f.set_value(e, Review.id("choice", base), if (obs.match) |match| match.id else "ignore");
        try f.show(e, Review.id("review-row", base), show_reviewed_observations);
        count += 1;
    }
    try f.set_text(e, Statement.id("statement-review-status", 14000), try std.fmt.allocPrint(modal_arena.allocator(), "{d} older rows marked · Confirm to save choices", .{count}));
}
fn click_statement(e: *ui.Engine, id: i64) !bool {
    if (id == Statement.id("apply-reviewed-through", 14000) and !f.s.busy) {
        try apply_reviewed_through(e);
        return true;
    }
    if (id == Statement.id("toggle-reviewed", 14000) and !f.s.busy) {
        show_reviewed_observations = !show_reviewed_observations;
        for (observations, 0..) |obs, i| {
            const base = review_base + @as(i64, @intCast(i)) * review_stride;
            try f.show(e, Review.id("review-row", base), show_reviewed_observations or (obs.expense_id == null and !obs.ignored and obs.match == null));
        }
        try f.set_text(e, Statement.id("toggle-reviewed", 14000), if (show_reviewed_observations) "Hide handled payments" else "Show handled payments");
        return true;
    }
    if (id >= review_base and id < review_base + @as(i64, @intCast(observations.len)) * review_stride and !f.s.busy) {
        const i: usize = @intCast(@divTrunc(id - review_base, review_stride));
        if (i < observations.len and id == Review.id("undo", review_base + @as(i64, @intCast(i)) * review_stride)) {
            const obs = observations[i];
            f.s.busy = true;
            try f.invoke(e, .unlink, "unlink_observation", .{ .id = obs.id, .expected_expense = obs.expense_id });
            return true;
        }
    }
    if (id == Statement.id("close-statement", 14000)) {
        try f.request_close(e);
        return true;
    }
    if (id == Statement.id("confirm-statement", 14000) and !f.s.busy) {
        try reconcile(e);
        return true;
    }

    return false;
}
fn ask_scanner_delete(e: *ui.Engine, id: []const u8, label: []const u8, mb: u32) !void {
    if (id.len > delete_model_buf.len) return error.UnknownModel;
    @memcpy(delete_model_buf[0..id.len], id);
    delete_model_len = id.len;
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const message = if (mb > 0) try std.fmt.allocPrint(a, "Delete {s} ({s})?", .{ label, try megabytes(a, mb) }) else "Delete your loaded model files?";
    try f.confirm_editor(e, .scanner_delete, message, "Delete");
}

pub fn confirm_scanner_delete(e: *ui.Engine) !void {
    if (delete_model_len == 0) return;
    f.s.busy = true;
    try f.invoke(e, .scanner_action, "scanner_delete", .{ .id = delete_model_buf[0..delete_model_len] });
    delete_model_len = 0;
}

pub fn scanner_ready() bool {
    return scanner != null and scanner.?.active.len > 0;
}

fn click_scanner(e: *ui.Engine, id: i64) !bool {
    if (id == scid("close-scanner")) {
        try f.close_modal(e);
        return true;
    }
    if (id >= 480000 and id < 481600 and scanner != null and (!f.s.busy or scanner.?.downloading.len > 0)) {
        const i: usize = @intCast(@divTrunc(id - 480000, 16));
        if (i >= scanner.?.models.len) return false;
        const base = 480000 + @as(i64, @intCast(i)) * 16;
        if (id != ScanRow.id("action", base) and id != ScanRow.id("secondary", base)) return false;
        const m = scanner.?.models[i];
        if (id == ScanRow.id("secondary", base)) {
            try ask_scanner_delete(e, m.id, m.label, m.mb);
        } else if (std.mem.eql(u8, scanner.?.downloading, m.id)) {
            try f.invoke(e, .scanner_action, "scanner_cancel_download", .{});
        } else if (m.installed) {
            f.s.busy = true;
            try f.invoke(e, .scanner_action, "scanner_select", .{ .id = m.id });
        } else {
            if (scanner.?.downloading.len > 0 or !scanner.?.vision_built) return true;
            @memcpy(download_id_buf[0..m.id.len], m.id);
            download_id_len = m.id.len;
            download_done = m.partial_mb;
            download_total = m.mb;
            auto_select_download = scanner.?.selected.len == 0;
            var message: [200]u8 = undefined;
            try progress.task(e, .download, try std.fmt.bufPrint(&message, "Downloading {s}", .{m.label}), @as(f64, @floatFromInt(m.partial_mb)) / @as(f64, @floatFromInt(m.mb)));
            try f.invoke(e, .scanner_download, "scanner_download", .{ .id = m.id });
        }
        return true;
    }
    if ((id == scid("model") or id == scid("projector")) and !f.s.busy) {
        f.s.busy = true;
        try f.invoke(e, .scanner_action, "pick_model", .{ .projector = id == scid("projector") });
        return true;
    }
    if (id == ScanRow.id("action", 492000) or id == ScanRow.id("secondary", 492000)) {
        if (id == ScanRow.id("secondary", 492000)) try ask_scanner_delete(e, "custom", "your loaded model files", 0) else try f.invoke(e, .scanner_action, "scanner_select", .{ .id = "custom" });
        return true;
    }
    if (id == ScanRow.id("action", 494000)) {
        if (scanner) |state| {
            if (std.mem.eql(u8, state.system.state, "available")) try f.invoke(e, .scanner_action, "scanner_select", .{ .id = "system" }) else try f.invoke(e, .scanner_action, "scanner_system_download", .{});
        }
        return true;
    }
    if (id == scid("scanner-fast") and scanner != null) {
        try f.invoke(e, .scanner_action, "scanner_fast", .{ .enabled = !scanner.?.fast });
        return true;
    }
    if (id == scid("scanner-gpu") and scanner != null) {
        try f.invoke(e, .scanner_action, "scanner_gpu", .{ .enabled = !scanner.?.use_gpu });
        return true;
    }

    return false;
}
fn click_sync(e: *ui.Engine, id: i64) !bool {
    if (id == sid("sync-link-details-toggle")) {
        try f.disclosure(e, id, sid("sync-link-details-body"), "Pairing link");
        return true;
    }
    if (id == sid("sync-service-toggle")) {
        try f.disclosure(e, id, sid("sync-service-body"), "Service");
        return true;
    }
    if (id == sid("sync-paste-toggle")) {
        try f.disclosure(e, id, sid("sync-paste-body"), "Paste link instead");
        return true;
    }
    if (id == sid("close-sync")) {
        try f.close_modal(e);
        return true;
    }
    inline for (.{ "start", "stop", "restart", "pairing", "now", "unpair", "scan", "connect" }) |action| if (id == sid("sync-" ++ action)) {
        try sync_action(e, if (std.mem.eql(u8, action, "now")) "sync_now" else if (std.mem.eql(u8, action, "scan")) "scan_pair" else if (std.mem.eql(u8, action, "connect")) "pair_link" else action, "");
        return true;
    };
    if (id == sid("sync-replace")) {
        replace_desktop = !replace_desktop;
        try f.switch_state(e, sid("sync-replace"), replace_desktop);
        return true;
    }
    if (id >= 500000 and id < 516000 and !f.s.busy) {
        const i: usize = @intCast(@divTrunc(id - 500000, 16));
        if (core != null and i < core.?.conflicts.len) {
            const c = core.?.conflicts[i];
            try f.invoke(e, .sync_conflict, "sync_conflict", .{ .kind = c.kind, .id = c.id });
        }
        return true;
    }
    if ((id == sid("sync-use-local") or id == sid("sync-use-remote")) and !f.s.busy) {
        if (e.tree.get(id).?.props.dis) return true;
        if (conflict) |c| {
            f.s.busy = true;
            try f.invoke(e, .sync_resolve, "sync_resolve", .{ .kind = c.kind, .id = c.id, .keep_local = id == sid("sync-use-local") });
        }
        return true;
    }
    if (id >= 520000 and id < 536000) {
        const i: usize = @intCast(@divTrunc(id - 520000, 16));
        if (i < devices.len and !devices[i].revoked and id == SyncDevice.id("disconnect", 520000 + @as(i64, @intCast(i)) * 16)) try sync_action(e, "revoke", devices[i].id);
        return true;
    }

    return false;
}
fn decoded(a: std.mem.Allocator, json: []const u8) ![]const u8 {
    return std.json.parseFromSliceLeaky([]const u8, a, json, .{ .allocate = .alloc_always });
}
pub fn resolved(e: *ui.Engine, request: f.Request, ok: bool, json: []const u8) !void {
    if (!ok) {
        if (request == .settings) bulk_saving = false;
        if (request == .scanner_download) {
            download_id_len = 0;
            download_total = 0;
        }
        if (request == .background_parse) parser_busy = false;
        f.finish(request);
        const target = switch (f.s.modal) {
            .preferences => pid("preferences-status"),
            .scanner => scid("model-status"),
            .statement => Statement.id("statement-review-status", 14000),
            .statements => Statements.id("statement-status", 13000),
            .sync => sid("sync-message"),
            else => f.aid("status"),
        };
        try f.report_error(e, target, json);
        return;
    }
    switch (request) {
        .background_parse => try resolved_background_parse(e, request, json),
        .export_pdf => try resolved_export_pdf(e, request, json),
        .report => try resolved_report(e, request, json),
        .settings, .reconcile => try resolved_settings(e, request, json),
        .pick_pdf => try resolved_pick_pdf(e, request, json),
        .bank_import => {
            f.finish(request);
            const result = try std.json.parseFromSliceLeaky(statements.BankImport, modal_arena.allocator(), json, .{ .allocate = .alloc_always });
            if (result.hash) |hash| {
                current_hash = hash;
                try f.refresh(e);
                try f.invoke(e, .observations, "statement_observations", .{ .hash = hash });
            } else {
                try f.set_text(e, Statements.id("statement-status", 13000), "No new charges in the current month.");
            }
        },
        .stage_pdf => try resolved_stage_pdf(e, request, json),
        .parse_pdf => try resolved_parse_pdf(e, request, json),
        .observations => try resolved_observations(e, request, json),
        .scanner_status => try resolved_scanner_status(e, request, json),
        .scanner_action => try resolved_scanner_action(e, request, json),
        .scanner_download => {
            if (auto_select_download and download_id_len > 0) {
                try f.invoke(e, .scanner_action, "scanner_select", .{ .id = download_id_buf[0..download_id_len] });
            }
            download_id_len = 0;
            download_total = 0;
            try f.invoke(e, .scanner_status, "scanner_status", .{});
        },
        .sync_status => try resolved_sync_status(e, request, json),
        .sync_transport, .sync_action => try resolved_sync_transport(e, request, json),
        .sync_conflict => try resolved_sync_conflict(e, request, json),
        .sync_resolve => try resolved_sync_resolve(e, request, json),
        else => {},
    }
    try f.overlay(e);
    f.redraw(e);
}
fn resolved_background_parse(e: *ui.Engine, _: f.Request, _: []const u8) !void {
    parser_busy = false;
    try f.refresh(e);
}
fn resolved_export_pdf(e: *ui.Engine, _: f.Request, json: []const u8) !void {
    try f.status(e, if (std.mem.eql(u8, json, "true")) "PDF saved" else "Cancelled");
}
fn resolved_report(e: *ui.Engine, _: f.Request, json: []const u8) !void {
    try f.status(e, if (std.mem.eql(u8, json, "true")) "Report saved" else "Cancelled");
}
fn resolved_settings(e: *ui.Engine, request: f.Request, _: []const u8) !void {
    f.finish(request);
    if (f.s.return_to_statements and section == .accounts and mapping_count > 0) {
        const base = mapping_base + @as(i64, @intCast(mapping_count - 1)) * mapping_stride;
        if (!e.tree.get(base).?.props.none) try f.set_value(e, Statements.id("santander-account", 13000), f.value(e, Mapping.id("key", base)));
    }
    if (bulk_saving) {
        bulk_saving = false;
        bulk_edit = null;
        try render_bulk(e);
    }
    if (f.s.modal != .none) try f.close_modal(e);
    try f.refresh(e);
}
fn resolved_pick_pdf(e: *ui.Engine, request: f.Request, json: []const u8) !void {
    var temporary = std.heap.ArenaAllocator.init(e.gpa);
    defer temporary.deinit();
    const a = temporary.allocator();
    f.finish(request);
    const file = try std.json.parseFromSliceLeaky(?@import("main.zig").UiFile, a, json, .{ .allocate = .alloc_always });
    if (file) |v| {
        f.s.busy = true;
        try f.invoke(e, .stage_pdf, "prepare_statement", .{ .name = v.name, .data_url = v.data_url });
    }
}
fn resolved_stage_pdf(e: *ui.Engine, request: f.Request, json: []const u8) !void {
    const a = modal_arena.allocator();
    f.finish(request);
    current_hash = try decoded(a, json);
    if (!oriel.target.is_android) {
        f.s.busy = true;
        try f.invoke(e, .parse_pdf, "parse_statement", .{ .hash = current_hash });
    } else try f.refresh(e);
}
fn resolved_parse_pdf(e: *ui.Engine, request: f.Request, _: []const u8) !void {
    f.finish(request);
    try f.refresh(e);
    try f.invoke(e, .observations, "statement_observations", .{ .hash = current_hash });
}
fn resolved_observations(e: *ui.Engine, _: f.Request, json: []const u8) !void {
    if ((f.s.modal != .statements and f.s.modal != .statement) or current_hash.len == 0) return;
    const a = modal_arena.allocator();
    const hash = try e.gpa.dupe(u8, current_hash);
    defer e.gpa.free(hash);
    reset_modal();
    current_hash = try a.dupe(u8, hash);
    observations = try std.json.parseFromSliceLeaky([]statements.Observation, a, json, .{ .allocate = .alloc_always });
    try render_observations(e);
}
fn resolved_scanner_status(e: *ui.Engine, _: f.Request, json: []const u8) !void {
    scanner = null;
    _ = scanner_arena.reset(.retain_capacity);
    const sa = scanner_arena.allocator();
    scanner = try std.json.parseFromSliceLeaky(Scanner.Status, sa, try decoded(sa, json), .{ .allocate = .alloc_always });
    if (f.s.modal == .scanner) try scanner_render(e);
}
fn resolved_scanner_action(e: *ui.Engine, request: f.Request, _: []const u8) !void {
    f.finish(request);
    try f.invoke(e, .scanner_status, "scanner_status", .{});
}
fn resolved_sync_status(e: *ui.Engine, _: f.Request, json: []const u8) !void {
    core = null;
    _ = core_arena.reset(.retain_capacity);
    const ca = core_arena.allocator();
    core = try std.json.parseFromSliceLeaky(sync_resolution.Status, ca, try decoded(ca, json), .{ .allocate = .alloc_always });
    if (f.s.modal != .sync) return;
    try sync_summary(e);
    var ids: std.ArrayList(i64) = .empty;
    for (core.?.conflicts, 0..) |c, i| {
        const base = 500000 + @as(i64, @intCast(i)) * 16;
        const label = try std.fmt.allocPrint(ca, "Review {s}", .{@tagName(c.kind)});
        _ = try SyncConflict.mount(&e.tree, base, 79910, &.{.{ .name = "text", .value = label }});
        try f.mark_action(e, base, label);
        try ids.append(ca, base);
    }
    if (ids.items.len == 0) {
        if (!try e.tree.stampKids(sid("sync-conflicts"), &.{})) return error.InvalidTemplate;
        try f.set_text(e, sid("sync-conflicts"), "None");
    } else if (!try e.tree.stampKids(sid("sync-conflicts"), ids.items)) return error.InvalidTemplate;
}
fn resolved_sync_transport(e: *ui.Engine, request: f.Request, json: []const u8) !void {
    if (request == .sync_action) f.finish(request);
    devices = &.{};
    _ = transport_arena.reset(.retain_capacity);
    const ta = transport_arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, ta, try decoded(ta, json), .{ .allocate = .alloc_always });
    if (v != .object) return;
    if (v.object.get("error")) |err| {
        if (err == .string and err.string.len > 0) {
            try f.status(e, err.string);
            return;
        }
    }
    if (f.s.modal != .sync) return;
    if (v.object.get("link")) |link| {
        try f.set_value(e, sid("sync-link"), link.string);
        try f.show(e, sid("sync-code"), true);
        if (v.object.get("qr")) |qr| {
            try f.set_image(e, sid("sync-qr"), qr.string);
        }
        if (v.object.get("expires")) |expires| if (expires == .integer) {
            pair_expires = expires.integer;
        };
    }
    if (v.object.get("endpoints")) |endpoints| if (endpoints == .array) {
        var routes: std.ArrayList([]const u8) = .empty;
        for (endpoints.array.items) |endpoint| if (endpoint == .string) try routes.append(ta, endpoint.string);
        try f.set_text(e, sid("sync-routes"), try std.mem.join(ta, "\n", routes.items));
    };
    if (v.object.get("running")) |running| if (running == .bool) {
        connection_state = if (running.bool) "Ready for phones" else "Service stopped";
    };
    if (v.object.get("paired")) |paired| if (paired == .bool) {
        const connected = if (v.object.get("connected")) |c| c == .bool and c.bool else false;
        connection_state = if (!paired.bool) "Not paired" else if (connected) "Connected" else "Waiting for desktop";
    };
    try sync_summary(e);
    if (v.object.get("devices")) |list| {
        const bytes = try std.json.Stringify.valueAlloc(ta, list, .{});
        devices = try std.json.parseFromSliceLeaky([]Device, ta, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        var ids: std.ArrayList(i64) = .empty;
        for (devices, 0..) |d, i| {
            const base = 520000 + @as(i64, @intCast(i)) * 16;
            const title = try std.fmt.allocPrint(ta, "{s}{s}", .{ d.label, if (d.revoked) " · disconnected" else "" });
            _ = try SyncDevice.mount(&e.tree, base, 79900, &.{.{ .name = "title", .value = title }});
            try f.show(e, SyncDevice.id("disconnect", base), !d.revoked);
            try f.mark_actions(e, SyncDevice, base, .{"disconnect"});
            try ids.append(ta, base);
        }
        if (!try e.tree.stampKids(sid("sync-devices"), ids.items)) return error.InvalidTemplate;
    }
    if (request == .sync_action) {
        const cancelled = if (v.object.get("cancelled")) |c| c == .bool and c.bool else false;
        if (v.object.get("paired")) |paired| if (paired == .bool and paired.bool and !cancelled) {
            try f.set_value(e, sid("sync-paste"), "");
            replace_desktop = false;
            try f.switch_state(e, sid("sync-replace"), false);
        };
        if (cancelled) try f.set_text(e, sid("sync-message"), "Cancelled");
        try refresh_sync(e);
        try f.refresh(e);
    }
}
fn resolved_sync_conflict(e: *ui.Engine, _: f.Request, json: []const u8) !void {
    if (f.s.modal != .sync) return;
    reset_modal();
    const a = modal_arena.allocator();
    conflict = try std.json.parseFromSliceLeaky(sync_types.Conflict, a, try decoded(a, json), .{ .allocate = .alloc_always });
    const local = try std.json.parseFromSliceLeaky(std.json.Value, a, conflict.?.local_payload, .{ .allocate = .alloc_always });
    const remote = try std.json.parseFromSliceLeaky(std.json.Value, a, conflict.?.remote_payload, .{ .allocate = .alloc_always });
    try f.set_text(e, sid("sync-local"), try std.json.Stringify.valueAlloc(a, local, .{ .whitespace = .indent_2 }));
    try f.set_text(e, sid("sync-remote"), try std.json.Stringify.valueAlloc(a, remote, .{ .whitespace = .indent_2 }));
    var deleted = false;
    if (remote == .object) if (remote.object.get("expense")) |expense| if (expense == .object) if (expense.object.get("deleted")) |v| {
        deleted = v == .bool and v.bool;
    };
    var props = e.tree.get(sid("sync-use-local")).?.props;
    props.dis = deleted or conflict.?.kind == .document or std.mem.eql(u8, conflict.?.reason, "EvidenceConflict") or std.mem.eql(u8, conflict.?.reason, "ImmutableSourceConflict");
    props.op = if (props.dis) 0.38 else 1;
    try e.tree.updateUiProps(sid("sync-use-local"), props);
    try f.show(e, sid("sync-review"), true);
}
fn resolved_sync_resolve(e: *ui.Engine, request: f.Request, _: []const u8) !void {
    f.finish(request);
    conflict = null;
    try f.show(e, sid("sync-review"), false);
    try refresh_sync(e);
    try f.refresh(e);
}

pub fn download_progress(e: *ui.Engine, v: std.json.Value) !void {
    if (v != .object) return;
    const parsed = try std.json.parseFromValue(Scanner.DownloadEvent, e.gpa, v, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const event = parsed.value;
    if (event.id.len > download_id_buf.len) return error.UnknownModel;
    @memcpy(download_id_buf[0..event.id.len], event.id);
    download_id_len = event.id.len;
    download_done = event.done_mb;
    download_total = event.total_mb;
    if (std.mem.eql(u8, event.state, "downloading") and event.total_mb > 0) {
        var message: [200]u8 = undefined;
        var label: []const u8 = "model";
        if (scanner) |state| for (state.models) |m| if (std.mem.eql(u8, event.id, m.id)) {
            label = m.label;
            break;
        };
        try progress.task(e, .download, try std.fmt.bufPrint(&message, "Downloading {s} · {d} MB of {d} MB", .{ label, event.done_mb, event.total_mb }), @as(f64, @floatFromInt(event.done_mb)) / @as(f64, @floatFromInt(event.total_mb)));
    }
    if (f.s.modal == .scanner) try scanner_render(e);
}

pub fn statement_unlinked(e: *ui.Engine, ok: bool, json: []const u8) !void {
    f.finish(.unlink);
    if (!ok) {
        try f.status(e, json);
        return;
    }
    try f.invoke(e, .observations, "statement_observations", .{ .hash = current_hash });
    try f.refresh(e);
}
