// Narrow compatibility policy helpers kept separate from extension lifecycle code.
const std = @import("std");
const runtime = @import("../runtime_016.zig");

pub fn isShimmedExtensionDependency(allocator: std.mem.Allocator, dependency_id: []const u8) bool {
    _ = allocator;
    return std.mem.eql(u8, dependency_id, "vscode.git") or
        std.mem.eql(u8, dependency_id, "vscode.docker") or
        std.mem.eql(u8, dependency_id, "vscode.yaml") or
        std.mem.eql(u8, dependency_id, "vscode.typescript-language-features") or
        (std.mem.eql(u8, dependency_id, "ms-python.python") and
            (@import("../runtime_016.zig").hasEnvVar("WIZP_ENABLE_PYTHON_EXTENSION_API_SHIM")));
}

pub fn allowBackgroundActivation(allocator: std.mem.Allocator, publisher: []const u8, id: []const u8) bool {
    if (std.mem.eql(u8, publisher, "redhat") and std.mem.eql(u8, id, "java")) return true;
    const raw = runtime.getEnvVarOwned(allocator, "WIZP_EXTENSION_BACKGROUND_ACTIVATION_ALLOWLIST") catch return false;
    defer allocator.free(raw);
    var it = std.mem.tokenizeAny(u8, raw, ",; \t\r\n");
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, id)) return true;
        if (publisher.len > 0 and entry.len == publisher.len + 1 + id.len and
            std.mem.eql(u8, entry[0..publisher.len], publisher) and
            entry[publisher.len] == '.' and
            std.mem.eql(u8, entry[publisher.len + 1 ..], id)) return true;
    }
    return false;
}

pub fn timeoutMs(allocator: std.mem.Allocator, env_name: []const u8, default_ms: u32) u32 {
    const raw = runtime.getEnvVarOwned(allocator, env_name) catch return default_ms;
    defer allocator.free(raw);
    return std.fmt.parseInt(u32, raw, 10) catch default_ms;
}

pub fn identifierMatches(publisher: []const u8, id: []const u8, identifier: []const u8) bool {
    if (std.mem.eql(u8, id, identifier)) return true;
    if (publisher.len == 0) return false;
    if (identifier.len != publisher.len + 1 + id.len) return false;
    return std.mem.eql(u8, identifier[0..publisher.len], publisher) and
        identifier[publisher.len] == '.' and
        std.mem.eql(u8, identifier[publisher.len + 1 ..], id);
}

test "extension policy keeps built-in dependency shims narrow" {
    try std.testing.expect(isShimmedExtensionDependency(std.testing.allocator, "vscode.git"));
    try std.testing.expect(isShimmedExtensionDependency(std.testing.allocator, "vscode.docker"));
    try std.testing.expect(isShimmedExtensionDependency(std.testing.allocator, "vscode.yaml"));
    try std.testing.expect(isShimmedExtensionDependency(std.testing.allocator, "vscode.typescript-language-features"));
    try std.testing.expect(!isShimmedExtensionDependency(std.testing.allocator, "example.other"));
    try std.testing.expect(!isShimmedExtensionDependency(std.testing.allocator, "vscode.git.extra"));
    try std.testing.expect(!isShimmedExtensionDependency(std.testing.allocator, "ms-python.python.extra"));
}

test "extension policy matches publisher-qualified background ids" {
    try std.testing.expect(allowBackgroundActivation(std.testing.allocator, "redhat", "java"));
    try std.testing.expect(!allowBackgroundActivation(std.testing.allocator, "example", "other"));
    try std.testing.expect(!allowBackgroundActivation(std.testing.allocator, "redhat", "javascript"));
    try std.testing.expect(!allowBackgroundActivation(std.testing.allocator, "redhatx", "java"));
    try std.testing.expect(!allowBackgroundActivation(std.testing.allocator, "redhat", "java.extra"));
}

test "extension policy uses safe timeout defaults" {
    try std.testing.expectEqual(@as(u32, 1234), timeoutMs(std.testing.allocator, "WIZP_TEST_MISSING_TIMEOUT", 1234));
}

test "extension policy matches qualified extension identifiers" {
    try std.testing.expect(identifierMatches("redhat", "java", "redhat.java"));
    try std.testing.expect(identifierMatches("redhat", "java", "java"));
    try std.testing.expect(!identifierMatches("redhat", "java", "other.java"));
}
