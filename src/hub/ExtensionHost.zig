// WIZP Extension Host — Manages VSIX extensions with QuickJS/Bun engine
// Architecture: VS Code-compatible extension API surface over lightweight JS engine.
//
// Lifecycle:
// 1. Discover extensions (scan extension dirs for package.json)
// 2. Load extension manifests (activationEvents, contributes, main)
// 3. Activate on trigger (language, command, startup, workspaceContains)
// 4. Provide VS Code Extension API (vscode.* namespace)
// 5. Deactivate on shutdown
//
// This is the bridge between Zig backend ↔ JS extensions ↔ Monaco frontend.

const std = @import("std");
const compat_runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;
const JSEngine = @import("JSEngine.zig").JSEngine;
const ContentLength = @import("../protocol/ContentLength.zig");
const ExtensionRpc = @import("ExtensionRpc.zig");
const ExtensionPolicy = @import("ExtensionPolicy.zig");
const ManifestParsing = @import("ManifestParsing.zig");
const ExtensionJson = @import("ExtensionJson.zig");

pub const ExtensionHost = struct {
    allocator: Allocator,
    engine: JSEngine,
    extensions: std.StringArrayHashMapUnmanaged(Extension) = .{},
    activated: std.StringArrayHashMapUnmanaged(void) = .{},
    activating: std.StringArrayHashMapUnmanaged(void) = .{},
    triggered_activation_events: std.StringArrayHashMapUnmanaged(void) = .{},
    disabled_extensions: std.StringArrayHashMapUnmanaged(void) = .{},
    extension_dirs: std.ArrayListUnmanaged([]const u8) = .empty,
    context_keys: std.StringArrayHashMapUnmanaged(ContextValue) = .{},
    recovery_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Extension = struct {
        id: []const u8,
        publisher: []const u8,
        name: []const u8,
        version: []const u8,
        ai_key: []const u8 = "",
        path: []const u8, // directory containing package.json
        main: []const u8, // relative path to main JS file
        package_json_raw: []const u8,
        activation_events: []const []const u8,
        extension_dependencies: []const []const u8 = &.{},
        extension_pack: []const []const u8 = &.{},
        contributes: ?Contributes = null,
    };

    const Contributes = struct {
        commands: []CommandContribution = &.{},
        menus: []MenuContribution = &.{},
        keybindings: []KeybindingContribution = &.{},
        configurations: []ConfigurationContribution = &.{},
        languages: []LanguageContribution = &.{},
        grammars: []GrammarContribution = &.{},
        themes: []ThemeContribution = &.{},
        snippets: []SnippetContribution = &.{},
        views_containers: []ViewContainerContribution = &.{},
        views: []ViewContribution = &.{},
        views_welcome: []ViewWelcomeContribution = &.{},
        breakpoints: []BreakpointContribution = &.{},
        json_validations: []JsonValidationContribution = &.{},
        resource_label_formatters: []ResourceLabelFormatterContribution = &.{},
        problem_matchers: []ProblemMatcherContribution = &.{},
        task_definitions: []TaskDefinitionContribution = &.{},
        debuggers: []DebuggerContribution = &.{},
        icon_themes: []IconThemeContribution = &.{},
        walkthroughs: []WalkthroughContribution = &.{},
        semantic_token_scopes: []RawContribution = &.{},
        semantic_token_types: []RawContribution = &.{},
        semantic_token_modifiers: []RawContribution = &.{},
        custom_editors: []RawContribution = &.{},
        language_model_tools: []RawContribution = &.{},
        yaml_validations: []RawContribution = &.{},
        debug_visualizers: []RawContribution = &.{},
        java_extensions: []RawContribution = &.{},
        java_build_file_patterns: []RawContribution = &.{},
        java_build_tools: []RawContribution = &.{},
        java_shortcuts: []RawContribution = &.{},
        chat_participants: []RawContribution = &.{},
        chat_sessions: []RawContribution = &.{},
        icons: []RawContribution = &.{},
        mcp_server_definition_providers: []RawContribution = &.{},
    };

    const CommandContribution = struct {
        command: []const u8,
        title: []const u8,
        enablement: ?[]const u8 = null,
    };

    const MenuContribution = struct {
        menu: []const u8,
        command: []const u8,
        when: ?[]const u8 = null,
        group: ?[]const u8 = null,
        alt: ?[]const u8 = null,
        args: ?[]const u8 = null,
    };

    const KeybindingContribution = struct {
        command: []const u8,
        key: []const u8,
        when: ?[]const u8 = null,
        linux: ?[]const u8 = null,
        mac: ?[]const u8 = null,
        win: ?[]const u8 = null,
    };

    const ConfigurationContribution = struct {
        key: []const u8,
        title: []const u8,
        type_name: []const u8,
        type_raw: []const u8,
        default_raw: []const u8,
        description: ?[]const u8 = null,
    };

    const ContextValue = union(enum) {
        boolean: bool,
        string: []const u8,
    };

    const LanguageContribution = struct {
        id: []const u8,
        aliases: []const []const u8 = &.{},
        extensions: []const []const u8 = &.{},
        configuration: ?[]const u8 = null,
    };

    const GrammarContribution = struct {
        language: []const u8,
        scope_name: []const u8,
        path: []const u8,
    };

    const ThemeContribution = struct {
        id: []const u8,
        label: []const u8,
        ui_theme: ?[]const u8 = null,
        path: []const u8,
    };

    const SnippetContribution = struct {
        language: []const u8,
        path: []const u8,
    };

    const ViewContainerContribution = struct {
        location: []const u8,
        id: []const u8,
        title: []const u8,
        icon: ?[]const u8 = null,
    };

    const ViewContribution = struct {
        location: []const u8,
        id: []const u8,
        name: []const u8,
        when: ?[]const u8 = null,
    };

    const ViewWelcomeContribution = struct {
        view: []const u8,
        contents: []const u8,
        when: ?[]const u8 = null,
    };

    const BreakpointContribution = struct {
        language: []const u8,
    };

    const JsonValidationContribution = struct {
        file_match: []const []const u8 = &.{},
        url: []const u8,
    };

    const ResourceLabelFormatterContribution = struct {
        scheme: []const u8,
        formatting_raw: []const u8,
    };

    const ProblemMatcherContribution = struct {
        name: []const u8,
        label: ?[]const u8 = null,
        owner: ?[]const u8 = null,
        source: ?[]const u8 = null,
        pattern_raw: ?[]const u8 = null,
    };

    const TaskDefinitionContribution = struct {
        type_name: []const u8,
        required: []const []const u8 = &.{},
        properties_raw: ?[]const u8 = null,
    };

    const DebuggerContribution = struct {
        type_name: []const u8,
        raw_json: []const u8,
        label: []const u8,
        program: ?[]const u8 = null,
        runtime: ?[]const u8 = null,
        languages: []const []const u8 = &.{},
        configuration_attributes_raw: ?[]const u8 = null,
    };

    const IconThemeContribution = struct {
        id: []const u8,
        label: []const u8,
        path: []const u8,
    };

    const WalkthroughContribution = struct {
        id: []const u8,
        title: []const u8,
        description: ?[]const u8 = null,
        steps_raw: ?[]const u8 = null,
    };

    const RawContribution = struct {
        key: ?[]const u8 = null,
        raw: []const u8,
    };

    const RawContributionFamily = enum {
        semantic_token_scopes,
        semantic_token_types,
        semantic_token_modifiers,
        custom_editors,
        language_model_tools,
        yaml_validations,
        debug_visualizers,
        java_extensions,
        java_build_file_patterns,
        java_build_tools,
        java_shortcuts,
        chat_participants,
        chat_sessions,
        icons,
        mcp_server_definition_providers,
    };

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const engine = try JSEngine.init(allocator);
        var host = Self{
            .allocator = allocator,
            .engine = engine,
        };
        // Inject VS Code Extension API into engine global scope
        try host.injectExtensionAPI();
        try host.loadDisabledExtensions();
        return host;
    }

    pub fn installRecoveryHandler(self: *Self) void {
        self.engine.setRecoveryHandler(self, requestRecovery);
    }

    fn requestRecovery(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.recovery_requested.store(true, .seq_cst);
    }

    pub fn recoverIfRequested(self: *Self) void {
        if (!self.recovery_requested.swap(false, .seq_cst)) return;
        self.restartHost() catch |err| {
            std.debug.print("WIZP ExtHost: recovery failed: {}\n", .{err});
        };
    }

    fn loadDisabledExtensions(self: *Self) !void {
        const builtin = @import("builtin");
        const home_name = if (comptime builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        const home = compat_runtime.getEnvVarOwned(self.allocator, home_name) catch return;
        defer self.allocator.free(home);
        const path = try std.fs.path.join(self.allocator, &.{ home, ".wizp", "disabled-extensions" });
        defer self.allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(
            compat_runtime.io(),
            path,
            self.allocator,
            .limited(1024 * 1024),
        ) catch return;
        defer self.allocator.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or self.disabled_extensions.contains(line)) continue;
            const owned = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(owned);
            try self.disabled_extensions.put(self.allocator, owned, {});
        }
    }

    pub fn deinit(self: *Self) void {
        // Deactivate all extensions
        var it = self.activated.iterator();
        while (it.next()) |entry| {
            if (self.deactivateExtension(entry.key_ptr.*)) |result| {
                self.allocator.free(result);
            } else |_| {}
        }
        self.activated.deinit(self.allocator);
        self.activating.deinit(self.allocator);
        var triggered_it = self.triggered_activation_events.iterator();
        while (triggered_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.triggered_activation_events.deinit(self.allocator);
        var disabled_it = self.disabled_extensions.iterator();
        while (disabled_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.disabled_extensions.deinit(self.allocator);

        self.clearContextKeys();
        self.context_keys.deinit(self.allocator);

        // Free extension data
        var ext_it = self.extensions.iterator();
        while (ext_it.next()) |entry| {
            const ext = entry.value_ptr.*;
            self.allocator.free(ext.id);
            self.allocator.free(ext.publisher);
            self.allocator.free(ext.name);
            self.allocator.free(ext.version);
            self.allocator.free(ext.ai_key);
            self.allocator.free(ext.path);
            self.allocator.free(ext.main);
            self.allocator.free(ext.package_json_raw);
            for (ext.activation_events) |ae| self.allocator.free(ae);
            self.allocator.free(ext.activation_events);
            for (ext.extension_dependencies) |dep| self.allocator.free(dep);
            if (ext.extension_dependencies.len > 0) self.allocator.free(ext.extension_dependencies);
            for (ext.extension_pack) |pack_id| self.allocator.free(pack_id);
            if (ext.extension_pack.len > 0) self.allocator.free(ext.extension_pack);
            if (ext.contributes) |contributes| {
                for (contributes.commands) |cmd| {
                    self.allocator.free(cmd.command);
                    self.allocator.free(cmd.title);
                    if (cmd.enablement) |enablement| self.allocator.free(enablement);
                }
                for (contributes.menus) |menu| {
                    self.allocator.free(menu.menu);
                    self.allocator.free(menu.command);
                    if (menu.when) |when| self.allocator.free(when);
                    if (menu.group) |group| self.allocator.free(group);
                    if (menu.alt) |alt| self.allocator.free(alt);
                    if (menu.args) |args| self.allocator.free(args);
                }
                for (contributes.keybindings) |kb| {
                    self.allocator.free(kb.command);
                    self.allocator.free(kb.key);
                    if (kb.when) |when| self.allocator.free(when);
                    if (kb.linux) |linux| self.allocator.free(linux);
                    if (kb.mac) |mac| self.allocator.free(mac);
                    if (kb.win) |win| self.allocator.free(win);
                }
                for (contributes.configurations) |cfg| {
                    self.allocator.free(cfg.key);
                    self.allocator.free(cfg.title);
                    self.allocator.free(cfg.type_name);
                    self.allocator.free(cfg.type_raw);
                    self.allocator.free(cfg.default_raw);
                    if (cfg.description) |description| self.allocator.free(description);
                }
                for (contributes.languages) |lang| {
                    self.allocator.free(lang.id);
                    for (lang.aliases) |alias| self.allocator.free(alias);
                    if (lang.aliases.len > 0) self.allocator.free(lang.aliases);
                    for (lang.extensions) |extension| self.allocator.free(extension);
                    if (lang.extensions.len > 0) self.allocator.free(lang.extensions);
                    if (lang.configuration) |configuration| self.allocator.free(configuration);
                }
                for (contributes.grammars) |grammar| {
                    self.allocator.free(grammar.language);
                    self.allocator.free(grammar.scope_name);
                    self.allocator.free(grammar.path);
                }
                for (contributes.themes) |theme| {
                    self.allocator.free(theme.id);
                    self.allocator.free(theme.label);
                    if (theme.ui_theme) |ui_theme| self.allocator.free(ui_theme);
                    self.allocator.free(theme.path);
                }
                for (contributes.snippets) |snippet| {
                    self.allocator.free(snippet.language);
                    self.allocator.free(snippet.path);
                }
                for (contributes.views_containers) |container| {
                    self.allocator.free(container.location);
                    self.allocator.free(container.id);
                    self.allocator.free(container.title);
                    if (container.icon) |icon| self.allocator.free(icon);
                }
                for (contributes.views) |view| {
                    self.allocator.free(view.location);
                    self.allocator.free(view.id);
                    self.allocator.free(view.name);
                    if (view.when) |when| self.allocator.free(when);
                }
                for (contributes.views_welcome) |welcome| {
                    self.allocator.free(welcome.view);
                    self.allocator.free(welcome.contents);
                    if (welcome.when) |when| self.allocator.free(when);
                }
                for (contributes.breakpoints) |breakpoint| self.allocator.free(breakpoint.language);
                for (contributes.json_validations) |validation| {
                    for (validation.file_match) |file_match| self.allocator.free(file_match);
                    if (validation.file_match.len > 0) self.allocator.free(validation.file_match);
                    self.allocator.free(validation.url);
                }
                for (contributes.resource_label_formatters) |formatter| {
                    self.allocator.free(formatter.scheme);
                    self.allocator.free(formatter.formatting_raw);
                }
                for (contributes.problem_matchers) |matcher| {
                    self.allocator.free(matcher.name);
                    if (matcher.label) |label| self.allocator.free(label);
                    if (matcher.owner) |owner| self.allocator.free(owner);
                    if (matcher.source) |source| self.allocator.free(source);
                    if (matcher.pattern_raw) |pattern_raw| self.allocator.free(pattern_raw);
                }
                for (contributes.task_definitions) |definition| {
                    self.allocator.free(definition.type_name);
                    for (definition.required) |required| self.allocator.free(required);
                    if (definition.required.len > 0) self.allocator.free(definition.required);
                    if (definition.properties_raw) |properties_raw| self.allocator.free(properties_raw);
                }
                for (contributes.debuggers) |debugger| {
                    self.allocator.free(debugger.type_name);
                    self.allocator.free(debugger.raw_json);
                    self.allocator.free(debugger.label);
                    if (debugger.program) |program| self.allocator.free(program);
                    if (debugger.runtime) |runtime| self.allocator.free(runtime);
                    for (debugger.languages) |language| self.allocator.free(language);
                    if (debugger.languages.len > 0) self.allocator.free(debugger.languages);
                    if (debugger.configuration_attributes_raw) |raw| self.allocator.free(raw);
                }
                for (contributes.icon_themes) |icon_theme| {
                    self.allocator.free(icon_theme.id);
                    self.allocator.free(icon_theme.label);
                    self.allocator.free(icon_theme.path);
                }
                for (contributes.walkthroughs) |walkthrough| {
                    self.allocator.free(walkthrough.id);
                    self.allocator.free(walkthrough.title);
                    if (walkthrough.description) |description| self.allocator.free(description);
                    if (walkthrough.steps_raw) |steps_raw| self.allocator.free(steps_raw);
                }
                self.freeRawContributions(contributes.semantic_token_scopes);
                self.freeRawContributions(contributes.semantic_token_types);
                self.freeRawContributions(contributes.semantic_token_modifiers);
                self.freeRawContributions(contributes.custom_editors);
                self.freeRawContributions(contributes.language_model_tools);
                self.freeRawContributions(contributes.yaml_validations);
                self.freeRawContributions(contributes.debug_visualizers);
                self.freeRawContributions(contributes.java_extensions);
                self.freeRawContributions(contributes.java_build_file_patterns);
                self.freeRawContributions(contributes.java_build_tools);
                self.freeRawContributions(contributes.java_shortcuts);
                self.freeRawContributions(contributes.chat_participants);
                self.freeRawContributions(contributes.chat_sessions);
                self.freeRawContributions(contributes.icons);
                self.freeRawContributions(contributes.mcp_server_definition_providers);
                if (contributes.commands.len > 0) self.allocator.free(contributes.commands);
                if (contributes.menus.len > 0) self.allocator.free(contributes.menus);
                if (contributes.keybindings.len > 0) self.allocator.free(contributes.keybindings);
                if (contributes.configurations.len > 0) self.allocator.free(contributes.configurations);
                if (contributes.languages.len > 0) self.allocator.free(contributes.languages);
                if (contributes.grammars.len > 0) self.allocator.free(contributes.grammars);
                if (contributes.themes.len > 0) self.allocator.free(contributes.themes);
                if (contributes.snippets.len > 0) self.allocator.free(contributes.snippets);
                if (contributes.views_containers.len > 0) self.allocator.free(contributes.views_containers);
                if (contributes.views.len > 0) self.allocator.free(contributes.views);
                if (contributes.views_welcome.len > 0) self.allocator.free(contributes.views_welcome);
                if (contributes.breakpoints.len > 0) self.allocator.free(contributes.breakpoints);
                if (contributes.json_validations.len > 0) self.allocator.free(contributes.json_validations);
                if (contributes.resource_label_formatters.len > 0) self.allocator.free(contributes.resource_label_formatters);
                if (contributes.problem_matchers.len > 0) self.allocator.free(contributes.problem_matchers);
                if (contributes.task_definitions.len > 0) self.allocator.free(contributes.task_definitions);
                if (contributes.debuggers.len > 0) self.allocator.free(contributes.debuggers);
                if (contributes.icon_themes.len > 0) self.allocator.free(contributes.icon_themes);
                if (contributes.walkthroughs.len > 0) self.allocator.free(contributes.walkthroughs);
            }
        }
        self.extensions.deinit(self.allocator);

        for (self.extension_dirs.items) |dir| self.allocator.free(dir);
        self.extension_dirs.deinit(self.allocator);

        self.engine.deinit();
    }

    fn freeRawContributions(self: *Self, items: []RawContribution) void {
        for (items) |item| {
            if (item.key) |key| self.allocator.free(key);
            self.allocator.free(item.raw);
        }
        if (items.len > 0) self.allocator.free(items);
    }

    fn rawContributionFamily(contributes: Contributes, family: RawContributionFamily) []RawContribution {
        return switch (family) {
            .semantic_token_scopes => contributes.semantic_token_scopes,
            .semantic_token_types => contributes.semantic_token_types,
            .semantic_token_modifiers => contributes.semantic_token_modifiers,
            .custom_editors => contributes.custom_editors,
            .language_model_tools => contributes.language_model_tools,
            .yaml_validations => contributes.yaml_validations,
            .debug_visualizers => contributes.debug_visualizers,
            .java_extensions => contributes.java_extensions,
            .java_build_file_patterns => contributes.java_build_file_patterns,
            .java_build_tools => contributes.java_build_tools,
            .java_shortcuts => contributes.java_shortcuts,
            .chat_participants => contributes.chat_participants,
            .chat_sessions => contributes.chat_sessions,
            .icons => contributes.icons,
            .mcp_server_definition_providers => contributes.mcp_server_definition_providers,
        };
    }

    fn writeRawContributionFamily(self: *Self, writer: anytype, json_key: []const u8, family: RawContributionFamily) !void {
        try writer.print("],\"{s}\":[", .{json_key});
        var first = true;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (rawContributionFamily(contributes, family)) |item| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writeRawContributionJson(writer, item);
                }
            }
        }
    }

    fn writeScopedRawContributionFamily(writer: anytype, contributes: Contributes, json_key: []const u8, family: RawContributionFamily) !void {
        try writer.print("],\"{s}\":[", .{json_key});
        for (rawContributionFamily(contributes, family), 0..) |item, index| {
            if (index > 0) try writer.writeAll(",");
            try writeRawContributionJson(writer, item);
        }
    }

    /// Add a directory to scan for extensions.
    pub fn addExtensionDir(self: *Self, dir: []const u8) !void {
        const duped = try self.allocator.dupe(u8, dir);
        try self.extension_dirs.append(self.allocator, duped);
    }

    /// Discover and load all extensions from registered directories.
    pub fn discoverExtensions(self: *Self) !void {
        for (self.extension_dirs.items) |dir| {
            try self.scanDirectory(dir);
        }
        try self.refreshDiscoveredExtensionRegistry();
        try self.refreshContributedConfigurationDefaults();
        if (!self.shouldDeferStartupExtensions()) {
            try self.activateWorkspaceContainsExtensions();
        }
        std.debug.print("WIZP ExtHost: discovered {} extensions\n", .{self.extensions.count()});
    }

    fn clearActivationState(self: *Self) void {
        // The engine is replaced on restart; discard all host-side runtime state
        // while retaining self.extensions as the metadata/contribution source.
        self.activated.clearRetainingCapacity();
        self.activating.clearRetainingCapacity();
        var triggered_it = self.triggered_activation_events.iterator();
        while (triggered_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.triggered_activation_events.clearRetainingCapacity();
        self.clearContextKeys();
    }

    fn clearContextKeys(self: *Self) void {
        var it = self.context_keys.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .string => |s| self.allocator.free(s),
                .boolean => {},
            }
        }
        self.context_keys.clearRetainingCapacity();
    }

    fn restartHost(self: *Self) !void {
        try self.engine.restart();
        self.clearActivationState();
        try self.injectExtensionAPI();
        try self.discoverExtensions();
        if (!self.shouldDeferStartupExtensions()) try self.activateByEvent("startup");
    }

    fn shouldDeferStartupExtensions(self: *Self) bool {
        const raw = compat_runtime.getEnvVarOwned(self.allocator, "WIZP_DEFER_STARTUP_EXTENSIONS") catch return false;
        defer self.allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        return std.mem.eql(u8, trimmed, "1") or std.mem.eql(u8, trimmed, "true");
    }

    fn refreshContributedConfigurationDefaults(self: *Self) !void {
        var defaults_json: std.Io.Writer.Allocating = .init(self.allocator);
        defer defaults_json.deinit();
        try self.writeContributedConfigurationDefaultsJson(&defaults_json.writer);
        const js = try std.fmt.allocPrint(
            self.allocator,
            "globalThis._wizpContributedConfigurationDefaults = {s};",
            .{defaults_json.written()},
        );
        defer self.allocator.free(js);
        try self.engine.evalVoid(js, "contributed-configuration-defaults");
    }

    fn refreshDiscoveredExtensionRegistry(self: *Self) !void {
        var extensions_json: std.Io.Writer.Allocating = .init(self.allocator);
        defer extensions_json.deinit();
        const writer = &extensions_json.writer;
        try writer.writeByte('[');
        var first = true;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            const full_id = if (ext.publisher.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ext.publisher, ext.id })
            else
                try self.allocator.dupe(u8, ext.id);
            defer self.allocator.free(full_id);

            const storage_root = try std.fs.path.join(self.allocator, &.{ ext.path, ".wizp-context" });
            defer self.allocator.free(storage_root);
            const extension_storage = try std.fs.path.join(self.allocator, &.{ storage_root, full_id });
            defer self.allocator.free(extension_storage);
            const name_storage = try std.fs.path.join(self.allocator, &.{ storage_root, ext.id });
            defer self.allocator.free(name_storage);
            const global_storage = try std.fs.path.join(self.allocator, &.{ storage_root, "global" });
            defer self.allocator.free(global_storage);
            const workspace_storage = try std.fs.path.join(self.allocator, &.{ storage_root, "workspace" });
            defer self.allocator.free(workspace_storage);
            const log_storage = try std.fs.path.join(self.allocator, &.{ storage_root, "logs" });
            defer self.allocator.free(log_storage);
            for ([_][]const u8{ storage_root, extension_storage, name_storage, global_storage, workspace_storage, log_storage }) |path| {
                std.Io.Dir.cwd().createDirPath(compat_runtime.io(), path) catch |err| {
                    std.debug.print("WIZP ExtHost: cannot create discovered extension storage path {s}: {}\n", .{ path, err });
                };
            }
            try self.ensureRedHatJavaJdtLog(storage_root, full_id);
            for (ext.extension_pack) |child_id| {
                const child_storage = try std.fs.path.join(self.allocator, &.{ storage_root, child_id });
                defer self.allocator.free(child_storage);
                std.Io.Dir.cwd().createDirPath(compat_runtime.io(), child_storage) catch |err| {
                    std.debug.print("WIZP ExtHost: cannot create extension-pack child storage path {s}: {}\n", .{ child_storage, err });
                };
                try self.ensureRedHatJavaJdtLog(storage_root, child_id);
            }
            for (ext.extension_dependencies) |child_id| {
                const child_storage = try std.fs.path.join(self.allocator, &.{ storage_root, child_id });
                defer self.allocator.free(child_storage);
                std.Io.Dir.cwd().createDirPath(compat_runtime.io(), child_storage) catch |err| {
                    std.debug.print("WIZP ExtHost: cannot create extension-dependency child storage path {s}: {}\n", .{ child_storage, err });
                };
                try self.ensureRedHatJavaJdtLog(storage_root, child_id);
            }

            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeByte('{');

            try writeJsonString(writer, "id");
            try writer.writeByte(':');
            try writeJsonString(writer, full_id);
            try writer.writeByte(',');

            try writeJsonString(writer, "name");
            try writer.writeByte(':');
            try writeJsonString(writer, ext.id);
            try writer.writeByte(',');

            try writeJsonString(writer, "publisher");
            try writer.writeByte(':');
            try writeJsonString(writer, ext.publisher);
            try writer.writeByte(',');

            try writeJsonString(writer, "displayName");
            try writer.writeByte(':');
            try writeJsonString(writer, ext.name);
            try writer.writeByte(',');

            try writeJsonString(writer, "version");
            try writer.writeByte(':');
            try writeJsonString(writer, ext.version);
            try writer.writeByte(',');

            try writeJsonString(writer, "aiKey");
            try writer.writeByte(':');
            try writeJsonString(writer, ext.ai_key);
            try writer.writeByte(',');

            try writeJsonString(writer, "extensionPath");
            try writer.writeByte(':');
            try writeJsonString(writer, ext.path);
            try writer.writeByte(',');

            try writeJsonString(writer, "activationEvents");
            try writer.writeByte(':');
            try writer.writeByte('[');
            for (ext.activation_events, 0..) |activation_event, index| {
                if (index > 0) try writer.writeByte(',');
                try writeJsonString(writer, activation_event);
            }
            try writer.writeByte(']');
            try writer.writeByte(',');

            try writeJsonString(writer, "packageJSON");
            try writer.writeByte(':');
            try writer.writeAll(ext.package_json_raw);
            try writer.writeByte('}');
        }
        try writer.writeByte(']');

        const js = try std.fmt.allocPrint(self.allocator,
            \\(async function() {{
            \\  const items = {s};
            \\  globalThis._wizpExtensions = globalThis._wizpExtensions || {{}};
            \\  globalThis._wizpLoadedExtensions = items.map(function(item) {{
            \\    const packageJSON = Object.assign({{
            \\      name: item.name || '',
            \\      publisher: item.publisher || '',
            \\      displayName: item.displayName || item.name || '',
            \\      version: item.version || '0.0.0',
            \\      aiKey: item.aiKey || ''
            \\    }}, item.packageJSON || {{}});
            \\    const extensionId = item.id || (packageJSON.publisher ? packageJSON.publisher + '.' + packageJSON.name : packageJSON.name);
            \\    let record = globalThis._wizpExtensions[extensionId] || globalThis._wizpExtensions[packageJSON.name];
            \\    if (!record) {{
            \\      record = {{
            \\        id: extensionId,
            \\        extensionUri: globalThis._wizpContext.Uri.file(item.extensionPath || globalThis._wizpCwd || '.'),
            \\        extensionPath: item.extensionPath || globalThis._wizpCwd || '.',
            \\        packageJSON: packageJSON,
            \\        isActive: false,
            \\        exports: undefined,
            \\        activate: async function() {{ return record.exports; }}
            \\      }};
            \\    }}
            \\    record.id = extensionId;
            \\    record.name = packageJSON.name;
            \\    record.publisher = packageJSON.publisher;
            \\    record.displayName = packageJSON.displayName;
            \\    record.extensionUri = globalThis._wizpContext.Uri.file(item.extensionPath || globalThis._wizpCwd || '.');
            \\    record.extensionPath = item.extensionPath || globalThis._wizpCwd || '.';
            \\    record.packageJSON = Object.assign({{}}, record.packageJSON || {{}}, packageJSON);
            \\    record.activationEvents = Array.isArray(item.activationEvents) ? item.activationEvents.slice() : [];
            \\    if (typeof record.isActive !== 'boolean') record.isActive = false;
            \\    if (typeof record.activate !== 'function') record.activate = async function() {{ return record.exports; }};
            \\    globalThis._wizpExtensions[packageJSON.name] = record;
            \\    globalThis._wizpExtensions[extensionId] = record;
            \\    return record;
            \\  }});
            \\}})();
        , .{extensions_json.written()});
        defer self.allocator.free(js);
        try self.engine.evalVoid(js, "discovered-extension-registry");
    }

    fn ensureRedHatJavaJdtLog(self: *Self, storage_root: []const u8, extension_id: []const u8) !void {
        if (!std.mem.eql(u8, extension_id, "redhat.java")) return;

        const metadata_dir = try std.fs.path.join(self.allocator, &.{ storage_root, extension_id, "jdt_ws", ".metadata" });
        defer self.allocator.free(metadata_dir);
        std.Io.Dir.cwd().createDirPath(compat_runtime.io(), metadata_dir) catch |err| {
            std.debug.print("WIZP ExtHost: cannot create Red Hat Java JDT metadata path {s}: {}\n", .{ metadata_dir, err });
            return;
        };

        const log_path = try std.fs.path.join(self.allocator, &.{ metadata_dir, ".log" });
        defer self.allocator.free(log_path);
        std.Io.Dir.cwd().access(compat_runtime.io(), log_path, .{}) catch {
            const log_file = std.Io.Dir.cwd().createFile(compat_runtime.io(), log_path, .{}) catch |err| {
                std.debug.print("WIZP ExtHost: cannot seed Red Hat Java JDT log {s}: {}\n", .{ log_path, err });
                return;
            };
            log_file.close(compat_runtime.io());
        };
    }

    fn writeContributedConfigurationDefaultsJson(self: *Self, writer: anytype) !void {
        try writer.writeByte('{');
        var first = true;
        var ext_it = self.extensions.iterator();
        while (ext_it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.configurations) |cfg| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writeJsonString(writer, cfg.key);
                    try writer.writeByte(':');
                    try writer.writeAll(cfg.default_raw);
                }
            }
        }
        try writer.writeByte('}');
    }

    fn extensionDebugEnabled(self: *Self) bool {
        _ = self;
        return compat_runtime.hasEnvVar("WIZP_EXTENSION_DEBUG");
    }

    fn findExtension(self: *Self, identifier: []const u8) ?Extension {
        if (self.extensions.get(identifier)) |ext| return ext;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ExtensionPolicy.identifierMatches(ext.publisher, ext.id, identifier)) return ext;
        }
        return null;
    }

    fn disabledExtensionKey(self: *Self, publisher: []const u8, id: []const u8) ?[]const u8 {
        var disabled_it = self.disabled_extensions.iterator();
        while (disabled_it.next()) |entry| {
            if (ExtensionPolicy.identifierMatches(publisher, id, entry.key_ptr.*)) return entry.key_ptr.*;
        }
        return null;
    }

    fn isExtensionDisabled(self: *Self, extension: Extension) bool {
        return self.disabledExtensionKey(extension.publisher, extension.id) != null;
    }

    fn activateWorkspaceContainsExtensions(self: *Self) !void {
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (self.activated.contains(ext.id)) continue;
            if (self.isExtensionDisabled(ext)) continue;
            for (ext.activation_events) |activation_event| {
                if (!std.mem.startsWith(u8, activation_event, "workspaceContains:")) continue;
                const pattern = activation_event["workspaceContains:".len..];
                if (pattern.len == 0) continue;
                const matched = if (containsGlobMeta(pattern))
                    self.workspaceContainsGlob(pattern) catch false
                else blk: {
                    std.Io.Dir.cwd().access(compat_runtime.io(), pattern, .{}) catch break :blk false;
                    break :blk true;
                };
                if (!matched) continue;
                try self.activateExtension(ext);
                break;
            }
        }
    }

    fn workspaceContainsGlob(self: *Self, pattern: []const u8) !bool {
        var cwd = try std.Io.Dir.cwd().openDir(
            compat_runtime.io(),
            ".",
            .{ .iterate = true },
        );
        defer cwd.close(compat_runtime.io());
        return try self.workspaceContainsGlobInDir(cwd, pattern, "");
    }

    fn workspaceContainsGlobInDir(self: *Self, dir: std.Io.Dir, pattern: []const u8, prefix: []const u8) !bool {
        var iter = dir.iterate();
        while (try iter.next(compat_runtime.io())) |entry| {
            if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, "node_modules") or std.mem.eql(u8, entry.name, "zig-out") or std.mem.eql(u8, entry.name, ".zig-cache")) continue;
            const rel = if (prefix.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            defer self.allocator.free(rel);

            if (globMatches(pattern, rel)) return true;
            if (entry.kind == .directory) {
                var child = dir.openDir(
                    compat_runtime.io(),
                    entry.name,
                    .{ .iterate = true },
                ) catch continue;
                defer child.close(compat_runtime.io());
                if (try self.workspaceContainsGlobInDir(child, pattern, rel)) return true;
            }
        }
        return false;
    }

    /// Scan a directory for extension package.json files.
    fn scanDirectory(self: *Self, dir: []const u8) !void {
        var fs_dir = std.Io.Dir.cwd().openDir(
            compat_runtime.io(),
            dir,
            .{ .iterate = true },
        ) catch return;
        defer fs_dir.close(compat_runtime.io());

        var iter = fs_dir.iterate();
        while (iter.next(compat_runtime.io()) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const ext_dir = try std.fs.path.join(self.allocator, &.{ dir, entry.name });
            defer self.allocator.free(ext_dir);
            self.loadExtension(ext_dir) catch |err| {
                std.debug.print("WIZP ExtHost: failed to load extension from {s}: {}\n", .{ ext_dir, err });
            };
        }
    }

    /// Load an extension from a directory containing package.json.
    fn loadExtension(self: *Self, ext_dir: []const u8) !void {
        const pkg_path = try std.fs.path.join(self.allocator, &.{ ext_dir, "package.json" });
        defer self.allocator.free(pkg_path);

        const pkg_content = std.Io.Dir.cwd().readFileAlloc(
            compat_runtime.io(),
            pkg_path,
            self.allocator,
            .limited(1024 * 1024),
        ) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(pkg_content);

        var manifest_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer manifest_arena.deinit();
        const manifest = try std.json.parseFromSlice(std.json.Value, manifest_arena.allocator(), pkg_content, .{});
        const root = switch (manifest.value) {
            .object => |object| object,
            else => return error.InvalidExtensionManifest,
        };

        const id = jsonObjectString(root, "name") orelse return;
        if (self.extensions.contains(id)) return;
        const publisher = jsonObjectString(root, "publisher") orelse "";
        const display_name = jsonObjectString(root, "displayName") orelse id;
        const version = jsonObjectString(root, "version") orelse "0.0.0";
        const ai_key = jsonObjectString(root, "aiKey") orelse "";
        const main_file = jsonObjectString(root, "main") orelse "extension.js";

        var activation_events = try ManifestParsing.stringArray(self.allocator, root, "activationEvents");

        // If no activationEvents, default to ["*"] (activate on startup)
        if (activation_events.items.len == 0) {
            try activation_events.append(try self.allocator.dupe(u8, "*"));
        }

        const extension_dependencies = try ManifestParsing.ownedStringArray(self.allocator, root, "extensionDependencies");
        const extension_pack = try ManifestParsing.ownedStringArray(self.allocator, root, "extensionPack");

        const commands = try self.parseCommandContributions(root);
        const menus = try self.parseMenuContributions(root);
        const keybindings = try self.parseKeybindingContributions(root);
        const configurations = try self.parseConfigurationContributions(root);
        const languages = try self.parseLanguageContributions(root);
        const grammars = try self.parseGrammarContributions(root);
        const themes = try self.parseThemeContributions(root);
        const snippets = try self.parseSnippetContributions(root);
        const views_containers = try self.parseViewContainerContributions(root);
        const views = try self.parseViewContributions(root);
        const views_welcome = try self.parseViewsWelcomeContributions(root);
        const breakpoints = try self.parseBreakpointContributions(root);
        const json_validations = try self.parseJsonValidationContributions(root);
        const resource_label_formatters = try self.parseResourceLabelFormatterContributions(root);
        const problem_matchers = try self.parseProblemMatcherContributions(root);
        const task_definitions = try self.parseTaskDefinitionContributions(root);
        const debuggers = try self.parseDebuggerContributions(root);
        const icon_themes = try self.parseIconThemeContributions(root);
        const walkthroughs = try self.parseWalkthroughContributions(root);
        const semantic_token_scopes = try self.parseRawContributionEntries(root, "semanticTokenScopes");
        const semantic_token_types = try self.parseRawContributionEntries(root, "semanticTokenTypes");
        const semantic_token_modifiers = try self.parseRawContributionEntries(root, "semanticTokenModifiers");
        const custom_editors = try self.parseRawContributionEntries(root, "customEditors");
        const language_model_tools = try self.parseRawContributionEntries(root, "languageModelTools");
        const yaml_validations = try self.parseRawContributionEntries(root, "yamlValidation");
        const debug_visualizers = try self.parseRawContributionEntries(root, "debugVisualizers");
        const java_extensions = try self.parseRawContributionEntries(root, "javaExtensions");
        const java_build_file_patterns = try self.parseRawContributionEntries(root, "javaBuildFilePatterns");
        const java_build_tools = try self.parseRawContributionEntries(root, "javaBuildTools");
        const java_shortcuts = try self.parseRawContributionEntries(root, "javaShortcuts");
        const chat_participants = try self.parseRawContributionEntries(root, "chatParticipants");
        const chat_sessions = try self.parseRawContributionEntries(root, "chatSessions");
        const icons = try self.parseRawContributionEntries(root, "icons");
        const mcp_server_definition_providers = try self.parseRawContributionEntries(root, "mcpServerDefinitionProviders");
        const raw_count = semantic_token_scopes.len + semantic_token_types.len + semantic_token_modifiers.len + custom_editors.len + language_model_tools.len + yaml_validations.len + debug_visualizers.len + java_extensions.len + java_build_file_patterns.len + java_build_tools.len + java_shortcuts.len + chat_participants.len + chat_sessions.len + icons.len + mcp_server_definition_providers.len;
        const has_contributes = commands.len > 0 or menus.len > 0 or keybindings.len > 0 or configurations.len > 0 or languages.len > 0 or grammars.len > 0 or themes.len > 0 or snippets.len > 0 or views_containers.len > 0 or views.len > 0 or views_welcome.len > 0 or breakpoints.len > 0 or json_validations.len > 0 or resource_label_formatters.len > 0 or problem_matchers.len > 0 or task_definitions.len > 0 or debuggers.len > 0 or icon_themes.len > 0 or walkthroughs.len > 0 or raw_count > 0;

        const ext = Extension{
            .id = try self.allocator.dupe(u8, id),
            .publisher = try self.allocator.dupe(u8, publisher),
            .name = try self.allocator.dupe(u8, display_name),
            .version = try self.allocator.dupe(u8, version),
            .ai_key = try self.allocator.dupe(u8, ai_key),
            .path = try self.allocator.dupe(u8, ext_dir),
            .main = try self.allocator.dupe(u8, main_file),
            .package_json_raw = try self.allocator.dupe(u8, pkg_content),
            .activation_events = try activation_events.toOwnedSlice(),
            .extension_dependencies = extension_dependencies,
            .extension_pack = extension_pack,
            .contributes = if (has_contributes) .{
                .commands = commands,
                .menus = menus,
                .keybindings = keybindings,
                .configurations = configurations,
                .languages = languages,
                .grammars = grammars,
                .themes = themes,
                .snippets = snippets,
                .views_containers = views_containers,
                .views = views,
                .views_welcome = views_welcome,
                .breakpoints = breakpoints,
                .json_validations = json_validations,
                .resource_label_formatters = resource_label_formatters,
                .problem_matchers = problem_matchers,
                .task_definitions = task_definitions,
                .debuggers = debuggers,
                .icon_themes = icon_themes,
                .walkthroughs = walkthroughs,
                .semantic_token_scopes = semantic_token_scopes,
                .semantic_token_types = semantic_token_types,
                .semantic_token_modifiers = semantic_token_modifiers,
                .custom_editors = custom_editors,
                .language_model_tools = language_model_tools,
                .yaml_validations = yaml_validations,
                .debug_visualizers = debug_visualizers,
                .java_extensions = java_extensions,
                .java_build_file_patterns = java_build_file_patterns,
                .java_build_tools = java_build_tools,
                .java_shortcuts = java_shortcuts,
                .chat_participants = chat_participants,
                .chat_sessions = chat_sessions,
                .icons = icons,
                .mcp_server_definition_providers = mcp_server_definition_providers,
            } else null,
        };

        try self.extensions.put(self.allocator, ext.id, ext);

        std.debug.print("WIZP ExtHost: loaded extension {s} v{s}\n", .{ ext.name, ext.version });
    }

    /// Activate extensions matching an activation event (e.g., "onLanguage:zig").
    pub fn activateByEvent(self: *Self, event: []const u8) !void {
        const debug = self.extensionDebugEnabled();
        if (debug) std.debug.print("WIZP ExtHost: activateByEvent {s}\n", .{event});
        if (!self.triggered_activation_events.contains(event)) {
            const owned_event = try self.allocator.dupe(u8, event);
            errdefer self.allocator.free(owned_event);
            try self.triggered_activation_events.put(self.allocator, owned_event, {});
        }
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (self.activated.contains(ext.id)) continue;
            if (self.isExtensionDisabled(ext)) continue;

            for (ext.activation_events) |ae| {
                if (matchesActivationEvent(ae, event)) {
                    if (debug) std.debug.print("WIZP ExtHost: activation event {s} matched {s}\n", .{ event, ext.id });
                    try self.activateExtension(ext);
                    break;
                }
            }
        }
    }

    fn parseCommandContributions(self: *Self, root: anytype) ![]CommandContribution {
        const array = contributionArrayValue(root, "commands") orelse return &.{};
        var commands = std.array_list.Managed(CommandContribution).init(self.allocator);
        for (array.items) |item| {
            const object = switch (item) {
                .object => |object| object,
                else => continue,
            };
            const command = jsonObjectString(object, "command") orelse continue;
            const title = jsonObjectString(object, "title") orelse command;
            const enablement = jsonObjectString(object, "enablement");
            try commands.append(.{
                .command = try self.allocator.dupe(u8, command),
                .title = try self.allocator.dupe(u8, title),
                .enablement = if (enablement) |expr| try self.allocator.dupe(u8, expr) else null,
            });
        }
        return try commands.toOwnedSlice();
    }

    fn parseMenuContributions(self: *Self, root: anytype) ![]MenuContribution {
        const menus_object = contributionObjectValue(root, "menus") orelse return &.{};
        var menus = std.array_list.Managed(MenuContribution).init(self.allocator);
        var it = menus_object.iterator();
        while (it.next()) |entry| {
            const menu_id = entry.key_ptr.*;
            const array = switch (entry.value_ptr.*) {
                .array => |array| array,
                else => continue,
            };
            for (array.items) |item| {
                const object = switch (item) {
                    .object => |object| object,
                    else => continue,
                };
                const command = jsonObjectString(object, "command") orelse continue;
                const when = jsonObjectString(object, "when");
                const group = jsonObjectString(object, "group");
                const alt = jsonObjectString(object, "alt");
                const args = if (object.get("args")) |value| try jsonValueToOwnedRaw(self.allocator, value) else null;
                try menus.append(.{
                    .menu = try self.allocator.dupe(u8, menu_id),
                    .command = try self.allocator.dupe(u8, command),
                    .when = if (when) |expr| try self.allocator.dupe(u8, expr) else null,
                    .group = if (group) |expr| try self.allocator.dupe(u8, expr) else null,
                    .alt = if (alt) |expr| try self.allocator.dupe(u8, expr) else null,
                    .args = args,
                });
            }
        }
        return try menus.toOwnedSlice();
    }

    fn parseKeybindingContributions(self: *Self, root: anytype) ![]KeybindingContribution {
        const array = contributionArrayValue(root, "keybindings") orelse return &.{};
        var keybindings = std.array_list.Managed(KeybindingContribution).init(self.allocator);
        for (array.items) |item| {
            const object = switch (item) {
                .object => |object| object,
                else => continue,
            };
            const command = jsonObjectString(object, "command") orelse continue;
            const key = jsonObjectString(object, "key") orelse continue;
            const when = jsonObjectString(object, "when");
            const linux = jsonObjectString(object, "linux");
            const mac = jsonObjectString(object, "mac");
            const win = jsonObjectString(object, "win");
            try keybindings.append(.{
                .command = try self.allocator.dupe(u8, command),
                .key = try self.allocator.dupe(u8, key),
                .when = if (when) |expr| try self.allocator.dupe(u8, expr) else null,
                .linux = if (linux) |expr| try self.allocator.dupe(u8, expr) else null,
                .mac = if (mac) |expr| try self.allocator.dupe(u8, expr) else null,
                .win = if (win) |expr| try self.allocator.dupe(u8, expr) else null,
            });
        }
        return try keybindings.toOwnedSlice();
    }

    fn appendConfigurationProperties(self: *Self, configurations: *std.array_list.Managed(ConfigurationContribution), config_object: anytype) !void {
        const title = jsonObjectString(config_object, "title") orelse "Extension";
        const properties = switch (config_object.get("properties") orelse return) {
            .object => |object| object,
            else => return,
        };
        var it = properties.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const item = switch (entry.value_ptr.*) {
                .object => |object| object,
                else => continue,
            };
            const type_name = jsonObjectString(item, "type") orelse "string";
            const type_raw = if (item.get("type")) |value| try jsonValueToOwnedRaw(self.allocator, value) else try self.allocator.dupe(u8, "\"string\"");
            const description = jsonObjectString(item, "description");
            const default_raw = if (item.get("default")) |value| try jsonValueToOwnedRaw(self.allocator, value) else try self.allocator.dupe(u8, "null");
            try configurations.append(.{
                .key = try self.allocator.dupe(u8, key),
                .title = try self.allocator.dupe(u8, title),
                .type_name = try self.allocator.dupe(u8, type_name),
                .type_raw = type_raw,
                .default_raw = default_raw,
                .description = if (description) |text| try self.allocator.dupe(u8, text) else null,
            });
        }
    }

    fn parseConfigurationContributions(self: *Self, root: anytype) ![]ConfigurationContribution {
        const contributes = switch (root.get("contributes") orelse return &.{}) {
            .object => |object| object,
            else => return &.{},
        };
        const config_value = contributes.get("configuration") orelse return &.{};
        var configurations = std.array_list.Managed(ConfigurationContribution).init(self.allocator);
        switch (config_value) {
            .object => |config_object| try self.appendConfigurationProperties(&configurations, config_object),
            .array => |config_array| {
                for (config_array.items) |config_item| {
                    const config_object = switch (config_item) {
                        .object => |object| object,
                        else => continue,
                    };
                    try self.appendConfigurationProperties(&configurations, config_object);
                }
            },
            else => {},
        }
        return try configurations.toOwnedSlice();
    }

    fn parseLanguageContributions(self: *Self, root: anytype) ![]LanguageContribution {
        const array = contributionArrayValue(root, "languages") orelse return &.{};
        var languages = std.array_list.Managed(LanguageContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const id = jsonObjectString(item, "id") orelse continue;
            try languages.append(.{
                .id = try self.allocator.dupe(u8, id),
                .aliases = try self.parseStringArrayValue(item, "aliases"),
                .extensions = try self.parseStringArrayValue(item, "extensions"),
                .configuration = if (jsonObjectString(item, "configuration")) |configuration| try self.allocator.dupe(u8, configuration) else null,
            });
        }
        return try languages.toOwnedSlice();
    }

    fn parseGrammarContributions(self: *Self, root: anytype) ![]GrammarContribution {
        const array = contributionArrayValue(root, "grammars") orelse return &.{};
        var grammars = std.array_list.Managed(GrammarContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const scope_name = jsonObjectString(item, "scopeName") orelse continue;
            const path = jsonObjectString(item, "path") orelse continue;
            const language = jsonObjectString(item, "language") orelse "";
            try grammars.append(.{
                .language = try self.allocator.dupe(u8, language),
                .scope_name = try self.allocator.dupe(u8, scope_name),
                .path = try self.allocator.dupe(u8, path),
            });
        }
        return try grammars.toOwnedSlice();
    }

    fn parseThemeContributions(self: *Self, root: anytype) ![]ThemeContribution {
        const array = contributionArrayValue(root, "themes") orelse return &.{};
        var themes = std.array_list.Managed(ThemeContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const path = jsonObjectString(item, "path") orelse continue;
            const label = jsonObjectString(item, "label") orelse path;
            const id = jsonObjectString(item, "id") orelse label;
            try themes.append(.{
                .id = try self.allocator.dupe(u8, id),
                .label = try self.allocator.dupe(u8, label),
                .ui_theme = if (jsonObjectString(item, "uiTheme")) |ui_theme| try self.allocator.dupe(u8, ui_theme) else null,
                .path = try self.allocator.dupe(u8, path),
            });
        }
        return try themes.toOwnedSlice();
    }

    fn parseSnippetContributions(self: *Self, root: anytype) ![]SnippetContribution {
        const array = contributionArrayValue(root, "snippets") orelse return &.{};
        var snippets = std.array_list.Managed(SnippetContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const language = jsonObjectString(item, "language") orelse continue;
            const path = jsonObjectString(item, "path") orelse continue;
            try snippets.append(.{
                .language = try self.allocator.dupe(u8, language),
                .path = try self.allocator.dupe(u8, path),
            });
        }
        return try snippets.toOwnedSlice();
    }

    fn parseViewContainerContributions(self: *Self, root: anytype) ![]ViewContainerContribution {
        const object = contributionObjectValue(root, "viewsContainers") orelse return &.{};
        var containers = std.array_list.Managed(ViewContainerContribution).init(self.allocator);
        var it = object.iterator();
        while (it.next()) |entry| {
            const location = entry.key_ptr.*;
            const array = switch (entry.value_ptr.*) {
                .array => |array| array,
                else => continue,
            };
            for (array.items) |item_value| {
                const item = switch (item_value) {
                    .object => |item| item,
                    else => continue,
                };
                const id = jsonObjectString(item, "id") orelse continue;
                const title = jsonObjectString(item, "title") orelse id;
                try containers.append(.{
                    .location = try self.allocator.dupe(u8, location),
                    .id = try self.allocator.dupe(u8, id),
                    .title = try self.allocator.dupe(u8, title),
                    .icon = if (jsonObjectString(item, "icon")) |icon| try self.allocator.dupe(u8, icon) else null,
                });
            }
        }
        return try containers.toOwnedSlice();
    }

    fn parseViewContributions(self: *Self, root: anytype) ![]ViewContribution {
        const object = contributionObjectValue(root, "views") orelse return &.{};
        var views = std.array_list.Managed(ViewContribution).init(self.allocator);
        var it = object.iterator();
        while (it.next()) |entry| {
            const location = entry.key_ptr.*;
            const array = switch (entry.value_ptr.*) {
                .array => |array| array,
                else => continue,
            };
            for (array.items) |item_value| {
                const item = switch (item_value) {
                    .object => |item| item,
                    else => continue,
                };
                const id = jsonObjectString(item, "id") orelse continue;
                const raw_name = jsonObjectString(item, "name");
                const name = if (raw_name) |value|
                    if (value.len > 0) value else id
                else
                    id;
                try views.append(.{
                    .location = try self.allocator.dupe(u8, location),
                    .id = try self.allocator.dupe(u8, id),
                    .name = try self.allocator.dupe(u8, name),
                    .when = if (jsonObjectString(item, "when")) |when| try self.allocator.dupe(u8, when) else null,
                });
            }
        }
        return try views.toOwnedSlice();
    }

    fn parseViewsWelcomeContributions(self: *Self, root: anytype) ![]ViewWelcomeContribution {
        const array = contributionArrayValue(root, "viewsWelcome") orelse return &.{};
        var views_welcome = std.array_list.Managed(ViewWelcomeContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const view = jsonObjectString(item, "view") orelse continue;
            const contents = jsonObjectString(item, "contents") orelse continue;
            try views_welcome.append(.{
                .view = try self.allocator.dupe(u8, view),
                .contents = try self.allocator.dupe(u8, contents),
                .when = if (jsonObjectString(item, "when")) |when| try self.allocator.dupe(u8, when) else null,
            });
        }
        return try views_welcome.toOwnedSlice();
    }

    fn parseBreakpointContributions(self: *Self, root: anytype) ![]BreakpointContribution {
        const array = contributionArrayValue(root, "breakpoints") orelse return &.{};
        var breakpoints = std.array_list.Managed(BreakpointContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const language = jsonObjectString(item, "language") orelse continue;
            try breakpoints.append(.{ .language = try self.allocator.dupe(u8, language) });
        }
        return try breakpoints.toOwnedSlice();
    }

    fn parseJsonValidationContributions(self: *Self, root: anytype) ![]JsonValidationContribution {
        const array = contributionArrayValue(root, "jsonValidation") orelse return &.{};
        var validations = std.array_list.Managed(JsonValidationContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const url = jsonObjectString(item, "url") orelse continue;
            try validations.append(.{
                .file_match = try self.parseStringArrayValue(item, "fileMatch"),
                .url = try self.allocator.dupe(u8, url),
            });
        }
        return try validations.toOwnedSlice();
    }

    fn parseResourceLabelFormatterContributions(self: *Self, root: anytype) ![]ResourceLabelFormatterContribution {
        const array = contributionArrayValue(root, "resourceLabelFormatters") orelse return &.{};
        var formatters = std.array_list.Managed(ResourceLabelFormatterContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const scheme = jsonObjectString(item, "scheme") orelse continue;
            const formatting_value = item.get("formatting") orelse continue;
            try formatters.append(.{
                .scheme = try self.allocator.dupe(u8, scheme),
                .formatting_raw = try jsonValueToOwnedRaw(self.allocator, formatting_value),
            });
        }
        return try formatters.toOwnedSlice();
    }

    fn parseProblemMatcherContributions(self: *Self, root: anytype) ![]ProblemMatcherContribution {
        const array = contributionArrayValue(root, "problemMatchers") orelse return &.{};
        var matchers = std.array_list.Managed(ProblemMatcherContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const name = jsonObjectString(item, "name") orelse continue;
            const pattern_raw = if (item.get("pattern")) |value| try jsonValueToOwnedRaw(self.allocator, value) else null;
            try matchers.append(.{
                .name = try self.allocator.dupe(u8, name),
                .label = if (jsonObjectString(item, "label")) |label| try self.allocator.dupe(u8, label) else null,
                .owner = if (jsonObjectString(item, "owner")) |owner| try self.allocator.dupe(u8, owner) else null,
                .source = if (jsonObjectString(item, "source")) |source| try self.allocator.dupe(u8, source) else null,
                .pattern_raw = pattern_raw,
            });
        }
        return try matchers.toOwnedSlice();
    }

    fn parseTaskDefinitionContributions(self: *Self, root: anytype) ![]TaskDefinitionContribution {
        const array = contributionArrayValue(root, "taskDefinitions") orelse return &.{};
        var definitions = std.array_list.Managed(TaskDefinitionContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const type_name = jsonObjectString(item, "type") orelse continue;
            const properties_raw = if (item.get("properties")) |value| try jsonValueToOwnedRaw(self.allocator, value) else null;
            try definitions.append(.{
                .type_name = try self.allocator.dupe(u8, type_name),
                .required = try self.parseStringArrayValue(item, "required"),
                .properties_raw = properties_raw,
            });
        }
        return try definitions.toOwnedSlice();
    }

    fn parseDebuggerContributions(self: *Self, root: anytype) ![]DebuggerContribution {
        const array = contributionArrayValue(root, "debuggers") orelse return &.{};
        var debuggers = std.array_list.Managed(DebuggerContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const type_name = jsonObjectString(item, "type") orelse continue;
            const label = jsonObjectString(item, "label") orelse type_name;
            const configuration_attributes_raw = if (item.get("configurationAttributes")) |value| try jsonValueToOwnedRaw(self.allocator, value) else null;
            try debuggers.append(.{
                .type_name = try self.allocator.dupe(u8, type_name),
                .raw_json = try jsonValueToOwnedRaw(self.allocator, item_value),
                .label = try self.allocator.dupe(u8, label),
                .program = if (jsonObjectString(item, "program")) |program| try self.allocator.dupe(u8, program) else null,
                .runtime = if (jsonObjectString(item, "runtime")) |runtime| try self.allocator.dupe(u8, runtime) else null,
                .languages = try self.parseStringArrayValue(item, "languages"),
                .configuration_attributes_raw = configuration_attributes_raw,
            });
        }
        return try debuggers.toOwnedSlice();
    }

    fn parseIconThemeContributions(self: *Self, root: anytype) ![]IconThemeContribution {
        const array = contributionArrayValue(root, "iconThemes") orelse return &.{};
        var icon_themes = std.array_list.Managed(IconThemeContribution).init(self.allocator);
        for (array.items) |item_value| {
            const item = switch (item_value) {
                .object => |object| object,
                else => continue,
            };
            const id = jsonObjectString(item, "id") orelse continue;
            const path = jsonObjectString(item, "path") orelse continue;
            const label = jsonObjectString(item, "label") orelse id;
            try icon_themes.append(.{
                .id = try self.allocator.dupe(u8, id),
                .label = try self.allocator.dupe(u8, label),
                .path = try self.allocator.dupe(u8, path),
            });
        }
        return try icon_themes.toOwnedSlice();
    }

    fn parseWalkthroughContributions(self: *Self, root: anytype) ![]WalkthroughContribution {
        const walkthrough_object = contributionObjectValue(root, "walkthroughs") orelse return &.{};
        var walkthroughs = std.array_list.Managed(WalkthroughContribution).init(self.allocator);
        var it = walkthrough_object.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            const item = switch (entry.value_ptr.*) {
                .object => |object| object,
                else => continue,
            };
            const title = jsonObjectString(item, "title") orelse id;
            const description = jsonObjectString(item, "description");
            const steps_raw = if (item.get("steps")) |value| try jsonValueToOwnedRaw(self.allocator, value) else null;
            try walkthroughs.append(.{
                .id = try self.allocator.dupe(u8, id),
                .title = try self.allocator.dupe(u8, title),
                .description = if (description) |text| try self.allocator.dupe(u8, text) else null,
                .steps_raw = steps_raw,
            });
        }
        return try walkthroughs.toOwnedSlice();
    }

    fn parseRawContributionEntries(self: *Self, root: anytype, key: []const u8) ![]RawContribution {
        const contributes = switch (root.get("contributes") orelse return &.{}) {
            .object => |object| object,
            else => return &.{},
        };
        const value = contributes.get(key) orelse return &.{};
        var entries = std.array_list.Managed(RawContribution).init(self.allocator);
        switch (value) {
            .array => |array| {
                for (array.items) |item_value| {
                    var raw_key: ?[]const u8 = null;
                    if (item_value == .object) {
                        const object = item_value.object;
                        if (jsonObjectString(object, "id")) |id| {
                            raw_key = try self.allocator.dupe(u8, id);
                        } else if (jsonObjectString(object, "name")) |name| {
                            raw_key = try self.allocator.dupe(u8, name);
                        } else if (jsonObjectString(object, "type")) |type_name| {
                            raw_key = try self.allocator.dupe(u8, type_name);
                        }
                    }
                    try entries.append(.{
                        .key = raw_key,
                        .raw = try jsonValueToOwnedRaw(self.allocator, item_value),
                    });
                }
            },
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| {
                    try entries.append(.{
                        .key = try self.allocator.dupe(u8, entry.key_ptr.*),
                        .raw = try jsonValueToOwnedRaw(self.allocator, entry.value_ptr.*),
                    });
                }
            },
            else => {
                try entries.append(.{
                    .raw = try jsonValueToOwnedRaw(self.allocator, value),
                });
            },
        }
        return try entries.toOwnedSlice();
    }

    fn parseStringArrayValue(self: *Self, object: anytype, key: []const u8) ![]const []const u8 {
        return try ManifestParsing.ownedStringArrayLenient(self.allocator, object, key);
    }

    fn contributionArrayValue(root: anytype, key: []const u8) ?std.json.Array {
        return ManifestParsing.contributionArray(root, key);
    }

    fn contributionObjectValue(root: anytype, key: []const u8) ?std.json.ObjectMap {
        return ManifestParsing.contributionObject(root, key);
    }

    fn jsonValueToOwnedRaw(allocator: Allocator, value: std.json.Value) ![]u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(value, .{}, &out.writer);
        return try out.toOwnedSlice();
    }

    pub fn commandsRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"commands\":[", .{id_str});

        var first = true;
        const builtins = [_]CommandContribution{
            .{ .command = "workbench.action.files.openFolder", .title = "Open Folder" },
            .{ .command = "workbench.action.files.save", .title = "Save" },
            .{ .command = "workbench.action.terminal.new", .title = "New Terminal" },
            .{ .command = "workbench.action.findInFiles", .title = "Search" },
            .{ .command = "setContext", .title = "Set Context" },
        };
        for (builtins) |cmd| {
            if (!first) try w.writeAll(",");
            first = false;
            try writeCommandJson(w, cmd.command, cmd.title, null, true);
        }

        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.commands) |cmd| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    const enabled = self.evaluateWhenClause(cmd.enablement);
                    try writeCommandJson(w, cmd.command, cmd.title, cmd.enablement, enabled);
                }
            }
        }

        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    pub fn hostStatusRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const running = self.engine.initialized and self.engine.child != null;
        return try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"available\":true,\"running\":{},\"restartSupported\":true,\"extensionCount\":{},\"activatedCount\":{},\"disabledCount\":{},\"state\":\"{s}\"}}}}",
            .{
                id_str,
                running,
                self.extensions.count(),
                self.activated.count(),
                self.disabled_extensions.count(),
                if (running) "running" else "stopped",
            },
        );
    }
    pub fn crashHostRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const fixture = std.mem.indexOf(u8, body, "\"fixture\":true") != null;
        const smoke_mode = compat_runtime.getEnvVarOwned(self.allocator, "WIZP_NATIVE_UI_SMOKE") catch null;
        defer if (smoke_mode) |value| self.allocator.free(value);
        if (!fixture or smoke_mode == null or !std.mem.eql(u8, std.mem.trim(u8, smoke_mode.?, " \t\r\n"), "1")) {
            return try jsonRpcError(self.allocator, id_str, -32601, "Extension host crash fixture is unavailable.");
        }
        self.engine.crashForTest();
        return try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"state\":\"stopped\",\"fixture\":true}}}}",
            .{id_str},
        );
    }

    pub fn restartHostRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        self.restartHost() catch |err| {
            return try jsonRpcError(self.allocator, id_str, -32000, @errorName(err));
        };
        return try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"state\":\"running\",\"extensionCount\":{},\"activatedCount\":{}}}}}",
            .{ id_str, self.extensions.count(), self.activated.count() },
        );
    }

    fn emptyProviderResult(self: *Self, body: []const u8, field: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        return try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"{s}\":[]}}}}",
            .{ id_str, field },
        );
    }
    pub fn registeredCommandsRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const js =
            \\(function() {
            \\  const registry = (globalThis._wizpContext && globalThis._wizpContext.commands && globalThis._wizpContext.commands._registry) || {};
            \\  const commands = Object.keys(registry).sort().map(function(command) {
            \\    return { command: command, registered: true };
            \\  });
            \\  return { commands: commands, registeredCommandCount: commands.length };
            \\})()
        ;
        const engine_result = try self.engine.evalString(js, "registeredCommands");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"commands\":[],\"registeredCommandCount\":0}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn menusRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const menu_filter = extractJSONString(body, "\"menu\"") orelse "commandPalette";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"menus\":[", .{id_str});

        var first = true;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.menus) |menu| {
                    if (!std.mem.eql(u8, menu.menu, menu_filter)) continue;
                    const visible = self.evaluateWhenClause(menu.when);
                    if (!visible) continue;
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeMenuJson(w, menu, self.commandTitle(menu.command), self.commandEnablement(menu.command) orelse true);
                }
            }
        }

        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    pub fn keybindingsRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const platform = extractJSONString(body, "\"platform\"") orelse "linux";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"keybindings\":[", .{id_str});

        var first = true;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.keybindings) |kb| {
                    const key = selectKeybinding(kb, platform);
                    if (key.len == 0) continue;
                    const enabled = self.evaluateWhenClause(kb.when) and (self.commandEnablement(kb.command) orelse true);
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeKeybindingJson(w, kb, key, enabled, self.keybindingConflictCount(key, platform));
                }
            }
        }

        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    fn keybindingConflictCount(self: *Self, key: []const u8, platform: []const u8) usize {
        var count: usize = 0;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.keybindings) |kb| {
                    const candidate = selectKeybinding(kb, platform);
                    if (std.mem.eql(u8, candidate, key)) count += 1;
                }
            }
        }
        return count;
    }

    pub fn configurationRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"configuration\":[", .{id_str});
        var first = true;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.configurations) |cfg| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeConfigurationJson(w, cfg);
                }
            }
        }
        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    pub fn languageContributionsRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"languages\":[", .{id_str});
        var first = true;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.languages) |lang| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeLanguageJson(w, lang);
                }
            }
        }

        try w.writeAll("],\"grammars\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.grammars) |grammar| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeGrammarJson(w, grammar);
                }
            }
        }

        try w.writeAll("],\"themes\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.themes) |theme| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeThemeJson(w, theme);
                }
            }
        }

        try w.writeAll("],\"snippets\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.snippets) |snippet| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeSnippetJson(w, snippet);
                }
            }
        }

        try w.writeAll("],\"viewsContainers\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.views_containers) |container| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeViewContainerJson(w, container);
                }
            }
        }

        try w.writeAll("],\"views\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.views) |view| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeViewJson(w, view);
                }
            }
        }

        try w.writeAll("],\"viewsWelcome\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.views_welcome) |welcome| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeViewWelcomeJson(w, welcome);
                }
            }
        }

        try w.writeAll("],\"breakpoints\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.breakpoints) |breakpoint| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeBreakpointJson(w, breakpoint);
                }
            }
        }

        try w.writeAll("],\"jsonValidation\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.json_validations) |validation| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeJsonValidationJson(w, validation);
                }
            }
        }

        try w.writeAll("],\"resourceLabelFormatters\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.resource_label_formatters) |formatter| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeResourceLabelFormatterJson(w, formatter);
                }
            }
        }

        try w.writeAll("],\"problemMatchers\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.problem_matchers) |matcher| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeProblemMatcherJson(w, matcher);
                }
            }
        }

        try w.writeAll("],\"taskDefinitions\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.task_definitions) |definition| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeTaskDefinitionJson(w, definition);
                }
            }
        }

        try w.writeAll("],\"debuggers\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.debuggers) |debugger| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeDebuggerJson(w, debugger);
                }
            }
        }

        try w.writeAll("],\"iconThemes\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.icon_themes) |icon_theme| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeIconThemeJson(w, icon_theme);
                }
            }
        }

        try w.writeAll("],\"walkthroughs\":[");
        first = true;
        it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.walkthroughs) |walkthrough| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeWalkthroughJson(w, walkthrough);
                }
            }
        }

        try self.writeRawContributionFamily(w, "semanticTokenScopes", .semantic_token_scopes);
        try self.writeRawContributionFamily(w, "semanticTokenTypes", .semantic_token_types);
        try self.writeRawContributionFamily(w, "semanticTokenModifiers", .semantic_token_modifiers);
        try self.writeRawContributionFamily(w, "customEditors", .custom_editors);
        try self.writeRawContributionFamily(w, "languageModelTools", .language_model_tools);
        try self.writeRawContributionFamily(w, "yamlValidation", .yaml_validations);
        try self.writeRawContributionFamily(w, "debugVisualizers", .debug_visualizers);
        try self.writeRawContributionFamily(w, "javaExtensions", .java_extensions);
        try self.writeRawContributionFamily(w, "javaBuildFilePatterns", .java_build_file_patterns);
        try self.writeRawContributionFamily(w, "javaBuildTools", .java_build_tools);
        try self.writeRawContributionFamily(w, "javaShortcuts", .java_shortcuts);
        try self.writeRawContributionFamily(w, "chatParticipants", .chat_participants);
        try self.writeRawContributionFamily(w, "chatSessions", .chat_sessions);
        try self.writeRawContributionFamily(w, "icons", .icons);
        try self.writeRawContributionFamily(w, "mcpServerDefinitionProviders", .mcp_server_definition_providers);

        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    pub fn contributionSnapshotRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const extension_id = extractJSONString(body, "\"extensionId\"") orelse "";
        const platform = extractJSONString(body, "\"platform\"") orelse "linux";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{", .{id_str});

        if (extension_id.len == 0) {
            try w.writeAll("\"status\":\"missing-extension-id\",\"commands\":[],\"menus\":[],\"keybindings\":[],\"configuration\":[],\"languages\":[],\"grammars\":[],\"themes\":[],\"snippets\":[],\"viewsContainers\":[],\"views\":[],\"viewsWelcome\":[],\"breakpoints\":[],\"jsonValidation\":[],\"resourceLabelFormatters\":[],\"problemMatchers\":[],\"taskDefinitions\":[],\"debuggers\":[],\"iconThemes\":[],\"walkthroughs\":[],\"semanticTokenScopes\":[],\"semanticTokenTypes\":[],\"semanticTokenModifiers\":[],\"customEditors\":[],\"languageModelTools\":[],\"yamlValidation\":[],\"debugVisualizers\":[],\"javaExtensions\":[],\"javaBuildFilePatterns\":[],\"javaBuildTools\":[],\"javaShortcuts\":[],\"chatParticipants\":[],\"chatSessions\":[],\"icons\":[],\"mcpServerDefinitionProviders\":[]}}");
            return try out.toOwnedSlice();
        }

        const ext = self.findExtension(extension_id) orelse {
            try w.writeAll("\"status\":\"extension-not-found\",\"commands\":[],\"menus\":[],\"keybindings\":[],\"configuration\":[],\"languages\":[],\"grammars\":[],\"themes\":[],\"snippets\":[],\"viewsContainers\":[],\"views\":[],\"viewsWelcome\":[],\"breakpoints\":[],\"jsonValidation\":[],\"resourceLabelFormatters\":[],\"problemMatchers\":[],\"taskDefinitions\":[],\"debuggers\":[],\"iconThemes\":[],\"walkthroughs\":[],\"semanticTokenScopes\":[],\"semanticTokenTypes\":[],\"semanticTokenModifiers\":[],\"customEditors\":[],\"languageModelTools\":[],\"yamlValidation\":[],\"debugVisualizers\":[],\"javaExtensions\":[],\"javaBuildFilePatterns\":[],\"javaBuildTools\":[],\"javaShortcuts\":[],\"chatParticipants\":[],\"chatSessions\":[],\"icons\":[],\"mcpServerDefinitionProviders\":[]}}");
            return try out.toOwnedSlice();
        };

        try w.writeAll("\"status\":\"ok\",\"extensionId\":");
        try writeJsonString(w, ext.id);
        try w.writeAll(",\"publisher\":");
        try writeJsonString(w, ext.publisher);
        try w.writeAll(",\"displayName\":");
        try writeJsonString(w, ext.name);
        try w.writeAll(",\"version\":");
        try writeJsonString(w, ext.version);

        if (ext.contributes) |contributes| {
            try w.writeAll(",\"commands\":[");
            for (contributes.commands, 0..) |cmd, index| {
                if (index > 0) try w.writeAll(",");
                const enabled = self.evaluateWhenClause(cmd.enablement);
                try writeCommandJson(w, cmd.command, cmd.title, cmd.enablement, enabled);
            }

            try w.writeAll("],\"menus\":[");
            for (contributes.menus, 0..) |menu, index| {
                if (index > 0) try w.writeAll(",");
                try writeMenuJson(w, menu, self.commandTitle(menu.command), self.commandEnablement(menu.command) orelse true);
            }

            try w.writeAll("],\"keybindings\":[");
            for (contributes.keybindings, 0..) |kb, index| {
                const key = selectKeybinding(kb, platform);
                if (key.len == 0) continue;
                if (index > 0) try w.writeAll(",");
                const enabled = self.evaluateWhenClause(kb.when) and (self.commandEnablement(kb.command) orelse true);
                try writeKeybindingJson(w, kb, key, enabled, self.keybindingConflictCount(key, platform));
            }

            try w.writeAll("],\"configuration\":[");
            for (contributes.configurations, 0..) |cfg, index| {
                if (index > 0) try w.writeAll(",");
                try writeConfigurationJson(w, cfg);
            }

            try w.writeAll("],\"languages\":[");
            for (contributes.languages, 0..) |lang, index| {
                if (index > 0) try w.writeAll(",");
                try writeLanguageJson(w, lang);
            }

            try w.writeAll("],\"grammars\":[");
            for (contributes.grammars, 0..) |grammar, index| {
                if (index > 0) try w.writeAll(",");
                try writeGrammarJson(w, grammar);
            }

            try w.writeAll("],\"themes\":[");
            for (contributes.themes, 0..) |theme, index| {
                if (index > 0) try w.writeAll(",");
                try writeThemeJson(w, theme);
            }

            try w.writeAll("],\"snippets\":[");
            for (contributes.snippets, 0..) |snippet, index| {
                if (index > 0) try w.writeAll(",");
                try writeSnippetJson(w, snippet);
            }

            try w.writeAll("],\"viewsContainers\":[");
            for (contributes.views_containers, 0..) |container, index| {
                if (index > 0) try w.writeAll(",");
                try writeViewContainerJson(w, container);
            }

            try w.writeAll("],\"views\":[");
            for (contributes.views, 0..) |view, index| {
                if (index > 0) try w.writeAll(",");
                try writeViewJson(w, view);
            }

            try w.writeAll("],\"viewsWelcome\":[");
            for (contributes.views_welcome, 0..) |welcome, index| {
                if (index > 0) try w.writeAll(",");
                try writeViewWelcomeJson(w, welcome);
            }

            try w.writeAll("],\"breakpoints\":[");
            for (contributes.breakpoints, 0..) |breakpoint, index| {
                if (index > 0) try w.writeAll(",");
                try writeBreakpointJson(w, breakpoint);
            }

            try w.writeAll("],\"jsonValidation\":[");
            for (contributes.json_validations, 0..) |validation, index| {
                if (index > 0) try w.writeAll(",");
                try writeJsonValidationJson(w, validation);
            }

            try w.writeAll("],\"resourceLabelFormatters\":[");
            for (contributes.resource_label_formatters, 0..) |formatter, index| {
                if (index > 0) try w.writeAll(",");
                try writeResourceLabelFormatterJson(w, formatter);
            }

            try w.writeAll("],\"problemMatchers\":[");
            for (contributes.problem_matchers, 0..) |matcher, index| {
                if (index > 0) try w.writeAll(",");
                try writeProblemMatcherJson(w, matcher);
            }

            try w.writeAll("],\"taskDefinitions\":[");
            for (contributes.task_definitions, 0..) |definition, index| {
                if (index > 0) try w.writeAll(",");
                try writeTaskDefinitionJson(w, definition);
            }

            try w.writeAll("],\"debuggers\":[");
            for (contributes.debuggers, 0..) |debugger, index| {
                if (index > 0) try w.writeAll(",");
                try writeDebuggerJson(w, debugger);
            }

            try w.writeAll("],\"iconThemes\":[");
            for (contributes.icon_themes, 0..) |icon_theme, index| {
                if (index > 0) try w.writeAll(",");
                try writeIconThemeJson(w, icon_theme);
            }

            try w.writeAll("],\"walkthroughs\":[");
            for (contributes.walkthroughs, 0..) |walkthrough, index| {
                if (index > 0) try w.writeAll(",");
                try writeWalkthroughJson(w, walkthrough);
            }

            try writeScopedRawContributionFamily(w, contributes, "semanticTokenScopes", .semantic_token_scopes);
            try writeScopedRawContributionFamily(w, contributes, "semanticTokenTypes", .semantic_token_types);
            try writeScopedRawContributionFamily(w, contributes, "semanticTokenModifiers", .semantic_token_modifiers);
            try writeScopedRawContributionFamily(w, contributes, "customEditors", .custom_editors);
            try writeScopedRawContributionFamily(w, contributes, "languageModelTools", .language_model_tools);
            try writeScopedRawContributionFamily(w, contributes, "yamlValidation", .yaml_validations);
            try writeScopedRawContributionFamily(w, contributes, "debugVisualizers", .debug_visualizers);
            try writeScopedRawContributionFamily(w, contributes, "javaExtensions", .java_extensions);
            try writeScopedRawContributionFamily(w, contributes, "javaBuildFilePatterns", .java_build_file_patterns);
            try writeScopedRawContributionFamily(w, contributes, "javaBuildTools", .java_build_tools);
            try writeScopedRawContributionFamily(w, contributes, "javaShortcuts", .java_shortcuts);
            try writeScopedRawContributionFamily(w, contributes, "chatParticipants", .chat_participants);
            try writeScopedRawContributionFamily(w, contributes, "chatSessions", .chat_sessions);
            try writeScopedRawContributionFamily(w, contributes, "icons", .icons);
            try writeScopedRawContributionFamily(w, contributes, "mcpServerDefinitionProviders", .mcp_server_definition_providers);
            try w.writeAll("]}}");
        } else {
            try w.writeAll(",\"commands\":[],\"menus\":[],\"keybindings\":[],\"configuration\":[],\"languages\":[],\"grammars\":[],\"themes\":[],\"snippets\":[],\"viewsContainers\":[],\"views\":[],\"viewsWelcome\":[],\"breakpoints\":[],\"jsonValidation\":[],\"resourceLabelFormatters\":[],\"problemMatchers\":[],\"taskDefinitions\":[],\"debuggers\":[],\"iconThemes\":[],\"walkthroughs\":[],\"semanticTokenScopes\":[],\"semanticTokenTypes\":[],\"semanticTokenModifiers\":[],\"customEditors\":[],\"languageModelTools\":[],\"yamlValidation\":[],\"debugVisualizers\":[],\"javaExtensions\":[],\"javaBuildFilePatterns\":[],\"javaBuildTools\":[],\"javaShortcuts\":[],\"chatParticipants\":[],\"chatSessions\":[],\"icons\":[],\"mcpServerDefinitionProviders\":[]");
            try w.writeAll("}}");
        }
        return try out.toOwnedSlice();
    }

    pub fn languageRuntimePlanRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;

        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{", .{id_str});
        try w.writeAll("\"defaultTokenizer\":\"monaco\",\"textMateTokenization\":\"opt-in\",\"loadPolicy\":\"lazy\",\"onigurumaLoadedByDefault\":false,\"preserveWizpUiTheme\":true,\"largeFileDegrades\":true,\"plans\":[");

        var first = true;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.languages) |lang| {
                    var grammar_match: ?GrammarContribution = null;
                    for (contributes.grammars) |grammar| {
                        if (std.mem.eql(u8, grammar.language, lang.id)) {
                            grammar_match = grammar;
                            break;
                        }
                    }
                    var theme_match: ?ThemeContribution = null;
                    if (contributes.themes.len > 0) theme_match = contributes.themes[0];

                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{\"languageId\":");
                    try writeJsonString(w, lang.id);
                    try w.writeAll(",\"configurationPath\":");
                    if (lang.configuration) |configuration| try writeJsonString(w, configuration) else try w.writeAll("null");
                    try w.writeAll(",\"monacoLanguageConfiguration\":\"lazy\"");
                    try w.writeAll(",\"textMateGrammar\":");
                    if (grammar_match) |grammar| {
                        try w.writeAll("{\"scopeName\":");
                        try writeJsonString(w, grammar.scope_name);
                        try w.writeAll(",\"path\":");
                        try writeJsonString(w, grammar.path);
                        try w.writeAll(",\"policy\":\"opt-in-lazy\"}");
                    } else {
                        try w.writeAll("null");
                    }
                    try w.writeAll(",\"tokenTheme\":");
                    if (theme_match) |theme| {
                        try w.writeAll("{\"id\":");
                        try writeJsonString(w, theme.id);
                        try w.writeAll(",\"label\":");
                        try writeJsonString(w, theme.label);
                        try w.writeAll(",\"path\":");
                        try writeJsonString(w, theme.path);
                        try w.writeAll(",\"convertedToMonacoRules\":\"lazy\",\"appliesUiColors\":false}");
                    } else {
                        try w.writeAll("null");
                    }
                    try w.writeAll("}");
                }
            }
        }

        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    pub fn textMateRuntimeSmokeRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const enabled = std.mem.indexOf(u8, body, "\"enabled\":true") != null or std.mem.indexOf(u8, body, "\"optIn\":true") != null;
        const source_raw = extractJSONString(body, "\"source\"") orelse "smoke ember plain";
        const source = try unescapeJsonString(self.allocator, source_raw);
        defer self.allocator.free(source);
        const language_id = extractJSONString(body, "\"languageId\"") orelse "smokelang";

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;

        var extension_match: ?Extension = null;
        var language_match: ?LanguageContribution = null;
        var grammar_match: ?GrammarContribution = null;
        var theme_match: ?ThemeContribution = null;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            const contributes = ext.contributes orelse continue;
            for (contributes.languages) |lang| {
                if (!std.mem.eql(u8, lang.id, language_id)) continue;
                extension_match = ext;
                language_match = lang;
                for (contributes.grammars) |grammar| {
                    if (std.mem.eql(u8, grammar.language, lang.id)) {
                        grammar_match = grammar;
                        break;
                    }
                }
                if (contributes.themes.len > 0) theme_match = contributes.themes[0];
                break;
            }
            if (language_match != null) break;
        }

        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{", .{id_str});
        try w.writeAll("\"defaultTokenizer\":\"monaco\",\"startupSafe\":true,\"onigurumaLoadedByDefault\":false,\"monacoDefaultUnchanged\":true,\"preserveWizpUiTheme\":true,\"largeFileDegrades\":true,\"enabled\":");
        try w.writeAll(if (enabled) "true" else "false");
        try w.writeAll(",\"loaded\":");
        try w.writeAll(if (enabled) "true" else "false");
        try w.writeAll(",\"lazyLoaded\":");
        try w.writeAll(if (enabled) "true" else "false");

        if (!enabled or extension_match == null or language_match == null or grammar_match == null) {
            try w.writeAll(",\"languageId\":");
            try writeJsonString(w, language_id);
            try w.writeAll(",\"grammarTokenized\":false,\"tokens\":[],\"convertedTokenRules\":[],\"appliesUiColors\":false}}");
            return try out.toOwnedSlice();
        }

        const ext = extension_match.?;
        const lang = language_match.?;
        const grammar = grammar_match.?;
        const theme = theme_match;
        const grammar_path = try joinExtensionPath(self.allocator, ext.path, grammar.path);
        defer self.allocator.free(grammar_path);
        const grammar_json = try std.Io.Dir.cwd().readFileAlloc(
            compat_runtime.io(),
            grammar_path,
            self.allocator,
            .limited(1024 * 1024),
        );
        defer self.allocator.free(grammar_json);
        const match_pattern_raw = extractJSONString(grammar_json, "\"match\"") orelse "\\b(smoke|ember)\\b";
        const match_pattern = try unescapeJsonString(self.allocator, match_pattern_raw);
        defer self.allocator.free(match_pattern);
        const token_scope = extractJSONString(grammar_json, "\"name\"") orelse grammar.scope_name;

        try w.writeAll(",\"languageId\":");
        try writeJsonString(w, lang.id);
        try w.writeAll(",\"scopeName\":");
        try writeJsonString(w, grammar.scope_name);
        try w.writeAll(",\"grammarPath\":");
        try writeJsonString(w, grammar.path);
        try w.writeAll(",\"grammarLoadedFromContribution\":true,\"matchPattern\":");
        try writeJsonString(w, match_pattern);
        try w.writeAll(",\"grammarTokenized\":true,\"tokens\":[");
        try writeSmokeTokens(w, source, token_scope);
        try w.writeAll("],\"convertedTokenRules\":[");
        if (theme) |theme_value| {
            const theme_path = try joinExtensionPath(self.allocator, ext.path, theme_value.path);
            defer self.allocator.free(theme_path);
            const theme_json = try std.Io.Dir.cwd().readFileAlloc(
                compat_runtime.io(),
                theme_path,
                self.allocator,
                .limited(1024 * 1024),
            );
            defer self.allocator.free(theme_json);
            const rule_scope = extractJSONString(theme_json, "\"scope\"") orelse token_scope;
            const foreground = extractJSONString(theme_json, "\"foreground\"") orelse "#ffcc66";
            try w.writeAll("{\"token\":");
            try writeJsonString(w, rule_scope);
            try w.writeAll(",\"foreground\":");
            try writeJsonString(w, foreground);
            try w.writeAll(",\"target\":\"editor-token\",\"sourceTheme\":");
            try writeJsonString(w, theme_value.id);
            try w.writeAll("}");
        }
        try w.writeAll("],\"appliesUiColors\":false,\"uiColorsIgnored\":[\"editor.background\"],\"themeConversionTarget\":\"monaco-token-rules-only\"}}");
        return try out.toOwnedSlice();
    }

    pub fn viewsContainersRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"containers\":[", .{id_str});
        var first = true;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.views_containers) |container| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeViewContainerJson(w, container);
                }
            }
        }
        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    pub fn viewsRpc(self: *Self, body: []const u8) ![]u8 {
        if (extractJSONString(body, "\"view\"") orelse extractJSONString(body, "\"viewId\"")) |view_id| {
            const event = try std.fmt.allocPrint(self.allocator, "view:{s}", .{view_id});
            defer self.allocator.free(event);
            try self.activateByEvent(event);
        }
        const id_str = extractJsonRpcId(body) orelse "null";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"views\":[", .{id_str});
        var first = true;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.views) |view| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeViewJson(w, view);
                }
            }
        }
        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    pub fn viewsWelcomeRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"viewsWelcome\":[", .{id_str});
        var first = true;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.views_welcome) |welcome| {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeViewWelcomeJson(w, welcome);
                }
            }
        }
        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    pub fn diagnosticsRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const js =
            \\({
            \\  collections: Object.values(globalThis._wizpDiagnosticCollections || {}).map(c => ({
            \\    id: c.id,
            \\    name: c.name,
            \\    entries: Object.keys(c.entries || {}).map(uri => ({ uri: uri, diagnostics: c.entries[uri] || [] }))
            \\  }))
            \\})
        ;
        const engine_result = try self.engine.evalString(js, "diagnostics");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"collections\":[]}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn debugStateRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const js = try std.fmt.allocPrint(self.allocator,
            \\(async function() {{
            \\  const req = {s};
            \\  const p = req.params || {{}};
            \\  const configSection = p.configSection || null;
            \\  const configKeys = Array.isArray(p.configKeys) ? p.configKeys : [];
            \\  const config = {{}};
            \\  if (configSection) {{
            \\    const activeDocument = globalThis._wizpContext.window.activeTextEditor && globalThis._wizpContext.window.activeTextEditor.document;
            \\    const cfg = globalThis._wizpContext.workspace.getConfiguration(configSection, activeDocument);
            \\    for (const key of configKeys) config[key] = cfg.get(key);
            \\  }}
            \\  const configInspect = {{}};
            \\  if (configSection && p.inspect) {{
            \\    const activeDocument = globalThis._wizpContext.window.activeTextEditor && globalThis._wizpContext.window.activeTextEditor.document;
            \\    const cfg = globalThis._wizpContext.workspace.getConfiguration(configSection, activeDocument);
            \\    for (const key of configKeys) configInspect[key] = cfg.inspect(key);
            \\  }}
            \\  const docs = Object.values(globalThis._wizpDocuments || {{}}).map(function(doc) {{
            \\    return {{
            \\      uri: doc.uri && doc.uri.toString ? doc.uri.toString() : String(doc.uri || ''),
            \\      fileName: doc.fileName,
            \\      languageId: doc.languageId,
            \\      version: doc.version,
            \\      textLength: doc.getText ? doc.getText().length : 0
            \\    }};
            \\  }});
            \\  const listenerCounts = {{}};
            \\  for (const key of Object.keys(globalThis._wizpTextDocumentListeners || {{}})) listenerCounts[key] = (globalThis._wizpTextDocumentListeners[key] || []).length;
            \\  const active = globalThis._wizpContext.window.activeTextEditor && globalThis._wizpContext.window.activeTextEditor.document;
            \\  const extensions = Object.values(globalThis._wizpExtensions || {{}})
            \\    .filter(function(ext, index, all) {{
            \\      return !!ext && !!ext.id && all.findIndex(function(candidate) {{ return candidate && candidate.id === ext.id; }}) === index;
            \\    }})
            \\    .map(function(ext) {{
            \\      return {{
            \\        id: ext.id || '',
            \\        name: ext.name || '',
            \\        publisher: ext.publisher || '',
            \\        activationEvents: ext.activationEvents || [],
            \\        isActive: !!ext.isActive,
            \\        activationState: ext.activationState || null,
            \\        hasActivationPromise: !!(ext && ext.activationPromise && typeof ext.activationPromise.then === 'function')
            \\      }};
            \\    }});
            \\  const safePayload = function(value) {{
            \\    try {{
            \\      return JSON.parse(JSON.stringify(value, function(key, item) {{
            \\        if (typeof item === 'function') return undefined;
            \\        if (item && typeof item === 'object' && typeof item.toString === 'function' && item.scheme) return item.toString();
            \\        return item;
            \\      }}));
            \\    }} catch (error) {{
            \\      return {{ __wizpUnserializable: String(error && error.message ? error.message : error) }};
            \\    }}
            \\  }};
            \\  const rawDebugConfigurationProviderRegistrations = globalThis._wizp_debugConfigurationProviderRegistrations || Object.keys(globalThis._wizp_debugConfigurationProviders || {{}}).map(function(type) {{
            \\    const entry = globalThis._wizp_debugConfigurationProviders[type] || {{}};
            \\    return {{ id: null, type: type, triggerKind: entry.triggerKind === undefined ? null : entry.triggerKind, provider: entry.provider }};
            \\  }});
            \\  const debugConfigurationProviderRegistrations = rawDebugConfigurationProviderRegistrations.map(function(entry) {{ return {{ id: entry.id || null, type: String(entry.type || ''), triggerKind: entry.triggerKind === undefined ? null : entry.triggerKind }}; }});
            \\  const rawDebugAdapterDescriptorFactoryRegistrations = globalThis._wizp_debugAdapterDescriptorFactoryRegistrations || Object.keys(globalThis._wizp_debugFactories || {{}}).map(function(type) {{
            \\    return {{ id: null, type: type }};
            \\  }});
            \\  const debugAdapterDescriptorFactoryRegistrations = rawDebugAdapterDescriptorFactoryRegistrations.map(function(entry) {{ return {{ id: entry.id || null, type: String(entry.type || '') }}; }});
            \\  const rawDebugAdapterTrackerFactoryRegistrations = globalThis._wizp_debugAdapterTrackerFactoryRegistrations || Object.keys(globalThis._wizp_debugTrackerFactories || {{}}).map(function(type) {{
            \\    return {{ id: null, type: type }};
            \\  }});
            \\  const debugAdapterTrackerFactoryRegistrations = rawDebugAdapterTrackerFactoryRegistrations.map(function(entry) {{ return {{ id: entry.id || null, type: String(entry.type || '') }}; }});
            \\  const providerRegistrations = {{
            \\    completions: (globalThis._wizpCompletionProviders || []).map(function(entry) {{ return {{ id: entry.id, selector: entry.selector, triggerCharacters: entry.triggerCharacters || [] }}; }}),
            \\    inlineCompletions: (globalThis._wizpInlineCompletionProviders || []).map(function(entry) {{ return {{ id: entry.id, selector: entry.selector }}; }}),
            \\    colors: (globalThis._wizpColorProviders || []).map(function(entry) {{ return {{ id: entry.id, selector: entry.selector }}; }}),
            \\    codeActions: (globalThis._wizpCodeActionProviders || []).map(function(entry) {{ return {{ id: entry.id, selector: entry.selector, metadata: entry.metadata || null }}; }}),
            \\    documentFormatting: (globalThis._wizpDocumentFormattingProviders || []).map(function(entry) {{ return {{ id: entry.id, selector: entry.selector }}; }}),
            \\    selectionRanges: (globalThis._wizpSelectionRangeProviders || []).map(function(entry) {{ return {{ id: entry.id, selector: entry.selector }}; }}),
            \\    fileDecorations: (globalThis._wizpFileDecorationProviders || []).map(function(entry) {{ return {{ id: entry.id }}; }}),
            \\    portAttributes: (globalThis._wizpPortAttributesProviders || []).map(function(entry) {{ return {{ id: entry.id, selector: entry.selector }}; }}),
            \\    debugConfigurationProviders: debugConfigurationProviderRegistrations,
            \\    debugAdapterDescriptorFactories: debugAdapterDescriptorFactoryRegistrations,
            \\    debugAdapterTrackerFactories: debugAdapterTrackerFactoryRegistrations,
            \\    debugVisualizationTree: Object.keys(globalThis._wizp_debugVisualizationTreeProviders || {{}}),
            \\    debugVisualizations: Object.keys(globalThis._wizp_debugVisualizationProviders || {{}}),
            \\    diagnostics: Object.keys(globalThis._wizpDiagnosticCollections || {{}})
            \\  }};
            \\  let debugConfigurationProbe = null;
            \\  if (p.debugConfigurationProbe) {{
            \\    const probe = p.debugConfigurationProbe || {{}};
            \\    const requestedTypes = Array.isArray(probe.types) ? probe.types.map(function(item) {{ return String(item || ''); }}).filter(Boolean) : [];
            \\    const baseConfig = probe.configuration && typeof probe.configuration === 'object' ? probe.configuration : {{}};
            \\    const token = {{ isCancellationRequested: false, onCancellationRequested: function() {{ return {{ dispose: function() {{}} }}; }} }};
            \\    const folder = (globalThis._wizpContext.workspace.workspaceFolders || [])[0] || null;
            \\    const callTimeoutMs = Math.max(100, Math.min(Number(probe.timeoutMs || 750), 1500));
            \\    const withProbeTimeout = async function(value, label) {{
            \\      return await new Promise(function(resolve) {{
            \\        let done = false;
            \\        const timer = setTimeout(function() {{
            \\          if (done) return;
            \\          done = true;
            \\          resolve({{ status: "timeout", label: label, timeoutMs: callTimeoutMs }});
            \\        }}, callTimeoutMs);
            \\        Promise.resolve(value).then(function(result) {{
            \\          if (done) return;
            \\          done = true;
            \\          clearTimeout(timer);
            \\          resolve({{ status: "ok", value: result }});
            \\        }}, function(error) {{
            \\          if (done) return;
            \\          done = true;
            \\          clearTimeout(timer);
            \\          resolve({{ status: "error", error: String(error && error.message ? error.message : error) }});
            \\        }});
            \\      }});
            \\    }};
            \\    const results = [];
            \\    for (const entry of rawDebugConfigurationProviderRegistrations) {{
            \\      const debugType = String(entry.type || '');
            \\      if (requestedTypes.length && requestedTypes.indexOf(debugType) < 0) continue;
            \\      const mapEntry = (globalThis._wizp_debugConfigurationProviders || {{}})[debugType] || {{}};
            \\      const provider = entry.provider || mapEntry.provider;
            \\      const result = {{ id: entry.id || null, type: debugType, triggerKind: entry.triggerKind === undefined ? null : entry.triggerKind }};
            \\      if (!provider) {{
            \\        result.status = "missing-provider-object";
            \\        results.push(result);
            \\        continue;
            \\      }}
            \\      result.status = "captured";
            \\      if (typeof provider.provideDebugConfigurations === 'function') {{
            \\        try {{
            \\          const outcome = await withProbeTimeout(provider.provideDebugConfigurations(folder, token), "provideDebugConfigurations");
            \\          if (outcome.status === "ok") result.provideDebugConfigurations = safePayload(outcome.value);
            \\          else result.provideDebugConfigurationsError = outcome.error || (outcome.label + " timed out after " + outcome.timeoutMs + "ms");
            \\        }} catch (error) {{
            \\          result.provideDebugConfigurationsError = String(error && error.message ? error.message : error);
            \\        }}
            \\      }}
            \\      const config = Object.assign({{ type: debugType, name: "WIZP parity debug config probe", request: "launch" }}, baseConfig);
            \\      if (typeof provider.resolveDebugConfiguration === 'function') {{
            \\        try {{
            \\          const outcome = await withProbeTimeout(provider.resolveDebugConfiguration(folder, Object.assign({{}}, config), token), "resolveDebugConfiguration");
            \\          if (outcome.status === "ok") result.resolveDebugConfiguration = safePayload(outcome.value);
            \\          else result.resolveDebugConfigurationError = outcome.error || (outcome.label + " timed out after " + outcome.timeoutMs + "ms");
            \\        }} catch (error) {{
            \\          result.resolveDebugConfigurationError = String(error && error.message ? error.message : error);
            \\        }}
            \\      }}
            \\      if (typeof provider.resolveDebugConfigurationWithSubstitutedVariables === 'function') {{
            \\        try {{
            \\          const outcome = await withProbeTimeout(provider.resolveDebugConfigurationWithSubstitutedVariables(folder, Object.assign({{}}, config), token), "resolveDebugConfigurationWithSubstitutedVariables");
            \\          if (outcome.status === "ok") result.resolveDebugConfigurationWithSubstitutedVariables = safePayload(outcome.value);
            \\          else result.resolveDebugConfigurationWithSubstitutedVariablesError = outcome.error || (outcome.label + " timed out after " + outcome.timeoutMs + "ms");
            \\        }} catch (error) {{
            \\          result.resolveDebugConfigurationWithSubstitutedVariablesError = String(error && error.message ? error.message : error);
            \\        }}
            \\      }}
            \\      results.push(result);
            \\    }}
            \\    debugConfigurationProbe = {{ status: results.length ? "captured" : "missing-provider", requestedTypes: requestedTypes, results: results }};
            \\  }}
            \\  return {{
            \\    activeTextEditor: active ? {{ uri: active.uri.toString(), fileName: active.fileName, languageId: active.languageId, version: active.version }} : null,
            \\    textDocuments: docs,
            \\    extensions: extensions,
            \\    listenerCounts: listenerCounts,
            \\    providerCounts: {{
            \\      codeActions: (globalThis._wizpCodeActionProviders || []).length,
            \\      documentFormatting: (globalThis._wizpDocumentFormattingProviders || []).length,
            \\      rangeFormatting: (globalThis._wizpRangeFormattingProviders || []).length,
            \\      completions: (globalThis._wizpCompletionProviders || []).length,
            \\      inlineCompletions: (globalThis._wizpInlineCompletionProviders || []).length,
            \\      colors: (globalThis._wizpColorProviders || []).length,
            \\      documentSymbols: (globalThis._wizpDocumentSymbolProviders || []).length,
            \\      selectionRanges: (globalThis._wizpSelectionRangeProviders || []).length,
            \\      workspaceSymbols: (globalThis._wizpWorkspaceSymbolProviders || []).length,
            \\      inlineValues: (globalThis._wizpInlineValuesProviders || []).length,
            \\      fileDecorations: (globalThis._wizpFileDecorationProviders || []).length,
            \\      portAttributes: (globalThis._wizpPortAttributesProviders || []).length,
            \\      debugConfigurationProviders: debugConfigurationProviderRegistrations.length,
            \\      debugAdapterDescriptorFactories: debugAdapterDescriptorFactoryRegistrations.length,
            \\      debugAdapterTrackerFactories: debugAdapterTrackerFactoryRegistrations.length,
            \\      debugVisualizationTree: Object.keys(globalThis._wizp_debugVisualizationTreeProviders || {{}}).length,
            \\      debugVisualizations: Object.keys(globalThis._wizp_debugVisualizationProviders || {{}}).length,
            \\      diagnostics: Object.keys(globalThis._wizpDiagnosticCollections || {{}}).length
            \\    }},
            \\    providerRegistrations: providerRegistrations,
            \\    debugConfigurationProbe: debugConfigurationProbe,
            \\    configuration: config,
            \\    configurationInspect: configInspect,
            \\    configurationReads: (globalThis._wizpConfigurationReads || []).slice(-100),
            \\    uiQueueLength: (globalThis._wizp_uiQueue || []).length
            \\  }};
            \\}})()
        , .{body});
        defer self.allocator.free(js);
        const engine_result = self.engine.evalStringTimeoutMs(js, self.diagnosticRpcTimeoutMs()) catch |err| {
            if (err == error.Timeout) {
                _ = self.restartHost() catch {};
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"textDocuments\":[],\"extensions\":[],\"listenerCounts\":{{}},\"providerCounts\":{{}},\"providerRegistrations\":{{}},\"configuration\":{{}},\"configurationInspect\":{{}},\"uiQueueLength\":0,\"rpcTimeout\":true}}}}", .{id_str});
            }
            return err;
        };
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"textDocuments\":[]}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn decorationsRpc(self: *Self, body: []const u8) ![]u8 {
        if (self.extensions.count() == 0) {
            const id_str = extractJsonRpcId(body) orelse "null";
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"types\":[],\"editors\":[]}}}}",
                .{id_str},
            );
        }
        const id_str = extractJsonRpcId(body) orelse "null";
        const js =
            \\({
            \\  types: Object.values(globalThis._wizpDecorationTypes || {}).map(t => ({
            \\    id: t.id,
            \\    options: t.options || {},
            \\    disposed: !!t.disposed
            \\  })),
            \\  editors: Object.keys(globalThis._wizpEditorDecorations || {}).map(uri => ({
            \\    uri: uri,
            \\    decorations: Object.keys(globalThis._wizpEditorDecorations[uri] || {}).map(typeId => ({
            \\      typeId: typeId,
            \\      ranges: globalThis._wizpEditorDecorations[uri][typeId] || []
            \\    }))
            \\  }))
            \\})
        ;
        const engine_result = try self.engine.evalString(js, "decorations");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"types\":[],\"editors\":[]}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn codeLensesRpc(self: *Self, body: []const u8) ![]u8 {
        if (self.extensions.count() == 0) return try self.emptyProviderResult(body, "lenses");
        const id_str = extractJsonRpcId(body) orelse "null";
        const js = try std.fmt.allocPrint(self.allocator,
            \\(async () => {{
            \\  const req = {s};
            \\  const p = req.params || {{}};
            \\  const uri = globalThis._wizpContext.Uri.parse(p.uri || req.uri || 'file://active.txt');
            \\  const document = {{
            \\    uri: uri,
            \\    fileName: uri.fsPath || uri.path || String(uri),
            \\    languageId: 'plaintext',
            \\    version: 1,
            \\    getText: function() {{ return ''; }}
            \\  }};
            \\  const providers = globalThis._wizpCodeLensProviders || [];
            \\  const lenses = [];
            \\  for (const entry of providers) {{
            \\    const provided = await Promise.resolve(entry.provider.provideCodeLenses(document, {{ isCancellationRequested: false }}));
            \\    for (const lens of (provided || [])) {{
            \\      let resolved = lens;
            \\      if (!resolved.command && entry.provider.resolveCodeLens) {{
            \\        resolved = await Promise.resolve(entry.provider.resolveCodeLens(lens, {{ isCancellationRequested: false }}));
            \\      }}
            \\      lenses.push({{
            \\        providerId: entry.id,
            \\        range: {{
            \\          start: {{ line: resolved.range.start.line, character: resolved.range.start.character }},
            \\          end: {{ line: resolved.range.end.line, character: resolved.range.end.character }}
            \\        }},
            \\        command: resolved.command || null
            \\      }});
            \\    }}
            \\  }}
            \\  return {{ lenses }};
            \\}})()
        , .{body});
        defer self.allocator.free(js);
        const engine_result = try self.engine.evalString(js, "codeLenses");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"lenses\":[]}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn inlayHintsRpc(self: *Self, body: []const u8) ![]u8 {
        if (self.extensions.count() == 0) return try self.emptyProviderResult(body, "hints");
        const id_str = extractJsonRpcId(body) orelse "null";
        const js = try std.fmt.allocPrint(self.allocator,
            \\(async () => {{
            \\  const req = {s};
            \\  const p = req.params || {{}};
            \\  const uri = globalThis._wizpContext.Uri.parse(p.uri || req.uri || 'file://active.txt');
            \\  const document = {{
            \\    uri: uri,
            \\    fileName: uri.fsPath || uri.path || String(uri),
            \\    languageId: 'plaintext',
            \\    version: 1,
            \\    getText: function() {{ return ''; }}
            \\  }};
            \\  const range = p.range || req.range || {{
            \\    start: {{ line: 0, character: 0 }},
            \\    end: {{ line: 999999, character: 999999 }}
            \\  }};
            \\  const providers = globalThis._wizpInlayHintProviders || [];
            \\  const hints = [];
            \\  for (const entry of providers) {{
            \\    const provided = await Promise.resolve(entry.provider.provideInlayHints(document, range, {{ isCancellationRequested: false }}));
            \\    for (const hint of (provided || [])) {{
            \\      let resolved = hint;
            \\      if ((!resolved.tooltip && !resolved.textEdits) && entry.provider.resolveInlayHint) {{
            \\        resolved = await Promise.resolve(entry.provider.resolveInlayHint(hint, {{ isCancellationRequested: false }}));
            \\      }}
            \\      hints.push({{
            \\        providerId: entry.id,
            \\        position: {{ line: resolved.position.line, character: resolved.position.character }},
            \\        label: resolved.label,
            \\        kind: resolved.kind === undefined ? null : resolved.kind,
            \\        tooltip: resolved.tooltip === undefined ? null : resolved.tooltip,
            \\        paddingLeft: !!resolved.paddingLeft,
            \\        paddingRight: !!resolved.paddingRight
            \\      }});
            \\    }}
            \\  }}
            \\  return {{ hints }};
            \\}})()
        , .{body});
        defer self.allocator.free(js);
        const engine_result = try self.engine.evalString(js, "inlayHints");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"hints\":[]}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn semanticTokensRpc(self: *Self, body: []const u8) ![]u8 {
        if (self.extensions.count() == 0) return try self.emptyProviderResult(body, "tokens");
        const id_str = extractJsonRpcId(body) orelse "null";
        const js = try std.fmt.allocPrint(self.allocator,
            \\(async () => {{
            \\  const req = {s};
            \\  const p = req.params || {{}};
            \\  const uri = globalThis._wizpContext.Uri.parse(p.uri || req.uri || 'file://active.txt');
            \\  const document = {{
            \\    uri: uri,
            \\    fileName: uri.fsPath || uri.path || String(uri),
            \\    languageId: 'plaintext',
            \\    version: 1,
            \\    getText: function() {{ return ''; }}
            \\  }};
            \\  const providers = globalThis._wizpSemanticTokenProviders || [];
            \\  const results = [];
            \\  for (const entry of providers) {{
            \\    const provided = await Promise.resolve(entry.provider.provideDocumentSemanticTokens(document, {{ isCancellationRequested: false }}));
            \\    if (!provided) continue;
            \\    results.push({{
            \\      providerId: entry.id,
            \\      legend: entry.legend,
            \\      resultId: provided.resultId || null,
            \\      data: Array.from(provided.data || [])
            \\    }});
            \\  }}
            \\  return {{ tokens: results }};
            \\}})()
        , .{body});
        defer self.allocator.free(js);
        const engine_result = try self.engine.evalString(js, "semanticTokens");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"tokens\":[]}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn foldingRangesRpc(self: *Self, body: []const u8) ![]u8 {
        if (self.extensions.count() == 0) return try self.emptyProviderResult(body, "ranges");
        const id_str = extractJsonRpcId(body) orelse "null";
        const js = try std.fmt.allocPrint(self.allocator,
            \\(async () => {{
            \\  const req = {s};
            \\  const p = req.params || {{}};
            \\  const uri = globalThis._wizpContext.Uri.parse(p.uri || req.uri || 'file://active.txt');
            \\  const document = {{
            \\    uri: uri,
            \\    fileName: uri.fsPath || uri.path || String(uri),
            \\    languageId: 'plaintext',
            \\    version: 1,
            \\    getText: function() {{ return ''; }}
            \\  }};
            \\  const providers = globalThis._wizpFoldingRangeProviders || [];
            \\  const ranges = [];
            \\  for (const entry of providers) {{
            \\    const provided = await Promise.resolve(entry.provider.provideFoldingRanges(document, {{ isCancellationRequested: false }}));
            \\    for (const range of (provided || [])) {{
            \\      ranges.push({{
            \\        providerId: entry.id,
            \\        start: range.start,
            \\        end: range.end,
            \\        kind: range.kind === undefined ? null : range.kind,
            \\        startCharacter: range.startCharacter === undefined ? null : range.startCharacter,
            \\        endCharacter: range.endCharacter === undefined ? null : range.endCharacter
            \\      }});
            \\    }}
            \\  }}
            \\  return {{ ranges }};
            \\}})()
        , .{body});
        defer self.allocator.free(js);
        const engine_result = try self.engine.evalString(js, "foldingRanges");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"ranges\":[]}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn languageProvidersRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        var activation_error_json: []u8 = "";
        if (extractJSONString(body, "\"languageId\"")) |language_id| {
            const event = try std.fmt.allocPrint(self.allocator, "language:{s}", .{language_id});
            defer self.allocator.free(event);
            self.activateByEvent(event) catch |err| {
                const err_name = @errorName(err);
                activation_error_json = try std.fmt.allocPrint(self.allocator, ",\"activationError\":{{\"event\":\"{s}\",\"name\":\"{s}\"}}", .{ event, err_name });
            };
        }
        defer if (activation_error_json.len > 0) self.allocator.free(activation_error_json);
        const js = try std.fmt.allocPrint(self.allocator,
            \\(async () => {{
            \\  const req = {s};
            \\  const p = req.params || {{}};
            \\  const uri = globalThis._wizpContext.Uri.parse(p.uri || req.uri || 'file://active.txt');
            \\  const key = uri && uri.toString ? uri.toString() : String(uri);
            \\  const line = p.line === undefined ? 0 : p.line;
            \\  const character = p.character === undefined ? (p.col === undefined ? 0 : p.col) : p.character;
            \\  const providerTimeoutMs = Number(p.providerTimeoutMs || 0);
            \\  const registrationWaitMs = Number(p.registrationWaitMs || 0);
            \\  let document = globalThis._wizpDocuments[key];
            \\  if (!document) {{
            \\    document = await globalThis._wizpContext.workspace.openTextDocument(uri);
            \\  }}
            \\  if (p.languageId) document.languageId = p.languageId;
            \\  if (Object.prototype.hasOwnProperty.call(p, 'text')) {{
            \\    const nextText = String(p.text || '');
            \\    if (document.getText() !== nextText) {{
            \\      globalThis._wizpContext.workspace._changeTextDocument(document, [{{
            \\        range: new globalThis._wizpContext.Range(
            \\          new globalThis._wizpContext.Position(0, 0),
            \\          new globalThis._wizpContext.Position(Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER)
            \\        ),
            \\        newText: nextText
            \\      }}]);
            \\    }}
            \\  }}
            \\  const requestedPosition = new globalThis._wizpContext.Position(line, character);
            \\  const position = document && typeof document.validatePosition === 'function'
            \\    ? document.validatePosition(requestedPosition)
            \\    : requestedPosition;
            \\  const editor = await globalThis._wizpContext.window.showTextDocument(document, {{
            \\    viewColumn: 1,
            \\    selection: new globalThis._wizpContext.Range(position, position),
            \\    preserveFocus: false
            \\  }});
            \\  if (editor) {{
            \\    editor.selection = new globalThis._wizpContext.Selection(position, position);
            \\    editor.selections = [editor.selection];
            \\  }}
            \\  const tokenSource = new globalThis._wizpContext.CancellationTokenSource();
            \\  if (p.cancelled) tokenSource.cancel();
            \\  const token = tokenSource.token;
            \\  const providerTimedOut = function(value) {{ return !!(value && value.__wizpProviderTimedOut); }};
            \\  const providerTimeoutValue = function(entry, label) {{
            \\    return {{ __wizpProviderTimedOut: true, providerId: entry && entry.id ? entry.id : '', label: label || '', timeoutMs: providerTimeoutMs }};
            \\  }};
            \\  const isTransientProviderStartupError = function(errorLike) {{
            \\    const message = String(errorLike && errorLike.message ? errorLike.message : errorLike || '');
            \\    return message.indexOf('Client is not running') >= 0 ||
            \\      message.indexOf('Connection is disposed') >= 0 ||
            \\      message.indexOf('Connection got disposed') >= 0 ||
            \\      message.indexOf('write EPIPE') >= 0;
            \\  }};
            \\  const pushProviderError = function(list, entry, label, errorLike) {{
            \\    list.push({{
            \\      id: entry && entry.id ? entry.id : null,
            \\      label: label || null,
            \\      message: String(errorLike && errorLike.message ? errorLike.message : errorLike),
            \\      name: String(errorLike && errorLike.name ? errorLike.name : 'Error')
            \\    }});
            \\  }};
            \\  const awaitProvider = async function(entry, label, work) {{
            \\    const startedAt = Date.now();
            \\    const retryDelayMs = providerTimeoutMs > 0
            \\      ? Math.max(75, Math.min(400, Math.floor(providerTimeoutMs / 4)))
            \\      : 150;
            \\    let attempts = 0;
            \\    while (attempts < 12) {{
            \\      attempts += 1;
            \\      const elapsedBeforeAttempt = Date.now() - startedAt;
            \\      const remainingMs = providerTimeoutMs > 0 ? Math.max(0, providerTimeoutMs - elapsedBeforeAttempt) : 0;
            \\      try {{
            \\        const promise = Promise.resolve().then(work);
            \\        const value = remainingMs > 0
            \\          ? await Promise.race([
            \\              promise,
            \\              new Promise(resolve => setTimeout(() => resolve(providerTimeoutValue(entry, label)), remainingMs))
            \\            ])
            \\          : await promise;
            \\        if (providerTimedOut(value)) {{
            \\          if (providerTimeoutMs > 0 && remainingMs > retryDelayMs) {{
            \\            await new Promise(resolve => setTimeout(resolve, retryDelayMs));
            \\            continue;
            \\          }}
            \\        }}
            \\        return value;
            \\      }} catch (error) {{
            \\        if (
            \\          isTransientProviderStartupError(error) &&
            \\          (providerTimeoutMs <= 0 || remainingMs > retryDelayMs)
            \\        ) {{
            \\          await new Promise(resolve => setTimeout(resolve, retryDelayMs));
            \\          continue;
            \\        }}
            \\        throw error;
            \\      }}
            \\    }}
            \\    return providerTimeoutValue(entry, label);
            \\  }};
            \\  const serializeUri = function(u) {{ return u && u.toString ? u.toString() : String(u || ''); }};
            \\  const serializePosition = function(pos) {{ return {{ line: pos.line ?? pos.lineNumber ?? 0, character: pos.character ?? pos.column ?? 0 }}; }};
            \\  const serializeRange = function(range) {{
            \\    if (!range) return null;
            \\    return {{ start: serializePosition(range.start), end: serializePosition(range.end) }};
            \\  }};
            \\  const pickValue = function(value, fallback) {{
            \\    return value === undefined || value === null ? fallback : value;
            \\  }};
            \\  const serializeLocation = function(loc) {{
            \\    if (!loc) return null;
            \\    return {{ uri: serializeUri(loc.uri), range: serializeRange(loc.range) }};
            \\  }};
            \\  const serializeHierarchyItem = function(item) {{
            \\    if (!item) return null;
            \\    return {{
            \\      name: item.name,
            \\      kind: item.kind === undefined ? null : item.kind,
            \\      detail: item.detail || null,
            \\      uri: serializeUri(item.uri),
            \\      range: serializeRange(item.range),
            \\      selectionRange: serializeRange(item.selectionRange)
            \\    }};
            \\  }};
            \\  const serializeWorkspaceEdit = function(edit) {{
            \\    if (!edit) return null;
            \\    const changes = {{}};
            \\    if (edit.changes) {{
            \\      for (const key of Object.keys(edit.changes)) {{
            \\        changes[key] = (edit.changes[key] || []).map(e => ({{ range: serializeRange(e.range), newText: e.newText || '' }}));
            \\      }}
            \\    }}
            \\    if (edit._entries) {{
            \\      for (const entry of edit._entries) {{
            \\        if (entry.kind !== 'edit' || !entry.uri) continue;
            \\        const key = serializeUri(entry.uri);
            \\        changes[key] = (changes[key] || []).concat((entry.edits || []).map(e => ({{ range: serializeRange(e.range), newText: e.newText || '' }})));
            \\      }}
            \\    }}
            \\    if (typeof edit.entries === 'function') {{
            \\      for (const entry of edit.entries()) {{
            \\        if (!Array.isArray(entry) || entry.length < 2) continue;
            \\        const key = serializeUri(entry[0]);
            \\        const edits = Array.isArray(entry[1]) ? entry[1] : [];
            \\        changes[key] = (changes[key] || []).concat(edits.map(e => ({{ range: serializeRange(e.range), newText: e.newText || '' }})));
            \\      }}
            \\    }}
            \\    return {{ changes }};
            \\  }};
            \\  const serializeCommand = function(command) {{
            \\    if (!command) return null;
            \\    return {{
            \\      title: command.title || null,
            \\      command: command.command || null,
            \\      arguments: Array.isArray(command.arguments) ? command.arguments : []
            \\    }};
            \\  }};
            \\  const serializeCodeActionKind = function(kind) {{
            \\    if (!kind) return null;
            \\    if (typeof kind === 'string') return kind;
            \\    if (kind.value !== undefined) return kind.value;
            \\    return String(kind);
            \\  }};
            \\  const serializeDocumentSymbol = function(symbol) {{
            \\    if (!symbol) return null;
            \\    if (symbol.location) {{
            \\      return {{
            \\        name: symbol.name,
            \\        kind: symbol.kind === undefined ? null : symbol.kind,
            \\        detail: symbol.detail || null,
            \\        containerName: symbol.containerName || null,
            \\        location: serializeLocation(symbol.location),
            \\        children: []
            \\      }};
            \\    }}
            \\    return {{
            \\      name: symbol.name,
            \\      kind: symbol.kind === undefined ? null : symbol.kind,
            \\      detail: symbol.detail || null,
            \\      range: serializeRange(symbol.range),
            \\      selectionRange: serializeRange(symbol.selectionRange),
            \\      children: (symbol.children || []).map(serializeDocumentSymbol).filter(Boolean)
            \\    }};
            \\  }};
            \\  const result = {{ providerResolution: {{ cancellationRequested: token.isCancellationRequested }} }};
            \\  const globMatches = function(pattern, fileName) {{
            \\    const pat = String(pattern || '').replace(/\\/g, '/');
            \\    const file = String(fileName || '').replace(/\\/g, '/');
            \\    if (!pat || pat === '*' || pat === '**' || pat === '**/*') return true;
            \\    if (pat.endsWith('/**/*')) {{
            \\      const root = pat.slice(0, -5);
            \\      return file === root || file.startsWith(root + '/');
            \\    }}
            \\    if (pat.endsWith('/**')) {{
            \\      const root = pat.slice(0, -3);
            \\      return file === root || file.startsWith(root + '/');
            \\    }}
            \\    if (pat.startsWith('**/*')) return file.endsWith(pat.slice(4));
            \\    if (pat.startsWith('**/')) {{
            \\      const suffix = pat.slice(3);
            \\      return file === suffix || file.endsWith('/' + suffix);
            \\    }}
            \\    if (pat.startsWith('*')) return file.endsWith(pat.slice(1));
            \\    if (pat.indexOf('*') < 0) return file === pat || file.endsWith('/' + pat);
            \\    const pieces = pat.split('*').filter(Boolean);
            \\    let offset = 0;
            \\    for (const piece of pieces) {{
            \\      const idx = file.indexOf(piece, offset);
            \\      if (idx < 0) return false;
            \\      offset = idx + piece.length;
            \\    }}
            \\    return true;
            \\  }};
            \\  const selectorScore = function(selector, doc) {{
            \\    if (!selector) return 0;
            \\    if (selector === '*') return 1;
            \\    if (typeof selector === 'string') return selector === doc.languageId ? 10 : 0;
            \\    const selectors = Array.isArray(selector) ? selector : [selector];
            \\    let best = 0;
            \\    for (const sel of selectors) {{
            \\      if (!sel) continue;
            \\      if (typeof sel === 'string') {{
            \\        if (sel === '*' || sel === doc.languageId) best = Math.max(best, sel === doc.languageId ? 10 : 1);
            \\        continue;
            \\      }}
            \\      let score = 0;
            \\      if (sel.language) {{
            \\        if (sel.language !== '*' && sel.language !== doc.languageId) continue;
            \\        score += sel.language === doc.languageId ? 10 : 1;
            \\      }}
            \\      if (sel.scheme) {{
            \\        if (sel.scheme !== '*' && sel.scheme !== doc.uri.scheme) continue;
            \\        score += sel.scheme === doc.uri.scheme ? 10 : 1;
            \\      }}
            \\      if (sel.pattern) {{
            \\        if (!globMatches(sel.pattern, doc.fileName)) continue;
            \\        score += 5;
            \\      }}
            \\      best = Math.max(best, score || 1);
            \\    }}
            \\    return best;
            \\  }};
            \\  const providerEntries = function(listName, singleName) {{
            \\    const list = globalThis[listName] || [];
            \\    if (list.length) return list
            \\      .map((entry, index) => Object.assign({{}}, entry, {{ _score: selectorScore(entry.selector, document), _order: index }}))
            \\      .filter(entry => entry._score > 0)
            \\      .sort((a, b) => b._score - a._score || a._order - b._order);
            \\    const provider = globalThis[singleName];
            \\    return provider ? [{{ id: singleName, provider, _score: 1, _order: 0 }}] : [];
            \\  }};
            \\  const matchingProviderCount = function() {{
            \\    let count = 0;
            \\    const providerLists = [
            \\      '_wizpCompletionProviders',
            \\      '_wizpHoverProviders',
            \\      '_wizpSignatureHelpProviders',
            \\      '_wizpDefinitionProviders',
            \\      '_wizpDeclarationProviders',
            \\      '_wizpTypeDefinitionProviders',
            \\      '_wizpImplementationProviders',
            \\      '_wizpReferenceProviders',
            \\      '_wizpRenameProviders',
            \\      '_wizpCodeActionProviders',
            \\      '_wizpColorProviders',
            \\      '_wizpDocumentSymbolProviders',
            \\      '_wizpSelectionRangeProviders',
            \\      '_wizpDocumentFormattingProviders',
            \\      '_wizpRangeFormattingProviders',
            \\      '_wizpOnTypeFormattingProviders',
            \\      '_wizpDocumentHighlightProviders',
            \\      '_wizpDocumentLinkProviders',
            \\      '_wizpCallHierarchyProviders',
            \\      '_wizpTypeHierarchyProviders'
            \\    ];
            \\    for (const listName of providerLists) {{
            \\      const list = globalThis[listName] || [];
            \\      for (const entry of list) {{
            \\        if (selectorScore(entry && entry.selector, document) > 0) count += 1;
            \\      }}
            \\    }}
            \\    return count;
            \\  }};
            \\  const pendingActivationEntries = function() {{
            \\    const values = Object.values(globalThis._wizpExtensions || {{}});
            \\    const pending = [];
            \\    const seen = new Set();
            \\    for (const ext of values) {{
            \\      if (!ext || !ext.id || seen.has(ext.id)) continue;
            \\      seen.add(ext.id);
            \\      if (ext.activationState !== 'pending') continue;
            \\      if (!ext.activationPromise || typeof ext.activationPromise.then !== 'function') continue;
            \\      pending.push(ext);
            \\    }}
            \\    return pending;
            \\  }};
            \\  const summarizePendingActivations = function(entries) {{
            \\    return (entries || []).map(function(ext) {{
            \\      return {{
            \\        id: ext.id || '',
            \\        isActive: !!ext.isActive,
            \\        activationState: ext.activationState || null
            \\      }};
            \\    }});
            \\  }};
            \\  const waitForProviderRegistrations = async function() {{
            \\    const before = matchingProviderCount();
            \\    const pendingBeforeEntries = pendingActivationEntries();
            \\    const pendingBefore = pendingBeforeEntries.length;
            \\    if (registrationWaitMs <= 0) {{
            \\      return {{
            \\        requestedMs: registrationWaitMs,
            \\        elapsedMs: 0,
            \\        before: before,
            \\        after: before,
            \\        pendingBefore: pendingBefore,
            \\        pendingAfter: pendingBefore,
            \\        pendingDetailsBefore: summarizePendingActivations(pendingBeforeEntries),
            \\        pendingDetailsAfter: summarizePendingActivations(pendingBeforeEntries)
            \\      }};
            \\    }}
            \\    const startedAt = Date.now();
            \\    let after = before;
            \\    let pendingAfterEntries = pendingBeforeEntries;
            \\    let pendingAfter = pendingBefore;
            \\    let lastSignature = String(before) + ':' + String(pendingBefore);
            \\    let stableSince = startedAt;
            \\    while ((Date.now() - startedAt) < registrationWaitMs) {{
            \\      await new Promise(resolve => setTimeout(resolve, 50));
            \\      after = matchingProviderCount();
            \\      pendingAfterEntries = pendingActivationEntries();
            \\      pendingAfter = pendingAfterEntries.length;
            \\      const signature = String(after) + ':' + String(pendingAfter);
            \\      if (signature !== lastSignature) {{
            \\        lastSignature = signature;
            \\        stableSince = Date.now();
            \\      }}
            \\    }}
            \\    pendingAfterEntries = pendingActivationEntries();
            \\    pendingAfter = pendingAfterEntries.length;
            \\    return {{
            \\      requestedMs: registrationWaitMs,
            \\      elapsedMs: Date.now() - startedAt,
            \\      before: before,
            \\      after: after,
            \\      pendingBefore: pendingBefore,
            \\      pendingAfter: pendingAfter,
            \\      pendingDetailsBefore: summarizePendingActivations(pendingBeforeEntries),
            \\      pendingDetailsAfter: summarizePendingActivations(pendingAfterEntries)
            \\    }};
            \\  }};
            \\  const serializeMarkdownish = function(value) {{
            \\    if (value === undefined || value === null) return null;
            \\    if (typeof value === 'string') return value;
            \\    if (Array.isArray(value)) return value.map(serializeMarkdownish);
            \\    if (value && typeof value === 'object' && typeof value.value === 'string') return value.value;
            \\    return String(value);
            \\  }};
            \\  const serializeCompletionItem = function(item) {{
            \\    const label = typeof item.label === 'string' ? item.label : ((item.label && item.label.label) || String(item.label || ''));
            \\    return {{
            \\      label: label,
            \\      kind: item.kind === undefined || item.kind === null ? globalThis._wizpContext.CompletionItemKind.Property : item.kind,
            \\      insertText: item.insertText && item.insertText.value !== undefined ? item.insertText.value : (item.insertText || label),
            \\      sortText: item.sortText === undefined || item.sortText === null ? '' : String(item.sortText),
            \\      filterText: item.filterText === undefined || item.filterText === null ? '' : String(item.filterText),
            \\      detail: item.detail === undefined || item.detail === null ? '' : String(item.detail),
            \\      documentation: serializeMarkdownish(item.documentation),
            \\      commitCharacters: item.commitCharacters || []
            \\    }};
            \\  }};
            \\  const serializeCompletionListValue = function(value) {{
            \\    const items = Array.isArray(value) ? value : ((value && value.items) || []);
            \\    const invalidCountRaw = Number(value && value._wizpInvalidCount);
            \\    return {{
            \\      isIncomplete: !!(value && value.isIncomplete),
            \\      invalidCount: Number.isFinite(invalidCountRaw) ? Math.max(0, Math.floor(invalidCountRaw)) : 0,
            \\      items: (items || []).map(serializeCompletionItem)
            \\    }};
            \\  }};
            \\  const completionLabelText = function(item) {{
            \\    return typeof item.label === 'string'
            \\      ? item.label
            \\      : ((item && item.label && item.label.label) || '');
            \\  }};
            \\  const completionSampleLabels = function(entries) {{
            \\    return (entries || []).slice(0, 12).map(function(entry) {{
            \\      return completionLabelText(entry && entry.item ? entry.item : entry);
            \\    }});
            \\  }};
            \\  const defaultCompletionRange = function() {{
            \\    const fallback = new globalThis._wizpContext.Range(position, position);
            \\    const replace = document && typeof document.getWordRangeAtPosition === 'function'
            \\      ? (document.getWordRangeAtPosition(position) || fallback)
            \\      : fallback;
            \\    const safeReplace = document && typeof document.validateRange === 'function'
            \\      ? document.validateRange(replace)
            \\      : replace;
            \\    return {{
            \\      insert: new globalThis._wizpContext.Range(safeReplace.start, position),
            \\      replace: safeReplace
            \\    }};
            \\  }};
            \\  const completionRangeParts = function(rangeValue, fallback) {{
            \\    const safeFallback = fallback || defaultCompletionRange();
            \\    const isRangeLike = function(value) {{
            \\      return !!(value && value.start && value.end);
            \\    }};
            \\    const safeRange = function(value, fallbackValue) {{
            \\      if (!isRangeLike(value)) return fallbackValue;
            \\      return document && typeof document.validateRange === 'function'
            \\        ? document.validateRange(value)
            \\        : value;
            \\    }};
            \\    if (!rangeValue) return {{
            \\      insert: safeFallback.insert,
            \\      replace: safeFallback.replace
            \\    }};
            \\    if (isRangeLike(rangeValue)) {{
            \\      const shared = safeRange(rangeValue, safeFallback.replace);
            \\      return {{
            \\        insert: shared,
            \\        replace: shared
            \\      }};
            \\    }}
            \\    const insertRange = safeRange(
            \\      rangeValue.insert !== undefined ? rangeValue.insert : rangeValue.inserting,
            \\      safeFallback.insert
            \\    );
            \\    const replaceRange = safeRange(
            \\      rangeValue.replace !== undefined ? rangeValue.replace : rangeValue.replacing,
            \\      safeFallback.replace
            \\    );
            \\    return {{
            \\      insert: insertRange,
            \\      replace: replaceRange,
            \\      inserting: insertRange,
            \\      replacing: replaceRange
            \\    }};
            \\  }};
            \\  const normalizeCompletionSuggestion = function(item) {{
            \\    const suggestion = item || {{}};
            \\    const label = completionLabelText(suggestion);
            \\    const fallback = defaultCompletionRange();
            \\    const rangeParts = completionRangeParts(suggestion.range, fallback);
            \\    if (!suggestion.range) {{
            \\      suggestion.range = {{
            \\        insert: rangeParts.insert,
            \\        replace: rangeParts.replace,
            \\        inserting: rangeParts.inserting,
            \\        replacing: rangeParts.replacing
            \\      }};
            \\    }} else if (suggestion.range && suggestion.range.start && suggestion.range.end) {{
            \\      suggestion.range = rangeParts.replace;
            \\    }} else {{
            \\      suggestion.range = {{
            \\        insert: rangeParts.insert,
            \\        replace: rangeParts.replace,
            \\        inserting: rangeParts.inserting,
            \\        replacing: rangeParts.replacing
            \\      }};
            \\    }}
            \\    if (!suggestion.sortText) suggestion.sortText = label;
            \\    return suggestion;
            \\  }};
            \\  const completionEntryIsInvalid = function(item) {{
            \\    const label = completionLabelText(item);
            \\    if (!label) return true;
            \\    const rangeValue = item && item.range;
            \\    if (!rangeValue) return false;
            \\    if (rangeValue.start && rangeValue.end) {{
            \\      return rangeValue.start.line !== position.line ||
            \\        rangeValue.end.line !== position.line;
            \\    }}
            \\    const insert = rangeValue.insert !== undefined ? rangeValue.insert : rangeValue.inserting;
            \\    const replace = rangeValue.replace !== undefined ? rangeValue.replace : rangeValue.replacing;
            \\    if (!insert || !replace) return true;
            \\    return insert.start.line !== position.line ||
            \\      replace.start.line !== position.line ||
            \\      insert.start.line !== insert.end.line ||
            \\      replace.start.line !== replace.end.line ||
            \\      insert.start.character !== replace.start.character;
            \\  }};
            \\  const makeCompletionEntry = function(item, providerEntry, container, order) {{
            \\    const suggestion = normalizeCompletionSuggestion(item);
            \\    const label = completionLabelText(suggestion);
            \\    const kind = suggestion.kind === undefined || suggestion.kind === null
            \\      ? globalThis._wizpContext.CompletionItemKind.Property
            \\      : suggestion.kind;
            \\    return {{
            \\      item: suggestion,
            \\      providerEntry: providerEntry,
            \\      container: container,
            \\      order: order,
            \\      label: label,
            \\      kind: kind,
            \\      sortTextLow: suggestion.sortText ? String(suggestion.sortText).toLowerCase() : null,
            \\      invalid: completionEntryIsInvalid(suggestion)
            \\    }};
            \\  }};
            \\  const defaultCompletionComparator = function(a, b) {{
            \\    if (a.sortTextLow && b.sortTextLow) {{
            \\      if (a.sortTextLow < b.sortTextLow) return -1;
            \\      if (a.sortTextLow > b.sortTextLow) return 1;
            \\    }}
            \\    if (a.label < b.label) return -1;
            \\    if (a.label > b.label) return 1;
            \\    return (a.kind || 0) - (b.kind || 0);
            \\  }};
            \\  const compareCompletionEntries = function(a, b) {{
            \\    const snippetKind = globalThis._wizpContext.CompletionItemKind.Snippet;
            \\    if (a.kind !== b.kind) {{
            \\      if (a.kind === snippetKind) return 1;
            \\      if (b.kind === snippetKind) return -1;
            \\    }}
            \\    return defaultCompletionComparator(a, b);
            \\  }};
            \\  try {{
            \\  const providerRegistrationWait = await waitForProviderRegistrations();
            \\  if (providerRegistrationWait.requestedMs > 0) result.providerResolution.registrationWait = providerRegistrationWait;
            \\  const collectDocumentWordCompletions = function() {{
            \\    if (document.languageId === 'java') return [];
            \\    const text = typeof document.getText === 'function' ? String(document.getText() || '') : String(p.text || '');
            \\    if (!text) return [];
            \\    const lineText = typeof p.lineText === 'string' ? String(p.lineText || '').trim() : '';
            \\    const symbolText = p.symbol ? String(p.symbol) : '';
            \\    const excludedSymbol = symbolText && (lineText.indexOf(symbolText + '(') >= 0 || lineText.startsWith(symbolText + ' ')) ? symbolText : '';
            \\    const activeLineText = typeof p.lineText === 'string'
            \\      ? String(p.lineText || '')
            \\      : String((document.lineAt(position.line) || {{ text: '' }}).text || '');
            \\    const activeCharacterRaw = Number(p && p.character);
            \\    const activeCharacter = Number.isFinite(activeCharacterRaw)
            \\      ? Math.max(0, Math.min(Math.floor(activeCharacterRaw), activeLineText.length))
            \\      : Math.max(0, Math.min(position.character || 0, activeLineText.length));
            \\    let activeWordStart = activeCharacter;
            \\    while (activeWordStart > 0 && /[A-Za-z0-9_]/.test(activeLineText.charAt(activeWordStart - 1))) activeWordStart -= 1;
            \\    let activeWordEnd = activeCharacter;
            \\    while (activeWordEnd < activeLineText.length && /[A-Za-z0-9_]/.test(activeLineText.charAt(activeWordEnd))) activeWordEnd += 1;
            \\    const activeWord = activeWordStart < activeWordEnd
            \\      ? activeLineText.slice(activeWordStart, activeWordEnd)
            \\      : '';
            \\    const items = [];
            \\    const seen = new Set();
            \\    const regex = /[A-Za-z_][A-Za-z0-9_]*/g;
            \\    let match = null;
            \\    while ((match = regex.exec(text)) !== null) {{
            \\      const word = String(match[0] || '');
            \\      if (!word) continue;
            \\      if (excludedSymbol && word === excludedSymbol) continue;
            \\      if (activeWord && word === activeWord) continue;
            \\      if (seen.has(word)) continue;
            \\      seen.add(word);
            \\      items.push({{
            \\        label: word,
            \\        kind: 0,
            \\        insertText: word,
            \\        detail: null,
            \\        documentation: null,
            \\        commitCharacters: []
            \\      }});
            \\    }}
            \\    return items;
            \\  }};
            \\  const completionProviders = providerEntries('_wizpCompletionProviders', '_wizp_completionProvider');
            \\  const completionLanguageId = String(document.languageId || '').toLowerCase();
            \\  const completionDocumentPath = String((document && (document.fileName || (document.uri && (document.uri.fsPath || document.uri.path || document.uri.toString())))) || '').replace(/\\/g, '/').toLowerCase();
            \\  const shouldInvokeCompletionCommand = completionProviders.length > 0 ||
            \\    completionLanguageId === 'go' ||
            \\    completionLanguageId === 'php' ||
            \\    completionLanguageId === 'html' ||
            \\    completionLanguageId === 'vue' ||
            \\    completionLanguageId === 'javascriptreact' ||
            \\    completionLanguageId === 'typescriptreact' ||
            \\    /\/go\.mod$/i.test(completionDocumentPath);
            \\  let completionItems = [];
            \\  const completionErrors = [];
            \\  if (shouldInvokeCompletionCommand) {{
            \\    if (completionProviders.length) result.providerResolution.completion = completionProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    const requestedResolveCountRaw = Number(p && p.itemResolveCount);
            \\    const requestedResolveCount = Number.isFinite(requestedResolveCountRaw)
            \\      ? Math.max(0, Math.floor(requestedResolveCountRaw))
            \\      : 20;
            \\    const requestedCompletionSampleCountRaw = Number(p && p.completionSampleCount);
            \\    const requestedCompletionSampleCount = Number.isFinite(requestedCompletionSampleCountRaw)
            \\      ? Math.max(1, Math.floor(requestedCompletionSampleCountRaw))
            \\      : 1;
            \\    const completionSampleDelayMsRaw = Number(p && p.completionSampleDelayMs);
            \\    const completionSampleDelayMs = Number.isFinite(completionSampleDelayMsRaw)
            \\      ? Math.max(0, Math.floor(completionSampleDelayMsRaw))
            \\      : 0;
            \\    const completionContext = p.triggerCharacter
            \\      ? {{ triggerKind: globalThis._wizpContext.CompletionTriggerKind.TriggerCharacter, triggerCharacter: p.triggerCharacter }}
            \\      : {{ triggerKind: globalThis._wizpContext.CompletionTriggerKind.Invoke }};
            \\    let latestCompletionSample = null;
            \\    let latestCompletionBuiltinSources = [];
            \\    const completionSamples = [];
            \\    for (let sampleIndex = 0; sampleIndex < requestedCompletionSampleCount; sampleIndex += 1) {{
            \\      let rawCompletion = null;
            \\      try {{
            \\        rawCompletion = await awaitProvider({{ id: 'vscode.executeCompletionItemProvider' }}, 'completion', async function() {{
            \\          const previousProviderOverrideToken = globalThis._wizpProviderOverrideToken;
            \\          globalThis._wizpProviderOverrideToken = token;
            \\          try {{
            \\            return await globalThis._wizpContext.commands.executeCommand(
            \\              'vscode.executeCompletionItemProvider',
            \\              document.uri,
            \\              position,
            \\              p.triggerCharacter || undefined,
            \\              requestedResolveCount
            \\            );
            \\          }} finally {{
            \\            globalThis._wizpProviderOverrideToken = previousProviderOverrideToken;
            \\          }}
            \\        }});
            \\        if (providerTimedOut(rawCompletion)) {{
            \\          pushProviderError(completionErrors, {{ id: 'vscode.executeCompletionItemProvider' }}, 'completion', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          rawCompletion = null;
            \\        }}
            \\      }} catch (error) {{
            \\        pushProviderError(completionErrors, {{ id: 'vscode.executeCompletionItemProvider' }}, 'completion', error);
            \\        rawCompletion = null;
            \\      }}
            \\      latestCompletionBuiltinSources = rawCompletion && Array.isArray(rawCompletion._wizpBuiltinSources)
            \\        ? rawCompletion._wizpBuiltinSources.slice()
            \\        : [];
            \\      latestCompletionSample = serializeCompletionListValue(rawCompletion);
            \\      completionSamples.push({{
            \\        sampleIndex: sampleIndex + 1,
            \\        itemCount: latestCompletionSample && Array.isArray(latestCompletionSample.items) ? latestCompletionSample.items.length : 0,
            \\        invalidCount: latestCompletionSample && Number.isFinite(Number(latestCompletionSample.invalidCount))
            \\          ? Math.max(0, Math.floor(Number(latestCompletionSample.invalidCount)))
            \\          : 0,
            \\        isIncomplete: !!(latestCompletionSample && latestCompletionSample.isIncomplete),
            \\        labels: completionSampleLabels(latestCompletionSample && Array.isArray(latestCompletionSample.items) ? latestCompletionSample.items : [])
            \\      }});
            \\      if (!latestCompletionSample || !latestCompletionSample.isIncomplete) break;
            \\      if (completionSampleDelayMs > 0 && sampleIndex + 1 < requestedCompletionSampleCount) {{
            \\        await new Promise(resolve => setTimeout(resolve, completionSampleDelayMs));
            \\      }}
            \\    }}
            \\    if (completionSamples.length > 1) result.providerResolution.completionSamples = completionSamples;
            \\    if (latestCompletionBuiltinSources.length) result.providerResolution.completionBuiltinSources = latestCompletionBuiltinSources;
            \\    if (latestCompletionSample) result.providerResolution.completionIsIncomplete = !!latestCompletionSample.isIncomplete;
            \\    if (latestCompletionSample && Number.isFinite(Number(latestCompletionSample.invalidCount))) {{
            \\      result.providerResolution.completionInvalidCount = Math.max(0, Math.floor(Number(latestCompletionSample.invalidCount)));
            \\    }}
            \\    completionItems = latestCompletionSample && Array.isArray(latestCompletionSample.items)
            \\      ? latestCompletionSample.items
            \\      : [];
            \\  }}
            \\  if (!completionItems.length && !completionProviders.length) {{
            \\    completionItems = collectDocumentWordCompletions();
            \\    if (completionItems.length) result.providerResolution.completionFallback = 'documentWords';
            \\  }}
            \\  if (completionErrors.length) result.providerResolution.completionErrors = completionErrors;
            \\  if (completionProviders.length || completionItems.length) {{
            \\    result.completion = {{
            \\      isIncomplete: !!result.providerResolution.completionIsIncomplete,
            \\      items: completionItems.map(serializeCompletionItem)
            \\    }};
            \\  }}
            \\  const hoverProviders = providerEntries('_wizpHoverProviders', '_wizp_hoverProvider');
            \\  if (hoverProviders.length) {{
            \\    result.providerResolution.hover = hoverProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    result.hover = null;
            \\    const hoverErrors = [];
            \\    for (const entry of hoverProviders) {{
            \\      try {{
            \\        const hover = await awaitProvider(entry, 'hover', function() {{ return entry.provider.provideHover(document, position, token); }});
            \\        if (providerTimedOut(hover)) {{
            \\          pushProviderError(hoverErrors, entry, 'hover', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        if (!hover) continue;
            \\        result.hover = {{
            \\        contents: (hover.contents || []).map(c => typeof c === 'string' ? c : (c && c.value) || String(c)),
            \\        range: serializeRange(hover.range)
            \\        }};
            \\        break;
            \\      }} catch (error) {{
            \\        pushProviderError(hoverErrors, entry, 'hover', error);
            \\      }}
            \\    }}
            \\    if (hoverErrors.length) result.providerResolution.hoverErrors = hoverErrors;
            \\  }}
            \\  const signatureProviders = providerEntries('_wizpSignatureHelpProviders', '_wizp_signatureHelpProvider');
            \\  if (signatureProviders.length) {{
            \\    result.providerResolution.signatureHelp = signatureProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    const signatureHelpErrors = [];
            \\    try {{
            \\      const help = await awaitProvider(signatureProviders[0], 'signatureHelp', function() {{
            \\        return signatureProviders[0].provider.provideSignatureHelp(document, position, token, {{
            \\          triggerKind: globalThis._wizpContext.SignatureHelpTriggerKind.TriggerCharacter,
            \\          triggerCharacter: '('
            \\        }});
            \\      }});
            \\      if (providerTimedOut(help)) {{
            \\        pushProviderError(signatureHelpErrors, signatureProviders[0], 'signatureHelp', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\        result.signatureHelp = null;
            \\      }} else {{
            \\        result.signatureHelp = help ? {{
            \\          activeSignature: help.activeSignature || 0,
            \\          activeParameter: help.activeParameter || 0,
            \\          signatures: (help.signatures || []).map(sig => ({{
            \\            label: sig.label,
            \\            documentation: sig.documentation || null,
            \\            parameters: (sig.parameters || []).map(param => ({{ label: param.label, documentation: param.documentation || null }}))
            \\          }}))
            \\        }} : null;
            \\      }}
            \\    }} catch (error) {{
            \\      pushProviderError(signatureHelpErrors, signatureProviders[0], 'signatureHelp', error);
            \\      result.signatureHelp = null;
            \\    }}
            \\    if (signatureHelpErrors.length) result.providerResolution.signatureHelpErrors = signatureHelpErrors;
            \\  }}
            \\  const definitionProviders = providerEntries('_wizpDefinitionProviders', '_wizp_definitionProvider');
            \\  if (definitionProviders.length) {{
            \\    result.providerResolution.definition = definitionProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    result.definition = [];
            \\    const definitionErrors = [];
            \\    for (const entry of definitionProviders) {{
            \\      const defs = await awaitProvider(entry, 'definition', function() {{ return entry.provider.provideDefinition(document, position, token); }});
            \\      if (providerTimedOut(defs)) {{
            \\        pushProviderError(definitionErrors, entry, 'definition', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\        continue;
            \\      }}
            \\      for (const def of (Array.isArray(defs) ? defs : (defs ? [defs] : []))) result.definition.push(serializeLocation(def));
            \\    }}
            \\    if (definitionErrors.length) result.providerResolution.definitionErrors = definitionErrors;
            \\  }}
            \\  const declarationProviders = providerEntries('_wizpDeclarationProviders', '_wizp_declarationProvider');
            \\  if (declarationProviders.length) {{
            \\    result.providerResolution.declaration = declarationProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    result.declaration = [];
            \\    const declarationErrors = [];
            \\    for (const entry of declarationProviders) {{
            \\      try {{
            \\        const decls = await awaitProvider(entry, 'declaration', function() {{ return entry.provider.provideDeclaration(document, position, token); }});
            \\        if (providerTimedOut(decls)) {{
            \\          pushProviderError(declarationErrors, entry, 'declaration', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        for (const decl of (Array.isArray(decls) ? decls : (decls ? [decls] : []))) result.declaration.push(serializeLocation(decl));
            \\      }} catch (error) {{
            \\        pushProviderError(declarationErrors, entry, 'declaration', error);
            \\      }}
            \\    }}
            \\    if (declarationErrors.length) result.providerResolution.declarationErrors = declarationErrors;
            \\  }}
            \\  const typeDefinitionProviders = providerEntries('_wizpTypeDefinitionProviders', '_wizp_typeDefinitionProvider');
            \\  if (typeDefinitionProviders.length) {{
            \\    result.providerResolution.typeDefinition = typeDefinitionProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    result.typeDefinition = [];
            \\    const typeDefinitionErrors = [];
            \\    for (const entry of typeDefinitionProviders) {{
            \\      try {{
            \\        const defs = await awaitProvider(entry, 'typeDefinition', function() {{ return entry.provider.provideTypeDefinition(document, position, token); }});
            \\        if (providerTimedOut(defs)) {{
            \\          pushProviderError(typeDefinitionErrors, entry, 'typeDefinition', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        for (const def of (Array.isArray(defs) ? defs : (defs ? [defs] : []))) result.typeDefinition.push(serializeLocation(def));
            \\      }} catch (error) {{
            \\        pushProviderError(typeDefinitionErrors, entry, 'typeDefinition', error);
            \\      }}
            \\    }}
            \\    if (typeDefinitionErrors.length) result.providerResolution.typeDefinitionErrors = typeDefinitionErrors;
            \\  }}
            \\  const implementationProviders = providerEntries('_wizpImplementationProviders', '_wizp_implementationProvider');
            \\  if (implementationProviders.length) {{
            \\    result.providerResolution.implementation = implementationProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    result.implementation = [];
            \\    const implementationErrors = [];
            \\    for (const entry of implementationProviders) {{
            \\      try {{
            \\        const impls = await awaitProvider(entry, 'implementation', function() {{ return entry.provider.provideImplementation(document, position, token); }});
            \\        if (providerTimedOut(impls)) {{
            \\          pushProviderError(implementationErrors, entry, 'implementation', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        for (const impl of (Array.isArray(impls) ? impls : (impls ? [impls] : []))) result.implementation.push(serializeLocation(impl));
            \\      }} catch (error) {{
            \\        pushProviderError(implementationErrors, entry, 'implementation', error);
            \\      }}
            \\    }}
            \\    if (implementationErrors.length) result.providerResolution.implementationErrors = implementationErrors;
            \\  }}
            \\  const referenceProviders = providerEntries('_wizpReferenceProviders', '_wizp_referenceProvider');
            \\  if (referenceProviders.length) {{
            \\    result.providerResolution.references = referenceProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    result.references = [];
            \\    const referenceErrors = [];
            \\    for (const entry of referenceProviders) {{
            \\      const refs = await awaitProvider(entry, 'references', function() {{
            \\        return entry.provider.provideReferences(document, position, {{ includeDeclaration: true }}, token);
            \\      }});
            \\      if (providerTimedOut(refs)) {{
            \\        pushProviderError(referenceErrors, entry, 'references', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\        continue;
            \\      }}
            \\      for (const ref of (refs || [])) result.references.push(serializeLocation(ref));
            \\    }}
            \\    if (referenceErrors.length) result.providerResolution.referenceErrors = referenceErrors;
            \\  }}
            \\  const renameProviders = providerEntries('_wizpRenameProviders', '_wizp_renameProvider');
            \\  if (renameProviders.length) {{
            \\    result.providerResolution.rename = renameProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    const renameProvider = renameProviders[0].provider;
            \\    const renameErrors = [];
            \\    try {{
            \\      if (renameProvider.prepareRename) {{
            \\        const prepared = await awaitProvider(renameProviders[0], 'prepareRename', function() {{ return renameProvider.prepareRename(document, position, token); }});
            \\        if (providerTimedOut(prepared)) {{
            \\          pushProviderError(renameErrors, renameProviders[0], 'prepareRename', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\        }} else {{
            \\          const preparedRange = prepared && prepared.range ? prepared.range : ((prepared && prepared.start && prepared.end) ? prepared : null);
            \\          if (preparedRange) {{
            \\            const placeholder = prepared && prepared.placeholder !== undefined
            \\              ? (prepared.placeholder || null)
            \\              : (typeof document.getText === 'function' ? document.getText(preparedRange) : null);
            \\            result.prepareRename = {{ range: serializeRange(preparedRange), placeholder: placeholder }};
            \\          }} else {{
            \\            result.prepareRename = prepared == null ? null : prepared;
            \\          }}
            \\        }}
            \\      }}
            \\      const edit = await awaitProvider(renameProviders[0], 'rename', function() {{
            \\        return renameProvider.provideRenameEdits(document, position, p.newName || 'RenamedSymbol', token);
            \\      }});
            \\      if (providerTimedOut(edit)) {{
            \\        pushProviderError(renameErrors, renameProviders[0], 'rename', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\        result.rename = null;
            \\      }} else {{
            \\        result.rename = serializeWorkspaceEdit(edit);
            \\      }}
            \\    }} catch (error) {{
            \\      pushProviderError(renameErrors, renameProviders[0], 'rename', error);
            \\      result.rename = null;
            \\    }}
            \\    if (renameErrors.length) result.providerResolution.renameErrors = renameErrors;
            \\  }}
            \\  const codeActionProviders = providerEntries('_wizpCodeActionProviders', '_wizp_codeActionProvider');
            \\  if (codeActionProviders.length) {{
            \\    result.providerResolution.codeActions = codeActionProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    const range = new globalThis._wizpContext.Range(
            \\      new globalThis._wizpContext.Position(pickValue(p.rangeStartLine, line), pickValue(p.rangeStartCharacter, character)),
            \\      new globalThis._wizpContext.Position(pickValue(p.rangeEndLine, line), pickValue(p.rangeEndCharacter, character))
            \\    );
            \\    const allActions = [];
            \\    const codeActionErrors = [];
            \\    for (const entry of codeActionProviders) {{
            \\      const actions = await awaitProvider(entry, 'codeActions', function() {{
            \\        return entry.provider.provideCodeActions(document, range, {{ diagnostics: [], triggerKind: 1 }}, token);
            \\      }});
            \\      if (providerTimedOut(actions)) {{
            \\        pushProviderError(codeActionErrors, entry, 'codeActions', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\        continue;
            \\      }}
            \\      for (const action of (actions || [])) {{
            \\        let resolved = action;
            \\        if (entry.provider.resolveCodeAction) {{
            \\          const maybeResolved = await awaitProvider(entry, 'codeActionResolve', function() {{ return entry.provider.resolveCodeAction(action, token); }});
            \\          if (providerTimedOut(maybeResolved)) pushProviderError(codeActionErrors, entry, 'codeActionResolve', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          else resolved = maybeResolved || action;
            \\        }}
            \\        allActions.push(resolved || action);
            \\      }}
            \\    }}
            \\    if (codeActionErrors.length) result.providerResolution.codeActionErrors = codeActionErrors;
            \\    result.codeActions = allActions.map(action => ({{
            \\      title: action.title,
            \\      kind: serializeCodeActionKind(action.kind),
            \\      isPreferred: !!action.isPreferred,
            \\      command: serializeCommand(action.command),
            \\      edit: serializeWorkspaceEdit(action.edit)
            \\    }}));
            \\  }}
            \\  const formatEdit = function(edit) {{ return {{ range: serializeRange(edit.range), newText: edit.newText || '' }}; }};
            \\  const colorProviders = providerEntries('_wizpColorProviders', '_wizp_colorProvider');
            \\  if (colorProviders.length) {{
            \\    result.providerResolution.colors = colorProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    result.colors = [];
            \\    const colorErrors = [];
            \\    for (const entry of colorProviders) {{
            \\      try {{
            \\        const colors = await Promise.resolve(entry.provider.provideDocumentColors(document, token));
            \\        for (const colorInfo of (colors || [])) {{
            \\          const color = colorInfo.color || {{}};
            \\          result.colors.push({{
            \\            providerId: entry.id,
            \\            range: serializeRange(colorInfo.range),
            \\            color: {{ red: color.red || 0, green: color.green || 0, blue: color.blue || 0, alpha: color.alpha === undefined ? 1 : color.alpha }}
            \\          }});
            \\        }}
            \\      }} catch (error) {{
            \\        colorErrors.push({{ id: entry.id, message: String(error && error.message ? error.message : error), name: String(error && error.name ? error.name : 'Error') }});
            \\      }}
            \\    }}
            \\    if (colorErrors.length) result.providerResolution.colorErrors = colorErrors;
            \\  }}
            \\  if ((globalThis._wizpDocumentHighlightProviders || []).length) {{
            \\    result.documentHighlights = [];
            \\    const documentHighlightErrors = [];
            \\    for (const entry of globalThis._wizpDocumentHighlightProviders) {{
            \\      try {{
            \\        const highlights = await awaitProvider(entry, 'documentHighlights', function() {{
            \\          return entry.provider.provideDocumentHighlights(document, position, token);
            \\        }});
            \\        if (providerTimedOut(highlights)) {{
            \\          pushProviderError(documentHighlightErrors, entry, 'documentHighlights', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        for (const highlight of (highlights || [])) {{
            \\          result.documentHighlights.push({{ providerId: entry.id, range: serializeRange(highlight.range), kind: highlight.kind === undefined ? null : highlight.kind }});
            \\        }}
            \\      }} catch (error) {{
            \\        pushProviderError(documentHighlightErrors, entry, 'documentHighlights', error);
            \\      }}
            \\    }}
            \\    if (documentHighlightErrors.length) result.providerResolution.documentHighlightErrors = documentHighlightErrors;
            \\  }}
            \\  if ((globalThis._wizpDocumentLinkProviders || []).length) {{
            \\    result.documentLinks = [];
            \\    const documentLinkErrors = [];
            \\    for (const entry of globalThis._wizpDocumentLinkProviders) {{
            \\      try {{
            \\        const links = await awaitProvider(entry, 'documentLinks', function() {{ return entry.provider.provideDocumentLinks(document, token); }});
            \\        if (providerTimedOut(links)) {{
            \\          pushProviderError(documentLinkErrors, entry, 'documentLinks', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        for (const link of (links || [])) {{
            \\          let resolved = link;
            \\          if (!resolved.target && entry.provider.resolveDocumentLink) {{
            \\            const maybeResolved = await awaitProvider(entry, 'documentLinkResolve', function() {{ return entry.provider.resolveDocumentLink(link, token); }});
            \\            if (providerTimedOut(maybeResolved)) {{
            \\              pushProviderError(documentLinkErrors, entry, 'documentLinkResolve', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\            }} else {{
            \\              resolved = maybeResolved || link;
            \\            }}
            \\          }}
            \\          result.documentLinks.push({{ providerId: entry.id, range: serializeRange(resolved.range), target: resolved.target ? serializeUri(resolved.target) : null, tooltip: resolved.tooltip || null }});
            \\        }}
            \\      }} catch (error) {{
            \\        pushProviderError(documentLinkErrors, entry, 'documentLinks', error);
            \\      }}
            \\    }}
            \\    if (documentLinkErrors.length) result.providerResolution.documentLinkErrors = documentLinkErrors;
            \\  }}
            \\  const documentSymbolProviders = providerEntries('_wizpDocumentSymbolProviders', '_wizp_documentSymbolProvider');
            \\  if (documentSymbolProviders.length) {{
            \\    result.documentSymbols = [];
            \\    result.providerResolution.documentSymbols = documentSymbolProviders.map(entry => ({{ id: entry.id, score: entry._score, order: entry._order }}));
            \\    const documentSymbolErrors = [];
            \\    for (const entry of documentSymbolProviders) {{
            \\      try {{
            \\        const symbols = await awaitProvider(entry, 'documentSymbols', function() {{ return entry.provider.provideDocumentSymbols(document, token); }});
            \\        if (providerTimedOut(symbols)) {{
            \\          pushProviderError(documentSymbolErrors, entry, 'documentSymbols', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        for (const symbol of (symbols || [])) result.documentSymbols.push(serializeDocumentSymbol(symbol));
            \\      }} catch (error) {{
            \\        pushProviderError(documentSymbolErrors, entry, 'documentSymbols', error);
            \\      }}
            \\    }}
            \\    if (documentSymbolErrors.length) result.providerResolution.documentSymbolErrors = documentSymbolErrors;
            \\  }}
            \\  const documentFormattingEdits = [];
            \\  if ((globalThis._wizpDocumentFormattingProviders || []).length) {{
            \\    result.providerResolution.documentFormatting = (globalThis._wizpDocumentFormattingProviders || []).map(entry => ({{ id: entry.id, score: selectorScore(entry.selector, document), selector: entry.selector }}));
            \\    const documentFormattingErrors = [];
            \\    for (const entry of globalThis._wizpDocumentFormattingProviders) {{
            \\      try {{
            \\        const edits = await awaitProvider(entry, 'documentFormatting', function() {{
            \\          return entry.provider.provideDocumentFormattingEdits(document, p.options || {{ tabSize: 2, insertSpaces: true }}, token);
            \\        }});
            \\        if (providerTimedOut(edits)) {{
            \\          pushProviderError(documentFormattingErrors, entry, 'documentFormatting', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        for (const edit of (edits || [])) documentFormattingEdits.push(formatEdit(edit));
            \\      }} catch (error) {{
            \\        pushProviderError(documentFormattingErrors, entry, 'documentFormatting', error);
            \\      }}
            \\    }}
            \\    if (documentFormattingErrors.length) result.providerResolution.documentFormattingErrors = documentFormattingErrors;
            \\  }}
            \\  result.documentFormatting = documentFormattingEdits;
            \\  result.documentFormattingAppliedText = globalThis._wizpContext.workspace._applyTextEdits(document.getText(), documentFormattingEdits);
            \\  if ((globalThis._wizpRangeFormattingProviders || []).length) {{
            \\    result.rangeFormatting = [];
            \\    result.providerResolution.rangeFormatting = (globalThis._wizpRangeFormattingProviders || []).map(entry => ({{ id: entry.id, score: selectorScore(entry.selector, document), selector: entry.selector }}));
            \\    const range = new globalThis._wizpContext.Range(
            \\      new globalThis._wizpContext.Position(pickValue(p.rangeStartLine, 0), pickValue(p.rangeStartCharacter, 0)),
            \\      new globalThis._wizpContext.Position(pickValue(p.rangeEndLine, 0), pickValue(p.rangeEndCharacter, 0))
            \\    );
            \\    const rangeFormattingErrors = [];
            \\    for (const entry of globalThis._wizpRangeFormattingProviders) {{
            \\      try {{
            \\        const edits = await awaitProvider(entry, 'rangeFormatting', function() {{
            \\          return entry.provider.provideDocumentRangeFormattingEdits(document, range, p.options || {{ tabSize: 2, insertSpaces: true }}, token);
            \\        }});
            \\        if (providerTimedOut(edits)) {{
            \\          pushProviderError(rangeFormattingErrors, entry, 'rangeFormatting', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        for (const edit of (edits || [])) result.rangeFormatting.push(formatEdit(edit));
            \\      }} catch (error) {{
            \\        pushProviderError(rangeFormattingErrors, entry, 'rangeFormatting', error);
            \\      }}
            \\    }}
            \\    if (rangeFormattingErrors.length) result.providerResolution.rangeFormattingErrors = rangeFormattingErrors;
            \\  }}
            \\  if ((globalThis._wizpOnTypeFormattingProviders || []).length) {{
            \\    result.onTypeFormatting = [];
            \\    const onTypeFormattingErrors = [];
            \\    for (const entry of globalThis._wizpOnTypeFormattingProviders) {{
            \\      try {{
            \\        const edits = await awaitProvider(entry, 'onTypeFormatting', function() {{
            \\          return entry.provider.provideOnTypeFormattingEdits(document, requestedPosition, p.ch || entry.firstTriggerCharacter || ';', p.options || {{ tabSize: 2, insertSpaces: true }}, token);
            \\        }});
            \\        if (providerTimedOut(edits)) {{
            \\          pushProviderError(onTypeFormattingErrors, entry, 'onTypeFormatting', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        for (const edit of (edits || [])) result.onTypeFormatting.push(formatEdit(edit));
            \\      }} catch (error) {{
            \\        pushProviderError(onTypeFormattingErrors, entry, 'onTypeFormatting', error);
            \\      }}
            \\    }}
            \\    if (onTypeFormattingErrors.length) result.providerResolution.onTypeFormattingErrors = onTypeFormattingErrors;
            \\  }}
            \\  if ((globalThis._wizpCallHierarchyProviders || []).length) {{
            \\    result.callHierarchy = [];
            \\    const callHierarchyErrors = [];
            \\    for (const entry of globalThis._wizpCallHierarchyProviders) {{
            \\      try {{
            \\        const preparedRaw = await awaitProvider(entry, 'callHierarchyPrepare', function() {{
            \\          return entry.provider.prepareCallHierarchy(document, position, token);
            \\        }});
            \\        if (providerTimedOut(preparedRaw)) {{
            \\          pushProviderError(callHierarchyErrors, entry, 'callHierarchyPrepare', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        const preparedItems = Array.isArray(preparedRaw) ? preparedRaw : (preparedRaw ? [preparedRaw] : []);
            \\        for (const item of preparedItems) {{
            \\          const incomingRaw = entry.provider.provideCallHierarchyIncomingCalls ? await awaitProvider(entry, 'callHierarchyIncoming', function() {{ return entry.provider.provideCallHierarchyIncomingCalls(item, token); }}) : [];
            \\          const outgoingRaw = entry.provider.provideCallHierarchyOutgoingCalls ? await awaitProvider(entry, 'callHierarchyOutgoing', function() {{ return entry.provider.provideCallHierarchyOutgoingCalls(item, token); }}) : [];
            \\          result.callHierarchy.push({{
            \\            providerId: entry.id,
            \\            item: serializeHierarchyItem(item),
            \\            incoming: (providerTimedOut(incomingRaw) ? [] : (incomingRaw || [])).map(call => ({{
            \\              from: serializeHierarchyItem(call.from),
            \\              fromRanges: (call.fromRanges || []).map(serializeRange)
            \\            }})),
            \\            outgoing: (providerTimedOut(outgoingRaw) ? [] : (outgoingRaw || [])).map(call => ({{
            \\              to: serializeHierarchyItem(call.to),
            \\              fromRanges: (call.fromRanges || []).map(serializeRange)
            \\            }}))
            \\          }});
            \\        }}
            \\      }} catch (error) {{
            \\        pushProviderError(callHierarchyErrors, entry, 'callHierarchy', error);
            \\      }}
            \\    }}
            \\    if (callHierarchyErrors.length) result.providerResolution.callHierarchyErrors = callHierarchyErrors;
            \\  }}
            \\  if ((globalThis._wizpTypeHierarchyProviders || []).length) {{
            \\    result.typeHierarchy = [];
            \\    const typeHierarchyErrors = [];
            \\    for (const entry of globalThis._wizpTypeHierarchyProviders) {{
            \\      try {{
            \\        const preparedRaw = await awaitProvider(entry, 'typeHierarchyPrepare', function() {{
            \\          return entry.provider.prepareTypeHierarchy(document, position, token);
            \\        }});
            \\        if (providerTimedOut(preparedRaw)) {{
            \\          pushProviderError(typeHierarchyErrors, entry, 'typeHierarchyPrepare', {{ message: 'timed out', name: 'ProviderTimeout' }});
            \\          continue;
            \\        }}
            \\        const preparedItems = Array.isArray(preparedRaw) ? preparedRaw : (preparedRaw ? [preparedRaw] : []);
            \\        for (const item of preparedItems) {{
            \\          const supertypes = entry.provider.provideTypeHierarchySupertypes ? await awaitProvider(entry, 'typeHierarchySupertypes', function() {{ return entry.provider.provideTypeHierarchySupertypes(item, token); }}) : [];
            \\          const subtypes = entry.provider.provideTypeHierarchySubtypes ? await awaitProvider(entry, 'typeHierarchySubtypes', function() {{ return entry.provider.provideTypeHierarchySubtypes(item, token); }}) : [];
            \\          result.typeHierarchy.push({{
            \\            providerId: entry.id,
            \\            item: serializeHierarchyItem(item),
            \\            supertypes: (providerTimedOut(supertypes) ? [] : (supertypes || [])).map(serializeHierarchyItem),
            \\            subtypes: (providerTimedOut(subtypes) ? [] : (subtypes || [])).map(serializeHierarchyItem)
            \\          }});
            \\        }}
            \\      }} catch (error) {{
            \\        pushProviderError(typeHierarchyErrors, entry, 'typeHierarchy', error);
            \\      }}
            \\    }}
            \\    if (typeHierarchyErrors.length) result.providerResolution.typeHierarchyErrors = typeHierarchyErrors;
            \\  }}
            \\  return result;
            \\  }} catch (error) {{
            \\    result.providerResolution.topLevelError = {{
            \\      message: String(error && error.message ? error.message : error),
            \\      name: String(error && error.name ? error.name : 'Error'),
            \\      stack: String(error && error.stack ? error.stack : '')
            \\    }};
            \\    return result;
            \\  }}
            \\}})()
        , .{body});
        defer self.allocator.free(js);
        const engine_result = try self.engine.evalString(js, "languageProviders");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{}" else raw;
        const final_result_json = if (activation_error_json.len == 0 or result_json.len == 0 or result_json[result_json.len - 1] != '}')
            result_json
        else
            try std.fmt.allocPrint(self.allocator, "{s}{s}}}", .{ result_json[0 .. result_json.len - 1], activation_error_json });
        defer if (final_result_json.ptr != result_json.ptr) self.allocator.free(final_result_json);
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, final_result_json });
    }

    pub fn executeCommandRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const command = extractJSONString(body, "\"command\"") orelse return try jsonRpcError(self.allocator, id_str, -32602, "extension/execute requires command");
        const allow_disabled = std.mem.indexOf(u8, body, "\"allowDisabled\":true") != null;

        if (std.mem.eql(u8, command, "workbench.extensions.disableExtension")) {
            const extension_id = extractFirstJsonStringArrayItem(body, "\"args\"") orelse return try jsonRpcError(self.allocator, id_str, -32602, "disableExtension requires extension id argument");
            const extension = self.findExtension(extension_id);
            const already_disabled = if (extension) |ext| self.isExtensionDisabled(ext) else self.disabled_extensions.contains(extension_id);
            if (!already_disabled) {
                const owned = try self.allocator.dupe(u8, extension_id);
                try self.disabled_extensions.put(self.allocator, owned, {});
            }
            const activated_id = if (extension) |ext| ext.id else extension_id;
            if (self.activated.contains(activated_id)) {
                if (self.deactivateExtension(activated_id)) |result_json| {
                    self.allocator.free(result_json);
                } else |_| {}
            }
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"disabled\":true,\"extensionId\":", .{id_str});
            try writeJsonString(w, extension_id);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, command, "workbench.extensions.enableExtension")) {
            const extension_id = extractFirstJsonStringArrayItem(body, "\"args\"") orelse return try jsonRpcError(self.allocator, id_str, -32602, "enableExtension requires extension id argument");
            const disabled_key = if (self.findExtension(extension_id)) |ext| self.disabledExtensionKey(ext.publisher, ext.id) else extension_id;
            if (disabled_key) |key| {
                if (self.disabled_extensions.fetchSwapRemove(key)) |kv| self.allocator.free(kv.key);
            }
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"enabled\":true,\"extensionId\":", .{id_str});
            try writeJsonString(w, extension_id);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, command, "setContext")) {
            try self.setContextFromRpcBody(body);
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        try self.setViewVisibleContextForFocusCommand(command);

        if (!allow_disabled) {
            if (self.commandEnablement(command)) |enabled| {
                if (!enabled) return try jsonRpcError(self.allocator, id_str, -32000, "command is disabled by enablement context");
            }
        }

        if (self.extensionOwningCommand(command)) |owner| {
            if (self.isExtensionDisabled(owner)) {
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
            }
        }

        const event = try std.fmt.allocPrint(self.allocator, "command:{s}", .{command});
        defer self.allocator.free(event);
        self.activateByEvent(event) catch |err| {
            return try jsonRpcError(self.allocator, id_str, -32001, @errorName(err));
        };

        const js = try std.fmt.allocPrint(self.allocator,
            \\(function() {{
            \\  let req = {s};
            \\  let p = req.params || {{}};
            \\  let commandId = p.command || req.command;
            \\  let reviveArg = function(value) {{
            \\    if (Array.isArray(value)) return value.map(reviveArg);
            \\    if (!value || typeof value !== 'object') return value;
            \\    if (value.__wizpType === 'uriFile') return globalThis._wizpContext.Uri.file(String(value.path || ''));
            \\    let out = {{}};
            \\    for (const key of Object.keys(value)) out[key] = reviveArg(value[key]);
            \\    return out;
            \\  }};
            \\  let rawArgs = (p.args || req.args) || [];
            \\  let args = Array.isArray(rawArgs) ? rawArgs.map(reviveArg) : [];
            \\  let run = function() {{ return Promise.resolve(globalThis._wizpContext.commands.executeCommand(commandId, ...args)); }};
            \\  if (p.detached || req.detached) {{
            \\    globalThis._wizpCommandResults = globalThis._wizpCommandResults || {{}};
            \\    let callId = 'cmd_' + Date.now() + '_' + Math.floor(Math.random() * 1000000);
            \\    setTimeout(() => {{
            \\      run().then(
            \\        value => {{ globalThis._wizpCommandResults[callId] = {{ command: commandId, status: 'resolved', value: value === undefined ? null : value }}; }},
            \\        error => {{ globalThis._wizpCommandResults[callId] = {{ command: commandId, status: 'rejected', message: String(error && error.message ? error.message : error), name: String(error && error.name ? error.name : 'Error') }}; }}
            \\      );
            \\    }}, 0);
            \\    return {{ detached: true, id: callId, command: commandId }};
            \\  }}
            \\  let timeoutMs = Number(p.timeoutMs || req.timeoutMs || 0);
            \\  let commandPromise = run();
            \\  return timeoutMs > 0
            \\    ? Promise.race([
            \\        commandPromise,
            \\        new Promise(resolve => setTimeout(() => resolve({{ __wizpTimedOut: true, command: commandId, timeoutMs: timeoutMs }}), timeoutMs))
            \\      ])
            \\    : commandPromise;
            \\}})()
        , .{body});
        defer self.allocator.free(js);

        const engine_result = try self.engine.evalString(js, "executeCommand");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "null" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn activationErrorsRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const js =
            \\(function() {
            \\  const errors = Object.keys(globalThis._wizpActivationErrors || {}).map(function(id) {
            \\    const entry = globalThis._wizpActivationErrors[id];
            \\    if (typeof entry === 'string') return { id: id, message: entry };
            \\    return { id: id, message: String(entry && entry.message ? entry.message : ''), name: String(entry && entry.name ? entry.name : ''), stack: String(entry && entry.stack ? entry.stack : '') };
            \\  });
            \\  return { errors: errors, count: errors.length };
            \\})()
        ;
        const engine_result = self.engine.evalStringTimeoutMs(js, self.diagnosticRpcTimeoutMs()) catch |err| {
            if (err == error.Timeout) {
                _ = self.restartHost() catch {};
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"errors\":[],\"count\":0,\"rpcTimeout\":true}}}}", .{id_str});
            }
            return err;
        };
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"errors\":[],\"count\":0}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn commandResultsRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const js =
            \\(function() {
            \\  return {
            \\    results: globalThis._wizpCommandResults || {},
            \\    count: Object.keys(globalThis._wizpCommandResults || {}).length
            \\  };
            \\})()
        ;
        const engine_result = try self.engine.evalString(js, "commandResults");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"results\":{},\"count\":0}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn runtimeProcessesRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const js =
            \\(function() {
            \\  const forked = (globalThis._wizpForkedProcesses || []).map(function(proc) {
            \\    return {
            \\      pid: proc.pid || 0,
            \\      modulePath: String(proc.modulePath || ''),
            \\      args: Array.isArray(proc.args) ? proc.args.map(String) : [],
            \\      ipcShim: !!proc.ipcShim,
            \\      native: !!proc.native
            \\    };
            \\  });
            \\  const spawned = (globalThis._wizpSpawnedProcesses || []).map(function(proc) {
            \\    return {
            \\      pid: proc.pid || 0,
            \\      command: String(proc.command || ''),
            \\      args: Array.isArray(proc.args) ? proc.args.map(String) : [],
            \\      kind: String(proc.kind || ''),
            \\      native: !!proc.native,
            \\      sync: !!proc.sync,
            \\      shell: !!proc.shell,
            \\      petShim: !!proc.petShim
            \\    };
            \\  });
            \\  const network = (globalThis._wizpNetworkAudit || []).map(function(entry) {
            \\    return {
            \\      module: String(entry.module || ''),
            \\      options: String(entry.options || ''),
            \\      local: !!entry.local,
            \\      allowlisted: !!entry.allowlisted,
            \\      explicitConsent: !!entry.explicitConsent,
            \\      consentRequired: !!entry.consentRequired,
            \\      allowlistRaw: entry.allowlistRaw ? String(entry.allowlistRaw) : '',
            \\      allowlistEntries: entry.allowlistEntries ? String(entry.allowlistEntries) : '',
            \\      host: entry.host ? String(entry.host) : '',
            \\      nativeAvailable: !!entry.nativeAvailable,
            \\      requestEnded: !!entry.requestEnded,
            \\      fetchAttempted: !!entry.fetchAttempted,
            \\      fetchResolved: !!entry.fetchResolved,
            \\      responseStatus: Number(entry.responseStatus || 0),
            \\      bodyResolved: !!entry.bodyResolved,
            \\      responseBytes: Number(entry.responseBytes || 0),
            \\      passthrough: entry.passthrough ? String(entry.passthrough) : '',
            \\      nativeError: entry.nativeError ? String(entry.nativeError) : ''
            \\    };
            \\  });
            \\  return {
            \\    forkedProcesses: forked,
            \\    forkedProcessCount: forked.length,
            \\    spawnedProcesses: spawned,
            \\    spawnedProcessCount: spawned.length,
            \\    networkAudit: network,
            \\    networkAuditCount: network.length
            \\  };
            \\})()
        ;
        const engine_result = self.engine.evalStringTimeoutMs(js, self.diagnosticRpcTimeoutMs()) catch |err| {
            if (err == error.Timeout) {
                _ = self.restartHost() catch {};
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"forkedProcesses\":[],\"forkedProcessCount\":0,\"spawnedProcesses\":[],\"spawnedProcessCount\":0,\"networkAudit\":[],\"networkAuditCount\":0,\"rpcTimeout\":true}}}}", .{id_str});
            }
            return err;
        };
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"forkedProcesses\":[],\"forkedProcessCount\":0,\"spawnedProcesses\":[],\"spawnedProcessCount\":0}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn updateConfigurationRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const js = try std.fmt.allocPrint(self.allocator,
            \\(function() {{
            \\  const req = {s};
            \\  const params = req.params || {{}};
            \\  const entries = params.values || (params.key ? {{ [params.key]: params.value }} : {{}});
            \\  const root = globalThis._wizpContext.workspace._configuration || (globalThis._wizpContext.workspace._configuration = {{}});
            \\  const scopes = root.__scopes || (root.__scopes = {{ global: {{}}, workspaceFolders: {{}} }});
            \\  const scopeKey = function(value) {{
            \\    const raw = value && (value.fsPath || value.path) ? (value.fsPath || value.path) : String(value || '');
            \\    return raw.replace(/^file:\/\//, '');
            \\  }};
            \\  let target = root;
            \\  if (params.target === 'global' || params.target === 1) target = scopes.global;
            \\  else if (params.target === 'workspaceFolder' || params.target === 3) {{
            \\    const key = scopeKey(params.scopeUri || params.resource || (globalThis._wizpContext.workspace.workspaceFolders[0] || {{}}).uri || globalThis._wizpCwd || '.');
            \\    target = scopes.workspaceFolders[key] || (scopes.workspaceFolders[key] = {{}});
            \\  }}
            \\  if (params.languageId) {{
            \\    const overrides = target.__languageOverrides || (target.__languageOverrides = {{}});
            \\    target = overrides[params.languageId] || (overrides[params.languageId] = {{}});
            \\  }}
            \\  const assign = function(fullKey, value) {{
            \\    const path = String(fullKey || '').split('.').filter(Boolean);
            \\    if (!path.length) return;
            \\    let cursor = target;
            \\    for (let i = 0; i < path.length - 1; i++) cursor = cursor[path[i]] = cursor[path[i]] || {{}};
            \\    if (value === undefined) delete cursor[path[path.length - 1]]; else cursor[path[path.length - 1]] = value;
            \\  }};
            \\  for (const key of Object.keys(entries || {{}})) assign(key, entries[key]);
            \\  return {{ status: 'configuration-updated', keys: Object.keys(entries || {{}}), configuration: root }};
            \\}})()
        , .{body});
        defer self.allocator.free(js);
        const engine_result = try self.engine.evalString(js, "updateConfiguration");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"status\":\"configuration-updated\",\"keys\":[]}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn cspellRuntimeProbeRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const js =
            \\(async function() {
            \\  const vscode = globalThis._wizpContext;
            \\  const extension = vscode.extensions.getExtension('streetsidesoftware.code-spell-checker') || vscode.extensions.getExtension('code-spell-checker');
            \\  const api = extension && extension.exports;
            \\  const editor = vscode.window.activeTextEditor;
            \\  const document = editor && editor.document;
            \\  const apiKeys = api ? Object.keys(api).sort() : [];
            \\  let clientState = null;
            \\  if (api && typeof api.cSpellClient === 'function') {
            \\    try {
            \\      const client = api.cSpellClient();
            \\      clientState = {
            \\        present: !!client,
            \\        hasServerApi: !!(client && client.serverApi),
            \\        hasCheckDocument: !!(client && client.serverApi && client.serverApi.checkDocument),
            \\        state: client && client.state
            \\      };
            \\    } catch (error) {
            \\      clientState = { present: false, error: String(error && error.message ? error.message : error) };
            \\    }
            \\  }
            \\  let checkDocument = { attempted: false };
            \\  if (api && typeof api.checkDocument === 'function' && document) {
            \\    checkDocument.attempted = true;
            \\    try {
            \\      const value = await Promise.race([
            \\        Promise.resolve(api.checkDocument(document, {})),
            \\        new Promise(resolve => setTimeout(() => resolve({ __wizpTimedOut: true }), 5000))
            \\      ]);
            \\      checkDocument.timedOut = !!(value && value.__wizpTimedOut);
            \\      checkDocument.resultType = Array.isArray(value) ? 'array' : typeof value;
            \\      checkDocument.issueCount = Array.isArray(value) ? value.length : (value && Array.isArray(value.items) ? value.items.length : null);
            \\      checkDocument.resultKeys = value && typeof value === 'object' && !Array.isArray(value) ? Object.keys(value).sort() : [];
            \\    } catch (error) {
            \\      checkDocument.error = String(error && error.message ? error.message : error);
            \\    }
            \\  }
            \\  const diagnosticStore = globalThis._wizpDiagnosticCollections || [];
            \\  const diagnosticValues = Array.isArray(diagnosticStore) ? diagnosticStore : Object.values(diagnosticStore);
            \\  const diagnostics = diagnosticValues.map(c => ({
            \\    name: c.name,
            \\    entries: Object.keys(c.entries || {}).length
            \\  }));
            \\  return {
            \\    extensionFound: !!extension,
            \\    isActive: !!(extension && extension.isActive),
            \\    apiKeys: apiKeys,
            \\    activeDocument: document ? document.uri.toString() : null,
            \\    clientState: clientState,
            \\    checkDocument: checkDocument,
            \\    diagnosticCollections: diagnostics,
            \\    status: extension && api && clientState && clientState.hasServerApi && checkDocument.attempted && !checkDocument.timedOut && !checkDocument.error
            \\      ? 'cspell-client-api-verified'
            \\      : 'blocked'
            \\  };
            \\})()
        ;
        const engine_result = try self.engine.evalString(js, "cspellRuntimeProbe");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"status\":\"blocked\"}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn activeTextDocumentRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const js = try std.fmt.allocPrint(self.allocator,
            \\(async function() {{
            \\  const req = {s};
            \\  const params = req.params || {{}};
            \\  const uri = globalThis._wizpContext.Uri.parse(params.uri || 'file://active.txt');
            \\  const key = uri.toString();
            \\  let document = globalThis._wizpDocuments[key];
            \\  const wasOpen = !!document;
            \\  if (!document) {{
            \\    document = await globalThis._wizpContext.workspace.openTextDocument(uri);
            \\  }}
            \\  if (params.languageId) document.languageId = params.languageId;
            \\  if (Object.prototype.hasOwnProperty.call(params, 'content')) {{
            \\    const nextText = String(params.content || '');
            \\    if (document.getText() !== nextText) {{
            \\      globalThis._wizpContext.workspace._changeTextDocument(document, [{{
            \\        range: new globalThis._wizpContext.Range(
            \\          new globalThis._wizpContext.Position(0, 0),
            \\          new globalThis._wizpContext.Position(Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER)
            \\        ),
            \\        newText: nextText
            \\      }}]);
            \\    }}
            \\  }}
            \\  if (params.fireOpen && wasOpen) {{
            \\    globalThis._wizpContext.workspace._fireTextDocumentEvent('open', document);
            \\  }}
            \\  const line = params.line === undefined ? 0 : params.line;
            \\  const character = params.character === undefined ? 0 : params.character;
            \\  const endLine = params.endLine === undefined ? line : params.endLine;
            \\  const endCharacter = params.endCharacter === undefined ? character : params.endCharacter;
            \\  const position = new globalThis._wizpContext.Position(line, character);
            \\  const endPosition = new globalThis._wizpContext.Position(endLine, endCharacter);
            \\  const selectionRange = new globalThis._wizpContext.Range(position, endPosition);
            \\  const editor = await globalThis._wizpContext.window.showTextDocument(document, {{ viewColumn: 1, selection: selectionRange }});
            \\  if (params.line !== undefined || params.character !== undefined || params.endLine !== undefined || params.endCharacter !== undefined) {{
            \\    editor.selection = new globalThis._wizpContext.Selection(position, endPosition);
            \\    editor.selections = [editor.selection];
            \\  }}
            \\  return {{
            \\    uri: document.uri.toString(),
            \\    fileName: document.fileName,
            \\    languageId: document.languageId,
            \\    version: document.version,
            \\    text: document.getText(),
            \\    selection: {{
            \\      start: {{ line: editor.selection.start.line, character: editor.selection.start.character }},
            \\      end: {{ line: editor.selection.end.line, character: editor.selection.end.character }}
            \\    }}
            \\  }};
            \\}})()
        , .{body});
        defer self.allocator.free(js);
        const engine_result = try self.engine.evalString(js, "activeTextDocument");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"text\":\"\"}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn clearMementoCacheRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const js =
            \\(function() {
            \\  const before = Object.keys(globalThis._wizpMementoStores || {}).length;
            \\  const secretBefore = Object.keys(globalThis._wizpSecretStores || {}).length;
            \\  globalThis._wizpMementoStores = {};
            \\  globalThis._wizpSecretStores = {};
            \\  return { cleared: true, before: before, secretBefore: secretBefore };
            \\})()
        ;
        const engine_result = try self.engine.evalString(js, "clearMementoCache");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"cleared\":true,\"before\":0}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn applySaveParticipantsRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const js = try std.fmt.allocPrint(self.allocator,
            \\(async function() {{
            \\  const req = {s};
            \\  const params = req.params || {{}};
            \\  const uri = globalThis._wizpContext.Uri.file(params.path || '');
            \\  const document = globalThis._wizpContext.workspace._makeTextDocument(uri, params.content || '', params.languageId || 'plaintext', 1);
            \\  let text = await globalThis._wizpContext.workspace._fireWillSaveTextDocument(document, 1);
            \\  document._text = text;
            \\  document.lineCount = String(text || '').split('\n').length;
            \\  const selectorScore = function(selector, doc) {{
            \\    if (!selector) return 0;
            \\    if (Array.isArray(selector)) return selector.reduce(function(best, item) {{ return Math.max(best, selectorScore(item, doc)); }}, 0);
            \\    if (typeof selector === 'string') return selector === '*' || selector === doc.languageId ? 10 : 0;
            \\    const languageOk = !selector.language || selector.language === '*' || selector.language === doc.languageId;
            \\    const schemeOk = !selector.scheme || selector.scheme === '*' || selector.scheme === (doc.uri && doc.uri.scheme);
            \\    return languageOk && schemeOk ? 10 : 0;
            \\  }};
            \\  let formatterEditCount = 0;
            \\  if (params.formatOnSave) {{
            \\    const providers = (globalThis._wizpDocumentFormattingProviders || [])
            \\      .filter(function(entry) {{ return selectorScore(entry.selector, document) > 0; }})
            \\      .sort(function(a, b) {{ return selectorScore(b.selector, document) - selectorScore(a.selector, document); }});
            \\    for (const entry of providers) {{
            \\      const edits = await Promise.resolve(entry.provider.provideDocumentFormattingEdits(document, params.options || {{ tabSize: 2, insertSpaces: true }}, {{ isCancellationRequested: false }}));
            \\      if (edits && edits.length) {{
            \\        formatterEditCount += edits.length;
            \\        text = globalThis._wizpContext.workspace._applyTextEdits(text, edits);
            \\        document._text = text;
            \\        document.lineCount = String(text || '').split('\n').length;
            \\        break;
            \\      }}
            \\    }}
            \\  }}
            \\  return {{ path: params.path || '', content: text, changed: text !== (params.content || ''), formatOnSave: !!params.formatOnSave, formatterEditCount: formatterEditCount }};
            \\}})()
        , .{body});
        defer self.allocator.free(js);
        const engine_result = try self.engine.evalString(js, "applySaveParticipants");
        defer self.allocator.free(engine_result);
        const raw = stripEngineResult(engine_result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"content\":\"\",\"changed\":false}" else raw;
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn deactivateExtensionRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const extension_id = extractJSONString(body, "\"extensionId\"") orelse return try jsonRpcError(self.allocator, id_str, -32602, "extension/deactivate requires extensionId");
        if (!self.activated.contains(extension_id)) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"deactivated\":false,\"reason\":\"notActive\"}}}}", .{id_str});
        }

        const result_json = try self.deactivateExtension(extension_id);
        defer self.allocator.free(result_json);
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
    }

    pub fn activateByEventRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const event = extractJSONString(body, "\"event\"") orelse return try jsonRpcError(self.allocator, id_str, -32602, "extension/activateByEvent requires event");
        const before = self.activated.count();
        self.activateByEvent(event) catch |err| {
            return try jsonRpcError(self.allocator, id_str, -32001, @errorName(err));
        };
        const activated_count = self.activated.count() - before;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"event\":", .{id_str});
        try writeJsonString(w, event);
        try w.print(",\"activated\":{},\"extensions\":[", .{activated_count});
        var first_extension = true;
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (!first_extension) try w.writeAll(",");
            first_extension = false;
            try w.writeAll("{\"id\":");
            try writeJsonString(w, ext.id);
            try w.writeAll(",\"activationEvents\":[");
            for (ext.activation_events, 0..) |activation_event, index| {
                if (index > 0) try w.writeAll(",");
                try writeJsonString(w, activation_event);
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    pub fn fileSystemAccessRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const scheme = extractJSONString(body, "\"scheme\"") orelse return try jsonRpcError(self.allocator, id_str, -32602, "extension/fileSystemAccess requires scheme");
        const event = try std.fmt.allocPrint(self.allocator, "fileSystem:{s}", .{scheme});
        defer self.allocator.free(event);
        const before = self.activated.count();
        try self.activateByEvent(event);
        const activated_count = self.activated.count() - before;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"scheme\":", .{id_str});
        try writeJsonString(w, scheme);
        try w.print(",\"activated\":{}}}}}", .{activated_count});
        return try out.toOwnedSlice();
    }

    pub fn debugLifecycleRpc(self: *Self, body: []const u8) ![]u8 {
        const id_str = extractJsonRpcId(body) orelse "null";
        const event_name = extractJSONString(body, "\"event\"") orelse "debug";
        const before = self.activated.count();
        try self.activateByEvent(event_name);
        const activated_count = self.activated.count() - before;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"event\":", .{id_str});
        try writeJsonString(w, event_name);
        try w.print(",\"activated\":{}}}}}", .{activated_count});
        return try out.toOwnedSlice();
    }

    pub fn activateTaskTypes(self: *Self, filter_type: ?[]const u8) !void {
        if (filter_type) |task_type| {
            const event = try std.fmt.allocPrint(self.allocator, "task:{s}", .{task_type});
            defer self.allocator.free(event);
            try self.activateByEvent(event);
            return;
        }
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            for (ext.activation_events) |activation_event| {
                if (!std.mem.startsWith(u8, activation_event, "onTaskType:")) continue;
                const task_type = activation_event["onTaskType:".len..];
                const event = try std.fmt.allocPrint(self.allocator, "task:{s}", .{task_type});
                defer self.allocator.free(event);
                try self.activateByEvent(event);
            }
            if (ext.contributes) |contributes| {
                for (contributes.task_definitions) |definition| {
                    const event = try std.fmt.allocPrint(self.allocator, "task:{s}", .{definition.type_name});
                    defer self.allocator.free(event);
                    try self.activateByEvent(event);
                }
            }
        }
    }

    fn commandEnablement(self: *Self, command: []const u8) ?bool {
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.commands) |cmd| {
                    if (std.mem.eql(u8, cmd.command, command)) {
                        return self.evaluateWhenClause(cmd.enablement);
                    }
                }
            }
        }
        return null;
    }

    fn commandTitle(self: *Self, command: []const u8) []const u8 {
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.commands) |cmd| {
                    if (std.mem.eql(u8, cmd.command, command)) return cmd.title;
                }
            }
        }
        return command;
    }

    fn extensionOwningCommand(self: *Self, command: []const u8) ?Extension {
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.commands) |cmd| {
                    if (std.mem.eql(u8, cmd.command, command)) return ext;
                }
            }
        }
        return null;
    }

    fn setViewVisibleContextForFocusCommand(self: *Self, command: []const u8) !void {
        const suffix = ".focus";
        if (!std.mem.endsWith(u8, command, suffix)) return;
        const view_id = command[0 .. command.len - suffix.len];
        if (!self.hasViewContribution(view_id)) return;
        const key = try std.fmt.allocPrint(self.allocator, "{s}.visible", .{view_id});
        defer self.allocator.free(key);
        try self.setContextBool(key, true);
    }

    fn hasViewContribution(self: *Self, view_id: []const u8) bool {
        var it = self.extensions.iterator();
        while (it.next()) |entry| {
            const ext = entry.value_ptr.*;
            if (ext.contributes) |contributes| {
                for (contributes.views) |view| {
                    if (std.mem.eql(u8, view.id, view_id)) return true;
                }
            }
        }
        return false;
    }

    fn setContextFromRpcBody(self: *Self, body: []const u8) !void {
        const args_start = std.mem.indexOf(u8, body, "\"args\"") orelse return error.InvalidContextArgs;
        const args_body = body[args_start..];
        const arr_start = std.mem.indexOfScalar(u8, args_body, '[') orelse return error.InvalidContextArgs;
        const key_escaped = ExtensionJson.firstString(args_body[arr_start + 1 ..]) orelse return error.InvalidContextArgs;
        const key = try ExtensionJson.unescape(self.allocator, key_escaped);
        defer self.allocator.free(key);

        const after_key_start = std.mem.indexOf(u8, args_body[arr_start + 1 ..], key_escaped) orelse return error.InvalidContextArgs;
        var value_slice = args_body[arr_start + 1 + after_key_start + key_escaped.len ..];
        if (std.mem.indexOfScalar(u8, value_slice, ',')) |comma| value_slice = value_slice[comma + 1 ..];
        value_slice = std.mem.trimStart(u8, value_slice, " \t\r\n");

        if (std.mem.startsWith(u8, value_slice, "true")) {
            try self.setContextBool(key, true);
        } else if (std.mem.startsWith(u8, value_slice, "false")) {
            try self.setContextBool(key, false);
        } else if (ExtensionJson.firstString(value_slice)) |value_escaped| {
            const value = try ExtensionJson.unescape(self.allocator, value_escaped);
            defer self.allocator.free(value);
            try self.setContextString(key, value);
        } else {
            try self.setContextBool(key, false);
        }
    }

    fn setContextBool(self: *Self, key: []const u8, value: bool) !void {
        try self.freeExistingContext(key);
        try self.context_keys.put(self.allocator, try self.allocator.dupe(u8, key), .{ .boolean = value });
    }

    fn setContextString(self: *Self, key: []const u8, value: []const u8) !void {
        try self.freeExistingContext(key);
        try self.context_keys.put(self.allocator, try self.allocator.dupe(u8, key), .{ .string = try self.allocator.dupe(u8, value) });
    }

    fn freeExistingContext(self: *Self, key: []const u8) !void {
        if (self.context_keys.fetchSwapRemove(key)) |entry| {
            self.allocator.free(entry.key);
            switch (entry.value) {
                .string => |s| self.allocator.free(s),
                .boolean => {},
            }
        }
    }

    fn evaluateWhenClause(self: *Self, expr: ?[]const u8) bool {
        const raw = expr orelse return true;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return true;

        var or_it = std.mem.splitSequence(u8, trimmed, "||");
        while (or_it.next()) |or_part| {
            var and_it = std.mem.splitSequence(u8, or_part, "&&");
            var all_true = true;
            while (and_it.next()) |and_part| {
                if (!self.evaluateWhenTerm(and_part)) {
                    all_true = false;
                    break;
                }
            }
            if (all_true) return true;
        }
        return false;
    }

    fn evaluateWhenTerm(self: *Self, term_raw: []const u8) bool {
        var term = std.mem.trim(u8, term_raw, " \t\r\n()");
        var negate = false;
        while (std.mem.startsWith(u8, term, "!")) {
            negate = !negate;
            term = std.mem.trimStart(u8, term[1..], " \t");
        }

        const result = blk: {
            if (std.mem.indexOf(u8, term, "==")) |pos| {
                const key = std.mem.trim(u8, term[0..pos], " \t");
                const expected = trimWhenLiteral(term[pos + 2 ..]);
                break :blk self.contextEquals(key, expected);
            }
            if (std.mem.indexOf(u8, term, "!=")) |pos| {
                const key = std.mem.trim(u8, term[0..pos], " \t");
                const expected = trimWhenLiteral(term[pos + 2 ..]);
                break :blk !self.contextEquals(key, expected);
            }
            break :blk self.contextTruthy(term);
        };
        return if (negate) !result else result;
    }

    fn contextTruthy(self: *Self, key: []const u8) bool {
        if (self.context_keys.get(key)) |value| {
            return switch (value) {
                .boolean => |b| b,
                .string => |s| s.len > 0,
            };
        }
        return false;
    }

    fn contextEquals(self: *Self, key: []const u8, expected: []const u8) bool {
        if (self.context_keys.get(key)) |value| {
            return switch (value) {
                .boolean => |b| (b and std.mem.eql(u8, expected, "true")) or (!b and std.mem.eql(u8, expected, "false")),
                .string => |s| std.mem.eql(u8, s, expected),
            };
        }
        return std.mem.eql(u8, expected, "false");
    }

    fn buildExtensionModuleMapJson(self: *Self, ext_path: []const u8, main_path: []const u8) ![]u8 {
        const embed_sources_raw = compat_runtime.getEnvVarOwned(self.allocator, "WIZP_EMBED_EXTENSION_SOURCES") catch null;
        defer if (embed_sources_raw) |value| self.allocator.free(value);
        const embed_sources = if (embed_sources_raw) |value|
            !(std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "FALSE"))
        else
            false;
        if (!embed_sources) return try self.allocator.dupe(u8, "{}");

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{");
        var first = true;
        const package_json_path = try std.fs.path.join(self.allocator, &.{ ext_path, "package.json" });
        defer self.allocator.free(package_json_path);
        try self.appendExtensionModuleSourceFile(w, package_json_path, &first);
        try self.appendExtensionModuleSourceFile(w, main_path, &first);
        try w.writeAll("}");
        return try out.toOwnedSlice();
    }

    fn appendExtensionModuleSourceFile(self: *Self, writer: anytype, path: []const u8, first: *bool) !void {
        const source = std.Io.Dir.cwd().readFileAlloc(
            compat_runtime.io(),
            path,
            self.allocator,
            .limited(4 * 1024 * 1024),
        ) catch return;
        defer self.allocator.free(source);
        if (!first.*) try writer.writeAll(",");
        first.* = false;
        try writeJsonString(writer, path);
        try writer.writeAll(":");
        if (std.mem.endsWith(u8, path, ".wasm")) {
            const b64_len = std.base64.standard.Encoder.calcSize(source.len);
            const b64 = try self.allocator.alloc(u8, b64_len);
            defer self.allocator.free(b64);
            _ = std.base64.standard.Encoder.encode(b64, source);
            try writer.writeAll("{\"__base64\":");
            try writeJsonString(writer, b64);
            try writer.writeAll("}");
        } else {
            try writeJsonString(writer, source);
        }
    }

    fn appendExtensionModuleSources(self: *Self, writer: anytype, dir_path: []const u8, first: *bool, depth: usize) !void {
        if (depth > 16) return;
        var dir = std.Io.Dir.cwd().openDir(
            compat_runtime.io(),
            dir_path,
            .{ .iterate = true },
        ) catch return;
        defer dir.close(compat_runtime.io());

        var read_buffer: [std.Io.Dir.Reader.min_buffer_len]u8 align(@alignOf(usize)) = undefined;
        var iter = dir.reader(compat_runtime.io(), &read_buffer);
        while (try iter.next()) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            const child_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(child_path);
            switch (entry.kind) {
                .directory => try self.appendExtensionModuleSources(writer, child_path, first, depth + 1),
                .file => {
                    if (!isCommonJsSourcePath(entry.name)) continue;
                    const source = compat_runtime.readFileAlloc(
                        self.allocator,
                        child_path,
                        4 * 1024 * 1024,
                    ) catch continue;
                    defer self.allocator.free(source);
                    if (!first.*) try writer.writeAll(",");
                    first.* = false;
                    try writeJsonString(writer, child_path);
                    try writer.writeAll(":");
                    if (std.mem.endsWith(u8, entry.name, ".wasm")) {
                        const b64_len = std.base64.standard.Encoder.calcSize(source.len);
                        const b64 = try self.allocator.alloc(u8, b64_len);
                        defer self.allocator.free(b64);
                        _ = std.base64.standard.Encoder.encode(b64, source);
                        try writer.writeAll("{\"__base64\":");
                        try writeJsonString(writer, b64);
                        try writer.writeAll("}");
                    } else {
                        try writeJsonString(writer, source);
                    }
                },
                else => {},
            }
        }
    }

    /// Activate a specific extension.
    fn activateExtension(self: *Self, ext: Extension) !void {
        if (self.activated.contains(ext.id)) return;
        if (self.activating.contains(ext.id)) return;
        const debug = self.extensionDebugEnabled();
        if (debug) std.debug.print("WIZP ExtHost: activateExtension {s} start\n", .{ext.id});
        try self.activating.put(self.allocator, ext.id, {});
        defer _ = self.activating.swapRemove(ext.id);

        for (ext.extension_dependencies) |dependency_id| {
            const dependency = self.findExtension(dependency_id) orelse {
                if (ExtensionPolicy.isShimmedExtensionDependency(self.allocator, dependency_id)) continue;
                std.debug.print("WIZP ExtHost: dependency {s} for {s} was not found\n", .{ dependency_id, ext.id });
                continue;
            };
            try self.activateExtension(dependency);
        }
        if (debug) std.debug.print("WIZP ExtHost: activateExtension {s} dependencies-ready\n", .{ext.id});

        var main_path = try std.fs.path.join(self.allocator, &.{ ext.path, ext.main });
        defer self.allocator.free(main_path);
        std.Io.Dir.cwd().access(compat_runtime.io(), main_path, .{}) catch |main_err| {
            if (main_err == error.FileNotFound) {
                const js_candidate = try std.fmt.allocPrint(self.allocator, "{s}.js", .{main_path});
                std.Io.Dir.cwd().access(compat_runtime.io(), js_candidate, .{}) catch |candidate_err| {
                    self.allocator.free(js_candidate);
                    return candidate_err;
                };
                self.allocator.free(main_path);
                main_path = js_candidate;
            } else {
                return main_err;
            }
        };

        if (try self.preflightJavaRuntimeUnavailable(ext)) return error.ActivationFailed;
        if (debug) std.debug.print("WIZP ExtHost: activateExtension {s} main-ready {s}\n", .{ ext.id, main_path });

        const normalized_main_path = try std.fs.path.resolve(self.allocator, &.{main_path});
        defer self.allocator.free(normalized_main_path);

        if (debug) std.debug.print("WIZP ExtHost: activateExtension {s} module-map:start\n", .{ext.id});
        const module_map_json = try self.buildExtensionModuleMapJson(ext.path, normalized_main_path);
        defer self.allocator.free(module_map_json);
        if (debug) std.debug.print("WIZP ExtHost: activateExtension {s} module-map:done\n", .{ext.id});

        const storage_root = try std.fs.path.join(self.allocator, &.{ ext.path, ".wizp-context" });
        defer self.allocator.free(storage_root);
        std.Io.Dir.cwd().createDirPath(compat_runtime.io(), storage_root) catch |err| {
            std.debug.print("WIZP ExtHost: cannot create storage root {s}: {}\n", .{ storage_root, err });
        };

        // Build activation wrapper: load module and call activate()
        const wrapper = try std.fmt.allocPrint(self.allocator,
            \\// Extension: {s}
            \\Promise.resolve((async function() {{
            \\  const module = {{ exports: {{}} }};
            \\  const exports = module.exports;
            \\  const nodeRequire = globalThis._wizpRequire;
            \\  const nativeRequire = typeof require === 'function' ? require : null;
            \\  const nativeFs = globalThis._wizpNativeFs || globalThis._wizpNodeFs;
            \\  const joinPath = function() {{
            \\    const joined = Array.prototype.slice.call(arguments).filter(Boolean).join('/').replace(/\/+/g, '/');
            \\    const absolute = joined.startsWith('/');
            \\    const parts = [];
            \\    for (const part of joined.split('/')) {{
            \\      if (!part || part === '.') continue;
            \\      if (part === '..') parts.pop(); else parts.push(part);
            \\    }}
            \\    return (absolute ? '/' : '') + parts.join('/');
            \\  }};
            \\  const dirname = function(path) {{ const idx = String(path || '').lastIndexOf('/'); return idx <= 0 ? '/' : String(path).slice(0, idx); }};
            \\  const extensionRoot = '{s}';
            \\  const mainFile = joinPath('{s}');
            \\  const mainDir = dirname(mainFile);
            \\  const moduleCache = {{}};
            \\  const moduleSources = {s};
            \\  globalThis._wizpExtensionFileSources = Object.assign(globalThis._wizpExtensionFileSources || {{}}, moduleSources);
            \\  const installNativeBuiltinRedirects = function() {{
            \\    if (typeof nativeRequire !== 'function') return false;
            \\    try {{
            \\      const nativeModule = nativeRequire('module');
            \\      if (!nativeModule) return false;
            \\      const currentRequire = nativeModule.prototype && typeof nativeModule.prototype.require === 'function' ? nativeModule.prototype.require : null;
            \\      const currentLoad = nativeModule._load;
            \\      if (currentRequire && currentRequire.__wizpBuiltinRedirect === true) return true;
            \\      if (currentLoad && currentLoad.__wizpBuiltinRedirect === true) return true;
            \\      const redirectedBuiltins = {{
            \\        'child_process': true,
            \\        'node:child_process': true,
            \\        'http': true,
            \\        'node:http': true,
            \\        'https': true,
            \\        'node:https': true
            \\      }};
            \\      const resolveBuiltin = function(request) {{
            \\        const name = String(request || '');
            \\        if (Object.prototype.hasOwnProperty.call(redirectedBuiltins, name)) return nodeRequire(name);
            \\        return null;
            \\      }};
            \\      if (currentRequire) {{
            \\        const wrappedRequire = function(request) {{
            \\          const redirected = resolveBuiltin(request);
            \\          if (redirected) return redirected;
            \\          return currentRequire.apply(this, arguments);
            \\        }};
            \\        wrappedRequire.__wizpBuiltinRedirect = true;
            \\        nativeModule.prototype.require = wrappedRequire;
            \\      }}
            \\      if (typeof currentLoad !== 'function') return !!currentRequire;
            \\      const wrappedLoad = function(request, parent, isMain) {{
            \\        const redirected = resolveBuiltin(request);
            \\        if (redirected) return redirected;
            \\        return currentLoad.apply(this, arguments);
            \\      }};
            \\      wrappedLoad.__wizpBuiltinRedirect = true;
            \\      nativeModule._load = wrappedLoad;
            \\      return true;
            \\    }} catch (error) {{
            \\      debugActivationWrite('[WIZP activation] ' + extensionId + ' native-builtin-redirect-fallback ' + String(error && error.message ? error.message : error));
            \\      return false;
            \\    }}
            \\  }};
            \\  const hasModuleSource = function(filename) {{
            \\    return Object.prototype.hasOwnProperty.call(moduleSources, filename);
            \\  }};
            \\  const nativeExists = function(filename) {{
            \\    try {{ return !!(nativeFs && nativeFs.existsSync && nativeFs.existsSync(filename)); }} catch (_) {{ return false; }}
            \\  }};
            \\  const moduleSourceExists = function(filename) {{
            \\    return hasModuleSource(filename) || nativeExists(filename);
            \\  }};
            \\  const moduleSourceText = function(filename) {{
            \\    if (hasModuleSource(filename)) return moduleSources[filename];
            \\    try {{
            \\      if (nativeFs && nativeFs.readFileSync && nativeExists(filename)) return nativeFs.readFileSync(filename, 'utf8');
            \\    }} catch (_) {{}}
            \\    return null;
            \\  }};
            \\  const resolveLocal = function(baseDir, request) {{
            \\    request = String(request || '');
            \\    if (!request.startsWith('./') && !request.startsWith('../')) return null;
            \\    const base = joinPath(baseDir, request);
            \\    const candidates = [base, base + '.js', base + '.cjs', base + '.json', joinPath(base, 'index.js'), joinPath(base, 'index.cjs')];
            \\    for (const candidate of candidates) if (moduleSourceExists(candidate)) return candidate;
            \\    return candidates[1];
            \\  }};
            \\  const resolveNodeModule = function(startDir, request) {{
            \\    request = String(request || '');
            \\    if (request.startsWith('./') || request.startsWith('../') || request.startsWith('/')) return null;
            \\    let dir = joinPath(startDir || extensionRoot);
            \\    while (dir && dir.startsWith(extensionRoot)) {{
            \\      const base = joinPath(dir, 'node_modules', request);
            \\      const packageJson = joinPath(base, 'package.json');
            \\      const packageSource = moduleSourceText(packageJson);
            \\      if (packageSource !== null && packageSource !== undefined) {{
            \\        try {{
            \\          const manifest = JSON.parse(packageSource || '{{}}');
            \\          const main = manifest.main || manifest.module || 'index.js';
            \\          const resolvedMain = resolveLocal(base, './' + main);
            \\          if (resolvedMain) return resolvedMain;
            \\        }} catch (_) {{}}
            \\      }}
            \\      const candidates = [base + '.js', base + '.cjs', joinPath(base, 'index.js'), joinPath(base, 'index.cjs')];
            \\      for (const candidate of candidates) if (moduleSourceExists(candidate)) return candidate;
            \\      if (dir === extensionRoot) break;
            \\      dir = dirname(dir);
            \\    }}
            \\    return null;
            \\  }};
            \\  const rewriteModuleSource = function(source) {{
            \\    source = String(source || '');
            \\    source = source.replace(/(^|\n)\s*import\s+([\s\S]*?)\s+from\s+["']([^"']+)["'];/g, function(match, prefix, spec, request) {{
            \\      spec = String(spec || '').trim();
            \\      if (spec.startsWith('* as ')) {{
            \\        return prefix + 'const ' + spec.slice(5).trim() + ' = require(' + JSON.stringify(request) + ');';
            \\      }}
            \\      if (spec.startsWith('{{') && spec.endsWith('}}')) {{
            \\        const destructured = spec.slice(1, -1).replace(/\bas\b/g, ':');
            \\        return prefix + 'const {{' + destructured + '}} = require(' + JSON.stringify(request) + ');';
            \\      }}
            \\      if (spec.indexOf(',') >= 0) {{
            \\        const comma = spec.indexOf(',');
            \\        const defaultName = spec.slice(0, comma).trim();
            \\        const rest = spec.slice(comma + 1).trim();
            \\        let code = prefix + 'const __wizpDefaultModule = require(' + JSON.stringify(request) + '); const ' + defaultName + ' = __wizpDefaultModule.default || __wizpDefaultModule;';
            \\        if (rest.startsWith('{{') && rest.endsWith('}}')) code += ' const {{' + rest.slice(1, -1).replace(/\bas\b/g, ':') + '}} = __wizpDefaultModule;';
            \\        return code;
            \\      }}
            \\      return prefix + 'const __wizpDefaultModule = require(' + JSON.stringify(request) + '); const ' + spec + ' = __wizpDefaultModule.default || __wizpDefaultModule;';
            \\    }});
            \\    source = source.replace(/(^|\n)\s*export\s+\{{([\s\S]*?)\}};/g, function(match, prefix, spec) {{
            \\      return prefix + String(spec || '').split(',').map(function(part) {{
            \\        part = part.trim();
            \\        if (!part) return '';
            \\        const pieces = part.split(/\s+as\s+/);
            \\        const localName = pieces[0].trim();
            \\        const exportedName = (pieces[1] || pieces[0]).trim();
            \\        return 'module.exports[' + JSON.stringify(exportedName) + '] = ' + localName + ';';
            \\      }}).join('\n');
            \\    }});
            \\    return source;
            \\  }};
            \\  const makeModuleBuiltin = function(baseDirForRequire) {{
            \\    const createScopedRequire = function(scopeDir) {{
            \\      const scopedRequire = function(request) {{
            \\        const resolved = resolveLocal(scopeDir, request);
            \\        if (resolved) return loadLocal(resolved);
            \\        const moduleResolved = resolveNodeModule(scopeDir, request);
            \\        if (moduleResolved) return loadLocal(moduleResolved);
            \\        return nodeRequire(request);
            \\      }};
            \\      scopedRequire.resolve = function(request) {{
            \\        const resolved = resolveLocal(scopeDir, request);
            \\        if (resolved) return resolved;
            \\        const moduleResolved = resolveNodeModule(scopeDir, request);
            \\        if (moduleResolved) return moduleResolved;
            \\        return String(request || '');
            \\      }};
            \\      return scopedRequire;
            \\    }};
            \\    const Module = function WizpModule(id) {{
            \\      this.id = id || '';
            \\      this.filename = id || '';
            \\      this.path = dirname(id || baseDirForRequire || extensionRoot);
            \\      this.exports = {{}};
            \\    }};
            \\    Module.prototype.require = function(request) {{
            \\      return createScopedRequire(this && this.path ? this.path : (baseDirForRequire || extensionRoot))(request);
            \\    }};
            \\    Module.builtinModules = (globalThis._wizpNodeRepl && globalThis._wizpNodeRepl.builtinModules) || [];
            \\    Module._builtinLibs = Module.builtinModules;
            \\    Module._resolveFilename = function(request, parent) {{
            \\      const parentPath = parent && (parent.filename || parent.id || parent.path);
            \\      const scopeDir = parentPath && String(parentPath).startsWith('/') ? dirname(parentPath) : (baseDirForRequire || extensionRoot);
            \\      const resolved = resolveLocal(scopeDir, request);
            \\      if (resolved) return resolved;
            \\      const moduleResolved = resolveNodeModule(scopeDir, request);
            \\      if (moduleResolved) return moduleResolved;
            \\      return String(request || '');
            \\    }};
            \\    Module.createRequire = function(base) {{
            \\      let basePath = String(base && (base.href || base.path || base.pathname) ? (base.href || base.path || base.pathname) : (base || baseDirForRequire || extensionRoot));
            \\      if (basePath.startsWith('file://')) {{
            \\        try {{ basePath = new URL(basePath).pathname; }} catch (_) {{ basePath = basePath.slice(7); }}
            \\      }}
            \\      return createScopedRequire(dirname(basePath || extensionRoot));
            \\    }};
            \\    Module.Module = Module;
            \\    return Module;
            \\  }};
            \\  const loadLocal = function(filename) {{
            \\    if (moduleCache[filename]) return moduleCache[filename].exports;
            \\    const localModule = {{ exports: {{}}, id: filename, filename: filename, path: dirname(filename), paths: [] }};
            \\    moduleCache[filename] = localModule;
            \\    let source = moduleSourceText(filename);
            \\    if (source === null || source === undefined) throw new Error('Module not found: ' + filename);
            \\    if (filename.endsWith('.json')) {{
            \\      localModule.exports = JSON.parse(source || '{{}}');
            \\      return localModule.exports;
            \\    }}
            \\    const localRequire = function(name) {{
            \\      if (name === 'module' || name === 'node:module') return makeModuleBuiltin(dirname(filename));
            \\      const resolved = resolveLocal(dirname(filename), name);
            \\      if (resolved) return loadLocal(resolved);
            \\      const moduleResolved = resolveNodeModule(dirname(filename), name);
            \\      if (moduleResolved) return loadLocal(moduleResolved);
            \\      return nodeRequire(name);
            \\    }};
            \\    source = rewriteModuleSource(source);
            \\    const fn = new Function('module', 'exports', 'require', '__filename', '__dirname', source);
            \\    fn(localModule, localModule.exports, localRequire, filename, dirname(filename));
            \\    return localModule.exports;
            \\  }};
            \\  const mainRequire = function(name) {{
            \\    const resolved = resolveLocal(mainDir, name);
            \\    if (resolved) return loadLocal(resolved);
            \\    const moduleResolved = resolveNodeModule(mainDir, name);
            \\    if (moduleResolved) return loadLocal(moduleResolved);
            \\    return nodeRequire(name);
            \\  }};
            \\  const extensionUri = globalThis._wizpContext.Uri.file('{s}');
            \\  const storageRoot = '{s}';
            \\  const storagePath = joinPath(storageRoot, 'workspace');
            \\  const globalStoragePath = joinPath(storageRoot, 'global');
            \\  const logPath = joinPath(storageRoot, 'logs');
            \\  const globalMementoPath = joinPath(storageRoot, 'global-memento.json');
            \\  const workspaceMementoPath = joinPath(storageRoot, 'workspace-memento.json');
            \\  const secretStoragePath = joinPath(storageRoot, 'secrets-fallback.json');
            \\  const ensureStorageDir = function(path) {{
            \\    try {{
            \\      if (nativeFs && nativeFs.mkdirSync) nativeFs.mkdirSync(path, {{ recursive: true }});
            \\    }} catch (_) {{}}
            \\  }};
            \\  ensureStorageDir(storageRoot);
            \\  ensureStorageDir(storagePath);
            \\  ensureStorageDir(globalStoragePath);
            \\  ensureStorageDir(logPath);
            \\  await globalThis._wizpLoadMementoStore('{s}:global', globalMementoPath);
            \\  await globalThis._wizpLoadMementoStore('{s}:workspace', workspaceMementoPath);
            \\  await globalThis._wizpLoadSecretStore('{s}', secretStoragePath);
            \\  const packageJSON = Object.assign({{ name: '{s}', publisher: '{s}', displayName: '{s}', version: '{s}', aiKey: '{s}' }}, {s});
            \\  const extensionId = packageJSON.publisher ? packageJSON.publisher + '.' + packageJSON.name : packageJSON.name;
            \\  const extensionStoragePath = joinPath(storageRoot, extensionId);
            \\  ensureStorageDir(joinPath(storageRoot, packageJSON.name));
            \\  ensureStorageDir(extensionStoragePath);
            \\  const allowBackgroundActivation = {s};
            \\  const debugActivation = allowBackgroundActivation || !!(globalThis._wizpNodeProcess && globalThis._wizpNodeProcess.env && globalThis._wizpNodeProcess.env.WIZP_EXTENSION_DEBUG);
            \\  const debugActivationWrite = function(line) {{
            \\    if (!debugActivation) return;
            \\    try {{
            \\      if (globalThis._wizpNodeProcess && globalThis._wizpNodeProcess.stderr && typeof globalThis._wizpNodeProcess.stderr.write === 'function') {{
            \\        globalThis._wizpNodeProcess.stderr.write(String(line || '') + '\n');
            \\        return;
            \\      }}
            \\    }} catch (_) {{}}
            \\    try {{ console.error(line); }} catch (_) {{}}
            \\  }};
            \\  const debugActivationPhase = function(phase) {{
            \\    debugActivationWrite('[WIZP activation] ' + extensionId + ' ' + phase);
            \\  }};
            \\  const extensionRecord = {{
            \\    id: extensionId,
            \\    extensionUri: extensionUri,
            \\    extensionPath: '{s}',
            \\    packageJSON: packageJSON,
            \\    isActive: false,
            \\    exports: module.exports,
            \\    activate: async function() {{ return extensionRecord.exports; }}
            \\  }};
            \\  globalThis._wizpExtensions[packageJSON.name] = extensionRecord;
            \\  globalThis._wizpExtensions[extensionId] = extensionRecord;
            \\  const extensionContext = Object.assign(Object.create(globalThis._wizpContext), {{
            \\    id: extensionId,
            \\    extension: extensionRecord,
            \\    extensionPath: '{s}',
            \\    extensionUri: extensionUri,
            \\    storageUri: globalThis._wizpContext.Uri.file(extensionStoragePath),
            \\    globalStorageUri: globalThis._wizpContext.Uri.file(extensionStoragePath),
            \\    logUri: globalThis._wizpContext.Uri.file(logPath),
            \\    storagePath: extensionStoragePath,
            \\    globalStoragePath: extensionStoragePath,
            \\    logPath: logPath,
            \\    extensionMode: globalThis._wizpContext.ExtensionMode.Production,
            \\    packageJSON: packageJSON,
            \\    subscriptions: [],
            \\    asAbsolutePath: function(relativePath) {{ return joinPath('{s}', relativePath || ''); }},
            \\    globalState: globalThis._wizpMakeMemento('{s}:global', globalMementoPath),
            \\    workspaceState: globalThis._wizpMakeMemento('{s}:workspace', workspaceMementoPath),
            \\    secrets: globalThis._wizpMakeSecretStorage('{s}', secretStoragePath),
            \\    environmentVariableCollection: globalThis._wizpMakeEnvironmentVariableCollection('{s}')
            \\  }});
            \\  const ensureNativeVscodeShim = function() {{
            \\    if (!nativeFs || !nativeFs.mkdirSync || !nativeFs.writeFileSync) return null;
            \\    const shimDir = joinPath(extensionRoot, 'node_modules', 'vscode');
            \\    const packagePath = joinPath(shimDir, 'package.json');
            \\    const indexPath = joinPath(shimDir, 'index.js');
            \\    try {{
            \\      nativeFs.mkdirSync(shimDir, {{ recursive: true }});
            \\      if (!nativeExists(packagePath)) nativeFs.writeFileSync(packagePath, JSON.stringify({{ name: 'vscode', main: 'index.js' }}, null, 2));
            \\      if (!nativeExists(indexPath)) nativeFs.writeFileSync(indexPath, 'module.exports = globalThis._wizpContext;\\n');
            \\      return indexPath;
            \\    }} catch (error) {{
            \\      debugActivationWrite('[WIZP activation] ' + extensionId + ' native-vscode-shim-error ' + String(error && error.message ? error.message : error));
            \\      return null;
            \\    }}
            \\  }};
            \\  const loadMainModule = function() {{
            \\    if (nativeFs && typeof nativeRequire === 'function') {{
            \\      try {{
            \\        ensureNativeVscodeShim();
            \\        installNativeBuiltinRedirects();
            \\        debugActivationPhase('loadMain:native-require:start');
            \\        const nativeExports = nativeRequire(mainFile);
            \\        debugActivationPhase('loadMain:native-require:done');
            \\        return nativeExports;
            \\      }} catch (error) {{
            \\        debugActivationWrite('[WIZP activation] ' + extensionId + ' native-require-fallback ' + String(error && error.message ? error.message : error));
            \\      }}
            \\    }}
            \\    debugActivationPhase('loadMain:custom-loader:start');
            \\    const loaded = loadLocal(mainFile);
            \\    debugActivationPhase('loadMain:custom-loader:done');
            \\    return loaded;
            \\  }};
            \\  debugActivationPhase('loadLocal:start');
            \\  module.exports = loadMainModule();
            \\  debugActivationPhase('loadLocal:done');
            \\  let activationExports = module.exports;
            \\  if (module.exports.activate) {{
            \\    const activationTimeoutMs = Number(globalThis._wizpActivationTimeoutMs || 30000);
            \\    debugActivationPhase('activate:start');
            \\    const activationRaw = module.exports.activate(extensionContext);
            \\    const activationIsThenable = !!(activationRaw && typeof activationRaw.then === 'function');
            \\    const activationPromise = Promise.resolve(activationRaw);
            \\    debugActivationPhase('activate:returned');
            \\    if (allowBackgroundActivation && activationIsThenable) {{
            \\      extensionRecord.isActive = true;
            \\      extensionRecord.activationState = 'pending';
            \\      extensionRecord.activationPromise = activationPromise.then(function(value) {{
            \\        debugActivationPhase('activate:async-resolved');
            \\        if (value !== undefined) activationExports = value;
            \\        extensionContext.extension.exports = activationExports;
            \\        extensionContext.extension.isActive = true;
            \\        extensionRecord.exports = activationExports;
            \\        extensionRecord.isActive = true;
            \\        extensionRecord.activationState = 'resolved';
            \\        extensionRecord.activate = async function() {{ return activationExports; }};
            \\        globalThis._wizpExtensions[packageJSON.name] = extensionRecord;
            \\        globalThis._wizpExtensions[extensionId] = extensionRecord;
            \\        delete globalThis._wizpActivationErrors['{s}'];
            \\        return activationExports;
            \\      }}).catch(function(error) {{
            \\        const message = String(error && error.message ? error.message : error);
            \\        extensionRecord.activationState = 'rejected';
            \\        extensionRecord.activationError = {{ message: message, name: String(error && error.name ? error.name : 'Error'), stack: String(error && error.stack ? error.stack : '') }};
            \\        globalThis._wizpActivationErrors['{s}'] = extensionRecord.activationError;
            \\        throw error;
            \\      }});
            \\      extensionRecord.activate = async function() {{ return extensionRecord.activationPromise; }};
            \\      debugActivationPhase('activate:async-pending');
            \\    }} else {{
            \\      const activationResult = activationTimeoutMs > 0
            \\        ? await Promise.race([
            \\            activationPromise,
            \\            new Promise(resolve => setTimeout(() => resolve({{ __wizpActivationTimedOut: true, timeoutMs: activationTimeoutMs }}), activationTimeoutMs))
            \\          ])
            \\        : await activationPromise;
            \\      if (activationResult && activationResult.__wizpActivationTimedOut) {{
            \\        globalThis._wizpActivationErrors['{s}'] = {{ message: 'Activation timed out after ' + activationResult.timeoutMs + 'ms', name: 'ActivationTimeout', timeoutMs: activationResult.timeoutMs }};
            \\        return {{ activated: false, timeoutMs: activationResult.timeoutMs }};
            \\      }}
            \\      if (activationResult !== undefined) activationExports = activationResult;
            \\    }}
            \\  }}
            \\  debugActivationPhase('activate:done');
            \\  extensionContext.extension.exports = activationExports;
            \\  extensionContext.extension.isActive = true;
            \\  extensionRecord.exports = activationExports;
            \\  extensionRecord.isActive = true;
            \\  extensionRecord.activationState = extensionRecord.activationState || 'resolved';
            \\  if (extensionRecord.activationState !== 'pending') extensionRecord.activate = async function() {{ return activationExports; }};
            \\  globalThis._wizpExtensions[packageJSON.name] = extensionRecord;
            \\  globalThis._wizpExtensions[extensionId] = extensionRecord;
            \\  delete globalThis._wizpActivationErrors['{s}'];
            \\  return {{ activated: true, pending: extensionRecord.activationState === 'pending' }};
            \\}})()).catch(function(error) {{
            \\  const message = String(error && error.message ? error.message : error);
            \\  globalThis._wizpActivationErrors['{s}'] = {{ message: message, name: String(error && error.name ? error.name : 'Error'), stack: String(error && error.stack ? error.stack : '') }};
            \\  return {{ activated: false, error: message }};
            \\}});
        , .{
            ext.id,
            ext.path,
            normalized_main_path,
            module_map_json,
            ext.path,
            storage_root,
            ext.id,
            ext.id,
            ext.id,
            ext.id,
            ext.publisher,
            ext.name,
            ext.version,
            ext.ai_key,
            ext.package_json_raw,
            if (ExtensionPolicy.allowBackgroundActivation(self.allocator, ext.publisher, ext.id)) "true" else "false",
            ext.path,
            ext.path,
            ext.path,
            ext.id,
            ext.id,
            ext.id,
            ext.id,
            ext.id,
            ext.id,
            ext.id,
            ext.id,
            ext.id,
        });
        defer self.allocator.free(wrapper);

        const activation_timeout_ms = self.activationTimeoutMs();
        if (debug) std.debug.print("WIZP ExtHost: activateExtension {s} eval:start timeout={}ms\n", .{ ext.id, activation_timeout_ms });
        const result = self.engine.evalStringTimeoutMs(wrapper, activation_timeout_ms) catch |err| {
            if (err == error.Timeout) {
                std.debug.print("WIZP ExtHost: activation for {s} exceeded host deadline ({}ms); restarting JS engine\n", .{ ext.id, activation_timeout_ms });
                try self.engine.restart();
                try self.injectExtensionAPI();
                try self.recordActivationError(ext.id, "ActivationHostTimeout", "Activation exceeded host deadline; JS extension host was restarted to preserve responsiveness.");
                return error.ActivationFailed;
            }
            return err;
        };
        defer self.allocator.free(result);
        const raw_result = stripEngineResult(result);
        if (raw_result.len == 0 or
            std.mem.indexOf(u8, raw_result, "\"activated\":false") != null or
            std.mem.indexOf(u8, raw_result, "\"error\"") != null or
            std.mem.indexOf(u8, raw_result, "\"timeoutMs\"") != null)
        {
            return error.ActivationFailed;
        }
        try self.activated.put(self.allocator, ext.id, {});

        std.debug.print("WIZP ExtHost: activated {s}\n", .{ext.name});
    }

    fn activationTimeoutMs(self: *Self) u32 {
        return ExtensionPolicy.timeoutMs(self.allocator, "WIZP_EXTENSION_ACTIVATION_TIMEOUT_MS", 30000);
    }

    fn diagnosticRpcTimeoutMs(self: *Self) u32 {
        return ExtensionPolicy.timeoutMs(self.allocator, "WIZP_EXTENSION_DIAGNOSTIC_RPC_TIMEOUT_MS", 1500);
    }

    fn recordActivationError(self: *Self, id: []const u8, name: []const u8, message: []const u8) !void {
        var id_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer id_buf.deinit();
        try writeJsonString(&id_buf.writer, id);
        var name_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer name_buf.deinit();
        try writeJsonString(&name_buf.writer, name);
        var message_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer message_buf.deinit();
        try writeJsonString(&message_buf.writer, message);
        const js = try std.fmt.allocPrint(self.allocator,
            \\globalThis._wizpActivationErrors = globalThis._wizpActivationErrors || {{}};
            \\globalThis._wizpActivationErrors[{s}] = {{ message: {s}, name: {s} }};
        , .{ id_buf.written(), message_buf.written(), name_buf.written() });
        defer self.allocator.free(js);
        try self.engine.evalVoid(js, "activation-error-record");
    }

    fn preflightJavaRuntimeUnavailable(self: *Self, ext: Extension) !bool {
        if (!std.mem.eql(u8, ext.publisher, "redhat") or !std.mem.eql(u8, ext.id, "java")) return false;

        const result = try self.engine.evalString(
            \\(function() {
            \\  const cfg = globalThis._wizpContext.workspace.getConfiguration('java');
            \\  const configuredPath = cfg.get('jdt.ls.java.home') || cfg.get('home');
            \\  return configuredPath && typeof configuredPath === 'string' ? configuredPath : null;
            \\})()
        , "java-runtime-preflight");
        defer self.allocator.free(result);
        const raw = stripEngineResult(result);
        if (raw.len == 0 or std.mem.eql(u8, raw, "null")) return false;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch return false;
        defer parsed.deinit();
        const configured_path = switch (parsed.value) {
            .string => |path| path,
            else => return false,
        };
        if (configured_path.len == 0 or javaRuntimePathExists(configured_path)) return false;

        var message_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer message_buf.deinit();
        try message_buf.writer.print(
            "Java JDT runtime unavailable: configured JDK path {s} is missing or inaccessible.",
            .{configured_path},
        );

        var message_json: std.Io.Writer.Allocating = .init(self.allocator);
        defer message_json.deinit();
        try writeJsonString(&message_json.writer, message_buf.written());
        const js = try std.fmt.allocPrint(self.allocator,
            \\globalThis._wizpActivationErrors = globalThis._wizpActivationErrors || {{}};
            \\globalThis._wizpActivationErrors['java'] = {{ message: {s}, name: 'JavaRuntimeUnavailable', stack: '' }};
            \\globalThis._wizp_uiQueue = globalThis._wizp_uiQueue || [];
            \\globalThis._wizp_uiQueue.push({{ type: 'message', severity: 'error', source: 'redhat.java', message: {s}, items: [{{ label: 'Open settings', command: 'workbench.action.openSettings', arguments: ['java.jdt.ls.java.home'] }}] }});
        , .{ message_json.written(), message_json.written() });
        defer self.allocator.free(js);
        try self.engine.evalVoid(js, "java-runtime-preflight-error");
        return true;
    }

    fn hasActivationError(self: *Self, id: []const u8) !bool {
        const js = try std.fmt.allocPrint(self.allocator, "Boolean(globalThis._wizpActivationErrors && globalThis._wizpActivationErrors['{s}'])", .{id});
        defer self.allocator.free(js);
        const result = try self.engine.evalString(js, "activationErrorCheck");
        defer self.allocator.free(result);
        const raw = stripEngineResult(result);
        return std.mem.eql(u8, raw, "true");
    }

    /// Deactivate an extension.
    fn deactivateExtension(self: *Self, id: []const u8) ![]u8 {
        const code = try std.fmt.allocPrint(self.allocator,
            \\Promise.resolve((function() {{
            \\  const extension = globalThis._wizpExtensions['{s}'];
            \\  if (!extension) return {{ deactivated: false, reason: 'missing' }};
            \\  const extensionExports = extension.exports || extension;
            \\  if (extensionExports.deactivate) return Promise.resolve(extensionExports.deactivate()).then(function(value) {{
            \\    delete globalThis._wizpExtensions['{s}'];
            \\    return {{ deactivated: true, value: value === undefined ? null : value, log: globalThis.__wizpDeactivateSmoke || [] }};
            \\  }});
            \\  delete globalThis._wizpExtensions['{s}'];
            \\  return {{ deactivated: true, value: null, log: globalThis.__wizpDeactivateSmoke || [] }};
            \\}})())
        , .{ id, id, id });
        defer self.allocator.free(code);
        const result = self.engine.evalString(code, "deactivate") catch |err| {
            _ = self.activated.swapRemove(id);
            return err;
        };
        defer self.allocator.free(result);
        _ = self.activated.swapRemove(id);
        const raw = stripEngineResult(result);
        const result_json = if (raw.len == 0 or std.mem.eql(u8, raw, "undefined")) "{\"deactivated\":true}" else raw;
        return try self.allocator.dupe(u8, result_json);
    }

    /// Inject the VS Code Extension API shim into the JS engine.
    fn injectExtensionAPI(self: *Self) !void {
        try self.engine.evalVoid(
            \\(async function() {
            \\  try { globalThis._wizpNativeFs = await import('node:fs'); } catch (_) { globalThis._wizpNativeFs = null; }
            \\  try { globalThis._wizpNativeChildProcess = await import('node:child_process'); } catch (_) { globalThis._wizpNativeChildProcess = null; }
            \\  try { globalThis._wizpNativeHttp = await import('node:http'); } catch (_) { globalThis._wizpNativeHttp = null; }
            \\  try { globalThis._wizpNativeHttps = await import('node:https'); } catch (_) { globalThis._wizpNativeHttps = null; }
            \\  return true;
            \\})()
        , "native-modules");

        // Initialize extension registry
        try self.engine.evalVoid(
            \\globalThis._wizpExtensions = {};
            \\globalThis._wizpActivationErrors = {};
            \\globalThis._wizp_uiQueue = [];
            \\globalThis._wizp_uiResolvers = {};
            \\globalThis._wizp_disposableId = 0;
            \\globalThis._wizpContextKeys = {};
            \\globalThis._wizpPortAttributesProviders = [];
            \\globalThis._wizpDocuments = {};
            \\globalThis._wizpVisibleTextEditors = [];
            \\globalThis._wizpActiveTextEditor = null;
            \\globalThis._wizpTextDocumentListeners = { open: [], change: [], save: [], close: [] };
            \\globalThis._wizpTerminals = [];
            \\globalThis._wizpActiveTerminal = null;
            \\globalThis._wizpTerminalListeners = { open: [], close: [], active: [] };
            \\globalThis._wizpTerminalDataListeners = [];
            \\globalThis._wizpTerminalShellExecutionListeners = { start: [], end: [] };
            \\globalThis._wizpTerminalShellIntegrationListeners = [];
            \\globalThis._wizpTaskExecutions = [];
            \\globalThis._wizp_debugVisualizationTreeProviders = {};
            \\globalThis._wizp_debugVisualizationProviders = {};
            \\globalThis._wizpMementoStores = {};
            \\globalThis._wizpSecretStores = {};
            \\globalThis._wizpEnvCollections = {};
            \\globalThis._wizpDiagnosticCollections = {};
            \\globalThis._wizpDecorationTypes = {};
            \\globalThis._wizpEditorDecorations = {};
            \\if (!globalThis._wizpTimersWrapped) {
            \\  globalThis._wizpTimersWrapped = true;
            \\  const nativeSetTimeout = typeof globalThis.setTimeout === 'function' ? globalThis.setTimeout.bind(globalThis) : null;
            \\  const nativeClearTimeout = typeof globalThis.clearTimeout === 'function' ? globalThis.clearTimeout.bind(globalThis) : function() {};
            \\  const nativeSetInterval = typeof globalThis.setInterval === 'function' ? globalThis.setInterval.bind(globalThis) : null;
            \\  const nativeClearInterval = typeof globalThis.clearInterval === 'function' ? globalThis.clearInterval.bind(globalThis) : function() {};
            \\  const normalizeTimerCallback = function(callback, args) {
            \\    if (typeof callback === 'function') {
            \\      return function() { return callback.apply(globalThis, args); };
            \\    }
            \\    if (typeof callback === 'string') {
            \\      return function() { return (0, eval)(callback); };
            \\    }
            \\    return function() {};
            \\  };
            \\  globalThis.setTimeout = function(callback, delay) {
            \\    const args = Array.prototype.slice.call(arguments, 2);
            \\    return nativeSetTimeout ? nativeSetTimeout(normalizeTimerCallback(callback, args), Number(delay) || 0) : 0;
            \\  };
            \\  globalThis.clearTimeout = nativeClearTimeout;
            \\  globalThis.setInterval = function(callback, delay) {
            \\    const args = Array.prototype.slice.call(arguments, 2);
            \\    return nativeSetInterval ? nativeSetInterval(normalizeTimerCallback(callback, args), Number(delay) || 0) : 0;
            \\  };
            \\  globalThis.clearInterval = nativeClearInterval;
            \\  globalThis.setImmediate = typeof globalThis.setImmediate === 'function' ? globalThis.setImmediate.bind(globalThis) : function(callback) {
            \\    const args = Array.prototype.slice.call(arguments, 1);
            \\    return globalThis.setTimeout.apply(globalThis, [callback, 0].concat(args));
            \\  };
            \\  globalThis.clearImmediate = typeof globalThis.clearImmediate === 'function' ? globalThis.clearImmediate.bind(globalThis) : globalThis.clearTimeout;
            \\  globalThis._wizpNodeTimers = {
            \\    setTimeout: globalThis.setTimeout,
            \\    clearTimeout: globalThis.clearTimeout,
            \\    setInterval: globalThis.setInterval,
            \\    clearInterval: globalThis.clearInterval,
            \\    setImmediate: globalThis.setImmediate,
            \\    clearImmediate: globalThis.clearImmediate
            \\  };
            \\}
            \\globalThis._wizpFileDecorationProviders = [];
            \\globalThis._wizpCodeLensProviders = [];
            \\globalThis._wizpInlayHintProviders = [];
            \\globalThis._wizpSemanticTokenProviders = [];
            \\globalThis._wizpDocumentRangeSemanticTokenProviders = [];
            \\globalThis._wizpFoldingRangeProviders = [];
            \\globalThis._wizpDocumentSymbolProviders = [];
            \\globalThis._wizpSelectionRangeProviders = [];
            \\globalThis._wizpWorkspaceSymbolProviders = [];
            \\globalThis._wizpInlineValuesProviders = [];
            \\globalThis._wizpInlineCompletionProviders = [];
            \\globalThis._wizpCompletionProviders = [];
            \\globalThis._wizpColorProviders = [];
            \\globalThis._wizpHoverProviders = [];
            \\globalThis._wizpSignatureHelpProviders = [];
            \\globalThis._wizpDefinitionProviders = [];
            \\globalThis._wizpDeclarationProviders = [];
            \\globalThis._wizpTypeDefinitionProviders = [];
            \\globalThis._wizpImplementationProviders = [];
            \\globalThis._wizpReferenceProviders = [];
            \\globalThis._wizpRenameProviders = [];
            \\globalThis._wizpCodeActionProviders = [];
            \\globalThis._wizpDocumentHighlightProviders = [];
            \\globalThis._wizpDocumentLinkProviders = [];
            \\globalThis._wizpDocumentFormattingProviders = [];
            \\globalThis._wizpRangeFormattingProviders = [];
            \\globalThis._wizpOnTypeFormattingProviders = [];
            \\globalThis._wizpCallHierarchyProviders = [];
            \\globalThis._wizpTypeHierarchyProviders = [];
            \\globalThis._wizpEmitTerminalData = function(terminal, data) {
            \\  if (!terminal || terminal._disposed) return;
            \\  const text = String(data || '');
            \\  globalThis._wizp_uiQueue.push({type: 'terminalData', id: terminal.id, name: terminal.name, data: text});
            \\  const event = { terminal: terminal, data: text };
            \\  for (const callback of globalThis._wizpTerminalDataListeners.slice()) {
            \\    try { callback(event); } catch (_) {}
            \\  }
            \\};
            \\globalThis._wizpEmitTerminalShellIntegrationChange = function(terminal) {
            \\  if (!terminal || terminal._disposed || !terminal.shellIntegration) return;
            \\  const event = { terminal: terminal, shellIntegration: terminal.shellIntegration };
            \\  for (const callback of globalThis._wizpTerminalShellIntegrationListeners.slice()) {
            \\    try { callback(event); } catch (_) {}
            \\  }
            \\};
        , "init");

        // Inject require() shim
        try self.engine.evalVoid(
            \\globalThis._wizpRequire = function(moduleName) {
            \\  // Basic require() for extension interop
            \\  const nativeModule = function(name) {
            \\    try {
            \\      return typeof require === 'function' ? require(name) : null;
            \\    } catch (_) {
            \\      return null;
            \\    }
            \\  };
            \\  if (moduleName === 'vscode') return globalThis._wizpContext;
            \\  if (moduleName === 'module' || moduleName === 'node:module') return globalThis._wizpNodeModule;
            \\  if (moduleName === 'console' || moduleName === 'node:console') return nativeModule('node:console') || globalThis._wizpNodeConsole;
            \\  if (moduleName === 'async_hooks' || moduleName === 'node:async_hooks') return globalThis._wizpNodeAsyncHooks;
            \\  if (moduleName === 'path' || moduleName === 'node:path') return globalThis._wizpNodePath;
            \\  if (moduleName === 'path/posix' || moduleName === 'node:path/posix') return globalThis._wizpNodePath.posix;
            \\  if (moduleName === 'os' || moduleName === 'node:os') return globalThis._wizpNodeOs;
            \\  if (moduleName === 'process' || moduleName === 'node:process') return globalThis._wizpNodeProcess;
            \\  if (moduleName === 'util' || moduleName === 'node:util') return nativeModule('node:util') || globalThis._wizpNodeUtil;
            \\  if (moduleName === 'util/types' || moduleName === 'node:util/types') {
            \\    const utilModule = nativeModule('node:util') || globalThis._wizpNodeUtil || {};
            \\    return nativeModule('node:util/types') || utilModule.types || {};
            \\  }
            \\  if (moduleName === 'assert' || moduleName === 'node:assert' || moduleName === 'assert/strict' || moduleName === 'node:assert/strict') return globalThis._wizpNodeAssert;
            \\  if (moduleName === 'url' || moduleName === 'node:url') return globalThis._wizpNodeUrl;
            \\  if (moduleName === 'fs' || moduleName === 'node:fs') return globalThis._wizpNodeFs;
            \\  if (moduleName === 'fs/promises' || moduleName === 'node:fs/promises') return globalThis._wizpNodeFs.promises;
            \\  if (moduleName === 'buffer' || moduleName === 'node:buffer') return nativeModule('node:buffer') || globalThis._wizpNodeBuffer;
            \\  if (moduleName === 'crypto' || moduleName === 'node:crypto') return globalThis._wizpNodeCrypto;
            \\  if (moduleName === 'events' || moduleName === 'node:events') return nativeModule('node:events') || nativeModule('events') || globalThis._wizpNodeEvents;
            \\  if (moduleName === 'repl' || moduleName === 'node:repl') return globalThis._wizpNodeRepl;
            \\  if (moduleName === 'readline' || moduleName === 'node:readline') return globalThis._wizpNodeReadline;
            \\  if (moduleName === 'readline/promises' || moduleName === 'node:readline/promises') return globalThis._wizpNodeReadlinePromises;
            \\  if (moduleName === 'stream' || moduleName === 'node:stream') return nativeModule('node:stream') || nativeModule('stream') || globalThis._wizpNodeStream;
            \\  if (moduleName === 'stream/consumers' || moduleName === 'node:stream/consumers') return nativeModule('node:stream/consumers') || globalThis._wizpNodeStreamConsumers;
            \\  if (moduleName === 'stream/promises' || moduleName === 'node:stream/promises') return nativeModule('node:stream/promises') || globalThis._wizpNodeStreamPromises;
            \\  if (moduleName === 'tty' || moduleName === 'node:tty') return nativeModule('node:tty') || globalThis._wizpNodeTty;
            \\  if (moduleName === 'string_decoder' || moduleName === 'node:string_decoder') return nativeModule('node:string_decoder') || globalThis._wizpNodeStringDecoder;
            \\  if (moduleName === 'child_process' || moduleName === 'node:child_process') return globalThis._wizpNodeChildProcess;
            \\  if (moduleName === 'http' || moduleName === 'node:http') return globalThis._wizpNodeHttp;
            \\  if (moduleName === 'https' || moduleName === 'node:https') return globalThis._wizpNodeHttps;
            \\  if (moduleName === 'http2' || moduleName === 'node:http2') return nativeModule('node:http2') || { constants: {}, connect: function() { throw new Error('http2 is unavailable in WIZP extension host'); }, createServer: function() { throw new Error('http2 is unavailable in WIZP extension host'); }, createSecureServer: function() { throw new Error('http2 is unavailable in WIZP extension host'); } };
            \\  if (moduleName === 'dns' || moduleName === 'node:dns') return globalThis._wizpNodeDns;
            \\  if (moduleName === 'dns/promises' || moduleName === 'node:dns/promises') return globalThis._wizpNodeDns && globalThis._wizpNodeDns.promises;
            \\  if (moduleName === 'net' || moduleName === 'node:net') return globalThis._wizpNodeNet;
            \\  if (moduleName === 'tls' || moduleName === 'node:tls') return globalThis._wizpNodeTls;
            \\  if (moduleName === 'zlib' || moduleName === 'node:zlib') return globalThis._wizpNodeZlib;
            \\  if (moduleName === 'punycode' || moduleName === 'node:punycode') return globalThis._wizpNodePunycode;
            \\  if (moduleName === 'querystring' || moduleName === 'node:querystring') return nativeModule('node:querystring') || nativeModule('querystring');
            \\  if (moduleName === 'perf_hooks' || moduleName === 'node:perf_hooks') return globalThis._wizpNodePerfHooks;
            \\  if (moduleName === 'timers' || moduleName === 'node:timers') return globalThis._wizpNodeTimers;
            \\  if (moduleName === 'timers/promises' || moduleName === 'node:timers/promises') return nativeModule('node:timers/promises') || {
            \\    setTimeout: function(delay, value) { return new Promise(function(resolve) { setTimeout(function() { resolve(value); }, delay || 0); }); },
            \\    setImmediate: function(value) { return new Promise(function(resolve) { (typeof setImmediate === 'function' ? setImmediate : setTimeout)(function() { resolve(value); }, 0); }); }
            \\  };
            \\  if (moduleName === 'worker_threads' || moduleName === 'node:worker_threads') return nativeModule('node:worker_threads') || {
            \\    isMainThread: true,
            \\    parentPort: null,
            \\    workerData: null,
            \\    threadId: 0,
            \\    MessageChannel: globalThis.MessageChannel,
            \\    MessagePort: globalThis.MessagePort,
            \\    Worker: class { constructor() { throw new Error('worker_threads are unavailable in WIZP extension host'); } }
            \\  };
            \\  if (moduleName === 'constants' || moduleName === 'node:constants') return globalThis._wizpNodeOs.constants;
            \\  throw new Error('Module not found: ' + moduleName);
            \\};
            \\globalThis._wizpNodePath = (function() {
            \\  const normalizeArray = function(parts, allowAboveRoot) {
            \\    const res = [];
            \\    for (const part of parts) {
            \\      if (!part || part === '.') continue;
            \\      if (part === '..') {
            \\        if (res.length && res[res.length - 1] !== '..') res.pop();
            \\        else if (allowAboveRoot) res.push('..');
            \\      } else {
            \\        res.push(part);
            \\      }
            \\    }
            \\    return res;
            \\  };
            \\  const normalize = function(path) {
            \\    path = String(path || '');
            \\    if (path.length === 0) return '.';
            \\    const absolute = path[0] === '/';
            \\    const trailing = path.endsWith('/');
            \\    let normalized = normalizeArray(path.split('/'), !absolute).join('/');
            \\    if (!normalized && !absolute) normalized = '.';
            \\    if (normalized && trailing) normalized += '/';
            \\    return (absolute ? '/' : '') + normalized;
            \\  };
            \\  const join = function() {
            \\    const joined = Array.prototype.slice.call(arguments).filter(function(part) { return part !== undefined && part !== null && String(part).length > 0; }).join('/');
            \\    return normalize(joined);
            \\  };
            \\  const resolve = function() {
            \\    const parts = Array.prototype.slice.call(arguments).filter(function(part) { return part !== undefined && part !== null && String(part).length > 0; }).map(String);
            \\    let resolved = '';
            \\    for (let i = parts.length - 1; i >= 0; i--) {
            \\      const part = parts[i];
            \\      if (!part) continue;
            \\      resolved = part + '/' + resolved;
            \\      if (part[0] === '/') break;
            \\    }
            \\    if (resolved[0] !== '/') resolved = '/' + resolved;
            \\    if (resolved.length > 1 && resolved.endsWith('/')) resolved = resolved.slice(0, -1);
            \\    return normalize(resolved);
            \\  };
            \\  const relative = function(from, to) {
            \\    const fromParts = normalize(resolve(from)).split('/').filter(Boolean);
            \\    const toParts = normalize(resolve(to)).split('/').filter(Boolean);
            \\    let same = 0;
            \\    while (same < fromParts.length && same < toParts.length && fromParts[same] === toParts[same]) same++;
            \\    const up = new Array(fromParts.length - same).fill('..');
            \\    return up.concat(toParts.slice(same)).join('/') || '';
            \\  };
            \\  const dirname = function(path) {
            \\    path = normalize(path);
            \\    if (path === '/') return '/';
            \\    const idx = path.lastIndexOf('/');
            \\    if (idx < 0) return '.';
            \\    if (idx === 0) return '/';
            \\    return path.slice(0, idx);
            \\  };
            \\  const basename = function(path, ext) {
            \\    path = normalize(path);
            \\    const base = path.slice(path.lastIndexOf('/') + 1);
            \\    return ext && base.endsWith(ext) ? base.slice(0, -String(ext).length) : base;
            \\  };
            \\  const extname = function(path) {
            \\    const base = basename(path);
            \\    const idx = base.lastIndexOf('.');
            \\    return idx > 0 ? base.slice(idx) : '';
            \\  };
            \\  const parse = function(path) {
            \\    path = String(path || '');
            \\    const root = path.startsWith('/') ? '/' : '';
            \\    const dir = dirname(path);
            \\    const base = basename(path);
            \\    const ext = extname(base);
            \\    const name = ext ? base.slice(0, -ext.length) : base;
            \\    return { root, dir, base, ext, name };
            \\  };
            \\  const formatPath = function(value) {
            \\    if (!value) return '';
            \\    const dir = value.dir || value.root || '';
            \\    const base = value.base || ((value.name || '') + (value.ext || ''));
            \\    return dir ? join(dir, base) : base;
            \\  };
            \\  return { sep: '/', delimiter: ':', posix: null, win32: null, normalize, join, resolve, relative, dirname, basename, extname, parse, format: formatPath, isAbsolute: function(path) { return String(path || '').startsWith('/'); } };
            \\})();
            \\globalThis._wizpNodePath.posix = globalThis._wizpNodePath;
            \\globalThis._wizpNodePath.win32 = globalThis._wizpNodePath;
            \\globalThis._wizpNodeProcess = {
            \\  env: Object.assign({}, globalThis._wizpProcessEnv || {}),
            \\  argv: ['wizp-extension-host'],
            \\  execPath: 'wizp',
            \\  platform: 'linux',
            \\  arch: 'x64',
            \\  versions: { node: 'shim', wizp: '0.1.0' },
            \\  cwd: function() { return globalThis._wizpCwd || '.'; },
            \\  nextTick: function(fn) { return Promise.resolve().then(fn); },
            \\  hrtime: function(previous) {
            \\    const millis = Date.now ? Date.now() : new Date().getTime();
            \\    let seconds = Math.floor(millis / 1000);
            \\    let nanos = Math.floor((millis - seconds * 1000) * 1000000);
            \\    if (Array.isArray(previous)) {
            \\      seconds -= Number(previous[0]) || 0;
            \\      nanos -= Number(previous[1]) || 0;
            \\      if (nanos < 0) { seconds -= 1; nanos += 1000000000; }
            \\    }
            \\    return [seconds, nanos];
            \\  },
            \\  binding: function(name) {
            \\    if (String(name || '') === 'natives') {
            \\      const natives = {};
            \\      for (const item of ['assert', 'async_hooks', 'buffer', 'child_process', 'console', 'crypto', 'dns', 'events', 'fs', 'http', 'https', 'module', 'net', 'os', 'path', 'process', 'querystring', 'readline', 'stream', 'stream/promises', 'string_decoder', 'tls', 'tty', 'url', 'util', 'zlib']) natives[item] = '';
            \\      return natives;
            \\    }
            \\    return {};
            \\  },
            \\  on: function(event, listener) { this._events = this._events || {}; (this._events[event] = this._events[event] || []).push(listener); return this; },
            \\  once: function(event, listener) { const self = this; const wrapped = function() { self.off(event, wrapped); listener.apply(null, arguments); }; return this.on(event, wrapped); },
            \\  off: function(event, listener) { const list = (this._events || {})[event] || []; const index = list.indexOf(listener); if (index >= 0) list.splice(index, 1); return this; },
            \\  emit: function(event) { const args = Array.prototype.slice.call(arguments, 1); for (const listener of (((this._events || {})[event] || []).slice())) { try { listener.apply(null, args); } catch (_) {} } return true; }
            \\};
            \\globalThis._wizpNodeProcess.hrtime.bigint = function() { return BigInt(Date.now ? Date.now() : new Date().getTime()) * 1000000n; };
            \\globalThis.process = globalThis.process || globalThis._wizpNodeProcess;
            \\try {
            \\  if (globalThis.process && typeof globalThis.process.on === 'function') {
            \\    globalThis.process.on('unhandledRejection', function(reason) {
            \\      const message = String(reason && reason.message ? reason.message : reason);
            \\      globalThis._wizpActivationErrors.__unhandledRejection = { message: message, name: String(reason && reason.name ? reason.name : 'UnhandledRejection'), stack: String(reason && reason.stack ? reason.stack : '') };
            \\      if (globalThis._wizp_uiQueue) globalThis._wizp_uiQueue.push({ type: 'extensionUnhandledRejection', message: message });
            \\    });
            \\    globalThis.process.on('uncaughtException', function(error) {
            \\      const message = String(error && error.message ? error.message : error);
            \\      globalThis._wizpActivationErrors.__uncaughtException = { message: message, name: String(error && error.name ? error.name : 'UncaughtException'), stack: String(error && error.stack ? error.stack : '') };
            \\      if (globalThis._wizp_uiQueue) globalThis._wizp_uiQueue.push({ type: 'extensionUncaughtException', message: message });
            \\    });
            \\  }
            \\} catch (_) {}
            \\globalThis._wizpNodeEvents = (function() {
            \\  function EventEmitter() { this._events = {}; this._maxListeners = EventEmitter.defaultMaxListeners; }
            \\  EventEmitter.prototype.on = function(event, listener) { return this.addListener(event, listener); };
            \\  EventEmitter.prototype.addListener = function(event, listener) {
            \\      if (typeof listener !== 'function') throw new TypeError('listener must be a function');
            \\      (this._events[event] = this._events[event] || []).push(listener);
            \\      return this;
            \\  };
            \\  EventEmitter.prototype.once = function(event, listener) {
            \\      const self = this;
            \\      function wrapped() { self.removeListener(event, wrapped); return listener.apply(this, arguments); }
            \\      wrapped.listener = listener;
            \\      return this.addListener(event, wrapped);
            \\  };
            \\  EventEmitter.prototype.off = function(event, listener) { return this.removeListener(event, listener); };
            \\  EventEmitter.prototype.removeListener = function(event, listener) {
            \\      const list = this._events[event] || [];
            \\      const index = list.findIndex(function(item) { return item === listener || item.listener === listener; });
            \\      if (index >= 0) list.splice(index, 1);
            \\      if (list.length === 0) delete this._events[event];
            \\      return this;
            \\  };
            \\  EventEmitter.prototype.removeAllListeners = function(event) {
            \\      if (event === undefined) this._events = {};
            \\      else delete this._events[event];
            \\      return this;
            \\  };
            \\  EventEmitter.prototype.emit = function(event) {
            \\      const args = Array.prototype.slice.call(arguments, 1);
            \\      const list = (this._events[event] || []).slice();
            \\      for (const listener of list) listener.apply(this, args);
            \\      return list.length > 0;
            \\  };
            \\  EventEmitter.prototype.listeners = function(event) { return (this._events[event] || []).map(function(item) { return item.listener || item; }); };
            \\  EventEmitter.prototype.rawListeners = function(event) { return (this._events[event] || []).slice(); };
            \\  EventEmitter.prototype.listenerCount = function(event) { return (this._events[event] || []).length; };
            \\  EventEmitter.prototype.eventNames = function() { return Object.keys(this._events); };
            \\  EventEmitter.prototype.setMaxListeners = function(count) { this._maxListeners = Number(count) || 0; return this; };
            \\  EventEmitter.prototype.getMaxListeners = function() { return this._maxListeners; };
            \\  EventEmitter.prototype.prependListener = function(event, listener) {
            \\      if (typeof listener !== 'function') throw new TypeError('listener must be a function');
            \\      (this._events[event] = this._events[event] || []).unshift(listener);
            \\      return this;
            \\  };
            \\  EventEmitter.prototype.prependOnceListener = function(event, listener) {
            \\      const self = this;
            \\      function wrapped() { self.removeListener(event, wrapped); return listener.apply(this, arguments); }
            \\      wrapped.listener = listener;
            \\      return this.prependListener(event, wrapped);
            \\  };
            \\  EventEmitter.defaultMaxListeners = 10;
            \\  EventEmitter.listenerCount = function(emitter, event) { return emitter && emitter.listenerCount ? emitter.listenerCount(event) : 0; };
            \\  EventEmitter.setMaxListeners = function(count) {
            \\    const value = Number(count);
            \\    const normalized = Number.isFinite(value) && value >= 0 ? value : 0;
            \\    const targets = Array.prototype.slice.call(arguments, 1);
            \\    if (targets.length === 0) {
            \\      EventEmitter.defaultMaxListeners = normalized;
            \\      return EventEmitter;
            \\    }
            \\    for (const target of targets) {
            \\      if (!target) continue;
            \\      if (typeof target.setMaxListeners === 'function') {
            \\        target.setMaxListeners(normalized);
            \\        continue;
            \\      }
            \\      if (typeof target.addEventListener === 'function' && typeof target.removeEventListener === 'function') {
            \\        try { target.__wizpMaxListeners = normalized; } catch (_) {}
            \\      }
            \\    }
            \\    return EventEmitter;
            \\  };
            \\  EventEmitter.getMaxListeners = function(target) {
            \\    if (!target) return EventEmitter.defaultMaxListeners;
            \\    if (typeof target.getMaxListeners === 'function') return target.getMaxListeners();
            \\    if (typeof target.addEventListener === 'function' && typeof target.removeEventListener === 'function') {
            \\      const value = target.__wizpMaxListeners;
            \\      return typeof value === 'number' ? value : EventEmitter.defaultMaxListeners;
            \\    }
            \\    return EventEmitter.defaultMaxListeners;
            \\  };
            \\  EventEmitter.addAbortListener = function(signal, listener) {
            \\    if (!signal || typeof signal.addEventListener !== 'function') throw new TypeError('signal must support addEventListener');
            \\    if (typeof listener !== 'function') throw new TypeError('listener must be a function');
            \\    const wrapped = function(event) {
            \\      try { signal.removeEventListener('abort', wrapped); } catch (_) {}
            \\      return listener.call(signal, event);
            \\    };
            \\    if (signal.aborted) {
            \\      if (typeof queueMicrotask === 'function') queueMicrotask(function() { wrapped({ type: 'abort', target: signal }); });
            \\      else setTimeout(function() { wrapped({ type: 'abort', target: signal }); }, 0);
            \\    } else {
            \\      signal.addEventListener('abort', wrapped, { once: true });
            \\    }
            \\    const disposable = {
            \\      dispose: function() {
            \\        try { signal.removeEventListener('abort', wrapped); } catch (_) {}
            \\      }
            \\    };
            \\    try {
            \\      if (typeof Symbol === 'function' && Symbol.dispose) disposable[Symbol.dispose] = disposable.dispose;
            \\    } catch (_) {}
            \\    return disposable;
            \\  };
            \\  EventEmitter.once = function(emitter, event) {
            \\    return new Promise(function(resolve) { emitter.once(event, function() { resolve(Array.prototype.slice.call(arguments)); }); });
            \\  };
            \\  EventEmitter.EventEmitter = EventEmitter;
            \\  EventEmitter.default = EventEmitter;
            \\  EventEmitter.once = EventEmitter.once;
            \\  EventEmitter.listenerCount = EventEmitter.listenerCount;
            \\  EventEmitter.getMaxListeners = EventEmitter.getMaxListeners;
            \\  EventEmitter.setMaxListeners = EventEmitter.setMaxListeners;
            \\  EventEmitter.addAbortListener = EventEmitter.addAbortListener;
            \\  return EventEmitter;
            \\})();
            \\globalThis._wizpNodeBuffer = (function() {
            \\  try {
            \\    if (typeof require === 'function') {
            \\      const nativeBuffer = require('node:buffer');
            \\      if (nativeBuffer && nativeBuffer.Buffer) return nativeBuffer;
            \\    }
            \\  } catch (_) {}
            \\  const encode = function(value) {
            \\    if (value instanceof Uint8Array) return value;
            \\    if (globalThis.TextEncoder) return new TextEncoder().encode(String(value || ''));
            \\    const text = String(value || '');
            \\    const bytes = new Uint8Array(text.length);
            \\    for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 255;
            \\    return bytes;
            \\  };
            \\  const decodeBase64 = function(value) {
            \\    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
            \\    const clean = String(value || '').replace(/[^A-Za-z0-9+/=]/g, '');
            \\    const bytes = [];
            \\    for (let i = 0; i < clean.length; i += 4) {
            \\      const a = alphabet.indexOf(clean[i]);
            \\      const b = alphabet.indexOf(clean[i + 1]);
            \\      const c = clean[i + 2] === '=' ? -1 : alphabet.indexOf(clean[i + 2]);
            \\      const d = clean[i + 3] === '=' ? -1 : alphabet.indexOf(clean[i + 3]);
            \\      if (a < 0 || b < 0) break;
            \\      const triplet = (a << 18) | (b << 12) | ((c < 0 ? 0 : c) << 6) | (d < 0 ? 0 : d);
            \\      bytes.push((triplet >> 16) & 255);
            \\      if (c >= 0) bytes.push((triplet >> 8) & 255);
            \\      if (d >= 0) bytes.push(triplet & 255);
            \\    }
            \\    return new Uint8Array(bytes);
            \\  };
            \\  const decode = function(bytes, encoding) {
            \\    encoding = String(encoding || 'utf8').toLowerCase();
            \\    if (encoding === 'hex') {
            \\      let hex = '';
            \\      for (let i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, '0');
            \\      return hex;
            \\    }
            \\    if (encoding === 'base64') {
            \\      const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
            \\      let out = '';
            \\      for (let i = 0; i < bytes.length; i += 3) {
            \\        const a = bytes[i];
            \\        const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
            \\        const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
            \\        const triplet = (a << 16) | (b << 8) | c;
            \\        out += chars[(triplet >> 18) & 63] + chars[(triplet >> 12) & 63] + (i + 1 < bytes.length ? chars[(triplet >> 6) & 63] : '=') + (i + 2 < bytes.length ? chars[triplet & 63] : '=');
            \\      }
            \\      return out;
            \\    }
            \\    if (globalThis.TextDecoder) return new TextDecoder('utf-8').decode(bytes);
            \\    let text = '';
            \\    for (let i = 0; i < bytes.length; i++) text += String.fromCharCode(bytes[i]);
            \\    return text;
            \\  };
            \\  class WizpBuffer extends Uint8Array {
            \\    static from(value, encoding) {
            \\      if (typeof value === 'string' && String(encoding || '').toLowerCase() === 'base64') return new WizpBuffer(decodeBase64(value));
            \\      if (value instanceof ArrayBuffer) return new WizpBuffer(value.slice(0));
            \\      if (ArrayBuffer.isView(value)) return new WizpBuffer(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
            \\      if (Array.isArray(value)) return new WizpBuffer(value);
            \\      return new WizpBuffer(encode(value, encoding));
            \\    }
            \\    static alloc(size, fill) {
            \\      const buffer = new WizpBuffer(Math.max(0, Number(size) || 0));
            \\      if (fill !== undefined) buffer.fill(typeof fill === 'string' ? (encode(fill)[0] || 0) : (Number(fill) || 0));
            \\      return buffer;
            \\    }
            \\    static allocUnsafe(size) { return new WizpBuffer(Math.max(0, Number(size) || 0)); }
            \\    static isBuffer(value) { return value instanceof WizpBuffer; }
            \\    static byteLength(value, encoding) { return WizpBuffer.from(value, encoding).length; }
            \\    static concat(list, totalLength) {
            \\      const buffers = (list || []).map(function(value) { return WizpBuffer.from(value); });
            \\      const length = totalLength === undefined ? buffers.reduce(function(sum, item) { return sum + item.length; }, 0) : Number(totalLength) || 0;
            \\      const out = new WizpBuffer(length);
            \\      let offset = 0;
            \\      for (const item of buffers) {
            \\        out.set(item.slice(0, Math.max(0, length - offset)), offset);
            \\        offset += item.length;
            \\        if (offset >= length) break;
            \\      }
            \\      return out;
            \\    }
            \\    toString(encoding, start, end) { return decode(this.slice(start || 0, end === undefined ? this.length : end), encoding); }
            \\  }
            \\  WizpBuffer.poolSize = 8192;
            \\  return { Buffer: WizpBuffer, SlowBuffer: WizpBuffer, INSPECT_MAX_BYTES: 50, constants: { MAX_LENGTH: 0x7fffffff, MAX_STRING_LENGTH: 0x1fffffff }, kMaxLength: 0x7fffffff, transcode: function(source) { return WizpBuffer.from(source); } };
            \\})();
            \\globalThis.Buffer = globalThis.Buffer || globalThis._wizpNodeBuffer.Buffer;
            \\globalThis._wizpNodeCrypto = (function() {
            \\  let seed = 0x12345678;
            \\  const nextByte = function() {
            \\    seed = (seed * 1664525 + 1013904223) >>> 0;
            \\    return (seed >>> 16) & 255;
            \\  };
            \\  const fillRandom = function(buffer) {
            \\    if (globalThis.crypto && typeof globalThis.crypto.getRandomValues === 'function') return globalThis.crypto.getRandomValues(buffer);
            \\    for (let i = 0; i < buffer.length; i++) buffer[i] = nextByte();
            \\    return buffer;
            \\  };
            \\  const randomBytes = function(size, callback) {
            \\    const buffer = globalThis._wizpNodeBuffer.Buffer.alloc(Math.max(0, Number(size) || 0));
            \\    fillRandom(buffer);
            \\    if (callback) Promise.resolve().then(function() { callback(null, buffer); });
            \\    return buffer;
            \\  };
            \\  const randomFillSync = function(buffer, offset, size) {
            \\    if (!buffer || typeof buffer.length !== 'number') throw new TypeError('buffer must be a Buffer or typed array');
            \\    const start = Math.max(0, Number(offset) || 0);
            \\    const end = size === undefined ? buffer.length : Math.min(buffer.length, start + Math.max(0, Number(size) || 0));
            \\    const view = buffer.subarray ? buffer.subarray(start, end) : Array.prototype.slice.call(buffer, start, end);
            \\    fillRandom(view);
            \\    if (!buffer.subarray) for (let i = start; i < end; i++) buffer[i] = view[i - start];
            \\    return buffer;
            \\  };
            \\  const randomFill = function(buffer, offset, size, callback) {
            \\    if (typeof offset === 'function') { callback = offset; offset = 0; size = undefined; }
            \\    else if (typeof size === 'function') { callback = size; size = undefined; }
            \\    const run = function() { return randomFillSync(buffer, offset, size); };
            \\    if (callback) {
            \\      Promise.resolve().then(function() { callback(null, run()); }, function(error) { callback(error); });
            \\      return undefined;
            \\    }
            \\    return Promise.resolve().then(run);
            \\  };
            \\  const randomUUID = function() {
            \\    const bytes = randomBytes(16);
            \\    bytes[6] = (bytes[6] & 0x0f) | 0x40;
            \\    bytes[8] = (bytes[8] & 0x3f) | 0x80;
            \\    const hex = bytes.toString('hex');
            \\    return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
            \\  };
            \\  const makeDigest = function(seedText) {
            \\    let state = 2166136261;
            \\    const chunks = [];
            \\    const api = {
            \\      update: function(value) {
            \\        const bytes = globalThis._wizpNodeBuffer.Buffer.from(value === undefined ? '' : value);
            \\        chunks.push(bytes);
            \\        for (let i = 0; i < bytes.length; i++) {
            \\          state ^= bytes[i];
            \\          state = Math.imul(state, 16777619) >>> 0;
            \\        }
            \\        return api;
            \\      },
            \\      digest: function(encoding) {
            \\        const out = globalThis._wizpNodeBuffer.Buffer.alloc(32);
            \\        let value = state;
            \\        for (let i = 0; i < out.length; i++) {
            \\          value = Math.imul(value ^ i, 16777619) >>> 0;
            \\          out[i] = (value >>> ((i % 4) * 8)) & 255;
            \\        }
            \\        return encoding ? out.toString(encoding) : out;
            \\      }
            \\    };
            \\    if (seedText) api.update(seedText);
            \\    return api;
            \\  };
            \\  const createHash = function(algorithm) { return makeDigest(String(algorithm || 'sha256')); };
            \\  const createHmac = function(algorithm, key) { return makeDigest(String(algorithm || 'sha256') + ':' + String(key || '')); };
            \\  const getRandomValues = function(array) { return fillRandom(array); };
            \\  const timingSafeEqual = function(a, b) {
            \\    a = globalThis._wizpNodeBuffer.Buffer.from(a);
            \\    b = globalThis._wizpNodeBuffer.Buffer.from(b);
            \\    if (a.length !== b.length) throw new Error('Input buffers must have the same length');
            \\    let diff = 0;
            \\    for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
            \\    return diff === 0;
            \\  };
            \\  const subtle = { digest: async function(algorithm, data) { return createHash(String(algorithm || 'sha256')).update(globalThis._wizpNodeBuffer.Buffer.from(data || [])).digest().buffer; } };
            \\  return { randomBytes, randomFill, randomFillSync, randomUUID, pseudoRandomBytes: randomBytes, createHash, createHmac, getRandomValues, timingSafeEqual, webcrypto: { getRandomValues, subtle }, subtle };
            \\})();
            \\globalThis._wizpNodeUtil = (function() {
            \\  const inspect = function(value, seen) {
            \\    if (value === undefined) return 'undefined';
            \\    if (value === null) return 'null';
            \\    if (typeof value === 'string') return value;
            \\    if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') return String(value);
            \\    if (typeof value === 'symbol') return value.toString();
            \\    if (typeof value === 'function') return '[Function' + (value.name ? ': ' + value.name : '') + ']';
            \\    if (value instanceof Error) return value.stack || (value.name ? value.name + ': ' : '') + (value.message || String(value));
            \\    if (value instanceof Date) return isNaN(value.getTime()) ? value.toString() : value.toISOString();
            \\    if (value instanceof RegExp) return value.toString();
            \\    if (typeof ArrayBuffer !== 'undefined' && value instanceof ArrayBuffer) return '[ArrayBuffer byteLength=' + value.byteLength + ']';
            \\    if (typeof ArrayBuffer !== 'undefined' && typeof ArrayBuffer.isView === 'function' && ArrayBuffer.isView(value)) {
            \\      const ctorName = value && value.constructor && value.constructor.name ? value.constructor.name : 'TypedArray';
            \\      try { return ctorName + ' [' + Array.prototype.join.call(value, ', ') + ']'; } catch (_) { return '[' + ctorName + ']'; }
            \\    }
            \\    seen = Array.isArray(seen) ? seen : [];
            \\    if (seen.indexOf(value) >= 0) return '[Circular]';
            \\    const nextSeen = seen.concat([value]);
            \\    if (Array.isArray(value)) return '[' + value.map(function(item) { return inspect(item, nextSeen); }).join(', ') + ']';
            \\    if (value instanceof Map) {
            \\      return 'Map(' + value.size + ') {' + Array.from(value.entries()).map(function(entry) {
            \\        return inspect(entry[0], nextSeen) + ' => ' + inspect(entry[1], nextSeen);
            \\      }).join(', ') + '}';
            \\    }
            \\    if (value instanceof Set) {
            \\      return 'Set(' + value.size + ') {' + Array.from(value.values()).map(function(item) { return inspect(item, nextSeen); }).join(', ') + '}';
            \\    }
            \\    try {
            \\      return JSON.stringify(value, function(_key, item) {
            \\        if (item instanceof Error) return item.stack || (item.name ? item.name + ': ' : '') + (item.message || String(item));
            \\        if (typeof item === 'bigint') return String(item);
            \\        if (typeof item === 'function') return '[Function' + (item.name ? ': ' + item.name : '') + ']';
            \\        if (typeof item === 'symbol') return item.toString();
            \\        return item;
            \\      });
            \\    } catch (_) {
            \\      try { return String(value); } catch (__){ return '[Object]'; }
            \\    }
            \\  };
            \\  const format = function(first) {
            \\    const args = Array.prototype.slice.call(arguments, 1);
            \\    if (typeof first !== 'string') return [first].concat(args).map(inspect).join(' ');
            \\    let index = 0;
            \\    const rendered = first.replace(/%[sdjifoO%]/g, function(token) {
            \\      if (token === '%%') return '%';
            \\      if (index >= args.length) return token;
            \\      const value = args[index++];
            \\      if (token === '%d' || token === '%i') return String(parseInt(value, 10));
            \\      if (token === '%f') return String(parseFloat(value));
            \\      if (token === '%j' || token === '%o' || token === '%O') return inspect(value);
            \\      return String(value);
            \\    });
            \\    return rendered + (index < args.length ? ' ' + args.slice(index).map(inspect).join(' ') : '');
            \\  };
            \\  const inherits = function(ctor, superCtor) {
            \\    if (!ctor) throw new TypeError('ctor is required');
            \\    if (superCtor && !superCtor.prototype && superCtor.default && superCtor.default.prototype) superCtor = superCtor.default;
            \\    if (superCtor && !superCtor.prototype && superCtor.EventEmitter && superCtor.EventEmitter.prototype) superCtor = superCtor.EventEmitter;
            \\    if (superCtor && !superCtor.prototype && superCtor.Stream && superCtor.Stream.prototype) superCtor = superCtor.Stream;
            \\    if (!superCtor || !superCtor.prototype) superCtor = function WizpEmptySuperCtor() {};
            \\    ctor.super_ = superCtor;
            \\    ctor.prototype = Object.create(superCtor.prototype, { constructor: { value: ctor, enumerable: false, writable: true, configurable: true } });
            \\  };
            \\  const promisify = function(fn) {
            \\    return function() {
            \\      const args = Array.prototype.slice.call(arguments);
            \\      return new Promise(function(resolve, reject) {
            \\        fn.apply(this, args.concat(function(err, value) { err ? reject(err) : resolve(value); }));
            \\      });
            \\    };
            \\  };
            \\  const callbackify = function(fn) {
            \\    return function() {
            \\      const args = Array.prototype.slice.call(arguments);
            \\      const cb = args.pop();
            \\      Promise.resolve(fn.apply(this, args)).then(function(value) { cb(null, value); }, function(err) { cb(err); });
            \\    };
            \\  };
            \\  const deprecate = function(fn) {
            \\    return function() { return fn.apply(this, arguments); };
            \\  };
            \\  const debuglog = function() { return function() {}; };
            \\  const types = {
            \\    isNativeError: function(value) { return value instanceof Error; },
            \\    isPromise: function(value) { return !!value && typeof value.then === 'function'; },
            \\    isRegExp: function(value) { return value instanceof RegExp; },
            \\    isDate: function(value) { return value instanceof Date; },
            \\    isMap: function(value) { return value instanceof Map; },
            \\    isSet: function(value) { return value instanceof Set; },
            \\    isArrayBuffer: function(value) { return value instanceof ArrayBuffer; },
            \\    isTypedArray: function(value) { return ArrayBuffer.isView(value) && !(value instanceof DataView); },
            \\    isProxy: function() { return false; }
            \\  };
            \\  return { format, inspect, inherits, promisify, callbackify, deprecate, debuglog, isDeepStrictEqual: function(a, b) { try { return JSON.stringify(a) === JSON.stringify(b); } catch (_) { return a === b; } }, types, TextEncoder: globalThis.TextEncoder, TextDecoder: globalThis.TextDecoder };
            \\})();
            \\globalThis._wizpNodeAssert = (function() {
            \\  const fail = function(message) { throw new Error(message || 'Assertion failed'); };
            \\  const sameJson = function(a, b) {
            \\    try { return JSON.stringify(a) === JSON.stringify(b); } catch (_) { return a === b; }
            \\  };
            \\  const assert = function(value, message) { if (!value) fail(message); };
            \\  assert.ok = assert;
            \\  assert.fail = fail;
            \\  assert.equal = function(actual, expected, message) { if (actual != expected) fail(message || ('Expected ' + actual + ' == ' + expected)); };
            \\  assert.notEqual = function(actual, expected, message) { if (actual == expected) fail(message || ('Expected ' + actual + ' != ' + expected)); };
            \\  assert.strictEqual = function(actual, expected, message) { if (actual !== expected) fail(message || ('Expected ' + actual + ' === ' + expected)); };
            \\  assert.notStrictEqual = function(actual, expected, message) { if (actual === expected) fail(message || ('Expected ' + actual + ' !== ' + expected)); };
            \\  assert.deepStrictEqual = function(actual, expected, message) { if (!sameJson(actual, expected)) fail(message || 'Expected values to be deeply equal'); };
            \\  assert.throws = function(fn, expected, message) {
            \\    try { fn(); } catch (error) {
            \\      if (expected instanceof RegExp && !expected.test(String(error && error.message ? error.message : error))) fail(message || 'Thrown error did not match');
            \\      return error;
            \\    }
            \\    fail(message || 'Missing expected exception');
            \\  };
            \\  assert.doesNotThrow = function(fn, message) { try { fn(); } catch (_) { fail(message || 'Got unwanted exception'); } };
            \\  assert.strict = assert;
            \\  return assert;
            \\})();
            \\globalThis._wizpNodeUrl = (function() {
            \\  const encodePath = function(path) {
            \\    return String(path || '').split('/').map(function(part) { return encodeURIComponent(part); }).join('/');
            \\  };
            \\  const pathToFileURL = function(path) {
            \\    path = String(path || '');
            \\    if (!path.startsWith('/')) path = '/' + path;
            \\    return new URL('file://' + encodePath(path));
            \\  };
            \\  const fileURLToPath = function(value) {
            \\    const url = value instanceof URL ? value : new URL(String(value));
            \\    if (url.protocol !== 'file:') throw new TypeError('The URL must be a file URL');
            \\    return decodeURIComponent(url.pathname);
            \\  };
            \\  const parse = function(value) {
            \\    const url = new URL(String(value), 'resolve://');
            \\    return {
            \\      href: url.href.replace('resolve://', ''),
            \\      protocol: url.protocol === 'resolve:' ? null : url.protocol,
            \\      slashes: url.href.indexOf('//') >= 0,
            \\      auth: url.username ? url.username + (url.password ? ':' + url.password : '') : null,
            \\      host: url.host || null,
            \\      port: url.port || null,
            \\      hostname: url.hostname || null,
            \\      hash: url.hash || null,
            \\      search: url.search || null,
            \\      query: url.search ? url.search.slice(1) : null,
            \\      pathname: url.pathname || null,
            \\      path: (url.pathname || '') + (url.search || '')
            \\    };
            \\  };
            \\  const format = function(value) {
            \\    if (typeof value === 'string') return value;
            \\    if (value instanceof URL) return value.href;
            \\    if (value && value.href) return String(value.href);
            \\    const protocol = value && value.protocol ? String(value.protocol) : '';
            \\    const host = value && value.host ? '//' + String(value.host) : '';
            \\    const pathname = value && value.pathname ? String(value.pathname) : '';
            \\    const search = value && value.search ? String(value.search) : '';
            \\    const hash = value && value.hash ? String(value.hash) : '';
            \\    return protocol + host + pathname + search + hash;
            \\  };
            \\  return { URL: globalThis.URL, URLSearchParams: globalThis.URLSearchParams, pathToFileURL, fileURLToPath, parse, format, resolve: function(from, to) { return new URL(String(to), String(from)).href; } };
            \\})();
            \\globalThis._wizpNodeReadlinePromises = (function() {
            \\  const createBaseInterface = function(options) {
            \\    const emitter = new globalThis._wizpNodeEvents.EventEmitter();
            \\    const history = [];
            \\    const input = options && options.input;
            \\    const cleanupFns = [];
            \\    let pending = '';
            \\    let closed = false;
            \\    const toText = function(chunk) {
            \\      if (chunk === undefined || chunk === null) return '';
            \\      if (typeof chunk === 'string') return chunk;
            \\      try { return globalThis._wizpNodeBuffer.Buffer.from(chunk).toString('utf8'); } catch (_) {}
            \\      return String(chunk);
            \\    };
            \\    const removeListener = function(target, event, listener) {
            \\      if (!target) return;
            \\      if (typeof target.off === 'function') target.off(event, listener);
            \\      else if (typeof target.removeListener === 'function') target.removeListener(event, listener);
            \\    };
            \\    const bindInput = function(event, listener) {
            \\      if (!input || typeof input.on !== 'function') return;
            \\      input.on(event, listener);
            \\      cleanupFns.push(function() { removeListener(input, event, listener); });
            \\    };
            \\    const flushPendingLines = function(finalize) {
            \\      const normalized = pending.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
            \\      const parts = normalized.split('\n');
            \\      pending = finalize ? '' : (parts.pop() || '');
            \\      for (const line of parts) emitter.emit('line', line);
            \\      if (finalize && normalized.length > 0 && !normalized.endsWith('\n')) emitter.emit('line', normalized);
            \\    };
            \\    const closeInterface = function() {
            \\      if (closed) return iface;
            \\      closed = true;
            \\      flushPendingLines(true);
            \\      while (cleanupFns.length > 0) {
            \\        const cleanup = cleanupFns.pop();
            \\        try { cleanup(); } catch (_) {}
            \\      }
            \\      emitter.emit('close');
            \\      return iface;
            \\    };
            \\    bindInput('data', function(chunk) {
            \\      pending += toText(chunk);
            \\      flushPendingLines(false);
            \\    });
            \\    bindInput('end', function() { closeInterface(); });
            \\    bindInput('close', function() { closeInterface(); });
            \\    bindInput('error', function(error) {
            \\      emitter.emit('error', error);
            \\      closeInterface();
            \\    });
            \\    if (input && typeof input.resume === 'function') {
            \\      Promise.resolve().then(function() {
            \\        if (!closed) input.resume();
            \\      });
            \\    }
            \\    const ask = function(query) {
            \\      history.push(String(query || ''));
            \\      return Promise.resolve('');
            \\    };
            \\    const iface = {
            \\      input: input,
            \\      output: options && options.output,
            \\      terminal: !!(options && options.terminal),
            \\      get closed() { return closed; },
            \\      question: ask,
            \\      pause: function() { if (input && typeof input.pause === 'function') input.pause(); emitter.emit('pause'); return iface; },
            \\      resume: function() { if (input && typeof input.resume === 'function') input.resume(); emitter.emit('resume'); return iface; },
            \\      close: closeInterface,
            \\      on: function(event, listener) { emitter.on(event, listener); return iface; },
            \\      once: function(event, listener) { emitter.once(event, listener); return iface; },
            \\      off: function(event, listener) { emitter.off(event, listener); return iface; },
            \\      removeListener: function(event, listener) { emitter.removeListener(event, listener); return iface; },
            \\      emit: function(event) {
            \\        const args = Array.prototype.slice.call(arguments, 1);
            \\        emitter.emit.apply(emitter, [event].concat(args));
            \\        return iface;
            \\      },
            \\      get history() { return history.slice(); }
            \\    };
            \\    return iface;
            \\  };
            \\  return {
            \\    createInterface: function(options) {
            \\      return createBaseInterface(options || {});
            \\    }
            \\  };
            \\})();
            \\globalThis._wizpNodeReadline = {
            \\  createInterface: function(options) {
            \\    const iface = globalThis._wizpNodeReadlinePromises.createInterface(options || {});
            \\    const ask = iface.question.bind(iface);
            \\    iface.question = function(query, callback) {
            \\      ask(query).then(function(answer) {
            \\        if (typeof callback === 'function') callback(answer);
            \\      });
            \\      return undefined;
            \\    };
            \\    return iface;
            \\  },
            \\  clearLine: function(stream, dir, callback) { if (callback) callback(); return true; },
            \\  clearScreenDown: function(stream, callback) { if (callback) callback(); return true; },
            \\  cursorTo: function(stream, x, y, callback) { if (typeof y === 'function') y(); else if (callback) callback(); return true; },
            \\  moveCursor: function(stream, dx, dy, callback) { if (callback) callback(); return true; },
            \\  emitKeypressEvents: function() {}
            \\};
            \\globalThis._wizpNodeRepl = {
            \\  builtinModules: ['assert', 'async_hooks', 'buffer', 'child_process', 'console', 'crypto', 'dns', 'events', 'fs', 'http', 'https', 'module', 'net', 'os', 'path', 'process', 'querystring', 'readline', 'stream', 'stream/promises', 'url', 'util', 'zlib']
            \\};
            \\globalThis._wizpNodeRepl._builtinLibs = globalThis._wizpNodeRepl.builtinModules;
            \\globalThis._wizpNodeModule = (function() {
            \\  function Module(id) {
            \\    this.id = id || '';
            \\    this.filename = id || '';
            \\    this.path = globalThis._wizpCwd || '.';
            \\    this.exports = {};
            \\  }
            \\  Module.builtinModules = globalThis._wizpNodeRepl.builtinModules;
            \\  Module._builtinLibs = Module.builtinModules;
            \\  Module.prototype.require = function(request) { return globalThis._wizpRequire(String(request || '')); };
            \\  Module._resolveFilename = function(request) { return String(request || ''); };
            \\  Module.createRequire = function() {
            \\    const createdRequire = function(request) { return globalThis._wizpRequire(String(request || '')); };
            \\    createdRequire.resolve = function(request) { return String(request || ''); };
            \\    return createdRequire;
            \\  };
            \\  Module.Module = Module;
            \\  return Module;
            \\})();
            \\globalThis._wizpNodeConsole = (function() {
            \\  const callConsole = function(method, args) {
            \\    const target = globalThis.console && globalThis.console[method] ? method : 'log';
            \\    try { if (globalThis.console && globalThis.console[target]) globalThis.console[target].apply(globalThis.console, args); } catch (_) {}
            \\  };
            \\  class Console {
            \\    constructor(stdout, stderr) { this.stdout = stdout; this.stderr = stderr || stdout; }
            \\    log() { callConsole('log', Array.prototype.slice.call(arguments)); }
            \\    info() { callConsole('info', Array.prototype.slice.call(arguments)); }
            \\    warn() { callConsole('warn', Array.prototype.slice.call(arguments)); }
            \\    error() { callConsole('error', Array.prototype.slice.call(arguments)); }
            \\    debug() { callConsole('debug', Array.prototype.slice.call(arguments)); }
            \\    trace() { callConsole('trace', Array.prototype.slice.call(arguments)); }
            \\    dir(value) { callConsole('dir', [value]); }
            \\    time() {}
            \\    timeEnd() {}
            \\    assert(value) { if (!value) this.error.apply(this, Array.prototype.slice.call(arguments, 1)); }
            \\  }
            \\  const defaultConsole = new Console();
            \\  return {
            \\    Console,
            \\    log: defaultConsole.log.bind(defaultConsole),
            \\    info: defaultConsole.info.bind(defaultConsole),
            \\    warn: defaultConsole.warn.bind(defaultConsole),
            \\    error: defaultConsole.error.bind(defaultConsole),
            \\    debug: defaultConsole.debug.bind(defaultConsole),
            \\    trace: defaultConsole.trace.bind(defaultConsole),
            \\    dir: defaultConsole.dir.bind(defaultConsole),
            \\    time: defaultConsole.time.bind(defaultConsole),
            \\    timeEnd: defaultConsole.timeEnd.bind(defaultConsole),
            \\    assert: defaultConsole.assert.bind(defaultConsole)
            \\  };
            \\})();
            \\globalThis._wizpNodeAsyncHooks = (function() {
            \\  let nextAsyncId = 1;
            \\  class AsyncLocalStorage {
            \\    constructor() { this._enabled = true; this._store = undefined; }
            \\    disable() { this._enabled = false; this._store = undefined; }
            \\    enterWith(store) { this._enabled = true; this._store = store; }
            \\    getStore() { return this._enabled ? this._store : undefined; }
            \\    run(store, callback) {
            \\      if (typeof callback !== 'function') throw new TypeError('callback must be a function');
            \\      const previousEnabled = this._enabled;
            \\      const previousStore = this._store;
            \\      this._enabled = true;
            \\      this._store = store;
            \\      try { return callback.apply(null, Array.prototype.slice.call(arguments, 2)); }
            \\      finally { this._enabled = previousEnabled; this._store = previousStore; }
            \\    }
            \\    exit(callback) {
            \\      if (typeof callback !== 'function') throw new TypeError('callback must be a function');
            \\      const previousEnabled = this._enabled;
            \\      const previousStore = this._store;
            \\      this._enabled = false;
            \\      this._store = undefined;
            \\      try { return callback.apply(null, Array.prototype.slice.call(arguments, 1)); }
            \\      finally { this._enabled = previousEnabled; this._store = previousStore; }
            \\    }
            \\    bind(callback) {
            \\      if (typeof callback !== 'function') throw new TypeError('callback must be a function');
            \\      const store = this.getStore();
            \\      const self = this;
            \\      return function() { return self.run.apply(self, [store, callback.bind(this)].concat(Array.prototype.slice.call(arguments))); };
            \\    }
            \\    snapshot() {
            \\      const store = this.getStore();
            \\      const self = this;
            \\      return function(callback) { return self.run.apply(self, [store, callback].concat(Array.prototype.slice.call(arguments, 1))); };
            \\    }
            \\    static bind(callback) { return callback; }
            \\    static snapshot() { return function(callback) { return callback.apply(null, Array.prototype.slice.call(arguments, 1)); }; }
            \\  }
            \\  class AsyncResource {
            \\    constructor(type, options) {
            \\      this.type = String(type || 'AsyncResource');
            \\      this._asyncId = nextAsyncId++;
            \\      this._triggerAsyncId = options && Number.isFinite(Number(options.triggerAsyncId)) ? Number(options.triggerAsyncId) : 0;
            \\    }
            \\    asyncId() { return this._asyncId; }
            \\    triggerAsyncId() { return this._triggerAsyncId; }
            \\    runInAsyncScope(callback, thisArg) {
            \\      if (typeof callback !== 'function') throw new TypeError('callback must be a function');
            \\      return callback.apply(thisArg, Array.prototype.slice.call(arguments, 2));
            \\    }
            \\    bind(callback, thisArg) {
            \\      if (typeof callback !== 'function') throw new TypeError('callback must be a function');
            \\      const self = this;
            \\      return function() { return self.runInAsyncScope.apply(self, [callback, thisArg === undefined ? this : thisArg].concat(Array.prototype.slice.call(arguments))); };
            \\    }
            \\    emitDestroy() { return this; }
            \\  }
            \\  const createHook = function() {
            \\    return {
            \\      enable: function() { return this; },
            \\      disable: function() { return this; }
            \\    };
            \\  };
            \\  return {
            \\    AsyncLocalStorage,
            \\    AsyncResource,
            \\    createHook,
            \\    executionAsyncId: function() { return 0; },
            \\    triggerAsyncId: function() { return 0; },
            \\    executionAsyncResource: function() { return {}; },
            \\    asyncWrapProviders: {},
            \\    constants: {}
            \\  };
            \\})();
            \\globalThis._wizpNodePerfHooks = (function() {
            \\  const marks = {};
            \\  const now = function() { return (Date.now ? Date.now() : new Date().getTime()); };
            \\  const performance = {
            \\    timeOrigin: now(),
            \\    now: function() { return now() - performance.timeOrigin; },
            \\    mark: function(name) { marks[String(name)] = performance.now(); },
            \\    measure: function(name, startMark, endMark) {
            \\      const start = marks[String(startMark)] || 0;
            \\      const end = endMark ? (marks[String(endMark)] || performance.now()) : performance.now();
            \\      return { name: String(name || ''), entryType: 'measure', startTime: start, duration: Math.max(0, end - start) };
            \\    },
            \\    clearMarks: function(name) { if (name === undefined) for (const key of Object.keys(marks)) delete marks[key]; else delete marks[String(name)]; },
            \\    clearMeasures: function() {},
            \\    getEntries: function() { return []; },
            \\    getEntriesByName: function() { return []; },
            \\    getEntriesByType: function() { return []; },
            \\  };
            \\  class PerformanceObserver {
            \\    constructor(callback) { this.callback = callback; }
            \\    observe() {}
            \\    disconnect() {}
            \\    takeRecords() { return []; }
            \\  }
            \\  return { performance, PerformanceObserver, monitorEventLoopDelay: function() { return { enable: function(){}, disable: function(){}, reset: function(){}, mean: 0, max: 0, min: 0 }; }, constants: {} };
            \\})();
            \\globalThis._wizpNodeStream = (function() {
            \\  function Stream(options) { this.options = options || {}; this.destroyed = false; this.readable = true; this.writable = true; this._events = {}; this._wizpPipes = []; }
            \\  Stream.prototype.on = function(event, listener) { (this._events[event] = this._events[event] || []).push(listener); return this; };
            \\  Stream.prototype.once = function(event, listener) { const self = this; const wrapped = function() { self.off(event, wrapped); listener.apply(null, arguments); }; return this.on(event, wrapped); };
            \\  Stream.prototype.off = function(event, listener) { const list = this._events[event] || []; const index = list.indexOf(listener); if (index >= 0) list.splice(index, 1); return this; };
            \\  Stream.prototype.removeListener = function(event, listener) { return this.off(event, listener); };
            \\  Stream.prototype.removeAllListeners = function(event) { if (event === undefined) this._events = {}; else delete this._events[event]; return this; };
            \\  Stream.prototype.emit = function(event) { const args = Array.prototype.slice.call(arguments, 1); for (const listener of (this._events[event] || []).slice()) listener.apply(null, args); return true; };
            \\  Stream.prototype.listeners = function(event) { return (this._events[event] || []).slice(); };
            \\  Stream.prototype.rawListeners = function(event) { return (this._events[event] || []).slice(); };
            \\  Stream.prototype.listenerCount = function(event) { return (this._events[event] || []).length; };
            \\  Stream.prototype.eventNames = function() { return Object.keys(this._events); };
            \\  Stream.prototype.pipe = function(destination, options) {
            \\    const source = this;
            \\    const opts = options || {};
            \\    if (!destination) return destination;
            \\    const pipeState = { destination: destination, options: opts, paused: false, onData: null, onEnd: null, onClose: null, onError: null, onDrain: null };
            \\    const cleanup = function() {
            \\      source.off('data', onData);
            \\      source.off('end', onEnd);
            \\      source.off('close', onClose);
            \\      source.off('error', onError);
            \\      if (destination && typeof destination.off === 'function') destination.off('drain', onDrain);
            \\      else if (destination && typeof destination.removeListener === 'function') destination.removeListener('drain', onDrain);
            \\      source._wizpPipes = (source._wizpPipes || []).filter(function(entry) { return entry !== pipeState; });
            \\    };
            \\    const onDrain = function() {
            \\      if (!pipeState.paused) return;
            \\      pipeState.paused = false;
            \\      if (typeof source.resume === 'function') source.resume();
            \\    };
            \\    const onData = function(chunk) {
            \\      if (!destination || destination.destroyed) {
            \\        cleanup();
            \\        return;
            \\      }
            \\      if (typeof destination.write !== 'function') {
            \\        if (typeof destination.emit === 'function') destination.emit('data', chunk);
            \\        return;
            \\      }
            \\      const wrote = destination.write(chunk);
            \\      if (wrote === false && typeof source.pause === 'function') {
            \\        pipeState.paused = true;
            \\        source.pause();
            \\      }
            \\    };
            \\    const onEnd = function() {
            \\      if (opts.end !== false && destination && typeof destination.end === 'function') destination.end();
            \\      cleanup();
            \\    };
            \\    const onClose = function() { cleanup(); };
            \\    const onError = function(error) {
            \\      cleanup();
            \\      if (destination && typeof destination.emit === 'function') destination.emit('error', error);
            \\    };
            \\    pipeState.onData = onData;
            \\    pipeState.onEnd = onEnd;
            \\    pipeState.onClose = onClose;
            \\    pipeState.onError = onError;
            \\    pipeState.onDrain = onDrain;
            \\    (source._wizpPipes = source._wizpPipes || []).push(pipeState);
            \\    source.on('data', onData);
            \\    source.on('end', onEnd);
            \\    source.on('close', onClose);
            \\    source.on('error', onError);
            \\    if (destination && typeof destination.on === 'function') destination.on('drain', onDrain);
            \\    source.emit('pipe', destination);
            \\    if (typeof source.resume === 'function') source.resume();
            \\    return destination;
            \\  };
            \\  Stream.prototype.unpipe = function(destination) {
            \\    const pipes = (this._wizpPipes || []).slice();
            \\    for (const pipeState of pipes) {
            \\      if (destination && pipeState.destination !== destination) continue;
            \\      this.off('data', pipeState.onData);
            \\      this.off('end', pipeState.onEnd);
            \\      this.off('close', pipeState.onClose);
            \\      this.off('error', pipeState.onError);
            \\      if (pipeState.destination && typeof pipeState.destination.off === 'function') pipeState.destination.off('drain', pipeState.onDrain);
            \\      else if (pipeState.destination && typeof pipeState.destination.removeListener === 'function') pipeState.destination.removeListener('drain', pipeState.onDrain);
            \\      this._wizpPipes = (this._wizpPipes || []).filter(function(entry) { return entry !== pipeState; });
            \\    }
            \\    return this;
            \\  };
            \\  Stream.prototype.destroy = function(error) { this.destroyed = true; if (error) this.emit('error', error); this.emit('close'); return this; };
            \\  function inherit(ctor, superCtor) { ctor.prototype = Object.create(superCtor.prototype); ctor.prototype.constructor = ctor; ctor.super_ = superCtor; }
            \\  function settleReadableWaiters(stream, settle) {
            \\    const waiters = stream._wizpReadableWaiters || [];
            \\    while (waiters.length > 0) {
            \\      const waiter = waiters.shift();
            \\      try { settle(waiter); } catch (_) {}
            \\    }
            \\  }
            \\  function initReadableState(stream) {
            \\    if (stream._wizpReadableStateInitialized) return stream;
            \\    stream._wizpReadableStateInitialized = true;
            \\    stream._wizpReadableQueue = [];
            \\    stream._wizpReadableWaiters = [];
            \\    stream._wizpReadableEnded = false;
            \\    stream._wizpReadableError = null;
            \\    stream.on('error', function(error) {
            \\      stream._wizpReadableError = error || new Error('stream error');
            \\      settleReadableWaiters(stream, function(waiter) { waiter.reject(stream._wizpReadableError); });
            \\    });
            \\    stream.on('close', function() {
            \\      if (stream._wizpReadableEnded || stream._wizpReadableError) return;
            \\      stream._wizpReadableEnded = true;
            \\      settleReadableWaiters(stream, function(waiter) { waiter.resolve({ value: undefined, done: true }); });
            \\    });
            \\    return stream;
            \\  }
            \\  function Readable(options) { Stream.call(this, options); initReadableState(this); }
            \\  inherit(Readable, Stream);
            \\  Readable.prototype.read = function() { return null; };
            \\  Readable.prototype.push = function(value) {
            \\    initReadableState(this);
            \\    if (value === null) {
            \\      this._wizpReadableEnded = true;
            \\      this.emit('end');
            \\      settleReadableWaiters(this, function(waiter) { waiter.resolve({ value: undefined, done: true }); });
            \\      return true;
            \\    }
            \\    if (this._wizpReadableWaiters.length > 0) {
            \\      const waiter = this._wizpReadableWaiters.shift();
            \\      waiter.resolve({ value: value, done: false });
            \\    } else {
            \\      this._wizpReadableQueue.push(value);
            \\    }
            \\    this.emit('data', value);
            \\    return true;
            \\  };
            \\  Readable.prototype.resume = function() { this.emit('resume'); return this; };
            \\  Readable.prototype.pause = function() { this.emit('pause'); return this; };
            \\  Readable.prototype.setEncoding = function() { return this; };
            \\  Readable.prototype[Symbol.asyncIterator] = function() {
            \\    const stream = initReadableState(this);
            \\    return {
            \\      next: function() {
            \\        if (stream._wizpReadableQueue.length > 0) return Promise.resolve({ value: stream._wizpReadableQueue.shift(), done: false });
            \\        if (stream._wizpReadableError) return Promise.reject(stream._wizpReadableError);
            \\        if (stream._wizpReadableEnded) return Promise.resolve({ value: undefined, done: true });
            \\        return new Promise(function(resolve, reject) { stream._wizpReadableWaiters.push({ resolve: resolve, reject: reject }); });
            \\      },
            \\      return: function() {
            \\        stream._wizpReadableEnded = true;
            \\        settleReadableWaiters(stream, function(waiter) { waiter.resolve({ value: undefined, done: true }); });
            \\        return Promise.resolve({ value: undefined, done: true });
            \\      },
            \\      [Symbol.asyncIterator]: function() { return this; }
            \\    };
            \\  };
            \\  Readable.from = function(iterable) {
            \\    const stream = new Readable();
            \\    Promise.resolve().then(async function() {
            \\      try {
            \\        for await (const chunk of iterable) stream.push(chunk);
            \\      } catch (error) {
            \\        stream.emit('error', error);
            \\      } finally {
            \\        stream.push(null);
            \\      }
            \\    });
            \\    return stream;
            \\  };
            \\  function Writable(options) { Stream.call(this, options); }
            \\  inherit(Writable, Stream);
            \\  Writable.prototype.write = function(chunk, encoding, callback) { if (typeof encoding === 'function') callback = encoding; this.emit('data', chunk); if (callback) callback(); return true; };
            \\  Writable.prototype.end = function(chunk, encoding, callback) { if (chunk !== undefined) this.write(chunk); if (typeof encoding === 'function') callback = encoding; this.emit('finish'); if (callback) callback(); return this; };
            \\  function Duplex(options) { Readable.call(this, options); }
            \\  inherit(Duplex, Readable);
            \\  Duplex.prototype.write = Writable.prototype.write;
            \\  Duplex.prototype.end = Writable.prototype.end;
            \\  function Transform(options) { Duplex.call(this, options); }
            \\  inherit(Transform, Duplex);
            \\  Transform.prototype._transform = function(chunk, encoding, callback) { if (callback) callback(null, chunk); };
            \\  Transform.prototype.write = function(chunk, encoding, callback) {
            \\    if (typeof encoding === 'function') callback = encoding;
            \\    const self = this;
            \\    let settled = false;
            \\    this._transform(chunk, encoding, function(error, value) {
            \\      if (settled) return;
            \\      settled = true;
            \\      if (error) {
            \\        self.emit('error', error);
            \\        if (callback) callback(error);
            \\        return;
            \\      }
            \\      if (value !== undefined && value !== null) self.push(value);
            \\      if (callback) callback();
            \\    });
            \\    return true;
            \\  };
            \\  Transform.prototype.end = function(chunk, encoding, callback) {
            \\    if (typeof chunk === 'function') callback = chunk;
            \\    if (typeof encoding === 'function') callback = encoding;
            \\    if (chunk !== undefined) this.write(chunk, encoding);
            \\    this.push(null);
            \\    this.emit('finish');
            \\    if (callback) callback();
            \\    return this;
            \\  };
            \\  function PassThrough(options) { Transform.call(this, options); }
            \\  inherit(PassThrough, Transform);
            \\  const finished = function(stream, callback) { if (callback) callback(); return function cleanup() {}; };
            \\  const pipeline = function() {
            \\    const args = Array.prototype.slice.call(arguments);
            \\    const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
            \\    if (callback) callback();
            \\    return args[args.length - 1] || null;
            \\  };
            \\  Stream.Stream = Stream;
            \\  Stream.Readable = Readable;
            \\  Stream.Writable = Writable;
            \\  Stream.Duplex = Duplex;
            \\  Stream.Transform = Transform;
            \\  Stream.PassThrough = PassThrough;
            \\  Stream.finished = finished;
            \\  Stream.pipeline = pipeline;
            \\  Stream.default = Stream;
            \\  return Stream;
            \\})();
            \\globalThis._wizpNodeStreamPromises = {
            \\  finished: function(stream) {
            \\    return new Promise(function(resolve, reject) {
            \\      if (!stream) { resolve(); return; }
            \\      let settled = false;
            \\      const cleanup = function() {
            \\        if (stream.off) {
            \\          stream.off('error', onError);
            \\          stream.off('end', onDone);
            \\          stream.off('finish', onDone);
            \\          stream.off('close', onDone);
            \\        } else if (stream.removeListener) {
            \\          stream.removeListener('error', onError);
            \\          stream.removeListener('end', onDone);
            \\          stream.removeListener('finish', onDone);
            \\          stream.removeListener('close', onDone);
            \\        }
            \\      };
            \\      const settle = function(error) {
            \\        if (settled) return;
            \\        settled = true;
            \\        cleanup();
            \\        if (error) reject(error); else resolve();
            \\      };
            \\      const onDone = function() { settle(null); };
            \\      const onError = function(error) { settle(error || new Error('stream error')); };
            \\      if (stream.destroyed || stream._wizpReadableEnded) { resolve(); return; }
            \\      if (stream.once) {
            \\        stream.once('error', onError);
            \\        stream.once('end', onDone);
            \\        stream.once('finish', onDone);
            \\        stream.once('close', onDone);
            \\      }
            \\      setTimeout(onDone, 0);
            \\    });
            \\  },
            \\  pipeline: function() {
            \\    const args = Array.prototype.slice.call(arguments);
            \\    return new Promise(function(resolve, reject) {
            \\      try {
            \\        globalThis._wizpNodeStream.pipeline.apply(globalThis._wizpNodeStream, args.concat(function(error) {
            \\          if (error) reject(error); else resolve();
            \\        }));
            \\      } catch (error) {
            \\        reject(error);
            \\      }
            \\    });
            \\  }
            \\};
            \\globalThis._wizpNodeStreamConsumers = {
            \\  text: async function(stream) {
            \\    const chunks = [];
            \\    if (!stream) return '';
            \\    if (typeof stream.setEncoding === 'function') stream.setEncoding('utf-8');
            \\    if (stream._chunks && Array.isArray(stream._chunks)) chunks.push.apply(chunks, stream._chunks);
            \\    if (stream._iterable) {
            \\      for await (const chunk of stream._iterable) chunks.push(chunk);
            \\    }
            \\    return await new Promise(function(resolve) {
            \\      let settled = false;
            \\      const done = function() {
            \\        if (settled) return;
            \\        settled = true;
            \\        resolve(chunks.map(function(chunk) {
            \\          if (chunk === undefined || chunk === null) return '';
            \\          return typeof chunk === 'string' ? chunk : globalThis._wizpNodeBuffer.Buffer.from(chunk).toString('utf8');
            \\        }).join(''));
            \\      };
            \\      if (typeof stream.on === 'function') {
            \\        stream.on('data', function(chunk) { chunks.push(chunk); });
            \\        stream.on('end', done);
            \\        stream.on('close', done);
            \\        stream.on('error', done);
            \\      }
            \\      if (typeof stream.resume === 'function') stream.resume();
            \\      setTimeout(done, 0);
            \\    });
            \\  },
            \\  buffer: async function(stream) { return globalThis._wizpNodeBuffer.Buffer.from(await globalThis._wizpNodeStreamConsumers.text(stream)); },
            \\  arrayBuffer: async function(stream) { return (await globalThis._wizpNodeStreamConsumers.buffer(stream)).buffer; },
            \\  json: async function(stream) { return JSON.parse(await globalThis._wizpNodeStreamConsumers.text(stream)); },
            \\  blob: async function(stream) { return new Blob([await globalThis._wizpNodeStreamConsumers.buffer(stream)]); }
            \\};
            \\globalThis._wizpNodeTty = (function() {
            \\  class ReadStream extends globalThis._wizpNodeStream.Readable {
            \\    constructor(fd, options) { super(options); this.fd = fd; this.isTTY = true; this.columns = 80; this.rows = 24; this.isRaw = false; }
            \\    setRawMode(mode) { this.isRaw = !!mode; return this; }
            \\  }
            \\  class WriteStream extends globalThis._wizpNodeStream.Writable {
            \\    constructor(fd, options) { super(options); this.fd = fd; this.isTTY = true; this.columns = 80; this.rows = 24; }
            \\    clearLine() { return true; }
            \\    clearScreenDown() { return true; }
            \\    cursorTo() { return true; }
            \\    moveCursor() { return true; }
            \\    getColorDepth() { return 1; }
            \\    hasColors() { return false; }
            \\  }
            \\  return { isatty: function() { return false; }, ReadStream, WriteStream };
            \\})();
            \\globalThis._wizpNodeStringDecoder = {
            \\  StringDecoder: class {
            \\    constructor(encoding) { this.encoding = encoding || 'utf8'; }
            \\    write(buffer) { return buffer === undefined || buffer === null ? '' : globalThis._wizpNodeBuffer.Buffer.from(buffer).toString(this.encoding); }
            \\    end(buffer) { return buffer === undefined ? '' : this.write(buffer); }
            \\  }
            \\};
            \\if (!globalThis._wizpNativeChildProcess) (async function() {
            \\  try {
            \\    globalThis._wizpNativeChildProcess = await import('node:child_process');
            \\  } catch (_) {
            \\    globalThis._wizpNativeChildProcess = null;
            \\  }
            \\})();
            \\globalThis._wizpNodeFs = (function() {
            \\  const memory = {};
            \\  const releaseFiles = {
            \\    '/etc/debian_version': '12\n',
            \\    '/etc/lsb-release': 'DISTRIB_ID=Debian\nDISTRIB_RELEASE=12\nDISTRIB_CODENAME=bookworm\nDISTRIB_DESCRIPTION="Debian GNU/Linux 12"\n'
            \\  };
            \\  const normalizePath = function(path) { return String(path && path.fsPath ? path.fsPath : (path && path.path ? path.path : path)); };
            \\  const nativeFs = function() {
            \\    try {
            \\      if (globalThis._wizpNativeFs) return globalThis._wizpNativeFs;
            \\      return typeof require === 'function' ? require('node:fs') : null;
            \\    } catch (_) {
            \\      return null;
            \\    }
            \\  };
            \\  const makeError = function(code, path) {
            \\    const error = new Error(code + ': ' + normalizePath(path));
            \\    error.code = code;
            \\    error.path = normalizePath(path);
            \\    return error;
            \\  };
            \\  const asBuffer = function(value) { return globalThis._wizpNodeBuffer.Buffer.from(value === undefined || value === null ? '' : value); };
            \\  const render = function(value, options) {
            \\    const encoding = typeof options === 'string' ? options : (options && options.encoding);
            \\    if (value && value.__base64) {
            \\      const binary = globalThis._wizpNodeBuffer.Buffer.from(value.__base64, 'base64');
            \\      return encoding ? binary.toString(encoding) : binary;
            \\    }
            \\    const buffer = asBuffer(value);
            \\    return encoding ? buffer.toString(encoding) : buffer;
            \\  };
            \\  const statFor = function(path, value) {
            \\    const size = value === undefined || value === null ? 0 : asBuffer(value).length;
            \\    return { dev: 0, ino: 0, mode: 0o100644, nlink: 1, uid: 0, gid: 0, rdev: 0, blksize: 4096, blocks: 1, size: size, atimeMs: 0, mtimeMs: 0, ctimeMs: 0, birthtimeMs: 0, atime: new Date(0), mtime: new Date(0), ctime: new Date(0), birthtime: new Date(0), isFile: function() { return true; }, isDirectory: function() { return false; }, isSymbolicLink: function() { return false; }, isBlockDevice: function() { return false; }, isCharacterDevice: function() { return false; }, isFIFO: function() { return false; }, isSocket: function() { return false; } };
            \\  };
            \\  const existsSync = function(path) {
            \\    path = normalizePath(path);
            \\    if (Object.prototype.hasOwnProperty.call(releaseFiles, path)) return true;
            \\    if (Object.prototype.hasOwnProperty.call(memory, path)) return true;
            \\    if (globalThis._wizpExtensionFileSources && Object.prototype.hasOwnProperty.call(globalThis._wizpExtensionFileSources, path)) return true;
            \\    const fs = nativeFs();
            \\    return !!(fs && fs.existsSync && fs.existsSync(path));
            \\  };
            \\  const readFileSync = function(path, options) {
            \\    path = normalizePath(path);
            \\    if (Object.prototype.hasOwnProperty.call(releaseFiles, path)) return render(releaseFiles[path], options);
            \\    if (globalThis._wizpExtensionFileSources && Object.prototype.hasOwnProperty.call(globalThis._wizpExtensionFileSources, path)) return render(globalThis._wizpExtensionFileSources[path], options);
            \\    if (Object.prototype.hasOwnProperty.call(memory, path)) return render(memory[path], options);
            \\    const fs = nativeFs();
            \\    if (fs && fs.readFileSync && fs.existsSync && fs.existsSync(path)) return fs.readFileSync(path, options);
            \\    throw makeError('ENOENT', path);
            \\  };
            \\  const writeFileSync = function(path, data, options) {
            \\    path = normalizePath(path);
            \\    memory[path] = data === undefined ? '' : data;
            \\    const fs = nativeFs();
            \\    if (fs && fs.writeFileSync) {
            \\      try { if (fs.mkdirSync) fs.mkdirSync(globalThis._wizpNodePath.dirname(path), { recursive: true }); } catch (_) {}
            \\      return fs.writeFileSync(path, data === undefined ? '' : data, options);
            \\    }
            \\  };
            \\  const mkdirSync = function(path, options) {
            \\    const fs = nativeFs();
            \\    if (fs && fs.mkdirSync) return fs.mkdirSync(normalizePath(path), options || {});
            \\    return undefined;
            \\  };
            \\  const chmodSync = function(path, mode) {
            \\    path = normalizePath(path);
            \\    const fs = nativeFs();
            \\    if (fs && fs.chmodSync) return fs.chmodSync(path, mode);
            \\    if (!existsSync(path)) throw makeError('ENOENT', path);
            \\    return undefined;
            \\  };
            \\  const rmSync = function(path, options) {
            \\    path = normalizePath(path);
            \\    delete memory[path];
            \\    const fs = nativeFs();
            \\    const rmOptions = options || {};
            \\    if (fs && fs.rmSync && fs.existsSync && fs.existsSync(path)) {
            \\      try { return fs.rmSync(path, rmOptions); } catch (_) {}
            \\    }
            \\    if (fs && fs.existsSync && fs.existsSync(path) && fs.statSync && fs.readdirSync && fs.unlinkSync && fs.rmdirSync) {
            \\      const removeRecursive = function(target) {
            \\        let stat;
            \\        try { stat = fs.statSync(target); } catch (error) { if (rmOptions.force) return; throw error; }
            \\        if (stat && stat.isDirectory && stat.isDirectory()) {
            \\          if (!rmOptions.recursive) return fs.rmdirSync(target);
            \\          for (const entry of fs.readdirSync(target)) removeRecursive(globalThis._wizpNodePath.join(target, entry));
            \\          return fs.rmdirSync(target);
            \\        }
            \\        return fs.unlinkSync(target);
            \\      };
            \\      return removeRecursive(path);
            \\    }
            \\  };
            \\  const unlinkSync = rmSync;
            \\  const rmdirSync = rmSync;
            \\  const readdirSync = function(path, options) {
            \\    path = normalizePath(path).replace(/\/+$/, '');
            \\    const fs = nativeFs();
            \\    if (fs && fs.readdirSync) {
            \\      try { return fs.readdirSync(path, options); } catch (_) {}
            \\    }
            \\    const names = new Set();
            \\    const prefix = path === '/' ? '/' : path + '/';
            \\    for (const key of Object.keys(memory)) {
            \\      if (!key.startsWith(prefix)) continue;
            \\      const rest = key.slice(prefix.length);
            \\      if (rest && rest.indexOf('/') < 0) names.add(rest);
            \\    }
            \\    return Array.from(names);
            \\  };
            \\  const statSync = function(path) {
            \\    path = normalizePath(path);
            \\    if (Object.prototype.hasOwnProperty.call(releaseFiles, path)) return statFor(path, releaseFiles[path]);
            \\    if (globalThis._wizpExtensionFileSources && Object.prototype.hasOwnProperty.call(globalThis._wizpExtensionFileSources, path)) return statFor(path, globalThis._wizpExtensionFileSources[path]);
            \\    if (Object.prototype.hasOwnProperty.call(memory, path)) return statFor(path, memory[path]);
            \\    const fs = nativeFs();
            \\    if (fs && fs.statSync) return fs.statSync(path);
            \\    throw makeError('ENOENT', path);
            \\  };
            \\  const lstatSync = statSync;
            \\  const accessSync = function(path, mode) {
            \\    path = normalizePath(path);
            \\    if (Object.prototype.hasOwnProperty.call(memory, path)) return;
            \\    if (globalThis._wizpExtensionFileSources && Object.prototype.hasOwnProperty.call(globalThis._wizpExtensionFileSources, path)) return;
            \\    const fs = nativeFs();
            \\    if (fs && fs.accessSync) return fs.accessSync(path, mode);
            \\    if (!existsSync(path)) throw makeError('ENOENT', path);
            \\  };
            \\  const realpathSync = function(path, options) {
            \\    const fs = nativeFs();
            \\    if (fs && fs.realpathSync) {
            \\      try { return fs.realpathSync(normalizePath(path), options); } catch (_) {}
            \\    }
            \\    return normalizePath(path);
            \\  };
            \\  realpathSync.native = realpathSync;
            \\  const copyFileSync = function(source, target) {
            \\    source = normalizePath(source);
            \\    target = normalizePath(target);
            \\    const fs = nativeFs();
            \\    const hasVirtualSource =
            \\      Object.prototype.hasOwnProperty.call(releaseFiles, source) ||
            \\      Object.prototype.hasOwnProperty.call(memory, source) ||
            \\      !!(globalThis._wizpExtensionFileSources && Object.prototype.hasOwnProperty.call(globalThis._wizpExtensionFileSources, source));
            \\    if (!hasVirtualSource && fs && fs.copyFileSync && fs.existsSync && fs.existsSync(source)) {
            \\      try { if (fs.mkdirSync) fs.mkdirSync(globalThis._wizpNodePath.dirname(target), { recursive: true }); } catch (_) {}
            \\      fs.copyFileSync(source, target);
            \\      if (fs.readFileSync) {
            \\        try { memory[target] = fs.readFileSync(target); } catch (_) {}
            \\      }
            \\      return;
            \\    }
            \\    return writeFileSync(target, readFileSync(source));
            \\  };
            \\  const renameSync = function(source, target) {
            \\    source = normalizePath(source);
            \\    target = normalizePath(target);
            \\    const fs = nativeFs();
            \\    if (!Object.prototype.hasOwnProperty.call(memory, source) && fs && fs.renameSync && fs.existsSync && fs.existsSync(source)) {
            \\      try { if (fs.mkdirSync) fs.mkdirSync(globalThis._wizpNodePath.dirname(target), { recursive: true }); } catch (_) {}
            \\      return fs.renameSync(source, target);
            \\    }
            \\    if (!existsSync(source)) throw makeError('ENOENT', source);
            \\    memory[target] = memory[source];
            \\    delete memory[source];
            \\  };
            \\  const memoryDirents = function(path, options) {
            \\    path = normalizePath(path).replace(/\/+$/, '');
            \\    const names = new Set();
            \\    const prefix = path === '/' ? '/' : path + '/';
            \\    for (const key of Object.keys(memory)) {
            \\      if (!key.startsWith(prefix)) continue;
            \\      const rest = key.slice(prefix.length);
            \\      if (rest) names.add(rest.split('/')[0]);
            \\    }
            \\    const wantsDirents = options && options.withFileTypes;
            \\    return Array.from(names).map(function(name) {
            \\      if (!wantsDirents) return name;
            \\      const childPath = prefix + name;
            \\      const isFile = Object.prototype.hasOwnProperty.call(memory, childPath);
            \\      const isDirectory = !isFile;
            \\      return { name: name, isFile: function() { return isFile; }, isDirectory: function() { return isDirectory; }, isSymbolicLink: function() { return false; }, isBlockDevice: function() { return false; }, isCharacterDevice: function() { return false; }, isFIFO: function() { return false; }, isSocket: function() { return false; } };
            \\    });
            \\  };
            \\  const makeFileHandle = function(path, nativeHandle) {
            \\    path = normalizePath(path);
            \\    return {
            \\      fd: nativeHandle && typeof nativeHandle.fd === 'number' ? nativeHandle.fd : ++globalThis._wizp_disposableId,
            \\      read: async function(buffer, offset, length, position) {
            \\        if (nativeHandle && typeof nativeHandle.read === 'function') return nativeHandle.read(buffer, offset, length, position);
            \\        const target = buffer && globalThis._wizpNodeBuffer.Buffer.isBuffer(buffer)
            \\          ? buffer
            \\          : globalThis._wizpNodeBuffer.Buffer.alloc(typeof length === 'number' && length >= 0 ? length : 0);
            \\        const begin = typeof offset === 'number' && offset >= 0 ? offset : 0;
            \\        const span = typeof length === 'number' && length >= 0 ? length : Math.max(0, target.length - begin);
            \\        const start = typeof position === 'number' && position >= 0 ? position : 0;
            \\        const source = globalThis._wizpNodeBuffer.Buffer.from(await promises.readFile(path));
            \\        const slice = source.subarray(start, start + span);
            \\        slice.copy(target, begin, 0, slice.length);
            \\        return { bytesRead: slice.length, buffer: target };
            \\      },
            \\      readFile: async function(options) {
            \\        if (nativeHandle && typeof nativeHandle.readFile === 'function') return nativeHandle.readFile(options);
            \\        return promises.readFile(path, options);
            \\      },
            \\      stat: async function() {
            \\        if (nativeHandle && typeof nativeHandle.stat === 'function') return nativeHandle.stat();
            \\        return statSync(path);
            \\      },
            \\      close: async function() {
            \\        if (nativeHandle && typeof nativeHandle.close === 'function') return nativeHandle.close();
            \\      }
            \\    };
            \\  };
            \\  const promises = {
            \\    access: async function(path, mode) {
            \\      path = normalizePath(path);
            \\      const fs = nativeFs();
            \\      if (fs && fs.promises && fs.promises.access) {
            \\        try {
            \\          return await fs.promises.access(path, mode);
            \\        } catch (error) {
            \\          if (existsSync(path)) return;
            \\          throw error;
            \\        }
            \\      }
            \\      return accessSync(path, mode);
            \\    },
            \\    readFile: async function(path, options) {
            \\      path = normalizePath(path);
            \\      if (Object.prototype.hasOwnProperty.call(releaseFiles, path)) return render(releaseFiles[path], options);
            \\      if (globalThis._wizpExtensionFileSources && Object.prototype.hasOwnProperty.call(globalThis._wizpExtensionFileSources, path)) return render(globalThis._wizpExtensionFileSources[path], options);
            \\      if (Object.prototype.hasOwnProperty.call(memory, path)) return render(memory[path], options);
            \\      const fs = nativeFs();
            \\      if (fs && fs.promises && fs.promises.readFile) return fs.promises.readFile(path, options);
            \\      if (globalThis.Bun) {
            \\        const file = globalThis.Bun.file(path);
            \\        if (await file.exists()) return options && (typeof options === 'string' || options.encoding) ? await file.text() : globalThis._wizpNodeBuffer.Buffer.from(await file.arrayBuffer());
            \\      }
            \\      throw makeError('ENOENT', path);
            \\    },
            \\    writeFile: async function(path, data) {
            \\      path = normalizePath(path);
            \\      memory[path] = data === undefined ? '' : data;
            \\      const fs = nativeFs();
            \\      if (fs && fs.promises && fs.promises.writeFile) {
            \\        if (fs.promises.mkdir) await fs.promises.mkdir(globalThis._wizpNodePath.dirname(path), { recursive: true });
            \\        return fs.promises.writeFile(path, data === undefined ? '' : data);
            \\      }
            \\      if (globalThis.Bun && typeof globalThis.Bun.write === 'function') await globalThis.Bun.write(path, data === undefined ? '' : data);
            \\    },
            \\    open: async function(path, flags, mode) {
            \\      path = normalizePath(path);
            \\      const flagText = flags === undefined || flags === null ? 'r' : String(flags);
            \\      const fs = nativeFs();
            \\      const mayCreate = flagText.indexOf('w') >= 0 || flagText.indexOf('a') >= 0 || flagText.indexOf('+') >= 0;
            \\      if (fs && fs.promises && fs.promises.open) {
            \\        if (mayCreate && fs.promises.mkdir) await fs.promises.mkdir(globalThis._wizpNodePath.dirname(path), { recursive: true });
            \\        return fs.promises.open(path, flags, mode);
            \\      }
            \\      if (!existsSync(path)) {
            \\        if (mayCreate) {
            \\          memory[path] = memory[path] || '';
            \\        } else {
            \\          throw makeError('ENOENT', path);
            \\        }
            \\      }
            \\      return makeFileHandle(path, null);
            \\    },
            \\    mkdir: async function(path, options) {
            \\      path = normalizePath(path);
            \\      const fs = nativeFs();
            \\      if (fs && fs.promises && fs.promises.mkdir) return fs.promises.mkdir(path, options || {});
            \\      return mkdirSync(path, options || {});
            \\    },
            \\    chmod: async function(path, mode) {
            \\      path = normalizePath(path);
            \\      const fs = nativeFs();
            \\      if (fs && fs.promises && fs.promises.chmod) return fs.promises.chmod(path, mode);
            \\      return chmodSync(path, mode);
            \\    },
            \\    rm: async function(path, options) {
            \\      path = normalizePath(path);
            \\      delete memory[path];
            \\      const fs = nativeFs();
            \\      if (fs && fs.promises && fs.promises.rm) {
            \\        try { return await fs.promises.rm(path, options || {}); } catch (_) {}
            \\      }
            \\      return rmSync(path, options || {});
            \\    },
            \\    unlink: async function(path) {
            \\      path = normalizePath(path);
            \\      delete memory[path];
            \\      const fs = nativeFs();
            \\      if (fs && fs.promises && fs.promises.unlink) return fs.promises.unlink(path);
            \\      return rmSync(path, {});
            \\    },
            \\    rmdir: async function(path, options) {
            \\      path = normalizePath(path);
            \\      delete memory[path];
            \\      const fs = nativeFs();
            \\      if (fs && fs.promises && fs.promises.rmdir) return fs.promises.rmdir(path, options || {});
            \\      return rmSync(path, options || {});
            \\    },
            \\    readdir: async function(path, options) {
            \\      path = normalizePath(path).replace(/\/+$/, '');
            \\      const fs = nativeFs();
            \\      if (fs && fs.promises && fs.promises.readdir) return fs.promises.readdir(path, options || {});
            \\      if (fs && fs.readdirSync) return fs.readdirSync(path, options || {});
            \\      return memoryDirents(path, options || {});
            \\    },
            \\    stat: async function(path) { return statSync(path); },
            \\    lstat: async function(path) { return statSync(path); },
            \\    realpath: async function(path, options) {
            \\      const fs = nativeFs();
            \\      if (fs && fs.promises && fs.promises.realpath) return fs.promises.realpath(normalizePath(path), options);
            \\      return realpathSync(path, options);
            \\    },
            \\    copyFile: async function(source, target) {
            \\      source = normalizePath(source);
            \\      target = normalizePath(target);
            \\      const fs = nativeFs();
            \\      const hasVirtualSource =
            \\        Object.prototype.hasOwnProperty.call(releaseFiles, source) ||
            \\        Object.prototype.hasOwnProperty.call(memory, source) ||
            \\        !!(globalThis._wizpExtensionFileSources && Object.prototype.hasOwnProperty.call(globalThis._wizpExtensionFileSources, source));
            \\      if (!hasVirtualSource && fs && fs.promises && fs.promises.copyFile) {
            \\        if (fs.promises.mkdir) await fs.promises.mkdir(globalThis._wizpNodePath.dirname(target), { recursive: true });
            \\        await fs.promises.copyFile(source, target);
            \\        if (fs.promises.readFile) {
            \\          try { memory[target] = await fs.promises.readFile(target); } catch (_) {}
            \\        }
            \\        return;
            \\      }
            \\      return copyFileSync(source, target);
            \\    },
            \\    rename: async function(source, target) {
            \\      const fs = nativeFs();
            \\      if (fs && fs.promises && fs.promises.rename) return fs.promises.rename(normalizePath(source), normalizePath(target));
            \\      return renameSync(source, target);
            \\    }
            \\  };
            \\  const callbackify = function(fn) {
            \\    return function() {
            \\      const args = Array.prototype.slice.call(arguments);
            \\      const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
            \\      const promise = Promise.resolve().then(function() { return fn.apply(null, args); });
            \\      if (callback) promise.then(function(value) { callback(null, value); }, function(error) { callback(error); });
            \\      return undefined;
            \\    };
            \\  };
            \\  const readFile = callbackify(promises.readFile);
            \\  const writeFile = callbackify(promises.writeFile);
            \\  const stat = callbackify(promises.stat);
            \\  const lstat = callbackify(promises.lstat);
            \\  const access = callbackify(promises.access);
            \\  const mkdir = callbackify(promises.mkdir);
            \\  const chmod = callbackify(promises.chmod);
            \\  const rm = callbackify(promises.rm);
            \\  const unlink = callbackify(promises.unlink);
            \\  const rmdir = callbackify(promises.rmdir);
            \\  const readdir = callbackify(promises.readdir);
            \\  const realpath = callbackify(promises.realpath);
            \\  const copyFile = callbackify(promises.copyFile);
            \\  const rename = callbackify(promises.rename);
            \\  realpath.native = realpath;
            \\  const createReadStream = function(path, options) {
            \\    path = normalizePath(path);
            \\    const fs = nativeFs();
            \\    if (fs && fs.createReadStream) return fs.createReadStream(path, options);
            \\    const stream = new globalThis._wizpNodeStream.Readable(options);
            \\    Promise.resolve().then(function() {
            \\      try { stream.push(readFileSync(path)); } catch (error) { stream.emit('error', error); }
            \\      stream.push(null);
            \\    });
            \\    return stream;
            \\  };
            \\  const createWriteStream = function(path, options) {
            \\    path = normalizePath(path);
            \\    const fs = nativeFs();
            \\    if (fs && fs.createWriteStream) {
            \\      try { if (fs.mkdirSync) fs.mkdirSync(globalThis._wizpNodePath.dirname(path), { recursive: true }); } catch (_) {}
            \\      return fs.createWriteStream(path, options);
            \\    }
            \\    const chunks = [];
            \\    const stream = new globalThis._wizpNodeStream.Writable(options);
            \\    const baseWrite = stream.write.bind(stream);
            \\    stream.write = function(chunk, encoding, callback) { chunks.push(chunk); return baseWrite(chunk, encoding, callback); };
            \\    const baseEnd = stream.end.bind(stream);
            \\    stream.end = function(chunk, encoding, callback) {
            \\      if (chunk !== undefined) chunks.push(chunk);
            \\      writeFileSync(path, globalThis._wizpNodeBuffer.Buffer.concat(chunks.map(asBuffer)));
            \\      return baseEnd(undefined, encoding, callback);
            \\    };
            \\    return stream;
            \\  };
            \\  const watch = function(path, options, listener) { return { close: function() {}, on: function() { return this; }, once: function() { return this; } }; };
            \\  const watchFile = function(path, options, listener) {};
            \\  const unwatchFile = function(path, listener) {};
            \\  return { constants: { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 }, promises, existsSync, readFile, writeFile, stat, lstat, access, mkdir, chmod, rm, unlink, rmdir, readdir, realpath, copyFile, rename, readFileSync, writeFileSync, mkdirSync, chmodSync, rmSync, unlinkSync, rmdirSync, readdirSync, statSync, lstatSync, accessSync, realpathSync, copyFileSync, renameSync, createReadStream, createWriteStream, watch, watchFile, unwatchFile };
            \\})();
            \\globalThis._wizpNodeChildProcess = (function() {
            \\  const nativeChildProcess = function() {
            \\    try {
            \\      if (globalThis._wizpNativeChildProcess) return globalThis._wizpNativeChildProcess;
            \\      return typeof require === 'function' ? require('node:child_process') : null;
            \\    } catch (_) {
            \\      return null;
            \\    }
            \\  };
            \\  const nativeStreamModule = function() {
            \\    try {
            \\      return typeof require === 'function' ? require('node:stream') : null;
            \\    } catch (_) {
            \\      return null;
            \\    }
            \\  };
            \\  const makePipeStream = function() {
            \\    const nativeStream = nativeStreamModule();
            \\    if (nativeStream && nativeStream.PassThrough) return new nativeStream.PassThrough();
            \\    if (globalThis._wizpNodeStream && globalThis._wizpNodeStream.PassThrough) return new globalThis._wizpNodeStream.PassThrough();
            \\    return new globalThis._wizpNodeStream.Duplex();
            \\  };
            \\  globalThis._wizpAttachRefable = function(target) {
            \\    if (!target || (typeof target !== 'object' && typeof target !== 'function')) return target;
            \\    if (!Object.prototype.hasOwnProperty.call(target, '_wizpRefd')) target._wizpRefd = true;
            \\    target.ref = function() { target._wizpRefd = true; return target; };
            \\    target.unref = function() { target._wizpRefd = false; return target; };
            \\    target.hasRef = function() { return target._wizpRefd !== false; };
            \\    return target;
            \\  };
            \\  const bunSpawnSync = function(command, args, options) {
            \\    if (!globalThis.Bun || typeof globalThis.Bun.spawnSync !== 'function') return null;
            \\    args = Array.isArray(args) ? args : [];
            \\    options = options || {};
            \\    let result;
            \\    try {
            \\      result = globalThis.Bun.spawnSync({
            \\        cmd: [String(command)].concat(args.map(String)),
            \\        cwd: options.cwd,
            \\        env: options.env,
            \\        stdout: 'pipe',
            \\        stderr: 'pipe'
            \\      });
            \\    } catch (error) {
            \\      const stderr = globalThis._wizpNodeBuffer.Buffer.from(error && error.message ? error.message : String(error || 'spawn failed'));
            \\      return {
            \\        pid: 0,
            \\        output: [null, globalThis._wizpNodeBuffer.Buffer.alloc(0), stderr],
            \\        stdout: globalThis._wizpNodeBuffer.Buffer.alloc(0),
            \\        stderr: stderr,
            \\        status: error && error.code === 'ENOENT' ? 127 : 126,
            \\        signal: null,
            \\        error: error
            \\      };
            \\    }
            \\    const stdout = result.stdout || globalThis._wizpNodeBuffer.Buffer.alloc(0);
            \\    const stderr = result.stderr || globalThis._wizpNodeBuffer.Buffer.alloc(0);
            \\    const wantsString = options && options.encoding && options.encoding !== 'buffer';
            \\    return {
            \\      pid: result.pid || 0,
            \\      output: [null, wantsString ? stdout.toString(options.encoding) : stdout, wantsString ? stderr.toString(options.encoding) : stderr],
            \\      stdout: wantsString ? stdout.toString(options.encoding) : stdout,
            \\      stderr: wantsString ? stderr.toString(options.encoding) : stderr,
            \\      status: result.exitCode === undefined ? 0 : result.exitCode,
            \\      signal: result.signalCode || null,
            \\      error: undefined
            \\    };
            \\  };
            \\  const makeProcess = function(options) {
            \\    options = options || {};
            \\    const events = {};
            \\    const proc = {
            \\      pid: 0,
            \\      killed: false,
            \\      exitCode: null,
            \\      signalCode: null,
            \\      _wizpRefd: true,
            \\      stdin: makePipeStream(),
            \\      stdout: makePipeStream(),
            \\      stderr: makePipeStream(),
            \\      on: function(event, listener) { (events[event] = events[event] || []).push(listener); return proc; },
            \\      once: function(event, listener) { const wrapped = function() { proc.off(event, wrapped); listener.apply(null, arguments); }; return proc.on(event, wrapped); },
            \\      off: function(event, listener) { const list = events[event] || []; const index = list.indexOf(listener); if (index >= 0) list.splice(index, 1); return proc; },
            \\      removeListener: function(event, listener) { return proc.off(event, listener); },
            \\      emit: function(event) { const args = Array.prototype.slice.call(arguments, 1); for (const listener of (events[event] || []).slice()) listener.apply(null, args); return true; },
            \\      kill: function(signal) {
            \\        proc.killed = true;
            \\        proc.signalCode = signal || 'SIGTERM';
            \\        proc.exitCode = 0;
            \\        proc.emit('exit', 0, proc.signalCode);
            \\        proc.emit('close', 0, proc.signalCode);
            \\        return true;
            \\      }
            \\    };
            \\    if (options.autoClose !== false) {
            \\      Promise.resolve().then(function() {
            \\        if (proc.exitCode !== null) return;
            \\        proc.exitCode = 0;
            \\        proc.stdout.push(null);
            \\        proc.stderr.push(null);
            \\        proc.emit('exit', 0, null);
            \\        proc.emit('close', 0, null);
            \\      });
            \\    }
            \\    return globalThis._wizpAttachRefable(proc);
            \\  };
            \\  const makeIpcProcess = function(modulePath, args, options) {
            \\    const proc = makeProcess({ autoClose: false });
            \\    proc.pid = ++globalThis._wizp_disposableId;
            \\    proc.connected = true;
            \\    proc.modulePath = String(modulePath || '');
            \\    proc.spawnargs = [proc.modulePath].concat(Array.isArray(args) ? args : []);
            \\    globalThis._wizpForkedProcesses = globalThis._wizpForkedProcesses || [];
            \\    globalThis._wizpForkedProcesses.push({ pid: proc.pid, modulePath: proc.modulePath, args: proc.spawnargs.slice(1), ipcShim: true });
            \\    const responseFor = function(message) {
            \\      const method = String(message && message.method || '');
            \\      if (method === 'initialize') {
            \\        return {
            \\          capabilities: {
            \\            textDocumentSync: 1,
            \\            workspace: { workspaceFolders: { supported: true, changeNotifications: true } },
            \\            executeCommandProvider: { commands: [] },
            \\            codeActionProvider: true
            \\          },
            \\          serverInfo: { name: 'wizp-ipc-language-server-shim', version: '0.1.0' }
            \\        };
            \\      }
            \\      if (method.indexOf('checkDocument') >= 0 || method.indexOf('CheckDocument') >= 0) return { items: [], issues: [], checked: true };
            \\      if (method.indexOf('getConfiguration') >= 0 || method.indexOf('GetConfiguration') >= 0) return {};
            \\      if (method.indexOf('isSpellCheckEnabled') >= 0) return true;
            \\      return null;
            \\    };
            \\    proc.send = function(message, sendHandle, options, callback) {
            \\      const cb = typeof sendHandle === 'function' ? sendHandle : (typeof options === 'function' ? options : callback);
            \\      if (message && Object.prototype.hasOwnProperty.call(message, 'id')) {
            \\        setTimeout(function() {
            \\          proc.emit('message', { jsonrpc: '2.0', id: message.id, result: responseFor(message) });
            \\        }, 0);
            \\      }
            \\      if (cb) setTimeout(function() { cb(null); }, 0);
            \\      return true;
            \\    };
            \\    proc.disconnect = function() {
            \\      proc.connected = false;
            \\      proc.emit('disconnect');
            \\    };
            \\    return proc;
            \\  };
            \\  const makePythonEnvToolsProcess = function(command, args, options) {
            \\    void options;
            \\    const proc = makeProcess({ autoClose: false });
            \\    proc.pid = ++globalThis._wizp_disposableId;
            \\    proc.spawnargs = [String(command || '')].concat(Array.isArray(args) ? args : []);
            \\    let pending = '';
            \\    const bufferFrom = function(value) {
            \\      if (globalThis._wizpNodeBuffer.Buffer.isBuffer(value)) return value;
            \\      if (typeof ArrayBuffer !== 'undefined') {
            \\        if (value instanceof ArrayBuffer) return globalThis._wizpNodeBuffer.Buffer.from(value);
            \\        if (typeof ArrayBuffer.isView === 'function' && ArrayBuffer.isView(value)) return globalThis._wizpNodeBuffer.Buffer.from(value.buffer, value.byteOffset || 0, value.byteLength || value.length || 0);
            \\      }
            \\      return globalThis._wizpNodeBuffer.Buffer.from(String(value === undefined || value === null ? '' : value));
            \\    };
            \\    const writeMessage = function(payload) {
            \\      try { globalThis._wizpDebugLog('pet-shim:send', JSON.stringify(payload)); } catch (_) {}
            \\      const body = JSON.stringify(payload);
            \\      const header = 'Content-Length: ' + globalThis._wizpNodeBuffer.Buffer.byteLength(body, 'utf8') + '\r\n\r\n';
            \\      proc.stdout.push(globalThis._wizpNodeBuffer.Buffer.from(header + body, 'utf8'));
            \\    };
            \\    const debugPreview = function(buffer) {
            \\      try {
            \\        return buffer.toString('utf8').replace(/\r/g, '\\r').replace(/\n/g, '\\n').slice(0, 160);
            \\      } catch (_) {
            \\        return '<unprintable>';
            \\      }
            \\    };
            \\    const writeNotification = function(method, params) {
            \\      writeMessage({ jsonrpc: '2.0', method: String(method || ''), params: params || {} });
            \\    };
            \\    const nativeFs = globalThis._wizpNativeFs;
            \\    const nodePath = globalThis._wizpNodePath;
            \\    const normalizePath = function(value) {
            \\      if (!value) return null;
            \\      let text = String(value || '');
            \\      if (!text) return null;
            \\      if (text.startsWith('file://')) {
            \\        try { text = new URL(text).pathname; } catch (_) { text = text.slice('file://'.length); }
            \\      }
            \\      try {
            \\        if (nodePath && typeof nodePath.resolve === 'function') return nodePath.resolve(text);
            \\      } catch (_) {}
            \\      return text;
            \\    };
            \\    const uniquePaths = function(items) {
            \\      const seen = new Set();
            \\      const result = [];
            \\      for (const item of Array.isArray(items) ? items : []) {
            \\        const normalized = normalizePath(item);
            \\        if (!normalized || seen.has(normalized)) continue;
            \\        seen.add(normalized);
            \\        result.push(normalized);
            \\      }
            \\      return result;
            \\    };
            \\    const configuredWorkspaceDirectories = function() {
            \\      const config = proc._wizpPetConfiguration && typeof proc._wizpPetConfiguration === 'object' ? proc._wizpPetConfiguration : {};
            \\      return uniquePaths(Array.isArray(config.workspaceDirectories) ? config.workspaceDirectories : []);
            \\    };
            \\    const configuredEnvironmentDirectories = function() {
            \\      const config = proc._wizpPetConfiguration && typeof proc._wizpPetConfiguration === 'object' ? proc._wizpPetConfiguration : {};
            \\      return uniquePaths(Array.isArray(config.environmentDirectories) ? config.environmentDirectories : []);
            \\    };
            \\    const fileExists = function(pathValue) {
            \\      try { return !!(nativeFs && nativeFs.existsSync && nativeFs.existsSync(pathValue)); } catch (_) { return false; }
            \\    };
            \\    const pythonVersionForPrefix = function(prefix) {
            \\      const cfgPath = nodePath && typeof nodePath.join === 'function' ? nodePath.join(prefix, 'pyvenv.cfg') : (String(prefix || '') + '/pyvenv.cfg');
            \\      try {
            \\        if (fileExists(cfgPath) && nativeFs && nativeFs.readFileSync) {
            \\          const text = String(nativeFs.readFileSync(cfgPath, 'utf8') || '');
            \\          const match = text.match(/(^|\n)version\s*=\s*([^\r\n]+)/i);
            \\          if (match && match[2]) return String(match[2]).trim();
            \\        }
            \\      } catch (_) {}
            \\      return '3.11.0';
            \\    };
            \\    const environmentKind = function(prefix) {
            \\      const cfgPath = nodePath && typeof nodePath.join === 'function' ? nodePath.join(prefix, 'pyvenv.cfg') : (String(prefix || '') + '/pyvenv.cfg');
            \\      return fileExists(cfgPath) ? 'Venv' : 'LinuxGlobal';
            \\    };
            \\    const discoverCandidateExecutables = function() {
            \\      const candidates = [];
            \\      const binDir = 'bin';
            \\      const exeNames = ['python', 'python3'];
            \\      for (const workspaceDir of configuredWorkspaceDirectories()) {
            \\        for (const folder of ['.venv', 'venv', 'env']) {
            \\          for (const exeName of exeNames) {
            \\            const candidate = nodePath.join(workspaceDir, folder, binDir, exeName);
            \\            if (fileExists(candidate)) candidates.push(candidate);
            \\          }
            \\        }
            \\      }
            \\      for (const envDir of configuredEnvironmentDirectories()) {
            \\        for (const exeName of exeNames) {
            \\          const candidate = nodePath.join(envDir, binDir, exeName);
            \\          if (fileExists(candidate)) candidates.push(candidate);
            \\        }
            \\        for (const folder of ['.venv', 'venv', 'env']) {
            \\          for (const exeName of exeNames) {
            \\            const nested = nodePath.join(envDir, folder, binDir, exeName);
            \\            if (fileExists(nested)) candidates.push(nested);
            \\          }
            \\        }
            \\      }
            \\      if (!candidates.length) {
            \\        const fallback = nodePath.join(globalThis._wizpCwd || '.', '.venv', binDir, 'python');
            \\        if (fileExists(fallback)) candidates.push(fallback);
            \\      }
            \\      const envPython = globalThis._wizpProcessEnv && (globalThis._wizpProcessEnv.PYTHON || globalThis._wizpProcessEnv.PYTHON3);
            \\      if (!candidates.length && envPython) candidates.push(String(envPython));
            \\      return uniquePaths(candidates);
            \\    };
            \\    const resolveEnvironment = function(executable) {
            \\      let text = normalizePath(executable);
            \\      if (!text) {
            \\        const discovered = discoverCandidateExecutables();
            \\        text = discovered.length ? discovered[0] : '';
            \\      }
            \\      if (!text) return {};
            \\      let prefix = text;
            \\      const binIndex = Math.max(text.lastIndexOf('/bin/'), text.lastIndexOf('\\\\bin\\\\'));
            \\      if (binIndex > 0) prefix = text.slice(0, binIndex);
            \\      const version = pythonVersionForPrefix(prefix);
            \\      const labelSuffix = nodePath && typeof nodePath.basename === 'function' ? (nodePath.basename(prefix) || nodePath.basename(text) || 'python') : 'python';
            \\      return {
            \\        name: 'Python ' + version + ' (' + labelSuffix + ')',
            \\        displayName: 'Python ' + version + ' (' + labelSuffix + ')',
            \\        executable: text,
            \\        prefix: prefix,
            \\        version: version,
            \\        kind: environmentKind(prefix),
            \\        tools: []
            \\      };
            \\    };
            \\    const handleMessage = function(message) {
            \\      if (!message || typeof message.method !== 'string' || !Object.prototype.hasOwnProperty.call(message, 'id')) {
            \\        try { globalThis._wizpDebugLog('pet-shim:ignored', JSON.stringify(message)); } catch (_) {}
            \\        return;
            \\      }
            \\      const method = message.method;
            \\      const params = message && typeof message.params === 'object' && message.params ? message.params : {};
            \\      try { globalThis._wizpDebugLog('pet-shim:recv', method, JSON.stringify(params)); } catch (_) {}
            \\      let result = null;
            \\      if (method === 'info') {
            \\        result = { petVersion: '0.0.0-wizp-spawn-shim', buildId: 'wizp-spawn-shim', commitSha: 'wizp-spawn-shim' };
            \\      } else if (method === 'configure') {
            \\        proc._wizpPetConfiguration = params;
            \\        result = { configured: true };
            \\      } else if (method === 'refresh') {
            \\        const environments = discoverCandidateExecutables().map(resolveEnvironment).filter(function(item) {
            \\          return item && item.executable && item.prefix && item.version;
            \\        });
            \\        for (const env of environments) writeNotification('environment', env);
            \\        writeNotification('telemetry', {
            \\          event: 'RefreshPerformance',
            \\          data: {
            \\            refreshPerformance: {
            \\              locators: ['wizp-spawn-shim'],
            \\              breakdown: { Workspaces: configuredWorkspaceDirectories().length }
            \\            }
            \\          }
            \\        });
            \\        result = { refreshed: environments.length };
            \\      } else if (method === 'resolve') {
            \\        result = resolveEnvironment(params.executable);
            \\      }
            \\      writeMessage({ jsonrpc: '2.0', id: message.id, result: result });
            \\    };
            \\    const pumpMessages = function() {
            \\      while (true) {
            \\        const headerEnd = pending.indexOf('\r\n\r\n');
            \\        if (headerEnd < 0) return;
            \\        const headerText = pending.slice(0, headerEnd);
            \\        let length = 0;
            \\        for (const line of headerText.split(/\r?\n/)) {
            \\          const parts = line.split(':');
            \\          if (parts.length < 2) continue;
            \\          if (String(parts[0] || '').trim().toLowerCase() !== 'content-length') continue;
            \\          length = parseInt(String(parts.slice(1).join(':') || '').trim(), 10) || 0;
            \\        }
            \\        const bodyStart = headerEnd + 4;
            \\        if (pending.length < bodyStart + length) return;
            \\        try { globalThis._wizpDebugLog('pet-shim:frame', 'header=' + headerText.replace(/\r/g, '\\r').replace(/\n/g, '\\n'), 'length=' + String(length)); } catch (_) {}
            \\        const body = pending.slice(bodyStart, bodyStart + length);
            \\        pending = pending.slice(bodyStart + length);
            \\        try {
            \\          handleMessage(JSON.parse(body));
            \\        } catch (error) {
            \\          try { globalThis._wizpDebugLog('pet-shim:parse-error', debugPreview(bufferFrom(body)), String(error && error.stack ? error.stack : error)); } catch (_) {}
            \\          proc.stderr.push(bufferFrom(error && error.stack ? error.stack : error));
            \\        }
            \\      }
            \\    };
            \\    proc.stdin.write = function(chunk, encoding, callback) {
            \\      void encoding;
            \\      const incoming = bufferFrom(chunk);
            \\      try { globalThis._wizpDebugLog('pet-shim:stdin-write', String(incoming.length || 0), debugPreview(incoming)); } catch (_) {}
            \\      pending += incoming.toString('utf8');
            \\      pumpMessages();
            \\      if (typeof callback === 'function') callback();
            \\      try { proc.stdin.emit('drain'); } catch (_) {}
            \\      return true;
            \\    };
            \\    proc.stdin.end = function(chunk, encoding, callback) {
            \\      if (chunk !== undefined && chunk !== null) proc.stdin.write(chunk, encoding);
            \\      if (typeof callback === 'function') callback();
            \\      return proc.stdin;
            \\    };
            \\    proc.kill = function(signal) {
            \\      if (proc.exitCode !== null) return true;
            \\      proc.killed = true;
            \\      proc.signalCode = signal || 'SIGTERM';
            \\      proc.exitCode = 0;
            \\      proc.stdout.push(null);
            \\      proc.stderr.push(null);
            \\      proc.emit('exit', 0, proc.signalCode);
            \\      proc.emit('close', 0, proc.signalCode);
            \\      return true;
            \\    };
            \\    return proc;
            \\  };
            \\  const shouldShimPythonEnvToolsSpawn = function(command, args) {
            \\    const env = globalThis._wizpProcessEnv || (globalThis._wizpNodeProcess && globalThis._wizpNodeProcess.env) || {};
            \\    if (env.WIZP_ENABLE_PYTHON_ENV_TOOLS_SPAWN_SHIM !== '1') return false;
            \\    const text = String(command || '');
            \\    if (!/(^|[\\/])python-env-tools[\\/]bin[\\/]pet(?:\\.exe)?$/.test(text)) return false;
            \\    return Array.isArray(args) && args.length > 0 && String(args[0]) === 'server';
            \\  };
            \\  const normalizeCallback = function(options, callback) {
            \\    return typeof options === 'function' ? options : callback;
            \\  };
            \\  const recordSpawnedProcess = function(entry) {
            \\    globalThis._wizpSpawnedProcesses = globalThis._wizpSpawnedProcesses || [];
            \\    globalThis._wizpSpawnedProcesses.push({
            \\      pid: entry && entry.pid ? entry.pid : 0,
            \\      command: String(entry && entry.command ? entry.command : ''),
            \\      args: Array.isArray(entry && entry.args) ? entry.args.map(String) : [],
            \\      kind: String(entry && entry.kind ? entry.kind : ''),
            \\      native: !!(entry && entry.native),
            \\      sync: !!(entry && entry.sync),
            \\      shell: !!(entry && entry.shell),
            \\      petShim: !!(entry && entry.petShim)
            \\    });
            \\  };
            \\  const exec = function(command, options, callback) {
            \\    const cb = normalizeCallback(options, callback);
            \\    const opts = (options && typeof options === 'object') ? options : {};
            \\    const native = nativeChildProcess();
            \\    recordSpawnedProcess({ command: String(command || ''), args: [], kind: 'exec', native: !!(native && native.exec), shell: true });
            \\    if (native && native.exec) {
            \\      try { return native.exec.apply(native, arguments); } catch (_) {}
            \\    }
            \\    const bunResult = bunSpawnSync('/bin/sh', ['-lc', String(command || '')], opts);
            \\    const proc = makeProcess();
            \\    if (bunResult && cb) {
            \\      Promise.resolve().then(function() {
            \\        const wantsBuffer = opts && opts.encoding === 'buffer';
            \\        const stdout = wantsBuffer || typeof bunResult.stdout === 'string' ? bunResult.stdout : (bunResult.stdout && bunResult.stdout.toString ? bunResult.stdout.toString(opts.encoding || 'utf8') : '');
            \\        const stderr = wantsBuffer || typeof bunResult.stderr === 'string' ? bunResult.stderr : (bunResult.stderr && bunResult.stderr.toString ? bunResult.stderr.toString(opts.encoding || 'utf8') : '');
            \\        const error = bunResult.status === 0 ? null : Object.assign(new Error(stderr ? String(stderr) : 'exec failed'), { code: bunResult.status });
            \\        try { cb(error, stdout, stderr); } catch (callbackError) { proc.emit('error', callbackError); }
            \\      });
            \\      return proc;
            \\    }
            \\    if (cb) Promise.resolve().then(function() { cb(null, '', ''); });
            \\    return proc;
            \\  };
            \\  const execFile = function(file, args, options, callback) {
            \\    const cb = typeof args === 'function' ? args : (typeof options === 'function' ? options : callback);
            \\    const argv = Array.isArray(args) ? args : [];
            \\    const opts = (options && typeof options === 'object') ? options : {};
            \\    const native = nativeChildProcess();
            \\    recordSpawnedProcess({ command: String(file || ''), args: argv, kind: 'execFile', native: !!(native && native.execFile) });
            \\    if (native && native.execFile) {
            \\      try { return native.execFile.apply(native, arguments); } catch (_) {}
            \\    }
            \\    const bunResult = bunSpawnSync(file, argv, opts);
            \\    if (bunResult) {
            \\      const proc = makeProcess();
            \\      if (cb) {
            \\        Promise.resolve().then(function() {
            \\          const wantsBuffer = opts && opts.encoding === 'buffer';
            \\          const stdout = wantsBuffer || typeof bunResult.stdout === 'string' ? bunResult.stdout : (bunResult.stdout && bunResult.stdout.toString ? bunResult.stdout.toString(opts.encoding || 'utf8') : '');
            \\          const stderr = wantsBuffer || typeof bunResult.stderr === 'string' ? bunResult.stderr : (bunResult.stderr && bunResult.stderr.toString ? bunResult.stderr.toString(opts.encoding || 'utf8') : '');
            \\          const error = bunResult.status === 0 ? null : Object.assign(new Error(stderr ? String(stderr) : 'execFile failed'), { code: bunResult.status });
            \\          try { cb(error, stdout, stderr); } catch (callbackError) { proc.emit('error', callbackError); }
            \\        });
            \\      }
            \\      return proc;
            \\    }
            \\    const proc = makeProcess();
            \\    if (cb) Promise.resolve().then(function() { cb(null, '', ''); });
            \\    return proc;
            \\  };
            \\  const bufferizeReadable = function(stream) {
            \\    if (!stream || stream.__wizpBufferized === true) return stream;
            \\    stream.__wizpBufferized = true;
            \\    const wrappers = typeof WeakMap === 'function' ? new WeakMap() : null;
            \\    const asyncIteratorSymbol = typeof Symbol === 'function' ? Symbol.asyncIterator : null;
            \\    const toBuffer = function(chunk) {
            \\      if (globalThis._wizpNodeBuffer.Buffer.isBuffer(chunk)) return chunk;
            \\      if (chunk instanceof Uint8Array) return globalThis._wizpNodeBuffer.Buffer.from(chunk);
            \\      return globalThis._wizpNodeBuffer.Buffer.from(String(chunk === undefined || chunk === null ? '' : chunk));
            \\    };
            \\    const wrap = function(listener) {
            \\      if (typeof listener !== 'function') return listener;
            \\      if (wrappers && wrappers.has(listener)) return wrappers.get(listener);
            \\      const wrapped = function(chunk) { return listener.call(this, toBuffer(chunk)); };
            \\      if (wrappers) wrappers.set(listener, wrapped);
            \\      return wrapped;
            \\    };
            \\    for (const name of ['on', 'addListener', 'once', 'prependListener', 'prependOnceListener']) {
            \\      if (typeof stream[name] !== 'function') continue;
            \\      const original = stream[name].bind(stream);
            \\      stream[name] = function(event, listener) {
            \\        return original(event, event === 'data' ? wrap(listener) : listener);
            \\      };
            \\    }
            \\    for (const name of ['off', 'removeListener']) {
            \\      if (typeof stream[name] !== 'function') continue;
            \\      const original = stream[name].bind(stream);
            \\      stream[name] = function(event, listener) {
            \\        return original(event, event === 'data' ? wrap(listener) : listener);
            \\      };
            \\    }
            \\    if (typeof stream.setEncoding === 'function') {
            \\      stream.setEncoding = function() { return stream; };
            \\    }
            \\    if (asyncIteratorSymbol && typeof stream[asyncIteratorSymbol] !== 'function') {
            \\      stream._wizpReadableQueue = [];
            \\      stream._wizpReadableWaiters = [];
            \\      stream._wizpReadableEnded = false;
            \\      stream._wizpReadableError = null;
            \\      if (typeof stream.on === 'function') {
            \\        stream.on('data', function(chunk) {
            \\          const value = toBuffer(chunk);
            \\          if (stream._wizpReadableWaiters.length > 0) {
            \\            const waiter = stream._wizpReadableWaiters.shift();
            \\            waiter.resolve({ value: value, done: false });
            \\          } else {
            \\            stream._wizpReadableQueue.push(value);
            \\          }
            \\        });
            \\        stream.on('end', function() {
            \\          stream._wizpReadableEnded = true;
            \\          while (stream._wizpReadableWaiters.length > 0) {
            \\            const waiter = stream._wizpReadableWaiters.shift();
            \\            waiter.resolve({ value: undefined, done: true });
            \\          }
            \\        });
            \\        stream.on('close', function() {
            \\          if (stream._wizpReadableEnded || stream._wizpReadableError) return;
            \\          stream._wizpReadableEnded = true;
            \\          while (stream._wizpReadableWaiters.length > 0) {
            \\            const waiter = stream._wizpReadableWaiters.shift();
            \\            waiter.resolve({ value: undefined, done: true });
            \\          }
            \\        });
            \\        stream.on('error', function(error) {
            \\          stream._wizpReadableError = error || new Error('stream error');
            \\          while (stream._wizpReadableWaiters.length > 0) {
            \\            const waiter = stream._wizpReadableWaiters.shift();
            \\            waiter.reject(stream._wizpReadableError);
            \\          }
            \\        });
            \\      }
            \\      stream[asyncIteratorSymbol] = function() {
            \\        return {
            \\          next: function() {
            \\            if (stream._wizpReadableQueue.length > 0) return Promise.resolve({ value: stream._wizpReadableQueue.shift(), done: false });
            \\            if (stream._wizpReadableError) return Promise.reject(stream._wizpReadableError);
            \\            if (stream._wizpReadableEnded) return Promise.resolve({ value: undefined, done: true });
            \\            return new Promise(function(resolve, reject) { stream._wizpReadableWaiters.push({ resolve: resolve, reject: reject }); });
            \\          },
            \\          return: function() {
            \\            stream._wizpReadableEnded = true;
            \\            while (stream._wizpReadableWaiters.length > 0) {
            \\              const waiter = stream._wizpReadableWaiters.shift();
            \\              waiter.resolve({ value: undefined, done: true });
            \\            }
            \\            return Promise.resolve({ value: undefined, done: true });
            \\          },
            \\          [asyncIteratorSymbol]: function() { return this; }
            \\        };
            \\      };
            \\    }
            \\    return stream;
            \\  };
            \\  const mirrorReadableToPassThrough = function(stream) {
            \\    if (!stream || stream.__wizpMirroredReadable === true) return stream;
            \\    const passthrough = makePipeStream();
            \\    passthrough.__wizpMirroredReadable = true;
            \\    const asBuffer = function(chunk) {
            \\      if (globalThis._wizpNodeBuffer.Buffer.isBuffer(chunk)) return chunk;
            \\      if (chunk instanceof Uint8Array) return globalThis._wizpNodeBuffer.Buffer.from(chunk);
            \\      return globalThis._wizpNodeBuffer.Buffer.from(String(chunk === undefined || chunk === null ? '' : chunk));
            \\    };
            \\    if (typeof stream.on === 'function') {
            \\      stream.on('data', function(chunk) {
            \\        try {
            \\          passthrough.write(asBuffer(chunk));
            \\        } catch (error) {
            \\          try { passthrough.emit('error', error); } catch (_) {}
            \\        }
            \\      });
            \\      stream.on('end', function() {
            \\        try { passthrough.end(); } catch (_) {}
            \\      });
            \\      stream.on('close', function() {
            \\        try { passthrough.emit('close'); } catch (_) {}
            \\      });
            \\      stream.on('error', function(error) {
            \\        try { passthrough.emit('error', error); } catch (_) {}
            \\      });
            \\    }
            \\    if (typeof stream.resume === 'function') {
            \\      try { stream.resume(); } catch (_) {}
            \\    }
            \\    return passthrough;
            \\  };
            \\  const attachDebugChildStreamLogs = function(proc, command) {
            \\    if (!globalThis._wizpDebugEnabled || !proc || proc.__wizpDebugChildStreamsAttached) return;
            \\    const lowerCommand = String(command || '').toLowerCase();
            \\    if (lowerCommand.indexOf('clangd') < 0) return;
            \\    proc.__wizpDebugChildStreamsAttached = true;
            \\    const asBuffer = function(chunk) {
            \\      if (globalThis._wizpNodeBuffer.Buffer.isBuffer(chunk)) return chunk;
            \\      if (chunk instanceof Uint8Array) return globalThis._wizpNodeBuffer.Buffer.from(chunk);
            \\      return globalThis._wizpNodeBuffer.Buffer.from(String(chunk === undefined || chunk === null ? '' : chunk));
            \\    };
            \\    const preview = function(chunk) {
            \\      try {
            \\        return asBuffer(chunk).toString('utf8').replace(/\r/g, '\\r').replace(/\n/g, '\\n').slice(0, 220);
            \\      } catch (_) {
            \\        return '<unprintable>';
            \\      }
            \\    };
            \\    const attach = function(stream, label) {
            \\      if (!stream || typeof stream.on !== 'function') return;
            \\      let count = 0;
            \\      stream.on('data', function(chunk) {
            \\        if (count >= 8) return;
            \\        count += 1;
            \\        try {
            \\          globalThis._wizpDebugLog('child-process', lowerCommand, label, 'chunk=' + String(count), 'len=' + String(asBuffer(chunk).length || 0), 'preview=' + preview(chunk));
            \\        } catch (_) {}
            \\      });
            \\    };
            \\    attach(proc.stdout, 'stdout');
            \\    attach(proc.stderr, 'stderr');
            \\    if (proc.stdin && typeof proc.stdin.write === 'function' && !proc.stdin.__wizpDebugWrappedWrite) {
            \\      proc.stdin.__wizpDebugWrappedWrite = true;
            \\      const originalWrite = proc.stdin.write.bind(proc.stdin);
            \\      let writeCount = 0;
            \\      proc.stdin.write = function(chunk, encoding, callback) {
            \\        if (writeCount < 8) {
            \\          writeCount += 1;
            \\          try {
            \\            globalThis._wizpDebugLog('child-process', lowerCommand, 'stdin', 'chunk=' + String(writeCount), 'len=' + String(asBuffer(chunk).length || 0), 'preview=' + preview(chunk));
            \\          } catch (_) {}
            \\        }
            \\        return originalWrite(chunk, encoding, callback);
            \\      };
            \\    }
            \\  };
            \\  const spawn = function() {
            \\    const command = arguments.length > 0 ? String(arguments[0]) : '';
            \\    const args = Array.isArray(arguments[1]) ? arguments[1].map(String) : [];
            \\    if (shouldShimPythonEnvToolsSpawn(command, args)) {
            \\      const proc = makePythonEnvToolsProcess(command, args, arguments[2]);
            \\      proc.stdout = bufferizeReadable(proc.stdout);
            \\      proc.stderr = bufferizeReadable(proc.stderr);
            \\      recordSpawnedProcess({ pid: proc.pid || 0, command: command, args: args, kind: 'spawn', native: false, petShim: true });
            \\      return proc;
            \\    }
            \\    const native = nativeChildProcess();
            \\    if (native && native.spawn) {
            \\      try {
            \\        const proc = native.spawn.apply(native, arguments);
            \\        if (proc) {
            \\          proc.stdout = bufferizeReadable(proc.stdout);
            \\          proc.stderr = bufferizeReadable(proc.stderr);
            \\        }
            \\        attachDebugChildStreamLogs(proc, command);
            \\        recordSpawnedProcess({ pid: proc && proc.pid ? proc.pid : 0, command: command, args: args, kind: 'spawn', native: true });
            \\        return proc;
            \\      } catch (_) {}
            \\    }
            \\    const proc = makeProcess();
            \\    recordSpawnedProcess({ pid: proc.pid || 0, command: command, args: args, kind: 'spawn', native: false });
            \\    return proc;
            \\  };
            \\  const fork = function(modulePath, args, options) {
            \\    const native = nativeChildProcess();
            \\    const argv = Array.isArray(args) ? args.map(String) : [];
            \\    const nativeForkEnabled = globalThis._wizpNativeForkEnabled === true;
            \\    if (nativeForkEnabled && native && native.fork) {
            \\      try {
            \\        const proc = native.fork.apply(native, arguments);
            \\        globalThis._wizpForkedProcesses = globalThis._wizpForkedProcesses || [];
            \\        globalThis._wizpForkedProcesses.push({ pid: proc && proc.pid ? proc.pid : 0, modulePath: String(modulePath || ''), args: argv, ipcShim: false, native: true });
            \\        return proc;
            \\      } catch (_) {}
            \\    }
            \\    return makeIpcProcess(modulePath, args, options);
            \\  };
            \\  const empty = function(options) {
            \\    const wantsString = options && options.encoding && options.encoding !== 'buffer';
            \\    return wantsString ? '' : globalThis._wizpNodeBuffer.Buffer.alloc(0);
            \\  };
            \\  const spawnSync = function(command, args, options) {
            \\    const native = nativeChildProcess();
            \\    const argv = Array.isArray(args) ? args.map(String) : [];
            \\    recordSpawnedProcess({ command: String(command || ''), args: argv, kind: 'spawnSync', native: !!(native && native.spawnSync), sync: true });
            \\    if (native && native.spawnSync) {
            \\      try { return native.spawnSync.apply(native, arguments); } catch (_) {}
            \\    }
            \\    const bunResult = bunSpawnSync(command, args, options || {});
            \\    if (bunResult) return bunResult;
            \\    const stdout = empty(options || {});
            \\    const stderr = empty(options || {});
            \\    return { pid: 0, output: [null, stdout, stderr], stdout: stdout, stderr: stderr, status: 0, signal: null, error: undefined };
            \\  };
            \\  const execSync = function(command, options) {
            \\    const native = nativeChildProcess();
            \\    recordSpawnedProcess({ command: String(command || ''), args: [], kind: 'execSync', native: !!(native && native.execSync), sync: true, shell: true });
            \\    if (native && native.execSync) {
            \\      try { return native.execSync.apply(native, arguments); } catch (_) {}
            \\    }
            \\    const bunResult = bunSpawnSync('/bin/sh', ['-c', command], options || {});
            \\    if (bunResult) return bunResult.stdout;
            \\    return empty(options || {});
            \\  };
            \\  const execFileSync = function(file, args, options) {
            \\    const native = nativeChildProcess();
            \\    const argv = Array.isArray(args) ? args.map(String) : [];
            \\    recordSpawnedProcess({ command: String(file || ''), args: argv, kind: 'execFileSync', native: !!(native && native.execFileSync), sync: true });
            \\    if (native && native.execFileSync) {
            \\      try { return native.execFileSync.apply(native, arguments); } catch (_) {}
            \\    }
            \\    const bunResult = bunSpawnSync(file, args, options || {});
            \\    if (bunResult) return bunResult.stdout;
            \\    return empty(options || {});
            \\  };
            \\  return { exec, execFile, spawn, fork, spawnSync, execSync, execFileSync };
            \\})();
            \\globalThis._wizpGetNetworkAllowlist = function() {
            \\  const env = globalThis._wizpProcessEnv || {};
            \\  const entries = String(globalThis._wizpExtensionNetworkAllowlist || env.WIZP_EXTENSION_NETWORK_ALLOWLIST || '')
            \\    .split(',')
            \\    .map(function(entry) { return String(entry || '').trim(); })
            \\    .filter(function(entry) { return entry.length > 0; });
            \\  globalThis._wizpNetworkAllowlist = entries;
            \\  return entries;
            \\};
            \\globalThis._wizpNetworkAllowlist = globalThis._wizpGetNetworkAllowlist();
            \\globalThis._wizpHasExtensionNetworkConsent = function() {
            \\  const env = globalThis._wizpProcessEnv || {};
            \\  const raw = String(globalThis._wizpExtensionNetworkConsent || env.WIZP_EXTENSION_NETWORK_CONSENT || '').trim().toLowerCase();
            \\  return raw === '1' || raw === 'true' || raw === 'yes' || raw === 'on';
            \\};
            \\globalThis._wizpIsAllowlistedNetworkTarget = function(target) {
            \\  const entries = globalThis._wizpGetNetworkAllowlist ? globalThis._wizpGetNetworkAllowlist() : (globalThis._wizpNetworkAllowlist || []);
            \\  const raw = String(target || '').trim();
            \\  if (!raw || !entries.length) return false;
            \\  const schemeIndex = raw.indexOf('://');
            \\  const authorityStart = schemeIndex >= 0 ? schemeIndex + 3 : 0;
            \\  let authorityEnd = raw.length;
            \\  for (const delimiter of ['/', '?', '#']) {
            \\    const index = raw.indexOf(delimiter, authorityStart);
            \\    if (index >= 0 && index < authorityEnd) authorityEnd = index;
            \\  }
            \\  const authority = authorityEnd > authorityStart ? raw.slice(authorityStart, authorityEnd) : '';
            \\  const atIndex = authority.lastIndexOf('@');
            \\  const host = atIndex >= 0 ? authority.slice(atIndex + 1) : authority;
            \\  const hostname = host.replace(/:\d+$/, '');
            \\  const origin = schemeIndex >= 0 && host ? raw.slice(0, authorityStart) + host : '';
            \\  return entries.some(function(entry) {
            \\    const token = String(entry || '').trim();
            \\    if (!token) return false;
            \\    if (token === '*') return true;
            \\    if (/^https?:\/\//i.test(token)) return raw.indexOf(token) === 0 || origin === token;
            \\    if (token.indexOf('*.') === 0) {
            \\      const suffix = token.slice(1);
            \\      return hostname === token.slice(2) || hostname.endsWith(suffix);
            \\    }
            \\    return host === token || hostname === token;
            \\  });
            \\};
            \\globalThis._wizpRedactSensitiveText = function(value) {
            \\  const text = String(value === undefined || value === null ? '' : value);
            \\  return text
            \\    .replace(/(\bBearer\s+)[A-Za-z0-9._~+/=-]{8,}/gi, '$1REDACTED')
            \\    .replace(/([?&](?:access[_-]?token|auth[_-]?token|id[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|secret|password|passwd|session|sessionid|code|token|key)=)[^&#\s]*/gi, '$1REDACTED')
            \\    .replace(/\/\/([^/@\s:]+):([^/@\s]*)@/g, '//REDACTED:REDACTED@');
            \\};
            \\globalThis._wizpRedactUrlForAudit = function(value) {
            \\  const raw = String(value === undefined || value === null ? '' : value);
            \\  try {
            \\    const parsed = new URL(raw);
            \\    if (parsed.username) parsed.username = 'REDACTED';
            \\    if (parsed.password) parsed.password = 'REDACTED';
            \\    const secretKey = /^(access[_-]?token|auth[_-]?token|id[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|secret|password|passwd|session|sessionid|code|token|key)$/i;
            \\    for (const key of Array.from(parsed.searchParams.keys())) {
            \\      if (secretKey.test(key)) parsed.searchParams.set(key, 'REDACTED');
            \\    }
            \\    return parsed.toString();
            \\  } catch (_) {
            \\    return globalThis._wizpRedactSensitiveText(raw);
            \\  }
            \\};
            \\globalThis._wizpAuditHostForTarget = function(value) {
            \\  const raw = String(value === undefined || value === null ? '' : value);
            \\  try { return new URL(raw).host; } catch (_) {}
            \\  const schemeIndex = raw.indexOf('://');
            \\  const authorityStart = schemeIndex >= 0 ? schemeIndex + 3 : 0;
            \\  let authorityEnd = raw.length;
            \\  for (const delimiter of ['/', '?', '#']) {
            \\    const index = raw.indexOf(delimiter, authorityStart);
            \\    if (index >= 0 && index < authorityEnd) authorityEnd = index;
            \\  }
            \\  const authority = authorityEnd > authorityStart ? raw.slice(authorityStart, authorityEnd) : '';
            \\  const atIndex = authority.lastIndexOf('@');
            \\  return atIndex >= 0 ? authority.slice(atIndex + 1) : authority;
            \\};
            \\globalThis._wizpNodeHttp = (function() {
            \\  const requestTarget = function(options) {
            \\    if (typeof options === 'string') return options;
            \\    if (options && typeof options.href === 'string' && options.href) return options.href;
            \\    const protocol = options && typeof options.protocol === 'string' && options.protocol ? options.protocol : 'http:';
            \\    const host = options && (options.hostname || options.host) ? String(options.hostname || options.host) : '';
            \\    const port = options && options.port ? ':' + String(options.port) : '';
            \\    const path = options && options.path ? String(options.path) : '/';
            \\    if (!host) return path;
            \\    return protocol + '//' + host + port + path;
            \\  };
            \\  const isLocalTarget = function(target) {
            \\    const value = String(target || '');
            \\    return /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(value) ||
            \\      /^(127\.0\.0\.1|localhost)(:\d+)?(\/|$)/.test(value);
            \\  };
            \\  const normalizeRequestArgs = function(argsLike) {
            \\    const args = Array.prototype.slice.call(argsLike || []);
            \\    const first = args.length > 0 ? args[0] : undefined;
            \\    const second = args.length > 1 ? args[1] : undefined;
            \\    const third = args.length > 2 ? args[2] : undefined;
            \\    const baseOptions = {};
            \\    const assignOptions = function(value) {
            \\      if (!value || typeof value !== 'object') return;
            \\      for (const key of Object.keys(value)) baseOptions[key] = value[key];
            \\    };
            \\    if (typeof first === 'string' || (typeof URL !== 'undefined' && first instanceof URL)) {
            \\      const href = String(first || '');
            \\      baseOptions.href = href;
            \\      try {
            \\        const parsed = new URL(href);
            \\        baseOptions.protocol = parsed.protocol;
            \\        baseOptions.hostname = parsed.hostname;
            \\        baseOptions.host = parsed.host;
            \\        if (parsed.port) baseOptions.port = parsed.port;
            \\        baseOptions.path = (parsed.pathname || '/') + (parsed.search || '');
            \\      } catch (_) {}
            \\      if (second && typeof second === 'object' && typeof second !== 'function') assignOptions(second);
            \\    } else if (first && typeof first === 'object') {
            \\      assignOptions(first);
            \\      if (second && typeof second === 'object' && typeof second !== 'function') assignOptions(second);
            \\    }
            \\    const callback = typeof second === 'function'
            \\      ? second
            \\      : (typeof third === 'function' ? third : null);
            \\    return { options: baseOptions, callback: callback };
            \\  };
            \\  const outgoingHeadersObject = function(value) {
            \\    const headers = {};
            \\    const assign = function(key, headerValue) {
            \\      if (!key) return;
            \\      headers[String(key).toLowerCase()] = Array.isArray(headerValue) ? headerValue.map(String).join(', ') : String(headerValue);
            \\    };
            \\    if (!value) return headers;
            \\    if (Array.isArray(value)) {
            \\      for (let index = 0; index + 1 < value.length; index += 2) assign(value[index], value[index + 1]);
            \\      return headers;
            \\    }
            \\    if (typeof value.forEach === 'function') {
            \\      try {
            \\        value.forEach(function(headerValue, key) { assign(key, headerValue); });
            \\        return headers;
            \\      } catch (_) {}
            \\    }
            \\    if (typeof value === 'object') {
            \\      for (const key of Object.keys(value)) assign(key, value[key]);
            \\    }
            \\    return headers;
            \\  };
            \\  const responseHeadersObject = function(headersLike) {
            \\    const headers = {};
            \\    const rawHeaders = [];
            \\    if (!headersLike || typeof headersLike.forEach !== 'function') return { headers: headers, rawHeaders: rawHeaders };
            \\    headersLike.forEach(function(value, key) {
            \\      const headerKey = String(key || '').toLowerCase();
            \\      const headerValue = String(value || '');
            \\      headers[headerKey] = headerValue;
            \\      rawHeaders.push(String(key || ''), headerValue);
            \\    });
            \\    return { headers: headers, rawHeaders: rawHeaders };
            \\  };
            \\  const fetchResponseBuffer = async function(fetchResponse) {
            \\    if (fetchResponse && fetchResponse.body && typeof fetchResponse.body.getReader === 'function') {
            \\      const reader = fetchResponse.body.getReader();
            \\      const chunks = [];
            \\      while (true) {
            \\        const step = await reader.read();
            \\        if (!step || step.done) break;
            \\        const value = step.value;
            \\        if (!value) continue;
            \\        if (globalThis._wizpNodeBuffer.Buffer.isBuffer(value)) chunks.push(value);
            \\        else if (value instanceof Uint8Array) chunks.push(globalThis._wizpNodeBuffer.Buffer.from(value));
            \\        else chunks.push(globalThis._wizpNodeBuffer.Buffer.from(String(value)));
            \\      }
            \\      return chunks.length > 0 ? globalThis._wizpNodeBuffer.Buffer.concat(chunks) : globalThis._wizpNodeBuffer.Buffer.alloc(0);
            \\    }
            \\    const bytes = await fetchResponse.arrayBuffer();
            \\    return bytes && bytes.byteLength > 0 ? globalThis._wizpNodeBuffer.Buffer.from(bytes) : globalThis._wizpNodeBuffer.Buffer.alloc(0);
            \\  };
            \\  const nativeRequestModule = function(target) {
            \\    return /^https:/i.test(String(target || '')) ? (globalThis._wizpNativeHttps || null) : (globalThis._wizpNativeHttp || null);
            \\  };
            \\  const shouldUseNativeRequest = function(target) {
            \\    return isLocalTarget(target) || (globalThis._wizpIsAllowlistedNetworkTarget(target) && globalThis._wizpHasExtensionNetworkConsent());
            \\  };
            \\  class ClientRequest extends globalThis._wizpNodeStream.Writable {
            \\    constructor(requestInfo, auditEntry) {
            \\      super((requestInfo && requestInfo.options) || {});
            \\      globalThis._wizpAttachRefable(this);
            \\      this.aborted = false;
            \\      this.destroyed = false;
            \\      this._wizpAuditEntry = auditEntry || null;
            \\      this._wizpRequestOptions = (requestInfo && requestInfo.options) || {};
            \\      this._wizpTarget = requestTarget(this._wizpRequestOptions);
            \\      this._wizpHeaders = outgoingHeadersObject(this._wizpRequestOptions.headers);
            \\      this._wizpChunks = [];
            \\      this._wizpAbortController = typeof AbortController === 'function' ? new AbortController() : null;
            \\      this.method = String(this._wizpRequestOptions.method || 'GET').toUpperCase();
            \\      this.protocol = String(this._wizpRequestOptions.protocol || (/^https:/i.test(this._wizpTarget) ? 'https:' : 'http:'));
            \\      this.host = String(this._wizpRequestOptions.host || this._wizpRequestOptions.hostname || '');
            \\      this.path = String(this._wizpRequestOptions.path || '/');
            \\      if (requestInfo && typeof requestInfo.callback === 'function') this.once('response', requestInfo.callback);
            \\    }
            \\    write(chunk, encoding, callback) {
            \\      if (typeof encoding === 'function') callback = encoding;
            \\      if (chunk !== undefined && chunk !== null) {
            \\        if (globalThis._wizpNodeBuffer.Buffer.isBuffer(chunk)) this._wizpChunks.push(chunk);
            \\        else if (chunk instanceof Uint8Array) this._wizpChunks.push(globalThis._wizpNodeBuffer.Buffer.from(chunk));
            \\        else this._wizpChunks.push(globalThis._wizpNodeBuffer.Buffer.from(String(chunk)));
            \\      }
            \\      if (callback) callback();
            \\      return true;
            \\    }
            \\    end(chunk, encoding, callback) {
            \\      if (typeof chunk === 'function') callback = chunk;
            \\      if (typeof encoding === 'function') callback = encoding;
            \\      if (chunk !== undefined && chunk !== null) this.write(chunk);
            \\      if (this._wizpAuditEntry) this._wizpAuditEntry.requestEnded = true;
            \\      const response = new globalThis._wizpNodeStream.Readable();
            \\      const local = isLocalTarget(this._wizpTarget);
            \\      const allowlisted = globalThis._wizpIsAllowlistedNetworkTarget(this._wizpTarget);
            \\      const externalConsent = globalThis._wizpHasExtensionNetworkConsent();
            \\      const canFetch = (local || (allowlisted && externalConsent)) && !!globalThis._wizpOriginalFetch;
            \\      response.resume = function() { return response; };
            \\      response.setEncoding = function() { return response; };
            \\      Promise.resolve().then(async () => {
            \\        if (canFetch) {
            \\          try {
            \\            if (this._wizpAuditEntry) this._wizpAuditEntry.fetchAttempted = true;
            \\            const method = this.method || 'GET';
            \\            const bodyBuffer = this._wizpChunks.length > 0 ? globalThis._wizpNodeBuffer.Buffer.concat(this._wizpChunks) : null;
            \\            const fetchInit = {
            \\              method: method,
            \\              headers: Object.assign({}, this._wizpHeaders),
            \\              signal: this._wizpAbortController ? this._wizpAbortController.signal : undefined,
            \\            };
            \\            if (bodyBuffer && method !== 'GET' && method !== 'HEAD') fetchInit.body = bodyBuffer;
            \\            const fetchResponse = await globalThis._wizpOriginalFetch(this._wizpTarget, fetchInit);
            \\            const responseHeaders = responseHeadersObject(fetchResponse.headers);
            \\            if (this._wizpAuditEntry) {
            \\              this._wizpAuditEntry.fetchResolved = true;
            \\              this._wizpAuditEntry.responseStatus = Number(fetchResponse.status || 0);
            \\            }
            \\            response.statusCode = Number(fetchResponse.status || 0);
            \\            response.statusMessage = String(fetchResponse.statusText || '');
            \\            response.headers = responseHeaders.headers;
            \\            response.rawHeaders = responseHeaders.rawHeaders;
            \\            response.url = fetchResponse.url || this._wizpTarget;
            \\            response.httpVersion = '1.1';
            \\            response.complete = false;
            \\            this.emit('response', response);
            \\            const responseBuffer = await fetchResponseBuffer(fetchResponse);
            \\            if (this._wizpAuditEntry) {
            \\              this._wizpAuditEntry.bodyResolved = true;
            \\              this._wizpAuditEntry.responseBytes = Number(responseBuffer && responseBuffer.length ? responseBuffer.length : 0);
            \\            }
            \\            if (responseBuffer && responseBuffer.length > 0) response.push(responseBuffer);
            \\            response.complete = true;
            \\            response.push(null);
            \\            this.emit('finish');
            \\            this.emit('close');
            \\            if (callback) callback();
            \\            return;
            \\          } catch (error) {
            \\            if (this._wizpAuditEntry) this._wizpAuditEntry.nativeError = String(error && error.message ? error.message : error);
            \\            this.destroy(error);
            \\            if (callback) callback();
            \\            return;
            \\          }
            \\        }
            \\        const body = local
            \\          ? ''
            \\          : JSON.stringify({ blocked: true, url: globalThis._wizpRedactUrlForAudit(this._wizpTarget), reason: 'external extension network is disabled by default' });
            \\        response.statusCode = local ? 204 : 451;
            \\        response.statusMessage = local ? 'No Content' : 'WIZP Network Blocked';
            \\        response.headers = local ? {} : { 'content-type': 'application/json', 'content-length': String(globalThis._wizpNodeBuffer.Buffer.byteLength(body, 'utf8')) };
            \\        this.emit('response', response);
            \\        if (body) response.push(globalThis._wizpNodeBuffer.Buffer.from(body, 'utf8'));
            \\        response.push(null);
            \\        this.emit('finish');
            \\        this.emit('close');
            \\        if (callback) callback();
            \\      });
            \\      return this;
            \\    }
            \\    abort() {
            \\      this.aborted = true;
            \\      if (this._wizpAbortController) {
            \\        try { this._wizpAbortController.abort(); } catch (_) {}
            \\      }
            \\      this.emit('abort');
            \\      this.emit('close');
            \\    }
            \\    destroy(error) {
            \\      this.destroyed = true;
            \\      if (this._wizpAbortController) {
            \\        try { this._wizpAbortController.abort(); } catch (_) {}
            \\      }
            \\      if (error) this.emit('error', error);
            \\      this.emit('close');
            \\      return this;
            \\    }
            \\    setHeader(name, value) { this._wizpHeaders[String(name || '').toLowerCase()] = Array.isArray(value) ? value.map(String).join(', ') : String(value); }
            \\    getHeader(name) { return this._wizpHeaders[String(name || '').toLowerCase()]; }
            \\    getHeaders() { return Object.assign({}, this._wizpHeaders); }
            \\    removeHeader(name) { delete this._wizpHeaders[String(name || '').toLowerCase()]; }
            \\    setTimeout(timeout, callback) { if (callback) this.once('timeout', callback); return this; }
            \\  }
            \\  const request = function(options, callback) {
            \\    const requestInfo = normalizeRequestArgs(arguments);
            \\    const target = requestTarget(requestInfo.options);
            \\    const moduleName = /^https:/i.test(String(target || '')) ? 'https' : 'http';
            \\    const local = isLocalTarget(target);
            \\    const allowlisted = globalThis._wizpIsAllowlistedNetworkTarget(target);
            \\    const externalConsent = globalThis._wizpHasExtensionNetworkConsent();
            \\    const native = nativeRequestModule(target);
            \\    const useFetch = (local || (allowlisted && externalConsent)) && !!globalThis._wizpOriginalFetch;
            \\    const useNative = !useFetch && (local || (allowlisted && externalConsent)) && !!(native && typeof native.request === 'function');
            \\    const auditHost = globalThis._wizpAuditHostForTarget(target);
            \\    const auditEntry = { module: moduleName, options: globalThis._wizpRedactUrlForAudit(target), local: local, allowlisted: allowlisted, explicitConsent: externalConsent, consentRequired: !!(!local && allowlisted), allowlistRaw: globalThis._wizpRedactSensitiveText(String(globalThis._wizpExtensionNetworkAllowlist || '')), allowlistEntries: Array.isArray(globalThis._wizpNetworkAllowlist) ? globalThis._wizpNetworkAllowlist.map(function(entry) { return globalThis._wizpRedactSensitiveText(entry); }).join('|') : '', host: auditHost, nativeAvailable: !!(native && typeof native.request === 'function'), requestEnded: false, fetchAttempted: false, fetchResolved: false, responseStatus: 0, bodyResolved: false, responseBytes: 0 };
            \\    globalThis._wizpNetworkAudit = globalThis._wizpNetworkAudit || [];
            \\    if (useFetch) {
            \\      auditEntry.passthrough = 'fetch-request';
            \\      globalThis._wizpNetworkAudit.push(auditEntry);
            \\      return new ClientRequest(requestInfo, auditEntry);
            \\    }
            \\    if (useNative) {
            \\      try {
            \\        auditEntry.passthrough = 'native-request';
            \\        globalThis._wizpNetworkAudit.push(auditEntry);
            \\        return native.request.apply(native, arguments);
            \\      } catch (error) {
            \\        auditEntry.passthrough = 'native-request-failed';
            \\        auditEntry.nativeError = String(error && error.message ? error.message : error);
            \\      }
            \\    }
            \\    if (!auditEntry.passthrough) auditEntry.passthrough = local || (allowlisted && externalConsent) ? 'shim-fallback' : 'blocked';
            \\    globalThis._wizpNetworkAudit.push(auditEntry);
            \\    return new ClientRequest(requestInfo, auditEntry);
            \\  };
            \\  const get = function(options, callback) {
            \\    const req = request(options, callback);
            \\    req.end();
            \\    return req;
            \\  };
            \\  class Server extends globalThis._wizpNodeEvents.EventEmitter {
            \\    constructor(options, requestListener) {
            \\      super();
            \\      globalThis._wizpAttachRefable(this);
            \\      this.listening = false;
            \\      this.timeout = 0;
            \\      this.keepAliveTimeout = 5000;
            \\      if (typeof options === 'function') requestListener = options;
            \\      if (requestListener) this.on('request', requestListener);
            \\    }
            \\    listen(options, host, callback) {
            \\      if (typeof options === 'function') callback = options;
            \\      if (typeof host === 'function') callback = host;
            \\      this.listening = true;
            \\      if (callback) this.once('listening', callback);
            \\      Promise.resolve().then(() => this.emit('listening'));
            \\      return this;
            \\    }
            \\    close(callback) {
            \\      this.listening = false;
            \\      if (callback) Promise.resolve().then(function() { callback(); });
            \\      this.emit('close');
            \\      return this;
            \\    }
            \\    address() { return { address: '127.0.0.1', family: 'IPv4', port: 0 }; }
            \\    setTimeout(timeout, callback) { this.timeout = Number(timeout) || 0; if (callback) this.on('timeout', callback); return this; }
            \\  }
            \\  const createServer = function(options, requestListener) { return new Server(options, requestListener); };
            \\  class Agent {
            \\    constructor(options) {
            \\      this.options = Object.assign({}, options || {});
            \\      this.keepAlive = !!this.options.keepAlive;
            \\      this.maxSockets = this.options.maxSockets || Infinity;
            \\      this.maxFreeSockets = this.options.maxFreeSockets || 256;
            \\      this.requests = {};
            \\      this.sockets = {};
            \\      this.freeSockets = {};
            \\    }
            \\    destroy() {}
            \\  }
            \\  return { request, get, createServer, Server, Agent, globalAgent: new Agent(), STATUS_CODES: { 204: 'No Content' }, ClientRequest };
            \\})();
            \\globalThis._wizpNodeHttps = Object.assign({}, globalThis._wizpNodeHttp, { globalAgent: new globalThis._wizpNodeHttp.Agent({ rejectUnauthorized: true }) });
            \\globalThis._wizpOriginalFetch = globalThis.fetch ? globalThis.fetch.bind(globalThis) : null;
            \\globalThis._wizpBlockedFetchResponse = function(url) {
            \\  const isGitKrakenConfig = /^https:\/\/configs\.gitkraken\.dev\/gitlens\//.test(url);
            \\  const auditUrl = globalThis._wizpRedactUrlForAudit(url);
            \\  const payload = isGitKrakenConfig
            \\    ? { blocked: true, offline: true, url: auditUrl, v: 1, promos: [], promosV2: [], cli: { minimumCoreVersion: '999.0.0', minimumProxyVersion: '999.0.0' }, git: { env: {} }, reason: 'external extension network is disabled by default' }
            \\    : { blocked: true, url: auditUrl, reason: 'external extension network is disabled by default' };
            \\  const status = isGitKrakenConfig ? 200 : 451;
            \\  const statusText = isGitKrakenConfig ? 'WIZP Offline Config' : 'WIZP Network Blocked';
            \\  const body = JSON.stringify(payload);
            \\  if (typeof globalThis.Response === 'function') {
            \\    return new globalThis.Response(body, {
            \\      status: status,
            \\      statusText: statusText,
            \\      headers: { 'content-type': 'application/json' }
            \\    });
            \\  }
            \\  const headers = { get: function(name) { return String(name || '').toLowerCase() === 'content-type' ? 'application/json' : null; }, has: function(name) { return String(name || '').toLowerCase() === 'content-type'; } };
            \\  return {
            \\    ok: status >= 200 && status < 300,
            \\    status: status,
            \\    statusText: statusText,
            \\    url: url,
            \\    redirected: false,
            \\    type: 'basic',
            \\    headers: headers,
            \\    text: async function() { return body; },
            \\    json: async function() { return JSON.parse(body); },
            \\    arrayBuffer: async function() {
            \\      const buffer = globalThis._wizpNodeBuffer.Buffer.from(body);
            \\      return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
            \\    },
            \\    clone: function() { return globalThis._wizpBlockedFetchResponse(url); }
            \\  };
            \\};
            \\globalThis.fetch = function(input, init) {
            \\  const url = typeof input === 'string' ? input : (input && input.url ? input.url : String(input || ''));
            \\  const isInternalWizpBridge = /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\/api\/(rpc|extension-rpc|extension\/lsp\/reply|extension\/ui\/reply)\b/.test(url);
            \\  const local = /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(url);
            \\  const allowlisted = globalThis._wizpIsAllowlistedNetworkTarget(url);
            \\  const externalConsent = globalThis._wizpHasExtensionNetworkConsent();
            \\  const canFetch = (local || (allowlisted && externalConsent)) && globalThis._wizpOriginalFetch;
            \\  if (!isInternalWizpBridge) {
            \\    globalThis._wizpNetworkAudit = globalThis._wizpNetworkAudit || [];
            \\    globalThis._wizpNetworkAudit.push({ module: 'fetch', options: globalThis._wizpRedactUrlForAudit(url), local: local, allowlisted: allowlisted, explicitConsent: externalConsent, consentRequired: !!(!local && allowlisted), host: globalThis._wizpAuditHostForTarget(url), fetchAttempted: !!canFetch, fetchResolved: false, passthrough: canFetch ? 'fetch' : 'blocked' });
            \\  }
            \\  if (canFetch) {
            \\    return globalThis._wizpOriginalFetch(input, init);
            \\  }
            \\  return Promise.resolve(globalThis._wizpBlockedFetchResponse(url));
            \\};
            \\globalThis._wizpNodeZlib = (function() {
            \\  const asBuffer = function(value) {
            \\    if (globalThis._wizpNodeBuffer.Buffer.isBuffer(value)) return value;
            \\    if (value instanceof Uint8Array) return globalThis._wizpNodeBuffer.Buffer.from(value);
            \\    return globalThis._wizpNodeBuffer.Buffer.from(String(value || ''));
            \\  };
            \\  const asyncPass = function(input, options, callback) {
            \\    if (typeof options === 'function') callback = options;
            \\    const output = asBuffer(input);
            \\    if (callback) Promise.resolve().then(function() { callback(null, output); });
            \\  };
            \\  const syncPass = function(input) { return asBuffer(input); };
            \\  const passthroughStream = function() { return new globalThis._wizpNodeStream.PassThrough(); };
            \\  return {
            \\    gzip: asyncPass,
            \\    gunzip: asyncPass,
            \\    deflate: asyncPass,
            \\    inflate: asyncPass,
            \\    unzip: asyncPass,
            \\    brotliCompress: asyncPass,
            \\    brotliDecompress: asyncPass,
            \\    gzipSync: syncPass,
            \\    gunzipSync: syncPass,
            \\    deflateSync: syncPass,
            \\    inflateSync: syncPass,
            \\    unzipSync: syncPass,
            \\    brotliCompressSync: syncPass,
            \\    brotliDecompressSync: syncPass,
            \\    createGzip: passthroughStream,
            \\    createGunzip: passthroughStream,
            \\    createDeflate: passthroughStream,
            \\    createInflate: passthroughStream,
            \\    createUnzip: passthroughStream,
            \\    constants: {}
            \\  };
            \\})();
            \\globalThis._wizpNodeNet = (function() {
            \\  globalThis._wizpNetNextPort = globalThis._wizpNetNextPort || 41000;
            \\  class Socket extends globalThis._wizpNodeStream.Duplex {
            \\    constructor(options) {
            \\      super(options || {});
            \\      globalThis._wizpAttachRefable(this);
            \\      this.connecting = false;
            \\      this.destroyed = false;
            \\      this.remoteAddress = undefined;
            \\      this.remotePort = undefined;
            \\      this.localAddress = '127.0.0.1';
            \\      this.localPort = 0;
            \\    }
            \\    connect(options, host, listener) {
            \\      if (typeof options === 'number') options = { port: options, host: host };
            \\      if (typeof host === 'function') listener = host;
            \\      this.connecting = true;
            \\      this.remoteAddress = (options && options.host) || host || '127.0.0.1';
            \\      this.remotePort = (options && options.port) || 0;
            \\      if (listener) this.once('connect', listener);
            \\      Promise.resolve().then(() => { this.connecting = false; this.emit('connect'); });
            \\      return this;
            \\    }
            \\    setEncoding() { return this; }
            \\    setKeepAlive() { return this; }
            \\    setNoDelay() { return this; }
            \\    setTimeout(timeout, callback) { if (callback) this.once('timeout', callback); return this; }
            \\    address() { return { address: this.localAddress, family: 'IPv4', port: this.localPort }; }
            \\  }
            \\  class Server extends globalThis._wizpNodeStream.Stream {
            \\    constructor(options, listener) {
            \\      super(options || {});
            \\      globalThis._wizpAttachRefable(this);
            \\      this.listening = false;
            \\      this._wizpAddress = { address: '127.0.0.1', family: 'IPv4', port: 0 };
            \\      if (typeof options === 'function') this.on('connection', options);
            \\      if (listener) this.on('connection', listener);
            \\    }
            \\    listen(options, host, callback) {
            \\      if (typeof options === 'function') callback = options;
            \\      if (typeof options === 'number') options = { port: options, host: host };
            \\      if (typeof host === 'function') callback = host;
            \\      this.listening = true;
            \\      const requestedPort = options && typeof options.port === 'number' ? options.port : (typeof options === 'number' ? options : 0);
            \\      const requestedHost = (options && options.host) || (typeof host === 'string' ? host : '') || '127.0.0.1';
            \\      const normalizedHost = requestedHost === 'localhost' ? '127.0.0.1' : requestedHost;
            \\      const nextPort = requestedPort > 0 ? requestedPort : (globalThis._wizpNetNextPort++);
            \\      this._wizpAddress = { address: normalizedHost, family: 'IPv4', port: nextPort };
            \\      if (callback) this.once('listening', callback);
            \\      Promise.resolve().then(() => this.emit('listening'));
            \\      return this;
            \\    }
            \\    close(callback) {
            \\      this.listening = false;
            \\      if (callback) Promise.resolve().then(function() { callback(); });
            \\      this.emit('close');
            \\      return this;
            \\    }
            \\    address() { return this._wizpAddress; }
            \\    getConnections(callback) { if (callback) callback(null, 0); }
            \\  }
            \\  const createConnection = function(options, host, listener) { return new Socket().connect(options, host, listener); };
            \\  const createServer = function(options, listener) { return new Server(options, listener); };
            \\  const isIPv4 = function(input) { return /^\d{1,3}(\.\d{1,3}){3}$/.test(String(input || '')); };
            \\  const isIPv6 = function(input) { return String(input || '').indexOf(':') >= 0; };
            \\  const isIP = function(input) { return isIPv4(input) ? 4 : isIPv6(input) ? 6 : 0; };
            \\  return { Socket, Server, createConnection, connect: createConnection, createServer, isIP, isIPv4, isIPv6 };
            \\})();
            \\globalThis._wizpNodeDns = (function() {
            \\  let defaultResultOrder = 'verbatim';
            \\  const constants = {
            \\    ADDRCONFIG: 32,
            \\    V4MAPPED: 8,
            \\    NODATA: 'ENODATA',
            \\    FORMERR: 'EFORMERR',
            \\    SERVFAIL: 'ESERVFAIL',
            \\    NOTFOUND: 'ENOTFOUND',
            \\    NOTIMP: 'ENOTIMP',
            \\    REFUSED: 'EREFUSED',
            \\    BADQUERY: 'EBADQUERY',
            \\    BADNAME: 'EBADNAME',
            \\    BADFAMILY: 'EBADFAMILY',
            \\    BADRESP: 'EBADRESP',
            \\    CONNREFUSED: 'ECONNREFUSED',
            \\    TIMEOUT: 'ETIMEOUT',
            \\    EOF: 'EOF',
            \\    FILE: 'EFILE',
            \\    NOMEM: 'ENOMEM',
            \\    DESTRUCTION: 'EDESTRUCTION',
            \\    BADSTR: 'EBADSTR',
            \\    BADFLAGS: 'EBADFLAGS',
            \\    NONAME: 'ENONAME',
            \\    BADHINTS: 'EBADHINTS',
            \\    NOTINITIALIZED: 'ENOTINITIALIZED',
            \\    LOADIPHLPAPI: 'ELOADIPHLPAPI',
            \\    ADDRGETNETWORKPARAMS: 'EADDRGETNETWORKPARAMS',
            \\    CANCELLED: 'ECANCELLED'
            \\  };
            \\  const makeError = function(code, hostname, syscall) {
            \\    const error = new Error((syscall || 'query') + ' ' + code + ' ' + String(hostname || ''));
            \\    error.code = code;
            \\    error.errno = code;
            \\    error.hostname = String(hostname || '');
            \\    error.syscall = syscall || 'query';
            \\    return error;
            \\  };
            \\  const normalizeLookupArgs = function(hostname, options, callback) {
            \\    if (typeof options === 'function') { callback = options; options = {}; }
            \\    if (typeof options === 'number') options = { family: options };
            \\    return { hostname: String(hostname || ''), options: options || {}, callback };
            \\  };
            \\  const localhostAddress = function(hostname, family) {
            \\    const host = String(hostname || '').toLowerCase();
            \\    if (host === 'localhost' || host === '') return family === 6 ? { address: '::1', family: 6 } : { address: '127.0.0.1', family: 4 };
            \\    if (globalThis._wizpNodeNet.isIPv4(host)) return { address: host, family: 4 };
            \\    if (globalThis._wizpNodeNet.isIPv6(host)) return { address: host, family: 6 };
            \\    return null;
            \\  };
            \\  const lookup = function(hostname, options, callback) {
            \\    const args = normalizeLookupArgs(hostname, options, callback);
            \\    if (typeof args.callback !== 'function') throw new TypeError('The "callback" argument must be of type function');
            \\    const family = Number(args.options.family || 0);
            \\    const item = localhostAddress(args.hostname, family);
            \\    Promise.resolve().then(function() {
            \\      if (!item) return args.callback(makeError(constants.NOTFOUND, args.hostname, 'getaddrinfo'));
            \\      if (args.options.all) return args.callback(null, [item]);
            \\      args.callback(null, item.address, item.family);
            \\    });
            \\  };
            \\  const lookupService = function(address, port, callback) {
            \\    if (typeof callback !== 'function') throw new TypeError('The "callback" argument must be of type function');
            \\    Promise.resolve().then(function() {
            \\      if (!globalThis._wizpNodeNet.isIP(String(address || ''))) return callback(makeError(constants.NOTFOUND, address, 'getnameinfo'));
            \\      callback(null, String(address) === '127.0.0.1' || String(address) === '::1' ? 'localhost' : String(address), String(port || '0'));
            \\    });
            \\  };
            \\  const resolve = function(hostname, rrtype, callback) {
            \\    if (typeof rrtype === 'function') { callback = rrtype; rrtype = 'A'; }
            \\    if (typeof callback !== 'function') throw new TypeError('The "callback" argument must be of type function');
            \\    const type = String(rrtype || 'A').toUpperCase();
            \\    Promise.resolve().then(function() {
            \\      const item = localhostAddress(hostname, type === 'AAAA' ? 6 : 4);
            \\      if (!item) return callback(makeError(constants.NOTFOUND, hostname, 'query' + type));
            \\      callback(null, [item.address]);
            \\    });
            \\  };
            \\  const emptyResolver = function(hostname, callback) {
            \\    if (typeof callback !== 'function') throw new TypeError('The "callback" argument must be of type function');
            \\    Promise.resolve().then(function() { callback(makeError(constants.NOTFOUND, hostname, 'query')); });
            \\  };
            \\  const reverse = function(address, callback) {
            \\    if (typeof callback !== 'function') throw new TypeError('The "callback" argument must be of type function');
            \\    Promise.resolve().then(function() {
            \\      if (!globalThis._wizpNodeNet.isIP(String(address || ''))) return callback(makeError(constants.NOTFOUND, address, 'getHostByAddr'));
            \\      callback(null, [String(address) === '127.0.0.1' || String(address) === '::1' ? 'localhost' : String(address)]);
            \\    });
            \\  };
            \\  const promises = {
            \\    lookup: function(hostname, options) {
            \\      return new Promise(function(resolvePromise, reject) {
            \\        lookup(hostname, options || {}, function(error, address, family) {
            \\          if (error) reject(error);
            \\          else if (options && options.all) resolvePromise(address);
            \\          else resolvePromise({ address, family });
            \\        });
            \\      });
            \\    },
            \\    lookupService: function(address, port) {
            \\      return new Promise(function(resolvePromise, reject) {
            \\        lookupService(address, port, function(error, hostname, service) {
            \\          error ? reject(error) : resolvePromise({ hostname, service });
            \\        });
            \\      });
            \\    },
            \\    resolve: function(hostname, rrtype) {
            \\      return new Promise(function(resolvePromise, reject) {
            \\        resolve(hostname, rrtype || 'A', function(error, addresses) { error ? reject(error) : resolvePromise(addresses); });
            \\      });
            \\    },
            \\    reverse: function(address) {
            \\      return new Promise(function(resolvePromise, reject) {
            \\        reverse(address, function(error, hostnames) { error ? reject(error) : resolvePromise(hostnames); });
            \\      });
            \\    },
            \\    setServers: function() {},
            \\    getServers: function() { return []; },
            \\    setDefaultResultOrder: function(order) { defaultResultOrder = String(order || 'verbatim'); },
            \\    getDefaultResultOrder: function() { return defaultResultOrder; }
            \\  };
            \\  promises.resolve4 = function(hostname) { return promises.resolve(hostname, 'A'); };
            \\  promises.resolve6 = function(hostname) { return promises.resolve(hostname, 'AAAA'); };
            \\  promises.resolveAny = function(hostname) { return Promise.reject(makeError(constants.NOTFOUND, hostname, 'queryAny')); };
            \\  promises.resolveCname = promises.resolveMx = promises.resolveNaptr = promises.resolveNs = promises.resolvePtr = promises.resolveSoa = promises.resolveSrv = promises.resolveTxt = function(hostname) { return Promise.reject(makeError(constants.NOTFOUND, hostname, 'query')); };
            \\  return {
            \\    ADDRCONFIG: constants.ADDRCONFIG,
            \\    V4MAPPED: constants.V4MAPPED,
            \\    promises,
            \\    lookup,
            \\    lookupService,
            \\    resolve,
            \\    resolve4: function(hostname, options, callback) { if (typeof options === 'function') callback = options; resolve(hostname, 'A', callback); },
            \\    resolve6: function(hostname, options, callback) { if (typeof options === 'function') callback = options; resolve(hostname, 'AAAA', callback); },
            \\    resolveAny: emptyResolver,
            \\    resolveCname: emptyResolver,
            \\    resolveMx: emptyResolver,
            \\    resolveNaptr: emptyResolver,
            \\    resolveNs: emptyResolver,
            \\    resolvePtr: emptyResolver,
            \\    resolveSoa: emptyResolver,
            \\    resolveSrv: emptyResolver,
            \\    resolveTxt: emptyResolver,
            \\    reverse,
            \\    setServers: function() {},
            \\    getServers: function() { return []; },
            \\    setDefaultResultOrder: function(order) { defaultResultOrder = String(order || 'verbatim'); },
            \\    getDefaultResultOrder: function() { return defaultResultOrder; },
            \\    isIP: globalThis._wizpNodeNet.isIP,
            \\    isIPv4: globalThis._wizpNodeNet.isIPv4,
            \\    isIPv6: globalThis._wizpNodeNet.isIPv6
            \\  };
            \\})();
            \\globalThis._wizpNodeTls = (function() {
            \\  const connect = function(options, host, listener) {
            \\    if (typeof options === 'number') options = { port: options, host: host };
            \\    if (typeof host === 'function') listener = host;
            \\    const socket = globalThis._wizpNodeNet.connect(options || {}, listener);
            \\    socket.authorized = true;
            \\    socket.encrypted = true;
            \\    socket.getPeerCertificate = function() { return {}; };
            \\    socket.getCipher = function() { return { name: 'TLS_NULL_WITH_NULL_NULL', version: 'TLSv1.3' }; };
            \\    return socket;
            \\  };
            \\  return {
            \\    connect,
            \\    createSecureContext: function(options) { return { context: options || {} }; },
            \\    TLSSocket: globalThis._wizpNodeNet.Socket,
            \\    rootCertificates: []
            \\  };
            \\})();
            \\globalThis._wizpNodePunycode = {
            \\  version: '2.1.0',
            \\  toASCII: function(input) { return String(input || ''); },
            \\  toUnicode: function(input) { return String(input || ''); },
            \\  encode: function(input) { return String(input || ''); },
            \\  decode: function(input) { return String(input || ''); },
            \\  ucs2: {
            \\    decode: function(input) { return Array.from(String(input || '')).map(function(ch) { return ch.codePointAt(0) || 0; }); },
            \\    encode: function(points) { return (points || []).map(function(point) { return String.fromCodePoint(point || 0); }).join(''); }
            \\  }
            \\};
            \\globalThis._wizpNodeOs = {
            \\  EOL: '\n',
            \\  constants: {
            \\    signals: {
            \\      SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGILL: 4, SIGTRAP: 5, SIGABRT: 6, SIGBUS: 7,
            \\      SIGFPE: 8, SIGKILL: 9, SIGUSR1: 10, SIGSEGV: 11, SIGUSR2: 12, SIGPIPE: 13,
            \\      SIGALRM: 14, SIGTERM: 15, SIGCHLD: 17, SIGCONT: 18, SIGSTOP: 19, SIGTSTP: 20,
            \\      SIGTTIN: 21, SIGTTOU: 22, SIGURG: 23, SIGXCPU: 24, SIGXFSZ: 25, SIGVTALRM: 26,
            \\      SIGPROF: 27, SIGWINCH: 28, SIGIO: 29, SIGSYS: 31
            \\    },
            \\    errno: {}
            \\  },
            \\  platform: function() { return globalThis._wizpNodeProcess.platform; },
            \\  arch: function() { return globalThis._wizpNodeProcess.arch; },
            \\  hostname: function() { return 'wizp-localhost'; },
            \\  homedir: function() { return (globalThis._wizpNodeProcess.env && globalThis._wizpNodeProcess.env.HOME) || '.'; },
            \\  tmpdir: function() { return (globalThis._wizpNodeProcess.env && (globalThis._wizpNodeProcess.env.TMPDIR || globalThis._wizpNodeProcess.env.TEMP || globalThis._wizpNodeProcess.env.TMP)) || '/tmp'; },
            \\  type: function() { return 'Linux'; },
            \\  release: function() { return 'shim'; },
            \\  cpus: function() { return []; },
            \\  loadavg: function() { return [0, 0, 0]; },
            \\  freemem: function() { return 0; },
            \\  totalmem: function() { return 0; },
            \\  networkInterfaces: function() { return {}; },
            \\  userInfo: function() { return { username: (globalThis._wizpNodeProcess.env && globalThis._wizpNodeProcess.env.USER) || 'wizp', uid: -1, gid: -1, shell: '/bin/sh', homedir: (globalThis._wizpNodeProcess.env && globalThis._wizpNodeProcess.env.HOME) || '.' }; }
            \\};
            \\globalThis._wizpNativeFs = globalThis._wizpNativeFs || (function() {
            \\  try { return typeof require === 'function' ? require('node:fs') : null; } catch (_) { return null; }
            \\})();
            \\globalThis._wizpLoadMementoStore = async function(scope, filePath) {
            \\  if (globalThis._wizpMementoStores[scope]) return globalThis._wizpMementoStores[scope];
            \\  let store = {};
            \\  const fs = globalThis._wizpNativeFs;
            \\  try {
            \\    if (fs && filePath && fs.existsSync(filePath)) {
            \\      store = JSON.parse(fs.readFileSync(filePath, 'utf8') || '{}') || {};
            \\    } else if (globalThis.Bun && filePath) {
            \\      const file = globalThis.Bun.file(filePath);
            \\      if (await file.exists()) store = JSON.parse(await file.text() || '{}') || {};
            \\    }
            \\  } catch (error) { globalThis._wizpMementoLoadError = String(error && error.message ? error.message : error); store = {}; }
            \\  globalThis._wizpMementoStores[scope] = store;
            \\  return store;
            \\};
            \\globalThis._wizpMakeMemento = function(scope, filePath) {
            \\  let store = globalThis._wizpMementoStores[scope];
            \\  if (!store) {
            \\    store = {};
            \\    globalThis._wizpMementoStores[scope] = store;
            \\  }
            \\  const persist = async function() {
            \\    const fs = globalThis._wizpNativeFs;
            \\    if (!filePath) return;
            \\    try {
            \\      if (fs) {
            \\        fs.mkdirSync(globalThis._wizpNodePath.dirname(filePath), { recursive: true });
            \\        fs.writeFileSync(filePath, JSON.stringify(store, null, 2));
            \\      } else if (globalThis.Bun && typeof globalThis.Bun.write === 'function') {
            \\        await globalThis.Bun.write(filePath, JSON.stringify(store, null, 2));
            \\      }
            \\    } catch (error) { globalThis._wizpMementoPersistError = String(error && error.message ? error.message : error); }
            \\  };
            \\  return {
            \\    get: function(key, defaultValue) {
            \\      globalThis._wizpDebugLog('memento.get', scope, String(key || ''));
            \\      return Object.prototype.hasOwnProperty.call(store, key) ? store[key] : defaultValue;
            \\    },
            \\    update: async function(key, value) { if (value === undefined) delete store[key]; else store[key] = value; await persist(); },
            \\    keys: function() { return Object.keys(store); },
            \\    setKeysForSync: function(keys) { store.__syncKeys = keys || []; persist(); }
            \\  };
            \\};
            \\globalThis._wizpSecretEncode = function(scope, value) {
            \\  const text = String(value);
            \\  const key = String(scope || 'wizp-secret');
            \\  let out = '';
            \\  for (let i = 0; i < text.length; i++) out += String.fromCharCode(text.charCodeAt(i) ^ key.charCodeAt(i % key.length));
            \\  if (typeof Buffer !== 'undefined') return Buffer.from(out, 'binary').toString('base64');
            \\  return btoa(out);
            \\};
            \\globalThis._wizpSecretDecode = function(scope, encoded) {
            \\  const raw = typeof Buffer !== 'undefined' ? Buffer.from(String(encoded || ''), 'base64').toString('binary') : atob(String(encoded || ''));
            \\  const key = String(scope || 'wizp-secret');
            \\  let out = '';
            \\  for (let i = 0; i < raw.length; i++) out += String.fromCharCode(raw.charCodeAt(i) ^ key.charCodeAt(i % key.length));
            \\  return out;
            \\};
            \\globalThis._wizpLoadSecretStore = async function(scope, filePath) {
            \\  if (globalThis._wizpSecretStores[scope]) return globalThis._wizpSecretStores[scope];
            \\  const store = {};
            \\  const fs = globalThis._wizpNativeFs;
            \\  try {
            \\    let payload = null;
            \\    if (fs && filePath && fs.existsSync(filePath)) {
            \\      payload = JSON.parse(fs.readFileSync(filePath, 'utf8') || '{}') || {};
            \\    } else if (globalThis.Bun && filePath) {
            \\      const file = globalThis.Bun.file(filePath);
            \\      if (await file.exists()) payload = JSON.parse(await file.text() || '{}') || {};
            \\    }
            \\    const values = payload && payload.values ? payload.values : {};
            \\    for (const key of Object.keys(values)) store[key] = globalThis._wizpSecretDecode(scope, values[key]);
            \\  } catch (error) { globalThis._wizpSecretLoadError = String(error && error.message ? error.message : error); }
            \\  globalThis._wizpSecretStores[scope] = store;
            \\  return store;
            \\};
            \\globalThis._wizpMakeSecretStorage = function(scope, filePath) {
            \\  const store = globalThis._wizpSecretStores[scope] = globalThis._wizpSecretStores[scope] || {};
            \\  const listeners = [];
            \\  const fire = function(key) { for (const listener of listeners.slice()) listener({ key: key }); };
            \\  const persist = async function() {
            \\    if (!filePath) return;
            \\    const values = {};
            \\    for (const key of Object.keys(store)) values[key] = globalThis._wizpSecretEncode(scope, store[key]);
            \\    const payload = { backend: 'encrypted-fallback', osKeyring: false, scope: scope, values: values };
            \\    const text = JSON.stringify(payload, null, 2);
            \\    const fs = globalThis._wizpNativeFs;
            \\    try {
            \\      if (fs) {
            \\        fs.mkdirSync(globalThis._wizpNodePath.dirname(filePath), { recursive: true });
            \\        fs.writeFileSync(filePath, text);
            \\      } else if (globalThis.Bun && typeof globalThis.Bun.write === 'function') {
            \\        await globalThis.Bun.write(filePath, text);
            \\      }
            \\    } catch (error) { globalThis._wizpSecretPersistError = String(error && error.message ? error.message : error); }
            \\  };
            \\  return {
            \\    get: async function(key) {
            \\      globalThis._wizpDebugLog('secrets.get', scope, String(key || ''));
            \\      return store[key];
            \\    },
            \\    store: async function(key, value) { store[key] = String(value); await persist(); fire(key); },
            \\    delete: async function(key) { delete store[key]; await persist(); fire(key); },
            \\    _metadata: function() { return { backend: 'encrypted-fallback', osKeyring: false, file: filePath || null, plaintextOnDisk: false }; },
            \\    onDidChange: function(listener) { listeners.push(listener); return { dispose: function() { const idx = listeners.indexOf(listener); if (idx >= 0) listeners.splice(idx, 1); } }; }
            \\  };
            \\};
            \\globalThis._wizpMakeEnvironmentVariableCollection = function(scope) {
            \\  const entries = globalThis._wizpEnvCollections[scope] = globalThis._wizpEnvCollections[scope] || {};
            \\  const collection = {
            \\    persistent: true,
            \\    replace: function(variable, value, options) { entries[variable] = { type: 1, value: String(value), options: options || {} }; },
            \\    append: function(variable, value, options) { entries[variable] = { type: 2, value: String(value), options: options || {} }; },
            \\    prepend: function(variable, value, options) { entries[variable] = { type: 3, value: String(value), options: options || {} }; },
            \\    get: function(variable) { return entries[variable]; },
            \\    delete: function(variable) { delete entries[variable]; },
            \\    clear: function() { for (const key of Object.keys(entries)) delete entries[key]; },
            \\    forEach: function(callback, thisArg) { for (const key of Object.keys(entries)) callback.call(thisArg, key, entries[key], collection); },
            \\    getScoped: function(scope) { return collection; },
            \\    description: undefined
            \\  };
            \\  return collection;
            \\};
        , "require-shim");

        const cwd: [:0]u8 = std.Io.Dir.cwd().realPathFileAlloc(compat_runtime.io(), ".", self.allocator) catch try compat_runtime.dupeZ(self.allocator, ".");
        defer self.allocator.free(cwd);
        var cwd_json_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer cwd_json_buf.deinit();
        try writeJsonString(&cwd_json_buf.writer, cwd);
        const cwd_js = try std.fmt.allocPrint(
            self.allocator,
            "globalThis._wizpCwd = {s};",
            .{cwd_json_buf.written()},
        );
        defer self.allocator.free(cwd_js);
        try self.engine.evalVoid(cwd_js, "cwd");

        const initial_config_json = compat_runtime.getEnvVarOwned(self.allocator, "WIZP_EXTENSION_CONFIGURATION_JSON") catch try self.allocator.dupe(u8, "{}");
        defer self.allocator.free(initial_config_json);
        var initial_config_json_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer initial_config_json_buf.deinit();
        try writeJsonString(&initial_config_json_buf.writer, initial_config_json);
        const initial_config_js = try std.fmt.allocPrint(
            self.allocator,
            "globalThis._wizpInitialExtensionConfigurationJson = {s};",
            .{initial_config_json_buf.written()},
        );
        defer self.allocator.free(initial_config_js);
        try self.engine.evalVoid(initial_config_js, "initial-extension-configuration");

        var env_json_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer env_json_buf.deinit();
        const env_writer = &env_json_buf.writer;
        try env_writer.writeByte('{');
        var first_env = true;
        var environment = try compat_runtime.environmentMap(self.allocator);
        defer environment.deinit();
        for (environment.keys(), environment.values()) |key, value| {
            if (!first_env) try env_writer.writeByte(',');
            first_env = false;
            try writeJsonString(env_writer, key);
            try env_writer.writeByte(':');
            try writeJsonString(env_writer, value);
        }
        try env_writer.writeByte('}');
        const process_env_js = try std.fmt.allocPrint(
            self.allocator,
            "globalThis._wizpProcessEnv = {s};",
            .{env_json_buf.written()},
        );
        defer self.allocator.free(process_env_js);
        try self.engine.evalVoid(process_env_js, "process-env");

        const network_allowlist_raw = compat_runtime.getEnvVarOwned(self.allocator, "WIZP_EXTENSION_NETWORK_ALLOWLIST") catch try self.allocator.dupe(u8, "");
        defer self.allocator.free(network_allowlist_raw);
        var network_allowlist_json: std.Io.Writer.Allocating = .init(self.allocator);
        defer network_allowlist_json.deinit();
        try writeJsonString(&network_allowlist_json.writer, network_allowlist_raw);
        const network_allowlist_js = try std.fmt.allocPrint(
            self.allocator,
            "globalThis._wizpExtensionNetworkAllowlist = {s};",
            .{network_allowlist_json.written()},
        );
        defer self.allocator.free(network_allowlist_js);
        try self.engine.evalVoid(network_allowlist_js, "extension-network-allowlist");

        const network_consent_raw = compat_runtime.getEnvVarOwned(self.allocator, "WIZP_EXTENSION_NETWORK_CONSENT") catch try self.allocator.dupe(u8, "");
        defer self.allocator.free(network_consent_raw);
        var network_consent_json: std.Io.Writer.Allocating = .init(self.allocator);
        defer network_consent_json.deinit();
        try writeJsonString(&network_consent_json.writer, network_consent_raw);
        const network_consent_js = try std.fmt.allocPrint(
            self.allocator,
            "globalThis._wizpExtensionNetworkConsent = {s};",
            .{network_consent_json.written()},
        );
        defer self.allocator.free(network_consent_js);
        try self.engine.evalVoid(network_consent_js, "extension-network-consent");

        const message_selection_mode = compat_runtime.getEnvVarOwned(self.allocator, "WIZP_EXTENSION_MESSAGE_SELECTION") catch try self.allocator.dupe(u8, "");
        defer self.allocator.free(message_selection_mode);
        var message_selection_json: std.Io.Writer.Allocating = .init(self.allocator);
        defer message_selection_json.deinit();
        try writeJsonString(&message_selection_json.writer, message_selection_mode);
        const message_selection_js = try std.fmt.allocPrint(
            self.allocator,
            "globalThis._wizpMessageSelectionMode = {s};",
            .{message_selection_json.written()},
        );
        defer self.allocator.free(message_selection_js);
        try self.engine.evalVoid(message_selection_js, "message-selection-mode");

        const quick_pick_selection_mode = compat_runtime.getEnvVarOwned(self.allocator, "WIZP_EXTENSION_QUICK_PICK_SELECTION") catch try self.allocator.dupe(u8, "");
        defer self.allocator.free(quick_pick_selection_mode);
        var quick_pick_selection_json: std.Io.Writer.Allocating = .init(self.allocator);
        defer quick_pick_selection_json.deinit();
        try writeJsonString(&quick_pick_selection_json.writer, quick_pick_selection_mode);
        const quick_pick_selection_js = try std.fmt.allocPrint(
            self.allocator,
            "globalThis._wizpQuickPickSelectionMode = {s};",
            .{quick_pick_selection_json.written()},
        );
        defer self.allocator.free(quick_pick_selection_js);
        try self.engine.evalVoid(quick_pick_selection_js, "quick-pick-selection-mode");

        const native_fork_enabled = compat_runtime.hasEnvVar("WIZP_EXTENSION_NATIVE_FORK");
        const native_fork_js = try std.fmt.allocPrint(self.allocator, "globalThis._wizpNativeForkEnabled = {};", .{native_fork_enabled});
        defer self.allocator.free(native_fork_js);
        try self.engine.evalVoid(native_fork_js, "native-fork-flag");

        const activation_timeout_ms_raw = compat_runtime.getEnvVarOwned(self.allocator, "WIZP_EXTENSION_ACTIVATION_TIMEOUT_MS") catch try self.allocator.dupe(u8, "30000");
        defer self.allocator.free(activation_timeout_ms_raw);
        const activation_timeout_ms = std.fmt.parseInt(u32, activation_timeout_ms_raw, 10) catch 30000;
        const activation_timeout_js = try std.fmt.allocPrint(self.allocator, "globalThis._wizpActivationTimeoutMs = {};", .{activation_timeout_ms});
        defer self.allocator.free(activation_timeout_js);
        try self.engine.evalVoid(activation_timeout_js, "activation-timeout");

        // Inject vscode API context
        try self.engine.evalVoid(
            \\globalThis._wizpDebugEnabled = !!(globalThis._wizpProcessEnv && globalThis._wizpProcessEnv.WIZP_EXTENSION_DEBUG);
            \\globalThis._wizpDebugLog = function() {
            \\  if (!globalThis._wizpDebugEnabled) return;
            \\  const line = Array.prototype.slice.call(arguments).map(function(part) { return String(part); }).join(' ');
            \\  try {
            \\    if (globalThis._wizpNodeProcess && globalThis._wizpNodeProcess.stderr && typeof globalThis._wizpNodeProcess.stderr.write === 'function') {
            \\      globalThis._wizpNodeProcess.stderr.write('[WIZP api] ' + line + '\n');
            \\      return;
            \\    }
            \\  } catch (_) {}
            \\  try { console.error('[WIZP api] ' + line); } catch (_) {}
            \\};
            \\globalThis._wizpContext = {
            \\  version: "1.110.11652",
            \\  // workspace API
            \\  workspace: {
            \\    workspaceFolders: [],
            \\    rootPath: globalThis._wizpCwd || '.',
            \\    isTrusted: true,
            \\    _fsProviders: {},
            \\    _textDocumentContentProviders: {},
            \\    get textDocuments() { return Object.values(globalThis._wizpDocuments || {}); },
            \\    get notebookDocuments() { return []; },
            \\    getWorkspaceFolder: function(uri) { return globalThis._wizpContext.workspace.workspaceFolders[0]; },
            \\    asRelativePath: function(pathOrUri, includeWorkspaceFolder) {
            \\      const value = String(pathOrUri && (pathOrUri.fsPath || pathOrUri.path) ? (pathOrUri.fsPath || pathOrUri.path) : pathOrUri || '');
            \\      const folder = globalThis._wizpContext.workspace.workspaceFolders[0];
            \\      const root = folder && folder.uri ? (folder.uri.fsPath || folder.uri.path || '') : '';
            \\      let rel = root && value.startsWith(root) ? value.slice(root.length).replace(/^\/+/, '') : value;
            \\      if (includeWorkspaceFolder && folder && folder.name) rel = folder.name + '/' + rel;
            \\      return rel;
            \\    },
            \\    findFiles: async function(include, exclude, maxResults, token) {
            \\      const patternValue = include && include.pattern ? String(include.pattern) : String(include || '');
            \\      const baseUri = include && include.baseUri ? include.baseUri : (globalThis._wizpContext.workspace.workspaceFolders[0] || {}).uri;
            \\      const basePath = baseUri && (baseUri.fsPath || baseUri.path) ? (baseUri.fsPath || baseUri.path) : (globalThis._wizpCwd || '.');
            \\      const excludeValue = exclude && exclude.pattern ? String(exclude.pattern) : String(exclude || '');
            \\      const results = [];
            \\      const limit = maxResults === undefined || maxResults === null ? Infinity : Number(maxResults);
            \\      globalThis._wizpDebugLog('workspace.findFiles:start', 'include=' + patternValue, 'exclude=' + excludeValue, 'base=' + basePath, 'limit=' + String(limit));
            \\      const expandBraceGlobs = function(pattern) {
            \\        const raw = String(pattern || '').trim();
            \\        if (!raw) return [];
            \\        const match = raw.match(/^\{(.+)\}$/);
            \\        if (!match) return [raw];
            \\        return String(match[1] || '')
            \\          .split(',')
            \\          .map(function(part) { return String(part || '').trim(); })
            \\          .filter(Boolean);
            \\      };
            \\      const globToRegExp = function(pattern) {
            \\        let source = String(pattern || '**/*');
            \\        source = source.replace(/\*\*\//g, '::WIZP_GLOBSTAR_DIR::');
            \\        source = source.replace(/\*\*/g, '::WIZP_GLOBSTAR::');
            \\        source = source.replace(/[.+^$()|[\]\\]/g, '\\$&');
            \\        source = source.replace(/\*/g, '[^/]*');
            \\        source = source.replace(/\?/g, '[^/]');
            \\        source = source.replace(/::WIZP_GLOBSTAR_DIR::/g, '(?:.*/)?');
            \\        source = source.replace(/::WIZP_GLOBSTAR::/g, '.*');
            \\        return new RegExp('^' + source + '$');
            \\      };
            \\      const includeMatchers = expandBraceGlobs(patternValue || '**/*').map(globToRegExp);
            \\      const excludeMatchers = expandBraceGlobs(excludeValue).map(globToRegExp);
            \\      if (globalThis._wizpDebugEnabled) {
            \\        globalThis._wizpDebugLog(
            \\          'workspace.findFiles:matchers',
            \\          'include=' + JSON.stringify(includeMatchers.map(function(re) { return re.source; })),
            \\          'exclude=' + JSON.stringify(excludeMatchers.map(function(re) { return re.source; }))
            \\        );
            \\      }
            \\      const walk = async function(dir, rel) {
            \\        if (token && token.isCancellationRequested) return;
            \\        if (results.length >= limit) return;
            \\        let entries = [];
            \\        try {
            \\          entries = await globalThis._wizpContext.workspace.fs.readDirectory(globalThis._wizpContext.Uri.file(dir));
            \\        } catch (_) {
            \\          return;
            \\        }
            \\        if (globalThis._wizpDebugEnabled && !rel) {
            \\          const preview = (entries || []).slice(0, 12).map(function(entry) {
            \\            if (Array.isArray(entry)) return String(entry[0] || '') + ':' + String(entry[1] || 0);
            \\            const entryName = typeof entry === 'string' ? entry : String(entry && entry.name ? entry.name : '');
            \\            const kind = entry && entry.isDirectory && entry.isDirectory() ? 'dir' : 'file';
            \\            return entryName + ':' + kind;
            \\          });
            \\          globalThis._wizpDebugLog('workspace.findFiles:entries', 'dir=' + dir, 'items=' + JSON.stringify(preview));
            \\        }
            \\        for (const entry of entries || []) {
            \\          if (results.length >= limit) break;
            \\          const name = Array.isArray(entry) ? String(entry[0] || '') : (typeof entry === 'string' ? entry : entry.name);
            \\          if (!name || name === 'node_modules' || name === '.git') continue;
            \\          const childRel = rel ? rel + '/' + name : name;
            \\          const childPath = globalThis._wizpNodePath.join(dir, name);
            \\          const isDirectory = Array.isArray(entry)
            \\            ? Number(entry[1] || 0) === 2
            \\            : !!(entry && entry.isDirectory && entry.isDirectory());
            \\          if (isDirectory) {
            \\            await walk(childPath, childRel);
            \\          } else if (includeMatchers.some(function(re) { return re.test(childRel); }) && !excludeMatchers.some(function(re) { return re.test(childRel); })) {
            \\            results.push(globalThis._wizpContext.Uri.file(childPath));
            \\          }
            \\        }
            \\      };
            \\      await walk(basePath, '');
            \\      globalThis._wizpDebugLog('workspace.findFiles:done', 'include=' + patternValue, 'count=' + String(results.length));
            \\      return results;
            \\    },
            \\    fs: {
            \\      _entries: {},
            \\      _record: function(path) {
            \\        const dir = globalThis._wizpNodePath.dirname(path);
            \\        const base = globalThis._wizpNodePath.basename(path);
            \\        if (!this._entries[dir]) this._entries[dir] = {};
            \\        this._entries[dir][base] = 1;
            \\      },
            \\      _forget: function(path) {
            \\        const dir = globalThis._wizpNodePath.dirname(path);
            \\        const base = globalThis._wizpNodePath.basename(path);
            \\        if (this._entries[dir]) delete this._entries[dir][base];
            \\      },
            \\      _path: function(uri) {
            \\        let value = uri && (uri.fsPath || uri.path) ? (uri.fsPath || uri.path) : String(uri);
            \\        value = String(value || '');
            \\        if (value.startsWith('file://')) value = value.slice('file://'.length);
            \\        if (value && !globalThis._wizpNodePath.isAbsolute(value)) {
            \\          value = globalThis._wizpNodePath.join(globalThis._wizpCwd || '.', value);
            \\        }
            \\        return value;
            \\      },
            \\      _provider: function(uri) {
            \\        const scheme = uri && uri.scheme ? uri.scheme : 'file';
            \\        if (scheme === 'file') return null;
            \\        const provider = globalThis._wizpContext.workspace._fsProviders[scheme];
            \\        if (!provider) throw new Error('No file system provider registered for scheme: ' + scheme);
            \\        return provider;
            \\      },
            \\      readFile: async function(uri) {
            \\        const provider = globalThis._wizpContext.workspace.fs._provider(uri);
            \\        if (provider) return await provider.readFile(uri);
            \\        const path = globalThis._wizpContext.workspace.fs._path(uri);
            \\        globalThis._wizpDebugLog('workspace.fs.readFile:start', path);
            \\        if (globalThis._wizpNativeFs && globalThis._wizpNativeFs.readFileSync) {
            \\          const nativeData = globalThis._wizpNodeBuffer.Buffer.from(globalThis._wizpNativeFs.readFileSync(path));
            \\          globalThis._wizpDebugLog('workspace.fs.readFile:done', path, 'bytes=' + String(nativeData.length || 0));
            \\          return nativeData;
            \\        }
            \\        const data = await Bun.file(path).arrayBuffer();
            \\        globalThis._wizpDebugLog('workspace.fs.readFile:done', path, 'bytes=' + String(data.byteLength || 0));
            \\        return globalThis._wizpNodeBuffer.Buffer.from(new Uint8Array(data));
            \\      },
            \\      writeFile: async function(uri, data) {
            \\        const provider = globalThis._wizpContext.workspace.fs._provider(uri);
            \\        if (provider) return await provider.writeFile(uri, data, {});
            \\        const path = globalThis._wizpContext.workspace.fs._path(uri);
            \\        if (globalThis.Bun && typeof globalThis.Bun.write === 'function') {
            \\          try {
            \\            const nodeFs = await import('node:fs');
            \\            if (nodeFs && nodeFs.promises && nodeFs.promises.mkdir) await nodeFs.promises.mkdir(globalThis._wizpNodePath.dirname(path), { recursive: true });
            \\          } catch (_) {}
            \\          await globalThis.Bun.write(path, globalThis._wizpNodeBuffer.Buffer.from(data || []));
            \\          globalThis._wizpContext.workspace.fs._record(path);
            \\          return;
            \\        }
            \\        if (globalThis._wizpNativeFs && globalThis._wizpNativeFs.writeFileSync) {
            \\          globalThis._wizpNativeFs.mkdirSync(globalThis._wizpNodePath.dirname(path), { recursive: true });
            \\          globalThis._wizpNativeFs.writeFileSync(path, globalThis._wizpNodeBuffer.Buffer.from(data || []));
            \\          globalThis._wizpContext.workspace.fs._record(path);
            \\          return;
            \\        }
            \\        await globalThis._wizpNodeFs.promises.mkdir(globalThis._wizpNodePath.dirname(path), { recursive: true });
            \\        await globalThis._wizpNodeFs.promises.writeFile(path, data);
            \\        globalThis._wizpContext.workspace.fs._record(path);
            \\      },
            \\      stat: async function(uri) {
            \\        const provider = globalThis._wizpContext.workspace.fs._provider(uri);
            \\        if (provider) return await provider.stat(uri);
            \\        const path = globalThis._wizpContext.workspace.fs._path(uri);
            \\        try {
            \\          try {
            \\            const nodeFs = await import('node:fs');
            \\            if (nodeFs && nodeFs.promises && nodeFs.promises.stat) {
            \\              const nativeStat = await nodeFs.promises.stat(path);
            \\              return { type: nativeStat.isDirectory && nativeStat.isDirectory() ? 2 : nativeStat.isSymbolicLink && nativeStat.isSymbolicLink() ? 64 : 1, ctime: nativeStat.ctimeMs || 0, mtime: nativeStat.mtimeMs || 0, size: nativeStat.size || 0 };
            \\            }
            \\          } catch (_) {}
            \\          if (globalThis._wizpNativeFs && globalThis._wizpNativeFs.statSync) {
            \\            const nativeStat = globalThis._wizpNativeFs.statSync(path);
            \\            return { type: nativeStat.isDirectory && nativeStat.isDirectory() ? 2 : nativeStat.isSymbolicLink && nativeStat.isSymbolicLink() ? 64 : 1, ctime: nativeStat.ctimeMs || 0, mtime: nativeStat.mtimeMs || 0, size: nativeStat.size || 0 };
            \\          }
            \\          const stat = await globalThis._wizpNodeFs.promises.stat(path);
            \\          return { type: stat.isDirectory && stat.isDirectory() ? 2 : stat.isSymbolicLink && stat.isSymbolicLink() ? 64 : 1, ctime: stat.ctimeMs || 0, mtime: stat.mtimeMs || 0, size: stat.size || 0 };
            \\        } catch (error) {
            \\          const fsError = globalThis._wizpContext.FileSystemError.FileNotFound(uri);
            \\          fsError.name = 'EntryNotFound (FileSystemError)';
            \\          throw fsError;
            \\        }
            \\      },
            \\      readDirectory: async function(uri) {
            \\        const provider = globalThis._wizpContext.workspace.fs._provider(uri);
            \\        if (provider) return await provider.readDirectory(uri);
            \\        const dir = globalThis._wizpContext.workspace.fs._path(uri);
            \\        try {
            \\          const nodeFs = await import('node:fs');
            \\          if (nodeFs && nodeFs.promises && nodeFs.promises.readdir) {
            \\            const nativeEntries = await nodeFs.promises.readdir(dir, { withFileTypes: true });
            \\            return nativeEntries.map(e => typeof e === 'string' ? [e, 0] : [e.name, e.isFile() ? 1 : e.isDirectory() ? 2 : e.isSymbolicLink() ? 64 : 0]);
            \\          }
            \\        } catch (_) {}
            \\        if (globalThis._wizpNativeFs && globalThis._wizpNativeFs.readdirSync) {
            \\          const nativeEntries = globalThis._wizpNativeFs.readdirSync(dir, { withFileTypes: true });
            \\          if (nativeEntries && nativeEntries.length) return nativeEntries.map(e => typeof e === 'string' ? [e, 0] : [e.name, e.isFile() ? 1 : e.isDirectory() ? 2 : e.isSymbolicLink() ? 64 : 0]);
            \\        }
            \\        if (globalThis._wizpContext.workspace.fs._entries[dir]) return Object.keys(globalThis._wizpContext.workspace.fs._entries[dir]).map(name => [name, 1]);
            \\        const entries = await globalThis._wizpNodeFs.promises.readdir(dir, { withFileTypes: true });
            \\        return entries.map(e => [e.name, e.isFile() ? 1 : e.isDirectory() ? 2 : e.isSymbolicLink() ? 64 : 0]);
            \\      },
            \\      createDirectory: async function(uri) {
            \\        const provider = globalThis._wizpContext.workspace.fs._provider(uri);
            \\        if (provider) return await provider.createDirectory(uri);
            \\        const dir = globalThis._wizpContext.workspace.fs._path(uri);
            \\        if (!globalThis._wizpContext.workspace.fs._entries[dir]) globalThis._wizpContext.workspace.fs._entries[dir] = {};
            \\        try {
            \\          const nodeFs = await import('node:fs');
            \\          if (nodeFs && nodeFs.promises && nodeFs.promises.mkdir) return await nodeFs.promises.mkdir(dir, { recursive: true });
            \\        } catch (_) {}
            \\        if (globalThis._wizpNativeFs && globalThis._wizpNativeFs.mkdirSync) return globalThis._wizpNativeFs.mkdirSync(dir, { recursive: true });
            \\        await globalThis._wizpNodeFs.promises.mkdir(dir, { recursive: true });
            \\      },
            \\      delete: async function(uri, options) {
            \\        const provider = globalThis._wizpContext.workspace.fs._provider(uri);
            \\        if (provider) return await provider.delete(uri, options || {});
            \\        const target = globalThis._wizpContext.workspace.fs._path(uri);
            \\        const rmOptions = { recursive: !!(options && options.recursive), force: !!(options && options.useTrash === false) };
            \\        globalThis._wizpContext.workspace.fs._forget(target);
            \\        if (globalThis._wizpNativeFs && globalThis._wizpNativeFs.rmSync) return globalThis._wizpNativeFs.rmSync(target, rmOptions);
            \\        if (globalThis._wizpNativeFs && globalThis._wizpNativeFs.statSync && globalThis._wizpNativeFs.readdirSync && globalThis._wizpNativeFs.unlinkSync && globalThis._wizpNativeFs.rmdirSync) {
            \\          const removeNative = function(path) {
            \\            let stat = null;
            \\            try { stat = globalThis._wizpNativeFs.statSync(path); } catch (_) { return; }
            \\            if (stat && stat.isDirectory && stat.isDirectory()) {
            \\              const entries = globalThis._wizpNativeFs.readdirSync(path);
            \\              for (const entry of entries) removeNative(globalThis._wizpNodePath.join(path, typeof entry === 'string' ? entry : entry.name));
            \\              globalThis._wizpNativeFs.rmdirSync(path);
            \\            } else {
            \\              globalThis._wizpNativeFs.unlinkSync(path);
            \\            }
            \\          };
            \\          removeNative(target);
            \\          return;
            \\        }
            \\        try {
            \\          const fs = await import('fs');
            \\          if (fs && fs.promises && fs.promises.rm) {
            \\            await fs.promises.rm(target, rmOptions);
            \\            return;
            \\          }
            \\        } catch (_) {}
            \\        await globalThis._wizpNodeFs.promises.rm(target, rmOptions);
            \\      },
            \\      copy: async function(source, target, options) {
            \\        const sourceProvider = globalThis._wizpContext.workspace.fs._provider(source);
            \\        const targetProvider = globalThis._wizpContext.workspace.fs._provider(target);
            \\        if (sourceProvider || targetProvider) {
            \\          if (sourceProvider !== targetProvider || !sourceProvider.copy) throw new Error('Provider copy requires same scheme and copy support');
            \\          return await sourceProvider.copy(source, target, options || {});
            \\        }
            \\        const src = globalThis._wizpContext.workspace.fs._path(source);
            \\        const dst = globalThis._wizpContext.workspace.fs._path(target);
            \\        if (globalThis._wizpNativeFs && globalThis._wizpNativeFs.cpSync) {
            \\          globalThis._wizpNativeFs.cpSync(src, dst, { recursive: true, force: !!(options && options.overwrite), errorOnExist: !(options && options.overwrite) });
            \\          globalThis._wizpContext.workspace.fs._record(dst);
            \\          return;
            \\        }
            \\        if (globalThis._wizpNativeFs && globalThis._wizpNativeFs.copyFileSync) {
            \\          globalThis._wizpNativeFs.mkdirSync(globalThis._wizpNodePath.dirname(dst), { recursive: true });
            \\          globalThis._wizpNativeFs.copyFileSync(src, dst);
            \\          globalThis._wizpContext.workspace.fs._record(dst);
            \\          return;
            \\        }
            \\        if (globalThis._wizpNativeFs && globalThis._wizpNativeFs.readFileSync && globalThis._wizpNativeFs.writeFileSync) {
            \\          globalThis._wizpNativeFs.mkdirSync(globalThis._wizpNodePath.dirname(dst), { recursive: true });
            \\          globalThis._wizpNativeFs.writeFileSync(dst, globalThis._wizpNativeFs.readFileSync(src));
            \\          globalThis._wizpContext.workspace.fs._record(dst);
            \\          return;
            \\        }
            \\        if (globalThis.Bun && typeof globalThis.Bun.write === 'function') {
            \\          await globalThis.Bun.write(dst, await globalThis.Bun.file(src).arrayBuffer());
            \\          globalThis._wizpContext.workspace.fs._record(dst);
            \\          return;
            \\        }
            \\        await globalThis._wizpNodeFs.promises.copyFile(src, dst);
            \\        globalThis._wizpContext.workspace.fs._record(dst);
            \\      },
            \\      rename: async function(source, target, options) {
            \\        const sourceProvider = globalThis._wizpContext.workspace.fs._provider(source);
            \\        const targetProvider = globalThis._wizpContext.workspace.fs._provider(target);
            \\        if (sourceProvider || targetProvider) {
            \\          if (sourceProvider !== targetProvider || !sourceProvider.rename) throw new Error('Provider rename requires same scheme and rename support');
            \\          return await sourceProvider.rename(source, target, options || {});
            \\        }
            \\        const src = globalThis._wizpContext.workspace.fs._path(source);
            \\        const dst = globalThis._wizpContext.workspace.fs._path(target);
            \\        if (globalThis._wizpNativeFs && globalThis._wizpNativeFs.renameSync) {
            \\          if (options && options.overwrite && globalThis._wizpNativeFs.rmSync) globalThis._wizpNativeFs.rmSync(dst, { recursive: true, force: true });
            \\          globalThis._wizpNativeFs.renameSync(src, dst);
            \\          globalThis._wizpContext.workspace.fs._forget(src);
            \\          globalThis._wizpContext.workspace.fs._record(dst);
            \\          return;
            \\        }
            \\        if (globalThis.Bun && typeof globalThis.Bun.write === 'function') {
            \\          await globalThis.Bun.write(dst, await globalThis.Bun.file(src).arrayBuffer());
            \\          globalThis._wizpContext.workspace.fs._forget(src);
            \\          globalThis._wizpContext.workspace.fs._record(dst);
            \\          return;
            \\        }
            \\        if (options && options.overwrite) await globalThis._wizpNodeFs.promises.rm(dst, { recursive: true, force: true });
            \\        await globalThis._wizpNodeFs.promises.rename(src, dst);
            \\        globalThis._wizpContext.workspace.fs._forget(src);
            \\        globalThis._wizpContext.workspace.fs._record(dst);
            \\      },
            \\    },
            \\    registerFileSystemProvider: function(scheme, provider, options) {
            \\      globalThis._wizpContext.workspace._fsProviders[scheme] = provider;
            \\      globalThis._wizp_uiQueue.push({ type: 'fsProviderRegistered', scheme: scheme, options: options || {} });
            \\      return { dispose: function() { delete globalThis._wizpContext.workspace._fsProviders[scheme]; } };
            \\    },
            \\    registerTextDocumentContentProvider: function(scheme, provider) {
            \\      globalThis._wizpContext.workspace._textDocumentContentProviders[scheme] = provider;
            \\      globalThis._wizp_uiQueue.push({ type: 'textDocumentContentProviderRegistered', scheme: scheme });
            \\      return { dispose: function() { delete globalThis._wizpContext.workspace._textDocumentContentProviders[scheme]; } };
            \\    },
            \\    createFileSystemWatcher: function(globPattern, ignoreCreateEvents, ignoreChangeEvents, ignoreDeleteEvents) {
            \\      const createEmitter = new globalThis._wizpContext.EventEmitter();
            \\      const changeEmitter = new globalThis._wizpContext.EventEmitter();
            \\      const deleteEmitter = new globalThis._wizpContext.EventEmitter();
            \\      const watcher = {
            \\        globPattern: globPattern,
            \\        ignoreCreateEvents: !!ignoreCreateEvents,
            \\        ignoreChangeEvents: !!ignoreChangeEvents,
            \\        ignoreDeleteEvents: !!ignoreDeleteEvents,
            \\        onDidCreate: createEmitter.event,
            \\        onDidChange: changeEmitter.event,
            \\        onDidDelete: deleteEmitter.event,
            \\        dispose: function() { createEmitter.dispose(); changeEmitter.dispose(); deleteEmitter.dispose(); }
            \\      };
            \\      globalThis._wizp_uiQueue.push({ type: 'fileSystemWatcherCreated', pattern: globPattern && globPattern.pattern ? globPattern.pattern : String(globPattern || '') });
            \\      return watcher;
            \\    },
            \\    onDidGrantWorkspaceTrust: function(callback) {
            \\      if (globalThis._wizpContext.workspace.isTrusted) Promise.resolve().then(function() { callback(); });
            \\      return { dispose: function() {} };
            \\    },
            \\    onDidOpenNotebookDocument: function(callback) { return { dispose: function() {} }; },
            \\    onDidCloseNotebookDocument: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeNotebookDocument: function(callback) { return { dispose: function() {} }; },
            \\    onDidSaveNotebookDocument: function(callback) { return { dispose: function() {} }; },
            \\    applyEdit: async function(edit) {
            \\      const fs = await import('fs');
            \\      const entries = edit && edit._entries ? edit._entries : [];
            \\      function pathOf(uri) { return uri && (uri.fsPath || uri.path) ? (uri.fsPath || uri.path) : String(uri); }
            \\      function offsetAt(text, pos) {
            \\        let line = 0, ch = 0;
            \\        for (let i = 0; i < text.length; i++) {
            \\          if (line === pos.line && ch === pos.character) return i;
            \\          if (text[i] === '\n') { line++; ch = 0; } else { ch++; }
            \\        }
            \\        return text.length;
            \\      }
            \\      for (const entry of entries) {
            \\        if (entry.kind === 'create') {
            \\          await fs.promises.mkdir(pathOf(entry.uri).split('/').slice(0, -1).join('/') || '.', { recursive: true });
            \\          await fs.promises.writeFile(pathOf(entry.uri), '', { flag: entry.options && entry.options.overwrite ? 'w' : 'wx' }).catch((err) => { if (!(entry.options && entry.options.ignoreIfExists && err && err.code === 'EEXIST')) throw err; });
            \\        } else if (entry.kind === 'delete') {
            \\          await fs.promises.rm(pathOf(entry.uri), { recursive: !!(entry.options && entry.options.recursive), force: !!(entry.options && entry.options.ignoreIfNotExists) });
            \\        } else if (entry.kind === 'rename') {
            \\          if (entry.options && entry.options.overwrite) await fs.promises.rm(pathOf(entry.newUri), { recursive: true, force: true });
            \\          await fs.promises.rename(pathOf(entry.oldUri), pathOf(entry.newUri));
            \\        } else if (entry.kind === 'edit') {
            \\          const path = pathOf(entry.uri);
            \\          let text = await fs.promises.readFile(path, 'utf8');
            \\          const edits = entry.edits.slice().sort((a, b) => offsetAt(text, b.range.start) - offsetAt(text, a.range.start));
            \\          for (const e of edits) {
            \\            const start = offsetAt(text, e.range.start);
            \\            const end = offsetAt(text, e.range.end);
            \\            text = text.slice(0, start) + e.newText + text.slice(end);
            \\          }
            \\          await fs.promises.writeFile(path, text);
            \\        }
            \\      }
            \\      return true;
            \\    },
            \\    _configuration: (function() {
            \\      try {
            \\        return JSON.parse(globalThis._wizpInitialExtensionConfigurationJson || '{}');
            \\      } catch (_) {
            \\        return {};
            \\      }
            \\    })(),
            \\    getConfiguration: function(section, scope) {
            \\      if (typeof WIZP_config_get === 'function') {
            \\        function summarizeNativeConfigValue(value) {
            \\          if (value === undefined || value === null) return value;
            \\          if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return value;
            \\          if (Array.isArray(value)) return value.slice(0, 16).map(summarizeNativeConfigValue);
            \\          if (typeof value === 'object') {
            \\            const summary = {};
            \\            const keys = Object.keys(value);
            \\            for (const key of keys.slice(0, 16)) summary[key] = summarizeNativeConfigValue(value[key]);
            \\            if (keys.length > 16) summary.__truncatedKeys = keys.length - 16;
            \\            return summary;
            \\          }
            \\          return String(value);
            \\        }
            \\        function recordNativeConfigurationRead(kind, key, payload) {
            \\          const reads = globalThis._wizpConfigurationReads = globalThis._wizpConfigurationReads || [];
            \\          const entry = Object.assign({
            \\            kind: kind,
            \\            section: section || '',
            \\            key: key === undefined || key === null ? '' : String(key)
            \\          }, payload || {});
            \\          reads.push(entry);
            \\          if (reads.length > 200) reads.splice(0, reads.length - 200);
            \\        }
            \\        const nativeApi = WIZP_config_get(section, scope);
            \\        if (!nativeApi || typeof nativeApi !== 'object') return nativeApi;
            \\        const wrapped = {
            \\          get: function(key, defaultValue) {
            \\            const value = typeof nativeApi.get === 'function' ? nativeApi.get(key, defaultValue) : nativeApi[key];
            \\            recordNativeConfigurationRead('get', key, {
            \\              defaultValue: summarizeNativeConfigValue(defaultValue),
            \\              value: summarizeNativeConfigValue(value === undefined && defaultValue !== undefined ? defaultValue : value)
            \\            });
            \\            return value === undefined && defaultValue !== undefined ? defaultValue : value;
            \\          },
            \\          has: function(key) {
            \\            const present = typeof nativeApi.has === 'function' ? nativeApi.has(key) : nativeApi[key] !== undefined;
            \\            recordNativeConfigurationRead('has', key, { value: !!present });
            \\            return !!present;
            \\          },
            \\          inspect: function(key) {
            \\            const value = typeof nativeApi.inspect === 'function' ? nativeApi.inspect(key) : undefined;
            \\            recordNativeConfigurationRead('inspect', key, { value: summarizeNativeConfigValue(value) });
            \\            return value;
            \\          },
            \\          update: function(key, value, target) {
            \\            recordNativeConfigurationRead('update', key, {
            \\              target: target === undefined || target === null ? null : target,
            \\              value: summarizeNativeConfigValue(value)
            \\            });
            \\            return typeof nativeApi.update === 'function' ? nativeApi.update(key, value, target) : Promise.resolve();
            \\          },
            \\          toJSON: function() {
            \\            return typeof nativeApi.toJSON === 'function' ? nativeApi.toJSON() : nativeApi;
            \\          }
            \\        };
            \\        return new Proxy(wrapped, {
            \\          get: function(target, prop) {
            \\            if (prop in target) return target[prop];
            \\            if (typeof prop !== 'string') return undefined;
            \\            return typeof nativeApi.get === 'function' ? nativeApi.get(prop) : nativeApi[prop];
            \\          },
            \\          has: function(target, prop) {
            \\            if (prop in target) return true;
            \\            if (typeof prop !== 'string') return false;
            \\            return typeof nativeApi.has === 'function' ? !!nativeApi.has(prop) : nativeApi[prop] !== undefined;
            \\          },
            \\          ownKeys: function(target) {
            \\            const snapshot = typeof nativeApi.toJSON === 'function' ? nativeApi.toJSON() : nativeApi;
            \\            const keys = snapshot && typeof snapshot === 'object' ? Object.keys(snapshot) : [];
            \\            for (const prop of Object.keys(target)) {
            \\              if (!keys.includes(prop)) keys.push(prop);
            \\            }
            \\            return keys;
            \\          },
            \\          getOwnPropertyDescriptor: function(target, prop) {
            \\            if (typeof prop === 'string' && prop in target) {
            \\              return { configurable: true, enumerable: false, writable: true, value: target[prop] };
            \\            }
            \\            if (typeof prop !== 'string') return undefined;
            \\            const snapshot = typeof nativeApi.toJSON === 'function' ? nativeApi.toJSON() : nativeApi;
            \\            if (snapshot && typeof snapshot === 'object' && Object.prototype.hasOwnProperty.call(snapshot, prop)) {
            \\              return { configurable: true, enumerable: true, writable: false, value: snapshot[prop] };
            \\            }
            \\            return undefined;
            \\          }
            \\        });
            \\      }
            \\      const root = globalThis._wizpContext.workspace._configuration;
            \\      function fullKey(key) { return [section, key].filter(function(part) { return part !== undefined && part !== null && String(part).length > 0; }).join('.'); }
            \\      function lookupIn(container, key) {
            \\        if (container && Object.prototype.hasOwnProperty.call(container, key)) return container[key];
            \\        const path = String(key || '').split('.').filter(Boolean);
            \\        let value = container;
            \\        for (const part of path) {
            \\          if (value === undefined || value === null || !Object.prototype.hasOwnProperty.call(value, part)) return undefined;
            \\          value = value[part];
            \\        }
            \\        return value;
            \\      }
            \\      function languageIdForScope() {
            \\        if (!scope) return undefined;
            \\        if (scope.languageId) return scope.languageId;
            \\        if (scope.document && scope.document.languageId) return scope.document.languageId;
            \\        const uri = scope.uri ? scope.uri.toString() : (scope.toString ? scope.toString() : '');
            \\        const doc = Object.values(globalThis._wizpDocuments || {}).find(function(item) { return item.uri && item.uri.toString && item.uri.toString() === uri; });
            \\        return doc && doc.languageId;
            \\      }
            \\      function pathForScope() {
            \\        if (scope && scope.uri) return scope.uri.fsPath || scope.uri.path || String(scope.uri);
            \\        if (scope && (scope.fsPath || scope.path)) return scope.fsPath || scope.path;
            \\        if (scope && scope.document && scope.document.uri) return scope.document.uri.fsPath || scope.document.uri.path || String(scope.document.uri);
            \\        if (scope && scope.toString) {
            \\          const value = String(scope);
            \\          if (value.indexOf('file://') === 0) return value.slice('file://'.length);
            \\        }
            \\        return '';
            \\      }
            \\      function workspaceFolderLayer() {
            \\        const folders = (((root || {}).__scopes || {}).workspaceFolders || {});
            \\        const targetPath = pathForScope();
            \\        let bestKey = '';
            \\        for (const key of Object.keys(folders)) {
            \\          if ((!bestKey || key.length > bestKey.length) && (!targetPath || targetPath === key || targetPath.indexOf(key.replace(/\/+$/, '') + '/') === 0)) bestKey = key;
            \\        }
            \\        return bestKey ? folders[bestKey] : undefined;
            \\      }
            \\      function langLayer(layer, languageId) {
            \\        return languageId && layer && layer.__languageOverrides ? layer.__languageOverrides[languageId] : undefined;
            \\      }
            \\      function lookup(key) {
            \\        const full = fullKey(key);
            \\        const scopes = (root || {}).__scopes || {};
            \\        const globalLayer = scopes.global || {};
            \\        const workspaceLayer = root || {};
            \\        const folderLayer = workspaceFolderLayer();
            \\        const languageId = languageIdForScope();
            \\        const layers = [globalLayer, langLayer(globalLayer, languageId), workspaceLayer, langLayer(workspaceLayer, languageId), folderLayer, langLayer(folderLayer, languageId)];
            \\        let found = undefined;
            \\        for (const layer of layers) {
            \\          const value = lookupIn(layer, full);
            \\          if (value !== undefined) found = value;
            \\        }
            \\        return found;
            \\      }
            \\      function assign(key, value) {
            \\        const path = fullKey(key).split('.').filter(Boolean);
            \\        if (!path.length) return;
            \\        let target = root;
            \\        for (let i = 0; i < path.length - 1; i++) target = target[path[i]] = target[path[i]] || {};
            \\        if (value === undefined) delete target[path[path.length - 1]]; else target[path[path.length - 1]] = value;
            \\      }
            \\      const contributedDefaults = globalThis._wizpContributedConfigurationDefaults || {};
            \\      // Core-owned defaults live here. Extension-owned defaults must come from
            \\      // contributed configuration metadata, not hand-written compatibility tables.
            \\      const coreDefaults = {
            \\          'files.exclude': {},
            \\          'files.eol': '\n',
            \\          'files.encoding': 'utf8',
            \\          'files.trimTrailingWhitespace': false,
            \\          'files.insertFinalNewline': false,
            \\          'editor.detectIndentation': false,
            \\          'editor.tabSize': 4,
            \\          'editor.indentSize': 'tabSize',
            \\          'editor.insertSpaces': true,
            \\          'git': { enabled: true, path: null, env: {}, autoRepositoryDetection: true, scanRepositories: [], ignoredRepositories: [], confirmSync: true, useCommitInputAsStashMessage: false, autofetch: false, terminalAuthentication: false },
            \\          'git.enabled': true,
            \\          'git.path': null,
            \\          'git.env': {},
            \\          'git.autoRepositoryDetection': true,
            \\          'git.scanRepositories': [],
            \\          'git.ignoredRepositories': [],
            \\          'git.confirmSync': true,
            \\          'git.useCommitInputAsStashMessage': false,
            \\          'git.autofetch': false,
            \\          'git.terminalAuthentication': false
            \\      };
            \\      function defaultFor(key) {
            \\        const full = fullKey(key);
            \\        if (Object.prototype.hasOwnProperty.call(contributedDefaults, full)) return contributedDefaults[full];
            \\        return Object.prototype.hasOwnProperty.call(coreDefaults, full) ? coreDefaults[full] : undefined;
            \\      }
            \\      function cloneValue(value) {
            \\        if (Array.isArray(value)) return value.map(cloneValue);
            \\        if (value && typeof value === 'object') {
            \\          const out = {};
            \\          for (const key of Object.keys(value)) out[key] = cloneValue(value[key]);
            \\          return out;
            \\        }
            \\        return value;
            \\      }
            \\      function assignPath(target, path, value) {
            \\        if (!target || !Array.isArray(path) || !path.length) return;
            \\        let cursor = target;
            \\        for (let i = 0; i < path.length - 1; i++) {
            \\          const part = path[i];
            \\          if (!cursor[part] || typeof cursor[part] !== 'object' || Array.isArray(cursor[part])) cursor[part] = {};
            \\          cursor = cursor[part];
            \\        }
            \\        cursor[path[path.length - 1]] = cloneValue(value);
            \\      }
            \\      function flattenLayer(layer, base, out) {
            \\        if (!layer || typeof layer !== 'object') return;
            \\        for (const key of Object.keys(layer)) {
            \\          if (!key || key === '__scopes' || key === '__languageOverrides') continue;
            \\          const value = layer[key];
            \\          const full = key.indexOf('.') >= 0 ? (base ? base + '.' + key : key) : (base ? base + '.' + key : key);
            \\          out[full] = value;
            \\          if (value && typeof value === 'object' && !Array.isArray(value)) flattenLayer(value, full, out);
            \\        }
            \\      }
            \\      let snapshotCache = null;
            \\      let defaultSnapshotCache = null;
            \\      function materializeDefaultsFrom(source) {
            \\        const merged = Object.create(null);
            \\        const prefix = section ? section + '.' : '';
            \\        function applyAbsoluteKey(full, value) {
            \\          if (typeof full !== 'string') return;
            \\          if (section) {
            \\            if (full === section) {
            \\              if (value && typeof value === 'object' && !Array.isArray(value)) {
            \\                const nested = {};
            \\                flattenLayer(value, '', nested);
            \\                for (const nestedKey of Object.keys(nested)) merged[nestedKey] = nested[nestedKey];
            \\              }
            \\              return;
            \\            }
            \\            if (!full.startsWith(prefix)) return;
            \\            merged[full.slice(prefix.length)] = value;
            \\            return;
            \\          }
            \\          merged[full] = value;
            \\        }
            \\        for (const full of Object.keys(source || {})) applyAbsoluteKey(full, source[full]);
            \\        const snapshot = {};
            \\        const orderedKeys = Object.keys(merged).sort(function(a, b) {
            \\          return a.split('.').length - b.split('.').length;
            \\        });
            \\        for (const key of orderedKeys) {
            \\          if (!key || key.indexOf('__') === 0) continue;
            \\          assignPath(snapshot, key.split('.').filter(Boolean), merged[key]);
            \\        }
            \\        return snapshot;
            \\      }
            \\      function materializeDefaultSnapshot() {
            \\        if (defaultSnapshotCache) return defaultSnapshotCache;
            \\        const snapshot = materializeDefaultsFrom(contributedDefaults);
            \\        const coreSnapshot = materializeDefaultsFrom(coreDefaults);
            \\        for (const key of Object.keys(coreSnapshot)) {
            \\          if (!Object.prototype.hasOwnProperty.call(snapshot, key)) snapshot[key] = coreSnapshot[key];
            \\        }
            \\        defaultSnapshotCache = snapshot;
            \\        return defaultSnapshotCache;
            \\      }
            \\      function materializeSnapshot() {
            \\        if (snapshotCache) return snapshotCache;
            \\        const scopes = (root || {}).__scopes || {};
            \\        const globalLayer = scopes.global || {};
            \\        const workspaceLayer = root || {};
            \\        const folderLayer = workspaceFolderLayer();
            \\        const languageId = languageIdForScope();
            \\        const merged = Object.create(null);
            \\        const prefix = section ? section + '.' : '';
            \\        function applyAbsoluteKey(full, value) {
            \\          if (typeof full !== 'string') return;
            \\          if (section) {
            \\            if (full === section) {
            \\              if (value && typeof value === 'object' && !Array.isArray(value)) {
            \\                const nested = {};
            \\                flattenLayer(value, '', nested);
            \\                for (const nestedKey of Object.keys(nested)) merged[nestedKey] = nested[nestedKey];
            \\              }
            \\              return;
            \\            }
            \\            if (!full.startsWith(prefix)) return;
            \\            merged[full.slice(prefix.length)] = value;
            \\            return;
            \\          }
            \\          merged[full] = value;
            \\        }
            \\        for (const full of Object.keys(contributedDefaults)) applyAbsoluteKey(full, contributedDefaults[full]);
            \\        for (const layer of [globalLayer, langLayer(globalLayer, languageId), workspaceLayer, langLayer(workspaceLayer, languageId), folderLayer, langLayer(folderLayer, languageId)]) {
            \\          const flat = {};
            \\          flattenLayer(layer, '', flat);
            \\          for (const full of Object.keys(flat)) applyAbsoluteKey(full, flat[full]);
            \\        }
            \\        const snapshot = {};
            \\        const orderedKeys = Object.keys(merged).sort(function(a, b) {
            \\          return a.split('.').length - b.split('.').length;
            \\        });
            \\        for (const key of orderedKeys) {
            \\          if (!key || key.indexOf('__') === 0) continue;
            \\          assignPath(snapshot, key.split('.').filter(Boolean), merged[key]);
            \\        }
            \\        snapshotCache = snapshot;
            \\        return snapshotCache;
            \\      }
            \\      function resolveProperty(key, defaultValue) {
            \\        const value = lookup(key);
            \\        if (value !== undefined) return value;
            \\        if (defaultValue !== undefined) return defaultValue;
            \\        const fallback = defaultFor(key);
            \\        if (fallback !== undefined) return fallback;
            \\        const snapshot = materializeSnapshot();
            \\        if (snapshot && typeof key === 'string') {
            \\          const snapshotValue = lookupIn(snapshot, key);
            \\          if (snapshotValue !== undefined) return snapshotValue;
            \\        }
            \\        return undefined;
            \\      }
            \\      function summarizeConfigValue(value) {
            \\        if (value === undefined || value === null) return value;
            \\        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return value;
            \\        if (Array.isArray(value)) return value.slice(0, 16).map(summarizeConfigValue);
            \\        if (typeof value === 'object') {
            \\          const summary = {};
            \\          const keys = Object.keys(value);
            \\          for (const key of keys.slice(0, 16)) summary[key] = summarizeConfigValue(value[key]);
            \\          if (keys.length > 16) summary.__truncatedKeys = keys.length - 16;
            \\          return summary;
            \\        }
            \\        return String(value);
            \\      }
            \\      function recordConfigurationRead(kind, key, payload) {
            \\        const reads = globalThis._wizpConfigurationReads = globalThis._wizpConfigurationReads || [];
            \\        const entry = Object.assign({
            \\          kind: kind,
            \\          section: section || '',
            \\          key: key === undefined || key === null ? '' : String(key)
            \\        }, payload || {});
            \\        reads.push(entry);
            \\        if (reads.length > 200) reads.splice(0, reads.length - 200);
            \\      }
            \\      const api = {
            \\        get: function(key, defaultValue) {
            \\          const value = resolveProperty(key, defaultValue);
            \\          recordConfigurationRead('get', key, {
            \\            defaultValue: summarizeConfigValue(defaultValue),
            \\            value: summarizeConfigValue(value === undefined && defaultValue !== undefined ? defaultValue : value)
            \\          });
            \\          return value === undefined && defaultValue !== undefined ? defaultValue : value;
            \\        },
            \\        has: function(key) {
            \\          const present = resolveProperty(key) !== undefined;
            \\          recordConfigurationRead('has', key, { value: present });
            \\          return present;
            \\        },
            \\        inspect: function(key) {
            \\          const full = fullKey(key);
            \\          const scopes = (root || {}).__scopes || {};
            \\          const globalLayer = scopes.global || {};
            \\          const workspaceLayer = root || {};
            \\          const folderLayer = workspaceFolderLayer();
            \\          const languageId = languageIdForScope();
            \\          const globalValue = lookupIn(globalLayer, full);
            \\          const workspaceValue = lookupIn(workspaceLayer, full);
            \\          const workspaceFolderValue = lookupIn(folderLayer, full);
            \\          const globalLanguageValue = lookupIn(langLayer(globalLayer, languageId), full);
            \\          const workspaceLanguageValue = lookupIn(langLayer(workspaceLayer, languageId), full);
            \\          const workspaceFolderLanguageValue = lookupIn(langLayer(folderLayer, languageId), full);
            \\          let defaultValue = defaultFor(key);
            \\          if (defaultValue === undefined) {
            \\            const defaultSnapshot = materializeDefaultSnapshot();
            \\            if (defaultSnapshot) {
            \\              const nestedDefaultValue = lookupIn(defaultSnapshot, key);
            \\              if (nestedDefaultValue !== undefined) defaultValue = nestedDefaultValue;
            \\            }
            \\          }
            \\          const result = { key: full, defaultValue: defaultValue, globalValue: globalValue, workspaceValue: workspaceValue, workspaceFolderValue: workspaceFolderValue, globalLanguageValue: globalLanguageValue, workspaceLanguageValue: workspaceLanguageValue, workspaceFolderLanguageValue: workspaceFolderLanguageValue };
            \\          recordConfigurationRead('inspect', key, { value: summarizeConfigValue(result) });
            \\          return result;
            \\        },
            \\        update: function(key, value, target) {
            \\          snapshotCache = null;
            \\          assign(key, value);
            \\          recordConfigurationRead('update', key, {
            \\            target: target === undefined || target === null ? null : target,
            \\            value: summarizeConfigValue(value)
            \\          });
            \\          return Promise.resolve();
            \\        },
            \\        toJSON: function() { return materializeSnapshot(); }
            \\      };
            \\      return new Proxy(api, {
            \\        get: function(target, prop) {
            \\          if (prop in target) return target[prop];
            \\          if (typeof prop !== 'string') return undefined;
            \\          return resolveProperty(prop);
            \\        },
            \\        has: function(target, prop) {
            \\          if (prop in target) return true;
            \\          return typeof prop === 'string' && resolveProperty(prop) !== undefined;
            \\        },
            \\        ownKeys: function(target) {
            \\          const snapshot = materializeSnapshot();
            \\          const keys = Object.keys(snapshot);
            \\          for (const prop of Object.keys(target)) {
            \\            if (!keys.includes(prop)) keys.push(prop);
            \\          }
            \\          return keys;
            \\        },
            \\        getOwnPropertyDescriptor: function(target, prop) {
            \\          if (typeof prop === 'string' && prop in target) {
            \\            return { configurable: true, enumerable: false, writable: true, value: target[prop] };
            \\          }
            \\          if (typeof prop !== 'string') return undefined;
            \\          const snapshot = materializeSnapshot();
            \\          if (Object.prototype.hasOwnProperty.call(snapshot, prop)) {
            \\            return { configurable: true, enumerable: true, writable: false, value: snapshot[prop] };
            \\          }
            \\          return undefined;
            \\        }
            \\      });
            \\    },
            \\    onDidChangeConfiguration: function(callback) { return { dispose: function() {} }; },
            \\    onDidRenameFiles: function(callback) { return { dispose: function() {} }; },
            \\    onDidDeleteFiles: function(callback) { return { dispose: function() {} }; },
            \\    onDidCreateFiles: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeWorkspaceFolders: function(callback) { return { dispose: function() {} }; },
            \\    registerPortAttributesProvider: function(selector, provider) {
            \\      const id = "portAttributes_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector || {}, provider: provider };
            \\      globalThis._wizpPortAttributesProviders.push(entry);
            \\      globalThis._wizp_uiQueue.push({type: "portAttributesProviderRegistered", id: id, selector: selector || {}});
            \\      return { dispose: function() {
            \\        globalThis._wizpPortAttributesProviders = globalThis._wizpPortAttributesProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    _makeTextDocument: function(uri, text, languageId, version) {
            \\      const parsedUri = typeof uri === 'string' ? globalThis._wizpContext.Uri.parse(uri) : uri;
            \\      const key = parsedUri && parsedUri.toString ? parsedUri.toString() : String(parsedUri);
            \\      const document = {
            \\        uri: parsedUri,
            \\        fileName: parsedUri.fsPath || parsedUri.path || key,
            \\        languageId: languageId || 'plaintext',
            \\        version: version || 1,
            \\        isDirty: false,
            \\        isClosed: false,
            \\        eol: 1,
            \\        lineCount: String(text || '').split('\n').length,
            \\        getText: function(range) {
            \\          if (!range) return document._text;
            \\          return document._text.slice(document.offsetAt(range.start), document.offsetAt(range.end));
            \\        },
            \\        lineAt: function(lineOrPosition) {
            \\          const line = typeof lineOrPosition === 'number' ? lineOrPosition : ((lineOrPosition && lineOrPosition.line) || 0);
            \\          const value = String(document._text || '').split('\n')[line] || '';
            \\          return {
            \\            lineNumber: line,
            \\            text: value,
            \\            range: new globalThis._wizpContext.Range(new globalThis._wizpContext.Position(line, 0), new globalThis._wizpContext.Position(line, value.length)),
            \\            rangeIncludingLineBreak: new globalThis._wizpContext.Range(new globalThis._wizpContext.Position(line, 0), new globalThis._wizpContext.Position(line, value.length + 1)),
            \\            firstNonWhitespaceCharacterIndex: value.search(/\S|$/),
            \\            isEmptyOrWhitespace: !value.trim()
            \\          };
            \\        },
            \\        offsetAt: function(position) {
            \\          let line = 0, ch = 0;
            \\          for (let i = 0; i < document._text.length; i++) {
            \\            if (line === position.line && ch === position.character) return i;
            \\            if (document._text[i] === '\n') { line++; ch = 0; } else { ch++; }
            \\          }
            \\          return document._text.length;
            \\        },
            \\        positionAt: function(offset) {
            \\          let line = 0, ch = 0;
            \\          const max = Math.max(0, Math.min(offset, document._text.length));
            \\          for (let i = 0; i < max; i++) {
            \\            if (document._text[i] === '\n') { line++; ch = 0; } else { ch++; }
            \\          }
            \\          return new globalThis._wizpContext.Position(line, ch);
            \\        },
            \\        getWordRangeAtPosition: function(position, regex) {
            \\          const safePosition = document.validatePosition(position || { line: 0, character: 0 });
            \\          const line = document.lineAt(safePosition.line);
            \\          const text = String((line && line.text) || '');
            \\          const baseFlags = regex && typeof regex.flags === 'string' ? regex.flags : '';
            \\          const wordRegex = regex instanceof RegExp
            \\            ? new RegExp(regex.source, baseFlags.indexOf('g') >= 0 ? baseFlags : (baseFlags + 'g'))
            \\            : /(-?\d*\.\d\w*)|([^\`\~\!\@\#\$\%\^\&\*\(\)\-\=\+\[\{\]\}\\\|\;\:\'\"\,\.\<\>\/\?\s]+)/g;
            \\          let match = null;
            \\          while ((match = wordRegex.exec(text)) !== null) {
            \\            const value = String((match && match[0]) || '');
            \\            if (!value) {
            \\              if (wordRegex.lastIndex === match.index) wordRegex.lastIndex += 1;
            \\              continue;
            \\            }
            \\            const start = match.index;
            \\            const end = start + value.length;
            \\            if (safePosition.character >= start && safePosition.character <= end) {
            \\              return new globalThis._wizpContext.Range(safePosition.line, start, safePosition.line, end);
            \\            }
            \\          }
            \\          return undefined;
            \\        },
            \\        validatePosition: function(position) {
            \\          const requestedLine = Number(position && position.line);
            \\          const requestedCharacter = Number(position && position.character);
            \\          const lines = String(document._text || '').split('\n');
            \\          const maxLine = Math.max(0, lines.length - 1);
            \\          const safeLine = Number.isFinite(requestedLine) ? Math.max(0, Math.min(requestedLine, maxLine)) : 0;
            \\          const lineText = lines[safeLine] || '';
            \\          const maxCharacter = lineText.length;
            \\          const safeCharacter = Number.isFinite(requestedCharacter) ? Math.max(0, Math.min(requestedCharacter, maxCharacter)) : 0;
            \\          return new globalThis._wizpContext.Position(safeLine, safeCharacter);
            \\        },
            \\        validateRange: function(range) {
            \\          const start = document.validatePosition(range && range.start ? range.start : { line: 0, character: 0 });
            \\          const end = document.validatePosition(range && range.end ? range.end : start);
            \\          if (end.line < start.line || (end.line === start.line && end.character < start.character)) {
            \\            return new globalThis._wizpContext.Range(start, start);
            \\          }
            \\          return new globalThis._wizpContext.Range(start, end);
            \\        },
            \\        save: async function() {
            \\          document._text = await globalThis._wizpContext.workspace._fireWillSaveTextDocument(document, 1);
            \\          document.isDirty = false;
            \\          globalThis._wizpContext.workspace._fireTextDocumentEvent('save', document);
            \\          return true;
            \\        },
            \\        _text: String(text || '')
            \\      };
            \\      globalThis._wizpDocuments[key] = document;
            \\      return document;
            \\    },
            \\    _inferLanguageIdForUri: function(uri) {
            \\      const parsedUri = typeof uri === 'string' ? globalThis._wizpContext.Uri.parse(uri) : uri;
            \\      const rawPath = String((parsedUri && (parsedUri.fsPath || parsedUri.path)) || '').replace(/\\/g, '/');
            \\      const fileName = rawPath.split('/').pop() || '';
            \\      const lowerName = fileName.toLowerCase();
            \\      if (lowerName === 'dockerfile' || lowerName.startsWith('dockerfile.')) return 'dockerfile';
            \\      if (lowerName === 'makefile') return 'makefile';
            \\      const extIndex = lowerName.lastIndexOf('.');
            \\      const ext = extIndex >= 0 ? lowerName.slice(extIndex) : '';
            \\      switch (ext) {
            \\        case '.js': case '.mjs': case '.cjs': return 'javascript';
            \\        case '.ts': case '.mts': case '.cts': return 'typescript';
            \\        case '.json': case '.jsonc': return 'json';
            \\        case '.md': case '.markdown': return 'markdown';
            \\        case '.html': case '.htm': return 'html';
            \\        case '.css': return 'css';
            \\        case '.py': return 'python';
            \\        case '.php': return 'php';
            \\        case '.zig': return 'zig';
            \\        case '.sh': case '.bash': case '.zsh': return 'shellscript';
            \\        case '.java': return 'java';
            \\        case '.go': return 'go';
            \\        case '.yaml': case '.yml': return 'yaml';
            \\        case '.cc': case '.cpp': case '.cxx': case '.c++': case '.hh': case '.hpp': case '.hxx': return 'cpp';
            \\        case '.c': return 'c';
            \\        default: return 'plaintext';
            \\      }
            \\    },
            \\    _fireTextDocumentEvent: function(kind, document, extra) {
            \\      const listeners = (globalThis._wizpTextDocumentListeners && globalThis._wizpTextDocumentListeners[kind]) || [];
            \\      const event = kind === 'change' ? Object.assign({ document: document, contentChanges: [] }, extra || {}) : document;
            \\      for (const callback of listeners.slice()) callback(event);
            \\    },
            \\    _changeTextDocument: function(document, edits) {
            \\      const before = document._text;
            \\      const after = globalThis._wizpContext.workspace._applyTextEdits(before, edits || []);
            \\      document._text = after;
            \\      document.version += 1;
            \\      document.isDirty = true;
            \\      document.lineCount = String(after || '').split('\n').length;
            \\      globalThis._wizpContext.workspace._fireTextDocumentEvent('change', document, { contentChanges: (edits || []).map(function(edit) { return { range: edit.range, text: edit.newText || '' }; }) });
            \\      return document;
            \\    },
            \\    _closeTextDocument: function(document) {
            \\      document.isClosed = true;
            \\      globalThis._wizpContext.workspace._fireTextDocumentEvent('close', document);
            \\      delete globalThis._wizpDocuments[document.uri.toString()];
            \\    },
            \\    openTextDocument: async function(uri) {
            \\      const parsedUri = typeof uri === 'string' ? globalThis._wizpContext.Uri.parse(uri) : uri;
            \\      const key = parsedUri && parsedUri.toString ? parsedUri.toString() : String(parsedUri);
            \\      if (globalThis._wizpDocuments[key]) return globalThis._wizpDocuments[key];
            \\      let text = '';
            \\      if (parsedUri && parsedUri.scheme === 'file') {
            \\        try {
            \\          const fs = await import('fs');
            \\          text = await fs.promises.readFile(parsedUri.fsPath || parsedUri.path, 'utf8');
            \\        } catch (_) {}
            \\      } else if (typeof WIZP_workspace_openTextDocument === 'function') {
            \\        return WIZP_workspace_openTextDocument(parsedUri);
            \\      }
            \\      const document = globalThis._wizpContext.workspace._makeTextDocument(
            \\        parsedUri,
            \\        text,
            \\        globalThis._wizpContext.workspace._inferLanguageIdForUri(parsedUri),
            \\        1
            \\      );
            \\      globalThis._wizpContext.workspace._fireTextDocumentEvent('open', document);
            \\      return document;
            \\    },
            \\    _willSaveTextDocumentListeners: [],
            \\    _applyTextEdits: function(text, edits) {
            \\      function offsetAt(value, pos) {
            \\        let line = 0, ch = 0;
            \\        for (let i = 0; i < value.length; i++) {
            \\          if (line === pos.line && ch === pos.character) return i;
            \\          if (value[i] === '\n') { line++; ch = 0; } else { ch++; }
            \\        }
            \\        return value.length;
            \\      }
            \\      const sorted = (edits || []).slice().sort((a, b) => offsetAt(text, b.range.start) - offsetAt(text, a.range.start));
            \\      for (const edit of sorted) {
            \\        const start = offsetAt(text, edit.range.start);
            \\        const end = offsetAt(text, edit.range.end);
            \\        text = text.slice(0, start) + edit.newText + text.slice(end);
            \\      }
            \\      return text;
            \\    },
            \\    _fireWillSaveTextDocument: async function(document, reason) {
            \\      let text = document && document.getText ? document.getText() : '';
            \\      const event = {
            \\        document: document,
            \\        reason: reason || 1,
            \\        waitUntil: function(thenable) {
            \\          event._waits.push(Promise.resolve(thenable).then(function(edits) {
            \\            text = globalThis._wizpContext.workspace._applyTextEdits(text, edits || []);
            \\          }));
            \\        },
            \\        _waits: []
            \\      };
            \\      for (const callback of globalThis._wizpContext.workspace._willSaveTextDocumentListeners.slice()) callback(event);
            \\      await Promise.all(event._waits);
            \\      return text;
            \\    },
            \\    onDidOpenTextDocument: function(callback) {
            \\      globalThis._wizpTextDocumentListeners.open.push(callback);
            \\      globalThis._wizp_onDidOpenTextDocument = callback;
            \\      return { dispose: function() {
            \\        const listeners = globalThis._wizpTextDocumentListeners.open;
            \\        const idx = listeners.indexOf(callback);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\        if (globalThis._wizp_onDidOpenTextDocument === callback) globalThis._wizp_onDidOpenTextDocument = null;
            \\      } };
            \\    },
            \\    onDidChangeTextDocument: function(callback, thisArg) {
            \\      const wrapped = function(event) { return callback.call(thisArg, event); };
            \\      wrapped._wizpOriginal = callback;
            \\      globalThis._wizpTextDocumentListeners.change.push(wrapped);
            \\      globalThis._wizp_onDidChangeTextDocument = wrapped;
            \\      return { dispose: function() {
            \\        const listeners = globalThis._wizpTextDocumentListeners.change;
            \\        const idx = listeners.indexOf(wrapped);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\        if (globalThis._wizp_onDidChangeTextDocument === wrapped) globalThis._wizp_onDidChangeTextDocument = null;
            \\      } };
            \\    },
            \\    onWillSaveTextDocument: function(callback) {
            \\      globalThis._wizpContext.workspace._willSaveTextDocumentListeners.push(callback);
            \\      return { dispose: function() {
            \\        const listeners = globalThis._wizpContext.workspace._willSaveTextDocumentListeners;
            \\        const idx = listeners.indexOf(callback);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\      } };
            \\    },
            \\    onDidSaveTextDocument: function(callback) {
            \\      globalThis._wizpTextDocumentListeners.save.push(callback);
            \\      globalThis._wizp_onDidSaveTextDocument = callback;
            \\      return { dispose: function() {
            \\        const listeners = globalThis._wizpTextDocumentListeners.save;
            \\        const idx = listeners.indexOf(callback);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\        if (globalThis._wizp_onDidSaveTextDocument === callback) globalThis._wizp_onDidSaveTextDocument = null;
            \\      } };
            \\    },
            \\    onDidCloseTextDocument: function(callback) {
            \\      globalThis._wizpTextDocumentListeners.close.push(callback);
            \\      globalThis._wizp_onDidCloseTextDocument = callback;
            \\      return { dispose: function() {
            \\        const listeners = globalThis._wizpTextDocumentListeners.close;
            \\        const idx = listeners.indexOf(callback);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\        if (globalThis._wizp_onDidCloseTextDocument === callback) globalThis._wizp_onDidCloseTextDocument = null;
            \\      } };
            \\    },
            \\  },
            \\  // window API
            \\  window: {
            \\    activeColorTheme: { kind: 2, name: 'WIZP Dark' },
            \\    state: { focused: true },
            \\    onDidChangeActiveColorTheme: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeWindowState: function(callback, thisArg, disposables) {
            \\      const disposable = { dispose: function() {} };
            \\      if (Array.isArray(disposables)) disposables.push(disposable);
            \\      return disposable;
            \\    },
            \\    _pickMessageItem: function(items) {
            \\      const mode = String(globalThis._wizpMessageSelectionMode || (globalThis._wizpNodeProcess && globalThis._wizpNodeProcess.env && globalThis._wizpNodeProcess.env.WIZP_EXTENSION_MESSAGE_SELECTION) || '').toLowerCase();
            \\      if (mode !== 'first') return undefined;
            \\      if (!items || items.length === 0) return undefined;
            \\      const item = items[0];
            \\      return typeof item === 'string' ? item : item;
            \\    },
            \\    _pickQuickPickItem: function(items) {
            \\      const mode = String(globalThis._wizpQuickPickSelectionMode || (globalThis._wizpNodeProcess && globalThis._wizpNodeProcess.env && globalThis._wizpNodeProcess.env.WIZP_EXTENSION_QUICK_PICK_SELECTION) || '').toLowerCase();
            \\      if (mode === 'none' || mode === 'cancel') return undefined;
            \\      const normalized = (items || []).map(function(item) { return typeof item === 'string' ? { label: item } : item; });
            \\      const separatorKind = globalThis._wizpContext && globalThis._wizpContext.QuickPickItemKind ? globalThis._wizpContext.QuickPickItemKind.Separator : undefined;
            \\      const visible = normalized.filter(function(item) {
            \\        return !(item && separatorKind !== undefined && item.kind === separatorKind);
            \\      });
            \\      const labelFor = function(item) { return String(item && (item.label || item.title || item.id || '') || ''); };
            \\      const descriptionFor = function(item) { return String(item && item.description || ''); };
            \\      const actionable = visible.filter(function(item) {
            \\        const label = labelFor(item).trim();
            \\        const lower = label.toLowerCase();
            \\        const description = descriptionFor(item).trim();
            \\        if (!label) return false;
            \\        if (description) return true;
            \\        if (lower === 'browse...' || lower === 'create virtual environment...' || lower === 'recommended' || lower === 'global' || lower === 'pyenv' || lower === 'pipenv' || lower === 'poetry' || lower === 'venv') return false;
            \\        if (lower.endsWith('...')) return false;
            \\        return true;
            \\      });
            \\      const preferred = actionable.find(function(item) {
            \\        const label = labelFor(item);
            \\        const description = descriptionFor(item);
            \\        return /python|interpreter|environment|env/i.test(label) || /[\\/]/.test(description);
            \\      });
            \\      const picked = preferred || actionable[0] || visible.find(function(item) { return labelFor(item).trim().length > 0; }) || visible[0];
            \\      try {
            \\        globalThis._wizpDebugLog(
            \\          'quickPick:auto-pick',
            \\          JSON.stringify(visible.map(function(item) {
            \\            return { label: labelFor(item), description: descriptionFor(item), kind: item && item.kind };
            \\          }).slice(0, 20)),
            \\          'picked=' + labelFor(picked)
            \\        );
            \\      } catch (_) {}
            \\      return picked;
            \\    },
            \\    showInformationMessage: function(message, ...items) {
            \\      globalThis._wizp_uiQueue.push({type: 'message', severity: 'info', message: message, items: items});
            \\      if (typeof WIZP_window_showMessage === 'function') WIZP_window_showMessage('info', message);
            \\      return Promise.resolve(globalThis._wizpContext.window._pickMessageItem(items));
            \\    },
            \\    showWarningMessage: function(message, ...items) {
            \\      globalThis._wizp_uiQueue.push({type: 'message', severity: 'warning', message: message, items: items});
            \\      if (typeof WIZP_window_showMessage === 'function') WIZP_window_showMessage('warning', message);
            \\      return Promise.resolve(globalThis._wizpContext.window._pickMessageItem(items));
            \\    },
            \\    showErrorMessage: function(message, ...items) {
            \\      globalThis._wizp_uiQueue.push({type: 'message', severity: 'error', message: message, items: items});
            \\      if (typeof WIZP_window_showMessage === 'function') WIZP_window_showMessage('error', message);
            \\      return Promise.resolve(globalThis._wizpContext.window._pickMessageItem(items));
            \\    },
            \\    showQuickPick: function(items, options) {
            \\      const normalized = (items || []).map(item => typeof item === 'string' ? { label: item } : item);
            \\      const id = ++globalThis._wizp_disposableId;
            \\      const picked = globalThis._wizpContext.window._pickQuickPickItem(normalized);
            \\      globalThis._wizp_uiQueue.push({
            \\        id: id,
            \\        type: 'quickPick',
            \\        items: normalized,
            \\        options: options || {},
            \\        pickedLabel: picked ? String(picked.label || picked.title || picked.id || '') : '',
            \\      });
            \\      return Promise.resolve(picked);
            \\    },
            \\    createQuickPick: function() {
            \\      const selectionListeners = [];
            \\      const activeListeners = [];
            \\      const acceptListeners = [];
            \\      const hideListeners = [];
            \\      const valueListeners = [];
            \\      const buttonListeners = [];
            \\      const itemButtonListeners = [];
            \\      const separatorButtonListeners = [];
            \\      const qp = {
            \\        title: undefined,
            \\        placeholder: undefined,
            \\        step: undefined,
            \\        totalSteps: undefined,
            \\        items: [],
            \\        buttons: [],
            \\        activeItems: [],
            \\        selectedItems: [],
            \\        canSelectMany: false,
            \\        matchOnDescription: false,
            \\        matchOnDetail: false,
            \\        ignoreFocusOut: false,
            \\        enabled: true,
            \\        busy: false,
            \\        value: '',
            \\        onDidChangeSelection: function(listener) {
            \\          selectionListeners.push(listener);
            \\          return { dispose: function() { const index = selectionListeners.indexOf(listener); if (index >= 0) selectionListeners.splice(index, 1); } };
            \\        },
            \\        onDidChangeActive: function(listener) {
            \\          activeListeners.push(listener);
            \\          return { dispose: function() { const index = activeListeners.indexOf(listener); if (index >= 0) activeListeners.splice(index, 1); } };
            \\        },
            \\        onDidAccept: function(listener) {
            \\          acceptListeners.push(listener);
            \\          return { dispose: function() { const index = acceptListeners.indexOf(listener); if (index >= 0) acceptListeners.splice(index, 1); } };
            \\        },
            \\        onDidHide: function(listener) {
            \\          hideListeners.push(listener);
            \\          return { dispose: function() { const index = hideListeners.indexOf(listener); if (index >= 0) hideListeners.splice(index, 1); } };
            \\        },
            \\        onDidChangeValue: function(listener) {
            \\          valueListeners.push(listener);
            \\          return { dispose: function() { const index = valueListeners.indexOf(listener); if (index >= 0) valueListeners.splice(index, 1); } };
            \\        },
            \\        onDidTriggerButton: function(listener) {
            \\          buttonListeners.push(listener);
            \\          return { dispose: function() { const index = buttonListeners.indexOf(listener); if (index >= 0) buttonListeners.splice(index, 1); } };
            \\        },
            \\        onDidTriggerItemButton: function(listener) {
            \\          itemButtonListeners.push(listener);
            \\          return { dispose: function() { const index = itemButtonListeners.indexOf(listener); if (index >= 0) itemButtonListeners.splice(index, 1); } };
            \\        },
            \\        onDidTriggerSeparatorButton: function(listener) {
            \\          separatorButtonListeners.push(listener);
            \\          return { dispose: function() { const index = separatorButtonListeners.indexOf(listener); if (index >= 0) separatorButtonListeners.splice(index, 1); } };
            \\        },
            \\        show: function() {
            \\          const id = ++globalThis._wizp_disposableId;
            \\          const normalized = (qp.items || []).map(item => typeof item === 'string' ? { label: item } : item);
            \\          const picked = globalThis._wizpContext.window._pickQuickPickItem(normalized);
            \\          globalThis._wizp_uiQueue.push({
            \\            id: id,
            \\            type: 'quickPick',
            \\            items: normalized,
            \\            options: {
            \\              title: qp.title,
            \\              placeHolder: qp.placeholder,
            \\              step: qp.step,
            \\              totalSteps: qp.totalSteps,
            \\              canPickMany: qp.canSelectMany,
            \\              matchOnDescription: qp.matchOnDescription,
            \\              matchOnDetail: qp.matchOnDetail,
            \\              ignoreFocusOut: qp.ignoreFocusOut,
            \\            },
            \\            pickedLabel: picked ? String(picked.label || picked.title || picked.id || '') : '',
            \\          });
            \\          qp.activeItems = picked ? [picked] : [];
            \\          qp.selectedItems = picked ? [picked] : [];
            \\          if (picked) {
            \\            for (const listener of activeListeners.slice()) listener(qp.activeItems);
            \\            for (const listener of selectionListeners.slice()) listener(qp.selectedItems);
            \\          }
            \\          if (picked) {
            \\            setTimeout(function() {
            \\              for (const listener of acceptListeners.slice()) listener();
            \\            }, 0);
            \\          }
            \\        },
            \\        hide: function() {
            \\          for (const listener of hideListeners.slice()) listener();
            \\        },
            \\        dispose: function() {
            \\          qp.hide();
            \\        },
            \\      };
            \\      return qp;
            \\    },
            \\    showInputBox: function(options) {
            \\      const id = ++globalThis._wizp_disposableId;
            \\      const opts = options || {};
            \\      globalThis._wizp_uiQueue.push({id: id, type: 'inputBox', options: opts});
            \\      return Promise.resolve(opts.value || '');
            \\    },
            \\    showOpenDialog: function(options) {
            \\      const id = ++globalThis._wizp_disposableId;
            \\      globalThis._wizp_uiQueue.push({id: id, type: 'openDialog', options: options || {}});
            \\      return Promise.resolve(undefined);
            \\    },
            \\    showSaveDialog: function(options) {
            \\      const id = ++globalThis._wizp_disposableId;
            \\      globalThis._wizp_uiQueue.push({id: id, type: 'saveDialog', options: options || {}});
            \\      return Promise.resolve(undefined);
            \\    },
            \\    withProgress: async function(options, task) {
            \\      const id = ++globalThis._wizp_disposableId;
            \\      const title = options && options.title;
            \\      globalThis._wizp_uiQueue.push({id: id, type: 'progressStart', title: title});
            \\      const progress = { report: function(value) { globalThis._wizp_uiQueue.push({id: id, type: 'progressReport', title: title, message: value && value.message, increment: value && value.increment}); } };
            \\      try {
            \\        return await Promise.resolve(task(progress, { isCancellationRequested: false, onCancellationRequested: function() { return { dispose: function() {} }; } }));
            \\      } finally {
            \\        globalThis._wizp_uiQueue.push({id: id, type: 'progressEnd', title: title});
            \\      }
            \\    },
            \\    createStatusBarItem: function(alignment, priority) {
            \\      const id = "status_" + (++globalThis._wizp_disposableId);
            \\      const item = { id: id, text: '', tooltip: '', command: undefined, alignment: alignment, priority: priority,
            \\        show: function() { globalThis._wizp_uiQueue.push({type: 'statusBar', id: id, action: 'show', item: { text: item.text, tooltip: item.tooltip, command: item.command, alignment: item.alignment, priority: item.priority }}); },
            \\        hide: function() { globalThis._wizp_uiQueue.push({type: 'statusBar', id: id, action: 'hide'}); },
            \\        dispose: function() { globalThis._wizp_uiQueue.push({type: 'statusBar', id: id, action: 'hide'}); }
            \\      };
            \\      return item;
            \\    },
            \\    createTerminal: function(nameOrOptions, shellPath, shellArgs) {
            \\      const options = typeof nameOrOptions === 'object' && nameOrOptions !== null ? nameOrOptions : { name: nameOrOptions, shellPath: shellPath, shellArgs: shellArgs };
            \\      const id = "terminal_" + (++globalThis._wizp_disposableId);
            \\      const inferShellEnv = function(text) {
            \\        const value = String(text || '').trim();
            \\        if (!value) return null;
            \\        const activationMatch = value.match(/(?:^|\s)(?:source|\.)\s+(['"]?)([^'"\s]+)\1/);
            \\        if (activationMatch && activationMatch[2]) {
            \\          const activationPath = String(activationMatch[2]);
            \\          if (/\/bin\/activate(?:\.[^\/\s]+)?$/i.test(activationPath)) {
            \\            return { VIRTUAL_ENV: activationPath.replace(/\/bin\/activate(?:\.[^\/\s]+)?$/i, '') };
            \\          }
            \\          if (/\\Scripts\\activate(?:\.[^\\\s]+)?$/i.test(activationPath)) {
            \\            return { VIRTUAL_ENV: activationPath.replace(/\\Scripts\\activate(?:\.[^\\\s]+)?$/i, '') };
            \\          }
            \\        }
            \\        const condaMatch = value.match(/(?:^|\s)conda\s+activate\s+(['"]?)([^'"\s]+)\1/i);
            \\        if (condaMatch && condaMatch[2]) return { CONDA_PREFIX: String(condaMatch[2]) };
            \\        return null;
            \\      };
            \\      const terminal = {
            \\        id: id,
            \\        name: options.name || 'Terminal',
            \\        creationOptions: options,
            \\        processId: Promise.resolve(10000 + globalThis._wizp_disposableId),
            \\        exitStatus: undefined,
            \\        state: {
            \\          isInteractedWith: false,
            \\          shell: options.shellPath || (globalThis._wizpProcessEnv && globalThis._wizpProcessEnv.SHELL) || '/bin/bash',
            \\        },
            \\        _sentText: [],
            \\        _shown: false,
            \\        _disposed: false,
            \\        _shellIntegrationReady: false,
            \\        shellIntegration: {
            \\          env: { value: {} },
            \\          executeCommand: function(commandLine, args) {
            \\            const execution = {
            \\              commandLine: String(commandLine || ''),
            \\              args: Array.isArray(args) ? args.slice() : [],
            \\            };
            \\            if (terminal._disposed) return execution;
            \\            const rendered = [execution.commandLine].concat(execution.args).filter(function(item) {
            \\              return String(item || '').length > 0;
            \\            }).join(' ');
            \\            terminal.state.isInteractedWith = true;
            \\            terminal._sentText.push(rendered + '\n');
            \\            globalThis._wizp_uiQueue.push({type: 'terminal', action: 'sendText', id: id, name: terminal.name, text: rendered + '\n'});
            \\            setTimeout(function() {
            \\              for (const callback of globalThis._wizpTerminalShellExecutionListeners.start.slice()) {
            \\                try { callback({ terminal: terminal, shellIntegration: terminal.shellIntegration, execution: execution }); } catch (_) {}
            \\              }
            \\              setTimeout(function() {
            \\                const envUpdate = inferShellEnv(rendered);
            \\                if (envUpdate) {
            \\                  const currentEnv = terminal.shellIntegration && terminal.shellIntegration.env && terminal.shellIntegration.env.value && typeof terminal.shellIntegration.env.value === 'object'
            \\                    ? terminal.shellIntegration.env.value
            \\                    : {};
            \\                  terminal.shellIntegration.env = { value: Object.assign({}, currentEnv, envUpdate) };
            \\                  globalThis._wizpEmitTerminalShellIntegrationChange(terminal);
            \\                }
            \\                globalThis._wizpEmitTerminalData(terminal, '$ ');
            \\                for (const callback of globalThis._wizpTerminalShellExecutionListeners.end.slice()) {
            \\                  try { callback({ terminal: terminal, shellIntegration: terminal.shellIntegration, execution: execution, exitCode: 0 }); } catch (_) {}
            \\                }
            \\              }, 0);
            \\            }, 0);
            \\            return execution;
            \\          },
            \\        },
            \\        sendText: function(text, addNewLine) {
            \\          if (terminal._disposed) return;
            \\          const value = String(text || '') + (addNewLine === false ? '' : '\n');
            \\          terminal.state.isInteractedWith = true;
            \\          terminal._sentText.push(value);
            \\          globalThis._wizp_uiQueue.push({type: 'terminal', action: 'sendText', id: id, name: terminal.name, text: value});
            \\          const envUpdate = inferShellEnv(value);
            \\          if (envUpdate) {
            \\            const currentEnv = terminal.shellIntegration && terminal.shellIntegration.env && terminal.shellIntegration.env.value && typeof terminal.shellIntegration.env.value === 'object'
            \\              ? terminal.shellIntegration.env.value
            \\              : {};
            \\            terminal.shellIntegration.env = { value: Object.assign({}, currentEnv, envUpdate) };
            \\            globalThis._wizpEmitTerminalShellIntegrationChange(terminal);
            \\          }
            \\          globalThis._wizpEmitTerminalData(terminal, '$ ');
            \\        },
            \\        show: function(preserveFocus) {
            \\          if (terminal._disposed) return;
            \\          terminal._shown = true;
            \\          globalThis._wizpActiveTerminal = terminal;
            \\          globalThis._wizp_uiQueue.push({type: 'terminal', action: 'show', id: id, name: terminal.name, preserveFocus: !!preserveFocus});
            \\          if (!terminal._shellIntegrationReady) {
            \\            terminal._shellIntegrationReady = true;
            \\            setTimeout(function() {
            \\              globalThis._wizpEmitTerminalShellIntegrationChange(terminal);
            \\              globalThis._wizpEmitTerminalData(terminal, '$ ');
            \\            }, 0);
            \\          }
            \\          for (const callback of globalThis._wizpTerminalListeners.active.slice()) callback(terminal);
            \\        },
            \\        hide: function() {
            \\          if (terminal._disposed) return;
            \\          terminal._shown = false;
            \\          globalThis._wizp_uiQueue.push({type: 'terminal', action: 'hide', id: id, name: terminal.name});
            \\        },
            \\        dispose: function() {
            \\          if (terminal._disposed) return;
            \\          terminal._disposed = true;
            \\          terminal.exitStatus = { code: 0, reason: 3 };
            \\          globalThis._wizpTerminals = globalThis._wizpTerminals.filter(t => t !== terminal);
            \\          if (globalThis._wizpActiveTerminal === terminal) globalThis._wizpActiveTerminal = globalThis._wizpTerminals[0] || null;
            \\          globalThis._wizp_uiQueue.push({type: 'terminal', action: 'dispose', id: id, name: terminal.name});
            \\          for (const callback of globalThis._wizpTerminalListeners.close.slice()) callback(terminal);
            \\          for (const callback of globalThis._wizpTerminalListeners.active.slice()) callback(globalThis._wizpActiveTerminal);
            \\        }
            \\      };
            \\      globalThis._wizpTerminals.push(terminal);
            \\      globalThis._wizpActiveTerminal = terminal;
            \\      globalThis._wizp_uiQueue.push({type: 'terminal', action: 'create', id: id, name: terminal.name, options: options});
            \\      for (const callback of globalThis._wizpTerminalListeners.open.slice()) callback(terminal);
            \\      for (const callback of globalThis._wizpTerminalListeners.active.slice()) callback(terminal);
            \\      return terminal;
            \\    },
            \\    get terminals() { return globalThis._wizpTerminals.slice(); },
            \\    get activeTerminal() { return globalThis._wizpActiveTerminal; },
            \\    registerTerminalProfileProvider: function(id, provider) {
            \\      globalThis._wizpTerminalProfileProviders = globalThis._wizpTerminalProfileProviders || {};
            \\      globalThis._wizpTerminalProfileProviders[id] = provider;
            \\      globalThis._wizp_uiQueue.push({type: 'terminalProfileRegistered', id: id});
            \\      return { dispose: function() { delete globalThis._wizpTerminalProfileProviders[id]; } };
            \\    },
            \\    onDidOpenTerminal: function(callback) {
            \\      globalThis._wizpTerminalListeners.open.push(callback);
            \\      return { dispose: function() {
            \\        const listeners = globalThis._wizpTerminalListeners.open;
            \\        const idx = listeners.indexOf(callback);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\      } };
            \\    },
            \\    onDidCloseTerminal: function(callback) {
            \\      globalThis._wizpTerminalListeners.close.push(callback);
            \\      return { dispose: function() {
            \\        const listeners = globalThis._wizpTerminalListeners.close;
            \\        const idx = listeners.indexOf(callback);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\      } };
            \\    },
            \\    onDidChangeActiveTerminal: function(callback) {
            \\      globalThis._wizpTerminalListeners.active.push(callback);
            \\      return { dispose: function() {
            \\        const listeners = globalThis._wizpTerminalListeners.active;
            \\        const idx = listeners.indexOf(callback);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\      } };
            \\    },
            \\    onDidWriteTerminalData: function(callback, thisArg, disposables) {
            \\      const wrapped = function(event) { return callback.call(thisArg, event); };
            \\      globalThis._wizpTerminalDataListeners.push(wrapped);
            \\      const disposable = { dispose: function() {
            \\        const listeners = globalThis._wizpTerminalDataListeners;
            \\        const idx = listeners.indexOf(wrapped);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\      } };
            \\      if (Array.isArray(disposables)) disposables.push(disposable);
            \\      return disposable;
            \\    },
            \\    onDidStartTerminalShellExecution: function(callback, thisArg, disposables) {
            \\      const wrapped = function(event) { return callback.call(thisArg, event); };
            \\      globalThis._wizpTerminalShellExecutionListeners.start.push(wrapped);
            \\      const disposable = { dispose: function() {
            \\        const listeners = globalThis._wizpTerminalShellExecutionListeners.start;
            \\        const idx = listeners.indexOf(wrapped);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\      } };
            \\      if (Array.isArray(disposables)) disposables.push(disposable);
            \\      return disposable;
            \\    },
            \\    onDidEndTerminalShellExecution: function(callback, thisArg, disposables) {
            \\      const wrapped = function(event) { return callback.call(thisArg, event); };
            \\      globalThis._wizpTerminalShellExecutionListeners.end.push(wrapped);
            \\      const disposable = { dispose: function() {
            \\        const listeners = globalThis._wizpTerminalShellExecutionListeners.end;
            \\        const idx = listeners.indexOf(wrapped);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\      } };
            \\      if (Array.isArray(disposables)) disposables.push(disposable);
            \\      return disposable;
            \\    },
            \\    onDidChangeTerminalShellIntegration: function(callback, thisArg, disposables) {
            \\      const wrapped = function(event) { return callback.call(thisArg, event); };
            \\      globalThis._wizpTerminalShellIntegrationListeners.push(wrapped);
            \\      const disposable = { dispose: function() {
            \\        const listeners = globalThis._wizpTerminalShellIntegrationListeners;
            \\        const idx = listeners.indexOf(wrapped);
            \\        if (idx >= 0) listeners.splice(idx, 1);
            \\      } };
            \\      if (Array.isArray(disposables)) disposables.push(disposable);
            \\      return disposable;
            \\    },
            \\    createOutputChannel: function(name, languageIdOrOptions) {
            \\      globalThis._wizpOutputChannels = globalThis._wizpOutputChannels || {};
            \\      const id = "output_" + (++globalThis._wizp_disposableId);
            \\      const isLog = !!(languageIdOrOptions && typeof languageIdOrOptions === 'object' && languageIdOrOptions.log);
            \\      const logLevelListeners = [];
            \\      let logLevel = globalThis._wizpContext.LogLevel.Info;
            \\      const formatOutputArgs = function(argsLike) {
            \\        const values = Array.prototype.slice.call(argsLike || []);
            \\        if (!values.length) return '';
            \\        if (values.length === 1) {
            \\          const only = values[0];
            \\          return only === undefined || only === null ? '' : String(only);
            \\        }
            \\        const util = globalThis._wizpNodeUtil || {};
            \\        if (typeof util.format === 'function') {
            \\          try { return util.format.apply(util, values); } catch (_) {}
            \\        }
            \\        return values.map(function(value) { return value === undefined || value === null ? '' : String(value); }).join(' ');
            \\      };
            \\      const channel = {
            \\        id: id,
            \\        name: name,
            \\        isLog: isLog,
            \\        lines: [],
            \\        disposed: false,
            \\        _shouldLogLevel: function(level) {
            \\          if (!isLog || !level) return true;
            \\          const levelValue = globalThis._wizpContext.LogLevel[String(level).charAt(0).toUpperCase() + String(level).slice(1)] || globalThis._wizpContext.LogLevel.Info;
            \\          return levelValue >= logLevel && logLevel !== globalThis._wizpContext.LogLevel.Off;
            \\        },
            \\        _append: function(value, newline, level) {
            \\          if (channel.disposed) return;
            \\          const text = value === undefined || value === null ? '' : String(value);
            \\          globalThis._wizp_uiQueue.push({type: 'outputTrace', id: id, channel: name, action: newline ? 'appendLine' : 'append', text: text, level: level || null});
            \\          if (!channel._shouldLogLevel(level)) return;
            \\          channel.lines.push({ text: text, newline: newline, level: level || null });
            \\          globalThis._wizp_uiQueue.push({type: 'output', id: id, channel: name, action: newline ? 'appendLine' : 'append', text: text, level: level || null});
            \\          if (typeof WIZP_output_append === 'function') WIZP_output_append(name, newline ? text + '\n' : text);
            \\        },
            \\        append: function() { channel._append(formatOutputArgs(arguments), false); },
            \\        appendLine: function() { channel._append(formatOutputArgs(arguments), true); },
            \\        replace: function() {
            \\          if (channel.disposed) return;
            \\          const text = formatOutputArgs(arguments);
            \\          channel.lines = [{ text: text, newline: false, level: null }];
            \\          globalThis._wizp_uiQueue.push({type: 'outputTrace', id: id, channel: name, action: 'replace', text: text, level: null});
            \\          globalThis._wizp_uiQueue.push({type: 'output', id: id, channel: name, action: 'replace', text: text});
            \\        },
            \\        clear: function() {
            \\          if (channel.disposed) return;
            \\          channel.lines = [];
            \\          globalThis._wizp_uiQueue.push({type: 'outputTrace', id: id, channel: name, action: 'clear', text: '', level: null});
            \\          globalThis._wizp_uiQueue.push({type: 'output', id: id, channel: name, action: 'clear'});
            \\        },
            \\        show: function(columnOrPreserveFocus, preserveFocus) {
            \\          if (channel.disposed) return;
            \\          globalThis._wizp_uiQueue.push({type: 'outputTrace', id: id, channel: name, action: 'show', text: '', level: null});
            \\          globalThis._wizp_uiQueue.push({type: 'output', id: id, channel: name, action: 'show', preserveFocus: !!(preserveFocus || columnOrPreserveFocus === true)});
            \\        },
            \\        hide: function() {
            \\          if (channel.disposed) return;
            \\          globalThis._wizp_uiQueue.push({type: 'outputTrace', id: id, channel: name, action: 'hide', text: '', level: null});
            \\          globalThis._wizp_uiQueue.push({type: 'output', id: id, channel: name, action: 'hide'});
            \\        },
            \\        dispose: function() {
            \\          if (channel.disposed) return;
            \\          channel.disposed = true;
            \\          delete globalThis._wizpOutputChannels[id];
            \\          globalThis._wizp_uiQueue.push({type: 'outputTrace', id: id, channel: name, action: 'dispose', text: '', level: null});
            \\          globalThis._wizp_uiQueue.push({type: 'output', id: id, channel: name, action: 'dispose'});
            \\        }
            \\      };
            \\      channel.trace = function() { channel._append(formatOutputArgs(arguments), true, 'trace'); };
            \\      channel.debug = function() { channel._append(formatOutputArgs(arguments), true, 'debug'); };
            \\      channel.info = function() { channel._append(formatOutputArgs(arguments), true, 'info'); };
            \\      channel.warn = function() { channel._append(formatOutputArgs(arguments), true, 'warn'); };
            \\      channel.error = function() { channel._append(formatOutputArgs(arguments), true, 'error'); };
            \\      Object.defineProperty(channel, 'logLevel', {
            \\        get: function() { return logLevel; },
            \\        set: function(value) {
            \\          if (typeof value !== 'number') return;
            \\          logLevel = value;
            \\          for (const listener of logLevelListeners.slice()) listener(logLevel);
            \\        }
            \\      });
            \\      channel.onDidChangeLogLevel = function(listener) {
            \\        if (typeof listener !== 'function') return { dispose: function() {} };
            \\        logLevelListeners.push(listener);
            \\        return { dispose: function() {
            \\          const idx = logLevelListeners.indexOf(listener);
            \\          if (idx >= 0) logLevelListeners.splice(idx, 1);
            \\        } };
            \\      };
            \\      globalThis._wizpOutputChannels[id] = channel;
            \\      return channel;
            \\    },
            \\    createWebviewPanel: function(viewType, title, showOptions, options) {
            \\      globalThis._wizp_webviewPanels = globalThis._wizp_webviewPanels || {};
            \\      globalThis._wizp_webviewMessageListeners = globalThis._wizp_webviewMessageListeners || {};
            \\      if (!globalThis._wizp_receiveWebviewMessage) {
            \\        globalThis._wizp_receiveWebviewMessage = function(id, message) {
            \\          const listeners = globalThis._wizp_webviewMessageListeners && globalThis._wizp_webviewMessageListeners[id];
            \\          if (!Array.isArray(listeners)) return false;
            \\          for (const listener of listeners.slice()) {
            \\            try { listener(message); } catch (_) {}
            \\          }
            \\          return listeners.length > 0;
            \\        };
            \\      }
            \\      const id = "webviewPanel_" + (++globalThis._wizp_disposableId);
            \\      const disposeListeners = [];
            \\      let webviewHtml = '';
            \\      let panel = null;
            \\      globalThis._wizp_webviewMessageListeners[id] = globalThis._wizp_webviewMessageListeners[id] || [];
            \\      const syncPanelState = function() {
            \\        if (!globalThis._wizpPostExtensionRpc) return;
            \\        globalThis._wizpPostExtensionRpc('webview/create', {
            \\          id: id,
            \\          title: panel && typeof panel.title === 'string' ? panel.title : String(title || viewType || id),
            \\          html: webviewHtml,
            \\          viewType: String(viewType || ''),
            \\          options: options || {}
            \\        }).catch(function() {});
            \\      };
            \\      const emitPanelUpdate = function() {
            \\        globalThis._wizp_uiQueue.push({
            \\          type: 'webviewPanelUpdated',
            \\          id: id,
            \\          viewType: viewType,
            \\          title: panel && typeof panel.title === 'string' ? panel.title : String(title || viewType || id),
            \\          html: webviewHtml,
            \\          options: options || {}
            \\        });
            \\        syncPanelState();
            \\      };
            \\      const webview = {
            \\        options: options || {},
            \\        cspSource: globalThis._wizpWebviewCspSource || ('vscode-webview://' + id),
            \\        asWebviewUri: function(uri) { return globalThis._wizpAsWebviewUri ? globalThis._wizpAsWebviewUri(id, uri) : uri; },
            \\        postMessage: function(message) {
            \\          globalThis._wizp_uiQueue.push({type: 'webviewPostMessage', id: id, message: message});
            \\          return Promise.resolve(true);
            \\        },
            \\        onDidReceiveMessage: function(listener) {
            \\          const listeners = globalThis._wizp_webviewMessageListeners[id];
            \\          listeners.push(listener);
            \\          return { dispose: function() {
            \\            const idx = listeners.indexOf(listener);
            \\            if (idx >= 0) listeners.splice(idx, 1);
            \\          } };
            \\        }
            \\      };
            \\      Object.defineProperty(webview, 'html', {
            \\        get: function() { return webviewHtml; },
            \\        set: function(value) {
            \\          webviewHtml = value == null ? '' : String(value);
            \\          emitPanelUpdate();
            \\        }
            \\      });
            \\      panel = {
            \\        id: id,
            \\        viewType: viewType,
            \\        title: title,
            \\        options: options || {},
            \\        viewColumn: typeof showOptions === 'number' ? showOptions : (showOptions && showOptions.viewColumn) || 1,
            \\        active: true,
            \\        visible: true,
            \\        webview: webview,
            \\        reveal: function(column, preserveFocus) {
            \\          panel.viewColumn = column || panel.viewColumn;
            \\          panel.visible = true;
            \\          panel.active = !preserveFocus;
            \\          globalThis._wizp_uiQueue.push({type: 'webviewPanelReveal', id: id, viewColumn: panel.viewColumn, preserveFocus: !!preserveFocus});
            \\        },
            \\        onDidDispose: function(listener) {
            \\          disposeListeners.push(listener);
            \\          return { dispose: function() {
            \\            const idx = disposeListeners.indexOf(listener);
            \\            if (idx >= 0) disposeListeners.splice(idx, 1);
            \\          } };
            \\        },
            \\        dispose: function() {
            \\          delete globalThis._wizp_webviewPanels[id];
            \\          delete globalThis._wizp_webviewMessageListeners[id];
            \\          panel.visible = false;
            \\          panel.active = false;
            \\          for (const listener of disposeListeners.slice()) listener();
            \\          globalThis._wizp_uiQueue.push({type: 'webviewPanelDisposed', id: id});
            \\          if (globalThis._wizpPostExtensionRpc) {
            \\            globalThis._wizpPostExtensionRpc('webview/dispose', { id: id }).catch(function() {});
            \\          }
            \\        }
            \\      };
            \\      let panelTitle = title == null ? '' : String(title);
            \\      Object.defineProperty(panel, 'title', {
            \\        get: function() { return panelTitle; },
            \\        set: function(value) {
            \\          panelTitle = value == null ? '' : String(value);
            \\          emitPanelUpdate();
            \\        }
            \\      });
            \\      globalThis._wizp_webviewPanels[id] = panel;
            \\      globalThis._wizp_uiQueue.push({type: 'webviewPanelCreated', id: id, viewType: viewType, title: panelTitle, html: webviewHtml, options: options || {}});
            \\      syncPanelState();
            \\      return panel;
            \\    },
            \\    registerWebviewViewProvider: function(id, provider, options) {
            \\       globalThis._wizp_webviewProviders = globalThis._wizp_webviewProviders || {};
            \\       globalThis._wizp_webviewProviderOptions = globalThis._wizp_webviewProviderOptions || {};
            \\       globalThis._wizp_resolvedWebviewViews = globalThis._wizp_resolvedWebviewViews || {};
            \\       globalThis._wizp_webviewMessageListeners = globalThis._wizp_webviewMessageListeners || {};
            \\       if (!globalThis._wizp_receiveWebviewMessage) {
            \\         globalThis._wizp_receiveWebviewMessage = function(targetId, message) {
            \\           const listeners = globalThis._wizp_webviewMessageListeners && globalThis._wizp_webviewMessageListeners[targetId];
            \\           if (!Array.isArray(listeners)) return false;
            \\           for (const listener of listeners.slice()) {
            \\             try { listener(message); } catch (_) {}
            \\           }
            \\           return listeners.length > 0;
            \\         };
            \\       }
            \\       globalThis._wizp_webviewProviders[id] = provider;
            \\       globalThis._wizp_webviewProviderOptions[id] = options || {};
            \\       if (!globalThis._wizp_resolveWebviewView) {
            \\         globalThis._wizp_resolveWebviewView = function(viewId) {
            \\           const providerEntry = globalThis._wizp_webviewProviders && globalThis._wizp_webviewProviders[viewId];
            \\           const providerOptions = globalThis._wizp_webviewProviderOptions && globalThis._wizp_webviewProviderOptions[viewId];
            \\           if (!providerEntry || typeof providerEntry.resolveWebviewView !== 'function') return null;
            \\           const existingView = globalThis._wizp_resolvedWebviewViews && globalThis._wizp_resolvedWebviewViews[viewId];
            \\           if (existingView) {
            \\             existingView.visible = true;
            \\             const existingEvent = { visible: true, webviewView: existingView };
            \\             for (const listener of (existingView._visibilityListeners || []).slice()) {
            \\               try { listener(existingEvent); } catch (_) {}
            \\             }
            \\             globalThis._wizp_uiQueue.push({type: 'webviewViewFocus', id: viewId, preserveFocus: false});
            \\             return existingView;
            \\           }
            \\           const messageKey = 'webviewView:' + viewId;
            \\           globalThis._wizp_webviewMessageListeners[messageKey] = globalThis._wizp_webviewMessageListeners[messageKey] || [];
            \\           const visibilityListeners = [];
            \\           const disposeListeners = [];
            \\           const webview = {
            \\             html: '',
            \\             options: (providerOptions && providerOptions.webviewOptions) || {},
            \\             cspSource: globalThis._wizpWebviewCspSource || ('vscode-webview://webviewView:' + viewId),
            \\             asWebviewUri: function(uri) { return globalThis._wizpAsWebviewUri ? globalThis._wizpAsWebviewUri(messageKey, uri) : uri; },
            \\             postMessage: function(message) {
            \\               globalThis._wizp_uiQueue.push({type: 'webviewPostMessage', id: messageKey, message: message});
            \\               return Promise.resolve(true);
            \\             },
            \\             onDidReceiveMessage: function(listener) {
            \\               const listeners = globalThis._wizp_webviewMessageListeners[messageKey];
            \\               listeners.push(listener);
            \\               return { dispose: function() {
            \\                 const idx = listeners.indexOf(listener);
            \\                 if (idx >= 0) listeners.splice(idx, 1);
            \\               } };
            \\             }
            \\           };
            \\           const view = {
            \\             id: viewId,
            \\             viewType: viewId,
            \\             title: viewId,
            \\             description: undefined,
            \\             badge: undefined,
            \\             visible: true,
            \\             webview: webview,
            \\             show: function(preserveFocus) {
            \\               view.visible = true;
            \\               const event = { visible: true, webviewView: view };
            \\               for (const listener of visibilityListeners.slice()) listener(event);
            \\               globalThis._wizp_uiQueue.push({type: 'webviewViewFocus', id: viewId, preserveFocus: !!preserveFocus});
            \\             },
            \\             onDidChangeVisibility: function(listener, thisArg, disposables) {
            \\               const wrapped = thisArg ? listener.bind(thisArg) : listener;
            \\               visibilityListeners.push(wrapped);
            \\               const disposable = { dispose: function() {
            \\                 const idx = visibilityListeners.indexOf(wrapped);
            \\                 if (idx >= 0) visibilityListeners.splice(idx, 1);
            \\               } };
            \\               if (Array.isArray(disposables)) disposables.push(disposable);
            \\               return disposable;
            \\             },
            \\             onDidDispose: function(listener) {
            \\               disposeListeners.push(listener);
            \\               return { dispose: function() {
            \\                 const idx = disposeListeners.indexOf(listener);
            \\                 if (idx >= 0) disposeListeners.splice(idx, 1);
            \\               } };
            \\             },
            \\             dispose: function() {
            \\               view.visible = false;
            \\               delete globalThis._wizp_resolvedWebviewViews[viewId];
            \\               delete globalThis._wizp_webviewMessageListeners[messageKey];
            \\               for (const listener of disposeListeners.slice()) listener();
            \\               globalThis._wizp_uiQueue.push({type: 'webviewViewDisposed', id: viewId});
            \\             }
            \\           };
            \\           view._visibilityListeners = visibilityListeners;
            \\           globalThis._wizp_resolvedWebviewViews[viewId] = view;
            \\           try {
            \\             providerEntry.resolveWebviewView(view, {}, { isCancellationRequested: false, onCancellationRequested: function() { return { dispose: function() {} }; } });
            \\           } catch (_) {}
            \\           globalThis._wizp_uiQueue.push({type: 'webviewViewFocus', id: viewId, preserveFocus: false});
            \\           return view;
            \\         };
            \\       }
            \\       const focusCommand = id + '.focus';
            \\       if (!globalThis._wizpContext.commands._registry[focusCommand]) {
            \\         globalThis._wizpContext.commands._registry[focusCommand] = function() {
            \\           globalThis._wizp_resolveWebviewView(id);
            \\           return Promise.resolve(true);
            \\         };
            \\         globalThis._wizp_uiQueue.push({type: 'commandRegistered', command: focusCommand});
            \\       }
            \\       // Signal UI that a webview is ready
            \\       globalThis._wizp_uiQueue.push({type: "webviewRegistered", id: id});
            \\       return { dispose: function() {
            \\         const existingView = globalThis._wizp_resolvedWebviewViews && globalThis._wizp_resolvedWebviewViews[id];
            \\         if (existingView && typeof existingView.dispose === 'function') existingView.dispose();
            \\         delete globalThis._wizp_webviewProviders[id];
            \\         delete globalThis._wizp_webviewProviderOptions[id];
            \\       } };
            \\    },
            \\    registerWebviewPanelSerializer: function(viewType, serializer) {
            \\       globalThis._wizp_webviewPanelSerializers = globalThis._wizp_webviewPanelSerializers || {};
            \\       globalThis._wizp_webviewPanelSerializers[viewType] = serializer;
            \\       globalThis._wizp_uiQueue.push({type: "webviewPanelSerializerRegistered", viewType: viewType});
            \\       return { dispose: function() { delete globalThis._wizp_webviewPanelSerializers[viewType]; } };
            \\    },
            \\    registerCustomEditorProvider: function(viewType, provider, options) {
            \\       globalThis._wizp_customEditors = globalThis._wizp_customEditors || {};
            \\       globalThis._wizp_customEditors[viewType] = provider;
            \\       return { dispose: function() { delete globalThis._wizp_customEditors[viewType]; } };
            \\    },
            \\    registerUriHandler: function(handler) {
            \\       globalThis._wizpUriHandlers = globalThis._wizpUriHandlers || [];
            \\       globalThis._wizpUriHandlers.push(handler);
            \\       globalThis._wizp_uiQueue.push({type: "uriHandlerRegistered"});
            \\       return { dispose: function() { const index = globalThis._wizpUriHandlers.indexOf(handler); if (index >= 0) globalThis._wizpUriHandlers.splice(index, 1); } };
            \\    },
            \\    createTreeView: function(id, options) {
            \\       globalThis._wizp_treeViews = globalThis._wizp_treeViews || {};
            \\       const tvId = "tree_" + (++globalThis._wizp_disposableId);
            \\       const visibilityListeners = [];
            \\       const selectionListeners = [];
            \\       const checkboxListeners = [];
            \\       const collapseListeners = [];
            \\       const expandListeners = [];
            \\       const tv = {
            \\         id: tvId,
            \\         title: options && options.title,
            \\         description: undefined,
            \\         message: undefined,
            \\         badge: undefined,
            \\         visible: true,
            \\         selection: [],
            \\         onDidChangeVisibility: function(listener, thisArg, disposables) {
            \\           const wrapped = thisArg ? listener.bind(thisArg) : listener;
            \\           visibilityListeners.push(wrapped);
            \\           const disposable = { dispose: function() { const index = visibilityListeners.indexOf(wrapped); if (index >= 0) visibilityListeners.splice(index, 1); } };
            \\           if (Array.isArray(disposables)) disposables.push(disposable);
            \\           return disposable;
            \\         },
            \\         onDidChangeSelection: function(listener) {
            \\           selectionListeners.push(listener);
            \\           return { dispose: function() { const index = selectionListeners.indexOf(listener); if (index >= 0) selectionListeners.splice(index, 1); } };
            \\         },
            \\         onDidChangeCheckboxState: function(listener) {
            \\           checkboxListeners.push(listener);
            \\           return { dispose: function() { const index = checkboxListeners.indexOf(listener); if (index >= 0) checkboxListeners.splice(index, 1); } };
            \\         },
            \\         onDidCollapseElement: function(listener) {
            \\           collapseListeners.push(listener);
            \\           return { dispose: function() { const index = collapseListeners.indexOf(listener); if (index >= 0) collapseListeners.splice(index, 1); } };
            \\         },
            \\         onDidExpandElement: function(listener) {
            \\           expandListeners.push(listener);
            \\           return { dispose: function() { const index = expandListeners.indexOf(listener); if (index >= 0) expandListeners.splice(index, 1); } };
            \\         },
            \\         reveal: function(element, options) {
            \\           tv.selection = element === undefined ? [] : [element];
            \\           for (const listener of selectionListeners.slice()) listener({ selection: tv.selection });
            \\           return Promise.resolve();
            \\         },
            \\         _fireCheckboxState: function(items) {
            \\           const event = { items: Array.isArray(items) ? items : [] };
            \\           for (const listener of checkboxListeners.slice()) listener(event);
            \\         },
            \\         _fireCollapseElement: function(element) {
            \\           const event = { element: element };
            \\           for (const listener of collapseListeners.slice()) listener(event);
            \\         },
            \\         _fireExpandElement: function(element) {
            \\           const event = { element: element };
            \\           for (const listener of expandListeners.slice()) listener(event);
            \\         },
            \\         dispose: function() {}
            \\       };
            \\       globalThis._wizp_treeViews[id] = tv;
            \\       const focusCommand = id + '.focus';
            \\       if (!globalThis._wizpContext.commands._registry[focusCommand]) {
            \\         globalThis._wizpContext.commands._registry[focusCommand] = function() {
            \\           tv.visible = true;
            \\           for (const listener of visibilityListeners.slice()) listener({ visible: true });
            \\           globalThis._wizp_uiQueue.push({type: "treeViewFocus", id: id, treeId: tvId});
            \\           return Promise.resolve(true);
            \\         };
            \\         globalThis._wizp_uiQueue.push({type: 'commandRegistered', command: focusCommand});
            \\       }
            \\       globalThis._wizp_uiQueue.push({type: "treeViewCreated", id: id, treeId: tvId});
            \\       return tv;
            \\    },
            \\    registerTreeDataProvider: function(id, provider) {
            \\       globalThis._wizp_treeDataProviders = globalThis._wizp_treeDataProviders || {};
            \\       globalThis._wizp_treeDataProviders[id] = provider;
            \\       globalThis._wizp_uiQueue.push({type: "treeDataProviderRegistered", id: id});
            \\       return { dispose: function() { delete globalThis._wizp_treeDataProviders[id]; } };
            \\    },
            \\    registerFileDecorationProvider: function(provider) {
            \\       const id = "fileDecoration_" + (++globalThis._wizp_disposableId);
            \\       const entry = { id: id, provider: provider };
            \\       globalThis._wizpFileDecorationProviders.push(entry);
            \\       globalThis._wizp_uiQueue.push({type: "fileDecorationProviderRegistered", id: id});
            \\       return { dispose: function() {
            \\         globalThis._wizpFileDecorationProviders = globalThis._wizpFileDecorationProviders.filter(function(item) { return item.id !== id; });
            \\       } };
            \\    },
            \\    _makeTextEditor: function(document, column) {
            \\      const editor = {
            \\        document: document,
            \\        viewColumn: column || 1,
            \\        selections: [new globalThis._wizpContext.Selection(new globalThis._wizpContext.Position(0, 0), new globalThis._wizpContext.Position(0, 0))],
            \\        selection: new globalThis._wizpContext.Selection(new globalThis._wizpContext.Position(0, 0), new globalThis._wizpContext.Position(0, 0)),
            \\        visibleRanges: [],
            \\        options: { tabSize: 4, insertSpaces: true },
            \\        setDecorations: function(decorationType, rangesOrOptions) {
            \\          const typeId = decorationType && (decorationType.id || decorationType.key);
            \\          if (!typeId) return;
            \\          const uri = editor.document && editor.document.uri && editor.document.uri.toString ? editor.document.uri.toString() : 'file://active.txt';
            \\          const ranges = (rangesOrOptions || []).map(function(item) {
            \\            const range = item && item.range ? item.range : item;
            \\            return {
            \\              start: { line: range.start.line, character: range.start.character },
            \\              end: { line: range.end.line, character: range.end.character },
            \\              hoverMessage: item && item.hoverMessage ? item.hoverMessage : undefined
            \\            };
            \\          });
            \\          globalThis._wizpEditorDecorations[uri] = globalThis._wizpEditorDecorations[uri] || {};
            \\          globalThis._wizpEditorDecorations[uri][typeId] = ranges;
            \\          globalThis._wizp_uiQueue.push({type: 'decorations', action: 'set', uri: uri, typeId: typeId, ranges: ranges});
            \\        },
            \\        revealRange: function(range, revealType) {
            \\          editor.visibleRanges = [range];
            \\          globalThis._wizp_uiQueue.push({type: 'revealRange', uri: document.uri.toString(), range: { start: range.start, end: range.end }, revealType: revealType || 0});
            \\        },
            \\        edit: async function(callback) {
            \\          const edits = [];
            \\          const builder = {
            \\            replace: function(range, text) { edits.push(new globalThis._wizpContext.TextEdit(range, text)); },
            \\            insert: function(position, text) { edits.push(globalThis._wizpContext.TextEdit.insert(position, text)); },
            \\            delete: function(range) { edits.push(globalThis._wizpContext.TextEdit.delete(range)); },
            \\            setEndOfLine: function(eol) { document.eol = eol; }
            \\          };
            \\          callback(builder);
            \\          globalThis._wizpContext.workspace._changeTextDocument(document, edits);
            \\          return true;
            \\        },
            \\        hide: function() {
            \\          globalThis._wizpVisibleTextEditors = globalThis._wizpVisibleTextEditors.filter(e => e !== editor);
            \\          if (globalThis._wizpActiveTextEditor === editor) globalThis._wizpActiveTextEditor = globalThis._wizpVisibleTextEditors[0] || null;
            \\        }
            \\      };
            \\      return editor;
            \\    },
            \\    showTextDocument: async function(documentOrUri, columnOrOptions, preserveFocus) {
            \\      const document = documentOrUri && documentOrUri.getText ? documentOrUri : await globalThis._wizpContext.workspace.openTextDocument(documentOrUri);
            \\      const column = typeof columnOrOptions === 'number' ? columnOrOptions : (columnOrOptions && columnOrOptions.viewColumn) || 1;
            \\      let editor = globalThis._wizpVisibleTextEditors.find(e => e.document && e.document.uri.toString() === document.uri.toString());
            \\      if (!editor) {
            \\        editor = globalThis._wizpContext.window._makeTextEditor(document, column);
            \\        globalThis._wizpVisibleTextEditors.push(editor);
            \\      }
            \\      editor.viewColumn = column;
            \\      if (!(columnOrOptions && columnOrOptions.preserveFocus) && !preserveFocus) globalThis._wizpActiveTextEditor = editor;
            \\      if (columnOrOptions && columnOrOptions.selection) {
            \\        editor.selection = new globalThis._wizpContext.Selection(columnOrOptions.selection.start, columnOrOptions.selection.end);
            \\        editor.selections = [editor.selection];
            \\      }
            \\      globalThis._wizp_uiQueue.push({type: 'showTextDocument', uri: document.uri.toString(), viewColumn: editor.viewColumn, preserveFocus: !!(preserveFocus || (columnOrOptions && columnOrOptions.preserveFocus))});
            \\      return editor;
            \\    },
            \\    createTextEditorDecorationType: function(options) {
            \\      const id = "decoration_" + (++globalThis._wizp_disposableId);
            \\      const type = {
            \\        key: id,
            \\        id: id,
            \\        options: options || {},
            \\        disposed: false,
            \\        dispose: function() {
            \\          type.disposed = true;
            \\          for (const uri of Object.keys(globalThis._wizpEditorDecorations || {})) {
            \\            delete globalThis._wizpEditorDecorations[uri][id];
            \\          }
            \\          globalThis._wizp_uiQueue.push({type: 'decorations', action: 'disposeType', typeId: id});
            \\        }
            \\      };
            \\      globalThis._wizpDecorationTypes[id] = type;
            \\      globalThis._wizp_uiQueue.push({type: 'decorationType', id: id, options: type.options});
            \\      return type;
            \\    },
            \\    get activeTextEditor() {
            \\      if (!globalThis._wizpActiveTextEditor) {
            \\        const document = globalThis._wizpContext.workspace._makeTextDocument(globalThis._wizpContext.Uri.file('active.txt'), '', 'plaintext', 1);
            \\        globalThis._wizpActiveTextEditor = globalThis._wizpContext.window._makeTextEditor(document, 1);
            \\        globalThis._wizpVisibleTextEditors = [globalThis._wizpActiveTextEditor];
            \\      }
            \\      return globalThis._wizpActiveTextEditor;
            \\    },
            \\    get visibleTextEditors() {
            \\      return globalThis._wizpVisibleTextEditors.slice();
            \\    },
            \\    get activeNotebookEditor() { return undefined; },
            \\    get visibleNotebookEditors() { return []; },
            \\    tabGroups: {
            \\      get all() { return [{ isActive: true, viewColumn: 1, activeTab: undefined, tabs: [] }]; },
            \\      get activeTabGroup() { return globalThis._wizpContext.window.tabGroups.all[0]; },
            \\      onDidChangeTabs: function(callback) { return { dispose: function() {} }; },
            \\      onDidChangeTabGroups: function(callback) { return { dispose: function() {} }; },
            \\      close: function(tabOrTabs, preserveFocus) { return Promise.resolve(true); }
            \\    },
            \\    onDidChangeActiveTextEditor: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeVisibleTextEditors: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeTextEditorSelection: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeTextEditorVisibleRanges: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeTextEditorOptions: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeWindowState: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeActiveNotebookEditor: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeVisibleNotebookEditors: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeNotebookEditorSelection: function(callback) { return { dispose: function() {} }; },
            \\    onDidChangeNotebookEditorVisibleRanges: function(callback) { return { dispose: function() {} }; },
            \\    registerTerminalLinkProvider: function(provider) {
            \\      globalThis._wizpTerminalLinkProviders = globalThis._wizpTerminalLinkProviders || [];
            \\      const id = "terminalLinkProvider_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, provider: provider || {} };
            \\      globalThis._wizpTerminalLinkProviders.push(entry);
            \\      globalThis._wizp_uiQueue.push({ type: 'terminalLinkProviderRegistered', id: id });
            \\      return {
            \\        dispose: function() {
            \\          globalThis._wizpTerminalLinkProviders = (globalThis._wizpTerminalLinkProviders || []).filter(function(item) { return item.id !== id; });
            \\        }
            \\      };
            \\    },
            \\  },
            \\  // commands API
            \\  commands: {
            \\    _registry: {},
            \\    _builtinProviderCommands: null,
            \\    _ensureBuiltinProviderCommands: function() {
            \\      if (globalThis._wizpContext.commands._builtinProviderCommands) {
            \\        return globalThis._wizpContext.commands._builtinProviderCommands;
            \\      }
            \\      const toUri = function(value) {
            \\        if (value && typeof value === 'object' && value.scheme) return value;
            \\        if (value && typeof value === 'object' && value.uri) return value.uri;
            \\        if (typeof value === 'string') {
            \\          return value.indexOf('://') >= 0 ? globalThis._wizpContext.Uri.parse(value) : globalThis._wizpContext.Uri.file(value);
            \\        }
            \\        const editor = globalThis._wizpContext.window.activeTextEditor;
            \\        if (editor && editor.document && editor.document.uri) return editor.document.uri;
            \\        return globalThis._wizpContext.Uri.file('active.txt');
            \\      };
            \\      const ensureDocument = async function(value) {
            \\        if (value && typeof value === 'object' && typeof value.getText === 'function' && value.uri) return value;
            \\        const uri = toUri(value);
            \\        const key = uri && uri.toString ? uri.toString() : String(uri || '');
            \\        let document = globalThis._wizpDocuments[key];
            \\        if (!document) {
            \\          document = await globalThis._wizpContext.workspace.openTextDocument(uri);
            \\        }
            \\        await globalThis._wizpContext.window.showTextDocument(document, { preview: false, preserveFocus: false });
            \\        return document;
            \\      };
            \\      const toPosition = function(document, value) {
            \\        if (value instanceof globalThis._wizpContext.Position) {
            \\          return document && typeof document.validatePosition === 'function' ? document.validatePosition(value) : value;
            \\        }
            \\        const raw = value && typeof value === 'object'
            \\          ? value
            \\          : { line: 0, character: 0 };
            \\        const position = new globalThis._wizpContext.Position(
            \\          Number(Object.prototype.hasOwnProperty.call(raw, 'line') ? raw.line : (raw.lineNumber || 0)) || 0,
            \\          Number(Object.prototype.hasOwnProperty.call(raw, 'character') ? raw.character : (raw.column || 0)) || 0
            \\        );
            \\        return document && typeof document.validatePosition === 'function' ? document.validatePosition(position) : position;
            \\      };
            \\      const toRange = function(document, value, fallbackPosition) {
            \\        if (value instanceof globalThis._wizpContext.Range) return value;
            \\        if (value && value.start && value.end) {
            \\          return new globalThis._wizpContext.Range(
            \\            toPosition(document, value.start),
            \\            toPosition(document, value.end)
            \\          );
            \\        }
            \\        const position = fallbackPosition || toPosition(document, { line: 0, character: 0 });
            \\        return new globalThis._wizpContext.Range(position, position);
            \\      };
            \\      const providerEntries = function(listName, document) {
            \\        const list = globalThis[listName] || [];
            \\        return list
            \\          .map(function(entry, index) {
            \\            return Object.assign({}, entry, {
            \\              _score: globalThis._wizpContext.languages.match(entry && entry.selector, document) || 0,
            \\              _order: index
            \\            });
            \\          })
            \\          .filter(function(entry) { return entry._score > 0; })
            \\          .sort(function(a, b) { return b._score - a._score || a._order - b._order; });
            \\      };
            \\      const arrayify = function(value) {
            \\        if (value === undefined || value === null) return [];
            \\        return Array.isArray(value) ? value : [value];
            \\      };
            \\      const nextToken = function() {
            \\        const overriddenToken = globalThis._wizpProviderOverrideToken;
            \\        if (overriddenToken && typeof overriddenToken === 'object') return overriddenToken;
            \\        return new globalThis._wizpContext.CancellationTokenSource().token;
            \\      };
            \\      const hostCompletionLanguage = function(document) {
            \\        return String((document && document.languageId) || '').toLowerCase();
            \\      };
            \\      const hostCompletionBasename = function(document) {
            \\        const uri = document && document.uri;
            \\        const raw = String((document && document.fileName) || (uri && (uri.fsPath || uri.path)) || '');
            \\        return raw.replace(/\\/g, '/').split('/').pop().toLowerCase();
            \\      };
            \\      const makeHostCompletionItem = function(spec) {
            \\        const item = new globalThis._wizpContext.CompletionItem(spec.label, spec.kind);
            \\        item.insertText = spec.snippet
            \\          ? new globalThis._wizpContext.SnippetString(spec.insertText || spec.label)
            \\          : (spec.insertText || spec.label);
            \\        item.sortText = spec.sortText || spec.label;
            \\        item.filterText = spec.filterText || '';
            \\        item.detail = spec.detail === undefined ? '' : spec.detail;
            \\        item.documentation = spec.documentation === undefined ? null : spec.documentation;
            \\        item.commitCharacters = spec.commitCharacters || [];
            \\        return item;
            \\      };
            \\      const collectDocumentWordCompletionItems = function(document, position) {
            \\        const text = document && typeof document.getText === 'function' ? String(document.getText() || '') : '';
            \\        if (!text) return [];
            \\        const line = document && typeof document.lineAt === 'function' ? document.lineAt(position.line) : { text: '' };
            \\        const activeLineText = String((line && line.text) || '');
            \\        const activeCharacter = Math.max(0, Math.min(position.character || 0, activeLineText.length));
            \\        let activeWordStart = activeCharacter;
            \\        while (activeWordStart > 0 && /[A-Za-z0-9_]/.test(activeLineText.charAt(activeWordStart - 1))) activeWordStart -= 1;
            \\        let activeWordEnd = activeCharacter;
            \\        while (activeWordEnd < activeLineText.length && /[A-Za-z0-9_]/.test(activeLineText.charAt(activeWordEnd))) activeWordEnd += 1;
            \\        const activeWord = activeWordStart < activeWordEnd ? activeLineText.slice(activeWordStart, activeWordEnd) : '';
            \\        const items = [];
            \\        const seen = new Set();
            \\        const regex = /[A-Za-z_][A-Za-z0-9_]*/g;
            \\        let match = null;
            \\        while ((match = regex.exec(text)) !== null) {
            \\          const word = String(match[0] || '');
            \\          if (!word || word === activeWord || seen.has(word)) continue;
            \\          seen.add(word);
            \\          items.push(makeHostCompletionItem({
            \\            label: word,
            \\            kind: globalThis._wizpContext.CompletionItemKind.Text,
            \\            insertText: word,
            \\            sortText: word,
            \\            detail: '',
            \\            documentation: null
            \\          }));
            \\        }
            \\        return items;
            \\      };
            \\      const emmetHtmlCompletionSpecs = [
            \\        { label: 'a', documentation: '<a href="|">|</a>', insertText: '<a href="${1}">${0}</a>' },
            \\        { label: 'a:blank', documentation: '<a href="http://|" target="_blank" rel="noopener noreferrer">|</a>', insertText: '<a href="http://${1}" target="_blank" rel="noopener noreferrer">${0}</a>' },
            \\        { label: 'a:link', documentation: '<a href="http://|">|</a>', insertText: '<a href="http://${1}">${0}</a>' },
            \\        { label: 'a:mail', documentation: '<a href="mailto:|">|</a>', insertText: '<a href="mailto:${1}">${0}</a>' },
            \\        { label: 'a:tel', documentation: '<a href="tel:+|">|</a>', insertText: '<a href="tel:+${1}">${0}</a>' },
            \\        { label: 'abbr', documentation: '<abbr title="|">|</abbr>', insertText: '<abbr title="${1}">${0}</abbr>' },
            \\        { label: 'acr', documentation: '<acronym title="|">|</acronym>', insertText: '<acronym title="${1}">${0}</acronym>' },
            \\        { label: 'acronym', documentation: '<acronym title="|">|</acronym>', insertText: '<acronym title="${1}">${0}</acronym>' },
            \\        { label: 'address', documentation: '<address>|</address>', insertText: '<address>${0}</address>' },
            \\        { label: 'adr', documentation: '<address>|</address>', insertText: '<address>${0}</address>' },
            \\        { label: 'applet', documentation: '<applet>|</applet>', insertText: '<applet>${0}</applet>' },
            \\        { label: 'area', documentation: '<area shape="|" coords="|" href="|" alt="|">', insertText: '<area shape="${1}" coords="${2}" href="${3}" alt="${0}">' },
            \\        { label: 'area:c', documentation: '<area shape="circle" coords="|" href="|" alt="|">', insertText: '<area shape="circle" coords="${1}" href="${2}" alt="${0}">' },
            \\        { label: 'area:d', documentation: '<area shape="default" coords="|" href="|" alt="|">', insertText: '<area shape="default" coords="${1}" href="${2}" alt="${0}">' },
            \\        { label: 'area:p', documentation: '<area shape="poly" coords="|" href="|" alt="|">', insertText: '<area shape="poly" coords="${1}" href="${2}" alt="${0}">' },
            \\        { label: 'area:r', documentation: '<area shape="rect" coords="|" href="|" alt="|">', insertText: '<area shape="rect" coords="${1}" href="${2}" alt="${0}">' },
            \\        { label: 'art', documentation: '<article>|</article>', insertText: '<article>${0}</article>' },
            \\        { label: 'article', documentation: '<article>|</article>', insertText: '<article>${0}</article>' },
            \\        { label: 'aside', documentation: '<aside>|</aside>', insertText: '<aside>${0}</aside>' },
            \\        { label: 'audio', documentation: '<audio src="|">|</audio>', insertText: '<audio src="${1}">${0}</audio>' }
            \\      ];
            \\      const hostBuiltinCompletionSet = function(document, position) {
            \\        const languageId = hostCompletionLanguage(document);
            \\        const basename = hostCompletionBasename(document);
            \\        const items = [];
            \\        const sources = [];
            \\        let isIncomplete = false;
            \\        if (['html', 'php', 'vue', 'javascriptreact', 'typescriptreact'].indexOf(languageId) >= 0) {
            \\          for (const spec of emmetHtmlCompletionSpecs) {
            \\            items.push(makeHostCompletionItem(Object.assign({
            \\              kind: globalThis._wizpContext.CompletionItemKind.Property,
            \\              detail: 'Emmet Abbreviation',
            \\              snippet: true
            \\            }, spec)));
            \\          }
            \\          isIncomplete = true;
            \\          sources.push('emmet');
            \\        }
            \\        if (languageId === 'go' || basename === 'go.mod') {
            \\          for (const item of collectDocumentWordCompletionItems(document, position)) items.push(item);
            \\          items.push(makeHostCompletionItem({
            \\            label: 'go',
            \\            kind: globalThis._wizpContext.CompletionItemKind.Snippet,
            \\            insertText: 'go func($1) {\n\t$0\n}($2)',
            \\            sortText: 'z-go',
            \\            detail: 'Snippet for anonymous goroutine declaration (Go)',
            \\            documentation: '\\n```\\ngo func() {\\n\\t\\n}()\\n```\\n',
            \\            snippet: true
            \\          }));
            \\          sources.push('documentWords', 'goSnippets');
            \\        }
            \\        return { items: items, isIncomplete: isIncomplete, sources: sources };
            \\      };
            \\      const commands = {
            \\        'vscode.executeCompletionItemProvider': async function(uriValue, positionValue, triggerCharacter, itemResolveCount) {
            \\          const document = await ensureDocument(uriValue);
            \\          const position = toPosition(document, positionValue);
            \\          const entries = providerEntries('_wizpCompletionProviders', document);
            \\          const completionContext = triggerCharacter
            \\            ? { triggerKind: globalThis._wizpContext.CompletionTriggerKind.TriggerCharacter, triggerCharacter: String(triggerCharacter) }
            \\            : { triggerKind: globalThis._wizpContext.CompletionTriggerKind.Invoke };
            \\          const collected = [];
            \\          let collectionOrder = 0;
            \\          let isIncomplete = false;
            \\          for (const entry of entries) {
            \\            try {
            \\              const provided = await Promise.resolve(entry.provider.provideCompletionItems(document, position, nextToken(), completionContext));
            \\              const container = Array.isArray(provided) ? { items: provided, isIncomplete: false } : (provided || null);
            \\              if (container && (container.isIncomplete || container.incomplete)) isIncomplete = true;
            \\              const items = Array.isArray(provided) ? provided : ((container && Array.isArray(container.items)) ? container.items : []);
            \\              for (const item of items) {
            \\                collected.push({ providerEntry: entry, item: item, _itemOrder: collectionOrder++ });
            \\              }
            \\            } catch (_) {}
            \\          }
            \\          const builtinCompletionSet = hostBuiltinCompletionSet(document, position);
            \\          for (const item of builtinCompletionSet.items) {
            \\            collected.push({ providerEntry: null, item: item, _itemOrder: collectionOrder++ });
            \\          }
            \\          if (builtinCompletionSet.isIncomplete) isIncomplete = true;
            \\          const completionLabelText = function(item) {
            \\            return typeof item.label === 'string'
            \\              ? item.label
            \\              : ((item && item.label && item.label.label) || '');
            \\          };
            \\          const defaultWordRange = document && typeof document.getWordRangeAtPosition === 'function'
            \\            ? (document.getWordRangeAtPosition(position) || new globalThis._wizpContext.Range(position, position))
            \\            : new globalThis._wizpContext.Range(position, position);
            \\          const defaultReplaceRange = document && typeof document.validateRange === 'function'
            \\            ? document.validateRange(defaultWordRange)
            \\            : defaultWordRange;
            \\          const defaultInsertRange = new globalThis._wizpContext.Range(defaultReplaceRange.start, position);
            \\          const normalizeRange = function(value) {
            \\            if (!value) {
            \\              return {
            \\                insert: defaultInsertRange,
            \\                replace: defaultReplaceRange
            \\              };
            \\            }
            \\            if (value.start && value.end) {
            \\              return document && typeof document.validateRange === 'function'
            \\                ? document.validateRange(value)
            \\                : value;
            \\            }
            \\            const insertRange = value.insert || value.inserting || defaultInsertRange;
            \\            const replaceRange = value.replace || value.replacing || defaultReplaceRange;
            \\            return {
            \\              insert: document && typeof document.validateRange === 'function' ? document.validateRange(insertRange) : insertRange,
            \\              replace: document && typeof document.validateRange === 'function' ? document.validateRange(replaceRange) : replaceRange
            \\            };
            \\          };
            \\          const normalized = collected.map(function(row) {
            \\            const suggestion = row && row.item ? row.item : {};
            \\            if (!suggestion.range) {
            \\              suggestion.range = normalizeRange(null);
            \\            } else {
            \\              suggestion.range = normalizeRange(suggestion.range);
            \\            }
            \\            if (!suggestion.sortText) suggestion.sortText = completionLabelText(suggestion);
            \\            return { providerEntry: row && row.providerEntry ? row.providerEntry : null, item: suggestion, _itemOrder: row && Number.isFinite(Number(row._itemOrder)) ? Number(row._itemOrder) : Number.MAX_SAFE_INTEGER };
            \\          });
            \\          const providerRank = function(row) {
            \\            const entry = row && row.providerEntry ? row.providerEntry : null;
            \\            return {
            \\              score: entry ? (Number(entry._score) || 0) : -1,
            \\              order: entry ? (Number(entry._order) || 0) : Number.MAX_SAFE_INTEGER
            \\            };
            \\          };
            \\          normalized.sort(function(a, b) {
            \\            const providerA = providerRank(a);
            \\            const providerB = providerRank(b);
            \\            if (providerA.score !== providerB.score) return providerB.score - providerA.score;
            \\            if (providerA.order !== providerB.order) return providerA.order - providerB.order;
            \\            const itemA = a && a.item ? a.item : {};
            \\            const itemB = b && b.item ? b.item : {};
            \\            const snippetKind = globalThis._wizpContext.CompletionItemKind.Snippet;
            \\            const kindA = itemA && itemA.kind === undefined ? globalThis._wizpContext.CompletionItemKind.Property : itemA.kind;
            \\            const kindB = itemB && itemB.kind === undefined ? globalThis._wizpContext.CompletionItemKind.Property : itemB.kind;
            \\            if (kindA !== kindB) {
            \\              if (kindA === snippetKind) return 1;
            \\              if (kindB === snippetKind) return -1;
            \\            }
            \\            const sortTextA = itemA && itemA.sortText ? String(itemA.sortText).toLowerCase() : '';
            \\            const sortTextB = itemB && itemB.sortText ? String(itemB.sortText).toLowerCase() : '';
            \\            if (sortTextA && sortTextB) {
            \\              if (sortTextA < sortTextB) return -1;
            \\              if (sortTextA > sortTextB) return 1;
            \\            }
            \\            const labelA = completionLabelText(itemA);
            \\            const labelB = completionLabelText(itemB);
            \\            if (labelA < labelB) return -1;
            \\            if (labelA > labelB) return 1;
            \\            return ((kindA || 0) - (kindB || 0)) || ((a && a._itemOrder) || 0) - ((b && b._itemOrder) || 0);
            \\          });
            \\          const resolveCount = Number.isFinite(Number(itemResolveCount))
            \\            ? Math.max(0, Math.floor(Number(itemResolveCount)))
            \\            : 0;
            \\          for (let index = 0; index < normalized.length && index < resolveCount; index += 1) {
            \\            const row = normalized[index];
            \\            if (!row || !row.providerEntry || !row.providerEntry.provider || !row.providerEntry.provider.resolveCompletionItem) continue;
            \\            try {
            \\              row.item = await Promise.resolve(row.providerEntry.provider.resolveCompletionItem(row.item, nextToken())) || row.item;
            \\            } catch (_) {}
            \\          }
            \\          const completionList = new globalThis._wizpContext.CompletionList(normalized.map(function(row) { return row.item; }), isIncomplete);
            \\          completionList._wizpInvalidCount = 0;
            \\          completionList._wizpBuiltinSources = builtinCompletionSet.sources || [];
            \\          return completionList;
            \\        },
            \\        'vscode.executeHoverProvider': async function(uriValue, positionValue) {
            \\          const document = await ensureDocument(uriValue);
            \\          const position = toPosition(document, positionValue);
            \\          const entries = providerEntries('_wizpHoverProviders', document);
            \\          const results = [];
            \\          for (const entry of entries) {
            \\            try {
            \\              const hover = await Promise.resolve(entry.provider.provideHover(document, position, nextToken()));
            \\              if (hover) results.push(hover);
            \\            } catch (_) {}
            \\          }
            \\          return results;
            \\        },
            \\        'vscode.executeDefinitionProvider': async function(uriValue, positionValue) {
            \\          const document = await ensureDocument(uriValue);
            \\          const position = toPosition(document, positionValue);
            \\          const entries = providerEntries('_wizpDefinitionProviders', document);
            \\          const results = [];
            \\          for (const entry of entries) {
            \\            try {
            \\              const locations = await Promise.resolve(entry.provider.provideDefinition(document, position, nextToken()));
            \\              results.push.apply(results, arrayify(locations).filter(Boolean));
            \\            } catch (_) {}
            \\          }
            \\          return results;
            \\        },
            \\        'vscode.executeReferenceProvider': async function(uriValue, positionValue, contextValue) {
            \\          const document = await ensureDocument(uriValue);
            \\          const position = toPosition(document, positionValue);
            \\          const entries = providerEntries('_wizpReferenceProviders', document);
            \\          const referenceContext = contextValue && typeof contextValue === 'object'
            \\            ? contextValue
            \\            : { includeDeclaration: true };
            \\          const results = [];
            \\          for (const entry of entries) {
            \\            try {
            \\              const locations = await Promise.resolve(entry.provider.provideReferences(document, position, referenceContext, nextToken()));
            \\              results.push.apply(results, arrayify(locations).filter(Boolean));
            \\            } catch (_) {}
            \\          }
            \\          return results;
            \\        },
            \\        'vscode.prepareRename': async function(uriValue, positionValue) {
            \\          const document = await ensureDocument(uriValue);
            \\          const position = toPosition(document, positionValue);
            \\          const entries = providerEntries('_wizpRenameProviders', document);
            \\          for (const entry of entries) {
            \\            if (!entry.provider || typeof entry.provider.prepareRename !== 'function') continue;
            \\            try {
            \\              const prepared = await Promise.resolve(entry.provider.prepareRename(document, position, nextToken()));
            \\              if (prepared !== undefined) return prepared;
            \\            } catch (_) {}
            \\          }
            \\          return null;
            \\        },
            \\        'vscode.executeDocumentRenameProvider': async function(uriValue, positionValue, newName) {
            \\          const document = await ensureDocument(uriValue);
            \\          const position = toPosition(document, positionValue);
            \\          const entries = providerEntries('_wizpRenameProviders', document);
            \\          for (const entry of entries) {
            \\            if (!entry.provider || typeof entry.provider.provideRenameEdits !== 'function') continue;
            \\            try {
            \\              const edit = await Promise.resolve(entry.provider.provideRenameEdits(document, position, newName, nextToken()));
            \\              if (edit !== undefined) return edit;
            \\            } catch (_) {}
            \\          }
            \\          return null;
            \\        },
            \\        'vscode.executeCodeActionProvider': async function(uriValue, rangeValue, contextValue) {
            \\          const document = await ensureDocument(uriValue);
            \\          const range = toRange(document, rangeValue);
            \\          const actionContext = contextValue && typeof contextValue === 'object'
            \\            ? contextValue
            \\            : { diagnostics: [], triggerKind: 1 };
            \\          const entries = providerEntries('_wizpCodeActionProviders', document);
            \\          const actions = [];
            \\          for (const entry of entries) {
            \\            try {
            \\              const provided = await Promise.resolve(entry.provider.provideCodeActions(document, range, actionContext, nextToken()));
            \\              for (const action of arrayify(provided).filter(Boolean)) {
            \\                let resolved = action;
            \\                if (entry.provider.resolveCodeAction) {
            \\                  try {
            \\                    resolved = await Promise.resolve(entry.provider.resolveCodeAction(action, nextToken())) || action;
            \\                  } catch (_) {}
            \\                }
            \\                actions.push(resolved);
            \\              }
            \\            } catch (_) {}
            \\          }
            \\          return actions;
            \\        },
            \\        'vscode.executeFormatDocumentProvider': async function(uriValue, options) {
            \\          const document = await ensureDocument(uriValue);
            \\          const entries = providerEntries('_wizpDocumentFormattingProviders', document);
            \\          const edits = [];
            \\          for (const entry of entries) {
            \\            try {
            \\              const provided = await Promise.resolve(entry.provider.provideDocumentFormattingEdits(document, options || { tabSize: 2, insertSpaces: true }, nextToken()));
            \\              edits.push.apply(edits, arrayify(provided).filter(Boolean));
            \\            } catch (_) {}
            \\          }
            \\          return edits;
            \\        },
            \\        'vscode.executeDocumentSymbolProvider': async function(uriValue) {
            \\          const document = await ensureDocument(uriValue);
            \\          const entries = providerEntries('_wizpDocumentSymbolProviders', document);
            \\          const results = [];
            \\          for (const entry of entries) {
            \\            try {
            \\              const provided = await Promise.resolve(entry.provider.provideDocumentSymbols(document, nextToken()));
            \\              results.push.apply(results, arrayify(provided).filter(Boolean));
            \\            } catch (_) {}
            \\          }
            \\          return results;
            \\        }
            \\      };
            \\      commands.prepareRename = commands['vscode.prepareRename'];
            \\      globalThis._wizpContext.commands._builtinProviderCommands = commands;
            \\      return commands;
            \\    },
            \\    registerCommand: function(id, callback) {
            \\      globalThis._wizpContext.commands._registry[id] = callback;
            \\      globalThis._wizp_uiQueue.push({type: 'commandRegistered', command: id});
            \\      return { dispose: function() {} };
            \\    },
            \\    registerTextEditorCommand: function(id, callback) {
            \\      globalThis._wizpContext.commands._registry[id] = function(...args) {
            \\        const editor = globalThis._wizpContext.window.activeTextEditor;
            \\        const builder = {
            \\          replace: function(range, text) { return editor.edit(function(editBuilder) { editBuilder.replace(range, text); }); },
            \\          insert: function(position, text) { return editor.edit(function(editBuilder) { editBuilder.insert(position, text); }); },
            \\          delete: function(range) { return editor.edit(function(editBuilder) { editBuilder.delete(range); }); }
            \\        };
            \\        return callback(editor, builder, ...args);
            \\      };
            \\      globalThis._wizp_uiQueue.push({type: 'commandRegistered', command: id});
            \\      return { dispose: function() {} };
            \\    },
            \\    executeCommand: function(id, ...args) {
            \\      if (id === 'setContext') {
            \\        globalThis._wizpContextKeys[args[0]] = args[1];
            \\        return Promise.resolve(true);
            \\      }
            \\      if (id === 'npm.packageManager') return Promise.resolve('npm');
            \\      const builtinId = id === 'prepareRename' ? 'vscode.prepareRename' : id;
            \\      const builtin = globalThis._wizpContext.commands._ensureBuiltinProviderCommands()[builtinId];
            \\      if (builtin) return Promise.resolve(builtin(...args));
            \\      const cb = globalThis._wizpContext.commands._registry[id];
            \\      if (!cb) return Promise.resolve(undefined);
            \\      return Promise.resolve(cb(...args));
            \\    }
            \\  },
            \\  env: {
            \\    appName: (globalThis._wizpNodeProcess && globalThis._wizpNodeProcess.env && globalThis._wizpNodeProcess.env.WIZP_EXTENSION_APP_NAME) || "WIZP",
            \\    appHost: "desktop",
            \\    language: "en",
            \\    shell: "bash",
            \\    uiKind: 1,
            \\    machineId: "wizp-machine",
            \\    sessionId: "wizp-session",
            \\    isTelemetryEnabled: false,
            \\    remoteName: undefined,
            \\    appRoot: ".",
            \\    uriScheme: "wizp",
            \\    asExternalUri: function(uri) { return Promise.resolve(uri); },
            \\    onDidChangeTelemetryEnabled: function(callback, thisArg, disposables) {
            \\      const disposable = { dispose: function() {} };
            \\      if (Array.isArray(disposables)) disposables.push(disposable);
            \\      return disposable;
            \\    },
            \\    createTelemetryLogger: function(sender, options) {
            \\      const listeners = [];
            \\      return {
            \\        isUsageEnabled: false,
            \\        isErrorsEnabled: false,
            \\        onDidChangeEnableStates: function(callback, thisArg, disposables) {
            \\          const wrapped = function(event) { return callback.call(thisArg, event || { isUsageEnabled: false, isErrorsEnabled: false }); };
            \\          listeners.push(wrapped);
            \\          const disposable = { dispose: function() { const index = listeners.indexOf(wrapped); if (index >= 0) listeners.splice(index, 1); } };
            \\          if (Array.isArray(disposables)) disposables.push(disposable);
            \\          return disposable;
            \\        },
            \\        sendEventData: function(eventName, data) {},
            \\        sendErrorData: function(error, data) {},
            \\        logUsage: function(eventName, data) {},
            \\        logError: function(error, data) {},
            \\        dispose: function() { listeners.length = 0; }
            \\      };
            \\    },
            \\    clipboard: {
            \\      readText: function() {
            \\        return new Promise((resolve) => {
            \\          const id = ++globalThis._wizp_disposableId;
            \\          globalThis._wizp_uiResolvers[id] = resolve;
            \\          globalThis._wizp_uiQueue.push({id: id, type: "clipboardRead"});
            \\        });
            \\      },
            \\      writeText: function(text) {
            \\        return new Promise((resolve) => {
            \\          const id = ++globalThis._wizp_disposableId;
            \\          globalThis._wizp_uiResolvers[id] = resolve;
            \\          globalThis._wizp_uiQueue.push({id: id, type: "clipboardWrite", text: text});
            \\        });
            \\      }
            \\    },
            \\    openExternal: function(uri) {
            \\        return new Promise((resolve) => {
            \\          const id = ++globalThis._wizp_disposableId;
            \\          globalThis._wizp_uiResolvers[id] = resolve;
            \\          globalThis._wizp_uiQueue.push({id: id, type: "openExternal", uri: uri.toString()});
            \\        });
            \\    },
            \\  },
            \\  Uri: class {
            \\    constructor(scheme, authority, path, query, fragment) {
            \\      this.scheme = scheme || 'file';
            \\      this.authority = authority || '';
            \\      this.path = path || '';
            \\      this.query = query || '';
            \\      this.fragment = fragment || '';
            \\      this.fsPath = this.scheme === 'file' ? this.path : this.path;
            \\    }
            \\    static file(path) {
            \\      let value = String(path || '');
            \\      if (value && !globalThis._wizpNodePath.isAbsolute(value)) value = globalThis._wizpNodePath.join(globalThis._wizpCwd || '.', value);
            \\      return new globalThis._wizpContext.Uri('file', '', value, '', '');
            \\    }
            \\    static parse(value) {
            \\      const str = String(value || '');
            \\      const match = str.match(/^([A-Za-z][A-Za-z0-9+.-]*):(\/\/([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?$/);
            \\      if (!match) return globalThis._wizpContext.Uri.file(str);
            \\      let path = match[4] || '';
            \\      let authority = match[3] || '';
            \\      if (path.length === 0 && authority && match[1] === 'file') { path = authority; authority = ''; }
            \\      return new globalThis._wizpContext.Uri(match[1], authority, path, match[6] || '', match[8] || '');
            \\    }
            \\    static joinPath(base, ...paths) {
            \\      const parts = [base.path || ''].concat(paths.map(p => String(p || ''))).join('/').split('/');
            \\      const normalized = [];
            \\      for (const part of parts) {
            \\        if (!part || part === '.') continue;
            \\        if (part === '..') normalized.pop(); else normalized.push(part);
            \\      }
            \\      const joined = normalized.join('/');
            \\      const needsLeadingSlash = (base.path || '').startsWith('/') || !!base.authority;
            \\      return base.with({ path: needsLeadingSlash ? '/' + joined : joined });
            \\    }
            \\    with(change) {
            \\      const c = change || {};
            \\      return new globalThis._wizpContext.Uri(
            \\        c.scheme === undefined ? this.scheme : c.scheme,
            \\        c.authority === undefined ? this.authority : c.authority,
            \\        c.path === undefined ? this.path : c.path,
            \\        c.query === undefined ? this.query : c.query,
            \\        c.fragment === undefined ? this.fragment : c.fragment
            \\      );
            \\    }
            \\    toString() {
            \\      const auth = this.authority ? '//' + this.authority : (this.scheme === 'file' ? '//' : '');
            \\      const path = this.authority && this.path && !this.path.startsWith('/') ? '/' + this.path : this.path;
            \\      const query = this.query ? '?' + this.query : '';
            \\      const fragment = this.fragment ? '#' + this.fragment : '';
            \\      return this.scheme + ':' + auth + path + query + fragment;
            \\    }
            \\    toJSON() { return { scheme: this.scheme, authority: this.authority, path: this.path, query: this.query, fragment: this.fragment, external: this.toString(), $mid: 1 }; }
            \\  },
            \\  FileType: { Unknown: 0, File: 1, Directory: 2, SymbolicLink: 64 },
            \\  FileSystemError: class extends Error {
            \\    constructor(messageOrUri) {
            \\      const message = messageOrUri && messageOrUri.toString ? messageOrUri.toString() : String(messageOrUri || 'File system error');
            \\      super(message);
            \\      this.name = 'FileSystemError';
            \\      this.code = 'Unknown';
            \\    }
            \\    static _make(code, messageOrUri) {
            \\      const error = new globalThis._wizpContext.FileSystemError(messageOrUri);
            \\      error.code = code;
            \\      return error;
            \\    }
            \\    static FileExists(messageOrUri) { return globalThis._wizpContext.FileSystemError._make('FileExists', messageOrUri); }
            \\    static FileNotFound(messageOrUri) { return globalThis._wizpContext.FileSystemError._make('FileNotFound', messageOrUri); }
            \\    static FileNotADirectory(messageOrUri) { return globalThis._wizpContext.FileSystemError._make('FileNotADirectory', messageOrUri); }
            \\    static FileIsADirectory(messageOrUri) { return globalThis._wizpContext.FileSystemError._make('FileIsADirectory', messageOrUri); }
            \\    static NoPermissions(messageOrUri) { return globalThis._wizpContext.FileSystemError._make('NoPermissions', messageOrUri); }
            \\    static Unavailable(messageOrUri) { return globalThis._wizpContext.FileSystemError._make('Unavailable', messageOrUri); }
            \\  },
            \\  CancellationError: class extends Error { constructor() { super('Canceled'); this.name = 'Canceled'; } },
            \\  Disposable: class {
            \\    constructor(callOnDispose) { this._callOnDispose = callOnDispose || function() {}; this._disposed = false; }
            \\    dispose() { if (this._disposed) return; this._disposed = true; this._callOnDispose(); }
            \\    static from(...items) { return new globalThis._wizpContext.Disposable(function() { for (const item of items) if (item && item.dispose) item.dispose(); }); }
            \\  },
            \\  EventEmitter: class {
            \\    constructor() { this._listeners = []; this.event = (listener, thisArgs, disposables) => { const wrapped = thisArgs ? listener.bind(thisArgs) : listener; this._listeners.push(wrapped); const disposable = new globalThis._wizpContext.Disposable(() => { this._listeners = this._listeners.filter(item => item !== wrapped); }); if (Array.isArray(disposables)) disposables.push(disposable); return disposable; }; }
            \\    fire(data) { for (const listener of this._listeners.slice()) listener(data); }
            \\    dispose() { this._listeners = []; }
            \\  },
            \\  CancellationTokenSource: class {
            \\    constructor() { const listeners = []; this.token = { isCancellationRequested: false, onCancellationRequested: function(listener) { listeners.push(listener); return new globalThis._wizpContext.Disposable(() => { const idx = listeners.indexOf(listener); if (idx >= 0) listeners.splice(idx, 1); }); } }; this._listeners = listeners; }
            \\    cancel() { if (this.token.isCancellationRequested) return; this.token.isCancellationRequested = true; for (const listener of this._listeners.slice()) listener(undefined); }
            \\    dispose(cancel) { if (cancel) this.cancel(); this._listeners.length = 0; }
            \\  },
            \\  Position: class {
            \\    constructor(l, c) { this.line = l; this.character = c; }
            \\    isBefore(other) { return this.line < other.line || (this.line === other.line && this.character < other.character); }
            \\    isBeforeOrEqual(other) { return this.isBefore(other) || this.isEqual(other); }
            \\    isAfter(other) { return other.isBefore(this); }
            \\    isAfterOrEqual(other) { return this.isAfter(other) || this.isEqual(other); }
            \\    isEqual(other) { return !!other && this.line === other.line && this.character === other.character; }
            \\    compareTo(other) { return this.isBefore(other) ? -1 : (this.isEqual(other) ? 0 : 1); }
            \\    translate(lineDelta, characterDelta) { return new globalThis._wizpContext.Position(this.line + (lineDelta || 0), this.character + (characterDelta || 0)); }
            \\    with(line, character) { const arg = typeof line === 'object' ? line : { line: line, character: character }; return new globalThis._wizpContext.Position(arg.line === undefined ? this.line : arg.line, arg.character === undefined ? this.character : arg.character); }
            \\  },
            \\  Range: class {
            \\    constructor(s, e, endLine, endCharacter) {
            \\      if (typeof s === 'number') {
            \\        s = new globalThis._wizpContext.Position(s, e || 0);
            \\        e = new globalThis._wizpContext.Position(endLine || 0, endCharacter || 0);
            \\      }
            \\      this.start = s.isBeforeOrEqual(e) ? s : e; this.end = s.isBeforeOrEqual(e) ? e : s; this.isEmpty = this.start.isEqual(this.end); this.isSingleLine = this.start.line === this.end.line;
            \\    }
            \\    contains(value) { const pos = value && value.start ? value.start : value; const end = value && value.end ? value.end : value; return this.start.isBeforeOrEqual(pos) && this.end.isAfterOrEqual(end); }
            \\    isEqual(other) { return !!other && this.start.isEqual(other.start) && this.end.isEqual(other.end); }
            \\    intersection(other) { const start = this.start.isAfter(other.start) ? this.start : other.start; const end = this.end.isBefore(other.end) ? this.end : other.end; return start.isAfter(end) ? undefined : new globalThis._wizpContext.Range(start, end); }
            \\    union(other) { const start = this.start.isBefore(other.start) ? this.start : other.start; const end = this.end.isAfter(other.end) ? this.end : other.end; return new globalThis._wizpContext.Range(start, end); }
            \\    with(start, end) { const arg = start && start.start ? start : { start: start, end: end }; return new globalThis._wizpContext.Range(arg.start || this.start, arg.end || this.end); }
            \\  },
            \\  Selection: class {
            \\    constructor(anchor, active) {
            \\      this.anchor = anchor;
            \\      this.active = active;
            \\      this.start = (anchor.line < active.line || (anchor.line === active.line && anchor.character <= active.character)) ? anchor : active;
            \\      this.end = this.start === anchor ? active : anchor;
            \\      this.isEmpty = this.start.line === this.end.line && this.start.character === this.end.character;
            \\      this.isReversed = this.anchor === this.end;
            \\    }
            \\  },
            \\  MarkdownString: class {
            \\    constructor(value, supportThemeIcons) { this.value = value || ''; this.supportThemeIcons = !!supportThemeIcons; this.supportHtml = false; this.isTrusted = false; }
            \\    appendText(value) { this.value += String(value || '').replace(/[\\`*_{}[\\]()#+\\-.!]/g, '\\\\$&'); return this; }
            \\    appendMarkdown(value) { this.value += String(value || ''); return this; }
            \\    appendCodeblock(value, language) { this.value += '\\n```' + (language || '') + '\\n' + String(value || '') + '\\n```'; return this; }
            \\  },
            \\  SnippetString: class {
            \\    constructor(value) { this.value = value || ''; }
            \\    appendText(value) { this.value += String(value || '').replace(/[$}\\\\]/g, '\\$&'); return this; }
            \\    appendTabstop(number) { this.value += '${' + (number || 0) + '}'; return this; }
            \\    appendPlaceholder(value, number) { this.value += '${' + (number || 1) + ':' + String(value || '') + '}'; return this; }
            \\    appendChoice(values, number) { this.value += '${' + (number || 1) + '|' + (values || []).map(String).join(',') + '|}'; return this; }
            \\    appendVariable(name, defaultValue) { this.value += '${' + String(name || '') + (defaultValue === undefined ? '' : ':' + String(defaultValue)) + '}'; return this; }
            \\  },
            \\  ThemeIcon: class { constructor(id, color) { this.id = id; this.color = color; } static get File() { return new globalThis._wizpContext.ThemeIcon('file'); } static get Folder() { return new globalThis._wizpContext.ThemeIcon('folder'); } },
            \\  ThemeColor: class { constructor(id) { this.id = String(id || ''); } },
            \\  FileDecoration: class { constructor(badge, tooltip, color) { this.badge = badge; this.tooltip = tooltip; this.color = color; this.propagate = false; } },
            \\  DebugVisualization: class { constructor(id) { this.id = String(id || ''); this.iconPath = undefined; this.visualization = undefined; } },
            \\  TerminalProfile: class { constructor(options) { Object.assign(this, options || {}); } },
            \\  TreeItem: class { constructor(labelOrUriOrCollapsibleState, collapsibleState) { if (labelOrUriOrCollapsibleState && labelOrUriOrCollapsibleState.scheme) this.resourceUri = labelOrUriOrCollapsibleState; else if (typeof labelOrUriOrCollapsibleState === 'number') this.collapsibleState = labelOrUriOrCollapsibleState; else this.label = labelOrUriOrCollapsibleState; if (collapsibleState !== undefined) this.collapsibleState = collapsibleState; if (this.collapsibleState === undefined) this.collapsibleState = 0; this.id = undefined; this.description = undefined; this.tooltip = undefined; this.command = undefined; this.contextValue = undefined; this.iconPath = undefined; } },
            \\  TreeItemCollapsibleState: { None: 0, Collapsed: 1, Expanded: 2 },
            \\  RelativePattern: class { constructor(base, pattern) { this.baseUri = typeof base === 'string' ? globalThis._wizpContext.Uri.file(base) : (base.uri || base); this.base = this.baseUri.fsPath || this.baseUri.path; this.pattern = pattern; } },
            \\  Color: class { constructor(red, green, blue, alpha) { this.red = red; this.green = green; this.blue = blue; this.alpha = alpha === undefined ? 1 : alpha; } },
            \\  ColorInformation: class { constructor(range, color) { this.range = range; this.color = color; } },
            \\  ColorPresentation: class { constructor(label) { this.label = String(label || ''); this.textEdit = undefined; this.additionalTextEdits = undefined; } },
            \\  ViewColumn: { Active: -1, Beside: -2, One: 1, Two: 2, Three: 3 },
            \\  QuickInputButtonLocation: { Title: 1, Inline: 2 },
            \\  QuickInputButtons: { Back: { iconPath: { id: 'arrow-left' }, tooltip: 'Back' } },
            \\  QuickPickItemKind: { Default: 0, Separator: -1 },
            \\  TextEditorRevealType: { Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 },
            \\  TextDocumentSaveReason: { Manual: 1, AfterDelay: 2, FocusOut: 3 },
            \\  ConfigurationTarget: { Global: 1, Workspace: 2, WorkspaceFolder: 3 },
            \\  ColorThemeKind: { Light: 1, Dark: 2, HighContrast: 3, HighContrastLight: 4 },
            \\  LanguageStatusSeverity: { Information: 0, Warning: 1, Error: 2 },
            \\  EndOfLine: { LF: 1, CRLF: 2 },
            \\  IndentAction: { None: 0, Indent: 1, IndentOutdent: 2, Outdent: 3 },
            \\  OverviewRulerLane: { Left: 1, Center: 2, Right: 4, Full: 7 },
            \\  DecorationRangeBehavior: { OpenOpen: 0, ClosedClosed: 1, OpenClosed: 2, ClosedOpen: 3 },
            \\  CodeLens: class { constructor(range, command) { this.range = range; this.command = command; this.isResolved = !!command; } },
            \\  CompletionItem: class { constructor(label, kind) { this.label = label; this.kind = kind; this.detail = undefined; this.documentation = undefined; this.sortText = undefined; this.filterText = undefined; this.insertText = undefined; this.range = undefined; this.command = undefined; this.tags = undefined; } },
            \\  CompletionList: class { constructor(items, isIncomplete) { this.items = items || []; this.isIncomplete = !!isIncomplete; } },
            \\  CompletionItemKind: { Text: 0, Method: 1, Function: 2, Constructor: 3, Field: 4, Variable: 5, Class: 6, Interface: 7, Module: 8, Property: 9, Unit: 10, Value: 11, Enum: 12, Keyword: 13, Snippet: 14, Color: 15, File: 16, Reference: 17, Folder: 18, EnumMember: 19, Constant: 20, Struct: 21, Event: 22, Operator: 23, TypeParameter: 24 },
            \\  CompletionItemTag: { Deprecated: 1 },
            \\  CompletionTriggerKind: { Invoke: 0, TriggerCharacter: 1, TriggerForIncompleteCompletions: 2 },
            \\  InsertTextFormat: { PlainText: 1, Snippet: 2 },
            \\  InsertTextMode: { asIs: 1, adjustIndentation: 2 },
            \\  InsertReplaceEdit: class {
            \\    constructor(newText, inserting, replacing) {
            \\      this.newText = newText;
            \\      this.inserting = inserting;
            \\      this.replacing = replacing;
            \\    }
            \\  },
            \\  DocumentLink: class { constructor(range, target) { this.range = range; this.target = target; this.tooltip = undefined; } },
            \\  CodeAction: class { constructor(title, kind) { this.title = title; this.kind = kind; this.diagnostics = []; this.edit = undefined; this.command = undefined; this.isPreferred = false; this.disabled = undefined; } },
            \\  CodeActionKind: class {
            \\    constructor(value) { this.value = String(value || ''); }
            \\    append(parts) { return new globalThis._wizpContext.CodeActionKind(this.value ? this.value + '.' + String(parts || '') : String(parts || '')); }
            \\    contains(other) { const value = other && other.value !== undefined ? other.value : String(other || ''); return value === this.value || value.startsWith(this.value + '.'); }
            \\    intersects(other) { const value = other && other.value !== undefined ? other.value : String(other || ''); return this.contains(value) || String(this.value || '').startsWith(value + '.'); }
            \\    toString() { return this.value; }
            \\    static get Empty() { return new globalThis._wizpContext.CodeActionKind(''); }
            \\    static get QuickFix() { return new globalThis._wizpContext.CodeActionKind('quickfix'); }
            \\    static get Refactor() { return new globalThis._wizpContext.CodeActionKind('refactor'); }
            \\    static get RefactorExtract() { return new globalThis._wizpContext.CodeActionKind('refactor.extract'); }
            \\    static get RefactorInline() { return new globalThis._wizpContext.CodeActionKind('refactor.inline'); }
            \\    static get RefactorRewrite() { return new globalThis._wizpContext.CodeActionKind('refactor.rewrite'); }
            \\    static get Source() { return new globalThis._wizpContext.CodeActionKind('source'); }
            \\    static get SourceOrganizeImports() { return new globalThis._wizpContext.CodeActionKind('source.organizeImports'); }
            \\    static get SourceFixAll() { return new globalThis._wizpContext.CodeActionKind('source.fixAll'); }
            \\  },
            \\  CodeActionTriggerKind: { Invoke: 1, Automatic: 2 },
            \\  InlayHint: class { constructor(position, label, kind) { this.position = position; this.label = label; this.kind = kind; } },
            \\  InlayHintKind: { Type: 1, Parameter: 2 },
            \\  SemanticTokensLegend: class { constructor(tokenTypes, tokenModifiers) { this.tokenTypes = tokenTypes || []; this.tokenModifiers = tokenModifiers || []; } },
            \\  SemanticTokens: class { constructor(data, resultId) { this.data = data instanceof Uint32Array ? data : new Uint32Array(data || []); this.resultId = resultId; } },
            \\  SemanticTokensBuilder: class {
            \\    constructor(legend) { this.legend = legend; this._data = []; this._lastLine = 0; this._lastChar = 0; }
            \\    push(line, char, length, tokenType, tokenModifiers) {
            \\      const deltaLine = line - this._lastLine;
            \\      const deltaStart = deltaLine === 0 ? char - this._lastChar : char;
            \\      this._data.push(deltaLine, deltaStart, length, tokenType || 0, tokenModifiers || 0);
            \\      this._lastLine = line;
            \\      this._lastChar = char;
            \\    }
            \\    build(resultId) { return new globalThis._wizpContext.SemanticTokens(new Uint32Array(this._data), resultId); }
            \\  },
            \\  FoldingRange: class { constructor(start, end, kind) { this.start = start; this.end = end; this.kind = kind; } },
            \\  FoldingRangeKind: { Comment: "comment", Imports: "imports", Region: "region" },
            \\  TextEdit: class {
            \\    constructor(range, newText) { this.range = range; this.newText = newText; }
            \\    static replace(range, newText) { return new globalThis._wizpContext.TextEdit(range, newText); }
            \\    static insert(position, newText) { return new globalThis._wizpContext.TextEdit(new globalThis._wizpContext.Range(position, position), newText); }
            \\    static delete(range) { return new globalThis._wizpContext.TextEdit(range, ''); }
            \\  },
            \\  WorkspaceEdit: class {
            \\    constructor() { this._entries = []; }
            \\    replace(uri, range, newText) { this._addEdit(uri, { range: range, newText: newText }); }
            \\    insert(uri, position, newText) { this._addEdit(uri, { range: new globalThis._wizpContext.Range(position, position), newText: newText }); }
            \\    delete(uri, range) { this._addEdit(uri, { range: range, newText: '' }); }
            \\    set(uri, edits) {
            \\      const key = uri && uri.toString ? uri.toString() : String(uri || '');
            \\      this._entries = this._entries.filter(e => e.kind !== 'edit' || !e.uri || e.uri.toString() !== key);
            \\      this._entries.push({ kind: 'edit', uri: uri, edits: edits || [] });
            \\    }
            \\    createFile(uri, options) { this._entries.push({ kind: 'create', uri: uri, options: options || {} }); }
            \\    deleteFile(uri, options) { this._entries.push({ kind: 'delete', uri: uri, options: options || {} }); }
            \\    renameFile(oldUri, newUri, options) { this._entries.push({ kind: 'rename', oldUri: oldUri, newUri: newUri, options: options || {} }); }
            \\    entries() {
            \\      return this._entries
            \\        .filter(e => e.kind === 'edit' && e.uri)
            \\        .map(e => [e.uri, e.edits || []]);
            \\    }
            \\    get(uri) {
            \\      const key = uri && uri.toString ? uri.toString() : String(uri || '');
            \\      const entry = this._entries.find(e => e.kind === 'edit' && e.uri && e.uri.toString() === key);
            \\      return entry ? (entry.edits || []) : undefined;
            \\    }
            \\    has(uri) {
            \\      const key = uri && uri.toString ? uri.toString() : String(uri || '');
            \\      return this._entries.some(e => e.kind === 'edit' && e.uri && e.uri.toString() === key);
            \\    }
            \\    clear() { this._entries = []; }
            \\    get size() { return this.entries().length; }
            \\    [Symbol.iterator]() { return this.entries()[Symbol.iterator](); }
            \\    toJSON() {
            \\      const changes = {};
            \\      for (const entry of this.entries()) {
            \\        const key = entry[0] && entry[0].toString ? entry[0].toString() : String(entry[0] || '');
            \\        changes[key] = (entry[1] || []).map(function(edit) { return { range: edit.range, newText: edit.newText || '' }; });
            \\      }
            \\      return { changes: changes };
            \\    }
            \\    _addEdit(uri, edit) {
            \\      let entry = this._entries.find(e => e.kind === 'edit' && e.uri && uri && e.uri.toString() === uri.toString());
            \\      if (!entry) { entry = { kind: 'edit', uri: uri, edits: [] }; this._entries.push(entry); }
            \\      entry.edits.push(edit);
            \\    }
            \\  },
            \\  Location: class { constructor(u, r) { this.uri = u; this.range = r; } toJSON() { return { uri: this.uri && this.uri.toString ? this.uri.toString() : String(this.uri || ''), range: this.range }; } },
            \\  SelectionRange: class { constructor(range, parent) { this.range = range; this.parent = parent; } },
            \\  LocationLink: class { constructor(targetUri, targetRange, targetSelectionRange, originSelectionRange) { this.targetUri = targetUri; this.targetRange = targetRange; this.targetSelectionRange = targetSelectionRange; this.originSelectionRange = originSelectionRange; } },
            \\  Diagnostic: class { constructor(range, message, severity) { this.range = range; this.message = message; this.severity = severity === undefined ? 0 : severity; this.source = undefined; this.code = undefined; this.relatedInformation = undefined; this.tags = undefined; } },
            \\  DiagnosticRelatedInformation: class { constructor(location, message) { this.location = location; this.message = message; } },
            \\  DiagnosticTag: { Unnecessary: 1, Deprecated: 2 },
            \\  Hover: class { constructor(contents, range) { this.contents = Array.isArray(contents) ? contents : [contents]; this.range = range; } },
            \\  DocumentHighlight: class { constructor(range, kind) { this.range = range; this.kind = kind === undefined ? 0 : kind; } },
            \\  DocumentHighlightKind: { Text: 0, Read: 1, Write: 2 },
            \\  ParameterInformation: class { constructor(label, documentation) { this.label = label; this.documentation = documentation; } },
            \\  SignatureInformation: class { constructor(label, documentation) { this.label = label; this.documentation = documentation; this.parameters = []; this.activeParameter = undefined; } },
            \\  SignatureHelp: class { constructor() { this.signatures = []; this.activeSignature = 0; this.activeParameter = 0; } },
            \\  SignatureHelpTriggerKind: { Invoke: 1, TriggerCharacter: 2, ContentChange: 3 },
            \\  SymbolInformation: class { constructor(name, kind, containerName, location) { this.name = name; this.kind = kind; this.containerName = containerName; this.location = location; } },
            \\  DocumentSymbol: class { constructor(name, detail, kind, range, selectionRange) { this.name = name; this.detail = detail; this.kind = kind; this.range = range; this.selectionRange = selectionRange; this.children = []; } },
            \\  CallHierarchyItem: class { constructor(kind, name, detail, uri, range, selectionRange) { this.kind = kind; this.name = name; this.detail = detail; this.uri = uri; this.range = range; this.selectionRange = selectionRange; } },
            \\  CallHierarchyIncomingCall: class { constructor(from, fromRanges) { this.from = from; this.fromRanges = Array.isArray(fromRanges) ? fromRanges : []; } },
            \\  CallHierarchyOutgoingCall: class { constructor(to, fromRanges) { this.to = to; this.fromRanges = Array.isArray(fromRanges) ? fromRanges : []; } },
            \\  TypeHierarchyItem: class { constructor(kind, name, detail, uri, range, selectionRange) { this.kind = kind; this.name = name; this.detail = detail; this.uri = uri; this.range = range; this.selectionRange = selectionRange; } },
            \\  SymbolKind: { File: 0, Module: 1, Namespace: 2, Package: 3, Class: 4, Method: 5, Property: 6, Field: 7, Constructor: 8, Enum: 9, Interface: 10, Function: 11, Variable: 12, Constant: 13, String: 14, Number: 15, Boolean: 16, Array: 17, Object: 18, Key: 19, Null: 20, EnumMember: 21, Struct: 22, Event: 23, Operator: 24, TypeParameter: 25 },
            \\  DiagnosticSeverity: { Error: 0, Warning: 1, Information: 2, Hint: 3 },
            \\  ProgressLocation: { SourceControl: 1, Window: 10, Notification: 15 },
            \\  StatusBarAlignment: { Left: 1, Right: 2 },
            \\  ExtensionMode: { Production: 1, Development: 2, Test: 3 },
            \\  ExtensionKind: { UI: 1, Workspace: 2 },
            \\  LogLevel: { Trace: 1, Debug: 2, Info: 3, Warning: 4, Error: 5, Off: 6 },
            \\  UIKind: { Desktop: 1, Web: 2 },
            \\  scm: {
            \\    createSourceControl: function(id, label, rootUri) {
            \\      const scmId = "scm_" + (++globalThis._wizp_disposableId);
            \\      globalThis._wizp_uiQueue.push({type: "scmRegistered", id: scmId, label: label, rootUri: rootUri ? rootUri.fsPath : null});
            \\      return {
            \\        id: scmId,
            \\        label: label,
            \\        rootUri: rootUri,
            \\        createResourceGroup: function(groupId, groupLabel) {
            \\          const rgId = scmId + "_" + groupId;
            \\          const group = {
            \\            id: rgId, label: groupLabel, resourceStates: [],
            \\            dispose: function() {}
            \\          };
            \\          return new Proxy(group, {
            \\            set: function(obj, prop, value) {
            \\              obj[prop] = value;
            \\              if (prop === 'resourceStates') {
            \\                globalThis._wizp_uiQueue.push({type: "scmUpdate", scmId: scmId, groupId: rgId, resourceStates: value.map(r => ({ resourceUri: r.resourceUri.fsPath }))});
            \\              }
            \\              return true;
            \\            }
            \\          });
            \\        },
            \\        dispose: function() {}
            \\      };
            \\    }
            \\  },
            \\  tasks: {
            \\    registerTaskProvider: function(type, provider) {
            \\      globalThis._wizp_taskProviders = globalThis._wizp_taskProviders || {};
            \\      globalThis._wizp_taskProviders[type] = provider;
            \\      return { dispose: function() { delete globalThis._wizp_taskProviders[type]; } };
            \\    },
            \\    executeTask: function(task) {
            \\      globalThis._wizp_uiQueue.push({type: "taskExecute", task: task});
            \\      const renderArg = function(arg) {
            \\        if (arg && typeof arg === 'object' && Object.prototype.hasOwnProperty.call(arg, 'value')) return String(arg.value || '');
            \\        return String(arg === undefined || arg === null ? '' : arg);
            \\      };
            \\      const renderCommand = function(command, args) {
            \\        return [String(command || '')].concat((args || []).map(renderArg)).filter(function(item) { return item.length > 0; }).join(' ');
            \\      };
            \\      const normalizeCwd = function(cwd) {
            \\        if (!cwd) return undefined;
            \\        if (typeof cwd === 'string') return cwd;
            \\        if (cwd.fsPath) return String(cwd.fsPath);
            \\        if (cwd.path) return String(cwd.path);
            \\        return String(cwd);
            \\      };
            \\      const executionSpec = function(task) {
            \\        const raw = task && task.execution ? task.execution : null;
            \\        if (!raw) return null;
            \\        const options = raw.options && typeof raw.options === 'object' ? raw.options : {};
            \\        if (raw.process) return { command: String(raw.process || ''), args: Array.isArray(raw.args) ? raw.args.map(renderArg) : [], options: options };
            \\        if (raw.commandLine) return { command: String(raw.commandLine || ''), args: Array.isArray(raw.args) ? raw.args.map(renderArg) : [], options: options };
            \\        return null;
            \\      };
            \\      const execution = {
            \\        task: task,
            \\        terminal: globalThis._wizpActiveTerminal || null,
            \\        dispose: function() {
            \\          globalThis._wizpTaskExecutions = (globalThis._wizpTaskExecutions || []).filter(function(item) { return item !== execution; });
            \\        }
            \\      };
            \\      globalThis._wizpTaskExecutions = globalThis._wizpTaskExecutions || [];
            \\      globalThis._wizpTaskExecutions.push(execution);
            \\      const spec = executionSpec(task);
            \\      if (spec && spec.command) {
            \\        const terminalName = String((task && task.name) || 'Task');
            \\        const outputName = String((task && task.source) || 'Task');
            \\        const commandLine = renderCommand(spec.command, spec.args);
            \\        const terminal = globalThis._wizpContext.window.createTerminal({ name: terminalName });
            \\        const output = globalThis._wizpContext.window.createOutputChannel(outputName);
            \\        execution.terminal = terminal;
            \\        terminal.show(true);
            \\        terminal.sendText(commandLine, true);
            \\        output.show(true);
            \\        output.appendLine("$ " + commandLine);
            \\        const spawnOptions = {};
            \\        const cwd = normalizeCwd(spec.options.cwd);
            \\        if (cwd) spawnOptions.cwd = cwd;
            \\        if (spec.options.env && typeof spec.options.env === 'object') {
            \\          spawnOptions.env = Object.assign({}, globalThis._wizpProcessEnv || {}, spec.options.env);
            \\        }
            \\        try {
            \\          const proc = globalThis._wizpNodeChildProcess && globalThis._wizpNodeChildProcess.spawn
            \\            ? globalThis._wizpNodeChildProcess.spawn(spec.command, spec.args, spawnOptions)
            \\            : null;
            \\          execution.process = proc || null;
            \\          const appendData = function(prefix, chunk) {
            \\            const text = chunk && chunk.toString ? chunk.toString('utf8') : String(chunk || '');
            \\            if (!text) return;
            \\            globalThis._wizp_uiQueue.push({type: 'terminal', action: 'output', id: terminal.id, name: terminal.name, text: text});
            \\            globalThis._wizpEmitTerminalData(terminal, text);
            \\            output.append(text);
            \\          };
            \\          if (proc && proc.stdout && typeof proc.stdout.on === 'function') proc.stdout.on('data', function(chunk) { appendData('stdout', chunk); });
            \\          if (proc && proc.stderr && typeof proc.stderr.on === 'function') proc.stderr.on('data', function(chunk) { appendData('stderr', chunk); });
            \\          if (proc && typeof proc.on === 'function') {
            \\            proc.on('error', function(error) {
            \\              const text = error && error.message ? String(error.message) : String(error || 'task process error');
            \\              output.appendLine(text);
            \\              globalThis._wizp_uiQueue.push({type: 'terminal', action: 'output', id: terminal.id, name: terminal.name, text: text + '\n'});
            \\            });
            \\            proc.on('exit', function(code, signal) {
            \\              execution.exitCode = code === undefined || code === null ? null : Number(code);
            \\              execution.signal = signal ? String(signal) : '';
            \\              terminal.exitStatus = { code: execution.exitCode || 0, reason: 3 };
            \\              output.appendLine("[exit " + String(execution.exitCode === null ? signal || 0 : execution.exitCode) + "]");
            \\            });
            \\          }
            \\        } catch (error) {
            \\          const text = error && error.message ? String(error.message) : String(error || 'task execution failed');
            \\          output.appendLine(text);
            \\          globalThis._wizp_uiQueue.push({type: 'terminal', action: 'output', id: terminal.id, name: terminal.name, text: text + '\n'});
            \\        }
            \\      }
            \\      return Promise.resolve(execution);
            \\    },
            \\    fetchTasks: function(filter) {
            \\      let promises = [];
            \\      if (globalThis._wizp_taskProviders) {
            \\        for (const type in globalThis._wizp_taskProviders) {
            \\           if (!filter || filter.type === type) {
            \\             promises.push(Promise.resolve(globalThis._wizp_taskProviders[type].provideTasks()));
            \\           }
            \\        }
            \\      }
            \\      return Promise.all(promises).then(arrs => arrs.flat());
            \\    },
            \\    get taskExecutions() { return (globalThis._wizpTaskExecutions || []).slice(); }
            \\  },
            \\  Task: class { constructor(def, scope, name, source, exec) { this.definition = def; this.scope = scope; this.name = name; this.source = source; this.execution = exec; } },
            \\  ShellExecution: class { constructor(commandLine, argsOrOptions, options) { this.commandLine = commandLine; this.args = Array.isArray(argsOrOptions) ? argsOrOptions : []; this.options = Array.isArray(argsOrOptions) ? (options || {}) : (argsOrOptions || {}); } },
            \\  ProcessExecution: class { constructor(process, argsOrOptions, options) { this.process = process; this.args = Array.isArray(argsOrOptions) ? argsOrOptions : []; this.options = Array.isArray(argsOrOptions) ? (options || {}) : (argsOrOptions || {}); } },
            \\  TaskScope: { Global: 1, Workspace: 2 },
            \\  TaskGroup: { Build: { id: 'build', isDefault: false }, Clean: { id: 'clean', isDefault: false }, Rebuild: { id: 'rebuild', isDefault: false }, Test: { id: 'test', isDefault: false } },
            \\  ShellQuoting: { Escape: 1, Strong: 2, Weak: 3 },
            \\  TaskRevealKind: { Always: 1, Silent: 2, Never: 3 },
            \\  TaskPanelKind: { Shared: 1, Dedicated: 2, New: 3 },
            \\  NotebookCellKind: { Markup: 1, Code: 2 },
            \\  NotebookCellOutputItem: class {
            \\    constructor(data, mime) {
            \\      this.data = data instanceof Uint8Array ? data : new TextEncoder().encode(String(data === undefined || data === null ? '' : data));
            \\      this.mime = mime || 'text/plain';
            \\    }
            \\    static text(value, mime) { return new globalThis._wizpContext.NotebookCellOutputItem(value, mime || 'text/plain'); }
            \\    static stdout(value) { return new globalThis._wizpContext.NotebookCellOutputItem(value, 'application/vnd.code.notebook.stdout'); }
            \\    static stderr(value) { return new globalThis._wizpContext.NotebookCellOutputItem(value, 'application/vnd.code.notebook.stderr'); }
            \\    static error(value) {
            \\      const error = value || {};
            \\      return new globalThis._wizpContext.NotebookCellOutputItem(JSON.stringify({
            \\        name: String(error.name || 'Error'),
            \\        message: String(error.message || error || ''),
            \\        stack: error.stack ? String(error.stack) : undefined
            \\      }), 'application/vnd.code.notebook.error');
            \\    }
            \\  },
            \\  NotebookCellOutput: class {
            \\    constructor(items, metadata) { this.items = Array.isArray(items) ? items : []; this.metadata = metadata; }
            \\  },
            \\  NotebookCellData: class {
            \\    constructor(kind, value, languageId) { this.kind = kind; this.value = String(value || ''); this.languageId = String(languageId || 'plaintext'); this.outputs = []; this.metadata = undefined; this.executionSummary = undefined; }
            \\  },
            \\  NotebookData: class {
            \\    constructor(cells) { this.cells = Array.isArray(cells) ? cells : []; this.metadata = undefined; }
            \\  },
            \\  TestRunProfileKind: { Run: 1, Debug: 2, Coverage: 3 },
            \\  TestTag: class { constructor(id) { this.id = String(id || ''); } },
            \\  TelemetryTrustedValue: class { constructor(value) { this.value = value; } },
            \\  TestRunRequest: class { constructor(include, exclude, profile) { this.include = include; this.exclude = exclude; this.profile = profile; } },
            \\  TestMessage: class { constructor(msg) { this.message = msg; } },
            \\  TestCoverageCount: class { constructor(covered, total) { this.covered = covered || 0; this.total = total || 0; } },
            \\  FileCoverage: class { constructor(uri, statementCoverage, branchCoverage, declarationCoverage) { this.uri = uri; this.statementCoverage = statementCoverage; this.branchCoverage = branchCoverage; this.declarationCoverage = declarationCoverage; } },
            \\  StatementCoverage: class { constructor(executed, location) { this.executed = executed || 0; this.location = location; this.branches = []; } },
            \\  BranchCoverage: class { constructor(executed, location) { this.executed = executed || 0; this.location = location; } },
            \\  DeclarationCoverage: class { constructor(name, executed, location) { this.name = name; this.executed = executed || 0; this.location = location; } },
            \\  DebugConfigurationProviderTriggerKind: { Initial: 1, Dynamic: 2 },
            \\  tests: {
            \\    createTestController: function(id, label) {
            \\      const cId = "testCtrl_" + (++globalThis._wizp_disposableId);
            \\      globalThis._wizp_testControllers = globalThis._wizp_testControllers || {};
            \\      const controller = {
            \\        id: id,
            \\        label: label,
            \\        runProfiles: [],
            \\        results: [],
            \\        items: {
            \\          _items: [],
            \\          add: function(item) { this._items.push(item); },
            \\          delete: function(itemId) { this._items = this._items.filter(function(item) { return item.id !== itemId; }); },
            \\          clear: function() { this._items = []; },
            \\          get: function(itemId) { return this._items.find(function(item) { return item.id === itemId; }); },
            \\          forEach: function(fn) { this._items.forEach(fn); },
            \\          replace: function(items) { this._items = Array.isArray(items) ? items.slice() : []; }
            \\        },
            \\        createTestItem: function(itemId, itemLabel, uri) {
            \\          const children = {
            \\            _items: [],
            \\            add: function(item) { this._items.push(item); },
            \\            delete: function(childId) { this._items = this._items.filter(function(item) { return item.id !== childId; }); },
            \\            clear: function() { this._items = []; },
            \\            get: function(childId) { return this._items.find(function(item) { return item.id === childId; }); },
            \\            forEach: function(fn) { this._items.forEach(fn); },
            \\            replace: function(items) { this._items = Array.isArray(items) ? items.slice() : []; }
            \\          };
            \\          return { id: itemId, label: itemLabel, uri: uri, children: children, tags: [], canResolveChildren: false, busy: false, range: undefined };
            \\        },
            \\        createRunProfile: function(label, kind, handler, isDefault, tag) {
            \\          const profile = { label: label, kind: kind, handler: handler, isDefault: !!isDefault, tag: tag };
            \\          this.runProfiles.push(profile);
            \\          return { label: label, kind: kind, isDefault: !!isDefault, dispose: function() {} };
            \\        },
            \\        createTestRun: function(req, name, persist) {
            \\           globalThis._wizp_uiQueue.push({type: "testRunStarted", controllerId: id, name: name});
            \\           const run = { name: name, persist: !!persist, results: [], output: [] };
            \\           controller.results.push(run);
            \\           return {
            \\             enqueued: function(t) { run.results.push({id: t.id, state: "enqueued"}); },
            \\             started: function(t) { run.results.push({id: t.id, state: "started"}); },
            \\             appendOutput: function(output) { run.output.push(String(output)); },
            \\             passed: function(t, duration) { run.results.push({id: t.id, state: "passed", duration: duration || 0}); globalThis._wizp_uiQueue.push({type: "testRunPassed", test: t.id}); },
            \\             failed: function(t, msg, duration) { run.results.push({id: t.id, state: "failed", message: msg.message || String(msg || "failed"), duration: duration || 0}); globalThis._wizp_uiQueue.push({type: "testRunFailed", test: t.id, message: msg.message || "failed"}); },
            \\             end: function() { run.ended = true; globalThis._wizp_uiQueue.push({type: "testRunEnded", controllerId: id}); }
            \\           };
            \\        },
            \\        dispose: function() { delete globalThis._wizp_testControllers[id]; }
            \\      };
            \\      globalThis._wizp_testControllers[id] = controller;
            \\      return controller;
            \\    }
            \\  },
            \\  debug: {
            \\    registerDebugAdapterDescriptorFactory: function(type, factory) {
            \\       globalThis._wizp_debugFactories = globalThis._wizp_debugFactories || {};
            \\       globalThis._wizp_debugAdapterDescriptorFactoryRegistrations = globalThis._wizp_debugAdapterDescriptorFactoryRegistrations || [];
            \\       const registrationId = "debugAdapterDescriptorFactory_" + (++globalThis._wizp_disposableId);
            \\       globalThis._wizp_debugAdapterDescriptorFactoryRegistrations.push({ id: registrationId, type: type, factory: factory });
            \\       globalThis._wizp_debugFactories[type] = factory;
            \\       return { dispose: function() { delete globalThis._wizp_debugFactories[type]; globalThis._wizp_debugAdapterDescriptorFactoryRegistrations = (globalThis._wizp_debugAdapterDescriptorFactoryRegistrations || []).filter(function(entry) { return entry.id !== registrationId; }); } };
            \\    },
            \\    registerDebugConfigurationProvider: function(type, provider, triggerKind) {
            \\       globalThis._wizp_debugConfigurationProviders = globalThis._wizp_debugConfigurationProviders || {};
            \\       globalThis._wizp_debugConfigurationProviderRegistrations = globalThis._wizp_debugConfigurationProviderRegistrations || [];
            \\       const registrationId = "debugConfigurationProvider_" + (++globalThis._wizp_disposableId);
            \\       globalThis._wizp_debugConfigurationProviderRegistrations.push({ id: registrationId, type: type, triggerKind: triggerKind === undefined ? null : triggerKind, provider: provider });
            \\       globalThis._wizp_debugConfigurationProviders[type] = { provider: provider, triggerKind: triggerKind };
            \\       return { dispose: function() { delete globalThis._wizp_debugConfigurationProviders[type]; globalThis._wizp_debugConfigurationProviderRegistrations = (globalThis._wizp_debugConfigurationProviderRegistrations || []).filter(function(entry) { return entry.id !== registrationId; }); } };
            \\    },
            \\    registerDebugAdapterTrackerFactory: function(type, factory) {
            \\       globalThis._wizp_debugTrackerFactories = globalThis._wizp_debugTrackerFactories || {};
            \\       globalThis._wizp_debugAdapterTrackerFactoryRegistrations = globalThis._wizp_debugAdapterTrackerFactoryRegistrations || [];
            \\       const registrationId = "debugAdapterTrackerFactory_" + (++globalThis._wizp_disposableId);
            \\       globalThis._wizp_debugAdapterTrackerFactoryRegistrations.push({ id: registrationId, type: type, factory: factory });
            \\       globalThis._wizp_debugTrackerFactories[type] = factory;
            \\       globalThis._wizp_uiQueue.push({type: "debugAdapterTrackerFactoryRegistered", debugType: type});
            \\       return { dispose: function() { delete globalThis._wizp_debugTrackerFactories[type]; globalThis._wizp_debugAdapterTrackerFactoryRegistrations = (globalThis._wizp_debugAdapterTrackerFactoryRegistrations || []).filter(function(entry) { return entry.id !== registrationId; }); } };
            \\    },
            \\    registerDebugVisualizationTreeProvider: function(id, provider) {
            \\       const providerId = String(id || 'default');
            \\       globalThis._wizp_debugVisualizationTreeProviders = globalThis._wizp_debugVisualizationTreeProviders || {};
            \\       globalThis._wizp_debugVisualizationTreeProviders[providerId] = provider;
            \\       globalThis._wizp_uiQueue.push({type: "debugVisualizationTreeProviderRegistered", id: providerId});
            \\       return { dispose: function() { delete globalThis._wizp_debugVisualizationTreeProviders[providerId]; } };
            \\    },
            \\    registerDebugVisualizationProvider: function(id, provider) {
            \\       const providerId = String(id || 'default');
            \\       globalThis._wizp_debugVisualizationProviders = globalThis._wizp_debugVisualizationProviders || {};
            \\       globalThis._wizp_debugVisualizationProviders[providerId] = provider;
            \\       globalThis._wizp_uiQueue.push({type: "debugVisualizationProviderRegistered", id: providerId});
            \\       return { dispose: function() { delete globalThis._wizp_debugVisualizationProviders[providerId]; } };
            \\    },
            \\    startDebugging: function(folder, nameOrConfiguration, parentSessionOrOptions) {
            \\       globalThis._wizp_uiQueue.push({type: "debugStarted", config: nameOrConfiguration});
            \\       return Promise.resolve(true);
            \\    },
            \\    onDidStartDebugSession: function(callback, thisArg) {
            \\       globalThis._wizpDebugSessionListeners = globalThis._wizpDebugSessionListeners || { start: [], terminate: [], custom: [] };
            \\       const wrapped = function(event) { return callback.call(thisArg, event); };
            \\       globalThis._wizpDebugSessionListeners.start.push(wrapped);
            \\       return { dispose: function() { const list = globalThis._wizpDebugSessionListeners.start; const index = list.indexOf(wrapped); if (index >= 0) list.splice(index, 1); } };
            \\    },
            \\    onDidTerminateDebugSession: function(callback, thisArg) {
            \\       globalThis._wizpDebugSessionListeners = globalThis._wizpDebugSessionListeners || { start: [], terminate: [], custom: [] };
            \\       const wrapped = function(event) { return callback.call(thisArg, event); };
            \\       globalThis._wizpDebugSessionListeners.terminate.push(wrapped);
            \\       return { dispose: function() { const list = globalThis._wizpDebugSessionListeners.terminate; const index = list.indexOf(wrapped); if (index >= 0) list.splice(index, 1); } };
            \\    },
            \\    onDidReceiveDebugSessionCustomEvent: function(callback, thisArg) {
            \\       globalThis._wizpDebugSessionListeners = globalThis._wizpDebugSessionListeners || { start: [], terminate: [], custom: [] };
            \\       const wrapped = function(event) { return callback.call(thisArg, event); };
            \\       globalThis._wizpDebugSessionListeners.custom.push(wrapped);
            \\       return { dispose: function() { const list = globalThis._wizpDebugSessionListeners.custom; const index = list.indexOf(wrapped); if (index >= 0) list.splice(index, 1); } };
            \\    },
            \\    onDidChangeBreakpoints: function(callback, thisArg) {
            \\       globalThis._wizpBreakpointListeners = globalThis._wizpBreakpointListeners || [];
            \\       const wrapped = function(event) { return callback.call(thisArg, event); };
            \\       globalThis._wizpBreakpointListeners.push(wrapped);
            \\       return { dispose: function() { const list = globalThis._wizpBreakpointListeners; const index = list.indexOf(wrapped); if (index >= 0) list.splice(index, 1); } };
            \\    },
            \\    breakpoints: [],
            \\    activeDebugSession: null,
            \\    activeDebugConsole: { append: function() {}, appendLine: function() {} }
            \\  },
            \\  comments: {
            \\    createCommentController: function(id, label) {
            \\      return {
            \\        id: id,
            \\        label: label,
            \\        createCommentThread: function(uri, range, comments) {
            \\           const threadId = ++globalThis._wizp_disposableId;
            \\           const thread = { uri: uri, range: range, comments: Array.isArray(comments) ? comments.slice() : [] };
            \\           const reply = new Promise(function(resolve) {
            \\             globalThis._wizp_uiResolvers[threadId] = resolve;
            \\           });
            \\           globalThis._wizp_uiQueue.push({type: "commentThreadCreated", id: threadId, uri: uri.fsPath, line: range.start.line, comments: thread.comments});
            \\           thread.reply = reply;
            \\           thread.dispose = function() { delete globalThis._wizp_uiResolvers[threadId]; };
            \\           return thread;
            \\        },
            \\        dispose: function() {}
            \\      };
            \\    }
            \\  },
            \\  notebooks: {
            \\    createNotebookController: function(id, viewType, label, handler) {
            \\      globalThis._wizp_notebookControllers = globalThis._wizp_notebookControllers || {};
            \\      const controller = {
            \\        id: id,
            \\        viewType: viewType,
            \\        label: label,
            \\        supportedLanguages: [],
            \\        executeHandler: handler || (async function() {}),
            \\        dispose: function() { delete globalThis._wizp_notebookControllers[id]; }
            \\      };
            \\      globalThis._wizp_notebookControllers[id] = controller;
            \\      return controller;
            \\    }
            \\  },
            \\  authentication: {
            \\    registerAuthenticationProvider: function(id, label, provider, options) {
            \\      globalThis._wizp_authProviders = globalThis._wizp_authProviders || {};
            \\      globalThis._wizp_authProviders[id] = { label: label, provider: provider, options: options || {} };
            \\      return { dispose: function() { delete globalThis._wizp_authProviders[id]; } };
            \\    },
            \\    getSession: async function(providerId, scopes, options) {
            \\      globalThis._wizp_uiQueue.push({type: "authenticationRequest", provider: providerId, scopes: scopes});
            \\      const entry = globalThis._wizp_authProviders && globalThis._wizp_authProviders[providerId];
            \\      if (entry && entry.provider) {
            \\        const sessions = await Promise.resolve(entry.provider.getSessions ? entry.provider.getSessions(scopes, options || {}) : []);
            \\        if (sessions && sessions.length) return sessions[0];
            \\        if (options && options.createIfNone && entry.provider.createSession) return await Promise.resolve(entry.provider.createSession(scopes, options || {}));
            \\      }
            \\      return undefined;
            \\    },
            \\    onDidChangeSessions: function(callback, thisArg, disposables) {
            \\      const disposable = { dispose: function() {} };
            \\      if (Array.isArray(disposables)) disposables.push(disposable);
            \\      return disposable;
            \\    }
            \\  },
            \\  chat: {
            \\    createChatParticipant: function(id, handler) {
            \\      const cpId = "chat_" + (++globalThis._wizp_disposableId);
            \\      globalThis._wizp_uiQueue.push({type: "chatParticipantRegistered", id: cpId, name: id});
            \\      return {
            \\        dispose: function() {}
            \\      };
            \\    }
            \\  },
            \\  lm: {
            \\    registerTool: function(nameOrDefinition, tool) {
            \\      globalThis._wizpLmTools = globalThis._wizpLmTools || {};
            \\      const name = typeof nameOrDefinition === 'string' ? nameOrDefinition : (nameOrDefinition && (nameOrDefinition.name || nameOrDefinition.toolReferenceName)) || ('tool_' + (++globalThis._wizp_disposableId));
            \\      globalThis._wizpLmTools[name] = { definition: nameOrDefinition, tool: tool || nameOrDefinition };
            \\      globalThis._wizp_uiQueue.push({type: "lmToolRegistered", name: name});
            \\      return { dispose: function() { delete globalThis._wizpLmTools[name]; } };
            \\    },
            \\    selectChatModels: function(selector) {
            \\      return Promise.resolve([]);
            \\    }
            \\  },
            \\  l10n: {
            \\    t: function(message) {
            \\      return message;
            \\    }
            \\  },
            \\  languages: {
            \\    IndentAction: { None: 0, Indent: 1, IndentOutdent: 2, Outdent: 3 },
            \\    getLanguages: function() { return Promise.resolve(['plaintext', 'javascript', 'typescript', 'json', 'markdown', 'html', 'css', 'python', 'php', 'zig', 'shellscript', 'c', 'cpp', 'java', 'go', 'yaml', 'dockerfile', 'makefile']); },
            \\    setLanguageConfiguration: function(language, configuration) {
            \\      globalThis._wizpLanguageConfigurations = globalThis._wizpLanguageConfigurations || {};
            \\      globalThis._wizpLanguageConfigurations[String(language || '')] = configuration || {};
            \\      globalThis._wizp_uiQueue.push({type: 'languageConfigurationRegistered', language: String(language || '')});
            \\      return { dispose: function() { delete globalThis._wizpLanguageConfigurations[String(language || '')]; } };
            \\    },
            \\    match: function(selector, document) {
            \\      if (!selector) return 0;
            \\      if (Array.isArray(selector)) return selector.reduce(function(best, item) { return Math.max(best, globalThis._wizpContext.languages.match(item, document)); }, 0);
            \\      if (typeof selector === 'string') return selector === '*' || selector === (document && document.languageId) ? 10 : 0;
            \\      const docLanguage = (document && document.languageId) || '';
            \\      const docScheme = (document && document.uri && document.uri.scheme) || '';
            \\      const docPath = String((document && (document.fileName || (document.uri && (document.uri.fsPath || document.uri.path || document.uri.toString())))) || '').replace(/\\/g, '/');
            \\      let score = 0;
            \\      if (selector.language) {
            \\        if (selector.language !== '*' && selector.language !== docLanguage) return 0;
            \\        score += selector.language === docLanguage ? 10 : 1;
            \\      }
            \\      if (selector.scheme) {
            \\        if (selector.scheme !== '*' && selector.scheme !== docScheme) return 0;
            \\        score += selector.scheme === docScheme ? 10 : 1;
            \\      }
            \\      if (selector.pattern) {
            \\        const pattern = String(selector.pattern || '').replace(/\\/g, '/');
            \\        const suffix = pattern.startsWith('**/') ? pattern.slice(3) : pattern;
            \\        if (suffix && suffix.indexOf('*') < 0 && docPath !== suffix && !docPath.endsWith('/' + suffix)) return 0;
            \\        score += 5;
            \\      }
            \\      return score || 1;
            \\    },
            \\    createLanguageStatusItem: function(id, selector) {
            \\      const item = {
            \\        id: id,
            \\        selector: selector,
            \\        name: '',
            \\        text: '',
            \\        detail: '',
            \\        severity: 0,
            \\        command: undefined,
            \\        busy: false,
            \\        accessibilityInformation: undefined,
            \\        dispose: function() { globalThis._wizp_uiQueue.push({type: 'languageStatusDisposed', id: id}); }
            \\      };
            \\      globalThis._wizpLanguageStatusItems = globalThis._wizpLanguageStatusItems || {};
            \\      globalThis._wizpLanguageStatusItems[id] = item;
            \\      globalThis._wizp_uiQueue.push({type: 'languageStatusCreated', id: id});
            \\      return item;
            \\    },
            \\    createDiagnosticCollection: function(name) {
            \\      const id = "diag_" + (++globalThis._wizp_disposableId);
            \\      const collection = {
            \\        id: id,
            \\        name: name,
            \\        entries: {},
            \\        disposed: false,
            \\        _uriKey: function(uri) { return uri && (uri.fsPath || uri.path) ? (uri.fsPath || uri.path) : String(uri); },
            \\        _mapDiagnostic: function(d) {
            \\          const range = d.range || {};
            \\          const start = range.start || (Array.isArray(range) ? range[0] : { line: 0, character: 0 });
            \\          const end = range.end || (Array.isArray(range) ? range[1] : start);
            \\          return {
            \\            message: String(d.message || ''),
            \\            severity: d.severity === undefined ? 0 : d.severity,
            \\            source: d.source || name,
            \\            code: d.code,
            \\            range: [{ line: start.line || 0, character: start.character || 0 }, { line: end.line || start.line || 0, character: end.character || start.character || 0 }],
            \\            startLineNumber: (start.line || 0) + 1,
            \\            startColumn: (start.character || 0) + 1,
            \\            endLineNumber: (end.line || start.line || 0) + 1,
            \\            endColumn: (end.character || start.character || 0) + 1
            \\          };
            \\        },
            \\        _publish: function(uriKey) {
            \\          globalThis._wizp_uiQueue.push({type: "setDiagnostics", uri: uriKey, diagnostics: collection.entries[uriKey] || []});
            \\        },
            \\        set: function(uriOrEntries, diags) {
            \\          if (collection.disposed) return;
            \\          if (Array.isArray(uriOrEntries) && diags === undefined) {
            \\            for (const entry of uriOrEntries) {
            \\              const uri = Array.isArray(entry) ? entry[0] : entry.uri;
            \\              const values = Array.isArray(entry) ? entry[1] : entry.diagnostics;
            \\              collection.set(uri, values || []);
            \\            }
            \\            return;
            \\          }
            \\          const uriKey = collection._uriKey(uriOrEntries);
            \\          collection.entries[uriKey] = (diags || []).map(collection._mapDiagnostic);
            \\          collection._publish(uriKey);
            \\        },
            \\        delete: function(uri) {
            \\          if (collection.disposed) return;
            \\          const uriKey = collection._uriKey(uri);
            \\          delete collection.entries[uriKey];
            \\          globalThis._wizp_uiQueue.push({type: "setDiagnostics", uri: uriKey, diagnostics: []});
            \\        },
            \\        clear: function() {
            \\          if (collection.disposed) return;
            \\          const keys = Object.keys(collection.entries);
            \\          collection.entries = {};
            \\          for (const key of keys) globalThis._wizp_uiQueue.push({type: "setDiagnostics", uri: key, diagnostics: []});
            \\        },
            \\        forEach: function(callback, thisArg) {
            \\          for (const key of Object.keys(collection.entries)) callback.call(thisArg, globalThis._wizpContext.Uri.file(key), collection.entries[key], collection);
            \\        },
            \\        dispose: function() {
            \\          if (collection.disposed) return;
            \\          collection.clear();
            \\          collection.disposed = true;
            \\          delete globalThis._wizpDiagnosticCollections[id];
            \\        }
            \\      };
            \\      globalThis._wizpDiagnosticCollections[id] = collection;
            \\      return collection;
            \\    },
            \\    registerHoverProvider: function(selector, provider) {
            \\      const id = "hover_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpHoverProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'hover', id);
            \\      globalThis._wizp_hoverProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpHoverProviders = globalThis._wizpHoverProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_hoverProvider === provider) globalThis._wizp_hoverProvider = globalThis._wizpHoverProviders.length ? globalThis._wizpHoverProviders[globalThis._wizpHoverProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerCompletionItemProvider: function(selector, provider) {
            \\      const id = "completion_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider, triggerCharacters: Array.prototype.slice.call(arguments, 2) };
            \\      globalThis._wizpCompletionProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'completion', id);
            \\      globalThis._wizp_completionProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpCompletionProviders = globalThis._wizpCompletionProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_completionProvider === provider) globalThis._wizp_completionProvider = globalThis._wizpCompletionProviders.length ? globalThis._wizpCompletionProviders[globalThis._wizpCompletionProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerInlineCompletionItemProvider: function(selector, provider) {
            \\      const id = "inlineCompletion_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpInlineCompletionProviders.push(entry);
            \\      globalThis._wizp_inlineCompletionProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpInlineCompletionProviders = globalThis._wizpInlineCompletionProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_inlineCompletionProvider === provider) globalThis._wizp_inlineCompletionProvider = globalThis._wizpInlineCompletionProviders.length ? globalThis._wizpInlineCompletionProviders[globalThis._wizpInlineCompletionProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerColorProvider: function(selector, provider) {
            \\      const id = "color_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpColorProviders.push(entry);
            \\      globalThis._wizp_colorProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpColorProviders = globalThis._wizpColorProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_colorProvider === provider) globalThis._wizp_colorProvider = globalThis._wizpColorProviders.length ? globalThis._wizpColorProviders[globalThis._wizpColorProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerDefinitionProvider: function(selector, provider) {
            \\      const id = "definition_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpDefinitionProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'definition', id);
            \\      globalThis._wizp_definitionProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpDefinitionProviders = globalThis._wizpDefinitionProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_definitionProvider === provider) globalThis._wizp_definitionProvider = globalThis._wizpDefinitionProviders.length ? globalThis._wizpDefinitionProviders[globalThis._wizpDefinitionProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerDeclarationProvider: function(selector, provider) {
            \\      const id = "declaration_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpDeclarationProviders.push(entry);
            \\      globalThis._wizp_declarationProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpDeclarationProviders = globalThis._wizpDeclarationProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_declarationProvider === provider) globalThis._wizp_declarationProvider = globalThis._wizpDeclarationProviders.length ? globalThis._wizpDeclarationProviders[globalThis._wizpDeclarationProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerTypeDefinitionProvider: function(selector, provider) {
            \\      const id = "typeDefinition_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpTypeDefinitionProviders.push(entry);
            \\      globalThis._wizp_typeDefinitionProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpTypeDefinitionProviders = globalThis._wizpTypeDefinitionProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_typeDefinitionProvider === provider) globalThis._wizp_typeDefinitionProvider = globalThis._wizpTypeDefinitionProviders.length ? globalThis._wizpTypeDefinitionProviders[globalThis._wizpTypeDefinitionProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerImplementationProvider: function(selector, provider) {
            \\      const id = "implementation_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpImplementationProviders.push(entry);
            \\      globalThis._wizp_implementationProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpImplementationProviders = globalThis._wizpImplementationProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_implementationProvider === provider) globalThis._wizp_implementationProvider = globalThis._wizpImplementationProviders.length ? globalThis._wizpImplementationProviders[globalThis._wizpImplementationProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerReferenceProvider: function(selector, provider) {
            \\      const id = "reference_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpReferenceProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'reference', id);
            \\      globalThis._wizp_referenceProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpReferenceProviders = globalThis._wizpReferenceProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_referenceProvider === provider) globalThis._wizp_referenceProvider = globalThis._wizpReferenceProviders.length ? globalThis._wizpReferenceProviders[globalThis._wizpReferenceProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerRenameProvider: function(selector, provider) {
            \\      const id = "rename_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpRenameProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'rename', id);
            \\      globalThis._wizp_renameProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpRenameProviders = globalThis._wizpRenameProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_renameProvider === provider) globalThis._wizp_renameProvider = globalThis._wizpRenameProviders.length ? globalThis._wizpRenameProviders[globalThis._wizpRenameProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerCodeActionsProvider: function(selector, provider) {
            \\      const id = "codeAction_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider, metadata: arguments[2] || null };
            \\      globalThis._wizpCodeActionProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'codeAction', id);
            \\      globalThis._wizp_codeActionProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpCodeActionProviders = globalThis._wizpCodeActionProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_codeActionProvider === provider) globalThis._wizp_codeActionProvider = globalThis._wizpCodeActionProviders.length ? globalThis._wizpCodeActionProviders[globalThis._wizpCodeActionProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerSignatureHelpProvider: function(selector, provider) {
            \\      const id = "signatureHelp_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider, triggerCharacters: Array.prototype.slice.call(arguments, 2) };
            \\      globalThis._wizpSignatureHelpProviders.push(entry);
            \\      globalThis._wizp_signatureHelpProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpSignatureHelpProviders = globalThis._wizpSignatureHelpProviders.filter(e => e.id !== id);
            \\        if (globalThis._wizp_signatureHelpProvider === provider) globalThis._wizp_signatureHelpProvider = globalThis._wizpSignatureHelpProviders.length ? globalThis._wizpSignatureHelpProviders[globalThis._wizpSignatureHelpProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerCodeLensProvider: function(selector, provider) {
            \\      const id = "codeLens_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpCodeLensProviders.push(entry);
            \\      return { dispose: function() {
            \\        globalThis._wizpCodeLensProviders = globalThis._wizpCodeLensProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerInlayHintsProvider: function(selector, provider) {
            \\      const id = "inlayHint_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpInlayHintProviders.push(entry);
            \\      return { dispose: function() {
            \\        globalThis._wizpInlayHintProviders = globalThis._wizpInlayHintProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerDocumentSemanticTokensProvider: function(selector, provider, legend) {
            \\      const id = "semanticTokens_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider, legend: legend || { tokenTypes: [], tokenModifiers: [] } };
            \\      globalThis._wizpSemanticTokenProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'semanticTokens', id);
            \\      return { dispose: function() {
            \\        globalThis._wizpSemanticTokenProviders = globalThis._wizpSemanticTokenProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerDocumentRangeSemanticTokensProvider: function(selector, provider, legend) {
            \\      const id = "documentRangeSemanticTokens_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider, legend: legend || { tokenTypes: [], tokenModifiers: [] } };
            \\      globalThis._wizpDocumentRangeSemanticTokenProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'documentRangeSemanticTokens', id);
            \\      return { dispose: function() {
            \\        globalThis._wizpDocumentRangeSemanticTokenProviders = globalThis._wizpDocumentRangeSemanticTokenProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerFoldingRangeProvider: function(selector, provider) {
            \\      const id = "foldingRange_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpFoldingRangeProviders.push(entry);
            \\      return { dispose: function() {
            \\        globalThis._wizpFoldingRangeProviders = globalThis._wizpFoldingRangeProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerDocumentSymbolProvider: function(selector, provider, metadata) {
            \\      const id = "documentSymbol_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider, metadata: metadata || null };
            \\      globalThis._wizpDocumentSymbolProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'documentSymbol', id);
            \\      return { dispose: function() {
            \\        globalThis._wizpDocumentSymbolProviders = globalThis._wizpDocumentSymbolProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerSelectionRangeProvider: function(selector, provider) {
            \\      const id = "selectionRange_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpSelectionRangeProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'selectionRange', id);
            \\      globalThis._wizp_selectionRangeProvider = provider;
            \\      return { dispose: function() {
            \\        globalThis._wizpSelectionRangeProviders = globalThis._wizpSelectionRangeProviders.filter(function(item) { return item.id !== id; });
            \\        if (globalThis._wizp_selectionRangeProvider === provider) globalThis._wizp_selectionRangeProvider = globalThis._wizpSelectionRangeProviders.length ? globalThis._wizpSelectionRangeProviders[globalThis._wizpSelectionRangeProviders.length - 1].provider : null;
            \\      } };
            \\    },
            \\    registerWorkspaceSymbolProvider: function(provider) {
            \\      const id = "workspaceSymbol_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, provider: provider };
            \\      globalThis._wizpWorkspaceSymbolProviders.push(entry);
            \\      return { dispose: function() {
            \\        globalThis._wizpWorkspaceSymbolProviders = globalThis._wizpWorkspaceSymbolProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerInlineValuesProvider: function(selector, provider) {
            \\      const id = "inlineValues_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpInlineValuesProviders.push(entry);
            \\      return { dispose: function() {
            \\        globalThis._wizpInlineValuesProviders = globalThis._wizpInlineValuesProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerDocumentHighlightProvider: function(selector, provider) {
            \\      const id = "documentHighlight_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpDocumentHighlightProviders.push(entry);
            \\      return { dispose: function() {
            \\        globalThis._wizpDocumentHighlightProviders = globalThis._wizpDocumentHighlightProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerDocumentLinkProvider: function(selector, provider) {
            \\      const id = "documentLink_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpDocumentLinkProviders.push(entry);
            \\      return { dispose: function() {
            \\        globalThis._wizpDocumentLinkProviders = globalThis._wizpDocumentLinkProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerDocumentFormattingEditProvider: function(selector, provider) {
            \\      const id = "documentFormatting_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpDocumentFormattingProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'documentFormatting', id);
            \\      return { dispose: function() {
            \\        globalThis._wizpDocumentFormattingProviders = globalThis._wizpDocumentFormattingProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerDocumentRangeFormattingEditProvider: function(selector, provider) {
            \\      const id = "rangeFormatting_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpRangeFormattingProviders.push(entry);
            \\      return { dispose: function() {
            \\        globalThis._wizpRangeFormattingProviders = globalThis._wizpRangeFormattingProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerOnTypeFormattingEditProvider: function(selector, provider, firstTriggerCharacter) {
            \\      const id = "onTypeFormatting_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider, firstTriggerCharacter: firstTriggerCharacter };
            \\      globalThis._wizpOnTypeFormattingProviders.push(entry);
            \\      return { dispose: function() {
            \\        globalThis._wizpOnTypeFormattingProviders = globalThis._wizpOnTypeFormattingProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerCallHierarchyProvider: function(selector, provider) {
            \\      const id = "callHierarchy_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpCallHierarchyProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'callHierarchy', id);
            \\      return { dispose: function() {
            \\        globalThis._wizpCallHierarchyProviders = globalThis._wizpCallHierarchyProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\    registerTypeHierarchyProvider: function(selector, provider) {
            \\      const id = "typeHierarchy_" + (++globalThis._wizp_disposableId);
            \\      const entry = { id: id, selector: selector, provider: provider };
            \\      globalThis._wizpTypeHierarchyProviders.push(entry);
            \\      globalThis._wizpDebugLog('provider.register', 'typeHierarchy', id);
            \\      return { dispose: function() {
            \\        globalThis._wizpTypeHierarchyProviders = globalThis._wizpTypeHierarchyProviders.filter(function(item) { return item.id !== id; });
            \\      } };
            \\    },
            \\  },
            \\  extensions: {
            \\    get all() {
            \\      const values = Object.values(globalThis._wizpExtensions || {});
            \\      const seen = [];
            \\      return values.filter(function(ext) {
            \\        if (!ext || !ext.id) return false;
            \\        if (seen.indexOf(ext.id) >= 0) return false;
            \\        seen.push(ext.id);
            \\        return true;
            \\      });
            \\    },
            \\    getExtension: function(id) {
            \\      const pythonApiShimEnabled = !!(globalThis._wizpNodeProcess && globalThis._wizpNodeProcess.env && globalThis._wizpNodeProcess.env.WIZP_ENABLE_PYTHON_EXTENSION_API_SHIM === '1');
            \\      const found = (globalThis._wizpExtensions || {})[id];
            \\      if (id === 'ms-python.python' && pythonApiShimEnabled) {
            \\        const activePathEmitter = new globalThis._wizpContext.EventEmitter();
            \\        const environmentsEmitter = new globalThis._wizpContext.EventEmitter();
            \\        const envVarsEmitter = new globalThis._wizpContext.EventEmitter();
            \\        let pythonPath = (globalThis._wizpNodeProcess && globalThis._wizpNodeProcess.env && (globalThis._wizpNodeProcess.env.PYTHON || globalThis._wizpNodeProcess.env.PYTHON3)) || '/usr/bin/python3';
            \\        const extensionPath = found && typeof found.extensionPath === 'string' && found.extensionPath ? found.extensionPath : (globalThis._wizpCwd || '.');
            \\        const extensionId = found && typeof found.id === 'string' && found.id ? found.id : 'ms-python.python';
            \\        const packageJSON = Object.assign({ name: 'python', publisher: 'ms-python', version: '2026.4.0' }, found && found.packageJSON ? found.packageJSON : {});
            \\        if (found && found.isActive && found.exports) return found;
            \\        const normalizeResource = function(resource) {
            \\          if (resource && typeof resource === 'object' && resource.uri) return resource.uri;
            \\          return resource;
            \\        };
            \\        const dirname = function(pathValue) {
            \\          const text = String(pathValue || '');
            \\          const slash = Math.max(text.lastIndexOf('/'), text.lastIndexOf('\\\\'));
            \\          return slash > 0 ? text.slice(0, slash) : text;
            \\        };
            \\        const normalizePath = function(value) {
            \\          if (!value) return pythonPath;
            \\          if (typeof value === 'string') return value;
            \\          if (typeof value.path === 'string' && value.path) return value.path;
            \\          if (typeof value.id === 'string' && value.id) return value.id;
            \\          if (value.executable && value.executable.uri && typeof value.executable.uri.fsPath === 'string' && value.executable.uri.fsPath) return value.executable.uri.fsPath;
            \\          return pythonPath;
            \\        };
            \\        const makeEnvironment = function(pathValue) {
            \\          const active = normalizePath(pathValue);
            \\          const envDir = dirname(active) || active;
            \\          return {
            \\            id: active,
            \\            path: active,
            \\            name: 'Python 3',
            \\            displayName: 'Python 3',
            \\            detailedDisplayName: active,
            \\            environmentPath: globalThis._wizpContext.Uri.file(envDir),
            \\            executable: {
            \\              uri: globalThis._wizpContext.Uri.file(active),
            \\              filename: active,
            \\              sysPrefix: envDir,
            \\            },
            \\            execInfo: {
            \\              run: { executable: active, args: [] },
            \\              activatedRun: { executable: active, args: [] },
            \\            },
            \\            version: { major: 3, minor: 11, micro: 0, patch: 0 },
            \\            tools: [],
            \\          };
            \\        };
            \\        const currentPathRecord = function(resource) {
            \\          return { id: pythonPath, path: pythonPath, resource: normalizeResource(resource) };
            \\        };
            \\        const exports = {
            \\          environments: {
            \\            getEnvironmentVariables: function(resource) {
            \\              void resource;
            \\              const env = (globalThis._wizpNodeProcess && globalThis._wizpNodeProcess.env) || {};
            \\              return Object.assign({}, env);
            \\            },
            \\            get onDidEnvironmentVariablesChange() { return envVarsEmitter.event; },
            \\            getActiveEnvironmentPath: function(resource) { return currentPathRecord(resource); },
            \\            updateActiveEnvironmentPath: async function(pathOrEnv, resource) {
            \\              const nextPath = normalizePath(pathOrEnv);
            \\              const changed = nextPath !== pythonPath;
            \\              pythonPath = nextPath;
            \\              const payload = currentPathRecord(resource);
            \\              if (changed) {
            \\                activePathEmitter.fire(payload);
            \\                environmentsEmitter.fire({ type: 'update', env: makeEnvironment(nextPath) });
            \\              }
            \\              return undefined;
            \\            },
            \\            get onDidChangeActiveEnvironmentPath() { return activePathEmitter.event; },
            \\            updateActiveEnvironment: function(pathOrEnv, resource) { return exports.environments.updateActiveEnvironmentPath(pathOrEnv, resource); },
            \\            get onDidChangeActiveEnvironment() { return activePathEmitter.event; },
            \\            resolveEnvironment: async function(pathOrEnv) { return makeEnvironment(pathOrEnv); },
            \\            get known() { return [makeEnvironment(pythonPath)]; },
            \\            refreshEnvironments: async function(options) {
            \\              environmentsEmitter.fire({ type: 'refresh', env: makeEnvironment(pythonPath), options: options || null });
            \\              return undefined;
            \\            },
            \\            get onDidChangeEnvironments() { return environmentsEmitter.event; },
            \\            get onDidEnvironmentsChanged() { return environmentsEmitter.event; },
            \\            get onDidActiveEnvironmentChanged() { return activePathEmitter.event; },
            \\            refreshEnvironment: async function() { return exports.environments.refreshEnvironments(); },
            \\            setActiveEnvironment: function(pathOrEnv, resource) { return exports.environments.updateActiveEnvironmentPath(pathOrEnv, resource); },
            \\          },
            \\          debug: {
            \\            getDebuggerPackagePath: async function() { return undefined; }
            \\          }
            \\        };
            \\        const record = found || {};
            \\        record.id = extensionId;
            \\        record.extensionUri = globalThis._wizpContext.Uri.file(extensionPath);
            \\        record.extensionPath = extensionPath;
            \\        record.isActive = true;
            \\        record.packageJSON = packageJSON;
            \\        record.exports = exports;
            \\        record.activate = async function() { return exports; };
            \\        if (globalThis._wizpExtensions) {
            \\          globalThis._wizpExtensions[packageJSON.name] = record;
            \\          globalThis._wizpExtensions[extensionId] = record;
            \\        }
            \\        return record;
            \\      }
            \\      if (found) return found;
            \\      if (id === 'vscode.typescript-language-features') {
            \\        const exports = {
            \\          getAPI: function(version) { return { version: version || 0 }; }
            \\        };
            \\        return {
            \\          id: 'vscode.typescript-language-features',
            \\          extensionUri: globalThis._wizpContext.Uri.file(globalThis._wizpCwd || '.'),
            \\          extensionPath: globalThis._wizpCwd || '.',
            \\          isActive: true,
            \\          packageJSON: { name: 'typescript-language-features', publisher: 'vscode', version: 'wizp-shim', contributes: { typescriptServerPlugins: [] } },
            \\          exports: exports,
            \\          activate: async function() { return exports; }
            \\        };
            \\      }
            \\      if (id === 'vscode.git') {
            \\        const repositoryEmitter = new globalThis._wizpContext.EventEmitter();
            \\        const api = {
            \\          git: {
            \\            path: 'git',
            \\            env: {},
            \\            repositories: []
            \\          },
            \\          repositories: [],
            \\          onDidOpenRepository: repositoryEmitter.event,
            \\          onDidCloseRepository: repositoryEmitter.event,
            \\          openRepository: async function(uri) { return undefined; },
            \\          getRepository: function(uri) { return undefined; }
            \\        };
            \\        const exports = { getAPI: function(version) { return api; } };
            \\        return {
            \\          id: 'vscode.git',
            \\          extensionUri: globalThis._wizpContext.Uri.file(globalThis._wizpCwd || '.'),
            \\          extensionPath: globalThis._wizpCwd || '.',
            \\          isActive: true,
            \\          packageJSON: { name: 'git', publisher: 'vscode', version: 'wizp-shim' },
            \\          exports: exports,
            \\          activate: async function() { return exports; }
            \\        };
            \\      }
            \\      if (id === 'vscode.docker' || id === 'vscode.yaml') {
            \\        const name = id === 'vscode.docker' ? 'docker' : 'yaml';
            \\        const exports = {};
            \\        return {
            \\          id: id,
            \\          extensionUri: globalThis._wizpContext.Uri.file(globalThis._wizpCwd || '.'),
            \\          extensionPath: globalThis._wizpCwd || '.',
            \\          isActive: true,
            \\          packageJSON: { name: name, publisher: 'vscode', version: 'wizp-shim' },
            \\          exports: exports,
            \\          activate: async function() { return exports; }
            \\        };
            \\      }
            \\      return undefined;
            \\    },
            \\    onDidChange: function(callback) { return { dispose: function() {} }; }
            \\  },
            \\  subscriptions: [],
            \\};
            \\
            \\globalThis._wizp_lspResolvers = {};
            \\
            \\globalThis.WIZP_onDidChangeTextDocument = function(uri, changes) {
            \\  const parsedUri = globalThis._wizpContext.Uri.file(uri);
            \\  const key = parsedUri.toString();
            \\  const doc = globalThis._wizpDocuments[key] || globalThis._wizpContext.workspace._makeTextDocument(parsedUri, '', 'plaintext', 1);
            \\  const edits = (changes || []).map(function(change) { return { range: change.range || new globalThis._wizpContext.Range(new globalThis._wizpContext.Position(0, 0), new globalThis._wizpContext.Position(0, 0)), newText: change.text || '' }; });
            \\  if (edits.length) globalThis._wizpContext.workspace._changeTextDocument(doc, edits);
            \\  else globalThis._wizpContext.workspace._fireTextDocumentEvent('change', doc, { contentChanges: changes || [] });
            \\};
            \\
            \\globalThis.WIZP_invokeHover = function(id, uri, line, col) {
            \\  const replyUrl = globalThis._wizpApiOrigin + "/api/extension/lsp/reply";
            \\  if (!globalThis._wizp_hoverProvider) { return fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}); }
            \\  const pos = { lineNumber: line, character: col };
            \\  const doc = { uri: globalThis._wizpContext.Uri.file(uri), fileName: uri };
            \\  Promise.resolve(globalThis._wizp_hoverProvider.provideHover(doc, pos, { isCancellationRequested: false }))
            \\    .then(res => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: res})}))
            \\    .catch(err => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}));
            \\};
            \\globalThis.WIZP_invokeCompletion = function(id, uri, line, col) {
            \\  const replyUrl = globalThis._wizpApiOrigin + "/api/extension/lsp/reply";
            \\  if (!globalThis._wizp_completionProvider) { return fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}); }
            \\  const doc = { uri: globalThis._wizpContext.Uri.file(uri), fileName: uri };
            \\  Promise.resolve(globalThis._wizp_completionProvider.provideCompletionItems(doc, { lineNumber: line, character: col }, { isCancellationRequested: false }, { triggerKind: globalThis._wizpContext.CompletionTriggerKind.Invoke }))
            \\    .then(res => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: res})}))
            \\    .catch(() => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}));
            \\};
            \\globalThis.WIZP_invokeDefinition = function(id, uri, line, col) {
            \\  const replyUrl = globalThis._wizpApiOrigin + "/api/extension/lsp/reply";
            \\  if (!globalThis._wizp_definitionProvider) { return fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}); }
            \\  const doc = { uri: globalThis._wizpContext.Uri.file(uri), fileName: uri };
            \\  Promise.resolve(globalThis._wizp_definitionProvider.provideDefinition(doc, { lineNumber: line, character: col }, { isCancellationRequested: false }))
            \\    .then(res => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: res})}))
            \\    .catch(() => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}));
            \\};
            \\globalThis.WIZP_invokeReference = function(id, uri, line, col) {
            \\  const replyUrl = globalThis._wizpApiOrigin + "/api/extension/lsp/reply";
            \\  if (!globalThis._wizp_referenceProvider) { return fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}); }
            \\  const doc = { uri: globalThis._wizpContext.Uri.file(uri), fileName: uri };
            \\  Promise.resolve(globalThis._wizp_referenceProvider.provideReferences(doc, { lineNumber: line, character: col }, { includeDeclaration: true }, { isCancellationRequested: false }))
            \\    .then(res => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: res})}))
            \\    .catch(() => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}));
            \\};
            \\globalThis.WIZP_invokeRename = function(id, uri, line, col, newName) {
            \\  const replyUrl = globalThis._wizpApiOrigin + "/api/extension/lsp/reply";
            \\  if (!globalThis._wizp_renameProvider) { return fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}); }
            \\  const doc = { uri: globalThis._wizpContext.Uri.file(uri), fileName: uri };
            \\  Promise.resolve(globalThis._wizp_renameProvider.provideRenameEdits(doc, { lineNumber: line, character: col }, newName, { isCancellationRequested: false }))
            \\    .then(res => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: res})}))
            \\    .catch(() => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}));
            \\};
            \\globalThis.WIZP_invokeCodeAction = function(id, uri, rangeStartLine, rangeStartCol, rangeEndLine, rangeEndCol) {
            \\  const replyUrl = globalThis._wizpApiOrigin + "/api/extension/lsp/reply";
            \\  if (!globalThis._wizp_codeActionProvider) { return fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}); }
            \\  const doc = { uri: globalThis._wizpContext.Uri.file(uri), fileName: uri };
            \\  const range = { start: { line: rangeStartLine, character: rangeStartCol }, end: { line: rangeEndLine, character: rangeEndCol } };
            \\  Promise.resolve(globalThis._wizp_codeActionProvider.provideCodeActions(doc, range, { diagnostics: [] }, { isCancellationRequested: false }))
            \\    .then(res => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: res})}))
            \\    .catch(() => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}));
            \\};
            \\globalThis.WIZP_invokeSignatureHelp = function(id, uri, line, col) {
            \\  const replyUrl = globalThis._wizpApiOrigin + "/api/extension/lsp/reply";
            \\  if (!globalThis._wizp_signatureHelpProvider) { return fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}); }
            \\  const doc = { uri: globalThis._wizpContext.Uri.file(uri), fileName: uri };
            \\  Promise.resolve(globalThis._wizp_signatureHelpProvider.provideSignatureHelp(doc, { lineNumber: line, character: col }, { isCancellationRequested: false }))
            \\    .then(res => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: res})}))
            \\    .catch(() => fetch(replyUrl, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id, result: null})}));
            \\};
        , "vscode-api");

        try self.engine.evalVoid(
            \\(function() {
            \\  const env = globalThis._wizpProcessEnv || {};
            \\  const host = String(env.WIZP_HOST || '127.0.0.1');
            \\  const port = String(env.WIZP_PORT || '9876');
            \\  globalThis._wizpApiOrigin = 'http://' + host + ':' + port;
            \\  globalThis._wizpWebviewOrigin = 'http://' + host + ':' + port;
            \\  globalThis._wizpWebviewCspSource = globalThis._wizpWebviewOrigin;
            \\  globalThis._wizpPostExtensionRpc = function(method, params) {
            \\    const fetchImpl = globalThis.fetch;
            \\    if (typeof fetchImpl !== 'function') return Promise.resolve(false);
            \\    const next = Promise.resolve(globalThis._wizpExtensionRpcChain || null)
            \\      .catch(function() {})
            \\      .then(function() {
            \\        return fetchImpl(globalThis._wizpApiOrigin + '/api/extension-rpc', {
            \\          method: 'POST',
            \\          headers: { 'Content-Type': 'application/json' },
            \\          body: JSON.stringify({
            \\            jsonrpc: '2.0',
            \\            id: 0,
            \\            method: method,
            \\            params: params || {}
            \\          })
            \\        }).then(function() { return true; }).catch(function() { return false; });
            \\      });
            \\    globalThis._wizpExtensionRpcChain = next.catch(function() {});
            \\    return next;
            \\  };
            \\  globalThis._wizpWebviewPathOf = function(uriLike) {
            \\    if (uriLike === null || uriLike === undefined) return '';
            \\    let raw = '';
            \\    if (typeof uriLike === 'string') {
            \\      raw = uriLike;
            \\    } else if (typeof uriLike === 'object') {
            \\      if (typeof uriLike.fsPath === 'string' && uriLike.fsPath) raw = uriLike.fsPath;
            \\      else if (uriLike.scheme === 'file' && typeof uriLike.path === 'string' && uriLike.path) raw = uriLike.path;
            \\      else if (typeof uriLike.toString === 'function') raw = String(uriLike.toString());
            \\      else raw = String(uriLike);
            \\    } else {
            \\      raw = String(uriLike);
            \\    }
            \\    raw = String(raw || '');
            \\    if (!raw) return '';
            \\    if (/^(data|blob|https?):/i.test(raw)) return '';
            \\    if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(raw)) {
            \\      try {
            \\        const parsed = globalThis._wizpContext.Uri.parse(raw);
            \\        if (parsed.scheme !== 'file') return '';
            \\        raw = parsed.fsPath || parsed.path || '';
            \\      } catch (_) {
            \\        return '';
            \\      }
            \\    }
            \\    raw = String(raw || '');
            \\    if (!raw) return '';
            \\    if (!globalThis._wizpNodePath.isAbsolute(raw)) {
            \\      raw = globalThis._wizpNodePath.join(globalThis._wizpCwd || '.', raw);
            \\    }
            \\    return globalThis._wizpNodePath.normalize(raw);
            \\  };
            \\  globalThis._wizpWebviewRootsFor = function(id) {
            \\    let webview = null;
            \\    if (typeof id === 'string' && id.indexOf('webviewView:') === 0) {
            \\      const viewId = id.slice('webviewView:'.length);
            \\      const resolvedViews = globalThis._wizp_resolvedWebviewViews || {};
            \\      const existingView = resolvedViews[viewId];
            \\      if (existingView && existingView.webview) webview = existingView.webview;
            \\      else if (globalThis._wizp_resolveWebviewView) {
            \\        try {
            \\          const resolved = globalThis._wizp_resolveWebviewView(viewId);
            \\          if (resolved && resolved.webview) webview = resolved.webview;
            \\        } catch (_) {}
            \\      }
            \\    } else {
            \\      const panels = globalThis._wizp_webviewPanels || {};
            \\      const panel = panels[id];
            \\      if (panel && panel.webview) webview = panel.webview;
            \\    }
            \\    let roots = [];
            \\    const configured = webview && webview.options && Array.isArray(webview.options.localResourceRoots) ? webview.options.localResourceRoots : [];
            \\    if (configured.length > 0) {
            \\      roots = configured.slice();
            \\    } else {
            \\      const workspaceFolder = (((globalThis._wizpContext || {}).workspace || {}).workspaceFolders || [])[0];
            \\      if (workspaceFolder && workspaceFolder.uri) roots.push(workspaceFolder.uri);
            \\      for (const extension of Object.values(globalThis._wizpExtensions || {})) {
            \\        if (extension && extension.extensionUri) roots.push(extension.extensionUri);
            \\        else if (extension && extension.extensionPath) roots.push(globalThis._wizpContext.Uri.file(extension.extensionPath));
            \\      }
            \\    }
            \\    const unique = [];
            \\    for (const root of roots) {
            \\      const normalized = globalThis._wizpWebviewPathOf(root);
            \\      if (normalized && unique.indexOf(normalized) < 0) unique.push(normalized);
            \\    }
            \\    return unique;
            \\  };
            \\  globalThis._wizpCanServeWebviewResource = function(id, resourcePath) {
            \\    const candidate = globalThis._wizpWebviewPathOf(resourcePath);
            \\    if (!candidate) return false;
            \\    const roots = globalThis._wizpWebviewRootsFor(id);
            \\    const sep = globalThis._wizpNodePath.sep || '/';
            \\    return roots.some(function(root) {
            \\      return candidate === root || candidate.indexOf(root + sep) === 0;
            \\    });
            \\  };
            \\  globalThis._wizpAsWebviewUri = function(id, uri) {
            \\    const path = globalThis._wizpWebviewPathOf(uri);
            \\    if (!path) return uri;
            \\    const url = globalThis._wizpWebviewOrigin +
            \\      '/api/webview-resource?id=' + encodeURIComponent(String(id || '')) +
            \\      '&path=' + encodeURIComponent(path);
            \\    return globalThis._wizpContext.Uri.parse(url);
            \\  };
            \\})()
        , "webview-resource-helpers");

        try self.engine.evalVoid(
            \\(function() {
            \\  const cwd = globalThis._wizpCwd || '.';
            \\  const name = cwd.split('/').pop() || cwd;
            \\  globalThis._wizpContext.workspace.workspaceFolders = [{ uri: globalThis._wizpContext.Uri.file(cwd), name: name, path: cwd, index: 0 }];
            \\})()
        , "workspace-cwd");

        try self.refreshContributedConfigurationDefaults();
    }

    /// Get the JS engine for direct use.
    pub fn getEngine(self: *Self) *JSEngine {
        return &self.engine;
    }
};

/// Check if an activation event pattern matches an event.
fn matchesActivationEvent(pattern: []const u8, event: []const u8) bool {
    if (std.mem.eql(u8, pattern, event)) return true;

    // VS Code wildcard activation is a startup activation event, not a catch-all
    // for every later event trigger.
    if (std.mem.eql(u8, pattern, "*")) return std.mem.eql(u8, event, "startup") or std.mem.eql(u8, event, "*");

    // onLanguage:xxx → triggered when language is xxx
    if (std.mem.eql(u8, pattern, "onLanguage")) {
        return std.mem.startsWith(u8, event, "language:") or std.mem.startsWith(u8, event, "onLanguage:");
    }

    if (std.mem.startsWith(u8, pattern, "onLanguage:")) {
        const lang = pattern["onLanguage:".len..];
        // event is like "language:zig"
        if (std.mem.startsWith(u8, event, "language:")) {
            return std.mem.eql(u8, lang, event["language:".len..]);
        }
    }

    // onCommand:xxx → triggered when command xxx is executed
    if (std.mem.startsWith(u8, pattern, "onCommand:")) {
        const cmd = pattern["onCommand:".len..];
        if (std.mem.startsWith(u8, event, "command:")) {
            return std.mem.eql(u8, cmd, event["command:".len..]);
        }
    }

    // onStartupFinished → triggered after editor is ready
    if (std.mem.eql(u8, pattern, "onStartupFinished") and std.mem.eql(u8, event, "startup")) {
        return true;
    }

    if (std.mem.startsWith(u8, pattern, "workspaceContains:")) {
        const glob = pattern["workspaceContains:".len..];
        if (std.mem.startsWith(u8, event, "workspaceContains:")) {
            const path = event["workspaceContains:".len..];
            return if (containsGlobMeta(glob)) globMatches(glob, path) else std.mem.eql(u8, glob, path);
        }
    }

    if (std.mem.startsWith(u8, pattern, "onView:")) {
        const view_id = pattern["onView:".len..];
        if (std.mem.startsWith(u8, event, "view:")) {
            return std.mem.eql(u8, view_id, event["view:".len..]);
        }
    }

    if (std.mem.startsWith(u8, pattern, "onDebugResolve:")) {
        const debug_type = pattern["onDebugResolve:".len..];
        if (std.mem.startsWith(u8, event, "debugResolve:")) {
            return std.mem.eql(u8, debug_type, event["debugResolve:".len..]);
        }
    }

    if (std.mem.eql(u8, pattern, "onDebug") or std.mem.startsWith(u8, pattern, "onDebug:")) {
        if (std.mem.eql(u8, event, "debug")) return true;
        if (std.mem.startsWith(u8, event, "debug:")) {
            if (std.mem.eql(u8, pattern, "onDebug")) return true;
            return std.mem.eql(u8, pattern["onDebug".len..], event["debug".len..]);
        }
    }

    if (std.mem.startsWith(u8, pattern, "onTaskType:")) {
        const task_type = pattern["onTaskType:".len..];
        if (std.mem.startsWith(u8, event, "task:")) {
            return std.mem.eql(u8, task_type, event["task:".len..]);
        }
    }

    if (std.mem.startsWith(u8, pattern, "onFileSystem:")) {
        const scheme = pattern["onFileSystem:".len..];
        if (std.mem.startsWith(u8, event, "fileSystem:")) {
            return std.mem.eql(u8, scheme, event["fileSystem:".len..]);
        }
    }

    // Exact match
    return std.mem.eql(u8, pattern, event);
}

fn containsGlobMeta(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?[]{}") != null;
}

fn isCommonJsSourcePath(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".js") or
        std.mem.endsWith(u8, name, ".cjs") or
        std.mem.endsWith(u8, name, ".json") or
        std.mem.endsWith(u8, name, ".editorconfig") or
        std.mem.endsWith(u8, name, ".wasm");
}

fn globMatches(pattern: []const u8, text: []const u8) bool {
    return globMatchesFrom(pattern, 0, text, 0);
}

fn globMatchesFrom(pattern: []const u8, pi: usize, text: []const u8, ti: usize) bool {
    var p = pi;
    var t = ti;
    while (p < pattern.len) {
        switch (pattern[p]) {
            '*' => {
                while (p + 1 < pattern.len and pattern[p + 1] == '*') p += 1;
                if (p + 1 == pattern.len) return true;
                var i = t;
                while (i <= text.len) : (i += 1) {
                    if (globMatchesFrom(pattern, p + 1, text, i)) return true;
                }
                return false;
            },
            '?' => {
                if (t >= text.len) return false;
                t += 1;
                p += 1;
            },
            else => |ch| {
                if (t >= text.len or text[t] != ch) return false;
                t += 1;
                p += 1;
            },
        }
    }
    return t == text.len;
}

test "activation event matching covers bounded trigger families" {
    try std.testing.expect(matchesActivationEvent("*", "startup"));
    try std.testing.expect(!matchesActivationEvent("*", "command:workbench.action.open"));
    try std.testing.expect(matchesActivationEvent("onLanguage:zig", "language:zig"));
    try std.testing.expect(!matchesActivationEvent("onLanguage:zig", "language:rust"));
    try std.testing.expect(matchesActivationEvent("onCommand:build.run", "command:build.run"));
    try std.testing.expect(matchesActivationEvent("workspaceContains:**/*.zig", "workspaceContains:src/main.zig"));
    try std.testing.expect(matchesActivationEvent("onView:wizp.explorer", "view:wizp.explorer"));
    try std.testing.expect(matchesActivationEvent("onDebug:node", "debug:node"));
    try std.testing.expect(matchesActivationEvent("onTaskType:npm", "task:npm"));
    try std.testing.expect(matchesActivationEvent("onFileSystem:file", "fileSystem:file"));
}

fn javaRuntimePathExists(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(compat_runtime.io(), path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(compat_runtime.io(), path, .{}) catch return false;
    return true;
}

fn jsonObjectString(object: anytype, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// Extract a JSON string value for a given key from minimal JSON.
/// Simple single-line string extractor — NOT a full JSON parser.
fn extractJSONString(json: []const u8, key: []const u8) ?[]const u8 {
    return ExtensionRpc.stringValue(json, key);
}

fn extractJSONValue(json: []const u8, key: []const u8) ?[]const u8 {
    return ExtensionJson.value(json, key);
}

fn extractFirstJsonStringArrayItem(json: []const u8, key: []const u8) ?[]const u8 {
    return ExtensionJson.firstArrayString(json, key);
}

fn trimWhenLiteral(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n'\"");
    if (std.mem.endsWith(u8, trimmed, ")")) return std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n'\"");
    return trimmed;
}

fn extractJsonRpcId(json: []const u8) ?[]const u8 {
    return ExtensionRpc.id(json);
}

fn stripEngineResult(result: []const u8) []const u8 {
    if (std.mem.startsWith(u8, result, "RESULT:")) return result["RESULT:".len..];
    return result;
}

fn jsonRpcError(allocator: Allocator, id_str: []const u8, code: i32, message: []const u8) ![]u8 {
    return try ExtensionRpc.errorResponse(allocator, id_str, code, message);
}

fn writeCommandJson(writer: anytype, command: []const u8, title: []const u8, enablement: ?[]const u8, enabled: bool) !void {
    try writer.writeAll("{\"command\":");
    try writeJsonString(writer, command);
    try writer.writeAll(",\"title\":");
    try writeJsonString(writer, title);
    if (enablement) |expr| {
        try writer.writeAll(",\"enablement\":");
        try writeJsonString(writer, expr);
    }
    try writer.print(",\"enabled\":{}", .{enabled});
    try writer.writeAll("}");
}

fn writeMenuJson(writer: anytype, menu: ExtensionHost.MenuContribution, title: []const u8, enabled: bool) !void {
    try writer.writeAll("{\"menu\":");
    try writeJsonString(writer, menu.menu);
    try writer.writeAll(",\"command\":");
    try writeJsonString(writer, menu.command);
    try writer.writeAll(",\"title\":");
    try writeJsonString(writer, title);
    if (menu.when) |when| {
        try writer.writeAll(",\"when\":");
        try writeJsonString(writer, when);
    }
    if (menu.group) |group| {
        try writer.writeAll(",\"group\":");
        try writeJsonString(writer, group);
    }
    if (menu.alt) |alt| {
        try writer.writeAll(",\"alt\":");
        try writeJsonString(writer, alt);
    }
    if (menu.args) |args| {
        try writer.writeAll(",\"args\":");
        try writer.writeAll(args);
    }
    try writer.print(",\"enabled\":{}", .{enabled});
    try writer.writeAll("}");
}

fn writeKeybindingJson(writer: anytype, kb: ExtensionHost.KeybindingContribution, key: []const u8, enabled: bool, conflict_count: usize) !void {
    try writer.writeAll("{\"command\":");
    try writeJsonString(writer, kb.command);
    try writer.writeAll(",\"key\":");
    try writeJsonString(writer, key);
    if (kb.when) |when| {
        try writer.writeAll(",\"when\":");
        try writeJsonString(writer, when);
    }
    try writer.print(",\"enabled\":{},\"isChord\":{},\"conflictCount\":{}", .{ enabled, std.mem.indexOfScalar(u8, key, ' ') != null, conflict_count });
    try writer.writeAll("}");
}

fn writeConfigurationJson(writer: anytype, cfg: ExtensionHost.ConfigurationContribution) !void {
    try writer.writeAll("{\"key\":");
    try writeJsonString(writer, cfg.key);
    try writer.writeAll(",\"title\":");
    try writeJsonString(writer, cfg.title);
    try writer.writeAll(",\"type\":");
    try writer.writeAll(cfg.type_raw);
    try writer.writeAll(",\"default\":");
    try writer.writeAll(cfg.default_raw);
    if (cfg.description) |description| {
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, description);
    }
    try writer.writeAll("}");
}

fn writeLanguageJson(writer: anytype, lang: ExtensionHost.LanguageContribution) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, lang.id);
    try writer.writeAll(",\"aliases\":");
    try writeJsonStringArray(writer, lang.aliases);
    try writer.writeAll(",\"extensions\":");
    try writeJsonStringArray(writer, lang.extensions);
    if (lang.configuration) |configuration| {
        try writer.writeAll(",\"configuration\":");
        try writeJsonString(writer, configuration);
    } else {
        try writer.writeAll(",\"configuration\":null");
    }
    try writer.writeAll("}");
}

fn writeGrammarJson(writer: anytype, grammar: ExtensionHost.GrammarContribution) !void {
    try writer.writeAll("{\"language\":");
    try writeJsonString(writer, grammar.language);
    try writer.writeAll(",\"scopeName\":");
    try writeJsonString(writer, grammar.scope_name);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, grammar.path);
    try writer.writeAll("}");
}

fn writeThemeJson(writer: anytype, theme: ExtensionHost.ThemeContribution) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, theme.id);
    try writer.writeAll(",\"label\":");
    try writeJsonString(writer, theme.label);
    if (theme.ui_theme) |ui_theme| {
        try writer.writeAll(",\"uiTheme\":");
        try writeJsonString(writer, ui_theme);
    }
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, theme.path);
    try writer.writeAll("}");
}

fn writeSnippetJson(writer: anytype, snippet: ExtensionHost.SnippetContribution) !void {
    try writer.writeAll("{\"language\":");
    try writeJsonString(writer, snippet.language);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, snippet.path);
    try writer.writeAll("}");
}

fn writeViewContainerJson(writer: anytype, container: ExtensionHost.ViewContainerContribution) !void {
    try writer.writeAll("{\"location\":");
    try writeJsonString(writer, container.location);
    try writer.writeAll(",\"id\":");
    try writeJsonString(writer, container.id);
    try writer.writeAll(",\"title\":");
    try writeJsonString(writer, container.title);
    if (container.icon) |icon| {
        try writer.writeAll(",\"icon\":");
        try writeJsonString(writer, icon);
    }
    try writer.writeAll("}");
}

fn writeViewJson(writer: anytype, view: ExtensionHost.ViewContribution) !void {
    try writer.writeAll("{\"location\":");
    try writeJsonString(writer, view.location);
    try writer.writeAll(",\"container\":");
    try writeJsonString(writer, view.location);
    try writer.writeAll(",\"id\":");
    try writeJsonString(writer, view.id);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, view.name);
    if (view.when) |when| {
        try writer.writeAll(",\"when\":");
        try writeJsonString(writer, when);
    }
    try writer.writeAll("}");
}

fn writeViewWelcomeJson(writer: anytype, welcome: ExtensionHost.ViewWelcomeContribution) !void {
    try writer.writeAll("{\"view\":");
    try writeJsonString(writer, welcome.view);
    try writer.writeAll(",\"contents\":");
    try writeJsonString(writer, welcome.contents);
    if (welcome.when) |when| {
        try writer.writeAll(",\"when\":");
        try writeJsonString(writer, when);
    }
    try writer.writeAll("}");
}

fn writeBreakpointJson(writer: anytype, breakpoint: ExtensionHost.BreakpointContribution) !void {
    try writer.writeAll("{\"language\":");
    try writeJsonString(writer, breakpoint.language);
    try writer.writeAll("}");
}

fn writeJsonValidationJson(writer: anytype, validation: ExtensionHost.JsonValidationContribution) !void {
    try writer.writeAll("{\"fileMatch\":");
    try writeJsonStringArray(writer, validation.file_match);
    try writer.writeAll(",\"url\":");
    try writeJsonString(writer, validation.url);
    try writer.writeAll("}");
}

fn writeResourceLabelFormatterJson(writer: anytype, formatter: ExtensionHost.ResourceLabelFormatterContribution) !void {
    try writer.writeAll("{\"scheme\":");
    try writeJsonString(writer, formatter.scheme);
    try writer.writeAll(",\"formatting\":");
    try writer.writeAll(formatter.formatting_raw);
    try writer.writeAll("}");
}

fn writeProblemMatcherJson(writer: anytype, matcher: ExtensionHost.ProblemMatcherContribution) !void {
    try writer.writeAll("{\"name\":");
    try writeJsonString(writer, matcher.name);
    if (matcher.label) |label| {
        try writer.writeAll(",\"label\":");
        try writeJsonString(writer, label);
    }
    if (matcher.owner) |owner| {
        try writer.writeAll(",\"owner\":");
        try writeJsonString(writer, owner);
    }
    if (matcher.source) |source| {
        try writer.writeAll(",\"source\":");
        try writeJsonString(writer, source);
    }
    if (matcher.pattern_raw) |pattern_raw| {
        try writer.writeAll(",\"pattern\":");
        try writer.writeAll(pattern_raw);
    }
    try writer.writeAll("}");
}

fn writeTaskDefinitionJson(writer: anytype, definition: ExtensionHost.TaskDefinitionContribution) !void {
    try writer.writeAll("{\"type\":");
    try writeJsonString(writer, definition.type_name);
    try writer.writeAll(",\"required\":");
    try writeJsonStringArray(writer, definition.required);
    if (definition.properties_raw) |properties_raw| {
        try writer.writeAll(",\"properties\":");
        try writer.writeAll(properties_raw);
    }
    try writer.writeAll("}");
}

fn writeDebuggerJson(writer: anytype, debugger: ExtensionHost.DebuggerContribution) !void {
    if (debugger.raw_json.len > 0) {
        try writer.writeAll(debugger.raw_json);
        return;
    }
    try writer.writeAll("{\"type\":");
    try writeJsonString(writer, debugger.type_name);
    try writer.writeAll(",\"label\":");
    try writeJsonString(writer, debugger.label);
    if (debugger.program) |program| {
        try writer.writeAll(",\"program\":");
        try writeJsonString(writer, program);
    }
    if (debugger.runtime) |runtime| {
        try writer.writeAll(",\"runtime\":");
        try writeJsonString(writer, runtime);
    }
    try writer.writeAll(",\"languages\":");
    try writeJsonStringArray(writer, debugger.languages);
    if (debugger.configuration_attributes_raw) |raw| {
        try writer.writeAll(",\"configurationAttributes\":");
        try writer.writeAll(raw);
    }
    try writer.writeAll("}");
}

fn writeIconThemeJson(writer: anytype, icon_theme: ExtensionHost.IconThemeContribution) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, icon_theme.id);
    try writer.writeAll(",\"label\":");
    try writeJsonString(writer, icon_theme.label);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, icon_theme.path);
    try writer.writeAll("}");
}

fn writeWalkthroughJson(writer: anytype, walkthrough: ExtensionHost.WalkthroughContribution) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, walkthrough.id);
    try writer.writeAll(",\"title\":");
    try writeJsonString(writer, walkthrough.title);
    if (walkthrough.description) |description| {
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, description);
    }
    if (walkthrough.steps_raw) |steps_raw| {
        try writer.writeAll(",\"steps\":");
        try writer.writeAll(steps_raw);
    }
    try writer.writeAll("}");
}

fn writeRawContributionJson(writer: anytype, contribution: ExtensionHost.RawContribution) !void {
    try writer.writeAll("{");
    if (contribution.key) |key| {
        try writer.writeAll("\"key\":");
        try writeJsonString(writer, key);
        try writer.writeAll(",");
    }
    try writer.writeAll("\"value\":");
    try writer.writeAll(contribution.raw);
    try writer.writeAll("}");
}

fn writeJsonStringArray(writer: anytype, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeByte(']');
}

fn selectKeybinding(kb: ExtensionHost.KeybindingContribution, platform: []const u8) []const u8 {
    if (std.mem.eql(u8, platform, "linux")) return kb.linux orelse kb.key;
    if (std.mem.eql(u8, platform, "mac") or std.mem.eql(u8, platform, "darwin")) return kb.mac orelse kb.key;
    if (std.mem.eql(u8, platform, "win") or std.mem.eql(u8, platform, "windows")) return kb.win orelse kb.key;
    return kb.key;
}

fn joinExtensionPath(allocator: Allocator, base: []const u8, relative: []const u8) ![]u8 {
    const trimmed = if (std.mem.startsWith(u8, relative, "./")) relative[2..] else relative;
    return std.fs.path.join(allocator, &.{ base, trimmed });
}

fn writeSmokeTokens(writer: anytype, source: []const u8, scope: []const u8) !void {
    var first = true;
    var line: usize = 0;
    var character: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if (c == '\n') {
            line += 1;
            character = 0;
            i += 1;
            continue;
        }
        if (!isWordByte(c)) {
            character += 1;
            i += 1;
            continue;
        }
        const start_index = i;
        const start_character = character;
        while (i < source.len and isWordByte(source[i])) : (i += 1) {
            character += 1;
        }
        const word = source[start_index..i];
        if (!isSmokeKeyword(word)) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"text\":");
        try writeJsonString(writer, word);
        try writer.writeAll(",\"scope\":");
        try writeJsonString(writer, scope);
        try writer.print(",\"line\":{},\"startCharacter\":{},\"endCharacter\":{}", .{ line, start_character, character });
        try writer.writeAll("}");
    }
}

fn isWordByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isSmokeKeyword(word: []const u8) bool {
    return std.mem.eql(u8, word, "smoke") or std.mem.eql(u8, word, "ember");
}

fn unescapeJsonString(allocator: Allocator, raw: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c != '\\' or i + 1 >= raw.len) {
            try out.append(c);
            continue;
        }
        i += 1;
        switch (raw[i]) {
            'n' => try out.append('\n'),
            'r' => try out.append('\r'),
            't' => try out.append('\t'),
            '"' => try out.append('"'),
            '\\' => try out.append('\\'),
            'b' => try out.append('\\'),
            else => {
                try out.append('\\');
                try out.append(raw[i]);
            },
        }
    }
    return try out.toOwnedSlice();
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try ContentLength.writeJsonString(writer, s);
}
