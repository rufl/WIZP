// Keybinding system for WIZP
// Supports multiple modes: normal, insert, visual, command
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const KeyMode = enum {
    normal, // Default mode for navigation
    insert, // Text insertion mode
    visual, // Selection mode
    command, // Command palette mode
    search, // Search mode
};

pub const KeyEvent = struct {
    key: Key,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,

    pub const Key = union(enum) {
        char: u8,
        special: SpecialKey,
    };

    pub const SpecialKey = enum {
        escape,
        enter,
        tab,
        backspace,
        delete,
        up,
        down,
        left,
        right,
        home,
        end,
        page_up,
        page_down,
        insert,
        f1,
        f2,
        f3,
        f4,
        f5,
        f6,
        f7,
        f8,
        f9,
        f10,
        f11,
        f12,
    };
};

pub const EditorAction = enum {
    // Movement
    cursor_up,
    cursor_down,
    cursor_left,
    cursor_right,
    cursor_word_forward,
    cursor_word_back,
    cursor_line_start,
    cursor_line_end,
    cursor_file_start,
    cursor_file_end,
    cursor_page_up,
    cursor_page_down,

    // Editing
    insert_char,
    insert_newline,
    delete_backward,
    delete_forward,
    delete_word_backward,
    delete_word_forward,
    delete_line,
    indent,
    dedent,

    // Selection
    select_up,
    select_down,
    select_left,
    select_right,
    select_word,
    select_line,
    select_all,

    // Clipboard
    copy,
    cut,
    paste,

    // Undo/Redo
    undo,
    redo,

    // File operations
    save,
    save_as,
    open_file,
    close_file,
    new_file,

    // Search
    search,
    search_next,
    search_prev,
    replace,

    // UI
    command_palette,
    toggle_file_tree,
    toggle_line_numbers,
    toggle_gutter,

    // AI/LLM
    chat_open,
    chat_send,
    complete_accept,

    // Misc
    quit,
    force_quit,
    noop,
};

pub const Keybind = struct {
    key: KeyEvent,
    mode: KeyMode,
    action: EditorAction,
};

