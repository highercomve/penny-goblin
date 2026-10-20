const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");
const ledger_mod = @import("core/ledger.zig");
const legacy = @import("core/legacy.zig");
const preferences = @import("core/preferences.zig");
const categorization = @import("core/categorization.zig");
const research_runtime = @import("research_runtime.zig");
const research_model = @import("research_model.zig");
const statements = @import("core/statements.zig");
const statement_runtime = @import("statement_runtime.zig");
const sync = @import("core/sync.zig");
const sync_runtime = @import("sync_runtime.zig");
const vision = @import("vision.zig");
const scanner = @import("scanner.zig");
const scanning = @import("core/scanning.zig");
const model = ledger_mod.model;

pub const std_options: std.Options = .{ .logFn = oriel.log.logFn };
pub const Events = struct { research_progress: research_runtime.Event, quick_action: struct {}, model_download: scanner.DownloadEvent, scan_stage: struct { stage: []const u8 } };
const QuickAction = enum { expense, receipt, sync };
var pending_action: ?QuickAction = null;
var tray: if (oriel.tray.available) ?*oriel.tray.Tray else void = if (oriel.tray.available) null else {};
var process_io: std.Io = undefined;
var mutex: std.Io.Mutex = .init;
var ledger: ?ledger_mod.Ledger = null;

fn database() !ledger_mod.Ledger {
    if (ledger) |db| return db;
    const gpa = std.heap.smp_allocator;
    const directory = try oriel.paths.appData(gpa, .{ .name = app.build.id });
    defer gpa.free(directory);
    const path = try std.fs.path.joinZ(gpa, &.{ directory, "ledger.sqlite3" });
    defer gpa.free(path);
    ledger = try ledger_mod.Ledger.open(path);
    return ledger.?;
}

pub const UiDefaults = struct { date: []const u8, account: []const u8 };

pub const UiFile = struct { name: []const u8, data_url: []const u8 };

pub const Snapshot = struct {
    expenses: []model.Expense,
    settings: []const u8,
    platform: []const u8,
    vision_available: bool,
    tray_running: bool,
    statements: []statements.Source,
};

