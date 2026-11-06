// WIZP Platform dispatch — comptime platform selection
// Pattern from anyzig Cmdline.zig: comptime union with OS-specific fields.
// Pattern from Electrobun: native webview per platform.

const builtin = @import("builtin");

/// Get only the platform module selected for the current target. Keeping the
/// imports inside the comptime switch prevents unsupported platform bindings
/// from being compiled into Linux builds.
pub const current = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .macos => @import("macos.zig"),
    .windows => @import("windows.zig"),
    else => @compileError("Unsupported platform"),
};

test "platform dispatch compiles" {
    _ = current;
}
