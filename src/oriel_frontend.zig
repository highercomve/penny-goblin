//! Compiled .oriel application. All financial writes use the existing command pool.
const std = @import("std");
const oriel = @import("oriel");
pub const ui = oriel.ui;
pub const reports = @import("core/reporting.zig");
pub const model = @import("core/model.zig");
const app = @import("main.zig");
const tools = @import("oriel_tools.zig");
const progress = @import("oriel_progress.zig");
const research = @import("oriel_research.zig");
const categories = @import("oriel_categories.zig");
const suggestions = @import("oriel_suggestions.zig");
const errors = @import("ui_errors.zig");
const App = ui.View(@embedFile("application.oriel"));
const Payment = ui.View(@embedFile("payment.oriel"));
const BudgetPart = ui.View(@embedFile("budget-part.oriel"));
const Day = ui.View(@embedFile("day.oriel"));
pub const Editor = ui.View(@embedFile("editor.oriel"));
pub const Item = ui.View(@embedFile("item.oriel"));
pub const Evidence = ui.View(@embedFile("evidence.oriel"));
const Backdrop = ui.View(@embedFile("backdrop.oriel"));
const Notice = ui.View(@embedFile("notice.oriel"));
const StatementEvidence = ui.View(@embedFile("statement-evidence.oriel"));
const EvidencePanel = ui.View(@embedFile("evidence-panel.oriel"));
const Text = ui.View(@embedFile("text.oriel"));
pub const editor_base: i64 = 10000;
pub const item_style: i64 = 70000;
pub const Page = enum { home, payments, insights, settings };
pub const Modal = enum { none, editor, preferences, fixed, statements, statement, scanner, sync, research };
pub const Request = enum(u32) { snapshot = 1, save, delete, new_id, pick_image, scan, documents, pick_legacy, import_legacy, pick_pdf, stage_pdf, parse_pdf, observations, reconcile, export_pdf, settings, scanner_status, scanner_action, sync_status, sync_transport, sync_action, sync_conflict, sync_resolve, report, quick_action, cancel, sources, background_parse, unlink, defaults, scanner_download, research_run, research_apply, research_source, research_model_status, research_model_action, category_edit, bank_import };
const input_names = .{ "month", "account-filter", "search", "category-filter", "date-from", "date-through", "ledger-sort", "merchant-search", "merchant-category", "merchant-grouping", "merchant-sort", "comparison-mode", "insights-from", "insights-to", "insights-year", "category-measure" };
pub const State = struct {
    io: std.Io = undefined,
    initialized: bool = false,
    snackbar_until: i64 = 0,
    variant: usize = 0,
    page: Page = .home,
    modal: Modal = .none,
    snapshot: ?std.json.Parsed(app.Snapshot) = null,
    settings: ?std.json.Parsed(reports.Settings) = null,
    refreshing: bool = false,
    busy: bool = false,
    busy_owner: ?Request = null,
    dirty: bool = false,
    confirm_discard: bool = false,
    drill_name: ?[]u8 = null,
    drill_ids: std.StringHashMapUnmanaged(void) = .empty,
    drill_active: bool = false,
    /// The page a drill-down was opened from; Back and its chip return there.
    drill_from: ?Page = null,
    return_to_editor: bool = false,
    return_to_statements: bool = false,
    editor_dirty: bool = false,
    inputs: [input_names.len][512]u8 = undefined,
    input_lens: [input_names.len]usize = @splat(0),
    actions: std.ArrayList(i64) = .empty,
    /// Controls outside the open modal, out of Tab's reach, with the
    /// tabindex each had before (modal_focus).
    inert: std.AutoHashMapUnmanaged(i64, ?i32) = .empty,
    selected: std.ArrayList(model.Expense) = .empty,
    draft: std.heap.ArenaAllocator = undefined,
    current: ?model.Expense = null,
    document: ?model.Document = null,
    /// The picked image's file name, which dates a voucher that prints none.
    document_name: []const u8 = "",
    rows: usize = 0,
    document_count: usize = 0,
    range_open: bool = false,
    bulk_open: bool = false,
    initialized_period: bool = false,
    initialized_insights: bool = false,
    editor_generation: u16 = 0,
    sources: ?std.json.Parsed([]@import("core/statements.zig").PaymentSource) = null,
    notice_open: bool = false,
    scan_first: bool = false,
    scan_cancelled: bool = false,
    details_open: bool = true,
    extraction_open: bool = false,
    scan_fill: bool = false,
    confirm_action: enum { discard, replace_image, rescan, scanner_delete, category_budget } = .discard,
    pending_camera: bool = false,
};
pub var s: State = .{};
const desktop = @import("oriel_desktop.zig");
const recovery = @import("oriel_recovery.zig");
pub fn configure(io: std.Io) void {
    s = .{ .io = io };
    recovery.reset();
    ui.configure(.{ .boot = boot, .event = event, .resolved = resolved_safe, .resized = resized, .timer = timer, .shutdown = shutdown });
}
pub fn aid(comptime name: []const u8) i64 {
    return App.id(name, 1000);
}
pub fn eid(comptime name: []const u8) i64 {
    return Editor.id(name, editor_base);
}
pub fn settings() reports.Settings {
    return if (s.settings) |v| v.value else .{};
}
pub fn invoke(e: *ui.Engine, request: Request, command: []const u8, args: anytype) !void {
    switch (request) {
        .save, .delete, .new_id, .pick_image, .scan, .pick_legacy, .import_legacy, .pick_pdf, .stage_pdf, .parse_pdf, .reconcile, .settings, .scanner_action, .sync_action, .sync_resolve, .unlink, .research_run, .research_apply, .bank_import => {
            if (s.busy) s.busy_owner = request;
        },
        else => {},
    }
    errdefer if (s.busy_owner == request) {
        s.busy = false;
        s.busy_owner = null;
    };
    switch (request) {
        .save, .new_id => try progress.task(e, .save, if (s.document != null) "Saving payment and voucher" else "Saving payment", null),
        .delete => try progress.task(e, .delete, "Deleting payment", null),
        .settings => try progress.task(e, .settings, "Saving settings", null),
        .import_legacy => try progress.task(e, .legacy, "Importing web export", null),
        .stage_pdf => try progress.task(e, .statement, "Saving statement", null),
        .parse_pdf => try progress.task(e, .statement, "Parsing statement", null),
        .report => try progress.task(e, .report, "Exporting report", null),
        .export_pdf => try progress.task(e, .report, "Saving source", null),
        else => {},
    }
    errdefer progress.resolved(e, request) catch {};
    const generation: u32 = if (request == .documents or request == .sources or request == .defaults) @as(u32, s.editor_generation) << 16 else 0;
    try ui.invoke(e, @intFromEnum(request) | generation, command, args);
}
pub fn finish(request: Request) void {
    if (s.busy_owner == request) {
        s.busy = false;
        s.busy_owner = null;
    }
}
pub fn value(e: *ui.Engine, id: i64) []const u8 {
    return if (e.tree.get(id)) |n| n.props.val orelse "" else "";
}
pub fn set_value(e: *ui.Engine, id: i64, text: []const u8) !void {
    const n = e.tree.get(id) orelse return error.UnknownNode;
    if (text.len > 2048) try e.tree.reserveUiProps(id, 64 * 1024);
    var p = n.props;
    p.val = text;
    try e.tree.updateUiProps(id, p);
}
pub fn show(e: *ui.Engine, id: i64, on: bool) !void {
    const n = e.tree.get(id) orelse return error.UnknownNode;
    var p = n.props;
    p.none = !on;
    try e.tree.updateUiProps(id, p);
}
pub fn set_text(e: *ui.Engine, id: i64, text: []const u8) !void {
    const n = e.tree.get(id) orelse return error.UnknownNode;
    var queue: [512]*ui.Node = undefined;
    queue[0] = n;
    var at: usize = 0;
    var len: usize = 1;
    while (at < len) : (at += 1) {
        const node = queue[at];
        if (node.kind == .text) {
            if (node.props.none and text.len > 0) try show(e, node.id, true);
            if (!try e.tree.updateText(node.id, text)) {
                var p = node.props;
                const first = if (p.runs) |rs| rs[0] else return error.InvalidTextNode;
                var run = first;
                run.t = text;
                const runs = [_]@TypeOf(first){run};
                p.runs = &runs;
                try e.tree.updateUiProps(node.id, p);
            }
            if (text.len == 0) try show(e, node.id, false);
            return;
        }
        if (node.kind == .button) {
            var p = node.props;
            const runs = [_]@TypeOf(p.runs.?[0]){.{ .t = text, .sz = p.fz orelse 14, .c = p.col orelse oriel.canvas.rgb(0x191d19) }};
            p.runs = &runs;
            p.val = text;
            p.al = text;
            try e.tree.updateUiProps(node.id, p);
            return;
        }
        for (node.kids.items) |child| {
            if (len == queue.len) return error.ViewTooLarge;
            queue[len] = child;
            len += 1;
        }
    }
    const base = 800000 + id;
    _ = try Text.mount(&e.tree, base, 79000, &.{.{ .name = "text", .value = "" }});
    if (!try e.tree.updateText(base, text)) return error.InvalidTextNode;
    if (!try e.tree.stampKids(id, &.{base})) return error.InvalidTemplate;
}
pub fn status(e: *ui.Engine, text: []const u8) !void {
    try snackbar(e, text, false);
}
fn snackbar(e: *ui.Engine, text: []const u8, failed: bool) !void {
    const id = aid("status");
    try set_text(e, id, text);
    var p = e.tree.get(id).?.props;
    p.op = 1;
    p.z = 2147483647;
    p.ty = 0;
    p.pe = "auto";
    p.none = text.len == 0;
    try e.tree.updateUiProps(id, p);
    const leaf = e.tree.get(id).?.kids.items[0];
    p = leaf.props;
    var run = p.runs.?[0];
    run.c = oriel.canvas.rgb(if (failed) (if (e.tree.dark) @as(u24, 0x93000a) else 0xffb4ab) else (if (e.tree.dark) @as(u24, 0x2e322e) else 0xeef2ea));
    run.sz = 14;
    p.runs = &.{run};
    p.lh = 19.6;
    try e.tree.updateUiProps(leaf.id, p);
    const duration: u32 = if (failed) 8000 else 3500;
    s.snackbar_until = std.Io.Clock.awake.now(s.io).toMilliseconds() + duration;
    e.backend.add_timer(e.backend.ctx, e, 2, duration);
}
pub fn set_image(e: *ui.Engine, id: i64, data_url: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    try e.tree.setImageData(id, try @import("core/ledger.zig").image_bytes(arena.allocator(), data_url));
}

pub fn disclosure(e: *ui.Engine, summary: i64, body: i64, label: []const u8) !void {
    const open = e.tree.get(body).?.props.none;
    try show(e, body, open);
    const text = try std.fmt.allocPrint(e.gpa, "{s} {s}", .{ label, if (open) "▴" else "▾" });
    defer e.gpa.free(text);
    try set_text(e, summary, text);
}

pub fn supporting(e: *ui.Engine, base: i64, text: []const u8) !void {
    _ = try Text.mount(&e.tree, base, 79000, &.{.{ .name = "text", .value = "" }});
    var props = e.tree.get(base).?.props;
    var run = props.runs.?[0];
    run.sz = 13;
    run.c = oriel.canvas.rgb(if (e.tree.dark) 0xc2c9c0 else 0x434a43);
    props.fz = 13;
    props.lh = 18.85;
    props.col = run.c;
    props.m = .{ .{ .px = 0 }, .{ .px = 0 }, .{ .px = 8 }, .{ .px = 0 } };
    props.runs = &.{run};
    try e.tree.updateUiProps(base, props);
    _ = try e.tree.updateText(base, text);
}

pub fn report_error(e: *ui.Engine, id: i64, code: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const message = try errors.message(arena.allocator(), code);
    if (id == aid("status")) try snackbar(e, message, true) else try set_text(e, id, message);
}

