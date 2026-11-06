// WIZP - Shared HTTP Client
// Single HTTP client used by LLM, OpenVSX, Updater, and ToolRegistry.
// Wraps std.http.Client with convenience methods for GET, POST, and download.

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;
const http = std.http;

pub const HttpClient = struct {
    allocator: Allocator,
    client: http.Client,

    pub fn init(allocator: Allocator) HttpClient {
        return .{
            .allocator = allocator,
            .client = http.Client{
                .allocator = allocator,
                .io = runtime.io(),
            },
        };
    }

    /// HTTP GET, returns response body as allocated slice
    pub fn get(self: *HttpClient, url: []const u8) ![]const u8 {
        const uri = try std.Uri.parse(url);
        var req_http = try self.client.request(.GET, uri, .{});
        defer req_http.deinit();
        try req_http.sendBodyComplete(&.{});

        var redirect_buf: [4096]u8 = undefined;
        var response = try req_http.receiveHead(&redirect_buf);
        var transfer_buf: [4096]u8 = undefined;
        return try response.reader(&transfer_buf).*.allocRemaining(self.allocator, .limited(10 * 1024 * 1024));
    }

    /// HTTP POST with JSON body, returns response body
    pub fn post(self: *HttpClient, url: []const u8, json_body: []const u8, headers: []const [2][]const u8) ![]const u8 {
        const uri = try std.Uri.parse(url);
        var header_buf = try self.allocator.alloc(http.Header, headers.len + 1);
        defer self.allocator.free(header_buf);
        var header_count: usize = 0;
        header_buf[header_count] = .{ .name = "Content-Type", .value = "application/json" };
        header_count += 1;
        for (headers) |h| {
            header_buf[header_count] = .{ .name = h[0], .value = h[1] };
            header_count += 1;
        }

        var req_http = try self.client.request(.POST, uri, .{
            .extra_headers = header_buf[0..header_count],
        });
        defer req_http.deinit();
        try req_http.sendBodyComplete(@constCast(json_body));

        var redirect_buf: [4096]u8 = undefined;
        var response = try req_http.receiveHead(&redirect_buf);
        var transfer_buf: [4096]u8 = undefined;
        return try response.reader(&transfer_buf).*.allocRemaining(self.allocator, .limited(10 * 1024 * 1024));
    }

    /// Download a file from URL to local path
    pub fn download(self: *HttpClient, url: []const u8, dest_path: []const u8) !void {
        const uri = try std.Uri.parse(url);
        var req_http = try self.client.request(.GET, uri, .{});
        defer req_http.deinit();
        try req_http.sendBodyComplete(&.{});

        var redirect_buf: [4096]u8 = undefined;
        var response = try req_http.receiveHead(&redirect_buf);

        // Ensure parent directory exists
        if (std.fs.path.dirname(dest_path)) |dir| {
            runtime.createDirPath(dir) catch {};
        }

        const file = try std.Io.Dir.cwd().createFile(runtime.io(), dest_path, .{});
        defer file.close(runtime.io());
        var buf: [8192]u8 = undefined;
        var transfer_buf: [8192]u8 = undefined;
        while (true) {
            const n = try response.reader(&transfer_buf).read(&buf);
            if (n == 0) break;
            try runtime.writeAll(file, buf[0..n]);
        }
    }

    /// HTTP GET with streaming — calls `on_chunk` for each received chunk
    pub fn streamGet(self: *HttpClient, url: []const u8, on_chunk: *const fn ([]const u8) void) !void {
        const uri = try std.Uri.parse(url);
        var req_http = try self.client.request(.GET, uri, .{});
        defer req_http.deinit();
        try req_http.sendBodyComplete(&.{});

        var redirect_buf: [4096]u8 = undefined;
        var response = try req_http.receiveHead(&redirect_buf);

        var buf: [4096]u8 = undefined;
        var transfer_buf: [4096]u8 = undefined;
        while (true) {
            const n = try response.reader(&transfer_buf).read(&buf);
            if (n == 0) break;
            on_chunk(buf[0..n]);
        }
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }
};
