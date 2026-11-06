<script lang="ts">
  type Props = { label?: string };
  // Svelte prop bindings remain mutable so parent updates stay reactive.
  /* eslint-disable prefer-const */
  let { label = 'ZIPI is responding' }: Props = $props();
  /* eslint-enable prefer-const */
</script>

<div class="typing-indicator" role="status">
  <span class="sr-only">{label}</span>
  <span class="typing-dots" aria-hidden="true"><i></i><i></i><i></i></span>
</div>

<style>
  .typing-indicator {
    display: flex;
    min-height: 20px;
    align-items: center;
    padding-inline: 4px;
  }

  .typing-dots {
    display: inline-flex;
    gap: 4px;
  }

  .typing-dots i {
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: var(--breadcrumb-dim);
    animation: typing-pulse 1s ease-in-out infinite;
  }

  .typing-dots i:nth-child(2) {
    animation-delay: 120ms;
  }

  .typing-dots i:nth-child(3) {
    animation-delay: 240ms;
  }

  @keyframes typing-pulse {
    0%,
    60%,
    100% {
      opacity: 0.35;
      transform: translateY(0);
    }

    30% {
      opacity: 1;
      transform: translateY(-3px);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .typing-dots i {
      animation: none;
      opacity: 0.7;
    }
  }
</style>
