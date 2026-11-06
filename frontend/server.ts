// WIZP Bun HTTP server — serves Monaco frontend and proxies to Zig daemon.
// Run: bun run server.ts
// Opens at http://localhost:9876
// Browser opened by Zig process (monaco_ui.zig), so we don't open it here.

import { startDaemon, stopDaemon, sendRpc } from "./bridge.ts";

const PORT = 9876;

// Start Zig daemon
await startDaemon();
console.log("WIZP daemon started"); // craft-ignore: intentional server status output.

// Serve static files + API proxy
const server = Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);

    // API proxy to Zig daemon
    if (url.pathname === "/api/rpc") {
      const body = await req.json();
      try {
        const result = await sendRpc(body.method, body.params);
        return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, result }), {
          headers: { "Content-Type": "application/json" },
        });
      } catch (e: any) {
        return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, error: { code: -1, message: e.message } }), {
          headers: { "Content-Type": "application/json" },
        });
      }
    }

    // Serve static files
    let filePath = url.pathname === "/" ? "/index.html" : url.pathname;
    const baseDir = import.meta.dir || ".";
    const file = Bun.file(baseDir + filePath);
    if (await file.exists()) {
      return new Response(file);
    }

    return new Response("Not Found", { status: 404 });
  },
});

console.log(`WIZP frontend server: http://localhost:${PORT}`); // craft-ignore: intentional server status output.

// Cleanup on exit
process.on("SIGINT", () => {
  stopDaemon();
  server.stop();
  process.exit(0);
});
process.on("SIGTERM", () => {
  stopDaemon();
  server.stop();
  process.exit(0);
});
