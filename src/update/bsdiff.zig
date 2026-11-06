// WIZP bsdiff/bspatch — Binary diff algorithm for tiny updates
// Pattern from Electrobun: bsdiff-based update mechanism.
//
// bsdiff: produces a patch from old + new file
// bspatch: applies a patch to old file to produce new file
//
// Based on Colin Percival's bsdiff 4.3 algorithm.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Generate a patch between old_data and new_data.
/// Returns the patch data. Caller owns memory.
pub fn bsdiff(allocator: Allocator, old_data: []const u8, new_data: []const u8) ![]u8 {
    if (old_data.len == 0) {
        // No old data, patch is just the new data with a simple header
        var result = try allocator.alloc(u8, 32 + new_data.len);
        const header = "WIZPDIFF40";
        @memcpy(result[0..10], header);
        // len_new, len_old, len_ctrl, len_diff, len_extra
        writeI64(result[10..18], @intCast(new_data.len));
        writeI64(result[18..26], 0);
        writeI64(result[26..34], 0); // ctrl_len
        @memset(result[34..42], 0); // diff_len
        @memcpy(result[42..][0..new_data.len], new_data);
        return result;
    }

    // Build suffix array for old_data (simplified: use linear search for matches)
    // Full bsdiff uses divsufsort; we use a simpler O(n*m) approach for small files.

    var ctrl_data = std.array_list.Managed(u8).init(allocator);
    var diff_data = std.array_list.Managed(u8).init(allocator);
    var extra_data = std.array_list.Managed(u8).init(allocator);

    var scan: usize = 0;
    var last_scan: usize = 0;
    var last_pos: usize = 0;
    var last_offset: usize = 0;
    var len: usize = 0;

    while (scan < new_data.len) {
        var best_score: usize = 0;
        var best_pos: usize = 0;
        var best_len: usize = 0;
        var best_offset: usize = 0;

        // Search for matching region in old_data
        const search_len = @min(new_data.len - scan, old_data.len);
        var pos: usize = 0;
        while (pos < old_data.len) {
            len = 0;
            while (len < search_len and pos + len < old_data.len and new_data[scan + len] == old_data[pos + len]) {
                len += 1;
            }
            if (len > best_len) {
                best_len = len;
                best_pos = pos;
                best_offset = if (pos >= scan) pos - scan else scan - pos;
            }
            pos += @max(1, len / 2);
        }

        if (best_len >= 8) {
            // Found a match - emit ADD and INSERT
            var i: usize = 0;
            var s: usize = 0;
            var lenf: usize = 0;

            // diff data
            lenf = 0;
            i = 0;
            while (i < scan - last_scan) {
                if (last_scan + i + best_pos < scan + old_data.len) {
                    lenf += 1;
                }
                i += 1;
            }

            // ctrl: ADD length, INSERT length, offset
            const add_len = scan - last_scan;
            const insert_len = best_len;
            try appendI64(&ctrl_data, allocator, @intCast(add_len));
            try appendI64(&ctrl_data, allocator, @intCast(insert_len));
            try appendI64(&ctrl_data, allocator, @intCast(best_offset));

            // diff data (ADD)
            i = 0;
            while (i < add_len) {
                const diff_byte = if (last_scan + i < new_data.len and last_pos + i < old_data.len) new_data[last_scan + i] ^ old_data[last_pos + i] else 0;
                try diff_data.append(diff_byte);
                i += 1;
            }
            _ = s;
            _ = lenf;

            // extra data (INSERT)
            try extra_data.appendSlice(new_data[scan .. scan + best_len]);

            last_scan = scan + best_len;
            last_pos = best_pos + best_len;
            last_offset = best_offset;
            scan += best_len;
        } else {
            scan += 1;
        }
    }

    // Emit final ADD for remaining data
    if (last_scan < new_data.len) {
        const remaining = new_data.len - last_scan;
        try appendI64(&ctrl_data, allocator, @intCast(remaining));
        try appendI64(&ctrl_data, allocator, 0);
        try appendI64(&ctrl_data, allocator, 0);
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            try diff_data.append(new_data[last_scan + i]);
        }
    }

    // Build patch file
    const header_size = 42;
    const total_size = header_size + ctrl_data.items.len + diff_data.items.len + extra_data.items.len;
    var result = try allocator.alloc(u8, total_size);

    // Magic + version
    @memcpy(result[0..10], "WIZPDIFF40");

    // Lengths
    writeI64(result[10..18], @intCast(new_data.len));
    writeI64(result[18..26], @intCast(old_data.len));
    writeI64(result[26..34], @intCast(ctrl_data.items.len));
    writeI64(result[34..42], @intCast(diff_data.items.len));

    // Data blocks
    @memcpy(result[42..][0..ctrl_data.items.len], ctrl_data.items);
    @memcpy(result[42 + ctrl_data.items.len ..][0..diff_data.items.len], diff_data.items);
    @memcpy(result[42 + ctrl_data.items.len + diff_data.items.len ..][0..extra_data.items.len], extra_data.items);

    return result;
}

