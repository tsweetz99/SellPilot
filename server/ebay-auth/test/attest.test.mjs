import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash, createPrivateKey, sign } from "node:crypto";
import { decodeCbor } from "../lib/cbor.mjs";
import { verifyAttestation, verifyAssertion, createAttest, parseAuthData, APPLE_APP_ATTEST_ROOT_CA, APP_ID } from "../lib/attest.mjs";
import { attestVerdict } from "../lib/attestGate.mjs";
import { handleAttest } from "../lib/attestEndpoint.mjs";
import { handleAI } from "../lib/ai.mjs";
import { memoryStore, createBudget } from "../lib/rateLimit.mjs";
import { X509Certificate } from "node:crypto";

const fixture = (name) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");
const vector = JSON.parse(fixture("attest-vector.json"));
const roots = [fixture("attest-root.pem")];
const deviceKey = createPrivateKey(fixture("attest-device.key.pem"));
const sha256 = (...parts) => { const h = createHash("sha256"); parts.forEach((p) => h.update(p)); return h.digest(); };
const INSTALL = "0123456789abcdef0123456789abcdef";
const OTHER_INSTALL = "fedcba9876543210fedcba9876543210";

// --- A tiny CBOR writer, only for building test objects ---
function head(major, length) {
  if (length < 24) return Buffer.from([(major << 5) | length]);
  if (length < 256) return Buffer.from([(major << 5) | 24, length]);
  const b = Buffer.alloc(3); b[0] = (major << 5) | 25; b.writeUInt16BE(length, 1); return b;
}
const cbor = (value) => {
  if (Buffer.isBuffer(value)) return Buffer.concat([head(2, value.length), value]);
  if (typeof value === "string") { const b = Buffer.from(value); return Buffer.concat([head(3, b.length), b]); }
  if (typeof value === "number") return head(0, value);
  if (Array.isArray(value)) return Buffer.concat([head(4, value.length), ...value.map(cbor)]);
  const keys = Object.keys(value);
  return Buffer.concat([head(5, keys.length), ...keys.flatMap((k) => [cbor(k), cbor(value[k])])]);
};
const der = (pem) => new X509Certificate(pem).raw;
const attestationFor = (variant = "good", { fmt = "apple-appattest", chain } = {}) => cbor({
  fmt, attStmt: { x5c: chain ?? [der(vector.variants[variant].credentialPem), der(fixture("attest-intermediate.pem"))], receipt: Buffer.from("receipt") },
  authData: Buffer.from(vector.variants[variant].authData, "base64"),
}).toString("base64");
const verifyGood = (extra = {}) => verifyAttestation({ attestation: attestationFor(), challenge: vector.challenge, keyId: vector.keyId, roots, ...extra });

function assertionFor(body, counter, { appId = vector.appId, key = deviceKey, tamper = false } = {}) {
  const auth = Buffer.concat([sha256(Buffer.from(appId)), Buffer.from([0x40]), Buffer.alloc(4)]);
  auth.writeUInt32BE(counter, 33);
  const signature = sign("sha256", sha256(Buffer.concat([auth, sha256(Buffer.from(tamper ? body + "x" : body))])), key);
  return cbor({ signature, authenticatorData: auth }).toString("base64");
}

test("the real Apple App Attest root is pinned", () => {
  assert.equal(new X509Certificate(APPLE_APP_ATTEST_ROOT_CA).subject.includes("Apple App Attestation Root CA"), true);
  assert.equal(APP_ID, "2XC3GTJ8B8.com.tidewrightstudios.sellpilot");
  assert.throws(() => verifyAttestation({ attestation: attestationFor(), challenge: vector.challenge, keyId: vector.keyId }), /not issued by Apple/);
});

test("a genuine attestation is accepted and yields the device's public key", () => {
  const result = verifyGood();
  assert.equal(result.environment, "production"); assert.match(result.publicKeyPem, /BEGIN PUBLIC KEY/);
});

