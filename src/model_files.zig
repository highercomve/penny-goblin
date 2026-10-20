//! Shared pinned, resumable GGUF downloads for scanner and categorization.
const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const log = std.log.scoped(.model_files);
pub const Source = struct { repo: []const u8, revision: []const u8 };
pub const Event = struct { id: []const u8, state: []const u8, done_mb: u32 = 0, total_mb: u32 = 0 };
pub const Emit = *const fn (Event) void;
pub const Progress = struct { id: []const u8, emit: Emit, total_mb: u32, cancelled: *std.atomic.Value(bool) };
/// Old versions reused mutable cache links. Require a private copy for pinned
/// downloads; user-selected external model paths remain an explicit choice.
pub fn independent_file(io: std.Io, path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.nlink > 1) return error.InvalidModel;
}
pub fn fetchFile(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, dir: []const u8, remote: []const u8, local: []const u8, size: u64, sha256: []const u8, entry: Source, progress: Progress, offset: u64) !void {
    if (try reuse(io, arena, try scan(io, arena, try sharedRoots(arena)), dir, local, size, sha256, progress.cancelled)) return;
    const url = try std.fmt.allocPrint(arena, "https://huggingface.co/{s}/resolve/{s}/{s}", .{ entry.repo, entry.revision, remote });
    // A server that ignores the range of a resume restarts once from zero.
    for (0..2) |_| if (try attempt(io, gpa, arena, url, dir, local, size, sha256, progress, offset)) return;
    return error.BadHttpStatus;
}

/// False when a resume's range was ignored (the .part is gone; try again).
fn attempt(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, url: []const u8, dir: []const u8, local: []const u8, size: u64, sha256: []const u8, progress: Progress, offset: u64) !bool {
    const final = try std.fs.path.join(arena, &.{ dir, local });
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{final});
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    const have = try hashExisting(io, part, size, &hasher, progress.cancelled);
    var file = if (have > 0)
        try std.Io.Dir.cwd().openFile(io, part, .{ .mode = .write_only })
    else
        try std.Io.Dir.cwd().createFile(io, part, .{});
    var closed = false;
    defer if (!closed) file.close(io);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var url_bufs: [2][8 * 1024]u8 = undefined;
    var redirect_buf: [16 * 1024]u8 = undefined;
    var uri = try std.Uri.parse(url);
    var req: std.http.Client.Request = undefined;
    var response: std.http.Client.Response = undefined;
    var hops: u8 = 0;
    // Hugging Face redirects to its CDN: follow by hand, HTTPS only.
    while (true) : (hops += 1) {
        if (hops == 6) return error.TooManyHttpRedirects;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InsecureModelUrl;
        var range_buf: [64]u8 = undefined;
        const extra: []const std.http.Header = if (have > 0)
            &.{.{ .name = "Range", .value = try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{have}) }}
        else
            &.{};
        req = try client.request(.GET, uri, .{
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = extra,
            .redirect_behavior = .unhandled,
        });
        errdefer req.deinit();
        try req.sendBodiless();
        response = try req.receiveHead(&redirect_buf);
        if (response.head.status.class() != .redirect) break;
        const location = response.head.location orelse return error.HttpRedirectLocationMissing;
        const buffer = &url_bufs[hops % 2];
        if (location.len > buffer.len) return error.HttpRedirectLocationOversize;
        @memcpy(buffer[0..location.len], location);
        var aux: []u8 = buffer;
        uri = try uri.resolveInPlace(location.len, &aux);
        req.deinit();
    }
    defer req.deinit();
    if (have > 0 and response.head.status == .ok) {
        file.close(io);
        closed = true;
        std.Io.Dir.cwd().deleteFile(io, part) catch {};
        return false;
    }
    if (response.head.status != (if (have > 0) std.http.Status.partial_content else std.http.Status.ok)) return error.BadHttpStatus;

    var transfer_buf: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    var chunk: [64 * 1024]u8 = undefined;
    var done = have;
    var last_mb: u64 = (offset + done) >> 20;
    while (done <= size) {
        if (progress.cancelled.load(.acquire)) return error.Cancelled;
        const n = reader.readSliceShort(&chunk) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        };
        if (n == 0) break;
        if (n > size - done) return error.Truncated;
        hasher.update(chunk[0..n]);
        file.writePositionalAll(io, chunk[0..n], done) catch return error.WriteFailed;
        done += n;
        if ((offset + done) >> 20 != last_mb) {
            last_mb = (offset + done) >> 20;
            progress.emit(.{ .id = progress.id, .state = "downloading", .done_mb = @intCast(last_mb), .total_mb = progress.total_mb });
        }
    }
    try file.sync(io);
    file.close(io);
    closed = true;
    if (done != size) return error.Truncated;
    const got = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    if (!std.mem.eql(u8, &got, sha256)) {
        std.Io.Dir.cwd().deleteFile(io, part) catch {};
        return error.ChecksumMismatch;
    }
    try std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), final, io);
    log.info("downloaded {s} ({d} MB)", .{ local, done >> 20 });
    return true;
}