/// Apply a patch to old_data, producing new_data.
/// Caller owns returned memory.
pub fn bspatch(allocator: Allocator, old_data: []const u8, patch: []const u8) ![]u8 {
    if (patch.len < 42) return error.InvalidPatch;

    // Verify magic
    if (!std.mem.eql(u8, patch[0..10], "WIZPDIFF40")) return error.InvalidPatch;

    const new_size = readI64(patch[10..18]);
    const old_size = readI64(patch[18..26]);
    const ctrl_len = readI64(patch[26..34]);
    const diff_len = readI64(patch[34..42]);

    if (old_data.len != old_size) return error.SizeMismatch;

    const ctrl_data = patch[42..][0..@intCast(ctrl_len)];
    const diff_data = patch[42 + @as(usize, @intCast(ctrl_len)) ..][0..@intCast(diff_len)];
    const extra_data = patch[42 + @as(usize, @intCast(ctrl_len)) + @as(usize, @intCast(diff_len)) ..];

    var result = try allocator.alloc(u8, @intCast(new_size));
    errdefer allocator.free(result);

    var old_pos: usize = 0;
    var new_pos: usize = 0;
    var ctrl_off: usize = 0;
    var diff_off: usize = 0;
    var extra_off: usize = 0;

    while (new_pos < new_size) {
        if (ctrl_off + 24 > ctrl_data.len) break;

        const add_len = readI64(ctrl_data[ctrl_off..][0..8]);
        const insert_len = readI64(ctrl_data[ctrl_off + 8 ..][0..8]);
        const seek_offset = readI64(ctrl_data[ctrl_off + 16 ..][0..8]);
        ctrl_off += 24;

        // ADD: diff_data XOR old_data
        var i: usize = 0;
        while (i < add_len) : (i += 1) {
            const old_byte = if (old_pos + i < old_data.len) old_data[old_pos + i] else 0;
            const diff_byte = if (diff_off < diff_data.len) diff_data[diff_off] else 0;
            result[new_pos] = old_byte ^ diff_byte;
            new_pos += 1;
            diff_off += 1;
        }
        old_pos += add_len;

        // Adjust old_pos by seek_offset for next match
        if (seek_offset != 0) {
            old_pos = if (seek_offset > 0)
                old_pos + @as(usize, @intCast(seek_offset))
            else
                old_pos - @as(usize, @intCast(-seek_offset));
        }

        // INSERT: copy from extra_data
        i = 0;
        while (i < insert_len) : (i += 1) {
            if (extra_off < extra_data.len) {
                result[new_pos] = extra_data[extra_off];
                extra_off += 1;
            }
            new_pos += 1;
        }
    }

    return result;
}

// Helper: write i64 to buffer as little-endian
fn writeI64(buf: []u8, val: i64) void {
    const u = @as(u64, @bitCast(val));
    buf[0] = @truncate(u);
    buf[1] = @truncate(u >> 8);
    buf[2] = @truncate(u >> 16);
    buf[3] = @truncate(u >> 24);
    buf[4] = @truncate(u >> 32);
    buf[5] = @truncate(u >> 40);
    buf[6] = @truncate(u >> 48);
    buf[7] = @truncate(u >> 56);
}

fn readI64(buf: []const u8) i64 {
    const lo = @as(u64, buf[0]) | (@as(u64, buf[1]) << 8) | (@as(u64, buf[2]) << 16) | (@as(u64, buf[3]) << 24);
    const hi = @as(u64, buf[4]) | (@as(u64, buf[5]) << 8) | (@as(u64, buf[6]) << 16) | (@as(u64, buf[7]) << 24);
    return @bitCast(lo | (hi << 32));
}

fn appendI64(list: *std.array_list.Managed(u8), allocator: Allocator, val: i64) !void {
    var buf: [8]u8 = undefined;
    writeI64(&buf, val);
    try list.appendSlice(&buf);
}

test "bsdiff/bspatch: roundtrip" {
    const old = "The quick brown fox jumps over the lazy dog.";
    const new = "The quick brown cat jumps over the lazy dog.";

    const patch = try bsdiff(std.testing.allocator, old, new);
    defer std.testing.allocator.free(patch);

    const rebuilt = try bspatch(std.testing.allocator, old, patch);
    defer std.testing.allocator.free(rebuilt);

    try std.testing.expectEqualStrings(new, rebuilt);
}

test "bsdiff/bspatch: identical" {
    const data = "hello world this is a test of the bsdiff algorithm";
    const patch = try bsdiff(std.testing.allocator, data, data);
    defer std.testing.allocator.free(patch);

    const rebuilt = try bspatch(std.testing.allocator, data, patch);
    defer std.testing.allocator.free(rebuilt);

    try std.testing.expectEqualStrings(data, rebuilt);
}

test "bsdiff/bspatch: empty old" {
    const new = "brand new file content";
    const patch = try bsdiff(std.testing.allocator, &.{}, new);
    defer std.testing.allocator.free(patch);

    const rebuilt = try bspatch(std.testing.allocator, &.{}, patch);
    defer std.testing.allocator.free(rebuilt);

    try std.testing.expectEqualStrings(new, rebuilt);
}

test "bsdiff/bspatch: large change" {
    var old_buf: [1024]u8 = undefined;
    var new_buf: [1024]u8 = undefined;
    for (&old_buf, 0..) |*b, i| b.* = @truncate(i);
    for (&new_buf, 0..) |*b, i| b.* = @truncate(i ^ 0xFF);

    const patch = try bsdiff(std.testing.allocator, &old_buf, &new_buf);
    defer std.testing.allocator.free(patch);

    const rebuilt = try bspatch(std.testing.allocator, &old_buf, patch);
    defer std.testing.allocator.free(rebuilt);

    try std.testing.expectEqualSlices(u8, &new_buf, rebuilt);
}
