const std = @import("std");
const bun = @import("root").bun;
const JSC = bun.JSC;
const dvui_available = @import("dvui_available");

export fn createWindow(global: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
    if (!dvui_available.WIZP_DVUI_AVAILABLE) {
        global.throwPretty("DVUI native GUI is not available. Build with -DWIZP_DVUI_AVAILABLE=true to enable.", .{});
        return .zero;
    }

    const DVUICore = @import("../../dvui_core.zig");

    const args = callframe.arguments(2);
    if (args.len < 1) return JSC.JSValue.createUndefined();

    const options = args.ptr[0];
    const title_str = options.get(global, "title").?
        .getZigString(global);
    // Create null-terminated title
    const title_z = std.cstr.addNullByte(title_str.allocator, title_str.slice()) catch {
        return JSC.JSValue.createNull();
    };
    defer title_z.allocator.free(title_z);

    const width = options.get(global, "width").?.asU32();
    const height = options.get(global, "height").?.asU32();

    // Create window via DVUI
    const dvui_core = DVUICore.createWindow(title_z, width, height) catch |err| {
        global.throwPretty("Window creation failed: {s}", .{@errorName(err)});
        return .zero;
    };

    return JSC.JSValue.createNumber(dvui_core.id);
}

export fn showNotification(global: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
    _ = callframe;
    global.throwPretty("Native notifications are not available in the DVUI bridge.", .{});
    return .zero;
}

export fn setStatusBarMessage(global: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
    _ = callframe;
    global.throwPretty("The native status bar is not available in the DVUI bridge.", .{});
    return .zero;
}
