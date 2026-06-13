import { encodeAbiParameters, parseAbiParameters } from "viem";

export type FinancialInputs = {
  vendor: `0x${string}`;
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
  onTimeRepaymentBps: number;
  totalRepaidUsdc: number;
  currentOutstandingDebtUsdc: number;
  currentDebtDueAt: number;
};

export type ConfidentialInferenceResult = {
  riskScore: number;
  approvedMultiple: number;
  rationale: string;
};

export type UnderwritingReport = {
  vendor: `0x${string}`;
  cap: bigint;
  expiry: bigint;
  creditAllocationBps: number;
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
const DEFAULT_NO_HISTORY_BPS = 4_000;
const MIN_CREDIT_ALLOCATION_BPS = 1_000;
const MAX_CREDIT_ALLOCATION_BPS = 7_000;
const REPORT_TTL_SECONDS = 7n * 24n * 60n * 60n;
const USDC_DECIMALS = 1_000_000;

export function deriveConservativeCap(
  input: FinancialInputs,
  inference: ConfidentialInferenceResult,
): bigint {
  const sanitizedMultiple = Math.max(0, Math.min(MAX_MULTIPLE, inference.approvedMultiple));
  const marginAdjustedMrr =
    (input.monthlyRecurringRevenueUsd * Math.max(0, input.grossMarginBps)) / 10_000;
  const burnCoveragePenalty = input.monthlyBurnUsd > input.cashBalanceUsd ? 0.5 : 1;
  const delinquencyPenalty = input.delinquencyRateBps > 1_000 ? 0.5 : 1;
  const riskPenalty = inference.riskScore > 70 ? 0.5 : 1;

  const capUsd = (
    marginAdjustedMrr
    * sanitizedMultiple
    * burnCoveragePenalty
    * delinquencyPenalty
    * riskPenalty
  );

  return BigInt(Math.floor(capUsd)) * USDC;
}

export function hasPlatformHistory(input: FinancialInputs): boolean {
  const history = input.platformTrackRecord;
  if (!history) return false;

  return history.repaymentCount > 0;
}

export function deriveNoHistoryCap(input: FinancialInputs): bigint {
  return deriveSupplyFromPrincipal(input, DEFAULT_NO_HISTORY_BPS);
}

export function deriveCap(
  input: FinancialInputs,
  inference: ConfidentialInferenceResult,
): bigint {
  const allocationBps = deriveCreditAllocationBps(input, inference);
  const chainlinkSupply = deriveSupplyFromPrincipal(input, allocationBps);

  if (!hasPlatformHistory(input)) {
    return chainlinkSupply;
  }

  const inferredCap = deriveConservativeCap(input, inference);
  return inferredCap < chainlinkSupply ? inferredCap : chainlinkSupply;
}

export function derivePlatformTrackRecordCap(input: FinancialInputs): bigint {
  const history = input.platformTrackRecord;
  if (!history || history.repaymentCount === 0) return deriveNoHistoryCap(input);

  const onTimeBps = Math.max(0, Math.min(10_000, history.onTimeRepaymentBps));
  const latePenaltyBps = Math.min(3_000, history.lateRepaymentCount * 1_000);
  const outstandingPenaltyBps = history.currentOutstandingDebtUsdc > 0 ? 1_000 : 0;
  const rawTrackRecordBps = (
    4_000
    + onTimeBps / 2
    - latePenaltyBps
    - outstandingPenaltyBps
  );
  const trackRecordBps = Math.max(1_000, Math.min(10_000, rawTrackRecordBps));

  return deriveSupplyFromPrincipal(input, Math.floor(trackRecordBps));
}

export function deriveCreditAllocationBps(
  input: FinancialInputs,
  inference: ConfidentialInferenceResult,
): number {
  if (!hasPlatformHistory(input)) return DEFAULT_NO_HISTORY_BPS;

  const history = input.platformTrackRecord;
  if (!history) return DEFAULT_NO_HISTORY_BPS;

  const onTimeBps = Math.max(0, Math.min(10_000, history.onTimeRepaymentBps));
  const repaymentDepthBps = Math.min(1_000, history.repaymentCount * 200);
  const volumeDepthBps = Math.min(1_000, Math.floor(history.totalRepaidUsdc / 1_000) * 100);
  const onTimeBonusBps = Math.floor((onTimeBps - 8_000) / 4);
  const latePenaltyBps = Math.min(2_500, history.lateRepaymentCount * 800);
  const outstandingPenaltyBps = history.currentOutstandingDebtUsdc > 0 ? 750 : 0;
  const riskPenaltyBps = Math.max(0, inference.riskScore - 50) * 50;
  const delinquencyPenaltyBps = input.delinquencyRateBps > 500
    ? input.delinquencyRateBps / 2
    : 0;
  const burnPenaltyBps = input.monthlyBurnUsd > input.cashBalanceUsd ? 750 : 0;

  const rawBps = (
    DEFAULT_NO_HISTORY_BPS
    + onTimeBonusBps
    + repaymentDepthBps
    + volumeDepthBps
    - latePenaltyBps
    - outstandingPenaltyBps
    - riskPenaltyBps
    - delinquencyPenaltyBps
    - burnPenaltyBps
  );

  return Math.floor(
    Math.max(MIN_CREDIT_ALLOCATION_BPS, Math.min(MAX_CREDIT_ALLOCATION_BPS, rawBps)),
  );
}

export function deriveSupplyFromPrincipal(
  input: FinancialInputs,
  creditAllocationBps: number,
): bigint {
  const principalUnits = BigInt(
    Math.floor(Math.max(0, input.currentDepositedPrincipalUsdc) * USDC_DECIMALS),
  );
  return principalUnits * BigInt(Math.floor(creditAllocationBps)) / 10_000n;
}

export function encodeCreditCapReport(
  vendor: `0x${string}`,
  cap: bigint,
  expiry: bigint,
  creditAllocationBps: number,
): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters(
      "address vendor, uint256 cap, uint64 expiry, uint16 creditAllocationBps",
    ),
    [vendor, cap, expiry, creditAllocationBps],
  );
}

export async function underwriteVendor(
  input: FinancialInputs,
  confidentialInfer: (input: FinancialInputs) => Promise<ConfidentialInferenceResult>,
  nowSeconds: bigint,
): Promise<UnderwritingReport> {
  const inference = await confidentialInfer(input);
  const creditAllocationBps = deriveCreditAllocationBps(input, inference);
  const cap = deriveCap(input, inference);
  const expiry = nowSeconds + REPORT_TTL_SECONDS;

  return {
    vendor: input.vendor,
    cap,
    expiry,
    creditAllocationBps,
    inference,
    encodedPayload: encodeCreditCapReport(
      input.vendor,
      cap,
      expiry,
      creditAllocationBps,
    ),
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
          task: "underwrite_usdc_credit_cap",
          financials,
          policy: {
            noPlatformHistoryCapBps: DEFAULT_NO_HISTORY_BPS,
            minCreditAllocationBps: MIN_CREDIT_ALLOCATION_BPS,
            maxCreditAllocationBps: MAX_CREDIT_ALLOCATION_BPS,
            currentDepositedPrincipalUsdc: financials.currentDepositedPrincipalUsdc,
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
