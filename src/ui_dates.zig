//! Native local calendar formatting for the compiled UI.
const std = @import("std");
const c = @cImport({
    @cDefine("_Nonnull", "");
    @cDefine("_Nullable", "");
    @cDefine("_Null_unspecified", "");
    @cInclude("time.h");
});

fn local_calendar(seconds: i64) !c.struct_tm {
    if (seconds < -2208988800 or seconds > 7258118400) return error.InvalidDate;
    var timestamp = std.math.cast(c.time_t, seconds) orelse return error.InvalidDate;
    var calendar: c.struct_tm = undefined;
    if (comptime @import("builtin").os.tag == .windows) {
        if (c._localtime64_s(&calendar, &timestamp) != 0) return error.InvalidDate;
    } else if (c.localtime_r(&timestamp, &calendar) == null) return error.InvalidDate;
    if (calendar.tm_year < 0 or calendar.tm_year > 299 or calendar.tm_mon < 0 or calendar.tm_mon > 11 or calendar.tm_mday < 1 or calendar.tm_mday > 31) return error.InvalidDate;
    return calendar;
}

pub fn local_day(a: std.mem.Allocator, seconds: i64) ![]const u8 {
    const calendar = try local_calendar(seconds);
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u16, @intCast(calendar.tm_year + 1900)), @as(u8, @intCast(calendar.tm_mon + 1)), @as(u8, @intCast(calendar.tm_mday)) });
}

pub fn local_time(buffer: []u8, seconds: i64) ![]const u8 {
    const calendar = try local_calendar(seconds);
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
    if (c.mktime(&calendar) == -1) return error.InvalidDate;
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

test "untrusted timestamps fail without integer cast panics" {
    var buffer: [80]u8 = undefined;
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64), -2208988801, 7258118401 }) |seconds| {
        try std.testing.expectError(error.InvalidDate, local_time(&buffer, seconds));
        try std.testing.expectError(error.InvalidDate, local_day(std.testing.allocator, seconds));
    }
    const day = try local_day(std.testing.allocator, 1792324800);
    defer std.testing.allocator.free(day);
    try std.testing.expect(@import("core/model.zig").valid_date(day));
}
