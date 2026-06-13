import { createPublicClient, createWalletClient, defineChain, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";

export function makeChain(chainId: number, rpcUrl: string) {
  return defineChain({
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: "Gas", symbol: "GAS", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });
}

export function publicClientFor(chainId: number, rpcUrl: string) {
  return createPublicClient({ chain: makeChain(chainId, rpcUrl), transport: http(rpcUrl) });
}

export function walletClientFor(key: `0x${string}`, chainId: number, rpcUrl: string) {
  return createWalletClient({
    account: privateKeyToAccount(key),
    chain: makeChain(chainId, rpcUrl),
    transport: http(rpcUrl),
  });
}
