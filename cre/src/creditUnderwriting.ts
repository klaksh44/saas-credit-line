import { encodeAbiParameters, parseAbiParameters } from "viem";

export type FinancialInputs = {
  vendor: `0x${string}`; // the company / borrower address
  currentDepositedPrincipalUsdc: number;
  monthlyRecurringRevenueUsd: number;
  grossMarginBps: number;
  cashBalanceUsd: number;
  monthlyBurnUsd: number;
  delinquencyRateBps: number;
  platformTrackRecord?: PlatformTrackRecord | null;
};

export type PlatformTrackRecord = {
  drawdownCount: number;
  repaymentCount: number;
  onTimeRepaymentCount: number;
  lateRepaymentCount: number;
  totalInterestPaidUsdc: number;
  defaultedAmountUsdc: number;
  currentOutstandingDebtUsdc: number;
  currentDebtDueAt: number;
};

export type ConfidentialInferenceResult = {
  riskScore: number; // 1..99 (higher = riskier)
  approvedMultiple: number; // 0..3 multiple of margin-adjusted MRR
  rationale: string;
};

export type UnderwritingReport = {
  vendor: `0x${string}`;
  cap: bigint;
  expiry: bigint;
  interestRateBps: number;
  inference: ConfidentialInferenceResult;
  encodedPayload: `0x${string}`;
};

export type WorkflowRuntime = {
  env?: Record<string, string | undefined>;
  now: () => Promise<number> | number;
  secrets: { get: (name: string) => Promise<string> | string };
  confidentialHttp: {
    post: (
      url: string,
      init: { headers: Record<string, string>; body: unknown },
    ) => Promise<{
      body: ConfidentialInferenceResult;
    }>;
  };
  evm: {
    writeReport: (args: {
      chainId: number;
      receiver: `0x${string}`;
      report: `0x${string}`;
    }) => Promise<unknown>;
  };
};

const USDC = 1_000_000n;
const MAX_MULTIPLE = 3;
const MIN_INTEREST_RATE_BPS = 600; // 6% APR floor
const MAX_INTEREST_RATE_BPS = 2400; // 24% APR ceiling (well under the contract's 100% bound)
const REPORT_TTL_SECONDS = 7n * 24n * 60n * 60n;

/**
 * Conservative USDC credit cap = margin-adjusted MRR × approved multiple, scaled down by
 * burn / delinquency / risk penalties. This is "how much credit the company qualifies for";
 * how much can actually be drawn is additionally bounded on-chain by the pool's liquid cash.
 */
export function deriveCap(
  input: FinancialInputs,
  inference: ConfidentialInferenceResult,
): bigint {
  const sanitizedMultiple = Math.max(0, Math.min(MAX_MULTIPLE, inference.approvedMultiple));
  const marginAdjustedMrr =
    (input.monthlyRecurringRevenueUsd * Math.max(0, input.grossMarginBps)) / 10_000;
  const burnCoveragePenalty = input.monthlyBurnUsd > input.cashBalanceUsd ? 0.5 : 1;
  const delinquencyPenalty = input.delinquencyRateBps > 1_000 ? 0.5 : 1;
  const riskPenalty = inference.riskScore > 70 ? 0.5 : 1;

  const capUsd =
    marginAdjustedMrr * sanitizedMultiple * burnCoveragePenalty * delinquencyPenalty * riskPenalty;

  return BigInt(Math.floor(Math.max(0, capUsd))) * USDC;
}

/**
 * Risk-priced APR for the pool's loan to the company. Riskier company → higher rate (the spread the
 * member-lenders earn). Monotonic in the confidential AI risk score, with burn/delinquency bumps.
 */
export function deriveInterestRateBps(
  input: FinancialInputs,
  inference: ConfidentialInferenceResult,
): number {
  const base = MIN_INTEREST_RATE_BPS;
  const riskComponent = Math.max(0, inference.riskScore) * 18; // ~+1782 bps at risk 99
  const burnPenalty = input.monthlyBurnUsd > input.cashBalanceUsd ? 400 : 0;
  const delinquencyPenalty = input.delinquencyRateBps > 1_000 ? 400 : 0;

  const raw = base + riskComponent + burnPenalty + delinquencyPenalty;
  return Math.floor(Math.max(MIN_INTEREST_RATE_BPS, Math.min(MAX_INTEREST_RATE_BPS, raw)));
}

export function encodeCreditCapReport(
  vendor: `0x${string}`,
  cap: bigint,
  expiry: bigint,
  interestRateBps: number,
): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters("address vendor, uint256 cap, uint64 expiry, uint16 interestRateBps"),
    [vendor, cap, expiry, interestRateBps],
  );
}

export async function underwriteVendor(
  input: FinancialInputs,
  confidentialInfer: (input: FinancialInputs) => Promise<ConfidentialInferenceResult>,
  nowSeconds: bigint,
): Promise<UnderwritingReport> {
  const inference = await confidentialInfer(input);
  const cap = deriveCap(input, inference);
  const interestRateBps = deriveInterestRateBps(input, inference);
  const expiry = nowSeconds + REPORT_TTL_SECONDS;

  return {
    vendor: input.vendor,
    cap,
    expiry,
    interestRateBps,
    inference,
    encodedPayload: encodeCreditCapReport(input.vendor, cap, expiry, interestRateBps),
  };
}

export async function workflow(
  runtime: WorkflowRuntime,
  input: FinancialInputs,
): Promise<UnderwritingReport> {
  const now = BigInt(await runtime.now());
  const endpoint = await runtime.secrets.get("CONFIDENTIAL_AI_ENDPOINT");
  const apiKey = await runtime.secrets.get("CONFIDENTIAL_AI_API_KEY");

  const report = await underwriteVendor(
    input,
    async (financials) => {
      const response = await runtime.confidentialHttp.post(endpoint, {
        headers: {
          authorization: `Bearer ${apiKey}`,
          "content-type": "application/json",
        },
        body: {
          task: "underwrite_usdc_credit_line",
          financials,
          policy: {
            minInterestRateBps: MIN_INTEREST_RATE_BPS,
            maxInterestRateBps: MAX_INTEREST_RATE_BPS,
            maxMultiple: MAX_MULTIPLE,
            platformTrackRecord: financials.platformTrackRecord ?? null,
          },
        },
      });

      return response.body;
    },
    now,
  );

  await runtime.evm.writeReport({
    chainId: Number(runtime.env?.ARC_CHAIN_ID ?? "5042002"),
    receiver: asAddress(runtime.env?.STAKE_AND_ADVANCE_ADDRESS),
    report: report.encodedPayload,
  });

  return report;
}

function asAddress(value: string | undefined): `0x${string}` {
  if (!value || !/^0x[a-fA-F0-9]{40}$/.test(value)) {
    throw new Error("STAKE_AND_ADVANCE_ADDRESS must be a valid EVM address");
  }

  return value as `0x${string}`;
}
