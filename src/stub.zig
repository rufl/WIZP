// Stub module - provides dummy types when features are disabled

pub const LLMConfig = struct {};
pub const Provider = enum { ollama };
pub const CompletionRequest = struct { messages: []const u8 = &.{} };
pub const CompletionResponse = struct { content: []const u8 = "" };
pub const Message = struct { role: u8 = 0, content: []const u8 = "" };
pub const LLMClient = struct {
    pub fn init(a: anytype, b: anytype) @This() {
        _ = a;
        _ = b;
        return .{};
    }
    pub fn close(_: *@This()) void {}
};
pub fn defaultModel(_: anytype) []const u8 {
    return "";
}
pub fn defaultApiBase(_: anytype) []const u8 {
    return "";
}

pub const KiloCode = struct {
    pub fn init(_: anytype, _: anytype) !@This() {
        return .{};
    }
    pub fn deinit(_: *@This()) void {}
    pub fn getInlineCompletion(_: *@This(), _: anytype) !?Completion {
        return null;
    }
    pub fn chat(_: *@This(), _: []const u8, _: anytype) ![]const u8 {
        return "";
    }
    pub fn setParams(_: *@This(), _: f32, _: f32, _: usize) void {}
    pub const ChatMessage = struct { role: u8 = 0, content: []const u8 = "" };
    pub const CompletionContext = struct { prefix: []const u8 = "", suffix: []const u8 = "" };
    pub const Completion = struct { text: []const u8 = "" };
    pub const ProjectContext = struct { current_file: ?FileCtx = null };
    pub const FileCtx = struct { path: []const u8 = "" };
};

pub const LspSuggestion = struct {};
pub const LspDetector = struct {
    pub fn detect(_: []const u8) ?LspSuggestion {
        return null;
    }
};
pub const FileIcons = struct {
    pub fn getIcon(_: []const u8) []const u8 {
        return "📄";
    }
};
pub const Formatter = struct {};
