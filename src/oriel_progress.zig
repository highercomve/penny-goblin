//! The web scan's stage progress and sweep, driven by native display frames.
const std = @import("std");
const oriel = @import("oriel");
const f = @import("oriel_frontend.zig");
const ui = f.ui;
const View = ui.View(@embedFile("progress.oriel"));
pub const base: i64 = 19600;
// "desktop": a phone paired with a reachable desktop, whose scanner reads it.
const stages = [_][]const u8{ "preparing", "text", "desktop", "loading", "reading", "writing" };
const messages = [_][]const u8{ "Preparing the image", "Reading receipt text", "Reading the voucher on your desktop", "Loading the AI scanner", "Reading the voucher with AI", "Extracting payment details" };
const desktop = 2;
const defaults = [_]f64{ 500, 1000, 15000, 5000, 90000, 30000 };
var expected = defaults;
var measured: [stages.len]f64 = @splat(0);
/// The stages this scan goes through, as known so far: on this device (not
/// the desktop) until the desktop takes it, then ending there; all of them
/// when the desktop was tried and the device scans after all.
var counted: [stages.len]bool = undefined;
var current: usize = 0;
var elapsed: f64 = 0;
var sweep_ms: f64 = 0;
var active = false;
var program: ui.Program = undefined;
pub const Task = enum { scan, save, delete, settings, legacy, statement, sync, download, report, refresh };
const Entry = struct { kind: Task, title: [512]u8 = undefined, len: usize = 0, value: ?f64 = null };
var tasks: [@typeInfo(Task).@"enum".fields.len]Entry = undefined;
var task_count: usize = 0;
var indeterminate_ms: f64 = 0;

pub fn prepare(e: *ui.Engine) !void {
    active = false;
    task_count = 0;
    indeterminate_ms = 0;
    expected = defaults;
    program = .init(e.gpa);
    try View.prepare(&e.tree, 79600);
    _ = try View.mount(&e.tree, base, 79600, &.{});
    try f.show(e, base, false);
}

pub fn shutdown() void {
    program.deinit();
}

/// Most recently started work is shown. Updates retain its stack position.
pub fn task(e: *ui.Engine, kind: Task, title: []const u8, value: ?f64) !void {
    if (title.len > 512) return error.ProgressMessageTooLong;
    var index: usize = 0;
    while (index < task_count and tasks[index].kind != kind) : (index += 1) {}
    if (index == task_count) {
        tasks[index] = .{ .kind = kind };
        task_count += 1;
    }
    @memcpy(tasks[index].title[0..title.len], title);
    tasks[index].len = title.len;
    tasks[index].value = value;
    try f.show(e, base, true);
    try f.overlay(e);
    e.removeFrameHooks(&task_count);
    try e.addFrameHook(.{ .ctx = &task_count, .func = frame });
}

pub fn end(e: *ui.Engine, kind: Task) !void {
    for (tasks[0..task_count], 0..) |entry, index| if (entry.kind == kind) {
        std.mem.copyForwards(Entry, tasks[index .. task_count - 1], tasks[index + 1 .. task_count]);
        task_count -= 1;
        break;
    };
    if (task_count == 0) {
        e.removeFrameHooks(&task_count);
        try f.show(e, base, false);
    }
}

pub fn resolved(e: *ui.Engine, request: f.Request) !void {
    const which: ?Task = switch (request) {
        .snapshot => .refresh,
        .save, .new_id => .save,
        .delete => .delete,
        .settings => .settings,
        .import_legacy => .legacy,
        .stage_pdf, .parse_pdf => .statement,
        .sync_action, .sync_resolve => .sync,
        .scanner_download => .download,
        .report, .export_pdf => .report,
        else => null,
    };
    if (which) |kind| try end(e, kind);
}

pub fn start(e: *ui.Engine) !void {
    current = 0;
    elapsed = 0;
    sweep_ms = 0;
    measured = @splat(0);
    for (&counted, 0..) |*on, index| on.* = index != desktop;
    active = true;
    try task(e, .scan, messages[0], 0);
}

