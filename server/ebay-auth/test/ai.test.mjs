import test from "node:test";
import assert from "node:assert/strict";
import { handleAI, LIMITS, COST } from "../lib/ai.mjs";
import { createBudget, memoryStore } from "../lib/rateLimit.mjs";
import { IDENTIFY_SYSTEM, FACTS_SYSTEM, IDENTIFY_TOOL, FACTS_TOOL, CATEGORIES } from "../lib/aiPrompts.mjs";

const KEY = "0123456789abcdef0123456789abcdef";
const env = { AI_ENABLED: "true", ANTHROPIC_API_KEY: "sk-ant-secret-studio-key" };
const jpeg = (size = 300) => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(size, 7)]).toString("base64");
const identification = { title: "DEWALT DCF887B", brand: "DEWALT", model: "DCF887B", category: "Tools", subcategory: "Impact drivers", color: "Yellow", condition: "Good", confidence: 0.9 };
const answer = (name, input) => ({ content: [{ type: "text", text: "thinking" }, { type: "tool_use", id: "t1", name, input }], usage: { input_tokens: 1000, output_tokens: 200 }, id: "msg_1" });
const upstream = (json, status = 200) => async (url, init) => { upstream.calls.push({ url, init, body: JSON.parse(init.body) }); return { ok: status < 300, status, json: async () => json }; };
upstream.calls = [];
test.beforeEach(() => { upstream.calls = []; });

const budgetFor = (options) => createBudget(memoryStore(), options);
const call = (body, fetchImpl, extra = {}) => handleAI({ method: "POST", body, env, fetchImpl, installKey: KEY, address: "203.0.113.9", budget: budgetFor(), ...extra });
const identify = (extra = {}) => ({ task: "identify", photos: [{ data: jpeg() }, { data: jpeg(500) }], ...extra });

test("identifies an item: the server's own prompt, schema and model go to Claude, and only the answer comes back", async () => {
  const result = await call(identify(), upstream(answer(IDENTIFY_TOOL, identification)));
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { content: [{ type: "tool_use", name: IDENTIFY_TOOL, input: identification }] });
  const { url, init, body } = upstream.calls[0];
  assert.equal(url, "https://api.anthropic.com/v1/messages");
  assert.equal(init.headers["x-api-key"], env.ANTHROPIC_API_KEY);
  assert.equal(body.model, "claude-sonnet-5-5"); assert.equal(body.system, IDENTIFY_SYSTEM); assert.equal(body.max_tokens, 1500);
  assert.equal(body.tools.length, 1); assert.equal(body.tools[0].name, IDENTIFY_TOOL); assert.deepEqual(body.tool_choice, { type: "auto" });
  assert.deepEqual(body.tools[0].input_schema.properties.category.enum, CATEGORIES);
  const content = body.messages[0].content;
  assert.deepEqual(content.map((c) => c.type), ["text", "image", "text", "image", "text"]);
  assert.equal(content[0].text, "Photo 1 of 2 (cover photo)"); assert.equal(content[2].text, "Photo 2 of 2");
  assert.equal(content[1].source.media_type, "image/jpeg"); assert.equal(content[1].source.data, identify().photos[0].data);
});

