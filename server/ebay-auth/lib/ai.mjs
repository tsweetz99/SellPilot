// The SellPilot AI service: identifies an item from photos, or pulls facts from a description, by calling Claude on the studio's
// account so people do not need their own key. The prompts and answer shapes are fixed here (see aiPrompts.mjs); callers send only
// photos or text. Pure logic with an injectable fetch, so it can be tested without a network.
import { createHash } from "node:crypto";
import { IDENTIFY_SYSTEM, IDENTIFY_SCHEMA, IDENTIFY_TOOL, FACTS_SYSTEM, FACTS_SCHEMA, FACTS_TOOL } from "./aiPrompts.mjs";

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const INSTALL_KEY = /^[0-9a-f]{32,64}$/i;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
export const LIMITS = { photos: 6, photoBytes: 1_200_000, totalBytes: 3_500_000, description: 4000 };
/** What each task takes from the allowances. An identification (vision) costs more than a text lookup. */
export const COST = { identify: 3, facts: 1 };

const reply = (status, body, retryAfterSeconds) => ({ status, body, ...(retryAfterSeconds ? { retryAfterSeconds } : {}) });
const fail = (status, error, message, retryAfterSeconds) => reply(status, { error, message }, retryAfterSeconds);
const PAUSED = "AI identification is paused right now. You can still enter the item's details yourself.";

function decodedSize(data) {
  return Math.floor((data.length * 3) / 4) - (data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0);
}

/** Checks the request and returns {task, ...} or a ready-made failure. */
function validate(body) {
  if (!body || typeof body !== "object") return { failure: fail(400, "invalid_request", "Send a JSON object.") };
  if (body.task === "identify") {
    const photos = body.photos;
    if (!Array.isArray(photos) || photos.length < 1 || photos.length > LIMITS.photos) return { failure: fail(400, "invalid_request", `Send between 1 and ${LIMITS.photos} photos.`) };
    let total = 0;
    for (const photo of photos) {
      const data = photo?.data;
      if (typeof data !== "string" || !BASE64.test(data)) return { failure: fail(400, "invalid_request", "Each photo needs base64 data.") };
      const bytes = decodedSize(data);
      if (bytes > LIMITS.photoBytes) return { failure: fail(413, "photo_too_large", "A photo is too large to analyze. Try a smaller one.") };
      total += bytes;
      const head = Buffer.from(data.slice(0, 8), "base64");
      if (!(head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff)) return { failure: fail(400, "invalid_request", "Photos must be JPEG images.") };
    }
    if (total > LIMITS.totalBytes) return { failure: fail(413, "photos_too_large", "The photos are too large to analyze together. Remove a few and try again.") };
    return { task: "identify", photos: photos.map((p) => p.data) };
  }
  if (body.task === "facts") {
    const description = typeof body.description === "string" ? body.description.trim() : "";
    if (!description || description.length > LIMITS.description) return { failure: fail(400, "invalid_request", `Send a description of up to ${LIMITS.description} characters.`) };
    return { task: "facts", description };
  }
  return { failure: fail(400, "invalid_request", "task must be identify or facts.") };
}

function upstreamBody(request, env) {
  if (request.task === "identify") {
    const content = [];
    request.photos.forEach((data, index) => {
      content.push({ type: "text", text: `Photo ${index + 1} of ${request.photos.length}${index === 0 ? " (cover photo)" : ""}` });
      content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data } });
    });
    content.push({ type: "text", text: `Identify the item these photos show and call ${IDENTIFY_TOOL}.` });
    return {
      model: env.AI_MODEL_IDENTIFY || "claude-sonnet-5-5", max_tokens: 1500, system: IDENTIFY_SYSTEM,
      tools: [{ name: IDENTIFY_TOOL, description: "Report the identification of the item in the photos.", input_schema: IDENTIFY_SCHEMA }],
      tool_choice: { type: "auto" }, messages: [{ role: "user", content }],
    };
  }
  return {
    model: env.AI_MODEL_FACTS || "claude-haiku-4-5-20251001", max_tokens: 800, system: FACTS_SYSTEM,
    tools: [{ name: FACTS_TOOL, description: "Report facts about the item.", input_schema: FACTS_SCHEMA }], tool_choice: { type: "auto" },
    messages: [{ role: "user", content: `The seller's description of the item:\n${request.description}\n\nCall ${FACTS_TOOL} with the facts the description supports.` }],
  };
}

