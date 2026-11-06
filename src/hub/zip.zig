// WIZP Pure Zig ZIP Extractor — No `unzip` external dependency.
// Handles store-method ZIP archives while std.zip handles full extraction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const runtime = @import("../runtime_016.zig");

const EOCD_SIGNATURE: u32 = 0x06054b50;
const CD_SIGNATURE: u32 = 0x02014b50;
const LF_SIGNATURE: u32 = 0x04034b50;
const archive_bytes_max: usize = 100 * 1024 * 1024;

const CentralDirEntry = struct {
    compression_method: u16,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    file_name: []const u8,
    local_header_offset: u32,
};

const EndOfCentralDir = struct {
    cd_offset: u32,
    cd_size: u32,
    cd_entries: u16,
};

/// Read one stored file from a ZIP archive and return its content.
pub fn readFile(allocator: Allocator, zip_path: []const u8, internal_path: []const u8) ![]u8 {
    const archive = try std.Io.Dir.cwd().readFileAlloc(
        runtime.io(),
        zip_path,
        allocator,
        .limited(archive_bytes_max),
    );
    defer allocator.free(archive);

    const eocd = try findEOCD(archive);
    const entries = try readCentralDir(allocator, archive, &eocd);
    defer {
        for (entries) |entry| allocator.free(entry.file_name);
        allocator.free(entries);
    }

    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.file_name, internal_path)) {
            return extractFile(allocator, archive, entry);
        }
    }
    return error.FileNotFound;
}

/// Extract all files from a ZIP archive with std.zip store/deflate support.
pub fn extractAll(allocator: Allocator, zip_path: []const u8, dest_dir: []const u8) !void {
    _ = allocator;
    var file = try std.Io.Dir.cwd().openFile(runtime.io(), zip_path, .{});
    defer file.close(runtime.io());

    try std.Io.Dir.cwd().createDirPath(runtime.io(), dest_dir);
    var destination = try std.Io.Dir.cwd().openDir(runtime.io(), dest_dir, .{});
    defer destination.close(runtime.io());

    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(runtime.io(), &read_buffer);
    try std.zip.extract(destination, &file_reader, .{});
}

fn findEOCD(archive: []const u8) !EndOfCentralDir {
    const search_size = @min(archive.len, 22 + 65536);
    if (search_size < 22) return error.BadZip;
    const search = archive[archive.len - search_size ..];
    var index = search.len - 4;
    while (true) {
        if (std.mem.readInt(u32, search[index..][0..4], .little) == EOCD_SIGNATURE) break;
        if (index == 0) return error.BadZip;
        index -= 1;
    }
    if (search.len - index < 22) return error.BadZip;
    const eocd = search[index..];
    const result = EndOfCentralDir{
        .cd_entries = std.mem.readInt(u16, eocd[10..][0..2], .little),
        .cd_size = std.mem.readInt(u32, eocd[12..][0..4], .little),
        .cd_offset = std.mem.readInt(u32, eocd[16..][0..4], .little),
    };
    const directory_end = std.math.add(usize, result.cd_offset, result.cd_size) catch return error.BadZip;
    if (directory_end > archive.len) return error.BadZip;
    return result;
}

fn readCentralDir(
    allocator: Allocator,
    archive: []const u8,
    eocd: *const EndOfCentralDir,
) ![]CentralDirEntry {
    var entries: std.ArrayListUnmanaged(CentralDirEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.file_name);
        entries.deinit(allocator);
    }
    try entries.ensureTotalCapacity(allocator, eocd.cd_entries);

    var offset: usize = eocd.cd_offset;
    for (0..eocd.cd_entries) |_| {
        if (offset > archive.len or archive.len - offset < 46) return error.BadZip;
        const header = archive[offset .. offset + 46];
        if (std.mem.readInt(u32, header[0..4], .little) != CD_SIGNATURE) return error.BadZip;
        const file_name_len = std.mem.readInt(u16, header[28..30], .little);
        const extra_field_len = std.mem.readInt(u16, header[30..32], .little);
        const comment_len = std.mem.readInt(u16, header[32..34], .little);
        const entry_size = std.math.add(
            usize,
            46,
            @as(usize, file_name_len) + extra_field_len + comment_len,
        ) catch return error.BadZip;
        if (entry_size > archive.len - offset) return error.BadZip;
        const file_name = try allocator.dupe(u8, archive[offset + 46 .. offset + 46 + file_name_len]);
        errdefer allocator.free(file_name);
        try entries.append(allocator, .{
            .compression_method = std.mem.readInt(u16, header[10..12], .little),
            .crc32 = std.mem.readInt(u32, header[16..20], .little),
            .compressed_size = std.mem.readInt(u32, header[20..24], .little),
            .uncompressed_size = std.mem.readInt(u32, header[24..28], .little),
            .file_name = file_name,
            .local_header_offset = std.mem.readInt(u32, header[42..46], .little),
        });
        offset += entry_size;
    }
    return entries.toOwnedSlice(allocator);
}

fn extractFile(allocator: Allocator, archive: []const u8, entry: *const CentralDirEntry) ![]u8 {
    const offset: usize = entry.local_header_offset;
    if (offset > archive.len or archive.len - offset < 30) return error.BadZip;
    const header = archive[offset .. offset + 30];
    if (std.mem.readInt(u32, header[0..4], .little) != LF_SIGNATURE) return error.BadZip;
    const file_name_len = std.mem.readInt(u16, header[26..28], .little);
    const extra_field_len = std.mem.readInt(u16, header[28..30], .little);
    const data_offset = std.math.add(
        usize,
        offset + 30,
        @as(usize, file_name_len) + extra_field_len,
    ) catch return error.BadZip;
    const data_end = std.math.add(usize, data_offset, entry.compressed_size) catch return error.BadZip;
    if (data_end > archive.len) return error.BadZip;
    if (entry.compression_method != 0) return error.UnsupportedCompression;
    if (entry.compressed_size != entry.uncompressed_size) return error.BadZip;
    return allocator.dupe(u8, archive[data_offset..data_end]);
}
