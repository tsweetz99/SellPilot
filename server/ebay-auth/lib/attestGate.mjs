// Decides what to do with a request given what App Attest says about it.
// Soft by default: a request with no proof is let through (so apps released before App Attest keep working) and counted in the log.
// With AI_REQUIRE_ATTEST=true, only requests proven to come from a registered device get through.

const MISSING = "This version of SellPilot needs an update. Open the App Store and update SellPilot, then try again.";
const INVALID = "This copy of SellPilot could not be verified. Close and reopen the app and try again.";

/**
 * @param {{check: Function}|null} attest   the attest service, or null when App Attest is switched off
 * @param {{required?: boolean, installKey: string, keyId?: string|null, assertion?: string|null, body?: string|Buffer}} request
 * Resolves {ok, state, reason?, response?}. When !ok, `response` is {status, body} for the caller to return.
 */
export async function attestVerdict(attest, { required = false, installKey, keyId = null, assertion = null, body = "" }) {
  if (!attest) return { ok: true, state: "off" };
  let result;
  try { result = await attest.check({ installKey, keyId, assertion, body }); } catch { result = { state: "invalid", reason: "check failed" }; }
  if (result.state === "valid") return { ok: true, state: "valid" };
  if (!required) return { ok: true, state: result.state, reason: result.reason };
  const missing = result.state === "missing";
  return { ok: false, state: result.state, reason: result.reason, response: { status: 401, body: { error: missing ? "attest_required" : "attest_invalid", message: missing ? MISSING : INVALID } } };
}
