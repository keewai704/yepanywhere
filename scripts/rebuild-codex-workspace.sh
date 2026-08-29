#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TMP_LICENSE="$(mktemp -d)"
for candidate in LICENSE LICENSE.md LICENSE.txt NOTICE NOTICE.md; do
  if [[ -f "$candidate" ]]; then cp "$candidate" "$TMP_LICENSE/$candidate"; fi
done

find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
mkdir -p .github/workflows apps/server/src apps/server/test apps/web/src/components apps/web/src/hooks apps/web/test scripts
for candidate in "$TMP_LICENSE"/*; do
  [[ -f "$candidate" ]] && cp "$candidate" .
done

cat > package.json <<'EOF'
{
  "name": "yep-anywhere",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "packageManager": "pnpm@10.34.5",
  "engines": {
    "node": ">=24"
  },
  "scripts": {
    "dev": "pnpm --parallel --filter @yep-anywhere/server --filter @yep-anywhere/web dev",
    "build": "pnpm -r build",
    "typecheck": "pnpm -r typecheck",
    "test": "pnpm -r test",
    "lint": "biome check . && node scripts/check-focus.mjs",
    "format": "biome format --write .",
    "format:check": "biome format .",
    "perf:check": "node scripts/check-bundle.mjs",
    "test:smoke": "node scripts/smoke.mjs",
    "start": "node apps/server/dist/index.js"
  }
}
EOF

cat > pnpm-workspace.yaml <<'EOF'
packages:
  - apps/*
EOF

cat > .node-version <<'EOF'
24
EOF

cat > .gitignore <<'EOF'
node_modules/
dist/
coverage/
.vite/
.DS_Store
*.log
.env
EOF

cat > biome.json <<'EOF'
{
  "files": {
    "includes": ["**", "!**/dist", "!**/coverage", "!pnpm-lock.yaml"]
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 100
  },
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "suspicious": {
        "noExplicitAny": "off"
      }
    }
  },
  "javascript": {
    "formatter": {
      "quoteStyle": "double",
      "semicolons": "always",
      "trailingCommas": "all"
    }
  }
}
EOF

cat > tsconfig.json <<'EOF'
{
  "files": [],
  "references": [
    { "path": "./apps/server" },
    { "path": "./apps/web" }
  ]
}
EOF

cat > .env.example <<'EOF'
HOST=127.0.0.1
PORT=3400
CODEX_HOME=
CODEX_WORKSPACE_ROOTS=
DEV_ORIGIN=http://localhost:5173
EOF

cat > README.md <<'EOF'
# Yep Anywhere

A focused, self-hosted web workspace for Codex. It reads existing Codex session history,
starts or resumes CLI sessions, streams progress, browses project files, and exposes a
responsive PWA interface designed for desktop, tablet, and phone.

## Modes

- **Fast** uses the CLI's native fast capability when it is advertised. On older builds it
  requests the fast service tier through Codex configuration.
- **Ultra** uses the CLI's native ultra capability when available. Otherwise it requests
  the maximum `xhigh` reasoning effort.

The selected mode is persisted in the browser and is included with every new or resumed
turn.

## Run

```bash
corepack enable
pnpm install --frozen-lockfile
pnpm build
pnpm start
```

The server listens on `127.0.0.1:3400` by default. Set `CODEX_WORKSPACE_ROOTS` to a
platform-delimited list of directories that the web UI may open. When it is omitted, the
current working directory is the only allowed root.

For development:

```bash
pnpm dev
```

## Validation

```bash
pnpm format:check
pnpm lint
pnpm typecheck
pnpm test
pnpm build
pnpm perf:check
pnpm test:smoke
```

The transcript reader caches normalized JSONL snapshots by file size and modification
stamp. The client virtualizes long conversations, keeps query subscriptions narrow, and
loads Markdown rendering and the file drawer in separate chunks.
EOF

cat > apps/server/package.json <<'EOF'
{
  "name": "@yep-anywhere/server",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "main": "dist/index.js",
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc -p tsconfig.json",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "test": "vitest run"
  }
}
EOF

cat > apps/server/tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2023",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2023", "DOM"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "rootDir": "src",
    "outDir": "dist",
    "declaration": true,
    "sourceMap": true,
    "types": ["node"]
  },
  "include": ["src/**/*.ts"],
  "exclude": ["dist", "test"]
}
EOF

cat > apps/server/src/types.ts <<'EOF'
export type CodexMode = "fast" | "ultra";

export type TranscriptRole = "user" | "assistant" | "system" | "tool";

export interface TranscriptItem {
  id: string;
  role: TranscriptRole;
  text: string;
  timestamp?: string;
  kind?: string;
}

export interface SessionSummary {
  id: string;
  cwd: string;
  title: string;
  updatedAt: string;
  preview: string;
}

export interface SessionDetail extends SessionSummary {
  items: TranscriptItem[];
}

export interface RunOutput {
  role: TranscriptRole;
  text: string;
  kind?: string;
}
EOF

cat > apps/server/src/config.ts <<'EOF'
import { realpath } from "node:fs/promises";
import { delimiter, relative, resolve, sep } from "node:path";

const configuredRoots = process.env.CODEX_WORKSPACE_ROOTS?.split(delimiter)
  .map((entry) => entry.trim())
  .filter(Boolean);

let rootsPromise: Promise<string[]> | undefined;

export const serverConfig = {
  host: process.env.HOST ?? "127.0.0.1",
  port: Number.parseInt(process.env.PORT ?? "3400", 10),
  devOrigin: process.env.DEV_ORIGIN,
};

async function workspaceRoots(): Promise<string[]> {
  rootsPromise ??= Promise.all((configuredRoots?.length ? configuredRoots : [process.cwd()]).map((root) => realpath(resolve(root))));
  return rootsPromise;
}

function isWithin(root: string, candidate: string): boolean {
  const pathFromRoot = relative(root, candidate);
  return pathFromRoot === "" || (!pathFromRoot.startsWith(`..${sep}`) && pathFromRoot !== "..");
}

export async function resolveWorkspace(input: string): Promise<string> {
  const candidate = await realpath(resolve(input));
  const roots = await workspaceRoots();
  if (!roots.some((root) => isWithin(root, candidate))) {
    throw new Error("Workspace is outside the configured roots");
  }
  return candidate;
}

export async function resolveWorkspacePath(workspace: string, input = "."): Promise<string> {
  const root = await resolveWorkspace(workspace);
  const candidate = await realpath(resolve(root, input));
  if (!isWithin(root, candidate)) {
    throw new Error("Path is outside the workspace");
  }
  return candidate;
}
EOF

cat > apps/server/src/mode.ts <<'EOF'
import { spawn } from "node:child_process";
import type { CodexMode } from "./types.js";

export interface ModeCapabilities {
  fast: boolean;
  ultra: boolean;
}

let capabilityPromise: Promise<ModeCapabilities> | undefined;

