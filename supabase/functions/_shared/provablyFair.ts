/**
 * 🎰 PROVABLY FAIR CRASH ALGORITHM (HMAC-SHA256)
 * 
 * Formula:
 * 1. hash = HMAC_SHA256(server_seed, client_seed + ":" + nonce)
 * 2. v = first 13 hex characters of hash (52 bits)
 * 3. house_edge = 0.05 (5%)
 * 4. multiplier = max(1, floor(0.95 / (1 - (v / 2^52)) * 100) / 100)
 */

export async function deriveCrashMultiplier(
  serverSeed: string,
  clientSeed: string,
  nonce: number,
  houseEdge: number = 0.05
): Promise<number> {
  const encoder = new TextEncoder();
  const keyData = encoder.encode(serverSeed);
  const messageData = encoder.encode(`${clientSeed}:${nonce}`);

  // Import HMAC key
  const key = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );

  // Sign message
  const signature = await crypto.subtle.sign("HMAC", key, messageData);
  const hashArray = Array.from(new Uint8Array(signature));
  const hashHex = hashArray.map(b => b.toString(16).padStart(2, "0")).join("");

  // 1. Take first 13 characters (52 bits)
  const hex52 = hashHex.substring(0, 13);
  const r = parseInt(hex52, 16);

  // 2. Maximum value for 52 bits
  const max52 = Math.pow(2, 52);

  // 3. Normalized value (0 to 1)
  const v = r / max52;

  // 4. Calculate multiplier with house edge
  // Formula: crashPoint = (1 - houseEdge) / (1 - v)
  const crashPoint = (1 - houseEdge) / (1 - v);

  // Ensure minimum is 1.00 and floor to 2 decimal places
  const multiplier = Math.max(1.00, Math.floor(crashPoint * 100) / 100);

  return multiplier;
}

/**
 * Example verification snippet for players:
 * 
 * const serverSeed = "abc...";
 * const clientSeed = "xyz...";
 * const nonce = 1;
 * const result = await deriveCrashMultiplier(serverSeed, clientSeed, nonce);
 * console.log(`Crash at: ${result}x`);
 */
