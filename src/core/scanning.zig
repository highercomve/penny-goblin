//! Scanner data shared by the app and tests: the downloadable model
//! catalog, the saved-choice vocabulary and parsing of an extraction reply.
//! Catalog entries pin a commit and both SHA-256s (Hugging Face API, checked
//! 2026-10), so a re-uploaded file cannot change under a hash. Each phone entry
//! was run on a Chilean boleta and a transfer voucher (2026-10-16); SmolVLM2
//! 500M/2.2B were tried and left out: they misread amounts.
const std = @import("std");
const model = @import("model.zig");

pub const Extraction = struct {
    amount: i64 = 0,
    currency: []const u8 = "CLP",
    date: []const u8 = "",
    time: []const u8 = "",
    payee: []const u8 = "",
    reference: []const u8 = "",
    location: []const u8 = "",
    bank: []const u8 = "",
    kind: []const u8 = "receipt",
    /// How it was read: "text" (OCR + rules) or "model"; not part of the model's schema.
    engine: []const u8 = "model",
};

/// Fast OCR only supplies a positive amount when its total is unambiguous.
/// A model filling missing fields must not replace that evidence with a subtotal.
pub fn preferTextAmount(inferred: Extraction, text: ?Extraction) Extraction {
    var value = inferred;
    if (text) |known| if (known.amount > 0) { value.amount = known.amount; };
    return value;
}

pub const max_id_len = 32;

pub const Entry = struct {
    id: []const u8,
    label: []const u8,
    repo: []const u8,
    revision: []const u8,
    file: []const u8,
    size: u64,
    sha256: []const u8,
    projector: []const u8,
    /// Unique local name: repos often call their projector mmproj-F16.gguf.
    projector_local: []const u8,
    projector_size: u64,
    projector_sha256: []const u8,
    note: []const u8,
    /// Too large for phone memory: hidden there.
    desktop_only: bool = false,
};