function readHelp(): Promise<string> {
  return new Promise((resolve) => {
    const child = spawn("codex", ["--help"], { stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    const timer = setTimeout(() => child.kill(), 2500);
    child.stdout.on("data", (chunk: Buffer) => {
      output += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk: Buffer) => {
      output += chunk.toString("utf8");
    });
    child.once("error", () => {
      clearTimeout(timer);
      resolve("");
    });
    child.once("close", () => {
      clearTimeout(timer);
      resolve(output);
    });
  });
}

export async function detectModeCapabilities(
  helpReader: () => Promise<string> = readHelp,
): Promise<ModeCapabilities> {
  if (helpReader === readHelp && capabilityPromise) return capabilityPromise;
  const task = helpReader().then((help) => ({
    fast: /(^|\s)--fast(?:\s|,|$)/m.test(help),
    ultra: /(^|\s)--ultra(?:\s|,|$)/m.test(help),
  }));
  if (helpReader === readHelp) capabilityPromise = task;
  return task;
}

export function modeArguments(mode: CodexMode, capabilities: ModeCapabilities): string[] {
  if (mode === "fast") {
    return capabilities.fast ? ["--fast"] : ["-c", 'service_tier="fast"'];
  }
  return capabilities.ultra ? ["--ultra"] : ["-c", 'model_reasoning_effort="xhigh"'];
}

export async function buildCodexArguments(input: {
  mode: CodexMode;
  prompt: string;
  resumeId?: string;
  capabilities?: ModeCapabilities;
}): Promise<string[]> {
  const capabilities = input.capabilities ?? (await detectModeCapabilities());
  const args = [...modeArguments(input.mode, capabilities), "exec"];
  if (input.resumeId) {
    args.push("resume", "--json", "--skip-git-repo-check", input.resumeId, input.prompt);
  } else {
    args.push("--json", "--skip-git-repo-check", input.prompt);
  }
  return args;
}
EOF

cat > apps/server/src/history.ts <<'EOF'
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { readFile, readdir, stat } from "node:fs/promises";
import type { SessionDetail, SessionSummary, TranscriptItem, TranscriptRole } from "./types.js";

const sessionRoot = join(process.env.CODEX_HOME ?? join(homedir(), ".codex"), "sessions");
const cache = new Map<string, { stamp: string; detail: SessionDetail }>();
const idToPath = new Map<string, string>();

async function collectJsonl(directory: string, output: string[], depth = 0): Promise<void> {
  if (depth > 8 || output.length > 6000) return;
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch {
    return;
  }
  await Promise.all(
    entries.map(async (entry) => {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await collectJsonl(path, output, depth + 1);
      else if (entry.isFile() && entry.name.endsWith(".jsonl")) output.push(path);
    }),
  );
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function textFromContent(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(textFromContent).filter(Boolean).join("\n");
  const record = asRecord(value);
  if (!record) return "";
  for (const key of ["text", "input_text", "output_text", "content", "message"]) {
    if (record[key] !== undefined) {
      const text = textFromContent(record[key]);
      if (text) return text;
    }
  }
  return "";
}

function roleFrom(value: unknown): TranscriptRole | undefined {
  if (value === "user" || value === "assistant" || value === "system" || value === "tool") {
    return value;
  }
  return undefined;
}

function normalizeLine(value: unknown, index: number): { item?: TranscriptItem; metadata?: Record<string, unknown> } {
  const record = asRecord(value);
  if (!record) return {};
  const payload = asRecord(record.payload) ?? record;
  const recordType = typeof record.type === "string" ? record.type : undefined;
  const payloadType = typeof payload.type === "string" ? payload.type : undefined;

  if (recordType === "session_meta" || payloadType === "session_meta") return { metadata: payload };

  let role = roleFrom(payload.role);
  if (!role && payloadType === "user_message") role = "user";
  if (!role && (payloadType === "agent_message" || payloadType === "assistant_message")) role = "assistant";
  if (!role && payloadType?.includes("tool")) role = "tool";

  const nestedMessage = asRecord(payload.message);
  role ??= roleFrom(nestedMessage?.role);
  const text = textFromContent(payload.content ?? nestedMessage?.content ?? payload.text ?? payload.message);
  if (!role || !text.trim()) return {};

  const timestamp =
    typeof record.timestamp === "string"
      ? record.timestamp
      : typeof payload.timestamp === "string"
        ? payload.timestamp
        : undefined;
  const stable = createHash("sha1").update(`${index}:${role}:${text}`).digest("hex").slice(0, 16);
  return {
    item: {
      id: stable,
      role,
      text: text.trim(),
      ...(timestamp ? { timestamp } : {}),
      ...(payloadType ? { kind: payloadType } : {}),
    },
  };
}

function pickString(record: Record<string, unknown> | undefined, keys: string[]): string | undefined {
  if (!record) return undefined;
  for (const key of keys) {
    if (typeof record[key] === "string" && record[key]) return record[key] as string;
  }
  return undefined;
}

async function parseSession(path: string): Promise<SessionDetail> {
  const info = await stat(path);
  const stamp = `${info.size}:${info.mtimeMs}`;
  const existing = cache.get(path);
  if (existing?.stamp === stamp) return existing.detail;

  const raw = await readFile(path, "utf8");
  const items: TranscriptItem[] = [];
  let metadata: Record<string, unknown> | undefined;
  const lines = raw.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]?.trim();
    if (!line) continue;
    try {
      const normalized = normalizeLine(JSON.parse(line), index);
      metadata ??= normalized.metadata;
      const item = normalized.item;
      const previous = items.at(-1);
      if (item && !(previous?.role === item.role && previous.text === item.text)) items.push(item);
    } catch {
      // An incomplete final JSONL record is ignored until the next snapshot.
    }
  }

  const id = pickString(metadata, ["id", "session_id", "thread_id"]) ?? basename(path, ".jsonl");
  const cwd = pickString(metadata, ["cwd", "working_directory", "workspace"]) ?? "";
  const firstUser = items.find((item) => item.role === "user")?.text ?? "Untitled session";
  const last = items.at(-1)?.text ?? firstUser;
  const updatedAt = info.mtime.toISOString();
  const detail: SessionDetail = {
    id,
    cwd,
    title: firstUser.replace(/\s+/g, " ").slice(0, 80),
    preview: last.replace(/\s+/g, " ").slice(0, 140),
    updatedAt,
    items,
  };
  cache.set(path, { stamp, detail });
  idToPath.set(id, path);
  return detail;
}

export async function listSessions(limit = 100): Promise<SessionSummary[]> {
  const files: string[] = [];
  await collectJsonl(sessionRoot, files);
  const newest = (
    await Promise.all(
      files.map(async (path) => {
        try {
          return { path, mtime: (await stat(path)).mtimeMs };
        } catch {
          return undefined;
        }
      }),
    )
  )
    .filter((entry): entry is { path: string; mtime: number } => Boolean(entry))
    .sort((a, b) => b.mtime - a.mtime)
    .slice(0, Math.max(1, Math.min(limit, 250)));

  const details = await Promise.all(newest.map((entry) => parseSession(entry.path)));
  return details.map(({ items: _items, ...summary }) => summary);
}

export async function getSession(id: string): Promise<SessionDetail | undefined> {
  const known = idToPath.get(id);
  if (known) return parseSession(known);
  await listSessions(250);
  const discovered = idToPath.get(id);
  return discovered ? parseSession(discovered) : undefined;
}

export const historyInternals = { normalizeLine, textFromContent };
EOF

cat > apps/server/src/runs.ts <<'EOF'
import { randomUUID } from "node:crypto";

export interface StreamEvent {
  id: number;
  type: "output" | "meta" | "log" | "done" | "error";
  data: unknown;
}

interface RunState {
  events: StreamEvent[];
  listeners: Set<(event: StreamEvent) => void>;
  completed: boolean;
  touchedAt: number;
}

class RunRegistry {
  private readonly runs = new Map<string, RunState>();

  create(): string {
    const id = randomUUID();
    this.runs.set(id, { events: [], listeners: new Set(), completed: false, touchedAt: Date.now() });
    this.sweep();
    return id;
  }

  publish(id: string, type: StreamEvent["type"], data: unknown): void {
    const state = this.runs.get(id);
    if (!state) return;
    const event = { id: state.events.length + 1, type, data } satisfies StreamEvent;
    state.events.push(event);
    state.touchedAt = Date.now();
    if (type === "done" || type === "error") state.completed = true;
    for (const listener of state.listeners) listener(event);
  }

  subscribe(id: string, listener: (event: StreamEvent) => void): (() => void) | undefined {
    const state = this.runs.get(id);
    if (!state) return undefined;
    for (const event of state.events) listener(event);
    if (!state.completed) state.listeners.add(listener);
    return () => state.listeners.delete(listener);
  }

  has(id: string): boolean {
    return this.runs.has(id);
  }

  private sweep(): void {
    const cutoff = Date.now() - 30 * 60 * 1000;
    for (const [id, state] of this.runs) {
      if (state.completed && state.touchedAt < cutoff) this.runs.delete(id);
    }
  }
}

export const runRegistry = new RunRegistry();
EOF

cat > apps/server/src/codex.ts <<'EOF'
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { buildCodexArguments } from "./mode.js";
import { runRegistry } from "./runs.js";
import type { CodexMode, RunOutput, TranscriptRole } from "./types.js";

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function findString(value: unknown, keys: Set<string>, depth = 0): string | undefined {
  if (depth > 5) return undefined;
  const record = asRecord(value);
  if (!record) return undefined;
  for (const [key, entry] of Object.entries(record)) {
    if (keys.has(key) && typeof entry === "string" && entry) return entry;
  }
  for (const entry of Object.values(record)) {
    const found = findString(entry, keys, depth + 1);
    if (found) return found;
  }
  return undefined;
}

function extractText(value: unknown, depth = 0): string {
  if (depth > 6) return "";
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map((entry) => extractText(entry, depth + 1)).filter(Boolean).join("\n");
  const record = asRecord(value);
  if (!record) return "";
  for (const key of ["text", "output_text", "content", "message", "delta"]) {
    if (record[key] !== undefined) {
      const text = extractText(record[key], depth + 1);
      if (text) return text;
    }
  }
  return "";
}

function normalizeOutput(value: unknown): RunOutput | undefined {
  const record = asRecord(value);
  if (!record) return undefined;
  const payload = asRecord(record.payload) ?? record;
  const type = typeof payload.type === "string" ? payload.type : typeof record.type === "string" ? record.type : undefined;
  const explicitRole = payload.role;
  let role: TranscriptRole = "assistant";
  if (explicitRole === "user" || explicitRole === "assistant" || explicitRole === "system" || explicitRole === "tool") role = explicitRole;
  else if (type?.includes("tool")) role = "tool";
  else if (type?.includes("reasoning")) role = "system";
  const text = extractText(payload);
  if (!text.trim()) return undefined;
  return { role, text: text.trim(), ...(type ? { kind: type } : {}) };
}

export async function startCodexRun(input: {
  cwd: string;
  prompt: string;
  mode: CodexMode;
  resumeId?: string;
}): Promise<string> {
  const runId = runRegistry.create();
  const args = await buildCodexArguments(input);
  runRegistry.publish(runId, "meta", { mode: input.mode, status: "starting" });
  const child = spawn("codex", args, {
    cwd: input.cwd,
    env: { ...process.env, TERM: "dumb", NO_COLOR: "1" },
    stdio: ["ignore", "pipe", "pipe"],
  });

  child.once("error", (error) => {
    runRegistry.publish(runId, "error", { message: error.message });
  });

  const output = createInterface({ input: child.stdout });
  output.on("line", (line) => {
    try {
      const parsed = JSON.parse(line) as unknown;
      const sessionId = findString(parsed, new Set(["session_id", "thread_id"]));
      if (sessionId) runRegistry.publish(runId, "meta", { sessionId });
      const normalized = normalizeOutput(parsed);
      if (normalized) runRegistry.publish(runId, "output", normalized);
    } catch {
      if (line.trim()) runRegistry.publish(runId, "output", { role: "assistant", text: line.trim(), kind: "text" });
    }
  });

  const errors = createInterface({ input: child.stderr });
  errors.on("line", (line) => {
    if (line.trim()) runRegistry.publish(runId, "log", { message: line.trim() });
  });

  child.once("close", (code, signal) => {
    if (code === 0) runRegistry.publish(runId, "done", { code, signal });
    else runRegistry.publish(runId, "error", { message: `Codex exited with code ${code ?? "unknown"}`, code, signal });
  });
  return runId;
}

export const codexInternals = { normalizeOutput };
EOF

cat > apps/server/src/files.ts <<'EOF'
import { readFile, readdir, stat } from "node:fs/promises";
import { relative } from "node:path";
import { resolveWorkspace, resolveWorkspacePath } from "./config.js";

export async function listFiles(workspace: string, requested = ".") {
  const root = await resolveWorkspace(workspace);
  const path = await resolveWorkspacePath(root, requested);
  const entries = await readdir(path, { withFileTypes: true });
  const normalized = await Promise.all(
    entries.slice(0, 500).map(async (entry) => {
      const entryPath = await resolveWorkspacePath(root, relative(root, `${path}/${entry.name}`));
      const info = await stat(entryPath);
      return {
        name: entry.name,
        path: relative(root, entryPath) || ".",
        type: entry.isDirectory() ? "directory" : "file",
        size: info.size,
        updatedAt: info.mtime.toISOString(),
      };
    }),
  );
  return normalized.sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name) : a.type === "directory" ? -1 : 1));
}

