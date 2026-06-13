import { encodePacked, keccak256 } from "viem";
import type { ServerConfig } from "./config.ts";

export type WorldIdVerifyResult = {
  ok: boolean;
  nullifierHash: `0x${string}`;
  mode: string;
  detail?: unknown;
};

/**
 * Resolve a World ID proof to a nullifier_hash.
 *
 * - mode="dev": no World App / QR needed (terminal-testable). The caller supplies a
 *   nullifier_hash (or a stable `id` we hash); enforcement still happens on-chain.
 * - mode="cloud": forwards the IDKit proof to the World Developer Portal cloud verify
 *   endpoint (V2/V4). Requires WORLD_APP_ID + WORLD_VERIFY_URL.
 */
export async function verifyWorldId(
  config: ServerConfig,
  body: {
    user: `0x${string}`;
    nullifier_hash?: `0x${string}`;
    id?: string;
    proof?: Record<string, unknown>;
    signal?: string;
  },
): Promise<WorldIdVerifyResult> {
  if (config.worldIdMode === "dev") {
    const nullifierHash =
      body.nullifier_hash ??
      keccak256(
        encodePacked(["address", "string", "string"], [body.user, config.worldAction, body.id ?? body.user]),
      );
    return { ok: true, nullifierHash, mode: "dev" };
  }

  // cloud mode
  if (!config.worldVerifyUrl || !config.worldAppId) {
    throw new Error("cloud mode requires WORLD_VERIFY_URL and WORLD_APP_ID");
  }
  if (!body.proof) throw new Error("cloud mode requires a `proof` from IDKit");

  const res = await fetch(config.worldVerifyUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ ...body.proof, action: config.worldAction, signal: body.signal }),
  });
  const detail = await res.json().catch(() => ({}));
  if (!res.ok) return { ok: false, nullifierHash: "0x", mode: "cloud", detail };

  const nullifierHash = (detail as { nullifier_hash?: `0x${string}` }).nullifier_hash;
  if (!nullifierHash) throw new Error("cloud verify response missing nullifier_hash");

  return { ok: true, nullifierHash, mode: "cloud", detail };
}
