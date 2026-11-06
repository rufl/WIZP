<script lang="ts">
  import { SHORTCUTS, WELCOME_SHORTCUTS } from '../shortcuts';

  let recentProjects = $state<string[]>([]);

  $effect(() => {
    try {
      recentProjects = JSON.parse(localStorage.getItem('wizp-recent-projects') || '[]');
    } catch {
      recentProjects = [];
    }
  });

  function openProject(path: string) {
    (window as any).__openFile?.(path);
  }

  function projectName(path: string) {
    return path.split(/[\\/]/).filter(Boolean).pop() || path;
  }
</script>

<section class="welcome" aria-labelledby="welcome-title">
  <div class="welcome-container">
    <header class="welcome-header">
      <h1 id="welcome-title" class="welcome-logo">WIZP</h1>
      <p class="welcome-subtitle">Linux-native code editor</p>
    </header>

    <div class="welcome-content">
      <div class="welcome-primary">
        <section class="welcome-section" aria-labelledby="welcome-start-title">
          <h2 id="welcome-start-title" class="welcome-title">Start</h2>
          <div class="welcome-actions">
            <button type="button" class="welcome-btn" onclick={() => (window as any).__newFile?.()}>
              <span class="codicon codicon-new-file" aria-hidden="true"></span>
              <span>New File</span>
            </button>
            <button
              type="button"
              class="welcome-btn primary"
              onclick={() => (window as any).__openFolder?.()}
            >
              <span class="codicon codicon-folder-opened" aria-hidden="true"></span>
              <span>Open Folder…</span>
            </button>
            <button
              type="button"
              class="welcome-btn"
              onclick={() => (window as any).__openFileViaDialog?.()}
            >
              <span class="codicon codicon-go-to-file" aria-hidden="true"></span>
              <span>Open File…</span>
            </button>
          </div>
        </section>

        <section class="welcome-section" aria-labelledby="welcome-recent-title">
          <h2 id="welcome-recent-title" class="welcome-title">Recent</h2>
          {#if recentProjects.length > 0}
            <div class="welcome-actions">
              {#each recentProjects.slice(0, 5) as path (path)}
                <button
                  type="button"
                  class="welcome-btn recent"
                  title={path}
                  onclick={() => openProject(path)}
                >
                  <span class="codicon codicon-repo" aria-hidden="true"></span>
                  <span class="recent-copy">
                    <span class="recent-name">{projectName(path)}</span>
                    <span class="recent-path">{path}</span>
                  </span>
                </button>
              {/each}
            </div>
          {:else}
            <p class="welcome-empty">Open a folder to start a recent-project list.</p>
          {/if}
        </section>
      </div>

      <section
        class="welcome-section welcome-shortcut-section"
        aria-labelledby="welcome-shortcuts-title"
      >
        <h2 id="welcome-shortcuts-title" class="welcome-title">Shortcuts</h2>
        <div class="welcome-shortcuts">
          {#each WELCOME_SHORTCUTS as id (id)}
            {@const shortcut = SHORTCUTS[id]}
            <div class="welcome-shortcut">
              <span class="welcome-desc">{shortcut.label}</span>
              <kbd class="welcome-keys">{shortcut.keys}</kbd>
            </div>
          {/each}
        </div>
      </section>
    </div>
  </div>
</section>

<style>
  .welcome {
    position: relative;
    display: flex;
    align-items: flex-start;
    justify-content: center;
    width: 100%;
    height: 100%;
    padding: clamp(32px, 7vh, 76px) clamp(20px, 5vw, 72px);
    overflow: auto;
    background:
      radial-gradient(
        circle at 50% 4%,
        color-mix(in srgb, var(--accent) 10%, transparent),
        transparent 38%
      ),
      radial-gradient(
        circle at 12% 80%,
        color-mix(in srgb, var(--accent) 5%, transparent),
        transparent 28%
      );
    user-select: none;
  }
  .welcome::after {
    position: absolute;
    inset: 0;
    z-index: 0;
    pointer-events: none;
    content: '';
    opacity: 0.18;
    background-image: radial-gradient(
      color-mix(in srgb, var(--fg) 22%, transparent) 0.6px,
      transparent 0.6px
    );
    background-size: 18px 18px;
    mask-image: linear-gradient(to bottom, black, transparent 78%);
  }
  .welcome > * {
    position: relative;
    z-index: 1;
  }
  .welcome-container {
    display: flex;
    width: min(900px, 100%);
    flex-direction: column;
    gap: clamp(32px, 5vh, 52px);
  }
  .welcome-header {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    text-align: center;
  }
  .welcome-logo {
    margin: 0;
    color: var(--fg);
    background: linear-gradient(
      135deg,
      var(--fg) 25%,
      color-mix(in srgb, var(--accent) 72%, var(--fg))
    );
    background-clip: text;
    -webkit-background-clip: text;
    font-size: clamp(34px, 5vw, 48px);
    font-weight: 300;
    letter-spacing: 0.2em;
    line-height: 1;
    -webkit-text-fill-color: transparent;
  }
  .welcome-subtitle {
    margin: 0;
    color: var(--breadcrumb-dim);
    font-size: 13px;
    letter-spacing: 0.01em;
  }
  .welcome-content {
    display: grid; /* craft-ignore: asymmetric actions and shortcut reference, not equal cards. */
    grid-template-columns: minmax(0, 1.2fr) minmax(240px, 0.8fr);
    gap: clamp(28px, 6vw, 64px);
    align-items: start;
  }
  .welcome-primary,
  .welcome-shortcut-section {
    min-width: 0;
    padding: 18px;
    border: 1px solid color-mix(in srgb, var(--panel-border) 88%, var(--accent) 12%);
    border-radius: 10px;
    background: color-mix(in srgb, var(--panel-bg) 88%, var(--bg));
    box-shadow:
      0 14px 32px color-mix(in srgb, var(--bg) 55%, transparent),
      inset 0 1px 0 color-mix(in srgb, var(--fg) 4%, transparent);
  }
  .welcome-primary {
    display: flex;
    flex-direction: column;
    gap: 28px;
  }
  .welcome-section {
    display: flex;
    min-width: 0;
    flex-direction: column;
    gap: 10px;
  }
  .welcome-title {
    margin: 0;
    color: var(--sidebar-fg);
    font-size: 11px;
    font-weight: 650;
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }
  .welcome-actions {
    display: flex;
    min-width: 0;
    flex-direction: column;
    gap: 4px;
  }
  .welcome-btn {
    display: flex;
    min-width: 0;
    min-height: 42px;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 9px 11px;
    border: 1px solid transparent;
    border-radius: 6px;
    background: transparent;
    color: var(--breadcrumb-dim);
    cursor: pointer;
    text-align: left;
    transition:
      background-color 140ms ease,
      border-color 140ms ease,
      color 140ms ease,
      transform 140ms ease;
  }
  .welcome-btn .codicon {
    flex: 0 0 auto;
    color: var(--activity-inactive);
    font-size: 17px;
  }
  .welcome-btn:hover {
    border-color: color-mix(in srgb, var(--accent) 28%, var(--panel-border));
    background: color-mix(in srgb, var(--accent) 8%, transparent);
    color: var(--fg);
    transform: translateX(2px);
  }
  .welcome-btn.primary {
    border-color: color-mix(in srgb, var(--accent) 55%, var(--panel-border));
    background: color-mix(in srgb, var(--accent) 12%, transparent);
    color: var(--fg);
  }
  .welcome-btn:hover .codicon,
  .welcome-btn.primary .codicon {
    color: var(--accent);
  }
  .welcome-btn:focus-visible {
    outline-offset: 1px;
  }
  .recent-copy {
    display: flex;
    min-width: 0;
    flex: 1;
    flex-direction: column;
    gap: 2px;
  }
  .recent-name,
  .recent-path {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .recent-name {
    color: var(--fg);
    font-size: 12px;
  }
  .recent-path {
    color: var(--breadcrumb-dim);
    font-size: 10px;
  }
  .welcome-empty {
    margin: 0;
    padding: 12px;
    border: 1px dashed var(--panel-border);
    border-radius: 6px;
    color: var(--breadcrumb-dim);
    font-size: 12px;
    line-height: 1.45;
  }
  .welcome-shortcuts {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 8px;
    border: 1px solid color-mix(in srgb, var(--panel-border) 82%, var(--accent) 18%);
    border-radius: 7px;
    background: color-mix(in srgb, var(--panel-bg) 86%, var(--bg));
  }
  .welcome-shortcut {
    display: flex;
    min-height: 36px;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 5px 7px;
    border-radius: 4px;
    font-size: 12px;
    transition: background-color 140ms ease;
  }
  .welcome-shortcut:hover {
    background: color-mix(in srgb, var(--accent) 8%, transparent);
  }
  .welcome-keys {
    flex: 0 0 auto;
    padding: 4px 7px;
    border: 1px solid var(--control-border);
    border-radius: 4px;
    background: var(--control-bg);
    color: var(--fg);
    font-family: 'Cascadia Code', 'JetBrains Mono', monospace;
    font-size: 10px;
    letter-spacing: 0.02em;
    box-shadow: inset 0 -1px 0 rgba(0, 0, 0, 0.35);
  }
  .welcome-desc {
    min-width: 0;
    color: var(--breadcrumb-dim);
  }
  @media (max-width: 760px) {
    .welcome-content {
      grid-template-columns: 1fr;
      gap: 28px;
    }
    .welcome-shortcut-section {
      padding-bottom: 24px;
    }
  }
  @media (max-height: 620px) {
    .welcome {
      padding-block: 24px;
    }
    .welcome-container {
      gap: 26px;
    }
    .welcome-logo {
      font-size: 32px;
    }
  }
  :global(html[data-ui-scale='large']) .welcome-content {
    grid-template-columns: 1fr;
  }
</style>
