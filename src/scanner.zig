//! Which engine reads vouchers ("Receipt scanner" in Settings): the device's
//! own model (Gemini Nano through `oriel.system_ai`, where supported), a
//! catalog model downloaded from Hugging Face, or a GGUF pair the user
//! imported. The choice is per device and never synchronized.
//!
const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");
const scanning = @import("core/scanning.zig");

const log = std.log.scoped(.scanner);
pub const is_phone = builtin.abi.isAndroid() or builtin.os.tag == .ios;

pub const Entry = scanning.Entry;
pub const catalog = scanning.catalog;
pub const find = scanning.find;
const validChoice = scanning.validChoice;

fn offered(entry: Entry) bool {
    return !(is_phone and entry.desktop_only);
}

/// What a scan runs on.
pub const Engine = union(enum) {
    system,
    local: struct { model: [:0]const u8, projector: [:0]const u8 },
};

fn appDir(arena: std.mem.Allocator) ![]const u8 {
    return oriel.paths.appData(arena, .{ .name = app.build.id });
}

pub fn modelsDir(arena: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(arena, &.{ try appDir(arena), "models" });
}

/// The files a user imported before the catalog existed (vision.pick_model).
pub fn customPaths(arena: std.mem.Allocator) !struct { model: [:0]const u8, projector: [:0]const u8 } {
    const dir = try appDir(arena);
    return .{
        .model = try std.fs.path.joinZ(arena, &.{ dir, "receipt-model.gguf" }),
        .projector = try std.fs.path.joinZ(arena, &.{ dir, "receipt-projector.gguf" }),
    };
}

fn present(io: std.Io, path: []const u8) bool {
    model_files.independent_file(io, path) catch return false;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.size > 1 << 20;
}

fn entryPaths(arena: std.mem.Allocator, entry: Entry) !struct { model: [:0]const u8, projector: [:0]const u8 } {
    const dir = try modelsDir(arena);
    return .{
        .model = try std.fs.path.joinZ(arena, &.{ dir, entry.file }),
        .projector = try std.fs.path.joinZ(arena, &.{ dir, entry.projector_local }),
    };
}

fn installed(io: std.Io, arena: std.mem.Allocator, entry: Entry) bool {
    const paths = entryPaths(arena, entry) catch return false;
    return present(io, paths.model) and present(io, paths.projector);
}

// ---------------------------------------------------------------------------
// The choice: "system", "custom" or a catalog id, in a small private file.

const choice_file = "scanner-choice";

fn readChoice(io: std.Io, arena: std.mem.Allocator) []const u8 {
    const dir = appDir(arena) catch return "";
    const path = std.fs.path.join(arena, &.{ dir, choice_file }) catch return "";
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64)) catch return "";
    return std.mem.trim(u8, text, " \r\n");
}

pub fn select(io: std.Io, arena: std.mem.Allocator, id: []const u8) !void {
    if (!validChoice(id)) return error.UnknownModel;
    if (std.mem.eql(u8, id, "system") and !systemSupported()) return error.SystemAiUnavailable;
    const dir = try appDir(arena);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, choice_file }), .data = id });
}

// ---------------------------------------------------------------------------
// Vision models other apps (LM Studio, GhostPen, Hugging Face) already keep,
// used where they are: a model with a projector (mmproj) in its folder.

pub const Shared = struct { model: [:0]const u8, projector: [:0]const u8, name: []const u8, app: []const u8, mb: u32, current: bool = false };
const shared_file = "scanner-shared.json";

fn sharedModels(io: std.Io, arena: std.mem.Allocator) ![]Shared {
    var list: std.ArrayList(Shared) = .empty;
    if (is_phone) return list.items;
    const found = try model_files.scan(io, arena, try model_files.sharedRoots(arena));
    const chosen = if (std.mem.eql(u8, readChoice(io, arena), "shared")) try readShared(io, arena) else null;
    for (found) |model| {
        if (!model_files.runnable(model)) continue;
        const dir = std.fs.path.dirname(model.path) orelse continue;
        const name = std.fs.path.stem(std.fs.path.basename(model.path));
        // The projector beside it; one named after the model first
        // (GhostPen's `<model>.mmproj.gguf`), else the folder's only one.
        var projector: ?model_files.Found = null;
        for (found) |other| {
            const other_name = std.fs.path.basename(other.path);
            if (!model_files.isProjector(other_name) or !std.mem.eql(u8, std.fs.path.dirname(other.path) orelse "", dir)) continue;
            if (projector == null or std.mem.startsWith(u8, other_name, name)) projector = other;
        }
        const pair = projector orelse continue;
        const item: Shared = .{ .model = try arena.dupeZ(u8, model.path), .projector = try arena.dupeZ(u8, pair.path), .name = name, .app = model.app, .mb = @intCast((model.size + pair.size) >> 20) };
        try list.append(arena, item);
        if (chosen) |c| list.items[list.items.len - 1].current = std.mem.eql(u8, c.model, item.model) and std.mem.eql(u8, c.projector, item.projector);
    }
    return list.items;
}