pub fn redraw(e: *ui.Engine) void {
    e.tree.layout();
    e.relaid = true;
    e.paintNow();
}
pub fn options(e: *ui.Engine, id: i64, values: []const []const u8, labels: []const []const u8, selected: []const u8) !void {
    var p = e.tree.get(id).?.props;
    const opts = try e.gpa.alloc([2][]const u8, values.len);
    defer e.gpa.free(opts);
    for (values, labels, opts) |v, l, *o| o.* = .{ v, l };
    p.options = opts;
    p.val = selected;
    try e.tree.updateUiProps(id, p);
}
fn boot(e: *ui.Engine) !void {
    s.draft = .init(e.gpa);
    s.initialized = true;
    inline for (.{ .{ App, 50000 }, .{ Editor, 60000 }, .{ Item, item_style }, .{ Payment, 70500 }, .{ Day, 70600 }, .{ BudgetPart, 70700 }, .{ Evidence, 71000 }, .{ EvidencePanel, 76000 }, .{ StatementEvidence, 76100 }, .{ Text, 79000 }, .{ Notice, 78000 }, .{ Backdrop, 79500 } }) |v| try v[0].prepare(&e.tree, v[1]);
    try desktop.prepare(e);
    try suggestions.prepare(e);
    try categories.prepare(e);
    try tools.prepare(e);
    try research.prepare(e);
    try progress.prepare(e);
    try choose_variant(e);
    try set_text(e, aid("total"), "—");
    try set_text(e, aid("payment-count"), "Loading…");
    try set_text(e, aid("receipt-count"), "");
    try show(e, aid("monthly-budget"), false);
    try refresh(e);
    if (!oriel.target.is_android) try invoke(e, .sync_action, "sync_control", .{ .action = "start" });
    e.backend.add_timer(e.backend.ctx, e, 1, 5000);
}
fn shutdown(e: *ui.Engine) void {
    if (!s.initialized) return;
    if (s.snapshot) |v| v.deinit();
    if (s.settings) |v| v.deinit();
    if (s.sources) |v| v.deinit();
    clear_drilldown(e);
    s.drill_ids.deinit(e.gpa);
    s.actions.deinit(e.gpa);
    s.inert.deinit(e.gpa);
    s.selected.deinit(e.gpa);
    s.draft.deinit();
    desktop.shutdown();
    categories.shutdown();
    progress.shutdown();
    tools.shutdown();
    research.shutdown();
    s.initialized = false;
    s.snapshot = null;
    s.settings = null;
}
fn choose_variant(e: *ui.Engine) !void {
    const next: usize = (if (e.tree.width < 840) @as(usize, 2) else 0) + (if (e.tree.dark) @as(usize, 1) else 0);
    s.variant = next;
    if (e.tree.get(1000) == null) _ = try App.mount(&e.tree, 1000, 50000, &.{});
    e.tree.root = e.tree.get(1000);
    inline for (input_names, 0..) |name, i| try set_value(e, aid(name), s.inputs[i][0..s.input_lens[i]]);
    try mark_actions(e, App, 1000, .{ "nav-home", "nav-payments", "nav-insights", "nav-settings", "refresh", "new-expense", "new-receipt", "open-fixed", "open-sync", "open-scanner", "open-statements", "pref-budget", "pref-fixed", "pref-accounts", "pref-categories", "pref-vendors", "pref-special", "audit-other", "clear-ledger", "clear-filters", "clear-drilldown", "export-report", "bulk-preview-button", "bulk-apply", "bulk-cancel", "range-toggle", "bulk-details-toggle", "quit", "hide-to-tray", "legacy-file", "research-open" });
    try navigation(e);
    const platform = if (s.snapshot) |snapshot| snapshot.value.platform else oriel.target.name;
    try show(e, aid("research-open"), std.mem.eql(u8, platform, "linux") or std.mem.eql(u8, platform, "android"));
    try show(e, aid("categories-bulk-category-list"), false);
    try show(e, aid("range-body"), s.range_open);
    try show(e, aid("bulk-details-body"), s.bulk_open);
    try set_text(e, aid("bulk-details-toggle"), if (s.bulk_open) "Categorize matching payments ▴" else "Categorize matching payments ▾");
    try tools.render_bulk(e);
    if (s.snapshot != null) {
        try period_options(e);
        try render(e);
    }
    try overlay(e);
}
fn resized(e: *ui.Engine) !void {
    const next: usize = (if (e.tree.width < 840) @as(usize, 2) else 0) + (if (e.tree.dark) @as(usize, 1) else 0);
    if (next != s.variant) try choose_variant(e);
    try tools.resize(e);
    try categories.resize(e);
    if (s.modal == .editor) {
        try resize_modal(e, editor_base);
        try editor_capture_layout(e);
    }
}
pub fn mark_action(e: *ui.Engine, id: i64, label: []const u8) !void {
    try e.tree.setAxEntry(id, .{ .r = .button, .n = label, .s = 1024 });
    if (e.tree.get(id)) |node| {
        var p = node.props;
        if (p.minh == null or p.minh.? == .px and p.minh.?.px < 48) p.minh = .{ .px = 48 };
        if (p.minw == null or p.minw.? == .px and p.minw.?.px < 48) p.minw = .{ .px = 48 };
        try e.tree.updateUiProps(id, p);
    }
    if (std.mem.indexOfScalar(i64, s.actions.items, id) == null) try s.actions.append(e.gpa, id);
}
pub fn mark_actions(e: *ui.Engine, comptime View: type, base: i64, comptime names: anytype) !void {
    inline for (names) |name| try mark_action(e, View.id(name, base), name);
}
fn inside(node: *ui.Node, ancestor: i64) bool {
    var n: ?*ui.Node = node;
    var depth: usize = 0;
    while (n) |p| : (depth += 1) {
        if (depth == 64) break;
        if (p.id == ancestor) return true;
        n = p.parent;
    }
    return false;
}
/// Controls outside the open modal (or dialog) stay drawn under its
/// backdrop, as a browser shows them, but Tab skips them (tabindex -1)
/// until it closes. Taps reach the backdrop above them, and the platform
/// hides a covered native field and draws it in place.
fn modal_focus(e: *ui.Engine, modal: ?i64) !void {
    var nodes = e.tree.nodes.iterator();
    while (nodes.next()) |entry| {
        const n = entry.value_ptr.*;
        if (n.kind == .input or n.kind == .textarea or n.kind == .select or n.kind == .button or n.kind == .check or std.mem.indexOfScalar(i64, s.actions.items, n.id) != null) {
            const allowed = if (modal) |id| inside(n, id) else true;
            const was = s.inert.get(n.id);
            if (allowed == (was == null)) continue;
            var p = n.props;
            if (allowed) {
                p.ti = was.?;
                _ = s.inert.remove(n.id);
            } else {
                try s.inert.put(e.gpa, n.id, n.props.ti);
                p.ti = -1;
            }
            try e.tree.updateUiProps(n.id, p);
        }
    }
    // Controls gone since (a list re-rendered): nothing to give back.
    var stale_ids: std.ArrayList(i64) = .empty;
    defer stale_ids.deinit(e.gpa);
    var stale = s.inert.keyIterator();
    while (stale.next()) |id| if (e.tree.get(id.*) == null) try stale_ids.append(e.gpa, id.*);
    for (stale_ids.items) |id| _ = s.inert.remove(id);
    for (s.actions.items) |id| if (e.tree.get(id)) |n| if (e.tree.ax.get(id)) |ax| {
        const allowed = if (modal) |parent| inside(n, parent) else true;
        try e.tree.setAxEntry(id, .{ .r = ax.r, .n = ax.n, .s = if (allowed) 1024 else 0 });
    };
}
pub fn switch_state(e: *ui.Engine, id: i64, on: bool) !void {
    const n = e.tree.get(id) orelse return error.UnknownNode;
    var p = n.props;
    const primary = oriel.canvas.rgb(if (e.tree.dark) 0x9ad4ae else 0x2d6a4f);
    const outline = oriel.canvas.rgb(if (e.tree.dark) 0x8c938a else 0x737a72);
    const border = if (on) primary else outline;
    p.bg = .{ .color = if (on) primary else oriel.canvas.rgb(if (e.tree.dark) 0x272b27 else 0xe4e9de) };
    p.bc = .{ border, border, border, border };
    try e.tree.updateUiProps(id, p);
    if (n.kids.items.len > 0) {
        const thumb = n.kids.items[0];
        var t = thumb.props;
        t.bg = .{ .color = if (on) oriel.canvas.rgb(if (e.tree.dark) 0x003920 else 0xffffff) else outline };
        t.ins = .{ .{ .px = if (on) 2 else 6 }, null, null, .{ .px = if (on) 22 else 6 } };
        t.w = .{ .px = if (on) 24 else 16 };
        t.h = t.w;
        try e.tree.updateUiProps(thumb.id, t);
    }
}
pub fn resize_modal(e: *ui.Engine, id: i64) !void {
    const phone = e.tree.width < 600;
    const width = @min(if (id == research.base) @as(f32, 860) else 640, e.tree.width);
    const height = @max(100, e.tree.height - (if (phone) @as(f32, 0) else 48));
    var p = e.tree.get(id).?.props;
    p.w = .{ .px = width };
    p.h = .{ .px = height };
    p.maxh = .{ .px = height };
    p.m = null;
    // The views only become absolute in their phone media query. Wide
    // windows need the same overlay behavior or the dialog flows after the
    // ledger and lands below the viewport.
    p.pos = "absolute";
    p.z = 2147483647;
    p.ins = .{ .{ .px = (e.tree.height - height) / 2 }, null, null, .{ .px = (e.tree.width - width) / 2 } };
    p.br = if (phone) null else p.br;
    try e.tree.updateUiProps(id, p);
}
fn navigation(e: *ui.Engine) !void {
    inline for (.{ "home", "payments", "insights", "settings" }) |page| {
        try show(e, aid("view-" ++ page), std.mem.eql(u8, @tagName(s.page), page));
        const node = e.tree.get(aid("nav-" ++ page)).?;
        const active = std.mem.eql(u8, @tagName(s.page), page);
        const pill = node.kids.items[0];
        var p = pill.props;
        p.bg = .{ .color = if (active) oriel.canvas.rgb(if (e.tree.dark) 0x384a3b else 0xdce7d6) else .{ 0, 0, 0, 0 } };
        try e.tree.updateUiProps(pill.id, p);
    }
    try set_text(e, aid("view-title"), switch (s.page) {
        .home => "Penny Goblin",
        .payments => "Payments",
        .insights => "Insights",
        .settings => "Settings",
    });
    try show(e, aid("new-receipt"), s.page == .home or s.page == .payments);
    try show(e, aid("new-expense"), s.page == .home or s.page == .payments);
}
pub fn navigate(e: *ui.Engine, page: Page) !void {
    s.page = page;
    try navigation(e);
    redraw(e);
}
pub fn overlay(e: *ui.Engine) !void {
    const root = e.tree.root orelse return;
    // The exported root's normal children plus one modal. Detached templates
    // remain owned by the engine; their native fields are explicitly hidden.
    var ids: [16]i64 = undefined;
    var len: usize = 0;
    for (root.kids.items) |child| if (child.id < 10000 and child.id != aid("status")) {
        ids[len] = child.id;
        len += 1;
    };
    const modal_id: ?i64 = if (desktop.menu_active) desktop.menu_base else if (s.modal == .editor) editor_base else tools.modal_id(s.modal);
    if (modal_id != null or s.notice_open) {
        _ = try Backdrop.mount(&e.tree, 19500, 79500, &.{});
        ids[len] = 19500;
        len += 1;
    }
    if (modal_id) |id| {
        ids[len] = id;
        len += 1;
    }
    if (categories.active) {
        ids[len] = categories.base;
        len += 1;
    }
    if (s.notice_open) {
        ids[len] = 19000;
        len += 1;
    }
    ids[len] = aid("status");
    len += 1;
    if (e.tree.get(progress.base) != null) {
        ids[len] = progress.base;
        len += 1;
    }
    if (!try e.tree.stampKids(root.id, ids[0..len])) return error.InvalidTemplate;
    try modal_focus(e, if (s.notice_open) 19000 else if (categories.active) categories.base else modal_id);
}
pub fn close_modal(e: *ui.Engine) !void {
    if (s.modal == .editor) try ui.setVisible(&e.tree, editor_base, false) else if (tools.modal_id(s.modal)) |id| try ui.setVisible(&e.tree, id, false);
    s.modal = .none;
    s.dirty = false;
    if (s.return_to_editor) {
        s.return_to_editor = false;
        s.modal = .editor;
        s.dirty = s.editor_dirty;
        e.tree.get(editor_base).?.stamp_owned = true;
        try ui.setVisible(&e.tree, editor_base, true);
    } else if (s.return_to_statements) {
        s.return_to_statements = false;
        s.modal = .statements;
        e.tree.get(13000).?.stamp_owned = true;
        try ui.setVisible(&e.tree, 13000, true);
    }
    try overlay(e);
    redraw(e);
}
pub fn refresh(e: *ui.Engine) !void {
    if (s.refreshing) return;
    s.refreshing = true;
    errdefer s.refreshing = false;
    try invoke(e, .snapshot, "snapshot", .{});
}
fn timer(e: *ui.Engine, id: u32) !void {
    if (id == 3) return recovery.checkpoint_timer(e);
    if (id == 2) {
        const remaining = s.snackbar_until - std.Io.Clock.awake.now(s.io).toMilliseconds();
        if (remaining > 0) e.backend.add_timer(e.backend.ctx, e, 2, @intCast(remaining)) else try show(e, aid("status"), false);
        return;
    }
    if (id != 1) return;
    try desktop.advance(e);
    try recovery.persist(e);
    defer e.backend.add_timer(e.backend.ctx, e, 1, 5000);
    if (!s.busy) try refresh(e);
    if (s.modal == .sync) try tools.refresh_sync(e);
    if (s.modal == .scanner) try invoke(e, .scanner_status, "scanner_status", .{});
    try invoke(e, .quick_action, "take_quick_action", .{});
}
fn period_options(e: *ui.Engine) !void {
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = s.snapshot.?.value.expenses;
    var months: []const []const u8 = &.{};
    inline for (.{ "month", "account-filter", "category-filter", "merchant-category" }, 0..) |name, which| {
        var list: std.ArrayList([]const u8) = .empty;
        try list.append(a, "");
        for (rows) |row| {
            const v = switch (which) {
                0 => row.date[0..7],
                1 => row.account,
                else => try reports.category_name(a, row, settings()),
            };
            var found = false;
            for (list.items) |x| {
                if (std.mem.eql(u8, x, v)) {
                    found = true;
                    break;
                }
            }
            if (!found) try list.append(a, v);
        }
        if (which == 1 and settings().cards_config == .object) {
            var cards = settings().cards_config.object.iterator();
            while (cards.next()) |card| {
                var found = false;
                for (list.items) |x| if (std.mem.eql(u8, x, card.key_ptr.*)) {
                    found = true;
                    break;
                };
                if (!found) try list.append(a, card.key_ptr.*);
            }
        }
        std.mem.sort([]const u8, list.items[1..], which == 0, struct {
            fn less(reverse: bool, x: []const u8, y: []const u8) bool {
                return if (reverse) std.mem.lessThan(u8, y, x) else std.mem.lessThan(u8, x, y);
            }
        }.less);
        const labels = try a.alloc([]const u8, list.items.len);
        for (list.items, 0..) |v, i| labels[i] = if (i == 0) switch (which) {
            0 => "All months",
            1 => "All accounts",
            else => "All categories",
        } else if (which == 0) try @import("ui_dates.zig").month_label(a, v) else if (which == 1) try reports.account_label(a, v, settings()) else v;
        var chosen = value(e, aid(name));
        if (which == 0 and !s.initialized_period and list.items.len > 1) {
            chosen = list.items[1];
            s.initialized_period = true;
        }
        try options(e, aid(name), list.items, labels, chosen);
        if (which == 0) months = list.items[1..];
    }
    try insights_options(e, a, months);
    remember_inputs(e);
}
/// Insights has its own month range: From and Through, or a whole year at once.
fn insights_options(e: *ui.Engine, a: std.mem.Allocator, months: []const []const u8) !void {
    const latest = if (months.len > 0) months[0] else "";
    var from: []const u8 = try a.dupe(u8, value(e, aid("insights-from")));
    var through: []const u8 = try a.dupe(u8, value(e, aid("insights-to")));
    if (!s.initialized_insights) {
        from = latest;
        through = latest;
        s.initialized_insights = months.len > 0;
    }
    if (!listed(months, from)) from = latest;
    if (!listed(months, through)) through = latest;
    const from_labels = try a.alloc([]const u8, months.len);
    const through_labels = try a.alloc([]const u8, months.len);
    var years: std.ArrayList([]const u8) = .empty;
    try years.append(a, "");
    for (months, 0..) |month, i| {
        const label = try @import("ui_dates.zig").month_label(a, month);
        from_labels[i] = try std.fmt.allocPrint(a, "From {s}", .{label});
        through_labels[i] = try std.fmt.allocPrint(a, "Through {s}", .{label});
        if (!listed(years.items, month[0..4])) try years.append(a, month[0..4]);
    }
    try options(e, aid("insights-from"), months, from_labels, from);
    try options(e, aid("insights-to"), months, through_labels, through);
    const year_labels = try a.dupe([]const u8, years.items);
    year_labels[0] = "Whole year";
    try options(e, aid("insights-year"), years.items, year_labels, "");
    try sync_insights_year(e);
}
fn listed(values: []const []const u8, wanted: []const u8) bool {
    for (values) |v| if (std.mem.eql(u8, v, wanted)) return true;
    return false;
}
pub const MonthRange = struct { from: []const u8, through: []const u8 };
pub fn insights_range(e: *ui.Engine) MonthRange {
    const from = value(e, aid("insights-from"));
    const through = value(e, aid("insights-to"));
    return if (std.mem.order(u8, from, through) == .gt) .{ .from = through, .through = from } else .{ .from = from, .through = through };
}
pub fn insights_matches(e: *ui.Engine, row: model.Expense) bool {
    const range = insights_range(e);
    const account = value(e, aid("account-filter"));
    if (account.len > 0 and !std.mem.eql(u8, account, row.account)) return false;
    if (range.from.len == 0 or row.date.len < 7) return false;
    const month = row.date[0..7];
    return std.mem.order(u8, month, range.from) != .lt and std.mem.order(u8, month, range.through) != .gt;
}
/// Calendar months from `from` through `through` ("YYYY-MM"), both included.
pub fn calendar_months(from: []const u8, through: []const u8) usize {
    const index = struct {
        fn of(month: []const u8) ?i64 {
            if (month.len != 7 or month[4] != '-') return null;
            const year = std.fmt.parseInt(i64, month[0..4], 10) catch return null;
            const number = std.fmt.parseInt(i64, month[5..7], 10) catch return null;
            return year * 12 + number - 1;
        }
    }.of;
    const first = index(from) orelse return 1;
    const last = index(through) orelse return 1;
    return if (last < first) 1 else @intCast(last - first + 1);
}
/// The first and last recorded months of `year`.
fn year_months(year: []const u8) ?MonthRange {
    var first: ?[]const u8 = null;
    var last: ?[]const u8 = null;
    for (s.snapshot.?.value.expenses) |row| if (row.date.len >= 7 and std.mem.startsWith(u8, row.date, year)) {
        const month = row.date[0..7];
        if (first == null or std.mem.order(u8, month, first.?) == .lt) first = month;
        if (last == null or std.mem.order(u8, month, last.?) == .gt) last = month;
    };
    return if (first) |value_first| .{ .from = value_first, .through = last.? } else null;
}
// The year chip names the whole year only while the range covers exactly its recorded months.
fn sync_insights_year(e: *ui.Engine) !void {
    const range = insights_range(e);
    var year: []const u8 = "";
    if (range.from.len == 7 and std.mem.eql(u8, range.from[0..4], range.through[0..4])) if (year_months(range.from[0..4])) |span| {
        if (std.mem.eql(u8, span.from, range.from) and std.mem.eql(u8, span.through, range.through)) year = range.from[0..4];
    };
    var buf: [4]u8 = undefined;
    @memcpy(buf[0..year.len], year);
    try set_value(e, aid("insights-year"), buf[0..year.len]);
}
fn insights_changed(e: *ui.Engine, id: i64) !void {
    var buf: [16]u8 = undefined;
    const from = value(e, aid("insights-from"));
    const through = value(e, aid("insights-to"));
    if (id == aid("insights-from") and std.mem.order(u8, from, through) == .gt and from.len <= buf.len) {
        @memcpy(buf[0..from.len], from);
        try set_value(e, aid("insights-to"), buf[0..from.len]);
    } else if (id == aid("insights-to") and std.mem.order(u8, through, from) == .lt and through.len <= buf.len) {
        @memcpy(buf[0..through.len], through);
        try set_value(e, aid("insights-from"), buf[0..through.len]);
    } else if (id == aid("insights-year") and value(e, aid("insights-year")).len == 4) {
        if (year_months(value(e, aid("insights-year")))) |span| {
            var first: [7]u8 = undefined;
            var last: [7]u8 = undefined;
            @memcpy(&first, span.from[0..7]);
            @memcpy(&last, span.through[0..7]);
            try set_value(e, aid("insights-from"), &first);
            try set_value(e, aid("insights-to"), &last);
        }
    }
    try sync_insights_year(e);
}
pub fn remember_inputs(e: *ui.Engine) void {
    inline for (input_names, 0..) |name, i| {
        const v = value(e, aid(name));
        const len = @min(v.len, s.inputs[i].len);
        @memcpy(s.inputs[i][0..len], v[0..len]);
        s.input_lens[i] = len;
    }
}
pub fn period(e: *ui.Engine) reports.Filter {
    return .{ .month = value(e, aid("month")), .account = value(e, aid("account-filter")), .from = value(e, aid("date-from")), .through = value(e, aid("date-through")) };
}
pub fn clear_drilldown(e: *ui.Engine) void {
    var keys = s.drill_ids.keyIterator();
    while (keys.next()) |key| e.gpa.free(key.*);
    s.drill_ids.clearRetainingCapacity();
    if (s.drill_name) |name| e.gpa.free(name);
    s.drill_name = null;
    s.drill_active = false;
    s.drill_from = null;
}
fn leave_drilldown(e: *ui.Engine) !void {
    const from = s.drill_from;
    clear_drilldown(e);
    if (from) |page| try navigate(e, page);
    try render(e);
}
pub fn drilldown(e: *ui.Engine, ids: []const []const u8, name: []const u8) !void {
    clear_drilldown(e);
    errdefer clear_drilldown(e);
    s.drill_from = s.page;
    s.drill_name = try e.gpa.dupe(u8, name);
    for (ids) |id| {
        const owned = try e.gpa.dupe(u8, id);
        errdefer e.gpa.free(owned);
        try s.drill_ids.put(e.gpa, owned, {});
    }
    s.drill_active = true;
    try set_value(e, aid("search"), "");
    try set_value(e, aid("category-filter"), "");
    remember_inputs(e);
    try navigate(e, .payments);
    try render(e);
}
fn count_label(e: *ui.Engine, id: i64, count: usize, suffix: []const u8) !void {
    var buffer: [32]u8 = undefined;
    var props = e.tree.get(id).?.props;
    var number = props.runs.?[0];
    number.t = try std.fmt.bufPrint(&buffer, "{d}", .{count});
    number.w = 600;
    var label = number;
    label.t = suffix;
    label.w = 400;
    props.runs = &.{ number, label };
    props.none = false;
    try e.tree.updateUiProps(id, props);
}

