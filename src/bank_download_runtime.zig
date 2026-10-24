//! Capture a BCI or Bank of America export from its isolated browser.
const std = @import("std");
const oriel = @import("oriel");
const statements = @import("core/statements.zig");
var mutex: std.Io.Mutex = .init;
pub const Capture = union(enum) { pdf: []const u8, rows: []const statements.Row };
const Reply = struct { pdf_base64: ?[]const u8 = null, rows: ?[]const statements.Row = null, @"error": []const u8 = "" };

pub fn capture(io: std.Io, a: std.mem.Allocator, bank: statements.Bank) !Capture {
    if (comptime oriel.target.os != .linux or oriel.target.is_android) return error.BankDesktopOnly;
    if (!mutex.tryLock()) return error.BankBrowserBusy;
    defer mutex.unlock(io);
    const result = std.process.run(a, io, .{
        .argv = &.{ try @import("runtime_helper.zig").browser_path(io, a), switch (bank) {
            .bci => "--bci",
            .boa => "--boa",
            .santander => return error.InvalidBankExport,
        } },
        .stdout_limit = .limited(44 * 1024 * 1024),
        .stderr_limit = .limited(128 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(15 * 60 + 10), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.BankBrowserUnavailable,
    };
    if (result.term != .exited or result.term.exited != 0) return error.BankBrowserUnavailable;
    const reply = try std.json.parseFromSliceLeaky(Reply, a, result.stdout, .{});
    if (std.mem.eql(u8, reply.@"error", "Cancelled")) return error.BankCancelled;
    if (std.mem.endsWith(u8, reply.@"error", "LoginTimedOut")) return error.BankLoginTimedOut;
    if (reply.@"error".len > 0) return error.BankBrowserUnavailable;
    if (bank == .boa) {
        if (reply.pdf_base64 != null) return error.InvalidBankExport;
        return .{ .rows = reply.rows orelse return error.InvalidBankExport };
    }
    if (reply.rows != null) return error.InvalidBankExport;
    const encoded = reply.pdf_base64 orelse return error.BankBrowserUnavailable;
    const data_url = try std.fmt.allocPrint(a, "data:application/pdf;base64,{s}", .{encoded});
    _ = try @import("core/statements.zig").pdf_bytes(a, data_url);
    return .{ .pdf = data_url };
}
