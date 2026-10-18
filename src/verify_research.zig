//! Real model/browser acceptance with synthetic expenses; no database is opened.
const std = @import("std");
const research = @import("research_runtime.zig");
const domain = @import("core/categorization.zig");
const model = @import("core/model.zig");
var process_io: std.Io = undefined;
var model_path: []const u8 = "";
var model_seen = false;
fn read_maps(a: std.mem.Allocator) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(process_io, "/proc/self/maps", .{});
    defer file.close(process_io);
    var buffer: [8192]u8 = undefined;
    var reader = file.readerStreaming(process_io, &buffer);
    return reader.interface.allocRemaining(a, .limited(4 * 1024 * 1024));
}
fn progress(event: research.Event) void {
    std.debug.print("{s} {d}/{d}\n", .{ event.stage, event.completed, event.total });
    if (std.mem.eql(u8, event.stage, "Researching merchants")) {
        const maps = read_maps(std.heap.page_allocator) catch return;
        defer std.heap.page_allocator.free(maps);
        model_seen = std.mem.indexOf(u8, maps, model_path) != null;
    }
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    process_io = init.io;
    model_path = try @import("research_model.zig").resolve(init.io, a);
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.ExpectedPrivateOutputPath;
    const settings = "{\"categories\":{\"Groceries\":[\"MARKET\"],\"Sports\":[],\"Dining\":[],\"Transport\":[]}}";
    var rows: [10]model.Expense = undefined;
    for (&rows, 0..) |*row, i| {
        const merchant = if (i == 0) "DECATHLON" else try std.fmt.allocPrint(a, "MARKET {d}", .{i});
        const id = try a.create([64]u8);
        id.* = model.digest(merchant);
        row.* = .{ .id = id, .date = "2026-10-18", .amount = 100, .payee = merchant, .revision = 1 };
    }
    const review = try research.run(init.io, a, try domain.prepare(a, &rows, settings), progress);
    const maps = try read_maps(a);
    if (!model_seen or std.mem.indexOf(u8, maps, model_path) != null) return error.ModelUnloadNotVerified;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = try std.json.Stringify.valueAlloc(a, review, .{}) });
    if (review.proposals.len != 10) return error.MerchantCountMismatch;
    for (review.proposals) |proposal| if (std.mem.eql(u8, proposal.merchant, "DECATHLON")) {
        if (!std.mem.eql(u8, proposal.category, "Sports") or proposal.sources.len == 0) return error.ResearchAcceptanceFailed;
    };
    std.debug.print("Ten synthetic merchants reviewed; real model/browser evidence and model unload verified; no ledger opened.\n", .{});
}
