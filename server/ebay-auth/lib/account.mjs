// The paywall's other two requests: "what do I have left?" and "I bought a pack, add it". Pure logic, so it can be tested without a network.
const INSTALL_KEY = /^[0-9a-f]{32,64}$/i;
const reply = (status, body) => ({ status, body });

/** @param {{method: string, body: unknown, installKey?: string|null, entitlement?: string|null, allowances: ReturnType<typeof import("./allowances.mjs").createAllowances>, paywallOn?: boolean}} request */
export async function handleAccount({ method, body, installKey = null, entitlement = null, allowances, paywallOn = true }) {
  if (method !== "GET" && method !== "POST") return reply(405, { error: "method_not_allowed", message: "Use GET or POST." });
  if (typeof installKey !== "string" || !INSTALL_KEY.test(installKey)) return reply(401, { error: "install_key_required", message: "This copy of SellPilot could not be verified. Update the app and try again." });
  const key = installKey.toLowerCase();
  try {
    if (method === "GET") return reply(200, { paywall: paywallOn, allowance: await allowances.status({ installKey: key, entitlement }) });
    const transaction = body && typeof body === "object" ? body.transaction : null;
    if (typeof transaction !== "string" || !transaction) return reply(400, { error: "invalid_request", message: "Send the signed transaction." });
    const result = await allowances.redeem({ installKey: key, transaction, entitlement });
    if (!result.ok) return reply(422, { error: "invalid_transaction", message: "That purchase could not be verified.", allowance: result.allowance });
    return reply(200, { added: result.added, allowance: result.allowance });
  } catch {
    return reply(503, { error: "unavailable", message: "Purchases are unavailable right now. Try again shortly; nothing has been lost." });
  }
}