/// Smallest first.
pub const catalog = [_]Entry{
    .{ .id = "qwen3.5-0.8b", .label = "Qwen3.5 0.8B", .repo = "unsloth/Qwen3.5-0.8B-GGUF", .revision = "6ab461498e2023f6e3c1baea90a8f0fe38ab64d0", .file = "Qwen3.5-0.8B-Q4_K_M.gguf", .size = 532517120, .sha256 = "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517", .projector = "mmproj-F16.gguf", .projector_local = "mmproj-qwen3.5-0.8b-F16.gguf", .projector_size = 204987232, .projector_sha256 = "56e4c6cfe73b0c82e3e82bc518d7591997e61d81f723fc41a586f4fa69ea2453", .note = "Fastest and smallest. Often misses dates; check them." },
    .{ .id = "qwen3.5-2b", .label = "Qwen3.5 2B", .repo = "unsloth/Qwen3.5-2B-GGUF", .revision = "f6d5376be1edb4d416d56da11e5397a961aca8ae", .file = "Qwen3.5-2B-Q4_K_M.gguf", .size = 1280835840, .sha256 = "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223", .projector = "mmproj-F16.gguf", .projector_local = "mmproj-qwen3.5-2b-F16.gguf", .projector_size = 668227264, .projector_sha256 = "7035e9cb8d7c6a9681d07eef9a364783e86ea4cd73faab2eabb4f43a101830c7", .note = "Recommended. Read our test receipt and transfer correctly." },
    .{ .id = "qwen2.5-vl-3b", .label = "Qwen2.5-VL 3B", .repo = "ggml-org/Qwen2.5-VL-3B-Instruct-GGUF", .revision = "5037fcf163dd95d1e41d1974465f0898ed108ca2", .file = "Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf", .size = 1929901056, .sha256 = "d02fe9b69ad8cadbbd228e387667af66612c44bed29ffc8eb1e7caf9ac486c12", .projector = "mmproj-Qwen2.5-VL-3B-Instruct-Q8_0.gguf", .projector_local = "mmproj-Qwen2.5-VL-3B-Instruct-Q8_0.gguf", .projector_size = 844757728, .projector_sha256 = "980c9b2f78c04e6cff93d277ada09e768394f112d75db3b4e9dea8a69f9fb904", .note = "Very accurate. Slower than 2B." },
    .{ .id = "gemma-3-4b-it", .label = "Gemma 3 4B", .repo = "ggml-org/gemma-3-4b-it-GGUF", .revision = "d0976223747697cb51e056d85c532013931fe52e", .file = "gemma-3-4b-it-Q4_K_M.gguf", .size = 2489757856, .sha256 = "882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863", .projector = "mmproj-model-f16.gguf", .projector_local = "mmproj-gemma-3-4b-it-f16.gguf", .projector_size = 851251104, .projector_sha256 = "8c0fb064b019a6972856aaae2c7e4792858af3ca4561be2dbf649123ba6c40cb", .note = "Accurate names, but slow and may miss dates. Needs 8 GB of memory." },
    .{ .id = "gemma-4-e2b-it", .label = "Gemma 4 E2B", .repo = "unsloth/gemma-4-E2B-it-GGUF", .revision = "0314792d7f1f7e229411f620751375812bb9faf2", .file = "gemma-4-E2B-it-Q4_K_M.gguf", .size = 3106738272, .sha256 = "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8", .projector = "mmproj-F16.gguf", .projector_local = "mmproj-gemma-4-e2b-it-F16.gguf", .projector_size = 985654080, .projector_sha256 = "140be8d7849741f88c50757d529b84373ee8e27052cc2236855b537f4a8215fa", .note = "Fast for its size; may misread store names. Needs 8 GB of memory." },
    .{ .id = "qwen3.5-4b", .label = "Qwen3.5 4B", .repo = "unsloth/Qwen3.5-4B-GGUF", .revision = "e87f176479d0855a907a41277aca2f8ee7a09523", .file = "Qwen3.5-4B-Q4_K_M.gguf", .size = 2740937888, .sha256 = "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4", .projector = "mmproj-F16.gguf", .projector_local = "mmproj-qwen3.5-4b-F16.gguf", .projector_size = 672423616, .projector_sha256 = "cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864", .note = "Balanced desktop choice.", .desktop_only = true },
    .{ .id = "gemma-4-e4b-it", .label = "Gemma 4 E4B", .repo = "unsloth/gemma-4-E4B-it-GGUF", .revision = "bfc15c382204943c3a8fff0c750b94ae2364d7a3", .file = "gemma-4-E4B-it-Q4_K_M.gguf", .size = 4977171584, .sha256 = "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87", .projector = "mmproj-F16.gguf", .projector_local = "mmproj-gemma-4-e4b-it-F16.gguf", .projector_size = 990372672, .projector_sha256 = "ddf46c21d7078e95338cfc22306b19b276a29a5ad089023449dd54d4b6170a51", .note = "Best quality on desktops.", .desktop_only = true },
};

pub fn find(id: []const u8) ?Entry {
    for (catalog) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}

pub fn validChoice(id: []const u8) bool {
    return std.mem.eql(u8, id, "system") or std.mem.eql(u8, id, "custom") or find(id) != null;
}

/// A model reply to an Extraction: the outermost JSON object, so fences or
/// chatter around it (system models follow the schema only as instructions)
/// are tolerated; anything else is InvalidExtraction.
pub fn parseReply(arena: std.mem.Allocator, reply: []const u8) !Extraction {
    if (!std.unicode.utf8ValidateSlice(reply)) return error.InvalidExtraction;
    const start = std.mem.indexOfScalar(u8, reply, '{') orelse return error.InvalidExtraction;
    const end = std.mem.lastIndexOfScalar(u8, reply, '}') orelse return error.InvalidExtraction;
    if (end < start) return error.InvalidExtraction;
    var value = std.json.parseFromSliceLeaky(Extraction, arena, reply[start .. end + 1], .{ .ignore_unknown_fields = true }) catch return error.InvalidExtraction;
    value.date = try isoDate(arena, value.date);
    return value;
}