/// The catalog entry a shared pair duplicates (same model and projector
/// sizes): offered as that entry, linked by a hash-checked "download".
fn catalogMatch(pair: Shared) ?[]const u8 {
    for (catalog) |entry| {
        if (offered(entry) and std.mem.eql(u8, std.fs.path.basename(pair.model), entry.file) and (entry.size + entry.projector_size) >> 20 == pair.mb) return entry.id;
    }
    return null;
}

fn readShared(io: std.Io, arena: std.mem.Allocator) !?struct { model: [:0]const u8, projector: [:0]const u8 } {
    const path = try std.fs.path.join(arena, &.{ try appDir(arena), shared_file });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024)) catch return null;
    const pair = std.json.parseFromSliceLeaky(struct { model: []const u8, projector: []const u8 }, arena, text, .{ .allocate = .alloc_always }) catch return null;
    return .{ .model = try arena.dupeZ(u8, pair.model), .projector = try arena.dupeZ(u8, pair.projector) };
}

/// Scan with a pair another app keeps: only one `status` lists, never an
/// arbitrary path from the interface.
pub fn selectShared(io: std.Io, arena: std.mem.Allocator, model: []const u8, projector: []const u8) !void {
    for (try sharedModels(io, arena)) |pair| if (std.mem.eql(u8, pair.model, model) and std.mem.eql(u8, pair.projector, projector)) {
        const dir = try appDir(arena);
        try std.Io.Dir.cwd().createDirPath(io, dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, shared_file }), .data = try std.json.Stringify.valueAlloc(arena, .{ .model = model, .projector = projector }, .{}) });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, choice_file }), .data = "shared" });
        return;
    };
    return error.UnknownModel;
}

const fast_file = "scanner-fast";

/// Fast mode (Android): read text with OCR and rules first, the model only
/// when a field is missing. On unless the user turns it off.
pub fn fastEnabled(io: std.Io, arena: std.mem.Allocator) bool {
    const dir = appDir(arena) catch return true;
    const path = std.fs.path.join(arena, &.{ dir, fast_file }) catch return true;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8)) catch return true;
    return !std.mem.eql(u8, std.mem.trim(u8, text, " \n"), "off");
}

pub fn setFast(io: std.Io, arena: std.mem.Allocator, enabled: bool) !void {
    const path = try std.fs.path.join(arena, &.{ try appDir(arena), fast_file });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = if (enabled) "on" else "off" });
}

const gpu_file = "scanner-gpu";

/// The user's choice; unset, on for an NVIDIA GPU through CUDA and off
/// otherwise. Measured 2026-10-18 on an RTX 4070, CUDA: 2.5-3.3 s a receipt
/// vs 6-15 s on the CPU (Qwen3.5 0.8B and Qwen2.5-VL 3B). Vulkan rebuilds
/// its pipelines for each scan (the model loads afresh): 21 s vs 15 s on
/// the CPU (2026-10-17, Qwen3.5 2B); the POCO X3's Adreno 618 failed the
/// self-test. The switch lets a device whose GPU passes try it.
pub fn gpuEnabled(io: std.Io, arena: std.mem.Allocator) bool {
    const dir = appDir(arena) catch return false;
    const path = std.fs.path.join(arena, &.{ dir, gpu_file }) catch return false;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8)) catch return @import("vision.zig").cudaGpu(io);
    return std.mem.eql(u8, std.mem.trim(u8, text, " \n"), "on");
}

pub fn setGpu(io: std.Io, arena: std.mem.Allocator, enabled: bool) !void {
    const path = try std.fs.path.join(arena, &.{ try appDir(arena), gpu_file });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = if (enabled) "on" else "off" });
}

fn freeMemoryMb(io: std.Io, arena: std.mem.Allocator) u32 {
    // procfs reports size 0: read it as a stream.
    const file = std.Io.Dir.cwd().openFile(io, "/proc/meminfo", .{}) catch return 0;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const text = reader.interface.allocRemaining(arena, .limited(64 * 1024)) catch return 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemAvailable:")) continue;
        var fields = std.mem.tokenizeAny(u8, line["MemAvailable:".len..], " kB");
        const kb = std.fmt.parseInt(u64, fields.next() orelse return 0, 10) catch return 0;
        return @intCast(@min(kb / 1024, std.math.maxInt(u32)));
    }
    return 0;
}

fn systemSupported() bool {
    return oriel.system_ai.available;
}

fn systemReady() bool {
    if (oriel.system_ai.available) return oriel.system_ai.status().state == .available;
    return false;
}

