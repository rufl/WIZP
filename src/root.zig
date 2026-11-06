// WIZP root module - exports all public APIs
// Feature flags control which modules are imported at compile time.
const features = @import("features.zig");
const FEATURES = features.FEATURES;

pub const buffer = @import("buffer/Buffer.zig");
pub const syntax = @import("syntax/Syntax.zig");
pub const theme = @import("theme/Theme.zig");
pub const ui = @import("ui/Editor.zig");
pub const config = @import("config/Config.zig");
pub const keybind = @import("keybind/Keybind.zig");
pub const threading = @import("threading/main.zig");

// Optional: AI/LLM features
pub const llm = if (FEATURES.ai) @import("llm/LLM.zig") else @import("stub.zig");
// Optional: LSP client
pub const lsp = if (FEATURES.lsp) @import("lsp/LSP.zig") else struct {
    pub const LSPClient = struct {
        pub fn init(_: anytype) @This() {
            return .{};
        }
    };
};
// Optional: MCP client
pub const mcp = if (FEATURES.ai) @import("mcp/MCP.zig") else struct {
    pub const MCPClient = struct {
        pub fn init(_: anytype) @This() {
            return .{};
        }
    };
};
// Optional: Plugin system
pub const plugin = if (FEATURES.sublime_plugins or FEATURES.vscode_plugins)
    @import("plugin/Plugin.zig")
else
    struct {
        pub const PluginManager = struct {
            pub fn init(_: anytype) @This() {
                return .{};
            }
        };
    };

test {
    _ = buffer;
    _ = syntax;
    _ = theme;
    _ = ui;
    _ = config;
    _ = keybind;
}