/// A GGUF file another local AI app (or Penny itself) keeps.
pub const Found = struct { path: []const u8, size: u64, inode: std.Io.File.INode, app: []const u8 };
pub const Root = struct { path: []const u8, app: []const u8 };

/// Model folders of other local AI apps on this computer: LM Studio, GhostPen
/// and the Hugging Face cache.
pub fn sharedRoots(arena: std.mem.Allocator) ![]const Root {
    var roots: std.ArrayList(Root) = .empty;
    if (comptime builtin.abi.isAndroid() or builtin.os.tag == .ios) return roots.items;
    if (std.c.getenv(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME")) |home_z| {
        const home = std.mem.span(home_z);
        try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ home, ".lmstudio", "models" }), .app = "LM Studio" });
        try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ home, ".cache", "lm-studio", "models" }), .app = "LM Studio" });
        try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ home, ".cache", "huggingface", "hub" }), .app = "Hugging Face" });
    }
    if (oriel.paths.appData(arena, .{ .name = "GhostPen" })) |ghostpen| {
        try roots.append(arena, .{ .path = try std.fs.path.join(arena, &.{ ghostpen, "models" }), .app = "GhostPen" });
    } else |_| {}
    return roots.items;
}

/// Every .gguf file under `roots` (a few levels deep, bounded), each once even
/// when hard-linked under several names.
pub fn scan(io: std.Io, arena: std.mem.Allocator, roots: []const Root) ![]const Found {
    var found: std.ArrayList(Found) = .empty;
    for (roots) |root| {
        var top = std.Io.Dir.cwd().openDir(io, root.path, .{ .iterate = true }) catch continue;
        defer top.close(io);
        var walker = try top.walk(arena);
        defer walker.deinit();
        var visited: usize = 0;
        while (walker.next(io) catch null) |entry| : (visited += 1) {
            if (visited == 20000) break;
            if (entry.kind == .directory and entry.depth() >= 5) walker.leave(io);
            if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.basename, ".gguf")) continue;
            const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            const seen = for (found.items) |other| {
                if (other.inode == stat.inode and other.size == stat.size) break true;
            } else false;
            if (seen) continue;
            try found.append(arena, .{ .path = try std.fs.path.join(arena, &.{ root.path, entry.path }), .size = stat.size, .inode = stat.inode, .app = root.app });
        }
    }
    return found.items;
}

/// A model llama can run on its own: not a vision projector, embedding or
/// speculative-decoding helper, nor a later shard of a split model.
pub fn runnable(found: Found) bool {
    const name = std.fs.path.basename(found.path);
    if (found.size < 100 << 20 or isProjector(name)) return false;
    for ([_][]const u8{ "embed", "mtp-" }) |needle| if (std.ascii.indexOfIgnoreCase(name, needle) != null) return false;
    return std.mem.indexOf(u8, name, "-of-") == null or std.mem.indexOf(u8, name, "-00001-of-") != null;
}
pub fn isProjector(name: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(name, "mmproj") != null;
}

/// Use an identical copy another app already downloaded instead of fetching
/// it again, matched by size and SHA-256 whatever its name there (GhostPen
/// calls a projector `<model>.mmproj.gguf`). Keep a verified independent copy:
/// another application may modify or replace its cached model later.
fn reuse(io: std.Io, arena: std.mem.Allocator, candidates: []const Found, dir: []const u8, local: []const u8, size: u64, sha256: []const u8, cancelled: *std.atomic.Value(bool)) !bool {
    const final = try std.fs.path.join(arena, &.{ dir, local });
    for (candidates) |candidate| {
        if (candidate.size != size) continue;
        var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
        if ((hashFile(io, candidate.path, &hasher, cancelled, size) catch |err| switch (err) {
            error.Cancelled => return err,
            else => continue,
        }) != size) continue;
        const got = std.fmt.bytesToHex(hasher.finalResult(), .lower);
        if (!std.mem.eql(u8, &got, sha256)) continue;
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const temporary = try std.fmt.allocPrint(arena, "{s}-{s}.tmp", .{ final, std.fmt.bytesToHex(random, .lower) });
        copy_model(io, candidate.path, temporary, size, cancelled) catch |err| switch (err) {
            error.Cancelled => return err,
            else => continue,
        };
        defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        var copied: std.crypto.hash.sha2.Sha256 = .init(.{});
        const copied_size = hashFile(io, temporary, &copied, cancelled, size) catch |err| switch (err) {
            error.Cancelled => return err,
            else => continue,
        };
        if (copied_size != size or !std.mem.eql(u8, &std.fmt.bytesToHex(copied.finalResult(), .lower), sha256)) continue;
        try std.Io.Dir.cwd().rename(temporary, .cwd(), final, io);
        log.info("reused {s} from {s}", .{ local, candidate.path });
        return true;
    }
    return false;
}