export async function readWorkspaceFile(workspace: string, requested: string) {
  const path = await resolveWorkspacePath(workspace, requested);
  const info = await stat(path);
  if (!info.isFile()) throw new Error("Path is not a file");
  if (info.size > 1_500_000) throw new Error("File is too large to preview");
  const bytes = await readFile(path);
  if (bytes.includes(0)) throw new Error("Binary files are not previewed");
  return { text: bytes.toString("utf8"), size: info.size, updatedAt: info.mtime.toISOString() };
}
EOF

cat > apps/server/src/git.ts <<'EOF'
import { spawn } from "node:child_process";

export function gitStatus(cwd: string): Promise<string> {
  return new Promise((resolve) => {
    const child = spawn("git", ["status", "--short", "--branch"], { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    const timer = setTimeout(() => child.kill(), 3000);
    child.stdout.on("data", (chunk: Buffer) => {
      output += chunk.toString("utf8");
    });
    child.once("error", () => {
      clearTimeout(timer);
      resolve("");
    });
    child.once("close", () => {
      clearTimeout(timer);
      resolve(output.trim());
    });
  });
}
EOF

cat > apps/server/src/index.ts <<'EOF'
import { readFile, stat } from "node:fs/promises";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { serve } from "@hono/node-server";
import { cors } from "hono/cors";
import { Hono } from "hono";
import { z } from "zod";
import { startCodexRun } from "./codex.js";
import { resolveWorkspace } from "./config.js";
import { listFiles, readWorkspaceFile } from "./files.js";
import { gitStatus } from "./git.js";
import { getSession, listSessions } from "./history.js";
import { runRegistry, type StreamEvent } from "./runs.js";
import { serverConfig } from "./config.js";

const app = new Hono();
if (serverConfig.devOrigin) app.use("/api/*", cors({ origin: serverConfig.devOrigin }));

const runSchema = z.object({
  cwd: z.string().min(1).max(4096),
  prompt: z.string().min(1).max(200_000),
  mode: z.enum(["fast", "ultra"]),
  sessionId: z.string().min(1).max(512).optional(),
});

app.get("/api/health", (context) => context.json({ ok: true, product: "Yep Anywhere" }));

app.get("/api/sessions", async (context) => {
  const limit = Number.parseInt(context.req.query("limit") ?? "100", 10);
  return context.json({ sessions: await listSessions(Number.isFinite(limit) ? limit : 100) });
});

app.get("/api/sessions/:id", async (context) => {
  const session = await getSession(context.req.param("id"));
  return session ? context.json(session) : context.json({ error: "Session not found" }, 404);
});

app.post("/api/runs", async (context) => {
  const input = runSchema.parse(await context.req.json());
  const cwd = await resolveWorkspace(input.cwd);
  const runId = await startCodexRun({ cwd, prompt: input.prompt, mode: input.mode, ...(input.sessionId ? { resumeId: input.sessionId } : {}) });
  return context.json({ runId }, 202);
});

app.get("/api/runs/:id/events", (context) => {
  const id = context.req.param("id");
  if (!runRegistry.has(id)) return context.json({ error: "Run not found" }, 404);
  const encoder = new TextEncoder();
  let unsubscribe: (() => void) | undefined;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const send = (event: StreamEvent) => {
        controller.enqueue(encoder.encode(`id: ${event.id}\nevent: ${event.type}\ndata: ${JSON.stringify(event.data)}\n\n`));
        if (event.type === "done" || event.type === "error") {
          unsubscribe?.();
          controller.close();
        }
      };
      unsubscribe = runRegistry.subscribe(id, send);
      context.req.raw.signal.addEventListener("abort", () => unsubscribe?.(), { once: true });
    },
    cancel() {
      unsubscribe?.();
    },
  });
  return new Response(stream, {
    headers: {
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "Content-Type": "text/event-stream; charset=utf-8",
      "X-Accel-Buffering": "no",
    },
  });
});

app.get("/api/files", async (context) => {
  const cwd = context.req.query("cwd");
  if (!cwd) return context.json({ error: "cwd is required" }, 400);
  return context.json({ entries: await listFiles(cwd, context.req.query("path") ?? ".") });
});

app.get("/api/file", async (context) => {
  const cwd = context.req.query("cwd");
  const path = context.req.query("path");
  if (!cwd || !path) return context.json({ error: "cwd and path are required" }, 400);
  return context.json(await readWorkspaceFile(cwd, path));
});

app.get("/api/git/status", async (context) => {
  const cwd = context.req.query("cwd");
  if (!cwd) return context.json({ error: "cwd is required" }, 400);
  return context.json({ status: await gitStatus(await resolveWorkspace(cwd)) });
});

app.onError((error, context) => {
  const message = error instanceof z.ZodError ? "Invalid request" : error.message;
  return context.json({ error: message }, error instanceof z.ZodError ? 400 : 500);
});

const currentDirectory = dirname(fileURLToPath(import.meta.url));
const webRoot = resolve(currentDirectory, "../../web/dist");
const mimeTypes: Record<string, string> = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".webmanifest": "application/manifest+json",
};

app.get("*", async (context) => {
  if (context.req.path.startsWith("/api/")) return context.notFound();
  const requested = context.req.path === "/" ? "index.html" : context.req.path.slice(1);
  const safeRequested = requested.includes("..") ? "index.html" : requested;
  let path = join(webRoot, safeRequested);
  try {
    if (!(await stat(path)).isFile()) path = join(webRoot, "index.html");
  } catch {
    path = join(webRoot, "index.html");
  }
  const body = await readFile(path);
  return new Response(body, { headers: { "Content-Type": mimeTypes[extname(path)] ?? "application/octet-stream" } });
});

serve({ fetch: app.fetch, hostname: serverConfig.host, port: serverConfig.port }, (info) => {
  process.stdout.write(`Yep Anywhere listening on http://${info.address}:${info.port}\n`);
});
EOF

cat > apps/server/test/mode.test.ts <<'EOF'
import { describe, expect, it } from "vitest";
import { buildCodexArguments, detectModeCapabilities, modeArguments } from "../src/mode.js";

describe("Codex mode arguments", () => {
  it("uses native capabilities when advertised", () => {
    expect(modeArguments("fast", { fast: true, ultra: true })).toEqual(["--fast"]);
    expect(modeArguments("ultra", { fast: true, ultra: true })).toEqual(["--ultra"]);
  });

  it("uses protocol configuration fallbacks", () => {
    expect(modeArguments("fast", { fast: false, ultra: false })).toEqual(["-c", 'service_tier="fast"']);
    expect(modeArguments("ultra", { fast: false, ultra: false })).toEqual(["-c", 'model_reasoning_effort="xhigh"']);
  });

  it("detects exact help flags", async () => {
    await expect(detectModeCapabilities(async () => "  --fast, enable fast mode\n  --ultra enable ultra mode")).resolves.toEqual({ fast: true, ultra: true });
  });

  it("includes the mode in new and resumed commands", async () => {
    await expect(buildCodexArguments({ mode: "fast", prompt: "hello", capabilities: { fast: true, ultra: false } })).resolves.toEqual(["--fast", "exec", "--json", "--skip-git-repo-check", "hello"]);
    await expect(buildCodexArguments({ mode: "ultra", prompt: "continue", resumeId: "session-1", capabilities: { fast: false, ultra: false } })).resolves.toEqual(["-c", 'model_reasoning_effort="xhigh"', "exec", "resume", "--json", "--skip-git-repo-check", "session-1", "continue"]);
  });
});
EOF

