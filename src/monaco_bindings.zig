pub export fn initializeMonaco() void {
    const js =
        "() => {" ++
        "    // Wait until globalThis.monaco is available" ++
        "    const interval = setInterval(() => {" ++
        "        if (typeof monaco !== 'undefined') {" ++
        "            clearInterval(interval);" ++
        "            setupMonacoLanguage();" ++
        "        }" ++
        "    }, 100);" ++
        "}";
    _ = js;
    JSC.Javascript.bunGlobal().call(.function, @as([*:0]const u8, @ptrCast(js.ptr)), .{});
}

fn setupMonacoLanguage() void {
    const js =
        "function() {" ++
        "    // Register Zig language" ++
        "    monaco.languages.register({ id: 'zig' });" ++
        "    // Set language configuration" ++
        "    monaco.languages.setLanguageConfiguration('zig', {" ++
        "        comments: { lineComment: '//', blockComment: ['/*', '*/'] }," ++
        "        brackets: [['(', ')'], ['[', ']'], ['{', '}']]," ++
        "        autoClosingPairs: [" ++
        "            { open: '{', close: '}' }," ++
        "            { open: '[', close: ']' }," ++
        "            { open: '(', close: ')' }," ++
        "            { open: '\"', close: '\"' }" ++
        "        ]" ++
        "    });" ++
        "    // Set tokenization" ++
        "    monaco.languages.setMonarchTokensProvider('zig', {" ++
        "        tokenizer: {" ++
        "            root: [" ++
        "                [/\\/\\/.*/, 'comment']," ++
        "                [/\\/\\*/, 'comment', '@comment']," ++
        "                [/\\b(const|var|fn|return|if|else|while|for|break|continue)\\b/, 'keyword']," ++
        "                [/[a-zA-Z_][a-zA-Z0-9_]*/, 'identifier']," ++
        "                [/\\d+/, 'number']" ++
        "            ]," ++
        "            comment: [" ++
        "                [/\\*\\//, 'comment', '@pop']," ++
        "                [/.*?/, 'comment']" ++
        "            ]" ++
        "        }" ++
        "    });" ++
        "}";
    _ = js;
    JSC.Javascript.bunGlobal().call(.function, @as([*:0]const u8, @ptrCast(js.ptr)), .{});
}

pub export fn createEditor(container_id: [*:0]const u8, initial_code: [*:0]const u8) void {
    _ = container_id;
    _ = initial_code;
    const js_container_id = bun.jsString(container_id);
    const js_initial_code = bun.jsString(initial_code);
    _ = js_container_id;
    _ = js_initial_code;

    const js =
        "function(containerId, initialCode) {" ++
        "    const container = document.getElementById(containerId);" ++
        "    if (container && typeof monaco !== 'undefined') {" ++
        "        monaco.editor.create(container, {" ++
        "            value: initialCode," ++
        "            language: 'zig'," ++
        "            theme: 'vs-dark'," ++
        "            automaticLayout: true," ++
        "            minimap: { enabled: false }" ++
        "        });" ++
        "    }" ++
        "}";
    JSC.Javascript.bunGlobal().call(.function, @as([*:0]const u8, @ptrCast(js.ptr)), .{});
}
