//! Bound recursive JSON materialization before allocating or descending.
const std = @import("std");
pub fn check(input: []const u8) !void {
    var depth: usize = 0;
    var string = false;
    var escaped = false;
    for (input) |byte| {
        if (string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                string = false;
            }
        } else switch (byte) {
            '"' => string = true,
            '[', '{' => {
                depth += 1;
                if (depth > 32) return error.JsonNestingTooDeep;
            },
            ']', '}' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            else => {},
        }
    }
    // Full grammar and matching bracket types are checked by std.json.
    if (depth != 0 or string) return error.InvalidJson;
}
test "JSON depth ignores escaped strings and rejects excessive nesting" {
    try check("{\"text\":\"[\\\"{\"}");
    try check("[" ** 32 ++ "0" ++ "]" ** 32);
    try std.testing.expectError(error.JsonNestingTooDeep, check("[" ** 33 ++ "0" ++ "]" ** 33));
}
