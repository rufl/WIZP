import { themeList, themeApply, iconThemeList, iconThemeApply, sendRpc } from '../bridge.ts';

let activeTheme = localStorage.getItem('wizp-theme') || 'one-dark';
let activeIconTheme = localStorage.getItem('wizp-icon-theme') || '';

export function getActiveTheme() {
  return activeTheme;
}
export function getActiveIconTheme() {
  return activeIconTheme;
}

function monacoColor(value: string, fallback: string) {
  const rgb = value.match(/^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i);
  if (rgb) {
    return `#${rgb
      .slice(1, 4)
      .map((channel) => Number(channel).toString(16).padStart(2, '0'))
      .join('')}`;
  }
  return /^#[0-9a-f]{6,8}$/i.test(value) ? value : fallback;
}

export async function applyTheme(name: string) {
  const result = await themeApply(name);

  activeTheme = name;
  localStorage.setItem('wizp-theme', name);

  try {
    const cfg = JSON.parse(localStorage.getItem('wizp-settings') || '{}');
    cfg.theme = name;
    localStorage.setItem('wizp-settings', JSON.stringify(cfg));
  } catch {
    // Settings persistence is best effort; the in-memory selection still applies.
  }

  const bg = result?.background || '#1e1e1e';
  const fg = result?.foreground || '#cccccc';
  const sel = result?.selection || '#264f78';

  // Derive missing common colors for better consistency across themes
  const derived = {
    // Core
    breadcrumbBg: result?.breadcrumbBg || bg,
    breadcrumbFg: result?.breadcrumbFg || fg,
    menuBg: result?.menuBg || bg,
    menuFg: result?.menuFg || fg,
    menubarSelBg: result?.menubarSelBg || 'rgba(255,255,255,0.08)',
    actActiveBg: result?.actActiveBg || result?.activityBarBg || '#2c2c2c',
    tabBorder: result?.tabBorder || bg,
    tabHoverBg: result?.tabHoverBg || 'rgba(255,255,255,0.06)',

    // Additional derived for better parity
    statusBarNoFolderBg: result?.statusBarNoFolderBg || '#68217a',
    editorLineHighlight: result?.editorLineHighlight || (bg === '#1e1e1e' ? '#2a2d2e' : '#f0f0f0'),
    panelTabActiveBorder: result?.panelTabActiveBorder || '#007acc',

    // New from expanded extraction
    focusBorder: result?.focusBorder || '#007acc',
    sideBarBg: result?.sideBarBg || bg,
    sideBarFg: result?.sideBarFg || fg,
    panelBg: result?.panelBg || bg,
    actActiveBorder: result?.actActiveBorder || '#ffffff',
    actBadgeBg: result?.actBadgeBg || '#007acc',
    tabActiveBorder: result?.tabActiveBorder || '#007acc',
    scrollSlider: result?.scrollSlider || '#424242',
    scrollHover: result?.scrollHover || '#4f4f4f',
  };

  const m = (window as any).monaco;
  if (m && result) {
    const themeName = 'wizp-' + name.replace(/[^a-z0-9-]/g, '');
    try {
      m.editor.defineTheme(themeName, {
        base: name.includes('light') ? 'vs' : 'vs-dark',
        inherit: true,
        colors: {
          'editor.background': monacoColor(bg, '#1e1e1e'),
          'editor.foreground': monacoColor(fg, '#cccccc'),
          'editor.selectionBackground': monacoColor(sel, '#264f78'),
          'editorCursor.foreground': monacoColor(fg, '#cccccc'),
          'editor.lineHighlightBackground': monacoColor(derived.editorLineHighlight, '#2a2d2e'),
          'editorLineNumber.foreground': '#858585',
          'editorLineNumber.activeForeground': '#c6c6c6',
          'editorWidget.background': monacoColor(bg, '#1e1e1e'),
          'editorWidget.border': monacoColor(derived.focusBorder, '#007acc'),
          focusBorder: monacoColor(derived.focusBorder, '#007acc'),
        },
        rules: result.rules || [],
      });
      m.editor.setTheme(themeName);
    } catch {
      // CSS theme updates still apply if Monaco rejects extension-provided color data.
    }

    // Robust fallback: force background on all editor instances + inner layers + containers
    document.querySelectorAll('.monaco-editor, #editor-container').forEach((el) => {
      const htmlEl = el as HTMLElement;
      htmlEl.style.backgroundColor = bg;
      const bgLayer = htmlEl.querySelector('.monaco-editor-background') as HTMLElement;
      if (bgLayer) bgLayer.style.backgroundColor = bg;
    });

    // Force layout on open editors (new state) so the theme change repaints immediately
    if ((window as any).groupPanes) {
      Object.values((window as any).groupPanes).forEach((p: any) => {
        if (p?.editor) {
          try {
            p.editor.layout();
          } catch {
            // A disposed editor may reject layout refresh during theme changes.
          }
        }
      });
    }
  }

  if (result) {
    document.documentElement.style.colorScheme = name.includes('light') ? 'light' : 'dark';

    // Core
    document.documentElement.style.setProperty('--bg', bg);
    document.documentElement.style.setProperty('--fg', fg);
    document.documentElement.style.setProperty('--panel-bg', derived.panelBg);
    document.documentElement.style.setProperty('--sidebar-bg', derived.sideBarBg);
    document.documentElement.style.setProperty('--sidebar-fg', derived.sideBarFg);
    document.documentElement.style.setProperty('--editor-bg', bg);
    document.documentElement.style.setProperty('--editor-fg', fg);
    document.documentElement.style.setProperty('--editor-selection', sel);
    document.documentElement.style.setProperty(
      '--editor-line-highlight',
      derived.editorLineHighlight,
    );
    document.documentElement.style.setProperty('--editor-cursor', fg);
    document.documentElement.style.setProperty('--editor-line-number', '#858585');
    document.documentElement.style.setProperty('--editor-line-number-active', '#c6c6c6');

    // Activity bar (full)
    document.documentElement.style.setProperty(
      '--activity-bar-bg',
      result.activityBarBg || '#2c2c2c',
    );
    document.documentElement.style.setProperty('--activity-bar-fg', result.activityBarFg || fg);
    document.documentElement.style.setProperty(
      '--activity-bar-inactive-fg',
      result.activityBarInactiveFg || '#888888',
    );
    document.documentElement.style.setProperty(
      '--activity-bar-active-border',
      derived.actActiveBorder,
    );
    document.documentElement.style.setProperty('--activity-bar-active-bg', derived.actActiveBg);
    document.documentElement.style.setProperty('--activity-bar-badge-bg', derived.actBadgeBg);

    // Status bar
    document.documentElement.style.setProperty('--status-bar-bg', result.statusBarBg || '#007acc');
    document.documentElement.style.setProperty('--status-bar-fg', result.statusBarFg || '#ffffff');
    document.documentElement.style.setProperty('--status-bar-dim', '#bbbbbb');
    document.documentElement.style.setProperty(
      '--status-bar-no-folder-bg',
      derived.statusBarNoFolderBg,
    );

    // Titlebar
    document.documentElement.style.setProperty('--titlebar-bg', result.titleBarBg || '#3c3c3c');
    document.documentElement.style.setProperty('--titlebar-fg', result.titleBarFg || fg);

    // Panel / dividers
    document.documentElement.style.setProperty('--panel-border', result.panelBorder || '#3c3c3c');
    document.documentElement.style.setProperty('--panel-tab-active-fg', fg);
    document.documentElement.style.setProperty('--panel-tab-inactive-fg', '#969696');
    document.documentElement.style.setProperty(
      '--panel-tab-active-border',
      derived.panelTabActiveBorder,
    );

    // Tabs (full set)
    document.documentElement.style.setProperty('--tab-bg', derived.tabBorder);
    document.documentElement.style.setProperty('--tab-active-bg', result.tabActiveBg || bg);
    document.documentElement.style.setProperty('--tab-active-fg', result.tabActiveFg || fg);
    document.documentElement.style.setProperty(
      '--tab-inactive-fg',
      result.tabInactiveFg || '#969696',
    );
    document.documentElement.style.setProperty('--tab-border', derived.tabBorder);
    document.documentElement.style.setProperty(
      '--tab-active-border-top',
      result.tabActiveBorderTop || '#007acc',
    );
    document.documentElement.style.setProperty('--tab-active-border', derived.tabActiveBorder);
    document.documentElement.style.setProperty('--tab-hover-bg', derived.tabHoverBg);

    // Breadcrumbs (common missing piece)
    document.documentElement.style.setProperty('--breadcrumb-bg', derived.breadcrumbBg);
    document.documentElement.style.setProperty('--breadcrumb-fg', derived.breadcrumbFg);
    document.documentElement.style.setProperty('--breadcrumb-dim', derived.breadcrumbFg);

    // Menu / menubar
    document.documentElement.style.setProperty('--menu-bg', derived.menuBg);
    document.documentElement.style.setProperty('--menu-fg', derived.menuFg);

    // Scrollbars
    document.documentElement.style.setProperty('--scrollbar-bg', 'transparent');
    document.documentElement.style.setProperty('--scrollbar-fg', derived.scrollSlider);
    document.documentElement.style.setProperty('--scrollbar-hover', derived.scrollHover);

    // Accent / focus (used for focus rings, links, etc.)
    document.documentElement.style.setProperty('--accent', derived.focusBorder);
  }

  return result;
}

