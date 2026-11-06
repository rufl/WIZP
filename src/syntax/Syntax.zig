// Sublime Text .sublime-syntax compatible syntax highlighting for WIZP
// Uses built-in static definitions for 15+ languages - ultra lightweight

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Scope = []const u8;

pub const MatchPattern = struct {
    regex: []const u8,
    scope: ?[]const u8 = null,
    captures: []const Capture = &.{},
    push: ?[]const []const u8 = null,
    set: ?[]const []const u8 = null,
    pop: bool = false,

    pub const Capture = struct {
        index: usize,
        scope: ?[]const u8 = null,
        patterns: ?[]const MatchPattern = null,
    };
};

pub const Context = struct {
    name: []const u8,
    patterns: []const MatchPattern = &.{},
    meta_scope: ?[]const u8 = null,
    meta_content_scope: ?[]const u8 = null,
};

pub const SyntaxDefinition = struct {
    name: []const u8,
    scope: []const u8,
    file_extensions: []const []const u8 = &.{},
    first_line_match: ?[]const u8 = null,
    contexts: []const Context = &.{},
    hidden: bool = false,
    variables: Variables = .{ .entries = .{} },

    pub const Variables = struct { entries: std.StringHashMapUnmanaged([]const u8) };

    // clone() intentionally removed — SyntaxDefinitions hold comptime data
    // and shallow-copy would create dangling pointer hazards. Use the original
    // SyntaxDefinition directly; all builtin syntaxes are comptime constants.
};

pub const Token = struct {
    start: usize,
    len: usize,
    scope: Scope,
};

pub const Highlighter = struct {
    syntax: *const SyntaxDefinition,
    context_stack: std.array_list.Managed([]const u8),

    pub fn init(allocator: Allocator, syntax: *const SyntaxDefinition) !Highlighter {
        var hl = Highlighter{ .syntax = syntax, .context_stack = std.array_list.Managed([]const u8).init(allocator) };
        try hl.context_stack.append("main");
        return hl;
    }

    pub fn deinit(self: *Highlighter) void {
        self.context_stack.deinit();
    }
};

// ============================================================
// Built-in syntax definitions
// ============================================================

const ZIG_PATTERNS = [_]MatchPattern{
    .{ .regex = "//[^\n]*", .scope = "comment.line.zig" },
    .{ .regex = "\"[^\"]*\"", .scope = "string.quoted.double.zig" },
    .{ .regex = "\\b(const|var|pub|fn|if|else|while|for|return|try|catch|defer|errdefer|switch|orelse|and|or|asm|usingnamespace|struct|enum|union|error|test|export|extern|inline|noinline|comptime|threadlocal|allowzero|volatile|linksection|callconv|anytype|anyframe|nosuspend|suspend|resume|async|await)\\b", .scope = "keyword.control.zig" },
    .{ .regex = "\\b(bool|void|noreturn|anyerror|anyopaque|type|isize|usize|f16|f32|f64|f80|f128|i8|i16|i32|i64|i128|u8|u16|u32|u64|u128|c_char|c_short|c_ushort|c_int|c_uint|c_long|c_ulong|c_longlong|c_ulonglong)\\b", .scope = "storage.type.zig" },
    .{ .regex = "\\b@[a-zA-Z_][a-zA-Z0-9_]*\\b", .scope = "support.function.builtin.zig" },
    .{ .regex = "\\b[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\b|\\b0[xX][0-9a-fA-F]+\\b|\\b0[oO][0-7]+\\b|\\b0[bB][01]+\\b", .scope = "constant.numeric.zig" },
    .{ .regex = "\\b[a-zA-Z_][a-zA-Z0-9_]*\\b", .scope = "variable.other.zig" },
    .{ .regex = "[+\\-*/%&|^~!<>=\\.\\?]+", .scope = "keyword.operator.zig" },
};

