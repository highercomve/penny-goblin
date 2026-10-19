//! Reporting shared by compiled Oriel views. Reviewed payments never become plans.
const std = @import("std");
const model = @import("model.zig");
const legacy = @import("legacy.zig");
pub const Settings = legacy.Settings;
pub const Totals = struct {
    actual: i64 = 0,
    variable: i64 = 0,
    fixed: i64 = 0,
    special: i64 = 0,
    salary: i64 = 0,
    planned: i64 = 0,
    actual_remaining: i64 = 0,
    forecast: i64 = 0,
};
pub const Filter = struct {
    month: []const u8 = "",
    account: []const u8 = "",
    category: []const u8 = "",
    search: []const u8 = "",
    from: []const u8 = "",
    through: []const u8 = "",
    audit: bool = false,
    pub fn matches(f: Filter, row: model.Expense, settings: Settings) bool {
        if (f.from.len > 0 and f.through.len > 0 and std.mem.order(u8, f.from, f.through) == .gt) return false;
        if (f.month.len > 0 and !std.mem.startsWith(u8, row.date, f.month)) return false;
        if (f.account.len > 0 and !std.mem.eql(u8, f.account, row.account)) return false;
        if (f.category.len > 0 and !category_matches(f.category, row, settings)) return false;
        if (f.from.len > 0 and std.mem.order(u8, row.date, f.from) == .lt) return false;
        if (f.through.len > 0 and std.mem.order(u8, row.date, f.through) == .gt) return false;
        if (f.audit and !uncategorized(row, settings)) return false;
        return f.search.len == 0 or contains(row.payee, f.search) or contains(row.notes, f.search) or contains(special(row, settings) orelse row.category, f.search);
    }
};
pub fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| if (fold_equal(haystack[i..][0..needle.len], needle)) return true;
    return false;
}
fn latin_lower(cp: u21) u21 {
    return if ((cp >= 'A' and cp <= 'Z') or (cp >= 0xc0 and cp <= 0xd6) or (cp >= 0xd8 and cp <= 0xde)) cp + 32 else if (cp == 0x178) 0xff else cp;
}
fn fold_equal(left: []const u8, right: []const u8) bool {
    const l = std.unicode.Utf8View.init(left) catch return false;
    const r = std.unicode.Utf8View.init(right) catch return false;
    var a = l.iterator();
    var b = r.iterator();
    while (a.nextCodepoint()) |cp| {
        const other = b.nextCodepoint() orelse return false;
        if (latin_lower(cp) != latin_lower(other)) return false;
    }
    return b.nextCodepoint() == null;
}
pub fn holder(account: []const u8, settings: Settings) []const u8 {
    if (settings.cards_config != .object) return account;
    const v = settings.cards_config.object.get(account) orelse return account;
    if (v == .string) return v.string;
    if (v == .object) if (v.object.get("holder")) |h| if (h == .string) return h.string;
    return account;
}
/// The returned label borrows account/config data or uses the caller's arena.
pub fn account_label(a: std.mem.Allocator, account: []const u8, config: Settings) ![]const u8 {
    const owner = holder(account, config);
    return if (std.mem.eql(u8, owner, account)) account else std.fmt.allocPrint(a, "{s} · {s}", .{ owner, account });
}
pub fn merchant(a: std.mem.Allocator, payee: []const u8, config: Settings, grouped: bool) ![]const u8 {
    var longest: usize = 0;
    var label: ?[]const u8 = null;
    if (config.vendors_config == .object) {
        var it = config.vendors_config.object.iterator();
        while (it.next()) |entry| if (entry.key_ptr.len > longest and entry.value_ptr.* == .string and contains(payee, entry.key_ptr.*)) {
            longest = entry.key_ptr.len;
            label = entry.value_ptr.string;
        };
    }
    if (label) |v| return v;
    if (!grouped) return std.mem.trim(u8, payee, " ");
    const Alias = struct { name: []const u8, patterns: []const []const u8 };
    const aliases = [_]Alias{
        .{ .name = "Jumbo", .patterns = &.{"JUMBO"} },                                                                                              .{ .name = "Lider", .patterns = &.{"LIDER"} },
        .{ .name = "Clínica Alemana", .patterns = &.{ "CLINICA ALEMANA", "AUTO CL ALEMANA", "DR.CLINICA ALEMANA" } },
        .{ .name = "Uber Eats", .patterns = &.{ "UBER EATS", "UBEREATS" } },                                                                        .{ .name = "Uber", .patterns = &.{ "UBER TRIP", "UBERTRIP", "UBER *TRIP", "UBER*TRIP" } },
        .{ .name = "PedidosYa", .patterns = &.{ "PEDIDOS YA", "PEDIDOSYA" } },                                                                      .{ .name = "Falabella", .patterns = &.{"FALABELLA"} },
        .{ .name = "Paris", .patterns = &.{"PARIS"} },                                                                                              .{ .name = "Ripley", .patterns = &.{"RIPLEY"} },
        .{ .name = "IKEA", .patterns = &.{"IKEA"} },                                                                                                .{ .name = "Easy", .patterns = &.{"EASY"} },
        .{ .name = "Sodimac", .patterns = &.{"SODIMAC"} },                                                                                          .{ .name = "Tottus", .patterns = &.{"TOTTUS"} },
        .{ .name = "Unimarc", .patterns = &.{"UNIMARC"} },                                                                                          .{ .name = "Santa Isabel", .patterns = &.{"SANTA ISABEL"} },
        .{ .name = "Cruz Verde", .patterns = &.{ "C. VERDE", "C.VERDE", "C VERDE", "CVERDE", "CRUZ VERDE" } },                                      .{ .name = "Salcobrand", .patterns = &.{"SALCOBRAND"} },
        .{ .name = "Farmacias Ahumada", .patterns = &.{ "FARMACIA AHUMADA", "FARMACIAS AHUMADA", "FARMACIAAHUMADA", "FARMACIASAHUMADA", "AHUM" } }, .{ .name = "Minimarket Antonia", .patterns = &.{"MINIMARKET ANTONIA"} },
        .{ .name = "Mercado Libre", .patterns = &.{ "MERCADOL", "MERCADOLIBRE" } },
        .{ .name = "Carnicería Los JJ", .patterns = &.{"CARNICERIA LOS JJ"} },
        .{ .name = "Wua Wua", .patterns = &.{"WUA WUA"} },                                                                                          .{ .name = "Copec", .patterns = &.{ "PRONTO COPEC", "PRONTOCOPEC", "COPEC" } },
        .{ .name = "Aramco", .patterns = &.{"ARAMCO"} },                                                                                            .{ .name = "Shell", .patterns = &.{"SHELL"} },
        .{ .name = "Starbucks", .patterns = &.{"STARBUCKS"} },                                                                                      .{ .name = "McDonald's", .patterns = &.{ "MCDONALDS", "MC DONALDS" } },
        .{ .name = "LATAM", .patterns = &.{"LATAM"} },                                                                                              .{ .name = "Decathlon", .patterns = &.{"DECATHLON"} },
        .{ .name = "Casaideas", .patterns = &.{ "CASAIDEAS", "CASA IDEAS" } },                                                                      .{ .name = "Zara", .patterns = &.{"ZARA"} },
        .{ .name = "H&M", .patterns = &.{ "H&M", "H Y M" } },                                                                                       .{ .name = "Spotify", .patterns = &.{"SPOTIFY"} },
        .{ .name = "Netflix", .patterns = &.{"NETFLIX"} },                                                                                          .{ .name = "Apple", .patterns = &.{"APPLE.COM"} },
        .{ .name = "Google", .patterns = &.{"GOOGLE"} },                                                                                            .{ .name = "Amazon", .patterns = &.{"AMAZON"} },
        .{ .name = "Cabify", .patterns = &.{"CABIFY"} },                                                                                            .{ .name = "Tag Total", .patterns = &.{"TAG TOTAL"} },
        .{ .name = "ComunidadFeliz", .patterns = &.{"COMUNIDAD FELIZ"} },                                                                           .{ .name = "Colsalud", .patterns = &.{"COLSALUD"} },
        .{ .name = "Enel", .patterns = &.{"ENEL"} },                                                                                                .{ .name = "Aguas Andinas", .patterns = &.{"AGUAS ANDINAS"} },
        .{ .name = "GTD Manquehue", .patterns = &.{"GTD"} },                                                                                        .{ .name = "VTR", .patterns = &.{"VTR"} },
        .{ .name = "Entel", .patterns = &.{"ENTEL"} },                                                                                              .{ .name = "Claro", .patterns = &.{"CLARO"} },
        .{ .name = "Movistar", .patterns = &.{"MOVISTAR"} },                                                                                        .{ .name = "Kaplan", .patterns = &.{"KAPLAN"} },
        .{ .name = "Lider Express", .patterns = &.{"EXPRESS DE LIDER"} },                                                                           .{ .name = "Ekono", .patterns = &.{"EKONO"} },
        .{ .name = "Dunkin", .patterns = &.{"DUNKIN"} },
    };
    for (aliases) |alias| for (alias.patterns) |pattern| if (word_match(payee, pattern)) return alias.name;
    var stripped = std.mem.trim(u8, payee, " ");
    for ([_][]const u8{ "MERCADOPAGO", "PAYU", "PAYSCAN", "TUU", "WEBPAY", "REDGLOBA", "RED GLOBA", "TRANSBANK", "TBK" }) |prefix| if (stripped.len >= prefix.len and std.ascii.eqlIgnoreCase(stripped[0..prefix.len], prefix)) {
        stripped = std.mem.trimStart(u8, stripped[prefix.len..], " *");
        break;
    };
    if (stripped.len == 0) return a.dupe(u8, std.mem.trim(u8, payee, " "));
    const out = try a.alloc(u8, stripped.len);
    errdefer a.free(out);
    const view = try std.unicode.Utf8View.init(stripped);
    var iterator = view.iterator();
    var written: usize = 0;
    var boundary = true;
    while (iterator.nextCodepoint()) |cp| {
        // Match the web app: Unicode lowercasing, then ASCII /\b\w/g
        // initials. Latin-1 covers the Spanish merchant names in the ledger.
        var lower = latin_lower(cp);
        const word = lower < 128 and (std.ascii.isAlphanumeric(@intCast(lower)) or lower == '_');
        if (boundary and word) lower = std.ascii.toUpper(@intCast(lower));
        written += try std.unicode.utf8Encode(lower, out[written..]);
        boundary = !word;
    }
    std.debug.assert(written == out.len);
    return out;
}
fn word_match(text: []const u8, pattern: []const u8) bool {
    if (pattern.len > text.len) return false;
    for (0..text.len - pattern.len + 1) |i| {
        if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_')) continue;
        const end = i + pattern.len;
        if (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) continue;
        if (std.ascii.eqlIgnoreCase(text[i..end], pattern)) return true;
    }
    return false;
}

