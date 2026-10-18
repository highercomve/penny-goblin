//! Process-independent JNI: WorkManager can use the ledger without opening UI.
const std = @import("std");
const jni = @import("oriel").android.jni;
const dispatch = @import("sync_dispatch.zig");

fn request(env: *jni.Env, _: jni.jclass, path_array: jni.jobject, input_array: jni.jobject) callconv(.c) jni.jobject {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = (env.bytesAlloc(a, path_array) catch null) orelse return env.newBytes("{\"ok\":false,\"err\":\"InvalidPath\"}");
    const input = (env.bytesAlloc(a, input_array) catch null) orelse return env.newBytes("{\"ok\":false,\"err\":\"InvalidRequest\"}");
    const result = dispatch.handle(a, path, input) catch return env.newBytes("{\"ok\":false,\"err\":\"SyncFailed\"}");
    return env.newBytes(result);
}

comptime {
    @export(&request, .{ .name = "Java_com_pennygoblin_sync_NativeSync_request" });
}
