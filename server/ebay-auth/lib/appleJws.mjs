// Checks a signed App Store transaction (the JWS string StoreKit gives the app) without calling Apple.
// Apple signs each transaction with a leaf certificate that chains up to Apple Root CA - G3. We pin that root, check every
// link of the chain, and then check the signature, so a made-up or edited transaction cannot pass.
import { X509Certificate, verify } from "node:crypto";

/** Apple Root CA - G3, from https://www.apple.com/certificateauthority/ (SHA-256 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79). */
export const APPLE_ROOT_CA_G3 = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----
`;

// DER for the marker extensions Apple puts on the leaf (1.2.840.113635.100.6.11.1) and the intermediate (1.2.840.113635.100.6.2.1).
const LEAF_MARKER = Buffer.from("060a2a864886f76364060b01", "hex");
const INTERMEDIATE_MARKER = Buffer.from("060a2a864886f763640602" + "01", "hex");

const decode = (part) => Buffer.from(part, "base64url");
const bad = (message) => Object.assign(new Error(message), { code: "invalid_signed_data" });

/**
 * Returns the decoded payload, or throws if the signature or the certificate chain is not Apple's.
 * @param {string} jws
 * @param {{roots?: string[], now?: number, requireMarkers?: boolean}} [options] `roots` and `requireMarkers` exist so tests can use their own chain.
 */
export function verifyAppleJws(jws, { roots = [APPLE_ROOT_CA_G3], now = Date.now(), requireMarkers = true } = {}) {
  if (typeof jws !== "string" || jws.length > 20_000) throw bad("Not a signed transaction.");
  const parts = jws.split(".");
  if (parts.length !== 3) throw bad("Not a signed transaction.");
  let header, payload;
  try { header = JSON.parse(decode(parts[0]).toString("utf8")); payload = JSON.parse(decode(parts[1]).toString("utf8")); } catch { throw bad("Not a signed transaction."); }
  if (header?.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length !== 3) throw bad("Unexpected signing method.");

  let chain;
  try { chain = header.x5c.map((cert) => new X509Certificate(Buffer.from(cert, "base64"))); } catch { throw bad("Unreadable certificate."); }
  const [leaf, intermediate, root] = chain;

  // The chain has to end at a root we trust, byte for byte.
  const trusted = roots.map((pem) => new X509Certificate(pem));
  if (!trusted.some((candidate) => candidate.raw.equals(root.raw))) throw bad("Not signed by Apple.");
  if (!root.verify(root.publicKey) || !intermediate.verify(root.publicKey) || !leaf.verify(intermediate.publicKey)) throw bad("Broken certificate chain.");

  // Certificates are judged at the moment Apple signed, so an old transaction stays valid after its certificate has expired.
  const at = Number.isFinite(payload?.signedDate) ? payload.signedDate : now;
  for (const certificate of chain) {
    if (at < Date.parse(certificate.validFrom) || at > Date.parse(certificate.validTo)) throw bad("Certificate not valid at signing time.");
  }
  if (requireMarkers && (!leaf.raw.includes(LEAF_MARKER) || !intermediate.raw.includes(INTERMEDIATE_MARKER))) throw bad("Not an App Store signing certificate.");

  const signed = Buffer.from(`${parts[0]}.${parts[1]}`);
  if (!verify("sha256", signed, { key: leaf.publicKey, dsaEncoding: "ieee-p1363" }, decode(parts[2]))) throw bad("Signature does not match.");
  return payload;
}