pub const Commands = struct {
    pub const async_commands = .{
        "research_categories", "apply_research",          "research_model_status", "research_model_pick",    "research_model_download", "research_model_default", "research_model_options", "research_model_use",
        "snapshot",            "save_expense",            "delete_expense",        "import_legacy",          "save_budget",             "expense_documents",      "analyze_receipt",        "pick_model",
        "export_report",       "prepare_statement",       "parse_statement",       "statement_observations", "reconcile_statement",     "unlink_observation",     "export_statement",       "expense_statements",
        "sync_status",         "sync_control",            "sync_conflict",         "sync_resolve",           "scanner_status",          "scanner_select",         "scanner_select_shared",  "scanner_download",
        "scanner_delete",      "scanner_system_download", "ui_defaults",           "ui_pick_file",           "scanner_gpu",             "analyze_text",           "scanner_fast",
    };

    pub fn sync_status(arena: std.mem.Allocator) ![]const u8 {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        return sync.records.encode(arena, try sync.resolution.status(try database(), arena));
    }
    pub fn sync_control(arena: std.mem.Allocator, args: struct {
        action: enum { status, start, stop, restart, pairing, revoke, pair_link, scan_pair, sync_now, unpair },
        device: []const u8 = "",
        link: []const u8 = "",
        replace: bool = false,
    }) ![]const u8 {
        if (comptime oriel.target.is_android) {
            var diagnostic: oriel.extensions.Diagnostics = .{};
            return oriel.extensions.get("penny.sync").call(arena, @tagName(args.action), try sync.records.encode(arena, args), .{ .timeout_ms = 240000, .diag = &diagnostic }) catch |err| {
                return sync.records.encode(arena, .{ .@"error" = if (diagnostic.code().len > 0) diagnostic.code() else @errorName(err) });
            };
        }
        const action: sync_runtime.Action = switch (args.action) {
            .status => .status,
            .start => .start,
            .stop => .stop,
            .restart => .restart,
            .pairing => .pairing,
            .revoke => .revoke,
            else => return error.MobileOnly,
        };
        return sync_runtime.control(process_io, arena, action, args.device);
    }
    pub fn sync_conflict(arena: std.mem.Allocator, args: @import("core/sync_types.zig").Key) ![]const u8 {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        return sync.records.encode(arena, try sync.resolution.preview(try database(), arena, args));
    }
    pub fn sync_resolve(arena: std.mem.Allocator, args: struct { kind: @import("core/sync_types.zig").Kind, id: []const u8, keep_local: bool }) !void {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        try sync.resolution.resolve(try database(), arena, .{ .kind = args.kind, .id = args.id }, args.keep_local);
    }

    /// Visual QA (desktop): the steps in $PENNY_QA for frontend/qa.js, else null.
    pub fn qa_scenario(_: std.mem.Allocator) ?[]const u8 {
        if (oriel.target.is_android) return null;
        return if (std.c.getenv("PENNY_QA")) |v| std.mem.span(v) else null;
    }

    /// Visual QA: qa.js's element boxes, written to $PENNY_QA_OUT.
    pub fn qa_report(arena: std.mem.Allocator, args: struct { text: []const u8 }) !void {
        _ = arena;
        if (oriel.target.is_android) return;
        const path = std.c.getenv("PENNY_QA_OUT") orelse return;
        try std.Io.Dir.cwd().writeFile(process_io, .{ .sub_path = std.mem.span(path), .data = args.text });
    }

    pub fn snapshot(arena: std.mem.Allocator) !Snapshot {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        const db = try database();
        return .{
            .expenses = try db.list(arena),
            .settings = try db.setting(arena, "budget"),
            .platform = oriel.target.name,
            .vision_available = oriel.llama.available,
            .tray_running = if (oriel.tray.available) tray != null else false,
            .statements = try statements.sources(db, arena),
        };
    }

    // These run on the main thread, just like tray callbacks.
    pub fn take_quick_action() ?QuickAction {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        const action = pending_action;
        pending_action = null;
        return action;
    }

    pub fn quit() void {
        oriel.App.quit(0);
    }

    pub fn new_id(arena: std.mem.Allocator) ![]const u8 {
        var bytes: [32]u8 = undefined;
        try process_io.randomSecure(&bytes);
        return arena.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
    }

    pub fn save_expense(arena: std.mem.Allocator, args: model.Save) !i64 {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        const revision = try (try database()).save(arena, args);
        // A device-local convenience; failure must never turn a committed
        // payment into an apparent failed save.
        remember_account(arena, args.expense.account) catch |err| std.log.warn("account preference: {s}", .{@errorName(err)});
        return revision;
    }

    pub fn delete_expense(_: std.mem.Allocator, args: struct { id: []const u8, expected_revision: i64 }) !void {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        try (try database()).remove(args.id, args.expected_revision);
    }

    pub fn import_legacy(arena: std.mem.Allocator, args: struct { json: []const u8 }) !legacy.Result {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        return legacy.import(try database(), arena, args.json);
    }

    pub fn save_budget(arena: std.mem.Allocator, args: preferences.Edit) !usize {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        return preferences.apply(try database(), arena, args);
    }

    pub fn research_categories(arena: std.mem.Allocator, args: struct { ids: []const []const u8 }) ![]const u8 {
        if (comptime oriel.target.is_android) return @import("research_remote.zig").run(process_io, arena, args.ids, emit_research);
        const review = blk: {
            mutex.lockUncancelable(process_io);
            defer mutex.unlock(process_io);
            break :blk try @import("research_service.zig").prepare(try database(), arena, args.ids);
        };
        return std.json.Stringify.valueAlloc(arena, try research_runtime.run(process_io, arena, review, emit_research), .{});
    }
    pub fn research_model_status(arena: std.mem.Allocator) ![]const u8 {
        if (comptime oriel.target.is_android) return @import("research_remote.zig").model(arena);
        return std.json.Stringify.valueAlloc(arena, try research_model.status(process_io, arena), .{});
    }
    pub fn research_model_pick(arena: std.mem.Allocator) !void {
        try research_model.pick(process_io, arena);
    }
    pub fn research_model_default(arena: std.mem.Allocator) !void {
        try research_model.use_default(process_io, arena);
    }
    pub fn research_model_options(arena: std.mem.Allocator) ![]const u8 {
        return std.json.Stringify.valueAlloc(arena, try research_model.options(process_io, arena), .{});
    }
    pub fn research_model_use(arena: std.mem.Allocator, args: struct { path: []const u8 }) !void {
        try research_model.use(process_io, arena, args.path);
    }
    pub fn research_model_download() !void {
        try research_model.download(process_io, std.heap.smp_allocator, emit_download);
    }
    pub fn cancel_research_model() void {
        research_model.cancelDownload();
    }
    pub fn open_research_source(arena: std.mem.Allocator, args: struct { url: []const u8 }) !void {
        try model.text(args.url, 2048, false);
        const uri = try std.Uri.parse(args.url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.host == null or uri.user != null or uri.password != null) return error.InvalidUrl;
        oriel.App.openExternal((try arena.dupeZ(u8, args.url)).ptr);
    }
    pub fn cancel_research() void {
        research_runtime.cancel();
        @import("research_remote.zig").cancel();
    }
    pub fn apply_research(arena: std.mem.Allocator, args: categorization.Apply) !usize {
        if (comptime oriel.target.is_android) return @import("research_remote.zig").apply(arena, args);
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        return categorization.apply(try database(), arena, args);
    }

    pub fn expense_documents(arena: std.mem.Allocator, args: struct { id: []const u8 }) ![]model.Document {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        return (try database()).documents(arena, args.id);
    }

    /// `name` and `modified` (Unix ms): the picked file's, which date a
    /// voucher that prints none (scanning.imageDate).
    pub fn analyze_receipt(arena: std.mem.Allocator, args: struct { data_url: []const u8, name: []const u8 = "", modified: i64 = 0 }) ![]const u8 {
        const today = try localDay(arena, std.Io.Clock.real.now(process_io).toSeconds());
        const image = try ledger_mod.image_bytes(arena, args.data_url);
        const taken = (try scanning.imageDate(arena, args.name, image, today)) orelse
            if (args.modified > 0) try localDay(arena, @divTrunc(args.modified, 1000)) else today;
        var found = try scanReceipt(process_io, arena, args.data_url, taken, true);
        settleDate(&found, taken);
        // Transfer generated JSON as a scalar. WebKit's structured reply did
        // not preserve the dynamic field values in the native acceptance run.
        return std.json.Stringify.valueAlloc(arena, found, .{});
    }

    /// Investigation: the OCR text path with the active local model.
    pub fn analyze_text(arena: std.mem.Allocator, args: struct { text: []const u8 }) ![]const u8 {
        const engine = try scanner.resolve(process_io, arena);
        if (engine != .local) return error.LocalModelRequired;
        return std.json.Stringify.valueAlloc(arena, try vision.extractText(process_io, arena, args.text, engine.local.model), .{});
    }

    pub fn pick_model(arena: std.mem.Allocator, args: struct { projector: bool = false }) !bool {
        return vision.pick_model(process_io, arena, args.projector);
    }

    pub fn cancel_analysis(_: std.mem.Allocator) void {
        vision.cancel();
        if (oriel.system_ai.available) oriel.system_ai.cancel();
    }

    // Receipt scanner settings: engine choice, catalog downloads, system model.
    pub fn scanner_status(arena: std.mem.Allocator) ![]const u8 {
        return std.json.Stringify.valueAlloc(arena, try scanner.status(process_io, arena), .{});
    }
    pub fn scanner_select(arena: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        try scanner.select(process_io, arena, args.id);
    }
    pub fn scanner_select_shared(arena: std.mem.Allocator, args: struct { model: []const u8, projector: []const u8 }) !void {
        try scanner.selectShared(process_io, arena, args.model, args.projector);
    }
    pub fn scanner_download(_: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        try scanner.download(process_io, std.heap.smp_allocator, args.id, emit_download);
    }
    pub fn scanner_cancel_download(_: std.mem.Allocator) void {
        scanner.cancelDownload();
    }
    pub fn scanner_fast(arena: std.mem.Allocator, args: struct { enabled: bool }) !void {
        try scanner.setFast(process_io, arena, args.enabled);
    }
    pub fn scanner_gpu(arena: std.mem.Allocator, args: struct { enabled: bool }) !void {
        try scanner.setGpu(process_io, arena, args.enabled);
    }
    pub fn scanner_delete(arena: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        try scanner.delete(process_io, arena, args.id);
    }
    pub fn scanner_system_download(_: std.mem.Allocator) !void {
        try scanner.downloadSystem();
    }

    pub fn ui_defaults(arena: std.mem.Allocator) !UiDefaults {
        const date = try localDay(arena, std.Io.Clock.real.now(process_io).toSeconds());
        const dir = try oriel.paths.appData(arena, .{ .name = app.build.id });
        const path = try std.fs.path.join(arena, &.{ dir, "last-account" });
        const account = std.Io.Dir.cwd().readFileAlloc(process_io, path, arena, .limited(120)) catch "";
        return .{ .date = date, .account = if (std.unicode.utf8ValidateSlice(account)) account else "" };
    }

    /// Compiled views use native file dialogs rather than DOM FileReader.
    pub fn ui_pick_file(arena: std.mem.Allocator, args: struct { kind: enum { image, camera, pdf, legacy } }) !?UiFile {
        if (args.kind == .image or args.kind == .camera) {
            const photo = oriel.camera.capturePhoto(process_io, arena, .{ .source = if (args.kind == .camera) .camera else .library }) catch |err| switch (err) {
                error.Cancelled => return null,
                else => return err,
            };
            return .{ .name = "voucher.jpg", .data_url = try oriel.camera.common.dataUrl(arena, photo.mime, photo.bytes) };
        }
        const path = try oriel.dialog.openFile(arena, .{ .title = switch (args.kind) {
            .image, .camera => "Choose payment image",
            .pdf => "Add bank statement",
            .legacy => "Import web export",
        } }) orelse return null;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(process_io, path, arena, .limited(if (args.kind == .pdf) 32 * 1024 * 1024 else 24 * 1024 * 1024));
        if (args.kind == .legacy) return .{ .name = std.fs.path.basename(path), .data_url = bytes };
        const mime = if (args.kind == .pdf) "application/pdf" else if (std.mem.startsWith(u8, bytes, "\x89PNG")) "image/png" else if (std.mem.startsWith(u8, bytes, "\xff\xd8")) "image/jpeg" else return error.InvalidImage;
        const prefix = try std.fmt.allocPrint(arena, "data:{s};base64,", .{mime});
        const out = try arena.alloc(u8, prefix.len + std.base64.standard.Encoder.calcSize(bytes.len));
        @memcpy(out[0..prefix.len], prefix);
        _ = std.base64.standard.Encoder.encode(out[prefix.len..], bytes);
        return .{ .name = std.fs.path.basename(path), .data_url = out };
    }

    pub fn export_report(arena: std.mem.Allocator, args: struct { html: []const u8 }) !bool {
        if (args.html.len > 16 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(args.html)) return error.ReportTooLarge;
        const path = try oriel.dialog.saveFile(arena, .{ .title = "Save Penny Goblin report (.html)" }) orelse return false;
        try oriel.dialog.writeFile(process_io, path, args.html);
        return true;
    }

    pub fn prepare_statement(arena: std.mem.Allocator, args: struct { name: []const u8, data_url: []const u8 }) ![]const u8 {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        return statements.stage(try database(), arena, args.name, args.data_url);
    }

    pub fn parse_statement(arena: std.mem.Allocator, args: struct { hash: []const u8 }) !void {
        mutex.lockUncancelable(process_io);
        const db = database() catch |err| {
            mutex.unlock(process_io);
            return err;
        };
        const data = statements.content(db, arena, args.hash) catch |err| {
            mutex.unlock(process_io);
            return err;
        };
        const budget = db.setting(arena, "budget") catch |err| {
            mutex.unlock(process_io);
            return err;
        };
        const observed = statements.observations(db, arena, args.hash) catch |err| {
            mutex.unlock(process_io);
            return err;
        };
        mutex.unlock(process_io);
        if (observed.len > 0) return;
        const parsed = try statement_runtime.parse(process_io, arena, data, budget);
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        try statements.accept_parse(try database(), arena, args.hash, parsed);
    }

    pub fn statement_observations(arena: std.mem.Allocator, args: struct { hash: []const u8 }) ![]statements.Observation {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        return statements.observations(try database(), arena, args.hash);
    }

    pub fn reconcile_statement(arena: std.mem.Allocator, args: struct { hash: []const u8, decisions: []const statements.Decision }) !usize {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        return statements.reconcile(try database(), arena, args.hash, args.decisions);
    }

    pub fn unlink_observation(arena: std.mem.Allocator, args: struct { id: []const u8, expected_expense: ?[]const u8 }) !void {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        try statements.unlink(try database(), arena, args.id, args.expected_expense);
    }

    pub fn expense_statements(arena: std.mem.Allocator, args: struct { id: []const u8 }) ![]statements.PaymentSource {
        mutex.lockUncancelable(process_io);
        defer mutex.unlock(process_io);
        return statements.payment_sources(try database(), arena, args.id);
    }

    pub fn export_statement(arena: std.mem.Allocator, args: struct { hash: []const u8 }) !bool {
        const data = blk: {
            mutex.lockUncancelable(process_io);
            defer mutex.unlock(process_io);
            break :blk try statements.content(try database(), arena, args.hash);
        };
        const bytes = try statements.pdf_bytes(arena, data);
        const path = try oriel.dialog.saveFile(arena, .{ .title = "Save original statement (.pdf)" }) orelse return false;
        try oriel.dialog.writeFile(process_io, path, bytes);
        return true;
    }
};

