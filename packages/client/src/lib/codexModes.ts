import type { EffortLevel, ModelInfo } from "@yep-anywhere/shared";
import type { EffortLevelOption } from "./effortLevels";

export const CODEX_FAST_SERVICE_TIER = "fast";

const LEGACY_FAST_SERVICE_TIER = "priority";
const ULTRA_EFFORT_PREFERENCE: readonly EffortLevel[] = [
  "ultra",
  "max",
  "xhigh",
  "high",
];

export function normalizeCodexServiceTier(
  serviceTier: string | null | undefined,
): string | undefined {
  if (
    serviceTier === CODEX_FAST_SERVICE_TIER ||
    serviceTier === LEGACY_FAST_SERVICE_TIER
  ) {
    return CODEX_FAST_SERVICE_TIER;
  }
  return serviceTier?.trim() || undefined;
}

export function modelSupportsCodexFast(model?: ModelInfo | null): boolean {
  return Boolean(
    model?.supportsFastMode ||
      model?.serviceTiers?.some(
        (tier) =>
          tier.id === CODEX_FAST_SERVICE_TIER ||
          tier.id === LEGACY_FAST_SERVICE_TIER,
      ),
  );
}

export function getCodexUltraEffort(
  options: readonly EffortLevelOption[],
): EffortLevel | null {
  for (const preferred of ULTRA_EFFORT_PREFERENCE) {
    if (options.some((option) => option.value === preferred)) {
      return preferred;
    }
  }
  return null;
}

export function isCodexUltraEffort(
  effort: EffortLevel | null | undefined,
  options: readonly EffortLevelOption[],
): boolean {
  const ultraEffort = getCodexUltraEffort(options);
  return ultraEffort !== null && effort === ultraEffort;
}
