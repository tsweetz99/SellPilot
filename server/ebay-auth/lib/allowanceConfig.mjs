// Reads the paywall settings from the environment, so they can change without a code change.
import { DEFAULTS } from "./products.mjs";

/** AI_FREE_ANALYSES, AI_PLUS_PER_PERIOD, APP_BUNDLE_ID, AI_ACCEPT_SANDBOX ("false" to refuse TestFlight and review purchases). */
export function allowanceOptions(env) {
  const count = (value, fallback) => { const n = Number(value); return Number.isInteger(n) && n >= 0 && value !== "" && value != null ? n : fallback; };
  return {
    bundleId: env.APP_BUNDLE_ID || DEFAULTS.bundleId,
    freeAnalyses: count(env.AI_FREE_ANALYSES, DEFAULTS.freeAnalyses),
    plusPerPeriod: count(env.AI_PLUS_PER_PERIOD, DEFAULTS.plusPerPeriod),
    acceptSandbox: env.AI_ACCEPT_SANDBOX !== "false",
  };
}