fn remember_account(arena: std.mem.Allocator, account: []const u8) !void {
    const dir = try oriel.paths.appData(arena, .{ .name = app.build.id });
    const path = try std.fs.path.join(arena, &.{ dir, "last-account" });
    try std.Io.Dir.cwd().writeFile(process_io, .{ .sub_path = path, .data = account });
}

fn setup() !void {
    if (!oriel.tray.available) return;
    tray = oriel.tray.Tray.create(std.heap.smp_allocator, .{
        .id = app.build.id,
        .title = "Penny Goblin",
        .tooltip = "Penny Goblin is running · Household ledger",
        .icon = .{ .png = if (oriel.target.os == .linux) @embedFile("tray.png") else app.build.icon.? },
        .menu = &.{
            .{ .item = .{ .id = "open", .label = "Open Penny Goblin" } },
            .{ .item = .{ .id = "receipt", .label = "Scan payment voucher" } },
            .{ .item = .{ .id = "expense", .label = "Enter expense manually" } },
            .{ .item = .{ .id = "sync", .label = "Pairing & synchronization" } },
            .separator,
            .{ .item = .{ .id = "quit", .label = "Quit Penny Goblin" } },
        },
        .on_menu = on_tray_menu,
        .on_activate = show_window,
    }) catch |err| {
        // If creation fails, closing must still exit instead of hiding an
        // inaccessible process. The UI also offers an explicit Quit action.
        if (oriel.App.getWindow("main")) |window| window.options.hide_on_close = false;
        std.log.warn("tray unavailable: {s}", .{@errorName(err)});
        return;
    };
}

