const std = @import("std");
const runtime = @import("runtime_016.zig");
const dvui_available = @import("dvui_available");

fn packageFileExists(path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(runtime.io(), path, .{}) catch return false;
    file.close(runtime.io());
    return true;
}

pub fn main(init: std.process.Init.Minimal) !void {
    runtime.initialize(init.environ);
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = if (comptime @import("builtin").mode == .debug)
        gpa.allocator()
    else
        std.heap.c_allocator;

    defer if (comptime @import("builtin").mode == .debug) {
        _ = gpa.deinit();
    };

    var args_it = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args_it.deinit();
    var args = std.array_list.Managed([:0]const u8).init(allocator);
    defer args.deinit();
    while (args_it.next()) |arg| try args.append(arg);
    const help = for (args.items[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) break true;
    } else false;
    if (help) {
        std.debug.print("WIZP - workspace editor backend\n\n", .{});
        std.debug.print("Usage: wizp [--daemon|--terminal|--terminal-probe|--package-smoke|--dvui]\n", .{});
        std.debug.print("       wizp --help\n", .{});
        return;
    }

    const daemon = for (args.items[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) break true;
    } else false;

    const dvui_flag = for (args.items[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dvui")) break true;
    } else false;

    const terminal = for (args.items[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--terminal")) break true;
    } else false;

    const terminal_probe = for (args.items[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--terminal-probe")) break true;
    } else false;
    const package_smoke = for (args.items[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--package-smoke")) break true;
    } else false;
    if (package_smoke) {
        const binary_path = if (@import("builtin").os.tag == .windows) "bin/wizp.exe" else "bin/wizp";
        if (!packageFileExists("README.md") or !packageFileExists("LICENSE") or !packageFileExists(binary_path)) {
            return error.InvalidPackageLayout;
        }
        const Editor = @import("ui/Editor.zig");
        var editor = try Editor.Editor.init(allocator, null);
        defer editor.deinit();
        std.debug.print("WIZP package smoke package-layout=true terminal-probe=true\n", .{});
        return;
    }

    if (terminal_probe) {
        const Editor = @import("ui/Editor.zig");
        var editor = try Editor.Editor.init(allocator, null);
        defer editor.deinit();
        std.debug.print("WIZP terminal probe ready\n", .{});
        return;
    }

    // Path A: Daemon mode — JSON-RPC backend for external frontends
    if (daemon) {
        const Editor = @import("ui/Editor.zig");
        var editor = try Editor.Editor.init(allocator, null);
        defer editor.deinit();
        try editor.runDaemon();
        return;
    }

    // Path B: DVUI Native — Pure Zig GUI (explicit --dvui flag)
    if (dvui_flag) {
        if (dvui_available.WIZP_DVUI_AVAILABLE) {
            const DVUICore = @import("dvui_core.zig");
            const Editor = @import("ui/Editor.zig");

            var dvui_core: DVUICore.DVUICore = undefined;
            try dvui_core.init(allocator);
            defer dvui_core.deinit();

            var editor = try Editor.Editor.init(allocator, &dvui_core);
            defer editor.deinit();

            while (editor.running) {
                try editor.render();
            }
        } else {
            std.debug.print("WIZP: DVUI not available. Rebuild with -DWIZP_DVUI_AVAILABLE=true\n", .{});
        }
        return;
    }

    // Path C: Terminal mode (explicit --terminal flag)
    if (terminal) {
        const Editor = @import("ui/Editor.zig");
        var editor = try Editor.Editor.init(allocator, null);
        defer editor.deinit();
        try editor.run();
        return;
    }

    // Default: Monaco — Embedded HTTP Server + Browser Frontend
    const MonacoUI = @import("monaco_ui.zig");
    var app = try MonacoUI.MonacoFrontend.init(allocator);
    defer app.deinit();
    try app.run();
}
