<script lang="ts">
  type Props = {
    value: number | null;
    label: string;
    pendingLabel?: string;
  };

  // Svelte prop bindings remain mutable so parent updates stay reactive.
  /* eslint-disable prefer-const */
  let { value, label, pendingLabel = 'Working' }: Props = $props();
  /* eslint-enable prefer-const */
  const percent = $derived(value === null ? null : Math.round(Math.max(0, Math.min(100, value))));
</script>

<div class="progress-bar">
  <div class="progress-heading">
    <span class="progress-label" title={label}>{label}</span>
    <span class="progress-value" aria-hidden="true"
      >{percent === null ? pendingLabel : `${percent}%`}</span
    >
  </div>
  <div
    class="progress-track"
    role="progressbar"
    aria-label={label}
    aria-valuemin="0"
    aria-valuemax="100"
    aria-valuenow={percent === null ? undefined : percent}
    aria-valuetext={percent === null ? undefined : `${percent}%`}
  >
    <span
      class="progress-fill"
      class:indeterminate={percent === null}
      style:width={percent === null ? undefined : `${percent}%`}
    ></span>
  </div>
</div>

<style>
  .progress-bar {
    min-width: 0;
    width: 100%;
  }

  .progress-heading {
    display: flex;
    min-width: 0;
    align-items: baseline;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 6px;
    font-size: 11px;
    line-height: 16px;
  }

  .progress-label {
    overflow: hidden;
    color: var(--fg);
    font-weight: 600;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .progress-value {
    flex: 0 0 auto;
    color: var(--breadcrumb-dim);
    font-variant-numeric: tabular-nums;
  }

  .progress-track {
    height: 5px;
    overflow: hidden;
    border-radius: 999px;
    background: var(--panel-border);
  }

  .progress-fill {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--accent);
    transition: width 180ms ease-out;
  }

  .progress-fill.indeterminate {
    width: 38%;
    animation: progress-crawl 1.2s ease-in-out infinite alternate;
  }

  @keyframes progress-crawl {
    from {
      transform: translateX(-8%);
    }
    to {
      transform: translateX(170%);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .progress-fill {
      transition: none;
    }
    .progress-fill.indeterminate {
      animation: none;
      transform: none;
    }
  }
</style>