cat > apps/server/test/history.test.ts <<'EOF'
import { describe, expect, it } from "vitest";
import { historyInternals } from "../src/history.js";

describe("history normalization", () => {
  it("normalizes user and assistant payloads", () => {
    expect(historyInternals.normalizeLine({ type: "event_msg", payload: { type: "user_message", message: "Ship it" } }, 1).item).toMatchObject({ role: "user", text: "Ship it" });
    expect(historyInternals.normalizeLine({ type: "response_item", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "Done" }] } }, 2).item).toMatchObject({ role: "assistant", text: "Done" });
  });
});
EOF

cat > apps/web/package.json <<'EOF'
{
  "name": "@yep-anywhere/web",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite --host 127.0.0.1",
    "build": "vite build",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "test": "vitest run"
  }
}
EOF

cat > apps/web/tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "useDefineForClassFields": true,
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "allowJs": false,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "allowSyntheticDefaultImports": true,
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "forceConsistentCasingInFileNames": true,
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "types": ["vite/client"]
  },
  "include": ["src", "test", "vite.config.ts", "vitest.config.ts"]
}
EOF

cat > apps/web/vite.config.ts <<'EOF'
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import { VitePWA } from "vite-plugin-pwa";

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: "autoUpdate",
      manifest: {
        name: "Yep Anywhere",
        short_name: "Yep",
        description: "A focused web workspace for Codex",
        theme_color: "#111113",
        background_color: "#111113",
        display: "standalone",
        start_url: "/",
        icons: [
          { src: "/icon.svg", sizes: "any", type: "image/svg+xml", purpose: "any maskable" }
        ]
      },
      workbox: {
        navigateFallbackDenylist: [/^\/api\//]
      }
    })
  ],
  server: {
    port: 5173,
    proxy: {
      "/api": "http://127.0.0.1:3400"
    }
  },
  build: {
    target: "es2022",
    sourcemap: true,
    rollupOptions: {
      output: {
        manualChunks: {
          react: ["react", "react-dom"],
          query: ["@tanstack/react-query", "@tanstack/react-virtual"]
        }
      }
    }
  }
});
EOF

cat > apps/web/vitest.config.ts <<'EOF'
import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    setupFiles: ["./test/setup.ts"]
  }
});
EOF

cat > apps/web/index.html <<'EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />
    <meta name="theme-color" content="#111113" />
    <link rel="icon" href="/icon.svg" />
    <title>Yep Anywhere</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
EOF

mkdir -p apps/web/public
cat > apps/web/public/icon.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" rx="28" fill="#17171a"/>
  <path d="M30 35h18l16 25 16-25h18L72 75v20H56V75L30 35Z" fill="#f4f4f5"/>
</svg>
EOF

cat > apps/web/src/types.ts <<'EOF'
export type CodexMode = "fast" | "ultra";
export type TranscriptRole = "user" | "assistant" | "system" | "tool";

export interface TranscriptItem {
  id: string;
  role: TranscriptRole;
  text: string;
  timestamp?: string;
  kind?: string;
}

export interface SessionSummary {
  id: string;
  cwd: string;
  title: string;
  updatedAt: string;
  preview: string;
}

export interface SessionDetail extends SessionSummary {
  items: TranscriptItem[];
}

export interface FileEntry {
  name: string;
  path: string;
  type: "directory" | "file";
  size: number;
  updatedAt: string;
}
EOF

cat > apps/web/src/api.ts <<'EOF'
import type { CodexMode, FileEntry, SessionDetail, SessionSummary } from "./types";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    ...init,
    headers: { "Content-Type": "application/json", ...init?.headers }
  });
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { error?: string };
    throw new Error(body.error ?? `Request failed with ${response.status}`);
  }
  return response.json() as Promise<T>;
}

export async function fetchSessions(): Promise<SessionSummary[]> {
  return (await request<{ sessions: SessionSummary[] }>("/api/sessions?limit=120")).sessions;
}

export function fetchSession(id: string): Promise<SessionDetail> {
  return request(`/api/sessions/${encodeURIComponent(id)}`);
}

export function startRun(input: { cwd: string; prompt: string; mode: CodexMode; sessionId?: string }): Promise<{ runId: string }> {
  return request("/api/runs", { method: "POST", body: JSON.stringify(input) });
}

export function subscribeRun(
  runId: string,
  handlers: {
    output: (data: { role: "user" | "assistant" | "system" | "tool"; text: string; kind?: string }) => void;
    meta?: (data: { sessionId?: string; status?: string }) => void;
    done: () => void;
    error: (message: string) => void;
  }
): () => void {
  const source = new EventSource(`/api/runs/${encodeURIComponent(runId)}/events`);
  source.addEventListener("output", (event) => handlers.output(JSON.parse((event as MessageEvent).data)));
  source.addEventListener("meta", (event) => handlers.meta?.(JSON.parse((event as MessageEvent).data)));
  source.addEventListener("done", () => {
    handlers.done();
    source.close();
  });
  source.addEventListener("error", (event) => {
    if (event instanceof MessageEvent && event.data) {
      const data = JSON.parse(event.data) as { message?: string };
      handlers.error(data.message ?? "Codex run failed");
    } else {
      handlers.error("The live connection ended unexpectedly");
    }
    source.close();
  });
  return () => source.close();
}

export async function fetchFiles(cwd: string, path: string): Promise<FileEntry[]> {
  const query = new URLSearchParams({ cwd, path });
  return (await request<{ entries: FileEntry[] }>(`/api/files?${query}`)).entries;
}

export async function fetchFile(cwd: string, path: string): Promise<{ text: string; size: number; updatedAt: string }> {
  const query = new URLSearchParams({ cwd, path });
  return request(`/api/file?${query}`);
}

export async function fetchGitStatus(cwd: string): Promise<string> {
  const query = new URLSearchParams({ cwd });
  return (await request<{ status: string }>(`/api/git/status?${query}`)).status;
}
EOF

cat > apps/web/src/hooks/usePersistentState.ts <<'EOF'
import { useCallback, useState } from "react";

export function usePersistentState<T>(key: string, initial: T): [T, (value: T) => void] {
  const [value, setValue] = useState<T>(() => {
    try {
      const stored = localStorage.getItem(key);
      return stored === null ? initial : (JSON.parse(stored) as T);
    } catch {
      return initial;
    }
  });
  const update = useCallback(
    (next: T) => {
      setValue(next);
      localStorage.setItem(key, JSON.stringify(next));
    },
    [key]
  );
  return [value, update];
}
EOF

cat > apps/web/src/components/ModeSwitch.tsx <<'EOF'
import { Gauge, Sparkles } from "lucide-react";
import { memo } from "react";
import type { CodexMode } from "../types";

interface ModeSwitchProps {
  value: CodexMode;
  onChange: (mode: CodexMode) => void;
  compact?: boolean;
}

export const ModeSwitch = memo(function ModeSwitch({ value, onChange, compact = false }: ModeSwitchProps) {
  return (
    <div className={`mode-switch${compact ? " mode-switch--compact" : ""}`} role="radiogroup" aria-label="Codex mode">
      <button type="button" role="radio" aria-checked={value === "fast"} className={value === "fast" ? "is-active" : ""} onClick={() => onChange("fast")} title="Use Codex fast execution">
        <Gauge size={14} aria-hidden="true" />
        <span>Fast</span>
      </button>
      <button type="button" role="radio" aria-checked={value === "ultra"} className={value === "ultra" ? "is-active" : ""} onClick={() => onChange("ultra")} title="Use maximum reasoning effort">
        <Sparkles size={14} aria-hidden="true" />
        <span>Ultra</span>
      </button>
    </div>
  );
});
EOF

cat > apps/web/src/components/ThemeButton.tsx <<'EOF'
import { Moon, Sun } from "lucide-react";
import { useEffect, useState } from "react";

export function ThemeButton() {
  const [light, setLight] = useState(() => localStorage.getItem("yep-theme") === "light");
  useEffect(() => {
    document.documentElement.dataset.theme = light ? "light" : "dark";
    localStorage.setItem("yep-theme", light ? "light" : "dark");
  }, [light]);
  return (
    <button type="button" className="icon-button" onClick={() => setLight((value) => !value)} aria-label={light ? "Use dark theme" : "Use light theme"}>
      {light ? <Moon size={17} /> : <Sun size={17} />}
    </button>
  );
}
EOF

cat > apps/web/src/components/Sidebar.tsx <<'EOF'
import { MessageSquarePlus, Search, X } from "lucide-react";
import { memo, useDeferredValue, useMemo, useState } from "react";
import type { SessionSummary } from "../types";

interface SidebarProps {
  sessions: SessionSummary[];
  selectedId?: string;
  open: boolean;
  onClose: () => void;
  onSelect: (id?: string) => void;
}

function relativeTime(value: string): string {
  const delta = Date.now() - new Date(value).getTime();
  if (delta < 60_000) return "now";
  if (delta < 3_600_000) return `${Math.floor(delta / 60_000)}m`;
  if (delta < 86_400_000) return `${Math.floor(delta / 3_600_000)}h`;
  return `${Math.floor(delta / 86_400_000)}d`;
}