fn show_window() void {
    if (oriel.App.getWindow("main")) |window| {
        window.show();
        window.focus();
    }
}

/// A voucher read as payment details. Fast mode first: text recognition and
/// rules in about a second. Then, on a phone paired with a desktop that's
/// reachable, the desktop's model (`desktop`: faster than the phone's); else
/// this device's own model.
fn scanReceipt(io: std.Io, arena: std.mem.Allocator, data_url: []const u8, taken: []const u8, desktop: bool) !vision.Extraction {
    const bytes = try ledger_mod.image_bytes(arena, data_url);
    vision.setGpu(scanner.gpuEnabled(io, arena));
    var partial: ?vision.Extraction = null;
    if (vision.ocrAvailable() and scanner.fastEnabled(io, arena)) {
        if (vision.recognize(arena, bytes)) |result| {
            if (result.complete) return result.extraction;
            var found = result.extraction;
            // An app's success screen prints no date: the payment is the
            // screenshot's, so text alone finishes the scan.
            if (found.date.len == 0 and taken.len > 0 and found.amount > 0 and found.payee.len > 0) {
                found.date = taken;
                return found;
            }
            partial = found;
        } else |err| std.log.warn("text scan failed: {s}", .{@errorName(err)});
    }
    if (desktop and oriel.target.is_android) {
        if (desktopScan(arena, data_url)) |found| return scanning.preferTextAmount(found, partial) else |err| std.log.info("desktop scan unavailable: {s}", .{@errorName(err)});
    }
    const engine = scanner.resolve(io, arena) catch |err| {
        // No model to fall back to: return what text recognition found for review.
        if (partial) |found| if (found.amount > 0) return found;
        return err;
    };
    return scanning.preferTextAmount(try vision.extract(io, arena, bytes, engine), partial);
}

