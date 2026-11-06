// WIZP All-in-One Binary — Embedded HTTP server + Monaco (local monaco-vs/)
// Self-contained: no Bun, no node_modules, no external dependencies.
// Spawns daemon child process for JSON-RPC backend, embedded HTTP server proxies RPCs.
//
// One mode: embedded HTTP server + browser frontend.
// Opens xdg-open system browser at http://localhost:9876

const std = @import("std");
const builtin = @import("builtin");
const EmbeddedServer = @import("embedded_server.zig").EmbeddedServer;

const ExtensionHost = @import("hub/ExtensionHost.zig").ExtensionHost;
const Allocator = std.mem.Allocator;
const runtime = @import("runtime_016.zig");

pub const MonacoFrontend = struct {
    allocator: Allocator,
    server: EmbeddedServer,
    server_thread: ?std.Thread = null,
    daemon_child: ?std.process.Child = null,
    running: bool,
    port: u16,
    extension_host: ?ExtensionHost = null,

    pub fn init(allocator: Allocator) !MonacoFrontend {
        const port = configuredPort();
        const server = try EmbeddedServer.init(allocator, port, null, null);

        return MonacoFrontend{
            .allocator = allocator,
            .server = server,
            .daemon_child = null,
            .running = true,
            .port = port,
            .extension_host = null,
        };
    }

    fn configuredPort() u16 {
        if (runtime.getEnvVarOwned(std.heap.page_allocator, "WIZP_PORT") catch null) |raw| {
            defer std.heap.page_allocator.free(raw);
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                const parsed = std.fmt.parseInt(u16, trimmed, 10) catch 9876;
                if (parsed > 0) return parsed;
            }
        }
        return 9876;
    }
    fn openBrowser(self: *MonacoFrontend) void {
        if (comptime builtin.os.tag != .windows) return;
        if (runtime.getEnvVarOwned(std.heap.page_allocator, "WIZP_NO_BROWSER") catch null) |value| {
            std.heap.page_allocator.free(value);
            return;
        }
        var url_buffer: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{}", .{self.port}) catch return;
        var child = std.process.spawn(runtime.io(), .{
            .argv = &.{ "cmd.exe", "/c", "start", "", url },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
        _ = child.wait(runtime.io()) catch {};
    }

    pub fn run(self: *MonacoFrontend) !void {
        // Start embedded HTTP server in background thread immediately so the socket accepts requests right away
        self.server_thread = try std.Thread.spawn(.{}, serveLoop, .{self});

        // Now spawn the child daemon process
        const self_exe = try std.process.executablePathAlloc(runtime.io(), self.allocator);
        defer self.allocator.free(self_exe);

        const daemon = try std.process.spawn(runtime.io(), .{
            .argv = &.{ self_exe, "--daemon" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });

        self.daemon_child = daemon;

        // Safely set the stdin/stdout files on the running server
        self.server.daemon_mutex.lock();
        self.server.daemon_stdin = daemon.stdin.?;
        self.server.daemon_stdout = daemon.stdout.?;
        self.server.daemon_mutex.unlock();

        self.initExtensionHost() catch |err| {
            std.debug.print("WIZP: extension host startup deferred/failed: {}\n", .{err});
        };

        std.debug.print("WIZP: Running — http://127.0.0.1:{} (press Ctrl+C to quit)\n", .{self.port});
        self.openBrowser();

        // Wait for shutdown signal via condvar
        var shutdown_mutex: @import("sync.zig").Mutex = .{};
        var shutdown_cond: @import("sync.zig").Condition = .{};
        defer {
            shutdown_cond.signal();
        }
        shutdown_mutex.lock();
        defer shutdown_mutex.unlock();
        while (self.running) {
            shutdown_cond.timedWait(&shutdown_mutex, 500 * std.time.ns_per_ms) catch {};
        }
    }

    fn initExtensionHost(self: *MonacoFrontend) !void {
        var ext_host = try ExtensionHost.init(self.allocator);
        errdefer ext_host.deinit();

        // Load extensions
        var home: []const u8 = "~";
        var home_allocated = false;
        if (comptime builtin.os.tag == .windows) {
            if (runtime.getEnvVarOwned(self.allocator, "USERPROFILE")) |val| {
                home = val;
                home_allocated = true;
            } else |_| {}
        } else if (runtime.getEnvVarOwned(self.allocator, "HOME")) |val| {
            home = val;
            home_allocated = true;
        } else |_| {
            home = "~";
        }
        defer if (home_allocated) self.allocator.free(home);

        const ext_dir = try std.fs.path.join(self.allocator, &.{ home, ".wizp/extensions" });
        defer self.allocator.free(ext_dir);
        ext_host.addExtensionDir(ext_dir) catch {};
        if (runtime.getEnvVarOwned(self.allocator, "WIZP_EXTENSION_DIR")) |extra_dir| {
            defer self.allocator.free(extra_dir);
            ext_host.addExtensionDir(extra_dir) catch {};
        } else |_| {}
        ext_host.discoverExtensions() catch |err| {
            std.debug.print("WIZP: extension discovery failed: {}\n", .{err});
        };
        self.extension_host = ext_host;
        self.extension_host.?.installRecoveryHandler();
        self.server.ext_host = &self.extension_host.?;
        if (runtime.getEnvVarOwned(self.allocator, "WIZP_DEFER_STARTUP_EXTENSIONS") catch null) |raw| {
            defer self.allocator.free(raw);
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "1") or std.mem.eql(u8, trimmed, "true")) {
                std.debug.print("WIZP: startup extension activation deferred\n", .{});
                return;
            }
        }

        self.extension_host.?.activateByEvent("startup") catch |err| {
            std.debug.print("WIZP: startup extension activation failed: {}\n", .{err});
        };
    }

    pub fn deinit(self: *MonacoFrontend) void {
        self.running = false;
        self.server.running = false;
        if (self.server_thread) |t| t.join();
        if (self.extension_host) |*host| {
            host.deinit();
            self.extension_host = null;
        }
        self.server.deinit();
        if (self.daemon_child) |*child| {
            child.kill(runtime.io());
        }
    }

    fn serveLoop(self: *MonacoFrontend) void {
        while (self.running) {
            self.server.serve() catch |err| {
                if (!self.running) break;
                std.debug.print("WIZP: Server error: {}\n", .{err});
                runtime.sleepNanoseconds(10 * std.time.ns_per_ms);
            };
        }
    }
};