pub fn render(e: *ui.Engine) !void {
    if (s.snapshot == null) return;
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var selected: std.ArrayList(model.Expense) = .empty;
    const filter = period(e);
    const snapshot = s.snapshot.?.value;
    try show(e, aid("quit"), !std.mem.eql(u8, snapshot.platform, "android") and !std.mem.eql(u8, snapshot.platform, "ios"));
    try show(e, aid("hide-to-tray"), snapshot.tray_running);
    try set_text(e, aid("device-hint"), if (snapshot.tray_running) "Saved on this device · Runs in the tray when closed" else "Saved on this device · Works offline");
    for (s.snapshot.?.value.expenses) |row| if (filter.matches(row, settings())) try selected.append(a, row);
    const total = reports.totals(selected.items, settings());
    var buf: [128]u8 = undefined;
    try set_text(e, aid("total"), try reports.money(&buf, total.actual));
    try count_label(e, aid("payment-count"), selected.items.len, " payments");
    var evidence: i64 = 0;
    for (selected.items) |row| if (row.evidence_count > 0) {
        evidence += 1;
    };
    try count_label(e, aid("receipt-count"), @intCast(evidence), " with receipt");
    try show(e, aid("monthly-budget"), filter.month.len > 0 and filter.account.len == 0);
    inline for (.{ .{ "budget-forecast", "forecast" }, .{ "fixed-planned", "planned" }, .{ "salary-total", "salary" } }) |pair| try set_text(e, aid(pair[0]), try reports.money(&buf, @field(total, pair[1])));
    var fixed_buffer: [48]u8 = undefined;
    try set_text(e, aid("fixed-paid"), try std.fmt.bufPrint(&buf, "{s} paid", .{try reports.money(&fixed_buffer, total.fixed)}));
    const budgeted = settings().category_budgets == .object and settings().category_budgets.object.count() > 0;
    try set_text(e, aid("budget-hint"), if (settings().salary == 0) "Add your salary in Settings to see what's left." else if (budgeted) "Long-press a budget to remove it." else "");
    try set_text(e, aid("period-title"), if (filter.month.len > 0) try @import("ui_dates.zig").month_label(a, filter.month) else if (filter.from.len > 0 or filter.through.len > 0) try std.fmt.allocPrint(a, "{s} through {s}", .{ if (filter.from.len > 0) filter.from else "Beginning", if (filter.through.len > 0) filter.through else "latest" }) else "All months");
    var variable: [48]u8 = undefined;
    var special: [48]u8 = undefined;
    var parts: [180]u8 = undefined;
    _ = try BudgetPart.mount(&e.tree, 27000000, 70700, &.{.{ .name = "text", .value = try std.fmt.bufPrint(&parts, "Variable {s}", .{try reports.money(&variable, total.variable)}) }});
    _ = try BudgetPart.mount(&e.tree, 27000004, 70700, &.{.{ .name = "text", .value = try std.fmt.bufPrint(&parts, "Special {s}", .{try reports.money(&special, total.special)}) }});
    if (budgeted) {
        var reserved: [48]u8 = undefined;
        _ = try BudgetPart.mount(&e.tree, 27000008, 70700, &.{.{ .name = "text", .value = try std.fmt.bufPrint(&parts, "Budgets left {s}", .{try reports.money(&reserved, total.reserved)}) }});
    }
    if (!try e.tree.stampKids(aid("budget-parts"), if (budgeted) &.{ 27000000, 27000004, 27000008 } else &.{ 27000000, 27000004 })) return error.InvalidTemplate;
    try show(e, aid("clear-drilldown"), s.drill_active);
    try set_text(e, aid("clear-drilldown"), if (s.drill_from) |from| switch (from) {
        .home => "Back to Home",
        .payments => "Back to Payments",
        .insights => "Back to Insights",
        .settings => "Back to Settings",
    } else "Clear filter");
    // A drill-down lists exactly its payments, including an Insights range beyond Home's period.
    try render_payments(e, if (s.drill_active) snapshot.expenses else selected.items);
    // Insights in CLP, as the budget; the list above shows every currency.
    var clp: std.ArrayList(model.Expense) = .empty;
    for (selected.items) |row| if (std.mem.eql(u8, row.currency, "CLP")) try clp.append(a, row);
    var insight: std.ArrayList(model.Expense) = .empty;
    for (snapshot.expenses) |row| if (std.mem.eql(u8, row.currency, "CLP") and insights_matches(e, row)) try insight.append(a, row);
    const range = insights_range(e);
    const months = calendar_months(range.from, range.through);
    try set_text(e, aid("insights-period"), if (range.from.len == 0) "No payments yet" else if (std.mem.eql(u8, range.from, range.through)) try @import("ui_dates.zig").month_label(a, range.from) else try std.fmt.allocPrint(a, "{s} – {s} · {d} months", .{ try @import("ui_dates.zig").month_label(a, range.from), try @import("ui_dates.zig").month_label(a, range.through), months }));
    try tools.render_reports(e, clp.items, insight.items, months);
    // After the reports: they reset the report arena that budget rows also use.
    try tools.render_budgets(e, selected.items);
    try tools.render_statements(e);
    try overlay(e);
    redraw(e);
}
fn render_payments(e: *ui.Engine, rows: []const model.Expense) !void {
    s.selected.clearRetainingCapacity();
    var f = period(e);
    if (s.drill_active) f = .{};
    f.search = value(e, aid("search"));
    f.category = value(e, aid("category-filter"));
    const query = f.search;
    f.search = "";
    var search_arena = std.heap.ArenaAllocator.init(e.gpa);
    defer search_arena.deinit();
    for (rows) |row| {
        if (!f.matches(row, settings()) or (s.drill_active and !s.drill_ids.contains(row.id))) continue;
        const matches = query.len == 0 or reports.contains(row.payee, query) or reports.contains(row.account, query) or reports.contains(reports.holder(row.account, settings()), query) or reports.contains(reports.special(row, settings()) orelse row.category, query) or reports.contains(row.notes, query) or reports.contains(row.reference, query) or reports.contains(try reports.merchant(search_arena.allocator(), row.payee, settings(), true), query);
        if (matches) try s.selected.append(e.gpa, row);
    }
    const sort = value(e, aid("ledger-sort"));
    std.mem.sort(model.Expense, s.selected.items, sort, struct {
        fn less(order: []const u8, x: model.Expense, y: model.Expense) bool {
            if (std.mem.eql(u8, order, "highest")) return x.amount > y.amount;
            if (std.mem.eql(u8, order, "lowest")) return x.amount < y.amount;
            return if (std.mem.eql(u8, order, "oldest")) std.mem.order(u8, x.date, y.date) == .lt else std.mem.order(u8, x.date, y.date) == .gt;
        }
    }.less);
    const count = @min(s.selected.items.len, 600);
    var ids: [1201]i64 = undefined;
    var count_ids: usize = 0;
    var last_day: []const u8 = "";
    for (s.selected.items[0..count], 0..) |row, i| {
        var amount: [48]u8 = undefined;
        var detail: [600]u8 = undefined;
        const base = 26000000 + @as(i64, @intCast(i)) * 16;
        if ((std.mem.eql(u8, sort, "newest") or std.mem.eql(u8, sort, "oldest") or sort.len == 0) and !std.mem.eql(u8, last_day, row.date)) {
            const day = 26010000 + @as(i64, @intCast(i)) * 4;
            var day_buffer: [80]u8 = undefined;
            _ = try Day.mount(&e.tree, day, 70600, &.{.{ .name = "day", .value = try @import("ui_dates.zig").day_label(&day_buffer, row.date) }});
            ids[count_ids] = day;
            count_ids += 1;
            last_day = row.date;
        }
        _ = search_arena.reset(.retain_capacity);
        const payee = try reports.merchant(search_arena.allocator(), row.payee, settings(), true);
        const initial = if (payee.len > 0) payee[0..@min(payee.len, try std.unicode.utf8ByteSequenceLength(payee[0]))] else "?";
        const by_date = sort.len == 0 or std.mem.eql(u8, sort, "newest") or std.mem.eql(u8, sort, "oldest");
        const detail_text = try std.fmt.bufPrint(&detail, "{s} · {s}{s}{s}", .{ try reports.category_name(search_arena.allocator(), row, settings()), reports.holder(row.account, settings()), if (by_date) "" else " · ", if (by_date) "" else row.date });
        _ = try Payment.mount(&e.tree, base, 70500, &.{ .{ .name = "payee", .value = payee }, .{ .name = "initial", .value = initial }, .{ .name = "detail", .value = detail_text }, .{ .name = "amount", .value = try reports.amount_text(&amount, row.amount, row.currency) } });
        if (row.evidence_count > 0) {
            const avatar = e.tree.get(Payment.id("payment-avatar", base)).?;
            var props = avatar.props;
            props.bg = .{ .color = oriel.canvas.rgb(if (e.tree.dark) 0x2f4f22 else 0xc4ef9a) };
            try e.tree.updateUiProps(avatar.id, props);
            const letter = avatar.kids.items[0];
            props = letter.props;
            var run = props.runs.?[0];
            run.c = oriel.canvas.rgb(if (e.tree.dark) 0xc4ef9a else 0x0f2b1d);
            props.runs = &.{run};
            try e.tree.updateUiProps(letter.id, props);
        }
        try mark_action(e, base, try std.fmt.bufPrint(&detail, "{s}, {s}, {s}", .{ row.payee, try reports.amount_text(&amount, row.amount, row.currency), row.date }));
        if (desktop.selected(row.id)) {
            var selection_props = e.tree.get(base).?.props;
            selection_props.bg = .{ .color = oriel.canvas.rgb(if (e.tree.dark) 0x384a3b else 0xd0e4c5) };
            try e.tree.updateUiProps(base, selection_props);
        }
        ids[count_ids] = base;
        count_ids += 1;
    }
    var hint: [512]u8 = undefined;
    try set_text(e, aid("ledger-filter-hint"), if (s.drill_active) try std.fmt.bufPrint(&hint, "{s} · {d}", .{ s.drill_name orelse "Filtered payments", s.selected.items.len }) else if (s.selected.items.len != rows.len) try std.fmt.bufPrint(&hint, "{d} of {d}", .{ s.selected.items.len, rows.len }) else "");
    s.rows = count;
    if (s.selected.items.len == 0) {
        try supporting(e, 26013000, if (s.snapshot.?.value.expenses.len == 0) "No payments yet. Tap Scan to add one." else "No matching payments.");
        var props = e.tree.get(26013000).?.props;
        var run = props.runs.?[0];
        run.sz = 15;
        props.fz = 15;
        props.lh = null;
        props.ta = "center";
        props.pad = .{ .{ .px = 40 }, .{ .px = 16 }, .{ .px = 40 }, .{ .px = 16 } };
        props.runs = &.{run};
        try e.tree.updateUiProps(26013000, props);
        ids[count_ids] = 26013000;
        count_ids += 1;
    } else if (s.selected.items.len > 600) {
        var label: [96]u8 = undefined;
        try supporting(e, 26013000, try std.fmt.bufPrint(&label, "Showing 600 of {d}. Search to narrow.", .{s.selected.items.len}));
        ids[count_ids] = 26013000;
        count_ids += 1;
    }
    if (!try e.tree.stampKids(aid("rows"), ids[0..count_ids])) return error.InvalidTemplate;
}
pub fn open_editor(e: *ui.Engine, expense: ?model.Expense) !void {
    if (s.busy or s.modal != .none or s.snapshot == null) return;
    s.editor_generation +%= 1;
    _ = s.draft.reset(.retain_capacity);
    s.current = null;
    s.document = null;
    s.document_count = 0;
    s.dirty = false;
    s.scan_first = false;
    s.scan_cancelled = false;
    s.details_open = true;
    s.extraction_open = false;
    suggestions.reset();
    _ = try Editor.mount(&e.tree, editor_base, 60000, &.{});
    try mark_actions(e, Editor, editor_base, .{ "close-editor", "save", "receipt-file", "camera-file", "scanner-setup", "manual-fallback", "analyze", "remove-image", "delete", "cancel-delete", "confirm-delete", "cancel-analysis", "details-toggle", "extraction-toggle", "choose-category" });
    try ui.setVisible(&e.tree, editor_base, true);
    if (expense) |row| s.current = try std.json.parseFromSliceLeaky(model.Expense, s.draft.allocator(), try std.json.Stringify.valueAlloc(s.draft.allocator(), row, .{}), .{ .allocate = .alloc_always });
    inline for (.{ "payee", "date", "account", "category", "notes", "reference", "location" }) |field| try set_value(e, eid("field-" ++ field), if (s.current) |v| @field(v, field) else if (std.mem.eql(u8, field, "category")) "Other" else "");
    try set_text(e, eid("category-value"), value(e, eid("field-category")));
    try category_rule_note(e);
    var amount: [32]u8 = undefined;
    try set_value(e, eid("field-amount"), if (s.current) |v| try model.amount_input(&amount, v.amount, v.currency) else "");
    var accounts: std.ArrayList([]const u8) = .empty;
    const a = s.draft.allocator();
    try accounts.append(a, "");
    if (settings().cards_config == .object) {
        var it = settings().cards_config.object.iterator();
        while (it.next()) |entry| try accounts.append(a, entry.key_ptr.*);
    }
    for (s.snapshot.?.value.expenses) |row| {
        var found = false;
        for (accounts.items) |x| if (std.mem.eql(u8, x, row.account)) {
            found = true;
            break;
        };
        if (!found) try accounts.append(a, row.account);
    }
    const account_labels = try a.alloc([]const u8, accounts.items.len);
    for (accounts.items, 0..) |account, i| account_labels[i] = if (account.len == 0) "Choose account" else try std.fmt.allocPrint(a, "{s} · {s}", .{ account, reports.holder(account, settings()) });
    try options(e, eid("field-account"), accounts.items, account_labels, if (s.current) |v| v.account else "");
    inline for (.{ "pending-evidence", "extraction-details", "delete-confirm", "cancel-analysis" }) |id| try show(e, eid(id), false);
    try set_text(e, eid("editor-title"), if (expense != null) "Payment" else "New payment");
    try show(e, eid("review-fields"), true);
    try show(e, eid("save"), true);
    try show(e, eid("capture-choices"), true);
    try show(e, eid("scanner-setup"), s.current == null);
    try editor_capture_layout(e);
    try show(e, eid("scan-sweep"), false);
    try show(e, eid("image-actions"), true);
    try show(e, eid("details-body"), true);
    try set_text(e, eid("details-toggle"), "More details ▴");
    try show(e, eid("manual-fallback"), false);
    try show(e, eid("delete"), expense != null);
    try show(e, eid("camera-label"), oriel.target.is_android);
    try set_text(e, eid("editor-status"), "");
    _ = try EvidencePanel.mount(&e.tree, 18000, 76000, &.{});
    if (!try e.tree.stampKids(eid("saved-evidence"), &.{18000})) return error.InvalidTemplate;
    s.modal = .editor;
    try resize_modal(e, editor_base);
    try overlay(e);
    redraw(e);
    desktop.focus(e, eid("field-payee"));
    if (expense == null) try invoke(e, .defaults, "ui_defaults", .{});
    if (expense) |row| {
        try invoke(e, .documents, "expense_documents", .{ .id = row.id });
        try invoke(e, .sources, "expense_statements", .{ .id = row.id });
    }
}
// Existing payments put compact attachment choices after their saved evidence.
fn editor_capture_layout(e: *ui.Engine) !void {
    if (s.current == null) return;
    const capture = e.tree.get(eid("capture-choices")) orelse return;
    var p = capture.props;
    p.m = .{ .{ .px = 8 }, .{ .px = 0 }, .{ .px = 8 }, .{ .px = 0 } };
    try e.tree.updateUiProps(capture.id, p);
    for (capture.kids.items) |choice| {
        p = choice.props;
        p.fd = "row";
        p.minh = .{ .px = 64 };
        try e.tree.updateUiProps(choice.id, p);
        for (choice.kids.items) |child| if (child.kind == .icon) {
            p = child.props;
            p.w = .{ .px = 24 };
            p.h = .{ .px = 24 };
            try e.tree.updateUiProps(child.id, p);
        };
    }
    const parent = capture.parent orelse return;
    var ids: [128]i64 = undefined;
    if (parent.kids.items.len > ids.len) return error.InvalidTemplate;
    var len: usize = 0;
    for (parent.kids.items) |child| if (child.id != capture.id) {
        ids[len] = child.id;
        len += 1;
    };
    ids[len] = capture.id;
    if (!try e.tree.stampKids(parent.id, ids[0 .. len + 1])) return error.InvalidTemplate;
}
pub fn open_capture(e: *ui.Engine) !void {
    try open_editor(e, null);
    if (s.modal != .editor) return;
    s.scan_first = true;
    s.details_open = false;
    try show(e, eid("details-body"), false);
    try set_text(e, eid("details-toggle"), "More details ▾");
    try set_value(e, eid("field-date"), "");
    try set_text(e, eid("editor-title"), "Scan voucher");
    try show(e, eid("review-fields"), false);
    try show(e, eid("save"), false);
    try show(e, eid("manual-fallback"), true);
    redraw(e);
}
fn show_review(e: *ui.Engine) !void {
    try show(e, eid("review-fields"), true);
    try show(e, eid("save"), true);
    try show(e, eid("manual-fallback"), false);
}
pub fn save(e: *ui.Engine) !void {
    if (s.busy) return;
    if (s.current == null) {
        s.busy = true;
        try invoke(e, .new_id, "new_id", .{});
        return;
    }
    var expense = s.current.?;
    inline for (.{ "payee", "date", "account", "category", "notes", "reference", "location" }) |field| @field(expense, field) = value(e, eid("field-" ++ field));
    // In the payment's own currency (a new one is CLP: this editor offers no other).
    expense.amount = model.parse_amount(value(e, eid("field-amount")), expense.currency) catch return error.InvalidAmount;
    try model.validate(expense);
    s.busy = true;
    errdefer s.busy = false;
    try invoke(e, .save, "save_expense", model.Save{ .expense = expense, .expected_revision = expense.revision, .document = s.document });
}
fn category_rule_note(e: *ui.Engine) !void {
    const row: model.Expense = .{ .id = "", .date = "", .amount = 0, .payee = value(e, eid("field-payee")) };
    const special = reports.special(row, settings());
    try show(e, eid("category-rule-note"), special != null);
    if (special) |label| try set_text(e, eid("category-rule-note"), try std.fmt.allocPrint(s.draft.allocator(), "Special payment: {s}", .{label}));
}
fn event(e: *ui.Engine, id: i64, kind: []const u8, data: []const u8) bool {
    defer if (oriel.target.is_android and (std.mem.eql(u8, kind, "input") or std.mem.eql(u8, kind, "change") or std.mem.eql(u8, kind, "click"))) {
        recovery.schedule(e);
    };
    return normalized_event(e, id, kind, data) catch |err| {
        std.log.err("Oriel view action: {s}", .{@errorName(err)});
        report_error(e, if (s.modal == .editor) eid("editor-status") else aid("status"), @errorName(err)) catch {};
        return true;
    };
}
fn normalized_event(e: *ui.Engine, id: i64, kind: []const u8, data: []const u8) !bool {
    if (!std.mem.eql(u8, kind, "input") and !std.mem.eql(u8, kind, "change")) return handle_event(e, id, kind, data);
    // Android/AppKit/Win32 carry [value, inputType, data]; GTK carries a string.
    // Normalize once before category/suggestion handlers or dirty-state tracking.
    const parsed = try std.json.parseFromSlice(std.json.Value, e.gpa, data, .{});
    defer parsed.deinit();
    if (parsed.value == .array and parsed.value.array.items.len > 0 and parsed.value.array.items[0] == .string) {
        const value_json = try std.json.Stringify.valueAlloc(e.gpa, parsed.value.array.items[0].string, .{});
        defer e.gpa.free(value_json);
        return handle_event(e, id, kind, value_json);
    }
    return handle_event(e, id, kind, data);
}

