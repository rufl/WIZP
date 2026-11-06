import { expect, test } from "bun:test";

test("terminal input and rerun remain ordered without blocking other sessions", async () => {
  const storage = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: { getItem: () => null },
  });
  // Browser globals must exist before evaluating this browser-only module.
  const { terminalWrite, terminalRerun } = await import("../frontend/bridge");
  const originalFetch = globalThis.fetch;
  const firstInput = Promise.withResolvers<void>();
  const received = new Map<number, string>();
  globalThis.fetch = (async (_url, options) => {
    const { id, method, params } = JSON.parse(String(options?.body));
    if (params.id === 1 && params.data === "A") await firstInput.promise;
    const text = method === "terminal/rerun" ? `${params.command}\n` : params.data;
    received.set(params.id, (received.get(params.id) ?? "") + text);
    return Response.json({ jsonrpc: "2.0", id, result: true });
  }) as typeof fetch;
  let writes: Promise<unknown>[] = [];
  try {
    writes = [terminalWrite("A", 1), terminalWrite("B", 1), terminalRerun("C", 1)];
    await terminalWrite("independent", 2);
    expect(received.get(2)).toBe("independent");
    firstInput.resolve();
    await Promise.all(writes);
    expect(received.get(1)).toBe("ABC\n");
  } finally {
    firstInput.resolve();
    await Promise.allSettled(writes);
    globalThis.fetch = originalFetch;
    if (storage) Object.defineProperty(globalThis, "localStorage", storage);
    else Reflect.deleteProperty(globalThis, "localStorage");
  }
});
