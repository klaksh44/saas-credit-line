/**
 * Permissionless keeper: crystallizes a pool default once the company's debt is past due + grace.
 * In production this logic moves into a Chainlink CRE workflow (CRE replaces Automation/Functions);
 * this script is the terminal-testable equivalent.
 *
 * Env: KEEPER_PRIVATE_KEY (required), ARC_RPC_URL (optional), STAKE_AND_ADVANCE_ADDRESS (or app default).
 */
import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { arcTestnet } from "../app/lib/arcChain";
import { STAKE_AND_ADVANCE_ADDRESS } from "../app/lib/addresses";

const abi = parseAbi([
  "function markDefaulted()",
  "function outstandingPrincipal() view returns (uint256)",
  "function dueAt() view returns (uint64)",
  "function defaultGracePeriod() view returns (uint64)",
]);

async function main() {
  const privateKey = process.env.KEEPER_PRIVATE_KEY as `0x${string}` | undefined;
  if (!privateKey) throw new Error("KEEPER_PRIVATE_KEY is required");

  const rpcUrl = process.env.ARC_RPC_URL ?? arcTestnet.rpcUrls.default.http[0];
  const account = privateKeyToAccount(privateKey);
  const publicClient = createPublicClient({ chain: arcTestnet, transport: http(rpcUrl) });
  const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http(rpcUrl) });

  const [principal, dueAt, grace] = await Promise.all([
    publicClient.readContract({ address: STAKE_AND_ADVANCE_ADDRESS, abi, functionName: "outstandingPrincipal" }),
    publicClient.readContract({ address: STAKE_AND_ADVANCE_ADDRESS, abi, functionName: "dueAt" }),
    publicClient.readContract({ address: STAKE_AND_ADVANCE_ADDRESS, abi, functionName: "defaultGracePeriod" }),
  ]);

  const now = BigInt(Math.floor(Date.now() / 1000));
  const defaultable = principal > 0n && dueAt > 0n && now > dueAt + grace;
  if (!defaultable) {
    console.log(JSON.stringify({ defaultable: false, principal: principal.toString(), dueAt: dueAt.toString() }));
    return;
  }

  const hash = await walletClient.writeContract({
    address: STAKE_AND_ADVANCE_ADDRESS,
    abi,
    functionName: "markDefaulted",
  });
  console.log(JSON.stringify({ defaultable: true, hash }));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