fn handle_event(e: *ui.Engine, id: i64, kind: []const u8, data: []const u8) !bool {
    if (std.mem.eql(u8, kind, "desktop_profile")) {
        recovery.profile(data);
        if (s.snapshot != null) try recovery.restore_once(e);
        return true;
    }
    if (std.mem.eql(u8, kind, "desktop_checkpoint")) {
        try recovery.persist(e);
        return true;
    }
    if (std.mem.eql(u8, kind, "desktop_files")) {
        try desktop.receive(e, data);
        return true;
    }
    if (std.mem.eql(u8, kind, "key") and try desktop.key(e, data)) return true;
    if (try desktop.event(e, id, kind, data)) return true;
    if (try categories.event(e, id, kind, data)) return true;
    if (std.mem.eql(u8, kind, "back")) {
        if (s.notice_open) return click(e, Notice.id("cancel", 19000));
        if (s.modal == .none and s.page == .home and !s.busy) return false;
        try request_close(e);
        return true;
    }
    if (try suggestions.event(e, id, kind, data)) return true;
    if (std.mem.eql(u8, kind, "message")) {
        const msg = try std.json.parseFromSlice(struct { __oriel_event: []const u8 = "", payload: std.json.Value = .null }, e.gpa, data, .{ .ignore_unknown_fields = true });
        defer msg.deinit();
        if (std.mem.eql(u8, msg.value.__oriel_event, "scan_stage") and s.modal == .editor and msg.value.payload == .object) if (msg.value.payload.object.get("stage")) |stage| if (stage == .string) try progress.stage(e, stage.string);
        if (std.mem.eql(u8, msg.value.__oriel_event, "research_progress")) try research.progress(e, msg.value.payload);
        if (std.mem.eql(u8, msg.value.__oriel_event, "model_download")) {
            try tools.download_progress(e, msg.value.payload);
            try research.model_progress(e, msg.value.payload);
        }
        if (std.mem.eql(u8, msg.value.__oriel_event, "quick_action")) try invoke(e, .quick_action, "take_quick_action", .{});
        return true;
    }
    if (std.mem.eql(u8, kind, "input") or std.mem.eql(u8, kind, "change")) {
        if (e.tree.get(id)) |n| if (n.kind == .input or n.kind == .textarea or n.kind == .select) {
            const parsed = try std.json.parseFromSlice([]const u8, e.gpa, data, .{});
            defer parsed.deinit();
            try e.tree.acceptUiValue(id, parsed.value);
        };
        if (s.modal == .editor) {
            s.dirty = true;
            if (id == eid("field-payee")) try category_rule_note(e);
        } else if (s.modal == .preferences) s.dirty = true else {
            if (id == aid("month") or id == aid("account-filter")) clear_drilldown(e);
            if (id == aid("insights-from") or id == aid("insights-to") or id == aid("insights-year")) try insights_changed(e, id);
            remember_inputs(e);
            try render(e);
        }
        return true;
    }
    if (std.mem.eql(u8, kind, "key") and std.mem.indexOf(u8, data, "Escape") != null) {
        try request_close(e);
        return true;
    }
    if (std.mem.eql(u8, kind, "contextmenu")) {
        if (s.notice_open or s.modal != .none or s.busy) return false;
        var target = e.tree.get(id);
        var level: usize = 0;
        while (target) |n| : (level += 1) {
            if (level == 64) break;
            if (try tools.context(e, n.id)) return true;
            target = n.parent;
        }
        return false;
    }
    if (!std.mem.eql(u8, kind, "click")) return false;
    if (id == 19500 and s.modal == .editor and !s.notice_open) {
        try request_close(e);
        return true;
    }
    // The engine reports the hit leaf; resolve against its ancestor controls.
    var node = e.tree.get(id);
    var depth: usize = 0;
    while (node) |n| : (depth += 1) {
        if (depth == 64) break;
        if (try click(e, n.id)) return true;
        node = n.parent;
    }
    return s.modal != .none;
}
pub fn request_close(e: *ui.Engine) !void {
    if (categories.active) {
        try categories.close(e);
        return;
    }
    if (s.modal == .research and research.running) {
        try research.stop(e);
        return;
    }
    if (s.notice_open) {
        _ = try click(e, Notice.id("cancel", 19000));
        return;
    }
    if (s.busy) return;
    if (s.dirty) {
        s.notice_open = true;
        s.confirm_discard = true;
        s.confirm_action = .discard;
        _ = try Notice.mount(&e.tree, 19000, 78000, &.{.{ .name = "message", .value = "Discard unsaved changes?" }});
        try overlay(e);
        redraw(e);
        return;
    }
    if (s.modal != .none) try close_modal(e) else if (s.drill_from != null) try leave_drilldown(e) else try navigate(e, .home);
}
/// Whether node `id` is the open dialog's (Notice, mounted at 19000) or inside it.
fn inNotice(e: *ui.Engine, id: i64) bool {
    return if (e.tree.get(id)) |node| inside(node, 19000) else false;
}

fn click(e: *ui.Engine, id: i64) !bool {
    if (id == eid("choose-category")) {
        try categories.open(e, false);
        return true;
    }
    if (id == aid("pref-categories")) {
        try categories.open(e, true);
        return true;
    }
    if (s.notice_open) {
        if (id == Notice.id("cancel", 19000) or id == Notice.id("confirm", 19000)) {
            s.notice_open = false;
            try ui.setVisible(&e.tree, 19000, false);
            if (id == Notice.id("confirm", 19000)) {
                switch (s.confirm_action) {
                    .discard => try close_modal(e),
                    .replace_image => {
                        try overlay(e);
                        try pick_image(e, s.pending_camera);
                    },
                    .rescan => {
                        try overlay(e);
                        try start_scan(e, true);
                    },
                    .scanner_delete => {
                        try overlay(e);
                        try tools.confirm_scanner_delete(e);
                    },
                    .category_budget => {
                        try overlay(e);
                        try tools.save_category_budget(e);
                    },
                }
            } else try overlay(e);
            return true;
        }
        // A button's label or the dialog around it: the walk goes on up to
        // the button. Anything outside the dialog is blocked while it's open.
        return !inNotice(e, id);
    }
    if (s.modal == .research) return research.click(e, id);
    if (s.modal == .editor) return editor_click(e, id);
    if (s.modal != .none) return tools.click(e, id);
    inline for (.{ "home", "payments", "insights", "settings" }) |page| if (id == aid("nav-" ++ page)) {
        // Choosing a destination ends a drill-down, as in the web view.
        if (s.drill_active) {
            clear_drilldown(e);
            try render(e);
        }
        try navigate(e, @field(Page, page));
        return true;
    };
    if (id == aid("refresh")) {
        try progress.task(e, .refresh, "Loading payments", null);
        try refresh(e);
        return true;
    }
    if (id == aid("new-expense") or id == aid("new-receipt")) {
        if (id == aid("new-receipt")) try open_capture(e) else try open_editor(e, null);
        return true;
    }
    if (id == aid("range-toggle")) {
        s.range_open = !s.range_open;
        try show(e, aid("range-body"), s.range_open);
        return true;
    }
    if (id == aid("bulk-details-toggle")) {
        s.bulk_open = !s.bulk_open;
        try disclosure(e, id, aid("bulk-details-body"), "Categorize matching payments");
        return true;
    }
    if (id >= 26000000 and id < 26000000 + @as(i64, @intCast(s.rows)) * 16) {
        const i: @TypeOf(s.rows) = @intCast(@divTrunc(id - 26000000, 16));
        try open_editor(e, s.selected.items[i]);
        return true;
    }
    if (id == aid("clear-drilldown")) {
        try leave_drilldown(e);
        return true;
    }
    if (id == aid("research-open")) {
        try research.open(e);
        return true;
    }
    if (id == aid("audit-other")) {
        var arena = std.heap.ArenaAllocator.init(e.gpa);
        defer arena.deinit();
        var ids: std.ArrayList([]const u8) = .empty;
        for (s.snapshot.?.value.expenses) |row| if (reports.uncategorized(row, settings())) try ids.append(arena.allocator(), row.id);
        try drilldown(e, ids.items, "Uncategorized variable payments");
        return true;
    }
    if (id == aid("clear-ledger") or id == aid("clear-filters")) {
        clear_drilldown(e);
        inline for (.{ "search", "category-filter" }) |name| try set_value(e, aid(name), "");
        if (id == aid("clear-filters")) inline for (.{ "month", "account-filter", "date-from", "date-through" }) |name| try set_value(e, aid(name), "");
        remember_inputs(e);
        try render(e);
        return true;
    }
    if (id == aid("legacy-file") and !s.busy) {
        s.busy = true;
        try invoke(e, .pick_legacy, "ui_pick_file", .{ .kind = "legacy" });
        return true;
    }
    if (id == aid("quit")) {
        try invoke(e, .cancel, "quit", .{});
        return true;
    }
    if (id == aid("hide-to-tray")) {
        if (oriel.App.getWindow("main")) |w| w.hide();
        return true;
    }
    return tools.click(e, id);
}
fn editor_click(e: *ui.Engine, id: i64) !bool {
    if (id >= 400000 and id < 400000 + @as(i64, @intCast(s.document_count)) * 16) {
        const base = 400000 + @divTrunc(id - 400000, 16) * 16;
        if (id == Evidence.id("toggle", base)) {
            try disclosure(e, id, Evidence.id("detail", base), "Extraction");
            return true;
        }
    }
    if (id >= 590000 and id < 606000 and s.sources != null and !s.busy) {
        const i: usize = @intCast(@divTrunc(id - 590000, 16));
        if (i >= s.sources.?.value.len) return true;
        const source = s.sources.?.value[i];
        const base = 590000 + @as(i64, @intCast(i)) * 16;
        if (id == StatementEvidence.id("toggle", base)) {
            const title = try std.fmt.allocPrint(e.gpa, "Statement · {s}", .{source.name});
            defer e.gpa.free(title);
            try disclosure(e, id, StatementEvidence.id("body", base), title);
        } else if (id == StatementEvidence.id("save", base)) try invoke(e, .export_pdf, "export_statement", .{ .hash = source.statement_hash });
        return true;
    }
    if (id == eid("close-editor")) {
        try request_close(e);
        return true;
    }
    if (id == eid("save")) {
        try save(e);
        return true;
    }
    if (id == eid("delete")) {
        try show(e, eid("delete-confirm"), true);
        return true;
    }
    if (id == eid("cancel-delete")) {
        try show(e, eid("delete-confirm"), false);
        return true;
    }
    if (id == eid("confirm-delete") and !s.busy) {
        s.busy = true;
        try invoke(e, .delete, "delete_expense", .{ .id = s.current.?.id, .expected_revision = s.current.?.revision });
        return true;
    }
    if (id == eid("receipt-file") or id == eid("camera-file")) {
        if (!s.busy) {
            s.pending_camera = id == eid("camera-file");
            if (s.scan_first and s.dirty and (value(e, eid("field-payee")).len > 0 or value(e, eid("field-amount")).len > 0)) {
                try confirm_editor(e, .replace_image, "Replace the voucher and regenerate this unsaved entry?", "Replace");
            } else try pick_image(e, s.pending_camera);
        }
        return true;
    }
    if (id == eid("remove-image") and !s.busy) {
        s.document = null;
        s.dirty = true;
        try e.tree.setImageData(eid("preview"), null);
        try show(e, eid("pending-evidence"), false);
        try show(e, eid("extraction-details"), false);
        try show(e, eid("capture-choices"), true);
        try show(e, eid("scanner-setup"), s.current == null);
        return true;
    }
    if (id == eid("details-toggle")) {
        s.details_open = !s.details_open;
        try show(e, eid("details-body"), s.details_open);
        try set_text(e, id, if (s.details_open) "More details ▴" else "More details ▾");
        return true;
    }
    if (id == eid("extraction-toggle")) {
        s.extraction_open = !s.extraction_open;
        try show(e, eid("extraction-text"), s.extraction_open);
        try set_text(e, id, if (s.extraction_open) "Extraction ▴" else "Extraction ▾");
        return true;
    }
    if (id == eid("analyze") and s.document != null and !s.busy) {
        if (s.dirty and (value(e, eid("field-payee")).len > 0 or value(e, eid("field-amount")).len > 0)) {
            try confirm_editor(e, .rescan, "Fill in known fields from the image? This may replace your draft values.", "Fill in");
        } else try start_scan(e, true);
        return true;
    }
    if (id == eid("cancel-analysis")) {
        s.scan_cancelled = true;
        try set_text(e, eid("cancel-analysis"), "Cancelling…");
        try invoke(e, .cancel, "cancel_analysis", .{});
        return true;
    }
    if (id == eid("scanner-setup") and !s.busy) {
        try open_scanner(e);
        return true;
    }
    if (id == eid("manual-fallback")) {
        try show_review(e);
        return true;
    }
    return false;
}
fn resolved_safe(e: *ui.Engine, request_id: u32, ok: bool, json: []const u8) !void {
    resolved(e, request_id, ok, json) catch |err| {
        if (std.enums.fromInt(Request, request_id & 0xffff)) |request| {
            finish(request);
            if (request == .scan) try progress.finish(e, false);
        }
        try report_error(e, if (s.modal == .editor) eid("editor-status") else aid("status"), @errorName(err));
    };
}

fn resolved(e: *ui.Engine, raw: u32, ok: bool, json: []const u8) !void {
    const request = std.enums.fromInt(Request, raw & 0xffff) orelse return;
    if ((request == .documents or request == .sources or request == .defaults) and raw >> 16 != s.editor_generation) return;
    if (request == .category_edit) return categories.resolved(e, ok, json);
    try progress.resolved(e, request);
    if (request == .research_run or request == .research_apply or request == .research_source or request == .research_model_status or request == .research_model_action) return research.resolved(e, request, ok, json);
    if (request == .defaults) {
        if (s.modal != .editor) return;
        if (!ok) {
            try set_text(e, eid("editor-status"), json);
            return;
        }
        const defaults = try std.json.parseFromSlice(app.UiDefaults, e.gpa, json, .{});
        defer defaults.deinit();
        if (!s.scan_first and value(e, eid("field-date")).len == 0) try set_value(e, eid("field-date"), defaults.value.date);
        if (value(e, eid("field-account")).len == 0) {
            for (e.tree.get(eid("field-account")).?.props.options orelse &.{}) |option| if (std.mem.eql(u8, option[0], defaults.value.account)) {
                try set_value(e, eid("field-account"), defaults.value.account);
                break;
            };
        }
        return;
    }
    if (request == .snapshot) {
        return resolved_snapshot(e, request, ok, json);
    }
    if (request == .quick_action) {
        return resolved_quick_action(e, request, ok, json);
    }
    if (request == .save or request == .delete or request == .import_legacy) {
        return resolved_mutation(e, request, ok, json);
    }
    if (request == .new_id) {
        return resolved_new_id(e, request, ok, json);
    }
    if (request == .pick_image or request == .pick_legacy) {
        return resolved_picked(e, request, ok, json);
    }
    if (request == .scan) {
        return resolved_scan(e, request, ok, json);
    }
    if (request == .documents) {
        return resolved_documents(e, request, ok, json);
    }
    if (request == .sources) {
        return resolved_sources(e, request, ok, json);
    }
    if (request == .unlink and s.modal == .statement) {
        try tools.statement_unlinked(e, ok, json);
        return;
    }
    if (request == .unlink) {
        return resolved_unlink(e, request, ok, json);
    }
    if (request == .cancel) return;
    try tools.resolved(e, request, ok, json);
}