pub fn special(row: model.Expense, settings: Settings) ?[]const u8 {
    if (settings.special_cases != .object) return null;
    var it = settings.special_cases.object.iterator();
    while (it.next()) |v| if (v.key_ptr.len > 0 and v.value_ptr.* == .string and contains(row.payee, v.key_ptr.*)) return v.value_ptr.string;
    return null;
}
/// Reporting classification is derived from rules, including historical payments.
/// Keep the reviewed ledger category intact; special transfers remain distinct.
pub fn category_name(a: std.mem.Allocator, row: model.Expense, settings: Settings) ![]const u8 {
    if (special(row, settings)) |label| return std.fmt.allocPrint(a, "Special: {s}", .{label});
    return row.category;
}
pub fn category_matches(name: []const u8, row: model.Expense, settings: Settings) bool {
    if (special(row, settings)) |label| return std.mem.startsWith(u8, name, "Special: ") and std.mem.eql(u8, name[9..], label);
    return std.mem.eql(u8, name, row.category);
}
pub fn uncategorized(row: model.Expense, settings: Settings) bool {
    return std.mem.eql(u8, row.category, "Other") and special(row, settings) == null and fixed_item(row, settings) == null;
}
fn normalized(buf: []u8, value: []const u8) []const u8 {
    var len: usize = 0;
    for (value) |c| {
        if (len == buf.len) break;
        const ch = if (std.ascii.isAlphanumeric(c) or std.ascii.isWhitespace(c)) std.ascii.toUpper(c) else ' ';
        buf[len] = ch;
        len += 1;
    }
    return std.mem.trim(u8, buf[0..len], " \t\r\n");
}
pub fn fixed_item(row: model.Expense, settings: Settings) ?usize {
    for (settings.fixed_expenses_items, 0..) |item, i| {
        if (row.category.len >= 7 and std.ascii.eqlIgnoreCase(row.category[0..7], "Fixed: ") and std.ascii.eqlIgnoreCase(row.category[7..], item.name)) return i;
    }
    var payee_buf: [240]u8 = undefined;
    const payee = normalized(&payee_buf, row.payee);
    for (settings.fixed_expenses_items, 0..) |item, i| for (item.keywords) |word| {
        var keyword_buf: [240]u8 = undefined;
        const keyword = normalized(&keyword_buf, word);
        if (keyword.len > 0 and std.mem.indexOf(u8, payee, keyword) != null) return i;
    };
    return null;
}
/// The budget's numbers, in CLP: payments in another currency are left out
/// (their totals are kept apart, never converted).
pub fn totals(rows: []const model.Expense, settings: Settings) Totals {
    var t: Totals = .{ .salary = settings.salary };
    for (settings.fixed_expenses_items) |item| t.planned += item.amount;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.currency, "CLP")) continue;
        t.actual += row.amount;
        if (special(row, settings) != null) t.special += row.amount else if (std.mem.startsWith(u8, row.category, "Fixed:") or fixed_item(row, settings) != null) t.fixed += row.amount else t.variable += row.amount;
    }
    t.actual_remaining = t.salary - t.actual;
    t.forecast = t.salary - t.planned - t.variable - t.special;
    return t;
}
/// A payment's amount in its currency: "$53.970" in CLP, "US$46.63" in USD.
pub fn amount_text(buf: []u8, amount: i64, currency: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, currency, "USD")) return money(buf, amount);
    var digits: [32]u8 = undefined;
    const whole = try std.fmt.bufPrint(&digits, "{d}", .{@divTrunc(@abs(amount), 100)});
    var w: std.Io.Writer = .fixed(buf);
    if (amount < 0) try w.writeByte('-');
    try w.writeAll("US$");
    for (whole, 0..) |ch, i| {
        if (i > 0 and (whole.len - i) % 3 == 0) try w.writeByte(',');
        try w.writeByte(ch);
    }
    try w.print(".{d:0>2}", .{@mod(@abs(amount), 100)});
    return w.buffered();
}

