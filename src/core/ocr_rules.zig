//! Fast scans: payment fields from text the platform's OCR read, with no
//! language model. Lines are grouped into rows by position (a label and its
//! right-aligned value become one row), then simple rules find the total,
//! date, payee and reference of a Chilean receipt or transfer voucher.
//! `complete` tells the caller whether to trust it or fall back to a model.
const std = @import("std");
const model = @import("model.zig");
const scanning = @import("scanning.zig");

pub const Line = struct { text: []const u8, left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
pub const Result = struct { extraction: scanning.Extraction, complete: bool };

const max_lines = 400;
const max_row_bytes = 512;

/// Rows in reading order: lines whose vertical extents overlap by half the
/// smaller height share a row, joined left to right.
pub fn rows(arena: std.mem.Allocator, input: []const Line) ![]const []const u8 {
    const lines = try arena.dupe(Line, input[0..@min(input.len, max_lines)]);
    std.mem.sort(Line, lines, {}, struct {
        fn less(_: void, a: Line, b: Line) bool {
            return a.top + a.bottom < b.top + b.bottom;
        }
    }.less);
    var out: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < lines.len) {
        var end = index + 1;
        var top = lines[index].top;
        var bottom = lines[index].bottom;
        while (end < lines.len and sameRow(top, bottom, lines[end])) : (end += 1) {
            top = @min(top, lines[end].top);
            bottom = @max(bottom, lines[end].bottom);
        }
        const row = lines[index..end];
        std.mem.sort(Line, row, {}, struct {
            fn less(_: void, a: Line, b: Line) bool {
                return a.left < b.left;
            }
        }.less);
        var text: std.ArrayList(u8) = .empty;
        for (row, 0..) |line, i| {
            if (i > 0) try text.append(arena, ' ');
            try text.appendSlice(arena, std.mem.trim(u8, line.text, " \t"));
        }
        try out.append(arena, text.items[0..@min(text.items.len, max_row_bytes)]);
        index = end;
    }
    return out.toOwnedSlice(arena);
}

fn sameRow(top: i32, bottom: i32, line: Line) bool {
    const overlap = @min(bottom, line.bottom) - @max(top, line.top);
    const height = @min(bottom - top, line.bottom - line.top);
    return height > 0 and overlap * 2 >= height;
}

pub fn extract(arena: std.mem.Allocator, text_rows: []const []const u8) !Result {
    var value: scanning.Extraction = .{};
    const lower = try arena.alloc([]const u8, text_rows.len);
    for (text_rows, lower) |row, *slot| slot.* = try std.ascii.allocLowerString(arena, row);
    value.amount = total(text_rows, lower);
    for (text_rows) |row| if (value.date.len == 0) {
        value.date = try findDate(arena, row);
        if (value.date.len > 0) value.time = try findTime(arena, row);
    };
    for (text_rows) |row| if (value.time.len == 0) {
        value.time = try findTime(arena, row);
    };
    const transfer = anyContains(lower, &.{ "transfer", "destinatario", "beneficiario" });
    value.kind = if (transfer) "transfer" else "receipt";
    value.payee = (if (transfer) labelled(text_rows, lower, &.{ "destinatario", "beneficiario", "para", "nombre" }) else null) orelse
        (try appPayee(arena, text_rows, lower)) orelse (try business(arena, text_rows, lower)) orelse "";
    value.reference = reference(text_rows, lower);
    if (!transfer) value.location = try location(arena, text_rows, lower);
    if (transfer) value.bank = bank(lower);
    return .{ .extraction = value, .complete = value.amount > 0 and value.date.len > 0 and value.payee.len > 0 };
}

// --- Amount -------------------------------------------------------------

/// Prefer an explicit final total, including a value split onto the next row.
/// Without one, only accept an unambiguous amount and no tax/discount breakdown.
/// A receipt's largest value is often its subtotal before discounts.
fn total(text_rows: []const []const u8, lower: []const []const u8) i64 {
    var found: i64 = 0;
    for (lower, 0..) |row, index| {
        const label = std.mem.trimStart(u8, row, " :*");
        const is_total = (startsWithAny(label, &.{ "total", "monto", "importe", "valor pagado" }) or contains(label, "total pagado")) and
            !amountComponent(label) and !containsAny(label, &.{ "items", "artículos" });
        if (!is_total) continue;
        // "Total : 489.981": a total's own row may print it without the sign.
        if (money(text_rows[index]) orelse labelAmount(text_rows[index])) |amount| {
            found = amount;
            continue;
        }
        for (index + 1..@min(index + 3, text_rows.len)) |next| {
            if (amountComponent(lower[next])) break;
            if (money(text_rows[next]) orelse standaloneAmount(text_rows[next])) |amount| {
                found = amount;
                break;
            }
            // Do not borrow another field's value when this total is unreadable.
            if (letters(text_rows[next]) >= 3) break;
        }
    }
    if (found > 0) return found;
    for (lower) |row| if (amountComponent(row)) return 0;
    for (text_rows, lower) |row, row_lower| {
        if (containsAny(row_lower, &.{ "saldo", "disponible", "cupo" })) continue;
        if (money(row)) |amount| {
            if (found > 0 and found != amount) return 0;
            found = amount;
        }
    }
    return found;
}

fn amountComponent(row: []const u8) bool {
    return containsAny(row, &.{ "subtotal", "sub total", "sub-total", "descuento", "discount", "neto", "iva", "i.v.a", "exento", "propina", "vuelto" });
}

/// Only a bare amount may follow a detached TOTAL label, never a reference.
fn standaloneAmount(row: []const u8) ?i64 {
    const value = std.mem.trim(u8, row, " \t$S:*");
    if (value.len == 0) return null;
    for (value) |ch| if (digit(ch) == null and ch != '.' and ch != ',') return null;
    return labelAmount(value);
}

fn negativePrefix(row: []const u8, before: usize) bool {
    const prefix = std.mem.trimEnd(u8, row[0..before], " \t$S");
    return std.mem.endsWith(u8, prefix, "-") or std.mem.endsWith(u8, prefix, "−");
}

