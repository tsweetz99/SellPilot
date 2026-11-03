// A small CBOR reader, enough for Apple's App Attest objects (maps with text keys, byte strings, arrays, integers).
// Reading only: the server never writes CBOR. Anything unexpected throws, which callers treat as "not valid".

const fail = (message) => { throw Object.assign(new Error(message), { code: "invalid_cbor" }); };

/** Decodes one CBOR value from `buffer` and requires that nothing follows it. */
export function decodeCbor(buffer) {
  const bytes = Buffer.from(buffer);
  let offset = 0;
  const need = (n) => { if (offset + n > bytes.length) fail("CBOR ended early"); };
  // The number that follows the type: an integer's value, or the size of what comes next.
  const argument = (info) => {
    if (info < 24) return info;
    const width = { 24: 1, 25: 2, 26: 4, 27: 8 }[info];
    if (!width) fail("Unsupported CBOR length");
    need(width);
    const value = width === 8 ? Number(bytes.readBigUInt64BE(offset)) : bytes.readUIntBE(offset, width);
    offset += width;
    if (!Number.isSafeInteger(value)) fail("CBOR number too large");
    return value;
  };
  // A size can never exceed what is left to read, which stops a tiny message from asking for a huge allocation.
  const length = (info) => { const n = argument(info); if (n > bytes.length * 8) fail("CBOR length too large"); return n; };
  const item = (depth) => {
    if (depth > 16) fail("CBOR nested too deeply");
    need(1);
    const head = bytes[offset++];
    const major = head >> 5, info = head & 31;
    switch (major) {
      case 0: return argument(info);
      case 1: return -1 - argument(info);
      case 2: { const n = length(info); need(n); const out = bytes.subarray(offset, offset + n); offset += n; return Buffer.from(out); }
      case 3: { const n = length(info); need(n); const out = bytes.toString("utf8", offset, offset + n); offset += n; return out; }
      case 4: { const n = length(info); const out = []; for (let i = 0; i < n; i++) out.push(item(depth + 1)); return out; }
      case 5: { const n = length(info); const out = {}; for (let i = 0; i < n; i++) { const key = item(depth + 1); if (typeof key !== "string") fail("Only text map keys are supported"); out[key] = item(depth + 1); } return out; }
      case 7: if (info === 20) return false; if (info === 21) return true; if (info === 22) return null; return fail("Unsupported CBOR simple value");
      default: return fail("Unsupported CBOR type");
    }
  };
  const value = item(0);
  if (offset !== bytes.length) fail("Extra bytes after CBOR value");
  return value;
}
