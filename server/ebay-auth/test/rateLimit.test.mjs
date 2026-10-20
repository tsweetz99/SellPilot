import test from "node:test";
import assert from "node:assert/strict";
import { createLimiter, memoryStore } from "../lib/rateLimit.mjs";

const HOUR = 3_600_000;

test("allows up to the per-key limit, then blocks until the next hour", async () => {
  let time = 10 * HOUR + 1000;
  const limiter = createLimiter(memoryStore(), { perKeyPerHour: 3, globalPerHour: 100, now: () => time });
  for (let i = 0; i < 3; i++) assert.equal((await limiter.check("a")).allowed, true);
  const blocked = await limiter.check("a");
  assert.equal(blocked.allowed, false); assert.equal(blocked.scope, "key"); assert.equal(blocked.retryAfterSeconds, 3599);
  time += HOUR;
  assert.equal((await limiter.check("a")).allowed, true, "a new hour starts a new window");
});

test("a global cap protects the whole endpoint even when keys are made up", async () => {
  const limiter = createLimiter(memoryStore(), { perKeyPerHour: 100, globalPerHour: 4, now: () => 5 * HOUR });
  for (let i = 0; i < 4; i++) assert.equal((await limiter.check(`key-${i}`)).allowed, true);
  const blocked = await limiter.check("key-new");
  assert.equal(blocked.allowed, false); assert.equal(blocked.scope, "global");
});

test("keeps one record per key, overwritten each hour, so the store does not grow", async () => {
  const records = new Map();
  const store = { async get(k) { return records.get(k) ?? null; }, async set(k, v) { records.set(k, v); } };
  let time = HOUR;
  const limiter = createLimiter(store, { now: () => time });
  for (let hour = 0; hour < 5; hour++) { await limiter.check("a"); time += HOUR; }
  assert.deepEqual([...records.keys()].sort(), ["global", "key:a"]);
});

import { createBudget } from "../lib/rateLimit.mjs";

test("budget windows roll over: hourly for an address, daily for an install and the service", async () => {
  let time = 0;
  const budget = createBudget(memoryStore(), { installPerDay: 10, addressPerHour: 3, globalPerDay: 100, now: () => time });
  const spend = (units = 1) => budget.spend({ installKey: "k", addressHash: "a", units });
  assert.equal((await spend(3)).allowed, true);
  const blocked = await spend(1);
  assert.equal(blocked.allowed, false); assert.equal(blocked.scope, "address"); assert.equal(blocked.retryAfterSeconds, 3600);
  time = 3_600_001;                                   // next hour: the address window rolls over, the install's day has not
  assert.equal((await spend(3)).allowed, true);
  time = 7_200_001; assert.equal((await spend(3)).allowed, true);
  time = 10_800_001; const dayLimited = await spend(3);          // 9 used of 10 today
  assert.equal(dayLimited.allowed, false); assert.equal(dayLimited.scope, "install");
  time = 86_400_001; assert.equal((await spend(3)).allowed, true, "a new day starts fresh");
});
