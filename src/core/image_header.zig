//! Reject oversized PNG/JPEG dimensions before a decoder allocates pixels.
const std = @import("std");
fn dimensions(width: u32, height: u32) !void {
    if (width == 0 or height == 0) return error.InvalidImage;
    if (@as(u64, width) * height > 16_000_000) return error.ImageTooLarge;
}
pub fn validate(image: []const u8) !void {
    if (image.len > 8 * 1024 * 1024) return error.ImageTooLarge;
    if (std.mem.startsWith(u8, image, "\x89PNG\r\n\x1a\n")) {
        if (image.len < 24 or std.mem.readInt(u32, image[8..12], .big) != 13 or !std.mem.eql(u8, image[12..16], "IHDR")) return error.InvalidImage;
        return dimensions(std.mem.readInt(u32, image[16..20], .big), std.mem.readInt(u32, image[20..24], .big));
    }
    if (!std.mem.startsWith(u8, image, "\xff\xd8")) return error.UnsupportedImage;
    var offset: usize = 2;
    while (offset < image.len) {
        if (image[offset] != 0xff) return error.InvalidImage;
        while (offset < image.len and image[offset] == 0xff) : (offset += 1) {}
        if (offset == image.len) return error.InvalidImage;
        const marker = image[offset];
        offset += 1;
        if (marker == 0xd9 or marker == 0xda or marker == 0) return error.InvalidImage;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
        if (image.len - offset < 2) return error.InvalidImage;
        const length = std.mem.readInt(u16, image[offset..][0..2], .big);
        if (length < 2 or length > image.len - offset) return error.InvalidImage;
        if (marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc) {
            if (length < 8) return error.InvalidImage;
            return dimensions(std.mem.readInt(u16, image[offset + 5 ..][0..2], .big), std.mem.readInt(u16, image[offset + 3 ..][0..2], .big));
        }
        offset += length;
    }
    return error.InvalidImage;
}
test "image bombs are rejected from headers before decoding" {
    try std.testing.expectError(error.ImageTooLarge, validate("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x7f\xff\xff\xff\x7f\xff\xff\xff"));
    try std.testing.expectError(error.ImageTooLarge, validate("\xff\xd8\xff\xc0\x00\x08\x08\xff\xff\xff\xff\x00"));
    try validate("\xff\xd8\xff\xc2\x00\x08\x08\x00\x10\x00\x10\x00");
    try std.testing.expectError(error.InvalidImage, validate("\xff\xd8\xff\xe0\xff\xff"));
}