/// "$ 53.970", "$40.000 CLP", "$1.234,00": whole pesos after a dollar sign.
/// OCR misreads are tolerated: "S 53.970" for the sign, "53.97O" for a zero.
fn money(row: []const u8) ?i64 {
    // App receipts print an explicit currency code instead of a peso sign.
    if (std.ascii.indexOfIgnoreCase(row, "CLP")) |at| {
        if ((at == 0 or !std.ascii.isAlphanumeric(row[at - 1])) and
            (at + 3 == row.len or !std.ascii.isAlphabetic(row[at + 3])))
        {
            const amount = std.mem.trimStart(u8, row[at + 3 ..], " :");
            if (amount.len > 0 and std.ascii.isDigit(amount[0])) return labelAmount(amount);
        }
    }
    for (row, 0..) |sign, at| {
        if (!isSign(row, at, sign) or negativePrefix(row, at)) continue;
        var i = at + 1;
        while (i < row.len and row[i] == ' ') i += 1;
        if (i >= row.len or !std.ascii.isDigit(row[i])) continue;
        var amount: i64 = 0;
        while (i < row.len) : (i += 1) {
            const ch = row[i];
            if (digit(ch)) |value| {
                amount = std.math.mul(i64, amount, 10) catch return null;
                amount += value;
            } else if (ch == '.' or ch == ',') {
                // Thousands separator only when exactly three digits follow; two are cents.
                if (digitRun(row[i + 1 ..]) != 3) break;
            } else break;
        }
        if (amount > 0 and amount <= 1_000_000_000_000) return amount;
    }
    return null;
}

/// The amount after a total label with no peso sign ("Total : 489.981"):
/// the first number after the label, its thousands grouped by dots or
/// commas, or three digits or more.
fn labelAmount(row: []const u8) ?i64 {
    var i: usize = 0;
    while (i < row.len and !std.ascii.isDigit(row[i])) i += 1;
    if (i == row.len or negativePrefix(row, i)) return null;
    var amount: i64 = 0;
    var digits: usize = 0;
    var grouped = false;
    while (i < row.len) : (i += 1) {
        const ch = row[i];
        if (std.ascii.isDigit(ch)) {
            amount = std.math.mul(i64, amount, 10) catch return null;
            amount += ch - '0';
            digits += 1;
        } else if ((ch == '.' or ch == ',') and digitRun(row[i + 1 ..]) == 3) {
            grouped = true;
        } else break;
    }
    // "(19%)", an item count or a percentage isn't a total.
    if (i < row.len and row[i] == '%') return null;
    if (!grouped and digits < 3) return null;
    return if (amount > 0 and amount <= 1_000_000_000_000) amount else null;
}

/// "$", or an "S" standing alone before the digits ("S 19.990", not "US$").
fn isSign(row: []const u8, at: usize, ch: u8) bool {
    if (ch == '$') return true;
    if (ch != 'S') return false;
    return at == 0 or !std.ascii.isAlphanumeric(row[at - 1]);
}

/// A digit inside an amount, where OCR reads a zero as the letter O.
fn digit(ch: u8) ?u8 {
    if (std.ascii.isDigit(ch)) return ch - '0';
    if (ch == 'O' or ch == 'o') return 0;
    return null;
}

fn digitRun(text: []const u8) usize {
    var n: usize = 0;
    while (n < text.len and digit(text[n]) != null) n += 1;
    return n;
}

// --- Date and time --------------------------------------------------------

const months = [_][]const u8{ "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre" };
/// English abbreviations where they differ from the Spanish ones ("01-SEP-2026" is both).
const english_months = [_]struct { []const u8, u32 }{ .{ "jan", 1 }, .{ "apr", 4 }, .{ "aug", 8 }, .{ "dec", 12 } };

/// DD/MM/YYYY, DD-MM-YY, DD.MM.YYYY, YYYY-MM-DD, "14 de octubre de 2026"
/// or "01-SEP-2026".
fn findDate(arena: std.mem.Allocator, row: []const u8) ![]const u8 {
    var i: usize = 0;
    while (i < row.len) : (i += 1) {
        if (!std.ascii.isDigit(row[i]) or (i > 0 and std.ascii.isDigit(row[i - 1]))) continue;
        if (try numericDate(arena, row[i..])) |date| return date;
        if (try spanishDate(arena, row[i..])) |date| return date;
    }
    return "";
}

fn numericDate(arena: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var parts: [3]u32 = undefined;
    var widths: [3]usize = undefined;
    var at: usize = 0;
    var separator: u8 = 0;
    for (0..3) |n| {
        const run = digitRun(text[at..]);
        if (run == 0 or run > 4) return null;
        parts[n] = std.fmt.parseInt(u32, text[at .. at + run], 10) catch return null;
        widths[n] = run;
        at += run;
        if (n == 2) break;
        // OCR separates punctuation from its digits ("17-10- 2026").
        // Only allow spacing around separators, never within a number.
        while (at < text.len and (text[at] == ' ' or text[at] == '\t')) at += 1;
        if (at >= text.len or !(text[at] == '/' or text[at] == '-' or text[at] == '.')) return null;
        if (separator == 0) separator = text[at] else if (text[at] != separator) return null;
        at += 1;
        while (at < text.len and (text[at] == ' ' or text[at] == '\t')) at += 1;
    }
    if (at < text.len and std.ascii.isDigit(text[at])) return null;
    // Preserve Chilean day-first dates when ambiguous. A second component
    // above 12 unambiguously identifies a US month-first app receipt.
    const month_first = widths[0] != 4 and parts[0] >= 1 and parts[0] <= 12 and parts[1] > 12;
    const year, const month, const day = if (widths[0] == 4)
        .{ parts[0], parts[1], parts[2] }
    else if (widths[2] == 4 or widths[2] == 2)
        .{ if (widths[2] == 2) parts[2] + 2000 else parts[2], if (month_first) parts[0] else parts[1], if (month_first) parts[1] else parts[0] }
    else
        return null;
    return validDate(arena, year, month, day);
}

