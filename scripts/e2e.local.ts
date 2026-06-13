/**
 * End-to-end terminal demo on a local anvil node.
 *
 * Flow (no frontend): deploy -> Chainlink underwrite (HTTP) -> World ID verify (HTTP)
 * -> personhood-gated stake -> reused-nullifier rejection -> drawdown -> cancel/settle
 * -> dispute + time-based autoRelease. Asserts balances/states; exits non-zero on failure.
 *
 * Prereqs: `forge build` has produced contracts/out, and an anvil node is running
 * (the scripts/e2e.local.sh wrapper starts one). RPC via ANVIL_RPC (default 8545).
 */
import { formatUnits, parseUnits } from "viem";
import { loadArtifact } from "../server/artifacts.ts";
import { publicClientFor, walletClientFor } from "../server/chain.ts";
import type { ServerConfig } from "../server/config.ts";
import { startServer } from "../server/index.ts";

const RPC = process.env.ANVIL_RPC ?? "http://127.0.0.1:8545";
const CHAIN_ID = 31337;
const USDC = (n: number | bigint) => parseUnits(String(n), 6);

// Well-known anvil dev keys (public test keys — never use on a real network).
const KEY = {
  vendor: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  user: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  arbiter: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  reporter: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  worldIdSigner: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
} as const;

const ADDR = {
  vendor: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  user: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  arbiter: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
  reporter: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
  worldIdSigner: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
} as const;

let passed = 0;
function check(label: string, actual: unknown, expected: unknown): void {
  const a = typeof actual === "bigint" ? actual.toString() : String(actual);
  const e = typeof expected === "bigint" ? expected.toString() : String(expected);
  if (a !== e) throw new Error(`FAIL ${label}: got ${a}, expected ${e}`);
  passed += 1;
  console.log(`  ✓ ${label} = ${a}`);
}

async function rpc(method: string, params: unknown[]): Promise<void> {
  await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
}

