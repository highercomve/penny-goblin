//! Prepare an immutable research snapshot while the caller owns the ledger lock.
const std = @import("std");
const ledger = @import("core/ledger.zig");
const domain = @import("core/categorization.zig");
pub fn prepare(db: ledger.Ledger, a: std.mem.Allocator, ids: []const []const u8) !domain.Review {
    if (ids.len == 0 or ids.len > 10000) return error.InvalidSelection;
    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    defer wanted.deinit(a);
    for (ids) |id| {
        if (!ledger.model.valid_id(id)) return error.InvalidId;
        try wanted.put(a, id, {});
    }
    var rows: std.ArrayList(ledger.model.Expense) = .empty;
    for (try db.list(a)) |row| if (wanted.contains(row.id)) try rows.append(a, row);
    return domain.prepare(a, rows.items, try db.setting(a, "budget"));
}