fn spanishDate(arena: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const day_len = digitRun(text);
    if (day_len == 0 or day_len > 2) return null;
    const day = std.fmt.parseInt(u32, text[0..day_len], 10) catch return null;
    var rest = std.mem.trimStart(u8, text[day_len..], " -/.");
    if (rest.len >= 3 and std.ascii.eqlIgnoreCase(rest[0..3], "de ")) rest = rest[3..];
    if (rest.len < 3) return null;
    const month: u32 = for (months, 1..) |name, number| {
        if (std.ascii.eqlIgnoreCase(rest[0..3], name[0..3])) break @intCast(number);
    } else for (english_months) |entry| {
        if (std.ascii.eqlIgnoreCase(rest[0..3], entry[0])) break entry[1];
    } else return null;
    var after = rest[3..];
    while (after.len > 0 and std.ascii.isAlphabetic(after[0])) after = after[1..];
    after = std.mem.trimStart(u8, after, " .,-/");
    if (after.len >= 3 and std.ascii.eqlIgnoreCase(after[0..3], "de ")) after = after[3..];
    if (digitRun(after) != 4 or (after.len > 4 and std.ascii.isDigit(after[4]))) return null;
    const year = std.fmt.parseInt(u32, after[0..4], 10) catch return null;
    return validDate(arena, year, month, day);
}

fn validDate(arena: std.mem.Allocator, year: u32, month: u32, day: u32) !?[]const u8 {
    if (year > 9999 or month > 99 or day > 99) return null;
    const iso = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
    return if (model.valid_date(iso)) iso else null;
}

/// Prefer the time beside the receipt date over a screenshot's status clock.
fn findTime(arena: std.mem.Allocator, row: []const u8) ![]const u8 {
    var i: usize = 0;
    while (i + 4 <= row.len) : (i += 1) {
        if (!std.ascii.isDigit(row[i]) or (i > 0 and std.ascii.isDigit(row[i - 1]))) continue;
        const width = digitRun(row[i..]);
        if (width < 1 or width > 2) continue;
        const colon = i + width;
        if (colon + 3 > row.len or row[colon] != ':' or !std.ascii.isDigit(row[colon + 1]) or !std.ascii.isDigit(row[colon + 2])) continue;
        if (colon + 3 < row.len and std.ascii.isDigit(row[colon + 3])) continue;
        var hour = std.fmt.parseInt(u8, row[i..colon], 10) catch continue;
        const minute = try std.fmt.parseInt(u8, row[colon + 1 .. colon + 3], 10);
        if (hour >= 24 or minute >= 60) continue;
        const suffix = std.mem.trimStart(u8, row[colon + 3 ..], " ");
        if (suffix.len >= 2 and (std.ascii.eqlIgnoreCase(suffix[0..2], "AM") or std.ascii.eqlIgnoreCase(suffix[0..2], "PM")) and
            (suffix.len == 2 or !std.ascii.isAlphabetic(suffix[2])))
        {
            if (hour < 1 or hour > 12) continue;
            hour = hour % 12 + @as(u8, if (std.ascii.toLower(suffix[0]) == 'p') 12 else 0);
        }
        return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}", .{ hour, minute });
    }
    return "";
}

// --- Payee, reference, bank ----------------------------------------------

/// "Destinatario: Johana", or the label alone with the name on the next row.
fn labelled(text_rows: []const []const u8, lower: []const []const u8, labels: []const []const u8) ?[]const u8 {
    for (lower, 0..) |row, index| {
        const trimmed = std.mem.trimStart(u8, row, " ");
        for (labels) |label| {
            if (!std.mem.startsWith(u8, trimmed, label)) continue;
            const after = trimmed[label.len..];
            if (after.len > 0 and std.ascii.isAlphabetic(after[0])) continue;
            const offset = text_rows[index].len - trimmed.len + label.len;
            const value = std.mem.trim(u8, text_rows[index][offset..], " :.-");
            if (letters(value) >= 3) return value;
            if (index + 1 < text_rows.len and letters(text_rows[index + 1]) >= 3) return std.mem.trim(u8, text_rows[index + 1], " :");
        }
    }
    return null;
}

/// A receipt's business: a name near the top, excluding document labels.
/// Mixed-case headers need the stronger evidence of a tax ID just below.
fn business(arena: std.mem.Allocator, text_rows: []const []const u8, lower: []const []const u8) !?[]const u8 {
    const banned = [_][]const u8{ "rut", "boleta", "factura", "electr", "s.i.i", "sii", "timbre", "giro", "direcc", "comuna", "ciudad", "fono", "vendedor", "fecha", "sucursal", "matriz", "total", "www", "http", "cajero", "caja", "ticket" };
    const top = @min(text_rows.len, 12);
    for (text_rows[0..top], lower[0..top], 0..) |row, row_lower, index| {
        const above_rut = index + 1 < text_rows.len and isRut(text_rows[index + 1]);
        if (!isName(row, row_lower, &banned, above_rut)) continue;
        // "ANDREA CAROLINA ACOSTA GODOY," continued by "IMPORTADORA Y ...".
        const trimmed = std.mem.trimEnd(u8, row, " ");
        if (std.mem.endsWith(u8, trimmed, ",") and index + 1 < text_rows.len and isName(text_rows[index + 1], lower[index + 1], &banned, false)) {
            return try std.fmt.allocPrint(arena, "{s} {s}", .{ trimmed, std.mem.trim(u8, text_rows[index + 1], " ,.") });
        }
        return withoutFolio(std.mem.trim(u8, row, " ,."));
    }
    return null;
}

/// A header name without the document number printed beside it
/// ("LG ELECTRONICS INC, CHILE LTDA N° 0179829").
fn withoutFolio(name: []const u8) []const u8 {
    for ([_][]const u8{ " N°", " Nº", " N.", " N " }) |mark| if (std.mem.indexOf(u8, name, mark)) |at| {
        const rest = std.mem.trimStart(u8, name[at + mark.len ..], " .:#");
        if (rest.len > 0 and std.ascii.isDigit(rest[0])) return std.mem.trim(u8, name[0..at], " ,.");
    };
    return name;
}