/// The local calendar day of Unix time `seconds`, as YYYY-MM-DD.
fn localDay(arena: std.mem.Allocator, seconds: i64) ![]const u8 {
    return @import("ui_dates.zig").local_day(arena, seconds);
}

/// A scan's date where it can't be the payment's: a model's invented one
/// (before 2000, or after the image was taken) or none, the image's date.
fn settleDate(found: *vision.Extraction, taken: []const u8) void {
    const invented = found.date.len > 0 and (std.mem.order(u8, found.date, "2000-01-01") == .lt or
        (taken.len > 0 and std.mem.order(u8, found.date, taken) == .gt));
    if (found.date.len == 0 or invented) found.date = taken;
}

/// The paired desktop's scan of `data_url` (penny.sync's `scan`: its own
/// model, over the pinned sync connection). Fails fast when the desktop
/// wasn't reachable in the last seconds, so the phone scans instead.
fn desktopScan(arena: std.mem.Allocator, data_url: []const u8) !vision.Extraction {
    if (comptime !oriel.target.is_android) return error.DesktopOnly;
    emit_stage("desktop");
    var diagnostic: oriel.extensions.Diagnostics = .{};
    const reply = oriel.extensions.get("penny.sync").call(arena, "scan", try sync.records.encode(arena, .{ .data_url = data_url }), .{ .timeout_ms = 330000, .diag = &diagnostic }) catch |err| {
        if (diagnostic.code().len > 0) std.log.info("desktop scan: {s}", .{diagnostic.code()});
        return err;
    };
    // The desktop's answer, held to the same shape as a local scan's.
    var found = try std.json.parseFromSliceLeaky(vision.Extraction, arena, reply, .{ .ignore_unknown_fields = true });
    found.engine = "desktop";
    return found;
}

