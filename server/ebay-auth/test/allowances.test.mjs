import test from "node:test";
import assert from "node:assert/strict";
import { createAllowances } from "../lib/allowances.mjs";
import { handleAccount } from "../lib/account.mjs";
import { memoryStore } from "../lib/rateLimit.mjs";
import { PRODUCTS, DEFAULTS } from "../lib/products.mjs";
import { allowanceOptions } from "../lib/allowanceConfig.mjs";

const DAY = 86_400_000;
const KEY = "0123456789abcdef0123456789abcdef";
const OTHER = "fedcba9876543210fedcba9876543210";
const MONTHLY = "com.tidewrightstudios.sellpilot.plus.monthly";
const PACK = "com.tidewrightstudios.sellpilot.analyses.25";
let clock = Date.UTC(2026, 10, 2);

/** A pretend "signed" transaction: the verifier below just reads it, so these tests are about the rules, not the cryptography. */
const jws = (fields) => `fake.${Buffer.from(JSON.stringify({ bundleId: DEFAULTS.bundleId, environment: "Production", ...fields })).toString("base64url")}.sig`;
const verify = (text) => { const [, body, sig] = text.split("."); if (sig !== "sig") throw new Error("bad"); return JSON.parse(Buffer.from(body, "base64url").toString()); };
const subscription = (fields = {}) => jws({ transactionId: "t-sub", originalTransactionId: "o-sub", productId: MONTHLY, originalPurchaseDate: clock - 2 * DAY, purchaseDate: clock - 2 * DAY, expiresDate: clock + 28 * DAY, ...fields });
const pack = (id, fields = {}) => jws({ transactionId: id, productId: PACK, ...fields });
const make = (options = {}) => createAllowances(memoryStore(), { verify, now: () => clock, ...options });
const analyze = async (a, who = {}) => { const plan = await a.plan({ installKey: KEY, ...who }); return plan.exhausted ? plan : { ...plan, allowance: await a.commit(plan) }; };

test.beforeEach(() => { clock = Date.UTC(2026, 10, 2); });

test("a new install gets five free analyses, then is told it is out", async () => {
  const a = make();
  for (let left = 4; left >= 0; left--) { const result = await analyze(a); assert.equal(result.source, "free"); assert.equal(result.allowance.free, left); }
  const out = await a.plan({ installKey: KEY });
  assert.equal(out.exhausted, true); assert.deepEqual(out.allowance, { free: 0, credits: 0, plus: null });
});

test("free analyses belong to one install; another install starts fresh", async () => {
  const a = make();
  for (let i = 0; i < 5; i++) await analyze(a);
  assert.equal((await a.plan({ installKey: OTHER })).source, "free");
});

test("planning spends nothing; only committing does", async () => {
  const a = make();
  for (let i = 0; i < 10; i++) await a.plan({ installKey: KEY });
  assert.equal((await a.status({ installKey: KEY })).free, 5);
});

test("a pack adds 25 credits once, however many times the app repeats the request", async () => {
  const a = make();
  const first = await a.redeem({ installKey: KEY, transaction: pack("p1") });
  assert.equal(first.ok, true); assert.equal(first.added, 25); assert.equal(first.allowance.credits, 25);
  const again = await a.redeem({ installKey: KEY, transaction: pack("p1") });
  assert.equal(again.ok, true); assert.equal(again.added, 0); assert.equal(again.allowance.credits, 25);
  assert.equal((await a.redeem({ installKey: KEY, transaction: pack("p2") })).allowance.credits, 50);
});

test("credits are spent last, after the free analyses", async () => {
  const a = make();
  await a.redeem({ installKey: KEY, transaction: pack("p1") });
  for (let i = 0; i < 5; i++) assert.equal((await analyze(a)).source, "free");
  const spent = await analyze(a);
  assert.equal(spent.source, "credits"); assert.equal(spent.allowance.credits, 24);
});

test("credits stay with the install that redeemed them", async () => {
  const a = make();
  await a.redeem({ installKey: KEY, transaction: pack("p1") });
  for (let i = 0; i < 5; i++) await analyze(a, {});
  assert.equal((await a.plan({ installKey: OTHER })).source, "free");
  for (let i = 0; i < 4; i++) await analyze(a, { installKey: OTHER });
});

test("a subscriber gets 60 a month, used before the free ones, and is told when it renews", async () => {
  const a = make();
  const entitlement = subscription();
  const first = await analyze(a, { entitlement });
  assert.equal(first.source, "plus"); assert.equal(first.allowance.plus.remaining, 59); assert.equal(first.allowance.free, 5);
  for (let i = 0; i < 59; i++) assert.equal((await analyze(a, { entitlement })).source, "plus");
  const next = await a.plan({ installKey: KEY, entitlement });
  assert.equal(next.source, "free", "the monthly set is used up, so the free ones are next");
  assert.equal(next.allowance.plus.remaining, 0); assert.equal(next.allowance.plus.renews, clock - 2 * DAY + DEFAULTS.periodMs);
});

test("the monthly set renews every 30 days from the first purchase", async () => {
  const a = make({ freeAnalyses: 0 });
  const start = clock - 2 * DAY;
  const entitlement = subscription();
  for (let i = 0; i < 60; i++) await analyze(a, { entitlement });
  assert.equal((await a.plan({ installKey: KEY, entitlement })).exhausted, true);
  clock += 29 * DAY;
  const renewed = await a.plan({ installKey: KEY, entitlement: subscription({ originalPurchaseDate: start, purchaseDate: start + 30 * DAY, expiresDate: clock + 28 * DAY }) });
  assert.equal(renewed.source, "plus"); assert.equal(renewed.allowance.plus.remaining, 60);
});

