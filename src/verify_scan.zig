//! Runs the real local model against a fixture, without saving financial data.
const std = @import("std");
const vision = @import("vision.zig");
const oriel = @import("oriel");

const Expected = struct {
    amount: i64,
    currency: []const u8 = "CLP",
    date: []const u8,
    payee: []const u8,
};

const Commands = struct {
    pub fn scan(arena: std.mem.Allocator, io: std.Io, args: struct { image_path: []const u8, model: []const u8, projector: []const u8 }) ![]const u8 {
        const image = try std.Io.Dir.cwd().readFileAlloc(io, args.image_path, arena, .limited(8 * 1024 * 1024 + 1));
        vision.setGpu(if (std.c.getenv("PENNY_GPU")) |value| std.mem.eql(u8, std.mem.span(value), "1") else true);
        // PENNY_TEXT=<ocr.txt>: the OCR text path instead of the image.
        if (std.c.getenv("PENNY_TEXT")) |text_path| {
            const text = try std.Io.Dir.cwd().readFileAlloc(io, std.mem.span(text_path), arena, .limited(16 * 1024));
            return std.json.Stringify.valueAlloc(arena, try vision.extractText(io, arena, text, try arena.dupeZ(u8, args.model)), .{});
        }
        const engine: @import("scanner.zig").Engine = .{ .local = .{ .model = try arena.dupeZ(u8, args.model), .projector = try arena.dupeZ(u8, args.projector) } };
        return std.json.Stringify.valueAlloc(arena, try vision.extract(io, arena, image, engine), .{});
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // -- image.jpg expected.json model.gguf projector.gguf
    if (args.len != 5) return error.ExpectedImageExpectationModelAndProjectorPaths;
    const json = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], arena, .limited(4096));
    const expected = try std.json.parseFromSliceLeaky(Expected, arena, json, .{});
    // Exercise Oriel's command dispatcher and JSON result, not just inference.
    const request_json = try std.json.Stringify.valueAlloc(arena, .{ .cmd = "scan", .args = .{ .image_path = args[1], .model = args[3], .projector = args[4] } }, .{});
    const response = try oriel.ipc.dispatchRequest(Commands, arena, try oriel.ipc.parseRequest(arena, request_json), init.io);
    const extraction_json = try std.json.parseFromSliceLeaky([]const u8, arena, response, .{});
    const actual = try std.json.parseFromSliceLeaky(Expected, arena, extraction_json, .{ .ignore_unknown_fields = true });
    std.debug.print("Extracted: {s}\n", .{extraction_json});
    if (actual.amount != expected.amount) return error.ExtractedAmountMismatch;
    if (!std.mem.eql(u8, actual.currency, expected.currency)) return error.ExtractedCurrencyMismatch;
    if (!std.mem.eql(u8, actual.date, expected.date)) return error.ExtractedDateMismatch;
    if (!std.mem.eql(u8, actual.payee, expected.payee)) return error.ExtractedPayeeMismatch;
    std.debug.print("Local scan verified: amount, currency, date and payee match. No entry saved.\n", .{});
}
