// The App Attest registration requests: "give me a challenge" and "here is my device key's attestation". Pure logic, so it can be tested.
const INSTALL_KEY = /^[0-9a-f]{32,64}$/i;
const reply = (status, body) => ({ status, body });

/**
 * @param {{method: string, body: unknown, installKey?: string|null, attest: ReturnType<typeof import("./attest.mjs").createAttest>|null,
 *          limiter?: {check(key: string): Promise<{allowed: boolean, retryAfterSeconds: number}>}, address?: string, log?: (line: string) => void}} request
 */
export async function handleAttest({ method, body, installKey = null, attest, limiter = null, address = "unknown", log = () => {} }) {
  if (method !== "GET" && method !== "POST") return reply(405, { error: "method_not_allowed", message: "Use GET or POST." });
  if (!attest) return reply(503, { error: "attest_unavailable", message: "Device verification is not switched on." });
  if (typeof installKey !== "string" || !INSTALL_KEY.test(installKey)) return reply(401, { error: "install_key_required", message: "This copy of SellPilot could not be verified. Update the app and try again." });
  try {
    if (limiter) {
      const verdict = await limiter.check(`attest:${address}`);
      if (!verdict.allowed) return { ...reply(429, { error: "rate_limited", message: "Too many attempts. Try again in a little while." }), retryAfterSeconds: verdict.retryAfterSeconds };
    }
    if (method === "GET") return reply(200, { challenge: await attest.challenge() });
    const { keyId, attestation, challenge } = body && typeof body === "object" ? body : {};
    if (typeof keyId !== "string" || typeof attestation !== "string" || typeof challenge !== "string") return reply(400, { error: "invalid_request", message: "Send keyId, attestation and challenge." });
    const result = await attest.register({ installKey: installKey.toLowerCase(), keyId, attestation, challenge });
    if (!result.ok) log(JSON.stringify({ event: "attest_rejected", reason: result.reason }));   // our own check names, never the proof
    return result.ok ? reply(200, { ok: true }) : reply(422, { error: "attestation_rejected", message: "This device could not be verified.", reason: result.reason });
  } catch (error) {
    log(JSON.stringify({ event: "attest_error", error: String(error?.message ?? error).slice(0, 200) }));
    return reply(503, { error: "unavailable", message: "Device verification is unavailable right now. Try again shortly." });
  }
}
