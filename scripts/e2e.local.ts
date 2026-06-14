/**
 * End-to-end terminal demo on a local anvil node — the "customers are the bank" lifecycle.
 *
 * Flow (no frontend): deploy -> Chainlink underwrite (HTTP, delivers cap + interest rate on-chain)
 * -> two members deposit (NAV-based shares) -> company drawdown -> time passes + repay with interest
 * (NAV rises) -> member redeems at a PROFIT -> second drawdown -> default after grace (NAV falls)
 * -> remaining member redeems at a LOSS. Asserts balances/NAV/state; exits non-zero on failure.
 *
 * Prereqs: `forge build` produced contracts/out, and anvil is running (scripts/e2e.local.sh
 * starts one). RPC via ANVIL_RPC (default 8545).
 */
import { formatUnits, parseUnits } from "viem";
import { loadArtifact } from "../server/artifacts.ts";
import { publicClientFor, walletClientFor } from "../server/chain.ts";
import type { ServerConfig } from "../server/config.ts";
import { startServer } from "../server/index.ts";

const RPC = process.env.ANVIL_RPC ?? "http://127.0.0.1:8545";
const CHAIN_ID = 31337;
const USDC = (n: number | bigint) => parseUnits(String(n), 6);
const SECONDS_PER_YEAR = 31_536_000;

// Well-known anvil dev keys (public test keys — never use on a real network).
const KEY = {
  company: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // deployer = borrower
  alice: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  bob: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  reporter: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
} as const;

const ADDR = {
  company: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  alice: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  bob: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
  reporter: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
} as const;

