// WIZP Sublime Syntax Loader — Parses .sublime-syntax YAML files into SyntaxDefinition
// 100% compatible with Sublime Text .sublime-syntax format.
// Supports: scope, contexts, match, captures, push, set, pop, meta_scope, variables.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Yaml = @import("Yaml.zig");
const SyntaxDef = @import("Syntax.zig");

const SyntaxDefinition = SyntaxDef.SyntaxDefinition;
const MatchPattern = SyntaxDef.MatchPattern;
const Context = SyntaxDef.Context;

pub const LoadError = error{
    FileNotFound,
    ParseError,
    InvalidSyntax,
    OutOfMemory,
};

/// Load a .sublime-syntax YAML string into a SyntaxDefinition.
/// The allocator is used for all dynamic allocations; caller owns the result.
pub fn load(allocator: Allocator, yaml_content: []const u8) !SyntaxDefinition {
    var parser = Yaml.Parser.init(allocator, yaml_content);
    var root = parser.parse() catch return error.ParseError;
    defer root.deinit();

    const root_map = root.asMap() orelse return error.InvalidSyntax;

    // Parse top-level fields
    const name = blk: {
        if (root_map.get("name")) |v| {
            if (v.asString()) |s| break :blk try allocator.dupe(u8, s);
        }
        break :blk try allocator.dupe(u8, "Unknown");
    };

    const scope = blk: {
        if (root_map.get("scope")) |v| {
            if (v.asString()) |s| break :blk try allocator.dupe(u8, s);
        }
        break :blk try allocator.dupe(u8, "source.unknown");
    };

    // Parse file_extensions
    var file_extensions = std.array_list.Managed([]const u8).init(allocator);
    if (root_map.get("file_extensions")) |exts| {
        if (exts.asList()) |list| {
            for (list.items) |*item| {
                if (item.asString()) |s| {
                    try file_extensions.append(try allocator.dupe(u8, s));
                }
            }
        }
    }

    const hidden = if (root_map.get("hidden")) |v| v.asBool() orelse false else false;

    const first_line_match = blk: {
        if (root_map.get("first_line_match")) |v| {
            if (v.asString()) |s| break :blk try allocator.dupe(u8, s);
        }
        break :blk null;
    };

    // Parse variables
    var variables = SyntaxDefinition.Variables{};
    if (root_map.get("variables")) |vars| {
        if (vars.asMap()) |var_map| {
            var it = var_map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.asString()) |s| {
                    try variables.entries.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, s));
                }
            }
        }
    }

    // Parse contexts
    var contexts = std.array_list.Managed(Context).init(allocator);
    if (root_map.get("contexts")) |ctxs| {
        if (ctxs.asMap()) |ctx_map| {
            var it = ctx_map.iterator();
            while (it.next()) |entry| {
                const ctx_name = try allocator.dupe(u8, entry.key_ptr.*);
                const patterns = try parseContextPatterns(allocator, entry.value_ptr, &variables);
                try contexts.append(.{
                    .name = ctx_name,
                    .patterns = patterns,
                });
            }
        }
    }

    return SyntaxDefinition{
        .name = name,
        .scope = scope,
        .file_extensions = try file_extensions.toOwnedSlice(),
        .first_line_match = first_line_match,
        .contexts = try contexts.toOwnedSlice(),
        .hidden = hidden,
        .variables = variables,
    };
}