const RUST_PATTERNS = [_]MatchPattern{
    .{ .regex = "//[^\n]*", .scope = "comment.line.rust" },
    .{ .regex = "\"[^\"]*\"", .scope = "string.quoted.double.rust" },
    .{ .regex = "\\b(fn|let|mut|if|else|while|for|in|loop|match|return|break|continue|use|mod|pub|impl|trait|struct|enum|type|where|as|async|await|dyn|move|ref|static|const|unsafe|extern|crate|super|self|Self)\\b", .scope = "keyword.control.rust" },
    .{ .regex = "\\b(bool|char|str|i8|i16|i32|i64|i128|isize|u8|u16|u32|u64|u128|usize|f32|f64|String|Vec|Option|Result|Box|HashMap|HashSet)\\b", .scope = "storage.type.rust" },
    .{ .regex = "\\b[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\b", .scope = "constant.numeric.rust" },
    .{ .regex = "[+\\-*/%&|^~!<>=\\.\\?]+", .scope = "keyword.operator.rust" },
};

const C_PATTERNS = [_]MatchPattern{
    .{ .regex = "//[^\n]*", .scope = "comment.line.c" },
    .{ .regex = "/\\*.*?\\*/", .scope = "comment.block.c" },
    .{ .regex = "\"[^\"]*\"", .scope = "string.quoted.double.c" },
    .{ .regex = "\\b(if|else|while|for|do|switch|case|default|break|continue|return|goto|sizeof|typedef|struct|union|enum|static|extern|const|volatile|register|auto|inline|restrict)\\b", .scope = "keyword.control.c" },
    .{ .regex = "\\b(void|char|short|int|long|float|double|signed|unsigned|_Bool|_Complex|size_t|ssize_t|int8_t|int16_t|int32_t|int64_t|uint8_t|uint16_t|uint32_t|uint64_t)\\b", .scope = "storage.type.c" },
    .{ .regex = "\\b[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\b|0[xX][0-9a-fA-F]+\\b", .scope = "constant.numeric.c" },
    .{ .regex = "#\\s*(include|define|ifdef|ifndef|if|else|elif|endif|pragma|error|warning|undef|line)\\b", .scope = "keyword.control.preprocessor.c" },
};

const PYTHON_PATTERNS = [_]MatchPattern{
    .{ .regex = "#[^\n]*", .scope = "comment.line.python" },
    .{ .regex = "\"\"\"[^\"]*\"\"\"", .scope = "string.quoted.double.block.python" },
    .{ .regex = "\"[^\"]*\"", .scope = "string.quoted.double.python" },
    .{ .regex = "'[^']*'", .scope = "string.quoted.single.python" },
    .{ .regex = "\\b(def|class|if|elif|else|while|for|in|try|except|finally|with|as|import|from|raise|return|yield|break|continue|pass|assert|del|global|nonlocal|lambda|async|await|and|or|not|is|True|False|None)\\b", .scope = "keyword.control.python" },
    .{ .regex = "\\b(int|float|str|bool|list|dict|tuple|set|bytes|bytearray|complex|object|type|super|property)\\b", .scope = "storage.type.python" },
    .{ .regex = "\\b[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\b|0[xX][0-9a-fA-F]+\\b", .scope = "constant.numeric.python" },
    .{ .regex = "\\b(self|cls)\\b", .scope = "variable.language.python" },
};

const JS_PATTERNS = [_]MatchPattern{
    .{ .regex = "//[^\n]*", .scope = "comment.line.js" },
    .{ .regex = "/\\*.*?\\*/", .scope = "comment.block.js" },
    .{ .regex = "\"[^\"]*\"", .scope = "string.quoted.double.js" },
    .{ .regex = "'[^']*'", .scope = "string.quoted.single.js" },
    .{ .regex = "`[^`]*`", .scope = "string.template.js" },
    .{ .regex = "\\b(if|else|while|for|do|switch|case|break|continue|return|throw|try|catch|finally|new|delete|typeof|instanceof|in|of|class|extends|super|import|export|default|from|as|async|await|yield|function|var|let|const)\\b", .scope = "keyword.control.js" },
    .{ .regex = "\\b(true|false|null|undefined|NaN|Infinity|this|arguments|globalThis)\\b", .scope = "constant.language.js" },
    .{ .regex = "\\b[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\b|0[xX][0-9a-fA-F]+\\b", .scope = "constant.numeric.js" },
    .{ .regex = "\\b(console|Math|JSON|Promise|Array|Object|String|Number|Boolean|RegExp|Date|Map|Set|Symbol|Error|parseInt|parseFloat)\\b", .scope = "support.function.js" },
};