async function main(): Promise<void> {
  const usdcArtifact = loadArtifact("MockUSDC");
  const stakeArtifact = loadArtifact("StakeAndAdvance");
  const stakeAbi = stakeArtifact.abi as never;
  const usdcAbi = usdcArtifact.abi as never;

  const publicClient = publicClientFor(CHAIN_ID, RPC);
  const vendor = walletClientFor(KEY.vendor, CHAIN_ID, RPC);
  const user = walletClientFor(KEY.user, CHAIN_ID, RPC);

  console.log("\n=== Deploy ===");
  // MockUSDC
  let hash = await vendor.deployContract({ abi: usdcAbi, bytecode: usdcArtifact.bytecode, args: [] });
  const usdc = (await publicClient.waitForTransactionReceipt({ hash })).contractAddress!;
  console.log(`  MockUSDC      ${usdc}`);

  // StakeAndAdvance(usdc, arbiter, keystoneForwarder=reporter, disputeWindow=600, collateralBps=6000)
  hash = await vendor.deployContract({
    abi: stakeAbi,
    bytecode: stakeArtifact.bytecode,
    args: [usdc, ADDR.arbiter, ADDR.reporter, 600, 6000],
  });
  const contract = (await publicClient.waitForTransactionReceipt({ hash })).contractAddress!;
  console.log(`  StakeAndAdvance ${contract}`);

  const writeVendor = (functionName: string, args: unknown[]) =>
    vendor.writeContract({ address: contract, abi: stakeAbi, functionName, args }).then((h) =>
      publicClient.waitForTransactionReceipt({ hash: h }),
    );
  const writeUser = (functionName: string, args: unknown[]) =>
    user.writeContract({ address: contract, abi: stakeAbi, functionName, args }).then((h) =>
      publicClient.waitForTransactionReceipt({ hash: h }),
    );
  const read = (functionName: string, args: unknown[] = []) =>
    publicClient.readContract({ address: contract, abi: stakeAbi, functionName, args });
  const usdcBal = (who: `0x${string}`) =>
    publicClient.readContract({ address: usdc, abi: usdcAbi, functionName: "balanceOf", args: [who] });

  await writeVendor("setWorldIdSigner", [ADDR.worldIdSigner]);
  console.log(`  worldIdSigner -> ${ADDR.worldIdSigner}`);

  // Fund the user and approve the contract.
  await vendor.writeContract({ address: usdc, abi: usdcAbi, functionName: "mint", args: [ADDR.user, USDC(1000)] }).then((h) => publicClient.waitForTransactionReceipt({ hash: h }));
  await user.writeContract({ address: usdc, abi: usdcAbi, functionName: "approve", args: [contract, USDC(1_000_000)] }).then((h) => publicClient.waitForTransactionReceipt({ hash: h }));
  check("user USDC funded", await usdcBal(ADDR.user), USDC(1000));

  // Backend (the API endpoints) in-process, pointing at this contract.
  const serverConfig: ServerConfig = {
    port: 0,
    rpcUrl: RPC,
    chainId: CHAIN_ID,
    contract: contract as `0x${string}`,
    reporterKey: KEY.reporter,
    worldIdSignerKey: KEY.worldIdSigner,
    worldIdMode: "dev",
    worldAction: "claim-free-subscription",
    worldAppId: undefined,
    worldVerifyUrl: undefined,
    voucherTtlSeconds: 900,
    confidentialAiEndpoint: undefined,
    confidentialAiApiKey: undefined,
  };
  const server = await startServer(serverConfig);
  const api = async (path: string, body?: unknown) => {
    const res = await fetch(`${server.url}${path}`, {
      method: body ? "POST" : "GET",
      headers: { "content-type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
    });
    const json = await res.json();
    if (!res.ok) throw new Error(`API ${path} ${res.status}: ${JSON.stringify(json)}`);
    return json;
  };

  try {
    console.log("\n=== API: /health ===");
    const health = await api("/health");
    check("health.ok", health.ok, true);
    check("health.worldIdMode", health.worldIdMode, "dev");

    console.log("\n=== Chainlink: POST /cre/underwrite (confidential AI -> signed cap on-chain) ===");
    const uw = await api("/cre/underwrite", {
      vendor: ADDR.vendor,
      currentDepositedPrincipalUsdc: 250,
      monthlyRecurringRevenueUsd: 5000,
      grossMarginBps: 8000,
      cashBalanceUsd: 50000,
      monthlyBurnUsd: 20000,
      delinquencyRateBps: 100,
    });
    console.log(`  inference: ${JSON.stringify(uw.inference)}  tx=${uw.txHash}`);
    check("attested cap", uw.cap, USDC(100));
    check("creditAllocationBps", uw.creditAllocationBps, 4000);
    check("onchain vendorCreditCap", await read("vendorCreditCap", [ADDR.vendor]), USDC(100));

    console.log("\n=== World ID: POST /worldid/verify (human #1) -> EIP-712 voucher ===");
    const v1 = await api("/worldid/verify", { user: ADDR.user, id: "human-1" });
    console.log(`  nullifier=${v1.nullifierHash}`);

    console.log("\n=== Stake (personhood-gated) ===");
    await writeUser("depositWithPersonhood", [ADDR.user, USDC(250), v1.nullifierHash, BigInt(v1.deadline), v1.signature]);
    const stake1 = (await read("stakes", [1n])) as unknown[];
    check("stake1.amount", stake1[2], USDC(250));
    check("stake1.collateral", stake1[3], USDC(150));
    check("stake1.creditAllocation", stake1[4], USDC(100));
    check("nullifier consumed", await read("usedNullifier", [v1.nullifierHash]), true);
    check("user USDC after stake", await usdcBal(ADDR.user), USDC(750));
    check("effectiveCreditLimit", await read("effectiveCreditLimit", [ADDR.vendor]), USDC(100));

    console.log("\n=== Sybil guard: same human (same nullifier) cannot stake again ===");
    let reverted = false;
    try {
      await publicClient.simulateContract({
        address: contract,
        abi: stakeAbi,
        functionName: "depositWithPersonhood",
        args: [ADDR.user, USDC(1), v1.nullifierHash, BigInt(v1.deadline), v1.signature],
        account: ADDR.user as `0x${string}`,
      });
    } catch {
      reverted = true;
    }
    check("reused nullifier reverts", reverted, true);

    console.log("\n=== Vendor drawdown ===");
    await writeVendor("drawdown", [USDC(80)]);
    check("outstanding debt", await read("currentOutstandingDebt", [ADDR.vendor]), USDC(80));
    check("vendor USDC after drawdown", await usdcBal(ADDR.vendor), USDC(80));

    console.log("\n=== User cancels (partial refund + priority obligation) ===");
    await writeUser("cancel", [1n]);
    const stake1After = (await read("stakes", [1n])) as unknown[];
    check("stake1 state Cancelled", stake1After[6], 2);
    check("user USDC after cancel", await usdcBal(ADDR.user), USDC(920)); // 750 + (250-80)
    check("vendor priorityObligation", await read("priorityObligation", [ADDR.vendor]), USDC(80));

    console.log("\n=== Dispute + time-based autoRelease (human #2) ===");
    const v2 = await api("/worldid/verify", { user: ADDR.user, id: "human-2" });
    await writeUser("depositWithPersonhood", [ADDR.user, USDC(250), v2.nullifierHash, BigInt(v2.deadline), v2.signature]);
    check("user USDC after stake2", await usdcBal(ADDR.user), USDC(670));
    await writeUser("raiseDispute", [2n]);
    const disputed = (await read("stakes", [2n])) as unknown[];
    check("stake2 state Disputed", disputed[6], 3);

    await rpc("evm_increaseTime", [601]);
    await rpc("evm_mine", []);
    await writeUser("autoRelease", [2n]); // permissionless after the window
    const resolved = (await read("stakes", [2n])) as unknown[];
    check("stake2 state Resolved", resolved[6], 4);
    check("user USDC final", await usdcBal(ADDR.user), USDC(840)); // 670 + 170

    console.log(`\n=== PASS: ${passed} assertions ===`);
    console.log(`User USDC: started 1000, ended ${formatUnits((await usdcBal(ADDR.user)) as bigint, 6)}`);
  } finally {
    await server.close();
  }
}

main().catch((err) => {
  console.error(`\n=== FAILED ===\n${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
