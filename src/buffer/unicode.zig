// WIZP Unicode utilities — UTF-8 codepoint navigation
// Without this, cursor position breaks on any non-ASCII text.

const std = @import("std");

/// Decoded codepoint with its UTF-8 byte length
pub const Codepoint = struct { cp: u21, len: u3 };

/// Returns the byte width of a UTF-8 codepoint given its first byte.
/// Returns 1 for continuation bytes and invalid bytes.
pub fn codepointWidth(first_byte: u8) u3 {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xC0) return 1; // continuation byte, treat as 1
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}

/// Get the next codepoint from `text` starting at `offset`.
pub fn nextCodepoint(text: []const u8, offset: usize) ?Codepoint {
    if (offset >= text.len) return null;
    const len = codepointWidth(text[offset]);
    if (offset + len > text.len) return null;
    var cp: u21 = 0;
    switch (len) {
        1 => cp = text[offset],
        2 => cp = (@as(u21, text[offset] & 0x1F) << 6) | @as(u21, text[offset + 1] & 0x3F),
        3 => cp = (@as(u21, text[offset] & 0x0F) << 12) | (@as(u21, text[offset + 1] & 0x3F) << 6) | @as(u21, text[offset + 2] & 0x3F),
        4 => cp = (@as(u21, text[offset] & 0x07) << 18) | (@as(u21, text[offset + 1] & 0x3F) << 12) | (@as(u21, text[offset + 2] & 0x3F) << 6) | @as(u21, text[offset + 3] & 0x3F),
        else => return null,
    }
    return .{ .cp = cp, .len = len };
}

/// Get the previous codepoint before `offset` in `text`.
pub fn prevCodepoint(text: []const u8, offset: usize) ?Codepoint {
    if (offset == 0) return null;
    var pos = offset - 1;
    while (pos > 0 and (text[pos] & 0xC0) == 0x80) {
        pos -= 1;
    }
    const len = codepointWidth(text[pos]);
    if (pos + len > text.len) return null;
    return nextCodepoint(text, pos);
}

/// Count the number of codepoints in `text`.
pub fn codepointCount(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        i += codepointWidth(text[i]);
        count += 1;
    }
    return count;
}

/// Convert a byte offset to a codepoint offset.
pub fn byteToCodepointOffset(text: []const u8, byte_offset: usize) usize {
    var cp_offset: usize = 0;
    var i: usize = 0;
    while (i < @min(byte_offset, text.len)) {
        i += codepointWidth(text[i]);
        cp_offset += 1;
    }
    return cp_offset;
}

/// Convert a codepoint offset to a byte offset.
pub fn codepointToByteOffset(text: []const u8, cp_offset: usize) usize {
    var byte_offset: usize = 0;
    var count: usize = 0;
    while (byte_offset < text.len and count < cp_offset) {
        byte_offset += codepointWidth(text[byte_offset]);
        count += 1;
    }
    return byte_offset;
}

/// Check if a byte position is on a valid codepoint boundary.
pub fn isCodepointBoundary(text: []const u8, offset: usize) bool {
    if (offset >= text.len) return true;
    return (text[offset] & 0xC0) != 0x80;
}

test "codepointWidth: ASCII" {
    try std.testing.expectEqual(@as(u3, 1), codepointWidth('A'));
    try std.testing.expectEqual(@as(u3, 1), codepointWidth('z'));
}

test "codepointWidth: multibyte" {
    try std.testing.expectEqual(@as(u3, 2), codepointWidth(0xC3)); // é
    try std.testing.expectEqual(@as(u3, 3), codepointWidth(0xE2)); // €
    try std.testing.expectEqual(@as(u3, 4), codepointWidth(0xF0)); // 🚀
}

test "nextCodepoint: ASCII" {
    const result = nextCodepoint("ABC", 0).?;
    try std.testing.expectEqual(@as(u21, 'A'), result.cp);
    try std.testing.expectEqual(@as(u3, 1), result.len);
}

test "nextCodepoint: multibyte" {
    const result = nextCodepoint("ébc", 0).?;
    try std.testing.expectEqual(@as(u21, 0xE9), result.cp);
    try std.testing.expectEqual(@as(u3, 2), result.len);
}

test "codepointCount: mixed" {
    try std.testing.expectEqual(@as(usize, 5), codepointCount("héllo"));
    try std.testing.expectEqual(@as(usize, 6), codepointCount("🚀hello"));
}

test "codepointCount: ASCII" {
    try std.testing.expectEqual(@as(usize, 5), codepointCount("hello"));
}

test "byteToCodepointOffset" {
    // "héllo" = h(1) + é(2) + llo(3) = 6 bytes, 5 codepoints
    try std.testing.expectEqual(@as(usize, 2), byteToCodepointOffset("héllo", 3)); // after "hé"
}

test "isCodepointBoundary" {
    try std.testing.expect(isCodepointBoundary("héllo", 0)); // 'h'
    try std.testing.expect(isCodepointBoundary("héllo", 1)); // start of 'é'
    try std.testing.expect(!isCodepointBoundary("héllo", 2)); // continuation of 'é'
    try std.testing.expect(isCodepointBoundary("héllo", 3)); // 'l'
}
