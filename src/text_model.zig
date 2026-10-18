//! Schema-constrained text inference. One session owns one model per batch.
const std = @import("std");
const oriel = @import("oriel");
const c = oriel.llama.c;
pub const Session = if (oriel.llama.available) struct {
    model: oriel.llama.Model,
    context: *c.llama_context,
    cancelled: *std.atomic.Value(bool),
    stop: *Stop,
    allocator: std.mem.Allocator,
    pub fn init(a: std.mem.Allocator, io: std.Io, path: [:0]const u8, cancelled: *std.atomic.Value(bool)) !@This() {
        @import("local_model.zig").ensureBackend();
        const stop = try a.create(Stop);
        errdefer a.destroy(stop);
        stop.* = .{ .flag = cancelled, .io = io, .deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 20 * 60 * 1000 };
        var mp = c.llama_model_default_params();
        mp.progress_callback = loading;
        mp.progress_callback_user_data = stop;
        mp.n_gpu_layers = 0;
        var devices = [_]c.ggml_backend_dev_t{null};
        mp.devices = &devices;
        const model = try oriel.llama.loadModel(path, mp);
        errdefer model.deinit();
        var cp = c.llama_context_default_params();
        cp.n_ctx = 8192;
        cp.n_batch = 512;
        cp.n_ubatch = 512;
        cp.n_threads = @intCast(@min(8, std.Thread.getCpuCount() catch 4));
        cp.n_threads_batch = cp.n_threads;
        cp.abort_callback = aborted;
        cp.abort_callback_data = stop;
        const context = c.llama_init_from_model(model.handle, cp) orelse return error.ContextFailed;
        return .{ .model = model, .context = context, .cancelled = cancelled, .stop = stop, .allocator = a };
    }
    pub fn deinit(self: *@This()) void {
        c.llama_free(self.context);
        self.model.deinit();
        self.allocator.destroy(self.stop);
    }
    pub fn generate(self: *@This(), a: std.mem.Allocator, system: [:0]const u8, input: []const u8, schema: []const u8) ![]const u8 {
        try self.check();
        const user = try std.fmt.allocPrintSentinel(a, "{s}\nReturn the JSON tool call only. /no_think", .{input}, 0);
        const messages = [_]c.llama_chat_message{ .{ .role = "system", .content = system }, .{ .role = "user", .content = user.ptr } };
        const template = c.llama_model_chat_template(self.model.handle, null);
        const buffer = try a.alloc(u8, 64 * 1024);
        var size = c.llama_chat_apply_template(template, &messages, 2, true, buffer.ptr, @intCast(buffer.len));
        if (size < 0) size = c.llama_chat_apply_template("chatml", &messages, 2, true, buffer.ptr, @intCast(buffer.len));
        if (size <= 0 or size > buffer.len) return error.ContextTooLarge;
        const vocab = c.llama_model_get_vocab(self.model.handle) orelse return error.NoVocabulary;
        const tokens = try a.alloc(c.llama_token, buffer.len);
        const count = c.llama_tokenize(vocab, buffer.ptr, size, tokens.ptr, @intCast(tokens.len), true, true);
        if (count <= 0 or count + 768 > c.llama_n_ctx(self.context)) return error.ContextTooLarge;
        c.llama_memory_clear(c.llama_get_memory(self.context), true);
        var offset: usize = 0;
        while (offset < @as(usize, @intCast(count))) {
            try self.check();
            const n = @min(512, @as(usize, @intCast(count)) - offset);
            if (c.llama_decode(self.context, c.llama_batch_get_one(tokens.ptr + offset, @intCast(n))) != 0) { try self.check(); return error.DecodeFailed; }
            offset += n;
        }
        return self.sample(a, vocab, schema);
    }
    fn check(self: *@This()) !void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (std.Io.Clock.awake.now(self.stop.io).toMilliseconds() >= self.stop.deadline) return error.ResearchTimeLimit;
    }
    fn sample(self: *@This(), a: std.mem.Allocator, vocab: *const c.llama_vocab, schema: []const u8) ![]const u8 {
        const grammar = try oriel.llama.jsonSchemaToGrammar(a, schema, null);
        const sampler = c.llama_sampler_chain_init(c.llama_sampler_chain_default_params()) orelse return error.OutOfMemory;
        defer c.llama_sampler_free(sampler);
        const constrained = c.llama_sampler_init_grammar(vocab, grammar.ptr, "root") orelse return error.InvalidSchema;
        c.llama_sampler_chain_add(sampler, constrained);
        c.llama_sampler_chain_add(sampler, c.llama_sampler_init_greedy() orelse return error.OutOfMemory);
        var output: std.ArrayList(u8) = .empty;
        for (0..768) |_| {
            try self.check();
            var token = c.llama_sampler_sample(sampler, self.context, -1);
            if (c.llama_vocab_is_eog(vocab, token)) return output.toOwnedSlice(a);
            var piece: [4096]u8 = undefined;
            const n = c.llama_token_to_piece(vocab, token, &piece, piece.len, 0, true);
            if (n < 0 or output.items.len + @as(usize, @intCast(n)) > 4096) return error.InvalidModelReply;
            try output.appendSlice(a, piece[0..@intCast(n)]);
            if (c.llama_decode(self.context, c.llama_batch_get_one(&token, 1)) != 0) { try self.check(); return error.DecodeFailed; }
        }
        return error.InvalidModelReply;
    }
} else struct {};
const Stop = struct { flag: *std.atomic.Value(bool), io: std.Io, deadline: i64 };
fn aborted(data: ?*anyopaque) callconv(.c) bool {
    const stop: *Stop = @ptrCast(@alignCast(data.?));
    return stop.flag.load(.acquire) or std.Io.Clock.awake.now(stop.io).toMilliseconds() >= stop.deadline;
}
fn loading(_: f32, data: ?*anyopaque) callconv(.c) bool { return !aborted(data); }