/**
 * @param {{method: string, body: unknown, env: Record<string, string|undefined>, fetchImpl?: typeof fetch,
 *          installKey?: string|null, address?: string|null,
 *          budget?: {spend(args: {installKey: string, addressHash: string, units: number}): Promise<{allowed: boolean, retryAfterSeconds: number, scope?: string}>},
 *          log?: (line: string) => void}} request
 */
export async function handleAI({ method, body, env, fetchImpl = fetch, installKey = null, address = null, budget = null, log = () => {} }) {
  if (method !== "POST") return fail(405, "method_not_allowed", "Use POST.");
  // Off unless the studio switches it on: this is the spending switch.
  if (env.AI_ENABLED !== "true") return fail(503, "ai_unavailable", PAUSED);
  if (!env.ANTHROPIC_API_KEY) { log(JSON.stringify({ event: "ai_not_configured" })); return fail(503, "ai_unavailable", PAUSED); }
  if (typeof installKey !== "string" || !INSTALL_KEY.test(installKey)) return fail(401, "install_key_required", "This copy of SellPilot could not be verified. Update the app and try again.");
  const key = installKey.toLowerCase();
  if ((env.AI_BLOCKED_INSTALL_KEYS ?? "").split(",").map((k) => k.trim().toLowerCase()).includes(key)) return fail(403, "forbidden", "This copy of SellPilot can't use the AI service.");

  const request = validate(body);
  if (request.failure) return request.failure;

  if (!budget) return fail(503, "limiter_unavailable", PAUSED);
  const addressHash = createHash("sha256").update(String(address ?? "unknown")).digest("hex").slice(0, 16);
  try {
    const verdict = await budget.spend({ installKey: key, addressHash, units: COST[request.task] });
    if (!verdict.allowed) {
      const message = verdict.scope === "install" ? "You've reached today's limit for AI identification. Try again tomorrow, or enter the details yourself."
        : verdict.scope === "address" ? "Too many requests from this network. Try again in a little while."
        : "AI identification is very busy right now. Try again later, or enter the details yourself.";
      return fail(verdict.scope === "global" ? 503 : 429, verdict.scope === "global" ? "ai_busy" : "rate_limited", message, verdict.retryAfterSeconds);
    }
  } catch {
    // Failing closed: if the allowances cannot be read, nobody spends money until they can.
    return fail(503, "limiter_unavailable", PAUSED);
  }

  const started = Date.now();
  const outcome = async () => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), Number(env.AI_TIMEOUT_MS) || 45_000);
    let upstream;
    try {
      upstream = await fetchImpl(ANTHROPIC_URL, {
        method: "POST", signal: controller.signal,
        headers: { "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify(upstreamBody(request, env)),
      });
    } catch (error) {
      return error?.name === "AbortError" ? fail(504, "ai_timeout", "Identification took too long. Try again, or use fewer photos.") : fail(502, "upstream_unreachable", "The AI service could not be reached. Try again shortly.");
    } finally { clearTimeout(timer); }

    if (!upstream.ok) {
      if (upstream.status === 400 || upstream.status === 413 || upstream.status === 422) return fail(422, "upstream_rejected", request.task === "identify" ? "The photos could not be processed. Try clearer or fewer photos." : "The description could not be processed.");
      // A rejected studio key is the studio's problem, not the caller's: say nothing about it and ask for a retry later.
      if (upstream.status === 401 || upstream.status === 403) { log(JSON.stringify({ event: "ai_key_rejected" })); return fail(503, "ai_unavailable", PAUSED); }
      if (upstream.status === 429 || upstream.status === 529 || upstream.status === 503) return fail(503, "ai_busy", "AI identification is busy right now. Try again in a moment.", 30);
      return fail(502, "upstream_error", "The AI service had a problem. Try again shortly.");
    }
    let json;
    try { json = await upstream.json(); } catch { return fail(502, "upstream_invalid", "The AI service returned an unreadable answer."); }
    const wanted = request.task === "identify" ? IDENTIFY_TOOL : FACTS_TOOL;
    const tool = (json.content ?? []).find((block) => block?.type === "tool_use" && block.name === wanted);
    if (!tool) return fail(502, "upstream_invalid", "The AI service did not return a usable answer. Try again.");
    // Only the answer, in the same shape the app already reads. Nothing else from the upstream reply is relayed.
    return reply(200, { content: [{ type: "tool_use", name: tool.name, input: tool.input }] });
  };

  const result = await outcome();
  // Counts only: never the photos, the description or the answer.
  log(JSON.stringify({ event: "ai", task: request.task, status: result.status, photos: request.photos?.length, ms: Date.now() - started }));
  return result;
}