/// "16/10/2026" or "16-10-26" (how Chilean documents print dates) to
/// "2026-10-16"; ISO dates pass through; anything else becomes "".
fn isoDate(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const date = std.mem.trim(u8, text, " ");
    if (date.len == 10 and date[4] == '-' and date[7] == '-') return if (model.valid_date(date)) date else "";
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, date, "/-.");
    while (it.next()) |part| : (count += 1) {
        if (count == 3) return "";
        parts[count] = part;
    }
    if (count != 3 or parts[0].len > 2 or parts[1].len > 2) return "";
    const day = std.fmt.parseInt(u8, parts[0], 10) catch return "";
    const month = std.fmt.parseInt(u8, parts[1], 10) catch return "";
    var year = std.fmt.parseInt(u16, parts[2], 10) catch return "";
    if (parts[2].len == 2) year += 2000 else if (parts[2].len != 4) return "";
    if (day < 1 or day > 31 or month < 1 or month > 12) return "";
    const iso = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
    return if (model.valid_date(iso)) iso else "";
}

/// When an image was taken, as YYYY-MM-DD, for a voucher that prints no
/// date (an app's success screen): the date Android names screenshots and
/// photos with ("Screenshot_20261005-1306…", "Screenshot_2026-10-05-13-06…",
/// "IMG_20261005_…", "PXL_20261005_…"), else a JPEG's EXIF date. Null when
/// neither has one; dates after `today` don't count.
pub fn imageDate(arena: std.mem.Allocator, name: []const u8, bytes: []const u8, today: []const u8) !?[]const u8 {
    if (try nameDate(arena, name, today)) |date| return date;
    return exifDate(arena, bytes[0..@min(bytes.len, 64 * 1024)], today);
}

fn nameDate(arena: std.mem.Allocator, name: []const u8, today: []const u8) !?[]const u8 {
    var i: usize = 0;
    while (i + 8 <= name.len) : (i += 1) {
        if (i > 0 and std.ascii.isDigit(name[i - 1])) continue;
        if (!std.mem.startsWith(u8, name[i..], "20")) continue;
        // YYYYMMDD or YYYY-MM-DD, not part of a longer number.
        const dashed = i + 10 <= name.len and name[i + 4] == '-' and name[i + 7] == '-';
        const parts: [3][]const u8 = if (dashed) .{ name[i .. i + 4], name[i + 5 .. i + 7], name[i + 8 .. i + 10] } else .{ name[i .. i + 4], name[i + 4 .. i + 6], name[i + 6 .. i + 8] };
        const end = i + @as(usize, if (dashed) 10 else 8);
        if (end < name.len and std.ascii.isDigit(name[end])) continue;
        const date = try std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{ parts[0], parts[1], parts[2] });
        if (model.valid_date(date) and std.mem.order(u8, date, today) != .gt) return date;
    }
    return null;
}

/// EXIF's "YYYY:MM:DD HH:MM:SS" (DateTimeOriginal, or the file's DateTime)
/// in a JPEG's first bytes.
fn exifDate(arena: std.mem.Allocator, head: []const u8, today: []const u8) !?[]const u8 {
    if (head.len < 4 or head[0] != 0xff or head[1] != 0xd8 or std.mem.indexOf(u8, head, "Exif\x00\x00") == null) return null;
    var i: usize = 0;
    while (i + 19 <= head.len) : (i += 1) {
        const t = head[i .. i + 19];
        const shape = "dddd:dd:dd dd:dd:dd";
        const fits = for (shape, t) |want, ch| {
            if (want == 'd' and !std.ascii.isDigit(ch)) break false;
            if (want != 'd' and ch != want) break false;
        } else true;
        if (!fits) continue;
        const date = try std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{ t[0..4], t[5..7], t[8..10] });
        if (model.valid_date(date) and std.mem.order(u8, date, today) != .gt) return date;
    }
    return null;
}