fn resolved_snapshot(e: *ui.Engine, _: Request, ok: bool, json: []const u8) !void {
    s.refreshing = false;
    if (!ok) {
        try status(e, json);
        return;
    }
    const next = try std.json.parseFromSlice(app.Snapshot, e.gpa, json, .{ .allocate = .alloc_always });
    errdefer next.deinit();
    const config = try std.json.parseFromSlice(reports.Settings, e.gpa, next.value.settings, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (s.snapshot) |old| if (!std.mem.eql(u8, old.value.settings, next.value.settings)) {
        clear_drilldown(e);
    };
    if (s.snapshot) |v| v.deinit();
    if (s.settings) |v| v.deinit();
    s.snapshot = next;
    s.settings = config;
    try period_options(e);
    try render(e);
    try tools.parse_queued(e);
    try recovery.restore_once(e);
    try desktop.advance(e);
    return;
}

fn resolved_quick_action(e: *ui.Engine, _: Request, ok: bool, json: []const u8) !void {
    if (!ok or s.modal != .none) return;
    const action = try std.json.parseFromSlice(?[]const u8, e.gpa, json, .{});
    defer action.deinit();
    if (action.value) |v| {
        if (std.mem.eql(u8, v, "sync")) try tools.open(e, .sync) else if (std.mem.eql(u8, v, "receipt")) try open_capture(e) else try open_editor(e, null);
    }
    return;
}

fn resolved_mutation(e: *ui.Engine, request: Request, ok: bool, json: []const u8) !void {
    finish(request);
    if (!ok) {
        try status(e, json);
        if (s.modal == .editor) try report_error(e, eid("editor-status"), json);
        return;
    }
    try close_modal(e);
    try status(e, if (request == .save) "Payment saved" else if (request == .delete) "Payment deleted" else "Imported");
    try refresh(e);
    return;
}

fn resolved_new_id(e: *ui.Engine, request: Request, ok: bool, json: []const u8) !void {
    finish(request);
    if (!ok) {
        try status(e, json);
        return;
    }
    const id = try std.json.parseFromSliceLeaky([]const u8, s.draft.allocator(), json, .{ .allocate = .alloc_always });
    if (!model.valid_id(id)) return error.InvalidId;
    s.current = .{ .id = id, .date = "", .payee = "", .amount = 0 };
    try save(e);
    return;
}

pub fn attach_image(e: *ui.Engine, file: app.UiFile) !void {
    // Validate with the same ledger decoder and size limit used by saving.
    _ = try @import("core/ledger.zig").image_bytes(s.draft.allocator(), file.data_url);
    s.document = .{ .data_url = try s.draft.allocator().dupe(u8, file.data_url) };
    s.document_name = try s.draft.allocator().dupe(u8, file.name);
    s.dirty = true;
    try set_image(e, eid("preview"), s.document.?.data_url);
    try show(e, eid("pending-evidence"), true);
    try show(e, eid("capture-choices"), false);
    try show(e, eid("scanner-setup"), false);
    redraw(e);
}

fn resolved_picked(e: *ui.Engine, request: Request, ok: bool, json: []const u8) !void {
    finish(request);
    if (!ok) {
        try status(e, json);
        return;
    }
    const file = try std.json.parseFromSliceLeaky(?app.UiFile, s.draft.allocator(), json, .{ .allocate = .alloc_always });
    if (file) |f| {
        if (request == .pick_legacy) {
            s.busy = true;
            try invoke(e, .import_legacy, "import_legacy", .{ .json = f.data_url });
            return;
        }
        try set_image(e, eid("preview"), f.data_url);
        s.document = .{ .data_url = f.data_url };
        s.document_name = f.name;
        s.dirty = true;
        try show(e, eid("pending-evidence"), true);
        try show(e, eid("capture-choices"), false);
        try show(e, eid("scanner-setup"), false);
        try start_scan(e, s.scan_first and s.current == null);
    }
    return;
}

fn open_scanner(e: *ui.Engine) !void {
    s.return_to_editor = true;
    s.editor_dirty = s.dirty;
    e.tree.get(editor_base).?.stamp_owned = false;
    try ui.setVisible(&e.tree, editor_base, false);
    s.modal = .none;
    try tools.open(e, .scanner);
}

fn pick_image(e: *ui.Engine, camera: bool) !void {
    s.busy = true;
    try invoke(e, .pick_image, "ui_pick_file", .{ .kind = if (camera) "camera" else "image" });
}

pub fn confirm_editor(e: *ui.Engine, action: @FieldType(State, "confirm_action"), message: []const u8, button: []const u8) !void {
    s.confirm_action = action;
    s.notice_open = true;
    _ = try Notice.mount(&e.tree, 19000, 78000, &.{.{ .name = "message", .value = message }});
    try set_text(e, Notice.id("confirm", 19000), button);
    try overlay(e);
    redraw(e);
}

fn set_editor_busy(e: *ui.Engine, busy: bool) !void {
    inline for (.{ "save", "delete", "close-editor", "analyze" }) |name| {
        const id = eid(name);
        var props = e.tree.get(id).?.props;
        props.dis = busy;
        props.op = if (busy) 0.38 else 1;
        try e.tree.updateUiProps(id, props);
    }
}

fn start_scan(e: *ui.Engine, fill: bool) !void {
    s.busy = true;
    s.scan_fill = fill;
    s.scan_cancelled = false;
    errdefer {
        s.busy = false;
        progress.finish(e, false) catch {};
    }
    try show(e, eid("cancel-analysis"), true);
    try set_text(e, eid("cancel-analysis"), "Cancel scan");
    try show(e, eid("scan-sweep"), true);
    try show(e, eid("image-actions"), false);
    try show(e, eid("review-fields"), false);
    try show(e, eid("extraction-details"), false);
    try show(e, eid("save"), !s.scan_first);
    try set_editor_busy(e, true);
    try show(e, eid("manual-fallback"), false);
    try set_text(e, eid("editor-status"), "");
    try progress.start(e);
    try invoke(e, .scan, "analyze_receipt", .{ .data_url = s.document.?.data_url, .name = s.document_name });
}

fn resolved_scan(e: *ui.Engine, request: Request, ok: bool, json: []const u8) !void {
    finish(request);
    try set_editor_busy(e, false);
    try progress.finish(e, ok and !s.scan_cancelled);
    try show(e, eid("cancel-analysis"), false);
    try show(e, eid("scan-sweep"), false);
    try show(e, eid("image-actions"), true);
    try show_review(e);
    if (s.scan_cancelled) {
        try set_text(e, eid("editor-status"), "Scan cancelled.");
        return;
    }
    if (!ok) {
        try report_error(e, eid("editor-status"), json);
        inline for (.{ "ScannerNotSetUp", "ModelNotDownloaded", "SystemModelNotReady", "SystemAiUnavailable", "ModelNotImported", "ProjectorNotImported" }) |code| if (std.mem.indexOf(u8, json, code) != null) {
            try open_scanner(e);
            break;
        };
        return;
    }
    const encoded = try std.json.parseFromSliceLeaky([]const u8, s.draft.allocator(), json, .{ .allocate = .alloc_always });
    const result = try std.json.parseFromSliceLeaky(@import("vision.zig").Extraction, s.draft.allocator(), encoded, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (!std.mem.eql(u8, result.currency, "CLP")) return error.UnsupportedCurrency;
    if (s.scan_fill) {
        inline for (.{ "payee", "date", "reference", "location" }) |field| try set_value(e, eid("field-" ++ field), @field(result, field));
        var buf: [32]u8 = undefined;
        try set_value(e, eid("field-amount"), try std.fmt.bufPrint(&buf, "{d}", .{result.amount}));
        if (try reports.suggest_category(s.draft.allocator(), result.payee, settings())) |category| try set_value(e, eid("field-category"), category);
        try set_text(e, eid("category-value"), value(e, eid("field-category")));
        try category_rule_note(e);
    }
    if (s.document) |*doc| doc.extraction = encoded;
    _ = try Text.mount(&e.tree, 18100, 79000, &.{.{ .name = "text", .value = encoded }});
    if (!try e.tree.stampKids(eid("extraction-text"), &.{18100})) return error.InvalidTemplate;
    try show(e, eid("extraction-details"), true);
    try show(e, eid("extraction-text"), false);
    try set_text(e, eid("extraction-toggle"), "Extraction ▾");
    s.extraction_open = false;
    s.dirty = true;
    try set_text(e, eid("editor-title"), "Check & save");
    try set_text(e, eid("editor-status"), if (s.scan_fill) "Check the amount, payee and date." else "Scanned. Your details were kept.");
    return;
}

fn resolved_documents(e: *ui.Engine, _: Request, ok: bool, json: []const u8) !void {
    if (!ok or s.modal != .editor) return;
    const docs = try std.json.parseFromSlice([]model.Document, e.gpa, json, .{ .allocate = .alloc_always });
    defer docs.deinit();
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(e.gpa);
    s.document_count = docs.value.len;
    for (docs.value, 0..) |doc, i| {
        const base = 400000 + @as(i64, @intCast(i)) * 16;
        _ = try Evidence.mount(&e.tree, base, 71000, &.{.{ .name = "detail", .value = "" }});
        try set_text(e, Evidence.id("detail", base), doc.extraction);
        try show(e, Evidence.id("detail", base), false);
        try show(e, Evidence.id("toggle", base), doc.extraction.len > 0);
        try set_text(e, Evidence.id("toggle", base), "Extraction ▾");
        try mark_action(e, Evidence.id("toggle", base), "Extraction");
        try set_image(e, Evidence.id("image", base), doc.data_url);
        try ids.append(e.gpa, base);
    }
    if (!try e.tree.stampKids(EvidencePanel.id("documents", 18000), ids.items)) return error.InvalidTemplate;
    return;
}

fn resolved_sources(e: *ui.Engine, _: Request, ok: bool, json: []const u8) !void {
    if (s.modal != .editor or !ok) return;
    const sources = try std.json.parseFromSlice([]@import("core/statements.zig").PaymentSource, e.gpa, json, .{ .allocate = .alloc_always });
    if (s.sources) |v| v.deinit();
    s.sources = sources;
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(e.gpa);
    for (sources.value, 0..) |source, i| {
        const base = 590000 + @as(i64, @intCast(i)) * 16;
        _ = try StatementEvidence.mount(&e.tree, base, 76100, &.{ .{ .name = "title", .value = "" }, .{ .name = "detail", .value = "" } });
        const title = try std.fmt.allocPrint(e.gpa, "Statement · {s} ▾", .{source.name});
        defer e.gpa.free(title);
        try set_text(e, StatementEvidence.id("toggle", base), title);
        try set_text(e, StatementEvidence.id("detail", base), source.source_json);
        try show(e, StatementEvidence.id("body", base), false);
        try mark_actions(e, StatementEvidence, base, .{ "toggle", "save" });
        try ids.append(e.gpa, base);
    }
    if (!try e.tree.stampKids(EvidencePanel.id("statements", 18000), ids.items)) return error.InvalidTemplate;
    return;
}

fn resolved_unlink(e: *ui.Engine, request: Request, ok: bool, json: []const u8) !void {
    finish(request);
    if (ok and s.current != null) {
        try invoke(e, .sources, "expense_statements", .{ .id = s.current.?.id });
        try refresh(e);
    } else if (!ok) try status(e, json);
    return;
}
test "parser dispatch OOM rolls back its owned map key and can retry" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1180, 820);
    defer e.destroy();
    try boot(e);
    var sources = [_]@import("core/statements.zig").Source{.{ .hash = &model.digest("queued"), .name = "Synthetic PDF", .status = "queued" }};
    const snap: app.Snapshot = .{ .expenses = &.{}, .settings = "{}", .platform = "linux", .vision_available = false, .tray_running = false, .statements = &sources };
    const json = try std.json.Stringify.valueAlloc(a, snap, .{});
    defer a.free(json);
    s.busy = true;
    try resolved(e, @intFromEnum(Request.snapshot), true, json);
    s.busy = false;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 2 });
    e.gpa = failing.allocator();
    const result = tools.parse_queued(e);
    e.gpa = a;
    try std.testing.expectError(error.OutOfMemory, result);
    try tools.parse_queued(e);
    try std.testing.expectEqualStrings("parse_statement", host.command);
}

test "stale statement and sync replies cannot invalidate a preferences draft" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1180, 820);
    defer e.destroy();
    try boot(e);
    const snap: app.Snapshot = .{ .expenses = &.{}, .settings = "{\"salary\":1234}", .platform = "linux", .vision_available = false, .tray_running = false, .statements = &.{} };
    const json = try std.json.Stringify.valueAlloc(a, snap, .{});
    defer a.free(json);
    try resolved(e, @intFromEnum(Request.snapshot), true, json);
    _ = try handle_event(e, aid("pref-budget"), "click", "0");
    try resolved(e, @intFromEnum(Request.observations), true, "[]");
    try resolved(e, @intFromEnum(Request.sync_conflict), true, "\"not a conflict\"");
    try std.testing.expect(s.modal == .preferences);
    const Preferences = ui.View(@embedFile("preferences-dialog.oriel"));
    _ = try handle_event(e, Preferences.id("save-preferences", 11000), "click", "0");
    const edit = try std.json.parseFromSlice(@import("core/preferences.zig").Edit, a, host.args, .{});
    defer edit.deinit();
    try std.testing.expectEqual(@as(i64, 1234), edit.value.settings.salary);
    try std.testing.expectEqualStrings(snap.settings, edit.value.expected);
}

const TestHost = struct {
    request: u32 = 0,
    command: []const u8 = "",
    args: []const u8 = "",
    allocator: std.mem.Allocator,
    fn measure(_: *anyopaque, _: *ui.Node, _: f32, out: *[2]f32) void {
        out.* = .{ 80, 20 };
    }
    fn laid(_: *anyopaque) void {}
    fn removed(_: *anyopaque, _: *ui.Node) void {}
    fn timer(_: *anyopaque, _: *ui.Engine, _: u32, _: u32) void {}
    fn focus(_: *anyopaque, _: *ui.Node) void {}
    fn dispatch(ctx: *anyopaque, _: *ui.Engine, request: u32, command: []const u8, args: []const u8) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        if (h.command.len > 0) h.allocator.free(h.command);
        if (h.args.len > 0) h.allocator.free(h.args);
        h.request = request;
        h.command = h.allocator.dupe(u8, command) catch unreachable;
        h.args = h.allocator.dupe(u8, args) catch unreachable;
    }
    fn deinit(h: *TestHost) void {
        if (h.command.len > 0) h.allocator.free(h.command);
        if (h.args.len > 0) h.allocator.free(h.args);
    }
};
test "compiled views retain revisions, dirty drafts and filters across responsive changes" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1180, 820);
    defer e.destroy();
    try boot(e);
    const row: model.Expense = .{ .id = &model.digest("view-test"), .date = "2026-10-17", .amount = 12345, .payee = "Market", .account = "1234", .revision = 7 };
    var rows = [_]model.Expense{row};
    const snapshot: app.Snapshot = .{ .expenses = &rows, .settings = "{\"salary\":100000,\"cards_config\":{\"1234\":\"Household\"}}", .platform = "linux", .vision_available = false, .tray_running = false, .statements = &.{} };
    const json = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(json);
    try resolved(e, @intFromEnum(Request.snapshot), true, json);
    try std.testing.expectEqualStrings("2026-10", value(e, aid("month")));
    try std.testing.expect(!e.tree.get(aid("receipt-count")).?.props.none);
    try std.testing.expectEqual(@as(usize, 1), s.selected.items.len);
    const scan_hit = e.tree.hit(48, 112) orelse return error.ScanActionOccluded;
    try std.testing.expect(inside(scan_hit, aid("new-receipt")));
    try open_editor(e, row);
    try set_value(e, eid("field-amount"), "54321");
    s.dirty = true;
    _ = try handle_event(e, e.tree.get(eid("save")).?.kids.items[0].id, "click", "0");
    const edit = try std.json.parseFromSlice(model.Save, a, host.args, .{});
    defer edit.deinit();
    try std.testing.expectEqual(@as(i64, 7), edit.value.expected_revision);
    try std.testing.expectEqual(@as(i64, 54321), edit.value.expense.amount);
    // A rejected stale write must leave the complete draft open.
    try resolved(e, @intFromEnum(Request.save), false, "RevisionConflict");
    try std.testing.expectEqual(Modal.editor, s.modal);
    try std.testing.expectEqualStrings("54321", value(e, eid("field-amount")));
    try request_close(e);
    try std.testing.expect(s.notice_open);
    _ = try click(e, Notice.id("cancel", 19000));
    try std.testing.expectEqual(Modal.editor, s.modal);
    try request_close(e);
    _ = try click(e, Notice.id("confirm", 19000));
    try std.testing.expectEqual(Modal.none, s.modal);
    e.tree.width = 393;
    e.tree.height = 820;
    try resized(e);
    try std.testing.expectEqualStrings("2026-10", value(e, aid("month")));
    try navigate(e, .payments);
    _ = try handle_event(e, aid("search"), "input", "\"missing\"");
    try std.testing.expectEqual(@as(usize, 0), s.selected.items.len);
    _ = try handle_event(e, aid("search"), "input", "\"market\"");
    try std.testing.expectEqual(@as(usize, 1), s.selected.items.len);
    try e.setColorScheme(true);
    try resized(e);
    try std.testing.expectEqualStrings("market", value(e, aid("search")));
    // Reopening mounts a clean editor; the old evidence response is ignored.
    const old_generation = s.editor_generation;
    try open_editor(e, row);
    try resolved(e, (@as(u32, old_generation) << 16) | @intFromEnum(Request.documents), true, "[]");
    try std.testing.expectEqualStrings("12345", value(e, eid("field-amount")));
}

test "settings and bulk previews preserve imported rules and do not write before confirmation" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1180, 820);
    defer e.destroy();
    try boot(e);
    const row: model.Expense = .{ .id = &model.digest("preview-test"), .date = "2026-10-17", .amount = 100, .payee = "Market", .account = "1234", .revision = 7 };
    var rows = [_]model.Expense{row};
    const config = "{\"salary\":1000,\"categories\":{\"Food\":[\"one,two\",\"three\"]}}";
    const snapshot: app.Snapshot = .{ .expenses = &rows, .settings = config, .platform = "linux", .vision_available = false, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    try tools.open_category_rules(e);
    try std.testing.expectEqual(Modal.preferences, s.modal);
    const Preferences = ui.View(@embedFile("preferences-dialog.oriel"));
    _ = try handle_event(e, e.tree.get(Preferences.id("save-preferences", 11000)).?.kids.items[0].id, "click", "0");
    const edit = try std.json.parseFromSlice(@import("core/preferences.zig").Edit, a, host.args, .{});
    defer edit.deinit();
    try std.testing.expectEqualStrings(config, edit.value.expected);
    try std.testing.expectEqualStrings("one,two", edit.value.settings.categories.object.get("Food").?.array.items[0].string);
    try std.testing.expectEqual(@as(usize, 2), edit.value.settings.categories.object.get("Food").?.array.items.len);
    try resolved(e, @intFromEnum(Request.settings), false, "SettingsConflict");
    try std.testing.expectEqual(Modal.preferences, s.modal);
    try close_modal(e);
    try navigate(e, .payments);
    try set_value(e, aid("bulk-pattern"), "Market");
    try set_value(e, aid("bulk-category"), "Food");
    const prior_request = host.request;
    _ = try handle_event(e, aid("bulk-preview-button"), "click", "0");
    try std.testing.expectEqual(Modal.none, s.modal);
    try std.testing.expect(!e.tree.get(aid("bulk-preview")).?.props.none);
    try std.testing.expectEqual(prior_request, host.request);
    // Opening another settings view must not invalidate the frozen preview arena.
    try tools.open_category_rules(e);
    const Mapping = ui.View(@embedFile("mapping.oriel"));
    const long_keywords: [24000]u8 = @splat('x');
    try set_value(e, Mapping.id("value", 20000000), &long_keywords);
    try std.testing.expectEqualStrings(&long_keywords, value(e, Mapping.id("value", 20000000)));
    try close_modal(e);
    _ = try handle_event(e, aid("bulk-apply"), "click", "0");
    const batch = try std.json.parseFromSlice(@import("core/preferences.zig").Edit, a, host.args, .{});
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 1), batch.value.targets.len);
    try std.testing.expectEqual(@as(i64, 7), batch.value.targets[0].revision);
    try std.testing.expectEqualStrings(config, batch.value.expected);
}

test "scan action starts capture and manual fallback exposes save" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 393, 820);
    defer e.destroy();
    try boot(e);
    const snapshot: app.Snapshot = .{ .expenses = &.{}, .settings = "{}", .platform = "linux", .vision_available = false, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    _ = try handle_event(e, aid("new-receipt"), "click", "0");
    try std.testing.expectEqual(Modal.editor, s.modal);
    try std.testing.expect(e.tree.get(eid("review-fields")).?.props.none);
    try std.testing.expect(e.tree.get(eid("save")).?.props.none);
    _ = try handle_event(e, eid("manual-fallback"), "click", "0");
    try std.testing.expect(!e.tree.get(eid("review-fields")).?.props.none);
    try std.testing.expect(!e.tree.get(eid("save")).?.props.none);
}

test "Insights keeps web chart geometry, percentages and exact row actions" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 393, 820);
    defer e.destroy();
    try boot(e);
    var rows = [_]model.Expense{
        .{ .id = &model.digest("report-a"), .date = "2026-10-17", .amount = 60000, .payee = "Restaurant A", .account = "1234", .category = "Dining", .revision = 1 },
        .{ .id = &model.digest("report-b"), .date = "2026-10-17", .amount = 40000, .payee = "Restaurant B", .account = "5678", .category = "Dining", .revision = 1 },
        .{ .id = &model.digest("report-c"), .date = "2026-10-17", .amount = 5000, .payee = "Family", .account = "1234", .category = "Other", .revision = 1 },
    };
    const snapshot: app.Snapshot = .{ .expenses = &rows, .settings = "{\"cards_config\":{\"1234\":\"Household\",\"5678\":\"Household\"},\"special_cases\":{\"Family\":\"Family\"}}", .platform = "android", .vision_available = false, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    try navigate(e, .insights);
    const DonutView = ui.View(@embedFile("donut.oriel"));
    const ReportView = ui.View(@embedFile("report-row.oriel"));
    try std.testing.expectEqual(@as(f32, 168), e.tree.get(DonutView.id("chart", 580000)).?.frame.w);
    // Export already folds the first donut margin into the title's margin.
    try std.testing.expectEqual(e.tree.get(aid("account-chart")).?.frame.y, e.tree.get(DonutView.id("chart", 580000)).?.frame.y);
    try std.testing.expectEqualStrings("$100.000", e.tree.get(DonutView.id("total", 580000)).?.props.runs.?[0].t);
    try std.testing.expect(!e.tree.get(ReportView.id("legend", 6000000)).?.props.none);
    const detail = e.tree.get(ReportView.id("detail", 6000000)).?.kids.items[0];
    try std.testing.expectEqualStrings("60%", detail.props.runs.?[0].t);
    // Two cards with the same owner stay separate, just as in WebKit.
    try std.testing.expectEqual(@as(usize, 3), e.tree.get(aid("account-chart")).?.kids.items.len);
    // Clicking the label bubbles to the entire report row, without a View control.
    _ = try handle_event(e, ReportView.id("title", 6000000), "click", "0");
    try std.testing.expectEqual(Page.payments, s.page);
    try std.testing.expectEqual(@as(usize, 1), s.selected.items.len);
    try std.testing.expect(e.back()); // Back returns to the report it came from.
    try std.testing.expectEqual(Page.insights, s.page);
    try std.testing.expect(!s.drill_active);
    try navigate(e, .insights);
    _ = try handle_event(e, 14000000, "click", "0");
    try std.testing.expectEqual(Modal.editor, s.modal);
    try std.testing.expectEqualStrings(rows[2].id, s.current.?.id);
    try close_modal(e);
    try e.setColorScheme(true);
    try resized(e);
    try std.testing.expectEqualStrings("$100.000", e.tree.get(DonutView.id("total", 580000)).?.props.runs.?[0].t);
}

