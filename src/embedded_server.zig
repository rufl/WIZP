// WIZP Embedded HTTP Server — serves the frontend from the packaged dist tree.
// Bun is a build-time dependency only. Monaco is served from the packaged
// monaco-vs/ directory; small development assets remain embedded as fallbacks.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const ExtensionHost = @import("hub/ExtensionHost.zig").ExtensionHost;
const ContentLength = @import("protocol/ContentLength.zig");
const EditorJson = @import("ui/EditorJson.zig");

fn rpcMethodMatches(body: []const u8, expected_marker: []const u8) bool {
    const method = EditorJson.escapedStringParam(body, "method") orelse return false;
    const expected_prefix = "\"method\":\"";
    const expected = if (std.mem.startsWith(u8, expected_marker, expected_prefix) and
        std.mem.endsWith(u8, expected_marker, "\""))
        expected_marker[expected_prefix.len .. expected_marker.len - 1]
    else
        expected_marker;
    return std.mem.eql(u8, method, expected);
}

test "RPC routing accepts whitespace around method separator" {
    try std.testing.expect(rpcMethodMatches(
        "{ \"jsonrpc\" : \"2.0\", \"method\" : \"extension/commands\", \"id\" : 7 }",
        "\"method\":\"extension/commands\"",
    ));
    try std.testing.expect(!rpcMethodMatches(
        "{ \"method\" : \"file/read\" }",
        "\"method\":\"extension/commands\"",
    ));
}

test "priority routing includes file, search, and control RPCs" {
    try std.testing.expect(EmbeddedServer.isPriorityRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\":\"file/read\"}",
    ));
    try std.testing.expect(EmbeddedServer.isPriorityRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\": \"file/save\"}",
    ));
    try std.testing.expect(EmbeddedServer.isPriorityRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\":\"file/rename\"}",
    ));
    try std.testing.expect(EmbeddedServer.isPriorityRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\":\"terminal/spawn\"}",
    ));
    try std.testing.expect(EmbeddedServer.isPriorityRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\":\"search/text\"}",
    ));
    try std.testing.expect(EmbeddedServer.isPriorityRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\":\"search/replace\"}",
    ));
    try std.testing.expect(!EmbeddedServer.isPriorityRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\":\"terminal/read\"}",
    ));
    try std.testing.expect(EmbeddedServer.isPriorityRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\":\"ghostty/info\"}",
    ));
}

test "critical routing keeps task and terminal control RPCs responsive" {
    try std.testing.expect(EmbeddedServer.isCriticalRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\":\"tasks/discover\"}",
    ));
    try std.testing.expect(EmbeddedServer.isCriticalRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\": \"terminal/write\"}",
    ));
    try std.testing.expect(EmbeddedServer.isCriticalRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\":\"hub/install\"}",
    ));
    try std.testing.expect(!EmbeddedServer.isCriticalRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\":\"terminal/read\"}",
    ));
}
test "terminal reads use their isolated worker pool" {
    try std.testing.expect(EmbeddedServer.isTerminalReadRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\":\"terminal/read\"}",
    ));
    try std.testing.expect(EmbeddedServer.isTerminalReadRequest(
        "POST /api/rpc HTTP/1.1\r\n\r\n{\"method\": \"terminal/read\"}",
    ));
}

test "direct file mutation renames absolute Unicode paths" {
    const allocator = std.testing.allocator;
    const base = try std.fmt.allocPrint(allocator, "/tmp/wizp-direct-rename-{}", .{std.time.nanoTimestamp()});
    defer allocator.free(base);
    try std.Io.Dir.createDirAbsolute(runtime.io(), base, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(runtime.io(), base) catch {};

    const old_path = try std.fs.path.join(allocator, &.{ base, "Long 文件.txt" });
    defer allocator.free(old_path);
    const new_path = try std.fs.path.join(allocator, &.{ base, "renamed-文件.txt" });
    defer allocator.free(new_path);
    try runtime.writeFile(old_path, "preserve existing content\n");

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"file/rename\",\"params\":{{\"from\":\"{s}\",\"to\":\"{s}\"}}}}}",
        .{ old_path, new_path },
    );
    defer allocator.free(body);
    const response = try EmbeddedServer.directFileMutationResponse(allocator, "file/rename", body);
    defer allocator.free(response);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":true}", response);
    try std.Io.Dir.cwd().access(runtime.io(), new_path, .{});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(runtime.io(), old_path, .{}));
}

// GTK window control functions (used for custom titlebar buttons in native mode)
extern "c" fn gtk_window_close(window: *anyopaque) void;
extern "c" fn gtk_window_iconify(window: *anyopaque) void;
extern "c" fn gtk_window_maximize(window: *anyopaque) void;

const frontend_bundled = @import("frontend_bundled").WIZP_BUNDLED_FRONTEND;
const runtime_paths = @import("runtime_paths");

const index_html = @embedFile("index.html");

const favicon_svg = @embedFile("favicon.svg");

const editor_ts = @embedFile("editor.ts"); // always present for dev builds

const xterm_css = @embedFile("xterm.css");
const codicon_css = @embedFile("codicon.css");
const codicon_ttf = @embedFile("codicon.ttf");

// Dev-only raw TS files (only referenced in serveFile when !bundled)
const bridge_ts = @embedFile("bridge.ts");
const terminal_ts = @embedFile("terminal.ts");
const eventbus_ts = @embedFile("src/eventbus.ts");
const explorer_ts = @embedFile("src/explorer.ts");
const git_ts = @embedFile("src/git.ts");
const palette_ts = @embedFile("src/palette.ts");
const search_ts = @embedFile("src/search.ts");
const settings_ts = @embedFile("src/settings.ts");
const sidebarViews_ts = @embedFile("src/sidebarViews.ts");
const utils_ts = @embedFile("src/utils.ts");