pub fn money(buf: []u8, amount: i64) ![]const u8 {
    if (buf.len < 48) return error.NoSpaceLeft;
    var digits: [32]u8 = undefined;
    const number = try std.fmt.bufPrint(&digits, "{d}", .{@abs(amount)});
    var pos: usize = 0;
    if (amount < 0) {
        buf[pos] = '-';
        pos += 1;
    }
    buf[pos] = '$';
    pos += 1;
    for (number, 0..) |ch, i| {
        if (i > 0 and (number.len - i) % 3 == 0) {
            buf[pos] = '.';
            pos += 1;
        }
        if (pos == buf.len) return error.NoSpaceLeft;
        buf[pos] = ch;
        pos += 1;
    }
    return buf[0..pos];
}
test "compiled reporting preserves fixed precedence and forecast" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Settings, a,
        \\{"salary":1000,"fixed_expenses_items":[{"name":"Cleaning","amount":200,"keywords":["cleaner"]},{"name":"Childcare","amount":20}],"special_cases":{"FAMILY":"Family"}}
    , .{});
    defer parsed.deinit();
    const rows = [_]model.Expense{
        .{ .id = "", .date = "2026-10-01", .amount = 100, .payee = "Market", .category = "Food" },
        .{ .id = "", .date = "2026-10-01", .amount = 150, .payee = "Cleaner", .category = "Fixed: Childcare" },
        .{ .id = "", .date = "2026-10-01", .amount = 50, .payee = "Family" },
    };
    const t = totals(&rows, parsed.value);
    try std.testing.expectEqual(@as(i64, 300), t.actual);
    try std.testing.expectEqual(@as(i64, 700), t.actual_remaining);
    try std.testing.expectEqual(@as(i64, 630), t.forecast);
    try std.testing.expectEqual(@as(?usize, 1), fixed_item(rows[1], parsed.value));
    try std.testing.expect(!(Filter{ .from = "2026-10-02", .through = "2026-10-01" }).matches(rows[0], parsed.value));
    try std.testing.expect((Filter{ .search = "market" }).matches(rows[0], parsed.value));
}

