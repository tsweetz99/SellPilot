// A small fixed-window limiter backed by any async key-value store (Netlify Blobs in production, a Map in tests).
// Serverless instances forget everything between calls, so the counts have to live in a store.
// One record per key (overwritten each hour) keeps the store from growing.

const HOUR_MS = 3_600_000;

/**
 * @param {{get(key: string): Promise<any>, set(key: string, value: any): Promise<void>}} store
 * @param {{perKeyPerHour?: number, globalPerHour?: number, now?: () => number}} [options]
 */
export function createLimiter(store, { perKeyPerHour = 20, globalPerHour = 600, now = Date.now } = {}) {
  async function bump(name, limit, bucket) {
    const record = await store.get(name);
    const count = record && record.bucket === bucket ? record.count : 0;
    if (count >= limit) return false;
    await store.set(name, { bucket, count: count + 1 });
    return true;
  }
  return {
    /** Counts one request for `key`. Resolves {allowed, retryAfterSeconds}. */
    async check(key) {
      const time = now(), bucket = Math.floor(time / HOUR_MS);
      const retryAfterSeconds = Math.max(1, Math.ceil(((bucket + 1) * HOUR_MS - time) / 1000));
      // The global cap is checked first so one noisy key cannot be used to exhaust the per-key records of others.
      if (!(await bump("global", globalPerHour, bucket))) return { allowed: false, retryAfterSeconds, scope: "global" };
      if (!(await bump(`key:${key}`, perKeyPerHour, bucket))) return { allowed: false, retryAfterSeconds, scope: "key" };
      return { allowed: true, retryAfterSeconds: 0 };
    },
  };
}

export function memoryStore() {
  const map = new Map();
  return { async get(key) { return map.has(key) ? structuredClone(map.get(key)) : null; }, async set(key, value) { map.set(key, structuredClone(value)); } };
}

const DAY_MS = 86_400_000;

/**
 * A spending allowance for the AI service, counted in "units" (an identification costs more than a fact lookup).
 * Three allowances are checked together: one per app install per day, one per network address per hour, and one for the whole
 * service per day. The service-wide one is the cap on the Anthropic bill. Each key keeps one record that is overwritten when
 * its window rolls over, so the store does not grow with traffic.
 *
 * @param {{get(key: string): Promise<any>, set(key: string, value: any): Promise<void>}} store
 */
export function createBudget(store, { installPerDay = 60, addressPerHour = 90, globalPerDay = 1500, now = Date.now } = {}) {
  const windows = (installKey, addressHash) => [
    { name: "ai:global", limit: globalPerDay, ms: DAY_MS, scope: "global" },
    { name: `ai:ip:${addressHash}`, limit: addressPerHour, ms: HOUR_MS, scope: "address" },
    { name: `ai:key:${installKey}`, limit: installPerDay, ms: DAY_MS, scope: "install" },
  ];
  return {
    /** Takes `units` from every allowance, or from none if any is used up. Resolves {allowed, retryAfterSeconds, scope}. */
    async spend({ installKey, addressHash, units }) {
      const time = now();
      const checked = [];
      for (const window of windows(installKey, addressHash)) {
        const bucket = Math.floor(time / window.ms);
        const record = await store.get(window.name);
        const used = record && record.bucket === bucket ? record.used : 0;
        if (used + units > window.limit) return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil(((bucket + 1) * window.ms - time) / 1000)), scope: window.scope };
        checked.push({ window, bucket, used });
      }
      for (const { window, bucket, used } of checked) await store.set(window.name, { bucket, used: used + units });
      return { allowed: true, retryAfterSeconds: 0 };
    },
  };
}
