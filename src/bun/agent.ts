type AcpChild = Bun.Subprocess<"pipe", "pipe", "inherit">;

type PendingRequest = {
  resolve(value: unknown): void;
  reject(error: Error): void;
};

type AgentStatus = {
  available: boolean;
  sessionId: string | null;
  workspace: string;
  promptActive: boolean;
  error: string | null;
};

export class AgentBridge {
  private child: AcpChild | null = null;
  private readTask: Promise<void> | null = null;
  private sequence = 1;
  private readonly pending = new Map<number, PendingRequest>();
  private readonly events: unknown[] = [];
  private sessionId: string | null = null;
  private workspace = "";
  private promptActive = false;
  private failure: string | null = null;
  private startTask: Promise<AgentStatus> | null = null;

  status(): AgentStatus {
    return {
      available: Boolean(this.child && this.child.exitCode === null),
      sessionId: this.sessionId,
      workspace: this.workspace,
      promptActive: this.promptActive,
      error: this.failure,
    };
  }

  takeEvents() {
    return this.events.splice(0);
  }

  async start(workspace: string, savedSession?: string | null, savedWorkspace?: string | null) {
    if (this.startTask) {
      if (this.workspace !== workspace) throw new Error("Stop the current agent before changing workspace.");
      return this.startTask;
    }
    if (this.child && this.child.exitCode === null) {
      if (this.workspace !== workspace) throw new Error("Stop the current agent before changing workspace.");
      return this.status();
    }
    const task = this.startFresh(workspace, savedSession, savedWorkspace);
    this.startTask = task;
    try {
      return await task;
    } finally {
      if (this.startTask === task) this.startTask = null;
    }
  }

  private async startFresh(workspace: string, savedSession?: string | null, savedWorkspace?: string | null) {
    this.sessionId = null;
    this.workspace = "";
    this.promptActive = false;
    this.failure = null;
    const executable = Bun.env.ZIPI_BIN?.trim() || Bun.which("zipi");
    if (!executable) throw new Error("ZIPI is unavailable. Set ZIPI_BIN or add zipi to PATH.");
    const child = Bun.spawn([executable, "acp", "--no-tools"], {
      cwd: workspace,
      stdin: "pipe",
      stdout: "pipe",
      stderr: "inherit",
    });
    this.child = child;
    this.workspace = workspace;
    this.failure = null;
    this.readTask = this.readOutput(child);
    try {
      await this.request("initialize", { protocolVersion: 1 });
      const session = savedSession && savedWorkspace === workspace
        ? await this.request("session/load", { sessionId: savedSession })
        : await this.request("session/new", { cwd: workspace });
      if (
        !session || typeof session !== "object" || Array.isArray(session) ||
        !("sessionId" in session) || typeof session.sessionId !== "string" || !session.sessionId
      ) throw new Error("ZIPI returned an invalid session ID.");
      if (this.child !== child || child.exitCode !== null)
        throw new Error("ZIPI agent stopped during startup.");
      this.sessionId = session.sessionId;
      return this.status();
    } catch (error) {
      await this.stop();
      throw error;
    }
  }

  async prompt(text: string, context = "") {
    if (!this.child || this.child.exitCode !== null || !this.sessionId) throw new Error("Start the ZIPI agent first.");
    if (this.promptActive) throw new Error("The agent is already responding.");
    this.promptActive = true;
    try {
      const message = context ? `${context}\n\n${text}` : text;
      await this.request("session/prompt", { sessionId: this.sessionId, prompt: message });
    } finally {
      this.promptActive = false;
    }
    return this.status();
  }

  async cancel() {
    if (!this.child || this.child.exitCode !== null || !this.sessionId) return this.status();
    await this.request("session/cancel", { sessionId: this.sessionId });
    return this.status();
  }

  async stop() {
    const child = this.child;
    this.child = null;
    this.promptActive = false;
    if (child && child.exitCode === null) {
      try {
        child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: this.sequence++, method: "shutdown", params: {} }) + "\n");
      } catch {}
      const exited = await Promise.race([child.exited.then(() => true), Bun.sleep(1000).then(() => false)]);
      if (!exited) child.kill("SIGKILL");
      await child.exited;
    }
    if (this.readTask) await this.readTask.catch(() => {});
    this.readTask = null;
    this.sessionId = null;
    this.workspace = "";
    const error = new Error("ZIPI agent stopped.");
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
    return this.status();
  }

  private async request(method: string, params: Record<string, unknown>) {
    const child = this.child;
    if (!child || child.exitCode !== null) throw new Error(this.failure || "ZIPI process is not running.");
    const id = this.sequence++;
    const promise = new Promise<unknown>((resolve, reject) => this.pending.set(id, { resolve, reject }));
    try {
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    } catch (error) {
      this.pending.delete(id);
      throw error;
    }
    return promise;
  }

  private async readOutput(child: AcpChild) {
    const reader = child.stdout.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        for (;;) {
          const newline = buffer.indexOf("\n");
          if (newline < 0) break;
          const line = buffer.slice(0, newline).trim();
          buffer = buffer.slice(newline + 1);
          if (line) this.receive(JSON.parse(line) as unknown);
        }
      }
      if (buffer.trim()) this.receive(JSON.parse(buffer) as unknown);
      await child.exited;
      if (this.child === child) throw new Error(`ZIPI exited with status ${child.exitCode}.`);
    } catch (error) {
      this.failure = error instanceof Error ? error.message : String(error);
      for (const pending of this.pending.values()) pending.reject(new Error(this.failure));
      this.pending.clear();
    } finally {
      reader.releaseLock();
    }
  }

  private receive(message: unknown) {
    if (!message || typeof message !== "object" || Array.isArray(message)) return;
    if ("method" in message && message.method === "session/update") {
      this.events.push("params" in message ? message.params : null);
      if (this.events.length > 512) this.events.splice(0, this.events.length - 512);
      return;
    }
    if (!("id" in message) || typeof message.id !== "number") return;
    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id);
    if ("error" in message && message.error && typeof message.error === "object" && !Array.isArray(message.error)) {
      const error = message.error;
      const text = "message" in error && typeof error.message === "string" ? error.message : "ZIPI ACP request failed.";
      pending.reject(new Error(text));
    } else {
      pending.resolve("result" in message ? message.result : undefined);
    }
  }
}