export const Sidebar = memo(function Sidebar({ sessions, selectedId, open, onClose, onSelect }: SidebarProps) {
  const [query, setQuery] = useState("");
  const deferredQuery = useDeferredValue(query.trim().toLowerCase());
  const filtered = useMemo(
    () => deferredQuery ? sessions.filter((session) => `${session.title} ${session.cwd} ${session.preview}`.toLowerCase().includes(deferredQuery)) : sessions,
    [deferredQuery, sessions]
  );
  return (
    <aside className={`sidebar${open ? " is-open" : ""}`} aria-label="Sessions">
      <div className="sidebar__brand">
        <div className="brand-mark">Y</div>
        <div><strong>Yep Anywhere</strong><span>Codex workspace</span></div>
        <button type="button" className="icon-button sidebar__close" onClick={onClose} aria-label="Close sessions"><X size={18} /></button>
      </div>
      <button type="button" className="new-session" onClick={() => { onSelect(undefined); onClose(); }}>
        <MessageSquarePlus size={17} /> New session
      </button>
      <label className="session-search">
        <Search size={15} aria-hidden="true" />
        <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search sessions" />
      </label>
      <div className="session-list">
        {filtered.map((session) => (
          <button key={session.id} type="button" className={`session-row${selectedId === session.id ? " is-active" : ""}`} onClick={() => { onSelect(session.id); onClose(); }}>
            <span className="session-row__title">{session.title}</span>
            <span className="session-row__meta"><span>{session.cwd || "Unknown workspace"}</span><time>{relativeTime(session.updatedAt)}</time></span>
            <span className="session-row__preview">{session.preview}</span>
          </button>
        ))}
        {!filtered.length && <p className="empty-copy">No matching sessions</p>}
      </div>
      <div className="sidebar__footer"><span className="status-dot" /> Local Codex CLI</div>
    </aside>
  );
});
EOF

cat > apps/web/src/components/Header.tsx <<'EOF'
import { Files, Menu, RefreshCw } from "lucide-react";
import type { CodexMode, SessionDetail } from "../types";
import { ModeSwitch } from "./ModeSwitch";
import { ThemeButton } from "./ThemeButton";

interface HeaderProps {
  session?: SessionDetail;
  cwd: string;
  mode: CodexMode;
  busy: boolean;
  onModeChange: (mode: CodexMode) => void;
  onMenu: () => void;
  onFiles: () => void;
  onRefresh: () => void;
}

export function Header({ session, cwd, mode, busy, onModeChange, onMenu, onFiles, onRefresh }: HeaderProps) {
  return (
    <header className="topbar">
      <button type="button" className="icon-button topbar__menu" onClick={onMenu} aria-label="Open sessions"><Menu size={19} /></button>
      <div className="topbar__identity">
        <strong>{session?.title ?? "New session"}</strong>
        <span>{session?.cwd || cwd || "Choose a workspace"}</span>
      </div>
      <div className="topbar__actions">
        {busy && <span className="running-label"><span className="status-dot is-running" />Running</span>}
        <ModeSwitch value={mode} onChange={onModeChange} compact />
        <button type="button" className="icon-button" onClick={onRefresh} aria-label="Refresh"><RefreshCw size={17} /></button>
        <button type="button" className="icon-button" onClick={onFiles} aria-label="Open files"><Files size={17} /></button>
        <ThemeButton />
      </div>
    </header>
  );
}
EOF

cat > apps/web/src/components/MarkdownMessage.tsx <<'EOF'
import ReactMarkdown from "react-markdown";

export default function MarkdownMessage({ text }: { text: string }) {
  return (
    <ReactMarkdown
      components={{
        a: ({ href, children }) => <a href={href} target="_blank" rel="noreferrer">{children}</a>,
        pre: ({ children }) => <pre tabIndex={0}>{children}</pre>
      }}
    >
      {text}
    </ReactMarkdown>
  );
}
EOF

cat > apps/web/src/components/VirtualTranscript.tsx <<'EOF'
import { useVirtualizer } from "@tanstack/react-virtual";
import { Bot, TerminalSquare, UserRound } from "lucide-react";
import { lazy, memo, Suspense, useEffect, useRef } from "react";
import type { TranscriptItem } from "../types";

const MarkdownMessage = lazy(() => import("./MarkdownMessage"));

function MessageIcon({ role }: { role: TranscriptItem["role"] }) {
  if (role === "user") return <UserRound size={16} />;
  if (role === "tool") return <TerminalSquare size={16} />;
  return <Bot size={16} />;
}

export const VirtualTranscript = memo(function VirtualTranscript({ items, busy }: { items: TranscriptItem[]; busy: boolean }) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const virtualizer = useVirtualizer({
    count: items.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: (index) => Math.min(420, 92 + (items[index]?.text.length ?? 0) / 7),
    overscan: 8
  });
  useEffect(() => {
    if (items.length) virtualizer.scrollToIndex(items.length - 1, { align: "end" });
  }, [items.length, virtualizer]);

  if (!items.length) {
    return (
      <div className="welcome-panel">
        <div className="welcome-mark">Y</div>
        <h1>What should Codex build?</h1>
        <p>Choose a workspace, select Fast or Ultra, and start a focused coding session.</p>
        <div className="welcome-grid"><span>Inspect a repository</span><span>Implement a feature</span><span>Review a change</span></div>
      </div>
    );
  }

  return (
    <div className="transcript" ref={scrollRef}>
      <div className="transcript__spacer" style={{ height: `${virtualizer.getTotalSize()}px` }}>
        {virtualizer.getVirtualItems().map((row) => {
          const item = items[row.index];
          if (!item) return null;
          return (
            <article key={item.id} data-index={row.index} ref={virtualizer.measureElement} className={`message message--${item.role}`} style={{ transform: `translateY(${row.start}px)` }}>
              <div className="message__rail"><span className="message__avatar"><MessageIcon role={item.role} /></span></div>
              <div className="message__body">
                <div className="message__label"><strong>{item.role === "user" ? "You" : item.role === "assistant" ? "Codex" : item.role}</strong>{item.kind && <span>{item.kind.replaceAll("_", " ")}</span>}</div>
                {item.role === "assistant" ? <Suspense fallback={<p className="message__plain">{item.text}</p>}><MarkdownMessage text={item.text} /></Suspense> : <p className="message__plain">{item.text}</p>}
              </div>
            </article>
          );
        })}
      </div>
      {busy && <div className="thinking-row"><span /><span /><span /></div>}
    </div>
  );
});
EOF

cat > apps/web/src/components/Composer.tsx <<'EOF'
import { ArrowUp, Paperclip, Square } from "lucide-react";
import { useEffect, useRef } from "react";
import type { CodexMode } from "../types";
import { ModeSwitch } from "./ModeSwitch";

interface ComposerProps {
  value: string;
  cwd: string;
  mode: CodexMode;
  busy: boolean;
  error?: string;
  onValueChange: (value: string) => void;
  onCwdChange: (value: string) => void;
  onModeChange: (mode: CodexMode) => void;
  onSubmit: () => void;
}

export function Composer({ value, cwd, mode, busy, error, onValueChange, onCwdChange, onModeChange, onSubmit }: ComposerProps) {
  const areaRef = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    const area = areaRef.current;
    if (!area) return;
    area.style.height = "0px";
    area.style.height = `${Math.min(220, Math.max(54, area.scrollHeight))}px`;
  }, [value]);
  return (
    <div className="composer-wrap">
      {error && <div className="composer-error" role="alert">{error}</div>}
      <div className="composer">
        <textarea ref={areaRef} value={value} onChange={(event) => onValueChange(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); onSubmit(); } }} placeholder="Ask Codex to change, inspect, or explain…" aria-label="Prompt" />
        <div className="composer__footer">
          <div className="composer__left">
            <button type="button" className="icon-button" disabled aria-label="Attachments are coming soon" title="Attachments are coming soon"><Paperclip size={16} /></button>
            <label className="cwd-field"><span>Workspace</span><input value={cwd} onChange={(event) => onCwdChange(event.target.value)} placeholder="/path/to/project" /></label>
            <ModeSwitch value={mode} onChange={onModeChange} compact />
          </div>
          <button type="button" className={`send-button${busy ? " is-busy" : ""}`} onClick={onSubmit} disabled={!value.trim() || !cwd.trim() || busy} aria-label={busy ? "Codex is running" : "Send prompt"}>{busy ? <Square size={14} /> : <ArrowUp size={18} />}</button>
        </div>
      </div>
      <p className="composer-hint">Enter to send · Shift+Enter for a new line</p>
    </div>
  );
}
EOF

cat > apps/web/src/components/FilePanel.tsx <<'EOF'
import { useQuery } from "@tanstack/react-query";
import { ChevronLeft, File, Folder, X } from "lucide-react";
import { useState } from "react";
import { fetchFile, fetchFiles } from "../api";

