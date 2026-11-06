// WIZP AI Panel — AI settings dialog and chat UI
// Extracted from Editor.zig to reduce monolith size.
const std = @import("std");
const Allocator = std.mem.Allocator;
const LLM = @import("../llm/LLM.zig");
const Theme = @import("../theme/Theme.zig");
const Color = Theme.Color;

pub const AISettingsField = enum {
    provider,
    model,
    api_key,
    api_base,
    temperature,
    max_tokens,
    save,
    cancel,
};

pub fn prevField(f: AISettingsField) AISettingsField {
    return switch (f) {
        .provider => .cancel,
        .model => .provider,
        .api_key => .model,
        .api_base => .api_key,
        .temperature => .api_base,
        .max_tokens => .temperature,
        .save => .max_tokens,
        .cancel => .save,
    };
}

pub fn nextField(f: AISettingsField) AISettingsField {
    return switch (f) {
        .provider => .model,
        .model => .api_key,
        .api_key => .api_base,
        .api_base => .temperature,
        .temperature => .max_tokens,
        .max_tokens => .save,
        .save => .cancel,
        .cancel => .provider,
    };
}
