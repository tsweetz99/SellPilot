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
