// WIZP - Compile-time feature flags.
// These gate conditional imports in root.zig. Set to false for smaller binary.
// Example: zig build -Doptimize=ReleaseSmall with these set to false trims ~300KB.

pub const FEATURES = struct {
    /// AI/LLM features (KiloCode, completions, chat) — gates llm and mcp imports
    pub const ai = true;

    /// LSP client (language servers) — gates lsp import
    pub const lsp = true;

    /// Plugin hosts — gates plugin import (Sublime Python + VSCode Bun)
    pub const sublime_plugins = true;
    pub const vscode_plugins = true;
};

/// Minimal build: core editor only, no AI, no LSP, no plugins (~500KB smaller)
pub const MINIMAL = FEATURES{
    .ai = false,
    .lsp = false,
    .sublime_plugins = false,
    .vscode_plugins = false,
};