/// The engine for the next scan: the saved choice when usable, else the
/// system model when ready, else the first installed model, else imported
/// files. error.ScannerNotSetUp when nothing can read a voucher yet.
pub fn resolve(io: std.Io, arena: std.mem.Allocator) !Engine {
    const choice = readChoice(io, arena);
    if (std.mem.eql(u8, choice, "system")) {
        if (systemReady()) return .system;
        return error.SystemModelNotReady;
    }
    if (find(choice)) |entry| {
        const paths = try entryPaths(arena, entry);
        if (present(io, paths.model) and present(io, paths.projector)) return .{ .local = .{ .model = paths.model, .projector = paths.projector } };
        return error.ModelNotDownloaded;
    }
    if (std.mem.eql(u8, choice, "shared")) {
        const pair = try readShared(io, arena) orelse return error.ModelNotFound;
        if (present(io, pair.model) and present(io, pair.projector)) return .{ .local = .{ .model = pair.model, .projector = pair.projector } };
        return error.ModelNotFound;
    }
    const custom = try customPaths(arena);
    if (std.mem.eql(u8, choice, "custom")) {
        if (present(io, custom.model) and present(io, custom.projector)) return .{ .local = .{ .model = custom.model, .projector = custom.projector } };
        return error.ModelNotImported;
    }
    if (systemReady()) return .system;
    for (catalog) |entry| if (offered(entry) and installed(io, arena, entry)) {
        const paths = try entryPaths(arena, entry);
        return .{ .local = .{ .model = paths.model, .projector = paths.projector } };
    };
    if (present(io, custom.model) and present(io, custom.projector)) return .{ .local = .{ .model = custom.model, .projector = custom.projector } };
    return error.ScannerNotSetUp;
}

// ---------------------------------------------------------------------------
// Status for Settings

pub const ModelStatus = struct {
    id: []const u8,
    label: []const u8,
    note: []const u8,
    mb: u32,
    installed: bool,
    partial_mb: u32,
    /// Another app on this computer has this model and projector (by size;
    /// the download verifies the hash and links them instead): "" when none.
    found: []const u8 = "",
};

pub const Status = struct {
    /// The saved choice ("" when none).
    selected: []const u8,
    /// What a scan would use now: "system", a catalog id, "custom" or "".
    active: []const u8,
    vision_built: bool,
    system: struct { supported: bool, state: []const u8, reason: []const u8 },
    models: []const ModelStatus,
    /// Vision models other apps keep with their projector, usable in place.
    shared: []const Shared = &.{},
    custom: bool,
    downloading: []const u8,
    /// A GPU that passed ggml's self-test ("" when none) and whether scans use it.
    gpu: []const u8,
    use_gpu: bool,
    /// Phones: MemAvailable in MB (0 when unknown). Scans slow down sharply
    /// when the model (+ ~25%) doesn't fit in it.
    free_mb: u32,
    /// Fast mode is possible here (OCR) and whether it's on.
    fast_available: bool,
    fast: bool,
};

pub fn status(io: std.Io, arena: std.mem.Allocator) !Status {
    var models: std.ArrayList(ModelStatus) = .empty;
    const dir = try modelsDir(arena);
    const others = try sharedModels(io, arena);
    var shared: std.ArrayList(Shared) = .empty;
    for (others) |other| if (catalogMatch(other) == null) try shared.append(arena, other);
    for (catalog) |entry| {
        if (!offered(entry)) continue;
        const part = try std.fmt.allocPrint(arena, "{s}.part", .{try std.fs.path.join(arena, &.{ dir, entry.file })});
        const partial: u64 = if (std.Io.Dir.cwd().statFile(io, part, .{})) |stat| stat.size else |_| 0;
        try models.append(arena, .{
            .id = entry.id,
            .label = entry.label,
            .note = entry.note,
            .mb = @intCast((entry.size + entry.projector_size) >> 20),
            .installed = installed(io, arena, entry),
            .partial_mb = @intCast(partial >> 20),
            .found = for (others) |other| {
                if (std.mem.eql(u8, catalogMatch(other) orelse "", entry.id)) break other.app;
            } else "",
        });
    }
    const custom = try customPaths(arena);
    const active: []const u8 = if (resolve(io, arena)) |engine| switch (engine) {
        .system => "system",
        .local => |paths| blk: {
            if (std.mem.eql(u8, paths.model, custom.model)) break :blk "custom";
            if (std.mem.eql(u8, readChoice(io, arena), "shared")) break :blk "shared";
            for (catalog) |entry| if (std.mem.endsWith(u8, paths.model, entry.file)) break :blk entry.id;
            break :blk "";
        },
    } else |_| "";
    var system: @FieldType(Status, "system") = .{ .supported = systemSupported(), .state = "unavailable", .reason = "" };
    if (oriel.system_ai.available) {
        const st = oriel.system_ai.status();
        system.state = @tagName(st.state);
        system.reason = try arena.dupe(u8, st.reason());
    }
    download_lock.lockUncancelable(io);
    const downloading = try arena.dupe(u8, downloading_id);
    download_lock.unlock(io);
    return .{
        .selected = readChoice(io, arena),
        .active = active,
        .vision_built = oriel.llama.available,
        .system = system,
        .models = models.items,
        .shared = shared.items,
        .custom = present(io, custom.model) and present(io, custom.projector),
        .downloading = downloading,
        .gpu = if (oriel.llama.available and oriel.ggml_gpu.load(io) > 0) try arena.dupe(u8, oriel.ggml_gpu.gpuName() orelse oriel.ggml_gpu.backendName() orelse "GPU") else "",
        .use_gpu = gpuEnabled(io, arena),
        .free_mb = if (is_phone) freeMemoryMb(io, arena) else 0,
        .fast_available = @import("vision.zig").ocrAvailable(),
        .fast = fastEnabled(io, arena),
    };
}