const GO_PATTERNS = [_]MatchPattern{
    .{ .regex = "//[^\n]*", .scope = "comment.line.go" },
    .{ .regex = "\"[^\"]*\"", .scope = "string.quoted.double.go" },
    .{ .regex = "`[^`]*`", .scope = "string.quoted.raw.go" },
    .{ .regex = "\\b(func|package|import|if|else|for|range|switch|case|default|break|continue|return|go|defer|select|chan|type|struct|interface|map|var|const)\\b", .scope = "keyword.control.go" },
    .{ .regex = "\\b(bool|byte|complex64|complex128|error|float32|float64|int|int8|int16|int32|int64|rune|string|uint|uint8|uint16|uint32|uint64|uintptr|nil|true|false|iota)\\b", .scope = "storage.type.go" },
    .{ .regex = "\\b[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\b|0[xX][0-9a-fA-F]+\\b", .scope = "constant.numeric.go" },
};

const JSON_PATTERNS = [_]MatchPattern{
    .{ .regex = "\"(?:[^\"\\\\]|\\\\.)*\"", .scope = "string.quoted.double.json" },
    .{ .regex = "\\b[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\b", .scope = "constant.numeric.json" },
    .{ .regex = "\\b(true|false|null)\\b", .scope = "constant.language.json" },
};

const YAML_PATTERNS = [_]MatchPattern{
    .{ .regex = "#[^\n]*", .scope = "comment.line.yaml" },
    .{ .regex = "\"[^\"]*\"", .scope = "string.quoted.double.yaml" },
    .{ .regex = "'[^']*'", .scope = "string.quoted.single.yaml" },
    .{ .regex = "\\b(true|false|null|yes|no|on|off)\\b", .scope = "constant.language.yaml" },
    .{ .regex = "\\b[0-9]+(?:\\.[0-9]+)?\\b", .scope = "constant.numeric.yaml" },
    .{ .regex = "^[a-zA-Z_][a-zA-Z0-9_]*(?=\\s*:)", .scope = "entity.name.tag.yaml" },
};

const TOML_PATTERNS = [_]MatchPattern{
    .{ .regex = "#[^\n]*", .scope = "comment.line.toml" },
    .{ .regex = "\"[^\"]*\"", .scope = "string.quoted.double.toml" },
    .{ .regex = "'[^']*'", .scope = "string.quoted.single.toml" },
    .{ .regex = "\\b(true|false)\\b", .scope = "constant.language.toml" },
    .{ .regex = "\\b[0-9]+(?:\\.[0-9]+)?\\b", .scope = "constant.numeric.toml" },
    .{ .regex = "^\\s*\\[[^\\]]+\\]", .scope = "entity.name.section.toml" },
};

const MARKDOWN_PATTERNS = [_]MatchPattern{
    .{ .regex = "^#{1,6}\\s.*$", .scope = "markup.heading.markdown" },
    .{ .regex = "\\*\\*[^*]+\\*\\*", .scope = "markup.bold.markdown" },
    .{ .regex = "\\*[^*]+\\*", .scope = "markup.italic.markdown" },
    .{ .regex = "`[^`]+`", .scope = "markup.raw.inline.markdown" },
    .{ .regex = "```[^`]*```", .scope = "markup.raw.block.markdown" },
    .{ .regex = "^\\s*[-*+]\\s", .scope = "markup.list.unnumbered.markdown" },
    .{ .regex = "^\\s*\\d+\\.\\s", .scope = "markup.list.numbered.markdown" },
    .{ .regex = "\\[([^\\]]*)\\]\\(([^\\)]*)\\)", .scope = "markup.link.markdown" },
    .{ .regex = "^>\\s.*$", .scope = "markup.quote.markdown" },
    .{ .regex = "^-{3,}$", .scope = "markup.hr.markdown" },
};

const HTML_PATTERNS = [_]MatchPattern{
    .{ .regex = "<!--.*?-->", .scope = "comment.block.html" },
    .{ .regex = "</?[a-zA-Z][a-zA-Z0-9_-]*\\b[^>]*>", .scope = "meta.tag.html" },
    .{ .regex = "[a-zA-Z-]+=\"[^\"]*\"", .scope = "entity.other.attribute-name.html" },
    .{ .regex = "&[a-zA-Z]+;", .scope = "constant.character.entity.html" },
};

