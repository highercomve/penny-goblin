//! Native local calendar formatting for the compiled UI.
const std = @import("std");
const c = @cImport({
    @cDefine("_Nonnull", "");
    @cDefine("_Nullable", "");
    @cDefine("_Null_unspecified", "");
    @cInclude("time.h");
});

pub fn local_time(buffer: []u8, seconds: i64) ![]const u8 {
    var timestamp: c.time_t = @intCast(seconds);
    var calendar: c.struct_tm = undefined;
    if (comptime @import("builtin").os.tag == .windows) {
        if (c._localtime64_s(&calendar, &timestamp) != 0) return error.InvalidDate;
    } else if (c.localtime_r(&timestamp, &calendar) == null) return error.InvalidDate;
    const len = c.strftime(buffer.ptr, buffer.len, "%x, %H:%M", &calendar);
    if (len == 0) return error.InvalidDate;
    return buffer[0..len];
}

pub fn day_label(buffer: []u8, date: []const u8) ![]const u8 {
    if (!@import("core/model.zig").valid_date(date)) return error.InvalidDate;
    var calendar = std.mem.zeroes(c.struct_tm);
    calendar.tm_year = @as(c_int, try std.fmt.parseInt(u16, date[0..4], 10)) - 1900;
    calendar.tm_mon = @as(c_int, try std.fmt.parseInt(u8, date[5..7], 10)) - 1;
    calendar.tm_mday = try std.fmt.parseInt(u8, date[8..10], 10);
    calendar.tm_hour = 12;
    calendar.tm_isdst = -1;
    _ = c.mktime(&calendar);
    var prefix: [64]u8 = undefined;
    const len = c.strftime(&prefix, prefix.len, "%a, %b", &calendar);
    if (len == 0) return error.InvalidDate;
    return std.fmt.bufPrint(buffer, "{s} {d}", .{ prefix[0..len], @as(u8, @intCast(calendar.tm_mday)) });
}

pub fn month_label(a: std.mem.Allocator, month: []const u8) ![]const u8 {
    const names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    if (month.len != 7 or month[4] != '-') return error.InvalidMonth;
    const index = try std.fmt.parseInt(usize, month[5..], 10);
    if (index < 1 or index > names.len) return error.InvalidMonth;
    return std.fmt.allocPrint(a, "{s} {s}", .{ names[index - 1], month[0..4] });
}

test "compiled calendar labels match the web English labels" {
    var buffer: [80]u8 = undefined;
    try std.testing.expectEqualStrings("Sat, Oct 17", try day_label(&buffer, "2026-10-17"));
    const month = try month_label(std.testing.allocator, "2026-10");
    defer std.testing.allocator.free(month);
    try std.testing.expectEqualStrings("October 2026", month);
}