pub fn suggest_category(a: std.mem.Allocator, payee: []const u8, config: Settings) !?[]const u8 {
    if (fixed_item(.{ .id = "", .date = "", .amount = 0, .payee = payee, .category = "" }, config)) |i| {
        const name = config.fixed_expenses_items[i].name;
        if (name.len + 7 <= 120) return try std.fmt.allocPrint(a, "Fixed: {s}", .{name});
    }
    if (config.categories == .object) {
        var it = config.categories.object.iterator();
        while (it.next()) |entry| if (entry.value_ptr.* == .array) for (entry.value_ptr.array.items) |word| {
            if (word == .string and word.string.len > 0 and contains(payee, word.string)) return entry.key_ptr.*;
        };
    }
    return null;
}
const ReportGroup = enum { category, account, merchant };
const ReportSummary = struct { name: []const u8, amount: i64 = 0, count: usize = 0 };
fn html_groups(a: std.mem.Allocator, w: *std.Io.Writer, rows: []const model.Expense, config: Settings, kind: ReportGroup) !void {
    var groups: std.StringHashMapUnmanaged(ReportSummary) = .empty;
    defer groups.deinit(a);
    for (rows) |row| {
        if (!std.mem.eql(u8, row.currency, "CLP")) continue; // CLP columns; USD is listed below.
        const key = switch (kind) {
            .category => row.category,
            .account => try account_label(a, row.account, config),
            .merchant => try merchant(a, row.payee, config, true),
        };
        const result = try groups.getOrPut(a, key);
        if (!result.found_existing) result.value_ptr.* = .{ .name = key };
        result.value_ptr.amount += row.amount;
        result.value_ptr.count += 1;
    }
    var items: std.ArrayList(ReportSummary) = .empty;
    defer items.deinit(a);
    var it = groups.valueIterator();
    while (it.next()) |summary| try items.append(a, summary.*);
    std.mem.sort(ReportSummary, items.items, {}, struct {
        fn less(_: void, x: ReportSummary, y: ReportSummary) bool {
            return if (x.amount == y.amount) std.ascii.lessThanIgnoreCase(x.name, y.name) else x.amount > y.amount;
        }
    }.less);
    try w.print("<h2>{s}</h2><table><thead><tr><th>Name</th><th>Payments</th><th>Actual CLP</th></tr></thead><tbody>", .{switch (kind) {
        .category => "Categories",
        .account => "Accounts",
        .merchant => "Merchants",
    }});
    var buf: [48]u8 = undefined;
    for (items.items) |summary| {
        try w.writeAll("<tr><td>");
        try html_text(w, summary.name);
        try w.print("</td><td>{d}</td><td>{s}</td></tr>", .{ summary.count, try money(&buf, summary.amount) });
    }
    try w.writeAll("</tbody></table>");
}