/// Payment apps' receipts ("Compra en" over "GTD MANQUEHUE SA" in Onepay,
/// "Pagaste a", "Comercio: …"): the label ending its row with the name on
/// the next one, or the name after the label's colon. OCR's "rn" and "rm"
/// for "m" ("Cormpra en") and a logo's letters before the label are allowed.
fn appPayee(arena: std.mem.Allocator, text_rows: []const []const u8, lower: []const []const u8) !?[]const u8 {
    if (receiptPayee(text_rows, lower)) |name| return name;
    const labels = [_][]const u8{ "compra en", "compraste en", "pagaste a", "pago a", "pago en", "pagado a", "comercio" };
    for (lower, 0..) |row, index| {
        const plain = try mergeMisreadM(arena, std.mem.trim(u8, row, " "));
        for (labels) |label| {
            if (std.mem.endsWith(u8, std.mem.trimEnd(u8, plain, " :"), label)) {
                if (index + 1 >= text_rows.len) continue;
                const next = std.mem.trim(u8, text_rows[index + 1], " :.,");
                if (letters(next) >= 3 and std.mem.indexOfScalar(u8, next, '$') == null) return next;
                continue;
            }
            // "Comercio: GTD MANQUEHUE": the original row's text after its colon.
            if (std.mem.indexOf(u8, plain, label)) |at| {
                const tail = std.mem.trimStart(u8, plain[at + label.len ..], " ");
                if (tail.len == 0 or tail[0] != ':') continue;
                const colon = std.mem.indexOfScalar(u8, text_rows[index], ':') orelse continue;
                const value = std.mem.trim(u8, text_rows[index][colon + 1 ..], " .,");
                if (letters(value) >= 3 and std.mem.indexOfScalar(u8, value, '$') == null) return value;
            }
        }
    }
    return null;
}

/// Delivery-app receipts explicitly name the merchant after this phrase.
/// The name may be on the same OCR row or immediately below it.
fn receiptPayee(text_rows: []const []const u8, lower: []const []const u8) ?[]const u8 {
    const labels = [_][]const u8{ "here's your receipt for", "here’s your receipt for" };
    for (lower, 0..) |row, index| for (labels) |label| {
        const trimmed = std.mem.trimStart(u8, row, " ");
        if (!std.mem.startsWith(u8, trimmed, label)) continue;
        if (trimmed.len > label.len and std.ascii.isAlphabetic(trimmed[label.len])) continue;
        const offset = row.len - trimmed.len + label.len;
        var name = merchantText(text_rows[index][offset..]);
        if (name.len == 0 and index + 1 < text_rows.len) name = merchantText(text_rows[index + 1]);
        // Do not mistake totals or other receipt sections for a missing name.
        if (letters(name) < 3 or money(name) != null or std.ascii.eqlIgnoreCase(name, "total") or std.ascii.eqlIgnoreCase(name, "payments")) continue;
        return name;
    };
    return null;
}

fn merchantText(text: []const u8) []const u8 {
    var name = std.mem.trim(u8, text, " :.,");
    // A merchant logo emoji is decoration, not part of the merchant name.
    while (name.len > 0) {
        const width = std.unicode.utf8ByteSequenceLength(name[0]) catch break;
        if (width > name.len) break;
        const codepoint = std.unicode.utf8Decode(name[0..width]) catch break;
        if (!(codepoint >= 0x1f300 and codepoint <= 0x1faff) and codepoint != 0xfe0f and codepoint != 0x200d) break;
        name = std.mem.trimStart(u8, name[width..], " ");
    }
    // The branch street address may share the merchant's OCR row.
    if (std.mem.indexOf(u8, name, " (")) |at| name = name[0..at];
    return std.mem.trim(u8, name, " :.,");
}

/// `text` with "rn" and "rm" read as the "m" OCR split ("cormpra" → "compra").
fn mergeMisreadM(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (i + 1 < text.len and text[i] == 'r' and (text[i + 1] == 'n' or text[i + 1] == 'm')) {
            try out.append(arena, 'm');
            i += 1;
        } else try out.append(arena, text[i]);
    }
    return out.items;
}

/// A standalone Chilean tax ID, optionally prefixed by RUT. Its shape is
/// evidence of a merchant header; this does not validate an identity.
fn isRut(row: []const u8) bool {
    var text = std.mem.trim(u8, row, " ");
    if (text.len >= 3 and std.ascii.eqlIgnoreCase(text[0..3], "rut")) text = std.mem.trimStart(u8, text[3..], " :.");
    var digits: usize = 0;
    for (text, 0..) |ch, i| {
        if (std.ascii.isDigit(ch)) {
            digits += 1;
        } else if (ch == '-') {
            if (digits < 7 or digits > 8 or i + 2 != text.len) return false;
            const check = text[i + 1];
            return std.ascii.isDigit(check) or check == 'k' or check == 'K';
        } else if (ch != '.' and ch != ' ') return false;
    }
    return false;
}

/// A mostly upper-case line of at least two words that isn't a document label.
fn isName(row: []const u8, row_lower: []const u8, banned: []const []const u8, above_rut: bool) bool {
    // A company's legal name may hold a banned word ("LG ELECTRONICS INC,
    // CHILE LTDA"): its legal form says it's the name, not a label.
    const company = containsAny(row_lower, &.{ "ltda", "limitada", " s.a", " spa", "e.i.r.l", "eirl" });
    for (banned) |word| if (contains(row_lower, word) and !(company and std.mem.eql(u8, word, "electr"))) return false;
    // A contextual mixed-case name must not be an address, phone, email or URL.
    const mixed_name = above_rut and std.mem.indexOfAny(u8, row, "0123456789@/:") == null;
    var upper: usize = 0;
    var lowercase: usize = 0;
    var words: usize = 0;
    var run: usize = 0;
    for (row) |ch| {
        if (std.ascii.isUpper(ch)) upper += 1;
        if (std.ascii.isLower(ch)) lowercase += 1;
        if (std.ascii.isAlphabetic(ch)) {
            run += 1;
        } else {
            if (run >= 3) words += 1;
            run = 0;
        }
    }
    if (run >= 3) words += 1;
    return words >= 2 and ((upper >= 6 and lowercase * 4 <= upper) or
        (mixed_name and upper >= 2 and upper + lowercase >= 6));
}