test("an attestation fails if anything about it is off", () => {
  assert.throws(() => verifyGood({ challenge: "some-other-challenge" }), /challenge does not match/);
  assert.throws(() => verifyGood({ keyId: Buffer.alloc(32, 1).toString("base64") }), /key id does not match/);
  assert.throws(() => verifyGood({ attestation: attestationFor("otherApp") }), /different app/);
  assert.throws(() => verifyGood({ attestation: attestationFor("counter") }), /counter is not zero/);
  assert.throws(() => verifyGood({ attestation: attestationFor("good", { fmt: "packed" }) }), /format/);
  assert.throws(() => verifyGood({ attestation: attestationFor("good", { chain: [der(vector.variants.good.credentialPem)] }) }), /certificate chain missing/);
  assert.throws(() => verifyGood({ roots: [fixture("attest-intermediate.pem")] }), /not issued by Apple|broken/);
  assert.throws(() => verifyGood({ attestation: "not base64 at all!" }), /not base64/);
  assert.throws(() => verifyGood({ now: Date.now() + 200 * 365 * 86_400_000 }), /not valid now/);
});

test("a development-environment attestation is refused unless the studio allows it", () => {
  const development = { attestation: attestationFor("development") };
  assert.throws(() => verifyGood(development), /not a production attestation/);
  assert.equal(verifyGood({ ...development, allowDevelopment: true }).environment, "development");
});

test("a signed request is accepted, and only if it is the same request, newer, and from this app", () => {
  const { publicKeyPem } = verifyGood();
  const body = '{"task":"identify"}';
  assert.equal(verifyAssertion({ assertion: assertionFor(body, 1), clientData: body, publicKeyPem, storedCounter: 0 }), 1);
  assert.throws(() => verifyAssertion({ assertion: assertionFor(body, 1), clientData: body + " ", publicKeyPem, storedCounter: 0 }), /signature does not match/);
  assert.throws(() => verifyAssertion({ assertion: assertionFor(body, 1, { tamper: true }), clientData: body, publicKeyPem, storedCounter: 0 }), /signature does not match/);
  assert.throws(() => verifyAssertion({ assertion: assertionFor(body, 1), clientData: body, publicKeyPem, storedCounter: 1 }), /replayed/);
  assert.throws(() => verifyAssertion({ assertion: assertionFor(body, 5), clientData: body, publicKeyPem, storedCounter: 9 }), /replayed/);
  assert.throws(() => verifyAssertion({ assertion: assertionFor(body, 2, { appId: vector.otherAppId }), clientData: body, publicKeyPem, storedCounter: 0 }), /different app/);
  assert.throws(() => verifyAssertion({ assertion: "AAAA", clientData: body, publicKeyPem, storedCounter: 0 }), /not readable|incomplete/);
});

test("CBOR: reads what App Attest sends and refuses anything malformed", () => {
  assert.deepEqual(decodeCbor(cbor({ a: 1, b: Buffer.from("xy"), c: ["z", 300] })), { a: 1, b: Buffer.from("xy"), c: ["z", 300] });
  assert.throws(() => decodeCbor(Buffer.from([0xa1, 0x61])), /ended early/);
  assert.throws(() => decodeCbor(Buffer.concat([cbor(1), Buffer.from([0])])), /Extra bytes/);
  assert.throws(() => decodeCbor(Buffer.from([0x5a, 0xff, 0xff, 0xff, 0xff])), /too large|ended early/);
  assert.throws(() => decodeCbor(Buffer.from([0xa1, 0x01, 0x01])), /text map keys/);
  assert.throws(() => decodeCbor(Buffer.from(Array(40).fill(0x81).concat([0x00]))), /nested too deeply/);
  assert.throws(() => decodeCbor(Buffer.from([0xf9, 0, 0])), /Unsupported/);
  assert.throws(() => parseAuthData(Buffer.alloc(10)), /too short/);
});

const service = (extra = {}) => { const store = memoryStore(); const start = Date.now(); let clock = start; const attest = createAttest(store, { roots, now: () => clock, ...extra }); return { attest, store, start, tick: (ms) => { clock += ms; } }; };
const registered = async (extra) => { const s = service(extra); const challenge = vector.challenge; await s.store.set(`attest-challenge:${challenge}`, { expires: s.start + 600_000, used: false }); return { ...s, challenge }; };
const register = (s, over = {}) => s.attest.register({ installKey: INSTALL, keyId: vector.keyId, attestation: attestationFor(), challenge: s.challenge, ...over });

