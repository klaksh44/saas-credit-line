import { loadArtifact } from "./artifacts.ts";
import { publicClientFor, walletClientFor } from "./chain.ts";
import type { ServerConfig } from "./config.ts";
import {
  underwriteVendor,
  type ConfidentialInferenceResult,
  type FinancialInputs,
} from "../cre/src/creditUnderwriting.ts";

const stakeAbi = loadArtifact("StakeAndAdvance").abi as never;

/**
 * Local stand-in for the Chainlink Confidential AI sandbox (deterministic risk model).
 * Used when CONFIDENTIAL_AI_ENDPOINT is unset, so the flow is terminal-testable offline.
 */
function devInfer(input: FinancialInputs): ConfidentialInferenceResult {
  const burnPressure = input.monthlyBurnUsd > input.cashBalanceUsd ? 30 : 0;
  const delinquency = Math.min(40, Math.floor(input.delinquencyRateBps / 50));
  const riskScore = Math.max(1, Math.min(99, 20 + burnPressure + delinquency));
  const approvedMultiple = riskScore > 70 ? 1 : riskScore > 50 ? 2 : 3;
  return { riskScore, approvedMultiple, rationale: `dev-model risk=${riskScore}` };
}

async function cloudInfer(
  config: ServerConfig,
  input: FinancialInputs,
): Promise<ConfidentialInferenceResult> {
  const res = await fetch(config.confidentialAiEndpoint as string, {
    method: "POST",
    headers: {
      authorization: `Bearer ${config.confidentialAiApiKey ?? ""}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ task: "underwrite_usdc_credit_cap", financials: input }),
  });
  if (!res.ok) throw new Error(`confidential AI endpoint returned ${res.status}`);
  return (await res.json()) as ConfidentialInferenceResult;
}

export async function underwriteAndDeliver(config: ServerConfig, financials: FinancialInputs) {
  const wallet = walletClientFor(config.reporterKey, config.chainId, config.rpcUrl);
  const publicClient = publicClientFor(config.chainId, config.rpcUrl);

  // Anchor the cap's expiry (TTL) to chain time, not wall-clock — the on-chain cap is checked
  // against block.timestamp, so a time-warped test chain must use the chain's clock.
  const now = (await publicClient.getBlock()).timestamp;
  const infer = config.confidentialAiEndpoint
    ? (input: FinancialInputs) => cloudInfer(config, input)
    : async (input: FinancialInputs) => devInfer(input);

  const report = await underwriteVendor(financials, infer, now);

  // Deliver the attested cap on-chain. The reporter key must equal the contract's
  // keystoneForwarder address (the authorized reporter on Arc, which has no forwarder).
  const hash = await wallet.writeContract({
    address: config.contract,
    abi: stakeAbi,
    functionName: "onReport",
    args: ["0x", report.encodedPayload],
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });

  return {
    vendor: report.vendor,
    cap: report.cap.toString(),
    expiry: report.expiry.toString(),
    interestRateBps: report.interestRateBps,
    inference: report.inference,
    mode: config.confidentialAiEndpoint ? "cloud" : "dev",
    txHash: hash,
    status: receipt.status,
  };
}
