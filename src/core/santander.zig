//! Santander's unbilled CLP response is untrusted input, never a ledger edit.
const std = @import("std");
const statements = @import("statements.zig");
const model = @import("model.zig");
const reports = @import("reporting.zig");

const Movement = struct {
    Fecha: []const u8,
    Descripcion: []const u8,
    Comercio: ?[]const u8 = null,
    Importe: []const u8,
    IndicadorDebeHaber: []const u8,
};
const Response = struct {
    METADATA: struct { STATUS: []const u8 },
    DATA: struct {
        Informacion: struct { Codigo: []const u8 },
        MatrizMovimientos: []const Movement,
    },
};

pub fn parse(a: std.mem.Allocator, json: []const u8, account: []const u8, today: []const u8, config: reports.Settings) ![]const statements.Row {
    if (json.len > 2 * 1024 * 1024 or !model.valid_date(today)) return error.InvalidSantanderResponse;
    const card = std.mem.trim(u8, account, " \\t\\r\\n");
    try model.text(card, 120, false);
    const response = std.json.parseFromSliceLeaky(Response, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSantanderResponse,
    };
    if (!std.mem.eql(u8, response.METADATA.STATUS, "0") or !std.mem.eql(u8, response.DATA.Informacion.Codigo, "00") or response.DATA.MatrizMovimientos.len > 10000) return error.InvalidSantanderResponse;
    var rows: std.ArrayList(statements.Row) = .empty;
    for (response.DATA.MatrizMovimientos) |movement| {
        if (std.mem.eql(u8, movement.IndicadorDebeHaber, "H")) continue;
        if (!std.mem.eql(u8, movement.IndicadorDebeHaber, "D")) return error.InvalidSantanderResponse;
        const description = std.mem.trim(u8, movement.Descripcion, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(description, "SALDO INICIAL") or std.ascii.eqlIgnoreCase(description, "PAGO")) continue;
        const date = try dateOf(a, movement.Fecha);
        if (!std.mem.eql(u8, date[0..7], today[0..7]) or std.mem.order(u8, date, today) == .gt) continue;
        const merchant = std.mem.trim(u8, movement.Comercio orelse "", " \t\r\n");
        const payee = try clean(a, if (merchant.len > 0) merchant else description);
        const row: statements.Row = .{
            .date = date,
            .amount = try amountOf(movement.Importe),
            .payee = payee,
            .account = try a.dupe(u8, card),
            .category = (try reports.suggest_category(a, payee, config)) orelse "Other",
        };
        try model.validate(.{ .id = &model.digest("validation"), .date = row.date, .amount = row.amount, .payee = row.payee, .account = row.account, .category = row.category });
        try rows.append(a, row);
    }
    // Snapshot hashes and equal-row occurrence numbers do not depend on API order.
    std.mem.sort(statements.Row, rows.items, {}, struct {
        fn less(_: void, l: statements.Row, r: statements.Row) bool {
            const date = std.mem.order(u8, l.date, r.date);
            if (date != .eq) return date == .gt;
            const payee = std.mem.order(u8, l.payee, r.payee);
            if (payee != .eq) return payee == .lt;
            return l.amount < r.amount;
        }
    }.less);
    return rows.toOwnedSlice(a);
}

fn clean(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    try model.text(text, 240, false);
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var first = true;
    while (words.next()) |word| {
        if (!first) try output.writer.writeByte(' ');
        try output.writer.writeAll(word);
        first = false;
    }
    return a.dupe(u8, output.written());
}

fn dateOf(a: std.mem.Allocator, date: []const u8) ![]const u8 {
    if (date.len != 10 or date[2] != '/' or date[5] != '/') return error.InvalidSantanderResponse;
    const value = try std.fmt.allocPrint(a, "{s}-{s}-{s}", .{ date[6..10], date[3..5], date[0..2] });
    if (!model.valid_date(value)) return error.InvalidSantanderResponse;
    return value;
}