fn copy_model(io: std.Io, source: []const u8, destination: []const u8, size: u64, cancelled: *std.atomic.Value(bool)) !void {
    const input = try std.Io.Dir.cwd().openFile(io, source, .{});
    defer input.close(io);
    const output = try std.Io.Dir.cwd().createFile(io, destination, .{ .exclusive = true, .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) });
    errdefer std.Io.Dir.cwd().deleteFile(io, destination) catch {};
    defer output.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var reader = input.reader(io, &buffer);
    var have: u64 = 0;
    while (have <= size) {
        if (cancelled.load(.acquire)) return error.Cancelled;
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        if (n > size - have) return error.ModelTooLarge;
        try output.writeStreamingAll(io, chunk[0..n]);
        have += n;
    }
    if (have != size) return error.Truncated;
    try output.sync(io);
}

fn hashFile(io: std.Io, path: []const u8, hasher: *std.crypto.hash.sha2.Sha256, cancelled: *std.atomic.Value(bool), maximum: u64) !u64 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [256 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var have: u64 = 0;
    while (have <= maximum) {
        if (cancelled.load(.acquire)) return error.Cancelled;
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (chunk.len > maximum - have) return error.ModelTooLarge;
        hasher.update(chunk);
        have += chunk.len;
        reader.interface.toss(chunk.len);
    }
    return have;
}

/// Hash what an interrupted download left; a complete or oversized .part restarts.
fn hashExisting(io: std.Io, part: []const u8, size: u64, hasher: *std.crypto.hash.sha2.Sha256, cancelled: *std.atomic.Value(bool)) !u64 {
    const have = hashFile(io, part, hasher, cancelled, size) catch |err| switch (err) {
        error.FileNotFound => return 0,
        error.ModelTooLarge => size,
        else => return err,
    };
    if (have < size) return have;
    hasher.* = .init(.{});
    std.Io.Dir.cwd().deleteFile(io, part) catch {};
    return 0;
}

test "a download reuses another app's identical model by content, not name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, ".lmstudio/models/vendor/Model-GGUF");
    try tmp.dir.createDirPath(io, "penny");
    const bytes = "GGUF" ++ "x" ** 4096;
    try tmp.dir.writeFile(io, .{ .sub_path = ".lmstudio/models/vendor/Model-GGUF/other-name.gguf", .data = bytes });
    const digest = std.fmt.bytesToHex(blk: {
        var out: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
        break :blk out;
    }, .lower);
    const found = try scan(io, a, &.{ .{ .path = try std.fs.path.join(a, &.{ base, "missing" }), .app = "None" }, .{ .path = try std.fs.path.join(a, &.{ base, ".lmstudio", "models" }), .app = "LM Studio" } });
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("LM Studio", found[0].app);
    var cancelled = std.atomic.Value(bool).init(false);
    const dir = try std.fs.path.join(a, &.{ base, "penny" });
    try std.testing.expect(!try reuse(io, a, found, dir, "wanted.gguf", bytes.len, "0" ** 64, &cancelled));
    try std.testing.expect(!try reuse(io, a, found, dir, "wanted.gguf", bytes.len + 1, &digest, &cancelled));
    try std.testing.expect(try reuse(io, a, found, dir, "wanted.gguf", bytes.len, &digest, &cancelled));
    try independent_file(io, try std.fs.path.join(a, &.{ dir, "wanted.gguf" }));
    try std.testing.expectEqualStrings(bytes, try tmp.dir.readFileAlloc(io, "penny/wanted.gguf", a, .limited(1 << 20)));
    try tmp.dir.writeFile(io, .{ .sub_path = ".lmstudio/models/vendor/Model-GGUF/other-name.gguf", .data = "GGUFchanged" });
    try std.testing.expectEqualStrings(bytes, try tmp.dir.readFileAlloc(io, "penny/wanted.gguf", a, .limited(1 << 20)));
}