export async function renderThemes(content: HTMLElement) {
  content.style.padding = '8px 12px';
  content.innerHTML = `
    <div style="font-size:11px;color:var(--breadcrumb-dim);margin-bottom:4px;font-weight:600;">COLOR THEMES</div>
    <div id="theme-list" style="margin-bottom:16px;"></div>
    <div style="font-size:11px;color:var(--breadcrumb-dim);margin-bottom:4px;font-weight:600;">FILE ICON THEMES</div>
    <div id="icon-theme-list"></div>
  `;

  // Color themes
  const list = document.getElementById('theme-list')!;
  try {
    const res = await themeList();
    renderThemeList(list, res.themes, activeTheme, 'theme');
  } catch {
    list.innerHTML = '<div style="color:var(--error);font-size:12px;">Failed to load themes</div>';
  }

  // Icon themes
  const iconList = document.getElementById('icon-theme-list')!;
  try {
    const res = await iconThemeList();
    const contributions = await sendRpc('extension/languageContributions', {});
    const contributed = (contributions?.iconThemes || [])
      .map((theme: any) => theme.id)
      .filter(Boolean);
    const all = [
      activeIconTheme ? 'default' : '',
      ...(res.iconThemes || []),
      ...contributed,
    ].filter(Boolean);
    renderThemeList(iconList, all, activeIconTheme || 'default', 'icon');
  } catch {
    iconList.innerHTML =
      '<div style="color:var(--breadcrumb-dim);font-size:12px;">No icon themes installed</div>';
  }
}

