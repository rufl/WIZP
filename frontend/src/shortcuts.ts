export const SHORTCUTS = {
  'file.new': { keys: 'Ctrl+N', label: 'New File' },
  'file.open': { keys: 'Ctrl+O', label: 'Open File' },
  'file.save': { keys: 'Ctrl+S', label: 'Save' },
  'file.saveAs': { keys: 'Ctrl+Shift+S', label: 'Save As...' },
  'file.close': { keys: 'Ctrl+W', label: 'Close Editor' },
  'file.quit': { keys: 'Ctrl+Q', label: 'Exit' },
  'preferences.settings': { keys: 'Ctrl+,', label: 'Settings' },
  'command.palette': { keys: 'Ctrl+Shift+P', label: 'Command Palette' },
  'quick.open': { keys: 'Ctrl+P', label: 'Quick Open' },
  'go.symbols.editor': { keys: 'Ctrl+Shift+O', label: 'Go to Symbol in Editor' },
  'go.symbols.workspace': { keys: 'Ctrl+T', label: 'Go to Symbol in Workspace' },
  'go.line': { keys: 'Ctrl+G', label: 'Go to Line' },
  'view.explorer': { keys: 'Ctrl+Shift+E', label: 'Explorer' },
  'view.search': { keys: 'Ctrl+Shift+F', label: 'Search' },
  'view.scm': { keys: 'Ctrl+Shift+G', label: 'Source Control' },
  'view.debug': { keys: 'Ctrl+Shift+D', label: 'Run and Debug' },
  'view.extensions': { keys: 'Ctrl+Shift+X', label: 'Extensions' },
  'view.sidebar': { keys: 'Ctrl+B', label: 'Toggle Sidebar' },
  'view.panel': { keys: 'Ctrl+J', label: 'Toggle Panel' },
  'editor.split': { keys: 'Ctrl+\\', label: 'Split Editor' },
  'editor.find': { keys: 'Ctrl+F', label: 'Find in File' },
  'editor.replace': { keys: 'Ctrl+H', label: 'Replace in File' },
  'editor.undo': { keys: 'Ctrl+Z', label: 'Undo' },
  'editor.redo': { keys: 'Ctrl+Y', label: 'Redo' },
  'editor.selectAll': { keys: 'Ctrl+A', label: 'Select All' },
  'editor.format': { keys: 'Shift+Alt+F', label: 'Format Document' },
  'editor.wordWrap': { keys: 'Alt+Z', label: 'Toggle Word Wrap' },
  'editor.definition': { keys: 'F12', label: 'Go to Definition' },
  'editor.peekDefinition': { keys: 'Alt+F12', label: 'Peek Definition' },
  'editor.references': { keys: 'Shift+F12', label: 'Go to References' },
  'editor.cycleTabs': { keys: 'Ctrl+Tab', label: 'Cycle Editor Tabs' },
  'terminal.new': { keys: 'Ctrl+`', label: 'New Terminal' },
  'debug.start': { keys: 'F5', label: 'Start Debugging' },
  'debug.run': { keys: 'Ctrl+F5', label: 'Run Without Debugging' },
  'debug.stop': { keys: 'Shift+F5', label: 'Stop Debugging' },
  'debug.breakpoint': { keys: 'F9', label: 'Toggle Breakpoint' },
} as const;

export type ShortcutId = keyof typeof SHORTCUTS;

export const WELCOME_SHORTCUTS: ShortcutId[] = [
  'file.open',
  'file.save',
  'quick.open',
  'command.palette',
  'view.sidebar',
  'view.panel',
  'editor.find',
  'view.search',
  'editor.split',
  'terminal.new',
];

export function shortcutFor(id: ShortcutId): string {
  return SHORTCUTS[id].keys;
}

function normalizeShortcut(value: string): string {
  return value.toLowerCase().replace(/\s+/g, '').replaceAll('cmd', 'ctrl');
}

function eventShortcut(event: KeyboardEvent): string {
  const key = event.code === 'Backquote' ? '`' : event.code === 'Backslash' ? '\\' : event.key;
  const parts = [
    ...(event.ctrlKey || event.metaKey ? ['Ctrl'] : []),
    ...(event.shiftKey ? ['Shift'] : []),
    ...(event.altKey ? ['Alt'] : []),
    key,
  ];
  return parts.join('+');
}

export function shortcutIdForEvent(event: KeyboardEvent): ShortcutId | undefined {
  const key = normalizeShortcut(eventShortcut(event));
  return (Object.keys(SHORTCUTS) as ShortcutId[]).find(
    (id) => normalizeShortcut(SHORTCUTS[id].keys) === key,
  );
}