/// A receipt's street address: the "Sucursal" line (with a city printed on
/// the next line), else "Dirección" and "Ciudad".
fn location(arena: std.mem.Allocator, text_rows: []const []const u8, lower: []const []const u8) ![]const u8 {
    if (afterLabel(text_rows, lower, "sucursal")) |at| {
        const next = at.row + 1;
        if (next < text_rows.len and isPlace(text_rows[next])) return std.fmt.allocPrint(arena, "{s}, {s}", .{ at.value, std.mem.trim(u8, text_rows[next], " ,.") });
        return at.value;
    }
    const street = afterLabel(text_rows, lower, "direcc") orelse return "";
    const city = afterLabel(text_rows, lower, "ciudad") orelse return street.value;
    return std.fmt.allocPrint(arena, "{s}, {s}", .{ street.value, city.value });
}

/// The value on a row starting with `label`: after its colon when there is
/// one ("Direcc ón: AV. ..." still works), else after the label.
fn afterLabel(text_rows: []const []const u8, lower: []const []const u8, label: []const u8) ?struct { row: usize, value: []const u8 } {
    for (lower, 0..) |row, index| {
        const trimmed = std.mem.trimStart(u8, row, " ");
        if (!std.mem.startsWith(u8, trimmed, label)) continue;
        const original = text_rows[index][row.len - trimmed.len ..];
        const colon = std.mem.indexOfScalar(u8, original[0..@min(original.len, label.len + 6)], ':');
        const value = std.mem.trim(u8, original[if (colon) |c| c + 1 else label.len..], " :.-,");
        if (letters(value) >= 3) return .{ .row = index, .value = value };
    }
    return null;
}

/// A short place name alone on a line ("Santiago"), not a label or amount.
fn isPlace(row: []const u8) bool {
    const text = std.mem.trim(u8, row, " ,.");
    if (text.len == 0 or text.len > 30 or letters(text) < 3) return false;
    for (text) |ch| if (ch == ':' or ch == '$' or std.ascii.isDigit(ch)) return false;
    return true;
}

/// "N° 358685", "Folio: 123", "Operación: TEST-1": an identifier with a digit.
fn reference(text_rows: []const []const u8, lower: []const []const u8) []const u8 {
    const labels = [_][]const u8{ "n°", "nº", "n.", "folio", "operaci", "comprobante", "transacci", "código", "codigo", "n " };
    for (lower, 0..) |row, index| {
        for (labels) |label| {
            var start: usize = 0;
            while (std.mem.indexOfPos(u8, row, start, label)) |at| : (start = at + 1) {
                if (at > 0 and std.ascii.isAlphabetic(row[at - 1])) continue;
                var i = at + label.len;
                while (i < row.len and std.ascii.isAlphabetic(row[i])) i += 1; // "operación"
                while (i < row.len and (row[i] == ' ' or row[i] == ':' or row[i] == '#' or row[i] == 0xb0)) i += 1;
                const token = identifier(text_rows[index][i..]);
                if (token.len >= 4 and std.mem.indexOfAny(u8, token, "0123456789") != null) return token;
            }
        }
        // OCR often drops the degree sign: "N358685".
        const trimmed = std.mem.trim(u8, text_rows[index], " ");
        if (trimmed.len >= 5 and (trimmed[0] == 'N' or trimmed[0] == 'n') and digitRun(trimmed[1..]) + 1 == trimmed.len) return trimmed[1..];
    }
    return "";
}

fn identifier(text: []const u8) []const u8 {
    var n: usize = 0;
    while (n < text.len and n < 40 and (std.ascii.isAlphanumeric(text[n]) or text[n] == '-')) n += 1;
    return text[0..n];
}

fn bank(lower: []const []const u8) []const u8 {
    const banks = [_][2][]const u8{ .{ "bci", "Bci" }, .{ "santander", "Santander" }, .{ "bancoestado", "BancoEstado" }, .{ "banco estado", "BancoEstado" }, .{ "banco de chile", "Banco de Chile" }, .{ "itaú", "Itaú" }, .{ "itau", "Itaú" }, .{ "scotiabank", "Scotiabank" }, .{ "bice", "BICE" }, .{ "falabella", "Banco Falabella" }, .{ "security", "Security" }, .{ "mach", "MACH" }, .{ "tenpo", "Tenpo" }, .{ "mercado pago", "Mercado Pago" } };
    for (lower) |row| for (banks) |entry| if (contains(row, entry[0])) return entry[1];
    return "";
}

// --- Small helpers -------------------------------------------------------

fn letters(text: []const u8) usize {
    var n: usize = 0;
    for (text) |ch| if (std.ascii.isAlphabetic(ch)) {
        n += 1;
    };
    return n;
}
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}
fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (contains(haystack, needle)) return true;
    return false;
}
fn startsWithAny(text: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| if (std.mem.startsWith(u8, text, prefix)) return true;
    return false;
}
fn anyContains(rows_lower: []const []const u8, needles: []const []const u8) bool {
    for (rows_lower) |row| if (containsAny(row, needles)) return true;
    return false;
}

// --- Tests: the boleta and voucher as an OCR engine reads them -----------

const boleta = [_][]const u8{
    "RUT76.066.235-6",   "BOLETAELECTRONICA",                     "N358685",              "S..I.-NUNOA",                      "ANDREA CAROLINA ACOSTA GODOY",
    "Gito:",             "VENTA DEPRENDASDEVESTIR.ART.PARA BFPE", "RODADOSMUEBLES",       "Direccon: AV,PFDRODFVALDIVIA2924", "Cona NUNOA",
    "Ciudad: SANTIAGO",  "Vendedor: Jessica Nunez",               "Focha: 16/10/2026",    "Foma de Pago:IARJEIA CREDIIO",     "CANT. FM VAIOR U. DFS.",
    "Menis 5 19.990 50", "$23.990",                               "Total Pagado 553.970", "Total Exento: $0",                 "Vuelto: $0",
    "TOTAL: $53.970",    "Timbre Electronico S.l.1",
};

