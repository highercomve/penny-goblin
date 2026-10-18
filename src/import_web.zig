//! Additive migration through the same transaction used by the application.
const std = @import("std");
const ledger_mod = @import("core/ledger.zig");
const legacy = @import("core/legacy.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return error.ExpectedExportAndDatabasePaths;
    const json = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(24 * 1024 * 1024));
    const path = try arena.dupeZ(u8, args[2]);
    const ledger = try ledger_mod.Ledger.open(path);
    defer ledger.close();
    const result = try legacy.import(ledger, arena, json);
    std.debug.print("Imported {d} payments; skipped {d} existing records; initialized settings: {}.\n", .{
        result.imported, result.skipped, result.settings_imported,
    });
}
