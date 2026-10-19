const std = @import("std");
const oriel = @import("oriel");

pub fn build(b: *std.Build) void {
    // On macOS, a target without a version builds for macOS 13+ (not just
    // the Mac building it); pass this target to every executable you add.
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const Renderer = enum { webview, native, oriel };
    const renderer = b.option(Renderer, "renderer", "Renderer: webview, native (HTML/JS), or oriel (compiled views)") orelse .webview;
    const vision = b.option(bool, "vision", "Build Oriel's on-device vision runtime") orelse true;
    const mobile = target.result.abi.isAndroid() or target.result.os.tag == .ios;
    // GPU backends for local vision. Vulkan and OpenCL stay off: the CPU was
    // faster on every device measured (desktop Vulkan 21 s vs 15 s CPU; on
    // the phones, slower or unavailable). -Dggml_cuda builds libggml-cuda.so
    // for NVIDIA GPUs, shipped next to the app and loaded only where the
    // driver is present (elsewhere the CPU runs the model).
    const ggml_opencl = b.option(bool, "ggml_opencl", "Android: OpenCL backend for Adreno GPUs") orelse false;
    const ggml_vulkan = b.option(bool, "ggml_vulkan", "Vulkan backend for local vision") orelse false;
    const ggml_cuda = b.option(bool, "ggml_cuda", "Linux: CUDA backend for local vision (needs the CUDA toolkit)") orelse false;
    const cuda_arch = b.option([]const u8, "cuda_arch", "-Dggml_cuda: compute capabilities like 75,86,89,120 (default: this machine's GPU)");
    const cuda_static = b.option(bool, "cuda_static", "-Dggml_cuda: link cuBLAS statically, so only the NVIDIA driver is needed at runtime") orelse false;
    const cuda_prebuilt = b.option([]const u8, "ggml_cuda_prebuilt", "Absolute path of a libggml-cuda.so built earlier from this Oriel snapshot (implies -Dggml_cuda; no nvcc)");
    const helper_file: ?std.Build.LazyPath = if (mobile) null else blk: {
        // The helper is a native executable: PyInstaller builds it on the host OS.
        const command = b.addSystemCommand(&.{if (b.graph.host.result.os.tag == .windows) "python" else "python3"});
        command.addFileArg(b.path("scripts/build-statement-helper.py"));
        command.addArg("--output");
        const output = command.addOutputFileArg("statement-helper.bin");
        command.addFileArg(b.path("src/helpers/statement_helper.py"));
        command.addFileArg(b.path("src/helpers/santander_parser.py"));
        command.addFileArg(b.path("src/helpers/bci_parser.py"));
        command.addFileArg(b.path("src/helpers/sync_transport.py"));
        command.addFileArg(b.path("scripts/helper-requirements.txt"));
        break :blk output;
    };
    const helper_files = b.addWriteFiles();
    const helper_root = helper_files.add("helper.zig", if (mobile) "pub const bytes = \"\";" else "pub const bytes = @embedFile(\"statement-helper.bin\");");
    if (helper_file) |file| _ = helper_files.addCopyFile(file, "statement-helper.bin");
    const helper_module = b.createModule(.{ .root_source_file = helper_root });

    // Oriel's built-in modules and plugins. Switch on what the app uses:
    // anything left off is neither compiled nor linked. Say it once for
    // every target: where a module doesn't exist (a tray on phones),
    // `oriel.tray.available` is false, so guard its calls with
    // `if (oriel.tray.available)`.
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .tray = true,
        .menu = false,
        .store = false,
        .dialog = true,
        .camera = true,
        .notification = false,
        .updater = false,
        .sql = true,
        .llama = vision,
        .llama_mtmd = vision,
        .fs_watch = false,
        .media_server = false,
        .global_shortcut = false,
        .input = false,
        .clipboard = false,
        // The phone's own model (Gemini Nano through ML Kit) as a scanner;
        // elsewhere `oriel.system_ai.available` is false.
        .system_ai = true,
        .ggml_opencl = ggml_opencl,
        .ggml_vulkan = ggml_vulkan,
        .ggml_cuda = ggml_cuda,
        .cuda_arch = cuda_arch,
        .cuda_static = cuda_static,
        .ggml_cuda_prebuilt = cuda_prebuilt,
        // Oriel's experimental native renderer instead of the WebView.
        .native_ui = renderer != .webview or (b.option(bool, "native_ui", "Compatibility: use HTML/JS native renderer") orelse false),
        .zig_ui = renderer == .oriel,
    });

    // Frontend in frontend/ (embeds frontend/ as-is).
    // zig build          production build
    // zig build run      run it
    // zig build check    type-check src/ without building
    // zig build package  installers: deb/rpm/AppImage (Linux), setup.exe (Windows), .app/.dmg (macOS)
    const view_names = [_][]const u8{ "application", "payment", "editor", "preferences-dialog", "fixed-page", "statements-page", "scanner-page", "statement-dialog", "sync-dialog", "item", "mapping", "evidence", "notice", "pager", "backdrop", "evidence-panel", "text", "review-row", "donut", "day", "category-row", "report-row", "comparison", "progress", "scanner-row", "statement-source", "statement-evidence", "suggestion", "sync-device", "sync-conflict", "budget-part", "research-dialog", "research-proposal", "research-source", "category-picker", "category-option" };
    var imports: [view_names.len + 1]std.Build.Module.Import = undefined;
    imports[0] = .{ .name = "penny_helper", .module = helper_module };
    for (view_names, 1..) |name, i| imports[i] = .{
        .name = b.fmt("{s}.oriel", .{name}),
        .module = b.createModule(.{ .root_source_file = b.path(b.fmt("views/{s}.oriel", .{name})) }),
    };
    const application = oriel.addApp(b, dep, .{
        .name = "penny-goblin",
        .root_source_file = b.path("src/main.zig"),
        .imports = &imports,
        .icon = b.path("icon.png"), // High-resolution PNG (1024x1024 recommended)
        .permissions = .{ .camera = "Photograph receipts to record household expenses" },
        .extensions = &.{
            .{
                .name = "penny.sync",
                .android = .{
                    .class = "com.pennygoblin.sync.SyncExtension",
                    .sources = &.{ b.path("platform/android/SyncExtension.kt"), b.path("platform/android/SyncEngine.kt"), b.path("platform/android/NativeSync.kt"), b.path("platform/android/PinnedHttp.kt"), b.path("platform/android/Credentials.kt") },
                    .dependencies = &.{ "androidx.work:work-runtime-ktx:2.10.1", "com.journeyapps:zxing-android-embedded:4.3.0" },
                },
                // A voucher photo for the desktop to scan (scan): the
                // desktop takes up to 24 MB (sync_transport.py MAX_SCAN_BYTES).
                .max_bytes = 24 * 1024 * 1024,
            },
            .{
                // Fast scans: ML Kit text recognition (bundled Latin model, offline).
                .name = "penny.ocr",
                .android = .{
                    .class = "com.pennygoblin.ocr.OcrExtension",
                    .sources = &.{b.path("platform/android/OcrExtension.kt")},
                    .dependencies = &.{ "com.google.mlkit:text-recognition:16.0.1", "androidx.exifinterface:exifinterface:1.3.7" },
                },
                .max_bytes = 10 * 1024 * 1024,
            },
        },
        .android = .{
            .hooks = &.{.{ .class = "com.pennygoblin.sync.SyncExtension" }},
            .permissions = &.{ .{ .name = "android.permission.ACCESS_NETWORK_STATE" }, .{ .name = "android.permission.ACCESS_WIFI_STATE" }, .{ .name = "android.permission.CHANGE_WIFI_MULTICAST_STATE" } },
            .proguard_rules = b.path("platform/android/proguard-rules.pro"),
        },
        .frontend = .{
            // A static page: embedded as-is, no npm and no dev server.
            .dir = if (renderer == .oriel) "views" else "frontend",
            .dist = ".",
            .build_command = null,
            .install_command = null,
            .dev = null,
            .types_path = null,
        },
        .package = .{
            .id = "com.pennygoblin.app",
            .name = "Penny Goblin",
            // .publisher = "Your Name <you@example.com>", // default: from the app id
            .summary = "Private household expenses, on your devices",
            .version = "0.2.10",
        },
        // The isolation pattern: every call from the frontend to Zig goes
        // through isolation/hook.js first, in a frame the page can't reach.
        // .isolation = .{ .hook = b.path("isolation/hook.js") },
    });

    // Zig's native ELF linker cannot yet consume GCC 16 .sframe relocations.
    const tests = b.addTest(.{ .use_llvm = true, .use_lld = target.result.ofmt != .macho, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "oriel", .module = dep.module("oriel") }},
    }) });
    b.step("test", "Test ledger invariants and legacy migration").dependOn(&b.addRunArtifact(tests).step);

    const verifier = b.addExecutable(.{
        .name = "verify-legacy",
        .use_llvm = true,
        .use_lld = target.result.ofmt != .macho,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/verify_legacy.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "oriel", .module = dep.module("oriel") }},
        }),
    });
    const verify = b.addRunArtifact(verifier);
    if (b.args) |args| verify.addArgs(args);
    b.step("verify-legacy", "Verify a web export in memory without logging financial data").dependOn(&verify.step);

    const report_verifier = b.addExecutable(.{ .name = "verify-reports", .use_llvm = true, .use_lld = target.result.ofmt != .macho, .root_module = b.createModule(.{
        .root_source_file = b.path("src/verify_reports.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "oriel", .module = dep.module("oriel") }},
    }) });
    const report_check = b.addRunArtifact(report_verifier);
    if (b.args) |args| report_check.addArgs(args);
    b.step("verify-reports", "Compare a web export against scripts/report-oracle.cjs output").dependOn(&report_check.step);

    const importer = b.addExecutable(.{
        .name = "import-web",
        .use_llvm = true,
        .use_lld = target.result.ofmt != .macho,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/import_web.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "oriel", .module = dep.module("oriel") }},
        }),
    });
    const import_web = b.addRunArtifact(importer);
    if (b.args) |args| import_web.addArgs(args);
    b.step("import-web", "Add a web export to a ledger: -- export.json ledger.sqlite3").dependOn(&import_web.step);

    // Android's launcher has no app module; the fixture runner is a desktop tool.
    const app_module = application.exe.root_module.import_table.get("oriel_app") orelse return;
    if (renderer == .oriel and !mobile) {
        var ui_imports: [imports.len + 2]std.Build.Module.Import = undefined;
        @memcpy(ui_imports[0..imports.len], &imports);
        ui_imports[imports.len] = .{ .name = "oriel", .module = dep.module("oriel") };
        ui_imports[imports.len + 1] = .{ .name = "oriel_app", .module = app_module };
        const ui_tests = b.addTest(.{ .use_llvm = true, .use_lld = target.result.ofmt != .macho, .root_module = b.createModule(.{
            .root_source_file = b.path("src/oriel_frontend.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &ui_imports,
        }) });
        b.step("test-ui", "Exercise compiled views, drafts, revisions and responsive state").dependOn(&b.addRunArtifact(ui_tests).step);
    }
    const scan_verifier = b.addExecutable(.{
        .name = "verify-scan",
        .use_llvm = true,
        .use_lld = target.result.ofmt != .macho,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/verify_scan.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "oriel", .module = dep.module("oriel") },
                .{ .name = "oriel_app", .module = app_module },
            },
        }),
    });
    const research_verifier = b.addExecutable(.{ .name = "verify-research", .use_llvm = true, .use_lld = target.result.ofmt != .macho, .root_module = b.createModule(.{
        .root_source_file = b.path("src/verify_research.zig"), .target = target, .optimize = .ReleaseSafe,
        .imports = &.{ .{ .name = "oriel", .module = dep.module("oriel") }, .{ .name = "oriel_app", .module = app_module } },
    }) });
    const verify_research = b.addRunArtifact(research_verifier);
    if (b.args) |args| verify_research.addArgs(args);
    b.step("verify-research", "Exercise real research against synthetic merchants on a private display").dependOn(&verify_research.step);
    const research_binary = b.addInstallArtifact(research_verifier, .{});
    b.step("build-research-verifier", "Build the standalone research acceptance runner").dependOn(&research_binary.step);

    // GPU backend libraries (libggml-vulkan.so) bind to ggml in the executable.
    scan_verifier.rdynamic = true;
    b.installArtifact(scan_verifier);
    const verify_scan = b.addRunArtifact(scan_verifier);
    if (b.args) |args| verify_scan.addArgs(args);
    b.step("verify-scan", "Check real local extraction against an image and expected JSON fixture").dependOn(&verify_scan.step);
}
