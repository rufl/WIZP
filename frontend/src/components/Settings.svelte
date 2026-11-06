<script lang="ts">
  import { tick } from 'svelte';
  import { themeList, configGet, configSet } from '../../bridge';
  import { sendRpc } from '../../bridge';
  import { applyTheme } from '../themes';
  import { SHORTCUTS } from '../shortcuts';
  import LoadingButton from './LoadingButton.svelte';

  type SettingsConfig = {
    theme: string;
    fontSize: number;
    fontFamily: string;
    tabSize: number;
    minimap: boolean;
    formatOnSave: boolean;
    autoSave: boolean;
    wordWrap: string;
    wordWrapColumn: number;
    lineNumbers: boolean;
    cursorStyle: string;
    bracketPairColorization: boolean;
    renderWhitespace: string;
  };

  type ExtensionSetting = {
    key: string;
    title?: string;
    type: string;
    default?: unknown;
    description?: string;
    value: unknown;
  };

  type SettingsMessage = { kind: 'status' | 'warning' | 'error'; text: string };

  const FONT_FAMILIES = [
    "'Cascadia Code', monospace",
    "'Fira Code', monospace",
    "'JetBrains Mono', monospace",
    "'Source Code Pro', monospace",
    "'Inconsolata', monospace",
    "'Consolas', monospace",
    'monospace',
  ];

  const CURSOR_STYLES = [
    'line',
    'block',
    'underline',
    'line-thin',
    'block-outline',
    'underline-thin',
  ];

  const DEFAULT_SETTINGS: SettingsConfig = {
    theme: 'one-dark',
    fontSize: 14,
    fontFamily: "'Cascadia Code', monospace",
    tabSize: 4,
    minimap: true,
    formatOnSave: true,
    autoSave: false,
    wordWrap: 'off',
    wordWrapColumn: 80,
    lineNumbers: true,
    cursorStyle: 'line',
    bracketPairColorization: true,
    renderWhitespace: 'selection',
  };

  function storedObject(key: string): Record<string, any> {
    try {
      const value = JSON.parse(localStorage.getItem(key) || '{}');
      return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
    } catch {
      return {};
    }
  }

  function boundedNumber(value: unknown, fallback: number, min: number, max: number) {
    const number = Number(value);
    return Number.isFinite(number) && number >= min && number <= max ? number : fallback;
  }

  function storedSettings(): SettingsConfig {
    const saved = storedObject('wizp-settings');
    return {
      theme: typeof saved.theme === 'string' ? saved.theme : DEFAULT_SETTINGS.theme,
      fontSize: boundedNumber(saved.fontSize, DEFAULT_SETTINGS.fontSize, 8, 32),
      fontFamily:
        typeof saved.fontFamily === 'string' ? saved.fontFamily : DEFAULT_SETTINGS.fontFamily,
      tabSize: boundedNumber(saved.tabSize, DEFAULT_SETTINGS.tabSize, 1, 16),
      minimap: typeof saved.minimap === 'boolean' ? saved.minimap : DEFAULT_SETTINGS.minimap,
      formatOnSave:
        typeof saved.formatOnSave === 'boolean'
          ? saved.formatOnSave
          : DEFAULT_SETTINGS.formatOnSave,
      autoSave: typeof saved.autoSave === 'boolean' ? saved.autoSave : DEFAULT_SETTINGS.autoSave,
      wordWrap: typeof saved.wordWrap === 'string' ? saved.wordWrap : DEFAULT_SETTINGS.wordWrap,
      wordWrapColumn: boundedNumber(saved.wordWrapColumn, DEFAULT_SETTINGS.wordWrapColumn, 20, 240),
      lineNumbers:
        typeof saved.lineNumbers === 'boolean' ? saved.lineNumbers : DEFAULT_SETTINGS.lineNumbers,
      cursorStyle:
        typeof saved.cursorStyle === 'string' ? saved.cursorStyle : DEFAULT_SETTINGS.cursorStyle,
      bracketPairColorization:
        typeof saved.bracketPairColorization === 'boolean'
          ? saved.bracketPairColorization
          : DEFAULT_SETTINGS.bracketPairColorization,
      renderWhitespace:
        typeof saved.renderWhitespace === 'string'
          ? saved.renderWhitespace
          : DEFAULT_SETTINGS.renderWhitespace,
    };
  }

  function hasStoredSettings() {
    try {
      return Boolean(localStorage.getItem('wizp-settings'));
    } catch {
      return false;
    }
  }

  const { isOpen = false, onClose } = $props<{ isOpen?: boolean; onClose: () => void }>();

  let config = $state<SettingsConfig>(storedSettings());
  let themes = $state<string[]>([]);
  let extensionSettings = $state<ExtensionSetting[]>([]);
  let contributedKeybindings = $state<any[]>([]);
  let loading = $state(true);
  let loadWarning = $state('');
  let saving = $state(false);
  let saveMessage = $state<SettingsMessage | null>(null);
  let retrySave = $state(false);
  let dialog = $state<HTMLElement>();
  let closeButton = $state<HTMLButtonElement>();
  let saveButton = $state<HTMLButtonElement>();
  let loadTicket = 0;
  let settingsReconnectPending = false;
  let settingsReconnectTimers: number[] = [];

  function platformName() {
    const platform = navigator.platform.toLowerCase();
    if (platform.includes('mac')) return 'mac';
    if (platform.includes('win')) return 'win';
    return 'linux';
  }

  function clearSettingsReconnectTimers() {
    for (const timer of settingsReconnectTimers) window.clearTimeout(timer);
    settingsReconnectTimers = [];
  }

  async function loadSettings(preserveDraft = false) {
    const ticket = ++loadTicket;
    const hadStoredSettings = hasStoredSettings();
    const draftExtensionValues = preserveDraft
      ? new Map(extensionSettings.map((setting) => [setting.key, setting.value]))
      : null;
    const draftKeybindingValues = preserveDraft
      ? new Map(contributedKeybindings.map((kb) => [kb.command, kb.effectiveKey]))
      : null;
    const extensionValues = storedObject('wizp-extension-settings');
    const keybindingOverrides = storedObject('wizp-keybinding-overrides');
    if (!preserveDraft) {
      config = storedSettings();
      themes = [];
      extensionSettings = [];
      contributedKeybindings = [];
    }
    loading = true;
    if (!preserveDraft) {
      loadWarning = '';
      saveMessage = null;
      retrySave = false;
    }

    const [themeResult, configResult, extensionResult, keybindingResult] = await Promise.allSettled(
      [
        themeList(),
        configGet(),
        sendRpc('extension/configuration', {}),
        sendRpc('extension/keybindings', { platform: platformName() }),
      ],
    );
    if (ticket !== loadTicket) return;

    const unavailable: string[] = [];
    if (themeResult.status === 'fulfilled') {
      themes = themeResult.value?.themes || [];
    } else {
      themes = [config.theme];
      unavailable.push('themes');
    }
    if (
      !hadStoredSettings &&
      !preserveDraft &&
      configResult.status === 'fulfilled' &&
      configResult.value?.tabWidth
    ) {
      config.tabSize = configResult.value.tabWidth;
    } else if (configResult.status === 'rejected') {
      unavailable.push('backend defaults');
    }
    if (extensionResult.status === 'fulfilled') {
      extensionSettings = (extensionResult.value?.configuration || []).map((setting: any) => ({
        ...setting,
        value:
          preserveDraft && draftExtensionValues?.has(setting.key)
            ? draftExtensionValues.get(setting.key)
            : Object.hasOwn(extensionValues, setting.key)
              ? extensionValues[setting.key]
              : setting.default,
      }));
    } else {
      unavailable.push('extension settings');
    }
    if (keybindingResult.status === 'fulfilled') {
      contributedKeybindings = (keybindingResult.value?.keybindings || []).map((kb: any) => ({
        ...kb,
        effectiveKey:
          preserveDraft && draftKeybindingValues?.has(kb.command)
            ? draftKeybindingValues.get(kb.command)
            : keybindingOverrides[kb.command] || kb.key,
      }));
    } else {
      unavailable.push('extension keybindings');
    }
    if (unavailable.length === 0) clearSettingsReconnectTimers();
    loadWarning = unavailable.length
      ? `Some settings sources are unavailable: ${unavailable.join(', ')}. Local preferences remain editable.`
      : '';
    loading = false;
    retrySettingsAfterReconnect();
  }

  function retrySettingsAfterReconnect() {
    if (!settingsReconnectPending || !isOpen || loading || saving) return;
    settingsReconnectPending = false;
    void loadSettings(true);
  }

  $effect(() => {
    if (isOpen) void loadSettings();
    else loadTicket++;
  });

  $effect(() => {
    const handleDaemonDisconnected = () => {
      if (isOpen) loadWarning = 'Settings backend disconnected. Reconnecting…';
    };
    const handleDaemonReconnected = () => {
      settingsReconnectPending = true;
      retrySettingsAfterReconnect();
      clearSettingsReconnectTimers();
      for (const delay of [250, 750, 1500]) {
        settingsReconnectTimers.push(
          window.setTimeout(() => {
            if (!isOpen || saving) return;
            settingsReconnectPending = true;
            retrySettingsAfterReconnect();
          }, delay),
        );
      }
    };
    window.addEventListener('wizpDaemonDisconnected', handleDaemonDisconnected);
    window.addEventListener('wizpDaemonReconnected', handleDaemonReconnected);
    return () => {
      window.removeEventListener('wizpDaemonDisconnected', handleDaemonDisconnected);
      clearSettingsReconnectTimers();
      window.removeEventListener('wizpDaemonReconnected', handleDaemonReconnected);
    };
  });

  $effect(() => {
    if (!isOpen) return;
    const returnFocus =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;
    void tick().then(() => closeButton?.focus());
    return () => returnFocus?.isConnected && returnFocus.focus();
  });

  $effect(() => {
    if (!isOpen || !retrySave || saving || loading) return;
    void tick().then(() => focusSaveButton());
    const timer = window.setInterval(focusSaveButton, 100);
    return () => window.clearInterval(timer);
  });

  function close() {
    if (!saving) onClose();
  }

  function handleKeydown(event: KeyboardEvent) {
    if (event.key === 'Escape') {
      event.preventDefault();
      close();
      return;
    }
    if (event.key !== 'Tab') return;
    const focusable = Array.from(
      dialog.querySelectorAll<HTMLElement>(
        'button:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ),
    ).filter((element) => !element.hidden);
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  function validateSettings() {
    const fields = [
      { id: 'settings-fontsize', label: 'Font size', value: config.fontSize, min: 8, max: 32 },
      { id: 'settings-tabsize', label: 'Tab size', value: config.tabSize, min: 1, max: 16 },
      {
        id: 'settings-wrapcolumn',
        label: 'Word wrap column',
        value: config.wordWrapColumn,
        min: 20,
        max: 240,
      },
    ];
    const invalid = fields.find(
      (field) =>
        !Number.isInteger(Number(field.value)) ||
        Number(field.value) < field.min ||
        Number(field.value) > field.max,
    );
    if (!invalid) return true;
    saveMessage = {
      kind: 'error',
      text: `${invalid.label} must be a whole number from ${invalid.min} to ${invalid.max}.`,
    };
    void tick().then(() => document.getElementById(invalid.id)?.focus());
    return false;
  }

  function extensionValue(setting: ExtensionSetting) {
    if (setting.type === 'boolean') return String(Boolean(setting.value));
    return String(setting.value ?? '');
  }
  function focusSaveButton(attempt = 0) {
    const button = document.getElementById('settings-save-button') as HTMLButtonElement | null;
    if (!button) return;
    if (!button.disabled) button.focus({ preventScroll: true });
    if (attempt < 8 && (button.disabled || document.activeElement !== button)) {
      window.setTimeout(() => focusSaveButton(attempt + 1), 25);
    }
  }

  async function save() {
    if (!validateSettings()) return;
    saving = true;
    retrySave = false;
    saveMessage = { kind: 'status', text: 'Saving settings…' };
    const settings = { ...config };
    try {
      localStorage.setItem('wizp-settings', JSON.stringify(settings));
    } catch {
      saveMessage = {
        kind: 'error',
        text: 'Settings could not be saved locally. Check available storage and try again.',
      };
      saving = false;
      return;
    }
    const overrides: Record<string, string> = {};
    for (const kb of contributedKeybindings) {
      if (kb.effectiveKey && kb.effectiveKey !== kb.key) overrides[kb.command] = kb.effectiveKey;
    }
    try {
      localStorage.setItem('wizp-keybinding-overrides', JSON.stringify(overrides));
      localStorage.setItem(
        'wizp-extension-settings',
        JSON.stringify(
          Object.fromEntries(extensionSettings.map((setting) => [setting.key, setting.value])),
        ),
      );
    } catch {
      saveMessage = {
        kind: 'warning',
        text: 'Editor settings were saved, but extension or keybinding overrides could not be stored locally.',
      };
      saving = false;
      return;
    }
    (window as any).__settingsChanged?.(settings);
    const writes: Array<{ label: string; promise: Promise<unknown> }> = [
      { label: 'tab width', promise: configSet('tabWidth', String(settings.tabSize)) },
      {
        label: 'minimap',
        promise: sendRpc('config/set', {
          key: 'editor.minimap.enabled',
          value: String(settings.minimap),
          scope: 'user',
        }),
      },
      {
        label: 'font size',
        promise: sendRpc('config/set', {
          key: 'editor.fontSize',
          value: String(settings.fontSize),
          scope: 'user',
        }),
      },
      {
        label: 'font family',
        promise: sendRpc('config/set', {
          key: 'editor.fontFamily',
          value: settings.fontFamily,
          scope: 'user',
        }),
      },
      {
        label: 'tab size',
        promise: sendRpc('config/set', {
          key: 'editor.tabSize',
          value: String(settings.tabSize),
          scope: 'user',
        }),
      },
      {
        label: 'line numbers',
        promise: sendRpc('config/set', {
          key: 'editor.lineNumbers',
          value: settings.lineNumbers ? 'on' : 'off',
          scope: 'user',
        }),
      },
      {
        label: 'word wrap',
        promise: sendRpc('config/set', {
          key: 'editor.wordWrap',
          value: settings.wordWrap,
          scope: 'user',
        }),
      },
      {
        label: 'word wrap column',
        promise: sendRpc('config/set', {
          key: 'editor.wordWrapColumn',
          value: String(settings.wordWrapColumn),
          scope: 'user',
        }),
      },
      {
        label: 'cursor style',
        promise: sendRpc('config/set', {
          key: 'editor.cursorStyle',
          value: settings.cursorStyle,
          scope: 'user',
        }),
      },
      {
        label: 'bracket pair colorization',
        promise: sendRpc('config/set', {
          key: 'editor.bracketPairColorization.enabled',
          value: String(settings.bracketPairColorization),
          scope: 'user',
        }),
      },
      {
        label: 'whitespace rendering',
        promise: sendRpc('config/set', {
          key: 'editor.renderWhitespace',
          value: settings.renderWhitespace,
          scope: 'user',
        }),
      },
      {
        label: 'format on save',
        promise: sendRpc('config/set', {
          key: 'editor.formatOnSave',
          value: String(settings.formatOnSave),
          scope: 'user',
        }),
      },
      {
        label: 'auto save',
        promise: sendRpc('config/set', {
          key: 'files.autoSave',
          value: settings.autoSave ? 'afterDelay' : 'off',
          scope: 'user',
        }),
      },
      { label: 'color theme', promise: applyTheme(settings.theme) },
      ...extensionSettings.map((setting) => ({
        label: setting.key,
        promise: sendRpc('config/set', {
          key: setting.key,
          value: extensionValue(setting),
          scope: 'user',
        }),
      })),
    ];
    const settled = await Promise.allSettled(writes.map((write) => write.promise));
    const failed = settled
      .map((result, index) => (result.status === 'rejected' ? writes[index].label : ''))
      .filter(Boolean);
    saving = false;
    if (failed.length > 0) {
      retrySave = true;
      saveMessage = {
        kind: 'warning',
        text: `Saved locally, but ${failed.length} preference${failed.length === 1 ? '' : 's'} could not sync: ${failed.join(', ')}. Retry when the backend is available.`,
      };
      await tick();
      focusSaveButton();
      requestAnimationFrame(() => focusSaveButton());
      return;
    }
    saveMessage = { kind: 'status', text: 'Settings saved.' };
    onClose();
  }
</script>

{#if isOpen}
  <div
    class="settings-backdrop"
    role="presentation"
    onclick={(e) => {
      if (e.target === e.currentTarget) close();
    }}
  >
    <div
      bind:this={dialog}
      id="settings-dialog"
      class="settings-content"
      role="dialog"
      aria-modal="true"
      aria-labelledby="settings-title"
      aria-describedby="settings-description"
      tabindex="-1"
      onkeydown={handleKeydown}
    >
      <div class="settings-header">
        <div>
          <h1 id="settings-title" class="settings-title">Settings</h1>
          <div id="settings-description" class="settings-description">
            Review editor preferences, then save to apply and sync them.
          </div>
        </div>
        <button
          bind:this={closeButton}
          class="settings-close"
          type="button"
          aria-label="Close settings"
          onclick={close}
          disabled={saving}
        >
          <span class="codicon codicon-close" aria-hidden="true"></span>
        </button>
      </div>

      <div class="settings-body" aria-busy={loading || undefined}>
        {#if loadWarning}
          <div class="settings-load-warning" role="status">
            <span>{loadWarning}</span>
            <button type="button" onclick={() => void loadSettings()} disabled={loading || saving}
              >Retry loading</button
            >
          </div>
        {/if}
        <section class="settings-section" aria-labelledby="settings-appearance-title">
          <h2 id="settings-appearance-title" class="settings-section-title">Appearance</h2>

          <div class="settings-field">
            <label for="settings-theme">Color Theme</label>
            {#if loading}
              <div class="settings-loading" role="status">Loading settings…</div>
            {:else if themes.length === 0}
              <div class="settings-loading">No themes are available.</div>
            {:else}
              <select id="settings-theme" bind:value={config.theme} disabled={saving}>
                {#each themes as theme (theme)}
                  <option value={theme}>{theme}</option>
                {/each}
              </select>
            {/if}
          </div>

          <div class="settings-row">
            <div class="settings-field">
              <label for="settings-fontsize">Font Size</label>
              <input
                id="settings-fontsize"
                type="number"
                bind:value={config.fontSize}
                min="8"
                max="32"
                step="1"
                aria-invalid={!Number.isInteger(Number(config.fontSize)) ||
                Number(config.fontSize) < 8 ||
                Number(config.fontSize) > 32
                  ? 'true'
                  : undefined}
                disabled={saving}
              />
            </div>
            <div class="settings-field">
              <label for="settings-tabsize">Tab Size</label>
              <input
                id="settings-tabsize"
                type="number"
                bind:value={config.tabSize}
                min="1"
                max="16"
                step="1"
                aria-invalid={!Number.isInteger(Number(config.tabSize)) ||
                Number(config.tabSize) < 1 ||
                Number(config.tabSize) > 16
                  ? 'true'
                  : undefined}
                disabled={saving}
              />
            </div>
          </div>

          <div class="settings-row">
            <div class="settings-field">
              <label for="settings-wrapcolumn">Word Wrap Column</label>
              <input
                id="settings-wrapcolumn"
                type="number"
                bind:value={config.wordWrapColumn}
                min="20"
                max="240"
                step="1"
                aria-invalid={!Number.isInteger(Number(config.wordWrapColumn)) ||
                Number(config.wordWrapColumn) < 20 ||
                Number(config.wordWrapColumn) > 240
                  ? 'true'
                  : undefined}
                disabled={saving}
              />
            </div>
            <div class="settings-field">
              <label for="settings-whitespace">Render Whitespace</label>
              <select
                id="settings-whitespace"
                bind:value={config.renderWhitespace}
                disabled={saving}
              >
                <option value="none">None</option>
                <option value="boundary">Boundary</option>
                <option value="selection">Selection</option>
                <option value="trailing">Trailing</option>
                <option value="all">All</option>
              </select>
            </div>
          </div>

          <div class="settings-field">
            <label for="settings-fontfamily">Font Family</label>
            <select id="settings-fontfamily" bind:value={config.fontFamily} disabled={saving}>
              {#each FONT_FAMILIES as f (f)}
                <option value={f}>{f.replace(/'/g, '').split(',')[0].trim()}</option>
              {/each}
            </select>
          </div>

          <div class="settings-row">
            <div class="settings-field">
              <label for="settings-cursor">Cursor Style</label>
              <select id="settings-cursor" bind:value={config.cursorStyle} disabled={saving}>
                {#each CURSOR_STYLES as s (s)}
                  <option value={s}>{s}</option>
                {/each}
              </select>
            </div>
            <div class="settings-field">
              <label for="settings-wordwrap">Word Wrap</label>
              <select id="settings-wordwrap" bind:value={config.wordWrap} disabled={saving}>
                <option value="off">Off</option>
                <option value="on">On</option>
                <option value="wordWrapColumn">At Column</option>
                <option value="bounded">Bounded</option>
              </select>
            </div>
          </div>

          <div class="settings-checkbox">
            <input
              id="settings-minimap"
              type="checkbox"
              bind:checked={config.minimap}
              disabled={saving}
            />
            <label for="settings-minimap">Show Minimap</label>
          </div>
          <div class="settings-checkbox">
            <input
              id="settings-linenumbers"
              type="checkbox"
              bind:checked={config.lineNumbers}
              disabled={saving}
            />
            <label for="settings-linenumbers">Show Line Numbers</label>
          </div>
          <div class="settings-checkbox">
            <input
              id="settings-bracketpair"
              type="checkbox"
              bind:checked={config.bracketPairColorization}
              disabled={saving}
            />
            <label for="settings-bracketpair">Bracket Pair Colorization</label>
          </div>
          <div class="settings-checkbox">
            <input
              id="settings-formatonsave"
              type="checkbox"
              bind:checked={config.formatOnSave}
              disabled={saving}
            />
            <label for="settings-formatonsave">Format on Save</label>
          </div>
          <div class="settings-checkbox">
            <input
              id="settings-autosave"
              type="checkbox"
              bind:checked={config.autoSave}
              disabled={saving}
            />
            <label for="settings-autosave">Auto Save (after 1s idle)</label>
          </div>
        </section>

        <section class="settings-section" aria-labelledby="settings-keybindings-title">
          <h2 id="settings-keybindings-title" class="settings-section-title">Keyboard Shortcuts</h2>
          <div class="keybind-list">
            {#each Object.entries(SHORTCUTS) as [id, kb] (id)}
              <div class="keybind-row">
                <span class="keybind-keys">{kb.keys}</span>
                <span class="keybind-desc">{kb.label}</span>
              </div>
            {/each}
            {#each contributedKeybindings as kb (kb.command || kb.key)}
              <div class="keybind-row">
                <input
                  class="keybind-edit"
                  bind:value={kb.effectiveKey}
                  aria-label={'Keybinding for ' + kb.command}
                  disabled={saving}
                />
                <span class="keybind-desc">{kb.command}</span>
              </div>
            {/each}
          </div>
        </section>

        {#if extensionSettings.length > 0}
          <section class="settings-section" aria-labelledby="settings-extensions-title">
            <h2 id="settings-extensions-title" class="settings-section-title">Extensions</h2>
            {#each extensionSettings as setting (setting.key)}
              <div class="settings-field">
                {#if setting.type === 'boolean'}
                  <div class="settings-checkbox">
                    <input
                      id={'setting-' + setting.key}
                      type="checkbox"
                      checked={setting.value === true}
                      disabled={saving}
                      onchange={(e) => {
                        setting.value = (e.currentTarget as HTMLInputElement).checked;
                      }}
                    />
                    <label for={'setting-' + setting.key}
                      >{setting.key}<span class="setting-description"
                        >{setting.description || setting.title}</span
                      ></label
                    >
                  </div>
                {:else}
                  <label for={'setting-' + setting.key}>{setting.key}</label>
                  <input
                    id={'setting-' + setting.key}
                    type={setting.type === 'number' || setting.type === 'integer'
                      ? 'number'
                      : 'text'}
                    value={String(setting.value ?? '')}
                    disabled={saving}
                    oninput={(e) => {
                      const value = (e.currentTarget as HTMLInputElement).value;
                      setting.value =
                        setting.type === 'number' || setting.type === 'integer'
                          ? Number(value)
                          : value;
                    }}
                  />
                  {#if setting.description}<span class="setting-description"
                      >{setting.description}</span
                    >{/if}
                {/if}
              </div>
            {/each}
          </section>
        {/if}
      </div>

      <div class="settings-footer">
        {#if saveMessage}
          <p
            class="settings-save-status"
            class:error={saveMessage.kind === 'error'}
            role={saveMessage.kind === 'error' || saveMessage.kind === 'warning'
              ? 'alert'
              : 'status'}
            aria-live={saveMessage.kind === 'status' ? 'polite' : 'assertive'}
          >
            {saveMessage.text}
          </p>
        {/if}
        <button
          type="button"
          class="btn-secondary"
          disabled={saving}
          onclick={() => {
            close();
            (window as any).__openFileInEditor?.('.wizprc');
          }}>Open Settings (JSON)</button
        >
        <button type="button" class="btn-cancel" onclick={close} disabled={saving}>Cancel</button>
        <LoadingButton
          id="settings-save-button"
          bind:element={saveButton}
          class="btn-primary"
          label={retrySave ? 'Retry Save' : 'Apply & Save'}
          pendingLabel="Saving…"
          pending={saving}
          disabled={loading}
          onclick={save}
        />
      </div>
    </div>
  </div>
{/if}

<style>
  .settings-backdrop {
    position: fixed;
    inset: 0;
    z-index: 99999;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 20px;
    background: rgba(0, 0, 0, 0.5);
  }
  .settings-content {
    width: min(620px, 100%);
    max-height: min(80vh, 760px);
    background: var(--sidebar-bg);
    border: 1px solid var(--panel-border);
    box-shadow: 0 20px 48px rgba(0, 0, 0, 0.6);
    border-radius: 8px;
    font-family: inherit;
    color: var(--fg);
    display: flex;
    flex-direction: column;
    height: 100%;
    outline: none;
    overflow: hidden;
  }
  .settings-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 18px;
    border-bottom: 1px solid var(--panel-border);
  }
  .settings-title {
    margin: 0;
    font-size: 14px;
    font-weight: 600;
  }
  .settings-description {
    margin-top: 2px;
    color: var(--breadcrumb-dim);
    font-size: 11px;
  }
  .settings-close {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 28px;
    min-height: 28px;
    border: 0;
    border-radius: 4px;
    background: transparent;
    cursor: pointer;
    font-size: 16px;
    color: var(--breadcrumb-dim);
  }
  .settings-close:hover {
    color: var(--fg);
  }
  .settings-close:disabled {
    cursor: wait;
    opacity: 0.65;
  }
  .settings-body {
    padding: 16px 20px;
    overflow-y: auto;
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 20px;
    overscroll-behavior: contain;
  }
  .settings-section-title {
    margin: 0 0 8px;
    font-size: 11px;
    color: var(--breadcrumb-dim);
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }
  .settings-field {
    margin-bottom: 12px;
  }
  .settings-field label {
    display: block;
    font-size: 12px;
    margin-bottom: 4px;
    color: var(--fg);
  }
  .settings-field input[type='number'],
  .settings-field input[type='text'],
  .settings-field select {
    width: 100%;
    padding: 6px 8px;
    background: var(--control-bg);
    border: 1px solid var(--control-border);
    color: var(--fg);
    border-radius: 4px;
    box-sizing: border-box;
    font-size: 12px;
  }
  .settings-field select {
    cursor: pointer;
  }
  .settings-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
  }
  .settings-checkbox {
    margin-top: 10px;
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 28px;
  }
  .settings-checkbox input {
    accent-color: var(--accent);
  }
  .settings-checkbox label {
    font-size: 12px;
    cursor: pointer;
  }

  .settings-footer {
    padding: 12px 18px;
    border-top: 1px solid var(--panel-border);
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    background: var(--panel-bg);
    border-radius: 0 0 8px 8px;
    flex-wrap: wrap;
  }
  .settings-save-status {
    flex: 1 1 100%;
    margin: 0 auto 0 0;
    color: var(--warn);
    font-size: 11px;
    line-height: 1.35;
  }
  .settings-save-status.error {
    color: var(--error);
  }
  .settings-load-warning {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 8px 10px;
    border: 1px solid var(--warn);
    border-radius: 4px;
    color: var(--fg);
    font-size: 11px;
    line-height: 1.4;
  }
  .settings-load-warning button {
    min-height: 28px;
    flex-shrink: 0;
    border: 1px solid var(--panel-border);
    border-radius: 4px;
    background: var(--panel-bg);
    color: var(--fg);
    cursor: pointer;
  }
  .settings-loading {
    padding: 8px 10px;
    color: var(--breadcrumb-dim);
    font-size: 12px;
  }
  .setting-description {
    display: block;
    margin-top: 2px;
    color: var(--breadcrumb-dim);
    font-size: 11px;
    line-height: 1.35;
    overflow-wrap: anywhere;
  }
  :global(.btn-primary) {
    background: #0e639c;
    color: white;
    border: none;
    border-radius: 4px;
    padding: 8px 18px;
    font-size: 13px;
    cursor: pointer;
  }
  :global(.btn-primary:hover) {
    background: #1177bb;
  }
  :global(.btn-primary:disabled),
  .btn-cancel:disabled,
  .btn-secondary:disabled {
    cursor: wait;
    opacity: 0.65;
  }
  .btn-cancel {
    border: 1px solid var(--panel-border);
    border-radius: 4px;
    padding: 8px 14px;
    background: transparent;
    color: var(--fg);
    cursor: pointer;
    font-size: 13px;
  }
  .btn-cancel:hover {
    background: var(--control-hover-bg);
  }
  .btn-secondary {
    background: transparent;
    color: var(--fg);
    border: 1px solid var(--panel-border);
    border-radius: 4px;
    padding: 8px 18px;
    font-size: 13px;
    cursor: pointer;
    margin-right: auto;
  }
  .btn-secondary:hover {
    background: var(--control-hover-bg);
  }
  .keybind-list {
    border: 1px solid var(--panel-border);
    border-radius: 4px;
    background: var(--editor-bg);
    max-height: 200px;
    overflow-y: auto;
  }
  .keybind-row {
    display: flex;
    align-items: center;
    padding: 5px 10px;
    font-size: 12px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
  }
  .keybind-row:last-child {
    border-bottom: none;
  }
  .keybind-keys {
    background: var(--control-bg);
    padding: 2px 6px;
    border-radius: 3px;
    font-family: monospace;
    font-size: 11px;
    margin-right: 10px;
    min-width: 100px;
    text-align: center;
    color: var(--fg);
  }
  .keybind-edit {
    background: var(--control-bg);
    border: 1px solid var(--control-border);
    color: var(--fg);
    padding: 2px 6px;
    border-radius: 3px;
    font-family: monospace;
    font-size: 11px;
    margin-right: 10px;
    width: 112px;
    text-align: center;
  }
  .keybind-desc {
    color: var(--breadcrumb-dim);
    min-width: 0;
    overflow-wrap: anywhere;
  }
  .settings-content :focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
  }
  @media (max-width: 640px) {
    .settings-backdrop {
      padding: 0;
    }
    .settings-content {
      width: 100%;
      max-height: 100vh;
      border-radius: 0;
    }
    .settings-row {
      grid-template-columns: 1fr;
      gap: 0;
    }
    .settings-footer {
      border-radius: 0;
    }
    .settings-footer button {
      flex: 1 1 auto;
    }
    .btn-secondary {
      flex-basis: 100% !important;
      margin-right: 0;
    }
  }
</style>
