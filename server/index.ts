import http from "node:http";
import { pathToFileURL } from "node:url";
import { loadArtifact } from "./artifacts.ts";
import { publicClientFor } from "./chain.ts";
import { configFromEnv, type ServerConfig } from "./config.ts";
import { underwriteAndDeliver } from "./underwrite.ts";

const stakeAbi = loadArtifact("StakeAndAdvance").abi as never;

// Permissive CORS so a browser frontend (e.g. Next.js on :3000) can call these endpoints.
const CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "content-type",
};

function send(res: http.ServerResponse, code: number, body: unknown): void {
  const payload = JSON.stringify(body, (_k, v) => (typeof v === "bigint" ? v.toString() : v));
  res.writeHead(code, { "content-type": "application/json", ...CORS_HEADERS });
  res.end(payload);
}

async function readJson(req: http.IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  return raw ? (JSON.parse(raw) as Record<string, unknown>) : {};
}

async function readPoolState(config: ServerConfig) {
  const publicClient = publicClientFor(config.chainId, config.rpcUrl);
  const s = (await publicClient.readContract({
    address: config.contract,
    abi: stakeAbi,
    functionName: "poolState",
  })) as readonly [bigint, bigint, bigint, bigint, bigint, bigint, number, number, number, boolean];
  return {
    totalAssets: s[0].toString(),
    cash: s[1].toString(),
    outstandingPrincipal: s[2].toString(),
    totalShares: s[3].toString(),
    navPerShare1e18: s[4].toString(),
    creditCap: s[5].toString(),
    capExpiry: s[6].toString(),
    interestRateBps: Number(s[7]),
    dueAt: s[8].toString(),
    defaulted: s[9],
  };
}

export function buildHandler(config: ServerConfig) {
  return async (req: http.IncomingMessage, res: http.ServerResponse): Promise<void> => {
    try {
      const url = req.url ?? "/";

      if (req.method === "OPTIONS") {
        res.writeHead(204, CORS_HEADERS);
        res.end();
        return;
      }

      if (req.method === "GET" && url === "/health") {
        return send(res, 200, {
          ok: true,
          chainId: config.chainId,
          contract: config.contract,
          confidentialAi: config.confidentialAiEndpoint ? "cloud" : "dev",
        });
      }

      // Read the live pool snapshot (NAV, assets, cash, debt, cap, rate) straight from the contract.
      if (req.method === "GET" && url === "/pool/state") {
        return send(res, 200, await readPoolState(config));
      }

      // Run confidential underwriting and deliver the signed credit cap + interest rate on-chain.
      if (req.method === "POST" && url === "/cre/underwrite") {
        const body = await readJson(req);
        const financials = (body.financials ?? body) as Record<string, unknown>;
        if (!financials.vendor) return send(res, 400, { error: "missing financials.vendor" });
        const result = await underwriteAndDeliver(config, financials as never);
        return send(res, 200, result);
      }

      return send(res, 404, { error: "not found", path: url });
    } catch (err) {
      return send(res, 500, { error: err instanceof Error ? err.message : String(err) });
    }
  };
}

export async function startServer(
  config: ServerConfig,
): Promise<{ url: string; port: number; close: () => Promise<void> }> {
  const server = http.createServer(buildHandler(config));
  await new Promise<void>((resolve) => server.listen(config.port, resolve));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : config.port;
  return {
    url: `http://127.0.0.1:${port}`,
    port,
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

// Run standalone: `npm run server` (loads ./.env, listens on PORT).
if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  try {
    process.loadEnvFile();
  } catch {
    // no .env file; rely on process env
  }
  const config = configFromEnv();
  startServer(config).then(({ url }) => {
    console.log(`[server] listening on ${url}`);
    console.log(`[server] contract=${config.contract} chainId=${config.chainId}`);
  });
}