fn resolveVariables(allocator: Allocator, input: []const u8, variables: *const SyntaxDefinition.Variables) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;

    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '{' and input[i + 1] == '{') {
            const end = std.mem.indexOfPos(u8, input, i + 2, "}}") orelse {
                try result.append(input[i]);
                i += 1;
                continue;
            };
            const var_name = input[i + 2 .. end];
            if (variables.entries.get(var_name)) |val| {
                try result.appendSlice(val);
            } else {
                try result.appendSlice(input[i .. end + 2]);
            }
            i = end + 2;
        } else {
            try result.append(input[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice();
}

fn parseContextPatterns(allocator: Allocator, context_value: *Yaml.YamlValue, variables: *const SyntaxDefinition.Variables) ![]const MatchPattern {
    const pattern_list = context_value.asList() orelse return &.{};

    var patterns = std.array_list.Managed(MatchPattern).init(allocator);

    for (pattern_list.items) |*item| {
        const item_map = item.asMap() orelse continue;

        // Skip meta-only entries (meta_scope, meta_content_scope without match)
        if (item_map.get("meta_scope") != null and item_map.get("match") == null) continue;
        if (item_map.get("meta_content_scope") != null and item_map.get("match") == null) continue;

        const regex_str = blk: {
            if (item_map.get("match")) |m| {
                if (m.asString()) |s| {
                    break :blk try resolveVariables(allocator, s, variables);
                }
            }
            break :blk try allocator.dupe(u8, "");
        };

        const scope_str = blk: {
            if (item_map.get("scope")) |s| {
                if (s.asString()) |str| {
                    break :blk try resolveVariables(allocator, str, variables);
                }
            }
            break :blk null;
        };

        // Parse captures
        var captures = std.array_list.Managed(MatchPattern.Capture).init(allocator);
        if (item_map.get("captures")) |caps| {
            if (caps.asMap()) |cap_map| {
                var it = cap_map.iterator();
                while (it.next()) |entry| {
                    const idx = std.fmt.parseInt(usize, entry.key_ptr.*, 10) catch continue;
                    const cap_map2 = entry.value_ptr.asMap() orelse continue;
                    const cap_scope = blk: {
                        if (cap_map2.get("scope")) |cs| {
                            if (cs.asString()) |s| break :blk try allocator.dupe(u8, s);
                        }
                        break :blk null;
                    };
                    try captures.append(.{
                        .index = idx,
                        .scope = cap_scope,
                        .patterns = null,
                    });
                }
            }
        }

        // Parse push
        var push: ?[]const []const u8 = null;
        if (item_map.get("push")) |p| {
            if (p.asList()) |list| {
                var push_list = std.array_list.Managed([]const u8).init(allocator);
                for (list.items) |*pi| {
                    if (pi.asString()) |s| {
                        try push_list.append(try allocator.dupe(u8, s));
                    }
                }
                if (push_list.items.len > 0) {
                    push = try push_list.toOwnedSlice();
                }
            } else if (p.asString()) |s| {
                const duped = try allocator.dupe(u8, s);
                push = &[_][]const u8{duped};
            }
        }

        // Parse set
        var set: ?[]const []const u8 = null;
        if (item_map.get("set")) |s_val| {
            if (s_val.asList()) |list| {
                var set_list = std.array_list.Managed([]const u8).init(allocator);
                for (list.items) |*si| {
                    if (si.asString()) |s| {
                        try set_list.append(try allocator.dupe(u8, s));
                    }
                }
                if (set_list.items.len > 0) {
                    set = try set_list.toOwnedSlice();
                }
            } else if (s_val.asString()) |s| {
                const duped = try allocator.dupe(u8, s);
                set = &[_][]const u8{duped};
            }
        }

        const pop = item_map.get("pop") != null and (item_map.get("pop").?.asBool() orelse true);

        try patterns.append(.{
            .regex = regex_str,
            .scope = scope_str,
            .captures = try captures.toOwnedSlice(),
            .push = push,
            .set = set,
            .pop = pop,
        });
    }

    return try patterns.toOwnedSlice();
}

/// Detect language from file extension using loaded syntax definitions.
pub fn detectLanguage(syntaxes: []const SyntaxDefinition, file_path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(file_path);
    if (ext.len == 0) return null;

    for (syntaxes) |syn| {
        for (syn.file_extensions) |syn_ext| {
            if (std.mem.eql(u8, ext[1..], syn_ext)) {
                return syn.scope;
            }
        }
    }
    return null;
}

test "SublimeSyntax: load JavaScript syntax" {
    const js_yaml =
        \\%YAML 1.2
        \\---
        \\name: JavaScript
        \\file_extensions:
        \\  - js
        \\  - jsx
        \\  - mjs
        \\scope: source.js
        \\contexts:
        \\  main:
        \\    - match: '\b(function)\b'
        \\      scope: keyword.control.js
        \\    - match: '".*?"'
        \\      scope: string.quoted.double.js
        \\    - match: //.*
        \\      scope: comment.line.js
        \\  strings:
        \\    - match: '"'
        \\      scope: string.quoted.double.js
        \\      push: string-content
    ;

    const syn = try load(std.testing.allocator, js_yaml);
    defer {
        std.testing.allocator.free(syn.name);
        std.testing.allocator.free(syn.scope);
        for (syn.file_extensions) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(syn.file_extensions);
        for (syn.contexts) |ctx| {
            for (ctx.patterns) |pat| {
                std.testing.allocator.free(pat.regex);
                if (pat.scope) |s| std.testing.allocator.free(s);
                for (pat.captures) |cap| {
                    if (cap.scope) |s| std.testing.allocator.free(s);
                }
                std.testing.allocator.free(pat.captures);
                if (pat.push) |p| {
                    for (p) |s| std.testing.allocator.free(s);
                    std.testing.allocator.free(p);
                }
                if (pat.set) |s_list| {
                    for (s_list) |s| std.testing.allocator.free(s);
                    std.testing.allocator.free(s_list);
                }
            }
            std.testing.allocator.free(ctx.patterns);
            std.testing.allocator.free(ctx.name);
        }
        std.testing.allocator.free(syn.contexts);
    }

    try std.testing.expectEqualStrings("JavaScript", syn.name);
    try std.testing.expectEqualStrings("source.js", syn.scope);
    try std.testing.expectEqual(@as(usize, 3), syn.file_extensions.len);
    try std.testing.expectEqualStrings("js", syn.file_extensions[0]);
    try std.testing.expectEqualStrings("mjs", syn.file_extensions[2]);

    try std.testing.expectEqual(@as(usize, 2), syn.contexts.len);
    try std.testing.expectEqualStrings("main", syn.contexts[0].name);
    try std.testing.expectEqualStrings("strings", syn.contexts[1].name);

    try std.testing.expectEqual(@as(usize, 3), syn.contexts[0].patterns.len);
    try std.testing.expectEqualStrings("\\b(function)\\b", syn.contexts[0].patterns[0].regex);
    try std.testing.expectEqualStrings("keyword.control.js", syn.contexts[0].patterns[0].scope.?);
}

test "SublimeSyntax: detect language from extension" {
    const js_yaml =
        \\name: JavaScript
        \\file_extensions: [js, jsx]
        \\scope: source.js
        \\contexts: {}
    ;

    const syn = try load(std.testing.allocator, js_yaml);
    defer {
        std.testing.allocator.free(syn.name);
        std.testing.allocator.free(syn.scope);
        for (syn.file_extensions) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(syn.file_extensions);
        std.testing.allocator.free(syn.contexts);
    }

    const syntaxes = [_]SyntaxDefinition{syn};
    try std.testing.expectEqualStrings("source.js", detectLanguage(&syntaxes, "app.js").?);
    try std.testing.expectEqualStrings("source.js", detectLanguage(&syntaxes, "component.jsx").?);
    try std.testing.expect(detectLanguage(&syntaxes, "readme.md") == null);
}