const CSS_PATTERNS = [_]MatchPattern{
    .{ .regex = "/\\*.*?\\*/", .scope = "comment.block.css" },
    .{ .regex = "[.#]?[a-zA-Z][a-zA-Z0-9_-]*\\s*\\{", .scope = "entity.name.tag.css" },
    .{ .regex = "[a-zA-Z-]+\\s*:", .scope = "support.type.property-name.css" },
    .{ .regex = "#[0-9a-fA-F]{3,8}\\b", .scope = "constant.other.color.css" },
    .{ .regex = "\\b[0-9]+(?:\\.[0-9]+)?(?:px|em|rem|%|vh|vw|vmin|vmax|ms|s|deg|rad)?\\b", .scope = "constant.numeric.css" },
    .{ .regex = "\\b(none|auto|inherit|initial|unset|block|inline|flex|grid|absolute|relative|fixed|static|sticky|hidden|visible|scroll|center|left|right|top|bottom|bold|normal|italic|underline|solid|dashed|dotted|transparent|important)\\b", .scope = "support.constant.css" },
};

const BASH_PATTERNS = [_]MatchPattern{
    .{ .regex = "#[^\n]*", .scope = "comment.line.shell" },
    .{ .regex = "\"[^\"]*\"", .scope = "string.quoted.double.shell" },
    .{ .regex = "'[^']*'", .scope = "string.quoted.single.shell" },
    .{ .regex = "\\b(if|then|else|elif|fi|for|while|do|done|in|case|esac|function|return|exit|break|continue|local|export|readonly|declare|typeset|unset|shift|source|eval|exec|trap)\\b", .scope = "keyword.control.shell" },
    .{ .regex = "\\b(echo|cd|ls|cat|grep|sed|awk|curl|wget|mkdir|rm|cp|mv|chmod|chown|ps|kill|env|export|printf|test)\\b", .scope = "support.function.builtin.shell" },
    .{ .regex = "\\$[a-zA-Z_][a-zA-Z0-9_]*", .scope = "variable.other.shell" },
    .{ .regex = "\\b[0-9]+\\b", .scope = "constant.numeric.shell" },
};

const LUA_PATTERNS = [_]MatchPattern{
    .{ .regex = "--[^\n]*", .scope = "comment.line.lua" },
    .{ .regex = "--\\[\\[.*?\\]\\]", .scope = "comment.block.lua" },
    .{ .regex = "\"[^\"]*\"", .scope = "string.quoted.double.lua" },
    .{ .regex = "'[^']*'", .scope = "string.quoted.single.lua" },
    .{ .regex = "\\[\\[[^\\]]*\\]\\]", .scope = "string.multiline.lua" },
    .{ .regex = "\\b(if|then|elseif|else|end|while|do|for|in|repeat|until|break|return|goto|function|local|nil|true|false|and|or|not)\\b", .scope = "keyword.control.lua" },
    .{ .regex = "\\b(string|table|math|io|os|coroutine|package|debug|bit32|utf8)\\b", .scope = "support.function.lua" },
    .{ .regex = "\\b[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\\b|0[xX][0-9a-fA-F]+\\b", .scope = "constant.numeric.lua" },
    .{ .regex = "\\b(self)\\b", .scope = "variable.language.lua" },
};

// Complete definitions
const ZIG_DEF = SyntaxDefinition{
    .name = "zig",
    .scope = "source.zig",
    .file_extensions = &.{ "zig", "zir" },
    .contexts = &.{.{ .name = "main", .patterns = &ZIG_PATTERNS }},
};

const RUST_DEF = SyntaxDefinition{
    .name = "rust",
    .scope = "source.rust",
    .file_extensions = &.{"rs"},
    .contexts = &.{.{ .name = "main", .patterns = &RUST_PATTERNS }},
};

const C_DEF = SyntaxDefinition{
    .name = "c",
    .scope = "source.c",
    .file_extensions = &.{ "c", "h" },
    .contexts = &.{.{ .name = "main", .patterns = &C_PATTERNS }},
};

const PYTHON_DEF = SyntaxDefinition{
    .name = "python",
    .scope = "source.python",
    .file_extensions = &.{ "py", "pyi", "pyx" },
    .contexts = &.{.{ .name = "main", .patterns = &PYTHON_PATTERNS }},
};

