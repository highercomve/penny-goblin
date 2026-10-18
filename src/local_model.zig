//! Shared initialization and memory ownership for local inference jobs.
const std = @import("std");
const oriel = @import("oriel");
pub var mutex: std.Io.Mutex = .init;
var initialized = false;
/// Caller holds mutex for its entire model/context lifetime.
pub fn ensureBackend() void {
    if (comptime !oriel.llama.available) return;
    if (!initialized) {
        oriel.llama.silenceLogs();
        oriel.llama.initBackend();
        initialized = true;
    }
}

/// The app and paired-phone workers must not load multi-GB models together.
/// Kernel ownership releases this lease even when a worker is cancelled.
pub fn acquire(io: std.Io, a: std.mem.Allocator) !?std.Io.File {
    if (comptime oriel.target.os != .linux or oriel.target.is_android) return null;
    const dir = try oriel.paths.appData(a, .{ .name = @import("oriel_app").build.id });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(a, &.{ dir, "inference.lock" });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600) });
    errdefer file.close(io);
    if (!try file.tryLock(io, .exclusive)) return error.DesktopScannerBusy;
    return file;
}
pub fn release(io: std.Io, file: ?std.Io.File) void {
    if (file) |held| { held.unlock(io); held.close(io); }
}
