//! Shared pinned, resumable GGUF downloads for scanner and categorization.
const std = @import("std");
const log = std.log.scoped(.model_files);
pub const Source = struct { repo: []const u8, revision: []const u8 };
pub const Event = struct { id: []const u8, state: []const u8, done_mb: u32 = 0, total_mb: u32 = 0 };
pub const Emit = *const fn (Event) void;
pub const Progress = struct { id: []const u8, emit: Emit, total_mb: u32, cancelled: *std.atomic.Value(bool) };
pub fn fetchFile(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, dir: []const u8, remote: []const u8, local: []const u8, size: u64, sha256: []const u8, entry: Source, progress: Progress, offset: u64) !void {
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
    while (true) {
        if (progress.cancelled.load(.acquire)) return error.Cancelled;
        const n = reader.readSliceShort(&chunk) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        };
        if (n == 0) break;
        if (done + n > size) return error.Truncated;
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

/// Hash what an interrupted download left; a complete or oversized .part restarts.
fn hashExisting(io: std.Io, part: []const u8, size: u64, hasher: *std.crypto.hash.sha2.Sha256, cancelled: *std.atomic.Value(bool)) !u64 {
    const file = std.Io.Dir.cwd().openFile(io, part, .{}) catch |err| switch (err) { error.FileNotFound => return 0, else => return err };
    defer file.close(io);
    var buffer: [256 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var have: u64 = 0;
    while (true) {
        if (cancelled.load(.acquire)) return error.Cancelled;
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) { error.EndOfStream => break, else => return err };
        hasher.update(chunk);
        have += chunk.len;
        reader.interface.toss(chunk.len);
    }
    if (have < size) return have;
    hasher.* = .init(.{});
    std.Io.Dir.cwd().deleteFile(io, part) catch {};
    return 0;
}

