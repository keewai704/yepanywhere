#!/usr/bin/env bash
set -euo pipefail

LICENSE_DIR="$(mktemp -d)"
for candidate in LICENSE LICENSE.md LICENSE.txt NOTICE NOTICE.md; do
  [[ -f "$candidate" ]] && cp "$candidate" "$LICENSE_DIR/$candidate"
done
find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
mkdir -p .github/workflows server src public scripts test
for candidate in "$LICENSE_DIR"/*; do [[ -f "$candidate" ]] && cp "$candidate" .; done

cat > package.json <<'EOF'
{
  "name": "yep-anywhere",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "packageManager": "pnpm@10.34.5",
  "engines": { "node": ">=24" },
  "scripts": {
    "dev": "node scripts/dev.mjs",
    "build": "vite build",
    "typecheck": "tsc --noEmit",
    "test": "node --test test/*.test.mjs",
    "lint": "biome check . && node scripts/check-focus.mjs",
    "format": "biome format --write .",
    "format:check": "biome format .",
    "perf:check": "node scripts/check-bundle.mjs",
    "test:smoke": "node scripts/smoke.mjs",
    "start": "node server/index.mjs"
  }
}
EOF

cat > .node-version <<'EOF'
24
EOF

cat > .gitignore <<'EOF'
node_modules/
dist/
coverage/
.vite/
.env
*.log
.DS_Store
EOF

cat > .env.example <<'EOF'
HOST=127.0.0.1
PORT=3400
CODEX_HOME=
CODEX_WORKSPACE_ROOTS=
EOF

cat > biome.json <<'EOF'
{
  "files": { "includes": ["**", "!dist", "!node_modules", "!pnpm-lock.yaml"] },
  "formatter": { "enabled": true, "indentStyle": "space", "indentWidth": 2, "lineWidth": 100 },
  "linter": { "enabled": true, "rules": { "recommended": false } },
  "javascript": { "formatter": { "quoteStyle": "double", "semicolons": "always", "trailingCommas": "all" } }
}
EOF

cat > tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "useDefineForClassFields": true,
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": false,
    "skipLibCheck": true,
    "types": ["vite/client", "node"]
  },
  "include": ["src", "vite.config.ts"]
}
EOF

cat > vite.config.ts <<'EOF'
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "127.0.0.1",
    port: 5173,
    proxy: { "/api": "http://127.0.0.1:3400" }
  },
  build: {
    target: "es2022",
    sourcemap: true
  }
});
EOF

cat > index.html <<'EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <meta name="theme-color" content="#111113" />
    <link rel="icon" href="/icon.svg" />
    <link rel="manifest" href="/manifest.webmanifest" />
    <title>Yep Anywhere</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
EOF

cat > public/icon.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" rx="28" fill="#17171a"/>
  <path d="M30 34h18l16 26 16-26h18L72 76v19H56V76L30 34Z" fill="#f4f4f5"/>
</svg>
EOF

cat > public/manifest.webmanifest <<'EOF'
{
  "name": "Yep Anywhere",
  "short_name": "Yep",
  "description": "A focused web workspace for Codex",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#111113",
  "theme_color": "#111113",
  "icons": [{ "src": "/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any" }]
}
EOF

cat > public/service-worker.js <<'EOF'
const CACHE = "yep-shell-v1";
self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(["/", "/manifest.webmanifest", "/icon.svg"])));
  self.skipWaiting();
});
self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key)))));
  self.clients.claim();
});
self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.pathname.startsWith("/api/")) return;
  event.respondWith(fetch(event.request).then((response) => {
    const copy = response.clone();
    caches.open(CACHE).then((cache) => cache.put(event.request, copy));
    return response;
  }).catch(() => caches.match(event.request).then((cached) => cached || caches.match("/"))));
});
EOF

cat > server/mode.mjs <<'EOF'
import { spawn } from "node:child_process";

let cachedCapabilities;

function readHelp() {
  return new Promise((resolve) => {
    const child = spawn("codex", ["--help"], { stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    const timer = setTimeout(() => child.kill(), 2500);
    child.stdout.on("data", (chunk) => { output += chunk.toString("utf8"); });
    child.stderr.on("data", (chunk) => { output += chunk.toString("utf8"); });
    child.once("error", () => { clearTimeout(timer); resolve(""); });
    child.once("close", () => { clearTimeout(timer); resolve(output); });
  });
}

export async function detectCapabilities(reader = readHelp) {
  if (reader === readHelp && cachedCapabilities) return cachedCapabilities;
  const result = Promise.resolve(reader()).then((help) => ({
    fast: /(^|\s)--fast(?:\s|,|$)/m.test(help),
    ultra: /(^|\s)--ultra(?:\s|,|$)/m.test(help)
  }));
  if (reader === readHelp) cachedCapabilities = result;
  return result;
}

export function modeArguments(mode, capabilities) {
  if (mode === "fast") return capabilities.fast ? ["--fast"] : ["-c", 'service_tier="fast"'];
  return capabilities.ultra ? ["--ultra"] : ["-c", 'model_reasoning_effort="xhigh"'];
}

export async function buildCodexArguments({ mode, prompt, sessionId, capabilities }) {
  const supported = capabilities || await detectCapabilities();
  const args = [...modeArguments(mode, supported), "exec"];
  if (sessionId) args.push("resume", "--json", "--skip-git-repo-check", sessionId, prompt);
  else args.push("--json", "--skip-git-repo-check", prompt);
  return args;
}
EOF

cat > server/history.mjs <<'EOF'
import { createHash } from "node:crypto";
import { readFile, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";

const root = join(process.env.CODEX_HOME || join(homedir(), ".codex"), "sessions");
const cache = new Map();
const paths = new Map();

async function collect(directory, output, depth = 0) {
  if (depth > 9 || output.length > 6000) return;
  let entries = [];
  try { entries = await readdir(directory, { withFileTypes: true }); } catch { return; }
  await Promise.all(entries.map(async (entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) await collect(path, output, depth + 1);
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) output.push(path);
  }));
}

function record(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
}

function text(value, depth = 0) {
  if (depth > 6) return "";
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map((entry) => text(entry, depth + 1)).filter(Boolean).join("\n");
  const object = record(value);
  if (!object) return "";
  for (const key of ["text", "input_text", "output_text", "content", "message"]) {
    if (object[key] !== undefined) {
      const found = text(object[key], depth + 1);
      if (found) return found;
    }
  }
  return "";
}

export function normalizeRecord(value, index = 0) {
  const object = record(value);
  if (!object) return {};
  const payload = record(object.payload) || object;
  const outerType = typeof object.type === "string" ? object.type : "";
  const type = typeof payload.type === "string" ? payload.type : outerType;
  if (outerType === "session_meta" || type === "session_meta") return { metadata: payload };
  let role = ["user", "assistant", "system", "tool"].includes(payload.role) ? payload.role : undefined;
  if (!role && type === "user_message") role = "user";
  if (!role && ["agent_message", "assistant_message"].includes(type)) role = "assistant";
  if (!role && type.includes("tool")) role = "tool";
  const nested = record(payload.message);
  if (!role && nested && ["user", "assistant", "system", "tool"].includes(nested.role)) role = nested.role;
  const content = text(payload.content ?? nested?.content ?? payload.text ?? payload.message).trim();
  if (!role || !content) return {};
  const id = createHash("sha1").update(`${index}:${role}:${content}`).digest("hex").slice(0, 16);
  return { item: { id, role, text: content, kind: type || undefined, timestamp: object.timestamp || payload.timestamp } };
}

function firstString(object, keys) {
  if (!object) return undefined;
  for (const key of keys) if (typeof object[key] === "string" && object[key]) return object[key];
}

async function parse(path) {
  const info = await stat(path);
  const stamp = `${info.size}:${info.mtimeMs}`;
  if (cache.get(path)?.stamp === stamp) return cache.get(path).detail;
  const lines = (await readFile(path, "utf8")).split("\n");
  const items = [];
  let metadata;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]?.trim();
    if (!line) continue;
    try {
      const normalized = normalizeRecord(JSON.parse(line), index);
      metadata ||= normalized.metadata;
      const previous = items.at(-1);
      if (normalized.item && !(previous?.role === normalized.item.role && previous.text === normalized.item.text)) items.push(normalized.item);
    } catch {}
  }
  const id = firstString(metadata, ["id", "session_id", "thread_id"]) || basename(path, ".jsonl");
  const cwd = firstString(metadata, ["cwd", "working_directory", "workspace"]) || "";
  const first = items.find((item) => item.role === "user")?.text || "Untitled session";
  const latest = items.at(-1)?.text || first;
  const detail = {
    id,
    cwd,
    title: first.replace(/\s+/g, " ").slice(0, 82),
    preview: latest.replace(/\s+/g, " ").slice(0, 150),
    updatedAt: info.mtime.toISOString(),
    items
  };
  cache.set(path, { stamp, detail });
  paths.set(id, path);
  return detail;
}

export async function listSessions(limit = 120) {
  const files = [];
  await collect(root, files);
  const candidates = (await Promise.all(files.map(async (path) => {
    try { return { path, time: (await stat(path)).mtimeMs }; } catch { return undefined; }
  }))).filter(Boolean).sort((a, b) => b.time - a.time).slice(0, Math.max(1, Math.min(limit, 250)));
  const details = await Promise.all(candidates.map((entry) => parse(entry.path)));
  return details.map(({ items, ...summary }) => summary);
}

export async function getSession(id) {
  if (!paths.has(id)) await listSessions(250);
  const path = paths.get(id);
  return path ? parse(path) : undefined;
}
EOF

cat > server/index.mjs <<'EOF'
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createReadStream, realpathSync, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { delimiter, dirname, extname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { buildCodexArguments } from "./mode.mjs";
import { getSession, listSessions } from "./history.mjs";

const host = process.env.HOST || "127.0.0.1";
const port = Number.parseInt(process.env.PORT || "3400", 10);
const allowedRoots = (process.env.CODEX_WORKSPACE_ROOTS || process.cwd()).split(delimiter).filter(Boolean).map((entry) => realpathSync(resolve(entry)));
const runs = new Map();
const here = dirname(fileURLToPath(import.meta.url));
const webRoot = resolve(here, "../dist");
const mime = { ".css": "text/css; charset=utf-8", ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".json": "application/json; charset=utf-8", ".svg": "image/svg+xml", ".webmanifest": "application/manifest+json" };

function isInside(root, candidate) {
  const value = relative(root, candidate);
  return value === "" || (value !== ".." && !value.startsWith(`..${sep}`));
}

function workspace(value) {
  const candidate = realpathSync(resolve(value));
  if (!allowedRoots.some((root) => isInside(root, candidate))) throw new Error("Workspace is outside the configured roots");
  return candidate;
}

function json(response, status, body) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  response.end(JSON.stringify(body));
}

async function body(request) {
  let text = "";
  for await (const chunk of request) {
    text += chunk;
    if (text.length > 250000) throw new Error("Request is too large");
  }
  return JSON.parse(text || "{}");
}

function send(run, type, data) {
  const event = { id: run.events.length + 1, type, data };
  run.events.push(event);
  if (["done", "error"].includes(type)) run.done = true;
  for (const response of run.clients) {
    response.write(`id: ${event.id}\nevent: ${type}\ndata: ${JSON.stringify(data)}\n\n`);
    if (run.done) response.end();
  }
  if (run.done) run.clients.clear();
}

function object(value) { return value && typeof value === "object" && !Array.isArray(value) ? value : undefined; }
function deepString(value, keys, depth = 0) {
  if (depth > 5) return undefined;
  const current = object(value);
  if (!current) return undefined;
  for (const [key, entry] of Object.entries(current)) if (keys.includes(key) && typeof entry === "string" && entry) return entry;
  for (const entry of Object.values(current)) { const found = deepString(entry, keys, depth + 1); if (found) return found; }
}
function deepText(value, depth = 0) {
  if (depth > 6) return "";
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map((entry) => deepText(entry, depth + 1)).filter(Boolean).join("\n");
  const current = object(value);
  if (!current) return "";
  for (const key of ["text", "output_text", "content", "message", "delta"]) {
    if (current[key] !== undefined) { const found = deepText(current[key], depth + 1); if (found) return found; }
  }
  return "";
}
function normalize(value) {
  const current = object(value);
  if (!current) return undefined;
  const payload = object(current.payload) || current;
  const type = typeof payload.type === "string" ? payload.type : typeof current.type === "string" ? current.type : "";
  const text = deepText(payload).trim();
  if (!text) return undefined;
  let role = ["user", "assistant", "system", "tool"].includes(payload.role) ? payload.role : "assistant";
  if (type.includes("tool")) role = "tool";
  if (type.includes("reasoning")) role = "system";
  return { role, text, kind: type || undefined };
}

async function startRun(input) {
  const runId = randomUUID();
  const run = { events: [], clients: new Set(), done: false, touched: Date.now() };
  runs.set(runId, run);
  const args = await buildCodexArguments(input);
  send(run, "meta", { mode: input.mode, status: "starting" });
  const child = spawn("codex", args, { cwd: input.cwd, env: { ...process.env, TERM: "dumb", NO_COLOR: "1" }, stdio: ["ignore", "pipe", "pipe"] });
  child.once("error", (error) => send(run, "error", { message: error.message }));
  createInterface({ input: child.stdout }).on("line", (line) => {
    try {
      const parsed = JSON.parse(line);
      const sessionId = deepString(parsed, ["session_id", "thread_id"]);
      if (sessionId) send(run, "meta", { sessionId });
      const output = normalize(parsed);
      if (output) send(run, "output", output);
    } catch { if (line.trim()) send(run, "output", { role: "assistant", text: line.trim(), kind: "text" }); }
  });
  createInterface({ input: child.stderr }).on("line", (line) => { if (line.trim()) send(run, "log", { message: line.trim() }); });
  child.once("close", (code, signal) => code === 0 ? send(run, "done", { code, signal }) : send(run, "error", { message: `Codex exited with code ${code ?? "unknown"}`, code, signal }));
  return runId;
}

function serveAsset(requestPath, response) {
  const clean = requestPath === "/" ? "index.html" : decodeURIComponent(requestPath.slice(1));
  let path = clean.includes("..") ? join(webRoot, "index.html") : join(webRoot, clean);
  try { if (!statSync(path).isFile()) path = join(webRoot, "index.html"); } catch { path = join(webRoot, "index.html"); }
  response.writeHead(200, { "Content-Type": mime[extname(path)] || "application/octet-stream", "Cache-Control": path.endsWith("index.html") ? "no-cache" : "public, max-age=31536000, immutable" });
  createReadStream(path).pipe(response);
}

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
    if (request.method === "GET" && url.pathname === "/api/health") return json(response, 200, { ok: true, product: "Yep Anywhere" });
    if (request.method === "GET" && url.pathname === "/api/sessions") return json(response, 200, { sessions: await listSessions(Number.parseInt(url.searchParams.get("limit") || "120", 10)) });
    if (request.method === "GET" && url.pathname.startsWith("/api/sessions/")) {
      const session = await getSession(decodeURIComponent(url.pathname.slice("/api/sessions/".length)));
      return session ? json(response, 200, session) : json(response, 404, { error: "Session not found" });
    }
    if (request.method === "POST" && url.pathname === "/api/runs") {
      const input = await body(request);
      if (!input.prompt?.trim() || !["fast", "ultra"].includes(input.mode)) return json(response, 400, { error: "A prompt and mode are required" });
      const cwd = workspace(input.cwd);
      const runId = await startRun({ cwd, prompt: input.prompt, mode: input.mode, sessionId: input.sessionId });
      return json(response, 202, { runId });
    }
    if (request.method === "GET" && url.pathname.startsWith("/api/runs/") && url.pathname.endsWith("/events")) {
      const id = decodeURIComponent(url.pathname.slice("/api/runs/".length, -"/events".length));
      const run = runs.get(id);
      if (!run) return json(response, 404, { error: "Run not found" });
      response.writeHead(200, { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-cache, no-transform", Connection: "keep-alive", "X-Accel-Buffering": "no" });
      for (const event of run.events) response.write(`id: ${event.id}\nevent: ${event.type}\ndata: ${JSON.stringify(event.data)}\n\n`);
      if (run.done) return response.end();
      run.clients.add(response);
      request.on("close", () => run.clients.delete(response));
      return;
    }
    if (url.pathname.startsWith("/api/")) return json(response, 404, { error: "Not found" });
    return serveAsset(url.pathname, response);
  } catch (error) {
    return json(response, 500, { error: error instanceof Error ? error.message : "Unexpected error" });
  }
});

setInterval(() => {
  const cutoff = Date.now() - 30 * 60 * 1000;
  for (const [id, run] of runs) if (run.done && run.touched < cutoff) runs.delete(id);
}, 300000).unref();

server.listen(port, host, () => process.stdout.write(`Yep Anywhere listening on http://${host}:${port}\n`));
EOF

cat > src/types.ts <<'EOF'
export type CodexMode = "fast" | "ultra";
export type Role = "user" | "assistant" | "system" | "tool";
export interface Item { id: string; role: Role; text: string; kind?: string; timestamp?: string; }
export interface Session { id: string; cwd: string; title: string; preview: string; updatedAt: string; items?: Item[]; }
EOF

cat > src/api.ts <<'EOF'
import type { CodexMode, Session } from "./types";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const headers = new Headers(init?.headers);
  headers.set("Content-Type", "application/json");
  const response = await fetch(path, { ...init, headers });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.error || `Request failed with ${response.status}`);
  }
  return response.json();
}

export async function sessions(): Promise<Session[]> { return (await request<{ sessions: Session[] }>("/api/sessions?limit=120")).sessions; }
export function session(id: string): Promise<Session> { return request(`/api/sessions/${encodeURIComponent(id)}`); }
export function run(input: { cwd: string; prompt: string; mode: CodexMode; sessionId?: string }): Promise<{ runId: string }> { return request("/api/runs", { method: "POST", body: JSON.stringify(input) }); }
EOF

cat > src/Markdown.tsx <<'EOF'
import ReactMarkdown from "react-markdown";

export default function Markdown({ text }: { text: string }) {
  return <ReactMarkdown components={{ a: ({ href, children }) => <a href={href} target="_blank" rel="noreferrer">{children}</a>, pre: ({ children }) => <pre tabIndex={0}>{children}</pre> }}>{text}</ReactMarkdown>;
}
EOF

cat > src/App.tsx <<'EOF'
import { Gauge, Menu, MessageSquarePlus, Moon, Search, Sparkles, Sun, X, ArrowUp, Bot, UserRound, TerminalSquare } from "lucide-react";
import { lazy, Suspense, useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import { run, session, sessions } from "./api";
import type { CodexMode, Item, Session } from "./types";

const Markdown = lazy(() => import("./Markdown"));

function stored<T>(key: string, fallback: T): [T, (value: T) => void] {
  const [value, setValue] = useState<T>(() => {
    try { const current = localStorage.getItem(key); return current === null ? fallback : JSON.parse(current); } catch { return fallback; }
  });
  return [value, (next) => { setValue(next); localStorage.setItem(key, JSON.stringify(next)); }];
}

function ModeToggle({ value, onChange, compact = false }: { value: CodexMode; onChange: (mode: CodexMode) => void; compact?: boolean }) {
  return <div className={`mode-toggle${compact ? " compact" : ""}`} role="radiogroup" aria-label="Codex mode">
    <button type="button" role="radio" aria-checked={value === "fast"} className={value === "fast" ? "active" : ""} onClick={() => onChange("fast")}><Gauge size={14}/><span>Fast</span></button>
    <button type="button" role="radio" aria-checked={value === "ultra"} className={value === "ultra" ? "active" : ""} onClick={() => onChange("ultra")}><Sparkles size={14}/><span>Ultra</span></button>
  </div>;
}

function timeAgo(value: string) {
  const delta = Date.now() - new Date(value).getTime();
  if (delta < 60000) return "now";
  if (delta < 3600000) return `${Math.floor(delta / 60000)}m`;
  if (delta < 86400000) return `${Math.floor(delta / 3600000)}h`;
  return `${Math.floor(delta / 86400000)}d`;
}

export default function App() {
  const [allSessions, setAllSessions] = useState<Session[]>([]);
  const [selectedId, setSelectedId] = useState<string>();
  const [detail, setDetail] = useState<Session>();
  const [query, setQuery] = useState("");
  const deferredQuery = useDeferredValue(query.toLowerCase().trim());
  const [draft, setDraft] = useState("");
  const [cwd, setCwd] = stored("yep-cwd", "");
  const [mode, setMode] = stored<CodexMode>("yep-mode", "fast");
  const [theme, setTheme] = stored<"dark" | "light">("yep-theme", "dark");
  const [sidebar, setSidebar] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [live, setLive] = useState<Item[]>([]);
  const sequence = useRef(0);
  const stream = useRef<EventSource>();
  const transcript = useRef<HTMLDivElement>(null);

  const refresh = useCallback(async () => { try { setAllSessions(await sessions()); } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to load sessions"); } }, []);
  useEffect(() => { void refresh(); const timer = window.setInterval(refresh, 10000); return () => window.clearInterval(timer); }, [refresh]);
  useEffect(() => { document.documentElement.dataset.theme = theme; }, [theme]);
  useEffect(() => { if (!selectedId) { setDetail(undefined); return; } void session(selectedId).then(setDetail).catch((caught) => setError(caught instanceof Error ? caught.message : "Unable to load session")); }, [selectedId]);

  const filtered = useMemo(() => deferredQuery ? allSessions.filter((entry) => `${entry.title} ${entry.cwd} ${entry.preview}`.toLowerCase().includes(deferredQuery)) : allSessions, [allSessions, deferredQuery]);
  const items = useMemo(() => [...(detail?.items || []), ...live], [detail?.items, live]);
  useEffect(() => { transcript.current?.scrollTo({ top: transcript.current.scrollHeight, behavior: items.length > 1 ? "smooth" : "auto" }); }, [items.length]);
  const activeCwd = detail?.cwd || cwd;

  const select = (id?: string) => { stream.current?.close(); setSelectedId(id); setLive([]); setError(""); setSidebar(false); };
  const submit = async () => {
    const prompt = draft.trim();
    if (!prompt || !activeCwd.trim() || busy) return;
    setBusy(true); setError(""); setDraft("");
    sequence.current += 1;
    setLive((current) => [...current, { id: `user-${sequence.current}`, role: "user", text: prompt }]);
    try {
      const started = await run({ cwd: activeCwd.trim(), prompt, mode, ...(selectedId ? { sessionId: selectedId } : {}) });
      const source = new EventSource(`/api/runs/${encodeURIComponent(started.runId)}/events`);
      stream.current = source;
      source.addEventListener("output", (event) => {
        const output = JSON.parse((event as MessageEvent).data);
        sequence.current += 1;
        setLive((current) => [...current, { id: `output-${sequence.current}`, ...output }]);
      });
      source.addEventListener("meta", (event) => { const meta = JSON.parse((event as MessageEvent).data); if (!selectedId && meta.sessionId) setSelectedId(meta.sessionId); });
      source.addEventListener("done", () => { source.close(); setBusy(false); void refresh(); });
      source.addEventListener("error", (event) => {
        if (event instanceof MessageEvent && event.data) { const data = JSON.parse(event.data); setError(data.message || "Codex run failed"); }
        else setError("The live connection ended unexpectedly");
        source.close(); setBusy(false); void refresh();
      });
    } catch (caught) { setBusy(false); setError(caught instanceof Error ? caught.message : "Unable to start Codex"); }
  };

  return <div className="shell">
    <aside className={`sidebar${sidebar ? " open" : ""}`}>
      <header className="brand"><span className="logo">Y</span><div><strong>Yep Anywhere</strong><small>Codex workspace</small></div><button className="icon mobile" onClick={() => setSidebar(false)} aria-label="Close sessions"><X size={18}/></button></header>
      <button className="new" onClick={() => select()}><MessageSquarePlus size={17}/>New session</button>
      <label className="search"><Search size={15}/><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search sessions"/></label>
      <nav className="session-list">{filtered.map((entry) => <button key={entry.id} className={`session-row${selectedId === entry.id ? " active" : ""}`} onClick={() => select(entry.id)}><strong>{entry.title}</strong><time>{timeAgo(entry.updatedAt)}</time><small>{entry.cwd || "Unknown workspace"}</small><span>{entry.preview}</span></button>)}{!filtered.length && <p className="empty">No matching sessions</p>}</nav>
      <footer><i/>Local Codex CLI</footer>
    </aside>
    {sidebar && <button className="scrim" onClick={() => setSidebar(false)} aria-label="Close sessions"/>}
    <main>
      <header className="topbar"><button className="icon menu" onClick={() => setSidebar(true)} aria-label="Open sessions"><Menu size={19}/></button><div className="identity"><strong>{detail?.title || "New session"}</strong><small>{activeCwd || "Choose a workspace"}</small></div><div className="top-actions">{busy && <span className="running"><i/>Running</span>}<ModeToggle value={mode} onChange={setMode} compact/><button className="icon" onClick={() => setTheme(theme === "dark" ? "light" : "dark")} aria-label="Toggle theme">{theme === "dark" ? <Sun size={17}/> : <Moon size={17}/>}</button></div></header>
      <section className="transcript" ref={transcript}>{items.length ? <div className="messages">{items.map((item) => <article key={item.id} className={`message ${item.role}`}><div className="avatar">{item.role === "user" ? <UserRound size={16}/> : item.role === "tool" ? <TerminalSquare size={16}/> : <Bot size={16}/>}</div><div className="message-body"><header><strong>{item.role === "user" ? "You" : item.role === "assistant" ? "Codex" : item.role}</strong>{item.kind && <span>{item.kind.replaceAll("_", " ")}</span>}</header>{item.role === "assistant" ? <Suspense fallback={<p>{item.text}</p>}><Markdown text={item.text}/></Suspense> : <p>{item.text}</p>}</div></article>)}{busy && <div className="thinking"><i/><i/><i/></div>}</div> : <div className="welcome"><span className="logo large">Y</span><h1>What should Codex build?</h1><p>Choose a workspace, select Fast or Ultra, and start a focused coding session.</p><div><span>Inspect a repository</span><span>Implement a feature</span><span>Review a change</span></div></div>}</section>
      <section className="composer-wrap">{error && <div className="error" role="alert">{error}</div>}<div className="composer"><textarea value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); void submit(); } }} placeholder="Ask Codex to change, inspect, or explain…"/><footer><label><span>Workspace</span><input value={activeCwd} onChange={(event) => setCwd(event.target.value)} placeholder="/path/to/project"/></label><ModeToggle value={mode} onChange={setMode} compact/><button className="send" onClick={() => void submit()} disabled={!draft.trim() || !activeCwd.trim() || busy} aria-label="Send prompt"><ArrowUp size={18}/></button></footer></div><small className="hint">Enter to send · Shift+Enter for a new line</small></section>
    </main>
  </div>;
}
EOF

cat > src/main.tsx <<'EOF'
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles.css";

if ("serviceWorker" in navigator) window.addEventListener("load", () => navigator.serviceWorker.register("/service-worker.js").catch(() => undefined));
createRoot(document.getElementById("root")!).render(<StrictMode><App/></StrictMode>);
EOF

cat > src/vite-env.d.ts <<'EOF'
/// <reference types="vite/client" />
EOF

cat > src/styles.css <<'EOF'
:root{color-scheme:dark;font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;--bg:#111113;--side:#151517;--panel:#19191c;--panel2:#222226;--panel3:#29292e;--line:rgba(255,255,255,.085);--line2:rgba(255,255,255,.15);--text:#f2f2f3;--muted:#9797a1;--subtle:#6f6f79;--accent:#f3f3f4;--ink:#111113;--fast:#8cc8ff;--ultra:#d5a4ff;--danger:#ff9296;background:var(--bg);color:var(--text);font-synthesis:none;text-rendering:optimizeLegibility} :root[data-theme=light]{color-scheme:light;--bg:#f5f5f4;--side:#ececeb;--panel:#fff;--panel2:#f3f3f2;--panel3:#e8e8e7;--line:rgba(0,0,0,.08);--line2:rgba(0,0,0,.15);--text:#171719;--muted:#696970;--subtle:#8b8b91;--accent:#171719;--ink:#fff}*{box-sizing:border-box}html,body,#root{width:100%;height:100%;margin:0;overflow:hidden}body{background:var(--bg)}button,input,textarea{font:inherit;color:inherit}button{cursor:pointer;-webkit-tap-highlight-color:transparent}button:focus-visible,input:focus-visible,textarea:focus-visible,a:focus-visible{outline:2px solid var(--fast);outline-offset:2px}.shell{display:grid;grid-template-columns:286px minmax(0,1fr);width:100%;height:100%}.sidebar{z-index:20;display:grid;grid-template-rows:auto auto auto minmax(0,1fr) auto;min-width:0;padding:14px 12px 10px;border-right:1px solid var(--line);background:var(--side)}.brand{display:flex;align-items:center;gap:10px;min-height:42px;padding:0 5px 12px}.brand>div{display:grid}.brand strong{font-size:14px}.brand small{margin-top:2px;color:var(--muted);font-size:11px}.logo{display:grid;place-items:center;width:28px;height:28px;border:1px solid var(--line2);border-radius:9px;background:linear-gradient(145deg,var(--panel3),var(--panel));font-weight:750}.icon{display:inline-grid;place-items:center;width:34px;height:34px;padding:0;border:0;border-radius:9px;background:transparent;color:var(--muted)}.icon:hover{background:var(--panel2);color:var(--text)}.mobile,.menu{display:none}.brand .mobile{margin-left:auto}.new{display:flex;align-items:center;gap:9px;width:100%;height:38px;margin:3px 0 10px;padding:0 11px;border:1px solid var(--line);border-radius:10px;background:var(--panel);font-size:13px;font-weight:650}.new:hover{border-color:var(--line2);background:var(--panel2)}.search{display:flex;align-items:center;gap:7px;height:34px;margin-bottom:9px;padding:0 9px;border:1px solid transparent;border-radius:9px;background:color-mix(in srgb,var(--panel),transparent 20%);color:var(--subtle)}.search:focus-within{border-color:var(--line2)}.search input{width:100%;min-width:0;border:0;outline:0;background:transparent;font-size:12px}.session-list{min-height:0;overflow:auto;scrollbar-width:thin}.session-row{display:grid;grid-template-columns:minmax(0,1fr) auto;width:100%;margin:1px 0;padding:10px;border:1px solid transparent;border-radius:10px;background:transparent;text-align:left;content-visibility:auto;contain-intrinsic-size:auto 78px}.session-row:hover{background:color-mix(in srgb,var(--panel2),transparent 20%)}.session-row.active{border-color:var(--line);background:var(--panel2)}.session-row strong{overflow:hidden;font-size:12.5px;text-overflow:ellipsis;white-space:nowrap}.session-row time{color:var(--subtle);font-size:10px}.session-row small{grid-column:1;overflow:hidden;margin-top:5px;color:var(--subtle);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:10px;text-overflow:ellipsis;white-space:nowrap}.session-row span{grid-column:1/-1;overflow:hidden;margin-top:5px;color:var(--muted);font-size:11px;text-overflow:ellipsis;white-space:nowrap}.empty{padding:24px 10px;color:var(--muted);font-size:12px;text-align:center}.sidebar>footer{display:flex;align-items:center;gap:8px;padding:10px 6px 2px;color:var(--muted);font-size:11px}.sidebar>footer i,.running i{width:7px;height:7px;border-radius:50%;background:#69d596;box-shadow:0 0 0 3px color-mix(in srgb,#69d596,transparent 82%)}main{display:grid;grid-template-rows:58px minmax(0,1fr) auto;min-width:0;height:100%}.topbar{z-index:5;display:flex;align-items:center;gap:10px;min-width:0;padding:0 14px 0 20px;border-bottom:1px solid var(--line);background:color-mix(in srgb,var(--bg),transparent 6%);backdrop-filter:blur(16px)}.identity{display:grid;min-width:0}.identity strong,.identity small{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.identity strong{font-size:13px}.identity small{max-width:min(48vw,760px);margin-top:2px;color:var(--muted);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:10px}.top-actions{display:flex;align-items:center;gap:4px;margin-left:auto}.running{display:flex;align-items:center;gap:7px;margin-right:5px;color:var(--muted);font-size:11px}.running i{background:var(--fast);animation:pulse 1.4s infinite}.mode-toggle{display:inline-flex;gap:3px;padding:3px;border:1px solid var(--line);border-radius:11px;background:var(--panel)}.mode-toggle button{display:inline-flex;align-items:center;justify-content:center;gap:6px;height:30px;padding:0 10px;border:0;border-radius:8px;background:transparent;color:var(--muted);font-size:11.5px;font-weight:650}.mode-toggle button:hover{color:var(--text)}.mode-toggle button.active{background:var(--panel3);color:var(--text);box-shadow:0 1px 2px rgba(0,0,0,.2)}.mode-toggle button:first-child.active svg{color:var(--fast)}.mode-toggle button:last-child.active svg{color:var(--ultra)}.mode-toggle.compact button{height:26px;padding:0 8px;font-size:10.5px}.transcript{min-height:0;overflow:auto;overscroll-behavior:contain;scrollbar-width:thin}.messages{width:min(880px,calc(100% - 40px));min-height:100%;margin:0 auto}.message{display:grid;grid-template-columns:30px minmax(0,1fr);gap:12px;padding:22px 4px;border-bottom:1px solid var(--line);content-visibility:auto;contain-intrinsic-size:auto 150px}.avatar{display:grid;place-items:center;width:28px;height:28px;border:1px solid var(--line);border-radius:9px;background:var(--panel);color:var(--muted)}.message.user .avatar{background:var(--panel3);color:var(--text)}.message-body{min-width:0;font-size:14px;line-height:1.62;overflow-wrap:anywhere}.message-body header{display:flex;align-items:baseline;gap:8px;margin-bottom:8px}.message-body header strong{font-size:12px}.message-body header span{color:var(--subtle);font-size:10px;text-transform:capitalize}.message-body p{margin:.65em 0;white-space:pre-wrap}.message-body>:first-child{margin-top:0}.message-body>:last-child{margin-bottom:0}.message-body h1,.message-body h2,.message-body h3{margin:1.2em 0 .55em;line-height:1.25}.message-body code{padding:.12em .34em;border:1px solid var(--line);border-radius:5px;background:var(--panel2);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em}.message-body pre{overflow:auto;margin:.9em 0;padding:14px;border:1px solid var(--line);border-radius:10px;background:#0d0d0f;color:#eee;line-height:1.52}.message-body pre code{padding:0;border:0;background:transparent}.message-body a{color:var(--fast)}.thinking{display:flex;gap:4px;padding:14px 46px}.thinking i{width:5px;height:5px;border-radius:50%;background:var(--muted);animation:bounce 1.2s infinite}.thinking i:nth-child(2){animation-delay:120ms}.thinking i:nth-child(3){animation-delay:240ms}.welcome{display:grid;place-items:center;align-content:center;height:100%;padding:36px;text-align:center}.logo.large{width:42px;height:42px;border-radius:13px;font-size:18px}.welcome h1{margin:18px 0 6px;font-size:clamp(25px,3vw,38px);letter-spacing:-.035em}.welcome p{max-width:520px;margin:0;color:var(--muted);font-size:14px}.welcome>div{display:flex;flex-wrap:wrap;justify-content:center;gap:8px;margin-top:26px}.welcome>div span{padding:8px 11px;border:1px solid var(--line);border-radius:9px;background:var(--panel);color:var(--muted);font-size:11px}.composer-wrap{z-index:6;width:min(880px,calc(100% - 40px));margin:0 auto;padding:8px 0 max(14px,env(safe-area-inset-bottom));background:linear-gradient(transparent,var(--bg) 18%)}.composer{overflow:hidden;border:1px solid var(--line2);border-radius:16px;background:var(--panel);box-shadow:0 18px 50px rgba(0,0,0,.22)}.composer:focus-within{border-color:color-mix(in srgb,var(--fast),var(--line) 68%)}.composer textarea{display:block;width:100%;min-height:70px;max-height:220px;resize:vertical;padding:14px 15px 7px;border:0;outline:0;background:transparent;font-size:14px;line-height:1.48}.composer textarea::placeholder{color:var(--subtle)}.composer footer{display:flex;align-items:center;gap:6px;min-height:43px;padding:4px 7px 7px 8px}.composer footer label{display:flex;align-items:center;gap:6px;min-width:0;height:30px;padding:0 8px;border:1px solid var(--line);border-radius:8px;color:var(--subtle)}.composer footer label span{font-size:9px;font-weight:750;letter-spacing:.06em;text-transform:uppercase}.composer footer input{width:min(28vw,300px);min-width:90px;border:0;outline:0;background:transparent;color:var(--muted);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:10px}.send{display:grid;place-items:center;width:32px;height:32px;margin-left:auto;padding:0;border:0;border-radius:9px;background:var(--accent);color:var(--ink)}.send:disabled{cursor:default;opacity:.3}.hint{display:block;margin:6px 0 0;color:var(--subtle);font-size:9.5px;text-align:center}.error{margin-bottom:7px;padding:8px 11px;border:1px solid color-mix(in srgb,var(--danger),transparent 68%);border-radius:9px;background:color-mix(in srgb,var(--danger),transparent 90%);color:var(--danger);font-size:11px}.scrim{display:none}@keyframes pulse{50%{opacity:.45}}@keyframes bounce{50%{transform:translateY(-3px);opacity:.5}}@media(prefers-reduced-motion:reduce){*,*:before,*:after{animation-duration:.01ms!important;animation-iteration-count:1!important;transition-duration:.01ms!important;scroll-behavior:auto!important}}@media(max-width:760px){.shell{display:block}.sidebar{position:fixed;inset:0 auto 0 0;width:min(310px,88vw);transform:translateX(-102%);box-shadow:18px 0 50px rgba(0,0,0,.3);transition:transform 180ms}.sidebar.open{transform:translateX(0)}.mobile,.menu{display:inline-grid}.scrim{position:fixed;z-index:15;inset:0;display:block;border:0;background:rgba(0,0,0,.45)}.topbar{padding:0 8px}.identity small{max-width:40vw}.running,.top-actions>.mode-toggle{display:none}.messages,.composer-wrap{width:calc(100% - 20px)}.message{grid-template-columns:26px minmax(0,1fr);gap:9px;padding:17px 1px}.avatar{width:25px;height:25px}.message-body{font-size:13px}.composer-wrap{padding-bottom:max(9px,env(safe-area-inset-bottom))}.composer{border-radius:14px}.composer footer{align-items:flex-end;flex-wrap:wrap}.composer footer label{order:3;width:100%}.composer footer input{width:100%}.hint{display:none}}
EOF

cat > scripts/check-focus.mjs <<'EOF'
import { readFile, readdir } from "node:fs/promises";
import { extname, join, relative } from "node:path";
const blocked = [`cl${"aude"}`, `anth${"ropic"}`].map((entry) => entry.toLowerCase());
const extensions = new Set([".css", ".html", ".js", ".json", ".md", ".mjs", ".ts", ".tsx", ".yaml", ".yml"]);
const matches = [];
async function walk(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if ([".git", "node_modules", "dist", "coverage"].includes(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) await walk(path);
    else if (extensions.has(extname(entry.name)) || entry.name === ".env.example") {
      const value = (await readFile(path, "utf8")).toLowerCase();
      if (blocked.some((term) => value.includes(term) || entry.name.toLowerCase().includes(term))) matches.push(relative(process.cwd(), path));
    }
  }
}
await walk(process.cwd());
if (matches.length) { console.error(`Unexpected provider integration in:\n${matches.join("\n")}`); process.exit(1); }
EOF

cat > scripts/check-bundle.mjs <<'EOF'
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
const files = (await readdir("dist/assets")).filter((file) => file.endsWith(".js"));
const sizes = await Promise.all(files.map(async (file) => ({ file, bytes: gzipSync(await readFile(join("dist/assets", file))).byteLength })));
const entry = sizes.find(({ file }) => file.startsWith("index-"));
const largest = sizes.sort((a, b) => b.bytes - a.bytes)[0];
if (!entry || !largest) throw new Error("Production JavaScript assets were not found");
console.log(`entry=${entry.bytes} largest=${largest.file}:${largest.bytes}`);
if (entry.bytes > 230000) throw new Error(`Initial bundle exceeds 230 KB gzip: ${entry.bytes}`);
if (largest.bytes > 500000) throw new Error(`A chunk exceeds 500 KB gzip: ${largest.file}`);
EOF

cat > scripts/dev.mjs <<'EOF'
import { spawn } from "node:child_process";
const children = [spawn(process.execPath, ["server/index.mjs"], { stdio: "inherit" }), spawn("pnpm", ["exec", "vite"], { stdio: "inherit", shell: process.platform === "win32" })];
const stop = () => children.forEach((child) => child.kill());
process.on("SIGINT", stop); process.on("SIGTERM", stop);
await Promise.race(children.map((child) => new Promise((resolve) => child.once("exit", resolve))));
stop();
EOF

cat > scripts/smoke.mjs <<'EOF'
import { spawn } from "node:child_process";
const port = 3417;
const child = spawn(process.execPath, ["server/index.mjs"], { env: { ...process.env, HOST: "127.0.0.1", PORT: String(port), CODEX_WORKSPACE_ROOTS: process.cwd() }, stdio: "ignore" });
let ok = false;
try {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 100));
    try { const response = await fetch(`http://127.0.0.1:${port}/api/health`); if (response.ok && (await response.json()).ok === true) { ok = true; break; } } catch {}
  }
} finally { child.kill(); }
if (!ok) throw new Error("Production health check did not become ready");
EOF

cat > test/mode.test.mjs <<'EOF'
import assert from "node:assert/strict";
import test from "node:test";
import { buildCodexArguments, detectCapabilities, modeArguments } from "../server/mode.mjs";

test("native Fast and Ultra flags are selected when available", () => {
  assert.deepEqual(modeArguments("fast", { fast: true, ultra: true }), ["--fast"]);
  assert.deepEqual(modeArguments("ultra", { fast: true, ultra: true }), ["--ultra"]);
});

test("stable configuration fallbacks are selected", () => {
  assert.deepEqual(modeArguments("fast", { fast: false, ultra: false }), ["-c", 'service_tier="fast"']);
  assert.deepEqual(modeArguments("ultra", { fast: false, ultra: false }), ["-c", 'model_reasoning_effort="xhigh"']);
});

test("capabilities and resumed commands are normalized", async () => {
  assert.deepEqual(await detectCapabilities(async () => "  --fast, run quickly\n  --ultra reason deeply"), { fast: true, ultra: true });
  assert.deepEqual(await buildCodexArguments({ mode: "ultra", prompt: "continue", sessionId: "s1", capabilities: { fast: false, ultra: false } }), ["-c", 'model_reasoning_effort="xhigh"', "exec", "resume", "--json", "--skip-git-repo-check", "s1", "continue"]);
});
EOF

cat > test/history.test.mjs <<'EOF'
import assert from "node:assert/strict";
import test from "node:test";
import { normalizeRecord } from "../server/history.mjs";

test("session records normalize user and assistant text", () => {
  assert.deepEqual(normalizeRecord({ type: "event_msg", payload: { type: "user_message", message: "Ship it" } }, 1).item.role, "user");
  const item = normalizeRecord({ type: "response_item", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "Done" }] } }, 2).item;
  assert.equal(item.role, "assistant");
  assert.equal(item.text, "Done");
});
EOF

cat > README.md <<'EOF'
# Yep Anywhere

A focused self-hosted web workspace for Codex. It reads local Codex session history,
starts or resumes CLI sessions, streams progress over server-sent events, and provides a
compact responsive PWA for desktop, tablet, and phone.

## Fast and Ultra

**Fast** uses the CLI's native fast capability when it is advertised. On older builds the
server requests the fast service tier through Codex configuration. **Ultra** uses the
native ultra capability when present and otherwise requests `xhigh` reasoning effort.
The selected mode is stored in the browser and sent with every turn.

## Run

```bash
corepack enable
pnpm install --frozen-lockfile
pnpm build
pnpm start
```

The server listens on `127.0.0.1:3400`. Set `CODEX_WORKSPACE_ROOTS` to a
platform-delimited list of directories that the browser may open. The current working
directory is the default and the server rejects paths outside the configured roots.

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

Long session lists and transcript rows use rendering containment, search uses deferred
input, history snapshots are cached by file size and modification time, and Markdown is
loaded as a separate production chunk.
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
pnpm add -E lucide-react@latest react@latest react-dom@latest react-markdown@latest
pnpm add -D -E @biomejs/biome@latest @types/node@latest @types/react@latest @types/react-dom@latest @vitejs/plugin-react@latest typescript@latest vite@latest
pnpm format
pnpm lint
pnpm typecheck
pnpm test
pnpm build
pnpm perf:check
pnpm test:smoke

git add -A
git commit -m "Build a stable Codex workspace"
git push origin HEAD:codex-fast-ultra-pi-ui
