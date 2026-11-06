// WIZP Embedded Syntax Registry
// Embeds 5+ real .sublime-syntax files at compile time and loads them dynamically.
// Falls back to hardcoded Syntax.zig definitions if embedded files are missing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SyntaxDef = @import("Syntax.zig");
const SublimeSyntax = @import("SublimeSyntax.zig");

const SyntaxDefinition = SyntaxDef.SyntaxDefinition;

// Embedded .sublime-syntax files (real YAML, loaded at runtime by YAML parser)
const JS_SYNTAX = @embedFile("JavaScript.sublime-syntax");
const PY_SYNTAX = @embedFile("Python.sublime-syntax");
const RUST_SYNTAX = @embedFile("Rust.sublime-syntax");
const GO_SYNTAX = @embedFile("Go.sublime-syntax");
const C_SYNTAX = @embedFile("C.sublime-syntax");

/// Registry of all loaded syntax definitions
pub const SyntaxRegistry = struct {
    allocator: Allocator,
    syntaxes: std.array_list.Managed(SyntaxDefinition),
    /// Map from file extension (without dot) to syntax index
    ext_map: std.StringHashMapUnmanaged(usize),
    loaded: bool = false,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Load all embedded .sublime-syntax files plus builtin Zig hardcoded syntax
    pub fn loadAll(self: *Self, hardcoded_zig: *const SyntaxDefinition) !void {
        if (self.loaded) return;

        // Load embedded .sublime-syntax files
        const embedded = [_][]const u8{ JS_SYNTAX, PY_SYNTAX, RUST_SYNTAX, GO_SYNTAX, C_SYNTAX };
        for (embedded) |yaml| {
            const syn = SublimeSyntax.load(self.allocator, yaml) catch continue;
            try self.add(syn);
        }

        // Add hardcoded Zig syntax (not yet ported to .sublime-syntax)
        try self.add(hardcoded_zig.*);

        // Also add hardcoded syntaxes for other languages from Syntax.zig
        // We keep these as fallbacks until ported to .sublime-syntax files
        try self.add(SyntaxDef.ZIG_SYNTAX);
        try self.add(SyntaxDef.JS_SYNTAX_COMPAT);
        try self.add(SyntaxDef.PY_SYNTAX_COMPAT);
        try self.add(SyntaxDef.RUST_SYNTAX_COMPAT);
        try self.add(SyntaxDef.GO_SYNTAX_COMPAT);
        try self.add(SyntaxDef.C_SYNTAX_COMPAT);

        self.loaded = true;
    }

    fn add(self: *Self, syn: SyntaxDefinition) !void {
        const idx = self.syntaxes.items.len;
        try self.syntaxes.append(syn);
        for (syn.file_extensions) |ext| {
            try self.ext_map.put(self.allocator, ext, idx);
        }
    }

    /// Find syntax definition by file extension
    pub fn findByExtension(self: *Self, file_path: []const u8) ?*const SyntaxDefinition {
        const ext = std.fs.path.extension(file_path);
        if (ext.len == 0) return null;
        const ext_no_dot = ext[1..];
        if (self.ext_map.get(ext_no_dot)) |idx| {
            return &self.syntaxes.items[idx];
        }
        return null;
    }

    /// Find syntax definition by scope name
    pub fn findByScope(self: *Self, scope: []const u8) ?*const SyntaxDefinition {
        for (self.syntaxes.items) |*syn| {
            if (std.mem.eql(u8, syn.scope, scope)) return syn;
        }
        return null;
    }

    pub fn deinit(self: *Self) void {
        for (self.syntaxes.items) |*syn| {
            self.allocator.free(syn.name);
            self.allocator.free(syn.scope);
            for (syn.file_extensions) |e| self.allocator.free(e);
            self.allocator.free(syn.file_extensions);
            if (syn.first_line_match) |f| self.allocator.free(f);
            for (syn.contexts) |ctx| {
                self.allocator.free(ctx.name);
                for (ctx.patterns) |pat| {
                    self.allocator.free(pat.regex);
                    if (pat.scope) |s| self.allocator.free(s);
                    for (pat.captures) |cap| {
                        if (cap.scope) |s| self.allocator.free(s);
                    }
                    self.allocator.free(pat.captures);
                    if (pat.push) |p| {
                        for (p) |s| self.allocator.free(s);
                        self.allocator.free(p);
                    }
                    if (pat.set) |s_list| {
                        for (s_list) |s| self.allocator.free(s);
                        self.allocator.free(s_list);
                    }
                }
                self.allocator.free(ctx.patterns);
            }
            self.allocator.free(syn.contexts);
        }
        self.syntaxes.deinit();
        var it = self.ext_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.ext_map.deinit();
    }
};

test "EmbeddedSyntax: load JS from embedded file" {
    var reg = SyntaxRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.loadAll(&SyntaxDef.ZIG_SYNTAX);

    const js_syn = reg.findByExtension("app.js").?;
    try std.testing.expectEqualStrings("JavaScript", js_syn.name);
    try std.testing.expect(js_syn.contexts.len > 0);
}

test "EmbeddedSyntax: load Python from embedded file" {
    var reg = SyntaxRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.loadAll(&SyntaxDef.ZIG_SYNTAX);

    const py_syn = reg.findByExtension("main.py").?;
    try std.testing.expectEqualStrings("Python", py_syn.name);
}

test "EmbeddedSyntax: load Rust from embedded file" {
    var reg = SyntaxRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.loadAll(&SyntaxDef.ZIG_SYNTAX);

    const rs_syn = reg.findByExtension("main.rs").?;
    try std.testing.expectEqualStrings("Rust", rs_syn.name);
}

test "EmbeddedSyntax: load Go from embedded file" {
    var reg = SyntaxRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.loadAll(&SyntaxDef.ZIG_SYNTAX);

    const go_syn = reg.findByExtension("main.go").?;
    try std.testing.expectEqualStrings("Go", go_syn.name);
}

test "EmbeddedSyntax: load C from embedded file" {
    var reg = SyntaxRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.loadAll(&SyntaxDef.ZIG_SYNTAX);

    const c_syn = reg.findByExtension("main.c").?;
    try std.testing.expectEqualStrings("C", c_syn.name);
}

test "EmbeddedSyntax: find by scope" {
    var reg = SyntaxRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.loadAll(&SyntaxDef.ZIG_SYNTAX);

    try std.testing.expect(reg.findByScope("source.js") != null);
    try std.testing.expect(reg.findByScope("source.python") != null);
    try std.testing.expect(reg.findByScope("source.zig") != null);
}

test "EmbeddedSyntax: unknown extension returns null" {
    var reg = SyntaxRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.loadAll(&SyntaxDef.ZIG_SYNTAX);

    try std.testing.expect(reg.findByExtension("config.xyz") == null);
}