test "boleta fields from OCR rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), &boleta);
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(i64, 53970), result.extraction.amount);
    try std.testing.expectEqualStrings("2026-10-16", result.extraction.date);
    try std.testing.expectEqualStrings("ANDREA CAROLINA ACOSTA GODOY", result.extraction.payee);
    try std.testing.expectEqualStrings("358685", result.extraction.reference);
    try std.testing.expectEqualStrings("receipt", result.extraction.kind);
    try std.testing.expectEqualStrings("AV,PFDRODFVALDIVIA2924, SANTIAGO", result.extraction.location);
}

test "photo misreads: S for $, O for 0, a two-line business name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ML Kit rows from a phone photo of the same boleta.
    const photo = [_][]const u8{
        "RUT 76. 066. 235-6",                       "BOLETA ELE CTRONCA",
        "N°358685",
        "S.L.L. - NUNOA",                           "ANDREA CAROLINA ACOSTA GODOY,",
        "IMPORTADORA Y cOMERCIALIZADORA, E IR.",    "Colto: VENTA DE PRENDAS DE VESTIR, ART.PARA BEI",
        "RODADOS MUEBLES",
        "Direcc ón: AV, IPEDRO IDE VALDIVIA 2924",
        "Conta NUNOA",                              "Cludad: SANTIAGO",
        "Fono:",                                    "Vendedor: Jessica Nunez",
        "Focha: 16/10/2026",                        "toma de Pago: IARJE IA CREDIIO",
        "Sucursal Av Pedro de Valdivia 2924 Nunoa", "Santiago",
        "VALORU DEs SUSTOT",                        "1 Meais S 19.990 S0S199",
        "S23.99U",                                  "S9.0",
        "Total Pagado: S 53.97o",                   "Total Exento:",
        "Vuelto:",                                  "TOTAL: $53.97O",
    };
    const result = try extract(arena.allocator(), &photo);
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(i64, 53970), result.extraction.amount);
    try std.testing.expectEqualStrings("2026-10-16", result.extraction.date);
    try std.testing.expectEqualStrings("ANDREA CAROLINA ACOSTA GODOY, IMPORTADORA Y cOMERCIALIZADORA, E IR", result.extraction.payee);
    try std.testing.expectEqualStrings("Av Pedro de Valdivia 2924 Nunoa, Santiago", result.extraction.location);
    try std.testing.expectEqual(@as(?i64, 19990), money("1 Meais S 19.990 S0S199"));
    try std.testing.expectEqual(@as(?i64, null), money("US 5 items"));
}

test "transfer voucher fields, label and value on separate rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const voucher = [_][]const u8{ "Bci", "Transferencia realizada", "Monto: $40.000 CLP", "Destinatario:", "Johana Castaneda", "Fecha: 14/10/2026", "Hora: 17:13", "Operacion: TEST-123456", "Saldo disponible $1.250.000" };
    const result = try extract(arena.allocator(), &voucher);
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(i64, 40000), result.extraction.amount);
    try std.testing.expectEqualStrings("2026-10-14", result.extraction.date);
    try std.testing.expectEqualStrings("17:13", result.extraction.time);
    try std.testing.expectEqualStrings("Johana Castaneda", result.extraction.payee);
    try std.testing.expectEqualStrings("TEST-123456", result.extraction.reference);
    try std.testing.expectEqualStrings("transfer", result.extraction.kind);
    try std.testing.expectEqualStrings("Bci", result.extraction.bank);
}

test "spanish dates, cents and incomplete text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2026-10-14", try findDate(a, "14 de octubre de 2026, 17:13"));
    try std.testing.expectEqualStrings("2026-10-09", try findDate(a, "Fecha 09-10-26"));
    try std.testing.expectEqualStrings("", try findDate(a, "Ref 31/02/2026"));
    try std.testing.expectEqual(@as(?i64, 40000), money("Monto $40.000,00"));
    try std.testing.expectEqual(@as(?i64, 1250000), money("$ 1.250.000"));
    const result = try extract(a, &.{ "Gracias por su compra", "$5.990" });
    try std.testing.expect(!result.complete);
}

test "lines become rows: label and right-aligned value join" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try rows(arena.allocator(), &.{
        .{ .text = "$53.970", .left = 400, .top = 102, .right = 480, .bottom = 120 },
        .{ .text = "TOTAL:", .left = 40, .top = 100, .right = 120, .bottom = 121 },
        .{ .text = "Vuelto:", .left = 40, .top = 70, .right = 120, .bottom = 90 },
    });
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("Vuelto:", out[0]);
    try std.testing.expectEqualStrings("TOTAL: $53.970", out[1]);
}

test "mixed-case merchant above a tax ID stays on the fast scan path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), &.{
        "Ciao Florentina",                 "76.886.315-6",                "Avenida Pocuro 3015",
        "Providencia, Chile",              "ciaoflorentina.com/",         "Recibo N: MRSA4A9P-9173",
        "Fecha: 17-10-2026 20:27:14 CLST", "Productos o servicios Monto", "1x Importe $67.640 A",
        "Subtotal $67.640",                "Propina $6.764",              "Total $74.404",
        "Mastercard $74.404",
    });
    try std.testing.expectEqualStrings("Ciao Florentina", result.extraction.payee);
    try std.testing.expectEqual(@as(i64, 74404), result.extraction.amount);
    try std.testing.expectEqualStrings("2026-10-17", result.extraction.date);
    try std.testing.expect(result.complete);
}

test "mixed-case merchant needs tax ID context and excludes contact details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "76.886.315-6", "RUT: 76.886.315-6", "76886315-6", "12.345.678-K" }) |rut| {
        try std.testing.expect(isRut(rut));
        try std.testing.expect((try extract(a, &.{ "Ciao Florentina", rut, "17-10-2026", "Total $74.404" })).complete);
    }
    for ([_][]const u8{ "74.404", "17-10-2026", "76.886.315-", "76.886.315-66", "abc" }) |text| try std.testing.expect(!isRut(text));
    for ([_][]const u8{ "Avenida Pocuro 3015", "Ciao@Florentina.com", "CiaoFlorentina.com/", "Fecha: Hoy", "Gracias por su compra" }) |header| {
        const result = try extract(a, &.{ header, "76.886.315-6", "17-10-2026", "Total $74.404" });
        try std.testing.expectEqualStrings("", result.extraction.payee);
        try std.testing.expect(!result.complete);
    }
    try std.testing.expect(!(try extract(a, &.{ "Ciao Florentina", "17-10-2026", "Total $74.404" })).complete);
}

