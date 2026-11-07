import { getStore } from "@netlify/blobs";
import { createAttest } from "../../lib/attest.mjs";
import { createLimiter } from "../../lib/rateLimit.mjs";
import { handleAttest } from "../../lib/attestEndpoint.mjs";
import { createHash } from "node:crypto";

// GET  /api/attest                                          a one-time challenge for registering this device's key
// POST /api/attest {"keyId","attestation","challenge"}      registers the key (Apple's attestation) for this install
// Header: x-sellpilot-install. Off unless AI_ATTEST=on.
export default async (request, context) => {
  const store = getStore("ai-attest");
  const wrap = { get: (key) => store.get(key, { type: "json" }), set: (key, value) => store.setJSON(key, value) };
  const attest = process.env.AI_ATTEST === "on" ? createAttest(wrap, { allowDevelopment: process.env.AI_ATTEST_ALLOW_DEVELOPMENT === "true" }) : null;
  const limits = getStore("app-token-limits");
  const limiter = createLimiter({ get: (key) => limits.get(key, { type: "json" }), set: (key, value) => limits.setJSON(key, value) }, { perKeyPerHour: 20, globalPerHour: 600 });
  let body = null;
  if (request.method === "POST") { try { body = await request.json(); } catch { /* handled as invalid */ } }
  const address = createHash("sha256").update(String(context?.ip ?? request.headers.get("x-nf-client-connection-ip") ?? "unknown")).digest("hex").slice(0, 16);
  const result = await handleAttest({ method: request.method, body, installKey: request.headers.get("x-sellpilot-install"), attest, limiter, address, log: (line) => console.log(line) });
  return new Response(JSON.stringify(result.body), { status: result.status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...(result.retryAfterSeconds ? { "Retry-After": String(result.retryAfterSeconds) } : {}) } });
};

export const config = { path: "/api/attest" };
