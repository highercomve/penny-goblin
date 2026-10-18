//! A native-renderer page's `<input type=file>` (-Dnative_ui): the file the
//! user picks, in two steps. `nui:pick_file` waits for the user on an IPC
//! worker (the phones' pickers refuse the UI thread, src/core/ipc.zig) and
//! keeps the picked path under a one-time token; `nui:picked_file`, on the
//! page's thread with its engine (src/core/native_commands.zig), opens that
//! file into the engine's file table, as a dropped file. A page only ever
//! gets handles for files the user chose, never a path it names.

const std = @import("std");
const common = @import("common.zig");
const heap = @import("../../core/heap.zig");

pub const pick_command = "nui:pick_file";
pub const picked_command = "nui:picked_file";

/// `extensions`: the input's accept list as extensions ("pdf", "png"),
/// without dots; the desktops' dialogs offer only those.
pub const Args = struct {
    extensions: []const []const u8 = &.{},
};

/// Picks the page hasn't taken yet: a few, the oldest dropped past that.
const max_pending = 8;
const Pending = struct { token: u64, path: []u8 };
var pending: [max_pending]?Pending = @splat(null);
var next_token: u64 = 1;
var mutex: std.Io.Mutex = .init;

/// `nui:pick_file`: the native file dialog. `{"token":n}`, or null when the
/// user cancelled. Blocks until the user answers (an IPC worker's call).
pub fn pick(arena: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const dialog = @import("../dialog.zig");
    const a = std.json.parseFromValueLeaky(Args, arena, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidOptions;
    const path = try dialog.openFile(heap.gpa, .{ .filter = try filterOf(arena, a.extensions) }) orelse return arena.dupe(u8, "null");
    const token = keep(path);
    return std.fmt.allocPrint(arena, "{{\"token\":{d}}}", .{token});
}

/// The accept list's valid extensions as the dialog's filter (none: every file).
fn filterOf(arena: std.mem.Allocator, extensions: []const []const u8) !?common.Filter {
    var valid: std.ArrayList([]const u8) = .empty;
    for (extensions[0..@min(extensions.len, common.max_filter_extensions)]) |ext| {
        if (common.validExtension(ext)) try valid.append(arena, ext);
    }
    if (valid.items.len == 0) return null;
    return .{ .name = "Files", .extensions = valid.items };
}

/// Keep `path` (owned, heap.gpa) for the page to take; its token.
fn keep(path: []u8) u64 {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    var slot: usize = 0;
    for (pending, 0..) |p, i| {
        const entry = p orelse {
            slot = i;
            break;
        };
        // Full: the oldest pick goes.
        if (entry.token < pending[slot].?.token) slot = i;
    } else if (pending[slot]) |old| heap.gpa.free(old.path);
    const token = next_token;
    next_token += 1;
    pending[slot] = .{ .token = token, .path = path };
    return token;
}

/// The path picked under `token`, once (the caller frees it with `free`);
/// null for an unknown or already taken token.
pub fn take(token: u64) ?[]u8 {
    std.Io.Threaded.mutexLock(&mutex);
    defer std.Io.Threaded.mutexUnlock(&mutex);
    for (&pending) |*p| if (p.*) |entry| if (entry.token == token) {
        p.* = null;
        return entry.path;
    };
    return null;
}

pub fn free(path: []u8) void {
    heap.gpa.free(path);
}

/// `nui:picked_file`: the file picked under the page's token opened into
/// `drops` (the engine's file table, as a dropped file), as `fileJson`; null
/// for an unknown token or a file that can't be opened. Main thread.
pub fn openPicked(arena: std.mem.Allocator, drops: anytype, args_json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSliceLeaky(struct { token: u64 }, arena, args_json, .{ .ignore_unknown_fields = true }) catch return arena.dupe(u8, "null");
    const path = take(parsed.token) orelse return arena.dupe(u8, "null");
    defer free(path);
    const path_z = try arena.dupeZ(u8, path);
    const handle = (drops.addPath(path_z) catch return arena.dupe(u8, "null")) orelse return arena.dupe(u8, "null");
    const entry = drops.info(handle) orelse return arena.dupe(u8, "null");
    return fileJson(arena, path, entry.size, entry.mtimeMs(), handle) catch |err| {
        drops.release(handle);
        return err;
    };
}

/// What the page's File is told: `[mime, name, size, lastModifiedMs,
/// handle]` as JSON. The MIME type from the name, "" when unknown (as
/// browsers give it).
pub fn fileJson(arena: std.mem.Allocator, path: []const u8, size: u64, mtime_ms: i64, handle: u32) ![]u8 {
    const name = std.fs.path.basename(path);
    const mime = @import("../share/common.zig").mimeOf(name);
    const shown = if (std.mem.eql(u8, mime, "application/octet-stream")) "" else mime;
    return std.fmt.allocPrint(arena, "[{f},{f},{d},{d},{d}]", .{ std.json.fmt(shown, .{}), std.json.fmt(name, .{}), size, mtime_ms, handle });
}

test "picks are taken once, by token, and the oldest goes past the limit" {
    var tokens: [max_pending + 1]u64 = undefined;
    for (&tokens, 0..) |*t, i| t.* = keep(try std.fmt.allocPrint(heap.gpa, "/tmp/pick-{d}.pdf", .{i}));
    // The first went to make room for the last.
    try std.testing.expect(take(tokens[0]) == null);
    const last = take(tokens[max_pending]).?;
    defer free(last);
    try std.testing.expectEqualStrings("/tmp/pick-8.pdf", last);
    try std.testing.expect(take(tokens[max_pending]) == null);
    for (tokens[1..max_pending]) |t| free(take(t).?);
}

test filterOf {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try filterOf(arena.allocator(), &.{}) == null);
    const f = (try filterOf(arena.allocator(), &.{ "pdf", "../x", "png" })).?;
    try std.testing.expectEqual(@as(usize, 2), f.extensions.len);
}

test fileJson {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("[\"application/pdf\",\"cartola.pdf\",1200,5,3]", try fileJson(arena.allocator(), "/cache/picked/cartola.pdf", 1200, 5, 3));
    try std.testing.expectEqualStrings("[\"\",\"notes\",0,0,1]", try fileJson(arena.allocator(), "notes", 0, 0, 1));
}