const JS_DEF = SyntaxDefinition{
    .name = "javascript",
    .scope = "source.js",
    .file_extensions = &.{ "js", "jsx", "mjs", "cjs" },
    .contexts = &.{.{ .name = "main", .patterns = &JS_PATTERNS }},
};

const TS_PATTERNS = JS_PATTERNS ++ [_]MatchPattern{
    .{ .regex = "\\b(type|interface|enum|namespace|declare|abstract|implements|readonly|keyof|infer|extends|as|satisfies)\\b", .scope = "keyword.control.ts" },
    .{ .regex = "\\b(string|number|boolean|void|any|unknown|never|object|symbol|bigint)\\b", .scope = "storage.type.ts" },
};

const TS_DEF = SyntaxDefinition{
    .name = "typescript",
    .scope = "source.ts",
    .file_extensions = &.{ "ts", "tsx" },
    .contexts = &.{.{ .name = "main", .patterns = &TS_PATTERNS }},
};

const GO_DEF = SyntaxDefinition{
    .name = "go",
    .scope = "source.go",
    .file_extensions = &.{"go"},
    .contexts = &.{.{ .name = "main", .patterns = &GO_PATTERNS }},
};

const JSON_DEF = SyntaxDefinition{
    .name = "json",
    .scope = "source.json",
    .file_extensions = &.{ "json", "jsonc" },
    .contexts = &.{.{ .name = "main", .patterns = &JSON_PATTERNS }},
};

const YAML_DEF = SyntaxDefinition{
    .name = "yaml",
    .scope = "source.yaml",
    .file_extensions = &.{ "yaml", "yml" },
    .contexts = &.{.{ .name = "main", .patterns = &YAML_PATTERNS }},
};

const TOML_DEF = SyntaxDefinition{
    .name = "toml",
    .scope = "source.toml",
    .file_extensions = &.{"toml"},
    .contexts = &.{.{ .name = "main", .patterns = &TOML_PATTERNS }},
};

const MARKDOWN_DEF = SyntaxDefinition{
    .name = "markdown",
    .scope = "text.html.markdown",
    .file_extensions = &.{ "md", "mdx" },
    .contexts = &.{.{ .name = "main", .patterns = &MARKDOWN_PATTERNS }},
};

const HTML_DEF = SyntaxDefinition{
    .name = "html",
    .scope = "text.html.basic",
    .file_extensions = &.{ "html", "htm" },
    .contexts = &.{.{ .name = "main", .patterns = &HTML_PATTERNS }},
};

const CSS_DEF = SyntaxDefinition{
    .name = "css",
    .scope = "source.css",
    .file_extensions = &.{ "css", "scss", "sass", "less" },
    .contexts = &.{.{ .name = "main", .patterns = &CSS_PATTERNS }},
};

const BASH_DEF = SyntaxDefinition{
    .name = "bash",
    .scope = "source.shell",
    .file_extensions = &.{ "sh", "bash", "zsh" },
    .contexts = &.{.{ .name = "main", .patterns = &BASH_PATTERNS }},
};

const LUA_DEF = SyntaxDefinition{
    .name = "lua",
    .scope = "source.lua",
    .file_extensions = &.{"lua"},
    .contexts = &.{.{ .name = "main", .patterns = &LUA_PATTERNS }},
};

/// Get a built-in syntax definition by language name
pub fn builtinSyntax(allocator: Allocator, lang: []const u8) !SyntaxDefinition {
    _ = allocator;
    if (std.mem.eql(u8, lang, "zig")) return ZIG_DEF;
    if (std.mem.eql(u8, lang, "rust")) return RUST_DEF;
    if (std.mem.eql(u8, lang, "c")) return C_DEF;
    if (std.mem.eql(u8, lang, "cpp")) return C_DEF;
    if (std.mem.eql(u8, lang, "python")) return PYTHON_DEF;
    if (std.mem.eql(u8, lang, "javascript")) return JS_DEF;
    if (std.mem.eql(u8, lang, "typescript")) return TS_DEF;
    if (std.mem.eql(u8, lang, "go")) return GO_DEF;
    if (std.mem.eql(u8, lang, "json")) return JSON_DEF;
    if (std.mem.eql(u8, lang, "jsonc")) return JSON_DEF;
    if (std.mem.eql(u8, lang, "yaml")) return YAML_DEF;
    if (std.mem.eql(u8, lang, "toml")) return TOML_DEF;
    if (std.mem.eql(u8, lang, "markdown")) return MARKDOWN_DEF;
    if (std.mem.eql(u8, lang, "html")) return HTML_DEF;
    if (std.mem.eql(u8, lang, "css")) return CSS_DEF;
    if (std.mem.eql(u8, lang, "scss")) return CSS_DEF;
    if (std.mem.eql(u8, lang, "less")) return CSS_DEF;
    if (std.mem.eql(u8, lang, "bash")) return BASH_DEF;
    if (std.mem.eql(u8, lang, "lua")) return LUA_DEF;
    return error.LanguageNotFound;
}