test("registering a device: challenge is single-use, expires, and the key registers once, for one install", async () => {
  const s = await registered();
  assert.deepEqual(await register(s), { ok: true, environment: "production" });
  assert.equal((await register(s)).reason, "challenge is unknown, used or expired", "the challenge only works once");
  const fresh = service(); await fresh.store.set(`attest-challenge:${vector.challenge}`, { expires: fresh.start + 600_000, used: false });
  await register({ ...fresh, challenge: vector.challenge });
  await fresh.store.set(`attest-challenge:c2`, { expires: fresh.start + 600_000, used: false });
  assert.equal((await fresh.attest.register({ installKey: OTHER_INSTALL, keyId: vector.keyId, attestation: attestationFor(), challenge: "c2" })).reason, "key already registered");
  const stale = await registered(); stale.tick(11 * 60_000);
  assert.equal((await register(stale)).ok, false, "an expired challenge is refused");
  assert.equal((await register(await registered(), { challenge: "never-issued" })).ok, false);
  const wrong = await registered(); assert.equal((await register(wrong, { attestation: attestationFor("counter") })).ok, false);
});

test("a fresh challenge from the service works end to end", async () => {
  const s = service();
  const challenge = await s.attest.challenge();
  assert.match(challenge, /^[A-Za-z0-9_-]{20,}$/);
  assert.equal((await s.store.get(`attest-challenge:${challenge}`)).used, false);
});

test("judging requests: missing, valid, and the ways a request can be invalid", async () => {
  const s = await registered(); await register(s);
  const body = '{"task":"identify","photos":[]}';
  const call = (over = {}) => s.attest.check({ installKey: INSTALL, keyId: vector.keyId, assertion: assertionFor(body, 1), body, ...over });
  assert.deepEqual(await s.attest.check({ installKey: INSTALL, body }), { state: "missing" });
  assert.deepEqual(await call(), { state: "valid" });
  assert.equal((await call()).reason, "counter did not increase (replayed request)", "the same signed request cannot be replayed");
  assert.deepEqual(await call({ assertion: assertionFor(body, 2) }), { state: "valid" });
  assert.equal((await call({ assertion: assertionFor(body, 3), body: body + "tampered" })).reason, "signature does not match");
  assert.equal((await call({ assertion: assertionFor(body, 4), installKey: OTHER_INSTALL })).reason, "key belongs to a different install");
  assert.equal((await call({ assertion: assertionFor(body, 5), keyId: Buffer.alloc(32, 9).toString("base64") })).reason, "unknown key");
  assert.equal((await call({ assertion: null })).reason, "proof is incomplete");
  assert.equal((await call({ keyId: null })).reason, "proof is incomplete");
});

test("the gate: soft mode lets everything through but says what it saw; required mode refuses what is not proven", async () => {
  const stub = (state, reason) => ({ check: async () => ({ state, reason }) });
  assert.deepEqual(await attestVerdict(null, { installKey: INSTALL }), { ok: true, state: "off" });
  assert.equal((await attestVerdict(stub("valid"), { installKey: INSTALL, required: true })).ok, true);
  for (const state of ["missing", "invalid"]) {
    const soft = await attestVerdict(stub(state, "x"), { installKey: INSTALL });
    assert.equal(soft.ok, true); assert.equal(soft.state, state);
    const hard = await attestVerdict(stub(state, "x"), { installKey: INSTALL, required: true });
    assert.equal(hard.ok, false); assert.equal(hard.response.status, 401);
    assert.equal(hard.response.body.error, state === "missing" ? "attest_required" : "attest_invalid");
    assert.match(hard.response.body.message, state === "missing" ? /update/i : /reopen/i);
  }
  const broken = await attestVerdict({ check: async () => { throw new Error("store down"); } }, { installKey: INSTALL, required: true });
  assert.equal(broken.ok, false, "if the check itself fails, nothing gets through when proof is required");
});