pub fn stage(e: *ui.Engine, name: []const u8) !void {
    if (!active) return;
    for (stages, 0..) |candidate, index| if (std.mem.eql(u8, name, candidate)) {
        if (index <= current) return;
        measured[current] = elapsed;
        if (index == desktop) {
            for (&counted, 0..) |*on, i| on.* = i <= desktop;
        } else if (current == desktop) {
            // The desktop couldn't scan it: its time isn't a desktop scan's.
            measured[desktop] = 0;
            counted = @splat(true);
        }
        current = index;
        elapsed = 0;
        try task(e, .scan, messages[index], null);
        return;
    };
}

pub fn finish(e: *ui.Engine, success: bool) !void {
    if (!active) return;
    active = false;
    if (success) {
        measured[current] = elapsed;
        for (&expected, measured) |*want, actual| if (actual > 0) {
            want.* = actual;
        };
    }
    try end(e, .scan);
}

fn frame(_: *anyopaque, e: *ui.Engine, interval: f64) bool {
    if (task_count == 0) return false;
    draw(e, interval) catch |err| {
        std.log.err("scan animation: {s}", .{@errorName(err)});
        return false;
    };
    return task_count > 0;
}

fn draw(e: *ui.Engine, interval: f64) !void {
    indeterminate_ms = @mod(indeterminate_ms + interval, 1400);
    if (active) {
        elapsed += interval;
        sweep_ms = @mod(sweep_ms + interval, 2200);
        var total: f64 = 0;
        var before: f64 = 0;
        for (expected, counted, 0..) |duration, on, index| if (on) {
            total += duration;
            if (index < current) before += duration;
        };
        const fraction = 0.95 * (1 - @exp(-elapsed / @max(500, expected[current]) * 1.6));
        const progress = (before + fraction * expected[current]) / total;
        for (tasks[0..task_count]) |*entry| if (entry.kind == .scan) {
            entry.value = progress;
        };
    }
    const entry = tasks[task_count - 1];
    try f.set_text(e, View.id("message", base), entry.title[0..entry.len]);
    var label: [16]u8 = undefined;
    try f.set_text(e, View.id("percent", base), if (entry.value) |v| try std.fmt.bufPrint(&label, "{d:.0}%", .{std.math.clamp(v, 0, 1) * 100}) else "");
    var bar = e.tree.get(View.id("bar", base)).?.props;
    bar.w = .{ .pct = if (entry.value) |v| @floatCast(@max(2, std.math.clamp(v, 0, 1) * 100)) else 40 };
    const phase: f32 = @floatCast(indeterminate_ms / 1400);
    bar.tx = if (entry.value != null) 0 else (phase * phase * (3 - 2 * phase) * 1.4 - 0.4) * e.tree.width;
    try e.tree.updateUiProps(View.id("bar", base), bar);
    var root = e.tree.get(base).?.props;
    root.ins = .{ .{ .px = 60 }, .{ .px = 0 }, .auto, .{ .px = if (e.tree.width >= 840) 96 else 0 } };
    try e.tree.updateUiProps(base, root);
    if (!active) return;
    const node = e.tree.get(f.eid("scan-sweep")) orelse return;
    const width = node.frame.w;
    const height = node.frame.h;
    if (width <= 0 or height <= 0) return;
    program.begin();
    // CSS ease-in-out's symmetric sweep; a fresh transparent canvas each frame.
    const t: f32 = @floatCast(sweep_ms / 2200);
    const eased = t * t * (3 - 2 * t);
    const top = (-0.18 + 1.18 * eased) * height;
    const band = height * 0.18;
    const color: u24 = if (e.tree.dark) 0x9ad4ae else 0x2d6a4f;
    const gradient = program.linearGradient(0, top, 0, top + band);
    program.colorStop(gradient, 0, oriel.canvas.rgba(color, 0));
    program.colorStop(gradient, 0.85, oriel.canvas.rgba(color, 0.35));
    program.colorStop(gradient, 1, oriel.canvas.rgba(color, 1));
    program.fillGradient(gradient);
    program.fillRect(0, top, width, band);
    if (program.failed) return error.OutOfMemory;
    program.last_len = program.cmds.items.len;
    if (!e.tree.commitCanvas(node.id, program.cmds.items, &program.arena)) return error.MissingCanvas;
}