// Public constants for EmbeddedSyntax registry compatibility
pub const ZIG_SYNTAX = ZIG_DEF;
pub const RUST_SYNTAX_COMPAT = RUST_DEF;
pub const C_SYNTAX_COMPAT = C_DEF;
pub const PY_SYNTAX_COMPAT = PYTHON_DEF;
pub const JS_SYNTAX_COMPAT = JS_DEF;
pub const GO_SYNTAX_COMPAT = GO_DEF;

const Lang = enum {
    unknown,
    zig,
    rust,
    c,
    python,
    javascript,
    typescript,
    go,
    json,
    yaml,
    toml,
    bash,
    lua,
};

fn langFromPath(path: []const u8) Lang {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return .unknown;
    const e = ext[1..];
    if (std.mem.eql(u8, e, "zig") or std.mem.eql(u8, e, "zir")) return .zig;
    if (std.mem.eql(u8, e, "rs")) return .rust;
    if (std.mem.eql(u8, e, "c") or std.mem.eql(u8, e, "h") or std.mem.eql(u8, e, "cpp") or std.mem.eql(u8, e, "hpp") or std.mem.eql(u8, e, "cc")) return .c;
    if (std.mem.eql(u8, e, "py") or std.mem.eql(u8, e, "pyi") or std.mem.eql(u8, e, "pyx")) return .python;
    if (std.mem.eql(u8, e, "js") or std.mem.eql(u8, e, "jsx") or std.mem.eql(u8, e, "mjs") or std.mem.eql(u8, e, "cjs")) return .javascript;
    if (std.mem.eql(u8, e, "ts") or std.mem.eql(u8, e, "tsx")) return .typescript;
    if (std.mem.eql(u8, e, "go")) return .go;
    if (std.mem.eql(u8, e, "json") or std.mem.eql(u8, e, "jsonc")) return .json;
    if (std.mem.eql(u8, e, "yaml") or std.mem.eql(u8, e, "yml")) return .yaml;
    if (std.mem.eql(u8, e, "toml")) return .toml;
    if (std.mem.eql(u8, e, "sh") or std.mem.eql(u8, e, "bash") or std.mem.eql(u8, e, "zsh")) return .bash;
    if (std.mem.eql(u8, e, "lua")) return .lua;
    return .unknown;
}

fn isIdentStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_' or ch == '$';
}

fn isIdentCont(ch: u8) bool {
    return isIdentStart(ch) or (ch >= '0' and ch <= '9');
}

