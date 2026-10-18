//! Device-local categorization model; independent from receipt scanning.
const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");
const files = @import("model_files.zig");
pub const id = "research-qwen3.5-9b";
pub const label = "Qwen3.5 9B (Q4_K_M)";
const filename = "Qwen3.5-9B-Q4_K_M.gguf";
const size: u64 = 5680522464;
const sha256 = "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8";
const source: files.Source = .{ .repo = "unsloth/Qwen3.5-9B-GGUF", .revision = "3885219b6810b007914f3a7950a8d1b469d598a5" };
var downloading = std.atomic.Value(bool).init(false);
var cancelled = std.atomic.Value(bool).init(false);
var mutex: std.Io.Mutex = .init;
pub const Status = struct { label: []const u8, ready: bool, custom: bool, downloading: bool, size_mb: u32 };
fn root(a: std.mem.Allocator) ![]const u8 { return std.fs.path.join(a, &.{ try oriel.paths.appData(a, .{ .name = app.build.id }), "categorization-model" }); }
fn choice(a: std.mem.Allocator) ![]const u8 { return std.fs.path.join(a, &.{ try root(a), "choice.json" }); }
fn default_path(a: std.mem.Allocator) ![:0]const u8 { return std.fs.path.joinZ(a, &.{ try root(a), filename }); }
fn custom_path(io: std.Io, a: std.mem.Allocator) !?[:0]const u8 {
    const json = std.Io.Dir.cwd().readFileAlloc(io, try choice(a), a, .limited(16 * 1024)) catch |err| switch (err) { error.FileNotFound => return null, else => return err };
    const path = try std.json.parseFromSliceLeaky([]const u8, a, json, .{ .allocate = .alloc_always });
    if (!std.fs.path.isAbsolute(path) or path.len > 4096) return error.InvalidModel;
    return try a.dupeZ(u8, path);
}
fn validate(io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const bytes = (try file.stat(io)).size;
    if (bytes < 1024 * 1024 or bytes > 32 * @as(u64, 1024 * 1024 * 1024)) return error.InvalidModel;
    var header: [4]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != 4 or !std.mem.eql(u8, &header, "GGUF")) return error.InvalidModel;
}
pub fn resolve(io: std.Io, a: std.mem.Allocator) ![:0]const u8 {
    if (comptime oriel.target.os != .linux or oriel.target.is_android) return error.DesktopResearchUnavailable;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const path = try custom_path(io, a) orelse try default_path(a);
    validate(io, path) catch return error.CategorizationModelRequired;
    return path;
}
pub fn status(io: std.Io, a: std.mem.Allocator) !Status {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const custom = try custom_path(io, a);
    const path = custom orelse try default_path(a);
    const ready = if (validate(io, path)) |_| true else |_| false;
    return .{ .label = if (custom != null) std.fs.path.basename(path) else label, .ready = ready, .custom = custom != null, .downloading = downloading.load(.acquire), .size_mb = @intCast(size >> 20) };
}
pub fn pick(io: std.Io, a: std.mem.Allocator) !void {
    if (comptime oriel.target.os != .linux or oriel.target.is_android) return error.DesktopResearchUnavailable;
    const path = try oriel.dialog.openFile(a, .{ .title = "Choose categorization GGUF (Qwen 9B or another instruction model)", .filter = .{ .name = "GGUF model", .extensions = &.{"gguf"} } }) orelse return;
    try validate(io, path);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    try std.Io.Dir.cwd().createDirPath(io, try root(a));
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, try choice(a), .{ .replace = true, .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600) });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, try std.json.Stringify.valueAlloc(a, path, .{}));
    try atomic.file.sync(io);
    try atomic.replace(io);
}
pub fn use_default(io: std.Io, a: std.mem.Allocator) !void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    std.Io.Dir.cwd().deleteFile(io, try choice(a)) catch |err| switch (err) { error.FileNotFound => {}, else => return err };
}
pub fn cancelDownload() void { cancelled.store(true, .release); }
pub fn download(io: std.Io, gpa: std.mem.Allocator, emit: files.Emit) !void {
    if (comptime oriel.target.os != .linux or oriel.target.is_android) return error.DesktopResearchUnavailable;
    if (downloading.swap(true, .acq_rel)) return error.AlreadyDownloading;
    defer downloading.store(false, .release);
    cancelled.store(false, .release);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try root(a);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const total: u32 = @intCast(size >> 20);
    files.fetchFile(io, gpa, a, dir, filename, filename, size, sha256, source, .{ .id = id, .emit = emit, .total_mb = total, .cancelled = &cancelled }, 0) catch |err| {
        emit(.{ .id = id, .state = if (err == error.Cancelled) "cancelled" else "error", .total_mb = total });
        return err;
    };
    try use_default(io, a);
    emit(.{ .id = id, .state = "done", .done_mb = total, .total_mb = total });
}
