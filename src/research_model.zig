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
pub const Status = struct { label: []const u8, ready: bool, custom: bool, downloading: bool, size_mb: u32, path: []const u8 = "" };
/// A model already on this computer that research can run on.
pub const Option = struct { path: []const u8, name: []const u8, app: []const u8, size_mb: u32, current: bool };
fn root(a: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(a, &.{ try oriel.paths.appData(a, .{ .name = app.build.id }), "categorization-model" });
}
fn choice(a: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(a, &.{ try root(a), "choice.json" });
}
fn default_path(a: std.mem.Allocator) ![:0]const u8 {
    return std.fs.path.joinZ(a, &.{ try root(a), filename });
}
fn custom_path(io: std.Io, a: std.mem.Allocator) !?[:0]const u8 {
    const json = std.Io.Dir.cwd().readFileAlloc(io, try choice(a), a, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
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
    const custom = try custom_path(io, a);
    const path = custom orelse try default_path(a);
    if (custom == null) files.independent_file(io, path) catch return error.CategorizationModelRequired;
    validate(io, path) catch return error.CategorizationModelRequired;
    return path;
}
pub fn status(io: std.Io, a: std.mem.Allocator) !Status {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const custom = try custom_path(io, a);
    const path = custom orelse try default_path(a);
    const independent = if (custom != null) true else if (files.independent_file(io, path)) |_| true else |_| false;
    const ready = independent and if (validate(io, path)) |_| true else |_| false;
    return .{ .label = if (custom != null) std.fs.path.basename(path) else label, .ready = ready, .custom = custom != null, .downloading = downloading.load(.acquire), .size_mb = @intCast(size >> 20), .path = path };
}
/// Text models already on this computer: Penny's own downloads and those of
/// LM Studio, GhostPen and the Hugging Face cache. Projectors, embedding and
/// speculative-decoding helpers and later split shards cannot run research.
pub fn options(io: std.Io, a: std.mem.Allocator) ![]Option {
    if (comptime oriel.target.os != .linux or oriel.target.is_android) return error.DesktopResearchUnavailable;
    const own = try oriel.paths.appData(a, .{ .name = app.build.id });
    var roots: std.ArrayList(files.Root) = .empty;
    try roots.append(a, .{ .path = try root(a), .app = "Penny Goblin" });
    try roots.append(a, .{ .path = try std.fs.path.join(a, &.{ own, "models" }), .app = "Penny Goblin" });
    try roots.appendSlice(a, try files.sharedRoots(a));
    const current = blk: {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        const path = try custom_path(io, a) orelse try default_path(a);
        break :blk std.Io.Dir.cwd().statFile(io, path, .{}) catch null;
    };
    var list: std.ArrayList(Option) = .empty;
    for (try files.scan(io, a, roots.items)) |found| {
        if (!files.runnable(found)) continue;
        const name = std.fs.path.basename(found.path);
        try list.append(a, .{
            .path = found.path,
            .name = name[0 .. name.len - ".gguf".len],
            .app = found.app,
            .size_mb = @intCast(found.size >> 20),
            .current = if (current) |c| c.inode == found.inode and c.size == found.size else false,
        });
    }
    return list.items;
}
/// Research on one of `options`: only a listed file, never an arbitrary path
/// from the interface.
pub fn use(io: std.Io, a: std.mem.Allocator, path: []const u8) !void {
    for (try options(io, a)) |option| if (std.mem.eql(u8, option.path, path)) {
        if (std.mem.eql(u8, path, try default_path(a))) return use_default(io, a);
        return choose(io, a, path);
    };
    return error.InvalidModel;
}
pub fn pick(io: std.Io, a: std.mem.Allocator) !void {
    if (comptime oriel.target.os != .linux or oriel.target.is_android) return error.DesktopResearchUnavailable;
    const path = try oriel.dialog.openFile(a, .{ .title = "Choose categorization GGUF (Qwen 9B or another instruction model)", .filter = .{ .name = "GGUF model", .extensions = &.{"gguf"} } }) orelse return;
    try choose(io, a, path);
}
fn choose(io: std.Io, a: std.mem.Allocator, path: []const u8) !void {
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
    std.Io.Dir.cwd().deleteFile(io, try choice(a)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
pub fn cancelDownload() void {
    cancelled.store(true, .release);
}
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
