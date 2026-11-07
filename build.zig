const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 17) {
        std.debug.panic(
            "WIZP requires Zig 0.17.x (found {d}.{d}.{d}).",
            .{ builtin.zig_version.major, builtin.zig_version.minor, builtin.zig_version.patch },
        );
    }

    var target = b.standardTargetOptions(.{});
    if (target.query.isNative() and builtin.target.os.tag == .linux) {
        target = b.resolveTargetQuery(.{
            .cpu_arch = builtin.target.cpu.arch,
            .os_tag = .linux,
            .abi = .gnu,
            .cpu_model = .baseline,
        });
    }
    const optimize = b.standardOptimizeOption(.{});
    const os_tag = target.result.os.tag;

    // QuickJS option
    const enable_quickjs = b.option(bool, "WIZP_QUICKJS", "Enable QuickJS embedded JavaScript runtime") orelse false;
    if (enable_quickjs) {
        if (std.Io.Dir.cwd().access(b.graph.io, "lib/quickjs/quickjs.c", .{})) |_| {} else |_| {
            std.debug.panic("WIZP_QUICKJS is unavailable: lib/quickjs sources are not vendored; use the Bun-backed extension host.", .{});
        }
    }
    // Tree-sitter option
    const enable_treesitter = b.option(bool, "TREE_SITTER_AVAILABLE", "Enable tree-sitter incremental parsing") orelse false;
    // Native WebView option (Electrobun-style) — this is the recommended release path

    // Bundled frontend (pre-compiled Vite output from frontend/dist).
    // The packaged launcher carries this directory; Bun is not required at runtime.
    const bundled_frontend = b.option(bool, "WIZP_BUNDLED_FRONTEND", "Use pre-built frontend/dist assets (run the frontend build for releases)") orelse false;
    // Bun binary path
    const bun_path_opt = b.option([]const u8, "WIZP_BUN", "Path to Bun binary used by the build and runtime (auto-detected if not set)");
    const bun_discovered = if (bun_path_opt) |_| null else discoverBun(b);
    const bun_path = if (bun_path_opt) |configured|
        resolveConfiguredProgram(b, configured)
    else
        bun_discovered orelse "bun";
    const bun_found = bun_path_opt != null or bun_discovered != null;
    // Cross-compiled packages must not embed the build host's absolute Bun
    // path. Resolve Bun from the target machine's PATH at runtime instead.
    const runtime_bun_path = b.option([]const u8, "WIZP_RUNTIME_BUN", "Bun executable name or path used at runtime") orelse bun_path;
    // DVUI option — default off (requires SDL3, OpenGL, etc.)
    const enable_dvui = b.option(bool, "WIZP_DVUI_AVAILABLE", "Enable DVUI native GUI backend (requires SDL3, OpenGL)") orelse false;

    const dvui_available_opt = b.addOptions();
    dvui_available_opt.addOption(bool, "WIZP_DVUI_AVAILABLE", enable_dvui);

    const frontend_bundled_opt = b.addOptions();
    frontend_bundled_opt.addOption(bool, "WIZP_BUNDLED_FRONTEND", bundled_frontend);

    const runtime_paths_opt = b.addOptions();
    runtime_paths_opt.addOption([]const u8, "source_root", ".");

    if (bundled_frontend and !bun_found) {
        // If the user explicitly asked for bundled frontend but we have no Bun,
        // they must have pre-built it.
        const required = [_][]const u8{"frontend/dist/index.html"};
        for (required) |p| {
            if (std.Io.Dir.cwd().access(b.graph.io, p, .{})) |_| {} else |_| {
                std.debug.panic(
                    \\WIZP_BUNDLED_FRONTEND is set but Bun was not found and frontend/dist/ is missing.
                    \\
                    \\Either:
                    \\  1. Install Bun and run the build again, or
                    \\  2. Pre-build manually:
                    \\       cd frontend && bun install && bun run build
                    \\
                , .{});
            }
        }
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("dvui_available", dvui_available_opt.createModule());
    exe_mod.addImport("frontend_bundled", frontend_bundled_opt.createModule());
    exe_mod.addImport("runtime_paths", runtime_paths_opt.createModule());

    // zigpty — cross-platform PTY library
    const zigpty_dep = b.dependency("zigpty", .{
        .target = target,
        .optimize = optimize,
    });
    const zigpty_dir = "zig";
    const zigpty_mod = b.createModule(.{
        .root_source_file = zigpty_dep.path(b.fmt("{s}/root.zig", .{zigpty_dir})),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addSiblingImports(b, zigpty_mod, zigpty_dep, zigpty_dir, &.{
        "root.zig", "common.zig", "pty_darwin.zig", "pty_linux.zig", "pty_windows.zig", "termios.zig",
    }, 0, target, optimize);
    exe_mod.addImport("zigpty", zigpty_mod);

    const zlay_dep = b.dependency("zlay", .{
        .target = target,
        .optimize = optimize,
    });
    const zlay_dir = "src";
    const zlay_mod = b.createModule(.{
        .root_source_file = zlay_dep.path(b.fmt("{s}/root.zig", .{zlay_dir})),
        .target = target,
        .optimize = optimize,
    });
    addSiblingImports(b, zlay_mod, zlay_dep, zlay_dir, &.{
        "types.zig",                   "widgets.zig",               "retained_reference_tests.zig",    "retained_store.zig",
        "root.zig",                    "scroll.zig",                "text.zig",                        "text_widgets.zig",
        "transition.zig",              "retained_layout.zig",       "layout.zig",                      "paragraph_provider.zig",
        "profile.zig",                 "public_metadata_tests.zig", "renderer.zig",                    "facade_tests.zig",
        "geometry.zig",                "globals.zig",               "hash.zig",                        "integration_tests.zig",
        "interaction.zig",             "context.zig",               "debug.zig",                       "debug_inspector_tests.zig",
        "declaration_order_tests.zig", "deep_render_tests.zig",     "exit_transition_tests.zig",       "animation.zig",
        "audit_regression_tests.zig",  "accessibility.zig",         "allocation_discipline_tests.zig",
    }, 4, target, optimize);
    exe_mod.addImport("zlay", zlay_mod);

    if (enable_dvui) {
        addDvuiSupport(b, exe_mod, target, optimize);
    } else {
        // --- DVUI-disabled path: stub modules ---
        const dvui_stub = b.createModule(.{
            .root_source_file = b.path("src/stubs/dvui.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("dvui", dvui_stub);

        const sdl_stub = b.createModule(.{
            .root_source_file = b.path("src/stubs/sdl-backend.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("sdl-backend", sdl_stub);
    }

    const exe = b.addExecutable(.{
        .name = "wizp",
        .root_module = exe_mod,
    });

    if (enable_dvui) {
        exe.root_module.addLibraryPath(b.path("lib"));
        exe.root_module.linkSystemLibrary("SDL3", .{});
    }

    // Note: if you get "unhandled relocation type R_X86_64_PC64" linker errors,
    // build with -Dtarget=x86_64-linux-gnu to work around GCC 16 .sframe incompatibility.

    if (enable_quickjs) {
        exe.root_module.addCMacro("WIZP_QUICKJS", "1");
        exe.root_module.addCSourceFile(.{ .file = b.path("lib/quickjs/quickjs.c"), .flags = &.{
            "-D_GNU_SOURCE",
            "-DCONFIG_VERSION=\"2024-01-13\"",
            "-DCONFIG_BIGNUM",
            "-Wno-discarded-qualifiers",
        } });
        exe.root_module.addCSourceFile(.{ .file = b.path("lib/quickjs/libregexp.c"), .flags = &.{"-D_GNU_SOURCE"} });
        exe.root_module.addCSourceFile(.{ .file = b.path("lib/quickjs/libunicode.c"), .flags = &.{"-D_GNU_SOURCE"} });
        exe.root_module.addCSourceFile(.{ .file = b.path("lib/quickjs/cutils.c"), .flags = &.{"-D_GNU_SOURCE"} });
        exe.root_module.addIncludePath(b.path("lib/quickjs"));
    }

    exe.root_module.addCSourceFile(.{ .file = b.path("lib/stb_truetype.c"), .flags = &.{} });
    exe.root_module.addIncludePath(b.path("lib"));

    // Tree-sitter incremental parsing (optional)
    const ts_options = b.addOptions();
    if (enable_treesitter) {
        ts_options.addOption(bool, "available", true);
        exe.root_module.addCMacro("TREE_SITTER_AVAILABLE", "1");
        exe.root_module.addCSourceFile(.{ .file = b.path("lib/tree-sitter/lib.c"), .flags = &.{"-DTREE_SITTER_AVAILABLE=1"} });
        exe.root_module.addIncludePath(b.path("lib/tree-sitter/lib/include"));
        exe.root_module.addIncludePath(b.path("lib/tree-sitter/lib/src"));
    } else {
        ts_options.addOption(bool, "available", false);
    }
    exe.root_module.addImport("tree_sitter_options", ts_options.createModule());

    // Bun path option
    const bun_options = b.addOptions();
    bun_options.addOption([]const u8, "bun_path", runtime_bun_path);
    bun_options.addOption([]const u8, "frontend_dir", "frontend");
    exe.root_module.addImport("bun_options", bun_options.createModule());

    // === Automatic frontend build for release builds ===
    // Build the live Vite frontend. The install step below packages its full
    // dist/ tree, including hashed assets and the generated index references.
    if (bundled_frontend) {
        if (bun_found) {
            const frontend_dir = b.path("frontend");

            const bun_build = b.addSystemCommand(&.{
                bun_path,
                "run",
                "build",
            });
            bun_build.setCwd(frontend_dir);
            bun_build.step.name = "bun run build (frontend)";

            bun_build.addFileInput(b.path("frontend/package.json"));
            bun_build.addFileInput(b.path("frontend/vite.config.ts"));
            exe.step.dependOn(&bun_build.step);
        }
    }

    if (os_tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
    } else if (os_tag == .macos) {
        exe.root_module.linkSystemLibrary("util", .{});
    }

    b.installArtifact(exe);

    if (os_tag != .windows) {
        const install_frontend_dist = b.addSystemCommand(&.{
            "sh",
            "-c",
            "if [ -d frontend/dist ]; then mkdir -p zig-out && rm -rf zig-out/frontend-dist && cp -R frontend/dist zig-out/frontend-dist; fi",
        });
        install_frontend_dist.step.name = "install frontend/dist into zig-out/frontend-dist";
        // The copy command has no implicit dependency on generated Vite
        // output. Track the manifest so a fresh frontend build cannot leave
        // zig-out/frontend-dist (and the native package) on an old hash.
        install_frontend_dist.addFileInput(b.path("frontend/dist/index.html"));
        b.getInstallStep().dependOn(&install_frontend_dist.step);
    }

    if (bun_found) {
        const install_bun = b.addInstallBinFile(.{ .cwd_relative = bun_path }, "bun");
        b.getInstallStep().dependOn(&install_bun.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run wizp");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("dvui_available", dvui_available_opt.createModule());
    test_mod.addImport("tree_sitter_options", ts_options.createModule());
    test_mod.addImport("zigpty", zigpty_mod);
    test_mod.addImport("zlay", zlay_mod);

    const test_exe = b.addTest(.{
        .root_module = test_mod,
    });
    if (enable_quickjs) {
        test_exe.root_module.addCMacro("WIZP_QUICKJS", "1");
    }
    if (os_tag == .windows) {
        test_exe.root_module.linkSystemLibrary("ws2_32", .{});
    } else if (os_tag == .macos) {
        test_exe.root_module.linkSystemLibrary("util", .{});
    }
    const run_tests = b.addRunArtifact(test_exe);
    // Zig 0.16 defaults test artifacts to the build-system IPC runner. That
    // runner is useful for per-test scheduling, but it makes this aggregate
    // suite depend on `--listen=-` and can abort before the test summary is
    // emitted. Run the compiled test artifact directly so this gate measures
    // the same process and exit status as the documented direct test command.
    if (test_exe.test_runner == null and run_tests.argv.items.len >= 2) {
        run_tests.argv.shrinkRetainingCapacity(run_tests.argv.items.len - 2);
        run_tests.stdio = .inherit;
    }
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // Named backend quality gate for local development and CI. Keep this
    // intentionally deterministic: it owns the Zig test process and source
    // formatting, while the repo-level verify script owns frontend/parity and
    // package evidence.
    const zig_fmt_check = b.addSystemCommand(&.{ "./scripts/zigw.sh", "fmt", "--check", "src/" });
    zig_fmt_check.step.name = "zig fmt --check src/";
    const check_step = b.step("check", "Run Zig tests and source format check");
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(&zig_fmt_check.step);

    // Optional X11 native GUI build (Linux only)
    const enable_x11 = if (os_tag == .linux) (b.option(bool, "WIZP_X11", "Build X11 native GUI (requires Xlib)") orelse false) else false;
    if (enable_x11) {
        const x11_mod = b.createModule(.{
            .root_source_file = b.path("src/main_native.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const x11_exe = b.addExecutable(.{
            .name = "wizp-native",
            .root_module = x11_mod,
        });
        x11_exe.root_module.addCSourceFile(.{ .file = b.path("lib/stb_truetype.c"), .flags = &.{} });
        x11_exe.root_module.addIncludePath(b.path("lib"));
        // Zig 0.16 does not add host system SDK paths when a target is explicit.
        x11_exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        x11_exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        x11_exe.root_module.linkSystemLibrary("X11", .{ .use_pkg_config = .force });
        b.installArtifact(x11_exe);
    }
}

fn resolveConfiguredProgram(_: *std.Build, configured: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(configured)) return configured;
    if (std.fs.path.dirname(configured) == null) return configured;
    return configured;
}

/// Discover Bun binary on the system.
fn discoverBun(b: *std.Build) ?[]const u8 {
    const local_candidates = [_][]const u8{
        "node_modules/electrobun/dist-linux-x64/bun",
        "zig-out/bin/bun",
    };
    for (local_candidates) |candidate| {
        if (std.Io.Dir.cwd().access(b.graph.io, candidate, .{})) |_| {
            return candidate;
        } else |_| {}
    }
    const p = b.findProgram(.{ .names = &.{"bun"} }) orelse return null;
    return p;
}

fn addDvuiSupport(
    b: *std.Build,
    exe_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const dvui_enums = @import("src/stubs/dvui_build_enums.zig");

    // DVUI build options
    const dvui_build_options = b.addOptions();
    dvui_build_options.addOption(?[]const u8, "snapshot_image_suffix", null);
    dvui_build_options.addOption(?[]const u8, "image_dir", null);
    dvui_build_options.addOption(?u8, "log_stack_trace", null);
    dvui_build_options.addOption(?bool, "log_error_trace", null);
    dvui_build_options.addOption(dvui_enums.VertexIndex, "vertex_index", .u16);
    dvui_build_options.addOption(dvui_enums.AccesskitOptions, "accesskit", .off);

    // DVUI default options — SDL3 backend needs libc, freetype, stb_image
    const dvui_default_options = b.addOptions();
    dvui_default_options.addOption(bool, "libc", true);
    dvui_default_options.addOption(bool, "tiny_file_dialogs", false);
    dvui_default_options.addOption(bool, "freetype", false);
    dvui_default_options.addOption(bool, "stb_image", false);
    dvui_default_options.addOption(bool, "tree_sitter", false);

    // DVUI module
    const dvui_module = b.addModule("dvui", .{
        .root_source_file = b.path("dvui/src/dvui.zig"),
        .target = target,
        .optimize = optimize,
    });
    dvui_module.addOptions("build_options", dvui_build_options);
    dvui_module.addOptions("default_options", dvui_default_options);

    // Render backend (default)
    const render_backend_mod = b.addModule("render_backend", .{
        .root_source_file = b.path("dvui/src/backends/render/default.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_backend_mod.addImport("dvui", dvui_module);
    dvui_module.addImport("render_backend", render_backend_mod);

    // SVG2TVG stub
    const svg2tvg_stub = b.createModule(.{
        .root_source_file = b.path("src/stubs/svg2tvg.zig"),
        .target = target,
        .optimize = optimize,
    });
    dvui_module.addImport("svg2tvg", svg2tvg_stub);

    // SDL3 backend module (uses sdl.zig which supports both SDL2 and SDL3)
    const sdl_backend_mod = b.createModule(.{
        .root_source_file = b.path("dvui/src/backends/sdl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // SDL3 options
    const sdl3_options = b.addOptions();
    sdl3_options.addOption(?bool, "callbacks", false);
    sdl3_options.addOption(std.SemanticVersion, "version", .{ .major = 3, .minor = 0, .patch = 0 });
    sdl_backend_mod.addOptions("sdl_options", sdl3_options);

    // Add C include paths for SDL3 headers and stb_truetype
    sdl_backend_mod.addIncludePath(b.path("lib"));
    dvui_module.addIncludePath(b.path("lib"));

    // Compile stb_image and stb_image_write implementations (needed by DVUI)
    dvui_module.addCSourceFile(.{ .file = b.path("lib/stb_image_impl.c") });
    dvui_module.addCSourceFile(.{ .file = b.path("lib/stb_image_write_impl.c") });

    // Wire dvui ↔ backend bidirectionally
    sdl_backend_mod.addImport("dvui", dvui_module);
    dvui_module.addImport("backend", sdl_backend_mod);

    exe_mod.addImport("dvui", dvui_module);
    exe_mod.addImport("sdl-backend", sdl_backend_mod);
}

fn addSiblingImports(
    b: *std.Build,
    root: *std.Build.Module,
    dep: *std.Build.Dependency,
    directory: []const u8,
    sources: []const []const u8,
    root_index: usize,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    var modules: [31]*std.Build.Module = undefined;
    if (sources.len > modules.len) @panic("dependency source list exceeds module capacity");
    modules[root_index] = root;
    for (sources, 0..) |source, index| {
        if (index == root_index) continue;
        modules[index] = b.createModule(.{
            .root_source_file = dep.path(b.fmt("{s}/{s}", .{ directory, source })),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
    }
    for (modules[0..sources.len]) |module| {
        for (sources, 0..) |source, index| {
            if (index != root_index and module != modules[index]) module.addImport(source, modules[index]);
        }
        if (module != root) {
            const dependency_name = if (std.mem.eql(u8, directory, "src")) "zlay" else "zigpty";
            module.addImport(dependency_name, root);
        }
    }
}
