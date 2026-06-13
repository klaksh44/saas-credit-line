import http from "node:http";
import { pathToFileURL } from "node:url";
import { configFromEnv, type ServerConfig } from "./config.ts";
import { underwriteAndDeliver } from "./underwrite.ts";
import { signPersonhoodVoucher } from "./voucher.ts";
import { verifyWorldId } from "./worldid.ts";

function send(res: http.ServerResponse, code: number, body: unknown): void {
  const payload = JSON.stringify(body, (_k, v) => (typeof v === "bigint" ? v.toString() : v));
  res.writeHead(code, { "content-type": "application/json" });
  res.end(payload);
}

async function readJson(req: http.IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  return raw ? (JSON.parse(raw) as Record<string, unknown>) : {};
}

export function buildHandler(config: ServerConfig) {
  return async (req: http.IncomingMessage, res: http.ServerResponse): Promise<void> => {
    try {
      const url = req.url ?? "/";

      if (req.method === "GET" && url === "/health") {
        return send(res, 200, {
          ok: true,
          worldIdMode: config.worldIdMode,
          chainId: config.chainId,
          contract: config.contract,
          confidentialAi: config.confidentialAiEndpoint ? "cloud" : "dev",
        });
      }

      // World ID V4 server-side signRequest. Dev mode returns a stub rp_context;
      // cloud mode would sign with the Developer Portal app key.
      if (req.method === "POST" && url === "/worldid/sign") {
        const body = await readJson(req);
        if (config.worldIdMode === "dev") {
          return send(res, 200, {
            action: config.worldAction,
            rp_context: { rp_id: config.worldAppId ?? "app_dev", nonce: `${Date.now()}`, dev: true },
          });
        }
        return send(res, 501, {
          error: "cloud signRequest not configured; provide app signing key (see docs)",
        });
      }

      // Validate personhood and issue an EIP-712 voucher the contract accepts.
      if (req.method === "POST" && url === "/worldid/verify") {
        const body = (await readJson(req)) as {
          user?: `0x${string}`;
          nullifier_hash?: `0x${string}`;
          id?: string;
          proof?: Record<string, unknown>;
          signal?: string;
        };
        if (!body.user) return send(res, 400, { error: "missing `user`" });

        const result = await verifyWorldId(config, { user: body.user, ...body });
        if (!result.ok) {
          return send(res, 401, { error: "world id verification failed", detail: result.detail });
        }

        const deadline = BigInt(Math.floor(Date.now() / 1000) + config.voucherTtlSeconds);
        const signature = await signPersonhoodVoucher({
          signerKey: config.worldIdSignerKey,
          chainId: config.chainId,
          verifyingContract: config.contract,
          user: body.user,
          nullifierHash: result.nullifierHash,
          deadline,
        });

        return send(res, 200, {
          user: body.user,
          nullifierHash: result.nullifierHash,
          deadline: deadline.toString(),
          signature,
          mode: result.mode,
        });
      }

      // Run confidential underwriting and deliver the signed credit cap on-chain.
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
    console.log(`[server] listening on ${url}  (worldIdMode=${config.worldIdMode})`);
    console.log(`[server] contract=${config.contract} chainId=${config.chainId}`);
  });
}
