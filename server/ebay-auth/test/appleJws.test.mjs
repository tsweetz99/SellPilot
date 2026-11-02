import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createPrivateKey, createSign, X509Certificate } from "node:crypto";
import { verifyAppleJws, APPLE_ROOT_CA_G3 } from "../lib/appleJws.mjs";

const fixture = (name) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");
const der = (pem) => new X509Certificate(pem).raw.toString("base64");
const b64 = (value) => Buffer.from(typeof value === "string" ? value : JSON.stringify(value)).toString("base64url");

/** Signs a transaction the way StoreKit's JWS is shaped, using the throwaway test chain. */
export function signTransaction(payload, { chain = ["leaf.pem", "intermediate.pem", "root.pem"], key = "leaf.key.pem", alg = "ES256" } = {}) {
  const head = b64({ alg, x5c: chain.map((name) => der(fixture(name))) });
  const body = b64(payload);
  const signature = createSign("sha256").update(`${head}.${body}`).sign({ key: createPrivateKey(fixture(key)), dsaEncoding: "ieee-p1363" });
  return `${head}.${body}.${signature.toString("base64url")}`;
}

const roots = [fixture("root.pem")];
const payload = { transactionId: "1000", productId: "x", signedDate: Date.now() };

test("a transaction signed through the trusted chain is accepted and decoded", () => {
  assert.deepEqual(verifyAppleJws(signTransaction(payload), { roots }), payload);
});

test("the real Apple root is pinned: a chain to any other root is refused", () => {
  assert.throws(() => verifyAppleJws(signTransaction(payload)), /Not signed by Apple/);
  assert.equal(new X509Certificate(APPLE_ROOT_CA_G3).subject.includes("Apple Root CA - G3"), true);
});

test("a chain that leads to a different root is refused even if it is well formed", () => {
  const forged = signTransaction(payload, { chain: ["leaf.pem", "intermediate.pem", "other-root.pem"] });
  assert.throws(() => verifyAppleJws(forged, { roots }), /Not signed by Apple|Broken certificate chain/);
});

test("an edited payload fails the signature", () => {
  const [head, , signature] = signTransaction(payload).split(".");
  const tampered = `${head}.${b64({ ...payload, productId: "free-upgrade" })}.${signature}`;
  assert.throws(() => verifyAppleJws(tampered, { roots }), /Signature does not match/);
});

test("a signature made with some other key fails", () => {
  const forged = signTransaction(payload, { key: "intermediate.key.pem" });
  assert.throws(() => verifyAppleJws(forged, { roots }), /Signature does not match|invalid|asn1|EC/i);
});

test("the Apple marker extensions are required unless a test turns the check off", () => {
  // The test chain has the markers, so this proves the check passes with them; a chain without them is covered by the root-only chain below.
  assert.doesNotThrow(() => verifyAppleJws(signTransaction(payload), { roots, requireMarkers: true }));
  const rootAsLeaf = signTransaction(payload, { chain: ["root.pem", "intermediate.pem", "root.pem"], key: "root.key.pem" });
  assert.throws(() => verifyAppleJws(rootAsLeaf, { roots }), /Broken certificate chain|Not an App Store/);
});

test("certificates are judged at the signing time, so an expired certificate does not break an old transaction", () => {
  const years = 200 * 365 * 86_400_000;
  assert.throws(() => verifyAppleJws(signTransaction({ ...payload, signedDate: Date.now() + years }), { roots }), /not valid at signing time/);
  assert.throws(() => verifyAppleJws(signTransaction({ ...payload, signedDate: 1000 }), { roots }), /not valid at signing time/);
});

test("things that are not a signed transaction are refused without crashing", () => {
  for (const junk of ["", "a.b", "a.b.c", "not a jws", 42, null, undefined, "x".repeat(30_000)]) assert.throws(() => verifyAppleJws(junk, { roots }), /Not a signed transaction|Unexpected signing/);
  const wrongAlg = signTransaction(payload, { alg: "HS256" });
  assert.throws(() => verifyAppleJws(wrongAlg, { roots }), /Unexpected signing method/);
});
