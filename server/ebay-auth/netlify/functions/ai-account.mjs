import { getStore } from "@netlify/blobs";
import { createAllowances } from "../../lib/allowances.mjs";
import { allowanceOptions } from "../../lib/allowanceConfig.mjs";
import { handleAccount } from "../../lib/account.mjs";

// GET  /api/ai/account                         what this install has left
// POST /api/ai/account  {"transaction":"<JWS>"}  turns a bought pack into credits
// Headers: x-sellpilot-install, and x-sellpilot-entitlement for SellPilot Plus.
export default async (request) => {
  const store = getStore("ai-allowances");
  const allowances = createAllowances({ get: (key) => store.get(key, { type: "json" }), set: (key, value) => store.setJSON(key, value) }, allowanceOptions(process.env));
  let body = null;
  if (request.method === "POST") { try { body = await request.json(); } catch { /* handled as invalid */ } }
  const result = await handleAccount({ method: request.method, body, installKey: request.headers.get("x-sellpilot-install"), entitlement: request.headers.get("x-sellpilot-entitlement"), allowances, paywallOn: process.env.AI_PAYWALL !== "off" });
  return new Response(JSON.stringify(result.body), { status: result.status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
};

export const config = { path: "/api/ai/account" };
