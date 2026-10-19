//! Search and reviewed category management, layered over the existing draft.
const std = @import("std");
const f = @import("oriel_frontend.zig");
const c = @import("core/categories.zig");
const prefs = @import("core/preferences.zig");
const View = f.ui.View(@embedFile("category-picker.oriel"));
const Row = f.ui.View(@embedFile("category-option.oriel"));
pub const base: i64 = 21000;
const row_base: i64 = 25000000;
pub var active = false;
var managing = false;
var editing = false;
var pending = false;
var storage: std.heap.ArenaAllocator = undefined;
var names: []const []const u8 = &.{};
var displayed: [100][]const u8 = undefined;
var count: usize = 0;
var source: []const u8 = "";
var expected: []const u8 = "";
var draft: ?prefs.Edit = null;
var chosen: []const u8 = "";
pub fn id(comptime name: []const u8) i64 {
    return View.id(name, base);
}
pub fn prepare(e: *f.ui.Engine) !void {
    storage = .init(e.gpa);
    active = false;
    try View.prepare(&e.tree, 83000);
    try Row.prepare(&e.tree, 84000);
}
pub fn shutdown() void {
    storage.deinit();
    active = false;
}
pub fn open(e: *f.ui.Engine, manage: bool) !void {
    if (f.s.busy or f.s.snapshot == null) return;
    _ = storage.reset(.retain_capacity);
    const a = storage.allocator();
    const config = try std.json.parseFromSliceLeaky(f.reports.Settings, a, f.s.snapshot.?.value.settings, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    // Catalog strings from expenses must survive periodic snapshot refreshes.
    const catalog = try c.catalog(a, f.s.snapshot.?.value.expenses, config);
    for (catalog) |*name| name.* = try a.dupe(u8, name.*);
    names = catalog;
    expected = try a.dupe(u8, f.s.snapshot.?.value.settings);
    managing = manage;
    editing = false;
    pending = false;
    draft = null;
    active = true;
    _ = try View.mount(&e.tree, base, 83000, &.{});
    try f.mark_actions(e, View, base, .{ "back", "add", "review", "apply", "rules" });
    try f.set_text(e, id("title"), if (manage) "Manage categories" else "Choose category");
    try f.set_text(e, id("status"), "");
    try f.show(e, id("rules"), manage);
    try f.set_value(e, id("search"), "");
    try f.show(e, id("edit"), false);
    try f.resize_modal(e, base);
    try render(e);
    try f.overlay(e);
    f.redraw(e);
}
pub fn close(e: *f.ui.Engine) !void {
    if (pending) return;
    active = false;
    try f.ui.setVisible(&e.tree, base, false);
    try f.overlay(e);
    f.redraw(e);
}
fn render(e: *f.ui.Engine) !void {
    count = 0;
    const query = std.mem.trim(u8, f.value(e, id("search")), " \t\r\n");
    var ids: [100]i64 = undefined;
    var exact = false;
    for (names) |name| if (c.same(name, query)) {
        exact = true;
        break;
    };
    var similar: ?[]const u8 = null;
    for (names) |name| {
        const typo = !exact and c.similar(name, query);
        if (typo) similar = name;
        if ((!f.reports.contains(name, query) and !typo) or count == displayed.len) continue;
        displayed[count] = name;
        ids[count] = row_base + @as(i64, @intCast(count)) * 16;
        var payments: usize = 0;
        for (f.s.snapshot.?.value.expenses) |row| if (std.mem.eql(u8, row.category, name)) {
            payments += 1;
        };
        const current = std.mem.eql(u8, f.value(e, f.eid("field-category")), name);
        const detail = if (managing) try std.fmt.allocPrint(storage.allocator(), "{d} payments", .{payments}) else "";
        _ = try Row.mount(&e.tree, ids[count], 84000, &.{ .{ .name = "text", .value = name }, .{ .name = "detail", .value = detail }, .{ .name = "trailing", .value = if (managing) "›" else if (current) "✓" else "" } });
        try f.show(e, Row.id("detail", ids[count]), managing);
        var props = e.tree.get(ids[count]).?.props;
        props.minh = .{ .px = if (managing) 72 else 56 };
        if (current and !managing) props.bg = .{ .color = @import("oriel").canvas.rgb(if (e.tree.dark) 0x2f4f22 else 0xc4ef9a) };
        try e.tree.updateUiProps(ids[count], props);
        try f.mark_action(e, ids[count], name);
        count += 1;
    }
    _ = try e.tree.stampKids(id("list"), ids[0..count]);
    try f.show(e, id("add"), query.len > 0 and !exact and !c.protected(query));
    try f.set_text(e, id("add-label"), try std.fmt.allocPrint(storage.allocator(), "Add “{s}”", .{query}));
    try f.set_text(e, id("status"), if (similar) |name| try std.fmt.allocPrint(storage.allocator(), "Similar category: {s}. Select it, or add a separate category.", .{name}) else if (count == 0) "No matching categories" else if (count == 100) "Showing 100 · search to narrow the list" else if (managing) "Choose a category to rename or merge" else "Select an existing category or search to add one");
}
fn edit(e: *f.ui.Engine, name: []const u8) !void {
    if (c.protected(name)) {
        try f.set_text(e, id("status"), "Other and fixed commitments are managed separately.");
        return;
    }
    source = name;
    editing = true;
    draft = null;
    try f.show(e, id("search"), false);
    try f.show(e, id("add"), false);
    try f.show(e, id("list"), false);
    try f.show(e, id("edit"), true);
    try f.show(e, id("apply"), false);
    try f.set_text(e, id("summary"), "");
    try f.set_text(e, id("source"), name);
    try f.set_value(e, id("target"), name);
}
fn select(e: *f.ui.Engine, name: []const u8) !void {
    try f.set_value(e, f.eid("field-category"), name);
    try f.set_text(e, f.eid("category-value"), name);
    f.s.dirty = true;
    try close(e);
}
fn submit(e: *f.ui.Engine, change: c.Change, targets: []const prefs.Target) !void {
    pending = true;
    errdefer pending = false;
    chosen = try storage.allocator().dupe(u8, change.target);
    try f.set_text(e, id("status"), "Saving category…");
    try f.invoke(e, .category_edit, "save_budget", prefs.Edit{ .settings = .{}, .expected = expected, .targets = targets, .category_change = change });
}
fn review(e: *f.ui.Engine) !void {
    const a = storage.allocator();
    const target = try c.clean(a, f.value(e, id("target")));
    const config = try std.json.parseFromSliceLeaky(f.reports.Settings, a, expected, .{ .ignore_unknown_fields = true });
    _ = try c.changed(a, config, names, .{ .source = source, .target = target });
    var targets: std.ArrayList(prefs.Target) = .empty;
    for (f.s.snapshot.?.value.expenses) |row| if (std.mem.eql(u8, row.category, source)) try targets.append(a, .{ .id = try a.dupe(u8, row.id), .revision = row.revision });
    draft = .{ .settings = .{}, .expected = expected, .targets = targets.items, .category_change = .{ .source = source, .target = target } };
    const exists = for (names) |name| {
        if (std.mem.eql(u8, name, target)) break true;
    } else false;
    try f.set_text(e, id("summary"), try std.fmt.allocPrint(a, "{s} “{s}” → “{s}”\n{d} payments across all dates. Keyword rules are kept.", .{ if (exists) "Merge" else "Rename", source, target, targets.items.len }));
    try f.show(e, id("apply"), true);
}
pub fn resize(e: *f.ui.Engine) !void {
    if (!active) return;
    try f.resize_modal(e, base);
    if (!editing) try render(e);
}
pub fn event(e: *f.ui.Engine, target: i64, kind: []const u8, data: []const u8) !bool {
    return handle_event(e, target, kind, data) catch |err| {
        try f.set_text(e, id("status"), try @import("ui_errors.zig").message(storage.allocator(), @errorName(err)));
        return true;
    };
}
fn handle_event(e: *f.ui.Engine, target: i64, kind: []const u8, data: []const u8) !bool {
    if (!active) return false;
    if (std.mem.eql(u8, kind, "back")) {
        if (editing and !pending) {
            editing = false;
            try open(e, managing);
        } else try close(e);
        return true;
    }
    if (pending) return true;
    if (std.mem.eql(u8, kind, "input") and (target == id("search") or target == id("target"))) {
        const text = try std.json.parseFromSlice([]const u8, e.gpa, data, .{});
        defer text.deinit();
        try e.tree.acceptUiValue(target, text.value);
        if (target == id("search")) try render(e) else {
            draft = null;
            try f.show(e, id("apply"), false);
        }
        return true;
    }
    if (!std.mem.eql(u8, kind, "click")) return false;
    var node = e.tree.get(target);
    while (node) |n| : (node = n.parent) {
        if (n.id == id("back")) return event(e, 0, "back", "");
        if (n.id == id("rules")) {
            try close(e);
            try @import("oriel_tools.zig").open_category_rules(e);
            return true;
        }
        if (n.id == id("review")) {
            try review(e);
            return true;
        }
        if (n.id == id("apply")) {
            const d = draft orelse return true;
            try submit(e, d.category_change.?, d.targets);
            return true;
        }
        if (n.id == id("add")) {
            const name = try c.clean(storage.allocator(), f.value(e, id("search")));
            try submit(e, .{ .target = name }, &.{});
            return true;
        }
        if (n.id >= row_base and n.id < row_base + @as(i64, @intCast(count)) * 16) {
            const name = displayed[@intCast(@divTrunc(n.id - row_base, 16))];
            if (managing) try edit(e, name) else try select(e, name);
            return true;
        }
    }
    return true;
}
pub fn resolved(e: *f.ui.Engine, ok: bool, json: []const u8) !void {
    pending = false;
    if (!ok) {
        try f.set_text(e, id("status"), try @import("ui_errors.zig").message(storage.allocator(), json));
        draft = null;
        try f.show(e, id("apply"), false);
        return;
    }
    if (!managing) try select(e, chosen) else try close(e);
    try f.refresh(e);
    try f.status(e, "Category saved");
}
