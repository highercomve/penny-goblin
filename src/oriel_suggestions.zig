//! The web category datalist, anchored to the same compiled field.
const std = @import("std");
const f = @import("oriel_frontend.zig");
const ui = f.ui;
const View = ui.View(@embedFile("suggestion.oriel"));
const base: i64 = 24000000;
var field_id: i64 = 0;
var list_id: i64 = 0;
var count: usize = 0;
var selected: ?usize = null;

pub fn prepare(e: *ui.Engine) !void {
    reset();
    try View.prepare(&e.tree, 79800);
}
pub fn reset() void {
    field_id = 0;
    list_id = 0;
    count = 0;
    selected = null;
}
fn list() i64 {
    return list_id;
}
fn choose(e: *ui.Engine, index: usize) !void {
    if (index >= count) return;
    const node = e.tree.get(base + @as(i64, @intCast(index))) orelse return;
    const runs = node.props.runs orelse return error.InvalidTemplate;
    if (runs.len == 0) return error.InvalidTemplate;
    try f.set_value(e, field_id, runs[0].t);
    try f.show(e, list(), false);
    selected = null;
}
fn open(e: *ui.Engine) !void {
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var categories: std.StringHashMapUnmanaged(void) = .empty;
    for (f.s.snapshot.?.value.expenses) |row| try categories.put(a, row.category, {});
    if (f.settings().categories == .object) {
        var keys = f.settings().categories.object.iterator();
        while (keys.next()) |entry| try categories.put(a, entry.key_ptr.*, {});
    }
    var names: std.ArrayList([]const u8) = .empty;
    const query = std.mem.trim(u8, f.value(e, field_id), " \t\r\n");
    var keys = categories.keyIterator();
    while (keys.next()) |key| if (f.reports.contains(key.*, query) and !std.ascii.eqlIgnoreCase(key.*, query)) try names.append(a, key.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    count = @min(50, names.items.len);
    selected = null;
    var ids: [50]i64 = undefined;
    for (names.items[0..count], 0..) |name, index| {
        ids[index] = base + @as(i64, @intCast(index));
        _ = try View.mount(&e.tree, ids[index], 79800, &.{.{ .name = "text", .value = name }});
        try f.mark_action(e, ids[index], name);
    }
    if (!try e.tree.stampKids(list(), ids[0..count])) return error.InvalidTemplate;
    try f.show(e, list(), count > 0);
    const field = e.tree.get(field_id) orelse return error.InvalidTemplate;
    const parent = field.parent orelse return error.InvalidTemplate;
    var props = parent.props;
    props.z = if (count > 0) 10 else null;
    try e.tree.updateUiProps(parent.id, props);
}
fn highlight(e: *ui.Engine) !void {
    for (0..count) |index| {
        const node = e.tree.get(base + @as(i64, @intCast(index))).?;
        var props = node.props;
        props.bg = if (selected == index) .{ .color = if (e.tree.dark) .{ 224, 228, 220, 0.1 } else .{ 25, 29, 25, 0.1 } } else null;
        try e.tree.updateUiProps(node.id, props);
    }
    if (selected) |index| e.tree.scrollIntoView(e.tree.get(base + @as(i64, @intCast(index))).?, "nearest");
}
pub fn event(e: *ui.Engine, id: i64, kind: []const u8, data: []const u8) !bool {
    if (f.s.modal != .none or f.s.snapshot == null) return false;
    const target = f.aid("bulk-category");
    if (id == target) {
        field_id = target;
        list_id = f.aid("categories-bulk-category-list");
    }
    if (field_id == 0) return false;
    if (std.mem.eql(u8, kind, "click") and id >= base and id < base + 50) {
        try choose(e, @intCast(id - base));
        return true;
    }
    if (id != field_id) return false;
    if (std.mem.eql(u8, kind, "blur")) {
        try f.show(e, list(), false);
        return false;
    }
    if (std.mem.eql(u8, kind, "input")) {
        const v = try std.json.parseFromSlice([]const u8, e.gpa, data, .{});
        defer v.deinit();
        try e.tree.acceptUiValue(id, v.value);
        try open(e);
        return true;
    }
    if (std.mem.eql(u8, kind, "focus")) {
        try open(e);
        return false;
    }
    if (!std.mem.eql(u8, kind, "key")) return false;
    const parsed = try std.json.parseFromSlice(std.json.Value, e.gpa, data, .{});
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len == 0 or parsed.value.array.items[0] != .string) return false;
    const key = parsed.value.array.items[0].string;
    if (e.tree.get(list()).?.props.none) {
        if (!std.mem.eql(u8, key, "ArrowDown")) return false;
        try open(e);
        return true;
    }
    if (std.mem.eql(u8, key, "Escape")) {
        try f.show(e, list(), false);
        return true;
    }
    if (std.mem.eql(u8, key, "Enter") and selected != null) {
        try choose(e, selected.?);
        return true;
    }
    if (count == 0) return false;
    if (std.mem.eql(u8, key, "ArrowDown")) selected = if (selected) |i| (i + 1) % count else 0 else if (std.mem.eql(u8, key, "ArrowUp")) selected = if (selected) |i| (i + count - 1) % count else count - 1 else return false;
    try highlight(e);
    return true;
}
