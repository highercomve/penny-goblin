//! Desktop input policy for the compiled renderer. Native text editing stays with the OS.
const std = @import("std");
const f = @import("oriel_frontend.zig");
const app = @import("main.zig");
const tools = @import("oriel_tools.zig");
const ui = f.ui;
var incoming: ?std.json.Parsed([]app.UiFile) = null;
var next_file: usize = 0;
const Menu = ui.View(@embedFile("desktop-menu.oriel"));
pub const menu_base: i64 = 19800;
pub var menu_active = false;
var menu_row: usize = 0;
var selected_ids: [600][64]u8 = undefined;
var selected_count: usize = 0;
var anchor: usize = 0;

pub fn prepare(e: *ui.Engine) !void {
    try Menu.prepare(&e.tree, 79700);
}
pub fn selected(id: []const u8) bool {
    for (selected_ids[0..selected_count]) |*entry| if (std.mem.eql(u8, entry, id)) return true;
    return false;
}
pub fn has_selection() bool {
    return selected_count > 0;
}
fn add(id: []const u8) void {
    if (id.len != 64 or selected(id) or selected_count == selected_ids.len) return;
    @memcpy(&selected_ids[selected_count], id);
    selected_count += 1;
}
fn toggle(id: []const u8) void {
    for (selected_ids[0..selected_count], 0..) |*entry, i| if (std.mem.eql(u8, entry, id)) {
        selected_count -= 1;
        selected_ids[i] = selected_ids[selected_count];
        return;
    };
    add(id);
}
fn row_index(e: *ui.Engine, id: i64) ?usize {
    var node = e.tree.get(id);
    var depth: usize = 0;
    while (node) |n| : (depth += 1) {
        if (depth == 64) break;
        if (n.id >= 26000000 and n.id < 26000000 + @as(i64, @intCast(f.s.rows)) * 16) return @intCast(@divTrunc(n.id - 26000000, 16));
        node = n.parent;
    }
    return null;
}
pub fn event(e: *ui.Engine, id: i64, kind: []const u8, data: []const u8) !bool {
    if (menu_active) {
        if (!std.mem.eql(u8, kind, "click")) return std.mem.eql(u8, kind, "contextmenu");
        var node = e.tree.get(id);
        var depth: usize = 0;
        while (node) |n| : (depth += 1) {
            if (depth == 64) break;
            if (n.id == Menu.id("edit", menu_base)) {
                try close_menu(e);
                if (menu_row < f.s.selected.items.len) try f.open_editor(e, f.s.selected.items[menu_row]);
                return true;
            }
            if (n.id == Menu.id("select", menu_base)) {
                if (menu_row < f.s.selected.items.len) toggle(f.s.selected.items[menu_row].id);
                try close_menu(e);
                try f.render(e);
                return true;
            }
            if (n.id == Menu.id("clear", menu_base)) selected_count = 0;
            if (n.id == Menu.id("clear", menu_base) or n.id == Menu.id("cancel", menu_base) or n.id == 19500) {
                try close_menu(e);
                try f.render(e);
                return true;
            }
            node = n.parent;
        }
        return true;
    }
    if (f.s.modal != .none or f.s.busy or f.s.notice_open) return false;
    const row = row_index(e, id) orelse return false;
    if (std.mem.eql(u8, kind, "contextmenu")) {
        const pos = try std.json.parseFromSlice([2]f32, e.gpa, data, .{});
        defer pos.deinit();
        menu_row = row;
        _ = try Menu.mount(&e.tree, menu_base, 79700, &.{});
        try f.mark_actions(e, Menu, menu_base, .{ "edit", "select", "clear", "cancel" });
        var p = e.tree.get(menu_base).?.props;
        p.ins = .{ .{ .px = std.math.clamp(pos.value[1], 0, @max(0, e.tree.height - 224)) }, null, null, .{ .px = std.math.clamp(pos.value[0], 0, @max(0, e.tree.width - 240)) } };
        try e.tree.updateUiProps(menu_base, p);
        menu_active = true;
        try ui.setVisible(&e.tree, menu_base, true);
        try f.overlay(e);
        f.redraw(e);
        focus(e, Menu.id("edit", menu_base));
        return true;
    }
    if (!std.mem.eql(u8, kind, "pointer")) return false;
    const parsed = try std.json.parseFromSlice(std.json.Value, e.gpa, data, .{});
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len < 7) return false;
    const v = parsed.value.array.items;
    if (v[0] != .string or !std.mem.eql(u8, v[0].string, "down") or v[6] != .integer or v[3] != .integer or v[3].integer != 1) return false;
    const mods = v[6].integer;
    if (mods & (1 | 2 | 8) == 0) {
        anchor = row;
        return false;
    }
    if (mods & 1 != 0) {
        const end = @min(@max(anchor, row) + 1, @min(f.s.selected.items.len, 600));
        for (@min(anchor, row)..end) |i| add(f.s.selected.items[i].id);
    } else {
        toggle(f.s.selected.items[row].id);
        anchor = row;
    }
    try f.render(e);
    return true;
}
pub fn close_menu(e: *ui.Engine) !void {
    menu_active = false;
    try ui.setVisible(&e.tree, menu_base, false);
    try f.overlay(e);
    f.redraw(e);
}

