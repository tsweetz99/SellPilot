import { getStore } from "@netlify/blobs";
import { createAllowances } from "../../lib/allowances.mjs";
import { allowanceOptions } from "../../lib/allowanceConfig.mjs";
import { handleAccount } from "../../lib/account.mjs";
import { createAttest } from "../../lib/attest.mjs";
import { attestVerdict } from "../../lib/attestGate.mjs";

// GET  /api/ai/account                         what this install has left
// POST /api/ai/account  {"transaction":"<JWS>"}  turns a bought pack into credits
// Headers: x-sellpilot-install, and x-sellpilot-entitlement for SellPilot Plus.
export default async (request) => {
  const store = getStore("ai-allowances");
  const allowances = createAllowances({ get: (key) => store.get(key, { type: "json" }), set: (key, value) => store.setJSON(key, value) }, allowanceOptions(process.env));
  const text = request.method === "POST" ? await request.text() : "";
  let body = null;
  if (text) { try { body = JSON.parse(text); } catch { /* handled as invalid */ } }
  const attestStore = getStore("ai-attest");
  const attest = process.env.AI_ATTEST === "on" ? createAttest({ get: (key) => attestStore.get(key, { type: "json" }), set: (key, value) => attestStore.setJSON(key, value) }, { allowDevelopment: process.env.AI_ATTEST_ALLOW_DEVELOPMENT === "true" }) : null;
  const attestCheck = ({ installKey }) => attestVerdict(attest, { required: process.env.AI_REQUIRE_ATTEST === "true", installKey, keyId: request.headers.get("x-sellpilot-attest-key"), assertion: request.headers.get("x-sellpilot-assertion"), body: text });
  const result = await handleAccount({ method: request.method, body, installKey: request.headers.get("x-sellpilot-install"), entitlement: request.headers.get("x-sellpilot-entitlement"), allowances, paywallOn: process.env.AI_PAYWALL !== "off", attestCheck });
  return new Response(JSON.stringify(result.body), { status: result.status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
};

export const config = { path: "/api/ai/account" };