fn amountOf(text: []const u8) !i64 {
    if (text.len == 0 or text.len > 20) return error.InvalidSantanderResponse;
    var groups = std.mem.splitScalar(u8, text, '.');
    var result: i64 = 0;
    var first = true;
    while (groups.next()) |group| {
        if (group.len == 0 or (!first and group.len != 3) or (first and std.mem.indexOfScalar(u8, text, '.') != null and group.len > 3)) return error.InvalidSantanderResponse;
        for (group) |digit| {
            if (!std.ascii.isDigit(digit)) return error.InvalidSantanderResponse;
            result = std.math.mul(i64, result, 10) catch return error.InvalidSantanderResponse;
            result = std.math.add(i64, result, digit - '0') catch return error.InvalidSantanderResponse;
        }
        first = false;
    }
    if (result <= 0 or result > 1_000_000_000_000) return error.InvalidSantanderResponse;
    return result;
}

test "Santander amounts are exact CLP and malformed grouping never becomes spending" {
    try std.testing.expectEqual(@as(i64, 383605), try amountOf("383.605"));
    try std.testing.expectEqual(@as(i64, 1200), try amountOf("1200"));
    for ([_][]const u8{ "1.20", "1,200", "-20", "0", "1..000", "NaN" }) |value| try std.testing.expectError(error.InvalidSantanderResponse, amountOf(value));
}

test "Santander captures only current-month debits, preserving equal purchases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"METADATA":{"STATUS":"0"},"DATA":{"Informacion":{"Codigo":"00"},"MatrizMovimientos":[
        \\{"Fecha":"18/10/2026","Descripcion":"COMPRA NORMAL","Comercio":"TEST SHOP","Importe":"1.200","IndicadorDebeHaber":"D"},
        \\{"Fecha":"18/10/2026","Descripcion":"COMPRA NORMAL","Comercio":"TEST SHOP","Importe":"1.200","IndicadorDebeHaber":"D"},
        \\{"Fecha":"30/09/2026","Descripcion":"COMPRA NORMAL","Comercio":"OLD SHOP","Importe":"9.999","IndicadorDebeHaber":"D"},
        \\{"Fecha":"01/10/2026","Descripcion":"SALDO INICIAL","Comercio":null,"Importe":"99.999","IndicadorDebeHaber":"D"},
        \\{"Fecha":"02/10/2026","Descripcion":"PAGO","Comercio":null,"Importe":"5.000","IndicadorDebeHaber":"H"},
        \\{"Fecha":"19/10/2026","Descripcion":"TRASPASO A DEUDA NACIONAL","Comercio":null,"Importe":"2.000","IndicadorDebeHaber":"D"}]}}
    ;
    const rows = try parse(a, json, "1234", "2026-10-19", .{});
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("TRASPASO A DEUDA NACIONAL", rows[0].payee);
    try std.testing.expectEqual(@as(i64, 1200), rows[1].amount);
    try std.testing.expectEqualStrings("1234", rows[2].account);
    try std.testing.expectError(error.InvalidSantanderResponse, parse(a, "{\"METADATA\":{\"STATUS\":\"1\"}}", "1234", "2026-10-19", .{}));
}

test "Santander response parsing frees partial allocations on every failure" {
    const T = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const rows = try parse(arena.allocator(), "{\"METADATA\":{\"STATUS\":\"0\"},\"DATA\":{\"Informacion\":{\"Codigo\":\"00\"},\"MatrizMovimientos\":[{\"Fecha\":\"19/10/2026\",\"Descripcion\":\"COMPRA NORMAL\",\"Comercio\":\"TEST SHOP\",\"Importe\":\"1.200\",\"IndicadorDebeHaber\":\"D\"}]}}", "1234", "2026-10-19", .{});
            try std.testing.expectEqual(@as(usize, 1), rows.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, T.run, .{});
}
