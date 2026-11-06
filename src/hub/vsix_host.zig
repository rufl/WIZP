const std = @import("std");
const bun = @import("root").bun;
const JSC = bun.JSC;

pub const VSIXHost = struct {
    allocator: std.mem.Allocator,
    extensions: std.StringArrayHashMapUnmanaged(Extension) = .{},

    const Extension = struct {
        id: []const u8,
        path: []const u8,
        active: bool = false,
        exports: ?JSC.JSValue = null,
    };

    pub fn init(allocator: std.mem.Allocator) VSIXHost {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VSIXHost) void {
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.path);
        }
        self.extensions.deinit();
    }

    pub fn registerExtension(self: *VSIXHost, id: []const u8, path: []const u8) !void {
        const dup_id = try self.allocator.dupe(u8, id);
        const dup_path = try self.allocator.dupe(u8, path);

        try self.extensions.put(self.allocator, dup_id, .{
            .id = dup_id,
            .path = dup_path,
        });
    }

    pub fn activateExtension(self: *VSIXHost, id: []const u8, _: *JSC.JSGlobalObject) !void {
        if (self.extensions.getPtr(id)) |ext| {
            if (ext.active) return;

            const activation_script =
                "import * as extension from '" ++ ext.path ++ "';\n" ++
                "if (typeof extension.activate === 'function') {\n" ++
                "  extension.activate(acquireHostAPI());\n" ++
                "}\n";

            ext.exports = JSC.Javascript.bunGlobal().call(
                .function,
                activation_script,
                .{},
            );
            ext.active = true;
        }
    }

    pub fn deactivateExtension(self: *VSIXHost, id: []const u8) void {
        if (self.extensions.getPtr(id)) |ext| {
            if (!ext.active) return;

            // Call deactivation hook if exists
            if (ext.exports) |exports| {
                if (exports.get("deactivate")) |deactivateFn| {
                    deactivateFn.call(
                        JSC.Javascript.bunGlobal(),
                        .{},
                    );
                }
            }
            ext.active = false;
        }
    }
};

fn acquireHostAPI() JSC.JSValue {
    // Returns a JavaScript object with VSIX host API
    const js_obj = JSC.JSValue.createEmptyObject();
    _ = js_obj.put("workspace", createWorkspaceAPI());
    _ = js_obj.put("window", createWindowAPI());
    _ = js_obj.put("commands", createCommandsAPI());
    return js_obj;
}

fn createWorkspaceAPI() JSC.JSValue {
    const js_workspace = JSC.JSValue.createEmptyObject();

    // File system operations
    _ = js_workspace.put("readFile", JSC.JSV.createFunction(
        "readFile",
        @import("zig_wrapper.zig").readFile,
    ));
    _ = js_workspace.put("writeFile", JSC.JSV.createFunction(
        "writeFile",
        @import("zig_wrapper.zig").writeFile,
    ));

    // File watchers
    _ = js_workspace.put("createFileWatcher", JSC.JSV.createFunction(
        "createFileWatcher",
        @import("zig_wrapper.zig").createFileWatcher,
    ));

    // Workspace state
    _ = js_workspace.put("getWorkspaceFolders", JSC.JSV.createFunction(
        "getWorkspaceFolders",
        @import("zig_wrapper.zig").getWorkspaceFolders,
    ));

    return js_workspace;
}

fn createWindowAPI() JSC.JSValue {
    // Implementation for window API
    return JSC.JSValue.createEmptyObject();
}

fn createCommandsAPI() JSC.JSValue {
    // Implementation for commands API
    return JSC.JSValue.createEmptyObject();
}