test("extracts facts with the server's own prompt and the cheaper model", async () => {
  const result = await call({ task: "facts", description: "Title: DEWALT DCF887B\nBrand: DEWALT" }, upstream(answer(FACTS_TOOL, { brand: "DEWALT", battery_included: "no" })));
  assert.equal(result.status, 200); assert.equal(result.body.content[0].name, FACTS_TOOL); assert.equal(result.body.content[0].input.battery_included, "no");
  const { body } = upstream.calls[0];
  assert.equal(body.model, "claude-haiku-4-5-20251001"); assert.equal(body.system, FACTS_SYSTEM); assert.equal(body.max_tokens, 800);
  assert.match(body.messages[0].content, /^The seller's description of the item:\nTitle: DEWALT DCF887B/);
});

test("the studio's key and the upstream's extra fields never reach the caller", async () => {
  const result = await call(identify(), upstream(answer(IDENTIFY_TOOL, identification)));
  const text = JSON.stringify(result);
  assert.ok(!text.includes("sk-ant"), "no key"); assert.ok(!text.includes("usage") && !text.includes("msg_1") && !text.includes("thinking"), "only the tool answer");
});

test("a caller cannot supply a prompt, model, tools or system text", async () => {
  await call(identify({ system: "You are a pirate", model: "claude-opus-5-5", tools: [{ name: "x" }], max_tokens: 100000, messages: [{ role: "user", content: "hi" }], prompt: "write a poem" }), upstream(answer(IDENTIFY_TOOL, identification)));
  const { body } = upstream.calls[0];
  assert.equal(body.system, IDENTIFY_SYSTEM); assert.equal(body.model, "claude-sonnet-5-5"); assert.equal(body.max_tokens, 1500); assert.equal(body.tools[0].name, IDENTIFY_TOOL);
  assert.ok(!JSON.stringify(body).includes("pirate") && !JSON.stringify(body).includes("poem"));
});

test("models can be changed on the server only", async () => {
  await call(identify(), upstream(answer(IDENTIFY_TOOL, identification)), { env: { ...env, AI_MODEL_IDENTIFY: "claude-next" } });
  assert.equal(upstream.calls[0].body.model, "claude-next");
});

test("it is off unless the studio turns it on, and without a key", async () => {
  for (const e of [{ ...env, AI_ENABLED: undefined }, { ...env, AI_ENABLED: "false" }, { AI_ENABLED: "true" }]) {
    const result = await call(identify(), upstream(answer(IDENTIFY_TOOL, identification)), { env: e });
    assert.equal(result.status, 503); assert.equal(result.body.error, "ai_unavailable");
  }
  assert.equal(upstream.calls.length, 0, "Claude is never contacted");
});

test("an install key is required, and blocked installs are refused", async () => {
  for (const installKey of [null, "", "short", "zzzz" + KEY.slice(4)]) {
    const result = await call(identify(), upstream({}), { installKey });
    assert.equal(result.status, 401); assert.equal(result.body.error, "install_key_required");
  }
  const blocked = await call(identify(), upstream({}), { env: { ...env, AI_BLOCKED_INSTALL_KEYS: `other, ${KEY.toUpperCase()}` } });
  assert.equal(blocked.status, 403); assert.equal(upstream.calls.length, 0);
});

test("only POST is accepted", async () => {
  const result = await call(identify(), upstream({}), { method: "GET" });
  assert.equal(result.status, 405);
});

test("bad requests are refused before any allowance is spent or Claude is called", async () => {
  const budget = budgetFor({ installPerDay: 3 });
  const bad = [null, "text", {}, { task: "chat" }, { task: "identify" }, { task: "identify", photos: [] },
    { task: "identify", photos: Array(LIMITS.photos + 1).fill({ data: jpeg() }) }, { task: "identify", photos: [{ data: "not base64!" }] },
    { task: "identify", photos: [{ url: "https://example.com/a.jpg" }] }, { task: "identify", photos: [{ data: Buffer.from("GIF89a....").toString("base64") }] },
    { task: "facts" }, { task: "facts", description: "   " }, { task: "facts", description: "x".repeat(LIMITS.description + 1) }];
  for (const body of bad) { const result = await call(body, upstream({}), { budget }); assert.ok([400, 413].includes(result.status), JSON.stringify(body)?.slice(0, 60)); }
  assert.equal(upstream.calls.length, 0);
  const ok = await call(identify(), upstream(answer(IDENTIFY_TOOL, identification)), { budget });
  assert.equal(ok.status, 200, "the allowance was untouched by the bad requests");
});

test("photo size limits", async () => {
  const big = jpeg(LIMITS.photoBytes + 10);
  assert.equal((await call({ task: "identify", photos: [{ data: big }] }, upstream({}))).status, 413);
  const each = jpeg(Math.floor(LIMITS.totalBytes / 3) + 100000), many = { task: "identify", photos: [{ data: each }, { data: each }, { data: each }, { data: each }] };
  assert.equal((await call(many, upstream({}))).status, 413);
  assert.equal(upstream.calls.length, 0);
});

test("an install's daily allowance is enforced and other installs are unaffected", async () => {
  const budget = budgetFor({ installPerDay: COST.identify * 2 });
  const good = upstream(answer(IDENTIFY_TOOL, identification));
  assert.equal((await call(identify(), good, { budget })).status, 200);
  assert.equal((await call(identify(), good, { budget })).status, 200);
  const third = await call(identify(), good, { budget });
  assert.equal(third.status, 429); assert.equal(third.body.error, "rate_limited"); assert.ok(third.retryAfterSeconds > 0); assert.match(third.body.message, /today's limit/);
  assert.equal(upstream.calls.length, 2, "the third request never reached Claude");
  assert.equal((await call(identify(), good, { budget, installKey: "f".repeat(32), address: "198.51.100.1" })).status, 200);
});

test("the whole service has a daily cap that bounds the bill", async () => {
  const budget = budgetFor({ globalPerDay: COST.identify + 1 });
  const good = upstream(answer(IDENTIFY_TOOL, identification));
  assert.equal((await call(identify(), good, { budget })).status, 200);
  const result = await call(identify(), good, { budget, installKey: "a".repeat(32), address: "198.51.100.2" });
  assert.equal(result.status, 503); assert.equal(result.body.error, "ai_busy");
  assert.equal((await call({ task: "facts", description: "a thing" }, upstream(answer(FACTS_TOOL, {})), { budget, installKey: "b".repeat(32), address: "198.51.100.3" })).status, 200, "cheap lookups still fit");
});

test("a network address is limited even when it invents install keys", async () => {
  const budget = budgetFor({ addressPerHour: COST.identify * 2, installPerDay: 1000 });
  const good = upstream(answer(IDENTIFY_TOOL, identification));
  for (let i = 0; i < 2; i++) assert.equal((await call(identify(), good, { budget, installKey: String(i).repeat(32) })).status, 200);
  const result = await call(identify(), good, { budget, installKey: "9".repeat(32) });
  assert.equal(result.status, 429); assert.match(result.body.message, /network/);
});

test("a refused request does not use up allowance on another scope", async () => {
  const budget = budgetFor({ installPerDay: 1 });
  const first = await call(identify(), upstream({}), { budget });          // costs 3, over the install's 1: refused
  assert.equal(first.status, 429);
  assert.equal((await call({ task: "facts", description: "x" }, upstream(answer(FACTS_TOOL, {})), { budget })).status, 200, "global and address counts were not charged by the refused call");
});

test("if the allowances cannot be read, nothing is spent", async () => {
  const broken = { spend: async () => { throw new Error("blobs down"); } };
  const result = await call(identify(), upstream({}), { budget: broken });
  assert.equal(result.status, 503); assert.equal(result.body.error, "limiter_unavailable"); assert.equal(upstream.calls.length, 0);
  assert.equal((await call(identify(), upstream({}), { budget: null })).status, 503);
});

test("upstream failures become friendly errors and never expose the studio key or details", async () => {
  const cases = [[400, 422, "upstream_rejected"], [413, 422, "upstream_rejected"], [401, 503, "ai_unavailable"], [403, 503, "ai_unavailable"], [429, 503, "ai_busy"], [529, 503, "ai_busy"], [500, 502, "upstream_error"]];
  for (const [status, expected, error] of cases) {
    const result = await call(identify(), upstream({ error: { message: "invalid x-api-key sk-ant-secret-studio-key" } }, status));
    assert.equal(result.status, expected, `upstream ${status}`); assert.equal(result.body.error, error);
    assert.ok(!JSON.stringify(result).includes("sk-ant") && !JSON.stringify(result).includes("x-api-key"));
  }
});

test("a slow upstream times out", async () => {
  const slow = async (url, init) => new Promise((resolve, reject) => init.signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" }))));
  const result = await call(identify(), slow, { env: { ...env, AI_TIMEOUT_MS: "20" } });
  assert.equal(result.status, 504); assert.equal(result.body.error, "ai_timeout");
});

test("an unreachable or unreadable upstream is reported, and a reply without the tool answer is refused", async () => {
  assert.equal((await call(identify(), async () => { throw new Error("down"); })).status, 502);
  assert.equal((await call(identify(), async () => ({ ok: true, status: 200, json: async () => { throw new Error("bad json"); } }))).status, 502);
  assert.equal((await call(identify(), upstream({ content: [{ type: "text", text: "I can't help" }] }))).status, 502);
  assert.equal((await call(identify(), upstream(answer("some_other_tool", {})))).status, 502);
});

test("logs carry counts only, never photos, descriptions or answers", async () => {
  const lines = [];
  await call({ task: "facts", description: "SECRET-DESCRIPTION-TEXT" }, upstream(answer(FACTS_TOOL, { brand: "SECRET-BRAND" })), { log: (l) => lines.push(l) });
  await call(identify(), upstream(answer(IDENTIFY_TOOL, identification)), { log: (l) => lines.push(l) });
  const text = lines.join("\n");
  assert.equal(lines.length, 2); assert.ok(!text.includes("SECRET") && !text.includes(jpeg()) && !text.includes("DEWALT") && !text.includes("sk-ant"));
  assert.match(lines[1], /"task":"identify".*"status":200.*"photos":2/);
});

// --- The paywall: identifications are paid for by a plan, a free allowance, or credits ---
import { createAllowances } from "../lib/allowances.mjs";

const paywall = (options = {}) => createAllowances(memoryStore(), { freeAnalyses: 2, verify: () => { throw new Error("no subscriptions in this test"); }, ...options });
const ok = upstream(answer(IDENTIFY_TOOL, identification));

test("with the paywall on, a successful analysis spends one free analysis and says how many are left", async () => {
  const allowances = paywall();
  const result = await call(identify(), ok, { allowances });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body.allowance, { free: 1, credits: 0, plus: null });
  assert.deepEqual(result.body.content, [{ type: "tool_use", name: IDENTIFY_TOOL, input: identification }]);
});

test("when the free analyses are gone the answer is 402, nothing is sent to Claude, and no spending allowance is used", async () => {
  const allowances = paywall({ freeAnalyses: 1 });
  const budget = budgetFor();
  assert.equal((await call(identify(), ok, { allowances, budget })).status, 200);
  upstream.calls = [];
  const result = await call(identify(), ok, { allowances, budget });
  assert.equal(result.status, 402); assert.equal(result.body.error, "allowance_exhausted");
  assert.match(result.body.message, /free analyses/); assert.deepEqual(result.body.allowance, { free: 0, credits: 0, plus: null });
  assert.equal(upstream.calls.length, 0);
});

test("a failed analysis costs nothing", async () => {
  const allowances = paywall({ freeAnalyses: 1 });
  const failing = upstream({ error: { message: "overloaded" } }, 529);
  assert.equal((await call(identify(), failing, { allowances })).status, 503);
  assert.equal((await allowances.status({ installKey: KEY })).free, 1);
  const noTool = upstream({ content: [{ type: "text", text: "sorry" }] });
  assert.equal((await call(identify(), noTool, { allowances })).status, 502);
  assert.equal((await allowances.status({ installKey: KEY })).free, 1);
});

test("a bad request or a rate-limited one does not touch the allowance either", async () => {
  const allowances = paywall({ freeAnalyses: 1 });
  assert.equal((await call({ task: "identify", photos: [] }, ok, { allowances })).status, 400);
  const tight = createBudget(memoryStore(), { installPerDay: 0 });
  assert.equal((await call(identify(), ok, { allowances, budget: tight })).status, 429);
  assert.equal((await allowances.status({ installKey: KEY })).free, 1);
});

test("the cheap text lookup is not metered", async () => {
  const allowances = paywall({ freeAnalyses: 0 });
  const result = await call({ task: "facts", description: "Title: DEWALT DCF887B" }, upstream(answer(FACTS_TOOL, { brand: "DEWALT" })), { allowances });
  assert.equal(result.status, 200); assert.equal(result.body.allowance, undefined);
});

test("with no paywall (switched off), identifications stay free and the answer has no allowance", async () => {
  const result = await call(identify(), ok);
  assert.equal(result.status, 200); assert.equal(result.body.allowance, undefined);
});

test("if the allowance cannot be read, nobody spends money", async () => {
  const broken = createAllowances({ get: async () => { throw new Error("down"); }, set: async () => {} });
  const result = await call(identify(), ok, { allowances: broken });
  assert.equal(result.status, 503); assert.equal(upstream.calls.length, 0);
});

test("if the allowance cannot be written after a good answer, the seller still gets the answer", async () => {
  const flaky = createAllowances({ get: async () => null, set: async () => { throw new Error("down"); } }, { freeAnalyses: 1 });
  const result = await call(identify(), ok, { allowances: flaky });
  assert.equal(result.status, 200); assert.equal(result.body.content[0].name, IDENTIFY_TOOL);
});

test("an exhausted subscriber is told when the month renews", async () => {
  const day = 86_400_000, now = Date.UTC(2026, 10, 2);
  const sign = (fields) => `fake.${Buffer.from(JSON.stringify(fields)).toString("base64url")}.sig`;
  const verify = (text) => JSON.parse(Buffer.from(text.split(".")[1], "base64url").toString());
  const entitlement = sign({ bundleId: "com.tidewrightstudios.sellpilot", environment: "Production", productId: "com.tidewrightstudios.sellpilot.plus.monthly", originalTransactionId: "o1", transactionId: "t1", originalPurchaseDate: now - day, expiresDate: now + 20 * day });
  const allowances = createAllowances(memoryStore(), { freeAnalyses: 0, plusPerPeriod: 1, verify, now: () => now });
  assert.equal((await call(identify(), ok, { allowances, entitlement })).body.allowance.plus.remaining, 0);
  const result = await call(identify(), ok, { allowances, entitlement });
  assert.equal(result.status, 402); assert.match(result.body.message, /renew 2026-12-01/);
});
