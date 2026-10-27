//! Private, atomic recovery checkpoints. Ledger writes still require explicit Save.
const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");
const UiFile = @import("main.zig").UiFile;
const f = @import("oriel_frontend.zig");
const ui = f.ui;
const tools = @import("oriel_tools.zig");
const desktop = @import("oriel_desktop.zig");
const Field = struct { id: i64, value: []const u8 };
const Scroll = struct { id: i64, x: f32, y: f32 };
pub const Checkpoint = struct {
    version: u8 = 1,
    page: f.Page,
    editor: bool,
    preferences: ?tools.PreferencesDraft = null,
    details_open: bool = true,
    range_open: bool = false,
    bulk_open: bool = false,
    dirty: bool,
    current: ?f.model.Expense,
    document: ?f.model.Document,
    document_name: []const u8,
    fields: []Field,
    scrolls: []Scroll,
    focus: i64,
    selection: []const []const u8 = &.{},
    pending_files: []const UiFile = &.{},
};
var restored = false;
var compare = false;
var profile_ready = false;
var pending = false;
var due_ms: i64 = 0;
pub fn profile(name: []const u8) void {
    compare = std.mem.eql(u8, name, "compare");
    profile_ready = true;
}
pub fn reset() void {
    restored = false;
    compare = false;
    profile_ready = false;
    pending = false;
    due_ms = 0;
}

pub fn capture(e: *ui.Engine, a: std.mem.Allocator) !Checkpoint {
    var fields: std.ArrayList(Field) = .empty;
    var scrolls: std.ArrayList(Scroll) = .empty;
    var nodes = e.tree.nodes.iterator();
    while (nodes.next()) |entry| {
        if (fields.items.len >= 4096 or scrolls.items.len >= 4096) return error.CheckpointTooLarge;
        const n = entry.value_ptr.*;
        if (n.kind == .input or n.kind == .textarea or n.kind == .select)
            try fields.append(a, .{ .id = n.id, .value = f.value(e, n.id) });
        if (n.props.scroll or n.props.scrollx)
            try scrolls.append(a, .{ .id = n.id, .x = n.scroll_x, .y = n.scroll_y });
    }
    const editor = f.s.modal == .editor or f.s.return_to_editor;
    return .{ .page = f.s.page, .editor = editor, .preferences = tools.preferences_draft(), .details_open = f.s.details_open, .range_open = f.s.range_open, .bulk_open = f.s.bulk_open, .dirty = f.s.dirty, .current = if (editor) f.s.current else null, .document = if (editor) f.s.document else null, .document_name = if (editor) f.s.document_name else "", .fields = fields.items, .scrolls = scrolls.items, .focus = e.focus.id, .selection = try desktop.selection(a), .pending_files = desktop.pending_files() };
}

fn path(a: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(a, &.{ try oriel.paths.appData(a, .{ .name = app.build.id }), if (compare) "desktop-draft-compare-v1.json" else "desktop-draft-v1.json" });
}

pub fn schedule(e: *ui.Engine) void {
    due_ms = std.Io.Clock.awake.now(f.s.io).toMilliseconds() + 750;
    if (!pending) {
        pending = true;
        e.backend.add_timer(e.backend.ctx, e, 3, 750);
    }
}
pub fn checkpoint_timer(e: *ui.Engine) !void {
    const remaining = due_ms - std.Io.Clock.awake.now(f.s.io).toMilliseconds();
    if (remaining > 0) {
        e.backend.add_timer(e.backend.ctx, e, 3, @intCast(remaining));
        return;
    }
    pending = false;
    try persist(e);
}

pub fn persist(e: *ui.Engine) !void {
    if (!oriel.target.is_android or !restored or f.s.snapshot == null) return;
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try std.json.Stringify.valueAlloc(a, try capture(e, a), .{});
    if (json.len > 80 * 1024 * 1024) return error.CheckpointTooLarge;
    var atomic = try std.Io.Dir.cwd().createFileAtomic(f.s.io, try path(a), .{ .replace = true, .permissions = .fromMode(0o600) });
    defer atomic.deinit(f.s.io);
    try atomic.file.writeStreamingAll(f.s.io, json);
    try atomic.file.sync(f.s.io);
    try atomic.replace(f.s.io);
}

pub fn restore_once(e: *ui.Engine) !void {
    if (!oriel.target.is_android or restored or !profile_ready) return;
    restored = true;
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const json = std.Io.Dir.cwd().readFileAlloc(f.s.io, try path(a), a, .limited(80 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const checkpoint = try std.json.parseFromSliceLeaky(Checkpoint, a, json, .{});
    try apply(e, checkpoint);
}

pub fn apply(e: *ui.Engine, c: Checkpoint) !void {
    if (c.version != 1 or c.fields.len > 4096 or c.scrolls.len > 4096) return error.InvalidCheckpoint;
    try f.navigate(e, c.page);
    if (c.editor) {
        try f.open_editor(e, c.current);
        if (c.document) |doc| try f.attach_image(e, .{ .name = c.document_name, .data_url = doc.data_url });
        f.s.dirty = c.dirty;
    }
    if (c.preferences) |prefs| try tools.restore_preferences(e, prefs);
    f.s.dirty = c.dirty;
    f.s.details_open = c.details_open;
    f.s.range_open = c.range_open;
    f.s.bulk_open = c.bulk_open;
    for (c.fields) |field| if (e.tree.get(field.id) != null) try f.set_value(e, field.id, field.value);
    if (c.editor) try f.set_text(e, f.eid("category-value"), f.value(e, f.eid("field-category")));
    if (c.editor) {
        try f.show(e, f.eid("details-body"), c.details_open);
        try f.set_text(e, f.eid("details-toggle"), if (c.details_open) "More details ▴" else "More details ▾");
    }
    try f.show(e, f.aid("range-body"), c.range_open);
    try f.show(e, f.aid("bulk-details-body"), c.bulk_open);
    try desktop.restore_selection(c.selection);
    f.remember_inputs(e);
    try f.render(e);
    f.redraw(e);
    for (c.scrolls) |scroll| if (e.tree.get(scroll.id)) |n| {
        if (std.math.isFinite(scroll.x) and std.math.isFinite(scroll.y)) {
            n.scroll_x = @max(0, scroll.x);
            n.scroll_y = @max(0, scroll.y);
        }
    };
    f.redraw(e);
    desktop.focus(e, c.focus);
    if (c.pending_files.len > 0) {
        const json = try std.json.Stringify.valueAlloc(e.gpa, c.pending_files, .{});
        defer e.gpa.free(json);
        try desktop.receive(e, json);
    }
}
