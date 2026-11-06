//! Stub svg2tvg module for compilation without SVG conversion support.

const std = @import("std");

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1.0,
};

pub const TvgData = struct {
    data: []const u8,
};

pub const tvg = struct {
    pub const Parser = struct {
        header: struct {
            width: u32 = 0,
            height: u32 = 0,
        } = .{},

        pub fn deinit(_: *Parser) void {}
    };

    pub fn parse(allocator: std.mem.Allocator, reader: anytype) !Parser {
        _ = allocator;
        _ = reader;
        return error.TvgParsingNotAvailable;
    }
};

pub fn renderStream(
    _: std.mem.Allocator,
    _: *anyopaque,
    reader: anytype,
    _: anytype,
) !void {
    _ = reader;
    return error.TvgRenderingNotAvailable;
}

pub fn convertSvg(_: std.mem.Allocator, _: []const u8) !TvgData {
    return error.SvgConversionNotAvailable;
}
