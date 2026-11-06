const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");

pub const DVUICore = struct {
    backend: SDLBackend,
    window: dvui.Window,
    allocator: std.mem.Allocator,
    interrupted: bool = false,

    pub fn init(self: *DVUICore, allocator: std.mem.Allocator) !void {
        self.backend = try SDLBackend.initWindow(.{
            .allocator = allocator,
            .size = .{ .w = 1280.0, .h = 720.0 },
            .vsync = true,
            .title = "WIZP",
        });

        // self.backend is now at a stable address on the caller's stack,
        // so backend.backend() returns a Backend with a valid, stable pointer.
        self.window = try dvui.Window.init(@src(), allocator, self.backend.backend(), .{});
        self.allocator = allocator;
    }

    pub fn deinit(self: *DVUICore) void {
        self.window.deinit();
        self.backend.deinit();
    }

    pub fn beginFrame(self: *DVUICore) !void {
        const nstime = self.window.beginWait(self.interrupted);
        try self.window.begin(nstime);
    }

    pub fn endFrame(self: *DVUICore) !void {
        const end_micros = try self.window.end(.{});
        try self.backend.setCursor(self.window.cursorRequested());
        try self.backend.textInputRect(self.window.textInputRequested());
        try self.backend.renderPresent();
        self.interrupted = try self.backend.waitEventTimeout(self.window.waitTime(end_micros));
    }

    pub fn addAllEvents(self: *DVUICore) !void {
        try self.backend.addAllEvents(&self.window);
    }

    pub fn shouldClose(_: *DVUICore) bool {
        for (dvui.events()) |*e| {
            if (e.evt == .window and e.evt.window.action == .close) return true;
            if (e.evt == .app and e.evt.app.action == .quit) return true;
        }
        return false;
    }
};
