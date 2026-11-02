// Who may run an AI analysis. An analysis is one photo identification. Three things pay for one, used in this order:
//   1. SellPilot Plus (subscription): a set number each 30 days, which renews and so should be used first.
//   2. The free allowance: a few analyses per install, once.
//   3. Credits bought as a pack: they never expire, so they are spent last.
// Purchases are proven by transactions Apple signed (see appleJws.mjs); the app cannot make up a subscription or a pack.
// Counts live in a key-value store (Netlify Blobs in production, a Map in tests), one small record per key.
import { verifyAppleJws } from "./appleJws.mjs";
import { PRODUCTS, DEFAULTS } from "./products.mjs";

/**
 * @param {{get(key: string): Promise<any>, set(key: string, value: any): Promise<void>}} store
 * @param {{bundleId?: string, freeAnalyses?: number, plusPerPeriod?: number, acceptSandbox?: boolean, now?: () => number,
 *          verify?: (jws: string) => object}} [options] `verify` is for tests; production uses Apple's chain.
 */
export function createAllowances(store, { bundleId = DEFAULTS.bundleId, freeAnalyses = DEFAULTS.freeAnalyses, plusPerPeriod = DEFAULTS.plusPerPeriod, acceptSandbox = true, now = Date.now, verify = (jws) => verifyAppleJws(jws, { now: now() }) } = {}) {
  /** The decoded transaction if it is genuine, ours, and live; otherwise null. */
  function accept(jws, kind) {
    let payload;
    try { payload = verify(jws); } catch { return null; }
    const product = PRODUCTS[payload?.productId];
    if (!product || product.kind !== kind || payload.bundleId !== bundleId) return null;
    if (payload.environment !== "Production" && !(acceptSandbox && payload.environment === "Sandbox")) return null;
    if (payload.revocationDate) return null;
    if (kind === "subscription" && !(payload.expiresDate > now())) return null;
    return { payload, product };
  }

  async function subscriptionState(entitlement) {
    if (!entitlement) return null;
    const accepted = accept(entitlement, "subscription");
    if (!accepted) return null;
    const { payload } = accepted;
    const root = payload.originalTransactionId ?? payload.transactionId;
    const started = payload.originalPurchaseDate ?? payload.purchaseDate ?? now();
    const bucket = Math.max(0, Math.floor((now() - started) / DEFAULTS.periodMs));
    const record = await store.get(`plus:${root}`);
    const used = record && record.bucket === bucket ? record.used : 0;
    return { key: `plus:${root}`, bucket, used, expires: payload.expiresDate, renews: started + (bucket + 1) * DEFAULTS.periodMs };
  }

  const countOf = async (key, field) => (await store.get(key))?.[field] ?? 0;

  async function snapshot(installKey, plus) {
    const freeUsed = await countOf(`free:${installKey}`, "used");
    return {
      free: Math.max(0, freeAnalyses - freeUsed),
      credits: await countOf(`credits:${installKey}`, "balance"),
      plus: plus ? { remaining: Math.max(0, plusPerPeriod - plus.used), limit: plusPerPeriod, renews: plus.renews, expires: plus.expires } : null,
    };
  }

  return {
    freeAnalyses, plusPerPeriod,

    /** Decides what pays for the next analysis, without spending it. Resolves {source, allowance} or {exhausted: true, allowance}. */
    async plan({ installKey, entitlement }) {
      const plus = await subscriptionState(entitlement);
      const allowance = await snapshot(installKey, plus);
      if (plus && plus.used < plusPerPeriod) return { source: "plus", plus, installKey, allowance };
      if (allowance.free > 0) return { source: "free", installKey, allowance };
      if (allowance.credits > 0) return { source: "credits", installKey, allowance };
      return { exhausted: true, allowance };
    },

    /** Spends the analysis a plan reserved. Called only after the analysis worked, so a failed call costs nothing. Resolves the new allowance. */
    async commit(plan) {
      const { source, installKey } = plan;
      if (source === "plus") { plan.plus.used += 1; await store.set(plan.plus.key, { bucket: plan.plus.bucket, used: plan.plus.used }); }
      else if (source === "free") await store.set(`free:${installKey}`, { used: (await countOf(`free:${installKey}`, "used")) + 1 });
      else if (source === "credits") await store.set(`credits:${installKey}`, { balance: Math.max(0, (await countOf(`credits:${installKey}`, "balance")) - 1) });
      return snapshot(installKey, plan.plus ?? null);
    },

    async status({ installKey, entitlement }) { return snapshot(installKey, await subscriptionState(entitlement)); },

    /** Turns a bought pack into credits for this install. Safe to repeat: each transaction counts once. */
    async redeem({ installKey, transaction, entitlement }) {
      const accepted = accept(transaction, "pack");
      if (!accepted) return { ok: false, allowance: await this.status({ installKey, entitlement }) };
      const id = String(accepted.payload.transactionId);
      const seen = await store.get(`pack:${id}`);
      if (!seen) {
        await store.set(`credits:${installKey}`, { balance: (await countOf(`credits:${installKey}`, "balance")) + accepted.product.credits });
        await store.set(`pack:${id}`, { installKey, at: now() });
      }
      return { ok: true, added: seen ? 0 : accepted.product.credits, allowance: await this.status({ installKey, entitlement }) };
    },
  };
}