export default function FilePanel({ cwd, onClose }: { cwd: string; onClose: () => void }) {
  const [path, setPath] = useState(".");
  const [file, setFile] = useState<string>();
  const entries = useQuery({ queryKey: ["files", cwd, path], queryFn: () => fetchFiles(cwd, path), enabled: Boolean(cwd) });
  const preview = useQuery({ queryKey: ["file", cwd, file], queryFn: () => fetchFile(cwd, file ?? ""), enabled: Boolean(cwd && file) });
  const parent = path === "." ? undefined : path.split("/").slice(0, -1).join("/") || ".";
  return (
    <aside className="file-panel" aria-label="Workspace files">
      <header><button type="button" className="icon-button" onClick={() => file ? setFile(undefined) : parent && setPath(parent)} disabled={!file && !parent} aria-label="Back"><ChevronLeft size={18} /></button><div><strong>{file ?? path}</strong><span>{cwd}</span></div><button type="button" className="icon-button" onClick={onClose} aria-label="Close files"><X size={18} /></button></header>
      {file ? <pre className="file-preview">{preview.data?.text ?? (preview.isLoading ? "Loading…" : preview.error instanceof Error ? preview.error.message : "")}</pre> : <div className="file-list">{entries.data?.map((entry) => <button key={entry.path} type="button" onClick={() => entry.type === "directory" ? setPath(entry.path) : setFile(entry.path)}>{entry.type === "directory" ? <Folder size={16} /> : <File size={16} />}<span>{entry.name}</span><small>{entry.type === "file" ? `${Math.ceil(entry.size / 1024)} KB` : ""}</small></button>)}</div>}
    </aside>
  );
}
EOF

cat > apps/web/src/App.tsx <<'EOF'
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { lazy, Suspense, useCallback, useMemo, useRef, useState } from "react";
import { fetchSession, fetchSessions, startRun, subscribeRun } from "./api";
import { Composer } from "./components/Composer";
import { Header } from "./components/Header";
import { Sidebar } from "./components/Sidebar";
import { VirtualTranscript } from "./components/VirtualTranscript";
import { usePersistentState } from "./hooks/usePersistentState";
import type { CodexMode, TranscriptItem } from "./types";

const FilePanel = lazy(() => import("./components/FilePanel"));

