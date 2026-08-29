import {
  DEFAULT_CODEX_REASONING_SUMMARY,
  DEFAULT_SUBAGENT_MAX_DEPTH,
  type CodexReasoningSummary,
  type SubagentMaxDepth,
} from "@yep-anywhere/shared";
import {
  isProviderRuntimeHostAvailable,
  startHostedProviderSession,
} from "./provider-runtime-host.js";
import { codexProvider } from "./codex.js";
import type { AgentProvider, ProviderName } from "./types.js";

export type {
  AgentProvider,
  AgentSession,
  AuthStatus,
  ProviderName,
  StartSessionOptions,
} from "./types.js";
export {
  CodexProvider,
  codexProvider,
  type CodexProviderConfig,
} from "./codex.js";

export interface ProviderRuntimeConfig {
  codexCliPath?: string;
  getProviderRuntimeSnapshot?: () => ProviderRuntimeSnapshot;
}

export interface ProviderRuntimeSnapshot {
  codexCliPath?: string;
  codexReasoningSummary?: CodexReasoningSummary;
  subagentMaxDepth?: SubagentMaxDepth;
}

let getProviderRuntimeSnapshot = (): ProviderRuntimeSnapshot => ({});
const hostedProviderProxies = new Map<ProviderName, AgentProvider>();

export function configureProviderRuntime(config: ProviderRuntimeConfig): void {
  codexProvider.setCodexPath(config.codexCliPath);
  getProviderRuntimeSnapshot =
    config.getProviderRuntimeSnapshot ?? (() => ({}));
  codexProvider.setReasoningSummaryGetter(
    () =>
      getProviderRuntimeSnapshot().codexReasoningSummary ??
      DEFAULT_CODEX_REASONING_SUMMARY,
  );
  codexProvider.setSubagentMaxDepthGetter(
    () =>
      getProviderRuntimeSnapshot().subagentMaxDepth ??
      DEFAULT_SUBAGENT_MAX_DEPTH,
  );
}

function hostedProvider(rawProvider: AgentProvider): AgentProvider {
  const existing = hostedProviderProxies.get(rawProvider.name);
  if (existing) return existing;
  const proxy = new Proxy(rawProvider, {
    get(target, property) {
      if (property === "startSession") {
        return (options: Parameters<AgentProvider["startSession"]>[0]) =>
          startHostedProviderSession(
            target.name,
            options,
            getProviderRuntimeSnapshot(),
          );
      }
      const value = Reflect.get(target, property, target) as unknown;
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  hostedProviderProxies.set(rawProvider.name, proxy);
  return proxy;
}

export { isProviderRuntimeHostAvailable };

function runtimeProvider(rawProvider: AgentProvider): AgentProvider {
  return isProviderRuntimeHostAvailable()
    ? hostedProvider(rawProvider)
    : rawProvider;
}

export function getAllProviders(): AgentProvider[] {
  return [runtimeProvider(codexProvider)];
}

export function getRawProvider(name: ProviderName): AgentProvider | null {
  return name === "codex" ? codexProvider : null;
}

export function getProvider(name: ProviderName): AgentProvider | null {
  const provider = getRawProvider(name);
  return provider ? runtimeProvider(provider) : null;
}