test "phone filters scroll horizontally and disclosures preserve state" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 393, 820);
    defer e.destroy();
    try boot(e);
    var rows = [_]model.Expense{.{ .id = &model.digest("alignment"), .date = "2026-10-17", .amount = 53970, .payee = "A long restaurant name that needs to be truncated", .account = "1234", .category = "Dining", .revision = 1 }};
    const snapshot: app.Snapshot = .{ .expenses = &rows, .settings = "{}", .platform = "android", .vision_available = false, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    for ([_]f32{ 320, 393 }) |width| {
        e.tree.width = width;
        try resized(e);
        try navigate(e, .payments);
        const filters = e.tree.get(aid("category-filter")).?.parent.?.parent.?;
        try std.testing.expect(filters.props.scrollx);
        try std.testing.expect(filters.content_w > filters.frame.w);
        try std.testing.expect(e.tree.get(aid("range-body")).?.props.none);
        _ = try handle_event(e, aid("range-toggle"), "click", "0");
        try std.testing.expect(!e.tree.get(aid("range-body")).?.props.none);
        _ = try handle_event(e, aid("range-toggle"), "click", "0");
        try std.testing.expect(e.tree.get(aid("bulk-details-body")).?.props.none);
        _ = try handle_event(e, aid("bulk-details-toggle"), "click", "0");
        try std.testing.expect(!e.tree.get(aid("bulk-details-body")).?.props.none);
        _ = try handle_event(e, aid("bulk-details-toggle"), "click", "0");
        try navigate(e, .insights);
        const merchants = e.tree.get(aid("merchant-category")).?.parent.?.parent.?;
        try std.testing.expect(merchants.props.scrollx);
    }
}

test "large receipt preview scans, animates and returns a review with disclosures" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 393, 820);
    defer e.destroy();
    try boot(e);
    const snapshot: app.Snapshot = .{ .expenses = &.{}, .settings = "{}", .platform = "android", .vision_available = true, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    try std.testing.expect(e.tree.get(aid("quit")).?.props.none);
    try std.testing.expect(e.tree.get(aid("hide-to-tray")).?.props.none);
    try open_capture(e);
    const padding: [65536]u8 = @splat('A');
    const uri = try std.fmt.allocPrint(a, "data:image/jpeg;base64,/9j/{s}", .{padding});
    defer a.free(uri);
    const picked = try std.json.Stringify.valueAlloc(a, app.UiFile{ .name = "test.jpg", .data_url = uri }, .{});
    defer a.free(picked);
    const callback = try a.dupe(u8, picked);
    defer a.free(callback);
    try resolved(e, @intFromEnum(Request.pick_image), true, callback);
    @memset(callback, 'x');
    try std.testing.expectEqualStrings(uri, s.document.?.data_url);
    try std.testing.expectEqual(Request.scan, s.busy_owner.?);
    try std.testing.expect(e.tree.get(eid("preview")).?.ui_image_data.?.len > 8192);
    try std.testing.expect(e.tree.get(eid("review-fields")).?.props.none);
    try std.testing.expect(!e.tree.get(eid("scan-sweep")).?.props.none);
    try std.testing.expect(!e.tree.get(progress.base).?.props.none);
    e.displayFrame(16.67);
    const answer = try std.json.Stringify.valueAlloc(a, "{\"amount\":74404,\"date\":\"2026-10-17\",\"payee\":\"Example cafe\"}", .{});
    defer a.free(answer);
    try resolved(e, @intFromEnum(Request.scan), true, answer);
    try std.testing.expect(!s.busy);
    try std.testing.expect(!e.tree.get(eid("analyze")).?.props.dis);
    try std.testing.expect(e.tree.get(progress.base).?.props.none);
    try std.testing.expectEqualStrings("74404", value(e, eid("field-amount")));
    try std.testing.expect(!e.tree.get(eid("review-fields")).?.props.none);
    try std.testing.expect(e.tree.get(eid("details-body")).?.props.none);
    _ = try handle_event(e, eid("details-toggle"), "click", "0");
    try std.testing.expect(!e.tree.get(eid("details-body")).?.props.none);
    _ = try handle_event(e, eid("extraction-toggle"), "click", "0");
    try std.testing.expect(!e.tree.get(eid("extraction-text")).?.props.none);
    _ = try handle_event(e, eid("analyze"), "click", "0");
    try std.testing.expect(s.notice_open);
    _ = try handle_event(e, Notice.id("confirm", 19000), "click", "0");
    try std.testing.expect(s.busy);
    _ = try handle_event(e, eid("cancel-analysis"), "click", "0");
    try resolved(e, @intFromEnum(Request.scan), true, answer);
    try std.testing.expectEqualStrings("74404", value(e, eid("field-amount")));
    try std.testing.expect(s.scan_cancelled);
    s.dirty = false;
    try close_modal(e);
    const payment: model.Expense = .{ .id = &model.digest("existing-receipt"), .payee = "Manual payee", .amount = 123, .date = "2026-10-01", .account = "1234", .revision = 3 };
    try open_editor(e, payment);
    const capture = e.tree.get(eid("capture-choices")).?;
    try std.testing.expectEqual(capture.id, capture.parent.?.kids.items[capture.parent.?.kids.items.len - 1].id);
    try std.testing.expectEqual(@as(f32, 64), capture.kids.items[0].props.minh.?.px);
    try std.testing.expect(e.tree.get(eid("scanner-setup")).?.props.none);
    try resolved(e, @intFromEnum(Request.pick_image), true, picked);
    try resolved(e, @intFromEnum(Request.scan), true, answer);
    try std.testing.expectEqualStrings("123", value(e, eid("field-amount")));
    try std.testing.expectEqualStrings("Manual payee", value(e, eid("field-payee")));
    const sources_json = "[{\"id\":\"source\",\"statement_hash\":\"hash\",\"name\":\"Example statement\",\"source_json\":\"{}\"}]";
    try resolved(e, (@as(u32, s.editor_generation) << 16) | @intFromEnum(Request.sources), true, sources_json);
    try std.testing.expect(e.tree.get(StatementEvidence.id("body", 590000)).?.props.none);
    _ = try handle_event(e, StatementEvidence.id("toggle", 590000), "click", "0");
    try std.testing.expect(!e.tree.get(StatementEvidence.id("body", 590000)).?.props.none);
    _ = try handle_event(e, StatementEvidence.id("save", 590000), "click", "0");
    try std.testing.expectEqualStrings("export_statement", host.command);
    try std.testing.expectEqualStrings("{\"hash\":\"hash\"}", host.args);
    s.dirty = false;
    try close_modal(e);
    try open_editor(e, null);
    var id_json: [66]u8 = undefined;
    id_json[0] = '"';
    id_json[65] = '"';
    @memcpy(id_json[1..65], &model.digest("new-payment"));
    try std.testing.expectError(error.InvalidAmount, resolved(e, @intFromEnum(Request.new_id), true, &id_json));
    @memset(&id_json, 'x');
    try std.testing.expect(model.valid_id(s.current.?.id));
    try set_value(e, eid("field-payee"), "Manual");
    try set_value(e, eid("field-date"), "2026-10-17");
    try set_value(e, eid("field-account"), "1234");
    try set_value(e, eid("field-amount"), "123");
    try save(e);
    const created = try std.json.parseFromSlice(model.Save, a, host.args, .{});
    defer created.deinit();
    try std.testing.expect(model.valid_id(created.value.expense.id));
}

test "fixed drilldown, category suggestions and scanner actions follow the web flows" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 393, 820);
    defer e.destroy();
    try boot(e);
    const row: model.Expense = .{ .id = &model.digest("fixed-view"), .date = "2026-10-17", .amount = 100, .payee = "RENT", .account = "1234", .category = "Housing" };
    var rows = [_]model.Expense{row};
    const snapshot: app.Snapshot = .{ .expenses = &rows, .settings = "{\"salary\":1000,\"fixed_expenses_items\":[{\"name\":\"Rent\",\"amount\":300,\"keywords\":[\"RENT\"]}],\"categories\":{\"Food\":[],\"Housing\":[]}}", .platform = "android", .vision_available = true, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    _ = try handle_event(e, aid("open-fixed"), "click", "0");
    try std.testing.expectEqual(Modal.fixed, s.modal);
    _ = try handle_event(e, 610000, "click", "0");
    try std.testing.expectEqual(Modal.none, s.modal);
    try std.testing.expect(s.drill_active);
    try std.testing.expectEqual(@as(usize, 1), s.selected.items.len);
    try open_editor(e, row);
    _ = try handle_event(e, eid("choose-category"), "click", "0");
    try std.testing.expect(categories.active);
    _ = try handle_event(e, categories.id("search"), "input", "\"Fo\"");
    _ = try handle_event(e, 25000000, "click", "0");
    try std.testing.expectEqualStrings("Food", value(e, eid("field-category")));
    try std.testing.expect(!categories.active);
    try std.testing.expectEqualStrings("Food", e.tree.get(eid("category-value")).?.props.runs.?[0].t);
    s.dirty = false;
    try close_modal(e);
    _ = try handle_event(e, aid("open-scanner"), "click", "0");
    const Scanner = @import("scanner.zig");
    const status_value: Scanner.Status = .{ .selected = "test", .active = "test", .vision_built = true, .system = .{ .supported = false, .state = "unavailable", .reason = "" }, .models = &.{.{ .id = "test", .label = "Test model", .note = "Ready", .mb = 100, .installed = true, .partial_mb = 0 }}, .custom = false, .downloading = "", .gpu = "", .use_gpu = false, .free_mb = 1000, .fast_available = true, .fast = true };
    const payload = try std.json.Stringify.valueAlloc(a, status_value, .{});
    defer a.free(payload);
    const reply = try std.json.Stringify.valueAlloc(a, payload, .{});
    defer a.free(reply);
    try resolved(e, @intFromEnum(Request.scanner_status), true, reply);
    const ScanRow = ui.View(@embedFile("scanner-row.oriel"));
    _ = try handle_event(e, ScanRow.id("secondary", 480000), "click", "0");
    try std.testing.expect(s.notice_open);
    const before = host.request;
    // A tap lands on a button's label, the engine's hit leaf: it still
    // answers the dialog (the click walks up to the button).
    const label = struct {
        fn of(engine: *ui.Engine, button: i64) i64 {
            return engine.tree.get(button).?.kids.items[0].id;
        }
    }.of;
    _ = try handle_event(e, label(e, Notice.id("cancel", 19000)), "click", "0");
    try std.testing.expect(!s.notice_open);
    try std.testing.expectEqual(before, host.request);
    _ = try handle_event(e, ScanRow.id("secondary", 480000), "click", "0");
    _ = try handle_event(e, label(e, Notice.id("confirm", 19000)), "click", "0");
    try std.testing.expectEqualStrings("scanner_delete", host.command);
}

test "Android Back unwinds sheets and protects unsaved drafts before leaving Home" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 393, 740);
    defer e.destroy();
    try boot(e);
    const snapshot: app.Snapshot = .{ .expenses = &.{}, .settings = "{}", .platform = "android", .vision_available = false, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    try std.testing.expect(!e.back());
    try navigate(e, .settings);
    _ = try click(e, aid("pref-vendors"));
    try std.testing.expectEqual(Modal.preferences, s.modal);
    try std.testing.expect(e.back());
    try std.testing.expectEqual(Modal.none, s.modal);
    try std.testing.expectEqual(Page.settings, s.page);
    _ = try click(e, aid("pref-vendors"));
    s.dirty = true;
    try std.testing.expect(e.back());
    try std.testing.expect(s.notice_open);
    // Under the dialog the sheet's controls stay drawn, out of Tab's reach.
    const covered = blk: {
        var it = e.tree.nodes.valueIterator();
        while (it.next()) |n| if ((n.*.kind == .input or n.*.kind == .button) and inside(n.*, tools.modal_id(.preferences).?)) break :blk n.*.id;
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(e.tree.get(covered).?.props.vis != false);
    try std.testing.expectEqual(@as(?i32, -1), e.tree.get(covered).?.props.ti);
    try std.testing.expectEqual(Modal.preferences, s.modal);
    try std.testing.expect(e.back()); // Cancel the prompt, keep the draft.
    try std.testing.expect(!s.notice_open);
    try std.testing.expectEqual(@as(?i32, null), e.tree.get(covered).?.props.ti);
    try std.testing.expect(s.dirty);
    try std.testing.expectEqual(Modal.preferences, s.modal);
    try std.testing.expect(e.back());
    _ = try click(e, Notice.id("confirm", 19000));
    try std.testing.expectEqual(Modal.none, s.modal);
    try std.testing.expect(e.back());
    try std.testing.expectEqual(Page.home, s.page);
    inline for (.{ Page.payments, Page.insights, Page.settings }) |page| {
        try navigate(e, page);
        try std.testing.expect(e.back());
        try std.testing.expectEqual(Page.home, s.page);
    }
    try navigate(e, .settings);
    inline for (.{ Modal.fixed, Modal.statements, Modal.scanner, Modal.sync }) |modal| {
        try tools.open(e, modal);
        try std.testing.expect(e.back());
        try std.testing.expectEqual(Modal.none, s.modal);
        try std.testing.expectEqual(Page.settings, s.page);
    }
    try open_editor(e, null);
    try open_scanner(e);
    try std.testing.expect(e.back());
    try std.testing.expectEqual(Modal.editor, s.modal);
    s.busy = true;
    try std.testing.expect(e.back()); // An in-flight operation cannot exit the app.
    try std.testing.expectEqual(Modal.editor, s.modal);
    s.busy = false;
    try std.testing.expect(e.back());
    try std.testing.expectEqual(Modal.none, s.modal);
}

test "research review keeps drafts, cancels Back and applies only selected revisions" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1180, 820);
    defer e.destroy();
    try boot(e);
    const row: model.Expense = .{ .id = &model.digest("research-view"), .date = "2026-10-18", .amount = 100, .payee = "DECATHLON", .revision = 3 };
    const next_row: model.Expense = .{ .id = &model.digest("research-next"), .date = "2026-10-18", .amount = 100, .payee = "Next merchant", .revision = 1 };
    var rows = [_]model.Expense{ row, next_row };
    const config = "{\"categories\":{\"Sports\":[]}}";
    const snapshot: app.Snapshot = .{ .expenses = &rows, .settings = config, .platform = "android", .vision_available = false, .tray_running = false, .statements = &.{} };
    const json = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(json);
    try resolved(e, @intFromEnum(Request.snapshot), true, json);
    try navigate(e, .payments);
    e.tree.width = 393;
    try resized(e);
    try std.testing.expect(!e.tree.get(aid("research-open")).?.props.none);
    try std.testing.expect(e.tree.get(aid("research-open")).?.frame.w > 0);
    _ = try click(e, aid("research-open"));
    try std.testing.expectEqual(Modal.research, s.modal);
    const Sheet = ui.View(@embedFile("research-dialog.oriel"));
    const Row = ui.View(@embedFile("research-proposal.oriel"));
    try std.testing.expect(e.tree.get(Sheet.id("model-controls", 20000)).?.props.none);
    try std.testing.expect(e.tree.get(Sheet.id("details", 20000)).?.props.none);
    _ = try click(e, Sheet.id("details-toggle", 20000));
    try std.testing.expect(!e.tree.get(Sheet.id("details", 20000)).?.props.none);
    _ = try click(e, Sheet.id("details-toggle", 20000));
    const close_frame = e.tree.get(Sheet.id("close", 20000)).?.frame;
    const close_hit = e.tree.hit(close_frame.x + close_frame.w / 2, close_frame.y + close_frame.h / 2) orelse return error.ResearchSheetOccluded;
    try std.testing.expect(inside(close_hit, 20000));
    const model_status_json = try std.json.Stringify.valueAlloc(a, @import("research_model.zig").Status{ .label = "Qwen3.5 9B", .ready = true, .custom = false, .downloading = false, .size_mb = 5417 }, .{});
    defer a.free(model_status_json);
    const model_status_wire = try std.json.Stringify.valueAlloc(a, model_status_json, .{});
    defer a.free(model_status_wire);
    try resolved(e, @intFromEnum(Request.research_model_status), true, model_status_wire);
    try set_value(e, aid("category-filter"), "Sports");
    try render(e);
    try std.testing.expectEqual(@as(usize, 0), s.selected.items.len);
    _ = try click(e, Sheet.id("start", 20000));
    try std.testing.expectEqualStrings("research_model_status", host.command);
    try std.testing.expect(!s.busy and !research.running);
    try std.testing.expect(e.tree.get(Sheet.id("activity-panel", 20000)).?.props.none);
    try std.testing.expect(std.mem.indexOf(u8, e.tree.get(Sheet.id("status", 20000)).?.props.runs.?[0].t, "current filters") != null);
    try set_value(e, aid("category-filter"), "");
    try render(e);
    _ = try click(e, Sheet.id("start", 20000));
    try std.testing.expect(!e.tree.get(Sheet.id("activity-panel", 20000)).?.props.none);
    try std.testing.expectEqualStrings("research_categories", host.command);
    try std.testing.expect(s.busy);
    const activity_event = try std.json.parseFromSlice(std.json.Value, a, "{\"stage\":\"Searching web\",\"merchant\":\"DECATHLON\",\"detail\":\"Merchant business query\",\"completed\":0,\"total\":1}", .{});
    defer activity_event.deinit();
    for (0..12) |_| try research.progress(e, activity_event.value);
    try std.testing.expect(e.tree.get(Sheet.id("activity-scroll", 20000)).?.frame.h <= 360);
    try std.testing.expectEqualStrings("0/1 merchants complete · update 12", e.tree.get(Sheet.id("progress", 20000)).?.props.runs.?[0].t);
    try std.testing.expectEqualStrings("DECATHLON", e.tree.get(Sheet.id("merchant", 20000)).?.props.runs.?[0].t);
    try std.testing.expect(std.mem.indexOf(u8, e.tree.get(Sheet.id("activity", 20000)).?.props.runs.?[0].t, "DECATHLON") != null);
    _ = try handle_event(e, 0, "message", "{\"__oriel_event\":\"research_progress\",\"payload\":{\"stage\":\"Reading source\",\"merchant\":\"Next merchant\",\"completed\":1,\"total\":2}}");
    try std.testing.expectEqualStrings("1/2 merchants complete · update 13", e.tree.get(Sheet.id("progress", 20000)).?.props.runs.?[0].t);
    try std.testing.expectEqualStrings("Next merchant", e.tree.get(Sheet.id("merchant", 20000)).?.props.runs.?[0].t);
    try std.testing.expect(std.mem.startsWith(u8, e.tree.get(Sheet.id("activity", 20000)).?.props.runs.?[0].t, "Next merchant"));
    try std.testing.expect(e.tree.get(Sheet.id("start", 20000)).?.props.none);
    try std.testing.expect(e.back());
    try std.testing.expectEqualStrings("cancel_research", host.command);
    const domain = @import("core/categorization.zig");
    const result = domain.Review{ .expected_settings = config, .proposals = &.{.{ .merchant = row.payee, .targets = &.{.{ .id = row.id, .revision = 3 }}, .category = "Sports", .reason = "Merchant sells sports equipment", .sources = &.{ .{ .url = "https://www.decathlon.cl/", .quote = "Sports equipment" }, .{ .url = "https://www.decathlon.cl/deportes", .title = "Merchant source title " ** 15, .quote = "Sports catalog" } } }} };
    const encoded = try std.json.Stringify.valueAlloc(a, result, .{});
    defer a.free(encoded);
    const wire = try std.json.Stringify.valueAlloc(a, encoded, .{});
    defer a.free(wire);
    try resolved(e, @intFromEnum(Request.research_run), true, wire);
    try std.testing.expect(!s.busy);
    try std.testing.expect(!e.tree.get(Sheet.id("start", 20000)).?.props.none);
    try std.testing.expectEqualStrings("Batch complete · review suggestions below", e.tree.get(Sheet.id("progress", 20000)).?.props.runs.?[0].t);
    try std.testing.expectEqualStrings("Sports", value(e, Row.id("category", 29000000)));
    const Source = ui.View(@embedFile("research-source.oriel"));
    try std.testing.expect(e.tree.get(Source.id("body", 29010016)).?.props.none);
    _ = try click(e, Source.id("toggle", 29010016));
    try std.testing.expect(!e.tree.get(Source.id("body", 29010016)).?.props.none);
    _ = try click(e, Source.id("open", 29010016));
    try std.testing.expectEqualStrings("open_research_source", host.command);
    try std.testing.expect(std.mem.indexOf(u8, host.args, "https://www.decathlon.cl/deportes") != null);
    try std.testing.expect(e.back());
    try std.testing.expect(s.notice_open);
    try std.testing.expect(e.back());
    try std.testing.expectEqual(Modal.research, s.modal);
    _ = try click(e, Sheet.id("apply", 20000));
    try std.testing.expectEqualStrings("apply_research", host.command);
    const edit = try std.json.parseFromSlice(domain.Apply, a, host.args, .{});
    defer edit.deinit();
    try std.testing.expectEqual(@as(i64, 3), edit.value.selections[0].targets[0].revision);
    try std.testing.expectEqualStrings(config, edit.value.expected_settings);
    try resolved(e, @intFromEnum(Request.research_apply), false, "RevisionConflict");
    try std.testing.expectEqualStrings("Sports", value(e, Row.id("category", 29000000)));
    try std.testing.expect(!s.busy);
    try set_value(e, Row.id("category", 29000000), "");
    _ = try click(e, Sheet.id("start", 20000));
    try std.testing.expectEqualStrings("research_categories", host.command);
    const next = try std.json.parseFromSlice(struct { ids: []const []const u8 }, a, host.args, .{});
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 1), next.value.ids.len);
    try std.testing.expectEqualStrings(next_row.id, next.value.ids[0]);
}

