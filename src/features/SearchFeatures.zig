// Search features: find in files, goto anything, fuzzy matching
// Reuses patterns from flow's ripgrep integration

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;

/// Find-in-files result
pub const SearchResult = struct {
    file_path: []const u8,
    line_number: usize,
    col: usize,
    line_text: []const u8,
    match_start: usize,
    match_end: usize,
};

/// Find-in-files configuration
pub const SearchConfig = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    file_pattern: []const u8 = "*",
    case_sensitive: bool = false,
    whole_word: bool = false,
    regex: bool = false,
    max_results: usize = 1000,
};

/// Search engine using built-in string matching (no external deps)
pub const SearchEngine = struct {
    allocator: Allocator,
    results: std.array_list.Managed(SearchResult),

    pub fn init(allocator: Allocator) SearchEngine {
        return .{ .allocator = allocator };
    }

    /// Search across files in a directory
    pub fn search(self: *SearchEngine, config: SearchConfig) ![]const SearchResult {
        self.results.clearRetainingCapacity();

        var dir = try std.Io.Dir.cwd().openDir(
            runtime.io(),
            config.path,
            .{ .iterate = true },
        );
        defer dir.close(runtime.io());

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(runtime.io())) |entry| {
            if (entry.kind != .file) continue;
            if (!matchGlob(entry.basename, config.file_pattern)) continue;
            if (self.results.items.len >= config.max_results) break;

            const full_path = try std.fs.path.join(self.allocator, &.{ config.path, entry.path });
            defer self.allocator.free(full_path);

            try self.searchFile(full_path, config);
        }

        return self.results.items;
    }

    /// Search within a single file
    fn searchFile(self: *SearchEngine, file_path: []const u8, config: SearchConfig) !void {
        const content = try runtime.readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_num: usize = 1;
        while (lines.next()) |line| : (line_num += 1) {
            if (self.results.items.len >= config.max_results) break;

            var search_line = line;
            var search_pattern = config.pattern;

            if (!config.case_sensitive) {
                // Simple case-folded search
                const lower_line = try std.ascii.allocLowerString(self.allocator, line);
                defer self.allocator.free(lower_line);
                const lower_pattern = try std.ascii.allocLowerString(self.allocator, config.pattern);
                defer self.allocator.free(lower_pattern);
                search_line = lower_line;
                search_pattern = lower_pattern;
            }

            if (std.mem.indexOf(u8, search_line, search_pattern)) |col| {
                const path_dup = try self.allocator.dupe(u8, file_path);
                const line_dup = try self.allocator.dupe(u8, line);
                try self.results.append(.{
                    .file_path = path_dup,
                    .line_number = line_num,
                    .col = col,
                    .line_text = line_dup,
                    .match_start = col,
                    .match_end = col + config.pattern.len,
                });
            }
        }
    }

    pub fn deinit(self: *SearchEngine) void {
        for (self.results.items) |r| {
            self.allocator.free(r.file_path);
            self.allocator.free(r.line_text);
        }
        self.results.deinit();
    }
};

/// Goto Anything - fuzzy file finder and symbol search
pub const GotoAnything = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) GotoAnything {
        return .{ .allocator = allocator };
    }

    /// Fuzzy match a query against a list of strings
    /// Returns scored matches sorted by relevance
    pub fn fuzzyMatch(allocator: Allocator, query: []const u8, candidates: []const []const u8) ![]const FuzzyMatch {
        var matches = std.array_list.Managed(FuzzyMatch).init(allocator);

        for (candidates) |candidate| {
            if (fuzzyScore(query, candidate)) |score| {
                try matches.append(.{ .text = candidate, .score = score });
            }
        }

        // Sort by score descending
        std.mem.sort(FuzzyMatch, matches.items, {}, struct {
            fn lt(_: void, a: FuzzyMatch, b: FuzzyMatch) bool {
                return a.score > b.score;
            }
        }.lt);

        return matches.toOwnedSlice();
    }

    /// Scan a directory for files matching a glob pattern
    pub fn scanFiles(allocator: Allocator, root: []const u8, pattern: []const u8, max_depth: usize) ![]const []const u8 {
        var files = std.array_list.Managed([]const u8).init(allocator);

        var dir = try std.Io.Dir.cwd().openDir(
            runtime.io(),
            root,
            .{ .iterate = true },
        );
        defer dir.close(runtime.io());

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(runtime.io())) |entry| {
            if (entry.kind != .file) continue;
            if (entry.depth() > max_depth) continue;
            if (!matchGlob(entry.basename, pattern)) continue;

            const full = try std.fs.path.join(allocator, &.{ root, entry.path });
            try files.append(full);
        }

        return files.toOwnedSlice();
    }

    pub const FuzzyMatch = struct {
        text: []const u8,
        score: usize,
    };
};

/// Fuzzy scoring: higher score = better match
fn fuzzyScore(query: []const u8, candidate: []const u8) ?usize {
    if (query.len == 0) return 0;
    if (candidate.len == 0) return null;

    var score: usize = 0;
    var qi: usize = 0;
    var prev_match: bool = false;

    for (candidate, 0..) |ch, i| {
        if (qi >= query.len) break;

        const qch = query[qi];
        if (std.ascii.toLower(ch) == std.ascii.toLower(qch)) {
            // Bonus for consecutive matches
            if (prev_match) score += 2;
            // Bonus for matching at start or after separator
            if (i == 0 or candidate[i - 1] == '_' or candidate[i - 1] == '-' or
                candidate[i - 1] == '/' or candidate[i - 1] == '.')
            {
                score += 10;
            }
            // Bonus for case match
            if (ch == qch) score += 5;

            score += 1;
            qi += 1;
            prev_match = true;
        } else {
            prev_match = false;
        }
    }

    if (qi < query.len) return null;
    return score;
}