function renderThemeList(
  container: HTMLElement,
  themes: string[],
  active: string,
  kind: 'theme' | 'icon',
) {
  container.innerHTML = themes
    .map((t) => {
      const isActive = t === active;
      const preview = kind === 'theme' ? getPreviewColors(t) : { bg: '#333', fg: '#ccc' };
      return `<div class="tree-row theme-item" data-theme="${t}" data-kind="${kind}" style="display:flex;align-items:center;gap:8px;padding:6px 4px;border-radius:4px;cursor:pointer;${isActive ? 'background:var(--editor-selection);' : ''}">
      <div style="width:20px;height:20px;border-radius:3px;border:1px solid #555;display:flex;align-items:center;justify-content:center;overflow:hidden;flex-shrink:0;">
        <span style="display:block;width:100%;height:100%;background:${preview.bg};"></span>
      </div>
      <span style="flex:1;font-size:12px;color:${isActive ? 'var(--fg)' : 'var(--breadcrumb-dim)'};font-weight:${isActive ? '600' : '400'};">${t}</span>
      ${isActive ? '<span class="codicon codicon-check" style="color:var(--info);font-size:14px;"></span>' : ''}
    </div>`;
    })
    .join('');

  container.querySelectorAll('.theme-item').forEach((el) => {
    (el as HTMLElement).onclick = async () => {
      const name = (el as HTMLElement).dataset.theme!;
      const kind = (el as HTMLElement).dataset.kind! as 'theme' | 'icon';
      if (name === active) return;
      try {
        if (kind === 'theme') {
          await applyTheme(name);
        } else {
          activeIconTheme = name === 'default' ? '' : name;
          if (activeIconTheme) await iconThemeApply(activeIconTheme).catch(() => null);
          localStorage.setItem('wizp-icon-theme', activeIconTheme);
          // Dispatch event so explorer can refresh icons
          window.dispatchEvent(
            new CustomEvent('icon-theme-changed', { detail: { name: activeIconTheme } }),
          );
        }
        renderThemes(container.parentElement as HTMLElement); // refresh
      } catch (err: any) {
        console.error('Theme apply failed:', err);
      }
    };
  });
}

function getPreviewColors(name: string): { bg: string; fg: string } {
  const map: Record<string, string> = {
    'one-dark': '#282c34',
    'one-light': '#fafafa',
    monokai: '#272822',
    dracula: '#282a36',
    nord: '#2e3440',
    'solarized-dark': '#002b36',
    'solarized-light': '#fdf6e3',
    'gruvbox-dark': '#282828',
    'gruvbox-light': '#fbf1c7',
    'catppuccin-mocha': '#1e1e2e',
    'catppuccin-latte': '#eff1f5',
    'tokyo-night': '#1a1b26',
    'tokyo-night-storm': '#24283b',
    'ayu-dark': '#0d1017',
    'ayu-mirage': '#1f2430',
    'github-dark': '#0d1117',
    'github-light': '#ffffff',
    'material-darker': '#212121',
    palenight: '#292d3e',
    'oceanic-next': '#1b2b34',
    zenburn: '#383838',
    molokai: '#1b1b1b',
    paseo: '#000000',
  };
  return { bg: map[name] || '#1e1e1e', fg: '#ccc' };
}
