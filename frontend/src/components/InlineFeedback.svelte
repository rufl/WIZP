<script lang="ts">
  type Props = {
    id: string;
    error?: string;
    hint?: string;
  };

  let { id, error = '', hint = '' }: Props = $props();
  const message = $derived(error || hint);
</script>

<p
  {id}
  class:invalid={Boolean(error)}
  class="inline-feedback"
  title={message}
  aria-live="polite"
  aria-atomic="true"
>
  {message}
</p>

<style>
  .inline-feedback {
    display: -webkit-box;
    min-height: 2.4em;
    max-height: 2.4em;
    overflow: hidden;
    margin: 4px 0 0;
    color: var(--breadcrumb-dim);
    font-size: 11px;
    line-height: 1.2;
    overflow-wrap: anywhere;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
  }

  .inline-feedback.invalid {
    color: var(--error);
  }
</style>
