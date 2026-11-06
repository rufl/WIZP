// WIZP JS Engine — Persistent Bun process for extension execution.
// Keeps a single Bun process alive, communicates via stdin/stdout framing markers.
// Protocol: send a JS block terminated by "__WIZP_EVAL_END__", then read a
// marker-wrapped base64 payload from stdout. This stays synchronized even when
// extension code writes unrelated stdout lines before the protocol result.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const BunResolver = @import("../bun/Resolver.zig");
const runtime = @import("../runtime_016.zig");

pub const JSEngine = struct {
    allocator: Allocator,
    bun_path: []const u8,
    child: ?std.process.Child = null,
    child_stdin: ?std.Io.File = null,
    child_stdout: ?std.Io.File = null,
    initialized: bool = false,
    recovery_context: ?*anyopaque = null,
    recovery_callback: ?*const fn (*anyopaque) void = null,

    const Self = @This();
    pub const default_eval_timeout_ms: u32 = 5_000;

    pub fn init(allocator: Allocator) !Self {
        const bun_opts = @import("bun_options");
        const bun_path = try BunResolver.resolve(allocator, bun_opts.bun_path) orelse return error.NoJSEngine;
        errdefer allocator.free(bun_path);

        var engine = Self{
            .allocator = allocator,
            .bun_path = bun_path,
        };
        try engine.startChild();
        return engine;
    }

    fn startChild(self: *Self) !void {
        // Persistent Bun REPL: reads lines from stdin, accumulates until marker,
        // then evaluates the entire block as one unit.
        // Marker protocol: send JS code followed by a line containing only
        // "__WIZP_EVAL_END__". Results/errors are written as base64 payloads
        // wrapped in explicit markers so extension stdout noise does not break
        // the control channel.
        const repl_script =
            \\let __buf = '';
            \\let __code = '';
            \\let __queue = Promise.resolve();
            \\const __MARKER = '__WIZP_EVAL_END__';
            \\const __RESULT_START = '__WIZP_RESULT_START__';
            \\const __RESULT_END = '__WIZP_RESULT_END__';
            \\const __ERROR_START = '__WIZP_ERROR_START__';
            \\const __ERROR_END = '__WIZP_ERROR_END__';
            \\const __protocolStdoutWrite = process.stdout.write.bind(process.stdout);
            \\const __stderrWrite = process.stderr && typeof process.stderr.write === 'function'
            \\  ? process.stderr.write.bind(process.stderr)
            \\  : null;
            \\const __redirectAuxWrite = function(writeFn, chunk, encoding, callback) {
            \\  let enc = encoding;
            \\  let cb = callback;
            \\  if (typeof enc === 'function') {
            \\    cb = enc;
            \\    enc = undefined;
            \\  }
            \\  try {
            \\    if (writeFn) writeFn(chunk, enc);
            \\  } catch (_) {}
            \\  if (typeof cb === 'function') {
            \\    try { cb(); } catch (_) {}
            \\  }
            \\  return true;
            \\};
            \\const __writePayload = function(startMarker, endMarker, value) {
            \\  const text = String(value || '');
            \\  const encoded = Buffer.from(text, 'utf8').toString('base64');
            \\  __protocolStdoutWrite(startMarker + encoded + endMarker + '\n');
            \\};
            \\process.stdout.write = function(chunk, encoding, callback) {
            \\  return __redirectAuxWrite(__stderrWrite || __protocolStdoutWrite, chunk, encoding, callback);
            \\};
            \\const __run = function(toEval) {
            \\  __queue = __queue.then(async () => {
            \\    if (!toEval.trim()) { __writePayload(__RESULT_START, __RESULT_END, 'undefined'); return; }
            \\    try {
            \\      let __r = (0, eval)(toEval);
            \\      if (__r && typeof __r.then === 'function') {
            \\        __r = await __r;
            \\      }
            \\      if (__r !== undefined) __writePayload(__RESULT_START, __RESULT_END, JSON.stringify(__r));
            \\      else __writePayload(__RESULT_START, __RESULT_END, 'undefined');
            \\    } catch(e) {
            \\      __writePayload(__ERROR_START, __ERROR_END, e && e.message ? e.message : String(e));
            \\    }
            \\  }, (e) => {
            \\    __writePayload(__ERROR_START, __ERROR_END, e && e.message ? e.message : String(e));
            \\  });
            \\};
            \\process.stdin.setEncoding('utf8');
            \\process.stdin.on('data', (chunk) => {
            \\  __buf += chunk;
            \\  const lines = __buf.split('\n');
            \\  __buf = lines.pop();
            \\  for (const line of lines) {
            \\    if (line.trim() === __MARKER) {
            \\      const toEval = __code;
            \\      __code = '';
            \\      __run(toEval);
            \\    } else {
            \\      __code += line + '\n';
            \\    }
            \\  }
            \\});
            \\process.stdin.resume();
        ;

        const child = try std.process.spawn(runtime.io(), .{
            .argv = &.{ self.bun_path, "-e", repl_script },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });

        self.child = child;
        self.child_stdin = child.stdin.?;
        self.child_stdout = child.stdout.?;
        self.initialized = true;

        std.debug.print("WIZP ExtHost: JS engine initialized (persistent Bun process, pid {any})\n", .{child.id});
    }

    pub fn deinit(self: *Self) void {
        self.stopChild(false);
        if (self.bun_path.len > 0) self.allocator.free(self.bun_path);
        self.* = undefined;
    }

    fn stopChild(self: *Self, force_kill: bool) void {
        if (self.child) |*child| {
            // Explicit cleanup: close stdin to signal end, then kill if still running, then wait
            if (child.stdin) |stdin| {
                stdin.close(runtime.io());
                child.stdin = null;
            }
            if (child.stdout) |stdout| {
                stdout.close(runtime.io());
                child.stdout = null;
            }
            _ = force_kill;
            child.kill(runtime.io());
            self.child = null;
        }
        self.child_stdin = null;
        self.child_stdout = null;
        self.initialized = false;
    }

    /// Restart the persistent JS process after a host-side timeout or crash.
    pub fn restart(self: *Self) !void {
        self.stopChild(true);
        try self.startChild();
    }

    pub fn setRecoveryHandler(self: *Self, context: *anyopaque, callback: *const fn (*anyopaque) void) void {
        self.recovery_context = context;
        self.recovery_callback = callback;
    }
    /// Stop the child without restarting it. Test-only callers use this to
    /// exercise the extension-host unavailable and recovery states.
    pub fn crashForTest(self: *Self) void {
        self.stopChild(true);
    }
    pub fn evalString(self: *Self, code: []const u8, filename: []const u8) ![]u8 {
        return self.evalStringWithTimeout(code, default_eval_timeout_ms) catch |err| {
            if (err == error.Timeout or err == error.NoJSEngine) {
                std.debug.print("WIZP ExtHost: eval {s} failed: {}\n", .{ filename, err });
                if (self.recovery_callback) |callback| {
                    const context = self.recovery_context orelse return err;
                    self.recovery_callback = null;
                    callback(context);
                    self.recovery_callback = callback;
                }
            }
            return err;
        };
    }

    /// Execute JavaScript code with an optional host-side I/O deadline.
    pub fn evalStringTimeoutMs(self: *Self, code: []const u8, timeout_ms: u32) ![]u8 {
        return self.evalStringWithTimeout(code, timeout_ms);
    }

    fn writeAllWithDeadline(self: *Self, file: std.Io.File, bytes: []const u8, deadline_ms: ?i64) !void {
        _ = self;
        if (deadline_ms == null or comptime builtin.os.tag == .windows) {
            try runtime.writeAll(file, bytes);
            return;
        }

        var written_total: usize = 0;
        while (written_total < bytes.len) {
            const deadline = deadline_ms.?;
            const remaining_ms = deadline - runtime.milliTimestamp();
            if (remaining_ms <= 0) return error.Timeout;

            var poll_fds: [1]std.posix.pollfd = .{
                .{ .fd = file.handle, .events = std.posix.POLL.OUT, .revents = 0 },
            };
            const poll_timeout: i32 = @intCast(@min(remaining_ms, 1000));
            const poll_result = std.posix.poll(&poll_fds, poll_timeout) catch |err| {
                if (err == error.InterruptedSystemCall) continue;
                return err;
            };
            if (poll_result == 0) continue;
            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return error.NoJSEngine;
            if (poll_fds[0].revents & std.posix.POLL.OUT == 0) continue;

            const chunk_end = @min(written_total + 4096, bytes.len);
            try runtime.writeAll(file, bytes[written_total..chunk_end]);
            written_total = chunk_end;
        }
    }

    fn evalStringWithTimeout(self: *Self, code: []const u8, timeout_ms: ?u32) ![]u8 {
        if (!self.initialized) return error.NoJSEngine;

        const deadline_ms: ?i64 = if (timeout_ms) |ms| runtime.milliTimestamp() + @as(i64, ms) else null;
        const debug_transport = runtime.hasEnvVar("WIZP_JS_ENGINE_DEBUG") or
            runtime.hasEnvVar("WIZP_EXTENSION_DEBUG");

        // Send code block to persistent Bun process, terminated by marker
        const stdin = self.child_stdin orelse return error.NoJSEngine;
        try self.writeAllWithDeadline(stdin, code, deadline_ms);
        if (debug_transport) std.debug.print("WIZP ExtHost: JS eval wrote code bytes={}\n", .{code.len});
        try self.writeAllWithDeadline(stdin, "\n__WIZP_EVAL_END__\n", deadline_ms);
        if (debug_transport) std.debug.print("WIZP ExtHost: JS eval wrote marker\n", .{});

        // Read result line from stdout
        const stdout = self.child_stdout orelse return error.NoJSEngine;
        if (debug_transport) std.debug.print("WIZP ExtHost: JS eval awaiting result\n", .{});
        var buf = try self.allocator.alloc(u8, 65536);
        defer self.allocator.free(buf);
        var line_start: usize = 0;
        var line_end: usize = 0;

        while (true) {
            // Process already-buffered complete lines before waiting for more
            // data. Extension stdout noise and the protocol result may arrive in
            // the same read; if we stop after the first ignored line we can
            // falsely time out while the result is already buffered.
            while (true) {
                if (std.mem.indexOfScalarPos(u8, buf[0..line_end], line_start, '\n')) |newline_idx| {
                    const line = try self.allocator.dupe(u8, buf[line_start..newline_idx]);
                    line_start = newline_idx + 1;

                    // Extension code may write to stdout. Accept marker-framed
                    // protocol payloads even when noise prefixes the line.
                    if (std.mem.indexOf(u8, line, "__WIZP_RESULT_START__")) |start_idx| {
                        const payload_start = start_idx + "__WIZP_RESULT_START__".len;
                        if (std.mem.indexOfPos(u8, line, payload_start, "__WIZP_RESULT_END__")) |end_idx| {
                            const encoded = line[payload_start..end_idx];
                            const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
                            const decoded = try self.allocator.alloc(u8, decoded_len);
                            errdefer self.allocator.free(decoded);
                            try std.base64.standard.Decoder.decode(decoded, encoded);
                            if (std.mem.eql(u8, decoded, "undefined")) {
                                self.allocator.free(line);
                                self.allocator.free(decoded);
                                return self.allocator.alloc(u8, 0);
                            }
                            self.allocator.free(line);
                            return decoded;
                        }
                    } else if (std.mem.indexOf(u8, line, "__WIZP_ERROR_START__")) |start_idx| {
                        const payload_start = start_idx + "__WIZP_ERROR_START__".len;
                        if (std.mem.indexOfPos(u8, line, payload_start, "__WIZP_ERROR_END__")) |end_idx| {
                            const encoded = line[payload_start..end_idx];
                            const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
                            const decoded = try self.allocator.alloc(u8, decoded_len);
                            errdefer self.allocator.free(decoded);
                            try std.base64.standard.Decoder.decode(decoded, encoded);
                            std.debug.print("WIZP ExtHost: JS error: {s}\n", .{decoded});
                            self.allocator.free(decoded);
                            self.allocator.free(line);
                            return self.allocator.alloc(u8, 0);
                        }
                    }
                    if (debug_transport and line.len > 0) {
                        const preview = if (line.len > 400) line[0..400] else line;
                        std.debug.print("WIZP ExtHost: JS eval ignored stdout line: {s}\n", .{preview});
                    }
                    self.allocator.free(line);
                    continue;
                }
                break;
            }

            if (line_start > 0 and line_start == line_end) {
                line_start = 0;
                line_end = 0;
            } else if (line_start > 0 and line_start == buf.len) {
                line_start = 0;
                line_end = 0;
            }

            // Grow buffer if full
            if (line_end >= buf.len) {
                if (line_start > 0) {
                    const remaining = line_end - line_start;
                    std.mem.copyForwards(u8, buf[0..remaining], buf[line_start..line_end]);
                    line_start = 0;
                    line_end = remaining;
                } else {
                    buf = try self.allocator.realloc(buf, buf.len + 65536);
                }
            }

            if (comptime builtin.os.tag != .windows) {
                if (deadline_ms) |deadline| {
                    const remaining_ms = deadline - runtime.milliTimestamp();
                    if (remaining_ms <= 0) return error.Timeout;
                    var poll_fds: [1]std.posix.pollfd = .{
                        .{ .fd = stdout.handle, .events = std.posix.POLL.IN, .revents = 0 },
                    };
                    const poll_timeout: i32 = @intCast(@min(remaining_ms, 1000));
                    const poll_result = std.posix.poll(&poll_fds, poll_timeout) catch |err| {
                        if (err == error.InterruptedSystemCall) continue;
                        return err;
                    };
                    if (poll_result == 0) continue;
                    if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return error.NoJSEngine;
                }
            }

            const bytes_read = runtime.read(stdout, buf[line_end..]) catch |err| {
                std.debug.print("WIZP ExtHost: stdout read error: {}\n", .{err});
                return err;
            };
            if (bytes_read == 0) {
                std.debug.print("WIZP ExtHost: Bun process died during eval\n", .{});
                return error.NoJSEngine;
            }
            line_end += bytes_read;
        }
    }

    /// Execute JavaScript code (no return value expected).
    pub fn evalVoid(self: *Self, code: []const u8, filename: []const u8) !void {
        _ = filename;
        const result = try self.evalString(code, "eval");
        self.allocator.free(result);
    }

    fn stringifyAlloc(self: *Self, value: anytype) ![]u8 {
        var buffer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer buffer.deinit();
        try std.json.Stringify.value(value, .{}, &buffer.writer);
        return buffer.toOwnedSlice();
    }

    fn buildFunctionCall(self: *Self, func_name: []const u8, args: []const []const u8) ![]u8 {
        const name_json = try self.stringifyAlloc(func_name);
        defer self.allocator.free(name_json);

        var args_json = std.array_list.Managed(u8).init(self.allocator);
        defer args_json.deinit();
        try args_json.append('[');
        for (args, 0..) |arg, index| {
            if (index > 0) try args_json.append(',');
            try args_json.appendSlice(arg);
        }
        try args_json.append(']');

        return std.fmt.allocPrint(
            self.allocator,
            "(() => {{ const fn = globalThis[{s}]; if (typeof fn !== 'function') throw new Error('Function not found'); return fn(...{s}); }})()",
            .{ name_json, args_json.items },
        );
    }

    /// Call a global JavaScript function with JSON-encoded argument expressions.
    pub fn callFunction(self: *Self, func_name: []const u8, args: []const []const u8) !?[]u8 {
        const code = try self.buildFunctionCall(func_name, args);
        defer self.allocator.free(code);
        const result = try self.evalString(code, "callFunction");
        if (result.len == 0) return null;
        return result;
    }

    test "function call expression quotes names and preserves JSON arguments" {
        var engine = Self{
            .allocator = std.testing.allocator,
            .bun_path = "",
        };
        const code = try engine.buildFunctionCall("test'name", &.{ "1", "{\"ok\":true}" });
        defer std.testing.allocator.free(code);
        try std.testing.expectEqualStrings(
            "(() => { const fn = globalThis[\"test'name\"]; if (typeof fn !== 'function') throw new Error('Function not found'); return fn(...[1,{\"ok\":true}]); })()",
            code,
        );
    }

    /// Inject a global variable into the JS runtime.
    pub fn injectGlobal(self: *Self, name: []const u8, json_value: []const u8) !void {
        const code = try std.fmt.allocPrint(self.allocator, "globalThis.{s} = {s};", .{ name, json_value });
        defer self.allocator.free(code);
        try self.evalVoid(code, "inject");
    }

    /// Inject a global function backed by Zig.
    pub fn injectFunction(self: *Self, name: []const u8, js_body: []const u8) !void {
        const code = try std.fmt.allocPrint(self.allocator, "globalThis.{s} = {s};", .{ name, js_body });
        defer self.allocator.free(code);
        try self.evalVoid(code, "inject");
    }
};