fn html_text(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}
/// Standalone export: money stays integer and every user-supplied cell is escaped.
pub fn html_report(a: std.mem.Allocator, rows: []const model.Expense, config: Settings) ![]const u8 {
    var work = std.heap.ArenaAllocator.init(a);
    defer work.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Penny Goblin expense report</title><style>body{font:15px system-ui;color:#233e34;max-width:1100px;margin:40px auto;padding:0 20px}table{border-collapse:collapse;width:100%}td,th{padding:10px;text-align:left;border-bottom:1px solid #ddd}td:last-child{text-align:right}@media print{tr{break-inside:avoid}}</style><h1>Penny Goblin · Expense report</h1>");
    const t = totals(rows, config);
    var money_buf: [48]u8 = undefined;
    try w.print("<p>Actual spending {s} · {d} payments</p>", .{ try money(&money_buf, t.actual), rows.len });
    try w.print("<p>Salary {s}", .{try money(&money_buf, t.salary)});
    try w.print(" · planned fixed {s}", .{try money(&money_buf, t.planned)});
    try w.print(" · forecast {s}</p>", .{try money(&money_buf, t.forecast)});
    try html_groups(work.allocator(), w, rows, config, .category);
    try html_groups(work.allocator(), w, rows, config, .account);
    try html_groups(work.allocator(), w, rows, config, .merchant);
    try w.writeAll("<h2>Recorded payments</h2><p>Forecast = salary − planned fixed − variable − special. Planned commitments are not actual payments.</p><table><thead><tr><th>Date</th><th>Payee</th><th>Account</th><th>Category</th><th>Notes</th><th>Amount</th></tr></thead><tbody>");
    for (rows) |row| {
        try w.writeAll("<tr>");
        for ([_][]const u8{ row.date, row.payee, try account_label(work.allocator(), row.account, config), row.category, row.notes }) |cell| {
            try w.writeAll("<td>");
            try html_text(w, cell);
            try w.writeAll("</td>");
        }
        try w.print("<td>{s}</td></tr>", .{try amount_text(&money_buf, row.amount, row.currency)});
    }
    try w.writeAll("</tbody></table></html>");
    return out.toOwnedSlice();
}

test "USD payments stay out of the CLP budget and print in dollars" {
    const rows = [_]model.Expense{
        .{ .id = "", .date = "2026-09-14", .amount = 53970, .payee = "Market" },
        .{ .id = "", .date = "2026-09-14", .amount = 4663, .currency = "USD", .payee = "Visa interest" },
    };
    const t = totals(&rows, .{});
    try std.testing.expectEqual(@as(i64, 53970), t.actual);
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("US$46.63", try amount_text(&buf, 4663, "USD"));
    try std.testing.expectEqualStrings("US$1,234,567.05", try amount_text(&buf, 123456705, "USD"));
    try std.testing.expectEqualStrings("$53.970", try amount_text(&buf, 53970, "CLP"));
}

test "report export escapes merchant markup and keeps exact integer totals" {
    const rows = [_]model.Expense{.{ .id = "", .date = "2026-10-17", .amount = 1000000000000, .payee = "<script>&\"" }};
    const html = try html_report(std.testing.allocator, &rows, .{});
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;&amp;&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "$1.000.000.000.000") != null);
}

