const std = @import("std");
const runtime = @import("runtime_016.zig");
const x = @import("ui/x11.zig");
pub fn main(init: std.process.Init.Minimal) !void {
    runtime.initialize(init.environ);
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    var editor = try x.NativeEditor.init(allocator);
    try editor.run();
}