test "actual Android OCR photo lines keep spaced dates on fast path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Unedited ML Kit text/boxes from the reported receipt photo. Keep only
    // the payment fields, excluding the contact and card details.
    const text_rows = try rows(a, &.{
        .{ .text = "CLao Forentina", .left = 270, .top = 240, .right = 591, .bottom = 293 },
        .{ .text = "76. 886.315-6", .left = 281, .top = 293, .right = 536, .bottom = 342 },
        .{ .text = "Fecha: 17-10- 2026 20: 27: 14 CLST", .left = 267, .top = 640, .right = 990, .bottom = 697 },
        .{ .text = "Total", .left = 284, .top = 1192, .right = 390, .bottom = 1228 },
        .{ .text = "$74.404", .left = 846, .top = 1189, .right = 1000, .bottom = 1229 },
    });
    const result = try extract(a, text_rows);
    try std.testing.expect(result.complete);
    try std.testing.expectEqualStrings("2026-10-17", result.extraction.date);
    try std.testing.expectEqual(@as(i64, 74404), result.extraction.amount);
    // Preserve what OCR actually read for review, never invent a correction.
    try std.testing.expectEqualStrings("CLao Forentina", result.extraction.payee);
}

test "date OCR spacing preserves calendar and numeric boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "17-10- 2026", "17 - 10 - 2026", "2026 - 10 - 17", "17 / 10 / 26", "17. 10. 2026" }) |text| {
        try std.testing.expectEqualStrings("2026-10-17", try findDate(a, text));
    }
    for ([_][]const u8{ "31 - 02 - 2026", "17 - 13 - 2026", "17 - 10 / 2026", "17 - 10 - 20260", "17 - 1 0 - 2026" }) |text| {
        try std.testing.expectEqualStrings("", try findDate(a, text));
    }
}

test "Onepay success screen: app label payee, amount, no printed date" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ML Kit on a POCO X3, from a screenshot of the app.
    const onepay = [_][]const u8{
        "Tu pago fue exitoso", "Monto $ 34.752", "gtd Cormpra en",
        "GTD MANQUEHUE SA",
        "El comprobante se mostrará en el comercio",
        "y puedes revisarlo en la sección Historial de",
        "Onepay",              "Ira Historial",  "Ir al inicio",
    };
    const result = try extract(arena.allocator(), &onepay);
    try std.testing.expectEqual(@as(i64, 34752), result.extraction.amount);
    try std.testing.expectEqualStrings("GTD MANQUEHUE SA", result.extraction.payee);
    // Not printed: the caller fills the photo's date (main.zig scanReceipt).
    try std.testing.expectEqualStrings("", result.extraction.date);
    try std.testing.expect(!result.complete);
}

test "LG boleta: abbreviated month, total without a sign, folio beside the name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ML Kit on a POCO X3, from the PDF boleta rendered to an image.
    const lg = [_][]const u8{
        "GLG BOLETA ELECTRÓNICA R.U.T.:76.014.61 0-2",
        "Life's Good",
        "LG ELECTRONICS ING, CHILE LTDA N° 0179829",
        "GIRO: IMPORTACION, EXPORTACIÓN Y COMERCIALIZACIÓN DE ARTÍCULOS ELÉCTRICOs Y",
        "GASA MATRIZ: ROSARIO NORTE N°407, PISO 10, LAS CONDES, SANTIAGO, CHILE S..I. - SANTIAGO ORIENTE",
        "FONO: 2941 9200- FAX: 2941 9201",
        "Razón Social One Time Costumer OBS LGECL N° Folio : 0179829 Emitido : 01-SEP-2026",
        "Ciudad Las Condes Numero Relac. OBS-B2C-S Pago",
        "Dirección Rosario Norte 407, piso 10",
        "Código Detalle Cantidad P. Unitario| Total",
        "WD14WVC4S6 Lavadora carga frontal 14 kg 400.833 400.833",
        "Documento Ref. Folio Fecha Razón Ref. Neto $ 411.749",
        "Orden De Compra ORDER 12300 14210 I.V.A. (19%) 78.232",
        "Total : 489.981|",
        "Timbre Electronico SII",
    };
    const result = try extract(arena.allocator(), &lg);
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(i64, 489981), result.extraction.amount);
    try std.testing.expectEqualStrings("2026-09-01", result.extraction.date);
    try std.testing.expectEqualStrings("LG ELECTRONICS ING, CHILE LTDA", result.extraction.payee);
    try std.testing.expectEqualStrings("0179829", result.extraction.reference);
}

test "abbreviated and English month dates; label amounts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2026-09-01", try findDate(a, "Emitido : 01-SEP-2026"));
    try std.testing.expectEqualStrings("2026-12-05", try findDate(a, "5 dic. 2026"));
    try std.testing.expectEqualStrings("2026-08-17", try findDate(a, "17 Aug 2026"));
    try std.testing.expectEqualStrings("", try findDate(a, "01-SEP-20261"));
    try std.testing.expectEqual(@as(?i64, 489981), labelAmount("Total : 489.981|"));
    try std.testing.expectEqual(@as(?i64, 5000), labelAmount("TOTAL 5000"));
    try std.testing.expectEqual(@as(?i64, null), labelAmount("Total items 3"));
    try std.testing.expectEqual(@as(?i64, null), labelAmount("Total IVA (19%)"));
}

