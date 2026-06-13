/**
 * Deploy MockUSDC + StakeAndAdvance to a running anvil, set the World ID signer,
 * fund/approve the demo user, and print {usdc, contract} as JSON.
 * Used by scripts/server.local.sh so the standalone server has a contract to talk to.
 */
import { parseUnits } from "viem";
import { loadArtifact } from "../server/artifacts.ts";
import { publicClientFor, walletClientFor } from "../server/chain.ts";

const RPC = process.env.ANVIL_RPC ?? "http://127.0.0.1:8545";
const CHAIN_ID = 31337;
const USDC = (n: number) => parseUnits(String(n), 6);

const KEY = {
  vendor: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  user: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
} as const;
const ADDR = {
  arbiter: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
  reporter: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
  worldIdSigner: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
  user: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
} as const;

async function main(): Promise<void> {
  const usdcArtifact = loadArtifact("MockUSDC");
  const stakeArtifact = loadArtifact("StakeAndAdvance");
  const pub = publicClientFor(CHAIN_ID, RPC);
  const vendor = walletClientFor(KEY.vendor, CHAIN_ID, RPC);

  let hash = await vendor.deployContract({ abi: usdcArtifact.abi as never, bytecode: usdcArtifact.bytecode, args: [] });
  const usdc = (await pub.waitForTransactionReceipt({ hash })).contractAddress!;

  hash = await vendor.deployContract({
    abi: stakeArtifact.abi as never,
    bytecode: stakeArtifact.bytecode,
    args: [usdc, ADDR.arbiter, ADDR.reporter, 600, 6000],
  });
  const contract = (await pub.waitForTransactionReceipt({ hash })).contractAddress!;

  await vendor.writeContract({ address: contract, abi: stakeArtifact.abi as never, functionName: "setWorldIdSigner", args: [ADDR.worldIdSigner] }).then((h) => pub.waitForTransactionReceipt({ hash: h }));
  await vendor.writeContract({ address: usdc, abi: usdcArtifact.abi as never, functionName: "mint", args: [ADDR.user, USDC(1000)] }).then((h) => pub.waitForTransactionReceipt({ hash: h }));

  console.log(JSON.stringify({ usdc, contract }));
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