pub const KeybindManager = struct {
    allocator: Allocator,
    binds: std.array_list.Managed(Keybind),
    mode: KeyMode = .normal,
    pending_keys: std.array_list.Managed(KeyEvent),

    const Self = @This();

    pub fn initEmpty(comptime T: type) std.array_list.Managed(T) {
        return std.array_list.Managed(T).init(undefined);
    }

    pub fn init(allocator: Allocator) Self {
        var self = Self{
            .allocator = allocator,
            .binds = std.array_list.Managed(Keybind).init(allocator),
            .pending_keys = std.array_list.Managed(KeyEvent).init(allocator),
        };
        self.loadDefaults();
        return self;
    }

    fn loadDefaults(self: *Self) void {
        // Normal mode defaults (Vim-like)
        self.addBind(.{ .key = .{ .key = .{ .special = .up } }, .mode = .normal, .action = .cursor_up });
        self.addBind(.{ .key = .{ .key = .{ .special = .down } }, .mode = .normal, .action = .cursor_down });
        self.addBind(.{ .key = .{ .key = .{ .special = .left } }, .mode = .normal, .action = .cursor_left });
        self.addBind(.{ .key = .{ .key = .{ .special = .right } }, .mode = .normal, .action = .cursor_right });

        // h, j, k, l for movement
        self.addBind(.{ .key = .{ .key = .{ .char = 'h' } }, .mode = .normal, .action = .cursor_left });
        self.addBind(.{ .key = .{ .key = .{ .char = 'j' } }, .mode = .normal, .action = .cursor_down });
        self.addBind(.{ .key = .{ .key = .{ .char = 'k' } }, .mode = .normal, .action = .cursor_up });
        self.addBind(.{ .key = .{ .key = .{ .char = 'l' } }, .mode = .normal, .action = .cursor_right });

        // Word movement
        self.addBind(.{ .key = .{ .key = .{ .char = 'w' } }, .mode = .normal, .action = .cursor_word_forward });
        self.addBind(.{ .key = .{ .key = .{ .char = 'b' } }, .mode = .normal, .action = .cursor_word_back });

        // Line start/end
        self.addBind(.{ .key = .{ .key = .{ .char = '0' } }, .mode = .normal, .action = .cursor_line_start });
        self.addBind(.{ .key = .{ .key = .{ .char = '$' } }, .mode = .normal, .action = .cursor_line_end });
        self.addBind(.{ .key = .{ .key = .{ .char = '^' } }, .mode = .normal, .action = .cursor_line_start });

        // File start/end
        self.addBind(.{ .key = .{ .key = .{ .char = 'g' } }, .mode = .normal, .action = .cursor_page_up }); // gg prefix
        self.addBind(.{ .key = .{ .key = .{ .char = 'G' } }, .mode = .normal, .action = .cursor_file_end });

        // Mode switching
        self.addBind(.{ .key = .{ .key = .{ .char = 'i' } }, .mode = .normal, .action = .noop }); // Enter insert mode
        self.addBind(.{ .key = .{ .key = .{ .char = 'v' } }, .mode = .normal, .action = .noop }); // Enter visual mode
        self.addBind(.{ .key = .{ .key = .{ .special = .escape } }, .mode = .insert, .action = .noop }); // Exit to normal

        // Editing (normal mode)
        self.addBind(.{ .key = .{ .key = .{ .char = 'x' } }, .mode = .normal, .action = .delete_forward });
        self.addBind(.{ .key = .{ .key = .{ .char = 'd' } }, .mode = .normal, .action = .delete_line });
        self.addBind(.{ .key = .{ .key = .{ .char = 'u' } }, .mode = .normal, .action = .undo });
        self.addBind(.{ .key = .{ .key = .{ .char = 'r' }, .ctrl = true }, .mode = .normal, .action = .redo });

        // Yank/Paste
        self.addBind(.{ .key = .{ .key = .{ .char = 'y' } }, .mode = .normal, .action = .copy });
        self.addBind(.{ .key = .{ .key = .{ .char = 'p' } }, .mode = .normal, .action = .paste });

        // Save
        self.addBind(.{ .key = .{ .key = .{ .char = 's' }, .ctrl = true }, .mode = .normal, .action = .save });
        self.addBind(.{ .key = .{ .key = .{ .char = 's' }, .ctrl = true }, .mode = .insert, .action = .save });

        // Command palette
        self.addBind(.{ .key = .{ .key = .{ .char = 'p' }, .ctrl = true, .shift = true }, .mode = .normal, .action = .command_palette });
        self.addBind(.{ .key = .{ .key = .{ .char = 'p' }, .ctrl = true, .shift = true }, .mode = .insert, .action = .command_palette });

        // Search
        self.addBind(.{ .key = .{ .key = .{ .char = '/' } }, .mode = .normal, .action = .search });
        self.addBind(.{ .key = .{ .key = .{ .char = 'f' }, .ctrl = true }, .mode = .normal, .action = .search });
        self.addBind(.{ .key = .{ .key = .{ .char = 'f' }, .ctrl = true }, .mode = .insert, .action = .search });

        // Quit
        self.addBind(.{ .key = .{ .key = .{ .char = 'q' }, .ctrl = true }, .mode = .normal, .action = .quit });
        self.addBind(.{ .key = .{ .key = .{ .char = 'q' }, .ctrl = true }, .mode = .insert, .action = .quit });
        // Force quit (no save prompt)
        self.addBind(.{ .key = .{ .key = .{ .char = 'q' }, .ctrl = true, .shift = true }, .mode = .normal, .action = .force_quit });
        self.addBind(.{ .key = .{ .key = .{ .char = 'q' }, .ctrl = true, .shift = true }, .mode = .insert, .action = .force_quit });
    }

    fn addBind(self: *Self, bind: Keybind) void {
        self.binds.append(bind) catch {};
    }

    pub fn processKey(self: *Self, event: KeyEvent) ?EditorAction {
        // Look for matching bind in current mode
        for (self.binds.items) |bind| {
            if (bind.mode == self.mode and keyMatch(bind.key, event)) {
                return bind.action;
            }
        }
        return null;
    }

    fn keyMatch(a: KeyEvent, b: KeyEvent) bool {
        return std.meta.eql(a.key, b.key) and a.ctrl == b.ctrl and a.alt == b.alt and a.shift == b.shift and a.meta == b.meta;
    }

    pub fn deinit(self: *Self) void {
        self.binds.deinit();
        self.pending_keys.deinit();
    }
};