let passed = 0;
function check(label: string, actual: unknown, expected: unknown): void {
  const a = typeof actual === "bigint" ? actual.toString() : String(actual);
  const e = typeof expected === "bigint" ? expected.toString() : String(expected);
  if (a !== e) throw new Error(`FAIL ${label}: got ${a}, expected ${e}`);
  passed += 1;
  console.log(`  ✓ ${label} = ${a}`);
}
function expect(label: string, condition: boolean, detail: string): void {
  if (!condition) throw new Error(`FAIL ${label}: ${detail}`);
  passed += 1;
  console.log(`  ✓ ${label} (${detail})`);
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
  const company = walletClientFor(KEY.company, CHAIN_ID, RPC);
  const alice = walletClientFor(KEY.alice, CHAIN_ID, RPC);
  const bob = walletClientFor(KEY.bob, CHAIN_ID, RPC);

  console.log("\n=== Deploy ===");
  let hash = await company.deployContract({ abi: usdcAbi, bytecode: usdcArtifact.bytecode, args: [] });
  const usdc = (await publicClient.waitForTransactionReceipt({ hash })).contractAddress!;
  console.log(`  MockUSDC        ${usdc}`);

  // StakeAndAdvance(usdc, keystoneForwarder=reporter, repaymentWindow=600, grace=600, minReserveBps=0)
  hash = await company.deployContract({
    abi: stakeAbi,
    bytecode: stakeArtifact.bytecode,
    args: [usdc, ADDR.reporter, 600, 600, 0],
  });
  const contract = (await publicClient.waitForTransactionReceipt({ hash })).contractAddress!;
  console.log(`  StakeAndAdvance ${contract}  (company = ${ADDR.company})`);

  const write = (wallet: typeof company, fn: string, args: unknown[]) =>
    wallet.writeContract({ address: contract, abi: stakeAbi, functionName: fn, args }).then((h) =>
      publicClient.waitForTransactionReceipt({ hash: h }),
    );
  const read = (fn: string, args: unknown[] = []) =>
    publicClient.readContract({ address: contract, abi: stakeAbi, functionName: fn, args });
  const usdcBal = (who: `0x${string}`) =>
    publicClient.readContract({ address: usdc, abi: usdcAbi, functionName: "balanceOf", args: [who] });

  // Fund members + company, approve the pool.
  const mint = (to: `0x${string}`, n: number) =>
    company.writeContract({ address: usdc, abi: usdcAbi, functionName: "mint", args: [to, USDC(n)] }).then((h) => publicClient.waitForTransactionReceipt({ hash: h }));
  const approve = (wallet: typeof company) =>
    wallet.writeContract({ address: usdc, abi: usdcAbi, functionName: "approve", args: [contract, USDC(1_000_000)] }).then((h) => publicClient.waitForTransactionReceipt({ hash: h }));

  await mint(ADDR.alice, 300);
  await mint(ADDR.bob, 300);
  await mint(ADDR.company, 1000); // buffer so the company can pay interest
  await approve(alice);
  await approve(bob);
  await approve(company);
  check("alice USDC funded", await usdcBal(ADDR.alice), USDC(300));

  // Backend (the API endpoints) in-process, pointing at this contract.
  const serverConfig: ServerConfig = {
    port: 0,
    rpcUrl: RPC,
    chainId: CHAIN_ID,
    contract: contract as `0x${string}`,
    reporterKey: KEY.reporter,
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
    check("health.confidentialAi", health.confidentialAi, "dev");

    console.log("\n=== Chainlink: POST /cre/underwrite (confidential AI -> cap + rate on-chain) ===");
    const financials = {
      vendor: ADDR.company,
      currentDepositedPrincipalUsdc: 250,
      monthlyRecurringRevenueUsd: 5000,
      grossMarginBps: 8000,
      cashBalanceUsd: 50000,
      monthlyBurnUsd: 20000,
      delinquencyRateBps: 100,
    };
    const uw = await api("/cre/underwrite", financials);
    console.log(`  inference: ${JSON.stringify(uw.inference)}  rate=${uw.interestRateBps}bps  tx=${uw.txHash}`);
    check("onchain creditCap == attested", await read("creditCap"), BigInt(uw.cap));
    check("onchain interestRateBps == attested", await read("interestRateBps"), uw.interestRateBps);
    expect("credit cap is positive", BigInt(uw.cap) > 0n, `cap=${uw.cap}`);

    console.log("\n=== Members deposit (become the bank) ===");
    await write(alice, "deposit", [USDC(300)]);
    await write(bob, "deposit", [USDC(300)]);
    check("alice shares", await read("sharesOf", [ADDR.alice]), USDC(300));
    check("bob shares", await read("sharesOf", [ADDR.bob]), USDC(300));
    check("totalAssets", await read("totalAssets"), USDC(600));
    check("cash", await read("cash"), USDC(600));
    check("NAV starts at 1.0", await read("navPerShare1e18"), 10n ** 18n);

    console.log("\n=== API: GET /pool/state ===");
    const state = await api("/pool/state");
    check("pool/state totalAssets", state.totalAssets, USDC(600).toString());
    check("pool/state navPerShare", state.navPerShare1e18, (10n ** 18n).toString());

    console.log("\n=== Company drawdown ===");
    await write(company, "drawdown", [USDC(300)]);
    check("outstandingPrincipal", await read("outstandingPrincipal"), USDC(300));
    check("cash after drawdown", await read("cash"), USDC(300));

    console.log("\n=== Time passes (~1yr); interest accrues; company repays ===");
    await rpc("evm_increaseTime", [SECONDS_PER_YEAR]);
    await rpc("evm_mine", []);
    const owed = (await read("accruedInterest")) as bigint;
    expect("interest accrued over the year", owed > 0n, `${formatUnits(owed, 6)} USDC`);
    const principal = (await read("outstandingPrincipal")) as bigint;
    await write(company, "repay", [principal + owed]);
    check("principal cleared", await read("outstandingPrincipal"), 0n);
    const navAfterRepay = (await read("navPerShare1e18")) as bigint;
    expect("NAV rose above 1.0 from interest", navAfterRepay > 10n ** 18n, `nav=${formatUnits(navAfterRepay, 18)}`);

    console.log("\n=== Member redeems at a PROFIT ===");
    const aliceShares = (await read("sharesOf", [ADDR.alice])) as bigint;
    await write(alice, "redeem", [aliceShares]);
    const aliceOut = (await usdcBal(ADDR.alice)) as bigint;
    expect("alice redeemed more than she deposited", aliceOut > USDC(300), `${formatUnits(aliceOut, 6)} > 300 USDC`);

    console.log("\n=== Second cycle: re-underwrite, drawdown, then DEFAULT ===");
    await api("/cre/underwrite", financials); // refresh the cap (prior one expired after the 1yr warp)
    await write(company, "drawdown", [USDC(300)]);
    check("outstandingPrincipal (cycle 2)", await read("outstandingPrincipal"), USDC(300));

    await rpc("evm_increaseTime", [600 + 600 + 1]); // past due + grace
    await rpc("evm_mine", []);
    await write(alice, "markDefaulted", []); // permissionless
    check("default recorded", await read("totalDefaultedAmount"), USDC(300));
    check("defaulted flag", await read("defaulted"), true);
    const navAfterDefault = (await read("navPerShare1e18")) as bigint;
    expect("NAV fell after default", navAfterDefault < navAfterRepay, `nav=${formatUnits(navAfterDefault, 18)}`);

    console.log("\n=== Remaining member redeems at a LOSS ===");
    const bobShares = (await read("sharesOf", [ADDR.bob])) as bigint;
    await write(bob, "redeem", [bobShares]);
    const bobOut = (await usdcBal(ADDR.bob)) as bigint;
    expect("bob redeemed less than he deposited (bore the default loss)", bobOut < USDC(300), `${formatUnits(bobOut, 6)} < 300 USDC`);

    console.log(`\n=== PASS: ${passed} assertions ===`);
    console.log(`alice: deposited 300, redeemed ${formatUnits(aliceOut, 6)} (profit)`);
    console.log(`bob:   deposited 300, redeemed ${formatUnits(bobOut, 6)} (loss — default)`);
  } finally {
    await server.close();
  }
}

main().catch((err) => {
  console.error(`\n=== FAILED ===\n${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
