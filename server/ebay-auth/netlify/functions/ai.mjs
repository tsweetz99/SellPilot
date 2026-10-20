import { getStore } from "@netlify/blobs";
import { handleAI, LIMITS } from "../../lib/ai.mjs";
import { createBudget } from "../../lib/rateLimit.mjs";

// POST https://<your-site>/api/ai   {"task":"identify","photos":[{"data":"<base64 JPEG>"}]}  or  {"task":"facts","description":"..."}
export default async (request, context) => {
  // A little over the photo cap, because the photos travel as base64 text.
  const text = await request.text();
  if (text.length > Math.ceil(LIMITS.totalBytes * 1.4) + 4000) return json(413, { error: "request_too_large", message: "The photos are too large to analyze. Remove a few and try again." });
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { /* handled as an invalid body */ }

  const store = getStore("ai-budget");
  const budget = createBudget({
    get: (key) => store.get(key, { type: "json" }),
    set: (key, value) => store.setJSON(key, value),
  }, {
    installPerDay: Number(process.env.AI_UNITS_PER_INSTALL_PER_DAY) || 60,
    addressPerHour: Number(process.env.AI_UNITS_PER_ADDRESS_PER_HOUR) || 90,
    globalPerDay: Number(process.env.AI_UNITS_PER_DAY) || 1500,
  });

  const result = await handleAI({
    method: request.method, body, env: process.env, installKey: request.headers.get("x-sellpilot-install"),
    address: context?.ip ?? request.headers.get("x-nf-client-connection-ip"), budget, log: (line) => console.log(line),
  });
  return json(result.status, result.body, result.retryAfterSeconds ? { "Retry-After": String(result.retryAfterSeconds) } : {});
};

const json = (status, payload, extra = {}) => new Response(JSON.stringify(payload), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...extra } });

export const config = { path: "/api/ai" };
