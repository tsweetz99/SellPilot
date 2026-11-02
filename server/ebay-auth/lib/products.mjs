// The things SellPilot sells. The ids must match App Store Connect and SellPilot/Services/Purchases.swift (a test keeps them in step).
export const PRODUCTS = {
  "com.tidewrightstudios.sellpilot.plus.monthly": { kind: "subscription" },
  "com.tidewrightstudios.sellpilot.plus.yearly": { kind: "subscription" },
  "com.tidewrightstudios.sellpilot.analyses.25": { kind: "pack", credits: 25 },
};
export const DEFAULTS = {
  bundleId: "com.tidewrightstudios.sellpilot",
  freeAnalyses: 5,        // once per install, never renews
  plusPerPeriod: 60,      // per 30 days from the first purchase, monthly or yearly
  periodMs: 30 * 86_400_000,
};