pub fn pending_files() []const app.UiFile {
    return if (incoming) |v| v.value[next_file..] else &.{};
}
pub fn selection(a: std.mem.Allocator) ![]const []const u8 {
    std.debug.assert(selected_count <= selected_ids.len);
    const ids = try a.alloc([]const u8, selected_count);
    for (ids, 0..) |*id, i| id.* = &selected_ids[i];
    return ids;
}
pub fn restore_selection(ids: []const []const u8) !void {
    if (ids.len > selected_ids.len) return error.TooManyPayments;
    selected_count = 0;
    for (ids) |id| {
        if (!f.model.valid_id(id)) return error.InvalidId;
        add(id);
    }
}

pub fn shutdown() void {
    if (incoming) |v| v.deinit();
    incoming = null;
    next_file = 0;
    selected_count = 0;
    menu_active = false;
}

pub fn receive(e: *ui.Engine, json: []const u8) !void {
    if (json.len > 65 * 1024 * 1024) return error.ImportTooLarge;
    if (incoming != null) return error.ImportAlreadyQueued;
    const parsed = try std.json.parseFromSlice([]app.UiFile, e.gpa, json, .{ .allocate = .alloc_always });
    if (parsed.value.len == 0 or parsed.value.len > 8) {
        parsed.deinit();
        return error.TooManyFiles;
    }
    incoming = parsed;
    next_file = 0;
    try advance(e);
    if (f.s.modal != .none) try f.status(e, "Attachments queued. Finish or cancel this draft to review the next file.");
}

pub fn advance(e: *ui.Engine) !void {
    if (incoming == null or f.s.snapshot == null or f.s.modal != .none or f.s.busy) return;
    errdefer {
        incoming.?.deinit();
        incoming = null;
        next_file = 0;
    }
    const file = incoming.?.value[next_file];
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const json = try std.json.Stringify.valueAlloc(arena.allocator(), file, .{});
    if (std.mem.startsWith(u8, file.data_url, "data:application/pdf;base64,")) {
        try tools.open(e, .statements);
        try tools.resolved(e, .pick_pdf, true, json);
    } else {
        try f.open_editor(e, null);
        // Review first. Dropping an image must never silently replace typed values or run a model.
        try f.attach_image(e, file);
    }
    next_file += 1;
    if (next_file == incoming.?.value.len) {
        incoming.?.deinit();
        incoming = null;
        next_file = 0;
    }
}

/// Keyboard focus moved: the engine scrolls the node to the top edge of its
/// scroller. The main pages keep a 64px sticky header over that edge, so a
/// node scrolled there is still hidden. Move it just below the header.
const header_height: f32 = 64;

/// The Tab event re-dispatches once through the engine's own focus order
/// (with this set, so it isn't intercepted again), then fixes the scroll.
var moving_focus = false;