fn isKeyword(lang: Lang, ident: []const u8) bool {
    const kws = switch (lang) {
        .zig => &[_][]const u8{
            "const", "var",            "pub",    "fn",   "if",    "else",  "while", "for",    "return", "try",    "catch",    "defer",    "errdefer",    "switch", "orelse", "and", "or",
            "asm",   "usingnamespace", "struct", "enum", "union", "error", "test",  "export", "extern", "inline", "noinline", "comptime", "threadlocal",
        },
        .rust => &[_][]const u8{
            "fn",     "let",  "mut",  "if",    "else", "while", "for",   "in",  "loop", "match", "return", "break", "continue", "use",    "mod",   "pub",   "impl", "trait",
            "struct", "enum", "type", "where", "as",   "async", "await", "dyn", "move", "ref",   "static", "const", "unsafe",   "extern", "crate", "super", "self",
        },
        .c => &[_][]const u8{
            "if",   "else",   "while",  "for",   "do",       "switch",   "case", "default", "break",    "continue", "return", "goto", "sizeof", "typedef", "struct", "union",
            "enum", "static", "extern", "const", "volatile", "register", "auto", "inline",  "restrict",
        },
        .python => &[_][]const u8{
            "def",   "class", "if",       "elif", "else",   "while", "for",    "in",       "try",    "except", "finally", "with", "as", "import", "from", "raise", "return",
            "yield", "break", "continue", "pass", "assert", "del",   "global", "nonlocal", "lambda", "async",  "await",   "and",  "or", "not",    "is",   "True",  "False",
            "None",
        },
        .javascript, .typescript => &[_][]const u8{
            "if",     "else",       "while", "for", "do",    "switch",  "case",  "break",  "continue", "return",  "throw", "try", "catch", "finally", "new",   "delete",
            "typeof", "instanceof", "in",    "of",  "class", "extends", "super", "import", "export",   "default", "from",  "as",  "async", "await",   "yield", "function",
            "var",    "let",        "const",
        },
        .go => &[_][]const u8{
            "func",   "package", "import", "if",     "else",      "for", "range", "switch", "case", "default", "break", "continue", "return", "go", "defer",
            "select", "chan",    "type",   "struct", "interface", "map", "var",   "const",
        },
        .bash => &[_][]const u8{
            "if",    "then",   "else",     "elif",    "fi",      "for",   "while", "do",     "done", "in",   "case", "esac", "function", "return", "exit", "break", "continue",
            "local", "export", "readonly", "declare", "typeset", "unset", "shift", "source", "eval", "exec", "trap",
        },
        .lua => &[_][]const u8{
            "if",   "then",  "elseif", "else", "end", "while", "do", "for", "in", "repeat", "until", "break", "return", "goto", "function", "local", "nil",
            "true", "false", "and",    "or",   "not",
        },
        else => return false,
    };
    for (kws) |kw| {
        if (std.mem.eql(u8, kw, ident)) return true;
    }
    return false;
}

pub fn tokenizeLine(allocator: Allocator, file_path: []const u8, line: []const u8) ![]Token {
    const lang = langFromPath(file_path);
    if (lang == .unknown) return &.{};

    var tokens = std.array_list.Managed(Token).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];

        const line_comment: u8 = switch (lang) {
            .python, .bash, .yaml, .toml => '#',
            else => @as(u8, 0),
        };

        if (lang == .lua and i + 1 < line.len and line[i] == '-' and line[i + 1] == '-') {
            try tokens.append(.{ .start = i, .len = line.len - i, .scope = "comment" });
            break;
        }

        if (line_comment != 0 and ch == line_comment) {
            try tokens.append(.{ .start = i, .len = line.len - i, .scope = "comment" });
            break;
        }

        if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
            try tokens.append(.{ .start = i, .len = line.len - i, .scope = "comment" });
            break;
        }

        if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, line, i + 2, "*/") orelse line.len;
            const len = if (end == line.len) line.len - i else (end + 2) - i;
            try tokens.append(.{ .start = i, .len = len, .scope = "comment" });
            i += len;
            continue;
        }

        if (ch == '"' or ch == '\'') {
            const quote = ch;
            var j = i + 1;
            var esc = false;
            while (j < line.len) : (j += 1) {
                const c = line[j];
                if (esc) {
                    esc = false;
                    continue;
                }
                if (c == '\\') {
                    esc = true;
                    continue;
                }
                if (c == quote) {
                    j += 1;
                    break;
                }
            }
            try tokens.append(.{ .start = i, .len = j - i, .scope = "string" });
            i = j;
            continue;
        }

        if ((lang == .javascript or lang == .typescript) and ch == '`') {
            var j = i + 1;
            while (j < line.len and line[j] != '`') : (j += 1) {}
            if (j < line.len) j += 1;
            try tokens.append(.{ .start = i, .len = j - i, .scope = "string" });
            i = j;
            continue;
        }

        if (ch >= '0' and ch <= '9') {
            var j = i + 1;
            while (j < line.len) : (j += 1) {
                const c = line[j];
                if (!((c >= '0' and c <= '9') or c == '_' or c == '.' or c == 'x' or c == 'X' or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) break;
            }
            try tokens.append(.{ .start = i, .len = j - i, .scope = "constant.numeric" });
            i = j;
            continue;
        }

        if (isIdentStart(ch)) {
            var j = i + 1;
            while (j < line.len and isIdentCont(line[j])) : (j += 1) {}
            const ident = line[i..j];
            if (isKeyword(lang, ident)) {
                try tokens.append(.{ .start = i, .len = j - i, .scope = "keyword" });
            }
            i = j;
            continue;
        }

        i += 1;
    }

    return try tokens.toOwnedSlice();
}

