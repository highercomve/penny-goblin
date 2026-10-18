//! Research review controller; the backend owns inference and atomic writes.
const std = @import("std");
const f = @import("oriel_frontend.zig");
const ui = f.ui;
const domain = @import("core/categorization.zig");
const Sheet = ui.View(@embedFile("research-dialog.oriel"));
const Row = ui.View(@embedFile("research-proposal.oriel"));
const Source = ui.View(@embedFile("research-source.oriel"));
var allocator: std.mem.Allocator = undefined;
var seen: std.StringHashMapUnmanaged(void) = .empty;
pub const base: i64 = 20000;
const rows: i64 = 29000000;
const stride: i64 = 16;
var review: ?std.json.Parsed(domain.Review) = null;
pub var running = false;
var model_ready = false;
var model_busy = false;
var activity: std.ArrayList(u8) = .empty;
var update_count: usize = 0;
fn id(comptime name: []const u8) i64 { return Sheet.id(name, base); }
pub fn prepare(e: *ui.Engine) !void {
    review = null;
    allocator = e.gpa;
    seen = .empty;
    running = false;
    update_count = 0;
    model_ready = false;
    model_busy = false;
    try Sheet.prepare(&e.tree, 80000);
    try Row.prepare(&e.tree, 81000);
    try Source.prepare(&e.tree, 82000);
}
fn clear_review() void {
    if (review) |value| value.deinit();
    review = null;
}
pub fn shutdown() void {
    clear_review();
    activity.deinit(allocator);
    activity = .empty;
    var keys = seen.keyIterator();
    while (keys.next()) |key| allocator.free(key.*);
    seen.deinit(allocator);
    seen = .empty;
}
pub fn open(e: *ui.Engine) !void {
    if (f.s.busy or f.s.modal != .none or f.s.snapshot == null) return;
    shutdown();
    _ = try Sheet.mount(&e.tree, base, 80000, &.{});
    f.s.modal = .research;
    f.s.dirty = false;
    try ui.setVisible(&e.tree, base, true);
    try f.resize_modal(e, base);
    try f.mark_actions(e, Sheet, base, .{ "close", "start", "cancel", "apply", "model-download", "model-pick", "model-default", "model-cancel", "details-toggle" });
    try f.show(e, id("details"), false);
    try f.show(e, id("cancel"), false);
    try f.show(e, id("activity-panel"), false);
    try f.show(e, id("apply"), false);
    try f.show(e, id("model-cancel"), false);
    try f.show(e, id("model-default"), false);
    try f.invoke(e, .research_model_status, "research_model_status", .{});
    const mobile = std.mem.eql(u8, f.s.snapshot.?.value.platform, "android");
    try f.show(e, id("model-controls"), !mobile);
    if (mobile) try f.set_text(e, id("model-status"), "Uses your paired desktop model. Configure it on the desktop first.");
    if (!mobile and !f.s.snapshot.?.value.vision_available) try f.set_text(e, id("status"), "This build needs local model support. Build with vision enabled.");
    try f.overlay(e);
    f.redraw(e);
}
pub fn stop(e: *ui.Engine) !void {
    try f.invoke(e, .cancel, "cancel_research", .{});
    try f.set_text(e, id("status"), "Stopping research… The current page may take up to 25 seconds.");
}
pub fn click(e: *ui.Engine, node: i64) !bool {
    if (node == id("details-toggle")) {
        try f.disclosure(e, id("details-toggle"), id("details"), "Model & privacy details");
        return true;
    }
    if (node == id("close")) { try f.request_close(e); return true; }
    if (node == id("cancel")) { try stop(e); return true; }
    if (node == id("model-cancel")) { try f.invoke(e, .cancel, "cancel_research_model", .{}); return true; }
    inline for (.{ "download", "pick", "default" }) |action| if (node == id("model-" ++ action)) {
        if (f.s.busy or model_busy) return true;
        model_busy = true;
        try f.show(e, id("model-cancel"), std.mem.eql(u8, action, "download"));
        try f.set_text(e, id("model-status"), "Setting up categorization model…");
        try f.invoke(e, .research_model_action, "research_model_" ++ action, .{});
        return true;
    };
    if (node == id("start")) {
        if (f.s.busy or model_busy) return true;
        if (!model_ready) { try f.set_text(e, id("status"), "Choose or download a categorization model first."); return true; }
        if (review) |current| for (current.value.proposals, 0..) |_, i| {
            if (f.value(e, Row.id("category", rows + @as(i64, @intCast(i)) * stride)).len > 0) {
                try f.set_text(e, id("status"), "Apply suggestions or leave them unchanged before researching the next batch.");
                return true;
            }
        };
        var arena = std.heap.ArenaAllocator.init(e.gpa);
        defer arena.deinit();
        var ids: std.ArrayList([]const u8) = .empty;
        for (f.s.selected.items) |row| if (!seen.contains(row.id) and domain.eligible(row, f.settings())) try ids.append(arena.allocator(), row.id);
        if (ids.items.len == 0) {
            try f.show(e, id("activity-panel"), false);
            try f.set_text(e, id("status"), "No eligible uncategorized variable payments match the current filters. Close this view and select Uncategorized or All categories, clear search, or choose another period. Fixed and special payments are excluded.");
            return true;
        }
        clear_review();
        activity.clearRetainingCapacity();
        update_count = 0;
        try f.set_text(e, id("progress"), "Waiting for desktop…");
        try f.set_text(e, id("merchant"), "");
        try f.set_text(e, id("activity"), "Connecting to research…");
        try f.show(e, id("start"), false);
        try f.show(e, id("activity-panel"), true);
        _ = try e.tree.stampKids(id("results"), &.{});
        f.s.busy = true;
        running = true;
        f.s.dirty = false;
        try f.show(e, id("apply"), false);
        try f.show(e, id("cancel"), true);
        try f.set_text(e, id("status"), "Loading desktop model…");
        try f.invoke(e, .research_run, "research_categories", .{ .ids = ids.items });
        return true;
    }
    if (node == id("apply")) {
        if (f.s.busy or review == null) return true;
        var arena = std.heap.ArenaAllocator.init(e.gpa);
        defer arena.deinit();
        var selected: std.ArrayList(domain.Selection) = .empty;
        for (review.?.value.proposals, 0..) |group, i| {
            const choice = f.value(e, Row.id("category", rows + @as(i64, @intCast(i)) * stride));
            if (choice.len > 0) try selected.append(arena.allocator(), .{ .targets = group.targets, .category = choice });
        }
        if (selected.items.len == 0) { try f.set_text(e, id("status"), "Choose at least one category to apply."); return true; }
        f.s.busy = true;
        try f.invoke(e, .research_apply, "apply_research", domain.Apply{ .expected_settings = review.?.value.expected_settings, .selections = selected.items });
        return true;
    }
    if (review) |value| for (value.value.proposals, 0..) |group, i| {
        for (group.sources, 0..) |source, j| {
            const source_id = 29010000 + @as(i64, @intCast(i)) * 128 + @as(i64, @intCast(j)) * 16;
            if (node == Source.id("toggle", source_id)) {
                try f.disclosure(e, Source.id("toggle", source_id), Source.id("body", source_id), if (source.title.len > 0) source.title else source.url);
                return true;
            }
            if (node == Source.id("open", source_id)) {
                try f.invoke(e, .research_source, "open_research_source", .{ .url = source.url });
                return true;
            }
        }
    };
    return false;
}
pub fn resolved(e: *ui.Engine, request: f.Request, ok: bool, json: []const u8) !void {
    f.finish(request);
    if (request == .research_run) running = false;
    if (f.s.modal != .research) return;
    if (request == .research_model_status) {
        if (!ok) { try f.report_error(e, id("model-status"), json); return; }
        const encoded = try std.json.parseFromSlice([]const u8, e.gpa, json, .{});
        defer encoded.deinit();
        const state = try std.json.parseFromSlice(@import("research_model.zig").Status, e.gpa, encoded.value, .{});
        defer state.deinit();
        model_ready = state.value.ready;
        model_busy = state.value.downloading;
        if (!model_ready or model_busy) {
            try f.show(e, id("details"), true);
            try f.set_text(e, id("details-toggle"), "Model & privacy details ▴");
        }
        try f.show(e, id("model-default"), state.value.custom);
        try f.show(e, id("model-cancel"), state.value.downloading);
        const mobile = std.mem.eql(u8, f.s.snapshot.?.value.platform, "android");
        const label = if (mobile and !state.value.ready) try std.fmt.allocPrint(e.gpa, "{s} · Configure this model on the desktop first.", .{state.value.label}) else try std.fmt.allocPrint(e.gpa, "{s} · {s}", .{ state.value.label, if (state.value.downloading) "Downloading" else "Ready on desktop" });
        defer e.gpa.free(label);
        try f.set_text(e, id("model-status"), label);
        return;
    }
    if (request == .research_model_action) {
        model_busy = false;
        if (!ok) try f.report_error(e, id("status"), json);
        try f.invoke(e, .research_model_status, "research_model_status", .{});
        return;
    }
    if (request == .research_run) {
        try f.show(e, id("start"), true);
        try f.set_text(e, id("progress"), if (ok) "Batch complete · review suggestions below" else "Research stopped · see status above");
    }
    try f.show(e, id("cancel"), false);
    if (!ok) { try f.report_error(e, id("status"), json); return; }
    if (request == .research_apply) {
        clear_review();
        f.s.dirty = false;
        _ = try e.tree.stampKids(id("results"), &.{});
        try f.show(e, id("apply"), false);
        try f.set_text(e, id("status"), "Selected payments categorized.");
        try f.refresh(e);
        return;
    }
    if (request != .research_run) return;
    const encoded = try std.json.parseFromSlice([]const u8, e.gpa, json, .{});
    defer encoded.deinit();
    clear_review();
    review = try std.json.parseFromSlice(domain.Review, e.gpa, encoded.value, .{ .allocate = .alloc_always });
    if (review.?.value.proposals.len > 10) return error.InvalidModelReply;
    for (review.?.value.proposals) |group| for (group.targets) |target| if (!seen.contains(target.id)) {
        const owned = try allocator.dupe(u8, target.id);
        errdefer allocator.free(owned);
        try seen.put(allocator, owned, {});
    };
    try render(e);
}
fn render(e: *ui.Engine) !void {
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var children: std.ArrayList(i64) = .empty;
    var categories: std.ArrayList([]const u8) = .empty;
    try categories.append(a, "");
    const config = f.settings();
    if (config.categories == .object) {
        var keys = config.categories.object.iterator();
        while (keys.next()) |entry| if (domain.category_exists(config, entry.key_ptr.*)) try categories.append(a, entry.key_ptr.*);
    }
    const labels = try a.dupe([]const u8, categories.items);
    labels[0] = "Leave unchanged";
    for (review.?.value.proposals, 0..) |group, i| {
        const row = rows + @as(i64, @intCast(i)) * stride;
        const reason = try std.fmt.allocPrint(a, "{d} payments · {s}", .{ group.targets.len, group.reason });
        _ = try Row.mount(&e.tree, row, 81000, &.{ .{ .name = "merchant", .value = group.merchant }, .{ .name = "reason", .value = reason } });
        try f.options(e, Row.id("category", row), categories.items, labels, group.category);
        if (group.sources.len > 6) return error.InvalidModelReply;
        var source_ids: std.ArrayList(i64) = .empty;
        for (group.sources, 0..) |source, j| {
            const source_id = 29010000 + @as(i64, @intCast(i)) * 128 + @as(i64, @intCast(j)) * 16;
            const title = try std.fmt.allocPrint(a, "{s} ▾", .{if (source.title.len > 0) source.title else source.url});
            _ = try Source.mount(&e.tree, source_id, 82000, &.{ .{ .name = "title", .value = title }, .{ .name = "quote", .value = source.quote } });
            try f.mark_actions(e, Source, source_id, .{ "toggle", "open" });
            try source_ids.append(a, source_id);
        }
        _ = try e.tree.stampKids(Row.id("sources", row), source_ids.items);
        try children.append(a, row);
    }
    _ = try e.tree.stampKids(id("results"), children.items);
    try f.show(e, id("apply"), review.?.value.proposals.len > 0);
    try f.set_text(e, id("status"), try std.fmt.allocPrint(a, "{d} merchants ready to review. {d} additional payments remain for another batch.", .{ review.?.value.proposals.len, review.?.value.remaining }));
    f.s.dirty = review.?.value.proposals.len > 0;
    try f.overlay(e);
}
pub fn progress(e: *ui.Engine, payload: std.json.Value) !void {
    if (!running or f.s.modal != .research or payload != .object) return;
    const event = try std.json.parseFromValue(@import("research_runtime.zig").Event, e.gpa, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const v = event.value;
    update_count += 1;
    try f.set_text(e, id("status"), v.stage);
    try f.set_text(e, id("merchant"), v.merchant);
    const label = try std.fmt.allocPrint(e.gpa, "{d}/{d} merchants complete · update {d}", .{ v.completed, v.total, update_count });
    defer e.gpa.free(label);
    try f.set_text(e, id("progress"), label);
    const line = try std.fmt.allocPrint(e.gpa, "{s}{s}{s}{s}{s}\n{s}\n", .{ v.merchant, if (v.merchant.len > 0) " · " else "", v.stage, if (v.detail.len > 0) ": " else "", v.detail, v.url });
    defer e.gpa.free(line);
    if (activity.items.len + line.len > 16000) activity.clearRetainingCapacity();
    try activity.insertSlice(e.gpa, 0, line);
    try f.set_text(e, id("activity"), activity.items);
    f.redraw(e);
}

pub fn model_progress(e: *ui.Engine, payload: std.json.Value) !void {
    if (f.s.modal != .research or payload != .object) return;
    const event_id = payload.object.get("id") orelse return;
    if (event_id != .string or !std.mem.eql(u8, event_id.string, "research-qwen3.5-9b")) return;
    const event = try std.json.parseFromValue(@import("model_files.zig").Event, e.gpa, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    var buffer: [128]u8 = undefined;
    try f.set_text(e, id("model-status"), try std.fmt.bufPrint(&buffer, "{s} · {d}/{d} MiB", .{ event.value.state, event.value.done_mb, event.value.total_mb }));
}