/// Ask the platform to fetch its own model (Android AICore). Blocks.
pub fn downloadSystem() !void {
    if (!oriel.system_ai.available) return error.SystemAiUnavailable;
    oriel.system_ai.download(null) catch |err| switch (err) {
        error.NotReady => {},
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// Catalog downloads: resumable through a .part, hashed while writing.

const model_files = @import("model_files.zig");
pub const DownloadEvent = model_files.Event;
pub const EmitFn = *const fn (DownloadEvent) void;

var download_lock: std.Io.Mutex = .init;
var downloading_buf: [scanning.max_id_len]u8 = undefined;
var downloading_id: []const u8 = "";
var download_cancel: std.atomic.Value(bool) = .init(false);

pub fn cancelDownload() void {
    download_cancel.store(true, .release);
}

/// Fetch a catalog model and its projector. Blocks for minutes: run it from
/// an async command. Progress goes to `emit` once per megabyte.
pub fn download(io: std.Io, gpa: std.mem.Allocator, id: []const u8, emit: EmitFn) !void {
    const entry = find(id) orelse return error.UnknownModel;
    if (!offered(entry)) return error.ModelTooLargeForDevice;
    {
        download_lock.lockUncancelable(io);
        defer download_lock.unlock(io);
        if (downloading_id.len > 0) return error.AlreadyDownloading;
        @memcpy(downloading_buf[0..id.len], id);
        downloading_id = downloading_buf[0..id.len];
    }
    defer {
        download_lock.lockUncancelable(io);
        downloading_id = "";
        download_lock.unlock(io);
    }
    download_cancel.store(false, .release);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try modelsDir(arena);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const total_mb: u32 = @intCast((entry.size + entry.projector_size) >> 20);
    const progress: model_files.Progress = .{ .id = entry.id, .emit = emit, .total_mb = total_mb, .cancelled = &download_cancel };
    const paths = try entryPaths(arena, entry);
    fetchAll(io, gpa, arena, dir, entry, paths.model, paths.projector, progress) catch |err| {
        emit(.{ .id = entry.id, .state = if (err == error.Cancelled) "cancelled" else "error", .total_mb = total_mb });
        return err;
    };
    emit(.{ .id = entry.id, .state = "done", .done_mb = total_mb, .total_mb = total_mb });
}

fn fetchAll(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, dir: []const u8, entry: Entry, model: []const u8, projector: []const u8, progress: model_files.Progress) !void {
    if (!present(io, model)) try model_files.fetchFile(io, gpa, arena, dir, entry.file, entry.file, entry.size, entry.sha256, .{ .repo = entry.repo, .revision = entry.revision }, progress, 0);
    if (!present(io, projector)) try model_files.fetchFile(io, gpa, arena, dir, entry.projector, entry.projector_local, entry.projector_size, entry.projector_sha256, .{ .repo = entry.repo, .revision = entry.revision }, progress, entry.size);
}

/// Delete a downloaded model and its projector (and partial downloads).
pub fn delete(io: std.Io, arena: std.mem.Allocator, id: []const u8) !void {
    if (std.mem.eql(u8, id, "custom")) {
        const custom = try customPaths(arena);
        try delete_if_present(io, custom.model);
        try delete_if_present(io, custom.projector);
        return;
    }
    const entry = find(id) orelse return error.UnknownModel;
    download_lock.lockUncancelable(io);
    defer download_lock.unlock(io);
    if (std.mem.eql(u8, downloading_id, id)) return error.Downloading;
    const paths = try entryPaths(arena, entry);
    for ([_][]const u8{ paths.model, paths.projector }) |path| {
        try delete_if_present(io, path);
        try delete_if_present(io, try std.fmt.allocPrint(arena, "{s}.part", .{path}));
    }
}
fn delete_if_present(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