test "discount receipt uses final total and never guesses the largest amount" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const breakdown = [_][]const u8{
        "SUPERMERCADO TOTTUS SA.", "18/10/26 14:49:12", "SUB TOTAL $435.670",
        "DESCUENTO -$52.065",      "NETO $322.357",     "IVA $61.248",
    };
    const printed = breakdown ++ [_][]const u8{ "TOTAL o$383.605", "TARJETA CREDITO $383.605", "TOTAL 383.605" };
    const result = try extract(a, &printed);
    try std.testing.expectEqual(@as(i64, 383605), result.extraction.amount);
    try std.testing.expect(result.complete);
    // A missing TOTAL must trigger fallback, not confidently return the subtotal.
    const missing = breakdown ++ [_][]const u8{"TARJETA CREDITO $383.605"};
    const uncertain = try extract(a, &missing);
    try std.testing.expectEqual(@as(i64, 0), uncertain.extraction.amount);
    try std.testing.expect(!uncertain.complete);
    const split = breakdown ++ [_][]const u8{ "TOTAL", "$", "383.605" };
    try std.testing.expectEqual(@as(i64, 383605), (try extract(a, &split)).extraction.amount);
    const unsafe = [_][]const u8{ "TOTAL", "DESCUENTO -$52.065", "$435.670" };
    try std.testing.expectEqual(@as(i64, 0), (try extract(a, &unsafe)).extraction.amount);
    const ambiguous = [_][]const u8{ "$435.670", "$383.605" };
    try std.testing.expectEqual(@as(i64, 0), (try extract(a, &ambiguous)).extraction.amount);
    try std.testing.expectEqual(@as(?i64, null), money("DESCUENTO -$52.065"));
    try std.testing.expectEqual(@as(?i64, null), labelAmount("TOTAL -$52.065"));
}

test "discount photo OCR boxes retain final payable amount" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Actual ML Kit boxes from the reported photo; payment fields only.
    const text_rows = try rows(a, &.{
        .{ .text = "SUB TOTAL", .left = 644, .top = 365, .right = 798, .bottom = 405 },
        .{ .text = "$435.670", .left = 983, .top = 343, .right = 1133, .bottom = 396 },
        .{ .text = "DESCUENTO", .left = 642, .top = 407, .right = 803, .bottom = 453 },
        .{ .text = "-$52.065", .left = 986, .top = 387, .right = 1132, .bottom = 443 },
        .{ .text = "SAASTOL NETOOMA $322.357", .left = 401, .top = 437, .right = 1130, .bottom = 505 },
        .{ .text = "IVA", .left = 647, .top = 504, .right = 696, .bottom = 541 },
        .{ .text = "aonsd $61.248", .left = 852, .top = 488, .right = 1126, .bottom = 551 },
        .{ .text = "TOTAL", .left = 645, .top = 548, .right = 732, .bottom = 586 },
        .{ .text = "o$383.605", .left = 924, .top = 532, .right = 1128, .bottom = 594 },
        .{ .text = "TARJETA CREDITO $383.605", .left = 648, .top = 616, .right = 1133, .bottom = 675 },
    });
    try std.testing.expectEqual(@as(i64, 383605), (try extract(a, text_rows)).extraction.amount);
}

test "Uber Eats pharmacy receipt uses final CLP total and US payment date" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const receipt = [_][]const u8{
        "9:49 Uber Eats",        "Receipt",                  "Thanks for",                            "ordering, Sergio",
        "Here's your receipt for 🏪Farmacias Ahumada",
        "(272 Av. Los Leones).", "Total CLP 16,147",         "3 Gesidol Infantil 100 mg/mL x 15 mL",
        "Solución Oral Para Gotas",
        "CLP 4,219/pc",          "Item Subtotal CLP 12,657", "Delivery Fee (VAT included) CLP 2,500", "Service Fee (VAT included) CLP 990",
        "Payments",
        "Mastercard ••••9526 CLP 16,147",
        "10/22/26 9:45 PM",
    };
    const result = try extract(arena.allocator(), &receipt);
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(i64, 16147), result.extraction.amount);
    try std.testing.expectEqualStrings("Farmacias Ahumada", result.extraction.payee);
    try std.testing.expectEqualStrings("2026-10-22", result.extraction.date);
    try std.testing.expectEqualStrings("21:45", result.extraction.time);
}

test "detached CLP total and receipt merchant label remain a quick scan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), &.{
        "Here's your receipt for",  "Farmacias Ahumada", "Total", "CLP 16,147",
        "Item Subtotal CLP 12,657", "10/22/26 9:45 PM",
    });
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(i64, 16147), result.extraction.amount);
    try std.testing.expectEqualStrings("Farmacias Ahumada", result.extraction.payee);
}

test "receipt dates preserve Chilean order and reject impossible US dates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2026-11-10", (try numericDate(a, "10/11/26")).?);
    try std.testing.expectEqualStrings("2026-10-22", (try numericDate(a, "22/10/26")).?);
    try std.testing.expectEqualStrings("2026-10-22", (try numericDate(a, "10/22/26")).?);
    try std.testing.expect((try numericDate(a, "10/32/26")) == null);
    try std.testing.expect((try numericDate(a, "02/30/26")) == null);
    try std.testing.expectEqualStrings("00:45", try findTime(a, "10/22/26 12:45 AM"));
    try std.testing.expectEqualStrings("12:45", try findTime(a, "10/22/26 12:45 PM"));
    try std.testing.expectEqualStrings("", try findTime(a, "1O:45"));
}

test "delivery receipt does not complete without merchant evidence or final total" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const missing_name = try extract(arena.allocator(), &.{
        "Here's your receipt for", "Total CLP 16,147", "10/22/26 9:45 PM",
    });
    try std.testing.expect(!missing_name.complete);
    const missing_total = try extract(arena.allocator(), &.{
        "Here’s your receipt for 🏪Farmacias Ahumada (272 Av. Los Leones).",
        "Item Subtotal CLP 12,657",
        "Delivery Fee CLP 2,500",
        "Service Fee CLP 990",
        "10/22/26 9:45 PM",
    });
    try std.testing.expect(!missing_total.complete);
    try std.testing.expectEqualStrings("Farmacias Ahumada", missing_total.extraction.payee);
    try std.testing.expectEqual(@as(i64, 0), missing_total.extraction.amount);
}