const WorkerPool = @import("threading/Worker.zig").WorkerPool;
const runtime = @import("runtime_016.zig");
const WindowsSocket = if (builtin.os.tag == .windows) struct {
    const Socket = usize;
    const invalid_socket: Socket = std.math.maxInt(Socket);
    const fionbio: c_int = @bitCast(@as(u32, 0x8004667e));

    const SockAddrIn = extern struct {
        family: u16,
        port: u16,
        address: u32,
        zero: [8]u8,
    };

    extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    extern "ws2_32" fn socket(family: c_int, kind: c_int, protocol: c_int) callconv(.winapi) Socket;
    extern "ws2_32" fn ioctlsocket(socket_handle: Socket, command: c_int, value: *u32) callconv(.winapi) c_int;
    extern "ws2_32" fn setsockopt(socket_handle: Socket, level: c_int, option: c_int, value: *const anyopaque, value_len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn bind(socket_handle: Socket, address: *const SockAddrIn, address_len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(socket_handle: Socket, backlog: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn accept(socket_handle: Socket, address: ?*anyopaque, address_len: ?*c_int) callconv(.winapi) Socket;
    extern "ws2_32" fn closesocket(socket_handle: Socket) callconv(.winapi) c_int;
    extern "ws2_32" fn recv(socket_handle: Socket, buffer: [*]u8, length: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn send(socket_handle: Socket, buffer: [*]const u8, length: c_int, flags: c_int) callconv(.winapi) c_int;

    fn listenOn(port: u16) !Socket {
        var wsadata: [512]u8 = undefined;
        if (WSAStartup(0x0202, &wsadata) != 0) return error.NetworkDown;
        errdefer _ = WSACleanup();

        const socket_handle = socket(2, 1, 6);
        if (socket_handle == invalid_socket) return error.NetworkDown;
        errdefer _ = closesocket(socket_handle);

        var reuse: c_int = 1;
        _ = setsockopt(socket_handle, 0xffff, 4, &reuse, @sizeOf(c_int));
        const address = SockAddrIn{
            .family = 2,
            .port = std.mem.nativeToBig(u16, port),
            .address = @bitCast([4]u8{ 127, 0, 0, 1 }),
            .zero = @as([8]u8, @splat(0)),
        };
        if (bind(socket_handle, &address, @sizeOf(SockAddrIn)) != 0) {
            return switch (WSAGetLastError()) {
                10048 => error.AddressInUse,
                10049 => error.AddressUnavailable,
                else => error.Unexpected,
            };
        }
        var nonblocking: u32 = 1;
        if (ioctlsocket(socket_handle, fionbio, &nonblocking) != 0) return error.Unexpected;
        if (listen(socket_handle, 128) != 0) return error.Unexpected;
        return socket_handle;
    }

    fn acceptOne(socket_handle: Socket) !Socket {
        const accepted = accept(socket_handle, null, null);
        if (accepted == invalid_socket) {
            return switch (WSAGetLastError()) {
                10035 => error.WouldBlock,
                else => error.Unexpected,
            };
        }
        var blocking: u32 = 0;
        if (ioctlsocket(accepted, fionbio, &blocking) != 0) {
            _ = closesocket(accepted);
            return error.Unexpected;
        }
        return accepted;
    }
    const PollFd = extern struct {
        fd: Socket,
        events: i16,
        revents: i16,
    };
    const poll_in: i16 = 0x0100;

    extern "ws2_32" fn WSAPoll(fd_array: *PollFd, count: u32, timeout: c_int) c_int;

    fn waitReadable(socket_handle: Socket, timeout_ms: c_int) bool {
        var poll_fd = PollFd{ .fd = socket_handle, .events = poll_in, .revents = 0 };
        return WSAPoll(&poll_fd, 1, timeout_ms) > 0;
    }

    fn close(socket_handle: Socket) void {
        if (socket_handle != invalid_socket) _ = closesocket(socket_handle);
    }

    fn cleanup() void {
        _ = WSACleanup();
    }

    fn read(socket_handle: Socket, buffer: []u8) !usize {
        const result = recv(socket_handle, buffer.ptr, @intCast(buffer.len), 0);
        if (result == 0) return 0;
        if (result < 0) {
            return switch (WSAGetLastError()) {
                10053, 10054, 10058 => error.ConnectionResetByPeer,
                10050, 10051 => error.NetworkDown,
                else => error.Unexpected,
            };
        }
        return @intCast(result);
    }

    fn writeAll(socket_handle: Socket, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const chunk_len: c_int = @intCast(@min(bytes.len - offset, @as(usize, std.math.maxInt(c_int))));
            const result = send(socket_handle, bytes.ptr + offset, chunk_len, 0);
            if (result <= 0) {
                return switch (WSAGetLastError()) {
                    10053, 10054, 10058 => error.ConnectionResetByPeer,
                    10050, 10051 => error.NetworkDown,
                    else => error.Unexpected,
                };
            }
            offset += @intCast(result);
        }
    }
} else struct {};

const LegacyStream = struct {
    inner: if (builtin.os.tag == .windows) WindowsSocket.Socket else std.Io.net.Stream,
    handle: if (builtin.os.tag == .windows) WindowsSocket.Socket else std.Io.net.Socket.Handle,

    fn init(inner: std.Io.net.Stream) LegacyStream {
        return .{ .inner = inner, .handle = inner.socket.handle };
    }

    fn initWindows(socket_handle: if (builtin.os.tag == .windows) WindowsSocket.Socket else usize) LegacyStream {
        return .{ .inner = socket_handle, .handle = socket_handle };
    }

    fn close(self: *LegacyStream) void {
        if (comptime builtin.os.tag == .windows) {
            WindowsSocket.close(self.handle);
        } else {
            self.inner.close(runtime.io());
        }
    }

    fn read(self: *LegacyStream, buffer: []u8) !usize {
        if (comptime builtin.os.tag == .windows) {
            return WindowsSocket.read(self.handle, buffer);
        }
        var reader = self.inner.reader(runtime.io(), &.{});
        var chunks = [_][]u8{buffer};
        return reader.interface.readVec(&chunks) catch |err| switch (err) {
            error.EndOfStream => 0,
            error.ReadFailed => return reader.err.?,
        };
    }

    fn write(self: *LegacyStream, bytes: []const u8) !usize {
        try self.writeAll(bytes);
        return bytes.len;
    }

    fn writeAll(self: *LegacyStream, bytes: []const u8) !void {
        if (comptime builtin.os.tag == .windows) {
            return WindowsSocket.writeAll(self.handle, bytes);
        }
        var buffer: [4096]u8 = undefined;
        var writer = self.inner.writer(runtime.io(), &buffer);
        writer.interface.writeAll(bytes) catch return writer.err.?;
        writer.interface.flush() catch return writer.err.?;
    }
};
fn waitReadable(socket_handle: if (builtin.os.tag == .windows) WindowsSocket.Socket else std.Io.net.Socket.Handle, timeout_ms: i32) bool {
    if (comptime builtin.os.tag == .windows) {
        return WindowsSocket.waitReadable(socket_handle, timeout_ms);
    }
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = socket_handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    return (std.posix.poll(&poll_fds, timeout_ms) catch return false) > 0;
}

const LegacyConnection = struct { stream: LegacyStream };

const LegacyServer = struct {
    inner: if (builtin.os.tag == .windows) WindowsSocket.Socket else std.Io.net.Server,

    fn init(port: u16) !LegacyServer {
        if (comptime builtin.os.tag == .windows) {
            return .{ .inner = try WindowsSocket.listenOn(port) };
        }
        const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        return .{ .inner = try addr.listen(runtime.io(), .{ .reuse_address = true }) };
    }

    fn accept(self: *LegacyServer) !LegacyConnection {
        if (comptime builtin.os.tag == .windows) {
            return .{ .stream = .initWindows(try WindowsSocket.acceptOne(self.inner)) };
        }
        return .{ .stream = .init(try self.inner.accept(runtime.io())) };
    }

    fn deinit(self: *LegacyServer) void {
        if (comptime builtin.os.tag == .windows) {
            WindowsSocket.close(self.inner);
            WindowsSocket.cleanup();
        } else {
            self.inner.deinit(runtime.io());
        }
    }
};

pub const EmbeddedServer = struct {
    allocator: Allocator,
    server: LegacyServer,
    running: bool,
    daemon_stdin: ?std.Io.File,
    daemon_stdout: ?std.Io.File,
    monaco_dir: ?[]const u8,
    frontend_dir: ?[]const u8,
    dirs_detected: bool = false,
    // For native window controls (minimize / maximize / close from custom titlebar)
    native_window: ?*anyopaque = null,
    ext_host: ?*ExtensionHost = null,
    // Serializes access to the shared daemon stdin/stdout pipes across HTTP threads
    daemon_mutex: @import("sync.zig").Mutex = .{},
    // Prevents continuous best-effort terminal reads from starving control RPCs.
    daemon_control_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // Serializes extension-host engine calls without blocking daemon callbacks.
    ext_host_mutex: @import("sync.zig").Mutex = .{},
    file_cache: std.StringHashMapUnmanaged([]const u8) = .{},
    workspace_folders_json: ?[]const u8 = null,
    cache_mutex: @import("sync.zig").Mutex = .{},
    accept_worker_pool: *WorkerPool,
    worker_pool: *WorkerPool,
    priority_worker_pool: *WorkerPool,
    terminal_read_worker_pool: *WorkerPool,
    critical_worker_pool: *WorkerPool,
    metrics_started_ns: i128,
    rpc_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    terminal_read_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    http_request_logging: bool,
    daemon_disconnect_injection: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const AcceptedConnTaskCtx = struct {
        server: *EmbeddedServer,
        conn: LegacyConnection,

        pub fn run(ctx: @This()) void {
            ctx.server.handleAcceptedConnection(ctx.conn);
        }
    };

    const ConnTaskCtx = struct {
        server: *EmbeddedServer,
        conn: LegacyConnection,
        initial: [4096]u8 = undefined,
        initial_len: usize = 0,

        pub fn run(ctx: @This()) void {
            ctx.server.handleConnection(ctx.conn, ctx.initial[0..ctx.initial_len]);
        }
    };

    pub fn init(allocator: Allocator, port: u16, daemon_in: ?std.Io.File, daemon_out: ?std.Io.File) !EmbeddedServer {
        var server = try LegacyServer.init(port);
        errdefer server.deinit();

        const accept_pool = try WorkerPool.init(allocator, 32);
        errdefer accept_pool.deinit();
        const pool = try WorkerPool.init(allocator, configuredWorkerCount());
        errdefer pool.deinit();
        const priority_pool = try WorkerPool.init(allocator, 8);
        errdefer priority_pool.deinit();
        const terminal_read_pool = try WorkerPool.init(allocator, 8);
        errdefer terminal_read_pool.deinit();
        const critical_pool = try WorkerPool.init(allocator, 8);
        errdefer critical_pool.deinit();
        return EmbeddedServer{
            .allocator = allocator,
            .server = server,
            .running = true,
            .daemon_stdin = daemon_in,
            .daemon_stdout = daemon_out,
            .monaco_dir = null,
            .frontend_dir = null,
            .dirs_detected = false,
            .accept_worker_pool = accept_pool,
            .worker_pool = pool,
            .priority_worker_pool = priority_pool,
            .terminal_read_worker_pool = terminal_read_pool,
            .critical_worker_pool = critical_pool,
            .metrics_started_ns = runtime.nanoTimestamp(),
            .daemon_disconnect_injection = .init(configuredDaemonDisconnectInjection()),
            .http_request_logging = configuredHttpRequestLogging(),
        };
    }

    fn configuredWorkerCount() usize {
        if (runtime.getEnvVarOwned(std.heap.page_allocator, "WIZP_HTTP_WORKERS") catch null) |raw| {
            defer std.heap.page_allocator.free(raw);
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                const parsed = std.fmt.parseInt(usize, trimmed, 10) catch 0;
                if (parsed > 0) return @min(parsed, 32);
            }
        }
        // Keep priority file saves/reads and reload traffic responsive while
        // terminal/read requests wait on PTY output or the daemon mutex.
        return 32;
    }

    fn configuredHttpRequestLogging() bool {
        if (runtime.getEnvVarOwned(std.heap.page_allocator, "WIZP_HTTP_REQUEST_LOGS") catch null) |raw| {
            defer std.heap.page_allocator.free(raw);
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            return std.mem.eql(u8, trimmed, "1") or
                std.ascii.eqlIgnoreCase(trimmed, "true") or
                std.ascii.eqlIgnoreCase(trimmed, "yes");
        }
        return false;
    }

    fn configuredDaemonDisconnectInjection() bool {
        if (runtime.getEnvVarOwned(std.heap.page_allocator, "WIZP_INJECT_DAEMON_DISCONNECT_ONCE") catch null) |raw| {
            defer std.heap.page_allocator.free(raw);
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            return std.mem.eql(u8, trimmed, "1") or
                std.ascii.eqlIgnoreCase(trimmed, "true") or
                std.ascii.eqlIgnoreCase(trimmed, "yes");
        }
        return false;
    }
    fn isFileRequest(initial: []const u8) bool {
        return std.mem.indexOf(u8, initial, "POST /api/file-read ") != null or
            std.mem.indexOf(u8, initial, "POST /api/file-save ") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/read\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/read\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/save\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/save\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/list\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/list\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/create\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/create\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/mkdir\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/mkdir\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/rename\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/rename\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/delete\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/delete\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"workspace/getFolders\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"workspace/getFolders\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"workspace/setFolders\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"workspace/setFolders\"") != null;
    }

    fn isCriticalRequest(initial: []const u8) bool {
        return std.mem.indexOf(u8, initial, "\"method\":\"tasks/run\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"tasks/run\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"tasks/discover\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"tasks/discover\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"terminal/write\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"terminal/write\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"hub/") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"hub/") != null;
    }
    fn isTerminalReadRequest(initial: []const u8) bool {
        return std.mem.indexOf(u8, initial, "\"method\":\"terminal/read\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"terminal/read\"") != null;
    }

    fn isPriorityRequest(initial: []const u8) bool {
        return std.mem.startsWith(u8, initial, "GET /") or
            std.mem.indexOf(u8, initial, "POST /api/file-read ") != null or
            std.mem.indexOf(u8, initial, "POST /api/file-save ") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/read\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/read\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/save\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/save\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/list\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/list\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/create\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/create\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/mkdir\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/mkdir\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/rename\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/rename\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"file/delete\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"file/delete\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"workspace/getFolders\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"workspace/getFolders\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"workspace/setFolders\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"workspace/setFolders\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"session/load\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"session/load\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"session/save\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"session/save\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"search/text\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"search/text\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"search/replace\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"search/replace\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"terminal/spawn\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"terminal/spawn\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"terminal/resize\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"terminal/resize\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"terminal/list\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"terminal/list\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"terminal/kill\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"terminal/kill\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"ghostty/info\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"ghostty/info\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"ghostty/rendererBridge\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"ghostty/rendererBridge\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"hub/") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"hub/") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"extension/hostStatus\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"extension/hostStatus\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"extension/restartHost\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"extension/restartHost\"") != null or
            std.mem.indexOf(u8, initial, "\"method\":\"extension/crashHost\"") != null or
            std.mem.indexOf(u8, initial, "\"method\": \"extension/crashHost\"") != null;
    }
    fn logRequest(self: *EmbeddedServer, comptime format: []const u8, args: anytype) void {
        if (self.http_request_logging) std.debug.print(format, args);
    }

    pub fn deinit(self: *EmbeddedServer) void {
        if (self.monaco_dir) |d| self.allocator.free(d);
        if (self.frontend_dir) |d| self.allocator.free(d);
        self.cache_mutex.lock();
        var it = self.file_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.file_cache.deinit(self.allocator);
        if (self.workspace_folders_json) |folders| self.allocator.free(folders);
        self.cache_mutex.unlock();
        self.server.deinit();

        self.accept_worker_pool.deinit();
        self.critical_worker_pool.deinit();
        self.terminal_read_worker_pool.deinit();
        self.priority_worker_pool.deinit();
        self.worker_pool.deinit();
    }

    pub fn serve(self: *EmbeddedServer) !void {
        while (self.running) {
            var conn = self.server.accept() catch |err| {
                if (err == error.WouldBlock) {
                    runtime.sleepNanoseconds(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };

            const ctx = AcceptedConnTaskCtx{
                .server = self,
                .conn = conn,
            };
            self.accept_worker_pool.spawn(ctx, AcceptedConnTaskCtx.run) catch {
                conn.stream.close();
            };
        }
    }

    fn handleAcceptedConnection(self: *EmbeddedServer, initial_conn: LegacyConnection) void {
        var conn = initial_conn;
        if (builtin.os.tag != .windows) {
            const optval: c_int = 1;
            std.posix.setsockopt(conn.stream.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&optval)) catch {};
        }

        if (!waitReadable(conn.stream.handle, 1_000)) {
            conn.stream.close();
            return;
        }
        var initial: [4096]u8 = undefined;
        var initial_len = conn.stream.read(&initial) catch {
            conn.stream.close();
            return;
        };
        if (initial_len == 0) {
            conn.stream.close();
            return;
        }

        // Browser fetches can deliver headers and the JSON body in separate
        // packets. Fill small requests before choosing the worker pool so
        // filesystem RPCs do not fall behind the general daemon queue.
        var request_complete = true;
        if (extractContentLength(initial[0..initial_len])) |content_length| {
            if (std.mem.indexOf(u8, initial[0..initial_len], "\r\n\r\n")) |header_end| {
                const required = header_end + 4 + content_length;
                while (initial_len < required and initial_len < initial.len) {
                    if (!waitReadable(conn.stream.handle, 1_000)) {
                        request_complete = false;
                        break;
                    }
                    const more = conn.stream.read(initial[initial_len..]) catch {
                        request_complete = false;
                        break;
                    };
                    if (more == 0) {
                        request_complete = false;
                        break;
                    }
                    initial_len += more;
                }
            }
        }
        if (!request_complete) {
            conn.stream.close();
            return;
        }

        if (isFileRequest(initial[0..initial_len])) {
            // File reads and saves are local-only and must not wait behind
            // daemon or terminal work in any worker pool.
            self.handleConnection(conn, initial[0..initial_len]);
            return;
        }

        if (isTerminalReadRequest(initial[0..initial_len])) {
            var ctx = ConnTaskCtx{
                .server = self,
                .conn = conn,
                .initial_len = initial_len,
            };
            @memcpy(ctx.initial[0..initial_len], initial[0..initial_len]);
            self.terminal_read_worker_pool.spawn(ctx, ConnTaskCtx.run) catch {
                conn.stream.close();
            };
            return;
        }

        if (isCriticalRequest(initial[0..initial_len])) {
            var ctx = ConnTaskCtx{
                .server = self,
                .conn = conn,
                .initial_len = initial_len,
            };
            @memcpy(ctx.initial[0..initial_len], initial[0..initial_len]);
            self.critical_worker_pool.spawn(ctx, ConnTaskCtx.run) catch {
                conn.stream.close();
            };
            return;
        }

        if (isPriorityRequest(initial[0..initial_len])) {
            var ctx = ConnTaskCtx{
                .server = self,
                .conn = conn,
                .initial_len = initial_len,
            };
            @memcpy(ctx.initial[0..initial_len], initial[0..initial_len]);
            self.priority_worker_pool.spawn(ctx, ConnTaskCtx.run) catch {
                conn.stream.close();
            };
            return;
        }

        var ctx = ConnTaskCtx{
            .server = self,
            .conn = conn,
            .initial_len = initial_len,
        };
        @memcpy(ctx.initial[0..initial_len], initial[0..initial_len]);
        self.worker_pool.spawn(ctx, ConnTaskCtx.run) catch {
            conn.stream.close();
        };
    }

    fn handleConnection(self: *EmbeddedServer, conn: LegacyConnection, initial: []const u8) void {
        var stream = conn.stream;
        defer stream.close();

        var buf: [4096]u8 = undefined;
        var request_buf = std.array_list.Managed(u8).init(self.allocator);
        defer request_buf.deinit();
        request_buf.appendSlice(initial) catch return;
        if (extractContentLength(request_buf.items)) |content_length| {
            while (true) {
                const body = extractBody(request_buf.items) orelse "";
                if (body.len >= content_length) break;
                if (!waitReadable(stream.handle, ContentLength.default_read_timeout_ms)) return;
                const more = stream.read(&buf) catch return;
                if (more == 0) break;
                request_buf.appendSlice(buf[0..more]) catch return;
            }
        }

        const request = request_buf.items;
        const method = extractMethod(request);
        const path = extractPath(request);

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/__wizp_ready")) {
            self.daemon_mutex.lock();
            const daemon_ready = self.probeDaemon() catch false;
            self.daemon_mutex.unlock();
            if (daemon_ready) {
                _ = stream.write("HTTP/1.1 204 No Content\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n") catch {};
            } else {
                _ = stream.write("HTTP/1.1 503 Service Unavailable\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n") catch {};
            }
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/__wizp_metrics")) {
            const elapsed_ns = @max(runtime.nanoTimestamp() - self.metrics_started_ns, 0);
            const uptime_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
            const rpc_requests = self.rpc_requests.load(.seq_cst);
            const terminal_read_requests = self.terminal_read_requests.load(.seq_cst);
            var body_buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(
                &body_buf,
                "{{\"schema\":1,\"uptimeMs\":{},\"rpcRequests\":{},\"terminalReadRequests\":{}}}",
                .{ uptime_ms, rpc_requests, terminal_read_requests },
            ) catch return;
            var header_buf: [256]u8 = undefined;
            const header = std.fmt.bufPrint(
                &header_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                .{body.len},
            ) catch return;
            _ = stream.writeAll(header) catch return;
            _ = stream.writeAll(body) catch {};
            return;
        }

        // Handle CORS preflight
        if (std.mem.eql(u8, method, "OPTIONS")) {
            self.logRequest("[WIZP HTTP] {s} {s} -> 204 (CORS preflight)\n", .{ method, path });
            _ = stream.write("HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n") catch {};
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/file-read")) {
            self.logRequest("[WIZP HTTP] {s} {s}\n", .{ method, path });
            const read_result = directFileReadResponse(std.heap.page_allocator, extractBody(request) orelse "");
            const json_body = read_result catch |err| {
                _ = stream.write("HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n") catch {};
                std.debug.print("[WIZP HTTP] direct file read error: {}\n", .{err});
                return;
            };
            defer std.heap.page_allocator.free(json_body);
            var header_buf: [256]u8 = undefined;
            const header = std.fmt.bufPrint(
                &header_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                .{json_body.len},
            ) catch return;
            stream.writeAll(header) catch return;
            stream.writeAll(json_body) catch {};
            return;
        }
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/file-save")) {
            const request_body = extractBody(request) orelse @as([]const u8, &[_]u8{});
            self.logRequest("[WIZP HTTP] {s} {s} body={}\n", .{ method, path, request_body.len });
            const save_result = directFileSaveResponse(std.heap.page_allocator, request_body);
            const json_body = save_result catch |err| {
                _ = stream.write("HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n") catch {};
                std.debug.print("[WIZP HTTP] direct file save error: {}\n", .{err});
                return;
            };
            defer std.heap.page_allocator.free(json_body);
            var header_buf: [256]u8 = undefined;
            const header = std.fmt.bufPrint(
                &header_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                .{json_body.len},
            ) catch return;
            stream.writeAll(header) catch return;
            stream.writeAll(json_body) catch {};
            return;
        }

        if (std.mem.eql(u8, method, "POST") and
            std.mem.eql(u8, path, "/api/rpc") and
            self.daemon_disconnect_injection.swap(false, .seq_cst))
        {
            self.logRequest("[WIZP HTTP] injected daemon disconnect\n", .{});
            return;
        }
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/rpc")) {
            _ = self.rpc_requests.fetchAdd(1, .seq_cst);
            const body = extractBody(request) orelse "";
            if (rpcMethodMatches(body, "\"method\":\"terminal/read\"") or
                rpcMethodMatches(body, "\"method\": \"terminal/read\""))
            {
                _ = self.terminal_read_requests.fetchAdd(1, .seq_cst);
            }
            self.logRequest("[WIZP HTTP] {s} {s}\n", .{ method, path });
            self.handleRpcProxy(&stream, request) catch |err| {
                const rpc_method = EditorJson.escapedStringParam(body, "method") orelse "";
                std.debug.print("[WIZP HTTP] {s} {s} method={s} -> RPC proxy error: {}\n", .{ method, path, rpc_method, err });
                self.writeRpcProxyError(&stream, request, err);
            };
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/window")) {
            self.logRequest("[WIZP HTTP] {s} {s}\n", .{ method, path });
            self.handleWindowAction(&stream, request) catch |err| {
                std.debug.print("[WIZP HTTP] {s} {s} -> window action error: {}\n", .{ method, path, err });
            };
            return;
        }

        // Extension RPC: extensions running in Bun JS engine call this endpoint
        // to communicate back to the Zig daemon (webview.create, workspace.findFiles, etc.)
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/extension-rpc")) {
            self.logRequest("[WIZP HTTP] {s} {s}\n", .{ method, path });
            self.handleRpcProxy(&stream, request) catch |err| {
                std.debug.print("[WIZP HTTP] {s} {s} -> RPC proxy error: {}\n", .{ method, path, err });
                self.writeRpcProxyError(&stream, request, err);
            };
            return;
        }
        if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/api/extension/ui/poll")) {
            const ext_host = self.ext_host orelse {
                self.writeExtensionHttpError(&stream, "503 Service Unavailable", error.ExtensionHostUnavailable);
                return;
            };
            const js = "globalThis._wizp_uiQueue.splice(0, globalThis._wizp_uiQueue.length)";
            const res = blk: {
                self.ext_host_mutex.lock();
                defer self.ext_host_mutex.unlock();
                break :blk ext_host.engine.evalString(js, "uiPoll");
            } catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            defer ext_host.allocator.free(res);
            const raw = stripEngineResult(res);
            const response = std.fmt.allocPrint(
                self.allocator,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{s}",
                .{ raw.len, raw },
            ) catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            defer self.allocator.free(response);
            stream.writeAll(response) catch |err| {
                std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
            };
            return;
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/api/extension/ui/reply")) {
            const ext_host = self.ext_host orelse {
                self.writeExtensionHttpError(&stream, "503 Service Unavailable", error.ExtensionHostUnavailable);
                return;
            };
            const js = std.fmt.allocPrint(
                self.allocator,
                "let req = {s}; if (globalThis._wizp_uiResolvers && globalThis._wizp_uiResolvers[req.id]) {{ globalThis._wizp_uiResolvers[req.id](req.value); delete globalThis._wizp_uiResolvers[req.id]; }}",
                .{extractBody(request) orelse "{}"},
            ) catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            defer self.allocator.free(js);
            self.ext_host_mutex.lock();
            defer self.ext_host_mutex.unlock();
            ext_host.engine.evalVoid(js, "uiReply") catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/extension/tasks")) {
            const ext_host = self.ext_host orelse {
                self.writeExtensionHttpError(&stream, "503 Service Unavailable", error.ExtensionHostUnavailable);
                return;
            };
            self.ext_host_mutex.lock();
            defer self.ext_host_mutex.unlock();
            ext_host.activateTaskTypes(null) catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            const res = ext_host.engine.evalString(
                "Promise.resolve(globalThis._wizpContext.tasks.fetchTasks()).then(t => JSON.stringify(t))",
                "tasks",
            ) catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            defer ext_host.allocator.free(res);
            const raw = stripEngineResult(res);
            const response = std.fmt.allocPrint(
                self.allocator,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{s}",
                .{ raw.len, raw },
            ) catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            defer self.allocator.free(response);
            stream.writeAll(response) catch |err| {
                std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
            };
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/extension/webview/html")) {
            const ext_host = self.ext_host orelse {
                self.writeExtensionHttpError(&stream, "503 Service Unavailable", error.ExtensionHostUnavailable);
                return;
            };
            const target = extractTarget(request);
            const encoded_id = queryParamValue(target, "id") orelse {
                self.writeExtensionHttpError(&stream, "400 Bad Request", error.MissingWebviewId);
                return;
            };
            const decoded_id = urlDecode(self.allocator, encoded_id) catch |err| {
                self.writeExtensionHttpError(&stream, "400 Bad Request", err);
                return;
            };
            defer self.allocator.free(decoded_id);
            const quoted_id = jsonStringAlloc(self.allocator, decoded_id) catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            defer self.allocator.free(quoted_id);
            const js = std.fmt.allocPrint(
                self.allocator,
                "let view = globalThis._wizp_resolveWebviewView && globalThis._wizp_resolveWebviewView({s}); view && view.webview ? view.webview.html : ''",
                .{quoted_id},
            ) catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            defer self.allocator.free(js);
            const res = blk: {
                self.ext_host_mutex.lock();
                defer self.ext_host_mutex.unlock();
                break :blk ext_host.engine.evalString(js, "webview");
            } catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            defer ext_host.allocator.free(res);

            const stripped = stripEngineResult(res);
            var raw = stripped;
            var decoded_raw: ?[]u8 = null;
            if (stripped.len >= 2 and stripped[0] == '"' and stripped[stripped.len - 1] == '"') {
                if (std.json.parseFromSlice(std.json.Value, self.allocator, stripped, .{})) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value == .string) {
                        decoded_raw = self.allocator.dupe(u8, parsed.value.string) catch |err| {
                            self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                            return;
                        };
                        raw = decoded_raw.?;
                    }
                } else |_| {}
            }
            defer if (decoded_raw) |value| self.allocator.free(value);
            const html = injectWebviewBootstrap(self.allocator, "webviewView:", decoded_id, raw) catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            defer self.allocator.free(html);
            const response = std.fmt.allocPrint(
                self.allocator,
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}",
                .{ html.len, html },
            ) catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            defer self.allocator.free(response);
            stream.writeAll(response) catch |err| {
                std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
            };
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/extension/lsp/reply")) {
            const ext_host = self.ext_host orelse {
                self.writeExtensionHttpError(&stream, "503 Service Unavailable", error.ExtensionHostUnavailable);
                return;
            };
            const js = std.fmt.allocPrint(
                self.allocator,
                "let rep = {s}; globalThis._wizp_uiQueue.push({{type: 'lspResult', id: rep.id, result: rep.result}});",
                .{extractBody(request) orelse "{}"},
            ) catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            defer self.allocator.free(js);
            self.ext_host_mutex.lock();
            defer self.ext_host_mutex.unlock();
            ext_host.engine.evalVoid(js, "lspReply") catch |err| {
                self.writeExtensionHttpError(&stream, "500 Internal Server Error", err);
                return;
            };
            _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/api/terminal/stream")) {
            self.handleTerminalStream(&stream);
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/api/webview-resource")) {
            const target = extractTarget(request);
            if (queryParamValue(target, "path")) |encoded_path| {
                const decoded_path = urlDecode(self.allocator, encoded_path) catch return;
                defer self.allocator.free(decoded_path);
                const decoded_id = if (queryParamValue(target, "id")) |encoded_id|
                    urlDecode(self.allocator, encoded_id) catch null
                else
                    null;
                defer if (decoded_id) |id| self.allocator.free(id);

                const workspace_root = std.Io.Dir.cwd().realPathFileAlloc(runtime.io(), ".", self.allocator) catch {
                    _ = stream.write("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\nForbidden") catch {};
                    return;
                };
                defer self.allocator.free(workspace_root);
                const workspace_allowed = std.mem.startsWith(u8, decoded_path, workspace_root) and
                    (decoded_path.len == workspace_root.len or decoded_path[workspace_root.len] == std.fs.path.sep);
                const webview_allowed = if (decoded_id) |id|
                    if (self.ext_host) |ext_host| webviewResourceAllowed(self, ext_host, id, decoded_path) else false
                else
                    false;
                const allowed = workspace_allowed or webview_allowed;
                if (!allowed) {
                    std.debug.print("[WIZP HTTP] GET /api/webview-resource denied outside workspace: {s}\n", .{decoded_path});
                    _ = stream.write("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\nForbidden") catch {};
                    return;
                }

                if (std.Io.Dir.cwd().readFileAlloc(
                    runtime.io(),
                    decoded_path,
                    self.allocator,
                    .limited(10 * 1024 * 1024),
                )) |content| {
                    defer self.allocator.free(content);
                    const mime = mimeType(decoded_path);
                    var hdr_buf: [512]u8 = undefined;
                    const header = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {}\r\nCache-Control: no-cache, no-store, must-revalidate\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", .{ mime, content.len }) catch return;
                    _ = stream.writeAll(header) catch {};
                    _ = stream.writeAll(content) catch {};
                    self.logRequest("[WIZP HTTP] GET /api/webview-resource?path={s} -> 200 OK ({s}, {} bytes)\n", .{ decoded_path, mime, content.len });
                    return;
                } else |err| {
                    std.debug.print("[WIZP HTTP] GET /api/webview-resource error reading file: {}\n", .{err});
                }
            }
            self.logRequest("[WIZP HTTP] {s} {s} -> 404\n", .{ method, path });
            _ = stream.write("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\nNot Found") catch {};
            return;
        }

        if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/api/codicon.ttf")) {
            var hdr_buf: [512]u8 = undefined;
            const header = std.fmt.bufPrint(
                &hdr_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {}\r\nCache-Control: no-cache, no-store, must-revalidate\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                .{ mimeType("/codicon.ttf"), codicon_ttf.len },
            ) catch return;
            _ = stream.writeAll(header) catch {};
            _ = stream.writeAll(codicon_ttf) catch {};
            return;
        }

        const content = self.serveFile(path);
        if (content) |c| {
            const mime = mimeType(path);
            var hdr_buf: [512]u8 = undefined;
            const header = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {}\r\nCache-Control: no-cache, no-store, must-revalidate\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", .{ mime, c.len }) catch return;
            _ = stream.writeAll(header) catch {};
            _ = stream.writeAll(c) catch {};
            self.logRequest("[WIZP HTTP] {s} {s} -> 200 ({s}, {} bytes)\n", .{ method, path, mime, c.len });
        } else {
            self.logRequest("[WIZP HTTP] {s} {s} -> 404\n", .{ method, path });
            _ = stream.write("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\nNot Found") catch {};
        }
    }

    fn handleRpcProxyUsesExtensionHost(body: []const u8) bool {
        const method = EditorJson.escapedStringParam(body, "method") orelse return false;
        return std.mem.startsWith(u8, method, "extension/") or
            std.mem.eql(u8, method, "webview/receiveMessage") or
            std.mem.eql(u8, method, "webview.receiveMessage") or
            std.mem.eql(u8, method, "workspace/setFolders") or
            std.mem.eql(u8, method, "window/setActiveTextEditor") or
            std.mem.eql(u8, method, "window/onDidSaveTextEditor");
    }

    fn isFastControlRpc(body: []const u8) bool {
        const method = EditorJson.escapedStringParam(body, "method") orelse return false;
        return std.mem.startsWith(u8, method, "hub/") or
            std.mem.eql(u8, method, "extension/hostStatus") or
            std.mem.eql(u8, method, "extension/restartHost") or
            std.mem.eql(u8, method, "extension/crashHost");
    }

    fn writeRpcProxyError(self: *EmbeddedServer, stream: *LegacyStream, request: []const u8, err: anyerror) void {
        const body = extractBody(request) orelse return;
        const id_str = extractJsonRpcId(body) orelse "null";
        const response_body = std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32000,\"message\":\"{s}\"}}}}",
            .{ id_str, @errorName(err) },
        ) catch return;
        defer self.allocator.free(response_body);
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
            .{response_body.len},
        ) catch return;
        stream.writeAll(header) catch return;
        stream.writeAll(response_body) catch {};
    }
    fn writeExtensionHttpError(self: *EmbeddedServer, stream: *LegacyStream, status: []const u8, err: anyerror) void {
        const body = std.fmt.allocPrint(
            self.allocator,
            "{{\"success\":false,\"error\":\"{s}\"}}",
            .{@errorName(err)},
        ) catch return;
        defer self.allocator.free(body);
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
            .{ status, body.len },
        ) catch return;
        stream.writeAll(header) catch return;
        stream.writeAll(body) catch {};
    }

    fn handleRpcProxy(self: *EmbeddedServer, stream: *LegacyStream, request: []const u8) !void {
        const body = extractBody(request) orelse {
            _ = stream.write("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\n\r\nMissing body") catch {};
            return;
        };
        if (rpcMethodMatches(body, "\"method\":\"file/save\"")) {
            const response_body = try directFileSaveResponse(self.allocator, body);
            defer self.allocator.free(response_body);
            const response = try std.fmt.allocPrint(
                self.allocator,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}",
                .{ response_body.len, response_body },
            );
            defer self.allocator.free(response);
            stream.writeAll(response) catch {};
            return;
        }
        if (rpcMethodMatches(body, "\"method\":\"workspace/getFolders\"") or
            rpcMethodMatches(body, "\"method\": \"workspace/getFolders\""))
        {
            self.cache_mutex.lock();
            const cached = if (self.workspace_folders_json) |folders|
                self.allocator.dupe(u8, folders) catch null
            else
                null;
            self.cache_mutex.unlock();
            if (cached) |folders| {
                defer self.allocator.free(folders);
                const id_str = extractJsonRpcId(body) orelse "null";
                const response_body = try ContentLength.resultResponse(self.allocator, id_str, folders);
                defer self.allocator.free(response_body);
                var http_header_buf: [256]u8 = undefined;
                const http_header = try std.fmt.bufPrint(
                    &http_header_buf,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                    .{response_body.len},
                );
                try stream.writeAll(http_header);
                try stream.writeAll(response_body);
                return;
            }
        }

        const uses_extension_host = self.ext_host != null and handleRpcProxyUsesExtensionHost(body);
        if (uses_extension_host) self.ext_host_mutex.lock();
        defer {
            if (uses_extension_host) {
                // Recovery mutates the persistent engine. Keep the same mutex
                // held until recovery completes so another extension request
                // cannot race restartHost or observe a half-initialized child.
                if (self.ext_host) |ext_host| ext_host.recoverIfRequested();
                self.ext_host_mutex.unlock();
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/tasks\"")) {
            const id_str = extractJsonRpcId(body) orelse "null";
            const ext_host = self.ext_host orelse return error.ExtensionHostUnavailable;
            try ext_host.activateTaskTypes(null);
            const engine_result = try ext_host.engine.evalString(
                "Promise.resolve(globalThis._wizpContext.tasks.fetchTasks()).then(t => JSON.stringify(t))",
                "tasks",
            );
            defer ext_host.allocator.free(engine_result);
            const raw = std.mem.trim(u8, stripEngineResult(engine_result), " \t\r\n");
            const result_json = if (raw.len > 0) raw else "[]";
            const response_body = try ContentLength.resultResponse(self.allocator, id_str, result_json);
            defer self.allocator.free(response_body);
            const response = try std.fmt.allocPrint(
                self.allocator,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}",
                .{ response_body.len, response_body },
            );
            defer self.allocator.free(response);
            stream.writeAll(response) catch {};
            return;
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/uiReply\"")) {
            const ext_host = self.ext_host orelse return error.ExtensionHostUnavailable;
            const js = try std.fmt.allocPrint(
                self.allocator,
                "let req = {s}; if (globalThis._wizp_uiResolvers && globalThis._wizp_uiResolvers[req.id]) {{ globalThis._wizp_uiResolvers[req.id](req.value); delete globalThis._wizp_uiResolvers[req.id]; }}",
                .{body},
            );
            defer self.allocator.free(js);
            try ext_host.engine.evalVoid(js, "uiReply");
            const response_body = try ContentLength.resultResponse(self.allocator, extractJsonRpcId(body) orelse "null", "true");
            defer self.allocator.free(response_body);
            const response = try std.fmt.allocPrint(
                self.allocator,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}",
                .{ response_body.len, response_body },
            );
            defer self.allocator.free(response);
            stream.writeAll(response) catch {};
            return;
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/hostStatus\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.hostStatusRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }
        if (rpcMethodMatches(body, "\"method\":\"extension/crashHost\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.crashHostRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/restartHost\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.restartHostRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/commands\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.commandsRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/registeredCommands\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.registeredCommandsRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/menus\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.menusRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/keybindings\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.keybindingsRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/contributionSnapshot\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.contributionSnapshotRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/configuration\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.configurationRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/languageContributions\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.languageContributionsRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/languageRuntimePlan\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.languageRuntimePlanRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/textMateRuntimeSmoke\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.textMateRuntimeSmokeRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/viewsContainers\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.viewsContainersRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/views\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.viewsRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/viewsWelcome\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.viewsWelcomeRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/diagnostics\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.diagnosticsRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/debugState\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.debugStateRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/decorations\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.decorationsRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/codeLenses\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.codeLensesRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/inlayHints\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.inlayHintsRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/semanticTokens\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.semanticTokensRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/foldingRanges\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.foldingRangesRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/languageProviders\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.languageProvidersRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/execute\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.executeCommandRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/activationErrors\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.activationErrorsRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/applySaveParticipants\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.applySaveParticipantsRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/commandResults\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.commandResultsRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/runtimeProcesses\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.runtimeProcessesRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/updateConfiguration\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.updateConfigurationRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/cspellRuntimeProbe\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.cspellRuntimeProbeRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/activeTextDocument\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.activeTextDocumentRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/clearMementoCache\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.clearMementoCacheRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/deactivate\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.deactivateExtensionRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/activateByEvent\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.activateByEventRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/fileSystemAccess\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.fileSystemAccessRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/debugLifecycle\"")) {
            if (self.ext_host) |ext_host| {
                const json_body = try ext_host.debugLifecycleRpc(body);
                defer ext_host.allocator.free(json_body);
                const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ json_body.len, json_body });
                defer self.allocator.free(response);
                stream.writeAll(response) catch |err| {
                    std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
                };
                return;
            }
        }

        // Intercept extension/resolveWebviewView for ExtensionHost
        if (rpcMethodMatches(body, "\"method\":\"extension/resolveWebviewView\"")) {
            if (self.ext_host) |ext_host| {
                if (std.mem.indexOf(u8, body, "\"viewId\":\"")) |start_idx| {
                    const id_start = start_idx + 10;
                    if (std.mem.indexOfScalarPos(u8, body, id_start, '"')) |id_end| {
                        const viewId = body[id_start..id_end];
                        const view_id_json = try jsonStringAlloc(self.allocator, viewId);
                        defer self.allocator.free(view_id_json);
                        const js = try std.fmt.allocPrint(self.allocator, "globalThis._wizp_resolveWebviewView({s})", .{view_id_json});
                        defer self.allocator.free(js);
                        try ext_host.engine.evalVoid(js, "resolveWebviewView");
                    }
                }
                // No direct response here: the daemon fallback below returns
                // the JSON-RPC acknowledgement after the host dispatch.
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"webview/receiveMessage\"") or rpcMethodMatches(body, "\"method\":\"webview.receiveMessage\"")) {
            if (self.ext_host) |ext_host| {
                const js = try std.fmt.allocPrint(self.allocator, "let req = {s}; let params = req.params || req; if (globalThis._wizp_receiveWebviewMessage) globalThis._wizp_receiveWebviewMessage(params.id, params.message);", .{body});
                defer self.allocator.free(js);
                try ext_host.engine.evalVoid(js, "receiveWebviewMessage");
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/invokeCompletion\"")) {
            if (self.ext_host) |ext_host| {
                const js = try std.fmt.allocPrint(self.allocator, "let req = {s}; globalThis.WIZP_invokeCompletion(req.reqId, req.uri, req.line, req.col);", .{body});
                defer self.allocator.free(js);
                try ext_host.engine.evalVoid(js, "invokeCompletion");
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/invokeHover\"")) {
            if (self.ext_host) |ext_host| {
                const js = try std.fmt.allocPrint(self.allocator, "let req = {s}; globalThis.WIZP_invokeHover(req.reqId, req.uri, req.line, req.col);", .{body});
                defer self.allocator.free(js);
                try ext_host.engine.evalVoid(js, "invokeHover");
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/invokeDefinition\"")) {
            if (self.ext_host) |ext_host| {
                const js = try std.fmt.allocPrint(self.allocator, "let req = {s}; globalThis.WIZP_invokeDefinition(req.reqId, req.uri, req.line, req.col);", .{body});
                defer self.allocator.free(js);
                try ext_host.engine.evalVoid(js, "invokeDefinition");
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/invokeReference\"")) {
            if (self.ext_host) |ext_host| {
                const js = try std.fmt.allocPrint(self.allocator, "let req = {s}; globalThis.WIZP_invokeReference(req.reqId, req.uri, req.line, req.col);", .{body});
                defer self.allocator.free(js);
                try ext_host.engine.evalVoid(js, "invokeReference");
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/invokeRename\"")) {
            if (self.ext_host) |ext_host| {
                const js = try std.fmt.allocPrint(self.allocator, "let req = {s}; globalThis.WIZP_invokeRename(req.reqId, req.uri, req.line, req.col, req.newName);", .{body});
                defer self.allocator.free(js);
                try ext_host.engine.evalVoid(js, "invokeRename");
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/invokeCodeAction\"")) {
            if (self.ext_host) |ext_host| {
                if (ext_host.extensions.count() > 0) {
                    const js = try std.fmt.allocPrint(self.allocator, "let req = {s}; globalThis.WIZP_invokeCodeAction(req.reqId, req.uri, req.rangeStartLine, req.rangeStartCol, req.rangeEndLine, req.rangeEndCol);", .{body});
                    defer self.allocator.free(js);
                    try ext_host.engine.evalVoid(js, "invokeCodeAction");
                }
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/invokeSignatureHelp\"")) {
            if (self.ext_host) |ext_host| {
                if (ext_host.extensions.count() > 0) {
                    const js = try std.fmt.allocPrint(self.allocator, "let req = {s}; globalThis.WIZP_invokeSignatureHelp(req.reqId, req.uri, req.line, req.col);", .{body});
                    defer self.allocator.free(js);
                    try ext_host.engine.evalVoid(js, "invokeSignatureHelp");
                }
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"extension/didChangeTextDocument\"")) {
            if (self.ext_host) |ext_host| {
                // To avoid JSON parsing limits, we pass the raw body to JS and let JS parse the `changes` array
                if (ext_host.extensions.count() > 0) {
                    const js = try std.fmt.allocPrint(self.allocator, "let req = {s}; globalThis.WIZP_onDidChangeTextDocument(req.uri, req.changes);", .{body});
                    defer self.allocator.free(js);
                    try ext_host.engine.evalVoid(js, "didChangeTextDocument");
                }
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"workspace/setFolders\"")) {
            const id_str = extractJsonRpcId(body) orelse "null";
            const folder_paths_json = try workspaceFolderPathsJson(self.allocator, body);
            defer self.allocator.free(folder_paths_json);
            const fallback_result = try workspaceFoldersResultJson(self.allocator, body);
            defer self.allocator.free(fallback_result);
            const cached_folders = try self.allocator.dupe(u8, fallback_result);
            self.cache_mutex.lock();
            if (self.workspace_folders_json) |old| self.allocator.free(old);
            self.workspace_folders_json = cached_folders;
            self.cache_mutex.unlock();
            if (self.ext_host) |ext_host| {
                const js = try std.fmt.allocPrint(self.allocator, "(function(){{let folderPaths={s};let mapped=folderPaths.map((pathValue,index)=>{{let path=String(pathValue||'');return {{uri:globalThis._wizpContext.Uri.file(path),name:path.split('/').pop()||path,path:path,index:index}};}});if(globalThis._wizpContext){{globalThis._wizpContext.workspace.workspaceFolders=mapped;if(globalThis._wizp_onDidChangeWorkspaceFolders)globalThis._wizp_onDidChangeWorkspaceFolders({{added:mapped,removed:[]}});}}return {{folders:mapped.map(f=>({{uri:f.uri,name:f.name,path:f.path,index:f.index}}))}};}})()", .{folder_paths_json});
                defer self.allocator.free(js);
                const engine_result = try ext_host.engine.evalString(js, "setWorkspaceFolders");
                defer ext_host.allocator.free(engine_result);
            }
            const daemon_response = blk: {
                self.daemon_mutex.lock();
                defer self.daemon_mutex.unlock();
                const daemon_in = self.daemon_stdin orelse break :blk null;
                if (self.daemon_stdout == null) break :blk null;
                var header_buf: [64]u8 = undefined;
                const header = std.fmt.bufPrint(&header_buf, "Content-Length: {}\r\n\r\n", .{body.len}) catch break :blk null;
                runtime.writeAll(daemon_in, header) catch |err| {
                    std.debug.print("[WIZP HTTP] workspace/setFolders daemon header write failed: {}\n", .{err});
                    self.invalidateDaemon();
                    break :blk null;
                };
                runtime.writeAll(daemon_in, body) catch |err| {
                    std.debug.print("[WIZP HTTP] workspace/setFolders daemon body write failed: {}\n", .{err});
                    self.invalidateDaemon();
                    break :blk null;
                };
                break :blk self.readDaemonResponse(ContentLength.default_read_timeout_ms, true) catch |err| {
                    std.debug.print("[WIZP HTTP] workspace/setFolders daemon response failed: {}\n", .{err});
                    break :blk null;
                };
            };
            const response_body = daemon_response orelse try ContentLength.resultResponse(self.allocator, id_str, fallback_result);
            defer self.allocator.free(response_body);
            const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{s}", .{ response_body.len, response_body });
            defer self.allocator.free(response);
            stream.writeAll(response) catch |err| {
                std.debug.print("[WIZP HTTP] response write failed: {}\n", .{err});
            };
            return;
        }

        if (rpcMethodMatches(body, "\"method\":\"window/setActiveTextEditor\"")) {
            if (self.ext_host) |ext_host| {
                if (std.mem.indexOf(u8, body, "\"path\":\"")) |start_idx| {
                    const id_start = start_idx + 8;
                    if (std.mem.indexOfScalarPos(u8, body, id_start, '"')) |id_end| {
                        const filePath = body[id_start..id_end];
                        const js = try std.fmt.allocPrint(self.allocator, "if (globalThis._wizpContext) {{ globalThis._wizpContext.window.activeTextEditor = {{ document: {{ uri: globalThis._wizpContext.Uri.file('{s}'), fileName: '{s}', languageId: 'plaintext', version: 1, getText: function(){{return '';}} }} }}; if (globalThis._wizp_onDidChangeActiveTextEditor) globalThis._wizp_onDidChangeActiveTextEditor(globalThis._wizpContext.window.activeTextEditor); }}", .{ filePath, filePath });
                        defer self.allocator.free(js);
                        try ext_host.engine.evalVoid(js, "setActiveTextEditor");
                    }
                }
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
                return;
            }
        }

        if (rpcMethodMatches(body, "\"method\":\"window/onDidSaveTextEditor\"")) {
            if (self.ext_host) |ext_host| {
                if (std.mem.indexOf(u8, body, "\"path\":\"")) |start_idx| {
                    const id_start = start_idx + 8;
                    if (std.mem.indexOfScalarPos(u8, body, id_start, '"')) |id_end| {
                        const filePath = body[id_start..id_end];
                        const js = try std.fmt.allocPrint(self.allocator, "if (globalThis._wizpContext && globalThis._wizp_onDidSaveTextDocument) {{ globalThis._wizp_onDidSaveTextDocument({{ uri: globalThis._wizpContext.Uri.file('{s}'), fileName: '{s}', languageId: 'plaintext', version: 1, getText: function(){{return '';}} }}); }}", .{ filePath, filePath });
                        defer self.allocator.free(js);
                        try ext_host.engine.evalVoid(js, "onDidSaveTextDocument");
                    }
                }
                _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"success\":true}") catch {};
                return;
            }
        }
        const proxy_method = EditorJson.escapedStringParam(body, "method") orelse "";
        if (std.mem.eql(u8, proxy_method, "file/list")) {
            const json_body = try directFileListResponse(self.allocator, body);
            defer self.allocator.free(json_body);
            var http_header_buf: [256]u8 = undefined;
            const http_header = try std.fmt.bufPrint(
                &http_header_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                .{json_body.len},
            );
            try stream.writeAll(http_header);
            try stream.writeAll(json_body);
            return;
        }
        if (std.mem.eql(u8, proxy_method, "file/create") or
            std.mem.eql(u8, proxy_method, "file/mkdir") or
            std.mem.eql(u8, proxy_method, "file/rename"))
        {
            const json_body = try directFileMutationResponse(self.allocator, proxy_method, body);
            defer self.allocator.free(json_body);
            var http_header_buf: [256]u8 = undefined;
            const http_header = try std.fmt.bufPrint(
                &http_header_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                .{json_body.len},
            );
            try stream.writeAll(http_header);
            try stream.writeAll(json_body);
            return;
        }
        if (std.mem.eql(u8, proxy_method, "file/read")) {
            const read_result = directFileReadResponse(self.allocator, body);
            const json_body = read_result catch |err| {
                _ = stream.write("HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n") catch {};
                std.debug.print("[WIZP HTTP] RPC file read error: {}\n", .{err});
                return;
            };
            defer self.allocator.free(json_body);
            var http_header_buf: [256]u8 = undefined;
            const http_header = try std.fmt.bufPrint(
                &http_header_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                .{json_body.len},
            );
            try stream.writeAll(http_header);
            try stream.writeAll(json_body);
            return;
        }
        if (std.mem.eql(u8, proxy_method, "file/save")) {
            const json_body = try directFileSaveResponse(self.allocator, body);
            defer self.allocator.free(json_body);
            var http_header_buf: [256]u8 = undefined;
            const http_header = try std.fmt.bufPrint(
                &http_header_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                .{json_body.len},
            );
            try stream.writeAll(http_header);
            try stream.writeAll(json_body);
            return;
        }

        // Terminal polling is best effort. Never let a burst of idle reads
        // queue behind a control RPC or hold the daemon mutex for its full wait.
        const is_terminal_read = std.mem.eql(u8, proxy_method, "terminal/read");
        if (!is_terminal_read) {
            _ = self.daemon_control_waiters.fetchAdd(1, .seq_cst);
            defer _ = self.daemon_control_waiters.fetchSub(1, .seq_cst);
            if (isFastControlRpc(body)) {
                var acquired = false;
                for (0..100) |_| {
                    if (self.daemon_mutex.tryLock()) {
                        acquired = true;
                        break;
                    }
                    runtime.sleepNanoseconds(2 * std.time.ns_per_ms);
                }
                if (!acquired) return error.DaemonBusy;
            } else {
                self.daemon_mutex.lock();
            }
        } else if (self.daemon_control_waiters.load(.seq_cst) != 0 or !self.daemon_mutex.tryLock()) {
            const id_str = extractJsonRpcId(body) orelse "null";
            const json_body = try ContentLength.resultResponse(self.allocator, id_str, "{\"data\":\"\"}");
            defer self.allocator.free(json_body);
            var http_header_buf: [256]u8 = undefined;
            const http_header = try std.fmt.bufPrint(
                &http_header_buf,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                .{json_body.len},
            );
            try stream.writeAll(http_header);
            try stream.writeAll(json_body);
            return;
        }
        defer self.daemon_mutex.unlock();
        if (self.daemon_stdin == null or self.daemon_stdout == null) {
            try stream.writeAll("HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"error\":\"daemon not running\"}");
            return;
        }

        const daemon_in = self.daemon_stdin.?;

        var cl_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&cl_buf, "Content-Length: {}\r\n\r\n", .{body.len}) catch return;
        // PTY reads are bounded to 20 ms in the daemon. Keep the proxy
        // deadline short enough that an orphaned terminal request cannot
        // hold the shared daemon mutex ahead of control RPCs.
        const read_timeout_ms: i32 = if (is_terminal_read) 1_000 else ContentLength.default_read_timeout_ms;
        const json_body = blk: {
            errdefer {
                if (!is_terminal_read) self.invalidateDaemon();
            }
            runtime.writeAll(daemon_in, header) catch |err| {
                std.debug.print("[WIZP HTTP] {s} daemon header write failed: {}\n", .{ proxy_method, err });
                return err;
            };
            runtime.writeAll(daemon_in, body) catch |err| {
                std.debug.print("[WIZP HTTP] {s} daemon body write failed: {}\n", .{ proxy_method, err });
                return err;
            };
            break :blk self.readDaemonResponse(read_timeout_ms, !is_terminal_read) catch |err| {
                if (!is_terminal_read) {
                    std.debug.print("[WIZP HTTP] {s} daemon response failed: {}\n", .{ proxy_method, err });
                    return err;
                }
                const id_str = extractJsonRpcId(body) orelse "null";
                break :blk try ContentLength.resultResponse(self.allocator, id_str, "{\"data\":\"\"}");
            };
        };
        defer self.allocator.free(json_body);
        var http_header_buf: [256]u8 = undefined;
        const http_header = try std.fmt.bufPrint(
            &http_header_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
            .{json_body.len},
        );
        try stream.writeAll(http_header);
        try stream.writeAll(json_body);
    }

    fn probeDaemon(self: *EmbeddedServer) !bool {
        // Caller holds daemon_mutex. A listening HTTP socket or non-null pipe does
        // not demonstrate a live protocol daemon.
        const daemon_in = self.daemon_stdin orelse return false;
        if (self.daemon_stdout == null) return false;
        errdefer self.invalidateDaemon();
        const request = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"workspace/getFolders\"}";
        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {}\r\n\r\n", .{request.len});
        try runtime.writeAll(daemon_in, header);
        try runtime.writeAll(daemon_in, request);
        const response = self.readDaemonResponse(ContentLength.default_read_timeout_ms, true) catch {
            return false;
        };
        defer self.allocator.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const id = parsed.value.object.get("id") orelse return false;
        return id == .integer and id.integer == 0 and
            parsed.value.object.contains("result") and !parsed.value.object.contains("error");
    }

    fn invalidateDaemon(self: *EmbeddedServer) void {
        self.daemon_stdin = null;
        self.daemon_stdout = null;
        // The packaged host supervises the HTTP owner, not just its listener.
        // Propagate a lost/desynchronized RPC daemon to that owner immediately.
        if (runtime.getEnvVarOwned(self.allocator, "WIZP_NATIVE_SESSION_OWNER")) |owner| {
            defer self.allocator.free(owner);
            if (std.mem.eql(u8, owner, "1")) std.process.exit(1);
        } else |_| {}
    }

    // Caller holds daemon_mutex; never return a partial frame to another request.
    fn readDaemonResponse(self: *EmbeddedServer, timeout_ms: i32, invalidate_on_error: bool) ![]u8 {
        const stdout = self.daemon_stdout orelse return error.DaemonDisconnected;
        errdefer if (invalidate_on_error) self.invalidateDaemon();
        var header_buf: [ContentLength.max_header_length]u8 = undefined;
        var header_len: usize = 0;
        while (true) {
            if (header_len == header_buf.len) return error.HeaderTooLarge;
            try ContentLength.waitReadable(stdout.handle, timeout_ms);
            const n = try runtime.read(stdout, header_buf[header_len .. header_len + 1]);
            if (n == 0) return error.DaemonDisconnected;
            header_len += n;
            if (header_len >= 4 and std.mem.eql(u8, header_buf[header_len - 4 .. header_len], "\r\n\r\n")) break;
        }
        const content_length = try ContentLength.parseHeader(header_buf[0..header_len]);
        const body = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(body);
        var received: usize = 0;
        while (received < body.len) {
            try ContentLength.waitReadable(stdout.handle, timeout_ms);
            const n = try runtime.read(stdout, body[received..]);
            if (n == 0) return error.DaemonDisconnected;
            received += n;
        }
        return body;
    }

    fn handleTerminalStream(self: *EmbeddedServer, stream: *LegacyStream) void {
        // Send chunked transfer encoding headers.
        // WebKit does NOT buffer chunked responses the same way it buffers EventSource,
        // so this avoids the ~3s delivery latency for high-throughput TUI programs.
        const header =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "Cache-Control: no-cache, no-store, must-revalidate\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n";
        _ = stream.writeAll(header) catch return;

        const rpc_req = "{\"jsonrpc\":\"2.0\",\"method\":\"terminal/read\",\"id\":1}";

        var idle_ticks: u32 = 0;

        while (self.running) {
            self.daemon_mutex.lock();

            if (self.daemon_stdin == null or self.daemon_stdout == null) {
                self.daemon_mutex.unlock();
                runtime.sleepNanoseconds(100 * std.time.ns_per_ms);
                continue;
            }

            var cl_buf: [64]u8 = undefined;
            const cl_hdr = std.fmt.bufPrint(&cl_buf, "Content-Length: {}\r\n\r\n", .{rpc_req.len}) catch {
                self.daemon_mutex.unlock();
                continue;
            };
            _ = runtime.writeAll(self.daemon_stdin.?, cl_hdr) catch {
                self.daemon_mutex.unlock();
                continue;
            };
            _ = runtime.writeAll(self.daemon_stdin.?, rpc_req) catch {
                self.daemon_mutex.unlock();
                continue;
            };

            const json_body = self.readDaemonResponse(1_000, false) catch {
                self.daemon_mutex.unlock();
                return;
            };
            self.daemon_mutex.unlock();
            defer self.allocator.free(json_body);

            var data_b64: []const u8 = "";
            if (std.mem.indexOf(u8, json_body, "\"data\":\"")) |d_start| {
                const v_start = d_start + 8;
                if (std.mem.indexOfScalarPos(u8, json_body, v_start, '"')) |v_end| {
                    data_b64 = json_body[v_start..v_end];
                }
            }

            if (data_b64.len > 0) {
                const expected_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64) catch continue;
                const decoded = self.allocator.alloc(u8, expected_len) catch return;
                defer self.allocator.free(decoded);
                std.base64.standard.Decoder.decode(decoded, data_b64) catch continue;
                var hex_buf: [16]u8 = undefined;
                const hex_len = std.fmt.bufPrint(&hex_buf, "{x}", .{decoded.len}) catch continue;
                _ = stream.writeAll(hex_len) catch return;
                _ = stream.writeAll("\r\n") catch return;
                _ = stream.writeAll(decoded) catch return;
                _ = stream.writeAll("\r\n") catch return;
                idle_ticks = 0;
            } else {
                idle_ticks += 1;
                if (idle_ticks < 10) {
                    runtime.sleepNanoseconds(50 * std.time.ns_per_ms);
                } else if (idle_ticks < 50) {
                    runtime.sleepNanoseconds(100 * std.time.ns_per_ms);
                } else {
                    runtime.sleepNanoseconds(200 * std.time.ns_per_ms);
                }
            }
        }

        _ = stream.writeAll("0\r\n\r\n") catch {};
    }

    fn handleWindowAction(self: *EmbeddedServer, stream: *LegacyStream, request: []const u8) !void {
        const body = extractBody(request) orelse {
            _ = stream.write("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\nMissing body") catch {};
            return;
        };
        std.debug.print("[WIZP Window] body = \"{s}\"\n", .{body});
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{}) catch {
            _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"ok\":true}") catch {};
            return;
        };
        const obj = parsed.value.object;
        if (obj.get("close")) |_| {
            _ = stream.write("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"ok\":true}") catch {};
        }
        _ = stream.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{\"ok\":true}") catch {};
    }

    fn serveFile(self: *EmbeddedServer, path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            if (self.serveFrontendFile("/index.html")) |content| {
                return content;
            }
            return index_html;
        }
        if (std.mem.eql(u8, path, "/favicon.svg")) return favicon_svg;
        if (std.mem.startsWith(u8, path, "/assets/favicon-") and std.mem.endsWith(u8, path, ".svg")) return favicon_svg;

        if (!frontend_bundled) {
            // Development raw TypeScript (only works under Bun or with a bundler dev server)
            if (std.mem.eql(u8, path, "/editor.ts")) return editor_ts;
            if (std.mem.eql(u8, path, "/bridge.ts")) return bridge_ts;
            if (std.mem.eql(u8, path, "/terminal.ts")) return terminal_ts;
            if (std.mem.eql(u8, path, "/src/eventbus.ts")) return eventbus_ts;
            if (std.mem.eql(u8, path, "/src/explorer.ts")) return explorer_ts;
            if (std.mem.eql(u8, path, "/src/git.ts")) return git_ts;
            if (std.mem.eql(u8, path, "/src/palette.ts")) return palette_ts;
            if (std.mem.eql(u8, path, "/src/search.ts")) return search_ts;
            if (std.mem.eql(u8, path, "/src/settings.ts")) return settings_ts;
            if (std.mem.eql(u8, path, "/src/sidebarViews.ts")) return sidebarViews_ts;
            if (std.mem.eql(u8, path, "/src/utils.ts")) return utils_ts;
        }

        if (std.mem.eql(u8, path, "/xterm.css")) return xterm_css;
        if (std.mem.eql(u8, path, "/codicon.css")) return codicon_css;
        if (std.mem.eql(u8, path, "/codicon.ttf")) return codicon_ttf;

        // Check in-memory cache first. Keep the lock scoped so disk loaders can
        // lazily detect directories without trying to re-enter this mutex.
        self.cache_mutex.lock();
        if (self.file_cache.get(path)) |cached| {
            self.cache_mutex.unlock();
            return cached;
        }
        self.cache_mutex.unlock();

        // Monaco editor core (served from standalone monaco-vs/ during dev, or
        // from the packaged frontend-dist/monaco tree for self-contained builds).
        if (std.mem.startsWith(u8, path, "/monaco/")) {
            if (self.serveMonacoFile(path)) |content| {
                const path_copy = self.allocator.dupe(u8, path) catch return content;
                self.cache_mutex.lock();
                defer self.cache_mutex.unlock();
                self.file_cache.put(self.allocator, path_copy, content) catch {
                    self.allocator.free(path_copy);
                };
                return content;
            }
            return null;
        }

        if (self.serveFrontendFile(path)) |content| {
            const path_copy = self.allocator.dupe(u8, path) catch return content;
            self.cache_mutex.lock();
            defer self.cache_mutex.unlock();
            self.file_cache.put(self.allocator, path_copy, content) catch {
                self.allocator.free(path_copy);
            };
            return content;
        }

        return null;
    }

    fn ensureDirs(self: *EmbeddedServer) void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();
        if (self.dirs_detected) return;
        self.dirs_detected = true;

        var monaco_dir: ?[]const u8 = null;
        var search_dirs: [7][]const u8 = undefined;
        var search_count: usize = 0;

        search_dirs[search_count] = ".";
        search_count += 1;

        if (runtime_paths.source_root.len > 0) {
            search_dirs[search_count] = runtime_paths.source_root;
            search_count += 1;
        }

        if (std.process.executablePathAlloc(runtime.io(), self.allocator)) |exe_path| {
            if (std.fs.path.dirname(exe_path)) |d| {
                search_dirs[search_count] = self.allocator.dupe(u8, d) catch "";
                search_count += 1;
                if (std.fs.path.dirname(d)) |parent| {
                    search_dirs[search_count] = self.allocator.dupe(u8, parent) catch "";
                    search_count += 1;
                    if (std.fs.path.dirname(parent)) |grandparent| {
                        search_dirs[search_count] = self.allocator.dupe(u8, grandparent) catch "";
                        search_count += 1;
                    }
                }
            }
            self.allocator.free(exe_path);
        } else |_| {}

        search_dirs[search_count] = self.allocator.dupe(u8, "zig-out") catch "";
        search_count += 1;

        for (search_dirs[0..search_count]) |dir| {
            if (dir.len == 0) continue;
            const monaco_candidates = [_][]const u8{
                "monaco-vs",
                "frontend/dist/monaco",
                "frontend-dist/monaco",
            };
            for (monaco_candidates) |monaco_candidate| {
                const candidate = std.fs.path.join(self.allocator, &.{ dir, monaco_candidate }) catch continue;
                if (openDirAny(candidate)) |opened| {
                    var opened_dir = opened;
                    opened_dir.close(runtime.io());
                    monaco_dir = candidate;
                    break;
                } else |_| {
                    self.allocator.free(candidate);
                }
            }
            if (monaco_dir != null) break;
        }

        var fe_dir_over: ?[]const u8 = null;
        for (search_dirs[0..search_count]) |dir| {
            if (dir.len == 0) continue;
            const frontend_candidates = [_][]const u8{
                "frontend/dist",
                "frontend-dist",
            };
            for (frontend_candidates) |frontend_candidate| {
                const fe_candidate = std.fs.path.join(self.allocator, &.{ dir, frontend_candidate }) catch continue;
                if (dirExists(fe_candidate)) {
                    fe_dir_over = fe_candidate;
                    break;
                } else {
                    self.allocator.free(fe_candidate);
                }
            }
            if (fe_dir_over != null) break;
        }

        for (search_dirs[2..search_count]) |dir| {
            if (dir.len > 0) self.allocator.free(dir);
        }

        self.monaco_dir = monaco_dir;
        self.frontend_dir = fe_dir_over;
    }

    fn serveFrontendFile(self: *EmbeddedServer, path: []const u8) ?[]const u8 {
        self.ensureDirs();
        const fe_dir = self.frontend_dir orelse return null;
        const rel = if (path.len > 0 and path[0] == '/') path[1..] else path;
        if (rel.len == 0 or std.mem.indexOf(u8, rel, "..") != null) return null;
        const full_path = std.fs.path.join(self.allocator, &.{ fe_dir, rel }) catch return null;
        defer self.allocator.free(full_path);
        return self.readFileAny(full_path, 10 << 20);
    }

    fn serveMonacoFile(self: *EmbeddedServer, path: []const u8) ?[]const u8 {
        self.ensureDirs();
        const monaco_dir = self.monaco_dir orelse return null;
        const relative = path["/monaco/".len..];
        if (relative.len == 0) return null;
        const full_path = std.fs.path.join(self.allocator, &.{ monaco_dir, relative }) catch return null;
        defer self.allocator.free(full_path);
        return self.readFileAny(full_path, 10 * 1024 * 1024);
    }

    fn openDirAny(path: []const u8) !std.Io.Dir {
        if (std.fs.path.isAbsolute(path)) {
            return std.Io.Dir.openDirAbsolute(runtime.io(), path, .{});
        }
        return std.Io.Dir.cwd().openDir(runtime.io(), path, .{});
    }

    fn dirExists(path: []const u8) bool {
        if (openDirAny(path)) |dir| {
            var opened = dir;
            opened.close(runtime.io());
            return true;
        } else |_| {
            return false;
        }
    }

    fn readFileAny(self: *EmbeddedServer, path: []const u8, max_bytes: usize) ?[]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(
            runtime.io(),
            path,
            self.allocator,
            .limited(max_bytes),
        ) catch null;
    }

    fn mimeType(path: []const u8) []const u8 {
        if (std.mem.eql(u8, path, "/")) return "text/html; charset=utf-8";
        if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
        if (std.mem.endsWith(u8, path, ".ts")) return "application/javascript; charset=utf-8";
        if (std.mem.endsWith(u8, path, ".js")) return "application/javascript; charset=utf-8";
        if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
        if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
        if (std.mem.endsWith(u8, path, ".ttf")) return "font/truetype";
        if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
        if (std.mem.endsWith(u8, path, ".map")) return "application/json; charset=utf-8";
        if (std.mem.endsWith(u8, path, ".woff")) return "font/woff";
        if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
        return "text/plain; charset=utf-8";
    }

    fn extractMethod(request: []const u8) []const u8 {
        const end = std.mem.indexOfScalar(u8, request, ' ') orelse return "GET";
        return request[0..end];
    }

    fn extractTarget(request: []const u8) []const u8 {
        const first_space = std.mem.indexOfScalar(u8, request, ' ') orelse return "/";
        const target_start = first_space + 1;
        const target_end = std.mem.indexOfScalarPos(u8, request, target_start, ' ') orelse request.len;
        if (target_end <= target_start) return "/";
        return request[target_start..target_end];
    }

    fn extractPath(request: []const u8) []const u8 {
        const first_space = std.mem.indexOfScalar(u8, request, ' ') orelse return "/";
        const path_start = first_space + 1;
        const path_end = std.mem.indexOfScalarPos(u8, request, path_start, ' ') orelse request.len;
        if (path_end <= path_start) return "/";
        var path = request[path_start..path_end];
        // Strip query string and fragment
        if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
        if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];
        return path;
    }

    fn queryParamValue(target: []const u8, key: []const u8) ?[]const u8 {
        const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
        var query = target[query_start + 1 ..];
        if (std.mem.indexOfScalar(u8, query, '#')) |fragment| query = query[0..fragment];
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
            } else if (std.mem.eql(u8, pair, key)) {
                return "";
            }
        }
        return null;
    }

    fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var out = std.array_list.Managed(u8).init(allocator);
        defer out.deinit();

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '%' and i + 2 < input.len) {
                const hex = input[i + 1 .. i + 3];
                const byte = std.fmt.parseInt(u8, hex, 16) catch {
                    try out.append(input[i]);
                    i += 1;
                    continue;
                };
                try out.append(byte);
                i += 3;
            } else {
                try out.append(input[i]);
                i += 1;
            }
        }
        return out.toOwnedSlice();
    }

    fn webviewResourceAllowed(self: *EmbeddedServer, ext_host: *ExtensionHost, id: []const u8, resource_path: []const u8) bool {
        const id_json = jsonStringAlloc(self.allocator, id) catch return false;
        defer self.allocator.free(id_json);
        const path_json = jsonStringAlloc(self.allocator, resource_path) catch return false;
        defer self.allocator.free(path_json);
        const js = std.fmt.allocPrint(
            self.allocator,
            "!!(globalThis._wizpCanServeWebviewResource && globalThis._wizpCanServeWebviewResource({s}, {s}))",
            .{ id_json, path_json },
        ) catch return false;
        defer self.allocator.free(js);
        const result = ext_host.engine.evalString(js, "webviewResourceAllowed") catch return false;
        defer ext_host.allocator.free(result);
        const raw = std.mem.trim(u8, stripEngineResult(result), " \t\r\n");
        return std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1");
    }

    fn extractBody(request: []const u8) ?[]const u8 {
        const hdr_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return null;
        const body_start = hdr_end + 4;
        if (body_start >= request.len) return null;
        if (contentLengthValueStart(request[0..hdr_end])) |cl_val_start| {
            const cl_val_end = std.mem.indexOfScalarPos(u8, request, cl_val_start, '\r') orelse hdr_end;
            const cl_str = std.mem.trim(u8, request[cl_val_start..cl_val_end], " \t");
            const cl = std.fmt.parseInt(usize, cl_str, 10) catch return null;
            if (request.len >= body_start + cl) {
                return request[body_start .. body_start + cl];
            }
        }
        if (request.len > body_start) return request[body_start..];
        return null;
    }

    fn extractJsonRpcId(json: []const u8) ?[]const u8 {
        return EditorJson.value(json, "id");
    }
    fn directReadAlloc(allocator: Allocator, path: []const u8, limit: usize) ![]u8 {
        return @import("runtime_016.zig").readFileAlloc(allocator, path, limit);
    }

    fn directFileListResponse(allocator: Allocator, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const escaped_path = EditorJson.escapedStringParam(body, "path") orelse "";
        const dir_path = try EditorJson.unescapeString(allocator, escaped_path);
        defer allocator.free(dir_path);
        var dir = (if (std.fs.path.isAbsolute(dir_path))
            std.Io.Dir.openDirAbsolute(runtime.io(), if (dir_path.len == 0) "." else dir_path, .{ .iterate = true })
        else
            std.Io.Dir.cwd().openDir(runtime.io(), if (dir_path.len == 0) "." else dir_path, .{ .iterate = true })) catch |err| {
            return try directRpcError(allocator, id_str, "list files", err);
        };
        defer dir.close(runtime.io());

        var files: std.Io.Writer.Allocating = .init(allocator);
        defer files.deinit();
        try files.writer.writeAll("[");
        var first = true;
        var iter = dir.iterate();
        while (try iter.next(runtime.io())) |entry| {
            if (!first) try files.writer.writeByte(',');
            first = false;
            const full_path = if (dir_path.len == 0 or std.mem.eql(u8, dir_path, "."))
                try allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(full_path);
            try files.writer.print("{{\"name\":", .{});
            try writeJsonString(&files.writer, entry.name);
            try files.writer.writeAll(",\"path\":");
            try writeJsonString(&files.writer, full_path);
            try files.writer.writeAll(",\"kind\":");
            try writeJsonString(&files.writer, if (entry.kind == .directory) "directory" else "file");
            try files.writer.writeByte('}');
        }
        try files.writer.writeByte(']');

        var response: std.Io.Writer.Allocating = .init(allocator);
        errdefer response.deinit();
        try response.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"files\":{s}}}}}", .{ id_str, files.written() });
        return try response.toOwnedSlice();
    }

    fn directRpcError(allocator: Allocator, id_str: []const u8, operation: []const u8, err: anyerror) ![]u8 {
        return try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32000,\"message\":\"{s} failed: {s}\"}}}}",
            .{ id_str, operation, @errorName(err) },
        );
    }

    fn directFileMutationResponse(allocator: Allocator, method: []const u8, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        if (std.mem.eql(u8, method, "file/create") or std.mem.eql(u8, method, "file/mkdir")) {
            const escaped_path = EditorJson.escapedStringParam(body, "path") orelse
                return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32602,\"message\":\"{s} requires path\"}}}}", .{ id_str, method });
            const path = try EditorJson.unescapeString(allocator, escaped_path);
            defer allocator.free(path);

            if (std.mem.eql(u8, method, "file/create")) {
                const file = (if (std.fs.path.isAbsolute(path))
                    std.Io.Dir.createFileAbsolute(runtime.io(), path, .{ .exclusive = true })
                else
                    std.Io.Dir.cwd().createFile(runtime.io(), path, .{ .exclusive = true })) catch |err| {
                    return try directRpcError(allocator, id_str, "create file", err);
                };
                file.close(runtime.io());
                return try ContentLength.resultResponse(allocator, id_str, "true");
            }
            if (std.mem.eql(u8, method, "file/mkdir")) {
                (if (std.fs.path.isAbsolute(path))
                    std.Io.Dir.createDirAbsolute(runtime.io(), path, .default_dir)
                else
                    std.Io.Dir.cwd().createDir(runtime.io(), path, .default_dir)) catch |err| {
                    return try directRpcError(allocator, id_str, "create folder", err);
                };
                return try ContentLength.resultResponse(allocator, id_str, "true");
            }
        }

        if (std.mem.eql(u8, method, "file/rename")) {
            const escaped_from = EditorJson.escapedStringParam(body, "from") orelse
                return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32602,\"message\":\"file/rename requires from\"}}}}", .{id_str});
            const from = try EditorJson.unescapeString(allocator, escaped_from);
            defer allocator.free(from);
            const escaped_to = EditorJson.escapedStringParam(body, "to") orelse
                return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32602,\"message\":\"file/rename requires to\"}}}}", .{id_str});
            const to = try EditorJson.unescapeString(allocator, escaped_to);
            defer allocator.free(to);
            std.Io.Dir.cwd().rename(from, std.Io.Dir.cwd(), to, runtime.io()) catch |err| {
                return try directRpcError(allocator, id_str, "rename", err);
            };
            return try ContentLength.resultResponse(allocator, id_str, "true");
        }

        return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"unsupported direct file operation\"}}}}", .{id_str});
    }

    fn directFileReadResponse(allocator: Allocator, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const escaped_path = EditorJson.escapedStringParam(body, "path") orelse blk: {
            var search_start: usize = 0;
            break :blk findJsonStringValue(body, "\"path\"", &search_start) orelse
                return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32602,\"message\":\"file/read requires path\"}}}}", .{id_str});
        };
        const path = try EditorJson.unescapeString(allocator, escaped_path);
        defer allocator.free(path);
        const content = directReadAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
            return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32000,\"message\":\"read failed: {s}\"}}}}", .{ id_str, @errorName(err) });
        };
        defer allocator.free(content);
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":", .{id_str});
        try writeJsonString(&out.writer, content);
        try out.writer.writeAll("}}");
        return try out.toOwnedSlice();
    }

    fn directFileSaveResponse(allocator: Allocator, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const escaped_path = EditorJson.escapedStringParam(body, "path") orelse
            return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32602,\"message\":\"file/save requires path\"}}}}", .{id_str});
        const path = try EditorJson.unescapeString(allocator, escaped_path);
        defer allocator.free(path);
        const escaped_content = EditorJson.escapedStringParam(body, "content") orelse
            return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32602,\"message\":\"file/save requires content\"}}}}", .{id_str});
        const content = try EditorJson.unescapeString(allocator, escaped_content);
        defer allocator.free(content);
        runtime.writeFile(path, content) catch |err| {
            return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32000,\"message\":\"{s}\"}}}}", .{ id_str, @errorName(err) });
        };
        return try ContentLength.resultResponse(allocator, id_str, "true");
    }

    fn workspaceFoldersResultJson(allocator: Allocator, body: []const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll("{\"folders\":[");
        var first = true;
        var search_start: usize = 0;
        while (findJsonStringValue(body, "\"path\"", &search_start)) |path| {
            if (!first) try out.writer.writeByte(',');
            first = false;
            try out.writer.writeAll("{\"path\":");
            try writeJsonString(&out.writer, path);
            try out.writer.writeByte('}');
        }
        if (first) {
            search_start = 0;
            while (findJsonStringValue(body, "\"uri\"", &search_start)) |uri| {
                if (!first) try out.writer.writeByte(',');
                first = false;
                try out.writer.writeAll("{\"path\":");
                try writeJsonString(&out.writer, uri);
                try out.writer.writeByte('}');
            }
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }

    fn workspaceFolderPathsJson(allocator: Allocator, body: []const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeByte('[');
        var first = true;
        var search_start: usize = 0;
        while (findJsonStringValue(body, "\"path\"", &search_start)) |path| {
            if (!first) try out.writer.writeByte(',');
            first = false;
            try writeJsonString(&out.writer, path);
        }
        if (first) {
            search_start = 0;
            while (findJsonStringValue(body, "\"uri\"", &search_start)) |uri| {
                if (!first) try out.writer.writeByte(',');
                first = false;
                try writeJsonString(&out.writer, uri);
            }
        }
        try out.writer.writeByte(']');
        return try out.toOwnedSlice();
    }

    fn findJsonStringValue(json: []const u8, key: []const u8, search_start: *usize) ?[]const u8 {
        const key_pos_rel = std.mem.indexOf(u8, json[search_start.*..], key) orelse return null;
        var pos = search_start.* + key_pos_rel + key.len;
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\r' or json[pos] == '\n')) : (pos += 1) {}
        if (pos >= json.len or json[pos] != ':') {
            search_start.* = pos;
            return findJsonStringValue(json, key, search_start);
        }
        pos += 1;
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\r' or json[pos] == '\n')) : (pos += 1) {}
        if (pos >= json.len or json[pos] != '"') {
            search_start.* = pos;
            return findJsonStringValue(json, key, search_start);
        }
        const value_start = pos + 1;
        pos = value_start;
        while (pos < json.len) : (pos += 1) {
            if (json[pos] != '"') continue;
            var escape_count: usize = 0;
            var j = pos;
            while (j > value_start) {
                j -= 1;
                if (json[j] == '\\') escape_count += 1 else break;
            }
            if (escape_count % 2 == 0) {
                search_start.* = pos + 1;
                return json[value_start..pos];
            }
        }
        search_start.* = json.len;
        return null;
    }

    fn writeJsonString(writer: anytype, value: []const u8) !void {
        try ContentLength.writeJsonString(writer, value);
    }

    fn jsonStringAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try writeJsonString(&out.writer, value);
        return try out.toOwnedSlice();
    }

    fn indexOfAsciiNoCase(haystack: []const u8, needle: []const u8) ?usize {
        if (needle.len == 0 or haystack.len < needle.len) return null;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (asciiEqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
        }
        return null;
    }

    fn injectWebviewBootstrap(allocator: std.mem.Allocator, prefix: []const u8, id: []const u8, html: []const u8) ![]u8 {
        const full_id = try std.mem.concat(allocator, u8, &.{ prefix, id });
        defer allocator.free(full_id);
        const full_id_json = try jsonStringAlloc(allocator, full_id);
        defer allocator.free(full_id_json);

        const bootstrap = try std.fmt.allocPrint(
            allocator,
            "<script>(function () {{ const WEBVIEW_ID = {s}; if (window.__wizpAcquireVsCodeApiFor === WEBVIEW_ID) return; let state = null; const vscodeApi = Object.freeze({{ postMessage: function(message) {{ window.parent.postMessage({{ __wizpWebviewClient: true, id: WEBVIEW_ID, message: message }}, '*'); return Promise.resolve(true); }}, setState: function(value) {{ state = value; return value; }}, getState: function() {{ return state; }} }}); window.__wizpAcquireVsCodeApiFor = WEBVIEW_ID; window.acquireVsCodeApi = function() {{ return vscodeApi; }}; window.addEventListener('message', function(event) {{ const payload = event && event.data; if (!payload || payload.__wizpWebviewHost !== true || payload.id !== WEBVIEW_ID) return; window.dispatchEvent(new MessageEvent('message', {{ data: payload.message }})); }}); }}());</script>",
            .{full_id_json},
        );
        defer allocator.free(bootstrap);

        if (indexOfAsciiNoCase(html, "<head")) |head_start| {
            if (std.mem.indexOfScalarPos(u8, html, head_start, '>')) |head_end| {
                return try std.mem.concat(allocator, u8, &.{ html[0 .. head_end + 1], bootstrap, html[head_end + 1 ..] });
            }
        }

        if (indexOfAsciiNoCase(html, "<body")) |body_start| {
            if (std.mem.indexOfScalarPos(u8, html, body_start, '>')) |body_end| {
                return try std.mem.concat(allocator, u8, &.{ html[0 .. body_end + 1], bootstrap, html[body_end + 1 ..] });
            }
        }

        return try std.mem.concat(allocator, u8, &.{ bootstrap, html });
    }

    fn stripEngineResult(result: []const u8) []const u8 {
        if (std.mem.startsWith(u8, result, "RESULT:")) return result["RESULT:".len..];
        return result;
    }

    fn contentLengthValueStart(headers: []const u8) ?usize {
        var line_start: usize = 0;
        while (line_start < headers.len) {
            const line_end = std.mem.indexOfScalarPos(u8, headers, line_start, '\n') orelse headers.len;
            var line = headers[line_start..line_end];
            line = std.mem.trimEnd(u8, line, "\r");
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const name = std.mem.trim(u8, line[0..colon], " \t");
                if (asciiEqlIgnoreCase(name, "content-length")) return line_start + colon + 1;
            }
            if (line_end == headers.len) break;
            line_start = line_end + 1;
        }
        return null;
    }

    fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
            const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
            if (la != lb) return false;
        }
        return true;
    }

    fn extractContentLength(request: []const u8) ?usize {
        const hdr_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return null;
        const cl_val_start = contentLengthValueStart(request[0..hdr_end]) orelse return null;
        const cl_val_end = std.mem.indexOfScalarPos(u8, request, cl_val_start, '\r') orelse hdr_end;
        const cl_str = std.mem.trim(u8, request[cl_val_start..cl_val_end], " \t");
        return std.fmt.parseInt(usize, cl_str, 10) catch null;
    }
};
