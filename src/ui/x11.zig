// WIZP Native GUI v2 - Full VS Code-style interactive UI
const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Buffer = @import("../buffer/Buffer.zig");
const Cursor = @import("../buffer/Cursor.zig");
const X11 = @cImport(@cInclude("X11/Xlib.h"));
extern fn XLookupString(event: *anyopaque, buffer: [*c]u8, bytes: c_int, keysym: *c_ulong, status: ?*anyopaque) c_int;

pub const NativeEditor = struct {
    a: std.mem.Allocator,
    d: *X11.Display,
    w: c_ulong,
    gc: X11.GC,
    pm: X11.Pixmap,
    pg: X11.GC,
    ww: u32,
    wh: u32,
    need_draw: bool,
    buf: Buffer,
    cur: Cursor,
    running: bool,
    sidebar: bool,
    sw: u32,
    dragging_sidebar: bool,
    drag_start_x: i32,
    menu_open: u32,
    menu_items: [5][]const []const u8,
    mode: enum { normal, insert },
    scroll: u32,
    tabs: [10][]const u8,
    tab_count: u32,
    active_tab: u32,
    mx: i32,
    my: i32,

    pub fn init(alloc: std.mem.Allocator) !NativeEditor {
        const d = X11.XOpenDisplay(null) orelse return error.NoDisplay;
        const s = X11.DefaultScreen(d);
        const r = X11.DefaultRootWindow(d);
        const w = X11.XCreateSimpleWindow(d, r, 0, 0, 1280, 720, 1, X11.BlackPixel(d, s), 0x1E1E1E);
        _ = X11.XStoreName(d, w, "WIZP - Code Editor");
        _ = X11.XSelectInput(d, w, X11.ExposureMask | X11.KeyPressMask | X11.ButtonPressMask | X11.ButtonReleaseMask | X11.PointerMotionMask | X11.StructureNotifyMask | X11.LeaveWindowMask);
        _ = X11.XMapWindow(d, w);
        const gc = X11.XCreateGC(d, w, 0, null);
        const pm = X11.XCreatePixmap(d, w, 1280, 720, @intCast(X11.DefaultDepth(d, s)));
        const pg = X11.XCreateGC(d, pm, 0, null);
        var buf = Buffer.init(alloc);
        try buf.insert(0, "const std = @import(\"std\");\npub fn main() !void {\n    std.debug.print(\"Hello WIZP!\\n\", .{});\n}\n");
        const menus = [_][]const []const u8{
            &.{ "&File", "&New File", "&Open File...", "&Save", "Save &As...", "----------------", "E&xit" },
            &.{ "&Edit", "&Undo", "&Redo", "----------------", "Cu&t", "&Copy", "&Paste" },
            &.{ "&View", "Toggle &Sidebar", "Toggle &Panel", "&Zen Mode", "----------------", "&Minimap" },
            &.{ "&Help", "&About WIZP", "&Welcome Page", "&Keybindings" },
            &.{ "&AI", "&Inline Completion", "&Chat", "AI &Settings..." },
        };
        return .{ .a = alloc, .d = d, .w = w, .gc = gc, .pm = pm, .pg = pg, .ww = 1280, .wh = 720, .need_draw = true, .buf = buf, .cur = Cursor.at(0, 0), .running = true, .sidebar = true, .sw = 200, .dragging_sidebar = false, .drag_start_x = 0, .menu_open = 99, .menu_items = menus, .mode = .normal, .scroll = 0, .tabs = .{"main.zig"} ++ @as([9][]const u8, @splat("")), .tab_count = 1, .active_tab = 0, .mx = 0, .my = 0 };
    }

    pub fn run(self: *NativeEditor) !void {
        while (self.running) {
            var had = false;
            while (X11.XPending(self.d) > 0) {
                had = true;
                var ev: X11.XEvent = undefined;
                _ = X11.XNextEvent(self.d, &ev);
                try self.handle(&ev);
            }
            if (self.need_draw or !had) {
                self.draw();
                self.need_draw = false;
            }
            if (!had) runtime.sleepNanoseconds(8 * std.time.ns_per_ms);
        }
        _ = X11.XFreeGC(self.d, self.pg);
        _ = X11.XFreePixmap(self.d, self.pm);
        _ = X11.XFreeGC(self.d, self.gc);
        _ = X11.XDestroyWindow(self.d, self.w);
        _ = X11.XCloseDisplay(self.d);
        self.buf.deinit();
    }

    fn handle(self: *NativeEditor, ev: *X11.XEvent) !void {
        switch (ev.type) {
            X11.ConfigureNotify => {
                self.ww = @intCast(ev.xconfigure.width);
                self.wh = @intCast(ev.xconfigure.height);
                if (self.pm != 0) _ = X11.XFreePixmap(self.d, self.pm);
                self.pm = X11.XCreatePixmap(self.d, self.w, @intCast(self.ww), @intCast(self.wh), @intCast(X11.DefaultDepth(self.d, X11.DefaultScreen(self.d))));
                if (self.pg != null) _ = X11.XFreeGC(self.d, self.pg);
                self.pg = X11.XCreateGC(self.d, self.pm, 0, null);
                self.need_draw = true;
            },
            X11.Expose => {
                self.need_draw = true;
            },
            X11.MotionNotify => {
                self.mx = ev.xmotion.x;
                self.my = ev.xmotion.y;
                if (self.dragging_sidebar) {
                    const new_w: u32 = @intCast(@max(80, @min(500, ev.xmotion.x - 48)));
                    if (new_w != self.sw) {
                        self.sw = new_w;
                        self.need_draw = true;
                    }
                }
            },
            X11.ButtonPress => {
                const mx: i32 = ev.xbutton.x;
                const my: i32 = ev.xbutton.y;
                // Menu bar click
                if (my < 22) {
                    const idx: u32 = @intCast(@divTrunc(mx, 90));
                    self.menu_open = if (self.menu_open == idx) 99 else idx;
                    self.need_draw = true;
                    return;
                }
                // Menu item click (if menu open)
                if (self.menu_open < 5 and my >= 22 and my < 22 + @as(i32, @intCast(self.menu_items[self.menu_open].len * 22))) {
                    const item: u32 = @intCast(@divTrunc(my - 22, 22));
                    self.handleMenu(self.menu_open, item);
                    self.menu_open = 99;
                    self.need_draw = true;
                    return;
                }
                self.menu_open = 99;
                // Sidebar resize handle
                if (self.sidebar and mx >= @as(i32, @intCast(48 + self.sw)) - 4 and mx <= @as(i32, @intCast(48 + self.sw)) + 4 and my > 22) {
                    self.dragging_sidebar = true;
                    self.drag_start_x = mx;
                    return;
                }
                // Sidebar icon click
                if (self.sidebar and mx < 48 and my > 22) {
                    self.sidebar = !self.sidebar;
                    self.need_draw = true;
                    return;
                }
                // Tab click
                if (my >= 22 and my < 48) {
                    const ex = if (self.sidebar) @as(i32, @intCast(48 + self.sw)) else 0;
                    if (mx >= ex) {
                        const tab_idx: u32 = @intCast(@divTrunc(mx - ex, 122));
                        if (tab_idx < self.tab_count) {
                            self.active_tab = tab_idx;
                            self.need_draw = true;
                        }
                    }
                    return;
                }
                self.need_draw = true;
            },
            X11.ButtonRelease => {
                self.dragging_sidebar = false;
            },
            X11.KeyPress => {
                const kc = ev.xkey.keycode;
                if (kc == 24 and (ev.xkey.state & X11.ControlMask) != 0) {
                    self.running = false;
                    return;
                }
                if (kc == 9) {
                    self.mode = .normal;
                    self.need_draw = true;
                    return;
                }
                if (kc == 31) {
                    self.mode = .insert;
                    self.need_draw = true;
                    return;
                }
                if (self.mode == .insert) {
                    if (kc == 22 and self.cur.col > 0) {
                        self.buf.delete(self.cur.toOffset(&self.buf) - 1, 1) catch {};
                        self.cur.col -= 1;
                        self.need_draw = true;
                    } else if (kc == 36) {
                        var b: [1]u8 = .{'\n'};
                        self.buf.insert(self.cur.toOffset(&self.buf), &b) catch {};
                        self.cur.row += 1;
                        self.cur.col = 0;
                        self.need_draw = true;
                    } else {
                        var out: [32]u8 = undefined;
                        var ks: c_ulong = 0;
                        const n: c_int = XLookupString(&ev.xkey, &out, @intCast(out.len), &ks, null);
                        if (n > 0) {
                            const slice = out[0..@intCast(n)];
                            if (slice[0] >= 32 or slice[0] == '\t') {
                                self.buf.insert(self.cur.toOffset(&self.buf), slice) catch {};
                                self.cur.col += @intCast(n);
                                self.need_draw = true;
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    fn handleMenu(self: *NativeEditor, menu: u32, item: u32) void {
        switch (menu) {
            0 => switch (item) {
                6 => self.running = false, // File → Exit
                3 => self.buf.save() catch {}, // File → Save
                else => {},
            },
            2 => switch (item) {
                1 => self.sidebar = !self.sidebar, // View → Toggle Sidebar
                else => {},
            },
            else => {},
        }
    }

    fn draw(self: *NativeEditor) void {
        const W = self.ww;
        const H = self.wh;
        const p = self.pm;
        const g = self.pg;

        // Clear
        _ = X11.XSetForeground(self.d, g, 0x1E1E1E);
        _ = X11.XFillRectangle(self.d, p, g, 0, 0, @intCast(W), @intCast(H));

        // Menu bar
        _ = X11.XSetForeground(self.d, g, 0x3C3C3C);
        _ = X11.XFillRectangle(self.d, p, g, 0, 0, @intCast(W), 22);
        var mx_pos: i32 = 8;
        for (self.menu_items, 0..) |menu, i| {
            if (menu.len == 0) continue;
            const label = menu[0];
            // Remove & for display
            var clean: [32]u8 = undefined;
            var ci: usize = 0;
            for (label) |c| {
                if (c != '&') {
                    clean[ci] = c;
                    ci += 1;
                }
            }
            const w2: i32 = @intCast(ci * 9);
            if (@as(u32, @intCast(i)) == self.menu_open) {
                _ = X11.XSetForeground(self.d, g, 0x505050);
                _ = X11.XFillRectangle(self.d, p, g, mx_pos - 2, 0, @as(c_uint, @intCast(w2 + 4)), 22);
            }
            _ = X11.XSetForeground(self.d, g, 0xCCCCCC);
            _ = X11.XDrawString(self.d, p, g, mx_pos, 15, &clean, @intCast(ci));
            mx_pos += w2 + 16;
        }
        _ = X11.XSetForeground(self.d, g, 0xCCCCCC);
        _ = X11.XDrawString(self.d, p, g, @as(c_int, @intCast(W)) - 40, @as(c_int, 15), "AI", 2);

        // Dropdown menu
        if (self.menu_open < 5) {
            const menu = self.menu_items[self.menu_open];
            const mx2 = @as(i32, @intCast(self.menu_open)) * 90 + 6;
            _ = X11.XSetForeground(self.d, g, 0x3C3C3C);
            _ = X11.XFillRectangle(self.d, p, g, mx2, 22, @as(c_uint, 200), @as(c_uint, @intCast(menu.len * 22)));
            for (menu, 0..) |item, j| {
                if (j == 0) continue; // Skip menu title
                const iy: i32 = 22 + @as(i32, @intCast(j)) * 22;
                if (std.mem.eql(u8, item, "----------------")) {
                    _ = X11.XSetForeground(self.d, g, 0x555555);
                    _ = X11.XDrawString(self.d, p, g, mx2 + 8, iy + 2, "────────────────────────", 22);
                } else {
                    _ = X11.XSetForeground(self.d, g, 0xCCCCCC);
                    var cl: [32]u8 = undefined;
                    var cj: usize = 0;
                    for (item) |c| {
                        if (c != '&') {
                            cl[cj] = c;
                            cj += 1;
                        }
                    }
                    _ = X11.XDrawString(self.d, p, g, mx2 + 16, iy + 15, &cl, @intCast(cj));
                }
            }
        }

        // Activity bar + Sidebar
        if (self.sidebar) {
            _ = X11.XSetForeground(self.d, g, 0x333333);
            _ = X11.XFillRectangle(self.d, p, g, 0, 22, 48, @intCast(H - 44));
            const icons = [_][]const u8{ "F", "S", "H", "G", "D", "E" };
            for (icons, 0..) |ic, idx| {
                _ = X11.XSetForeground(self.d, g, if (idx == 0) 0xFFFFFF else 0x858585);
                _ = X11.XDrawString(self.d, p, g, 16, @intCast(50 + idx * 40), ic.ptr, @intCast(ic.len));
            }
            _ = X11.XSetForeground(self.d, g, 0x252526);
            _ = X11.XFillRectangle(self.d, p, g, 48, 22, @intCast(self.sw), @intCast(H - 44));
            // Resize handle
            const hx: i32 = @as(i32, @intCast(48 + self.sw));
            _ = X11.XSetForeground(self.d, g, if (self.dragging_sidebar) 0x007ACC else 0x474747);
            _ = X11.XFillRectangle(self.d, p, g, hx - 2, 22, 4, @intCast(H - 44));
            _ = X11.XSetForeground(self.d, g, 0x858585);
            _ = X11.XDrawString(self.d, p, g, 56, 40, "EXPLORER", 8);
            _ = X11.XSetForeground(self.d, g, 0xD4D4D4);
            _ = X11.XDrawString(self.d, p, g, 56, 64, "src/", 4);
            _ = X11.XSetForeground(self.d, g, 0xFFFFFF);
            _ = X11.XDrawString(self.d, p, g, 68, 86, "main.zig", 8);
        }

        const ex: i32 = if (self.sidebar) @as(i32, @intCast(48 + self.sw)) else 0;
        const ew: u32 = W - @as(u32, @intCast(ex));

        // Tab bar
        _ = X11.XSetForeground(self.d, g, 0x2D2D2D);
        _ = X11.XFillRectangle(self.d, p, g, @intCast(ex), 22, @intCast(ew), 28);
        var tx: i32 = ex + 2;
        for (0..self.tab_count) |ti| {
            if (ti >= self.tabs.len) break;
            const name = self.tabs[ti];
            if (name.len == 0) continue;
            const tw: i32 = @as(i32, @intCast(@as(i32, @intCast(name.len * 9)))) + 20;
            _ = X11.XSetForeground(self.d, g, if (ti == self.active_tab) 0x1E1E1E else 0x2D2D2D);
            _ = X11.XFillRectangle(self.d, p, g, tx, 22, @as(c_uint, @intCast(tw)), 26);
            _ = X11.XSetForeground(self.d, g, 0xCCCCCC);
            const nz = runtime.dupeZ(self.a, name) catch continue;
            defer self.a.free(nz);
            _ = X11.XDrawString(self.d, p, g, tx + 8, 40, nz.ptr, @intCast(name.len));
            tx += tw + 2;
        }

        // Editor
        _ = X11.XSetForeground(self.d, g, 0x1E1E1E);
        _ = X11.XFillRectangle(self.d, p, g, @intCast(ex), 50, @intCast(ew), @intCast(H - 72));
        if (self.cur.row >= self.scroll) {
            const cy: i32 = 50 + @as(i32, @intCast((self.cur.row - self.scroll) * 22));
            if (cy < @as(i32, @intCast(H)) - 72) {
                _ = X11.XSetForeground(self.d, g, 0x2A2D2E);
                _ = X11.XFillRectangle(self.d, p, g, ex + 30, cy, @intCast(ew - 30), 22);
            }
        }
        const text = self.buf.getText(self.a) catch "";
        defer self.a.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var ln: u32 = 0;
        while (lines.next()) |line| : (ln += 1) {
            if (ln < self.scroll) continue;
            const sy: i32 = 50 + @as(i32, @intCast((ln - self.scroll) * 22));
            if (sy > @as(i32, @intCast(H)) - 72) break;
            _ = X11.XSetForeground(self.d, g, 0x858585);
            var nb: [8]u8 = undefined;
            const ns = std.fmt.bufPrint(&nb, "{d: >3}", .{ln + 1}) catch "   ";
            _ = X11.XDrawString(self.d, p, g, ex + 4, sy + 14, ns.ptr, @intCast(ns.len));
            _ = X11.XSetForeground(self.d, g, 0xD4D4D4);
            const dz = runtime.dupeZ(self.a, line) catch continue;
            defer self.a.free(dz);
            _ = X11.XDrawString(self.d, p, g, ex + 34, sy + 14, dz.ptr, @intCast(@min(line.len, 300)));
        }

        // Status bar
        _ = X11.XSetForeground(self.d, g, 0x007ACC);
        _ = X11.XFillRectangle(self.d, p, g, 0, @intCast(H - 22), @intCast(W), 22);
        _ = X11.XSetForeground(self.d, g, 0xFFFFFF);
        const mode = if (self.mode == .normal) "NORMAL" else "INSERT";
        var st: [128]u8 = undefined;
        const ss = std.fmt.bufPrint(&st, "{s}  main.zig *  Ln {}, Col {}  UTF-8  zig  █ {}/{}", .{ mode, self.cur.row + 1, self.cur.col_cp + 1, self.ww, self.wh }) catch "WIZP";
        _ = X11.XDrawString(self.d, p, g, 10, @intCast(H - 6), ss.ptr, @intCast(ss.len));

        // Swap
        _ = X11.XCopyArea(self.d, p, self.w, g, 0, 0, @intCast(W), @intCast(H), 0, 0);
        _ = X11.XFlush(self.d);
    }
};
