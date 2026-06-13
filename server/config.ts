export type WorldIdMode = "dev" | "cloud";

export type ServerConfig = {
  port: number;
  rpcUrl: string;
  chainId: number;
  contract: `0x${string}`;
  reporterKey: `0x${string}`;
  worldIdSignerKey: `0x${string}`;
  worldIdMode: WorldIdMode;
  worldAction: string;
  worldAppId: string | undefined;
  worldVerifyUrl: string | undefined;
  voucherTtlSeconds: number;
  confidentialAiEndpoint: string | undefined;
  confidentialAiApiKey: string | undefined;
};

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var: ${name}`);
  return value;
}

function asHex(name: string): `0x${string}` {
  const value = required(name);
  if (!/^0x[0-9a-fA-F]+$/.test(value)) throw new Error(`${name} must be a 0x hex string`);
  return value as `0x${string}`;
}

export function configFromEnv(overrides: Partial<ServerConfig> = {}): ServerConfig {
  return {
    port: Number(process.env.PORT ?? 8788),
    rpcUrl: process.env.RPC_URL ?? "http://127.0.0.1:8545",
    chainId: Number(process.env.CHAIN_ID ?? 31337),
    contract: (process.env.STAKE_AND_ADVANCE_ADDRESS as `0x${string}`) ?? "0x",
    reporterKey: asHex("REPORTER_PRIVATE_KEY"),
    worldIdSignerKey: asHex("WORLD_ID_SIGNER_PRIVATE_KEY"),
    worldIdMode: (process.env.WORLD_ID_MODE as WorldIdMode) ?? "dev",
    worldAction: process.env.WORLD_ACTION ?? "claim-free-subscription",
    worldAppId: process.env.WORLD_APP_ID,
    worldVerifyUrl: process.env.WORLD_VERIFY_URL,
    voucherTtlSeconds: Number(process.env.VOUCHER_TTL_SECONDS ?? 900),
    confidentialAiEndpoint: process.env.CONFIDENTIAL_AI_ENDPOINT,
    confidentialAiApiKey: process.env.CONFIDENTIAL_AI_API_KEY,
    ...overrides,
  };
}
