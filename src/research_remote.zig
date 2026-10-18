//! Phone client: jobs and writes remain on the authenticated paired desktop.
const std = @import("std");
const oriel = @import("oriel");
const runtime = @import("research_runtime.zig");
const domain = @import("core/categorization.zig");
const records = @import("core/sync_records.zig");
var running = std.atomic.Value(bool).init(false);
var cancelled = std.atomic.Value(bool).init(false);
var job_id: [32]u8 = undefined;
var has_job = false;
const Reply = struct { job: []const u8, state: []const u8, events: []const runtime.Event = &.{}, next: usize = 0, review: ?domain.Review = null, @"error": []const u8 = "" };
fn call(a: std.mem.Allocator, value: anytype) ![]const u8 {
    if (comptime !oriel.target.is_android) return error.MobileOnly;
    var diagnostic: oriel.extensions.Diagnostics = .{};
    return oriel.extensions.get("penny.sync").call(a, "research", try records.encode(a, value), .{ .timeout_ms = 90000, .diag = &diagnostic }) catch {
        if (std.mem.eql(u8, diagnostic.code(), "DesktopResearchUnavailable")) return error.DesktopResearchUnavailable;
        if (std.mem.eql(u8, diagnostic.code(), "NotPaired")) return error.NotPaired;
        if (std.mem.eql(u8, diagnostic.code(), "DesktopScannerBusy")) return error.DesktopScannerBusy;
        if (std.mem.eql(u8, diagnostic.code(), "RevisionConflict")) return error.RevisionConflict;
        if (std.mem.eql(u8, diagnostic.code(), "SettingsConflict")) return error.SettingsConflict;
        if (std.mem.eql(u8, diagnostic.code(), "ResearchJobNotFound")) return error.ResearchJobNotFound;
        return error.DesktopUnavailable;
    };
}
pub fn model(a: std.mem.Allocator) ![]const u8 { return call(a, .{ .action = "model" }); }
pub fn cancel() void { cancelled.store(true, .release); }
pub fn run(io: std.Io, a: std.mem.Allocator, ids: []const []const u8, emit: *const fn (runtime.Event) void) ![]const u8 {
    if (ids.len == 0 or ids.len > 10000) return error.InvalidSelection;
    if (running.swap(true, .acq_rel)) return error.ResearchAlreadyRunning;
    defer running.store(false, .release);
    cancelled.store(false, .release);
    const gpa = std.heap.smp_allocator;
    var response = try call(gpa, .{ .action = "start", .ids = ids });
    defer gpa.free(response);
    for (0..1500) |_| {
        var poll_arena = std.heap.ArenaAllocator.init(gpa);
        defer poll_arena.deinit();
        const p = poll_arena.allocator();
        const result = try std.json.parseFromSliceLeaky(Reply, p, response, .{});
        if (result.job.len != job_id.len) return error.InvalidModelReply;
        @memcpy(&job_id, result.job);
        has_job = true;
        for (result.events) |event| emit(event);
        if (cancelled.load(.acquire)) {
            _ = try call(p, .{ .action = "cancel", .job = @as([]const u8, &job_id) });
            return error.Cancelled;
        }
        if (std.mem.eql(u8, result.state, "ready")) return records.encode(a, result.review orelse return error.InvalidModelReply);
        if (std.mem.eql(u8, result.state, "cancelled")) return error.Cancelled;
        if (!std.mem.eql(u8, result.state, "running")) {
            emit(.{ .completed = 0, .total = 0, .stage = "Desktop research stopped", .detail = result.@"error" });
            return error.RemoteResearchFailed;
        }
        try std.Io.sleep(io, .fromSeconds(1), .awake);
        // Replies are bounded; free each one after its next cursor is copied.
        const next = result.next;
        const old = response;
        response = try call(gpa, .{ .action = "poll", .job = @as([]const u8, &job_id), .after = next });
        gpa.free(old);
    }
    return error.ResearchTimeLimit;
}
pub fn apply(a: std.mem.Allocator, edit: domain.Apply) !usize {
    if (running.swap(true, .acq_rel)) return error.ResearchAlreadyRunning;
    defer running.store(false, .release);
    if (!has_job) return error.ResearchJobNotFound;
    const result = try std.json.parseFromSliceLeaky(struct { count: usize }, a, try call(a, .{ .action = "apply", .job = @as([]const u8, &job_id), .edit = edit }), .{});
    return result.count;
}