/// Detect language scope name from a file path based on its extension.
/// Returns the canonical language name or null if the extension is unrecognized.
pub fn detectLanguage(filePath: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(filePath);
    if (ext.len == 0) return null;
    const e = ext[1..];
    if (std.mem.eql(u8, e, "zig")) return "zig";
    if (std.mem.eql(u8, e, "ts") or std.mem.eql(u8, e, "tsx")) return "typescript";
    if (std.mem.eql(u8, e, "js") or std.mem.eql(u8, e, "jsx") or std.mem.eql(u8, e, "mjs") or std.mem.eql(u8, e, "cjs")) return "javascript";
    if (std.mem.eql(u8, e, "py") or std.mem.eql(u8, e, "pyi") or std.mem.eql(u8, e, "pyx")) return "python";
    if (std.mem.eql(u8, e, "c") or std.mem.eql(u8, e, "h")) return "c";
    if (std.mem.eql(u8, e, "cpp") or std.mem.eql(u8, e, "hpp") or std.mem.eql(u8, e, "cc") or std.mem.eql(u8, e, "cxx") or std.mem.eql(u8, e, "hh")) return "cpp";
    if (std.mem.eql(u8, e, "rs")) return "rust";
    if (std.mem.eql(u8, e, "go")) return "go";
    if (std.mem.eql(u8, e, "java")) return "java";
    if (std.mem.eql(u8, e, "md") or std.mem.eql(u8, e, "mdx")) return "markdown";
    if (std.mem.eql(u8, e, "json") or std.mem.eql(u8, e, "jsonc")) return "json";
    if (std.mem.eql(u8, e, "html") or std.mem.eql(u8, e, "htm")) return "html";
    if (std.mem.eql(u8, e, "css") or std.mem.eql(u8, e, "scss") or std.mem.eql(u8, e, "sass") or std.mem.eql(u8, e, "less")) return "css";
    if (std.mem.eql(u8, e, "sh") or std.mem.eql(u8, e, "bash") or std.mem.eql(u8, e, "zsh")) return "shell";
    if (std.mem.eql(u8, e, "toml")) return "toml";
    if (std.mem.eql(u8, e, "yaml") or std.mem.eql(u8, e, "yml")) return "yaml";
    if (std.mem.eql(u8, e, "lua")) return "lua";
    return null;
}

/// Return a pointer to the built-in syntax definition for a given scope name.
/// Returns null if no built-in syntax matches the scope.
pub fn getBuiltinSyntax(scope: []const u8) ?*const SyntaxDefinition {
    if (std.mem.eql(u8, scope, "zig")) return &ZIG_DEF;
    if (std.mem.eql(u8, scope, "rust")) return &RUST_DEF;
    if (std.mem.eql(u8, scope, "c")) return &C_DEF;
    if (std.mem.eql(u8, scope, "cpp")) return &C_DEF;
    if (std.mem.eql(u8, scope, "python")) return &PYTHON_DEF;
    if (std.mem.eql(u8, scope, "javascript")) return &JS_DEF;
    if (std.mem.eql(u8, scope, "typescript")) return &TS_DEF;
    if (std.mem.eql(u8, scope, "go")) return &GO_DEF;
    if (std.mem.eql(u8, scope, "json")) return &JSON_DEF;
    if (std.mem.eql(u8, scope, "yaml")) return &YAML_DEF;
    if (std.mem.eql(u8, scope, "toml")) return &TOML_DEF;
    if (std.mem.eql(u8, scope, "markdown")) return &MARKDOWN_DEF;
    if (std.mem.eql(u8, scope, "html")) return &HTML_DEF;
    if (std.mem.eql(u8, scope, "css")) return &CSS_DEF;
    if (std.mem.eql(u8, scope, "shell") or std.mem.eql(u8, scope, "bash")) return &BASH_DEF;
    if (std.mem.eql(u8, scope, "lua")) return &LUA_DEF;
    return null;
}
