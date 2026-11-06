const std = @import("std");
const runtime = @import("../runtime_016.zig");
const bun = @import("root").bun;
const JSC = bun.JSC;

pub export fn readFile(global: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
    const args = callframe.arguments(1);
    if (args.len < 1) {
        return JSC.JSValue.createUndefined();
    }

    const path_str = args.ptr[0].getZigString(global);
    const path = path_str.slice();

    const contents = runtime.readFileAlloc(global.allocator(), path, std.math.maxInt(usize)) catch |err| {
        return JSC.Javascript.createError(
            global,
            "Failed to read file: {s}",
            .{@errorName(err)},
        );
    };

    return JSC.JSValue.createString(global, contents);
}

pub export fn writeFile(global: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
    const args = callframe.arguments(2);
    if (args.len < 2) {
        return JSC.JSValue.createUndefined();
    }

    const path_str = args.ptr[0].getZigString(global);
    const path = path_str.slice();
    const content_str = args.ptr[1].getZigString(global);
    const content = content_str.slice();

    runtime.writeFile(path, content) catch |err| {
        return JSC.Javascript.createError(
            global,
            "Failed to write file: {s}",
            .{@errorName(err)},
        );
    };

    return JSC.JSValue.createBoolean(true);
}

pub export fn createFileWatcher(global: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
    _ = callframe;
    return JSC.Javascript.createError(
        global,
        "File watchers are not available in the legacy VSIX host",
        .{},
    );
}

pub export fn getWorkspaceFolders(global: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(.C) JSC.JSValue {
    _ = callframe; // Currently no arguments needed
    const allocator = global.allocator();
    const folder = std.Io.Dir.cwd().realPathFileAlloc(runtime.io(), ".", allocator) catch {
        return JSC.JSValue.createEmptyArray(global, 0);
    };
    defer allocator.free(folder);
    const uri = std.fmt.allocPrint(allocator, "file://{s}", .{folder}) catch {
        return JSC.JSValue.createEmptyArray(global, 0);
    };
    defer allocator.free(uri);

    const js_array = JSC.JSValue.createEmptyArray(global, 1);
    const js_folder = JSC.JSValue.createObject(global);
    _ = js_folder.put(global, "uri", JSC.JSValue.createString(global, uri));

    // Extract just the folder name
    const name = std.fs.path.basename(folder);
    _ = js_folder.put(global, "name", JSC.JSValue.createString(global, name));
    js_array.putIndex(js_folder);
    return js_array;
}