fn move_focus(e: *ui.Engine, data: []const u8) bool {
    moving_focus = true;
    defer moving_focus = false;
    _ = e.event(0, "key", data);
    reveal_focused(e);
    return true;
}

pub fn reveal_focused(e: *ui.Engine) void {
    if (f.s.modal != .none or menu_active) return;
    const node = e.tree.get(e.focus.id) orelse return;
    var scroll: ?*ui.Node = null;
    var at: ?*ui.Node = node;
    var depth: usize = 0;
    while (at) |n| : (at = n.parent) {
        if (n.props.sticky != null) return;
        if (scroll == null and n.props.scroll) scroll = n;
        depth += 1;
        if (depth > 512) return;
    }
    const scroller = scroll orelse return;
    const delta = reveal_scroll(node.frame.y, scroller.scroll_y);
    if (delta != 0) _ = e.scrollBy(scroller, delta);
}

fn reveal_scroll(y: f32, scroll_y: f32) f32 {
    const shortfall = header_height - y;
    return if (shortfall <= 0.5) 0 else -@min(shortfall, scroll_y);
}

test "keyboard reveal moves the focused node below the sticky header" {
    try std.testing.expectEqual(@as(f32, -64), reveal_scroll(0, 100));
    try std.testing.expectEqual(@as(f32, -36), reveal_scroll(28, 100));
    try std.testing.expectEqual(@as(f32, -20), reveal_scroll(0, 20));
    try std.testing.expectEqual(@as(f32, 0), reveal_scroll(64, 100));
    try std.testing.expectEqual(@as(f32, 0), reveal_scroll(200, 100));
}

pub fn focus(e: *ui.Engine, id: i64) void {
    const node = e.tree.get(id) orelse return;
    e.focus.id = id;
    e.focus.visible = true;
    e.backend.focus(e.backend.ctx, node);
    e.tree.scrollIntoView(node, "nearest");
}

pub fn key(e: *ui.Engine, data: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, e.gpa, data, .{});
    defer parsed.deinit();
    const v = parsed.value;
    if (v != .array or v.array.items.len < 2) return false;
    const items = v.array.items;
    if (items[0] != .string or items[1] != .integer) return false;
    const name = items[0].string;
    const mods = items[1].integer;
    const ctrl = mods & (2 | 8) != 0;
    if (std.mem.eql(u8, name, "Tab") and mods & (2 | 4 | 8) == 0 and !moving_focus) return move_focus(e, data);
    if (std.mem.eql(u8, name, "Escape")) {
        if (menu_active) {
            try close_menu(e);
            return true;
        }
        if (f.s.modal == .none and selected_count > 0) {
            selected_count = 0;
            try f.render(e);
            return true;
        }
    }
    if (ctrl and mods & 4 == 0) {
        if (std.ascii.eqlIgnoreCase(name, "s") and f.s.modal == .editor) {
            if (!f.s.busy) try f.save(e);
            return true;
        }
        if (f.s.modal != .none) return false;
        if (std.ascii.eqlIgnoreCase(name, "n")) {
            if (mods & 1 != 0) try f.open_capture(e) else try f.open_editor(e, null);
            return true;
        }
        if (std.ascii.eqlIgnoreCase(name, "f")) {
            try f.navigate(e, .payments);
            focus(e, f.aid("search"));
            return true;
        }
        if (std.ascii.eqlIgnoreCase(name, "r")) {
            if (!f.s.busy) try f.refresh(e);
            return true;
        }
    }
    // Text fields and native selects retain caret/selection/option arrow behavior.
    if (mods == 0) {
        if (e.tree.get(e.focus.id)) |node| {
            if (node.kind == .input or node.kind == .textarea or node.kind == .select) return false;
        }
        if (std.mem.eql(u8, name, "ArrowDown") or std.mem.eql(u8, name, "ArrowRight")) return move_focus(e, "[\"Tab\",0]");
        if (std.mem.eql(u8, name, "ArrowUp") or std.mem.eql(u8, name, "ArrowLeft")) return move_focus(e, "[\"Tab\",1]");
    }
    return false;
}