test imageDate {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const today = "2026-10-18";
    try std.testing.expectEqualStrings("2026-10-05", (try imageDate(a, "Screenshot_20261005-130641.png", "", today)).?);
    try std.testing.expectEqualStrings("2026-10-05", (try imageDate(a, "Screenshot_2026-10-05-13-06-12-345_cl.app.jpg", "", today)).?);
    try std.testing.expectEqualStrings("2026-09-17", (try imageDate(a, "PXL_20260917_123456789.jpg", "", today)).?);
    try std.testing.expect(try imageDate(a, "Screenshot_20261399-1.png", "", today) == null);
    try std.testing.expect(try imageDate(a, "IMG_20261231_1.jpg", "", today) == null); // after today
    try std.testing.expect(try imageDate(a, "onepay.jpg", "not a jpeg", today) == null);
    const jpeg = "\xff\xd8\xff\xe1\x00\x40Exif\x00\x00MM\x00\x2a....2026:09:30 18:04:11\x00";
    try std.testing.expectEqualStrings("2026-09-30", (try imageDate(a, "voucher.jpg", jpeg, today)).?);
}

test "catalog entries are pinned and unique" {
    for (catalog, 0..) |entry, index| {
        try std.testing.expectEqual(@as(usize, 40), entry.revision.len);
        try std.testing.expectEqual(@as(usize, 64), entry.sha256.len);
        try std.testing.expectEqual(@as(usize, 64), entry.projector_sha256.len);
        try std.testing.expect(entry.id.len <= max_id_len);
        for (catalog[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.id, other.id));
            try std.testing.expect(!std.mem.eql(u8, entry.projector_local, other.projector_local));
        }
    }
    try std.testing.expect(validChoice("system") and validChoice("custom") and validChoice("qwen3.5-2b"));
    try std.testing.expect(!validChoice("../../etc/passwd"));
}

test "system replies are parsed from fenced or chatty JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseReply(arena.allocator(), "```json\n{\"amount\":53970,\"payee\":\"Andrea\",\"extra\":1}\n```");
    try std.testing.expectEqual(@as(i64, 53970), parsed.amount);
    try std.testing.expectEqualStrings("Andrea", parsed.payee);
    try std.testing.expectError(error.InvalidExtraction, parseReply(arena.allocator(), "no json here"));
    try std.testing.expectEqualStrings("2026-10-16", (try parseReply(arena.allocator(), "{\"date\":\"16/10/2026\"}")).date);
    try std.testing.expectEqualStrings("2026-10-09", (try parseReply(arena.allocator(), "{\"date\":\"9-10-26\"}")).date);
    try std.testing.expectEqualStrings("", (try parseReply(arena.allocator(), "{\"date\":\"yesterday\"}")).date);
    try std.testing.expectEqualStrings("", (try parseReply(arena.allocator(), "{\"date\":\"1610-20-20\"}")).date);
}


test "model completion preserves a reliable OCR total after discounts" {
    const inferred: Extraction = .{ .amount = 435670, .payee = "SUPERMERCADO TOTTUS SA.", .date = "2026-10-18" };
    const result = preferTextAmount(inferred, .{ .amount = 383605, .engine = "text" });
    try std.testing.expectEqual(@as(i64, 383605), result.amount);
    try std.testing.expectEqualStrings(inferred.payee, result.payee);
    try std.testing.expectEqualStrings(inferred.date, result.date);
    try std.testing.expectEqual(inferred.amount, preferTextAmount(inferred, .{ .amount = 0 }).amount);
    try std.testing.expectEqual(inferred.amount, preferTextAmount(inferred, null).amount);
}