test "category picker preserves drafts and reviews merges across all dates" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 393, 820);
    defer e.destroy();
    try boot(e);
    const row: model.Expense = .{ .id = &model.digest("category"), .revision = 3, .date = "2025-01-17", .amount = 100, .payee = "Lunch", .account = "Debit", .category = "Dinning" };
    var rows = [_]model.Expense{row};
    const snapshot: app.Snapshot = .{ .expenses = &rows, .settings = "{\"categories\":{\"Dining\":[]}}", .platform = "android", .vision_available = false, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    try open_editor(e, row);
    try set_value(e, eid("field-payee"), "Unsaved merchant");
    s.dirty = true;
    try show(e, eid("details-body"), false);
    try std.testing.expect(e.tree.get(eid("field-category")).?.props.none);
    const category_frame = e.tree.get(eid("choose-category")).?.frame;
    const hit = e.tree.hit(category_frame.x + category_frame.w / 2, category_frame.y + category_frame.h / 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(inside(hit, eid("choose-category")));
    _ = try handle_event(e, hit.id, "click", "0");
    try std.testing.expect(categories.active);
    const search_frame = e.tree.get(categories.id("search")).?.frame;
    const foreground = e.tree.hit(search_frame.x + search_frame.w / 2, search_frame.y + search_frame.h / 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(inside(foreground, categories.base));
    try std.testing.expect(e.back());
    try std.testing.expect(!categories.active);
    try std.testing.expect(s.dirty and s.modal == .editor);
    try std.testing.expectEqualStrings("Unsaved merchant", value(e, eid("field-payee")));
    _ = try handle_event(e, eid("choose-category"), "click", "0");
    _ = try handle_event(e, categories.id("search"), "input", "\" dining \"");
    try std.testing.expect(e.tree.get(categories.id("add")).?.props.none);
    _ = try handle_event(e, categories.id("search"), "input", "\"Dinning\"");
    try std.testing.expectEqual(@as(usize, 1), e.tree.get(categories.id("list")).?.kids.items.len);
    try std.testing.expect(e.back());
    s.dirty = false;
    try close_modal(e);
    _ = try handle_event(e, aid("pref-categories"), "click", "0");
    _ = try handle_event(e, categories.id("search"), "input", "\"Dinning\"");
    _ = try handle_event(e, 25000000, "click", "0");
    _ = try handle_event(e, categories.id("target"), "input", "\"Dining\"");
    _ = try handle_event(e, categories.id("review"), "click", "0");
    try std.testing.expect(!e.tree.get(categories.id("apply")).?.props.none);
    try std.testing.expect(std.mem.indexOf(u8, e.tree.get(categories.id("summary")).?.props.runs.?[0].t, "1 payments across all dates") != null);
    _ = try handle_event(e, categories.id("apply"), "click", "0");
    const edit = try std.json.parseFromSlice(@import("core/preferences.zig").Edit, a, host.args, .{});
    defer edit.deinit();
    try std.testing.expectEqualStrings("Dinning", edit.value.category_change.?.source);
    try std.testing.expectEqual(@as(i64, 3), edit.value.targets[0].revision);
    try resolved(e, @intFromEnum(Request.category_edit), false, "RevisionConflict");
    try std.testing.expect(categories.active);
    try std.testing.expectEqualStrings("Dining", value(e, categories.id("target")));
    try std.testing.expect(e.tree.get(categories.id("apply")).?.props.none);
    try std.testing.expect(e.back());
    try std.testing.expect(categories.active);
    try std.testing.expect(e.back());
    try std.testing.expect(!categories.active);
}

test "payment backdrop dismisses clean sheets and protects dirty or busy drafts" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1280, 820);
    defer e.destroy();
    try boot(e);
    const snapshot: app.Snapshot = .{ .expenses = &.{}, .settings = "{}", .platform = "linux", .vision_available = false, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    try open_editor(e, null);
    try std.testing.expect(e.tree.get(19500).?.props.click);
    _ = try handle_event(e, eid("editor-title"), "click", "0");
    try std.testing.expectEqual(Modal.editor, s.modal);
    _ = try handle_event(e, 19500, "click", "0");
    try std.testing.expectEqual(Modal.none, s.modal);
    try open_editor(e, null);
    try set_value(e, eid("field-payee"), "Unsaved merchant");
    s.dirty = true;
    _ = try handle_event(e, 19500, "click", "0");
    try std.testing.expect(s.notice_open);
    _ = try handle_event(e, 19500, "click", "0");
    try std.testing.expect(s.notice_open);
    _ = try handle_event(e, Notice.id("cancel", 19000), "click", "0");
    try std.testing.expectEqualStrings("Unsaved merchant", value(e, eid("field-payee")));
    s.busy = true;
    _ = try handle_event(e, 19500, "click", "0");
    try std.testing.expect(!s.notice_open and s.modal == .editor);
    s.busy = false;
}

test "special rule editor reuses equivalent descriptions and preserves conflicting drafts" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1180, 820);
    defer e.destroy();
    try boot(e);
    const config = "{\"special_cases\":{\"TRASPASO A DEUDA NACIONAL\":\"USD purchases converted to CLP\"}}";
    const snapshot: app.Snapshot = .{ .expenses = &.{}, .settings = config, .platform = "linux", .vision_available = false, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    _ = try handle_event(e, aid("pref-special"), "click", "0");
    const Preferences = ui.View(@embedFile("preferences-dialog.oriel"));
    const Mapping = ui.View(@embedFile("mapping.oriel"));
    _ = try handle_event(e, Preferences.id("add-special", 11000), "click", "0");
    try set_value(e, Mapping.id("key", 20000032), "Traspaso A Deuda Nacional");
    try set_value(e, Mapping.id("value", 20000032), "Different label");
    try std.testing.expectError(error.ConflictingSpecialRule, handle_event(e, Preferences.id("save-preferences", 11000), "click", "0"));
    try std.testing.expect(s.modal == .preferences and !s.busy);
    try std.testing.expectEqualStrings("Different label", value(e, Mapping.id("value", 20000032)));
    try set_value(e, Mapping.id("value", 20000032), "USD purchases converted to CLP");
    _ = try handle_event(e, Preferences.id("save-preferences", 11000), "click", "0");
    const edit = try std.json.parseFromSlice(@import("core/preferences.zig").Edit, a, host.args, .{});
    defer edit.deinit();
    try std.testing.expectEqual(@as(usize, 1), edit.value.settings.special_cases.object.count());
    try std.testing.expect(edit.value.settings.special_cases.object.contains("TRASPASO A DEUDA NACIONAL"));
}

test "a missing bank card is saved through Accounts and Back returns to bank import" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1180, 820);
    defer e.destroy();
    try boot(e);
    const config = "{\"salary\":1234,\"cards_config\":{}}";
    const snapshot: app.Snapshot = .{ .expenses = &.{}, .settings = config, .platform = "linux", .vision_available = false, .tray_running = false, .statements = &.{}, .santander_available = true };
    const json = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(json);
    try resolved(e, @intFromEnum(Request.snapshot), true, json);
    _ = try handle_event(e, aid("open-statements"), "click", "0");
    const Statements = ui.View(@embedFile("statements-page.oriel"));
    const Preferences = ui.View(@embedFile("preferences-dialog.oriel"));
    const Mapping = ui.View(@embedFile("mapping.oriel"));
    _ = try handle_event(e, Statements.id("bank-bci", 13000), "click", "0");
    try set_value(e, Statements.id("santander-account", 13000), "TEST BCI card");
    _ = try handle_event(e, Statements.id("bank-add-account", 13000), "click", "0");
    try std.testing.expect(s.modal == .preferences and s.return_to_statements);
    try std.testing.expectEqualStrings("TEST BCI card", value(e, Mapping.id("key", 20000000)));
    try request_close(e);
    _ = try click(e, Notice.id("confirm", 19000));
    try std.testing.expect(s.modal == .statements and !s.return_to_statements);
    try std.testing.expectEqualStrings("TEST BCI card", value(e, Statements.id("santander-account", 13000)));
    _ = try handle_event(e, Statements.id("bank-add-account", 13000), "click", "0");
    try set_value(e, Mapping.id("value", 20000000), "Test cardholder");
    _ = try handle_event(e, Preferences.id("save-preferences", 11000), "click", "0");
    try std.testing.expectEqualStrings("save_budget", host.command);
    const edit = try std.json.parseFromSlice(@import("core/preferences.zig").Edit, a, host.args, .{});
    defer edit.deinit();
    try std.testing.expectEqualStrings(config, edit.value.expected);
    try std.testing.expectEqual(@as(i64, 1234), edit.value.settings.salary);
    try std.testing.expectEqualStrings("Test cardholder", edit.value.settings.cards_config.object.get("TEST BCI card").?.string);
    try resolved(e, @intFromEnum(Request.settings), true, "0");
    try std.testing.expect(s.modal == .statements and !s.return_to_statements);
    try std.testing.expectEqualStrings("TEST BCI card", value(e, Statements.id("santander-account", 13000)));
    _ = try handle_event(e, Statements.id("santander-connect", 13000), "click", "0");
    try std.testing.expectEqualStrings("import_bci", host.command);
    try std.testing.expect(std.mem.indexOf(u8, host.args, "TEST BCI card") != null);
    try resolved(e, @intFromEnum(Request.bank_import), false, "BankCancelled");
}

test "Santander capture requires an account and stages review without saving a payment" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1180, 820);
    defer e.destroy();
    try boot(e);
    const snapshot: app.Snapshot = .{ .expenses = &.{}, .settings = "{}", .platform = "linux", .vision_available = false, .tray_running = false, .statements = &.{}, .santander_available = true };
    const json = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(json);
    try resolved(e, @intFromEnum(Request.snapshot), true, json);
    _ = try handle_event(e, aid("open-statements"), "click", "0");
    const Statements = ui.View(@embedFile("statements-page.oriel"));
    try std.testing.expect(!e.tree.get(Statements.id("santander-import", 13000)).?.props.none);
    const before = host.request;
    _ = try handle_event(e, Statements.id("santander-connect", 13000), "click", "0");
    try std.testing.expectEqual(before, host.request);
    try std.testing.expect(!s.busy);
    try set_value(e, Statements.id("santander-account", 13000), "1234");
    _ = try handle_event(e, Statements.id("santander-connect", 13000), "click", "0");
    try std.testing.expect(s.busy);
    try std.testing.expectEqualStrings("import_santander", host.command);
    try std.testing.expect(std.mem.indexOf(u8, host.args, "1234") != null);
    try resolved(e, @intFromEnum(Request.bank_import), true, "{\"hash\":null,\"added\":0}");
    try std.testing.expect(!s.busy and s.modal == .statements);
    _ = try handle_event(e, Statements.id("santander-connect", 13000), "click", "0");
    try resolved(e, @intFromEnum(Request.bank_import), false, "SantanderCancelled");
    try std.testing.expect(!s.busy and s.modal == .statements);
    _ = try handle_event(e, Statements.id("bank-bci", 13000), "click", "0");
    try std.testing.expectEqualStrings("", value(e, Statements.id("santander-account", 13000)));
    _ = try handle_event(e, Statements.id("santander-connect", 13000), "click", "0");
    try std.testing.expect(!s.busy);
    try set_value(e, Statements.id("santander-account", 13000), "BCI checking");
    _ = try handle_event(e, Statements.id("santander-connect", 13000), "click", "0");
    try std.testing.expectEqualStrings("import_bci", host.command);
    try resolved(e, @intFromEnum(Request.bank_import), false, "BciCancelled");
    try std.testing.expect(!s.busy and s.modal == .statements);
    _ = try handle_event(e, Statements.id("bank-boa", 13000), "click", "0");
    try std.testing.expectEqualStrings("", value(e, Statements.id("santander-account", 13000)));
    _ = try handle_event(e, Statements.id("santander-connect", 13000), "click", "0");
    try std.testing.expect(!s.busy);
    try set_value(e, Statements.id("santander-account", 13000), "BofA checking");
    _ = try handle_event(e, Statements.id("santander-connect", 13000), "click", "0");
    try std.testing.expectEqualStrings("import_boa", host.command);
    try resolved(e, @intFromEnum(Request.bank_import), false, "BankCancelled");
    try std.testing.expect(!s.busy and s.modal == .statements);
    _ = try handle_event(e, Statements.id("santander-connect", 13000), "click", "0");
    const imported = try std.json.Stringify.valueAlloc(a, @import("core/statements.zig").BankImport{ .hash = &model.digest("bank-source"), .added = 1 }, .{});
    defer a.free(imported);
    try resolved(e, @intFromEnum(Request.bank_import), true, imported);
    try std.testing.expectEqualStrings("statement_observations", host.command);
    const obs = [_]@import("core/statements.zig").Observation{.{ .id = &model.digest("bank-observation"), .source = .{ .date = "2026-10-19", .payee = "TEST SHOP", .amount = 1234, .currency = "USD", .account = "BofA checking", .category = "Other" }, .expense_id = null, .ignored = false }};
    const encoded = try std.json.Stringify.valueAlloc(a, obs, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.observations), true, encoded);
    try std.testing.expect(s.modal == .statement and !s.busy);
    try std.testing.expectEqual(@as(usize, 0), s.snapshot.?.value.expenses.len);
    const Statement = ui.View(@embedFile("statement-dialog.oriel"));
    const Review = ui.View(@embedFile("review-row.oriel"));
    var handled = [_]@import("core/statements.zig").Observation{
        obs[0],
        .{ .id = &model.digest("ignored-bank-row"), .source = obs[0].source, .expense_id = null, .ignored = true },
        .{ .id = &model.digest("matched-bank-row"), .source = obs[0].source, .expense_id = null, .ignored = false, .match = .{ .id = &model.digest("reviewed-payment"), .revision = 1 } },
        .{ .id = &model.digest("older-bank-row"), .source = obs[0].source, .expense_id = null, .ignored = false },
    };
    handled[0].source.date = "2026-10-23";
    const handled_json = try std.json.Stringify.valueAlloc(a, handled, .{});
    defer a.free(handled_json);
    try resolved(e, @intFromEnum(Request.observations), true, handled_json);
    try std.testing.expect(!e.tree.get(Review.id("review-row", 22000000)).?.props.none);
    try std.testing.expect(e.tree.get(Review.id("review-row", 22000032)).?.props.none);
    try std.testing.expect(e.tree.get(Review.id("review-row", 22000064)).?.props.none);
    _ = try handle_event(e, Statement.id("toggle-reviewed", 14000), "click", "0");
    try std.testing.expect(!e.tree.get(Review.id("review-row", 22000032)).?.props.none);
    try set_value(e, Statement.id("reviewed-through", 14000), "2026-10-22");
    _ = try handle_event(e, Statement.id("apply-reviewed-through", 14000), "click", "0");
    try std.testing.expectEqualStrings("create", value(e, Review.id("choice", 22000000)));
    try std.testing.expectEqualStrings("ignore", value(e, Review.id("choice", 22000096)));
    try std.testing.expectEqualStrings(handled[2].match.?.id, value(e, Review.id("choice", 22000064)));
    _ = try handle_event(e, Statement.id("confirm-statement", 14000), "click", "0");
    try std.testing.expectEqualStrings("reconcile_statement", host.command);
    try std.testing.expect(std.mem.indexOf(u8, host.args, "ignore") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.args, "link") != null);
}