test("the registration endpoint hands out challenges and registers keys, with limits", async () => {
  const s = service();
  const call = (extra) => handleAttest({ method: "GET", body: null, installKey: INSTALL, attest: s.attest, ...extra });
  const issued = await call({});
  assert.equal(issued.status, 200); assert.ok(issued.body.challenge);
  assert.equal((await call({ method: "DELETE" })).status, 405);
  assert.equal((await call({ installKey: "short" })).status, 401);
  assert.equal((await call({ attest: null })).status, 503);
  assert.equal((await call({ method: "POST", body: { keyId: 1 } })).status, 400);
  assert.equal((await call({ method: "POST", body: { keyId: vector.keyId, attestation: attestationFor(), challenge: "unknown" } })).status, 422);
  const limited = await call({ limiter: { check: async () => ({ allowed: false, retryAfterSeconds: 60 }) } });
  assert.equal(limited.status, 429); assert.equal(limited.retryAfterSeconds, 60);
  const down = await call({ attest: { challenge: async () => { throw new Error("down"); } } });
  assert.equal(down.status, 503);
});

// --- Wired into the AI handler ---
const KEY = INSTALL;
const env = { AI_ENABLED: "true", ANTHROPIC_API_KEY: "sk-ant-test" };
const jpeg = () => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(300, 7)]).toString("base64");
const upstream = async () => ({ ok: true, status: 200, json: async () => ({ content: [{ type: "tool_use", name: "report_identification", input: { title: "x" } }] }) });
const ai = (attestCheck, calls = []) => handleAI({ method: "POST", body: { task: "identify", photos: [{ data: jpeg() }] }, env, fetchImpl: async (...a) => { calls.push(a); return upstream(); }, installKey: KEY, address: "203.0.113.9", budget: createBudget(memoryStore()), attestCheck });

test("the AI service: with proof required, an unproven request is refused before anything is sent to Claude", async () => {
  const calls = [];
  const refused = await ai(({ installKey }) => attestVerdict({ check: async () => ({ state: "missing" }) }, { required: true, installKey }), calls);
  assert.equal(refused.status, 401); assert.equal(refused.body.error, "attest_required"); assert.equal(calls.length, 0);
  const soft = await ai(({ installKey }) => attestVerdict({ check: async () => ({ state: "missing" }) }, { required: false, installKey }), calls);
  assert.equal(soft.status, 200); assert.equal(calls.length, 1);
  const proven = await ai(({ installKey }) => attestVerdict({ check: async () => ({ state: "valid" }) }, { required: true, installKey }));
  assert.equal(proven.status, 200);
});

test("a rejected registration and an invalid request log their reason, and nothing else", async () => {
  const s = service(); const lines = [];
  const rejected = await handleAttest({ method: "POST", body: { keyId: vector.keyId, attestation: attestationFor(), challenge: "unknown" }, installKey: INSTALL, attest: s.attest, log: (l) => lines.push(l) });
  assert.equal(rejected.status, 422);
  assert.match(lines.at(-1), /"event":"attest_rejected"/); assert.match(lines.at(-1), /challenge is unknown/); assert.doesNotMatch(lines.join(""), new RegExp(vector.keyId));
  const ai = [];
  await handleAI({ method: "POST", body: { task: "identify", photos: [{ data: jpeg() }] }, env, fetchImpl: upstream, installKey: KEY, address: "x", budget: createBudget(memoryStore()), attestCheck: async () => ({ ok: true, state: "invalid", reason: "unknown key" }), log: (l) => ai.push(l) });
  assert.match(ai.at(-1), /"attest":"invalid"/); assert.match(ai.at(-1), /"attest_reason":"unknown key"/);
});

test("the AI service logs how many requests are proven, never the proof itself", async () => {
  const lines = [];
  await handleAI({ method: "POST", body: { task: "identify", photos: [{ data: jpeg() }] }, env, fetchImpl: upstream, installKey: KEY, address: "x", budget: createBudget(memoryStore()), attestCheck: async () => ({ ok: true, state: "valid" }), log: (l) => lines.push(l) });
  assert.match(lines.at(-1), /"attest":"valid"/); assert.doesNotMatch(lines.join(""), /assertion|attestation/);
});