/// `--scan-worker`: the desktop's sync service hands a paired phone's voucher
/// here (stdin `{"data_url":…}`); the reply is `{"ok":true,"value":…}` with
/// this desktop's scan, or `{"ok":false,"err":…}`.
fn scanWorker(init: std.process.Init) !u8 {
    var buffer: [8192]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(init.io, &buffer);
    const arena = init.arena.allocator();
    const input = try reader.interface.allocRemaining(arena, .limited(32 * 1024 * 1024));
    const reply = blk: {
        const args = std.json.parseFromSliceLeaky(struct { data_url: []const u8 }, arena, input, .{ .ignore_unknown_fields = true, .max_value_len = 32 * 1024 * 1024 }) catch
            break :blk try sync.records.encode(arena, .{ .ok = false, .err = "InvalidScanRequest" });
        const found = scanReceipt(init.io, arena, args.data_url, "", false) catch |err|
            break :blk try sync.records.encode(arena, .{ .ok = false, .err = @errorName(err) });
        break :blk try sync.records.encode(arena, .{ .ok = true, .value = found });
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, reply);
    return 0;
}

fn emit_stage(name: []const u8) void {
    oriel.App.events(Events).emit(.scan_stage, .{ .stage = name });
}

fn emit_download(event: scanner.DownloadEvent) void {
    oriel.App.events(Events).emit(.model_download, event);
}

fn on_tray_menu(id: []const u8, _: ?bool) void {
    if (std.mem.eql(u8, id, "quit")) {
        oriel.App.quit(0);
        return;
    }
    show_window();
    const action: QuickAction = if (std.mem.eql(u8, id, "expense")) .expense else if (std.mem.eql(u8, id, "receipt")) .receipt else if (std.mem.eql(u8, id, "sync")) .sync else return;
    mutex.lockUncancelable(process_io);
    pending_action = action;
    mutex.unlock(process_io);
    oriel.App.events(Events).emit(.quick_action, .{});
}

pub fn main(init: std.process.Init) !u8 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "--sync-worker")) return @import("sync_dispatch.zig").worker(init, arguments[2]);
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], "--scan-worker")) return scanWorker(init);
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "--research-worker")) return @import("research_worker.zig").worker(init, arguments[2]);
    process_io = init.io;
    vision.setStageCallback(emit_stage);
    defer {
        if (!oriel.target.is_android) sync_runtime.stop(process_io);
        if (oriel.tray.available) {
            if (tray) |icon| icon.deinit();
            tray = null;
        }
        // Android can run main again in the same process after the window
        // closes (sync keeps the process alive); never leave a closed handle cached.
        mutex.lockUncancelable(process_io);
        if (ledger) |db| db.close();
        ledger = null;
        pending_action = null;
        mutex.unlock(process_io);
    }
    if (oriel.options.zig_ui) @import("oriel_frontend.zig").configure(process_io);
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .app = app.build,
        .window = .{ .title = "Penny Goblin", .width = 1180, .height = 820, .hide_on_close = oriel.tray.available },
        .setup = setup,
    });
}

comptime {
    if (oriel.target.is_android) _ = @import("sync_android.zig");
}

fn emit_research(event: research_runtime.Event) void {
    oriel.App.events(Events).emit(.research_progress, event);
}