export default function App() {
  const queryClient = useQueryClient();
  const [selectedId, setSelectedId] = useState<string>();
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [filesOpen, setFilesOpen] = useState(false);
  const [draft, setDraft] = useState("");
  const [mode, setMode] = usePersistentState<CodexMode>("yep-codex-mode", "fast");
  const [cwd, setCwd] = usePersistentState("yep-cwd", "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [liveItems, setLiveItems] = useState<TranscriptItem[]>([]);
  const sequence = useRef(0);
  const stopStream = useRef<() => void>();

  const sessions = useQuery({ queryKey: ["sessions"], queryFn: fetchSessions, refetchInterval: busy ? false : 8_000 });
  const detail = useQuery({ queryKey: ["session", selectedId], queryFn: () => fetchSession(selectedId ?? ""), enabled: Boolean(selectedId) });
  const session = detail.data;
  const activeCwd = session?.cwd || cwd;
  const items = useMemo(() => [...(session?.items ?? []), ...liveItems], [liveItems, session?.items]);

  const selectSession = useCallback((id?: string) => {
    stopStream.current?.();
    setSelectedId(id);
    setLiveItems([]);
    setError(undefined);
    if (!id) setDraft("");
  }, []);

  const refresh = useCallback(() => {
    void queryClient.invalidateQueries({ queryKey: ["sessions"] });
    if (selectedId) void queryClient.invalidateQueries({ queryKey: ["session", selectedId] });
  }, [queryClient, selectedId]);

  const submit = useCallback(async () => {
    const prompt = draft.trim();
    const workspace = activeCwd.trim();
    if (!prompt || !workspace || busy) return;
    setError(undefined);
    setBusy(true);
    setDraft("");
    sequence.current += 1;
    const optimistic: TranscriptItem = { id: `live-user-${sequence.current}`, role: "user", text: prompt };
    setLiveItems((current) => [...current, optimistic]);
    try {
      const { runId } = await startRun({ cwd: workspace, prompt, mode, ...(selectedId ? { sessionId: selectedId } : {}) });
      stopStream.current = subscribeRun(runId, {
        output: (output) => {
          sequence.current += 1;
          setLiveItems((current) => [...current, { id: `live-${sequence.current}`, ...output }]);
        },
        meta: (metadata) => {
          if (!selectedId && metadata.sessionId) setSelectedId(metadata.sessionId);
        },
        done: () => {
          setBusy(false);
          refresh();
        },
        error: (message) => {
          setBusy(false);
          setError(message);
          refresh();
        }
      });
    } catch (caught) {
      setBusy(false);
      setError(caught instanceof Error ? caught.message : "Unable to start Codex");
    }
  }, [activeCwd, busy, draft, mode, refresh, selectedId]);

  return (
    <div className={`app-shell${sidebarOpen ? " has-sidebar" : ""}${filesOpen ? " has-files" : ""}`}>
      <Sidebar sessions={sessions.data ?? []} selectedId={selectedId} open={sidebarOpen} onClose={() => setSidebarOpen(false)} onSelect={selectSession} />
      <main className="workspace">
        <Header session={session} cwd={cwd} mode={mode} busy={busy} onModeChange={setMode} onMenu={() => setSidebarOpen(true)} onFiles={() => setFilesOpen((value) => !value)} onRefresh={refresh} />
        <VirtualTranscript items={items} busy={busy} />
        <Composer value={draft} cwd={activeCwd} mode={mode} busy={busy} error={error} onValueChange={setDraft} onCwdChange={setCwd} onModeChange={setMode} onSubmit={submit} />
      </main>
      {filesOpen && <Suspense fallback={<aside className="file-panel file-panel--loading">Loading files…</aside>}><FilePanel cwd={activeCwd} onClose={() => setFilesOpen(false)} /></Suspense>}
      {sidebarOpen && <button type="button" className="scrim" onClick={() => setSidebarOpen(false)} aria-label="Close sessions" />}
    </div>
  );
}
EOF

cat > apps/web/src/main.tsx <<'EOF'
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { registerSW } from "virtual:pwa-register";
import App from "./App";
import "./styles.css";

registerSW({ immediate: true });
const queryClient = new QueryClient({ defaultOptions: { queries: { staleTime: 4_000, retry: 1, refetchOnWindowFocus: false } } });

createRoot(document.getElementById("root")!).render(
  <StrictMode><QueryClientProvider client={queryClient}><App /></QueryClientProvider></StrictMode>
);
EOF

cat > apps/web/src/vite-env.d.ts <<'EOF'
/// <reference types="vite/client" />
/// <reference types="vite-plugin-pwa/client" />
EOF

cat > apps/web/src/styles.css <<'EOF'
:root {
  color-scheme: dark;
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  --bg: #111113;
  --sidebar: #151517;
  --surface: #19191c;
  --surface-2: #202024;
  --surface-3: #28282d;
  --border: rgba(255, 255, 255, 0.08);
  --border-strong: rgba(255, 255, 255, 0.14);
  --text: #f3f3f4;
  --muted: #95959f;
  --subtle: #6e6e78;
  --accent: #f1f1f2;
  --accent-ink: #111113;
  --fast: #8cc8ff;
  --ultra: #d7a7ff;
  --danger: #ff8f92;
  background: var(--bg);
  color: var(--text);
  font-synthesis: none;
  text-rendering: optimizeLegibility;
}

:root[data-theme="light"] {
  color-scheme: light;
  --bg: #f5f5f4;
  --sidebar: #ececeb;
  --surface: #ffffff;
  --surface-2: #f5f5f5;
  --surface-3: #e9e9e8;
  --border: rgba(0, 0, 0, 0.08);
  --border-strong: rgba(0, 0, 0, 0.14);
  --text: #171719;
  --muted: #696970;
  --subtle: #8a8a91;
  --accent: #171719;
  --accent-ink: #ffffff;
}

* { box-sizing: border-box; }
html, body, #root { width: 100%; height: 100%; margin: 0; overflow: hidden; }
body { background: var(--bg); }
button, input, textarea { color: inherit; font: inherit; }
button { -webkit-tap-highlight-color: transparent; }
button:focus-visible, input:focus-visible, textarea:focus-visible, a:focus-visible { outline: 2px solid color-mix(in srgb, var(--fast), white 15%); outline-offset: 2px; }

.app-shell { display: grid; grid-template-columns: 286px minmax(0, 1fr); width: 100%; height: 100%; background: var(--bg); }
.workspace { position: relative; display: grid; grid-template-rows: 58px minmax(0, 1fr) auto; min-width: 0; height: 100%; }
.sidebar { z-index: 20; display: grid; grid-template-rows: auto auto auto minmax(0, 1fr) auto; min-width: 0; padding: 14px 12px 10px; border-right: 1px solid var(--border); background: var(--sidebar); }
.sidebar__brand { display: flex; align-items: center; gap: 10px; min-height: 42px; padding: 0 5px 12px; }
.sidebar__brand > div:nth-child(2) { display: grid; min-width: 0; }
.sidebar__brand strong { font-size: 14px; letter-spacing: -0.01em; }
.sidebar__brand span { margin-top: 2px; color: var(--muted); font-size: 11px; }
.brand-mark, .welcome-mark { display: grid; place-items: center; width: 28px; height: 28px; border: 1px solid var(--border-strong); border-radius: 9px; background: linear-gradient(145deg, var(--surface-3), var(--surface)); font-weight: 750; }
.sidebar__close { display: none !important; margin-left: auto; }
.icon-button { display: inline-grid; place-items: center; width: 34px; height: 34px; padding: 0; border: 0; border-radius: 9px; background: transparent; color: var(--muted); cursor: pointer; transition: background 120ms ease, color 120ms ease; }
.icon-button:hover:not(:disabled) { background: var(--surface-2); color: var(--text); }
.icon-button:disabled { cursor: default; opacity: 0.35; }
.new-session { display: flex; align-items: center; gap: 9px; width: 100%; height: 38px; margin: 3px 0 10px; padding: 0 11px; border: 1px solid var(--border); border-radius: 10px; background: var(--surface); color: var(--text); font-size: 13px; font-weight: 600; cursor: pointer; }
.new-session:hover { border-color: var(--border-strong); background: var(--surface-2); }
.session-search { display: flex; align-items: center; gap: 7px; height: 34px; margin-bottom: 9px; padding: 0 9px; border: 1px solid transparent; border-radius: 9px; background: color-mix(in srgb, var(--surface), transparent 22%); color: var(--subtle); }
.session-search:focus-within { border-color: var(--border-strong); }
.session-search input { width: 100%; min-width: 0; border: 0; outline: 0; background: transparent; font-size: 12px; }
.session-list { min-height: 0; overflow: auto; overscroll-behavior: contain; scrollbar-width: thin; }
.session-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; width: 100%; margin: 1px 0; padding: 10px; border: 1px solid transparent; border-radius: 10px; background: transparent; color: inherit; text-align: left; cursor: pointer; content-visibility: auto; contain-intrinsic-size: auto 76px; }
.session-row:hover { background: color-mix(in srgb, var(--surface-2), transparent 20%); }
.session-row.is-active { border-color: var(--border); background: var(--surface-2); }
.session-row__title { overflow: hidden; font-size: 12.5px; font-weight: 620; text-overflow: ellipsis; white-space: nowrap; }
.session-row__meta { display: contents; }
.session-row__meta span { grid-column: 1; overflow: hidden; margin-top: 5px; color: var(--subtle); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.session-row__meta time { grid-column: 2; grid-row: 1; color: var(--subtle); font-size: 10px; }
.session-row__preview { grid-column: 1 / -1; overflow: hidden; margin-top: 5px; color: var(--muted); font-size: 11px; line-height: 1.35; text-overflow: ellipsis; white-space: nowrap; }
.empty-copy { padding: 24px 12px; color: var(--muted); font-size: 12px; text-align: center; }
.sidebar__footer { display: flex; align-items: center; gap: 7px; padding: 10px 6px 2px; color: var(--muted); font-size: 11px; }
.status-dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; background: #69d596; box-shadow: 0 0 0 3px color-mix(in srgb, #69d596, transparent 82%); }
.status-dot.is-running { background: var(--fast); box-shadow: 0 0 0 3px color-mix(in srgb, var(--fast), transparent 82%); animation: pulse 1.4s ease-in-out infinite; }

.topbar { z-index: 5; display: flex; align-items: center; gap: 10px; min-width: 0; padding: 0 14px 0 20px; border-bottom: 1px solid var(--border); background: color-mix(in srgb, var(--bg), transparent 7%); backdrop-filter: blur(16px); }
.topbar__menu { display: none; }
.topbar__identity { display: grid; min-width: 0; }
.topbar__identity strong { overflow: hidden; font-size: 13px; text-overflow: ellipsis; white-space: nowrap; }
.topbar__identity span { overflow: hidden; max-width: min(46vw, 720px); margin-top: 2px; color: var(--muted); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.topbar__actions { display: flex; align-items: center; gap: 4px; margin-left: auto; }
.running-label { display: flex; align-items: center; gap: 7px; margin-right: 5px; color: var(--muted); font-size: 11px; }
.mode-switch { display: inline-flex; align-items: center; gap: 3px; padding: 3px; border: 1px solid var(--border); border-radius: 11px; background: var(--surface); }
.mode-switch button { display: inline-flex; align-items: center; justify-content: center; gap: 6px; height: 30px; padding: 0 10px; border: 0; border-radius: 8px; background: transparent; color: var(--muted); font-size: 11.5px; font-weight: 650; cursor: pointer; transition: background 120ms ease, color 120ms ease, box-shadow 120ms ease; }
.mode-switch button:hover { color: var(--text); }
.mode-switch button.is-active { background: var(--surface-3); color: var(--text); box-shadow: 0 1px 2px rgba(0, 0, 0, 0.18); }
.mode-switch button:first-child.is-active svg { color: var(--fast); }
.mode-switch button:last-child.is-active svg { color: var(--ultra); }
.mode-switch--compact button { height: 26px; padding: 0 8px; font-size: 10.5px; }

.transcript { min-height: 0; overflow: auto; overscroll-behavior: contain; scrollbar-width: thin; scroll-padding-bottom: 160px; }
.transcript__spacer { position: relative; width: min(860px, calc(100% - 40px)); margin: 0 auto; }
.message { position: absolute; top: 0; left: 0; display: grid; grid-template-columns: 30px minmax(0, 1fr); gap: 12px; width: 100%; padding: 22px 4px; border-bottom: 1px solid var(--border); contain: layout paint style; }
.message__rail { padding-top: 1px; }
.message__avatar { display: grid; place-items: center; width: 28px; height: 28px; border: 1px solid var(--border); border-radius: 9px; background: var(--surface); color: var(--muted); }
.message--user .message__avatar { background: var(--surface-3); color: var(--text); }
.message__body { min-width: 0; color: var(--text); font-size: 14px; line-height: 1.62; overflow-wrap: anywhere; }
.message__label { display: flex; align-items: baseline; gap: 8px; margin-bottom: 8px; }
.message__label strong { font-size: 12px; }
.message__label span { color: var(--subtle); font-size: 10px; text-transform: capitalize; }
.message__plain { margin: 0; white-space: pre-wrap; }
.message__body > :first-child { margin-top: 0; }
.message__body > :last-child { margin-bottom: 0; }
.message__body p, .message__body ul, .message__body ol { margin: 0.65em 0; }
.message__body h1, .message__body h2, .message__body h3 { margin: 1.25em 0 0.55em; line-height: 1.25; }
.message__body h1 { font-size: 1.3em; } .message__body h2 { font-size: 1.17em; } .message__body h3 { font-size: 1.06em; }
.message__body code { padding: 0.12em 0.34em; border: 1px solid var(--border); border-radius: 5px; background: var(--surface-2); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9em; }
.message__body pre { overflow: auto; margin: 0.9em 0; padding: 14px; border: 1px solid var(--border); border-radius: 10px; background: #0d0d0f; color: #ededee; line-height: 1.52; }
.message__body pre code { padding: 0; border: 0; background: transparent; }
.message__body a { color: var(--fast); }
.thinking-row { position: sticky; bottom: 0; display: flex; gap: 4px; width: min(860px, calc(100% - 40px)); margin: 0 auto; padding: 14px 46px; background: linear-gradient(transparent, var(--bg) 45%); }
.thinking-row span { width: 5px; height: 5px; border-radius: 50%; background: var(--muted); animation: bounce 1.2s infinite; }.thinking-row span:nth-child(2){animation-delay:120ms}.thinking-row span:nth-child(3){animation-delay:240ms}
.welcome-panel { display: grid; place-items: center; align-content: center; min-height: 100%; padding: 36px; text-align: center; }
.welcome-panel .welcome-mark { width: 42px; height: 42px; border-radius: 13px; font-size: 18px; }
.welcome-panel h1 { margin: 18px 0 6px; font-size: clamp(25px, 3vw, 38px); letter-spacing: -0.035em; }
.welcome-panel p { max-width: 510px; margin: 0; color: var(--muted); font-size: 14px; }
.welcome-grid { display: flex; flex-wrap: wrap; justify-content: center; gap: 8px; margin-top: 26px; }
.welcome-grid span { padding: 8px 11px; border: 1px solid var(--border); border-radius: 9px; background: var(--surface); color: var(--muted); font-size: 11px; }

.composer-wrap { z-index: 6; width: min(860px, calc(100% - 40px)); margin: 0 auto; padding: 8px 0 max(14px, env(safe-area-inset-bottom)); background: linear-gradient(transparent, var(--bg) 18%); }
.composer { overflow: hidden; border: 1px solid var(--border-strong); border-radius: 16px; background: var(--surface); box-shadow: 0 18px 50px rgba(0, 0, 0, 0.22); }
.composer:focus-within { border-color: color-mix(in srgb, var(--fast), var(--border) 68%); }
.composer textarea { display: block; width: 100%; min-height: 54px; max-height: 220px; resize: none; padding: 14px 15px 7px; border: 0; outline: 0; background: transparent; font-size: 14px; line-height: 1.48; }
.composer textarea::placeholder { color: var(--subtle); }
.composer__footer { display: flex; align-items: center; gap: 9px; min-height: 43px; padding: 4px 7px 7px 8px; }
.composer__left { display: flex; align-items: center; gap: 5px; min-width: 0; }
.cwd-field { display: flex; align-items: center; gap: 6px; min-width: 0; height: 30px; padding: 0 8px; border: 1px solid var(--border); border-radius: 8px; color: var(--subtle); }
.cwd-field span { font-size: 9px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; }
.cwd-field input { width: min(25vw, 250px); min-width: 80px; border: 0; outline: 0; background: transparent; color: var(--muted); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 10px; }
.send-button { display: grid; place-items: center; width: 32px; height: 32px; margin-left: auto; padding: 0; border: 0; border-radius: 9px; background: var(--accent); color: var(--accent-ink); cursor: pointer; }
.send-button:disabled { cursor: default; opacity: 0.3; }.send-button.is-busy{background:var(--surface-3);color:var(--muted)}
.composer-hint { margin: 6px 0 0; color: var(--subtle); font-size: 9.5px; text-align: center; }
.composer-error { margin-bottom: 7px; padding: 8px 11px; border: 1px solid color-mix(in srgb, var(--danger), transparent 68%); border-radius: 9px; background: color-mix(in srgb, var(--danger), transparent 90%); color: var(--danger); font-size: 11px; }

.file-panel { z-index: 18; display: grid; grid-template-rows: 58px minmax(0, 1fr); width: min(430px, 38vw); border-left: 1px solid var(--border); background: var(--sidebar); }
.app-shell.has-files { grid-template-columns: 286px minmax(0, 1fr) minmax(300px, 430px); }
.file-panel header { display: flex; align-items: center; gap: 8px; padding: 0 10px; border-bottom: 1px solid var(--border); }
.file-panel header > div { display: grid; min-width: 0; flex: 1; }.file-panel header strong,.file-panel header span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.file-panel header strong{font-size:12px}.file-panel header span{margin-top:2px;color:var(--muted);font-size:9px;font-family:ui-monospace,monospace}
.file-list { min-height: 0; overflow: auto; padding: 8px; }.file-list button{display:grid;grid-template-columns:20px minmax(0,1fr) auto;align-items:center;gap:6px;width:100%;padding:8px;border:0;border-radius:8px;background:transparent;color:var(--muted);text-align:left;cursor:pointer}.file-list button:hover{background:var(--surface-2);color:var(--text)}.file-list button span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:11px}.file-list button small{color:var(--subtle);font-size:9px}
.file-preview { min-height: 0; margin: 0; overflow: auto; padding: 14px; background: color-mix(in srgb, var(--bg), black 4%); color: var(--text); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; line-height: 1.55; white-space: pre; tab-size: 2; }.file-panel--loading{display:grid;place-items:center;color:var(--muted);font-size:12px}
.scrim { display: none; }

@keyframes pulse { 50% { opacity: 0.45; } }
@keyframes bounce { 50% { transform: translateY(-3px); opacity: 0.5; } }
@media (prefers-reduced-motion: reduce) { *, *::before, *::after { scroll-behavior: auto !important; animation-duration: 0.01ms !important; animation-iteration-count: 1 !important; transition-duration: 0.01ms !important; } }

@media (max-width: 1100px) {
  .app-shell, .app-shell.has-files { grid-template-columns: 248px minmax(0, 1fr); }
  .file-panel { position: fixed; top: 0; right: 0; bottom: 0; width: min(430px, 88vw); box-shadow: -20px 0 50px rgba(0,0,0,.25); }
  .cwd-field input { width: min(20vw, 180px); }
}

@media (max-width: 760px) {
  .app-shell, .app-shell.has-files { display: block; }
  .workspace { width: 100%; }
  .sidebar { position: fixed; inset: 0 auto 0 0; width: min(310px, 88vw); transform: translateX(-102%); box-shadow: 18px 0 50px rgba(0,0,0,.3); transition: transform 180ms ease; }
  .sidebar.is-open { transform: translateX(0); }
  .sidebar__close, .topbar__menu { display: inline-grid !important; }
  .scrim { position: fixed; z-index: 15; inset: 0; display: block; border: 0; background: rgba(0,0,0,.45); }
  .topbar { padding: 0 8px; }.topbar__identity span{max-width:42vw}.running-label{display:none}.topbar__actions>.mode-switch{display:none}
  .transcript__spacer, .thinking-row, .composer-wrap { width: calc(100% - 20px); }
  .message { grid-template-columns: 26px minmax(0, 1fr); gap: 9px; padding: 17px 1px; }.message__avatar{width:25px;height:25px;border-radius:8px}.message__body{font-size:13px}
  .composer-wrap { padding-bottom: max(9px, env(safe-area-inset-bottom)); }.composer{border-radius:14px}.composer__footer{align-items:flex-end}.composer__left{flex-wrap:wrap}.cwd-field{order:3;width:100%}.cwd-field input{width:100%}.composer-hint{display:none}
  .file-panel { width: 100%; }
}
EOF

cat > apps/web/test/setup.ts <<'EOF'
import "@testing-library/jest-dom/vitest";
EOF

cat > apps/web/test/ModeSwitch.test.tsx <<'EOF'
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { ModeSwitch } from "../src/components/ModeSwitch";

describe("ModeSwitch", () => {
  it("exposes accessible Fast and Ultra choices", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    render(<ModeSwitch value="fast" onChange={onChange} />);
    expect(screen.getByRole("radio", { name: "Fast" })).toHaveAttribute("aria-checked", "true");
    await user.click(screen.getByRole("radio", { name: "Ultra" }));
    expect(onChange).toHaveBeenCalledWith("ultra");
  });
});
EOF

cat > scripts/check-focus.mjs <<'EOF'
import { readFile, readdir } from "node:fs/promises";
import { extname, join, relative } from "node:path";

const first = `cl${"aude"}`;
const second = `anth${"ropic"}`;
const blocked = [first, second].map((value) => value.toLowerCase());
const checkedExtensions = new Set([".cjs", ".css", ".html", ".js", ".json", ".md", ".mjs", ".ts", ".tsx", ".yaml", ".yml"]);
const matches = [];

async function walk(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if ([".git", "node_modules", "dist", "coverage"].includes(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) await walk(path);
    else if (checkedExtensions.has(extname(entry.name)) || entry.name === ".env.example") {
      const text = (await readFile(path, "utf8")).toLowerCase();
      if (blocked.some((term) => text.includes(term) || entry.name.toLowerCase().includes(term))) matches.push(relative(process.cwd(), path));
    }
  }
}

await walk(process.cwd());
if (matches.length) {
  console.error(`Unexpected provider integration in:\n${matches.join("\n")}`);
  process.exit(1);
}
EOF

cat > scripts/check-bundle.mjs <<'EOF'
import { gzipSync } from "node:zlib";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";

const assets = "apps/web/dist/assets";
const files = (await readdir(assets)).filter((file) => file.endsWith(".js"));
const sizes = await Promise.all(files.map(async (file) => ({ file, gzip: gzipSync(await readFile(join(assets, file))).byteLength })));
const largest = sizes.sort((a, b) => b.gzip - a.gzip)[0];
const entry = sizes.find(({ file }) => file.startsWith("index-"));
if (!largest || !entry) throw new Error("Production JavaScript assets were not found");
console.log(`entry=${entry.gzip} largest=${largest.file}:${largest.gzip}`);
if (entry.gzip > 220_000) throw new Error(`Initial bundle exceeds 220 KB gzip: ${entry.gzip}`);
if (largest.gzip > 480_000) throw new Error(`A lazy chunk exceeds 480 KB gzip: ${largest.file}`);
EOF

cat > scripts/smoke.mjs <<'EOF'
import { spawn } from "node:child_process";

const port = 3417;
const child = spawn(process.execPath, ["apps/server/dist/index.js"], {
  env: { ...process.env, HOST: "127.0.0.1", PORT: String(port), CODEX_WORKSPACE_ROOTS: process.cwd() },
  stdio: ["ignore", "pipe", "pipe"]
});
let ok = false;
try {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 125));
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`);
      const body = await response.json();
      if (response.ok && body.ok === true) { ok = true; break; }
    } catch {}
  }
} finally {
  child.kill();
}
if (!ok) throw new Error("Production health check did not become ready");
EOF

cat > .github/workflows/ci.yml <<'EOF'
name: Codex CI

on:
  push:
    branches: [main, codex-fast-ultra-pi-ui]
  pull_request:

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-node@v4
        with:
          node-version-file: .node-version
          cache: pnpm
      - run: corepack enable
      - run: pnpm install --frozen-lockfile
      - run: pnpm format:check
      - run: pnpm lint
      - run: pnpm typecheck
      - run: pnpm test
      - run: pnpm build
      - run: pnpm perf:check
      - run: pnpm test:smoke
EOF

corepack enable
pnpm add -Dw -E @biomejs/biome@latest typescript@latest @types/node@latest tsx@latest vitest@latest
pnpm --filter @yep-anywhere/server add -E @hono/node-server@latest hono@latest zod@latest
pnpm --filter @yep-anywhere/server add -D -E @types/node@latest tsx@latest typescript@latest vitest@latest
pnpm --filter @yep-anywhere/web add -E @tanstack/react-query@latest @tanstack/react-virtual@latest lucide-react@latest react@latest react-dom@latest react-markdown@latest
pnpm --filter @yep-anywhere/web add -D -E @testing-library/jest-dom@latest @testing-library/react@latest @testing-library/user-event@latest @types/react@latest @types/react-dom@latest @vitejs/plugin-react@latest jsdom@latest typescript@latest vite@latest vite-plugin-pwa@latest vitest@latest
pnpm format
pnpm lint
pnpm typecheck
pnpm test
pnpm build
pnpm perf:check
pnpm test:smoke

git add -A
git commit -m "Build a focused Codex workspace"
git push origin HEAD:codex-fast-ultra-pi-ui
