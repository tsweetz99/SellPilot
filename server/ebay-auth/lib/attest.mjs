// Apple App Attest: proof that a request comes from a genuine copy of SellPilot on a real Apple device.
// The app registers a hardware-backed key once ("attestation": Apple vouches for the key and the app), then signs each request
// with it ("assertion"). Checks follow Apple's "Validating apps that connect to your server". Pure logic with an injectable
// store and clock so it can be tested without a network or a device.
import { createHash, randomBytes, verify, X509Certificate, createPublicKey } from "node:crypto";
import { decodeCbor } from "./cbor.mjs";

/** Apple App Attestation Root CA (SHA-256 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32). */
export const APPLE_APP_ATTEST_ROOT_CA = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----
`;

export const APP_ID = "2XC3GTJ8B8.com.tidewrightstudios.sellpilot";
const NONCE_OID = Buffer.from("06092a864886f763640802", "hex");        // 1.2.840.113635.100.8.2 (9 bytes of identifier)
const NONCE_SHAPE = Buffer.from("3024a1220420", "hex");                // SEQUENCE { [1] { OCTET STRING(32) } }
const AAGUID_PRODUCTION = Buffer.concat([Buffer.from("appattest"), Buffer.alloc(7)]);
const AAGUID_DEVELOPMENT = Buffer.from("appattestdevelop");
const CHALLENGE_LIFETIME_MS = 10 * 60_000;

const sha256 = (...parts) => { const h = createHash("sha256"); parts.forEach((p) => h.update(p)); return h.digest(); };
const invalid = (reason) => Object.assign(new Error(reason), { reason });
const decodeBase64 = (value, what) => {
  if (typeof value !== "string" || value.length === 0 || value.length > 20_000 || !/^[A-Za-z0-9+/_-]+={0,2}$/.test(value)) throw invalid(`${what} is not base64`);
  return Buffer.from(value, "base64");
};

/** Splits authenticator data into its parts. */
export function parseAuthData(authData) {
  if (!Buffer.isBuffer(authData) || authData.length < 37) throw invalid("authenticator data too short");
  const parsed = { rpIdHash: authData.subarray(0, 32), flags: authData[32], counter: authData.readUInt32BE(33) };
  if (authData.length >= 55) {
    parsed.aaguid = authData.subarray(37, 53);
    const idLength = authData.readUInt16BE(53);
    if (authData.length < 55 + idLength) throw invalid("credential id runs past the data");
    parsed.credentialId = authData.subarray(55, 55 + idLength);
  }
  return parsed;
}

function chainTo(roots, leaf, intermediates, at) {
  const certificates = [leaf, ...intermediates];
  const trusted = roots.map((pem) => new X509Certificate(pem));
  for (let i = 0; i < certificates.length; i++) {
    const certificate = certificates[i];
    if (at < Date.parse(certificate.validFrom) || at > Date.parse(certificate.validTo)) throw invalid("certificate not valid now");
    const issuer = certificates[i + 1];
    if (issuer) { if (!certificate.verify(issuer.publicKey)) throw invalid("broken certificate chain"); continue; }
    // The last certificate must be issued by a root we trust.
    if (!trusted.some((root) => certificate.verify(root.publicKey) && certificate.checkIssued(root))) throw invalid("not issued by Apple");
  }
}

/**
 * Checks an attestation. Returns {publicKeyPem, environment}; throws an Error with a `reason` if anything is off.
 * @param {{attestation: string, challenge: string, keyId: string, appId?: string, allowDevelopment?: boolean, roots?: string[], now?: number}} input
 */
export function verifyAttestation({ attestation, challenge, keyId, appId = APP_ID, allowDevelopment = false, roots = [APPLE_APP_ATTEST_ROOT_CA], now = Date.now() }) {
  let object;
  try { object = decodeCbor(decodeBase64(attestation, "attestation")); } catch (error) { throw invalid(error.reason ?? "attestation is not readable"); }
  if (object?.fmt !== "apple-appattest") throw invalid("unexpected attestation format");
  const x5c = object.attStmt?.x5c;
  if (!Array.isArray(x5c) || x5c.length < 2 || !x5c.every(Buffer.isBuffer)) throw invalid("certificate chain missing");
  let certificates;
  try { certificates = x5c.map((der) => new X509Certificate(der)); } catch { throw invalid("unreadable certificate"); }
  const [credential, ...intermediates] = certificates;
  try { chainTo(roots, credential, intermediates, now); } catch (error) { throw invalid(error.reason ?? "certificate check failed"); }

  const authData = object.authData;
  const auth = parseAuthData(authData);
  const nonce = sha256(authData, sha256(Buffer.from(String(challenge))));
  const at = credential.raw.indexOf(NONCE_OID);
  const shape = at < 0 ? -1 : credential.raw.indexOf(NONCE_SHAPE, at);
  if (shape < 0 || !credential.raw.subarray(shape + NONCE_SHAPE.length, shape + NONCE_SHAPE.length + 32).equals(nonce)) throw invalid("challenge does not match");

  const keyBytes = decodeBase64(keyId, "key id");
  const point = credential.publicKey.export({ type: "spki", format: "der" }).subarray(-65);
  if (point.length !== 65 || point[0] !== 4 || !sha256(point).equals(keyBytes)) throw invalid("key id does not match the certificate");

  if (!auth.rpIdHash.equals(sha256(Buffer.from(appId)))) throw invalid("attestation is for a different app");
  if (auth.counter !== 0) throw invalid("counter is not zero");
  const production = auth.aaguid?.equals(AAGUID_PRODUCTION), development = auth.aaguid?.equals(AAGUID_DEVELOPMENT);
  if (!production && !(allowDevelopment && development)) throw invalid("not a production attestation");
  if (!auth.credentialId?.equals(keyBytes)) throw invalid("credential id does not match the key id");
  return { publicKeyPem: credential.publicKey.export({ type: "spki", format: "pem" }), environment: production ? "production" : "development" };
}

/**
 * Checks one signed request. `clientData` is exactly what the app hashed (the request body). Returns the new counter; throws on failure.
 * @param {{assertion: string, clientData: Buffer|string, publicKeyPem: string, storedCounter: number, appId?: string}} input
 */
export function verifyAssertion({ assertion, clientData, publicKeyPem, storedCounter, appId = APP_ID }) {
  let object;
  try { object = decodeCbor(decodeBase64(assertion, "assertion")); } catch (error) { throw invalid(error.reason ?? "assertion is not readable"); }
  const { signature, authenticatorData } = object ?? {};
  if (!Buffer.isBuffer(signature) || !Buffer.isBuffer(authenticatorData)) throw invalid("assertion is incomplete");
  const auth = parseAuthData(authenticatorData);
  if (!auth.rpIdHash.equals(sha256(Buffer.from(appId)))) throw invalid("assertion is for a different app");
  // Apple's recipe: nonce = SHA-256(authenticatorData || SHA-256(request)); the key's ECDSA signature (which hashes again) is over that nonce.
  const nonce = sha256(Buffer.concat([authenticatorData, sha256(Buffer.from(clientData ?? ""))]));
  let good = false;
  try { good = verify("sha256", nonce, createPublicKey(publicKeyPem), signature); } catch { good = false; }
  if (!good) throw invalid("signature does not match");
  if (!(auth.counter > storedCounter)) throw invalid("counter did not increase (replayed request)");
  return auth.counter;
}

/**
 * Keeps the registered keys and the one-time challenges in a key-value store.
 * @param {{get(key: string): Promise<any>, set(key: string, value: any): Promise<void>}} store
 */
export function createAttest(store, { appId = APP_ID, allowDevelopment = false, now = Date.now, roots = [APPLE_APP_ATTEST_ROOT_CA] } = {}) {
  const keyName = (keyId) => `attest-key:${sha256(decodeBase64(keyId, "key id")).toString("hex")}`;
  return {
    /** A fresh single-use challenge for one registration. */
    async challenge() {
      const value = randomBytes(24).toString("base64url");
      await store.set(`attest-challenge:${value}`, { expires: now() + CHALLENGE_LIFETIME_MS, used: false });
      return value;
    },

    /** Registers a device key for an install code. Resolves {ok: true} or {ok: false, reason}. */
    async register({ installKey, keyId, attestation, challenge }) {
      try {
        if (typeof challenge !== "string" || challenge.length > 100) throw invalid("challenge missing");
        const record = await store.get(`attest-challenge:${challenge}`);
        if (!record || record.used || now() > record.expires) throw invalid("challenge is unknown, used or expired");
        await store.set(`attest-challenge:${challenge}`, { ...record, used: true });
        const name = keyName(keyId);
        if (await store.get(name)) throw invalid("key already registered");
        const { publicKeyPem, environment } = verifyAttestation({ attestation, challenge, keyId, appId, allowDevelopment, roots, now: now() });
        await store.set(name, { publicKeyPem, counter: 0, installKey, environment, registered: now() });
        return { ok: true, environment };
      } catch (error) { return { ok: false, reason: error.reason ?? "attestation failed" }; }
    },

    /** Judges one request: "valid", "missing" (no proof sent) or "invalid" (proof sent but wrong), with a reason. */
    async check({ installKey, keyId, assertion, body }) {
      if (!keyId && !assertion) return { state: "missing" };
      try {
        if (!keyId || !assertion) throw invalid("proof is incomplete");
        const name = keyName(keyId);
        const record = await store.get(name);
        if (!record) throw invalid("unknown key");
        if (record.installKey !== installKey) throw invalid("key belongs to a different install");
        const counter = verifyAssertion({ assertion, clientData: body ?? "", publicKeyPem: record.publicKeyPem, storedCounter: record.counter, appId });
        await store.set(name, { ...record, counter });
        return { state: "valid" };
      } catch (error) { return { state: "invalid", reason: error.reason ?? "assertion failed" }; }
    },
  };
}
