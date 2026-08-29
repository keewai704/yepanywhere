import { CodexProvider } from "./implementations/CodexProvider";
import type { Provider } from "./types";

const codexProvider = new CodexProvider();

export function getAllProviders(): Provider[] {
  return [codexProvider];
}

export function getProvider(_id: string | undefined): Provider {
  return codexProvider;
}