test "merchant fallback matches Spanish Unicode lowercasing and ASCII initials" {
    const a = std.testing.allocator;
    const name = try merchant(a, "MERCADOPAGO * CAFÉ SEÑORA", .{}, true);
    defer a.free(name);
    try std.testing.expectEqualStrings("Café SeñOra", name);
    try std.testing.expectEqualStrings("Tottus", try merchant(a, "TOTTUS 123", .{}, true));
}

test "historical special payments are classified outside Other without changing the ledger" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try std.json.parseFromSliceLeaky(Settings, a, "{\"special_cases\":{\"TRASPASO A DEUDA NACIONAL\":\"USD purchases converted to CLP\"}}", .{});
    const row: model.Expense = .{ .id = "", .date = "2026-09-09", .payee = "Traspaso A Deuda Nacional", .amount = 232466, .category = "Other" };
    const other: Filter = .{ .month = "2026-09", .category = "Other" };
    const special_filter: Filter = .{ .month = "2026-09", .category = "Special: USD purchases converted to CLP" };
    try std.testing.expect(!other.matches(row, config));
    try std.testing.expect(special_filter.matches(row, config));
    try std.testing.expect(!uncategorized(row, config));
    try std.testing.expectEqualStrings("Special: USD purchases converted to CLP", try category_name(a, row, config));
    try std.testing.expectEqualStrings("Other", row.category);
}
