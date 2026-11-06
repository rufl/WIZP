export function getIcon(name: string): string {
  if (!name) return 'codicon-file';
  const lower = name.toLowerCase();
  // Special filenames
  const specials: Record<string, string> = {
    makefile: 'codicon-gear',
    dockerfile: 'codicon-container',
    '.gitignore': 'codicon-git-ignore',
    '.env': 'codicon-archive',
    license: 'codicon-law',
    'readme.md': 'codicon-book',
    'package.json': 'codicon-package',
    'cargo.toml': 'codicon-package',
    'build.zig': 'codicon-gear',
  };
  for (const [k, v] of Object.entries(specials)) {
    if (lower.includes(k)) return v;
  }
  // By extension
  const ext = name.split('.').pop()?.toLowerCase() || '';
  const extMap: Record<string, string> = {
    ts: 'codicon-symbol-namespace',
    tsx: 'codicon-symbol-ruler',
    js: 'codicon-symbol-namespace',
    jsx: 'codicon-symbol-ruler',
    zig: 'codicon-symbol-structure',
    rs: 'codicon-symbol-structure',
    go: 'codicon-symbol-structure',
    c: 'codicon-symbol-structure',
    cpp: 'codicon-symbol-structure',
    h: 'codicon-symbol-header',
    hpp: 'codicon-symbol-header',
    py: 'codicon-symbol-namespace',
    rb: 'codicon-ruby',
    java: 'codicon-symbol-class',
    json: 'codicon-json',
    yaml: 'codicon-settings',
    yml: 'codicon-settings',
    toml: 'codicon-settings',
    xml: 'codicon-code',
    html: 'codicon-file-code',
    htm: 'codicon-file-code',
    css: 'codicon-symbol-color',
    scss: 'codicon-symbol-color',
    less: 'codicon-symbol-color',
    svg: 'codicon-file-media',
    png: 'codicon-file-media',
    jpg: 'codicon-file-media',
    jpeg: 'codicon-file-media',
    gif: 'codicon-file-media',
    ico: 'codicon-file-media',
    md: 'codicon-markdown',
    txt: 'codicon-file-text',
    log: 'codicon-output',
    lock: 'codicon-lock',
    gitignore: 'codicon-git-ignore',
    gitmodules: 'codicon-git-merge',
    sh: 'codicon-terminal',
    bash: 'codicon-terminal',
    zsh: 'codicon-terminal',
    fish: 'codicon-terminal',
    ps1: 'codicon-terminal-powershell',
  };
  return extMap[ext] || 'codicon-file';
}