pub const ReplaceResult = struct {
    file_path: []const u8,
    replacements: usize,
    error_msg: ?[]const u8,
};

pub const SearchReplace = struct {
    allocator: Allocator,
    results: std.array_list.Managed(ReplaceResult),

    pub fn init(allocator: Allocator) SearchReplace {
        return .{ .allocator = allocator };
    }

    pub fn replace(self: *SearchReplace, config: SearchConfig, replacement: []const u8) ![]const ReplaceResult {
        self.results.clearRetainingCapacity();

        var dir = try std.Io.Dir.cwd().openDir(
            runtime.io(),
            config.path,
            .{ .iterate = true },
        );
        defer dir.close(runtime.io());

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(runtime.io())) |entry| {
            if (entry.kind != .file) continue;
            if (!matchGlob(entry.basename, config.file_pattern)) continue;

            const full_path = try std.fs.path.join(self.allocator, &.{ config.path, entry.path });
            defer self.allocator.free(full_path);

            const path_dup = try self.allocator.dupe(u8, full_path);
            var error_msg: ?[]const u8 = null;
            var count: usize = 0;

            if (self.doReplace(full_path, config, replacement)) |c| {
                count = c;
            } else |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "{}", .{err});
                self.allocator.free(path_dup);
                error_msg = msg;
                try self.results.append(.{
                    .file_path = try self.allocator.dupe(u8, full_path),
                    .replacements = 0,
                    .error_msg = error_msg,
                });
                continue;
            }

            try self.results.append(.{
                .file_path = path_dup,
                .replacements = count,
                .error_msg = null,
            });
        }

        return self.results.items;
    }

    fn doReplace(self: *SearchReplace, file_path: []const u8, config: SearchConfig, replacement: []const u8) !usize {
        var content = runtime.readFileAlloc(
            self.allocator,
            file_path,
            10 * 1024 * 1024,
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.FileTooLarge,
            else => |other| return other,
        };
        defer self.allocator.free(content);

        const check_len = @min(content.len, 512);
        for (content[0..check_len]) |byte| {
            if (byte == 0) return error.BinaryFile;
        }

        var count: usize = 0;
        var search_content = content;
        var search_pattern = config.pattern;

        var lower_content_lower: ?[]u8 = null;
        var lower_pattern: ?[]u8 = null;
        defer {
            if (lower_content_lower) |lc| self.allocator.free(lc);
            if (lower_pattern) |lp| self.allocator.free(lp);
        }

        if (!config.case_sensitive) {
            lower_content_lower = try std.ascii.allocLowerString(self.allocator, content);
            lower_pattern = try std.ascii.allocLowerString(self.allocator, config.pattern);
            search_content = lower_content_lower.?;
            search_pattern = lower_pattern.?;
        }

        var search_offset: usize = 0;
        while (search_offset < search_content.len) {
            const remaining = search_content[search_offset..];
            if (std.mem.indexOf(u8, remaining, search_pattern)) |idx| {
                count += 1;
                search_offset += idx + search_pattern.len;
            } else {
                break;
            }
        }

        if (count == 0) return 0;

        if (config.case_sensitive) {
            const new_content = try std.mem.replaceOwned(u8, self.allocator, content, config.pattern, replacement);
            self.allocator.free(content);
            try runtime.writeFile(file_path, new_content);
            self.allocator.free(new_content);
        } else {
            var new_content = std.array_list.Managed(u8).init(self.allocator);
            defer new_content.deinit();

            var write_offset: usize = 0;
            search_offset = 0;
            while (search_offset < search_content.len) {
                const remaining = search_content[search_offset..];
                if (std.mem.indexOf(u8, remaining, search_pattern)) |idx| {
                    try new_content.appendSlice(content[write_offset .. search_offset + idx]);
                    try new_content.appendSlice(replacement);
                    write_offset = search_offset + idx + config.pattern.len;
                    search_offset = write_offset;
                } else {
                    break;
                }
            }
            try new_content.appendSlice(content[write_offset..]);

            try runtime.writeFile(file_path, new_content.items);
        }

        return count;
    }

    pub fn deinit(self: *SearchReplace) void {
        for (self.results.items) |r| {
            self.allocator.free(r.file_path);
            if (r.error_msg) |msg| self.allocator.free(msg);
        }
        self.results.deinit();
    }
};

/// Simple glob matching (* and ? wildcards)
fn matchGlob(name: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.indexOf(u8, pattern, "*") == null and std.mem.indexOf(u8, pattern, "?") == null) {
        return std.mem.eql(u8, name, pattern);
    }

    var ni: usize = 0;
    var pi: usize = 0;
    var star_idx: i32 = -1;
    var match_idx: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == name[ni])) {
            ni += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_idx = @intCast(pi);
            match_idx = ni;
            pi += 1;
        } else if (star_idx >= 0) {
            pi = @intCast(star_idx + 1);
            match_idx += 1;
            ni = match_idx;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
    return pi == pattern.len;
}