test "Insights month range, whole year and category medians follow WebKit" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1180, 820);
    defer e.destroy();
    try boot(e);
    var rows = [_]model.Expense{
        .{ .id = &model.digest("range-1"), .date = "2025-11-04", .amount = 700, .payee = "Old market", .account = "1234", .category = "Food", .revision = 1 },
        .{ .id = &model.digest("range-2"), .date = "2026-01-10", .amount = 1000, .payee = "Market", .account = "1234", .category = "Food", .revision = 1 },
        .{ .id = &model.digest("range-3"), .date = "2026-01-12", .amount = 300, .payee = "Cab", .account = "1234", .category = "Taxi", .revision = 1 },
        .{ .id = &model.digest("range-4"), .date = "2026-02-03", .amount = 3000, .payee = "Market", .account = "1234", .category = "Food", .revision = 1 },
        .{ .id = &model.digest("range-5"), .date = "2026-03-08", .amount = 2000, .payee = "Market", .account = "1234", .category = "Food", .revision = 1 },
        .{ .id = &model.digest("range-6"), .date = "2026-03-09", .amount = 900, .payee = "Cab", .account = "1234", .category = "Taxi", .revision = 1 },
    };
    const snapshot: app.Snapshot = .{ .expenses = &rows, .settings = "{\"cards_config\":{\"1234\":\"Household\"},\"fixed_expenses_items\":[{\"name\":\"Rent\",\"amount\":500,\"keywords\":[\"RENT\"]}]}", .platform = "linux", .vision_available = false, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    try navigate(e, .insights);
    const Chart = ui.View(@embedFile("category-row.oriel"));
    const text = struct {
        fn of(engine: *ui.Engine, id: i64) []const u8 {
            const n = engine.tree.get(id).?;
            const holder = if (n.kids.items.len > 0) n.kids.items[0] else n;
            return holder.props.runs.?[0].t;
        }
    }.of;
    try std.testing.expectEqualStrings("2026-03", value(e, aid("insights-from")));
    try std.testing.expectEqualStrings("2026-03", value(e, aid("insights-to")));
    try std.testing.expectEqualStrings("March 2026", text(e, aid("insights-period")));
    try std.testing.expectEqualStrings("1 payments", text(e, Chart.id("detail", 8000000)));

    _ = try handle_event(e, aid("insights-year"), "change", "\"2026\"");
    try std.testing.expectEqualStrings("2026-01", value(e, aid("insights-from")));
    try std.testing.expectEqualStrings("2026-03", value(e, aid("insights-to")));
    try std.testing.expectEqualStrings("January 2026 – March 2026 · 3 months", text(e, aid("insights-period")));
    try std.testing.expectEqualStrings("2026-03", value(e, aid("month")));
    // Food: 1000, 3000, 2000 -> median 2000. Taxi: 300, 0, 900 -> median 300.
    try std.testing.expectEqualStrings("Food", text(e, Chart.id("title", 8000000)));
    try std.testing.expectEqualStrings("$6.000", text(e, Chart.id("amount", 8000000)));
    try std.testing.expectEqualStrings("3 payments · median $2.000 a month", text(e, Chart.id("detail", 8000000)));
    _ = try handle_event(e, aid("category-measure"), "change", "\"median\"");
    try std.testing.expectEqualStrings("$2.000", text(e, Chart.id("amount", 8000000)));
    try std.testing.expectEqualStrings("3 payments · total $6.000", text(e, Chart.id("detail", 8000000)));
    try std.testing.expectEqualStrings("Taxi", text(e, Chart.id("title", 8000016)));
    try std.testing.expectEqualStrings("$300", text(e, Chart.id("amount", 8000016)));
    _ = try click(e, aid("chart-fixed"));
    try std.testing.expectEqualStrings("$500", text(e, Chart.id("amount", 8000016)));
    try std.testing.expectEqualStrings("Planned a month", text(e, Chart.id("detail", 8000016)));
    _ = try handle_event(e, aid("category-measure"), "change", "\"total\"");
    try std.testing.expectEqualStrings("Rent", text(e, Chart.id("title", 8000016)));
    try std.testing.expectEqualStrings("$1.500", text(e, Chart.id("amount", 8000016)));
    _ = try click(e, aid("chart-fixed"));

    _ = try handle_event(e, aid("insights-from"), "change", "\"2025-11\"");
    try std.testing.expectEqualStrings("", value(e, aid("insights-year")));
    try std.testing.expectEqualStrings("November 2025 – March 2026 · 5 months", text(e, aid("insights-period")));
    _ = try handle_event(e, aid("insights-from"), "change", "\"2026-03\"");
    _ = try handle_event(e, aid("insights-to"), "change", "\"2026-01\"");
    try std.testing.expectEqualStrings("2026-01", value(e, aid("insights-from")));
    try std.testing.expectEqualStrings("2026-01", value(e, aid("insights-to")));

    // On a phone the range chips sit in one short row, directly above the period label.
    e.tree.width = 393;
    try resized(e);
    try navigate(e, .insights);
    const chip = e.tree.get(aid("insights-from")).?.frame;
    const label = e.tree.get(aid("insights-period")).?.frame;
    try std.testing.expect(label.y >= chip.y + chip.h and label.y - chip.y < 96);
    try std.testing.expect(e.tree.get(aid("insights-from")).?.parent.?.parent.?.props.scrollx);
    _ = try handle_event(e, aid("insights-year"), "change", "\"2025\"");
    _ = try click(e, aid("export-report"));
    try std.testing.expectEqualStrings("export_report", host.command);
    try std.testing.expect(std.mem.indexOf(u8, host.args, "Old market") != null);
    try std.testing.expect(std.mem.indexOf(u8, host.args, "Cab") == null);
}

test "a category median joins the monthly budget and Home tracks it" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1180, 820);
    defer e.destroy();
    try boot(e);
    var rows = [_]model.Expense{
        .{ .id = &model.digest("budget-1"), .date = "2026-01-10", .amount = 1000, .payee = "Market", .account = "1234", .category = "Food", .revision = 1 },
        .{ .id = &model.digest("budget-2"), .date = "2026-02-03", .amount = 3000, .payee = "Market", .account = "1234", .category = "Food", .revision = 1 },
        .{ .id = &model.digest("budget-3"), .date = "2026-03-08", .amount = 1500, .payee = "Market", .account = "1234", .category = "Food", .revision = 1 },
        .{ .id = &model.digest("budget-4"), .date = "2026-03-09", .amount = 900, .payee = "Cab", .account = "1234", .category = "Taxi", .revision = 1 },
    };
    var snapshot: app.Snapshot = .{ .expenses = &rows, .settings = "{\"salary\":10000,\"fixed_expenses_items\":[{\"name\":\"Rent\",\"amount\":500,\"keywords\":[\"RENT\"]}]}", .platform = "linux", .vision_available = false, .tray_running = false, .statements = &.{} };
    const encoded = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(encoded);
    try resolved(e, @intFromEnum(Request.snapshot), true, encoded);
    try navigate(e, .insights);
    _ = try handle_event(e, aid("insights-year"), "change", "\"2026\"");
    _ = try handle_event(e, aid("category-measure"), "change", "\"median\"");
    const Chart = ui.View(@embedFile("category-row.oriel"));
    const text = struct {
        fn of(engine: *ui.Engine, id: i64) []const u8 {
            const n = engine.tree.get(id).?;
            const holder = if (n.kids.items.len > 0) n.kids.items[0] else n;
            return holder.props.runs.?[0].t;
        }
    }.of;
    // Food: 1000, 3000, 1500 -> median 1500.
    try std.testing.expectEqualStrings("Food", text(e, Chart.id("title", 8000000)));
    try std.testing.expect(!e.tree.get(aid("category-hint")).?.props.none);
    // A tap still opens the category's payments; a long press offers the budget.
    _ = try handle_event(e, Chart.id("title", 8000000), "click", "0");
    try std.testing.expectEqual(Page.payments, s.page);
    try std.testing.expectEqual(@as(usize, 3), s.selected.items.len);
    try std.testing.expect(e.back());
    try std.testing.expectEqual(Page.insights, s.page);
    _ = try handle_event(e, Chart.id("title", 8000000), "contextmenu", "[0,0,2,2,0]");
    try std.testing.expect(s.notice_open);
    try std.testing.expectEqual(Page.insights, s.page);
    try std.testing.expectEqualStrings("Add Food to the monthly budget at its median, $1.500 a month?", text(e, Notice.id("message", 19000)));
    _ = try click(e, Notice.id("confirm", 19000));
    try std.testing.expectEqualStrings("save_budget", host.command);
    const edit = try std.json.parseFromSlice(@import("core/preferences.zig").Edit, a, host.args, .{ .ignore_unknown_fields = true });
    defer edit.deinit();
    try std.testing.expectEqual(@as(i64, 1500), edit.value.settings.category_budgets.object.get("Food").?.integer);
    try std.testing.expectEqual(@as(usize, 1), edit.value.settings.fixed_expenses_items.len);
    try resolved(e, @intFromEnum(Request.settings), true, "0");

    snapshot.settings = "{\"salary\":10000,\"fixed_expenses_items\":[{\"name\":\"Rent\",\"amount\":500,\"keywords\":[\"RENT\"]}],\"category_budgets\":{\"Food\":2000}}";
    const updated = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(updated);
    try resolved(e, @intFromEnum(Request.snapshot), true, updated);
    try navigate(e, .home);
    // March: Food 1500 of 2000; the forecast keeps the other 500 aside.
    try std.testing.expectEqualStrings("Food", text(e, Chart.id("title", 21000000)));
    try std.testing.expectEqualStrings("of $2.000 · $500 left", text(e, Chart.id("detail", 21000000)));
    try std.testing.expectEqualStrings("$6.600", text(e, aid("budget-forecast")));
    _ = try handle_event(e, aid("month"), "change", "\"2026-02\"");
    try std.testing.expectEqualStrings("$1.000 over $2.000", text(e, Chart.id("detail", 21000000)));
    try std.testing.expectEqualStrings("Long-press a budget to remove it.", text(e, aid("budget-hint")));
    _ = try handle_event(e, Chart.id("title", 21000000), "click", "0");
    try std.testing.expectEqual(Page.payments, s.page);
    try std.testing.expectEqual(@as(usize, 1), s.selected.items.len);
    try std.testing.expect(e.back());
    _ = try handle_event(e, Chart.id("title", 21000000), "contextmenu", "[0,0,2,2,0]");
    try std.testing.expectEqualStrings("Remove the Food budget of $2.000 a month?", text(e, Notice.id("message", 19000)));
    _ = try click(e, Notice.id("confirm", 19000));
    const removal = try std.json.parseFromSlice(@import("core/preferences.zig").Edit, a, host.args, .{ .ignore_unknown_fields = true });
    defer removal.deinit();
    try std.testing.expectEqual(@as(usize, 0), removal.value.settings.category_budgets.object.count());
}

test "desktop shortcuts keep editor focus inside modal and recovery retains unsaved revision" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 1180, 820);
    defer e.destroy();
    try boot(e);
    const row: model.Expense = .{ .id = &model.digest("desktop-draft"), .date = "2026-10-27", .amount = 123, .payee = "Synthetic", .revision = 7 };
    var rows = [_]model.Expense{row};
    const snapshot: app.Snapshot = .{ .expenses = &rows, .settings = "{}", .platform = "android", .vision_available = false, .tray_running = false, .statements = &.{} };
    const json = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(json);
    try resolved(e, @intFromEnum(Request.snapshot), true, json);
    try std.testing.expect(e.event(0, "key", "[\"f\",2]"));
    try std.testing.expectEqual(aid("search"), e.focus.id);
    try open_editor(e, row);
    try std.testing.expectEqual(eid("field-payee"), e.focus.id);
    try std.testing.expect(e.focus.visible);
    // Wide windows must overlay the dialog instead of flowing it after the
    // ledger (the CSS media query only covers phone widths).
    const dialog = e.tree.get(editor_base).?;
    try std.testing.expectEqualStrings("absolute", dialog.props.pos.?);
    try std.testing.expect(dialog.frame.y >= 0 and dialog.frame.y + dialog.frame.h <= e.tree.height + 1);
    try std.testing.expect(dialog.frame.x >= 0 and dialog.frame.x + dialog.frame.w <= e.tree.width + 1);
    try std.testing.expectEqual(@as(?i32, -1), e.tree.get(aid("new-expense")).?.props.ti);
    try std.testing.expect(e.event(eid("field-payee"), "input", "[\"Unsaved synthetic draft\",\"insertText\",\"t\"]"));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), try recovery.capture(e, arena.allocator()), .{});
    const checkpoint = try std.json.parseFromSliceLeaky(recovery.Checkpoint, arena.allocator(), encoded, .{ .allocate = .alloc_always });
    try close_modal(e);
    try recovery.apply(e, checkpoint);
    try std.testing.expectEqualStrings("Unsaved synthetic draft", value(e, eid("field-payee")));
    try std.testing.expectEqual(@as(i64, 7), s.current.?.revision);
    try std.testing.expect(s.dirty);
    try std.testing.expect(e.event(eid("field-payee"), "key", "[\"s\",2]"));
    try std.testing.expectEqualStrings("save_expense", host.command);
    const saved = try std.json.parseFromSlice(model.Save, a, host.args, .{});
    defer saved.deinit();
    try std.testing.expectEqual(@as(i64, 7), saved.value.expected_revision);
}

test "attachment batch refuses replacement of a dirty editor and remains reviewable" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 393, 820);
    defer e.destroy();
    try boot(e);
    const snapshot: app.Snapshot = .{ .expenses = &.{}, .settings = "{}", .platform = "android", .vision_available = false, .tray_running = false, .statements = &.{} };
    const json = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(json);
    try resolved(e, @intFromEnum(Request.snapshot), true, json);
    try open_editor(e, null);
    try set_value(e, eid("field-payee"), "Do not replace");
    s.dirty = true;
    try desktop.receive(e, "[{\"name\":\"synthetic.png\",\"data_url\":\"data:image/png;base64,iVBORw0KGgo=\"}]");
    try std.testing.expectEqualStrings("Do not replace", value(e, eid("field-payee")));
    try std.testing.expect(s.document == null);
    try std.testing.expectError(error.ImportAlreadyQueued, desktop.receive(e, "[]"));
    try close_modal(e);
    try desktop.advance(e);
    try std.testing.expect(s.document != null);
    try std.testing.expectEqualStrings("synthetic.png", s.document_name);
    try std.testing.expect(s.dirty);
}

test "every drawn control shows a focus look in the payments tab order" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 768, 576);
    defer e.destroy();
    try boot(e);
    const row: model.Expense = .{ .id = &model.digest("focus-order"), .date = "2026-10-27", .amount = 123, .payee = "Synthetic", .revision = 7 };
    var rows = [_]model.Expense{row};
    const snapshot: app.Snapshot = .{ .expenses = &rows, .settings = "{}", .platform = "android", .vision_available = false, .tray_running = false, .statements = &.{} };
    const json = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(json);
    try resolved(e, @intFromEnum(Request.snapshot), true, json);
    try navigate(e, .payments);
    var drawn: usize = 0;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        _ = e.event(0, "key", "[\"Tab\",0]");
        try std.testing.expect(e.focus.visible);
        try std.testing.expectEqual(e.focus.id, e.focus.ring);
        const n = e.tree.get(e.focus.id) orelse return error.MissingFocusNode;
        switch (n.kind) {
            .input, .textarea, .select, .check, .button => {},
            else => {
                // A view with a hover look otherwise suppresses the platform
                // ring: its own focus look must draw one.
                try std.testing.expect(n.props.ol != null);
                drawn += 1;
            },
        }
    }
    try std.testing.expect(drawn >= 10);
}

fn find_scroller(n: *ui.Node) ?*ui.Node {
    if (n.props.scroll and n.content_h > n.frame.h + 0.5) return n;
    for (n.kids.items) |k| if (find_scroller(k)) |found| return found;
    return null;
}

test "keyboard focus under the sticky header is scrolled below it" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 768, 576);
    defer e.destroy();
    try boot(e);
    const snapshot: app.Snapshot = .{ .expenses = &.{}, .settings = "{}", .platform = "android", .vision_available = false, .tray_running = false, .statements = &.{} };
    const json = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(json);
    try resolved(e, @intFromEnum(Request.snapshot), true, json);
    try navigate(e, .payments);
    const scroller = find_scroller(e.tree.root.?) orelse return error.MissingScroller;
    e.setScrollY(scroller, 120);
    try std.testing.expect(scroller.scroll_y > 0);
    desktop.focus(e, aid("search"));
    try std.testing.expectEqual(aid("search"), e.focus.id);
    desktop.reveal_focused(e);
    const search = e.tree.get(aid("search")).?;
    try std.testing.expect(search.frame.y >= 63.5);
}

test "ctrl toggles and shift extends the payment selection" {
    const a = std.testing.allocator;
    var host: TestHost = .{ .allocator = a };
    defer host.deinit();
    configure(std.testing.io);
    const e = try ui.Engine.create(a, .{ .ctx = &host, .measure = TestHost.measure, .laid_out = TestHost.laid, .removed = TestHost.removed, .add_timer = TestHost.timer, .invoke = TestHost.dispatch, .focus = TestHost.focus }, &.{}, "{}", "main", "application.oriel", 768, 576);
    defer e.destroy();
    try boot(e);
    const rows = [_]model.Expense{
        .{ .id = &model.digest("select-a"), .date = "2026-10-27", .amount = 100, .payee = "A", .revision = 1 },
        .{ .id = &model.digest("select-b"), .date = "2026-10-26", .amount = 200, .payee = "B", .revision = 1 },
        .{ .id = &model.digest("select-c"), .date = "2026-10-25", .amount = 300, .payee = "C", .revision = 1 },
    };
    var snapshot_rows = rows;
    const snapshot: app.Snapshot = .{ .expenses = &snapshot_rows, .settings = "{}", .platform = "android", .vision_available = false, .tray_running = false, .statements = &.{} };
    const json = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    defer a.free(json);
    try resolved(e, @intFromEnum(Request.snapshot), true, json);
    try navigate(e, .payments);
    try std.testing.expectEqual(@as(usize, 3), s.selected.items.len);
    _ = try desktop.event(e, 26000000, "pointer", "[\"down\",0,0,1,0,0,2]");
    try std.testing.expect(desktop.has_selection());
    try std.testing.expect(desktop.selected(rows[0].id));
    _ = try desktop.event(e, 26000000, "pointer", "[\"down\",0,0,1,0,0,2]");
    try std.testing.expect(!desktop.has_selection());
    _ = try desktop.event(e, 26000032, "pointer", "[\"down\",0,0,1,0,0,1]");
    try std.testing.expect(desktop.selected(rows[0].id));
    try std.testing.expect(desktop.selected(rows[1].id));
    try std.testing.expect(desktop.selected(rows[2].id));
}