test("the monthly count follows the subscription, not the install, so it cannot be reset by a new install code", async () => {
  const a = make({ freeAnalyses: 0 });
  const entitlement = subscription();
  for (let i = 0; i < 60; i++) await analyze(a, { entitlement });
  assert.equal((await a.plan({ installKey: OTHER, entitlement })).exhausted, true);
});

test("an exhausted subscriber can still use pack credits", async () => {
  const a = make({ freeAnalyses: 0 });
  const entitlement = subscription();
  for (let i = 0; i < 60; i++) await analyze(a, { entitlement });
  await a.redeem({ installKey: KEY, transaction: pack("p1"), entitlement });
  assert.equal((await analyze(a, { entitlement })).source, "credits");
});

test("transactions that are not good are ignored: expired, another app, wrong product, revoked, unsigned", async () => {
  const a = make({ freeAnalyses: 0 });
  const bad = [
    subscription({ expiresDate: clock - 1 }), subscription({ bundleId: "com.someone.else" }), subscription({ productId: "com.other.product" }),
    subscription({ revocationDate: clock - DAY }), subscription({ productId: PACK }), subscription({ environment: "Xcode" }), "fake.e30.notsig", "garbage",
  ];
  for (const entitlement of bad) assert.equal((await a.plan({ installKey: KEY, entitlement })).exhausted, true, String(entitlement).slice(0, 40));
  for (const transaction of [pack("x1", { bundleId: "com.someone.else" }), pack("x2", { revocationDate: 1 }), pack("x3", { productId: MONTHLY }), "garbage"]) assert.equal((await a.redeem({ installKey: KEY, transaction })).ok, false);
  assert.equal((await a.status({ installKey: KEY })).credits, 0);
});

test("sandbox purchases (TestFlight and App Review) count unless the studio turns them off", async () => {
  const sandboxSub = subscription({ environment: "Sandbox" });
  assert.equal((await make({ freeAnalyses: 0 }).plan({ installKey: KEY, entitlement: sandboxSub })).source, "plus");
  assert.equal((await make({ freeAnalyses: 0, acceptSandbox: false }).plan({ installKey: KEY, entitlement: sandboxSub })).exhausted, true);
});

test("the products on sale match what the app and the allowances expect", () => {
  assert.deepEqual(Object.keys(PRODUCTS).sort(), [PACK, MONTHLY, "com.tidewrightstudios.sellpilot.plus.yearly"].sort());
  assert.equal(PRODUCTS[PACK].credits, 25); assert.equal(DEFAULTS.freeAnalyses, 5); assert.equal(DEFAULTS.plusPerPeriod, 60);
});

test("settings come from the environment, with safe defaults for anything missing or malformed", () => {
  assert.deepEqual(allowanceOptions({}), { bundleId: DEFAULTS.bundleId, freeAnalyses: 5, plusPerPeriod: 60, acceptSandbox: true });
  assert.deepEqual(allowanceOptions({ AI_FREE_ANALYSES: "3", AI_PLUS_PER_PERIOD: "100", APP_BUNDLE_ID: "com.x", AI_ACCEPT_SANDBOX: "false" }), { bundleId: "com.x", freeAnalyses: 3, plusPerPeriod: 100, acceptSandbox: false });
  assert.equal(allowanceOptions({ AI_FREE_ANALYSES: "0" }).freeAnalyses, 0);
  assert.equal(allowanceOptions({ AI_FREE_ANALYSES: "lots", AI_PLUS_PER_PERIOD: "-4" }).freeAnalyses, 5);
  assert.equal(allowanceOptions({ AI_PLUS_PER_PERIOD: "-4" }).plusPerPeriod, 60);
});

test("the account endpoint reports what is left, redeems packs, and refuses what it cannot verify", async () => {
  const a = make();
  const ask = (extra) => handleAccount({ allowances: a, installKey: KEY, method: "GET", body: null, ...extra });
  assert.deepEqual((await ask({})).body, { paywall: true, allowance: { free: 5, credits: 0, plus: null } });
  assert.equal((await ask({ installKey: "short" })).status, 401);
  assert.equal((await ask({ installKey: null })).status, 401);
  assert.equal((await ask({ method: "DELETE" })).status, 405);
  const redeemed = await ask({ method: "POST", body: { transaction: pack("p1") } });
  assert.equal(redeemed.status, 200); assert.equal(redeemed.body.added, 25); assert.equal(redeemed.body.allowance.credits, 25);
  assert.equal((await ask({ method: "POST", body: { transaction: "garbage" } })).status, 422);
  assert.equal((await ask({ method: "POST", body: {} })).status, 400);
  assert.equal((await ask({ method: "POST", body: null })).status, 400);
  assert.equal((await ask({ paywallOn: false })).body.paywall, false);
});

test("if the store is down the account endpoint says so plainly", async () => {
  const broken = createAllowances({ get: async () => { throw new Error("down"); }, set: async () => { throw new Error("down"); } }, { verify, now: () => clock });
  const result = await handleAccount({ allowances: broken, installKey: KEY, method: "GET", body: null });
  assert.equal(result.status, 503); assert.match(result.body.message, /nothing has been lost/);
});
