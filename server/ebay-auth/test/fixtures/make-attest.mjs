// Makes the throwaway App Attest test vector: a certificate chain shaped like Apple's (root -> intermediate -> credential certificate
// carrying the nonce extension 1.2.840.113635.100.8.2) for a fixed device key, challenge and a few variants of the authenticator data.
// These keys sign nothing real. Run once with `node make-attest.mjs` and commit the output; the tests never need openssl.
import { execFileSync } from "node:child_process";
import { createHash, createPublicKey } from "node:crypto";
import { writeFileSync, readFileSync, rmSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const here = new URL(".", import.meta.url).pathname;
const dir = mkdtempSync(join(tmpdir(), "attest-"));
const run = (...args) => execFileSync("openssl", args, { stdio: ["ignore", "pipe", "pipe"] });
const sha256 = (...parts) => { const h = createHash("sha256"); parts.forEach((p) => h.update(p)); return h.digest(); };
const out = (name, data) => writeFileSync(join(here, name), data);

const APP_ID = "2XC3GTJ8B8.com.tidewrightstudios.sellpilot";
const OTHER_APP_ID = "ZZZZZZZZZZ.com.example.other";
const CHALLENGE = "test-challenge-0123456789";

run("ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", join(dir, "root.key"));
run("req", "-new", "-x509", "-key", join(dir, "root.key"), "-sha384", "-days", "36500", "-subj", "/CN=Test App Attestation Root CA/O=SellPilot Tests", "-out", join(dir, "root.pem"));
run("ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", join(dir, "inter.key"));
run("req", "-new", "-key", join(dir, "inter.key"), "-subj", "/CN=Test App Attestation CA 1/O=SellPilot Tests", "-out", join(dir, "inter.csr"));
writeFileSync(join(dir, "inter.cnf"), "basicConstraints=critical,CA:TRUE\n");
run("x509", "-req", "-in", join(dir, "inter.csr"), "-CA", join(dir, "root.pem"), "-CAkey", join(dir, "root.key"), "-CAcreateserial", "-sha384", "-days", "36500", "-extfile", join(dir, "inter.cnf"), "-out", join(dir, "inter.pem"));
run("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", join(dir, "leaf.key"));

const leafKey = readFileSync(join(dir, "leaf.key"), "utf8");
const publicKey = createPublicKey(leafKey);
const point = publicKey.export({ type: "spki", format: "der" }).subarray(-65);
const keyId = sha256(point);

const authData = ({ appId = APP_ID, counter = 0, aaguid = Buffer.concat([Buffer.from("appattest"), Buffer.alloc(7)]) } = {}) => {
  const head = Buffer.concat([sha256(Buffer.from(appId)), Buffer.from([0x40]), Buffer.alloc(4)]);
  head.writeUInt32BE(counter, 33);
  const idLength = Buffer.alloc(2); idLength.writeUInt16BE(keyId.length);
  return Buffer.concat([head, aaguid, idLength, keyId]);
};
const variants = {
  good: authData(),
  development: authData({ aaguid: Buffer.from("appattestdevelop") }),
  counter: authData({ counter: 1 }),
  otherApp: authData({ appId: OTHER_APP_ID }),
};

const manifest = { appId: APP_ID, otherAppId: OTHER_APP_ID, challenge: CHALLENGE, keyId: keyId.toString("base64"), variants: {} };
for (const [name, data] of Object.entries(variants)) {
  const nonce = sha256(data, sha256(Buffer.from(CHALLENGE)));
  run("req", "-new", "-key", join(dir, "leaf.key"), "-subj", `/CN=Test credential ${name}/O=SellPilot Tests`, "-out", join(dir, `${name}.csr`));
  writeFileSync(join(dir, `${name}.cnf`), `basicConstraints=critical,CA:FALSE\n1.2.840.113635.100.8.2=DER:3024A1220420${nonce.toString("hex")}\n`);
  run("x509", "-req", "-in", join(dir, `${name}.csr`), "-CA", join(dir, "inter.pem"), "-CAkey", join(dir, "inter.key"), "-CAcreateserial", "-sha256", "-days", "36500", "-extfile", join(dir, `${name}.cnf`), "-out", join(dir, `${name}.pem`));
  const cert = readFileSync(join(dir, `${name}.pem`), "utf8");
  manifest.variants[name] = { authData: data.toString("base64"), credentialPem: cert };
}
out("attest-root.pem", readFileSync(join(dir, "root.pem")));
out("attest-intermediate.pem", readFileSync(join(dir, "inter.pem")));
out("attest-device.key.pem", leafKey);
out("attest-vector.json", JSON.stringify(manifest, null, 2));
rmSync(dir, { recursive: true, force: true });
console.log("wrote attest-root.pem, attest-intermediate.pem, attest-device.key.pem, attest-vector.json");
